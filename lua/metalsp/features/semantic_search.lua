local M = {}
local db = require("metalsp.db")
local ui = require("metalsp.ui")
local utils = require("metalsp.utils")

function M.search(query)
  if not query or query == "" then
    utils.notify("Usage: :MetaLSPSearch <query>", vim.log.levels.WARN)
    return
  end
  local nodes = db.search_nodes(query)
  if not nodes or #nodes == 0 then
    utils.notify("No semantic matches found for: " .. query, vim.log.levels.INFO)
    return
  end
  
  local lines = { "# Semantic Search Results for: " .. query, "" }
  local items = {}
  
  for _, n in ipairs(nodes) do
    lines[#lines + 1] = "- **" .. ui.node_icon(n.type) .. " " .. n.name .. "** (`" .. utils.relative_path(n.file_path) .. ":" .. ((n.line_start or 0) + 1) .. "`)"
    items[#lines] = n -- map line to node
    if n.semantic_summary and n.semantic_summary ~= "" then
      lines[#lines + 1] = "  > " .. utils.one_line(n.semantic_summary)
    end
  end
  
  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end
  
  local event = require("nui.utils.autocmd").event
  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  
  local popup = Popup({
    enter = true,
    position = "50%",
    size = { width = width, height = height },
    relative = "editor",
    border = { style = "rounded", text = { top = " MetaLSP Semantic Search ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false, filetype = "markdown" },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder", wrap = true, cursorline = true },
  })
  
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].modifiable = false
  
  local close = function() popup:unmount() end
  popup:map("n", "q", close, { noremap = true })
  popup:map("n", "<Esc>", close, { noremap = true })
  popup:map("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    -- Find the closest item moving upwards if we are on the summary line
    local target = items[lnum] or items[lnum - 1]
    close()
    if target then
      local root = utils.get_project_root() or vim.fn.getcwd()
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. target.file_path))
      pcall(vim.api.nvim_win_set_cursor, 0, { (target.line_start or 0) + 1, 0 })
    end
  end, { noremap = true })
  popup:on(event.BufLeave, close, { once = true })
end

return M
