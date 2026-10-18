-- The messages module against noice.nvim, each set up as nvim-config had them: noice with its bottom_search,
-- command_palette and long_message_to_split presets, LSP progress off (nvim-config 07d2b9a~1:nvim/lua/plugins/noice.lua),
-- and this module on ui2 with nvim-config's targets; both toast through snacks.notifier. Plain ui2 runs too, as the
-- floor. Only what runs per keystroke or per message is measured. Each side runs in its own `nvim --clean` with a UI
-- (a terminal, 120x36), sides interleaved, 3 runs per side per round.
--
--   nvim --clean --headless -l bench/messages.lua [folder with noice.nvim, nui.nvim and snacks.nvim] [rounds]
--
-- The folder defaults to ~/.local/share/nvim/lazy; rounds to 5. Keys and messages come from a timer in the child
-- (nvim_input, nvim_echo), and the cost is the child's CPU time (getrusage) over them divided by their number: what
-- Neovim, the plugin and the drawing take for each, idle time left out. Median µs per operation:
-- - cmdline key: a character typed in the ':' popup (noice: its popup; here: ui2 drawing it, the window moved);
-- - normal key: j and k in a 200-line buffer, 'showcmd' on (noice: %S in the statusline; here: showcmd());
-- - 2j: a count and its motion, typed as one input (the count is drawn while it waits only on a real keyboard);
-- - message: a one-line message from a timer, 60 ms apart, each its own toast;
-- - long message: a 40-line message from a timer, 150 ms apart, each to the split.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

if not vim.env.NB_BENCH_SIDE then
  local lazy = vim.fs.normalize(arg[1] or "~/.local/share/nvim/lazy")
  local rounds = tonumber(arg[2]) or 5
  for _, p in ipairs({ "noice.nvim", "nui.nvim", "snacks.nvim" }) do
    assert(vim.uv.fs_stat(lazy .. "/" .. p), p .. " not found in " .. lazy)
  end
  vim.o.columns, vim.o.lines = 120, 40
  local sides = { "noice", "neoblocks", "ui2" }
  local results = {} ---@type table<string, table<string, number[]>>
  local checks = {} ---@type table<string, table<string, any>>
  local function run(side)
    local out = vim.fn.tempname() .. ".json"
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 120, height = 36 })
    local job = vim.fn.jobstart({
      vim.v.progpath,
      "--clean",
      "-u",
      root .. "/bench/messages.lua",
    }, { term = true, env = { NB_BENCH_SIDE = side, NB_BENCH_LAZY = lazy, NB_BENCH_OUT = out } })
    vim.wait(60000, function() return vim.uv.fs_stat(out) ~= nil end, 50)
    vim.wait(50)
    local screen = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.fn.jobstop(job)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    local ok, r = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(out), "\n")) end)
    assert(ok, side .. ": no result; its screen:\n" .. table.concat(screen, "\n"))
    return r
  end
  local per_round = {} ---@type table<integer, table<string, table<string, number[]>>>
  for round = 1, rounds do
    per_round[round] = {}
    for _ = 1, 3 do
      for _, side in ipairs(sides) do
        local r = run(side)
        checks[side] = r.checks
        for op, us in pairs(r.ops) do
          results[side] = results[side] or {}
          results[side][op] = results[side][op] or {}
          table.insert(results[side][op], us)
          per_round[round][side] = per_round[round][side] or {}
          per_round[round][side][op] = per_round[round][side][op] or {}
          table.insert(per_round[round][side][op], us)
        end
      end
    end
    io.write(("round %d done\n"):format(round))
  end
  local function median(t)
    local s = vim.deepcopy(t)
    table.sort(s)
    local n = #s
    return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
  end
  local ops = { "cmdline key", "normal key", "2j", "message", "long message" }
  io.write(("\nNeovim %s, %d rounds x 3 runs, median µs per operation (CPU)\n\n"):format(vim.version(), rounds))
  io.write(("| %-14s |%10s |%10s |%10s | rounds neoblocks < noice |\n"):format("µs per op", unpack(sides)))
  io.write("|----------------|-----------|-----------|-----------|--------------------------|\n")
  for _, op in ipairs(ops) do
    local agree = 0
    for round = 1, rounds do
      if median(per_round[round].neoblocks[op]) < median(per_round[round].noice[op]) then
        agree = agree + 1
      end
    end
    io.write(
      ("| %-14s |%10.1f |%10.1f |%10.1f | %d of %d |\n"):format(
        op,
        median(results.noice[op]),
        median(results.neoblocks[op]),
        median(results.ui2[op]),
        agree,
        rounds
      )
    )
  end
  io.write("\nchecks (last run of each side): ", vim.inspect(checks), "\n")
  return
