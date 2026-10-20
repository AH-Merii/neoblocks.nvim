-- The diagnostics module, each test in a child Neovim with a UI (a terminal, 80x24), driven over RPC. What's drawn is
-- read from the child's screen (its cells' text) and from the module's extmarks (each chunk's colours). The expected
-- rows are tiny-inline-diagnostic's with nvim-config's options, as bench/diagnostics.lua compares them cell by cell;
-- the signs are its modern preset's (presets.lua:4-12).
local root = vim.fn.getcwd()
vim.o.columns, vim.o.lines = 100, 40

-- U+E0B6, U+E0B4, U+F177 and U+F176 as UTF-8 bytes (Lua 5.1 has no \u{})
local LEFT, RIGHT, DOT = "\238\130\182", "\238\130\180", "●"
local ARROW, UP = " \239\133\183   ", " \239\133\182   "

---@alias DiagMark { row: integer, id: integer, text: string, chunks: { text: string, fg?: integer, bg?: integer }[] }

---@class DiagChild
---@field lua fun(code: string, ...): any runs `code` in the child, its `...` the arguments
---@field move fun(line: integer, col?: integer) puts the cursor there (1-based line, 0-based column); the child reacts
---@field row fun(r: integer): string screen row `r` (0-based), trailing blanks dropped
---@field marks fun(buf?: integer): DiagMark[] the extmarks in `buf` (default: the current one), colours resolved
---@field stop fun()

