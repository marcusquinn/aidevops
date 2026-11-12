#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-actions-parent.sh -- Parent-task child detection and close-contract helpers
# =============================================================================
# Split from pulse-issue-reconcile-actions.sh (GH#37574) to keep the
# orchestrator under the 2000-line file-size-debt gate. Functions moved
# verbatim; no behavioural changes.
#
# Sourced by pulse-issue-reconcile-actions.sh. Do NOT invoke directly.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-actions-parent.sh"
#
# Dependencies:
#   - shared-constants.sh and the pulse-wrapper.sh configuration constants
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_ISSUE_RECONCILE_ACTIONS_PARENT_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ACTIONS_PARENT_LOADED=1

#######################################
# Fetch mergedAt for a PR using the shared wrapper when available.
# The wrapper adds REST fallback, telemetry, and exact-output caching under
# GraphQL budget pressure. Raw gh remains as a fallback because this file is
# also sourced by isolated tests and partial deployments.
# Args: $1 = PR number, $2 = slug (owner/name)
# Stdout: mergedAt timestamp or empty
#######################################
_pir_pr_merged_at() {
	local pr_num="$1" slug="$2"
	[[ -n "$pr_num" && -n "$slug" ]] || return 1
	if declare -F gh_pr_view >/dev/null 2>&1; then
		gh_pr_view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null
		return $?
	fi
	gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null
	return $?
}

