#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36241: exercise real sourced-library predicates with inputs above pipe capacity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "$SCRIPT_DIR/full-loop-helper-commit.sh"
# shellcheck source=../full-loop-helper-merge.sh
source "$SCRIPT_DIR/full-loop-helper-merge.sh"
# shellcheck source=../claim-task-id-counter.sh
source "$SCRIPT_DIR/claim-task-id-counter.sh"
# shellcheck source=../dispatch-dedup-assignment.sh
source "$SCRIPT_DIR/dispatch-dedup-assignment.sh"
# shellcheck source=../worker-lifecycle-common.sh
source "$SCRIPT_DIR/worker-lifecycle-common.sh"

checks=0
assert_status() {
	local expected="$1"
	shift
	local command_name="$1"
	local actual=0
	"$@" >/dev/null || actual=$?
	if [[ "$actual" -ne "$expected" ]]; then
		printf 'FAIL %s: expected status %s, got %s\n' "$command_name" "$expected" "$actual" >&2
		exit 1
	fi
	checks=$((checks + 1))
	return 0
}

assert_output() {
	local expected="$1"
	shift
	local command_name="$1"
	local actual=""
	actual=$("$@")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s: unexpected output\n' "$command_name" >&2
		exit 1
	fi
	checks=$((checks + 1))
	return 0
}

# Many short lines ensure an early match does not consume the whole payload.
padding=$(awk 'BEGIN { for (i=0; i<16384; i++) print "                " }')
for suffix in "$padding" ""; do
	for prefix in "" "$padding"; do
		assert_status 0 _completion_bookkeeping_body_has_reference "${prefix}Ref #36241${suffix}" 36241
		assert_status 0 _completion_bookkeeping_body_has_closing_reference "${prefix}Resolves #36241${suffix}" 36241
		assert_status 0 _merge_output_is_graphql_rate_limit "${prefix}GraphQL: API rate limit exceeded${suffix}"
		assert_status 0 _merge_output_is_transient_server_error "${prefix}HTTP 503${suffix}"
		assert_status 0 _merge_output_is_review_policy_block "${prefix}At least 1 approving review${suffix}"
		assert_status 0 _cas_push_rejection_is_non_fast_forward "${prefix}non-fast-forward${suffix}"
		assert_status 0 _cas_push_rejection_is_auth_failure "${prefix}Authentication failed${suffix}"
		assert_status 0 _gh_secondary_cooldown_detect "${prefix}secondary rate limit${suffix}"
	done
done
assert_status 1 _completion_bookkeeping_body_has_reference "Ref #362410${padding}" 36241
assert_status 1 _completion_bookkeeping_body_has_closing_reference "Ref #36241${padding}" 36241
for predicate in _merge_output_is_graphql_rate_limit _merge_output_is_transient_server_error \
	_merge_output_is_review_policy_block _cas_push_rejection_is_non_fast_forward \
	_cas_push_rejection_is_auth_failure _gh_secondary_cooldown_detect; do
	assert_status 1 "$predicate" "$padding"
	assert_status 1 "$predicate" ""
done
assert_output primary-rate-limit _gh_secondary_cooldown_body_classification "API rate limit exceeded${padding}"
response=$(printf 'HTTP/2 403\r\nRetry-After: 30\r\n\r\n%s\nRetry-After: 90\n' "$padding")
assert_output 30 _gh_secondary_cooldown_header_value "$response" retry-after
assert_output 403 _gh_secondary_cooldown_status "$response"
assert_output '' _gh_secondary_cooldown_header_value "$response" missing

versions=$(awk 'BEGIN { for (i=0; i<30000; i++) print "9.8.7" }')
assert_output 1.2.0 aidevops_parse_semver "1.2
$versions"
assert_status 1 aidevops_parse_semver "$padding"
labels=$(jq -cn '[range(30000) | {name:"parent-task"}] | {labels:.}')
assert_output 'PARENT_TASK_BLOCKED (label=parent-task)' _is_assigned_check_parent_task "$labels"
assert_output 'BLOCKED (label=parent-task)' _is_assigned_check_label_block "$labels" 36241 test/repo parent-task BLOCKED test
assert_status 1 _is_assigned_check_parent_task '{"labels":[]}'
assert_output 'GUARD_UNCERTAIN (reason=jq-failure call=parent-task-check issue=36241 repo=test/repo)' \
	_is_assigned_check_parent_task '{' 36241 test/repo
brief=$(printf '## Evidence\n.agents/scripts/shared-constants.sh\n## Files to inspect\n## Approach\n## Acceptance criteria\n## Verification\nbash check.sh\n%s' "$padding")
assert_status 0 _escalate_body_has_investigation_context "$brief"
assert_status 1 _escalate_body_has_investigation_context "$padding"

# The selector must drain, not hide a real producer failure behind success.
rc=0
output=$({ printf '%s\n' "$versions"; exit 7; } | sed -n '1p') || rc=$?
[[ "$rc" -eq 7 && "$output" == '9.8.7' ]]
checks=$((checks + 1))
printf 'PASS: %s shared pipe-reader regression checks\n' "$checks"