--- A child with `lines` in its buffer and `diags` set on it (vim.diagnostic.set() lists), no sign or number column.
--- `opts` is the diagnostics options (Lua), `before` runs before setup().
---@param o { lines: string[], diags?: table[], opts?: string, before?: string }
---@return DiagChild
local function start(o)
  local init = vim.fn.tempname() .. ".lua"
  local sock = vim.fn.tempname() .. ".sock"
  vim.fn.writefile(
    vim.split(
      table.concat({
        ("vim.opt.rtp:prepend(%q)"):format(root),
        'vim.cmd.runtime("plugin/neoblocks.lua")',
        "vim.o.termguicolors = true",
        "vim.o.swapfile = false",
        "vim.o.cursorline = true",
        "vim.diagnostic.config({ virtual_text = false, signs = false, underline = false })",
        o.before or "",
        ("require('neoblocks').setup({ diagnostics = %s })"):format(o.opts or "{}"),
      }, "\n"),
      "\n"
    ),
    init
  )
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 80, height = 24 })
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "-u", init, "--listen", sock }, { term = true })
  local ch ---@type integer?
  vim.wait(5000, function()
    if vim.uv.fs_stat(sock) then
      ch = vim.fn.sockconnect("pipe", sock, { rpc = true })
    end
    return ch ~= nil and ch > 0
  end, 20)
  assert(ch and ch > 0, "the child didn't listen on " .. sock)
  -- RPC is served while the child still starts ('background' detection waits), before init has run
  assert(vim.wait(5000, function() return vim.rpcrequest(ch, "nvim_get_vvar", "vim_did_enter") == 1 end, 20))
  -- vim.rpcrequest() has no @return annotation, so its result would type as nil
  ---@return any
  local function lua(code, ...) return vim.rpcrequest(ch, "nvim_exec_lua", code, { ... }) end
  ---@type DiagChild
  local c = {
    lua = lua,
    move = function(line, col)
      lua("vim.api.nvim_win_set_cursor(0, { ... })", line, col or 0)
      lua("") -- CursorMoved runs before the child reads the next request
    end,
    row = function(r)
      return (
        lua(
          [[
        vim.cmd.redraw()
        local cells = {}
        for c = 0, vim.o.columns - 1 do
          cells[#cells + 1] = vim.api.nvim__inspect_cell(1, ..., c)[1]
        end
        return table.concat(cells)
      ]],
          r
        ):gsub("%s+$", "")
      )
    end,
    marks = function(b)
      return lua(
        [[
        local ns = vim.api.nvim_get_namespaces()["neoblocks.diagnostics"]
        local ret = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(..., ns, 0, -1, { details = true })) do
          local chunks, text = {}, {}
          for _, ch in ipairs(m[4].virt_text or {}) do
            local h = vim.api.nvim_get_hl(0, { name = ch[2], link = false })
            chunks[#chunks + 1] = { text = ch[1], fg = h.fg, bg = h.bg }
            text[#text + 1] = ch[1]
          end
          ret[#ret + 1] = { row = m[2], text = table.concat(text), chunks = chunks, id = m[1] }
        end
        table.sort(ret, function(a, b) return a.row < b.row end)
        return ret
      ]],
        b or 0
      )
    end,
    stop = function()
      vim.fn.jobstop(job)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end,
  }
  c.lua(
    [[
    local lines, diags = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    _G.ns = vim.api.nvim_create_namespace("test")
    vim.diagnostic.set(_G.ns, 0, diags)
  ]],
    o.lines,
    o.diags or {}
  )
  return c
end

--- Runs `fn` with a child, and stops the child whatever happens.
---@param o { lines: string[], diags?: table[], opts?: string, before?: string }
---@param fn fun(c: DiagChild)
local function with(o, fn)
  local c = start(o)
  local ok_, err = xpcall(fn, debug.traceback, c)
  c.stop()
  assert(ok_, err)
end

--- Waits until `cond()` is true, up to 5 s; returns its last value.
local function wait(cond)
  vim.wait(5000, cond, 20)
  return cond()
end

local function E(lnum, col, end_col, message, extra)
  return vim.tbl_extend(
    "force",
    { lnum = lnum, col = col, end_col = end_col, severity = 1, message = message },
    extra or {}
  )
end

test(
  "the cursor's line shows its diagnostic after the text, with its code and source; other lines show nothing",
  function()
    with({
      lines = { "local a = 1", "print(b)" },
      diags = { E(1, 6, 7, "Undefined global `b`.", { code = "undefined-global", source = "lua_ls" }) },
    }, function(c)
      c.move(2, 6)
      eq(
        "print(b) " .. ARROW .. LEFT .. " " .. DOT .. " Undefined global `b`. [undefined-global] (lua_ls) " .. RIGHT,
        c.row(1)
      )
      eq("local a = 1", c.row(0))
    end)
  end
)

test(
  "off a diagnostic's line, each line shows a pill: a dot per diagnostic, the most severe last, then the count",
  function()
    with({
      lines = { "x = 1", "y = 2", "z = 3" },
      diags = {
        E(0, 0, 1, "w", { severity = 2 }),
        E(2, 0, 1, "h", { severity = 4 }),
        E(2, 0, 1, "e"),
        E(2, 2, 3, "w", { severity = 2 }),
      },
    }, function(c)
      c.lua([[
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
      vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xff0000 })
      vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xffff00 })
      vim.api.nvim_set_hl(0, "DiagnosticHint", { fg = 0x0000ff })
      vim.cmd.doautocmd("ColorScheme")
    ]])
      c.move(2, 0)
      eq("x = 1 " .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT, c.row(0))
      eq("z = 3 " .. ARROW .. LEFT .. " " .. DOT:rep(3) .. " 3 " .. RIGHT, c.row(2))
      -- each dot in its severity's colour, on the error's tint: 22% of #ff0000 over #000000 is #380000
      local dots = vim.tbl_filter(function(ch) return ch.text == DOT end, c.marks()[2].chunks)
      eq({
        { text = DOT, fg = 0x0000ff, bg = 0x380000 },
        { text = DOT, fg = 0xffff00, bg = 0x380000 },
        { text = DOT, fg = 0xff0000, bg = 0x380000 },
      }, dots)
    end)
  end
)

