#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#39091: source_access_blocked must not map to needs-credentials.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/../shared-constants.sh"
# shellcheck source=../shared-gh-wrappers-status.sh
source "${SCRIPT_DIR}/../shared-gh-wrappers-status.sh"

FAIL=0
check() {
	local name="$1"
	local got="$2"
	local want="$3"
	if [[ "$got" == "$want" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (got=%s want=%s)\n' "$name" "$got" "$want"
		FAIL=1
	fi
	return 0
}

check "source_access_blocked label" "$(blocked_needs_label_for_reason source_access_blocked)" "needs-source-access"
check "missing_secret label" "$(blocked_needs_label_for_reason missing_secret)" "needs-credentials"
check "credentials label" "$(blocked_needs_label_for_reason credentials)" "needs-credentials"
guidance="$(blocked_companion_guidance needs-source-access)"
check "source access guidance owner" "$([[ "$guidance" == *"Owner: access owner"* ]] && echo yes)" "yes"
check "source access guidance has no secret route" "$([[ "$guidance" == *"aidevops secret set"* ]] && echo yes || echo no)" "no"
check "source access label is blocked-owned" "$(printf '%s\n' "${BLOCKED_OWNED_COMPANION_LABELS[@]}" | rg -c '^needs-source-access$')" "1"
check "label-sync defines label" "$(rg -c '^\s+"needs-source-access\|' "${SCRIPT_DIR}/../label-sync-helper.sh")" "1"

[[ "$FAIL" -eq 0 ]]
