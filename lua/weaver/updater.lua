-- lua/weaver/updater.lua
-- Background update-checker: runs `git fetch --dry-run` per plugin
-- and reports which ones have upstream changes available.

local util = require("weaver.util")

local M = {}

-- { [name] = true } for plugins with available updates
M.has_update = {} ---@type table<string, boolean>
-- { [name] = "fetching"|"done"|"error" }
M.status = {} ---@type table<string, string>

local _callbacks = {} ---@type function[]

--- Register a callback to be fired when all checks complete.
---@param fn function
function M.on_done(fn)
  table.insert(_callbacks, fn)
end

local function notify_done()
  for _, fn in ipairs(_callbacks) do pcall(fn) end
end

--- Check a single plugin asynchronously for available updates.
---@param name string
---@param cb function|nil  Called with (name, has_update:boolean)
function M.check_one(name, cb)
  local path = util.plugin_path(name)
  if not vim.uv.fs_stat(path) then
    if cb then cb(name, false) end
    return
  end

  M.status[name] = "fetching"

  vim.system(
    { "git", "-C", path, "fetch", "--dry-run", "origin" },
    { timeout = 10000 },
    function(result)
      vim.schedule(function()
        -- git fetch --dry-run outputs to stderr when there are changes
        local has = (result.code == 0)
            and (result.stderr ~= nil and result.stderr ~= "")
        M.has_update[name] = has
        M.status[name] = "done"
        if cb then cb(name, has) end
      end)
    end
  )
end

--- Check all managed plugins concurrently.
---@param names string[]
---@param cb function|nil  Called once all checks complete
function M.check_all(names, cb)
  if #names == 0 then
    if cb then cb() end
    return
  end

  local pending = #names
  local function on_one()
    pending = pending - 1
    if pending == 0 then
      notify_done()
      if cb then cb() end
    end
  end

  for _, name in ipairs(names) do
    M.check_one(name, function()
      on_one()
    end)
  end
end

return M
