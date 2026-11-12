#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-actions-repair.sh -- Recently-closed parent repair and live-parent trust helpers
# =============================================================================
# Split from pulse-issue-reconcile-actions.sh (GH#37574) to keep the
# orchestrator under the 2000-line file-size-debt gate. Functions moved
# verbatim; no behavioural changes.
#
# Sourced by pulse-issue-reconcile-actions.sh. Do NOT invoke directly.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-actions-repair.sh"
#
# Dependencies:
#   - shared-constants.sh and the pulse-wrapper.sh configuration constants
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_ISSUE_RECONCILE_ACTIONS_REPAIR_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ACTIONS_REPAIR_LOADED=1

_repair_recently_closed_parent() {
	local slug="$1" issue_num="$2" issue_state="$3"
	case "$issue_state" in
	CLOSED | closed) ;;
	*) return 1 ;;
	esac
	if _repair_closed_parent_contract "$slug" "$issue_num"; then
		_SP_CPT_REOPENED=1
	fi
	return 0
}

_repair_recently_closed_parents_for_slug() {
	local slug="$1"
	local max_reopens="${2:-5}"
	local max_candidates="${3:-10}"
	local candidate_stride="${4:-$max_candidates}"
	local candidate_round="${5:-0}"
	local recent_json=""
	local candidates_json=""
	local rows=""
	local row_count=0 candidate_start=0
	local issue_num=""
	local issue_title_b64=""
	local issue_body_b64=""
	local issue_labels_b64=""
	local issue_title=""
	local issue_body=""
	local issue_labels=""
	local decode_flag="-d"
	_PIR_RECENT_PARENT_REOPENED=0
	_PIR_RECENT_PARENT_SCANNED=0
	[[ "$max_reopens" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$max_candidates" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$candidate_stride" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$candidate_round" =~ ^(0|[1-9][0-9]*)$ ]] || return 0
	declare -F _fetch_recently_closed_parent_tasks >/dev/null 2>&1 || return 0
	recent_json=$(_fetch_recently_closed_parent_tasks "$slug" "${_PIR_PT_LABEL:-parent-task}") || return 0
	candidates_json=$(printf '%s' "$recent_json" | jq -c '
		[.[] | select((.state // "" | ascii_downcase) == "closed")] | sort_by(.number)
	' 2>/dev/null) || return 0
	row_count=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null) || return 0
	[[ "$row_count" =~ ^[1-9][0-9]*$ ]] || return 0
	candidate_start=$((((candidate_round % row_count) * (candidate_stride % row_count)) % row_count))
	rows=$(printf '%s' "$candidates_json" | jq -r --argjson start "$candidate_start" --arg string_type "$_PIR_JSON_TYPE_STRING" '
		(.[$start:] + .[:$start])[] |
		[
			(.number // "" | tostring),
			((.title // "") | @base64),
			((.body // "") | @base64),
			(((.labels // []) | map(if type == $string_type then . else (.name // "") end) | join(",")) | @base64)
		] | join("|")
	' 2>/dev/null) || return 0
	[[ "$(uname -s)" == "Darwin" ]] && decode_flag="-D"
	while IFS='|' read -r issue_num issue_title_b64 issue_body_b64 issue_labels_b64; do
		[[ "$_PIR_RECENT_PARENT_REOPENED" -lt "$max_reopens" && \
			"$_PIR_RECENT_PARENT_SCANNED" -lt "$max_candidates" ]] || break
		[[ "$issue_num" =~ ^[1-9][0-9]*$ ]] || continue
		issue_title=$(printf '%s' "$issue_title_b64" | base64 "$decode_flag" 2>/dev/null) || continue
		issue_body=$(printf '%s' "$issue_body_b64" | base64 "$decode_flag" 2>/dev/null) || continue
		issue_labels=$(printf '%s' "$issue_labels_b64" | base64 "$decode_flag" 2>/dev/null) || continue
		_PIR_RECENT_PARENT_SCANNED=$((_PIR_RECENT_PARENT_SCANNED + 1))
		_action_cpt_single "$slug" "$issue_num" "$issue_title" "$issue_body" \
			0 0 0 168 CLOSED "$issue_labels"
		if [[ "$_SP_CPT_REOPENED" -eq 1 ]]; then
			_PIR_RECENT_PARENT_REOPENED=$((_PIR_RECENT_PARENT_REOPENED + 1))
		fi
	done <<<"$rows"
	return 0
}

_pir_parent_repair_uint_is_safe() {
	local value="$1"
	[[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
	[[ "${#value}" -lt 10 ]] && return 0
	[[ "${#value}" -eq 10 && "${value:0:1}" == "1" ]] && return 0
	[[ "${#value}" -eq 10 && "${value:0:1}" == "2" && \
		"${value:1}" -le 147483647 ]] && return 0
	return 1
}

#######################################
# Load the persisted recently-closed-parent repository cursor. Missing,
# malformed, or out-of-range state safely restarts at the first repository.
# Args: $1=cursor file, $2=repository count
# Returns: 0 always; result is exposed through _PIR_PARENT_REPAIR_CURSOR
#######################################
_pir_parent_repair_cursor_load() {
	local cursor_file="$1" repo_count="$2" raw_cursor=""
	_PIR_PARENT_REPAIR_CURSOR=0
	_pir_parent_repair_uint_is_safe "$repo_count" || return 0
	[[ "$repo_count" -gt 0 && -e "$cursor_file" ]] || return 0
	if [[ ! -r "$cursor_file" ]] || ! read -r raw_cursor <"$cursor_file" || \
		! _pir_parent_repair_uint_is_safe "$raw_cursor"; then
		_pir_parent_repair_cursor_store "$cursor_file" 0 || true
		return 0
	fi
	_PIR_PARENT_REPAIR_CURSOR="$raw_cursor"
	return 0
}

#######################################
# Atomically persist the next recently-closed-parent repository cursor.
# Args: $1=cursor file, $2=next cursor
# Returns: 0=stored, 1=invalid or storage failure
#######################################
_pir_parent_repair_cursor_store() {
	local cursor_file="$1" next_cursor="$2" state_dir="" temporary=""
	_pir_parent_repair_uint_is_safe "$next_cursor" || return 1
	state_dir=$(dirname "$cursor_file") || return 1
	mkdir -p "$state_dir" 2>/dev/null || return 1
	temporary=$(mktemp "${state_dir}/.parent-repair-cursor.XXXXXX" 2>/dev/null) || return 1
	if ! printf '%s\n' "$next_cursor" >"$temporary"; then
		rm -f "$temporary" 2>/dev/null || true
		return 1
	fi
	chmod 600 "$temporary" 2>/dev/null || true
	if ! mv "$temporary" "$cursor_file" 2>/dev/null; then
		rm -f "$temporary" 2>/dev/null || true
		return 1
	fi
	return 0
}

#######################################
# Scan a bounded, cursor-rotated repository window for recently closed parents.
# Persisted progress prevents a stable repositories.json order or scheduler
# cadence from starving repos after the first max_repo_scans entries.
# max_candidates bounds expensive per-parent GraphQL, comment, child-state, and
# live-trust checks across the whole cycle.
# Args: $1=repos JSON, $2=max reopens, $3=max repo scans, $4=max candidates
# Returns: 0 always; outcomes are exposed through _PIR_RECENT_PARENT_CYCLE_*
#######################################
_repair_recently_closed_parents_cycle() {
	local repos_json="$1"
	local max_reopens="${2:-5}"
	local max_repo_scans="${3:-10}"
	local max_candidates="${4:-10}"
	local repo_slugs_json="" ordered_slugs="" slug=""
	local repo_count=0 rotation_sequence=0 rotation_start=0 next_cursor=0
	local scan_sequence=0 candidate_round=0
	local cursor_file="${AIDEVOPS_PARENT_REPAIR_CURSOR_FILE:-${HOME}/.aidevops/state/parent-repair-repo.cursor}"
	local reopens_remaining=0 candidates_remaining=0
	_PIR_RECENT_PARENT_REPOS_SCANNED=0
	_PIR_RECENT_PARENT_CYCLE_REOPENED=0
	_PIR_RECENT_PARENT_CYCLE_CANDIDATES=0

	[[ -f "$repos_json" ]] || return 0
	[[ "$max_reopens" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$max_repo_scans" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$max_candidates" =~ ^[1-9][0-9]*$ ]] || return 0
	_pir_parent_repair_uint_is_safe "$max_reopens" || return 0
	_pir_parent_repair_uint_is_safe "$max_repo_scans" || return 0
	_pir_parent_repair_uint_is_safe "$max_candidates" || return 0
	repo_slugs_json=$(jq -c '[
		.initialized_repos[] |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") |
		.slug
	]' "$repos_json" 2>/dev/null) || return 0
	repo_count=$(printf '%s' "$repo_slugs_json" | jq -r 'length' 2>/dev/null) || return 0
	_pir_parent_repair_uint_is_safe "$repo_count" || return 0
	[[ "$repo_count" -gt 0 ]] || return 0

	_pir_parent_repair_cursor_load "$cursor_file" "$repo_count"
	rotation_sequence="$_PIR_PARENT_REPAIR_CURSOR"
	rotation_start=$((rotation_sequence % repo_count))
	scan_sequence="$rotation_sequence"
	ordered_slugs=$(printf '%s' "$repo_slugs_json" | jq -r --argjson start "$rotation_start" \
		'(.[$start:] + .[:$start])[]' 2>/dev/null) || return 0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$_PIR_RECENT_PARENT_REPOS_SCANNED" -lt "$max_repo_scans" && \
			"$_PIR_RECENT_PARENT_CYCLE_REOPENED" -lt "$max_reopens" && \
			"$_PIR_RECENT_PARENT_CYCLE_CANDIDATES" -lt "$max_candidates" ]] || break
		reopens_remaining=$((max_reopens - _PIR_RECENT_PARENT_CYCLE_REOPENED))
		candidates_remaining=$((max_candidates - _PIR_RECENT_PARENT_CYCLE_CANDIDATES))
		candidate_round=$((scan_sequence / repo_count))
		_PIR_RECENT_PARENT_REPOS_SCANNED=$((_PIR_RECENT_PARENT_REPOS_SCANNED + 1))
		_repair_recently_closed_parents_for_slug "$slug" "$reopens_remaining" \
			"$candidates_remaining" "$max_candidates" "$candidate_round"
		_PIR_RECENT_PARENT_CYCLE_REOPENED=$((_PIR_RECENT_PARENT_CYCLE_REOPENED + _PIR_RECENT_PARENT_REOPENED))
		_PIR_RECENT_PARENT_CYCLE_CANDIDATES=$((_PIR_RECENT_PARENT_CYCLE_CANDIDATES + _PIR_RECENT_PARENT_SCANNED))
		if [[ "$scan_sequence" -ge 2147483647 ]]; then
			scan_sequence=0
		else
			scan_sequence=$((scan_sequence + 1))
		fi
		# Never hand a repository a partial tail of the global candidate budget.
		# A non-empty repository owns this cycle's fixed-size candidate window;
		# the persisted sequence advances to the next repository for the next run.
		[[ "$_PIR_RECENT_PARENT_SCANNED" -eq 0 ]] || break
	done <<<"$ordered_slugs"

	if [[ "$rotation_sequence" -gt $((2147483647 - _PIR_RECENT_PARENT_REPOS_SCANNED)) ]]; then
		next_cursor=0
	else
		next_cursor=$((rotation_sequence + _PIR_RECENT_PARENT_REPOS_SCANNED))
	fi
	if [[ "$_PIR_RECENT_PARENT_REPOS_SCANNED" -gt 0 ]] && \
		! _pir_parent_repair_cursor_store "$cursor_file" "$next_cursor"; then
		echo "[pulse-wrapper] Closed-parent repair scan: unable to persist repository cursor" >>"${LOGFILE:-/dev/null}"
	fi
	echo "[pulse-wrapper] Closed-parent repair scan: repos=${_PIR_RECENT_PARENT_REPOS_SCANNED}/${max_repo_scans} candidates=${_PIR_RECENT_PARENT_CYCLE_CANDIDATES}/${max_candidates} reopened=${_PIR_RECENT_PARENT_CYCLE_REOPENED}/${max_reopens} cursor=${rotation_sequence}->${next_cursor}/${repo_count}" >>"${LOGFILE:-/dev/null}"
	return 0
}

_pir_collect_parent_child_evidence() {
	local slug="$1"
	local issue_num="$2"
	local issue_body="$3"
	local self_issue_pattern="^${issue_num}$"
	local graph_nums=""
	local body_nums=""
	local prose_nums=""
	local comment_nums=""
	local source_parts=""
	local children_section=""
	_PIR_CPT_CHILD_NUMS=""
	_PIR_CPT_CHILD_SOURCE="unavailable"
	_PIR_CPT_KNOWN_CHILD_COUNT=0
	_PIR_CPT_DECLARED_NUMS=""
	_PIR_CPT_GRAPH_NUMS=""

	graph_nums=$(_fetch_subissue_numbers "$slug" "$issue_num") || return 1
	graph_nums=$(printf '%s\n' "$graph_nums" | sort -un | grep -v "$self_issue_pattern" | grep -v '^$' || true)
	[[ -n "$graph_nums" ]] && source_parts="${source_parts:+${source_parts}+}graph"
	children_section=$(_extract_children_section "$issue_body")
	if [[ -n "$children_section" ]]; then
		body_nums=$(printf '%s' "$children_section" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un | grep -v "$self_issue_pattern" || true)
		[[ -n "$body_nums" ]] && source_parts="${source_parts:+${source_parts}+}body"
	fi
	prose_nums=$(_extract_children_from_prose "$issue_body" | grep -v "$self_issue_pattern" || true)
	[[ -n "$prose_nums" ]] && source_parts="${source_parts:+${source_parts}+}prose"
	comment_nums=$(_fetch_children_from_trusted_roadmap_comments "$slug" "$issue_num") || return 1
	comment_nums=$(printf '%s\n' "$comment_nums" | grep -v "$self_issue_pattern" || true)
	[[ -n "$comment_nums" ]] && source_parts="${source_parts:+${source_parts}+}comments"
	_PIR_CPT_CHILD_NUMS=$(printf '%s\n%s\n%s\n%s\n' "$graph_nums" "$body_nums" "$prose_nums" "$comment_nums" |
		grep -E '^[0-9]+$' | sort -un | grep -v "$self_issue_pattern" || true)
	_PIR_CPT_CHILD_SOURCE="${source_parts:-none}"
	_PIR_CPT_KNOWN_CHILD_COUNT=$(printf '%s\n' "$_PIR_CPT_CHILD_NUMS" |
		awk '$0 ~ /^[0-9]+$/ { c++ } END { print c+0 }')
	# GH#37679: the explicitly declared list (body ## Children section plus
	# trusted roadmap comments) and the native graph are kept separately so the
	# close contract can check that the declaration covers every graph child.
	_PIR_CPT_DECLARED_NUMS=$(printf '%s\n%s\n' "$body_nums" "$comment_nums" |
		grep -E '^[0-9]+$' | sort -un || true)
	_PIR_CPT_GRAPH_NUMS="$graph_nums"
	return 0
}

#######################################
# Apply the external-author trust gate to a freshly fetched parent. OWNER,
# MEMBER, bots, write-authorized collaborators, and cryptographically approved
# contributors may proceed. Unknown or unapproved authors fail closed; the
# shared gate may add needs-maintainer-review as its idempotent repair.
#
# #aidevops:trust-boundary -- terminal tracker close (GH#34180/#34125 class):
# a maintainer-signed approval that later verifies STALE (signature valid,
# snapshot drifted) still proves a maintainer accepted the parent. Ordinary
# lifecycle work after approval (decomposition labels, dispatch unlock) always
# drifts that snapshot, so requiring VERIFIED left every approved external
# parent permanently open. For the close action only, STALE is accepted and
# _PIR_PARENT_TRUST_BASIS records it; _try_close_parent_tracker then requires
# the child set to include the write-controlled sub-issue graph. All other
# mutations (phase filing, nudges, escalations) still require VERIFIED because
# they act on untrusted parent content.
# Args: $1=slug, $2=issue number, $3=live issue JSON, $4=mutation kind (optional)
# Returns: 0=trusted/approved, 1=blocked
#######################################
_pir_live_parent_trust_is_allowed() {
	local slug="$1" issue_num="$2" live_issue_json="$3" mutation="${4:-}"
	local author_association="" author_login="" author_type="" author_is_bot="false" labels_csv=""
	_PIR_PARENT_TRUST_BASIS="$_PIR_PARENT_TRUST_TRUSTED"
	author_association=$(printf '%s' "$live_issue_json" | \
		jq -r '.author_association // .authorAssociation // ""' 2>/dev/null) || return 1
	author_login=$(printf '%s' "$live_issue_json" | \
		jq -r '.user.login // .author.login // ""' 2>/dev/null) || return 1
	author_type=$(printf '%s' "$live_issue_json" | \
		jq -r '.user.type // .author.type // ""' 2>/dev/null) || return 1
	labels_csv=$(printf '%s' "$live_issue_json" | jq -r --arg string_type "$_PIR_JSON_TYPE_STRING" '
		[.labels[]? | if type == $string_type then . else (.name // empty) end] | join(",")
	' 2>/dev/null) || return 1
	[[ "$author_type" == "Bot" ]] && author_is_bot="true"

	if _should_reconcile_external_issue_gate "$author_association" "$author_type" "$author_is_bot"; then
		if _action_reconcile_external_issue_gate "$slug" "$issue_num" "$labels_csv" \
			"$author_association" "$author_login"; then
			[[ "$mutation" == "$_PIR_PARENT_MUTATION_CLOSE" && \
				"$_PIR_EXTERNAL_GATE_MUTATED" -eq 0 && \
				"$_PIR_EXTERNAL_GATE_VERIFICATION" == "$_PIR_APPROVAL_STALE" ]] || return 1
			_PIR_PARENT_TRUST_BASIS="$_PIR_PARENT_TRUST_STALE_APPROVED_CLOSE"
		fi
	fi
	return 0
}

# Re-read the parent immediately before each mutating action. Cached issue lists
# are only an initial filter; missing metadata, label removal, NMR, persistent
# state, or unresolved external-author trust all fail closed for this cycle.
# When supplied, $3 requires the live issue to remain in that exact state.
# $4 names the mutation kind; only the close kind may use a stale approval.
_pir_parent_mutation_is_allowed() {
	local slug="$1"
	local issue_num="$2"
	local expected_state="${3:-}"
	local mutation="${4:-}"
	local live_issue_json=""
	local nmr_label="${_PIR_NMR_LABEL:-needs-maintainer-review}"
	local parent_label="${_PIR_PT_LABEL:-parent-task}"
	local persistent_label="${_PIR_PERSISTENT_LABEL:-persistent}"
	_PIR_LIVE_PARENT_JSON=""

	[[ "$slug" == */* && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	live_issue_json=$(gh api "repos/${slug}/issues/${issue_num}" 2>/dev/null) || return 1
	#aidevops:trust-boundary -- live NMR/persistent labels stop all parent mutations.
	printf '%s' "$live_issue_json" | jq -e --argjson issue "$issue_num" \
		--arg nmr "$nmr_label" --arg parent "$parent_label" \
		--arg persistent "$persistent_label" --arg string_type "$_PIR_JSON_TYPE_STRING" \
		--arg expected_state "$expected_state" '
		def names: [.labels[]? | if type == $string_type then . else (.name // empty) end];
		(.number == $issue) and
		(names | index($parent) != null) and
		(names | index($nmr) == null) and
		(names | index($persistent) == null) and
		(($expected_state == "") or ((.state // "" | ascii_downcase) == ($expected_state | ascii_downcase)))
	' >/dev/null 2>&1 || return 1
	#aidevops:trust-boundary -- live author authority gates every parent mutation.
	_pir_live_parent_trust_is_allowed "$slug" "$issue_num" "$live_issue_json" "$mutation" || return 1
	_PIR_LIVE_PARENT_JSON="$live_issue_json"
	return 0
}
