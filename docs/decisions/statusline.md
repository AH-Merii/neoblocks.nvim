# statusline: decisions

The `statusline` module replaces [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for one config: AH-Merii/nvim-config's
`nvim/lua/plugins/lualine.lua` (called "the config" below). Read against lualine.nvim 47f91c4, gitsigns.nvim abf82a6,
nvim-config 2d8ff5b and Neovim 0.12.6 / 0.13-dev on 2026-10-14. lualine paths are under `lua/lualine/`; config paths are
`plugins/lualine.lua:<line>` unless named.

## What the config gets from lualine today (the parity target)

1. **One global statusline**, no separators, everything in sections c (left) and x (right), a/b/y/z empty
   (`plugins/lualine.lua:292-294,316-323`). lualine sets `laststatus=3` (`lualine.lua:539-540`) and joins the sections as
   `%<` + c + `%=` + x (`lualine.lua:170-177`). The config puts its own `'%='` component in c (`:381`), so the line has
   three parts: left, a centred group, right.
2. **Text colour** `#abb2bf` with no background: the theme sets only c's fg (`:311-314`); lualine makes every group with
   `guibg=None gui=nocombine` (`highlight.lua:142-155`). The colourscheme clears StatusLine's background
   (`plugins/colorschemes.lua:37`). The config's `colors` are always its fallback hexes: `require("onedark.palette")` is
   keyed by style (`onedark.nvim/lua/onedark/palette.lua:1-2`), so `c.fg` etc. are nil (`:2-17`). StatusLine's own fg is
   the deep style's `#93a4c3` (`palette.lua`, `onedark/highlights.lua:92`), so the text colour must be set, not inherited.
3. **How a component draws** (`component.lua:271-295`): nothing at all when `cond()` isn't true or the text is empty
   (no icon, no padding); otherwise `icon .. " " .. text` (`:170`), then padding, one space each side by default, the
   left one after a `%#Group#` the text starts with and the right one before a closing `%*` (`:97-115`); a
   table that names one side pads only that side (`:86-116`); the colour group in front, and the section's group again
   after a component that changed colour (`:119-138`); a click wraps the padded text (`:211-215,258-260`).
4. **Mode-coloured icon** `` (`:340-357`): fg from `vim.fn.mode()`'s first letter (n i v V c s S R t), red for any
   other (e.g. CTRL-V); right padding only; rebuilt on ModeChanged (`:307`).
5. **The config's own components, given as functions**: file path with its own `%#Lualine*#` groups (`:169-260,359-362`,
   cond `buffer_not_empty`); location `%3l:%-2{charcol('.')}` and progress `%{line('.') == 1 ? 'Top' ...}` as
   statusline expressions, so they follow the cursor with no rebuild (`:364-369`); cached LSP / formatter / linter
   lists with icons and bold colours (`:383-402`); the tools indicator, icon hidden when empty, click runs `:Tools`
   (`:404-411`); pending keys as `%{v:lua...}` or `%S` (`:461-466`), redrawn by `redrawstatus` from
   `config/ui2/showcmd.lua:55-58`. lualine inserts a function's text as is, unescaped (`component.lua:279-284`).
6. **diagnostics** (`:371-380`): `vim.diagnostic.count(0)`, the current buffer only (`components/diagnostics/sources.lua:35-44`);
   error, warn, info, hint in that order, counts above 0 only, each `symbol .. count` in its colour, joined by a space
   (`components/diagnostics/init.lua:86-108`). The config sets three symbols and colours; hint keeps lualine's default
   `󰌶 ` and DiagnosticHint's fg (`init.lua:25-30`, `diagnostics/config.lua:7-12,48-54`). Counts don't change in
   Insert mode (`update_in_insert = false`, `init.lua:57,75-76`). Rebuilt on DiagnosticChanged (`:308`).
