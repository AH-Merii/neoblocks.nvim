# diagnostics: decisions

The `diagnostics` module replaces tiny-inline-diagnostic.nvim (46ae9b3, 2026-10-08) as nvim-config uses it
(`nvim/lua/features/diagnostics.lua` at AH-Merii/nvim-config f582841: the modern preset and the options set there).
It draws the same thing, with less code and less work per keystroke. Read against Neovim v0.13.0-dev-1895+g0851e7dabe
(nightly) on 2026-10-20. `R` is `$VIMRUNTIME/lua/vim/diagnostic` of that nightly, `T` is tiny-inline-diagnostic's
`lua/tiny-inline-diagnostic`.

## What it does (the parity target)

1. On the cursor's line, the diagnostics under the cursor (every one on the line when none is) in a pill after the
   text: an arrow, a rounded end, a dot, the message, ` [code]`, ` (source)`. Each further message line gets a row
   of its own over the lines below (`│`, the last `└`), and each diagnostic up to 3 LSP related-information entries
   (`↳ message [file:line]`). Only that line is drawn (`T/renderer.lua:57-83`, `T/virtual_text.lua:85-175`).
2. On every other line in view, a pill with a dot per diagnostic, the most severe last, and their count
   (`display_count`, `show_multiple_glyphs`).
3. A line ending within `softwrap` (30) columns of the window's edge gets them on the rows under it, from the first
   column, after an up arrow. Rows past the buffer's last line are virtual lines.
4. Hidden in Insert, Select and Visual mode (Visual-block keeps them, `T/state.lua:13-23`) and while
   `vim.diagnostic.open_float()`'s float is open (`override_open_float`).
5. The pill is the severity's colour on a tint: 22% of it over Normal's background. On the cursor's line the arrow
   and the rounded ends take CursorLine's background; with `'nocursorline'` the ends don't but the arrow still does,
   as tiny-inline-diagnostic's (`T/chunk.lua:332-343`).

## 1. A vim.diagnostic handler, not DiagnosticChanged

- Decided: the module registers `vim.diagnostic.handlers["neoblocks.diagnostics"]`. Neovim then does what
  tiny-inline-diagnostic does by hand: it filters each handler's diagnostics by the handler's `severity` option
  (`R/_display.lua:183-184`), holds them back in Insert mode unless `update_in_insert` (`R/_display.lua:33,159`),
  calls `hide()` on `vim.diagnostic.enable(false)` and before each `show()` (`R/_display.lua:146`), and shows every
  buffer again when the config changes (`R/_config.lua:146-152`). `vim.diagnostic.config({ ["neoblocks.diagnostics"]
  = false })` turns it off as `virtual_text = false` does.
- The handler gets the buffer as the caller named it, 0 included, as the built-in handlers do (they resolve it with
  `vim._resolve_bufnr()`); it does the same.
- The lists it gets are the store's own (`R/_store.lua:102` writes `_extmark_id` into them): it reads them and keeps
  its own tables for related information, never changing Neovim's.
- Deliberate difference: tiny-inline-diagnostic sets itself up per buffer on `LspAttach` (`T/diagnostic.lua:20`), so
  a buffer whose diagnostics come only from nvim-lint shows nothing inline. The handler draws every buffer with
  diagnostics.

## 2. Persistent extmarks, diffed; a decoration provider only to watch the view

