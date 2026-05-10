#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-auto-sig-body-file.sh — regression guard for GH#23304.
#
# Verifies that wrapper-created PRs/comments using --body-file receive the same
# aidevops signature footer as --body without mutating the caller-owned file and
# without duplicating an existing signature marker.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

export AIDEVOPS_SIG_CLI="OpenCode"
export AIDEVOPS_SIG_CLI_VERSION="test"
export AIDEVOPS_SIG_MODEL="openai/gpt-5.5"
export AIDEVOPS_SIG_TOKENS="1"

export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv.log"
export GH_BODY_CAPTURE_FILE="${TEST_ROOT}/gh_body_capture.log"
MOCK_BIN_DIR="${TEST_ROOT}/mockbin"
mkdir -p "$MOCK_BIN_DIR"
cat >"${MOCK_BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
	printf '<%s>\n' "$arg" >>"${GH_ARGV_RECORD_FILE}"
done
while [[ $# -gt 0 ]]; do
	case "$1" in
	--body-file)
		if [[ $# -gt 1 && -r "$2" ]]; then
			cat "$2" >>"${GH_BODY_CAPTURE_FILE}"
			printf '\n--END-BODY--\n' >>"${GH_BODY_CAPTURE_FILE}"
		fi
		shift 2
		;;
	--body-file=*)
		body_file="${1#--body-file=}"
		if [[ -r "$body_file" ]]; then
			cat "$body_file" >>"${GH_BODY_CAPTURE_FILE}"
			printf '\n--END-BODY--\n' >>"${GH_BODY_CAPTURE_FILE}"
		fi
		shift
		;;
	*)
		shift
		;;
	esac
done
case "${1:-} ${2:-}" in
"pr create") printf '%s\n' "https://example.invalid/test/repo/pull/1" ;;
esac
exit 0
MOCK
chmod +x "${MOCK_BIN_DIR}/gh"
export PATH="${MOCK_BIN_DIR}:${PATH}"

SHARED_GH="${TEST_SCRIPTS_DIR}/shared-gh-wrappers.sh"
if [[ ! -f "$SHARED_GH" ]]; then
	printf 'FAIL setup: %s not found\n' "$SHARED_GH" >&2
	exit 1
fi
# shellcheck source=/dev/null
source "$SHARED_GH" >/dev/null 2>&1 || true

_ensure_origin_labels_for_args() { return 0; }
_gh_validate_edit_args() { return 0; }
_gh_should_fallback_to_rest() { return 1; }
_rest_should_fallback() { return 1; }
_gh_auto_link_sub_issue() { return 0; }
session_origin_label() { printf '%s' "origin:worker"; return 0; }
detect_session_origin() { printf '%s' "worker"; return 0; }

reset_capture() {
	: >"$GH_ARGV_RECORD_FILE"
	: >"$GH_BODY_CAPTURE_FILE"
	return 0
}

count_captured_signatures() {
	grep -c '<!-- aidevops:sig -->' "$GH_BODY_CAPTURE_FILE" 2>/dev/null || printf '0\n'
	return 0
}

assert_body_file_signed() {
	local name="$1" command_name="$2"
	local body_file="${TEST_ROOT}/${command_name}.md"
	printf '## Summary\n\nBody\n' >"$body_file"
	reset_capture
	if [[ "$command_name" == "pr-create" ]]; then
		gh_create_pr --repo o/r --title "Fix body-file signing" --body-file "$body_file" >/dev/null 2>&1
	else
		gh_pr_comment 1 --repo o/r --body-file "$body_file" >/dev/null 2>&1
	fi
	if [[ "$(count_captured_signatures)" == "1" ]] && ! grep -q '<!-- aidevops:sig -->' "$body_file"; then
		print_result "$name" 0
	else
		print_result "$name" 1 "captured signatures=$(count_captured_signatures), original_mutated=$(grep -c '<!-- aidevops:sig -->' "$body_file" 2>/dev/null || printf '0')"
	fi
	return 0
}

assert_existing_signature_not_duplicated() {
	local body_file="${TEST_ROOT}/already-signed.md"
	printf '## Summary\n\nBody\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) existing\n' >"$body_file"
	reset_capture
	gh_pr_comment 1 --repo o/r --body-file="$body_file" >/dev/null 2>&1
	if [[ "$(count_captured_signatures)" == "1" ]]; then
		print_result "body-file existing signature is not duplicated" 0
	else
		print_result "body-file existing signature is not duplicated" 1 "captured signatures=$(count_captured_signatures)"
	fi
	return 0
}

assert_body_file_signed "gh_create_pr --body-file signs temp body" "pr-create"
assert_body_file_signed "gh_pr_comment --body-file signs temp body" "pr-comment"
assert_existing_signature_not_duplicated

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
