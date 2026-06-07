--- MetaLSP.nvim — Cloud Authentication Manager
--- Handles OAuth device flows, API key storage, and token refreshes.

local M = {}

local utils = require("metalsp.utils")
local uv = vim.uv or vim.loop

local CREDENTIALS_FILE = vim.fn.stdpath("data") .. "/metalsp_credentials.json"
local COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98"

local OAUTH_PORT = 1455
local OAUTH_CALLBACK_PATH = "/auth/callback"
local OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local OPENAI_AUTH_URL = "https://auth.openai.com/oauth/authorize"
local OPENAI_TOKEN_URL = "https://auth.openai.com/oauth/token"
local GEMINI_CLIENT_ID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
local GEMINI_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
local GEMINI_TOKEN_URL = "https://oauth2.googleapis.com/token"

local function gemini_client_secret()
  return vim.env.GEMINI_CLIENT_SECRET or vim.g.metalsp_gemini_client_secret
end

local function urlencode(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function base64_encode(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((data:gsub('.', function(x) 
    local r,b_val='',x:byte()
    for i=8,1,-1 do r=r..(b_val%2^i-b_val%2^(i-1)>0 and '1' or '0') end
    return r;
  end)..'0000'):gsub('%d%d%d%d%d%d', function(x)
    if #x<6 then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return b:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

local function base64url_encode(data)
  local enc = base64_encode(data)
  enc = enc:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
  return enc
end

local function base64_decode(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  data = tostring(data or ""):gsub("[^" .. b .. "=]", "")
  return (data:gsub('.', function(x)
    if x == '=' then return '' end
    local r, f = '', (b:find(x, 1, true) or 1) - 1
    for i = 6, 1, -1 do
      r = r .. (f % 2^i - f % 2^(i - 1) > 0 and '1' or '0')
    end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == '1' and 2^(8 - i) or 0)
    end
    return string.char(c)
  end))
end

local function base64url_decode(data)
  data = tostring(data or ""):gsub("-", "+"):gsub("_", "/")
  local pad = #data % 4
  if pad > 0 then
    data = data .. string.rep("=", 4 - pad)
  end
  return base64_decode(data)
end

-- Lua equivalent of JS URLSearchParams / application/x-www-form-urlencoded.
-- Notably: spaces become '+', and '~' is percent-encoded.
local function form_urlencode(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("([^%w%*%-%._ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  str = str:gsub("~", "%%7E")
  str = str:gsub(" ", "+")
  return str
end

local function urlsearchparams(params)
  local parts = {}
  for _, pair in ipairs(params) do
    parts[#parts + 1] = form_urlencode(pair[1]) .. "=" .. form_urlencode(pair[2])
  end
  return table.concat(parts, "&")
end

local function post_form_urlencoded(url, params, callback)
  local node = vim.fn.exepath("node")
  if node and node ~= "" then
    local script = [[
const fs = require('node:fs');
(async () => {
  try {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const body = new URLSearchParams();
    for (const pair of input.params) body.append(String(pair[0]), String(pair[1] ?? ''));
    const response = await fetch(input.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    process.stdout.write(await response.text());
  } catch (error) {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  }
})();
]]
    vim.system(
      { node, "-e", script },
      { text = true, stdin = vim.json.encode({ url = url, params = params }) },
      callback
    )
    return
  end

  vim.system(
    {
      "curl", "-s", "-X", "POST",
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "-d", urlsearchparams(params),
      url,
    },
    { text = true },
    callback
  )
end

local function jwt_payload(jwt)
  if type(jwt) ~= "string" then return nil end
  local payload = jwt:match("^[^.]+%.([^.]+)%.")
  if not payload then return nil end
  local ok, decoded = pcall(vim.json.decode, base64url_decode(payload))
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

local function extract_openai_account_id(id_token)
  local payload = jwt_payload(id_token)
  local claim = payload and payload["https://api.openai.com/auth"]
  if type(claim) == "table" then
    return claim.chatgpt_account_id or claim.account_id or claim.accountId or claim.account or claim.id or claim.organization_id or claim.organizationId
  elseif type(claim) == "string" then
    return claim
  end
  return nil
end

local function hex_to_binary(hex)
  return (hex:gsub('..', function (cc)
    return string.char(tonumber(cc, 16))
  end))
end

local function random_bytes(length)
  local f = io.open("/dev/urandom", "rb")
  if f then
    local data = f:read(length)
    f:close()
    if data and #data == length then return data end
  end

  -- Fallback for platforms without /dev/urandom.
  local bytes = {}
  math.randomseed(os.time() + (uv.hrtime or function() return 0 end)())
  for i = 1, length do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

local function bytes_to_hex(data)
  return (data:gsub('.', function(c)
    return string.format('%02x', string.byte(c))
  end))
end

local function generate_code_verifier()
  -- Match Pi/OpenCode: 32 random bytes encoded as base64url (43 chars).
  return base64url_encode(random_bytes(32))
end

local function generate_state()
  -- Match Pi/OpenCode: randomBytes(16).toString("hex").
  return bytes_to_hex(random_bytes(16))
end

local function generate_code_challenge(verifier)
  local hex = vim.fn.sha256(verifier)
  local binary = hex_to_binary(hex)
  return base64url_encode(binary)
end

-- Helper to open URL in default browser
local function open_url(url)
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
  elseif vim.fn.has("mac") == 1 then
    vim.system({ "open", url })
  elseif vim.fn.has("unix") == 1 then
    vim.system({ "xdg-open", url })
  elseif vim.fn.has("win32") == 1 then
    vim.system({ "cmd.exe", "/c", "start", url })
  end
end

-- Read hosts.json from standard GitHub Copilot plugins location as fallback
local function read_copilot_hosts_json()
  local home = vim.fn.expand("$HOME")
  local path
  if vim.fn.has("win32") == 1 then
    local appdata = vim.fn.expand("$APPDATA")
    path = appdata .. "/github-copilot/hosts.json"
  else
    path = home .. "/.config/github-copilot/hosts.json"
  end

  if vim.fn.filereadable(path) == 1 then
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and decoded then
        -- Format is typically: { "github.com": { "oauth_token": "ghu_..." } }
        for host, data in pairs(decoded) do
          if host:find("github.com") and data.oauth_token then
            return data.oauth_token
          end
        end
      end
    end
  end
  return nil
end

--- Load credentials from storage
--- @return table
function M.load_credentials()
  if vim.fn.filereadable(CREDENTIALS_FILE) == 0 then
    return {}
  end
  local f = io.open(CREDENTIALS_FILE, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return {}
end

--- Save credentials to storage
--- @param creds table
function M.save_credentials(creds)
  local f = io.open(CREDENTIALS_FILE, "w")
  if f then
    f:write(vim.json.encode(creds))
    f:close()
    -- Set permissions to read/write only by owner
    pcall(vim.fn.setfperm, CREDENTIALS_FILE, "rw-------")
  end
end

--- Exchange Copilot ghu_token for session_token
--- @param ghu_token string
--- @param callback function(token: string|nil, err: string|nil)
function M.refresh_copilot_session(ghu_token, callback)
  vim.system(
    {
      "curl", "-s",
      "-H", "Authorization: token " .. ghu_token,
      "-H", "Accept: application/json",
      "-H", "Editor-Version: Neovim/" .. (vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch),
      "-H", "Editor-Plugin-Version: MetaLSP.nvim/1.0.0",
      "https://api.github.com/copilot_internal/v2/token"
    },
    { text = true },
    function(obj)
      if obj.code ~= 0 then
        vim.schedule(function() callback(nil, "Curl error " .. obj.code .. ": " .. (obj.stderr or "")) end)
        return
      end

      local ok, res = pcall(vim.json.decode, obj.stdout)
      if not ok or not res or type(res) ~= "table" then
        vim.schedule(function() callback(nil, "Invalid JSON from Copilot token exchange: " .. tostring(obj.stdout)) end)
        return
      end

      if res.error then
        vim.schedule(function() callback(nil, "API error: " .. tostring(res.error)) end)
        return
      end

      if not res.token then
        vim.schedule(function() callback(nil, "No token in response") end)
        return
      end

      vim.schedule(function() callback(res.token, nil) end)
    end
  )
end

--- Refresh an OAuth access token for OpenAI or Gemini.
local function refresh_oauth_token(provider, refresh_token, callback)
  local params
  local token_url
  if provider == "openai" then
    token_url = OPENAI_TOKEN_URL
    params = {
      { "grant_type", "refresh_token" },
      { "refresh_token", refresh_token },
      { "client_id", OPENAI_CLIENT_ID },
    }
  elseif provider == "gemini" then
    local client_secret = gemini_client_secret()
    if not client_secret or client_secret == "" then
      callback(nil, "Gemini OAuth requires GEMINI_CLIENT_SECRET")
      return
    end
    token_url = GEMINI_TOKEN_URL
    params = {
      { "client_id", GEMINI_CLIENT_ID },
      { "client_secret", client_secret },
      { "grant_type", "refresh_token" },
      { "refresh_token", refresh_token },
    }
  else
    callback(nil, "Unsupported OAuth provider: " .. tostring(provider))
    return
  end

  post_form_urlencoded(token_url, params, function(obj)
      if obj.code ~= 0 then
        vim.schedule(function() callback(nil, "Refresh failed (token request exit code " .. obj.code .. "): " .. (obj.stderr or "")) end)
        return
      end

      local ok, res = pcall(vim.json.decode, obj.stdout)
      if ok and res and res.access_token then
        vim.schedule(function()
          local creds = M.load_credentials()
          creds[provider] = creds[provider] or {}
          creds[provider].access_token = res.access_token
          if res.refresh_token then
            creds[provider].refresh_token = res.refresh_token
          end
          if provider == "openai" then
            if res.id_token then
              creds[provider].id_token = res.id_token
            end
            creds[provider].account_id = extract_openai_account_id(res.access_token) or extract_openai_account_id(res.id_token) or creds[provider].account_id
          end
          creds[provider].expires_at = os.time() + (res.expires_in or 3600)
          M.save_credentials(creds)
          callback(res.access_token, nil)
        end)
      else
        local err_desc = (res and (res.error_description or res.error)) or "Failed to refresh token."
        vim.schedule(function() callback(nil, err_desc) end)
      end
    end
  )
end

--- Get authenticated token for a provider.
--- For Copilot, handles internal session token refresh automatically.
--- @param provider string "copilot"|"openai"|"gemini"
--- @param callback function(token: string|nil, err: string|nil)
function M.get_token(provider, callback)
  local creds = M.load_credentials()

  if provider == "openai" then
    local op = creds.openai or {}
    
    -- If we have OAuth credentials
    if type(op) == "table" and (op.access_token or op.refresh_token) then
      local now = os.time()
      if op.access_token and op.expires_at and (op.expires_at - now > 300) then
        callback(op.access_token, nil)
        return
      end

      if op.refresh_token then
        refresh_oauth_token("openai", op.refresh_token, function(new_token, err)
          if err then
            callback(nil, "Failed to refresh ChatGPT session: " .. tostring(err))
          else
            callback(new_token, nil)
          end
        end)
        return
      end
    end

    -- Fallback to standard API Key
    local key = (type(creds.openai) == "table" and creds.openai.api_key) or os.getenv("OPENAI_API_KEY")
    if key and key ~= "" then
      callback(key, nil)
    else
      callback(nil, "ChatGPT authentication not found. Please log in via :MetaLSPLogin openai")
    end
    return
  elseif provider == "gemini" then
    local gm = creds.gemini or {}

    if type(gm) == "table" and (gm.access_token or gm.refresh_token) then
      local now = os.time()
      if gm.access_token and gm.expires_at and (gm.expires_at - now > 300) then
        callback(gm.access_token, nil)
        return
      end

      if gm.refresh_token then
        refresh_oauth_token("gemini", gm.refresh_token, function(new_token, err)
          if err then
            callback(nil, "Failed to refresh Gemini session: " .. tostring(err))
          else
            callback(new_token, nil)
          end
        end)
        return
      end
    end

    local key = (type(creds.gemini) == "table" and creds.gemini.api_key) or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if key and key ~= "" then
      callback(key, nil)
    else
      callback(nil, "Gemini authentication not found. Please log in via :MetaLSPLogin gemini")
    end
    return
  elseif provider == "copilot" then
    local cop = creds.github_copilot or {}
    local ghu = cop.ghu_token or read_copilot_hosts_json()

    if not ghu or ghu == "" then
      callback(nil, "GitHub Copilot credentials not found. Please log in via :MetaLSPLogin copilot")
      return
    end

    -- If we have a cached session token that is still valid for > 5 mins
    local now = os.time()
    if cop.session_token and cop.expires_at and (cop.expires_at - now > 300) then
      callback(cop.session_token, nil)
      return
    end

    -- Refresh the session token
    M.refresh_copilot_session(ghu, function(session_token, err)
      if err then
        callback(nil, "Failed to refresh Copilot session: " .. tostring(err))
        return
      end

      -- Update cached session token (usually valid for 25-30 minutes)
      local new_creds = M.load_credentials()
      new_creds.github_copilot = new_creds.github_copilot or {}
      new_creds.github_copilot.ghu_token = ghu
      new_creds.github_copilot.session_token = session_token
      new_creds.github_copilot.expires_at = os.time() + 1500 -- Safely cache for 25 mins
      M.save_credentials(new_creds)

      callback(session_token, nil)
    end)
    return
  end

  callback(nil, "Unknown provider: " .. tostring(provider))
end

local function prompt_key(title, prompt_text, callback)
  local ok_nui, Input = pcall(require, "nui.input")
  if ok_nui then
    local event = require("nui.utils.autocmd").event
    local input = Input({
      position = "50%",
      size = {
        width = 60,
        height = 1,
      },
      border = {
        style = "rounded",
        text = {
          top = " " .. title .. " ",
          top_align = "center",
        },
      },
      win_options = {
        winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      },
    }, {
      prompt = "🔑 " .. prompt_text,
      default_value = "",
      on_close = function()
        callback(nil)
      end,
      on_submit = function(value)
        callback(vim.trim(value))
      end,
    })
    input:mount()
    input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
    input:map("n", "q", function() input:unmount() end, { noremap = true })
    input:on(event.BufLeave, function() input:unmount() end, { once = true })
  else
    vim.ui.input({ prompt = title .. " - " .. prompt_text }, callback)
  end
end

local function show_copilot_login_popup(user_code, expires_in)
  local ok_nui, Popup = pcall(require, "nui.popup")
  if not ok_nui then return nil end

  local lines = {
    "  GitHub Copilot Authentication",
    "  ───────────────────────────────",
    "  1. Copy code: " .. user_code .. " (copied to clipboard!)",
    "  2. Browser opened at: https://github.com/login/device",
    "",
    "  ⏳ Waiting for GitHub authorization...",
    "     (Expires in " .. math.floor(expires_in / 60) .. " minutes)",
  }

  local popup = Popup({
    position = "50%",
    size = {
      width = 58,
      height = 8,
    },
    enter = false,
    focusable = false,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = " 🧠 GitHub Copilot Login ",
        top_align = "center",
      },
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
  })

  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  return popup
end

--- Log in to GitHub Copilot using OAuth Device Flow
--- @param callback function(success: boolean, err: string|nil)
function M.login_copilot(callback)
  utils.notify("Requesting GitHub device authorization code...", vim.log.levels.INFO)

  vim.system(
    {
      "curl", "-s", "-X", "POST",
      "-H", "Accept: application/json",
      "-d", "client_id=" .. COPILOT_CLIENT_ID .. "&scope=copilot",
      "https://github.com/login/device/code"
    },
    { text = true },
    function(obj)
      if obj.code ~= 0 then
        vim.schedule(function() callback(false, "Failed to connect to GitHub: " .. (obj.stderr or "")) end)
        return
      end

      local ok, res = pcall(vim.json.decode, obj.stdout)
      if not ok or not res or not res.device_code or not res.user_code then
        vim.schedule(function() callback(false, "Invalid response from GitHub: " .. tostring(obj.stdout)) end)
        return
      end

      local device_code = res.device_code
      local user_code = res.user_code
      local verification_uri = res.verification_uri or "https://github.com/login/device"
      local interval = res.interval or 5
      local expires_in = res.expires_in or 900

      vim.schedule(function()
        -- Copy code to clipboard
        pcall(vim.fn.setreg, "+", user_code)
        pcall(vim.fn.setreg, "*", user_code)

        -- Open URL
        open_url(verification_uri)

        -- Show float popup status window
        local copilot_popup = show_copilot_login_popup(user_code, expires_in)
        local msg = string.format("[MetaLSP] Copilot Login:\n1. Copy code: %s (copied!)\n2. Authorize in browser.", user_code)
        utils.notify(msg, vim.log.levels.INFO)

        -- Start Polling
        local poll_timer = uv.new_timer()
        local time_elapsed = 0

        poll_timer:start(interval * 1000, interval * 1000, vim.schedule_wrap(function()
          time_elapsed = time_elapsed + interval
          if time_elapsed > expires_in then
            poll_timer:stop()
            poll_timer:close()
            if copilot_popup then
              local timeout_lines = {
                "  GitHub Copilot Authentication",
                "  ───────────────────────────────",
                "  ❌ Authentication timed out!",
                "  Please try again.",
              }
              vim.bo[copilot_popup.bufnr].modifiable = true
              vim.api.nvim_buf_set_lines(copilot_popup.bufnr, 0, -1, false, timeout_lines)
              vim.bo[copilot_popup.bufnr].modifiable = false
              vim.defer_fn(function() copilot_popup:unmount() end, 4000)
            end
            callback(false, "Authentication timed out. Please try again.")
            return
          end

          vim.system(
            {
              "curl", "-s", "-X", "POST",
              "-H", "Accept: application/json",
              "-d", string.format("client_id=%s&device_code=%s&grant_type=urn:ietf:params:oauth:grant-type:device_code", COPILOT_CLIENT_ID, device_code),
              "https://github.com/login/oauth/access_token"
            },
            { text = true },
            function(poll_obj)
              if poll_obj.code ~= 0 then return end
              local poll_ok, poll_res = pcall(vim.json.decode, poll_obj.stdout)
              if not poll_ok or not poll_res then return end

              if poll_res.access_token then
                poll_timer:stop()
                poll_timer:close()

                local ghu_token = poll_res.access_token
                -- Exchange for session token right away to verify and cache
                M.refresh_copilot_session(ghu_token, function(session_token, err)
                  if err then
                    if copilot_popup then
                      local fail_lines = {
                        "  GitHub Copilot Authentication",
                        "  ───────────────────────────────",
                        "  ❌ Verification failed!",
                        "  Error: " .. tostring(err),
                      }
                      vim.bo[copilot_popup.bufnr].modifiable = true
                      vim.api.nvim_buf_set_lines(copilot_popup.bufnr, 0, -1, false, fail_lines)
                      vim.bo[copilot_popup.bufnr].modifiable = false
                      vim.defer_fn(function() copilot_popup:unmount() end, 4000)
                    end
                    callback(false, "Verification failed: " .. tostring(err))
                    return
                  end

                  local creds = M.load_credentials()
                  creds.github_copilot = {
                    ghu_token = ghu_token,
                    session_token = session_token,
                    expires_at = os.time() + 1500
                  }
                  M.save_credentials(creds)

                  if copilot_popup then
                    local success_lines = {
                      "  GitHub Copilot Authentication",
                      "  ───────────────────────────────",
                      "  ✅ Successfully authenticated!",
                      "  Session token cached and ready.",
                    }
                    vim.bo[copilot_popup.bufnr].modifiable = true
                    vim.api.nvim_buf_set_lines(copilot_popup.bufnr, 0, -1, false, success_lines)
                    vim.bo[copilot_popup.bufnr].modifiable = false
                    vim.defer_fn(function() copilot_popup:unmount() end, 2000)
                  end
                  callback(true, nil)
                end)
              elseif poll_res.error == "authorization_pending" then
                -- Still waiting, keep polling
              else
                -- Other error (e.g. expired_token, access_denied)
                poll_timer:stop()
                poll_timer:close()
                local err_desc = poll_res.error_description or poll_res.error or "Unknown authorization error"
                if copilot_popup then
                  local fail_lines = {
                    "  GitHub Copilot Authentication",
                    "  ───────────────────────────────",
                    "  ❌ Authentication failed!",
                    "  Error: " .. tostring(err_desc),
                  }
                  vim.bo[copilot_popup.bufnr].modifiable = true
                  vim.api.nvim_buf_set_lines(copilot_popup.bufnr, 0, -1, false, fail_lines)
                  vim.bo[copilot_popup.bufnr].modifiable = false
                  vim.defer_fn(function() copilot_popup:unmount() end, 4000)
                end
                callback(false, err_desc)
              end
            end
          )
        end))
      end)
    end
  )
end

-- Web Authentication for OpenAI and Google Gemini
local active_server = nil

local function urldecode(str)
  str = str:gsub("+", " ")
  str = str:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return str
end

local function get_success_html(provider)
  local name = provider == "openai" and "OpenAI" or "Google Gemini"
  return [[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Authentication Success - MetaLSP</title>
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-gradient: radial-gradient(circle at 50% 0%, #1e1b4b, #09090b);
      --card-bg: rgba(15, 23, 42, 0.45);
      --card-border: rgba(16, 185, 129, 0.2);
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --success: #10b981;
    }
    body {
      background: var(--bg-gradient);
      color: var(--text-main);
      font-family: 'Outfit', sans-serif;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .card {
      background: var(--card-bg);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border: 1px solid var(--card-border);
      border-radius: 24px;
      padding: 40px;
      width: 100%;
      max-width: 480px;
      text-align: center;
      box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
    }
    .success-badge {
      background: rgba(16, 185, 129, 0.1);
      border: 1px solid rgba(16, 185, 129, 0.2);
      border-radius: 50%;
      width: 72px;
      height: 72px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      margin-bottom: 24px;
      color: var(--success);
      box-shadow: 0 0 30px rgba(16, 185, 129, 0.2);
    }
    h1 {
      font-size: 26px;
      font-weight: 600;
      margin-bottom: 12px;
    }
    p {
      color: var(--text-muted);
      font-size: 15px;
      line-height: 1.6;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="success-badge">
      <svg width="36" height="36" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
        <polyline points="20 6 9 17 4 12"></polyline>
      </svg>
    </div>
    <h1>Authentication Successful!</h1>
    <p>MetaLSP is now successfully connected to your ]] .. name .. [[ account. You can safely close this browser tab and return to Neovim.</p>
  </div>
</body>
</html>
]]
end

local function get_failure_html(provider, err_msg, port)
  local name = provider == "openai" and "OpenAI" or "Google Gemini"
  if type(err_msg) == "table" then
    local ok, encoded = pcall(vim.json.encode, err_msg)
    if ok and encoded then
      err_msg = encoded
    else
      err_msg = tostring(err_msg)
    end
  else
    err_msg = tostring(err_msg or "Unknown error")
  end
  err_msg = err_msg or "Unknown error"
  err_msg = err_msg:gsub("<", "&lt;"):gsub(">", "&gt;")
  return [[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Authentication Failed - MetaLSP</title>
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-gradient: radial-gradient(circle at 50% 0%, #1e1b4b, #09090b);
      --card-bg: rgba(15, 23, 42, 0.45);
      --card-border: rgba(239, 68, 68, 0.2);
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --error: #ef4444;
      --primary: #6366f1;
    }
    body {
      background: var(--bg-gradient);
      color: var(--text-main);
      font-family: 'Outfit', sans-serif;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .card {
      background: var(--card-bg);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border: 1px solid var(--card-border);
      border-radius: 24px;
      padding: 40px;
      width: 100%;
      max-width: 480px;
      text-align: center;
      box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
    }
    .error-badge {
      background: rgba(239, 68, 68, 0.1);
      border: 1px solid rgba(239, 68, 68, 0.2);
      border-radius: 50%;
      width: 72px;
      height: 72px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      margin-bottom: 24px;
      color: var(--error);
      box-shadow: 0 0 30px rgba(239, 68, 68, 0.2);
    }
    h1 {
      font-size: 26px;
      font-weight: 600;
      margin-bottom: 12px;
      color: var(--error);
    }
    p {
      color: var(--text-muted);
      font-size: 15px;
      line-height: 1.6;
      margin-bottom: 24px;
    }
    .error-box {
      background: rgba(239, 68, 68, 0.08);
      border: 1px solid rgba(239, 68, 68, 0.15);
      border-radius: 12px;
      padding: 16px;
      font-family: monospace;
      font-size: 13px;
      color: #fda4af;
      word-break: break-all;
      margin-bottom: 30px;
      text-align: left;
    }
    .btn-retry {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      background: var(--primary);
      color: white;
      border: none;
      border-radius: 12px;
      padding: 12px 24px;
      font-size: 15px;
      font-weight: 600;
      cursor: pointer;
      text-decoration: none;
      transition: all 0.2s ease;
    }
    .btn-retry:hover {
      background: #4f46e5;
      box-shadow: 0 0 20px rgba(99, 102, 241, 0.4);
      transform: translateY(-1px);
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="error-badge">
      <svg width="36" height="36" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
        <line x1="18" y1="6" x2="6" y2="18"></line>
        <line x1="6" y1="6" x2="18" y2="18"></line>
      </svg>
    </div>
    <h1>Authentication Failed</h1>
    <p>We could not verify the API key with ]] .. name .. [[. Please check the error details below.</p>
    <div class="error-box">]] .. err_msg .. [[</div>
    <button onclick="window.history.back()" class="btn-retry">
      Try Again
    </button>
  </div>
</body>
</html>
]]
end

local function validate_key(provider, key, callback)
  local url = provider == "openai" and "https://api.openai.com/v1/models" or "https://generativelanguage.googleapis.com/v1beta/openai/models"
  vim.system(
    {
      "curl", "-s",
      "-H", "Authorization: Bearer " .. key,
      url
    },
    { text = true },
    function(obj)
      if obj.code ~= 0 then
        vim.schedule(function() callback(false, "Connection error: curl exited with code " .. obj.code) end)
        return
      end

      local ok, res = pcall(vim.json.decode, obj.stdout)
      if ok and res and res.data then
        vim.schedule(function() callback(true, nil) end)
      else
        local err_msg = "Invalid API Key."
        if ok and res and res.error and res.error.message then
          err_msg = res.error.message
        end
        vim.schedule(function() callback(false, err_msg) end)
      end
    end
  )
end

function M.start_web_login(provider, callback)
  if active_server then
    pcall(function() active_server:close() end)
    active_server = nil
  end

  local server = uv.new_tcp()
  local port = 19876
  local bound = false
  while port < 19900 do
    local success = pcall(function()
      server:bind("127.0.0.1", port)
    end)
    if success then
      bound = true
      break
    else
      port = port + 1
    end
  end

  if not bound then
    callback(false, "Could not bind to any local port in range 19876-19900")
    return
  end

  active_server = server

  local current_file = debug.getinfo(1).source:sub(2)
  local current_dir = vim.fn.fnamemodify(current_file, ":p:h")
  local html_path = current_dir .. "/login.html"

  local file_url = "file://" .. html_path .. "?port=" .. port .. "&provider=" .. provider
  open_url(file_url)
  utils.notify("Opened web login page in browser. Waiting for authentication...", vim.log.levels.INFO)

  server:listen(128, function(err)
    if err then return end
    local client = uv.new_tcp()
    server:accept(client)
    client:read_start(function(read_err, data)
      if read_err or not data then
        pcall(function() client:close() end)
        return
      end

      local first_line = data:match("^([^\r\n]+)")
      if first_line then
        local method, path = first_line:match("^(%a+)%s+(%S+)%s+HTTP")
        if method == "GET" and path:find("^/callback") then
          local key = path:match("[?&]key=([^&%s]+)")
          if key then
            key = urldecode(key)
            validate_key(provider, key, function(is_valid, err_msg)
              if is_valid then
                local html = get_success_html(provider)
                local response = "HTTP/1.1 200 OK\r\n" ..
                                 "Content-Type: text/html; charset=utf-8\r\n" ..
                                 "Content-Length: " .. #html .. "\r\n" ..
                                 "Connection: close\r\n\r\n" .. html
                client:write(response, function()
                  pcall(function() client:close() end)
                  
                  local creds = M.load_credentials()
                  creds[provider] = { api_key = key }
                  M.save_credentials(creds)
                  
                  if active_server == server then
                    pcall(function() server:close() end)
                    active_server = nil
                  end
                  
                  callback(true, nil)
                end)
              else
                local html = get_failure_html(provider, err_msg or "Invalid Key", port)
                local response = "HTTP/1.1 200 OK\r\n" ..
                                 "Content-Type: text/html; charset=utf-8\r\n" ..
                                 "Content-Length: " .. #html .. "\r\n" ..
                                 "Connection: close\r\n\r\n" .. html
                client:write(response, function()
                  pcall(function() client:close() end)
                end)
              end
            end)
          else
            local html = "<h1>Error</h1><p>No key provided in callback.</p>"
            local response = "HTTP/1.1 400 Bad Request\r\n" ..
                             "Content-Type: text/html; charset=utf-8\r\n" ..
                             "Content-Length: " .. #html .. "\r\n" ..
                             "Connection: close\r\n\r\n" .. html
            client:write(response, function()
              pcall(function() client:close() end)
            end)
          end
        else
          local response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          client:write(response, function()
            pcall(function() client:close() end)
          end)
        end
      else
        pcall(function() client:close() end)
      end
    end)
  end)
end

local function http_response(client, status, html)
  local response = "HTTP/1.1 " .. status .. "\r\n" ..
                   "Content-Type: text/html; charset=utf-8\r\n" ..
                   "Content-Length: " .. #html .. "\r\n" ..
                   "Connection: close\r\n\r\n" .. html
  client:write(response, function() pcall(function() client:close() end) end)
end

local function oauth_config(provider)
  local redirect_uri = "http://localhost:" .. OAUTH_PORT .. OAUTH_CALLBACK_PATH
  if provider == "openai" then
    return {
      name = "OpenAI",
      auth_url = OPENAI_AUTH_URL,
      token_url = OPENAI_TOKEN_URL,
      client_id = OPENAI_CLIENT_ID,
      redirect_uri = redirect_uri,
      scope = "openid profile email offline_access",
      auth_params = {
        { "response_type", "code" },
        { "client_id", OPENAI_CLIENT_ID },
        { "redirect_uri", redirect_uri },
        { "scope", "openid profile email offline_access" },
        -- code_challenge is appended after PKCE generation to match Pi/OpenCode order.
        -- code_challenge_method/state/extra params are appended below.
      },
      token_params = function(code, verifier)
        return {
          { "grant_type", "authorization_code" },
          { "client_id", OPENAI_CLIENT_ID },
          { "code", code },
          { "code_verifier", verifier },
          { "redirect_uri", redirect_uri },
        }
      end,
    }
  elseif provider == "gemini" then
    local client_secret = gemini_client_secret()
    if not client_secret or client_secret == "" then
      return nil, "Gemini OAuth requires GEMINI_CLIENT_SECRET"
    end
    redirect_uri = "http://localhost:" .. OAUTH_PORT .. "/oauth2callback"
    return {
      name = "Google Gemini",
      auth_url = GEMINI_AUTH_URL,
      token_url = GEMINI_TOKEN_URL,
      client_id = GEMINI_CLIENT_ID,
      redirect_uri = redirect_uri,
      scope = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
      auth_params = {
        { "client_id", GEMINI_CLIENT_ID },
        { "redirect_uri", redirect_uri },
        { "response_type", "code" },
        { "scope", "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile" },
        { "access_type", "offline" },
        { "prompt", "consent" },
      },
      token_params = function(code, verifier)
        return {
          { "client_id", GEMINI_CLIENT_ID },
          { "client_secret", client_secret },
          { "grant_type", "authorization_code" },
          { "code", code },
          { "redirect_uri", redirect_uri },
          { "code_verifier", verifier },
        }
      end,
    }
  end
end

local function login_oauth_provider(provider, callback)
  if active_server then
    pcall(function() active_server:close() end)
    active_server = nil
  end

  local cfg = oauth_config(provider)
  if not cfg then
    callback(false, "Unsupported OAuth provider: " .. tostring(provider))
    return
  end

  local verifier = generate_code_verifier()
  local challenge = generate_code_challenge(verifier)
  local state = generate_state()
  local exchanged = false

  local server = uv.new_tcp()
  local success = pcall(function()
    server:bind("127.0.0.1", OAUTH_PORT)
  end)

  if not success then
    callback(false, "Could not bind to port " .. OAUTH_PORT .. ". Please make sure no other process is using port " .. OAUTH_PORT .. ".")
    return
  end

  active_server = server

  local auth_params = vim.deepcopy(cfg.auth_params)
  auth_params[#auth_params + 1] = { "code_challenge", challenge }
  auth_params[#auth_params + 1] = { "code_challenge_method", "S256" }
  auth_params[#auth_params + 1] = { "state", state }
  if provider == "openai" then
    -- Match Codex/Pi/OpenCode simplified browser flow exactly.
    auth_params[#auth_params + 1] = { "id_token_add_organizations", "true" }
    auth_params[#auth_params + 1] = { "codex_cli_simplified_flow", "true" }
    auth_params[#auth_params + 1] = { "originator", "pi" }
  end
  local auth_url = cfg.auth_url .. "?" .. urlsearchparams(auth_params)

  open_url(auth_url)
  utils.notify("Opened browser for " .. cfg.name .. " login. Waiting for callback on port " .. OAUTH_PORT .. "...", vim.log.levels.INFO)

  server:listen(128, function(err)
    if err then return end
    local client = uv.new_tcp()
    server:accept(client)
    client:read_start(function(read_err, data)
      if read_err or not data then
        pcall(function() client:close() end)
        return
      end

      local first_line = data:match("^([^\r\n]+)")
      if not first_line then
        pcall(function() client:close() end)
        return
      end

      local method, path = first_line:match("^(%a+)%s+(%S+)%s+HTTP")
      if method ~= "GET" or not (path:find("^" .. OAUTH_CALLBACK_PATH) or path:find("^/oauth2callback")) then
        http_response(client, "404 Not Found", "")
        return
      end

      local error_param = path:match("[?&]error=([^&%s]+)")
      if error_param then
        http_response(client, "200 OK", get_failure_html(provider, urldecode(error_param), OAUTH_PORT))
        return
      end

      local code = path:match("[?&]code=([^&%s]+)")
      local recv_state = path:match("[?&]state=([^&%s]+)")
      if recv_state ~= state then
        http_response(client, "400 Bad Request", "<h1>Error</h1><p>State verification failed (CSRF protection).</p>")
        return
      end

      if exchanged then
        http_response(client, "200 OK", get_success_html(provider))
        return
      end

      if not code then
        http_response(client, "400 Bad Request", "<h1>Error</h1><p>No authorization code received.</p>")
        return
      end

      exchanged = true
      code = urldecode(code)
      post_form_urlencoded(cfg.token_url, cfg.token_params(code, verifier), function(obj)
          if obj.code ~= 0 then
            local html = get_failure_html(provider, "Failed to connect to token server: " .. (obj.stderr or ""), OAUTH_PORT)
            vim.schedule(function() http_response(client, "500 Internal Error", html) end)
            return
          end

          local ok, res = pcall(vim.json.decode, obj.stdout)
          if ok and res and res.access_token then
            local account_id = provider == "openai" and (extract_openai_account_id(res.access_token) or extract_openai_account_id(res.id_token)) or nil
            local creds = M.load_credentials()
            creds[provider] = {
              access_token = res.access_token,
              refresh_token = res.refresh_token,
              id_token = res.id_token,
              account_id = account_id,
              expires_at = os.time() + (res.expires_in or 3600),
            }
            M.save_credentials(creds)

            local html = get_success_html(provider)
            vim.schedule(function()
              http_response(client, "200 OK", html)
              if active_server == server then
                pcall(function() server:close() end)
                active_server = nil
              end
              callback(true, nil)
            end)
          else
            local err_desc = (res and (res.error_description or res.error)) or "Failed to exchange authorization code."
            local html = get_failure_html(provider, err_desc, OAUTH_PORT)
            vim.schedule(function() http_response(client, "200 OK", html) end)
          end
        end
      )
    end)
  end)
end

local function login_openai_with_node(callback)
  local node = vim.fn.exepath("node")
  if not node or node == "" then return false end

  if active_server then
    pcall(function() active_server:close() end)
    active_server = nil
  end

  local script = [[
const http = require('node:http');
const { randomBytes, webcrypto } = require('node:crypto');
const { spawn } = require('node:child_process');

const CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';
const AUTHORIZE_URL = 'https://auth.openai.com/oauth/authorize';
const TOKEN_URL = 'https://auth.openai.com/oauth/token';
const REDIRECT_URI = 'http://localhost:1455/auth/callback';
const SCOPE = 'openid profile email offline_access';
const CLAIM = 'https://api.openai.com/auth';

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function generatePKCE() {
  const verifier = b64url(randomBytes(32));
  const hash = await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: b64url(Buffer.from(hash)) };
}
function successHtml() { return '<!doctype html><html><body><h1>Authentication Successful</h1><p>You can close this tab and return to Neovim.</p></body></html>'; }
function errorHtml(msg) { return '<!doctype html><html><body><h1>Authentication Failed</h1><pre>' + String(msg).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) + '</pre></body></html>'; }
function openUrl(url) {
  const platform = process.platform;
  const cmd = platform === 'darwin' ? 'open' : platform === 'win32' ? 'cmd' : 'xdg-open';
  const args = platform === 'win32' ? ['/c', 'start', '', url] : [url];
  try { spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref(); } catch {}
}
function decodeJwt(token) {
  try {
    const parts = String(token).split('.');
    if (parts.length !== 3) return null;
    return JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch { return null; }
}
function accountId(accessToken) {
  const payload = decodeJwt(accessToken);
  const auth = payload && payload[CLAIM];
  return auth && typeof auth.chatgpt_account_id === 'string' ? auth.chatgpt_account_id : null;
}
(async () => {
  const { verifier, challenge } = await generatePKCE();
  const state = randomBytes(16).toString('hex');
  const authUrl = new URL(AUTHORIZE_URL);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('client_id', CLIENT_ID);
  authUrl.searchParams.set('redirect_uri', REDIRECT_URI);
  authUrl.searchParams.set('scope', SCOPE);
  authUrl.searchParams.set('code_challenge', challenge);
  authUrl.searchParams.set('code_challenge_method', 'S256');
  authUrl.searchParams.set('state', state);
  authUrl.searchParams.set('id_token_add_organizations', 'true');
  authUrl.searchParams.set('codex_cli_simplified_flow', 'true');
  authUrl.searchParams.set('originator', 'pi');

  let settled = false;
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '', 'http://localhost');
      if (url.pathname !== '/auth/callback') { res.writeHead(404); res.end(); return; }
      if (url.searchParams.get('state') !== state) { res.writeHead(400, {'content-type':'text/html'}); res.end(errorHtml('State mismatch')); return; }
      const code = url.searchParams.get('code');
      if (!code) { res.writeHead(400, {'content-type':'text/html'}); res.end(errorHtml('Missing authorization code')); return; }
      if (settled) { res.writeHead(200, {'content-type':'text/html'}); res.end(successHtml()); return; }
      settled = true;

      const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          client_id: CLIENT_ID,
          code,
          code_verifier: verifier,
          redirect_uri: REDIRECT_URI,
        }),
      });
      const text = await response.text();
      if (!response.ok) {
        res.writeHead(200, {'content-type':'text/html'}); res.end(errorHtml(text || response.statusText));
        console.log(JSON.stringify({ ok: false, error: text || response.statusText, status: response.status }));
        server.close(() => process.exit(1));
        return;
      }
      const json = JSON.parse(text);
      const acc = accountId(json.access_token);
      if (!json.access_token || !json.refresh_token || typeof json.expires_in !== 'number' || !acc) {
        const err = 'Token response missing access_token/refresh_token/expires_in/account_id: ' + text;
        res.writeHead(200, {'content-type':'text/html'}); res.end(errorHtml(err));
        console.log(JSON.stringify({ ok: false, error: err }));
        server.close(() => process.exit(1));
        return;
      }
      res.writeHead(200, {'content-type':'text/html'}); res.end(successHtml());
      console.log(JSON.stringify({ ok: true, access_token: json.access_token, refresh_token: json.refresh_token, expires_in: json.expires_in, account_id: acc }));
      server.close(() => process.exit(0));
    } catch (error) {
      const msg = error && error.stack ? error.stack : String(error);
      try { res.writeHead(500, {'content-type':'text/html'}); res.end(errorHtml(msg)); } catch {}
      console.log(JSON.stringify({ ok: false, error: msg }));
      server.close(() => process.exit(1));
    }
  });
  server.listen(1455, '127.0.0.1', () => {
    openUrl(authUrl.toString());
  });
  server.on('error', (error) => {
    console.log(JSON.stringify({ ok: false, error: error.message || String(error) }));
    process.exit(1);
  });
  setTimeout(() => {
    console.log(JSON.stringify({ ok: false, error: 'OpenAI login timed out' }));
    server.close(() => process.exit(1));
  }, 10 * 60 * 1000).unref();
})().catch((error) => {
  console.log(JSON.stringify({ ok: false, error: error && error.stack ? error.stack : String(error) }));
  process.exit(1);
});
]]

  utils.notify("Opened browser for ChatGPT login. Waiting for callback on port 1455...", vim.log.levels.INFO)
  vim.system({ node, "-e", script }, { text = true }, function(obj)
    local line = (obj.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local ok, res = pcall(vim.json.decode, line)
    if ok and res and res.ok and res.access_token then
      vim.schedule(function()
        local creds = M.load_credentials()
        creds.openai = {
          access_token = res.access_token,
          refresh_token = res.refresh_token,
          account_id = res.account_id,
          expires_at = os.time() + (res.expires_in or 3600),
        }
        M.save_credentials(creds)
        callback(true, nil)
      end)
    else
      local err = (ok and res and res.error) or obj.stderr or obj.stdout or "OpenAI login failed"
      vim.schedule(function() callback(false, err) end)
    end
  end)
  return true
end

--- Log in to OpenAI
--- @param callback function(success: boolean, err: string|nil)
function M.login_openai(callback)
  if login_openai_with_node(callback) then return end
  login_oauth_provider("openai", callback)
end

--- Log in to Google Gemini
--- @param callback function(success: boolean, err: string|nil)
function M.login_gemini(callback)
  login_oauth_provider("gemini", callback)
end

--- Log out (remove credentials for a provider or all)
--- @param provider string|nil "copilot"|"openai"|"gemini"|nil (nil for all)
function M.logout(provider)
  local creds = M.load_credentials()
  if not provider then
    creds = {}
    utils.notify("Logged out of all cloud providers.", vim.log.levels.INFO)
  elseif provider == "copilot" then
    creds.github_copilot = nil
    utils.notify("Logged out of GitHub Copilot.", vim.log.levels.INFO)
  elseif provider == "openai" then
    creds.openai = nil
    utils.notify("Logged out of OpenAI.", vim.log.levels.INFO)
  elseif provider == "gemini" then
    creds.gemini = nil
    utils.notify("Logged out of Google Gemini.", vim.log.levels.INFO)
  end
  M.save_credentials(creds)
end

return M
