#!/usr/bin/env bash
# list-verify-helper.sh - List verification queue entries with filtering
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   list-verify-helper.sh [options]
#
# Filtering options:
#   --pending          Show only pending verifications [ ]
#   --passed           Show only passed verifications [x]
#   --failed           Show only failed verifications [!]
#   --task, -t ID      Filter by task ID (e.g., t168)
#
# Display options:
#   --compact          One-line per entry (no details)
#   --json             Output as JSON
#   --no-color         Disable colors
#   --help, -h         Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Defaults
FILTER_STATUS=""
FILTER_TASK=""
COMPACT=false
OUTPUT_JSON=false
NO_COLOR=false

# Colors
C_GREEN="\033[0;32m"
C_RED="\033[0;31m"
C_YELLOW="\033[1;33m"
# shellcheck disable=SC2034  # Reserved for future use
C_BOLD="\033[1m"
# shellcheck disable=SC2034  # Reserved for future use
C_DIM="\033[2m"
C_NC="\033[0m"

# Find project root
find_project_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -f "$dir/TODO.md" ]]; then
			echo "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

# Emit the current entry state as a pipe-delimited record and reset all fields
# Globals: current_status current_vid current_tid current_desc current_pr
#          current_merged current_files current_checks current_verified current_failed
_flush_entry() {
	if [[ -n "$current_vid" ]]; then
		echo "${current_status}|${current_vid}|${current_tid}|${current_desc}|${current_pr}|${current_merged}|${current_files}|${current_checks}|${current_verified}|${current_failed}"
	fi
	current_status="" current_vid="" current_tid="" current_desc=""
	current_pr="" current_merged="" current_files="" current_checks=""
	current_verified="" current_failed=""
	return 0
}

# Parse the header line of a verify entry and populate current_* globals
# Args: $1 = marker char, $2 = verify_id, $3 = task_id, $4 = rest of line
# Globals written: current_status current_vid current_tid current_desc
#                  current_pr current_merged current_verified current_failed
_parse_entry_header() {
	local marker="$1"
	current_vid="$2"
	current_tid="$3"
	local rest="$4"

	case "$marker" in
	" ") current_status="pending" ;;
	"x") current_status="passed" ;;
	"!") current_status="failed" ;;
	*) current_status="unknown" ;;
	esac

	# Extract PR reference
	if [[ "$rest" =~ \|\ PR\ #([0-9]+) ]]; then
		current_pr="#${BASH_REMATCH[1]}"
	elif [[ "$rest" =~ \|\ cherry-picked:([a-f0-9]+) ]]; then
		current_pr="cherry:${BASH_REMATCH[1]}"
	fi

	# Extract dates and failure reason
	[[ "$rest" =~ merged:([0-9-]+) ]] && current_merged="${BASH_REMATCH[1]}"
	[[ "$rest" =~ verified:([0-9-]+) ]] && current_verified="${BASH_REMATCH[1]}"
	[[ "$rest" =~ failed:[0-9-]+\ reason:(.+) ]] && current_failed="${BASH_REMATCH[1]}"

	# Description is everything before the first |, right-trimmed
	current_desc="${rest%%|*}"
	current_desc="${current_desc%"${current_desc##*[![:space:]]}"}"
	return 0
}

# Parse indented metadata lines (files: / check:) and append to current_* globals
# Args: $1 = line
# Globals written: current_files current_checks
_parse_entry_metadata() {
	local line="$1"
	if [[ "$line" =~ ^[[:space:]]+files:\ (.+) ]]; then
		current_files="${BASH_REMATCH[1]}"
	elif [[ "$line" =~ ^[[:space:]]+check:\ (.+) ]]; then
		if [[ -n "$current_checks" ]]; then
			current_checks="${current_checks}; ${BASH_REMATCH[1]}"
		else
			current_checks="${BASH_REMATCH[1]}"
		fi
	fi
	return 0
}

# Parse a verification entry block into structured data
# Input: path to VERIFY.md
# Output: pipe-delimited records: status|verify_id|task_id|description|pr|merged|files|checks|verified|failed_reason
parse_verify_entries() {
	local verify_file="$1"
	local in_queue=false
	current_status="" current_vid="" current_tid="" current_desc=""
	current_pr="" current_merged="" current_files="" current_checks=""
	current_verified="" current_failed=""

	while IFS= read -r line; do
		if [[ "$line" == "<!-- VERIFY-QUEUE-START -->" ]]; then
			in_queue=true
			continue
		fi
		if [[ "$line" == "<!-- VERIFY-QUEUE-END -->" ]]; then
			_flush_entry
			in_queue=false
			continue
		fi
		$in_queue || continue
		[[ -z "$line" ]] && continue

		# New entry: - [ ] v001 t168 Description | PR #660 | merged:2026-02-08
		if [[ "$line" =~ ^-\ \[(.)\]\ (v[0-9]+)\ (t[0-9]+)\ (.+) ]]; then
			_flush_entry
			_parse_entry_header "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
				"${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
			continue
		fi

		_parse_entry_metadata "$line"
	done <"$verify_file"

	_flush_entry
	return 0
}

# Apply filters
apply_filters() {
	local line="$1"
	local status
	local tid
	status=$(echo "$line" | cut -d'|' -f1)
	tid=$(echo "$line" | cut -d'|' -f3)

	# Status filter
	if [[ -n "$FILTER_STATUS" ]]; then
		[[ "$status" != "$FILTER_STATUS" ]] && return 1
	fi

	# Task filter
	if [[ -n "$FILTER_TASK" ]]; then
		[[ "$tid" != "$FILTER_TASK" ]] && return 1
	fi

	return 0
}

# Count entries by status in an entries file
# Args: $1 = entries_file
# Output: three lines: pending=N passed=N failed=N
_count_entries() {
	local entries_file="$1"
	local pending_count=0 passed_count=0 failed_count=0
	while IFS='|' read -r status _rest; do
		case "$status" in
		pending) ((++pending_count)) ;;
		passed) ((++passed_count)) ;;
		failed) ((++failed_count)) ;;
		esac
	done <"$entries_file"
	echo "pending=${pending_count}"
	echo "passed=${passed_count}"
	echo "failed=${failed_count}"
	return 0
}

