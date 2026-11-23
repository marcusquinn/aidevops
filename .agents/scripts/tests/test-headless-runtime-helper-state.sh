#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper-state.sh - Clean-exit and scoped-delivery
# reconciliation, failure evidence, worker DB persistence and prompt transport
# for the headless runtime.
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
	run_terminal_reconciliation_tests
	run_failure_evidence_tests
	run_worker_db_persistence_tests
	test_opencode_project_table_migration_replay_detected
	test_large_opencode_prompt_uses_file_attachment
	test_public_triage_prompt_forces_file_attachment
	test_public_triage_isolated_data_is_discarded
	test_public_triage_cleanup_failure_is_reported
	test_public_triage_does_not_persist_session_or_failure_output
	test_large_claude_prompt_uses_stdin_file
	test_registered_prompt_temp_cleanup_removes_dir
	test_registered_temp_cleanup_failure_is_reported_and_retained
	test_public_triage_output_temp_starts_cleanup_guardian
	test_launch_helpers_tolerate_unset_state
	finish_test_run || return 1
	return 0
}

main "$@"
