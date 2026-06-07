--- MetaLSP.nvim — Error analysis in right pane only.
--- No virtual text, no diagnostic interception, no auto model calls.

local M = {}

local ollama = require("metalsp.ollama")
local utils = require("metalsp.utils")
local db = require("metalsp.db")

local function diagnostic_items()
  local items = {}
  local project_root = utils.get_project_root() or vim.fn.getcwd()

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local abs = vim.api.nvim_buf_get_name(bufnr)
      if abs ~= "" then
        local file_path = utils.relative_path(abs, project_root)
        for _, d in ipairs(vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.ERROR })) do
          local line = (d.lnum or 0) + 1
          local node = db.get_node_at(file_path, d.lnum or 0)
          items[#items + 1] = {
            bufnr = bufnr,
            file_path = file_path,
            line = line,
            col = (d.col or 0) + 1,
            message = d.message or "",
            source = d.source,
            code = d.code,
            node = node,
            context = utils.get_context(bufnr, d.lnum or 0, 8),
          }
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.file_path == b.file_path then return (a.line or 0) < (b.line or 0) end
    return (a.file_path or "") < (b.file_path or "")
  end)
  return items
end

local function build_context(items)
  local lines = {
    "Analyze the following diagnostics. For each error, list:",
    "1. Error",
    "2. Likely cause",
    "3. How to fix",
    "4. Evidence from the provided code lines",
    "Be concise. Do not propose edits unless asked.",
    "",
  }

  for i, it in ipairs(items) do
    lines[#lines + 1] = string.format("## Error %d", i)
    lines[#lines + 1] = string.format("Location: %s:%d:%d", it.file_path, it.line or 1, it.col or 1)
    if it.node then lines[#lines + 1] = string.format("Function: %s (%s)", it.node.name or "?", it.node.type or "symbol") end
    lines[#lines + 1] = "Message: " .. utils.one_line(it.message or "")
    if it.source then lines[#lines + 1] = "Source: " .. tostring(it.source) end
    if it.code then lines[#lines + 1] = "Code: " .. tostring(it.code) end
    lines[#lines + 1] = "Context:"
    lines[#lines + 1] = "```"
    lines[#lines + 1] = it.context or ""
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end

  return table.concat(lines, "\n")
end

function M.explain_errors()
  local items = diagnostic_items()
  if #items == 0 then
    utils.notify("No ERROR diagnostics found", vim.log.levels.INFO)
    return
  end

  local ok, kt = pcall(require, "metalsp.features.knowledge_tree")
  if ok and kt.show_error_fix then
    kt.show_error_fix(items, "Analyzing errors…")
  end

  local question = [[
List every error grouped by file/function. For each error include:
- what the error means
- likely root cause
- concrete fix steps
- evidence with file/line references
Keep the answer concise and actionable.
]]

  ollama.ask_with_context(build_context(items), question, function(answer, err)
    vim.schedule(function()
      if err or not answer then
        utils.notify("Error analysis failed: " .. tostring(err or "empty response"), vim.log.levels.WARN)
        if ok and kt.show_error_fix then kt.show_error_fix(items, "Error analysis failed: " .. tostring(err or "empty response")) end
        return
      end
      if ok and kt.show_error_fix then kt.show_error_fix(items, answer) end
    end)
  end)
end

function M.explain_at_cursor()
  M.explain_errors()
end

function M.setup()
  vim.keymap.set("n", "<leader>me", function()
    M.explain_errors()
  end, { desc = "MetaLSP: Analyze errors in right pane", noremap = true, silent = true })

  vim.api.nvim_create_user_command("MetaLSPErrorFix", function()
    M.explain_errors()
  end, { desc = "MetaLSP: Analyze all errors in right pane" })

  vim.api.nvim_create_user_command("MetaLSPExplainError", function()
    M.explain_errors()
  end, { desc = "MetaLSP: Analyze errors in right pane" })
end

return M