7. **branch** (`:416-422`, icon ``, cyan bold, the config's own `cond`): lualine reads `HEAD` of the git dir found
   upward from the buffer's folder, following a `.git` file (`components/branch/git_branch.lua:70-135`); the name is
   everything after `refs/heads/` (`:26`, so `feat/statusline`), or the hash's first 6 characters when detached (`:30`);
   it watches `HEAD` (`:44`) and looks again on BufEnter (`:142`); `%` is escaped (`components/branch/init.lua:22`).
8. **diff** (`:423-433`, symbols `󰐖 󰦓 󰍵`, green/orange/red, the config's width `cond`): lualine runs
   `git -C <dir> diff -U0 -- <file>` on BufEnter and BufWritePost (`components/diff/git_diff.lua:26-27,94-106`), so it
   counts the saved file against the index; a changed hunk counts min(added, removed) as modified and the rest as
   added or removed (`:59-83`); nothing when all are 0 or the file isn't in git (`components/diff/init.lua:86-90`,
   `git_diff.lua:112-118`).
9. **progress** (`:434-442`): `vim.ui.progress_status()`, `%` escaped by the config, icon `󰔟`, violet, rebuilt on
   Progress. On 0.12.6 the function already returns escaped text with a trailing space, `40%%(1) `
   (`$VIMRUNTIME/lua/vim/ui.lua:382`); escaped again it shows as `40%%(1)`. Nightly returns `40%(1)`.
10. **searchcount** (`:443-455`): `[current/min(total, 999)]`, timeout 500 ms, nothing while `v:hlsearch` is 0
    (`components/searchcount.lua:3-29`); the config rebuilds on CursorMoved/CursorMovedI while `v:hlsearch` is 1.
    After `:nohlsearch` (`<Esc>`, `config/keymaps.lua:70`) nothing rebuilds; lualine's 1 s timer drops the count.
11. **macro recording** (`:456-460,274-285`): ` @a` (U+F03D, then ` @`), yellow bold, refreshed on
    RecordingEnter/RecordingLeave. During RecordingLeave `reg_recording()` still returns the register (probe below);
    lualine's refresh lands up to 16 ms later (`lualine.lua:370-376,514-528`), by when it's empty.
12. **When it rebuilds**: the config's events (`:298-310`), queued and applied every 16 ms (`lualine.lua:370-376,514-528`);
    a 1 s timer (`config.lua:24`, `lualine.lua:541-548`); a full reload on ColorScheme (`lualine.lua:279-280`). It
    writes the current window's `'statusline'` (`lualine.lua:426-437`), replacing a window-local one such as the
    quickfix ftplugin's.

Cost: lualine took about 1.8 ms per `j` while it rebuilt on CursorMoved (nvim-config `docs/profiling-scrolling.md:77`);
dropping CursorMoved saved 0.8 ms of the 9.6 ms per `j` (`profiling-scrolling.md:105-107`).

Left out, since the config doesn't use them: sections a/b/y/z, separators and transitional separators, themes beyond
one fg, inactive sections and per-window statuslines (the line is global, so lualine never draws the empty inactive
one), tabline, winbar, extensions, `disabled_filetypes`, `ignore_focus`, `fmt`, `draw_empty`, the mode-name, filename,
filetype, encoding, fileformat, location, progress, lsp_status, buffers, tabs, windows and selectioncount components,
diagnostic sources other than `nvim_diagnostic`, `always_visible`, `colored = false`, icon tables (`align`, icon
colour), cterm colours.

## 1. One global statusline, two lists

- `left` and `right` are lists of components, drawn as `left .. "%=" .. right` in the default colour, with
  `laststatus=3`. A `"%="` entry in `left` makes the centred group, as the config's (parity 1).
- Only a global statusline: the config uses nothing else (parity 1), and it needs no inactive or per-window builds.

## 2. Components draw as lualine's

- A component is a function returning statusline text, a raw statusline string starting with `%` (e.g. `"%="`,
  `"%3l:%-2c"`), a built-in name, or a table: `{ <one of those>, icon?, color?, cond?, on_click?, padding? }` plus
  the built-in's own options.
- The parity 3 rules exactly: empty or `cond` not true draws nothing, not even padding or icon; `icon .. " " .. text`;
  `padding` 1 each side by default, a number for both, a table pads only the sides it names; the colour group goes in
  front of the padded text, so the icon takes the component's colour (`component.lua:285-290`). The config keeps its
  spacing without changes: its `padding = { right = 1 }` icon stays as it is.
- A string that isn't a built-in and doesn't start with `%` is a mistake (a mistyped built-in): `setup()` reports it
  as an error and the rest draws.
- A component that errors draws nothing and the rest still draws (lualine retries and gives up,
  `utils/utils.lua:178-182`). The error is reported once, not on every rebuild.
- The same for a component whose text isn't valid statusline syntax (a stray `%`, an unclosed `%{` or `%(`), e.g. the
  config's file path in a folder with `%` in its name (`:183-259` puts the path in unescaped). `'statusline'` rejects
  the whole line (E539/E540/E542), so when it does, each component's piece is checked with `nvim_eval_statusline()`,
  which rejects the same text with no side effects, and the bad ones are left out of that rebuild. Checking only after
  a rejection keeps the usual rebuild free of it. lualine sets the option unchecked (`utils/nvim_opts.lua:105-110`), so
  its line stops updating and the error comes back on every refresh.
- A lone `%` at the end of a component's padded text (`"100%"` with `padding = 0`) is the one mistake the line doesn't
  reject: it escapes the `%` of the colour or click the module writes after it, so `100%%#NeoblocksStatusline#` showed
  the group's name. It is checked for in each component's text (one `match` on its end) and handled as the others.

## 3. Text is statusline format; what the module reads from outside is escaped

- A function's text and a raw string go in as is, like lualine (parity 5): the config's path brings its own `%#...#`
  groups, location and progress are `%l`-style items, pending keys are `%{...}` or `%S`. Escaping them would break
  all of these.
- Built-ins escape the `%` in what they read: branch names (lualine does, parity 7), progress text.

## 4. Colours: NeoblocksStatusline* groups over StatusLine

- `color` is a highlight group name, a table of `nvim_set_hl()` attributes (`{ fg = "#e5c07b", bold = true }`), or a
  function returning either, called on each rebuild (the mode colour). The top-level `color` is the default text
  colour, for parity 2; without it components use StatusLine's.
- Not lualine's `gui = "bold"` (`highlight.lua:113-114`): the config's seven become `bold = true`. A table
  `nvim_set_hl()` rejects is reported once and its component drawn in the default colour (the top-level one rejected:
  StatusLine's), so `setup()` doesn't stop halfway, and neither do the modules set up after it (decision 2).
- Every group the module writes into the line is a `NeoblocksStatusline*` group it defines (a table gets its own, a
  group name gets one linked to it). They set no background, and Neovim combines statusline groups with StatusLine
  (`nvim_eval_statusline` reports `groups = { "StatusLine", "Foo" }` for `%#Foo#`, probe below), so the background is
  StatusLine's: transparent with the user's colourscheme, as lualine's `guibg=None` groups are today.
- A table with no `fg` (`{ bold = true }`) takes the top-level colour's fg, as lualine fills a missing fg from the
  section's colour (`highlight.lua:281-308`). The group is drawn over StatusLine, so without the fill the text would
  take StatusLine's fg (`#93a4c3` with the user's colourscheme, parity 2). With no top-level colour there is nothing to
  fill and StatusLine's fg is the default one anyway.
- After a component whose text has any `%` item the line goes back to the default colour, since `%#Group#`, `%1*`
  and `%*` all change it. lualine starts each component in the section's colour (`component.lua:133-136`), so a
  colour change never reaches the next component or the fill.
- Not lualine's `nocombine`: with it a group drops StatusLine's background; with the user's StatusLine there is none,
  so it shows the same.
- A colourscheme clears the groups; the module defines them again on ColorScheme, the default one first, so a filled
  fg follows a top-level colour that is a group name.
- `mode_color(colors, fallback)` returns a colour function for the config's mode icon (parity 4): `colors` keyed by
  `mode()`'s first letter.

## 5. Rebuilt on events, at most once per 16 ms; no timer

- The line is built in Lua only when something changes: the `events` list (lualine's defaults without
  CursorMoved/CursorMovedI, as the config's list, `:298-310`), the events each built-in in use needs (decisions
  7-11), and `refresh()`. A `User` event isn't an `events` entry: the config's ToolsChanged handler calls `refresh()`
  (`:158-164`).
- Events mark the line stale and schedule one rebuild, after the config's own handlers for the same event (its LSP /
  formatter / linter caches, `:154-156`). After a quiet spell it runs on the next loop tick (`vim.schedule`), so the
  mode colour changes at once; within 16 ms of the last rebuild it waits until 16 ms have passed. A burst of events in
  separate ticks (progress messages, which the config turns into Progress events, nvim-config
  `config/autocmds.lua:172-189`; GitSignsUpdate on each edit) costs one rebuild per 16 ms, as lualine's queue
  (`lualine.lua:370-376,514-528`). A scheduled callback alone isn't enough: 500 progress messages one per ms gave 500
  rebuilds and 500 writes with it, against lualine's 36 writes; with the 16 ms cap, 37 rebuilds and 36 writes, on
  0.12.6 and nightly (probe below).
