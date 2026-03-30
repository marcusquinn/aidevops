---
description: Shared learnings graduated from local memory across all users
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
---

# Graduated Learnings

Validated patterns promoted from local memory. Qualify at high confidence or 3+ accesses.
Managed by `memory-graduate-helper.sh graduate` / `memory-helper.sh graduate [candidates|graduate|status]`.

---

## Anti-Patterns

- **PostgreSQL for memory** adds deployment complexity — SQLite FTS5 is simpler. *(9x)*
- **Haiku on complex shell refactors** misses edge cases with many conditionals. Use sonnet+. *(3x)*
- **Mentioning issues in summary text** without logging them as TODOs loses improvements. Fix: every sentence describing a bug → either fix it now or add a TODO entry. Do not batch to end of session. *(1x)*

## Architecture Decisions

- **YAML handoffs** are more token-efficient than markdown (~400 vs ~2000 tokens).
- **Mailbox** uses SQLite (`mailbox.db`) not TOON files. Prune shows storage report by default; `--force` to delete. Migration from TOON runs automatically on `aidevops update`. *(8x)*
- **Agent lifecycle tiers**: `draft/` (R&D, orchestration-created), `custom/` (private, permanent), shared (`.agents/` via PR). Both `draft/` and `custom/` survive `setup.sh`. *(3x)*
- **Bugs found during a task** must be logged as TODOs IMMEDIATELY — not deferred to end of session. Deferring loses context. *(1x)*
- **Content generation tasks** (images, video, UGC, ads): ALWAYS read domain subagents BEFORE generating. `content/production-image.md` has JSON prompt templates; `tools/video/video-prompt-design.md` has the 7-component format; `content/story.md` has hook frameworks. *(1x)*
- **UGC multi-shot content**: generate ALL shots (not just hero), assemble with `ffmpeg`, output assembled video as primary deliverable. Individual clips are intermediates. *(1x)*
- **Orphaned PR scanner needed**: workers create PRs but supervisor records `task_only`/`no_pr` when (1) worker emits `TASK_COMPLETE` instead of `FULL_LOOP_COMPLETE`, (2) PR created after signal, or (3) `evaluate_worker` fails to parse PR URL. Fix: Phase 3c in pulse — `gh pr list --state open --head feature/tXXX` for tasks in complete/deployed/failed with no `pr_url`. Caught t199.2 (PR #849), t199.3 (PR #846), t199.5 (PR #872) manually.
- **OpenCode system prompt override**: `prompt` field in `opencode.json` replaces `anthropic_default` (not appends). All active agents must have `build.txt` set or fall back to upstream `anthropic.txt`. *(1x)*

## Configuration & Preferences

- **Conventional commits with scope**: `feat(memory): description` *(4x)*
- **User-facing generated assets** → `~/Downloads/` for interactive sessions. Do NOT use `~/.aidevops/.agent-workspace/` — invisible to user in Finder. Reserve `.agent-workspace` for headless/pipeline runs.
- **Runtime identity**: always use the app name from version-check output. Misidentifying (e.g., Claude Code vs OpenCode) leads to wrong config paths, CLI commands, and prompt loading assumptions.

## Patterns & Best Practices

- **Phase-based task breakdown** (4 phases, separate commits) worked well for complex feature adoption. *(3x)*
- **Opus for race condition root cause**: reasoning through concurrent execution paths identified the issue. *(2x)*
- **Memory daemon** should auto-extract learnings from thinking blocks when sessions end. *(5x)*
- **Task ID collision** (t264 assigned twice): always `git pull` and re-read TODO.md before assigning IDs. The pre-dispatch check catches it. *(1x)*
- **Stale TODO.md**: `update_todo_on_complete()` only runs during post-PR lifecycle. Cross-session merges leave TODO.md out of sync. Fix: `supervisor-helper.sh reconcile-todo` periodically; workers check `task_obsolete` before starting.

## Solutions & Fixes

- **Deploying auto-recovery infinite loop** (t263/PR #1036): `retry_count` was LOCAL and reset every pulse cycle. Fixed with persistent `deploying_recovery_attempts` DB column, max 10 attempts, fallback direct SQL UPDATE.
- **Pulse silent failure** with `set -euo pipefail`: Phase 3 called with `2>/dev/null || true` — crashes silently, pulse exits after printing only the header. Diagnosis: check `post-pr.log` for repeated entries.
- **Bash `declare -A` + `set -u`** = unbound variable on empty arrays. Use newline-delimited string + grep for portable `set -u`-safe lookups. Fixed in `issue-sync-helper.sh` PR #1086.
- **Parallel worker PRs on dependency chains** create merge conflicts. Dispatch sequentially respecting `blocked-by`, or use a single worker for the plan. (t008.1-4, t012.3-5)
- **Decomposition workers marking parent `#plan` tasks `[x]`** is a known bug (t278). Always verify subtask completion before marking parent done.
- **`issue-sync find_closing_pr()` format mismatch**: `pr:#NNN` in TODO.md vs `PR #NNN` in regex → close comments silently omit PR reference. Fixed in t291/PR#1129.
- **Cron supervisor pulse on macOS** (PR #780): requires (1) `/usr/sbin` in PATH for `sysctl`, (2) `GH_TOKEN` cached to file (`~/.aidevops/.agent-workspace/supervisor/.gh-token-cache`) since macOS keyring is inaccessible from cron, (3) `get_aidevops_identity` must validate `gh api` output is not a JSON error. *(52x)*
- **Script deploy lag** (37x): after merging PRs that modify `.agents/scripts/`, the deployed copy at `~/.aidevops/agents/scripts/` is NOT auto-updated. Run `aidevops update` or `rsync -a --exclude=loop-state/ --exclude=custom/ --exclude=draft/ ~/Git/aidevops/.agents/ ~/.aidevops/agents/` after merging script changes.
