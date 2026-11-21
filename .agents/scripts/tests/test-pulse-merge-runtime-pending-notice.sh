#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Stub case for pulse-merge-runtime-pending-notice.sh (GH#39645): a liftable
# hold notifies once per head, a repeat at the same head and a non-liftable hold
# notify nobody, a new head notifies again, no live session (including after a
# notified session exits) logs ATTENTION, and a head with pending or red
# required checks waits until they are green. A red head of a worker or
# takeover PR routes to CI repair (t19244); other owners and holds do not.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
check() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: expected [%s] got [%s]\n' "$name" "$expected" "$actual"
		FAILURES=$((FAILURES + 1))
	fi
	return 0
}

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cat >"${WORK}/helper.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "runtime-pending-notice" ]] || exit 2
[[ "$(cat "$STUB_DIR/decision")" == "lift" ]] || exit 1
jq -nc --argjson pr "$2" --arg repo "$3" --arg head "$(cat "$STUB_DIR/head")" \
	'{pr: $pr, repo: $repo, head: $head, held_since: "2026-11-21T05:00:00Z", reason: "no device available", command: "full-loop-helper.sh verify-runtime \($pr) \($repo) --testing \"<evidence>\""}'
EOF
# Like the real CLI, send opens --text-file as a path ("-" is not stdin).
cat >"${WORK}/bus.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
list) cat "$STUB_DIR/sessions" ;;
send)
	session="$2" text_file=""
	shift 2
	while [[ $# -gt 0 ]]; do
		[[ "$1" == "--text-file" ]] && text_file="${2:-}"
		shift
	done
	[[ -f "$text_file" ]] || exit 1
	printf '%s\n' "$session" >>"$STUB_DIR/sent"
	cat "$text_file" >>"$STUB_DIR/sent-text"
	;;
esac
EOF
chmod +x "${WORK}/helper.sh" "${WORK}/bus.sh"

export STUB_DIR="${WORK}/stub"
mkdir -p "$STUB_DIR"
export LOGFILE="${WORK}/pulse.log"
export PULSE_RUNTIME_PENDING_NOTICE_STATE_DIR="${WORK}/state"
export PULSE_RUNTIME_PENDING_FULL_LOOP_HELPER="${WORK}/helper.sh"
export PULSE_RUNTIME_PENDING_SESSION_BUS_HELPER="${WORK}/bus.sh"
export PULSE_RUNTIME_PENDING_RECHECK_SECONDS=0
export PULSE_RUNTIME_PENDING_RECHECK_SENT_SECONDS=0
: >"$LOGFILE"

# shellcheck source=../pulse-merge-runtime-pending-notice.sh
source "${SCRIPTS_DIR}/pulse-merge-runtime-pending-notice.sh"

sent_count() {
	[[ -f "${STUB_DIR}/sent" ]] || { printf '0\n'; return 0; }
	wc -l <"${STUB_DIR}/sent" | tr -d ' '
	return 0
}

printf 'lift\n' >"${STUB_DIR}/decision"
printf '%s\n' "$HEAD_A" >"${STUB_DIR}/head"
printf '%s\n' '[{"session_id":"ses_tui1","kind":"tui","messageable":true,"repo":"o/r"},{"session_id":"ses_w1","kind":"headless","messageable":true,"repo":"o/r"},{"session_id":"ses_other","kind":"tui","messageable":true,"repo":"o/x"}]' >"${STUB_DIR}/sessions"

_pmrp_route_held_pr 7 o/r
check "lift sends one notice to the interactive session on the repo" "1" "$(sent_count)"
check "notice targets the interactive session only" "ses_tui1" "$(<"${STUB_DIR}/sent")"
check "notice carries the head and command" "2" "$(grep -cE -e "${HEAD_A}|verify-runtime 7 o/r --testing" "${STUB_DIR}/sent-text")"
check "notice keeps the recorded reason intact" "1" "$(grep -cF -e 'data only): no device available' "${STUB_DIR}/sent-text")"

_pmrp_route_held_pr 7 o/r
check "repeat cycle at the same head sends nothing" "1" "$(sent_count)"

printf '%s\n' "$HEAD_B" >"${STUB_DIR}/head"
_pmrp_route_held_pr 7 o/r
check "a new head sends one more notice" "2" "$(sent_count)"

printf 'keep\n' >"${STUB_DIR}/decision"
_pmrp_route_held_pr 8 o/r
check "keep decision sends nothing" "2" "$(sent_count)"

printf 'lift\n' >"${STUB_DIR}/decision"
printf '[]\n' >"${STUB_DIR}/sessions"
_pmrp_route_held_pr 9 o/r
check "no live session sends nothing" "2" "$(sent_count)"
check "no live session logs one ATTENTION line with age" "1" "$(grep -cE -e 'ATTENTION: PR #9 in o/r is held as runtime-pending \(held [0-9]+ min\)' "$LOGFILE")"
check "ATTENTION line keeps the recorded reason intact" "1" "$(grep -cF -e 'reason: no device available (GH#39645)' "$LOGFILE")"

printf '%s\n' '[{"session_id":"ses_tui1","kind":"tui","messageable":true,"repo":"o/r"}]' >"${STUB_DIR}/sessions"
_pmrp_route_held_pr 9 o/r
check "a session appearing later receives the notice" "3" "$(sent_count)"

printf '[]\n' >"${STUB_DIR}/sessions"
_pmrp_route_held_pr 9 o/r
check "a notified session leaving sends nothing more" "3" "$(sent_count)"
check "a notified session leaving logs ATTENTION again" "2" "$(grep -cE -e 'ATTENTION: PR #9 in o/r' "$LOGFILE")"
printf '%s\n' '[{"session_id":"ses_tui1","kind":"tui","messageable":true,"repo":"o/r"}]' >"${STUB_DIR}/sessions"

# With the merge pass's required-check helpers sourced, a head whose required
# checks are pending or red is never offered to a verifier; a green head is.
# One exact-head rollup per read: the state file picks which one.
_required_contexts_for_default_branch() {
	printf 'Framework Validation\nLint\n'
	return 0
}
gh_pr_check_runs_rest() {
	local fv="success" lint='"completed","conclusion":"success"'
	case "$(<"${STUB_DIR}/ci")" in
	pending) fv="" ;;
	red) fv="failure" ;;
	mixed) fv="failure" lint='"in_progress","conclusion":null' ;;
	esac
	printf '[{"name":"Framework Validation","status":"completed","conclusion":%s},{"name":"Lint","status":%s}]\n' \
		"$([[ -n "$fv" ]] && printf '"%s"' "$fv" || printf 'null')" "$lint"
	return 0
}
# t19244: a red head routes to CI repair through the real finalizer label gate;
# the fix-worker route itself is stubbed and records its arguments.
# shellcheck source=../pulse-merge-feedback-finalizer.sh
source "${SCRIPTS_DIR}/pulse-merge-feedback-finalizer.sh"
_route_pr_to_fix_worker() {
	local rc=0
	printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "${8:-}" >>"${STUB_DIR}/routes"
	[[ -f "${STUB_DIR}/route_rc" ]] && rc=$(<"${STUB_DIR}/route_rc")
	return "$rc"
}
route_count() {
	[[ -f "${STUB_DIR}/routes" ]] || { printf '0\n'; return 0; }
	wc -l <"${STUB_DIR}/routes" | tr -d ' '
	return 0
}
WORKER_LABELS="origin:worker,hold-for-review,status:in-review"

