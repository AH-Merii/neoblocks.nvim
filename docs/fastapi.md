# neoblocks.fastapi

FastAPI routes in a picker, read from the code (replaces fastapi-vscode's route search)

A FastAPI project's routes in a picker, found by reading the code, never by running it. Replaces the path
operation search of [fastapi-vscode](https://github.com/fastapi/fastapi-vscode), ported from its analyzer:

- the apps: `entrypoint` if set, else `[tool.fastapi] entrypoint` in a pyproject.toml, else every app assigned in a
  file that calls `FastAPI(`; test files, `tests/` and hidden folders aren't searched;
- their routes: each `@app.get(...)`, `@router.post(...)`, `@app.api_route(...)` and `@app.websocket(...)`, with
  the prefixes of the `include_router()` and `APIRouter(prefix=...)` above it and the path of a `mount()`, followed
  through imports, `__init__.py` re-exports, namespace packages, a `src/` layout and factory functions;
- a path built from string constants, f-strings and `+` resolves; another expression stays as `{expression}`, and
  the picker leaves out the leading ones (`{settings.API_V1_STR}/users` shows as `/users`).

```lua
require("neoblocks").setup({ fastapi = {} })
vim.keymap.set("n", "<leader>sF", function() Neoblocks.fastapi.pick() end, { desc = "FastAPI routes" })
```

In [snacks.nvim](https://github.com/folke/snacks.nvim)'s picker: `<CR>` opens the handler, `<a-g>` where its
router or app is made, `<a-y>` yanks its path, `<c-q>` sends the list to the quickfix list. Its source is
`fastapi_routes`, so `picker.sources.fastapi_routes` in snacks' options changes it. Without snacks, the routes are
offered in `vim.ui.select()`.

Python is read with tree-sitter: it needs the `python` parser (`:TSInstall python` with nvim-treesitter); a file
is read again only once it changed, and an unsaved buffer counts with its edits. Methods are drawn in
`NeoblocksFastapiGet`, `...Post`, `...Put`, `...Patch`, `...Delete`, `...Options`, `...Head` and `...Websocket`,
linked to diagnostic colours as Swagger UI colours them; a deprecated route's path in `NeoblocksFastapiDeprecated`.

## Setup

```lua
require("neoblocks").setup({ fastapi = {} })
```

## Options

```lua
---@class neoblocks.fastapi.Config
---@field entrypoint? string the app, as `package.module:variable` from the current directory; default: pyproject.toml's `[tool.fastapi] entrypoint`, else every app
---@field exclude? string[] folder names not searched for apps, besides hidden ones
local defaults = {
  entrypoint = nil,
  exclude = { "venv", "__pycache__", "node_modules", "tests", "test" },
}
```

## API

### `Neoblocks.fastapi.setup()`

Reads the options and defines the highlight groups.

### `Neoblocks.fastapi.routes()`

Every route of the project in the current directory, sorted by path as the picker shows it, then by method.
Raises an error when there's no Python parser, or the entrypoint names no file or no app.

- returns `neoblocks.fastapi.Route[]`

### `Neoblocks.fastapi.pick()`

The routes in snacks' picker, or `vim.ui.select()` without it: `<CR>` opens the handler, `<a-g>` the router or app,
`<a-y>` yanks the path. Says why instead when the module is switched off or there are no routes.

