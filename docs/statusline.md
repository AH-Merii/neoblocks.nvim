# neoblocks.statusline

A global statusline rebuilt only on events (replaces lualine.nvim)

A global statusline built from two lists of components, rebuilt on events and never on a cursor move. Replaces
[lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for a statusline with one global line.

```lua
{
  "AH-Merii/neoblocks.nvim",
  event = "VeryLazy",
  config = function()
    local sl = require("neoblocks.statusline")
    require("neoblocks").setup({
      statusline = {
        color = { fg = "#abb2bf" },
        left = {
          { function() return "" end, color = sl.mode_color({ i = { fg = "#98c379" } }), padding = { right = 1 } },
          "%f",
          { "diagnostics", symbols = { error = "E" } },
          "%=",
        },
        right = {
          { "branch", icon = "", color = { fg = "#56b6c2", bold = true } },
          "diff",
          "searchcount",
          { "%3l:%-2c", color = { bold = true } },
        },
      },
    })
  end,
}
```

A component is a function returning statusline text, a statusline string starting with `%`, a built-in name
(`diagnostics`, `branch`, `diff`, `searchcount`, `progress_status`, `recording`) or a table with one of those
first and its options. A component draws nothing when it's empty or its `cond` isn't true; otherwise
`icon text` with one space each side (`padding`), as lualine draws it.

A colour is a highlight group name or a table of `nvim_set_hl()` attributes, e.g. `{ fg = "#e5c07b", bold = true }`
(lualine's `gui = "bold"` is `bold = true` here). A colour Neovim rejects is reported and drawn in the default one.

Text from a function or a string goes in as statusline text, unescaped, so `%l`-style items and `%{...}`
expressions in it follow the cursor without a rebuild; text that isn't valid statusline syntax is reported and its
component left out. The line is rebuilt on `events` and the events the built-ins in use need, at most once per
16 ms, and at once by `refresh()`. A cursor move runs nothing, except while a search is highlighted and the line
has `searchcount`: then it counts the matches again, at most once per 16 ms. `diff` shows gitsigns.nvim's counts.

## Setup

```lua
require("neoblocks").setup({ statusline = {} })
```

## Options

```lua
---@class neoblocks.statusline.Config
---@field left? neoblocks.statusline.Component[] drawn from the left edge; a "%=" entry starts a centred group
---@field right? neoblocks.statusline.Component[] drawn against the right edge
---@field color? neoblocks.statusline.Color text colour of components without their own; default StatusLine's
---@field events? string[] events that rebuild the line; built-ins add their own
---@class neoblocks.statusline.ComponentOpts
---@field [1] string|fun(): string? a function, a "%..." statusline string, or a built-in name
---@field icon? string drawn before the text, with a space; left out with the text when it's empty
---@field color? neoblocks.statusline.Color|fun(): neoblocks.statusline.Color? called on each rebuild
---@field cond? fun(): boolean drawn only when it returns true
---@field on_click? fun(clicks: integer, button: string, mods: string)
---@field padding? integer|{ left?: integer, right?: integer } spaces around the text: 1 each side by default
---@field symbols? table<string, string> diagnostics: error/warn/info/hint; diff: added/modified/removed
---@field diagnostics_color? table<string, neoblocks.statusline.Color> diagnostics: a colour per severity
---@field diff_color? table<string, neoblocks.statusline.Color> diff: added/modified/removed colours
local defaults = {
  left = { "%f %m%r", "branch", "diff", "diagnostics" },
  right = { "searchcount", "recording", "progress_status", "%l:%c" },
  events = {
    "WinEnter",
    "BufEnter",
    "BufWritePost",
    "SessionLoadPost",
    "FileChangedShellPost",
    "VimResized",
    "FileType",
    "ModeChanged",
  },
}
```

## API

### `Neoblocks.statusline.setup()`

Starts the statusline with the options given to `setup()`.

### `Neoblocks.statusline.refresh(buf)`

Rebuilds the statusline now; after `:Neoblocks statusline off` it puts back the statusline it replaced.

- `buf?` `integer`

### `Neoblocks.statusline.mode_color(colors, fallback)`

A colour function for `color`, picking the colour for the current mode.

- `colors` `table<string,neoblocks.statusline.Color>`: keyed by the first letter of `mode()`: n, i, v, V, ...
- `fallback?` `neoblocks.statusline.Color`: for any other mode
- returns `fun():neoblocks.statusline.Color?`

