-- From files to apps: which files hold the apps (the entrypoint, or every file calling FastAPI(), as
-- src/appDiscovery.ts), how an import leads to a file (src/core/importResolver.ts) and how include_router() and
-- mount() join routers into an app (src/core/routerResolver.ts), each at fastapi-vscode 39e5382. Ends in a flat list
-- of routes with their full paths (src/core/transformer.ts without the tree view's grouping).
local M = {}

local analyze = require("neoblocks.fastapi.analyze")
local uv = vim.uv

---@class neoblocks.fastapi.Node an app or router, with what it includes
---@field file string
---@field var string
---@field type "FastAPI"|"APIRouter"
---@field prefix string
---@field line integer
---@field col integer
---@field routes neoblocks.fastapi.RouteInfo[]
---@field children { node: neoblocks.fastapi.Node, prefix: string }[]

---@class neoblocks.fastapi.Ctx
---@field root string the folder searched (VS Code's workspace folder)
---@field project string the folder absolute imports start from
---@field bufs table<string, integer> loaded buffers by name
---@field visited table<string, true> file#variable already in this app

---@param path string
local function is_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

local dirname, join = vim.fs.dirname, vim.fs.joinpath

---@param ctx neoblocks.fastapi.Ctx
local function file(ctx, path) return analyze.file(path, ctx.bufs) end

--- Where absolute imports start for an entry file: above a package, the folder holding its top package; beside a
--- loose module, the nearest pyproject.toml's folder up to the root, else the module's own.
---@param entry string
---@param root string
function M.project_root(entry, root)
  local dir = dirname(entry)
  local function within(d) return d == root or vim.startswith(d, root .. "/") end
  if not is_file(join(dir, "__init__.py")) then
    local d = dir
    while within(d) do
      if is_file(join(d, "pyproject.toml")) then
        return d
      end
      if d == root then
        break
      end
      d = dirname(d)
    end
    return dir
  end
  while within(dir) and dir ~= root do
    local parent = dirname(dir)
    if not is_file(join(parent, "__init__.py")) then
      return parent
    end
    dir = parent
  end
  return root
end

--- module.py, else module/__init__.py, as Python looks.
---@param base string the module's path without .py
---@return string?
local function module_file(base)
  if is_file(base .. ".py") then
    return base .. ".py"
  elseif is_file(join(base, "__init__.py")) then
    return join(base, "__init__.py")
  end
end

---@param imp neoblocks.fastapi.Import
---@param from string the importing file
---@param start string where absolute imports start
local function module_dir(imp, from, start)
  local dir = start
  if imp.dots > 0 then
    dir = dirname(from)
    for _ = 2, imp.dots do
      dir = dirname(dir)
    end
  end
  return imp.module ~= "" and join(dir, (imp.module:gsub("%.", "/"))) or dir
end

--- The file an import names; an absolute import not under the project is looked for under its src/ too.
---@param imp neoblocks.fastapi.Import
---@param from string
---@param ctx neoblocks.fastapi.Ctx
---@return string?
local function resolve_import(imp, from, ctx)
  return module_file(module_dir(imp, from, ctx.project))
    or (imp.dots == 0 and module_file(module_dir(imp, from, join(ctx.project, "src"))) or nil)
end

---@param imports neoblocks.fastapi.Import[]
---@param name string a name bound in the file
---@return neoblocks.fastapi.Import?, neoblocks.fastapi.Name?
local function import_of(imports, name)
  for _, imp in ipairs(imports) do
    for _, n in ipairs(imp.names) do
      if (n.alias or n.name) == name then
        return imp, n
      end
    end
  end
end

--- The file a name from an import comes from: a submodule of a package (or namespace package), a module a package's
--- __init__.py re-exports it from, else the imported module itself.
---@param imp neoblocks.fastapi.Import
---@param name string the name as the module has it
---@param from string
---@param ctx neoblocks.fastapi.Ctx
---@return string? file
---@return string? name the name in that file; nil when it's the file itself (a submodule)
local function resolve_name(imp, name, from, ctx)
  local base = resolve_import(imp, from, ctx)
  local init = base and base:match("/__init__%.py$") ~= nil
  if not base or init then
    -- a namespace package has no file: its folder under the project, then under src/
    local dirs = base and { dirname(base) } or { module_dir(imp, from, ctx.project) }
    if not base and imp.dots == 0 then
      dirs[2] = module_dir(imp, from, join(ctx.project, "src"))
    end
    for _, dir in ipairs(dirs) do
      local sub = module_file(join(dir, (name:gsub("%.", "/"))))
      if sub then
        return sub, nil
      end
    end
  end
  if base and init then
    local a = file(ctx, base)
    local re, re_named = nil, nil ---@type neoblocks.fastapi.Import?, neoblocks.fastapi.Name?
    if a then
      re, re_named = import_of(a.imports, name)
    end
    local found = re and resolve_import(re, base, ctx)
    if found then
      -- `from .router import router as api`: `router` in router.py
      return found, re_named and re_named.name or name
    end
  end
  return base, name
end

---@param info neoblocks.fastapi.RouterInfo
---@param a neoblocks.fastapi.Analysis
---@param path string
---@return neoblocks.fastapi.Node
local function node_of(info, a, path)
  return {
    file = path,
    var = info.var,
    type = info.type,
    prefix = info.prefix,
    line = info.line,
    col = info.col,
    routes = vim.tbl_filter(function(r) return r.owner == info.var end, a.routes),
    children = {},
  }
end

---@param routers neoblocks.fastapi.RouterInfo[]
---@param var? string
---@return neoblocks.fastapi.RouterInfo?
local function find_app(routers, var)
  local first_router
  for _, r in ipairs(routers) do
    if var then
      if r.var == var then
        return r
      end
    elseif r.type == "FastAPI" then
      return r
    else
      first_router = first_router or r
    end
  end
  return first_router
end

local build, resolve_ref

---@param a neoblocks.fastapi.Analysis
---@param node neoblocks.fastapi.Node
---@param ctx neoblocks.fastapi.Ctx
local function add_includes(a, node, ctx)
  for _, inc in ipairs(a.includes) do
    if inc.owner == node.var then
      local child = resolve_ref(inc.router, a, node.file, ctx, "include")
      if child then
        node.children[#node.children + 1] = { node = child, prefix = inc.prefix }
      end
    end
  end
end

--- The app or router a name in a file stands for: one made in the file, else one an import brings.
---@param ref string `router`, or `module.router`
---@param a neoblocks.fastapi.Analysis
---@param from string
---@param ctx neoblocks.fastapi.Ctx
---@param kind "include"|"mount"
---@return neoblocks.fastapi.Node?
function resolve_ref(ref, a, from, ctx, kind)
  local first, attr = ref:match("^([^.]+)%.(.+)$")
  first = first or ref
  for _, r in ipairs(a.routers) do
    if r.var == first and (r.type == "APIRouter" or kind == "mount") then
      local key = from .. "#" .. first
      if ctx.visited[key] then
        return nil
      end
      ctx.visited[key] = true
      local node = node_of(r, a, from)
      add_includes(a, node, ctx)
      return node
    end
  end
  local imp, named = import_of(a.imports, first)
  if not imp then
    return nil
  end
  local target, inner = resolve_name(imp, named and named.name or first, from, ctx)
  if not target then
    return nil
  end
  if attr then
    local ta = file(ctx, target)
    local info = ta and find_app(ta.routers, attr)
    if ta and not info and kind == "include" then
      -- `router = make_router()`: an include_router() argument is a router, whatever made it
      for _, c in ipairs(ta.calls) do
        if c.var == attr then
          info = { var = attr, type = "APIRouter", prefix = c.prefix, line = c.line, col = c.col }
        end
      end
    end
    if info then
      local key = target .. "#" .. attr
      if ctx.visited[key] then
        return nil
      end
      ctx.visited[key] = true
      local node = node_of(info, ta, target)
      add_includes(ta, node, ctx)
      return node
    end
  end
  return build(target, ctx, inner)
end

--- The app (or router) `var` in a file with what it includes and mounts; without `var`, its first app, else its first
--- router.
---@param path string
---@param ctx neoblocks.fastapi.Ctx
---@param var? string
---@return neoblocks.fastapi.Node?
function build(path, ctx, var)
  local key = path .. "#" .. (var or "")
  if ctx.visited[key] then
    return nil
  end
  ctx.visited[key] = true
  local a = file(ctx, path)
  if not a then
    return nil
  end
  local app = find_app(a.routers, var)
  if not app and path:match("/__init__%.py$") and #a.routers == 0 then
    -- a package that re-exports its router: `from .router import router`
    local imp = import_of(a.imports, "router")
    local actual = imp and resolve_import(imp, path, ctx)
    local aa = actual and not ctx.visited[actual] and file(ctx, actual) or nil
    local info = aa and find_app(aa.routers)
    if actual and aa and info then
      ctx.visited[actual] = true
      a, app, path = aa, info, actual
    end
  end
  if not app and var then
    local made, routed = nil, false ---@type { line: integer, col: integer, callee: string }?, boolean
    for _, c in ipairs(a.calls) do
      if c.var == var then
        made = c
      end
    end
    for _, r in ipairs(a.routes) do
      routed = routed or r.owner == var
    end
    if routed then
      -- `app = make_app()` with routes on it: an app, whatever made it
      app = { var = var, type = "FastAPI", prefix = "", line = made and made.line or 1, col = made and made.col or 0 }
    elseif made then
      -- `app = create_app()` from another module: the app the factory makes
      local imp, named = import_of(a.imports, made.callee)
      local factory = imp and resolve_name(imp, named and named.name or made.callee, path, ctx)
      local node = factory and not ctx.visited[factory .. "#"] and build(factory, ctx)
      if node then
        node.var = var
        return node
      end
    end
  end
  if not app then
    return nil
  end
  local node = node_of(app, a, path)
  add_includes(a, node, ctx)
  for _, m in ipairs(a.mounts) do
    if m.owner == app.var then
      local child = resolve_ref(m.app, a, path, ctx, "mount")
      if child then
        node.children[#node.children + 1] = { node = child, prefix = m.path }
      end
    end
  end
  return node
end

---@param root string
---@param path string
---@param var? string
---@param bufs table<string, integer>
---@return neoblocks.fastapi.Node?
function M.app(root, path, var, bufs)
  return build(path, { root = root, project = M.project_root(path, root), bufs = bufs, visited = {} }, var)
end

--- `pkg.main:app` -> pkg/main.py, app
---@param entry string
---@return string rel, string? var
function M.parse_entrypoint(entry)
  local module, var = entry:match("^([^:]*):?(.*)$")
  return module:gsub("%.", "/") .. ".py", var ~= "" and var or nil
end

--- `[tool.fastapi] entrypoint` in a pyproject.toml's text.
---@param text string
---@return string?
function M.pyproject_entrypoint(text)
  local section ---@type string?
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*%[") then
      section = line:match("^%s*%[%s*([^%]]-)%s*%]")
    elseif section == "tool.fastapi" then
      local v = line:match('^%s*entrypoint%s*=%s*"([^"]*)"') or line:match("^%s*entrypoint%s*=%s*'([^']*)'")
      if v then
        return v
      end
    end
  end
end

---@param name string
local function is_test_file(name) return name:match("^test_") or name:match("_test%.py$") or name == "conftest.py" end

--- The Python files and pyproject.toml files under root, folders named in `exclude` and hidden ones skipped,
--- shallowest first.
---@param root string
---@param exclude table<string, true>
---@return string[] py, string[] pyprojects
function M.files(root, exclude)
  local py, pyprojects = {}, {}
  for rel, type in
    vim.fs.dir(root, {
      depth = math.huge,
      skip = function(dir)
        local name = vim.fs.basename(dir)
        return not (exclude[name] or name:sub(1, 1) == ".")
      end,
    })
  do
    local name = vim.fs.basename(rel)
    if type == "file" then
      if name == "pyproject.toml" then
        pyprojects[#pyprojects + 1] = rel
      elseif name:match("%.py$") and not is_test_file(name) then
        py[#py + 1] = rel
      end
    end
  end
  local function depth(rel) return select(2, rel:gsub("/", "")) end
  local function order(a, b)
    local da, db = depth(a), depth(b)
    return da ~= db and da < db or (da == db and a < b)
  end
  table.sort(py, order)
  table.sort(pyprojects, order)
  return vim.tbl_map(function(r) return join(root, r) end, py),
    vim.tbl_map(function(r) return join(root, r) end, pyprojects)
end

return M
