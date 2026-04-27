#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-actions.sh — Per-issue action helpers and predicates
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21376) to keep the orchestrator
# file below the 2000-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined all PULSE_* configuration constants.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-actions.sh"
#
# Exports — parent-task child detection helpers:
#   _fetch_subissue_numbers       — fetch child issue numbers via GraphQL
#   _extract_children_section     — extract ## Children / ## Sub-tasks section
#   _extract_children_from_prose  — extract children from narrow prose patterns
#   _compute_parent_nudge_age_hours — compute age of decomposition nudge comment
#   _post_parent_phases_unfiled_nudge — nudge when declared phases > filed children
#   _try_close_parent_tracker     — close parent if all children are resolved
#
# Exports — single-pass stage predicates:
#   _should_ciw   — stage 1 predicate (status:available)
#   _should_rsd   — stage 2 predicate (status:done)
#   _should_oimp  — stage 3 predicate (not a parent-task)
#   _should_cpt   — stage 4 predicate (parent-task)
#   _should_lia   — stage 5 predicate (labelless aidevops-shaped)
#
# Exports — single-pass per-issue action helpers:
#   _action_ciw_single   — close issue with merged PR (stage 1)
#   _action_rsd_single   — reconcile stale-done issue (stage 2)
#   _action_oimp_single  — close open issue with merged PR (stage 3)
#   _action_cpt_single   — reconcile parent-task (stage 4)
#
# Note: _action_lia_single (stage 5) is over 100 lines and stays in
# pulse-issue-reconcile.sh to preserve its (file, fname) identity key.
# _post_parent_decomposition_nudge and _post_parent_decomposition_escalation
# are also over 100 lines and stay in the orchestrator.

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED=1

#######################################
# Fetch sub-issue numbers via GitHub GraphQL (t2138).
#
# Uses the native `subIssues` relationship on the issue node. Returns
# newline-separated child issue numbers on stdout. Empty output on any
# failure, empty graph, or feature-not-enabled. Callers must treat empty
# output as "fall back to body regex", NOT "no children" — the sub-issue
# feature is a recent GitHub addition and legacy parents may link
# children only via body text.
#
# Args: $1 = slug (owner/name), $2 = issue number
#######################################
_fetch_subissue_numbers() {
	local slug="$1" issue_num="$2"
	[[ "$slug" == */* ]] || return 0
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 0

	local owner="${slug%%/*}" name="${slug##*/}"
	# t2138: fetch pageInfo alongside nodes so we can fail-closed when
	# hasNextPage is true. Partial child lists would silently let the
	# reconciler close parents before the tail children are checked.
	# The jq filter returns `PAGINATED` (non-numeric) when hasNextPage=true,
	# which the caller treats as "empty" → falls back to body regex.
	local graphql_result
	# shellcheck disable=SC2016  # GraphQL variable markers ($owner/$name/$number) are intentional literals, not bash expansions
	graphql_result=$(gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){subIssues(first:50){nodes{number state}pageInfo{hasNextPage}}}}}' \
		-F "owner=$owner" -F "name=$name" -F "number=$issue_num" \
		--jq 'if (.data.repository.issue.subIssues.pageInfo.hasNextPage // false) then "PAGINATED" else (.data.repository.issue.subIssues.nodes // [] | .[] | .number) end' 2>/dev/null) || return 0

	# Fail-closed guard: if hasNextPage, pretend we got nothing so the
	# caller falls back to body regex (where pagination is not an issue).
	if [[ "$graphql_result" == "PAGINATED" ]]; then
		return 0
	fi
	printf '%s\n' "$graphql_result"
	return 0
}

# t2244: extract the ## Children / ## Sub-tasks / ## Child issues section from
# a parent issue body. Returns ONLY the text between that heading and the next
# ## heading (or EOF). Returns empty if no matching heading found — caller must
# treat empty as "no declared children in body" and skip the body-regex path.
# This prevents prose #NNN mentions (e.g., "triggered by #19708") from being
# misread as child references and causing premature parent close.
_extract_children_section() {
	local body="$1"
	printf '%s' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	'
	return 0
}

