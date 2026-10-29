#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only verification of an explicitly selected, existing app deployment.

_full_loop_verify_deployment() {
	local repo="$1" pr_number="$2" run_id="$3" workflow="$4" source_sha="$5"
	local repository="" pr="" run="" workflow_json="" latest="" compare=""
	local branch="" actor="" permission="" merge_sha=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
		"$pr_number" =~ ^[1-9][0-9]*$ && "$run_id" =~ ^[1-9][0-9]*$ &&
		"$workflow" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ &&
		"$source_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" != "marcusquinn/aidevops" ]] || return 1
	# aidevops:trust-boundary — require maintainer access, a same-repository push,
	# and write-authorized original AND rerun actors; never accept PR/fork runs.
	repository=$(gh api "repos/${repo}" 2>/dev/null) || return 1
	jq -e --arg repo "$repo" '.full_name == $repo and .archived == false and
		(.permissions.admin == true or .permissions.maintain == true or .permissions.push == true)' \
		<<<"$repository" >/dev/null || return 1
	pr=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null) || return 1
	jq -e --arg repo "$repo" '.merged == true and .state == "closed" and
		.base.repo.full_name == $repo and (.merged_at | type == "string") and
		(.merge_commit_sha | test("^[0-9a-f]{40}$")) and (.base.ref | strings | length > 0)' \
		<<<"$pr" >/dev/null || return 1
	branch=$(jq -er '.base.ref' <<<"$pr") || return 1
	merge_sha=$(jq -er '.merge_commit_sha' <<<"$pr") || return 1
	workflow_json=$(gh api "repos/${repo}/actions/workflows/${workflow}" 2>/dev/null) || return 1
	run=$(gh api "repos/${repo}/actions/runs/${run_id}" 2>/dev/null) || return 1
	jq -e --arg repo "$repo" --arg branch "$branch" --arg sha "$source_sha" \
		--arg workflow "$workflow" --argjson id "$run_id" --argjson pr "$pr" --argjson wf "$workflow_json" '
		.id == $id and .workflow_id == $wf.id and $wf.path == (".github/workflows/" + $workflow)
		and .path == $wf.path and .repository.full_name == $repo and .head_repository.full_name == $repo
		and .event == "push" and .head_branch == $branch and .head_sha == $sha
		and .status == "completed" and .conclusion == "success"
		and (.run_attempt | type == "number" and . >= 1 and floor == .)
		and ((.run_started_at | fromdateiso8601) >= ($pr.merged_at | fromdateiso8601))
		and (.actor.login | strings | test("^[A-Za-z0-9_-]+(\\[bot\\])?$"))
		and (.triggering_actor.login | strings | test("^[A-Za-z0-9_-]+(\\[bot\\])?$"))
	' <<<"$run" >/dev/null || return 1
	for actor in "$(jq -r '.actor.login' <<<"$run")" "$(jq -r '.triggering_actor.login' <<<"$run")"; do
		permission=$(gh api "repos/${repo}/collaborators/${actor}/permission" 2>/dev/null) || return 1
		jq -e '.permission == "admin" or .permission == "maintain" or .permission == "write"' \
			<<<"$permission" >/dev/null || return 1
	done
	# Reject stale runs, including an older success followed by a pending/failing
	# deployment. Do not filter for success, which would hide newer failed runs.
	latest=$(gh api -X GET "repos/${repo}/actions/workflows/${workflow}/runs" \
		-f branch="$branch" -f per_page=1 2>/dev/null) || return 1
	jq -e --argjson run "$run" '.workflow_runs[0] |
		.id == $run.id and .run_attempt == $run.run_attempt and .head_sha == $run.head_sha
		and .status == "completed" and .conclusion == "success"' <<<"$latest" >/dev/null || return 1
	compare=$(gh api "repos/${repo}/compare/${merge_sha}...${source_sha}" 2>/dev/null) || return 1
	jq -e --arg merge "$merge_sha" --arg source "$source_sha" '
		(.status == "ahead" or .status == "identical") and .base_commit.sha == $merge
		and .merge_base_commit.sha == $merge and (if .status == "identical" then $source == $merge else true end)
	' <<<"$compare" >/dev/null || return 1
	jq -cn --arg repo "$repo" --argjson pr "$pr_number" --arg workflow "$workflow" \
		--arg sha "$source_sha" --arg merge "$merge_sha" --argjson run "$run" '
		{schema_version:1,evidence_type:"tagless-deployment",repository:$repo,pr_number:$pr,
		workflow:$workflow,run_id:$run.id,run_attempt:$run.run_attempt,source_sha:$sha,merge_sha:$merge}' || return 1
	return 0
}

