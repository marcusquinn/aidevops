#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SCHEDULERS_LINUX="${REPO_ROOT}/.agents/scripts/setup/modules/schedulers-linux.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_fixture() {
	TEST_ROOT="$(mktemp -d)"
	export HOME="${TEST_ROOT}/home"
	export CRON_FILE="${TEST_ROOT}/crontab"
	export SYSTEMD_ENABLED_FILE="${TEST_ROOT}/systemd-enabled"
	local fake_bin="${TEST_ROOT}/bin"
	mkdir -p "$HOME/.config/systemd/user" "$fake_bin"
	: >"$CRON_FILE"
	: >"$SYSTEMD_ENABLED_FILE"

	cat >"${fake_bin}/crontab" <<'CRONTAB_FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
-l)
	[[ -f "$CRON_FILE" ]] && cat "$CRON_FILE"
	exit 0
	;;
-r)
	: >"$CRON_FILE"
	exit 0
	;;
-)
	cat >"$CRON_FILE"
	exit 0
	;;
*)
	cp "$1" "$CRON_FILE"
	exit 0
	;;
esac
CRONTAB_FAKE
	chmod +x "${fake_bin}/crontab"

	cat >"${fake_bin}/systemctl" <<'SYSTEMCTL_FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--user" && ( "${2:-}" == "is-enabled" || "${2:-}" == "is-active" ) ]]; then
	grep -qxF "${3:-}" "$SYSTEMD_ENABLED_FILE"
	exit $?
fi
if [[ "${1:-}" == "--user" && "${2:-}" == "status" ]]; then
	exit 0
fi
exit 0
SYSTEMCTL_FAKE
	chmod +x "${fake_bin}/systemctl"
	export PATH="${fake_bin}:$PATH"
	return 0
}

cleanup_fixture() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

load_scheduler_functions() {
	print_info() {
		printf '%s\n' "$*"
		return 0
	}
	print_warning() {
		printf '%s\n' "$*" >&2
		return 0
	}
	# shellcheck source=../setup/modules/schedulers-linux.sh
	source "$SCHEDULERS_LINUX"
	return 0
}

test_duplicate_auto_update_cron_removed() {
	setup_fixture
	printf '%s\n' \
		'*/10 * * * * /home/example/.aidevops/agents/scripts/auto-update-helper.sh check # aidevops-auto-update' \
		'15 * * * * /usr/bin/true # keep-me' >"$CRON_FILE"
	printf '%s\n' 'aidevops-auto-update.timer' >"$SYSTEMD_ENABLED_FILE"
	load_scheduler_functions

	local output=""
	output="$(_reconcile_linux_scheduler_duplicates)"
	local after_first=""
	after_first="$(cat "$CRON_FILE")"
	_reconcile_linux_scheduler_duplicates >/dev/null
	local after_second=""
	after_second="$(cat "$CRON_FILE")"

	if [[ "$after_first" != *'aidevops-auto-update'* && "$after_first" == *'keep-me'* && "$after_first" == "$after_second" && "$output" == *'Removed duplicate cron entry for auto-update'* ]]; then
		print_result "duplicate auto-update cron is removed and reconciliation is idempotent" 0
		cleanup_fixture
		return 0
	fi

	print_result "duplicate auto-update cron is removed and reconciliation is idempotent" 1 "output=${output} cron=${after_first} second=${after_second}"
	cleanup_fixture
	return 0
}

test_duplicate_pulse_merge_cron_removed() {
	setup_fixture
	printf '%s\n' \
		'* * * * * /home/example/.aidevops/agents/scripts/pulse-merge-routine.sh run # aidevops: pulse-merge-routine' \
		'0 6 * * * /usr/bin/true # legitimate-cron-only' >"$CRON_FILE"
	printf '%s\n' 'aidevops-pulse-merge.timer' >"$SYSTEMD_ENABLED_FILE"
	load_scheduler_functions

	local output=""
	output="$(_reconcile_linux_scheduler_duplicates)"
	local cron_after=""
	cron_after="$(cat "$CRON_FILE")"

	if [[ "$cron_after" != *'pulse-merge-routine'* && "$cron_after" == *'legitimate-cron-only'* && "$output" == *'Removed duplicate cron entry for pulse merge'* ]]; then
		print_result "duplicate pulse merge cron is removed while preserving unrelated cron" 0
		cleanup_fixture
		return 0
	fi

	print_result "duplicate pulse merge cron is removed while preserving unrelated cron" 1 "output=${output} cron=${cron_after}"
	cleanup_fixture
	return 0
}

test_systemd_only_stats_wrapper_preserved() {
	setup_fixture
	printf '%s\n' '30 2 * * * /usr/bin/true # keep-cron-only' >"$CRON_FILE"
	printf '%s\n' 'aidevops-stats-wrapper.timer' >"$SYSTEMD_ENABLED_FILE"
	load_scheduler_functions

	local output=""
	output="$(_reconcile_linux_scheduler_duplicates)"
	local cron_after=""
	cron_after="$(cat "$CRON_FILE")"

	if [[ "$cron_after" == *'keep-cron-only'* && "$output" == *'Kept stats wrapper systemd user timer; no duplicate cron entry found'* ]]; then
		print_result "systemd-only stats wrapper is preserved and logged" 0
		cleanup_fixture
		return 0
	fi

	print_result "systemd-only stats wrapper is preserved and logged" 1 "output=${output} cron=${cron_after}"
	cleanup_fixture
	return 0
}

test_cron_only_scheduler_preserved() {
	setup_fixture
	printf '%s\n' '* * * * * /home/example/pulse-wrapper.sh # aidevops: supervisor-pulse' >"$CRON_FILE"
	load_scheduler_functions

	local output=""
	output="$(_reconcile_linux_scheduler_duplicates)"
	local cron_after=""
	cron_after="$(cat "$CRON_FILE")"

	if [[ "$cron_after" == *'aidevops: supervisor-pulse'* && "$output" == *'Kept supervisor pulse cron entry; no systemd user timer found'* ]]; then
		print_result "cron-only scheduler is preserved" 0
		cleanup_fixture
		return 0
	fi

	print_result "cron-only scheduler is preserved" 1 "output=${output} cron=${cron_after}"
	cleanup_fixture
	return 0
}

main() {
	test_duplicate_auto_update_cron_removed
	test_duplicate_pulse_merge_cron_removed
	test_systemd_only_stats_wrapper_preserved
	test_cron_only_scheduler_preserved

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
