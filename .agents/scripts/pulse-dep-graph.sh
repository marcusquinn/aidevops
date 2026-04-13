#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dep-graph.sh — Cross-issue dependency graph cache and blocked-status resolution (t1935).
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - build_dependency_graph_cache
#   - refresh_blocked_status_from_graph
#   - is_blocked_by_unresolved
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_DEP_GRAPH_LOADED:-}" ]] && return 0
_PULSE_DEP_GRAPH_LOADED=1

#######################################
# Dependency graph cache (t1935)
#
# Builds a JSON cache of all blocked-by relationships across pulse repos.
# The cache is rebuilt once per cycle (or when stale) so that
# is_blocked_by_unresolved() can answer without any live API calls.
#
# Cache format (DEP_GRAPH_CACHE_FILE):
# {
#   "built_at": "<ISO timestamp>",
#   "repos": {
#     "owner/repo": {
#       "open_issues": [<number>, ...],
#       "task_to_issue": { "tNNN": <number>, ... },
#       "blocked_by": {
#         "<issue_number>": {
#           "task_ids": ["NNN", ...],
#           "issue_nums": ["NNN", ...],
#           "has_defer_marker": true|false  # t2031 — body signals human hold
#         }
#       },
#       "defer_flags": { "<issue_number>": true, ... }  # t2031 — body defer
#                                                       # markers for issues
#                                                       # without blocked-by
#     }
#   }
# }
#
# Returns: 0 always (non-fatal — cache miss falls back to live API)
#######################################
build_dependency_graph_cache() {
	local cache_file="$DEP_GRAPH_CACHE_FILE"
	local ttl_secs="$DEP_GRAPH_CACHE_TTL_SECS"

	# Skip rebuild if cache is fresh
	if [[ -f "$cache_file" ]]; then
		local cache_age
		cache_age=$(($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)))
		if [[ "$cache_age" -lt "$ttl_secs" ]]; then
			echo "[pulse-wrapper] dep-graph-cache: cache fresh (${cache_age}s < ${ttl_secs}s TTL), skipping rebuild" >>"$LOGFILE"
			return 0
		fi
	fi

	echo "[pulse-wrapper] dep-graph-cache: building dependency graph cache (t1935)" >>"$LOGFILE"
	local build_start
	build_start=$(date +%s)

	local repos_json
	repos_json=$(jq -c '.initialized_repos[] | select(.pulse == true and (.local_only != true))' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || repos_json=""
	if [[ -z "$repos_json" ]]; then
		echo "[pulse-wrapper] dep-graph-cache: no pulse repos found, skipping" >>"$LOGFILE"
		return 0
	fi

	# Build the graph JSON incrementally
	local graph_json
	graph_json=$(printf '{"built_at":"%s","repos":{}}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

	while IFS= read -r repo_entry; do
		[[ -n "$repo_entry" ]] || continue
		local slug
		slug=$(printf '%s' "$repo_entry" | jq -r '.slug // empty' 2>/dev/null)
		[[ -n "$slug" ]] || continue

		# Fetch all open issues with their bodies in one API call
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open --limit 200 \
			--json number,title,body,labels 2>/dev/null) || issues_json='[]'

		local open_nums task_to_issue blocked_by_map defer_flags_map
		open_nums='[]'
		task_to_issue='{}'
		blocked_by_map='{}'
		defer_flags_map='{}'

		# Parse each issue: extract open issue numbers, task→issue mapping, and blocked-by refs
		while IFS= read -r issue_json; do
			[[ -n "$issue_json" ]] || continue
			local num title body
			num=$(printf '%s' "$issue_json" | jq -r '.number // empty' 2>/dev/null)
			title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null)
			body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null)
			[[ "$num" =~ ^[0-9]+$ ]] || continue

			# Accumulate open issue numbers
			local _new_open_nums
			_new_open_nums=$(printf '%s' "$open_nums" | jq --argjson n "$num" '. + [$n]' 2>/dev/null) || _new_open_nums=""
			[[ -n "$_new_open_nums" ]] && open_nums="$_new_open_nums"

			# Extract task ID from title (e.g. "t1935: ..." → "1935")
			local task_id_in_title
			task_id_in_title=$(printf '%s' "$title" | grep -oE '^t([0-9]+):' | grep -oE '[0-9]+' || true)
			if [[ -n "$task_id_in_title" ]]; then
				task_to_issue=$(printf '%s' "$task_to_issue" |
					jq --arg tid "$task_id_in_title" --argjson n "$num" '.[$tid] = $n' 2>/dev/null) || true
			fi

			# Extract blocked-by task IDs and issue numbers from body.
			# Two-step parse tolerates both the markdown format emitted by
			# brief-template.md (`**Blocked by:** ` + backtick-quoted IDs) and
			# the bare TODO.md format (`blocked-by:tNNN,tMMM`). The first step
			# locates every blocked-by line; the second step pulls every tNNN
			# and #NNN token from those lines. This captures comma-separated
			# IDs that the original single-match regex silently dropped (t2015,
			# GH#18429). Uses POSIX `[^[:cntrl:]]` rather than `[^\n]` because
			# BSD grep on macOS does not expand \n inside bracket expressions
			# (same class of bug as t1983 BSD awk).
			local blocker_lines blocker_tids blocker_nums
			blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
			blocker_tids=$(printf '%s' "$blocker_lines" | grep -oE 't[0-9]+' | grep -oE '[0-9]+' || true)
			blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)

			# Body defer/hold marker detection (t2031). A `status:blocked`
			# label may have been applied for reasons other than the
			# blocked-by chain — most commonly a human-imposed hold phrased
			# in the issue body like "Defer until X" or "On hold". The
			# refresh routine must not auto-unblock these. We record a
			# boolean flag per issue that the refresh consults before
			# removing the label.
			local has_defer_marker="false"
			if printf '%s' "$body" | grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]'; then
				has_defer_marker="true"
				defer_flags_map=$(printf '%s' "$defer_flags_map" |
					jq --arg n "$num" '.[$n] = true' 2>/dev/null) || true
			fi

			if [[ -n "$blocker_tids" || -n "$blocker_nums" ]]; then
				local tid_arr num_arr
				tid_arr=$(printf '%s' "$blocker_tids" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null) || tid_arr='[]'
				num_arr=$(printf '%s' "$blocker_nums" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null) || num_arr='[]'
				blocked_by_map=$(printf '%s' "$blocked_by_map" |
					jq --arg n "$num" --argjson tids "$tid_arr" --argjson nums "$num_arr" --argjson defer "$has_defer_marker" \
						'.[$n] = {"task_ids": $tids, "issue_nums": $nums, "has_defer_marker": $defer}' 2>/dev/null) || true
			fi
		done < <(printf '%s' "$issues_json" | jq -c '.[]' 2>/dev/null)

		# Merge repo data into graph
		graph_json=$(printf '%s' "$graph_json" |
			jq --arg slug "$slug" \
				--argjson open "$open_nums" \
				--argjson t2i "$task_to_issue" \
				--argjson bb "$blocked_by_map" \
				--argjson df "$defer_flags_map" \
				'.repos[$slug] = {"open_issues": $open, "task_to_issue": $t2i, "blocked_by": $bb, "defer_flags": $df}' \
				2>/dev/null) || true

	done <<<"$repos_json"

	# Atomically write cache (write to tmp then mv)
	local tmp_file
	tmp_file="${cache_file}.tmp.$$"
	mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
	if printf '%s\n' "$graph_json" >"$tmp_file"; then
		mv "$tmp_file" "$cache_file" || rm -f "$tmp_file"
	else
		rm -f "$tmp_file"
	fi

	local build_end build_dur
	build_end=$(date +%s)
	build_dur=$((build_end - build_start))
	echo "[pulse-wrapper] dep-graph-cache: built in ${build_dur}s → ${cache_file}" >>"$LOGFILE"
	return 0
}

