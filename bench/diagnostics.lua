-- The diagnostics module against tiny-inline-diagnostic.nvim set up as nvim-config had it
-- (nvim-config 4949601:nvim/lua/features/diagnostics.lua, its options below as TINY). Two parts:
--
-- 1. The look: each scenario runs on both sides, each in its own `nvim --clean` with a UI (a terminal, 100x30), and
--    after each step the whole screen is read cell by cell (nvim__inspect_cell(): text, colours, italic). Every
--    cell must match; a mismatch prints both rows and the run fails. tiny-inline-diagnostic is settled by calling
--    its renderer before each read, so its throttle can't leave a frame half drawn.
-- 2. The cost: operations from a timer in the child, the child's CPU time (getrusage) over them divided by their
--    number: what Neovim, the plugin and the drawing take for each, idle time left out. Median µs per operation, sides
--    interleaved, 3 runs per side per round.
--
--   nvim --clean --headless -l bench/diagnostics.lua [folder with tiny-inline-diagnostic.nvim] [rounds] [look|cost]
--
-- The folder defaults to ~/.local/share/nvim/site/pack/core/opt; rounds to 5; both parts run unless one is named.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

-- nvim-config's tiny-inline-diagnostic options, as they were (features/diagnostics.lua:8-109)
local TINY = [[{
  preset = "modern",
  transparent_cursorline = true,
  hi = { error = "DiagnosticError", warn = "DiagnosticWarn", info = "DiagnosticInfo", hint = "DiagnosticHint",
    arrow = "NonText", background = "CursorLine", mixing_color = "Normal" },
  options = {
    show_source = { enabled = true, if_many = false },
    use_icons_from_diagnostic = false,
    set_arrow_to_diag_color = false,
    throttle = 20,
    softwrap = 30,
    add_messages = { messages = true, display_count = true, use_max_severity = false, show_multiple_glyphs = true },
    multilines = { enabled = true, always_show = false, trim_whitespaces = false, tabstop = 4, severity = nil },
    show_all_diags_on_cursorline = false,
    show_related = { enabled = true, max_count = 3 },
    overflow = { mode = "none", padding = 0 },
    break_line = { enabled = false, after = 30 },
    format = nil,
    virt_texts = { priority = 2048 },
    severity = { vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN, vim.diagnostic.severity.INFO,
      vim.diagnostic.severity.HINT },
    override_open_float = true,
  },
}]]

-- nvim-config's vim.diagnostic.config() (features/diagnostics.lua:143-160), virtual_text off as the plugin set it
local DIAG_CONFIG = [[{
  virtual_text = false,
  underline = true,
  update_in_insert = false,
  severity_sort = true,
  signs = {
    text = { [1] = "E", [2] = "W", [3] = "I", [4] = "H" },
    numhl = { [1] = "ErrorMsg", [2] = "WarningMsg" },
  },
}]]

-- The child ------------------------------------------------------------------------------------------------------

