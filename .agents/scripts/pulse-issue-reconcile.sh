#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-issue-reconcile.sh — Issue state reconciliation — assignment normalization, close-on-merged-PR, stale status:done recovery.
#
# Extracted from pulse-wrapper.sh in Phase 5 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   - normalize_active_issue_assignments
#   - close_issues_with_merged_prs
#   - reconcile_stale_done_issues
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_LOADED=1

#######################################
# Ensure active issues have an assignee
#
# Prevent overlap by normalizing assignment on issues already marked as
# actively worked (`status:queued` or `status:in-progress`). If an issue
# has one of these labels but no assignee, assign it to the runner user.
#
# Returns: 0 always (best-effort)
#######################################
normalize_active_issue_assignments() {
	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local runner_user
	runner_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$runner_user" ]]; then
		echo "[pulse-wrapper] Assignment normalization skipped: unable to resolve runner user" >>"$LOGFILE"
		return 0
	fi

	local total_checked=0
	local total_assigned=0
	local now_epoch
	now_epoch=$(date +%s)

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issue_rows issue_rows_json issue_rows_err
		issue_rows_err=$(mktemp)
		issue_rows_json=$(gh issue list --repo "$slug" --state open --json number,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$issue_rows_err") || issue_rows_json=""
		if [[ -z "$issue_rows_json" || "$issue_rows_json" == "null" ]]; then
			local _issue_rows_err_msg
			_issue_rows_err_msg=$(cat "$issue_rows_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] normalize_active_issue_assignments: gh issue list FAILED for ${slug}: ${_issue_rows_err_msg}" >>"$LOGFILE"
			rm -f "$issue_rows_err"
			continue
		fi
		rm -f "$issue_rows_err"
		issue_rows=$(printf '%s' "$issue_rows_json" | jq -r '.[] | select(((.labels | map(.name) | index("status:queued")) or (.labels | map(.name) | index("status:in-progress"))) and ((.assignees | length) == 0)) | .number' 2>/dev/null) || issue_rows=""
		if [[ -z "$issue_rows" ]]; then
			continue
		fi

		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			total_checked=$((total_checked + 1))
			if gh issue edit "$issue_number" --repo "$slug" --add-assignee "$runner_user" >/dev/null 2>&1; then
				total_assigned=$((total_assigned + 1))
			fi
		done <<<"$issue_rows"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_checked" -gt 0 ]]; then
		echo "[pulse-wrapper] Assignment normalization: assigned ${total_assigned}/${total_checked} active unassigned issues to ${runner_user}" >>"$LOGFILE"
	fi

	# --- Pass 2: Reset stale assignments (GH#16842) ---
	# Workers that crash after the launch validation window leave issues with
	# assignees + status:queued/in-progress but no running worker process.
	# The dedup guard then blocks re-dispatch indefinitely. Reset these so
	# the deterministic fill floor can re-dispatch them.
	#
	# t1933: PID-based checks are local-only. In multi-runner setups, a worker
	# dispatched by another machine is invisible to pgrep on this machine.
	# Gate PID checks on runner identity: if the dispatch comment's Worker PID
	# is not running locally, fall back to WORKER_MAX_RUNTIME time-based expiry
	# before resetting. This prevents false recovery of cross-runner dispatches.
	local total_reset=0
	# Default max runtime for cross-runner time-based expiry (3h, matches worker-watchdog.sh default)
	local cross_runner_max_runtime="${WORKER_MAX_RUNTIME:-10800}"

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json
		stale_json=$(gh issue list --repo "$slug" --assignee "$runner_user" --state open \
			--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		[[ -n "$stale_json" && "$stale_json" != "null" ]] || continue

		# Filter: has status:queued or status:in-progress, updated >1h ago
		local stale_issues
		stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - 3600))" '
			[.[] | select(
				((.labels | map(.name)) | (index("status:queued") or index("status:in-progress")))
				and ((.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]
		' 2>/dev/null) || stale_issues=""
		[[ -n "$stale_issues" ]] || continue

		# For each candidate, verify no active worker process exists
		local repo_path_for_slug
		repo_path_for_slug=$(jq -r --arg s "$slug" '.initialized_repos[] | select(.slug == $s) | .path' "$repos_json" 2>/dev/null) || repo_path_for_slug=""

		local stale_num
		while IFS= read -r stale_num; do
			[[ "$stale_num" =~ ^[0-9]+$ ]] || continue

			# t1933: Extract Worker PID from the most recent dispatch comment.
			# If the dispatch comment records a PID that is NOT running locally,
			# this may be a cross-runner dispatch — use time-based expiry instead
			# of PID-based recovery to avoid falsely resetting active workers on
			# other machines.
			local dispatch_pid=""
			local dispatch_comment_age=0
			local dispatch_created_at=""

			# Read PID and creation date from the latest dispatch comment in one go.
			# This avoids storing the full comment JSON and running multiple jq processes.
			# The || true on the process substitution prevents set -e from exiting
			# if gh api returns no comments.
			{
				IFS= read -r dispatch_pid
				IFS= read -r dispatch_created_at
			} < <(gh api "repos/${slug}/issues/${stale_num}/comments" \
				--jq '[.[] | select(.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker"))] | sort_by(.created_at) | last | if . then ((.body | capture("\\*\\*Worker PID\\*\\*: (?<pid>[0-9]+)") | .pid // ""), .created_at) else empty end' \
				2>/dev/null) || true

			if [[ -n "$dispatch_created_at" ]]; then
				local dispatch_epoch
				dispatch_epoch=$(date -u -d "$dispatch_created_at" '+%s' 2>/dev/null ||
					TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$dispatch_created_at" '+%s' 2>/dev/null ||
					echo "0")
				if [[ "$dispatch_epoch" -gt 0 ]]; then
					dispatch_comment_age=$((now_epoch - dispatch_epoch))
				fi
			fi

			# Check if any worker process references this issue (local PID check)
			local local_worker_found=false
			if pgrep -f "issue.*${stale_num}" >/dev/null 2>&1 || pgrep -f "#${stale_num}" >/dev/null 2>&1; then
				local_worker_found=true
			fi

			if [[ "$local_worker_found" == "true" ]]; then
				# Local worker is running — do not reset
				continue
			fi

			# t1933: If dispatch comment has a PID that is not running locally,
			# determine if this is a cross-runner dispatch by checking whether
			# the PID exists on this machine. If the PID is absent locally but
			# the dispatch comment is still within WORKER_MAX_RUNTIME, assume
			# the worker is running on another machine and skip the reset.
			if [[ -n "$dispatch_pid" ]] && [[ "$dispatch_pid" =~ ^[0-9]+$ ]]; then
				if ! ps -p "$dispatch_pid" >/dev/null 2>&1; then
					# PID not running locally — could be cross-runner dispatch.
					# Only reset if the dispatch comment has aged beyond WORKER_MAX_RUNTIME.
					if [[ "$dispatch_comment_age" -lt "$cross_runner_max_runtime" ]]; then
						echo "[pulse-wrapper] Stale assignment skip (cross-runner guard): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not local, comment age ${dispatch_comment_age}s < max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
						continue
					fi
					echo "[pulse-wrapper] Stale assignment reset (cross-runner expired): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not local, comment age ${dispatch_comment_age}s >= max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
				fi
			fi

			# Also check worker log recency — if log was written in last 10 min, worker may still be active
			local safe_slug_check
			safe_slug_check=$(printf '%s' "$slug" | tr '/:' '--')
			local worker_log="/tmp/pulse-${safe_slug_check}-${stale_num}.log"
			if [[ -f "$worker_log" ]]; then
				local log_mtime
				# Linux stat -c first (stat -f '%m' on Linux outputs filesystem info to stdout)
				log_mtime=$(stat -c '%Y' "$worker_log" 2>/dev/null || stat -f '%m' "$worker_log" 2>/dev/null) || log_mtime=0
				if [[ $((now_epoch - log_mtime)) -lt 600 ]]; then
					continue
				fi
			fi

			# No local worker and cross-runner guard passed — reset the issue for re-dispatch
			echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
			gh issue edit "$stale_num" --repo "$slug" \
				--remove-assignee "$runner_user" \
				--remove-label "status:queued" --remove-label "status:in-progress" \
				--add-label "status:available" >/dev/null 2>&1 || true
			total_reset=$((total_reset + 1))
		done <<<"$stale_issues"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_reset" -gt 0 ]]; then
		echo "[pulse-wrapper] Stale assignment cleanup: reset ${total_reset} issues for re-dispatch" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Close open issues whose work is already done — a merged PR exists
# that references the issue via "Closes #N" or matching task ID in
# the PR title (GH#16851).
#
# The dedup guard (Layer 4) detects these and blocks re-dispatch,
# but the issue stays open forever. This stage closes them with a
# comment linking to the merged PR, cleaning the backlog.
#######################################
close_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Only check issues marked available for dispatch. Capped at 20
		# per repo to limit API calls (dedup helper makes 1 call per issue).
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:available" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Skip management issues (supervisor, persistent, quality-review)
			# — these are intentionally kept open
			local labels_csv
			labels_csv=$(printf '%s' "$issues_json" | jq -r ".[$((i - 1))].labels // [] | map(.name) | join(\",\")" 2>/dev/null) || labels_csv=""

			# Ask dedup helper if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# has-open-pr returns 0 when PR evidence found (open OR merged).
				# For closing, we MUST verify the PR is actually merged — an open
				# PR means work is in progress, not complete. (GH#17871 fix)
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				# GH#17871: Verify PR is actually merged before closing.
				# The dedup helper's Check 1 matches OPEN PRs by title/commit.
				# An open PR blocks dispatch (correct) but must NOT trigger
				# issue closure — the work isn't done yet.
				if [[ -n "$pr_num" ]]; then
					local merged_at
					merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
					if [[ -z "$merged_at" ]]; then
						echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} exists but is NOT merged (GH#17871 guard)" >>"$LOGFILE"
						continue
					fi
				fi

				# GH#17372: Verify PR diff actually touches files from the issue.
				# A merged PR with "closes #NNN" may reference the issue without
				# fixing it (e.g., mentioned in a comment, not the actual fix).
				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true
				# t1934: Unlock issue (locked at dispatch time)
				unlock_issue_after_worker "$issue_num" "$slug"

				echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Close issues with merged PRs: closed ${total_closed} issue(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Reconcile status:done issues that are still open.
#
# Workers set status:done when they believe work is complete, but the
# issue may stay open if: (1) PR merged but Closes #N was missing,
# (2) worker declared done but never created a PR, (3) PR was rejected.
#
# Case 1: merged PR found → close the issue (work verified done).
# Cases 2+3: no merged PR → reset to status:available for re-dispatch.
#
# Capped at 20 per repo per cycle to limit API calls.
#######################################
reconcile_stale_done_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0
	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:done" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Check if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# Dedup helper returns 0 for open OR merged PRs.
				# For closing, verify the PR is actually merged (GH#17871).
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				# GH#17871: Verify PR is actually merged before closing.
				local merged_at=""
				if [[ -n "$pr_num" ]]; then
					merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
					if [[ -z "$merged_at" ]]; then
						echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
						# Reset to available — PR exists but isn't merged yet
						gh issue edit "$issue_num" --repo "$slug" \
							--remove-label "status:done" \
							--add-label "status:available" >/dev/null 2>&1 || continue
						total_reset=$((total_reset + 1))
						continue
					fi
				fi

				# GH#17372: Verify PR diff touches files from the issue
				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
						# Reset to available for re-evaluation instead of closing
						gh issue edit "$issue_num" --repo "$slug" \
							--remove-label "status:done" \
							--add-label "status:available" >/dev/null 2>&1 || continue
						total_reset=$((total_reset + 1))
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"} (merged at ${merged_at:-unknown})." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true
				# t1934: Unlock issue (locked at dispatch time)
				unlock_issue_after_worker "$issue_num" "$slug"

				echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			else
				# No merged PR — reset for re-evaluation
				gh issue edit "$issue_num" --repo "$slug" \
					--remove-label "status:done" \
					--add-label "status:available" >/dev/null 2>&1 || continue
				echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
				total_reset=$((total_reset + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$((total_closed + total_reset))" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile stale done issues: closed=${total_closed}, reset=${total_reset}" >>"$LOGFILE"
	fi

	return 0
}
