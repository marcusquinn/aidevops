#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for the `_close_conflicting_pr` close-comment wording
# (GH#17574 / t2032) AND the file-overlap verification (GH#18815).
#
# Verifies that when the deterministic merge pass detects "work already
# on main", the close comment:
#   1. Says "landed on main" — NOT "committed directly to main"
#   2. Includes "(via PR #NNN)" when the matching commit has a
#      squash-merge suffix
#   3. Omits the parenthetical when no PR number is parseable
#   4. (GH#18815) Only fires when the matching commit and the closing PR
#      share a non-planning file path. A planning-only match (e.g., the
#      #18760 ↔ #18749 false positive) must NOT close the PR.
#   5. (GH#18815) Fails CLOSED when file lookups error out — leave the PR
#      open and post a rebase nudge instead of discarding work.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
STUB_DIR=""
CAPTURED_COMMENT_FILE=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Stub `gh` for the new file-overlap-aware contract. The stub dispatches on
# argument shape and reads predetermined response files written by each test
# case. This keeps the stub stable across tests — only the response files
# change per case.
#
# Response files (written by set_responses):
#   $TEST_ROOT/commits.json     — output for `gh api repos/.../commits` (JSON array)
#   $TEST_ROOT/commit-files.txt — output for `gh api repos/.../commits/SHA` (lines)
#   $TEST_ROOT/pr-files.txt     — output for `gh pr view N --json files` (lines)
#   $TEST_ROOT/pr-labels.txt    — output for `gh pr view N --json labels` (lines)
#   $TEST_ROOT/pr-branch.txt    — output for `gh pr view N --json headRefName`
#
# A missing or empty response file makes the stub exit 1, simulating a gh
# API failure for the relevant call.
write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
TEST_ROOT="${TEST_ROOT}"
CAPTURED_COMMENT_FILE="${CAPTURED_COMMENT_FILE}"

if [[ "\$1" == "api" ]]; then
	url="\$2"
	if [[ "\$url" =~ /commits/[a-f0-9]+\$ ]]; then
		# gh api repos/X/Y/commits/SHA --jq '.files[].filename'
		response="\${TEST_ROOT}/commit-files.txt"
		if [[ ! -s "\$response" ]]; then
			exit 1
		fi
		cat "\$response"
		exit 0
	elif [[ "\$url" =~ /commits\$ ]]; then
		# gh api repos/X/Y/commits --jq '[.[] | {sha, subject}]'
		response="\${TEST_ROOT}/commits.json"
		if [[ ! -s "\$response" ]]; then
			exit 1
		fi
		cat "\$response"
		exit 0
	fi
	exit 0
fi

