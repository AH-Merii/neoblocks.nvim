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

## 3. Text is statusline format; what the module reads from outside is escaped

- A function's text and a raw string go in as is, like lualine (parity 5): the config's path brings its own `%#...#`
  groups, location and progress are `%l`-style items, pending keys are `%{...}` or `%S`. Escaping them would break
  all of these.
- Built-ins escape the `%` in what they read: branch names (lualine does, parity 7), progress text.

## 4. Colours: NeoblocksStatusline* groups over StatusLine

- `color` is a highlight group name, a table of `nvim_set_hl()` attributes (`{ fg = "#e5c07b", bold = true }`), or a
  function returning either, called on each rebuild (the mode colour). The top-level `color` is the default text
  colour, for parity 2; without it components use StatusLine's.
- Every group the module writes into the line is a `NeoblocksStatusline*` group it defines (a table gets its own, a
  group name gets one linked to it). They set no background, and Neovim combines statusline groups with StatusLine
  (`nvim_eval_statusline` reports `groups = { "StatusLine", "Foo" }` for `%#Foo#`, probe below), so the background is
  StatusLine's: transparent with the user's colourscheme, as lualine's `guibg=None` groups are today.
- Not lualine's `nocombine`: with it a group drops StatusLine's background; with the user's StatusLine there is none,
  so it shows the same.
- A colourscheme clears the groups; the module defines them again on ColorScheme.
- `mode_color(colors, fallback)` returns a colour function for the config's mode icon (parity 4): `colors` keyed by
  `mode()`'s first letter.

## 5. Rebuilt on events, once per loop tick; no timer

- The line is built in Lua and stored in `'statusline'` only when something changes: the `events` list (lualine's
  defaults without CursorMoved/CursorMovedI, as the config's list, `:298-310`), the events each built-in in use needs
  (decisions 7-11), and `refresh()`.
- Events mark the line stale and schedule one rebuild (`vim.schedule`): several events in one tick cost one build,
  and the config's own handlers for the same event (its LSP / formatter / linter caches, `:154-156`) have run first.
  lualine gets the same from its 16 ms queue (`lualine.lua:370-376`); a scheduled callback runs sooner.
- `refresh()` rebuilds at once, for the config's ToolsChanged handler (`:158-164`) and for tests.
- No timer. lualine's 1 s timer (parity 12) covered:
  - LSP names after LspAttach/LspDetach (the config's cache updates, `:154`, but those aren't refresh events): the
    config adds LspAttach and LspDetach to `events`;
  - the file path's width budget after a window resize without VimResized: the config adds WinResized;
  - the branch after a checkout outside Neovim: the module watches HEAD (decision 8);
  - the search count after `:nohlsearch`: drawn as an expression (decision 6).
- **To decide (user):** keep it timer-free, or add an `interval` option for anything else the timer caught.

## 6. What follows the cursor is left to Neovim

- Location and progress are the config's statusline expressions (parity 5); Neovim evaluates them on each draw, and
  the module never rebuilds on CursorMoved.
- searchcount: the count is computed on CursorMoved/CursorMovedI only while `v:hlsearch` is 1 (the config's rule,
  parity 10) and stored; only it is updated, not the whole line, so a move with a search highlighted costs one
  `searchcount()`, where lualine rebuilt everything. It's drawn through an expression that shows it only while
  `v:hlsearch` is 1, so `:nohlsearch` hides it at the next draw with no event. Options `maxcount` (999) and `timeout`
  (500), as lualine.

## 7. diagnostics

- `vim.diagnostic.count(0)`, error / warn / info / hint, counts above 0, `symbol .. count` in the severity's colour,
  joined by a space (parity 6). Rebuilt on DiagnosticChanged.
- `symbols` and `colors` are merged per severity over the defaults, so the config's three keep hint's default:
  lualine's icons (`diagnostics/config.lua:7-12`) and the Diagnostic* groups.
- `update_in_insert = false`: in Insert mode the counts stay as they were when it started, as lualine (parity 6).

## 8. branch: read HEAD ourselves, not gitsigns'

- Found upward from the buffer's folder (the cwd for a buffer with no name), following a `.git` file (worktrees,
  submodules), as lualine (parity 7); the folder → git dir lookup is cached. The name is everything after
  `refs/heads/`, or the first 6 characters of a detached hash (lualine). `%` escaped.
- HEAD is watched with `vim.uv` fs events; a change rebuilds the line.
- Not gitsigns' `b:gitsigns_head`: after a branch switch gitsigns sets it to the ref's last path component
  (`gitsigns/git/repo.lua:53-57,170`), so `feat/statusline` would show as `statusline`; on attach it uses
  `git rev-parse --abbrev-ref HEAD` (`repo.lua:263-273`), the full name. Reading HEAD is one small file read, no
  process.

## 9. diff: from gitsigns

- Counts from `b:gitsigns_status_dict` (`added`, `changed`, `removed`, `gitsigns/status.lua:24-39`), rebuilt on
  `User GitSignsUpdate`. gitsigns counts a changed hunk the same way as lualine (`gitsigns/hunks.lua:357-375`,
  `git_diff.lua:59-83`). Option names are lualine's: `symbols`/`colors` with `added`, `modified`, `removed`; default
  symbols `+ ~ -` and the Added / Changed / Removed groups (`$VIMRUNTIME/doc/syntax.txt:245-247`).
- Why: the user runs gitsigns on every buffer (nvim-config `plugins/git.lua:4`), so the counts are already computed;
  lualine starts a `git diff` process on every BufEnter and save (parity 8).
- What differs from lualine, **to decide (user)**:
  - unsaved changes count as you type (lualine: the saved file);
  - an untracked file shows all its lines as added, since the config has `attach_to_untracked = true`
    (`plugins/git.lua:65`); lualine shows nothing for it;
  - without gitsigns the component shows nothing (reading git ourselves is left out).

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

- `setup()` saves the global `'statusline'` and `'laststatus'`, sets `laststatus=3` and draws.
- A window-local `'statusline'` (the quickfix ftplugin's) is replaced while that window is current, as lualine (parity 12),
  and put back when the module is off.
- Off (`:Neoblocks statusline off`, `vim.g.neoblocks_statusline = false`, then `refresh()`): the saved values are
  restored. Off in one buffer: the saved statusline shows while that buffer is current.

## 14. Cost

- Per cursor move: nothing, or one `searchcount()` while a search is highlighted (decision 6). Per redraw: Neovim
  parses the stored string; the module runs no Lua unless a component's own expression does.
- **Implementation stage:** `bench/statusline.lua`, lualine with the config's setup against this module with the same
  components: time per `j` (CursorMoved + redraw), per redraw, and per rebuild. Numbers go here.

## Probes

Run with `nvim --clean --headless -l` on 0.12.6 and nightly:

- `nvim_eval_statusline("%#Foo#a%*b", { highlights = true })` with Foo defined: `groups = { "StatusLine", "Foo" }`.
- RecordingLeave callback: `reg_recording()` returns `a`.
- `nvim_echo({{"working"}}, false, { kind = "progress", source = "test", status = "running", percent = 40 })`, then
  `vim.ui.progress_status()`: `"40%%(1) "` on 0.12.6, `"40%(1)"` on nightly.
- `:copen` in `--clean`: the window's `'statusline'` is the ftplugin's `%t%{exists('w:quickfix_title')...`.
