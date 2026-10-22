-- The fastapi module: the routes it finds in a project on disk, and the picker over them. Each test writes a small
-- FastAPI project into a scratch folder, makes it the current directory and lists its routes as
-- "METHOD path handler file:line" (the file relative to the project). The expected routes are FastAPI's: a route's
-- path is the prefixes above it joined to its own, as FastAPI joins them. The projects follow fastapi-vscode's test
-- fixtures (src/test/fixtures at 39e5382), whose analyzer this module ports.
--
-- Neovim bundles no Python parser: `mise run check:test` builds tree-sitter-python's and passes its folder in
-- $NEOBLOCKS_TEST_PARSERS.
local root = vim.fn.getcwd()
-- the runner may put the repo on 'runtimepath' as ".", which the tests' chdir would lose
vim.opt.rtp:prepend(root)
local parsers = vim.env.NEOBLOCKS_TEST_PARSERS
assert(
  parsers and vim.uv.fs_stat(parsers .. "/parser/python.so"),
  "no Python parser for the tests: run them with `mise run check:test`, which builds one"
)
vim.opt.rtp:append(parsers)

---@param files table<string, string> path in the project -> contents
---@return string dir the project, now the current directory
local function project(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for path, text in pairs(files) do
    local file = dir .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), file)
  end
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(dir)
  return vim.fn.getcwd()
end

---@param opts? table the fastapi options
local function start(opts)
  local nb = fresh()
  nb.setup({ fastapi = opts or {} })
  return nb
end

---@param route { method: string, path: string, name: string, file: string, line: integer }
local function show(route)
  return ("%s %s %s %s:%d"):format(
    route.method,
    route.path,
    route.name,
    vim.fs.relpath(vim.fn.getcwd(), route.file),
    route.line
  )
end

---@param nb? table a set-up neoblocks; a new one with default options when nil
local function list(nb) return vim.tbl_map(show, (nb or start()).fastapi.routes()) end

-- A project whose routes come from two routers in a package, one imported absolutely, one relatively
local PACKAGE = {
  ["app/__init__.py"] = "",
  ["app/main.py"] = [[
from fastapi import FastAPI, APIRouter
from app.routes import users
from .routes.items import router as items_router
app = FastAPI()
app.include_router(users.router, prefix="/api")
app.include_router(items_router)
@app.get("/")
def root(): ...
orphan = APIRouter()
@orphan.get("/orphan")
def lost(): ...]],
  ["app/routes/__init__.py"] = "",
  ["app/routes/users.py"] = [[
from fastapi import APIRouter
router = APIRouter(prefix="/users")
@router.get("/")
def list_users(): ...
@router.get("/{user_id}")
def get_user(user_id: int): ...]],
  ["app/routes/items.py"] = [[
from fastapi import APIRouter
router = APIRouter(prefix="/items")
@router.post("/")
def create_item(): ...]],
}

test(
  "a route's path is the include_router prefix, then its router's, then its own; unreached routers aren't listed",
  function()
    project(PACKAGE)
    eq({
      "GET / root app/main.py:7",
      "GET /api/users/ list_users app/routes/users.py:3",
      "GET /api/users/{user_id} get_user app/routes/users.py:5",
      "POST /items/ create_item app/routes/items.py:3",
    }, list())
  end
)

test("routers are found through nested includes, __init__.py re-exports, namespace packages and src/", function()
  project({
    ["pyproject.toml"] = '[project]\nname = "shop"',
    -- no __init__.py beside main.py: imports resolve from pyproject.toml's folder, then its src/
    ["src/shop/main.py"] = [[
from fastapi import FastAPI
from shop.integrations import api
from shop.extra import orders
app = FastAPI()
app.include_router(api)
app.include_router(orders.router)]],
    ["src/shop/integrations/__init__.py"] = "from .router import router as api",
    ["src/shop/integrations/router.py"] = [[
from fastapi import APIRouter
from .neon import router as neon_router
router = APIRouter(prefix="/integrations")
router.include_router(neon_router, prefix="/db")
@router.get("/github")
def github(): ...]],
    ["src/shop/integrations/neon.py"] = [[
from fastapi import APIRouter
router = APIRouter(prefix="/neon")
@router.post("/connect")
def connect_neon(): ...]],
    -- a namespace package: no __init__.py in extra/
    ["src/shop/extra/orders.py"] = [[
from fastapi import APIRouter
router = APIRouter(prefix="/orders")
@router.get("/")
def list_orders(): ...]],
  })
  eq({
    "POST /integrations/db/neon/connect connect_neon src/shop/integrations/neon.py:3",
    "GET /integrations/github github src/shop/integrations/router.py:5",
    "GET /orders/ list_orders src/shop/extra/orders.py:3",
  }, list())
end)

