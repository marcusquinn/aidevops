#!/usr/bin/env bash
# verify-brief.sh - Extract and execute verify: blocks from task briefs
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   verify-brief.sh <brief-file> [options]
#
# Options:
#   --repo-path <path>    Repository root (default: git root or PWD)
#   --json                Output results as JSON
#   --verbose             Show command output for passing checks
#   --dry-run             Parse and show blocks without executing
#   --help                Show this help message
#
# Verify block methods:
#   bash      — run shell command, pass if exit 0
#   codebase  — rg pattern search, pass if match found (expect: absent inverts)
#   subagent  — spawn AI review prompt (requires ai-research MCP)
#   manual    — flag for human review (always SKIP, never blocks)
#
# Exit codes:
#   0 - All non-manual criteria passed (or no verify blocks found)
#   1 - One or more criteria failed
#   2 - Usage error (missing file, bad arguments)
#
# Examples:
#   verify-brief.sh todo/tasks/t1313-brief.md
#   verify-brief.sh todo/tasks/t1313-brief.md --dry-run
#   verify-brief.sh todo/tasks/t1313-brief.md --json --verbose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Configuration
BRIEF_FILE=""
REPO_PATH=""
JSON_OUTPUT=false
VERBOSE=false
DRY_RUN=false

# Counters
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
UNVERIFIED_COUNT=0
TOTAL_CRITERIA=0

# Results array (for JSON output)
declare -a RESULTS=()

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*" >&2; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*" >&2; }
log_unverified() { echo -e "${PURPLE}[UNVERIFIED]${NC} $*" >&2; }
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2 || true; }

# Show help
show_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
	return 0
}

# Parse arguments
parse_args() {
	if [[ $# -eq 0 ]]; then
		log_fail "Missing required argument: brief-file"
		show_help
		return 2
	fi

	local arg=""
	local val=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--repo-path)
			val="$2"
			REPO_PATH="$val"
			shift 2
			;;
		--json)
			JSON_OUTPUT=true
			shift
			;;
		--verbose)
			VERBOSE=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help)
			show_help
			exit 0
			;;
		-*)
			log_fail "Unknown option: $arg"
			return 2
			;;
		*)
			if [[ -z "$BRIEF_FILE" ]]; then
				BRIEF_FILE="$arg"
			else
				log_fail "Unexpected argument: $arg"
				return 2
			fi
			shift
			;;
		esac
	done

	# Validate brief file exists
	if [[ ! -f "$BRIEF_FILE" ]]; then
		log_fail "Brief file not found: $BRIEF_FILE"
		return 2
	fi

	# Resolve repo path
	if [[ -z "$REPO_PATH" ]]; then
		REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
	fi

	return 0
}

