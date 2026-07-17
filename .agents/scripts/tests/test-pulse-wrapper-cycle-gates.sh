#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TMP=$(mktemp -d -t pulse-cycle-gates.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

export SCRIPT_DIR="${TMP}/scripts"
export WRAPPER_LOGFILE="${TMP}/wrapper.log"
export PULSE_SCOPE_REPOS="owner/repo"
mkdir -p "$SCRIPT_DIR"
: >"$WRAPPER_LOGFILE"

GH_QUERY_FILE="${TMP}/query.txt"
TIMEOUT_CALL_FILE="${TMP}/timeout.txt"
export GH_QUERY_FILE
export TIMEOUT_CALL_FILE
export TIMEOUT_MODE="pass"
gh() {
	printf '%s\n' "$*" >"$GH_QUERY_FILE"
	printf '0\n'
	return 0
}

timeout_sec() {
	local timeout_seconds="$1"
	shift
	printf '%s\n' "$timeout_seconds" >"$TIMEOUT_CALL_FILE"
	if [[ "$TIMEOUT_MODE" == "timeout" ]]; then
		return 124
	fi
	"$@"
	return $?
}

cat >"${SCRIPT_DIR}/pulse-idle-backoff-helper.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
should-skip) exit 0 ;;
state)
	printf '{"consecutive_idle":2,"current_effective_interval_s":120}\n'
	exit 0
	;;
*) exit 1 ;;
esac
EOF
chmod +x "${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"

SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-wrapper-cycle-gates.sh"
# shellcheck disable=SC1090
source "$SOURCE_SCRIPT"

if _pulse_available_auto_dispatch_work_exists; then
	fail "zero eligible issues does not bypass idle backoff"
else
	pass "zero eligible issues does not bypass idle backoff"
fi

if grep -q -- '-label:needs-maintainer-review' "$GH_QUERY_FILE"; then
	pass "idle-work query excludes NMR-held issues"
else
	fail "idle-work query excludes NMR-held issues" "query=$(<"$GH_QUERY_FILE")"
fi

if [[ "$(<"$TIMEOUT_CALL_FILE")" == "30" ]]; then
	pass "idle-work query uses bounded default timeout"
else
	fail "idle-work query uses bounded default timeout" "timeout=$(<"$TIMEOUT_CALL_FILE")"
fi

export TIMEOUT_MODE="timeout"
if _pulse_available_auto_dispatch_work_exists; then
	fail "idle-work query surfaces timeout status"
else
	query_rc=$?
	if [[ "$query_rc" -eq 124 ]]; then
		pass "idle-work query surfaces timeout status"
	else
		fail "idle-work query surfaces timeout status" "rc=${query_rc}"
	fi
fi

if _pulse_check_idle_backoff_gate; then
	pass "idle-work timeout bypasses idle backoff"
else
	fail "idle-work timeout bypasses idle backoff"
fi

if grep -q 'timed out after 30s' "$WRAPPER_LOGFILE"; then
	pass "idle-work timeout is logged"
else
	fail "idle-work timeout is logged"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
