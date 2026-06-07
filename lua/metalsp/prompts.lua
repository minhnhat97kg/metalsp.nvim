--- MetaLSP.nvim — Prompt management

local M = {}

local config = require("metalsp.config")
local utils = require("metalsp.utils")

local project_prompts = nil

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  return table.concat(lines, "\n")
end

function M.reload()
  project_prompts = {}
  local root = utils.get_project_root() or vim.fn.getcwd()
  local lua_file = root .. "/.metalsp/prompts.lua"
  if vim.uv.fs_stat(lua_file) then
    local ok, loaded = pcall(dofile, lua_file)
    if ok and type(loaded) == "table" then
      project_prompts = vim.tbl_deep_extend("force", project_prompts, loaded)
    else
      utils.notify("Failed loading " .. lua_file .. ": " .. tostring(loaded), vim.log.levels.WARN)
    end
  end

  local dir = root .. "/.metalsp/prompts"
  if vim.uv.fs_stat(dir) then
    for _, name in ipairs({
      "analyze_system", "analyze_user", "error_system", "error_user", "arch_system", "arch_user",
      "sandbox_system", "sandbox_user", "ask_system", "ask_user", "live_flow", "live_intent",
      "live_side_effects", "live_risk", "live_impact", "review_diff",
    }) do
      local text = read_file(dir .. "/" .. name .. ".md")
      if text then project_prompts[name] = text end
    end
  end
  return project_prompts
end

function M.get(name)
  if not project_prompts then M.reload() end
  local cfg = config.get()
  return (project_prompts and project_prompts[name]) or (cfg.prompts and cfg.prompts[name])
end

function M.render(name, ctx)
  local template = M.get(name)
  if type(template) == "function" then return template(ctx or {}) end
  local out = tostring(template or "")
  for key, value in pairs(ctx or {}) do
    out = out:gsub("{{%s*" .. key .. "%s*}}", tostring(value or ""))
  end
  return out
end

function M.names()
  local cfg = config.get()
  local seen, out = {}, {}
  for k in pairs(cfg.prompts or {}) do seen[k] = true; out[#out + 1] = k end
  if not project_prompts then M.reload() end
  for k in pairs(project_prompts or {}) do if not seen[k] then out[#out + 1] = k end end
  table.sort(out)
  return out
end

function M.edit(name)
  local root = utils.get_project_root() or vim.fn.getcwd()
  local dir = root .. "/.metalsp/prompts"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name .. ".md"
  if not vim.uv.fs_stat(path) then
    local current = M.get(name) or ""
    vim.fn.writefile(vim.split(tostring(current), "\n", { plain = true }), path)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
