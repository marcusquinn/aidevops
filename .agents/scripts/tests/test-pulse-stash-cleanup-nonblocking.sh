#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#21997: pulse preflight must not wait for stash cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_LIB="${SCRIPT_DIR}/../pulse-dispatch-preflight-lib.sh"
TEST_DIR=""

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message"
	exit 1
}

main() {
	TEST_DIR=$(mktemp -d)
	trap cleanup EXIT

	local stub_dir="${TEST_DIR}/scripts"
	mkdir -p "$stub_dir" "${TEST_DIR}/.aidevops/logs"

	cat >"${stub_dir}/cleanup-stashes-async-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'started\n' >>"${HOME}/async-marker"
sleep 5
printf 'finished\n' >>"${HOME}/async-marker"
exit 0
STUB
	chmod +x "${stub_dir}/cleanup-stashes-async-helper.sh"

	local start elapsed
	start=$(date +%s)
	(
		export HOME="$TEST_DIR"
		SCRIPT_DIR="$stub_dir"
		LOGFILE="${TEST_DIR}/pulse.log"
		PRE_RUN_STAGE_TIMEOUT=1

		run_stage_with_timeout() {
			local _stage_name="$1"
			local _timeout_secs="$2"
			local fn="$3"
			shift 3
			"$fn" "$@"
			return 0
		}

		cleanup_orphans() { return 0; }
		cleanup_stale_opencode() { return 0; }
		cleanup_stalled_workers() { return 0; }
		cleanup_worktrees() { return 0; }
		cleanup_stashes() { sleep 5; return 0; }
		reap_zombie_workers() { return 0; }

		# shellcheck source=../pulse-dispatch-preflight-lib.sh
		source "$PREFLIGHT_LIB"
		_preflight_cleanup_and_ledger
	)
	elapsed=$(($(date +%s) - start))

	if [[ "$elapsed" -ge 3 ]]; then
		fail "preflight waited ${elapsed}s for stash cleanup; expected async return under 3s"
	fi

	for _ in 1 2 3 4 5; do
		[[ -f "${TEST_DIR}/async-marker" ]] && break
		sleep 0.2
	done

	if [[ ! -f "${TEST_DIR}/async-marker" ]]; then
		fail "async stash cleanup helper was not launched"
	fi

	printf 'PASS: preflight launched stash cleanup asynchronously in %ss\n' "$elapsed"
	return 0
}

main "$@"
