#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Stub case for pulse-merge-runtime-pending-notice.sh (GH#39645): a liftable
# hold notifies once per head, a repeat at the same head and a non-liftable hold
# notify nobody, a new head notifies again, and no live session logs ATTENTION.
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
cat >"${WORK}/bus.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
list) cat "$STUB_DIR/sessions" ;;
send) printf '%s\n' "$2" >>"$STUB_DIR/sent"; cat >>"$STUB_DIR/sent-text" ;;
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
check "notice carries the head and command" "2" "$(rg -c "${HEAD_A}|verify-runtime 7 o/r --testing" "${STUB_DIR}/sent-text")"

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
check "no live session logs one ATTENTION line with age" "1" "$(rg -c 'ATTENTION: PR #9 in o/r is held as runtime-pending \(held [0-9]+ min\)' "$LOGFILE")"

printf '%s\n' '[{"session_id":"ses_tui1","kind":"tui","messageable":true,"repo":"o/r"}]' >"${STUB_DIR}/sessions"
_pmrp_route_held_pr 9 o/r
check "a session appearing later receives the notice" "3" "$(sent_count)"

if [[ "$FAILURES" -gt 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All tests passed\n'
exit 0