end

-- The child: set up one side, then run the operations from timers and write their costs to `out`.
local side, lazy = vim.env.NB_BENCH_SIDE, vim.env.NB_BENCH_LAZY
local out = assert(vim.env.NB_BENCH_OUT, "NB_BENCH_OUT unset: run bench/messages.lua, not the child")
vim.opt.rtp:prepend(lazy .. "/snacks.nvim")
vim.o.cmdheight = 0
vim.o.showcmd = true
vim.o.swapfile = false
require("snacks").setup({ notifier = { enabled = true } })
if side == "noice" then
  vim.opt.rtp:prepend(lazy .. "/nui.nvim")
  vim.opt.rtp:prepend(lazy .. "/noice.nvim")
  vim.o.showcmdloc = "statusline"
  vim.o.statusline = "%f %= %S "
  require("noice").setup({
    lsp = { progress = { enabled = false } },
    presets = { bottom_search = true, command_palette = true, long_message_to_split = true },
  })
else
  vim.opt.rtp:prepend(root)
  vim.cmd.runtime("plugin/neoblocks.lua")
  vim.o.showcmdloc = "statusline"
  require("vim._core.ui2").enable({ msg = { targets = { default = "msg", typed_cmd = "cmd" } } })
  if side == "neoblocks" then
    require("neoblocks").setup({ messages = {} })
    vim.o.statusline = "%f %= " .. Neoblocks.messages.showcmd() .. " "
  else
    vim.o.statusline = "%f %= %S "
  end
end
local lines = {}
for i = 1, 200 do
  lines[i] = ("line %d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)

local uv = vim.uv
local function cpu()
  local r = assert(uv.getrusage())
  return (r.utime.sec + r.stime.sec) * 1e6 + r.utime.usec + r.stime.usec
end

local ops, checks = {}, {}

--- Runs step(i) for i = 1..n, `every` ms apart, from a timer; then records the CPU per step under `name`.
local function series(name, n, every, step, after)
  local i, start = 0, cpu()
  local timer = assert(uv.new_timer())
  timer:start(
    every,
    every,
    vim.schedule_wrap(function()
      i = i + 1
      if i <= n then
        step(i)
        return
      end
      timer:stop()
      timer:close()
      ops[name] = (cpu() - start) / n
      after()
    end)
  )
end

local function keys(k) vim.api.nvim_input(k) end

local steps = {
  function(next)
    keys(":")
    vim.defer_fn(function()
      series("cmdline key", 200, 8, function() keys("a") end, function()
        checks.cmdline = vim.fn.getcmdline():sub(1, 5)
        keys("<Esc>")
        vim.defer_fn(next, 100)
      end)
    end, 100)
  end,
  function(next)
    series(
      "normal key",
      200,
      8,
      function(i) keys(i % 2 == 1 and "j" or "k") end,
      function() vim.defer_fn(next, 100) end
    )
  end,
  function(next)
    -- one input: while a count waits for its motion, Neovim runs no timers, so "j" can't come from a later one
    series("2j", 100, 16, function() keys("2j") end, function()
      checks.line = vim.fn.line(".")
      keys("gg")
      vim.defer_fn(next, 100)
    end)
  end,
  function(next)
    series("message", 60, 60, function(i) vim.api.nvim_echo({ { "message " .. i } }, true, {}) end, function()
      -- toasts on screen now: snacks' are notifier windows (filetype snacks_notif)
      checks.toasts = #vim.tbl_filter(
        function(w) return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "snacks_notif" end,
        vim.api.nvim_list_wins()
      )
      vim.defer_fn(next, 200)
    end)
  end,
  function(next)
    local long = {}
    for i = 1, 40 do
      long[i] = "output line " .. i
    end
    local text = table.concat(long, "\n")
    series("long message", 20, 150, function() vim.api.nvim_echo({ { text } }, true, {}) end, function()
      local splits = vim.tbl_filter(
        function(w) return vim.api.nvim_win_get_config(w).relative == "" end,
        vim.api.nvim_tabpage_list_wins(0)
      )
      checks.splits = #splits
      vim.defer_fn(next, 100)
    end)
  end,
}

local function go(i)
  if i > #steps then
    vim.fn.writefile({ vim.json.encode({ ops = ops, checks = checks }) }, out)
    return
  end
  steps[i](function() go(i + 1) end)
end

vim.api.nvim_create_autocmd("UIEnter", {
  once = true,
  callback = function()
    vim.defer_fn(function() go(1) end, 500)
  end,
})