- `'statusline'` is written only when the text differs from what's there (lualine too, `utils/nvim_opts.lua:36-38`):
  a write fires OptionSet and redraws the status line.
- While the command line is open Neovim doesn't redraw the status line, so a write then is followed by
  `:redrawstatus`, as lualine (`utils/nvim_opts.lua:63-66`). Without it the mode icon kept Normal's colour after `:`.
- `refresh()` rebuilds at once, for the config's ToolsChanged handler (`:158-164`) and for tests.
- A name in `events` that isn't an event (`WinResize` for `WinResized`) is reported and the rest set up, as other
  config mistakes (decisions 2 and 4): `nvim_create_autocmd()` raises for it, which stopped `setup()` before its
  ColorScheme handler and first draw.
- No timer. lualine's 1 s timer (parity 12) covered:
  - LSP names after LspAttach/LspDetach (the config's cache updates, `:154`, but those aren't refresh events): the
    config adds LspAttach and LspDetach to `events`;
  - the file path's width budget after a window resize without VimResized: the config adds WinResized;
  - the branch after a checkout outside Neovim: the module watches HEAD (decision 8);
  - the search count after `:nohlsearch`: drawn as an expression (decision 6);
  - the search count after anything that changes it without moving the cursor: `*` or `n` on the only match, a new
    `@/`, an edit. SafeState follows each of these (decision 6).
