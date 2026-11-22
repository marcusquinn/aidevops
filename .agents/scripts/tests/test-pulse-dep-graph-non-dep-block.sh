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
# guaranteed re-BLOCKED dispatches (webapp#2273).
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
HOLD_MARKER_LIB="$REPO_ROOT/.agents/scripts/issue-hold-marker-lib.sh"

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
	return 0
}

###############################################################################
# Part 1: body defer marker detection (pure function, no network)
#
# Exercise the shared predicate used by Pulse and post-merge healing.
###############################################################################

# shellcheck disable=SC1090
source "$HOLD_MARKER_LIB"

printf '\n== Body defer marker detection ==\n'

assert_eq 'defer until phrase' 'true' "$(issue_body_has_defer_marker 'Defer until Phase 1-6 are working end-to-end @alexey')"
assert_eq 'do not dispatch' 'true' "$(issue_body_has_defer_marker 'Do not dispatch this yet.')"
assert_eq 'do-not-dispatch' 'true' "$(issue_body_has_defer_marker '- do-not-dispatch until owner reviews.')"
assert_eq 'on-hold hyphenated' 'true' "$(issue_body_has_defer_marker 'On-hold until review.')"
assert_eq 'on hold spaced' 'true' "$(issue_body_has_defer_marker '> On hold pending review.')"
assert_eq 'ON HOLD uppercase' 'true' "$(issue_body_has_defer_marker 'ON HOLD: waiting for legal.')"
assert_eq 'HUMAN_UNBLOCK_REQD' 'true' "$(issue_body_has_defer_marker 'HUMAN_UNBLOCK_REQUIRED — see comment thread.')"
assert_eq 'hold for trailing' 'true' "$(issue_body_has_defer_marker 'hold for Q2 release cycle')"
assert_eq 'paused colon' 'true' "$(issue_body_has_defer_marker 'paused: waiting on vendor')"
assert_eq 'paused space' 'true' "$(issue_body_has_defer_marker 'paused pending review')"

# No-match baselines — must NOT match anything.
assert_eq 'clean body' 'false' "$(issue_body_has_defer_marker 'Normal task body with no markers.')"
assert_eq 'blocked-by only' 'false' "$(issue_body_has_defer_marker 'blocked-by:t143,t200 should not trip the defer check')"
assert_eq 'word defer in prose' 'false' "$(issue_body_has_defer_marker 'We should not defer this; ship it now.')"
assert_eq 'dispatch without prefix' 'false' "$(issue_body_has_defer_marker 'Dispatch the worker once ready.')"
assert_eq 'hold without for' 'false' "$(issue_body_has_defer_marker 'please hold this comment until later')"
assert_eq 'mid-sentence hold for' 'false' "$(issue_body_has_defer_marker 'Other rows belong to other parts; neither is a hold for this part.')"
assert_eq 'mid-sentence on hold' 'false' "$(issue_body_has_defer_marker 'This task may be on hold for review.')"
assert_eq 'hold inside fence' 'false' "$(issue_body_has_defer_marker $'```\nOn hold\n```')"

###############################################################################
# Part 1b: not-before time gate (GH#39856, pure function, fixed clock)
###############################################################################

printf '\n== not-before time gate ==\n'

NB_NOW=1795000000 # 2026-11-18T11:06:40Z
NB_FUTURE='<!-- aidevops:not-before at=2026-11-26T07:00:00Z reason=external_event_date -->'
NB_PAST='<!-- aidevops:not-before at=2026-11-10T07:00:00Z reason=external_event_date -->'
NB_PAST_RELEASED='<!-- aidevops:not-before-released at=2026-11-10T07:00:00Z -->'
nb_comments() {
	local association="$1" body="$2"
	jq -cn --arg a "$association" --arg b "$body" '[[{author_association:$a,body:$b,created_at:"2026-11-01T00:00:00Z"}]]'
	return 0
}
nb_state() {
	issue_not_before_state "$1" "$2" "$3" "$NB_NOW" || printf 'error\n'
	return 0
}
assert_eq 'no marker' 'none' "$(nb_state '[]' 'Plain body' true)"
assert_eq 'future body marker holds' 'active 1795676400 2026-11-26T07:00:00Z' "$(nb_state '[]' $'Intro\n'"$NB_FUTURE" false)"
assert_eq 'future trusted comment marker holds' 'active 1795676400 2026-11-26T07:00:00Z' "$(nb_state "$(nb_comments MEMBER "$NB_FUTURE")" '' false)"
assert_eq 'untrusted comment marker ignored' 'none' "$(nb_state "$(nb_comments NONE "$NB_FUTURE")" '' false)"
assert_eq 'expired trusted body marker releases' 'expired 1794294000 2026-11-10T07:00:00Z' "$(nb_state '[]' "$NB_PAST" true)"
assert_eq 'expired untrusted body marker never releases' 'none' "$(nb_state '[]' "$NB_PAST" false)"
assert_eq 'expired trusted comment marker releases' 'expired 1794294000 2026-11-10T07:00:00Z' "$(nb_state "$(nb_comments OWNER "$NB_PAST")" '' false)"
assert_eq 'release receipt makes expiry one-shot' 'released 1794294000 2026-11-10T07:00:00Z' \
	"$(nb_state "$(jq -cn --arg a "$NB_PAST" --arg r "$NB_PAST_RELEASED" '[{author_association:"OWNER",body:$a},{author_association:"COLLABORATOR",body:$r}]')" '' false)"