test("aliases and subclasses of FastAPI and APIRouter count as them", function()
  project({
    -- no "FastAPI(" in the text, so only the entrypoint finds it
    ["main.py"] = [[
import fastapi as fa
from fastapi import APIRouter as AR, FastAPI as F
class Protected(AR): ...
class App(F): ...
api = App()
public = fa.APIRouter(prefix="/public")
private = Protected(prefix="/private")
@public.get("/a")
def a(): ...
@private.get("/b")
def b(): ...
api.include_router(public)
api.include_router(private)]],
  })
  eq({ "GET /private/b b main.py:10", "GET /public/a a main.py:8" }, list(start({ entrypoint = "main:api" })))
end)

test(
  "paths of strings, module constants, f-strings and + resolve; any other expression stays as {expression}",
  function()
    project({
      ["main.py"] = [[
from fastapi import FastAPI, APIRouter
from config import settings
BASE = "/api"
app = FastAPI()
r = APIRouter(prefix=BASE + "/v1")
@r.get(f"{BASE}/ping/{{n}}")
def ping(n: int): ...
@r.get("/a" "/b")
def ab(): ...
@app.get(settings.HEALTH)
def health(): ...
app.include_router(r, prefix=settings.API_PREFIX)]],
    })
    -- sorted by the path without its leading {expression}s, as the picker shows it
    eq({
      "GET {settings.HEALTH} health main.py:10",
      "GET {settings.API_PREFIX}/api/v1/a/b ab main.py:8",
      "GET {settings.API_PREFIX}/api/v1/api/ping/{n} ping main.py:6",
    }, list())
  end
)

test(
  "each route decorator is a route on its own line, every api_route method one, same paths in method order",
  function()
    project({
      ["main.py"] = [[
from fastapi import FastAPI
import functools
app = FastAPI()
@app.head("/items")
@app.get("/items")
def items(): ...
@app.api_route("/any", methods=["PATCH", "PUT"])
def any_(): ...
@app.websocket("/ws")
async def ws(websocket): ...
@app.delete(path="/items/{id}", deprecated=True)
def delete_item(id: int): ...
@app.exception_handler(ValueError)
def on_error(request, exc): ...
@app.middleware("http")
async def mw(request, call_next): ...
@functools.cache
def helper(): ...
@app.on_event("startup")
def start(): ...
@app.post("/old", deprecated=False)
def old(): ...]],
    })
    local nb = start()
    eq({
      "PUT /any any_ main.py:7",
      "PATCH /any any_ main.py:7",
      "GET /items items main.py:5",
      "HEAD /items items main.py:4",
      "DELETE /items/{id} delete_item main.py:11",
      "POST /old old main.py:21",
      "WEBSOCKET /ws ws main.py:9",
    }, list(nb))
    local deprecated = vim.tbl_map(
      function(r) return r.name end,
      vim.tbl_filter(function(r) return r.deprecated end, nb.fastapi.routes())
    )
    eq({ "delete_item" }, deprecated)
  end
)

test("a mounted app's routes are under its mount path, and not listed again on their own", function()
  project({
    ["admin.py"] = [[
from fastapi import FastAPI
admin_app = FastAPI()
@admin_app.get("/users")
def users(): ...]],
    ["main.py"] = [[
from fastapi import FastAPI
from admin import admin_app
app = FastAPI()
app.mount("/admin", admin_app)
@app.get("/")
def home(): ...]],
  })
  eq({ "GET / home main.py:5", "GET /admin/users users admin.py:3" }, list())
end)

-- Two services; svc_b has two apps in one file
local SERVICES = {
  ["svc_a/main.py"] = [[
from fastapi import FastAPI
app = FastAPI()
@app.get("/a")
def a(): ...]],
  ["svc_b/main.py"] = [[
from fastapi import FastAPI
app = FastAPI()
admin = FastAPI()
@app.get("/b")
def b(): ...
@admin.get("/admin")
def adm(): ...]],
}

test(
  "the apps are the entrypoint option's, else pyproject.toml's [tool.fastapi] entrypoint's, else every FastAPI()",
  function()
    project(SERVICES)
    eq({ "GET /a a svc_a/main.py:3", "GET /admin adm svc_b/main.py:6", "GET /b b svc_b/main.py:4" }, list())
    local dir = project(SERVICES)
    vim.fn.writefile(
      { "[project]", 'name = "x"', "", "[tool.fastapi]", 'entrypoint = "svc_b.main:admin"' },
      dir .. "/pyproject.toml"
    )
    eq({ "GET /admin adm svc_b/main.py:6" }, list())
    eq({ "GET /a a svc_a/main.py:3" }, list(start({ entrypoint = "svc_a.main:app" })))
  end
)

