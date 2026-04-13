#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for pulse-dep-graph.sh non-dep-block gating (t2031).
#
# Guards the conservative auto-unblock path in
# `refresh_blocked_status_from_graph`. The pulse used to blindly strip
# `status:blocked` whenever an issue's blocked-by chain resolved — but
# the label is also applied by worker BLOCKED exits, watchdog thrash
# kills, terminal-blocker detection, and manual human holds. Removing it
# in those cases discarded worker/watchdog evidence and wasted cycles on
# guaranteed re-BLOCKED dispatches (awardsapp#2273).
#
# t2031 added two checks:
#   (a) Body defer/hold marker detection at cache build time.
#   (b) Non-dep BLOCKED marker detection in recent comments (live fetch).
#
# This test covers both — (a) directly, (b) via a mocked `gh` stub on
# PATH.
#
# Usage: bash test-pulse-dep-graph-non-dep-block.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEP_GRAPH="$REPO_ROOT/.agents/scripts/pulse-dep-graph.sh"

if [[ ! -f "$DEP_GRAPH" ]]; then
	echo "FAIL: cannot locate pulse-dep-graph.sh at $DEP_GRAPH" >&2
	exit 1
fi

pass_count=0
fail_count=0

assert_eq() {
	local label="$1" want="$2" got="$3"
	if [[ "$want" == "$got" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  want=%q\n  got=%q\n' "$label" "$want" "$got" >&2
		fail_count=$((fail_count + 1))
	fi
}

###############################################################################
# Part 1: body defer marker detection (pure function, no network)
#
# Mirror of the block in pulse-dep-graph.sh:143-155 — keep this regex
# byte-identical. If the helper regex changes, update the mirror and this
# test together.
###############################################################################

body_has_defer_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]'; then
		echo "true"
	else
		echo "false"
	fi
}

printf '\n== Body defer marker detection ==\n'

assert_eq 'defer until phrase' 'true' "$(body_has_defer_marker 'Defer until Phase 1-6 are working end-to-end @alexey')"
assert_eq 'do not dispatch' 'true' "$(body_has_defer_marker 'Please do not dispatch this yet.')"
assert_eq 'do-not-dispatch' 'true' "$(body_has_defer_marker 'Tagged do-not-dispatch until owner reviews.')"
assert_eq 'on-hold hyphenated' 'true' "$(body_has_defer_marker 'This task is on-hold.')"
assert_eq 'on hold spaced' 'true' "$(body_has_defer_marker 'This task is on hold.')"
assert_eq 'ON HOLD uppercase' 'true' "$(body_has_defer_marker 'ON HOLD: waiting for legal.')"
assert_eq 'HUMAN_UNBLOCK_REQD' 'true' "$(body_has_defer_marker 'HUMAN_UNBLOCK_REQUIRED — see comment thread.')"
assert_eq 'hold for trailing' 'true' "$(body_has_defer_marker 'hold for Q2 release cycle')"
assert_eq 'paused colon' 'true' "$(body_has_defer_marker 'paused: waiting on vendor')"
assert_eq 'paused space' 'true' "$(body_has_defer_marker 'paused pending review')"

# No-match baselines — must NOT match anything.
assert_eq 'clean body' 'false' "$(body_has_defer_marker 'Normal task body with no markers.')"
assert_eq 'blocked-by only' 'false' "$(body_has_defer_marker 'blocked-by:t143,t200 should not trip the defer check')"
assert_eq 'word defer in prose' 'false' "$(body_has_defer_marker 'We should not defer this; ship it now.')"
assert_eq 'dispatch without prefix' 'false' "$(body_has_defer_marker 'Dispatch the worker once ready.')"
assert_eq 'hold without for' 'false' "$(body_has_defer_marker 'please hold this comment until later')"

###############################################################################
# Part 2: non-dep BLOCKED comment marker detection (pure regex)
#
# Mirror of the `_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS` pattern at
# pulse-dep-graph.sh:212. Keep byte-identical.
###############################################################################

_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS='\*\*BLOCKED\*\*.*cannot proceed|Worker Watchdog Kill|Terminal blocker detected|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED'

comment_has_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qE "$_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS"; then
		echo "true"
	else
		echo "false"
	fi
}

printf '\n== Comment BLOCKED marker detection ==\n'

assert_eq 'worker exit BLOCKED' 'true' \
	"$(comment_has_marker '**BLOCKED** — cannot proceed autonomously. Evidence: blockers not resolved.')"

