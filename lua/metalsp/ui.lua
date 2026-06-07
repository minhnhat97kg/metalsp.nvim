--- MetaLSP.nvim — UI Components
--- Built on nui.nvim (Popup, Menu, Input) + nvim-web-devicons for file-type icons.

local M = {}

local utils = require("metalsp.utils")

--- MetaLSP virtual-text namespace
local NS = vim.api.nvim_create_namespace("metalsp")

local function buffer_safe_lines(src)
  local out = {}
  for _, item in ipairs(src or {}) do
    local text = tostring(item or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then
      out[#out + 1] = ""
    else
      for part in (text .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = part
      end
    end
  end
  return out
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Devicons Helper
-- ═══════════════════════════════════════════════════════════════════════════

--- Get file-type icon and highlight group.
--- @param filename string
--- @param filetype string|nil
--- @return string icon, string hl_group
function M.get_icon(filename, filetype)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return "󰈙", "Normal" end

  local icon, hl
  if filetype then
    icon, hl = devicons.get_icon_by_filetype(filetype, { default = true })
  else
    icon, hl = devicons.get_icon(filename, nil, { default = true })
  end
  return icon or "󰈙", hl or "Normal"
end

--- Get icon for a MetaLSP node type.
--- @param node_type string "function"|"method"|"class"|"struct"|"interface"
--- @return string icon
function M.node_icon(node_type)
  local icons = {
    ["function"]  = "󰊕",
    ["method"]    = "󰆦",
    ["class"]     = "󰠱",
    ["struct"]    = "󱠎",
    ["interface"] = "󰜰",
    ["variable"]  = "󰀫",
    ["constant"]  = "󰏿",
    ["field"]     = "󰜢",
    ["type_alias"] = "󰜁",
    ["architecture_rule"] = "󰒓",
    ["default"]   = "󰉿",
  }
  return icons[node_type] or icons["default"]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Semantic Hover Popup (Feature 1)
-- ═══════════════════════════════════════════════════════════════════════════

local function build_semantic_lines(node, dependents_count)
  -- Decode side_effects JSON
  local side_effects = {}
  if node.side_effects and node.side_effects ~= "" then
    local ok, decoded = pcall(vim.json.decode, node.side_effects)
    if ok and type(decoded) == "table" then
      side_effects = decoded
    end
  end

  local lines = {
    "## MetaLSP",
    string.format("**%s %s**  ", M.node_icon(node.type), node.name),
    string.format("`%s:%d-%d`", node.file_path, (node.line_start or 0) + 1, (node.line_end or 0) + 1),
    "",
    "### Summary",
    (node.semantic_summary and node.semantic_summary ~= "") and node.semantic_summary or "_No local summary yet. Use Live Knowledge (`a`) or Tree summary (`s`) to analyze explicitly._",
  }

  if node.thinking and node.thinking ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Implementation Flow"
    lines[#lines + 1] = node.thinking
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "### Side Effects"
  if #side_effects == 0 then
    lines[#lines + 1] = "- none/unknown"
  else
    for _, se in ipairs(side_effects) do
      lines[#lines + 1] = string.format("- **%s** → %s", se.type or "?", se.target or "")
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "### Impact"
  lines[#lines + 1] = string.format("- `%d` direct dependent(s)", dependents_count)


  -- Compute popup dimensions
  local max_width = 0
  for _, l in ipairs(lines) do
    if #l > max_width then max_width = #l end
  end
  local width = math.min(math.max(max_width + 2, 52), vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)

  return lines, width, height
end

local function hover_content_lines(state)
  local lines = {}
  vim.list_extend(lines, state.lsp_lines or { "_Fetching LSP documentation…_" })
  if #lines == 0 then lines[#lines + 1] = "_No LSP documentation available._" end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""
  vim.list_extend(lines, state.agent_lines or {})
  return buffer_safe_lines(lines)
end

local function hover_size(lines)
  local max_width = 0
  for _, l in ipairs(lines) do max_width = math.max(max_width, vim.fn.strdisplaywidth(l)) end
  return {
    width = math.min(math.max(max_width + 2, 50), math.max(50, math.floor(vim.o.columns * 0.7))),
    height = math.min(math.max(#lines, 6), math.max(6, math.floor(vim.o.lines * 0.45))),
  }
end

--- Render hover like Neovim's native markdown hover: one markdown document,
--- LSP docs first, MetaLSP graph notes below.
local function render_popup_tab(popup)
  if not popup or not popup.bufnr or not vim.api.nvim_buf_is_valid(popup.bufnr) then return end
  local state = popup.metalsp_state
  local lines = hover_content_lines(state)

  popup:update_layout({
    size = hover_size(lines),
    border = { text = { top = string.format(" %s hover ", state.file_icon or "󰈙"), top_align = "center" } },
  })

  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].filetype = "markdown"
  vim.bo[popup.bufnr].modifiable = false

  utils.render_markdown(popup.bufnr)
end

--- Show a nui.Popup with semantic information and LSP docs.
---
--- @param node table DB node { name, type, file_path, semantic_summary, side_effects, ... }
--- @param dependents_count integer how many nodes depend on this
--- @param lsp_lines table|nil initial LSP markdown lines
function M.semantic_popup(node, dependents_count, lsp_lines)
  local Popup = require("nui.popup")
  local event = require("nui.utils.autocmd").event

  local agent_lines, width, height = build_semantic_lines(node, dependents_count)
  local file_icon, icon_hl = M.get_icon(node.file_path)

  local popup = Popup({
    enter = true,
    position = { row = 1, col = 0 },
    size = { width = width, height = height },
    relative = "cursor",
    border = {
      style = "rounded",
      text = { top = "", top_align = "center" },
    },
    buf_options = { modifiable = true, readonly = false, filetype = "markdown" },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
      conceallevel = 2,
      concealcursor = "n",
    },
  })

  popup.metalsp_state = {
    current_tab = 1,
    agent_lines = agent_lines,
    lsp_lines = lsp_lines or { "  󰔚 Fetching LSP docs..." },
    file_icon = file_icon,
    icon_hl = icon_hl,
    node = node,
  }

  popup:mount()
  render_popup_tab(popup)

  -- Keymaps
  local close = function() popup:unmount() end
  popup:map("n", "q", close, { noremap = true })
  popup:map("n", "<Esc>", close, { noremap = true })
  
  popup:map("n", "<Tab>", function()
    -- Keep native-hover-like single document; Tab just cycles window focus out.
    vim.cmd("wincmd p")
  end, { noremap = true })

  popup:map("n", "<CR>", function()
    popup:unmount()
    local n = popup.metalsp_state.node
    if n and n.file_path then
      local abs = vim.fn.getcwd() .. "/" .. n.file_path
      vim.cmd("edit " .. vim.fn.fnameescape(abs))
      vim.api.nvim_win_set_cursor(0, { (n.line_start or 0) + 1, 0 })
    end
  end, { noremap = true })

  popup:on(event.BufLeave, close, { once = true })

  return popup
end

--- Update an existing nui.Popup dynamically with new semantic info.
---
--- @param popup table nui.Popup instance
--- @param node table updated DB node
--- @param dependents_count integer
function M.update_semantic_popup(popup, node, dependents_count)
  if not popup or not popup.bufnr or not vim.api.nvim_buf_is_valid(popup.bufnr) then return end

  local lines, width, height = build_semantic_lines(node, dependents_count)
  local file_icon, icon_hl = M.get_icon(node.file_path)

  popup.metalsp_state.agent_lines = lines
  popup.metalsp_state.file_icon = file_icon
  popup.metalsp_state.icon_hl = icon_hl
  popup.metalsp_state.node = node

  popup:update_layout({
    size = { width = width, height = height }
  })

  render_popup_tab(popup)
end

--- Update an existing nui.Popup dynamically with LSP docs.
---
--- @param popup table nui.Popup instance
--- @param lsp_lines table
function M.update_lsp_docs(popup, lsp_lines)
  if not popup or not popup.bufnr or not vim.api.nvim_buf_is_valid(popup.bufnr) then return end
  popup.metalsp_state.lsp_lines = lsp_lines
  render_popup_tab(popup)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Blast Radius Menu (Feature 2)
-- ═══════════════════════════════════════════════════════════════════════════

--- Show an interactive nui.Menu of all blast radius nodes.
--- Also populates the Quickfix list.
---
--- @param origin_name string the node being changed
--- @param nodes table[] list of { name, type, file_path, line_start, depth }
function M.blast_radius_menu(origin_name, nodes)
  local Menu = require("nui.menu")
  local event = require("nui.utils.autocmd").event

  if #nodes == 0 then
    vim.notify("[MetaLSP] No dependents found for: " .. origin_name, vim.log.levels.INFO)
    return
  end

  -- Populate Quickfix list
  local qf_items = {}
  for _, node in ipairs(nodes) do
    local file_icon, _ = M.get_icon(node.file_path)
    qf_items[#qf_items + 1] = {
      filename = node.file_path,
      lnum     = (node.line_start or 0) + 1,
      col      = 1,
      text     = utils.one_line(string.format("[depth:%d] %s %s", node.depth or 1, file_icon, node.name)),
    }
  end
  vim.fn.setqflist(qf_items, "r")
  vim.fn.setqflist({}, "a", { title = utils.one_line("MetaLSP Blast Radius: " .. origin_name) })

  -- Build menu items
  local menu_items = {}
  for _, node in ipairs(nodes) do
    local file_icon, _ = M.get_icon(node.file_path)
    local depth_str = string.rep("  ", (node.depth or 1) - 1)
    local label = string.format("%s%s %s  %s:%d",
      depth_str, file_icon, node.name,
      node.file_path, (node.line_start or 0) + 1)
    menu_items[#menu_items + 1] = Menu.item(label, { node = node })
  end

  local max_width = 0
  for _, item in ipairs(menu_items) do
    if #item.text > max_width then max_width = #item.text end
  end
  local width = math.min(math.max(max_width + 4, 60), vim.o.columns - 4)
  local height = math.min(#menu_items + 2, math.floor(vim.o.lines * 0.5))

  local menu = Menu({
    position = "50%",
    size = { width = width, height = height },
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = string.format(" 󰀦 Blast Radius: %s (%d affected) ", origin_name, #nodes),
        top_align = "center",
        bottom = " <CR> open  q quit  copen for full list ",
        bottom_align = "center",
      },
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
  }, {
    lines = menu_items,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close      = { "q", "<Esc>" },
      submit     = { "<CR>" },
    },
    on_submit = function(item)
      if item.node then
        local abs = vim.fn.getcwd() .. "/" .. item.node.file_path
        vim.cmd("edit " .. vim.fn.fnameescape(abs))
        vim.api.nvim_win_set_cursor(0, { (item.node.line_start or 0) + 1, 0 })
      end
    end,
  })

  menu:mount()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Error Translation Popup (Feature 3)
-- ═══════════════════════════════════════════════════════════════════════════

--- Show a nui.Popup with LLM-translated error explanation.
---
--- @param translation string the natural-language explanation
--- @param error_msg string the original error (shown smaller)
function M.error_popup(translation, error_msg)
  local Popup = require("nui.popup")
  local event = require("nui.utils.autocmd").event

  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)
  local file_icon, _ = M.get_icon(file_path)

  local lines = {
    "  󰅚 Original Error:",
    "",
  }
  -- Truncate error to 2 lines
  local err_lines = vim.split(error_msg or "", "\n")
  for i = 1, math.min(2, #err_lines) do
    lines[#lines + 1] = "  " .. (err_lines[i] or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.rep("─", 50)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  󰚩 Root Cause Analysis"
  lines[#lines + 1] = ""

  -- Word-wrap translation
  local words = vim.split(translation or "Unable to analyze.", " ")
  local line = "  "
  for _, w in ipairs(words) do
    if #line + #w + 1 > 52 then
      lines[#lines + 1] = line
      line = "  " .. w .. " "
    else
      line = line .. w .. " "
    end
  end
  if #line > 2 then lines[#lines + 1] = line end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Press q / <Esc> to close"

  local width = math.min(56, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)

  local popup = Popup({
    position = { row = 1, col = 0 },
    size = { width = width, height = height },
    relative = "cursor",
    border = {
      style = "rounded",
      text = {
        top = string.format(" %s MetaLSP — Error Analysis ", file_icon),
        top_align = "center",
      },
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:DiagnosticError",
      wrap = false,
    },
  })

  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, buffer_safe_lines(lines))
  vim.bo[popup.bufnr].modifiable = false

  vim.api.nvim_buf_add_highlight(popup.bufnr, -1, "DiagnosticError", 0, 0, -1)

  popup:map("n", "q", function() popup:unmount() end, { noremap = true })
  popup:map("n", "<Esc>", function() popup:unmount() end, { noremap = true })
  popup:on(event.BufLeave, function() popup:unmount() end, { once = true })

  utils.render_markdown(popup.bufnr)

  return popup
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Input Dialog (Generic)
-- ═══════════════════════════════════════════════════════════════════════════

--- Show a nui.Input prompt and call callback with the result.
---
--- @param prompt string
--- @param default string|nil default value
--- @param callback function(value: string|nil)
function M.input(prompt, default, callback)
  local Input = require("nui.input")
  local event = require("nui.utils.autocmd").event

  local input = Input({
    position = "50%",
    size = { width = 50 },
    relative = "editor",
    border = {
      style = "rounded",
      text = { top = " " .. prompt .. " ", top_align = "center" },
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
  }, {
    prompt    = "> ",
    default_value = default or "",
    on_submit = function(value) callback(value) end,
    on_close  = function() callback(nil) end,
  })

  input:mount()
  input:on(event.BufLeave, function() input:unmount() end, { once = true })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Virtual Text
-- ═══════════════════════════════════════════════════════════════════════════

--- Set virtual text on a specific buffer line.
--- @param bufnr integer
--- @param line integer 0-indexed
--- @param text string
--- @param hl_group string|nil
function M.set_virtual_text(bufnr, line, text, hl_group)
  -- MetaLSP no longer writes virtual text. Keep this function as a no-op for
  -- backward compatibility; all assistant output should be rendered in the
  -- right sidebar/popup UI instead.
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

--- Clear all MetaLSP virtual text in a buffer.
--- @param bufnr integer
function M.clear_virtual_text(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Quickfix Helpers
-- ═══════════════════════════════════════════════════════════════════════════

--- Set quickfix list and open it.
--- @param entries table[] vim quickfix format: { filename, lnum, col, text }
--- @param title string
function M.set_quickfix(entries, title)
  local safe_entries = {}
  for _, entry in ipairs(entries or {}) do
    local e = vim.tbl_extend("force", {}, entry)
    e.text = utils.one_line(e.text)
    safe_entries[#safe_entries + 1] = e
  end
  vim.fn.setqflist(safe_entries, "r")
  vim.fn.setqflist({}, "a", { title = utils.one_line(title) })
  vim.cmd("copen")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Statusline Component
-- ═══════════════════════════════════════════════════════════════════════════

--- Return a string suitable for embedding in statusline.
--- @return string
function M.statusline()
  local ollama = require("metalsp.ollama")
  return ollama.status_string()
end

return M
