#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper-terminal.sh - BLOCKED signals, PR-less terminal
# proof and own-merged terminal reconciliation for the headless runtime.
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
	run_blocked_completion_tests
	finish_test_run || return 1
	return 0
}

main "$@"
