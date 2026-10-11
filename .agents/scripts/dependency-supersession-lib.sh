#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# dependency-supersession-lib.sh — shared "closed as superseded" blocker rule
# (GH#34341).
#
# Consolidation comments "Superseded by #S" on the original issue, labels it
# consolidated and closes it not planned, while native blockedBy edges keep
# pointing at the closed original. A CLOSED blocker is therefore not proof
# that the dependency's work exists: follow trusted supersession comments and
# report the dependency outstanding while the successor chain is still open.
#
# Sourced by pulse-dep-graph.sh and dependency-event-reconciler.sh.

[[ -n "${_DEPENDENCY_SUPERSESSION_LIB_LOADED:-}" ]] && return 0
_DEPENDENCY_SUPERSESSION_LIB_LOADED=1

DEP_SUPERSESSION_DETAIL=""

#######################################
# Closure reasons that can mean "continued elsewhere". COMPLETED and legacy
# empty reasons keep the closed-means-resolved rule.
# Args: $1 - stateReason (GraphQL enum or REST spelling)
# Returns: 0 when the reason needs a supersession check; 1 otherwise.
#######################################
dep_supersession_reason_applies() {
	local reason="$1"
	case "$reason" in
	NOT_PLANNED | not_planned | DUPLICATE | duplicate) return 0 ;;
	esac
	return 1
}

#######################################
# Read one hop and print "STATE|REASON|SUCCESSOR" (successor may be empty).
# aidevops:trust-boundary — only OWNER/MEMBER/COLLABORATOR comments whose first
# non-blank line starts "Superseded by #N" can name a successor; newest wins.
# Args: $1 - repo slug, $2 - issue or PR number
# Returns: 0 on a complete, cost-metered response; 1 otherwise.
#######################################
_dep_supersession_fetch() {
	local repo="$1"
	local number="$2"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local response="" reported_cost=""
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="dependency-supersession-exact-cost" \
		gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner, name:$name) {
    issueOrPullRequest(number:$number) {
      __typename
      ... on Issue { state stateReason comments(last: 100) { nodes { authorAssociation body } } }
      ... on PullRequest { state }
    }
  }
  rateLimit { cost }
}' -F owner="$owner" -F name="$name" -F number="$number" 2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$response" | jq -er '
		.data.repository.issueOrPullRequest
		| select(type == "object" and (.state | type) == "string")
		| [.state, (.stateReason // ""),
			([(.comments.nodes // [])[]
				| select(type == "object")
				| select((.authorAssociation // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
				| (.body // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | (.[0] // "")
				| capture("^\\s*Superseded by #(?<n>[0-9]+)\\b"; "i") | .n] | last // "")]
		| join("|")' 2>/dev/null
	return $?
}

# Case-insensitive "owner/repo#N" comparison (GitHub slugs are case-insensitive).
_dep_supersession_same_ref() {
	local left="$1"
	local right="$2"
	[[ -n "$left" && -n "$right" ]] || return 1
	[[ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]]
	return $?
}

#######################################
# Decide whether a closed blocker's work still lives in an open successor.
# Readiness checks only (dispatch, refresh, unblock); completion checks keep
# the closed-means-resolved rule.
# Args: $1 - blocker repo slug, $2 - blocker number,
#       $3 - stateReason the caller read with the CLOSED state,
#       $4 - optional dependant reference "owner/repo#N"
# Returns: 0 when superseded work is outstanding or cannot be verified (fail
#          closed; DEP_SUPERSESSION_DETAIL says why); 1 when the blocker was
#          not superseded or its successor chain finished.
#######################################
dep_supersession_outstanding() {
	local repo="$1"
	local number="$2"
	local reason="${3:-}"
	local dependant_ref="${4:-}"
	local origin="$number"
	local max_hops="${DEP_SUPERSESSION_MAX_HOPS:-3}"
	local hops=0 seen="," row="" state="" successor=""
	DEP_SUPERSESSION_DETAIL=""
	# COMPLETED, legacy empty and other reasons need no request.
	dep_supersession_reason_applies "$reason" || return 1
	[[ "$max_hops" =~ ^[1-9]$ ]] || max_hops=3
	if [[ ! "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ || ! "$number" =~ ^[1-9][0-9]*$ ]]; then
		DEP_SUPERSESSION_DETAIL="invalid blocker reference"
		return 0
	fi
	while [[ "$hops" -le "$max_hops" ]]; do
		row=$(_dep_supersession_fetch "$repo" "$number") || {
			DEP_SUPERSESSION_DETAIL="supersession lookup failed for #${number}"
			return 0
		}
		IFS='|' read -r state reason successor <<<"$row"
		case "$state" in
		CLOSED | MERGED) ;;
		OPEN)
			DEP_SUPERSESSION_DETAIL="successor #${number} of #${origin} is open"
			[[ "$hops" -gt 0 ]] || DEP_SUPERSESSION_DETAIL="#${origin} is open again"
			return 0
			;;
		*)
			DEP_SUPERSESSION_DETAIL="#${number} has unknown state '${state}'"
			return 0
			;;
		esac
		dep_supersession_reason_applies "$reason" || return 1
		[[ "$successor" =~ ^[1-9][0-9]*$ ]] || return 1
		# The dependant itself absorbed the work; waiting on it would deadlock.
		_dep_supersession_same_ref "${repo}#${successor}" "$dependant_ref" && return 1
		seen="${seen}${number},"
		if [[ "$seen" == *",${successor},"* ]]; then
			DEP_SUPERSESSION_DETAIL="supersession cycle at #${successor}"
			return 0
		fi
		number="$successor"
		hops=$((hops + 1))
	done
	DEP_SUPERSESSION_DETAIL="supersession chain from #${origin} exceeds ${max_hops} hops"
	return 0
}

#######################################
# dep_supersession_outstanding plus one log line when the dependant must wait.
# Logs to $LOGFILE when set (pulse), otherwise stderr.
# Args: $1 - log prefix, $2..$5 - as dep_supersession_outstanding
# Returns: 0 when the dependant must stay blocked; 1 otherwise.
#######################################
dep_supersession_blocks() {
	local log_prefix="$1"
	local repo="$2"
	local number="$3"
	local reason="$4"
	local dependant_ref="${5:-}"
	local message=""
	dep_supersession_outstanding "$repo" "$number" "$reason" "$dependant_ref" || return 1
	message="${log_prefix} blocker ${repo}#${number} closed ${reason} but ${DEP_SUPERSESSION_DETAIL} — keeping blocked (GH#34341)"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '%s\n' "$message" >>"$LOGFILE" || true
	else
		printf '%s\n' "$message" >&2
	fi
	return 0
}
