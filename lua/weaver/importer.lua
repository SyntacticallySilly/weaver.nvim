-- lua/weaver/importer.lua
--
-- Resolves { import = "..." } entries in the raw spec list into concrete
-- plugin spec tables by discovering and executing Lua files on disk.
--
-- Three import forms:
--  1. Lua module path  { import = "plugins" }
--  2. Absolute filesystem path  { import = "/home/user/.config/nvim/plugins" }
--  3. Home-relative path  { import = "~/dotfiles/nvim/plugins" }

local util = require("weaver.util")

local M = {}

-- ── Helpers ────────────────────────────────────────────────────────────

---@param modname string
---@return string
local function mod_to_relpath(modname)
  return (modname:gsub("%.", "/"))   -- extra parens discard second return
end

---@param s string
---@return boolean
local function is_fs_path(s)
  local c = s:sub(1, 1)
  if c == "/" then return true end
  local two = s:sub(1, 2)
  return two == "~/" or two == "~\\"
end

--- Recursively collect every *.lua file under `dir`, sorted deterministically.
---@param dir string
---@return string[]
local function collect_lua_files(dir)
  local files = {}

  local function scan(path)
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end

    local entries = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      entries[#entries + 1] = { name = name, ftype = ftype }
    end

    -- Dirs first (grouped), then by name — stable across platforms
    table.sort(entries, function(a, b)
      if a.ftype == b.ftype then return a.name < b.name end
      return a.ftype == "directory"
    end)

    local sep = path .. "/"
    for _, entry in ipairs(entries) do
      local full = sep .. entry.name
      if entry.ftype == "directory" then
        scan(full)
      elseif entry.ftype == "file" and entry.name:sub(-4) == ".lua" then
        files[#files + 1] = full
      end
    end
  end

  scan(dir)
  return files
end

-- ── File loading ────────────────────────────────────────────────────────

---@param modname string
---@return any
local function load_by_module(modname)
  package.loaded[modname] = nil   -- allow re-sourcing on :Weaver refresh
  local ok, result = pcall(require, modname)
  if not ok then
    vim.notify(
      ("[weaver/import] Failed to load module '%s':\n  %s"):format(modname, result),
      vim.log.levels.ERROR
    )
    return nil
  end
  return result
end

---@param path string
---@return any
local function load_by_path(path)
  local fn, err = loadfile(path)
  if not fn then
    vim.notify(
      ("[weaver/import] Failed to parse '%s':\n  %s"):format(path, err),
      vim.log.levels.ERROR
    )
    return nil
  end
  local ok, result = pcall(fn)
  if not ok then
    vim.notify(
      ("[weaver/import] Runtime error in '%s':\n  %s"):format(path, result),
      vim.log.levels.ERROR
    )
    return nil
  end
  return result
end

-- ── Normalisation ───────────────────────────────────────────────────────

---@param value any
---@return table[]
local function normalize_to_list(value)
  if value == nil or value == false then return {} end

  if type(value) == "string" then return { { value } } end

  if type(value) ~= "table" then
    vim.notify(
      "[weaver/import] Spec file returned unexpected type: " .. type(value),
      vim.log.levels.WARN
    )
    return {}
  end

  -- Single-spec heuristic: [1] is a non-path string, or no [1] but has src keys
  local v1 = value[1]
  local is_single = (type(v1) == "string" and not is_fs_path(v1))
    or (v1 == nil and (value.src or value.url or value.dir or value.import))

  if is_single then return { value } end

  -- List of specs — filter out nils
  local result = {}
  for _, item in ipairs(value) do
    if item ~= nil then result[#result + 1] = item end
  end
  return result
end

-- ── Core expansion ──────────────────────────────────────────────────────

local expand_raw_list -- forward declaration

---@param raw any
---@return table[]
local function expand_one(raw)
  if type(raw) == "string" then return { raw } end
  if type(raw) ~= "table"  then return {} end
  if raw.import              then return M.resolve_import(raw.import, raw) end
  return { raw }
end

expand_raw_list = function(raws)
  local out = {}
  for _, raw in ipairs(raws) do
    for _, item in ipairs(expand_one(raw)) do
      out[#out + 1] = item
    end
  end
  return out
end

-- ── Public API ──────────────────────────────────────────────────────────

---@param target       string
---@param import_opts  table|nil
---@return table[]
function M.resolve_import(target, import_opts)
  import_opts = import_opts or {}

  -- Collect extra merge fields once, outside the inner loop
  local extra     = {}
  local has_extra = false
  for k, v in pairs(import_opts) do
    if k ~= "import" then
      extra[k]  = v
      has_extra = true
    end
  end

  local collected = {}

  if is_fs_path(target) then
    -- ── Filesystem path ────────────────────────────────────────────
    local abs_dir = vim.fn.expand(target)
    local stat    = vim.uv.fs_stat(abs_dir)
    if not stat then
      vim.notify(
        ("[weaver/import] Path does not exist: '%s'"):format(abs_dir),
        vim.log.levels.WARN
      )
      return {}
    end

    if stat.type == "file" then
      collected[1] = { path = abs_dir, result = load_by_path(abs_dir) }
    else
      for _, file in ipairs(collect_lua_files(abs_dir)) do
        collected[#collected + 1] = { path = file, result = load_by_path(file) }
      end
    end
  else
    -- ── Lua module name ────────────────────────────────────────────
    local reldir    = mod_to_relpath(target)
    local rtp       = vim.api.nvim_list_runtime_paths()   -- fetch once
    local found_any = false

    for _, rtp_dir in ipairs(rtp) do
      local lua_dir = rtp_dir .. "/lua/" .. reldir
      local stat    = vim.uv.fs_stat(lua_dir)
      if not stat then goto next_rtp end

      found_any = true

      if stat.type == "file" then
        -- Single-file module
        collected[#collected + 1] = { mod = target, result = load_by_module(target) }
      elseif stat.type == "directory" then
        -- Pre-compute the prefix to strip once per rtp dir
        local lua_prefix = rtp_dir .. "/lua/"
        local prefix_len = #lua_prefix

        for _, file in ipairs(collect_lua_files(lua_dir)) do
          local rel     = file:sub(prefix_len + 1):gsub("%.lua$", "")
          local modname = rel:gsub("/", ".")
          collected[#collected + 1] = { mod = modname, result = load_by_module(modname) }
        end
      end

      ::next_rtp::
    end

    if not found_any then
      local result = load_by_module(target)
      if result then
        collected[1] = { mod = target, result = result }
      else
        vim.notify(
          ("[weaver/import] Module '%s' not found in runtimepath"):format(target),
          vim.log.levels.WARN
        )
      end
    end
  end

  -- ── Flatten + merge extra fields ─────────────────────────────────
  local raw_specs = {}
  for _, item in ipairs(collected) do
    for _, spec in ipairs(normalize_to_list(item.result)) do
      if has_extra and type(spec) == "table" then
        spec = vim.tbl_extend("keep", spec, extra)
      end
      raw_specs[#raw_specs + 1] = spec
    end
  end

  return expand_raw_list(raw_specs)
end

---@param raws table[]
---@return table[]
function M.expand(raws)
  return expand_raw_list(raws)
end

return M
