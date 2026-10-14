-- Offline test runner, no dependencies: `nvim -l tests/run.lua [name...]` runs tests/*_spec.lua (or those whose name
-- contains one of the arguments), each file in its own `nvim --clean` so no state leaks between files.
--
-- A spec file calls test(name, fn); inside, eq(want, got) and ok(cond, msg) fail the test. fresh() unloads neoblocks
-- and returns a new require("neoblocks"), for a test that needs setup() again.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))

if arg[1] == "--spec" then
  vim.opt.rtp:prepend(root)
  vim.cmd.runtime("plugin/neoblocks.lua")
  local tests = {} ---@type { name: string, fn: function }[]
  _G.test = function(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
  _G.eq = function(want, got, msg)
    if not vim.deep_equal(want, got) then
      error(("%swant %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(want), vim.inspect(got)), 2)
    end
  end
  _G.ok = function(cond, msg)
    if not cond then
      error(msg or "not ok", 2)
    end
  end
  _G.fresh = function()
    for name in pairs(package.loaded) do
      if name == "neoblocks" or name:match("^neoblocks%.") then
        package.loaded[name] = nil
      end
    end
    -- vim.g and vim.b can't be iterated (LuaJIT has no __pairs), so list their names from Vimscript
    for key in pairs(vim.fn.eval("g:")) do
      if key:match("^neoblocks_") then
        vim.g[key] = nil
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      for key in pairs(vim.fn.getbufvar(buf, "")) do
        if key:match("^neoblocks_") then
          vim.b[buf][key] = nil
        end
      end
    end
    _G.Neoblocks = nil
    return require("neoblocks")
  end
  dofile(arg[2])
  local failed = 0
  for _, t in ipairs(tests) do
    local pass, err = xpcall(t.fn, debug.traceback)
    if pass then
      io.write("  ok   ", t.name, "\n")
    else
      failed = failed + 1
      io.write("  FAIL ", t.name, "\n       ", (err:gsub("\n", "\n       ")), "\n")
    end
  end
  if #tests == 0 then
    io.write("  FAIL no tests in ", arg[2], "\n")
    failed = 1
  end
  os.exit(failed == 0 and 0 or 1)
end

local files = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
local filters = { unpack(arg) }
local failed, ran = {}, 0
for _, file in ipairs(files) do
  local name = vim.fs.basename(file):gsub("_spec%.lua$", "")
  if #filters == 0 or vim.iter(filters):any(function(f) return name:find(f, 1, true) ~= nil end) then
    ran = ran + 1
    io.write(name, "\n")
    local out = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", root .. "/tests/run.lua", "--spec", file }, { cwd = root })
      :wait()
    io.write(out.stdout)
    if out.code ~= 0 then
      io.write(out.stderr)
      failed[#failed + 1] = name
    end
  end
end
if ran == 0 then
  io.write("no spec file matches ", table.concat(filters, " "), "\n")
  os.exit(1)
end
if #failed > 0 then
  io.write("failed: ", table.concat(failed, ", "), "\n")
  os.exit(1)
end
io.write(("all %d spec files passed\n"):format(ran))
