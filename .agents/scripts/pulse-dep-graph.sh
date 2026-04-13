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
# Body defer/hold marker detection (t2031)
#
# A `status:blocked` label may have been applied for reasons other than
# the blocked-by chain — most commonly a human-imposed hold phrased in
# the issue body like "Defer until X" or "On hold". The refresh routine
# must not auto-unblock those. This helper runs at cache build time and
# at assertion time in the regression test; keep the regex in sync
# across both copies.
#
# Arguments: $1 - issue body text
# Outputs:   "true" or "false" on stdout
#######################################
_body_has_defer_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]'; then
		echo "true"
	else
		echo "false"
	fi
}

#######################################
# Parse a single issue for the dep-graph cache (t2031 refactor)
#
# Consumes one issue JSON blob (from `gh issue list --json
# number,title,body,labels`) and the current per-repo accumulator state,
# and emits updated accumulator state. Extracted from
# build_dependency_graph_cache so that function stays under the 100-line
# complexity gate.
#
# Arguments:
#   $1 - issue JSON (single object)
#   $2 - current accumulator JSON (compact object with keys:
#        open_nums, task_to_issue, blocked_by_map, defer_flags_map)
#
# Output: a single compact JSON object with the updated accumulator.
# If the input issue JSON is invalid or missing a number, emits the
# input accumulator unchanged.
#######################################
_dep_graph_process_issue_json() {
	local issue_json="$1"
	local acc_json="$2"

	local num title body
	num=$(printf '%s' "$issue_json" | jq -r '.number // empty' 2>/dev/null)
	title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null)
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null)

	if ! [[ "$num" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$acc_json"
		return 0
	fi

	# Extract task ID from title (e.g. "t1935: ..." → "1935")
	local task_id_in_title
	task_id_in_title=$(printf '%s' "$title" | grep -oE '^t([0-9]+):' | grep -oE '[0-9]+' || true)

	# Extract blocked-by task IDs and issue numbers from body. Two-step
	# parse tolerates both the markdown format emitted by
	# brief-template.md (`**Blocked by:** ` + backtick-quoted IDs) and
	# the bare TODO.md format (`blocked-by:tNNN,tMMM`). BSD/GNU portable
	# via POSIX `[^[:cntrl:]]` (see t1983 / t2015 for history).
	local blocker_lines blocker_tids blocker_nums
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	blocker_tids=$(printf '%s' "$blocker_lines" | grep -oE 't[0-9]+' | grep -oE '[0-9]+' || true)
	blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)

	local tid_arr num_arr
	tid_arr=$(printf '%s' "$blocker_tids" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || tid_arr='[]'
	num_arr=$(printf '%s' "$blocker_nums" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || num_arr='[]'
	local has_blockers="false"
	[[ -n "$blocker_tids" || -n "$blocker_nums" ]] && has_blockers="true"

	# Body defer/hold marker detection (t2031).
	local has_defer_marker
	has_defer_marker=$(_body_has_defer_marker "$body")

	# Single jq call merges every accumulator update in one pass.
	# Keeps the shell shorter and guarantees compact single-line output.
	printf '%s' "$acc_json" | jq -c \
		--argjson n "$num" \
		--arg tid "$task_id_in_title" \
		--argjson tids "$tid_arr" \
		--argjson nums "$num_arr" \
		--arg has_blockers "$has_blockers" \
		--argjson defer "$has_defer_marker" \
		'
		.open_nums = (.open_nums + [$n])
		| (if $tid != "" then .task_to_issue[$tid] = $n else . end)
		| (if $has_blockers == "true"
			then .blocked_by_map[($n | tostring)] = {"task_ids": $tids, "issue_nums": $nums, "has_defer_marker": $defer}
			else . end)
		| (if $defer == true
			then .defer_flags_map[($n | tostring)] = true
			else . end)
		' 2>/dev/null || printf '%s\n' "$acc_json"
}

#######################################
# Build per-repo dep graph data (t2031 refactor, GH#18593 perf)
#
# Fetches all open issues for one repo slug and produces the per-repo
# dep-graph cache object in a single jq call instead of spawning a
# subshell per issue. This collapses O(n * ~13) process forks down to
# O(1) per repo, which is significant for repos with 200+ open issues.
#
# The jq program replicates the logic of _dep_graph_process_issue_json:
#   - task ID extraction from title (^tNNN: prefix)
#   - blocked-by line detection and tID/issueNum extraction
#   - defer/hold marker detection (same patterns as _body_has_defer_marker)
#
# _dep_graph_process_issue_json is retained for unit testing and as a
# reference implementation.
#
# Arguments: $1 - repo slug (owner/repo)
# Output:    one JSON object on stdout
#######################################
_dep_graph_build_repo_data() {
	local slug="$1"
	local issues_json
	issues_json=$(gh issue list --repo "$slug" --state open --limit 200 \
		--json number,title,body,labels 2>/dev/null) || issues_json='[]'

	# Single jq pass: extract all fields, apply regex, build accumulator.
	# Equivalent to calling _dep_graph_process_issue_json once per issue
	# but without spawning a subshell for each issue.
	printf '%s' "$issues_json" | jq -c '
		reduce .[] as $issue (
			{"open_nums":[],"task_to_issue":{},"blocked_by_map":{},"defer_flags_map":{}};
			($issue.number) as $num |
			($issue.title // "") as $title |
			($issue.body // "") as $body |

			# Extract task ID from title (e.g. "t1935: ..." -> "1935")
			(if ($title | test("^t[0-9]+:"))
			 then ($title | capture("^t(?<id>[0-9]+):").id)
			 else ""
			 end) as $tid |

			# Extract all lines matching the blocked-by pattern (case-insensitive)
			([$body | split("\n") | .[] | select(test("(?i)blocked[- ]by"))] | join(" ")) as $blocker_text |

			# Extract tNNN task IDs from blocked-by text (capture group -> number only)
			([$blocker_text | scan("t([0-9]+)") | .[0]] | unique) as $blocker_tids |

			# Extract #NNN issue numbers from blocked-by text (capture group -> number only)
			([$blocker_text | scan("#([0-9]+)") | .[0]] | unique) as $blocker_nums |

			# Defer/hold marker detection (mirrors _body_has_defer_marker shell patterns)
			($body | test("(?i)defer until|do[- ]not[- ]dispatch|on[- ]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]")) as $has_defer |

			(($blocker_tids | length) > 0 or ($blocker_nums | length) > 0) as $has_blockers |

			.open_nums += [$num]
			| (if $tid != "" then .task_to_issue[$tid] = $num else . end)
			| (if $has_blockers
			   then .blocked_by_map[($num | tostring)] = {
			       "task_ids": $blocker_tids,
			       "issue_nums": $blocker_nums,
			       "has_defer_marker": $has_defer
			   }
			   else . end)
			| (if $has_defer then .defer_flags_map[($num | tostring)] = true else . end)
		)
		| {
			"open_issues": .open_nums,
			"task_to_issue": .task_to_issue,
			"blocked_by": .blocked_by_map,
			"defer_flags": .defer_flags_map
		}
	' 2>/dev/null || printf '{"open_issues":[],"task_to_issue":{},"blocked_by":{},"defer_flags":{}}\n'
}

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

		# Delegate the per-repo fetch + parse to _dep_graph_build_repo_data
		# (t2031 refactor — keeps build_dependency_graph_cache under the
		# 100-line complexity gate).
		local repo_data
		repo_data=$(_dep_graph_build_repo_data "$slug")
		[[ -n "$repo_data" ]] || continue

		# Merge repo data into graph
		graph_json=$(printf '%s' "$graph_json" |
			jq --arg slug "$slug" --argjson rd "$repo_data" \
				'.repos[$slug] = $rd' 2>/dev/null) || true
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
# Check whether all blocked-by entries of a single cache entry are
# resolved (t2031 refactor helper).
#
# Arguments:
#   $1 - entry_json (blocked_by cache entry for one issue)
#   $2 - task_to_issue_json (repo-level task→issue mapping)
#   $3 - open_issues_json (repo-level open issue numbers)
#
# Exit codes:
#   0 - all blockers resolved
#   1 - at least one blocker still open
#######################################
_refresh_all_blockers_resolved() {
	local entry_json="$1"
	local task_to_issue_json="$2"
	local open_issues_json="$3"

	# Task ID blockers
	local blocker_tids tid blocker_issue_num is_open
	blocker_tids=$(printf '%s' "$entry_json" | jq -r '.task_ids[]' 2>/dev/null) || blocker_tids=""
	while IFS= read -r tid; do
		[[ -n "$tid" ]] || continue
		blocker_issue_num=$(printf '%s' "$task_to_issue_json" | jq -r --arg t "$tid" '.[$t] // empty' 2>/dev/null)
		[[ -n "$blocker_issue_num" ]] || continue
		is_open=$(printf '%s' "$open_issues_json" | jq --argjson n "$blocker_issue_num" 'index($n) != null' 2>/dev/null) || is_open="false"
		[[ "$is_open" == "true" ]] && return 1
	done <<<"$blocker_tids"

	# Issue number blockers
	local blocker_nums bnum
	blocker_nums=$(printf '%s' "$entry_json" | jq -r '.issue_nums[]' 2>/dev/null) || blocker_nums=""
	while IFS= read -r bnum; do
		[[ "$bnum" =~ ^[0-9]+$ ]] || continue
		is_open=$(printf '%s' "$open_issues_json" | jq --argjson n "$bnum" 'index($n) != null' 2>/dev/null) || is_open="false"
		[[ "$is_open" == "true" ]] && return 1
	done <<<"$blocker_nums"

	return 0
}

#######################################
# Attempt to auto-unblock a single issue (t2031 refactor helper).
#
# Consults the non-dep defer gate and only unblocks when both body and
# comments are clean. Extracted from refresh_blocked_status_from_graph
# so that function stays under the 100-line complexity gate.
#
# Arguments:
#   $1 - slug
#   $2 - issue_num
#   $3 - entry_json (blocked_by cache entry)
#   $4 - defer_flags_json (repo-level defer flags)
#
# Exit codes:
#   0 - issue unblocked (caller should increment counter)
#   1 - skipped (label absent, API error, or non-dep block detected)
#######################################
_refresh_try_unblock_issue() {
	local slug="$1"
	local issue_num="$2"
	local entry_json="$3"
	local defer_flags_json="$4"

	local current_labels
	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	[[ ",${current_labels}," == *",status:blocked,"* ]] || return 1

	# Cached defer flag — either inside the blocked_by entry or in the
	# repo-level defer_flags map. Either "true" triggers defer.
	local entry_defer top_defer has_defer_flag
	entry_defer=$(printf '%s' "$entry_json" | jq -r '.has_defer_marker // false' 2>/dev/null) || entry_defer="false"
	top_defer=$(printf '%s' "$defer_flags_json" | jq -r --arg n "$issue_num" '.[$n] // false' 2>/dev/null) || top_defer="false"
	has_defer_flag="false"
	[[ "$entry_defer" == "true" || "$top_defer" == "true" ]] && has_defer_flag="true"

	local skip_reason=""
	if skip_reason=$(_should_defer_auto_unblock "$slug" "$issue_num" "$has_defer_flag"); then
		echo "[pulse-wrapper] dep-graph-cache: NOT unblocking #${issue_num} in ${slug} — non-dep block detected (${skip_reason}) (t2031)" >>"$LOGFILE"
		return 1
	fi

	# t2033: atomic transition — clears all sibling status:* labels, not just status:blocked
	set_issue_status "$issue_num" "$slug" "available" 2>/dev/null || true
	echo "[pulse-wrapper] dep-graph-cache: unblocked #${issue_num} in ${slug} — all blockers resolved, no non-dep markers (t1935/t2031)" >>"$LOGFILE"
	return 0
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
# _should_defer_auto_unblock() via _refresh_try_unblock_issue() to skip
# issues whose block origin is clearly non-dep (body defer gate, worker
# BLOCKED exit, watchdog kill, terminal blocker, human hold). The old
# behaviour — blindly unblocking on dep resolution — wasted worker
# budget on guaranteed-re-BLOCKED dispatches (awardsapp#2273).
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

		local blocked_issue_nums
		blocked_issue_nums=$(printf '%s' "$blocked_by_json" | jq -r 'keys[]' 2>/dev/null) || blocked_issue_nums=""
		[[ -n "$blocked_issue_nums" ]] || continue

		local issue_num entry_json
		while IFS= read -r issue_num; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
			entry_json=$(printf '%s' "$blocked_by_json" | jq -c --arg n "$issue_num" '.[$n]' 2>/dev/null) || continue

			_refresh_all_blockers_resolved "$entry_json" "$task_to_issue_json" "$open_issues_json" || continue

			if _refresh_try_unblock_issue "$slug" "$issue_num" "$entry_json" "$defer_flags_json"; then
				unblocked_count=$((unblocked_count + 1))
			fi
		done <<<"$blocked_issue_nums"
	done <<<"$slugs"

	if [[ "$unblocked_count" -gt 0 ]]; then
		echo "[pulse-wrapper] dep-graph-cache: refresh complete — unblocked ${unblocked_count} issue(s) (t1935)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Extract blocked-by task IDs and issue numbers from an issue body.
#
# (GH#18693 refactor helper — keeps is_blocked_by_unresolved under 100 lines.)
#
# Patterns matched:
#   - "blocked-by:tNNN" or "blocked-by: tNNN" (TODO.md format)
#   - "Blocked by tNNN" or "blocked by tNNN" (prose)
#   - "blocked-by:#NNN" (GitHub issue reference)
#
# Arguments: $1 - issue body text
# Output:    two newline-separated lists on stdout, separated by a NUL:
#            <task_ids>\0<issue_nums>
#######################################
_blocked_by_extract_refs() {
	local body="$1"
	local tids nums
	tids=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ]by[: ]*t([0-9]+)' | grep -oE '[0-9]+' || true)
	nums=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ]by[: ]*#([0-9]+)' | grep -oE '[0-9]+' || true)
	printf '%s\0%s' "$tids" "$nums"
	return 0
}

#######################################
# Load cached dep-graph state for a repo (GH#18693 refactor helper).
#
# Reads DEP_GRAPH_CACHE_FILE (if present and within 2× TTL) and extracts
# the per-repo open_issues and task_to_issue maps. Emits a single compact
# JSON object on stdout with the three fields the resolver needs:
#   {"use_cache": bool, "open_issues": [...], "task_to_issue": {...}}
#
# Fails open — on any error emits use_cache:false so the caller falls
# through to live API resolution.
#
# Arguments: $1 - repo slug
# Output:    one JSON object on stdout
#######################################
_blocked_by_load_cache() {
	local repo_slug="$1"
	local cache_file="$DEP_GRAPH_CACHE_FILE"

	[[ -f "$cache_file" ]] || {
		printf '{"use_cache":false,"open_issues":[],"task_to_issue":{}}'
		return 0
	}

	local cache_age
	cache_age=$(($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)))
	# Accept cache up to 2× TTL to tolerate slow rebuild cycles
	if [[ "$cache_age" -ge $((DEP_GRAPH_CACHE_TTL_SECS * 2)) ]]; then
		printf '{"use_cache":false,"open_issues":[],"task_to_issue":{}}'
		return 0
	fi

	local graph_json
	graph_json=$(cat "$cache_file" 2>/dev/null) || graph_json=""
	if [[ -z "$graph_json" ]]; then
		printf '{"use_cache":false,"open_issues":[],"task_to_issue":{}}'
		return 0
	fi

	printf '%s' "$graph_json" | jq -c --arg s "$repo_slug" '{
		use_cache: true,
		open_issues: (.repos[$s].open_issues // []),
		task_to_issue: (.repos[$s].task_to_issue // {})
	}' 2>/dev/null || printf '{"use_cache":false,"open_issues":[],"task_to_issue":{}}'
	return 0
}

#######################################
# Resolve a single task-ID blocker to open/closed (GH#18693 refactor helper).
#
# Uses the cached dep graph first; falls back to a live `gh issue list`
# search when the task is not found in the cache.
#
# Arguments:
#   $1 - task_id (digits only)
#   $2 - repo slug
#   $3 - issue_number (for logging)
#   $4 - cache_state JSON (from _blocked_by_load_cache)
#
# Exit codes:
#   0 - blocker is open (caller should return "blocked")
#   1 - blocker is resolved or not found (caller should continue)
#######################################
_blocked_by_check_task_id() {
	local task_id="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local cache_state="$4"

	local use_cache
	use_cache=$(printf '%s' "$cache_state" | jq -r '.use_cache' 2>/dev/null || echo "false")

	if [[ "$use_cache" == "true" ]]; then
		local blocker_issue_num
		blocker_issue_num=$(printf '%s' "$cache_state" |
			jq -r --arg t "$task_id" '.task_to_issue[$t] // empty' 2>/dev/null)
		if [[ -n "$blocker_issue_num" ]]; then
			local is_open
			is_open=$(printf '%s' "$cache_state" |
				jq --argjson n "$blocker_issue_num" '.open_issues | index($n) != null' 2>/dev/null) || is_open="false"
			if [[ "$is_open" == "true" ]]; then
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by t${task_id}=#${blocker_issue_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
				return 0
			fi
			return 1
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
	return 1
}

#######################################
# Resolve a single GitHub issue-number blocker (GH#18693 refactor helper).
#
# Arguments:
#   $1 - blocker_num
#   $2 - repo slug
#   $3 - issue_number (for logging)
#   $4 - cache_state JSON (from _blocked_by_load_cache)
#
# Exit codes:
#   0 - blocker is open
#   1 - blocker is resolved or not found
#######################################
_blocked_by_check_issue_num() {
	local blocker_num="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local cache_state="$4"

	local use_cache
	use_cache=$(printf '%s' "$cache_state" | jq -r '.use_cache' 2>/dev/null || echo "false")

	if [[ "$use_cache" == "true" ]]; then
		local is_open
		is_open=$(printf '%s' "$cache_state" |
			jq --argjson n "$blocker_num" '.open_issues | index($n) != null' 2>/dev/null) || is_open="false"
		if [[ "$is_open" == "true" ]]; then
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
			return 0
		fi
		return 1
	fi

	# Live API fallback
	local blocker_state
	blocker_state=$(gh issue view "$blocker_num" --repo "$repo_slug" \
		--json state --jq '.state // ""' 2>/dev/null) || blocker_state=""
	if [[ "$blocker_state" == "OPEN" ]]; then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (live: open) — skipping dispatch (t1927)" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Blocked-by enforcement (t1927, enhanced t1935, decomposed GH#18693)
#
# Parses the issue body for blocked-by dependencies and checks whether the
# blocking task/issue is still open. Uses the cached dependency graph (built
# once per cycle) for zero-API-call resolution. Falls back to live API calls
# only when the cache is absent or the blocker is not found in it.
#
# Decomposed into _blocked_by_extract_refs, _blocked_by_load_cache,
# _blocked_by_check_task_id, and _blocked_by_check_issue_num so this outer
# orchestrator stays under the 100-line complexity gate.
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

	# Extract blocked-by references (tNNN and #NNN).
	local refs blocker_task_ids blocker_issue_nums
	refs=$(_blocked_by_extract_refs "$issue_body")
	blocker_task_ids="${refs%%$'\0'*}"
	blocker_issue_nums="${refs#*$'\0'}"

	# No blocked-by references → not blocked
	if [[ -z "$blocker_task_ids" && -z "$blocker_issue_nums" ]]; then
		return 1
	fi

	# Load cache state once for this repo (one JSON object the helpers consume).
	local cache_state
	cache_state=$(_blocked_by_load_cache "$repo_slug")

	# Check task ID blockers
	if [[ -n "$blocker_task_ids" ]]; then
		local task_id
		while IFS= read -r task_id; do
			[[ -n "$task_id" ]] || continue
			if _blocked_by_check_task_id "$task_id" "$repo_slug" "$issue_number" "$cache_state"; then
				return 0
			fi
		done <<<"$blocker_task_ids"
	fi

	# Check GitHub issue number blockers
	if [[ -n "$blocker_issue_nums" ]]; then
		local blocker_num
		while IFS= read -r blocker_num; do
			[[ -n "$blocker_num" ]] || continue
			if _blocked_by_check_issue_num "$blocker_num" "$repo_slug" "$issue_number" "$cache_state"; then
				return 0
			fi
		done <<<"$blocker_issue_nums"
	fi

	return 1
}
