#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Checkout-free publication of TODO.md and todo/** changes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PLANNING_PUBLISHER_LOADED:-}" ]] && return 0
_PLANNING_PUBLISHER_LOADED=1

PLANNING_PUBLISH_MAX_RETRIES="${PLANNING_PUBLISH_MAX_RETRIES:-3}"
PLANNING_PUBLISH_RESULT=""
PLANNING_PUBLICATION_ID=""
PLANNING_PUBLISHED_COMMIT=""

_planning_publish_log() {
	local level="$1"
	local message="$2"
	if command -v "log_${level}" >/dev/null 2>&1; then
		"log_${level}" "$message"
	else
		printf '[planning-publisher][%s] %s\n' "$level" "$message" >&2
	fi
	return 0
}

_planning_publish_path_allowed() {
	local path="$1"
	case "$path" in
	TODO.md | todo/*)
		[[ "$path" != *'..'* && "$path" != *'//'* && "$path" != */ ]]
		return $?
		;;
	*) return 1 ;;
	esac
}

_planning_publish_changed_paths() {
	local repo_path="$1"
	{
		git -C "$repo_path" diff --name-only HEAD -- TODO.md todo/ 2>/dev/null || true
		git -C "$repo_path" diff --name-only --cached -- TODO.md todo/ 2>/dev/null || true
		git -C "$repo_path" ls-files --others --exclude-standard -- TODO.md todo/ 2>/dev/null || true
	} | LC_ALL=C sort -u | grep -v '^$' || true
	return 0
}

_planning_publish_snapshot() {
	local repo_path="$1"
	local paths="$2"
	local snapshot_file="$3"
	local path=""
	: >"$snapshot_file" || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		_planning_publish_path_allowed "$path" || {
			_planning_publish_log error "Unauthorized planning path: $path"
			return 1
		}
		if [[ -L "${repo_path}/${path}" ]] || [[ -d "${repo_path}/${path}" ]]; then
			_planning_publish_log error "Planning paths must be regular files: $path"
			return 1
		fi
		if [[ -f "${repo_path}/${path}" ]]; then
			local blob_sha=""
			blob_sha=$(git -C "$repo_path" hash-object -w -- "${repo_path}/${path}") || return 1
			printf 'file\t%s\t%s\n' "$blob_sha" "$path" >>"$snapshot_file" || return 1
		else
			printf 'delete\t-\t%s\n' "$path" >>"$snapshot_file" || return 1
		fi
	done <<<"$paths"
	return 0
}

_planning_publish_build_index() {
	local repo_path="$1"
	local parent_sha="$2"
	local snapshot_file="$3"
	local index_file="$4"
	local operation="" blob_sha="" path=""
	rm -f "$index_file" || return 1
	GIT_INDEX_FILE="$index_file" git -C "$repo_path" read-tree "$parent_sha" || return 1
	while IFS=$'\t' read -r operation blob_sha path; do
		[[ -n "$path" ]] || continue
		if [[ "$operation" == "file" ]]; then
			GIT_INDEX_FILE="$index_file" git -C "$repo_path" update-index --add --cacheinfo "100644,${blob_sha},${path}" || return 1
		else
			GIT_INDEX_FILE="$index_file" git -C "$repo_path" update-index --force-remove -- "$path" || return 1
		fi
	done <"$snapshot_file"
	return 0
}

_planning_publish_verify_index() {
	local repo_path="$1"
	local parent_sha="$2"
	local snapshot_file="$3"
	local index_file="$4"
	local changed_path="" operation="" expected_sha="" path="" staged_sha=""
	while IFS= read -r changed_path; do
		[[ -n "$changed_path" ]] || continue
		_planning_publish_path_allowed "$changed_path" || return 1
	done < <(GIT_INDEX_FILE="$index_file" git -C "$repo_path" diff --cached --name-only "$parent_sha")
	while IFS=$'\t' read -r operation expected_sha path; do
		if [[ "$operation" == "file" ]]; then
			staged_sha=$(GIT_INDEX_FILE="$index_file" git -C "$repo_path" rev-parse ":${path}" 2>/dev/null) || return 1
			[[ "$staged_sha" == "$expected_sha" ]] || return 1
		elif GIT_INDEX_FILE="$index_file" git -C "$repo_path" rev-parse ":${path}" >/dev/null 2>&1; then
			return 1
		fi
	done <"$snapshot_file"
	return 0
}

