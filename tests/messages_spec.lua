-- The messages module: the cmdline popup, toasts and the split, the history, and pending keys, each in a child
-- Neovim with a real UI. ui2 exists only with a UI attached (vim/_core/ui2.lua: enable() returns without one), so each
-- test runs a child `nvim --clean` in a terminal, 120x36, types into the terminal and asks the child over RPC.
-- snacks.nvim isn't installed here (the runner is offline): tests that need it give the child a fake `Snacks` that
-- records each toast and picker call; the expected titles, levels and timeouts come from noice's behaviour as
-- docs/decisions/messages.md lists it.
local root = vim.fn.getcwd()
vim.o.columns, vim.o.lines = 120, 40

-- the parts of snacks the module calls: the notifier (toasts recorded in _G.toasts, history from _G.notify_history,
-- notify raising when _G.notify_fails) and the picker (its options in _G.picked)
local FAKE_SNACKS = [[
_G.toasts, _G.notify_history = {}, {}
_G.Snacks = {
  did_setup = true,
  config = { notifier = { enabled = true } },
  notifier = {
    notify = function(msg, level, opts)
      if _G.notify_fails then
        error("notify failed")
      end
      table.insert(_G.toasts, { msg = msg, level = level, title = opts.title, timeout = opts.timeout, routine = opts.routine })
    end,
    get_history = function() return _G.notify_history end,
  },
  picker = { pick = function(opts) _G.picked = opts end },
}
]]

---@class Child
---@field lua fun(code: string, ...): any runs `code` in the child, its `...` the arguments
---@field send fun(keys: string) types `keys` (with <> notation) into the terminal
---@field screen fun(): string[] the terminal's lines
---@field stop fun() ends the child and closes its terminal

--- A child Neovim with a UI: `before` runs before setup(), `opts` is the messages options (Lua), `setup` the whole
--- setup() table instead (Lua), `after` runs after.
---@param o { snacks?: boolean, opts?: string, setup?: string, before?: string, after?: string }
---@return Child
local function start(o)
  local init = vim.fn.tempname() .. ".lua"
  local sock = vim.fn.tempname() .. ".sock"
  vim.fn.writefile(
    vim.split(
      table.concat({
        ("vim.opt.rtp:prepend(%q)"):format(root),
        'vim.cmd.runtime("plugin/neoblocks.lua")',
        "vim.o.cmdheight = 0",
        -- no hit-enter or more prompt, which would block RPC, when ui2 isn't on (ui2 ignores both: ui2/messages.lua)
        "vim.o.messagesopt = 'wait:0,history:500,progress:c'",
        "vim.o.more = false",
        o.snacks and FAKE_SNACKS or "",
        o.before or "",
        ("require('neoblocks').setup(%s)"):format(o.setup or ("{ messages = %s }"):format(o.opts or "{}")),
        o.after or "",
      }, "\n"),
      "\n"
    ),
    init
  )
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 120, height = 36 })
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "-u", init, "--listen", sock }, { term = true })
  local ch ---@type integer?
  vim.wait(5000, function()
    if vim.uv.fs_stat(sock) then
      ch = vim.fn.sockconnect("pipe", sock, { rpc = true })
    end
    return ch ~= nil and ch > 0
  end, 20)
  assert(ch and ch > 0, "the child didn't listen on " .. sock)
  ---@type Child
  local c = {
    lua = function(code, ...) return vim.rpcrequest(ch, "nvim_exec_lua", code, { ... }) end,
    send = function(keys) vim.api.nvim_chan_send(job, vim.keycode(keys)) end,
    screen = function() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end,
    stop = function()
      vim.fn.jobstop(job)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end,
  }
  -- UIEnter has run, and the tick after it, where startup messages are replayed
  vim.wait(5000, function() return c.lua("return vim.v.vim_did_enter") == 1 end, 20)
  c.lua("vim.schedule(function() _G.ready = true end)")
  vim.wait(2000, function() return c.lua("return _G.ready") == true end, 20)
  return c
end

--- Runs `fn` with a child, and stops the child whatever happens.
---@param o { snacks?: boolean, opts?: string, setup?: string, before?: string, after?: string }
---@param fn fun(c: Child)
local function with(o, fn)
  local c = start(o)
  local ok_, err = xpcall(fn, debug.traceback, c)
  c.stop()
  assert(ok_, err)
end

--- Waits until `cond()` is true, up to `ms` (5 s: check:all runs the checks in parallel); returns its last value.
local function wait(cond, ms)
  vim.wait(ms or 5000, cond, 20)
  return cond()
end

