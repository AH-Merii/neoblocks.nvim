--- One module per plugin it replaces, each off until `setup()` names it. `Neoblocks.<module>` loads a module on
--- first use, so a module you don't use is never loaded.
---
--- A module that's on can be switched off and on again:
--- - everywhere: `:Neoblocks {module} {on|off|toggle}`, `vim.g.neoblocks_<module> = false`;
--- - in one buffer: `:Neoblocks! {module} {on|off|toggle}`, `vim.b.neoblocks_<module> = false`. A buffer's switch
---   wins over the global one.
---@class Neoblocks: neoblocks.modules
local M = {}

M.version = "0.0.0" -- x-release-please-version

setmetatable(M, {
  __index = function(t, k)
    local mod = require("neoblocks." .. k)
    rawset(t, k, mod)
    return mod
  end,
})

_G.Neoblocks = M

M.did_setup = false

--- Turns on each module named in `opts`, unless its options say `enabled = false`.
---
--- ```lua
--- require("neoblocks").setup({ colors = {} })
--- ```
---@param opts? neoblocks.Config
function M.setup(opts)
  if M.did_setup then
    return vim.notify("neoblocks: setup() was already called", vim.log.levels.ERROR)
  end
  M.did_setup = true
  local config = require("neoblocks.config")
  config.set(opts or {})
  for _, name in ipairs(require("neoblocks.meta").modules()) do
    if config.enabled(name) then
      M[name].setup()
    end
  end
end

--- Turns a module on or off without losing its setup: globally, or in one buffer.
---@param name string
---@param state? boolean on or off; flips it when nil
---@param buf? integer a buffer (0 for the current one); all buffers when nil
function M.toggle(name, state, buf)
  local util = require("neoblocks.util")
  if state == nil then
    state = not util.enabled(name, buf)
  end
  local key = "neoblocks_" .. name
  if buf then
    vim.b[buf][key] = state
  else
    vim.g[key] = state
  end
  local mod = M[name]
  if mod.refresh then
    mod.refresh(buf)
  end
end

return M
