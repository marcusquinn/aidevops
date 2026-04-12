#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test dispatch-dedup-helper.sh is-assigned (GH#10521)
#
# Verifies that is_assigned() distinguishes between:
# - Repo maintainer/owner assignment (should NOT block dispatch)
# - Runner account assignment (SHOULD block dispatch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)

	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/config/aidevops"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	# Create a repos.json with a known maintainer
	cat >"${TEST_ROOT}/config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/home/user/Git/aidevops",
      "slug": "marcusquinn/aidevops",
      "pulse": true,
      "maintainer": "marcusquinn-bot"
    },
    {
      "path": "/home/user/Git/other",
      "slug": "orgname/other-repo",
      "pulse": true,
      "maintainer": "orgadmin"
    }
  ]
}
EOF

	# Point the helper to our test repos.json
	export REPOS_JSON="${TEST_ROOT}/config/aidevops/repos.json"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a gh stub that returns specific issue metadata for a given issue.
#
# The stub also serves a recent-activity comment for `gh api .../comments`
# so that _is_stale_assignment() in dispatch-dedup-helper.sh returns
# "not stale" (exit 1). Without this, the stale recovery path fires in
# the test environment (empty comments → no activity → treated as stale
# → block → recover → allow dispatch), causing all "blocks dispatch"
# assertions to flip. The recent-activity timestamp is generated fresh
# at stub creation time to guarantee it's under the 10-minute threshold.
create_gh_stub() {
	local assignees_csv="$1"
	local labels_csv="${2:-}"
	local state="${3:-OPEN}"
	local assignees_json labels_json recent_ts

	assignees_json=$(
		ASSIGNEES_CSV="$assignees_csv" python3 - <<'PY'
import json
import os
items=[item for item in os.environ.get('ASSIGNEES_CSV','').split(',') if item]
print(json.dumps([{"login": item} for item in items]))
PY
	)
	labels_json=$(
		LABELS_CSV="$labels_csv" python3 - <<'PY'
import json
import os
items=[item for item in os.environ.get('LABELS_CSV','').split(',') if item]
print(json.dumps([{"name": item} for item in items]))
PY
	)

	# Fresh UTC timestamp so the synthetic comment is always "recent"
	# regardless of when the test runs.
	recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"${state}","assignees":${assignees_json},"labels":${labels_json}}'
	exit 0
fi

# Stale-assignment recovery calls: gh api repos/<slug>/issues/<num>/comments --jq '...'
# Return a single recent "Dispatching worker" comment so the helper's
# _is_stale_assignment() sees active work and does NOT recover the
# assignment. The --jq filter is applied by the real gh client, but the
# helper's own subsequent jq calls work on this array directly.
if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -q '/comments'; then
	printf '%s\n' '[{"created_at":"${recent_ts}","author":"runner1","body_start":"Dispatching worker (PID 12345)"}]'
	exit 0
fi

# gh issue edit / gh issue comment — used by _recover_stale_assignment in
# the unlikely event a test trips it. Succeed silently so the recovery is
# idempotent and doesn't break the test run.
if [[ "\${1:-}" == "issue" && ("\${2:-}" == "edit" || "\${2:-}" == "comment") ]]; then
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "\$*" >&2
exit 1
GHEOF

	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Test: unassigned issue → safe to dispatch (exit 1)
test_unassigned_issue() {
	create_gh_stub ""

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "unassigned issue allows dispatch" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "unassigned issue allows dispatch" 0
	return 0
}

# Test: assigned to self → safe to dispatch (exit 1)
test_assigned_to_self() {
	create_gh_stub "runner1"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "assigned to self allows dispatch" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "assigned to self allows dispatch" 0
	return 0
}

# Test: assigned to repo owner (from slug) → safe to dispatch (exit 1)
# GH#10521: marcusquinn is the owner in marcusquinn/aidevops
test_assigned_to_repo_owner() {
	create_gh_stub "marcusquinn"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "assigned to repo owner allows dispatch (GH#10521)" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "assigned to repo owner allows dispatch (GH#10521)" 0
	return 0
}

# Test: assigned to repo maintainer (from repos.json) → safe to dispatch (exit 1)
# GH#10521: maintainer from repos.json should not block
test_assigned_to_maintainer() {
	create_gh_stub "marcusquinn-bot"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "assigned to maintainer allows dispatch (GH#10521)" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "assigned to maintainer allows dispatch (GH#10521)" 0
	return 0
}

# Test: assigned to another runner → block dispatch (exit 0)
test_assigned_to_another_runner() {
	create_gh_stub "other-runner"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'other-runner'*)
			print_result "assigned to another runner blocks dispatch" 0
			return 0
			;;
		esac
		print_result "assigned to another runner blocks dispatch" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "assigned to another runner blocks dispatch" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# Test: assigned to both maintainer AND another runner → block dispatch (exit 0)
test_mixed_assignees_with_runner() {
	create_gh_stub "marcusquinn,other-runner"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'other-runner'*)
			print_result "mixed assignees with runner blocks dispatch" 0
			return 0
			;;
		esac
		print_result "mixed assignees with runner blocks dispatch" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "mixed assignees with runner blocks dispatch" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# Test: assigned to both maintainer AND self → safe to dispatch (exit 1)
test_mixed_assignees_maintainer_and_self() {
	create_gh_stub "marcusquinn,runner1"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "maintainer + self allows dispatch" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "maintainer + self allows dispatch" 0
	return 0
}

