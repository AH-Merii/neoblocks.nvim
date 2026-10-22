--- A FastAPI project's routes in a picker, found by reading the code, never by running it. Replaces the path
--- operation search of [fastapi-vscode](https://github.com/fastapi/fastapi-vscode), ported from its analyzer:
---
--- - the apps: `entrypoint` if set, else `[tool.fastapi] entrypoint` in a pyproject.toml, else every app assigned in a
---   file that calls `FastAPI(`; test files, `tests/` and hidden folders aren't searched;
--- - their routes: each `@app.get(...)`, `@router.post(...)`, `@app.api_route(...)` and `@app.websocket(...)`, with
---   the prefixes of the `include_router()` and `APIRouter(prefix=...)` above it and the path of a `mount()`, followed
---   through imports, `__init__.py` re-exports, namespace packages, a `src/` layout and factory functions;
--- - a path built from string constants, f-strings and `+` resolves; another expression stays as `{expression}`, and
---   the picker leaves out the leading ones (`{settings.API_V1_STR}/users` shows as `/users`).
---
--- ```lua
--- require("neoblocks").setup({ fastapi = {} })
--- vim.keymap.set("n", "<leader>sF", function() Neoblocks.fastapi.pick() end, { desc = "FastAPI routes" })
--- ```
---
--- In [snacks.nvim](https://github.com/folke/snacks.nvim)'s picker: `<CR>` opens the handler, `<a-g>` where its
--- router or app is made, `<a-y>` yanks its path, `<c-q>` sends the list to the quickfix list. Its source is
--- `fastapi_routes`, so `picker.sources.fastapi_routes` in snacks' options changes it. Without snacks, the routes are
--- offered in `vim.ui.select()`.
---
--- Python is read with tree-sitter: it needs the `python` parser (`:TSInstall python` with nvim-treesitter); a file
--- is read again only once it changed, and an unsaved buffer counts with its edits. Methods are drawn in
--- `NeoblocksFastapiGet`, `...Post`, `...Put`, `...Patch`, `...Delete`, `...Options`, `...Head` and `...Websocket`,
--- linked to diagnostic colours as Swagger UI colours them; a deprecated route's path in `NeoblocksFastapiDeprecated`.
---@class neoblocks.fastapi
local M = {}

M.meta = { desc = "FastAPI routes in a picker, read from the code (replaces fastapi-vscode's route search)" }

---@class neoblocks.fastapi.Config
---@field entrypoint? string the app, as `package.module:variable` from the current directory; default: pyproject.toml's `[tool.fastapi] entrypoint`, else every app
---@field exclude? string[] folder names not searched for apps, besides hidden ones
local defaults = {
  entrypoint = nil,
  exclude = { "venv", "__pycache__", "node_modules", "tests", "test" },
}

local api = vim.api
local NAME = "fastapi"
local analyze = require("neoblocks.fastapi.analyze")
local graph = require("neoblocks.fastapi.graph")

local config ---@type neoblocks.fastapi.Config?

local LINKS = {
  Get = "DiagnosticInfo",
  Post = "DiagnosticOk",
  Put = "DiagnosticWarn",
  Patch = "DiagnosticHint",
  Delete = "DiagnosticError",
  Options = "Comment",
  Head = "Comment",
  Websocket = "Special",
  Deprecated = "DiagnosticDeprecated",
}

local function highlights()
  for name, link in pairs(LINKS) do
    api.nvim_set_hl(0, "NeoblocksFastapi" .. name, { link = link, default = true })
  end
end

--- Reads the options and defines the highlight groups.
function M.setup()
  config = require("neoblocks.config").get(NAME, defaults)
  highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("neoblocks.fastapi", { clear = true }),
    callback = highlights,
  })
end

