-- lua/weaver/loader.lua
-- Lazy-loading engine + real keymap registration.
--
-- Keys table dual role
-- ──────────────────────────────────────────────────────────────────────
-- 1. TRIGGER  (lazy plugins only, before load)
--    A stub keymap intercepts the first keypress, loads the plugin,
--    deletes itself, then re-feeds the lhs so the real handler fires.
--
-- 2. REAL KEYMAP  (all plugins, after load)
--    If the entry supplies an rhs, weaver registers the actual keymap
--    via register_keymaps() once the plugin is live.
-- ──────────────────────────────────────────────────────────────────────

local util = require("weaver.util")

local M = {}

local _loaded = {} ---@type table<string, true>

-- ── Key-spec normalisation ─────────────────────────────────────────────

---@class WeaverKeySpec
---@field lhs     string
---@field rhs     string|function|nil
---@field modes   string[]
---@field desc    string|nil
---@field silent  boolean
---@field noremap boolean
---@field expr    boolean
---@field buffer  integer|boolean|nil

---@param raw string|table
---@return WeaverKeySpec|nil
local function normalise_key(raw)
  if type(raw) == "string" then
    return { lhs = raw, rhs = nil, modes = { "n" },
             desc = nil, silent = true, noremap = true, expr = false, buffer = nil }
  end

  if type(raw) ~= "table" or not raw[1] then
    vim.notify(
      "[weaver] Invalid key spec (must be string or table with lhs as [1]): "
        .. vim.inspect(raw),
      vim.log.levels.WARN
    )
    return nil
  end

  -- Resolve modes once at normalisation time
  local modes
  local raw_mode = raw.mode
  if type(raw_mode) == "table" then
    modes = raw_mode
  elseif type(raw_mode) == "string" then
    -- "nv" shorthand → split into chars; comma-list → split by comma
    if #raw_mode > 1 and not raw_mode:find(",", 1, true) then
      modes = {}
      for i = 1, #raw_mode do modes[i] = raw_mode:sub(i, i) end
    else
      modes = vim.split(raw_mode, ",", { plain = true, trimempty = true })
    end
  else
    modes = { "n" }
  end

  return {
    lhs     = raw[1],
    rhs     = raw[2],
    modes   = modes,
    desc    = raw.desc,
    silent  = raw.silent  ~= false,
    noremap = raw.noremap ~= false,
    expr    = raw.expr    == true,
    buffer  = raw.buffer,
  }
end

-- ── Pre-normalise keys list once per spec ──────────────────────────────