- Decided with the user (2026-10-16): no timer and no `interval` option; the config lists the events it needs.

## 6. What follows the cursor is left to Neovim

- Location and progress are the config's statusline expressions (parity 5); Neovim evaluates them on each draw, and
  the module never rebuilds on CursorMoved.
- searchcount: the count is computed on CursorMoved/CursorMovedI only while `v:hlsearch` is 1 (the config's rule,
  parity 10) and stored in a `g:` variable; only it is updated, not the whole line, where lualine rebuilt everything.
  It's drawn through an expression, `%{v:hlsearch ? get(g:, ...) : ''}`, so `:nohlsearch` hides it at the next draw
  with no event. It counts up to 999 matches and stops after 500 ms, lualine's defaults
  (`components/searchcount.lua:3-6`); the config sets neither, so they aren't options.
- A count runs only when what it depends on changed since the last one: `v:hlsearch`, `@/`, the buffer, its
  `changedtick`, the window or the cursor. A rebuild and a move in the same tick, which `A`, `o` or a window switch
  give (ModeChanged or WinEnter, and CursorMoved), count once; lualine's single queue merges them into one refresh
  (`lualine.lua:370-376,500-512`). A rebuild with none of them changed reuses the count.
- A count on a cursor move waits until 16 ms after the last count, as the config's refresh waits for lualine's 16 ms
  queue (`plugins/lualine.lua:445-451`, `lualine.lua:370-376,514-528`). A scroll animation moves the cursor every
  10 ms (nvim-config `docs/profiling-scrolling.md`), and in a large file `searchcount()` is most of what a move costs:
  counting on every move took 20 counts per scroll against lualine's 13 (decision 14). A rebuild counts at once, if
  anything changed, since it runs at most once per 16 ms itself (decision 5); `refresh()` isn't capped.
- When a count changed and the line's text didn't, the module runs `:redrawstatus`, since Neovim doesn't redraw for a
  `g:` variable; this holds for a rebuild's count too. Without it a window switch showed the other window's count:
  Neovim drew the line before the WinEnter rebuild counted.
