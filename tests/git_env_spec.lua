-- runner_spec runs this file under a git hook's variables; run alone, it checks the same with none set.

--- Runs git in `dir`, without the user's or the system's config; errors when git does.
local function git(dir, ...)
  local out = vim
    .system(
      { "git", "-c", "user.name=t", "-c", "user.email=t@t", ... },
      { cwd = dir, env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" } }
    )
    :wait()
  eq(0, out.code, ("git %s: %s"):format(table.concat({ ... }, " "), out.stderr))
end

test("git run in a scratch folder makes and commits to a repo there", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  git(dir, "commit", "-q", "--allow-empty", "-m", "probe")
  ok(vim.uv.fs_stat(dir .. "/.git/HEAD") ~= nil, "git init made no repo in " .. dir)
  vim.fn.delete(dir, "rf")
end)
