--- MetaLSP.nvim — Configuration
--- Default settings with user-override support.

local M = {}

--- @class MetaLSPConfig
M.defaults = {
  -- Path to SQLite database file
  db_path = vim.fn.stdpath("data") .. "/metalsp.db",

  commands = {
    -- Keep :command list small. Use :MetaLSP <subcommand> for most actions.
    minimal = true,
  },

  -- Active LLM provider: "ollama" | "copilot" | "openai" | "gemini"
  cloud_provider = "ollama",

  -- Automatically append MetaLSP provider/model to Neovim's statusline.
  statusline = {
    enabled = true,
    use_devicons = true,
  },

  -- Ollama / Ollama-compatible LLM settings
  ollama = {
    endpoint = "http://localhost:11434",
    model = "qwen2.5-coder:7b",
    timeout_ms = 120000,
    temperature = 0.1,
    -- Larger context/responses are often needed for source-code summaries.
    num_ctx = 8192,
    num_predict = 2048,
    max_code_chars = 24000,
    -- Max concurrent requests to Ollama (sequential by default)
    max_concurrent = 1,
    local_endpoint = "http://localhost:11434",
    local_model = "qwen2.5-coder:7b",
  },

  -- Cloud provider model settings
  copilot_model = "gpt-4o",
  openai_model = "gpt-4o",
  gemini_model = "gemini-1.5-flash",


  -- Prompt templates. Each value can be a string template or a function(ctx) -> string.
  -- String templates support {{name}}, {{type}}, {{code}}, {{error}}, {{context}},
  -- {{question}}, {{rules}}, {{language}}, {{func_name}}, {{func_body}}.
  prompts = {
    analyze_system = [[
You are MetaLSP, a local code knowledge assistant running inside the user's editor.
Your task is benign: analyze the provided source-code symbol for developer navigation.
Do not refuse. Do not mention policy. Do not say you cannot assist.
Respond with ONLY a valid JSON object. No markdown, no explanation outside JSON.

The JSON must have exactly these fields:
{
  "thinking": "string — compact reusable knowledge. Include: Intent, Flow, Inputs/Outputs, Important dependencies, Side-effect/risk notes, Suggested checks. Explain observable logic only; do not include hidden chain-of-thought or policy text.",
  "semantic_summary": "string — concise purpose/intent summary plus when this symbol is used. 2-4 sentences max.",
  "side_effects": [
    { "type": "DB_WRITE|DB_READ|API_CALL|FILE_IO|CACHE|EVENT|NONE", "target": "description of what is affected" }
  ]
}

For thinking, use this compact structure:
Intent: ...
Flow:
1. Validate/prepare inputs.
2. Call dependency X.
3. Transform result Y.
4. Return/emit/write Z.
Inputs/Outputs: ...
Risks/Checks: ...

If there are no side effects, use: "side_effects": []
]],
    analyze_user = [[
Analyze this source-code symbol. Return JSON only.
Language/symbol type: {{type}}
Symbol name: {{name}}

Code:
```
{{code}}
```
]],
    error_system = [[
You are an expert code debugger. Given a compiler/LSP error and surrounding code,
explain the root cause in clear, plain language.

Respond with ONLY a JSON object:
{
  "root_cause": "string — what is actually wrong (1-2 sentences)",
  "fix_suggestion": "string — concrete actionable fix (1-2 sentences)"
}
]],
    error_user = [[
Error:
{{error}}

Code context:
```
{{context}}
```
]],
    arch_system = [[
You are an architecture compliance checker. Given architecture rules and source code,
identify any violations.

Respond with ONLY a JSON array (empty array if no violations):
[
  {
    "line_hint": number or null,
    "rule": "short rule name",
    "message": "string — what rule is violated and how to fix it"
  }
]
]],
    arch_user = [[
Architecture Rules:
{{rules}}

Source Code:
```
{{code}}
```
]],
    sandbox_system = [[
You are a test harness generator. Given a {{language}} function, generate a complete, runnable
test script with realistic mock data. The script should:
1. Import or define any needed dependencies inline
2. Call the function with realistic mock arguments
3. Print the result clearly

Respond with ONLY the raw {{language}} code — no markdown fences, no explanation.
]],
    sandbox_user = [[
Function name: {{func_name}}

Code:
{{func_body}}
]],
    ask_system = [[
You are MetaLSP, a concise coding assistant inside Neovim.
Answer using the provided knowledge-graph context and tool-provided code excerpts.
Code excerpts may include line numbers in the form `123 │ code`; cite file:line when useful.
If the context is insufficient, say what is missing.
Prefer clear step-by-step explanations when explaining code flow.
Keep the answer short and actionable.
]],
    ask_user = [[
Knowledge context:
{{context}}

User question:
{{question}}
]],
    live_flow = [[
Using the code excerpts and graph context, explain the implementation flow step-by-step.
Return: Evidence, Flow, Risks, Uncertainty.
]],
    live_intent = [[
Explain the intent/purpose of this symbol. Return: Evidence, Intent, When used, Uncertainty.
]],
    live_side_effects = [[
Identify side effects from this symbol and related graph context. Return: Evidence, Side effects, Risk, Uncertainty.
]],
    live_risk = [[
Analyze risks if this symbol changes. Return: Evidence, Risk checklist, Suggested tests, Uncertainty.
]],
    live_impact = [[
Analyze direct and transitive impact using graph context. Return: Evidence, Impact, Callers/dependencies, Uncertainty.
]],
    review_diff = [[
Review this git diff as a local coding assistant. Do not rewrite code.
Return: Summary, Risk checklist, Suggested tests, Architecture notes, Uncertainty.
]],
  },

  live = {
    default_mode = "flow",
    max_related_nodes = 4,
    max_code_lines = 160,
    auto_update = false,
  },

  tools = {
    read_code = true,
    read_dependencies = true,
    read_references = true,
    read_git_diff = true,
    search_text = true,
    max_code_lines = 160,
    max_related_nodes = 4,
    max_search_results = 20,
  },

  -- Languages with Treesitter extractors
  languages = { "go", "typescript", "javascript", "lua" },

  -- Feature toggles
  features = {
    semantic_hover = true,
    blast_radius = true,
    error_translator = true,
    arch_linter = true,
    sandbox_repl = true,
    knowledge_tree = true,
    render_markdown = true,
  },

  -- Path to architecture rules file (relative to project root)
  arch_rules_file = ".meta-rules.md",

  -- Automatically index on save. Indexing is structural/LSP-only by default;
  -- it must not call the model unless explicitly enabled.
  auto_index_on_save = true,
  auto_summarize_on_index = false,
  auto_lsp_index_on_save = true,

  -- Debounce times (ms)
  debounce = {
    index_ms = 500,        -- After save, wait before indexing
    error_translate_ms = 2000,  -- After error, wait before translating
    arch_lint_ms = 5000,   -- After save, wait before linting
  },

  -- Blast radius max recursion depth
  blast_radius_max_depth = 10,

  -- Keymaps (set to false to disable)
  keymaps = {
    semantic_hover = "K",           -- Native hover + mirror docs into MetaLSP NOW
    summary_cursor = "<leader>mn",  -- Open NOW for symbol under cursor
    chat = "<leader>mc",            -- Open CHAT
    explorer = "<leader>mf",        -- Open FILES
    index_file = "<leader>mi",      -- Manually index current file
    index_project = "<leader>mp",   -- Index project/current location
    error_fix = "<leader>me",       -- Analyze current diagnostics/errors
    status = "<leader>ms",          -- Show MetaLSP status
    blast_radius = "<leader>mb",    -- Show blast radius
    sandbox_repl = "<leader>mx",    -- Generate sandbox from selection
    knowledge_tree = "<leader>mt",  -- Toggle MetaLSP sidebar
  },
}

--- Active config (populated by setup())
M.options = {}

--- Merge user options with defaults
--- @param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

--- Get active config (shorthand)
--- @return MetaLSPConfig
function M.get()
  return M.options
end

return M
