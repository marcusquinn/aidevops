#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-failure-feedback-helper.sh - Mine worker runtime failures into feedback tasks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

DEFAULT_SINCE_HOURS=24
DEFAULT_THRESHOLD=3
DEFAULT_LIMIT=5
DEFAULT_METRICS_FILE="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"

print_usage() {
	cat <<'EOF'
worker-failure-feedback-helper.sh - Mine non-success worker metrics into feedback tasks

Usage:
  worker-failure-feedback-helper.sh report [--since-hours N] [--threshold N] [--metrics-file PATH]
  worker-failure-feedback-helper.sh create-issues [--since-hours N] [--threshold N] [--limit N] [--dry-run]

The miner groups recent non-success headless-runtime-metrics.jsonl rows by
result, failure_reason, session_key, issue_number, and repo_slug. Repeated
classes become worker-ready issue bodies with evidence and verification steps.
EOF
	return 0
}

die() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 1
}

require_positive_integer() {
	local option_name="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then
		die "${option_name} must be a positive integer"
		return 1
	fi
	return 0
}

parse_common_args() {
	SINCE_HOURS="$DEFAULT_SINCE_HOURS"
	THRESHOLD="$DEFAULT_THRESHOLD"
	LIMIT="$DEFAULT_LIMIT"
	METRICS_FILE="$DEFAULT_METRICS_FILE"
	DRY_RUN=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--since-hours) SINCE_HOURS="${2:-}"; require_positive_integer "$arg" "$SINCE_HOURS" || return 2; shift 2 ;;
		--threshold) THRESHOLD="${2:-}"; require_positive_integer "$arg" "$THRESHOLD" || return 2; shift 2 ;;
		--limit) LIMIT="${2:-}"; require_positive_integer "$arg" "$LIMIT" || return 2; shift 2 ;;
		--metrics-file) METRICS_FILE="${2:-}"; [[ -n "$METRICS_FILE" ]] || return 2; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) print_usage; return 64 ;;
		*) die "unknown flag: $arg"; return 2 ;;
		esac
	done
	return 0
}

mine_failure_groups_json() {
	local since_hours="$1"
	local threshold="$2"
	local metrics_file="$3"
	if [[ ! -f "$metrics_file" ]]; then
		printf '[]\n'
		return 0
	fi
	local cutoff_epoch
	cutoff_epoch=$(( $(date +%s) - (since_hours * 3600) ))
	jq -s --argjson cutoff "$cutoff_epoch" --argjson threshold "$threshold" '
    map(select((.ts // 0) >= $cutoff))
    | map(select((.result // "") != "success" or (.exit_code // 1) != 0))
    | group_by([.result // "unknown", .failure_reason // "", .session_key // "", (.issue_number // "" | tostring), .repo_slug // ""])
    | map({
        result: (.[0].result // "unknown"),
        failure_reason: (.[0].failure_reason // ""),
        session_key: (.[0].session_key // ""),
        issue_number: (.[0].issue_number // null),
        repo_slug: (.[0].repo_slug // ""),
        count: length,
        first_ts: (map(.ts // 0) | min),
        last_ts: (map(.ts // 0) | max),
        examples: (sort_by(.ts // 0) | reverse | .[0:5] | map({ts, model, provider, exit_code, duration_ms, session_id, work_dir, output_file}))
      })
    | map(select(.count >= $threshold))
    | sort_by(.count) | reverse
  ' "$metrics_file" 2>/dev/null || printf '[]\n'
	return 0
}

cmd_report() {
	parse_common_args "$@"
	local parse_rc=$?
	[[ "$parse_rc" -eq 64 ]] && return 0
	[[ "$parse_rc" -eq 0 ]] || return "$parse_rc"
	mine_failure_groups_json "$SINCE_HOURS" "$THRESHOLD" "$METRICS_FILE"
	return 0
}

issue_body_for_group() {
	local group_json="$1"
	jq -r '
    "## Task\nFix repeated headless worker failure class: " + (.result // "unknown") + " / " + (.failure_reason // "unspecified") + "\n\n" +
    "## Why\nThe worker failure feedback miner observed " + (.count|tostring) + " matching non-success runtime metric rows. Repeated failures consume tokens/CPU without producing merged work; this task should turn the evidence into a durable fix.\n\n" +
    "## Files to modify\n- EDIT: .agents/scripts/headless-runtime-helper.sh — inspect worker lifecycle handling for this failure class.\n- EDIT: .agents/scripts/headless-runtime-lib.sh — adjust metric classification if the row is misclassified.\n- EDIT: .agents/scripts/worker-activity-helper.sh — keep failure detail visible if presentation needs improvement.\n\n" +
    "## Evidence\n- result: " + (.result // "unknown") + "\n" +
    "- failure_reason: " + (.failure_reason // "") + "\n" +
    "- session_key: " + (.session_key // "") + "\n" +
    "- issue_number: " + ((.issue_number // "")|tostring) + "\n" +
    "- repo_slug: " + (.repo_slug // "") + "\n" +
    "- count: " + (.count|tostring) + "\n" +
    "- examples: `" + ((.examples // []) | tostring) + "`\n\n" +
    "## Acceptance criteria\n- The cited failure class is either fixed or explicitly reclassified with evidence.\n- A regression test or fixture covers the observed row shape.\n- New non-success rows retain issue/repo/session/log evidence for future mining.\n\n" +
    "## Verification\n- shellcheck .agents/scripts/headless-runtime-helper.sh .agents/scripts/headless-runtime-lib.sh .agents/scripts/worker-activity-helper.sh\n- .agents/scripts/worker-failure-feedback-helper.sh report --since-hours 24 --threshold 1\n"
  ' <<<"$group_json"
	return 0
}

cmd_create_issues() {
	parse_common_args "$@"
	local parse_rc=$?
	[[ "$parse_rc" -eq 64 ]] && return 0
	[[ "$parse_rc" -eq 0 ]] || return "$parse_rc"
	local groups_json
	groups_json=$(mine_failure_groups_json "$SINCE_HOURS" "$THRESHOLD" "$METRICS_FILE")
	local created=0
	while IFS= read -r group; do
		[[ -n "$group" ]] || continue
		[[ "$created" -lt "$LIMIT" ]] || break
		local title body
		title=$(jq -r '"Fix repeated worker failure: " + (.result // "unknown") + " / " + (.failure_reason // "unspecified")' <<<"$group")
		body=$(issue_body_for_group "$group")
		if [[ "$DRY_RUN" -eq 1 ]]; then
			printf 'DRY_RUN title=%s\n%s\n' "$title" "$body"
		else
			claim-task-id.sh --title "$title" --description "$body" --labels "auto-dispatch,tier:standard,bug,worker-failure-feedback"
		fi
		created=$((created + 1))
	done < <(jq -c '.[]' <<<"$groups_json")
	printf 'created=%d\n' "$created"
	return 0
}

main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	report) cmd_report "$@" ;;
	create-issues) cmd_create_issues "$@" ;;
	help | -h | --help) print_usage ;;
	*) die "unknown command: $cmd"; print_usage >&2; return 2 ;;
	esac
}

main "$@"
