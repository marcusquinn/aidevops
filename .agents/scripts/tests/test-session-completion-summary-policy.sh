#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DOC="${REPO_ROOT}/.agents/AGENTS.md"
SESSION_DOC="${REPO_ROOT}/.agents/reference/session.md"
FULL_LOOP_COMMAND="${REPO_ROOT}/.agents/scripts/commands/full-loop.md"
SAFETY_STOP_DOC="${REPO_ROOT}/.agents/reference/safety-stop-recovery.md"

require_literal() {
	local needle="$1"
	local file="$2"
	local description="$3"

	if ! grep -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		return 1
	fi
	return 0
}

main() {
	require_literal 'state aim and solved outcome' \
		"$AGENTS_DOC" 'always-loaded completion guidance omits the session aim and solved outcome' || return 1
	# shellcheck disable=SC2016 # literal Markdown backticks
	require_literal 'ends with the `What next` block (needed from user, left to capture, close readiness)' \
		"$AGENTS_DOC" 'always-loaded guidance omits the end-of-turn What next block' || return 1
	for field in '**Needed from you:**' '**Left to capture:**' '**Close:**' '### Capture Check'; do
		require_literal "$field" "$SESSION_DOC" \
			"session What next block omits: $field" || return 1
	done
	require_literal "never write \`None\` while a question" \
		"$SESSION_DOC" 'What next block may hide an open user question' || return 1
	require_literal 'reconnects the delivered work to the session aim or problem' \
		"$SESSION_DOC" 'session completion detail omits reader reorientation context' || return 1
	require_literal 'routine-owned cleanup: one no-action line unless user action is required or work is at risk' \
		"$AGENTS_DOC" 'always-loaded completion guidance does not limit routine cleanup to a no-action note' || return 1
	require_literal 'Do not attempt that cleanup, and never turn it into a user task' \
		"$SESSION_DOC" 'session lifecycle may still hand routine cleanup to the user' || return 1
	require_literal 'is not a reason to ask the user to clean up' \
		"$SESSION_DOC" 'session lifecycle lets blocked deletions become user cleanup tasks' || return 1
	require_literal 'after this session closes; no action needed.' \
		"$SESSION_DOC" 'session lifecycle omits the no-action cleanup explanation' || return 1
	require_literal "A valid routine-owned \`CLEANUP_DEFERRED\` handoff is operational bookkeeping, not a user task" \
		"$FULL_LOOP_COMMAND" 'full-loop guidance does not classify routine cleanup as a non-user task' || return 1
	require_literal 'after this session closes; no action needed.' \
		"$FULL_LOOP_COMMAND" 'full-loop guidance omits the no-action cleanup explanation' || return 1
	require_literal 'Do not copy lifecycle promise tokens' \
		"$FULL_LOOP_COMMAND" 'machine lifecycle tokens may leak into the user-facing summary' || return 1
	require_literal '**Delivered:** every promised acceptance criterion has verified evidence.' \
		"$SESSION_DOC" 'session guidance does not define delivered evidence' || return 1
	require_literal '**Externally blocked:** name the dependency, its durable action, its owner' \
		"$SESSION_DOC" 'session guidance does not define an actionable external handoff' || return 1
	require_literal '**Active:** identify an actually live executor or a verified durable checkpoint' \
		"$SESSION_DOC" 'session guidance permits imaginary background continuation' || return 1
	require_literal 'A plan, suggested next step, draft, or expired command is not an active executor.' \
		"$SESSION_DOC" 'session guidance does not reject plans as execution' || return 1
	require_literal 'While authorized safe work remains, perform the next safe action' \
		"$SESSION_DOC" 'session guidance allows premature stops in authorized work' || return 1
	require_literal '### Behavioral Examples' \
		"$SESSION_DOC" 'session guidance lacks behavioral contract examples' || return 1
	for behavior in \
		'Authorized work remains and a safe edit or check is available' \
		'A permission must be granted by a human' \
		'A recoverable API call fails' \
		'A human may not return soon' \
		'Every accepted criterion has evidence' \
		'A status check finds held phases awaiting authority or inputs' \
		'The user explicitly stops work'; do
		require_literal "$behavior" "$SESSION_DOC" \
			"session guidance omits behavioral case: $behavior" || return 1
	done
	require_literal 'not prove a future model run complies with the contract.' \
		"$SESSION_DOC" 'session guidance overstates literal policy coverage' || return 1
	require_literal 'Handoff action and verification' \
		"$SAFETY_STOP_DOC" 'safety-stop checkpoints omit human-only handoff evidence' || return 1
	require_literal 'Do not claim that work continues in the background unless a named, live executor' \
		"$SAFETY_STOP_DOC" 'safety-stop guidance allows unsupported background-progress claims' || return 1
	require_literal '**Truthful execution state (MANDATORY):**' \
		"$FULL_LOOP_COMMAND" 'full-loop command omits truthful execution states' || return 1
	require_literal 'continuation; it never completes unfinished delivery.' \
		"$FULL_LOOP_COMMAND" 'full-loop command treats checkpointing as completion' || return 1
	# GH#33130: What next must not hide uncommitted session-owned work.
	require_literal 'Inspect live Git status in every touched repository and linked worktree.' \
		"$SESSION_DOC" 'capture check omits the live Git-status inspection' || return 1
	require_literal 'Session-owned modified, staged, or untracked files are uncaptured' \
		"$SESSION_DOC" 'capture check does not classify uncommitted files as uncaptured' || return 1
	require_literal 'ask for that approval under **Needed from you**' \
		"$SESSION_DOC" 'capture check hides missing commit approval' || return 1
	require_literal 'Do not rely on an earlier status snapshot.' \
		"$SESSION_DOC" 'capture check accepts stale Git status' || return 1
	require_literal 'no session-owned repository changes remain uncommitted' \
		"$SESSION_DOC" 'Ready to close permits uncommitted session-owned changes' || return 1
	# GH#33927: close readiness covers held objective phases, not only PRs.
	require_literal 'every unresolved objective phase is' \
		"$SESSION_DOC" 'Ready to close ignores held objective phases' || return 1
	require_literal 'Another session holding the plan is not an executor.' \
		"$SESSION_DOC" 'Ready to close accepts a plan held elsewhere as ownership' || return 1
	require_literal 'becomes one bounded numbered ask naming' \
		"$SESSION_DOC" 'missing human-only authority is not surfaced as an ask' || return 1
	check_link_and_step_rules || return 1

	if grep -Fq -- "Cleanup: commit or stash changes, then run \`wt merge\`" "$SESSION_DOC"; then
		printf 'FAIL: session lifecycle still directs the owning session to clean its worktree\n' >&2
		return 1
	fi

	printf 'PASS: completion summaries prioritize delivered outcomes over routine cleanup\n'
	return 0
}

