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
# GH#37922: deterministic quota and timeout stubs; never reads host quotas.
cat >"$TEST_ROOT/bin/quota" <<'EOF'
#!/usr/bin/env bash
[[ -z "${QUOTA_ARGS_LOG:-}" ]] || printf '%s\n' "$*" >"$QUOTA_ARGS_LOG"
printf '%b' "${QUOTA_OUTPUT:-Disk quotas for user test (uid 1000): none\n}"
exit "${QUOTA_RC:-0}"
EOF
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
chmod +x "$TEST_ROOT/bin/quota" "$TEST_ROOT/bin/timeout"
QUOTA_HEADER='Disk quotas for user test (uid 1000):\n     Filesystem  blocks   quota   limit   grace   files   quota   limit   grace\n'

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

# GH#37922: df reports 100 GiB free on 200 GiB; only quota evidence differs.
run_quota_check() {
	local description="$1"
	local quota_output="$2"
	local quota_rc="$3"
	local expected_rc="$4"
	local expected_reason="$5"
	local expected_state="$6"
	local rc=0
	QUOTA_OUTPUT="$quota_output" QUOTA_RC="$quota_rc" DF_TOTAL_KB=209715200 DF_AVAILABLE_KB=104857600 \
		PATH="$TEST_ROOT/bin:$(dirname "$REAL_AWK"):/usr/bin:/bin" \
		aidevops_worktree_capacity_check "$TEST_ROOT/existing" || rc=$?
	if [[ "$rc" -eq "$expected_rc" && "$AIDEVOPS_DISK_CAPACITY_REASON" == "$expected_reason" &&
		"$AIDEVOPS_DISK_QUOTA_STATE" == "$expected_state" ]]; then
		pass "$description"
		return 0
	fi
	fail "$description" "rc=$rc reason=$AIDEVOPS_DISK_CAPACITY_REASON state=$AIDEVOPS_DISK_QUOTA_STATE"
	return 0
}

run_quota_check "no quota limits" "" 0 0 available none
run_quota_check "quota block hard limit reached" \
	"${QUOTA_HEADER}      /dev/test 262144000* 250000000 262144000 1 10 0 0 0\n" 1 1 quota-exhausted exhausted
run_quota_check "quota file hard limit reached" \
	"${QUOTA_HEADER}      /dev/test 1000 0 0 0 500* 0 500 0\n" 1 1 quota-exhausted exhausted
run_quota_check "quota soft grace expired" \
	"${QUOTA_HEADER}      /dev/test 2000* 1000 0 1 10 0 0 0\n" 1 1 quota-exhausted exhausted
run_quota_check "quota headroom below minimum" \
	"${QUOTA_HEADER}      /dev/test 259000000 0 262144000 0 10 0 0 0\n" 0 1 quota-below-minimum-kb limited
run_quota_check "ample quota headroom" \
	"${QUOTA_HEADER}      /dev/test 1000 0 62914560 0 10 0 0 0\n" 0 0 available limited
if [[ "$AIDEVOPS_DISK_CAPACITY_SOURCE" == quota && "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -eq 62913560 ]]; then
	pass "effective capacity uses quota headroom"
else
	fail "effective capacity uses quota headroom" "source=$AIDEVOPS_DISK_CAPACITY_SOURCE available=$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB"
fi
run_quota_check "quota report without rows is unavailable" \
	"quota: Mountpoint (or device) /test not found or has no quota enabled.\n" 1 0 available unavailable
run_quota_check "unparseable quota row is unavailable" \
	"${QUOTA_HEADER}      /dev/test lots 0 limit 0 10 0 0 0\n" 1 0 available unavailable

quota_rc=0
AIDEVOPS_DISK_QUOTA_COMMAND=aidevops-missing-quota DF_TOTAL_KB=209715200 DF_AVAILABLE_KB=104857600 \
	PATH="$TEST_ROOT/bin:$(dirname "$REAL_AWK"):/usr/bin:/bin" \
	aidevops_worktree_capacity_check "$TEST_ROOT/existing" || quota_rc=$?
if [[ "$quota_rc" -eq 0 && "$AIDEVOPS_DISK_QUOTA_STATE" == unsupported ]]; then
	pass "missing quota tool is unsupported"
else
	fail "missing quota tool is unsupported" "rc=$quota_rc state=$AIDEVOPS_DISK_QUOTA_STATE"
fi

QUOTA_ARGS_LOG="$TEST_ROOT/quota-args" DF_TOTAL_KB=209715200 DF_AVAILABLE_KB=104857600 \
	PATH="$TEST_ROOT/bin:$(dirname "$REAL_AWK"):/usr/bin:/bin" \
	aidevops_worktree_capacity_check "$TEST_ROOT/existing" || true
if [[ "$(cat "$TEST_ROOT/quota-args" 2>/dev/null)" == "-w -p -u -g -f /test" ]]; then
	pass "quota probe targets the df mount point"
else
	fail "quota probe targets the df mount point" "args=$(cat "$TEST_ROOT/quota-args" 2>/dev/null)"
fi

printf 'Results: %s passed, %s failed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
