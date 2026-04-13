#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-simplification-state.sh — Simplification hash-registry state management.
#
# Extracted from pulse-simplification.sh in t2020 (GH#18483) as the surgical
# split to clear the 2,000-line simplification gate that was blocking #18420
# (t1993: schedule post-merge-review-scanner.sh).
#
# This module contains the self-contained sub-cluster of functions that read,
# write, refresh, prune, push, and backfill .agents/configs/simplification-state.json
# — the shared hash registry the simplification routine uses to detect which
# files have been processed, how many passes they have been through, and whether
# they have converged.
#
# Why a separate module? The parent file (pulse-simplification.sh) had grown to
# 2,058 lines — 58 over the large-file simplification gate threshold — which
# deadlocked any dispatch that named the file as an implementation target. The
# state cluster is the largest self-contained sub-cluster in the parent file:
# its 7 functions only call each other, _complexity_scan_has_existing_issue
# (resolved at call time via Bash name resolution since both modules are sourced
# from pulse-wrapper.sh), and standard shell/gh/jq builtins. No call graph
# rewiring is needed — this is a pure move.
#
# This module is sourced by pulse-wrapper.sh immediately after
# pulse-simplification.sh. It MUST NOT be executed directly — it relies on the
# orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
#   pulse-simplification.sh   (source order: state AFTER parent, since parent
#                              defines _complexity_scan_has_existing_issue which
#                              _simplification_state_backfill_closed calls.
#                              Bash resolves function names at call time, so
#                              the inverse order would also work, but keeping
#                              state after parent reads left-to-right as
#                              "parent, then the state sub-cluster extracted
#                              from it".)
#
# Functions in this module (in source order, unchanged from parent):
#   - _simplification_state_check
#   - _simplification_state_record
#   - _simplification_state_refresh
#   - _simplification_state_prune
#   - _simplification_state_push
#   - _create_requeue_issue
#   - _simplification_state_backfill_closed
#
# This is a pure move from pulse-simplification.sh. Function bodies are
# byte-identical to their pre-extraction form.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_SIMPLIFICATION_STATE_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_STATE_LOADED=1

# Check if a file has already been simplified and is unchanged.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file path
# Returns: 0 = already simplified (unchanged/converged), 1 = not simplified or changed
# Outputs to stdout: "unchanged" | "converged" | "recheck" | "new"
# "converged" means the file has been through SIMPLIFICATION_MAX_PASSES passes
# and should not be re-flagged until it is genuinely modified by non-simplification work.
_simplification_state_check() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	if [[ ! -f "$state_file" ]]; then
		echo "new"
		return 1
	fi

	local recorded_hash
	recorded_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$state_file" 2>/dev/null) || recorded_hash=""

	if [[ -z "$recorded_hash" ]]; then
		echo "new"
		return 1
	fi

	# Compute current git blob hash
	local current_hash
	local full_path="${repo_path}/${file_path}"
	if [[ ! -f "$full_path" ]]; then
		echo "new"
		return 1
	fi
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""

	if [[ "$current_hash" == "$recorded_hash" ]]; then
		echo "unchanged"
		return 0
	fi

	# Hash differs — check pass count before flagging for recheck (t1754).
	# Files that have been through max_passes simplification rounds are
	# considered converged. They won't be re-flagged until the hash is
	# refreshed by _simplification_state_refresh (which resets passes to 0
	# only when the file is genuinely modified by non-simplification work).
	local passes
	passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || passes=0
	if [[ "$passes" -ge "$max_passes" ]]; then
		echo "converged"
		return 0
	fi

	echo "recheck"
	return 1
}

# Record a file as simplified in the state file.
# Increments the pass counter each time a file is re-simplified (t1754).
# Arguments: $1 - repo_path, $2 - file_path, $3 - state_file, $4 - pr_number
_simplification_state_record() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local pr_number="${4:-0}"

	local current_hash
	local full_path="${repo_path}/${file_path}"
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""
	[[ -z "$current_hash" ]] && return 1

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Ensure state file exists with valid structure
	if [[ ! -f "$state_file" ]]; then
		printf '{"files":{}}\n' >"$state_file"
	fi

	# Read existing pass count and increment (t1754 — convergence tracking)
	local prev_passes
	prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || prev_passes=0
	local new_passes=$((prev_passes + 1))

	# Update the entry using jq — includes pass counter
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
		--argjson pr "$pr_number" --argjson passes "$new_passes" \
		'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
		"$state_file" >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
	return 0
}

