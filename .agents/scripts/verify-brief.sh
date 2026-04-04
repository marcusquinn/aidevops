#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
#   runtime   — start dev env, run smoke/stability checks via browser-qa-helper.sh
#
# Runtime method fields (verify block):
#   url       — base URL to test (default: read from testing.json or http://localhost:3000)
#   pages     — space-separated page paths to smoke-test (default: "/")
#   start_cmd — shell command to start dev env (optional; skipped if URL already responds)
#   timeout   — seconds to wait for dev env to start (default: 30)
#
# Runtime method reads testing.json from repo root or ~/.aidevops/testing.json for defaults.
# testing.json fields used: url, start_command, smoke_pages (all optional).
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

# Logging: uses shared log_info/log_error/log_success/log_warn from shared-constants.sh
# Script-specific log levels kept inline
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
			if [[ $# -lt 2 || "$2" == -* ]]; then
				log_fail "Missing value for --repo-path"
				return 2
			fi
			REPO_PATH="$2"
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
# Sets: V_METHOD, V_RUN, V_PATTERN, V_PATH, V_EXPECT, V_PROMPT, V_FILES,
#       V_URL, V_PAGES, V_START_CMD, V_TIMEOUT
parse_verify_yaml() {
	local yaml="$1"

	V_METHOD=""
	V_RUN=""
	V_PATTERN=""
	V_PATH=""
	V_EXPECT="present"
	V_PROMPT=""
	V_FILES=""
	# runtime method fields
	V_URL=""
	V_PAGES=""
	V_START_CMD=""
	V_TIMEOUT="30"

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
		elif [[ "$line" =~ ^url:[[:space:]]*(.+)$ ]]; then
			V_URL="${BASH_REMATCH[1]}"
			V_URL="${V_URL#\"}"
			V_URL="${V_URL%\"}"
		elif [[ "$line" =~ ^pages:[[:space:]]*(.+)$ ]]; then
			V_PAGES="${BASH_REMATCH[1]}"
			V_PAGES="${V_PAGES#\"}"
			V_PAGES="${V_PAGES%\"}"
		elif [[ "$line" =~ ^start_cmd:[[:space:]]*(.+)$ ]]; then
			V_START_CMD="${BASH_REMATCH[1]}"
			V_START_CMD="${V_START_CMD#\"}"
			V_START_CMD="${V_START_CMD%\"}"
		elif [[ "$line" =~ ^timeout:[[:space:]]*(.+)$ ]]; then
			V_TIMEOUT="${BASH_REMATCH[1]}"
			V_TIMEOUT="${V_TIMEOUT#\"}"
			V_TIMEOUT="${V_TIMEOUT%\"}"
		fi
	done <<<"$yaml"

	# Minimal YAML unescape: \\ -> \ (double-quoted YAML strings use \\ for literal backslash)
	V_RUN="${V_RUN//\\\\/\\}"
	V_PATTERN="${V_PATTERN//\\\\/\\}"
	V_PATH="${V_PATH//\\\\/\\}"
	V_PROMPT="${V_PROMPT//\\\\/\\}"
	V_FILES="${V_FILES//\\\\/\\}"
	V_URL="${V_URL//\\\\/\\}"
	V_PAGES="${V_PAGES//\\\\/\\}"
	V_START_CMD="${V_START_CMD//\\\\/\\}"

	# Validate method
	if [[ -z "$V_METHOD" ]]; then
		log_fail "Verify block missing 'method' field"
		return 1
	fi

	case "$V_METHOD" in
	bash | codebase | subagent | manual | runtime) ;;
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

# Read a field from testing.json (repo-local or ~/.aidevops/testing.json).
# Args: $1 = field name, $2 = repo_path, $3 = default value
# Output: field value or default
_read_testing_json_field() {
	local field="$1"
	local repo_path="$2"
	local default_val="$3"

	# Search order: repo-local testing.json, then ~/.aidevops/testing.json
	local config_file=""
	if [[ -f "${repo_path}/testing.json" ]]; then
		config_file="${repo_path}/testing.json"
	elif [[ -f "${HOME}/.aidevops/testing.json" ]]; then
		config_file="${HOME}/.aidevops/testing.json"
	fi

	if [[ -z "$config_file" ]]; then
		echo "$default_val"
		return 0
	fi

	# Use jq if available, otherwise fall back to grep-based extraction
	if command -v jq >/dev/null 2>&1; then
		local val
		val=$(jq -r --arg f "$field" '.[$f] // empty' "$config_file" 2>/dev/null || true)
		if [[ -n "$val" && "$val" != "null" ]]; then
			echo "$val"
			return 0
		fi
	else
		# Minimal grep-based extraction for simple string fields
		local val
		val=$(grep -E "\"${field}\"[[:space:]]*:[[:space:]]*\"" "$config_file" 2>/dev/null |
			sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/" |
			head -1 || true)
		if [[ -n "$val" ]]; then
			echo "$val"
			return 0
		fi
	fi

	echo "$default_val"
	return 0
}

# Check if a URL is reachable (HTTP 2xx or 3xx response).
# Args: $1 = url, $2 = timeout_seconds
# Returns: 0 if reachable, 1 if not
_url_reachable() {
	local url="$1"
	local timeout_secs="${2:-10}"

	if command -v curl >/dev/null 2>&1; then
		local http_code
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			--max-time "$timeout_secs" \
			--connect-timeout 5 \
			"$url" 2>/dev/null || echo "000")
		case "$http_code" in
		2?? | 3??) return 0 ;;
		*) return 1 ;;
		esac
	elif command -v wget >/dev/null 2>&1; then
		wget -q --spider --timeout="$timeout_secs" "$url" >/dev/null 2>&1
		return $?
	fi

	# No curl or wget — cannot check
	log_warn "Neither curl nor wget available; cannot check URL reachability"
	return 1
}

