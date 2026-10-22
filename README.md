# herdr-sidekick-agents.nvim

Drive coding-agent panes in [Herdr](https://herdr.dev) from Neovim.

Instead of embedding an agent CLI in a Neovim terminal buffer, this plugin opens it in a **real Herdr pane** beside your editor. That makes your editor's agent a first-class Herdr agent: it shows working/blocked state in the sidebar, fires Herdr notifications when it finishes while you're elsewhere, participates in agent cycling keybinds, and gets resumed by Herdr's session restore.

[Claude Code](https://claude.com/claude-code), `codex` and `grok` ship as profiles, and any other agent kind Herdr supports — `gemini`, `opencode`, … — is one line of config away.

The whole flow needs **two keys, whatever agents you use**: one to open/hide the pane (asking which agent to start the first time), one to send context to whichever agent is open.

## Features

- **One key to open or hide.** With no agent pane yet, `toggle()` asks which agent to start (via `vim.ui.select`, so it uses your picker UI); with one already open it *hides* the pane by zooming the editor — the agent process keeps running and Herdr keeps notifying about its state — and toggling again reveals it. A single configured agent skips the prompt. (Note: zoom hides *all* other panes in the tab, not just the agent.)
- **One key to go the other way.** `focus()` jumps to the agent pane and zooms it, hiding the editor — the inverse of `toggle()`'s hide. Herdr's own zoom key (`prefix+z`) brings the editor back from there.
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
  "jcarlos7121/herdr-sidekick-agents.nvim",
  cond = vim.env.HERDR_ENV == "1", -- only inside herdr
  main = "herdr-sidekick-agents",
  opts = {},
}
```

### Herdr side (optional)

The repo is also a [Herdr plugin](https://herdr.dev/docs/plugins/) with one action, `close-agent`, which closes the focused pane only when Herdr detects a coding agent in it (any agent, not just ones this plugin started; on the editor or a plain shell it does nothing). It lets you close the agent pane from the Herdr side of the split as well:

```sh
herdr plugin install jcarlos7121/herdr-sidekick-agents.nvim
```

Then bind it in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "jcarlos7121.sidekick-agents.close-agent"
description = "close agent pane"
```

## Keymaps

The plugin sets **no keymaps**. Map the functions however you like — `toggle()`, `focus()`, `close()` and `send()` each take an optional agent profile name (a name with no profile is used as a bare Herdr agent kind with no args):

```lua
-- the whole flow, any agent
vim.keymap.set("n", ",4", function() require("herdr-sidekick-agents").toggle() end,
  { desc = "Toggle agent pane (herdr)" })
vim.keymap.set({ "n", "v" }, ",5", function() require("herdr-sidekick-agents").send() end,
  { desc = "Send file/selection ref to agent pane" })
```

Optional extras — focus the agent full-screen, a dedicated key for one agent, or a second agent beside the first:

```lua
vim.keymap.set("n", ",7", function() require("herdr-sidekick-agents").focus() end,
  { desc = "Focus agent pane, hide editor (herdr)" })
vim.keymap.set("n", ",6", function() require("herdr-sidekick-agents").pick() end,
  { desc = "Start another agent pane (herdr)" })
vim.keymap.set("n", ",8", function() require("herdr-sidekick-agents").toggle("codex") end,
  { desc = "Toggle Codex pane (herdr)" })
```

`pick()` always starts a new pane, even when an agent pane is already open (it asks which agent unless only one is configured). Pass `{ zoom = false }` as the second argument to `focus()` (e.g. `focus(nil, { zoom = false })`) to jump to the agent pane without zooming it.

## Configuration

Defaults shown:

```lua
require("herdr-sidekick-agents").setup({
  ratio = 0.7,          -- editor pane's share of the tab (0.7 → agent gets 30%)
  direction = "right",  -- where the agent pane splits off: "right" or "down"
  start_retries = 10,   -- agent-start retries while the pane shell boots
  start_retry_ms = 500,
  start_timeout_ms = 60000, -- how long herdr waits for the agent to report readiness
  pane_env = { "Q_TERM=1" }, -- extra KEY=VALUE env for the agent pane's shell (Q_TERM=1 keeps kiro-cli's shell wrapper from blocking agent start)
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
- `pane_env` — optional list of `KEY=VALUE` strings. When an agent sets it, that list replaces the global `pane_env` for that agent.

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

Everything goes through Herdr's CLI, using the environment Herdr injects into every pane (`HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_BIN_PATH`):

- `toggle()` looks for a pane running any configured agent kind in your tab (falling back to your space) via `herdr agent list`. If one exists in your tab it toggles `herdr pane zoom` on the editor pane (hide/show without touching the process); in another tab it focuses it; otherwise it asks which agent to start, then `herdr pane split` (in Neovim's cwd, with `pane_env`) + `herdr agent start --kind <kind>`, retrying briefly while the new pane's shell finishes booting. Passing a name restricts every step to that one agent.
- `focus()` unzooms the editor if needed, then `herdr agent focus` + `herdr pane zoom --on` on the agent's pane.
- `close()` runs `herdr pane close` on the agent's pane, ending the process.
- `send()` uses `herdr pane send-text`, which types into the agent's input without pressing enter.
- When a tab holds more than one agent pane, a pane of the agent kind this Neovim most recently started there wins; otherwise the first match in the tab does.

On the Herdr side, the `close-agent` plugin action (see [Herdr side](#herdr-side-optional)) runs `herdr agent get` on the focused pane and, only if that finds an agent, `herdr pane close`, so you can close the agent from either side of the split.

## License

MIT
