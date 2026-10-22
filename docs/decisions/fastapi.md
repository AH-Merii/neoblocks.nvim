# fastapi: decisions

The `fastapi` module is the route search of [fastapi-vscode](https://github.com/fastapi/fastapi-vscode) ("the
extension" below), ported to Neovim: its analyzer, read at 39e5382 on 2026-10-22, with a picker in place of its
path operation explorer. Paths below without a repo are the extension's `src/`. Checked on Neovim
v0.13.0-dev-1895 (nightly), snacks.nvim 882c996 and tree-sitter-python v0.25.0.

## 1. What's ported, and what isn't

- Ported: app discovery (`appDiscovery.ts`), the per-file extraction (`core/extractors.ts`, `core/analyzer.ts`),
  import resolution (`core/importResolver.ts`), the router graph (`core/routerResolver.ts`) and the full paths
  (`core/transformer.ts`, without the tree view's prefix grouping). `analyze.lua` is the extraction, `graph.lua`
  the discovery, imports and graph, and `init.lua` the API, the picker and what the docs are generated from.
- Not ported: FastAPI Cloud (deploy, logs, sign-in) and telemetry, which the user doesn't want; the explorer's tree
  view (2); the CodeLens links between test client calls and routes, which come in a later PR (the user's call on
  2026-10-22: the analyzer and picker first).
- The extension's test fixtures (`test/fixtures/`) are the model for `tests/fastapi_spec.lua`: the same layouts
  (package, re-export, namespace, src layout, factory, aliases, subclasses, mounts, multi-app), written inline.

## 2. A picker instead of the explorer

- Decided: one flat list of routes, `METHOD /path handler file:line`, sorted by the shown path then by method (GET,
  POST, PUT, PATCH, DELETE, OPTIONS, HEAD, WEBSOCKET, the extension's `METHOD_ORDER` in
  `vscode/pathOperationTreeProvider.ts`). The picker's fuzzy filter over method, path, handler and file does what
  the explorer's tree and its separate "Search Path Operations" quick pick (`extension.ts`, which also sorts by path)
  each did.
- Each explorer action has a picker equivalent: open the handler (`<CR>`, snacks' own jump), open the router's
  definition (the extension's "Go to Router", here `<a-g>`), copy the path (`<a-y>`, snacks' `yank` reading
  `item.data`: `snacks/picker/actions.lua:581-586`). `<a-g>` and `<a-y>` are keys snacks' input window doesn't bind
  (`snacks/picker/config/defaults.lua:225-275`); `<c-q>` to the quickfix list is snacks' own (`:255`).
- The source is named `fastapi_routes`, so a user changes its keys or layout in snacks' own options.
- Rejected: a tree view in a split (the extension's explorer). It's a second UI to maintain for what the filter
  already finds, and nothing else in the user's config is a sidebar tree.

## 3. snacks.nvim is optional; no command

- As for the messages history (`docs/decisions/messages.md` 2): snacks is found at runtime, never required. Without
  its picker, `pick()` offers the routes in `vim.ui.select()` and opens the chosen handler.
- No `:FastAPI` command: `plugin/neoblocks.lua` only defines `:Neoblocks`, and module features are called from a
  keymap (`Neoblocks.messages.history()` is the same).
- `:Neoblocks fastapi off` makes `pick()` refuse and say so. `routes()` is data and works either way, as
  `messages.entries()` does.

## 4. Python is read with tree-sitter

- Decided: Neovim's tree-sitter with the `python` parser, the parser the extension uses (`core/parser.ts`, through
  web-tree-sitter). It handles what a line scanner gets wrong: decorators over several lines, strings with `#` or
  brackets, comments between arguments.
- Neovim bundles no Python parser (its `lib/nvim/parser/` has c, lua, markdown, query, vim, vimdoc and a few more).
  The user's config installs one with nvim-treesitter; without one, `routes()` raises an error and `pick()` says how
  to install it, and `:checkhealth neoblocks` reports it.
- Tests: `mise run check:test` builds tree-sitter-python v0.25.0 from its release tarball, checked against the
  sha256 GitHub lists for that asset (`gh api repos/tree-sitter/tree-sitter-python/releases/tags/v0.25.0`), with the
  system C compiler (about a second), into `~/.cache/neoblocks/parsers/`, and passes the folder to the spec in
  `$NEOBLOCKS_TEST_PARSERS`. The runner itself stays offline (`docs/decisions/neoblocks.md` 3); CI's test job
  already downloads Neovim. Rejected: the release's `.wasm` parser, which needs a Neovim built with wasmtime;
  committing a built `.so`, a binary for one platform in the repo.
- Extraction runs one query over the node types the extension walks (`decorated_definition`, `assignment`, `call`,
  imports, `class_definition`), then the extension's logic on each in Lua.

## 5. Where it differs from the extension

Each was decided while porting, because the extension's result is wrong for FastAPI or for a flat list:

- Every app a file assigns is listed, not only its first FastAPI (`core/routerResolver.ts:46`): a file with two apps
  serves both. An app another app mounts or includes is listed under that app's path only; the extension lists a
  mounted app's file again as an app of its own.
- `api_route(..., methods=["PUT", "PATCH"])` is one route per method; the extension takes the first
  (`core/extractors.ts:242`).
- f-strings: `{BASE}` resolves like a constant, `{{` is `{`. The extension slices the f-string's text
  (`core/extractors.ts:128`), so `f"{BASE}/x"` stayed `{BASE}/x`.
- A route's line is its own decorator's. The extension gives each stacked decorator the line of the first
  (`core/extractors.ts:251`), so `@app.head` under `@app.get` jumped to the `get`.
- A namespace package (a folder without `__init__.py`) is looked for under `src/` too; the extension computes its
  folder from the project root only (`core/importResolver.ts:178`), though modules get the `src/` fallback (`:136`).
- A re-export under a new name (`from .router import router as api` in `__init__.py`) leads to `router` in
  `router.py`; the extension looks for a variable `api` there (`core/routerResolver.ts:404`, and the
  `buildRouterGraphInternal` call after it).
- Routers in one file that include each other end: the extension's local-router branch (`core/routerResolver.ts:334`)
  marks nothing visited, so two routers including each other in one file recurse forever.
- A `mount()` belongs to the app it's called on; the extension adds every mount in the file to the app
  (`core/routerResolver.ts:294`), which matters once a file's apps are all listed.
- `import a as b, c` binds two names, each its own import; the extension keeps the first module path for both
  (`core/extractors.ts:385`).
- An entrypoint, from the option or from pyproject.toml, that names no file or no app is an error naming it. The
  extension shows a warning for its setting and silently falls back for pyproject.toml (`appDiscovery.ts:138`).
- Hidden folders are skipped, besides the `exclude` names. The extension's list is `.venv`, `.git` and five others
  (`appDiscovery.ts:61`); `.tox`, `.nox` and `.mypy_cache` hold Python files no project serves.
- An unsaved buffer is read with its edits. The extension reads files from disk (`core/analyzer.ts:96`) and
  refreshes on a file watcher; here the picker is the only reader and is opened on demand.
- Not taken: the extension's last resort of the active editor's file when nothing calls `FastAPI(`
  (`appDiscovery.ts:218`). In a picker opened from anywhere, it would list a random file's router as an app.
- The project is the current directory, where VS Code has its workspace folders.

## 6. Reading a file once

- Each file's analysis is kept and used again while its version is the same: a loaded buffer's changedtick, else
  its mtime (seconds and nanoseconds) and size. The "calls FastAPI(" check that picks app files is kept the same
  way, so after the first pick only changed files are read.
- `bench/fastapi.lua`, on a generated project of 1000 routes in 50 routers beside 1000 other Python files
  (2026-10-22, the machine above, median of 7): 103 ms the first time, 21 ms after (walking and stat-ing the files),
  20 ms after a router file is saved, 22 ms after an unsaved edit. There's no Neovim plugin to compare with.
- Not taken: reading asynchronously, or watching files. 21 ms on a pick is below what a key press notices; a
  watcher would cost on every save in projects where the picker is never opened.
