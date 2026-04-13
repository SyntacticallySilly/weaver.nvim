# 🧵 weaver.nvim

> A modern, performant frontend and compatibility layer for **vim.pack** —
> the Neovim 0.12 built-in plugin manager.

Weaver sits between you and `vim.pack`, giving you:

- **Full lazy.nvim spec syntax** (events, filetypes, commands, keymaps,
  dependencies, priorities, `opts`, `config`, `init`, `build`, `version` …)
- **A beautiful TUI** (`:Weaver`) showing loaded / unloaded / disabled plugins
  with live update badges
- **Zero compromise performance** — no Lua bytecode caching tricks needed;
  startup cost is the plugins themselves, not the manager

---

## Requirements

- Neovim **≥ 0.12** (`vim.pack` API)
- `git` in `$PATH`

---

## Installation (bootstrap)

Because weaver itself uses `vim.pack`, you can bootstrap it with a tiny
snippet at the **very top** of your `init.lua`:

```lua
-- Bootstrap weaver.nvim via vim.pack
vim.pack.add({ "https://github.com/SyntacticallySilly/weaver.nvim" })
```

Then configure it immediately after:

```lua
require("weaver").setup({
  -- your plugins here
})
```

---

## Usage

### Basic

```lua
require("weaver").setup({
  -- Plain string (eager load)
  "nvim-lua/plenary.nvim",

  -- With options table
  { "catppuccin/nvim",
    name     = "catppuccin",
    lazy     = false,
    priority = 1000,
    config   = function() vim.cmd.colorscheme("catppuccin") end },
})
```

### Lazy loading by event

```lua
{ "nvim-treesitter/nvim-treesitter",
  version = "main",
  build   = ":TSUpdate",
  event   = { "BufReadPost", "BufNewFile" },
  config  = function()
    require("nvim-treesitter.configs").setup({ highlight = { enable = true } })
  end },
```

### Lazy loading by filetype

```lua
{ "stevearc/conform.nvim",
  ft     = { "lua", "python", "rust" },
  opts   = {
    formatters_by_ft = { lua = { "stylua" }, python = { "black" } },
  } },
```

### Lazy loading by command

```lua
{ "nvim-telescope/telescope.nvim",
  cmd          = { "Telescope" },
  dependencies = { "nvim-lua/plenary.nvim" },
  config       = function() require("telescope").setup({}) end },
```

### Lazy loading by keymap

```lua
{ "folke/which-key.nvim",
  keys = {
    { "<leader>",  desc = "Leader" },
    { "<leader>w", "<cmd>w<cr>", desc = "Save" },
  },
  opts = {} },
```

### Version pinning

```lua
{ "neovim/nvim-lspconfig", version = "v2.0.0" },
-- or a branch:
{ "nvim-treesitter/nvim-treesitter", version = "main" },
```

### Local plugins

```lua
{ dir = "~/projects/my-plugin",
  config = function() require("my-plugin").setup({}) end },
```

### Dependencies

```lua
{ "nvim-telescope/telescope.nvim",
  cmd          = "Telescope",
  dependencies = {
    "nvim-lua/plenary.nvim",
    { "nvim-telescope/telescope-fzf-native.nvim",
      build = "make" },
  },
  config = function() require("telescope").setup({}) end },
```

### Post-install / update hooks

```lua
{ "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate" },       -- Neovim command

{ "some/plugin",
  build = "make install" },    -- Shell command

{ "other/plugin",
  build = function()           -- Lua function
    require("other").post_install()
  end },
```

---

## The `:Weaver` UI

```
:Weaver           → Open the popup window
:Weaver update    → Update all plugins
:Weaver update plenary.nvim telescope.nvim   → Update specific plugins
:Weaver add user/new-plugin  → Add a plugin at runtime
:Weaver del old-plugin       → Delete a plugin
```

### Inside the window

| Key       | Action                                  |
|-----------|-----------------------------------------|
| `l`       | Load plugin under cursor                |
| `u`       | Update plugin under cursor              |
| `U`       | Update **all** plugins                  |
| `i`       | Install any missing plugins             |
| `d`       | Delete plugin under cursor (with confirm) |
| `r`       | Refresh / re-render window              |
| `?`       | Toggle help overlay                     |
| `q` / `Esc` | Close                                 |

Update availability is checked **concurrently** via `git fetch --dry-run`
the moment the window opens; plugins with upstream changes show an **↑** badge.

---

## API

```lua
local weaver = require("weaver")

weaver.setup(specs, opts)   -- Main entry point
weaver.open()               -- Open UI programmatically
weaver.add({ ... })         -- Add plugins post-setup
weaver.update({ "name" })   -- Update by name (nil = all)
weaver.del("name")          -- Delete a plugin
```

---

## Comparison

| Feature                   | lazy.nvim | vim.pack (raw) | weaver.nvim |
|---------------------------|-----------|----------------|-------------|
| Lazy loading              | ✅        | ❌             | ✅          |
| lazy.nvim spec syntax     | ✅        | ❌             | ✅          |
| Built-in (no bootstrap)   | ❌        | ✅             | via vim.pack |
| TUI frontend              | ✅        | ❌             | ✅          |
| Update badges             | ✅        | ❌             | ✅          |
| Version pinning           | ✅        | ✅             | ✅          |
| Dependencies              | ✅        | manual         | ✅          |
| Build hooks               | ✅        | via autocmd    | ✅          |
| Local plugins             | ✅        | manual         | ✅          |
| Startup overhead          | medium    | minimal        | minimal     |

---

## License

MIT