#######################################
# t2442: extract child issue numbers from narrow prose patterns.
#
# DELIBERATELY narrow — t2244 (CodeRabbit review of PR #19810) explicitly
# disqualified "any #NNN mention = child" matching after the #19734
# incident where that logic closed parent trackers prematurely by
# mistaking context refs for children. This helper only matches four
# phrase shapes that unambiguously declare a child relationship:
#
#   1. `Phase N <anything> #NNNN` — e.g. "Phase 1 split out as #19996"
#   2. `filed as #NNNN`           — "Phase 2 was filed as #20001"
#   3. `tracks #NNNN`              — "tracks #19808 and #19858"
#   4. `[Bb]locked by:? #NNNN`     — "Blocked by: #42"
#
# Bare `#NNNN` mentions in prose (e.g. "triggered by #19708", "cf. #12345",
# "closes #17", "see #42") are intentionally NOT matched. The heuristic
# is: these four verbs-of-parenthood are rare in prose about ANYTHING
# ELSE, so the false-positive rate is low and the false-negative cost
# (parent stays open one more cycle until nudge fires, harmless) is
# acceptable.
#
# Called as a THIRD fallback in reconcile_completed_parent_tasks after
# the GraphQL subIssues graph AND the ## Children heading extraction
# both come back empty. Never mutates the parent body.
#
# Arguments:
#   arg1 - parent issue body text
# Outputs: one child issue number per line, deduplicated, sorted. Empty
#          output = no matches (caller must treat as "no children from
#          prose" and skip to the nudge/escalation path).
# Returns: always 0.
#######################################
_extract_children_from_prose() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Four narrow patterns. POSIX ERE only (grep -E) so macOS bash 3.2 compat.
	# We collect matches then extract the numeric portion.
	#   - phase-ref:  "Phase 1 split out as #19996", "Phase 2 — #20001"
	#   - filed-as:   "filed as #N", "was filed as #N"
	#   - tracks:     "tracks #N"
	#   - blocked-by: "blocked by: #N", "Blocked by #N", "blocked-by: #N"
	#
	# Each pattern independently captures the #NNNN token; we union the
	# results via sort -u. Anchors `(^|[^a-zA-Z0-9_])` and `([^a-zA-Z0-9_]|$)`
	# prevent matches inside words (e.g. "hashtracks" or "#Nfiled").
	local patterns=(
		'(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Tt]racks[[:space:]]+#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)'
	)

	local all_matches=""
	local pat
	for pat in "${patterns[@]}"; do
		local hits
		hits=$(printf '%s' "$body" | grep -oE "$pat" 2>/dev/null || true)
		[[ -n "$hits" ]] || continue
		all_matches="${all_matches}${hits}"$'\n'
	done

	[[ -n "$all_matches" ]] || return 0

	# Extract the trailing #NNNN from each matched phrase, strip the `#`,
	# drop anything that isn't a clean positive integer, deduplicate.
	printf '%s' "$all_matches" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un
	return 0
}

#######################################
# t2442: Compute the age (in hours) of the existing nudge comment on a
# parent-task issue. Used by the escalation path to gate "nudge has sat
# unactioned for long enough that we escalate".
#
# Walks comments for the `<!-- parent-needs-decomposition -->` marker,
# returns the age in HOURS as an integer on stdout. Returns empty output
# (exit 0) if no such comment exists OR if the API call fails — the
# caller MUST treat empty as "do not escalate" (fail-closed — without a
# nudge there is no signal to escalate on, and API-unavailable should
# never open new comments).
#
# Arguments:
#   arg1 - repo slug
#   arg2 - parent issue number
# Outputs: integer hours (e.g. "168") or empty string on no-nudge/failure.
#######################################
_compute_parent_nudge_age_hours() {
	local slug="$1"
	local parent_num="$2"

	[[ -n "$slug" && "$parent_num" =~ ^[0-9]+$ ]] || return 0

	# t2572: streaming pattern — --paginate + --jq (no --slurp, which `gh api`
	# rejects). Per-page jq emits matching .created_at values; `head -n1`
	# yields the first match across all pages (chronological order = oldest,
	# which is what the 7-day escalation gate wants).
	local nudge_created_at
	nudge_created_at=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq '.[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .created_at' \
		2>/dev/null | head -n1) || nudge_created_at=""
	[[ -n "$nudge_created_at" ]] || return 0

	# Convert ISO-8601 to epoch. macOS `date` needs -j -f; GNU `date` uses -d.
	local nudge_epoch="" now_epoch=""
	if date --version >/dev/null 2>&1; then
		nudge_epoch=$(date -d "$nudge_created_at" +%s 2>/dev/null || echo "")
	else
		nudge_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$nudge_created_at" +%s 2>/dev/null || echo "")
	fi
	[[ "$nudge_epoch" =~ ^[0-9]+$ ]] || return 0

	now_epoch=$(date +%s)
	local age_seconds=$((now_epoch - nudge_epoch))
	[[ "$age_seconds" -ge 0 ]] || return 0

	printf '%d\n' "$((age_seconds / 3600))"
	return 0
}

