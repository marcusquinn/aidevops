#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse merge REST state helpers: exact mergeability, review history, and
# update-branch transport without native gh GraphQL reads.

[[ -n "${_PULSE_MERGE_REST_STATE_LOADED:-}" ]] && return 0
_PULSE_MERGE_REST_STATE_LOADED=1

# shellcheck source=./shared-gh-collaborator-permission.sh
source "${BASH_SOURCE[0]%/*}/shared-gh-collaborator-permission.sh"

_pmrs_gh_call() {
	local operation="$1"
	shift
	local rc=0

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout "$operation" "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_pmrs_review_max_pages() {
	local max_pages="${AIDEVOPS_PULSE_REVIEW_MAX_PAGES:-10}"
	[[ "$max_pages" =~ ^[0-9]+$ ]] || max_pages=10
	[[ "$max_pages" -ge 1 ]] || max_pages=1
	[[ "$max_pages" -le 100 ]] || max_pages=100
	printf '%s' "$max_pages"
	return 0
}

#######################################
# Normalize PR mergeable values from mixed GitHub API paths.
# Args: $1=raw mergeable value
# Stdout: normalized mergeable enum
#######################################
_pmp_normalize_mergeable_state() {
	local raw_state="$1"
	local normalized_state=""
	case "$raw_state" in
	MERGEABLE|mergeable|true|TRUE) normalized_state="MERGEABLE" ;;
	CONFLICTING|conflicting|false|FALSE) normalized_state="CONFLICTING" ;;
	UNKNOWN|unknown|''|null|NULL) normalized_state="UNKNOWN" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf '%s' "$normalized_state"
	return 0
}

#######################################
# Normalize PR mergeable values into a caller variable.
# Args: $1=destination variable name, $2=raw mergeable value
#######################################
_pmp_normalize_mergeable_state_into() {
	local dest_var="$1"
	local raw_state="$2"
	local normalized_state=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_state" in
	MERGEABLE|mergeable|true|TRUE) normalized_state="MERGEABLE" ;;
	CONFLICTING|conflicting|false|FALSE) normalized_state="CONFLICTING" ;;
	UNKNOWN|unknown|''|null|NULL) normalized_state="UNKNOWN" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_state"
	return 0
}

#######################################
# Refresh empty/UNKNOWN mergeability through the exact single-PR REST route.
# Args: $1=destination var, $2=PR number, $3=repo slug, $4=current state
#######################################
_pmp_refresh_unknown_mergeable_state_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local current_mergeable="$4"
	local refreshed_mergeable=""
	local refresh_exit=0

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_mergeable_state_into refreshed_mergeable "$current_mergeable"

	if [[ "$refreshed_mergeable" == "UNKNOWN" || -z "$refreshed_mergeable" ]]; then
		# STRICT: the REST single-PR read triggers mergeability computation (GH#37368).
		refreshed_mergeable=$(AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_REST_FIRST_STRICT=1 AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 \
			gh_pr_view "$pr_number" --repo "$repo_slug" --json mergeable --jq '.mergeable // ""')
		refresh_exit=$?
		[[ $refresh_exit -eq 0 && -n "$refreshed_mergeable" ]] || refreshed_mergeable="UNKNOWN"
		_pmp_normalize_mergeable_state_into refreshed_mergeable "$refreshed_mergeable"
	fi

	printf -v "$dest_var" '%s' "$refreshed_mergeable"
	return 0
}

#######################################
# Add exact single-PR REST mergeability to every unknown list item.
# Args: $1=repo slug, $2=PR JSON array
#######################################
_pmp_enrich_prs_with_mergeability() {
	local repo_slug="$1"
	local pr_json="$2"
	local enriched_json="$pr_json"
	local rows=""
	local _US=$'\x1f'
	local index="" number="" mergeable=""

	if [[ -z "$repo_slug" ]]; then
		printf '%s' "$pr_json"
		return 0
	fi
	rows=$(printf '%s' "$pr_json" | jq -r '
		if type != "array" then error("expected PR array")
		else to_entries[] | [
			(.key | tostring),
			(if ((.value | has("number") | not) or .value.number == null) then "" else (.value.number | tostring) end),
			(if ((.value | has("mergeable") | not) or .value.mergeable == null or (.value.mergeable | tostring | length) == 0)
			 then "UNKNOWN" else (.value.mergeable | tostring) end)
		] | join("\u001f")
		end' 2>/dev/null) || {
		printf '%s' "$pr_json"
		return 0
	}

	while IFS="$_US" read -r index number mergeable; do
		[[ -n "$index" ]] || continue
		_pmp_normalize_mergeable_state_into mergeable "$mergeable"
		if [[ "$number" =~ ^[0-9]+$ && "$mergeable" == "UNKNOWN" ]]; then
			_pmp_refresh_unknown_mergeable_state_into mergeable "$number" "$repo_slug" "$mergeable"
			enriched_json=$(printf '%s' "$enriched_json" | jq --argjson index "$index" --arg mergeable "$mergeable" '.[$index].mergeable = $mergeable' 2>/dev/null) || {
				printf '%s' "$pr_json"
				return 0
			}
		fi
	done <<<"$rows"

	printf '%s' "$enriched_json"
	return 0
}

