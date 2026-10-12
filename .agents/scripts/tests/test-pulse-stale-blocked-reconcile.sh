#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${TEST_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"
LOGFILE="$ROOT/pulse.log"
REPOS_JSON="$ROOT/repos.json"
mkdir -p "$HOME/.aidevops/cache"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/one","pulse":true},{"slug":"owner/two","pulse":true},{"slug":"owner/local","pulse":true,"local_only":true}]}' >"$REPOS_JSON"
# shellcheck source=../pulse-wrapper-cycle.sh
source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"

CALLS=""
reconcile_stale_blocked_issues() {
	local repo="$1"
	CALLS="${CALLS}${CALLS:+ }$repo"
	return 0
}
_file_mtime_epoch() {
	printf '0\n'
	return 0
}

PULSE_STALE_BLOCKED_RECONCILE_INTERVAL=1800 _pulse_reconcile_stale_blocked_if_due
# Start repo rotates across sweeps (GH#33957); the selected set is what matters.
[[ "$CALLS" == "owner/one owner/two" || "$CALLS" == "owner/two owner/one" ]] || {
	printf 'FAIL: expected both remote pulse repos, got %s\n' "$CALLS"
	exit 1
}
CALLS=""
_file_mtime_epoch() {
	date +%s
	return 0
}
_pulse_reconcile_stale_blocked_if_due
[[ -z "$CALLS" ]] || {
	printf 'FAIL: fresh cadence sentinel did not suppress reconciliation\n'
	exit 1
}

# GH#33957: a partial pass leaves the sentinel stale so the next cycle resumes,
# every repo receives a deadline inside the stage deadline, and only a complete
# traversal restarts the cadence.
SENTINEL="$HOME/.aidevops/cache/pulse-stale-blocked-reconcile-last-run"
_file_mtime_epoch() {
	printf '0\n'
	return 0
}
DEADLINES=""
reconcile_stale_blocked_issues() {
	local repo="$1"
	DEADLINES="${DEADLINES}${DEADLINES:+ }${DER_STALE_BLOCKED_DEADLINE_EPOCH:-unset}"
	[[ "$repo" == "owner/two" ]] && return 3
	return 0
}
rm -f "$SENTINEL"
now_epoch=$(date +%s)
PULSE_STAGE_DEADLINE_EPOCH=$((now_epoch + 100)) PULSE_STALE_BLOCKED_RECONCILE_MARGIN_SECONDS=10 \
	_pulse_reconcile_stale_blocked_if_due
[[ ! -f "$SENTINEL" ]] || {
	printf 'FAIL: partial stale sweep touched the cadence sentinel\n'
	exit 1
}
grep -q 'partial_repos=1 repos=2' "$LOGFILE" || {
	printf 'FAIL: partial stale sweep was not reported\n'
	exit 1
}
for repo_deadline in $DEADLINES; do
	[[ "$repo_deadline" =~ ^[0-9]+$ && "$repo_deadline" -le $((now_epoch + 90)) && "$repo_deadline" -gt "$now_epoch" ]] || {
		printf 'FAIL: repo deadline %s outside stage budget\n' "$repo_deadline"
		exit 1
	}
done
STARTED=""
reconcile_stale_blocked_issues() {
	STARTED="${STARTED}${1} "
	return 0
}
rm -f "$SENTINEL"
PULSE_STAGE_DEADLINE_EPOCH=$((now_epoch + 5)) PULSE_STALE_BLOCKED_RECONCILE_MARGIN_SECONDS=10 \
	_pulse_reconcile_stale_blocked_if_due
[[ -z "$STARTED" && ! -f "$SENTINEL" ]] || {
	printf 'FAIL: expired sweep deadline still started repos (%s) or touched the sentinel\n' "$STARTED"
	exit 1
}
grep -q 'partial_repos=2 repos=2' "$LOGFILE" || {
	printf 'FAIL: deferred repos were not reported as partial\n'
	exit 1
}
_pulse_reconcile_stale_blocked_if_due
[[ -f "$SENTINEL" ]] || {
	printf 'FAIL: complete stale sweep did not touch the cadence sentinel\n'
	exit 1
}

