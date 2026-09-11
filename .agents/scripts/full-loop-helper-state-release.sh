#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Release State -- release authorization, evidence, and receipts
# =============================================================================
# Focused sub-library for full-loop-helper-state.sh. Contains release
# authorization snapshots, release evidence paths, candidate validation, and
# terminal receipt persistence.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-state-release.sh"
#
# Dependencies:
#   - Constants and lifecycle functions from full-loop-helper-state.sh
#   - release-authorization-manifest-helper.sh
#   - full-loop-cleanup-receipt.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_STATE_RELEASE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_RELEASE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_full_loop_release_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_dir="${AIDEVOPS_FULL_LOOP_RECEIPT_DIR:-${HOME}/.aidevops/state/full-loop-release}"
	local safe_repo="${repo//\//_}"
	printf '%s/%s-%s.status\n' "$receipt_dir" "$safe_repo" "$pr_number"
	return 0
}

_full_loop_release_evidence_path() {
	local repo="$1"
	local pr_number="$2"
	local evidence_type="$3"
	local receipt_path=""
	case "$evidence_type" in aggregate | authorization-gap | failure | receipt-conflict | successor) ;; *) return 1 ;; esac
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	printf '%s.%s.json\n' "${receipt_path%.status}" "$evidence_type"
	return 0
}

_full_loop_release_authorization_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	printf '%s.authorization.json\n' "${receipt_path%.status}"
	return 0
}

_full_loop_read_release_authorization() {
	local repo="$1"
	local pr_number="$2"
	local authorization_path=""
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	[[ -f "$authorization_path" ]] || return 2
	jq -er --arg repo "$repo" --argjson pr "$pr_number" '
		select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
		| .expected_sources
		| sort_by(.pr)
		| map("\(.pr)@\(.merge)")
		| join(",")
	' "$authorization_path"
	return $?
}

_full_loop_read_release_authorization_record() {
	local repo="$1"
	local pr_number="$2"
	local authorization_path=""
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	[[ -f "$authorization_path" ]] || return 2
	jq -ce --arg repo "$repo" --argjson pr "$pr_number" '
		select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
	' "$authorization_path"
	return $?
}

