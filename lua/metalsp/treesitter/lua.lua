--- MetaLSP.nvim — Treesitter AST Extractor: Lua

local M = {}

-- ── Query strings ────────────────────────────────────────────────────────────

--- Named function declarations and method assignments (M.foo = function...).
local FUNC_QUERY = [[
  (function_declaration
    name: (identifier) @func_name) @func_def

  (assignment_statement
    (variable_list
      name: [
        (dot_index_expression
          field: (identifier) @func_name)
        (method_index_expression
          method: (identifier) @func_name)
      ])
    (expression_list value: (function_definition) @func_def))

  (local_function
    name: (identifier) @func_name) @func_def

  (local_variable_declaration
    (variable_declarator
      name: (identifier) @func_name
      value: (function_definition) @func_def))
]]

--- Call expressions.
local CALL_QUERY = [[
  (function_call
    name: [
      (identifier) @call_name
      (method_index_expression
        method: (identifier) @call_name)
      (dot_index_expression
        field: (identifier) @call_name)
    ])
]]

--- require() calls for imports.
local REQUIRE_QUERY = [[
  (function_call
    name: (identifier) @req (#eq? @req "require")
    args: (args (string content: (string_content) @import_path)))
]]

--- Variables / module fields for outline-like display.
local VAR_QUERY = [[
  (local_variable_declaration
    (variable_declarator
      name: (identifier) @var_name) @var_def)

  (assignment_statement
    (variable_list
      name: [
        (identifier) @var_name
        (dot_index_expression field: (identifier) @field_name)
      ]) @var_def)
]]

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function node_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr) or ""
end

local function node_range(node)
  local sr, _, er, _ = node:range()
  return sr, er
end

local function extract_code(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  return table.concat(lines, "\n")
end

local function extract_calls(body_node, bufnr)
  local edges = {}
  local seen = {}
  local ok, query = pcall(vim.treesitter.query.parse, "lua", CALL_QUERY)
  if not ok then return edges end

  for _, captured_node in query:iter_captures(body_node, bufnr, 0, -1) do
    local name = node_text(captured_node, bufnr)
    if name and #name > 1 and name ~= "require" and not seen[name] then
      seen[name] = true
      edges[#edges + 1] = {
        target_name = name,
        target_id = nil,
        relation_type = "CALLS",
      }
    end
  end
  return edges
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Extract all symbols from a Lua buffer.
--- @param bufnr integer
--- @return Symbol[]
function M.extract(bufnr)
  local symbols = {}

  local parser = vim.treesitter.get_parser(bufnr, "lua")
  if not parser then return symbols end

  local tree = parser:parse()[1]
  if not tree then return symbols end
  local root = tree:root()

  -- ── Functions ─────────────────────────────────────────────────────────────
  local ok, func_query = pcall(vim.treesitter.query.parse, "lua", FUNC_QUERY)
  if ok then
    for _, match, _ in func_query:iter_matches(root, bufnr, 0, -1) do
      local def_node, name_node
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = func_query.captures[id]
        if cap == "func_def" then def_node = node end
        if cap == "func_name" then name_node = node end
      end

      if def_node and name_node then
        local name = node_text(name_node, bufnr)
        local sl, el = node_range(def_node)
        local raw = extract_code(bufnr, sl, el)
        local edges = extract_calls(def_node, bufnr)

        symbols[#symbols + 1] = {
          name       = name,
          type       = "function",
          line_start = sl,
          line_end   = el,
          raw_code   = raw,
          edges      = edges,
        }
      end
    end
  end

  -- ── Variables / Module fields ─────────────────────────────────────────────
  local var_ok, var_query = pcall(vim.treesitter.query.parse, "lua", VAR_QUERY)
  if var_ok then
    for _, match, _ in var_query:iter_matches(root, bufnr, 0, -1) do
      local def_node, name_node, sym_type
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = var_query.captures[id]
        if cap == "var_def" then def_node = node end
        if cap == "var_name" then name_node, sym_type = node, "variable" end
        if cap == "field_name" then name_node, sym_type = node, "field" end
      end

      if def_node and name_node then
        local name = node_text(name_node, bufnr)
        local sl, el = node_range(def_node)
        local raw = extract_code(bufnr, sl, el)
        -- Function-valued variables are already indexed as functions above.
        if not raw:find("function", 1, true) then
          symbols[#symbols + 1] = {
            name       = name,
            id_key     = (sym_type or "variable") .. ":" .. name .. ":" .. tostring(sl + 1),
            type       = sym_type or "variable",
            line_start = sl,
            line_end   = el,
            raw_code   = raw,
            edges      = {},
          }
        end
      end
    end
  end

  -- ── Require imports ────────────────────────────────────────────────────────
  local req_ok, req_query = pcall(vim.treesitter.query.parse, "lua", REQUIRE_QUERY)
  local imports = {}
  if req_ok then
    for id, captured_node in req_query:iter_captures(root, bufnr, 0, -1) do
      if req_query.captures[id] == "import_path" then
        imports[#imports + 1] = node_text(captured_node, bufnr)
      end
    end
  end

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