#######################################
# Non-dep-block comment markers (t2031)
#
# Patterns that indicate `status:blocked` was applied for a reason other
# than the blocked-by chain. When any of these markers appears in recent
# comments, the refresh routine must NOT auto-unblock — removing the
# label would discard worker/watchdog/human evidence and waste cycles on
# a guaranteed re-BLOCKED dispatch.
#
# Sources:
#   - `**BLOCKED**.*cannot proceed` — worker exit BLOCKED with evidence
#   - `Worker Watchdog Kill`        — watchdog thrash kill (zero-commit loops)
#   - `Terminal blocker detected`   — pulse-dispatch-core._apply_terminal_blocker
#   - `ACTION REQUIRED`             — supervisor-posted human-action escalation
#   - `HUMAN_UNBLOCK_REQUIRED`      — explicit machine-readable hold marker
#######################################
_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS='\*\*BLOCKED\*\*.*cannot proceed|Worker Watchdog Kill|Terminal blocker detected|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED'

#######################################
# Decide whether to defer auto-unblock for an issue (t2031)
#
# Conservative gate for `refresh_blocked_status_from_graph`. An issue with
# a resolved blocked-by chain should still NOT be auto-unblocked when the
# `status:blocked` label was applied for another reason (worker BLOCKED
# exit, watchdog thrash kill, terminal blocker, manual human hold). Those
# origins leave evidence that auto-unblock would silently discard,
# producing repeat BLOCKED dispatches.
#
# Two signals:
#   (a) Defer/hold marker in the issue body (cached, zero API cost).
#   (b) Non-dep BLOCKED markers in the 10 most recent comments (one API
#       call per unblock candidate — candidates are rare, cost is fine).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
#   $3 - cached defer flag ("true" or "false" from build time)
#
# Output (stdout):
#   A short machine-readable reason token when the refresh should defer
#   ("body-defer" or "comment-marker"). Empty string when safe to unblock.
#
# Exit codes:
#   0 - defer (do NOT auto-unblock); reason printed to stdout
#   1 - safe to unblock (no signal)
#######################################
_should_defer_auto_unblock() {
	local repo_slug="$1"
	local issue_num="$2"
	local has_defer_flag="$3"

	# (a) Body defer marker — cached at build time, free to consult.
	if [[ "$has_defer_flag" == "true" ]]; then
		printf 'body-defer\n'
		return 0
	fi

	# (b) Non-dep BLOCKED markers in recent comments. Single API call per
	# candidate; unblock candidates are rare (typical cycle: 0-5 across all
	# repos), so the cost is well-bounded. Silently tolerate fetch failures
	# (fail-open on API error → behave as before, preserving the t1935
	# auto-unblock path when network is flaky).
	local recent_bodies=""
	recent_bodies=$(gh issue view "$issue_num" --repo "$repo_slug" \
		--json comments --jq '[.comments[-10:][] | .body] | join("\n---\n")' \
		2>/dev/null) || recent_bodies=""

	if [[ -n "$recent_bodies" ]]; then
		if printf '%s' "$recent_bodies" | grep -qE "$_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS"; then
			printf 'comment-marker\n'
			return 0
		fi
	fi

	return 1
}

