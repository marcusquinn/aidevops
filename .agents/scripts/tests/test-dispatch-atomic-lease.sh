#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Focused protocol tests for the atomic dispatch lease (GH#27165).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
LEDGER_HELPER="${SCRIPTS_DIR}/dispatch-ledger-helper.sh"
CLAIM_HELPER="${SCRIPTS_DIR}/dispatch-claim-helper.sh"
TEST_ROOT="$(mktemp -d -t dispatch-atomic-lease.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

TESTS_RUN=0
TESTS_FAILED=0

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
	printf 'FAIL %s\n' "$name"
	[[ -z "$detail" ]] || printf '  %s\n' "$detail"
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected=${expected} actual=${actual}"
	fi
	return 0
}

setup_mock_gh() {
	local bin_dir="${TEST_ROOT}/bin"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${MOCK_GH_STATE_DIR:?}"
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	printf '%s' "${MOCK_OPEN_PR_JSON:-[]}" | jq -r '.[0].number // empty'
	exit "${MOCK_PR_EXIT:-0}"
fi
[[ "${1:-}" == "api" ]] || exit 1
shift
endpoint="${1:-}"
shift || true
method="GET"
body=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--method) method="$2"; shift 2 ;;
	--field) body="${2#body=}"; shift 2 ;;
	--jq) shift 2 ;;
	*) shift ;;
	esac
done
if [[ "$endpoint" == "user" ]]; then
	printf 'same-login\n'
	exit 0
fi
if [[ "$endpoint" == repos/*/issues/*/comments* && "$method" == "POST" ]]; then
	printf '%s' "$body" >"${state_dir}/last-post.txt"
	printf '999\n'
	exit 0
fi
if [[ "$endpoint" == repos/*/issues/*/comments* ]]; then
	if [[ -f "${state_dir}/claim-comments.json" ]]; then
		cat "${state_dir}/claim-comments.json"
	else
		printf '[]\n'
	fi
	exit 0
