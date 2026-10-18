# messages: decisions

The `messages` module is nvim-config's `nvim/lua/ui/messages/` (AH-Merii/nvim-config ee67afa, "the config" below)
moved here: noice.nvim's look on top of Neovim's own ui2. The behaviour and the reasons for it were decided in the
config's `docs/ui2-noice-parity-decisions.md` (2026-10-12), which stays the parity record; this file records what
moving it changed and why. Read against noice.nvim 7bfd942, snacks.nvim 882c996, blink.cmp 1.10.2 and Neovim
v0.13.0-dev-1868 (nightly) on 2026-10-18. `R` is `$VIMRUNTIME/lua/vim/_core` of that nightly.

## What it does (the parity target)

From the config's decisions doc, unchanged:

1. `:` and `input()` in noice's command_palette popup: row 3, centred, at least 60 wide, rounded, title and icon per
   kind (Cmdline, Lua, Help, Filter, Calculator, the prompt). ui2 still draws the text in its own cmd window; the module
   only moves that window, and gives blink.cmp the popup's position through `vim.g.ui_cmdline_pos`
   (`blink.cmp/lua/blink/cmp/config/completion/menu.lua:49-56`).
2. `/` and `?` over the last row (noice's bottom_search). `confirm()`, `:s///c`, block mode and `input('')` stay with
   ui2.
3. Messages as snacks.notifier toasts: errors stay (`timeout = 0`) except the routine "nothing found or at the edge"
   codes, info merges into one toast, adjacent errors share one, titles are the typed command or noice's
   Error/Warning/Messages; undo, quickfix, completion, verbose, shell_cmd and progress are left out.
4. Output taller than a toast (counted as snacks sizes it, a typed command's output as a whole) opens in a split
   below that isn't entered; `q` closes it.
5. A history of every message, newest first, in snacks' picker.
6. Pending keys for a statusline, without the one-frame flash of keys whose command runs at once.

## 1. One module, four parts, each guarded on its own

- `lua/neoblocks/messages/init.lua` holds what the docs are generated from (the top comment, `Config`, the API) and
  `setup()`; `cmdline.lua`, `toasts.lua` (the config's `messages.lua`; `neoblocks.messages.messages` read badly) and
  `showcmd.lua` hook ui2. The config's `history.lua` is `history()` in `init.lua`: the generator reads the API from the
  module's own file only (`scripts/docs.lua`, `parse(file, ...)` per module).
- As in the config, each part checks the ui2 internals it hooks before installing, and puts ui2's handler back and
  warns once when one is missing or fails at runtime; the others keep working. What each part's state is (on, off in
  the options, or why it's plain ui2) is kept, so `:checkhealth neoblocks` lists it, where the config only warned.
  The config's pending-keys hook had no guard at runtime (`nvim/lua/ui/messages/showcmd.lua` at nvim-config 76533b0);
  here it has one like the other two, and when it fails the keys go back to Neovim (6).
- The code is the config's, with the names changed (namespaces `neoblocks.messages.*`, the info toast's id
  `neoblocks.messages`; nothing in the config reads the old ids: `git grep 'ui2\.msg' origin/main` in nvim-config finds
  only the old module and its doc). Its `path:line` references to the runtime were re-read against nightly.

## 2. snacks.nvim is optional, found at runtime

- Decided: snacks is detected when it's used, never required. Toasts need `Snacks.did_setup` and
  `Snacks.config.notifier.enabled`, the config's check (its `snacks_ready()`); the history picker needs `Snacks.picker`.
- Without the notifier, every message stays with ui2, recorded in the history: what the config already did before
  snacks was set up (`route()`'s `not snacks_ready()` branch). The cmdline popup and pending keys don't use snacks.
- Without the picker, `history()` lists the messages in a scratch split, newest first, `q` closes it.
- Rejected: snacks as a hard dependency (neoblocks has none, `docs/decisions/neoblocks.md` 3); drawing toasts of our
  own (a second notifier is a module of its own, not part of this move); `vim.notify` as the fallback toast: Neovim's
  default `vim.notify` is `nvim_echo`, whose message comes back to `msg_show` and so to this hook.
- Kept from the config: a toast passes `routine = true` for a routine error, so a snacks `notifier.keep` that holds
  errors can let it time out (the config's `ui/snacks.lua:53` reads `n.routine`).

## 3. Neovim versions: nightly only

- neoblocks supports Neovim 0.13 (nightly) only: the user's call on 2026-10-18, after this module's first review.
  fd9c02f (#11) dropped 0.12 across neoblocks (CI, README, `health.lua`); this module has no version checks and no
  0.12 code paths, and its tests run on nightly.
- Every internal the parts hook, read on v0.13.0-dev-1868 on 2026-10-18:

  | Internal | where |
  |---|---|
  | handler looked up per event | `R/ui2.lua:159,238` |
  | `ui.cmd`, `ui.msg` set by `enable()` with a UI | `R/ui2.lua:217-219,234-235` |
  | fast events rescheduled | `R/ui2.lua:242-243` |
  | `ui.check_targets()`, `ui.wins`, `ui.bufs`, `ui.cmdheight` | `R/ui2.lua:54-57,77` |
  | `cmd.cmdline_show/hide`, `srow`, `level`, `prompt` | `R/ui2/cmdline.lua:96,144,8,10,6` |
  | `msg.msg_show(kind, content, replace_last, history, append, id, trigger)` | `R/ui2/messages.lua:466` |
  | `msg.msg_showcmd(content)` | `R/ui2/messages.lua:583` |

- ui2 is private and still changing, so the guards stay: each part checks the internals it hooks when it's set up, and
  one that finds an internal missing or fails while it runs turns itself off with a warning (tests cover both).
- `cmdline_show`'s `prompt` is `string|false` (`R/ui2/cmdline.lua:92`); `false` is read as `""`. Its `hl_id` is -1
  for `:` and `/` and 0 for `input()` prompts (probe below); the routing reads `hl_id == 0` only for prompts
  (`firstc == ""`).
- `:w`'s progress message has the id `nvim.bufwrite "<file>"` (`doc/api-ui-events.txt:871` of the nightly install,
  `src/nvim/bufwrite.c:1104` on master), and the toasts keep it. A test writes a file and checks the toast and the
  history entry. (The review found `:w` showing nothing on 0.12.6, whose id is `"bufwrite"`,
  `src/nvim/bufwrite.c:1710` at v0.12.6; out of scope now.)
- `enable()` takes `msg.targets`, a target or a table with a `default` key (`R/ui2.lua:214-216`), and errors on
  removed keys such as `msg.msg.timeout` (`R/ui2.lua:208-210`). The `ui2` option is passed as given.

## 4. setup() turns ui2 on, and hooks it

- The config calls `ui2.enable()` and then `ui.messages.setup()` (`nvim/lua/app/init.lua:24-27`). A neoblocks user
  shouldn't have to know `vim._core`, so `setup()` calls `enable(ui2)` itself, unless ui2 is on already (`ui.cmd` and
  `ui.msg` are set: they only are after `enable()` with a UI, table in 3). The config can keep its own call, to catch the
  messages of everything before neoblocks loads.
- Startup errors ui2 showed before snacks was set up become toasts, as in the config. The config replayed them at
  `User VeryLazy`, which its own startup fires (`nvim/lua/app/init.lua:141-151`); neoblocks can't count on that event,
  so it replays on the tick after UIEnter, when VeryLazy fires (`lazy/core/util.lua:167-195`, and the config's copy
  of it), if snacks is set up by then, else at VeryLazy, if it fires; after that the list is dropped, and it never
  holds more than 500.
- Without a UI (`--headless`) `enable()` returns early (`R/ui2.lua:217-219`), so nothing is hooked, as in the config.

## 5. Options: one switch per part, and ui2's own

- `ui2`: the table for `enable()`. Default `{}`, ui2's defaults.
- `cmdline`, `toasts`, `showcmd`: each part can be left out, e.g. `toasts = false` for a config with its own notifier.
  The config used all three; the default is all on. `showcmd` on means the module sets 'showcmdloc' (6); off leaves
  it alone.
- Not options (the config hardcodes them, and they're noice's): the popup's row 3 and width 60, the 20-row split limit,
  the routine error codes, the 500-message history. The popup's colours are highlight groups instead:
  `NeoblocksMessagesBorder`, `...Title`, `...Icon`, linked by default to `DiagnosticSignInfo`, the config's colour for
  all three, and linked again on ColorScheme.

## 6. On and off

- `:Neoblocks messages off` (or `vim.g.neoblocks_messages = false`, then `refresh()`): the hooks stay installed and
  pass every event to ui2's own handler, so ui2 behaves as plain ui2; an open popup goes back to ui2's window.
- Pending keys: the module sets 'showcmdloc' to "last" while on, so the keys come to the hook as `msg_showcmd`, and to
  "statusline" while off, or once the hook failed or found `msg_showcmd` missing, so Neovim draws them for `%S`.
  While the hook is in, `showcmd()` returns `%{v:lua...pending()}%S`: in each state one half is empty, so a statusline
  that drew it once, a plain 'statusline' string or the neoblocks statusline (which rebuilds only on its events),
  follows a switch with no rebuild.
  - Rejected: putting back the value from before `setup()` (b7a88f6 did). With Neovim's default "last", `%S` draws
    nothing, so switched off a statusline showed no keys (the new switch test against b7a88f6: `SL[]` after
    typing `5`, as in the review's probe).
  - Rejected: `refresh()` rebuilding the statusline through `require("neoblocks.statusline").refresh()`. It ties the
    two modules together and still misses a plain 'statusline' string. Before the change, a neoblocks statusline that
    drew `showcmd()` while on still showed `SL[]` after a switch off and `5`, even with 'showcmdloc' put back to
    "statusline" (the new switch test's neoblocks-statusline case with 'showcmdloc' "statusline" set first, run
    against b7a88f6).
  - The user's own 'showcmdloc' isn't kept while `showcmd` is on: only these two values give a `showcmd()`
    statusline its keys. `showcmd = false` leaves it alone.
- `:Neoblocks! messages off` (one buffer): the cmdline and messages follow the current buffer, as the statusline does.
  Pending keys follow only the global switch: 'showcmdloc' is a global option.

## 7. API

- `history()`: the config's `history.open()`. `entries()`: the config's `messages.entries()`, kept after a hook
  failure, with what it saw until then.
- `pending()` and `showcmd()`: the config's statusline component chose `%{v:lua...get()}` or `%S` itself
  (`nvim/lua/ui/statusline.lua:279`); `showcmd()` gives one text for both states (6), so the component is
  `function() return Neoblocks.messages.showcmd() end`.

## 8. Tests

- ui2 needs a UI attached, so each test runs a child `nvim --clean` in a terminal (`jobstart(..., { term = true })`
  in a 120x36 float, as `tests/statusline_spec.lua` does for the screen), types into the terminal and asks the child
  over RPC (`--listen`, `sockconnect`). The child turns off the hit-enter and more prompts, which ui2 ignores (it
  reads only maxheight, timeout and pager from 'messagesopt', `R/ui2/messages.lua:53-63`), so a broken module can't block RPC.
- snacks isn't installed in the runner (offline). Tests that need it give the child a fake `Snacks` that records each
  toast's text, level, title, timeout and `routine`, and the picker's items. snacks' own drawing (the `style` function
  that lays chunk highlights over the toast) isn't covered: it needs the real snacks.
- Ported from the config's checks: `tests/regress/checks/showcmd_pending.lua` (every case, fed as `msg_showcmd` events)
  and `tests/regress/work/ui2-noice/ui2_noice.sh` (the popup, `/`, `:echo` and error toasts and their titles, routine
  errors, undo left out, the split for 60 lines, 25 typed lines, a 25-message burst, a 31-line async message and
  wrapped lines, `g<`). Not ported: the tmux check's "still there after 4.5 s" and "gone after 4.5 s", which time
  snacks' own timeout; the tests check the `timeout` the module passes instead. `<leader>N` dismissing toasts is the
  config's key. Added: titles per kind, input prompts, `confirm()`, block mode, blink's position, the switch, a
  failing toast, the early replay, the history with and without snacks, a missing internal.
- Added after the review of b7a88f6, each from a rule it found untested: `:w`'s toast and history entry from a real
  write, and which progress ids make a toast; each part turned off in the options; the `ui2` option reaching
  `enable()`; a popup failing at runtime; the buffer-local switch for the cmdline and messages, and pending keys
  staying global; a statusline drawn once following the switch (a plain string and the neoblocks statusline); a
  failing pending-keys hook; pending keys in the statusline with `msg_showcmd` missing. Fixed waits (`vim.wait(300)`
  before asserting) became waits on the mode or the screen. After the second review: a count pending when the module
  is switched off leaves the statusline, and the toasts helper waits for a marker message instead of a fixed 50 ms.
- Every test fails against a do-nothing module (36 of 36), and each of 27 sibling wrong implementations (one bug
  each: routine errors ignored, a typed command's output not measured as a whole, wrapped rows not counted, showcmd
  showing every key, the title ignoring the cursor, no early replay, blink's column off by one, quiet kinds shown,
  no block-mode drop, `/` in the popup, the switch ignored, a failed hook kept, info or errors not merged, no history
  fallback, history oldest first, 'showcmdloc' kept "last" while off, ui2 on but nothing hooked; and from the review:
  the options ignored, the `ui2` option ignored, every progress message dropped, a failing popup kept, the cmdline
  and messages ignoring the buffer switch, pending keys following it, the pending-keys hook unguarded, `showcmd()`
  without `%S`; and from the second review: a count kept shown after a switch off) fails at least one test, on nightly. They're kept outside the repo, as `docs/decisions/neoblocks.md` 3 says.
- Seen once: `input('')`, `<Esc>`, then `confirm()` answered with `n` and `:` typed at once left `:` at the bottom on
  nightly, 3 runs of 3 in one test; the same keys in a separate child passed, so the test was split
  in two. Not explained. Also seen: blink's position not cleared within 5 s of a lone `<Esc>` sent to close the popup,
  in 2 of 5 `check:all` runs (which run the checks in parallel), then not in the next 3; that test closes the cmdline
  with `<C-c>` now, a single byte the TUI needn't time out. Not explained either.

## 9. Cost

`bench/messages.lua` runs noice (nvim-config's presets, `07d2b9a~1:nvim/lua/plugins/noice.lua` in nvim-config), this
module and plain ui2, each in its own child with a UI and snacks.notifier, 3 runs per side per round, interleaved,
5 rounds. It measures the child's CPU time over keys and messages sent from a timer, so drawing and the terminal
output count, as they do when typing. By D61 (nvim-config's rule: real when the rounds agree, felt when a keystroke
crosses one 8.3 ms frame or an event ~100 ms):

Run on 2026-10-18 at a76157c, noice.nvim 7bfd942, nui.nvim 10fc361, snacks.nvim 882c996, with
`systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=512M -- nvim --clean --headless -l
bench/messages.lua ~/.local/share/nvimt/lazy 5` (the `nvim` on PATH, v0.13.0-dev-1868). Not rerun after the review fixes: on the
per-key path they add one `pcall` around the pending-keys update per `msg_showcmd` and nothing else. Median µs of CPU per operation over 15 runs per
side; the last column counts the rounds where this module's median was lower than noice's:

| µs             | noice | neoblocks | plain ui2 | rounds lower |
|----------------|------:|----------:|----------:|-------------:|
| cmdline key    |  1158 |       730 |       410 |       5 of 5 |
| normal key     |   210 |       251 |       176 |       0 of 5 |
| 2j             |   325 |       465 |       272 |       0 of 5 |
| message        |  3688 |      3134 |       519 |       3 of 5 |
| long message   |  1083 |      1001 |       957 |       3 of 5 |

- Per keystroke (8.3 ms a frame): a key in the popup costs about 430 µs less than noice's, every round. A normal
  key costs about 40 µs more and `2j` about 140 µs more, every round: real, and at most 5% of a frame, so not felt.
  Logged, not acted on (D61). The extra is ui2's: with 'showcmdloc' "last", which the hook needs to see the keys, ui2
  gets a `msg_showcmd` per key and redraws at once for a non-empty one (`R/ui2.lua:162-174`); plain ui2 here keeps
  'showcmdloc' "statusline".
- Per message (an event, ~100 ms): a toast costs about 0.5 ms less than noice's, 3 rounds of 5; the split costs the
  same within the noise (3 of 5). Both are snacks' drawing for the most part (plain ui2
  shows the message for about 0.5 ms).
- Checked in each run: the cmdline held the typed text, `2j` reached line 200, a toast was on screen after the
  messages, and the long messages opened a split, for both noice and this module.

## Known differences from noice

The config's list (`docs/ui2-noice-parity-decisions.md`, "Known differences from noice") still holds: `:lua `,
`:help ` and prompts stay visible; blink's labels sit one cell right of the typed text; long `:!` output shows when it
ends; errors in a typed command's split output aren't sticky toasts; `confirm()`, `:s///c`, `:messages` and `g<` use
ui2's windows; icons need a Nerd Font.

## Probes

- `cmdline_show` arguments, from a wrapper around ui2's that logged them in a child with a TUI: `:` `hl_id = -1`, `/`
  `-1`, `input('Name: ')` `0`, `confirm()` `10` in mode `r?`, `vim.ui.input({ prompt = 'P> ' })` `0`; `prompt` a
  string in all of them.
- `vim.o.columns, vim.o.lines = 120, 40` in the headless test runner, then a 120x36 float holding a terminal job: the
  child's `&columns`/`&lines` are 120 and 36.
- A count waiting for its motion blocks the child's timers: a timer sending `2`, then `j` from its next tick, never
  sent the `j` (the bench's first version hung there), as the config's `showcmd.lua` comment says.