_pmp_normalize_review_decision_into() {
	local dest_var="$1"
	local raw_decision="$2"
	local normalized_decision=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_decision" in
	CHANGES_REQUESTED|APPROVED|OBSERVED_APPROVED|REVIEW_REQUIRED|NONE) normalized_decision="$raw_decision" ;;
	changes_requested) normalized_decision="CHANGES_REQUESTED" ;;
	approved) normalized_decision="APPROVED" ;;
	observed_approved) normalized_decision="OBSERVED_APPROVED" ;;
	review_required) normalized_decision="REVIEW_REQUIRED" ;;
	none) normalized_decision="NONE" ;;
	''|null|NULL|UNKNOWN|unknown) normalized_decision="UNKNOWN" ;;
	*) normalized_decision="$raw_decision" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_decision"
	return 0
}

_pmp_review_decision_is_unknown() {
	local raw_decision="$1"
	local checked_decision=""
	_pmp_normalize_review_decision_into checked_decision "$raw_decision"
	[[ "$checked_decision" == "UNKNOWN" ]]
	return $?
}

#######################################
# Fetch review history in explicit, bounded REST pages. Every transport has a
# concrete page number; a full final page at the bound fails closed.
# Args: $1=PR number, $2=repo slug
# Stdout: one flattened JSON review array
#######################################
_pmp_rest_reviews_json() {
	local pr_number="$1"
	local repo_slug="$2"
	local page=1
	local max_pages=10
	local endpoint="" page_json="" page_count=0 reviews_json='[]'

	max_pages=$(_pmrs_review_max_pages)
	while [[ "$page" -le "$max_pages" ]]; do
		if declare -F gh_budget_worker_reserve_allows >/dev/null 2>&1; then
			gh_budget_worker_reserve_allows || return 1
		fi
		endpoint="repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100&page=${page}"
		page_json=$(AIDEVOPS_GH_PAGE_NUMBER="$page" \
			AIDEVOPS_GH_ROUTE_DECISION="pulse-review-explicit-page" \
			_pmrs_gh_call read gh api "$endpoint" 2>/dev/null) || return 1
		printf '%s' "$page_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
		page_count=$(printf '%s' "$page_json" | jq 'length' 2>/dev/null) || return 1
		[[ "$page_count" =~ ^[0-9]+$ ]] || return 1
		reviews_json=$(printf '%s\n%s\n' "$reviews_json" "$page_json" | jq -cs '.[0] + .[1]' 2>/dev/null) || return 1
		if [[ "$page_count" -lt 100 ]]; then
			printf '%s' "$reviews_json"
			return 0
		fi
		page=$((page + 1))
	done
	return 1
}

#######################################
# Derive active review state from each reviewer's latest state-changing review.
# This preserves active blockers and exposes observed approvals without
# fabricating policy-level APPROVED/REVIEW_REQUIRED state that review history
# alone cannot prove.
#######################################
_pmp_rest_review_decision_from_reviews() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json=""

	reviews_json=$(_pmp_rest_reviews_json "$pr_number" "$repo_slug") || return 1
	printf '%s' "$reviews_json" | _pmp_reduce_reviews_json || return 1
	return 0
}

