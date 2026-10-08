#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Relationships — Node ID Cache and GitHub GraphQL Mutations
# =============================================================================
# Node ID caching, addBlockedBy/removeBlockedBy/addSubIssue GraphQL mutations,
# dependency status normalization, and declared-edge graph helpers for
# issue-sync-relationships.sh.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships-gh.sh"
#
# Dependencies (all available when sourced from issue-sync-relationships.sh):
#   - shared-constants.sh (print_error, print_info, log_verbose)
#   - issue-sync-lib.sh (resolve_gh_node_id, strip_code_fences, parse_task_line,
#     task_identity_validate)
#   - issue-sync-relationships-state.sh (_relationship_record_outcome,
#     _relationship_record_diagnostic, _relationship_record_mutation_failure,
#     _end_relationship_sync_scope)
#   - issue-sync-relationship-batch.sh (_relationship_run_timed,
#     _gh_native_blocked_by_contains, _gh_native_sub_issue_contains,
#     _relationship_native_cache_invalidate, _relationship_status_was_synced,
#     _relationship_mark_status_synced, _relationship_apply_planned_batches)
#
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_GH_LIB_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_GH_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_init_node_id_cache() {
	if [[ -z "$_NODE_ID_CACHE_FILE" ]]; then
		_NODE_ID_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-node-cache.XXXXXX")
		_NODE_ID_RATE_LIMITED_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-ratelimited.XXXXXX")
		# Chain onto any existing EXIT trap rather than replacing it.
		local _prev_trap
		_prev_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
		# shellcheck disable=SC2064
		trap "rm -f '$_NODE_ID_CACHE_FILE' '$_NODE_ID_RATE_LIMITED_FILE'${_prev_trap:+; $_prev_trap}" EXIT
	fi
	return 0
}

# Return 0 (true) if the most recent _cached_node_id call was rate-limited.
# Reads the flag file written by the subshell — bash variables set inside $()
# are discarded when the subshell exits, but file writes persist.
_node_id_was_rate_limited() {
	[[ -n "${_NODE_ID_RATE_LIMITED_FILE:-}" ]] && \
		[[ "$(cat "$_NODE_ID_RATE_LIMITED_FILE" 2>/dev/null)" == "1" ]]
	return $?
}

_cached_node_id() {
	local num="$1" repo="$2"
	[[ -z "$num" ]] && return 0
	_init_node_id_cache
	# Reset the rate-limited flag for this resolution. Runs inside the subshell
	# spawned by callers' $() — the file truncation IS visible to the parent.
	[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && : >"$_NODE_ID_RATE_LIMITED_FILE"

	# Check cache file
	local cached
	cached=$(grep -m1 "^${num}=" "$_NODE_ID_CACHE_FILE" 2>/dev/null | cut -d= -f2- || echo "")
	if [[ -n "$cached" ]]; then
		echo "$cached"
		return 0
	fi

	local nid
	nid=$(resolve_gh_node_id "$num" "$repo")
	if [[ -n "$nid" ]]; then
		echo "${num}=${nid}" >>"$_NODE_ID_CACHE_FILE"
		echo "$nid"
		return 0
	fi

	# GraphQL returned empty. If rate-limited, try REST path (t2739).
	# REST: GET /repos/{owner}/{repo}/issues/{number} → .node_id
	# Uses the same core-pool 5000/hr budget that the t2574 write-path fallbacks use.
	if _rest_should_fallback; then
		local rest_nid
		rest_nid=$(_gh_with_timeout read gh api "/repos/${repo}/issues/${num}" --jq '.node_id // ""' 2>/dev/null || echo "")
		if [[ -n "$rest_nid" ]]; then
			echo "${num}=${rest_nid}" >>"$_NODE_ID_CACHE_FILE"
			echo "$rest_nid"
			return 0
		fi
		# Both GraphQL and REST failed — write flag so callers can emit RATE_LIMITED.
		[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && echo "1" >"$_NODE_ID_RATE_LIMITED_FILE"
	fi
	return 0
}

# Add a blocked-by relationship between two issues.
# issueId = the blocked issue, blockingIssueId = the blocker.
# Suppresses "already taken" errors (idempotent semantics).
# Arguments:
#   $1 - blocked_node_id (the issue that IS blocked)
#   $2 - blocking_node_id (the issue that BLOCKS)
# Returns: 0=success/already-exists, 1=error. The invocation ledger retains
# whether this call created, observed, failed, or deferred the edge.
_gh_add_blocked_by() {
	local blocked_id="$1" blocking_id="$2"
	local result="" contains_rc=0 mutation_rc=0
	_relationship_run_timed snapshot _gh_native_blocked_by_contains \
		"$blocked_id" "$blocking_id" || contains_rc=$?
	case "$contains_rc" in
		0)
			log_verbose "  blocked-by relationship already exists"
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
			return 0
			;;
		1) ;;
		*)
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			return 1
			;;
	esac
	# GitHub exposes rateLimit on Query, not Mutation. This fixed mutation has
	# no connections and consumes one GraphQL point, accounted at transport.
	# shellcheck disable=SC2016  # GraphQL $variables are literal query syntax
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-add-blocked-by-exact-cost" \
		_relationship_run_timed mutation _gh_with_timeout write gh api graphql -f query='
