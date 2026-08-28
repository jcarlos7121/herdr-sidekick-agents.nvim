# herdr-agents.nvim

Drive coding-agent panes in [Herdr](https://herdr.dev) from Neovim.

Instead of embedding an agent CLI in a Neovim terminal buffer, this plugin opens it in a **real Herdr pane** beside your editor. That makes your editor's agent a first-class Herdr agent: it shows working/blocked state in the sidebar, fires Herdr notifications when it finishes while you're elsewhere, participates in agent cycling keybinds, and gets resumed by Herdr's session restore.

[Claude Code](https://claude.com/claude-code), `codex` and `grok` ship as profiles, and any other agent kind Herdr supports — `gemini`, `opencode`, … — is one line of config away.

The whole flow needs **two keys, whatever agents you use**: one to open/hide the pane (asking which agent to start the first time), one to send context to whichever agent is open.

## Features

- **One key to open or hide.** With no agent pane yet, `toggle()` asks which agent to start (via `vim.ui.select`, so it uses your picker UI); with one already open it *hides* the pane by zooming the editor — the agent process keeps running and Herdr keeps notifying about its state — and toggling again reveals it. A single configured agent skips the prompt. (Note: zoom hides *all* other panes in the tab, not just the agent.)
- **One key to send context**, agent-agnostic: `send()` targets whichever agent pane is open, so the same key works for Claude, Codex, Grok or anything you add later.
- **Optional named agents.** Every function takes an agent name (`toggle("codex")`) when you want a dedicated key or a second agent alongside the first.
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
  "jcarlos7121/herdr-agents.nvim",
  cond = vim.env.HERDR_ENV == "1", -- only inside herdr
  main = "herdr-agents",
  opts = {},
}
```

## Keymaps

The plugin sets **no keymaps**. Map the functions however you like — each takes an optional agent profile name:

```lua
-- the whole flow, any agent
vim.keymap.set("n", ",4", function() require("herdr-agents").toggle() end,
  { desc = "Toggle agent pane (herdr)" })
vim.keymap.set({ "n", "v" }, ",5", function() require("herdr-agents").send() end,
  { desc = "Send file/selection ref to agent pane" })
```

Optional extras — a dedicated key for one agent, or a second agent beside the first:

```lua
vim.keymap.set("n", ",6", function() require("herdr-agents").toggle("codex") end,
  { desc = "Toggle Codex pane (herdr)" })
vim.keymap.set("n", ",7", function() require("herdr-agents").pick() end,
  { desc = "Start another agent pane (herdr)" })
```

## Configuration

Defaults shown:

```lua
require("herdr-agents").setup({
  ratio = 0.7,          -- editor pane's share of the tab (0.7 → agent gets 30%)
  direction = "right",  -- where the agent pane splits off: "right" or "down"
  start_retries = 10,   -- agent-start retries while the pane shell boots
  start_retry_ms = 500,
  start_timeout_ms = 60000, -- how long herdr waits for the agent to report readiness
  default_agent = "claude", -- offered first in the picker
  agent_order = nil,        -- optional explicit picker order; the rest follow alphabetically
  agents = {
    claude = { kind = "claude", args = { "--continue" } },
    codex  = { kind = "codex",  args = {} },
    grok   = { kind = "grok",   args = { "--continue" } },
  },
})
```

Each profile takes:

- `kind` — an agent kind Herdr knows (`herdr agent start --help` lists them). Defaults to the profile name.
- `args` — passed to that CLI verbatim, e.g. `{ "resume", "--last" }` for Codex or `{ "--continue" }` for Claude.
- `ratio` / `direction` / `timeout_ms` — optional per-agent overrides of the top-level values.

Agents that open a first-run consent screen (Grok Build does) may not report readiness before the timeout. That is not fatal — the CLI is running in the pane either way, and the plugin says so rather than reporting a failure.

Adding another agent is one line — it joins the picker automatically:

```lua
opts = {
  agents = {
    gemini = { args = {} }, -- `kind` defaults to the profile name
  },
}
```

Note: `args` is passed through verbatim. Flags like `--dangerously-skip-permissions` are your call — they are deliberately not a default.

## How it works

Everything goes through Herdr's CLI, using the environment Herdr injects into every pane (`HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_BIN_PATH`):

- `toggle()` looks for a pane running any configured agent kind in your tab (falling back to your space) via `herdr agent list`. If one exists in your tab it toggles `herdr pane zoom` on the editor pane (hide/show without touching the process); in another tab it focuses it; otherwise it asks which agent to start, then `herdr pane split` + `herdr agent start --kind <kind>`, retrying briefly while the new pane's shell finishes booting. Passing a name restricts every step to that one agent.
- `close()` runs `herdr pane close` on the agent's pane, ending the process.
- `send()` uses `herdr pane send-text`, which types into the agent's input without pressing enter.
- When a tab holds more than one agent pane, the one this Neovim started most recently there wins; otherwise the first match in the tab does.

A natural counterpart on the Herdr side is a keybind that closes the focused pane when it's an agent pane — see [Herdr's custom command keybinds](https://herdr.dev/docs/configuration/) — so you can toggle from either side of the split.

## License

MIT
