#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression coverage for GH#23916: _run_triage_review_worker must validate
# all mandatory launch/reporting paths before invoking the headless runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/triage-review-worker-contract-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

write_headless_helper() {
	cat >"${TEST_TMP}/headless-runtime-helper.sh" <<'EOS'
#!/usr/bin/env bash
printf 'WORKER_ISSUE_NUMBER=%s WORKER_REPO_SLUG=%s WORKER_WORKTREE_PATH=%s %s\n' \
	"${WORKER_ISSUE_NUMBER:-<unset>}" "${WORKER_REPO_SLUG:-<unset>}" "${WORKER_WORKTREE_PATH:-<unset>}" "$*"
exit 0
EOS
	chmod +x "${TEST_TMP}/headless-runtime-helper.sh" || fail "failed to chmod headless helper"
	return 0
}

write_headless_helper
mkdir -p "${TEST_TMP}/home/.aidevops/logs" "${TEST_TMP}/repo" || fail "failed to create test directories"
HOME="${TEST_TMP}/home"
LOGFILE="${TEST_TMP}/pulse.log"
HEADLESS_RUNTIME_HELPER="${TEST_TMP}/headless-runtime-helper.sh"

# shellcheck source=../pulse-ancillary-dispatch.sh
source "${SCRIPTS_DIR}/pulse-ancillary-dispatch.sh"

prefetch_file="${TEST_TMP}/prefetch.md"
printf '%s\n' 'prefetched issue context' >"$prefetch_file"

missing_output_stderr="${TEST_TMP}/missing-output.stderr"
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "$prefetch_file" "" 2>"$missing_output_stderr" || \
	fail "missing output file path should not fail the caller"
if ! grep -q 'triage worker output file missing' "$missing_output_stderr"; then
	fail "missing output file path did not produce an auditable stderr error"
fi

missing_prefetch_output="${TEST_TMP}/missing-prefetch.out"
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "" "$missing_prefetch_output" || \
	fail "missing prefetch file should not fail the caller"
if ! grep -q 'triage worker env contract missing' "$missing_prefetch_output"; then
	fail "missing prefetch file did not write the env contract failure"
fi
if grep -q 'WORKER_ISSUE_NUMBER' "$missing_prefetch_output"; then
	fail "missing prefetch file launched the headless runtime"
fi

valid_output="${TEST_TMP}/valid.out"
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "$prefetch_file" "$valid_output" || \
	fail "valid worker launch should not fail the caller"
if ! grep -q 'WORKER_ISSUE_NUMBER=42' "$valid_output"; then
	fail "valid worker launch did not invoke the headless runtime"
fi
if ! grep -q -- '--prompt-file' "$valid_output"; then
	fail "valid worker launch did not pass the prompt file flag"
fi

printf '%s\n' 'PASS triage review worker validates mandatory paths'