mutation($blocked:ID!,$blocking:ID!) {
  addBlockedBy(input: {issueId:$blocked, blockingIssueId:$blocking}) {
    issue { number }
  }
}' -f blocked="$blocked_id" -f blocking="$blocking_id" 2>&1) || mutation_rc=$?
	_relationship_native_cache_invalidate "$blocked_id" || true
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.addBlockedBy.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		_relationship_record_outcome "$_REL_OUTCOME_CREATED"
		return 0
	fi
	if echo "$result" | grep -qi 'already been taken'; then
		log_verbose "  blocked-by relationship already exists"
		_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
		return 0
	fi
	_relationship_record_mutation_failure "$mutation_rc" "$result"
	log_verbose "  addBlockedBy error: ${result:0:200}"
	return 1
}

# Remove a deterministic break edge from an already-materialized native cycle.
# Absence is idempotent success; lookup or mutation uncertainty remains retryable.
_gh_remove_blocked_by() {
	local blocked_id="$1"
	local blocking_id="$2"
	local contains_rc=0 mutation_rc=0 result=""
	_gh_native_blocked_by_contains "$blocked_id" "$blocking_id" || contains_rc=$?
	case "$contains_rc" in
		1) return 0 ;;
		2) return 1 ;;
	esac
	# shellcheck disable=SC2016  # GraphQL $variables are literal query syntax
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-remove-blocked-by-exact-cost" \
		_gh_with_timeout write gh api graphql -f query='
mutation($blocked:ID!,$blocking:ID!) {
  removeBlockedBy(input: {issueId:$blocked, blockingIssueId:$blocking}) {
    issue { number }
  }
}' -f blocked="$blocked_id" -f blocking="$blocking_id" 2>&1) || mutation_rc=$?
	_relationship_native_cache_invalidate "$blocked_id" || true
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.removeBlockedBy.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		return 0
	fi
	log_verbose "  removeBlockedBy error: ${result:0:200}"
	return 1
}

# Keep dependency status normalization from overwriting active lifecycle state.
_dependency_sync_has_active_status() {
	local labels_csv="$1"
	local padded_labels=",${labels_csv},"
	[[ "$padded_labels" == *",status:queued,"* ||
		"$padded_labels" == *",status:claimed,"* ||
		"$padded_labels" == *",status:in-progress,"* ||
		"$padded_labels" == *",status:in-review,"* ||
		"$padded_labels" == *",status:done,"* ]]
	return $?
}

_relationship_task_line() {
	local task_id="$1" todo_file="$2"
	_first_todo_task_line_or_empty "$task_id" "$todo_file" || return 1
	return 0
}

