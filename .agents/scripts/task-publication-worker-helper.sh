#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/task-coordinator.mjs"
# shellcheck source=./planning-publisher.sh
source "${SCRIPT_DIR}/planning-publisher.sh"

PUBLICATION_MAX_CONCURRENCY="${AIDEVOPS_PUBLICATION_MAX_CONCURRENCY:-4}"
PUBLICATION_LEASE_SECONDS="${AIDEVOPS_PUBLICATION_LEASE_SECONDS:-120}"
PUBLICATION_MAX_BACKOFF="${AIDEVOPS_PUBLICATION_MAX_BACKOFF:-300}"

_publication_evidence() {
	local result="$1"
	local publication_id="$2"
	local commit_sha="${3:-}"
	jq -cn --arg result "$result" --arg publication_id "$publication_id" --arg commit_sha "$commit_sha" \
		'{result:$result,publicationId:$publication_id,commitSha:$commit_sha}'
	return 0
}

_publication_finish() {
	local lease="$1"
	local owner_id="$2"
	local status="$3"
	local evidence="$4"
	local retry_after="${5:-0}"
	node "$COORDINATOR" lease-finish --owner-id "$owner_id" \
		--repository-id "$(jq -r '.repositoryId' <<<"$lease")" \
		--fencing-token "$(jq -r '.fencingToken' <<<"$lease")" --status "$status" \
		--retry-after "$retry_after" --evidence "$evidence" >/dev/null || return 1
	return 0
}

_publication_heartbeat() {
	local lease="$1"
	local owner_id="$2"
	local interval=$((PUBLICATION_LEASE_SECONDS / 3))
	[[ $interval -gt 0 ]] || interval=1
	while sleep "$interval"; do
		node "$COORDINATOR" lease-renew --owner-id "$owner_id" \
			--repository-id "$(jq -r '.repositoryId' <<<"$lease")" \
			--fencing-token "$(jq -r '.fencingToken' <<<"$lease")" \
			--lease-seconds "$PUBLICATION_LEASE_SECONDS" >/dev/null 2>&1 || return 1
	done
	return 0
}

_publication_push_guard() {
	local _repo_path="$1"
	local _remote_name="$2"
	local _branch_name="$3"
	local _parent_sha="$4"
	local _candidate_sha="$5"
	local _attempt="$6"
	: "$_repo_path" "$_remote_name" "$_branch_name" "$_parent_sha" "$_candidate_sha" "$_attempt"
	node "$COORDINATOR" lease-check --owner-id "$PUBLICATION_GUARD_OWNER_ID" \
		--repository-id "$PUBLICATION_GUARD_REPOSITORY_ID" \
		--fencing-token "$PUBLICATION_GUARD_FENCING_TOKEN" >/dev/null
	return $?
}

