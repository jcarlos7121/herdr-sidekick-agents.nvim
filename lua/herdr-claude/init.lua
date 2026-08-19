-- herdr-claude-nvim — drive a Claude Code pane in Herdr from Neovim.
--
-- Instead of embedding Claude Code in a Neovim terminal, this opens it in a
-- real Herdr pane next to your editor, so all of Herdr's agent features work
-- on it: state notifications, sidebar status, agent cycling, session resume.
--
-- No keymaps are set by this plugin — see the README for suggested mappings.
local M = {}

M.config = {
  -- Fraction of the tab the *editor* pane keeps when the Claude pane opens
  -- (herdr's split ratio is the original pane's share; 0.7 → Claude gets 30%).
  ratio = 0.7,
  -- Direction of the split relative to the editor pane.
  direction = "right",
  -- Extra arguments passed to the `claude` CLI when the pane starts.
  -- e.g. { "--continue" } to resume the previous conversation on reopen.
  claude_args = { "--continue" },
  -- How long to keep retrying `herdr agent start` while the new pane's
  -- shell is still booting (fish/zsh init scripts take a moment).
  start_retries = 10,
  start_retry_ms = 500,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
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

-- The Claude agent pane closest to this Neovim: same tab first, then same space.
local function find_claude()
  local decoded = herdr_json({ "agent", "list" })
  local agents = decoded and decoded.result and decoded.result.agents or {}
  local same_space
  for _, a in ipairs(agents) do
    if a.agent == "claude" and a.pane_id ~= vim.env.HERDR_PANE_ID then
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

--- Toggle the Claude pane, claudecode.nvim-style hide/show:
--- no Claude pane in this tab -> split one off the editor pane and start Claude;
--- Claude pane visible        -> zoom the editor pane (hides it; Claude keeps
---                               running and Herdr notifications keep firing);
--- Claude pane hidden by zoom -> unzoom to reveal it.
--- A Claude pane in another tab of the same space is focused instead.
function M.toggle()
  if vim.env.HERDR_ENV ~= "1" then
    vim.notify("herdr-claude: not inside a herdr pane", vim.log.levels.WARN)
    return
  end
  local existing = find_claude()
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
    "--direction", M.config.direction,
    "--ratio", tostring(M.config.ratio),
    "--cwd", vim.fn.getcwd(),
    "--focus",
  })
  local pane = split and split.result and split.result.pane
  if not pane then
    vim.notify("herdr-claude: pane split failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end
  -- herdr agent names: lowercase letters, digits, hyphens; must start lowercase
  local name = "claude-" .. (vim.env.HERDR_TAB_ID or "main"):lower():gsub("[^%w]", "-")
  -- The fresh pane's shell needs a moment before it counts as "an available
  -- shell" — retry agent start until it is ready.
  local function start_claude(attempt)
    local cmd = { herdr_bin(), "agent", "start", name, "--kind", "claude", "--pane", pane.pane_id, "--" }
    vim.list_extend(cmd, M.config.claude_args)
    vim.system(cmd, { text = true }, function(res)
      if res.code == 0 then
        return
      end
      local out = (res.stderr or "") .. (res.stdout or "")
      if out:find("agent_pane_busy", 1, true) and attempt < M.config.start_retries then
        vim.defer_fn(function()
          start_claude(attempt + 1)
        end, M.config.start_retry_ms)
      else
        vim.schedule(function()
          vim.notify("herdr-claude: claude failed to start: " .. out, vim.log.levels.ERROR)
        end)
      end
    end)
  end
  vim.defer_fn(function()
    start_claude(1)
  end, 300)
end

--- Close the Claude pane for real (ends the claude process). With
--- `--continue` in claude_args, the next toggle resumes the conversation.
function M.close()
  local existing = find_claude()
  if not existing then
    vim.notify("herdr-claude: no Claude pane to close", vim.log.levels.WARN)
    return
  end
  herdr_json({ "pane", "close", existing.pane_id })
end

--- Type a context reference into the Claude pane's input, without submitting:
--- visual mode  -> "<relpath>:<start>-<end> "
--- in nvim-tree -> path of the node under the cursor
--- normal mode  -> current buffer's relative path
function M.send()
  local target = find_claude()
  if not target then
    vim.notify("herdr-claude: no Claude pane in this tab — toggle one open first", vim.log.levels.WARN)
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
