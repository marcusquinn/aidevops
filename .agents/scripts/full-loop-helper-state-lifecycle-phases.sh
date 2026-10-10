#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Phase emitters and release integration for the lifecycle orchestrator.
# Inherits globals and dependencies from full-loop-helper-state-lifecycle.sh.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_STATE_PHASES_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_PHASES_LOADED=1

# --- Phase Emitters ---
# Drive the AI loop per full-loop.md

emit_task_phase() {
	print_phase "Task Development" "AI will iterate on task until TASK_COMPLETE"
	echo "PROMPT: $1"
	echo "When complete, emit: <promise>TASK_COMPLETE</promise>"
}
emit_preflight_phase() {
	print_phase "Preflight" "AI runs quality checks"
	[[ "${SKIP_PREFLIGHT:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] && {
		print_warning "Preflight skipped"
		echo "<promise>PREFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Run quality checks per full-loop.md guidance."
}
emit_pr_create_phase() {
	print_phase "PR Creation" "AI creates pull request"
	[[ "${NO_AUTO_PR:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] && ! is_headless && {
		print_warning "Auto PR disabled"
		return 0
	}
	echo "Create PR per full-loop.md guidance."
}
emit_pr_review_phase() {
	print_phase "PR Review" "AI monitors CI and reviews"
	echo "Monitor PR per full-loop.md guidance."
}
emit_postflight_phase() {
	print_phase "Postflight" "AI verifies release health"
	[[ "${RELEASE_INTENT:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] || {
		RELEASE_STATUS="$_FULL_LOOP_RELEASE_NOT_REQUESTED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_info "release:not-requested — publication was not explicitly authorized"
		return 0
	}
	if [[ "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		print_info "release:${RELEASE_STATUS} — publication gate already completed"
		return 0
	fi
	if ! _full_loop_invoke_authorized_release; then
		RELEASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_error "release:failed"
		return 1
	fi
	if ! _full_loop_reconcile_detached_publication_receipt; then
		RELEASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_error "release:failed — terminal detached receipt is missing"
		return 1
	fi
	print_success "release:${RELEASE_STATUS}"
	[[ "${SKIP_POSTFLIGHT:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] && {
		print_warning "Postflight skipped"
		echo "<promise>POSTFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Verify release per full-loop.md guidance."
}

# Release authorization, evidence, and receipt persistence.
# shellcheck source=./full-loop-helper-state-release.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state-release.sh"

_full_loop_write_release_failure_evidence() {
	local repo="$1"
	local requested_pr="$2"
	local requested_merge="$3"
	local current_head="$4"
	local release_source_pr="${5:-}"
	local attempted_tag="${6:-}"
	local release_type="${7:-}"
	local evidence_path=""
	local now=""
	[[ "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	[[ -z "$release_source_pr" || "$release_source_pr" =~ ^[0-9]+$ ]] || return 1
	[[ -z "$attempted_tag" || "$attempted_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ -z "$release_type" || "$release_type" == "patch" || "$release_type" == "minor" || "$release_type" == "major" ]] || return 1
	[[ (-z "$attempted_tag" && -z "$release_type") || (-n "$attempted_tag" && -n "$release_type") ]] || return 1
	[[ "$requested_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$current_head" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$requested_pr" failure) || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$requested_pr" --arg requested_merge "$requested_merge" \
		--arg release_source_pr "$release_source_pr" --arg current_head "$current_head" \
		--arg attempted_tag "$attempted_tag" --arg release_type "$release_type" --arg now "$now" \
		'{schema_version:1,status:"failed",repository:$repo,requested_pr:$requested_pr,requested_merge:$requested_merge,
		  release_source_pr:(if $release_source_pr == "" then null else ($release_source_pr | tonumber) end),current_head:$current_head,
		  attempted_tag:(if $attempted_tag == "" then null else $attempted_tag end),
		  release_type:(if $release_type == "" then null else $release_type end),recorded_at:$now}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	_full_loop_write_release_receipt "$repo" "$requested_pr" "$_FULL_LOOP_PHASE_FAILED"
	return $?
}

_full_loop_write_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local evidence_path=""
	local successor_path=""
	local now=""
	[[ "$pr_number" =~ ^[0-9]+$ && "$aggregate_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" aggregate) || return 1
	successor_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" successor) || return 1
	[[ ! -e "$successor_path" ]] || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --arg status "$_FULL_LOOP_RELEASE_SUPERSEDED" --argjson pr_number "$pr_number" --arg source_merge "$source_merge" \
		--argjson aggregate_pr "$aggregate_pr" --arg aggregate_merge "$aggregate_merge" \
		--arg tag "$tag_name" --arg tag_commit "$tag_commit" --arg now "$now" \
		'{schema_version:1,status:$status,repository:$repo,pr_number:$pr_number,source_merge:$source_merge,
		  aggregate_pr:$aggregate_pr,aggregate_merge:$aggregate_merge,release_tag:$tag,release_commit:$tag_commit,recorded_at:$now}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	_full_loop_update_superseded_cleanup_receipt "$repo" "$pr_number"
	return $?
}

_full_loop_update_superseded_cleanup_receipt() {
	local repo="$1"
	local pr_number="$2"
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	fi
	return 0
}

_full_loop_verify_aggregate_superseded_release_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	[[ "$evidence_path" == *.aggregate.json ]] || return 1
	_full_loop_validate_superseded_evidence "$evidence_path" "$repo" "$pr_number"
	return $?
}

_full_loop_verify_successor_superseded_release_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	[[ "$evidence_path" == *.successor.json ]] || return 1
	_full_loop_validate_superseded_evidence "$evidence_path" "$repo" "$pr_number"
	return $?
}

_full_loop_superseded_release_evidence_path() {
	local repo="$1"
	local pr_number="$2"
	local aggregate_path=""
	local successor_path=""
	local evidence_path=""
	aggregate_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" aggregate) || return 1
	successor_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" successor) || return 1
	if [[ -f "$aggregate_path" ]]; then
		_full_loop_verify_aggregate_superseded_release_evidence \
			"$aggregate_path" "$repo" "$pr_number" || return 1
		evidence_path="$aggregate_path"
	fi
	if [[ -f "$successor_path" ]]; then
		[[ -z "$evidence_path" ]] || return 1
		_full_loop_verify_successor_superseded_release_evidence \
			"$successor_path" "$repo" "$pr_number" || return 1
		evidence_path="$successor_path"
	fi
	[[ -n "$evidence_path" ]] || return 1
	printf '%s\n' "$evidence_path"
	return 0
}

_full_loop_verify_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	_full_loop_superseded_release_evidence_path "$repo" "$pr_number" >/dev/null
	return $?
}

_full_loop_write_successor_release_receipt() {
	local repo="$1"
	local source_pr="$2"
	local source_merge="$3"
	local source_tag="$4"
	local source_commit="$5"
	local source_run="$6"
	local successor_pr="$7"
	local successor_merge="$8"
	local release_tag="$9"
	shift 9
	local release_commit="$1"
	local release_run="$2"
	local aggregate_path=""
	local evidence_path=""
	local now=""
	[[ "$source_pr" =~ ^[0-9]+$ && "$successor_pr" =~ ^[0-9]+$ && "$source_pr" != "$successor_pr" ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$successor_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$source_commit" =~ $_FULL_LOOP_SHA40_REGEX && "$release_commit" =~ $_FULL_LOOP_SHA40_REGEX && "$source_commit" != "$release_commit" ]] || return 1
	[[ "$source_tag" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$release_tag" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$source_tag" != "$release_tag" ]] || return 1
	[[ "$source_run" =~ ^[0-9]+$ && "$release_run" =~ ^[0-9]+$ && "$source_run" -gt 0 && "$release_run" -gt 0 && "$source_run" != "$release_run" ]] || return 1
	aggregate_path=$(_full_loop_release_evidence_path "$repo" "$source_pr" aggregate) || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$source_pr" successor) || return 1
	[[ ! -e "$aggregate_path" ]] || return 1
	if [[ -f "$evidence_path" ]]; then
		_full_loop_verify_successor_superseded_release_evidence \
			"$evidence_path" "$repo" "$source_pr" || return 1
		jq -e --arg source_merge "$source_merge" --arg source_tag "$source_tag" \
			--arg source_commit "$source_commit" --argjson source_run "$source_run" \
			--argjson successor_pr "$successor_pr" --arg successor_merge "$successor_merge" \
			--arg release_tag "$release_tag" --arg release_commit "$release_commit" \
			--argjson release_run "$release_run" '
			.source_merge == $source_merge and .source_release_tag == $source_tag
			and .source_release_commit == $source_commit and .source_workflow_run == $source_run
			and .successor_pr == $successor_pr and .successor_merge == $successor_merge
			and .release_tag == $release_tag and .release_commit == $release_commit
			and .release_workflow_run == $release_run
		' "$evidence_path" >/dev/null 2>&1 || return 1
	else
		now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		mkdir -p "${evidence_path%/*}" || return 1
		jq -cn --arg repo "$repo" --arg status "$_FULL_LOOP_RELEASE_SUPERSEDED" \
			--arg evidence_type "post-publication-supersession" --argjson source_pr "$source_pr" \
			--arg source_merge "$source_merge" --arg source_tag "$source_tag" \
			--arg source_commit "$source_commit" --argjson source_run "$source_run" \
			--argjson successor_pr "$successor_pr" --arg successor_merge "$successor_merge" \
			--arg release_tag "$release_tag" --arg release_commit "$release_commit" \
			--argjson release_run "$release_run" --arg now "$now" '
			{schema_version:1,evidence_type:$evidence_type,status:$status,repository:$repo,
			 pr_number:$source_pr,source_pr:$source_pr,source_merge:$source_merge,
			 source_release_tag:$source_tag,source_release_commit:$source_commit,
			 source_workflow_run:$source_run,successor_pr:$successor_pr,successor_merge:$successor_merge,
			 release_tag:$release_tag,release_commit:$release_commit,
			 release_workflow_run:$release_run,recorded_at:$now}
		' >"${evidence_path}.tmp.$$" || return 1
		mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	fi
	_full_loop_write_release_receipt "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	_full_loop_update_superseded_cleanup_receipt "$repo" "$source_pr"
	return $?
}

_full_loop_persist_release_status() {
	local status="$1"
	local repo=""
	[[ "$status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$status" == "$_FULL_LOOP_PHASE_FAILED" ]] || return 1
	if [[ -f "$STATE_FILE" ]]; then
		save_state "${CURRENT_PHASE:-${PHASE:-postflight}}" "$SAVED_PROMPT" "${PR_NUMBER:-}" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	fi
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || return 0
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	_full_loop_write_release_receipt "$repo" "$PR_NUMBER" "$status"
	return $?
}

_full_loop_invoke_authorized_release() {
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || {
		print_error "Authorized release requires a persisted PR number"
		return 1
	}
	local reconciliation_status=0
	_full_loop_reconcile_detached_publication_receipt || reconciliation_status=$?
	case "$reconciliation_status" in
	0) return 0 ;;
	2)
		print_error "release:published receipt could not be reconciled into lifecycle state"
		return 1
		;;
	esac
	local runner="${AIDEVOPS_FULL_LOOP_RELEASE_RUNNER:-${SCRIPT_DIR}/full-loop-release-helper.sh}"
	[[ -x "$runner" ]] || {
		print_error "Authorized release runner is unavailable: $runner"
		return 1
	}
	AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
		AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
		AIDEVOPS_RELEASE_EXPECTED_SOURCES="${RELEASE_EXPECTED_SOURCES:-}" \
		"$runner" "$RELEASE_TYPE" "$PR_NUMBER" "$DEPLOYMENT_SCOPE"
	return $?
}
emit_deploy_phase() {
	print_phase "Deploy" "AI deploys changes"
	[[ "${RELEASE_INTENT:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] || {
		print_info "release:not-requested — deployment skipped"
		return 0
	}
	[[ "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] && {
		print_info "release:${RELEASE_STATUS} — deployment completed by the release runner"
		return 0
	}
	! is_aidevops_repo && {
		print_info "Not aidevops repo, skipping deploy"
		return 0
	}
	[[ "${NO_AUTO_DEPLOY:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] && {
		print_warning "Auto deploy disabled"
		return 0
	}
	echo "Run setup.sh per full-loop.md guidance."
}
