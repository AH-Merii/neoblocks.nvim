--- A global statusline built from two lists of components, rebuilt on events and never on a cursor move. Replaces
--- [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for a statusline with one global line.
---
--- ```lua
--- {
---   "AH-Merii/neoblocks.nvim",
---   event = "VeryLazy",
---   config = function()
---     local sl = require("neoblocks.statusline")
---     require("neoblocks").setup({
---       statusline = {
---         color = { fg = "#abb2bf" },
---         left = {
---           { function() return "" end, color = sl.mode_color({ i = { fg = "#98c379" } }), padding = { right = 1 } },
---           "%f",
---           { "diagnostics", symbols = { error = "E" } },
---           "%=",
---         },
---         right = {
---           { "branch", icon = "", color = { fg = "#56b6c2", bold = true } },
---           "diff",
---           "searchcount",
---           { "%3l:%-2c", color = { bold = true } },
---         },
---       },
---     })
---   end,
--- }
--- ```
---
--- A component is a function returning statusline text, a statusline string starting with `%`, a built-in name
--- (`diagnostics`, `branch`, `diff`, `searchcount`, `progress_status`, `recording`) or a table with one of those
--- first and its options. A component draws nothing when it's empty or its `cond` isn't true; otherwise
--- `icon text` with one space each side (`padding`), as lualine draws it.
---
--- A colour is a highlight group name or a table of `nvim_set_hl()` attributes, e.g. `{ fg = "#e5c07b", bold = true }`
--- (lualine's `gui = "bold"` is `bold = true` here). A colour Neovim rejects is reported and drawn in the default one.
---
--- Text from a function or a string goes in as statusline text, unescaped, so `%l`-style items and `%{...}`
--- expressions in it follow the cursor without a rebuild; text that isn't valid statusline syntax is reported and its
--- component left out. The line is rebuilt on `events` and the events the built-ins in use need, at most once per
--- 16 ms, and at once by `refresh()`. A cursor move runs nothing, except while a search is highlighted and the line
--- has `searchcount`: then it counts the matches again, at most once per 16 ms. `diff` shows gitsigns.nvim's counts.
---@class neoblocks.statusline
local M = {}

M.meta = { desc = "A global statusline rebuilt only on events (replaces lualine.nvim)" }

---@alias neoblocks.statusline.Color string|vim.api.keyset.highlight a highlight group, or nvim_set_hl() attributes

---@class neoblocks.statusline.Config
---@field left? neoblocks.statusline.Component[] drawn from the left edge; a "%=" entry starts a centred group
---@field right? neoblocks.statusline.Component[] drawn against the right edge
---@field color? neoblocks.statusline.Color text colour of components without their own; default StatusLine's
---@field events? string[] events that rebuild the line; built-ins add their own
---@class neoblocks.statusline.ComponentOpts
---@field [1] string|fun(): string? a function, a "%..." statusline string, or a built-in name
---@field icon? string drawn before the text, with a space; left out with the text when it's empty
---@field color? neoblocks.statusline.Color|fun(): neoblocks.statusline.Color? called on each rebuild
---@field cond? fun(): boolean drawn only when it returns true
---@field on_click? fun(clicks: integer, button: string, mods: string)
---@field padding? integer|{ left?: integer, right?: integer } spaces around the text: 1 each side by default
---@field symbols? table<string, string> diagnostics: error/warn/info/hint; diff: added/modified/removed
---@field diagnostics_color? table<string, neoblocks.statusline.Color> diagnostics: a colour per severity
---@field diff_color? table<string, neoblocks.statusline.Color> diff: added/modified/removed colours
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

local api, uv = vim.api, vim.uv
local NAME = "statusline"
local DEFAULT = "NeoblocksStatusline" -- the text colour of components without their own

---@class neoblocks.statusline.Comp
---@field id integer
---@field opts neoblocks.statusline.ComponentOpts
---@field text fun(c: neoblocks.statusline.Comp): string? the component's text, before icon and padding
---@field builtin? neoblocks.statusline.Builtin
---@field lpad integer
---@field rpad integer
---@field group? string the group of a colour that isn't a function
---@field click? integer
---@field reported? boolean its error was reported
---@field var? string searchcount: the g: variable holding the padded count
---@field last? table<integer, table<string, integer>> diagnostics: the counts per buffer, for Insert mode

---@class neoblocks.statusline.Event
---@field [1] string the event
---@field pattern? string
---@field buf? fun(args: vim.api.keyset.create_autocmd.callback_args): integer? the buffer it's about, when any

---@class neoblocks.statusline.Builtin
---@field events? (string|neoblocks.statusline.Event)[]
---@field init? fun(c: neoblocks.statusline.Comp)
---@field text fun(c: neoblocks.statusline.Comp): string?

local S = {
  config = nil, ---@type neoblocks.statusline.Config?
  left = {}, ---@type neoblocks.statusline.Comp[]
  right = {}, ---@type neoblocks.statusline.Comp[]
  groups = {}, ---@type table<string, vim.api.keyset.highlight|fun(): vim.api.keyset.highlight> for ColorScheme
  keys = {}, ---@type table<string, string> colour key -> group
  n = 0, -- groups made from tables
  clicks = {}, ---@type table<integer, function>
  rebuild = { pending = false, last = -math.huge }, -- a rebuild is scheduled; when the last one ran, in ms
  recount = { pending = false, last = -math.huge }, -- the same for the search counts
  searched = "", -- the search state the counts are for
  counted = nil, ---@type string? the search state, window and cursor the counts in the g: variables are for
  drawn = false, -- the module's line is in 'statusline'
  saved = nil, ---@type { stl: string, ls: integer }? what it replaced
  saved_wo = {}, ---@type table<integer, string> window-local statuslines it cleared
  showing = false, -- the module's line, not the one it replaced, is in 'statusline'
  counting = false, -- the line carries the searchcount slots
  parts = {}, ---@type string[] the line, in pieces
  owners = {}, ---@type table<integer, neoblocks.statusline.Comp> the component that drew each piece of `parts`
  slots = {}, ---@type { at: integer, c: neoblocks.statusline.Comp, text: string }[] searchcount pieces of `parts`
}

---@param s string
local function escape(s) return (s:gsub("%%", "%%%%")) end

---@param msg string
local function report(msg) vim.notify("neoblocks.statusline: " .. msg, vim.log.levels.ERROR) end

-- Colours -----------------------------------------------------------------------------------------------------------

---@param spec vim.api.keyset.highlight|fun(): vim.api.keyset.highlight
---@return vim.api.keyset.highlight
local function resolve(spec)
  if type(spec) == "function" then
    return spec()
  end
  return spec
end

--- Defines a group, and keeps it for ColorScheme; false and the error when Neovim rejects `spec`. A function spec is
--- called again on each ColorScheme.
---@param name string
---@param spec vim.api.keyset.highlight|fun(): vim.api.keyset.highlight
---@return boolean, string?
local function define(name, spec)
  local ok, err = pcall(api.nvim_set_hl, 0, name, resolve(spec))
  if not ok then
    return false, err
  end
  S.groups[name] = spec
  return true
end

--- `color` with the default text colour's fg when it has none, as lualine fills it from the section's
--- (highlight.lua:281-308): the group is drawn over StatusLine, whose fg it would take otherwise.
---@param color vim.api.keyset.highlight
---@return vim.api.keyset.highlight|fun(): vim.api.keyset.highlight
local function with_fg(color)
  if color.fg or color.link then
    return color
  end
  return function()
    return vim.tbl_extend("keep", color, { fg = api.nvim_get_hl(0, { name = DEFAULT, link = false }).fg })
  end
end

--- A key that's the same for equal colours, so a colour function makes one group per colour, not per rebuild.
---@param color neoblocks.statusline.Color
local function key_of(color)
  if type(color) == "string" then
    return color
  end
  local keys = vim.tbl_keys(color)
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = k .. "=" .. tostring(color[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- The NeoblocksStatusline group drawing `color`, defined on first use; the default one, reported once, for a
--- colour Neovim rejects.
---@param color? neoblocks.statusline.Color
---@return string
local function group_of(color)
  if color == nil then
    return DEFAULT
  end
  local key = key_of(color)
  local name = S.keys[key]
  if not name then
    if type(color) == "string" then
      name = DEFAULT .. "_" .. color:gsub("[^%w_.@-]", "_")
      define(name, { link = color })
    else
      S.n = S.n + 1
      name = DEFAULT .. S.n
      local ok, err = define(name, with_fg(color))
      if not ok then
        report(("colour %s: %s"):format(vim.inspect(color, { newline = " ", indent = "" }), err))
        name = DEFAULT
      end
    end
    S.keys[key] = name
  end
  return name
end

-- Git ---------------------------------------------------------------------------------------------------------------

local git = {
  dirs = {}, ---@type table<string, string> folder -> git dir; only found ones, since a folder can become a repo
  miss = nil, ---@type string? "buffer folder" of the last lookup that found no repo
  watched = nil, ---@type string? the git dir whose HEAD is watched
  branch = "",
  watcher = nil, ---@type uv.uv_fs_event_t?
}

local schedule ---@type fun()

--- The git dir of the repo `dir` is in: a .git folder, or the one a .git file points to (worktrees, submodules).
---@param dir string
---@return string?
local function git_dir(dir)
  local hit = git.dirs[dir]
  if hit then
    return hit
  end
  local found ---@type string?
  local d = dir ---@type string?
  while d do
    local path = d .. "/.git"
    local st = uv.fs_stat(path)
    if st then
      local gd ---@type string?
      if st.type == "directory" then
        gd = path
      elseif st.type == "file" then
        local f = io.open(path)
        if f then
          gd = (f:read("*l") or ""):match("^gitdir: (.+)$")
          f:close()
        end
        if gd and gd:sub(1, 1) ~= "/" then
          gd = d .. "/" .. gd
        end
      end
      local head = gd and uv.fs_stat(gd .. "/HEAD")
      if gd and head and head.type == "file" then
        found = vim.fs.normalize(gd)
        break
      end
    end
    local parent = vim.fs.dirname(d)
    d = parent ~= d and parent or nil
  end
  git.dirs[dir] = found
  return found
end

--- The branch HEAD names, or the first 6 characters of a detached hash (as lualine).
---@param gd string
local function read_head(gd)
  local f = io.open(gd .. "/HEAD")
  if not f then
    return ""
  end
  local head = f:read("*l") or ""
  f:close()
  return head:match("^ref: refs/heads/(.+)$") or head:sub(1, 6)
end

--- Watches the HEAD of `gd`, and only it. git replaces the file, so the watch is set again after each change.
---@param gd? string
local function watch(gd)
  if git.watched == gd then
    return
  end
  if git.watcher then
    git.watcher:stop()
  end
  git.watched, git.branch = gd, gd and read_head(gd) or ""
  if not gd then
    return
  end
  git.watcher = git.watcher or uv.new_fs_event()
  local w = assert(git.watcher, "no fs_event handle")
  local head = gd .. "/HEAD"
  local function start()
    w:start(
      head,
      {},
      vim.schedule_wrap(function()
        if git.watched ~= gd then
          return
        end
        w:stop()
        start()
        local branch = read_head(gd)
        if branch ~= git.branch then
          git.branch = branch
          schedule()
        end
      end)
    )
  end
  start()
end

-- Built-ins ---------------------------------------------------------------------------------------------------------

local severities = { "error", "warn", "info", "hint" }
local diagnostic_hl =
  { error = "DiagnosticError", warn = "DiagnosticWarn", info = "DiagnosticInfo", hint = "DiagnosticHint" }
-- lualine's, with icons on (lualine components/diagnostics/config.lua:6-12)
local diagnostic_symbols = { error = "󰅚 ", warn = "󰀪 ", info = "󰋽 ", hint = "󰌶 " }
-- option key, gitsigns' key
local diff_keys = { { "added", "added" }, { "modified", "changed" }, { "removed", "removed" } }
local diff_hl = { added = "Added", modified = "Changed", removed = "Removed" }
local diff_symbols = { added = "+", modified = "~", removed = "-" }

---@type table<string, neoblocks.statusline.Builtin>
local builtins = {
  diagnostics = {
    events = { { "DiagnosticChanged", buf = function(args) return args.buf end }, "InsertLeave" },
    init = function(c)
      local o = c.opts
      o.symbols = vim.tbl_extend("force", diagnostic_symbols, o.symbols or {})
      o.diagnostics_color = vim.tbl_extend("force", diagnostic_hl, o.diagnostics_color or {})
      c.last = {}
    end,
    text = function(c)
      local buf = api.nvim_get_current_buf()
      local counts = c.last[buf]
      if not counts or api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
        local n, sev = vim.diagnostic.count(buf), vim.diagnostic.severity
        counts =
          { error = n[sev.ERROR] or 0, warn = n[sev.WARN] or 0, info = n[sev.INFO] or 0, hint = n[sev.HINT] or 0 }
        c.last[buf] = counts
      end
      local out = {}
      for _, s in ipairs(severities) do
        if counts[s] > 0 then
          out[#out + 1] = ("%%#%s#%s%d"):format(group_of(c.opts.diagnostics_color[s]), c.opts.symbols[s], counts[s])
        end
      end
      return table.concat(out, " ")
    end,
  },
  branch = {
    events = { "DirChanged" },
    text = function()
      local name = api.nvim_buf_get_name(0)
      -- a terminal's folder is in its name, term://<dir>//<pid>:<cmd> (lualine git_branch.lua:91-94); a name that
      -- isn't a path (none, a URI) takes the cwd's
      local term = name:match("^term://(.-)//%d+:")
      local dir = term and vim.fs.normalize(term)
        or vim.fn.isabsolutepath(name) == 1 and vim.fs.dirname(name)
        or vim.fn.getcwd()
      -- outside a repo the lookup walks up to /: it's done again for another buffer or folder, or refresh(), as
      -- lualine's on BufEnter (git_branch.lua:137-143), not on each rebuild
      local key = api.nvim_get_current_buf() .. " " .. dir
      if git.miss ~= key then
        local gd = git_dir(dir)
        git.miss = not gd and key or nil
        watch(gd)
      end
      return escape(git.branch)
    end,
  },
  diff = {
    events = { { "User", pattern = "GitSignsUpdate", buf = function(args) return args.data and args.data.buffer end } },
    init = function(c)
      c.opts.symbols = vim.tbl_extend("force", diff_symbols, c.opts.symbols or {})
      c.opts.diff_color = vim.tbl_extend("force", diff_hl, c.opts.diff_color or {})
    end,
    text = function(c)
      local d = vim.b.gitsigns_status_dict
      if type(d) ~= "table" then
        return ""
      end
      local out = {}
      for _, k in ipairs(diff_keys) do
        local n = tonumber(d[k[2]]) or 0
        if n > 0 then
          out[#out + 1] = ("%%#%s#%s%d"):format(group_of(c.opts.diff_color[k[1]]), c.opts.symbols[k[1]], n)
        end
      end
      return table.concat(out, " ")
    end,
  },
  -- an expression over a variable holding the count: :nohlsearch hides it with no event, and a move while a search
  -- is highlighted updates the variable, not the line
  searchcount = {
    init = function(c) c.var = "neoblocks_statusline_search" .. c.id end,
    text = function(c) return ("%%{v:hlsearch ? get(g:, '%s', '') : ''}"):format(c.var) end,
  },
  progress_status = {
    events = { "Progress" },
    -- it starts tracking Progress events on its first call
    init = function() vim.ui.progress_status() end,
    text = function()
      -- 0.12 returns "40%%(1) ", nightly "40%(1)"
      return escape(vim.trim((vim.ui.progress_status():gsub("%%%%", "%%"))))
    end,
  },
  recording = {
    events = { "RecordingEnter", "RecordingLeave" },
    text = function()
      local reg = vim.fn.reg_recording()
      return reg ~= "" and "@" .. escape(reg) or ""
    end,
  },
}

-- Drawing -----------------------------------------------------------------------------------------------------------

--- `icon text` with the component's padding. As lualine's (component.lua:97-115), the left padding goes after a
--- colour the text starts with, and the right one before a closing `%*` after a colour change, so they take the
--- text's colour, which shows in a group with a background and in the `<` of a truncated line.
---@param c neoblocks.statusline.Comp
---@param text string
local function pad(c, text)
  if c.opts.icon then
    text = c.opts.icon .. " " .. text
  end
  local head = text:match("^%%#.-#") or ""
  local tail = text:find("%%#.*#.*%%%*$") and "%*" or ""
  return head .. (" "):rep(c.lpad) .. text:sub(#head + 1, #text - #tail) .. (" "):rep(c.rpad) .. tail
end

---@param c neoblocks.statusline.Comp
---@return string text, string group, string? invalid the padded text, with its click; why it isn't valid statusline
local function draw_one(c)
  local o = c.opts
  if o.cond and o.cond() ~= true then
    return "", DEFAULT
  end
  local text = c.text(c)
  if type(text) == "number" then
    text = tostring(text)
  end
  if type(text) ~= "string" or text == "" then
    return "", DEFAULT
  end
  text = pad(c, text)
  -- a lone % at the end escapes the % of what's written after it (the colour, the click's end), so Neovim takes it
  local tail = text:match("%%+$")
  if tail and #tail % 2 == 1 then
    local ok, err = pcall(api.nvim_eval_statusline, text, {})
    return "", DEFAULT, ok and "a lone % at the end" or tostring(err)
  end
  if c.var then
    -- a %{} result's spaces are drawn as fill characters, so the padding is outside it, in a group that's left out
    -- with its icon and padding while the count is empty
    text = "%(" .. text .. "%)"
  end
  if c.click then
    text = ("%%%d@v:lua.require'neoblocks.statusline'._click@%s%%T"):format(c.click, text)
  end
  local group = c.group
  if not group then
    local color = o.color --[[@as fun(): neoblocks.statusline.Color?]]
    group = group_of(color())
  end
  return text, group
end

---@param c neoblocks.statusline.Comp
---@param err string
local function report_invalid(c, err)
  if not c.reported then
    c.reported = true
    report(("component %d drew invalid statusline text: %s"):format(c.id, err))
  end
end

--- A component's statusline text in its colour, the default colour again after it; nothing when it errors or its
--- text isn't valid, reported once.
---@param c neoblocks.statusline.Comp
---@return string
local function draw(c)
  local ok, text, group, invalid = pcall(draw_one, c)
  if not ok then
    if not c.reported then
      c.reported = true
      report(("component %d failed: %s"):format(c.id, text))
    end
    return ""
  elseif invalid then
    report_invalid(c, invalid)
    return ""
  elseif text == "" then
    return ""
  elseif group ~= DEFAULT then
    -- the line is in the default colour between components, as lualine's (component.lua:119-138)
    return "%#" .. group .. "#" .. text .. "%#" .. DEFAULT .. "#"
  elseif text:find("%", 1, true) then
    -- any item may change the colour: %#Group#, %1*, %*
    return text .. "%#" .. DEFAULT .. "#"
  end
  return text
end

--- What a search count depends on, besides the cursor: the highlight, the pattern, the buffer and its text.
local function search_state()
  local buf = api.nvim_get_current_buf()
  return ("%d:%d:%d:%s"):format(vim.v.hlsearch, buf, api.nvim_buf_get_changedtick(buf), vim.fn.getreg("/"))
end

--- Puts the searchcount slots in the line while a search is highlighted, and counts its matches: Neovim evaluates
--- their expression on every draw, so the line carries it only while it can show something. It counts only when the
--- search state, the window or the cursor changed since the last count: a rebuild and a move in the same tick count
--- once.
---@return boolean counted whether a count changed
local function update_searches()
  local on, counted = vim.v.hlsearch == 1, false
  S.searched = search_state()
  local stale = false
  if on and #S.slots > 0 then
    local pos = api.nvim_win_get_cursor(0)
    local key = ("%s:%d:%d:%d"):format(S.searched, api.nvim_get_current_win(), pos[1], pos[2])
    stale = key ~= S.counted
    if stale then
      S.counted, S.recount.last = key, uv.hrtime() / 1e6
    end
  end
  for _, slot in ipairs(S.slots) do
    local c = slot.c
    if stale then
      -- lualine's limits (components/searchcount.lua:3-6)
      local ok, r = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 500 })
      local count = ok and next(r) ~= nil and ("[%d/%d]"):format(r.current, math.min(r.total, r.maxcount)) or ""
      if vim.g[c.var] ~= count then
        vim.g[c.var] = count
        counted = true
      end
    end
    S.parts[slot.at] = on and slot.text or ""
  end
  S.counting = on
  return counted
end

--- Rebuilds the parts of the line: every component's text, and a slot for each searchcount.
local function rebuild_parts()
  local parts, slots, owners = { "%<%#" .. DEFAULT .. "#" }, {}, {}
  local function add(list)
    for _, c in ipairs(list) do
      parts[#parts + 1] = draw(c)
      owners[#parts] = c
      if c.var then
        slots[#slots + 1] = { at = #parts, c = c, text = parts[#parts] }
      end
    end
  end
  add(S.left)
  parts[#parts + 1] = "%="
  add(S.right)
  S.parts, S.slots, S.owners = parts, slots, owners
end

--- Puts `line` in 'statusline' unless it's there already; false when Neovim rejects it.
---@param line string
---@return boolean
local function apply(line)
  if vim.go.statusline == line then
    return true
  end
  if not pcall(function() vim.go.statusline = line end) then
    return false
  end
  -- Neovim doesn't redraw the statusline while the command line is open (lualine does the same,
  -- utils/nvim_opts.lua:63-66)
  if api.nvim_get_mode().mode:sub(1, 1) == "c" then
    vim.cmd.redrawstatus()
  end
  return true
end

--- Puts the line on the screen: writes 'statusline' when the line changed, or redraws it when only a count did, since
--- Neovim doesn't watch the g: variables the counts are in. False when Neovim rejects the line.
---@param counted boolean
---@return boolean
local function show(counted)
  local line = table.concat(S.parts)
  if vim.go.statusline ~= line then
    return apply(line)
  elseif counted then
    vim.cmd.redrawstatus()
  end
  return true
end

--- Leaves out the pieces of the line that aren't valid statusline syntax (a component's stray `%`), each reported
--- once; only after Neovim rejected the whole line.
local function drop_invalid()
  for i, c in pairs(S.owners) do
    local ok, err = pcall(api.nvim_eval_statusline, S.parts[i], {})
    if not ok then
      S.parts[i] = ""
      for _, slot in ipairs(S.slots) do
        if slot.at == i then
          slot.text = ""
        end
      end
      report_invalid(c, tostring(err))
    end
  end
end

local function restore_windows()
  for win, stl in pairs(S.saved_wo) do
    if api.nvim_win_is_valid(win) and api.nvim_get_option_value("statusline", { scope = "local", win = win }) == "" then
      api.nvim_set_option_value("statusline", stl, { scope = "local", win = win })
    end
  end
  S.saved_wo = {}
end

--- Draws the line for the current buffer, or puts back what it replaced where the module is off.
local function build()
  S.rebuild.pending, S.rebuild.last = false, uv.hrtime() / 1e6
  if not S.config then
    return
  end
  local util = require("neoblocks.util")
  if not util.enabled(NAME, api.nvim_get_current_buf()) then
    if not S.drawn or not S.saved then
      return
    elseif util.enabled(NAME) then
      -- off in this buffer only: the line it replaced shows while the buffer is current
      apply(S.saved.stl)
      S.showing = false
    else
      apply(S.saved.stl)
      vim.go.laststatus = S.saved.ls
      restore_windows()
      S.drawn, S.showing = false, false
    end
    return
  end
  if not S.drawn then
    -- what's there now, also after an off/on: off puts back what it replaced last
    S.saved = { stl = vim.go.statusline, ls = vim.go.laststatus }
    S.drawn = true
    vim.go.laststatus = 3
  end
  -- a window's own statusline (quickfix's) would hide the global one
  local win = api.nvim_get_current_win()
  local own = api.nvim_get_option_value("statusline", { scope = "local", win = win })
  if own ~= "" then
    S.saved_wo[win] = own
    api.nvim_set_option_value("statusline", "", { scope = "local", win = win })
  end
  rebuild_parts()
  local counted = update_searches()
  S.showing = true
  if not show(counted) then
    drop_invalid()
    apply(table.concat(S.parts))
  end
end

local INTERVAL = 16 -- ms: at most one rebuild or recount this often, as lualine's queue (lualine.lua:370-376)

--- Runs `run` once however often it's asked, after the other handlers of what asked: on the next loop tick, or 16 ms
--- after `t.last` when that's later.
---@param t { pending: boolean, last: number }
---@param run fun()
local function throttle(t, run)
  if t.pending then
    return
  end
  t.pending = true
  local wait = t.last + INTERVAL - uv.hrtime() / 1e6
  if wait > 0 then
    vim.defer_fn(run, math.ceil(wait))
  else
    vim.schedule(run)
  end
end

--- One rebuild however many events ask for it, so a burst of events (progress, gitsigns) costs one per 16 ms.
schedule = function() throttle(S.rebuild, build) end

--- Counts the searches again, and draws the line only when a count changed.
local function recount()
  S.recount.pending = false
  if not S.showing then
    return
  end
  show(update_searches())
end

-- Setup -------------------------------------------------------------------------------------------------------------

---@param spec neoblocks.statusline.Component
---@param id integer
---@return neoblocks.statusline.Comp?
local function component(spec, id)
  local opts ---@type neoblocks.statusline.ComponentOpts
  if type(spec) == "table" then
    opts = spec
  else
    opts = {
      spec --[[@as string|fun(): string?]],
    }
  end
  local first = opts[1]
  local c = { id = id, opts = opts, text = function() end, lpad = 1, rpad = 1 } ---@type neoblocks.statusline.Comp
  if type(first) == "function" then
    c.text = function() return first() end
  elseif type(first) == "string" and builtins[first] then
    c.builtin = builtins[first]
    c.text = c.builtin.text
  elseif type(first) == "string" and first:sub(1, 1) == "%" then
    c.text = function() return first end
  else
    local names = vim.tbl_keys(builtins)
    table.sort(names)
    report(
      ("%s is not a component: give a function, a statusline string starting with %%, or one of %s"):format(
        vim.inspect(first),
        table.concat(names, ", ")
      )
    )
    return nil
  end
  local p = opts.padding
  if p == nil then
    p = 1
  end
  if type(p) == "number" then
    c.lpad, c.rpad = p, p
  else
    c.lpad, c.rpad = p.left or 0, p.right or 0
  end
  if type(opts.color) ~= "function" then
    c.group = group_of(opts.color --[[@as neoblocks.statusline.Color?]])
  end
  if opts.on_click then
    c.click = id
    S.clicks[id] = opts.on_click
  end
  if c.builtin and c.builtin.init then
    c.builtin.init(c)
  end
  return c
end

local function comps() return vim.list_extend(vim.list_slice(S.left), S.right) end

---@param config neoblocks.statusline.Config
local function autocmds(config)
  local group = api.nvim_create_augroup("neoblocks.statusline", { clear = true })
  -- "event pattern" -> the event; one the user listed rebuilds for any buffer, not only the current one
  local events = {} ---@type table<string, neoblocks.statusline.Event>
  ---@param e string|neoblocks.statusline.Event
  local function add(e)
    local ev = type(e) == "table" and e or { e }
    local key = ev[1]:lower() .. " " .. (ev.pattern or "")
    if not events[key] or events[key].buf then
      events[key] = ev
    end
  end
  for _, e in ipairs(config.events or {}) do
    add(e)
  end
  for _, c in ipairs(comps()) do
    for _, e in ipairs(c.builtin and c.builtin.events or {}) do
      add(e)
    end
  end
  for _, ev in pairs(events) do
    local buf_of = ev.buf
    -- a name that isn't an event is reported, and the rest set up (decision 2)
    local ok, err = pcall(api.nvim_create_autocmd, ev[1], {
      group = group,
      pattern = ev.pattern,
      callback = function(args)
        local buf = buf_of and buf_of(args)
        if buf == nil or buf == api.nvim_get_current_buf() then
          schedule()
        end
      end,
    })
    if not ok then
      report(("events: %s"):format(err))
    end
  end
  if vim.iter(comps()):any(function(c) return c.var ~= nil end) then
    -- only the count, only while a search is highlighted (decision 6), and at most once per 16 ms: a scroll
    -- animation moves the cursor more often than that
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = group,
      callback = function()
        -- nothing to do while no search is highlighted and the line carries no count
        if S.showing and (vim.v.hlsearch == 1 or S.counting) then
          throttle(S.recount, recount)
        end
      end,
    })
    -- what changes the count without a move (*, n on the only match, :nohlsearch, an edit) is followed by SafeState
    api.nvim_create_autocmd("SafeState", {
      group = group,
      callback = function()
        if S.showing and (vim.v.hlsearch == 1 or S.counting) and search_state() ~= S.searched then
          throttle(S.recount, recount)
        end
      end,
    })
  end
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      -- the default first: the others' missing fg is read from it
      api.nvim_set_hl(0, DEFAULT, resolve(S.groups[DEFAULT]))
      for name, spec in pairs(S.groups) do
        api.nvim_set_hl(0, name, resolve(spec))
      end
      schedule()
    end,
  })
end

--- Starts the statusline with the options given to `setup()`.
function M.setup()
  local config = require("neoblocks.config").get(NAME, defaults)
  S.config, S.left, S.right, S.clicks, S.parts, S.slots, S.owners = config, {}, {}, {}, {}, {}, {}
  S.groups, S.keys, S.n, S.counted = {}, {}, 0, nil
  local color = config.color
  local ok, err =
    define(DEFAULT, color == nil and {} or type(color) == "string" and { link = color } or color --[[@as table]])
  if not ok then
    report(("colour %s: %s"):format(vim.inspect(color, { newline = " ", indent = "" }), err))
    define(DEFAULT, {})
  end
  local id = 0
  for _, side in ipairs({ { config.left, S.left }, { config.right, S.right } }) do
    for _, spec in ipairs(side[1] or {}) do
      id = id + 1
      local c = component(spec, id)
      if c then
        table.insert(side[2], c)
      end
    end
  end
  autocmds(config)
  build()
end

--- Rebuilds the statusline now; after `:Neoblocks statusline off` it puts back the statusline it replaced.
---@param buf? integer
function M.refresh(buf)
  local _ = buf -- one global line: it shows the current buffer whichever buffer was switched
  git.miss = nil
  build()
end

--- A colour function for `color`, picking the colour for the current mode.
---@param colors table<string,neoblocks.statusline.Color> keyed by the first letter of `mode()`: n, i, v, V, ...
---@param fallback? neoblocks.statusline.Color for any other mode
---@return fun():neoblocks.statusline.Color?
function M.mode_color(colors, fallback)
  return function() return colors[vim.fn.mode()] or fallback end
end

---@private
function M._click(id, clicks, button, mods)
  local fn = S.clicks[id]
  if fn then
    fn(clicks, button, mods)
  end
end

function M.health()
  local h = vim.health
  h.ok(("%d components on the left, %d on the right"):format(#S.left, #S.right))
  if vim.iter(comps()):any(function(c) return c.builtin == builtins.diff end) then
    -- installed but not loaded yet (lazy-loaded): gitsigns ships lua/gitsigns.lua
    local installed = vim
      .iter({ "lua/gitsigns.lua", "lua/gitsigns/init.lua" })
      :any(function(f) return #api.nvim_get_runtime_file(f, false) > 0 end)
    if package.loaded.gitsigns or installed then
      h.ok("diff: gitsigns.nvim found")
    else
      h.warn("diff shows nothing without gitsigns.nvim: it draws gitsigns' counts")
    end
  end
end

return M
