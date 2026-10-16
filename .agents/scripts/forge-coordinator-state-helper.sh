#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly RESTORE_DEFERRED_MARKER=".restore-deferred"
readonly RESTORE_EMPTY_INIT_MARKER=".restore-empty-init"
readonly PHASE_EXACT_INVENTORY="exact-name-inventory"
readonly PHASE_LEGACY_INVENTORY="legacy-inventory"
readonly INVENTORY_DIAGNOSTIC_UNKNOWN="unknown"

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

is_invalid_json_failure() {
	local error_file="$1"
	grep -qiE 'unexpected end of JSON input' "$error_file" && return 0
	return 1
}

# Fixed phase/category diagnostics only; never response bodies, URLs or tokens.
report_restore_phase() {
	local phase="$1"
	local category="$2"
	printf '::notice title=Coordinator restore phase::phase=%s category=%s\n' "$phase" "$category" >&2
	return 0
}

# Classify a failed gh call. Returns 0 when deferred (rate limit or invalid
# JSON response), 1 when it is a hard failure the caller must propagate.
handle_gh_restore_failure() {
	local state_dir="$1"
	local repository="$2"
	local error_file="$3"
	local phase="$4"
	if is_github_rate_limited "$error_file"; then
		report_restore_phase "$phase" "rate_limited"
		defer_rate_limited_restore "$state_dir" "$repository" "$error_file" || return 1
		return 0
	fi
	if is_invalid_json_failure "$error_file"; then
		report_restore_phase "$phase" "invalid_json_response"
		defer_restore "$state_dir" "$repository" "GitHub returned an empty or malformed response during ${phase}" || return 1
		return 0
	fi
	report_restore_phase "$phase" "gh_failure"
	print_error_file "$error_file"
	return 1
}

# A successful inventory must be non-empty JSON with an artifacts array.
inventory_is_valid() {
	local inventory="$1"
	[[ -n "$inventory" ]] || return 1
	jq -e '(.artifacts | type) == "array"' >/dev/null 2>&1 <<<"$inventory" || return 1
	return 0
}

defer_invalid_inventory() {
	local state_dir="$1"
	local repository="$2"
	local phase="$3"
	report_restore_phase "$phase" "invalid_inventory_shape"
	defer_restore "$state_dir" "$repository" "GitHub returned an empty or malformed artifact inventory during ${phase}" || return 1
	return 0
}

# Temporary investigation metadata. Remove after the inventory failure is diagnosed;
# never enable HTTP debug logging or publish the captured headers/body.
inventory_cli_version() {
	local output=""
	output=$(gh --version 2>/dev/null) || output=""
	if [[ "$output" =~ ^gh[[:space:]]version[[:space:]]([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})([[:space:]]|$) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	else
		printf '%s' "$INVENTORY_DIAGNOSTIC_UNKNOWN"
	fi
	return 0
}

inventory_header_value() {
	local headers="$1"
	local wanted="$2"
	local line="" key="" value="" examined=0
	while IFS= read -r line; do
		examined=$((examined + 1))
		((examined <= 64)) || break
		line="${line%$'\r'}"
		[[ "$line" == *:* ]] || continue
		key=$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')
		[[ "$key" == "$wanted" ]] || continue
		value="${line#*:}"
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%"${value##*[![:space:]]}"}"
		printf '%s' "$value"
		return 0
	done <<<"$headers"
	return 0
}

report_inventory_http() {
	local phase="$1" headers="$2" body="$3" gh_exit="$4"
	local status="$INVENTORY_DIAGNOSTIC_UNKNOWN" kind="$INVENTORY_DIAGNOSTIC_UNKNOWN" request_id="$INVENTORY_DIAGNOSTIC_UNKNOWN" bytes="" value=""
	local status_line="${headers%%$'\n'*}"
	if [[ "$status_line" =~ ^HTTP/[0-9.]+[[:space:]]+([1-5][0-9][0-9])([[:space:]]|$) ]]; then
		status="${BASH_REMATCH[1]}"
	fi
	value=$(inventory_header_value "$headers" content-type | tr '[:upper:]' '[:lower:]')
	case "$value" in
	application/json | application/json\;* | application/vnd.github+json | application/vnd.github+json\;*) kind="json" ;;
	text/html | text/html\;*) kind="html" ;;
	text/plain | text/plain\;*) kind="text" ;;
	esac
	value=$(inventory_header_value "$headers" x-github-request-id)
	if [[ "$value" =~ ^[[:xdigit:]]{1,16}(:[[:xdigit:]]{1,16}){1,7}$ ]]; then
		request_id="$value"
	fi
	# Captured text only: this is not Content-Length or the wire payload size.
	bytes=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
	printf '::notice title=Coordinator inventory HTTP diagnostics::phase=%s gh_version=%s gh_exit=%s http_status=%s content_type=%s request_id=%s captured_body_bytes=%s\n' \
		"$phase" "$(inventory_cli_version)" "$gh_exit" "$status" "$kind" "$request_id" "$bytes" >&2
	return 0
}

