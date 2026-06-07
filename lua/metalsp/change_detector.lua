--- MetaLSP.nvim — Change Detector
--- Compares SHA256 hashes of symbol code against stored values in the DB.
--- This is the "90% resource saving" gate — unchanged symbols are never sent to Ollama.

local M = {}

local utils = require("metalsp.utils")
local db    = require("metalsp.db")
local ts    = require("metalsp.treesitter")

--- @class ChangeReport
--- @field changed Symbol[]   -- symbols with new/modified code
--- @field unchanged Symbol[] -- symbols whose code is identical
--- @field deleted string[]   -- node IDs that no longer exist in the buffer

--- Analyze a buffer and compute what has changed since the last index.
---
--- @param bufnr integer
--- @param file_path string relative project path
--- @return ChangeReport
function M.detect(bufnr, file_path)
  local report = { changed = {}, unchanged = {}, deleted = {} }

  -- Extract current symbols via Treesitter
  local symbols = ts.extract(bufnr)

  -- Build set of current symbol IDs
  local current_ids = {}
  local root = utils.get_project_root(bufnr)
  for _, sym in ipairs(symbols) do
    local id = utils.make_node_id(file_path, sym.id_key or sym.name, root)
    current_ids[id] = true
  end

  -- Find deleted nodes: IDs in DB that are no longer in the buffer
  local db_nodes = db.get_file_nodes(file_path)
  for _, node in ipairs(db_nodes) do
    if not current_ids[node.id] then
      report.deleted[#report.deleted + 1] = node.id
    end
  end

  -- Classify each current symbol as changed or unchanged
  for _, sym in ipairs(symbols) do
    local id = utils.make_node_id(file_path, sym.id_key or sym.name, root)
    local new_hash = utils.hash(sym.raw_code)
    sym.id = id
    sym.hash = new_hash
    sym.project_root = root
    sym.project_id = utils.project_id(root)

    local existing = db.get_node(id)
    if not existing or existing.hash ~= new_hash or not existing.semantic_summary or existing.semantic_summary == "" then
      report.changed[#report.changed + 1] = sym
    else
      report.unchanged[#report.unchanged + 1] = sym
    end
  end

  return report
end

--- Process a change report:
--- 1. Delete removed nodes from DB
--- 2. Upsert changed nodes (preserving existing semantic data)
--- 3. Replace edges for changed nodes
--- 4. Return the list of changed symbols that need LLM analysis
---
--- @param report ChangeReport
--- @param file_path string
--- @return Symbol[] symbols queued for Ollama
function M.apply(report, file_path)
  -- Delete removed symbols only. Do not delete the whole file here: unchanged
  -- symbols would lose their semantic summaries and all edges via cascade.
  for _, deleted_id in ipairs(report.deleted) do
    db.delete_node(deleted_id)
  end

  -- Upsert changed nodes immediately (with structural data, pending LLM)
  for _, sym in ipairs(report.changed) do
    db.upsert_node_preserve_semantic({
      id           = sym.id,
      name         = sym.name,
      type         = sym.type,
      file_path    = file_path,
      project_id   = sym.project_id,
      project_root = sym.project_root,
      line_start   = sym.line_start,
      line_end     = sym.line_end,
      hash         = sym.hash,
    })

    -- Replace edges for this symbol
    local edges = {}
    for _, edge in ipairs(sym.edges or {}) do
      -- For now, store edges with unresolved target_name
      -- target_id will be resolved lazily when both nodes exist
      local target_id = edge.target_id
      if not target_id and edge.target_name then
        -- Try to resolve: look up by name in DB
        local node = db.get_node_by_name(edge.target_name)
        if node then
          target_id = node.id
        end
      end

      if target_id then
        edges[#edges + 1] = {
          target_id = target_id,
          relation_type = edge.relation_type,
        }
      end
    end

    -- Always replace edges, even with an empty list, so removed calls/imports
    -- do not leave stale blast-radius relationships behind.
    db.replace_edges(sym.id, edges)
  end

  -- Upsert unchanged nodes (update line numbers in case of formatting changes)
  for _, sym in ipairs(report.unchanged) do
    db.upsert_node_preserve_semantic({
      id           = sym.id,
      name         = sym.name,
      type         = sym.type,
      file_path    = file_path,
      project_id   = sym.project_id,
      project_root = sym.project_root,
      line_start   = sym.line_start,
      line_end     = sym.line_end,
      hash         = sym.hash,
    })
  end

  return report.changed
end

return M
