-- herdr-claude-nvim — drive coding-agent panes in Herdr from Neovim.
--
-- Instead of embedding an agent CLI in a Neovim terminal, this opens it in a
-- real Herdr pane next to your editor, so all of Herdr's agent features work
-- on it: state notifications, sidebar status, agent cycling, session resume.
--
-- Claude Code is the default agent; any agent kind Herdr supports (codex,
-- gemini, opencode, ...) can be added under `agents` in setup().
--
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
  -- Agent used when toggle()/send()/close() are called without a name.
  default_agent = "claude",
  -- Agent profiles. `kind` must be an agent kind Herdr knows (see
  -- `herdr agent start --help`); `args` is passed to that CLI verbatim.
  -- `ratio` and `direction` may be overridden per agent.
  agents = {
    claude = { kind = "claude", args = { "--continue" } },
    codex = { kind = "codex", args = {} },
  },
}

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

-- The agent pane of this kind closest to this Neovim: same tab, then same space.
local function find_agent(kind)
  local decoded = herdr_json({ "agent", "list" })
  local agents = decoded and decoded.result and decoded.result.agents or {}
  local same_space
  for _, a in ipairs(agents) do
    if a.agent == kind and a.pane_id ~= vim.env.HERDR_PANE_ID then
      if a.tab_id == vim.env.HERDR_TAB_ID then
        return a
      end
      if a.workspace_id == vim.env.HERDR_WORKSPACE_ID then
        same_space = same_space or a
      end
    end
  end
  return same_space
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

--- Toggle an agent pane, claudecode.nvim-style hide/show:
--- no pane for this agent in the tab -> split one off the editor and start it;
--- pane visible                      -> zoom the editor pane (hides it; the
---                                      agent keeps running and Herdr keeps
---                                      notifying about its state);
--- pane hidden by zoom               -> unzoom to reveal it.
--- A matching pane in another tab of the same space is focused instead.
---@param name string|nil agent profile name (default: config.default_agent)
function M.toggle(name)
  if vim.env.HERDR_ENV ~= "1" then
    vim.notify("herdr-claude: not inside a herdr pane", vim.log.levels.WARN)
    return
  end
  local agent_name, profile = profile_for(name)
  local existing = find_agent(profile.kind)
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
    vim.notify("herdr-claude: pane split failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end
  -- herdr agent names: lowercase letters, digits, hyphens; must start lowercase
  local herdr_name = agent_name:lower():gsub("[^%w]", "-")
    .. "-"
    .. (vim.env.HERDR_TAB_ID or "main"):lower():gsub("[^%w]", "-")
  -- The fresh pane's shell needs a moment before it counts as "an available
  -- shell" — retry agent start until it is ready.
  local function start_agent(attempt)
    local cmd = {
      herdr_bin(), "agent", "start", herdr_name,
      "--kind", profile.kind,
      "--pane", pane.pane_id,
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
          start_agent(attempt + 1)
        end, M.config.start_retry_ms)
      else
        vim.schedule(function()
          vim.notify(
            "herdr-claude: " .. profile.kind .. " failed to start: " .. out,
            vim.log.levels.ERROR
          )
        end)
      end
    end)
  end
  vim.defer_fn(function()
    start_agent(1)
  end, 300)
end

--- Close an agent pane for real (ends the process). With a resume flag in the
--- profile's args, the next toggle picks the conversation back up.
---@param name string|nil agent profile name (default: config.default_agent)
function M.close(name)
  local _, profile = profile_for(name)
  local existing = find_agent(profile.kind)
  if not existing then
    vim.notify("herdr-claude: no " .. profile.kind .. " pane to close", vim.log.levels.WARN)
    return
  end
  herdr_json({ "pane", "close", existing.pane_id })
end

--- Type a context reference into an agent pane's input, without submitting:
--- visual mode  -> "<relpath>:<start>-<end> "
--- in nvim-tree -> path of the node under the cursor
--- normal mode  -> current buffer's relative path
---@param name string|nil agent profile name (default: config.default_agent)
function M.send(name)
  local _, profile = profile_for(name)
  local target = find_agent(profile.kind)
  if not target then
    vim.notify(
      "herdr-claude: no " .. profile.kind .. " pane in this tab — toggle one open first",
      vim.log.levels.WARN
    )
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
      vim.notify("herdr-claude: no file under cursor", vim.log.levels.WARN)
      return
    end
    text = vim.fn.fnamemodify(node.absolute_path, ":.") .. " "
  else
    local path = vim.fn.expand("%:.")
    if path == "" then
      vim.notify("herdr-claude: buffer has no file path", vim.log.levels.WARN)
      return
    end
    text = path .. " "
  end
  herdr_json({ "pane", "send-text", target.pane_id, text })
end

return M