if vim.env.NB_BENCH_SIDE then
  local side, dir = vim.env.NB_BENCH_SIDE, vim.env.NB_BENCH_DIR
  vim.o.swapfile = false
  vim.o.termguicolors = true -- colours as the highlight groups define them, not the 256-colour palette
  vim.o.cursorline = true
  vim.o.number = true
  vim.o.wrap = false
  vim.diagnostic.config(assert(loadstring("return " .. DIAG_CONFIG))())
  local settle = function() end
  if side == "tiny" then
    vim.opt.rtp:prepend(dir .. "/tiny-inline-diagnostic.nvim")
    require("tiny-inline-diagnostic").setup(assert(loadstring("return " .. TINY))())
    vim.diagnostic.config({ virtual_text = false })
    -- it draws a buffer only once LspAttach fired there (diagnostic.lua:31-82); its renderer draws at once
    _G.attach = function(buf) vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 0 } }) end
    settle = function()
      require("tiny-inline-diagnostic.renderer").safe_render(
        require("tiny-inline-diagnostic").config,
        vim.api.nvim_get_current_buf()
      )
    end
  elseif side == "neoblocks" then
    vim.opt.rtp:prepend(root)
    vim.cmd.runtime("plugin/neoblocks.lua")
    require("neoblocks").setup({ diagnostics = {} })
    _G.attach = function() end
  else -- "none": the floor, signs and underlines only
    _G.attach = function() end
  end
  _G.ns = vim.api.nvim_create_namespace("bench")

  -- A chunk list as drawn: each chunk's highlight resolved to its colours, neighbours that draw alike merged.
  local function resolve(chunks)
    local out = {}
    for _, ch in ipairs(chunks or {}) do
      local h = (ch[2] and ch[2] ~= "None") and vim.api.nvim_get_hl(0, { name = ch[2], link = false }) or {}
      local look = ("fg=%s bg=%s%s"):format(h.fg or "-", h.bg or "-", h.italic and " italic" or "")
      if out[#out] and out[#out][2] == look then
        out[#out][1] = out[#out][1] .. ch[1]
      elseif ch[1] ~= "" then
        out[#out + 1] = { ch[1], look }
      end
    end
    return out
  end

  -- The screen as text, a cell per entry, and the side's extmarks as they draw: where, and each chunk's colours.
  -- Cell colours from nvim__inspect_cell() don't match the highlight groups here (two cells of one chunk differ), so
  -- the colours are compared on the extmarks.
  _G.snap = function()
    settle()
    vim.cmd.redraw({ bang = true })
    local rows = {}
    for r = 0, vim.o.lines - 1 do
      local cells = {}
      for c = 0, vim.o.columns - 1 do
        cells[#cells + 1] = vim.api.nvim__inspect_cell(1, r, c)[1]
      end
      rows[#rows + 1] = table.concat(cells, "\1")
    end
    local id = vim.api.nvim_get_namespaces()[side == "tiny" and "TinyInlineDiagnostic" or "neoblocks.diagnostics"]
    local marks = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, id, 0, -1, { details = true })) do
      local d = m[4] --[[@as vim.api.keyset.extmark_details]] -- always there with `details = true`
      local lines = {}
      for _, l in ipairs(d.virt_lines or {}) do
        lines[#lines + 1] = resolve(l)
      end
      local text = resolve(d.virt_text)
      -- Marks that can't be seen are left out: off-screen ones (both sides draw past the view: tiny-inline-diagnostic
      -- one line, renderer.lua:51-52; neoblocks a screen each way), and tiny-inline-diagnostic's marks with no text,
      -- from its overflow loop running to the buffer's end (extmark_writer.lua:328)
      local seen = m[2] >= vim.fn.line("w0") - 1 and m[2] <= vim.fn.line("w$") - 1
      if seen and (#text > 0 or #lines > 0) then
        marks[#marks + 1] = vim.inspect({
          row = m[2],
          col = m[3],
          at = d.virt_text_win_col or d.virt_text_pos,
          text = text,
          lines = #lines > 0 and lines or nil,
          above = d.virt_lines_above or nil,
          priority = d.priority,
        }, { newline = " ", indent = "" })
      end
    end
    table.sort(marks)
    return { rows = rows, marks = marks }
  end

  local out = vim.env.NB_BENCH_OUT
  if not out then
    return
  end

  -- The cost: 300 lines, a diagnostic on every 4th (1, 5, 9, ...) and a second at column 10 on every 8th. Each
  -- operation runs n times from a timer, `every` ms apart (more than the plugin's 20 ms throttle, so its draws land
  -- inside), and costs the CPU time over the series divided by n.
  local uv = vim.uv
  local function cpu()
    local r = assert(uv.getrusage())
    return (r.utime.sec + r.stime.sec) * 1e6 + r.utime.usec + r.stime.usec
  end
  local lines, diags = {}, {}
  for i = 1, 300 do
    lines[i] = ("local value_%d = compute(%d, options)"):format(i, i)
  end
  local function diagnostics(tag)
    local list = {}
    for l = 0, 299, 4 do
      list[#list + 1] =
        { lnum = l, col = 0, end_col = 5, severity = 1 + l % 3, message = tag .. " at " .. l, source = "bench" }
      if l % 8 == 0 then
        list[#list + 1] = { lnum = l, col = 10, end_col = 15, severity = 2, message = "second\nline", source = "bench" }
      end
    end
    return list
  end
  diags = diagnostics("first")

  local ops = {} ---@type table<string, number>
  local function series(name, n, every, step, after)
    local i, start = 0, cpu()
    local timer = assert(uv.new_timer())
    timer:start(
      every,
      every,
      vim.schedule_wrap(function()
        i = i + 1
        if i <= n then
          return step(i)
        end
        timer:stop()
        timer:close()
        ops[name] = (cpu() - start) / n
        after()
      end)
    )
  end
  local function keys(k) vim.api.nvim_input(k) end
  local function at(line, col) vim.api.nvim_win_set_cursor(0, { line, col or 0 }) end
  local popup ---@type integer?

  local steps = {
    function(next)
      at(2)
      series("j/k off diagnostics", 200, 30, function(i) keys(i % 2 == 1 and "j" or "k") end, next)
    end,
    function(next)
      at(4)
      series("j/k onto one", 200, 30, function(i) keys(i % 2 == 1 and "j" or "k") end, next)
    end,
    function(next)
      at(9, 2)
      series("10l/10h along one", 200, 30, function(i) keys(i % 2 == 1 and "10l" or "10h") end, next)
    end,
    function(next)
      at(2)
      series(
        "diagnostics update",
        100,
        30,
        function(i) vim.diagnostic.set(_G.ns, 0, diagnostics("update " .. i)) end,
        next
      )
    end,
    function(next)
      -- a which-key-like popup that changes size: WinResized for the popup only
      local buf = vim.api.nvim_create_buf(false, true)
      popup = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 20, col = 10, width = 30, height = 5 })
      series(
        "popup resize",
        200,
        30,
        function(i) vim.api.nvim_win_set_config(popup, { height = 5 + i % 2 }) end,
        function()
          vim.api.nvim_win_close(popup, true)
          next()
        end
      )
    end,
    function(next)
      at(1)
      vim.cmd.normal({ "gg", bang = true })
      series("scroll ^E/^Y", 200, 30, function(i) keys(i % 2 == 1 and "<C-e>" or "<C-y>") end, next)
    end,
  }
  local function go(i)
    if i > #steps then
      vim.fn.writefile({ vim.json.encode({ ops = ops, line = vim.fn.line(".") }) }, out)
      return
    end
    steps[i](function()
      vim.defer_fn(function() go(i + 1) end, 100)
    end)
  end
  vim.api.nvim_create_autocmd("UIEnter", {
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      _G.attach(0)
      vim.diagnostic.set(_G.ns, 0, diags)
      vim.defer_fn(function() go(1) end, 500)
    end,
  })
  return
end

-- The parent -----------------------------------------------------------------------------------------------------

local dir = vim.fs.normalize(arg[1] or "~/.local/share/nvim/site/pack/core/opt")
local rounds = tonumber(arg[2]) or 5
local only = arg[3]
assert(vim.uv.fs_stat(dir .. "/tiny-inline-diagnostic.nvim"), "tiny-inline-diagnostic.nvim not found in " .. dir)
vim.o.columns, vim.o.lines = 110, 40

---@class BenchChild
---@field lua fun(code: string, ...): any
---@field stop fun()

--- A child Neovim with a UI, 100x30, running one side.
---@param side "tiny"|"neoblocks"
---@param env? table<string, string>
---@return BenchChild
local function start(side, env)
  local sock = vim.fn.tempname() .. ".sock"
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 100, height = 30 })
  local job = vim.fn.jobstart(
    { vim.v.progpath, "--clean", "-u", root .. "/bench/diagnostics.lua", "--listen", sock },
    { term = true, env = vim.tbl_extend("force", { NB_BENCH_SIDE = side, NB_BENCH_DIR = dir }, env or {}) }
  )
  local ch ---@type integer?
  vim.wait(10000, function()
    if vim.uv.fs_stat(sock) then
      ch = vim.fn.sockconnect("pipe", sock, { rpc = true })
    end
    return ch ~= nil and ch > 0
  end, 20)
  assert(ch and ch > 0, side .. ": the child didn't listen on " .. sock)
  -- RPC is served while the child still starts (its 'background' detection waits), before init has run
  local ready = vim.wait(10000, function() return vim.rpcrequest(ch, "nvim_get_vvar", "vim_did_enter") == 1 end, 20)
  assert(ready, side .. ": the child didn't start")
  return {
    lua = function(code, ...) return vim.rpcrequest(ch, "nvim_exec_lua", code, { ... }) end,
    stop = function()
      vim.fn.jobstop(job)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end,
  }
end

-- The buffer: code-like lines, 8 of them long enough to reach the window's right side, line 33 wider than the window
local LINES = {}
for i = 1, 40 do
  LINES[i] = ("local value_%d = compute(%d, options)"):format(i, i)
end
LINES[20] = "local message = string.format('%s: %s', name, value) .. ' and then a lot more text that runs on and on'"
LINES[33] = ("x"):rep(30) .. " = " .. ("y"):rep(150)

local function related(msg, line)
  return {
    message = msg,
    location = { uri = "file:///tmp/other.py", range = { start = { line = line, character = 0 } } },
  }
end

-- vim.diagnostic.set() lists, 0-based lines
local DIAGS = {
  {
    lnum = 2,
    col = 6,
    end_col = 13,
    severity = 1,
    message = "Undefined global `value_3`.",
    source = "lua_ls",
    code = "undefined-global",
  },
  { lnum = 2, col = 0, end_col = 5, severity = 2, message = "Unused local.", source = "lua_ls", code = "unused-local" },
  {
    lnum = 6,
    col = 16,
    end_col = 23,
    severity = 1,
    source = "pyrefly",
    code = "bad-argument-type",
    message = "Argument `int` is not assignable to parameter `options`\n  expected: `str`\n  found: `int`",
    user_data = {
      lsp = {
        relatedInformation = {
          related("Parameter declared here", 11),
          related("Called from here", 41),
          related("", 3),
          related("A fourth", 4),
        },
      },
    },
  },
  { lnum = 6, col = 0, end_col = 5, severity = 3, message = "Consider a constant.", source = "pyrefly" },
  { lnum = 11, col = 0, end_col = 5, severity = 2, message = "w", source = "lint" },
  { lnum = 11, col = 6, end_col = 9, severity = 4, message = "h", source = "lint" },
  { lnum = 11, col = 10, end_col = 12, severity = 1, message = "e", source = "lint", code = 42 },
  { lnum = 11, col = 13, end_col = 14, severity = 4, message = "h2", source = "lint" },
  {
    lnum = 19,
    col = 6,
    end_col = 13,
    severity = 1,
    message = "This line is long, so the message goes under it.",
    source = "lua_ls",
  },
  {
    lnum = 24,
    col = 10,
    end_col = 10,
    severity = 2,
    message = "Zero-width, at the end of a token.",
    source = "lua_ls",
  },
  { lnum = 32, col = 0, end_col = 3, severity = 2, message = "On a line wider than the window.", source = "lua_ls" },
  {
    lnum = 38,
    col = 0,
    end_col = 5,
    severity = 1,
    message = "Near the end:\nsecond\nthird\nfourth",
    source = "lua_ls",
  },
}

-- Each scenario: options before the buffer is filled, then steps; the screen is read after each step.
local SCENARIOS = {
  {
    name = "cursor moves",
    steps = {
      { "a line without diagnostics: the others' pills", "vim.api.nvim_win_set_cursor(0, { 1, 0 })" },
      { "on the warning only", "vim.api.nvim_win_set_cursor(0, { 3, 1 })" },
      { "on the error only", "vim.api.nvim_win_set_cursor(0, { 3, 8 })" },
      { "on neither: both", "vim.api.nvim_win_set_cursor(0, { 3, 20 })" },
      { "a multiline message with related information", "vim.api.nvim_win_set_cursor(0, { 7, 18 })" },
      { "the info on that line", "vim.api.nvim_win_set_cursor(0, { 7, 1 })" },
      { "four on a line, none under the cursor", "vim.api.nvim_win_set_cursor(0, { 12, 30 })" },
      { "a long line: under it", "vim.api.nvim_win_set_cursor(0, { 20, 0 })" },
      { "a zero-width range, cursor before it", "vim.api.nvim_win_set_cursor(0, { 25, 9 })" },
      { "a line wider than the window", "vim.api.nvim_win_set_cursor(0, { 33, 0 })" },
      { "near the end: rows past the last line", "vim.api.nvim_win_set_cursor(0, { 39, 0 })" },
      { "the last line, pills", "vim.api.nvim_win_set_cursor(0, { 40, 0 })" },
      { "scrolled sideways", "vim.api.nvim_win_set_cursor(0, { 33, 120 })" },
    },
  },
  {
    name = "no cursorline",
    options = "vim.o.cursorline = false",
    steps = {
      { "on the warning", "vim.api.nvim_win_set_cursor(0, { 3, 1 })" },
      { "a multiline message", "vim.api.nvim_win_set_cursor(0, { 7, 18 })" },
    },
  },
  {
    name = "wrap",
    options = "vim.o.wrap = true",
    steps = {
      { "pills", "vim.api.nvim_win_set_cursor(0, { 1, 0 })" },
      { "the line under a soft-wrapped one", "vim.api.nvim_win_set_cursor(0, { 32, 0 })" },
      { "a soft-wrapped line itself", "vim.api.nvim_win_set_cursor(0, { 33, 0 })" },
      { "a long line, under it", "vim.api.nvim_win_set_cursor(0, { 20, 0 })" },
    },
  },
  {
    name = "modes and the float",
    steps = {
      { "on the error", "vim.api.nvim_win_set_cursor(0, { 3, 8 })" },
      { "Insert mode hides them", "vim.api.nvim_input('i')" },
      { "back in Normal mode", "vim.api.nvim_input('<Esc>')" },
      { "Visual mode hides them", "vim.api.nvim_input('v')" },
      { "back again", "vim.api.nvim_input('<Esc>')" },
      { "the float hides them", "vim.diagnostic.open_float()" },
      { "closing it brings them back", "vim.cmd.fclose()" },
    },
  },
}

-- Fills the child's buffer and sets the diagnostics.
---@param c BenchChild
---@param options? string
local function fill(c, options)
  c.lua(options or "")
  c.lua(
    [[
    local lines, diags = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    _G.attach(0)
    vim.diagnostic.set(_G.ns, 0, diags)
  ]],
    LINES,
    DIAGS
  )
end

--- What differs between two snapshots: the screen rows whose text differs, then the extmarks only one side has.
local function diff(a, b)
  local out = {}
  for r = 1, math.max(#a.rows, #b.rows) do
    if a.rows[r] ~= b.rows[r] then
      local ca, cb = vim.split(a.rows[r] or "", "\1"), vim.split(b.rows[r] or "", "\1")
      local col = 0
      while ca[col + 1] == cb[col + 1] do
        col = col + 1
      end
      out[#out + 1] = ("  row %d, from col %d\n    tiny:      %s\n    neoblocks: %s"):format(
        r - 1,
        col,
        table.concat(ca),
        table.concat(cb)
      )
    end
  end
  local in_b = {}
  for _, m in ipairs(b.marks) do
    in_b[m] = (in_b[m] or 0) + 1
  end
  for _, m in ipairs(a.marks) do
    if (in_b[m] or 0) > 0 then
      in_b[m] = in_b[m] - 1
    else
      out[#out + 1] = "  only tiny:      " .. m
    end
  end
  for m, n in pairs(in_b) do
    for _ = 1, n do
      out[#out + 1] = "  only neoblocks: " .. m
    end
  end
  return out
end

local function look()
  local failed = 0
  for _, sc in ipairs(SCENARIOS) do
    local shots = {} ---@type table<string, string[][]>
    for _, side in ipairs({ "tiny", "neoblocks" }) do
      local c = start(side)
      fill(c, sc.options)
      shots[side] = {}
      for i, step in ipairs(sc.steps) do
        c.lua(step[2])
        c.lua("") -- a round trip, so the step's autocmds and scheduled work have run
        shots[side][i] = c.lua("return _G.snap()")
      end
      c.stop()
    end
    for i, step in ipairs(sc.steps) do
      local d = diff(shots.tiny[i], shots.neoblocks[i])
      io.write(("%s %s: %s\n"):format(#d == 0 and "  same" or "  DIFF", sc.name, step[1]))
      if #d > 0 then
        failed = failed + 1
        io.write(table.concat(d, "\n"), "\n")
      end
    end
  end
  return failed
end

local OPS =
  { "j/k off diagnostics", "j/k onto one", "10l/10h along one", "diagnostics update", "popup resize", "scroll ^E/^Y" }

local function median(t)
  local s = vim.deepcopy(t)
  table.sort(s)
  local n = #s
  return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
end

local function cost()
  local sides = { "tiny", "neoblocks", "none" }
  ---@alias BenchCosts table<string, table<string, number[]>> side -> operation -> µs per run
  local all, per_round = {}, {} ---@type BenchCosts, BenchCosts[]
  for round = 1, rounds do
    per_round[round] = {}
    for _ = 1, 3 do
      for _, side in ipairs(sides) do
        local out = vim.fn.tempname() .. ".json"
        local c = start(side, { NB_BENCH_OUT = out })
        local done = vim.wait(120000, function() return vim.uv.fs_stat(out) ~= nil end, 50)
        c.stop()
        assert(done, side .. ": no result")
        local r = vim.json.decode(table.concat(vim.fn.readfile(out), "\n"))
        for op, us in pairs(r.ops) do
          for _, t in ipairs({ all, per_round[round] }) do
            t[side] = t[side] or {}
            t[side][op] = t[side][op] or {}
            table.insert(t[side][op], us)
          end
        end
      end
    end
    io.write(("round %d done\n"):format(round))
  end
  io.write(("\nNeovim %s, %d rounds x 3 runs, median µs per operation (CPU)\n\n"):format(vim.version(), rounds))
  io.write("| µs per op           |      tiny | neoblocks |      none | rounds neoblocks < tiny |\n")
  io.write("|---------------------|-----------|-----------|-----------|-------------------------|\n")
  for _, op in ipairs(OPS) do
    local agree = 0
    for round = 1, rounds do
      if median(per_round[round].neoblocks[op]) < median(per_round[round].tiny[op]) then
        agree = agree + 1
      end
    end
    io.write(
      ("| %-19s |%10.1f |%10.1f |%10.1f | %d of %d |\n"):format(
        op,
        median(all.tiny[op]),
        median(all.neoblocks[op]),
        median(all.none[op]),
        agree,
        rounds
      )
    )
  end
end

if not only or only == "look" then
  io.write("The look, cell by cell:\n")
  local failed = look()
  if failed > 0 then
    io.write(("%d steps differ\n"):format(failed))
    os.exit(1)
  end
end

if not only or only == "cost" then
  io.write("\nThe cost:\n")
  cost()
end
