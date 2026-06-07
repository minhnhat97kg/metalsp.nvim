--- MetaLSP.nvim — Feature 5: Contextual Sandbox REPL Generator
--- Select a function visually → LLM generates a runnable test harness with mock data
--- → executed via the system runtime → output shown as virtual text.

local M = {}

local ollama = require("metalsp.ollama")
local ui     = require("metalsp.ui")
local utils  = require("metalsp.utils")

--- Map language → file extension and runner command.
local RUNNERS = {
  go = {
    ext = "go",
    cmd = function(file) return { "go", "run", file } end,
    -- go run needs a file in a valid package dir; create a temp dir
    needs_dir = true,
  },
  typescript = {
    ext = "ts",
    -- Try tsx first, then ts-node, then deno
    cmd = function(file)
      if vim.fn.executable("tsx") == 1 then
        return { "tsx", file }
      elseif vim.fn.executable("ts-node") == 1 then
        return { "ts-node", "--esm", file }
      else
        return { "deno", "run", "--allow-all", file }
      end
    end,
  },
  javascript = {
    ext = "js",
    cmd = function(file) return { "node", file } end,
  },
  lua = {
    ext = "lua",
    cmd = function(file) return { "lua", file } end,
  },
}

--- Get visual selection as a string.
--- @return string|nil, integer start_line
local function get_visual_selection()
  -- Re-enter normal mode to finalize marks
  local ok, lines = pcall(function()
    local s_row = vim.fn.line("'<") - 1  -- 0-indexed
    local e_row = vim.fn.line("'>")      -- exclusive end
    local buf_lines = vim.api.nvim_buf_get_lines(0, s_row, e_row, false)
    return buf_lines, s_row
  end)
  if not ok then return nil, 0 end
  local buf_lines, start_line = lines[1], lines[2]
  return type(buf_lines) == "table" and table.concat(buf_lines, "\n") or nil, start_line
end

--- Write code to a temp file and run it, calling callback with output.
--- @param code string
--- @param lang string
--- @param callback function(output: string, err: string|nil)
local function run_sandbox(code, lang)
  local runner = RUNNERS[lang]
  if not runner then
    return nil, "No runner configured for: " .. lang
  end

  -- Create temp file
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local tmpfile = tmpdir .. "/sandbox." .. runner.ext
  local f = io.open(tmpfile, "w")
  if not f then return nil, "Cannot write temp file: " .. tmpfile end
  f:write(code)
  f:close()

  return tmpfile, tmpdir, nil
end

--- Main entry point: generate and run sandbox for selected code.
--- @param bufnr integer|nil
--- @param start_line integer|nil 0-indexed (for virtual text placement)
--- @param selected_code string|nil (if nil, uses visual selection)
function M.run(bufnr, start_line, selected_code)
  bufnr = bufnr or 0

  local lang = utils.get_language(bufnr)
  if not lang then
    utils.notify("Unsupported language for Sandbox REPL", vim.log.levels.WARN)
    return
  end

  local code = selected_code
  if not code then
    code, start_line = get_visual_selection()
  end

  if not code or #code == 0 then
    utils.notify("No code selected. Use visual mode to select a function.", vim.log.levels.WARN)
    return
  end

  -- Extract function name from first line (best-effort)
  local func_name = code:match("func%s+([%w_]+)") or
                    code:match("function%s+([%w_]+)") or
                    code:match("const%s+([%w_]+)") or
                    "selected_function"

  ui.set_virtual_text(bufnr, start_line or 0, "Generating sandbox…", "DiagnosticInfo")

  -- Step 1: Generate sandbox code via LLM
  ollama.generate_sandbox(func_name, code, lang, function(sandbox_code, gen_err)
    if gen_err or not sandbox_code then
      ui.set_virtual_text(bufnr, start_line or 0,
        "Sandbox generation failed: " .. (gen_err or ""), "DiagnosticError")
      return
    end

    -- Step 2: Write to temp file and execute
    local tmpfile, tmpdir, write_err = run_sandbox(sandbox_code, lang)
    if write_err then
      ui.set_virtual_text(bufnr, start_line or 0, write_err, "DiagnosticError")
      return
    end

    local runner = RUNNERS[lang]
    local cmd = runner.cmd(tmpfile)

    ui.set_virtual_text(bufnr, start_line or 0, "Running sandbox…", "DiagnosticInfo")

    vim.system(cmd, { text = true, timeout = 15000 }, function(obj)
      vim.schedule(function()
        -- Cleanup temp dir
        vim.fn.delete(tmpdir, "rf")

        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        ui.clear_virtual_text(bufnr)

        if obj.code ~= 0 then
          local err_output = (obj.stderr or ""):gsub("\n", " | ")
          ui.set_virtual_text(bufnr, start_line or 0,
            "Error: " .. err_output:sub(1, 80), "DiagnosticError")
          return
        end

        -- Show output as virtual text (collapsed to 1 line) + full popup
        local output = vim.trim(obj.stdout or "")
        local short = output:gsub("\n", " ↵ ")
        if #short > 80 then short = short:sub(1, 77) .. "..." end

        ui.set_virtual_text(bufnr, start_line or 0,
          "Output: " .. short, "DiagnosticOk")

        -- If output is multi-line, also show in a popup
        if output:find("\n") then
          local lines = vim.split(output, "\n")
          local Popup = require("nui.popup")
          local event = require("nui.utils.autocmd").event
          local content = {}
          for _, l in ipairs(lines) do
            content[#content + 1] = "  " .. l
          end
          content[#content + 1] = ""
          content[#content + 1] = "  Press q to close"

          local popup = Popup({
            position = "50%",
            size = {
              width  = math.min(math.max(#short + 4, 50), vim.o.columns - 4),
              height = math.min(#content + 2, 20),
            },
            relative = "editor",
            border = {
              style = "rounded",
              text = {
                top = string.format("  Sandbox: %s [%s] ", func_name, lang),
                top_align = "center",
              },
            },
            win_options = {
              winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
            },
          })
          popup:mount()
          vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, utils.buffer_safe_lines(content))
          vim.bo[popup.bufnr].modifiable = false
          popup:map("n", "q", function() popup:unmount() end, { noremap = true })
          popup:map("n", "<Esc>", function() popup:unmount() end, { noremap = true })
          popup:on(event.BufLeave, function() popup:unmount() end, { once = true })
        end
      end)
    end)
  end)
end

--- Setup: register command and visual keymap.
--- @param keymap string|boolean
function M.setup(keymap)
  vim.api.nvim_create_user_command("MetaLSPSandbox", function()
    M.run(vim.api.nvim_get_current_buf())
  end, {
    range = true,
    desc  = "MetaLSP: Generate and run sandbox for selected function",
  })

  if not keymap then return end

  vim.keymap.set("v", keymap, function()
    local bufnr = vim.api.nvim_get_current_buf()
    local start_line = vim.fn.line("'<") - 1
    local code, _ = get_visual_selection()
    -- Exit visual mode first
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
    vim.schedule(function()
      M.run(bufnr, start_line, code)
    end)
  end, { desc = "MetaLSP: Sandbox REPL", noremap = true, silent = true })
end

return M
