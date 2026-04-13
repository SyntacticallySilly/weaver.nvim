-- lua/weaver/loader.lua
-- Lazy-loading engine: wires events, filetypes, commands and keymaps
-- to deferred plugin loading via :packadd.

local util = require("weaver.util")

local M = {}

-- Track which plugins have been loaded already.
local _loaded = {} ---@type table<string, boolean>

--- Actually load a plugin: packadd + run its config.
---@param spec WeaverSpec
local function do_load(spec)
  if _loaded[spec.name] then return end
  _loaded[spec.name] = true

  -- Load dependencies first
  for _, dep in ipairs(spec.deps or {}) do
    if not _loaded[dep.name] then
      do_load(dep)
    end
  end

  -- For local plugins add dir to rtp directly; for managed ones use packadd
  if spec.dir then
    vim.opt.runtimepath:append(spec.dir)
    vim.opt.runtimepath:append(spec.dir .. "/after")
    -- Source plugin files manually
    for _, f in ipairs(vim.fn.glob(spec.dir .. "/plugin/**/*.{vim,lua}", false, true)) do
      vim.cmd("source " .. f)
    end
  else
    -- vim.pack already placed plugin in opt/ — just activate it
    local ok, err = pcall(vim.cmd.packadd, spec.name)
    if not ok then
      vim.notify(("[weaver] packadd failed for '%s': %s"):format(spec.name, err),
        vim.log.levels.ERROR)
      return
    end
  end

  -- Run user config
  if spec.config then
    util.safe_call(function() spec.config(spec) end, spec.name .. ".config")
  end
end

--- Public: load a plugin by name immediately.
---@param name string
function M.load(name)
  local registry = require("weaver.init")._registry
  local spec = registry[name]
  if not spec then
    vim.notify("[weaver] Unknown plugin: " .. name, vim.log.levels.WARN)
    return
  end
  do_load(spec)
end

--- Wire lazy triggers for a spec. Called once per spec during setup.
---@param spec WeaverSpec
function M.register_triggers(spec)
  local name = spec.name

  -- ── Event-based loading ────────────────────────────────────────────
  if #spec.event > 0 then
    vim.api.nvim_create_autocmd(spec.event, {
      group    = vim.api.nvim_create_augroup("weaver_event_" .. name, { clear = true }),
      once     = true,
      callback = function(ev)
        do_load(spec)
        -- Re-fire the event so the just-loaded plugin can react to it
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

  -- ── FileType-based loading ─────────────────────────────────────────
  if #spec.ft > 0 then
    vim.api.nvim_create_autocmd("FileType", {
      pattern  = spec.ft,
      group    = vim.api.nvim_create_augroup("weaver_ft_" .. name, { clear = true }),
      once     = true,
      callback = function(ev)
        do_load(spec)
        -- Re-trigger FileType so ftplugin/syntax from the plugin fires
        vim.api.nvim_exec_autocmds("FileType", {
          buffer   = ev.buf,
          modeline = false,
        })
      end,
    })
  end

  -- ── Command-based loading ──────────────────────────────────────────
  for _, cmd in ipairs(spec.cmd) do
    -- Create a stub command that loads the plugin then re-runs the command
    vim.api.nvim_create_user_command(cmd, function(args)
      vim.api.nvim_del_user_command(cmd)
      do_load(spec)
      -- Re-execute the original command with original arguments
      local bang = args.bang and "!" or ""
      local call = cmd .. bang
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

  -- ── Keymap-based loading ───────────────────────────────────────────
  for _, key_spec in ipairs(spec.keys) do
    -- key_spec may be: string lhs, or { lhs, rhs, mode=, desc= }
    local lhs, rhs, modes, desc
    if type(key_spec) == "string" then
      lhs   = key_spec
      rhs   = nil
      modes = { "n" }
      desc  = "[weaver] load " .. name
    else
      lhs   = key_spec[1]
      rhs   = key_spec[2]
      modes = type(key_spec.mode) == "table" and key_spec.mode
          or { key_spec.mode or "n" }
      desc  = key_spec.desc or ("[weaver] load " .. name)
    end

    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, lhs, function()
        -- Delete stub, load plugin, then replay the real keymap or rhs
        vim.keymap.del(mode, lhs)
        do_load(spec)
        if rhs then
          local feed = type(rhs) == "function"
              and rhs()
              or vim.api.nvim_replace_termcodes(rhs, true, false, true)
          if feed then vim.api.nvim_feedkeys(feed, "m", false) end
        else
          -- Re-feed the original lhs so the now-loaded plugin handles it
          vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(lhs, true, false, true), "m", false)
        end
      end, { desc = desc, silent = true })
    end
  end
end

--- Register a PackChanged autocmd for build hooks.
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
          -- Neovim command
          if not ev.data.active then vim.cmd.packadd(spec.name) end
          util.safe_call(function() vim.cmd(spec.build:sub(2)) end, spec.name .. ".build_cmd")
        else
          -- Shell command
          vim.system(vim.split(spec.build, " "), { cwd = ev.data.path })
        end
      end
    end,
  })
end

return M