_full_loop_write_release_authorization_snapshot() {
	local repo="$1"
	local pr_number="$2"
	local snapshot_json="$3"
	local authorization_path=""
	jq -e --arg repo "$repo" --argjson pr "$pr_number" '
		.schema_version == 1 and .repository == $repo and .requested_pr == $pr
	' <<<"$snapshot_json" >/dev/null || return 1
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	printf '%s\n' "$snapshot_json" >"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_persist_release_authorization() {
	local repo="$1"
	local pr_number="$2"
	local expected_sources="$3"
	local authorization_path=""
	local expected_json=""
	local existing=""
	local now=""
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	expected_sources=$(release_authorization_manifest_string "$expected_sources") || return 1
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	if [[ -f "$authorization_path" ]]; then
		existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
		[[ "$existing" == "$expected_sources" ]] || {
			printf 'Persisted release authorization for PR #%s conflicts with the requested source set\n' "$pr_number" >&2
			return 1
		}
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$pr_number" --argjson expected "$expected_json" --arg now "$now" \
		'{schema_version:1,repository:$repo,requested_pr:$requested_pr,expected_sources:$expected,recorded_at:$now}' \
		>"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_write_release_authorization_record() {
	local repo="$1"
	local pr_number="$2"
	local expected_sources="$3"
	local previous_record="${4:-null}"
	local authorization_path=""
	local expected_json=""
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	if [[ "$previous_record" != "null" ]]; then
		jq -e --arg repo "$repo" --argjson pr "$pr_number" '
			.schema_version == 1 and .repository == $repo and .requested_pr == $pr
		' <<<"$previous_record" >/dev/null || return 1
	fi
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$pr_number" --argjson expected "$expected_json" \
		--argjson previous "$previous_record" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		{schema_version:1,repository:$repo,requested_pr:$requested_pr,expected_sources:$expected,recorded_at:$now}
		+ (if $previous == null then {} else {aggregate_recovery:{previous_authorization:$previous}} end)
	' >"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_read_release_authorization_recovery_snapshot() {
	local repo="$1"
	local pr_number="$2"
	local record=""
	record=$(_full_loop_read_release_authorization_record "$repo" "$pr_number") || return 1
	jq -ce --arg repo "$repo" --argjson pr "$pr_number" '
		.aggregate_recovery.previous_authorization
		| select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
	' <<<"$record"
	return $?
}

_full_loop_expand_release_authorization_for_aggregate() {
	local repo="$1"
	local pr_number="$2"
	local previous_sources="$3"
	local expected_sources="$4"
	local existing=""
	local previous_record=""
	previous_sources=$(release_authorization_manifest_string "$previous_sources") || return 1
	expected_sources=$(release_authorization_manifest_string "$expected_sources") || return 1
	existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
	[[ "$existing" == "$previous_sources" ]] || return 1
	release_authorization_subset "$previous_sources" "$expected_sources" || return 1
	previous_record=$(_full_loop_read_release_authorization_record "$repo" "$pr_number") || return 1
	_full_loop_write_release_authorization_record "$repo" "$pr_number" "$expected_sources" "$previous_record"
	return $?
}

_full_loop_restore_release_authorization_after_aggregate() {
	local repo="$1"
	local pr_number="$2"
	local recovery_sources="$3"
	local previous_sources="$4"
	local existing=""
	local snapshot=""
	local snapshot_sources=""
	recovery_sources=$(release_authorization_manifest_string "$recovery_sources") || return 1
	previous_sources=$(release_authorization_manifest_string "$previous_sources") || return 1
	existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
	[[ "$existing" == "$recovery_sources" ]] || return 1
	snapshot=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$pr_number") || return 1
	snapshot_sources=$(jq -r '.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")' \
		<<<"$snapshot") || return 1
	[[ "$snapshot_sources" == "$previous_sources" ]] || return 1
	_full_loop_write_release_authorization_snapshot "$repo" "$pr_number" "$snapshot"
	return $?
}

_full_loop_write_release_authorization_gap_evidence() {
	local repo="$1"
	local requested_pr="$2"
	local expected_sources="$3"
	local observed_sources="$4"
	local tag_object="$5"
	local release_commit="$6"
	local reason="$7"
	local evidence_path=""
	local expected_json=""
	local observed_json=""
	local now=""
	[[ "$requested_pr" =~ ^[0-9]+$ && "$tag_object" =~ $_FULL_LOOP_SHA40_REGEX && "$release_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ -n "$reason" ]] || return 1
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	observed_json=$(release_authorization_manifest_json "$observed_sources") || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$requested_pr" authorization-gap) || return 1
	if [[ -f "$evidence_path" ]]; then
		jq -e --arg repo "$repo" --argjson requested_pr "$requested_pr" --argjson expected "$expected_json" \
			--argjson observed "$observed_json" --arg tag_object "$tag_object" --arg release_commit "$release_commit" \
			--arg reason "$reason" '
			.schema_version == 1 and .status == "authorization-gap" and .repository == $repo
			and .requested_pr == $requested_pr and .expected_sources == $expected and .observed_sources == $observed
			and .tag_object == $tag_object and .release_commit == $release_commit and .reason == $reason
			and .terminal_cleanup_evidence == false
		' "$evidence_path" >/dev/null 2>&1
		return $?
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$requested_pr" --argjson expected "$expected_json" \
		--argjson observed "$observed_json" --arg tag_object "$tag_object" --arg release_commit "$release_commit" \
		--arg reason "$reason" --arg now "$now" \
		'{schema_version:1,status:"authorization-gap",repository:$repo,requested_pr:$requested_pr,
		  expected_sources:$expected,observed_sources:$observed,tag_object:$tag_object,release_commit:$release_commit,
		  reason:$reason,recorded_at:$now,terminal_cleanup_evidence:false}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	return 0
}

_full_loop_release_candidate_evidence_matches() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local evidence_type="$8"
	local evidence_path=""
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" "$evidence_type") || return 1
	[[ -f "$evidence_path" ]] || return 1
	if [[ "$evidence_type" == "aggregate" ]]; then
		_full_loop_verify_aggregate_superseded_release_evidence \
			"$evidence_path" "$repo" "$pr_number" || return 1
	elif [[ "$evidence_type" == "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" ]]; then
		jq -e --arg repo "$repo" --argjson pr_number "$pr_number" \
			--arg source_merge "$source_merge" --argjson aggregate_pr "$aggregate_pr" \
			--arg aggregate_merge "$aggregate_merge" --arg tag_name "$tag_name" \
			--arg tag_commit "$tag_commit" --arg evidence_status "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" \
			--arg preserved_status "$_FULL_LOOP_RELEASE_NOT_REQUESTED" '
			.schema_version == 1 and .evidence_type == "published-aggregate-terminal-receipt-conflict"
			and .status == $evidence_status and .repository == $repo and .pr_number == $pr_number
			and .source_merge == $source_merge and .aggregate_pr == $aggregate_pr
			and .aggregate_merge == $aggregate_merge and .release_tag == $tag_name
			and .release_commit == $tag_commit and .preserved_receipt_status == $preserved_status
			and (.terminal_cleanup_evidence | not)
		' "$evidence_path" >/dev/null 2>&1
		return $?
	else
		return 1
	fi
	jq -e --arg source_merge "$source_merge" --argjson aggregate_pr "$aggregate_pr" \
		--arg aggregate_merge "$aggregate_merge" --arg tag_name "$tag_name" \
		--arg tag_commit "$tag_commit" '
		.source_merge == $source_merge and .aggregate_pr == $aggregate_pr
		and .aggregate_merge == $aggregate_merge and .release_tag == $tag_name
		and .release_commit == $tag_commit
	' "$evidence_path" >/dev/null 2>&1
	return $?
}

_full_loop_write_release_receipt_conflict_evidence() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local receipt_path=""
	local receipt_status=""
	local evidence_path=""
	local now=""
	[[ "$pr_number" =~ ^[0-9]+$ && "$aggregate_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT") || return 1
	if [[ -f "$evidence_path" ]]; then
		_full_loop_release_candidate_evidence_matches "$repo" "$pr_number" "$source_merge" \
			"$aggregate_pr" "$aggregate_merge" "$tag_name" "$tag_commit" \
			"$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT"
		return $?
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson pr_number "$pr_number" --arg source_merge "$source_merge" \
		--argjson aggregate_pr "$aggregate_pr" --arg aggregate_merge "$aggregate_merge" \
		--arg tag_name "$tag_name" --arg tag_commit "$tag_commit" \
		--arg evidence_status "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" \
		--arg preserved_status "$_FULL_LOOP_RELEASE_NOT_REQUESTED" --argjson terminal_cleanup_evidence false \
		--arg now "$now" '
		{schema_version:1,evidence_type:"published-aggregate-terminal-receipt-conflict",
		 status:$evidence_status,repository:$repo,pr_number:$pr_number,source_merge:$source_merge,
		 aggregate_pr:$aggregate_pr,aggregate_merge:$aggregate_merge,release_tag:$tag_name,
		 release_commit:$tag_commit,preserved_receipt_status:$preserved_status,recorded_at:$now,
		 terminal_cleanup_evidence:$terminal_cleanup_evidence}
	' >"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	return 0
}

_full_loop_read_release_receipt_status() {
	local receipt_path="$1"
	local receipt_status=""
	[[ -n "$receipt_path" ]] || return 1
	if [[ ! -e "$receipt_path" && ! -L "$receipt_path" ]]; then
		printf '\n'
		return 0
	fi
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ -n "$receipt_status" ]] || return 1
	printf '%s\n' "$receipt_status"
	return 0
}

