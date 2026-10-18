-- The statusline module: lualine's layout and spacing, colours, built-ins, when it rebuilds, and on/off.
-- Expected text comes from lualine's drawing rules (docs/decisions/statusline.md, parity 3), written out by hand.
-- Tests run with -l, where typed keys and clicks aren't processed; the ones that need them (clicks, Insert mode) run
-- in a child Neovim's main loop.
local root = vim.fn.getcwd()

--- Waits out the rebuild rate cap (lualine's 16 ms) and two loop ticks, so a rebuild an event asked for has run.
local function flush()
  local done = false
  vim.defer_fn(function()
    vim.schedule(function()
      vim.schedule(function() done = true end)
    end)
  end, 20)
  vim.wait(1000, function() return done end)
end

--- The statusline as Neovim draws it, 200 cells wide, each '%=' fill shown as one "|"; and the raw result.
--- Fills are drawn with "~" so they can't be told apart from spaces.
local function render()
  local r = vim.api.nvim_eval_statusline(
    vim.o.statusline,
    { winid = vim.api.nvim_get_current_win(), maxwidth = 200, fillchar = "~", highlights = true }
  )
  return (r.str:gsub("~+", "|")), r
end

--- The highlight drawn at the first `text` in the line: its attributes (links followed) and its group.
---@return vim.api.keyset.get_hl_info, string
local function hl_of(text)
  local _, r = render()
  local at = r.str:find(text, 1, true)
  assert(at, ("%q not in %q"):format(text, r.str))
  local group = "StatusLine"
  for _, h in ipairs(r.highlights) do
    if h.start <= at - 1 then
      group = h.group
    end
  end
  return vim.api.nvim_get_hl(0, { name = group, link = false }), group
end

--- A component function that returns `text` and counts its calls in calls[text].
local calls = {} ---@type table<string, integer>
local function counted(text)
  calls[text] = 0
  return function()
    calls[text] = calls[text] + 1
    return text
  end
end

local function fn(text)
  return function() return text end
end

local notify = vim.notify

--- Collects the ERROR notifications from now on (clean() puts vim.notify back).
local function reported()
  local list = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      list[#list + 1] = msg
    end
  end
  return list
end

--- How many of `list` contain `text`.
local function count_of(list, text)
  return #vim.tbl_filter(function(m) return m:find(text, 1, true) ~= nil end, list)
end

--- A clean window and buffer, no autocmds or scheduled rebuilds left from an earlier test's module, and the options
--- the module changes back to Neovim's defaults.
local function clean()
  flush()
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if au.group_name and tostring(au.group_name):lower():find("neoblocks", 1, true) then
      pcall(vim.api.nvim_del_autocmd, au.id)
    end
  end
  vim.notify = notify
  vim.cmd("silent! only | enew!")
  vim.go.statusline = ""
  vim.wo.statusline = ""
  vim.o.laststatus = 2
  vim.v.hlsearch = 0
  vim.diagnostic.reset()
end

--- A fresh neoblocks with the statusline set up from opts (left and right default to empty); returns the module.
local function start(opts)
  clean()
  local nb = fresh()
  opts.left = opts.left or {}
  opts.right = opts.right or {}
  nb.setup({ statusline = opts })
  flush()
  return nb.statusline
end

--- Runs `code` in a child Neovim's main loop with neoblocks and these helpers (flush is not needed there: use
--- vim.defer_fn); `code` calls done(value) to return value.
local function child(code)
  local file = vim.fn.tempname() .. ".lua"
  local prelude = ([[
vim.opt.rtp:prepend(%q)
vim.cmd.runtime("plugin/neoblocks.lua")
function render()
  local r = vim.api.nvim_eval_statusline(vim.o.statusline, { maxwidth = 200, fillchar = "~" })
  return (r.str:gsub("~+", "|")), r
end
function done(v)
  io.stdout:write("\nRESULT", vim.json.encode(v), "\n")
  vim.cmd("qa!")
end
vim.defer_fn(function() done({ timeout = true }) end, 5000)
]]):format(root)
  vim.fn.writefile(vim.split(prelude .. code, "\n"), file)
  local out = vim
    .system({ vim.v.progpath, "--clean", "--headless", "-c", "luafile " .. file }, { timeout = 10000 })
    :wait()
  local json = (out.stdout or ""):match("RESULT(.-)\n")
  assert(json, ("child gave no result: %s %s"):format(out.stdout, out.stderr))
  local ret = vim.json.decode(json)
  assert(not ret.timeout, ("child timed out: %s"):format(out.stderr))
  return ret
end

--- A file at dir/sub/file.txt with a .git above it; HEAD holds `head`, or .git is a file pointing at `gitdir`, a path
--- relative to dir or an absolute one (as git worktrees write).
local function repo(head, opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  local gitdir = opts.gitdir and vim.startswith(opts.gitdir, "/") and opts.gitdir
    or (dir .. "/" .. (opts.gitdir or ".git"))
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.mkdir(gitdir, "p")
  vim.fn.writefile({ head }, gitdir .. "/HEAD")
  if opts.gitdir then
    vim.fn.writefile({ "gitdir: " .. opts.gitdir }, dir .. "/.git")
  end
  vim.fn.writefile({ "x" }, dir .. "/sub/file.txt")
  return dir, gitdir
end

-- Layout and spacing ---------------------------------------------------------------------------------------------

test("setup() draws one global statusline: left, a fill, right", function()
  start({ left = { fn("L") }, right = { fn("R") } })
  eq(3, vim.o.laststatus)
  eq(" L | R ", (render()))
end)

test("a component is 'icon text' with one space each side; a padding table pads only the sides it names", function()
  start({
    left = {
      { fn("M"), padding = { right = 1 } },
      { fn("a"), icon = "I" },
      { fn("b"), padding = 0 },
      { fn("c"), padding = { left = 2 } },
      { fn("d"), padding = 2 },
    },
  })
  eq("M  I a b  c  d  |", (render()))
end)

test("padding takes the colour a component's text starts with, and the one it ends with before a %*", function()
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  local ns = vim.api.nvim_create_namespace("test")
  start({
    color = { fg = "#abb2bf" },
    left = {
      fn("%#TestStatuslineGroup#aa"),
      fn("%#TestStatuslineGroup#bb%*"),
      { fn("%#TestStatuslineGroup#cc"), icon = "I" },
      fn("d%#TestStatuslineGroup#d"),
      { "diagnostics", symbols = { error = "E" }, diagnostics_color = { error = { fg = "#ff0000" } } },
    },
  })
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = "m", severity = 1 } })
  flush()
  local line, r = render()
  eq(" aa  bb  I cc  dd  E1 |", line)
  --- The group drawing the cell at byte `at` (1-based) of the line.
  local function group_at(at)
    local group = "StatusLine"
    for _, h in ipairs(r.highlights) do
      if h.start <= at - 1 then
        group = h.group
      end
    end
    return group
  end
  -- lualine adds the left padding after a leading %#Group#, the right one before a trailing %*, and the icon
  -- before either (component.lua:97-115, 285-288)
  eq("TestStatuslineGroup", group_at(line:find(" aa", 1, true)), "left padding of text starting with a colour")
  eq("TestStatuslineGroup", group_at(line:find("bb ", 1, true) + 2), "right padding before a trailing %*")
  ok(group_at(line:find(" I", 1, true)) ~= "TestStatuslineGroup", "an icon comes before the text's colour")
  ok(group_at(line:find(" d", 1, true)) ~= "TestStatuslineGroup", "a colour change after the start")
  eq(0xff0000, vim.api.nvim_get_hl(0, { name = group_at(line:find(" E1", 1, true)), link = false }).fg, "built-in")
end)

