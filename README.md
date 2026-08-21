# herdr-claude-nvim

Drive coding-agent panes in [Herdr](https://herdr.dev) from Neovim.

Instead of embedding an agent CLI in a Neovim terminal buffer, this plugin opens it in a **real Herdr pane** beside your editor. That makes your editor's agent a first-class Herdr agent: it shows working/blocked state in the sidebar, fires Herdr notifications when it finishes while you're elsewhere, participates in agent cycling keybinds, and gets resumed by Herdr's session restore.

[Claude Code](https://claude.com/claude-code) is the default agent, and any agent kind Herdr supports — `codex`, `gemini`, `opencode`, … — works the same way through an agent profile.

## Features

- **Toggle** an agent pane split off your editor pane (default: right side, 30% wide), with `cwd` set to Neovim's current working directory. Toggling *hides* the pane by zooming the editor — the agent process keeps running and Herdr keeps notifying about its state — and toggling again reveals it. (Note: zoom hides *all* other panes in the tab, not just the agent.)
- **Multiple agents side by side.** Claude in one pane, Codex in another, each toggled by its own key.
- **Close** a pane for real with `close()` when you want the process gone. With a resume flag in the profile's args, the next toggle picks the conversation back up.
- **Send context** into an agent's input — *without submitting*, so you keep typing your instruction:
  - visual selection → `path/to/file.lua:12-34`
  - in [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua) → the path of the node under the cursor
  - any other buffer → the file's relative path

## Requirements

- Neovim ≥ 0.10
- [Herdr](https://herdr.dev) ≥ 0.8, with Neovim running inside a Herdr pane
- The agent CLI you use (`claude`, `codex`, …) on your `PATH`

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

The plugin sets **no keymaps**. Map the functions however you like — each takes an optional agent profile name:

```lua
-- Claude (the default agent)
vim.keymap.set("n", ",4", function() require("herdr-claude").toggle() end,
  { desc = "Toggle Claude pane (herdr)" })
vim.keymap.set({ "n", "v" }, ",5", function() require("herdr-claude").send() end,
  { desc = "Send file/selection ref to Claude pane" })

-- Codex
vim.keymap.set("n", ",6", function() require("herdr-claude").toggle("codex") end,
  { desc = "Toggle Codex pane (herdr)" })
vim.keymap.set({ "n", "v" }, ",7", function() require("herdr-claude").send("codex") end,
  { desc = "Send file/selection ref to Codex pane" })
```

## Configuration

Defaults shown:

```lua
require("herdr-claude").setup({
  ratio = 0.7,          -- editor pane's share of the tab (0.7 → agent gets 30%)
  direction = "right",  -- where the agent pane splits off: "right" or "down"
  start_retries = 10,   -- agent-start retries while the pane shell boots
  start_retry_ms = 500,
  default_agent = "claude", -- used when toggle()/send()/close() get no name
  agents = {
    claude = { kind = "claude", args = { "--continue" } },
    codex  = { kind = "codex",  args = {} },
  },
})
```

Each profile takes:

- `kind` — an agent kind Herdr knows (`herdr agent start --help` lists them). Defaults to the profile name.
- `args` — passed to that CLI verbatim, e.g. `{ "resume", "--last" }` for Codex or `{ "--continue" }` for Claude.
- `ratio` / `direction` — optional per-agent overrides of the top-level values.

Adding another agent is just another profile:

```lua
opts = {
  agents = {
    gemini = { kind = "gemini", args = {} },
  },
}
```

Note: `args` is passed through verbatim. Flags like `--dangerously-skip-permissions` are your call — they are deliberately not a default.

## How it works

Everything goes through Herdr's CLI, using the environment Herdr injects into every pane (`HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_BIN_PATH`):

- `toggle(name)` looks for a pane running that agent kind in your tab (falling back to your space) via `herdr agent list`. If one exists in your tab it toggles `herdr pane zoom` on the editor pane (hide/show without touching the process); in another tab it focuses it; otherwise `herdr pane split` + `herdr agent start --kind <kind>`, retrying briefly while the new pane's shell finishes booting.
- `close(name)` runs `herdr pane close` on that agent's pane, ending the process.
- `send(name)` uses `herdr pane send-text`, which types into the agent's input without pressing enter.

A natural counterpart on the Herdr side is a keybind that closes the focused pane when it's an agent pane — see [Herdr's custom command keybinds](https://herdr.dev/docs/configuration/) — so you can toggle from either side of the split.

## License

MIT
