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

repo_allows_pulse_write_actions() { return 0; }
_merge_ready_prs_for_repo() { return 0; }
_pmp_now_epoch() { printf '0\n'; return 0; }
_pmp_add_elapsed_seconds() { return 0; }
_pmp_log_repo_timing_summary() { return 0; }

total_merged=0
total_closed=0
total_failed=0
total_eligible=0
completed_all=1
process_checkpoint="${tmp_dir}/process-checkpoint"
_pmp_process_merge_repo_for_pass "owner/repo" "$process_checkpoint" "${tmp_dir}/process.log" \
	"${tmp_dir}/stop" total_merged total_closed total_failed total_eligible completed_all
[[ -f "$process_checkpoint" ]]
process_checkpoint_repo=$(<"$process_checkpoint")
[[ "$process_checkpoint_repo" == "owner/repo" ]]

printf 'pulse merge-pass strict-mode regression checks passed\n'