# GH#33957: positive proof that a dependency edge no longer blocks. Succeeds
# only when the native blockedBy page is complete and non-empty, contains the
# declared blocker (issue number in this repo, or node ID), and every native
# blocker is CLOSED. Any read failure, truncation or open blocker fails closed.
_dependency_native_blockers_closed_for() {
	local issue_num="$1"
	local repo="$2"
	local blocker_ref="$3"
	local owner="${repo%%/*}" name="${repo#*/}" result=""
	[[ "$issue_num" =~ ^[0-9]+$ && "$repo" == */* && -n "$blocker_ref" ]] || return 1
	# shellcheck disable=SC2016
	result=$(_relationship_run_timed status _gh_with_timeout read gh api graphql -f query='
query($o:String!,$r:String!,$n:Int!) {
  repository(owner:$o,name:$r) {
    issue(number:$n) {
      blockedBy(first:100) { nodes { id number state repository { nameWithOwner } } pageInfo { hasNextPage } }
    }
  }
}' -F o="$owner" -F r="$name" -F n="$issue_num" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -e --arg ref "$blocker_ref" --arg repo "$repo" '
      .data.repository.issue.blockedBy as $b
      | ($b | type) == "object"
        and $b.pageInfo.hasNextPage == false
        and ($b.nodes | type) == "array"
        and ($b.nodes | length) > 0
        and all($b.nodes[]; .state == "CLOSED")
        and any($b.nodes[]; .id == $ref
          or ((.number | tostring) == $ref and .repository.nameWithOwner == $repo))' >/dev/null 2>&1
	return $?
}

# Move an inactive dependency-bearing issue out of the available queue. This is
# intentionally label-only: auto-dispatch remains attached so Pulse can promote
# the issue after every native blocker closes. Callers that have just observed
# or created a native edge pass its blocker ($4); a verified closed edge then
# leaves the issue available so enrich cannot revert Pulse's unblock (GH#33957).
# Retry holds pass no blocker and still fail closed.
_ensure_dependency_status_blocked() {
	local issue_num="$1"
	local repo="$2"
	local reason="$3"
	local blocker_ref="${4:-}"
	local current_labels=""

	[[ "$issue_num" =~ ^[0-9]+$ && "$repo" == */* ]] || return 1
	_relationship_status_was_synced "$issue_num" && return 0
	current_labels=$(_relationship_run_timed status _gh_with_timeout read gh issue view "$issue_num" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || {
		log_verbose "$issue_num: dependency_status_sync_failed reason=${reason}_status_read_failed"
		return 1
	}
	if [[ ",${current_labels}," != *",status:available,"* ]] || \
		_dependency_sync_has_active_status "$current_labels"; then
		_relationship_mark_status_synced "$issue_num"
		return 0
	fi
	# Not marked synced: a later edge or retry hold for this issue must still
	# be able to block it in the same pass.
	if [[ -n "$blocker_ref" ]] && \
		_dependency_native_blockers_closed_for "$issue_num" "$repo" "$blocker_ref"; then
		log_verbose "$issue_num: dependency_status_unchanged reason=${reason}_native_blockers_closed"
		return 0
	fi
	if ! _relationship_run_timed status _gh_with_timeout write gh issue edit "$issue_num" --repo "$repo" \
		--remove-label "status:available" --add-label "status:blocked" >/dev/null 2>&1; then
		log_verbose "$issue_num: dependency_status_sync_failed reason=${reason}_status_write_failed"
		return 1
	fi
	# A dispatcher may have advanced state between the read and edit. Repair any
	# resulting sibling conflict immediately; active lifecycle state wins.
	current_labels=$(_relationship_run_timed status _gh_with_timeout read gh issue view "$issue_num" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	if _dependency_sync_has_active_status "$current_labels" && \
		[[ ",${current_labels}," == *",status:blocked,"* ]]; then
		_relationship_run_timed status _gh_with_timeout write gh issue edit "$issue_num" --repo "$repo" \
			--remove-label "status:blocked" >/dev/null 2>&1 || true
	fi
	_relationship_mark_status_synced "$issue_num"
	log_verbose "$issue_num: dependency_status_blocked reason=${reason}"
	return 0
}

# Keep a dependency-bearing issue out of the available queue when native
# relationship repair cannot complete. The next relationship pass can repair
# the edge, while Pulse supplies the positive proof required to unblock it.
_hold_dependency_sync_retry() {
	local issue_num="$1"
	local repo="$2"
	local reason="$3"
	if ! _ensure_dependency_status_blocked "$issue_num" "$repo" "$reason"; then
		log_verbose "$issue_num: dependency_relationship_sync_retryable reason=${reason}_status_sync_failed"
		return 1
	fi
	log_verbose "$issue_num: dependency_relationship_sync_retryable reason=${reason}"
	return 0
}

# Add a sub-issue (parent-child) relationship.
# Suppresses "duplicate sub-issues" and "only have one parent" errors.
# Emit the Cartesian product of blocked and blocker issue-number lists while
# rejecting self edges. Kept separate so the prose parser stays below the
# repository nesting-depth gate.
_emit_phase_dependency_pairs() {
	local blocked_nums="$1"
	local blocker_nums="$2"
	local blocked_num="" blocker_num=""
	while IFS= read -r blocked_num; do
		[[ -n "$blocked_num" ]] || continue
		while IFS= read -r blocker_num; do
			[[ -n "$blocker_num" && "$blocked_num" != "$blocker_num" ]] || continue
			printf 'PAIR:%s:%s\n' "$blocked_num" "$blocker_num"
		done <<<"$blocker_nums"
	done <<<"$blocked_nums"
	return 0
}

_RELATIONSHIP_EDGE_CACHE_FILE=""
_RELATIONSHIP_EDGE_CACHE=""

# A completed, noncanonical historical row cannot be parsed by the issue-sync
# codec. Only omit it when neither an active declaration nor its own blocks:
# marker connects it to active work. Compare whole IDs, never numeric aliases.
_relationship_active_ids_and_refs() {
	local stripped="$1"
	local task_line task_id key value ref
	_RELATIONSHIP_ACTIVE_IDS='|'
	_RELATIONSHIP_ACTIVE_REFS='|'
	while IFS= read -r task_line; do
		[[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]\>-]\][[:space:]]+(t[0-9]+(\.[0-9a-z]+)*)[[:space:]] ]] || continue
		task_id="${BASH_REMATCH[1]}"
		_RELATIONSHIP_ACTIVE_IDS+="${task_id}|"
		for key in blocked-by blocks; do
			if [[ "$task_line" =~ (^|[[:space:]])${key}:([^[:space:]]+) ]]; then
				value="${BASH_REMATCH[2]//,/ }"
				for ref in $value; do
					_RELATIONSHIP_ACTIVE_REFS+="${ref}|"
				done
			fi
		done
	done <<<"$stripped"
	return 0
}

