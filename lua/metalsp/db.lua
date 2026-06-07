--- MetaLSP.nvim — SQLite Database Layer
--- Knowledge Graph storage using sqlite.lua (kkharji/sqlite.lua)

local M = {}

local config = require("metalsp.config")
local utils = require("metalsp.utils")

--- @type table|nil sqlite.db instance
local db = nil

--- sqlite.lua returns `true` (not nil) for SELECT with no rows.
--- This helper normalises the result to always be a table.
--- @param rows any
--- @return table
local function safe_rows(rows)
  if type(rows) == "table" then return rows end
  return {}
end

--- Schema creation SQL
local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_root TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    file_path TEXT NOT NULL,
    line_start INTEGER NOT NULL,
    line_end INTEGER NOT NULL,
    semantic_summary TEXT,
    side_effects TEXT,
    thinking TEXT,
    hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS edges (
    source_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    relation_type TEXT NOT NULL,
    source TEXT DEFAULT 'treesitter',
    confidence REAL DEFAULT 1.0,
    PRIMARY KEY (source_id, target_id, relation_type),
    FOREIGN KEY (source_id) REFERENCES nodes(id) ON DELETE CASCADE,
    FOREIGN KEY (target_id) REFERENCES nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS analyses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    hash TEXT NOT NULL,
    model TEXT,
    prompt_version TEXT,
    semantic_summary TEXT,
    side_effects TEXT,
    thinking TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tool_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    input TEXT,
    output TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_edges_target_relation ON edges(target_id, relation_type);
CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_id);
CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_nodes_file ON nodes(file_path);
CREATE INDEX IF NOT EXISTS idx_analyses_node_hash ON analyses(node_id, hash);
CREATE INDEX IF NOT EXISTS idx_tool_runs_project_time ON tool_runs(project_id, created_at);

CREATE TABLE IF NOT EXISTS pins (
    node_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    PRIMARY KEY (node_id, project_id),
    FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chat_sessions (
    project_id TEXT PRIMARY KEY,
    chat_lines_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
]]

--- Initialize the database connection and create schema.
--- @return boolean success
function M.init()
  if db then return true end

  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    utils.notify("sqlite.lua not found. Please install kkharji/sqlite.lua", vim.log.levels.ERROR)
    return false
  end

  local cfg = config.get()
  db = sqlite:open(cfg.db_path)
  if not db then
    utils.notify("Failed to open database at: " .. cfg.db_path, vim.log.levels.ERROR)
    return false
  end

  -- Enable WAL mode for better concurrent read/write performance
  db:eval("PRAGMA journal_mode=WAL")
  db:eval("PRAGMA foreign_keys=ON")

  -- Create schema
  for statement in SCHEMA_SQL:gmatch("[^;]+") do
    local trimmed = statement:match("^%s*(.-)%s*$")
    if trimmed and #trimmed > 0 then
      db:eval(trimmed)
    end
  end

  -- Lightweight migrations for existing DBs.
  local function ensure_column(table_name, column_name, ddl)
    local info = safe_rows(db:eval("PRAGMA table_info(" .. table_name .. ")"))
    for _, col in ipairs(info) do
      if col.name == column_name then return end
    end
    pcall(function() db:eval("ALTER TABLE " .. table_name .. " ADD COLUMN " .. ddl) end)
  end

  ensure_column("nodes", "project_id", "project_id TEXT")
  ensure_column("nodes", "project_root", "project_root TEXT")
  ensure_column("nodes", "thinking", "thinking TEXT")
  ensure_column("edges", "source", "source TEXT DEFAULT 'treesitter'")
  ensure_column("edges", "confidence", "confidence REAL DEFAULT 1.0")

  -- Indexes that depend on migrated columns must be created after migrations.
  db:eval("CREATE INDEX IF NOT EXISTS idx_nodes_project_file ON nodes(project_id, file_path)")

  return true
end

--- Close the database connection.
function M.close()
  if db then
    db:close()
    db = nil
  end
end

--- Get raw db handle (for advanced queries).
--- @return table|nil
function M.handle()
  return db
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Node Operations
-- ═══════════════════════════════════════════════════════════════════════════

