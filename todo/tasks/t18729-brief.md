## Origin

**Selected tier:** `tier:standard`

- Created 2026-10-18 by an interactive OpenCode session at a maintainer's request. A managed project repository needs a larger per-issue worker budget than the install default.

## What

Let a managed repository override the per-issue cost circuit breaker budgets (t2007) with a committed `.aidevops/dispatch-cost-budgets.conf` in its own checkout. Repositories without the file keep the install-wide budgets from `.agents/configs/dispatch-cost-budgets.conf`.

## Why

- `_get_cost_budget_for_tier` reads only the deployed framework config, so the 800K budget applies to every repository on a runner. A repository whose phases need several roughly 300K-token sessions trips the breaker after two sessions, and its continuation splits then multiply fixed per-part costs.
- Editing the deployed `~/.aidevops/agents/configs/` copy is lost on `aidevops update` and does not reach other maintainers' runners. A committed repository file is versioned, reviewed through that repository's PRs and identical on every runner.

## How

1. `.agents/scripts/dispatch-dedup-cost.sh`:
   - `_get_cost_budget_for_tier <tier> [repo_slug]`. After loading the framework config, resolve the slug's checkout from `repos.json` (`initialized_repos[].path`, honour `AIDEVOPS_REPOS_FILE`, follow `_dsi_repo_path_for_slug` in `dispatch-single-issue-helper.sh`) and read `<path>/.aidevops/dispatch-cost-budgets.conf` when present.
   - Never `source` the repository file. Parse only `^COST_BUDGET_(SIMPLE|STANDARD|THINKING|DEFAULT)=[0-9]+$` lines; ignore everything else.
   - Clamp accepted values to 100000–20000000 so a typo cannot disable or zero the breaker.
   - `_check_cost_budget` passes its `repo_slug`.
2. `.agents/configs/dispatch-cost-budgets.conf`: document the override, its parsing rules and the clamp. Also correct the stale header comment, which still says the breaker applies `needs-maintainer-review`; it applies `status:blocked`.
3. `.agents/scripts/tests/test-cost-circuit-breaker.sh`: add assertions with a fixture `repos.json` and repository file. A repository budget of 2000000 allows 900K spend; a repository without the file still blocks at 800K; a line containing a command (`COST_BUDGET_STANDARD=1; touch <marker>`) is ignored and never executed.

## Acceptance

- [ ] `bash .agents/scripts/tests/test-cost-circuit-breaker.sh` passes, including the new override assertions.
- [ ] ShellCheck reports no findings for the changed scripts.
- [ ] Repositories without the file see unchanged budgets.

### Files Scope

- .agents/scripts/dispatch-dedup-cost.sh
- .agents/configs/dispatch-cost-budgets.conf
- .agents/scripts/tests/test-cost-circuit-breaker.sh

## Dispatch

Implemented by the interactive session that filed it.