_post_parent_phases_unfiled_nudge() {
	local slug="$1"
	local parent_num="$2"
	local declared_count="${3:-0}"
	local filed_count="${4:-0}"
	local unfiled_phases="${5:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-declared-phases-unfiled -->'

	# Idempotency check: skip if marker already present in any comment.
	# Pattern mirrors _post_parent_decomposition_nudge (t2572 fix: streaming
	# --paginate + --jq, no --slurp). Fail-closed on API error.
	# Use printf to build the jq filter to avoid a 3rd raw copy of the
	# .[] | select(.body | contains()) fragment (string-literal ratchet).
	local _jq_filter
	_jq_filter=$(printf '.[] | select(.body | contains("%s")) | .id' "$marker")
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq "$_jq_filter" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""

	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Phases nudge dedup: API/jq failure for #${parent_num} in ${slug} — skipping (fail-closed, t2786)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	[[ "$existing" -ge 1 ]] && return 1

	local unfiled_list=""
	if [[ -n "$unfiled_phases" ]]; then
		unfiled_list="

**Unfiled phases detected:**

$(printf '%s' "$unfiled_phases" | sed 's/^[[:space:]]*//' | sed 's/^/- /')"
	fi

	local comment_body="${marker}
## Parent Tracker: Declared Phases Not Yet Filed

This parent declares **${declared_count} phase(s)** in its \`## Phases\` section but only **${filed_count}** have been filed as child issues. Closing the parent now would be premature — the unfiled phases would be silently dropped.${unfiled_list}

**To proceed:** file the remaining phases as child issues and link them in a \`## Children\` section in the parent body. The parent will close automatically once all children are resolved.

_Detected by \`_try_close_parent_tracker\` (pulse-issue-reconcile.sh, t2786). Posted once per issue via the \`<!-- parent-declared-phases-unfiled -->\` marker; re-runs are no-ops._"

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: phases-unfiled nudge posted for #${parent_num} in ${slug} (declared=${declared_count}, filed=${filed_count}, t2786)" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# t2138: extract per-parent close logic. Keeps reconcile_completed_parent_tasks
# under the 100-line shell-complexity threshold and makes the close decision
# independently testable. Returns 0 if the parent was closed, 1 if skipped
# (fewer than 2 known children, any child still open, or close call failed).
_try_close_parent_tracker() {
	local slug="$1" parent_num="$2" child_nums="$3" child_source="$4" parent_body="${5:-}"
	local all_closed="true" child_summary="" child_count=0
	local child_num="" child_state="" child_title_line=""

	while IFS= read -r child_num; do
		[[ -n "$child_num" && "$child_num" =~ ^[0-9]+$ ]] || continue
		child_state=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.state // "unknown"' 2>/dev/null) || child_state="unknown"
		child_title_line=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.title // ""' 2>/dev/null) || child_title_line=""

		# Skip references that aren't real child issues (PRs, external refs)
		[[ "$child_state" == "unknown" ]] && continue

		child_count=$((child_count + 1))
		if [[ "$child_state" == "closed" ]]; then
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ✅ CLOSED"
		else
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ⏳ OPEN"
			all_closed="false"
		fi
	done <<<"$child_nums"

	# Need at least 2 children (1 = probably just a reference, not a parent).
	[[ "$child_count" -ge 2 ]] || return 1
	[[ "$all_closed" == "true" ]] || return 1

	# t2786 / GH#20871: declared-vs-filed guard. If the parent body declares
	# more phases in a ## Phases section than have been filed as child issues,
	# skip close and post a one-time nudge.
	#
	# Counting is over the structured parser's row output (see _parse_phases_section
	# delegation comment near top of this module). Each row represents one
	# canonically-declared phase (list-form or bold-form). Rows starting with
	# a digit form the count; rows with an empty 4th tab field (child_ref)
	# are unfiled.
	if [[ -n "$parent_body" ]]; then
		local _phases_section
		_phases_section=$(_parse_phases_section "$parent_body")
		if [[ -n "$_phases_section" ]]; then
			local _declared_count
			_declared_count=$(printf '%s\n' "$_phases_section" | safe_grep_count -E '^[0-9]+	')
			if [[ "$_declared_count" -gt "$child_count" ]]; then
				local _unfiled_phases
				# Rows where field 4 (child_ref) is empty — phases declared
				# but not yet linked to a child issue. Format human-readable
				# for the nudge body: "Phase N: description".
				_unfiled_phases=$(printf '%s\n' "$_phases_section" | \
					awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { printf "Phase %s: %s\n", $1, $2 }')
				_post_parent_phases_unfiled_nudge \
					"$slug" "$parent_num" "$_declared_count" "$child_count" "$_unfiled_phases"
				echo "[pulse-wrapper] Reconcile parent-task: skip close #${parent_num} in ${slug} — declared ${_declared_count} phases but only ${child_count} filed (t2786)" >>"${LOGFILE:-/dev/null}"
				return 1
			fi
		fi
	fi

	gh issue close "$parent_num" --repo "$slug" \
		--comment "## All child tasks completed — closing parent tracker

${child_summary}

All ${child_count} child issues are resolved. Parent tracker closed automatically.

_Detected by reconcile_completed_parent_tasks (pulse-issue-reconcile.sh)._" \
		>/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: closed #${parent_num} in ${slug} — all ${child_count} children closed (source=${child_source})" >>"$LOGFILE"
	return 0
}

# Stage 1 predicate: issue has status:available (candidate for close-via-merged-PR).
# Args: $1 = labels_csv (comma-separated label names from pre-fetched JSON)
# Note: unquoted case patterns avoid adding to the string-literal ratchet count.
_should_ciw() {
	local labels_csv="$1"
	case "$labels_csv" in
		*status:available*) return 0 ;;
	esac
	return 1
}

# Stage 2 predicate: issue has status:done (candidate for stale-done reconcile).
# Args: $1 = labels_csv
_should_rsd() {
	local labels_csv="$1"
	case "$labels_csv" in
		*status:done*) return 0 ;;
	esac
	return 1
}

# Stage 3 predicate: issue is NOT a parent-task (candidate for open-with-merged-PR check).
# Issues handled by stages 1+2 via short-circuit never reach this predicate.
# Args:
#   $1 = issue_num
#   $2 = parent_task_nums (newline-delimited list of parent-task issue numbers)
_should_oimp() {
	local issue_num="$1"
	local parent_task_nums="$2"
	if [[ -n "$parent_task_nums" ]] && printf '%s\n' "$parent_task_nums" | grep -qx "$issue_num"; then
		return 1
	fi
	return 0
}

# Stage 4 predicate: issue carries the parent-task label.
# Args: $1 = labels_csv
_should_cpt() {
	local labels_csv="$1"
	case "$labels_csv" in
		*parent-task*) return 0 ;;
	esac
	return 1
}

# Stage 5 predicate: issue is an aidevops-shaped labelless candidate.
# Title must match tNNN: or GH#NNN: AND no origin:/tier:/status: labels.
# Args: $1 = issue_title, $2 = labels_csv
_should_lia() {
	local issue_title="$1"
	local labels_csv="$2"
	# Title must match aidevops task shape
	if ! printf '%s' "$issue_title" | grep -qE '^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+): '; then
		return 1
	fi
	# Must have no origin:/tier:/status: labels (unquoted patterns avoid ratchet)
	case "$labels_csv" in
		*origin:* | *tier:* | *status:*) return 1 ;;
	esac
	return 0
}

##############################################
# t2776: Per-issue action helpers for reconcile_issues_single_pass.
# Each helper encapsulates the action logic for one reconcile sub-stage.
# Called once per qualifying issue; the outer loop and issue fetch live in
# reconcile_issues_single_pass — not here.
#
# Return conventions (consistent across helpers):
#   0 = action taken (issue closed / fixed / nudged / escalated)
#   1 = no action taken (skipped, guard fired, API failure, etc.)
#   2 = reset action taken (used by _action_rsd_single: reset to available)
##############################################

#######################################
# Stage 1 action: close an issue whose work is done via a merged PR.
# (Per-issue body of close_issues_with_merged_prs — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if issue was closed, 1 otherwise
#######################################
_action_ciw_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null) || return 1

	local pr_ref="" pr_num="" merged_at=""
	pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
	pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
	merged_at=""

	if [[ -n "$pr_num" ]]; then
		merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
		if [[ -z "$merged_at" ]]; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
		>/dev/null 2>&1 || return 1

	fast_fail_reset "$issue_num" "$slug" || true
	unlock_issue_after_worker "$issue_num" "$slug"
	echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
	return 0
}

#######################################
# Stage 2 action: reconcile a status:done issue.
# (Per-issue body of reconcile_stale_done_issues — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if closed, 2 if reset to status:available, 1 if no action taken
#######################################
_action_rsd_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
		local pr_ref="" pr_num="" merged_at=""
		pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
		pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
		merged_at=""

		if [[ -n "$pr_num" ]]; then
			merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
			if [[ -z "$merged_at" ]]; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
			if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		gh issue close "$issue_num" --repo "$slug" \
			--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"} (merged at ${merged_at:-unknown})." \
			>/dev/null 2>&1 || return 1

		fast_fail_reset "$issue_num" "$slug" || true
		unlock_issue_after_worker "$issue_num" "$slug"
		echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
		return 0
	else
		# No merged PR — reset for re-evaluation
		set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
		echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
		return 2
	fi
}

#######################################
# Stage 3 action: close an open issue whose linked PR has already merged.
# (Per-issue body of reconcile_open_issues_with_merged_prs — no slug loop.)
#
# t2985: looks up the merged PR via the per-repo prefetched lookup string
# (built once by _build_oimp_lookup_for_slug). Replaces the previous
# per-issue gh search + gh pr view body-recheck pair, which was the
# dominant cost driver in reconcile_issues_single_pass (~600s/cycle at
# steady-state, the t2984 budget threshold). Body-keyword filtering is
# built into the lookup builder itself, so the redundant body-grep is
# also gone.
#
# Args:
#   $1 = slug
#   $2 = issue_num
#   $3 = verify_helper (path to verify-issue-close-helper.sh)
#   $4 = oimp_lookup (pipe-delimited |num=pr|...| string from
#        _build_oimp_lookup_for_slug; may be empty if prefetch failed)
# Returns: 0 if closed, 1 otherwise
#######################################
_action_oimp_single() {
	local slug="$1" issue_num="$2" verify_helper="$3"
	local oimp_lookup="${4:-}"

	# t2985: lookup PR number locally instead of `gh pr list --search`.
	# Empty lookup → no merged PR found → return 1 (next-cycle retry).
	local merged_pr_num=""
	if [[ -n "$oimp_lookup" ]]; then
		merged_pr_num=$(printf '%s' "$oimp_lookup" \
			| grep -oE "\|${issue_num}=[0-9]+" 2>/dev/null \
			| head -1 \
			| cut -d= -f2) || merged_pr_num=""
	fi
	[[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]] || return 1

	# Body keyword check is built into the lookup builder — the jq scan
	# only emits pairs from PR bodies actually containing
	# Resolves|Closes|Fixes #N. The previous `gh pr view ... body` re-grep
	# is now redundant and removed (t2985).

	if [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$merged_pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — PR #${merged_pr_num} does not touch issue files (GH#17372)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: linked PR #${merged_pr_num} was already merged. Detected by reconcile pass." \
		>/dev/null 2>&1 || return 1

	if declare -F fast_fail_reset >/dev/null 2>&1; then
		fast_fail_reset "$issue_num" "$slug" || true
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_num" "$slug"
	fi
	echo "[pulse-wrapper] Reconcile merged-PR: closed #${issue_num} in ${slug} — merged PR #${merged_pr_num}" >>"$LOGFILE"
	return 0
}

# t2776: globals set by _action_cpt_single to communicate multi-outcome results.
# Initialized to 0 before each call; set to 1 when the respective action fires.
_SP_CPT_CLOSED=0
_SP_CPT_NUDGED=0
_SP_CPT_ESCALATED=0

#######################################
# Stage 4 action: reconcile a parent-task issue (close/nudge/escalate).
# (Per-issue body of reconcile_completed_parent_tasks — no slug loop.)
#
# Sets _SP_CPT_CLOSED / _SP_CPT_NUDGED / _SP_CPT_ESCALATED globals (each 0|1)
# to communicate which actions were taken. Caller reads and resets these.
#
# Args:
#   $1=slug, $2=issue_num, $3=issue_title, $4=issue_body
#   $5=can_close (1|0), $6=can_nudge (1|0), $7=can_escalate (1|0)
#   $8=escalation_threshold_hours
# Returns: 0 always (action outcomes via globals)
#######################################
_action_cpt_single() {
	local slug="$1" issue_num="$2" issue_title="$3" issue_body="$4"
	local can_close="${5:-0}" can_nudge="${6:-0}" can_escalate="${7:-0}"
	local escalation_threshold_hours="${8:-168}"
	_SP_CPT_CLOSED=0
	_SP_CPT_NUDGED=0
	_SP_CPT_ESCALATED=0

	# Child detection (GH#20872): UNION of (graph, body, prose) sources, not
	# first-non-empty-wins (the pre-GH#20872 behaviour). Real-world parent
	# bodies frequently have a partially-populated sub-issue graph where some
	# children are wired via GraphQL `sub_issues` and others only listed in
	# the body's `## Children` section or referenced in prose. First-wins made
	# the smaller graph result silently mask the larger body listing — the
	# child_count guard then blocked auto-close on parents whose children were
	# all closed (canonical: #20559, #20581 during v3.11.1 deploy verification).
	#
	# Source label remains informative: dash-joined list of contributing
	# sources (e.g. `graph+body`, `body`, `graph+body+prose`) so the log line
	# in `_try_close_parent_tracker` records which extractors found children.
	# t2841: explicit init — under set -u, _b_nums is referenced at the
	# union step below regardless of whether children_section is
	# non-empty. Without init, an issue body with no children-section
	# triggers `_b_nums: unbound variable` and aborts the function.
	local _g_nums="" _b_nums="" _p_nums="" child_nums=""
	local _src_parts=""
	_g_nums=$(_fetch_subissue_numbers "$slug" "$issue_num" | sort -un | grep -v "^${issue_num}$" | grep -v '^$' || true)
	[[ -n "$_g_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}graph"

	local children_section
	children_section=$(_extract_children_section "$issue_body")
	if [[ -n "$children_section" ]]; then
		_b_nums=$(printf '%s' "$children_section" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un | grep -v "^${issue_num}$" || true)
		[[ -n "$_b_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}body"
	fi

	_p_nums=$(_extract_children_from_prose "$issue_body" | grep -v "^${issue_num}$" || true)
	[[ -n "$_p_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}prose"

	# Union: concatenate, keep numeric lines, dedupe, drop self-reference
	child_nums=$(printf '%s\n%s\n%s\n' "$_g_nums" "$_b_nums" "$_p_nums" \
		| grep -E '^[0-9]+$' | sort -un | grep -v "^${issue_num}$" || true)
	local child_source="${_src_parts:-none}"

	if [[ -z "$child_nums" ]]; then
		# No children — try phase extractor, then nudge/escalate (t2771/t2388/t2442)
		local _phase_extractor="${_PIR_SCRIPT_DIR}/parent-task-phase-extractor.sh"
		if [[ -x "$_phase_extractor" ]]; then
			if PHASE_EXTRACTOR_DRY_RUN="${PHASE_EXTRACTOR_DRY_RUN:-0}" \
				"$_phase_extractor" run "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase-extractor filed children for #${issue_num} in ${slug} (t2771)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if [[ "$can_nudge" == "1" ]]; then
			if _post_parent_decomposition_nudge "$slug" "$issue_num" "$issue_title"; then
				_SP_CPT_NUDGED=1
			fi
		fi
		if [[ "$can_escalate" == "1" ]]; then
			local _nudge_age_hours
			_nudge_age_hours=$(_compute_parent_nudge_age_hours "$slug" "$issue_num")
			if [[ "$_nudge_age_hours" =~ ^[0-9]+$ ]] && \
				[[ "$_nudge_age_hours" -ge "$escalation_threshold_hours" ]]; then
				if _post_parent_decomposition_escalation "$slug" "$issue_num" "$issue_title"; then
					_SP_CPT_ESCALATED=1
				fi
			fi
		fi
		return 0
	fi

	if [[ "$can_close" == "1" ]]; then
		if _try_close_parent_tracker "$slug" "$issue_num" "$child_nums" "$child_source" "$issue_body"; then
			_SP_CPT_CLOSED=1
		fi
	fi
	return 0
}
