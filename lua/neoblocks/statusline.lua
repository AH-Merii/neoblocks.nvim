--- A global statusline built from two lists of components, rebuilt only on events, so moving the cursor costs
--- nothing. Replaces lualine.nvim for a statusline with one global line.
---
--- ```lua
--- require("neoblocks").setup({
---   statusline = {
---     left = { "branch", "diff", "diagnostics" },
---     right = { "searchcount", { "%3l:%-2c", color = { bold = true } } },
---   },
--- })
--- ```
---
--- A component is a function returning statusline text, a statusline string starting with `%`, a built-in name
--- (`diagnostics`, `branch`, `diff`, `searchcount`, `progress_status`, `recording`) or a table with one of those
--- first and its options. A component draws nothing when it's empty or its `cond` isn't true; otherwise
--- `icon text` with one space each side (`padding`).
---@class neoblocks.statusline
local M = {}

M.meta = { desc = "A global statusline rebuilt only on events (replaces lualine.nvim)" }

---@alias neoblocks.statusline.Color string|vim.api.keyset.highlight a highlight group, or nvim_set_hl() attributes

---@class neoblocks.statusline.Config
---@field left? neoblocks.statusline.Component[] drawn from the left edge; a "%=" entry starts a centred group
---@field right? neoblocks.statusline.Component[] drawn against the right edge
---@field color? neoblocks.statusline.Color text colour of components without their own; default StatusLine's
---@field events? string[] events that rebuild the line; built-ins add the ones they need
---@class neoblocks.statusline.ComponentOpts
---@field [1] string|fun(): string? a function, a "%..." statusline string, or a built-in name
---@field icon? string drawn before the text, with a space; left out with the text when it's empty
---@field color? neoblocks.statusline.Color|fun(): neoblocks.statusline.Color? called on each rebuild
---@field cond? fun(): boolean drawn only when it returns true
---@field on_click? fun(clicks: integer, button: string, mods: string)
---@field padding? integer|{ left?: integer, right?: integer } spaces around the text: 1 each side by default
---@field symbols? table<string, string> diagnostics: error/warn/info/hint; diff: added/modified/removed
---@field colors? table<string, neoblocks.statusline.Color> keyed like symbols
---@field update_in_insert? boolean diagnostics: update the counts in Insert mode (default false)
---@field maxcount? integer searchcount: count up to this many matches (default 999)
---@field timeout? integer searchcount: stop counting after this many ms (default 500)
---@alias neoblocks.statusline.Component string|fun(): string?|neoblocks.statusline.ComponentOpts
local defaults = {
  left = { "%f %m%r", "branch", "diff", "diagnostics" },
  right = { "searchcount", "recording", "progress_status", "%l:%c" },
  events = {
    "WinEnter",
    "BufEnter",
    "BufWritePost",
    "SessionLoadPost",
    "FileChangedShellPost",
    "VimResized",
    "FileType",
    "ModeChanged",
  },
}

function M.setup() local _ = defaults end

--- Rebuilds the statusline now; after `:Neoblocks statusline off` it puts back the statusline it replaced.
---@param buf? integer
function M.refresh(buf) local _ = buf end

--- A colour function for `color`, picking the colour for the current mode.
---@param colors table<string, neoblocks.statusline.Color> keyed by the first letter of `mode()`: n, i, v, V, ...
---@param fallback? neoblocks.statusline.Color for any other mode
---@return fun(): neoblocks.statusline.Color?
function M.mode_color(colors, fallback)
  local _ = { colors, fallback }
  return function() end
end

function M.health() end

return M
