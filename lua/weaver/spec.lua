-- lua/weaver/spec.lua
-- Translates lazy.nvim-style specs into weaver's internal format.
--
-- Supported lazy.nvim spec keys:
--   [1]          string  – plugin source (shorthand or URL)
--   name         string  – override plugin name
--   version      string  – git tag/branch/commit or semver range
--   dependencies table   – list of specs loaded before this plugin
--   lazy         bool    – force defer until explicitly loaded
--   event        str|tbl – load on VimEvent(s)
--   ft           str|tbl – load on FileType(s)
--   cmd          str|tbl – load on Ex command(s)
--   keys         str|tbl – load on keymap(s)  { lhs, rhs?, mode?, desc? }
--   priority     int     – loading order (higher = earlier), default 50
--   enabled      bool|fn – whether plugin is active at all
--   cond         bool|fn – conditional load (false → disabled)
--   build        str|fn  – run after install/update  (= lazy "build" / "run")
--   config       fn      – called after the plugin is loaded
--   init         fn      – always called at startup, even for lazy plugins
--   opts         table   – passed to config as second arg (calls setup automatically)
--   dir          string  – local path (skips vim.pack, just adds to rtp)
--   url          string  – alias for [1]
--   import       string  – import a directory or Lua module (handled by importer)

local util     = require("weaver.util")
local importer = require("weaver.importer") -- ← NEW

---@class WeaverSpec
---@field src       string        Full source URL
---@field name      string        Resolved plugin name
---@field version   string|nil    Version pin / branch
---@field lazy      boolean       Whether lazy-loading is active
---@field event     string[]|nil  Triggering events
---@field ft        string[]|nil  Triggering filetypes
---@field cmd       string[]|nil  Triggering commands
---@field keys      table[]|nil   Triggering keymaps
---@field priority  integer       Load priority
---@field enabled   boolean       Is plugin enabled
---@field build     string|function|nil  Post-install/update hook
---@field config    function|nil  Post-load configuration
---@field init      function|nil  Always-run startup hook
---@field opts      table|nil     Passed to plugin's setup()
---@field dir       string|nil    Local directory override
---@field deps      WeaverSpec[]  Resolved dependency specs

local M        = {}

--- Normalize any value to a string list.
---@param v any
---@return string[]
local function to_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  if type(v) == "table" then return v end
  return {}
end

--- Evaluate a boolean-or-function field.
---@param v boolean|function|nil
---@return boolean
local function eval_bool(v)
  if v == nil then return true end
  if type(v) == "function" then return v() ~= false end
  return v ~= false
end

--- Parse a single lazy.nvim-style spec table into a WeaverSpec.
--- Recursively resolves dependencies.
---@param raw table|string
---@return WeaverSpec|nil
function M.parse(raw)
  if type(raw) == "string" then raw = { raw } end

  if type(raw) ~= "table" then
    vim.notify("[weaver] Invalid spec: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  -- Resolve source
  local src_raw = raw[1] or raw.url or raw.src or raw.dir
  if not src_raw then
    vim.notify("[weaver] Spec missing source: " .. vim.inspect(raw), vim.log.levels.WARN)
    return nil
  end

  local is_local = raw.dir ~= nil or (src_raw:sub(1, 1) == "/" or src_raw:sub(1, 2) == "~/")
  local src      = is_local and src_raw or util.normalize_src(src_raw)
  local name     = raw.name or util.name_from_src(src_raw)

  if not eval_bool(raw.enabled) then return nil end
  if not eval_bool(raw.cond) then return nil end

  local has_trigger = raw.event ~= nil or raw.ft ~= nil
      or raw.cmd ~= nil or raw.keys ~= nil
  local lazy
  if raw.lazy == false then
    lazy = false
  elseif raw.lazy == true or has_trigger then
    lazy = true
  else
    lazy = false
  end

  local config_fn = raw.config
  if raw.opts ~= nil then
    local opts     = raw.opts
    local user_cfg = raw.config
    config_fn      = function(plugin)
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
    event    = to_list(raw.event),
    ft       = to_list(raw.ft),
    cmd      = to_list(raw.cmd),
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

  if raw.dependencies then
    for _, dep in ipairs(raw.dependencies) do
      local dep_spec = M.parse(dep)
      if dep_spec then table.insert(spec.deps, dep_spec) end
    end
  end

  return spec
end

--- Parse a list of raw specs, returning a flat ordered list of WeaverSpecs.
--- *** Import directives are expanded here before parsing begins. ***
---@param raws table[]
---@return WeaverSpec[]
function M.parse_all(raws)
  -- ── EXPAND imports first ────────────────────────────────────────────
  local expanded = importer.expand(raws) -- ← NEW (one line)
  -- ───────────────────────────────────────────────────────────────────

  local seen     = {}
  local result   = {}

  local function insert(spec)
    if not spec or seen[spec.name] then return end
    for _, dep in ipairs(spec.deps) do insert(dep) end
    seen[spec.name] = true
    table.insert(result, spec)
  end

  local parsed = {}
  for _, raw in ipairs(expanded) do -- ← uses `expanded` not `raws`
    local spec = M.parse(raw)
    if spec then table.insert(parsed, spec) end
  end

  table.sort(parsed, function(a, b) return a.priority > b.priority end)
  for _, spec in ipairs(parsed) do insert(spec) end

  return result
end

return M
