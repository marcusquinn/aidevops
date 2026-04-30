#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-stuck.sh — Stuck-merge detector + zero-progress circuit breaker (t3193, GH#21895)
#
# Detects PRs that are merge-eligible (APPROVED + MERGEABLE + no hold-for-review)
# but stay unmerged past a configurable threshold, classifies the stuck reason,
# files escalation comments/issues, and tracks zero-progress cycles.
#
# Mirrors the layout of pulse-merge-conflict.sh — sourced by pulse-wrapper.sh
# AFTER pulse-merge.sh and its sub-libraries. MUST NOT be executed directly.
#
# Functions in this module (in source order):
#   - _stuck_merge_load_config              (config loader)
#   - _classify_stuck_pr                    (per-PR classifier)
#   - _stuck_pr_failure_fingerprint         (extract failing check names)
#   - _detect_pattern_outage               (cross-PR outage grouping)
#   - _escalate_individual_stuck_pr         (one-shot PR comment)
#   - _handle_stuck_conflict_no_nudge       (label-agnostic rebase nudge)
#   - _run_stuck_merge_detector             (per-repo entry point)
#   - run_stuck_merge_detector_all_repos    (top-level entry point)
#   - _update_zero_progress_counter         (cycle-level throughput tracker)
#
# All functions fail-open: missing helpers, API errors, or malformed
# state never block the merge pass — they log and return 0.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_STUCK_LOADED:-}" ]] && return 0
_PULSE_MERGE_STUCK_LOADED=1

# Module-level variable defaults (set -u guards).
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"

# Shared string constants (quality gate: no repeated literals).
_STUCK_CLASS_NOT_STUCK="NOT_STUCK"
_STUCK_LABELS="auto-dispatch,tier:thinking,source:merge-stuck-detector,bug"
_STUCK_COUNTER_ESCALATIONS="pulse_merge_stuck_escalations_filed"

# Zero-progress state file — persists across cycles.
_STUCK_ZERO_PROGRESS_FILE="${HOME}/.aidevops/logs/pulse-merge-zero-progress.count"

#######################################
# Load stuck-merge thresholds from config file.
# Env vars take precedence over conf file values.
# Fail-open: missing conf file uses hardcoded defaults.
#######################################
_stuck_merge_load_config() {
	local conf_file="${HOME}/.aidevops/agents/configs/pulse-merge-stuck.conf"

	# Hardcoded defaults (always set first).
	: "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:=240}"
	: "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:=5}"
	: "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:=3}"

	# Source conf file only to pick up values not already set by env.
	if [[ -f "$conf_file" ]]; then
		local _saved_age="${AIDEVOPS_MERGE_STUCK_AGE_MINUTES}"
		local _saved_cycles="${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES}"
		local _saved_min="${AIDEVOPS_MERGE_PATTERN_MIN_PRS}"
		# shellcheck source=/dev/null
		source "$conf_file" 2>/dev/null || true
		# Restore env overrides (env takes precedence).
		[[ -n "$_saved_age" ]] && AIDEVOPS_MERGE_STUCK_AGE_MINUTES="$_saved_age"
		[[ -n "$_saved_cycles" ]] && AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES="$_saved_cycles"
		[[ -n "$_saved_min" ]] && AIDEVOPS_MERGE_PATTERN_MIN_PRS="$_saved_min"
	fi
	return 0
}