--- Upsert a node into the knowledge graph.
--- @param node table { id, name, type, file_path, line_start, line_end, semantic_summary?, side_effects?, thinking?, hash }
function M.upsert_node(node)
  if not db then return end
  local root = utils.get_project_root() or vim.fn.getcwd()
  node.project_id = node.project_id or utils.project_id(root)
  node.project_root = node.project_root or vim.fs.normalize(root)
  -- Do not use INSERT OR REPLACE here: SQLite implements REPLACE as
  -- DELETE + INSERT, which triggers ON DELETE CASCADE and removes graph edges
  -- that point at this node during indexing. Use a real upsert instead so the
  -- row identity is preserved and existing incoming/outgoing edges survive.
  db:eval([[
    INSERT INTO nodes (id, project_id, project_root, name, type, file_path, line_start, line_end, semantic_summary, side_effects, thinking, hash)
    VALUES (:id, :project_id, :project_root, :name, :type, :file_path, :line_start, :line_end, :semantic_summary, :side_effects, :thinking, :hash)
    ON CONFLICT(id) DO UPDATE SET
      project_id = excluded.project_id,
      project_root = excluded.project_root,
      name = excluded.name,
      type = excluded.type,
      file_path = excluded.file_path,
      line_start = excluded.line_start,
      line_end = excluded.line_end,
      semantic_summary = excluded.semantic_summary,
      side_effects = excluded.side_effects,
      thinking = excluded.thinking,
      hash = excluded.hash
  ]], {
    id = node.id,
    project_id = node.project_id,
    project_root = node.project_root,
    name = node.name,
    type = node.type,
    file_path = node.file_path,
    line_start = node.line_start,
    line_end = node.line_end,
    semantic_summary = node.semantic_summary,
    side_effects = node.side_effects,
    thinking = node.thinking,
    hash = node.hash,
  })
end

--- Upsert a node but preserve existing semantic_summary, side_effects, and thinking.
--- Used when only Treesitter data changed (before LLM re-analyzes).
--- @param node table { id, name, type, file_path, line_start, line_end, hash }
function M.upsert_node_preserve_semantic(node)
  if not db then return end

  -- Check if node exists and has semantic data
  local existing = M.get_node(node.id)
  if existing and existing.semantic_summary then
    node.semantic_summary = existing.semantic_summary
    node.side_effects = existing.side_effects
    node.thinking = existing.thinking
  end

  M.upsert_node(node)
end

--- Update only the semantic fields of a node (after LLM analysis).
--- @param id string node ID
--- @param summary string semantic summary
--- @param side_effects string JSON array of side effects
--- @param thinking string|nil reasoning process
function M.update_semantic(id, summary, side_effects, thinking)
  if not db then return end
  db:eval([[
    UPDATE nodes SET semantic_summary = :semantic_summary, side_effects = :side_effects, thinking = :thinking WHERE id = :id
  ]], {
    id = id,
    semantic_summary = summary,
    side_effects = side_effects,
    thinking = thinking,
  })

  local node = M.get_node(id)
  if node then
    db:eval([[
      INSERT INTO analyses (node_id, project_id, hash, model, prompt_version, semantic_summary, side_effects, thinking, created_at)
      VALUES (:node_id, :project_id, :hash, :model, :prompt_version, :semantic_summary, :side_effects, :thinking, :created_at)
    ]], {
      node_id = id,
      project_id = node.project_id or utils.project_id(),
      hash = node.hash,
      model = config.get().ollama.model,
      prompt_version = "analyze_v2",
      semantic_summary = summary,
      side_effects = side_effects,
      thinking = thinking,
      created_at = os.time(),
    })
  end
end

--- Clear semantic fields for a node so it can be regenerated.
--- @param id string node ID
function M.clear_semantic(id)
  if not db then return end
  db:eval([[
    UPDATE nodes SET semantic_summary = NULL, side_effects = NULL, thinking = NULL WHERE id = :id
  ]], { id = id })
end

--- Get a node by ID.
--- @param id string
--- @return table|nil
function M.get_node(id)
  if not db then return nil end
  local rows = safe_rows(db:eval("SELECT * FROM nodes WHERE id = ?", { id }))
  return rows[1]
end

--- Find the node that contains a specific line in a file.
--- @param file_path string (relative)
--- @param line integer 0-indexed line number
--- @return table|nil
function M.get_node_at(file_path, line)
  if not db then return nil end
  local rows = safe_rows(db:eval([[
    SELECT * FROM nodes
    WHERE project_id = ? AND file_path = ? AND line_start <= ? AND line_end >= ?
    ORDER BY (line_end - line_start) ASC
    LIMIT 1
  ]], { utils.project_id(), file_path, line, line }))
  return rows[1]