test("an empty component, or one whose cond isn't true at the rebuild, draws nothing: no icon, no padding", function()
  _G.wide = false
  local sl = start({
    left = {
      fn("a"),
      { fn(""), icon = "I" },
      { fn(nil), icon = "J" },
      { fn("x"), icon = "K", cond = function() return false end },
      { fn("y"), cond = function() return true end },
      { fn("w"), cond = function() return _G.wide end },
      fn("b"),
    },
  })
  eq(" a  y  b |", (render()))
  _G.wide = true
  sl.refresh()
  eq(" a  y  w  b |", (render()), "cond became true")
  _G.wide = false
  sl.refresh()
  eq(" a  y  b |", (render()), "cond became false")
end)

test("a '%=' component in left centres what follows it, as the config's layout", function()
  start({
    left = { { fn("M"), padding = { right = 1 } }, fn("file"), fn("%="), fn("lsp") },
    right = { fn("main") },
  })
  eq("M  file  |  lsp | main ", (render()))
end)

test("a string starting with % is statusline text, padded like any component", function()
  start({ left = { "%{'r'.'aw'}", "%=" }, right = {} })
  eq(" raw  | |", (render()))
end)

test("statusline items in a component's text stay live: the line follows the cursor with no rebuild", function()
  start({ left = { counted("%l") } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "1", "2", "3", "4", "5", "6", "7" })
  local before = calls["%l"]
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  eq(" 7 |", (render()))
  eq(before, calls["%l"], "rebuilt")
end)

test("moving the cursor rebuilds and counts nothing while no search is highlighted", function()
  -- searchcount() scans the buffer: it's the per-move cost decision 14 rules out after :nohlsearch
  local searchcount, counts = vim.fn.searchcount, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.searchcount = function(...)
    counts = counts + 1
    return searchcount(...)
  end
  local ok_, err = pcall(function()
    start({ left = { counted("x") }, right = { "searchcount" } })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "needle", "hay", "needle" })
    vim.fn.setreg("/", "needle")
    vim.o.hlsearch = true
    vim.v.hlsearch = 0
    local before = calls.x
    ok(before > 0, "never built")
    counts = 0
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      vim.api.nvim_exec_autocmds("CursorMovedI", {})
    end
    flush()
    eq(before, calls.x, "rebuilt")
    eq(0, counts, "searchcount() calls")
    -- the same moves with the search highlighted do count, so the calls above would have been seen
    vim.v.hlsearch = 1
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    flush()
    ok(counts > 0, "searchcount() not seen while a search is highlighted")
  end)
  vim.fn.searchcount = searchcount
  assert(ok_, err)
end)

test("a string that is neither a built-in nor statusline text is reported, and the rest draws", function()
  local errors = {}
  clean()
  local nb = fresh()
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
  end
  nb.setup({ statusline = { left = { "diagnostic", fn("a") }, right = {} } })
  flush()
  eq(" a |", (render()))
  ok(#errors == 1 and errors[1]:find("diagnostic", 1, true), vim.inspect(errors))
end)

test("a component that errors draws nothing, the rest still draws, and it's reported once", function()
  local errors = {}
  clean()
  local nb = fresh()
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
  end
  nb.setup({ statusline = { left = { fn("a"), function() error("boom") end, fn("b") }, right = {} } })
  flush()
  local sl = nb.statusline
  sl.refresh()
  sl.refresh()
  eq(" a  b |", (render()))
  eq(1, #vim.tbl_filter(function(m) return m:find("boom", 1, true) ~= nil end, errors), vim.inspect(errors))
end)

test(
  "a component whose text isn't valid statusline syntax draws nothing, the rest still updates, reported once",
  function()
    -- the component's options change what the module writes around its text: padding, colour, click
    local forms = {
      { name = "default padding", opts = {}, ok = " ok  one |", fine = " fine  three |" },
      { name = "padding 0", opts = { padding = 0 }, ok = "ok one |", fine = "fine three |" },
      { name = "left padding only", opts = { padding = { left = 1 } }, ok = " ok one |", fine = " fine three |" },
      {
        name = "padding 0, a colour",
        opts = { padding = 0, color = { fg = "#e5c07b" } },
        ok = "ok one |",
        fine = "fine three |",
      },
      {
        name = "padding 0, a click",
        opts = { padding = 0, on_click = function() end },
        ok = "ok one |",
        fine = "fine three |",
      },
    }
    -- each a mistake 'statusline' rejects: an unknown item, an unclosed %{, an unclosed %(, a lone % at the end
    for _, bad in ipairs({ "50%x done", "%{line('.')", "%(a", "100%" }) do
      for _, form in ipairs(forms) do
        local name = ("%s, %s"):format(bad, form.name)
        clean()
        local nb = fresh()
        local errs = reported()
        _G.t, _G.v = "ok", "one"
        local first = vim.tbl_extend("error", { function() return _G.t end }, form.opts)
        nb.setup({ statusline = { left = { first, function() return _G.v end }, right = {} } })
        flush()
        eq(form.ok, (render()), name)
        _G.t, _G.v = bad, "two"
        nb.statusline.refresh()
        eq(" two |", (render()), name)
        _G.v = "three"
        vim.api.nvim_exec_autocmds("BufEnter", {})
        flush()
        eq(" three |", (render()), name .. ": after an event")
        eq(1, #errs, name .. ": " .. vim.inspect(errs))
        _G.t = "fine"
        nb.statusline.refresh()
        eq(form.fine, (render()), name .. ": text that's valid again")
      end
    end
  end
)

test("a name in `events` that isn't an event is reported; the line, the other events and colours still work", function()
  clean()
  local nb = fresh()
  local errs = reported()
  _G.value = "one"
  -- WinResize: a typo for WinResized, which decision 5 tells the config to add; on either side of the good ones
  local ok_, err = pcall(nb.setup, {
    statusline = {
      color = { fg = "#abb2bf" },
      events = { "NotAnEvent", "BufWritePost", "WinResize" },
      left = { function() return _G.value end },
      right = {},
    },
  })
  ok(ok_, "setup() raised " .. tostring(err))
  flush()
  eq(" one |", (render()), "drawn by setup()")
  eq(1, count_of(errs, "NotAnEvent"), vim.inspect(errs))
  eq(1, count_of(errs, "WinResize"), vim.inspect(errs))
  _G.value = "two"
  vim.api.nvim_exec_autocmds("BufWritePost", {})
  flush()
  eq(" two |", (render()), "an event listed with them")
  vim.cmd.colorscheme("default")
  flush()
  eq(0xabb2bf, hl_of("two").fg, "after :colorscheme")
end)

-- When it rebuilds ---------------------------------------------------------------------------------------------------

test("an event in `events` rebuilds the line, once for several in the same tick; other events don't", function()
  local n = 0
  start({
    events = { "BufWritePost", "FileType" },
    left = {
      function()
        n = n + 1
        return "n" .. n
      end,
    },
  })
  local built = n
  ok(built > 0, "never built")
  vim.api.nvim_exec_autocmds("BufWritePost", {})
  vim.api.nvim_exec_autocmds("FileType", {})
  vim.api.nvim_exec_autocmds("BufWritePost", {})
  flush()
  eq(built + 1, n, "builds")
  eq((" n%d |"):format(built + 1), (render()))
  vim.api.nvim_exec_autocmds("WinEnter", {})
  flush()
  eq(built + 1, n, "WinEnter isn't in events")
end)

test("an event's rebuild runs after the other handlers of that event, even ones added later", function()
  _G.value = "old"
  start({ events = { "BufWritePost" }, left = { function() return _G.value end } })
  vim.api.nvim_create_autocmd("BufWritePost", { callback = function() _G.value = "new" end })
  vim.api.nvim_exec_autocmds("BufWritePost", {})
  flush()
  eq(" new |", (render()))
end)

test("a burst of events rebuilds at most once per 16 ms, and the line ends with the last event's state", function()
  local n = 0
  start({
    events = { "BufWritePost" },
    left = {
      function()
        n = n + 1
        return "v" .. tostring(_G.burst)
      end,
    },
  })
  local built, t0 = n, vim.uv.hrtime()
  -- one event per loop tick, as a language server's progress messages arrive
  for i = 1, 100 do
    _G.burst = i
    vim.api.nvim_exec_autocmds("BufWritePost", {})
    vim.wait(1)
  end
  flush()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  ok(n - built <= ms / 16 + 2, ("%d rebuilds in %d ms"):format(n - built, ms))
  eq(" v100 |", (render()))
end)

test("a rebuild that gives the same line leaves 'statusline' alone; one that changes it writes it", function()
  _G.value = "same"
  local sl = start({ left = { function() return _G.value end } })
  local writes = 0
  local au = vim.api.nvim_create_autocmd("OptionSet", {
    pattern = "statusline",
    callback = function() writes = writes + 1 end,
  })
  sl.refresh()
  vim.api.nvim_exec_autocmds("BufEnter", {})
  flush()
  eq(0, writes, "the same line")
  _G.value = "changed"
  sl.refresh()
  vim.api.nvim_del_autocmd(au)
  eq(1, writes, "a changed line")
  eq(" changed |", (render()))
end)

test("a rebuild while the command line is open reaches the screen, for the mode and for other events", function()
  -- on a real screen: a child Neovim in a terminal, its statusline read from the terminal's lines
  local init = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    ("vim.opt.rtp:prepend(%q)"):format(root),
    'vim.cmd.runtime("plugin/neoblocks.lua")',
    '_G.v = "early"',
    "require('neoblocks').setup({ statusline = { left = {",
    "  function() return 'MODE=' .. vim.fn.mode() .. ' V=' .. _G.v end,",
    "}, right = {} } })",
    -- an event that rebuilds the line, fired while the command line is open
    "vim.api.nvim_create_autocmd('CmdlineEnter', { callback = function()",
    "  vim.defer_fn(function() _G.v = 'late'; vim.api.nvim_exec_autocmds('BufEnter', {}) end, 500)",
    "end })",
  }, init)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 10 })
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "-u", init }, { term = true })
  local function status()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("MODE=", 1, true) then
        return vim.trim(line)
      end
    end
    return ""
  end
  local ok_, err = pcall(function()
    vim.wait(3000, function() return status() == "MODE=n V=early" end, 10)
    eq("MODE=n V=early", status(), "before")
    vim.api.nvim_chan_send(job, ":")
    vim.wait(400, function() return status() == "MODE=c V=early" end, 10)
    eq("MODE=c V=early", status(), "after ':' (ModeChanged)")
    vim.wait(2000, function() return status() == "MODE=c V=late" end, 10)
    eq("MODE=c V=late", status(), "an event with the command line open")
  end)
  vim.fn.jobstop(job)
  vim.api.nvim_win_close(win, true)
  assert(ok_, err)
