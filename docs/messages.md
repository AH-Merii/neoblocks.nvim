# neoblocks.messages

ui2 with noice's cmdline popup, toasts and long output in a split (replaces noice.nvim)

noice.nvim's message and cmdline look on top of Neovim's own ui2 (`:h ui2`), with nothing drawn by a UI of its
own. Replaces [noice.nvim](https://github.com/folke/noice.nvim) for its command_palette, bottom_search and
long_message_to_split presets with [snacks.nvim](https://github.com/folke/snacks.nvim)'s notifier:

- `:` and `input()` prompts in a bordered popup near the top, titled by the kind of command (Cmdline, Lua, Help,
  Filter, Calculator or the prompt); blink.cmp's cmdline menu opens under it (`vim.g.ui_cmdline_pos`);
- `/` and `?` over the last row, so the windows don't move;
- messages as snacks.notifier toasts: errors stay until dismissed, except a search or jump that found nothing;
  info merges into one toast; output taller than a toast opens in a split below that isn't entered (`q` closes it);
  undo, quickfix, completion and verbose messages are left out, as noice left them out;
- `history()`: every message since startup in a picker, newest first;
- `showcmd()`: the keys of a command that waits for more (a count, `d`, `g`), for a statusline, without the one-frame
  flash of keys whose command runs at once (`w`, `j`, `^D`).

```lua
vim.o.cmdheight = 0 -- the popup and the bottom search need it, as noice's do
require("neoblocks").setup({
  messages = {
    -- messages ui2 keeps in its float, a typed command's output in the cmdline
    ui2 = { msg = { targets = { default = "msg", typed_cmd = "cmd" } } },
  },
})
vim.keymap.set("n", "<leader>n", function() Neoblocks.messages.history() end, { desc = "Message history" })
```

Call `setup()` early in your config, before any message you want to see as a toast: `setup()` turns ui2 on with
the `ui2` options unless your config already did (`require("vim._core.ui2").enable()`), then hooks it. What comes
before that stays with plain ui2. Errors and warnings ui2 showed before snacks.notifier was set up become toasts
once it is, on the tick after UIEnter (lazy.nvim's VeryLazy), or at VeryLazy itself.

snacks.nvim is optional and found at runtime: without its notifier, messages stay with ui2 (and still go in the
history); without its picker, `history()` lists them in a split. ui2 is private (`vim._core`): each part checks the
internals it hooks when it's set up, and a part that finds one missing, or fails while it runs, puts ui2's own
handler back and says so once, so a Neovim that renamed one gives plain ui2, not a broken cmdline. Checked on
Neovim 0.13 nightly; `:checkhealth neoblocks` shows which parts are on. Without a UI attached
(`--headless`) there's no ui2, and the module does nothing.

The popup's border, title and icon are drawn in `NeoblocksMessagesBorder`, `NeoblocksMessagesTitle` and
`NeoblocksMessagesIcon`, linked to `DiagnosticSignInfo` (noice's colour). A toast passes `routine = true` to
snacks for a routine error, so a snacks `notifier.keep` can let it time out.

## Setup

```lua
require("neoblocks").setup({ messages = {} })
```

## Options

```lua
---@class neoblocks.messages.Config
---@field ui2? table options for `require("vim._core.ui2").enable()`, when `setup()` turns ui2 on itself
---@field cmdline? boolean `:` and `input()` in the popup, `/` and `?` over the last row
---@field toasts? boolean messages as snacks.notifier toasts and long output in a split; false leaves them to ui2
---@field showcmd? boolean pending keys through `showcmd()`, which sets 'showcmdloc'; false leaves 'showcmdloc' alone
local defaults = {
  ui2 = {},
  cmdline = true,
  toasts = true,
  showcmd = true,
}
```

## API

### `Neoblocks.messages.setup()`

Turns ui2 on unless it is, then hooks each part the options turn on.

### `Neoblocks.messages.refresh(buf)`

After `:Neoblocks messages off` the cmdline and messages go back to plain ui2, and pending keys to Neovim's own
`%S` ('showcmdloc' "statusline"); on again, to this module.

- `buf?` `integer`

### `Neoblocks.messages.entries()`

Messages seen since `setup()`, oldest first: the toasts, the split's output and what ui2 kept (route "ui2").

- returns `neoblocks.messages.Entry[]`

### `Neoblocks.messages.history()`

The message history, newest first, like noice's `:Noice history`: the messages of `entries()` and, with
snacks.notifier, the `vim.notify()` calls it shows. In a snacks picker, filterable by level, title and text; without
snacks, listed in a split (`q` closes it). `g<` and `:messages` still open ui2's pager.

### `Neoblocks.messages.pending()`

The keys typed so far of a command that waits for more (a count, an operator, `g`, a register), last 10
characters; empty while none waits. A lone key whose command runs at once is left out.

- returns `string`

### `Neoblocks.messages.showcmd()`

Pending keys as statusline text: `pending()` while the module is on, Neovim's own `%S` while it's switched off or
the hook isn't in (a ui2 without it). For that the module sets 'showcmdloc': "last" while on, so the keys reach the
hook, "statusline" otherwise, so Neovim draws them. The text is the same either way, so a statusline drawn once
follows a switch. For a statusline component: `function() return Neoblocks.messages.showcmd() end`.

- returns `string`

