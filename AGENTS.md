# Agents

Before starting work in a new clone, run:

```sh
mise trust && mise run setup
```

It points git at `.githooks/`, so every push, with `git push` or `but push`, runs CI's checks first; `git config
core.hooksPath` prints `.githooks` once it's done. Don't skip the hook with `--no-verify`: fix what it reports.

How the repo works, its checks and its conventions are in [CONTRIBUTING.md](CONTRIBUTING.md).
