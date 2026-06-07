--- MetaLSP.nvim — Treesitter AST Dispatcher
--- Detects buffer language and delegates to the correct extractor.

local M = {}

local utils = require("metalsp.utils")
local config = require("metalsp.config")

--- Language extractor registry
local extractors = {
  go         = function(bufnr) return require("metalsp.treesitter.go").extract(bufnr) end,
  typescript = function(bufnr) return require("metalsp.treesitter.typescript").extract(bufnr, "typescript") end,
  javascript = function(bufnr) return require("metalsp.treesitter.typescript").extract(bufnr, "javascript") end,
  lua        = function(bufnr) return require("metalsp.treesitter.lua").extract(bufnr) end,
}

local function language_enabled(lang)
  local languages = config.get().languages
  if not languages then return true end
  return vim.tbl_contains(languages, lang)
end

--- Extract all symbols from a buffer.
--- Automatically detects the language and dispatches to the correct extractor.
---
--- @param bufnr integer|nil (defaults to current buffer)
--- @return Symbol[] list of extracted symbols, or empty list if unsupported
function M.extract(bufnr)
  bufnr = bufnr or 0

  -- Check if buffer is valid and has a file
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return {} end

  -- Detect language
  local lang = utils.get_language(bufnr)
  if not lang or not language_enabled(lang) then return {} end

  local extractor = extractors[lang]
  if not extractor then
    utils.notify("No extractor for language: " .. lang, vim.log.levels.DEBUG)
    return {}
  end

  -- Run extractor, catch any Treesitter errors gracefully
  local ok, symbols = pcall(extractor, bufnr)
  if not ok then
    utils.notify("Extractor error for " .. lang .. ": " .. tostring(symbols), vim.log.levels.WARN)
    return {}
  end

  return symbols or {}
end

--- Check if the current buffer's language is supported.
--- @param bufnr integer|nil
--- @return boolean
function M.is_supported(bufnr)
  local lang = utils.get_language(bufnr or 0)
  return lang ~= nil and language_enabled(lang) and extractors[lang] ~= nil
end

--- Register a custom extractor for a language.
--- Allows users to extend MetaLSP with additional language support.
--- @param lang string filetype key (e.g. "python")
--- @param fn function(bufnr: integer): Symbol[]
function M.register(lang, fn)
  extractors[lang] = fn
end

return M