end)

test("refresh() rebuilds at once", function()
  _G.value = "old"
  local sl = start({ left = { function() return _G.value end } })
  _G.value = "new"
  sl.refresh()
  eq(" new |", (render()))
end)

-- Colours ------------------------------------------------------------------------------------------------------------

test("a colour table colours its component; the others take the top-level colour, not the one before them", function()
  start({ color = { fg = "#abb2bf" }, left = { { fn("aa"), color = { fg = "#e5c07b", bold = true } }, fn("bb") } })
  local aa, bb = hl_of("aa"), hl_of("bb")
  eq({ 0xe5c07b, true }, { aa.fg, aa.bold })
  eq(0xabb2bf, bb.fg)
  ok(not bb.bold, "the colour before it bled into it")
end)

test("a colour can be a group name, or a function called on each rebuild", function()
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  _G.fg = "#222222"
  local sl = start({
    left = { { fn("gg"), color = "TestStatuslineGroup" }, { fn("ff"), color = function() return { fg = _G.fg } end } },
  })
  eq(0x111111, hl_of("gg").fg)
  eq(0x222222, hl_of("ff").fg)
  _G.fg = "#333333"
  sl.refresh()
  eq(0x333333, hl_of("ff").fg)
end)

test("a component's colour covers its icon, whichever form the colour takes", function()
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  start({
    color = { fg = "#abb2bf" },
    left = {
      { fn("tt"), icon = "TI", color = { fg = "#e5c07b", bold = true } },
      { fn("gg"), icon = "GI", color = "TestStatuslineGroup" },
      { fn("ff"), icon = "FI", color = function() return { fg = "#222222" } end },
    },
  })
  -- lualine adds the icon before it colours the component (component.lua:170, 285-290)
  local t = hl_of("TI")
  eq({ 0xe5c07b, true }, { t.fg, t.bold }, "table")
  eq(0x111111, hl_of("GI").fg, "group name")
  eq(0x222222, hl_of("FI").fg, "function")
end)

test("every group the module draws with is a NeoblocksStatusline group with no background of its own", function()
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  start({
    color = { fg = "#abb2bf" },
    left = {
      { fn("aa"), color = { fg = "#e5c07b" } },
      { fn("gg"), color = "TestStatuslineGroup" },
      { "diagnostics", symbols = { error = "E" } },
      fn("plain"),
    },
  })
  vim.diagnostic.set(vim.api.nvim_create_namespace("test"), 0, { { lnum = 0, col = 0, message = "m", severity = 1 } })
  flush()
  local _, r = render()
  local groups = {}
  for _, h in ipairs(r.highlights) do
    if h.group ~= "StatusLine" then
      groups[h.group] = true
    end
  end
  ok(vim.tbl_count(groups) >= 4, "groups: " .. vim.inspect(groups))
  for group in pairs(groups) do
    ok(group:find("^NeoblocksStatusline"), group)
    eq(nil, vim.api.nvim_get_hl(0, { name = group, link = false }).bg, group .. " has a background")
  end
end)

test(
  "colours come back after a colourscheme clears the groups: top-level, tables, functions, names, defaults",
  function()
    vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
    start({
      color = { fg = "#abb2bf" },
      left = {
        fn("pp"),
        { fn("aa"), color = { fg = "#e5c07b" } },
        { fn("ff"), color = function() return { fg = "#333333" } end },
        { fn("gg"), color = "TestStatuslineGroup" },
        { "diagnostics", symbols = { hint = "H" } },
      },
    })
    vim.diagnostic.set(vim.api.nvim_create_namespace("test"), 0, { { lnum = 0, col = 0, message = "m", severity = 4 } })
    flush()
    vim.cmd.colorscheme("default")
    -- what the new colourscheme defines
    vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#222222" })
    vim.api.nvim_set_hl(0, "DiagnosticHint", { fg = "#00ff00" })
    flush()
    eq(0xabb2bf, hl_of("pp").fg, "top-level")
    eq(0xe5c07b, hl_of("aa").fg, "table")
    eq(0x333333, hl_of("ff").fg, "function")
    eq(0x222222, hl_of("gg").fg, "group name")
    eq(0x00ff00, hl_of("H1").fg, "diagnostics' default")
  end
)

test("the top-level colour can be a group name", function()
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  start({ color = "TestStatuslineGroup", left = { fn("pp") } })
  eq(0x111111, hl_of("pp").fg)
end)