_planning_publish_validate() {
	local repo_path="$1"
	local parent_sha="$2"
	local candidate_sha="$3"
	local index_file="$4"
	local validator="${AIDEVOPS_PLANNING_VALIDATOR:-}"
	if [[ -n "$validator" ]]; then
		GIT_INDEX_FILE="$index_file" "$validator" "$repo_path" "$parent_sha" "$candidate_sha"
		return $?
	fi
	local hook="${SCRIPT_DIR:-${repo_path}/.agents/scripts}/pre-commit-hook.sh"
	if [[ -x "$hook" ]]; then
		(cd "$repo_path" && GIT_INDEX_FILE="$index_file" HOOK_MODE=pre-commit "$hook" >/dev/null) || return 1
	fi
	local privacy_lib="${SCRIPT_DIR:-${repo_path}/.agents/scripts}/privacy-guard-helper.sh"
	if [[ -f "$privacy_lib" ]]; then
		# shellcheck disable=SC1090
		source "$privacy_lib"
		local privacy_hits="" slugs_file=""
		slugs_file=$(mktemp "${TMPDIR:-/tmp}/planning-private-slugs.XXXXXX") || return 1
		privacy_enumerate_private_slugs "$slugs_file" >/dev/null 2>&1 || true
		privacy_hits=$(cd "$repo_path" && {
			privacy_scan_secret_material_diff "$parent_sha" "$candidate_sha" 2>/dev/null || true
			privacy_scan_diff "$parent_sha" "$candidate_sha" "$slugs_file" 2>/dev/null || true
		})
		rm -f "$slugs_file"
		[[ -z "$privacy_hits" ]] || return 1
	fi
	return 0
}

_planning_publish_parent_conflicts() {
	local repo_path="$1"
	local old_parent="$2"
	local new_parent="$3"
	local snapshot_file="$4"
	local operation="" blob_sha="" path=""
	while IFS=$'\t' read -r operation blob_sha path; do
		if ! git -C "$repo_path" diff --quiet "$old_parent" "$new_parent" -- "$path"; then
			return 0
		fi
	done <"$snapshot_file"
	return 1
}

_planning_publish_push() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local parent_sha="$4"
	local candidate_sha="$5"
	if [[ -n "${AIDEVOPS_PLANNING_FENCE_REF:-}" && -n "${AIDEVOPS_PLANNING_FENCE_SHA:-}" ]]; then
		git -C "$repo_path" push -q --atomic \
			--force-with-lease="refs/heads/${branch_name}:${parent_sha}" \
			--force-with-lease="${AIDEVOPS_PLANNING_FENCE_REF}:${AIDEVOPS_PLANNING_FENCE_SHA}" \
			"$remote_name" "${candidate_sha}:refs/heads/${branch_name}" \
			"${AIDEVOPS_PLANNING_FENCE_SHA}:${AIDEVOPS_PLANNING_FENCE_REF}"
		return $?
	fi
	git -C "$repo_path" push -q --force-with-lease="refs/heads/${branch_name}:${parent_sha}" "$remote_name" "${candidate_sha}:refs/heads/${branch_name}"
	return $?
}