#######################################
# Reduce a REST-shaped review array (stdin) to the active review state.
#######################################
_pmp_reduce_reviews_json() {
	jq -r '
		def state_changing: .state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED";
		if type != "array" then error("expected review array")
		elif any(.[]?; state_changing and (
			(.user | type) != "object"
			or (.user.login | type) != "string"
			or (.user.login | length) == 0
			or (.submitted_at | type) != "string"
			or (.submitted_at | length) == 0
			or (.id | type) != "number"
		)) then error("malformed state-changing review")
		else map(select(state_changing))
		| group_by(.user.login)
		| map(max_by([.submitted_at // "", .id // 0]))
		| if any(.state == "CHANGES_REQUESTED") then "CHANGES_REQUESTED"
		  elif any(.state == "APPROVED") then "OBSERVED_APPROVED"
		  else "NONE" end end
	' 2>/dev/null || return 1
	return 0
}

#######################################
# GraphQL fallback for the review state when REST is at the worker reserve.
# One bounded history read (GraphQL budget is separate from REST core).
# Preserve state-changing reviews even after later comments. Pagination metadata
# makes incomplete history fail closed, independently of gh's internal limits.
# Args: $1=PR number, $2=repo slug
# Stdout: CHANGES_REQUESTED | OBSERVED_APPROVED | NONE
#######################################
_pmp_graphql_review_decision_from_reviews() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_json=""
	local owner="${repo_slug%%/*}" name="${repo_slug#*/}"
	local mapped=""

	# GraphQL variables must remain literal, not shell-expanded.
	# shellcheck disable=SC2016
	pr_json=$(_pmrs_gh_call read gh api graphql -f query='
		query($owner:String!,$name:String!,$number:Int!) {
			repository(owner:$owner,name:$name) {
				pullRequest(number:$number) {
					reviews(first:100) {
						pageInfo { hasNextPage }
						nodes { databaseId author { login } state submittedAt }
					}
				}
			}
		}' -f owner="$owner" -f name="$name" -F number="$pr_number" 2>/dev/null) || return 1
	mapped=$(printf '%s' "$pr_json" | jq -ce '
		if .errors != null then error("GraphQL errors") else
		.data.repository.pullRequest.reviews
		| if .pageInfo.hasNextPage != false or (.nodes | type) != "array"
		  then error("incomplete review history") else .nodes end
		| map({user: {login: .author.login}, state: .state, submitted_at: .submittedAt, id: .databaseId})
		end
	' 2>/dev/null) || return 1
	printf '%s' "$mapped" | _pmp_reduce_reviews_json || return 1
	return 0
}

_pmp_refresh_unknown_review_decision_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local current_review="$4"
	local refreshed_review=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_review_decision_into refreshed_review "$current_review"
	if [[ "$refreshed_review" == "UNKNOWN" ]]; then
		refreshed_review=$(_pmp_rest_review_decision_from_reviews "$pr_number" "$repo_slug" 2>/dev/null) ||
			refreshed_review=$(_pmp_graphql_review_decision_from_reviews "$pr_number" "$repo_slug" 2>/dev/null) ||
			refreshed_review="UNKNOWN"
		_pmp_normalize_review_decision_into refreshed_review "$refreshed_review"
	fi
	printf -v "$dest_var" '%s' "$refreshed_review"
	return 0
}

#######################################
# Reconcile the already-gated review state with a fresh, bounded REST review
# history immediately before stale native-auto recovery. A new blocker is
# authoritative; unavailable or contradictory evidence fails closed.
# Args: $1=destination var, $2=PR number, $3=repo slug, $4=gated review state
#######################################
_pmp_refresh_native_auto_review_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local gated_review="$4"
	local fresh_review=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_review_decision_into gated_review "$gated_review"
	fresh_review=$(_pmp_rest_review_decision_from_reviews "$pr_number" "$repo_slug" 2>/dev/null) || {
		printf -v "$dest_var" '%s' UNKNOWN
		return 1
	}
	_pmp_normalize_review_decision_into fresh_review "$fresh_review"

	if [[ "$fresh_review" == "CHANGES_REQUESTED" ]]; then
		printf -v "$dest_var" '%s' "$fresh_review"
		return 0
	fi
	case "${gated_review}:${fresh_review}" in
	APPROVED:OBSERVED_APPROVED | OBSERVED_APPROVED:OBSERVED_APPROVED | NONE:OBSERVED_APPROVED | NONE:NONE)
		printf -v "$dest_var" '%s' "$fresh_review"
		return 0
		;;
	esac
	printf -v "$dest_var" '%s' UNKNOWN
	return 1
}

#######################################
# Resolve unknown review states before classification or eligibility decisions.
# Args: $1=repo slug, $2=PR JSON array
#######################################
_pmrs_review_cache() {
	local action="$1" repo_slug="$2" number="$3" head="$4" updated="$5" decision="${6:-}"
	local cache_credential=""
	# This cache is enrichment only. Final native-auto reconciliation deliberately
	# uses uncached review pages. Missing metadata always forces a fresh read.
	[[ -n "$head" && -n "$updated" ]] || return 1
	_gh_active_credential_into cache_credential || return 1
	PMRS_CACHE_REPO="$repo_slug" PMRS_CACHE_NUMBER="$number" PMRS_CACHE_HEAD="$head" \
		PMRS_CACHE_UPDATED="$updated" PMRS_CACHE_DECISION="$decision" PMRS_CACHE_TOKEN="$cache_credential" \
		python3 - "$action" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

root = Path(os.environ.get("AIDEVOPS_PULSE_REVIEW_CACHE_DIR", str(Path.home() / ".aidevops/logs/pulse-review-cache")))
try:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = root.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o077:
        sys.exit(1)
    key = hashlib.sha256(json.dumps([os.environ.get("GH_HOST", "github.com"),
        os.environ["PMRS_CACHE_TOKEN"],
        *[os.environ["PMRS_CACHE_" + name] for name in ("REPO", "NUMBER", "HEAD", "UPDATED")]]).encode()).hexdigest()
    path = root / (key + ".json")
    allowed = "NONE CHANGES_REQUESTED OBSERVED_APPROVED".split()
    if sys.argv[1] == "get":
        mode = path.lstat()
        if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o077:
            sys.exit(1)
        row = json.loads(path.read_text())
        if not 0 <= time.time() - row["at"] < 300 or row["decision"] not in allowed:
            sys.exit(1)
        print(row["decision"])
    else:
        decision = os.environ["PMRS_CACHE_DECISION"]
        if decision not in allowed:
            sys.exit(1)
        fd, temporary = tempfile.mkstemp(dir=root)
        with os.fdopen(fd, "w") as stream:
            json.dump({"at": time.time(), "decision": decision}, stream)
        os.replace(temporary, path)
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
	return $?
}

_pmp_enrich_prs_with_review_decisions() {
	local repo_slug="$1"
	local pr_json="$2"
	local enriched_json="$pr_json"
	local pr_rows=""
	local _US=$'\x1f'
	local index="" number="" review_decision="" head="" updated=""
	local enrichment_credential=""
	# Pin keychain and host-specific auth across cache get, fresh fetch and put.
	# No credential identity means no cache; existing fresh-read behavior remains.
	local GH_TOKEN="${GH_TOKEN:-}" GH_ENTERPRISE_TOKEN="${GH_ENTERPRISE_TOKEN:-}"
	if _gh_active_credential_into enrichment_credential; then
		GH_TOKEN="$enrichment_credential"
		GH_ENTERPRISE_TOKEN="$enrichment_credential"
		export GH_TOKEN GH_ENTERPRISE_TOKEN
	fi

	if [[ -z "$repo_slug" ]]; then
		printf '%s' "$pr_json"
		return 0
	fi
	pr_rows=$(printf '%s' "$pr_json" | jq -r '
		if type != "array" then error("expected PR array")
		else to_entries[] | [
			(.key | tostring),
			(if ((.value | has("number") | not) or .value.number == null or (.value.number | tostring | length) == 0)
			 then "" else (.value.number | tostring) end),
			(if ((.value | has("reviewDecision") | not) or .value.reviewDecision == null or (.value.reviewDecision | tostring | length) == 0)
			 then "UNKNOWN" else .value.reviewDecision end),
			(.value.headRefOid // ""), (.value.updatedAt // "")
		] | join("\u001f")
		end' 2>/dev/null) || {
		printf '%s' "$pr_json"
		return 0
	}

	while IFS="$_US" read -r index number review_decision head updated; do
		[[ -n "$index" ]] || continue
		_pmp_normalize_review_decision_into review_decision "$review_decision"
		if [[ "$number" =~ ^[0-9]+$ ]] && _pmp_review_decision_is_unknown "$review_decision"; then
			if ! review_decision=$(_pmrs_review_cache get "$repo_slug" "$number" "$head" "$updated"); then
				_pmp_refresh_unknown_review_decision_into review_decision "$number" "$repo_slug" UNKNOWN
				_pmrs_review_cache put "$repo_slug" "$number" "$head" "$updated" "$review_decision" || true
			fi
			enriched_json=$(printf '%s' "$enriched_json" | jq --argjson index "$index" --arg review "$review_decision" '.[$index].reviewDecision = $review' 2>/dev/null) || {
				printf '%s' "$pr_json"
				return 0
			}
		fi
	done <<<"$pr_rows"

	printf '%s' "$enriched_json"
	return 0
}

#######################################
# Execute GitHub's update-a-pull-request-branch REST endpoint.
# Args: $1=PR number, $2=repo slug, $3=expected current head SHA
#######################################
_pmp_update_branch_rest() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="${3:-}"

	if [[ -z "$expected_head_sha" ]]; then
		printf 'update-branch refused: expected head SHA is required for PR #%s in %s\n' \
			"$pr_number" "$repo_slug" >&2
		return 2
	fi
	# Every caller shares one head-bound semantic-conflict cooldown (GH#34560).
	# The helpers live in pulse-merge-process.sh; absent helpers fail open.
	if declare -F _pmp_update_branch_conflict_cooldown_active >/dev/null 2>&1 &&
		_pmp_update_branch_conflict_cooldown_active "$pr_number" "$repo_slug" "$expected_head_sha"; then
		printf 'update-branch skipped: semantic conflict cooldown active for PR #%s head %s (GH#34560)\n' \
			"$pr_number" "${expected_head_sha:0:12}" >&2
		return 1
	fi

	local ub_output=""
	local ub_rc=0
	ub_output=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-update-branch-rest" \
		_pmrs_gh_call write gh api --method PUT "repos/${repo_slug}/pulls/${pr_number}/update-branch" \
		-f expected_head_sha="$expected_head_sha" 2>&1) || ub_rc=$?
	[[ -z "$ub_output" ]] || printf '%s\n' "$ub_output"
	if [[ "$ub_rc" -ne 0 && "$ub_output" == *"HTTP 422"* ]] &&
		declare -F _pmp_record_update_branch_conflict_cooldown >/dev/null 2>&1; then
		_pmp_record_update_branch_conflict_cooldown "$pr_number" "$repo_slug" "$expected_head_sha" || true
	fi
	return "$ub_rc"
}

#######################################
# Resolve (and opportunistically prune) the per-PR missing-check state file.
# Lines: "<head_sha> <epoch> <ok|failed|exhausted>".
# Args: $1=repo slug, $2=PR number
#######################################
_pmrs_missing_checks_state_file() {
	local repo_slug="$1"
	local pr_number="$2"
	local state_dir="${AIDEVOPS_PULSE_MISSING_CHECKS_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse-missing-required-checks}"
	local safe_slug=""

	mkdir -p "$state_dir" 2>/dev/null || return 1
	find "$state_dir" -type f -mtime +7 -delete 2>/dev/null || true
	safe_slug=$(printf '%s' "$repo_slug" | tr -c '[:alnum:]._-' '_')
	printf '%s/%s-%s' "$state_dir" "$safe_slug" "$pr_number"
	return 0
}

#######################################
# True when every non-passing required context is absent from the exact-head
# rollup and no check is in flight. Reads the globals that
# _check_required_checks_passing sets in the same shell; unset = unknown.
#######################################
_pmrs_missing_checks_applicable() {
	local nonpass="${_PULSE_REQUIRED_CHECKS_NONPASS_COUNT:-}"
	local missing="${_PULSE_REQUIRED_CHECKS_MISSING_COUNT:-}"
	local in_flight="${_PULSE_CHECKS_IN_FLIGHT_COUNT:-}"

	[[ "$nonpass" =~ ^[0-9]+$ && "$missing" =~ ^[0-9]+$ && "$in_flight" =~ ^[0-9]+$ ]] || return 1
	[[ "$missing" -gt 0 && "$missing" -eq "$nonpass" && "$in_flight" -eq 0 ]] || return 1
	return 0
}

#######################################
# Age of the head commit from its committer timestamp.
# Args: $1=repo slug, $2=head SHA
# Stdout: age in seconds
#######################################
_pmrs_head_commit_age_seconds() {
	local repo_slug="$1"
	local head_sha="$2"
	local committed_at="" committed_epoch="" now_epoch=""

	committed_at=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-missing-checks-head-age-rest" \
		_pmrs_gh_call read gh api "repos/${repo_slug}/commits/${head_sha}" \
		--jq '.commit.committer.date // empty' 2>/dev/null) || return 1
	[[ -n "$committed_at" ]] || return 1
	committed_epoch=$(date -u -d "$committed_at" +%s 2>/dev/null \
		|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$committed_at" +%s 2>/dev/null) || return 1
	[[ "$committed_epoch" =~ ^[0-9]+$ ]] || return 1
	now_epoch=$(date -u +%s)
	printf '%s' "$((now_epoch - committed_epoch))"
	return 0
}

#######################################
# List latest-per-workflow runs at the exact head that ended failure or
# startup_failure with zero jobs (no check run is ever created for them).
# Args: $1=repo slug, $2=head SHA
# Stdout: one "<run id><TAB><workflow name>" line per run; returns 1 when none
#######################################
_pmrs_zero_job_runs() {
	local repo_slug="$1"
	local head_sha="$2"
	local runs_json="" candidates="" run_id="" run_name="" total="" found=1

	runs_json=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-zero-job-runs-rest" \
		_pmrs_gh_call read gh api -X GET "repos/${repo_slug}/actions/runs" \
		-f head_sha="$head_sha" -f per_page=100 2>/dev/null) || return 1
	candidates=$(jq -r --arg head "$head_sha" '
		(.workflow_runs // [])
		| map(select(.head_sha == $head))
		| group_by(.workflow_id)
		| map(max_by(.run_number // 0))
		| .[]
		| select(.status == "completed" and (.conclusion == "failure" or .conclusion == "startup_failure"))
		| [.id, (.name // "workflow")] | @tsv' <<<"$runs_json" 2>/dev/null) || return 1
	while IFS=$'\t' read -r run_id run_name; do
		[[ "$run_id" =~ ^[0-9]+$ ]] || continue
		total=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-zero-job-runs-jobs-rest" \
			_pmrs_gh_call read gh api -X GET "repos/${repo_slug}/actions/runs/${run_id}/jobs" \
			-f per_page=1 --jq '.total_count' 2>/dev/null) || continue
		[[ "$total" == "0" ]] || continue
		printf '%s\t%s\n' "$run_id" "$run_name"
		found=0
	done <<<"$candidates"
	return "$found"
}

#######################################
# Request one rerun of a zero-job run. The reservation is written before the
# write and survives restarts: a run ID is never replayed, and an ambiguous or
# failed request escalates once.
# Args: $1=repo slug, $2=PR number, $3=head SHA, $4=run id
# Returns: 0=rerun requested, 2=already handled earlier, 1=request failed
#######################################
_pmrs_rerun_zero_job_run() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_sha="$3"
	local run_id="$4"
	local state_root="${AIDEVOPS_TEMP_DIR:-${HOME:+$HOME/.aidevops/.agent-workspace/tmp}}"
	local state_dir="${PULSE_MERGE_ZERO_JOB_RERUN_STATE_DIR:-${state_root:+$state_root/pulse-zero-job-reruns}}"
	local reservation=""

	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$head_sha" =~ ^[A-Za-z0-9_-]+$ && "$run_id" =~ ^[0-9]+$ && -n "$state_dir" ]] || return 1
	mkdir -p "$state_dir" 2>/dev/null || return 1
	reservation="${state_dir}/${repo_slug//\//-}-${pr_number}-${head_sha}-${run_id}"
	if ! mkdir "$reservation" 2>/dev/null; then
		if mkdir "$reservation/escalated" 2>/dev/null; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: zero-job run=${run_id} on head ${head_sha:0:12} already had a rerun requested; no further automatic reruns (t18926)" >>"$LOGFILE"
		fi
		return 2
	fi
	#aidevops:trust-boundary — the run ID comes from an API listing filtered to
	# the gated head SHA, and the caller already passed pulse write policy.
	if gh run rerun "$run_id" --repo "$repo_slug" >/dev/null 2>&1; then
		: >"$reservation/submitted" 2>/dev/null || true
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: requested rerun of zero-job workflow run=${run_id} on head ${head_sha:0:12} (t18926)" >>"$LOGFILE"
		return 0
	fi
	mkdir "$reservation/escalated" 2>/dev/null || true
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: rerun request failed for zero-job workflow run=${run_id} on head ${head_sha:0:12}; no further automatic reruns (t18926)" >>"$LOGFILE"
	return 1
}

#######################################
# Rerun zero-job workflow runs for the gated head before any update-branch.
# Args: $1=repo slug, $2=PR number, $3=head SHA
# Returns: 0=zero-job runs exist and were handled (caller must not
#          update-branch), 1=none exist or reruns are not permitted
#######################################
_pmrs_remediate_zero_job_runs() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_sha="$3"
	local runs="" run_id="" run_name=""

	if declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 &&
		! repo_allows_pulse_write_actions "$repo_slug"; then
		return 1
	fi
	if declare -F _pmrc_actions_incident_blocks_rerun >/dev/null 2>&1 &&
		_pmrc_actions_incident_blocks_rerun; then
		return 1
	fi
	runs=$(_pmrs_zero_job_runs "$repo_slug" "$head_sha") || return 1
	while IFS=$'\t' read -r run_id run_name; do
		[[ -n "$run_id" ]] || continue
		_pmrs_rerun_zero_job_run "$repo_slug" "$pr_number" "$head_sha" "$run_id" || true
	done <<<"$runs"
	return 0
}

#######################################
# Remediate required contexts that will never report on the current head
# (GH#32951). GitHub can drop a workflow run for a PR event; the required
# context then stays "expected" forever, native auto-merge can never finish,
# and re-arming it every cycle only churns writes (other runners may disarm
# it again). Request one expected-head update-branch to retrigger CI instead.
# Bounded per head by a cooldown and per PR by an attempt cap so a
# paths-filtered required workflow that never reports cannot loop.
#
# Caller must have passed all merge gates and stopped DRY_RUN, and must call
# _check_required_checks_passing for the same PR immediately before.
# Args: $1=PR number, $2=repo slug, $3=gated head SHA
# Returns: 0=handled (update requested, cooling down, failed, or attempts
#          exhausted) — caller must not arm native auto-merge;
#          1=not applicable, head too young, or state unavailable
#######################################
_pmp_remediate_missing_required_checks() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="${3:-}"
	local threshold="${AIDEVOPS_PULSE_MISSING_REQUIRED_CHECK_SECONDS:-1800}"
	local max_attempts="${AIDEVOPS_PULSE_MISSING_REQUIRED_CHECK_MAX_UPDATES:-2}"
	local state_file="" now_epoch="" head_entry="" head_epoch="" head_result=""
	local attempts=0 age="" ub_output="" ub_rc=0
	local missing="${_PULSE_REQUIRED_CHECKS_MISSING_COUNT:-0}"

	[[ -n "$head_sha" ]] || return 1
	_pmrs_missing_checks_applicable || return 1
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1800
	[[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2
	state_file=$(_pmrs_missing_checks_state_file "$repo_slug" "$pr_number") || return 1
	now_epoch=$(date -u +%s)

	if [[ -f "$state_file" ]]; then
		head_entry=$(awk -v sha="$head_sha" '$1 == sha { e = $2 " " $3 } END { print e }' "$state_file" 2>/dev/null) || head_entry=""
		attempts=$(awk '$3 == "ok" { n++ } END { print n + 0 }' "$state_file" 2>/dev/null) || attempts=0
		[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
	fi
	read -r head_epoch head_result <<<"$head_entry"
	[[ "$head_result" == "exhausted" ]] && return 0
	if [[ "$head_epoch" =~ ^[0-9]+$ ]] && ((now_epoch - head_epoch < threshold)); then
		return 0
	fi

	age=$(_pmrs_head_commit_age_seconds "$repo_slug" "$head_sha") || return 1
	[[ "$age" =~ ^[0-9]+$ && "$age" -ge "$threshold" ]] || return 1

	if [[ "$attempts" -ge "$max_attempts" ]]; then
		printf '%s %s exhausted\n' "$head_sha" "$now_epoch" >>"$state_file"
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: ${missing} required context(s) never reported on head ${head_sha:0:12} after ${attempts} update-branch attempt(s); native auto-merge not re-armed — check required workflow triggers/path filters or re-run CI (GH#32951)" >>"$LOGFILE"
		return 0
	fi

	# A zero-job run created no check run; rerunning it needs no new commit and
	# keeps passing checks, unlike update-branch on an up-to-date head (t18926).
	if _pmrs_remediate_zero_job_runs "$repo_slug" "$pr_number" "$head_sha"; then
		printf '%s %s rerun\n' "$head_sha" "$now_epoch" >>"$state_file"
		return 0
	fi

	ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$head_sha" 2>&1) || ub_rc=$?
	if [[ "$ub_rc" -eq 0 ]]; then
		printf '%s %s ok\n' "$head_sha" "$now_epoch" >>"$state_file"
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: ${missing} required context(s) never reported on head ${head_sha:0:12} (${age}s old, no checks in flight) — update-branch requested to retrigger CI instead of arming native auto-merge (GH#32951)" >>"$LOGFILE"
		return 0
	fi
	printf '%s %s failed\n' "$head_sha" "$now_epoch" >>"$state_file"
	ub_output=$(printf '%s' "$ub_output" | tr '\n' ' ' | cut -c1-300)
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: ${missing} required context(s) never reported on head ${head_sha:0:12}; update-branch failed, holding native auto-merge for ${threshold}s (GH#32951): ${ub_output}" >>"$LOGFILE"
	return 0
}

#######################################
# Read auto-merge enablement time through a fixed-cost GraphQL query when the
# REST representation omits auto_merge.enabled_at. The operation reports its
# own cost and fails closed if GitHub changes the calibrated one-point shape.
# Args: $1=PR number, $2=repo slug
# Stdout: enabledAt timestamp, or empty when no request exists
#######################################
_pmrs_auto_merge_enabled_at_graphql() {
	local pr_number="$1"
	local repo_slug="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"
	local response="" reported_cost="" enabled_at=""

	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-auto-merge-enabled-at-exact-cost" \
		_pmrs_gh_call read gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) { autoMergeRequest { enabledAt } }
			}
			rateLimit { cost }
		}
	') || return 1
	[[ -n "$response" ]] || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty') || return 1
	if [[ "$reported_cost" != "1" ]]; then
		printf 'auto-merge enabledAt GraphQL cost contract changed for PR #%s in %s\n' \
			"$pr_number" "$repo_slug" >&2
		return 1
	fi
	enabled_at=$(printf '%s' "$response" \
		| jq -r '.data.repository.pullRequest.autoMergeRequest.enabledAt // empty') || return 1
	printf '%s' "$enabled_at"
	return 0
}

#######################################
# Fetch native-auto and merge-state metadata through REST. If REST omits the
# auto-merge timestamp, recover that one GraphQL-only field through a fixed,
# response-metered query; a failed recovery leaves the age unknown/fail-closed.
# Args: $1=PR number, $2=repo slug
#######################################
_pmp_rest_pr_merge_state() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state="" enabled_at=""
	pr_state=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-pr-merge-state-rest" \
		_pmrs_gh_call read gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '
		{
			autoMergeRequest: (if .auto_merge == null then null else {
				enabledAt: (.auto_merge.enabled_at // null),
				enabledBy: (.auto_merge.enabled_by // null)
			} end),
			mergeStateStatus: ((.mergeable_state // "unknown") | ascii_upcase),
			mergeable: (if .mergeable == true then "MERGEABLE"
				elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
			headRefOid: (.head.sha // "")
		}'
	) || return $?
	[[ -n "$pr_state" ]] || return 1
	if printf '%s' "$pr_state" | jq -e '.autoMergeRequest != null and .autoMergeRequest.enabledAt == null' >/dev/null 2>&1; then
		enabled_at=$(_pmrs_auto_merge_enabled_at_graphql "$pr_number" "$repo_slug" 2>/dev/null) || enabled_at=""
		if [[ -n "$enabled_at" ]]; then
			pr_state=$(printf '%s' "$pr_state" | jq -c --arg enabled_at "$enabled_at" \
				'.autoMergeRequest.enabledAt = $enabled_at') || return 1
		fi
	fi
	printf '%s' "$pr_state"
	return 0
}

#######################################
# Overlay the review state that already passed the current merge gate onto the
# exact-attribution REST/native-auto snapshot.
# Args: $1=PR number, $2=repo slug, $3=current review state
#######################################
_pmp_native_auto_merge_state() {
	local pr_number="$1"
	local repo_slug="$2"
	local current_review="$3"
	local pr_state=""

	pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug") || return 1
	_pmp_normalize_review_decision_into current_review "$current_review"
	pr_state=$(printf '%s' "$pr_state" | jq -c --arg review "$current_review" \
		'.reviewDecision = $review' 2>/dev/null) || return 1
	printf '%s' "$pr_state"
	return 0
}

_pmp_extract_update_branch_state() {
	local auto_var="$1"
	local state_var="$2"
	local mergeable_var="$3"
	local pr_state="$4"
	local head_var="${5:-}"
	local existing_auto="" merge_state="" mergeable="" head_oid="" _RS=$'\x1e'

	IFS="$_RS" read -r existing_auto merge_state mergeable head_oid <<<"$(printf '%s' "$pr_state" \
		| jq -r '"\(if .autoMergeRequest then "present" else "" end)\u001e\(.mergeStateStatus // "")\u001e\(.mergeable // "")\u001e\(.headRefOid // "")"' \
		|| true)"
	_pmp_normalize_mergeable_state_into mergeable "$mergeable"
	printf -v "$auto_var" '%s' "$existing_auto"
	printf -v "$state_var" '%s' "$merge_state"
	printf -v "$mergeable_var" '%s' "$mergeable"
	if [[ -n "$head_var" ]]; then
		[[ "$head_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
		printf -v "$head_var" '%s' "$head_oid"
	fi
	return 0
}