- What changes the count without a move is caught on SafeState, which Neovim fires after each command and callback
  when it's about to wait for input (`:h SafeState`; a probe shows it after a `*` that doesn't move, in Insert mode
  and after each timer callback). The handler compares `v:hlsearch`, `@/`, the buffer and its `changedtick` with
  those of the last count and only counts when one differs, so a key that changes none of them costs four reads.
  lualine's 1 s timer caught these cases a second late; SafeState catches them at once, with no timer.
- The expression is in the line only while a search is highlighted: Neovim evaluates it on every draw (1.6 to 1.75 µs
  more than literal text, probe below), so a count that finds `v:hlsearch` 1 or 0 puts it in or takes it out by
  joining the line's stored parts again, with no component called.
- Its icon and padding are outside the expression, in a `%( %)` group: a `%{}` result's spaces are drawn as fill
  characters (probe below), and the group is left out while the count is empty.

## 7. diagnostics

- `vim.diagnostic.count(0)`, error / warn / info / hint, counts above 0, `symbol .. count` in the severity's colour,
  joined by a space (parity 6). Rebuilt on DiagnosticChanged.
- `symbols` and `diagnostics_color`, lualine's names (`components/diagnostics/init.lua:34-37`), are merged per
  severity over the defaults, so the config's three keep hint's default: lualine's icons (`diagnostics/config.lua:7-12`)
  and the Diagnostic* groups.
- In Insert mode the counts stay as they were when it started, as lualine's default `update_in_insert = false`
  (parity 6). The config doesn't change it, so it isn't an option.

## 8. branch: read HEAD ourselves, not gitsigns'

- Found upward from the buffer's folder, following a `.git` file (worktrees, submodules), as lualine (parity 7). A
  terminal's folder is the one in its name, `term://<dir>//<pid>:<cmd>`, as lualine (`git_branch.lua:91-94`). A buffer
  whose name isn't a path (none, or a URI such as `health://`) takes the cwd's repo: walking up from the name's
  "folder" would give a path relative to the cwd, and caching it would show another repo's branch after a `:cd`.
- A folder's git dir is cached once found, as lualine caches only what it finds (`components/branch/git_branch.lua:130`).
  Outside a repo the lookup walks every folder up to `/` (16 `fs_stat` calls and about 30 µs for a file 9 folders
  deep, review probe), so it runs again only for another buffer or folder, or on `refresh()`: lualine walks again on
  BufEnter (`git_branch.lua:137-143`), not on each refresh. A `git init` shows after a buffer switch, a `:cd` for a
  buffer with no name, or `refresh()`. The built-in rebuilds on DirChanged, which the config's events lack.
- The name is everything after
  `refs/heads/`, or the first 6 characters of a detached hash (lualine). `%` escaped.
- HEAD is watched with `vim.uv` fs events; a change rebuilds the line.
- Not gitsigns' `b:gitsigns_head`: after a branch switch gitsigns sets it to the ref's last path component
  (`gitsigns/git/repo.lua:53-57,170`), so `feat/statusline` would show as `statusline`; on attach it uses
  `git rev-parse --abbrev-ref HEAD` (`repo.lua:263-273`), the full name. Reading HEAD is one small file read, no
  process.

## 9. diff: from gitsigns

- Counts from `b:gitsigns_status_dict` (`added`, `changed`, `removed`, `gitsigns/status.lua:24-39`), rebuilt on
  `User GitSignsUpdate`. gitsigns counts a changed hunk the same way as lualine (`gitsigns/hunks.lua:357-375`,
  `git_diff.lua:59-83`). Option names are lualine's: `symbols`/`diff_color` (`components/diff/init.lua:41,52-54`) with
  `added`, `modified`, `removed`; default
  symbols `+ ~ -` and the Added / Changed / Removed groups (`$VIMRUNTIME/doc/syntax.txt:245-247`).
- Why: the user runs gitsigns on every buffer (nvim-config `plugins/git.lua:4`), so the counts are already computed;
  lualine starts a `git diff` process on every BufEnter and save (parity 8).
- What differs from lualine, accepted by the user (2026-10-16):
  - unsaved changes count as you type (lualine: the saved file);
  - an untracked file shows all its lines as added, since the config has `attach_to_untracked = true`
    (`plugins/git.lua:65`); lualine shows nothing for it;
  - without gitsigns the component shows nothing and `:checkhealth` warns, also for a gitsigns installed but not
    loaded yet (it ships `lua/gitsigns.lua`); reading git ourselves, as a fallback, is left out.
