#!/usr/bin/env bash
# =============================================================================
# findings-to-tasks-helper.sh
# =============================================================================
# Convert actionable findings into tracked TODO tasks + GitHub issues.
#
# Input format (pipe-delimited, one finding per line):
#   severity|title|details
#
# Severity is optional; if omitted, defaults to medium:
#   title only
#
# Usage:
#   findings-to-tasks-helper.sh create --input findings.txt [options]
#   findings-to-tasks-helper.sh help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC1091
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly DEFAULT_SOURCE="review"
readonly DEFAULT_SEVERITY="medium"
readonly CLAIM_SCRIPT="${SCRIPT_DIR}/claim-task-id.sh"

trim() {
	local input="${1:-}"
	input="${input#"${input%%[![:space:]]*}"}"
	input="${input%"${input##*[![:space:]]}"}"
	printf '%s' "$input"
	return 0
}

is_valid_severity() {
	local severity=""
	severity="$(trim "${1:-}")"
	case "$severity" in
	critical | high | medium | low | info)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

normalize_tag_list() {
	local tags_csv="${1:-}"
	local source="${2:-$DEFAULT_SOURCE}"
	local severity="${3:-$DEFAULT_SEVERITY}"

	local out="#actionable-finding #${source} #${severity}"
	local token=""
	local token_trimmed=""

	if [[ -n "$tags_csv" ]]; then
		while IFS=',' read -r token; do
			token_trimmed="$(trim "$token")"
			if [[ -z "$token_trimmed" ]]; then
				continue
			fi
			if [[ "$token_trimmed" == \#* ]]; then
				out+=" ${token_trimmed}"
			else
				out+=" #${token_trimmed}"
			fi
		done <<<"$tags_csv"
	fi

	printf '%s' "$out"
	return 0
}

normalize_label_list() {
	local labels_csv="${1:-}"
	local source="${2:-$DEFAULT_SOURCE}"
	local severity="${3:-$DEFAULT_SEVERITY}"

	local out="actionable-finding,${source},severity:${severity},source:findings-to-tasks"
	local token=""
	local token_trimmed=""

	if [[ -n "$labels_csv" ]]; then
		while IFS=',' read -r token; do
			token_trimmed="$(trim "$token")"
			if [[ -z "$token_trimmed" ]]; then
				continue
			fi
			out+=",${token_trimmed}"
		done <<<"$labels_csv"
	fi

	printf '%s' "$out"
	return 0
}

show_help() {
	cat <<'EOF'
findings-to-tasks-helper.sh - Create tracked tasks from actionable findings

Usage:
  findings-to-tasks-helper.sh create --input <file> [options]
  findings-to-tasks-helper.sh help

Input format (one finding per line):
  severity|title|details

Examples:
  findings-to-tasks-helper.sh create --input findings.txt --source security-audit
  findings-to-tasks-helper.sh create --input findings.txt --dry-run --no-issue

Options:
  --input PATH          Required. File containing actionable findings.
  --repo-path PATH      Git repo root (default: git root or current directory).
  --source NAME         Source tag/label (default: review).
  --labels CSV          Extra issue labels (comma-separated).
  --tags CSV            Extra TODO hashtags (comma-separated).
  --output PATH         Write generated TODO lines to file.
  --offline             Force offline ID allocation.
  --no-issue            Allocate task IDs only; skip issue creation.
  --dry-run             Preview allocations without changing state.
  --allow-partial       Exit 0 even if some findings fail conversion.
EOF
	return 0
}

resolve_repo_path() {
	local requested_path="${1:-}"
	local repo_path=""

	if [[ -n "$requested_path" ]]; then
		repo_path="$requested_path"
	else
		repo_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
	fi

	if [[ ! -d "$repo_path" ]]; then
		log_error "Repo path does not exist: $repo_path"
		return 1
	fi

	printf '%s' "$repo_path"
	return 0
}

parse_finding_line() {
	local line="${1:-}"
	local parsed_severity=""
	local parsed_title=""
	local parsed_details=""

	local field1=""
	local field2=""
	local field3=""

	IFS='|' read -r field1 field2 field3 <<<"$line"
	field1="$(trim "$field1")"
	field2="$(trim "$field2")"
	field3="$(trim "$field3")"

	if [[ -n "$field2" ]]; then
		parsed_severity="$field1"
		parsed_title="$field2"
		parsed_details="$field3"
	else
		parsed_severity="$DEFAULT_SEVERITY"
		parsed_title="$field1"
		parsed_details=""
	fi

	if ! is_valid_severity "$parsed_severity"; then
		parsed_details="$parsed_title${parsed_details:+ - $parsed_details}"
		parsed_title="$field1${field2:+ | $field2}${field3:+ | $field3}"
		parsed_title="$(trim "$parsed_title")"
		parsed_severity="$DEFAULT_SEVERITY"
	fi

	printf '%s\t%s\t%s' "$parsed_severity" "$parsed_title" "$parsed_details"
	return 0
}

create_task_for_finding() {
	local repo_path="${1:-}"
	local source="${2:-$DEFAULT_SOURCE}"
	local severity="${3:-$DEFAULT_SEVERITY}"
	local title="${4:-}"
	local details="${5:-}"
	local extra_labels="${6:-}"
	local extra_tags="${7:-}"
	local offline_mode="${8:-false}"
	local no_issue_mode="${9:-false}"
	local dry_run_mode="${10:-false}"

	local labels=""
	local tags=""
	labels="$(normalize_label_list "$extra_labels" "$source" "$severity")"
	tags="$(normalize_tag_list "$extra_tags" "$source" "$severity")"

	local cmd=("$CLAIM_SCRIPT" --title "$title" --repo-path "$repo_path" --labels "$labels")
	if [[ -n "$details" ]]; then
		cmd+=(--description "$details")
	fi
	if [[ "$offline_mode" == "true" ]]; then
		cmd+=(--offline)
	fi
	if [[ "$no_issue_mode" == "true" ]]; then
		cmd+=(--no-issue)
	fi
	if [[ "$dry_run_mode" == "true" ]]; then
		cmd+=(--dry-run)
	fi

	local claim_output=""
	local claim_rc=0
	claim_output=$("${cmd[@]}" 2>&1) || claim_rc=$?
	if [[ "$claim_rc" -ne 0 && "$claim_rc" -ne 2 ]]; then
		log_error "Failed to create task for finding: $title"
		log_error "$claim_output"
		return 1
	fi

	local task_id=""
	local issue_ref=""
	task_id=$(printf '%s\n' "$claim_output" | sed -n 's/^task_id=//p' | head -1)
	issue_ref=$(printf '%s\n' "$claim_output" | sed -n 's/^ref=//p' | head -1)

	if [[ -z "$task_id" ]]; then
		log_error "claim-task-id.sh returned no task_id for: $title"
		return 1
	fi

	local today=""
	today="$(date +%Y-%m-%d)"

	local todo_line="- [ ] ${task_id} ${title} ${tags}"
	if [[ -n "$issue_ref" && "$issue_ref" != "offline" ]]; then
		todo_line+=" ref:${issue_ref}"
	fi
	todo_line+=" logged:${today}"

	printf '%s\n' "$todo_line"
	return 0
}

cmd_create() {
	local input_file=""
	local repo_path_arg=""
	local source="$DEFAULT_SOURCE"
	local extra_labels=""
	local extra_tags=""
	local output_file=""
	local offline_mode="false"
	local no_issue_mode="false"
	local dry_run_mode="false"
	local allow_partial="false"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--input)
			input_file="${2:-}"
			shift 2
			;;
		--repo-path)
			repo_path_arg="${2:-}"
			shift 2
			;;
		--source)
			source="${2:-$DEFAULT_SOURCE}"
			shift 2
			;;
		--labels)
			extra_labels="${2:-}"
			shift 2
			;;
		--tags)
			extra_tags="${2:-}"
			shift 2
			;;
		--output)
			output_file="${2:-}"
			shift 2
			;;
		--offline)
			offline_mode="true"
			shift
			;;
		--no-issue)
			no_issue_mode="true"
			shift
			;;
		--dry-run)
			dry_run_mode="true"
			shift
			;;
		--allow-partial)
			allow_partial="true"
			shift
			;;
		help | --help | -h)
			show_help
			return 0
			;;
		*)
			log_error "Unknown argument: $arg"
			show_help
			return 1
			;;
		esac
	done

	if [[ -z "$input_file" ]]; then
		log_error "--input is required"
		show_help
		return 1
	fi

	if [[ ! -f "$input_file" ]]; then
		log_error "Input file not found: $input_file"
		return 1
	fi

	if [[ ! -r "$input_file" ]]; then
		log_error "Input file is not readable: $input_file"
		return 1
	fi

	if [[ ! -x "$CLAIM_SCRIPT" ]]; then
		log_error "claim-task-id.sh is missing or not executable: $CLAIM_SCRIPT"
		return 1
	fi

	local repo_path=""
	repo_path="$(resolve_repo_path "$repo_path_arg")" || return 1

	local actionable_findings_total=0
	local deferred_tasks_created=0
	local skipped_empty=0
	local failed=0

	local line=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		local clean_line=""
		clean_line="$(trim "$line")"

		if [[ -z "$clean_line" ]]; then
			skipped_empty=$((skipped_empty + 1))
			continue
		fi
		if [[ "$clean_line" == \#* ]]; then
			continue
		fi

		actionable_findings_total=$((actionable_findings_total + 1))

		local parsed=""
		local severity=""
		local title=""
		local details=""
		parsed="$(parse_finding_line "$clean_line")"
		severity="$(printf '%s' "$parsed" | cut -f1)"
		title="$(printf '%s' "$parsed" | cut -f2)"
		details="$(printf '%s' "$parsed" | cut -f3)"

		if [[ -z "$title" ]]; then
			log_warn "Skipping actionable finding with empty title: $clean_line"
			failed=$((failed + 1))
			continue
		fi

		local todo_line=""
		if ! todo_line=$(create_task_for_finding \
			"$repo_path" \
			"$source" \
			"$severity" \
			"$title" \
			"$details" \
			"$extra_labels" \
			"$extra_tags" \
			"$offline_mode" \
			"$no_issue_mode" \
			"$dry_run_mode"); then
			failed=$((failed + 1))
			continue
		fi

		deferred_tasks_created=$((deferred_tasks_created + 1))
		printf '%s\n' "$todo_line"
		if [[ -n "$output_file" ]]; then
			printf '%s\n' "$todo_line" >>"$output_file"
		fi
	done <"$input_file"

	local coverage="0"
	if [[ "$actionable_findings_total" -gt 0 ]]; then
		coverage=$((deferred_tasks_created * 100 / actionable_findings_total))
	fi

	printf 'actionable_findings_total=%s\n' "$actionable_findings_total"
	printf 'deferred_tasks_created=%s\n' "$deferred_tasks_created"
	printf 'failed=%s\n' "$failed"
	printf 'skipped_empty=%s\n' "$skipped_empty"
	printf 'coverage=%s%%\n' "$coverage"

	if [[ "$failed" -gt 0 && "$allow_partial" != "true" ]]; then
		log_error "Some actionable findings were not converted. Re-run with --allow-partial only if intentionally deferring conversion."
		return 1
	fi

	if [[ "$actionable_findings_total" -gt 0 && "$coverage" -lt 100 && "$allow_partial" != "true" ]]; then
		log_error "Coverage below 100%. Every actionable finding must map to a tracked task."
		return 1
	fi

	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	create)
		cmd_create "$@"
		return $?
		;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
