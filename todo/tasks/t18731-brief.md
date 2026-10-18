## What

Make `qlty-cli.sh` work locally without a Qlty account, and in linked worktrees.

## Why

The Qlty CLI runs fully offline once a repo has `.qlty/qlty.toml` (verified with Qlty CLI v0.657.0: `qlty init --yes`, `qlty check`, `qlty smells --all` with no credentials). It uses no GitHub App analysis minutes. But the aidevops wrapper blocks this:

- `check`, `fmt` and `smells` call `load_api_config`, which returns 1 when no credentials exist; under `set -euo pipefail` the script exits after printing the "No Qlty credentials found" warning, before running Qlty. `monitor-code-review.sh` (`qlty-cli.sh check 5`) fails the same way.
- `init` tests `[[ -d .git ]]`, which is false in linked worktrees (`.git` is a file), so it refuses to run where interactive work happens.
- `init` runs `qlty init` interactively; agents need `--yes`.

## How

- `.agents/scripts/qlty-cli.sh`: `load_api_config` returns 0 with an info line when credentials are absent (credentials are only for Qlty Cloud features). `init_qlty` uses `git rev-parse --is-inside-work-tree` and `qlty init --yes`. Help text states credentials are optional.
- `.agents/tools/code-review/qlty.md`: Quick Reference states local use needs no account or credentials, how to initialise, and how to keep `.qlty/` uncommitted for local-only use.

### Files Scope

- `.agents/scripts/qlty-cli.sh`
- `.agents/tools/code-review/qlty.md`

## Acceptance Criteria

- With no Qlty credentials, `qlty-cli.sh check 5` and `qlty-cli.sh smells --all` run Qlty in an initialised repo.
- `qlty-cli.sh init` succeeds in a linked worktree.
- ShellCheck passes for `qlty-cli.sh`.