_relationship_skip_completed_legacy_row() {
	local task_line="$1" task_id="$2"
	local ref value
	_warn_padded_task_line "$task_line"
	[[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[x\] ]] || return 1
	[[ "$task_id" =~ ^t[0-9]{1,18}(\.[0-9]{1,18}){0,8}$ ]] || return 1
	[[ "$_RELATIONSHIP_ACTIVE_REFS" != *"|${task_id}|"* ]] || {
		print_error "Active dependency references historical noncanonical task ID ${task_id}; migrate that reference without aliasing task IDs"
		return 1
	}
	if [[ "$task_line" =~ (^|[[:space:]])blocks:([^[:space:]]+) ]]; then
		value="${BASH_REMATCH[2]//,/ }"
		for ref in $value; do
			if [[ "$_RELATIONSHIP_ACTIVE_IDS" == *"|${ref}|"* ]]; then
				print_error "Historical noncanonical task ID ${task_id} blocks active task ${ref}; migrate the relationship without aliasing task IDs"
				return 1
			fi
		done
	fi
	return 0
}

# Report a dependency parse failure naming the row and invalid reference(s).
# Completed rows with historical noncanonical targets are skipped (return 0);
# open rows fail (return 1).
_relationship_report_parse_failure() {
	local task_line="$1"
	local task_id="$2"
	local key="" value="" ref="" invalid=""
	for key in blocked-by blocks; do
		value=""
		if [[ "$task_line" =~ (^|[[:space:]])${key}:([^[:space:]]+) ]]; then
			value="${BASH_REMATCH[2]}"
		fi
		[[ -n "$value" ]] || continue
		while IFS= read -r ref; do
			[[ "$ref" =~ ^(GH)?#[1-9][0-9]*$ ]] && continue
			task_identity_validate "$ref" && continue
			invalid="${invalid:+${invalid}, }${key}:${ref}"
		done < <(printf '%s\n' "$value" | tr ',' '\n')
	done
	if [[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[[xX]\] ]]; then
		print_info "Skipping completed task ${task_id}: dependency metadata not parseable (${invalid:-unknown reference})"
		return 0
	fi
	print_error "Cannot parse dependencies for task ${task_id}: invalid reference ${invalid:-unknown}"
	return 1
}

# Emit declared task dependency edges as blocked-task|blocking-task pairs.
_relationship_declared_edges() {
	local todo_file="$1"
	local task_line="" task_id="" parsed="" key="" value="" stripped=""
	local blocked_by="" blocks="" dep_task_id="" saved_ifs=""
	stripped=$(strip_code_fences <"$todo_file") || return 1
	_relationship_active_ids_and_refs "$stripped" || return 1
	while IFS= read -r task_line; do
		[[ "$task_line" == *"blocked-by:"* || "$task_line" == *"blocks:"* ]] || continue
		[[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[.\][[:space:]]+(t[0-9]+(\.[0-9a-z]+)*)[[:space:]] ]] || continue
		task_id="${BASH_REMATCH[1]}"
		if ! task_identity_validate "$task_id"; then
			_relationship_skip_completed_legacy_row "$task_line" "$task_id" || return 1
			continue
		fi
		if ! parsed=$(parse_task_line "$task_line"); then
			_relationship_report_parse_failure "$task_line" "$task_id" || return 1
			continue
		fi
		blocked_by=""
		blocks=""
		while IFS='=' read -r key value; do
			case "$key" in
			blocked_by) blocked_by="$value" ;;
			blocks) blocks="$value" ;;
			esac
		done <<<"$parsed"
		saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$task_id" "$dep_task_id"
		done
		for dep_task_id in $blocks; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$dep_task_id" "$task_id"
		done
		IFS="$saved_ifs"
	done <<<"$stripped"
	return 0
}