# Test: different repo — maintainer from repos.json for orgname/other-repo
test_different_repo_maintainer() {
	create_gh_stub "orgadmin"

	if "$HELPER_SCRIPT" is-assigned 200 orgname/other-repo runner1 >/dev/null 2>&1; then
		print_result "different repo maintainer allows dispatch" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "different repo maintainer allows dispatch" 0
	return 0
}

# Test: no self_login provided, assigned to owner → safe (exit 1)
test_no_self_login_owner_assigned() {
	create_gh_stub "marcusquinn"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops >/dev/null 2>&1; then
		print_result "no self_login + owner assigned allows dispatch" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "no self_login + owner assigned allows dispatch" 0
	return 0
}

# Test: owner assignment becomes blocking when active claim state exists
test_owner_assigned_with_active_status_blocks() {
	create_gh_stub "marcusquinn" "status:queued"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn'*)
			print_result "owner + status:queued blocks dispatch (GH#11141)" 0
			return 0
			;;
		esac
		print_result "owner + status:queued blocks dispatch (GH#11141)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "owner + status:queued blocks dispatch (GH#11141)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# Test: maintainer assignment becomes blocking when active claim state exists
test_maintainer_assigned_with_active_status_blocks() {
	create_gh_stub "marcusquinn-bot" "status:in-progress"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn-bot'*)
			print_result "maintainer + status:in-progress blocks dispatch (GH#11141)" 0
			return 0
			;;
		esac
		print_result "maintainer + status:in-progress blocks dispatch (GH#11141)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "maintainer + status:in-progress blocks dispatch (GH#11141)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# GH#18352: owner + status:claimed blocks dispatch.
# Regression guard for the exact race that produced #18352: an interactive
# session claimed a task via claim-task-id.sh, which applied status:claimed
# + owner assignment. The old code only treated queued/in-progress as active,
# so the owner-passive exemption fired and the pulse raced the interactive
# session with a duplicate worker.
test_owner_assigned_with_status_claimed_blocks() {
	create_gh_stub "marcusquinn" "status:claimed"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn'*)
			print_result "owner + status:claimed blocks dispatch (GH#18352)" 0
			return 0
			;;
		esac
		print_result "owner + status:claimed blocks dispatch (GH#18352)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "owner + status:claimed blocks dispatch (GH#18352)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# GH#18352: owner + status:in-review blocks dispatch.
# Once an interactive session opens a PR, the issue transitions to in-review.
# The pulse must not dispatch a duplicate worker against an in-review issue
# owned by the maintainer.
test_owner_assigned_with_status_in_review_blocks() {
	create_gh_stub "marcusquinn" "status:in-review"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn'*)
			print_result "owner + status:in-review blocks dispatch (GH#18352)" 0
			return 0
			;;
		esac
		print_result "owner + status:in-review blocks dispatch (GH#18352)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "owner + status:in-review blocks dispatch (GH#18352)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# GH#18352: owner + origin:interactive blocks dispatch even without a status
# label. origin:interactive is a strong "human session owns this" signal —
# the pulse must never race an in-flight interactive session regardless of
# whether the status label has caught up yet.
test_owner_assigned_with_origin_interactive_blocks() {
	create_gh_stub "marcusquinn" "origin:interactive,bug"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn'*)
			print_result "owner + origin:interactive blocks dispatch (GH#18352)" 0
			return 0
			;;
		esac
		print_result "owner + origin:interactive blocks dispatch (GH#18352)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "owner + origin:interactive blocks dispatch (GH#18352)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# GH#18352: maintainer + origin:interactive blocks dispatch.
# Same rule as owner — origin:interactive overrides the passive exemption.
test_maintainer_assigned_with_origin_interactive_blocks() {
	create_gh_stub "marcusquinn-bot" "origin:interactive"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'marcusquinn-bot'*)
			print_result "maintainer + origin:interactive blocks dispatch (GH#18352)" 0
			return 0
			;;
		esac
		print_result "maintainer + origin:interactive blocks dispatch (GH#18352)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "maintainer + origin:interactive blocks dispatch (GH#18352)" 1 "Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# Regression: the original owner-passive exemption must still work when
# neither an active status label nor origin:interactive is present.
# A bare owner-assignment from auto-triage workflows must not block dispatch
# (this preserves the GH#10521 queue-starvation fix).
test_owner_assigned_no_status_no_origin_allows_dispatch() {
	create_gh_stub "marcusquinn" "bug"

	if "$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 >/dev/null 2>&1; then
		print_result "owner + no active status + no origin:interactive allows dispatch (GH#10521 regression)" 1 "Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "owner + no active status + no origin:interactive allows dispatch (GH#10521 regression)" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_unassigned_issue
	test_assigned_to_self
	test_assigned_to_repo_owner
	test_assigned_to_maintainer
	test_assigned_to_another_runner
	test_mixed_assignees_with_runner
	test_mixed_assignees_maintainer_and_self
	test_different_repo_maintainer
	test_no_self_login_owner_assigned
	test_owner_assigned_with_active_status_blocks
	test_maintainer_assigned_with_active_status_blocks
	test_owner_assigned_with_status_claimed_blocks
	test_owner_assigned_with_status_in_review_blocks
	test_owner_assigned_with_origin_interactive_blocks
	test_maintainer_assigned_with_origin_interactive_blocks
	test_owner_assigned_no_status_no_origin_allows_dispatch

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