#######################################
# Refresh blocked status from dependency graph (t1935, hardened t2031)
#
# Reads the cached dependency graph and relabels issues from
# status:blocked → status:available when all their blockers are closed.
# Runs once per cycle with zero API calls for the resolution check
# (the graph already contains open issue numbers).
#
# t2031 hardening: before removing the label, consults
# _should_defer_auto_unblock() to skip issues whose block origin is
# clearly non-dep (body defer gate, worker BLOCKED exit, watchdog kill,
# terminal blocker, human hold). The old behaviour — blindly unblocking
# on dep resolution — wasted worker budget on guaranteed-re-BLOCKED
# dispatches (awardsapp#2273 / aidevops t2031).
#
# Returns: 0 always (non-fatal)
#######################################
refresh_blocked_status_from_graph() {
	local cache_file="$DEP_GRAPH_CACHE_FILE"

	if [[ ! -f "$cache_file" ]]; then
		echo "[pulse-wrapper] dep-graph-cache: no cache file, skipping blocked-status refresh" >>"$LOGFILE"
		return 0
	fi

	local graph_json
	graph_json=$(cat "$cache_file" 2>/dev/null) || return 0
	[[ -n "$graph_json" ]] || return 0

	local unblocked_count=0

	# Iterate repos in the graph
	local slugs
	slugs=$(printf '%s' "$graph_json" | jq -r '.repos | keys[]' 2>/dev/null) || slugs=""
	[[ -n "$slugs" ]] || return 0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local repo_data open_issues_json task_to_issue_json blocked_by_json defer_flags_json
		repo_data=$(printf '%s' "$graph_json" | jq -c --arg s "$slug" '.repos[$s]' 2>/dev/null) || continue
		open_issues_json=$(printf '%s' "$repo_data" | jq -c '.open_issues // []' 2>/dev/null) || open_issues_json='[]'
		task_to_issue_json=$(printf '%s' "$repo_data" | jq -c '.task_to_issue // {}' 2>/dev/null) || task_to_issue_json='{}'
		blocked_by_json=$(printf '%s' "$repo_data" | jq -c '.blocked_by // {}' 2>/dev/null) || blocked_by_json='{}'
		defer_flags_json=$(printf '%s' "$repo_data" | jq -c '.defer_flags // {}' 2>/dev/null) || defer_flags_json='{}'

		# For each issue that has blocked-by entries, check if all blockers are resolved
		local blocked_issue_nums
		blocked_issue_nums=$(printf '%s' "$blocked_by_json" | jq -r 'keys[]' 2>/dev/null) || blocked_issue_nums=""
		[[ -n "$blocked_issue_nums" ]] || continue

		while IFS= read -r issue_num; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			local entry_json
			entry_json=$(printf '%s' "$blocked_by_json" | jq -c --arg n "$issue_num" '.[$n]' 2>/dev/null) || continue

			local all_resolved=true

			# Check task ID blockers against task_to_issue map + open_issues
			local blocker_tids
			blocker_tids=$(printf '%s' "$entry_json" | jq -r '.task_ids[]' 2>/dev/null) || blocker_tids=""
			while IFS= read -r tid; do
				[[ -n "$tid" ]] || continue
				local blocker_issue_num
				blocker_issue_num=$(printf '%s' "$task_to_issue_json" | jq -r --arg t "$tid" '.[$t] // empty' 2>/dev/null)
				if [[ -n "$blocker_issue_num" ]]; then
					# Check if blocker issue is in open_issues list
					local is_open
					is_open=$(printf '%s' "$open_issues_json" | jq --argjson n "$blocker_issue_num" 'index($n) != null' 2>/dev/null) || is_open="false"
					if [[ "$is_open" == "true" ]]; then
						all_resolved=false
						break
					fi
				fi
				# If task not in map, assume resolved (issue may have been closed and pruned)
			done <<<"$blocker_tids"

			# Check issue number blockers against open_issues
			if [[ "$all_resolved" == "true" ]]; then
				local blocker_nums
				blocker_nums=$(printf '%s' "$entry_json" | jq -r '.issue_nums[]' 2>/dev/null) || blocker_nums=""
				while IFS= read -r bnum; do
					[[ "$bnum" =~ ^[0-9]+$ ]] || continue
					local is_open
					is_open=$(printf '%s' "$open_issues_json" | jq --argjson n "$bnum" 'index($n) != null' 2>/dev/null) || is_open="false"
					if [[ "$is_open" == "true" ]]; then
						all_resolved=false
						break
					fi
				done <<<"$blocker_nums"
			fi

			# If all blockers resolved, consider relabeling status:blocked → status:available.
			# t2031: gate the unblock behind _should_defer_auto_unblock to respect
			# non-dep block origins (body defer, worker BLOCKED, watchdog, terminal).
			if [[ "$all_resolved" == "true" ]]; then
				# Verify the issue actually has status:blocked before making API call
				local current_labels
				current_labels=$(gh issue view "$issue_num" --repo "$slug" \
					--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
				if [[ ",${current_labels}," == *",status:blocked,"* ]]; then
					# Look up cached defer flag. Two places: either inside the
					# blocked_by entry (has_defer_marker) or in the top-level
					# defer_flags map (belt-and-braces for issues that may have
					# been bucketed differently). Either "true" triggers defer.
					local entry_defer top_defer has_defer_flag
					entry_defer=$(printf '%s' "$entry_json" | jq -r '.has_defer_marker // false' 2>/dev/null) || entry_defer="false"
					top_defer=$(printf '%s' "$defer_flags_json" | jq -r --arg n "$issue_num" '.[$n] // false' 2>/dev/null) || top_defer="false"
					has_defer_flag="false"
					if [[ "$entry_defer" == "true" || "$top_defer" == "true" ]]; then
						has_defer_flag="true"
					fi

					local skip_reason=""
					if skip_reason=$(_should_defer_auto_unblock "$slug" "$issue_num" "$has_defer_flag"); then
						echo "[pulse-wrapper] dep-graph-cache: NOT unblocking #${issue_num} in ${slug} — non-dep block detected (${skip_reason}) (t2031)" >>"$LOGFILE"
					else
						gh issue edit "$issue_num" --repo "$slug" \
							--remove-label "status:blocked" --add-label "status:available" 2>/dev/null || true
						echo "[pulse-wrapper] dep-graph-cache: unblocked #${issue_num} in ${slug} — all blockers resolved, no non-dep markers (t1935/t2031)" >>"$LOGFILE"
						unblocked_count=$((unblocked_count + 1))
					fi
				fi
			fi
		done <<<"$blocked_issue_nums"
	done <<<"$slugs"

	if [[ "$unblocked_count" -gt 0 ]]; then
		echo "[pulse-wrapper] dep-graph-cache: refresh complete — unblocked ${unblocked_count} issue(s) (t1935)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Blocked-by enforcement (t1927, enhanced t1935)
#
# Parses the issue body for blocked-by dependencies and checks whether
# the blocking task/issue is still open. Uses the cached dependency graph
# (built once per cycle) for zero-API-call resolution. Falls back to live
# API calls only when the cache is absent or the blocker is not found in it.
#
# Patterns matched:
#   - "blocked-by:tNNN" or "blocked-by: tNNN" (TODO.md format)
#   - "Blocked by tNNN" or "blocked by tNNN" (prose in issue body)
#   - "blocked-by:#NNN" (GitHub issue reference)
#
# Args:
#   $1 - issue body text
#   $2 - repo slug (owner/repo)
#   $3 - issue number (for logging)
# Returns:
#   exit 0 = blocker is unresolved (do NOT dispatch)
#   exit 1 = no blocker or blocker is resolved (safe to dispatch)
#######################################
is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"

	[[ -n "$issue_body" ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	# Extract blocked-by references from the issue body.
	# Match patterns: blocked-by:tNNN, blocked-by: tNNN, Blocked by tNNN,
	# blocked-by:#NNN, blocked by #NNN
	local blocker_task_ids blocker_issue_nums
	blocker_task_ids=$(printf '%s' "$issue_body" | grep -ioE '[Bb]locked[- ]by[: ]*t([0-9]+)' | grep -oE '[0-9]+' || true)
	blocker_issue_nums=$(printf '%s' "$issue_body" | grep -ioE '[Bb]locked[- ]by[: ]*#([0-9]+)' | grep -oE '[0-9]+' || true)

	# No blocked-by references → not blocked
	if [[ -z "$blocker_task_ids" && -z "$blocker_issue_nums" ]]; then
		return 1
	fi

	# Attempt cache-based resolution (t1935): read the dependency graph cache
	# built once per cycle. If the cache is present and fresh, use it to
	# resolve blocker state without any API calls.
	local cache_file="$DEP_GRAPH_CACHE_FILE"
	local use_cache=false
	local graph_json="" open_issues_json="" task_to_issue_json=""

	if [[ -f "$cache_file" ]]; then
		local cache_age
		cache_age=$(($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)))
		# Accept cache up to 2× TTL to tolerate slow rebuild cycles
		if [[ "$cache_age" -lt $((DEP_GRAPH_CACHE_TTL_SECS * 2)) ]]; then
			graph_json=$(cat "$cache_file" 2>/dev/null) || graph_json=""
			if [[ -n "$graph_json" ]]; then
				open_issues_json=$(printf '%s' "$graph_json" |
					jq -c --arg s "$repo_slug" '.repos[$s].open_issues // []' 2>/dev/null) || open_issues_json='[]'
				task_to_issue_json=$(printf '%s' "$graph_json" |
					jq -c --arg s "$repo_slug" '.repos[$s].task_to_issue // {}' 2>/dev/null) || task_to_issue_json='{}'
				use_cache=true
			fi
		fi
	fi

	# Check task ID blockers
	if [[ -n "$blocker_task_ids" ]]; then
		while IFS= read -r task_id; do
			[[ -n "$task_id" ]] || continue

			if [[ "$use_cache" == "true" ]]; then
				# Cache path: look up task→issue mapping, then check open_issues
				local blocker_issue_num
				blocker_issue_num=$(printf '%s' "$task_to_issue_json" |
					jq -r --arg t "$task_id" '.[$t] // empty' 2>/dev/null)
				if [[ -n "$blocker_issue_num" ]]; then
					local is_open
					is_open=$(printf '%s' "$open_issues_json" |
						jq --argjson n "$blocker_issue_num" 'index($n) != null' 2>/dev/null) || is_open="false"
					if [[ "$is_open" == "true" ]]; then
						echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by t${task_id}=#${blocker_issue_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
						return 0
					fi
					# Blocker issue found in map but not in open list → resolved
					continue
				fi
				# Task not in map → fall through to live API (may be a new issue)
			fi

			# Live API fallback: search for an open issue with this task ID in the title
			local blocker_state
			blocker_state=$(gh issue list --repo "$repo_slug" --state open \
				--search "t${task_id} in:title" --json number,state --jq '.[0].state // ""' 2>/dev/null) || blocker_state=""
			if [[ "$blocker_state" == "OPEN" ]]; then
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by t${task_id} (live: open) — skipping dispatch (t1927)" >>"$LOGFILE"
				return 0
			fi
		done <<<"$blocker_task_ids"
	fi

	# Check GitHub issue number blockers
	if [[ -n "$blocker_issue_nums" ]]; then
		while IFS= read -r blocker_num; do
			[[ -n "$blocker_num" ]] || continue

			if [[ "$use_cache" == "true" ]]; then
				# Cache path: check if blocker_num is in open_issues list
				local is_open
				is_open=$(printf '%s' "$open_issues_json" |
					jq --argjson n "$blocker_num" 'index($n) != null' 2>/dev/null) || is_open="false"
				if [[ "$is_open" == "true" ]]; then
					echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
					return 0
				fi
				# Not in open list → resolved (closed or never existed)
				continue
			fi

			# Live API fallback
			local blocker_state
			blocker_state=$(gh issue view "$blocker_num" --repo "$repo_slug" \
				--json state --jq '.state // ""' 2>/dev/null) || blocker_state=""
			if [[ "$blocker_state" == "OPEN" ]]; then
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (live: open) — skipping dispatch (t1927)" >>"$LOGFILE"
				return 0
			fi
		done <<<"$blocker_issue_nums"
	fi

	return 1
}
