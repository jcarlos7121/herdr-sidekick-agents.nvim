-- herdr-sidekick-agents.nvim — drive coding-agent panes in Herdr from Neovim.
--
-- Instead of embedding an agent CLI in a Neovim terminal, this opens it in a
-- real Herdr pane next to your editor, so all of Herdr's agent features work
-- on it: state notifications, sidebar status, agent cycling, session resume.
--
-- The core flow needs two keys, whatever agents you use:
--   toggle()  no agent pane yet -> pick which agent to start; otherwise
--             hide/show the pane you already have
--   send()    push file/selection context to whichever agent pane is open
--
-- Any agent kind Herdr supports can be added under `agents` in setup().
-- No keymaps are set by this plugin — see the README for suggested mappings.
local M = {}

M.config = {
  -- Fraction of the tab the *editor* pane keeps when the agent pane opens
  -- (herdr's split ratio is the original pane's share; 0.7 → agent gets 30%).
  ratio = 0.7,
  -- Direction of the split relative to the editor pane.
  direction = "right",
  -- How long to keep retrying `herdr agent start` while the new pane's
  -- shell is still booting (fish/zsh init scripts take a moment).
  start_retries = 10,
  start_retry_ms = 500,
  -- How long `herdr agent start` waits for the agent to report interactive
  -- readiness, in ms. Agents that show a first-run consent screen (grok) or
  -- otherwise boot slowly need more than herdr's 30s default.
  start_timeout_ms = 60000,
  -- Offered first in the picker, and used by the named-agent API as a default.
  default_agent = "claude",
  -- Optional explicit picker order. Unlisted agents follow, alphabetically.
  agent_order = nil,
  -- Agent profiles. `kind` must be an agent kind Herdr knows (see
  -- `herdr agent start --help`); `args` is passed to that CLI verbatim.
  -- `ratio`, `direction` and `timeout_ms` may be overridden per agent.
  agents = {
    claude = { kind = "claude", args = { "--continue" } },
    codex = { kind = "codex", args = {} },
    grok = { kind = "grok", args = { "--continue" } },
  },
}

-- tab_id -> agent profile name this Neovim most recently started there, so
-- send()/close() prefer it when a tab holds more than one agent pane.
M._last_by_tab = {}

function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  -- `agents` and list-valued args are replaced wholesale, not deep-merged,
  -- so a shorter arg list cannot inherit stale trailing entries.
  local agents = opts.agents
  opts.agents = nil
  local legacy_claude_args = opts.claude_args
  opts.claude_args = nil

  M.config = vim.tbl_deep_extend("force", M.config, opts)

  if legacy_claude_args then
    M.config.agents.claude.args = legacy_claude_args
  end
  for name, profile in pairs(agents or {}) do
    local existing = M.config.agents[name] or {}
    M.config.agents[name] = {
      kind = profile.kind or existing.kind or name,
      args = profile.args or existing.args or {},
      ratio = profile.ratio or existing.ratio,
      direction = profile.direction or existing.direction,
      timeout_ms = profile.timeout_ms or existing.timeout_ms,
    }
  end
end

local function profile_for(name)
  name = name or M.config.default_agent
  local profile = M.config.agents[name]
  if not profile then
    -- unknown name: treat it as a bare agent kind with no arguments
    profile = { kind = name, args = {} }
  end
  return name, profile
end

