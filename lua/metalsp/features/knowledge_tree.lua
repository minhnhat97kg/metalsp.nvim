--- MetaLSP.nvim — Knowledge Tree
--- Sidebar tree of indexed project files and graph-backed symbols.

local M = {}

local db     = require("metalsp.db")
local ui     = require("metalsp.ui")
local utils  = require("metalsp.utils")
local ollama = require("metalsp.ollama")
local lsp_indexer = require("metalsp.lsp_indexer")
local prompts = require("metalsp.prompts")
local tools = require("metalsp.tools")
local config = require("metalsp.config")

local state = {
  win = nil,       -- top knowledge window
  buf = nil,
  chat_win = nil,  -- bottom memory/input window
  chat_buf = nil,
  width = 30, -- match nvim-tree default width
  chat_height = nil, -- computed as 50% of sidebar height
  tab = "now", -- now, chat, explorer
  source_win = nil,
  live_node = nil,
  live_loading = false,
  live_lines = nil,
  live_line_items = {},
  live_mode = nil,
  live_refresh_timer = nil,
  live_last_key = nil,
  expanded = {},
  line_items = {},
  summarizing = {},
  focus_node = nil,
  focus_history = {},
  pins = {},
  focus_context = nil,
  chat_lines = {},
  error_lines = nil,
  error_items = {},
  scope_folder = nil,
  project_root = nil,
  show_variables = false,
  relation_view = nil, -- nil | "calls" | "callers"
  compact = false,     -- toggle for NOW tab compact view
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local NS = vim.api.nvim_create_namespace("metalsp-knowledge-tree")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "MetaLSPTreeTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeFolder", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeFile", { link = "NvimTreeFileName", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeSymbol", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeMuted", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeOk", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeWarn", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTreeBusy", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPMemoryUser", { link = "Question", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPMemoryAssistant", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPLiveTool", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPLiveResult", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPLiveHeading", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTabActive", { link = "TabLineSel", default = true })
  vim.api.nvim_set_hl(0, "MetaLSPTabInactive", { link = "TabLine", default = true })
end

local TAB_CONFIG = {
  { id = "now",   label = "now",   icon = "󰔚" },
  { id = "chat",  label = "chat",  icon = "󰭹" },
  { id = "explorer", label = "files", icon = "" },
}

local function tab_header(active)
  local parts = {}
  for _, t in ipairs(TAB_CONFIG) do
    local label = active == t.id and ("[" .. t.label .. "]") or t.label
    parts[#parts + 1] = t.icon .. " " .. label
  end
  return table.concat(parts, " | ")
end

local function highlight_tabs(buf, lnum, active)
  local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
  for _, t in ipairs(TAB_CONFIG) do
    local label = active == t.id and ("[" .. t.label .. "]") or t.label
    local s, e = line:find(label, 1, true)
    if s then
      vim.api.nvim_buf_add_highlight(buf, NS, active == t.id and "MetaLSPTabActive" or "MetaLSPTabInactive", lnum, s - 1, e)
    end
  end
end

local function ensure_buf()
  if is_valid_buf(state.buf) then return state.buf end
  setup_highlights()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "metalsp-tree"
  vim.api.nvim_buf_set_name(state.buf, "MetaLSP Knowledge Tree")
  return state.buf
end

local function ensure_chat_buf()
  if is_valid_buf(state.chat_buf) then return state.chat_buf end
  setup_highlights()
  state.chat_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.chat_buf].buftype = "nofile"
  vim.bo[state.chat_buf].bufhidden = "hide"
  vim.bo[state.chat_buf].swapfile = false
  vim.bo[state.chat_buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(state.chat_buf, "MetaLSP Memory")
  return state.chat_buf
end

local function open_win()
  local buf = ensure_buf()
  if is_valid_win(state.win) then return end

  vim.cmd("topleft vertical " .. state.width .. "new")
  state.win = vim.api.nvim_get_current_win()
  state.chat_win = state.win
  state.chat_buf = buf
  vim.api.nvim_win_set_buf(state.win, buf)
  vim.wo[state.win].winfixwidth = true
  vim.wo[state.win].winfixheight = true
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldenable = false
  vim.wo[state.win].wrap = true
  vim.wo[state.win].linebreak = true
  vim.wo[state.win].cursorline = true
end

local function close_win()
  if is_valid_win(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.live_refresh_timer then
    state.live_refresh_timer:stop()
    state.live_refresh_timer:close()
    state.live_refresh_timer = nil
  end
  state.win = nil
  state.chat_win = nil
end

local function pick_window(windows)
  if #windows == 0 then return nil end
  if #windows == 1 then return windows[1] end

  local chars = { "A", "S", "D", "F", "J", "K", "L", "H", "G", "W", "E" }
  local char_to_win = {}
  local floats = {}

  for i, win in ipairs(windows) do
    local char = chars[i] or tostring(i)
    char_to_win[string.lower(char)] = win
    char_to_win[string.upper(char)] = win

    local width = vim.api.nvim_win_get_width(win)
    local height = vim.api.nvim_win_get_height(win)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " " .. char .. " " })

    local float_win = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = win,
      width = 3,
      height = 1,
      row = math.floor(height / 2),
      col = math.floor(width / 2) - 1,
      style = "minimal",
      border = "single"
    })
    
    pcall(vim.api.nvim_win_set_option, float_win, "winhl", "NormalFloat:WarningMsg,FloatBorder:WarningMsg")
    table.insert(floats, float_win)
  end

  vim.cmd("redraw")
  local char_code = vim.fn.getchar()
  
  for _, float_win in ipairs(floats) do
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end

  if type(char_code) ~= "number" then return nil end
  return char_to_win[string.char(char_code)]
end

function M.open_in_other_pane(file_path, line)
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local abs = root .. "/" .. file_path
  local current = vim.api.nvim_get_current_win()
  
  local valid_wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.win and win ~= state.chat_win and win ~= current then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" then
        table.insert(valid_wins, win)
      end
    end
  end

  local target = pick_window(valid_wins)

  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  else
    if #valid_wins > 0 then return end -- user cancelled picking
    vim.cmd("wincmd p")
    local w2 = vim.api.nvim_get_current_win()
    if w2 == current or vim.bo[vim.api.nvim_win_get_buf(w2)].buftype ~= "" then
      vim.cmd("botright vertical new")
    end
  end
  if not pcall(vim.cmd, "edit " .. vim.fn.fnameescape(abs)) then
    -- fallback in case it fails to create or focus
    vim.cmd("wincmd p")
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end
  if line then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
end

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local VARIABLE_TYPES = { variable = true, constant = true, field = true }

