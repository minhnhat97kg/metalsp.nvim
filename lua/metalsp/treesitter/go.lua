--- MetaLSP.nvim — Treesitter AST Extractor: Go

local M = {}

--- @alias SymbolType "function"|"method"|"class"|"interface"|"struct"|"variable"|"constant"
--- @alias RelationType "CALLS"|"IMPORTS"|"MUTATES"|"DEPENDS_ON"

--- @class Edge
--- @field target_id string  -- node id of the called symbol (may be unresolved)
--- @field target_name string
--- @field relation_type RelationType

--- @class Symbol
--- @field name string
--- @field type SymbolType
--- @field line_start integer  (0-indexed)
--- @field line_end integer    (0-indexed)
--- @field raw_code string
--- @field edges Edge[]

-- ── Query strings ────────────────────────────────────────────────────────────

--- Captures top-level function declarations and method declarations.
local FUNC_QUERY = [[
  (function_declaration
    name: (identifier) @func_name) @func_def

  (method_declaration
    receiver: (parameter_list
      (parameter_declaration type: (_) @recv_type))
    name: (field_identifier) @method_name) @method_def
]]

--- Captures call expressions within a node's body.
local CALL_QUERY = [[
  (call_expression
    function: [
      (identifier) @call_name
      (selector_expression
        field: (field_identifier) @call_name)
    ])
]]

--- Captures variables and constants for outline-like display.
local VAR_QUERY = [[
  (var_declaration
    (var_spec name: (identifier) @var_name) @var_def)

  (const_declaration
    (const_spec name: (identifier) @const_name) @const_def)

  (short_var_declaration
    left: (expression_list (identifier) @var_name)) @var_def
]]

--- Captures import paths.
local IMPORT_QUERY = [[
  (import_spec path: (interpreted_string_literal) @import_path)
]]

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Get the text of a TSNode.
--- @param node TSNode
--- @param bufnr integer
--- @return string
local function node_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr) or ""
end

--- Get 0-indexed start/end lines of a TSNode.
--- @param node TSNode
--- @return integer start_line, integer end_line
local function node_range(node)
  local sr, _, er, _ = node:range()
  return sr, er
end

--- Get a child node by field name (handling Neovim 0.12 API changes).
--- @param node TSNode
--- @param field_name string
--- @return TSNode|nil
local function child_by_field(node, field_name)
  if not node then return nil end
  if node.child_by_field_name then
    return node:child_by_field_name(field_name)
  elseif node.field then
    local res = node:field(field_name)
    return type(res) == "table" and res[1] or res
  end
  return nil
end

