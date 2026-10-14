--- The options each module runs with: its defaults, with what `setup()` passed for it on top.
---@class neoblocks.config
local M = {}

local user = {} ---@type table<string, table>

---@param opts neoblocks.Config
function M.set(opts)
  vim.validate("opts", opts, "table")
  user = {}
  for name, o in pairs(opts) do
    vim.validate(("opts.%s"):format(name), o, "table")
    user[name] = o
  end
end

--- Whether `setup()` turned the module on: named in its options, and not `enabled = false`.
---@param name string
function M.enabled(name) return user[name] ~= nil and user[name].enabled ~= false end

--- The module's defaults with the user's options on top; lists are replaced, not merged.
---@generic T: table
---@param name string
---@param defaults T
---@return T
function M.get(name, defaults)
  local o = vim.deepcopy(user[name] or {})
  o.enabled = nil
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), o)
end

return M
