#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify bounded ShellCheck batching and timeout fallback behaviour.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=../linters-local-validators.sh
source "${SCRIPT_DIR}/linters-local-validators.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DIR=""

cleanup() {
	[[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]] || return 0
	rm -rf "$TEST_TMP_DIR"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (expected %s, got %s)\n' "$description" "$expected" "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

make_fake_shellcheck() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/shellcheck" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"$FAKE_SHELLCHECK_LOG"
if [[ "${FAKE_TIMEOUT_BATCH:-0}" == "1" && "$#" -gt 3 ]]; then
	exit 124
fi
if [[ "${FAKE_TIMEOUT_ALL:-0}" == "1" ]]; then
	exit 124
fi
if [[ "${FAKE_SILENT_FAILURE:-0}" == "1" ]]; then
	exit 2
fi
if [[ "${FAKE_SILENT_LINT_FAILURE:-0}" == "1" ]]; then
	exit 1
fi
exit 0
FAKE
	chmod +x "${bin_dir}/shellcheck"
	return 0
}

create_fixture_files() {
	local fixture_dir="$1"
	local count="$2"
	local index=0
	ALL_SH_FILES=()
	while [[ "$index" -lt "$count" ]]; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"${fixture_dir}/fixture-${index}.sh"
		ALL_SH_FILES+=("${fixture_dir}/fixture-${index}.sh")
		index=$((index + 1))
	done
	return 0
}

main() {
	local tmp_dir invocation_count output
	tmp_dir=$(mktemp -d)
	TEST_TMP_DIR="$tmp_dir"
	trap cleanup EXIT
	make_fake_shellcheck "${tmp_dir}/bin"
	export PATH="${tmp_dir}/bin:${PATH}"
	export FAKE_SHELLCHECK_LOG="${tmp_dir}/calls"

	create_fixture_files "$tmp_dir" 5
	export LINTERS_LOCAL_SHELLCHECK_BATCH_SIZE=2
	run_shellcheck >/dev/null
	invocation_count=$(wc -l <"$FAKE_SHELLCHECK_LOG" | tr -d '[:space:]')
	assert_equal 3 "$invocation_count" "ShellCheck processes files in bounded batches"

	: >"$FAKE_SHELLCHECK_LOG"
	create_fixture_files "$tmp_dir" 2
	export FAKE_TIMEOUT_BATCH=1
	output=$(run_shellcheck 2>&1)
	invocation_count=$(wc -l <"$FAKE_SHELLCHECK_LOG" | tr -d '[:space:]')
	assert_equal 3 "$invocation_count" "timed-out batch retries files individually"
	if [[ "$output" == *"retrying 2 file(s) individually"* ]]; then
		assert_equal 1 1 "timeout fallback is reported"
	else
		assert_equal 1 0 "timeout fallback is reported"
	fi

	unset FAKE_TIMEOUT_BATCH
	export FAKE_TIMEOUT_ALL=1
	local failure_status=0
	run_shellcheck >/dev/null 2>&1 || failure_status=$?
	assert_equal 1 "$failure_status" "persistent per-file timeouts fail closed"

	unset FAKE_TIMEOUT_ALL
	export FAKE_SILENT_FAILURE=1
	failure_status=0
	run_shellcheck >/dev/null 2>&1 || failure_status=$?
	assert_equal 1 "$failure_status" "silent ShellCheck infrastructure failures fail closed"

	unset FAKE_SILENT_FAILURE
	export FAKE_SILENT_LINT_FAILURE=1
	failure_status=0
	run_shellcheck >/dev/null 2>&1 || failure_status=$?
	assert_equal 1 "$failure_status" "silent ShellCheck lint failures fail closed"

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
