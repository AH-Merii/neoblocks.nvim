# Contributing

## Setup

Every check is a [mise](https://mise.jdx.dev) task, each pinning its own tools, and runs the same way locally and
in CI.

```sh
mise run setup            # once: install the pre-push secret scan
mise run check:all        # every check CI runs, except the type check (CI only: it's heavy)
mise run check:test       # the tests; NVIM=nightly mise run check:test for nightly
mise run fmt              # format with stylua
mise tasks                # everything else
```

## Adding a module

A module is `lua/neoblocks/<name>.lua`, or `lua/neoblocks/<name>/init.lua` once it needs splitting. It's found
automatically; nothing else lists it. It has:

- `M.meta = { desc = "one line" }`;
- `M.setup()`, which reads its options with `require("neoblocks.config").get("<name>", defaults)`;
- optionally `M.refresh(buf?)`, called after it's switched on or off, and `M.health()` for `:checkhealth`.

It checks `require("neoblocks.util").enabled("<name>", buf)` wherever it does its work, so `:Neoblocks` and
`vim.b`/`vim.g.neoblocks_<name>` switch it. Each module also gets tests (`tests/<name>_spec.lua`), a benchmark against
the plugin it replaces (`bench/<name>.lua`) and its decisions (`docs/decisions/<name>.md`).

## Docs come from the code

`scripts/docs.lua` (`mise run docs`) generates `docs/<module>.md`, `doc/neoblocks.txt`, the module table in README.md
and `lua/neoblocks/types.lua` from each module's source:

- the `---` comment block at the top of the file: what the module is and how to use it (markdown);
- `M.meta.desc`;
- the `---@class neoblocks.<name>.Config` annotation and the `local defaults = {...}` table under it;
- each `function M.<name>(...)` with a `---` comment above it, and its `@param`/`@return` lines. Leave a function
  uncommented, or mark it `@private`, to keep it out.

Don't edit the generated files by hand: change the comments. You don't need to commit them either; after each merge
to main a bot regenerates them and commits the result.

## Tests

`nvim -l tests/run.lua [name...]` runs `tests/*_spec.lua`, each file in its own `nvim --clean`, offline. A spec calls
`test(name, fn)`, and inside it `eq(want, got)` and `ok(cond, msg)`; `fresh()` gives a newly loaded `neoblocks` for a
test that needs `setup()` again. Name tests for the rule they check.

## Pull requests

- PRs are squash-merged, so the PR title becomes the commit: a [Conventional Commit](https://www.conventionalcommits.org)
  title, scoped to the module where there is one, e.g. `fix(colors): a swatch follows its color when the line changes`.
- `ci-ok` must pass; it passes when every check does.
- [release-please](https://github.com/googleapis/release-please) turns `feat` and `fix` titles into the next
  version and its changelog.

Design decisions and their reasons are in [docs/decisions/](docs/decisions/neoblocks.md).