- Rejected: a decoration provider drawing ephemeral extmarks per redraw. An ephemeral mark's `virt_text` draws but its
  `virt_lines` don't, and rows past the buffer's end need them. Probe on this nightly (a decoration provider puts one
  ephemeral mark with both on row 0; the child's screen read with `nvim__inspect_cell`):

  ```text
  0 one EOL
  1 two
  2 three
  ```

- Decided: persistent extmarks, each keyed by what it draws (the row, the window's text, the diagnostics' version). A
  redraw reuses the marks whose key is unchanged and deletes the rest. Moving between lines without diagnostics
  changes no mark, so Neovim redraws no line for them (`tests/diagnostics_spec.lua`, "moving between lines without
  diagnostics…").
- No throttle. nvim-config set tiny-inline-diagnostic's to 20 ms (`T/diagnostic.lua:46`); this module draws on
  `CursorMoved` at once, and the cost table below is without one.

## 3. Which lines get pills, and when

- The lines in view and a screen's height of margin each way, so lines brought into view by a short scroll already
  have their pills. While the view stays inside the rows planned, for the same diagnostics, text and window, a cursor
  move off the diagnostics' lines plans nothing; past them, the rows are planned again around the view.
- tiny-inline-diagnostic listens to `CursorMoved`, `ModeChanged` and `VimResized`/`WinResized`
  (`T/autocmds.lua:40-41,78,158`), not `WinScrolled`: lines a scroll brings into view without moving the cursor show
  no pills until it moves.
- Here the view is checked as Neovim redraws a window: a decoration provider's `on_win` is given the window's top
  and bottom rows, and a view past the planned rows draws on the next tick. The current window's view can't leave
  them without its cursor moving (`CursorMoved` plans again), but another window, the mouse wheel or an opened fold
  can (a test scrolls another window 55 lines).
- Rejected: `WinScrolled` for it. Its callback ran cold on every scroll and cost 26 to 107 µs a step, `v:event`
  alone 13 µs and `line("w0")`/`line("w$")` 5 and 4 µs (timed with `vim.uv.hrtime()` in a UI child, ^E/^Y every
  40 ms, 2026-10-20); the same calls take under 1 µs in a loop. Scroll alone, the bench's cost child, median CPU
  per ^E/^Y over 7 interleaved runs, above the side without the module in the same runs:

  | run | `WinScrolled`, rows checked | empty `WinScrolled` callback | `on_win` | no listener |
  |---|---|---|---|---|
  | 1 | +50.8 µs | +18.0 µs | | +11.3 µs |
  | 2 | | | +6.5 µs | +5.8 µs |
- `WinScrolled` is listened to only while a buffer shows its cursor line's diagnostics: they're placed by how far the
  window is scrolled sideways and how wide it is, and it fires on a resize too (`doc/windows.txt:659-661`). Tests
  scroll 3 columns and narrow a window.
- No `WinResized`. tiny-inline-diagnostic drew every buffer again on any (`T/autocmds.lua:157-170`), a which-key
  popup's included. It fires after the display is updated (`doc/windows.txt:665`), as `on_win`'s draw does, and every
  case it would see is seen: a taller window by `on_win`, a narrower one by `WinScrolled`. Taking it out, no wrong
  implementation that only drops it had failed a test.

## 4. NUL bytes

- tiny-inline-diagnostic measures the cursor's line with `strdisplaywidth()` (`T/chunk.lua:396`), which fails with
  E976 on a line with a NUL byte: the crash nvim-config hit. Its messages' widths are measured in a `pcall`
  (`T/chunk.lua:15-16`). Here the line is measured with `virtcol("$")`, which takes it, and a NUL byte in a message
  shows as `^@`, as Neovim shows it in text, before `strdisplaywidth()` measures it.
- Whether the cursor's line wraps is the window's own count, `nvim_win_text_height()`, which takes a line with a NUL
  byte and knows about `'linebreak'` and inline virtual text.

## 5. Options

- Kept, under their own names: `show_source`, `show_code`, `related` (`show_related.max_count`), `softwrap`, `blend`
  (the tint's 0.22), `priority` (`virt_texts.priority`) and `hide_on_float` (`override_open_float`).
- Dropped, each set to its default or a no-op in nvim-config:
  - `throttle` (2);
  - `transparent_cursorline`: nothing reads it (`grep -rn transparent_cursorline lua/` at 46ae9b3 finds nothing);
  - `preset` and `signs`: the modern preset's signs are fixed (`T/presets.lua:4-12`); `hi`: the groups nvim-config
    named are the ones used;
  - `overflow`, `break_line`, `format`, `multilines.trim_whitespaces` and `tabstop`: with `overflow = "none"`, messages
    are split on newlines only, tabs left as they are (`T/chunk.lua:540-546`, `T/utils.lua:119-124`);
  - `use_icons_from_diagnostic`, `set_arrow_to_diag_color`, `show_all_diags_on_cursorline`, `use_max_severity`,
    `multilines.always_show`: off in nvim-config; `show_multiple_glyphs`: on, the only behaviour;
  - `severity`: the handler's own `severity` option (1).

## 6. Checked against tiny-inline-diagnostic

`bench/diagnostics.lua` runs both, and a side with neither, in a 100x30 terminal with nvim-config's options.

- Look: each step's screen text, cell by cell, and the module's extmarks with their colours resolved, against
  tiny-inline-diagnostic's. 26 steps in four scenarios (cursor moves, `'nocursorline'`, `'wrap'`, modes and the
  float): all 26 the same (`nvim --clean --headless -l bench/diagnostics.lua <dir> 1 look`, 2026-10-20).
- Ghostty with nvim-config itself, once with tiny-inline-diagnostic and once with this module, the same diagnostics set
  in a Lua file: the same pixels in 10 states (the cursor on a three-line error, on a warning and an info, on related
  information, on a blank line among pills, on an error and a warning, and `<leader>dt` off and on).
- Cost: CPU per operation, 3 rounds of 3 runs each, the medians:

  | µs per op | tiny | neoblocks | none | rounds neoblocks < tiny |
  |---|---|---|---|---|
  | j/k off diagnostics | 1035.5 | 473.3 | 455.9 | 3 of 3 |
  | j/k onto one | 887.5 | 727.7 | 437.8 | 3 of 3 |
  | 10l/10h along one | 665.8 | 549.4 | 412.0 | 3 of 3 |
  | diagnostics update | 4904.1 | 4635.1 | 4384.4 | 3 of 3 |
  | popup resize | 695.7 | 172.7 | 172.8 | 3 of 3 |
  | scroll ^E/^Y | 489.2 | 493.5 | 471.3 | 1 of 3 |

  Scroll is a tie within the runs' spread: the side with neither measured 485.6 and 515.7 µs for it in two runs of
  the same code. tiny-inline-diagnostic does nothing on a scroll and leaves the lines it brings into view without
  pills; this module draws them.
