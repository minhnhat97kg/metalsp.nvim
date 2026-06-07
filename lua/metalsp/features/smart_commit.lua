local M = {}

local db = require("metalsp.db")
local ollama = require("metalsp.ollama")
local utils = require("metalsp.utils")
local config = require("metalsp.config")

local function get_staged_diff()
  local root = utils.get_project_root() or vim.fn.getcwd()
  local obj = vim.system({ "git", "diff", "--staged" }, { cwd = root, text = true }):wait()
  return obj.stdout or ""
end

local function get_modified_files()
  local root = utils.get_project_root() or vim.fn.getcwd()
  local obj = vim.system({ "git", "diff", "--staged", "--name-only" }, { cwd = root, text = true }):wait()
  local files = {}
  for _, line in ipairs(vim.split(obj.stdout or "", "\n", { trimempty = true })) do
    table.insert(files, line)
  end
  return files
end

function M.generate_commit()
  local diff = get_staged_diff()
  if not diff or diff == "" then
    utils.notify("No staged changes found. Please `git add` your changes first.", vim.log.levels.WARN)
    return
  end

  utils.notify("Generating Smart Commit Message... (Analyzing Blast Radius)")

  local files = get_modified_files()
  local affected_nodes = {}
  local blast_count = 0

  -- Find nodes affected by these files
  for _, file in ipairs(files) do
    local nodes = db.get_file_nodes(file)
    for _, n in ipairs(nodes) do
      table.insert(affected_nodes, n)
      local blast = db.get_blast_radius(n.id)
      blast_count = blast_count + #blast
    end
  end

  local context = { "Tool context: local graph/code reader" }
  context[#context + 1] = "Git Staged Diff:"
  context[#context + 1] = "```diff\n" .. diff:sub(1, 16000) .. "\n```"
  context[#context + 1] = string.format("Blast Radius Analysis: %d functions/components potentially affected.", blast_count)

  local prompt = [[
You are an expert developer writing a git commit message.
Based on the Git diff and the Blast Radius Analysis provided in the context, write a clear, conventional commit message.
Format your response as follows:

<type>(<scope>): <subject>

<body>
- Detail 1
- Detail 2

Risk/Impact Analysis:
(Mention the blast radius impact if applicable)

Respond ONLY with the commit message, no extra markdown or conversational text.
]]

  ollama.ask_with_context(table.concat(context, "\n\n"), prompt, function(answer, err)
    vim.schedule(function()
      if err or not answer then
        utils.notify("Commit generation failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "gitcommit"
      local lines = vim.split(answer, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      local width = math.min(80, vim.o.columns - 4)
      local height = math.min(#lines + 2, vim.o.lines - 6)

      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Smart Commit Message ",
        title_pos = "center",
      })

      -- Keymaps to save or close
      vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { noremap = true, silent = true })
      utils.notify("Press 'q' to close this window. You can yank the text.", vim.log.levels.INFO)
    end)
  end)
end

return M