test("a colour with no fg keeps the top-level text colour and adds its own attributes, as lualine's", function()
  -- lualine fills a missing fg from the section's colour (highlight.lua:281-308); StatusLine's fg is another one
  vim.api.nvim_set_hl(0, "StatusLine", { fg = "#93a4c3" })
  local forms = {
    table = { bold = true },
    ["function"] = function() return { bold = true } end,
  }
  for form, color in pairs(forms) do
    for _, top in ipairs({ { fg = "#abb2bf" }, "TestStatuslineGroup" }) do
      local name = form .. ", top-level " .. vim.inspect(top)
      vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#abb2bf" })
      start({ color = top, left = { { fn("bb"), color = color } } })
      local bb = hl_of("bb")
      eq({ 0xabb2bf, true }, { bb.fg, bb.bold }, name)
      if type(top) == "string" then
        -- a colourscheme that changes the top-level group: the fill follows it
        vim.cmd.colorscheme("default")
        vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#444444" })
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        flush()
        eq(0x444444, hl_of("bb").fg, name .. ", after :colorscheme")
        vim.api.nvim_set_hl(0, "StatusLine", { fg = "#93a4c3" })
      end
    end
  end
end)

test("a component's change of colour stays inside it: what follows, and the fill, take the default colour", function()
  -- lualine starts every component in the section's colour (component.lua:133-136)
  vim.api.nvim_set_hl(0, "TestStatuslineGroup", { fg = "#111111" })
  vim.api.nvim_set_hl(0, "User1", { fg = "#ff0000" })
  vim.api.nvim_set_hl(0, "StatusLine", { fg = "#93a4c3" })
  -- each way statusline text switches colour: a group, a User group, back to StatusLine
  for _, text in ipairs({ "%#TestStatuslineGroup#A", "%1*A", "A%*" }) do
    start({ color = { fg = "#abb2bf" }, left = { fn(text), fn("B") }, right = { fn("C") } })
    for _, after in ipairs({ "B", "C", "~" }) do
      eq(0xabb2bf, hl_of(after).fg, ("%s, then %q"):format(text, after))
    end
  end
end)

test("a colour Neovim rejects (lualine's gui = 'bold') is reported once and draws in the default colour", function()
  local bad = { fg = "#e5c07b", gui = "bold" }
  local cases = {
    { name = "a component's table", color = { fg = "#abb2bf" }, comp = { fn("aa"), color = bad }, want = 0xabb2bf },
    {
      name = "a colour function's result",
      color = { fg = "#abb2bf" },
      comp = { fn("aa"), color = function() return bad end },
      want = 0xabb2bf,
    },
    -- the default colour itself rejected: no colour of its own, so StatusLine's, as with no `color`
    { name = "the top-level colour", color = bad, comp = fn("aa"), want = nil },
  }
  for _, case in ipairs(cases) do
    clean()
    local nb = fresh()
    local errs = reported()
    local ok_, err =
      pcall(nb.setup, { statusline = { color = case.color, left = { case.comp, fn("bb") }, right = {} } })
    ok(ok_, case.name .. ": setup() raised " .. tostring(err))
    flush()
    nb.statusline.refresh()
    nb.statusline.refresh()
    eq(" aa  bb |", (render()), case.name)
    eq(case.want, hl_of("aa").fg, case.name)
    eq(1, count_of(errs, "gui"), case.name .. ": " .. vim.inspect(errs))
  end
end)