--- Returns a list of WeaverKeySpec, normalised exactly once.
--- Caches the result on the spec table itself to avoid redundant work.
---@param spec WeaverSpec
---@return WeaverKeySpec[]
local function get_normalised_keys(spec)
  if spec._norm_keys then return spec._norm_keys end
  local out = {}
  for _, raw_key in ipairs(spec.keys) do
    local k = normalise_key(raw_key)
    if k then out[#out + 1] = k end
  end
  spec._norm_keys = out   -- cache on spec (private field, underscore convention)
  return out
end

-- ── Real keymap registration ───────────────────────────────────────────

--- Register all declared keymaps from spec.keys that have an explicit rhs.
---@param spec WeaverSpec
function M.register_keymaps(spec)
  if not spec.keys or #spec.keys == 0 then return end

  for _, key in ipairs(get_normalised_keys(spec)) do
    if key.rhs == nil then goto continue end   -- pure trigger / doc entry

    local map_opts = {
      desc    = key.desc,
      silent  = key.silent,
      noremap = key.noremap,
      expr    = key.expr,
    }
    if key.buffer ~= nil then map_opts.buffer = key.buffer end

    for _, mode in ipairs(key.modes) do
      local ok, err = pcall(vim.keymap.set, mode, key.lhs, key.rhs, map_opts)
      if not ok then
        vim.notify(
          ("[weaver] Failed to register keymap '%s' for '%s': %s")
            :format(key.lhs, spec.name, err),
          vim.log.levels.WARN
        )
      end
    end

    ::continue::
  end
end

-- ── Core load ──────────────────────────────────────────────────────────

-- Forward-declare to allow do_load to reference the registry lazily
local _weaver_init  -- resolved on first use to avoid circular require at module load

local function get_registry()
  if not _weaver_init then _weaver_init = require("weaver.init") end
  return _weaver_init._registry
end

---@param spec WeaverSpec
local function do_load(spec)
  if _loaded[spec.name] then return end
  _loaded[spec.name] = true

  -- Deps first (already flattened by spec.parse_all, but guard for runtime adds)
  for _, dep in ipairs(spec.deps or {}) do
    if not _loaded[dep.name] then do_load(dep) end
  end

  -- Activate
  if spec.dir then
    vim.opt.runtimepath:append(spec.dir)
    if vim.uv.fs_stat(spec.dir .. "/after") then
      vim.opt.runtimepath:append(spec.dir .. "/after")
    end
    -- Source plugin scripts
    local plugin_files = vim.fn.glob(spec.dir .. "/plugin/**/*.{vim,lua}", false, true)
    for _, f in ipairs(plugin_files) do
      vim.cmd("source " .. f)
    end
  else
    local ok, err = pcall(vim.cmd.packadd, spec.name)
    if not ok then
      vim.notify(
        ("[weaver] packadd failed for '%s': %s"):format(spec.name, err),
        vim.log.levels.ERROR
      )
      return
    end
  end

  if spec.config then
    util.safe_call(function() spec.config(spec) end, spec.name .. ".config")
  end

  -- Register real keymaps after config (user declarations override plugin maps)
  M.register_keymaps(spec)
end

-- ── Public load ─────────────────────────────────────────────────────────

---@param name string
function M.load(name)
  local spec = get_registry()[name]
  if not spec then
    vim.notify("[weaver] Unknown plugin: " .. name, vim.log.levels.WARN)
    return
  end
  do_load(spec)
end

-- ── Lazy triggers ──────────────────────────────────────────────────────

---@param spec WeaverSpec
function M.register_triggers(spec)
  local name = spec.name

  -- Event
  if #spec.event > 0 then
    vim.api.nvim_create_autocmd(spec.event, {
      group    = vim.api.nvim_create_augroup("weaver_event_" .. name, { clear = true }),
      once     = true,
      callback = function(ev)
        do_load(spec)
        if ev.event ~= "VimEnter" and ev.event ~= "UIEnter" then
          pcall(vim.api.nvim_exec_autocmds, ev.event, {
            buffer   = ev.buf,
            data     = ev.data,
            modeline = false,
          })
        end
      end,
    })
  end

  -- FileType
  if #spec.ft > 0 then
    vim.api.nvim_create_autocmd("FileType", {
      pattern  = spec.ft,
      group    = vim.api.nvim_create_augroup("weaver_ft_" .. name, { clear = true }),
      once     = true,
      callback = function(ev)
        do_load(spec)
        vim.api.nvim_exec_autocmds("FileType", { buffer = ev.buf, modeline = false })
      end,
    })
  end

  -- Command — reuse a shared stub factory to keep closures small
  for _, cmd in ipairs(spec.cmd) do
    local _cmd = cmd   -- capture once per iteration
    vim.api.nvim_create_user_command(_cmd, function(args)
      vim.api.nvim_del_user_command(_cmd)
      do_load(spec)
      local call = _cmd .. (args.bang and "!" or "")
      if args.args ~= "" then call = call .. " " .. args.args end
      pcall(vim.cmd, call)
    end, {
      nargs = "*",
      bang  = true,
      desc  = "[weaver] lazy-load stub for " .. name,
    })
  end

  -- Keys — use pre-normalised list; build stub closure once per lhs/mode pair
  for _, key in ipairs(get_normalised_keys(spec)) do
    local lhs      = key.lhs
    local term_lhs = vim.api.nvim_replace_termcodes(lhs, true, false, true)

    for _, mode in ipairs(key.modes) do
      vim.keymap.set(mode, lhs, function()
        pcall(vim.keymap.del, mode, lhs)
        do_load(spec)
        vim.api.nvim_feedkeys(term_lhs, "m", false)
      end, {
        desc   = key.desc or ("[weaver] load " .. name),
        silent = true,
      })
    end
  end
end

-- ── Build hooks ────────────────────────────────────────────────────────

---@param spec WeaverSpec
function M.register_build_hook(spec)
  if not spec.build then return end

  -- Cache build type check outside the autocmd closure
  local build      = spec.build
  local build_type = type(build)
  local is_cmd     = build_type == "string" and build:sub(1, 1) == ":"
  local build_args = is_cmd and nil or (build_type == "string" and vim.split(build, " "))

  vim.api.nvim_create_autocmd("PackChanged", {
    group    = vim.api.nvim_create_augroup("weaver_build_" .. spec.name, { clear = true }),
    callback = function(ev)
      if ev.data.spec.name ~= spec.name then return end
      if ev.data.kind ~= "install" and ev.data.kind ~= "update" then return end

      if build_type == "function" then
        util.safe_call(build, spec.name .. ".build")
      elseif is_cmd then
        if not ev.data.active then vim.cmd.packadd(spec.name) end
        util.safe_call(
          function() vim.cmd(build:sub(2)) end,
          spec.name .. ".build_cmd"
        )
      else
        vim.system(build_args, { cwd = ev.data.path })
      end
    end,
  })
end

return M