- Switching branches (outside Neovim) and worktrees keeps the counts right with no work here: gitsigns watches the
  git dir and recounts (`gitsigns/git/repo.lua:167-172`, `attach.lua:373-375`), then fires GitSignsUpdate.

## 10. progress_status

- `vim.ui.progress_status()`, rebuilt on Progress. Made the same on both versions: 0.12.6's `%%` is turned back into
  `%`, the trailing space trimmed, then `%` escaped, so it shows `40%(1)` (parity 9; the config shows `40%%(1)` on
  0.12.6 today).
- `setup()` calls `progress_status()` once: it starts tracking Progress events only on its first call
  (`$VIMRUNTIME/lua/vim/ui.lua:341-363,391-392` on 0.12.6), so a progress message before the first draw would be missed.

## 11. recording

- `@` and the register, rebuilt on RecordingEnter/RecordingLeave; the rebuild runs after RecordingLeave is over
  (decision 5), when `reg_recording()` is empty (parity 11). The config's leading ``
  becomes `icon = ""`, which keeps its text and spacing (checked live, `[3/5]  @q` drawn the same).

## 12. Clicks

- `on_click(clicks, button, mods)`, lualine's arguments (`utils/fn_store.lua:29-31`), around the padded text as
  lualine (parity 3), through `%<id>@v:lua...@...%T`.

## 13. On and off

- Switching on (`setup()`, or on after off) saves the global `'statusline'` and `'laststatus'` in place at that
  moment, sets `laststatus=3` and draws. Saving at each switch-on keeps what the user set while the module was off.
- A window-local `'statusline'` (the quickfix ftplugin's) is replaced while that window is current, as lualine (parity 12),
  and put back when the module is off.
- Off (`:Neoblocks statusline off`, `vim.g.neoblocks_statusline = false`, then `refresh()`): the saved values are
  restored. Off in one buffer: the saved statusline shows while that buffer is current.

## 14. Cost

- Per cursor move: nothing, or one `searchcount()` at most every 16 ms while a search is highlighted (decision 6).
  Per redraw: Neovim parses the stored string; the module runs no Lua unless a component's own expression does.
- `bench/statusline.lua` draws the config's statusline (its components, colours, events and conds) with lualine
  and with this module, each in its own `nvim --clean` in a scratch git repo with a changed file, six diagnostics and
  a search with 56 matches in 400 lines. It checks that both draw the same text. The config's components (file path,
  conds) are the same functions in both. lualine's diff counts come from its own `git diff`, this module's from a
  `b:gitsigns_status_dict` holding the same counts. Two changes, both the same for each: headless windows are 80
  columns whatever `'columns'` says, so the diff's width cond is `> 60` instead of `> 80`. The config's CursorMoved
  refresh is the config's, unforced, so it waits for lualine's 16 ms queue; the two search-on move rows therefore make
  their moves from a timer in the event loop, where that queue and this module's cap run.