end

--- Get all nodes for a file.
--- @param file_path string (relative)
--- @return table[]
function M.get_file_nodes(file_path, project_id)
  if not db then return {} end
  project_id = project_id or utils.project_id()
  return safe_rows(db:eval("SELECT * FROM nodes WHERE project_id = ? AND file_path = ? ORDER BY line_start", { project_id, file_path }))
end

--- Search nodes by name or summary
--- @param query string
--- @return table[]
function M.search_nodes(query)
  if not db then return {} end

  local words = vim.split(query, "%s+", { trimempty = true })
  if #words == 0 then return {} end

  local where_clauses = {}
  local params = { utils.project_id() }

  for _, word in ipairs(words) do
    table.insert(where_clauses, "(name LIKE ? OR semantic_summary LIKE ?)")
    local like_word = "%" .. word .. "%"
    table.insert(params, like_word)
    table.insert(params, like_word)
  end

  local sql = string.format([[
    SELECT * FROM nodes 
    WHERE project_id = ? AND %s
    ORDER BY file_path, line_start
    LIMIT 30
  ]], table.concat(where_clauses, " AND "))

  return safe_rows(db:eval(sql, params))
end

--- Delete all nodes (and cascading edges) for a file.
--- @param file_path string (relative)
function M.delete_file_nodes(file_path)
  if not db then return end
  db:eval("DELETE FROM nodes WHERE project_id = ? AND file_path = ?", { utils.project_id(), file_path })
end

--- Delete a single node by ID (and cascading edges).
--- @param id string
function M.delete_node(id)
  if not db then return end
  db:eval("DELETE FROM nodes WHERE id = ?", { id })
end

--- Find a node by name.
--- @param name string
--- @return table|nil
function M.get_node_by_name(name)
  if not db then return nil end
  local rows = safe_rows(db:eval("SELECT * FROM nodes WHERE project_id = ? AND name = ? LIMIT 1", { utils.project_id(), name }))
  return rows[1]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Edge Operations
-- ═══════════════════════════════════════════════════════════════════════════

--- Replace all outgoing edges from a source node.
--- @param source_id string
--- @param edges table[] list of { target_id, relation_type, source?, confidence? }
function M.replace_edges(source_id, edges)
  if not db then return end

  -- Delete existing outgoing structural edges from this source.
  db:eval("DELETE FROM edges WHERE source_id = ? AND COALESCE(source, 'treesitter') = 'treesitter'", { source_id })

  for _, edge in ipairs(edges) do
    M.add_edge(source_id, edge.target_id, edge.relation_type, edge.source or "treesitter", edge.confidence or 0.6)
  end
end

--- Add a single edge.
--- @param source_id string
--- @param target_id string
--- @param relation_type string "CALLS"|"IMPORTS"|"MUTATES"|"DEPENDS_ON"|"REFERENCES"|"VIOLATES"
--- @param source string|nil "treesitter"|"lsp"|"llm"|"manual"
--- @param confidence number|nil
function M.add_edge(source_id, target_id, relation_type, source, confidence)
  if not db then return end
  db:eval([[
    INSERT OR IGNORE INTO edges (source_id, target_id, relation_type, source, confidence)
    VALUES (:source_id, :target_id, :relation_type, :source, :confidence)
  ]], {
    source_id = source_id,
    target_id = target_id,
    relation_type = relation_type,
    source = source or "manual",
    confidence = confidence or 1.0,
  })
end

--- Get direct dependents (who calls this node?).
--- @param target_id string
--- @return table[]
function M.get_direct_dependents(target_id)
  if not db then return {} end
  return safe_rows(db:eval([[
    SELECT n.*, e.relation_type, e.source as edge_source, e.confidence
    FROM edges e JOIN nodes n ON e.source_id = n.id
    WHERE e.target_id = ?
  ]], { target_id }))
end

--- Get direct dependencies (what does this node call?).
--- @param source_id string
--- @return table[]
function M.get_direct_dependencies(source_id)
  if not db then return {} end
  return safe_rows(db:eval([[
    SELECT n.*, e.relation_type, e.source as edge_source, e.confidence
    FROM edges e JOIN nodes n ON e.target_id = n.id
    WHERE e.source_id = ?
  ]], { source_id }))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Graph Traversal — Recursive CTE (Blast Radius)
-- ═══════════════════════════════════════════════════════════════════════════