# Wait for a URL to become reachable, polling every 2 seconds.
# Args: $1 = url, $2 = timeout_seconds
# Returns: 0 when reachable, 1 on timeout
_wait_for_url() {
	local url="$1"
	local timeout_secs="${2:-30}"
	local elapsed=0
	local interval=2

	while [[ $elapsed -lt $timeout_secs ]]; do
		if _url_reachable "$url" 5; then
			return 0
		fi
		sleep $interval
		elapsed=$((elapsed + interval))
	done

	return 1
}

# Resolve runtime verify defaults from testing.json for empty fields.
# Mutates caller's url/pages/start_cmd via nameref-free approach: prints
# three newline-separated values (url, pages, start_cmd) to stdout.
# Args: $1=url, $2=pages, $3=start_cmd, $4=repo_path
_runtime_resolve_defaults() {
	local url="$1"
	local pages="$2"
	local start_cmd="$3"
	local repo_path="$4"

	if [[ -z "$url" ]]; then
		url=$(_read_testing_json_field "url" "$repo_path" "http://localhost:3000")
	fi
	if [[ -z "$pages" ]]; then
		pages=$(_read_testing_json_field "smoke_pages" "$repo_path" "/")
	fi
	if [[ -z "$start_cmd" ]]; then
		start_cmd=$(_read_testing_json_field "start_command" "$repo_path" "")
	fi

	printf '%s\n' "$url" "$pages" "$start_cmd"
	return 0
}

# Ensure the dev environment is running at the given URL.
# Starts it via start_cmd if not already reachable.
# On success: prints the background PID (or 0 if already running) to stdout.
# Args: $1=url, $2=start_cmd, $3=timeout_secs, $4=repo_path
# Returns: 0=running, 1=failed to start
_runtime_start_dev_env() {
	local url="$1"
	local start_cmd="$2"
	local timeout_secs="$3"
	local repo_path="$4"

	if _url_reachable "$url" 5; then
		log_debug "Dev environment already running at $url"
		echo "0"
		return 0
	fi

	if [[ -z "$start_cmd" ]]; then
		log_fail "Dev environment not running at $url and no start_cmd provided"
		log_info "  Set start_cmd in verify block or testing.json to auto-start"
		return 1
	fi

	log_info "  Starting dev environment: $start_cmd"
	local start_log
	start_log=$(mktemp "${TMPDIR:-/tmp}/verify-brief-runtime-XXXXXX.log")
	(cd "$repo_path" && bash -c "$start_cmd" >"$start_log" 2>&1) &
	local start_pid=$!
	log_debug "Dev env started with PID $start_pid, log: $start_log"

	log_info "  Waiting for $url (timeout: ${timeout_secs}s)..."
	if ! _wait_for_url "$url" "$timeout_secs"; then
		log_fail "Dev environment did not start within ${timeout_secs}s"
		kill "$start_pid" 2>/dev/null || true
		rm -f "$start_log"
		return 1
	fi

	log_debug "Dev environment ready at $url"
	echo "$start_pid"
	return 0
}

# Run browser-qa smoke checks and return their raw output via stdout.
# Args: $1=browser_qa_helper, $2=url, $3=pages
# Returns: exit code from browser-qa-helper.sh smoke command
_runtime_run_smoke() {
	local browser_qa_helper="$1"
	local url="$2"
	local pages="$3"

	log_info "  Running smoke checks on $url (pages: $pages)"
	local smoke_output
	local smoke_rc=0
	smoke_output=$(bash "$browser_qa_helper" smoke \
		--url "$url" \
		--pages "$pages" \
		--timeout 30000 \
		2>&1) || smoke_rc=$?

	if [[ "$VERBOSE" == "true" && -n "$smoke_output" ]]; then
		echo "$smoke_output" | head -30 >&2
	fi

	printf '%s' "$smoke_output"
	return $smoke_rc
}

