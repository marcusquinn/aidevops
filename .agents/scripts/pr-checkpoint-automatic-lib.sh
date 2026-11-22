#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared automatic admission predicate. No mutations or historical recovery.

# Reuse the bounded, positive GraphQL edit-evidence collector used by release
# fencing; no release function is invoked by this module.
# shellcheck source=headless-runtime-release-claim.sh
source "${BASH_SOURCE[0]%/*}/headless-runtime-release-claim.sh"

_pr_checkpoint_automatic_target() {
	local repo="$1" pr_json="$2" issue_json="$3" comments="$4" runner="$5" session="$6"
	local lease="${7:-}" claiming="${8:-false}" expected_owner="${9:-$runner}" released="${10:-false}"
	local trusted_logins="" result="" prior_comments="" issue="" pr="" author="" device=""
	[[ -n "$session" ]] || return 1
	device=$(_resolve_device_id) || return 1
	trusted_logins=$(_pr_checkpoint_trusted_logins "$comments" "$repo") || return 2
	comments=$(_hrff_release_comment_edits "$comments" \
		'(?m)^(DISPATCH_CLAIM |DISPATCH_LEASE |CLAIM_RELEASED |Dispatching worker|Interactive session claimed)') || return 2
	comments=$(jq -c 'map(map(if ._release_body_unedited == true then .updated_at = .created_at else . end))' \
		<<<"$comments") || return 1
	result=$(printf '%s\n' "$pr_json" "$issue_json" "$comments" "$trusted_logins" |
		jq -se --arg repo "$repo" --arg assignee "$runner" --arg session "$session" \
			--arg lease "$lease" --arg device "$device" --argjson claiming "$claiming" \
			--arg prelaunch "${AIDEVOPS_PR_CHECKPOINT_REQUIRE_PRELAUNCH:-0}" --arg attempt "${AIDEVOPS_ATTEMPT_ID:-}" '
			select(length == 4) | {repo:$repo,pr:.[0],issue:.[1],comments:.[2],trusted_logins:.[3],
			assignee:$assignee,session:$session,lease:$lease,device:$device,claiming:$claiming,
			require_prelaunch:($prelaunch == "1"),attempt:$attempt}' |
		python3 "${_PR_CHECKPOINT_REVISION_VALIDATOR%/*}/pr_checkpoint_admission.py") || return 1
	issue=$(jq -er '.issue' <<<"$result") || return 1
	pr=$(jq -er '.pr' <<<"$result") || return 1
	author=$(jq -er '.author' <<<"$result") || return 1
	prior_comments=$(jq -c '.comments' <<<"$result") || return 1
	_pr_checkpoint_pr_metadata_is_eligible "$pr_json" "$repo" "$pr" "$issue" "" "" "$author" || return 1
	# Both views retain approvals and all protective labels. In particular, an
	# expired revision approval cannot be downgraded to automatic admission.
	_pr_checkpoint_issue_metadata_is_eligible "$issue_json" "$issue" "$expected_owner" \
		"$prior_comments" "$author" "$released" || return 1
	jq -c 'del(.comments)' <<<"$result"
	return 0
}