- Run on 2026-10-14 (after the third review's fixes), lualine.nvim 47f91c4, with
  `systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 -- nvim --clean --headless -l bench/statusline.lua`
  (and `mise exec neovim@nightly --` before `nvim` for nightly). Median µs per operation over 7 rounds:

  | µs per op                 | lualine 0.12.6 | neoblocks 0.12.6 | lualine nightly | neoblocks nightly |
  |---------------------------|---------------:|-----------------:|----------------:|------------------:|
  | rebuild                   |          192.0 |             95.6 |           196.0 |              92.8 |
  | of which config           |           57.4 |             55.9 |            55.2 |              55.5 |
  | redraw                    |           26.0 |             25.2 |            28.5 |              28.3 |
  | j                         |           79.1 |             78.4 |            57.1 |              56.4 |
  | rebuild, search on        |          268.4 |             94.4 |           262.3 |              92.0 |
  | redraw, search on         |           27.5 |             29.0 |            29.6 |              32.0 |
  | j, search on, 40 ms apart |          932.9 |            436.4 |           907.7 |             395.3 |
  | scroll frame, search on   |         2785.9 |           2532.2 |          2570.5 |            2352.9 |

  - rebuild: what an event costs. Without the config's own functions, about 37 to 40 µs for this module against 135
    to 141 µs for lualine. That is also what lualine paid per `j` while it rebuilt on CursorMoved. Both skip writing an
    unchanged line (decision 5), as each rebuild here gives the same text.
  - redraw (`:redrawstatus`) and `j` (`normal! j`, CursorMoved, redraw) vary by about ±3 µs between runs. With no
    search highlighted, this module is level or lower.
  - With a search highlighted, a redraw costs about 4 µs more here, against 1 to 2 µs more for lualine: the
    `v:hlsearch` expression is 1.6 to 1.75 µs per draw (probe below), and the rest is within the noise. In the
    rebuild rows, `searchcount()` over 400 lines is about 70 µs. lualine counts on each rebuild; this module counted
    on the first and reused it, since the cursor and the search didn't change between rebuilds (decision 6). Before
    that it also counted on each one: 155.8 µs on 0.12.6.
  - The two move rows with a search on are CPU time per move, the moves made from a timer 40 ms or 10 ms apart, each
    followed by CursorMoved, a redraw and SafeState, and include what each one's timers cost meanwhile. At 40 ms
    (key repeat, 400 lines) both count once per move; a move costs half as much here, since the config rebuilt all
    of lualine on each one. The scroll frame row is 20 moves 10 ms apart in a 50 000-line file with 500 matches,
    where `searchcount()` is most of the cost: both make 13 counts per scroll and the rows are level within their
    noise (three more nightly runs before the third review's fixes: lualine 2559, 2485, 2414; neoblocks 2275, 2244,
    2329). A move in the same tick as a rebuild (`A`, `o`) has no row: the spec checks it counts once. Before the
    16 ms cap this
    module counted on every move: the same bench on that code gave 20 counts per scroll and 3086 µs per frame
    against lualine's 2829 on 0.12.6.

## Probes

Run with `nvim --clean --headless -l` on 0.12.6 and nightly:

- `nvim_eval_statusline("%#Foo#a%*b", { highlights = true })` with Foo defined: `groups = { "StatusLine", "Foo" }`.
- RecordingLeave callback: `reg_recording()` returns `a`.
- `nvim_echo({{"working"}}, false, { kind = "progress", source = "test", status = "running", percent = 40 })`, then
  `vim.ui.progress_status()`: `"40%%(1) "` on 0.12.6, `"40%(1)"` on nightly.
- `:copen` in `--clean`: the window's `'statusline'` is the ftplugin's `%t%{exists('w:quickfix_title')...`.
- `nvim_eval_statusline("a%{g:x}b", { fillchar = "~" })` with `g:x = " [2/3] "`: `"a~[2/3]~b"`; `%{%g:x%}` too. In
  `"a%( I %{g:x} %)b"` the group is left out when `g:x` is `""`: `"ab"`. Same on 0.12.6 and nightly.
- `nvim_eval_statusline` 5000 times, median of 7 rounds: `%#A# [13/56] %#B#` 0.51 µs (nightly 0.55),
  `%#A#%( %{v:hlsearch ? get(g:, 'x', '') : ''} %)%#B#` 2.13 µs (nightly 2.30). Three groups in a row 0.56 µs
  against one 0.49 µs.
- SafeState (an autocmd counting its calls, run in a child's main loop): fires 2 times after a `*` that doesn't
  move the cursor, once after each of 10 timer callbacks (11 on nightly), and in Insert mode.
- In a headless `nvim --clean`, `:redrawstatus` evaluates the statusline (a `%{v:lua...}` counter goes up), and
  `winwidth(0)` stays 80 after `set columns=200`.
- `nvim_input("d")`: ModeChanged reports `no`, `mode()` returns `n`.
- `vim.go.statusline = s` and `nvim_eval_statusline(s, {})` reject the same text with the same error: `50%x done`
  (E539), `%{` (E540), `%(` (E542), `a%` (E539); `%#Foo` and `%1@x@a` pass both.
- Progress burst (`fix/progress_fix.lua` in the scratch dir, from the review's `probe/progress.lua`): 500
  `nvim_echo(..., { kind = "progress" })`, one per ms, counting OptionSet on `statusline`. lualine (Progress
  refreshing it, as the config): 36 writes. This module: 37 rebuilds, 36 writes.