--- Agent profile names in picker order: `agent_order` first (when set),
--- otherwise the default agent followed by the rest alphabetically.
local function agent_names()
  local names, seen = {}, {}
  for _, name in ipairs(M.config.agent_order or {}) do
    if M.config.agents[name] and not seen[name] then
      names[#names + 1] = name
      seen[name] = true
    end
  end
  local rest = {}
  for name in pairs(M.config.agents) do
    if not seen[name] then
      rest[#rest + 1] = name
    end
  end
  table.sort(rest)
  if not M.config.agent_order and M.config.agents[M.config.default_agent] then
    for i, name in ipairs(rest) do
      if name == M.config.default_agent then
        table.remove(rest, i)
        table.insert(rest, 1, name)
        break
      end
    end
  end
  vim.list_extend(names, rest)
  return names
end

local function herdr_bin()
  local bin = vim.env.HERDR_BIN_PATH
  if bin == nil or bin == "" then
    bin = "herdr"
  end
  return bin
end

local function herdr_json(args)
  local cmd = { herdr_bin() }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, (res.stderr ~= "" and res.stderr) or res.stdout
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout)
  if not ok then
    return nil, res.stdout
  end
  return decoded
end

local function list_agents()
  local decoded = herdr_json({ "agent", "list" })
  return decoded and decoded.result and decoded.result.agents or {}
end

--- Nearest agent pane matching `wanted` (a set of herdr agent kinds, or nil
--- for "any configured agent"): same tab first, then same space. When a tab
--- holds several, the one this Neovim started there wins.
local function find_agent(wanted)
  if not wanted then
    wanted = {}
    for name, profile in pairs(M.config.agents) do
      wanted[profile.kind or name] = true
    end
  end
  local preferred_kind
  local remembered = M._last_by_tab[vim.env.HERDR_TAB_ID or ""]
  if remembered and M.config.agents[remembered] then
    preferred_kind = M.config.agents[remembered].kind or remembered
  end

  local in_tab, preferred, same_space
  for _, a in ipairs(list_agents()) do
    if wanted[a.agent] and a.pane_id ~= vim.env.HERDR_PANE_ID then
      if a.tab_id == vim.env.HERDR_TAB_ID then
        in_tab = in_tab or a
        if a.agent == preferred_kind then
          preferred = preferred or a
        end
      elseif a.workspace_id == vim.env.HERDR_WORKSPACE_ID then
        same_space = same_space or a
      end
    end
  end
  return preferred or in_tab or same_space
end

local function editor_zoomed()
  local edges = herdr_json({ "pane", "edges", "--pane", vim.env.HERDR_PANE_ID })
  local e = edges and edges.result and edges.result.edges
  if not e then
    return false
  end
  if e.zoomed ~= nil then
    return e.zoomed
  end
  return e.layout and e.layout.zoomed or false
end

--- Split a pane off the editor and start `agent_name` in it.
local function start_agent(agent_name)
  local _, profile = profile_for(agent_name)
  local split, err = herdr_json({
    "pane", "split",
    "--pane", vim.env.HERDR_PANE_ID,
    "--direction", profile.direction or M.config.direction,
    "--ratio", tostring(profile.ratio or M.config.ratio),
    "--cwd", vim.fn.getcwd(),
    "--focus",
  })
  local pane = split and split.result and split.result.pane
  if not pane then
    vim.notify("herdr-sidekick-agents: pane split failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end
  M._last_by_tab[vim.env.HERDR_TAB_ID or ""] = agent_name
  -- herdr agent names: lowercase letters, digits, hyphens; must start lowercase
  local herdr_name = agent_name:lower():gsub("[^%w]", "-")
    .. "-"
    .. (vim.env.HERDR_TAB_ID or "main"):lower():gsub("[^%w]", "-")
  -- The fresh pane's shell needs a moment before it counts as "an available
  -- shell" — retry agent start until it is ready.
  local function attempt_start(attempt)
    local cmd = {
      herdr_bin(), "agent", "start", herdr_name,
      "--kind", profile.kind,
      "--pane", pane.pane_id,
      "--timeout", tostring(profile.timeout_ms or M.config.start_timeout_ms),
      "--",
    }
    vim.list_extend(cmd, profile.args or {})
    vim.system(cmd, { text = true }, function(res)
      if res.code == 0 then
        return
      end
      local out = (res.stderr or "") .. (res.stdout or "")
      if out:find("agent_pane_busy", 1, true) and attempt < M.config.start_retries then
        vim.defer_fn(function()
          attempt_start(attempt + 1)
        end, M.config.start_retry_ms)
      elseif out:find('"code":"timeout"', 1, true) then
        -- herdr stopped waiting for a readiness signal, but the CLI is running
        -- in the pane regardless (common on an agent's first-run consent screen)
        vim.schedule(function()
          vim.notify(
            "herdr-sidekick-agents: " .. profile.kind .. " did not report readiness in time; "
              .. "check the pane — it is usually running",
            vim.log.levels.WARN
          )
        end)
      else
        vim.schedule(function()
          vim.notify(
            "herdr-sidekick-agents: " .. profile.kind .. " failed to start: " .. out,
            vim.log.levels.ERROR
          )
        end)
      end
    end)
  end
  vim.defer_fn(function()
    attempt_start(1)
  end, 300)
end

--- Ask which agent to start, then start it. Skips the prompt when only one
--- agent is configured.
---@param on_pick fun(name: string)|nil called with the chosen name
function M.pick(on_pick)
  local names = agent_names()
  if #names == 0 then
    vim.notify("herdr-sidekick-agents: no agents configured", vim.log.levels.ERROR)
    return
  end
  if #names == 1 then
    (on_pick or start_agent)(names[1])
    return
  end
  vim.ui.select(names, { prompt = "Start agent:" }, function(choice)
    if choice then
      (on_pick or start_agent)(choice)
    end
  end)
end

--- Toggle the agent pane.
--- No agent pane in this tab -> pick an agent and start one beside the editor.
--- Pane visible              -> zoom the editor pane (hides it; the agent keeps
---                              running and Herdr keeps notifying about it).
--- Pane hidden by zoom       -> unzoom to reveal it.
--- A matching pane in another tab of the same space is focused instead.
---@param name string|nil restrict to one agent profile; omit for "any agent"
function M.toggle(name)
  if vim.env.HERDR_ENV ~= "1" then
    vim.notify("herdr-sidekick-agents: not inside a herdr pane", vim.log.levels.WARN)
    return
  end
  local wanted
  if name then
    local _, profile = profile_for(name)
    wanted = { [profile.kind] = true }
  end
  local existing = find_agent(wanted)
  if existing then
    if existing.tab_id ~= vim.env.HERDR_TAB_ID then
      herdr_json({ "agent", "focus", existing.pane_id })
    elseif editor_zoomed() then
      herdr_json({ "pane", "zoom", "--off", "--pane", vim.env.HERDR_PANE_ID })
    else
      herdr_json({ "pane", "zoom", "--on", "--pane", vim.env.HERDR_PANE_ID })
    end
    return
  end
  if name then
    start_agent(name)
  else
    M.pick()
  end
end

--- Close an agent pane for real (ends the process). With a resume flag in the
--- profile's args, the next toggle picks the conversation back up.
---@param name string|nil restrict to one agent profile; omit for "any agent"
function M.close(name)
  local wanted
  if name then
    local _, profile = profile_for(name)
    wanted = { [profile.kind] = true }
  end
  local existing = find_agent(wanted)
  if not existing then
    vim.notify("herdr-sidekick-agents: no agent pane to close", vim.log.levels.WARN)
    return
  end
  herdr_json({ "pane", "close", existing.pane_id })
end

--- Type a context reference into the agent pane's input, without submitting:
--- visual mode  -> "<relpath>:<start>-<end> "
--- in nvim-tree -> path of the node under the cursor
--- normal mode  -> current buffer's relative path
---@param name string|nil restrict to one agent profile; omit for "any agent"
function M.send(name)
  local wanted
  if name then
    local _, profile = profile_for(name)
    wanted = { [profile.kind] = true }
  end
  local target = find_agent(wanted)
  if not target then
    vim.notify("herdr-sidekick-agents: no agent pane open — toggle one open first", vim.log.levels.WARN)
    return
  end
  local text
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    if l1 > l2 then
      l1, l2 = l2, l1
    end
    text = string.format("%s:%d-%d ", vim.fn.expand("%:."), l1, l2)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  elseif vim.bo.filetype == "NvimTree" then
    local ok, api = pcall(require, "nvim-tree.api")
    local node = ok and api.tree.get_node_under_cursor()
    if not (node and node.absolute_path) then
      vim.notify("herdr-sidekick-agents: no file under cursor", vim.log.levels.WARN)
      return
    end
    text = vim.fn.fnamemodify(node.absolute_path, ":.") .. " "
  else
    local path = vim.fn.expand("%:.")
    if path == "" then
      vim.notify("herdr-sidekick-agents: buffer has no file path", vim.log.levels.WARN)
      return
    end
    text = path .. " "
  end
  herdr_json({ "pane", "send-text", target.pane_id, text })
end

return M
