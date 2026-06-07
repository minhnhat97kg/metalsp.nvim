--- MetaLSP.nvim — Local assistant tools

local M = {}

local db = require("metalsp.db")
local utils = require("metalsp.utils")

local last_runs = {}

local function root()
  return utils.get_project_root() or vim.fn.getcwd()
end

local function code_excerpt(node, max_lines)
  max_lines = max_lines or 160
  if not node or not node.file_path then return "" end
  local abs = root() .. "/" .. node.file_path
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then return "" end
  local s = math.max(0, node.line_start or 0)
  local e = math.max(s, node.line_end or s)
  if e - s + 1 > max_lines then e = s + max_lines - 1 end
  local out = { string.format("File: %s:%d-%d", node.file_path, s + 1, e + 1), "```" }
  for i = s + 1, math.min(e + 1, #lines) do
    out[#out + 1] = string.format("%4d │ %s", i, lines[i])
  end
  out[#out + 1] = "```"
  return table.concat(out, "\n")
end

local function record(name, input, output)
  last_runs[#last_runs + 1] = { name = name, input = input, output = output, created_at = os.time() }
  if #last_runs > 50 then table.remove(last_runs, 1) end
  if db.record_tool_run then db.record_tool_run(name, tostring(input or ""), tostring(output or "")) end
end

function M.read_code(node, opts)
  local out = code_excerpt(node, opts and opts.max_lines or nil)
  record("read_code", node and node.id or "", out)
  return out, { string.format("- `read_code` %s:%d-%d", node.file_path or "?", (node.line_start or 0) + 1, (node.line_end or 0) + 1) }
end

function M.read_dependencies(node, opts)
  local max = (opts and opts.max_nodes) or 4
  local context, tool_lines = { "Dependencies code excerpts:" }, {}
  local deps = db.get_direct_dependencies(node.id)
  for i, n in ipairs(deps) do
    if i > max then break end
    tool_lines[#tool_lines + 1] = string.format("- `read_dependencies` `%s` %s:%d", n.name or "?", n.file_path or "?", (n.line_start or 0) + 1)
    context[#context + 1] = code_excerpt(n, opts and opts.max_lines or 80)
  end
  if #deps == 0 then context[#context + 1] = "none indexed" end
  local out = table.concat(context, "\n\n")
  record("read_dependencies", node.id, out)
  return out, tool_lines
end

function M.read_references(node, opts)
  local max = (opts and opts.max_nodes) or 4
  local context, tool_lines = { "References/callers code excerpts:" }, {}
  local refs = db.get_direct_dependents(node.id)
  for i, n in ipairs(refs) do
    if i > max then break end
    tool_lines[#tool_lines + 1] = string.format("- `read_references` `%s` %s:%d", n.name or "?", n.file_path or "?", (n.line_start or 0) + 1)
    context[#context + 1] = code_excerpt(n, opts and opts.max_lines or 80)
  end
  if #refs == 0 then context[#context + 1] = "none indexed" end
  local out = table.concat(context, "\n\n")
  record("read_references", node.id, out)
  return out, tool_lines
end

function M.read_git_diff(staged)
  local args = staged and { "git", "diff", "--staged" } or { "git", "diff" }
  local obj = vim.system(args, { cwd = root(), text = true }):wait()
  local out = obj.stdout or ""
  record(staged and "read_git_diff_staged" or "read_git_diff", "", out)
  return out, { staged and "- `read_git_diff --staged`" or "- `read_git_diff`" }
end

function M.search_text(query, max_results)
  max_results = max_results or 20
  local obj = vim.system({ "rg", "-n", "--no-heading", query }, { cwd = root(), text = true }):wait()
  local lines = vim.split(obj.stdout or "", "\n", { trimempty = true })
  local out = {}
  for i, l in ipairs(lines) do if i > max_results then break end; out[#out + 1] = l end
  local text = table.concat(out, "\n")
  record("search_text", query, text)
  return text, { "- `search_text` " .. query }
end

function M.read_file_location(spec, opts)
  opts = opts or {}
  spec = tostring(spec or "")
  local path, line, end_line = spec:match("^(.+):(%d+)%-(%d+)$")
  if not path then path, line = spec:match("^(.+):(%d+)$") end
  path = path or spec
  path = path:gsub("^@", "")
  line = tonumber(line)
  end_line = tonumber(end_line)

  local abs = path:sub(1, 1) == "/" and path or (root() .. "/" .. path)
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then
    local out = "Could not read file location: " .. spec
    record("read_file_location", spec, out)
    return out, { "- `read_file_location` failed " .. spec }
  end

  local max_lines = opts.max_lines or 120
  local s = line or 1
  local e = end_line or (line and (line + math.floor(max_lines / 2)) or math.min(#lines, max_lines))
  s = math.max(1, math.min(s, #lines))
  e = math.max(s, math.min(e, #lines, s + max_lines - 1))

  local rel = utils.relative_path(abs, root())
  local out = { string.format("File: %s:%d-%d", rel, s, e), "```" }
  for i = s, e do out[#out + 1] = string.format("%4d │ %s", i, lines[i]) end
  out[#out + 1] = "```"
  local text = table.concat(out, "\n")
  record("read_file_location", spec, text)
  return text, { string.format("- `read_file_location` %s:%d-%d", rel, s, e) }
end

function M.read_url(url, opts)
  opts = opts or {}
  url = tostring(url or "")
  local obj = vim.system({ "curl", "-L", "-s", "--max-time", tostring(opts.timeout or 15), url }, { text = true }):wait()
  local out = obj.stdout or ""
  local max_chars = opts.max_chars or 20000
  if #out > max_chars then out = out:sub(1, max_chars) .. "\n\n[MetaLSP: URL content truncated]" end
  if obj.code ~= 0 or out == "" then out = "Could not read URL: " .. url .. "\n" .. tostring(obj.stderr or "") end
  record("read_url", url, out)
  return "URL: " .. url .. "\n```\n" .. out .. "\n```", { "- `read_url` " .. url }
end

function M.last_runs()
  return last_runs
end

return M