planning_publish() {
	local repo_path="$1"
	local commit_msg="$2"
	local remote_name="${3:-origin}"
	local branch_name="${4:-}"
	local paths="${5:-}"
	local temp_dir="" snapshot_file="" index_file="" parent_sha="" tree_sha="" candidate_sha=""
	local publication_id="" attempt=0 push_rc=0 latest_sha=""

	[[ -n "$branch_name" ]] || branch_name=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null) || return 1
	[[ -n "$paths" ]] || paths=$(_planning_publish_changed_paths "$repo_path")
	if [[ -z "$paths" ]]; then
		PLANNING_PUBLISH_RESULT="noop"
		return 0
	fi
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/planning-publisher.XXXXXX") || return 1
	snapshot_file="${temp_dir}/snapshot"
	index_file="${temp_dir}/index"
	_planning_publish_snapshot "$repo_path" "$paths" "$snapshot_file" || {
		rm -rf "$temp_dir"
		return 1
	}
	publication_id=$(git -C "$repo_path" hash-object "$snapshot_file") || {
		rm -rf "$temp_dir"
		return 1
	}
	PLANNING_PUBLICATION_ID="$publication_id"

	while [[ $attempt -lt $PLANNING_PUBLISH_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))
		git -C "$repo_path" fetch -q "$remote_name" "$branch_name" || {
			rm -rf "$temp_dir"
			return 1
		}
		latest_sha=$(git -C "$repo_path" rev-parse FETCH_HEAD) || {
			rm -rf "$temp_dir"
			return 1
		}
		if [[ -n "$parent_sha" ]] && _planning_publish_parent_conflicts "$repo_path" "$parent_sha" "$latest_sha" "$snapshot_file"; then
			_planning_publish_log warning "AIDEVOPS_PLANNING_PUBLISH_STATUS=retryable_conflict publication_id=${publication_id}"
			rm -rf "$temp_dir"
			return 2
		fi
		parent_sha="$latest_sha"
		_planning_publish_build_index "$repo_path" "$parent_sha" "$snapshot_file" "$index_file" || {
			rm -rf "$temp_dir"
			return 1
		}
		_planning_publish_verify_index "$repo_path" "$parent_sha" "$snapshot_file" "$index_file" || {
			rm -rf "$temp_dir"
			return 1
		}
		tree_sha=$(GIT_INDEX_FILE="$index_file" git -C "$repo_path" write-tree) || {
			rm -rf "$temp_dir"
			return 1
		}
		if [[ "$tree_sha" == "$(git -C "$repo_path" rev-parse "${parent_sha}^{tree}")" ]]; then
			PLANNING_PUBLISH_RESULT="noop"
			PLANNING_PUBLISHED_COMMIT="$parent_sha"
			rm -rf "$temp_dir"
			return 0
		fi
		candidate_sha=$(printf '%s\n\nPlanning-Publication-ID: %s\n' "$commit_msg" "$publication_id" | git -C "$repo_path" commit-tree "$tree_sha" -p "$parent_sha") || {
			rm -rf "$temp_dir"
			return 1
		}
		if ! _planning_publish_validate "$repo_path" "$parent_sha" "$candidate_sha" "$index_file"; then
			_planning_publish_log error "Planning publication validation failed; nothing pushed"
			rm -rf "$temp_dir"
			return 1
		fi
		if [[ -n "${AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK:-}" ]]; then
			"$AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK" "$repo_path" "$remote_name" "$branch_name" "$parent_sha" "$candidate_sha" "$attempt" || {
				rm -rf "$temp_dir"
				return 1
			}
		fi
		if [[ -n "${AIDEVOPS_PLANNING_PUSH_GUARD:-}" ]]; then
			"$AIDEVOPS_PLANNING_PUSH_GUARD" "$repo_path" "$remote_name" "$branch_name" "$parent_sha" "$candidate_sha" "$attempt" || {
				rm -rf "$temp_dir"
				return 3
			}
		fi
		push_rc=0
		_planning_publish_push "$repo_path" "$remote_name" "$branch_name" "$parent_sha" "$candidate_sha" || push_rc=$?
		if [[ $push_rc -eq 0 ]]; then
			PLANNING_PUBLISH_RESULT="published"
			PLANNING_PUBLISHED_COMMIT="$candidate_sha"
			_planning_publish_log success "Published planning files (${publication_id})"
			rm -rf "$temp_dir"
			return 0
		fi
	done
	_planning_publish_log warning "AIDEVOPS_PLANNING_PUBLISH_STATUS=retryable_conflict publication_id=${publication_id}"
	rm -rf "$temp_dir"
	return 2
}