#######################################
# Classify a stuck PR. Returns a classification string on stdout.
#
# Classifications:
#   STUCK_CHECKS_FAILING       — >=1 check FAILURE, no conflict
#   STUCK_CONFLICT_NO_NUDGE    — CONFLICTING, no origin:interactive/contributor label
#   STUCK_BRANCHPROTECT_404    — branch protection 404 (no protection configured)
#   STUCK_AUTH                 — gh auth signature in error output
#   STUCK_OTHER                — eligible but no clear signal
#   NOT_STUCK                  — PR is not stuck (too young, not approved, etc.)
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - pr_json (compact JSON object with number,mergeable,reviewDecision,
#        author,title,labels,createdAt,updatedAt fields)
#######################################
_classify_stuck_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_json="$3"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || { echo "$_STUCK_CLASS_NOT_STUCK"; return 0; }

	# Extract fields from the PR JSON.
	local mergeable="" review_decision="" labels_csv="" created_at=""
	mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // ""' 2>/dev/null) || mergeable=""
	review_decision=$(printf '%s' "$pr_json" | jq -r 'if (.reviewDecision | length) == 0 then "NONE" else .reviewDecision end' 2>/dev/null) || review_decision="NONE"
	labels_csv=$(printf '%s' "$pr_json" | jq -r '[.labels[]?.name // empty] | join(",")' 2>/dev/null) || labels_csv=""
	created_at=$(printf '%s' "$pr_json" | jq -r '.createdAt // ""' 2>/dev/null) || created_at=""

	# Skip PRs with hold-for-review or draft status.
	if [[ "$labels_csv" == *"hold-for-review"* ]]; then
		echo "$_STUCK_CLASS_NOT_STUCK"
		return 0
	fi

	# Check PR age against threshold.
	local age_minutes=0
	if [[ -n "$created_at" ]]; then
		local created_epoch=0 now_epoch=0
		created_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null) || created_epoch=0
		now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
		if [[ "$created_epoch" -gt 0 && "$now_epoch" -gt 0 ]]; then
			age_minutes=$(( (now_epoch - created_epoch) / 60 ))
		fi
	fi

	if [[ "$age_minutes" -lt "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-240}" ]]; then
		echo "$_STUCK_CLASS_NOT_STUCK"
		return 0
	fi

	# CONFLICTING with no rebase-nudge-eligible labels.
	if [[ "$mergeable" == "CONFLICTING" ]]; then
		if [[ "$labels_csv" != *"origin:interactive"* && "$labels_csv" != *"origin:contributor"* ]]; then
			echo "STUCK_CONFLICT_NO_NUDGE"
			return 0
		fi
		echo "$_STUCK_CLASS_NOT_STUCK"
		return 0
	fi

	# Only classify further if reviewed (APPROVED or at least not CHANGES_REQUESTED).
	if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
		echo "$_STUCK_CLASS_NOT_STUCK"
		return 0
	fi

	# If MERGEABLE but not merged — check for failing checks.
	if [[ "$mergeable" == "MERGEABLE" ]]; then
		# Fetch check run status for this PR.
		local pr_sha="" check_json=""
		pr_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null) || pr_sha=""
		if [[ -z "$pr_sha" ]]; then
			pr_sha=$(gh pr view "$pr_number" --repo "$repo_slug" \
				--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_sha=""
		fi

		if [[ -n "$pr_sha" ]]; then
			local check_raw
			check_raw=$(gh api "repos/${repo_slug}/commits/${pr_sha}/check-runs" 2>/dev/null) || check_raw="{}"
			check_json=$(printf '%s' "$check_raw" | jq '.check_runs // []' 2>/dev/null) || check_json="[]"
			local failing_count
			failing_count=$(printf '%s' "$check_json" | jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null) || failing_count=0
			[[ "$failing_count" =~ ^[0-9]+$ ]] || failing_count=0

			if [[ "$failing_count" -gt 0 ]]; then
				echo "STUCK_CHECKS_FAILING"
				return 0
			fi
		fi

		echo "STUCK_OTHER"
		return 0
	fi

	echo "$_STUCK_CLASS_NOT_STUCK"
	return 0
}

#######################################
# Extract failing check names as a sorted comma-separated fingerprint.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
# Output: sorted CSV of failing check names (e.g. "Format,Lint,Typecheck")
#######################################
_stuck_pr_failure_fingerprint() {
	local pr_number="$1"
	local repo_slug="$2"

	local pr_sha
	pr_sha=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_sha=""
	[[ -n "$pr_sha" ]] || { echo ""; return 0; }

	local check_raw="" fingerprint=""
	check_raw=$(gh api "repos/${repo_slug}/commits/${pr_sha}/check-runs" 2>/dev/null) || check_raw="{}"
	fingerprint=$(printf '%s' "$check_raw" | jq -r '[.check_runs[] | select(.conclusion == "failure") | .name] | sort | join(",")' 2>/dev/null) || fingerprint=""
	echo "$fingerprint"
	return 0
}

