#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PULSE_CHECK_SOURCE_ONLY=1
# shellcheck source=../pulse-check-helper.sh
source "${SCRIPT_DIR}/../pulse-check-helper.sh"

finding='{"family_fingerprint":"ff-v1:test","family_count":4,"family_recent_count":2}'

gh() { return 75; }
rc=0
_refresh_failure_family_issue "owner/repo" "42" "$finding" || rc=$?
[[ "$rc" -eq 75 ]] || {
	printf 'expected body-read exit 75, got %s\n' "$rc" >&2
	exit 1
}

gh() { printf 'existing body\n'; }
_load_gh_wrappers() { return 0; }
gh_issue_edit_safe() { return 44; }
rc=0
_refresh_failure_family_issue "owner/repo" "42" "$finding" || rc=$?
[[ "$rc" -eq 44 ]] || {
	printf 'expected body-update exit 44, got %s\n' "$rc" >&2
	exit 1
}

closed=0
gh() {
	printf '[{"number":42,"body":"failure-family-state fingerprint=ff-v1:test count=4 recent_count=2 status=recurring","createdAt":"2026-01-01T00:00:00Z"}]\n'
}
_refresh_failure_family_issue() { return 75; }
gh_issue_close_safe() { closed=1; }
rc=0
_reconcile_failure_family_remediations "owner/repo" \
	'{"failure_family_remediation":[{"fingerprint":"ff-v1:test","family":"test","count":4,"recent_count":0,"confidence":"high","recovery_outcome":"not-observed"}]}' || rc=$?
[[ "$rc" -eq 1 && "$closed" -eq 0 ]] || {
	printf 'expected reconciliation refresh failure without close, got rc=%s closed=%s\n' "$rc" "$closed" >&2
	exit 1
}

printf 'PASS failure-family refresh propagation\n'