fi
if [[ "$endpoint" == repos/*/issues/* ]]; then
	printf '{"assignees":[]}\n'
	exit 0
fi
exit 1
MOCK
	chmod +x "${bin_dir}/gh"
	export PATH="${bin_dir}:${PATH}"
	export MOCK_GH_STATE_DIR="$TEST_ROOT"
	return 0
}

test_ledger_phase_transitions() {
	export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/ledger"
	export AIDEVOPS_RUNNER_DEVICE_ID="device-alpha"
	mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	"$LEDGER_HELPER" register --session-key issue-27165 --issue 27165 --repo owner/repo \
		--pid $$ --session-id session-alpha
	local ledger="${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"
	assert_eq "register records pre-launch phase" "pre-launch" "$(jq -r '.lease_phase' "$ledger")"
	assert_eq "register records stable device" "device-alpha" "$(jq -r '.runner_device' "$ledger")"
	[[ "$(jq -r '.lease_expires_at' "$ledger")" == *Z ]] && pass "pre-launch lease has explicit expiry" || fail "pre-launch lease has explicit expiry"

	"$LEDGER_HELPER" ready --session-key issue-27165 --session-id runtime-session --evidence worker.started
	assert_eq "readiness promotes lease to active" "active" "$(jq -r '.lease_phase' "$ledger")"
	assert_eq "readiness evidence is durable" "worker.started" "$(jq -r '.readiness_evidence' "$ledger")"
	assert_eq "runtime session replaces launch session" "runtime-session" "$(jq -r '.worker_session_id' "$ledger")"

	"$LEDGER_HELPER" complete --session-key issue-27165
	assert_eq "completion records terminal phase" "terminal" "$(jq -r '.lease_phase' "$ledger")"
	assert_eq "completion records terminal evidence" "ledger-status:completed" "$(jq -r '.terminal_evidence' "$ledger")"
	"$LEDGER_HELPER" register --session-key issue-27165 --issue 27165 --repo owner/repo --pid $$
	assert_eq "late registration cannot resurrect terminal lease" "completed" "$(jq -r '.status' "$ledger")"
	return 0
}

test_concurrent_registration_is_atomic() {
	export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/concurrent-ledger"
	mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	AIDEVOPS_RUNNER_DEVICE_ID=device-a "$LEDGER_HELPER" register --session-key issue-race --issue 55 --repo owner/repo --pid $$ &
	local pid_a=$!
	AIDEVOPS_RUNNER_DEVICE_ID=device-b "$LEDGER_HELPER" register --session-key issue-race --issue 55 --repo owner/repo --pid $$ &
	local pid_b=$!
	wait "$pid_a"
	wait "$pid_b"
	local ledger="${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"
	assert_eq "concurrent registration leaves one valid owner" "1" "$(jq -s '[.[] | select(.session_key == "issue-race")] | length' "$ledger")"
	jq -e 'select(.runner_device == "device-a" or .runner_device == "device-b")' "$ledger" >/dev/null \
		&& pass "same-login devices remain distinguishable" || fail "same-login devices remain distinguishable"
	return 0
}

test_claim_marker_contains_lease_identity() {
	local now=""
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	jq -n --arg now "$now" '[{id:999,body:"",created_at:$now}]' >"${TEST_ROOT}/claim-comments.json"
	export AIDEVOPS_TEST_MODE=1
	export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1
	export AIDEVOPS_RUNNER_DEVICE_ID="device-beta"
	export DISPATCH_CLAIM_WINDOW=0
	# The mock initially returns only the just-posted body through last-post; make
	# a second lightweight mock response by running claim in a subshell that
	# teaches the mock to replay the POST body on GET.
	python3 - "${TEST_ROOT}/bin/gh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('if [[ -f "${state_dir}/claim-comments.json" ]]; then\n\t\tcat "${state_dir}/claim-comments.json"', 'if [[ -f "${state_dir}/last-post.txt" ]]; then\n\t\tjq -n --rawfile body "${state_dir}/last-post.txt" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \'[{id:999,body:$body,created_at:$now}]\'\n\telif [[ -f "${state_dir}/claim-comments.json" ]]; then\n\t\tcat "${state_dir}/claim-comments.json"')
p.write_text(s)
PY
	local output="" rc=0
	output=$("$CLAIM_HELPER" claim 27165 owner/repo same-login 2>&1) || rc=$?
	assert_eq "lease-aware claim wins deterministic single-runner race" "0" "$rc"
	local body=""
	body=$(<"${TEST_ROOT}/last-post.txt")
	[[ "$body" == *"device=device-beta"* && "$body" == *"session=issue-27165"* ]] \
		&& pass "claim marker distinguishes device and session" || fail "claim marker distinguishes device and session" "$body"
	[[ "$body" == *"lease_phase=pre-launch"* && "$body" == *"lease_expires_at="* ]] \
		&& pass "claim marker carries bounded pre-launch lease" || fail "claim marker carries bounded pre-launch lease" "$body"
	[[ "$output" == *"device=device-beta"* ]] && pass "claim result exposes deterministic owner device" || fail "claim result exposes deterministic owner device" "$output"
	return 0
}

test_worker_readiness_and_terminal_evidence() {
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/lifecycle-ledger"
	export AIDEVOPS_RUNNER_DEVICE_ID="device-runtime"
	export WORKER_SESSION_KEY="issue-77"
	export WORKER_ISSUE_NUMBER="77"
	export DISPATCH_REPO_SLUG="owner/repo"
	export AIDEVOPS_WORKER_ID="worker:issue-77:test"
	mkdir -p "$HOME" "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	"$LEDGER_HELPER" register --session-key issue-77 --issue 77 --repo owner/repo --pid $$
	# shellcheck source=../worker-lifecycle-common.sh
	source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
	_update_dispatch_lease_from_runtime_event worker.started
	local ledger="${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"
	assert_eq "worker self-report promotes ledger lease" "active" "$(jq -r '.lease_phase' "$ledger")"
	local body=""
	body=$(<"${TEST_ROOT}/last-post.txt")
	[[ "$body" == *"DISPATCH_LEASE phase=active"* && "$body" == *"runner_device=device-runtime"* ]] \
		&& pass "worker readiness emits public lease evidence" || fail "worker readiness emits public lease evidence" "$body"

	_update_dispatch_lease_from_runtime_event worker.completed
	assert_eq "worker terminal self-report closes ledger lease" "terminal" "$(jq -r '.lease_phase' "$ledger")"
	body=$(<"${TEST_ROOT}/last-post.txt")
	[[ "$body" == *"DISPATCH_LEASE phase=terminal"* && "$body" == *"outcome=completed"* ]] \
		&& pass "worker completion emits terminal lease evidence" || fail "worker completion emits terminal lease evidence" "$body"
	return 0
}

test_expired_launch_reverification() {
	SCRIPT_DIR="$TEST_ROOT"
	# shellcheck source=../dispatch-dedup-stale.sh
	source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"
	local claim_ts="2026-01-01T00:00:00Z"
	local expired="2026-01-01T00:01:00Z"
	local future="2099-01-01T00:00:00Z"
	local claim_body="DISPATCH_CLAIM nonce=n runner=same-login ts=${claim_ts} device=device-a session=issue-55 lease_phase=pre-launch lease_expires_at=${expired}"
	local launch_crash_json=""
	launch_crash_json=$(jq -n --arg claim "$claim_body" --arg ts "$claim_ts" '[
		{created_at:"2026-01-01T00:01:01Z",body_start:"Dispatching worker (deterministic)."},
		{created_at:$ts,body_start:$claim}
	]')
	local rc=0
	_stale_assignment_recheck_expired_prelaunch_lease 55 owner/repo "$launch_crash_json" "$(date +%s)" || rc=$?
	assert_eq "spawn intent without readiness is reclaimable after expiry" "0" "$rc"

	local ready_json=""
	ready_json=$(jq -n --arg claim "$claim_body" --arg ts "$claim_ts" --arg future "$future" '[
		{created_at:"2026-01-01T00:01:02Z",body_start:("DISPATCH_LEASE phase=active expires_at=" + $future)},
		{created_at:$ts,body_start:$claim}
	]')
	rc=0
	_stale_assignment_recheck_expired_prelaunch_lease 55 owner/repo "$ready_json" "$(date +%s)" || rc=$?
	assert_eq "active remote worker blocks takeover" "2" "$rc"

	export MOCK_OPEN_PR_JSON='[{"number":88}]'
	rc=0
	_stale_assignment_recheck_expired_prelaunch_lease 55 owner/repo "$launch_crash_json" "$(date +%s)" || rc=$?
	assert_eq "open PR evidence blocks expired-lease takeover" "2" "$rc"
	export MOCK_OPEN_PR_JSON='[]'
	return 0
}

setup_mock_gh
test_ledger_phase_transitions
test_concurrent_registration_is_atomic
test_claim_marker_contains_lease_identity
test_worker_readiness_and_terminal_evidence
test_expired_launch_reverification

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