# Parse JSON summary from smoke output.
# Prints three newline-separated values: passed, total, console_errors.
# Args: $1=smoke_output
_runtime_parse_smoke_results() {
	local smoke_output="$1"
	local passed=0
	local total=0
	local console_errors=0

	if command -v jq >/dev/null 2>&1; then
		local json_part
		json_part=$(printf '%s' "$smoke_output" | grep -E '^\{' | head -1 || true)
		if [[ -n "$json_part" ]]; then
			passed=$(printf '%s' "$json_part" | jq -r '.summary.passed // 0' 2>/dev/null || echo "0")
			total=$(printf '%s' "$json_part" | jq -r '.summary.total // 0' 2>/dev/null || echo "0")
			console_errors=$(printf '%s' "$json_part" | jq -r '.summary.consoleErrors // 0' 2>/dev/null || echo "0")
		fi
	fi

	printf '%s\n' "$passed" "$total" "$console_errors"
	return 0
}

# Evaluate smoke results and log pass/fail.
# Args: $1=smoke_rc, $2=smoke_output, $3=passed, $4=total, $5=console_errors, $6=url
# Returns: 0=pass, 1=fail
_runtime_evaluate_smoke() {
	local smoke_rc="$1"
	local smoke_output="$2"
	local passed="$3"
	local total="$4"
	local console_errors="$5"
	local url="$6"

	if [[ $smoke_rc -ne 0 ]]; then
		log_fail "Smoke checks failed (exit $smoke_rc)"
		if [[ "$VERBOSE" != "true" && -n "$smoke_output" ]]; then
			printf '%s' "$smoke_output" | tail -5 >&2
		fi
		return 1
	fi

	if [[ $console_errors -gt 0 ]]; then
		log_fail "Smoke checks: $console_errors console error(s) detected on $url"
		return 1
	fi

	if [[ $total -gt 0 ]]; then
		log_pass "Smoke checks: $passed/$total pages passed on $url"
	else
		log_pass "Smoke checks passed on $url"
	fi

	return 0
}

# Execute a runtime verification: start dev env, run smoke checks.
# Args: $1=url, $2=pages, $3=start_cmd, $4=timeout, $5=repo_path
# Returns: 0=pass, 1=fail, 3=skip (browser-qa-helper.sh not available)
exec_runtime() {
	local url="$1"
	local pages="$2"
	local start_cmd="$3"
	local timeout_secs="$4"
	local repo_path="$5"

	local browser_qa_helper="${SCRIPT_DIR}/browser-qa-helper.sh"

	# Resolve defaults from testing.json for any empty fields
	local resolved
	resolved=$(_runtime_resolve_defaults "$url" "$pages" "$start_cmd" "$repo_path")
	url=$(printf '%s\n' "$resolved" | sed -n '1p')
	pages=$(printf '%s\n' "$resolved" | sed -n '2p')
	start_cmd=$(printf '%s\n' "$resolved" | sed -n '3p')

	log_debug "Runtime verify: url=$url pages=$pages timeout=${timeout_secs}s"

	if [[ ! -x "$browser_qa_helper" ]]; then
		log_skip "Runtime verification: browser-qa-helper.sh not found at $browser_qa_helper"
		return 3
	fi

	# Phase 1: Ensure dev environment is running
	local start_pid
	start_pid=$(_runtime_start_dev_env "$url" "$start_cmd" "$timeout_secs" "$repo_path") || return 1

	# Phase 2: Run smoke checks
	local smoke_output
	local smoke_rc=0
	smoke_output=$(_runtime_run_smoke "$browser_qa_helper" "$url" "$pages") || smoke_rc=$?

	# Phase 3: Parse smoke results
	local smoke_results
	smoke_results=$(_runtime_parse_smoke_results "$smoke_output")
	local passed total console_errors
	passed=$(printf '%s\n' "$smoke_results" | sed -n '1p')
	total=$(printf '%s\n' "$smoke_results" | sed -n '2p')
	console_errors=$(printf '%s\n' "$smoke_results" | sed -n '3p')

	# Cleanup: stop dev env if we started it
	if [[ "${start_pid:-0}" -gt 0 ]]; then
		kill "$start_pid" 2>/dev/null || true
	fi

	_runtime_evaluate_smoke "$smoke_rc" "$smoke_output" "$passed" "$total" "$console_errors" "$url"
	return $?
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
		runtime) log_info "    url: ${V_URL:-<from testing.json>}  pages: ${V_PAGES:-/}  start_cmd: ${V_START_CMD:-<none>}  timeout: ${V_TIMEOUT}s" ;;
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
	runtime)
		exec_runtime "$V_URL" "$V_PAGES" "$V_START_CMD" "$V_TIMEOUT" "$REPO_PATH" || rc=$?
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