--- Compute the full blast radius: all nodes that transitively depend on the target.
--- Uses WITH RECURSIVE CTE to walk the dependency graph upward.
--- @param node_id string the node being modified
--- @param max_depth integer|nil max recursion depth (default from config)
--- @return table[] list of { id, name, type, file_path, line_start, line_end, depth }
function M.get_blast_radius(node_id, max_depth)
  if not db then return {} end
  max_depth = max_depth or config.get().blast_radius_max_depth

  return safe_rows(db:eval([[
    WITH RECURSIVE affected(id, depth) AS (
      SELECT source_id, 1
      FROM edges
      WHERE target_id = ?

      UNION

      SELECT e.source_id, a.depth + 1
      FROM edges e
      JOIN affected a ON e.target_id = a.id
      WHERE a.depth < ?
    )
    SELECT DISTINCT n.id, n.name, n.type, n.file_path, n.line_start, n.line_end,
           MIN(a.depth) as depth
    FROM affected a
    JOIN nodes n ON a.id = n.id
    GROUP BY n.id
    ORDER BY depth, n.file_path, n.line_start
  ]], { node_id, max_depth }))
end

--- Compute full dependency tree downward (what does this node depend on?).
--- @param node_id string
--- @param max_depth integer|nil
--- @return table[]
function M.get_dependency_tree(node_id, max_depth)
  if not db then return {} end
  max_depth = max_depth or config.get().blast_radius_max_depth

  return safe_rows(db:eval([[
    WITH RECURSIVE deps(id, depth) AS (
      SELECT target_id, 1
      FROM edges
      WHERE source_id = ?

      UNION

      SELECT e.target_id, d.depth + 1
      FROM edges e
      JOIN deps d ON e.source_id = d.id
      WHERE d.depth < ?
    )
    SELECT DISTINCT n.id, n.name, n.type, n.file_path, n.line_start, n.line_end,
           MIN(d.depth) as depth
    FROM deps d
    JOIN nodes n ON d.id = n.id
    GROUP BY n.id
    ORDER BY depth, n.file_path, n.line_start
  ]], { node_id, max_depth }))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Stats & Debug
-- ═══════════════════════════════════════════════════════════════════════════

--- Get database statistics.
--- @return table { node_count, edge_count, files }
function M.stats()
  if not db then return { node_count = 0, edge_count = 0, files = 0 } end

  local pid = utils.project_id()
  local nodes = safe_rows(db:eval("SELECT COUNT(*) as cnt FROM nodes WHERE project_id = ?", { pid }))
  local edges = safe_rows(db:eval([[
    SELECT COUNT(*) as cnt FROM edges e
    JOIN nodes n ON e.source_id = n.id
    WHERE n.project_id = ?
  ]], { pid }))
  local files = safe_rows(db:eval("SELECT COUNT(DISTINCT file_path) as cnt FROM nodes WHERE project_id = ?", { pid }))

  return {
    node_count = nodes[1] and nodes[1].cnt or 0,
    edge_count = edges[1] and edges[1].cnt or 0,
    files      = files[1] and files[1].cnt or 0,
  }
end

--- Debug: dump all nodes (for :MetaLSPDebug).
--- @return table[]
function M.dump_nodes(project_id_or_all)
  if not db then return {} end
  if project_id_or_all == true then
    return safe_rows(db:eval("SELECT * FROM nodes ORDER BY project_root, file_path, line_start"))
  end
  local pid = type(project_id_or_all) == "string" and project_id_or_all or utils.project_id()
  return safe_rows(db:eval("SELECT * FROM nodes WHERE project_id = ? ORDER BY file_path, line_start", { pid }))
end

--- Debug: dump all edges.
--- @return table[]
function M.dump_edges()
  if not db then return {} end
  return safe_rows(db:eval([[
    SELECT e.* FROM edges e
    JOIN nodes n ON e.source_id = n.id
    WHERE n.project_id = ?
    ORDER BY e.source_id
  ]], { utils.project_id() }))
end

--- Delete all graph data for the current project.
function M.clear_project()
  if not db then return end
  db:eval("DELETE FROM nodes WHERE project_id = ?", { utils.project_id() })
end

