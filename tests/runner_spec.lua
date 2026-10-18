-- A git hook runs with GIT_DIR, GIT_INDEX_FILE and others set to the pushing repo. The pre-push hook runs these
-- tests, and a spec's `git init` or `git commit` in a scratch folder then went to that repo: in a linked worktree it
-- set core.bare and moved main.

--- Runs git in `dir` with no git variables but the config ones; returns its trimmed stdout.
local function git(dir, ...)
  local out = vim
    .system(
      { "git", "-c", "user.name=t", "-c", "user.email=t@t", ... },
      { cwd = dir, env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" } }
    )
    :wait()
  return vim.trim(out.stdout), out.code
end

test("specs run under a git hook's variables leave the hook's repo alone", function()
  local hook = vim.fn.tempname()
  vim.fn.mkdir(hook, "p")
  git(hook, "init", "-q", "-b", "main")
  git(hook, "commit", "-q", "--allow-empty", "-m", "the hook's repo")
  local refs = git(hook, "for-each-ref", "--format=%(refname) %(objectname)")
  ok(refs:match("^refs/heads/main %x+$"), "setup: " .. refs)

  local gitdir = hook .. "/.git"
  local out = vim
    .system({ vim.v.progpath, "--clean", "--headless", "-l", vim.fn.getcwd() .. "/tests/run.lua", "git_env" }, {
      env = { GIT_DIR = gitdir, GIT_INDEX_FILE = gitdir .. "/index", GIT_PREFIX = "" },
    })
    :wait()
  eq(0, out.code, out.stdout .. out.stderr)
  ok(out.stdout:find("ok   git run in a scratch folder", 1, true), "git_env_spec didn't run: " .. out.stdout)
  eq(refs, (git(hook, "for-each-ref", "--format=%(refname) %(objectname)")))
  local bare, code = git(hook, "config", "--get", "core.bare")
  eq({ "false", 0 }, { bare, code })
  vim.fn.delete(hook, "rf")
end)