# _print_section_header: print the markdown table header for a section.
# Args: $1 = section name (failed|pending|passed)
# Returns: 0 always.
_print_section_header() {
	local section="$1"
	case "$section" in
	failed)
		echo "| # | Verify | Task | Description | PR | Merged | Reason |"
		echo "|---|--------|------|-------------|-----|--------|--------|"
		;;
	pending)
		echo "| # | Verify | Task | Description | PR | Merged | Checks |"
		echo "|---|--------|------|-------------|-----|--------|--------|"
		;;
	passed)
		echo "| # | Verify | Task | Description | PR | Merged | Verified |"
		echo "|---|--------|------|-------------|-----|--------|----------|"
		;;
	esac
	return 0
}

# _print_section_rows: print table rows for a section from entries_file.
# Args: $1 = section name, $2 = entries_file
# Returns: 0 always.
_print_section_rows() {
	local section="$1"
	local entries_file="$2"
	local num=0

	while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
		[[ "$status" != "$section" ]] && continue
		((++num))
		case "$section" in
		failed)
			echo "| $num | $vid | $tid | $desc | $pr | $merged | ${failed_reason:--} |"
			;;
		pending)
			local check_count=0
			[[ -n "$checks" ]] && check_count=$(echo "$checks" | tr ';' '\n' | wc -l | tr -d ' ')
			echo "| $num | $vid | $tid | $desc | $pr | $merged | ${check_count} checks |"
			;;
		passed)
			echo "| $num | $vid | $tid | $desc | $pr | $merged | ${verified:--} |"
			;;
		esac
	done <"$entries_file"
	return 0
}

# Render one status section (failed / pending / passed) in markdown
# Args: $1 = section name, $2 = count, $3 = entries_file, $4 = color code
_output_markdown_section() {
	local section="$1"
	local count="$2"
	local entries_file="$3"
	local color="$4"

	[[ "$count" -eq 0 ]] && return 0

	local title
	title=$(printf '%s' "${section:0:1}" | tr '[:lower:]' '[:upper:]')${section:1}

	if $NO_COLOR; then
		echo "### ${title} ($count)"
	else
		echo -e "### ${color}${title} ($count)${C_NC}"
	fi
	echo ""

	if $COMPACT; then
		while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
			[[ "$status" != "$section" ]] && continue
			case "$section" in
			failed) echo "- [!] $vid $tid $desc $pr ${failed_reason:+reason: $failed_reason}" ;;
			pending) echo "- [ ] $vid $tid $desc $pr" ;;
			passed) echo "- [x] $vid $tid $desc $pr verified:$verified" ;;
			esac
		done <"$entries_file"
	else
		_print_section_header "$section"
		_print_section_rows "$section" "$entries_file"
	fi
	echo ""
	echo "---"
	echo ""
	return 0
}

