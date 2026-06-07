--- MetaLSP.nvim — Hover integration
--- Keeps native LSP hover on `K`, and mirrors hover docs into the right MetaLSP pane.

local M = {}

local utils = require("metalsp.utils")

local function lsp_hover_lines(bufnr, cb)
  local params = vim.lsp.util.make_position_params(0, "utf-8")
  vim.lsp.buf_request_all(bufnr, "textDocument/hover", params, function(responses)
    local lines = {}
    for _, response in pairs(responses or {}) do
      if response.result and response.result.contents then
        local md = vim.lsp.util.convert_input_to_markdown_lines(response.result.contents)
        if md and #md > 0 then
          if #lines > 0 then lines[#lines + 1] = "" end
          vim.list_extend(lines, md)
        end
      end
    end
    vim.schedule(function() cb(lines) end)
  end)
end

--- Native hover + right-pane docs. No popup, no auto hover, no model.
function M.show(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local source_line = vim.api.nvim_win_get_cursor(source_win)[1] - 1

  -- Preserve default/native hover behavior.
  vim.lsp.buf.hover()

  -- Mirror docs into the right MetaLSP pane on explicit K only.
  lsp_hover_lines(bufnr, function(lines)
    local ok, kt = pcall(require, "metalsp.features.knowledge_tree")
    if ok and kt.show_hover_docs then
      kt.show_hover_docs(bufnr, lines, source_line, source_win)
    end
  end)
end

function M.setup(keymap)
  if not keymap then return end

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("metalsp-hover", { clear = true }),
    callback = function(event)
      local lang = utils.get_language(event.buf)
      if not lang then return end

      vim.keymap.set("n", keymap, function()
        M.show(event.buf)
      end, {
        buffer = event.buf,
        desc = "MetaLSP: native hover + right pane docs",
        noremap = true,
        silent = true,
      })
    end,
  })
end

return M
