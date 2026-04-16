-- lua/weaver/spec.lua
-- Translates lazy.nvim-style specs into weaver's internal format.
--
-- Supported lazy.nvim spec keys:
--   [1]          string  – plugin source (shorthand or URL)
--   name         string  – override plugin name
--   version      string  – git tag/branch/commit or semver range
--   dependencies table   – list of specs loaded before this plugin
--   lazy         bool    – default TRUE. set false to force eager load,
--                          which suppresses all event/ft/cmd/keys triggers.
--   event        str|tbl – load on VimEvent(s)         (ignored when lazy=false)
--   ft           str|tbl – load on FileType(s)         (ignored when lazy=false)
--   cmd          str|tbl – load on Ex command(s)       (ignored when lazy=false)
--   keys         str|tbl – keymap specs { lhs, rhs?, mode?, desc?, ... }
--                          When lazy=true:  acts as lazy-load trigger + real keymap
--                          When lazy=false: registers real keymaps only, no stub
--   priority     int     – loading order (higher = earlier), default 50
--   enabled      bool|fn – whether plugin is active at all
--   cond         bool|fn – conditional load (false → disabled)
--   build        str|fn  – run after install/update
--   config       fn      – called after the plugin is loaded
--   init         fn      – always called at startup, even for lazy plugins
--   opts         table   – passed to config as second arg (auto-calls setup())
--   dir          string  – local path (skips vim.pack, just adds to rtp)
--   url          string  – alias for [1]
--   import       string  – import a directory or Lua module (handled by importer)

local util     = require("weaver.util")
local importer = require("weaver.importer")

---@class WeaverSpec
---@field src       string        Full source URL
---@field name      string        Resolved plugin name
---@field version   string|nil    Version pin / branch
---@field lazy      boolean       Whether lazy-loading is active (default: true)
---@field event     string[]      Triggering events      (empty when lazy=false)
---@field ft        string[]      Triggering filetypes   (empty when lazy=false)
---@field cmd       string[]      Triggering commands    (empty when lazy=false)
---@field keys      table[]       Keymap specs (trigger + real map, or real map only)
---@field priority  integer       Load priority
---@field enabled   boolean       Is plugin enabled
---@field build     string|function|nil  Post-install/update hook
---@field config    function|nil  Post-load configuration
---@field init      function|nil  Always-run startup hook
---@field opts      table|nil     Passed to plugin's setup()
---@field dir       string|nil    Local directory override
---@field deps      WeaverSpec[]  Resolved dependency specs

local M = {}

---@param v any
---@return string[]
local function to_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  if type(v) == "table"  then return v     end
  return {}
end

---@param v boolean|function|nil
---@return boolean
local function eval_bool(v)
  if v == nil then return true end
  if type(v) == "function" then return v() ~= false end
  return v ~= false
end

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

  local is_local = raw.dir ~= nil
    or (src_raw:sub(1, 1) == "/" or src_raw:sub(1, 2) == "~/")
  local src  = is_local and src_raw or util.normalize_src(src_raw)
  local name = raw.name or util.name_from_src(src_raw)

  if not eval_bool(raw.enabled) then return nil end
  if not eval_bool(raw.cond)    then return nil end

  -- ── Lazy resolution ─────────────────────────────────────────────────
  -- CHANGED: lazy is TRUE by default.
  --
  -- lazy = false  → force eager load; ALL trigger fields (event, ft, cmd)
  --                 are zeroed out so loader.register_triggers() is never
  --                 called. keys entries are still kept for real keymap
  --                 registration, they just won't create stub keymaps.
  --
  -- lazy = true   → explicit lazy; triggers wired as-is.
  -- lazy = nil    → same as true (the new default).
  -- ────────────────────────────────────────────────────────────────────
  local lazy = (raw.lazy ~= false) -- CHANGED: nil → true, false → false

  -- When eager, zero out every trigger so register_triggers() has nothing
  -- to wire. The keys table is intentionally preserved (real keymaps).
  local event = lazy and to_list(raw.event) or {}   -- CHANGED
  local ft    = lazy and to_list(raw.ft)    or {}   -- CHANGED
  local cmd   = lazy and to_list(raw.cmd)   or {}   -- CHANGED

  -- config wrapper: auto-call setup(opts) when opts is present
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
    event    = event,                               -- CHANGED (zeroed when !lazy)
    ft       = ft,                                  -- CHANGED
    cmd      = cmd,                                 -- CHANGED
    keys     = to_list(raw.keys),                   -- always kept (real keymaps)
    priority = raw.priority or 50,
    enabled  = true,
    build    = raw.build or raw.run,
    config   = config_fn,
    init     = raw.init,
    opts     = raw.opts,
    dir      = is_local and vim.fn.expand(src_raw) or nil,
    deps     = {},
  }

  if raw.dependencies then
    for _, dep in ipairs(raw.dependencies) do
      local dep_spec = M.parse(dep)
      if dep_spec then table.insert(spec.deps, dep_spec) end
    end
  end

  return spec
end

---@param raws table[]
---@return WeaverSpec[]
function M.parse_all(raws)
  local expanded = importer.expand(raws)

  local seen   = {}
  local result = {}

  local function insert(spec)
    if not spec or seen[spec.name] then return end
    for _, dep in ipairs(spec.deps) do insert(dep) end
    seen[spec.name] = true
    table.insert(result, spec)
  end

  local parsed = {}
  for _, raw in ipairs(expanded) do
    local spec = M.parse(raw)
    if spec then table.insert(parsed, spec) end
  end

  table.sort(parsed, function(a, b) return a.priority > b.priority end)
  for _, spec in ipairs(parsed) do insert(spec) end

  return result
end

return M
