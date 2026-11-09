#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#37344: deferred claim-release retry evidence and recovery consumer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
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

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
