#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Explicit operator-owned capability; never inferred from a failed check.

# shellcheck source=ci-infra-signature-lib.sh
source "${BASH_SOURCE[0]%/*}/ci-infra-signature-lib.sh"

REPO_ACTIONS_JSON_ARRAY="array"

repo_actions_unavailable() {
	local repo="$1"
	local registry="${REPOS_FILE:-$HOME/.config/aidevops/repos.json}"
	[[ -f "$registry" ]] || return 1
	jq -e --arg repo "$repo" '
		[.initialized_repos[]? | select(.slug == $repo)] as $entries
		| ($entries | length) == 1 and $entries[0].actions == "unavailable"
	' "$registry" >/dev/null 2>&1 || return 1
	return 0
}

# A receipt is a marker followed immediately by one JSON line. A trusted
# assertion records all configured/documented local checks, not invented tests.
repo_actions_receipt_valid() {
	local body="$1"
	local head="$2"
	jq -en --arg body "$body" --arg head "$head" --arg array "$REPO_ACTIONS_JSON_ARRAY" '
		($body | split("\n")) as $lines
		| any(range(0; $lines | length); . as $i
			| $lines[$i] == "<!-- aidevops:local-verification:v1 -->" and
			(try ($lines[$i + 1] | fromjson
				| .head == $head and .status == "passed"
				and .checks_complete == true
				and (.checks | type == $array and length > 0)
				and all(.checks[]; (.command | type == "string" and length > 0)
					and .exit_code == 0 and (.result | type == "string" and length > 0))) catch false))
	' >/dev/null 2>&1 || return 1
	return 0
}

repo_actions_trusted_receipt() {
	local repo="$1" pr="$2" head="$3" pull="$4"
	local comments="" entries="" entry="" body="" login="" permission=""
	comments=$(gh api "repos/${repo}/issues/${pr}/comments?per_page=100" --paginate --slurp) || return 1
	entries=$(jq -cn --argjson pull "$pull" --argjson pages "$comments" --arg array "$REPO_ACTIONS_JSON_ARRAY" '
		if ($pages | type != $array) or any($pages[]; type != $array)
		then error("invalid comments") else
		[$pull] + ($pages | add // []) end
		| .[] | select(.author_association == "OWNER" or .author_association == "MEMBER"
			or .author_association == "COLLABORATOR") | {body,login:.user.login}
	') || return 1
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		body=$(jq -r '.body // ""' <<<"$entry") || return 1
		repo_actions_receipt_valid "$body" "$head" || continue
		login=$(jq -r '.login // empty' <<<"$entry") || return 1
		[[ "$login" =~ ^[A-Za-z0-9_-]+$ ]] || continue
		#aidevops:trust-boundary -- prose or a receipt from an external author
		# cannot relax CI. Verify current write authority, not just association.
		permission=$(gh api "repos/${repo}/collaborators/${login}/permission" --jq '.permission') || return 1
		case "$permission" in
		admin | maintain | write) return 0 ;;
		esac
	done <<<"$entries"
	printf 'BLOCKED: missing trusted local verification for head %s\n' "$head" >&2
	return 1
}

# One exact-head observation, never a polling loop. All non-billing terminal
# failures (including optional checks and commit statuses) remain blocking.
# Native branch protection and review/author gates are separate and unchanged.
repo_actions_verify_local() {
	local repo="$1" pr="$2" expected_head="${3:-}"
	local pull="" head="" runs="" statuses="" failed_ids="" id="" final_head="" check_label=""
	local latest_statuses="" status_entry="" status_label=""
	repo_actions_unavailable "$repo" || return 1
	pull=$(gh api "repos/${repo}/pulls/${pr}") || return 1
	head=$(jq -er '.head.sha | select(test("^[0-9a-f]{40}$"))' <<<"$pull") || return 1
	[[ -z "$expected_head" || "$head" == "$expected_head" ]] || return 1
	repo_actions_trusted_receipt "$repo" "$pr" "$head" "$pull" || return 1
	runs=$(gh api "repos/${repo}/commits/${head}/check-runs?per_page=100" --paginate --slurp) || return 1
	statuses=$(gh api "repos/${repo}/commits/${head}/statuses?per_page=100" --paginate --slurp) || return 1
	# Reject malformed or incomplete responses and unknown conclusions. Every
	# failure must pass the provider-specific outage classifier below.
	failed_ids=$(jq -ern --argjson pages "$runs" --arg head "$head" --arg array "$REPO_ACTIONS_JSON_ARRAY" '
		if ($pages | type != $array or length == 0)
			or any($pages[]; (.check_runs | type) != $array)
			or (($pages | map(.check_runs | length) | add) != $pages[0].total_count)
		then error("incomplete check runs") else ($pages | map(.check_runs) | add) end
		| "completed" as $completed
		| if any(.[]; .head_sha != $head or (.id | type) != "number"
			or (.status != "queued" and .status != "in_progress" and .status != $completed)
			or (.status != $completed and .conclusion != null) or
			(.status == $completed and
				(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped") and
				.conclusion != "failure"))
		then error("invalid or terminal check: " + ([.[] | select(.status == $completed
			and .conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")
			| "\(.name // "unknown") (app: \(.app.slug // "unknown"))"] | join(", ")))
		else [.[] | select(.status == $completed and .conclusion == "failure") | .id] | @json end
	') || return 1
	# Latest status per context; success and pending pass, failures must be a
	# classified provider outage.
	latest_statuses=$(jq -ecn --argjson pages "$statuses" --arg array "$REPO_ACTIONS_JSON_ARRAY" '
		if ($pages | type == $array and length > 0) and all($pages[]; type == $array)
		then $pages | add | sort_by(.context) | group_by(.context) | map(max_by(.id))
		else error("incomplete commit statuses") end') || return 1
	while IFS= read -r status_entry; do
		[[ -n "$status_entry" ]] || continue
		ci_commit_status_indicates_quota_outage "$status_entry" && continue
		status_label=$(jq -r '"\(.context // "unknown") (\(.state // "unknown"), creator: \(.creator.login // "unknown"))"' \
			<<<"$status_entry") || return 1
		printf 'BLOCKED: non-billing terminal status: %s\n' "$status_label" >&2
		return 1
	done < <(jq -c '.[] | select(.state != "success" and .state != "pending")' <<<"$latest_statuses")
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		if ! ci_check_run_indicates_billing_outage "$repo" "$id"; then
			check_label=$(jq -r --argjson id "$id" '.[] | .check_runs[] | select(.id == $id)
				| "\(.name // "unknown") (app: \(.app.slug // "unknown"), id: \(.id))"' <<<"$runs") || return 1
			printf 'BLOCKED: non-billing terminal check failure: %s\n' "$check_label" >&2
			return 1
		fi
	done < <(jq -r '.[]' <<<"$failed_ids")
	final_head=$(gh api "repos/${repo}/pulls/${pr}" --jq '.head.sha') || return 1
	[[ "$final_head" == "$head" ]] || return 1
	printf 'PASS: trusted local verification at %s; Actions unavailable; no non-billing terminal failures; no polling\n' "$head"
	return 0
}
