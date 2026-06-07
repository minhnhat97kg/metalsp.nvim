local M = {}

local db = require("metalsp.db")
local ui = require("metalsp.ui")
local utils = require("metalsp.utils")

local state = {
  win = nil,
  buf = nil,
  root = nil,
  expanded_dirs = {},
  expanded_files = {},
  lines = {},
  line_items = {},
  width = 40,
}

local function is_valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function is_valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end

local function ensure_buf()
  if is_valid_buf(state.buf) then return state.buf end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "metalsp-explorer"
  vim.api.nvim_buf_set_name(state.buf, "MetaLSP Explorer")
  return state.buf
end

-- Collect per-file index/summary status.
-- Status meanings:
--   nil                  = not indexed
--   "indexed_no_summary" = indexed structurally, but no LLM summary yet
--   "summarized"         = at least one indexed node has an LLM summary
local function get_file_statuses()
  local files = {}
  local ok, res = pcall(function()
    local handle = db.handle()
    if not handle and db.init then
      db.init()
      handle = db.handle()
    end
    if not handle then return {} end

    local pid = utils.project_id(state.root)
    return handle:eval([[
      SELECT
        file_path,
        COUNT(*) AS node_count,
        SUM(CASE WHEN semantic_summary IS NOT NULL AND semantic_summary != '' THEN 1 ELSE 0 END) AS summary_count
      FROM nodes
      WHERE project_id = ?
      GROUP BY file_path
    ]], { pid })
  end)
  if ok and type(res) == "table" then
    for _, row in ipairs(res) do
      if row.file_path then
        local summaries = tonumber(row.summary_count or 0) or 0
        files[row.file_path] = summaries > 0 and "summarized" or "indexed_no_summary"
      end
    end
  end
  return files
end

-- Get tree structure of a directory
local function scan_dir(dir_path)
  local handle = vim.loop.fs_scandir(dir_path)
  if not handle then return {} end
  local items = {}
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if not name:match("^%.git$") and not name:match("^node_modules$") then
      table.insert(items, { name = name, type = type, path = dir_path .. "/" .. name })
    end
  end
  table.sort(items, function(a, b)
    if a.type == "directory" and b.type ~= "directory" then return true end
    if a.type ~= "directory" and b.type == "directory" then return false end
    return a.name < b.name
  end)
  return items
end

local function get_icon(name, ext)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, _ = devicons.get_icon(name, ext, { default = true })
    return icon or ""
  end
  return ""
end