local function tree_insert(root, file_path, nodes)
  local cur = root
  local parts = split_path(file_path)
  for i, part in ipairs(parts) do
    local is_file = i == #parts
    cur.children = cur.children or {}
    cur.child_map = cur.child_map or {}

    local child = cur.child_map[part]
    if not child then
      local path_parts = {}
      for j = 1, i do path_parts[j] = parts[j] end
      local path = table.concat(path_parts, "/")
      child = {
        name = part,
        path = path,
        type = is_file and "file" or "dir",
        children = {},
        child_map = {},
      }
      cur.child_map[part] = child
      cur.children[#cur.children + 1] = child
    end
    cur = child
  end

  local function symbol_span(n)
    return (n.line_start or 0), (n.line_end or n.line_start or 0)
  end

  local roots = {}
  for _, n in ipairs(nodes or {}) do
    n.children = {}
    n.child_map = nil
  end

  local filtered_nodes = {}
  for _, n in ipairs(nodes or {}) do
    if state.show_variables or not VARIABLE_TYPES[n.type] then
      filtered_nodes[#filtered_nodes + 1] = n
    end
  end

  for _, child_node in ipairs(filtered_nodes) do
    local cs, ce = symbol_span(child_node)
    local parent = nil
    for _, maybe_parent in ipairs(filtered_nodes) do
      if maybe_parent.id ~= child_node.id then
        local ps, pe = symbol_span(maybe_parent)
        if ps <= cs and pe >= ce and (ps < cs or pe > ce) then
          if not parent then
            parent = maybe_parent
          else
            local pps, ppe = symbol_span(parent)
            if (pe - ps) < (ppe - pps) then parent = maybe_parent end
          end
        end
      end
    end

    if parent then
      parent.children = parent.children or {}
      parent.children[#parent.children + 1] = child_node
    else
      roots[#roots + 1] = child_node
    end
  end

  local function sort_symbols(list)
    table.sort(list or {}, function(a, b)
      if (a.line_start or 0) == (b.line_start or 0) then
        return (a.line_end or 0) > (b.line_end or 0)
      end
      return (a.line_start or 0) < (b.line_start or 0)
    end)
    for _, n in ipairs(list or {}) do sort_symbols(n.children or {}) end
  end
  sort_symbols(roots)

  cur.symbols = roots
end

local function node_belongs_to_current_folder(node, folder, project_root)
  if not node or not node.file_path or node.file_path == "" then return false end

  if node.file_path:sub(1, 1) == "/" then
    return node.file_path == folder or vim.startswith(node.file_path, folder .. "/")
  end

  -- DB paths are project-relative. Convert the current location to a relative
  -- prefix and only show files under that location.
  project_root = vim.fs.normalize(project_root or utils.get_project_root() or vim.fn.getcwd())
  folder = vim.fs.normalize(folder or project_root)
  local rel_scope = utils.relative_path(folder, project_root)
  if rel_scope == "." or rel_scope == "" then
    return vim.uv.fs_stat(project_root .. "/" .. node.file_path) ~= nil
  end
  return node.file_path == rel_scope
    or vim.startswith(node.file_path, rel_scope .. "/")
end

local function build_tree()
  local root = { name = "", path = "", type = "root", children = {}, child_map = {} }
  local project_root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local folder = state.scope_folder or utils.current_location_folder()
  folder = vim.fs.normalize(folder)

  local by_file = {}
  for _, node in ipairs(db.dump_nodes(utils.project_id(project_root))) do
    if node_belongs_to_current_folder(node, folder, project_root) then
      by_file[node.file_path] = by_file[node.file_path] or {}
      by_file[node.file_path][#by_file[node.file_path] + 1] = node
    end
  end

  for file_path, nodes in pairs(by_file) do
    table.sort(nodes, function(a, b) return (a.line_start or 0) < (b.line_start or 0) end)
    tree_insert(root, file_path, nodes)
  end

  local function sort_children(n)
    table.sort(n.children or {}, function(a, b)
      if a.type ~= b.type then return a.type == "dir" end
      return a.name < b.name
    end)
    for _, child in ipairs(n.children or {}) do sort_children(child) end
  end
  sort_children(root)
  return root
end

local append_buffer_safe_lines
local sanitize_buffer_lines
local summarize_node_confirm

local function add_line(lines, item, text)
  lines[#lines + 1] = text
  state.line_items[#lines] = item
end

local function render_symbol(lines, sym, depth)
  local indent = string.rep("  ", depth)
  local has_children = #(sym.children or {}) > 0
  local expanded = state.expanded[sym.id]
  local marker = has_children and (expanded and "▾ " or "▸ ") or "  "
  local suffix = state.summarizing[sym.id] and " …" or ""

  add_line(lines, { type = "symbol", node = sym, path = sym.id },
    indent .. marker .. ui.node_icon(sym.type) .. " " .. sym.name .. suffix)

  if has_children and expanded then
    for _, child in ipairs(sym.children or {}) do
      render_symbol(lines, child, depth + 1)
    end
  end
end

local function render_node(lines, node, depth)
  local indent = string.rep("  ", depth)
  local expanded = state.expanded[node.path]

  if node.type == "dir" then
    add_line(lines, node, indent .. (expanded and "▾ " or "▸ ") .. (expanded and " " or " ") .. node.name)
    if expanded then
      for _, child in ipairs(node.children or {}) do render_node(lines, child, depth + 1) end
    end
    return
  end

  if node.type == "file" then
    local icon = ui.get_icon(node.name)
    local count = #(node.symbols or {})
    add_line(lines, node, indent .. (expanded and "▾ " or "▸ ") .. icon .. " " .. node.name .. " (" .. count .. ")")
    if expanded then
      for _, sym in ipairs(node.symbols or {}) do
        render_symbol(lines, sym, depth + 1)
      end
    end
  end
end

local function focus_children(node)
  if not node then return {} end
  local children = {}
  for _, n in ipairs(db.get_file_nodes(node.file_path)) do
    if n.id ~= node.id
        and (n.line_start or 0) >= (node.line_start or 0)
        and (n.line_end or n.line_start or 0) <= (node.line_end or node.line_start or 0)
        and VARIABLE_TYPES[n.type] then
      children[#children + 1] = n
    end
  end
  table.sort(children, function(a, b) return (a.line_start or 0) < (b.line_start or 0) end)
  return children
end

local function current_source_focus_node()
  local win = is_valid_win(state.source_win) and state.source_win or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr), state.project_root)
  local line = vim.api.nvim_win_get_cursor(win)[1] - 1
  return db.get_node_at(file_path, line)
end

local function find_tests_for_node(node)
  if not node or not node.name or node.name == "" then return {} end
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local obj = vim.system({
    "rg", "-n", "--no-heading", node.name,
    "-g", "*_test.go", "-g", "*.test.ts", "-g", "*.spec.ts", "-g", "*_spec.lua", "-g", "*test*",
  }, { cwd = root, text = true }):wait()
  local out = {}
  for _, l in ipairs(vim.split(obj.stdout or "", "\n", { trimempty = true })) do
    local file, lnum, text = l:match("^([^:]+):(%d+):(.*)$")
    if file and lnum then
      out[#out + 1] = { file_path = file, line = tonumber(lnum), text = vim.trim(text or "") }
      if #out >= 8 then break end
    end
  end
  return out
end

local function diagnostics_for_node(node)
  local out = {}
  if not node then return out end
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local abs = root .. "/" .. node.file_path
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
      for _, d in ipairs(vim.diagnostic.get(b)) do
        if d.lnum >= (node.line_start or 0) and d.lnum <= (node.line_end or node.line_start or 0) then
          out[#out + 1] = { line = (d.lnum or 0) + 1, message = utils.one_line(d.message or ""), severity = d.severity }
        end
      end
      break
    end
  end
  return out
end

local function node_changed(node)
  if not node or not node.file_path then return false end
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local obj = vim.system({ "git", "diff", "--name-only", "--", node.file_path }, { cwd = root, text = true }):wait()
  if vim.trim(obj.stdout or "") ~= "" then return true end
  local staged = vim.system({ "git", "diff", "--staged", "--name-only", "--", node.file_path }, { cwd = root, text = true }):wait()
  return vim.trim(staged.stdout or "") ~= ""
end

local function render_focus_tree(lines, node)
  if not node then
    lines[#lines + 1] = "No focused symbol."
    lines[#lines + 1] = "Move cursor into a function and press `a`."
    return
  end

  state.focus_node = node
  local vars = focus_children(node)
  local calls = db.get_direct_dependencies(node.id)
  local callers = db.get_direct_dependents(node.id)
  local tests = find_tests_for_node(node)
  local diagnostics = diagnostics_for_node(node)
  local changed = node_changed(node)

  if #state.focus_history > 0 then
    local crumbs = {}
    local start = math.max(1, #state.focus_history - 2)
    for i = start, #state.focus_history do crumbs[#crumbs + 1] = state.focus_history[i].name end
    crumbs[#crumbs + 1] = node.name
    lines[#lines + 1] = table.concat(crumbs, " > ")
  end
  lines[#lines + 1] = node.file_path
  lines[#lines + 1] = ""
  add_line(lines, { type = "focus", node = node }, "Current")
  add_line(lines, { type = "symbol", node = node }, "  " .. ui.node_icon(node.type) .. " " .. node.name)
  if node.semantic_summary and node.semantic_summary ~= "" then
    lines[#lines + 1] = "    " .. utils.one_line(node.semantic_summary):sub(1, 120)
  end
  if node.thinking and node.thinking ~= "" then
    lines[#lines + 1] = "    flow: " .. utils.one_line(node.thinking):sub(1, 100)
  end
  if state.show_variables then
    for _, v in ipairs(vars) do
      add_line(lines, { type = "symbol", node = v }, "    " .. ui.node_icon(v.type) .. " " .. v.name)
    end
  elseif #vars > 0 then
    lines[#lines + 1] = "    " .. #vars .. " vars hidden (v)"
  end

  local function related_section(title, nodes, empty)
    lines[#lines + 1] = ""
    add_line(lines, { type = "section", name = title }, title)
    if #nodes == 0 then
      lines[#lines + 1] = "  " .. empty
      return
    end
    table.sort(nodes, function(a, b)
      if (a.file_path or "") == (b.file_path or "") then return (a.line_start or 0) < (b.line_start or 0) end
      return (a.file_path or "") < (b.file_path or "")
    end)
    local last_file = nil
    for _, n in ipairs(nodes) do
      if n.file_path ~= last_file then
        last_file = n.file_path
        add_line(lines, { type = "file", path = n.file_path }, "  " .. n.file_path)
      end
      add_line(lines, { type = "related", node = n }, string.format("    %s %s:%d", ui.node_icon(n.type), n.name or "?", (n.line_start or 0) + 1))
    end
  end

  lines[#lines + 1] = ""
  add_line(lines, { type = "section", name = "Diagnostics" }, "Diagnostics")
  if #diagnostics == 0 then
    lines[#lines + 1] = "  none"
  else
    for _, d in ipairs(diagnostics) do
      add_line(lines, { type = "diagnostic", node = node, line = d.line }, "  line " .. d.line .. ": " .. d.message)
    end
  end

  lines[#lines + 1] = ""
  add_line(lines, { type = "section", name = "Changes" }, "Changes")
  if changed then
    add_line(lines, { type = "changes", node = node }, "  file changed (g review)")
  else
    lines[#lines + 1] = "  none"
  end

  related_section("Calls", calls, "none indexed (L)")
  related_section("Callers", callers, "none indexed (L)")

  lines[#lines + 1] = ""
  add_line(lines, { type = "section", name = "Tests" }, "Tests")
  if #tests == 0 then
    lines[#lines + 1] = "  none found"
  else
    for _, t in ipairs(tests) do
      add_line(lines, { type = "file", path = t.file_path, line = t.line }, "  " .. t.file_path .. ":" .. t.line)
    end
  end

  lines[#lines + 1] = ""
  add_line(lines, { type = "section", name = "Next checks" }, "Next checks")
  local added = false
  if #diagnostics > 0 then lines[#lines + 1] = "  fix diagnostics first"; added = true end
  if changed then lines[#lines + 1] = "  review current changes with g"; added = true end
  if #callers > 0 then lines[#lines + 1] = "  check callers before behavior changes"; added = true end
  if #calls > 0 then lines[#lines + 1] = "  verify dependency error/side-effect paths"; added = true end
  if #tests == 0 then lines[#lines + 1] = "  add/find tests for this path"; added = true end
  if not added then lines[#lines + 1] = "  looks clean" end

  if next(state.pins) then
    lines[#lines + 1] = ""
    add_line(lines, { type = "section", name = "Pinned" }, "Pinned")
    for _, p in pairs(state.pins) do
      add_line(lines, { type = "related", node = p }, "  " .. ui.node_icon(p.type) .. " " .. p.name)
    end
  end
end

local function render_graph_tab()
  local buf = ensure_buf()
  vim.bo[buf].filetype = "metalsp-tree"
  state.line_items = {}

  local node = state.focus_node or state.live_node or current_source_focus_node()
  local lines = {
    tab_header("graph"),
    "focus" .. (state.show_variables and "  +vars" or ""),
    "",
  }
  render_focus_tree(lines, node)

  vim.bo[buf].modifiable = true
  lines = sanitize_buffer_lines(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeTitle", 0, 0, -1)
  highlight_tabs(buf, 0, "graph")
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", 1, 0, -1)
  for lnum, item in pairs(state.line_items) do
    if item.type == "file" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeFile", lnum - 1, 0, -1)
    elseif item.type == "section" or item.type == "focus" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", lnum - 1, 0, -1)
    elseif item.type == "diagnostic" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeWarn", lnum - 1, 0, -1)
    elseif item.type == "changes" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeBusy", lnum - 1, 0, -1)
    elseif item.type == "symbol" or item.type == "related" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeSymbol", lnum - 1, 0, -1)
    end
  end
  vim.bo[buf].modifiable = false
  utils.render_markdown(buf)
end

local function render_live_tab()
  local buf = ensure_buf()
  vim.bo[buf].filetype = "markdown"
  state.line_items = {}
  local mode_suffix = state.compact and " (compact)" or " (full)"
  local lines = {
    tab_header("now"),
    "Now" .. (state.live_mode and (" / " .. state.live_mode) or "") .. mode_suffix,
    "_C: toggle compact · s: summary · L: LSP index · g: git diff · Space: actions_",
    "",
  }

  if state.live_loading then
    lines[#lines + 1] = "Analyzing…"
  elseif state.live_lines then
    local offset = #lines
    append_buffer_safe_lines(lines, state.live_lines)
    for lnum, item in pairs(state.live_line_items or {}) do
      state.line_items[offset + lnum] = item
    end
  else
    lines[#lines + 1] = "Move cursor in code, or press `a` to inspect."
  end

  if state.error_lines and #state.error_lines > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "# Errors"
    local offset = #lines
    append_buffer_safe_lines(lines, state.error_lines)
    for lnum, item in pairs(state.error_items or {}) do
      state.line_items[offset + lnum] = item
    end
  end

  vim.bo[buf].modifiable = true
  lines = sanitize_buffer_lines(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeTitle", 0, 0, -1)
  highlight_tabs(buf, 0, "now")
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", 1, 0, -1)

  local in_tools = false
  local in_result = false
  for i, line in ipairs(lines) do
    if line:match("^#") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPLiveHeading", i - 1, 0, -1)
    end
    if line:match("^## Tool calls") or line:match("^#### Tools") then
      in_tools = true
      in_result = false
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPLiveTool", i - 1, 0, -1)
    elseif line:match("^## Result") then
      in_tools = false
      in_result = true
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPLiveHeading", i - 1, 0, -1)
    elseif in_tools and (line:match("^%- `") or line == "") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPLiveTool", i - 1, 0, -1)
    elseif in_result and line ~= "" then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPLiveResult", i - 1, 0, -1)
    end
  end
  vim.bo[buf].modifiable = false
  utils.render_markdown(buf)
  vim.cmd("redraw")
end

local function render_error_tab()
  local buf = ensure_buf()
  vim.bo[buf].filetype = "markdown"
  state.line_items = {}
  local lines = {
    tab_header("error"),
    "Errors",
    "",
  }

  if state.error_lines then
    append_buffer_safe_lines(lines, state.error_lines)
    for lnum, item in pairs(state.error_items or {}) do
      state.line_items[#lines - #state.error_lines + lnum] = item
    end
  else
    lines[#lines + 1] = "No errors analyzed yet. Run `:MetaLSPErrorFix`."
  end

  vim.bo[buf].modifiable = true
  lines = sanitize_buffer_lines(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeTitle", 0, 0, -1)
  highlight_tabs(buf, 0, "error")
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", 1, 0, -1)
  vim.bo[buf].modifiable = false
  utils.render_markdown(buf)
end

local render_chat

function M.refresh()
  if state.tab == "chat" then
    if render_chat then render_chat() end
  elseif state.tab == "explorer" then
    local ok, exp = pcall(require, "metalsp.features.explorer")
    if ok and exp.render_to_buffer then exp.render_to_buffer(ensure_buf(), tab_header("explorer"), NS, state.project_root) end
  else
    render_live_tab()
  end
end

local function is_bad_summary(summary)
  if not summary or summary == "" then return true end
  local lower = tostring(summary):lower()
  if lower:find("can't assist", 1, true)
      or lower:find("cannot assist", 1, true)
      or lower:find("i'm sorry", 1, true)
      or lower:find("i am sorry", 1, true) then
    return true
  end
  local ok, decoded = pcall(vim.json.decode, summary)
  return ok and type(decoded) == "table" and decoded.response ~= nil
end

local function format_side_effects(node)
  local out = {}
  if node.side_effects and node.side_effects ~= "" then
    local ok, decoded = pcall(vim.json.decode, node.side_effects)
    if ok and type(decoded) == "table" then
      for _, se in ipairs(decoded) do
        out[#out + 1] = string.format("  • %s → %s", se.type or "?", se.target or "")
      end
    end
  end
  if #out == 0 then out[1] = "  • none/unknown" end
  return out
end

local function get_node_raw_code(node)
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local abs_path = root .. "/" .. node.file_path

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
      local lines = vim.api.nvim_buf_get_lines(b, node.line_start, node.line_end + 1, false)
      return table.concat(lines, "\n")
    end
  end

  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok then return "" end
  local slice = {}
  for i = node.line_start + 1, math.min(node.line_end + 1, #lines) do
    slice[#slice + 1] = lines[i]
  end
  return table.concat(slice, "\n")
end

local function build_symbol_lines(node)
  local deps = db.get_direct_dependencies(node.id)
  local refs = db.get_direct_dependents(node.id)
  local blast = db.get_blast_radius(node.id)
  local line_items = {}

  local lines = {
    string.format("# %s %s", ui.node_icon(node.type), node.name),
    string.format("`%s:%d`", node.file_path, (node.line_start or 0) + 1),
    "",
    "## Summary",
    state.summarizing[node.id]
        and "󰔟 Summarizing with Ollama…"
      or (not is_bad_summary(node.semantic_summary) and node.semantic_summary or "No valid summary yet. Press s to generate one."),
    "",
    "Implementation flow:",
    (node.thinking and node.thinking ~= "") and node.thinking or "  • none generated yet",
    "",
    "## Side effects",
  }

  vim.list_extend(lines, format_side_effects(node))

  local function add_jump_line(n, relation)
    local lnum = #lines + 1
    lines[lnum] = string.format("- %s `%s` — `%s:%d` _%s_",
      ui.node_icon(n.type), n.name or "?", n.file_path or "?", (n.line_start or 0) + 1, relation or "RELATED")
    line_items[lnum] = n
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Calls / dependencies"
  if #deps == 0 then
    lines[#lines + 1] = "- none indexed — press `L` to use LSP"
  else
    for _, d in ipairs(deps) do add_jump_line(d, d.relation_type or "CALLS") end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Callers / references"
  if #refs == 0 then
    lines[#lines + 1] = "- none indexed — press `L` to use LSP"
  else
    for _, r in ipairs(refs) do add_jump_line(r, r.relation_type or "REFERENCES") end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Impact"
  lines[#lines + 1] = "- Blast radius: **" .. #blast .. "** transitive dependent(s)"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "_Enter_: open item/file · `s`: summary · `L`: index LSP · `q`: close"
  return lines, line_items
end

local function build_compact_context(node)
  local deps = db.get_direct_dependencies(node.id)
  local refs = db.get_direct_dependents(node.id)
  local blast = db.get_blast_radius(node.id)
  local side_effects = format_side_effects(node)

  local context = {
    string.format("Node: %s %s (%s)", ui.node_icon(node.type), node.name, node.type or "symbol"),
    string.format("Location: %s:%d", node.file_path, (node.line_start or 0) + 1),
    "Summary: " .. ((not is_bad_summary(node.semantic_summary) and node.semantic_summary) or "not available"),
    "Side effects:",
  }
  vim.list_extend(context, side_effects)
  context[#context + 1] = string.format("Related counts: %d dependencies, %d references, %d blast-radius", #deps, #refs, #blast)

  local function append_some(title, nodes)
    context[#context + 1] = title .. ":"
    if #nodes == 0 then
      context[#context + 1] = "  • none indexed"
      return
    end
    for i, n in ipairs(nodes) do
      if i > 8 then
        context[#context + 1] = "  • …"
        break
      end
      context[#context + 1] = string.format("  • %s %s (%s:%d)", ui.node_icon(n.type), n.name, n.file_path or "?", (n.line_start or 0) + 1)
    end
  end
  append_some("Dependencies", deps)
  append_some("References", refs)

  return table.concat(context, "\n"), { deps = #deps, refs = #refs, blast = #blast }
end

local function format_code_excerpt(node, max_lines)
  if not node then return "" end
  max_lines = max_lines or 120
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local abs_path = node.file_path and (root .. "/" .. node.file_path) or nil
  if not abs_path then return "" end

  local ok, file_lines = pcall(vim.fn.readfile, abs_path)
  if not ok or type(file_lines) ~= "table" then return "" end

  local start_l = math.max(0, node.line_start or 0)
  local end_l = math.max(start_l, node.line_end or start_l)
  if end_l - start_l + 1 > max_lines then
    end_l = start_l + max_lines - 1
  end

  local out = {}
  out[#out + 1] = string.format("File: %s:%d-%d", node.file_path, start_l + 1, end_l + 1)
  out[#out + 1] = "```"
  for i = start_l + 1, math.min(end_l + 1, #file_lines) do
    out[#out + 1] = string.format("%4d │ %s", i, file_lines[i])
  end
  out[#out + 1] = "```"
  return table.concat(out, "\n")
end

local function build_git_context()
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local status_obj = vim.system({ "git", "status", "--short" }, { cwd = root, text = true }):wait()
  local status_lines = vim.split(status_obj.stdout or "", "\n", { trimempty = true })

  local context = { "Git changes / status:" }
  if #status_lines == 0 then
    context[#context + 1] = "- No uncommitted changes."
  else
    context[#context + 1] = string.format("- Total changed files: %d", #status_lines)
    for _, l in ipairs(status_lines) do
      context[#context + 1] = "  " .. l
    end

    local diff_obj = vim.system({ "git", "diff", "--stat" }, { cwd = root, text = true }):wait()
    local diff_stat = vim.trim(diff_obj.stdout or "")
    if diff_stat ~= "" then
      context[#context + 1] = "Git diff stat:"
      for line in (diff_stat .. "\n"):gmatch("(.-)\n") do
        context[#context + 1] = "  " .. line
      end
    end
  end
  return table.concat(context, "\n")
end

local function build_issues_context(max_items)
  max_items = max_items or 50
  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  local diags = vim.diagnostic.get(nil)

  local counts = { error = 0, warn = 0, info = 0, hint = 0 }
  local list = {}

  for _, d in ipairs(diags) do
    local sev = vim.diagnostic.severity[d.severity] or "unknown"
    local sev_key = sev:lower()
    if counts[sev_key] ~= nil then
      counts[sev_key] = counts[sev_key] + 1
    end

    local bufnr = d.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local rel = utils.relative_path(name, root)
        list[#list + 1] = {
          severity = sev_key:upper(),
          file = rel,
          line = (d.lnum or 0) + 1,
          col = (d.col or 0) + 1,
          message = utils.one_line(d.message or "")
        }
      end
    end
  end

  local context = { "LSP Diagnostics / Errors:" }
  context[#context + 1] = string.format("- Summary: %d error(s), %d warning(s), %d info, %d hint(s)",
    counts.error, counts.warn, counts.info, counts.hint)

  if state.error_lines and #state.error_lines > 0 then
    context[#context + 1] = "MetaLSP analyzed errors:"
    for _, line in ipairs(state.error_lines) do
      if line ~= "" then context[#context + 1] = "  " .. line end
    end
  end

  if #list == 0 then
    context[#context + 1] = "- No LSP diagnostics found."
  else
    table.sort(list, function(a, b)
      if a.severity ~= b.severity then
        return a.severity == "ERROR" or (a.severity == "WARN" and b.severity ~= "ERROR")
      end
      if a.file ~= b.file then return a.file < b.file end
      return a.line < b.line
    end)

    for i, item in ipairs(list) do
      if i > max_items then
        context[#context + 1] = string.format("- … %d more diagnostic(s)", #list - max_items)
        break
      end
      context[#context + 1] = string.format("- [%s] %s:%d:%d %s",
        item.severity, item.file, item.line, item.col, item.message)
    end
  end

  local total_count = counts.error + counts.warn + counts.info + counts.hint
  return table.concat(context, "\n"), total_count
end

local function build_graph_code_context(node, question)
  if not node then return "", {} end
  local deps = db.get_direct_dependencies(node.id)
  local refs = db.get_direct_dependents(node.id)
  local q = tostring(question or ""):lower()
  local include_refs = q:find("caller", 1, true) or q:find("reference", 1, true) or q:find("blast", 1, true) or q:find("impact", 1, true)
  local include_deps = q:find("depend", 1, true) or q:find("call", 1, true) or q:find("flow", 1, true) or q:find("step", 1, true)
  if not include_refs and not include_deps then
    include_deps = true
  end

  local context = { "Tool context: local graph/code reader" }
  local tool_lines = { "#### Tools", string.format("- `read_code` %s:%d-%d", node.file_path, (node.line_start or 0) + 1, (node.line_end or 0) + 1) }
  context[#context + 1] = "Focused node code:"
  context[#context + 1] = format_code_excerpt(node, 160)

  local function append_related(title, nodes, enabled)
    if not enabled then return end
    context[#context + 1] = title .. " code excerpts:"
    local count = 0
    for _, n in ipairs(nodes) do
      if count >= 4 then break end
      count = count + 1
      tool_lines[#tool_lines + 1] = string.format("- `read_code` %s `%s` %s:%d-%d", title:lower(), n.name or "?", n.file_path or "?", (n.line_start or 0) + 1, (n.line_end or 0) + 1)
      context[#context + 1] = format_code_excerpt(n, 80)
    end
    if count == 0 then context[#context + 1] = "  none indexed" end
  end

  append_related("Dependencies", deps, include_deps)
  append_related("References", refs, include_refs)

  local seen_url = {}
  for url in tostring(question or ""):gmatch("https?://[^%s%)%]}>,]+") do
    url = url:gsub("[%.%,%;:]$", "")
    if not seen_url[url] then
      seen_url[url] = true
      local out, used = tools.read_url(url, { max_chars = 16000 })
      context[#context + 1] = out
      vim.list_extend(tool_lines, used)
    end
  end

  local seen_file = {}
  for spec in tostring(question or ""):gmatch("@?[%w%._%-%/%~]+:%d+%-?%d*") do
    if not spec:match("^https?://") and not seen_file[spec] then
      seen_file[spec] = true
      local out, used = tools.read_file_location(spec, { max_lines = 120 })
      context[#context + 1] = out
      vim.list_extend(tool_lines, used)
    end
  end

  return table.concat(context, "\n\n"), tool_lines
end

function append_buffer_safe_lines(dst, src)
  for _, item in ipairs(src or {}) do
    local text = tostring(item or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then
      dst[#dst + 1] = ""
    else
      for part in (text .. "\n"):gmatch("(.-)\n") do
        dst[#dst + 1] = part
      end
    end
  end
end

function sanitize_buffer_lines(lines)
  local out = {}
  append_buffer_safe_lines(out, lines)
  return out
end

render_chat = function()
  local buf = ensure_buf()
  state.chat_buf = buf
  state.chat_win = state.win
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  lines[#lines + 1] = tab_header("chat")
  lines[#lines + 1] = "Chat"
  local _, issue_count = build_issues_context(1)
  if state.focus_node then
    local _, counts = build_compact_context(state.focus_node)
    lines[#lines + 1] = string.format("**Context:** %s `%s`", ui.node_icon(state.focus_node.type), state.focus_node.name)
    lines[#lines + 1] = string.format("deps:`%d` refs:`%d` blast:`%d` issues:`%d`", counts.deps, counts.refs, counts.blast, issue_count)
  else
    lines[#lines + 1] = string.format("**Context:** project issues available `%d`; no focused symbol", issue_count)
    lines[#lines + 1] = "Ask about current issues, or press `K` on a symbol to add code context."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "_i/a ask · c clear · C compact · @file:line/URL allowed · q close_"
  lines[#lines + 1] = string.rep("─", math.max(10, state.width - 2))
  append_buffer_safe_lines(lines, state.chat_lines)
  if #state.chat_lines > 0 then lines[#lines + 1] = "" end
  lines[#lines + 1] = ">> "

  vim.bo[buf].modifiable = true
  lines = sanitize_buffer_lines(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeTitle", 0, 0, -1)
  highlight_tabs(buf, 0, "chat")
  vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", 1, 0, -1)
  for i, line in ipairs(lines) do
    if line:match("^### You") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPMemoryUser", i - 1, 0, -1)
    elseif line:match("^### MetaLSP") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPMemoryAssistant", i - 1, 0, -1)
    elseif line:match("^#### Tools") or line:match("^%- `") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPTreeMuted", i - 1, 0, -1)
    elseif line:match("^>>") then
      vim.api.nvim_buf_add_highlight(buf, NS, "MetaLSPMemoryUser", i - 1, 0, 2)
    end
  end
  vim.bo[buf].modifiable = false

  if is_valid_win(state.chat_win) then
    local last = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, state.chat_win, { last, #((vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1]) or "") })
    pcall(vim.api.nvim_win_call, state.chat_win, function() vim.cmd("normal! z-") end)
  end
  utils.render_markdown(buf)
  vim.cmd("redraw")
end

local function load_node_memory(node)
  if not node then return end
  state.focus_node = db.get_node(node.id) or node
  state.focus_context = build_compact_context(state.focus_node)
  state.chat_lines = {}
  state.tab = "chat"
  render_chat()
  if is_valid_win(state.chat_win) then
    vim.api.nvim_set_current_win(state.chat_win)
    vim.bo[state.chat_buf].modifiable = true
    vim.api.nvim_win_set_cursor(state.chat_win, { vim.api.nvim_buf_line_count(state.chat_buf), 3 })
    vim.cmd("startinsert!")
  end
end

local function submit_chat()
  local buf = ensure_buf()
  local last = vim.api.nvim_buf_line_count(buf)
  local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  local question = vim.trim(line:gsub("^>>%s*", ""))
  if question == "" then return end

  if state.focus_node and not state.focus_context then
    state.focus_context = build_compact_context(state.focus_node)
  end
  local git_context = build_git_context()
  local issues_context = build_issues_context(80)
  local tool_context, tool_lines = build_graph_code_context(state.focus_node, question)
  local full_context = table.concat({ git_context or "", issues_context or "", state.focus_context or "", tool_context or "" }, "\n\n")

  state.chat_lines[#state.chat_lines + 1] = "### You"
  state.chat_lines[#state.chat_lines + 1] = question
  state.chat_lines[#state.chat_lines + 1] = ""
  vim.list_extend(state.chat_lines, tool_lines)
  state.chat_lines[#state.chat_lines + 1] = ""
  state.chat_lines[#state.chat_lines + 1] = "### MetaLSP"
  local response_start_idx = #state.chat_lines + 1
  state.chat_lines[response_start_idx] = "thinking…"
  db.save_chat_session(utils.project_id(state.project_root), state.chat_lines)
  render_chat()

  local accumulated_answer = ""
  ollama.ask_with_context(full_context, question, function(answer, err)
    vim.schedule(function()
      if err then
        while #state.chat_lines >= response_start_idx do
          table.remove(state.chat_lines)
        end
        state.chat_lines[response_start_idx] = "Error: " .. tostring(err)
        db.save_chat_session(utils.project_id(state.project_root), state.chat_lines)
        render_chat()
        return
      end
      if answer then
        while #state.chat_lines >= response_start_idx do
          table.remove(state.chat_lines)
        end
        local lines = {}
        append_buffer_safe_lines(lines, { answer })
        for _, l in ipairs(lines) do
          state.chat_lines[#state.chat_lines + 1] = l
        end
        db.save_chat_session(utils.project_id(state.project_root), state.chat_lines)
        render_chat()
      end
    end)
  end, function(chunk)
    vim.schedule(function()
      if chunk and chunk ~= "" then
        accumulated_answer = accumulated_answer .. chunk
        while #state.chat_lines >= response_start_idx do
          table.remove(state.chat_lines)
        end
        local lines = {}
        append_buffer_safe_lines(lines, { accumulated_answer })
        for _, l in ipairs(lines) do
          state.chat_lines[#state.chat_lines + 1] = l
        end
        render_chat()
      end
    end)
  end)
end

local function update_popup_lines(popup, node)
  if not popup or not popup.bufnr or not vim.api.nvim_buf_is_valid(popup.bufnr) then return end
  local updated = db.get_node(node.id) or node
  local raw_lines, item_map = build_symbol_lines(updated)
  local updated_lines = {}
  append_buffer_safe_lines(updated_lines, raw_lines)
  popup.metalsp_line_items = item_map or {}
  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, sanitize_buffer_lines(updated_lines))
  vim.bo[popup.bufnr].filetype = "markdown"
  vim.bo[popup.bufnr].modifiable = false
end

local function extract_function_notes(raw_code, node)
  local notes = {}
  if node and node.semantic_summary and node.semantic_summary ~= "" then
    notes[#notes + 1] = "Previous summary: " .. node.semantic_summary
  end
  for _, line in ipairs(vim.split(raw_code or "", "\n")) do
    local note = line:match("^%s*//%s*(.+)$")
      or line:match("^%s*%-%-%s*(.+)$")
      or line:match("^%s*#%s*(.+)$")
      or line:match("^%s*%*%s*(.+)$")
    if note and note ~= "" then
      notes[#notes + 1] = note
      if #notes >= 40 then break end
    end
  end
  return table.concat(notes, "\n")
end

local function replace_cached_node(updated)
  if not updated or not updated.id then return end
  if state.focus_node and state.focus_node.id == updated.id then state.focus_node = updated end
  if state.live_node and state.live_node.id == updated.id then state.live_node = updated end
  if state.pins and state.pins[updated.id] then state.pins[updated.id] = updated end
  for i, n in ipairs(state.focus_history or {}) do
    if n.id == updated.id then state.focus_history[i] = updated end
  end
end

local reload_now_node

local function summarize_node(node, popup)
  if not node or state.summarizing[node.id] then return end
  node = db.get_node(node.id) or node
  local analysis_hash = node.hash

  local raw_code = get_node_raw_code(node)
  if raw_code == "" then
    utils.notify("Cannot read code for: " .. node.name, vim.log.levels.WARN)
    return
  end

  db.clear_semantic(node.id)
  state.summarizing[node.id] = true

  reload_now_node(node)
  update_popup_lines(popup, db.get_node(node.id) or node)

  ollama.analyze_function({
    id = node.id,
    name = node.name,
    type = node.type,
    raw_code = raw_code,
    notes = extract_function_notes(raw_code, node),
    hash = analysis_hash,
  }, function(summary, side_effects, err, thinking)
    state.summarizing[node.id] = nil

    if err or not summary then
      vim.schedule(function()
        reload_now_node(node)
        update_popup_lines(popup, node)
        utils.notify("Summary failed for " .. node.name .. ": " .. tostring(err or "empty response"), vim.log.levels.WARN)
      end)
      return
    end

    local current = db.get_node(node.id)
    if not current or (analysis_hash and current.hash ~= analysis_hash) then
      vim.schedule(function()
        reload_now_node(node)
        update_popup_lines(popup, node)
      end)
      return
    end

    db.update_semantic(node.id, summary, side_effects, thinking)
    local updated = db.get_node(node.id) or current
    replace_cached_node(updated)
    vim.schedule(function()
      reload_now_node(updated)
      update_popup_lines(popup, updated)
    end)
  end)
end

local function index_lsp_refs(node, popup)
  if not node then return end
  utils.notify("Indexing LSP references/dependencies for " .. node.name .. "…")

  local refs_done, deps_done = false, false
  local refs_count, deps_count = 0, 0
  local first_err = nil

  local function finish_if_done()
    if not (refs_done and deps_done) then return end
    vim.schedule(function()
      if first_err then
        utils.notify("LSP graph indexing warning: " .. first_err, vim.log.levels.WARN)
      end
      utils.notify(string.format("Linked %d reference(s), %d dependenc(ies) into MetaLSP graph", refs_count, deps_count))
      M.refresh()
      update_popup_lines(popup, node)
    end)
  end

  lsp_indexer.index_references_for_node(node, function(count, err)
    refs_count = count or 0
    first_err = first_err or err
    refs_done = true
    finish_if_done()
  end)

  lsp_indexer.index_dependencies_for_node(node, function(count, err)
    deps_count = count or 0
    first_err = first_err or err
    deps_done = true
    finish_if_done()
  end)
end

local function show_symbol_popup(node)
  local raw_lines, item_map = build_symbol_lines(node)
  local lines = {}
  append_buffer_safe_lines(lines, raw_lines)

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end

  local event = require("nui.utils.autocmd").event
  local width = math.min(70, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local popup = Popup({
    enter = true,
    position = "50%",
    size = { width = width, height = height },
    relative = "editor",
    border = { style = "rounded", text = { top = " 󰊢 Knowledge Node ", top_align = "center" } },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder", wrap = true, linebreak = true, cursorline = true },
  })

  popup:mount()
  popup.metalsp_line_items = item_map or {}
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, sanitize_buffer_lines(lines))
  vim.bo[popup.bufnr].filetype = "markdown"
  vim.bo[popup.bufnr].modifiable = false

  local close = function() popup:unmount() end
  popup:map("n", "q", close, { noremap = true })
  popup:map("n", "<Esc>", close, { noremap = true })
  popup:map("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(popup.bufnr, lnum - 1, lnum, false)[1] or ""
    local file, l = line:match("`([^`]+):(%d+)`")
    close()
    if file and l then
      open_in_other_pane(file, tonumber(l))
    else
      open_in_other_pane(node.file_path, (node.line_start or 0) + 1)
    end
  end, { noremap = true })
  popup:map("n", "s", function()
    utils.notify("Summary is protected: press capital `S` to generate/update DB summary.", vim.log.levels.INFO)
  end, { noremap = true })
  popup:map("n", "S", function()
    summarize_node_confirm(db.get_node(node.id) or node, popup)
  end, { noremap = true })
  popup:map("n", "L", function()
    index_lsp_refs(db.get_node(node.id) or node, popup)
  end, { noremap = true })
  popup:on(event.BufLeave, close, { once = true })

  -- Do not auto-summarize on open. Summary generation is protected behind `S`
  -- to avoid accidental repeated LLM calls.
end

local function current_item()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_items[lnum]
end

function M.switch_tab(tab)
  if tab == "error" or tab == "graph" then tab = "now" end
  state.tab = tab
  state.relation_view = nil
  if tab == "now" and not state.focus_node then
    state.focus_node = current_source_focus_node()
  end
  if tab == "chat" and state.focus_node then
    state.focus_context = build_compact_context(state.focus_node)
  end
  M.refresh()
  if tab == "chat" then
    vim.schedule(function()
      if is_valid_win(state.win) then
        local buf = ensure_buf()
        local last = vim.api.nvim_buf_line_count(buf)
        vim.bo[buf].modifiable = true
        vim.api.nvim_win_set_cursor(state.win, { last, 3 })
        vim.cmd("startinsert!")
      end
    end)
  end
end

function M.toggle_or_show()
  if state.tab == "explorer" then
    local ok, exp = pcall(require, "metalsp.features.explorer")
    if ok and exp.on_cr then exp.on_cr() end
    return
  end
  if state.tab == "now" then
    local item = current_item()
    if item and item.type == "symbol" and item.node then
      M.open_in_other_pane(item.node.file_path, (item.node.line_start or 0) + 1)
    elseif item and item.type == "diagnostic" and item.node then
      M.open_in_other_pane(item.node.file_path, item.line or ((item.node.line_start or 0) + 1))
    elseif item and item.type == "file" and item.path then
      M.open_in_other_pane(item.path, item.line)
    elseif item and item.type == "related" and item.node then
      if state.focus_node then table.insert(state.focus_history, state.focus_node) end
      state.focus_node = db.get_node(item.node.id) or item.node
      M.refresh()
    elseif item and item.type == "changes" and item.node then
      M.review_diff(false)
    else
      M.inspect_now(true)
    end
    return
  end
  local item = current_item()
  if not item then return end

  if item.type == "related" and item.node then
    if state.focus_node then table.insert(state.focus_history, state.focus_node) end
    state.focus_node = db.get_node(item.node.id) or item.node
    M.refresh()
  elseif item.type == "symbol" and item.node then
    open_in_other_pane(item.node.file_path, (item.node.line_start or 0) + 1)
  elseif item.type == "file" and item.path then
    open_in_other_pane(item.path, item.line)
  elseif item.type == "diagnostic" and item.node then
    open_in_other_pane(item.node.file_path, item.line or ((item.node.line_start or 0) + 1))
  elseif item.type == "changes" and item.node then
    M.review_diff(false)
  end
end

function M.show_relation_view(kind)
  local item = current_item()
  if item and item.type == "symbol" then state.focus_node = item.node end
  if state.tab == "now" and state.live_node then state.focus_node = state.live_node end
  state.tab = "now"
  state.relation_view = kind
  M.refresh()
end

function M.toggle_variables()
  state.show_variables = not state.show_variables
  M.refresh()
end

function M.focus_back()
  local prev = table.remove(state.focus_history)
  if prev then
    state.focus_node = prev
    M.refresh()
  end
end

function M.pin_focus()
  local node = state.focus_node or state.live_node
  if node and node.id then
    state.pins[node.id] = node
    db.add_pin(node.id, utils.project_id(state.project_root))
    M.refresh()
  end
end

function M.unpin_focus()
  local node = state.focus_node or state.live_node
  if node and node.id then
    state.pins[node.id] = nil
    db.remove_pin(node.id, utils.project_id(state.project_root))
    M.refresh()
  end
end

function M.toggle_compact()
  state.compact = not state.compact
  if state.tab == "now" then
    if state.live_node then
      reload_now_node(state.live_node)
    else
      M.refresh()
    end
  else
    M.refresh()
  end
  utils.notify("MetaLSP compact mode: " .. (state.compact and "ON" or "OFF"), vim.log.levels.INFO)
end

function M.show_actions_palette()
  local items = {
    { label = "S: Summarize current symbol into DB", action = M.resummarize_current },
    { label = "L: Index LSP references/callers into graph", action = M.index_lsp_refs_current },
    { label = "C: Toggle Compact Mode (NOW tab)", action = M.toggle_compact },
    { label = "v: Toggle Variables display (NOW tab)", action = M.toggle_variables },
    { label = "p: Pin current symbol", action = M.pin_focus },
    { label = "u: Unpin current symbol", action = M.unpin_focus },
    { label = "d: Review git diff / changes", action = function() M.review_diff(false) end },
    { label = "cl: Login to Cloud Provider (Copilot/OpenAI/Gemini)", action = function()
      vim.ui.select({ "copilot", "openai", "gemini" }, { prompt = "Select Cloud Provider to login:" }, function(provider)
        if not provider then return end
        vim.cmd("MetaLSPLogin " .. provider)
      end)
    end },
    { label = "cp: Select LLM Provider (ollama/copilot/openai/gemini)", action = function()
      vim.ui.select({ "ollama", "copilot", "openai", "gemini" }, { prompt = "Select Active Provider:" }, function(provider)
        if not provider then return end
        vim.cmd("MetaLSPProvider " .. provider)
      end)
    end },
    { label = "i: Index current file", action = function()
      if is_valid_win(state.source_win) then
        vim.api.nvim_win_call(state.source_win, function() vim.cmd("MetaLSPIndex") end)
      else
        vim.cmd("MetaLSPIndex")
      end
      M.refresh()
    end },
    { label = "gf: Open selected symbol in editor", action = M.open_file },
    { label = "1: Switch to NOW tab", action = function() M.switch_tab("now") end },
    { label = "2: Switch to CHAT tab", action = function() M.switch_tab("chat") end },
    { label = "3: Switch to FILES tab", action = function() M.switch_tab("explorer") end },
    { label = "?: Show all shortcuts help", action = M.show_help },
  }

  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = item.label
  end

  vim.ui.select(labels, {
    prompt = "MetaLSP Actions:",
  }, function(choice)
    if not choice then return end
    for _, item in ipairs(items) do
      if item.label == choice then
        item.action()
        break
      end
    end
  end)
end

function M.show_help()
  local lines = {
    "# MetaLSP shortcuts",
    "",
    "## Global",
    "- `<leader>mn` open NOW for cursor summary",
    "- `<leader>mc` open CHAT",
    "- `<leader>mf` open FILES",
    "- `<leader>mi` index current file",
    "- `<leader>mp` index project/current location",
    "- `<leader>me` analyze errors",
    "- `<leader>ms` status",
    "- `<leader>mt` toggle sidebar",
    "",
    "## Tabs",
    "- `1` NOW",
    "- `2` CHAT",
    "- `3` FILES",
    "- `<Tab>` cycle tabs",
    "- `q` close sidebar",
    "- `<Space>` / `?` show this help",
    "",
    "## Common actions",
    "- `<CR>` smart action: inspect/open/focus/toggle",
    "- `a` ask/inspect/add depending on tab",
    "- `S` summarize selected/current symbol into DB (protected)",
    "- `s` shows summary hint only",
    "- `i` index current file or selected file/folder",
    "- `r` refresh; rename in FILES",
    "- `d` review diff; delete in FILES",
    "",
    "## NOW",
    "- Shows current summary, related items, errors, and pins",
    "- `C` toggle Compact Mode (hides verbose flows, Calls/Refs trees, and tips)",
    "- `p` / `u` pin/unpin focus node (persisted across sessions to SQLite)",
    "- `a` inspect cursor symbol without model",
    "- `S` generate/update one DB summary containing intent, flow, side effects, risks/checks",
    "- `s` only shows a hint, to avoid accidental re-summary",
    "- `L` index LSP calls/callers into graph",
    "- `K` load current/focused symbol into CHAT",
    "- Ask CHAT for flow/intent/impact details from stored DB context",
    "- `gf` open selected file/symbol",
    "",
    "## CHAT",
    "- `a` / `i` jump to input",
    "- insert `<CR>` submit question",
    "- `c` clear chat",
    "- Context includes current issues/diagnostics automatically",
    "- Use `@file:line` or URL to add extra context",
    "",
    "## FILES",
    "- `󰅚` not indexed · `󰁯` indexed but no summary · no badge = summarized",
    "- `<CR>` toggle folder/file outline",
    "- `o` open file in editor",
    "- `i` index file/folder",
    "- `a` add file/folder",
    "- `r` rename file/folder",
    "- `d` delete file/folder",
    "",
    "## Popup",
    "- `<CR>` open item/file",
    "- `S` summarize",
    "- `L` index LSP facts",
    "- `q` / `<Esc>` close",
  }

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end
  local event = require("nui.utils.autocmd").event
  local popup = Popup({
    enter = true,
    position = "50%",
    size = { width = math.min(64, vim.o.columns - 4), height = math.min(#lines + 2, vim.o.lines - 6) },
    relative = "editor",
    border = { style = "rounded", text = { top = " MetaLSP shortcuts ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false, filetype = "markdown" },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder", wrap = true, linebreak = true },
  })
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, sanitize_buffer_lines(lines))
  vim.bo[popup.bufnr].modifiable = false
  popup:map("n", "q", function() popup:unmount() end, { noremap = true })
  popup:map("n", "<Esc>", function() popup:unmount() end, { noremap = true })
  popup:on(event.BufLeave, function() popup:unmount() end, { once = true })
end

function M.open_chat()
  if not is_valid_win(state.win) then M.open() end
  M.switch_tab("chat")
end

function M.open_files()
  if not is_valid_win(state.win) then M.open() end
  M.switch_tab("explorer")
end

function M.open_file()
  if state.tab == "now" and state.live_node then
    M.open_in_other_pane(state.live_node.file_path, (state.live_node.line_start or 0) + 1)
    return
  end
  local item = current_item()
  if not item then return end
  local file_path = item.type == "file" and item.path or (item.node and item.node.file_path)
  if not file_path then return end
  local line = item.line or (item.node and ((item.node.line_start or 0) + 1)) or nil
  M.open_in_other_pane(file_path, line)
end

summarize_node_confirm = function(node, popup)
  node = node and (db.get_node(node.id) or node)
  if not node then return end
  if node.semantic_summary and node.semantic_summary ~= "" then
    vim.ui.select({ "Cancel", "Update summary" }, { prompt = "MetaLSP summary already exists for " .. (node.name or "symbol") }, function(choice)
      if choice == "Update summary" then summarize_node(node, popup) end
    end)
  else
    summarize_node(node, popup)
  end
end

function M.resummarize_current()
  if state.tab == "now" then
    local node = state.live_node or state.focus_node
    if node then summarize_node_confirm(node) end
    return
  end
  local item = current_item()
  if not item or item.type ~= "symbol" then
    utils.notify("Place cursor on a symbol in MetaLSPTree to summarize", vim.log.levels.WARN)
    return
  end
  summarize_node_confirm(item.node)
end

function M.index_lsp_refs_current()
  if state.tab == "now" and state.live_node then
    index_lsp_refs(db.get_node(state.live_node.id) or state.live_node)
    return
  end
  local item = current_item()
  if not item or item.type ~= "symbol" then
    utils.notify("Place cursor on a symbol in MetaLSPTree to index LSP references", vim.log.levels.WARN)
    return
  end
  index_lsp_refs(db.get_node(item.node.id) or item.node)
end

function M.load_tree_symbol_memory()
  local item = current_item()
  if state.tab == "now" then
    local node = state.live_node or state.focus_node or current_source_focus_node()
    if item and item.node then node = item.node end
    if node then
      load_node_memory(db.get_node(node.id) or node)
    else
      utils.notify("No indexed symbol to load. Put cursor in a symbol and run :MetaLSPIndex first.", vim.log.levels.WARN)
    end
    return
  end
  if not item or item.type ~= "symbol" then
    utils.notify("Place cursor on a symbol in MetaLSPTree to load memory", vim.log.levels.WARN)
    return
  end
  load_node_memory(db.get_node(item.node.id) or item.node)
end

local function get_source_cursor_node()
  local win = is_valid_win(state.source_win) and state.source_win or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr), state.project_root)
  local line = vim.api.nvim_win_get_cursor(win)[1] - 1
  local best = db.get_node_at(file_path, line)
  return best, bufnr, file_path, line
end

local function build_now_lines_async(node, bufnr, callback)
  local line_items = {}
  if not node then
    callback({ "No indexed symbol at cursor.", "Save/index the file first." }, line_items)
    return
  end

  local deps = db.get_direct_dependencies(node.id)
  local refs = db.get_direct_dependents(node.id)
  local blast = db.get_blast_radius(node.id)
  local diagnostics = {}
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for _, d in ipairs(vim.diagnostic.get(bufnr)) do
      if d.lnum >= (node.line_start or 0) and d.lnum <= (node.line_end or node.line_start or 0) then
        diagnostics[#diagnostics + 1] = d
      end
    end
  end

  local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
  
  local changed = false
  local tests = {}
  local pending = 2

  local function finalize()
    local lines = {
      string.format("# %s %s", ui.node_icon(node.type), node.name),
      string.format("`%s:%d` %s", node.file_path, (node.line_start or 0) + 1, changed and "󰒓 changed" or ""),
      string.format("󰅚 %d  󰁯 %d  󰁰 %d  󰀦 %d  󰄬 %d", #diagnostics, #deps, #refs, #blast, #tests),
      "",
    }

    local summary_str
    if state.summarizing[node.id] then
      summary_str = "󰔟 Summarizing with Ollama…"
    elseif not is_bad_summary(node.semantic_summary) then
      summary_str = node.semantic_summary
    else
      summary_str = "_No DB summary yet. Press `S` to generate._"
    end

    lines[#lines + 1] = "## Summary"
    lines[#lines + 1] = summary_str
    lines[#lines + 1] = ""

    if not state.compact then
      if node.thinking and node.thinking ~= "" then
        lines[#lines + 1] = "Implementation flow:"
        lines[#lines + 1] = node.thinking
        lines[#lines + 1] = ""
      end

      local function add_file_tree_section(title, nodes)
        if #nodes == 0 then return end
        lines[#lines + 1] = "## " .. title

        local by_file = {}
        for _, n in ipairs(nodes) do
          local file = n.file_path or "?"
          by_file[file] = by_file[file] or {}
          by_file[file][#by_file[file] + 1] = n
        end

        local files = vim.tbl_keys(by_file)
        table.sort(files)
        for _, file in ipairs(files) do
          table.sort(by_file[file], function(a, b) return (a.line_start or 0) < (b.line_start or 0) end)
          local fname = vim.fn.fnamemodify(file, ":t")
          local ext = fname:match("^.+(%..+)$") or ""
          ext = ext:sub(2)
          local icon = ui.get_icon and ui.get_icon(fname, ext) or ""

          local file_lnum = #lines + 1
          lines[file_lnum] = string.format("▾ %s %s", icon, file)
          line_items[file_lnum] = { type = "file", path = file }

          for _, n in ipairs(by_file[file]) do
            local lnum = #lines + 1
            lines[lnum] = string.format("  %s %s:%d", ui.node_icon(n.type), n.name or "?", (n.line_start or 0) + 1)
            line_items[lnum] = { type = "symbol", node = n }
          end
        end
        lines[#lines + 1] = ""
      end

      if #diagnostics > 0 then
        lines[#lines + 1] = "## Diags"
        for _, d in ipairs(diagnostics) do
          local lnum = #lines + 1
          lines[lnum] = string.format("- L%d: %s", (d.lnum or 0) + 1, utils.one_line(d.message or ""))
          line_items[lnum] = { type = "diagnostic", node = node, line = (d.lnum or 0) + 1 }
        end
        lines[#lines + 1] = ""
      end

      add_file_tree_section("Calls", deps)
      add_file_tree_section("Refs", refs)

      if #tests > 0 then
        add_file_tree_section("Tests", tests)
      end

      if changed then
        lines[#lines + 1] = "## Changes"
        local lnum = #lines + 1
        lines[lnum] = "  file changed (g review)"
        line_items[lnum] = { type = "changes", node = node }
        lines[#lines + 1] = ""
      end

      lines[#lines + 1] = "### Tips"
      if #diagnostics > 0 then lines[#lines + 1] = "• fix diags first" end
      if changed then lines[#lines + 1] = "• review diff (`g`)" end
      if #refs > 0 then lines[#lines + 1] = "• check callers" end
      if #deps > 0 then lines[#lines + 1] = "• check side-effects" end
      if #tests == 0 then lines[#lines + 1] = "• add tests" end
      if #diagnostics == 0 and #refs == 0 and #deps == 0 then lines[#lines + 1] = "• index LSP (`L`)" end
    end

    callback(lines, line_items)
  end

  local function on_task_done()
    pending = pending - 1
    if pending == 0 then
      vim.schedule(finalize)
    end
  end

  vim.system({ "git", "diff", "--name-only", "--", node.file_path }, { cwd = root, text = true }, function(obj)
    changed = vim.trim(obj.stdout or "") ~= ""
    on_task_done()
  end)

  if node.name and node.name ~= "" then
    vim.system({ "rg", "-n", "--no-heading", node.name, "-g", "*_test.go", "-g", "*.test.ts", "-g", "*.spec.ts", "-g", "*_spec.lua", "-g", "*test*" }, { cwd = root, text = true }, function(obj)
      for _, l in ipairs(vim.split(obj.stdout or "", "\n", { trimempty = true })) do
        local file, lnum, text = l:match("^([^:]+):(%d+):(.*)$")
        if file and lnum then
          tests[#tests + 1] = { file_path = file, line_start = tonumber(lnum) - 1, name = vim.trim(text or file), type = "test" }
          if #tests >= 5 then break end
        end
      end
      on_task_done()
    end)
  else
    on_task_done()
  end
end

reload_now_node = function(node)
  if not node or not (state.tab == "now" and state.live_node and state.live_node.id == node.id) then
    M.refresh()
    return
  end

  if state.live_mode == "docs" then
    local lines = {}
    lines[#lines + 1] = string.format("# %s %s", ui.node_icon(node.type), node.name)
    lines[#lines + 1] = string.format("`%s:%d-%d`", node.file_path, (node.line_start or 0) + 1, (node.line_end or 0) + 1)
    lines[#lines + 1] = ""
    if state.summarizing[node.id] then
      lines[#lines + 1] = "󰔟 Summarizing with Ollama…"
    elseif not is_bad_summary(node.semantic_summary) then
      lines[#lines + 1] = "## MetaLSP summary"
      lines[#lines + 1] = node.semantic_summary
      if node.thinking and node.thinking ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Flow"
        lines[#lines + 1] = node.thinking
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "󰁯 Press `s` to re-summary"
    else
      lines[#lines + 1] = "## Hover docs"
      lines[#lines + 1] = "_No DB summary yet and no LSP documentation available._"
      lines[#lines + 1] = ""
      lines[#lines + 1] = "󰁯 Press `s` to summary with MetaLSP"
    end
    state.live_lines = lines
    M.refresh()
  else
    local target_buf = nil
    local root = state.project_root or utils.get_project_root() or vim.fn.getcwd()
    local abs_path = root .. "/" .. node.file_path
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
        target_buf = b
        break
      end
    end
    build_now_lines_async(node, target_buf, function(lines, items)
      state.live_lines = lines
      state.live_line_items = items
      M.refresh()
    end)
  end
end

function M.inspect_now(force)
  local node, bufnr = get_source_cursor_node()
  if not node then
    -- Keep the previous useful context instead of replacing it with an empty
    -- "not indexed" message while the cursor is on whitespace/imports/etc.
    return
  end

  local counts = vim.diagnostic.count(bufnr)
  local diag_key = table.concat({
    counts[vim.diagnostic.severity.ERROR] or 0,
    counts[vim.diagnostic.severity.WARN] or 0,
    counts[vim.diagnostic.severity.INFO] or 0,
    counts[vim.diagnostic.severity.HINT] or 0,
  }, ",")
  local key = table.concat({ node.id or "", node.hash or "", diag_key }, ":")
  if not force and state.live_last_key == key then return end
  state.live_last_key = key

  state.tab = "now"
  state.live_node = node
  state.focus_node = node or state.focus_node
  state.live_mode = "inspect"
  state.live_loading = true
  if not state.live_lines then
    state.live_lines = { "Loading..." }
    state.live_line_items = {}
  end
  M.refresh()

  build_now_lines_async(node, bufnr, function(lines, items)
    -- If the user has moved quickly and started a new inspect, 
    -- we might want to ignore this, but it's okay to overwrite for now.
    -- Or just check if state.live_last_key is still the same.
    if state.live_last_key == key then
      state.live_loading = false
      state.live_lines = lines
      state.live_line_items = items
      M.refresh()
    end
  end)
end

local function schedule_live_inspect(delay_ms)
  if not (is_valid_win(state.win) and state.tab == "now") then return end
  if state.live_loading then return end
  delay_ms = delay_ms or 900
  if state.live_refresh_timer then
    state.live_refresh_timer:stop()
    state.live_refresh_timer:close()
  end
  state.live_refresh_timer = vim.uv.new_timer()
  state.live_refresh_timer:start(delay_ms, 0, function()
    if state.live_refresh_timer then
      state.live_refresh_timer:stop()
      state.live_refresh_timer:close()
      state.live_refresh_timer = nil
    end
    vim.schedule(function()
      if is_valid_win(state.win) and state.tab == "now" and not state.live_loading then
        M.inspect_now(false)
      end
    end)
  end)
end

function M.analyze_live_cursor(mode)
  mode = mode or config.get().live.default_mode or "flow"
  local node = get_source_cursor_node()
  if not node then
    utils.notify("No indexed MetaLSP node at source cursor. Save/index the file first.", vim.log.levels.WARN)
    return
  end

  state.tab = "now"
  state.live_node = node
  state.live_mode = mode
  state.live_loading = true
  state.live_lines = nil
  state.live_line_items = {}
  M.refresh()

  local tool_cfg = config.get().tools or {}
  local compact_context = build_compact_context(node)
  local context_parts = { compact_context }
  local tool_lines = { "## Tool calls" }
  local out, used = tools.read_code(node, { max_lines = tool_cfg.max_code_lines })
  context_parts[#context_parts + 1] = out
  vim.list_extend(tool_lines, used)

  if mode == "flow" or mode == "impact" or mode == "risk" then
    out, used = tools.read_dependencies(node, { max_nodes = tool_cfg.max_related_nodes, max_lines = 80 })
    context_parts[#context_parts + 1] = out
    vim.list_extend(tool_lines, used)
  end
  if mode == "impact" or mode == "risk" then
    out, used = tools.read_references(node, { max_nodes = tool_cfg.max_related_nodes, max_lines = 80 })
    context_parts[#context_parts + 1] = out
    vim.list_extend(tool_lines, used)
  end

  local instruction = prompts.render("live_" .. mode, { name = node.name, type = node.type })
  local question = instruction ~= "" and instruction or ("Analyze " .. mode)
  ollama.ask_with_context(table.concat(context_parts, "\n\n"), question, function(answer, err)
    vim.schedule(function()
      state.live_loading = false
      state.live_line_items = {}
      if err or not answer then
        state.live_lines = { "Analysis failed: " .. tostring(err or "empty response") }
      else
        state.live_lines = {
          string.format("# %s %s", ui.node_icon(node.type), node.name),
          string.format("`%s:%d`", node.file_path, (node.line_start or 0) + 1),
          "",
        }
        vim.list_extend(state.live_lines, tool_lines)
        state.live_lines[#state.live_lines + 1] = ""
        state.live_lines[#state.live_lines + 1] = "## Result"
        state.live_lines[#state.live_lines + 1] = answer
      end
      M.refresh()
    end)
  end)
end

function M.open_cursor_summary()
  local source_win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local source_line = vim.api.nvim_win_get_cursor(source_win)[1] - 1
  M.show_hover_docs(bufnr, {}, source_line, source_win)
end

function M.show_hover_docs(bufnr, lsp_lines, source_line, source_win)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if source_win and vim.api.nvim_win_is_valid(source_win) then state.source_win = source_win end
  if not is_valid_win(state.win) then M.open() end

  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr), state.project_root)
  local line = source_line
  if line == nil then
    local win = source_win and vim.api.nvim_win_is_valid(source_win) and source_win or state.source_win
    line = (win and vim.api.nvim_win_is_valid(win)) and (vim.api.nvim_win_get_cursor(win)[1] - 1) or 0
  end
  local node = db.get_node_at(file_path, line)

  state.tab = "now"
  state.live_mode = "docs"
  state.live_loading = false
  state.live_line_items = {}
  state.live_node = node or state.live_node
  state.focus_node = node or state.focus_node

  local lines = {}
  if node then
    lines[#lines + 1] = string.format("# %s %s", ui.node_icon(node.type), node.name)
    lines[#lines + 1] = string.format("`%s:%d-%d`", node.file_path, (node.line_start or 0) + 1, (node.line_end or 0) + 1)
    lines[#lines + 1] = ""
  end

  if node and node.semantic_summary and node.semantic_summary ~= "" then
    lines[#lines + 1] = "## MetaLSP summary"
    lines[#lines + 1] = node.semantic_summary
    if node.thinking and node.thinking ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "## Flow"
      lines[#lines + 1] = node.thinking
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "󰁯 Press `s` to re-summary"
  else
    lines[#lines + 1] = "## Hover docs"
    append_buffer_safe_lines(lines, lsp_lines and #lsp_lines > 0 and lsp_lines or { "_No DB summary yet and no LSP documentation available._" })
    lines[#lines + 1] = ""
    lines[#lines + 1] = "󰁯 Press `s` to summary with MetaLSP"
  end

  state.live_lines = lines
  M.refresh()
end

function M.show_error_fix(items, answer)
  if not is_valid_win(state.win) then M.open() end
  state.tab = "now"
  state.live_mode = "errors"
  state.live_loading = false
  state.error_items = {}

  local lines = { "# Error analysis", "" }
  local by_folder = {}
  for _, it in ipairs(items or {}) do
    local folder = vim.fn.fnamemodify(it.file_path or "?", ":h")
    if folder == "." then folder = "root" end
    by_folder[folder] = by_folder[folder] or {}
    by_folder[folder][it.file_path or "?"] = by_folder[folder][it.file_path or "?"] or {}
    table.insert(by_folder[folder][it.file_path or "?"], it)
  end

  local folders = vim.tbl_keys(by_folder)
  table.sort(folders)
  lines[#lines + 1] = "## Errors"
  for _, folder in ipairs(folders) do
    lines[#lines + 1] = "- " .. folder
    local files = vim.tbl_keys(by_folder[folder])
    table.sort(files)
    for _, file in ipairs(files) do
      lines[#lines + 1] = "  - " .. file
      table.sort(by_folder[folder][file], function(a, b) return (a.line or 0) < (b.line or 0) end)
      for _, it in ipairs(by_folder[folder][file]) do
        local fn = it.node and it.node.name or "<file>"
        local lnum = #lines + 1
        lines[lnum] = string.format("    - `%s:%d` **%s** — %s", file, it.line or 1, fn, utils.one_line(it.message or ""))
        state.error_items[lnum] = it
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## LLM analysis"
  append_buffer_safe_lines(lines, { answer or "_No analysis yet._" })
  state.error_lines = lines
  M.refresh()
end

function M.review_diff(staged)
  state.tab = "now"
  state.live_mode = staged and "review_staged" or "review_diff"
  state.live_loading = true
  state.live_lines = nil
  state.live_line_items = {}
  M.refresh()
  local diff, tool_lines = tools.read_git_diff(staged)
  local instruction = prompts.render("review_diff", {})
  ollama.ask_with_context(diff, instruction, function(answer, err)
    vim.schedule(function()
      state.live_loading = false
      state.live_lines = { "# Git Diff Review", "", "## Tool calls" }
      vim.list_extend(state.live_lines, tool_lines or {})
      state.live_lines[#state.live_lines + 1] = ""
      state.live_lines[#state.live_lines + 1] = "## Result"
      state.live_lines[#state.live_lines + 1] = answer or ("Error: " .. tostring(err))
      M.refresh()
    end)
  end)
end

function M.load_current_symbol_memory()
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr))
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local node = db.get_node_at(file_path, line)
  if not node then
    utils.notify("No indexed MetaLSP node at cursor. Save/index the file first.", vim.log.levels.WARN)
    return
  end
  if not is_valid_win(state.win) then M.open() end
  load_node_memory(node)
end

local function memory_start_input()
  state.tab = "chat"
  render_chat()
  local buf = ensure_buf()
  local last = vim.api.nvim_buf_line_count(buf)
  vim.bo[buf].modifiable = true
  if is_valid_win(state.win) then vim.api.nvim_set_current_win(state.win) end
  vim.api.nvim_win_set_cursor(0, { last, 3 })
  vim.cmd("startinsert!")
end

local function setup_chat_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("i", "<CR>", function()
    vim.cmd("stopinsert")
    submit_chat()
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP chat submit" }))
end

local function setup_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", close_win, vim.tbl_extend("force", opts, { desc = "MetaLSP close" }))
  vim.api.nvim_buf_set_keymap(buf, "n", "1", "", { noremap = true, silent = true, callback = function() M.switch_tab("now") end })
  vim.api.nvim_buf_set_keymap(buf, "n", "2", "", { noremap = true, silent = true, callback = function() M.switch_tab("chat") end })
  vim.api.nvim_buf_set_keymap(buf, "n", "3", "", { noremap = true, silent = true, callback = function() M.switch_tab("explorer") end })
  vim.keymap.set("n", "<Tab>", function()
    local next_tab = "now"
    if state.tab == "now" then next_tab = "chat"
    elseif state.tab == "chat" then next_tab = "explorer"
    else next_tab = "now" end
    M.switch_tab(next_tab)
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP switch tab" }))
  vim.keymap.set("n", "a", function()
    if state.tab == "explorer" then
      local ok, exp = pcall(require, "metalsp.features.explorer")
      if ok and exp.on_add then exp.on_add() end
    elseif state.tab == "chat" then memory_start_input() else M.inspect_now(true) end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP inspect/ask/add" }))
  vim.keymap.set("n", "f", function()
    if state.tab == "now" then
      utils.notify("NOW is compact: press `S` once to store summary/flow/intent in DB, then ask in CHAT.", vim.log.levels.INFO)
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP: compact NOW hint" }))
  vim.keymap.set("n", "i", function()
    if state.tab == "explorer" then
      local ok, exp = pcall(require, "metalsp.features.explorer")
      if ok and exp.on_index then exp.on_index() end
    elseif state.tab == "chat" then
      memory_start_input()
    else
      if is_valid_win(state.source_win) then
        vim.api.nvim_win_call(state.source_win, function() vim.cmd("MetaLSPIndex") end)
      else
        vim.cmd("MetaLSPIndex")
      end
      M.refresh()
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP index/input" }))
  vim.keymap.set("n", "e", function()
    if state.tab == "now" then
      utils.notify("NOW is compact: side effects are stored by `S` and available in CHAT.", vim.log.levels.INFO)
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP: compact NOW hint" }))
  
  -- route 'r' to explorer rename; elsewhere refresh the current view
  vim.keymap.set("n", "r", function()
    if state.tab == "explorer" then
      local ok, exp = pcall(require, "metalsp.features.explorer")
      if ok and exp.on_rename then exp.on_rename() end
    else
      M.refresh()
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP rename/refresh" }))
  
  -- route 'd' to explorer delete if explorer tab, otherwise review diff
  vim.keymap.set("n", "d", function() 
    if state.tab == "explorer" then
      local ok, exp = pcall(require, "metalsp.features.explorer")
      if ok and exp.on_delete then exp.on_delete() end
    else
      M.review_diff(false) 
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP delete/review diff" }))
  
  vim.keymap.set("n", "b", function()
    if state.tab == "now" then
      utils.notify("NOW is compact: ask CHAT about impact after `L`/`S` if needed.", vim.log.levels.INFO)
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP: compact NOW hint" }))
  vim.keymap.set("n", "g", function()
    M.review_diff(false)
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP review git changes" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "MetaLSP refresh" }))
  vim.keymap.set("n", "c", function()
    if state.tab == "chat" then
      state.chat_lines = {}
      db.save_chat_session(utils.project_id(state.project_root), state.chat_lines)
      render_chat()
    else
      M.show_relation_view("calls")
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP calls/clear" }))
  vim.keymap.set("n", "v", M.toggle_variables, vim.tbl_extend("force", opts, { desc = "MetaLSP toggle variables" }))
  vim.keymap.set("n", "p", M.pin_focus, vim.tbl_extend("force", opts, { desc = "MetaLSP pin focus" }))
  vim.keymap.set("n", "u", M.unpin_focus, vim.tbl_extend("force", opts, { desc = "MetaLSP unpin focus" }))
  vim.keymap.set("n", "?", M.show_help, vim.tbl_extend("force", opts, { desc = "MetaLSP help" }))
  vim.keymap.set("n", "<Space>", M.show_actions_palette, vim.tbl_extend("force", opts, { desc = "MetaLSP actions menu" }))
  vim.keymap.set("n", "s", function()
    utils.notify("Summary is protected: press capital `S` to generate/update DB summary.", vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP summary hint" }))
  vim.keymap.set("n", "S", M.resummarize_current, vim.tbl_extend("force", opts, { desc = "MetaLSP summarize current symbol into DB" }))
  vim.keymap.set("n", "L", M.index_lsp_refs_current, vim.tbl_extend("force", opts, { desc = "MetaLSP graph index LSP references" }))
  vim.keymap.set("n", "K", M.load_tree_symbol_memory, vim.tbl_extend("force", opts, { desc = "MetaLSP graph load symbol chat" }))
  vim.keymap.set("n", "<CR>", M.toggle_or_show, vim.tbl_extend("force", opts, { desc = "MetaLSP focus/open" }))
  vim.keymap.set("n", "<BS>", M.focus_back, vim.tbl_extend("force", opts, { desc = "MetaLSP previous focus" }))
  vim.keymap.set("n", "o", function()
    if state.tab == "explorer" then
      local ok, exp = pcall(require, "metalsp.features.explorer")
      if ok and exp.on_o then exp.on_o() end
    else
      M.toggle_or_show()
    end
  end, vim.tbl_extend("force", opts, { desc = "MetaLSP focus/open" }))
  vim.keymap.set("n", "gf", M.open_file, vim.tbl_extend("force", opts, { desc = "MetaLSP open file" }))
  vim.keymap.set("n", "C", M.toggle_compact, vim.tbl_extend("force", opts, { desc = "MetaLSP toggle compact mode" }))
end

function M.open()
  local source_buf = vim.api.nvim_get_current_buf()
  state.source_win = vim.api.nvim_get_current_win()
  state.scope_folder = utils.current_location_folder(source_buf)
  state.project_root = utils.get_project_root(source_buf) or vim.fn.getcwd()
  if state.tab == "error" or state.tab == "graph" then state.tab = "now" end
  state.tab = state.tab or "now"

  -- Load persisted session data
  local proj_id = utils.project_id(state.project_root)
  state.pins = {}
  local db_pins = db.get_pinned_nodes(proj_id)
  for _, pin_node in ipairs(db_pins) do
    state.pins[pin_node.id] = pin_node
  end
  state.chat_lines = db.load_chat_session(proj_id) or {}

  open_win()
  setup_keymaps(state.buf)
  setup_chat_keymaps(state.chat_buf)
  if state.tab == "now" then M.inspect_now(true) else M.refresh() end
end

function M.toggle()
  if is_valid_win(state.win) then
    close_win()
  else
    M.open()
  end
end

function M.setup(keymap)
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("metalsp-knowledge-theme", { clear = true }),
    callback = setup_highlights,
  })
  vim.api.nvim_create_autocmd({ "CursorHold", "DiagnosticChanged" }, {
    group = vim.api.nvim_create_augroup("metalsp-knowledge-now", { clear = true }),
    callback = function()
      if config.get().live.auto_update ~= false then
        schedule_live_inspect(900)
      end
    end,
  })

  vim.api.nvim_create_user_command("MetaLSPTree", M.toggle, { desc = "MetaLSP: Toggle Knowledge Tree" })
  vim.api.nvim_create_user_command("MetaLSPRefreshTree", M.refresh, { desc = "MetaLSP: Refresh Knowledge Tree" })
  vim.api.nvim_create_user_command("MetaLSPMemory", M.load_current_symbol_memory, { desc = "MetaLSP: Load cursor symbol into Knowledge Chat" })
  vim.api.nvim_create_user_command("MetaLSPLive", function(opts)
    if not is_valid_win(state.win) then M.open() end
    M.analyze_live_cursor(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", complete = function() return { "flow", "intent", "side_effects", "risk", "impact" } end, desc = "MetaLSP: Now Knowledge mode" })
  vim.api.nvim_create_user_command("MetaLSPReviewDiff", function() if not is_valid_win(state.win) then M.open() end; M.review_diff(false) end, { desc = "MetaLSP: Review git diff" })
  vim.api.nvim_create_user_command("MetaLSPReviewStaged", function() if not is_valid_win(state.win) then M.open() end; M.review_diff(true) end, { desc = "MetaLSP: Review staged git diff" })
  if keymap then
    vim.keymap.set("n", keymap, M.toggle, { desc = "MetaLSP: Knowledge Tree", noremap = true, silent = true })
  end
  vim.keymap.set("n", "<leader>mk", M.load_current_symbol_memory,
    { desc = "MetaLSP: Load cursor symbol chat", noremap = true, silent = true })
end

return M
