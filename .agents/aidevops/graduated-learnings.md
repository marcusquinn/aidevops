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

Validated patterns promoted from local memory (3+ accesses or high confidence).
Graduated by `memory-graduate-helper.sh`, timestamped per batch.

**Categories**:

- **Solutions & Fixes**: Working solutions to real problems
- **Anti-Patterns**: Approaches that failed (avoid repeating)
- **Patterns & Best Practices**: Proven approaches
- **Architecture Decisions**: Key design choices and rationale
- **Configuration & Preferences**: Tool and workflow settings
- **Context & Background**: Important background information

**Usage**: `memory-helper.sh graduate [candidates|graduate|status]`

## Graduated: 2026-02-08

### Anti-Patterns (What NOT to Do)

- **[FAILED_APPROACH]** Tried using PostgreSQL for memory but it adds deployment complexity - SQLite FTS5 is simpler
  *(confidence: high, validated: 9x)*

- **[FAILURE_PATTERN]** [task:refactor] Haiku missed edge cases when refactoring complex shell scripts with many conditionals [model:haiku]
  *(confidence: high, validated: 3x)*

### Architecture Decisions

- **[ARCHITECTURAL_DECISION]** YAML handoffs are more token-efficient than markdown (~400 vs ~2000 tokens)
  *(confidence: high, validated: 0x)*

- **[DECISION]** Mailbox uses SQLite (`mailbox.db`) not TOON files. Prune shows storage report by default, `--force` to delete. Migration from TOON runs automatically on `aidevops update` via `setup.sh`.
  *(confidence: medium, validated: 8x)*

- **[DECISION]** Agent lifecycle uses three tiers: `draft/` (R&D, orchestration-created), `custom/` (private, permanent), shared (`.agents/` via PR). Both `draft/` and `custom/` survive `setup.sh` deployments. Orchestration agents (Build+, Ralph loop, runners) know they can create drafts for reusable parallel processing context and propose them for inclusion in aidevops.
  *(confidence: medium, validated: 3x)*

### Configuration & Preferences

- **[USER_PREFERENCE]** Prefer conventional commits with scope: feat(memory): description
  *(confidence: medium, validated: 4x)*

### Patterns & Best Practices

- **[SUCCESS_PATTERN]** [task:feature] Breaking task into 4 phases with separate commits worked well for Claude-Flow feature adoption [model:sonnet]
  *(confidence: high, validated: 3x)*

- **[SUCCESS_PATTERN]** [task:bugfix] Opus identified root cause of race condition by reasoning through concurrent execution paths [model:opus]
  *(confidence: high, validated: 2x)*

- **[CODEBASE_PATTERN]** Memory daemon should auto-extract learnings from thinking blocks when sessions end
  *(confidence: medium, validated: 5x)*

## Graduated: 2026-02-11

### Anti-Patterns (What NOT to Do)

- **[FAILURE_PATTERN]** Mentioning issues in summary text without logging TODOs or fixing them. Fix: log issues immediately, don't batch to end.
   *(confidence: high, validated: 1x)*

### Architecture Decisions

- **[DECISION]** Log discovered issues as TODOs immediately, not at session end. Deferring loses context.
   *(confidence: high, validated: 1x)*

- **[DECISION]** For content generation (images, video, UGC, ads): read domain subagents first. Structured templates (Nanobanana Pro, 7-component video format, hook frameworks) produce better results than freehand.
   *(confidence: high, validated: 1x)*

- **[DECISION]** UGC content: generate all shots, assemble with `ffmpeg` transitions, output final sequence as primary deliverable (not individual clips).
   *(confidence: high, validated: 1x)*

