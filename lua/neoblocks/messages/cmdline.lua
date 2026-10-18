-- noice's command_palette preset on top of ui2: the ':' cmdline and input() prompts move into a bordered popup
-- near the top centre, with an icon and a title per cmdline type, and blink's cmdline menu attached under it.
-- '/' and '?' stay at the bottom over the statusline (noice's bottom_search), so nothing above them moves.
-- confirm() and :s///c prompts (ui2's dialog) and block mode (:if ... :endif) stay with plain ui2.
--
-- ui2 is private, so this leans on its internals (R = $VIMRUNTIME/lua/vim/_core, nightly v0.13.0-dev-1868):
-- - handlers are looked up from ui.cmd on every event (R/ui2.lua:159,238), so wrapping ui.cmd.cmdline_show
--   (R/ui2/cmdline.lua:96-113) and ui.cmd.cmdline_hide (R/ui2/cmdline.lua:144-177) is enough;
-- - ui.cmd.srow/level (R/ui2/cmdline.lua:8,10), ui.wins/bufs and ui.check_targets (R/ui2.lua:56-57,77).
-- ui2 still renders the text, its highlighting and the cursor in its own cmd window; this only moves that window.
-- If any of it fails, the wrappers uninstall themselves and plain ui2 takes over.
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("neoblocks.messages.cmdline")
local ROW, MIN_WIDTH = 3, 60 -- noice command_palette (noice/config/preset.lua:65-98)
local MAX_PROMPT = 60 -- longer input() prompts show inline, without icon or title (noice/ui/cmdline.lua:126-146)
local ICON, BORDER, TITLE = "NeoblocksMessagesIcon", "NeoblocksMessagesBorder", "NeoblocksMessagesTitle"
local WINHL = ("Normal:Normal,FloatBorder:%s,FloatTitle:%s,Search:,CurSearch:,IncSearch:"):format(BORDER, TITLE)

-- noice's cmdline formats (noice/config/init.lua:24-31), matched against firstc .. text. Icons are escaped as UTF-8
-- bytes (Lua 5.1 has no \u{}): nerd-font glyphs in the private use area do not survive every editor and tool.
-- U+E620 Lua, U+F128 Help, U+F097B input, U+F1EC Calculator, U+F054 Cmdline.
local formats = {
  { title = "Lua", icon = "\238\152\160", pattern = { "^:%s*lua%s+", "^:%s*lua%s*=%s*", "^:%s*=%s*" } },
  { title = "Help", icon = "\239\132\168", pattern = { "^:%s*he?l?p?%s+" } },
  { title = "Filter", icon = "$", pattern = { "^:%s*!" } },
}

local ui, orig_show, orig_hide
local active, popup_win = false, nil ---@type false|"popup"|"search", integer?

--- Title and icon for the cmdline. Like noice (noice/ui/cmdline.lua:81-115), a format applies once the cursor is past
--- its prefix and the longest match wins; an input() title is its prompt without the trailing ':' (same file:142).
--- A long or multi-line prompt stays inline in the popup, with no icon and the default title (same file:126-146).
---@return string title, string? icon
local function format(firstc, text, pos, prompt)
  if firstc == "" and (#prompt > MAX_PROMPT or prompt:find("\n")) then
    return "Input", nil
  elseif firstc == "" then
    local title = prompt:gsub("%s*:%s*$", "")
    return title ~= "" and title or "Input", "\243\176\165\187"
  elseif firstc == "=" then
    return "Calculator", "\239\135\172"
  end
  local line, best, title, icon = firstc .. text, 0, "Cmdline", "\239\129\148"
  for _, f in ipairs(formats) do
    for _, pat in ipairs(f.pattern) do
      local _, e = line:find(pat)
      if e and e > best and pos >= e - 1 then
        best, title, icon = e, f.title, f.icon
      end
    end
  end
  return title, icon
end

--- Where a cmdline_show goes: "popup" for ':' and '=' (also nested <C-r>=), and input() prompts, which send hl_id 0
--- (confirm() sends MoreMsg and :s///c Question; they stay in ui2's dialog; ':' sends -1, probe in
--- docs/decisions/messages.md). "search" for '/' and '?'.
--- "drop": ui2 schedules a cmdline_show that arrives in block mode (R/ui2.lua:242-243), so after ':if ... :endif' the
--- show for 'endif' runs once the cmdline is closed; drawing it would leave a stale cmdline (here a stale popup).
--- Prompts (firstc "") are not cmdline mode: confirm() and :s///c show theirs in mode "r". Cmdline modes are "c",
--- "cr" (overstrike) and "cv" (:h mode()).
---@return "drop"|"bottom"|"popup"|"search"
local function route(firstc, prompt, hl_id)
  if firstc ~= "" and ui.cmd.level == 0 and api.nvim_get_mode().mode:sub(1, 1) ~= "c" then
    return "drop"
  elseif ui.cmdheight ~= 0 or ui.cmd.srow > 0 then
    return "bottom"
  elseif firstc == ":" or firstc == "=" then
    return "popup"
  elseif firstc == "/" or firstc == "?" then
    return "search"
  end
  local input = firstc == "" and type(prompt) == "string" and prompt ~= "" and hl_id == 0
  return input and "popup" or "bottom"
end

--- Back to ui2's own window: closing it makes check_targets() open a fresh `relative = "laststatus"` one with ui2's
--- options, as ui2 does itself (R/ui2/cmdline.lua:147-150, R/ui2.lua:86-151).
local function restore()
  active, popup_win, vim.g.ui_cmdline_pos = false, nil, nil
  pcall(api.nvim_buf_clear_namespace, ui.bufs.cmd, ns, 0, -1)
  pcall(api.nvim_win_close, ui.wins.cmd, true)
  ui.check_targets()
end

--- ui2 raises 'cmdheight' to 1 on every show (R/ui2/cmdline.lua:27-33); undo it before ui2 redraws (R/ui2.lua:163-174)
--- so the statusline keeps the last row. Same idiom as ui2's.
local function keep_cmdheight()
  if vim.o.cmdheight ~= 0 then
    vim._with({ noautocmd = true, o = { splitkeep = "screen" } }, function()
      vim.o.cmdheight = 0
      return nil
    end)
  end
end

--- '/' and '?' like noice's bottom_search, a borderless float over the last row (noice/config/views.lua:143-153):
--- ui2's line keeps its look (MsgArea) but covers the statusline instead of pushing it up. blink's search menu
--- needs no position: with 'cmdheight' 0 it already anchors to the last row (blink.cmp config/completion/menu.lua:54-55).
local function place_search()
  local win = ui.wins.cmd
  api.nvim_win_set_config(
    win,
    { relative = "editor", row = vim.o.lines - 1, col = 0, width = vim.o.columns, height = 1, hide = false }
  )
  local height = api.nvim_win_text_height(win, {}).all
  if height > 1 then
    api.nvim_win_set_config(win, { relative = "editor", row = vim.o.lines - height, col = 0, height = height })
  end
  keep_cmdheight()
  active = "search"
end

--- Move ui2's cmd window (already filled by the original handler) into the popup.
local function place(content, pos, firstc, prompt)
  local win, buf, row = ui.wins.cmd, ui.bufs.cmd, ui.cmd.srow
  local text = ""
  for _, chunk in ipairs(content) do
    text = text .. chunk[2]
  end
  local title, icon = format(firstc, text, pos, prompt)
  local overlay = icon and firstc ~= "" and api.nvim_strwidth(icon) == 1 and api.nvim_strwidth(firstc) == 1

  -- The icon covers firstc (overlay) with a space after it; an input() prompt gets it in front (inline). No conceal:
  -- concealed text before the cursor misplaces the terminal cursor in this unfocused window (measured: ':' concealed
  -- put it one cell right), so ':lua ', ':help ' and the input() prompt stay visible.
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if overlay then
    api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { icon, ICON } }, virt_text_pos = "overlay" })
    api.nvim_buf_set_extmark(buf, ns, row, #firstc, { virt_text = { { " " } }, virt_text_pos = "inline" })
  elseif icon then
    api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { icon .. " ", ICON } }, virt_text_pos = "inline" })
  end
  -- Cells the icon adds to the first row: icon and a space, less the firstc cell it covers.
  local extra = icon and api.nvim_strwidth(icon) + 1 - (overlay and api.nvim_strwidth(firstc) or 0) or 0
  -- Cells in front of the typed text, which is on the last row (after a multi-line prompt's last line).
  local lines = api.nvim_buf_get_lines(buf, row, -1, false)
  local lead = (#lines > 1 and 0 or extra) + api.nvim_strwidth((firstc .. prompt):match("[^\n]*$"))

  local textw = 0 -- includes ui2's trailing cursor cell
  for _, l in ipairs(lines) do
    textw = math.max(textw, api.nvim_strwidth(l))
  end
  local width = math.min(math.max(MIN_WIDTH, extra + textw), vim.o.columns - 4)
  local col = math.floor((vim.o.columns - width - 2) / 2)
  api.nvim_win_set_config(win, {
    relative = "editor",
    row = ROW,
    col = col,
    width = width,
    height = 1,
    border = "rounded",
    title = { { " " .. title .. " ", TITLE } },
    title_pos = "center",
    hide = false,
  })
  if win ~= popup_win then
    -- ui2 sets its window options only when it (re)creates the window (R/ui2.lua:111-138); set ours the same way.
    vim._with(
      { win = win, noautocmd = true },
      function() return api.nvim_set_option_value("winhighlight", WINHL, { scope = "local" }) end
    )
    popup_win = win
  end
  local height = api.nvim_win_text_height(win, {}).all
  api.nvim_win_set_config(win, { height = height })
  keep_cmdheight()
  active = "popup"

  -- blink's cmdline menu goes one row below this (1-based row, 0-based col), relative to the editor
  -- (blink.cmp/lua/blink/cmp/config/completion/menu.lua:49-56): the row under the bottom border, and the cell before
  -- the typed text, as blink's own bottom default ({ lines - 1, 0 } with ':' in column 0). blink adds the 1-based
  -- keyword column and does not subtract the menu border there, so with a bordered menu labels sit one cell right of
  -- the typed text, the same as at the bottom.
  vim.g.ui_cmdline_pos = { ROW + height + 2, col + lead }
end

--- Put ui2's handlers back and say so once; the cmdline keeps working as plain ui2.
local function uninstall(err)
  if ui.cmd.cmdline_show ~= M.cmdline_show and ui.cmd.cmdline_hide ~= M.cmdline_hide then
    return
  end
  ui.cmd.cmdline_show, ui.cmd.cmdline_hide = orig_show, orig_hide
  pcall(restore)
  require("neoblocks.messages")._off("cmdline", "the popup failed: " .. tostring(err))
end

--- Run fn in pcall; on error fall back to plain ui2.
local function guard(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then
    uninstall(res)
  end
  return ok, res
end

---@private
function M.cmdline_show(content, pos, firstc, prompt, indent, level, hl_id)
  -- nightly annotates prompt as string|false (R/ui2/cmdline.lua:92)
  local p = type(prompt) == "string" and prompt or ""
  -- switched off: plain ui2, after an open popup is put back
  local ok_on, on = guard(require("neoblocks.messages")._on)
  local to = "bottom"
  if ok_on and on then
    local _
    _, to = guard(route, firstc, p, hl_id)
  end
  if to == "drop" then
    return
  elseif active and active ~= to then
    guard(restore) -- the window is hidden now; the original unhides it (R/ui2/cmdline.lua:22-23)
  end
  orig_show(content, pos, firstc, prompt, indent, level, hl_id)
  if ui.cmd.cmdline_show ~= M.cmdline_show then
    return -- route() or restore() failed and put plain ui2 back
  end
  local placed = to == "popup" and guard(place, content, pos, firstc, p) or to == "search" and guard(place_search)
  if (to == "popup" or to == "search") and not placed then
    orig_show(content, pos, firstc, prompt, indent, level, hl_id)
  end
end

---@private
function M.cmdline_hide(level, abort)
  orig_hide(level, abort)
  -- The original returns early while a nested cmdline is still open (R/ui2/cmdline.lua:153-155), keeping ui.cmd.level.
  if active and ui.cmd.level == 0 then
    guard(restore)
  end
end

--- After a switch: an open popup goes back to ui2's window when the module is off.
function M.refresh()
  if active and not require("neoblocks.messages")._on() then
    guard(restore)
  end
end

---@param ui2 table require("vim._core.ui2") after enable() with a UI attached
---@return boolean installed
function M.setup(ui2)
  local cmd = type(ui2) == "table" and ui2.cmd
  if
    not (
      type(cmd) == "table"
      and type(cmd.cmdline_show) == "function"
      and type(cmd.cmdline_hide) == "function"
      and type(cmd.srow) == "number"
      and type(cmd.level) == "number"
      and type(ui2.check_targets) == "function"
      and type(ui2.wins) == "table"
      and type(ui2.bufs) == "table"
      and type(ui2.cmdheight) == "number"
    )
  then
    return false
  elseif cmd.cmdline_show == M.cmdline_show then
    return true
  end
  ui, orig_show, orig_hide = ui2, cmd.cmdline_show, cmd.cmdline_hide
  cmd.cmdline_show, cmd.cmdline_hide = M.cmdline_show, M.cmdline_hide
  return true
end

return M