--- Find summaries that look invalid/refusal-like.
--- @return table[]
function M.bad_summaries()
  if not db then return {} end
  return safe_rows(db:eval([[
    SELECT * FROM nodes
    WHERE project_id = ? AND semantic_summary IS NOT NULL AND semantic_summary != ''
      AND (
        lower(semantic_summary) LIKE '%can''t assist%'
        OR lower(semantic_summary) LIKE '%cannot assist%'
        OR lower(semantic_summary) LIKE '%i''m sorry%'
        OR semantic_summary LIKE '{%"response"%'
      )
    ORDER BY file_path, line_start
  ]], { utils.project_id() }))
end

--- Record a local tool run for audit/debug.
--- @param name string
--- @param input string
--- @param output string
function M.record_tool_run(name, input, output)
  if not db then return end
  pcall(function()
    db:eval([[
      INSERT INTO tool_runs (project_id, tool_name, input, output, created_at)
      VALUES (:project_id, :tool_name, :input, :output, :created_at)
    ]], {
      project_id = utils.project_id(),
      tool_name = name,
      input = input or "",
      output = output or "",
      created_at = os.time(),
    })
  end)
end

--- Recent persisted tool runs for current project.
--- @param limit integer|nil
--- @return table[]
function M.tool_runs(limit)
  if not db then return {} end
  return safe_rows(db:eval([[
    SELECT * FROM tool_runs WHERE project_id = ? ORDER BY created_at DESC LIMIT ?
  ]], { utils.project_id(), limit or 20 }))
end

--- Self-test: verify schema and basic operations.
function M.test()
  if not M.init() then
    utils.notify("DB init failed", vim.log.levels.ERROR)
    return
  end

  -- Test upsert
  M.upsert_node({
    id = "test/file.go:TestFunc",
    name = "TestFunc",
    type = "function",
    file_path = "test/file.go",
    line_start = 10,
    line_end = 20,
    hash = "abc123",
    thinking = "My reasoning process goes here.",
  })

  -- Test retrieval
  local node = M.get_node("test/file.go:TestFunc")
  assert(node, "Node should exist after upsert")
  assert(node.name == "TestFunc", "Node name should match")
  assert(node.thinking == "My reasoning process goes here.", "Node thinking should match")

  -- Test get_node_at
  local at = M.get_node_at("test/file.go", 15)
  assert(at, "Should find node at line 15")

  -- Cleanup
  db:eval("DELETE FROM nodes WHERE id = ?", { "test/file.go:TestFunc" })

  local stats = M.stats()
  utils.notify(string.format("DB test passed! Stats: %d nodes, %d edges, %d files",
    stats.node_count, stats.edge_count, stats.files))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Operations
-- ═══════════════════════════════════════════════════════════════════════════

--- Get all pinned nodes for a project.
--- @param project_id string
--- @return table[] nodes list
function M.get_pinned_nodes(project_id)
  if not db then return {} end
  local rows = safe_rows(db:eval([[
    SELECT n.* FROM nodes n
    JOIN pins p ON n.id = p.node_id
    WHERE p.project_id = ?
  ]], { project_id }))
  return rows
end

--- Add a pinned node.
--- @param node_id string
--- @param project_id string
function M.add_pin(node_id, project_id)
  if not db then return end
  db:eval("INSERT OR IGNORE INTO pins (node_id, project_id) VALUES (?, ?)", { node_id, project_id })
end

--- Remove a pinned node.
--- @param node_id string
--- @param project_id string
function M.remove_pin(node_id, project_id)
  if not db then return end
  db:eval("DELETE FROM pins WHERE node_id = ? AND project_id = ?", { node_id, project_id })
end

--- Save chat session.
--- @param project_id string
--- @param chat_lines table array of strings
function M.save_chat_session(project_id, chat_lines)
  if not db then return end
  local json = vim.json.encode(chat_lines)
  db:eval([[
    INSERT INTO chat_sessions (project_id, chat_lines_json, updated_at)
    VALUES (:project_id, :json, :now)
    ON CONFLICT(project_id) DO UPDATE SET
      chat_lines_json = excluded.chat_lines_json,
      updated_at = excluded.updated_at
  ]], {
    project_id = project_id,
    json = json,
    now = os.time()
  })
end

--- Load chat session.
--- @param project_id string
--- @return table|nil chat_lines
function M.load_chat_session(project_id)
  if not db then return nil end
  local rows = safe_rows(db:eval("SELECT chat_lines_json FROM chat_sessions WHERE project_id = ?", { project_id }))
  if #rows == 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, rows[1].chat_lines_json)
  return ok and decoded or nil
end

return M
