-- The statusline against lualine.nvim, each drawing nvim-config's statusline (nvim/lua/plugins/lualine.lua): the
-- same components, colours and refresh events. Each runs in its own `nvim --clean`, in a scratch git repo with a
-- changed file, diagnostics and a search.
--
--   nvim --clean --headless -l bench/statusline.lua [path to lualine.nvim]
--
-- lualine defaults to ~/.local/share/nvim/lazy/lualine.nvim. Times are µs per operation, the median of 7 rounds:
-- - rebuild: lualine.refresh({ force = true }) / Neoblocks.statusline.refresh(): what an event costs;
-- - of which config: the config's own functions in it (file path, conds), the same for both;
-- - redraw: :redrawstatus, Neovim drawing the stored line;
-- - j: a cursor move (normal! j, CursorMoved, redraw) with no search highlighted;
-- - search on: the same with a search highlighted ([13/56] drawn), where the config refreshes lualine on each move;
-- - j, search on, 40 ms apart: CPU per move at key-repeat rate, the moves made from a timer in the event loop, so
--   lualine's 16 ms queue and this module's cap run as they do in use;
-- - scroll frame, search on: CPU per move of a scroll animation (20 moves 10 ms apart, as snacks' scroll) in a
--   50 000-line file with 500 matches, where searchcount() is most of the cost.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local scratch = vim.fs.normalize("~/.cache/neoblocks/statusline/bench")

if arg[1] ~= "--impl" then
  local lualine = arg[1] or vim.fs.normalize("~/.local/share/nvim/lazy/lualine.nvim")
  assert(vim.uv.fs_stat(lualine), "lualine.nvim not found at " .. lualine)
  -- a repo with a branch and a changed file, as lualine's branch and diff read them
  vim.fn.delete(scratch, "rf")
  vim.fn.mkdir(scratch .. "/lua/proj", "p")
  local lines = {}
  for i = 1, 400 do
    lines[i] = ("local value_%d = %d -- needle %d"):format(i, i, i % 7)
  end
  vim.fn.writefile(lines, scratch .. "/lua/proj/file.lua")
  local function git(...)
    local out = vim.system({ "git", "-C", scratch, ... }, { text = true }):wait()
    assert(out.code == 0, out.stderr)
  end
  git("init", "-q", "-b", "feat/bench")
  git("-c", "user.name=bench", "-c", "user.email=bench@localhost", "add", ".")
  git("-c", "user.name=bench", "-c", "user.email=bench@localhost", "commit", "-qm", "init")
  lines[10], lines[20] = "changed", "changed too"
  table.insert(lines, 30, "added")
  table.remove(lines, 50)
  vim.fn.writefile(lines, scratch .. "/lua/proj/file.lua")
  local big = {}
  for i = 1, 50000 do
    big[i] = ("local value_%d = %d%s"):format(i, i, i % 100 == 0 and " -- needle 3" or "")
  end
  vim.fn.writefile(big, scratch .. "/lua/proj/big.lua")

  local results = {}
  for _, impl in ipairs({ "lualine", "neoblocks" }) do
    local out = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", root .. "/bench/statusline.lua", "--impl", impl, lualine })
      :wait()
    local json = (out.stdout or ""):match("RESULT(.-)\n") or (out.stderr or ""):match("RESULT(.-)\n")
    assert(json, impl .. " gave no result:\n" .. (out.stdout or "") .. (out.stderr or ""))
    results[impl] = vim.json.decode(json)
  end
  local rows = {
    { "rebuild", "rebuild" },
    { "config", "of which config" },
    { "redraw", "redraw" },
    { "j", "j" },
    { "rebuild_search", "rebuild, search on" },
    { "redraw_search", "redraw, search on" },
    { "j_search", "j, search on, 40 ms apart" },
    { "scroll_search", "scroll frame, search on" },
  }
  io.write(("Neovim %s, lualine.nvim at %s\n\n"):format(tostring(vim.version()), lualine))
  io.write(
    "| µs per op                 | lualine | neoblocks | ratio |\n"
      .. "|---------------------------|--------:|----------:|------:|\n"
  )
  for _, r in ipairs(rows) do
    local l, n = results.lualine[r[1]], results.neoblocks[r[1]]
    io.write(("| %-25s | %7.1f | %9.1f | %4.1fx |\n"):format(r[2], l, n, l / n))
  end
  io.write(
    ("\nsearchcount() calls per 20-frame scroll: lualine %d, neoblocks %d\n"):format(
      results.lualine.scroll_counts,
      results.neoblocks.scroll_counts
    )
  )
  io.write("\nThe line each draws:\n")
  io.write(
    ("lualine:   %s\nneoblocks: %s\n"):format(vim.inspect(results.lualine.line), vim.inspect(results.neoblocks.line))
  )
  if vim.env.BENCH_STL then
    io.write(("\nstored:\nlualine:   %s\nneoblocks: %s\n"):format(results.lualine.stl, results.neoblocks.stl))
  end
  io.write(("same text: %s\n"):format(tostring(results.lualine.line == results.neoblocks.line)))
  return
end

-- In the child: one implementation --------------------------------------------------------------------------------

local impl, lualine_dir = arg[2], arg[3]
vim.o.hlsearch = true
vim.cmd.cd(scratch)
vim.cmd.edit(scratch .. "/lua/proj/file.lua")
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_create_namespace("bench")
local function d(lnum, severity) return { lnum = lnum, col = 0, message = "m", severity = severity } end
vim.diagnostic.set(ns, buf, { d(1, 1), d(2, 1), d(3, 2), d(4, 2), d(5, 2), d(6, 3) })
vim.fn.setreg("/", "needle 3")
-- what gitsigns would hold for the change above; the user runs gitsigns either way (nvim-config plugins/git.lua)
vim.b.gitsigns_status_dict = { added = 1, changed = 2, removed = 1, head = "feat/bench" }

-- The config's own pieces, the same for both (plugins/lualine.lua:1-260).
local colors = {
  fg = "#abb2bf",
  red = "#e06c75",
  yellow = "#e5c07b",
  green = "#98c379",
  cyan = "#56b6c2",
  blue = "#61afef",
  magenta = "#c678dd",
  orange = "#d19a66",
  violet = "#a9a1e1",
}
local conditions = {
  buffer_not_empty = function() return vim.fn.empty(vim.fn.expand("%:t")) ~= 1 end,
  -- the config's is > 80; a headless window is 80 wide whatever 'columns' says, and the diff should draw
  hide_in_width = function() return vim.fn.winwidth(0) > 60 end,
  check_git_workspace = function()
    local filepath = vim.fn.expand("%:p:h")
    local gitdir = vim.fn.finddir(".git", filepath .. ";")
    return gitdir ~= "" and #gitdir > 0 and #gitdir < #filepath
  end,
}
vim.api.nvim_set_hl(0, "LualineNormal", { fg = colors.fg })
vim.api.nvim_set_hl(0, "LualineProjectRoot", { fg = colors.magenta, bold = true })
vim.api.nvim_set_hl(0, "LualinePath", { fg = colors.fg })
vim.api.nvim_set_hl(0, "LualineFilename", { fg = colors.blue, bold = true })
local root_cache = {}
local function project_root()
  local dir = vim.fn.expand("%:p:h")
  if not root_cache[dir] then
    local top = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel")[1]
    root_cache[dir] = (top and top ~= "" and not top:match("^fatal")) and top or vim.fn.getcwd()
  end
  return root_cache[dir]
end
local function filepath()
  if vim.fn.bufname("%") == "" then
    return ""
  end
  local full, proj = vim.fn.expand("%:p"), project_root()
  local budget = math.floor(vim.fn.winwidth(0) * 0.4)
  local rel = full:gsub("^" .. vim.pesc(proj) .. "/?", "")
  local parts = vim.split(rel, "/", { trimempty = true })
  local name, file = vim.fn.fnamemodify(proj, ":t"), parts[#parts] or ""
  local mid = table.concat(vim.list_slice(parts, 1, #parts - 1), "/")
  local function build(p, m, f)
    local out = "%#LualineProjectRoot#" .. p .. "%#LualineNormal#"
    if m ~= "" then
      out = out .. "/%#LualinePath#" .. m .. "%#LualineNormal#"
    end
    return out .. "/%#LualineFilename#" .. f .. "%#LualineNormal#"
  end
  local function width(s) return vim.fn.strdisplaywidth((s:gsub("%%#.-#", ""))) end
  local display = build(name, mid, file)
  if width(display) > budget then
    display = "%#LualineFilename#" .. file .. "%#LualineNormal#"
  end
  return display
end
local mode_colors = {
  n = colors.fg,
  i = colors.green,
  v = colors.blue,
  V = colors.blue,
  c = colors.magenta,
  s = colors.orange,
  S = colors.orange,
  R = colors.violet,
  t = colors.red,
}
local function macro()
  local reg = vim.fn.reg_recording()
  return reg == "" and "" or " @" .. reg
end
local location = "%3l:%-2{charcol('.')}"
local progress =
  "%{line('.') == 1 ? 'Top' : line('.') == line('$') ? 'Bot' : printf('%2d%%', line('.') * 100 / line('$'))}"
local lsp, formatters, linters, tools = "lua_ls", "stylua", "selene", "2"
local events = {
  "WinEnter",
  "BufEnter",
  "BufWritePost",
  "SessionLoadPost",
  "FileChangedShellPost",
  "VimResized",
  "Filetype",
  "ModeChanged",
  "DiagnosticChanged",
}

local rebuild ---@type fun()
local on_move ---@type fun()?

if impl == "lualine" then
  vim.opt.rtp:prepend(lualine_dir)
  local lualine = require("lualine")
  local c, x = {}, {}
  c[#c + 1] = {
    function() return "" end,
    color = function() return { fg = mode_colors[vim.fn.mode()] or colors.red } end,
    padding = { right = 1 },
  }
  c[#c + 1] = { filepath, cond = conditions.buffer_not_empty }
  c[#c + 1] = { function() return location end }
  c[#c + 1] = { function() return progress end, color = { fg = colors.fg, gui = "bold" } }
  c[#c + 1] = {
    "diagnostics",
    sources = { "nvim_diagnostic" },
    symbols = { error = " ", warn = " ", info = " " },
    diagnostics_color = { error = { fg = colors.red }, warn = { fg = colors.yellow }, info = { fg = colors.cyan } },
  }
  c[#c + 1] = { function() return "%=" end }
  c[#c + 1] = { function() return lsp end, icon = "󱍔 LSP:", color = { fg = colors.yellow, gui = "bold" } }
  c[#c + 1] = { function() return formatters end, icon = "󰁨 ", color = { fg = colors.magenta, gui = "bold" } }
  c[#c + 1] = { function() return linters end, icon = " ", color = { fg = colors.orange, gui = "bold" } }
  c[#c + 1] = {
    function() return tools end,
    icon = "󰖷",
    color = { fg = colors.orange, gui = "bold" },
    on_click = function() end,
  }
  x[#x + 1] =
    { "branch", icon = "", color = { fg = colors.cyan, gui = "bold" }, cond = conditions.check_git_workspace }
  x[#x + 1] = {
    "diff",
    symbols = { added = "󰐖 ", modified = "󰦓 ", removed = "󰍵 " },
    diff_color = { added = { fg = colors.green }, modified = { fg = colors.orange }, removed = { fg = colors.red } },
    cond = conditions.hide_in_width,
  }
  x[#x + 1] = {
    function() return (vim.ui.progress_status():gsub("%%", "%%%%")) end,
    icon = "󰔟",
    color = { fg = colors.violet },
  }
  x[#x + 1] = { "searchcount", color = { fg = colors.fg } }
  x[#x + 1] = { macro, color = { fg = colors.yellow, gui = "bold" } }
  x[#x + 1] = { function() return "%S" end, color = { fg = colors.fg } }
  local empty = { lualine_a = {}, lualine_b = {}, lualine_c = {}, lualine_x = {}, lualine_y = {}, lualine_z = {} }
  lualine.setup({
    options = {
      component_separators = "",
      section_separators = "",
      globalstatus = true,
      refresh = { events = events },
      theme = { normal = { c = { fg = colors.fg } }, inactive = { c = { fg = colors.fg } } },
    },
    sections = { lualine_a = {}, lualine_b = {}, lualine_y = {}, lualine_z = {}, lualine_c = c, lualine_x = x },
    inactive_sections = empty,
  })
  rebuild = function() lualine.refresh({ scope = "window", place = { "statusline" }, force = true }) end
  -- the config's handler (plugins/lualine.lua:445-451): it queues the refresh for lualine's 16 ms timer
  on_move = function()
    if vim.v.hlsearch == 1 then
      lualine.refresh({ place = { "statusline" } })
    end
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { callback = function() on_move() end })
  -- lualine's diff runs `git diff` in the background, and its first draw is on a timer
  vim.api.nvim_exec_autocmds("BufEnter", {})
  vim.wait(1500, function()
    rebuild()
    return vim.o.statusline:find("󰐖", 1, true) ~= nil
  end, 50)
else
  vim.opt.rtp:prepend(root)
  require("neoblocks").setup({
    statusline = {
      color = { fg = colors.fg },
      events = vim.list_extend(vim.deepcopy(events), { "LspAttach", "LspDetach", "WinResized" }),
      left = {
        {
          function() return "" end,
          color = require("neoblocks.statusline").mode_color(
            vim.tbl_map(function(fg) return { fg = fg } end, mode_colors),
            { fg = colors.red }
          ),
          padding = { right = 1 },
        },
        { filepath, cond = conditions.buffer_not_empty },
        { function() return location end },
        { function() return progress end, color = { fg = colors.fg, bold = true } },
        {
          "diagnostics",
          symbols = { error = " ", warn = " ", info = " " },
          diagnostics_color = {
            error = { fg = colors.red },
            warn = { fg = colors.yellow },
            info = { fg = colors.cyan },
          },
        },
        "%=",
        { function() return lsp end, icon = "󱍔 LSP:", color = { fg = colors.yellow, bold = true } },
        { function() return formatters end, icon = "󰁨 ", color = { fg = colors.magenta, bold = true } },
        { function() return linters end, icon = " ", color = { fg = colors.orange, bold = true } },
        {
          function() return tools end,
          icon = "󰖷",
          color = { fg = colors.orange, bold = true },
          on_click = function() end,
        },
      },
      right = {
        {
          "branch",
          icon = "",
          color = { fg = colors.cyan, bold = true },
          cond = conditions.check_git_workspace,
        },
        {
          "diff",
          symbols = { added = "󰐖 ", modified = "󰦓 ", removed = "󰍵 " },
          diff_color = {
            added = { fg = colors.green },
            modified = { fg = colors.orange },
            removed = { fg = colors.red },
          },
          cond = conditions.hide_in_width,
        },
        { "progress_status", icon = "󰔟", color = { fg = colors.violet } },
        { "searchcount", color = { fg = colors.fg } },
        { "recording", icon = "", color = { fg = colors.yellow, bold = true } },
        { "%S", color = { fg = colors.fg } },
      },
    },
  })
  rebuild = function() Neoblocks.statusline.refresh() end
end

--- Median µs per call of fn over 7 rounds of n calls.
local function time(n, fn)
  local rounds = {}
  for r = 1, 7 do
    local t = vim.uv.hrtime()
    for i = 1, n do
      fn(i)
    end
    rounds[r] = (vim.uv.hrtime() - t) / n / 1e3
  end
  table.sort(rounds)
  return rounds[4]
end

local function move(i)
  vim.cmd(i % 2 == 0 and "normal! j" or "normal! k")
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.cmd("redrawstatus")
end

local function cpu_ms()
  local r = assert(vim.uv.getrusage())
  return (r.utime.sec + r.stime.sec) * 1e3 + (r.utime.usec + r.stime.usec) / 1e3
end

--- Median CPU µs per move over 7 rounds of `n` moves `step` ms apart, each made from a timer in the event loop, as
--- typed keys and scroll animations are, and followed by what the main loop does after one: CursorMoved, a redraw
--- and SafeState. The rounds include what each implementation's timers cost while it runs, and 50 ms after.
---@return number us, integer counts the median, and searchcount() calls in its round
local function moves(n, step, down)
  local searchcount, counts = vim.fn.searchcount, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.searchcount = function(...)
    counts = counts + 1
    return searchcount(...)
  end
  local rounds = {}
  for r = 1, 7 do
    counts = 0
    local done, i, t0 = false, 0, cpu_ms()
    local timer = assert(vim.uv.new_timer())
    timer:start(
      step,
      step,
      vim.schedule_wrap(function()
        if i >= n then
          return
        end
        i = i + 1
        move(down and 2 or i)
        vim.api.nvim_exec_autocmds("SafeState", {})
        if i == n then
          timer:stop()
          timer:close()
          vim.defer_fn(function() done = true end, 50)
        end
      end)
    )
    vim.wait(10000, function() return done end)
    rounds[r] = { (cpu_ms() - t0) * 1e3 / n, counts }
  end
  vim.fn.searchcount = searchcount
  table.sort(rounds, function(a, b) return a[1] < b[1] end)
  return rounds[4][1], rounds[4][2]
end

vim.api.nvim_win_set_cursor(0, { 100, 0 })
local result = {}
-- no search highlighted: the usual state
vim.v.hlsearch = 0
rebuild()
result.rebuild = time(500, rebuild)
-- the part of a rebuild that is the config's own functions, the same in both
result.config = time(500, function()
  filepath()
  conditions.buffer_not_empty()
  conditions.check_git_workspace()
  conditions.hide_in_width()
end)
result.redraw = time(5000, function() vim.cmd("redrawstatus") end)
result.j = time(2000, move)
-- a search highlighted: [13/56] in the line
vim.v.hlsearch = 1
rebuild()
result.rebuild_search = time(500, rebuild)
result.redraw_search = time(5000, function() vim.cmd("redrawstatus") end)
result.j_search = moves(20, 40)
rebuild()
result.stl = vim.o.statusline
result.line = vim.api.nvim_eval_statusline(vim.o.statusline, { maxwidth = 150 }).str
-- a scroll in a large file
vim.cmd.edit(scratch .. "/lua/proj/big.lua")
vim.wait(1500)
vim.api.nvim_win_set_cursor(0, { 25000, 0 })
vim.v.hlsearch = 1
rebuild()
result.scroll_search, result.scroll_counts = moves(20, 10, true)
-- selene: allow(incorrect_standard_library_use)
io.stdout:write("RESULT", vim.json.encode(result), "\n")
