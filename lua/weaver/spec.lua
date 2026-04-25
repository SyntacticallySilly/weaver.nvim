-- lua/weaver/spec.lua
-- Translates lazy.nvim-style specs into weaver's internal WeaverSpec format.
--
-- lazy.nvim spec fields handled:
--   Source:      [1], url, dir, name, dev
--   Loading:     dependencies, enabled, cond, priority
--   Setup:       init, opts (table|fn), config (fn|true), main, build
--   Lazy:        lazy, event (str|list|fn), ft (str|list|fn),
--                cmd (str|list|fn), keys (str|list|fn)
--   Versioning:  version, tag, branch, commit, pin, submodules
--   Advanced:    optional, specs, module, import

local util     = require("weaver.util")
local importer = require("weaver.importer")

---@class WeaverSpec
---@field src        string
---@field name       string
---@field version    string|nil
---@field pin        boolean
---@field lazy       boolean
---@field event      string[]
---@field ft         string[]
---@field cmd        string[]
---@field keys       table[]
---@field priority   integer
---@field enabled    boolean
---@field optional   boolean
---@field build      string|function|nil
---@field config     function|nil
---@field init       function|nil
---@field opts       table|nil
---@field dir        string|nil
---@field deps       WeaverSpec[]
---@field scoped     WeaverSpec[]   -- from `specs` field (scope-children)
---@field _norm_keys table[]|nil    -- cached normalised key specs (loader internal)

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────────

-- Resolve a value that may be a plain list/string or a lazy.nvim-style
-- function `fun(self, defaults) -> list`.  The function form is called
-- with the (not-yet-complete) spec table and an empty default list.
---@param v any
---@param self_spec table   the raw spec table, passed as first arg to fn
---@return string[]
local function resolve_list(v, self_spec)
  if v == nil              then return {} end
  if type(v) == "string"  then return { v } end
  if type(v) == "table"   then return v end
  if type(v) == "function" then
    local ok, result = pcall(v, self_spec, {})
    if ok and type(result) == "table" then return result end
    if ok and type(result) == "string" then return { result } end
    -- function returned nil/false → treat as empty (conditional disable)
    return {}
  end
  return {}
end

---@param v boolean|function|nil
---@param self_spec table|nil
---@return boolean
local function eval_bool(v, self_spec)
  if v == nil               then return true end
  if type(v) == "function"  then return v(self_spec or {}) ~= false end
  return v ~= false
end

-- ── MAIN module heuristic ────────────────────────────────────────────────
-- lazy.nvim tries multiple candidates to find which Lua module exposes setup().
-- We replicate the same priority order so `opts` auto-setup works for plugins
-- whose module name differs from their repo name (lspconfig, nvim-treesitter…)

---@param raw_name string   repo-tail name, e.g. "nvim-lspconfig"
---@param explicit string|nil  value of raw.main if given
---@return string|nil   the first module that exists, or nil
local function resolve_main(raw_name, explicit)
  if explicit then return explicit end

  -- Build candidate list matching lazy.nvim's heuristic order
  local candidates = {
    raw_name,                           -- "nvim-lspconfig"  (as-is)
    raw_name:gsub("^n?vim%-", ""),      -- "lspconfig"       (strip nvim-/vim- prefix)
    raw_name:gsub("%-", "_"),           -- "nvim_lspconfig"  (hyphens → underscores)
    raw_name:gsub("^n?vim%-", ""):gsub("%-", "_"),  -- "lspconfig" clean
    raw_name:gsub("%.nvim$", ""),       -- "telescope"       (strip .nvim suffix)
    raw_name:gsub("%.nvim$", ""):gsub("%-", "_"),
  }

  -- Deduplicate while preserving order
  local seen = {}
  for _, c in ipairs(candidates) do
    if not seen[c] then
      seen[c] = true
      -- A quick pcall-require check tells us if the module actually exists
      local ok, mod = pcall(require, c)
      if ok and type(mod) == "table" and type(mod.setup) == "function" then
        return c
      end
    end
  end
  return nil   -- caller will skip setup() gracefully