#######################################
# Detect pattern outages: groups of stuck PRs sharing a failure fingerprint.
# Files ONE investigation issue per unique fingerprint when count >= threshold.
# Deduped by HTML marker: <!-- merge-stuck:pattern:<sha256> -->
#
# Args:
#   $1 - repo_slug
#   $2 - newline-delimited list of "pr_number|fingerprint" pairs
#######################################
_detect_pattern_outage() {
	local repo_slug="$1"
	local fingerprint_data="$2"
	local min_prs="${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-3}"

	[[ -n "$fingerprint_data" ]] || return 0

	# Group by fingerprint and count.
	local fp_counts
	fp_counts=$(printf '%s\n' "$fingerprint_data" | awk -F'|' '{print $2}' | sort | uniq -c | sort -rn)

	while IFS= read -r line; do
		local count="" fp=""
		count=$(printf '%s' "$line" | awk '{print $1}')
		fp=$(printf '%s' "$line" | awk '{$1=""; print}' | sed 's/^ *//')
		[[ -n "$fp" && "$count" -ge "$min_prs" ]] || continue

		# Compute dedup marker.
		local fp_hash="" marker=""
		fp_hash=$(printf '%s' "$fp" | sha256sum 2>/dev/null | awk '{print $1}') || fp_hash=$(printf '%s' "$fp" | md5sum 2>/dev/null | awk '{print $1}') || fp_hash="unknown"
		marker="<!-- merge-stuck:pattern:${fp_hash} -->"

		# Check if we already filed this outage (search open issues).
		local existing
		existing=$(gh issue list --repo "$repo_slug" --state open \
			--search "merge-stuck pattern outage" --limit 5 \
			--json number,body 2>/dev/null) || existing="[]"
		if printf '%s' "$existing" | grep -q "$marker" 2>/dev/null; then
			echo "[pulse-merge-stuck] Pattern outage already filed for fingerprint '${fp}' in ${repo_slug} — skipping" >>"$LOGFILE"
			continue
		fi

		# Collect affected PR numbers.
		local affected_prs
		affected_prs=$(printf '%s\n' "$fingerprint_data" | awk -F'|' -v target="$fp" '$2 == target {print "#" $1}' | tr '\n' ' ')

		# File the investigation issue.
		local body
		body="${marker}
## Merge-stuck pattern outage detected (t3193)

**${count} PRs** in \`${repo_slug}\` share an identical CI failure fingerprint and have been stuck past the ${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-240}-minute threshold.

### Failure fingerprint

\`\`\`
${fp}
\`\`\`

### Affected PRs

${affected_prs}

### Analysis

When multiple PRs fail the **same set of checks**, the root cause is typically:
- **Broken base branch** (CI infra change, dependency update, lockfile drift)
- **Shared CI environment issue** (runner unavailable, service account expired)
- **Configuration change** that affects all PRs (linter rule, workflow update)

### Recommended action

1. Check the default branch CI status — run the failing checks against \`HEAD\` of the default branch
2. If the base is broken, fix it directly on the default branch
3. Once the base is green, the stuck PRs should auto-resolve on next rebase/update-branch cycle

<sub>Filed automatically by \`pulse-merge-stuck.sh\` (t3193, GH#21895)</sub>"

		if declare -F gh_create_issue >/dev/null 2>&1; then
			gh_create_issue --repo "$repo_slug" \
				--title "Merge-stuck: ${count} PRs failing ${fp}" \
				--body "$body" \
				--label "$_STUCK_LABELS" 2>/dev/null || true
		else
			echo "[pulse-merge-stuck] gh_create_issue not available — cannot file pattern outage for ${repo_slug}" >>"$LOGFILE"
		fi
		pulse_stats_increment "$_STUCK_COUNTER_ESCALATIONS" 2>/dev/null || true
		echo "[pulse-merge-stuck] Filed pattern outage issue for fingerprint '${fp}' (${count} PRs) in ${repo_slug}" >>"$LOGFILE"
	done <<< "$fp_counts"

	return 0
}

#######################################
# Post a one-shot escalation comment on an individual stuck PR's linked issue.
# Deduped by marker: <!-- merge-stuck:individual -->
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - classification (e.g. STUCK_CHECKS_FAILING)
#######################################
_escalate_individual_stuck_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local classification="$3"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	local marker="<!-- merge-stuck:individual:${pr_number} -->"

	# Find linked issue.
	local linked_issue=""
	if declare -F _extract_linked_issue >/dev/null 2>&1; then
		linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue=""
	fi

	# Post on the PR itself if no linked issue found.
	local target_type="pr"
	local target_number="$pr_number"
	if [[ -n "$linked_issue" ]]; then
		target_type="issue"
		target_number="$linked_issue"
	fi

	# Check dedup marker.
	if declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		local comment_body
		comment_body="${marker}
## Stuck-merge detected (t3193)

PR #${pr_number} has been merge-eligible but stuck for >${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-240} minutes.

**Classification:** \`${classification}\`

### Recommended action

"
		case "$classification" in
			STUCK_CHECKS_FAILING)
				comment_body+="CI checks are failing. Review the failing checks on the PR and either:
- Fix the failures if they are PR-specific
- Check if the default branch CI is also broken (pattern outage)"
				;;
			STUCK_CONFLICT_NO_NUDGE)
				comment_body+="The PR has merge conflicts but no \`origin:interactive\` or \`origin:contributor\` label, so the existing rebase-nudge paths did not fire. Rebase the branch against the default branch."
				;;
			STUCK_OTHER)
				comment_body+="The PR appears merge-eligible but is not being merged. Check for transient API errors, stale merge state, or missing approvals."
				;;
			*)
				comment_body+="Investigate the merge state of this PR."
				;;
		esac

		comment_body+="

<sub>Posted automatically by \`pulse-merge-stuck.sh\` (t3193)</sub>"

		_gh_idempotent_comment "$target_number" "$repo_slug" "$marker" "$comment_body" "$target_type" || true
		pulse_stats_increment "$_STUCK_COUNTER_ESCALATIONS" 2>/dev/null || true
		echo "[pulse-merge-stuck] Escalated stuck PR #${pr_number} (${classification}) in ${repo_slug}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Post a label-agnostic rebase nudge for CONFLICTING PRs that don't have
# origin:interactive or origin:contributor labels. Extends the existing
# rebase-nudge family. Uses the same marker for idempotency.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#######################################
_handle_stuck_conflict_no_nudge() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _handle_stuck_conflict_no_nudge: _gh_idempotent_comment not defined — skipping PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local marker="<!-- pulse-rebase-nudge -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — branch has merge conflicts (t3193)

This PR has merge conflicts against the default branch and has been stuck for >${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-240} minutes. The pulse merge pass cannot auto-resolve these conflicts.

### To resolve

Rebase against the default branch and force-push:

\`\`\`bash
git fetch origin
git rebase origin/<default-branch>
# resolve conflicts
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial.

<sub>Posted automatically by \`pulse-merge-stuck.sh\` (t3193, GH#21895)</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# Run stuck-merge detector for a single repo.
# Called after the merge pass for that repo completes.
#
# Args:
#   $1 - repo_slug
# Env: uses AIDEVOPS_MERGE_STUCK_AGE_MINUTES, AIDEVOPS_MERGE_PATTERN_MIN_PRS
#######################################
_run_stuck_merge_detector() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 0

	_stuck_merge_load_config

	# Fetch open PRs with extended fields for classification.
	local pr_list
	pr_list=$(gh pr list --repo "$repo_slug" --state open \
		--json number,mergeable,reviewDecision,author,title,labels,createdAt,headRefOid \
		--limit 50 2>/dev/null) || pr_list="[]"

	local pr_count
	pr_count=$(printf '%s' "$pr_list" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -gt 0 ]] || return 0

	local stuck_count=0
	local fingerprint_data=""

	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" pr_number="" classification=""
		pr_obj=$(printf '%s' "$pr_list" | jq -c ".[$i]" 2>/dev/null)
		pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // ""' 2>/dev/null)
		i=$((i + 1))
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue

		classification=$(_classify_stuck_pr "$pr_number" "$repo_slug" "$pr_obj")

		case "$classification" in
			NOT_STUCK)
				continue
				;;
			STUCK_CHECKS_FAILING)
				stuck_count=$((stuck_count + 1))
				# Collect fingerprint for outage detection.
				local fp
				fp=$(_stuck_pr_failure_fingerprint "$pr_number" "$repo_slug")
				if [[ -n "$fp" ]]; then
					fingerprint_data+="${pr_number}|${fp}"$'\n'
				fi
				# Individual escalation (only if not part of a pattern outage).
				# Deferred until after pattern detection.
				;;
			STUCK_CONFLICT_NO_NUDGE)
				stuck_count=$((stuck_count + 1))
				_handle_stuck_conflict_no_nudge "$pr_number" "$repo_slug"
				;;
			STUCK_OTHER)
				stuck_count=$((stuck_count + 1))
				_escalate_individual_stuck_pr "$pr_number" "$repo_slug" "$classification"
				;;
		esac
	done

	# Pattern outage detection for STUCK_CHECKS_FAILING PRs.
	if [[ -n "$fingerprint_data" ]]; then
		_detect_pattern_outage "$repo_slug" "$fingerprint_data"

		# Escalate individual STUCK_CHECKS_FAILING PRs that are NOT part of a pattern.
		local min_prs="${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-3}"
		while IFS='|' read -r _pr_num _fp; do
			[[ -n "$_pr_num" && -n "$_fp" ]] || continue
			local fp_count
			fp_count=$(printf '%s\n' "$fingerprint_data" | awk -F'|' -v target="$_fp" '$2 == target' | wc -l)
			fp_count=$(echo "$fp_count" | tr -d ' ')
			if [[ "$fp_count" -lt "$min_prs" ]]; then
				_escalate_individual_stuck_pr "$_pr_num" "$repo_slug" "STUCK_CHECKS_FAILING"
			fi
		done <<< "$fingerprint_data"
	fi

	# Update gauge counter.
	if [[ "$stuck_count" -gt 0 ]]; then
		echo "[pulse-merge-stuck] ${stuck_count} stuck PR(s) detected in ${repo_slug}" >>"$LOGFILE"
	fi

	# Return the stuck count via stdout for the caller to aggregate.
	echo "$stuck_count"
	return 0
}

#######################################
# Top-level entry point: run stuck-merge detector across all pulse-enabled repos.
# Called from merge_ready_prs_all_repos after the merge pass completes.
#
# Args:
#   $1 - total_merged (from the merge pass, for zero-progress tracking)
#######################################
run_stuck_merge_detector_all_repos() {
	local total_merged="${1:-0}"

	_stuck_merge_load_config

	local _repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$_repos_json" ]] || return 0

	local total_stuck=0

	while IFS='|' read -r repo_slug _; do
		[[ -n "$repo_slug" ]] || continue
		local repo_stuck
		repo_stuck=$(_run_stuck_merge_detector "$repo_slug" 2>/dev/null) || repo_stuck=0
		[[ "$repo_stuck" =~ ^[0-9]+$ ]] || repo_stuck=0
		total_stuck=$((total_stuck + repo_stuck))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$_repos_json" 2>/dev/null)

	# Record gauge counter.
	if declare -F pulse_stats_increment >/dev/null 2>&1 && [[ "$total_stuck" -gt 0 ]]; then
		local _i=0
		while [[ "$_i" -lt "$total_stuck" ]]; do
			pulse_stats_increment "pulse_merge_eligible_stuck_pr_count" 2>/dev/null || true
			_i=$((_i + 1))
		done
	fi

	# Update zero-progress counter.
	_update_zero_progress_counter "$total_merged" "$total_stuck"

	echo "[pulse-merge-stuck] Detector complete: total_stuck=${total_stuck}" >>"$LOGFILE"
	return 0
}

#######################################
# Track zero-progress merge cycles.
# Increments counter when no PR was merged but eligible stuck PRs exist.
# Resets on any successful merge. Files meta-issue at threshold.
#
# Args:
#   $1 - total_merged (from current cycle)
#   $2 - total_stuck (eligible stuck PRs across all repos)
#######################################
_update_zero_progress_counter() {
	local total_merged="${1:-0}"
	local total_stuck="${2:-0}"
	local threshold="${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-5}"

	# If any PR was merged, reset counter.
	if [[ "$total_merged" -gt 0 ]]; then
		echo "0" > "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null || true
		return 0
	fi

	# No merge and no stuck PRs — nothing to track.
	if [[ "$total_stuck" -eq 0 ]]; then
		return 0
	fi

	# Increment counter.
	local current=0
	[[ -f "$_STUCK_ZERO_PROGRESS_FILE" ]] && current=$(cat "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null) || current=0
	[[ "$current" =~ ^[0-9]+$ ]] || current=0
	current=$((current + 1))
	echo "$current" > "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null || true

	pulse_stats_increment "pulse_merge_zero_progress_cycles" 2>/dev/null || true

	# Check threshold.
	if [[ "$current" -ge "$threshold" ]]; then
		echo "[pulse-merge-stuck] Zero-progress counter hit threshold (${current} >= ${threshold}) — filing meta-issue" >>"$LOGFILE"
		_file_zero_progress_meta_issue "$total_stuck"
		# Reset after filing to avoid repeated meta-issues.
		echo "0" > "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null || true
	fi

	return 0
}

#######################################
# File a zero-progress meta-issue. Deduped by marker.
#
# Args:
#   $1 - total_stuck PR count
#######################################
_file_zero_progress_meta_issue() {
	local total_stuck="${1:-0}"
	local marker="<!-- merge-stuck:zero-progress -->"

	# Check if circuit breaker is active — suppress during GraphQL exhaustion.
	if [[ -f "${HOME}/.aidevops/logs/pulse-stats.json" ]]; then
		local cb_active
		cb_active=$(jq -r '.counters.pulse_dispatch_circuit_broken // [] | length' \
			"${HOME}/.aidevops/logs/pulse-stats.json" 2>/dev/null) || cb_active=0
		if [[ "$cb_active" -gt 0 ]]; then
			echo "[pulse-merge-stuck] Suppressing zero-progress meta-issue — circuit breaker active" >>"$LOGFILE"
			return 0
		fi
	fi

	# Dedup: check for existing open zero-progress issue.
	local existing
	existing=$(gh issue list --repo marcusquinn/aidevops --state open \
		--search "merge-stuck zero-progress" --limit 3 \
		--json number,body 2>/dev/null) || existing="[]"
	if printf '%s' "$existing" | grep -q "$marker" 2>/dev/null; then
		echo "[pulse-merge-stuck] Zero-progress meta-issue already open — skipping" >>"$LOGFILE"
		return 0
	fi

	local body
	body="${marker}
## Merge throughput collapse detected (t3193)

The pulse merge pass has completed **${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-5} consecutive cycles** with zero PRs merged while **${total_stuck} eligible PR(s)** remain stuck across managed repos.

### What this means

The merge pipeline is not making forward progress. Possible causes:
- All eligible PRs have failing CI checks (check for a shared base-branch issue)
- Branch protection API errors are causing fail-closed decisions
- Transient GitHub API outage blocking merge operations

### Recommended action

1. Run \`pulse-diagnose-helper.sh pr <N>\` on a representative stuck PR
2. Check \`~/.aidevops/logs/pulse-merge.log\` for recurring error patterns
3. If a shared CI failure: fix the default branch, then rebase stuck PRs

<sub>Filed automatically by \`pulse-merge-stuck.sh\` (t3193, GH#21895)</sub>"

	if declare -F gh_create_issue >/dev/null 2>&1; then
		gh_create_issue --repo marcusquinn/aidevops \
			--title "Merge-stuck: zero-progress for ${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-5} cycles (${total_stuck} stuck PRs)" \
			--body "$body" \
			--label "$_STUCK_LABELS" 2>/dev/null || true
	else
		echo "[pulse-merge-stuck] gh_create_issue not available — cannot file zero-progress meta-issue" >>"$LOGFILE"
	fi
	pulse_stats_increment "$_STUCK_COUNTER_ESCALATIONS" 2>/dev/null || true

	return 0
}