test("the diagnostic under the cursor's column shows alone; with none under it, every one on the line does", function()
  local line = "local value = compute(x)" -- 24 columns: the text after it starts at 25, its second row at 25 + 6
  with({
    lines = { line, "x" },
    diags = { E(0, 0, 5, "Unused.", { severity = 2 }), E(0, 14, 21, "Bad call.") },
  }, function(c)
    c.move(1, 1)
    eq(line .. " " .. ARROW .. LEFT .. " " .. DOT .. " Unused. " .. RIGHT, c.row(0))
    eq("x", c.row(1))
    c.move(1, 15)
    eq(line .. " " .. ARROW .. LEFT .. " " .. DOT .. " Bad call. " .. RIGHT, c.row(0))
    c.move(1, 12)
    eq(line .. " " .. ARROW .. LEFT .. " " .. DOT .. " Bad call.", c.row(0))
    eq("x" .. (" "):rep(30) .. " " .. DOT .. " Unused.   " .. RIGHT, c.row(1))
  end)
end)

test("a zero-width range is under the cursor on the characters either side of it", function()
  with({
    lines = { "hello world here" },
    diags = { E(0, 5, 5, "gap", { severity = 2 }), E(0, 12, 16, "end") },
  }, function(c)
    for _, col in ipairs({ 4, 5 }) do
      c.move(1, col)
      local row = c.row(0)
      ok(row:find("gap", 1, true) and not row:find("end", 1, true), ("col %d: %s"):format(col, row))
    end
    c.move(1, 7)
    ok(c.row(0):find("end", 1, true) and c.row(1):find("gap", 1, true), "col 7: both, the error first")
  end)
end)

test(
  "a message's further lines get rows of their own over the lines below, aligned, the last one closed with └",
  function()
    with({
      lines = { "a = f()", "", "" },
      diags = { E(0, 4, 7, "Type mismatch:\n  expected: str\n  found: int", { source = "pyrefly" }) },
    }, function(c)
      c.move(1, 4)
      -- "a = f()" ends at 7: the text after it starts at 8, the rows below at 8 + 6
      eq("a = f() " .. ARROW .. LEFT .. " " .. DOT .. " Type mismatch:", c.row(0))
      eq((" "):rep(14) .. " │   expected: str", c.row(1))
      eq((" "):rep(14) .. " └   found: int (pyrefly) " .. RIGHT, c.row(2))
    end)
  end
)