# Output as markdown
output_markdown() {
	local entries_file="$1"
	local pending_count=0 passed_count=0 failed_count=0

	while IFS='=' read -r key val; do
		case "$key" in
		pending) pending_count="$val" ;;
		passed) passed_count="$val" ;;
		failed) failed_count="$val" ;;
		esac
	done < <(_count_entries "$entries_file")

	local total=$((pending_count + passed_count + failed_count))

	echo "## Verification Queue"
	echo ""

	if [[ $total -eq 0 ]]; then
		echo "*No verification entries found.*"
		echo ""
		return 0
	fi

	_output_markdown_section "failed" "$failed_count" "$entries_file" "$C_RED"
	_output_markdown_section "pending" "$pending_count" "$entries_file" "$C_YELLOW"
	_output_markdown_section "passed" "$passed_count" "$entries_file" "$C_GREEN"

	echo -e "**Summary:** ${pending_count} pending | ${passed_count} passed | ${failed_count} failed | ${total} total"
	return 0
}

# Escape string for JSON output
json_escape() {
	local str="$1"
	str="${str//\\/\\\\}"
	str="${str//\"/\\\"}"
	str="${str//$'\n'/\\n}"
	str="${str//$'\r'/\\r}"
	str="${str//$'\t'/\\t}"
	echo "$str"
	return 0
}

# Output as JSON
output_json() {
	local entries_file="$1"

	echo "{"

	local sections=("pending" "passed" "failed")
	local first_section=true

	for section in "${sections[@]}"; do
		$first_section || echo ","
		first_section=false

		echo "  \"${section}\": ["
		local first=true
		while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
			[[ "$status" != "$section" ]] && continue
			$first || echo ","
			first=false
			desc=$(json_escape "$desc")
			files=$(json_escape "$files")
			checks=$(json_escape "$checks")
			failed_reason=$(json_escape "$failed_reason")
			printf '    {"verify_id":"%s","task_id":"%s","desc":"%s","pr":"%s","merged":"%s","files":"%s","checks":"%s","verified":"%s","failed_reason":"%s"}' \
				"$vid" "$tid" "$desc" "$pr" "$merged" "$files" "$checks" "$verified" "$failed_reason"
		done <"$entries_file"
		echo ""
		echo "  ]"
	done

	echo "}"
	return 0
}

# Show help
show_help() {
	cat <<'EOF'
Usage: list-verify-helper.sh [options]

Filtering:
  --pending          Show only pending verifications [ ]
  --passed           Show only passed verifications [x]
  --failed           Show only failed verifications [!]
  --task, -t ID      Filter by task ID (e.g., t168)

Display:
  --compact          One-line per entry (no details)
  --json             Output as JSON
  --no-color         Disable colors
  --help, -h         Show this help

Examples:
  list-verify-helper.sh                # All entries, grouped by status
  list-verify-helper.sh --pending      # Only pending verifications
  list-verify-helper.sh --failed       # Only failed (needs attention)
  list-verify-helper.sh -t t168        # Specific task verification
  list-verify-helper.sh --compact      # One-line per entry
  list-verify-helper.sh --json         # JSON output
EOF
	return 0
}

# Require argument for option
require_arg() {
	local opt="$1"
	local val="$2"
	if [[ -z "$val" || "$val" == -* ]]; then
		echo "ERROR: Option $opt requires an argument" >&2
		exit 1
	fi
	return 0
}

# Main
main() {
	# Parse command line
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pending) FILTER_STATUS="pending" ;;
		--passed) FILTER_STATUS="passed" ;;
		--failed) FILTER_STATUS="failed" ;;
		--task | -t)
			require_arg "$1" "${2:-}"
			FILTER_TASK="$2"
			shift
			;;
		--compact) COMPACT=true ;;
		--json) OUTPUT_JSON=true ;;
		--no-color) NO_COLOR=true ;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
		shift
	done

	# Disable colors if not a terminal
	# shellcheck disable=SC2034
	if $NO_COLOR || [[ ! -t 1 ]]; then
		C_GREEN="" C_RED="" C_YELLOW="" C_BOLD="" C_DIM="" C_NC=""
	fi

	# Find project
	local project_root
	project_root=$(find_project_root) || {
		echo "ERROR: Not in a project directory (no TODO.md found)" >&2
		exit 1
	}

	local verify_file="$project_root/todo/VERIFY.md"

	if [[ ! -f "$verify_file" ]]; then
		echo "No verification queue found (todo/VERIFY.md does not exist)." >&2
		exit 0
	fi

	# Create temp file
	local entries_tmp
	entries_tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$entries_tmp'" EXIT

	# Parse and filter entries
	parse_verify_entries "$verify_file" | while IFS= read -r line; do
		if apply_filters "$line"; then
			echo "$line"
		fi
	done >"$entries_tmp"

	# Output
	if $OUTPUT_JSON; then
		output_json "$entries_tmp"
	else
		output_markdown "$entries_tmp"
	fi
}

main "$@"