test("mode_color() picks the colour for the mode's first letter, the fallback for any other", function()
  local nb = fresh()
  local color = nb.statusline.mode_color({ n = { fg = "#000001" }, v = { fg = "#000002" } }, { fg = "#000003" })
  start({ left = { { fn("mm"), color = color } } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc", "def" })
  eq(0x000001, hl_of("mm").fg, "Normal")
  vim.api.nvim_feedkeys("v", "x", false)
  flush()
  eq(0x000002, hl_of("mm").fg, "Visual")
  vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "x", false)
  flush()
  eq(0x000003, hl_of("mm").fg, "Visual block")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  flush()
  eq(0x000001, hl_of("mm").fg, "Normal again")
end)

test("mode_color() keys on mode()'s first letter: a pending operator (mode no) takes Normal's colour", function()
  local got = child([[
local color = require("neoblocks.statusline").mode_color({ n = { fg = "#000001" } }, { fg = "#000003" })
require("neoblocks").setup({ statusline = { left = { { function() return "mm" end, color = color } }, right = {} } })
local function fg()
  local r = vim.api.nvim_eval_statusline(vim.o.statusline, { maxwidth = 200, highlights = true })
  local at, group = r.str:find("mm", 1, true), "StatusLine"
  for _, h in ipairs(r.highlights) do
    if h.start <= at - 1 then group = h.group end
  end
  return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
end
vim.defer_fn(function()
  vim.api.nvim_input("d")
  vim.defer_fn(function() done({ mode = vim.api.nvim_get_mode().mode, fg = fg() }) end, 100)
end, 100)
]])
  eq("no", got.mode, "not operator-pending")
  eq(0x000001, got.fg)
end)

-- Clicks -------------------------------------------------------------------------------------------------------------

test("a click anywhere on a component, icon and padding too, calls its on_click; a click elsewhere doesn't", function()
  -- lualine wraps the click around the padded text with its icon (component.lua:211-215,279-289)
  local got = child([[
vim.o.mouse = "a"
_G.hits = {}
require("neoblocks").setup({ statusline = { left = {
  { function() return "CLICKME" end, icon = "T", on_click = function(...) _G.hits[#_G.hits + 1] = { ... } end },
  function() return "other" end,
}, right = {} } })
-- " T CLICKME  other": columns 0 (padding), 1 (icon), 3 (text), 10 (padding); 11 and 12 are the next component's
local cols, out = { 0, 1, 3, 10, 11, 12 }, {}
local function click(i)
  if i > #cols then
    return done({ line = render(), hits = out, args = _G.hits[1] or false })
  end
  local before, row = #_G.hits, vim.o.lines - vim.o.cmdheight - 1
  vim.api.nvim_input_mouse("left", "press", "", 0, row, cols[i])
  vim.api.nvim_input_mouse("left", "release", "", 0, row, cols[i])
  vim.defer_fn(function()
    out[#out + 1] = #_G.hits - before
    click(i + 1)
  end, 50)
end
vim.defer_fn(function()
  vim.cmd("redraw!")
  click(1)
end, 100)
]])
  eq(" T CLICKME  other |", got.line)
  eq({ 1, 1, 1, 1, 0, 0 }, got.hits, "calls per click at columns 0, 1, 3, 10, 11, 12")
  ok(type(got.args) == "table", "not called: " .. vim.inspect(got))
  eq({ 1, "l" }, { got.args[1], got.args[2] })
  eq("string", type(got.args[3]))
end)

-- Built-ins ----------------------------------------------------------------------------------------------------------

test("diagnostics: the current buffer's counts by severity, in order, each with its symbol, none when zero", function()
  start({ left = { { "diagnostics", symbols = { error = "E", warn = "W", info = "I", hint = "H" } } } })
  local ns = vim.api.nvim_create_namespace("test")
  local d = function(severity) return { lnum = 0, col = 0, message = "m", severity = severity } end
  local other = vim.api.nvim_create_buf(true, false)
  vim.diagnostic.set(ns, 0, { d(4), d(2), d(3), d(1), d(2) })
  vim.diagnostic.set(ns, other, { d(1), d(1), d(1) })
  flush()
  eq(" E1 W2 I1 H1 |", (render()), "another buffer's diagnostics changed last")
  vim.diagnostic.reset(ns, 0)
  flush()
  eq("|", (render()))
end)

test("diagnostics: each count in its severity's colour; symbols and colours not given are lualine's", function()
  vim.api.nvim_set_hl(0, "DiagnosticHint", { fg = "#00ff00" })
  start({
    left = {
      {
        "diagnostics",
        symbols = { error = "E", info = "I" },
        diagnostics_color = { error = { fg = "#ff0000" }, info = { fg = "#00ffff" } },
      },
    },
  })
  local ns = vim.api.nvim_create_namespace("test")
  vim.diagnostic.set(ns, 0, {
    { lnum = 0, col = 0, message = "m", severity = 1 },
    { lnum = 0, col = 0, message = "m", severity = 3 },
    { lnum = 0, col = 0, message = "m", severity = 4 },
  })
  flush()
  -- lualine's default hint symbol, with icons on (lualine components/diagnostics/config.lua:6-12)
  eq(" E1 I1 󰌶 1 |", (render()))
  eq(0xff0000, hl_of("E1").fg)
  eq(0x00ffff, hl_of("I1").fg)
  eq(0x00ff00, hl_of("󰌶 1").fg)
end)

test("diagnostics: counts stay as they were while in Insert mode, and catch up after it", function()
  local got = child([[
require("neoblocks").setup({ statusline = { left = { { "diagnostics", symbols = { error = "E" } } }, right = {} } })
local ns = vim.api.nvim_create_namespace("test")
local function set(n)
  local list = {}
  for i = 1, n do list[i] = { lnum = 0, col = 0, message = "m" .. i, severity = 1 } end
  vim.diagnostic.set(ns, vim.api.nvim_get_current_buf(), list)
end
set(1)
vim.defer_fn(function()
  vim.api.nvim_input("i")
  vim.defer_fn(function()
    set(2)
    vim.defer_fn(function()
      local inside = render()
      vim.api.nvim_input("<Esc>")
      vim.defer_fn(function() done({ inside = inside, after = render() }) end, 100)
    end, 100)
  end, 100)
end, 100)
]])
  eq(" E1 |", got.inside, "Insert mode")
  eq(" E2 |", got.after, "after Insert mode")
end)

test("branch: the name after refs/heads/ of the repo above the buffer's file, % escaped", function()
  local dir = repo("ref: refs/heads/feat/100%")
  start({ left = { { "branch", icon = "B" } } })
  vim.cmd.edit(dir .. "/sub/file.txt")
  flush()
  eq(" B feat/100% |", (render()))
end)

test("branch: a .git file is followed, relative or absolute; a detached HEAD shows the hash's first 6", function()
  for _, gitdir in ipairs({ "gd", vim.fn.tempname() .. "/main/.git/worktrees/wt" }) do
    local dir = repo("0123456789abcdef0123456789abcdef01234567", { gitdir = gitdir })
    start({ left = { { "branch", icon = "B" } } })
    vim.cmd.edit(dir .. "/sub/file.txt")
    flush()
    eq(" B 012345 |", (render()), gitdir)
  end
end)

test("branch: a new HEAD shows without an event, also when git replaces the file", function()
  local dir, gitdir = repo("ref: refs/heads/one")
  start({ left = { { "branch", icon = "B" } } })
  vim.cmd.edit(dir .. "/sub/file.txt")
  flush()
  eq(" B one |", (render()))
  for _, name in ipairs({ "two", "three" }) do
    vim.fn.writefile({ "ref: refs/heads/" .. name }, gitdir .. "/HEAD.lock")
    assert(vim.uv.fs_rename(gitdir .. "/HEAD.lock", gitdir .. "/HEAD"))
    local want = (" B %s |"):format(name)
    vim.wait(3000, function() return render() == want end, 20)
    eq(want, (render()))
  end
end)

test("branch: a buffer with no name shows the branch of the repo at the cwd", function()
  local dir = repo("ref: refs/heads/main")
  -- started before the cd: the runner puts neoblocks on 'runtimepath' by a path relative to the cwd
  local sl = start({ left = { { "branch", icon = "B" } } })
  vim.cmd.cd(dir .. "/sub")
  local ok_, err = pcall(function()
    sl.refresh()
    eq("", vim.api.nvim_buf_get_name(0))
    eq(" B main |", (render()))
  end)
  vim.cmd.cd(root)
  assert(ok_, err)
end)

test("branch: a :cd shows the new cwd's branch in a buffer with no name, with no event of the config's", function()
  -- the config's events have no DirChanged (nvim-config plugins/lualine.lua:298-308)
  local a, b = repo("ref: refs/heads/xa"), repo("ref: refs/heads/yb")
  start({ events = { "BufWritePost" }, left = { { "branch", icon = "B" } } })
  local ok_, err = pcall(function()
    eq("", vim.api.nvim_buf_get_name(0))
    for _, case in ipairs({ { a .. "/sub", " B xa |" }, { b, " B yb |" } }) do
      vim.cmd.cd(case[1])
      flush()
      eq(case[2], (render()), case[1])
    end
  end)
  vim.cmd.cd(root)
  assert(ok_, err)
end)

test(
  "branch: a terminal shows its own folder's branch, a buffer named by a URI the cwd's, whatever ran before",
  function()
    -- lualine reads a terminal's folder from its name, term://<dir>//<pid>:<cmd> (git_branch.lua:91-94)
    local a, b = repo("ref: refs/heads/xa"), repo("ref: refs/heads/yb")
    local sl = start({ left = { { "branch", icon = "B" } } })
    local jobs = {}
    local ok_, err = pcall(function()
      vim.cmd.cd(a)
      vim.cmd.enew()
      local term = vim.api.nvim_get_current_buf()
      jobs[#jobs + 1] = vim.fn.jobstart({ "sleep", "30" }, { term = true })
      sl.refresh()
      eq(" B xa |", (render()), "a terminal started in a")
      vim.cmd.cd(b)
      vim.cmd.edit(b .. "/sub/file.txt")
      sl.refresh()
      eq(" B yb |", (render()), "a file in b")
      vim.api.nvim_set_current_buf(term)
      sl.refresh()
      eq(" B xa |", (render()), "back in the terminal, the cwd in b")
      vim.cmd.enew()
      jobs[#jobs + 1] = vim.fn.jobstart({ "sleep", "30" }, { term = true, cwd = a .. "/sub" })
      sl.refresh()
      eq(" B xa |", (render()), "a terminal started in a's subfolder, first drawn with the cwd in b")
      -- a name that isn't a path: the cwd's repo, looked up from the cwd's folder upward, as a buffer with no name
      vim.cmd.enew()
      vim.api.nvim_buf_set_name(0, "nofile://x")
      vim.cmd.cd(a .. "/sub")
      sl.refresh()
      eq(" B xa |", (render()), "a URI buffer, the cwd in a's subfolder")
      vim.cmd.cd(b)
      sl.refresh()
      eq(" B yb |", (render()), "a URI buffer, the cwd in b")
    end)
    for _, job in ipairs(jobs) do
      vim.fn.jobstop(job)
    end
    vim.cmd.cd(root)
    assert(ok_, err)
  end
)

test("branch: nothing, not even the icon, outside a git repo", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "x" }, dir .. "/file.txt")
  start({ left = { { "branch", icon = "B" }, fn("x") } })
  vim.cmd.edit(dir .. "/file.txt")
  flush()
  eq(" x |", (render()))
end)

test(
  "branch: a folder that becomes a repo, or whose parent does, shows the branch after refresh() or a buffer switch",
  function()
    -- outside a repo the lookup walks every folder up to /; lualine walks again only on BufEnter
    -- (git_branch.lua:137-143), not on each rebuild
    local ways = {
      refresh = function(sl) sl.refresh() end,
      ["a buffer switch"] = function()
        vim.cmd.enew()
        flush()
        vim.cmd.buffer("#")
        flush()
      end,
    }
    for way, again in pairs(ways) do
      for _, at in ipairs({ "", "/.." }) do
        local name = way .. ", git init" .. at
        local dir = vim.fn.tempname() .. "/a"
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "x" }, dir .. "/file.txt")
        local sl = start({ left = { { "branch", icon = "B" }, fn("x") } })
        vim.cmd.edit(dir .. "/file.txt")
        flush()
        eq(" x |", (render()), name .. ": before")
        -- what `git init -b new` writes, in the file's folder or its parent
        local gitdir = vim.fs.normalize(dir .. at) .. "/.git"
        vim.fn.mkdir(gitdir, "p")
        vim.fn.writefile({ "ref: refs/heads/new" }, gitdir .. "/HEAD")
        vim.api.nvim_exec_autocmds("BufWritePost", {})
        flush()
        eq(" x |", (render()), name .. ": an event's rebuild")
        again(sl)
        eq(" B new  x |", (render()), name)
      end
    end
  end
)

test(
  "diff: the current buffer's gitsigns counts, symbols and colours, zero counts left out, on GitSignsUpdate",
  function()
    start({
      left = {
        {
          "diff",
          symbols = { added = "A", modified = "M", removed = "R" },
          diff_color = { added = { fg = "#00aa00" }, modified = { fg = "#aaaa00" }, removed = { fg = "#aa0000" } },
        },
        fn("x"),
      },
    })
    local function update(status, buf)
      buf = buf or vim.api.nvim_get_current_buf()
      vim.b[buf].gitsigns_status_dict = status
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
      flush()
    end
    update({ added = 3, changed = 0, removed = 1, head = "main" })
    eq(" A3 R1  x |", (render()))
    eq(0x00aa00, hl_of("A3").fg)
    eq(0xaa0000, hl_of("R1").fg)
    update({ added = 0, changed = 2, removed = 0, head = "main" })
    eq(" M2  x |", (render()))
    eq(0xaaaa00, hl_of("M2").fg)
    update({ added = 9, changed = 9, removed = 9, head = "main" }, vim.api.nvim_create_buf(true, false))
    eq(" M2  x |", (render()), "another buffer updated last")
    update(nil)
    eq(" x |", (render()))
  end
)

-- Switching branches and worktrees -----------------------------------------------------------------------------------
-- Real repos made by git, under ~/.cache/neoblocks/statusline/switch/. The diff cases run the real gitsigns.nvim from
-- lazy.nvim's folder; CI installs only mise's tools (.github/workflows/ci.yml), so there they're skipped.

local scratch = vim.env.HOME .. "/.cache/neoblocks/statusline/switch"
local gitsigns_dir = vim.fn.stdpath("data") .. "/lazy/gitsigns.nvim"
local has_gitsigns = vim.uv.fs_stat(gitsigns_dir .. "/lua/gitsigns.lua") ~= nil

--- test(), or one that's skipped, saying so in its name, when gitsigns.nvim isn't installed.
local function gitsigns_test(name, body)
  if has_gitsigns then
    return test(name, body)
  end
  test(("%s [SKIPPED: no gitsigns.nvim at %s]"):format(name, gitsigns_dir), function() end)
end

--- Runs git in `dir`, without the user's or the system's config; errors when git does.
local function git(dir, ...)
  local out = vim
    .system(
      { "git", "-c", "user.name=t", "-c", "user.email=t@t", ... },
      { cwd = dir, env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" } }
    )
    :wait()
  assert(out.code == 0, ("git %s: %s"):format(table.concat({ ... }, " "), out.stderr))
end

local on_main = { "a", "b", "c", "d", "e", "f", "g", "h" }
local on_other = { "a", "B", "c", "d", "e", "f", "g", "H", "i", "j" }
local made = 0

--- A repo at <top>/main whose file.txt is `on_main` on branch main and `on_other` on branch other, with main checked
--- out there; with `worktree`, other is checked out in a worktree at <top>/wt. Returns top, main, wt.
local function two_branches(worktree)
  made = made + 1
  local top = ("%s/%d-%d"):format(scratch, vim.fn.getpid(), made)
  local main, wt = top .. "/main", top .. "/wt"
  vim.fn.delete(top, "rf")
  vim.fn.mkdir(main, "p")
  git(main, "init", "-q", "-b", "main")
  vim.fn.writefile(on_main, main .. "/file.txt")
  git(main, "add", "file.txt")
  git(main, "commit", "-q", "-m", "main")
  git(main, "switch", "-q", "-c", "other")
  vim.fn.writefile(on_other, main .. "/file.txt")
  git(main, "commit", "-q", "-am", "other")
  git(main, "switch", "-q", "main")
  if worktree then
    git(main, "worktree", "add", "-q", wt, "other")
  end
  return top, main, wt
end

--- Runs `body`, with gitsigns.nvim set up when `gitsigns`; then wipes the buffers, gitsigns and `top` and goes back to
--- the first cwd, so the tests after it see none of them.
local function in_repos(top, gitsigns, body)
  if gitsigns then
    vim.opt.rtp:append(gitsigns_dir)
    require("gitsigns").setup({})
  end
  local ok_, err = pcall(body)
  if gitsigns then
    require("gitsigns").detach_all()
    -- gitsigns' groups are "gitsigns" and "gitsigns.<part>" (its attach.lua:23); one left behind runs a later test's
    -- BufFilePre with gitsigns unloaded
    for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
      local name = au.group_name
      if type(name) == "string" and (name == "gitsigns" or vim.startswith(name, "gitsigns.")) then
        pcall(vim.api.nvim_del_augroup_by_id, au.group)
      end
    end
    vim.opt.rtp:remove(gitsigns_dir)
    for name in pairs(package.loaded) do
      if name == "gitsigns" or name:match("^gitsigns%.") then
        package.loaded[name] = nil
      end
    end
  end
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(root)
  vim.fn.delete(top, "rf")
  assert(ok_, err)
end

--- The line once it's `want`, or as it is after 5 s: git and gitsigns work in the background.
local function line_becomes(want)
  vim.wait(5000, function() return render() == want end, 20)
  return (render())
end

local diff_symbols = { "diff", symbols = { added = "A", modified = "M", removed = "R" } }

gitsigns_test(
  "branch and diff: a git switch outside Neovim shows the new branch and the counts against it, with no event",
  function()
    local top, main = two_branches(false)
    in_repos(top, true, function()
      start({ left = { { "branch", icon = "B" }, diff_symbols } })
      vim.cmd.edit(main .. "/file.txt")
      -- unsaved, so git switch leaves the buffer's text as it is: against main's, b changed and i added
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "B", "c", "d", "e", "f", "g", "h", "i" })
      eq(" B main  A1 M1 |", line_becomes(" B main  A1 M1 |"), "on main")
      git(main, "switch", "-q", "other")
      -- against other's: H changed, j removed
      eq(" B other  M1 R1 |", line_becomes(" B other  M1 R1 |"), "after git switch other")
      git(main, "switch", "-q", "main")
      eq(" B main  A1 M1 |", line_becomes(" B main  A1 M1 |"), "after git switch main")
    end)
  end
)

test("branch: buffers from two worktrees of one repo each show their worktree's branch, by window or buffer", function()
  local top, main, wt = two_branches(true)
  in_repos(top, false, function()
    start({ left = { { "branch", icon = "B" } } })
    vim.cmd.edit(main .. "/file.txt")
    local in_main = vim.api.nvim_get_current_buf()
    flush()
    eq(" B main |", (render()), "main's file")
    vim.cmd.vsplit(wt .. "/file.txt")
    flush()
    eq(" B other |", (render()), "the worktree's file, in a new window")
    for _, want in ipairs({ " B main |", " B other |" }) do
      vim.cmd.wincmd("p")
      flush()
      eq(want, (render()), "after a window switch")
    end
    vim.api.nvim_set_current_buf(in_main)
    flush()
    eq(" B main |", (render()), "main's file in the worktree's window")
  end)
end)

gitsigns_test("diff: buffers from two worktrees of one repo each show their own counts, by window or buffer", function()
  local top, main, wt = two_branches(true)
  in_repos(top, true, function()
    start({ left = { { "branch", icon = "B" }, diff_symbols } })
    vim.cmd.edit(main .. "/file.txt")
    local in_main = vim.api.nvim_get_current_buf()
    -- against main's: z added
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "z" })
    eq(" B main  A1 |", line_becomes(" B main  A1 |"), "main's file")
    vim.cmd.vsplit(wt .. "/file.txt")
    -- against other's: a changed
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A" })
    eq(" B other  M1 |", line_becomes(" B other  M1 |"), "the worktree's file, in a new window")
    for _, want in ipairs({ " B main  A1 |", " B other  M1 |" }) do
      vim.cmd.wincmd("p")
      flush()
      eq(want, (render()), "after a window switch")
    end
    vim.api.nvim_set_current_buf(in_main)
    flush()
    eq(" B main  A1 |", (render()), "main's file in the worktree's window")
  end)
