<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2737: multi-runtime version freshness for framework status greeting

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `runtime-registry.sh greeting multi-runtime` / `runtime version multi-runtime registry` — 0 hits. Fresh ground.
- [x] Discovery pass: `git log --since="3 days" --oneline -- .agents/scripts/generate-runtime-config.sh` shows only the t2736 merge (`677a2b57b`, 2026-04-22) touching `_generate_agents_opencode`. `gh pr list --state open --search "runtime-registry"` returned no collisions.
- [x] Upstream dependency check: `anomalyco/opencode#23879` (dismissible toasts) filed 2026-04-22 but NOT on the critical path for this parent — toast UX is orthogonal to version freshness.
- [x] Tier: N/A at parent level. Child phases get their own tiers when claimed (Phase A likely `tier:standard`, Phase B likely `tier:standard`, Phase C likely `tier:simple` per runtime).

## Stub — canonical brief is the issue body

This parent task uses the worker-ready issue body as its canonical brief (t2417 pattern — 6 of 7 heading signals present: Session Origin, What, Why, How, Files to modify, Acceptance; plus PR Conventions, Scope). See [GH#20471](https://github.com/marcusquinn/aidevops/issues/20471).

## Decomposition status

- **Phase A — foundation** (`rt_version` / `rt_display_name` helpers, `greeting-cache-helper.sh`, `_generate_agents` parameterisation): not started. Will get its own task ID + child issue when ready to dispatch.
- **Phase B — Claude Code wire**: blocked on Phase A merge.
- **Phase C — remaining runtimes** (Codex, Droid, Aider, Cursor, Continue): not started; filed per-runtime as user demand surfaces. Phase A's abstractions should keep each child under ~2h.

## PR conventions (parent-task rule)

Each phase PR uses `For #20471` or `Ref #20471` in its body — never `Closes`/`Fixes`/`Resolves`. Only the final phase PR (when all runtimes wired and parent ready to close) uses `Closes #20471`. Enforced by `.github/workflows/parent-task-keyword-check.yml`.

## Related

- **Blocks on**: none.
- **Supersedes pattern of**: t2730 (runtime-identity line in heredoc, ineffective because it targeted the deprecated generator), t2736 (cache-read for OpenCode — this parent generalises it).
- **Adjacent / orthogonal**: `anomalyco/opencode#23879` (dismissible toasts).
