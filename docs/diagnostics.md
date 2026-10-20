# neoblocks.diagnostics

Diagnostics in a pill after the cursor's line, counts elsewhere (replaces tiny-inline-diagnostic)

tiny-inline-diagnostic's look, drawn by a `vim.diagnostic` handler (`:h diagnostic-handlers`). Replaces
[tiny-inline-diagnostic.nvim](https://github.com/rachartier/tiny-inline-diagnostic.nvim) set up with its "modern"
preset, messages, counts, multiline and related information:

- the cursor's line: its diagnostics after the text in a rounded pill tinted by severity: the ones under the cursor,
  or every one on the line when none is. Each message line gets a row of its own below (`│`, `└`), with LSP related
  information under its diagnostic (`↳`). When the line ends too close to the window's edge, they go under it;
- when the cursor's line has none, each visible line with diagnostics gets a small pill: a `●` per diagnostic,
  coloured by severity, and their count;
- nothing in Insert, Visual or Select mode, nor while `vim.diagnostic.open_float()`'s float is open.

```lua
vim.diagnostic.config({ virtual_text = false }) -- this draws them instead
require("neoblocks").setup({ diagnostics = {} })
vim.keymap.set("n", "<leader>dt", function() Neoblocks.toggle("diagnostics") end, { desc = "Inline diagnostics" })
```

`setup()` adds the `neoblocks.diagnostics` handler and turns it on in `vim.diagnostic.config()`, so the built-in
switches work on it as on the built-in handlers: `vim.diagnostic.enable(false)` hides it, `vim.diagnostic.config({
["neoblocks.diagnostics"] = false })` turns it off, and `vim.diagnostic.config({ ["neoblocks.diagnostics"] = {
severity = ... } })` filters what it draws. It draws every buffer with diagnostics, from LSP or not.

The colours come from `DiagnosticError`, `DiagnosticWarn`, `DiagnosticInfo`, `DiagnosticHint`, `CursorLine`,
`NonText` and `Normal`, blended again on `ColorScheme`, into the `NeoblocksDiagnostics*` groups. The signs are Nerd
Font glyphs, as the preset's are.

## Setup

```lua
require("neoblocks").setup({ diagnostics = {} })
```

## Options

```lua
---@class neoblocks.diagnostics.Config
---@field show_source? boolean add each diagnostic's source, as `(source)`
---@field show_code? boolean add each diagnostic's code, as `[code]`
---@field related? integer how many LSP related-information entries to show under each diagnostic; 0 for none
---@field softwrap? integer the cursor line's diagnostics go under it when it ends this close to the window's edge
---@field blend? number how much of the severity's colour tints the pill, from 0 to 1, over `Normal`'s background
---@field priority? integer the extmarks' priority: higher draws over other virtual text
---@field hide_on_float? boolean hide them while `vim.diagnostic.open_float()`'s float is open
local defaults = {
  show_source = true,
  show_code = true,
  related = 3,
  softwrap = 30,
  blend = 0.22,
  priority = 2048,
  hide_on_float = true,
}
```

## API

### `Neoblocks.diagnostics.refresh(buf)`

Draws again after the module is switched on or off: a buffer (0 for the current one), or every buffer.

- `buf?` `integer`

