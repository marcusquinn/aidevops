#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#37344: deferred claim-release retry evidence and recovery consumer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
ROOT="${RETRY_TEST_ROOT:-}"
if [[ -z "$ROOT" ]]; then
	ROOT=$(mktemp -d) || exit 1
	trap 'rm -rf "$ROOT"' EXIT
fi
export AIDEVOPS_CLAIM_RELEASE_RETRY_DIR="${ROOT}/retry"
export AIDEVOPS_DISPATCH_LEASE_TOKEN="tok" AIDEVOPS_DISPATCH_LEASE_DEVICE="dev"
export AIDEVOPS_DISPATCH_LEASE_SESSION="issue-42" WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="o/r"

print_warning() {
	return 0
}
print_info() {
	return 0
}
# shellcheck source=../headless-runtime-release-retry.sh
source "${SCRIPT_DIR}/headless-runtime-release-retry.sh"

PASS=0 FAIL=0
check() {
	if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s (got %q want %q)\n' "$1" "$2" "$3"
	fi
	return 0
}
rows() {
	find "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
	return 0
}
age_rows() {
	local f
	for f in "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json; do
		[[ -f "$f" ]] && jq '.next_after = 0 | .pid = 999999' "$f" >"${f}.t" && mv "${f}.t" "$f"
	done
	return 0
}

# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh" 2>/dev/null || true

if [[ "${1:-}" == real-* ]]; then
	_hrff_release_issue_number() { printf '42\n'; return 0; }
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_resolve_release_runner_login() { printf 'runner\n'; return 0; }
	_hrff_check_release_claim() { _HRFF_RELEASE_CLAIM_OWNED="${TEST_OWNED:-1}"; _HRFF_RELEASE_CLAIM_ID=123; return 0; }
	_hrff_blocked_release_persisted() { return 1; }
	_hrff_enqueue_observation_recovery() { return 0; }
	_unlock_issue_after_dispatch_release() { return 0; }
	clear_active_status_on_release() { printf '%s\n' "$4" >>"${ROOT}/projection"; return 0; }
	gh_issue_edit_safe() { [[ " $* " != *" --add-label status:blocked "* ]] || printf 'blocked\n' >>"${ROOT}/projection"; return 0; }
	gh() { printf '%s\n' '{"title":"test","body":"scope","state":"open","labels":[],"assignees":[]}'; return 0; }
	terminal_blocker_fetch_trusted_comments() { printf '[]\n'; return 0; }
	_terminal_blocker_dependency_signature() { printf '[]\n'; return 0; }
	_hrff_post_claim_released_comment() {
		[[ "${ADMISSION:-0}" == 1 ]] || return 1
		printf '%s\n' "$3" >>"${ROOT}/published"
		return 0
	}
	if [[ "$1" == real-spec-* ]]; then
		# GH#38021: issue #42 is a canonical consolidated spec. SPEC_CARRIES=1 is
		# the read before the checkpoint escalation; otherwise the released state.
		# The drain shell loads the continuation module only through the replay.
		_gh_with_timeout() { shift; "$@"; return $?; }
		gh() {
			local labels='["status:available","consolidated"]'
			[[ "${SPEC_CARRIES:-0}" != 1 ]] || labels='["status:in-progress","consolidated","auto-dispatch"]'
			[[ "$*" == "api repos/o/r/issues/42" ]] || return 1
			jq -cn --argjson labels "$labels" --arg body '_Supersedes #7 — this issue is the consolidated spec._' \
				'{state: "open", body: $body, assignees: [], labels: [$labels[] | {name: .}]}'
			return 0
		}
		set_issue_status() { printf '%s\n' "$*" >>"${ROOT}/projection"; return 0; }
	fi
	if [[ "$1" == real-record ]]; then
		export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$ROOT"
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash "v2:${TEST_REASON}")
		export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
		_release_dispatch_claim issue-42 blocked 1 1 || true
	elif [[ "$1" == real-spec-record ]]; then
		# The checkpoint escalation loads the module and reads the issue first.
		# shellcheck source=../pulse-merge-partial-continuation.sh
		source "${SCRIPT_DIR}/pulse-merge-partial-continuation.sh"
		_pmpc_record_checkpoint_spec_dispatch o/r 42 || true
		_release_dispatch_claim issue-42 worker_draft_checkpoint 1 1 || true
	else
		_hrrr_drain
	fi
	exit 0
