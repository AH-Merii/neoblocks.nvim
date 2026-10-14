-- setup(), options, the on/off switches and :Neoblocks, checked with stand-in modules on 'runtimepath'
local dir = vim.fn.tempname()
local calls = {} ---@type table<string, { setup?: integer, refresh: (integer|string)[] }> setup() and refresh() calls

--- A module file in a temp dir that counts its setup() and refresh() calls.
local function module(name)
  local path = ("%s/lua/neoblocks/%s.lua"):format(dir, name)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({
    "local M = { meta = { desc = 'stand-in' } }",
    ("function M.setup() _G.calls.%s.setup = (_G.calls.%s.setup or 0) + 1 end"):format(name, name),
    ("function M.refresh(buf) table.insert(_G.calls.%s.refresh, buf or 'all') end"):format(name),
    "return M",
  }, path)
  calls[name] = { refresh = {} }
end
_G.calls = calls
module("alpha")
module("beta")
module("gamma")
vim.fn.mkdir(dir .. "/lua/neoblocks/delta", "p")
vim.fn.writefile(
  { "return { meta = { desc = 'folder module' }, setup = function() end }" },
  dir .. "/lua/neoblocks/delta/init.lua"
)
vim.opt.rtp:append(dir)

local function reset()
  for name in pairs(calls) do
    calls[name] = { refresh = {} }
  end
  return fresh()
end

test("modules are found as files and folders on 'runtimepath', without the core files", function()
  local modules = require("neoblocks.meta").modules()
  for _, name in ipairs({ "alpha", "beta", "gamma", "delta" }) do
    ok(vim.list_contains(modules, name), name .. " missing from " .. vim.inspect(modules))
  end
  for _, core in ipairs({ "init", "config", "meta", "util", "health", "types" }) do
    ok(not vim.list_contains(modules, core), core .. " listed as a module")
  end
end)

test("every module shipped in lua/neoblocks/ has a one-line meta.desc", function()
  local shipped = vim.fn.glob(vim.fn.getcwd() .. "/lua/neoblocks/*", false, true)
  local core = require("neoblocks.meta").core
  for _, path in ipairs(shipped) do
    local name = vim.fs.basename(path):gsub("%.lua$", "")
    if not core[name] then
      local desc = vim.tbl_get(require("neoblocks." .. name), "meta", "desc")
      ok(type(desc) == "string" and desc ~= "" and not desc:find("\n"), name .. ": meta.desc is " .. vim.inspect(desc))
    end
  end
  ok(
    vim.list_contains(shipped, vim.fn.getcwd() .. "/lua/neoblocks/init.lua"),
    "lua/neoblocks/ not found: " .. vim.inspect(shipped)
  )
end)

test("setup() starts each module it names, once, and loads no other", function()
  local nb = reset()
  nb.setup({ alpha = {}, beta = { some = 1 } })
  eq(1, calls.alpha.setup, "alpha")
  eq(1, calls.beta.setup, "beta")
  eq(nil, calls.gamma.setup, "gamma")
  eq(nil, package.loaded["neoblocks.gamma"], "gamma loaded")
end)

test("setup() leaves a module with enabled = false off", function()
  local nb = reset()
  nb.setup({ alpha = { enabled = false } })
  eq(nil, calls.alpha.setup)
  ok(not require("neoblocks.util").enabled("alpha"), "alpha counts as on")
end)

test("a second setup() is refused and starts nothing again", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  local notified
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level) notified = { msg, level } end
  nb.setup({ alpha = {}, beta = {} })
  eq(1, calls.alpha.setup)
  eq(nil, calls.beta.setup)
  eq(vim.log.levels.ERROR, notified and notified[2])
end)

test(
  "options are the defaults with the user's on top: tables merge, lists are replaced, defaults stay as they were",
  function()
    local nb = reset()
    nb.setup({ alpha = { a = 2, t = { y = 3 }, list = { "z" } } })
    local defaults = { a = 1, b = 1, t = { x = 1, y = 1 }, list = { "p", "q" }, n = { k = 1 } }
    local got = require("neoblocks.config").get("alpha", defaults)
    eq({ a = 2, b = 1, t = { x = 1, y = 3 }, list = { "z" }, n = { k = 1 } }, got)
    got.n.k = 2 -- a module changing its options must not change the defaults the next get() starts from
    eq({ a = 1, b = 1, t = { x = 1, y = 1 }, list = { "p", "q" }, n = { k = 1 } }, defaults, "defaults changed")
  end
)