_relationship_edges_for_file() {
	local todo_file="$1"
	if [[ "$_RELATIONSHIP_EDGE_CACHE_FILE" != "$todo_file" ]]; then
		_RELATIONSHIP_EDGE_CACHE=$(set -o pipefail; _relationship_declared_edges "$todo_file" | LC_ALL=C sort -u) || return 1
		_RELATIONSHIP_EDGE_CACHE_FILE="$todo_file"
	fi
	return 0
}

_relationship_prepare_edge_snapshot() {
	local todo_file="$1"
	local owns_scope="$2"
	# Child task subshells inherit the complete graph rather than rescan history.
	_RELATIONSHIP_EDGE_CACHE_FILE=""
	if ! _relationship_edges_for_file "$todo_file"; then
		print_error "Cannot build a complete TODO dependency graph"
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	fi
	return 0
}

_declared_dependency_path_exists() {
	local current_task="$1"
	local target_task="$2"
	local edges="$3"
	local seen_tasks="$4"
	local metrics_file="${5:-}"
	local seen_csv="${seen_tasks//$'\n'/,}"
	# Build a deduplicated adjacency table once, then traverse iteratively. The
	# legacy seen_tasks argument remains accepted for source-compatible callers.
	if printf '%s\n' "$edges" | awk -F'|' \
		-v start="$current_task" -v target="$target_task" \
		-v initial_seen="$seen_csv" -v metrics_file="$metrics_file" '
		function mark_initial_seen(raw, parts, count, idx) {
			count = split(raw, parts, ",")
			for (idx = 1; idx <= count; idx++) {
				if (parts[idx] != "") visited[parts[idx]] = 1
			}
		}
		NF == 2 && $1 != "" && $2 != "" {
			edge_key = $1 SUBSEP $2
			if (!(edge_key in unique_edge)) {
				unique_edge[edge_key] = 1
				degree[$1]++
				adjacent[$1, degree[$1]] = $2
				edge_count++
			}
		}
		END {
			mark_initial_seen(initial_seen)
			found = (start == target)
			stack[++stack_size] = start
			while (!found && stack_size > 0) {
				current = stack[stack_size--]
				if (current in visited) continue
				visited[current] = 1
				visited_count++
				for (idx = 1; idx <= degree[current]; idx++) {
					next_task = adjacent[current, idx]
					traversed_count++
					if (next_task == target) {
						found = 1
						break
					}
					if (!(next_task in visited)) stack[++stack_size] = next_task
				}
			}
			if (metrics_file != "") {
				printf "nodes=%d edges=%d traversed=%d\n", visited_count, edge_count, traversed_count > metrics_file
				close(metrics_file)
			}
			exit(found ? 0 : 1)
		}'
	then
		return 0
	fi
	return 1
}

