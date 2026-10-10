#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by pulse-dispatch-core.sh after its shared constants and dependencies.
[[ -n "${_PULSE_DISPATCH_LOCKS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_LOCKS_LOADED=1

#######################################
# Resolve the worker tier from issue labels. When multiple tier:* labels
# are present (collision — see t1997), pick the highest rank order.
# Fallback: tier:standard if no tier label is present.
# Arguments:
#   $1 - comma-separated label list (e.g., "bug,tier:simple,auto-dispatch")
# Output:
#   tier:thinking, tier:standard, or tier:simple
# Exit codes:
#   0 - always succeeds
#######################################
_resolve_worker_tier() {
	local labels_csv="$1"
	# Convert to lowercase for case-insensitive matching (Bash 3.2 compatible)
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	if [[ "$labels_with_commas" == *",tier:thinking,"* ]]; then
		printf 'tier:thinking'
	elif [[ "$labels_with_commas" == *",tier:standard,"* ]]; then
		printf 'tier:standard'
	elif [[ "$labels_with_commas" == *",tier:simple,"* ]]; then
		printf 'tier:simple'
	else
		printf 'tier:standard' # default when no tier label present
	fi
	return 0
}

#######################################
# Check if a worker exists for a specific repo+issue pair
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Exit codes:
#   0 - matching worker exists
#   1 - no matching worker
#######################################
has_worker_for_repo_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local repo_path
	repo_path=$(get_repo_path_by_slug "$repo_slug")

	local worker_lines
	worker_lines=$(list_active_worker_processes) || worker_lines=""
	local issue_boundary='([^0-9]|$)'

	# Primary match: repo path + issue number in command line.
	# Requires get_repo_path_by_slug to return a non-empty path.
	if [[ -n "$repo_path" ]]; then
		local matches
		matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" -v path="$repo_path" -v boundary="$issue_boundary" '
			BEGIN {
				esc = path
				gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc)
			}
			$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") &&
			($0 ~ ("issue-" issue boundary) || $0 ~ ("Issue #" issue boundary)) { count++ }
			END { print count + 0 }
		') || matches=0
		[[ "$matches" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || matches=0
		if [[ "$matches" -gt 0 ]]; then
			return 0
		fi
	fi

	# Fallback: match by session-key alone (GH#6453).
	# When get_repo_path_by_slug returns empty (slug not in repos.json,
	# path mismatch, or repos.json unavailable), the primary match above
	# always returns 0 matches — a false-negative that causes the backfill
	# cycle to re-dispatch already-running workers.
	# The session-key "issue-<number>" is always present in the command line
	# of workers dispatched via headless-runtime-helper.sh run --session-key.
	# This fallback catches those workers regardless of path resolution.
	local sk_matches
	sk_matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" -v boundary="$issue_boundary" '
		$0 ~ ("--session-key[[:space:]]+issue-" issue boundary) { count++ }
		END { print count + 0 }
	') || sk_matches=0
	[[ "$sk_matches" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || sk_matches=0
	if [[ "$sk_matches" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Thin orchestrator — runs read-only dedup layers in order.
# Byte-for-byte behavioural equivalent of the pre-GH#18654 single-function
# implementation. Layers return 0 to block or 1 to continue; Layer 4 returns 2
# only for a worker draft that must reach stale-assignment recovery first.
# The optimistic GitHub claim lock runs after the worker canary preflight in
# _dispatch_launch_worker so a broken local runtime does not publish noisy
# DISPATCH_CLAIM comments when no worker can start.
#######################################
check_dispatch_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"

	_dedup_layer1_ledger_check "$issue_number" "$repo_slug" && return 0
	_dedup_layer2_process_match "$issue_number" "$repo_slug" && return 0
	_dedup_layer3_title_match "$title" && return 0
	local _pr_evidence_rc=0
	_dedup_layer4_pr_evidence "$issue_number" "$repo_slug" "$issue_title" || _pr_evidence_rc=$?
	if [[ "$_pr_evidence_rc" -eq 0 ]]; then
		return 0
	fi
	# A verified worker-owned draft is still a hard duplicate-dispatch block,
	# but its assignment may need the existing stale-checkpoint transition.
	# Unknown Layer 4 outcomes fail closed rather than weakening PR protection.
	if [[ "$_pr_evidence_rc" -ne 1 && "$_pr_evidence_rc" -ne 2 ]]; then
		return 0
	fi
	# Active dispatch comments and assignment/claim guards are expected
	# cross-runner locks, not launch failures. Preserve the block while giving
	# dispatch_max a distinct benign rc so the stage wrapper suppresses generic
	# "Stage failed" noise and refill loops can skip this candidate for the
	# current pulse cycle (GH#23541).
	_dedup_layer5_dispatch_comment "$issue_number" "$repo_slug" "$self_login" && return 3
	_dedup_layer6_assignee_and_stale "$issue_number" "$repo_slug" "$self_login" && return 3
	[[ "$_pr_evidence_rc" -eq 2 ]] && return 0

	return 1
}

#######################################
# Conversation-lock failure attribution (GH#34057). Values are normalized
# against a fixed allowlist before any log write, so lifecycle logs never carry
# raw stderr, response bodies, credentials or workload content. These globals
# are diagnostics only; they never influence a lock, verify or deny decision.
#######################################
_PULSE_CONVERSATION_LOCK_UNCLASSIFIED="unclassified"
_PULSE_CONVERSATION_LOCK_FAILURE_REASON=""
_PULSE_CONVERSATION_LOCK_FAILURE_DETAIL=""
_PULSE_CONVERSATION_LOCK_MUTATION=""

_conversation_lock_reset_attribution() {
	_PULSE_CONVERSATION_LOCK_FAILURE_REASON=""
	_PULSE_CONVERSATION_LOCK_FAILURE_DETAIL=""
	_PULSE_CONVERSATION_LOCK_MUTATION="not_attempted"
	return 0
}

#######################################
# Record one conversation-lock failure cause (normalized when summarized).
# Args: $1 = reason, $2 = optional read-failure class
#######################################
_conversation_lock_set_failure() {
	local reason="$1"
	local detail="${2:-none}"
	_PULSE_CONVERSATION_LOCK_FAILURE_REASON="$reason"
	_PULSE_CONVERSATION_LOCK_FAILURE_DETAIL="$detail"
	return 0
}

#######################################
# Print a value only when it belongs to the named allowlist.
# Args: $1 = kind (reason|detail|mutation), $2 = value
#######################################
_conversation_lock_allowlisted() {
	local kind="$1"
	local value="$2"
	case "${kind}:${value}" in
	reason:invalid_arguments | reason:read_unavailable | reason:state_malformed | \
		reason:verify_read_unavailable | reason:verify_read_malformed | \
		reason:verify_not_propagated | reason:marker_record_failed | \
		detail:none | detail:not_found | detail:auth_rejected | detail:rate_limited | \
		detail:forbidden | detail:server_error | detail:transport_error | \
		detail:no_diagnostic | mutation:not_attempted | mutation:accepted | \
		mutation:rejected)
		printf '%s\n' "$value"
		;;
	*) printf '%s\n' "$_PULSE_CONVERSATION_LOCK_UNCLASSIFIED" ;;
	esac
	return 0
}

#######################################
# Print the last conversation-lock failure as sanitized key=value fields.
# Unknown or unset state is reported as unclassified, never inferred.
#######################################
conversation_lock_failure_summary() {
	printf 'cause=%s detail=%s mutation=%s\n' \
		"$(_conversation_lock_allowlisted reason "${_PULSE_CONVERSATION_LOCK_FAILURE_REASON:-}")" \
		"$(_conversation_lock_allowlisted detail "${_PULSE_CONVERSATION_LOCK_FAILURE_DETAIL:-none}")" \
		"$(_conversation_lock_allowlisted mutation "${_PULSE_CONVERSATION_LOCK_MUTATION:-not_attempted}")"
	return 0
}

#######################################
# Map gh API stderr to a bounded class. The raw text stays in process memory
# and is never echoed. Rate limits are checked before generic HTTP 403.
# Args: $1 = captured stderr text
#######################################
_conversation_lock_read_failure_class() {
	local err_text="$1"
	local lowered=""
	if [[ -z "$err_text" ]]; then
		printf 'no_diagnostic\n'
		return 0
	fi
	lowered=$(printf '%s' "$err_text" | tr '[:upper:]' '[:lower:]')
	case "$lowered" in
	*"rate limit"* | *"http 429"*) printf 'rate_limited\n' ;;
	*"http 404"* | *"not found"*) printf 'not_found\n' ;;
	*"http 401"* | *"bad credentials"*) printf 'auth_rejected\n' ;;
	*"http 403"*) printf 'forbidden\n' ;;
	*"http 5"[0-9][0-9]*) printf 'server_error\n' ;;
	*"timeout"* | *"timed out"* | *"connection"* | *"dial tcp"* | *"no such host"* | \
		*"could not resolve"* | *"eof"* | *"tls"*) printf 'transport_error\n' ;;
	*) printf '%s\n' "$_PULSE_CONVERSATION_LOCK_UNCLASSIFIED" ;;
	esac
	return 0
}

