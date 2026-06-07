--- MetaLSP.nvim — Main Entry Point
--- Orchestrates the full indexing pipeline and wires up all features.

local M = {}

local config  = require("metalsp.config")
local utils   = require("metalsp.utils")
local db      = require("metalsp.db")
local ts      = require("metalsp.treesitter")
local detector = require("metalsp.change_detector")
local ollama  = require("metalsp.ollama")
local prompts = require("metalsp.prompts")
local tools   = require("metalsp.tools")
local lsp_indexer = require("metalsp.lsp_indexer")

-- ═══════════════════════════════════════════════════════════════════════════
-- Indexing Pipeline
-- ═══════════════════════════════════════════════════════════════════════════

local ANALYZABLE_TYPES = {
  ["function"] = true,
  ["method"] = true,
  ["class"] = true,
  ["struct"] = true,
  ["interface"] = true,
  ["type_alias"] = true,
}

local function is_analyzable_symbol(sym)
  return sym and ANALYZABLE_TYPES[sym.type] == true
end

--- Full indexing pipeline triggered on BufWritePost.
--- 1. Detect changes (hash comparison)
--- 2. Update DB with structural data immediately
--- 3. Queue changed symbols for Ollama analysis
--- 4. Trigger blast radius notification for changed symbols
---
--- @param bufnr integer
local function index_buffer(bufnr)
  local file_abs = vim.api.nvim_buf_get_name(bufnr)
  if file_abs == "" then return end

  local root = utils.get_project_root(bufnr)
  if not root then return end

  local file_path = utils.relative_path(file_abs, root)

  -- Step 1 & 2: Detect changes + update DB structure
  local report = detector.detect(bufnr, file_path)
  local changed_syms = detector.apply(report, file_path)

  local semantic_syms = vim.tbl_filter(is_analyzable_symbol, changed_syms)
  local cfg = config.get()

  -- Step 3: optionally enrich graph with LSP facts. Indexing should not call
  -- the model by default; summaries are user-triggered from Live/Tree (`a`, `s`).
  if cfg.auto_lsp_index_on_save then
    for _, sym in ipairs(semantic_syms) do
      local node = db.get_node(sym.id)
      if node then
        lsp_indexer.index_dependencies_for_node(node, function() end)
        lsp_indexer.index_references_for_node(node, function() end)
      end
    end
  end

  if cfg.auto_summarize_on_index then
    for _, sym in ipairs(semantic_syms) do
      local sym_id = sym.id
      local sym_hash = sym.hash
      ollama.analyze_function(sym, function(summary, side_effects, err, thinking)
        if err or not summary then return end
        local current = db.get_node(sym_id)
        if not current or current.hash ~= sym_hash then return end
        db.update_semantic(sym_id, summary, side_effects, thinking)
      end)
    end
  end

  -- Step 4: Notify blast radius if anything changed
  if cfg.features.blast_radius and #semantic_syms > 0 then
    require("metalsp.features.blast_radius").on_changed_nodes(semantic_syms)
  end

  -- Debug log
  if #changed_syms > 0 or #report.deleted > 0 then
    vim.notify(
      string.format("[MetaLSP] Indexed %s: %d changed, %d deleted, %d unchanged",
        vim.fn.fnamemodify(file_path, ":t"),
        #changed_syms, #report.deleted, #report.unchanged),
      vim.log.levels.DEBUG
    )
  end
end

--- Debounced indexer — won't fire more than once per debounce period.
local index_debounced = nil

-- ═══════════════════════════════════════════════════════════════════════════
-- User Commands
-- ═══════════════════════════════════════════════════════════════════════════

function M.index_file_path(abs_path)
  local bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  local ft = vim.filetype.match({ filename = abs_path })
  if ft then vim.bo[bufnr].filetype = ft end
  if ts.is_supported(bufnr) then
    index_buffer(bufnr)
    return true
  end
  return false
end
local index_file_path = M.index_file_path

local function show_lines_popup(title, lines)
  local ok_nui, Popup = pcall(require, "nui.popup")
  if not ok_nui then vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO); return end
  local event = require("nui.utils.autocmd").event
  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local popup = Popup({
    position = "50%",
    size = { width = math.min(max_w + 4, math.max(50, math.floor(vim.o.columns * 0.7))), height = math.min(#lines + 2, math.max(8, math.floor(vim.o.lines * 0.7))) },
    relative = "editor",
    border = { style = "rounded", text = { top = " " .. title .. " ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false, filetype = "markdown" },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder", wrap = true, linebreak = true },
  })
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, utils.buffer_safe_lines(lines))
  vim.bo[popup.bufnr].modifiable = false
  popup:map("n", "q", function() popup:unmount() end, { noremap = true })
  popup:map("n", "<Esc>", function() popup:unmount() end, { noremap = true })
  popup:on(event.BufLeave, function() popup:unmount() end, { once = true })
  utils.render_markdown(popup.bufnr)
end

local function run_doctor()
  local lines = { "# MetaLSP Doctor", "" }
  local function check(label, ok, detail)
    lines[#lines + 1] = string.format("- %s %s%s", ok and "OK" or "WARN", label, detail and (": " .. detail) or "")
  end
  check("sqlite DB", db.handle() ~= nil, config.get().db_path)
  check("nui.nvim", (pcall(require, "nui.popup")))
  check("render-markdown.nvim", (pcall(require, "render-markdown")))
  check("treesitter supported", ts.is_supported(vim.api.nvim_get_current_buf()), vim.bo.filetype)
  local clients = vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf() })
  check("LSP attached", #clients > 0, #clients .. " client(s)")
  local stats = db.stats()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Graph"
  lines[#lines + 1] = string.format("- nodes: %d", stats.node_count)
  lines[#lines + 1] = string.format("- edges: %d", stats.edge_count)
  lines[#lines + 1] = string.format("- files: %d", stats.files)
  lines[#lines + 1] = string.format("- bad summaries: %d", #db.bad_summaries())
  ollama.check_health(function(ok, models)
    vim.schedule(function()
      check("Ollama", ok, ok and ((models and #models or 0) .. " model(s)") or "unreachable")
      show_lines_popup("MetaLSP Doctor", lines)
    end)
  end)
end

local function attach_cloud_model(args)
  local parts = vim.split(args or "", " ", { trimempty = true })
  local cfg = config.get()
  if parts[1] == "off" or parts[1] == "local" then
    cfg.ollama.endpoint = cfg.ollama.local_endpoint or "http://localhost:11434"
    cfg.ollama.model = cfg.ollama.local_model or cfg.ollama.model
    utils.notify("MetaLSP model: local " .. cfg.ollama.model)
    return
  end
  local endpoint, model = parts[1], parts[2]
  if not endpoint or not model then
    utils.notify("Usage: :MetaLSPCloudModel <ollama-compatible-endpoint> <model> | off", vim.log.levels.WARN)
    return
  end
  cfg.ollama.local_endpoint = cfg.ollama.local_endpoint or cfg.ollama.endpoint
  cfg.ollama.local_model = cfg.ollama.local_model or cfg.ollama.model
  cfg.ollama.endpoint = endpoint:gsub("/$", "")
  cfg.ollama.model = model
  utils.notify("MetaLSP cloud model attached: " .. model .. " @ " .. cfg.ollama.endpoint)
end

local selected_model_state_path = vim.fn.stdpath("data") .. "/metalsp_selected_model.json"

local function get_configured_model(cfg, provider)
  if provider == "ollama" then
    return cfg.ollama and cfg.ollama.model
  elseif provider == "copilot" then
    return cfg.copilot_model
  elseif provider == "openai" then
    return cfg.openai_model
  elseif provider == "gemini" then
    return cfg.gemini_model
  end
end

local function set_configured_model(cfg, provider, model)
  if not provider or not model or model == "" then return end
  cfg.cloud_provider = provider
  if provider == "ollama" then
    cfg.ollama.model = model
  elseif provider == "copilot" then
    cfg.copilot_model = model
  elseif provider == "openai" then
    cfg.openai_model = model
  elseif provider == "gemini" then
    cfg.gemini_model = model
  end
end

local function save_selected_model(provider, model)
  if not provider or not model or model == "" then return end
  local data = {
    provider = provider,
    model = model,
    updated_at = os.time(),
  }
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(selected_model_state_path, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(data) }, selected_model_state_path)
end

local function load_selected_model()
  if vim.fn.filereadable(selected_model_state_path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, selected_model_state_path)
  if not ok or not lines then return nil end
  local ok_decode, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(data) ~= "table" then return nil end
  if not ({ ollama = true, copilot = true, openai = true, gemini = true })[data.provider] then return nil end
  if type(data.model) ~= "string" or data.model == "" then return nil end
  return data
end

local function apply_latest_selected_model(cfg)
  local selected = load_selected_model()
  if selected then
    set_configured_model(cfg, selected.provider, selected.model)
  end
  return selected
end

local function uniq_sorted_models(models)
  local seen, out = {}, {}
  for _, m in ipairs(models or {}) do
    if type(m) == "string" and m ~= "" and not seen[m] then
      seen[m] = true
      out[#out + 1] = m
    end
  end
  table.sort(out)
  return out
end

local function looks_like_model_id(provider, value)
  if type(value) ~= "string" or value == "" then return false end
  value = value:gsub("^models/", "")
  if provider == "openai" then
    return value:match("^gpt[%w%.-]*") or value:match("^o%d[%w%.-]*") or value:match("^codex[%w%.-]*")
  elseif provider == "gemini" then
    return value:match("^gemini[%w%.-]*") ~= nil
  elseif provider == "copilot" then
    return value:match("^gpt[%w%.-]*") or value:match("^claude[%w%.-]*") or value:match("^o%d[%w%.-]*")
  end
  return true
end

local function parse_model_list(provider, stdout)
  local ok, res = pcall(vim.json.decode, stdout or "")
  if not ok or type(res) ~= "table" then return nil end
  local models = {}

  local function add(value)
    if type(value) ~= "string" then return end
    value = value:gsub("^models/", "")
    if looks_like_model_id(provider, value) then models[#models + 1] = value end
  end

  local function visit(value, depth)
    if depth > 8 or type(value) ~= "table" then return end
    add(value.id)
    add(value.name)
    add(value.slug)
    add(value.model)
    add(value.model_slug)
    add(value.default_model)
    add(value.current_model)
    add(value.title)
    for _, child in pairs(value) do
      if type(child) == "table" then
        visit(child, depth + 1)
      elseif type(child) == "string" then
        add(child)
      end
    end
  end

  visit(res, 0)
  return uniq_sorted_models(models)
end

local function is_openai_platform_api_key(token)
  return type(token) == "string" and (token:match("^sk%-") or token:match("^sess%-"))
end

local function openai_model_list_urls(creds, token)
  local op = creds and creds.openai or {}
  local has_oauth = type(op) == "table" and (op.access_token or op.refresh_token)
  local has_api_key = is_openai_platform_api_key(token) or (type(op) == "table" and op.api_key and not has_oauth)

  if has_api_key then
    -- Platform API key model discovery, equivalent to:
    -- curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"
    return { "https://api.openai.com/v1/models" }
  end

  -- ChatGPT/Codex OAuth tokens are not regular platform API keys. The public
  -- /v1/models endpoint can omit Codex subscription models (e.g. gpt-5.5), so
  -- try ChatGPT backend model endpoints first.
  return {
    "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0",
    "https://chatgpt.com/backend-api/models?history_and_training_disabled=false",
    "https://chatgpt.com/backend-api/models",
    "https://api.openai.com/v1/models",
  }
end

local function fetch_cloud_models(provider, callback)
  local cloud_auth = require("metalsp.cloud_auth")
  local ok_creds, creds = pcall(cloud_auth.load_credentials)
  creds = ok_creds and creds or {}
  local urls
  if provider == "gemini" then
    urls = { "https://generativelanguage.googleapis.com/v1beta/openai/models" }
  elseif provider == "copilot" then
    urls = { "https://api.githubcopilot.com/models" }
  elseif provider ~= "openai" then
    callback({})
    return
  end

  cloud_auth.get_token(provider, function(token, auth_err)
    if auth_err or not token then
      -- Not logged in: do not show this provider in the model picker.
      vim.schedule(function() callback({}) end)
      return
    end

    if provider == "openai" then
      urls = openai_model_list_urls(creds, token)
    end

    local function build_curl_args(url)
      local curl_args = {
        "curl", "-s", "-L", "--max-time", "20",
        "-w", "\n__METALSP_HTTP_STATUS__:%{http_code}",
        url,
        "-H", "Authorization: Bearer " .. token,
        "-H", "Accept: application/json",
      }

      if provider == "openai" then
        if not is_openai_platform_api_key(token) then
          local account_id = creds and creds.openai and creds.openai.account_id
          if account_id and account_id ~= "" then
            vim.list_extend(curl_args, {
              "-H", "chatgpt-account-id: " .. tostring(account_id),
              "-H", "OpenAI-Account-ID: " .. tostring(account_id),
            })
          end
          vim.list_extend(curl_args, {
            "-H", "originator: pi",
            "-H", "User-Agent: MetaLSP.nvim",
            "-H", "oai-language: en-US",
          })
        end
      elseif provider == "copilot" then
        vim.list_extend(curl_args, {
          "-H", "Copilot-Integration-Id: vscode-chat",
          "-H", "Editor-Version: Neovim/" .. (vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch),
          "-H", "Editor-Plugin-Version: MetaLSP.nvim/1.0.0",
        })
      end
      return curl_args
    end

    local function try_url(index)
      local url = urls[index]
      if not url then
        vim.schedule(function() callback({}) end)
        return
      end

      vim.system(build_curl_args(url), { text = true }, function(obj)
        local models = nil
        local stdout = obj.stdout or ""
        local status = stdout:match("\n__METALSP_HTTP_STATUS__:(%d+)%s*$")
        stdout = stdout:gsub("\n__METALSP_HTTP_STATUS__:%d+%s*$", "")
        if obj.code == 0 and status and status:match("^2") then
          models = parse_model_list(provider, stdout)
        end
        if models and #models > 0 then
          vim.schedule(function() callback(models) end)
        else
          if index == #urls then
            vim.schedule(function()
              local msg = string.format("No %s models returned from provider API", provider)
              if status then msg = msg .. " (last HTTP " .. status .. ")" end
              utils.notify(msg, vim.log.levels.WARN)
            end)
          end
          try_url(index + 1)
        end
      end)
    end

    try_url(1)
  end)
end

local function prune_legacy_commands()
  if config.get().commands and config.get().commands.minimal == false then return end
  local keep = {
    MetaLSP = true,
    MetaLSPTree = true,
    MetaLSPLive = true,
    MetaLSPIndex = true,
    MetaLSPProjectIndex = true,
    MetaLSPSettings = true,
    MetaLSPDoctor = true,
    MetaLSPErrorFix = true,
    MetaLSPTool = true,
    MetaLSPRecentTools = true,
    MetaLSPCloudModel = true,
    MetaLSPLogin = true,
    MetaLSPProvider = true,
    MetaLSPLogout = true,
    MetaLSPStatus = true,
    MetaLSPModel = true,
  }
  for name, _ in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    if name:match("^MetaLSP") and not keep[name] then
      pcall(vim.api.nvim_del_user_command, name)
    end
  end
end

local function register_commands()
  vim.api.nvim_create_user_command("MetaLSP", function(opts)
    local args = vim.split(opts.args or "", " ", { trimempty = true })
    local sub = args[1] or "tree"
    local function rest(from)
      local out = {}
      for i = from, #args do out[#out + 1] = args[i] end
      return table.concat(out, " ")
    end
    if sub == "tree" then vim.cmd("MetaLSPTree")
    elseif sub == "live" then vim.cmd("MetaLSPLive " .. rest(2))
    elseif sub == "index" then vim.cmd("MetaLSPIndex")
    elseif sub == "index-project" or sub == "project-index" then vim.cmd("MetaLSPProjectIndex")
    elseif sub == "settings" then vim.cmd("MetaLSPSettings")
    elseif sub == "doctor" then run_doctor()
    elseif sub == "cloud" or sub == "cloud-model" then attach_cloud_model(rest(2))
    elseif sub == "error-fix" or sub == "errors" then vim.cmd("MetaLSPErrorFix")
    elseif sub == "tools" then vim.cmd("MetaLSPRecentTools")
    elseif sub == "tool" then vim.cmd("MetaLSPTool " .. rest(2))
    elseif sub == "search" then
      local ok, search = pcall(require, "metalsp.features.semantic_search")
      if ok then search.search(rest(2)) else utils.notify("Semantic search not available", vim.log.levels.ERROR) end
    elseif sub == "commit" then
      local ok, commit = pcall(require, "metalsp.features.smart_commit")
      if ok then commit.generate_commit() else utils.notify("Smart commit not available", vim.log.levels.ERROR) end
    elseif sub == "explorer" then
      local tree = require("metalsp.features.knowledge_tree")
      tree.open()
      tree.switch_tab("explorer")
    elseif sub == "login" then vim.cmd("MetaLSPLogin " .. rest(2))
    elseif sub == "provider" then vim.cmd("MetaLSPProvider " .. rest(2))
    elseif sub == "logout" then vim.cmd("MetaLSPLogout " .. rest(2))
    elseif sub == "model" then vim.cmd("MetaLSPModel")
    else utils.notify("MetaLSP: tree, live, index, index-project, settings, doctor, search, commit, explorer, tool, tools, login, provider, logout, model", vim.log.levels.WARN) end
  end, { nargs = "*", complete = function(_, line)
    local parts = vim.split(line, " ", { trimempty = true })
    if #parts <= 1 then return { "tree", "live", "index", "index-project", "settings", "doctor", "search", "commit", "explorer", "cloud", "cloud-model", "error-fix", "errors", "tool", "tools", "login", "provider", "logout", "model" } end
    if parts[2] == "live" then return { "flow", "intent", "side_effects", "risk", "impact" } end
    if parts[2] == "tool" then return { "read_git_diff", "read_git_diff_staged", "search_text" } end
    if parts[2] == "login" then return { "copilot", "openai", "gemini" } end
    if parts[2] == "provider" then return { "ollama", "copilot", "openai", "gemini" } end
    if parts[2] == "logout" then return { "copilot", "openai", "gemini" } end
    return {}
  end, desc = "MetaLSP command dispatcher" })

  vim.api.nvim_create_user_command("MetaLSPDoctor", run_doctor, { desc = "MetaLSP: Health check" })
  vim.api.nvim_create_user_command("MetaLSPCloudModel", function(opts)
    attach_cloud_model(opts.args)
  end, { nargs = "*", desc = "MetaLSP: Attach Ollama-compatible cloud model" })

  vim.api.nvim_create_user_command("MetaLSPLogin", function(opts)
    local args = vim.split(opts.args or "", " ", { trimempty = true })
    local provider = args[1]
    local cloud_auth = require("metalsp.cloud_auth")
    local provider_names = {
      copilot = "GitHub Copilot",
      openai = "OpenAI",
      gemini = "Google Gemini",
    }

    local function finish_login(success, err)
      if success then
        utils.notify("Successfully logged in to " .. provider_names[provider] .. "!", vim.log.levels.INFO)
        config.get().cloud_provider = provider
      else
        utils.notify(provider_names[provider] .. " login failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end

    local function start_login()
      if provider == "copilot" then
        cloud_auth.login_copilot(finish_login)
      elseif provider == "openai" then
        cloud_auth.login_openai(finish_login)
      elseif provider == "gemini" then
        cloud_auth.login_gemini(finish_login)
      else
        utils.notify("Usage: :MetaLSPLogin <copilot|openai|gemini>", vim.log.levels.WARN)
      end
    end

    if not provider_names[provider] then
      utils.notify("Usage: :MetaLSPLogin <copilot|openai|gemini>", vim.log.levels.WARN)
      return
    end

    if opts.bang then
      start_login()
      return
    end

    -- Check existing auth first. This also refreshes OAuth/session tokens when possible.
    cloud_auth.get_token(provider, function(token, _err)
      vim.schedule(function()
        if token and token ~= "" then
          config.get().cloud_provider = provider
          utils.notify(provider_names[provider] .. " is already authenticated. Use :MetaLSPLogin! " .. provider .. " to force re-login.", vim.log.levels.INFO)
        else
          start_login()
        end
      end)
    end)
  end, {
    nargs = 1,
    bang = true,
    complete = function() return { "copilot", "openai", "gemini" } end,
    desc = "MetaLSP: Login to a cloud provider"
  })

  vim.api.nvim_create_user_command("MetaLSPProvider", function(opts)
    local args = vim.split(opts.args or "", " ", { trimempty = true })
    local provider = args[1]
    local allowed = { ollama = true, copilot = true, openai = true, gemini = true }
    if allowed[provider] then
      config.get().cloud_provider = provider
      utils.notify("MetaLSP provider set to: " .. provider, vim.log.levels.INFO)
    else
      utils.notify("Usage: :MetaLSPProvider <ollama|copilot|openai|gemini>", vim.log.levels.WARN)
    end
  end, {
    nargs = 1,
    complete = function() return { "ollama", "copilot", "openai", "gemini" } end,
    desc = "MetaLSP: Switch active LLM provider"
  })

  vim.api.nvim_create_user_command("MetaLSPLogout", function(opts)
    local args = vim.split(opts.args or "", " ", { trimempty = true })
    local provider = args[1] ~= "" and args[1] or nil
    local cloud_auth = require("metalsp.cloud_auth")
    cloud_auth.logout(provider)
  end, {
    nargs = "?",
    complete = function() return { "copilot", "openai", "gemini" } end,
    desc = "MetaLSP: Logout from a cloud provider (clears tokens)"
  })

  -- Manually index current file
  vim.api.nvim_create_user_command("MetaLSPIndex", function()
    local bufnr = vim.api.nvim_get_current_buf()
    if ts.is_supported(bufnr) then
      index_buffer(bufnr)
      utils.notify("Indexing complete for " .. vim.fn.expand("%:t"))
    else
      utils.notify("File type not supported for indexing", vim.log.levels.WARN)
    end
  end, { desc = "MetaLSP: Index current file" })

  -- Index all supported files under the current location/folder.
  vim.api.nvim_create_user_command("MetaLSPProjectIndex", function()
    local root = utils.current_location_folder()
    vim.system({ "rg", "--files", "-g", "!vendor", "-g", "!node_modules", "-g", "!.git" }, { cwd = root, text = true }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          utils.notify("Project indexing failed: " .. tostring(obj.stderr), vim.log.levels.WARN)
          return
        end
        local total, indexed = 0, 0
        for _, rel in ipairs(vim.split(obj.stdout or "", "\n", { trimempty = true })) do
          total = total + 1
          if index_file_path(root .. "/" .. rel) then indexed = indexed + 1 end
        end
        utils.notify(string.format("Index queued from current location (%s): %d/%d supported files", vim.fn.fnamemodify(root, ":~:."), indexed, total))
      end)
    end)
  end, { desc = "MetaLSP: Index from current location" })

  vim.api.nvim_create_user_command("MetaLSPClearProject", function()
    db.clear_project()
    utils.notify("Cleared MetaLSP graph for current project")
  end, { desc = "MetaLSP: Clear current project graph" })

  vim.api.nvim_create_user_command("MetaLSPSettings", function()
    local cfg = config.get()
    local lines = {
      "MetaLSP Settings",
      string.rep("─", 40),
      "active provider:         " .. tostring(cfg.cloud_provider or "ollama"),
      "ollama model (local):    " .. tostring(cfg.ollama.model),
      "copilot model (cloud):   " .. tostring(cfg.copilot_model or "gpt-4o"),
      "openai model (cloud):    " .. tostring(cfg.openai_model or "gpt-4o"),
      "gemini model (cloud):    " .. tostring(cfg.gemini_model or "gemini-1.5-flash"),
      "endpoint (local):        " .. tostring(cfg.ollama.endpoint),
      "num_ctx:                 " .. tostring(cfg.ollama.num_ctx),
      "num_predict:             " .. tostring(cfg.ollama.num_predict),
      "temperature:             " .. tostring(cfg.ollama.temperature),
      "max_code_chars:          " .. tostring(cfg.ollama.max_code_chars),
      "live.default_mode:       " .. tostring(cfg.live and cfg.live.default_mode),
      "auto_index_on_save:      " .. tostring(cfg.auto_index_on_save),
      "auto_lsp_index_on_save:  " .. tostring(cfg.auto_lsp_index_on_save),
      "auto_summarize_on_index: " .. tostring(cfg.auto_summarize_on_index),
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "MetaLSP: Show runtime settings" })

  vim.api.nvim_create_user_command("MetaLSPModel", function()
    local cfg = config.get()
    apply_latest_selected_model(cfg)
    local current_provider = cfg.cloud_provider or "ollama"
    local current_model = get_configured_model(cfg, current_provider) or "unknown"

    local function apply_choice(target)
      set_configured_model(cfg, target.provider, target.model)
      save_selected_model(target.provider, target.model)
      pcall(vim.cmd, "redrawstatus")
      utils.notify(string.format("MetaLSP model set to [%s] %s", target.provider, target.model), vim.log.levels.INFO)
    end

    local function show_model_picker(ollama_ok, local_models, cloud_models)
      local options = {}
      local mapping = {}

      if ollama_ok and local_models then
        for _, m in ipairs(local_models) do
          local label = string.format("[ollama] %s", m)
          table.insert(options, label)
          mapping[label] = { provider = "ollama", model = m }
        end
      end

      for _, provider in ipairs({ "openai", "gemini", "copilot" }) do
        for _, m in ipairs(cloud_models[provider] or {}) do
          local label = string.format("[%s] %s", provider, m)
          table.insert(options, label)
          mapping[label] = { provider = provider, model = m }
        end
      end

      local custom_label = "✍️ Enter custom model name..."
      table.insert(options, custom_label)

      local prompt = string.format("Select Model (Current: [%s] %s)", current_provider, current_model)
      vim.ui.select(options, { prompt = prompt }, function(choice)
        if not choice then return end

        if choice == custom_label then
          vim.ui.select({ "ollama", "copilot", "openai", "gemini" }, { prompt = "Select provider for custom model:" }, function(provider)
            if not provider then return end
            vim.ui.input({ prompt = "Enter custom model name: " }, function(model_name)
              if not model_name or model_name == "" then return end
              apply_choice({ provider = provider, model = model_name })
            end)
          end)
        else
          local target = mapping[choice]
          if target then apply_choice(target) end
        end
      end)
    end

    utils.notify("Fetching model list from provider APIs...", vim.log.levels.INFO)
    ollama.check_health(function(ollama_ok, local_models)
      local cloud_models = {}
      local pending = 3
      local function done(provider, models)
        cloud_models[provider] = models
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            show_model_picker(ollama_ok, local_models, cloud_models)
          end)
        end
      end

      fetch_cloud_models("openai", function(models)
        done("openai", models)
      end)
      fetch_cloud_models("gemini", function(models)
        done("gemini", models)
      end)
      fetch_cloud_models("copilot", function(models)
        done("copilot", models)
      end)
    end)
  end, { desc = "MetaLSP: List and select available local/cloud models" })

  vim.api.nvim_create_user_command("MetaLSPSetModel", function(opts)
    local cfg = config.get()
    cfg.ollama.model = opts.args
    cfg.cloud_provider = "ollama"
    save_selected_model("ollama", opts.args)
    pcall(vim.cmd, "redrawstatus")
    utils.notify("Model set to " .. opts.args)
  end, { nargs = 1, desc = "MetaLSP: Set Ollama model" })

  vim.api.nvim_create_user_command("MetaLSPSetContext", function(opts)
    config.get().ollama.num_ctx = tonumber(opts.args) or config.get().ollama.num_ctx
    utils.notify("Context size set to " .. tostring(config.get().ollama.num_ctx))
  end, { nargs = 1, desc = "MetaLSP: Set Ollama num_ctx" })

  vim.api.nvim_create_user_command("MetaLSPSetPredict", function(opts)
    config.get().ollama.num_predict = tonumber(opts.args) or config.get().ollama.num_predict
    utils.notify("Predict tokens set to " .. tostring(config.get().ollama.num_predict))
  end, { nargs = 1, desc = "MetaLSP: Set Ollama num_predict" })

  vim.api.nvim_create_user_command("MetaLSPSetTemperature", function(opts)
    config.get().ollama.temperature = tonumber(opts.args) or config.get().ollama.temperature
    utils.notify("Temperature set to " .. tostring(config.get().ollama.temperature))
  end, { nargs = 1, desc = "MetaLSP: Set Ollama temperature" })

  vim.api.nvim_create_user_command("MetaLSPPrompts", function()
    vim.notify("MetaLSP prompts:\n" .. table.concat(prompts.names(), "\n"), vim.log.levels.INFO)
  end, { desc = "MetaLSP: List prompts" })

  vim.api.nvim_create_user_command("MetaLSPEditPrompt", function(opts)
    prompts.edit(opts.args)
  end, { nargs = 1, complete = function() return prompts.names() end, desc = "MetaLSP: Edit prompt in .metalsp/prompts" })

  vim.api.nvim_create_user_command("MetaLSPReloadPrompts", function()
    prompts.reload()
    utils.notify("Prompts reloaded")
  end, { desc = "MetaLSP: Reload project prompts" })

  vim.api.nvim_create_user_command("MetaLSPTool", function(opts)
    local args = vim.split(opts.args or "", " ", { trimempty = true })
    local name = args[1]
    local output
    if name == "read_git_diff" then
      output = tools.read_git_diff(false)
    elseif name == "read_git_diff_staged" then
      output = tools.read_git_diff(true)
    elseif name == "search_text" then
      local query_parts = {}
      for i = 2, #args do query_parts[#query_parts + 1] = args[i] end
      output = tools.search_text(table.concat(query_parts, " "), config.get().tools.max_search_results)
    elseif name == "read_file_location" then
      output = tools.read_file_location(args[2] or "")
    elseif name == "read_url" then
      output = tools.read_url(args[2] or "")
    else
      utils.notify("Supported tools: read_git_diff, read_git_diff_staged, search_text <query>, read_file_location <file:line>, read_url <url>", vim.log.levels.WARN)
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, "MetaLSP Tool: " .. name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, utils.buffer_safe_lines(output))
    utils.render_markdown(buf)
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
  end, { nargs = "+", complete = function() return { "read_git_diff", "read_git_diff_staged", "search_text", "read_file_location", "read_url" } end, desc = "MetaLSP: Run local tool" })

  vim.api.nvim_create_user_command("MetaLSPRecentTools", function()
    local persisted = db.tool_runs and db.tool_runs(10) or {}
    local runs = #persisted > 0 and persisted or tools.last_runs()
    local lines = { "# MetaLSP Tool Runs", "" }
    for _, r in ipairs(runs) do
      local name = r.tool_name or r.name
      lines[#lines + 1] = string.format("- `%s` %s", name or "?", os.date("%H:%M:%S", r.created_at or os.time()))
    end
    if #runs == 0 then lines[#lines + 1] = "- none" end
    show_lines_popup("MetaLSP Tools", lines)
  end, { desc = "MetaLSP: Show recent tool runs" })

  -- Show status & health check
  vim.api.nvim_create_user_command("MetaLSPStatus", function()
    local stats = db.stats()
    local cfg = config.get()
    local provider = cfg.cloud_provider or "ollama"
    local cloud_auth = require("metalsp.cloud_auth")
    local creds = cloud_auth.load_credentials()

    ollama.check_health(function(ok, models)
      vim.schedule(function()
        local active_model = "unknown"
        local auth_status = "N/A"
        if provider == "ollama" then
          active_model = cfg.ollama.model
          auth_status = "local (no auth)"
        elseif provider == "copilot" then
          active_model = cfg.copilot_model or "gpt-4o"
          local has_token = (creds.github_copilot and creds.github_copilot.ghu_token ~= nil) or false
          auth_status = has_token and "authenticated" or "NOT authenticated"
        elseif provider == "openai" then
          active_model = cfg.openai_model or "gpt-4o"
          local has_token = (creds.openai and (creds.openai.api_key ~= nil or creds.openai.access_token ~= nil or creds.openai.refresh_token ~= nil)) or false
          auth_status = has_token and "authenticated" or "NOT authenticated"
        elseif provider == "gemini" then
          active_model = cfg.gemini_model or "gemini-1.5-flash"
          local has_token = (creds.gemini and (creds.gemini.api_key ~= nil or creds.gemini.access_token ~= nil or creds.gemini.refresh_token ~= nil)) or false
          auth_status = has_token and "authenticated" or "NOT authenticated"
        end

        local lines = {
          "MetaLSP Status",
          string.rep("─", 40),
          string.format("  📊 Nodes:           %d", stats.node_count),
          string.format("  🔗 Edges:           %d", stats.edge_count),
          string.format("  📁 Files:           %d", stats.files),
          "",
          string.format("  🧠 Active Provider: %s", provider),
          string.format("  🤖 Active Model:    %s", active_model),
          string.format("  🔑 Auth Status:     %s", auth_status),
          "",
          ok
            and string.format("  ✅ Ollama Local:    reachable (%d model(s))", models and #models or 0)
            or  "  ❌ Ollama Local:    unreachable (check localhost:11434)",
          "",
          "  " .. ollama.status_string(),
        }
        if models and #models > 0 then
          lines[#lines + 1] = ""
          lines[#lines + 1] = "  Available models:"
          for _, m in ipairs(models) do
            lines[#lines + 1] = "    • " .. m
          end
        end
        -- Show in a nui Popup if available, else notify
        local ok_nui, Popup = pcall(require, "nui.popup")
        if ok_nui then
          local event = require("nui.utils.autocmd").event
          local max_w = 0
          for _, l in ipairs(lines) do if #l > max_w then max_w = #l end end
          local popup = Popup({
            position = "50%",
            size = { width = math.min(max_w + 4, 60), height = #lines + 2 },
            relative = "editor",
            border = { style = "rounded", text = { top = " 🧠 MetaLSP Status ", top_align = "center" } },
            win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder" },
          })
          popup:mount()
          vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, utils.buffer_safe_lines(lines))
          vim.bo[popup.bufnr].modifiable = false
          popup:map("n", "q", function() popup:unmount() end, { noremap = true })
          popup:map("n", "<Esc>", function() popup:unmount() end, { noremap = true })
          popup:on(event.BufLeave, function() popup:unmount() end, { once = true })
        else
          vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
        end
      end)
    end)
  end, { desc = "MetaLSP: Show status and Ollama health" })

  vim.api.nvim_create_user_command("MetaLSPGraphStats", function()
    local stats = db.stats()
    local edges = db.dump_edges()
    local by_source = {}
    for _, e in ipairs(edges) do
      by_source[e.source or "unknown"] = (by_source[e.source or "unknown"] or 0) + 1
    end
    local lines = {
      "MetaLSP Graph Stats",
      string.rep("─", 40),
      string.format("Nodes: %d", stats.node_count),
      string.format("Edges: %d", stats.edge_count),
      string.format("Files: %d", stats.files),
      "",
      "Edge sources:",
    }
    for source, count in pairs(by_source) do
      lines[#lines + 1] = string.format("  %s: %d", source, count)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "MetaLSP: Show graph stats" })

  vim.api.nvim_create_user_command("MetaLSPBadSummaries", function()
    local bad = db.bad_summaries()
    if #bad == 0 then
      utils.notify("No bad summaries found")
      return
    end
    local qf = {}
    for _, n in ipairs(bad) do
      qf[#qf + 1] = {
        filename = n.file_path,
        lnum = (n.line_start or 0) + 1,
        col = 1,
        text = utils.one_line("Bad MetaLSP summary: " .. n.name),
      }
    end
    vim.fn.setqflist(qf, "r")
    vim.fn.setqflist({}, "a", { title = "MetaLSP Bad Summaries" })
    vim.cmd("copen")
  end, { desc = "MetaLSP: List suspicious summaries" })

  -- Debug: dump DB nodes for current file
  vim.api.nvim_create_user_command("MetaLSPDebug", function()
    local root = utils.get_project_root()
    local file_path = utils.relative_path(vim.api.nvim_buf_get_name(0), root)
    local nodes = db.get_file_nodes(file_path)
    local lines = { "Nodes for: " .. file_path, string.rep("─", 50) }
    for _, n in ipairs(nodes) do
      lines[#lines + 1] = string.format("  [%s] %s (L%d-L%d) hash:%s",
        n.type, n.name, n.line_start + 1, n.line_end + 1, n.hash:sub(1, 8))
      if n.semantic_summary then
        lines[#lines + 1] = "    → " .. n.semantic_summary:sub(1, 60)
      end
    end
    if #nodes == 0 then lines[#lines + 1] = "  No nodes indexed yet. Save the file to index." end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "MetaLSP: Debug — dump DB nodes for current file" })

  -- Run DB self-test
  vim.api.nvim_create_user_command("MetaLSPTest", function()
    db.test()
  end, { desc = "MetaLSP: Self-test database" })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Autocmds
-- ═══════════════════════════════════════════════════════════════════════════

local function register_autocmds(cfg)
  local group = vim.api.nvim_create_augroup("metalsp-main", { clear = true })

  -- Index on save
  if cfg.auto_index_on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group    = group,
      callback = function(ev)
        if not ts.is_supported(ev.buf) then return end
        index_debounced(ev.buf)
      end,
    })
  end

  -- Close DB cleanly on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = group,
    callback = function() db.close() end,
  })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Keymaps
-- ═══════════════════════════════════════════════════════════════════════════

local function register_keymaps(cfg)
  local km = cfg.keymaps

  if km.index_file then
    vim.keymap.set("n", km.index_file, "<cmd>MetaLSPIndex<CR>",
      { desc = "MetaLSP: Index file", noremap = true, silent = true })
  end

  if km.index_project then
    vim.keymap.set("n", km.index_project, "<cmd>MetaLSPProjectIndex<CR>",
      { desc = "MetaLSP: Index project/current location", noremap = true, silent = true })
  end

  if km.error_fix then
    vim.keymap.set("n", km.error_fix, "<cmd>MetaLSPErrorFix<CR>",
      { desc = "MetaLSP: Analyze errors", noremap = true, silent = true })
  end

  if km.status then
    vim.keymap.set("n", km.status, "<cmd>MetaLSPStatus<CR>",
      { desc = "MetaLSP: Status", noremap = true, silent = true })
  end

  if km.summary_cursor then
    vim.keymap.set("n", km.summary_cursor, function()
      require("metalsp.features.knowledge_tree").open_cursor_summary()
    end, { desc = "MetaLSP: Open cursor summary", noremap = true, silent = true })
  end

  if km.chat then
    vim.keymap.set("n", km.chat, function()
      require("metalsp.features.knowledge_tree").open_chat()
    end, { desc = "MetaLSP: Chat", noremap = true, silent = true })
  end

  if km.explorer then
    vim.keymap.set("n", km.explorer, function()
      require("metalsp.features.knowledge_tree").open_files()
    end, { desc = "MetaLSP: Files", noremap = true, silent = true })
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Statusline
-- ═══════════════════════════════════════════════════════════════════════════

--- Return a string suitable for embedding in statusline/lualine.
--- @return string
function M.statusline()
  return require("metalsp.ui").statusline()
end

--- Return only the active provider/model, e.g. "[openai] gpt-5.5".
--- @return string
function M.model_string()
  return require("metalsp.ollama").model_string()
end

local statusline_marker = "%#MetaLSPStatusline#%{v:lua.MetaLSP_statusline()}%*"

local function setup_statusline(cfg)
  if cfg.statusline and cfg.statusline.enabled == false then return end
  _G.MetaLSP_statusline = function()
    local ok, value = pcall(function() return require("metalsp").statusline() end)
    return ok and value or ""
  end

  local function attach()
    local current = vim.o.statusline or ""
    if current:find("MetaLSP_statusline", 1, true) then return end
    if current == "" then current = "%f %h%m%r %=%-14.(%l,%c%V%) %P" end
    vim.o.statusline = current .. " %= " .. statusline_marker
  end

  attach()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("MetaLSPStatusline", { clear = true }),
    callback = function()
      pcall(vim.api.nvim_set_hl, 0, "MetaLSPStatusline", { link = "StatusLine" })
    end,
  })
  pcall(vim.api.nvim_set_hl, 0, "MetaLSPStatusline", { link = "StatusLine" })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Setup
-- ═══════════════════════════════════════════════════════════════════════════

--- Initialize MetaLSP with user configuration.
--- Call this from init.lua after plugins are loaded.
---
--- @param opts table|nil user config overrides (see metalsp.config for defaults)
function M.setup(opts)
  -- 1. Merge config and restore the latest selected provider/model.
  config.setup(opts)
  local cfg = config.get()
  apply_latest_selected_model(cfg)

  -- 2. Initialize database
  if not db.init() then
    utils.notify("Failed to initialize database. MetaLSP disabled.", vim.log.levels.ERROR)
    return
  end

  -- 3. Build debounced indexer from config
  index_debounced = utils.debounce(index_buffer, cfg.debounce.index_ms)

  -- 4. Register user commands (always available)
  register_commands()

  -- 5. Register autocmds
  register_autocmds(cfg)

  -- 6. Register global keymaps
  register_keymaps(cfg)

  -- 7. Setup statusline component
  setup_statusline(cfg)

  -- 8. Setup features (each registers its own autocmds/keymaps)
  if cfg.features.semantic_hover then
    require("metalsp.features.semantic_hover").setup(cfg.keymaps.semantic_hover)
  end

  if cfg.features.blast_radius then
    require("metalsp.features.blast_radius").setup(cfg.keymaps.blast_radius)
  end

  if cfg.features.error_translator then
    require("metalsp.features.error_translator").setup()
  end

  if cfg.features.arch_linter then
    require("metalsp.features.arch_linter").setup()
  end

  if cfg.features.sandbox_repl then
    require("metalsp.features.sandbox_repl").setup(cfg.keymaps.sandbox_repl)
  end

  if cfg.features.knowledge_tree then
    require("metalsp.features.knowledge_tree").setup(cfg.keymaps.knowledge_tree)
  end

  prune_legacy_commands()

  utils.notify("MetaLSP initialized ✓ (DB: " .. cfg.db_path .. ")")
end

return M