# A repo that consumes the whole budget must not starve the next one: with a
# mocked clock and identical cycle timing, consecutive sweeps start with the
# previously deferred repo.
FAKE_NOW=1000
date() {
	printf '%s\n' "$FAKE_NOW"
	return 0
}
reconcile_stale_blocked_issues() {
	STARTED="${STARTED}${1} "
	FAKE_NOW=$((FAKE_NOW + 100))
	return 0
}
first_starts=""
STAMP_DIR="$HOME/.aidevops/cache/stale-blocked-complete"
for sweep in 1 2 3; do
	# Each sweep is a first traversal: no per-repo stamps (t18663).
	rm -rf "$SENTINEL" "$STAMP_DIR"
	STARTED=""
	FAKE_NOW=$((1000 + sweep * 120))
	PULSE_STAGE_DEADLINE_EPOCH=$((FAKE_NOW + 60)) PULSE_STALE_BLOCKED_RECONCILE_MARGIN_SECONDS=15 \
		_pulse_reconcile_stale_blocked_if_due
	first_starts="${first_starts}${STARTED}"
done
unset -f date
[[ "$first_starts" == "owner/one owner/two owner/one " || "$first_starts" == "owner/two owner/one owner/two " ]] || {
	printf 'FAIL: budget-consuming repo starved the next repo: %s\n' "$first_starts"
	exit 1
}

# t18663: a repo with a clean pass inside the interval is not re-listed, and
# the remaining due repo receives the whole sweep budget.
rm -rf "$SENTINEL" "$STAMP_DIR"
mkdir -p "$STAMP_DIR"
touch "$STAMP_DIR/owner__one"
_file_mtime_epoch() {
	case "$1" in
	*/owner__one) date +%s ;;
	*) printf '0\n' ;;
	esac
	return 0
}
STARTED=""
DEADLINES=""
reconcile_stale_blocked_issues() {
	STARTED="${STARTED}${1} "
	DEADLINES="${DEADLINES}${DER_STALE_BLOCKED_DEADLINE_EPOCH:-unset}:${DER_STALE_BLOCKED_STOP_EPOCH:-unset} "
	return 3
}
now_epoch=$(date +%s)
PULSE_STAGE_DEADLINE_EPOCH=$((now_epoch + 100)) PULSE_STALE_BLOCKED_RECONCILE_MARGIN_SECONDS=10 \
	_pulse_reconcile_stale_blocked_if_due
[[ "$STARTED" == "owner/two " && "$DEADLINES" == "$((now_epoch + 90)):$((now_epoch + 90)) " ]] || {
	printf 'FAIL: fresh repo was re-listed or the due repo lost budget: started=%s deadlines=%s\n' "$STARTED" "$DEADLINES"
	exit 1
}
[[ ! -f "$SENTINEL" && ! -f "$STAMP_DIR/owner__two" ]] || {
	printf 'FAIL: partial pass stamped the sweep or the repo cadence\n'
	exit 1
}
grep -q 'partial_repos=1 repos=2 fresh_repos=1' "$LOGFILE" || {
	printf 'FAIL: fresh repo count was not reported\n'
	exit 1
}
reconcile_stale_blocked_issues() {
	STARTED="${STARTED}${1} "
	return 0
}
STARTED=""
_pulse_reconcile_stale_blocked_if_due
[[ "$STARTED" == "owner/two " && -f "$STAMP_DIR/owner__two" && -f "$SENTINEL" ]] || {
	printf 'FAIL: clean pass did not start the repo cadence (started=%s)\n' "$STARTED"
	exit 1
}

