---
description: Shared learnings graduated from local memory across all users
mode: subagent
tools: { read: true, write: false, edit: false, bash: false, glob: false, grep: false, webfetch: false }
---

# Graduated Learnings

Validated patterns promoted from local memory (3+ accesses or high confidence).
Manage: `memory-graduate-helper.sh` · `memory-helper.sh graduate [candidates|graduate|status]`

## Anti-Patterns

- PostgreSQL for memory adds deployment complexity — SQLite FTS5 is simpler *(high, 9x)*
- [task:refactor] Haiku missed edge cases on complex shell scripts with many conditionals [model:haiku] *(high, 3x)*
- Log issues immediately on discovery — don't mention in summary and defer *(high, 1x)*

## Architecture Decisions

- YAML handoffs more token-efficient than markdown (~400 vs ~2000 tokens) *(high, 0x)*
- Mailbox uses SQLite (`mailbox.db`) not TOON files. Prune shows storage report by default; `--force` to delete. Migration from TOON runs automatically on `aidevops update` *(medium, 8x)*
- Agent lifecycle: three tiers — `draft/` (R&D), `custom/` (private, permanent), shared (`.agents/` via PR). Both survive `setup.sh`. Orchestration agents can create drafts and propose them for inclusion *(medium, 3x)*
- Content generation (images, video, UGC, ads): read domain subagents first — structured templates outperform freehand *(high, 1x)*
- UGC content: generate all shots, assemble with `ffmpeg` transitions, output final sequence (not individual clips) *(high, 1x)*
- CRITICAL: Supervisor needs orphaned PR scanner (Phase 3c). Workers emit `TASK_COMPLETE` before PR, or `evaluate_worker` fails to parse PR URL. Fix: scan `gh pr list --state open --head feature/tXXX` for tasks with `task_only`/`no_pr`/NULL `pr_url`. Would catch t199.2 (PR #849), t199.3 (PR #846), t199.5 (PR #872) *(high, 0x)*

## Configuration & Preferences

- Prefer conventional commits with scope: `feat(memory): description` *(medium, 4x)*
- User-facing assets → `~/Downloads/` for immediate review. Reserve `.agent-workspace` for headless/pipeline runs only *(high, 0x)*
- Runtime identity: use version-check output, don't guess — wrong identity → wrong config paths and CLI commands *(high, 0x)*

## Patterns & Best Practices

- [task:feature] Breaking task into 4 phases with separate commits worked well for Claude-Flow feature adoption [model:sonnet] *(high, 3x)*
- [task:bugfix] Opus identified root cause of race condition by reasoning through concurrent execution paths [model:opus] *(high, 2x)*
- Memory daemon should auto-extract learnings from thinking blocks when sessions end *(medium, 5x)*
- OpenCode: `prompt` field in `opencode.json` replaces (not appends) `anthropic_default`. All active agents must have `build.txt` set or fall back to upstream `anthropic.txt`, losing aidevops overrides *(high, 1x)*
- Task ID collision: t264 assigned by two sessions simultaneously (PR #1040 vs version-manager fix). Prevention: `git pull` and re-read TODO.md before assigning IDs *(high, 1x)*
- Stale TODO.md: completed tasks (t231 PR #955, t247, t259 PR #1020) remain open because `update_todo_on_complete()` only runs post-PR. Fix: use `task-complete-helper.sh`; workers report `task_obsolete` *(high, 0x)*
- [task:feature] t136.5: Scaffold aidevops-pro/anon repos | PR #792 | [model:opus] [duration:1206s] *(medium, 51x)*

## Solutions & Fixes

- Auto-recovery infinite loop: `retry_count` was LOCAL, reset every pulse cycle. Fixed t263 (PR #1036): persistent `deploying_recovery_attempts` DB column, max 10 attempts, fallback SQL UPDATE *(high, 0x)*
- Pulse silent failure: Phase 3 called with `2>/dev/null || true` masks crashes. Symptom: only header printed. Diagnosis: check `post-pr.log` for repeated entries *(high, 0x)*
- Bash `declare -A` + `set -u` = unbound variable on empty arrays. Use newline-delimited string + grep for portable `set -u`-safe lookups. Fixed `issue-sync-helper.sh` PR #1086 *(high, 0x)*
- Parallel workers on blocked-by chains create merge conflicts (t008.1-4, t012.3-5). Dispatch sequentially or use single worker *(high, 0x)*
- Decomposition bug (t278): parents marked [x] while subtasks still [ ]. Verify subtask completion before marking parent done *(high, 0x)*
- issue-sync `find_closing_pr()`: format mismatch (`pr:#NNN` vs `PR #NNN`) silently omits PR reference. Fixed t291/PR#1129 *(high, 0x)*
- CRITICAL: Cron pulse on macOS needs (1) `/usr/sbin` in PATH, (2) `GH_TOKEN` cached to file (keyring inaccessible), (3) `get_aidevops_identity` validates `gh api` output. Fixed PR #780 *(medium, 52x)*
- SYSTEMIC: Deployed scripts at `~/.aidevops/agents/scripts/` NOT auto-updated after merging. Run `aidevops update` after script changes. *(medium, 37x)*
