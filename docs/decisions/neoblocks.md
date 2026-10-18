# neoblocks: decisions

How the repo is put together and why. Each module records its own decisions in `docs/decisions/<module>.md`.
Compared against snacks.nvim (882c996) and AH-Merii/claude-plugins on 2026-10-14.

## 1. Modules: one file each, found on 'runtimepath'

- A module is `lua/neoblocks/<name>.lua`, or `lua/neoblocks/<name>/init.lua` once it needs splitting.
  `meta.modules()` lists them from 'runtimepath', so adding one edits nothing else. snacks finds its modules the
  same way, in its own folder only (snacks `meta/init.lua:27-60`); searching 'runtimepath' also lets the tests, or a
  user's config, add one.
- Contract: `M.meta = { desc = "one line" }`, `M.setup()`, and optionally `M.refresh(buf?)` (after a switch) and
  `M.health()`. A module reads its options in `setup()`, not when it's first required: snacks reads them at require
  time (`local config = Snacks.config.get(...)` at the top of 5 modules), which is why it must not be lazy-loaded.
- Naming a module in `setup()` turns it on, `enabled = false` keeps it off (as snacks, `init.lua:139-141`). Modules
  not named are never required.
- On/off after setup is one switch for every module: `vim.b.neoblocks_<name>`, then `vim.g.neoblocks_<name>`, through
  `Neoblocks.toggle()` and `:Neoblocks[!]`. Rather than snacks' per-module enable/disable and a hand-written toggle
  for each (`toggle.lua:287-350`), a module checks `util.enabled()` where it draws.
- `_G.Neoblocks` with a lazy `__index`, as snacks (`init.lua:4-12`), so keymaps can call `Neoblocks.colors...`.
- Not taken (yet): snacks' per-module start events (a central table, `init.lua:150-156`). Every module so far is
  cheap to set up; add a `meta` field when one isn't.

## 2. Docs are generated from the code, and a bot commits them

- `scripts/docs.lua` reads each module's top comment, `meta.desc`, its `---@class neoblocks.<name>.Config` with the
  `defaults` table, and its commented `M.*` functions. It writes `docs/<module>.md`, `doc/neoblocks.txt`, README's
  module table and `lua/neoblocks/types.lua` (the options' types for lua_ls).
- Our own generator, not snacks' (721 lines over treesitter, then pandoc through panvimdoc in CI): ours reads a few
  fixed conventions line by line, writes vimdoc itself, and needs nothing but Neovim.
- After each push to main, `docs.yml` regenerates and commits as the neoblocks-docs GitHub App, which the main ruleset
  lets past. The App is installed on this repo only; each workflow asks for just the permissions it uses (contents
  write here). PRs run `check:docs`, which generates into a scratch
  folder and checks `:helptags` accepts it; they don't need to commit the generated files.

## 3. Checks are mise tasks; CI runs each as a job

- Shaped like claude-plugins: `mise-tasks/check/<name>`, each pinning its own tools in its `#MISE` header; CI has one
  job per task and a `ci-ok` job that passes only when all did, the one check the main ruleset requires.
- Checks: stylua, selene (plus no debug output in `lua/`/`plugin/`, as snacks' `dd(` check), lua-language-server (in CI
  and the pre-push hook, not `check:all`), tests on Neovim nightly, the docs generator, the PR title, gitleaks
  and zizmor + jactionlint.
- Tests: `nvim -l tests/run.lua`, no dependencies and offline; each spec file runs in its own `nvim --clean`. snacks'
  runner downloads lazy.nvim when it isn't installed (`tests/minit.lua:6-10`).
- Wrong-implementation checks are kept outside the repo, as evidence the tests catch real bugs.

## 4. One version, from release-please

- Conventional Commit PR titles (squash merges) drive release-please; merging its PR tags `vX.Y.Z`.
- release-please runs as the neoblocks-docs App (contents, issues and pull requests write), so CI runs on its release
  PR and it merges like any other. A PR opened with `GITHUB_TOKEN` gets CI only after someone approves the runs
  (GitHub changelog, 2026-06-11: "Bot-created pull requests can run workflows if approved").
- One version for the repo, not one per module: lazy.nvim's `version` only reads tags like `v1.2.3`
  (`lazy/manage/semver.lua:86`), so per-module tags (`colors-v0.1.0`) would be invisible to it.
- The version is also written to `M.version` in `lua/neoblocks/init.lua`, shown by `:checkhealth neoblocks`.
- Releases start at 0.1.0 and stay below 1.0 until the API settles: `bump-minor-pre-major` makes a breaking change
  bump the minor. The first release comes from `initial-version`: with no release tag yet, release-please ignores the
  manifest's `0.0.0` and falls back to it, or to 1.0.0 without it (`src/strategies/base.ts:756-761` in
  googleapis/release-please).

## 5. Security

- Workflows: read-only token at the top, write granted per job (release only); actions pinned to a commit SHA with
  `persist-credentials: false`; Dependabot bumps the pins weekly after a 7-day cooldown, with `ci:` titles so a bump
  cuts no release.
- gitleaks on each PR's commits and the full history on main; locally an agent hook before `but commit`, and the
  pre-push hook below.
- Locally, `.githooks/pre-push` runs CI's checks on what a push sends, so a push that passes it passes CI: each
  pushed commit is checked in a `git archive` copy (GitButler's working tree holds every applied branch and
  uncommitted edits), tests run on nightly, the type check runs capped at 1 GB (it peaked at 221 MB), and
  gitleaks scans every commit not on main. CI's PR title check has no PR to read at push time, so the hook checks
  the pushed commit subjects with the same `check:title`. `mise run setup`
  sets `core.hooksPath`, the one hook location both `git push` and `but push` run (GitButler's `pre_push()` runs only
  a hook file, never a git-config hook: `crates/gitbutler-repo/src/hooks.rs` at 2d95f37). That needs a GitButler
  build that keeps its own guard hooks in git config (gitbutlerapp/gitbutler#14698, nightly until the next release):
  earlier builds wrote them into `.git/hooks`, which `core.hooksPath` switches off. The first version installed a
  stub into `.git/hooks` instead, to leave those alone.
- Agents read AGENTS.md (CLAUDE.md links to it), which starts with `mise run setup`, and Claude Code sessions get a
  reminder when it hasn't run.
- CodeQL default setup (the `actions` language: it has no Lua), secret scanning with push protection, private
  vulnerability reporting (SECURITY.md), and a ruleset on main: ci-ok required, linear history, no force push or
  deletion; the docs App is the only bypass.
