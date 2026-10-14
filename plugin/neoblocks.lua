-- :Neoblocks {module} {on|off|toggle} switches a module set up by setup() on or off; with a bang, in the current
-- buffer only. The command is all this file adds at startup: modules load when it or setup() first uses them.
local actions = { "on", "off", "toggle" }

vim.api.nvim_create_user_command("Neoblocks", function(cmd)
  local name, action = cmd.fargs[1], cmd.fargs[2]
  local modules = require("neoblocks.meta").modules()
  if not vim.list_contains(modules, name) or not vim.list_contains(actions, action) then
    return vim.notify(
      "usage: :Neoblocks[!] {" .. table.concat(modules, "|") .. "} {on|off|toggle}",
      vim.log.levels.ERROR
    )
  end
  if not require("neoblocks.config").enabled(name) then
    return vim.notify(("neoblocks: %s is off in setup()"):format(name), vim.log.levels.ERROR)
  end
  local state ---@type boolean? nil flips it
  if action ~= "toggle" then
    state = action == "on"
  end
  require("neoblocks").toggle(name, state, cmd.bang and 0 or nil)
end, {
  bang = true,
  nargs = "+",
  desc = "Switch a neoblocks module on or off",
  complete = function(_, line)
    local n = #vim.split(line, "%s+", { trimempty = true }) + (line:match("%s$") and 1 or 0)
    if n == 2 then
      return require("neoblocks.meta").modules()
    elseif n == 3 then
      return actions
    end
    return {}
  end,
})