#######################################
# Read the live conversation-lock state for one issue.
# Success stdout is unchanged (the API .locked value). On read failure the
# function still returns 1 and prints only "unavailable:<class>" so callers
# that inspect the exit status keep their fail-closed behaviour (GH#34057).
#######################################
_read_issue_conversation_lock() {
	local issue_num="$1"
	local slug="$2"
	local err_file="" err_target="/dev/null" locked_state="" read_rc=0 err_text=""
	err_file=$(mktemp 2>/dev/null) || err_file=""
	[[ -z "$err_file" ]] || err_target="$err_file"
	locked_state=$(gh api "repos/${slug}/issues/${issue_num}" --jq '.locked' 2>"$err_target") || read_rc=$?
	if [[ -n "$err_file" ]]; then
		err_text=$(<"$err_file") || err_text=""
		rm -f "$err_file" 2>/dev/null || true
	fi
	if [[ "$read_rc" -ne 0 ]]; then
		printf 'unavailable:%s\n' "$(_conversation_lock_read_failure_class "$err_text")"
		return 1
	fi
	printf '%s\n' "$locked_state"
	return 0
}

#######################################
# Extract the bounded read-failure class from a failed read's stdout.
# Args: $1 = captured stdout of a failed _read_issue_conversation_lock call
#######################################
_conversation_lock_read_failure_detail() {
	local captured="$1"
	if [[ "$captured" == unavailable:* ]]; then
		printf '%s\n' "${captured#unavailable:}"
		return 0
	fi
	printf '%s\n' "$_PULSE_CONVERSATION_LOCK_UNCLASSIFIED"
	return 0
}

