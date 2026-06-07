--- MetaLSP.nvim — Utility functions

local M = {}

--- Compute SHA256 hash of a string (used for change detection).
--- @param str string
--- @return string hex hash
function M.hash(str)
  return vim.fn.sha256(str)
end

--- Detect project root by checking LSP clients first, then git markers.
--- @param bufnr integer|nil
--- @return string|nil root path
function M.get_project_root(bufnr)
  bufnr = bufnr or 0

  -- Try LSP root first
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.config and client.config.root_dir then
      return client.config.root_dir
    end
  end

  -- Fallback: search for common root markers
  local markers = { ".git", "go.mod", "package.json", "Cargo.toml", "pyproject.toml" }
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil end

  local dir = vim.fn.fnamemodify(path, ":h")
  local found = vim.fs.find(markers, { upward = true, path = dir, limit = 1 })
  if found and #found > 0 then
    return vim.fn.fnamemodify(found[1], ":h")
  end

  return nil
end

--- Get the user's current file-system location.
--- Prefer the current buffer's directory; fall back to cwd.
--- @param bufnr integer|nil
--- @return string folder absolute normalized path
function M.current_location_folder(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and vim.bo[bufnr].buftype == "" then
    local stat = vim.uv.fs_stat(name)
    local dir = stat and stat.type == "directory" and name or vim.fn.fnamemodify(name, ":h")
    if dir and dir ~= "" then return vim.fs.normalize(dir) end
  end
  return vim.fs.normalize(vim.fn.getcwd())
end

--- Convert an absolute file path to a project-relative path.
--- @param abs_path string
--- @param root string|nil project root
--- @return string relative path
function M.relative_path(abs_path, root)
  root = root or M.get_project_root()
  if not root then return abs_path end

  -- Normalize both paths
  root = vim.fs.normalize(root)
  abs_path = vim.fs.normalize(abs_path)

  if abs_path == root then
    return "."
  end
  if vim.startswith(abs_path, root .. "/") then
    local rel = abs_path:sub(#root + 2) -- +2 to skip trailing /
    return rel
  end
  return abs_path
end

--- Get stable project ID for the current root.
--- @param root string|nil
--- @return string
function M.project_id(root)
  root = vim.fs.normalize(root or M.get_project_root() or vim.fn.getcwd())
  return vim.fn.sha256(root):sub(1, 16)
end

--- Generate a unique node ID from file path and symbol name.
--- Format: "projectHash:rel/path/to/file.ts:symbolName"
--- @param file_path string (relative)
--- @param name string
--- @param root string|nil
--- @return string
function M.make_node_id(file_path, name, root)
  return M.project_id(root) .. ":" .. file_path .. ":" .. name
end

--- Parse a node ID back to file_path and name.
--- @param id string
--- @return string file_path, string name
function M.parse_node_id(id)
  local sep = id:find(":[^/\\]*$")
  if sep then
    return id:sub(1, sep - 1), id:sub(sep + 1)
  end
  return id, ""
end

--- Debounce a function call.
--- Returns a new function that delays execution until after `ms` milliseconds
--- have elapsed since the last time it was invoked.
--- @param fn function
--- @param ms integer
--- @return function debounced
function M.debounce(fn, ms)
  local timer = vim.uv.new_timer()
  return function(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(function()
      fn(unpack(args))
    end))
  end
end

--- Get lines around a specific line for context.
--- @param bufnr integer
--- @param line integer 0-indexed
--- @param context_lines integer number of lines above/below
--- @return string
function M.get_context(bufnr, line, context_lines)
  context_lines = context_lines or 10
  local total = vim.api.nvim_buf_line_count(bufnr)
  local start = math.max(0, line - context_lines)
  local stop = math.min(total, line + context_lines + 1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start, stop, false)
  return table.concat(lines, "\n")
end

--- Safe JSON decode with error handling.
--- @param str string
--- @return table|nil, string|nil error
function M.json_decode(str)
  local ok, result = pcall(vim.json.decode, str)
  if ok then
    return result, nil
  end

  -- Try to extract JSON from markdown code block (LLM sometimes wraps in ```)
  local json_block = str:match("```json%s*(.-)%s*```")
  if json_block then
    ok, result = pcall(vim.json.decode, json_block)
    if ok then return result, nil end
  end

  -- Try to find raw JSON object
  local json_obj = str:match("%b{}")
  if json_obj then
    ok, result = pcall(vim.json.decode, json_obj)
    if ok then return result, nil end
  end

  return nil, "Failed to parse JSON: " .. tostring(result)
end

--- Convert arbitrary strings to a safe list for nvim_buf_set_lines().
--- Neovim rejects list items containing newlines.
--- @param src table|string|nil
--- @return string[]
function M.buffer_safe_lines(src)
  if type(src) == "string" then src = { src } end
  local out = {}
  for _, item in ipairs(src or {}) do
    local text = tostring(item or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then
      out[#out + 1] = ""
    else
      for part in (text .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = part
      end
    end
  end
  return out
end

--- Make text safe for one-line APIs such as quickfix titles/items.
--- @param text any
--- @return string
function M.one_line(text)
  return tostring(text or ""):gsub("[\r\n]+", " ")
end

--- Notify with MetaLSP prefix
--- @param msg string
--- @param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  vim.notify("[MetaLSP] " .. M.one_line(msg), level or vim.log.levels.INFO)
end

--- Get buffer filetype mapped to MetaLSP language key
--- @param bufnr integer|nil
--- @return string|nil
function M.get_language(bufnr)
  bufnr = bufnr or 0
  local ft = vim.bo[bufnr].filetype
  local map = {
    go = "go",
    typescript = "typescript",
    typescriptreact = "typescript",
    javascript = "javascript",
    javascriptreact = "javascript",
    lua = "lua",
  }
  return map[ft]
end

--- Enable render-markdown.nvim for a buffer if configured.
--- @param bufnr integer|nil
function M.render_markdown(bufnr)
  local config = require("metalsp.config")
  if not config.get().features.render_markdown then return end

  bufnr = bufnr or 0
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].syntax = "markdown"
  end

  pcall(vim.treesitter.start, bufnr, "markdown")
  local function enable_and_render()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_call(bufnr, function()
      local rm_api = require("render-markdown.api")
      if rm_api and rm_api.buf_enable then rm_api.buf_enable() end
      if rm_api and rm_api.render then
        rm_api.render({ buf = bufnr })
      end
    end)
  end
  pcall(enable_and_render)
  vim.schedule(function() pcall(enable_and_render) end)
end

return M
