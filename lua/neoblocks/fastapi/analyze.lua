-- One Python file's FastAPI facts, read with tree-sitter: route decorators, FastAPI() and APIRouter() assignments,
-- include_router() and mount() calls, imports and the calls a factory assigns (`app = create_app()`). A port of
-- fastapi-vscode's src/core/analyzer.ts and extractors.ts (39e5382); docs/decisions/fastapi.md lists where it differs.
-- A file is read again only when it changed: its buffer's changedtick, or its mtime and size on disk.
local M = {}

local ts = vim.treesitter

-- Marks an expression inside a path until it's resolved to a module string constant, or to "{expression}"
-- (the extension's U+E000). FastAPI's own {param} segments are never marked, so never replaced.
local MARK = "\1"

local METHODS = { get = 1, post = 2, put = 3, patch = 4, delete = 5, options = 6, head = 7, websocket = 8 }
M.METHODS = METHODS

---@class neoblocks.fastapi.RouteInfo
---@field owner string the app or router the decorator is on, as written: `app`, `router`
---@field method string upper case
---@field path string
---@field name string the handler
---@field line integer 1-based, the decorator's
---@field col integer 0-based
---@field deprecated? boolean

---@class neoblocks.fastapi.RouterInfo
---@field var string the variable assigned
---@field type "FastAPI"|"APIRouter"
---@field prefix string
---@field line integer
---@field col integer

---@class neoblocks.fastapi.Import
---@field module string dotted, without the leading dots of a relative import
---@field dots integer 0 for an absolute import
---@field names neoblocks.fastapi.Name[]

---@class neoblocks.fastapi.Name a name an import binds
---@field name string as the module has it
---@field alias? string what `as` renames it to

---@class neoblocks.fastapi.Analysis
---@field routes neoblocks.fastapi.RouteInfo[]
---@field routers neoblocks.fastapi.RouterInfo[]
---@field includes { owner: string, router: string, prefix: string }[]
---@field mounts { owner: string, app: string, path: string }[]
---@field imports neoblocks.fastapi.Import[]
---@field calls { var: string, callee: string, prefix: string, line: integer, col: integer }[] module-level `x = f(...)`

local query ---@type vim.treesitter.Query?
local function get_query()
  query = query
    or ts.query.parse(
      "python",
      [[
        (decorated_definition) @decorated
        (assignment) @assignment
        (call) @call
        (import_statement) @import
        (import_from_statement) @import
        (class_definition) @class
      ]]
    )
  return query
end

---@param node TSNode
---@param name string
---@return TSNode?
local function field(node, name) return node:field(name)[1] end

---@param node TSNode
---@param types table<string, true>
local function inside(node, types)
  local p = node:parent()
  while p do
    if types[p:type()] then
      return true
    end
    p = p:parent()
  end
  return false
end

local SCOPES = { function_definition = true, class_definition = true }

---@param node TSNode
---@return TSNode[] the arguments, comments left out
local function args_of(node)
  return vim.tbl_filter(function(n) return n:type() ~= "comment" end, node:named_children())
end

--- A call's argument by position (1-based) among the positional ones, else by keyword.
---@param args TSNode[]
---@return TSNode?
local function arg(args, pos, keyword, src)
  local n = 0
  for _, a in ipairs(args) do
    if a:type() ~= "keyword_argument" then
      n = n + 1
      if n == pos then
        return a
      end
    end
  end
  for _, a in ipairs(args) do
    local name = a:type() == "keyword_argument" and field(a, "name")
    if name and ts.get_node_text(name, src) == keyword then
      return field(a, "value")
    end
  end
end

--- `obj.method(args)`: the object, the method's name and the arguments; nothing for another call.
---@param node? TSNode
---@return TSNode? obj, string? method, TSNode? args
local function method_call(node, src)
  if not node or node:type() ~= "call" then
    return
  end
  local fn, args = field(node, "function"), field(node, "arguments")
  local obj, attr = fn and fn:type() == "attribute" and field(fn, "object"), fn and field(fn, "attribute")
  if obj and attr and args then
    return obj, ts.get_node_text(attr, src), args
  end
end

--- A string literal's value; an f-string's interpolations marked as expressions, its `{{` and `}}` unescaped.
---@param node TSNode
---@return string?
local function string_value(node, src)
  if node:type() ~= "string" then
    return nil
  end
  local f, parts = false, {}
  for child in node:iter_children() do
    local t = child:type()
    if t == "string_start" then
      f = ts.get_node_text(child, src):lower():find("f", 1, true) ~= nil
    elseif t == "string_content" then
      local s = ts.get_node_text(child, src)
      parts[#parts + 1] = f and (s:gsub("{{", "{"):gsub("}}", "}")) or s
    elseif t == "interpolation" then
      local expr = field(child, "expression")
      parts[#parts + 1] = MARK .. (expr and ts.get_node_text(expr, src) or "") .. MARK
    end
  end
  return table.concat(parts)
end

--- A path from strings, adjacent strings and `+`; anything else is an expression to resolve later.
---@param node TSNode
---@return string
local function path_of(node, src)
  local t = node:type()
  if t == "string" then
    return string_value(node, src) or ""
  elseif t == "concatenated_string" then
    return table.concat(vim.tbl_map(function(n) return path_of(n, src) end, node:named_children()))
  elseif t == "binary_operator" then
    local left, op, right = field(node, "left"), field(node, "operator"), field(node, "right")
    if left and right and op and ts.get_node_text(op, src) == "+" then
      return path_of(left, src) .. path_of(right, src)
    end
  end
  return MARK .. ts.get_node_text(node, src) .. MARK
end

--- Each marked expression: the module string constant it names, else "{expression}". Constants may name constants.
---@param path string
---@param consts table<string, string>
local function resolve(path, consts)
  for _ = 1, 5 do
    local n
    path, n = path:gsub(MARK .. "([^" .. MARK .. "]+)" .. MARK, consts)
    if n == 0 or not path:find(MARK, 1, true) then
      break
    end
  end
  return (path:gsub(MARK .. "([^" .. MARK .. "]*)" .. MARK, "{%1}"))
end

---@param call TSNode
---@return string prefix the `prefix=` keyword argument's path
local function prefix_of(call, src)
  local args = field(call, "arguments")
  for _, a in ipairs(args and args:named_children() or {}) do
    local name, value = field(a, "name"), field(a, "value")
    if a:type() == "keyword_argument" and name and value and ts.get_node_text(name, src) == "prefix" then
      return path_of(value, src)
    end
  end
  return ""
end

---@param node TSNode
---@return neoblocks.fastapi.Import[] one per name an `import` binds; one for a `from ... import`
local function imports_of(node, src)
  local ret = {}
  if node:type() == "import_statement" then
    for _, n in ipairs(node:field("name")) do
      if n:type() == "aliased_import" then
        local name, alias = field(n, "name"), field(n, "alias")
        local module = name and ts.get_node_text(name, src) or ""
        ret[#ret + 1] =
          { module = module, dots = 0, names = { { name = module, alias = alias and ts.get_node_text(alias, src) } } }
      else
        -- `import a.b` binds `a`
        local module = ts.get_node_text(n, src)
        ret[#ret + 1] = { module = module, dots = 0, names = { { name = module:match("^[^.]+") } } }
      end
    end
    return ret
  end
  local module = field(node, "module_name")
  local dots, path = (module and ts.get_node_text(module, src) or ""):match("^(%.*)(.*)$")
  local names = {}
  for _, n in ipairs(node:field("name")) do
    if n:type() == "aliased_import" then
      local name, alias = field(n, "name"), field(n, "alias")
      names[#names + 1] =
        { name = name and ts.get_node_text(name, src) or "", alias = alias and ts.get_node_text(alias, src) }
    else
      names[#names + 1] = { name = ts.get_node_text(n, src) }
    end
  end
  return { { module = path, dots = #dots, names = names } }
end

--- Analyzes Python source.
---@param src string
---@return neoblocks.fastapi.Analysis
function M.source(src)
  local tree = ts.get_string_parser(src, "python"):parse()[1]
  local nodes = { decorated = {}, assignment = {}, call = {}, import = {}, class = {} } ---@type table<string, TSNode[]>
  local q = get_query()
  for id, node in q:iter_captures(tree:root(), src) do
    table.insert(nodes[q.captures[id]], node)
  end
  local a = { routes = {}, routers = {}, includes = {}, mounts = {}, imports = {}, calls = {} } ---@type neoblocks.fastapi.Analysis

  for _, node in ipairs(nodes.import) do
    vim.list_extend(a.imports, imports_of(node, src))
  end

  -- What makes an app or a router here: the names, their aliases, `import fastapi as f`'s f.X, and subclasses
  local apps = { FastAPI = true, ["fastapi.FastAPI"] = true } ---@type table<string, true>
  local routers = { APIRouter = true, ["fastapi.APIRouter"] = true } ---@type table<string, true>
  for _, imp in ipairs(a.imports) do
    for _, n in ipairs(imp.names) do
      if n.alias and imp.dots == 0 and imp.module == "fastapi" then
        if n.name == "FastAPI" then
          apps[n.alias] = true
        elseif n.name == "APIRouter" then
          routers[n.alias] = true
        elseif n.name == "fastapi" then
          apps[n.alias .. ".FastAPI"], routers[n.alias .. ".APIRouter"] = true, true
        end
      end
    end
  end
  for _, node in ipairs(nodes.class) do
    local name, supers = field(node, "name"), field(node, "superclasses")
    if name and supers then
      local cls = ts.get_node_text(name, src)
      for _, s in ipairs(supers:named_children()) do
        local parent = ts.get_node_text(s, src)
        if routers[parent] then
          routers[cls] = true
        elseif apps[parent] then
          apps[cls] = true
        end
      end
    end
  end

  local consts = {} ---@type table<string, string>
  for _, node in ipairs(nodes.assignment) do
    local left, right = field(node, "left"), field(node, "right")
    if left and right and right:type() == "call" then
      local fn = field(right, "function")
      local callee = fn and ts.get_node_text(fn, src) or ""
      local row, col = node:start()
      local type = routers[callee] and "APIRouter" or apps[callee] and "FastAPI"
      if type then
        a.routers[#a.routers + 1] =
          { var = ts.get_node_text(left, src), type = type, prefix = prefix_of(right, src), line = row + 1, col = col }
      end
      if fn and fn:type() == "identifier" and not inside(node, SCOPES) then
        a.calls[#a.calls + 1] = {
          var = ts.get_node_text(left, src),
          callee = callee,
          prefix = prefix_of(right, src),
          line = row + 1,
          col = col,
        }
      end
    elseif left and right and left:type() == "identifier" and right:type() == "string" and not inside(node, SCOPES) then
      consts[ts.get_node_text(left, src)] = string_value(right, src)
    end
  end

  for _, node in ipairs(nodes.decorated) do
    local def = field(node, "definition")
    local name = def and field(def, "name")
    for _, dec in ipairs(node:named_children()) do
      local call = dec:type() == "decorator" and dec:named_child(0)
      local obj, method, args = method_call(call or nil, src)
      method = method and method:lower()
      if obj and method and args and (METHODS[method] or method == "api_route") then
        local argv = args_of(args)
        local path = arg(argv, 1, "path", src)
        local deprecated = arg(argv, math.huge, "deprecated", src)
        local methods = { method:upper() }
        if method == "api_route" then
          local list = arg(argv, math.huge, "methods", src)
          methods = {}
          for _, m in ipairs(list and list:named_children() or {}) do
            local v = string_value(m, src)
            if v and METHODS[v:lower()] then
              methods[#methods + 1] = v:upper()
            end
          end
          methods = #methods > 0 and methods or { "GET" }
        end
        local row, col = dec:start()
        for _, m in ipairs(methods) do
          a.routes[#a.routes + 1] = {
            owner = ts.get_node_text(obj, src),
            method = m,
            path = path and path_of(path, src) or "",
            name = name and ts.get_node_text(name, src) or "",
            line = row + 1,
            col = col,
            deprecated = deprecated and ts.get_node_text(deprecated, src) == "True" or nil,
          }
        end
      end
    end
  end

  for _, node in ipairs(nodes.call) do
    local obj, method, args = method_call(node, src)
    if obj and args and method == "include_router" then
      local argv = args_of(args)
      local router = arg(argv, 1, "router", src)
      a.includes[#a.includes + 1] = {
        owner = ts.get_node_text(obj, src),
        router = router and ts.get_node_text(router, src) or "",
        prefix = prefix_of(node, src),
      }
    elseif obj and args and method == "mount" then
      local argv = args_of(args)
      local path, app = arg(argv, 1, "path", src), arg(argv, 2, "app", src)
      if #argv >= 2 then
        a.mounts[#a.mounts + 1] = {
          owner = ts.get_node_text(obj, src),
          path = path and path_of(path, src) or "",
          app = app and ts.get_node_text(app, src) or "",
        }
      end
    end
  end

  for _, r in ipairs(a.routes) do
    r.path = resolve(r.path, consts)
  end
  for _, m in ipairs(a.mounts) do
    m.path = resolve(m.path, consts)
  end
  for _, list in ipairs({ a.routers, a.includes, a.calls }) do
    for _, x in ipairs(list) do
      x.prefix = resolve(x.prefix, consts)
    end
  end
  return a
end

local cache = {} ---@type table<string, { key: string, analysis?: neoblocks.fastapi.Analysis, app?: boolean }>

--- What identifies this version of a file: its buffer's changedtick when it's loaded, else its mtime and size.
---@param path string absolute
---@param bufs table<string, integer> loaded buffers by name
---@return string? nil when there's no such file
local function version(path, bufs)
  local buf = bufs[path]
  if buf then
    return ("b%d:%d"):format(buf, vim.api.nvim_buf_get_changedtick(buf))
  end
  local stat = vim.uv.fs_stat(path)
  return stat and ("f%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

---@param path string
---@param bufs table<string, integer>
---@return string?
local function text(path, bufs)
  local buf = bufs[path]
  if buf then
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---@param path string
---@param bufs table<string, integer>
---@return table? entry the cache entry for this version of the file, nil when there's no file
local function entry(path, bufs)
  local key = version(path, bufs)
  if not key then
    return nil
  end
  local e = cache[path]
  if not e or e.key ~= key then
    e = { key = key }
    cache[path] = e
  end
  return e
end

--- The file's analysis, nil when it can't be read.
---@param path string absolute
---@param bufs table<string, integer> loaded buffers by name
---@return neoblocks.fastapi.Analysis?
function M.file(path, bufs)
  local e = entry(path, bufs)
  if e and not e.analysis then
    local src = text(path, bufs)
    e.analysis = src and M.source(src) or nil
  end
  return e and e.analysis
end

--- Whether the file calls `FastAPI(`: the text check that picks the files to analyze when looking for apps.
---@param path string absolute
---@param bufs table<string, integer>
function M.mentions_app(path, bufs)
  local e = entry(path, bufs)
  if e and e.app == nil then
    e.app = (text(path, bufs) or ""):find("FastAPI(", 1, true) ~= nil
  end
  return e and e.app or false
end

return M