end)

test("branch: a :cd into another worktree of the repo shows that worktree's branch in a buffer with no name", function()
  local top, main, wt = two_branches(true)
  in_repos(top, false, function()
    start({ left = { { "branch", icon = "B" } } })
    eq("", vim.api.nvim_buf_get_name(0))
    for _, case in ipairs({ { main, " B main |" }, { wt, " B other |" }, { main, " B main |" } }) do
      vim.cmd.cd(case[1])
      flush()
      eq(case[2], (render()), "cd " .. case[1])
    end
  end)
end)

test("searchcount: [current/total] after a move while a search is highlighted; :nohlsearch hides it", function()
  start({ left = { fn("x") }, right = { "searchcount" } })
  local lines = {}
  for i = 1, 30 do
    lines[i] = (i == 5 or i == 10 or i == 20) and "a needle" or "hay"
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.fn.setreg("/", "needle")
  vim.o.hlsearch = true
  vim.v.hlsearch = 1
  vim.api.nvim_win_set_cursor(0, { 10, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  flush()
  eq(" x | [2/3] ", (render()))
  vim.api.nvim_win_set_cursor(0, { 20, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  flush()
  eq(" x | [3/3] ", (render()))
  vim.cmd.nohlsearch()
  eq(" x |", (render()))
end)

test("searchcount: a move while a search is highlighted redoes only the count", function()
  start({ left = { counted("x") }, right = { "searchcount" } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "needle", "hay", "needle" })
  vim.fn.setreg("/", "needle")
  vim.o.hlsearch = true
  vim.v.hlsearch = 1
  local before = calls.x
  ok(before > 0, "never built")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  flush()
  eq(" x | [2/2] ", (render()))
  eq(before, calls.x, "the other components were rebuilt")
end)

test("searchcount: the count follows the search, its highlight and the text with no cursor move", function()
  -- lualine's 1 s timer caught these for the config (lualine.lua:541-548); typed keys need a child's main loop
  local got = child([[
vim.o.hlsearch = true
require("neoblocks").setup({ statusline = { left = { function() return "x" end }, right = { "searchcount" } } })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "other", "needle", "other", "other" })
vim.fn.setreg("/", "other")
vim.v.hlsearch = 1
-- steps 2, 6 and 7 change the search state and leave the cursor where it is
local steps = {
  function() vim.api.nvim_win_set_cursor(0, { 2, 0 }) end,
  -- a new pattern: * on the start of the only 'needle' stays put
  function() vim.api.nvim_input("*") end,
  function() vim.api.nvim_input(":nohlsearch<CR>") end,
  function() vim.api.nvim_win_set_cursor(0, { 1, 0 }) end,
  function() vim.api.nvim_win_set_cursor(0, { 2, 0 }) end,
  -- the search highlighted again: n on the only match stays put
  function() vim.api.nvim_input("n") end,
  -- the text: a match added below the cursor
  function() vim.api.nvim_buf_set_lines(0, -1, -1, false, { "needle" }) end,
}
local out = {}
local function step(i)
  if i > #steps then return done(out) end
  steps[i]()
  vim.defer_fn(function()
    out[i] = render()
    step(i + 1)
  end, 100)
end
vim.defer_fn(function() step(1) end, 100)
]])
  eq(" x | [1/1] ", got[2], "* on 'needle' after 'other'")
  eq(" x |", got[3], ":nohlsearch")
  eq(" x | [1/1] ", got[6], "n after :nohlsearch")
  eq(" x | [1/2] ", got[7], "a match added")
end)

test("searchcount: a burst of moves with a search highlighted counts at most once per 16 ms, ending current", function()
  -- the config's refresh on a move waits for lualine's 16 ms timer (lualine.lua:370-376,514-528)
  local searchcount, counts = vim.fn.searchcount, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.searchcount = function(...)
    counts = counts + 1
    return searchcount(...)
  end
  local ok_, err = pcall(function()
    start({ left = { fn("x") }, right = { "searchcount" } })
    local lines = {}
    for i = 1, 200 do
      lines[i] = "needle"
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.fn.setreg("/", "needle")
    vim.o.hlsearch = true
    vim.v.hlsearch = 1
    counts = 0
    local t0 = vim.uv.hrtime()
    -- one move per loop tick, as a scroll animation's timer moves the cursor
    for i = 1, 100 do
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      vim.wait(1)
    end
    flush()
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(counts <= ms / 16 + 2, ("%d counts in %d ms"):format(counts, ms))
    eq(" x | [100/200] ", (render()))
  end)
  vim.fn.searchcount = searchcount
  assert(ok_, err)
end)

test("searchcount: the total shown stops at 999, as lualine's", function()
  -- lualine shows [current/min(total, 999)] (components/searchcount.lua:27-28)
  start({ left = { fn("x") }, right = { "searchcount" } })
  local lines = {}
  for i = 1, 1500 do
    lines[i] = "needle"
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.fn.setreg("/", "needle")
  vim.o.hlsearch = true
  vim.v.hlsearch = 1
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  flush()
  eq(" x | [2/999] ", (render()))
end)

test("searchcount: a count runs only when the cursor, the search or the text changed since the last one", function()
  -- searchcount() scans the buffer (decision 6): a rebuild and a move in the same tick, as `A` gives (ModeChanged and
  -- CursorMovedI), count once; a rebuild or a SafeState that changes none of them counts nothing
  local searchcount, counts = vim.fn.searchcount, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.searchcount = function(...)
    counts = counts + 1
    return searchcount(...)
  end
  local ok_, err = pcall(function()
    local sl = start({ events = { "BufWritePost" }, left = { fn("x") }, right = { "searchcount" } })
    local lines = {}
    for i = 1, 200 do
      lines[i] = "needle"
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.fn.setreg("/", "needle")
    vim.o.hlsearch = true
    vim.v.hlsearch = 1
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    flush()
    eq(" x | [1/200] ", (render()), "first count")
    local orders = {
      { "BufWritePost", "CursorMoved", "SafeState" },
      { "CursorMoved", "BufWritePost", "SafeState" },
    }
    for i, order in ipairs(orders) do
      counts = 0
      vim.api.nvim_win_set_cursor(0, { 10 * i, 0 })
      for _, event in ipairs(order) do
        vim.api.nvim_exec_autocmds(event, {})
      end
      flush()
      eq(1, counts, table.concat(order, ", "))
      eq((" x | [%d/200] "):format(10 * i), (render()), table.concat(order, ", "))
    end
    counts = 0
    vim.api.nvim_exec_autocmds("BufWritePost", {})
    flush()
    sl.refresh()
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("SafeState", {})
      flush()
    end
    eq(0, counts, "a rebuild, refresh() and SafeState with nothing changed")
  end)
  vim.fn.searchcount = searchcount
  assert(ok_, err)
end)

test("searchcount: a rebuild that changes only the count draws it on the screen", function()
  -- on a real screen: a child Neovim in a terminal, its statusline read from the terminal's lines. Switching windows
  -- (WinEnter rebuilds) shows the other window's cursor, so its count, with the rest of the line the same.
  local init = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    ("vim.opt.rtp:prepend(%q)"):format(root),
    'vim.cmd.runtime("plugin/neoblocks.lua")',
    "vim.o.hlsearch = true",
    "local lines = {}",
    "for i = 1, 30 do lines[i] = (i == 5 or i == 10 or i == 20) and 'needle' or 'hay' end",
    "vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)",
    "require('neoblocks').setup({ statusline = { left = { function() return 'SL' end }, right = { 'searchcount' } } })",
  }, init)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 12 })
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "-u", init }, { term = true })
  local function status()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("SL", 1, true) then
        return line
      end
    end
  end
  local function count() return (status() or ""):match("%[%d+/%d+%]") or "" end
  local function after(keys, want)
    vim.api.nvim_chan_send(job, vim.keycode(keys))
    vim.wait(1000, function() return count() == want end, 10)
    eq(want, count(), keys)
  end
  local ok_, err = pcall(function()
    vim.wait(3000, function() return status() ~= nil end, 10)
    ok(status(), "no statusline drawn")
    after("/needle<CR>", "[1/3]")
    after(":split<CR>20G", "[3/3]")
    after("<C-w>w", "[1/3]")
    after("<C-w>w", "[3/3]")
  end)
  vim.fn.jobstop(job)
  vim.api.nvim_win_close(win, true)
  assert(ok_, err)