# Refresh all hashes in the simplification state file against current main (t1754).
# This replaces the fragile timeline-API-based backfill. For every file already
# in state, recompute git hash-object. If the hash matches, do nothing. If it
# differs, update the hash AND increment the pass counter (the file was changed
# by a simplification PR that merged since the last scan).
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 on success. Outputs refreshed count to stdout.
_simplification_state_refresh() {
	local repo_path="$1"
	local state_file="$2"
	local refreshed=0

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local file_paths
	file_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || file_paths=""
	[[ -z "$file_paths" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	while IFS= read -r fp; do
		[[ -z "$fp" ]] && continue
		local full_path="${repo_path}/${fp}"
		[[ ! -f "$full_path" ]] && continue

		local current_hash stored_hash
		current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || continue
		# Read hash and passes in a single jq call — spawning jq twice per file
		# inside a loop is inefficient when the state file can have hundreds of entries (GH#18555).
		local prev_passes
		IFS=$'\t' read -r stored_hash prev_passes < <(
			jq -r --arg fp "$fp" \
				'.files[$fp] // {"hash": "", "passes": 0} | [(.hash // ""), (.passes // 0 | tostring)] | join("\t")' \
				"$tmp_state" 2>/dev/null
		)
		[[ -n "$stored_hash" ]] || stored_hash=""
		[[ "$prev_passes" =~ ^[0-9]+$ ]] || prev_passes=0

		# Also fix any non-SHA1 hashes (wrong algorithm, t1754)
		local stored_len=${#stored_hash}
		if [[ "$current_hash" != "$stored_hash" || "$stored_len" -ne 40 ]]; then
			local now_iso new_passes
			now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
			new_passes=$((prev_passes + 1))
			local inner_tmp
			inner_tmp=$(mktemp)
			jq --arg fp "$fp" --arg hash "$current_hash" --arg at "$now_iso" \
				--argjson passes "$new_passes" \
				'.files[$fp].hash = $hash | .files[$fp].at = $at | .files[$fp].passes = $passes' \
				"$tmp_state" >"$inner_tmp" 2>/dev/null && mv "$inner_tmp" "$tmp_state" || rm -f "$inner_tmp"
			refreshed=$((refreshed + 1))
		fi
	done <<<"$file_paths"

	if [[ "$refreshed" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$refreshed"
	return 0
}

# Prune stale entries from simplification state (files that no longer exist).
# This handles file moves/renames/deletions — entries for non-existent files
# are removed so they don't cause false "recheck" status or accumulate.
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 = pruned (or nothing to prune), 1 = error
# Outputs to stdout: number of entries pruned
_simplification_state_prune() {
	local repo_path="$1"
	local state_file="$2"

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local all_paths
	all_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || {
		echo "0"
		return 1
	}

	local pruned=0
	local stale_paths=""
	while IFS= read -r file_path; do
		[[ -z "$file_path" ]] && continue
		local full_path="${repo_path}/${file_path}"
		if [[ ! -f "$full_path" ]]; then
			stale_paths="${stale_paths}${file_path}\n"
			pruned=$((pruned + 1))
		fi
	done <<<"$all_paths"

	if [[ "$pruned" -gt 0 ]]; then
		local tmp_file
		tmp_file=$(mktemp)
		# Build a JSON array of stale paths and remove all in one jq pass using
		# --argjson. Building a jq filter by string concatenation is fragile:
		# paths containing quotes or special characters cause syntax errors and
		# are a potential injection vector (GH#18555).
		local stale_paths_json
		stale_paths_json=$(printf '%b' "$stale_paths" | jq -R . | jq -s .)
		jq --argjson paths "${stale_paths_json:-[]}" \
			'reduce $paths[] as $p (.; del(.files[$p])) | {"files": .files}' \
			"$state_file" >"$tmp_file" 2>/dev/null || {
			# Fallback: remove entries one at a time using safe --arg (not string concat)
			cp "$state_file" "$tmp_file"
			while IFS= read -r sp; do
				[[ -z "$sp" ]] && continue
				local tmp2
				tmp2=$(mktemp)
				jq --arg fp "$sp" 'del(.files[$fp])' "$tmp_file" >"$tmp2" 2>/dev/null && mv "$tmp2" "$tmp_file" || rm -f "$tmp2"
			done < <(printf '%b' "$stale_paths")
		}
		mv "$tmp_file" "$state_file" || {
			rm -f "$tmp_file"
			echo "0"
			return 1
		}
	fi

	echo "$pruned"
	return 0
}

# Commit and push simplification state to main (planning data, not code).
# Arguments: $1 - repo_path
_simplification_state_push() {
	local repo_path="$1"
	local state_rel=".agents/configs/simplification-state.json"

	# Only push from the canonical (main) worktree
	local main_branch
	main_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"
	local current_branch
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""

	if [[ "$current_branch" != "$main_branch" ]]; then
		echo "[pulse-wrapper] simplification-state: skipping push — not on $main_branch (on $current_branch)" >>"$LOGFILE"
		return 0
	fi

	if ! git -C "$repo_path" diff --quiet -- "$state_rel" 2>/dev/null; then
		git -C "$repo_path" add "$state_rel" 2>/dev/null || return 1
		git -C "$repo_path" commit -m "chore: update simplification state registry" --no-verify 2>/dev/null || return 1
		git -C "$repo_path" push origin "$main_branch" 2>/dev/null || return 1
		echo "[pulse-wrapper] simplification-state: pushed updated state to $main_branch" >>"$LOGFILE"
	fi
	return 0
}

# Create a follow-up simplification-debt issue when Qlty smells persist after
# a simplification PR merges (t1912). Each re-queue creates a NEW issue (not a
# reopen) for a clean audit trail of each pass.
#
# Arguments:
#   $1 - aidevops_slug (owner/repo)
#   $2 - file_path (repo-relative)
#   $3 - remaining_smells (integer count)
#   $4 - pass_count (current pass number, already incremented)
#   $5 - prev_issue_num (the issue that just closed)
# Returns: 0 on success, 1 on failure. Outputs created issue number to stdout.
_create_requeue_issue() {
	local aidevops_slug="$1"
	local file_path="$2"
	local remaining_smells="$3"
	local pass_count="$4"
	local prev_issue_num="$5"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	# Determine tier based on pass count — escalate to reasoning after max passes
	local tier_label="tier:standard"
	local escalation_note=""
	if [[ "$pass_count" -ge "$max_passes" ]]; then
		tier_label="tier:reasoning"
		escalation_note="

### Escalation note

This file has been through ${pass_count} simplification passes but ${remaining_smells} Qlty smells remain. Previous passes achieved partial reduction but the remaining complexity likely requires **architectural decomposition** (extracting modules, splitting concerns) rather than incremental tightening. Consider a different approach than the previous passes took."
	fi

	local issue_title="simplification: re-queue ${file_path} (pass ${pass_count}, ${remaining_smells} smells remaining)"

	# NOTE: Uses IFS read instead of $(cat <<HEREDOC) to avoid Bash 3.2 bug
	# where literal ) inside a heredoc nested in $() is misinterpreted as
	# closing the command substitution. macOS ships Bash 3.2 by default.
	local issue_body
	IFS= read -r -d '' issue_body <<REQUEUE_BODY_EOF || true
## Post-merge smell verification (automated — t1912)

**File:** \`${file_path}\`
**Qlty smells remaining:** ${remaining_smells}
**Pass:** ${pass_count} of ${max_passes} max
**Previous issue:** #${prev_issue_num}

The previous simplification pass (issue #${prev_issue_num}) merged successfully but Qlty still reports ${remaining_smells} smell(s) on this file. This follow-up issue was created automatically by the post-merge verification step.

### Context from previous pass

Review issue #${prev_issue_num} for what the previous attempt accomplished and what trade-offs were made. Build on that work rather than starting from scratch.

### Proposed action

1. Run \`~/.qlty/bin/qlty smells --all "${file_path}"\` to identify the specific remaining smells
2. Address the flagged complexity — reduce function length, extract helpers, simplify control flow
3. Verify: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty unavailable)${escalation_note}

### Verification

- Qlty smells resolved or reduced for the target file
- Content preservation: all task IDs, URLs, code blocks present before and after
- ShellCheck clean (for .sh files)
REQUEUE_BODY_EOF

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "Claude Code" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	local created_number=""
	# shellcheck disable=SC2086
	created_number=$(gh_create_issue --repo "$aidevops_slug" \
		--title "$issue_title" \
		--label "simplification-debt" --label "$tier_label" --label "auto-dispatch" \
		--body "$issue_body" 2>/dev/null | grep -oE '[0-9]+$') || {
		echo "[pulse-wrapper] _create_requeue_issue: failed to create re-queue issue for ${file_path}" >>"$LOGFILE"
		return 1
	}

	echo "[pulse-wrapper] _create_requeue_issue: created #${created_number} for ${file_path} (pass ${pass_count}, ${remaining_smells} smells, ${tier_label})" >>"$LOGFILE"
	echo "$created_number"
	return 0
}

# Backfill simplification state for recently closed issues (t1855).
#
# The critical bug: _simplification_state_record() was defined but never called.
# Workers complete simplification PRs and issues auto-close via "Closes #NNN",
# but the state file never gets updated. This function runs each scan cycle
# to detect recently closed simplification issues and record their file hashes.
#
# Arguments: $1 - repo_path, $2 - state_file, $3 - aidevops_slug
# Returns: 0. Outputs count of entries added to stdout.
_simplification_state_backfill_closed() {
	local repo_path="$1"
	local state_file="$2"
	local aidevops_slug="$3"
	local added=0

	# Fetch recently closed simplification issues (last 7 days, max 50)
	local closed_issues
	closed_issues=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state closed \
		--limit 50 --json number,title,closedAt 2>/dev/null) || {
		echo "0"
		return 0
	}
	[[ -z "$closed_issues" || "$closed_issues" == "[]" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	# Use process substitution to avoid subshell variable propagation bug (t1855).
	# A pipe (| while read) runs the loop in a subshell where $added won't propagate.
	while IFS= read -r issue; do
		[[ -z "$issue" ]] && continue
		local title file_path issue_num

		title=$(echo "$issue" | jq -r '.title') || continue
		issue_num=$(echo "$issue" | jq -r '.number') || continue

		# Extract file path from title — pattern: "simplification: tighten agent doc ... (path, N lines)"
		# or "simplification: reduce function complexity in path (N functions ...)"
		file_path=$(echo "$title" | grep -oE '\.[a-z][^ ,)]+\.(md|sh)' | head -1) || continue
		[[ -z "$file_path" ]] && continue

		# Skip if file doesn't exist
		[[ ! -f "${repo_path}/${file_path}" ]] && continue

		# Skip if already in state with matching hash
		local existing_hash
		existing_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$tmp_state" 2>/dev/null) || existing_hash=""
		local current_hash
		current_hash=$(git -C "$repo_path" hash-object "${repo_path}/${file_path}" 2>/dev/null) || continue

		if [[ "$existing_hash" == "$current_hash" ]]; then
			continue
		fi

		# Record the file in state — either new entry or updated hash
		local now_iso prev_passes new_passes
		now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
		prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$tmp_state" 2>/dev/null) || prev_passes=0
		new_passes=$((prev_passes + 1))

		local inner_tmp
		inner_tmp=$(mktemp)
		jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
			--argjson pr "$issue_num" --argjson passes "$new_passes" \
			'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
			"$tmp_state" >"$inner_tmp" 2>/dev/null && mv "$inner_tmp" "$tmp_state" || {
			rm -f "$inner_tmp"
			continue
		}
		added=$((added + 1))

		# Post-merge smell verification (t1912): check if Qlty still flags this file.
		# If smells persist after the simplification PR merged, create a follow-up
		# issue so the file gets another pass. Qlty CLI is optional — if not
		# installed, this step is skipped silently and the function behaves as before.
		local full_path="${repo_path}/${file_path}"
		local qlty_cmd=""
		if command -v qlty >/dev/null 2>&1; then
			qlty_cmd="qlty"
		elif [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
			qlty_cmd="${HOME}/.qlty/bin/qlty"
		fi

		if [[ -n "$qlty_cmd" ]]; then
			local remaining_smells
			remaining_smells=$("$qlty_cmd" smells --all "$full_path" 2>/dev/null | grep -c '^[^ ]' || echo "0")

			if [[ "$remaining_smells" -gt 0 ]]; then
				# Check for existing open re-queue issue before creating a new one
				if ! _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
					local requeue_result=""
					requeue_result=$(_create_requeue_issue "$aidevops_slug" "$file_path" "$remaining_smells" "$new_passes" "$issue_num") || true
					if [[ -n "$requeue_result" ]]; then
						echo "[pulse-wrapper] backfill: re-queued ${file_path} → #${requeue_result} (${remaining_smells} smells remain after #${issue_num})" >>"$LOGFILE"
					fi
				else
					echo "[pulse-wrapper] backfill: ${file_path} has ${remaining_smells} smells after #${issue_num} but open issue already exists — skipping re-queue" >>"$LOGFILE"
				fi
			else
				echo "[pulse-wrapper] backfill: ${file_path} — Qlty clean after #${issue_num} (pass ${new_passes})" >>"$LOGFILE"
			fi
		fi
	done < <(echo "$closed_issues" | jq -c '.[]')

	if [[ "$added" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$added"
	return 0
}
