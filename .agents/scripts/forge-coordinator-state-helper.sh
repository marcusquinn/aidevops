#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly RESTORE_DEFERRED_MARKER=".restore-deferred"
readonly RESTORE_EMPTY_INIT_MARKER=".restore-empty-init"

print_error_file() {
	local error_file="$1"
	local line=""
	while IFS= read -r line; do
		printf '%s\n' "$line" >&2
	done <"$error_file"
	return 0
}

is_github_rate_limited() {
	local error_file="$1"
	grep -qiE 'API rate limit exceeded|GraphQL: API rate limit (already )?exceeded|secondary rate limit|abuse detection|was submitted too quickly' "$error_file" && return 0
	return 1
}

defer_restore() {
	local state_dir="$1"
	local repository="$2"
	local reason="$3"
	touch "${state_dir}/${RESTORE_DEFERRED_MARKER}" || return 1
	printf '::warning title=Coordinator restore deferred::%s for %s; preserving the latest durable checkpoint and skipping event publication.\n' "$reason" "$repository" >&2
	return 0
}

defer_rate_limited_restore() {
	local state_dir="$1"
	local repository="$2"
	local error_file="$3"
	print_error_file "$error_file"
	defer_restore "$state_dir" "$repository" "GitHub API rate limit is exhausted" || return 1
	return 0
}

