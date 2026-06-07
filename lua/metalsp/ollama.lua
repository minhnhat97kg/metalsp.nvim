--- MetaLSP.nvim — Ollama Async Client
--- All LLM calls are non-blocking via vim.system + curl.
--- An internal FIFO queue prevents flooding Ollama with concurrent requests.

local M = {}

local config = require("metalsp.config")
local utils  = require("metalsp.utils")
local prompts = require("metalsp.prompts")
local cloud_auth = require("metalsp.cloud_auth")

-- ═══════════════════════════════════════════════════════════════════════════
-- Queue System
-- ═══════════════════════════════════════════════════════════════════════════

--- @class QueueItem
--- @field fn function() async job to run
--- @field label string human-readable description for status display

local queue = {}        -- FIFO queue of QueueItem
local running = 0       -- number of currently active requests
local total_queued = 0  -- total items ever queued (for stats)

--- Status for statusline
M.status = {
  queued = 0,
  active = 0,
  last_error = nil,
}

--- Drain the queue: start jobs up to max_concurrent.
local function drain()
  local cfg = config.get()
  local max = cfg.ollama.max_concurrent

  while running < max and #queue > 0 do
    local item = table.remove(queue, 1)
    running = running + 1
    M.status.active = running
    M.status.queued = #queue
    M.status.current_label = item.label

    -- Run the queued async job
    item.fn(function()
      running = running - 1
      M.status.active = running
      if running == 0 then
        M.status.current_label = nil
      end
      drain() -- trigger next item
    end)
  end
end