if [[ "\$1" == "pr" && "\$2" == "close" ]]; then
	shift 2
	while [[ \$# -gt 0 ]]; do
		if [[ "\$1" == "--comment" ]]; then
			printf '%s' "\$2" >"\${CAPTURED_COMMENT_FILE}"
			shift 2
		else
			shift
		fi
	done
	exit 0
fi

if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
	# Find the --json field name to know which response to emit.
	field=""
	args=("\$@")
	i=2
	while [[ \$i -lt \${#args[@]} ]]; do
		if [[ "\${args[\$i]}" == "--json" ]]; then
			j=\$((i + 1))
			field="\${args[\$j]}"
			break
		fi
		i=\$((i + 1))
	done
	case "\$field" in
		labels)
			response="\${TEST_ROOT}/pr-labels.txt"
			if [[ -f "\$response" ]]; then cat "\$response"; fi
			exit 0
			;;
		files)
			response="\${TEST_ROOT}/pr-files.txt"
			if [[ ! -s "\$response" ]]; then exit 1; fi
			cat "\$response"
			exit 0
			;;
		headRefName)
			response="\${TEST_ROOT}/pr-branch.txt"
			if [[ -f "\$response" ]]; then cat "\$response"; else echo "feature/test"; fi
			exit 0
			;;
		*)
			exit 0
			;;
	esac
fi

exit 0
STUB_EOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	STUB_DIR="${TEST_ROOT}/stubs"
	CAPTURED_COMMENT_FILE="${TEST_ROOT}/captured-comment.txt"
	mkdir -p "$STUB_DIR"
	: >"$CAPTURED_COMMENT_FILE"

	write_stub_gh

	export PATH="${STUB_DIR}:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Source the helpers under test from pulse-merge.sh in isolation. The
# parent module is sourced by pulse-wrapper.sh and depends on bootstrap
# state, so we extract just the function bodies into a temp file and
# source that.
load_functions_under_test() {
	local repo_root
	repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
	local src="${repo_root}/.agents/scripts/pulse-merge.sh"
	local tmp_fn="${TEST_ROOT}/pulse-merge-funcs.sh"

	# Extract these functions in order:
	#   _is_planning_path_for_overlap
	#   _verify_pr_overlaps_commit
	#   _post_rebase_nudge_on_worker_conflicting
	#   _close_conflicting_pr
	# Each definition uses tab-indented bodies with a column-0 "}" closer.
	awk '
		/^_is_planning_path_for_overlap\(\) \{$/    { fn=1 }
		/^_verify_pr_overlaps_commit\(\) \{$/        { fn=1 }
		/^_post_rebase_nudge_on_worker_conflicting\(\) \{$/ { fn=1 }
		/^_close_conflicting_pr\(\) \{$/             { fn=1 }
		fn { print }
		fn && /^\}$/ { fn=0 }
	' "$src" >"$tmp_fn"

	# shellcheck source=/dev/null
	source "$tmp_fn"
	return 0
}

# Helper to write per-test response files.
set_responses() {
	local commits_json="$1"
	local commit_files="$2"
	local pr_files="$3"
	printf '%s' "$commits_json" >"${TEST_ROOT}/commits.json"
	printf '%s' "$commit_files" >"${TEST_ROOT}/commit-files.txt"
	printf '%s' "$pr_files" >"${TEST_ROOT}/pr-files.txt"
	# Default empty labels (no origin:interactive)
	: >"${TEST_ROOT}/pr-labels.txt"
	echo "feature/test" >"${TEST_ROOT}/pr-branch.txt"
	return 0
}

# ── Test cases ──

test_wording_with_squash_merge_pr_number() {
	setup_sandbox
	# Matching commit has the standard squash-merge "(#18480)" suffix AND
	# touches the same implementation file as the closing PR — genuine duplicate.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2017: teach /review-issue-pr to do temporal-duplicate checks (#18480)"},{"sha":"def4567890abcdef","subject":"chore: something else"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr with temporal-duplicate checks"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on main (via PR #18480)"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "cites '(via PR #NNN)' when matching commit has squash-merge suffix" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

test_wording_without_pr_number_fallback() {
	setup_sandbox
	# Matching commit is a direct-to-main commit with no "(#NNN)" suffix
	# but DOES touch the same implementation file → genuine duplicate.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2017: direct push to main without going through a PR"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on main,"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "(via PR #"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "omits parenthetical when no PR number parseable" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

test_no_match_uses_fallback_message() {
	setup_sandbox
	# No commit on main matches the task ID → falls through to the
	# "work NOT on main" branch; comment must NOT claim "landed on main".
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: totally unrelated commit"},{"sha":"def4567890abcdef","subject":"feat: still unrelated"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if printf '%s' "$body" | grep -q "landed on main"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi
	if ! printf '%s' "$body" | grep -q "merge conflicts"; then
		result=1
	fi

	print_result "no-match uses 're-attempt' fallback, not 'landed on main'" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

# GH#18815 regression: reproduces the PR #18760 false-positive close.
# The matching commit only touches planning files (TODO.md + briefs); the
# closing PR touches an implementation script. The function MUST NOT close.
test_no_close_when_matching_commit_only_touches_planning_files() {
	setup_sandbox
	set_responses \
		'[{"sha":"deadbeefcafe1234","subject":"plan(t2059, t2060): file follow-ups from GH#18538 worker-is-triager session (#18749)"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		"$(printf 'TODO.md\ntodo/tasks/t2059-brief.md\ntodo/tasks/t2060-brief.md')" \
		"$(printf '.agents/scripts/task-complete-helper.sh\n.agents/scripts/tests/test-task-complete-move.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	# Must NOT have called gh pr close (captured comment file is empty)
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	# Must have logged the false-positive detection
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi
	if ! grep -q "GH#18815" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: planning-only match leaves PR open (no close)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# GH#18815 regression: confirms genuine duplicates (real implementation
# file overlap) still close as before.
test_close_when_matching_commit_overlaps_implementation_files() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')" \
		"$(printf '.agents/scripts/task-complete-helper.sh\n.agents/scripts/tests/test-task-complete-move.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ ! -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! printf '%s' "$body" | grep -q "has already landed on main (via PR #18999)"; then
		result=1
	fi

	print_result "GH#18815: real implementation overlap still closes PR" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

# GH#18815 regression: file lookup failure → fail-CLOSED → no auto-close.
# Simulates a gh API failure on the commit-files lookup.
test_no_close_when_commit_files_lookup_fails() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"}]' \
		'' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: commit-files lookup failure leaves PR open (fail-CLOSED)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# GH#18815 regression: PR-files lookup failure → fail-CLOSED → no auto-close.
test_no_close_when_pr_files_lookup_fails() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"}]' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')" \
		''

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: PR-files lookup failure leaves PR open (fail-CLOSED)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# ── Run all tests ──

test_wording_with_squash_merge_pr_number
test_wording_without_pr_number_fallback
test_no_match_uses_fallback_message
test_no_close_when_matching_commit_only_touches_planning_files
test_close_when_matching_commit_overlaps_implementation_files
test_no_close_when_commit_files_lookup_fails
test_no_close_when_pr_files_lookup_fails

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
