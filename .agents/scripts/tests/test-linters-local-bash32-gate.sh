#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#22789 regression guard: the local Bash 3.2 gate should use the same
# regression helper as CI on feature branches, and timeout as a warning instead
# of exhausting the outer linters-local.sh command.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
TEST_ROOT=""

fail() {
	local message="$1"
	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$message"
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

make_feature_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir" || return 1
	git -C "$repo_dir" init -q -b main || return 1
	printf '#!/usr/bin/env bash\nprintf '\''base\\n'\''\n' >"${repo_dir}/example.sh"
	git -C "$repo_dir" add example.sh || return 1
	git -C "$repo_dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init || return 1
	git -C "$repo_dir" update-ref refs/remotes/origin/main main || return 1
	git -C "$repo_dir" checkout -q -b feature/gh22789 || return 1
	printf '#!/usr/bin/env bash\nprintf '\''head\\n'\''\n' >"${repo_dir}/example.sh"
	git -C "$repo_dir" add example.sh || return 1
	git -C "$repo_dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m change || return 1
	return 0
}

load_gate() {
	SCRIPT_DIR="$TEST_SCRIPTS_DIR"
	# shellcheck source=../shared-constants.sh
	source "${TEST_SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=../linters-local-analysis.sh
	source "${TEST_SCRIPTS_DIR}/linters-local-analysis.sh"
	return 0
}

test_feature_branch_uses_regression_helper() {
	setup
	local repo_dir="${TEST_ROOT}/repo"
	make_feature_repo "$repo_dir" || fail "create feature repo"
	load_gate || fail "load bash32 gate"

	local output rc=0
	cd "$repo_dir" || fail "enter feature repo"
	output=$(LINTERS_LOCAL_BASH32_TIMEOUT=30 check_bash32_compat 2>&1) || rc=$?
	[[ "$rc" -eq 0 ]] || fail "expected clean regression gate, got exit $rc: $output"
	[[ "$output" == *"no new Bash 3.2 regressions"* ]] || fail "expected regression success output: $output"
	[[ "$output" == *"no new violations"* || "$output" == *"No new violations"* ]] || fail "expected helper regression output: $output"
	teardown
	return 0
}

test_timeout_is_warning_only() {
	setup
	local repo_dir="${TEST_ROOT}/repo"
	local stub_dir="${TEST_ROOT}/scripts"
	make_feature_repo "$repo_dir" || fail "create feature repo"
	mkdir -p "$stub_dir" || fail "create stub script dir"
	cat >"${stub_dir}/complexity-regression-helper.sh" <<'STUB'
#!/usr/bin/env bash
sleep 5
exit 0
STUB
	chmod +x "${stub_dir}/complexity-regression-helper.sh" || fail "chmod stub helper"
	load_gate || fail "load bash32 gate"
	SCRIPT_DIR="$stub_dir"

	local output rc=0
	cd "$repo_dir" || fail "enter feature repo"
	output=$(LINTERS_LOCAL_BASH32_TIMEOUT=1 check_bash32_compat 2>&1) || rc=$?
	[[ "$rc" -eq 0 ]] || fail "expected timeout warning to be non-blocking, got exit $rc: $output"
	[[ "$output" == *"regression scan timed out"* ]] || fail "expected timeout warning output: $output"
	teardown
	return 0
}

test_feature_branch_uses_regression_helper
test_timeout_is_warning_only
pass "linters-local bash32 gate uses CI parity and bounded timeout fallback"
exit 0