assert_eq 'untrusted receipt cannot spend the release' 'expired 1794294000 2026-11-10T07:00:00Z' \
	"$(nb_state "$(jq -cn --arg a "$NB_PAST" --arg r "$NB_PAST_RELEASED" '[{author_association:"OWNER",body:$a},{author_association:"NONE",body:$r}]')" '' false)"
assert_eq 'latest marker wins while any is unexpired' 'active 1795676400 2026-11-26T07:00:00Z' "$(nb_state "$(nb_comments OWNER "$NB_PAST")" "$NB_FUTURE" false)"
assert_eq 'malformed marker fails closed' 'invalid 0 -' "$(nb_state '[]' '<!-- aidevops:not-before at=next-tuesday -->' false)"
assert_eq 'fenced example is not a marker' 'none' "$(nb_state '[]' $'```\n'"$NB_FUTURE"$'\n```' true)"
assert_eq 'inline-code example is not a marker' 'none' "$(nb_state '[]' 'Use `'"$NB_FUTURE"'` to hold.' true)"
assert_eq 'unreadable comments fail closed' 'error' "$(nb_state 'not-json' '' false)"
nb_blocks=0
issue_not_before_blocks 'not-json' '' false "$NB_NOW" && nb_blocks=1
assert_eq 'unreadable comments block release' '1' "$nb_blocks"

###############################################################################
# Part 2: non-dep BLOCKED comment marker detection (pure regex)
#
# Mirror of the `_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS` pattern at
# pulse-dep-graph.sh:212. Keep byte-identical.
###############################################################################

_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS='\*\*BLOCKED\*\*.*cannot proceed|Worker Watchdog Kill|Terminal blocker detected|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED|CLAIM_RELEASED reason=blocked([[:space:]]|$)'

comment_has_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qE "$_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS"; then
		echo "true"
	else
		echo "false"
	fi
	return 0
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

assert_eq 'blocked claim release' 'true' \
	"$(comment_has_marker 'CLAIM_RELEASED reason=blocked runner=maintainer ts=2026-08-30T00:00:00Z')"

assert_eq 'non-blocked claim release' 'false' \
	"$(comment_has_marker 'CLAIM_RELEASED reason=worker_complete runner=maintainer ts=2026-08-30T00:00:00Z')"

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
# Source the helper and stub `gh` on PATH to return controlled REST comment
# JSON. This exercises both signals end-to-end without hitting GitHub.
###############################################################################

printf '\n== _should_defer_auto_unblock integration ==\n'

# Temp dir for stub
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub gh that reads a canned paginated REST response file.
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_STUB_CALLS:-/dev/null}"
# Canned response is whatever lives in $GH_STUB_COMMENTS.
# If unset or file missing, return the real --paginate --slurp shape for an
# issue with no comments. GH_STUB_FAIL simulates an API outage.
if [[ -n "${GH_STUB_FAIL:-}" ]]; then
	exit 1
fi
# GH#39856: the issue read (body for the not-before gate) uses --jq.
if [[ "$*" == "api repos/owner/repo/issues/123 --jq"* ]]; then
	[[ -z "${GH_STUB_ISSUE_FAIL:-}" ]] || exit 1
	printf '%s\n' "${GH_STUB_BODY:-}"
	exit 0
fi
if [[ "${GH_STUB_COMMENTS:-}" && -f "${GH_STUB_COMMENTS}" ]]; then
	cat "${GH_STUB_COMMENTS}"
else
	printf '[[]]\n'
fi
STUB
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"
export GH_STUB_CALLS="$STUB_DIR/gh-calls.log"
: >"$GH_STUB_CALLS"

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