printf 'pending\n' >"${STUB_DIR}/ci"
_pmrp_route_held_pr 10 o/r 77 "$WORKER_LABELS"
check "pending required checks send nothing" "3" "$(sent_count)"
check "pending required checks route no CI repair" "0" "$(route_count)"
printf 'mixed\n' >"${STUB_DIR}/ci"
_pmrp_route_held_pr 10 o/r 77 "$WORKER_LABELS"
check "a failure beside an active required check sends nothing" "3" "$(sent_count)"
check "a failure beside an active required check routes no CI repair" "0" "$(route_count)"
printf 'red\n' >"${STUB_DIR}/ci"
_pmrp_route_held_pr 10 o/r 77 "$WORKER_LABELS"
check "red required checks send nothing" "3" "$(sent_count)"
check "red required checks log the failing context" "1" "$(grep -cE -e 'notice for o/r#10@b{12} deferred: required checks failing \(Framework Validation\)' "$LOGFILE")"
check "red worker PR routes one CI repair for its head" "1" "$(route_count)"
check "CI repair route gets the PR, issue, kind, labels and head" "10|o/r|77|ci|${WORKER_LABELS}|${HEAD_B}" "$(<"${STUB_DIR}/routes")"
check "CI repair route logs that the hold is kept" "1" "$(grep -cF -e 'o/r#10@bbbbbbbbbbbb has failing required checks; CI repair route rc=0; hold-for-review kept (t19244)' "$LOGFILE")"
printf 'green\n' >"${STUB_DIR}/ci"
_pmrp_route_held_pr 10 o/r 77 "$WORKER_LABELS"
check "green required checks send the notice" "4" "$(sent_count)"
check "green required checks route no CI repair" "1" "$(route_count)"
# A notified head whose same-SHA CI re-run turns red still routes repair.
printf 'red\n' >"${STUB_DIR}/ci"
_pmrp_route_held_pr 10 o/r 77 "$WORKER_LABELS"
check "a notified head that turns red sends nothing more" "4" "$(sent_count)"
check "a notified head that turns red routes CI repair" "2" "$(route_count)"

_pmrp_route_held_pr 11 o/r 77 "origin:interactive,origin:worker-takeover,hold-for-review"
check "red worker-takeover PR routes CI repair" "3" "$(route_count)"
for refused in "origin:interactive,hold-for-review" "origin:worker,hold-for-review,external-contributor" \
	"origin:worker,hold-for-review,no-takeover" "origin:worker,hold-for-review,needs-maintainer-review" \
	"hold-for-review" ""; do
	_pmrp_route_held_pr 12 o/r 77 "$refused"
	check "red PR labelled [${refused}] routes no CI repair" "3" "$(route_count)"
done
printf 'keep\n' >"${STUB_DIR}/decision"
_pmrp_route_held_pr 13 o/r 77 "$WORKER_LABELS"
check "red PR whose hold is not runtime-pending-only routes no CI repair" "3" "$(route_count)"
printf 'lift\n' >"${STUB_DIR}/decision"
check "a dispatched CI repair logs no ATTENTION" "0" "$(grep -cF -e 'CI repair could not proceed' "$LOGFILE")"
printf '75\n' >"${STUB_DIR}/route_rc"
_pmrp_route_held_pr 14 o/r 77 "$WORKER_LABELS"
check "a deferred CI repair route logs ATTENTION with its rc" "1" "$(grep -cF -e 'ATTENTION: PR #14 in o/r is held as runtime-pending with failing required checks and CI repair could not proceed (route rc=75;' "$LOGFILE")"
rm -f "${STUB_DIR}/route_rc"

if [[ "$FAILURES" -gt 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All tests passed\n'
exit 0
