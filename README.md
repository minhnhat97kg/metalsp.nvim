# MetaLSP.nvim

MetaLSP.nvim is a standalone Neovim plugin for local + cloud-assisted code analysis.
It can index code, summarize symbols, explain errors, manage model/provider selection, and show status in the statusline.

## Features

- Local Ollama / Ollama-compatible providers
- OpenAI / Codex OAuth
- Gemini OAuth
- Model picker with provider API listing
- Statusline integration
- Code graph / semantic summaries
- Error translation and architecture checks
- Knowledge tree / chat / explorer UI

## Requirements

- Neovim **0.12+**
- `sqlite.lua`
- `nui.nvim`
- Recommended:
  - `nvim-web-devicons`
  - `nvim-treesitter`
  - `telescope.nvim`
  - `render-markdown.nvim`

## Installation

### lazy.nvim

```lua
{
  url = "https://github.com/minhnhat97kg/metalsp.nvim",
  config = function()
    require("metalsp").setup({})
  end,
}
```

### git clone

```sh
git clone https://github.com/minhnhat97kg/metalsp.nvim ~/.local/share/nvim/site/pack/metal/start/metalsp.nvim
```

Then in `init.lua`:

```lua
require("metalsp").setup({})
```

## Setup

Minimal setup:

```lua
require("metalsp").setup({})
```

Example with overrides:

```lua
require("metalsp").setup({
  cloud_provider = "ollama",
  statusline = {
    enabled = true,
    use_devicons = true,
  },
  ollama = {
    endpoint = "http://localhost:11434",
    model = "qwen2.5-coder:7b",
    temperature = 0.1,
  },
})
```

## Usage

### Common commands

- `:MetaLSPModel` — pick a model from provider APIs
- `:MetaLSPProvider {ollama|copilot|openai|gemini}` — switch active provider
- `:MetaLSPLogin {openai|gemini|copilot}` — login to cloud provider
- `:MetaLSPLogin! {provider}` — force re-login
- `:MetaLSPLogout {provider}` — clear credentials
- `:MetaLSPStatus` — show runtime status
- `:MetaLSPDoctor` — health check
- `:MetaLSPIndex` — index current file
- `:MetaLSPProjectIndex` — index current project
- `:MetaLSPSettings` — show current config
- `:MetaLSPTool ...` — run internal helper tools
- `:MetaLSP search ...` — semantic search
- `:MetaLSP commit` — generate commit message
- `:MetaLSP errors` — explain current diagnostics
- `:MetaLSP tree` — open knowledge tree
- `:MetaLSP live` — open live analysis UI

### Keymaps

Defaults:

- `<leader>mi` — index current file
- `<leader>mp` — index current project
- `<leader>me` — explain current errors
- `<leader>ms` — show status
- `<leader>mt` — toggle knowledge tree
- `<leader>mc` — chat
- `<leader>mf` — explorer

## Statusline

Statusline is enabled by default.
It shows the active provider/model and current queue state.
If `nvim-web-devicons` is installed, the icon is shown automatically.

Disable it:

```lua
require("metalsp").setup({
  statusline = {
    enabled = false,
  },
})
```

## Model persistence

The last selected model is saved automatically and restored on startup.
So if you choose OpenAI/Gemini/Ollama once, MetaLSP will reuse it next time.

## Cloud auth notes

- OpenAI OAuth/Codex uses ChatGPT backend endpoints
- Gemini uses Google OAuth + PKCE
- If a cloud provider is not authenticated, it will not appear in the model picker
- Gemini OAuth client id is hardcoded (public client)
- Gemini OAuth client secret is read from:
  - `GEMINI_CLIENT_SECRET`
  - or `vim.g.metalsp_gemini_client_secret`

## Troubleshooting

### No models shown

- Make sure you are logged in
- Run `:MetaLSPDoctor`
- Check provider auth with `:MetaLSPLogin`
- For OpenAI API keys, use `OPENAI_API_KEY`

### Statusline does not update

- Ensure `statusline.enabled = true`
- Make sure your colorscheme does not override the statusline component
- Run `:redrawstatus`

## Development

```sh
git clone https://github.com/minhnhat97kg/metalsp.nvim
cd metalsp.nvim
git status
```

## License

TBD
