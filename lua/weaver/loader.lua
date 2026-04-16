-- lua/weaver/loader.lua
-- Lazy-loading engine + real keymap registration.
--
-- Keys table dual role
-- ─────────────────────────────────────────────────────────────────────
-- Every entry in spec.keys has two independent jobs:
--
--   1. TRIGGER  (lazy plugins only, before load)
--      A stub keymap intercepts the first keypress, loads the plugin,
--      deletes itself, then re-feeds the lhs so the real handler fires.
--
--   2. REAL KEYMAP  (all plugins, after load)
--      If the entry supplies an rhs, weaver registers the actual keymap
--      via register_keymaps() once the plugin is live.
--      Entries with only an lhs (no rhs) are pure triggers / docs.
--
-- When lazy = false the trigger stubs are never created (spec.keys is
-- passed through to register_keymaps() only).
-- ─────────────────────────────────────────────────────────────────────

local util = require("weaver.util")

local M = {}

local _loaded = {} ---@type table<string, boolean>

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

--- Normalise a raw keys entry (string or table) into a WeaverKeySpec.
---@param raw string|table
---@return WeaverKeySpec|nil
local function normalise_key(raw)
  if type(raw) == "string" then
    return {
      lhs     = raw,
      rhs     = nil,
      modes   = { "n" },
      desc    = nil,
      silent  = true,
      noremap = true,
      expr    = false,
      buffer  = nil,
    }
  end

  if type(raw) ~= "table" or not raw[1] then
    vim.notify(
      "[weaver] Invalid key spec (must be string or table with lhs as [1]): "
        .. vim.inspect(raw),
      vim.log.levels.WARN
    )
    return nil
  end

  -- mode can be a string "n", "v", "i", ... or a list { "n", "v" }
  local modes
  if type(raw.mode) == "table" then
    modes = raw.mode
  elseif type(raw.mode) == "string" then
    -- support "nv" shorthand as well as single chars
    if #raw.mode > 1 and not raw.mode:match(",") then
      modes = {}
      for char in raw.mode:gmatch(".") do table.insert(modes, char) end
    else
      modes = vim.split(raw.mode, ",", { plain = true, trimempty = true })
    end
  else
    modes = { "n" }
  end

  return {
    lhs     = raw[1],
    rhs     = raw[2],
    modes   = modes,
    desc    = raw.desc,
    silent  = raw.silent  ~= false,   -- default true
    noremap = raw.noremap ~= false,   -- default true
    expr    = raw.expr    == true,    -- default false
    buffer  = raw.buffer,             -- nil = global
  }
end

-- ── Real keymap registration ───────────────────────────────────────────

--- Register all declared keymaps from spec.keys that have an explicit rhs.
--- Called after every plugin load (lazy and eager paths).
--- Entries with no rhs are pure trigger-docs and are skipped.
---@param spec WeaverSpec
function M.register_keymaps(spec)
  if not spec.keys or #spec.keys == 0 then return end

  for _, raw_key in ipairs(spec.keys) do
    local key = normalise_key(raw_key)
    if not key then goto continue end

    -- No rhs → pure lazy trigger / documentation entry, nothing to register
    if key.rhs == nil then goto continue end

    local map_opts = {
      desc    = key.desc,
      silent  = key.silent,
      noremap = key.noremap,
      expr    = key.expr,
    }
    if key.buffer ~= nil then
      map_opts.buffer = key.buffer
    end

    for _, mode in ipairs(key.modes) do
      -- Always honour the user's explicit declaration.
      -- If the plugin itself already registered the same lhs that is fine —
      -- the user's rhs takes precedence (they put it in the spec intentionally).
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

--- Activate a plugin, run its config, then register its declared keymaps.
--- Idempotent — repeated calls for the same plugin are no-ops.
---@param spec WeaverSpec
local function do_load(spec)
  if _loaded[spec.name] then return end
  _loaded[spec.name] = true

  -- Deps first
  for _, dep in ipairs(spec.deps or {}) do
    if not _loaded[dep.name] then do_load(dep) end
  end

  -- Activate
  if spec.dir then
    vim.opt.runtimepath:append(spec.dir)
    if vim.uv.fs_stat(spec.dir .. "/after") then
      vim.opt.runtimepath:append(spec.dir .. "/after")
    end
    for _, f in ipairs(
      vim.fn.glob(spec.dir .. "/plugin/**/*.{vim,lua}", false, true)
    ) do
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

  -- Config
  if spec.config then
    util.safe_call(function() spec.config(spec) end, spec.name .. ".config")
  end

  -- Real keymaps (runs after config so plugin-set maps are already in place;
  -- user declarations then override where they conflict)
  M.register_keymaps(spec)
