# herdr-claude-nvim

Drive a [Claude Code](https://claude.com/claude-code) pane in [Herdr](https://herdr.dev) from Neovim.

Instead of embedding Claude Code in a Neovim terminal buffer, this plugin opens it in a **real Herdr pane** beside your editor. That makes your editor's Claude a first-class Herdr agent: it shows working/blocked state in the sidebar, fires Herdr notifications when it finishes while you're elsewhere, participates in agent cycling keybinds, and gets resumed by Herdr's session restore.

## Features

- **Toggle** a Claude Code pane split off your editor pane (default: right side, 30% wide), with `cwd` set to Neovim's current working directory. Closing and reopening resumes the conversation when `--continue` is in `claude_args`.
- **Send context** into Claude's input — *without submitting*, so you keep typing your instruction:
  - visual selection → `path/to/file.lua:12-34`
  - in [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua) → the path of the node under the cursor
  - any other buffer → the file's relative path

## Requirements

- Neovim ≥ 0.10
- [Herdr](https://herdr.dev) ≥ 0.8, with Neovim running inside a Herdr pane
- The `claude` CLI on your `PATH`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jcarlos7121/herdr-claude-nvim",
  cond = vim.env.HERDR_ENV == "1", -- only inside herdr
  main = "herdr-claude",
  opts = {},
}
```

## Keymaps

The plugin sets **no keymaps**. Map the two functions however you like — for example:

```lua
vim.keymap.set("n", ",4", function() require("herdr-claude").toggle() end,
  { desc = "Toggle Claude pane (herdr)" })
vim.keymap.set({ "n", "v" }, ",5", function() require("herdr-claude").send() end,
  { desc = "Send file/selection ref to Claude pane" })
```

## Configuration

Defaults shown:

```lua
require("herdr-claude").setup({
  ratio = 0.7,                 -- editor pane's share of the tab (0.7 → Claude gets 30%)
  direction = "right",         -- where the Claude pane splits off: "right" or "down"
  claude_args = { "--continue" }, -- extra args for the claude CLI
  start_retries = 10,          -- agent-start retries while the pane shell boots
  start_retry_ms = 500,
})
```

Note: `claude_args` is passed to the `claude` CLI verbatim. Flags like `--dangerously-skip-permissions` are your call — they are deliberately not a default.

## How it works

Everything goes through Herdr's CLI, using the environment Herdr injects into every pane (`HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_BIN_PATH`):

- `toggle()` looks for a Claude agent pane in your tab (falling back to your space) via `herdr agent list`. If one exists it runs `herdr pane close`; otherwise `herdr pane split` + `herdr agent start --kind claude`, retrying briefly while the new pane's shell finishes booting.
- `send()` uses `herdr pane send-text`, which types into Claude's input without pressing enter.

A natural counterpart on the Herdr side is a keybind that closes the focused pane when it's a Claude agent — see [Herdr's custom command keybinds](https://herdr.dev/docs/configuration/) — so you can toggle from either side of the split.

## License

MIT
