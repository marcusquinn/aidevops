#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TEST_ROOT="$(mktemp -d -t disk-capacity.XXXXXX)"
REAL_AWK="$(command -v awk)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/existing"
cat >"$TEST_ROOT/bin/df" <<'EOF'
#!/usr/bin/env bash
if [[ "${DF_FAIL:-0}" == "1" ]]; then
	exit 1
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test %s 1 %s 1%% /test\n' "${DF_TOTAL_KB}" "${DF_AVAILABLE_KB}"
exit 0
EOF
chmod +x "$TEST_ROOT/bin/df"

pass() {
	local description="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$description"
	return 0
}

fail() {
	local description="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s%s\n' "$description" "${detail:+ — $detail}"
	return 0
}

# shellcheck source=../disk-capacity-lib.sh
source "$SCRIPT_DIR/../disk-capacity-lib.sh"

run_check() {
	local total_kb="$1"
	local available_kb="$2"
	local expected_rc="$3"
	local expected_reason="$4"
	local rc=0
	DF_TOTAL_KB="$total_kb" DF_AVAILABLE_KB="$available_kb" PATH="$TEST_ROOT/bin:$(dirname "$REAL_AWK"):/usr/bin:/bin" \
		aidevops_worktree_capacity_check "$TEST_ROOT/existing/new/path" || rc=$?
	if [[ "$rc" -eq "$expected_rc" && "$AIDEVOPS_DISK_CAPACITY_REASON" == "$expected_reason" ]]; then
		pass "$expected_reason"
		return 0
	fi
	fail "$expected_reason" "rc=$rc reason=$AIDEVOPS_DISK_CAPACITY_REASON"
	return 0
}

run_check 209715200 20971520 0 available
run_check 209715200 4194304 1 below-minimum-kb
run_check 1048576000 41943040 1 below-minimum-percent
run_check 104857600 5242880 0 available

capacity_rc=0
DF_FAIL=1 PATH="$TEST_ROOT/bin:$(dirname "$REAL_AWK"):/usr/bin:/bin" \
	aidevops_worktree_capacity_check "$TEST_ROOT/existing" || capacity_rc=$?
if [[ "$capacity_rc" -eq 2 && "$AIDEVOPS_DISK_CAPACITY_REASON" == "capacity-unknown" ]]; then
	pass "capacity-unknown"
else
	fail "capacity-unknown" "rc=$capacity_rc reason=$AIDEVOPS_DISK_CAPACITY_REASON"
fi

printf 'Results: %s passed, %s failed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
