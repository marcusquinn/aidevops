#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Producer-owned write and retention policy for worker failure excerpts.

[[ -n "${_WORKER_FAILURE_EVIDENCE_LOADED:-}" ]] && return 0
_WORKER_FAILURE_EVIDENCE_LOADED=1

if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
	_worker_failure_evidence_dir="${BASH_SOURCE[0]%/*}"
	# shellcheck source=./portable-stat.sh
	source "${_worker_failure_evidence_dir}/portable-stat.sh"
	unset _worker_failure_evidence_dir
fi

WORKER_EXCERPT_KEEP_COUNT="${AIDEVOPS_WORKER_EXCERPT_KEEP_COUNT:-3}"
WORKER_EXCERPT_MAX_AGE_DAYS="${AIDEVOPS_WORKER_EXCERPT_MAX_AGE_DAYS:-30}"
WORKER_EXCERPT_MAX_BYTES="${AIDEVOPS_WORKER_EXCERPT_MAX_BYTES:-196608}"
readonly WORKER_EXCERPT_RETENTION_CONFIRMATION="DELETE-STALE-WORKER-EXCERPTS"

_worker_excerpt_policy_value() {
	local value="$1"
	local fallback="$2"
	case "$value" in
	'' | *[!0-9]*) printf '%s' "$fallback" ;;
	*) printf '%s' "$value" ;;
	esac
	return 0
}

_worker_excerpt_size_bytes() {
	local excerpt_path="$1"
	local excerpt_kib=""
	local ignored=""
	IFS=$'\t ' read -r excerpt_kib ignored < <(du -sk "$excerpt_path" 2>/dev/null) || return 1
	case "$excerpt_kib" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$((excerpt_kib * 1024))"
	return 0
}