fi

: >"${ROOT}/writes"
ATTEMPT_RC=1
_hrff_release_dispatch_claim_attempt() {
	# Replay runs in a subshell, so count writes through a file.
	if [[ "$ATTEMPT_RC" -eq 0 ]]; then
		printf 'w\n' >>"${ROOT}/writes"
		return 0
	fi
	return 1
}
writes() {
	wc -l <"${ROOT}/writes" | tr -d ' '
	return 0
}
_hrff_release_issue_number() {
	printf '42\n'
	return 0
}

# 1. Deferred release records one private row (idempotent on repeat).
_release_dispatch_claim issue-42 blocked 1 1
_release_dispatch_claim issue-42 blocked 1 1
check "row recorded once" "$(rows)" "1"
check "row mode private" "$(stat -c %a "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json 2>/dev/null || stat -f %Lp "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json)" "600"

# 2. Not yet due / live original worker: no replay, row retained.
_hrrr_drain >/dev/null
check "not-due row retained" "$(rows)" "1"
for f in "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json; do jq ".next_after = 0 | .pid = $$" "$f" >"${f}.t" && mv "${f}.t" "$f"; done
_hrrr_drain >/dev/null
check "live worker row retained" "$(rows)" "1"
check "live worker no write" "$(writes)" "0"

# 3. Continued deferral keeps evidence and counts the attempt.
age_rows
_hrrr_drain >/dev/null
check "deferral retains row" "$(rows)" "1"
check "attempt counted" "$(jq -r .attempts "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json)" "1"

# 4. Admission recovers: release persisted once, row removed, replay is a no-op.
age_rows
ATTEMPT_RC=0
check "drain summary" "$(_hrrr_drain)" "candidates=1 resolved=1 retained=0"
check "one release write" "$(writes)" "1"
check "row removed" "$(rows)" "0"
_hrrr_drain >/dev/null
check "no duplicate write" "$(writes)" "1"

# 5. Success clears prior evidence; a failure without lease binding records nothing.
ATTEMPT_RC=1
_release_dispatch_claim issue-42 blocked 1 1
ATTEMPT_RC=0
_release_dispatch_claim issue-42 blocked 1 1
check "success clears row" "$(rows)" "0"
ATTEMPT_RC=1
AIDEVOPS_DISPATCH_LEASE_TOKEN="" _release_dispatch_claim issue-42 blocked 1 1
check "no binding no row" "$(rows)" "0"