--- Waits until the child is in `mode` (its first letter: "n", "c"), and says whether it got there.
local function in_mode(c, mode)
  return wait(function() return c.lua("return vim.api.nvim_get_mode().mode"):sub(1, 1) == mode end)
end

--- In normal mode with no popup and no split left, and no toasts recorded.
local function reset(c)
  c.send("<Esc><Esc>")
  wait(function() return c.lua("return vim.api.nvim_get_mode().mode") == "n" end)
  -- not :only, which closes ui2's floats too
  c.lua([[
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_get_config(w).relative == "" then
        vim.api.nvim_win_close(w, true)
      end
    end
    _G.toasts = _G.toasts and {}
  ]])
end

--- Echoes `text` from a typed :echo whose command line doesn't hold it (ui2 leaves a run command in its cmd buffer).
local function echo(c, text)
  local h = math.floor(#text / 2)
  c.send((':echo "%s" .. "%s"<CR>'):format(text:sub(1, h), text:sub(h + 1)))
end

-- ui2's cmd window: where it is, its title and 'cmdheight'
local CMD = [[
local ui = require("vim._core.ui2")
local c = vim.api.nvim_win_get_config(ui.wins.cmd)
local title = type(c.title) == "table" and vim.trim(c.title[1][1]) or ""
return { relative = c.relative, title = title, row = c.row, cmdheight = vim.o.cmdheight }
]]

-- whether one of ui2's own buffers shows `text` (messages after an expanded cmdline go to the pager, ui2/messages.lua)
local IN_UI2 = [[
local ui = require("vim._core.ui2")
for _, b in ipairs({ ui.bufs.cmd, ui.bufs.msg, ui.bufs.pager, ui.bufs.dialog }) do
  if table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find(..., 1, true) then
    return true
  end
end
return false
]]

-- the normal windows of the tab and which is current: { { text, current }, ... }
local SPLITS = [[
local ret = {}
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_config(w).relative == "" then
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
    ret[#ret + 1] = { text = text, current = w == vim.api.nvim_get_current_win() }
  end
end
return ret
]]

--- The split that shows `text`, if any.
local function split_with(c, text)
  for _, s in ipairs(c.lua(SPLITS)) do
    if s.text:find(text, 1, true) then
      return s
    end
  end
end

--- What a statusline "SL[...]" shows between the brackets, if it's on screen.
local function sl(c)
  for _, l in ipairs(c.screen()) do
    local s = l:match("SL%[(.-)%]")
    if s then
      return s
    end
  end
end

--- Types `keys` and waits for the statusline to show `want`; returns what it shows.
local function sl_after(c, keys, want)
  c.send(keys)
  return wait(function() return sl(c) == want and want end) or sl(c)
end

--- The warnings the module gave, from :messages.
local function warnings(c) return c.lua("return vim.fn.execute('messages')") end

--- The toasts the fake notifier got, once at least `n` arrived and a marker message sent after them came through as
--- well, so a later toast of the same command would be in too. The marker's own toast is left out.
local function toasts(c, n)
  wait(function() return #c.lua("return _G.toasts") >= (n or 1) end)
  c.lua("_G.marker_seen = false vim.api.nvim_echo({ { 'toasts-marker' } }, false, {})")
  -- takes the marker out once it's there; wait() asks once more after it's true
  local seen = [[
    for i, t in ipairs(_G.toasts) do
      if t.msg == "toasts-marker" then
        table.remove(_G.toasts, i)
        _G.marker_seen = true
      end
    end
    return _G.marker_seen
  ]]
  ok(wait(function() return c.lua(seen) end), "the marker message never became a toast")
  return c.lua("return _G.toasts")
end

-- Without a UI -------------------------------------------------------------------------------------------------------

test("without a UI attached, setup() leaves messages to Neovim and showcmd() is Neovim's %S", function()
  local nb = fresh()
  nb.setup({ messages = {} })
  eq(nil, require("vim._core.ui2").msg, "ui2 turned on with no UI")
  eq("%S", nb.messages.showcmd())
end)

test("a part turned off in the options is left to plain ui2, and the other parts stay on", function()
  -- 'showcmdloc' starts as "tabline", which only the pending-keys part changes
  local cases = {
    { "{ cmdline = false }", { popup = false, toast = true, showcmdloc = "last" } },
    { "{ toasts = false }", { popup = true, toast = false, showcmdloc = "last" } },
    { "{ showcmd = false }", { popup = true, toast = true, showcmdloc = "tabline" } },
  }
  for _, case in ipairs(cases) do
    with({ snacks = true, opts = case[1], before = "vim.o.showcmdloc = 'tabline'" }, function(c)
      local want = case[2]
      c.send(":")
      ok(in_mode(c, "c"), case[1] .. ": ':' didn't open the command line")
      local popup = want.popup and wait(function() return c.lua(CMD).relative == "editor" end)
        or c.lua(CMD).relative == "editor"
      reset(c)
      echo(c, "hello")
      local toast ---@type boolean
      if want.toast then
        toast = toasts(c)[1] ~= nil
      else
        ok(wait(function() return c.lua(IN_UI2, "hello") end), case[1] .. ": ui2 doesn't show it")
        toast = #c.lua("return _G.toasts") > 0
      end
      eq(want, { popup = popup, toast = toast, showcmdloc = c.lua("return vim.o.showcmdloc") }, case[1])
    end)
  end
end)

test("setup() turns ui2 on with the ui2 options", function()
  -- a message from a timer goes to ui2's target: its cmdline by default, its message window with the options of
  -- this module's docs
  local cases = {
    { "{ toasts = false }", "cmd" },
    { "{ toasts = false, ui2 = { msg = { targets = { default = 'msg' } } } }", "msg" },
  }
  for _, case in ipairs(cases) do
    with({ opts = case[1] }, function(c)
      c.lua("vim.defer_fn(function() vim.api.nvim_echo({ { 'from a timer' } }, true, {}) end, 10)")
      local where = [[
        local ui = require("vim._core.ui2")
        for _, t in ipairs({ "cmd", "msg" }) do
          if table.concat(vim.api.nvim_buf_get_lines(ui.bufs[t], 0, -1, false), "\n"):find("from a timer", 1, true) then
            return t
          end
        end
        return false
      ]]
      eq(case[2], wait(function() return c.lua(where) end) or c.lua(where), case[1])
    end)
  end
end)

-- The cmdline popup --------------------------------------------------------------------------------------------------

test("':' opens a rounded popup near the top with the statusline kept, and <Esc> gives ui2 its window back", function()
  with({}, function(c)
    c.send(":")
    eq(
      { relative = "editor", title = "Cmdline", row = 3, cmdheight = 0 },
      wait(function() return c.lua(CMD).relative == "editor" and c.lua(CMD) end) or c.lua(CMD)
    )
    -- row 3 is the top border, the title in it
    local function top() return c.screen()[4]:match("╭.* Cmdline .*╮") end
    ok(wait(top), table.concat(c.screen(), "\n"))
    ok(c.screen()[36]:find("[No Name]", 1, true), "the last row isn't the statusline: " .. c.screen()[36])
    c.send("<Esc>")
    eq("laststatus", wait(function() return c.lua(CMD).relative == "laststatus" and "laststatus" end) or c.lua(CMD))
  end)
end)

test("the popup's title names the kind of command once the cursor is past its prefix, or the input() prompt", function()
  -- noice's formats (noice/config/init.lua:24-31) and input titles (noice/ui/cmdline.lua:126-146)
  local cases = {
    { ":", "Cmdline" },
    { ":lu", "Cmdline" },
    { ":lua ", "Lua" },
    { ":lua x<C-b> ", "Cmdline" }, -- a space typed at the start: the cursor is before "lua "
    { ":=", "Lua" },
    { ":h ", "Help" },
    { ":help ", "Help" },
    { ":!", "Filter" },
    { ":<C-r>=", "Calculator" },
    { ":call input('Name: ')<CR>", "Name" },
    { (":call input('%s: ')<CR>"):format(("x"):rep(70)), "Input" },
  }
  with({}, function(c)
    local wrong = {}
    for _, case in ipairs(cases) do
      c.send(case[1])
      local got = wait(function() return c.lua(CMD).title == case[2] and case[2] end) or c.lua(CMD).title
      if got ~= case[2] then
        wrong[#wrong + 1] = ("%s -> %q, want %q"):format(case[1], got, case[2])
      end
      reset(c)
    end
    eq({}, wrong)
  end)
end)

test("an input() with no prompt stays at the bottom in ui2's own window", function()
  with({}, function(c)
    c.send(":call input('')<CR>")
    -- in the prompt, after the ':' that came before it closed: ui2 shows both before the child reads more keys
    ok(wait(function() return in_mode(c, "c") and c.lua("return vim.fn.getcmdtype()") == "@" end), "not in the prompt")
    eq("laststatus", c.lua(CMD).relative, "input('')")
  end)
end)

test("confirm() stays in ui2's dialog, and ':' after it is the popup", function()
  with({}, function(c)
    c.send(":call confirm('Sure?', \"&Yes\\n&No\")<CR>")
    -- the child is in the prompt and doesn't answer RPC: read the screen
    ok(wait(function() return table.concat(c.screen(), "\n"):find("[Y]es", 1, true) ~= nil end), "no confirm prompt")
    ok(not table.concat(c.screen(), "\n"):find("╭", 1, true), "a popup for confirm()")
    c.send("n:")
    eq("editor", wait(function() return c.lua(CMD).relative == "editor" and "editor" end) or c.lua(CMD).relative)
  end)
end)

test("after a :if ... :endif block no popup is left on screen", function()
  with({}, function(c)
    c.send(":")
    eq("editor", wait(function() return c.lua(CMD).relative == "editor" and "editor" end) or c.lua(CMD).relative)
    c.send("if 1<CR>endif<CR>")
    ok(in_mode(c, "n"), "still in the block")
    eq("laststatus", c.lua(CMD).relative)
    local function popup() return table.concat(c.screen(), "\n"):find("╭", 1, true) ~= nil end
    ok(wait(function() return not popup() end), table.concat(c.screen(), "\n"))
  end)
end)

test("'/' and '?' type over the last row, with no popup, and the windows keep their height", function()
  with({}, function(c)
    for _, key in ipairs({ "/", "?" }) do
      local height = c.lua("return vim.api.nvim_win_get_height(0)")
      c.send(key .. "abc")
      eq(
        { relative = "editor", title = "", row = 35, cmdheight = 0 },
        wait(function() return c.lua(CMD).relative == "editor" and c.lua(CMD) end) or c.lua(CMD),
        key
      )
      ok(wait(function() return c.screen()[36]:find(key .. "abc", 1, true) ~= nil end), c.screen()[36])
      eq(height, c.lua("return vim.api.nvim_win_get_height(0)"), key .. ": the window's height")
      reset(c)
    end
  end)
end)

test("vim.g.ui_cmdline_pos puts blink's menu under the popup at the typed text, and is cleared after", function()
  with({}, function(c)
    c.send(":")
    -- 120 columns: the popup is 60 wide at column (120 - 60 - 2) / 2 = 29, the text 2 cells in (icon, space); row 3,
    -- one line, its border: the menu's row is 3 + 1 + 2
    local function pos() return c.lua("return vim.g.ui_cmdline_pos") end
    eq({ 6, 31 }, wait(function() return pos() ~= vim.NIL and pos() end) or pos())
    -- <C-c>: one byte, where a lone <Esc> waits out 'ttimeoutlen' in the child's TUI
    c.send("<C-c>")
    eq(vim.NIL, wait(function() return pos() == vim.NIL and vim.NIL end) or pos())
  end)
end)

test("switched off, ':' stays at the bottom; switched on again, it's the popup", function()
  with({}, function(c)
    c.lua("Neoblocks.toggle('messages', false)")
    c.send(":")
    ok(in_mode(c, "c"), "':' didn't open the command line")
    eq("laststatus", c.lua(CMD).relative, "off")
    reset(c)
    c.lua("Neoblocks.toggle('messages', true)")
    c.send(":")
    eq("editor", wait(function() return c.lua(CMD).relative == "editor" and "editor" end) or c.lua(CMD).relative)
  end)
end)

test("a popup that fails while it runs gives the cmdline back to ui2 for good, and warns once", function()
  with({
    -- only the popup sets a rounded border
    after = [[
local set = vim.api.nvim_win_set_config
vim.api.nvim_win_set_config = function(win, cfg)
  if _G.fail_popup and cfg.border == "rounded" then
    error("popup broke")
  end
  return set(win, cfg)
end
_G.fail_popup = true
]],
  }, function(c)
    for i = 1, 2 do
      c.send(":")
      ok(in_mode(c, "c"), "':' didn't open the command line")
      eq("laststatus", c.lua(CMD).relative, "failing, ':' number " .. i)
      c.send("<C-c>")
      ok(in_mode(c, "n"), "still in the command line")
    end
    c.lua("_G.fail_popup = false")
    c.send(":")
    ok(in_mode(c, "c"), "':' didn't open the command line")
    eq("laststatus", c.lua(CMD).relative, "after the failure")
    local _, n = warnings(c):gsub("cmdline: the popup failed", "")
    eq(1, n, warnings(c))
  end)
end)

test(
  "switched off in one buffer, ':' and messages there go to ui2, and other buffers keep the popup and toasts",
  function()
    with({ snacks = true }, function(c)
      c.lua("vim.cmd('Neoblocks! messages off')")
      c.send(":")
      ok(in_mode(c, "c"), "':' didn't open the command line")
      eq("laststatus", c.lua(CMD).relative, "the buffer switched off")
      reset(c)
      echo(c, "in the off buffer")
      ok(wait(function() return c.lua(IN_UI2, "in the off buffer") end), "ui2 doesn't show it")
      eq({}, c.lua("return _G.toasts"), "a toast in the buffer switched off")
      c.lua("vim.cmd.enew()")
      c.send(":")
      eq("editor", wait(function() return c.lua(CMD).relative == "editor" and "editor" end) or c.lua(CMD).relative)
      reset(c)
      echo(c, "in another buffer")
      eq({ "in another buffer" }, vim.tbl_map(function(t) return t.msg end, toasts(c)))
    end)
  end
)

-- Toasts and the split ----------------------------------------------------------------------------------------------

test(":echo is one info toast titled with the command, not in ui2's window, and g< still opens ui2's pager", function()
  with({ snacks = true }, function(c)
    -- the message isn't in the command, which ui2 leaves in its cmd buffer
    c.send(':echo "hi" .. " there"<CR>')
    eq({ { level = "info", msg = "hi there", title = ':echo "hi" .. " there"' } }, toasts(c))
    eq(false, c.lua(IN_UI2, "hi there"))
    c.send("g<")
    ok(
      wait(function() return c.lua("return vim.api.nvim_get_current_win() == require('vim._core.ui2').wins.pager") end),
      "g< didn't open the pager"
    )
  end)
end)

test("an error stays until dismissed, unless it's routine: a search or jump that found nothing", function()
  -- timeout 0 keeps a snacks toast (snacks/notifier.lua:31); nil is snacks' default 3 s. Titles: the typed command,
  -- or noice's "Error" when no command was typed (a search)
  local cases = {
    { ":nosuchcmd<CR>", "E492", { title = ":nosuchcmd", timeout = 0, routine = false } },
    { ":echo nosuchvar<CR>", "E121", { title = ":echo nosuchvar", timeout = 0, routine = false } },
    { "/nosuchtext<CR>", "E486", { title = "Error", routine = true } },
    { ":cnext<CR>", "E42", { title = ":cnext", routine = true } },
  }
  with({ snacks = true }, function(c)
    for _, case in ipairs(cases) do
      c.send(case[1])
      local t = toasts(c)
      eq(1, #t, case[1])
      ok(t[1].msg:find(case[2], 1, true), ("%s: %s"):format(case[1], t[1].msg))
      eq(case[3], { title = t[1].title, timeout = t[1].timeout, routine = t[1].routine }, case[1])
      eq("error", t[1].level, case[1])
      reset(c)
    end
  end)
end)

test("a warning is a warn toast titled Warning", function()
  with({ snacks = true }, function(c)
    c.lua("vim.defer_fn(function() vim.api.nvim_echo({ { 'careful' } }, true, { kind = 'wmsg' }) end, 10)")
    eq({ { level = "warn", msg = "careful", title = "Warning", routine = false } }, toasts(c))
  end)
end)

test("the info messages of a tick merge into one toast, and adjacent errors share one", function()
  with({ snacks = true }, function(c)
    c.send(':lua print("one") print("two")<CR>')
    eq({ { level = "info", msg = "one\ntwo", title = ':lua print("one") print("two")' } }, toasts(c))
    reset(c)
    c.lua([[vim.defer_fn(function()
      vim.api.nvim_echo({ { "E1: first" } }, true, { err = true })
      vim.api.nvim_echo({ { "E2: second" } }, true, { err = true })
    end, 10)]])
    local t = toasts(c)
    eq(1, #t, vim.inspect(t))
    eq({ "error", "E1: first\nE2: second", "Error" }, { t[1].level, t[1].msg, t[1].title })
  end)
end)

test("undo and quickfix messages are left out", function()
  with({ snacks = true }, function(c)
    c.send("oundo me<Esc>u")
    c.lua(
      [[vim.fn.setqflist({ { filename = "qa", lnum = 1, text = "a" }, { filename = "qb", lnum = 1, text = "b" } })]]
    )
    c.send(":cnext<CR>")
    wait(function() return c.lua("return vim.fn.bufname()") == "qb" end)
    -- a message after them, so their own flush has run
    c.send(':echo "marker"<CR>')
    eq({ "marker" }, vim.tbl_map(function(t) return t.msg end, toasts(c)))
  end)
end)

test(":w's written message is an info toast titled :w, and in the history", function()
  with({ snacks = true }, function(c)
    local file = c.lua("return vim.fn.tempname() .. '.txt'")
    c.send((":e %s<CR>ihello<Esc>:w<CR>"):format(file))
    local t = toasts(c)
    ok(#t > 0, "no toast")
    -- "hello" and its newline: 1 line, 6 bytes
    ok(t[#t].msg:find("[New] 1L, 6B written", 1, true), vim.inspect(t))
    eq({ "info", ":w" }, { t[#t].level, t[#t].title })
    local e = vim.tbl_filter(
      function(x) return x.msg:find("written", 1, true) end,
      c.lua("return Neoblocks.messages.entries()")
    )
    eq({ "toast" }, vim.tbl_map(function(x) return x.route end, e))
  end)
end)

test("of the progress messages only a file write's is a toast", function()
  -- the ids Neovim gives its progress messages (:h ui-messages, "progress"): :w's, completion's and indent's; and an
  -- integer, as nvim_echo() gives a plugin's
  local ids = { 'nvim.bufwrite "a.txt"', "nvim.completion", "nvim.indent", 7 }
  with({ snacks = true }, function(c)
    for i, id in ipairs(ids) do
      c.lua(
        "require('vim._core.ui2').msg.msg_show('progress', { { 0, ..., 0 } }, false, true, false, select(2, ...), '')",
        "progress " .. i,
        id
      )
    end
    echo(c, "marker")
    wait(function()
      return vim.tbl_contains(vim.tbl_map(function(t) return t.msg end, c.lua("return _G.toasts")), "marker")
    end)
    eq({ "progress 1", "marker" }, vim.tbl_map(function(t) return t.msg end, c.lua("return _G.toasts")))
  end)
end)

test("output taller than a toast opens in a split below that isn't entered, and q closes it", function()
  with({ snacks = true }, function(c)
    c.send(':lua print(table.concat(vim.fn.range(1, 60), "\\n"))<CR>')
    local s = wait(function() return split_with(c, "\n60") end)
    ok(s, "no split with the output")
    eq(false, s.current, "the split was entered")
    eq({}, c.lua("return _G.toasts"), "the output was a toast too")
    c.send("<C-w>jq")
    eq(1, wait(function() return #c.lua(SPLITS) == 1 and 1 end) or #c.lua(SPLITS))
  end)
end)

test("a typed command's output is measured as a whole, other messages one at a time", function()
  -- 36 rows: a toast holds min(20, 36 * 0.6 - 2) = 19 rows (noice's 20, snacks' max height 0.6)
  with({ snacks = true }, function(c)
    c.send(':lua for i = 1, 25 do print("typed-" .. i) end<CR>')
    ok(wait(function() return split_with(c, "typed-25") end), "25 lines of one typed command: no split")
    reset(c)
    c.lua([[vim.defer_fn(function()
      for i = 1, 25 do vim.api.nvim_echo({ { "burst-" .. i } }, true, {}) end
    end, 10)]])
    local t = toasts(c)
    ok(t[1] and t[1].msg:find("burst-25", 1, true), "25 short messages from a timer: no toast")
    eq(nil, split_with(c, "burst-25"), "25 short messages from a timer opened a split")
    reset(c)
    c.lua([[vim.defer_fn(function() print("long\n" .. table.concat(vim.fn.range(1, 30), "\n")) end, 10)]])
    ok(wait(function() return split_with(c, "long") end), "one 31-line message from a timer: no split")
  end)
end)

test("lines that wrap in a toast count as the rows they wrap to", function()
  -- 19 lines of 47 cells: a toast is at most 120 * 0.4 = 48 wide with 2 cells of padding, so each takes 2 rows
  with({ snacks = true }, function(c)
    c.send(':lua for i = 10, 28 do print(i .. string.rep("x", 45)) end<CR>')
    ok(wait(function() return split_with(c, "28xxx") end), "no split")
    eq({}, c.lua("return _G.toasts"))
  end)
end)

test("without snacks.notifier, messages stay with ui2 and still go in the history", function()
  with({}, function(c)
    echo(c, "plain")
    ok(wait(function() return c.lua(IN_UI2, "plain") end), "ui2 doesn't show it")
    local e = c.lua("return Neoblocks.messages.entries()")
    eq({ { "plain", "ui2", "info" } }, vim.tbl_map(function(x) return { x.msg, x.route, x.level } end, e))
  end)
end)

test("an error ui2 showed before snacks was set up becomes a toast once it is; info doesn't", function()
  with({
    after = [[
vim.api.nvim_echo({ { "E5: early" } }, true, { err = true })
vim.api.nvim_echo({ { "early info" } }, true, {})
]] .. FAKE_SNACKS,
  }, function(c)
    local t = toasts(c)
    eq(1, #t, vim.inspect(t))
    eq("error", t[1].level)
    ok(t[1].msg:find("E5: early", 1, true), t[1].msg)
  end)
end)

test("switched off, messages go to ui2; on again, they're toasts", function()
  with({ snacks = true }, function(c)
    c.lua("Neoblocks.toggle('messages', false)")
    echo(c, "while off")
    ok(wait(function() return c.lua(IN_UI2, "while off") end), "ui2 doesn't show it")
    c.lua("Neoblocks.toggle('messages', true)")
    echo(c, "on again")
    eq({ "on again" }, vim.tbl_map(function(t) return t.msg end, toasts(c)))
  end)
end)

test("a toast that fails gives the message to ui2, warns once, and later messages go to ui2", function()
  with({ snacks = true }, function(c)
    c.lua("_G.notify_fails = true")
    echo(c, "boom")
    ok(wait(function() return c.lua(IN_UI2, "boom") end), "the failed message isn't shown")
    ok(
      wait(function() return c.lua("return vim.fn.execute('messages')"):find("toasts:.*plain ui2") ~= nil end),
      "no warning: " .. c.lua("return vim.fn.execute('messages')")
    )
    c.lua("_G.notify_fails = false")
    echo(c, "after")
    ok(wait(function() return c.lua(IN_UI2, "after") end), "the next message isn't with ui2")
    eq({}, c.lua("return _G.toasts"))
  end)
end)

-- History -----------------------------------------------------------------------------------------------------------

test("history() opens snacks' picker over the messages and the vim.notify() history, newest first", function()
  with({ snacks = true }, function(c)
    c.lua("_G.notify_history = { { added = 1, level = 'warn', title = 'N', msg = 'from notify' } }")
    local function shown(n)
      return wait(function() return #c.lua("return _G.toasts") >= n end)
    end
    echo(c, "first")
    ok(shown(1), "no toast")
    echo(c, "second")
    ok(shown(2), "no second toast")
    c.lua("Neoblocks.messages.history()")
    local items = c.lua("return vim.tbl_map(function(i) return i.item.msg end, _G.picked.items)")
    eq({ "second", "first", "from notify" }, items)
  end)
end)

test("without snacks, history() lists the messages newest first in a split", function()
  with({}, function(c)
    echo(c, "older")
    echo(c, "newer")
    wait(function() return #c.lua("return Neoblocks.messages.entries()") == 2 end)
    c.lua("Neoblocks.messages.history()")
    local lines = c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    eq(2, #lines, vim.inspect(lines))
    ok(lines[1]:find("newer$") and lines[2]:find("older$"), vim.inspect(lines))
  end)
end)

-- Pending keys ------------------------------------------------------------------------------------------------------

test("pending() leaves out a lone key whose command runs at once, and keeps the keys of one that waits", function()
  -- fed as Neovim sends them to ui2 with 'showcmdloc' "last" (:h ui-messages, msg_showcmd)
  local cases = {
    { "w", "" },
    { "j", "" },
    { "^D", "" },
    { "^U", "" },
    { "p", "" },
    { "x", "" },
    { "5", "5" },
    { "d", "d" },
    { "c", "c" },
    { "y", "y" },
    { ">", ">" },
    { '"', '"' },
    { "f", "f" },
    { "r", "r" },
    { "z", "z" },
    { "Z", "Z" },
    { "^W", "^W" },
    { "q", "q" },
    { "m", "m" },
    { "@", "@" },
    { "5d", "5d" },
    { '"ay', '"ay' },
    { "d2", "d2" },
    { "12", "12" },
    { "3x5", "3x5" },
    { "12345678901", "2345678901" },
  }
  with({}, function(c)
    local wrong = {}
    for _, case in ipairs(cases) do
      local got =
        c.lua("require('vim._core.ui2').msg.msg_showcmd({ { 0, ... } }) return Neoblocks.messages.pending()", case[1])
      if got ~= case[2] then
        wrong[#wrong + 1] = ("%q -> %q, want %q"):format(case[1], got, case[2])
      end
    end
    eq({}, wrong)
  end)
end)

test("a statusline drawing showcmd() shows a count and an operator as they're typed", function()
  with({ after = [[vim.o.statusline = "SL[" .. Neoblocks.messages.showcmd() .. "]"]] }, function(c)
    for _, step in ipairs({ { "5", "5" }, { "d", "5d" }, { "<Esc>", "" } }) do
      eq(step[2], sl_after(c, step[1], step[2]), step[1])
    end
  end)
end)

test("a statusline that drew showcmd() once shows pending keys switched off and on, with no rebuild", function()
  -- Neovim's default 'showcmdloc' ("last"), which draws nothing for %S. A plain 'statusline' string drawn while
  -- off, and the neoblocks statusline drawn at setup while on, which rebuilds only on its events: a count is none
  local cases = {
    {
      "plain, drawn while off",
      {
        after = [[
Neoblocks.toggle("messages", false)
vim.o.statusline = "SL[" .. Neoblocks.messages.showcmd() .. "]"
Neoblocks.toggle("messages", true)
]],
      },
    },
    {
      "neoblocks statusline, drawn while on",
      {
        setup = [[{ messages = {}, statusline = {
        left = { { function() return "SL[" .. Neoblocks.messages.showcmd() .. "]" end, padding = 0 } }, right = {},
      } }]],
      },
    },
  }
  for _, case in ipairs(cases) do
    with(case[2], function(c)
      for _, state in ipairs({ false, true, false }) do
        local name = ("%s, %s"):format(case[1], state and "on" or "off")
        c.lua("Neoblocks.toggle('messages', ...)", state)
        eq("5", sl_after(c, "5", "5"), name)
        eq("", sl_after(c, "<Esc>", ""), name)
        -- the hook's 'showcmdloc' while on (pending keys reach it), Neovim's statusline one while off (%S draws them)
        eq(state and "last" or "statusline", c.lua("return vim.o.showcmdloc"), name)
      end
    end)
  end
end)

test("switched off in one buffer, pending keys stay on: 'showcmdloc' is global", function()
  with({}, function(c)
    c.lua("vim.cmd('Neoblocks! messages off')")
    eq("last", c.lua("return vim.o.showcmdloc"))
    local got = c.lua("require('vim._core.ui2').msg.msg_showcmd({ { 0, '5' } }) return Neoblocks.messages.pending()")
    eq("5", got, "pending() after a count")
  end)
end)

test("switched off while a count is pending, the statusline drops it", function()
  with({
    after = [[
vim.o.statusline = "SL[" .. Neoblocks.messages.showcmd() .. "]"
vim.keymap.set("n", "Q", "<Cmd>lua Neoblocks.toggle('messages', false)<CR>")
]],
  }, function(c)
    eq("5", sl_after(c, "5", "5"), "the count")
    c.send("Q")
    eq("statusline", wait(function() return c.lua("return vim.o.showcmdloc") == "statusline" and "statusline" end))
    eq("", wait(function() return sl(c) == "" and "" end) or sl(c), "after the switch")
  end)
end)

test(
  "a pending-keys hook that fails gives the keys back to Neovim, warns once, and the statusline still shows them",
  function()
    with({ after = [[vim.o.statusline = "SL[" .. Neoblocks.messages.showcmd() .. "]"]] }, function(c)
      -- a chunk whose text isn't a string, as if ui2 changed what it sends
      for _ = 1, 2 do
        c.lua("pcall(require('vim._core.ui2').msg.msg_showcmd, { { 0, true } })")
      end
      ok(wait(function() return warnings(c):find("showcmd: .*plain ui2") ~= nil end), "no warning: " .. warnings(c))
      local _, n = warnings(c):gsub("showcmd: ", "")
      eq(1, n, warnings(c))
      eq("5", sl_after(c, "5", "5"))
    end)
  end
)

-- Missing internals -------------------------------------------------------------------------------------------------

test("a ui2 internal that's missing leaves its part to plain ui2, says so, and the other parts work", function()
  with({
    -- as if a Neovim renamed msg_showcmd: ui2 skips events it has no handler for (vim/_core/ui2.lua, ui_attach)
    before = "require('vim._core.ui2').enable({}) require('vim._core.ui2').msg.msg_showcmd = nil",
    after = [[vim.o.statusline = "SL[" .. Neoblocks.messages.showcmd() .. "]"]],
  }, function(c)
    -- Neovim draws the pending keys in the statusline itself
    eq("5", sl_after(c, "5", "5"))
    eq("", sl_after(c, "<Esc>", ""))
    ok(
      wait(function() return c.lua("return vim.fn.execute('messages')"):find("showcmd: .*plain ui2") ~= nil end),
      "no warning: " .. c.lua("return vim.fn.execute('messages')")
    )
    c.send(":")
    eq("editor", wait(function() return c.lua(CMD).relative == "editor" and "editor" end) or c.lua(CMD).relative)
    reset(c)
    c.lua("vim.cmd('checkhealth neoblocks')")
    local health = table.concat(c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "\n")
    ok(health:find("showcmd: plain ui2", 1, true) and health:find("cmdline: on", 1, true), health)
  end)
end)