test("a module that wasn't named gets its defaults and counts as off", function()
  reset()
  eq({ a = 1 }, require("neoblocks.config").get("gamma", { a = 1 }))
  ok(not require("neoblocks.util").enabled("gamma"), "gamma counts as on")
end)

test("a buffer's switch wins over the global one, either way", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  local util = require("neoblocks.util")
  local buf = vim.api.nvim_get_current_buf()
  ok(util.enabled("alpha", buf), "on by default")
  vim.g.neoblocks_alpha = false
  ok(not util.enabled("alpha", buf), "global off")
  vim.b[buf].neoblocks_alpha = true
  ok(util.enabled("alpha", buf), "buffer on over global off")
  vim.g.neoblocks_alpha = true
  vim.b[buf].neoblocks_alpha = false
  ok(not util.enabled("alpha", buf), "buffer off over global on")
  ok(util.enabled("alpha"), "no buffer: the global switch")
end)

test("toggle() flips the switch, sets one buffer's only when given one, and tells the module", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  local util = require("neoblocks.util")
  local buf, other = vim.api.nvim_get_current_buf(), vim.api.nvim_create_buf(true, false)
  nb.toggle("alpha", nil, buf)
  ok(not util.enabled("alpha", buf), "buffer still on")
  ok(util.enabled("alpha", other), "other buffer switched off too")
  nb.toggle("alpha", nil, buf)
  ok(util.enabled("alpha", buf), "buffer not back on")
  nb.toggle("alpha", false)
  ok(not util.enabled("alpha", other), "global off didn't reach the other buffer")
  nb.toggle("alpha", false)
  ok(not util.enabled("alpha", other), "toggle(false) flipped instead of setting")
  eq({ buf, buf, "all", "all" }, calls.alpha.refresh)
end)

test(":Neoblocks switches a module, in the current buffer with a bang", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  local util = require("neoblocks.util")
  local other = vim.api.nvim_create_buf(true, false)
  vim.cmd("Neoblocks! alpha off")
  ok(not util.enabled("alpha", 0), "current buffer on")
  ok(util.enabled("alpha", other), "bang reached another buffer")
  vim.cmd("Neoblocks alpha off")
  ok(not util.enabled("alpha", other), "off")
  vim.cmd("Neoblocks alpha on")
  ok(util.enabled("alpha", other), "on")
  vim.cmd("Neoblocks alpha toggle")
  ok(not util.enabled("alpha", other), "toggle")
end)

test(":Neoblocks refuses unknown modules and actions, and modules setup() left off", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  local errors = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
  end
  vim.cmd("Neoblocks nope on")
  vim.cmd("Neoblocks alpha sideways")
  vim.cmd("Neoblocks beta on")
  eq(3, #errors, vim.inspect(errors))
  eq(nil, vim.g.neoblocks_beta, "beta switched")
  eq({}, calls.beta.refresh, "beta told")
end)

test(":Neoblocks completes module names, then actions", function()
  reset()
  local modules = vim.fn.getcompletion("Neoblocks ", "cmdline")
  ok(vim.list_contains(modules, "alpha") and vim.list_contains(modules, "delta"), vim.inspect(modules))
  eq({ "on", "off", "toggle" }, vim.fn.getcompletion("Neoblocks alpha ", "cmdline"))
end)

test(":checkhealth neoblocks reports setup and each module as on or off", function()
  local nb = reset()
  nb.setup({ alpha = {} })
  vim.cmd("checkhealth neoblocks")
  -- nightly fills the report after the command returns
  local text = ""
  vim.wait(2000, function()
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return text:find("neoblocks.gamma", 1, true) ~= nil
  end)
  ok(text:find("setup() called", 1, true), text)
  ok(text:find("neoblocks%.alpha: stand%-in.-on"), "alpha not on:\n" .. text)
  ok(text:find("neoblocks%.beta: stand%-in.-off"), "beta not off:\n" .. text)
end)
