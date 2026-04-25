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

# Mutable gh-stub state — controls behaviour per test
GH_STUB_MODE="success"  # success | duplicate | error | empty_node

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
# Stub gh that responds based on \$GH_STUB_MODE
mode="\${GH_STUB_MODE:-success}"
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then exit 0; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "graphql" ]]; then
	args="\$*"
	# Detect mutation vs query
	if [[ "\$args" == *"addSubIssue"* ]]; then
		case "\$mode" in
			duplicate) echo '{"errors":[{"message":"Sub-issues may only have one parent"}]}'; exit 0 ;;
			error)     echo '{"errors":[{"message":"unexpected"}]}'; exit 0 ;;
			*)         echo '{"data":{"addSubIssue":{"issue":{"number":1}}}}'; exit 0 ;;
		esac
	fi
	# Query for issue node ID
	if [[ "\$mode" == "empty_node" ]]; then
		echo ""
	else
		echo "I_node_abc123"
	fi
	exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

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
GH_STUB_MODE="success"
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

# ---------------------------------------------------------------------------
# Test 6 — _link_parent_issue_post_create swallows duplicate-relationship error
# ---------------------------------------------------------------------------
_saved_parent="${PARENT_ISSUE_NUM:-}"
PARENT_ISSUE_NUM="20518"
GH_STUB_MODE="duplicate"
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
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
