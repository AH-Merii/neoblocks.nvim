--- tiny-inline-diagnostic's look, drawn by a `vim.diagnostic` handler (`:h diagnostic-handlers`). Replaces
--- [tiny-inline-diagnostic.nvim](https://github.com/rachartier/tiny-inline-diagnostic.nvim) set up with its "modern"
--- preset, messages, counts, multiline and related information:
---
--- - the cursor's line: its diagnostics after the text in a rounded pill tinted by severity: the ones under the cursor,
---   or every one on the line when none is. Each message line gets a row of its own below (`│`, `└`), with LSP related
---   information under its diagnostic (`↳`). When the line ends too close to the window's edge, they go under it;
--- - when the cursor's line has none, each visible line with diagnostics gets a small pill: a `●` per diagnostic,
---   coloured by severity, and their count;
--- - nothing in Insert, Visual or Select mode, nor while `vim.diagnostic.open_float()`'s float is open.
---
--- ```lua
--- vim.diagnostic.config({ virtual_text = false }) -- this draws them instead
--- require("neoblocks").setup({ diagnostics = {} })
--- vim.keymap.set("n", "<leader>dt", function() Neoblocks.toggle("diagnostics") end, { desc = "Inline diagnostics" })
--- ```
---
--- `setup()` adds the `neoblocks.diagnostics` handler and turns it on in `vim.diagnostic.config()`, so the built-in
--- switches work on it as on the built-in handlers: `vim.diagnostic.enable(false)` hides it, `vim.diagnostic.config({
--- ["neoblocks.diagnostics"] = false })` turns it off, and `vim.diagnostic.config({ ["neoblocks.diagnostics"] = {
--- severity = ... } })` filters what it draws. It draws every buffer with diagnostics, from LSP or not.
---
--- The colours come from `DiagnosticError`, `DiagnosticWarn`, `DiagnosticInfo`, `DiagnosticHint`, `CursorLine`,
--- `NonText` and `Normal`, blended again on `ColorScheme`, into the `NeoblocksDiagnostics*` groups. The signs are Nerd
--- Font glyphs, as the preset's are.
---@class neoblocks.diagnostics
local M = {}

M.meta = { desc = "Diagnostics in a pill after the cursor's line, counts elsewhere (replaces tiny-inline-diagnostic)" }

---@class neoblocks.diagnostics.Config
---@field show_source? boolean add each diagnostic's source, as `(source)`
---@field show_code? boolean add each diagnostic's code, as `[code]`
---@field related? integer how many LSP related-information entries to show under each diagnostic; 0 for none
---@field softwrap? integer the cursor line's diagnostics go under it when it ends this close to the window's edge
---@field blend? number how much of the severity's colour tints the pill, from 0 to 1, over `Normal`'s background
---@field priority? integer the extmarks' priority: higher draws over other virtual text
---@field hide_on_float? boolean hide them while `vim.diagnostic.open_float()`'s float is open
local defaults = {
  show_source = true,
  show_code = true,
  related = 3,
  softwrap = 30,
  blend = 0.22,
  priority = 2048,
  hide_on_float = true,
}

local api = vim.api
local NAME = "diagnostics"
local HANDLER = "neoblocks.diagnostics"
local ns = api.nvim_create_namespace("neoblocks.diagnostics")
local group = api.nvim_create_augroup("neoblocks.diagnostics", { clear = false })

local SEV = { "Error", "Warn", "Info", "Hint" }
-- The modern preset's signs (tiny-inline-diagnostic presets.lua:4-12): Nerd Font half circles and long arrows,
-- U+E0B6, U+E0B4, U+F177 and U+F176 as UTF-8 bytes (Lua 5.1 has no \u{}).
local LEFT, RIGHT, DOT = "\238\130\182", "\238\130\180", "●"
local ARROW, UP_ARROW = " \239\133\183   ", " \239\133\182   "
local VERTICAL, VERTICAL_END = " │", " └"
-- The modes it's hidden in, as mode() names them (tiny-inline-diagnostic state.lua:13-23): Visual blockwise,
-- Replace and Operator-pending aren't among them.
local HIDDEN_MODES = { s = true, v = true, V = true, i = true, ic = true, ix = true }

---@class (private) neoblocks.diagnostics.Buf
---@field by_ns table<integer, vim.Diagnostic[]> each namespace's, as the handler got them: Neovim's lists, read only
---@field by_lnum? table<integer, vim.Diagnostic[]> every namespace's by line, most severe first; built when drawn
---@field version integer bumped when `by_ns` changes
---@field marks table<string, integer> the extmarks drawn, by what each draws
---@field pills table<integer, [string, string][]> the count pills drawn for this `version`, by line
---@field dirty? boolean `hide()` dropped a namespace and nothing has drawn since
---@field range? { first: integer, last: integer, version: integer, tick: integer, win: integer } the rows the pills
--- drawn cover, and for what; nil when they aren't what's drawn
---@field block? boolean the cursor line's diagnostics are what's drawn
---@field queued? boolean a redraw found its window past `range`, and a draw is scheduled

local S = {
  config = nil, ---@type neoblocks.diagnostics.Config?
  bufs = {}, ---@type table<integer, neoblocks.diagnostics.Buf>
  hidden_mode = false, -- the current mode is one of HIDDEN_MODES
  floats = {}, ---@type table<integer, true> the buffers of the diagnostic floats open
  open_float = nil, ---@type function? vim.diagnostic.open_float before setup() wrapped it
  blocks = {}, ---@type table<integer, true> the buffers showing their cursor line's diagnostics
  scroll = nil, ---@type integer? the WinScrolled autocmd, while `blocks` has one
}

-- Highlights ----------------------------------------------------------------------------------------------------

-- `fg` over `bg` at `alpha`, per channel, rounded (tiny-inline-diagnostic utils.lua blend()); a missing colour is
-- black.
---@param fg? integer
---@param bg? integer
---@param alpha number
---@return integer
local function blend(fg, bg, alpha)
  fg, bg = fg or 0, bg or 0
  local out = 0
  for shift = 16, 0, -8 do
    local f = math.floor(fg / 2 ^ shift) % 256
    local b = math.floor(bg / 2 ^ shift) % 256
    out = out * 256 + math.floor(math.min(math.max(0, alpha * f + (1 - alpha) * b), 255) + 0.5)
  end
  return out
end

-- Per severity: `NeoblocksDiagnostics<Sev>` the pill, `...Cap` its rounded ends on the cursor line, `...CapNoBg`
-- elsewhere, `...On<Sev2>` a `●` of this severity in a pill of another; then the arrow on and off the cursor line.
-- tiny-inline-diagnostic's highlights.lua, without the groups the modern preset doesn't use.
local function set_highlights()
  local function get(name) return api.nvim_get_hl(0, { name = name, link = false }) end
  local mix = get("Normal").bg or (vim.o.background == "light" and 0xffffff or 0)
  local cursorline = get("CursorLine").bg
  local sev = {} ---@type { fg?: integer, tint: integer, italic: boolean }[]
  for i, name in ipairs(SEV) do
    local h = get("Diagnostic" .. name)
    sev[i] = { fg = h.fg, tint = blend(h.fg, mix, S.config.blend), italic = h.italic or false }
  end
  for i, name in ipairs(SEV) do
    local s, pre = sev[i], "NeoblocksDiagnostics" .. name
    api.nvim_set_hl(0, pre, { fg = s.fg, bg = s.tint, italic = s.italic })
    api.nvim_set_hl(0, pre .. "Cap", { fg = s.tint, bg = cursorline, italic = s.italic })
    api.nvim_set_hl(0, pre .. "CapNoBg", { fg = s.tint, italic = s.italic })
    for j, on in ipairs(SEV) do
      api.nvim_set_hl(0, pre .. "On" .. on, { fg = s.fg, bg = sev[j].tint, italic = s.italic })
    end
  end
  local arrow = get("NonText").fg
  api.nvim_set_hl(0, "NeoblocksDiagnosticsArrow", { fg = arrow, bg = cursorline })
  api.nvim_set_hl(0, "NeoblocksDiagnosticsArrowNoBg", { fg = arrow })
end

-- What to draw ---------------------------------------------------------------------------------------------------

-- Most severe first; equal severities newest first, by the extmark vim.diagnostic placed for each, since
-- table.sort isn't stable (tiny-inline-diagnostic cache.lua:27-38, its #164).
local function before(a, b)
  return a.severity < b.severity
    or (a.severity == b.severity and a._extmark_id ~= nil and b._extmark_id ~= nil and a._extmark_id > b._extmark_id)
end

---@param b neoblocks.diagnostics.Buf
---@return table<integer, vim.Diagnostic[]>
local function by_lnum(b)
  if not b.by_lnum then
    local flat = {} ---@type vim.Diagnostic[]
    for _, list in pairs(b.by_ns) do
      for _, d in ipairs(list) do
        flat[#flat + 1] = d
      end
    end
    table.sort(flat, before)
    local lines = {} ---@type table<integer, vim.Diagnostic[]>
    for _, d in ipairs(flat) do
      local line = lines[d.lnum]
      if line then
        line[#line + 1] = d
      else
        lines[d.lnum] = { d }
      end
    end
    b.by_lnum = lines
  end
  return b.by_lnum
end

-- The line's diagnostics under the cursor's column, or all of them when none is; a zero-width range counts the
-- characters on both sides of it. Then each one's related information, up to `related` with a message
-- (tiny-inline-diagnostic filter.lua:26-78 and 125-173). Related entries are tables of our own; diagnostics aren't
-- copied or changed.
---@param line vim.Diagnostic[]
---@param col integer the cursor's byte column, 0-based
---@return table[]
local function under_cursor(line, col)
  local at = {} ---@type vim.Diagnostic[]
  for _, d in ipairs(line) do
    local hit
    if d.col == d.end_col and d.col > 0 then
      hit = col == d.col or col == d.col - 1
    else
      hit = col >= d.col and col <= d.end_col
    end
    if hit then
      at[#at + 1] = d
    end
  end
  if #at == 0 then
    at = line
  end
  local max = S.config.related
  local ret = {} ---@type table[]
  for _, d in ipairs(at) do
    ret[#ret + 1] = d
    local info = max > 0 and vim.tbl_get(d, "user_data", "lsp", "relatedInformation")
    if type(info) == "table" then
      for i, r in ipairs(info) do
        if i > max then
          break
        end
        if r.message and r.message ~= "" then
          ret[#ret + 1] = { related = r, severity = d.severity, lnum = d.lnum }
        end
      end
    end
  end
  return ret
end

-- An entry's text: the message, then ` [code]` and ` (source)`; for related information ` [file:line]`
-- (tiny-inline-diagnostic chunk.lua:432-457). NUL bytes show as `^@`, as Neovim shows them in text: strdisplaywidth()
-- can't take them (E976, tiny-inline-diagnostic's crash).
---@param e table a diagnostic, or a related entry from under_cursor()
---@return string
local function text_of(e)
  local o = S.config --[[@as neoblocks.diagnostics.Config]]
  local msg
  if e.related then
    local r = e.related
    msg = r.message
    local uri = r.location and r.location.uri
    if uri then
      local file = vim.fs.basename(vim.uri_to_fname(uri))
      local start = r.location.range and r.location.range.start
      msg = start and ("%s [%s:%d]"):format(msg, file, start.line + 1) or ("%s [%s]"):format(msg, file)
    end
  else
    msg = e.message
    if o.show_code and e.code ~= nil and e.code ~= vim.NIL then
      msg = ("%s [%s]"):format(msg, e.code)
    end
    if o.show_source and e.source then
      msg = ("%s (%s)"):format(msg, e.source)
    end
  end
  return (msg:gsub("%z", "^@"))
end

-- The text's lines, empty ones dropped (tiny-inline-diagnostic utils.lua split_lines()).
---@param s string
---@return string[]
local function lines_of(s)
  local ret = {} ---@type string[]
  for l in s:gmatch("([^\n\r]*)\r?\n?") do
    if l ~= "" then
      ret[#ret + 1] = l
    end
  end
  return ret
end

local width = vim.fn.strdisplaywidth

-- The cursor line's rows: per entry its header (the arrow and the left end on the first), then a row per further
-- message line, every message padded to the widest (one more for a diagnostic when some entry is related
-- information); the right end closes the last. `under` puts a blank row and the up arrow first
-- (tiny-inline-diagnostic virtual_text.lua:85-175, chunk.lua:38-356, highlights.lua:215-241).
---@param entries table[] from under_cursor()
---@param under boolean the line ends too close to the window's edge
---@param cursorline boolean 'cursorline' is drawn on the line
---@return [string, string][][]
local function block(entries, under, cursorline)
  local texts, max, any_related = {}, 0, false
  for k, e in ipairs(entries) do
    texts[k] = lines_of(text_of(e))
    for _, l in ipairs(texts[k]) do
      max = math.max(max, width(l))
    end
    any_related = any_related or e.related ~= nil
  end
  local n, out = #entries, {} ---@type integer, [string, string][][]
  for k, e in ipairs(entries) do
    local related = e.related ~= nil
    local hl = "NeoblocksDiagnostics" .. (SEV[e.severity] or "Error")
    local cap = (k > 1 or under or not cursorline) and hl .. "CapNoBg" or hl .. "Cap"
    local pad = (any_related and not related) and max + 1 or max
    local lines = texts[k]
    if under and k == 1 then
      out[#out + 1] = { { " ", "None" } }
    end
    for j, l in ipairs(lines) do
      local msg = l .. (" "):rep(pad - width(l))
      if j == 1 then
        local row = {} ---@type [string, string][]
        if k == 1 and not related then
          if under then
            out[#out + 1] = { { "", "None" }, { UP_ARROW, "NeoblocksDiagnosticsArrowNoBg" } }
          else
            row[1] = { ARROW, "NeoblocksDiagnosticsArrow" }
          end
        end
        if k == 1 then
          row[#row + 1] = { LEFT, cap }
        end
        row[#row + 1] = { related and "  " or " ", hl }
        row[#row + 1] = { related and "↳ " or DOT, hl }
        local text = (related and "" or " ") .. msg
        if #lines == 1 and k == n then
          row[#row + 1] = { msg ~= "" and text .. " " or text, hl }
          row[#row + 1] = { RIGHT, cap }
        else
          row[#row + 1] = { text .. " ", hl }
        end
        out[#out + 1] = row
      else
        local row = related and { { "    " .. msg, hl }, { " ", hl } }
          or { { j == #lines and VERTICAL_END or VERTICAL, hl }, { " " .. msg, hl }, { " ", hl } }
        if k == n and j == #lines then
          row[#row + 1] = { RIGHT, hl .. "CapNoBg" }
        end
        out[#out + 1] = row
      end
    end
  end
  return out
end

-- Another line's pill: a dot per diagnostic, the less severe ones first, each on the most severe one's tint, then
-- their count (tiny-inline-diagnostic chunk.lua:38-195 with display_count, extmark_writer.lua:22-36).
---@param line vim.Diagnostic[] most severe first
---@return [string, string][]
local function pill(line)
  local sevs = {} ---@type integer[]
  for i, d in ipairs(line) do
    sevs[i] = d.severity
  end
  table.sort(sevs)
  local main = SEV[sevs[1]] or "Error"
  local hl = "NeoblocksDiagnostics" .. main
  local row = { { ARROW, "NeoblocksDiagnosticsArrowNoBg" }, { LEFT, hl .. "CapNoBg" }, { " ", hl } }
  for i = #sevs, 2, -1 do
    row[#row + 1] = { DOT, ("NeoblocksDiagnostics%sOn%s"):format(SEV[sevs[i]] or "Error", main) }
  end
  row[#row + 1] = { DOT, hl }
  row[#row + 1] = { (" %d "):format(#line), hl }
  row[#row + 1] = { RIGHT, hl .. "CapNoBg" }
  return row
end

---@param line [string, string][]
---@param n integer
---@return [string, string][] the line after `n` spaces
local function indent(line, n)
  local ret = { { (" "):rep(n), "None" } }
  for _, chunk in ipairs(line) do
    ret[#ret + 1] = chunk
  end
  return ret
end

-- The extmarks for the cursor line's rows `vl`, as tiny-inline-diagnostic places them (extmarks.lua:156-256,
-- extmark_writer.lua): the first after the text, the rest over the lines below, aligned past the arrow; rows past
-- the buffer's end, or below a line that soft-wraps, as virtual lines.
---@param c integer the cursor's line, 0-based
---@param vl [string, string][][]
---@param under boolean
---@param win_col integer where the text after the line starts, in window columns
---@param line_count integer
---@param wrapped? integer the first of the rows' lines that soft-wraps
---@return [integer, vim.api.keyset.set_extmark][]
local function place(c, vl, under, win_col, line_count, wrapped)
  local priority = S.config.priority
  local left = api.nvim_strwidth(LEFT)
  local signs = under and left or left + api.nvim_strwidth(ARROW)
  local start = under and 3 or 1
  local under_signs = under and (signs == 0 and 0 or 1) or signs
  local out = {} ---@type [integer, vim.api.keyset.set_extmark][]
  local function at(row, virt_text, col)
    out[#out + 1] = { row, { virt_text = virt_text, virt_text_win_col = col, priority = priority, strict = false } }
  end
  local function below(row, l) out[#out + 1] = { row, { virt_lines = l, priority = priority, strict = false } } end
  if wrapped == c or (wrapped and under) then
    local lines = {}
    for i = 2, #vl do
      local pad = (under and i == 2) and win_col or win_col + (i > start and under_signs or 0)
      lines[#lines + 1] = pad > 0 and indent(vl[i], pad) or vl[i]
    end
    out[#out + 1] =
      { c, { virt_text = vl[1], virt_text_pos = "eol", virt_lines = lines, priority = priority, strict = false } }
  elseif wrapped then
    local n = wrapped - c
    at(c, vl[1], win_col)
    for i = 2, n do
      at(c + i - 1, vl[i], win_col + signs)
    end
    local lines = {}
    for i = n + 1, #vl do
      lines[#lines + 1] = win_col + signs > 0 and indent(vl[i], win_col + signs) or vl[i]
    end
    below(c + n - 1, lines)
  elseif under or c - 1 + #vl > line_count - 1 then
    local existing = line_count - c
    if under then
      at(c + 1, vl[2], win_col)
    end
    for i = start, math.min(existing, #vl) do
      at(c + i - 1, vl[i], win_col + (i > start and under_signs or 0))
    end
    local lines = {}
    for i = existing + 1, #vl do
      lines[#lines + 1] = indent(vl[i], win_col + (i > start and under_signs or 0))
    end
    if #lines > 0 then
      below(line_count - 1, lines)
    end
  else
    at(c, vl[1], win_col)
    for i = 2, #vl do
      at(c + i - 1, vl[i], win_col + signs)
    end
  end
  return out
end

-- Drawing ---------------------------------------------------------------------------------------------------------

---@param t string[]
---@param line [string, string][]
local function add_chunks(t, line)
  for _, chunk in ipairs(line) do
    t[#t + 1] = chunk[1]
    t[#t + 1] = chunk[2]
  end
  t[#t + 1] = "\2"
end

-- What a cursor-line extmark draws, as a string: a mark already drawing it is kept.
---@param tick integer
---@param row integer
---@param o vim.api.keyset.set_extmark
local function key_of(tick, row, o)
  local t = { "b", tick, row, o.virt_text_win_col or o.virt_text_pos or "" } ---@type any[]
  add_chunks(t, o.virt_text or {})
  for _, line in ipairs(o.virt_lines or {}) do
    add_chunks(t, line)
  end
  return table.concat(t, "\1")
end

-- The first line in [first, last] that soft-wraps in the current window: taller than one row without its virtual
-- lines. tiny-inline-diagnostic compares strdisplaywidth() with the text width (extmarks.lua:26-36), which errors
-- on a line with a NUL byte; the window's own count can't, and knows about 'linebreak' and inline virtual text.
---@return integer?
local function first_wrapped(first, last)
  for row = first, math.min(last, api.nvim_buf_line_count(0) - 1) do
    local h = api.nvim_win_text_height(0, { start_row = row, end_row = row })
    if h.all - h.fill > 1 then
      return row
    end
  end
end

-- Every extmark the current window should show for the buffer, each with a key saying what it draws. The cursor's
-- line in full when it has diagnostics, otherwise the pills of the lines in view, as tiny-inline-diagnostic
-- (renderer.lua:47-111, with multilines on and always_show off); virtcol("$") for where the line's text ends, as
-- there. Pills go a screen beyond the view each way, where they can't be seen: a scroll then finds its new lines
-- drawn, and while the view stays inside them nothing is planned at all (nil).
---@param buf integer
---@param b neoblocks.diagnostics.Buf
---@return { key: string, row: integer, opts: vim.api.keyset.set_extmark }[]?
local function plan(buf, b)
  local lines = by_lnum(b)
  local cursor = api.nvim_win_get_cursor(0)
  local c = cursor[1] - 1
  local tick = api.nvim_buf_get_changedtick(buf)
  local want = {}
  local here = lines[c]
  if here then
    local endcol = vim.fn.virtcol("$")
    local under = endcol - 1 > api.nvim_win_get_width(0) - S.config.softwrap
    local vl = block(under_cursor(here, cursor[2]), under, vim.wo.cursorline and vim.wo.cursorlineopt ~= "number")
    b.range, b.block = nil, true
    if #vl > 0 then
      local win_col = under and 0 or endcol - vim.fn.winsaveview().leftcol
      local wrapped = vim.wo.wrap and #vl > 1 and first_wrapped(c, c + #vl - 1) or nil
      for _, m in ipairs(place(c, vl, under, win_col, api.nvim_buf_line_count(buf), wrapped)) do
        want[#want + 1] = { key = key_of(tick, m[1], m[2]), row = m[1], opts = m[2] }
      end
    end
    return want
  end
  local first, last, win = vim.fn.line("w0") - 1, vim.fn.line("w$") - 1, api.nvim_get_current_win()
  local r = b.range
  if r and r.version == b.version and r.tick == tick and r.win == win and first >= r.first and last <= r.last then
    return nil
  end
  local height = api.nvim_win_get_height(0)
  r = { first = first - height, last = last + 1 + height, version = b.version, tick = tick, win = win }
  b.range, b.block = r, nil
  for row = r.first, r.last do
    local line = lines[row]
    if line then
      local virt_text = b.pills[row]
      if not virt_text then
        virt_text = pill(line)
        b.pills[row] = virt_text
      end
      want[#want + 1] = {
        key = ("p\1%d\1%d\1%d"):format(b.version, tick, row),
        row = row,
        opts = { virt_text = virt_text, virt_text_pos = "eol", priority = S.config.priority, strict = false },
      }
    end
  end
  return want
end

---@param buf integer
---@param b neoblocks.diagnostics.Buf
local function clear(buf, b)
  b.range, b.block = nil, nil
  if next(b.marks) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    b.marks = {}
  end
end

-- The window it draws for: the current one when it shows the buffer, else the first that does.
---@param buf integer
---@return integer?
local function window_of(buf)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == buf then
    return win
  end
  return vim.fn.win_findbuf(buf)[1]
end

local render ---@type fun(buf: integer)

-- WinScrolled only while a buffer shows its cursor line's diagnostics: they're placed by how far the window is
-- scrolled sideways and how wide it is, and WinScrolled fires on a resize too (:h win-scrolled-resized). The pills'
-- rows are checked as windows redraw (on_win, setup()), which costs a scroll less.
---@param buf integer
---@param shown? boolean
local function blocks_changed(buf, shown)
  S.blocks[buf] = shown or nil
  local any = next(S.blocks) ~= nil
  if any and not S.scroll then
    S.scroll = api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function()
        for b in pairs(S.blocks) do
          render(b)
        end
      end,
    })
  elseif not any and S.scroll then
    api.nvim_del_autocmd(S.scroll)
    S.scroll = nil
  end
end

-- Draws the buffer for its window, touching only the extmarks that change: one that already draws what's wanted
-- stays, so moving the cursor between lines without diagnostics changes nothing on screen.
---@param buf integer
function render(buf)
  local b = S.bufs[buf]
  if not b then
    return
  end
  b.dirty = nil
  local on = next(S.floats) == nil
    and not S.hidden_mode
    and next(b.by_ns) ~= nil
    and require("neoblocks.util").enabled(NAME, buf)
  local win = on and window_of(buf)
  local want ---@type { key: string, row: integer, opts: vim.api.keyset.set_extmark }[]?
  if not win then
    clear(buf, b)
  elseif win == api.nvim_get_current_win() then
    want = plan(buf, b)
  else
    want = api.nvim_win_call(win, function() return plan(buf, b) end)
  end
  if want then
    local drawn = {} ---@type table<string, integer>
    for _, m in ipairs(want) do
      local id = b.marks[m.key]
      if id then
        b.marks[m.key] = nil
      else
        id = api.nvim_buf_set_extmark(buf, ns, m.row, 0, m.opts)
      end
      drawn[m.key] = id
    end
    for _, id in pairs(b.marks) do
      api.nvim_buf_del_extmark(buf, ns, id)
    end
    b.marks = drawn
  end
  if S.blocks[buf] ~= b.block then
    blocks_changed(buf, b.block)
  end
end

-- Diagnostics in -------------------------------------------------------------------------------------------------

---@param buf integer
---@return neoblocks.diagnostics.Buf
local function track(buf)
  local b = S.bufs[buf]
  if b then
    return b
  end
  b = { by_ns = {}, version = 0, marks = {}, pills = {} }
  S.bufs[buf] = b
  -- every cursor move, as tiny-inline-diagnostic (autocmds.lua:39-72), but drawn at once rather than throttled: a
  -- move that changes nothing draws nothing
  api.nvim_create_autocmd("CursorMoved", { group = group, buf = buf, callback = function(ev) render(ev.buf) end })
  -- Forgotten when unloaded or wiped out, its extmarks deleted: they outlive an unload (`:edit!`), and a buffer written
  -- under a name keeps its number through the wipeout (`:w name` on an unnamed one), where vim.diagnostic drops its
  -- diagnostics without hide() (diagnostic/_store.lua:18-20). vim.diagnostic shows them again when they're read.
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buf = buf,
    callback = function(ev)
      clear(ev.buf, b)
      S.bufs[ev.buf] = nil
      blocks_changed(ev.buf, false)
      api.nvim_clear_autocmds({ group = group, buf = ev.buf })
    end,
  })
  return b
end

---@param b neoblocks.diagnostics.Buf
local function changed(b)
  b.version = b.version + 1
  b.by_lnum, b.pills = nil, {}
end

-- vim.diagnostic.show() calls hide() for a namespace before show() (diagnostic/_display.lua): hide() only marks the
-- buffer, and draws on the next tick if no show() drew it first, so an update draws once. Both get the buffer as
-- the caller named it, 0 included, as the built-in handlers do (diagnostic/_handlers.lua: vim._resolve_bufnr()).
---@type vim.diagnostic.Handler
local handler = {
  show = function(namespace, buf, diagnostics)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    local b = track(buf)
    b.by_ns[namespace] = diagnostics
    changed(b)
    render(buf)
  end,
  hide = function(namespace, buf)
    buf = buf == 0 and api.nvim_get_current_buf() or buf
    local b = S.bufs[buf]
    if not (b and b.by_ns[namespace]) then
      return
    end
    b.by_ns[namespace] = nil
    changed(b)
    b.dirty = true
    vim.schedule(function()
      if b.dirty and S.bufs[buf] == b then
        render(buf)
      end
    end)
  end,
}

-- vim.diagnostic.open_float(), hiding the diagnostics while its float is open (tiny-inline-diagnostic override.lua)
local function open_float(...)
  local float, win = S.open_float(...)
  if float and S.config.hide_on_float then
    S.floats[float] = true
    M.refresh()
    api.nvim_create_autocmd({ "BufWinLeave", "BufDelete" }, {
      group = group,
      buf = float,
      once = true,
      callback = function()
        S.floats[float] = nil
        vim.schedule(function() M.refresh() end)
      end,
    })
  end
  return float, win
end

-- Setup -----------------------------------------------------------------------------------------------------------

---@private
function M.setup()
  S.config = require("neoblocks.config").get(NAME, defaults)
  set_highlights()
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function(ev)
      -- Neovim's vim.v.event annotation (_meta/vvars_extra.lua) lacks ModeChanged's fields
      local event = vim.v.event --[[@as { new_mode: string }]]
      local hidden = HIDDEN_MODES[event.new_mode] == true
      if hidden ~= S.hidden_mode then
        S.hidden_mode = hidden
        render(ev.buf)
      end
    end,
  })
  -- The pills' rows: a window redrawn past them (scrolled further than its cursor lets CursorMoved see, as another
  -- window or the mouse can, or a fold opened) draws on the next tick. on_win is given the rows; WinScrolled would
  -- read v:event and line() on every scroll (docs/decisions/diagnostics.md 3).
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, toprow, botrow)
      local b = S.bufs[buf]
      local r = b and b.range
      if r and r.win == win and (toprow < r.first or botrow > r.last) and not b.queued then
        b.queued = true
        vim.schedule(function()
          b.queued = nil
          if S.bufs[buf] == b then
            render(buf)
          end
        end)
      end
      return false
    end,
  })
  api.nvim_create_autocmd("VimResized", { group = group, callback = function() M.refresh() end })

  vim.diagnostic.handlers[HANDLER] = handler
  if S.config.hide_on_float and not S.open_float then
    S.open_float = vim.diagnostic.open_float
    vim.diagnostic.open_float = open_float
  end
  -- config() shows every buffer's diagnostics again, through the handler too, so the ones already there draw now
  vim.diagnostic.config({ [HANDLER] = vim.diagnostic.config()[HANDLER] or true })
end

--- Draws again after the module is switched on or off: a buffer (0 for the current one), or every buffer.
---@param buf? integer
function M.refresh(buf)
  if buf then
    return render(buf == 0 and api.nvim_get_current_buf() or buf)
  end
  for b in pairs(S.bufs) do
    render(b)
  end
end

---@private
function M.health()
  local h = vim.health
  local config = vim.diagnostic.config() or {}
  if vim.diagnostic.handlers[HANDLER] ~= handler then
    h.error("vim.diagnostic.handlers['neoblocks.diagnostics'] was replaced after setup(): nothing draws them")
  elseif not config[HANDLER] then
    h.warn("off in vim.diagnostic.config(): ['neoblocks.diagnostics'] is false")
  else
    h.ok("drawn by the neoblocks.diagnostics handler")
  end
  if config.virtual_text then
    h.warn("vim.diagnostic.config() has virtual_text on as well: both draw after the line")
  end
  if S.config.hide_on_float then
    if vim.diagnostic.open_float == open_float then
      h.ok("hidden while vim.diagnostic.open_float()'s float is open")
    else
      h.warn("vim.diagnostic.open_float was replaced after setup(): its float doesn't hide them")
    end
  end
end

return M
