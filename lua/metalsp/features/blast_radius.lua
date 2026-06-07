--- MetaLSP.nvim — Feature 2: Blast Radius Analysis
--- Shows all functions/modules that transitively depend on the function under cursor.
--- Can trigger manually (keymap/command) or automatically on BufWritePost.

local M = {}

local db     = require("metalsp.db")
local ui     = require("metalsp.ui")
local utils  = require("metalsp.utils")

local function compact_names(nodes, max_names, max_chars)
  max_names = max_names or 5
  max_chars = max_chars or 120
  local names = {}
  for i, node in ipairs(nodes) do
    if i > max_names then break end
    names[#names + 1] = node.name or "?"
  end
  local text = table.concat(names, ", ")
  if #nodes > max_names then
    text = text .. string.format(", +%d more", #nodes - max_names)
  end
  if #text > max_chars then
    text = text:sub(1, max_chars - 3) .. "..."
  end
  return text
end

--- Show blast radius for a specific node ID.
--- @param node_id string
--- @param node_name string  for display
function M.show_for_id(node_id, node_name)
  local affected = db.get_blast_radius(node_id)

  if #affected == 0 then
    utils.notify("No dependents found for: " .. node_name)
    return
  end

  utils.notify(string.format("⚠  %d function(s) affected by changes to '%s'", #affected, node_name))
  ui.blast_radius_menu(node_name, affected)
end

--- Show blast radius for the function at the current cursor position.
--- @param bufnr integer|nil
function M.show_at_cursor(bufnr)
  bufnr = bufnr or 0

  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr))
  local line      = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed

  local node = db.get_node_at(file_path, line)
  if not node then
    utils.notify("No indexed function found at cursor. Save the file to index it.", vim.log.levels.WARN)
    return
  end

  M.show_for_id(node.id, node.name)
end

--- Automatically compute blast radius for a list of changed nodes.
--- Called from the indexing pipeline after BufWritePost.
--- @param changed_nodes table[] list of { id, name } (from change_detector)
function M.on_changed_nodes(changed_nodes)
  if #changed_nodes == 0 then return end

  -- Aggregate all affected nodes across all changed functions
  local all_affected = {}
  local seen = {}
  local changed_names = {}

  for _, sym in ipairs(changed_nodes) do
    changed_names[#changed_names + 1] = sym.name
    local affected = db.get_blast_radius(sym.id)
    for _, a in ipairs(affected) do
      if not seen[a.id] then
        seen[a.id] = true
        all_affected[#all_affected + 1] = a
      end
    end
  end

  if #all_affected == 0 then return end

  -- Show a compact notification and populate quickfix without opening menu.
  -- Keep this short to avoid Vim's hit-enter prompt on save.
  utils.notify(string.format(
    "⚠  %d dependent(s) affected by %d changed symbol(s): %s",
    #all_affected,
    #changed_nodes,
    compact_names(changed_nodes)
  ))

  -- Populate quickfix in background
  local qf_items = {}
  for _, node in ipairs(all_affected) do
    qf_items[#qf_items + 1] = {
      filename = node.file_path,
      lnum     = (node.line_start or 0) + 1,
      col      = 1,
      text     = utils.one_line(string.format("[depth:%d] %s %s", node.depth or 1, ui.node_icon(node.type), node.name)),
    }
  end
  vim.fn.setqflist(qf_items, "r")
  vim.fn.setqflist({}, "a", {
    title = utils.one_line("MetaLSP Blast Radius: " .. compact_names(changed_nodes, 8, 80)),
  })
end

--- Setup: register keymap and user command.
--- @param keymap string|boolean
function M.setup(keymap)
  vim.api.nvim_create_user_command("MetaLSPBlastRadius", function()
    M.show_at_cursor()
  end, { desc = "MetaLSP: Show Blast Radius for function at cursor" })

  if not keymap then return end

  vim.keymap.set("n", keymap, function()
    M.show_at_cursor()
  end, { desc = "MetaLSP: Blast Radius", noremap = true, silent = true })
end

return M