local function render(target_buf, header, ns)
  if target_buf then state.buf = target_buf end
  if header ~= nil then state.header = header end
  if ns ~= nil then state.ns = ns end

  target_buf = state.buf
  header = state.header
  ns = state.ns

  if not is_valid_buf(target_buf) then return end
  state.root = vim.fs.normalize(state.root or utils.get_project_root() or vim.fn.getcwd())

  local file_statuses = get_file_statuses()

  local lines = {}
  local items = {}
  local highlights = {}

  local function add_line(text, item)
    lines[#lines + 1] = text
    items[#lines] = item
    if item.type == "file" then
      if item.status == "not_indexed" or item.status == "indexed_no_summary" then
        table.insert(highlights, { hl_group = "MetaLSPTreeWarn", line = #lines - 1 })
      else
        table.insert(highlights, { hl_group = "MetaLSPTreeFile", line = #lines - 1 })
      end
    elseif item.type == "dir" then
      table.insert(highlights, { hl_group = "MetaLSPTreeFile", line = #lines - 1 })
    elseif item.type == "node" then
      table.insert(highlights, { hl_group = "MetaLSPTreeSymbol", line = #lines - 1 })
    elseif item.type == "empty" then
      table.insert(highlights, { hl_group = "MetaLSPTreeMuted", line = #lines - 1 })
    end
  end

  if header then
    add_line(header, { type = "header" })
  else
    add_line("Files", { type = "header" })
    add_line("=" .. string.rep("=", state.width - 2), { type = "header" })
  end
  add_line("󰅚 not indexed · 󰁯 no summary", { type = "empty" })
  add_line("", { type = "empty" })

  local function walk(dir, indent, rel_dir)
    local children = scan_dir(dir)
    for _, child in ipairs(children) do
      local rel_path = rel_dir == "" and child.name or (rel_dir .. "/" .. child.name)
      if child.type == "directory" then
        local is_expanded = state.expanded_dirs[child.path]
        local icon = is_expanded and "▾" or "▸"
        add_line(string.format("%s%s  %s", indent, icon, child.name), { type = "dir", name = child.name, path = child.path })
        if is_expanded then
          walk(child.path, indent .. "  ", rel_path)
        end
      else
        local status = file_statuses[rel_path] or "not_indexed"
        -- Only show extra state icons for files that need action:
        --   󰅚 not indexed
        --   󰁯 indexed but no LLM summary yet
        -- Fully summarized files show only the normal devicon.
        local status_icon = status == "not_indexed" and " 󰅚" or (status == "indexed_no_summary" and " 󰁯" or "")
        local is_indexed = status ~= "not_indexed"
        local is_expanded = state.expanded_files[child.path]
        local expand_icon = is_expanded and "▾" or "▸"
        
        local ext = child.name:match("^.+(%..+)$") or ""
        ext = ext:sub(2)
        local file_icon = get_icon(child.name, ext)

        add_line(string.format("%s%s %s %s%s", indent, expand_icon, file_icon, child.name, status_icon), { type = "file", name = child.name, path = child.path, rel_path = rel_path, status = status, is_indexed = is_indexed })
        
        if is_expanded and is_indexed then
          local pid = utils.project_id(state.root)
          local nodes = db.get_file_nodes(rel_path, pid)
          local has_outline = false
          if nodes and #nodes > 0 then
            for _, n in ipairs(nodes) do
              if n.type ~= "variable" and n.type ~= "field" then
                has_outline = true
                add_line(string.format("%s    %s %s", indent, ui.node_icon(n.type), n.name), { type = "node", node = n })
              end
            end
          end
          if not has_outline then
            add_line(string.format("%s    (no outline)", indent), { type = "empty" })
          end
        end
      end
    end
  end

  walk(state.root, "", "")

  state.lines = lines
  state.line_items = items

  vim.bo[target_buf].modifiable = true
  vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
  
  -- Add highlight
  if ns then
    vim.api.nvim_buf_clear_namespace(target_buf, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(target_buf, ns, "MetaLSPTreeTitle", 0, 0, -1)
    
    for _, hl in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(target_buf, ns, hl.hl_group, hl.line, 0, -1)
    end
    
    -- Highlight tabs
    local line0 = lines[1] or ""
    local TAB_CONFIG = {
      { id = "now",   label = "now" },
      { id = "chat",  label = "chat" },
      { id = "explorer", label = "files" },
    }
    for _, t in ipairs(TAB_CONFIG) do
      local label = t.id == "explorer" and ("[" .. t.label .. "]") or t.label
      local s, e = line0:find(label, 1, true)
      if s then
        vim.api.nvim_buf_add_highlight(target_buf, ns, t.id == "explorer" and "MetaLSPTabActive" or "MetaLSPTabInactive", 0, s - 1, e)
      end
    end
  end

  vim.bo[target_buf].modifiable = false
end

function M.render_to_buffer(bufnr, header, ns, root)
  if root and root ~= "" then state.root = vim.fs.normalize(root) end
  render(bufnr, header, ns)
end


local function get_item_under_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_items[lnum]
end

local function on_cr()
  local item = get_item_under_cursor()
  if not item then return end

  if item.type == "dir" then
    state.expanded_dirs[item.path] = not state.expanded_dirs[item.path]
    render()
  elseif item.type == "file" then
    state.expanded_files[item.path] = not state.expanded_files[item.path]
    render()
  elseif item.type == "node" then
    local root = state.root or vim.fn.getcwd()
    vim.cmd("wincmd p")
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.node.file_path))
    pcall(vim.api.nvim_win_set_cursor, 0, { (item.node.line_start or 0) + 1, 0 })
  end
end

local function on_add()
  local item = get_item_under_cursor()
  local dir = state.root
  if item and item.type == "dir" then
    dir = item.path
  elseif item and item.type == "file" then
    dir = vim.fn.fnamemodify(item.path, ":h")
  end
  vim.ui.input({ prompt = "Create file/folder (end with / for folder): " }, function(input)
    if not input or input == "" then return end
    local full_path = dir .. "/" .. input
    if input:match("/$") then
      vim.fn.mkdir(full_path, "p")
    else
      local f = io.open(full_path, "w")
      if f then f:close() end
    end
    render()
  end)
end

local function on_delete()
  local item = get_item_under_cursor()
  if not item or (item.type ~= "file" and item.type ~= "dir") then return end
  vim.ui.select({"Yes", "No"}, { prompt = "Delete " .. item.name .. "?" }, function(choice)
    if choice == "Yes" then
      vim.fn.delete(item.path, "rf")
      render()
    end
  end)
end

local function on_o()
  local item = get_item_under_cursor()
  if not item then return end

  if item.type == "file" or item.type == "node" then
    local path = item.type == "file" and item.path or item.node.file_path
    local line = item.type == "node" and ((item.node.line_start or 0) + 1) or nil
    
    local ok, kt = pcall(require, "metalsp.features.knowledge_tree")
    if ok and kt.open_in_other_pane then
      -- If path is absolute (like item.path), open_in_other_pane handles it since it prepends root
      -- Wait, open_in_other_pane does: `abs = root .. "/" .. file_path`
      -- So we must pass the relative path!
      local rel_path = item.type == "file" and item.rel_path or item.node.file_path
      kt.open_in_other_pane(rel_path, line)
    end
  elseif item.type == "dir" then
    state.expanded_dirs[item.path] = not state.expanded_dirs[item.path]
    render()
  end
end
local function on_index()
  local item = get_item_under_cursor()
  if not item or (item.type ~= "file" and item.type ~= "dir") then return end

  local metalsp = require("metalsp")
  local total, indexed = 0, 0

  if item.type == "file" then
    total = 1
    if metalsp.index_file_path(item.path) then indexed = 1 end
  elseif item.type == "dir" then
    local function walk_index(dir)
      local children = scan_dir(dir)
      for _, child in ipairs(children) do
        if child.type == "directory" then
          walk_index(child.path)
        else
          total = total + 1
          if metalsp.index_file_path(child.path) then indexed = indexed + 1 end
        end
      end
    end
    walk_index(item.path)
  end

  require("metalsp.utils").notify(string.format("Explorer Indexing: %d/%d supported files indexed.", indexed, total))
  render()
end

local function on_rename()
  local item = get_item_under_cursor()
  if not item or (item.type ~= "file" and item.type ~= "dir") then return end
  vim.ui.input({ prompt = "Rename to: ", default = item.name }, function(input)
    if not input or input == "" or input == item.name then return end
    local new_path = vim.fn.fnamemodify(item.path, ":h") .. "/" .. input
    vim.fn.rename(item.path, new_path)
    -- Also delete from DB if it was a file to force re-index
    if item.type == "file" then
      pcall(db.delete_file_nodes, item.rel_path)
    end
    render()
  end)
end

function M.open()
  local buf = ensure_buf()
  if is_valid_win(state.win) then return end

  state.root = vim.fs.normalize(utils.get_project_root() or vim.fn.getcwd())
  
  vim.cmd("botright vertical " .. state.width .. "new")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, buf)

  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldenable = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = true

  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", { noremap = true, silent = true, callback = on_cr })
  vim.api.nvim_buf_set_keymap(buf, "n", "a", "", { noremap = true, silent = true, callback = on_add })
  vim.api.nvim_buf_set_keymap(buf, "n", "d", "", { noremap = true, silent = true, callback = on_delete })
  vim.api.nvim_buf_set_keymap(buf, "n", "r", "", { noremap = true, silent = true, callback = on_rename })
  vim.api.nvim_buf_set_keymap(buf, "n", "i", "", { noremap = true, silent = true, callback = on_index })
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { noremap = true, silent = true })
  
  render()
end

function M.toggle()
  if is_valid_win(state.win) then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
  else
    M.open()
  end
end

function M.on_cr() on_cr() end
function M.on_o() on_o() end
function M.on_add() on_add() end
function M.on_delete() on_delete() end
function M.on_rename() on_rename() end
function M.on_index() on_index() end

return M
