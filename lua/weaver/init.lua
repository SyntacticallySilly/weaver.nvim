-- lua/weaver/init.lua
local spec_parser = require("weaver.spec")
local loader      = require("weaver.loader")
local ui          = require("weaver.ui")
local util        = require("weaver.util")

local M = {}

M._registry = {} ---@type table<string, WeaverSpec>
M._specs    = {} ---@type WeaverSpec[]

local defaults = {
  auto_install = true,
  notify_level = vim.log.levels.INFO,
  icons = {
    loaded   = "●",
    unloaded = "○",
    disabled = "✗",
    update   = "↑",
    lazy     = "⚡",
  },
}

M.options = {}

-- Build the vim.pack spec list in a single pass, skipping local plugins
local function bootstrap_pack(specs)
  local pack_list = {}
  for _, spec in ipairs(specs) do
    if not spec.dir then
      local entry = { src = spec.src }
      if spec.version then entry.version = spec.version end
      if spec.name    then entry.name    = spec.name    end
      pack_list[#pack_list + 1] = entry
    end
  end
  if #pack_list > 0 then vim.pack.add(pack_list) end
end

local function run_init_hooks(specs)
  for _, spec in ipairs(specs) do
    if spec.init then
      util.safe_call(spec.init, spec.name .. ".init")
    end
  end
end

local function load_eager(specs)
  -- specs is already priority-sorted by spec.parse_all
  for _, spec in ipairs(specs) do
    if spec.lazy then goto continue end

    if spec.dir then
      vim.opt.runtimepath:prepend(spec.dir)
      if vim.uv.fs_stat(spec.dir .. "/after") then
        vim.opt.runtimepath:append(spec.dir .. "/after")
      end
    else
      local ok, err = pcall(vim.cmd.packadd, spec.name)
      if not ok then
        vim.notify(
          ("[weaver] packadd failed for '%s': %s"):format(spec.name, err),
          vim.log.levels.WARN
        )
      end
    end

    if spec.config then
      util.safe_call(function() spec.config(spec) end, spec.name .. ".config")
    end

    loader.register_keymaps(spec)
    ::continue::
  end
end

local function register_lazy(specs)
  for _, spec in ipairs(specs) do
    if spec.lazy then loader.register_triggers(spec) end
    loader.register_build_hook(spec)
  end
end

function M.setup(raw_specs, opts)
  M.options = util.merge(defaults, opts or {})

  local specs = spec_parser.parse_all(raw_specs)
  M._specs    = specs

  for _, spec in ipairs(specs) do
    M._registry[spec.name] = spec
  end

  bootstrap_pack(specs)
  run_init_hooks(specs)
  load_eager(specs)
  register_lazy(specs)
end

function M.open()
  ui.open(M._specs)
end

function M.add(raw_specs)
  local new_specs = spec_parser.parse_all(raw_specs)
  for _, spec in ipairs(new_specs) do
    if not M._registry[spec.name] then
      M._registry[spec.name]        = spec
      M._specs[#M._specs + 1]       = spec
    end
  end
  bootstrap_pack(new_specs)
  run_init_hooks(new_specs)
  load_eager(new_specs)
  register_lazy(new_specs)
end

function M.update(names)
  local targets = names or vim.tbl_keys(M._registry)
  targets = vim.tbl_filter(function(n)
    return M._registry[n] and not M._registry[n].dir
  end, targets)
  vim.pack.update(targets)
end

function M.del(name)
  if M._registry[name] then
    M._registry[name] = nil
    M._specs = vim.tbl_filter(function(s) return s.name ~= name end, M._specs)
  end
  vim.pack.del({ name })
end

return M