--- Extract raw code lines for a node range.
--- @param bufnr integer
--- @param start_line integer 0-indexed
--- @param end_line integer 0-indexed inclusive
--- @return string
local function extract_code(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  return table.concat(lines, "\n")
end

--- Parse call expressions within a subtree node.
--- @param body_node TSNode
--- @param bufnr integer
--- @return Edge[]
local function extract_calls(body_node, bufnr)
  local edges = {}
  local seen = {}

  local ok, query = pcall(vim.treesitter.query.parse, "go", CALL_QUERY)
  if not ok then return edges end

  for _, captured_node in query:iter_captures(body_node, bufnr, 0, -1) do
    local name = node_text(captured_node, bufnr)
    -- Skip built-ins and single-char names
    if name and #name > 1 and not seen[name] then
      seen[name] = true
      edges[#edges + 1] = {
        target_name = name,
        target_id = nil, -- will be resolved later
        relation_type = "CALLS",
      }
    end
  end

  return edges
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Extract all symbols from a Go buffer.
--- @param bufnr integer
--- @return Symbol[]
function M.extract(bufnr)
  local symbols = {}

  local parser = vim.treesitter.get_parser(bufnr, "go")
  if not parser then return symbols end

  local tree = parser:parse()[1]
  if not tree then return symbols end

  local root = tree:root()

  -- ── Functions & Methods ────────────────────────────────────────────────────
  local ok, func_query = pcall(vim.treesitter.query.parse, "go", FUNC_QUERY)
  if not ok then return symbols end

  for _, match, _ in func_query:iter_matches(root, bufnr, 0, -1) do
    local def_node, name_node, recv_node
    for id, node in pairs(match) do
      node = type(node) == "table" and node[1] or node
      local cap = func_query.captures[id]
      if cap == "func_def" or cap == "method_def" then def_node = node end
      if cap == "func_name" or cap == "method_name" then name_node = node end
      if cap == "recv_type" then recv_node = node end
    end

    if def_node and name_node then
      local name = node_text(name_node, bufnr)
      local sl, el = node_range(def_node)
      local raw = extract_code(bufnr, sl, el)

      -- For methods, prefix with receiver type: "(*Repo).Create"
      if recv_node then
        local recv = node_text(recv_node, bufnr):gsub("[%*%(%)]", "")
        name = "(" .. recv .. ")." .. name
      end

      local sym_type = recv_node and "method" or "function"
      local body = child_by_field(def_node, "body") or def_node
      local edges = extract_calls(body, bufnr)

      symbols[#symbols + 1] = {
        name       = name,
        type       = sym_type,
        line_start = sl,
        line_end   = el,
        raw_code   = raw,
        edges      = edges,
      }
    end
  end

  -- ── Struct / Interface types ───────────────────────────────────────────────
  local type_query_str = [[
    (type_declaration (type_spec name: (type_identifier) @type_name type: [
      (struct_type)
      (interface_type)
    ] @type_body))
  ]]
  local type_ok, type_query = pcall(vim.treesitter.query.parse, "go", type_query_str)
  if type_ok then
    for _, match, _ in type_query:iter_matches(root, bufnr, 0, -1) do
      local name_n, body_n
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = type_query.captures[id]
        if cap == "type_name" then name_n = node end
        if cap == "type_body" then body_n = node end
      end
      if name_n and body_n then
        local name = node_text(name_n, bufnr)
        local sl, el = node_range(body_n:parent() or body_n)
        local raw = extract_code(bufnr, sl, el)
        local ttype = body_n:type() == "interface_type" and "interface" or "struct"
        symbols[#symbols + 1] = {
          name       = name,
          type       = ttype,
          line_start = sl,
          line_end   = el,
          raw_code   = raw,
          edges      = {},
        }
      end
    end
  end

  -- ── Variables / Constants ─────────────────────────────────────────────────
  local var_ok, var_query = pcall(vim.treesitter.query.parse, "go", VAR_QUERY)
  if var_ok then
    for _, match, _ in var_query:iter_matches(root, bufnr, 0, -1) do
      local def_node, name_node, sym_type
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = var_query.captures[id]
        if cap == "var_def" or cap == "const_def" then def_node = node end
        if cap == "var_name" or cap == "const_name" then name_node = node end
        if cap == "const_name" or cap == "const_def" then sym_type = "constant" end
      end
      if def_node and name_node then
        local name = node_text(name_node, bufnr)
        local sl, el = node_range(def_node)
        symbols[#symbols + 1] = {
          name       = name,
          id_key     = (sym_type or "variable") .. ":" .. name .. ":" .. tostring(sl + 1),
          type       = sym_type or "variable",
          line_start = sl,
          line_end   = el,
          raw_code   = extract_code(bufnr, sl, el),
          edges      = {},
        }
      end
    end
  end

  -- ── Imports ────────────────────────────────────────────────────────────────
  local import_ok, import_query = pcall(vim.treesitter.query.parse, "go", IMPORT_QUERY)
  local imports = {}
  if import_ok then
    for _, captured_node in import_query:iter_captures(root, bufnr, 0, -1) do
      local path = node_text(captured_node, bufnr):gsub('"', '')
      imports[#imports + 1] = path
    end
  end

  -- Attach imports as IMPORTS edges to each function symbol
  for _, sym in ipairs(symbols) do
    for _, imp in ipairs(imports) do
      sym.edges[#sym.edges + 1] = {
        target_name = imp,
        target_id = nil,
        relation_type = "IMPORTS",
      }
    end
  end

  return symbols
end

return M
