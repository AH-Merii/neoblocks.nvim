<h1 align="center"><img src="assets/neoblocks-wordmark.svg" alt="Neoblocks" width="600"></h1>

<p align="center">Small, fast replacements for Neovim plugins, each off until you turn it on.</p>

## Modules

<!-- modules:start -->

| Module | What it does |
| --- | --- |
| [diagnostics](docs/diagnostics.md) | Diagnostics in a pill after the cursor's line, counts elsewhere (replaces tiny-inline-diagnostic) |
| [messages](docs/messages.md) | ui2 with noice's cmdline popup, toasts and long output in a split (replaces noice.nvim) |
| [statusline](docs/statusline.md) | A global statusline rebuilt only on events (replaces lualine.nvim) |

<!-- modules:end -->

## Install

Neovim 0.13 (nightly) or newer. With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "AH-Merii/neoblocks.nvim",
  lazy = false,
  ---@type neoblocks.Config
  opts = {
    colors = {}, -- naming a module turns it on; colors = { enabled = false } keeps it off
  },
}
```

A module you don't name is never loaded.

## Usage

- `:Neoblocks {module} {on|off|toggle}` switches a module on or off; `:Neoblocks!` does it in the current buffer only.
- `:checkhealth neoblocks` shows which modules are on.
- `:h neoblocks`, or [docs/](docs/neoblocks.md), has each module's options and API.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