# A failed pass stays due; a future-dated stamp never suppresses a repo.
rm -rf "$SENTINEL" "$STAMP_DIR"
reconcile_stale_blocked_issues() {
	[[ "$1" == "owner/one" ]] && return 1
	return 0
}
_pulse_reconcile_stale_blocked_if_due
[[ ! -f "$STAMP_DIR/owner__one" && -f "$STAMP_DIR/owner__two" ]] || {
	printf 'FAIL: failed pass was stamped or clean pass was not\n'
	exit 1
}
grep -q 'failures=1 partial_repos=0 repos=2 fresh_repos=0' "$LOGFILE" || {
	printf 'FAIL: failed repo was not reported\n'
	exit 1
}
rm -f "$SENTINEL"
touch "$STAMP_DIR/owner__one"
_file_mtime_epoch() {
	printf '%s\n' "$(($(date +%s) + 3600))"
	return 0
}
reconcile_stale_blocked_issues() {
	STARTED="${STARTED}${1} "
	return 0
}
STARTED=""
_pulse_reconcile_stale_blocked_if_due
[[ "$STARTED" == *"owner/one "* && "$STARTED" == *"owner/two "* ]] || {
	printf 'FAIL: future-dated stamps suppressed due repos: %s\n' "$STARTED"
	exit 1
}

# Exercise the production wiring without starting Pulse or contacting GitHub.
# The existing timeout wrapper owns process termination; this checks that the
# cold sweep actually uses it and retains the first-wave admission reserve.
RECONCILE_STAGE=$(awk '
	/local _pulse_stale_blocked_timeout=/ { reading = 1 }
	reading { print }
	reading && /_pulse_reconcile_stale_blocked_if_due \|\| true/ { exit }
' "${SCRIPT_DIR}/pulse-wrapper.sh")
[[ -n "$RECONCILE_STAGE" ]] || {
	printf 'FAIL: stale reconciliation has no bounded production stage\n'
	exit 1
}
STAGE_CALL=""
_pulse_run_budget_priority_stage_with_timeout() {
	local stage="$1"
	local timeout_seconds="$2"
	local command_name="$3"
	STAGE_CALL="${stage}:${timeout_seconds}:${AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S}:${command_name}"
	# A timed-out optional sweep must not prevent the next startup stage.
	return 124
}
run_reconcile_stage() {
	local _pulse_pre_dispatch_reserve_s=120
	# Only the tracked production snippet above is evaluated, never issue text.
	eval "$RECONCILE_STAGE" || return 1
	return 0
}
for configured_timeout in unset 37 0 invalid; do
	unset PULSE_STALE_BLOCKED_RECONCILE_TIMEOUT_SECONDS
	[[ "$configured_timeout" == unset ]] || PULSE_STALE_BLOCKED_RECONCILE_TIMEOUT_SECONDS="$configured_timeout"
	expected_timeout=60
	[[ "$configured_timeout" != 37 ]] || expected_timeout=37
	run_reconcile_stage || {
		printf 'FAIL: reconciliation timeout blocked startup\n'
		exit 1
	}
	[[ "$STAGE_CALL" == "stale_blocked_reconcile:${expected_timeout}:120:_pulse_reconcile_stale_blocked_if_due" ]] || {
		printf 'FAIL: invalid timeout/reserve wiring: %s\n' "$STAGE_CALL"
		exit 1
	}
done

# GH#34432 regression: 45s across 61 due repos must not round each share to
# 0s (an already-expired repo deadline); the minimum share is capped by the
# sweep deadline.
share_deadline=$(_pulse_stale_blocked_repo_deadline 1000 1045 61)
[[ "$share_deadline" == 1005 ]] || {
	printf 'FAIL: zero fair share not raised to the minimum: %s\n' "$share_deadline"
	exit 1
}
share_deadline=$(_pulse_stale_blocked_repo_deadline 1000 1003 61)
[[ "$share_deadline" == 1003 ]] || {
	printf 'FAIL: minimum share exceeded the sweep deadline: %s\n' "$share_deadline"
	exit 1
}
share_deadline=$(_pulse_stale_blocked_repo_deadline 1000 1060 2)
[[ "$share_deadline" == 1030 ]] || {
	printf 'FAIL: fair share above the minimum changed: %s\n' "$share_deadline"
	exit 1
}
printf 'PASS: stale blocked reconciliation is cadence bounded and startup-timeout protected\n'
