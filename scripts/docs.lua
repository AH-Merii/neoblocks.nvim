-- Generates the docs from the code: `nvim -l scripts/docs.lua [outdir]`. CI's docs bot commits the result to main.
--
-- Read from each module's own file (and lua/neoblocks/init.lua for neoblocks itself):
-- - the `---` comment block at the top of the file: what the module is and how to use it (markdown);
-- - `M.meta.desc`: one line;
-- - the `---@class neoblocks.<name>.Config` annotation and the `local defaults = {...}` table under it: the options;
-- - each `function M.<name>(...)` with a `---` comment above it: the API, with its @param and @return lines.
--   A function with no comment, or with @private, is left out.
--
-- Written: docs/<module>.md, doc/neoblocks.txt (vimdoc), the module table in README.md and lua/neoblocks/types.lua.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local out = arg[1] and vim.fs.normalize(vim.fn.fnamemodify(arg[1], ":p")) or root
vim.opt.rtp:prepend(root)

---@class neoblocks.docs.Fn
---@field name string
---@field params string the parameter list as written, e.g. "(name, state, buf)"
---@field desc string[]
---@field args { name: string, type: string, desc: string }[]
---@field returns { type: string, desc: string }[]

---@class neoblocks.docs.Module
---@field name string "neoblocks" for neoblocks itself
---@field prefix string what the API is called through: "Neoblocks" or "Neoblocks.<name>"
---@field desc string
---@field intro string[]
---@field config? string[] the Config annotation and the defaults table
---@field fns neoblocks.docs.Fn[]

--- Splits "name type rest" from an annotation, the type being the next word (types here have no spaces).
local function split_annotation(s)
  local name, type, desc = s:match("^(%S+)%s+(%S+)%s*(.*)$")
  return name or s, type or "", desc or ""
end