# Break declared cycles deterministically before native mutation. At least one
# edge in every numeric issue cycle ascends, so dropping ascending cycle edges
# preserves useful ordering without leaving the whole component deadlocked.
_dependency_cycle_should_skip_edge() {
	local blocked_task="$1"
	local blocker_task="$2"
	local blocked_num="$3"
	local blocker_num="$4"
	local todo_file="$5"
	local edges=""
	_relationship_edges_for_file "$todo_file" || return 1
	edges="$_RELATIONSHIP_EDGE_CACHE"
	_declared_dependency_path_exists "$blocker_task" "$blocked_task" "$edges" "" || return 1
	if [[ "$blocked_num" =~ ^[0-9]+$ && "$blocker_num" =~ ^[0-9]+$ ]] &&
		((blocked_num < blocker_num)); then
		log_verbose "$blocked_task (#$blocked_num): ignoring circular blocked-by edge to $blocker_task (#$blocker_num)"
		return 0
	fi
	return 1
}

# Arguments: $1=parent_node_id, $2=child_node_id
# Returns: 0=success/already-exists, 1=error
_gh_add_sub_issue() {
	local parent_id="$1" child_id="$2"
	local result="" contains_rc=0 mutation_rc=0
	_gh_native_sub_issue_contains "$parent_id" "$child_id" || contains_rc=$?
	case "$contains_rc" in
		0)
			log_verbose "  sub-issue relationship already exists"
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
			return 0
			;;
		1) ;;
		*)
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			return 1
			;;
	esac
	# shellcheck disable=SC2016  # GraphQL $variables are literal query syntax
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-add-sub-issue-exact-cost" \
		_gh_with_timeout write gh api graphql -f query='
mutation($parent:ID!,$child:ID!) {
  addSubIssue(input: {issueId:$parent, subIssueId:$child}) {
    issue { number }
  }
}' -f parent="$parent_id" -f child="$child_id" 2>&1) || mutation_rc=$?
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.addSubIssue.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		_relationship_record_outcome "$_REL_OUTCOME_CREATED"
		return 0
	fi
	if echo "$result" | grep -qi 'duplicate sub-issues\|only have one parent'; then
		log_verbose "  sub-issue relationship already exists"
		_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
		return 0
	fi
	_relationship_record_mutation_failure "$mutation_rc" "$result"
	log_verbose "  addSubIssue error: ${result:0:200}"
	return 1
}