assert_eq 'watchdog kill' 'true' \
	"$(comment_has_marker '## Worker Watchdog Kill

**Reason:** Worker process became idle.')"

assert_eq 'terminal blocker' 'true' \
	"$(comment_has_marker '**Terminal blocker detected** (GH#5141) — skipping dispatch.')"

assert_eq 'ACTION REQUIRED escalation' 'true' \
	"$(comment_has_marker 'ACTION REQUIRED: refresh your GitHub token scopes.')"

assert_eq 'HUMAN_UNBLOCK_REQUIRED tag' 'true' \
	"$(comment_has_marker 'Setting HUMAN_UNBLOCK_REQUIRED until owner reviews.')"

# Dedup operational comments like dispatch claims must NOT trip the gate.
assert_eq 'dispatch claim' 'false' \
	"$(comment_has_marker 'DISPATCH_CLAIM nonce=abc123 runner=marcusquinn ts=2026-04-13T00:00:00Z max_age_s=1800')"

assert_eq 'merge summary' 'false' \
	"$(comment_has_marker 'PR #1234 merged. Closing parent issue.')"

assert_eq 'plain BLOCKED word' 'false' \
	"$(comment_has_marker 'The word BLOCKED by itself should not match.')"

# SC2016: backticks in the test body are LITERAL markdown characters — the
# format the framework emits. Single-quoting is intentional.
# shellcheck disable=SC2016
assert_eq 'blocked-by line' 'false' \
	"$(comment_has_marker '**Blocked by:** `t143`, `t200`')"

###############################################################################
# Part 3: _should_defer_auto_unblock integration via mocked gh
#
# Source the helper and stub `gh` on PATH to return controlled comment
# JSON. This exercises both signals end-to-end without hitting GitHub.
###############################################################################

printf '\n== _should_defer_auto_unblock integration ==\n'

# Temp dir for stub
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub gh that reads a canned response file. The helper calls
# `gh issue view $num --repo $slug --json comments --jq '...'` so the
# stub inspects argv to decide which canned file to serve.
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Canned response is whatever lives in $GH_STUB_COMMENTS.
# If unset or file missing, return empty so the helper fail-opens.
if [[ "${GH_STUB_COMMENTS:-}" && -f "${GH_STUB_COMMENTS}" ]]; then
	cat "${GH_STUB_COMMENTS}"
else
	printf ''
fi
STUB
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

# Shim the helper's dependencies: LOGFILE must exist so `echo >>` works.
export LOGFILE="$STUB_DIR/test.log"
: >"$LOGFILE"

# Source the helper. Sourcing defines `_should_defer_auto_unblock` and
# the non-dep-block marker constant.
# shellcheck disable=SC1090
source "$DEP_GRAPH"

# Scenario 1: body defer flag true → returns body-defer, exit 0
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'true' || echo "__no_defer__")
assert_eq 'body defer flag triggers defer' 'body-defer' "$got"

# Scenario 2: body defer flag false, no comments → returns empty, exit 1
unset GH_STUB_COMMENTS
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'clean body and empty comments → unblock' '__no_defer__' "$got"

# Scenario 3: body defer flag false, comment contains **BLOCKED** → defer
export GH_STUB_COMMENTS="$STUB_DIR/blocked-comment.json"
printf '**BLOCKED** — cannot proceed autonomously. Evidence: ...' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'worker BLOCKED comment triggers defer' 'comment-marker' "$got"

# Scenario 4: Worker Watchdog Kill comment → defer
printf '## Worker Watchdog Kill\n\n**Reason:** idle' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'watchdog kill comment triggers defer' 'comment-marker' "$got"

# Scenario 5: Terminal blocker comment → defer
printf '**Terminal blocker detected** (GH#5141) — skipping dispatch.' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'terminal blocker comment triggers defer' 'comment-marker' "$got"

# Scenario 6: clean comment (dispatch claim, merge summary) → unblock
printf 'DISPATCH_CLAIM nonce=abc123 runner=marcusquinn\n---\nPR #1234 merged.' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'clean operational comments → unblock' '__no_defer__' "$got"

# Scenario 7: body defer takes precedence even with clean comments
printf 'DISPATCH_CLAIM nonce=abc123' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'true' || echo "__no_defer__")
assert_eq 'body defer precedence over clean comments' 'body-defer' "$got"

printf '\n'
printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

printf 'All pulse-dep-graph non-dep-block tests passed (t2031).\n'
exit 0