check_link_and_step_rules() {
	# GH#33829: asks and delivery reports must link what the user has to inspect.
	# GH#33867: each link is a bare full URL on its own line, never inline.
	require_literal 'object URLs on own line' \
		"$AGENTS_DOC" 'always-loaded What next guidance omits own-line object links' || return 1
	require_literal '**Link everything the user must look at.**' \
		"$SESSION_DOC" 'What next rules do not require clickable links' || return 1
	require_literal '**One link per line, always.**' \
		"$SESSION_DOC" 'clickable-link guidance permits inline links' || return 1
	require_literal "Take URLs from tool output; never guess or hand-build them." \
		"$SESSION_DOC" 'clickable-link guidance permits guessed URLs' || return 1
	if grep -Eq -- ' — (https?://|<(full )?URL)' "$SESSION_DOC"; then
		printf 'FAIL: session guidance still shows a URL inline after a label\n' >&2
		return 1
	fi
	# GH#33834: human-only asks need linked, navigable, rendered steps.
	require_literal 'human actions as linked steps' \
		"$AGENTS_DOC" 'always-loaded What next guidance omits human action steps' || return 1
	for step_rule in '### Human Action Steps' '**Direct link first.**' \
		'**Navigation path** in bold' '**Markdown that stands out in the TUI:**' \
		'**Never put secrets in steps.**'; do
		require_literal "$step_rule" "$SESSION_DOC" \
			"human action steps omit: $step_rule" || return 1
	done
	return 0
}

main "$@"
