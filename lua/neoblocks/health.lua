--- `:checkhealth neoblocks`: the version, whether setup() ran, then each module: on or off, and its own checks.
---@class neoblocks.health
local M = {}

function M.check()
  local health = vim.health
  local nb = require("neoblocks")
  health.start("neoblocks")
  health.info("version " .. nb.version)
  if vim.fn.has("nvim-0.13") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.13 (nightly) or newer is needed, found " .. tostring(vim.version()))
  end
  if nb.did_setup then
    health.ok("setup() called")
  else
    health.warn("setup() not called: every module is off")
  end
  local config = require("neoblocks.config")
  for _, name in ipairs(require("neoblocks.meta").modules()) do
    local mod = nb[name]
    health.start(("neoblocks.%s: %s"):format(name, mod.meta.desc))
    if config.enabled(name) then
      health.ok("on")
      if mod.health then
        mod.health()
      end
    else
      health.info("off: not named in setup()")
    end
  end
end

return M