--- Enqueue an Ollama request job.
--- @param label string
--- @param fn function(done: function) async function, must call done() when complete
local function enqueue(label, fn)
  queue[#queue + 1] = { fn = fn, label = label }
  M.status.queued = #queue
  total_queued = total_queued + 1
  drain()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HTTP Helpers
-- ═══════════════════════════════════════════════════════════════════════════

--- Send a POST request to Ollama /api/generate and call callback with parsed response.
--- @param prompt string
--- @param system_prompt string|nil
--- @param json_mode boolean if true, forces Ollama to reply with valid JSON
--- @param callback function(result: string|nil, err: string|nil)
--- @param done function called when request completes (for queue draining)
local function get_provider_details(provider, cfg)
  local url, model, headers
  if provider == "copilot" then
    url = "https://api.githubcopilot.com/chat/completions"
    model = cfg.copilot_model or "gpt-4o"
    headers = {
      "-H", "Content-Type: application/json",
      "-H", "Copilot-Integration-Id: vscode-chat",
      "-H", "Editor-Version: Neovim/" .. (vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch),
      "-H", "Editor-Plugin-Version: MetaLSP.nvim/1.0.0",
    }
  elseif provider == "openai" then
    url = "https://api.openai.com/v1/chat/completions"
    model = cfg.openai_model or "gpt-4o"
    headers = {
      "-H", "Content-Type: application/json",
    }
  elseif provider == "gemini" then
    url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    model = cfg.gemini_model or "gemini-1.5-flash"
    headers = {
      "-H", "Content-Type: application/json",
    }
  end
  return url, model, headers
end

local function append_openai_account_header(curl_args, provider)
  if provider ~= "openai" then return end
  local ok, creds = pcall(cloud_auth.load_credentials)
  local account_id = ok and creds and creds.openai and creds.openai.account_id
  if account_id and account_id ~= "" then
    table.insert(curl_args, "-H")
    table.insert(curl_args, "OpenAI-Account-ID: " .. tostring(account_id))
    table.insert(curl_args, "-H")
    table.insert(curl_args, "chatgpt-account-id: " .. tostring(account_id))
  end
end

local function split_curl_status(stdout)
  stdout = stdout or ""
  local status = stdout:match("\n__METALSP_HTTP_STATUS__:(%d+)%s*$")
  local body = stdout:gsub("\n__METALSP_HTTP_STATUS__:%d+%s*$", "")
  return body, tonumber(status)
end

local function format_api_error(provider, status, body)
  local msg = nil
  local parsed = nil
  local ok = false
  ok, parsed = pcall(vim.json.decode, body or "")
  if ok and type(parsed) == "table" then
    if parsed.error then
      if type(parsed.error) == "table" then
        msg = parsed.error.message or vim.json.encode(parsed.error)
      else
        msg = tostring(parsed.error)
      end
    elseif parsed.detail then
      msg = tostring(parsed.detail)
    elseif parsed.message then
      msg = tostring(parsed.message)
    end
  end
  if not msg or msg == "" then
    msg = vim.trim((body or ""):sub(1, 1200))
  end
  if not msg or msg == "" then msg = "empty response" end
  return string.format("%s API error%s: %s", provider, status and (" (HTTP " .. status .. ")") or "", msg)
end

local function is_openai_codex_token(provider, token)
  return provider == "openai" and token and not token:match("^sk%-") and not token:match("^sess%-")
end

local function build_openai_codex_payload(model_name, prompt, system_prompt, stream, cfg)
  return {
    model = model_name,
    store = false,
    stream = true, -- ChatGPT/Codex backend requires streaming, even for aggregate calls.
    instructions = system_prompt and system_prompt ~= "" and system_prompt or "You are a helpful assistant.",
    input = {
      {
        type = "message",
        role = "user",
        content = { { type = "input_text", text = prompt } },
      },
    },
    text = { verbosity = "low" },
    include = { "reasoning.encrypted_content" },
    parallel_tool_calls = true,
    reasoning = { effort = "low", summary = "auto" },
  }
end

local function parse_codex_sse_text(body)
  local text = ""
  for data in (body or ""):gmatch("data:%s*([^\n]+)") do
    data = vim.trim(data)
    if data ~= "" and data ~= "[DONE]" then
      local ok, parsed = pcall(vim.json.decode, data)
      if ok and parsed then
        if parsed.type == "response.output_text.delta" then
          text = text .. (parsed.delta or "")
        elseif parsed.type == "response.output_text.done" and text == "" then
          text = parsed.text or text
        elseif parsed.type == "error" or parsed.type == "response.failed" or parsed.error then
          return nil, format_api_error("openai", nil, data)
        end
      end
    end
  end
  if text == "" then
    return nil, "openai response contained no output text"
  end
  return text, nil
end

local function openai_codex_headers()
  return {
    "-H", "content-type: application/json",
    "-H", "accept: text/event-stream",
    "-H", "OpenAI-Beta: responses=experimental",
    "-H", "originator: pi",
  }
end

--- Send a POST request to Ollama /api/generate or cloud provider chat/completions.
--- @param prompt string
--- @param system_prompt string|nil
--- @param json_mode boolean if true, forces LLM to reply with valid JSON
--- @param callback function(result: string|nil, err: string|nil)
--- @param done function called when request completes (for queue draining)
local function call_ollama(prompt, system_prompt, json_mode, callback, done)
  local cfg = config.get()
  local provider = cfg.cloud_provider or "ollama"

  if provider ~= "ollama" then
    cloud_auth.get_token(provider, function(token, auth_err)
      if auth_err or not token then
        done()
        local err = "Auth failed for " .. provider .. ": " .. tostring(auth_err)
        M.status.last_error = err
        vim.schedule(function()
          utils.notify(err, vim.log.levels.ERROR)
          callback(nil, err)
        end)
        return
      end

      local url, model_name, extra_headers = get_provider_details(provider, cfg)
      local request_payload
      local using_codex = is_openai_codex_token(provider, token)
      if using_codex then
        url = "https://chatgpt.com/backend-api/codex/responses"
        extra_headers = openai_codex_headers()
        request_payload = build_openai_codex_payload(model_name, prompt, system_prompt, true, cfg)
      else
        local messages = {}
        if system_prompt and system_prompt ~= "" then
          table.insert(messages, { role = "system", content = system_prompt })
        end
        table.insert(messages, { role = "user", content = prompt })

        request_payload = {
          model = model_name,
          messages = messages,
          temperature = cfg.ollama.temperature or 0.1,
          stream = false,
        }
        if json_mode then
          request_payload.response_format = { type = "json_object" }
        end
      end

      local payload = vim.json.encode(request_payload)
      local curl_args = {
        "curl", "-sS", "--max-time", tostring(math.floor(cfg.ollama.timeout_ms / 1000)),
        "-w", "\n__METALSP_HTTP_STATUS__:%{http_code}",
        "-X", "POST",
        url,
        "-H", "Authorization: Bearer " .. token,
      }
      for _, h in ipairs(extra_headers) do
        table.insert(curl_args, h)
      end
      append_openai_account_header(curl_args, provider)
      table.insert(curl_args, "-d")
      table.insert(curl_args, payload)

      vim.system(
        curl_args,
        { text = true },
        function(obj)
          done() -- release queue slot regardless of result

          if obj.code ~= 0 then
            local err = provider .. " request failed (exit " .. obj.code .. "): " .. (obj.stderr or "")
            M.status.last_error = err
            vim.schedule(function()
              utils.notify(err, vim.log.levels.ERROR)
              callback(nil, err)
            end)
            return
          end

          local body, status = split_curl_status(obj.stdout)
          if status and (status < 200 or status >= 300) then
            local err = format_api_error(provider, status, body)
            M.status.last_error = err
            vim.schedule(function()
              utils.notify(err, vim.log.levels.ERROR)
              callback(nil, err)
            end)
            return
          end

          if using_codex then
            local response_text, codex_err = parse_codex_sse_text(body)
            if codex_err then
              M.status.last_error = codex_err
              vim.schedule(function()
                utils.notify(codex_err, vim.log.levels.ERROR)
                callback(nil, codex_err)
              end)
              return
            end
            vim.schedule(function() callback(response_text, nil) end)
            return
          end

          local parsed, decode_err = utils.json_decode(body)
          if not parsed then
            vim.schedule(function()
              utils.notify(provider .. " payload error: " .. tostring(decode_err) .. ": " .. vim.trim((body or ""):sub(1, 500)), vim.log.levels.ERROR)
              callback(nil, decode_err)
            end)
            return
          end

          if parsed.error then
            local err = provider .. " API error: " .. tostring(parsed.error.message or parsed.error)
            M.status.last_error = err
            vim.schedule(function()
              utils.notify(err, vim.log.levels.ERROR)
              callback(nil, err)
            end)
            return
          end

          local response_text = ""
          if parsed.choices and parsed.choices[1] and parsed.choices[1].message then
            response_text = parsed.choices[1].message.content or ""
          else
            local err = provider .. " payload missing response content"
            M.status.last_error = err
            vim.schedule(function()
              utils.notify(err, vim.log.levels.ERROR)
              callback(nil, err)
            end)
            return
          end

          vim.schedule(function() callback(response_text, nil) end)
        end
      )
    end)
    return
  end

  local request_payload = {
    model  = cfg.ollama.model,
    prompt = prompt,
    system = system_prompt or "",
    stream = false,
    options = {
      temperature = cfg.ollama.temperature or 0.1,  -- Low temp for consistent structured output
      num_ctx = cfg.ollama.num_ctx or 8192,
      num_predict = cfg.ollama.num_predict or 2048,
    },
  }

  if json_mode then
    request_payload.format = "json"
  end

  local payload = vim.json.encode(request_payload)

  vim.system(
    {
      "curl", "-s", "--max-time", tostring(math.floor(cfg.ollama.timeout_ms / 1000)),
      "-X", "POST",
      cfg.ollama.endpoint .. "/api/generate",
      "-H", "Content-Type: application/json",
      "-d", payload,
    },
    { text = true },
    function(obj)
      done() -- release queue slot regardless of result

      if obj.code ~= 0 then
        local err = "Ollama request failed (exit " .. obj.code .. "): " .. (obj.stderr or "")
        M.status.last_error = err
        vim.schedule(function()
          utils.notify(err, vim.log.levels.ERROR)
          callback(nil, err)
        end)
        return
      end

      local parsed, decode_err = utils.json_decode(obj.stdout)
      if not parsed then
        vim.schedule(function()
          utils.notify("Ollama payload error: " .. tostring(decode_err), vim.log.levels.ERROR)
          callback(nil, decode_err)
        end)
        return
      end

      if parsed.error then
        local err = "Ollama API error: " .. tostring(parsed.error)
        M.status.last_error = err
        vim.schedule(function()
          utils.notify(err, vim.log.levels.ERROR)
          callback(nil, err)
        end)
        return
      end

      if parsed.response == nil then
        local err = "Ollama payload missing response"
        M.status.last_error = err
        vim.schedule(function()
          utils.notify(err, vim.log.levels.ERROR)
          callback(nil, err)
        end)
        return
      end

      vim.schedule(function() callback(parsed.response, nil) end)
    end
  )
end

local function call_ollama_stream(prompt, system_prompt, callback, done)
  local cfg = config.get()
  local provider = cfg.cloud_provider or "ollama"

  if provider ~= "ollama" then
    cloud_auth.get_token(provider, function(token, auth_err)
      if auth_err or not token then
        done()
        local err = "Auth failed for " .. provider .. ": " .. tostring(auth_err)
        vim.schedule(function()
          utils.notify(err, vim.log.levels.ERROR)
          callback(nil, true, err)
        end)
        return
      end

      local url, model_name, extra_headers = get_provider_details(provider, cfg)
      local request_payload
      local using_codex = is_openai_codex_token(provider, token)
      if using_codex then
        url = "https://chatgpt.com/backend-api/codex/responses"
        extra_headers = openai_codex_headers()
        request_payload = build_openai_codex_payload(model_name, prompt, system_prompt, true, cfg)
      else
        local messages = {}
        if system_prompt and system_prompt ~= "" then
          table.insert(messages, { role = "system", content = system_prompt })
        end
        table.insert(messages, { role = "user", content = prompt })

        request_payload = {
          model = model_name,
          messages = messages,
          temperature = cfg.ollama.temperature or 0.1,
          stream = true,
        }
      end

      local payload = vim.json.encode(request_payload)
      local curl_args = {
        "curl", "-sS", "-N", "--max-time", tostring(math.floor(cfg.ollama.timeout_ms / 1000)),
        "-w", "\n__METALSP_HTTP_STATUS__:%{http_code}",
        "-X", "POST",
        url,
        "-H", "Authorization: Bearer " .. token,
      }
      for _, h in ipairs(extra_headers) do
        table.insert(curl_args, h)
      end
      append_openai_account_header(curl_args, provider)
      table.insert(curl_args, "-d")
      table.insert(curl_args, payload)

      local buffer = ""
      local saw_chunk = false
      local api_error = nil
      vim.system(
        curl_args,
        {
          stdout = function(err, data)
            if err then
              vim.schedule(function() callback(nil, true, err) end)
              return
            end
            if not data then return end

            buffer = buffer .. data
            while true do
              local newline_idx = buffer:find("\n")
              if not newline_idx then break end
              local line = buffer:sub(1, newline_idx - 1)
              buffer = buffer:sub(newline_idx + 1)

              line = vim.trim(line)
              if line ~= "" then
                if line:sub(1, 5) == "data:" then
                  local data_str = vim.trim(line:sub(6))
                  if data_str == "[DONE]" then
                    vim.schedule(function() callback("", true, nil) end)
                  else
                    local ok, parsed = pcall(vim.json.decode, data_str)
                    if ok and parsed and parsed.error then
                      api_error = format_api_error(provider, nil, data_str)
                    elseif ok and parsed and (parsed.type == "error" or parsed.type == "response.failed") then
                      api_error = format_api_error(provider, nil, data_str)
                    elseif using_codex and ok and parsed and parsed.type == "response.output_text.delta" then
                      local chunk = parsed.delta or ""
                      if chunk ~= "" then saw_chunk = true end
                      vim.schedule(function() callback(chunk, false, nil) end)
                    elseif using_codex and ok and parsed and (parsed.type == "response.completed" or parsed.type == "response.done") then
                      vim.schedule(function() callback("", true, nil) end)
                    elseif ok and parsed and parsed.choices and parsed.choices[1] then
                      local delta = parsed.choices[1].delta or {}
                      local chunk = delta.content or ""
                      if chunk ~= "" then saw_chunk = true end
                      local is_done = (parsed.choices[1].finish_reason ~= nil)
                      vim.schedule(function() callback(chunk, is_done, nil) end)
                    end
                  end
                else
                  -- Fallback to plain JSON line parsing
                  local ok, parsed = pcall(vim.json.decode, line)
                  if line:match("^__METALSP_HTTP_STATUS__:%d+") then
                    buffer = line .. "\n" .. buffer
                    break
                  elseif ok and parsed and parsed.error then
                    api_error = format_api_error(provider, nil, line)
                  elseif ok and parsed and (parsed.type == "error" or parsed.type == "response.failed") then
                    api_error = format_api_error(provider, nil, line)
                  elseif using_codex and ok and parsed and parsed.type == "response.output_text.delta" then
                    local chunk = parsed.delta or ""
                    if chunk ~= "" then saw_chunk = true end
                    vim.schedule(function() callback(chunk, false, nil) end)
                  elseif using_codex and ok and parsed and (parsed.type == "response.completed" or parsed.type == "response.done") then
                    vim.schedule(function() callback("", true, nil) end)
                  elseif ok and parsed and parsed.choices and parsed.choices[1] then
                    local delta = parsed.choices[1].delta or {}
                    local chunk = delta.content or ""
                    if chunk ~= "" then saw_chunk = true end
                    local is_done = (parsed.choices[1].finish_reason ~= nil)
                    vim.schedule(function() callback(chunk, is_done, nil) end)
                  end
                end
              end
            end
          end
        },
        function(obj)
          done() -- release queue slot

          local final_body, status = split_curl_status(buffer)
          if api_error then
            M.status.last_error = api_error
            vim.schedule(function()
              utils.notify(api_error, vim.log.levels.ERROR)
              callback(nil, true, api_error)
            end)
            return
          end

          if status and (status < 200 or status >= 300) then
            local err = format_api_error(provider, status, final_body ~= "" and final_body or buffer)
            M.status.last_error = err
            vim.schedule(function()
              utils.notify(err, vim.log.levels.ERROR)
              callback(nil, true, err)
            end)
            return
          end

          if final_body ~= "" then
            local line = vim.trim(final_body)
            if line:sub(1, 5) == "data:" then
              local data_str = vim.trim(line:sub(6))
              if data_str ~= "[DONE]" then
                local ok, parsed = pcall(vim.json.decode, data_str)
                if ok and parsed and parsed.error then
                  local err = format_api_error(provider, status, data_str)
                  M.status.last_error = err
                  vim.schedule(function() utils.notify(err, vim.log.levels.ERROR); callback(nil, true, err) end)
                  return
                elseif ok and parsed and parsed.choices and parsed.choices[1] then
                  local delta = parsed.choices[1].delta or {}
                  vim.schedule(function() callback(delta.content or "", true, nil) end)
                  return
                end
              end
            else
              local ok, parsed = pcall(vim.json.decode, line)
              if ok and parsed and parsed.error then
                local err = format_api_error(provider, status, line)
                M.status.last_error = err
                vim.schedule(function() utils.notify(err, vim.log.levels.ERROR); callback(nil, true, err) end)
                return
              end
            end
          end

          if obj.code ~= 0 then
            local exit_err = provider .. " request failed (exit " .. obj.code .. "): " .. (obj.stderr or "")
            M.status.last_error = exit_err
            vim.schedule(function() utils.notify(exit_err, vim.log.levels.ERROR); callback(nil, true, exit_err) end)
          elseif not saw_chunk and status == nil then
            local err = provider .. " request finished without response data"
            M.status.last_error = err
            vim.schedule(function() utils.notify(err, vim.log.levels.ERROR); callback(nil, true, err) end)
          else
            vim.schedule(function() callback("", true, nil) end)
          end
        end
      )
    end)
    return
  end

  local request_payload = {
    model  = cfg.ollama.model,
    prompt = prompt,
    system = system_prompt or "",
    stream = true,
    options = {
      temperature = cfg.ollama.temperature or 0.1,
      num_ctx = cfg.ollama.num_ctx or 8192,
      num_predict = cfg.ollama.num_predict or 2048,
    },
  }

  local payload = vim.json.encode(request_payload)
  local buffer = ""

  vim.system(
    {
      "curl", "-s", "-N", "--max-time", tostring(math.floor(cfg.ollama.timeout_ms / 1000)),
      "-X", "POST",
      cfg.ollama.endpoint .. "/api/generate",
      "-H", "Content-Type: application/json",
      "-d", payload,
    },
    {
      stdout = function(err, data)
        if err then
          vim.schedule(function() callback(nil, true, err) end)
          return
        end
        if not data then return end

        buffer = buffer .. data
        while true do
          local newline_idx = buffer:find("\n")
          if not newline_idx then break end
          local line = buffer:sub(1, newline_idx - 1)
          buffer = buffer:sub(newline_idx + 1)

          line = vim.trim(line)
          if line ~= "" then
            local ok, parsed = pcall(vim.json.decode, line)
            if ok and parsed and parsed.response then
              local chunk = parsed.response
              local is_done = parsed.done or false
              vim.schedule(function() callback(chunk, is_done, nil) end)
            elseif ok and parsed and parsed.error then
              local api_err = "Ollama API error: " .. tostring(parsed.error)
              vim.schedule(function() callback(nil, true, api_err) end)
            end
          end
        end
      end
    },
    function(obj)
      done() -- release queue slot

      if buffer ~= "" then
        local line = vim.trim(buffer)
        local ok, parsed = pcall(vim.json.decode, line)
        if ok and parsed and parsed.response then
          vim.schedule(function() callback(parsed.response, parsed.done or false, nil) end)
        end
      end

      if obj.code ~= 0 then
        local exit_err = "Ollama request failed (exit " .. obj.code .. "): " .. (obj.stderr or "")
        vim.schedule(function() callback(nil, true, exit_err) end)
      else
        vim.schedule(function() callback("", true, nil) end)
      end
    end
  )
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════════════════════

local pending_analyses = {}

local function trim(s)
  return tostring(s or ""):gsub("^%s*", ""):gsub("%s*$", "")
end

local function render_template(template, ctx)
  if type(template) == "function" then
    return template(ctx or {})
  end
  local out = tostring(template or "")
  for key, value in pairs(ctx or {}) do
    out = out:gsub("{{%s*" .. key .. "%s*}}", tostring(value or ""))
  end
  return out
end

local function prompt(name, ctx)
  return prompts.render(name, ctx)
end

local function looks_like_refusal(text)
  text = tostring(text or ""):lower()
  return text:find("can't assist", 1, true)
      or text:find("cannot assist", 1, true)
      or text:find("i'm sorry", 1, true)
      or text:find("i am sorry", 1, true)
      or text:find("can't help", 1, true)
end

local function unwrap_nested_response(parsed)
  if type(parsed) == "table" and type(parsed.response) == "string" then
    local nested = utils.json_decode(parsed.response)
    if type(nested) == "table" then return nested end
  end
  return parsed
end

--- Analyze a function and return semantic_summary + side_effects as JSON.
---
--- @param sym table { id, name, type, raw_code, hash? }
--- @param callback function(summary: string, side_effects: string, err: string|nil, thinking: string|nil)
function M.analyze_function(sym, callback)
  local pending_key = sym.id and (sym.id .. ":" .. tostring(sym.hash or "no-hash")) or nil
  if pending_key and pending_analyses[pending_key] then
    -- Already enqueued or running for this exact code hash.
    return
  end
  if pending_key then
    pending_analyses[pending_key] = true
  end

  local max_code_chars = config.get().ollama.max_code_chars or 24000
  local raw_code = sym.raw_code or ""
  if #raw_code > max_code_chars then
    raw_code = raw_code:sub(1, max_code_chars) .. "\n\n/* MetaLSP: code truncated to fit model context */"
  end

  local notes = trim(sym.notes or sym.docs or "")
  if notes ~= "" then
    raw_code = raw_code .. "\n\n/* MetaLSP function notes / docs for accuracy:\n" .. notes .. "\n*/"
  end

  local ctx = {
    type = sym.type or "unknown",
    name = sym.name or "unknown",
    code = raw_code,
    notes = notes,
    docs = trim(sym.docs or ""),
  }
  local system_prompt = prompt("analyze_system", ctx)
  local prompt_text = prompt("analyze_user", ctx)

  enqueue("analyze:" .. sym.name, function(done)
    vim.schedule(function()
      print("[MetaLSP] Summary: Analyzing " .. sym.name .. "...")
    end)
    call_ollama(prompt_text, system_prompt, true, function(response, err)
      if pending_key then
        pending_analyses[pending_key] = nil
      end

      if err or not response then
        vim.schedule(function()
          print("[MetaLSP] Summary: Error analyzing " .. sym.name .. ": " .. tostring(err))
        end)
        callback(nil, nil, err, nil)
        return
      end

      -- Extract native <think> process if present (from reasoning models like deepseek-r1)
      local native_thinking = nil
      local think_start, think_end = response:find("<think>")
      local think_close_start, think_close_end = response:find("</think>")
      if think_start and think_close_start then
        native_thinking = response:sub(think_end + 1, think_close_start - 1):gsub("^%s*(.-)%s*$", "%1")
        response = response:sub(1, think_start - 1) .. response:sub(think_close_end + 1)
      end

      local parsed, parse_err = utils.json_decode(response)
      local summary = ""
      local side_effects_json = "[]"
      local final_thinking = native_thinking or ""

      if not parsed then
        -- Try to extract JSON from markdown block
        local json_block = response:match("```[jJ][sS][oO][nN]%s*(.-)%s*```") or response:match("```%s*({.-})%s*```")
        if json_block then
          parsed, parse_err = utils.json_decode(json_block)
        end
      end

      parsed = unwrap_nested_response(parsed)

      if parsed and type(parsed) == "table" then
        summary = parsed.semantic_summary
          or parsed.semanticSummary
          or parsed.summary
          or parsed.description
          or parsed.purpose
          or parsed.analysis
          or parsed.result
          or parsed.response
          or ""
        side_effects_json = vim.json.encode(parsed.side_effects or parsed.sideEffects or {})
        local flow = parsed.flow_steps or parsed.flowSteps or parsed.steps
        if type(flow) == "table" then
          local lines = {}
          for i, step in ipairs(flow) do
            lines[#lines + 1] = string.format("%d. %s", i, tostring(step))
          end
          flow = table.concat(lines, "\n")
        end
        if parsed.thinking or parsed.reasoning or parsed.notes or flow then
          final_thinking = trim(final_thinking .. "\n" .. (flow or parsed.thinking or parsed.reasoning or parsed.notes))
        end
      else
        -- Fallback: The model didn't return JSON, it just returned plain text.
        summary = trim(response)
      end

      summary = trim(summary)
      if summary == "" then
        callback(nil, nil, "Empty response", nil)
        return
      end

      -- Do not persist model refusals or Ollama envelope JSON as a semantic summary.
      -- Keeping the DB empty allows `s` re-summary to try again with a better prompt/model.
      if looks_like_refusal(summary) then
        callback(nil, nil, "Model refused to summarize this code", nil)
        return
      end

      local envelope = utils.json_decode(summary)
      if type(envelope) == "table" and type(envelope.response) == "string" then
        local unwrapped = trim(envelope.response)
        if looks_like_refusal(unwrapped) then
          callback(nil, nil, "Model refused to summarize this code", nil)
          return
        end
        summary = unwrapped
      end

      vim.schedule(function()
        print("[MetaLSP] Summary: Analyzed " .. sym.name)
      end)
      callback(summary, side_effects_json, nil, final_thinking)
    end, done)
  end)
end

--- Translate an LSP error into plain-language root cause analysis.
---
--- @param error_msg string raw LSP error message
--- @param code_context string surrounding source code
--- @param callback function(translation: string|nil, err: string|nil)
function M.translate_error(error_msg, code_context, callback)
  local ctx = { error = error_msg, context = code_context }
  local system_prompt = prompt("error_system", ctx)
  local prompt_text = prompt("error_user", ctx)

  enqueue("error:" .. error_msg:sub(1, 30), function(done)
    vim.schedule(function()
      print("[MetaLSP] Explaining error...")
    end)
    call_ollama(prompt_text, system_prompt, true, function(response, err)
      if err or not response then
        callback(nil, err)
        return
      end

      local parsed, _ = utils.json_decode(response)
      if parsed then
        local text = (parsed.root_cause or "") .. "\n\n💡 Fix: " .. (parsed.fix_suggestion or "")
        callback(text, nil)
      else
        -- Fallback: return raw response if JSON parse fails
        callback(response, nil)
      end
    end, done)
  end)
end

--- Check code against architecture rules and return violations.
---
--- @param code string buffer code to check
--- @param rules_text string markdown rules from .meta-rules.md
--- @param callback function(violations: table[]|nil, err: string|nil)
function M.check_arch_rules(code, rules_text, callback)
  local ctx = { rules = rules_text, code = code:sub(1, 4000) }
  local system_prompt = prompt("arch_system", ctx)
  local prompt_text = prompt("arch_user", ctx)

  enqueue("arch-lint", function(done)
    vim.schedule(function()
      print("[MetaLSP] Running architecture lint...")
    end)
    call_ollama(prompt_text, system_prompt, true, function(response, err)
      if err or not response then
        callback(nil, err)
        return
      end

      local parsed, _ = utils.json_decode(response)
      if type(parsed) == "table" then
        callback(parsed, nil)
      else
        callback({}, nil)
      end
    end, done)
  end)
end

--- Generate a sandbox test harness for a function.
---
--- @param func_name string
--- @param func_body string source code of the function
--- @param lang string "go"|"typescript"|"lua"
--- @param callback function(sandbox_code: string|nil, err: string|nil)
function M.generate_sandbox(func_name, func_body, lang, callback)
  local extensions = { go = "go", typescript = "ts", javascript = "js", lua = "lua" }
  local ext = extensions[lang] or "txt"

  local ctx = { language = lang, func_name = func_name, func_body = func_body }
  local system_prompt = prompt("sandbox_system", ctx)
  local prompt_text = prompt("sandbox_user", ctx)

  enqueue("sandbox:" .. func_name, function(done)
    vim.schedule(function()
      print("[MetaLSP] Generating sandbox for " .. func_name .. "...")
    end)
    call_ollama(prompt_text, system_prompt, false, function(response, err)
      callback(response, err)
    end, done)
  end)
end

--- Ask a question using a compact knowledge-graph context.
--- @param context string
--- @param question string
--- @param callback function(answer: string|nil, err: string|nil)
--- @param on_chunk function(chunk: string)|nil
function M.ask_with_context(context, question, callback, on_chunk)
  local ctx = { context = context or "", question = question or "" }
  local system_prompt = prompt("ask_system", ctx)
  local prompt_text = prompt("ask_user", ctx)

  enqueue("ask-knowledge", function(done)
    local accumulated = ""
    local done_called = false
    call_ollama_stream(prompt_text, system_prompt, function(chunk, is_done, err)
      if done_called then return end
      if err then
        done_called = true
        callback(nil, err)
        return
      end
      if chunk and chunk ~= "" then
        accumulated = accumulated .. chunk
        if on_chunk then
          on_chunk(chunk)
        end
      end
      if is_done then
        done_called = true
        callback(trim(accumulated), nil)
      end
    end, done)
  end)
end

--- Check if Ollama is reachable.
--- @param callback function(ok: boolean, model: string|nil)
function M.check_health(callback)
  local cfg = config.get()
  vim.system(
    { "curl", "-s", "--max-time", "3", cfg.ollama.endpoint .. "/api/tags" },
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          callback(false, nil)
          return
        end
        local parsed, _ = utils.json_decode(obj.stdout)
        local model_names = {}
        if parsed and parsed.models then
          for _, m in ipairs(parsed.models) do
            model_names[#model_names + 1] = m.name
          end
        end
        callback(true, model_names)
      end)
    end
  )
end

local function status_icon()
  local cfg = config.get()
  if cfg.statusline and cfg.statusline.use_devicons == false then
    return "🧠"
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok and devicons then
    local icon = devicons.get_icon("metalsp.lua", "lua", { default = true })
    if icon and icon ~= "" then return icon end
  end
  return "🧠"
end

local function active_model_label()
  local cfg = config.get()
  local provider = cfg.cloud_provider or "ollama"
  local model = "unknown"
  if provider == "ollama" then
    model = cfg.ollama and cfg.ollama.model or model
  elseif provider == "copilot" then
    model = cfg.copilot_model or model
  elseif provider == "openai" then
    model = cfg.openai_model or model
  elseif provider == "gemini" then
    model = cfg.gemini_model or model
  end
  return string.format("[%s] %s", provider, model)
end

--- Get active provider/model summary string.
--- @return string
function M.model_string()
  return active_model_label()
end

--- Get queue status summary string (for statusline).
--- @return string
function M.status_string()
  local model = active_model_label()
  if M.status.active > 0 then
    local label = M.status.current_label or "analyzing"
    local clean_label = label:gsub("^analyze:", "Analyzing "):gsub("^error:.*", "Explaining error"):gsub("^sandbox:", "Generating sandbox for ")
    return string.format("%s MetaLSP %s: %s... (%d queued)", status_icon(), model, clean_label, M.status.queued)
  elseif M.status.queued > 0 then
    return string.format("%s MetaLSP %s: %d queued", status_icon(), model, M.status.queued)
  elseif M.status.last_error then
    return string.format("%s MetaLSP %s: Error (%s)", status_icon(), model, M.status.last_error:sub(1, 30))
  else
    return string.format("%s MetaLSP %s: ready", status_icon(), model)
  end
end

return M
