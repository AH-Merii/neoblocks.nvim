--- Finds the modules: every lua/neoblocks/<name>.lua or lua/neoblocks/<name>/init.lua on 'runtimepath', except the
--- core files below. Adding a module is adding its file, here or in your own config; nothing lists them.
---@class neoblocks.meta
local M = {}

---@class neoblocks.Meta
---@field desc string one line: what the module does

--- The files that make up neoblocks itself rather than a module.
M.core = { init = true, config = true, meta = true, util = true, health = true, types = true }

--- Module names, sorted.
---@return string[]
function M.modules()
  local seen, ret = {}, {} ---@type table<string, boolean>, string[]
  for _, path in ipairs(vim.api.nvim_get_runtime_file("lua/neoblocks/*", true)) do
    local file = vim.fs.basename(path)
    local name = file:match("^(.+)%.lua$") or (vim.uv.fs_stat(path .. "/init.lua") and file)
    if name and not M.core[name] and not seen[name] then
      seen[name] = true
      ret[#ret + 1] = name
    end
  end
  table.sort(ret)
  return ret
end

return M
