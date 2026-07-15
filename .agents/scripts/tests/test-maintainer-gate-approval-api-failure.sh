#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27611: signed-approval and PR-label API failures
# must not be coerced into authority decisions or label mutations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/maintainer-gate-reusable.yml"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s' "$test_name"
	if [[ -n "$detail" ]]; then
		printf ': %s' "$detail"
	fi
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t maintainer-gate-approval.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALLS"

	python3 - "$WORKFLOW_FILE" "$TEST_ROOT" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
for job_name, output_name in (
    ("protect-labels", "issue-job.sh"),
    ("protect-pr-labels", "pr-job.sh"),
):
    steps = workflow["jobs"][job_name]["steps"]
    run = next(step["run"] for step in steps if "run" in step)
    (root / output_name).write_text(run)
PY

	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	case "${GH_SCENARIO:-}" in
		pr-label-failure) exit 1 ;;
		pr-*) printf 'external-contributor\n'; exit 0 ;;
	esac
fi

if [[ "${1:-}" == "api" && "$*" == *"/comments"* ]]; then
	case "${GH_SCENARIO:-}" in
		issue-api-failure|pr-approval-failure) exit 1 ;;
		issue-invalid|pr-invalid) printf '{"message":"rate limited"}\n'; exit 0 ;;
		issue-signed|pr-signed) printf '[[{"body":"<!-- aidevops-signed-approval -->"}]]\n'; exit 0 ;;
		issue-unsigned|pr-unsigned) printf '[[]]\n'; exit 0 ;;
	esac
fi

if [[ "${1:-}" == "issue" && ( "${2:-}" == "edit" || "${2:-}" == "comment" ) ]]; then
	exit 0
fi
if [[ "${1:-}" == "pr" && ( "${2:-}" == "edit" || "${2:-}" == "comment" ) ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_issue_job() {
	local scenario="$1"
	GH_SCENARIO="$scenario" \
		ISSUE_NUMBER=42 \
		ISSUE_AUTHOR=external \
		ACTOR=maintainer \
		ACTOR_ASSOCIATION=OWNER \
		REPO=owner/repo \
		GH_TOKEN=test-token \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/issue-job.sh"
}

run_pr_job() {
	local scenario="$1"
	GH_SCENARIO="$scenario" \
		PR_NUMBER=43 \
		PR_AUTHOR=external \
		ACTOR=maintainer \
		REPO=owner/repo \
		GH_TOKEN=test-token \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/pr-job.sh"
}

assert_no_mutation() {
	local test_name="$1"
	if grep -qE '^(issue|pr) edit ' "$GH_CALLS"; then
		print_result "$test_name" 1 "unexpected edit: $(grep -E '^(issue|pr) edit ' "$GH_CALLS")"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

assert_job_fails_without_mutation() {
	local target="$1"
	local scenario="$2"
	local test_prefix="$3"
	: >"$GH_CALLS"
	if [[ "$target" == "issue" ]]; then
		if run_issue_job "$scenario" >/dev/null 2>&1; then
			print_result "$test_prefix fails the job" 1 "expected non-zero exit"
		else
			print_result "$test_prefix fails the job" 0
		fi
	else
		if run_pr_job "$scenario" >/dev/null 2>&1; then
			print_result "$test_prefix fails the job" 1 "expected non-zero exit"
		else
			print_result "$test_prefix fails the job" 0
		fi
	fi
	assert_no_mutation "$test_prefix leaves labels unchanged"
	return 0
}

test_issue_approval_paths() {
	assert_job_fails_without_mutation issue issue-api-failure "issue approval API failure"
	assert_job_fails_without_mutation issue issue-invalid "invalid issue approval response"
	: >"$GH_CALLS"
	if run_issue_job issue-signed >/dev/null 2>&1; then
		print_result "signed issue approval is accepted" 0
	else
		print_result "signed issue approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "signed issue approval does not restore NMR"
	: >"$GH_CALLS"
	run_issue_job issue-unsigned >/dev/null 2>&1 || true
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "confirmed unsigned issue restores NMR" 0
	else
		print_result "confirmed unsigned issue restores NMR" 1 "expected issue edit"
	fi
	return 0
}

test_pr_approval_paths() {
	assert_job_fails_without_mutation pr pr-label-failure "PR label API failure"
	assert_job_fails_without_mutation pr pr-approval-failure "PR approval API failure"
	assert_job_fails_without_mutation pr pr-invalid "invalid PR approval response"
	: >"$GH_CALLS"
	if run_pr_job pr-signed >/dev/null 2>&1; then
		print_result "signed PR approval is accepted" 0
	else
		print_result "signed PR approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "signed PR approval does not restore NMR"
	: >"$GH_CALLS"
	run_pr_job pr-unsigned >/dev/null 2>&1 || true
	if grep -q '^pr edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "confirmed unsigned external PR restores NMR" 0
	else
		print_result "confirmed unsigned external PR restores NMR" 1 "expected PR edit"
	fi
	return 0
}

has_combined_slurp_and_jq() {
	local workflow_file="$1"
	if sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' "$workflow_file" |
		grep 'gh[[:space:]][[:space:]]*api' |
		grep -F -- '--slurp' |
		grep -Fq -- '--jq'; then
		return 0
	fi
	return 1
}

test_slurp_and_jq_are_separate() {
	local combined_fixture="${TEST_ROOT}/combined-flags.sh"
	cat >"$combined_fixture" <<'EOF'
gh api --jq '.[]' \
  --paginate \
  --slurp repos/example/project/issues/1/comments
EOF
	if has_combined_slurp_and_jq "$combined_fixture"; then
		print_result "slurp/jq detector handles reordered multiline flags" 0
	else
		print_result "slurp/jq detector handles reordered multiline flags" 1 "forbidden fixture was not detected"
	fi

	if has_combined_slurp_and_jq "$WORKFLOW_FILE"; then
		print_result "maintainer gate separates gh --slurp from jq" 1 "unsupported gh flag combination remains"
	else
		print_result "maintainer gate separates gh --slurp from jq" 0
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_issue_approval_paths
	test_pr_approval_paths
	test_slurp_and_jq_are_separate
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