---@param path string
---@param name string
---@param prefix string
---@return neoblocks.docs.Module
local function parse(path, name, prefix)
  local lines = vim.fn.readfile(path)
  local mod = { name = name, prefix = prefix, desc = "", intro = {}, fns = {} } ---@type neoblocks.docs.Module
  local i = 1
  while lines[i] and lines[i]:match("^%-%-%-") and not lines[i]:match("^%-%-%-%s*@") do
    mod.intro[#mod.intro + 1] = (lines[i]:gsub("^%-%-%- ?", ""))
    i = i + 1
  end
  local pending = {} ---@type string[]
  while i <= #lines do
    local line = lines[i]
    if line:match("^%-%-%-") then
      pending[#pending + 1] = (line:gsub("^%-%-%- ?", ""))
    else
      local fname, params = line:match("^function M%.([%w_]+)(%b())")
      local private = false
      for _, p in ipairs(pending) do
        private = private or p:match("^@private") ~= nil
      end
      if fname and #pending > 0 and not private then
        local fn = { name = fname, params = params, desc = {}, args = {}, returns = {} } ---@type neoblocks.docs.Fn
        for _, p in ipairs(pending) do
          local tag, rest = p:match("^@(%w+)%s*(.*)$")
          if tag == "param" then
            local n, t, d = split_annotation(rest)
            fn.args[#fn.args + 1] = { name = n, type = t, desc = d }
          elseif tag == "return" then
            local t, d = rest:match("^(%S+)%s*(.*)$")
            fn.returns[#fn.returns + 1] = { type = t or rest, desc = d or "" }
          elseif not tag then
            fn.desc[#fn.desc + 1] = p
          end
        end
        mod.fns[#mod.fns + 1] = fn
      elseif line:match("^local defaults = {") then
        local config = vim.tbl_filter(function(p) return p:match("^@class") or p:match("^@field") end, pending)
        config = vim.tbl_map(function(p) return "---" .. p end, config)
        while lines[i] do
          config[#config + 1] = lines[i]
          if lines[i] == "}" then
            break
          end
          i = i + 1
        end
        mod.config = config
      end
      pending = {}
    end
    i = i + 1
  end
  return mod
end

--- Trims leading and trailing empty lines.
local function trim(list)
  local s, e = 1, #list
  while s <= e and list[s] == "" do
    s = s + 1
  end
  while e >= s and list[e] == "" do
    e = e - 1
  end
  return vim.list_slice(list, s, e)
end

local function signature(mod, fn) return ("%s.%s%s"):format(mod.prefix, fn.name, fn.params) end

---@param mod neoblocks.docs.Module
local function markdown(mod)
  local md = { "# " .. (mod.name == "neoblocks" and "neoblocks" or "neoblocks." .. mod.name), "", mod.desc, "" }
  vim.list_extend(md, trim(mod.intro))
  if mod.name ~= "neoblocks" then
    vim.list_extend(
      md,
      { "", "## Setup", "", "```lua", ('require("neoblocks").setup({ %s = {} })'):format(mod.name), "```" }
    )
  end
  if mod.config then
    vim.list_extend(md, { "", "## Options", "", "```lua" })
    vim.list_extend(md, mod.config)
    md[#md + 1] = "```"
  end
  if #mod.fns > 0 then
    vim.list_extend(md, { "", "## API" })
    for _, fn in ipairs(mod.fns) do
      vim.list_extend(md, { "", "### `" .. signature(mod, fn) .. "`", "" })
      vim.list_extend(md, trim(fn.desc))
      if #fn.args > 0 or #fn.returns > 0 then
        md[#md + 1] = ""
      end
      for _, a in ipairs(fn.args) do
        md[#md + 1] = ("- `%s` `%s`%s"):format(a.name, a.type, a.desc ~= "" and (": " .. a.desc) or "")
      end
      for _, r in ipairs(fn.returns) do
        md[#md + 1] = ("- returns `%s`%s"):format(r.type, r.desc ~= "" and (": " .. r.desc) or "")
      end
    end
  end
  md[#md + 1] = ""
  return md
end

--- A help line with a tag at the right edge (column 78).
local function tagged(left, tag)
  tag = "*" .. tag .. "*"
  return left .. (" "):rep(math.max(1, 78 - vim.fn.strdisplaywidth(left) - #tag)) .. tag
end

--- Markdown lines to help lines: ```lua blocks become >lua ... <, `code` stays as is.
local function vimdoc_text(lines, indent)
  local ret, in_code = {}, false
  for _, l in ipairs(lines) do
    local lang = l:match("^```(%w*)$")
    if lang and not in_code then
      ret[#ret + 1] = indent .. ">" .. lang
      in_code = true
    elseif l == "```" and in_code then
      ret[#ret + 1] = indent .. "<"
      in_code = false
    else
      ret[#ret + 1] = l == "" and "" or ((in_code and (indent .. "  ") or indent) .. l)
    end
  end
  return ret
end

---@param mod neoblocks.docs.Module
local function vimdoc(mod)
  local tag = mod.name == "neoblocks" and "neoblocks-intro" or ("neoblocks-" .. mod.name)
  local title = mod.name == "neoblocks" and "INTRODUCTION" or mod.name:upper()
  local doc = { ("="):rep(78), tagged(title, tag), "", mod.desc, "" }
  vim.list_extend(doc, vimdoc_text(trim(mod.intro), ""))
  if mod.config then
    vim.list_extend(doc, { "", tagged("Options ~", tag .. "-options"), ">lua" })
    vim.list_extend(doc, vim.tbl_map(function(l) return l == "" and "" or ("  " .. l) end, mod.config))
    doc[#doc + 1] = "<"
  end
  for _, fn in ipairs(mod.fns) do
    local args = fn.params:gsub("([%w_]+)", "{%1}")
    vim.list_extend(
      doc,
      { "", tagged(("%s.%s%s"):format(mod.prefix, fn.name, args), ("%s.%s()"):format(mod.prefix, fn.name)) }
    )
    vim.list_extend(doc, vimdoc_text(trim(fn.desc), "    "))
    if #fn.args > 0 then
      vim.list_extend(doc, { "", "    Parameters: ~" })
      for _, a in ipairs(fn.args) do
        doc[#doc + 1] = ("      • {%s} (`%s`)%s"):format(
          a.name:gsub("%?$", ""),
          a.type,
          a.desc ~= "" and (" " .. a.desc) or ""
        )
      end
    end
    if #fn.returns > 0 then
      vim.list_extend(doc, { "", "    Return: ~" })
      for _, r in ipairs(fn.returns) do
        doc[#doc + 1] = ("      (`%s`)%s"):format(r.type, r.desc ~= "" and (" " .. r.desc) or "")
      end
    end
  end
  doc[#doc + 1] = ""
  return doc
end

local function write(path, lines)
  path = out .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local names = require("neoblocks.meta").modules()
local nb = require("neoblocks")
local core = parse(root .. "/lua/neoblocks/init.lua", "neoblocks", "Neoblocks")
core.desc = "Hand-rolled replacements for Neovim plugins."
local modules = {} ---@type neoblocks.docs.Module[]
for _, name in ipairs(names) do
  local file = root .. "/lua/neoblocks/" .. name .. ".lua"
  file = vim.uv.fs_stat(file) and file or (root .. "/lua/neoblocks/" .. name .. "/init.lua")
  local mod = parse(file, name, "Neoblocks." .. name)
  mod.desc = nb[name].meta.desc
  modules[#modules + 1] = mod
end

-- docs/
write("docs/neoblocks.md", markdown(core))
for _, mod in ipairs(modules) do
  write(("docs/%s.md"):format(mod.name), markdown(mod))
end

-- doc/neoblocks.txt
local help = { "*neoblocks.txt*  " .. core.desc, "", ("="):rep(78), tagged("CONTENTS", "neoblocks-contents"), "" }
help[#help + 1] = ("  Introduction%s|neoblocks-intro|"):format((" "):rep(40 - #"  Introduction"))
for _, mod in ipairs(modules) do
  help[#help + 1] = ("  %s%s|neoblocks-%s|"):format(mod.name, (" "):rep(38 - #mod.name), mod.name)
end
help[#help + 1] = ""
vim.list_extend(help, vimdoc(core))
for _, mod in ipairs(modules) do
  vim.list_extend(help, vimdoc(mod))
end
help[#help + 1] = "vim:tw=78:ts=8:sw=4:sts=4:et:ft=help:norl:"
write("doc/neoblocks.txt", help)

-- README.md: the table between the markers
local readme_path = root .. "/README.md"
local readme = vim.fn.readfile(readme_path)
local s = vim.iter(ipairs(readme)):find(function(_, l) return l == "<!-- modules:start -->" end)
local e = vim.iter(ipairs(readme)):find(function(_, l) return l == "<!-- modules:end -->" end)
assert(s and e and s < e, "README.md: the <!-- modules:start --> and <!-- modules:end --> markers are missing")
local table_lines = { "<!-- modules:start -->", "", "| Module | What it does |", "| --- | --- |" }
for _, mod in ipairs(modules) do
  table_lines[#table_lines + 1] = ("| [%s](docs/%s.md) | %s |"):format(mod.name, mod.name, mod.desc)
end
vim.list_extend(table_lines, { "", "<!-- modules:end -->" })
local new_readme = vim.list_extend(vim.list_slice(readme, 1, s - 1), table_lines)
write("README.md", vim.list_extend(new_readme, vim.list_slice(readme, e + 1)))

-- lua/neoblocks/types.lua
local types = {
  "---@meta _",
  "-- Generated by scripts/docs.lua from each module's annotations. Don't edit: the docs bot rewrites it.",
  "",
  "---@class neoblocks.modules",
}
for _, name in ipairs({ "config", "health", "meta", "util" }) do
  types[#types + 1] = ("---@field %s neoblocks.%s"):format(name, name)
end
for _, mod in ipairs(modules) do
  types[#types + 1] = ("---@field %s neoblocks.%s"):format(mod.name, mod.name)
end
vim.list_extend(types, { "", "---@class neoblocks.Config" })
for _, mod in ipairs(modules) do
  if mod.config then
    types[#types + 1] = ("---@field %s? neoblocks.%s.Config|{ enabled?: boolean }"):format(mod.name, mod.name)
  else
    types[#types + 1] = ("---@field %s? { enabled?: boolean }"):format(mod.name)
  end
end
write("lua/neoblocks/types.lua", types)
io.write(("docs written to %s for %d modules\n"):format(out, #modules))