#######################################
# Fetch sub-issue numbers via GitHub GraphQL (t2138).
#
# Uses the native `subIssues` relationship on the issue node. Returns
# newline-separated child issue numbers on stdout. A complete empty graph
# returns success with empty output so legacy body evidence remains usable.
# API, metering, projection, and pagination failures return non-zero so callers
# can defer every mutation rather than confuse unavailable evidence with an
# authoritative empty graph.
#
# Args: $1 = slug (owner/name), $2 = issue number
#######################################
_fetch_subissue_numbers() {
	local slug="$1" issue_num="$2"
	[[ "$slug" == */* ]] || return 1
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 1

	local owner="${slug%%/*}" name="${slug##*/}"
	# t2138: fetch pageInfo alongside nodes so we can fail-closed when
	# hasNextPage is true. Partial child lists would silently let the
	# reconciler close parents before the tail children are checked.
	# The jq filter returns `PAGINATED` when hasNextPage=true so this source is
	# marked unavailable instead of authorizing a partial-union close.
	local graphql_response="" graphql_result="" reported_cost=""
	# shellcheck disable=SC2016  # GraphQL variable markers ($owner/$name/$number) are intentional literals, not bash expansions
	graphql_response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-subissues-exact-cost" \
		gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){subIssues(first:50){nodes{number state}pageInfo{hasNextPage}}}}rateLimit{cost}}' \
		-F "owner=$owner" -F "name=$name" -F "number=$issue_num" \
		2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$graphql_response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$graphql_response" | jq -e '
		try (
			(.errors? // []) as $errors |
			.data.repository.issue.subIssues as $subissues |
			($errors | type) == "array" and
			($errors | length) == 0 and
			($subissues | type) == "object" and
			($subissues.nodes | type) == "array" and
			($subissues.pageInfo | type) == "object" and
			($subissues.pageInfo.hasNextPage | type) == "boolean" and
			all($subissues.nodes[]; (.number | type) == "number")
		) catch false
	' >/dev/null 2>&1 || return 1
	graphql_result=$(printf '%s' "$graphql_response" | jq -r \
		'if .data.repository.issue.subIssues.pageInfo.hasNextPage then "PAGINATED" else (.data.repository.issue.subIssues.nodes[] | .number) end' \
		2>/dev/null) || return 1

	# A partial native graph can hide an open child omitted from the body.
	if [[ "$graphql_result" == "PAGINATED" ]]; then
		return 1
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
# Extract child issue numbers from trusted roadmap comments.
#
# Parent creation can publish a dependency roadmap as a maintainer comment
# while leaving the immutable original body unchanged. Reconciliation used to
# ignore that durable declaration and falsely report zero children. Restrict
# this source to trusted author associations and an explicit roadmap/children
# heading so arbitrary prose references cannot affect parent closure.
#
# Arguments:
#   arg1 - repository slug
#   arg2 - parent issue number
# Outputs: one child issue number per line, deduplicated and sorted.
# Returns: 0=complete read (including no matching comments), 1=unavailable.
#######################################
_fetch_children_from_trusted_roadmap_comments() {
	local slug="$1"
	local issue_num="$2"
	[[ -n "$slug" ]] || return 1
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 1

	local trusted_bodies=""
	trusted_bodies=$(gh api --paginate "repos/${slug}/issues/${issue_num}/comments" \
		--jq '.[] | select((.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") and (.body | test("(?im)^##[[:space:]]+(Dispatch roadmap|Children|Child issues|Sub-tasks)[[:space:]]*$"))) | .body' \
		2>/dev/null) || return 1
	printf '%s\n' "$trusted_bodies" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Dispatch roadmap|Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ { in_section = 1; next }
		in_section && /^##[[:space:]]/ { in_section = 0 }
		in_section { print }
	' | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un || true
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
	# rejects). Per-page jq emits matching .created_at values; draining sed
	# yields the first match across all pages (chronological order = oldest,
	# which is what the 7-day escalation gate wants).
	local nudge_created_at
	nudge_created_at=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq '.[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .created_at' \
		2>/dev/null | sed -n '1p') || nudge_created_at=""
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

# Machine-readable parent close-contract result. The predicate below resets
# these globals on every call so callers can explain and repair an incomplete
# contract without reparsing the body.
_PARENT_CLOSE_CONTRACT_REASON=""
_PARENT_CLOSE_CONTRACT_DECLARED=0
_PARENT_CLOSE_CONTRACT_UNFILED=""
_PARENT_CLOSE_CONTRACT_LIVE_BODY_UNAVAILABLE="live-body-unavailable"
_PIR_JSON_TYPE_STRING=string
_PIR_JSON_TYPE_ARRAY=array
_PIR_JSON_TYPE_OBJECT=object
_PIR_LIVE_PARENT_JSON=""
_PIR_RECENT_PARENT_REOPENED=0
_PIR_RECENT_PARENT_SCANNED=0
_PIR_RECENT_PARENT_REPOS_SCANNED=0
_PIR_RECENT_PARENT_CYCLE_REOPENED=0
_PIR_RECENT_PARENT_CYCLE_CANDIDATES=0
_PIR_CPT_VERIFIED_CHILD_COUNT=0
_PIR_CPT_VERIFIED_CHILD_SUMMARY=""
_PIR_CPT_REPAIR_REASON=""
# Parent mutation kinds and trust bases (see _pir_live_parent_trust_is_allowed).
_PIR_PARENT_MUTATION_CLOSE=close
_PIR_PARENT_TRUST_TRUSTED=trusted
_PIR_PARENT_TRUST_STALE_APPROVED_CLOSE=stale-approved-terminal-close
_PIR_PARENT_TRUST_BASIS="$_PIR_PARENT_TRUST_TRUSTED"
_PIR_EXTERNAL_GATE_VERIFICATION=""
_PIR_APPROVAL_STALE=STALE_APPROVAL
_PIR_EXTERNAL_CONTRIBUTOR_LABEL=external-contributor

_parent_comments_api_path() {
	local slug="$1" parent_num="$2"
	printf 'repos/%s/issues/%s/comments\n' "$slug" "$parent_num"
	return 0
}

_PARENT_CLOSE_CONTRACT_NEEDS_DECOMPOSITION_MARKER='<!-- parent-close-contract: needs-decomposition -->'
_PARENT_CLOSE_CONTRACT_KEEP_OPEN_MARKER='<!-- parent-close-contract: keep-open -->'
# Exact recovery steps for the provisional creation-time marker (GH#37679).
_PARENT_CLOSE_CONTRACT_DECOMPOSITION_STEPS="This parent still carries the provisional creation-time marker \`<!-- parent-close-contract: needs-decomposition -->\`. To let it close: (1) add a \`## Children\` section to the parent body listing every child issue, one \`- #NNN\` line each, and include every native sub-issue in that list; (2) replace the marker with \`<!-- parent-close-contract: expected-children=N -->\`, where N is the number of children, or with \`<!-- parent-close-contract: complete -->\` if no more children are planned. Reconciliation then closes the parent once every child is closed."
_PARENT_CLOSE_CONTRACT_KEEP_OPEN_STEPS="This parent is explicitly marked \`<!-- parent-close-contract: keep-open -->\`, so it never closes automatically. When the objective is finished, replace that marker with \`<!-- parent-close-contract: complete -->\` and rerun reconciliation or close the parent."

#######################################
# GH#37679: decide whether a parent has declared its decomposition, which
# satisfies the provisional needs-decomposition marker. The declaration must be
# an explicit child list (body `## Children` / `## Child issues` /
# `## Sub-tasks` section or a trusted roadmap comment), every known child must
# already be verified terminal, and every native sub-issue must appear in the
# declared list. Graph-only children never satisfy the marker.
# Args: $1=declared child numbers, $2=native graph child numbers,
#       $3=children terminal flag (1 = every known child verified terminal)
# Returns: 0=declared and terminal, 1=otherwise
#######################################
_parent_decomposition_declared() {
	local declared_nums="$1" graph_nums="$2" children_terminal="${3:-0}"
	local graph_num="" declared_set=""
	[[ "$children_terminal" == "1" ]] || return 1
	[[ "$declared_nums" =~ [0-9] ]] || return 1
	declared_set=$'\n'"${declared_nums}"$'\n'
	while IFS= read -r graph_num; do
		[[ "$graph_num" =~ ^[0-9]+$ ]] || continue
		[[ "$declared_set" == *$'\n'"${graph_num}"$'\n'* ]] || return 1
	done <<<"$graph_nums"
	return 0
}

#######################################
# Decide whether deterministic parent-body evidence blocks closure.
# Backward compatibility is deliberate: legacy parents with no contract and
# no unchecked criteria remain closable once every known child is terminal.
#
# Recognised contracts:
#   - canonical ## Phases rows (every row must contain a child reference)
#   - <!-- parent-close-contract: expected-children=N -->
#   - <!-- parent-close-contract: complete -->
#   - <!-- parent-close-contract: keep-open --> (explicit, always blocks)
#   - <!-- parent-close-contract: needs-decomposition --> (provisional
#     creation-time default; satisfied once the decomposition is declared, see
#     _parent_decomposition_declared)
# Unchecked Markdown task-list criteria also block closure.
#
# A complete native sub-issue graph is the authoritative decomposition record.
# Once every graph child is terminal (verified by the caller), stale unchecked
# tracker criteria do not keep the parent open. Explicit keep-open and expected
# child contracts still win.
# Args: $1=parent_body, $2=known_child_count, $3=child evidence source,
#       $4=declared child numbers, $5=native graph child numbers,
#       $6=children terminal flag (1 only when the caller verified every known
#          child is terminal). Omitted declaration evidence fails closed.
# Returns: 0=incomplete, 1=complete or legacy-unknown
#######################################
_parent_close_contract_incomplete() {
	local parent_body="$1"
	local known_child_count="${2:-0}"
	local child_source="${3:-}"
	local declared_nums="${4:-}" graph_nums="${5:-}" children_terminal="${6:-0}"
	local native_graph_complete=0
	_PARENT_CLOSE_CONTRACT_REASON=""
	_PARENT_CLOSE_CONTRACT_DECLARED=0
	_PARENT_CLOSE_CONTRACT_UNFILED=""
	[[ -n "$parent_body" ]] || return 1
	case "+${child_source}+" in
	*+graph+*)
		[[ "$known_child_count" -gt 0 ]] && native_graph_complete=1
		;;
	esac

	local phases_section="" unfiled_count=0
	phases_section=$(_parse_phases_section "$parent_body")
	if [[ -n "$phases_section" ]]; then
		_PARENT_CLOSE_CONTRACT_DECLARED=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ { c++ } END { print c+0 }')
		_PARENT_CLOSE_CONTRACT_UNFILED=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { printf "Phase %s: %s\n", $1, $2 }')
		unfiled_count=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { c++ } END { print c+0 }')
		if [[ "$unfiled_count" -gt 0 ]] &&
			[[ "$native_graph_complete" -eq 0 || "$known_child_count" -lt "$_PARENT_CLOSE_CONTRACT_DECLARED" ]]; then
			_PARENT_CLOSE_CONTRACT_REASON="unfiled-phases"
			return 0
		fi
	fi

	local expected_children=""
	expected_children=$(printf '%s\n' "$parent_body" |
		sed -nE 's/.*<!-- parent-close-contract: expected-children=([0-9]+) -->.*/\1/p' | sed -n '1p')
	if [[ "$expected_children" =~ ^[0-9]+$ ]] && [[ "$known_child_count" -lt "$expected_children" ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="expected-children:${expected_children}"
		return 0
	fi

	if [[ "$parent_body" == *"<!-- parent-close-contract: phase-plan -->"* &&
		"$_PARENT_CLOSE_CONTRACT_DECLARED" -eq 0 ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="invalid-phase-plan"
		return 0
	fi
	if [[ "$parent_body" == *"$_PARENT_CLOSE_CONTRACT_KEEP_OPEN_MARKER"* ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="keep-open"
		return 0
	fi
	if [[ "$parent_body" == *"$_PARENT_CLOSE_CONTRACT_NEEDS_DECOMPOSITION_MARKER"* ]] &&
		! _parent_decomposition_declared "$declared_nums" "$graph_nums" "$children_terminal"; then
		_PARENT_CLOSE_CONTRACT_REASON="needs-decomposition"
		return 0
	fi
	if [[ "$native_graph_complete" -eq 0 ]] &&
		printf '%s\n' "$parent_body" | grep -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' >/dev/null; then
		_PARENT_CLOSE_CONTRACT_REASON="unchecked-criteria"
		return 0
	fi

	return 1
}

#######################################
# Extract a string body from a complete live issue object.
# Args: $1=live issue JSON
# Stdout: exact body string
# Returns: 0=string body found, 1=missing, malformed, or non-string body
#######################################
_pir_parent_body_from_json() {
	local live_issue_json="$1"
	printf '%s' "$live_issue_json" | jq -er --arg string_type "$_PIR_JSON_TYPE_STRING" \
		'select((type | test("^object$")) and has("body") and (.body | type) == $string_type) | .body' \
		2>/dev/null
	return $?
}

#######################################
# Extract a non-empty revision timestamp from a complete live issue object.
# Args: $1=live issue JSON
# Stdout: updated_at/updatedAt string
# Returns: 0=revision found, 1=missing, malformed, or non-string revision
#######################################
_pir_parent_revision_from_json() {
	local live_issue_json="$1"
	printf '%s' "$live_issue_json" | jq -er --arg string_type "$_PIR_JSON_TYPE_STRING" '
		(.updated_at // .updatedAt) |
		select(type == $string_type and length > 0)
	' 2>/dev/null
	return $?
}

#######################################
# Apply the parent close contract to a freshly fetched issue object. A missing
# or non-string body is ambiguous and therefore blocks closure, while an
# explicitly empty body preserves the legacy compatibility contract.
# Args: $1=live_issue_json, $2=known_child_count, $3=child evidence source,
#       $4=declared child numbers, $5=native graph child numbers,
#       $6=children terminal flag (see _parent_close_contract_incomplete)
# Returns: 0=incomplete or ambiguous, 1=complete or legacy-unknown
#######################################
_parent_live_close_contract_incomplete() {
	local live_issue_json="$1"
	local known_child_count="${2:-0}"
	local child_source="${3:-}"
	local declared_nums="${4:-}" graph_nums="${5:-}" children_terminal="${6:-0}"
	local live_body=""
	if ! live_body=$(_pir_parent_body_from_json "$live_issue_json"); then
		_PARENT_CLOSE_CONTRACT_REASON="$_PARENT_CLOSE_CONTRACT_LIVE_BODY_UNAVAILABLE"
		_PARENT_CLOSE_CONTRACT_DECLARED=0
		_PARENT_CLOSE_CONTRACT_UNFILED=""
		return 0
	fi
	_parent_close_contract_incomplete "$live_body" "$known_child_count" "$child_source" \
		"$declared_nums" "$graph_nums" "$children_terminal"
	return $?
}

#######################################
# Post a one-time worker-ready explanation for a non-phase close-contract
# failure. The caller supplies the marker so open-parent nudges and closed-
# parent repairs each remain independently idempotent.
# Args: $1=slug, $2=parent_num, $3=reason, $4=marker
# Returns: 0=posted, 1=already present or API/comment failure
#######################################
_post_parent_close_contract_nudge() {
	local slug="$1" parent_num="$2" reason="$3" marker="$4"
	local existing="" comments_api=""
	comments_api=$(_parent_comments_api_path "$slug" "$parent_num")
	existing=$(gh api --paginate "$comments_api" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""
	[[ "$existing" =~ ^[0-9]+$ ]] || return 1
	[[ "$existing" -eq 0 ]] || return 1

	local guidance="Complete the declared decomposition and update the parent close contract before closure."
	case "$reason" in
	needs-decomposition)
		guidance="$_PARENT_CLOSE_CONTRACT_DECOMPOSITION_STEPS"
		;;
	keep-open)
		guidance="$_PARENT_CLOSE_CONTRACT_KEEP_OPEN_STEPS"
		;;
	expected-children:*)
		guidance="Link all ${reason#expected-children:} expected child issues, then rerun reconciliation."
		;;
	unchecked-criteria)
		guidance="Resolve or check every remaining parent acceptance criterion, then rerun reconciliation."
		;;
	invalid-phase-plan)
		guidance="Rewrite the phase plan in canonical list or bold phase form and link each filed child."
		;;
	esac

	local comment_body="${marker}
## Parent Tracker: Close Contract Incomplete

Reconciliation found deterministic evidence that this parent objective is not complete (${reason}). The parent remains open so declared work is not lost.

**Recovery:** ${guidance}

_Posted once by parent close-contract reconciliation._"
	gh_issue_comment "$parent_num" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 || return 1
	return 0
}

_mark_parent_review_hold() {
	local slug="$1" parent_num="$2"
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$parent_num" --repo "$slug" \
			--add-label "hold-for-review" >/dev/null 2>&1 || true
	else
		gh issue edit "$parent_num" --repo "$slug" \
			--add-label "hold-for-review" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Verify that a live parent is still an automation-completed close whose body
# deterministically requires repair. Intentional or unknown close reasons fail
# closed. Sets _PIR_CPT_REPAIR_REASON on success.
# Args: $1=live issue JSON, $2=known child count, $3=child evidence source,
#       $4=declared child numbers, $5=native graph child numbers,
#       $6=children terminal flag (see _parent_close_contract_incomplete)
# Returns: 0=repairable, 1=not repairable or ambiguous
#######################################
_pir_closed_parent_repair_reason() {
	local live_issue_json="$1" known_child_count="$2" child_source="${3:-}"
	local declared_nums="${4:-}" graph_nums="${5:-}" children_terminal="${6:-0}"
	_PIR_CPT_REPAIR_REASON=""
	printf '%s' "$live_issue_json" | jq -e --arg string_type "$_PIR_JSON_TYPE_STRING" '
		(.state_reason // .stateReason) as $reason |
		(.state // "" | ascii_downcase) == "closed" and
		($reason | type) == $string_type and
		($reason | ascii_downcase | . == "completed")
	' >/dev/null 2>&1 || return 1
	_parent_live_close_contract_incomplete "$live_issue_json" "$known_child_count" "$child_source" \
		"$declared_nums" "$graph_nums" "$children_terminal" || return 1
	[[ "$_PARENT_CLOSE_CONTRACT_REASON" != "$_PARENT_CLOSE_CONTRACT_LIVE_BODY_UNAVAILABLE" ]] || return 1
	_PIR_CPT_REPAIR_REASON="$_PARENT_CLOSE_CONTRACT_REASON"
	return 0
}

#######################################
# Report whether every known child of a closed parent is terminal, for the
# provisional needs-decomposition contract only (GH#37679). Other contracts do
# not depend on it, so their repair decisions spend no extra child reads.
# Args: $1=slug, $2=newline-separated child numbers, $3=parent body
# Stdout: 1 when the marker is present and every child verifies closed, else 0
#######################################
_pir_cpt_children_terminal_flag() {
	local slug="$1" child_nums="$2" parent_body="$3"
	if [[ "$parent_body" == *"$_PARENT_CLOSE_CONTRACT_NEEDS_DECOMPOSITION_MARKER"* ]] &&
		_pir_verify_parent_children_closed "$slug" "$child_nums"; then
		printf '1\n'
		return 0
	fi
	printf '0\n'
	return 0
}

#######################################
# Reopen a recently closed parent only when deterministic close-contract
# evidence proves that closure was premature. The repair marker makes retries
# no-ops even if another automation closes the parent again.
# Args: $1=slug, $2=parent_num
# Returns: 0=reopened, 1=already repaired or API failure
#######################################
_repair_closed_parent_contract() {
	local slug="$1" parent_num="$2"
	local marker='<!-- parent-close-contract-repaired -->'
	local existing="" existing_ids="" comments_api="" reason=""
	local first_body="" first_revision="" first_child_nums="" first_child_source=""
	local final_body="" final_revision="" final_child_nums="" final_child_source=""
	local final_child_count=0 children_terminal=0
	comments_api=$(_parent_comments_api_path "$slug" "$parent_num")
	existing_ids=$(gh api --paginate "$comments_api" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null) || return 1
	existing=$(printf '%s\n' "$existing_ids" | awk 'NF { count++ } END { print count+0 }')
	[[ "$existing" =~ ^[0-9]+$ ]] || return 1
	[[ "$existing" -eq 0 ]] || return 1

	# Build two complete live evidence snapshots, then perform one final parent
	# revision/reason fence immediately before reopen. Cached list bodies and
	# counts are discovery hints only and never authorize repair.
	_pir_parent_mutation_is_allowed "$slug" "$parent_num" closed || return 1
	first_body=$(_pir_parent_body_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	first_revision=$(_pir_parent_revision_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	_pir_collect_parent_child_evidence "$slug" "$parent_num" "$first_body" || return 1
	first_child_nums="$_PIR_CPT_CHILD_NUMS"
	first_child_source="$_PIR_CPT_CHILD_SOURCE"
	children_terminal=$(_pir_cpt_children_terminal_flag "$slug" "$first_child_nums" "$first_body")
	_pir_closed_parent_repair_reason "$_PIR_LIVE_PARENT_JSON" "$_PIR_CPT_KNOWN_CHILD_COUNT" \
		"$_PIR_CPT_CHILD_SOURCE" "$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" \
		"$children_terminal" || return 1

	_pir_parent_mutation_is_allowed "$slug" "$parent_num" closed || return 1
	final_body=$(_pir_parent_body_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	final_revision=$(_pir_parent_revision_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	[[ "$final_body" == "$first_body" && "$final_revision" == "$first_revision" ]] || return 1
	_pir_collect_parent_child_evidence "$slug" "$parent_num" "$final_body" || return 1
	final_child_nums="$_PIR_CPT_CHILD_NUMS"
	final_child_source="$_PIR_CPT_CHILD_SOURCE"
	final_child_count="$_PIR_CPT_KNOWN_CHILD_COUNT"
	[[ "$final_child_nums" == "$first_child_nums" && \
		"$final_child_source" == "$first_child_source" ]] || return 1
	# Re-read child terminality from the final snapshot so a child changing
	# state between snapshots cannot flip the reopen decision (GH#37679).
	local final_children_terminal=0
	final_children_terminal=$(_pir_cpt_children_terminal_flag "$slug" "$final_child_nums" "$final_body")
	[[ "$final_children_terminal" == "$children_terminal" ]] || return 1

	_pir_parent_mutation_is_allowed "$slug" "$parent_num" closed || return 1
	[[ "$(_pir_parent_body_from_json "$_PIR_LIVE_PARENT_JSON")" == "$final_body" ]] || return 1
	[[ "$(_pir_parent_revision_from_json "$_PIR_LIVE_PARENT_JSON")" == "$final_revision" ]] || return 1
	_pir_closed_parent_repair_reason "$_PIR_LIVE_PARENT_JSON" "$final_child_count" \
		"$final_child_source" "$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" \
		"$children_terminal" || return 1
	reason="$_PIR_CPT_REPAIR_REASON"
	gh issue reopen "$parent_num" --repo "$slug" >/dev/null 2>&1 || return 1
	_post_parent_close_contract_nudge "$slug" "$parent_num" "$reason" "$marker" || true
	_mark_parent_review_hold "$slug" "$parent_num"
	echo "[pulse-wrapper] Reconcile parent-task: reopened #${parent_num} in ${slug} — incomplete close contract (${reason})" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Re-read each known child and build the close summary. The caller invokes this
# for the cached candidate and for each live evidence snapshot before close.
# Args: $1=slug, $2=newline-separated child issue numbers
# Returns: 0=one or more real children and all are closed, 1=otherwise
#######################################
_pir_verify_parent_children_closed() {
	local slug="$1" child_nums="$2"
	local child_num="" child_state="" child_title_line=""
	local all_closed="true"
	_PIR_CPT_VERIFIED_CHILD_COUNT=0
	_PIR_CPT_VERIFIED_CHILD_SUMMARY=""

	while IFS= read -r child_num; do
		[[ -n "$child_num" && "$child_num" =~ ^[0-9]+$ ]] || continue
		child_state=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.state // empty' 2>/dev/null) || child_state=""
		child_title_line=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.title // ""' 2>/dev/null) || child_title_line=""
		# An unreadable child is unresolved evidence, not permission to omit it
		# from the all-closed decision. Fail the whole verification pass closed.
		[[ -n "$child_state" ]] || return 1

		_PIR_CPT_VERIFIED_CHILD_COUNT=$((_PIR_CPT_VERIFIED_CHILD_COUNT + 1))
		case "$child_state" in
		closed | CLOSED)
			_PIR_CPT_VERIFIED_CHILD_SUMMARY="${_PIR_CPT_VERIFIED_CHILD_SUMMARY}
- #${child_num}: ${child_title_line} — ✅ CLOSED"
			;;
		*)
			_PIR_CPT_VERIFIED_CHILD_SUMMARY="${_PIR_CPT_VERIFIED_CHILD_SUMMARY}
- #${child_num}: ${child_title_line} — ⏳ OPEN"
			all_closed="false"
			;;
		esac
	done <<<"$child_nums"

	[[ "$all_closed" == "true" && "$_PIR_CPT_VERIFIED_CHILD_COUNT" -gt 0 ]] || return 1
	return 0
}

_hold_parent_for_incomplete_close_contract() {
	local slug="$1"
	local parent_num="$2"
	local child_count="$3"
	local evidence_source="${4:-cached}"
	if [[ "$_PARENT_CLOSE_CONTRACT_REASON" == "unfiled-phases" ]]; then
		_post_parent_phases_unfiled_nudge "$slug" "$parent_num" \
			"$_PARENT_CLOSE_CONTRACT_DECLARED" "$child_count" \
			"$_PARENT_CLOSE_CONTRACT_UNFILED" || true
	else
		_post_parent_close_contract_nudge "$slug" "$parent_num" \
			"$_PARENT_CLOSE_CONTRACT_REASON" \
			"<!-- parent-close-contract-incomplete:${_PARENT_CLOSE_CONTRACT_REASON} -->" || true
	fi
	_mark_parent_review_hold "$slug" "$parent_num"
	echo "[pulse-wrapper] Reconcile parent-task: kept #${parent_num} open in ${slug} — incomplete close contract (${_PARENT_CLOSE_CONTRACT_REASON}, evidence=${evidence_source})" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Verify that live child evidence, child states, parent body/revision, state,
# labels, and authority remain stable at the final close boundary.
# Args: $1=slug, $2=parent, $3=body, $4=child numbers, $5=child source,
#       $6=initial parent revision
# Returns: 0=stable and closeable, 1=changed or ambiguous
#######################################
_pir_parent_close_snapshot_is_stable() {
	local slug="$1" parent_num="$2" live_parent_body="$3"
	local expected_child_nums="$4" expected_child_source="$5" live_parent_revision="$6"
	local final_parent_body="" final_parent_revision="" child_count=0

	[[ -n "$live_parent_revision" ]] || return 1
	_pir_collect_parent_child_evidence "$slug" "$parent_num" "$live_parent_body" || return 1
	[[ "$_PIR_CPT_CHILD_NUMS" == "$expected_child_nums" && \
		"$_PIR_CPT_CHILD_SOURCE" == "$expected_child_source" ]] || return 1
	_pir_verify_parent_children_closed "$slug" "$_PIR_CPT_CHILD_NUMS" || return 1
	child_count="$_PIR_CPT_VERIFIED_CHILD_COUNT"
	if _parent_close_contract_incomplete "$live_parent_body" "$child_count" \
		"$_PIR_CPT_CHILD_SOURCE" "$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" 1; then
		_hold_parent_for_incomplete_close_contract "$slug" "$parent_num" "$child_count" live
		return 1
	fi

	# No remote reads may sit between this state/authority/body fence and close.
	# The revision check also catches metadata mutations when GitHub supplies it.
	_pir_parent_mutation_is_allowed "$slug" "$parent_num" open "$_PIR_PARENT_MUTATION_CLOSE" || return 1
	final_parent_body=$(_pir_parent_body_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	[[ "$final_parent_body" == "$live_parent_body" ]] || return 1
	final_parent_revision=$(_pir_parent_revision_from_json "$_PIR_LIVE_PARENT_JSON") || return 1
	[[ "$final_parent_revision" == "$live_parent_revision" ]] || return 1
	return 0
}

#######################################
# Verify the cross-resource close postcondition. GitHub does not expose an
# issue-revision compare-and-swap through `gh issue close`, so a successful
# close is immediately re-read and compensated when our completed closure is
# proven stale. Unknown or intentional close reasons never authorize reopen.
# Args: $1=slug, $2=parent, $3=body, $4=child numbers, $5=child source
# Returns: 0=stable completed close, 1=changed or ambiguous
#######################################
_pir_parent_close_postcondition_is_stable() {
	local slug="$1" parent_num="$2" expected_body="$3"
	local expected_child_nums="$4" expected_child_source="$5"
	local live_parent_json="" live_parent_body="" child_count=0
	_PIR_CPT_POST_CLOSE_REOPEN_ALLOWED=0

	live_parent_json=$(gh api "repos/${slug}/issues/${parent_num}" 2>/dev/null) || return 1
	printf '%s' "$live_parent_json" | jq -e --argjson issue "$parent_num" '
		(.number == $issue) and
		((.state // "" | ascii_downcase) == "closed") and
		(.state_reason // .stateReason // "" | ascii_downcase | . == "completed")
	' >/dev/null 2>&1 || return 1
	_PIR_CPT_POST_CLOSE_REOPEN_ALLOWED=1
	_pir_live_parent_trust_is_allowed "$slug" "$parent_num" "$live_parent_json" "$_PIR_PARENT_MUTATION_CLOSE" || return 1
	live_parent_body=$(_pir_parent_body_from_json "$live_parent_json") || return 1
	[[ "$live_parent_body" == "$expected_body" ]] || return 1
	printf '%s' "$live_parent_json" | jq -e --arg parent "${_PIR_PT_LABEL:-parent-task}" \
		--arg nmr "${_PIR_NMR_LABEL:-needs-maintainer-review}" \
		--arg persistent "${_PIR_PERSISTENT_LABEL:-persistent}" \
		--arg string_type "$_PIR_JSON_TYPE_STRING" '
		def names: [.labels[]? | if type == $string_type then . else (.name // empty) end];
		(names | index($parent) != null) and
		(names | index($nmr) == null) and
		(names | index($persistent) == null)
	' >/dev/null 2>&1 || return 1
	_pir_collect_parent_child_evidence "$slug" "$parent_num" "$live_parent_body" || return 1
	[[ "$_PIR_CPT_CHILD_NUMS" == "$expected_child_nums" && \
		"$_PIR_CPT_CHILD_SOURCE" == "$expected_child_source" ]] || return 1
	_pir_verify_parent_children_closed "$slug" "$_PIR_CPT_CHILD_NUMS" || return 1
	child_count="$_PIR_CPT_VERIFIED_CHILD_COUNT"
	_parent_close_contract_incomplete "$live_parent_body" "$child_count" \
		"$_PIR_CPT_CHILD_SOURCE" "$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" 1 && return 1
	return 0
}

_pir_reopen_unstable_parent_close() {
	local slug="$1" parent_num="$2"
	_pir_parent_mutation_is_allowed "$slug" "$parent_num" closed "$_PIR_PARENT_MUTATION_CLOSE" || return 1
	printf '%s' "$_PIR_LIVE_PARENT_JSON" | jq -e '
		(.state_reason // .stateReason // "" | ascii_downcase | . == "completed")
	' >/dev/null 2>&1 || return 1
	gh issue reopen "$parent_num" --repo "$slug" >/dev/null 2>&1 || return 1
	_mark_parent_review_hold "$slug" "$parent_num"
	echo "[pulse-wrapper] Reconcile parent-task: reopened #${parent_num} in ${slug} — post-close evidence changed" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Close a parent, verify the post-close snapshot, and compensate by reopening
# when evidence changed. Args: slug parent_num live_body child_nums child_source
# Returns: 0=closed and stable, 1=close failed or compensated
#######################################
_pir_close_parent_with_postcondition() {
	local slug="$1" parent_num="$2" live_parent_body="$3" child_nums="$4" child_source="$5"
	gh issue close "$parent_num" --repo "$slug" >/dev/null 2>&1 || return 1
	if ! _pir_parent_close_postcondition_is_stable "$slug" "$parent_num" "$live_parent_body" \
		"$child_nums" "$child_source"; then
		if [[ "$_PIR_CPT_POST_CLOSE_REOPEN_ALLOWED" -eq 1 ]]; then
			_pir_reopen_unstable_parent_close "$slug" "$parent_num" || \
				echo "[pulse-wrapper] Reconcile parent-task: unable to compensate unstable close #${parent_num} in ${slug}" >>"${LOGFILE:-/dev/null}"
		fi
		return 1
	fi
	return 0
}

#######################################
# Budget guard for multi-round-trip mutations (GH#34289). Reads the
# single-pass locals _t2984_start_ts/_t2984_budget via dynamic scope. A parent
# close spans several reads, the close, a stability check, an optional reopen
# and a comment; starting one near the budget risks a mid-action stage kill.
# Env: RECONCILE_MUTATION_RESERVE_SECS=reserve seconds (default 90)
# Returns: 0=enough budget (or no budget active), 1=too little remaining
#######################################
_pir_budget_allows_mutation() {
	local reserve="${RECONCILE_MUTATION_RESERVE_SECS:-90}"
	[[ "$reserve" =~ ^[0-9]+$ ]] || reserve=90
	local budget="${_t2984_budget:-0}" start="${_t2984_start_ts:-}"
	[[ "$budget" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 0
	[[ "$budget" -gt 0 ]] || return 0
	[[ $((budget - (SECONDS - start))) -ge "$reserve" ]] || return 1
	return 0
}
