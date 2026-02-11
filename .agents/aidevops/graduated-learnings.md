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

Validated learnings promoted from local memory databases into shared documentation.
These patterns have been confirmed through repeated use across sessions.

**How memories graduate**: Memories qualify when they reach high confidence or are
accessed frequently (3+ times). The `memory-graduate-helper.sh` script identifies
candidates and appends them here. Each graduation batch is timestamped.

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

- **[DECISION]** Mailbox uses SQLite (mailbox.db) not TOON files. Prune shows storage report by default, --force to delete. Migration from TOON runs automatically on aidevops update via setup.sh.
  *(confidence: medium, validated: 8x)*

- **[DECISION]** Agent lifecycle uses three tiers: draft/ (R&D, orchestration-created), custom/ (private, permanent), shared (.agents/ via PR). Both draft/ and custom/ survive setup.sh deployments. Orchestration agents (Build+, Ralph loop, runners) know they can create drafts for reusable parallel processing context and propose them for inclusion in aidevops.
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

- **[FAILURE_PATTERN]** Session anti-pattern: mentioning issues in summary text without logging them as TODOs or fixing them. This creates an illusion of thoroughness while actually losing the improvements. The fix is mechanical: every time you type a sentence describing a bug or limitation, STOP and either (1) fix it now, or (2) add a TODO entry. Then continue writing the summary. Do not batch issue logging to the end.
  *(confidence: high, validated: 1x)*

### Architecture Decisions

- **[DECISION]** When discovering bugs or issues during a task, log them as TODOs IMMEDIATELY — do not defer until the end of the session or until the user asks. This session discovered 8 issues but only logged 2 until prompted. The development lifecycle rule is clear: issues discovered during work must be fixed on the fly or logged as TODOs. Deferring loses context and risks forgetting entirely.
  *(confidence: high, validated: 1x)*

- **[DECISION]** For content generation tasks (images, video, UGC, ads), ALWAYS read domain subagents BEFORE generating. content/production/image.md has Nanobanana Pro JSON prompt templates that produce dramatically better results than freehand prompts. tools/video/video-prompt-design.md has the 7-component video prompt format. content/story.md has hook frameworks. Using structured templates from subagents vs freehand: the difference was visible in output quality during the Trinity Windows UGC test.
  *(confidence: high, validated: 1x)*

- **[DECISION]** UGC content generation needs a complete assembled sequence, not just individual assets. When storyboarding multi-shot content: (1) generate video for ALL shots not just the hero, (2) assemble into a single sequence with transitions using ffmpeg, (3) output the final assembled video as the primary deliverable. Individual clips are intermediates, not the final product.
  *(confidence: high, validated: 1x)*