end

-- ── parse ────────────────────────────────────────────────────────────────

---@param raw table|string
---@return WeaverSpec|nil
function M.parse(raw)
  if type(raw) == "string" then raw = { raw } end
  if type(raw) ~= "table" then
    vim.notify("[weaver] Invalid spec: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  -- ── Source ──────────────────────────────────────────────────────────
  local src_raw = raw[1] or raw.url or raw.src or raw.dir
  if not src_raw then
    vim.notify("[weaver] Spec missing source: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  local first_char = src_raw:sub(1, 1)
  local first_two  = src_raw:sub(1, 2)
  local is_local   = raw.dir ~= nil
    or first_char == "/" or first_two == "~/" or first_two == "~\\"

  -- `dev = true` → treated as local using util.dev_path (falls back gracefully)
  if raw.dev and not is_local then
    local dev_path = util.dev_path(src_raw)
    if dev_path then
      raw = vim.tbl_extend("force", raw, { dir = dev_path })
      is_local = true
      src_raw  = dev_path
    end
  end

  local src  = is_local and src_raw or util.normalize_src(src_raw)
  local name = raw.name or util.name_from_src(src_raw)

  -- ── Guards ──────────────────────────────────────────────────────────
  -- Bail before building closures for disabled/conditional specs
  if not eval_bool(raw.enabled, raw) then return nil end
  if not eval_bool(raw.cond,    raw) then return nil end

  -- ── Lazy resolution ──────────────────────────────────────────────────
  -- nil → true (lazy by default); false → eager
  local lazy = raw.lazy ~= false

  -- Resolve trigger fields — each supports str | list | fn
  local event = lazy and resolve_list(raw.event, raw) or {}
  local ft    = lazy and resolve_list(raw.ft,    raw) or {}
  local cmd   = lazy and resolve_list(raw.cmd,   raw) or {}

  -- ── config / opts ────────────────────────────────────────────────────
  -- lazy.nvim supports:
  --   config = true          → auto-call require(MAIN).setup(opts)
  --   config = function(...) → user function (called with plugin, opts)
  --   opts   = table         → implies config=true behaviour
  --   opts   = function(plugin, existing_opts) → merge/replace
  --
  -- weaver wraps all of these into a single config_fn closure.

  local config_fn

  local has_opts   = raw.opts ~= nil
  local config_raw = raw.config
  local auto_setup = has_opts or config_raw == true  -- `config=true` shorthand

  if auto_setup or (config_raw and config_raw ~= true) then
    local user_opts_raw = raw.opts
    local user_cfg      = (config_raw ~= true) and config_raw or nil
    local main_hint     = raw.main   -- may be nil; resolve_main() handles that

    config_fn = function(plugin)
      -- Resolve opts: table is used as-is; function receives (plugin, {})
      local resolved_opts
      if type(user_opts_raw) == "function" then
        -- lazy.nvim signature: fun(plugin, opts) where opts is existing/parent opts
        local ok, result = pcall(user_opts_raw, plugin, {})
        resolved_opts = (ok and type(result) == "table") and result or {}
      else
        resolved_opts = user_opts_raw or {}
      end

      -- Auto-call setup() when opts present or config=true
      if auto_setup then
        local main_mod = resolve_main(name, main_hint)
        if main_mod then
          -- Re-require (module is now loaded after packadd)
          local ok, mod = pcall(require, main_mod)
          if ok and type(mod) == "table" and type(mod.setup) == "function" then
            util.safe_call(
              function() mod.setup(resolved_opts) end,
              name .. ".setup"
            )
          end
        else
          vim.notify(
            ("[weaver] Could not find main module for '%s' — setup() skipped. "
             .. "Set `main = 'module_name'` in the spec to fix this."):format(name),
            vim.log.levels.DEBUG
          )
        end
      end

      -- Call user's config function if provided
      if user_cfg then
        util.safe_call(
          function() user_cfg(plugin, resolved_opts) end,
          name .. ".config"
        )
      end
    end
  end

  -- ── keys: normalise here so we can handle `false` rhs (disable) ──────
  -- raw.keys may be: string | {lhs} | {lhs, rhs, ...} | {lhs, false} | fn
  local raw_keys = resolve_list(raw.keys, raw)

  -- ── Version / pin ─────────────────────────────────────────────────────
  -- `commit` is treated identically to a version pin for vim.pack purposes
  local version = raw.version or raw.tag or raw.branch or raw.commit

  ---@type WeaverSpec
  local spec = {
    src      = is_local and src_raw or src,
    name     = name,
    version  = version,
    pin      = raw.pin == true,
    lazy     = lazy,
    event    = event,
    ft       = ft,
    cmd      = cmd,
    keys     = raw_keys,
    priority = raw.priority or 50,
    enabled  = true,
    optional = raw.optional == true,
    build    = raw.build or raw.run,
    config   = config_fn,
    init     = raw.init,
    opts     = raw.opts,
    dir      = is_local and vim.fn.expand(src_raw) or nil,
    deps     = {},
    scoped   = {},
  }

  -- ── dependencies ──────────────────────────────────────────────────────
  if raw.dependencies then
    for _, dep in ipairs(raw.dependencies) do
      local dep_spec = M.parse(dep)
      if dep_spec then spec.deps[#spec.deps + 1] = dep_spec end
    end
  end

  -- ── scoped specs (`specs` field) ────────────────────────────────────
  -- These are only active while the parent plugin is enabled (already
  -- guaranteed here since we passed the enabled/cond guards above).
  if raw.specs then
    local scoped_raw = type(raw.specs) == "table" and raw.specs or { raw.specs }
    for _, s in ipairs(scoped_raw) do
      local s_spec = M.parse(s)
      if s_spec then spec.scoped[#spec.scoped + 1] = s_spec end
    end
  end

  return spec
end

-- ── parse_all ────────────────────────────────────────────────────────────

---@param raws table[]
---@return WeaverSpec[]
function M.parse_all(raws)
  local expanded = importer.expand(raws)

  -- First pass: parse everything (preserves order for priority sort)
  local parsed = {}
  for _, raw in ipairs(expanded) do
    local spec = M.parse(raw)
    if spec then parsed[#parsed + 1] = spec end
  end

  -- ── optional resolution ───────────────────────────────────────────────
  -- A spec with optional=true is only kept if the same plugin name appears
  -- at least once without optional=true.  This is the lazy.nvim contract
  -- that LazyVim distros rely on heavily.
  local non_optional = {}
  for _, spec in ipairs(parsed) do
    if not spec.optional then non_optional[spec.name] = true end
  end
  local filtered = {}
  for _, spec in ipairs(parsed) do
    if not spec.optional or non_optional[spec.name] then
      filtered[#filtered + 1] = spec
    end
  end
  parsed = filtered

  -- Sort by priority descending (higher = loaded earlier)
  table.sort(parsed, function(a, b) return a.priority > b.priority end)

  -- ── deduplication + dep hoisting ──────────────────────────────────────
  -- Flatten scoped specs into the top-level list alongside regular specs,
  -- then deduplicate while ensuring deps always appear before their parent.
  local seen   = {}
  local result = {}

  local function insert(spec)
    if seen[spec.name] then return end
    for _, dep in ipairs(spec.deps) do
      if not seen[dep.name] then insert(dep) end
    end
    seen[spec.name]     = true
    result[#result + 1] = spec
    -- Scoped children are hoisted here so they participate in dedup
    for _, child in ipairs(spec.scoped) do
      insert(child)
    end
  end

  for _, spec in ipairs(parsed) do insert(spec) end

  return result
end

return M