_full_loop_validate_release_candidates() {
	local repo="$1"
	local source_json="$2"
	local mode="${3:-$_FULL_LOOP_RELEASE_STRICT}"
	local tag_name="${4:-}"
	local tag_commit="${5:-}"
	local source_pr=""
	local source_merge=""
	local candidate_rows=""
	local candidate_pr=""
	local candidate_merge=""
	local candidate_role=""
	local candidate_status=""
	local candidate_receipt=""
	local conflict_path=""
	source_pr=$(jq -er '.source_pr' <<<"$source_json") || return 1
	source_merge=$(jq -er '.source_merge' <<<"$source_json") || return 1
	candidate_rows=$(jq -er --arg aggregate_role "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED" \
		'.source_pr as $source | [{pr:.source_pr,merge:.source_merge,role:"source"}]
		+ [.aggregated_sources[] | select(.pr != $source) | {pr,merge,role:$aggregate_role}]
		| .[] | [.pr,.merge,.role] | @tsv' <<<"$source_json") || return 1
	if [[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
		"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]]; then
		[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	elif [[ "$mode" != "$_FULL_LOOP_RELEASE_STRICT" ]]; then
		return 1
	fi
	while IFS=$'\t' read -r candidate_pr candidate_merge candidate_role; do
		[[ "$candidate_pr" =~ ^[0-9]+$ && "$candidate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
		candidate_receipt=$(_full_loop_release_receipt_path "$repo" "$candidate_pr") || return 1
		candidate_status=$(_full_loop_read_release_receipt_status "$candidate_receipt") || return 1
		case "$candidate_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED") ;;
		"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
			[[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ||
				("$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" &&
				"$candidate_role" == "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED") ]] || {
				printf 'Cannot aggregate terminal release:%s evidence for PR #%s\n' "$candidate_status" "$candidate_pr" >&2
				return 1
			}
			conflict_path=$(_full_loop_release_evidence_path "$repo" "$candidate_pr" "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT") || return 1
			if [[ -f "$conflict_path" ]]; then
				_full_loop_release_candidate_evidence_matches "$repo" "$candidate_pr" "$candidate_merge" \
					"$source_pr" "$source_merge" "$tag_name" "$tag_commit" \
					"$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" || return 1
			fi
			;;
		"$_FULL_LOOP_RELEASE_SUPERSEDED")
			[[ ("$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED") &&
				"$candidate_role" == "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED" ]] || return 1
			_full_loop_release_candidate_evidence_matches "$repo" "$candidate_pr" "$candidate_merge" \
				"$source_pr" "$source_merge" "$tag_name" "$tag_commit" aggregate || return 1
			;;
		"$_FULL_LOOP_RELEASE_PUBLISHED")
			[[ ("$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED") &&
				"$candidate_role" == "source" ]] || return 1
			;;
		*)
			printf 'Cannot aggregate terminal release:%s evidence for PR #%s\n' "$candidate_status" "$candidate_pr" >&2
			return 1
			;;
		esac
	done <<<"$candidate_rows"
	return 0
}

_full_loop_persist_release_success() {
	local repo="$1"
	local release_path="$2"
	local source_json="$3"
	local release_source_pr="$4"
	local release_source_merge="$5"
	local mode="${6:-strict}"
	local version=""
	local tag_name=""
	local tag_commit=""
	local aggregated_rows=""
	local aggregated_pr=""
	local aggregated_merge=""
	local receipt_path=""
	local receipt_status=""
	IFS= read -r version <"$release_path/VERSION" || return 1
	tag_name="v${version}"
	tag_commit=$(git -C "$release_path" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	aggregated_rows=$(jq -r '.source_pr as $source | .aggregated_sources[] | select(.pr != $source) | [.pr,.merge] | @tsv' <<<"$source_json") || return 1
	while IFS=$'\t' read -r aggregated_pr aggregated_merge; do
		[[ -n "$aggregated_pr" ]] || continue
		receipt_path=$(_full_loop_release_receipt_path "$repo" "$aggregated_pr") || return 1
		receipt_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
		case "$receipt_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED")
			_full_loop_write_superseded_release_receipt "$repo" "$aggregated_pr" "$aggregated_merge" \
				"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			;;
		"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
			if [[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]]; then
				_full_loop_write_superseded_release_receipt "$repo" "$aggregated_pr" "$aggregated_merge" \
					"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			else
				_full_loop_write_release_receipt_conflict_evidence "$repo" "$aggregated_pr" "$aggregated_merge" \
					"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			fi
			;;
		"$_FULL_LOOP_RELEASE_SUPERSEDED")
			[[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
			_full_loop_release_candidate_evidence_matches "$repo" "$aggregated_pr" "$aggregated_merge" \
				"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" aggregate || return 1
			_full_loop_update_superseded_cleanup_receipt "$repo" "$aggregated_pr" || return 1
			;;
		*) return 1 ;;
		esac
	done <<<"$aggregated_rows"
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$release_source_pr") || return 1
	receipt_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
	case "$receipt_status" in
	"" | "$_FULL_LOOP_PHASE_FAILED")
		_full_loop_write_release_receipt "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		[[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ||
			"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
		_full_loop_write_release_receipt "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		full_loop_update_cleanup_release_status "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED")
		[[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
			"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

_full_loop_write_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local status="$3"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$status" == "$_FULL_LOOP_PHASE_FAILED" ]] || return 1
	local receipt_path=""
	local current_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	mkdir -p "${receipt_path%/*}" || return 1
	current_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
	case "${current_status}:${status}" in
	"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_NOT_REQUESTED}" | \
		"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_PUBLISHED}" | \
		"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_SUPERSEDED}" | \
		"${_FULL_LOOP_RELEASE_PUBLISHED}:${_FULL_LOOP_RELEASE_PUBLISHED}" | \
		"${_FULL_LOOP_RELEASE_SUPERSEDED}:${_FULL_LOOP_RELEASE_SUPERSEDED}") ;;
	"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:"* | \
		"${_FULL_LOOP_RELEASE_PUBLISHED}:"* | \
		"${_FULL_LOOP_RELEASE_SUPERSEDED}:"*)
		return 1
		;;
	esac
	printf '%s\n' "$status" >"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	if [[ "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		local failure_path=""
		failure_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" failure) || return 1
		rm -f "$failure_path" || return 1
	fi
	return 0
}

_full_loop_release_expected_tag_at_commit() {
	local source_commit="$1"
	local release_type="$2"
	local version=""
	local major=""
	local minor=""
	local patch=""
	[[ "$source_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	case "$release_type" in patch | minor | major) ;; *) return 1 ;; esac
	version=$(git -C "$REPO_ROOT" show "${source_commit}:VERSION" 2>/dev/null) || return 1
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	IFS='.' read -r major minor patch <<<"$version"
	case "$release_type" in
	patch) patch=$((patch + 1)) ;;
	minor)
		minor=$((minor + 1))
		patch=0
		;;
	major)
		major=$((major + 1))
		minor=0
		patch=0
		;;
	esac
	printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
	return 0
}
