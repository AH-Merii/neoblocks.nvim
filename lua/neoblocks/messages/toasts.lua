-- noice-like message routing on top of ui2 (:h ui2). Messages become snacks.notifier toasts (errors stay
-- until dismissed, except routine search and navigation ones), output taller than a toast opens in a split
-- below (noice's long_message_to_split), and progress (a statusline shows it) and the kinds noice never showed
-- (undo, quickfix, ...) are dropped. Without snacks.notifier set up, every message stays with ui2.
-- Dialogs, search, block mode and the pager stay with ui2.
--
-- ui2 is private (vim._core), so this hooks its internals. R = $VIMRUNTIME/lua/vim/_core, nightly
-- v0.13.0-dev-1868:
-- - R/ui2.lua:159,238: the UI callback looks the handler up in ui.msg on every event, so replacing
--   ui.msg.msg_show is enough. ui.msg exists only with a UI attached (R/ui2.lua:217-219,234-235).
-- - R/ui2.lua:242-243: fast events are rescheduled, so msg_show never runs in a fast event. It can
--   still run under textlock, so nothing here opens windows or notifies before vim.schedule.
-- - R/ui2/messages.lua:466: msg_show(kind, content, replace_last, history, append, id, trigger).
-- - R/ui2/cmdline.lua:6,8,10: ui.cmd.prompt, srow and level.
-- A failing hook puts ui2's msg_show back, warns once and replays the batch through ui2.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("neoblocks.messages.toasts")

local MAX_ENTRIES = 500
-- Kinds ui2 keeps: prompts (dialog), the search line and count, cmdline clears and the wildmenu list.
local passthrough = { confirm = true, search_cmd = true, search_count = true, empty = true, wildlist = true }
-- Kinds noice never showed: it notified only "", echo, echomsg, lua_print, list_cmd, errors and warnings
-- (noice/config/routes.lua:79-96) and dropped what no route matched (noice/message/router.lua:192-205).
-- shell_cmd echoes the typed ":!cmd", which is already the toast's title. They stay in :messages.
local quiet = { undo = true, quickfix = true, completion = true, verbose = true, shell_cmd = true }
local levels =
  { emsg = "error", echoerr = "error", lua_error = "error", rpc_error = "error", shell_err = "error", wmsg = "warn" }
-- Routine errors: a search or jump that found nothing or hit an edge. Their toasts time out after snacks'
-- 3s like every noice toast did; all other errors stay until dismissed. Sources: :h <code>, in
-- $VIMRUNTIME/doc/<file>:<line> (nightly v0.13.0-dev-1868).
local routine = {} ---@type table<string, true>
for _, codes in ipairs({
  { "E486", "E384", "E385", "E35" }, -- search found nothing or hit an end: pattern.txt:163, options.txt:7848, message.txt:403
  { "E348", "E349" }, -- * # [i [d with nothing under the cursor: pattern.txt:61
  { "E42", "E553", "E776", "E380", "E381" }, -- quickfix and location lists: quickfix.txt:12,98,46,943,952
  { "E426", "E433", "E73", "E555", "E556" }, -- tags: tagsrch.txt:33,204,112, options.txt:6902
  { "E387", "E388", "E389" }, -- [i [d ]D include-file search: tagsrch.txt:684
  { "E662", "E663", "E664", "E20", "E490" }, -- change list, marks, folds: motion.txt:1252-1266,823, fold.txt:325
  { "E163", "E164", "E165", "E87", "E88", "E84" }, -- :next :bnext ends: editing.txt:744,762, windows.txt:1310,1331,1383
  { "E446", "E447" }, -- gf: editing.txt:262
}) do
  for _, code in ipairs(codes) do
    routine[code] = true
  end
end
-- noice's toast titles when no typed command names the toast (noice/config/routes.lua:85,90,95).
local titles = { error = "Error", warn = "Warning", info = "Messages" }
-- snacks' toast width { min = 40, max = 0.4 } and its padding of 1 cell per side (snacks/notifier.lua:114,118).
local TOAST_MIN, TOAST_MAX, TOAST_PAD = 40, 0.4, 2

local ui ---@type table
local orig_show ---@type function
local hook ---@type function
local batch ---@type table[]? entries waiting for the next flush
local flushing = false
local ring = {} ---@type table[]
local early = {} ---@type table[]? errors and warnings ui2 showed before snacks was set up, toasted once it is
local split_buf ---@type integer?
local fail ---@type fun(err: any, b: table[]?)

-- Same clock as snacks.notifier's `added` (snacks/notifier.lua:263-270), so the history picker sorts both.
local function now()
  local t = assert(vim.uv.clock_gettime("realtime"))
  return t.sec + t.nsec / 1e9
end

local function snacks_ready()
  local S = rawget(_G, "Snacks")
  if type(S) ~= "table" or not S.did_setup then
    return false
  end
  local ok, on = pcall(function() return S.config.notifier.enabled end)
  return ok and on == true
end

---@param e table
---@param route "toast"|"split"|"ui2"
local function record(e, route)
  if e.ring then -- an early message, recorded when ui2 showed it, now toasted
    e.ring.route = route
    return
  end
  e.ring = { added = e.added, kind = e.kind, level = e.level, title = e.title, msg = e.text, route = route }
  ring[#ring + 1] = e.ring
  if #ring > MAX_ENTRIES then
    table.remove(ring, 1)
  end
end

---@param content [integer, string, integer?][]
local function plain(content)
  local parts = {}
  for _, c in ipairs(content) do
    parts[#parts + 1] = c[2]
  end
  return table.concat(parts)
end

---@param kind string
---@param trigger string
local function new_entry(kind, trigger)
  local title ---@type string?
  -- A timer's message while the cmdline is open is also "typed_cmd"; only a running command gets its title.
  if trigger == "typed_cmd" and vim.fn.getcmdtype() == "" then
    title = ":" .. vim.fn.histget(":", -1)
    title = vim.fn.strcharlen(title) > 50 and vim.fn.strcharpart(title, 0, 49) .. "…" or title
  end
  return { kind = kind, level = levels[kind] or "info", chunks = {}, title = title, typed = title ~= nil, added = now() }
end

---@param e table
---@param content [integer, string, integer?][]
local function add_chunks(e, content)
  for _, c in ipairs(content) do
    e.chunks[#e.chunks + 1] = { c[2]:gsub("\r", ""), c[3] or 0 }
  end
end

-- Lines and highlight ranges of a batch for the split, chunk hl_ids as extmarks like ui2's own
-- (R/ui2/messages.lua:394-395).
---@param b table[]
local function render(b)
  local lines, hls = {}, {}
  for _, e in ipairs(b) do
    local cur = { "" }
    for _, c in ipairs(e.chunks) do
      local parts = vim.split(c[1], "\n", { plain = true })
      local srow, scol = #lines + #cur - 1, #cur[#cur]
      cur[#cur] = cur[#cur] .. parts[1]
      for i = 2, #parts do
        cur[#cur + 1] = parts[i]
      end
      if c[2] > 0 then
        hls[#hls + 1] = { srow, scol, #lines + #cur - 1, #cur[#cur], c[2] }
      end
    end
    while #cur > 1 and cur[#cur] == "" do
      cur[#cur] = nil
    end
    vim.list_extend(lines, cur)
  end
  return lines, hls
end

-- noice's cmdline_output split: below everything, 20% high, not entered, q closes, wrapped. The
-- minimal style turns off number, list, cursorline and statuscolumn (:h nvim_open_win).
---@param b table[]
local function show_split(b)
  if not (split_buf and api.nvim_buf_is_valid(split_buf)) then
    split_buf = api.nvim_create_buf(false, true)
    vim.bo[split_buf].bufhidden = "hide"
    pcall(api.nvim_buf_set_name, split_buf, "[Output]")
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buf = split_buf, desc = "Close" })
  end
  local lines, hls = render(b)
  api.nvim_buf_clear_namespace(split_buf, ns, 0, -1)
  api.nvim_buf_set_lines(split_buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(
      split_buf,
      ns,
      h[1],
      h[2],
      { end_row = h[3], end_col = h[4], hl_group = h[5], strict = false }
    )
  end
  local win = vim.fn.bufwinid(split_buf)
  if win == -1 then
    local height = math.max(10, math.floor(vim.o.lines * 0.2))
    win = api.nvim_open_win(split_buf, false, { split = "below", win = -1, height = height, style = "minimal" })
    api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,EndOfBuffer:", { win = win, scope = "local" })
  end
  api.nvim_win_set_cursor(win, { 1, 0 })
end

-- One toast for the entries `es`, with their chunk highlights drawn over snacks' own render.
---@param es table[]
---@param level "error"|"warn"|"info"
---@param opts table
local function toast(es, level, opts)
  local lines, hls = render(es)
  opts.ft = "text" -- not snacks' markdown: "[New]" or "[C]" would be concealed as links
  opts.history = false -- snacks keys its history by id (snacks/notifier.lua:404-406); the ring is the history
  -- 0 keeps it until dismissed (snacks/notifier.lua:31); `routine` lets a notifier.keep that holds errors skip it
  opts.timeout = level == "error" and not opts.routine and 0 or nil
  -- snacks calls this later from its timer, outside flush()'s pcall, and turns an error into an emsg
  -- (snacks/notifier.lua:333-345) that would come back here as another failing toast. So it catches its
  -- own errors, draws the plain text for snacks to size, and falls back to plain ui2.
  opts.style = function(buf, notif, ctx)
    ctx.opts.wo.wrap = true -- wrap like the row count in show(); snacks sizes the toast after this (notifier.lua:597)
    local ok, err = pcall(function() ctx.notifier:get_render()(buf, notif, ctx) end)
    if not ok then
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(notif.msg, "\n", { plain = true }))
      return fail(err)
    end
    if api.nvim_buf_get_lines(buf, 0, 1, false)[1] == lines[1] then
      for _, h in ipairs(hls) do
        pcall(
          api.nvim_buf_set_extmark,
          buf,
          ctx.ns,
          h[1],
          h[2],
          { end_row = h[3], end_col = h[4], hl_group = h[5], strict = false }
        )
      end
    end
  end
  rawget(_G, "Snacks").notifier.notify(table.concat(lines, "\n"), level, opts)
end

---@param b table[]
local function show(b)
  for _, e in ipairs(b) do
    e.text = table.concat(vim.tbl_map(function(c) return c[1] end, e.chunks)):gsub("\n+$", "")
  end
  b = vim.tbl_filter(function(e) return e.text ~= "" end, b)
  if #b == 0 then
    return
  end

  -- Rows the toasts take, as snacks sizes them: the widest line clamped to { min, max }, then each line
  -- wrapped at that width with its padding (snacks/notifier.lua:513-517, 588-603). The wider toast of
  -- a batch is the one that wraps, so one width for the whole batch is exact.
  local width = TOAST_MIN
  for _, e in ipairs(b) do
    e.widths = {}
    for _, l in ipairs(vim.split(e.text, "\n", { plain = true })) do
      e.widths[#e.widths + 1] = vim.fn.strdisplaywidth(l) + TOAST_PAD
      width = math.max(width, e.widths[#e.widths])
    end
  end
  width = math.min(width, math.floor(vim.o.columns * TOAST_MAX))
  local typed_rows = 0
  for _, e in ipairs(b) do
    e.rows = 0
    for _, w in ipairs(e.widths) do
      e.rows = e.rows + math.max(1, math.ceil(w / width))
    end
    typed_rows = typed_rows + (e.typed and e.rows or 0)
  end

  -- Taller than noice's 20 rows or than a toast may grow (snacks height max 0.6): split. noice measures
  -- each message (noice/config/preset.lua:102, noice/message/filter.lua:98-100), so a burst of short
  -- async messages stays a toast; the output of one typed command (many print()s) counts as one.
  local limit = math.min(20, math.floor(vim.o.lines * 0.6) - 2)
  local long = vim.tbl_filter(function(e) return (e.typed and typed_rows or e.rows) > limit end, b)
  if #long > 0 and pcall(show_split, long) then
    for _, e in ipairs(long) do
      record(e, "split")
    end
    b = vim.tbl_filter(function(e) return not vim.list_contains(long, e) end, b)
  end

  -- Info merges into one toast that replaces the previous one (noice's replace + merge); a message
  -- with a string id (`:w` progress) keeps its own. Adjacent errors or warnings share one toast, so a
  -- Vimscript error split over messages ("Error detected...", "line 3:", "E121: ...") reads as one.
  local info, groups = {}, {}
  for _, e in ipairs(b) do
    local last = groups[#groups]
    if e.level == "info" and not e.sid then
      info[#info + 1] = e
    elseif e.level ~= "info" and last and last.level == e.level and not last.sid then
      table.insert(last, e)
    else
      groups[#groups + 1] = { e, level = e.level, sid = e.sid }
    end
    record(e, "toast")
  end
  if #info > 0 then
    toast(info, "info", { id = "neoblocks.messages", title = info[1].title or titles.info })
  end
  for _, g in ipairs(groups) do
    local brief = g.level == "error"
    for _, e in ipairs(g) do
      brief = brief and routine[e.text:match("^E%d+")] == true
    end
    toast(g, g.level, { id = g.sid, title = g[1].title or titles[g.level], routine = brief })
  end
end

-- Replayed messages keep their ids: ui2 replaces a shown message with the same id (R/ui2/messages.lua:300,310-312).
---@param err any
---@param b table[]?
function fail(err, b)
  local installed = ui.msg.msg_show == hook
  if installed then
    ui.msg.msg_show = orig_show
  end
  vim.schedule(function()
    for _, e in ipairs(b or {}) do
      pcall(
        orig_show,
        e.kind,
        vim.tbl_map(function(c) return { 0, c[1], c[2] } end, e.chunks),
        false,
        false,
        false,
        e.id or 0,
        ""
      )
    end
  end)
  if installed then
    require("neoblocks.messages")._off("toasts", "the message hook failed: " .. tostring(err))
  end
end

local function flush()
  local b = batch
  batch = nil
  if not b then
    return
  end
  flushing = true
  local ok, err = pcall(show, b)
  flushing = false
  if not ok then
    fail(err, b)
  end
end

-- Returns true when the message was taken over, false to hand it to ui2.
local function route(kind, content, replace_last, append, id, trigger)
  if not require("neoblocks.messages")._on() then
    return false
  end
  -- snacks' failure report (snacks/notifier.lua:336-344) arrives one emsg per line. A toast of it can fail
  -- the same way, endlessly, and snacks dropped its queue anyway: back to plain ui2 before the first line.
  if levels[kind] and plain(content):find("Snacks notifier failed", 1, true) then
    fail("snacks.notifier failed, see :messages")
    return false
  end
  if
    passthrough[kind]
    or ui.cmd.prompt
    or ui.cmd.srow > 0
    or (trigger == "typed_cmd" and api.nvim_get_current_win() == ui.wins.pager)
    or flushing
    or not snacks_ready()
  then
    if not passthrough[kind] and kind ~= "progress" then
      local e = new_entry(kind, trigger)
      e.text = plain(content):gsub("\r", ""):gsub("\n+$", "")
      if e.text ~= "" then
        record(e, "ui2")
        if early and e.level ~= "info" and #early < MAX_ENTRIES and not snacks_ready() then
          add_chunks(e, content)
          early[#early + 1] = e
        end
      end
    end
    return false
  end
  -- Quiet kinds are dropped. Progress shows in a statusline (vim.ui.progress_status()); only `:w`'s "written" is a
  -- message, id 'nvim.bufwrite "<file>"' (:h ui-messages).
  if quiet[kind] or kind == "progress" and not (type(id) == "string" and id:match("^nvim%.bufwrite")) then
    return true
  end

  if not batch then
    batch = {}
    vim.schedule(flush)
  end
  local prev = batch[#batch]
  if append and prev then
    add_chunks(prev, content)
    return true
  end
  -- A message with the id of one in this batch replaces it (`:w` sends "writing", then "written"),
  -- and replace_last replaces the latest one (:h ui-messages).
  for i = #batch, 1, -1 do
    if batch[i].id == id or (replace_last and i == #batch) then
      table.remove(batch, i)
      break
    end
  end
  local e = new_entry(kind, trigger)
  e.id, e.sid = id, type(id) == "string" and "neoblocks.messages." .. id or nil
  add_chunks(e, content)
  batch[#batch + 1] = e
  return true
end

--- Toasts the errors and warnings ui2 showed before snacks was set up (its msg window clears them after
--- 'messagesopt' timeout), once snacks is; `last` gives up on them.
---@param last boolean
local function replay(last)
  local b = early
  if not b or not (last or snacks_ready()) then
    return
  end
  early = nil
  -- Load snacks.notifier in a normal context: snacks' vim.notify requires it lazily
  -- (snacks/init.lua:218-223), which fails with E5560 when the first notify comes from a fast event.
  pcall(function() return rawget(_G, "Snacks") and rawget(_G, "Snacks").notifier end)
  if #b > 0 and snacks_ready() and ui.msg.msg_show == hook then
    flushing = true
    local ok, err = pcall(show, b)
    flushing = false
    if not ok then
      fail(err)
    end
  end
end

--- Messages seen since setup, oldest first: toasts, split output and what ui2 kept (route "ui2").
function M.entries() return vim.deepcopy(ring) end

---@param ui2 table require("vim._core.ui2") after enable()
---@return boolean installed
function M.setup(ui2)
  ui = ui2
  if not (ui.msg and ui.cmd and type(ui.msg.msg_show) == "function" and type(ui.wins) == "table") then
    return false
  end
  if type(ui.cmd.srow) ~= "number" or ui.cmd.prompt == nil then
    return false
  end
  if ui.msg.msg_show == hook then
    return true
  end
  orig_show = ui.msg.msg_show
  hook = function(kind, content, replace_last, history, append, id, trigger)
    local ok, taken = pcall(route, kind, content, replace_last, append, id, trigger)
    if not ok then
      fail(taken)
    end
    if not (ok and taken) then
      return orig_show(kind, content, replace_last, history, append, id, trigger)
    end
  end
  ui.msg.msg_show = hook

  -- Startup errors become toasts on the tick after UIEnter, when lazy.nvim fires VeryLazy (lazy/core/util.lua:167-195)
  -- and a config's startup plugins (snacks) are set up; at VeryLazy itself for a snacks set up then; after that, never.
  local group = api.nvim_create_augroup("neoblocks.messages.toasts", { clear = true })
  if vim.v.vim_did_enter == 1 then
    vim.schedule(function() replay(false) end)
  else
    api.nvim_create_autocmd("UIEnter", {
      group = group,
      once = true,
      callback = function()
        vim.schedule(function() replay(false) end)
      end,
    })
  end
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VeryLazy",
    once = true,
    callback = function()
      vim.schedule(function() replay(true) end)
    end,
  })
  return true
end

return M
