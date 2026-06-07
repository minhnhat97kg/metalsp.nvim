--- MetaLSP.nvim — Treesitter AST Extractor: TypeScript / JavaScript

local M = {}

-- ── Query strings ────────────────────────────────────────────────────────────

--- Named functions, arrow function assignments, and class methods.
local FUNC_QUERY = [[
  (function_declaration
    name: (identifier) @func_name) @func_def

  (lexical_declaration
    (variable_declarator
      name: (identifier) @func_name
      value: [
        (arrow_function)
        (function_expression)
      ])) @func_def

  (export_statement
    declaration: (function_declaration
      name: (identifier) @func_name)) @func_def

  (method_definition
    name: (property_identifier) @func_name) @func_def
]]

--- Class declarations.
local CLASS_QUERY = [[
  (class_declaration
    name: (type_identifier) @class_name) @class_def

  (export_statement
    declaration: (class_declaration
      name: (type_identifier) @class_name)) @class_def
]]

--- Variables, fields, interfaces, and type aliases for outline-like display.
local OUTLINE_QUERY = [[
  (lexical_declaration
    (variable_declarator
      name: (identifier) @var_name) @var_def)

  (public_field_definition
    name: (property_identifier) @field_name) @field_def

  (interface_declaration
    name: (type_identifier) @interface_name) @interface_def

  (type_alias_declaration
    name: (type_identifier) @type_name) @type_def
]]

--- Call expressions.
local CALL_QUERY = [[
  (call_expression
    function: [
      (identifier) @call_name
      (member_expression
        property: (property_identifier) @call_name)
    ])
]]

--- Import declarations.
local IMPORT_QUERY = [[
  (import_statement
    source: (string
      (string_fragment) @import_path))
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

local function extract_calls(body_node, bufnr, lang)
  local edges = {}
  local seen = {}

  local ok, query = pcall(vim.treesitter.query.parse, lang, CALL_QUERY)
  if not ok then return edges end

  for _, captured_node in query:iter_captures(body_node, bufnr, 0, -1) do
    local name = node_text(captured_node, bufnr)
    if name and #name > 1 and not seen[name] then
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

--- Extract all symbols from a TypeScript/JavaScript buffer.
--- @param bufnr integer
--- @param lang string "typescript"|"javascript"
--- @return Symbol[]
function M.extract(bufnr, lang)
  lang = lang or "typescript"
  local symbols = {}

  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then
    -- Fallback: try javascript parser for .js files
    parser = vim.treesitter.get_parser(bufnr, "javascript")
    if not parser then return symbols end
    lang = "javascript"
  end

  local tree = parser:parse()[1]
  if not tree then return symbols end
  local root = tree:root()

  -- ── Functions & Methods ──────────────────────────────────────────────────
  local ok, func_query = pcall(vim.treesitter.query.parse, lang, FUNC_QUERY)
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
        local edges = extract_calls(def_node, bufnr, lang)

        -- Detect if it's a class method by checking parent
        local sym_type = "function"
        local parent = def_node:parent()
        if parent and (parent:type() == "class_body" or parent:type() == "method_definition") then
          sym_type = "method"
        end

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
  end

  -- ── Classes ───────────────────────────────────────────────────────────────
  local class_ok, class_query = pcall(vim.treesitter.query.parse, lang, CLASS_QUERY)
  if class_ok then
    for _, match, _ in class_query:iter_matches(root, bufnr, 0, -1) do
      local def_node, name_node
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = class_query.captures[id]
        if cap == "class_def" then def_node = node end
        if cap == "class_name" then name_node = node end
      end

      if def_node and name_node then
        local name = node_text(name_node, bufnr)
        local sl, el = node_range(def_node)
        local raw = extract_code(bufnr, sl, el)
        symbols[#symbols + 1] = {
          name       = name,
          type       = "class",
          line_start = sl,
          line_end   = el,
          raw_code   = raw,
          edges      = {},
        }
      end
    end
  end

  -- ── Variables / Fields / Interfaces / Type aliases ───────────────────────
  local outline_ok, outline_query = pcall(vim.treesitter.query.parse, lang, OUTLINE_QUERY)
  if outline_ok then
    for _, match, _ in outline_query:iter_matches(root, bufnr, 0, -1) do
      local def_node, name_node, sym_type
      for id, node in pairs(match) do
        node = type(node) == "table" and node[1] or node
        local cap = outline_query.captures[id]
        if cap == "var_def" or cap == "field_def" or cap == "interface_def" or cap == "type_def" then def_node = node end
        if cap == "var_name" then name_node, sym_type = node, "variable" end
        if cap == "field_name" then name_node, sym_type = node, "field" end
        if cap == "interface_name" then name_node, sym_type = node, "interface" end
        if cap == "type_name" then name_node, sym_type = node, "type_alias" end
      end

      if def_node and name_node then
        local name = node_text(name_node, bufnr)
        local sl, el = node_range(def_node)
        local raw = extract_code(bufnr, sl, el)
        -- Function-valued variables are already indexed as functions above.
        if not (sym_type == "variable" and (raw:find("=>", 1, true) or raw:find("function", 1, true))) then
          symbols[#symbols + 1] = {
            name       = name,
            id_key     = sym_type .. ":" .. name .. ":" .. tostring(sl + 1),
            type       = sym_type,
            line_start = sl,
            line_end   = el,
            raw_code   = raw,
            edges      = {},
          }
        end
      end
    end
  end

  -- ── Imports ───────────────────────────────────────────────────────────────
  local import_ok, import_query = pcall(vim.treesitter.query.parse, lang, IMPORT_QUERY)
  local imports = {}
  if import_ok then
    for _, captured_node in import_query:iter_captures(root, bufnr, 0, -1) do
      imports[#imports + 1] = node_text(captured_node, bufnr)
    end
  end

  -- Attach imports to each function/method symbol
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
