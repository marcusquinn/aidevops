#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#23760: planning-commit-helper next-id must preserve
# multi-word values when parsing --title, --labels, and --description.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
PLANNING_HELPER="${REPO_ROOT}/.agents/scripts/planning-commit-helper.sh"

if [[ ! -x "$PLANNING_HELPER" ]]; then
	printf 'planning-commit-helper.sh not executable: %s\n' "$PLANNING_HELPER" >&2
	exit 1
fi

output=$("$PLANNING_HELPER" next-id \
	--title "Run Phase 3 kickoff adjustment for post-t394 roadmap" \
	--labels "bug,auto-dispatch" \
	--description "Multi word description value" \
	--dry-run 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	printf 'FAIL: expected next-id dry-run to succeed, rc=%s\n%s\n' "$rc" "$output" >&2
	exit 1
fi

if [[ "$output" == *"command not found"* ]]; then
	printf 'FAIL: parser attempted to execute part of a multi-word value\n%s\n' "$output" >&2
	exit 1
fi

if [[ "$output" != *"TASK_ID=tDRY_RUN"* ]] || [[ "$output" != *"TASK_REF=DRY_RUN"* ]]; then
	printf 'FAIL: expected dry-run task fields in output\n%s\n' "$output" >&2
	exit 1
fi

printf 'PASS: planning-commit-helper next-id preserves multi-word arguments\n'
exit 0
