#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22856: keep full-loop worker guidance aligned with the
# project's US English wording used by the headless runtime contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
FULL_LOOP_DOC="${REPO_ROOT}/.agents/workflows/full-loop.md"

main() {
	if grep -n 'behaviour' "$FULL_LOOP_DOC"; then
		printf 'FAIL: full-loop workflow should use US English "behavior" spelling\n' >&2
		return 1
	fi

	if ! grep -n 'expected behavior' "$FULL_LOOP_DOC" >/dev/null; then
		printf 'FAIL: expected implementation-context guidance was not found\n' >&2
		return 1
	fi

	printf 'PASS: full-loop workflow uses consistent behavior spelling\n'
	return 0
}

main "$@"
