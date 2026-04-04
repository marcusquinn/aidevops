#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/.agents/scripts/deploy-agents-on-merge.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$name"
	if [[ -n "$detail" ]]; then
		printf "     %s\n" "$detail"
	fi
	return 0
}

assert_eq() {
	local actual="$1"
	local expected="$2"
	local name="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "Expected '$expected', got '$actual'"
	fi
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local name="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "Missing substring: $needle"
	fi
	return 0
}

create_base_repo() {
	local dir="$1"
	git init "$dir" >/dev/null 2>&1
	git -C "$dir" checkout -b main >/dev/null 2>&1 || true
	mkdir -p "$dir/.agents/scripts"
	echo "echo ok" >"$dir/.agents/scripts/example.sh"
	echo "2.0.0" >"$dir/VERSION"
	git -C "$dir" add . >/dev/null 2>&1
	git -C "$dir" commit -m "initial" >/dev/null 2>&1
	return 0
}

run_script() {
	local repo="$1"
	shift
	bash "$SCRIPT_PATH" --repo "$repo" "$@" 2>&1
	return $?
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Test 1: Invalid commit should fail fast (exit 1)
TEST_REPO_INVALID="$TMP_DIR/repo-invalid"
create_base_repo "$TEST_REPO_INVALID"

set +e
invalid_output="$(run_script "$TEST_REPO_INVALID" --diff "--bad-ref" --quiet)"
invalid_status=$?
set -e

assert_eq "$invalid_status" "1" "Invalid --diff commit exits with status 1"
assert_contains "$invalid_output" "Invalid commit reference" "Invalid --diff commit logs validation error"

# Test 2: git diff failure should return 1 (not 2/no-op)
TEST_REPO_DIFF_FAIL="$TMP_DIR/repo-diff-fail"
create_base_repo "$TEST_REPO_DIFF_FAIL"

FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-C" ]]; then
	repo_path="$2"
	shift 2
else
	repo_path=""
fi

if [[ "$1" == "diff" && "$2" == "--name-only" ]]; then
	printf 'simulated git diff failure\n' >&2
	exit 128
fi

if [[ -n "$repo_path" ]]; then
	exec /usr/bin/git -C "$repo_path" "$@"
fi

exec /usr/bin/git "$@"
EOF
chmod +x "$FAKE_BIN/git"

set +e
diff_fail_output="$(PATH="$FAKE_BIN:/usr/bin:/bin" run_script "$TEST_REPO_DIFF_FAIL" --diff HEAD --quiet)"
diff_fail_status=$?
set -e

assert_eq "$diff_fail_status" "1" "git diff failure exits with status 1"
assert_contains "$diff_fail_output" "Failed to detect changed agent files: simulated git diff failure" "git diff failure logs actionable error"

# Test 3: Real changed agent files should deploy successfully
TEST_REPO_CHANGED="$TMP_DIR/repo-changed"
create_base_repo "$TEST_REPO_CHANGED"

echo "echo updated" >"$TEST_REPO_CHANGED/.agents/scripts/example.sh"
git -C "$TEST_REPO_CHANGED" add .agents/scripts/example.sh >/dev/null 2>&1
git -C "$TEST_REPO_CHANGED" commit -m "update script" >/dev/null 2>&1

set +e
changed_output="$(run_script "$TEST_REPO_CHANGED" --diff HEAD~1)"
changed_status=$?
set -e

assert_eq "$changed_status" "0" "Changed script deploy exits with status 0"
assert_contains "$changed_output" "using fast scripts-only deploy" "Changed script deploy selects scripts-only path"

printf "\nRan %d tests, %d failed.\n" "$TOTAL_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi

exit 0