---@class neoblocks.fastapi.Route
---@field method string `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `HEAD` or `WEBSOCKET`
---@field path string the full path, prefixes included; an unresolved expression as `{expression}`
---@field name string the handler function
---@field file string
---@field line integer the route decorator's line
---@field col integer
---@field deprecated? boolean
---@field app { name: string, file: string } the app it's served by
---@field router { name: string, file: string, line: integer, col: integer } where its router, or its app, is made

-- The path without its leading `{expression}` segments, `/` when that leaves nothing: how the picker shows it.
---@param path string
---@return string
local function display_path(path)
  local rest = path
  while rest:match("^{[^}]*}") do
    rest = rest:gsub("^{[^}]*}", "", 1)
  end
  return rest == "" and "/" or rest
end

---@param node neoblocks.fastapi.Node
---@param prefix string
---@param app { name: string, file: string }
---@param out neoblocks.fastapi.Route[]
local function flatten(node, prefix, app, out)
  local full = prefix .. node.prefix
  local router = { name = node.var, file = node.file, line = node.line, col = node.col }
  for _, r in ipairs(node.routes) do
    out[#out + 1] = {
      method = r.method,
      path = full .. r.path,
      name = r.name,
      file = node.file,
      line = r.line,
      col = r.col,
      deprecated = r.deprecated,
      app = app,
      router = router,
    }
  end
  for _, child in ipairs(node.children) do
    flatten(child.node, full .. child.prefix, app, out)
  end
end

---@param node neoblocks.fastapi.Node
---@param into table<string, true>
local function inner_keys(node, into)
  for _, child in ipairs(node.children) do
    into[child.node.file .. "#" .. child.node.var] = true
    inner_keys(child.node, into)
  end
end

--- Every route of the project in the current directory, sorted by path as the picker shows it, then by method.
--- Raises an error when there's no Python parser, or the entrypoint names no file or no app.
---@return neoblocks.fastapi.Route[]
function M.routes()
  local opts = config or require("neoblocks.config").get(NAME, defaults)
  if not vim.treesitter.language.add("python") then
    error("neoblocks.fastapi: no tree-sitter parser for python; install one, e.g. `:TSInstall python`", 0)
  end
  local root = vim.fs.normalize(vim.fn.getcwd())
  local bufs = {} ---@type table<string, integer>
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and api.nvim_buf_get_name(b) ~= "" then
      bufs[vim.fs.normalize(api.nvim_buf_get_name(b))] = b
    end
  end
  local exclude = {} ---@type table<string, true>
  for _, name in ipairs(opts.exclude or {}) do
    exclude[name] = true
  end

  local apps = {} ---@type neoblocks.fastapi.Node[]
  local py, pyprojects = graph.files(root, exclude)
  local entry, base = opts.entrypoint, root
  if not entry then
    for _, path in ipairs(pyprojects) do
      local f = io.open(path, "r")
      entry = f and graph.pyproject_entrypoint(f:read("*a"))
      if f then
        f:close()
      end
      if entry then
        base = vim.fs.dirname(path)
        break
      end
    end
  end
  if entry then
    local rel, var = graph.parse_entrypoint(entry)
    local path = vim.fs.joinpath(base, rel)
    if not vim.uv.fs_stat(path) then
      error(("neoblocks.fastapi: entrypoint %s: no file %s"):format(entry, path), 0)
    end
    local app = graph.app(root, path, var, bufs)
    if not app then
      error(("neoblocks.fastapi: entrypoint %s: no app %s in %s"):format(entry, var or "", path), 0)
    end
    apps[1] = app
  else
    local candidates = vim.tbl_filter(function(path) return analyze.mentions_app(path, bufs) end, py)
    for _, path in ipairs(candidates) do
      local a = analyze.file(path, bufs)
      local vars = vim.tbl_map(
        function(r) return r.var end,
        vim.tbl_filter(function(r) return r.type == "FastAPI" end, a and a.routers or {})
      )
      for _, var in ipairs(#vars > 0 and vars or { false }) do
        apps[#apps + 1] = graph.app(root, path, var or nil, bufs)
      end
    end
    -- an app another app mounts or includes is listed under it, not again on its own
    local inner = {} ---@type table<string, true>
    for _, app in ipairs(apps) do
      inner_keys(app, inner)
    end
    apps = vim.tbl_filter(function(app) return not inner[app.file .. "#" .. app.var] end, apps)
  end

  local routes = {} ---@type neoblocks.fastapi.Route[]
  for _, app in ipairs(apps) do
    flatten(app, "", { name = app.var, file = app.file }, routes)
  end
  local shown = {} ---@type table<neoblocks.fastapi.Route, string>
  for _, r in ipairs(routes) do
    shown[r] = display_path(r.path)
  end
  table.sort(routes, function(a, b)
    if shown[a] ~= shown[b] then
      return shown[a] < shown[b]
    end
    local ma, mb = analyze.METHODS[a.method:lower()], analyze.METHODS[b.method:lower()]
    if ma ~= mb then
      return ma < mb
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return routes
end

---@param file string
---@param line integer
---@param col integer
local function open(file, line, col)
  vim.cmd.edit(vim.fn.fnameescape(file))
  pcall(api.nvim_win_set_cursor, 0, { line, col })
  vim.cmd("normal! zv")
end

local LABEL = { WEBSOCKET = "WS" }

---@param r neoblocks.fastapi.Route
local function hl(r) return "NeoblocksFastapi" .. r.method:sub(1, 1) .. r.method:sub(2):lower() end

---@return table? # Snacks, when snacks.nvim is set up with its picker
local function snacks()
  local s = rawget(_G, "Snacks")
  return type(s) == "table" and s.did_setup and s.picker and type(s.picker.pick) == "function" and s or nil
end

--- The routes in snacks' picker, or `vim.ui.select()` without it: `<CR>` opens the handler, `<a-g>` the router or app,
--- `<a-y>` yanks the path. Says why instead when the module is switched off or there are no routes.
function M.pick()
  if not require("neoblocks.util").enabled(NAME, api.nvim_get_current_buf()) then
    return vim.notify("neoblocks.fastapi: off (`:Neoblocks fastapi on`)", vim.log.levels.WARN)
  end
  local ok, routes = pcall(M.routes)
  if not ok then
    return vim.notify(tostring(routes), vim.log.levels.ERROR)
  end
  local root = vim.fn.getcwd()
  if #routes == 0 then
    return vim.notify(("neoblocks.fastapi: no FastAPI routes found in %s"):format(root), vim.log.levels.WARN)
  end
  local apps = {} ---@type table<string, true>
  for _, r in ipairs(routes) do
    apps[r.app.file .. "#" .. r.app.name] = true
  end
  local several = #vim.tbl_keys(apps) > 1
  local function where(r) return ("%s:%d"):format(vim.fs.relpath(root, r.file) or r.file, r.line) end
  local function label(r) return LABEL[r.method] or r.method end

  local s = snacks()
  if not s then
    return vim.ui.select(routes, {
      prompt = "FastAPI routes",
      format_item = function(r) return ("%-7s %s  %s  %s"):format(label(r), display_path(r.path), r.name, where(r)) end,
    }, function(r)
      if r then
        open(r.file, r.line, r.col)
      end
    end)
  end
  local items = {}
  for _, r in ipairs(routes) do
    local path = display_path(r.path)
    items[#items + 1] = {
      text = table.concat({ r.method, path, r.name, where(r), several and r.app.name or nil }, " "),
      file = r.file,
      pos = { r.line, r.col },
      data = path,
      route = r,
    }
  end
  s.picker.pick({
    source = "fastapi_routes",
    title = "FastAPI routes",
    items = items,
    preview = "file",
    format = function(item)
      local r = item.route
      local ret = {
        { ("%-7s"):format(label(r)), hl(r) },
        { " " },
        { item.data, r.deprecated and "NeoblocksFastapiDeprecated" or nil },
        { "  " },
        { r.name, "Function" },
        { "  " },
        { where(r), "Comment" },
      }
      if several then
        vim.list_extend(ret, { { "  " }, { r.app.name, "Comment" } })
      end
      return ret
    end,
    actions = {
      router = function(picker, item)
        picker:close()
        if item then
          local at = item.route.router
          open(at.file, at.line, at.col)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-g>"] = { "router", mode = { "n", "i" }, desc = "Open the router or app" },
          ["<a-y>"] = { "yank", mode = { "n", "i" }, desc = "Yank the path" },
        },
      },
    },
  })
end

function M.health()
  local h = vim.health
  if vim.treesitter.language.add("python") then
    h.ok("tree-sitter parser for python found")
  else
    h.error("no tree-sitter parser for python: routes() and pick() need one, e.g. `:TSInstall python`")
  end
  if snacks() then
    h.ok("snacks.picker found: pick() opens it")
  else
    h.info("no snacks.picker: pick() uses vim.ui.select()")
  end
  local entry = (config or {}).entrypoint
  h.info(
    entry and ("apps: the entrypoint option's, %s"):format(entry)
      or "apps: pyproject.toml's [tool.fastapi] entrypoint, else every app in a file that calls FastAPI("
  )
end

return M