#######################################
# Read authoritative conversation-lock state for every auto-dispatch issue in
# one bounded GraphQL request. Reconciliation may use this repository-level
# snapshot, while the worker launch path continues to perform its own fresh
# per-target verification.
#
# Args:
#   $1 = repository slug
#   $2 = raw open-issue snapshot JSON
# Returns:
#   JSON list of {number, locked}; non-zero when any requested issue is absent
#   or malformed
#######################################
_read_issue_conversation_locks_batch() {
	local slug="$1"
	local issue_json="$2"
	local owner="${slug%%/*}"
	local repo="${slug#*/}"
	local issue_numbers="" query="" issue_num="" response=""

	# Require two non-empty components, not different names: same/same is valid.
	[[ "$slug" == */* && -n "$owner" && -n "$repo" && "$repo" != */* ]] || return 1
	issue_numbers=$(printf '%s' "$issue_json" | jq -ce \
		--arg auto_dispatch_label "$_PULSE_DISPATCH_AUTO_LABEL" \
		--arg no_auto_dispatch_label "no-auto-dispatch" '
		[.[] |
			([.labels[]? | .name? // .]) as $labels |
			select(($labels | index($auto_dispatch_label)) != null and ($labels | index($no_auto_dispatch_label)) == null) |
			.number] |
		if all(.[]; type == "number" and . >= 1 and floor == .) then unique else error("invalid issue number") end
	' 2>/dev/null) || return 1
	[[ "$issue_numbers" != "[]" ]] || {
		printf '[]\n'
		return 0
	}

	# shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
	query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
	while IFS= read -r issue_num; do
		query="${query}issue_${issue_num}:issue(number:${issue_num}){number locked}"
	done < <(printf '%s' "$issue_numbers" | jq -r '.[]')
	query="${query}}}"

	response=$(gh api graphql -f "query=${query}" -F "owner=${owner}" -F "name=${repo}" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -ce --argjson expected "$issue_numbers" '
		(.data.repository // null) as $repository |
		if ($repository | type) != "object" then error("missing repository lock snapshot") else
			[$repository[] | select(type == "object") | {number, locked}] as $locks |
			if (($locks | map(.number) | sort) == ($expected | sort)) and
				all($locks[]; (.locked | type) == "boolean")
			then $locks else error("incomplete repository lock snapshot") end
		end
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Verify an issue conversation lock after GitHub accepts the lock mutation.
# The issue REST read can briefly lag the mutation, so retry boundedly while
# preserving the fail-closed trust boundary.
#
# Args:
#   $1 = issue number
#   $2 = repository slug
# Returns:
#   0 when a read confirms locked=true, 1 after bounded exhaustion
#######################################
_verify_issue_conversation_lock() {
	local issue_num="$1"
	local slug="$2"
	local attempts="${AIDEVOPS_CONVERSATION_LOCK_VERIFY_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY:-2}"
	local attempt=1
	local locked_state=""

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$attempts" -le 3 ]] || attempts=3
	[[ "$retry_delay" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || retry_delay=2
	[[ "$retry_delay" -le 5 ]] || retry_delay=2

	while [[ "$attempt" -le "$attempts" ]]; do
		# Retry observed propagation lag, never an unknown transport outcome.
		if ! locked_state=$(_read_issue_conversation_lock "$issue_num" "$slug"); then
			_conversation_lock_set_failure verify_read_unavailable \
				"$(_conversation_lock_read_failure_detail "$locked_state")"
			return 1
		fi
		if [[ "$locked_state" == "true" ]]; then
			return 0
		fi
		if [[ "$locked_state" != "$_PULSE_DISPATCH_FALSE" ]]; then
			_conversation_lock_set_failure verify_read_malformed
			return 1
		fi
		if [[ "$attempt" -lt "$attempts" ]]; then
			sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done

	# Every bounded read answered locked=false: the mutation outcome is not
	# visible yet. This is not evidence that the lock is absent indefinitely.
	_conversation_lock_set_failure verify_not_propagated
	return 1
}

#######################################
# Lock an issue to prevent prompt injection
# (t1894, t1934, GH#30180). Auto-dispatch is the authorization boundary,
# so the issue must be frozen before it enters worker-readable context.
# The issue lock is strict and verified. Linked PR conversations remain open so
# write-access CI can post reviews and status comments during worker execution.
#######################################
_apply_issue_conversation_lock_state() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"
	local locked_state="$4"

	_conversation_lock_reset_attribution
	if [[ -z "$issue_num" || -z "$slug" ]]; then
		_conversation_lock_set_failure invalid_arguments
		return 1
	fi
	case "$locked_state" in
	true)
		if ! _record_auto_dispatch_lock "$issue_num" "$slug"; then
			_conversation_lock_set_failure marker_record_failed
			return 1
		fi
		echo "[pulse-wrapper] Reused existing verified conversation lock for #${issue_num} in ${slug} (GH#30180)" >>"$LOGFILE"
		return 0
		;;
	false) ;;
	*)
		_conversation_lock_set_failure state_malformed
		return 1
		;;
	esac

	# aidevops:trust-boundary — never launch a worker when the mutable public
	# instruction surface could not be frozen and independently re-read.
	local lock_applied=0
	if ! gh issue lock "$issue_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1; then
		# A rejected mutation is not retried: only an independent read may
		# establish that another actor already froze the conversation.
		_PULSE_CONVERSATION_LOCK_MUTATION="rejected"
		if ! _verify_issue_conversation_lock "$issue_num" "$slug"; then
			echo "[pulse-wrapper] Failed to verify conversation lock for #${issue_num} in ${slug}; dispatch remains blocked (GH#30180) $(conversation_lock_failure_summary)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-wrapper] Reused existing verified conversation lock for #${issue_num} in ${slug} (GH#30180)" >>"$LOGFILE"
	else
		lock_applied=1
		_PULSE_CONVERSATION_LOCK_MUTATION="accepted"
	fi
	if [[ "$lock_applied" -eq 1 ]] && ! _verify_issue_conversation_lock "$issue_num" "$slug"; then
		echo "[pulse-wrapper] Failed to verify conversation lock for #${issue_num} in ${slug}; dispatch remains blocked (GH#30180) $(conversation_lock_failure_summary)" >>"$LOGFILE"
		return 1
	fi
	if ! _record_auto_dispatch_lock "$issue_num" "$slug"; then
		_conversation_lock_set_failure marker_record_failed
		return 1
	fi
	echo "[pulse-wrapper] Locked #${issue_num} in ${slug} during worker execution (t1934)" >>"$LOGFILE"

	return 0
}

lock_issue_for_worker() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"
	local locked_state=""

	_conversation_lock_reset_attribution
	if [[ -z "$issue_num" || -z "$slug" ]]; then
		_conversation_lock_set_failure invalid_arguments
		return 1
	fi

	# The launch path always uses a fresh per-target read. Repository-level
	# reconciliation calls _apply_issue_conversation_lock_state directly with a
	# bounded authoritative batch snapshot and cannot weaken this final gate.
	if ! locked_state=$(_read_issue_conversation_lock "$issue_num" "$slug"); then
		_conversation_lock_set_failure read_unavailable \
			"$(_conversation_lock_read_failure_detail "$locked_state")"
		return 1
	fi
	_apply_issue_conversation_lock_state "$issue_num" "$slug" "$reason" "$locked_state"
	return $?
}

_auto_dispatch_lock_marker() {
	local issue_num="$1"
	local slug="$2"
	local lock_dir="${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR:-${HOME}/.aidevops/cache/auto-dispatch-locks}"
	local lock_key="${slug//\//--}-${issue_num}"
	printf '%s/%s\n' "$lock_dir" "$lock_key"
	return 0
}

_record_auto_dispatch_lock() {
	local issue_num="$1"
	local slug="$2"
	local marker=""
	marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || return 1
	mkdir -p "${marker%/*}" 2>/dev/null || return 1
	: >"$marker" 2>/dev/null || return 1
	return 0
}

#######################################
# Return success when label policy requires the conversation to remain locked.
# Args: comma-separated label names
#######################################
_auto_dispatch_lock_required() {
	local labels_csv="$1"
	if [[ ",$labels_csv," == *,auto-dispatch,* && ",$labels_csv," != *,no-auto-dispatch,* ]]; then
		return 0
	fi
	return 1
}

#######################################
# Reconcile conversation locks for every visible auto-dispatch issue,
# including blocked and queued work that cannot reach the launch path yet.
# Only markers owned by this mechanism may trigger an unlock.
#######################################
reconcile_auto_dispatch_issue_locks() {
	local slug="$1"
	local issue_json="$2"
	local issue_num="" marker="" labels="" labels_csv="" lock_snapshot="" lock_states="" locked_state=""
	[[ -n "$slug" && -n "$issue_json" ]] || return 1
	lock_snapshot=$(_read_issue_conversation_locks_batch "$slug" "$issue_json") || return 1
	lock_states=$(printf '%s' "$lock_snapshot" | jq -ce '
		map({key: (.number | tostring), value: .locked}) | from_entries
	' 2>/dev/null) || return 1

	while IFS=$'\t' read -r issue_num labels; do
		[[ "$issue_num" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || continue
		marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || continue
		labels_csv=",${labels},"
		if _auto_dispatch_lock_required "$labels"; then
			locked_state=$(printf '%s' "$lock_states" | jq -r --arg issue_num "$issue_num" \
				'if has($issue_num) then .[$issue_num] | tostring else "unknown" end' 2>/dev/null) || return 1
			[[ "$locked_state" == "true" || "$locked_state" == "$_PULSE_DISPATCH_FALSE" ]] || return 1
			_apply_issue_conversation_lock_state "$issue_num" "$slug" resolved "$locked_state" || return 1
		elif [[ -f "$marker" && "$labels_csv" != *,no-auto-dispatch,* ]]; then
			gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || return 1
			rm -f "$marker" 2>/dev/null || return 1
			echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after auto-dispatch removal (GH#30180)" >>"$LOGFILE"
		fi
	done < <(printf '%s' "$issue_json" | jq -r '.[] | [(.number | tostring), ([.labels[]? | .name? // .] | join(","))] | @tsv' 2>/dev/null)

	return 0
}

#######################################
# Release conversation locks after terminal worker handling only when the issue
# is no longer auto-dispatch eligible. Retryable work stays frozen across the
# worker-to-Pulse handoff, closing the post-worker comment race (GH#30180).
#######################################
unlock_issue_after_worker() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	local labels=""
	if ! labels=$(gh api "repos/${slug}/issues/${issue_num}" --jq '[.labels[]? | .name] | join(",")' 2>/dev/null); then
		echo "[pulse-wrapper] Could not verify labels before unlocking #${issue_num} in ${slug}; retaining conversation lock (GH#30180)" >>"$LOGFILE"
		return 1
	fi
	# aidevops:trust-boundary — auto-dispatch remains authoritative across
	# retries, so completion cleanup must not reopen its instruction surface.
	if _auto_dispatch_lock_required "$labels"; then
		echo "[pulse-wrapper] Retained conversation lock for auto-dispatch #${issue_num} in ${slug} after worker handoff (GH#30180)" >>"$LOGFILE"
		return 0
	fi

	gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	local marker=""
	marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || marker=""
	[[ -z "$marker" ]] || rm -f "$marker" 2>/dev/null || true
	echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after worker completion (t1934)" >>"$LOGFILE"

	return 0
}

#######################################
# GH#17779: Helper for _is_task_committed_to_main.
# Reads commit hashes from stdin, applies the two-stage planning filter
# (subject-line prefix + path-based), and prints the count of real
# implementation commits to stdout.
#
# Planning-only path allowlist (t2379, GH#19863):
#   - TODO.md / todo/**           — task entries and briefs
#   - AGENTS.md / .agents/AGENTS.md — agent guides
#   - docs/** / */docs/**         — documentation
#   - .task-counter               — CAS counter file touched by
#                                   claim-task-id.sh on every ID allocation.
#                                   Without this, a planning PR that
#                                   touches TODO.md + brief + .task-counter
#                                   is misclassified as implementation and
#                                   permanently blocks future dispatch via
#                                   the main-commit dedup false positive
#                                   (GH#17574). Root cause of the t2366
#                                   r914 task getting stuck after its
#                                   plan-filing PR #19819 merged.
#
# Args:
#   $1 - repo_path (local path to the repo)
# Stdin: one commit hash per line
#######################################
_count_impl_commits() {
	local repo_path_inner="$1"
	local match_count_inner=0
	local commit_hash_inner
	while IFS= read -r commit_hash_inner; do
		[[ -z "$commit_hash_inner" ]] && continue
		local is_planning_only_inner=true
		local touched_path_inner
		while IFS= read -r touched_path_inner; do
			[[ -z "$touched_path_inner" ]] && continue
			case "$touched_path_inner" in
			TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md | */docs/* | docs/* | .task-counter) ;;
			*)
				is_planning_only_inner=false
				break
				;;
			esac
		done < <(git -C "$repo_path_inner" diff-tree --no-commit-id --name-only -r "$commit_hash_inner" 2>/dev/null)
		if [[ "$is_planning_only_inner" == "$_PULSE_DISPATCH_FALSE" ]]; then
			match_count_inner=$((match_count_inner + 1))
		fi
	done
	echo "$match_count_inner"
	return 0
}

#######################################
# t2004: Signal 1 — search git log subject lines for task ID patterns.
# Handles tNNN and GH#NNN prefixes extracted from the issue title.
# Subject-only matching prevents body cross-references from causing false
# positives (GH#17779). Uses _count_impl_commits to filter planning-only
# commits (GH#17707).
#
# Args:
#   $1 - issue_title (to extract tNNN / GH#NNN prefix patterns)
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_recent_commits() {
	local issue_title="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 1: tNNN or tNNN.X task ID from title (e.g., "t153: add dark mode", "t2053.2: shell init")
	# Subject-only: body cross-references like "(t101)" must not match.
	# grep -w enforces word boundaries — prevents t101 matching t1010.
	# Subtask decimal suffix preserved (GH#19165) — t2053.2 must NOT match parent t2053 commits.
	local -a subject_patterns=()
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9a-z]+)*' | head -1 | sed 's/[.]/\\./g') || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		subject_patterns+=("$task_id_match")
	fi

	# Pattern 2: GH#NNN from title (e.g., "GH#17574: fix pulse dispatch")
	# Subject-only: body mentions of other GH# IDs must not match.
	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		subject_patterns+=("$gh_id_match")
	fi

	[[ ${#subject_patterns[@]} -gt 0 ]] || return 1

	# Bash 3.2 + set -u: length check already done above.
	local pattern
	for pattern in "${subject_patterns[@]}"; do
		local match_count=0
		# Fetch all commits as "HASH SUBJECT", filter planning subjects, then
		# grep -w for word-boundary match on the subject portion only.
		#
		# Subject exclusions (t2379, GH#19863):
		#   - chore: claim        — claim-task-id.sh counter bump commits
		#   - chore: mark tNNN complete — task-complete-helper.sh bookkeeping
		#       commits written by issue-sync.yml after ANY PR merge. Touch
		#       TODO.md only, but belt+braces against future regressions.
		#   - plan: / pNN:        — explicit planning prefixes
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				--format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|chore: mark t[0-9]+ complete|plan:|p[0-9]+:)' |
				grep -wE "$pattern" |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_recent_commits: found ${match_count} commit(s) matching subject pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 2 — search git log commit messages for closing keywords and
# squash-merge suffixes that indicate the issue was resolved via a merged PR.
#
# Patterns: "(#NNN)" squash-merge suffix, "Closes #NNN", "Fixes #NNN".
# Full-message matching is safe here — these keywords legitimately appear
# only in commit bodies for commits that close an issue (GH#17779).
#
# Args:
#   $1 - issue_number
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_merged_pr() {
	local issue_number="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 3: GitHub squash-merge suffix "(#NNN)" — only matches commit
	# titles, not body references. The bare "#NNN" pattern previously caused
	# false positives: any commit that MENTIONED an issue (e.g., "Relabeled
	# #17659 and #17660") would match, closing issues whose work hadn't been
	# done. Restrict to the "(#NNN)" suffix that GitHub adds to squash merges.
	# t1927: Escape parens for -E regex — unescaped parens are capture groups
	# that match bare "#NNN" in commit bodies (evidence tables, PR descriptions).
	# With \( \) the pattern only matches the literal "(#NNN)" suffix.
	local -a message_patterns=()
	message_patterns+=("\\(#${issue_number}\\)")

	# Patterns 4-5: "Closes #NNN" / "Fixes #NNN" in commit messages — these
	# are the conventional patterns for commits that resolve an issue.
	# \b word boundary prevents #17779 from matching #177790 (longer IDs).
	message_patterns+=("[Cc]loses #${issue_number}\\b")
	message_patterns+=("[Ff]ixes #${issue_number}\\b")

	# Bash 3.2 + set -u: guard empty array iteration.
	local pattern
	for pattern in "${message_patterns[@]}"; do
		local match_count=0
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				-E --grep="$pattern" --format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_merged_pr: found ${match_count} commit(s) matching message pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 3 — scan TODO.md on origin/main for completed task markers.
# Catches tasks marked [x] in planning files without a conventional commit
# message — e.g., tasks completed via direct TODO edit + push.
#
# Args:
#   $1 - issue_number
#   $2 - issue_title (to extract tNNN prefix)
#   $3 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task found completed ([x]) in TODO.md on origin/main
#   1 - no match (or TODO.md unavailable)
#######################################
_task_id_in_changed_files() {
	local issue_number="$1"
	local issue_title="$2"
	local repo_path="$3"

	local todo_content
	todo_content=$(git -C "$repo_path" show origin/main:TODO.md 2>/dev/null) || return 1

	# Check for tNNN or tNNN.X completion marker: "- [x] tNNN ..."
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9a-z]+)*' | head -1 | sed 's/[.]/\\./g') || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\]\s+${task_id_match}(\s|$)"; then
			echo "[pulse-wrapper] _task_id_in_changed_files: found completed '${task_id_match}' in TODO.md on origin/main" >>"$LOGFILE"
			return 0
		fi
	fi

	# Check for GH#NNN completion marker: "- [x] ... GH#NNN ..."
	if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\].*\bGH#${issue_number}\b"; then
		echo "[pulse-wrapper] _task_id_in_changed_files: found completed 'GH#${issue_number}' in TODO.md on origin/main" >>"$LOGFILE"
		return 0
	fi

	return 1
}
