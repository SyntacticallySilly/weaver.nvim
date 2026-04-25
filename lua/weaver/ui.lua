-- lua/weaver/ui.lua
-- The :Weaver popup window — a full TUI frontend for vim.pack.

local util    = require("weaver.util")
local updater = require("weaver.updater")
local loader  = require("weaver.loader")

local M = {}

-- ── Internal state ───────────────────────────────────────────────────
local state = {
  buf   = nil, ---@type integer|nil
  win   = nil, ---@type integer|nil
  ns    = vim.api.nvim_create_namespace("weaver_ui"),
  specs = {}, ---@type WeaverSpec[]
  lines = {}, ---@type string[]
  map   = {}, ---@type table<integer, WeaverSpec>
}

-- ── Highlight groups ─────────────────────────────────────────────────
local function setup_hl()
  vim.api.nvim_set_hl(0, "WeaverLoaded",    { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "WeaverUnloaded",  { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "WeaverDisabled",  { fg = "#6c7086", italic = true })
  vim.api.nvim_set_hl(0, "WeaverUpdate",    { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "WeaverHeader",    { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "WeaverSubHeader", { fg = "#89dceb" })
  vim.api.nvim_set_hl(0, "WeaverKey",       { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "WeaverBorder",    { fg = "#313244" })
end

-- Map category → highlight group (avoids repeated string comparisons in apply_hl)
local CAT_HL = {
  loaded   = "WeaverLoaded",
  unloaded = "WeaverUnloaded",
  disabled = "WeaverDisabled",
}

-- ── Categorize a spec ────────────────────────────────────────────────
---@param spec WeaverSpec
---@return "loaded"|"unloaded"|"disabled"
local function categorize(spec)
  if not spec.enabled           then return "disabled" end
  if util.is_loaded(spec.name)  then return "loaded"   end
  return "unloaded"
end

-- ── Build display lines ──────────────────────────────────────────────
local ICONS = {
  loaded   = "●",
  unloaded = "○",
  disabled = "✗",
  update   = " ↑",
  lazy     = " ⚡",
}

local function build_lines()
  local lines   = {}
  local line_map = {}

  -- Bucket specs into groups in a single pass
  local groups = {
    { label = "Loaded",   key = "loaded",   specs = {} },
    { label = "Unloaded", key = "unloaded", specs = {} },
    { label = "Disabled", key = "disabled", specs = {} },
  }
  local group_by_key = {}
  for _, g in ipairs(groups) do group_by_key[g.key] = g end

  for _, spec in ipairs(state.specs) do
    local g = group_by_key[categorize(spec)]
    g.specs[#g.specs + 1] = spec
  end

  lines[1] = "  ⠶ Weaver  —  vim.pack frontend"
  lines[2] = "  " .. string.rep("─", 60)

  for _, group in ipairs(groups) do
    if #group.specs == 0 then goto next_group end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("  ── %s (%d) "):format(group.label, #group.specs)

    local icon       = ICONS[group.key]
    local group_key  = group.key

    for _, spec in ipairs(group.specs) do
      local upd_badge  = updater.has_update[spec.name] and ICONS.update or ""
      local lazy_badge = spec.lazy and ICONS.lazy or ""
      local ver_badge  = spec.version and ("  @" .. spec.version) or ""
      local fetching   = updater.status[spec.name] == "fetching" and " …" or ""

      local line = ("  %s  %-35s  %-10s%s%s%s%s"):format(
        icon, spec.name, group_key,
        lazy_badge, ver_badge, upd_badge, fetching
      )
      local lnum       = #lines + 1
      lines[lnum]      = line
      line_map[lnum]   = spec
    end

    ::next_group::
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Press ? for help  ·  q / <Esc> to close"

  state.lines = lines
  state.map   = line_map
  return lines
end

-- ── Apply highlights ─────────────────────────────────────────────────
local function apply_hl()
  local buf = state.buf
  local ns  = state.ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Batch per-spec highlights
  for lnum, spec in pairs(state.map) do
    local line  = state.lines[lnum]
    if not line then goto continue end

    local cat   = categorize(spec)
    local group = CAT_HL[cat]
    vim.api.nvim_buf_add_highlight(buf, ns, group, lnum - 1, 0, #line)

    if updater.has_update[spec.name] then
      local upd_start = line:find(ICONS.update, 1, true)
      if upd_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "WeaverUpdate", lnum - 1, upd_start - 1, #line)
      end
    end

    ::continue::
  end

  -- Static highlights
  vim.api.nvim_buf_add_highlight(buf, ns, "WeaverHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "WeaverBorder", 1, 0, -1)

  for i, line in ipairs(state.lines) do
    if line:sub(1, 4) == "  ──" then
      vim.api.nvim_buf_add_highlight(buf, ns, "WeaverSubHeader", i - 1, 0, -1)
    end
  end

  vim.api.nvim_buf_add_highlight(buf, ns, "WeaverKey", #state.lines - 1, 0, -1)
end

-- ── Render ───────────────────────────────────────────────────────────
local function render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local lines = build_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  apply_hl()
end

-- ── Help overlay ─────────────────────────────────────────────────────
local help_lines = {
  "  ── Keymaps ───────────────────────────────────────",
  "  u   Update plugin under cursor",
  "  U   Update ALL plugins",
  "  i   Install missing / new plugins",
  "  d   Delete plugin under cursor",
  "  l   Load plugin under cursor (lazy → eager)",
  "  r   Refresh window",
  "  ?   Toggle this help",
  "  q / <Esc>   Close Weaver",
}

local _showing_help = false
local _saved_lines  = {}

local function toggle_help()
  if not state.buf then return end
  vim.bo[state.buf].modifiable = true
  if _showing_help then
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, _saved_lines)
    _showing_help = false
  else
    _saved_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, help_lines)
    _showing_help = true
  end
  vim.bo[state.buf].modifiable = false
end

-- ── Cursor spec ──────────────────────────────────────────────────────
local function spec_at_cursor()
  return state.map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

-- ── Window creation ──────────────────────────────────────────────────
local function create_window()
  local width  = math.min(80, vim.o.columns - 4)
  local height = math.min(30, vim.o.lines   - 4)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype   = "weaver"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " 🧵 Weaver ",
    title_pos = "center",
  })

  vim.wo[win].wrap         = false
  vim.wo[win].cursorline   = true
  vim.wo[win].winhighlight = "Normal:Normal,CursorLine:Visual"

  state.buf = buf
  state.win = win
end

-- ── Popup keymaps ─────────────────────────────────────────────────────
local function setup_keymaps()
  local buf = state.buf
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
  end

  map("q",     function() vim.api.nvim_win_close(state.win, true) end, "Close Weaver")
  map("<Esc>", function() vim.api.nvim_win_close(state.win, true) end, "Close Weaver")
  map("?",     toggle_help,                                              "Toggle help")

  map("r", function()
    render()
    vim.notify("[weaver] Refreshed", vim.log.levels.INFO)
  end, "Refresh")

  map("l", function()
    local spec = spec_at_cursor()
    if not spec then return end
    loader.load(spec.name)
    render()
    vim.notify("[weaver] Loaded: " .. spec.name, vim.log.levels.INFO)
  end, "Load plugin")

  map("u", function()
    local spec = spec_at_cursor()
    if not spec then return end
    vim.notify("[weaver] Updating " .. spec.name .. " …", vim.log.levels.INFO)
    vim.pack.update({ spec.name }, {}, function()
      updater.has_update[spec.name] = false
      render()
      vim.notify("[weaver] Updated: " .. spec.name, vim.log.levels.INFO)
    end)
  end, "Update plugin under cursor")

  map("U", function()
    vim.notify("[weaver] Updating all plugins …", vim.log.levels.INFO)
    -- Collect names in a single pass
    local names = {}
    for _, s in ipairs(state.specs) do names[#names + 1] = s.name end
    vim.pack.update(names, {}, function()
      updater.has_update = {}
      render()
      vim.notify("[weaver] All plugins updated.", vim.log.levels.INFO)
    end)
  end, "Update all plugins")

  map("i", function()
    vim.notify("[weaver] Installing missing plugins …", vim.log.levels.INFO)
    local registry   = require("weaver.init")._registry
    local pack_specs = {}
    for _, spec in pairs(registry) do
      if not spec.dir then
        local ps = { src = spec.src }
        if spec.version then ps.version = spec.version end
        if spec.name    then ps.name    = spec.name    end
        pack_specs[#pack_specs + 1] = ps
      end
    end
    vim.pack.add(pack_specs)
    render()
  end, "Install missing plugins")

  map("d", function()
    local spec = spec_at_cursor()
    if not spec then return end
    vim.ui.select({ "Yes", "No" }, {
      prompt = ("Delete '%s'?"):format(spec.name),
    }, function(choice)
      if choice ~= "Yes" then return end
      vim.pack.del({ spec.name })
      vim.notify("[weaver] Deleted: " .. spec.name, vim.log.levels.INFO)
      render()
    end)
  end, "Delete plugin")
end

-- ── Public ───────────────────────────────────────────────────────────

---@param specs WeaverSpec[]
function M.open(specs)
  setup_hl()
  state.specs = specs

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    render()
    return
  end

  create_window()
  setup_keymaps()
  render()

  -- Background update checks
  local names = {}
  for _, s in ipairs(specs) do
    if not s.dir and util.is_installed(s.name) then
      names[#names + 1] = s.name
    end
  end

  updater.check_all(names, function()
    vim.schedule(render)
  end)

  updater.on_done(vim.schedule_wrap(render))
end

return M