# Scenario 2b (GH#37200): an unreadable comment history cannot prove the
# absence of a terminal-blocker hold, so the refresh defers instead of
# silently relabelling the issue available.
got=$(GH_STUB_FAIL=1 _should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'comment fetch failure defers unblock' 'comments-unavailable' "$got"

# Scenario 3: body defer flag false, comment contains **BLOCKED** → defer
export GH_STUB_COMMENTS="$STUB_DIR/blocked-comment.json"
jq -cn --arg body '**BLOCKED** — cannot proceed autonomously. Evidence: ...' \
	'[{author_association:"OWNER",body:$body}]' >"$GH_STUB_COMMENTS"
: >"$GH_STUB_CALLS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'worker BLOCKED comment triggers defer' 'comment-marker' "$got"
rest_comment_calls=$(grep -cF 'api repos/owner/repo/issues/123/comments?per_page=100 --paginate --slurp' "$GH_STUB_CALLS" 2>/dev/null || true)
assert_eq 'comment marker read uses paginated REST' '1' "$rest_comment_calls"

# Scenario 4: Worker Watchdog Kill comment → defer
jq -cn --arg body $'## Worker Watchdog Kill\n\n**Reason:** idle' \
	'[{author_association:"MEMBER",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'watchdog kill comment triggers defer' 'comment-marker' "$got"

# Scenario 5: Terminal blocker comment → defer
jq -cn --arg body '**Terminal blocker detected** (GH#5141) — skipping dispatch.' \
	'[{author_association:"COLLABORATOR",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'terminal blocker comment triggers defer' 'comment-marker' "$got"

# Scenario 6: clean comment (dispatch claim, merge summary) → unblock
jq -cn --arg body $'DISPATCH_CLAIM nonce=abc123 runner=maintainer\n---\nPR #1234 merged.' \
	'[{author_association:"OWNER",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'clean operational comments → unblock' '__no_defer__' "$got"

# Scenario 7: body defer takes precedence even with clean comments
jq -cn --arg body 'DISPATCH_CLAIM nonce=abc123' \
	'[{author_association:"OWNER",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'true' || echo "__no_defer__")
assert_eq 'body defer precedence over clean comments' 'body-defer' "$got"

# Scenario 8: trusted structured blocked release → defer
jq -cn --arg body 'CLAIM_RELEASED reason=blocked runner=maintainer ts=2026-08-30T00:00:00Z' \
	'[{author_association:"OWNER",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'trusted blocked claim release triggers defer' 'comment-marker' "$got"

# Scenario 9: untrusted lookalike cannot create a durable hold
jq -cn --arg body 'CLAIM_RELEASED reason=blocked runner=attacker ts=2026-08-30T00:00:00Z' \
	'[{author_association:"NONE",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'untrusted blocked claim release does not defer' '__no_defer__' "$got"

# Scenario 10: other trusted release reasons remain eligible to unblock
jq -cn --arg body 'CLAIM_RELEASED reason=worker_complete runner=maintainer ts=2026-08-30T00:00:00Z' \
	'[{author_association:"OWNER",body:$body}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'trusted non-blocked claim release does not defer' '__no_defer__' "$got"

jq -cn '[{author_association:"OWNER",body:"DISPATCH_CLAIM nonce=first"},
    {author_association:"OWNER",body:"CLAIM_RELEASED reason=blocked runner=maintainer "}]
    + [range(12) | {author_association:"OWNER",body:"DISPATCH_LEASE nonce=noise"}]' >"$GH_STUB_COMMENTS"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'blocked release survives more than ten lease comments' 'comment-marker' "$got"
jq '. + [{author_association:"OWNER",body:"DISPATCH_CLAIM nonce=next"}]' "$GH_STUB_COMMENTS" >"$STUB_DIR/new-claim.json"
export GH_STUB_COMMENTS="$STUB_DIR/new-claim.json"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'new dispatch supersedes previous blocked attempt' '__no_defer__' "$got"

# GH#39856: an unexpired not-before time gate defers even when the comment
# history is otherwise clean; an expired one leaves the existing checks alone.
jq -cn '[{author_association:"OWNER",body:"DISPATCH_CLAIM nonce=clean"}]' >"$STUB_DIR/clean.json"
export GH_STUB_COMMENTS="$STUB_DIR/clean.json"
got=$(GH_STUB_BODY='<!-- aidevops:not-before at=2999-01-01T00:00:00Z reason=external_event_date -->' \
	_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'unexpired body not-before defers' 'not-before' "$got"
jq -cn '[{author_association:"MEMBER",body:"<!-- aidevops:not-before at=2999-01-01T00:00:00Z reason=external_event_date -->"}]' >"$STUB_DIR/nb-comment.json"
export GH_STUB_COMMENTS="$STUB_DIR/nb-comment.json"
got=$(_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'unexpired trusted comment not-before defers' 'not-before' "$got"
export GH_STUB_COMMENTS="$STUB_DIR/clean.json"
got=$(GH_STUB_BODY='<!-- aidevops:not-before at=2020-01-01T00:00:00Z reason=external_event_date -->' \
	_should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'expired not-before does not defer by itself' '__no_defer__' "$got"
got=$(GH_STUB_ISSUE_FAIL=1 _should_defer_auto_unblock 'owner/repo' '123' 'false' || echo "__no_defer__")
assert_eq 'unreadable issue body defers unblock' 'issue-unavailable' "$got"

printf '\n'
printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

printf 'All pulse-dep-graph non-dep-block tests passed (t2031).\n'
exit 0
