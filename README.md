# neoblocks.nvim

Small, fast replacements for Neovim plugins, each off until you turn it on.

## Modules

<!-- modules:start -->

| Module | What it does |
| --- | --- |

<!-- modules:end -->

## Install

Neovim 0.12 or newer. With [lazy.nvim](https://github.com/folke/lazy.nvim):

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