restore_state() {
	local state_dir="$1"
	local repository="$2"
	local repository_id="$3"
	local artifact_name="forge-coordinator-${repository_id}"
	local artifact_id="" artifact_json="" archive="" error_file=""
	local legacy_count="" legacy_total=""
	mkdir -p "$state_dir"
	rm -f "${state_dir}/${RESTORE_DEFERRED_MARKER}" "${state_dir}/${RESTORE_EMPTY_INIT_MARKER}"
	error_file=$(mktemp "${state_dir}/restore-error.XXXXXX") || return 1

	# New checkpoints use one stable name, allowing GitHub to filter server-side.
	# This replaces the former --paginate scan across every repository artifact.
	if ! artifact_json=$(gh api "repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=1" 2>"$error_file"); then
		if is_github_rate_limited "$error_file"; then
			defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
			rm -f "$error_file"
			return 0
		fi
		print_error_file "$error_file"
		rm -f "$error_file"
		return 1
	fi
	artifact_id=$(jq -r --arg name "$artifact_name" '[.artifacts[]? | select((.name == $name) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
		rm -f "$error_file"
		return 1
	}

	# One bounded legacy page migrates checkpoints written with run-ID suffixes.
	if [[ -z "$artifact_id" ]]; then
		if ! artifact_json=$(gh api "repos/${repository}/actions/artifacts?per_page=100" 2>"$error_file"); then
			if is_github_rate_limited "$error_file"; then
				defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
				rm -f "$error_file"
				return 0
			fi
			print_error_file "$error_file"
			rm -f "$error_file"
			return 1
		fi
		artifact_id=$(jq -r --arg prefix "${artifact_name}-" '[.artifacts[]? | select((.name | startswith($prefix)) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		legacy_count=$(jq -r '.artifacts | length' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		legacy_total=$(jq -r '.total_count // (.artifacts | length)' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		if [[ -z "$artifact_id" && "$legacy_count" =~ ^[0-9]+$ && "$legacy_total" =~ ^[0-9]+$ ]] && ((legacy_total > legacy_count)); then
			touch "${state_dir}/${RESTORE_EMPTY_INIT_MARKER}" || {
				rm -f "$error_file"
				return 1
			}
			printf '::warning title=Coordinator state initialized::No matching checkpoint was found in the bounded legacy artifact page for %s; initializing one stable-name checkpoint without scanning all repository artifacts.\n' "$repository" >&2
		fi
	fi
	if [[ -z "$artifact_id" ]]; then
		rm -f "$error_file"
		return 0
	fi
	if [[ ! "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid coordinator artifact ID returned for repository %s: %q\n' "$repository" "$artifact_id" >&2
		rm -f "$error_file"
		return 1
	fi
	archive="${state_dir}/state.zip"
	if ! gh api "repos/${repository}/actions/artifacts/${artifact_id}/zip" >"$archive" 2>"$error_file"; then
		rm -f "$archive"
		if is_github_rate_limited "$error_file"; then
			defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
			rm -f "$error_file"
			return 0
		fi
		print_error_file "$error_file"
		rm -f "$error_file"
		return 1
	fi
	if ! unzip -oq "$archive" -d "$state_dir"; then
		rm -f "$archive" "$error_file"
		return 1
	fi
	rm -f "$archive" "$error_file"
	return 0
}

cleanup_state() {
	local mode="$1"
	local repository="$2"
	local repository_id="$3"
	local protected_artifact_id="$4"
	local artifact_name="forge-coordinator-${repository_id}"
	local inventory_file="" candidate_file="" fallback_artifact_id=""
	local total_count="" retained_count="" candidate_count="" candidate_bytes=""
	local artifact_id="" artifact_size="" cleanup_failed=0

	[[ "$mode" == "plan" || "$mode" == "apply" ]] || {
		printf 'Invalid cleanup mode: %s\n' "$mode" >&2
		return 1
	}
	[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
		printf 'Invalid repository slug: %s\n' "$repository" >&2
		return 1
	}
	[[ "$repository_id" =~ ^[1-9][0-9]*$ ]] || {
		printf 'Invalid repository ID: %s\n' "$repository_id" >&2
		return 1
	}
	[[ "$protected_artifact_id" =~ ^[1-9][0-9]*$ ]] || {
		printf 'Invalid protected coordinator artifact ID: %s\n' "$protected_artifact_id" >&2
		return 1
	}

	inventory_file=$(mktemp) || return 1
	candidate_file=$(mktemp) || {
		rm -f "$inventory_file"
		return 1
	}
	if ! gh api --paginate --slurp \
		"repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=100" |
		jq --arg name "$artifact_name" \
			'[.[]?.artifacts[]? | select((.name == $name) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | reverse' \
			>"$inventory_file"; then
		rm -f "$inventory_file" "$candidate_file"
		return 1
	fi
	if ! jq -e --argjson protected "$protected_artifact_id" \
		'any(.[]; .id == $protected)' "$inventory_file" >/dev/null; then
		printf 'Protected coordinator artifact %s is not a live exact-name checkpoint for %s.\n' \
			"$protected_artifact_id" "$repository" >&2
		rm -f "$inventory_file" "$candidate_file"
		return 1
	fi

	fallback_artifact_id=$(jq -r --argjson protected "$protected_artifact_id" \
		'[.[] | select(.id != $protected)] | .[0].id // empty' "$inventory_file") || {
		rm -f "$inventory_file" "$candidate_file"
		return 1
	}
	if [[ -n "$fallback_artifact_id" && ! "$fallback_artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid fallback coordinator artifact ID: %s\n' "$fallback_artifact_id" >&2
		rm -f "$inventory_file" "$candidate_file"
		return 1
	fi
	jq -r --argjson protected "$protected_artifact_id" \
		--arg fallback "$fallback_artifact_id" \
		'.[] | select(.id != $protected and (($fallback == "") or ((.id | tostring) != $fallback))) | [.id, (.size_in_bytes // 0)] | @tsv' \
		"$inventory_file" >"$candidate_file" || {
		rm -f "$inventory_file" "$candidate_file"
		return 1
	}

	total_count=$(jq 'length' "$inventory_file") || return 1
	retained_count=$((total_count > 1 ? 2 : total_count))
	candidate_count=$(wc -l <"$candidate_file" | tr -d ' ')
	candidate_bytes=$(awk -F '\t' '{ total += $2 } END { print total + 0 }' "$candidate_file")
	printf 'Coordinator artifact cleanup %s: repository=%s total=%s retained=%s candidates=%s bytes=%s protected=%s fallback=%s\n' \
		"$mode" "$repository" "$total_count" "$retained_count" "$candidate_count" \
		"$candidate_bytes" "$protected_artifact_id" "${fallback_artifact_id:-none}"

	if [[ "$mode" == "apply" ]]; then
		while IFS=$'\t' read -r artifact_id artifact_size; do
			[[ -n "$artifact_id" ]] || continue
			if [[ ! "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
				printf 'Invalid cleanup candidate artifact ID: %s\n' "$artifact_id" >&2
				cleanup_failed=1
				break
			fi
			if ! gh api --method DELETE "repos/${repository}/actions/artifacts/${artifact_id}"; then
				cleanup_failed=1
				break
			fi
			printf 'Deleted coordinator artifact %s (%s bytes).\n' "$artifact_id" "$artifact_size"
		done <"$candidate_file"
	fi

	rm -f "$inventory_file" "$candidate_file"
	((cleanup_failed == 0)) || return 1
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	restore) restore_state "${2:?state directory required}" "${3:?repository required}" "${4:?repository ID required}" ;;
	cleanup-plan) cleanup_state plan "${2:?repository required}" "${3:?repository ID required}" "${4:?protected artifact ID required}" ;;
	cleanup-apply) cleanup_state apply "${2:?repository required}" "${3:?repository ID required}" "${4:?protected artifact ID required}" ;;
	*)
		printf 'Usage: %s restore STATE_DIR REPOSITORY REPOSITORY_ID | cleanup-plan|cleanup-apply REPOSITORY REPOSITORY_ID PROTECTED_ARTIFACT_ID\n' "$0" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
