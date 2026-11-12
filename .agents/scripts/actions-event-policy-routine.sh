#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Report uncovered managed repositories, optionally applying their event policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=config-helper.sh
source "${SCRIPT_DIR}/config-helper.sh"

main() {
	local helper="${SCRIPT_DIR}/actions-event-policy-helper.sh"
	local output="" rc=0 failed=0 enabled="" line="" slug="" visibility=""
	enabled=$(config_get safety.actions_event_policy_auto_apply false) || return 1
	output=$("$helper" status --all-managed) || rc=$?
	if [[ "$rc" -gt 1 ]]; then
		printf 'Event policy scan encountered errors\n' >&2
		failed=1
	fi
	while IFS= read -r line; do
		case "$line" in
		'OK '*) printf '%s\n' "$line" ;;
		'UNCOVERED '*)
			slug="${line#UNCOVERED }"
			slug="${slug%%:*}"
			if [[ ! "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
				printf 'Invalid uncovered repository: %s\n' "$slug" >&2
				failed=1
			elif [[ "$enabled" != "true" ]]; then
				printf 'UNCOVERED %s: report only (auto-apply disabled)\n' "$slug"
			elif ! visibility=$(gh api --method GET "repos/${slug}" --jq '.visibility // (if .private then "private" else "public" end)'); then
				printf 'ERROR %s: cannot confirm visibility\n' "$slug" >&2
				failed=1
			elif [[ "$visibility" != "public" ]]; then
				printf 'SKIP %s: not public\n' "$slug"
			elif ! "$helper" apply --repo "$slug" >/dev/null; then
				printf 'ERROR %s: apply failed\n' "$slug" >&2
				failed=1
			elif ! "$helper" status --repo "$slug" >/dev/null; then
				printf 'ERROR %s: verification failed\n' "$slug" >&2
				failed=1
			else
				printf 'OK %s: policy applied and verified\n' "$slug"
			fi
			;;
		esac
	done <<<"$output"
	return "$failed"
}

main "$@"
