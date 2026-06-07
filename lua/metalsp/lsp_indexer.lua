--- MetaLSP.nvim — LSP-backed graph indexing
--- Uses LSP references to add graph edges into the MetaLSP SQLite DB.

local M = {}

local db = require("metalsp.db")
local utils = require("metalsp.utils")

local function node_lookup_name(node)
  local name = node.name or ""
  -- Go method display names are like "(Repo).Create"; the source identifier is "Create".
  return name:match("%.([%w_]+)$") or name
end

local function ensure_loaded_buf(node)
  local root = utils.get_project_root() or vim.fn.getcwd()
  local abs = root .. "/" .. node.file_path

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
      return b
    end
  end

  local bufnr = vim.fn.bufadd(abs)
  vim.fn.bufload(bufnr)
  local ft = vim.filetype.match({ filename = abs })
  if ft and vim.bo[bufnr].filetype == "" then vim.bo[bufnr].filetype = ft end
  pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr })
  return bufnr
end

local function find_symbol_position(bufnr, node)
  local name = node_lookup_name(node)
  local start_line = node.line_start or 0
  local end_line = node.line_end or start_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)

  for i, line in ipairs(lines) do
    local col = line:find(name, 1, true)
    if col then
      return start_line + i - 1, col - 1
    end
  end

  return start_line, 0
end

local function location_items(result)
  if not result then return {} end
  if result.uri or result.targetUri then return { result } end
  return result
end

local function make_position_params(bufnr, line, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = line, character = col },
  }
end

local function request_definition_at(bufnr, line, col, cb)
  local params = make_position_params(bufnr, line, col)
  vim.lsp.buf_request_all(bufnr, "textDocument/definition", params, cb)
end

local function locations_from_responses(responses)
  local out = {}
  for _, resp in pairs(responses or {}) do
    local result = resp.result
    if result then
      for _, loc in ipairs(location_items(result)) do
        out[#out + 1] = loc
      end
    end
  end
  return out
end

--- Index LSP references for a DB node into graph edges.
--- Adds edge: referencing containing node -> target node, relation_type="REFERENCES".
--- @param node table DB node
--- @param callback function|nil fun(count: integer, err: string|nil)
function M.index_references_for_node(node, callback)
  callback = callback or function() end
  if not node or not node.id then
    callback(0, "missing node")
    return
  end

  local bufnr = ensure_loaded_buf(node)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    callback(0, "could not load buffer")
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback(0, "no LSP client attached for " .. node.file_path .. " (open the file once, or ensure its LSP starts for hidden buffers)")
    return
  end

  local line, col = find_symbol_position(bufnr, node)
  local params = make_position_params(bufnr, line, col)
  params.context = { includeDeclaration = false }

  vim.lsp.buf_request_all(bufnr, "textDocument/references", params, function(responses)
    local added = 0
    local seen = {}

    for _, resp in pairs(responses or {}) do
      if resp.result then
        for _, loc in ipairs(location_items(resp.result)) do
          local uri = loc.uri or (loc.targetUri)
          local range = loc.range or loc.targetSelectionRange or loc.targetRange
          if uri and range then
            local abs = vim.uri_to_fname(uri)
            local rel = utils.relative_path(abs)
            local ref_line = range.start.line
            local ref_node = db.get_node_at(rel, ref_line)
            if ref_node and ref_node.id ~= node.id then
              local key = ref_node.id .. "->" .. node.id
              if not seen[key] then
                seen[key] = true
                db.add_edge(ref_node.id, node.id, "REFERENCES", "lsp", 1.0)
                added = added + 1
              end
            end
          end
        end
      end
    end

    callback(added, nil)
  end)
end

--- Index LSP definitions for calls made by a DB node into graph edges.
--- Adds edge: source node -> definition target node, relation_type="CALLS".
--- This uses Treesitter only to find candidate call names, then asks LSP for the
--- real definition and links that definition back to an indexed DB node.
--- @param node table DB node
--- @param callback function|nil fun(count: integer, err: string|nil)
function M.index_dependencies_for_node(node, callback)
  callback = callback or function() end
  if not node or not node.id then
    callback(0, "missing node")
    return
  end

  local bufnr = ensure_loaded_buf(node)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback(0, "no LSP client attached for " .. node.file_path .. " (open the file once, or ensure its LSP starts for hidden buffers)")
    return
  end

  local ok_ts, ts = pcall(require, "metalsp.treesitter")
  if not ok_ts then
    callback(0, "treesitter dispatcher unavailable")
    return
  end

  local symbols = ts.extract(bufnr)
  local current
  for _, sym in ipairs(symbols) do
    if sym.name == node.name and sym.line_start == node.line_start then
      current = sym
      break
    end
  end
  if not current or not current.edges or #current.edges == 0 then
    callback(0, nil)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, node.line_start, node.line_end + 1, false)
  local pending, added = 0, 0
  local seen = {}

  local function done_one()
    pending = pending - 1
    if pending == 0 then callback(added, nil) end
  end

  for _, edge in ipairs(current.edges) do
    if edge.relation_type == "CALLS" and edge.target_name then
      local found_line, found_col
      for i, line in ipairs(lines) do
        local col = line:find(edge.target_name, 1, true)
        if col then
          found_line = node.line_start + i - 1
          found_col = col - 1
          break
        end
      end

      if found_line then
        pending = pending + 1
        request_definition_at(bufnr, found_line, found_col, function(responses)
          for _, loc in ipairs(locations_from_responses(responses)) do
            local uri = loc.uri or loc.targetUri
            local range = loc.range or loc.targetSelectionRange or loc.targetRange
            if uri and range then
              local rel = utils.relative_path(vim.uri_to_fname(uri))
              local target = db.get_node_at(rel, range.start.line)
              if target and target.id ~= node.id then
                local key = node.id .. "->" .. target.id
                if not seen[key] then
                  seen[key] = true
                  db.add_edge(node.id, target.id, "CALLS", "lsp", 1.0)
                  added = added + 1
                end
              end
            end
          end
          done_one()
        end)
      end
    end
  end

  if pending == 0 then callback(0, nil) end
end

return M
