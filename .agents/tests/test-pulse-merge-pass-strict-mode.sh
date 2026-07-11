#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression checks for pulse merge-pass helpers under strict shell mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../scripts/pulse-merge-pass.sh
source "${SCRIPT_DIR}/../scripts/pulse-merge-pass.sh"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pmp-strict.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
checkpoint_file="${tmp_dir}/checkpoint"
logfile="${tmp_dir}/resume.log"
: >"$checkpoint_file"

checkpoint_result="sentinel"
resume_pending_result=1
resumed_result=1
_pmp_prepare_merge_checkpoint_resume "owner/repo|/tmp/repo" "$checkpoint_file" "$logfile" \
	checkpoint_result resume_pending_result resumed_result
[[ -z "$checkpoint_result" && "$resume_pending_result" -eq 0 && "$resumed_result" -eq 0 ]]

unset missing_resume missing_counter PULSE_MERGE_PR_CURSOR_FILE LOGFILE
if _pmp_checkpoint_resume_skip_repo "owner/repo" "owner/repo" missing_resume; then
	printf 'unset resume flag unexpectedly requested a skip\n' >&2
	exit 1
fi
_pmp_add_counter_var missing_counter 2
# shellcheck disable=SC2154 # Assigned indirectly by _pmp_add_counter_var.
[[ "$missing_counter" -eq 2 ]]

merged=0
closed=0
failed=0
if _pmp_pause_merge_pr_cursor "owner/repo" '[]' 0 budget merged closed failed 0 0 0; then
	printf 'pause helper unexpectedly returned success\n' >&2
	exit 1
else
	status=$?
fi
[[ "$status" -eq 5 ]]

printf 'pulse merge-pass strict-mode regression checks passed\n'
