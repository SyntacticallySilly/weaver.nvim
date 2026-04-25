-- lua/weaver/util.lua
-- Shared utility helpers for weaver.nvim

local M = {}

-- Cache stdpath once — vim.fn calls are expensive across hot paths
local _data_path = vim.fn.stdpath("data")

--- Resolve a plugin name from its source URL or shorthand.
---@param src string
---@return string
function M.name_from_src(src)
  return src:match("[^/]+$"):gsub("%.git$", "")
end

--- Normalize a GitHub shorthand "user/repo" into a full URL.
---@param src string
---@return string
function M.normalize_src(src)
  if src:sub(1, 4) == "http" then return src end           -- fast prefix check
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
  -- Use cached data path; avoid repeated stdpath() calls
  return _data_path .. "/site/pack/core/opt/" .. name
end

-- Cache of rtp set, invalidated when rtp changes.
-- We use a lazy-rebuilt set keyed by rtp length as a cheap dirty-check.
local _rtp_cache_len = -1
local _rtp_set       = {} ---@type table<string, boolean>

--- Check if a plugin is currently loaded (in rtp and sourced).
---@param name string
---@return boolean
function M.is_loaded(name)
  local rtp = vim.api.nvim_list_runtime_paths()
  -- Rebuild the set only when rtp actually changes
  if #rtp ~= _rtp_cache_len then
    _rtp_set = {}
    for _, p in ipairs(rtp) do
      -- Extract the last path component
      local tail = p:match("[/\\]([^/\\]+)$")
      if tail then _rtp_set[tail] = true end
    end
    _rtp_cache_len = #rtp
  end
  return _rtp_set[name] == true
end

--- Check whether a plugin directory exists on disk.
---@param name string
---@return boolean
function M.is_installed(name)
  return vim.uv.fs_stat(M.plugin_path(name)) ~= nil
end

return M