test("an entrypoint that names no file or no app is an error that names it", function()
  project(SERVICES)
  for _, entry in ipairs({ "svc_c.main:app", "svc_a.main:nope" }) do
    local fine, err = pcall(start({ entrypoint = entry }).fastapi.routes)
    ok(not fine, entry .. " gave routes")
    ok(tostring(err):find(entry, 1, true), ("the error doesn't name %s: %s"):format(entry, err))
  end
end)

test("tests, test files, conftest.py, virtualenvs and caches aren't searched for apps", function()
  local app = 'from fastapi import FastAPI\napp = FastAPI()\n@app.get("/%s")\ndef h(): ...'
  project({
    ["src/app.py"] = app:format("real"),
    ["tests/main.py"] = app:format("t1"),
    ["test/main.py"] = app:format("t2"),
    ["pkg/test_main.py"] = app:format("t3"),
    ["pkg/main_test.py"] = app:format("t4"),
    ["pkg/conftest.py"] = app:format("t5"),
    [".venv/lib/main.py"] = app:format("t6"),
    ["venv/lib/main.py"] = app:format("t7"),
    ["node_modules/x/main.py"] = app:format("t8"),
    ["pkg/__pycache__/main.py"] = app:format("t9"),
  })
  eq({ "GET /real h src/app.py:3" }, list())
end)

test("the exclude option names the folders skipped instead", function()
  local app = 'from fastapi import FastAPI\napp = FastAPI()\n@app.get("/%s")\ndef h(): ...'
  project({ ["src/app.py"] = app:format("real"), ["legacy/app.py"] = app:format("old") })
  eq({ "GET /real h src/app.py:3" }, list(start({ exclude = { "legacy" } })))
end)

test("an app made by a factory function is found through the factory, in its module or another", function()
  project({
    ["factory_main.py"] = "from app import create_app\napp = create_app()",
    ["app.py"] = [[
from fastapi import FastAPI
from routers import router
def create_app() -> FastAPI:
    app = FastAPI()
    app.include_router(router, prefix="/users")
    return app]],
    ["routers.py"] = [[
from fastapi import APIRouter
router = APIRouter()
@router.get("/{user_id}")
def get_user(user_id: int): ...]],
    ["main.py"] = [[
from app import get_fastapi_app
app = get_fastapi_app()
@app.get("/1")
def one(): ...]],
  })
  eq({ "GET /users/{user_id} get_user routers.py:3" }, list(start({ entrypoint = "factory_main:app" })))
  eq({ "GET /1 one main.py:3" }, list(start({ entrypoint = "main:app" })))
end)

test("routers that include each other, in two files or one, give each route once", function()
  project({
    ["main.py"] = "from fastapi import FastAPI\nfrom a import router\napp = FastAPI()\napp.include_router(router)",
    ["a.py"] = [[
from fastapi import APIRouter
from b import router as b_router
router = APIRouter(prefix="/a")
router.include_router(b_router)
@router.get("/x")
def ax(): ...]],
    ["b.py"] = [[
from fastapi import APIRouter
from a import router as a_router
router = APIRouter(prefix="/b")
router.include_router(a_router)
@router.get("/y")
def by(): ...]],
  })
  eq({ "GET /a/b/y by b.py:5", "GET /a/x ax a.py:5" }, list())
  project({
    ["main.py"] = [[
from fastapi import FastAPI, APIRouter
app = FastAPI()
r1 = APIRouter(prefix="/one")
r2 = APIRouter(prefix="/two")
r1.include_router(r2)
r2.include_router(r1)
app.include_router(r1)
@r2.get("/z")
def z(): ...]],
  })
  eq({ "GET /one/two/z z main.py:8" }, list())
end)

test("routes follow files changed on disk, and unsaved edits in a buffer", function()
  local dir = project({ ["main.py"] = 'from fastapi import FastAPI\napp = FastAPI()\n@app.get("/old")\ndef h(): ...' })
  local nb = start()
  eq({ "GET /old h main.py:3" }, list(nb))
  -- the same length and likely the same second as before, so only the change itself can show it
  vim.fn.writefile(
    { "from fastapi import FastAPI", "app = FastAPI()", '@app.get("/dsk")', "def h(): ..." },
    dir .. "/main.py"
  )
  eq({ "GET /dsk h main.py:3" }, list(nb))
  vim.cmd.edit("main.py")
  vim.api.nvim_buf_set_lines(0, 2, 3, false, { "", '@app.get("/new")' })
  eq({ "GET /new h main.py:4" }, list(nb))
end)

