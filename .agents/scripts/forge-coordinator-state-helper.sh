#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly RESTORE_DEFERRED_MARKER=".restore-deferred"
readonly RESTORE_EMPTY_INIT_MARKER=".restore-empty-init"
readonly RESTORE_CREATED_AT_MARKER=".restore-created-at"
readonly CLEANUP_PAGE_SIZE=100
readonly CLEANUP_MODE_APPLY="apply"
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

# Remember when the restored checkpoint was created so a scheduled keepalive run
# can decide whether it is close to the organisation retention limit.
record_restore_created_at() {
	local state_dir="$1" artifact_json="$2" artifact_id="$3"
	local created_at=""
	created_at=$(jq -r --argjson id "$artifact_id" \
		'[.artifacts[]? | select(.id == $id)] | .[0].created_at // empty' <<<"$artifact_json" 2>/dev/null) || return 0
	[[ "$created_at" =~ ^[0-9T:Z.+-]+$ ]] || return 0
	printf '%s\n' "$created_at" >"${state_dir}/${RESTORE_CREATED_AT_MARKER}" || return 0
	return 0
}

# Prints due=true when the restored checkpoint is at least MAX_AGE_DAYS old.
# No restored checkpoint (empty init, deferred restore) is never due.
keepalive_due() {
	local state_dir="$1" max_age_days="$2"
	local created_at="" age_days=""
	[[ "$max_age_days" =~ ^[1-9][0-9]*$ ]] || {
		printf 'Invalid keepalive age in days: %s\n' "$max_age_days" >&2
		return 1
	}
	if [[ -f "${state_dir}/${RESTORE_DEFERRED_MARKER}" || ! -f "${state_dir}/${RESTORE_CREATED_AT_MARKER}" ]]; then
		printf 'due=false\n'
		return 0
	fi
	created_at=$(<"${state_dir}/${RESTORE_CREATED_AT_MARKER}")
	age_days=$(jq -n --arg t "$created_at" '((now - ($t | fromdateiso8601)) / 86400) | floor' 2>/dev/null) || age_days=""
	if [[ ! "$age_days" =~ ^-?[0-9]+$ ]]; then
		printf 'due=false\n'
		return 0
	fi
	printf 'age_days=%s\n' "$age_days"
	if ((age_days >= max_age_days)); then
		printf 'due=true\n'
	else
		printf 'due=false\n'
	fi
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
	rm -f "${state_dir}/${RESTORE_DEFERRED_MARKER}" "${state_dir}/${RESTORE_EMPTY_INIT_MARKER}" "${state_dir}/${RESTORE_CREATED_AT_MARKER}"
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
	record_restore_created_at "$state_dir" "$artifact_json" "$artifact_id"
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

# Fetch one exact-name inventory page (newest first), retrying transient
# truncated or malformed responses before giving up on the page.
fetch_cleanup_page() {
	local repository="$1" artifact_name="$2" page="$3" out_file="$4"
	local attempt=1 raw=""
	while ((attempt <= 3)); do
		if raw=$(gh api "repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=${CLEANUP_PAGE_SIZE}&page=${page}") &&
			jq -e '(.artifacts | type) == "array"' <<<"$raw" >/dev/null 2>&1; then
			printf '%s' "$raw" >"$out_file" || return 1
			return 0
		fi
		attempt=$((attempt + 1))
		((attempt > 3)) || sleep "${AIDEVOPS_COORDINATOR_CLEANUP_RETRY_DELAY:-1}"
	done
	return 1
}

# Handle one cleanup candidate. Updates the caller's counters (dynamic scope)
# and sets cleanup_stop when the run must end. Isolated failures never stop it.
cleanup_one_artifact() {
	local mode="$1" repository="$2" artifact_id="$3" artifact_size="$4"
	local delete_error=""
	if [[ ! "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid cleanup candidate artifact ID: %s\n' "$artifact_id" >&2
		cleanup_failed=$((cleanup_failed + 1))
		return 0
	fi
	[[ "$artifact_size" =~ ^[0-9]+$ ]] || artifact_size=0
	if [[ "$mode" != "$CLEANUP_MODE_APPLY" ]]; then
		candidate_count=$((candidate_count + 1))
		candidate_bytes=$((candidate_bytes + artifact_size))
		return 0
	fi

	if ((deleted_count >= cleanup_max_deletes)); then
		cleanup_stop="delete_cap"
		return 0
	fi
	if (($(date +%s) - cleanup_started >= cleanup_max_seconds)); then
		cleanup_stop="time_budget"
		return 0
	fi
	candidate_count=$((candidate_count + 1))
	candidate_bytes=$((candidate_bytes + artifact_size))
	if delete_error=$(gh api --method DELETE "repos/${repository}/actions/artifacts/${artifact_id}" 2>&1); then
		deleted_count=$((deleted_count + 1))
		consecutive_failures=0
		printf 'Deleted coordinator artifact %s (%s bytes).\n' "$artifact_id" "$artifact_size"
		# Stay below the secondary rate limit (5 points per DELETE, 900 per minute).
		sleep "${AIDEVOPS_COORDINATOR_CLEANUP_DELETE_DELAY:-0.4}"
	elif grep -qiE 'HTTP 404|Not Found' <<<"$delete_error"; then
		skipped_count=$((skipped_count + 1))
	elif grep -qiE 'rate limit|submitted too quickly|abuse detection' <<<"$delete_error"; then
		printf '::warning title=Coordinator cleanup rate limited::Stopping this run; the next run continues from the oldest remaining checkpoint.\n' >&2
		cleanup_stop="rate_limited"
	else
		cleanup_failed=$((cleanup_failed + 1))
		consecutive_failures=$((consecutive_failures + 1))
		printf '::warning title=Coordinator cleanup delete failed::artifact=%s; continuing with the next candidate.\n' "$artifact_id" >&2
		((consecutive_failures < 5)) || cleanup_stop="consecutive_failures"
	fi
	return 0
}

# Process one inventory page, oldest candidate first.
cleanup_one_page() {
	local mode="$1" repository="$2" artifact_name="$3" page_file="$4" protected_id="$5" fallback_id="$6"
	local artifact_id="" artifact_size="" candidates=""
	candidates=$(jq -r --arg name "$artifact_name" --argjson protected "$protected_id" --arg fallback "$fallback_id" \
		'[.artifacts[] | select((.name == $name) and ((.expired // false) == false) and .id != $protected and (($fallback == "") or ((.id | tostring) != $fallback)))]
		| sort_by([.created_at, .id]) | .[] | [.id, (.size_in_bytes // 0)] | @tsv' "$page_file") || return 1
	while IFS=$'\t' read -r artifact_id artifact_size; do
		[[ -n "$artifact_id" ]] || continue
		cleanup_one_artifact "$mode" "$repository" "$artifact_id" "$artifact_size"
		[[ -z "$cleanup_stop" ]] || break
	done <<<"$candidates"
	return 0
}

validate_cleanup_args() {
	local mode="$1" repository="$2" repository_id="$3" protected_id="$4" max_deletes="$5" max_seconds="$6"
	[[ "$mode" == "plan" || "$mode" == "$CLEANUP_MODE_APPLY" ]] || {
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
	[[ "$protected_id" =~ ^[1-9][0-9]*$ ]] || {
		printf 'Invalid protected coordinator artifact ID: %s\n' "$protected_id" >&2
		return 1
	}
	[[ "$max_deletes" =~ ^[1-9][0-9]*$ && "$max_seconds" =~ ^[1-9][0-9]*$ ]] || {
		printf 'Invalid cleanup deletion or time cap.\n' >&2
		return 1
	}
	return 0
}

# Bounded cleanup: page oldest-first and delete while paging, cap deletions and
# time per run, pace DELETEs and continue past isolated failures, so a large
# backlog shrinks on every run instead of needing one full inventory first.
cleanup_state() {
	local mode="$1"
	local repository="$2"
	local repository_id="$3"
	local protected_artifact_id="$4"
	local artifact_name="forge-coordinator-${repository_id}"
	local page_file="" first_page_file="" fallback_artifact_id=""
	local total_count="" retained_count="" last_page="" page=""
	local candidate_count=0 candidate_bytes=0 deleted_count=0 skipped_count=0
	local cleanup_failed=0 consecutive_failures=0 pages_failed=0 cleanup_stop=""
	local cleanup_max_deletes="${AIDEVOPS_COORDINATOR_CLEANUP_MAX_DELETES:-400}"
	local cleanup_max_seconds="${AIDEVOPS_COORDINATOR_CLEANUP_MAX_SECONDS:-420}"
	local cleanup_started=""
	cleanup_started=$(date +%s)

	validate_cleanup_args "$mode" "$repository" "$repository_id" "$protected_artifact_id" "$cleanup_max_deletes" "$cleanup_max_seconds" || return 1

	first_page_file=$(mktemp) || return 1
	page_file=$(mktemp) || {
		rm -f "$first_page_file"
		return 1
	}
	# Page 1 holds the newest checkpoints: the protected upload and its fallback.
	if ! fetch_cleanup_page "$repository" "$artifact_name" 1 "$first_page_file"; then
		printf 'Coordinator inventory page 1 could not be read for %s.\n' "$repository" >&2
		rm -f "$first_page_file" "$page_file"
		return 1
	fi
	if ! jq -e --argjson protected "$protected_artifact_id" --arg name "$artifact_name" \
		'any(.artifacts[]; .id == $protected and .name == $name and ((.expired // false) == false))' "$first_page_file" >/dev/null; then
		printf 'Protected coordinator artifact %s is not a live exact-name checkpoint for %s.\n' \
			"$protected_artifact_id" "$repository" >&2
		rm -f "$first_page_file" "$page_file"
		return 1
	fi
	fallback_artifact_id=$(jq -r --argjson protected "$protected_artifact_id" --arg name "$artifact_name" \
		'[.artifacts[] | select(.name == $name and ((.expired // false) == false) and .id != $protected)] | sort_by([.created_at, .id]) | reverse | .[0].id // empty' "$first_page_file") || {
		rm -f "$first_page_file" "$page_file"
		return 1
	}
	if [[ -n "$fallback_artifact_id" && ! "$fallback_artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid fallback coordinator artifact ID: %s\n' "$fallback_artifact_id" >&2
		rm -f "$first_page_file" "$page_file"
		return 1
	fi
	total_count=$(jq -r '.total_count // (.artifacts | length)' "$first_page_file") || total_count=0
	[[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0
	retained_count=$((total_count > 1 ? 2 : total_count))
	last_page=$(((total_count + CLEANUP_PAGE_SIZE - 1) / CLEANUP_PAGE_SIZE))
	((last_page >= 1)) || last_page=1

	# Deleting from the oldest end never shifts the newer pages still to be read.
	page=$last_page
	while ((page >= 1)); do
		if ((page == 1)); then
			cp "$first_page_file" "$page_file" || break
		elif ! fetch_cleanup_page "$repository" "$artifact_name" "$page" "$page_file"; then
			pages_failed=$((pages_failed + 1))
			printf '::warning title=Coordinator inventory page skipped::page=%s could not be read; continuing.\n' "$page" >&2
			page=$((page - 1))
			continue
		fi
		cleanup_one_page "$mode" "$repository" "$artifact_name" "$page_file" "$protected_artifact_id" "$fallback_artifact_id" || pages_failed=$((pages_failed + 1))
		[[ -z "$cleanup_stop" ]] || break
		if (($(date +%s) - cleanup_started >= cleanup_max_seconds)); then
			cleanup_stop="time_budget"
			break
		fi
		page=$((page - 1))
	done

	printf 'Coordinator artifact cleanup %s: repository=%s total=%s retained=%s candidates=%s bytes=%s protected=%s fallback=%s deleted=%s skipped=%s failed=%s pages_failed=%s stop=%s\n' \
		"$mode" "$repository" "$total_count" "$retained_count" "$candidate_count" \
		"$candidate_bytes" "$protected_artifact_id" "${fallback_artifact_id:-none}" \
		"$deleted_count" "$skipped_count" "$cleanup_failed" "$pages_failed" "${cleanup_stop:-complete}"

	rm -f "$first_page_file" "$page_file"
	# An isolated failure is a warning; an apply run that made no progress fails.
	if [[ "$mode" == "$CLEANUP_MODE_APPLY" ]] && ((cleanup_failed + pages_failed > 0 && deleted_count == 0)); then
		return 1
	fi
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	restore) restore_state "${2:?state directory required}" "${3:?repository required}" "${4:?repository ID required}" ;;
	keepalive-due) keepalive_due "${2:?state directory required}" "${3:?maximum age in days required}" ;;
	cleanup-plan) cleanup_state plan "${2:?repository required}" "${3:?repository ID required}" "${4:?protected artifact ID required}" ;;
	cleanup-apply) cleanup_state apply "${2:?repository required}" "${3:?repository ID required}" "${4:?protected artifact ID required}" ;;
	*)
		printf 'Usage: %s restore STATE_DIR REPOSITORY REPOSITORY_ID | keepalive-due STATE_DIR MAX_AGE_DAYS | cleanup-plan|cleanup-apply REPOSITORY REPOSITORY_ID PROTECTED_ARTIFACT_ID\n' "$0" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