# 6. Expired evidence is dropped without any write.
_release_dispatch_claim issue-42 blocked 1 1
for f in "$AIDEVOPS_CLAIM_RELEASE_RETRY_DIR"/*.json; do jq '.created = 1 | .next_after = 0 | .pid = 999999' "$f" >"${f}.t" && mv "${f}.t" "$f"; done
: >"${ROOT}/writes"
_hrrr_drain >/dev/null
check "expired row dropped" "$(rows)" "0"
check "expired no write" "$(writes)" "0"

# 7. Blocker context survives serialization; malformed and legacy rows fail closed.
export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$ROOT"
export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:permission_required')
_release_dispatch_claim issue-42 blocked 1 1
age_rows
f=$(_hrrr_path o/r 42 issue-42)
blocker_path="" fingerprint="" missing_secrets=""
_hrrr_read_blocker "$f" blocked
check "classified fingerprint restored" "$fingerprint" "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
check "classified path restored" "$blocker_path" "$ROOT"
jq '.blocker.fingerprint = "000000000000000000000000"' "$f" >"${f}.t" && mv "${f}.t" "$f"
_hrrr_drain >/dev/null
check "changed observation retained" "$(rows)" "1"
check "changed observation not replayed" "$(writes)" "0"
jq 'del(.blocker)' "$f" >"${f}.t" && mv "${f}.t" "$f"
_hrrr_drain >/dev/null
check "legacy blocker retained" "$(rows)" "1"
check "legacy blocker not replayed" "$(writes)" "0"

# Exercise the actual release attempt in separate recording and drain shells.
rm -f "$f"
for test_case in permission_required source_access_blocked runner_capability_unmet runner_capability_no_secret; do
	test_reason="$test_case" expected=blocked missing=""
	if [[ "$test_case" == runner_capability_no_secret ]]; then
		test_reason=runner_capability_unmet expected=available
	elif [[ "$test_case" == runner_capability_unmet ]]; then
		missing=TEST_SECRET
	fi
	: >"${ROOT}/projection"
	RETRY_TEST_ROOT="$ROOT" TEST_REASON="$test_reason" AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS="$missing" bash "$0" real-record
	age_rows
	RETRY_TEST_ROOT="$ROOT" ADMISSION=1 bash "$0" real-drain >/dev/null
	check "real replay ${test_reason} removed" "$(rows)" "0"
	check "real replay ${test_reason} marker" "$(rg -c "reason=${test_reason}" "${ROOT}/published")" "1"
	check "real replay ${test_case} projection" "$(<"${ROOT}/projection")" "$expected"
	RETRY_TEST_ROOT="$ROOT" ADMISSION=1 bash "$0" real-drain >/dev/null
	check "real replay ${test_reason} no duplicate" "$(rg -c "reason=${test_reason}" "${ROOT}/published")" "1"
	: >"${ROOT}/published"
done
RETRY_TEST_ROOT="$ROOT" TEST_REASON=permission_required bash "$0" real-record
age_rows
RETRY_TEST_ROOT="$ROOT" ADMISSION=1 TEST_OWNED=0 bash "$0" real-drain >/dev/null
check "changed owner no write" "$(wc -c <"${ROOT}/published" | tr -d ' ')" "0"

# GH#38021: a deferred draft-checkpoint release carries the recording run's
# proof that it removed auto-dispatch from a consolidated spec. The replay runs
# in another process and restores the label only with that proof.
f=$(_hrrr_path o/r 42 issue-42)
rm -f "$f" "${f}.binding"
for carried in 1 0; do
	expected_field=false expected_projection=available
	if [[ "$carried" == 1 ]]; then
		expected_field=true
		expected_projection=$'available\n42 o/r available --add-label auto-dispatch'
	fi
	: >"${ROOT}/projection"
	RETRY_TEST_ROOT="$ROOT" SPEC_CARRIES="$carried" bash "$0" real-spec-record
	check "spec receipt carried=${carried} recorded" "$(jq -r '.spec_dispatch // false' "$f" 2>/dev/null)" "$expected_field"
	age_rows
	RETRY_TEST_ROOT="$ROOT" ADMISSION=1 bash "$0" real-spec-drain >/dev/null
	check "spec replay carried=${carried} removed" "$(rows)" "0"
	check "spec replay carried=${carried} projection" "$(<"${ROOT}/projection")" "$expected_projection"
done
# A receipt added to a row after it was written does not match the binding.
: >"${ROOT}/projection"
RETRY_TEST_ROOT="$ROOT" SPEC_CARRIES=0 bash "$0" real-spec-record
age_rows
jq '.spec_dispatch = true' "$f" >"${f}.t" && mv "${f}.t" "$f"
RETRY_TEST_ROOT="$ROOT" ADMISSION=1 bash "$0" real-spec-drain >/dev/null
check "edited spec receipt retained" "$(rows)" "1"
check "edited spec receipt not replayed" "$(wc -c <"${ROOT}/projection" | tr -d ' ')" "0"

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
