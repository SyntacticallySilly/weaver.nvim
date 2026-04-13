-- lua/weaver/importer.lua
--
-- Resolves { import = "..." } entries in the raw spec list into concrete
-- plugin spec tables by discovering and executing Lua files on disk.
--
-- Three import forms are supported:
--
--  1. Lua module path  { import = "plugins" }
--       Resolved via runtimepath: every *.lua file found under
--       <rtp>/lua/plugins/**/*.lua is loaded with require().
--       Dot-notation sub-modules also work: { import = "plugins.editor" }
--
--  2. Absolute filesystem path  { import = "/home/user/.config/nvim/plugins" }
--       Every *.lua file in that directory tree is loaded with loadfile().
--
--  3. Home-relative path  { import = "~/dotfiles/nvim/plugins" }
--       Expanded with vim.fn.expand() then treated as case 2.
--
-- Each discovered file must return one of:
--   • A single spec table  →  treated as one spec
--   • A list of spec tables → each element treated as one spec
--   • nil / false           → silently ignored (allows conditional files)
--
-- Nested { import = ... } entries returned by a file are also expanded
-- recursively, so spec files can themselves import sub-directories.

local util = require("weaver.util")

local M = {}

-- ── Helpers ────────────────────────────────────────────────────────────

--- Convert a dot-notation Lua module name to a relative file path.
--- "plugins.editor"  →  "plugins/editor"
---@param modname string
---@return string
local function mod_to_relpath(modname)
  return modname:gsub("%.", "/")
end

--- Detect whether a string looks like an explicit filesystem path
--- (absolute or home-relative) rather than a Lua module name.
---@param s string
---@return boolean
local function is_fs_path(s)
  return s:sub(1, 1) == "/" or s:sub(1, 2) == "~/" or s:sub(1, 2) == "~\\"
end

--- Recursively collect every *.lua file under `dir`, sorted alphabetically
--- so loading order is deterministic across all platforms.
---@param dir string   Absolute directory path
---@return string[]    Sorted list of absolute file paths
local function collect_lua_files(dir)
  local files = {}

  local function scan(path)
    local handle = vim.uv.fs_scandir(path)
    if not handle then return end

    -- Collect entries first so we can sort them before recursing
    local entries = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      table.insert(entries, { name = name, ftype = ftype })
    end

    -- Sort: directories first (so nested imports stay grouped), then files
    table.sort(entries, function(a, b)
      if a.ftype == b.ftype then return a.name < b.name end
      return a.ftype == "directory"
    end)

    for _, entry in ipairs(entries) do
      local full = path .. "/" .. entry.name
      if entry.ftype == "directory" then
        scan(full) -- recurse
      elseif entry.ftype == "file" and entry.name:match("%.lua$") then
        table.insert(files, full)
      end
    end
  end

  scan(dir)
  return files
end

-- ── File loading ────────────────────────────────────────────────────────

--- Load a spec file via `require()` (Lua module path variant).
--- Returns whatever the module returns, or nil on error.
---@param modname string   Full dot-notation module name, e.g. "plugins.editor"
---@return any
local function load_by_module(modname)
  -- Wipe the module cache so re-sourcing works after :Weaver refresh
  package.loaded[modname] = nil
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

--- Load a spec file via `loadfile()` (filesystem path variant).
--- Returns whatever the file returns, or nil on error.
---@param path string   Absolute path to a .lua file
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

--- Ensure `value` is a flat list of raw spec tables.
--- Handles: nil, a single spec table, a list of spec tables.
---@param value any
---@return table[]
local function normalize_to_list(value)
  if value == nil or value == false then return {} end

  -- A plain string shorthand like "user/repo" – wrap it
  if type(value) == "string" then
    return { { value } }
  end

  if type(value) ~= "table" then
    vim.notify(
      "[weaver/import] Spec file returned unexpected type: " .. type(value),
      vim.log.levels.WARN
    )
    return {}
  end

  -- Distinguish { "user/repo", lazy = true, ... }  (single spec with string [1])
  -- from  { { "a/b" }, { "c/d" } }  (list of specs)
  --
  -- Heuristic: if [1] is a string that looks like a source *and* the table
  -- has no numeric keys beyond [1], treat it as a single spec.
  -- Otherwise treat it as a list.
  local is_single = false
  if type(value[1]) == "string" and not is_fs_path(value[1]) then
    -- Looks like { "user/repo", event = "..." }
    is_single = true
  elseif value[1] == nil and (value.src or value.url or value.dir or value.import) then
    -- Looks like { src = "...", event = "..." }  or  { import = "..." }
    is_single = true
  end

  if is_single then
    return { value }
  end

  -- It's a list – flatten one level (each element may be a spec or nil)
  local result = {}
  for _, item in ipairs(value) do
    if item ~= nil then
      table.insert(result, item)
    end
  end
  return result
end

-- ── Core expansion (forward declaration for recursion) ──────────────────

local expand_raw_list -- declared here, defined below

