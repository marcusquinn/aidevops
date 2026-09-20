#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#31995: Check 0 may normalize only positively
# identified auto-triage NMR residue for a PR author with maintainer authority.

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
	[[ -z "$detail" ]] || printf ': %s' "$detail"
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t maintainer-gate-nmr-residue.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"

	python3 - "$WORKFLOW_FILE" "${TEST_ROOT}/job.sh" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
steps = workflow["jobs"]["check-pr"]["steps"]
run = next(step["run"] for step in steps if "run" in step)
pathlib.Path(sys.argv[2]).write_text(run)
PY

	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf 'needs-maintainer-review\nexternal-contributor\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "edit" ]]; then
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/collaborators/fixture-author/permission" ]]; then
	if [[ "${GH_SCENARIO:-}" == "untrusted-auto" ]]; then
		printf 'read\n'
	else
		printf 'write\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" && "${3:-}" == *"/events?per_page=100" ]]; then
	if [[ "${GH_SCENARIO:-}" == "trusted-explicit" ]]; then
		printf '%s\n' '[{"event":"labeled","label":{"name":"external-contributor"},"actor":{"login":"github-actions[bot]"},"created_at":"2026-09-01T10:00:00Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-09-02T10:00:00Z"}]'
	else
		printf '%s\n' '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"github-actions[bot]"},"created_at":"2026-09-01T10:00:00Z"},{"event":"labeled","label":{"name":"external-contributor"},"actor":{"login":"github-actions[bot]"},"created_at":"2026-09-01T10:00:00Z"}]'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == *"/statuses/"* ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
}

teardown_test_env() {
	[[ -z "$TEST_ROOT" || ! -d "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
}

run_job() {
	local scenario="$1"
	: >"$GH_CALLS"
	GH_SCENARIO="$scenario" \
		PR_TITLE="fixture" \
		PR_BODY="" \
		PR_NUMBER=42 \
		PR_AUTHOR=fixture-author \
		HEAD_SHA=fixture-head \
		PR_AUTHOR_ASSOCIATION=COLLABORATOR \
		REPO=owner/repo \
		REPO_OWNER=owner \
		GH_TOKEN="[redacted-credential]" \
		GITHUB_OUTPUT="${TEST_ROOT}/github-output" \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/job.sh"
}

assert_removed() {
	local test_name="$1"
	if grep -qF 'pr edit 42 --repo owner/repo --remove-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "expected stale NMR removal"
	fi
}

assert_preserved() {
	local test_name="$1"
	if grep -qF -- '--remove-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "$test_name" 1 "unexpected NMR removal"
	else
		print_result "$test_name" 0
	fi
}

main() {
	setup_test_env
	trap teardown_test_env EXIT

	if run_job trusted-auto >/dev/null 2>&1; then
		assert_removed "trusted author auto-triage residue is normalized"
	else
		print_result "trusted author auto-triage residue is normalized" 1 "job returned non-zero"
	fi

	if run_job trusted-explicit >/dev/null 2>&1; then
		assert_preserved "trusted author explicit NMR hold is preserved"
	else
		print_result "trusted author explicit NMR hold is preserved" 1 "job returned non-zero"
	fi

	if run_job untrusted-auto >/dev/null 2>&1; then
		assert_preserved "untrusted external PR remains blocked"
	else
		print_result "untrusted external PR remains blocked" 1 "job returned non-zero"
	fi

	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