_publication_install_remote_fence() {
	local lease="$1"
	local owner_id="$2"
	local repo_path="$3"
	local remote_name="$4"
	local branch_name="$5"
	local repository_id="" repository_key="" fencing_token="" fence_ref="" observed_fence="" parent_sha="" tree_sha="" fence_sha=""
	repository_id=$(jq -r '.repositoryId' <<<"$lease")
	repository_key=$(printf '%s' "$repository_id" | git -C "$repo_path" hash-object --stdin) || return 1
	fencing_token=$(jq -r '.fencingToken' <<<"$lease")
	fence_ref="refs/aidevops/publication-fences/${repository_key}"
	observed_fence=$(git -C "$repo_path" ls-remote "$remote_name" "$fence_ref" | while IFS=$'\t' read -r sha _ref; do printf '%s' "$sha"; done) || return 1
	node "$COORDINATOR" lease-check --owner-id "$owner_id" --repository-id "$repository_id" --fencing-token "$fencing_token" >/dev/null || return 1
	git -C "$repo_path" fetch -q "$remote_name" "$branch_name" || return 1
	parent_sha=$(git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
	tree_sha=$(git -C "$repo_path" rev-parse "${parent_sha}^{tree}") || return 1
	fence_sha=$(printf 'aidevops publication fence\n\nrepository-id: %s\nfencing-token: %s\n' "$repository_id" "$fencing_token" |
		GIT_AUTHOR_NAME=aidevops GIT_AUTHOR_EMAIL=aidevops@localhost GIT_COMMITTER_NAME=aidevops GIT_COMMITTER_EMAIL=aidevops@localhost \
			git -C "$repo_path" commit-tree "$tree_sha" -p "$parent_sha") || return 1
	git -C "$repo_path" push -q --atomic --force-with-lease="${fence_ref}:${observed_fence}" \
		"$remote_name" "${fence_sha}:${fence_ref}" || return 1
	AIDEVOPS_PLANNING_FENCE_REF="$fence_ref"
	AIDEVOPS_PLANNING_FENCE_SHA="$fence_sha"
	export AIDEVOPS_PLANNING_FENCE_REF AIDEVOPS_PLANNING_FENCE_SHA
	return 0
}

_publication_process_lease() {
	local lease="$1"
	local owner_id="$2"
	local repo_path="" remote_name="" branch_name="" paths="" commit_sha="" evidence="" rc=0 attempt=0 retry_after=0 heartbeat_pid=""
	repo_path=$(jq -r '.batch[0].repositoryPath' <<<"$lease")
	remote_name=$(jq -r '.batch[0].remoteName' <<<"$lease")
	branch_name=$(jq -r '.batch[0].branchName' <<<"$lease")
	attempt=$(jq -r '.batch[0].attemptCount' <<<"$lease")
	paths=$(jq -r '[.batch[].payload.paths[]?] | unique | .[]' <<<"$lease")

	PLANNING_PUBLISH_RESULT=""
	PLANNING_PUBLICATION_ID=""
	PLANNING_PUBLISHED_COMMIT=""
	export PUBLICATION_GUARD_OWNER_ID="$owner_id"
	PUBLICATION_GUARD_REPOSITORY_ID=$(jq -r '.repositoryId' <<<"$lease")
	PUBLICATION_GUARD_FENCING_TOKEN=$(jq -r '.fencingToken' <<<"$lease")
	export PUBLICATION_GUARD_REPOSITORY_ID PUBLICATION_GUARD_FENCING_TOKEN
	_publication_install_remote_fence "$lease" "$owner_id" "$repo_path" "$remote_name" "$branch_name" || return 1
	_publication_heartbeat "$lease" "$owner_id" &
	heartbeat_pid=$!
	AIDEVOPS_PLANNING_PUSH_GUARD=_publication_push_guard planning_publish "$repo_path" "plan: publish queued task projections" "$remote_name" "$branch_name" "$paths" || rc=$?
	kill "$heartbeat_pid" >/dev/null 2>&1 || true
	wait "$heartbeat_pid" 2>/dev/null || true
	if [[ $rc -eq 0 ]]; then
		commit_sha="$PLANNING_PUBLISHED_COMMIT"
		evidence=$(_publication_evidence "${PLANNING_PUBLISH_RESULT:-published}" "$PLANNING_PUBLICATION_ID" "$commit_sha")
		_publication_finish "$lease" "$owner_id" published "$evidence" || return 1
		return 0
	fi
	retry_after=$((2 ** (attempt - 1)))
	[[ $retry_after -le $PUBLICATION_MAX_BACKOFF ]] || retry_after="$PUBLICATION_MAX_BACKOFF"
	evidence=$(_publication_evidence "retryable_rc_${rc}" "$PLANNING_PUBLICATION_ID")
	_publication_finish "$lease" "$owner_id" retryable "$evidence" "$retry_after" || return 1
	return 0
}

_publication_worker_once() {
	local owner_id="$1"
	local lease=""
	lease=$(node "$COORDINATOR" lease-next --owner-id "$owner_id" --lease-seconds "$PUBLICATION_LEASE_SECONDS" --max-active "$PUBLICATION_MAX_CONCURRENCY") || return 1
	[[ "$(jq -r '.leased' <<<"$lease")" == "true" ]] || return 2
	_publication_process_lease "$lease" "$owner_id"
	return $?
}

publication_worker_run() {
	local launched=0 owner_id="" child_pid="" child_rc=0 overall_rc=0 pids=""
	while [[ $launched -lt $PUBLICATION_MAX_CONCURRENCY ]]; do
		owner_id="publisher-${$}-${launched}"
		_publication_worker_once "$owner_id" &
		child_pid=$!
		pids="${pids} ${child_pid}"
		launched=$((launched + 1))
	done
	for child_pid in $pids; do
		child_rc=0
		wait "$child_pid" || child_rc=$?
		if [[ $child_rc -ne 0 && $child_rc -ne 2 ]]; then
			overall_rc=1
		fi
	done
	return "$overall_rc"
}

main() {
	local command="${1:-run}"
	case "$command" in
	run) publication_worker_run ;;
	once)
		local rc=0
		_publication_worker_once "publisher-${$}-once" || rc=$?
		[[ $rc -eq 2 ]] && return 0
		return "$rc"
		;;
	metrics) node "$COORDINATOR" publication-metrics ;;
	*)
		printf 'Usage: %s {run|once|metrics}\n' "$0" >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
