#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Generate OpenCode Commands -- Automation (Ralph Loop)
# =============================================================================
# Ralph loop, CI loop, full-loop, and automation command definitions
# for OpenCode.
#
# Usage: source "${SCRIPT_DIR}/generate-opencode-commands-automation.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - create_command() from the orchestrator
#   - AGENT_BUILD constant from the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OPENCODE_CMDS_AUTOMATION_LOADED:-}" ]] && return 0
_OPENCODE_CMDS_AUTOMATION_LOADED=1

# --- Automation (Ralph Loop) Commands ---
# Split into core Ralph loop management and loop monitor sub-groups.

cmd_ralph_loop() {
	create_command "ralph-loop" \
		"Start iterative AI development loop (Ralph Wiggum technique)" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/ralph-loop.md and follow its instructions.

Start a Ralph loop for iterative development.

Arguments: $ARGUMENTS

**Session Title**: Only set a session title if one hasn't been set already (e.g., by `/ralph-task` which sets `"t042: description"`). If no task-prefixed title exists, use `session-rename` with a concise version of the prompt (truncate to ~60 chars if needed).

**Usage:**
```bash
/ralph-loop "<prompt>" --max-iterations <n> --completion-promise "<text>"
```

**Options:**
- `--max-iterations <n>` - Stop after N iterations (default: unlimited)
- `--completion-promise <text>` - Phrase that signals completion

For end-to-end development, prefer `/full-loop` which handles the complete lifecycle.

**How it works:**
1. You work on the task
2. When you try to exit, the SAME prompt is fed back
3. You see your previous work in files and git history
4. Iterate until completion or max iterations

**Completion:**
To signal completion, output: `<promise>YOUR_PHRASE</promise>`
The promise must be TRUE - do not output false promises to escape.

**Examples:**
```bash
/ralph-loop "Build a REST API for todos" --max-iterations 20 --completion-promise "DONE"
/ralph-loop "Fix all TypeScript errors" --completion-promise "ALL_FIXED" --max-iterations 10
```
BODY

	return 0
}

define_ralph_management_commands() {
	create_command "cancel-ralph" \
		"Cancel active Ralph Wiggum loop" \
		"$AGENT_BUILD" "" <<'BODY'
Cancel the active Ralph loop.

Remove the state file to stop the loop:

```bash
rm -f .agents/loop-state/ralph-loop.local.md .agents/loop-state/ralph-loop.local.state
```

If no loop state file exists, no loop is active.
BODY

	create_command "ralph-status" \
		"Show current Ralph loop status" \
		"$AGENT_BUILD" "" <<'BODY'
Show the current Ralph loop status.

**Check status:**

```bash
cat .agents/loop-state/ralph-loop.local.md 2>/dev/null || echo "No active Ralph loop"
```

This shows:
- Whether a loop is active
- Current iteration number
- Max iterations setting
- Completion promise (if set)
- When the loop started
BODY

	create_command "ralph-task" \
		"Run Ralph loop for a task from TODO.md by ID" \
		"$AGENT_BUILD" "" <<'BODY'
Run a Ralph loop for a specific task from TODO.md.

Task ID: $ARGUMENTS

**Workflow:**
1. Find task in TODO.md by ID (e.g., t042)
2. Extract ralph metadata (promise, verify command, max iterations)
3. **Set session title** using `session-rename` tool with format: `"t042: Task description here"`
4. Start Ralph loop with extracted parameters

**Task format in TODO.md:**
```markdown
- [ ] t042 Fix all ShellCheck violations #ralph ~2h
  ralph-promise: "SHELLCHECK_CLEAN"
  ralph-verify: "shellcheck .agents/scripts/*.sh"
  ralph-max: 10
```

**Or shorthand:**
```markdown
- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~2h
```

**Usage:**
```bash
/ralph-task t042
```

This will:
1. Read TODO.md and find task t042
2. Extract the ralph-promise, ralph-verify, ralph-max values
3. Set session title to `"t042: {task description}"` using `session-rename` tool
4. Start: `/ralph-loop "{task description}" --completion-promise "{promise}" --max-iterations {max}`

**Requirements:**
- Task must have `#ralph` tag
- Task should have completion criteria defined
BODY

	return 0
}

define_ralph_core_commands() {
	cmd_ralph_loop
	define_ralph_management_commands
	return 0
}

