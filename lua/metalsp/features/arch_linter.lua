--- MetaLSP.nvim — Feature 4: Architectural Consistency Linter
--- Reads .meta-rules.md from project root, sends code + rules to Ollama on save,
--- and reports violations as Neovim diagnostics (vim.diagnostic.set).

local M = {}

local ollama = require("metalsp.ollama")
local utils  = require("metalsp.utils")
local config = require("metalsp.config")
local db     = require("metalsp.db")

--- Diagnostic namespace for architectural violations.
local NS = vim.api.nvim_create_namespace("metalsp-arch")

--- Cache: file_path → { rules_hash, code_hash, violations }
--- Avoids re-linting when neither code nor rules changed.
local cache = {}

--- Try to read the architecture rules file.
--- @param root string project root path
--- @return string|nil rules_text, string|nil error
local function read_rules(root)
  local cfg = config.get()
  local rules_path = root .. "/" .. cfg.arch_rules_file

  local f = io.open(rules_path, "r")
  if not f then return nil, "Rules file not found: " .. rules_path end

  local text = f:read("*a")
  f:close()
  return text, nil
end

local function sync_rule_edges(bufnr, violations)
  local root = utils.get_project_root(bufnr) or vim.fn.getcwd()
  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr), root)
  local rules_file = config.get().arch_rules_file

  for i, v in ipairs(violations or {}) do
    local rule_name = (v.rule or v.message or "architecture rule"):sub(1, 80)
    local rule_id = utils.make_node_id(rules_file, "rule:" .. rule_name, root)
    db.upsert_node({
      id = rule_id,
      project_id = utils.project_id(root),
      project_root = vim.fs.normalize(root),
      name = rule_name,
      type = "architecture_rule",
      file_path = rules_file,
      line_start = 0,
      line_end = 0,
      hash = utils.hash(rule_name),
      semantic_summary = v.message,
      side_effects = "[]",
    })

    local lnum = (v.line_hint and v.line_hint > 0) and (v.line_hint - 1) or 0
    local source_node = db.get_node_at(file_path, lnum)
    if source_node then
      db.add_edge(source_node.id, rule_id, "VIOLATES", "llm", 0.8)
    end
  end
end

--- Set architectural violation diagnostics on a buffer.
--- @param bufnr integer
--- @param violations table[] list of { line_hint, message }
local function set_arch_diagnostics(bufnr, violations)
  local diags = {}
  for _, v in ipairs(violations) do
    local lnum = (v.line_hint and v.line_hint > 0) and (v.line_hint - 1) or 0
    -- Clamp to buffer size
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if lnum >= line_count then lnum = math.max(0, line_count - 1) end

    diags[#diags + 1] = {
      lnum     = lnum,
      col      = 0,
      end_lnum = lnum,
      end_col  = -1,
      severity = vim.diagnostic.severity.WARN,
      message  = "⚙ [Arch] " .. (v.message or "Architecture rule violation"),
      source   = "metalsp-arch",
    }
  end

  vim.diagnostic.set(NS, bufnr, diags, {
    virtual_text = {
      prefix = "⚙",
      spacing = 4,
    },
    underline = true,
    signs = true,
  })
end

--- Lint a buffer against architecture rules.
--- @param bufnr integer
function M.lint(bufnr)
  bufnr = bufnr or 0

  local root = utils.get_project_root(bufnr)
  if not root then return end

  local rules_text, err = read_rules(root)
  if not rules_text then
    -- No rules file — silently clear any existing arch diagnostics
    vim.diagnostic.set(NS, bufnr, {})
    return
  end

  -- Get full buffer code
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local code = table.concat(lines, "\n")

  -- Check cache — skip if nothing changed
  local file_path = utils.relative_path(vim.api.nvim_buf_get_name(bufnr))
  local combined_hash = utils.hash(rules_text .. code)
  if cache[file_path] and cache[file_path].hash == combined_hash then
    -- Re-apply cached diagnostics (buffer may have been reloaded)
    set_arch_diagnostics(bufnr, cache[file_path].violations)
    return
  end

  -- Send to Ollama
  ollama.check_arch_rules(code, rules_text, function(violations, ollama_err)
    if ollama_err then return end
    violations = violations or {}

    -- Update cache
    cache[file_path] = { hash = combined_hash, violations = violations }

    -- Apply diagnostics
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      set_arch_diagnostics(bufnr, violations)
      sync_rule_edges(bufnr, violations)

      if #violations > 0 then
        utils.notify(string.format(
          "⚙ %d architecture violation(s) in %s",
          #violations, vim.fn.fnamemodify(file_path, ":t")
        ), vim.log.levels.WARN)
      end
    end)
  end)
end

--- Debounced lint trigger (5s after save — expensive LLM call).
local lint_debounced = utils.debounce(function(bufnr)
  M.lint(bufnr)
end, 5000)

--- Setup: register BufWritePost autocmd.
function M.setup()
  vim.api.nvim_create_autocmd("BufWritePost", {
    group    = vim.api.nvim_create_augroup("metalsp-arch-lint", { clear = true }),
    callback = function(ev)
      local lang = utils.get_language(ev.buf)
      if not lang then return end
      lint_debounced(ev.buf)
    end,
  })

  -- Manual trigger command
  vim.api.nvim_create_user_command("MetaLSPLint", function()
    M.lint(vim.api.nvim_get_current_buf())
  end, { desc = "MetaLSP: Run architecture lint on current file" })

  -- Clear arch diagnostics command
  vim.api.nvim_create_user_command("MetaLSPClearLint", function()
    vim.diagnostic.set(NS, vim.api.nvim_get_current_buf(), {})
    utils.notify("Architecture diagnostics cleared")
  end, { desc = "MetaLSP: Clear architecture diagnostics" })
end

return M
