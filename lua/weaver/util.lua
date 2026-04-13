-- lua/weaver/util.lua
-- Shared utility helpers for weaver.nvim

local M = {}

--- Resolve a plugin name from its source URL or shorthand.
--- Supports both "user/repo" and full "https://github.com/user/repo" forms.
---@param src string
---@return string
function M.name_from_src(src)
  return src:match("[^/]+$"):gsub("%.git$", "")
end

--- Normalize a GitHub shorthand "user/repo" into a full URL.
---@param src string
---@return string
function M.normalize_src(src)
  if src:match("^https?://") then
    return src
  end
  -- "user/repo" shorthand → full GitHub URL
  if src:match("^[%w%-_.]+/[%w%-_.]+$") then
    return "https://github.com/" .. src
  end
  return src
end

--- Deep-merge two tables (right wins).
---@param base table
---@param override table
---@return table
function M.merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = M.merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

--- Safely call a function and notify on error.
---@param fn function
---@param label string
function M.safe_call(fn, label)
  local ok, err = pcall(fn)
  if not ok then
    vim.notify(("[weaver] Error in %s: %s"):format(label, err), vim.log.levels.ERROR)
  end
end

--- Return the installation path for a plugin by name.
---@param name string
---@return string
function M.plugin_path(name)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt", name)
end

--- Check if a plugin is currently loaded (in rtp and sourced).
---@param name string
---@return boolean
function M.is_loaded(name)
  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    if p:match("[/\\]" .. vim.pesc(name) .. "$") then
      return true
    end
  end
  return false
end

--- Check whether a plugin directory exists on disk.
---@param name string
---@return boolean
function M.is_installed(name)
  return vim.uv.fs_stat(M.plugin_path(name)) ~= nil
end

return M
