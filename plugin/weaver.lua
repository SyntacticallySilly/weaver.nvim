-- plugin/weaver.lua
-- Auto-loaded by Neovim at startup (no user action needed).
-- Registers the :Weaver user command.

if vim.g.loaded_weaver then return end
vim.g.loaded_weaver = true

-- Require Neovim 0.12+
if vim.fn.has("nvim-0.12") == 0 then
  vim.notify(
    "[weaver] Neovim 0.12+ is required (vim.pack API not available).",
    vim.log.levels.ERROR
  )
  return
end

vim.api.nvim_create_user_command("Weaver", function(args)
  local sub = args.args ~= "" and args.args or "open"
  local weaver = require("weaver")

  if sub == "open" or sub == "" then
    weaver.open()

  elseif sub:match("^update") then
    -- :Weaver update [name1 name2 ...]
    local names_str = sub:match("^update%s+(.*)")
    local names = names_str and vim.split(names_str, "%s+") or nil
    weaver.update(names)

  elseif sub:match("^add%s+") then
    -- :Weaver add user/repo
    local src = sub:match("^add%s+(.*)")
    if src then weaver.add({ src }) end

  elseif sub:match("^del%s+") then
    -- :Weaver del plugin-name
    local name = sub:match("^del%s+(.*)")
    if name then weaver.del(name) end

  else
    vim.notify("[weaver] Unknown subcommand: " .. sub, vim.log.levels.WARN)
  end
end, {
  nargs   = "?",
  desc    = "Weaver plugin manager",
  complete = function()
    return { "open", "update", "add", "del" }
  end,
})
