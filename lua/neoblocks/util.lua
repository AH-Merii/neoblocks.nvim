--- Helpers shared by two or more modules. A helper only one module needs stays in that module.
---@class neoblocks.util
local M = {}

--- Whether a module is on in a buffer: set up, and not switched off by `vim.b.neoblocks_<name>` or, when the
--- buffer doesn't say, `vim.g.neoblocks_<name>`.
---@param name string
---@param buf? integer
function M.enabled(name, buf)
  if not require("neoblocks.config").enabled(name) then
    return false
  end
  local key = "neoblocks_" .. name
  local b = buf and vim.b[buf][key]
  if b ~= nil then
    return b ~= false
  end
  return vim.g[key] ~= false
end

return M
