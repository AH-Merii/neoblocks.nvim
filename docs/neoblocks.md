# neoblocks

Hand-rolled replacements for Neovim plugins.

One module per plugin it replaces, each off until `setup()` names it. `Neoblocks.<module>` loads a module on
first use, so a module you don't use is never loaded.

A module that's on can be switched off and on again:
- everywhere: `:Neoblocks {module} {on|off|toggle}`, `vim.g.neoblocks_<module> = false`;
- in one buffer: `:Neoblocks! {module} {on|off|toggle}`, `vim.b.neoblocks_<module> = false`. A buffer's switch
  wins over the global one.

## API

### `Neoblocks.setup(opts)`

Turns on each module named in `opts`, unless its options say `enabled = false`.

```lua
require("neoblocks").setup({ colors = {} })
```

- `opts?` `neoblocks.Config`

### `Neoblocks.toggle(name, state, buf)`

Turns a module on or off without losing its setup: globally, or in one buffer.

- `name` `string`
- `state?` `boolean`: on or off; flips it when nil
- `buf?` `integer`: a buffer (0 for the current one); all buffers when nil