end

-- ── Public load (called by :Weaver 'l' keymap and weaver.load()) ────────

---@param name string
function M.load(name)
  local spec = require("weaver.init")._registry[name]
  if not spec then
    vim.notify("[weaver] Unknown plugin: " .. name, vim.log.levels.WARN)
    return
  end
  do_load(spec)
end

-- ── Lazy triggers ──────────────────────────────────────────────────────

--- Wire all lazy-load triggers for a spec.
--- Only called for specs where lazy = true.
--- spec.event / spec.ft / spec.cmd are already empty when lazy = false
--- (zeroed in spec.lua), so this function is safe to call unconditionally,
--- but init.lua only invokes it when spec.lazy = true anyway.
---@param spec WeaverSpec
function M.register_triggers(spec)
  local name = spec.name

  -- ── Event ──────────────────────────────────────────────────────────
  if #spec.event > 0 then
    vim.api.nvim_create_autocmd(spec.event, {
      group   = vim.api.nvim_create_augroup("weaver_event_" .. name, { clear = true }),
      once    = true,
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

  -- ── FileType ───────────────────────────────────────────────────────
  if #spec.ft > 0 then
    vim.api.nvim_create_autocmd("FileType", {
      pattern  = spec.ft,
      group    = vim.api.nvim_create_augroup("weaver_ft_" .. name, { clear = true }),
      once     = true,
      callback = function(ev)
        do_load(spec)
        vim.api.nvim_exec_autocmds("FileType", {
          buffer   = ev.buf,
          modeline = false,
        })
      end,
    })
  end

  -- ── Command ────────────────────────────────────────────────────────
  for _, cmd in ipairs(spec.cmd) do
    vim.api.nvim_create_user_command(cmd, function(args)
      vim.api.nvim_del_user_command(cmd)
      do_load(spec)
      local call = cmd .. (args.bang and "!" or "")
      if args.args and args.args ~= "" then
        call = call .. " " .. args.args
      end
      pcall(vim.cmd, call)
    end, {
      nargs = "*",
      bang  = true,
      desc  = "[weaver] lazy-load stub for " .. name,
    })
  end

  -- ── Keys ───────────────────────────────────────────────────────────
  -- For lazy plugins each key entry gets a STUB keymap that:
  --   1. Deletes itself
  --   2. Calls do_load() — which runs config AND register_keymaps() inside
  --   3. Re-feeds the original lhs so the now-registered real map fires,
  --      OR directly invokes rhs if the user supplied one without wanting
  --      a plugin-provided binding to take over.
  for _, raw_key in ipairs(spec.keys) do
    local key = normalise_key(raw_key)
    if not key then goto continue end

    for _, mode in ipairs(key.modes) do
      vim.keymap.set(mode, key.lhs, function()
        -- Remove the stub first so do_load's register_keymaps (or the
        -- plugin itself) can claim the lhs cleanly.
        pcall(vim.keymap.del, mode, key.lhs)

        do_load(spec)

        -- After load:
        --   • If user gave an rhs, register_keymaps() already set it.
        --     Re-feed lhs so it fires naturally (handles both string and
        --     function rhs uniformly).
        --   • If no rhs, the plugin should have set the map; re-feed lhs.
        -- Either way, re-feeding lhs is the correct action.
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(key.lhs, true, false, true),
          "m",
          false
        )
      end, {
        desc   = key.desc or ("[weaver] load " .. name),
        silent = true,
      })
    end

    ::continue::
  end
end

-- ── Build hooks ────────────────────────────────────────────────────────

---@param spec WeaverSpec
function M.register_build_hook(spec)
  if not spec.build then return end
  vim.api.nvim_create_autocmd("PackChanged", {
    group    = vim.api.nvim_create_augroup("weaver_build_" .. spec.name, { clear = true }),
    callback = function(ev)
      if ev.data.spec.name ~= spec.name then return end
      if ev.data.kind ~= "install" and ev.data.kind ~= "update" then return end
      if type(spec.build) == "function" then
        util.safe_call(spec.build, spec.name .. ".build")
      elseif type(spec.build) == "string" then
        if spec.build:sub(1, 1) == ":" then
          if not ev.data.active then vim.cmd.packadd(spec.name) end
          util.safe_call(
            function() vim.cmd(spec.build:sub(2)) end,
            spec.name .. ".build_cmd"
          )
        else
          vim.system(vim.split(spec.build, " "), { cwd = ev.data.path })
        end
      end
    end,
  })
end

return M
