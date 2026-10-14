# neoblocks.nvim

Hand-rolled replacements for Neovim plugins, built to stay out of the way: each module does what we used from the
plugin it replaces, and costs nothing while it's off. A module isn't loaded until `setup()` names it.

## Modules

<!-- modules:start -->

| Module | What it does |
| --- | --- |

<!-- modules:end -->

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

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

Neovim 0.12 or newer. `:checkhealth neoblocks` shows what's on. `:Neoblocks[!] {module} {on|off|toggle}` switches a
module on or off, everywhere or (with `!`) in the current buffer; `:h neoblocks` has the rest.

## Docs

The docs are generated from the code: each module's top comment, options and annotated functions become
`docs/<module>.md`, `:h neoblocks` and the table above (`scripts/docs.lua`). A bot commits them after each merge to
main, so don't edit those files by hand: change the code's comments.

## Development

Every check is a [mise](https://mise.jdx.dev) task and runs the same way locally and in CI:

```sh
mise run setup            # once: install the pre-push secret scan
mise run check:test       # tests, on the Neovim from mise.toml
mise run check:lint       # stylua and selene
mise run docs             # regenerate the docs
mise tasks                # everything else
```
