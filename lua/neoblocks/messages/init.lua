--- noice.nvim's message and cmdline look on top of Neovim's own ui2 (`:h ui2`), with nothing drawn by a UI of its
--- own. Replaces [noice.nvim](https://github.com/folke/noice.nvim) for its command_palette, bottom_search and
--- long_message_to_split presets with [snacks.nvim](https://github.com/folke/snacks.nvim)'s notifier:
---
--- - `:` and `input()` prompts in a bordered popup near the top, titled by the kind of command (Cmdline, Lua, Help,
---   Filter, Calculator or the prompt); blink.cmp's cmdline menu opens under it (`vim.g.ui_cmdline_pos`);
--- - `/` and `?` over the last row, so the windows don't move;
--- - messages as snacks.notifier toasts, each staying as long as snacks' `timeout` and `notifier.keep` say;
---   info merges into one toast; output taller than a toast opens in a split below that isn't entered (`q` closes it);
---   undo, quickfix, completion and verbose messages are left out, as noice left them out;
--- - `history()`: every message since startup in a picker, newest first;
--- - `showcmd()`: the keys of a command that waits for more (a count, `d`, `g`), for a statusline, without the one-frame
---   flash of keys whose command runs at once (`w`, `j`, `^D`).
---
--- ```lua
--- vim.o.cmdheight = 0 -- the popup and the bottom search need it, as noice's do
--- require("neoblocks").setup({
---   messages = {
---     -- messages ui2 keeps in its float, a typed command's output in the cmdline
---     ui2 = { msg = { targets = { default = "msg", typed_cmd = "cmd" } } },
---   },
--- })
--- vim.keymap.set("n", "<leader>n", function() Neoblocks.messages.history() end, { desc = "Message history" })
--- ```
---
--- Call `setup()` early in your config, before any message you want to see as a toast: `setup()` turns ui2 on with
--- the `ui2` options unless your config already did (`require("vim._core.ui2").enable()`), then hooks it. What comes
--- before that stays with plain ui2. Errors and warnings ui2 showed before snacks.notifier was set up become toasts
--- once it is, on the tick after UIEnter (lazy.nvim's VeryLazy), or at VeryLazy itself.
---
--- snacks.nvim is optional and found at runtime: without its notifier, messages stay with ui2 (and still go in the
--- history); without its picker, `history()` lists them in a split. ui2 is private (`vim._core`): each part checks the
--- internals it hooks when it's set up, and a part that finds one missing, or fails while it runs, puts ui2's own
--- handler back and says so once, so a Neovim that renamed one gives plain ui2, not a broken cmdline. Checked on
--- Neovim 0.13 nightly; `:checkhealth neoblocks` shows which parts are on. Without a UI attached
--- (`--headless`) there's no ui2, and the module does nothing.
---
--- The popup's border, title and icon are drawn in `NeoblocksMessagesBorder`, `NeoblocksMessagesTitle` and
--- `NeoblocksMessagesIcon`, linked to `DiagnosticSignInfo` (noice's colour). A toast passes `routine = true` to
--- snacks for a routine error (a search or jump that found nothing), so a snacks `notifier.keep` that holds errors
--- until dismissed can let the routine ones time out:
---
--- ```lua
--- require("snacks").setup({
---   notifier = { keep = function(n) return n.level == "error" and not n.routine or vim.fn.getcmdpos() > 0 end },
--- })
--- ```
---@class neoblocks.messages
local M = {}

M.meta = { desc = "ui2 with noice's cmdline popup, toasts and long output in a split (replaces noice.nvim)" }

---@class neoblocks.messages.Config
---@field ui2? table options for `require("vim._core.ui2").enable()`, when `setup()` turns ui2 on itself
---@field cmdline? boolean `:` and `input()` in the popup, `/` and `?` over the last row
---@field toasts? boolean messages as snacks.notifier toasts and long output in a split; false leaves them to ui2
---@field showcmd? boolean pending keys through `showcmd()`, which sets 'showcmdloc'; false leaves 'showcmdloc' alone
local defaults = {
  ui2 = {},
  cmdline = true,
  toasts = true,
  showcmd = true,
}

local api = vim.api
local NAME = "messages"
local PARTS = { "cmdline", "toasts", "showcmd" }

local S = {
  config = nil, ---@type neoblocks.messages.Config?
  ui = nil, ---@type table? require("vim._core.ui2") once it's hooked
  -- each part: "on", or why it's off
  status = {}, ---@type table<string, string>
}

---@param msg string
---@param level? integer
local function report(msg, level)
  vim.schedule(function() vim.notify("neoblocks.messages: " .. msg, level or vim.log.levels.WARN) end)
end

-- Whether the module is on: in the current buffer, or with `global` everywhere ('showcmdloc' is global). For the
-- parts; not API (a `--` comment keeps it out of the docs).
function M._on(global) return require("neoblocks.util").enabled(NAME, not global and api.nvim_get_current_buf() or nil) end

-- A part that failed or found a ui2 internal missing: plain ui2 from now on, said once.
function M._off(part, why)
  S.status[part] = why
  report(("%s: %s, using plain ui2"):format(part, why))
end

local function highlights()
  for _, name in ipairs({ "NeoblocksMessagesBorder", "NeoblocksMessagesTitle", "NeoblocksMessagesIcon" }) do
    api.nvim_set_hl(0, name, { link = "DiagnosticSignInfo", default = true })
  end
end

--- Turns ui2 on unless it is, then hooks each part the options turn on.
function M.setup()
  local config = require("neoblocks.config").get(NAME, defaults)
  S.config, S.status = config, {}
  local ok, ui = pcall(require, "vim._core.ui2")
  if not (ok and type(ui) == "table" and type(ui.enable) == "function") then
    for _, part in ipairs(PARTS) do
      S.status[part] = "this Neovim has no ui2 (vim._core.ui2)"
    end
    return
  end
  -- ui.cmd and ui.msg exist once enable() ran with a UI attached ($VIMRUNTIME/lua/vim/_core/ui2.lua:217-219,234-235
  -- on nightly), so they say whether it's on
  if not (ui.cmd and ui.msg) and #api.nvim_list_uis() > 0 then
    local enabled, err = pcall(ui.enable, config.ui2)
    if not enabled then
      report("ui2.enable() failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if not (ui.cmd and ui.msg) then
    for _, part in ipairs(PARTS) do
      S.status[part] = #api.nvim_list_uis() == 0 and "no UI attached, so no ui2" or "ui2 isn't on"
    end
    return
  end
  S.ui = ui
  highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("neoblocks.messages", { clear = true }),
    callback = highlights,
  })
  for _, part in ipairs(PARTS) do
    if config[part] == false then
      S.status[part] = "off in the options"
    else
      local loaded, res = pcall(function() return require("neoblocks.messages." .. part).setup(ui) end)
      if not loaded then
        M._off(part, tostring(res))
      elseif res == false then
        M._off(part, "a ui2 internal it hooks is missing")
      else
        S.status[part] = "on"
      end
    end
  end
end

--- After `:Neoblocks messages off` the cmdline and messages go back to plain ui2, and pending keys to Neovim's own
--- `%S` ('showcmdloc' "statusline"); on again, to this module.
---@param buf? integer
function M.refresh(buf)
  local _ = buf -- one UI: it follows the current buffer whichever buffer was switched
  if S.status.cmdline == "on" then
    require("neoblocks.messages.cmdline").refresh()
  end
  if S.status.showcmd == "on" then
    require("neoblocks.messages.showcmd").refresh()
  end
end

---@class neoblocks.messages.Entry
---@field added number when, in seconds (snacks.notifier's clock)
---@field kind string the ui-messages kind (`:h ui-messages`)
---@field level "error"|"warn"|"info"
---@field title? string the command that gave it
---@field msg string
---@field route "toast"|"split"|"ui2" where it went

--- Messages seen since `setup()`, oldest first: the toasts, the split's output and what ui2 kept (route "ui2").
---@return neoblocks.messages.Entry[]
function M.entries()
  -- also after the hook failed and ui2 took over: what it saw until then
  local toasts = package.loaded["neoblocks.messages.toasts"]
  return toasts and toasts.entries() or {}
end

---@return table? # Snacks, when snacks.nvim is set up
local function snacks()
  local s = rawget(_G, "Snacks")
  return type(s) == "table" and s.did_setup and s or nil
end

--- The message history, newest first, like noice's `:Noice history`: the messages of `entries()` and, with
--- snacks.notifier, the `vim.notify()` calls it shows. In a snacks picker, filterable by level, title and text; without
--- snacks, listed in a split (`q` closes it). `g<` and `:messages` still open ui2's pager.
function M.history()
  local items = {}
  local s = snacks()
  ---@param n { added: number, level: string, title: string?, kind: string?, msg: string }
  local function add(n, ft)
    local text = table.concat(vim.tbl_filter(function(v) return v ~= nil end, { n.level, n.title, n.kind, n.msg }), " ")
    -- the item shape of snacks' notifications source (snacks/picker/source/snacks.lua:4-21)
    items[#items + 1] = { text = text, item = n, severity = n.level, preview = { text = n.msg, ft = ft } }
  end
  if s and s.notifier and type(s.notifier.get_history) == "function" then
    for _, n in ipairs(s.notifier.get_history()) do
      add(n, "markdown")
    end
  end
  for _, e in ipairs(M.entries()) do
    e.title = e.title or e.kind
    add(e)
  end
  table.sort(items, function(a, b) return a.item.added > b.item.added end)
  if s and s.picker and type(s.picker.pick) == "function" then
    -- snacks' notifications picker (snacks/picker/config/sources.lua:836-842) over these items
    return s.picker.pick({
      title = "Messages",
      items = items,
      format = "notification",
      preview = "preview",
      formatters = { severity = { level = true } },
      confirm = "close",
    })
  end
  local lines = {}
  for _, it in ipairs(items) do
    local n = it.item
    local head = ("%s %-5s %s: "):format(os.date("%H:%M:%S", math.floor(n.added)), n.level, n.title or "")
    for i, l in ipairs(vim.split(n.msg, "\n", { plain = true })) do
      lines[#lines + 1] = (i == 1 and head or (" "):rep(#head)) .. l
    end
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "no messages" })
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden = false, "wipe"
  pcall(api.nvim_buf_set_name, buf, "[Messages]")
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buf = buf, desc = "Close" })
  api.nvim_open_win(buf, true, { split = "below", win = -1, height = math.max(10, math.floor(vim.o.lines * 0.3)) })
end

--- The keys typed so far of a command that waits for more (a count, an operator, `g`, a register), last 10
--- characters; empty while none waits. A lone key whose command runs at once is left out.
---@return string
function M.pending() return require("neoblocks.messages.showcmd").get() end

--- Pending keys as statusline text: `pending()` while the module is on, Neovim's own `%S` while it's switched off or
--- the hook isn't in (a ui2 without it). For that the module sets 'showcmdloc': "last" while on, so the keys reach the
--- hook, "statusline" otherwise, so Neovim draws them. The text is the same either way, so a statusline drawn once
--- follows a switch. For a statusline component: `function() return Neoblocks.messages.showcmd() end`.
---@return string
function M.showcmd()
  if S.status.showcmd == "on" then
    -- 'showcmdloc' is "last" while on, so %S draws nothing, and "statusline" while off, so pending() is empty
    return "%{v:lua.require'neoblocks.messages'.pending()}%S"
  end
  return "%S"
end

function M.health()
  local h = vim.health
  if not S.ui then
    return h.warn(("ui2 isn't hooked: %s"):format(S.status.cmdline or "setup() didn't run"))
  end
  for _, part in ipairs(PARTS) do
    local why = S.status[part]
    if why == "on" then
      h.ok(part .. ": on")
    elseif why == "off in the options" then
      h.info(part .. ": " .. why)
    else
      h.warn(("%s: plain ui2: %s"):format(part, why))
    end
  end
  local s = snacks()
  if S.status.toasts == "on" then
    if s and s.config and s.config.notifier and s.config.notifier.enabled then
      h.ok("snacks.notifier found: messages are toasts")
    else
      h.warn("snacks.notifier isn't set up: messages stay with ui2")
    end
  end
  if s and s.picker then
    h.ok("snacks.picker found: history() opens a picker")
  else
    h.info("no snacks.picker: history() lists the messages in a split")
  end
end

return M