-- the parts of snacks the picker calls: Snacks.picker.pick, its options kept in _G.picked
local function fake_snacks()
  _G.picked = nil
  _G.Snacks = { did_setup = true, picker = { pick = function(opts) _G.picked = opts end } }
end

---@return { msg: string, level: integer? }[] notes the vim.notify() calls from now on
local function notes()
  local seen = {}
  vim.notify = function(msg, level) seen[#seen + 1] = { msg = msg, level = level } end
  return seen
end

local function here()
  return ("%s:%d"):format(vim.fs.relpath(vim.fn.getcwd(), vim.api.nvim_buf_get_name(0)), vim.fn.line("."))
end

test(
  "pick() opens snacks' picker on every route, in order, each at its file and line, filterable by its parts",
  function()
    project(PACKAGE)
    fake_snacks()
    start().fastapi.pick()
    ok(_G.picked, "no picker opened")
    local at = vim.tbl_map(
      function(item) return ("%s:%d:%d"):format(vim.fs.relpath(vim.fn.getcwd(), item.file), item.pos[1], item.pos[2]) end,
      _G.picked.items
    )
    eq({ "app/main.py:7:0", "app/routes/users.py:3:0", "app/routes/users.py:5:0", "app/routes/items.py:3:0" }, at)
    local item = _G.picked.items[3]
    for _, part in ipairs({ "GET", "/api/users/{user_id}", "get_user", "app/routes/users.py" }) do
      ok(item.text:find(part, 1, true), ("%q isn't in the text the picker filters: %q"):format(part, item.text))
    end
  end
)

test("in the picker, the router action opens where the route's router or app is made; yank copies the path", function()
  project(PACKAGE)
  fake_snacks()
  start().fastapi.pick()
  local picker = { close = function() end }
  _G.picked.actions.router(picker, _G.picked.items[2])
  eq("app/routes/users.py:2", here())
  _G.picked.actions.router(picker, _G.picked.items[1])
  eq("app/main.py:4", here())
  project({
    ["main.py"] = [[
from fastapi import FastAPI, APIRouter
from config import settings
app = FastAPI()
r = APIRouter()
@r.get("/users")
def users(): ...
app.include_router(r, prefix=settings.API)]],
  })
  start().fastapi.pick()
  -- what the picker yanks: the path without its leading {expression}s, as the extension copies it
  eq("/users", _G.picked.items[1].data)
end)

test("without snacks, pick() offers the routes in vim.ui.select and opens the chosen one", function()
  project(PACKAGE)
  _G.Snacks = nil
  local offered
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, opts, on_choice)
    offered = vim.tbl_map(opts.format_item, items)
    on_choice(items[3], 3)
  end
  start().fastapi.pick()
  eq(4, offered and #offered)
  ok(offered[3]:find("/api/users/{user_id}", 1, true) and offered[3]:find("get_user", 1, true), offered[3])
  eq("app/routes/users.py:5", here())
end)

test("pick() with no routes says so and opens no picker", function()
  project({ ["main.py"] = "print('no app here')" })
  fake_snacks()
  local seen = notes()
  start().fastapi.pick()
  eq(nil, _G.picked)
  ok(#seen == 1 and seen[1].msg:lower():find("no fastapi routes", 1, true), vim.inspect(seen))
end)

test("while the module is switched off, pick() opens no picker and says why", function()
  project(PACKAGE)
  fake_snacks()
  local seen = notes()
  local nb = start()
  nb.toggle("fastapi", false)
  nb.fastapi.pick()
  eq(nil, _G.picked)
  ok(#seen == 1 and seen[1].msg:find("off", 1, true), vim.inspect(seen))
end)

test("without a Python parser, routes() fails and pick() says the parser is missing", function()
  local dir = project(PACKAGE)
  local script = vim.fn.tempname() .. ".lua"
  -- a child Neovim with no Python parser on 'runtimepath', whatever this machine has installed
  vim.fn.writefile({
    ("vim.opt.rtp:prepend(%q)"):format(root),
    "for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do",
    "  if vim.uv.fs_stat(p .. '/parser/python.so') then vim.opt.rtp:remove(p) end",
    "end",
    ("vim.fn.chdir(%q)"):format(dir),
    "require('neoblocks').setup({ fastapi = {} })",
    "local ok = pcall(Neoblocks.fastapi.routes)",
    "local msg",
    "vim.notify = function(m) msg = m end",
    "Neoblocks.fastapi.pick()",
    "io.stdout:write(tostring(ok), '\\n', tostring(msg))",
  }, script)
  local out = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script }):wait()
  local lines = vim.split(out.stdout, "\n")
  eq("false", lines[1], out.stderr)
  local msg = lines[2]:lower()
  ok(msg:find("parser", 1, true) and msg:find("python", 1, true), out.stdout)
end)
