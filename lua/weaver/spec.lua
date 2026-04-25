-- lua/weaver/spec.lua
-- Translates lazy.nvim-style specs into weaver's internal format.

local util     = require("weaver.util")
local importer = require("weaver.importer")

---@class WeaverSpec
---@field src       string
---@field name      string
---@field version   string|nil
---@field lazy      boolean
---@field event     string[]
---@field ft        string[]
---@field cmd       string[]
---@field keys      table[]
---@field priority  integer
---@field enabled   boolean
---@field build     string|function|nil
---@field config    function|nil
---@field init      function|nil
---@field opts      table|nil
---@field dir       string|nil
---@field deps      WeaverSpec[]

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────

---@param v any
---@return string[]
local function to_list(v)
  if v == nil              then return {} end
  if type(v) == "string"  then return { v } end
  if type(v) == "table"   then return v end
  return {}
end

---@param v boolean|function|nil
---@return boolean
local function eval_bool(v)
  if v == nil                 then return true end
  if type(v) == "function"    then return v() ~= false end
  return v ~= false
end

-- ── parse ────────────────────────────────────────────────────────────

---@param raw table|string
---@return WeaverSpec|nil
function M.parse(raw)
  if type(raw) == "string" then raw = { raw } end

  if type(raw) ~= "table" then
    vim.notify("[weaver] Invalid spec: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  local src_raw = raw[1] or raw.url or raw.src or raw.dir
  if not src_raw then
    vim.notify("[weaver] Spec missing source: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  -- Fast local-path detection (avoid multiple sub() calls)
  local first_char  = src_raw:sub(1, 1)
  local first_two   = src_raw:sub(1, 2)
  local is_local    = raw.dir ~= nil
    or first_char == "/" or first_two == "~/" or first_two == "~\\"

  local src  = is_local and src_raw or util.normalize_src(src_raw)
  local name = raw.name or util.name_from_src(src_raw)

  -- Bail early before building config closure
  if not eval_bool(raw.enabled) then return nil end
  if not eval_bool(raw.cond)    then return nil end

  -- lazy = nil → true (lazy by default); false → eager
  local lazy = raw.lazy ~= false

  -- Zero out trigger lists when eager — avoid table alloc for empty lists
  local event = lazy and to_list(raw.event) or {}
  local ft    = lazy and to_list(raw.ft)    or {}
  local cmd   = lazy and to_list(raw.cmd)   or {}

  -- Build config closure only when needed
  local config_fn = raw.config
  if raw.opts ~= nil then
    local opts     = raw.opts
    local user_cfg = raw.config
    config_fn = function(plugin)
      local resolved_opts = type(opts) == "function" and opts(plugin) or opts
      local ok, mod = pcall(require, name)
      if ok and type(mod.setup) == "function" then
        util.safe_call(function() mod.setup(resolved_opts) end, name .. ".setup")
      end
      if user_cfg then
        util.safe_call(function() user_cfg(plugin, resolved_opts) end, name .. ".config")
      end
    end
  end

  ---@type WeaverSpec
  local spec = {
    src      = is_local and src_raw or src,
    name     = name,
    version  = raw.version or raw.tag or raw.branch,
    lazy     = lazy,
    event    = event,
    ft       = ft,
    cmd      = cmd,
    keys     = to_list(raw.keys),
    priority = raw.priority or 50,
    enabled  = true,
    build    = raw.build or raw.run,
    config   = config_fn,
    init     = raw.init,
    opts     = raw.opts,
    dir      = is_local and vim.fn.expand(src_raw) or nil,
    deps     = {},
  }

  -- Parse dependencies (recursive)
  if raw.dependencies then
    local deps = spec.deps
    for _, dep in ipairs(raw.dependencies) do
      local dep_spec = M.parse(dep)
      if dep_spec then deps[#deps + 1] = dep_spec end
    end
  end

  return spec
end

-- ── parse_all ────────────────────────────────────────────────────────

---@param raws table[]
---@return WeaverSpec[]
function M.parse_all(raws)
  local expanded = importer.expand(raws)

  -- Parse into a flat list first, preserving priority sort
  local parsed = {}
  for _, raw in ipairs(expanded) do
    local spec = M.parse(raw)
    if spec then parsed[#parsed + 1] = spec end
  end

  table.sort(parsed, function(a, b) return a.priority > b.priority end)

  -- Deduplicate while hoisting deps; use a hash-set for O(1) seen checks
  local seen   = {}
  local result = {}

  local function insert(spec)
    if seen[spec.name] then return end
    -- Deps are already sorted by their own parse; insert deps first
    for _, dep in ipairs(spec.deps) do
      if not seen[dep.name] then insert(dep) end
    end
    seen[spec.name]   = true
    result[#result + 1] = spec
  end

  for _, spec in ipairs(parsed) do insert(spec) end

  return result
end

return M
