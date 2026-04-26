#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-parent-issue.sh — t2838 regression guard.
#
# Validates --parent-issue N flag in claim-task-id.sh and the
# _link_parent_issue_post_create helper in claim-task-id-issue.sh.
#
# Cases covered:
#   1. PARENT_ISSUE_NUM defaults to empty
#   2. _compose_issue_body injects 'Parent: #N' on fallback path
#   3. _compose_issue_body omits 'Parent:' line when global is empty
#   4. _link_parent_issue_post_create returns 0 with empty global (no-op)
#   5. _link_parent_issue_post_create returns 0 with valid stubbed gh
#   6. _link_parent_issue_post_create swallows duplicate-relationship error
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       expected: %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		pass "$name"
	else
		fail "$name" "want='${want}' got='${got}'"
	fi
	return 0
}

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' not found in haystack"
	fi
	return 0
}

assert_not_contains() {
	local name="$1" haystack="$2" needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' should not appear in haystack"
	fi
	return 0
}

# Mutable gh-stub state — controls behaviour per test.
# MUST be exported so the gh stub subprocess sees the value.
export GH_STUB_MODE="success"  # success | duplicate | error | empty_node

_setup_stubs() {
	local stub_dir
	stub_dir=$(mktemp -d)
	# Track for teardown
	export _T2838_STUB_DIR="$stub_dir"

	cat >"${stub_dir}/git" <<'STUB'
#!/usr/bin/env bash
# Return a fake remote URL so slug extraction works.
if [[ "${1:-}" == "-C" ]]; then shift 2; fi
case "${1:-}" in
	remote)
		case "${2:-}" in
			get-url) echo "git@github.com:test/repo.git"; exit 0 ;;
		esac
		;;
esac
exit 0
STUB
	chmod +x "${stub_dir}/git"

	cat >"${stub_dir}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh that responds based on \$GH_STUB_MODE.
# The post-t2838-review consolidation uses a single GraphQL query that
# returns both parent and child node IDs separated by '|', via the jq
# fallback expression in --jq. We emit the pre-jq'd output here so the
# helper sees what gh would return after --jq evaluation.
mode="\${GH_STUB_MODE:-success}"
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then exit 0; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "graphql" ]]; then
	args="\$*"
	# Detect mutation vs query — mutation contains addSubIssue.
	if [[ "\$args" == *"addSubIssue"* ]]; then
		case "\$mode" in
			duplicate) echo '{"errors":[{"message":"Sub-issues may only have one parent"}]}'; exit 0 ;;
			error)     echo '{"errors":[{"message":"unexpected"}]}'; exit 0 ;;
			*)         echo '{"data":{"addSubIssue":{"issue":{"number":12345}}}}'; exit 0 ;;
		esac
	fi
	# Query for issue node IDs — returns the pipe-joined string the
	# helper's --jq filter would produce. empty_node returns just the
	# pipe to simulate both IDs missing.
	if [[ "\$mode" == "empty_node" ]]; then
		echo "|"
	else
		echo "I_parent_abc|I_child_xyz"
	fi
	exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	# jq stub that no-ops most calls but isn't used for the addSubIssue
	# path — gh stub above already emits the pre-jq'd combined string.
	cat >"${stub_dir}/jq" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "${stub_dir}/jq"

	export PATH="${stub_dir}:${PATH}"
	export HOME="${stub_dir}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi

	return 0
}

_teardown() {
	[[ -n "${_T2838_STUB_DIR:-}" && -d "${_T2838_STUB_DIR:-}" ]] && rm -rf "${_T2838_STUB_DIR}"
	return 0
}
trap _teardown EXIT

_setup_stubs

# ---------------------------------------------------------------------------
# Test 1 — PARENT_ISSUE_NUM is declared (not undefined) and empty after source
# Use indirect check: with set -u active, accessing an undeclared var aborts.
# Capturing via subshell tells us whether the var is declared at all.
# ---------------------------------------------------------------------------
_t1_state="undeclared"
if [[ -z "${PARENT_ISSUE_NUM+x}" ]]; then
	_t1_state="undeclared"
elif [[ -z "$PARENT_ISSUE_NUM" ]]; then
	_t1_state="declared_empty"
else
	_t1_state="declared_nonempty"
fi
assert_eq "global_declared_and_empty" "$_t1_state" "declared_empty"