# Print a tab-delimited dry-run plan for older duplicate evidence from one
# session. The newest excerpt is an unresolved-recovery hard veto at any size.
_worker_excerpt_retention_plan() {
	local excerpt_dir="$1"
	local safe_key="$2"
	local keep_count=""
	local max_age_days=""
	local max_bytes=""
	local age_cutoff=""
	local excerpt_path=""
	local excerpt_size=""
	local excerpt_mtime=""
	local excerpt_name=""
	local excerpt_suffix=""
	local excerpt_count=0
	local total_bytes=0
	local remaining_count=0
	local remaining_bytes=0
	local newest_excerpt=""
	local reason=""
	local index=0
	local -a excerpts=()
	local -a sizes=()
	local -a mtimes=()

	[[ -d "$excerpt_dir" && ! -L "$excerpt_dir" ]] || return 0
	[[ "$safe_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
	keep_count=$(_worker_excerpt_policy_value "$WORKER_EXCERPT_KEEP_COUNT" 3)
	max_age_days=$(_worker_excerpt_policy_value "$WORKER_EXCERPT_MAX_AGE_DAYS" 30)
	max_bytes=$(_worker_excerpt_policy_value "$WORKER_EXCERPT_MAX_BYTES" 196608)
	age_cutoff=$(($(date +%s) - (max_age_days * 86400)))

	while IFS= read -r excerpt_path; do
		[[ -n "$excerpt_path" ]] || continue
		if [[ "$excerpt_path" == "$excerpt_dir/${safe_key}-*.log" && ! -e "$excerpt_path" ]]; then
			continue
		fi
		[[ -f "$excerpt_path" && ! -L "$excerpt_path" ]] || return 2
		excerpt_name="${excerpt_path##*/}"
		excerpt_suffix="${excerpt_name#"${safe_key}-"}"
		[[ "$excerpt_suffix" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+\.log$ ]] || return 2
		excerpt_size=$(_worker_excerpt_size_bytes "$excerpt_path") || return 2
		excerpt_mtime=$(_file_mtime_epoch "$excerpt_path" 2>/dev/null) || return 2
		case "$excerpt_mtime" in
		'' | *[!0-9]* | 0) return 2 ;;
		esac
		excerpts+=("$excerpt_path")
		sizes+=("$excerpt_size")
		mtimes+=("$excerpt_mtime")
		total_bytes=$((total_bytes + excerpt_size))
	done < <(printf '%s\n' "$excerpt_dir/${safe_key}-"*.log 2>/dev/null | LC_ALL=C sort)

	excerpt_count=${#excerpts[@]}
	[[ "$excerpt_count" -gt 1 ]] || return 0
	remaining_count="$excerpt_count"
	remaining_bytes="$total_bytes"
	newest_excerpt="${excerpts[$((excerpt_count - 1))]}"
	while [[ "$index" -lt "$excerpt_count" ]]; do
		excerpt_path="${excerpts[$index]}"
		excerpt_size="${sizes[$index]}"
		excerpt_mtime="${mtimes[$index]}"
		reason=""
		if [[ "$excerpt_path" != "$newest_excerpt" ]]; then
			[[ "$remaining_count" -gt "$keep_count" ]] && reason="count"
			if [[ "$remaining_bytes" -gt "$max_bytes" ]]; then
				reason="${reason:+${reason},}bytes"
			fi
			if [[ "$excerpt_mtime" -lt "$age_cutoff" ]]; then
				reason="${reason:+${reason},}age"
			fi
		fi
		if [[ -n "$reason" ]]; then
			printf '%s\t%s\t%s\n' "$excerpt_path" "$excerpt_size" "$reason"
			remaining_count=$((remaining_count - 1))
			remaining_bytes=$((remaining_bytes - excerpt_size))
		fi
		index=$((index + 1))
	done
	return 0
}

_worker_excerpt_retention_apply() {
	local excerpt_dir="$1"
	local safe_key="$2"
	local plan_file="$3"
	local confirmation="$4"
	local candidate_path=""
	local candidate_bytes=""
	local candidate_reason=""
	local candidate_name=""
	local trash_dir="${excerpt_dir}/.retention-trash"
	local staged_path=""
	local current_plan=""
	local current_size=""
	local index=0
	local -a staged_paths=()

	[[ "$confirmation" == "$WORKER_EXCERPT_RETENTION_CONFIRMATION" ]] || return 1
	[[ -d "$excerpt_dir" && ! -L "$excerpt_dir" && -f "$plan_file" ]] || return 1
	[[ "$safe_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	current_plan=$(_worker_excerpt_retention_plan "$excerpt_dir" "$safe_key") || return 1
	current_plan=$'\n'"${current_plan}"$'\n'
	mkdir -p "$trash_dir" || return 1
	while IFS=$'\t' read -r candidate_path candidate_bytes candidate_reason; do
		[[ -n "$candidate_path" ]] || continue
		candidate_name="${candidate_path##*/}"
		[[ "${candidate_path%/*}" == "$excerpt_dir" ]] || return 1
		[[ "$candidate_name" == "${safe_key}-"*.log ]] || return 1
		[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || return 1
		case "$candidate_bytes" in
		'' | *[!0-9]*) return 1 ;;
		esac
		[[ -n "$candidate_reason" ]] || return 1
		[[ "$current_plan" == *$'\n'"${candidate_path}"$'\t'"${candidate_bytes}"$'\t'"${candidate_reason}"$'\n'* ]] || return 1
		current_size=$(_worker_excerpt_size_bytes "$candidate_path") || return 1
		[[ "$current_size" == "$candidate_bytes" ]] || return 1
		staged_path="${trash_dir}/${candidate_name}-$$-${index}"
		mv "$candidate_path" "$staged_path" || return 1
		staged_paths+=("$staged_path")
		index=$((index + 1))
	done <"$plan_file"
	if [[ "${AIDEVOPS_RETENTION_TEST_INTERRUPT_AFTER_STAGE:-0}" == "1" ]]; then
		return 1
	fi
	for staged_path in "${staged_paths[@]}"; do
		rm -f "$staged_path" || return 1
	done
	rmdir "$trash_dir" 2>/dev/null || true
	return 0
}

# Preserve a capped output excerpt, then converge older duplicate evidence for
# the same session. Observability and retention failures remain non-fatal.
_metric_failure_excerpt_candidate_path() {
	local output_file="$1"
	local session_key="$2"
	local retention_tmp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local safe_key=""
	local candidate_path=""
	[[ -n "$output_file" && -f "$output_file" ]] || return 0
	safe_key=$(printf '%s' "$session_key" | tr -c 'A-Za-z0-9._-' '_')
	mkdir -p "$retention_tmp_dir" 2>/dev/null || return 0
	candidate_path=$(mktemp "${retention_tmp_dir}/worker-failure-${safe_key:-unknown}.XXXXXX" 2>/dev/null || true)
	[[ -n "$candidate_path" ]] || return 0
	if ! python3 - "$output_file" "$candidate_path" <<'PY' >/dev/null 2>&1
import sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src, "rb") as f:
        data = f.read()[-65536:]
    with open(dst, "wb") as f:
        f.write(data)
except OSError:
    sys.exit(1)
PY
	then
		rm -f "$candidate_path"
		return 0
	fi
	if [[ -s "$candidate_path" ]]; then
		printf '%s' "$candidate_path"
	else
		rm -f "$candidate_path"
	fi
	return 0
}

_metric_failure_excerpt_path() {
	local output_file="$1"
	local session_key="$2"
	local excerpt_dir="${HOME}/.aidevops/logs/worker-failure-excerpts"
	local safe_key=""
	local timestamp=""
	local excerpt_path=""
	local retention_tmp_dir=""
	local plan_file=""

	# Protected workloads must never persist transcript-derived diagnostics,
	# including otherwise bounded failure excerpts.
	if declare -F _headless_private_workload_enabled >/dev/null 2>&1 && \
		_headless_private_workload_enabled; then
		return 0
	fi
	[[ -n "$output_file" && -f "$output_file" ]] || return 0
	mkdir -p "$excerpt_dir" 2>/dev/null || return 0
	safe_key=$(printf '%s' "$session_key" | tr -c 'A-Za-z0-9._-' '_')
	timestamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "unknown")
	excerpt_path="${excerpt_dir}/${safe_key:-unknown}-${timestamp}-$$.log"
	python3 - "$output_file" "$excerpt_path" <<'PY' >/dev/null 2>&1 || return 0
import sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src, "rb") as f:
        data = f.read()[-65536:]
    with open(dst, "wb") as f:
        f.write(data)
except OSError:
    sys.exit(0)
PY
	if [[ -s "$excerpt_path" ]]; then
		retention_tmp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
		if mkdir -p "$retention_tmp_dir" 2>/dev/null; then
			plan_file=$(mktemp "${retention_tmp_dir}/worker-excerpt-retention.XXXXXX" 2>/dev/null || true)
			if [[ -n "$plan_file" ]]; then
				if _worker_excerpt_retention_plan "$excerpt_dir" "${safe_key:-unknown}" >"$plan_file"; then
					_worker_excerpt_retention_apply "$excerpt_dir" "${safe_key:-unknown}" "$plan_file" "$WORKER_EXCERPT_RETENTION_CONFIRMATION" 2>/dev/null || true
				fi
				rm -f "$plan_file"
			fi
		fi
		printf '%s' "$excerpt_path"
	fi
	return 0
}

# Gate excerpt creation on the final reconciled attempt result so successful
# continuations cannot displace the failure evidence they recovered from.
_metric_failure_excerpt_for_result() {
	local result_label="$1"
	local output_file="$2"
	local session_key="$3"
	case "$result_label" in
	success | post_pr_handoff) return 0 ;;
	esac
	_metric_failure_excerpt_path "$output_file" "$session_key"
	return 0
}
