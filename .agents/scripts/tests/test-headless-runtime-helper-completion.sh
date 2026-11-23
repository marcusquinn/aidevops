#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper-completion.sh - Worker no-output classification,
# produced-output detection and run finish/orphan recovery for the headless
# runtime.
#
# Split from test-headless-runtime-helper.sh so each root suite finishes under
# the affected-tests per-suite timeout (GH#39968).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./test-headless-runtime-harness.sh
# shellcheck disable=SC1091  # test module resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-headless-runtime-harness.sh"

main() {
	setup_test_env
	run_worker_no_output_classification_tests
	test_worker_produced_output_with_commits_returns_pr_exists_failopen
	test_worker_produced_output_non_worker_session_returns_pr_exists
	test_worker_produced_output_invalid_workdir_returns_pr_exists
	test_worker_produced_output_zero_diff_pushed_branch_returns_noop
	test_worker_produced_output_branch_no_pr_returns_branch_orphan
	test_worker_produced_output_local_branch_no_remote_returns_local_branch_unpushed
	test_worker_produced_output_branch_with_pr_returns_pr_exists
	run_worker_finish_tests
	finish_test_run || return 1
	return 0
}

main "$@"