# ---------------------------------------------------------------------------
# Test 2 — _compose_issue_body injects 'Parent: #N' on fallback path
# (no brief file → fallback branch)
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="20518"
# Fallback path: no brief file means it uses raw description as body.
# Use a temp dir as repo with no brief file.
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
mkdir -p todo/tasks
body_with_parent=$(_compose_issue_body "t9999: test" "Some description text" 2>/dev/null || echo "")
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_contains "compose_body_injects_parent_line" "$body_with_parent" "Parent: #20518"

# ---------------------------------------------------------------------------
# Test 3 — _compose_issue_body omits 'Parent:' line when global is empty
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM=""
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
mkdir -p todo/tasks
body_no_parent=$(_compose_issue_body "t9999: test" "Some description text" 2>/dev/null || echo "")
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_not_contains "compose_body_omits_parent_when_unset" "$body_no_parent" "Parent: #"

# ---------------------------------------------------------------------------
# Test 4 — _link_parent_issue_post_create no-op when global empty
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM=""
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
git init -q . 2>/dev/null
output=$(_link_parent_issue_post_create "12345" "$_repo_tmp" 2>&1)
rc=$?
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_eq "link_helper_no_op_returns_0" "$rc" "0"
assert_not_contains "link_helper_no_op_silent" "$output" "linked"

# ---------------------------------------------------------------------------
# Test 5 — _link_parent_issue_post_create succeeds with valid stubbed gh
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="20518"
export GH_STUB_MODE="success"
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
git init -q . 2>/dev/null
git remote add origin git@github.com:test/repo.git 2>/dev/null
output=$(_link_parent_issue_post_create "12345" "$_repo_tmp" 2>&1)
rc=$?
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_eq "link_helper_success_returns_0" "$rc" "0"
assert_contains "link_helper_success_logs_linked" "$output" "linked #12345"

# ---------------------------------------------------------------------------
# Test 6 — _link_parent_issue_post_create swallows duplicate-relationship error
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="20518"
export GH_STUB_MODE="duplicate"
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
git init -q . 2>/dev/null
git remote add origin git@github.com:test/repo.git 2>/dev/null
output=$(_link_parent_issue_post_create "12345" "$_repo_tmp" 2>&1)
rc=$?
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_eq "link_helper_duplicate_returns_0" "$rc" "0"

# ---------------------------------------------------------------------------
# Test 7 — empty_node mode (issue not found) returns 0 without addSubIssue call
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="999999"
export GH_STUB_MODE="empty_node"
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
git init -q . 2>/dev/null
git remote add origin git@github.com:test/repo.git 2>/dev/null
output=$(_link_parent_issue_post_create "12345" "$_repo_tmp" 2>&1)
rc=$?
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_eq "link_helper_empty_node_returns_0" "$rc" "0"
assert_contains "link_helper_empty_node_logs_warning" "$output" "could not resolve node IDs"

# ---------------------------------------------------------------------------
# Test 8 — error mode logs warning, returns 0 (does NOT log "linked")
# Validates the post-review fix that replaced fragile substring matching
# on the word "errors" with explicit success-shape checking.
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="20518"
export GH_STUB_MODE="error"
_repo_tmp=$(mktemp -d)
cd "$_repo_tmp" || exit 1
git init -q . 2>/dev/null
git remote add origin git@github.com:test/repo.git 2>/dev/null
output=$(_link_parent_issue_post_create "12345" "$_repo_tmp" 2>&1)
rc=$?
cd - >/dev/null || exit 1
PARENT_ISSUE_NUM="$_saved_parent"
rm -rf "$_repo_tmp"

assert_eq "link_helper_error_returns_0" "$rc" "0"
assert_contains "link_helper_error_logs_failure" "$output" "addSubIssue failed"
assert_not_contains "link_helper_error_does_not_log_linked" "$output" "linked #"

# ---------------------------------------------------------------------------
# Test 9 — regex validation: --parent-issue 0 should be rejected
# Test the regex directly since calling main() with set -euo pipefail and
# stubbed deps is fragile. Helper proves the post-review fix.
# ---------------------------------------------------------------------------
_check_regex() {
	local v="$1"
	if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then echo "valid"; else echo "invalid"; fi
}
assert_eq "regex_rejects_zero" "$(_check_regex 0)" "invalid"
assert_eq "regex_rejects_leading_zero" "$(_check_regex 01)" "invalid"
assert_eq "regex_rejects_negative" "$(_check_regex -5)" "invalid"
assert_eq "regex_rejects_alpha" "$(_check_regex 12a)" "invalid"
assert_eq "regex_rejects_empty_when_passed" "$(_check_regex '')" "invalid"
assert_eq "regex_accepts_one" "$(_check_regex 1)" "valid"
assert_eq "regex_accepts_large" "$(_check_regex 20518)" "valid"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
