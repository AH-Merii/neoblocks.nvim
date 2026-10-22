-- What finding a project's routes costs. There's no Neovim plugin this replaces (fastapi-vscode is a VS Code
-- extension), so this measures the module alone, on a generated project: an app including 50 routers of 20 routes
-- each (1000 routes), beside 1000 Python files that don't mention FastAPI, as most of a real project's files.
--
--   nvim --clean --headless -l bench/fastapi.lua [folder holding parser/python.so]
--
-- The folder defaults to $NEOBLOCKS_TEST_PARSERS, then ~/.local/share/nvim/site (nvim-treesitter's). Times are ms,
-- the median of 7 rounds:
-- - cold: routes() with nothing read yet, the first pick() of a session: every file walked, the 51 app and router
--   files parsed and the other 1000 read for "FastAPI(";
-- - warm: routes() again with nothing changed: every file walked and stat()ed, nothing read;
-- - one file saved: routes() after a router file changed on disk: that file parsed again;
-- - one buffer edited: routes() after an unsaved edit to a loaded router file.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.rtp:prepend(root)
local parsers = arg[1] or vim.env.NEOBLOCKS_TEST_PARSERS or vim.fs.normalize("~/.local/share/nvim/site")
vim.opt.rtp:append(parsers)
assert(vim.treesitter.language.add("python"), "no python parser in " .. parsers .. "/parser")

local scratch = vim.fs.normalize("~/.cache/neoblocks/fastapi/bench")
local ROUTERS, ROUTES, OTHERS = 50, 20, 1000
vim.fn.delete(scratch, "rf")

---@param rel string
---@param lines string[]
local function write(rel, lines)
  local path = scratch .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---@param i integer
---@param tag string a word that changes the file's contents, not its routes
local function router(i, tag)
  local lines = { "from fastapi import APIRouter", ("router = APIRouter(prefix='/r%d')  # %s"):format(i, tag) }
  for j = 1, ROUTES do
    vim.list_extend(lines, {
      "",
      ("@router.%s('/item%d/{id}')"):format(({ "get", "post", "put", "delete" })[j % 4 + 1], j),
      ("async def handler_%d_%d(id: int):"):format(i, j),
      ("    return {'router': %d, 'route': %d, 'id': id}"):format(i, j),
    })
  end
  return lines
end

local main = { "from fastapi import FastAPI" }
for i = 1, ROUTERS do
  main[#main + 1] = ("from app.routes import r%d"):format(i)
  write(("app/routes/r%d.py"):format(i), router(i, "a"))
end
main[#main + 1] = "app = FastAPI()"
for i = 1, ROUTERS do
  main[#main + 1] = ("app.include_router(r%d.router, prefix='/api')"):format(i)
end
write("app/__init__.py", {})
write("app/routes/__init__.py", {})
write("app/main.py", main)
for i = 1, OTHERS do
  local body = {}
  for j = 1, 40 do
    body[j] = ("def f%d(x):\n    return x * %d"):format(j, j)
  end
  write(("lib/pkg%d/mod%d.py"):format(i % 20, i), body)
end
vim.fn.chdir(scratch)

local function fresh()
  for name in pairs(package.loaded) do
    if name == "neoblocks" or name:match("^neoblocks%.") then
      package.loaded[name] = nil
    end
  end
  _G.Neoblocks = nil
  local nb = require("neoblocks")
  nb.setup({ fastapi = {} })
  return nb
end

---@param fn fun()
---@return number ms
local function time(fn)
  local t = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - t) / 1e6
end

local ops = { "cold", "warm", "one file saved", "one buffer edited" }
local results = {} ---@type table<string, number[]>
for _, op in ipairs(ops) do
  results[op] = {}
end
for round = 1, 7 do
  local nb = fresh()
  local n = 0
  table.insert(results.cold, time(function() n = #nb.fastapi.routes() end))
  assert(n == ROUTERS * ROUTES, ("found %d routes, want %d"):format(n, ROUTERS * ROUTES))
  table.insert(results.warm, time(function() nb.fastapi.routes() end))
  write("app/routes/r7.py", router(7, "saved " .. round))
  table.insert(results["one file saved"], time(function() nb.fastapi.routes() end))
  vim.cmd.edit("app/routes/r9.py")
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { ("router = APIRouter(prefix='/r9')  # edit %d"):format(round) })
  table.insert(results["one buffer edited"], time(function() nb.fastapi.routes() end))
  vim.cmd("bwipeout!")
end

io.write(("%d routes in %d routers, %d other files; ms, median of 7\n"):format(ROUTERS * ROUTES, ROUTERS, OTHERS))
for _, op in ipairs(ops) do
  local t = results[op]
  table.sort(t)
  io.write(("%-18s %8.1f\n"):format(op, t[4]))
end