read_restore_inventory() {
	local phase="$1" endpoint="$2" error_file="$3"
	local response="" headers="" gh_exit=0 blocks=0
	# --include exposes response metadata on this SAME read, never an extra probe.
	# A sentinel preserves the header separator and body size for empty responses.
	response=$(
		gh api --include "$endpoint" 2>"$error_file" || gh_exit=$?
		printf '\036'
		exit "$gh_exit"
	) || gh_exit=$?
	response="${response%$'\036'}"
	while [[ "$response" == HTTP/* ]] && ((blocks < 4)); do
		if [[ "$response" == *$'\r\n\r\n'* ]]; then
			headers="${response%%$'\r\n\r\n'*}"
			response="${response#*$'\r\n\r\n'}"
		elif [[ "$response" == *$'\n\n'* ]]; then
			headers="${response%%$'\n\n'*}"
			response="${response#*$'\n\n'}"
		else
			break
		fi
		blocks=$((blocks + 1))
	done
	report_inventory_http "$phase" "$headers" "$response" "$gh_exit"
	# Only the original caller consumes this body via command substitution.
	printf '%s' "$response"
	((gh_exit == 0)) || return 1
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
	if ! artifact_json=$(read_restore_inventory "$PHASE_EXACT_INVENTORY" "repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=1" "$error_file"); then
		if handle_gh_restore_failure "$state_dir" "$repository" "$error_file" "$PHASE_EXACT_INVENTORY"; then
			rm -f "$error_file"
			return 0
		fi
		rm -f "$error_file"
		return 1
	fi
	if ! inventory_is_valid "$artifact_json"; then
		defer_invalid_inventory "$state_dir" "$repository" "$PHASE_EXACT_INVENTORY"
		rm -f "$error_file"
		return 0
	fi
	artifact_id=$(jq -r --arg name "$artifact_name" '[.artifacts[]? | select((.name == $name) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
		report_restore_phase "$PHASE_EXACT_INVENTORY" "metadata_validation_failed"
		rm -f "$error_file"
		return 1
	}

	# One bounded legacy page migrates checkpoints written with run-ID suffixes.
	if [[ -z "$artifact_id" ]]; then
		if ! artifact_json=$(read_restore_inventory "$PHASE_LEGACY_INVENTORY" "repos/${repository}/actions/artifacts?per_page=100" "$error_file"); then
			if handle_gh_restore_failure "$state_dir" "$repository" "$error_file" "$PHASE_LEGACY_INVENTORY"; then
				rm -f "$error_file"
				return 0
			fi
			rm -f "$error_file"
			return 1
		fi
		if ! inventory_is_valid "$artifact_json"; then
			defer_invalid_inventory "$state_dir" "$repository" "$PHASE_LEGACY_INVENTORY"
			rm -f "$error_file"
			return 0
		fi
		artifact_id=$(jq -r --arg prefix "${artifact_name}-" '[.artifacts[]? | select((.name | startswith($prefix)) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
			report_restore_phase "$PHASE_LEGACY_INVENTORY" "metadata_validation_failed"
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
		report_restore_phase "metadata-validation" "invalid_artifact_id"
		printf 'Invalid coordinator artifact ID returned for repository %s: %q\n' "$repository" "$artifact_id" >&2
		rm -f "$error_file"
		return 1
	fi
	archive="${state_dir}/state.zip"
	if ! gh api "repos/${repository}/actions/artifacts/${artifact_id}/zip" >"$archive" 2>"$error_file"; then
		rm -f "$archive"
		if handle_gh_restore_failure "$state_dir" "$repository" "$error_file" "zip-download"; then
			rm -f "$error_file"
			return 0
		fi
		rm -f "$error_file"
		return 1
	fi
	if ! unzip -oq "$archive" -d "$state_dir"; then
		report_restore_phase "extraction" "unzip_failed"
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