# Versioned receipts remain one-line status files. Deployment receipts retain
# that first-line ABI, but carry mandatory evidence in the SAME atomic file so
# losing an optional sidecar cannot downgrade verification to a plain success.
_full_loop_deployment_receipt_payload() {
	local path="$1"
	jq -Rsc 'split("\n") |
		if length == 2 and .[1] == "" then ""
		elif length == 3 and .[0] == "published" and (.[1] | length > 0) and .[2] == "" then .[1]
		else error("Invalid deployment receipt framing") end' "$path" || return 1
	return 0
}

_full_loop_verify_deployment_receipt() {
	local repo="$1" pr_number="$2"
	local path="" evidence="" verified=""
	path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$path" ]] || return 0
	evidence=$(_full_loop_deployment_receipt_payload "$path") || return 1
	[[ "$evidence" != '""' ]] || return 0
	evidence=$(jq -er 'fromjson | select(.schema_version == 1 and .evidence_type == "tagless-deployment")' <<<"$evidence") || return 1
	jq -e --arg repo "$repo" --argjson pr "$pr_number" '.repository == $repo and .pr_number == $pr' \
		<<<"$evidence" >/dev/null || return 1
	verified=$(_full_loop_verify_deployment "$repo" "$pr_number" \
		"$(jq -r '.run_id' <<<"$evidence")" "$(jq -r '.workflow' <<<"$evidence")" \
		"$(jq -r '.source_sha' <<<"$evidence")") || return 1
	jq -e --argjson verified "$verified" '. == $verified' <<<"$evidence" >/dev/null || return 1
	return 0
}

cmd_record_deployment() {
	local pr_number="${1:-}" run_id="${2:-}" workflow="${3:-}" source_sha="${4:-}"
	local repo="" evidence="" path="" existing="" status=0
	[[ $# -ge 4 && $# -le 5 ]] || {
		print_error "Usage: record-deployment <PR> <RUN_ID> <WORKFLOW.yml> <DEPLOYED_SHA> [REPO]"
		return 1
	}
	repo=$(_full_loop_resolve_repo "${5:-}") || return 1
	evidence=$(_full_loop_verify_deployment "$repo" "$pr_number" "$run_id" "$workflow" "$source_sha") || {
		print_error "Deployment evidence is missing, stale, unsuccessful, unrelated, or untrusted"
		return 1
	}
	_full_loop_acquire_transition_lock || return 1
	path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || status=1
	if [[ "$status" -eq 0 && -e "$path" ]]; then
		# Re-attest only the same deployment identity with a newer verified run
		# or attempt. Never replace versioned, malformed, or unrelated evidence.
		existing=$(_full_loop_deployment_receipt_payload "$path") || status=1
		if [[ "$status" -eq 0 ]]; then
			existing=$(jq -er 'fromjson' <<<"$existing") || status=1
		fi
		if [[ "$status" -eq 0 ]]; then
			jq -e --argjson evidence "$evidence" '
				. == $evidence or (
					.schema_version == $evidence.schema_version and .evidence_type == $evidence.evidence_type
					and .repository == $evidence.repository and .pr_number == $evidence.pr_number
					and .workflow == $evidence.workflow and .merge_sha == $evidence.merge_sha
					and (.source_sha | type == "string" and test("^[0-9a-f]{40}$"))
					and ([.run_id, .run_attempt] | all(type == "number" and . >= 1 and floor == .))
					and ($evidence.run_id > .run_id or
						($evidence.run_id == .run_id and $evidence.run_attempt > .run_attempt))
				)' <<<"$existing" >/dev/null || status=1
		fi
	fi
	if [[ "$status" -eq 0 && "$existing" != "$evidence" ]]; then
		mkdir -p "${path%/*}" || status=1
		if [[ "$status" -eq 0 ]]; then
			printf 'published\n%s\n' "$evidence" >"${path}.tmp.$$" && mv "${path}.tmp.$$" "$path" || status=1
		fi
	fi
	if [[ "$status" -eq 0 ]]; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_PUBLISHED" || status=1
	fi
	_full_loop_release_transition_lock
	[[ "$status" -eq 0 ]] || {
		print_error "Cannot record deployment: conflicting terminal receipt or cleanup evidence"
		return 1
	}
	print_success "Verified tagless deployment recorded for PR #${pr_number} (run=${run_id}, source=${source_sha})"
	return 0
}