cmd_preflight_loop() {
	create_command "preflight-loop" \
		"Run preflight checks in a loop until all pass (Ralph pattern)" \
		"$AGENT_BUILD" "" <<'BODY'
Run preflight checks iteratively until all pass or max iterations reached.

Arguments: $ARGUMENTS

**Usage:**
```bash
/preflight-loop [--auto-fix] [--max-iterations N]
```

**Options:**
- `--auto-fix` - Attempt to automatically fix issues
- `--max-iterations N` - Max iterations (default: 10)

**Run the checks:**

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/linters-local.sh
```

**Completion promise:** `<promise>PREFLIGHT_PASS</promise>`

This applies the Ralph Wiggum technique to quality checks:
1. Run all preflight checks (linters-local.sh, shellcheck, markdown lint)
2. If failures and --auto-fix: attempt fixes
3. Re-run checks
4. Repeat until all pass or max iterations

**Examples:**
```bash
/preflight-loop --auto-fix --max-iterations 5
/preflight-loop  # Manual fixes between iterations
```
BODY

	return 0
}

cmd_pr_loop() {
	create_command "pr-loop" \
		"Monitor PR until approved or merged (Ralph pattern)" \
		"$AGENT_BUILD" "" <<'BODY'
Monitor a PR iteratively until approved, merged, or max iterations reached.

Arguments: $ARGUMENTS

**Usage:**
```bash
/pr-loop [--pr NUMBER] [--wait-for-ci] [--max-iterations N]
```

**Options:**
- `--pr NUMBER` - PR number (auto-detected if not provided)
- `--wait-for-ci` - Wait for CI checks to complete
- `--max-iterations N` - Max iterations (default: 10)

Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/commands/pr-loop.md and follow its instructions.

**Completion promises:**
- `<promise>PR_APPROVED</promise>` - PR approved and ready to merge
- `<promise>PR_MERGED</promise>` - PR has been merged

**Workflow:**
1. Check PR status (CI, reviews, mergeable)
2. If changes requested: get feedback, apply fixes, push
3. If CI failed: get annotations, fix issues, push
4. If pending: wait and re-check
5. Repeat until approved/merged or max iterations

**Examples:**
```bash
/pr-loop --wait-for-ci
/pr-loop --pr 123 --max-iterations 20
```
BODY

	return 0
}

cmd_postflight_loop() {
	create_command "postflight-loop" \
		"Monitor release health after deployment (Ralph pattern)" \
		"$AGENT_BUILD" "" <<'BODY'
Monitor release health for a specified duration.

Arguments: $ARGUMENTS

**Usage:**
```bash
/postflight-loop [--monitor-duration Nm] [--max-iterations N]
```

**Options:**
- `--monitor-duration Nm` - How long to monitor (e.g., 5m, 10m, 1h)
- `--max-iterations N` - Max checks during monitoring (default: 5)

Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/commands/postflight-loop.md and follow its instructions.

**Completion promise:** `<promise>RELEASE_HEALTHY</promise>`

**Checks performed:**
1. Latest CI workflow status
2. Release tag exists
3. Version consistency (VERSION file matches release)

**Examples:**
```bash
/postflight-loop --monitor-duration 10m
/postflight-loop --monitor-duration 1h --max-iterations 10
```
BODY

	return 0
}

define_ci_loop_commands() {
	cmd_preflight_loop
	cmd_pr_loop
	cmd_postflight_loop
	return 0
}

cmd_full_loop() {
	create_command "full-loop" \
		"Start end-to-end development loop (task -> preflight -> PR -> postflight -> deploy)" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/commands/full-loop.md and follow its instructions.

Start a full development loop for: $ARGUMENTS

**Full Loop Phases:**
```text
Task Development -> Preflight -> PR Create -> PR Review -> Postflight -> Deploy
```

**Usage:**
```bash
/full-loop "Implement feature X with tests"
/full-loop "Fix bug Y" --max-task-iterations 30
/full-loop t061  # Will look up task description from TODO.md
```

**Options:**
- `--max-task-iterations N` - Max iterations for task (default: 50)
- `--skip-preflight` - Skip preflight checks
- `--skip-postflight` - Skip postflight monitoring
- `--no-auto-pr` - Pause for manual PR creation

**Completion promise:** `<promise>FULL_LOOP_COMPLETE</promise>`
BODY

	return 0
}

define_loop_monitor_commands() {
	define_ci_loop_commands
	cmd_full_loop
	return 0
}

define_automation_commands() {
	define_ralph_core_commands
	define_loop_monitor_commands
	return 0
}