- **[DECISION]** CRITICAL self-improvement: The supervisor needs a post-evaluation orphaned PR scanner. Pattern observed across 47+ tasks: workers create PRs but the supervisor records "'"task_only"'" or "'"no_pr"'" because (1) worker emits TASK_COMPLETE instead of FULL_LOOP_COMPLETE, (2) PR creation happens after the signal, or (3) evaluate_worker fails to parse the PR URL from logs. Fix: add a Phase 3c to the pulse cycle that runs "'"gh pr list --state open --head feature/tXXX"'" for all tasks in complete/deployed/failed states with task_only/no_pr/NULL pr_url, and links any found PRs. This would have caught t199.2 (PR #849), t199.3 (PR #846), t199.5 (PR #872) automatically instead of requiring manual intervention.
  *(confidence: high, validated: 0x)*

### Configuration & Preferences

- **[USER_PREFERENCE]** User-facing generated assets (images, videos, documents) should be output to ~/Downloads/ so the user can immediately review them in Finder. Do NOT bury outputs in ~/.aidevops/.agent-workspace/ for interactive sessions — that path is invisible to the user. Reserve .agent-workspace for headless/pipeline runs only.
  *(confidence: high, validated: 0x)*

- **[USER_PREFERENCE]** Runtime identity hazard: misidentifying as Claude Code when running in OpenCode wastes cycles investigating wrong config paths, wrong CLI commands, wrong prompt loading. The AGENTS.md rule says "'"use the app name from the version check output — do not guess"'". Enforce this strictly — wrong identity leads to wrong assumptions about how build.txt loads, where configs live, and which CLI to use for dispatch.
  *(confidence: high, validated: 0x)*

### Patterns & Best Practices

- **[CODEBASE_PATTERN]** OpenCode system prompt override: the agent "'"prompt"'" field in opencode.json replaces anthropic_default (not appends). Code path: input.agent.prompt ? [input.agent.prompt] : SystemPrompt.provider(input.model). The {file:path} syntax is resolved by template matching. All active agents must have build.txt set or they fall back to upstream anthropic.txt, losing all aidevops overrides. Verified: all 12 active agents have it; 4 disabled agents (build, plan, Plan+, AI-DevOps) don"'"t need it.
  *(confidence: high, validated: 1x)*

- **[CODEBASE_PATTERN]** Task ID collision: t264 was assigned by two sessions simultaneously. Another session used t264 for memory monitoring (PR #1040), while this session used t264 for version-manager unbound variable fix. The pre-dispatch check caught it ("'"t264 is marked [x] in TODO.md"'"). Prevention: always git pull and re-read TODO.md before assigning IDs. The collision prevention rule in AGENTS.md exists but needs enforcement during monitoring sessions that create tasks.
  *(confidence: high, validated: 1x)*

- **[CODEBASE_PATTERN]** Stale TODO.md pattern: tasks completed in previous sessions (t231 via PR #955, t247 via subtask PRs, t259 via PR #1020) remain open in TODO.md because the supervisor"'"s update_todo_on_complete() only runs during the post-PR lifecycle. When a monitoring session manually merges PRs or when tasks are completed across session boundaries, TODO.md falls out of sync. Fix: run "'"supervisor-helper.sh reconcile-todo"'" periodically, and before dispatching tasks, check if the work is already done (workers now do this and report task_obsolete).
  *(confidence: high, validated: 0x)*

- **[SUCCESS_PATTERN]** [task:feature] Supervisor task t136.5 completed successfully | PR: https://github.com/marcusquinn/aidevops/pull/792 | Task: Scaffold aidevops-pro and aidevops-anon repos - create initial plugin repos with proper structure [model:opus] [duration:1206s]
  *(confidence: medium, validated: 51x)*

### Solutions & Fixes

- **[ERROR_FIX]** Deploying auto-recovery infinite loop: when a task is stuck in "'"deploying"'" and its PR is already merged, cmd_pr_lifecycle Step 4b runs cleanup_after_merge (worktree already gone) and update_todo_on_complete (already marked [x]). The retry_count variable was LOCAL and reset every pulse cycle, allowing infinite recovery attempts across pulses. Additionally, if cmd_transition to "'"deployed"'" fails AND the fallback cmd_transition to "'"failed"'" also fails, the task stays in "'"deploying"'" forever. Fixed by t263 (PR #1036): persistent deploying_recovery_attempts DB column, max 10 attempts across all pulses, fallback direct SQL UPDATE.
  *(confidence: high, validated: 0x)*

- **[ERROR_FIX]** Pulse silent failure pattern: with set -euo pipefail, Phase 3 (process_post_pr_lifecycle) can fail silently because it"'"s called with "'"2>/dev/null || true"'". If the function crashes internally (e.g., infinite loop in deploying auto-recovery), the pulse exits with code 1 but produces no output after the header line. The "'"|| true"'" prevents the error from propagating, but the exit code still leaks through. Symptom: pulse prints "'"=== Supervisor Pulse <timestamp> ==="'" and nothing else. Diagnosis: check post-pr.log for repeated entries, check exit code of manual pulse run.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Bash associative arrays (declare -A) + set -u = unbound variable on empty arrays and subscript access. Use newline-delimited string + grep instead for portable set -u-safe lookups. Fixed in issue-sync-helper.sh PR #1086.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Worker PRs dispatched in parallel for tasks with dependency chains (blocked-by) will create merge conflicts. t008.1-4 and t012.3-5 all conflicted because workers ran simultaneously on overlapping files. Solution: dispatch sequentially respecting blocked-by dependencies, or use a single worker for the entire plan.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** Decomposition workers marking parent #plan tasks [x] is a known bug (t278). Parents t008 and t012 were falsely completed while subtasks were still [ ]. Always verify subtask completion before marking parent done.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** issue-sync find_closing_pr() bug pattern: when TODO.md uses a different format (pr:#NNN) than what the code searches for (PR #NNN), close comments silently omit the PR reference. Always check that regex patterns match the actual data format in TODO.md. Fixed in t291/PR#1129.
  *(confidence: high, validated: 0x)*

- **[WORKING_SOLUTION]** CRITICAL FIX: Cron supervisor pulse requires three things to work on macOS: (1) /usr/sbin in PATH for sysctl, (2) GH_TOKEN cached to file since macOS keyring is inaccessible from cron - supervisor-helper.sh now auto-caches token from interactive sessions to ~/.aidevops/.agent-workspace/supervisor/.gh-token-cache, (3) get_aidevops_identity must validate gh api output is not JSON error. Fixed in PR #780.
  *(confidence: medium, validated: 52x)*

- **[WORKING_SOLUTION]** SYSTEMIC: After merging PRs that modify supervisor-helper.sh or other scripts in .agents/scripts/, the deployed copy at ~/.aidevops/agents/scripts/ is NOT automatically updated. The cron pulse runs the deployed copy. Must run "'"rsync -a --exclude=loop-state/ --exclude=custom/ --exclude=draft/ ~/Git/aidevops/.agents/ ~/.aidevops/agents/"'" or "'"aidevops update"'" after merging script changes. setup.sh deploy_aidevops_agents() handles this but may not run to completion in all modes. Consider adding auto-deploy to the supervisor"'"s post-merge hook.
  *(confidence: medium, validated: 37x)*

