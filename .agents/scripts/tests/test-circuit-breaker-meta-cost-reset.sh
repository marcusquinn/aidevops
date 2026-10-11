#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#34349: exercise merge recovery against the production cost aggregator.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../circuit-breaker-meta-filer.sh
source "${SCRIPT_DIR}/circuit-breaker-meta-filer.sh"
# shellcheck source=../dispatch-dedup-cost.sh
source "${SCRIPT_DIR}/dispatch-dedup-cost.sh"

COMMENTS='[[
 {"created_at":"2026-01-01T00:00:00Z","body":"spent 400,000 tokens"},
 {"created_at":"2026-01-02T00:00:00Z","body":"spent 450,484 tokens"}
]]'
EVENTS="" RESET_WRITES=0 COMMENT_FAIL=0 READ_FAIL=0 OTHER_BLOCKERS=0

gh() {
	local command="$1" path="${2:-}"
	case "$command:$path" in
	api:*/comments)
		[[ "$READ_FAIL" == 0 ]] || return 1
		printf '%s' "$COMMENTS"
		;;
	api:*/timeline) printf '[[]]' ;;
	issue:edit) EVENTS+="remove;" ;;
	issue:view) printf '%s' "$OTHER_BLOCKERS" ;;
	*) return 1 ;;
	esac
	return 0
}

gh_issue_comment() {
	local issue="$1" body="${5:-}"
	[[ "$issue" == 7 ]] || return 1
	if [[ "$body" == *"cost-circuit-breaker:reset"* ]]; then
		[[ "$COMMENT_FAIL" == 0 ]] || return 1
		COMMENTS=$(printf '%s' "$COMMENTS" | jq --arg body "$body" \
			'.[0] += [{created_at:"2026-01-03T00:00:00Z", author_association:"COLLABORATOR", body:$body}]') || return 1
		RESET_WRITES=$((RESET_WRITES + 1))
		EVENTS+="reset;"
	else
		EVENTS+="receipt;"
	fi
	return 0
}

set_issue_status() {
	local issue="$1" repo="$2" status="$3"
	[[ "$issue" == 7 && "$repo" == example/app && "$status" == available ]] || return 1
	EVENTS+="available;"
	return 0
}

assert_equal() {
	local actual="$1" expected="$2" description="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s (actual=%s expected=%s)\n' "$description" "$actual" "$expected" >&2
		exit 1
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

assert_equal "$(_sum_issue_token_spend 7 example/app)" '850484|2' 'historical attempts exceed the standard budget'

# A failed read/write must not remove the blocker or publish availability.
READ_FAIL=1
RC=0
_cb_meta_unblock_original example/app 7 example/framework 99 || RC=$?
assert_equal "$RC" 2 'failed comment fetch reports reset failure'
assert_equal "$EVENTS" '' 'failed fetch preserves the structural blocker'
READ_FAIL=0 COMMENT_FAIL=1 RC=0
_cb_meta_unblock_original example/app 7 example/framework 99 || RC=$?
assert_equal "$RC" 2 'failed reset write reports failure'
assert_equal "$EVENTS" '' 'failed reset write preserves the structural blocker'

COMMENT_FAIL=0
_cb_meta_unblock_original example/app 7 example/framework 99 || exit 1
assert_equal "$EVENTS" 'reset;remove;remove;available;receipt;' 'durable reset precedes blocker removal and availability'
assert_equal "$(_sum_issue_token_spend 7 example/app)" '0|0' 'merged meta excludes old spend from the next dispatch'

COMMENTS=$(printf '%s' "$COMMENTS" | jq \
	'.[0] += [{created_at:"2026-01-04T00:00:00Z",body:"spent 12,000 tokens"}]')
assert_equal "$(_sum_issue_token_spend 7 example/app)" '12000|1' 'new attempts still count after recovery'
EVENTS=''
_cb_meta_unblock_original example/app 7 example/framework 99 || exit 1
assert_equal "$RESET_WRITES" 1 'repeated merge cleanup does not reset the window again'
assert_equal "$(_sum_issue_token_spend 7 example/app)" '12000|1' 'repeated cleanup preserves new worker spend'

OTHER_BLOCKERS=1 EVENTS=''
_cb_meta_unblock_original example/app 7 example/framework 99 || exit 1
assert_equal "$EVENTS" 'remove;remove;receipt;' 'another blocker prevents availability despite a durable reset'

printf 'All meta cost-reset regression checks passed\n'
