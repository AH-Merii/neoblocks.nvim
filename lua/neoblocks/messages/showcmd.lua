-- Pending keys for a statusline, without the keys whose command runs at once. Neovim puts every typed key in
-- 'showcmd' while its command runs, and with 'showcmdloc' "statusline" that drew one frame of "w" or "^D" per
-- keypress. With 'showcmdloc' "last" the text comes to ui2 as msg_showcmd events instead (:h ui-messages), which
-- this replaces: a lone key is left out unless its command waits for more keys. A statusline draws it through
-- Neoblocks.messages.showcmd(). While the module is switched off, or after the hook failed or found msg_showcmd
-- missing, 'showcmdloc' is "statusline", so Neovim draws the keys itself for showcmd()'s %S.
--
-- Not a delay: while a command waits for its next key (after a count or a g), Neovim runs no scheduled callbacks,
-- so a delayed count would never show.
--
-- ui2 is private (vim._core). R = $VIMRUNTIME/lua/vim/_core, nightly v0.13.0-dev-1868:
-- - R/ui2.lua:159,238: the UI callback looks the handler up in ui.msg on every event.
-- - R/ui2/messages.lua:583: msg_showcmd(content), content as in msg_show: { attr_id, text, hl_id } chunks.
local M = {}

-- Normal-mode keys that wait for another key ($VIMRUNTIME/doc/index.txt, *normal-index*): those taking a
-- {char}, {motion} or {register}, the g z Z [ ] CTRL-W CTRL-\ prefixes, and counts. 'showcmd' writes control
-- keys as ^X.
local waits = { ["^W"] = true, ["^\\"] = true }
for key in ([[!"'<=>@FT[]`fgmqrtzcdyZ123456789]]):gmatch(".") do
  waits[key] = true
end

local ui, orig ---@type table, function
local installed = false
local shown = ""

--- The pending keys to show, last 10 characters as ui2 shows them (R/ui2/messages.lua:584).
function M.get() return shown end

--- The 'showcmd' text to show: all of it, unless it is one key whose command needs nothing more. Visual mode's
--- selection size ("12", "3x5") is kept.
---@param text string
---@return string
local function visible(text)
  local lone = #text == 1 or (#text == 2 and text:sub(1, 1) == "^")
  return (lone and not waits[text]) and "" or text
end

--- Where the keys go: to the hook with 'showcmdloc' "last" while it's on, to Neovim's own %S otherwise. showcmd()
--- draws both, so a statusline drawn once shows the keys either way.
---@param on boolean
local function place(on)
  local loc = on and "last" or "statusline"
  if vim.o.showcmdloc ~= loc then
    vim.o.showcmdloc = loc
  end
  if not on then
    shown = ""
  end
  vim.cmd.redrawstatus()
end

local hook

--- The hook failed: Neovim's own pending keys from now on, said once.
local function fail(err)
  installed = false
  if ui.msg.msg_showcmd == hook then
    ui.msg.msg_showcmd = orig
  end
  pcall(place, false)
  require("neoblocks.messages")._off("showcmd", "the pending-keys hook failed: " .. tostring(err))
end

---@param content [integer, string, integer?][]
local function update(content)
  local text = visible(table.concat(vim.tbl_map(function(chunk) return chunk[2] end, content or {})):sub(-10))
  if text ~= shown then
    shown = text
    vim.cmd.redrawstatus()
  end
end

---@param content [integer, string, integer?][]
hook = function(content)
  if not require("neoblocks.messages")._on(true) then
    return orig(content)
  end
  local ok, err = pcall(update, content)
  if not ok then
    fail(err)
  end
end

--- After a switch: the keys go to the hook while the module is on, to Neovim's %S while it's off.
function M.refresh()
  if installed then
    place(require("neoblocks.messages")._on(true))
  end
end

---@param ui2 table require("vim._core.ui2")
---@return boolean installed false when the ui2 internal it hooks is missing
function M.setup(ui2)
  if type(ui2.msg) ~= "table" or type(ui2.msg.msg_showcmd) ~= "function" then
    place(false)
    return false
  end
  if ui2.msg.msg_showcmd ~= hook then
    ui, orig = ui2, ui2.msg.msg_showcmd
    ui.msg.msg_showcmd = hook
  end
  installed = true
  M.refresh()
  return true
end

return M