--- Expand a single raw entry.  If it is an import directive resolve it;
--- otherwise return it unchanged (it is a plain spec).
---@param raw any
---@return table[]   Zero or more concrete raw spec tables
local function expand_one(raw)
  -- Plain string shorthand – not an import
  if type(raw) == "string" then return { raw } end
  if type(raw) ~= "table" then return {} end

  -- ── Import directive ─────────────────────────────────────────────────
  if raw.import then
    return M.resolve_import(raw.import, raw)
  end

  -- ── Regular spec – pass through unchanged ────────────────────────────
  return { raw }
end

--- Expand a raw spec list, resolving all import directives recursively.
---@param raws table[]
---@return table[]
expand_raw_list = function(raws)
  local out = {}
  for _, raw in ipairs(raws) do
    local expanded = expand_one(raw)
    for _, item in ipairs(expanded) do
      table.insert(out, item)
    end
  end
  return out
end

-- ── Public API ──────────────────────────────────────────────────────────

--- Resolve an import directive to a flat list of raw spec tables.
---
--- `import_opts` is the full raw table that contained the `import` key,
--- e.g. `{ import = "plugins", enabled = false }`.  Any extra keys are
--- merged onto every spec produced by this import (useful for disabling a
--- whole directory in one line).
---
---@param target       string       The import value ("plugins", "~/path", …)
---@param import_opts  table|nil    The parent { import = … } table itself
---@return table[]
function M.resolve_import(target, import_opts)
  import_opts = import_opts or {}

  -- Extra fields to merge onto every produced spec (exclude `import` itself)
  local extra = {}
  for k, v in pairs(import_opts) do
    if k ~= "import" then extra[k] = v end
  end
  local has_extra = next(extra) ~= nil

  local collected = {} -- raw file results before flattening

  -- ── Case A: filesystem path ──────────────────────────────────────────
  if is_fs_path(target) then
    local abs_dir = vim.fn.expand(target)

    -- Allow pointing at a single .lua file too
    local stat = vim.uv.fs_stat(abs_dir)
    if not stat then
      vim.notify(
        ("[weaver/import] Path does not exist: '%s'"):format(abs_dir),
        vim.log.levels.WARN
      )
      return {}
    end

    if stat.type == "file" then
      table.insert(collected, { path = abs_dir, result = load_by_path(abs_dir) })
    else
      for _, file in ipairs(collect_lua_files(abs_dir)) do
        table.insert(collected, { path = file, result = load_by_path(file) })
      end
    end

    -- ── Case B: Lua module name ──────────────────────────────────────────
  else
    local reldir = mod_to_relpath(target)

    -- Find every rtp directory that contains lua/<reldir>
    local found_any = false
    for _, rtp_dir in ipairs(vim.api.nvim_list_runtime_paths()) do
      local lua_dir = rtp_dir .. "/lua/" .. reldir

      local stat = vim.uv.fs_stat(lua_dir)
      if stat then
        found_any = true

        if stat.type == "file" then
          -- Edge case: the module resolves to a single file
          load_by_module(target) -- cache it
          table.insert(collected, { mod = target, result = load_by_module(target) })
        elseif stat.type == "directory" then
          -- Discover every .lua file and map it to its module name
          for _, file in ipairs(collect_lua_files(lua_dir)) do
            -- Turn absolute path back to a dot-notation module name:
            -- <rtp>/lua/plugins/editor/treesitter.lua → plugins.editor.treesitter
            local rel = file:sub(#(rtp_dir .. "/lua/") + 1) -- strip rtp prefix
            rel = rel:gsub("%.lua$", "")                    -- strip extension
            local modname = rel:gsub("/", ".")              -- slashes → dots

            table.insert(collected, { mod = modname, result = load_by_module(modname) })
          end
        end
      end
    end

    -- Also attempt to load the module itself (it might be an init.lua-style dir)
    -- This covers the case where `require("plugins")` directly returns specs.
    if not found_any then
      local result = load_by_module(target)
      if result then
        table.insert(collected, { mod = target, result = result })
      else
        vim.notify(
          ("[weaver/import] Module '%s' not found in runtimepath"):format(target),
          vim.log.levels.WARN
        )
      end
    end
  end

  -- ── Flatten collected results ────────────────────────────────────────
  local raw_specs = {}
  for _, item in ipairs(collected) do
    local specs = normalize_to_list(item.result)
    for _, spec in ipairs(specs) do
      -- Merge extra import-level options (e.g. enabled = false)
      if has_extra and type(spec) == "table" then
        spec = vim.tbl_extend("keep", spec, extra)
      end
      table.insert(raw_specs, spec)
    end
  end

  -- Recursively expand any nested import directives found inside the files
  return expand_raw_list(raw_specs)
end

--- Main entry-point called by spec.parse_all().
--- Walks the raw spec list and expands every { import = "..." } entry in place.
---
---@param raws table[]   The raw spec list passed to weaver.setup()
---@return table[]       Fully-expanded flat list of concrete raw specs
function M.expand(raws)
  return expand_raw_list(raws)
end

return M