# Extract acceptance criteria and their verify blocks from a brief file.
# Writes parallel arrays: CRITERIA_TEXT[], CRITERIA_YAML[]
# Each index corresponds to one criterion. YAML is empty string if no verify block.
parse_brief() {
	local brief_file="$1"
	local in_criteria=false
	local in_yaml_block=false
	local yaml_content=""
	local current_index=-1
	local found_criteria_section=false

	CRITERIA_TEXT=()
	CRITERIA_YAML=()

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Detect Acceptance Criteria section
		if [[ "$line" =~ ^##[[:space:]]+Acceptance[[:space:]]+Criteria ]]; then
			in_criteria=true
			found_criteria_section=true
			continue
		fi

		# Detect next section (exit criteria parsing)
		if [[ "$in_criteria" == "true" && "$line" =~ ^##[[:space:]] && ! "$line" =~ Acceptance ]]; then
			break
		fi

		if [[ "$in_criteria" != "true" ]]; then
			continue
		fi

		# Detect start of yaml fenced block
		if [[ "$in_yaml_block" == "false" && "$line" =~ ^[[:space:]]*\`\`\`yaml[[:space:]]*$ ]]; then
			in_yaml_block=true
			yaml_content=""
			continue
		fi

		# Detect end of yaml fenced block
		if [[ "$in_yaml_block" == "true" && "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
			in_yaml_block=false
			if [[ -n "$yaml_content" && $current_index -ge 0 ]]; then
				CRITERIA_YAML[current_index]="$yaml_content"
			fi
			yaml_content=""
			continue
		fi

		# Accumulate yaml content
		if [[ "$in_yaml_block" == "true" ]]; then
			if [[ -n "$yaml_content" ]]; then
				yaml_content="${yaml_content}"$'\n'"${line}"
			else
				yaml_content="${line}"
			fi
			continue
		fi

		# Detect criterion line (- [ ] or - [x])
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]x]\][[:space:]](.+)$ ]]; then
			current_index=$((${#CRITERIA_TEXT[@]}))
			CRITERIA_TEXT+=("${BASH_REMATCH[1]}")
			CRITERIA_YAML+=("")
			continue
		fi

	done <"$brief_file"

	if [[ "$found_criteria_section" != "true" ]]; then
		log_info "No Acceptance Criteria section found in $brief_file"
	fi

	return 0
}

# Parse a YAML verify block into variables.
# Sets: V_METHOD, V_RUN, V_PATTERN, V_PATH, V_EXPECT, V_PROMPT, V_FILES
parse_verify_yaml() {
	local yaml="$1"

	V_METHOD=""
	V_RUN=""
	V_PATTERN=""
	V_PATH=""
	V_EXPECT="present"
	V_PROMPT=""
	V_FILES=""

	local line
	while IFS= read -r line; do
		# Strip leading whitespace
		line="${line#"${line%%[![:space:]]*}"}"

		# Skip verify: header line
		[[ "$line" == "verify:" ]] && continue
		# Skip empty lines
		[[ -z "$line" ]] && continue

		# Parse key: value pairs
		if [[ "$line" =~ ^method:[[:space:]]*(.+)$ ]]; then
			V_METHOD="${BASH_REMATCH[1]}"
			# Strip surrounding quotes
			V_METHOD="${V_METHOD#\"}"
			V_METHOD="${V_METHOD%\"}"
		elif [[ "$line" =~ ^run:[[:space:]]*(.+)$ ]]; then
			V_RUN="${BASH_REMATCH[1]}"
			V_RUN="${V_RUN#\"}"
			V_RUN="${V_RUN%\"}"
		elif [[ "$line" =~ ^pattern:[[:space:]]*(.+)$ ]]; then
			V_PATTERN="${BASH_REMATCH[1]}"
			V_PATTERN="${V_PATTERN#\"}"
			V_PATTERN="${V_PATTERN%\"}"
		elif [[ "$line" =~ ^path:[[:space:]]*(.+)$ ]]; then
			V_PATH="${BASH_REMATCH[1]}"
			V_PATH="${V_PATH#\"}"
			V_PATH="${V_PATH%\"}"
		elif [[ "$line" =~ ^expect:[[:space:]]*(.+)$ ]]; then
			V_EXPECT="${BASH_REMATCH[1]}"
			V_EXPECT="${V_EXPECT#\"}"
			V_EXPECT="${V_EXPECT%\"}"
		elif [[ "$line" =~ ^prompt:[[:space:]]*(.+)$ ]]; then
			V_PROMPT="${BASH_REMATCH[1]}"
			V_PROMPT="${V_PROMPT#\"}"
			V_PROMPT="${V_PROMPT%\"}"
		elif [[ "$line" =~ ^files:[[:space:]]*(.+)$ ]]; then
			V_FILES="${BASH_REMATCH[1]}"
			V_FILES="${V_FILES#\"}"
			V_FILES="${V_FILES%\"}"
		fi
	done <<<"$yaml"

	# Minimal YAML unescape: \\ -> \ (double-quoted YAML strings use \\ for literal backslash)
	V_RUN="${V_RUN//\\\\/\\}"
	V_PATTERN="${V_PATTERN//\\\\/\\}"
	V_PATH="${V_PATH//\\\\/\\}"
	V_PROMPT="${V_PROMPT//\\\\/\\}"
	V_FILES="${V_FILES//\\\\/\\}"

	# Validate method
	if [[ -z "$V_METHOD" ]]; then
		log_fail "Verify block missing 'method' field"
		return 1
	fi

	case "$V_METHOD" in
	bash | codebase | subagent | manual) ;;
	*)
		log_fail "Unknown verify method: $V_METHOD"
		return 1
		;;
	esac

	return 0
}

# Execute a bash verification
exec_bash() {
	local run_cmd="$1"
	local repo_path="$2"

	if [[ -z "$run_cmd" ]]; then
		log_fail "bash method requires 'run' field"
		return 1
	fi

	log_debug "Running: $run_cmd"

	local output
	local rc=0
	output=$(cd "$repo_path" && bash -c "$run_cmd" 2>&1) || rc=$?

	if [[ "$VERBOSE" == "true" && -n "$output" ]]; then
		echo "$output" | head -20 >&2
	fi

	return $rc
}

# Execute a codebase verification
exec_codebase() {
	local pattern="$1"
	local search_path="$2"
	local expect="$3"
	local repo_path="$4"

	if [[ -z "$pattern" ]]; then
		log_fail "codebase method requires 'pattern' field"
		return 1
	fi

	# Default search path is repo root
	local full_path="$repo_path"
	if [[ -n "$search_path" ]]; then
		full_path="${repo_path}/${search_path}"
	fi

	log_debug "Searching for pattern '$pattern' in '$full_path' (expect: $expect)"

	local rc=0
	local output
	# Use -- to prevent pattern from being interpreted as rg flags
	output=$(rg --no-heading -c -- "$pattern" "$full_path" 2>/dev/null) || rc=$?

	local found=false
	if [[ $rc -eq 0 && -n "$output" ]]; then
		found=true
	fi

	if [[ "$VERBOSE" == "true" ]]; then
		if [[ "$found" == "true" ]]; then
			rg --no-heading -n -- "$pattern" "$full_path" 2>/dev/null | head -5 >&2 || true
		fi
	fi

	if [[ "$expect" == "absent" ]]; then
		# Pass if pattern NOT found
		if [[ "$found" == "true" ]]; then
			return 1
		fi
		return 0
	else
		# Pass if pattern found (default: present)
		if [[ "$found" == "true" ]]; then
			return 0
		fi
		return 1
	fi
}

# Execute a subagent verification
exec_subagent() {
	local prompt="$1"
	local files="$2"

	if [[ -z "$prompt" ]]; then
		log_fail "subagent method requires 'prompt' field"
		return 1
	fi

	# Subagent verification requires interactive AI — report as skip in automated mode
	log_skip "Subagent verification requires interactive AI review"
	log_info "  Prompt: $prompt"
	if [[ -n "$files" ]]; then
		log_info "  Files: $files"
	fi

	# Return special code 3 to indicate "skip" (not fail)
	return 3
}

# Execute a manual verification
exec_manual() {
	local prompt="$1"

	log_skip "Manual verification required"
	if [[ -n "$prompt" ]]; then
		log_info "  Check: $prompt"
	fi

	# Return special code 3 to indicate "skip" (not fail)
	return 3
}

# Add a result to the results array
add_result() {
	local criterion="$1"
	local status="$2"
	local method="${3:-none}"
	local detail="${4:-}"

	# Escape for JSON
	criterion="${criterion//\\/\\\\}"
	criterion="${criterion//\"/\\\"}"
	detail="${detail//\\/\\\\}"
	detail="${detail//\"/\\\"}"

	RESULTS+=("{\"criterion\":\"${criterion}\",\"status\":\"${status}\",\"method\":\"${method}\",\"detail\":\"${detail}\"}")
	return 0
}

# Output results as JSON
output_json() {
	local pass="$1"
	local fail="$2"
	local skip="$3"
	local unverified="$4"
	local total="$5"

	echo "{"
	echo "  \"summary\": {"
	echo "    \"total\": $total,"
	echo "    \"pass\": $pass,"
	echo "    \"fail\": $fail,"
	echo "    \"skip\": $skip,"
	echo "    \"unverified\": $unverified"
	echo "  },"
	echo "  \"results\": ["

	local i=0
	local count=${#RESULTS[@]}
	for result in "${RESULTS[@]}"; do
		i=$((i + 1))
		if [[ $i -lt $count ]]; then
			echo "    ${result},"
		else
			echo "    ${result}"
		fi
	done

	echo "  ]"
	echo "}"
	return 0
}

# Process a single criterion with its optional verify block
process_criterion() {
	local criterion="$1"
	local yaml="$2"

	TOTAL_CRITERIA=$((TOTAL_CRITERIA + 1))

	# No verify block — mark as unverified
	if [[ -z "$yaml" ]]; then
		UNVERIFIED_COUNT=$((UNVERIFIED_COUNT + 1))
		log_unverified "$criterion"
		add_result "$criterion" "unverified" "none" "No verify block"
		return 0
	fi

	# Parse the YAML block
	if ! parse_verify_yaml "$yaml"; then
		FAIL_COUNT=$((FAIL_COUNT + 1))
		log_fail "$criterion (invalid verify block)"
		add_result "$criterion" "fail" "unknown" "Invalid verify block"
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "  [$V_METHOD] $criterion"
		case "$V_METHOD" in
		bash) log_info "    run: $V_RUN" ;;
		codebase) log_info "    pattern: $V_PATTERN  path: ${V_PATH:-<repo>}  expect: $V_EXPECT" ;;
		subagent) log_info "    prompt: $V_PROMPT" ;;
		manual) log_info "    prompt: ${V_PROMPT:-<none>}" ;;
		esac
		add_result "$criterion" "dry-run" "$V_METHOD" ""
		return 0
	fi

	# Execute verification
	local rc=0
	case "$V_METHOD" in
	bash)
		exec_bash "$V_RUN" "$REPO_PATH" || rc=$?
		;;
	codebase)
		exec_codebase "$V_PATTERN" "$V_PATH" "$V_EXPECT" "$REPO_PATH" || rc=$?
		;;
	subagent)
		exec_subagent "$V_PROMPT" "$V_FILES" || rc=$?
		;;
	manual)
		exec_manual "$V_PROMPT" || rc=$?
		;;
	esac

	# Interpret result
	case $rc in
	0)
		PASS_COUNT=$((PASS_COUNT + 1))
		log_pass "$criterion"
		add_result "$criterion" "pass" "$V_METHOD" ""
		;;
	3)
		# Skip (subagent/manual)
		SKIP_COUNT=$((SKIP_COUNT + 1))
		add_result "$criterion" "skip" "$V_METHOD" "Requires human/AI review"
		;;
	*)
		FAIL_COUNT=$((FAIL_COUNT + 1))
		log_fail "$criterion"
		add_result "$criterion" "fail" "$V_METHOD" "Exit code: $rc"
		;;
	esac

	return 0
}

# Main execution
main() {
	local parse_rc=0
	parse_args "$@" || parse_rc=$?
	if [[ $parse_rc -ne 0 ]]; then
		return $parse_rc
	fi

	log_info "Verifying brief: $BRIEF_FILE"
	log_info "Repo path: $REPO_PATH"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN — parsing only, no execution"
	fi

	# Parse the brief file into parallel arrays
	parse_brief "$BRIEF_FILE"

	local count=${#CRITERIA_TEXT[@]}
	if [[ $count -eq 0 ]]; then
		log_info "No acceptance criteria found"
		return 0
	fi

	# Process each criterion
	local i
	for ((i = 0; i < count; i++)); do
		process_criterion "${CRITERIA_TEXT[$i]}" "${CRITERIA_YAML[$i]}"
	done

	# Summary
	echo "" >&2
	log_info "=== Verification Summary ==="
	log_info "Total criteria: $TOTAL_CRITERIA"
	[[ $PASS_COUNT -gt 0 ]] && log_pass "Passed: $PASS_COUNT"
	[[ $FAIL_COUNT -gt 0 ]] && log_fail "Failed: $FAIL_COUNT"
	[[ $SKIP_COUNT -gt 0 ]] && log_skip "Skipped: $SKIP_COUNT (manual/subagent)"
	[[ $UNVERIFIED_COUNT -gt 0 ]] && log_unverified "Unverified: $UNVERIFIED_COUNT (no verify block)"

	# JSON output
	if [[ "$JSON_OUTPUT" == "true" ]]; then
		output_json "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$UNVERIFIED_COUNT" "$TOTAL_CRITERIA"
	fi

	# Exit code: fail if any criteria failed
	if [[ $FAIL_COUNT -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