end)

test("searchcount: the line holds the count's expression only while a search is highlighted", function()
  -- Neovim evaluates an expression in 'statusline' on every draw (decision 6)
  start({ left = { fn("x") }, right = { "searchcount" } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "needle", "hay", "needle" })
  vim.fn.setreg("/", "needle")
  vim.o.hlsearch = true
  local function moved(hl)
    vim.v.hlsearch = hl
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    flush()
    return vim.o.statusline:find("hlsearch", 1, true) ~= nil
  end
  eq(false, moved(0), "no search highlighted")
  eq(true, moved(1), "a search highlighted")
  eq(false, moved(0), "after :nohlsearch")
end)

test("progress_status: running progress shows as Neovim sums it, % once, from the first message", function()
  start({ left = { "progress_status", fn("x") } })
  -- silent: the progress message would print to the test's output
  local progress = "{ kind = 'progress', source = 'test', title = 'T', status = %q, percent = %d, id = _G.id }"
  vim.cmd("silent lua _G.id = vim.api.nvim_echo({ { 'a' } }, false, " .. progress:format("running", 40) .. ")")
  flush()
  eq(" 40%(1)  x |", (render()))
  vim.cmd("silent lua vim.api.nvim_echo({ { 'b' } }, false, " .. progress:format("success", 100) .. ")")
  flush()
  eq(" x |", (render()))
end)