- **[DECISION]** CRITICAL: Supervisor needs orphaned PR scanner (Phase 3c). Pattern: workers emit `TASK_COMPLETE` before PR, or `evaluate_worker` fails to parse PR URL. Fix: scan `gh pr list --state open --head feature/tXXX` for tasks with `task_only`/`no_pr`/NULL `pr_url`. Would catch t199.2 (PR #849), t199.3 (PR #846), t199.5 (PR #872) automatically.
   *(confidence: high, validated: 0x)*

### Configuration & Preferences

- **[USER_PREFERENCE]** User-facing generated assets (images, videos, documents) should be output to `~/Downloads/` so the user can immediately review them in Finder. Do NOT bury outputs in `~/.aidevops/.agent-workspace/` for interactive sessions — that path is invisible to the user. Reserve `.agent-workspace` for headless/pipeline runs only.
  *(confidence: high, validated: 0x)*

- **[USER_PREFERENCE]** Runtime identity: use version-check output, don't guess. Wrong identity → wrong config paths, CLI commands, prompt loading.
   *(confidence: high, validated: 0x)*

### Patterns & Best Practices

- **[CODEBASE_PATTERN]** OpenCode: `prompt` field in `opencode.json` replaces (not appends) `anthropic_default`. All active agents must have `build.txt` set or fall back to upstream `anthropic.txt`, losing aidevops overrides.
   *(confidence: high, validated: 1x)*

- **[CODEBASE_PATTERN]** Task ID collision: t264 assigned by two sessions simultaneously (PR #1040 vs version-manager fix). Prevention: `git pull` and re-read TODO.md before assigning IDs.
   *(confidence: high, validated: 1x)*

- **[CODEBASE_PATTERN]** Stale TODO.md: completed tasks (t231 PR #955, t247 subtasks, t259 PR #1020) remain open because `update_todo_on_complete()` only runs post-PR. Fix: run `supervisor-helper.sh reconcile-todo` periodically; workers check if work is done and report `task_obsolete`.
   *(confidence: high, validated: 0x)*

- **[SUCCESS_PATTERN]** [task:feature] t136.5: Scaffold aidevops-pro/anon repos | PR #792 | [model:opus] [duration:1206s]
   *(confidence: medium, validated: 51x)*

### Solutions & Fixes

- **[ERROR_FIX]** Deploying auto-recovery infinite loop: `retry_count` was LOCAL, reset every pulse cycle. If both `deployed` and `failed` transitions fail, task stuck forever. Fixed t263 (PR #1036): persistent `deploying_recovery_attempts` DB column, max 10 attempts, fallback SQL UPDATE.
   *(confidence: high, validated: 0x)*

- **[ERROR_FIX]** Pulse silent failure: Phase 3 called with `2>/dev/null || true` masks crashes. Symptom: only header printed. Diagnosis: check `post-pr.log` for repeated entries.
   *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Bash associative arrays (`declare -A`) + `set -u` = unbound variable on empty arrays and subscript access. Use newline-delimited string + grep instead for portable `set -u`-safe lookups. Fixed in `issue-sync-helper.sh` PR #1086.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Parallel workers on blocked-by chains create merge conflicts (t008.1-4, t012.3-5). Solution: dispatch sequentially or use single worker.
   *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Decomposition bug (t278): parents marked [x] while subtasks still [ ]. Verify subtask completion before marking parent done.
   *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** issue-sync `find_closing_pr()`: format mismatch (`pr:#NNN` vs `PR #NNN`) silently omits PR reference. Ensure regex matches TODO.md format. Fixed t291/PR#1129.
   *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** CRITICAL: Cron pulse on macOS needs (1) `/usr/sbin` in PATH, (2) `GH_TOKEN` cached to file (keyring inaccessible), (3) `get_aidevops_identity` validates `gh api` output. Fixed PR #780.
   *(confidence: medium, validated: 52x)*

- **[WORKING_SOLUTION]** SYSTEMIC: Deployed scripts at `~/.aidevops/agents/scripts/` NOT auto-updated after merging. Cron pulse runs deployed copy. Run `aidevops update` or `rsync` after script changes. Consider auto-deploy in post-merge hook.
   *(confidence: medium, validated: 37x)*