test("related information goes under its diagnostic: up to `related` entries, empty messages skipped", function()
  local function rel(msg, line)
    return {
      message = msg,
      location = { uri = "file:///tmp/other.py", range = { start = { line = line, character = 0 } } },
    }
  end
  local o = {
    lines = { "call(x)", "", "", "", "" },
    diags = {
      E(0, 0, 4, "Bad argument.", {
        user_data = {
          lsp = {
            relatedInformation = { rel("Declared here", 11), rel("", 2), rel("Called here", 40), rel("Fourth", 3) },
          },
        },
      }),
    },
  }
  local function screen(c)
    c.move(1, 0)
    local rows = {}
    for r = 0, 4 do
      rows[#rows + 1] = c.row(r)
    end
    return table.concat(rows, "\n")
  end
  with(o, function(c)
    local s = screen(c)
    ok(s:find("↳ Declared here [other.py:12]", 1, true), s)
    ok(s:find("↳ Called here [other.py:41]", 1, true), s)
    ok(not s:find("Fourth", 1, true), "the third entry is the last: " .. s)
    ok(not s:find("[other.py:3]", 1, true), "the empty entry draws no row: " .. s)
  end)
  o.opts = "{ related = 1 }"
  with(o, function(c)
    local s = screen(c)
    ok(s:find("Declared here", 1, true) and not s:find("Called here", 1, true), s)
  end)
end)

test(
  "a line ending within `softwrap` columns of the window's edge gets them under it, from the first column",
  function()
    with({ lines = { ("x"):rep(60), "", "" }, diags = { E(0, 0, 1, "Too long.") } }, function(c)
      c.move(1, 0)
      eq(UP:gsub("%s+$", ""), c.row(1))
      eq(LEFT .. " " .. DOT .. " Too long. " .. RIGHT, c.row(2))
    end)
  end
)

test("rows past the buffer's last line are virtual lines under it", function()
  with({ lines = { "a", "last = 1" }, diags = { E(1, 0, 4, "one\ntwo\nthree") } }, function(c)
    c.move(2, 0)
    eq("last = 1 " .. ARROW .. LEFT .. " " .. DOT .. " one", c.row(1))
    eq((" "):rep(15) .. " │ two", c.row(2))
    eq((" "):rep(15) .. " └ three " .. RIGHT, c.row(3))
  end)
end)

--- The module's extmarks' texts, row by row.
local function texts(c, b)
  return vim.tbl_map(function(m) return m.row .. ":" .. m.text end, c.marks(b))
end

local TWO = {
  lines = { "x = 1", "y = 2", "z = 3" },
  diags = { E(0, 0, 1, "First.", { severity = 2 }), E(2, 0, 1, "Third.") },
}
local PILLS =
  { "0:" .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT, "2:" .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT }

test("Insert, Select and Visual mode hide them until Normal mode; Visual-block mode keeps them", function()
  with(TWO, function(c)
    c.move(2, 0)
    eq(PILLS, texts(c))
    local function mode(keys, want)
      c.lua("vim.api.nvim_input(...)", keys)
      return wait(function() return c.lua("return vim.api.nvim_get_mode().mode") == want end)
    end
    for _, m in ipairs({ { "i", "i" }, { "v", "v" }, { "V", "V" }, { "gh", "s" } }) do
      ok(mode(m[1], m[2]), m[2])
      eq({}, texts(c), m[2])
      ok(mode("<Esc>", "n"), "back from " .. m[2])
      eq(PILLS, texts(c), "back from " .. m[2])
    end
    ok(mode("<C-v>", "\22"))
    eq(PILLS, texts(c))
  end)
end)

test("the diagnostics float hides them until it closes", function()
  with(TWO, function(c)
    c.move(1, 0)
    local shown = texts(c)
    eq({ "0:" .. ARROW .. LEFT .. " " .. DOT .. " First. " .. RIGHT }, shown)
    c.lua("_G.float_buf, _G.float_win = vim.diagnostic.open_float()")
    ok(c.lua("return vim.api.nvim_win_is_valid(_G.float_win)"), "the float opened")
    eq({}, texts(c))
    c.lua("vim.api.nvim_win_close(_G.float_win, true)")
    eq(shown, wait(function() return #texts(c) > 0 and texts(c) end))
  end)
end)

test(":Neoblocks diagnostics off hides them everywhere, :Neoblocks! in the current buffer only", function()
  with(TWO, function(c)
    c.move(2, 0)
    c.lua("vim.cmd('Neoblocks diagnostics off')")
    eq({}, texts(c))
    c.lua("vim.cmd('Neoblocks diagnostics on')")
    eq(PILLS, texts(c))
    -- a second buffer, with a diagnostic, in a window of its own
    c.lua([[
      vim.cmd("new")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "other" })
      vim.diagnostic.set(_G.ns, 0, { { lnum = 0, col = 0, severity = 1, message = "Other." } })
    ]])
    c.lua("vim.cmd('Neoblocks! diagnostics off')")
    eq({}, texts(c))
    eq(PILLS, texts(c, 1))
    c.lua("vim.cmd('Neoblocks! diagnostics on')")
    ok(texts(c)[1]:find("Other.", 1, true), "back in the second buffer")
  end)
end)

test(
  "they follow vim.diagnostic: enable(false) hides them, the handler's severity filter applies, false turns them off",
  function()
    with(TWO, function(c)
      c.move(2, 0)
      c.lua("vim.diagnostic.enable(false)")
      eq({}, texts(c))
      c.lua("vim.diagnostic.enable(true)")
      eq(PILLS, texts(c))
      c.lua("vim.diagnostic.config({ ['neoblocks.diagnostics'] = { severity = vim.diagnostic.severity.ERROR } })")
      eq({ PILLS[2] }, texts(c))
      c.lua("vim.diagnostic.config({ ['neoblocks.diagnostics'] = false })")
      eq({}, texts(c))
    end)
  end
)

test("a NUL byte in the line or the message draws as ^@, with or without 'wrap', and raises no error", function()
  for _, wrap in ipairs({ false, true }) do
    with({ lines = { "a\0b", "" }, diags = { E(0, 0, 1, "bad\0msg") } }, function(c)
      c.lua("vim.wo.wrap = ...", wrap)
      c.move(1, 0)
      eq("a^@b " .. ARROW .. LEFT .. " " .. DOT .. " bad^@msg " .. RIGHT, c.row(0), "wrap " .. tostring(wrap))
      eq("", c.lua("return vim.v.errmsg"))
    end)
  end
end)

test("diagnostics from several namespaces count together in one pill", function()
  with({ lines = { "x = 1", "" }, diags = { E(0, 0, 1, "One.") } }, function(c)
    c.lua([[
      local second = vim.api.nvim_create_namespace("second")
      vim.diagnostic.set(second, 0, { { lnum = 0, col = 2, severity = 1, message = "Two." } })
    ]])
    c.move(2, 0)
    eq("x = 1 " .. ARROW .. LEFT .. " " .. DOT:rep(2) .. " 2 " .. RIGHT, c.row(0))
  end)
end)

test("a buffer shown in another window than the current one draws for that window", function()
  with({ lines = { "a", "b" } }, function(c)
    c.lua([[
      vim.cmd("new")
      vim.diagnostic.set(_G.ns, 1, { { lnum = 1, col = 0, severity = 1, message = "Elsewhere." } })
    ]])
    eq({ "1:" .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT }, texts(c, 1))
  end)
end)

test("a window made taller shows the pills of the lines it reveals", function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = "line " .. i
  end
  with({ lines = lines }, function(c)
    c.lua([[
      vim.cmd("split | resize 3")
      vim.diagnostic.set(_G.ns, 0, { { lnum = 20, col = 0, severity = 1, message = "Far." } })
    ]])
    eq({}, texts(c))
    c.lua("vim.cmd.only()")
    eq(
      { "20:" .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT },
      wait(function() return #texts(c) > 0 and texts(c) end)
    )
  end)
end)

test(
  "a window scrolled further than its pills reach, its cursor not moving with it, shows the lines it brings into view",
  function()
    local lines = {}
    for i = 1, 100 do
      lines[i] = "line " .. i
    end
    with({ lines = { "current" } }, function(c)
      -- another buffer in the window below, scrolled from outside it, as the mouse wheel does
      c.lua(
        [[
      local lines = ...
      vim.cmd("belowright new | resize 8")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.diagnostic.set(_G.ns, 0, { { lnum = 60, col = 0, severity = 1, message = "Far." } })
      _G.other = vim.api.nvim_get_current_win()
      vim.cmd("wincmd p")
    ]],
        lines
      )
      local buf = c.lua("return vim.api.nvim_win_get_buf(_G.other)")
      eq({}, texts(c, buf))
      c.lua("vim.api.nvim_win_call(_G.other, function() vim.fn.winrestview({ topline = 55, lnum = 56 }) end)")
      eq(
        { "60:" .. ARROW .. LEFT .. " " .. DOT .. " 1 " .. RIGHT },
        wait(function() return #texts(c, buf) > 0 and texts(c, buf) end)
      )
    end)
  end
)

test("a window made narrower puts the cursor line's diagnostics under it once the line ends near the edge", function()
  with({ lines = { ("x"):rep(30), "", "" }, diags = { E(0, 0, 1, "Too long.") } }, function(c)
    c.lua("vim.cmd('vnew | wincmd p | vertical resize 70')")
    c.move(1, 0)
    eq({ "0:" .. ARROW .. LEFT .. " " .. DOT .. " Too long. " .. RIGHT }, texts(c))
    c.lua("vim.cmd('vertical resize 45')")
    eq(
      { "1:" .. UP, "2:" .. LEFT .. " " .. DOT .. " Too long. " .. RIGHT },
      wait(
        function() return texts(c)[1] ~= "0:" .. ARROW .. LEFT .. " " .. DOT .. " Too long. " .. RIGHT and texts(c) end
      )
    )
  end)
end)

test("scrolled sideways, the cursor's line keeps its diagnostics right after its text", function()
  with({ lines = { "local value = compute(x)" }, diags = { E(0, 14, 21, "Bad call.") } }, function(c)
    c.lua("vim.wo.wrap = false")
    c.move(1, 15)
    c.lua("vim.cmd('normal! 3zl')")
    eq(3, c.lua("return vim.fn.winsaveview().leftcol"))
    eq("al value = compute(x) " .. ARROW .. LEFT .. " " .. DOT .. " Bad call. " .. RIGHT, c.row(0))
  end)
end)

test("a cursor move that changes nothing drawn leaves the extmarks as they are, so Neovim redraws nothing", function()
  -- between lines without diagnostics
  with({ lines = { "a", "b", "c", "d", "e" }, diags = { E(0, 0, 1, "A."), E(4, 0, 1, "E.") } }, function(c)
    c.move(2, 0)
    local before = c.marks()
    eq(2, #before)
    c.move(3, 0)
    c.move(4, 0)
    eq(before, c.marks())
  end)
  -- along a line, under the same diagnostic
  with({ lines = { "print(b)", "x" }, diags = { E(0, 0, 8, "Bad.") } }, function(c)
    c.move(1, 1)
    local before = c.marks()
    eq(1, #before)
    c.move(1, 5)
    eq(before, c.marks())
  end)
end)

test("a buffer unloaded, read again or wiped out keeps nothing drawn from before", function()
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(TWO.lines, path)
  local block = { "0:" .. ARROW .. LEFT .. " " .. DOT .. " First. " .. RIGHT }
  for _, reload in ipairs({ "edit!", "write | enew | bunload # | buffer #" }) do
    with(vim.tbl_extend("force", TWO, { before = ("vim.cmd.edit(%q)"):format(path) }), function(c)
      c.move(2, 0)
      eq(PILLS, texts(c))
      c.lua("vim.cmd(...)", reload)
      c.move(1, 0)
      eq(block, texts(c), reload)
      c.move(2, 0)
      eq(PILLS, texts(c), reload)
    end)
  end
  -- an unnamed buffer written under a name is wiped out and made again; vim.diagnostic drops its diagnostics
  with(TWO, function(c)
    c.move(2, 0)
    c.lua("vim.cmd.write(...)", vim.fn.tempname())
    eq({}, texts(c))
    c.lua("vim.diagnostic.set(_G.ns, 0, { { lnum = 0, col = 0, severity = 1, message = 'First.' } })")
    c.move(1, 0)
    eq(block, texts(c))
  end)
end)

-- tiny-inline-diagnostic gives the arrow CursorLine's background whatever 'cursorline' is (chunk.lua:332-343)
test(
  "on the cursor's line the pill's ends take CursorLine's background, none with 'nocursorline'; the arrow keeps it",
  function()
    with({ lines = { "print(b)" }, diags = { E(0, 6, 7, "Undefined.") } }, function(c)
      c.lua([[
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x222222 })
      vim.cmd.doautocmd("ColorScheme")
    ]])
      local function ends()
        local got = {}
        for _, ch in ipairs(c.marks()[1].chunks) do
          if ch.text == ARROW or ch.text == LEFT or ch.text == RIGHT then
            got[#got + 1] = ch.bg or false
          end
        end
        return got
      end
      c.move(1, 6)
      eq({ 0x222222, 0x222222, 0x222222 }, ends())
      c.lua("vim.wo.cursorline = false")
      c.move(1, 7)
      eq({ 0x222222, false, false }, ends())
    end)
  end
)