test("progress_status: a message sent while the statusline is off shows once it's switched on", function()
  -- in a child: Neovim tracks progress from the first progress_status() call in the process, which an earlier test made
  local got = child([[
vim.g.neoblocks_statusline = false
require("neoblocks").setup({ statusline = { left = { "progress_status" }, right = {} } })
vim.cmd("silent lua vim.api.nvim_echo({ { 'a' } }, false, "
  .. "{ kind = 'progress', source = 'test', title = 'T', status = 'running', percent = 40 })")
vim.defer_fn(function()
  require("neoblocks").toggle("statusline", true)
  done({ line = render() })
end, 100)
]])
  eq(" 40%(1) |", got.line)
end)

test("recording: @ and the register while a macro records, nothing once it stops", function()
  start({ left = { "recording", fn("x") } })
  vim.api.nvim_feedkeys("qa", "x", false)
  flush()
  eq(" @a  x |", (render()))
  vim.api.nvim_feedkeys("q", "x", false)
  flush()
  eq(" x |", (render()))
end)

-- On and off ---------------------------------------------------------------------------------------------------------

test("off puts back the 'statusline' and 'laststatus' it replaced; on draws again", function()
  clean()
  local nb = fresh()
  vim.go.statusline = "PREV"
  nb.setup({ statusline = { left = { fn("L") }, right = {} } })
  flush()
  eq(" L |", (render()))
  nb.toggle("statusline", false)
  eq("PREV", vim.o.statusline)
  eq(2, vim.o.laststatus)
  nb.toggle("statusline", true)
  eq(" L |", (render()))
  eq(3, vim.o.laststatus)
end)

test("off puts back what was there when it was last switched on, not before setup()", function()
  clean()
  local nb = fresh()
  vim.go.statusline = "PREV"
  nb.setup({ statusline = { left = { fn("L") }, right = {} } })
  flush()
  nb.toggle("statusline", false)
  -- set while the module is off
  vim.go.statusline = "MINE"
  vim.o.laststatus = 0
  nb.toggle("statusline", true)
  eq(" L |", (render()))
  nb.toggle("statusline", false)
  eq({ "MINE", 0 }, { vim.go.statusline, vim.o.laststatus })
end)

test("off in one buffer shows the replaced statusline while that buffer is current", function()
  clean()
  local nb = fresh()
  vim.go.statusline = "PREV"
  nb.setup({ statusline = { left = { fn("L") }, right = {} } })
  flush()
  local off, other = vim.api.nvim_create_buf(true, false), vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(off)
  flush()
  nb.toggle("statusline", false, off)
  eq("PREV", vim.o.statusline, "the switched-off buffer")
  vim.api.nvim_set_current_buf(other)
  flush()
  eq(" L |", (render()), "another buffer")
  vim.api.nvim_set_current_buf(off)
  flush()
  eq("PREV", vim.o.statusline, "back in the switched-off buffer")
end)

test("a window's own statusline (quickfix's) is replaced while it's current, and back when off", function()
  clean()
  local nb = fresh()
  nb.setup({ statusline = { left = { fn("L") }, right = {} } })
  flush()
  vim.cmd.copen()
  flush()
  eq(" L |", (render()), "in the quickfix window")
  nb.toggle("statusline", false)
  ok(vim.wo.statusline:find("quickfix_title", 1, true), "quickfix's own: " .. vim.wo.statusline)
  vim.cmd.cclose()
end)

test(":checkhealth warns about gitsigns only when diff is used and gitsigns isn't there", function()
  -- a gitsigns on 'runtimepath' but not loaded yet (lazy-loaded), laid out as it ships: lua/gitsigns.lua
  local fake = vim.fn.tempname()
  vim.fn.mkdir(fake .. "/lua/gitsigns", "p")
  vim.fn.writefile({ "return {}" }, fake .. "/lua/gitsigns.lua")
  local cases = {
    { left = { "diff" }, gitsigns = false, warns = true },
    { left = { "diagnostics" }, gitsigns = false, warns = false },
    { left = { "diff" }, gitsigns = true, warns = false },
  }
  for _, case in ipairs(cases) do
    package.loaded.gitsigns = nil
    if case.gitsigns then
      vim.opt.rtp:prepend(fake)
    end
    start({ left = case.left })
    vim.cmd("checkhealth neoblocks")
    local text = ""
    vim.wait(2000, function()
      text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      return text:find("neoblocks.statusline", 1, true) ~= nil
    end)
    vim.opt.rtp:remove(fake)
    local section = text:match("neoblocks%.statusline.*") or ""
    ok(section ~= "", text)
    eq(case.warns, section:find("WARNING.-gitsigns") ~= nil, vim.inspect(case) .. "\n" .. section)
  end
end)
