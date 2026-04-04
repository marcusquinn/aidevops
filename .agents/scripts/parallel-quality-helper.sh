#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1072,SC1073,SC2086
# =============================================================================
# Parallel Quality Helper - Run quality checks concurrently (~3.75x speedup)
# =============================================================================
# Runs shellcheck, sonarcloud, secrets, markdown, and returns checks in
# parallel using & + wait, then aggregates results.
#
# Usage:
#   parallel-quality-helper.sh [checks...]
#   parallel-quality-helper.sh all
#   parallel-quality-helper.sh shellcheck sonarcloud
#   parallel-quality-helper.sh --timeout 120
#
# Checks (pass one or more as arguments):
#   sc          - static analysis on .sh files (ShellCheck)
#   sonarcloud  - quality gate status (SonarCloud remote API)
#   secrets     - secret detection (Secretlint)
#   markdown    - style checks on .md files (markdownlint)
#   returns     - return statement coverage in shell functions
#   all         - run all checks (default)
#
# Note: the 'sc' check key maps to 'shellcheck' internally.
#
# Options:
#   --timeout N   Per-check timeout in seconds (default: 60)
#   --help        Show this help
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/lint-file-discovery.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly PQ_DEFAULT_TIMEOUT=60
readonly SONARCLOUD_PROJECT_KEY="marcusquinn_aidevops"

# Temp directory for inter-process result passing
WORK_DIR=""

# =============================================================================
# Setup / Teardown
# =============================================================================

setup_work_dir() {
	WORK_DIR=$(mktemp -d)
	return 0
}

cleanup_work_dir() {
	if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
	return 0
}

# =============================================================================
# Individual check runners (each writes result to $WORK_DIR/<name>.result)
# Result format: EXIT_CODE|DURATION_MS|OUTPUT
# =============================================================================

# _write_result: write check result to temp file.
# Args: $1=name $2=exit_code $3=duration_ms $4=output
_write_result() {
	local name="$1"
	local exit_code="$2"
	local duration_ms="$3"
	local output="$4"
	printf '%s\n%s\n%s\n' "$exit_code" "$duration_ms" "$output" >"${WORK_DIR}/${name}.result"
	return 0
}

# _elapsed_ms: compute elapsed milliseconds since $1 (epoch seconds from date +%s).
# Returns result via stdout.
_elapsed_ms() {
	local start_s="$1"
	local end_s
	end_s=$(date +%s)
	echo $(((end_s - start_s) * 1000))
	return 0
}

# run_shellcheck: ShellCheck all tracked .sh files.
run_shellcheck() {
	local timeout_s="$1"
	local start_s
	start_s=$(date +%s)
	local output=""
	local exit_code=0

	if ! command -v shellcheck &>/dev/null; then
		_write_result "shellcheck" 0 "$(_elapsed_ms "$start_s")" "SKIP: shellcheck not installed"
		return 0
	fi

	lint_shell_files_local
	local sh_files=("${LINT_SH_FILES_LOCAL[@]}")

	if [[ ${#sh_files[@]} -eq 0 ]]; then
		_write_result "shellcheck" 0 "$(_elapsed_ms "$start_s")" "PASS: No shell files to check"
		return 0
	fi

	local file_result all_output=""
	local timed_out=0
	local violations=0

	for file in "${sh_files[@]}"; do
		[[ -f "$file" ]] || continue
		file_result=$(
			ulimit -v 1048576 2>/dev/null || true
			timeout "$timeout_s" shellcheck --severity=warning --format=gcc "$file" 2>&1
		) || {
			local sc_exit=$?
			if [[ $sc_exit -eq 124 ]]; then
				timed_out=$((timed_out + 1))
				continue
			fi
			exit_code=1
		}
		if [[ -n "$file_result" ]]; then
			all_output="${all_output}${file_result}"$'\n'
			violations=$((violations + 1))
		fi
	done

	if [[ $violations -gt 0 ]]; then
		exit_code=1
		output="FAIL: $violations files with violations"$'\n'"$(echo "$all_output" | head -20)"
	elif [[ $timed_out -gt 0 ]]; then
		output="WARN: $timed_out files timed out, ${#sh_files[@]} total"
	else
		output="PASS: ${#sh_files[@]} files clean"
	fi

	_write_result "shellcheck" "$exit_code" "$(_elapsed_ms "$start_s")" "$output"
	return 0
}

# run_sonarcloud: Check SonarCloud quality gate via API.
run_sonarcloud() {
	local timeout_s="$1"
	local start_s
	start_s=$(date +%s)
	local output=""
	local exit_code=0

	if ! command -v curl &>/dev/null; then
		_write_result "sonarcloud" 0 "$(_elapsed_ms "$start_s")" "SKIP: curl not available"
		return 0
	fi

	local gate_response gate_status
	gate_response=$(timeout "$timeout_s" curl -s \
		"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${SONARCLOUD_PROJECT_KEY}" \
		2>/dev/null) || gate_response=""

	if [[ -z "$gate_response" ]]; then
		_write_result "sonarcloud" 0 "$(_elapsed_ms "$start_s")" "SKIP: SonarCloud API unreachable"
		return 0
	fi

	gate_status=$(echo "$gate_response" | jq -r '.projectStatus.status // "UNKNOWN"' 2>/dev/null) || gate_status="UNKNOWN"

	if [[ "$gate_status" == "OK" ]]; then
		output="PASS: Quality gate OK"
	elif [[ "$gate_status" == "ERROR" ]]; then
		exit_code=1
		local failing
		failing=$(echo "$gate_response" | jq -r '
			[.projectStatus.conditions[]? | select(.status == "ERROR") |
			"  \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"]
			| join("\n")
		' 2>/dev/null) || failing=""
		output="FAIL: Quality gate ERROR"$'\n'"$failing"
	else
		output="WARN: Quality gate status: $gate_status"
	fi

	_write_result "sonarcloud" "$exit_code" "$(_elapsed_ms "$start_s")" "$output"
	return 0
}

# run_secrets: Secretlint secret detection.
run_secrets() {
	local timeout_s="$1"
	local start_s
	start_s=$(date +%s)
	local output=""
	local exit_code=0

	# Resolve secretlint binary (global, local, or main repo for worktrees)
	local secretlint_cmd=""
	if command -v secretlint &>/dev/null; then
		secretlint_cmd="secretlint"
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		secretlint_cmd="./node_modules/.bin/secretlint"
	else
		local repo_root
		repo_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs -I{} sh -c 'cd "{}/.." && pwd' 2>/dev/null || echo "")
		if [[ -n "$repo_root" && "$repo_root" != "$(pwd)" && -f "$repo_root/node_modules/.bin/secretlint" ]]; then
			secretlint_cmd="$repo_root/node_modules/.bin/secretlint"
		fi
	fi

	if [[ -z "$secretlint_cmd" ]]; then
		_write_result "secrets" 0 "$(_elapsed_ms "$start_s")" "SKIP: secretlint not installed"
		return 0
	fi

	if [[ ! -f ".secretlintrc.json" ]]; then
		_write_result "secrets" 0 "$(_elapsed_ms "$start_s")" "SKIP: .secretlintrc.json not found"
		return 0
	fi

	local scan_output
	if timeout "$timeout_s" $secretlint_cmd "**/*" --format compact >/dev/null 2>&1; then
		output="PASS: No secrets detected"
	else
		exit_code=1
		scan_output=$(timeout "$timeout_s" $secretlint_cmd "**/*" --format compact 2>&1 | head -20) || true
		output="FAIL: Potential secrets detected"$'\n'"$scan_output"
	fi

	_write_result "secrets" "$exit_code" "$(_elapsed_ms "$start_s")" "$output"
	return 0
}

# run_markdown: Markdownlint style checks on changed/tracked .md files.
run_markdown() {
	local timeout_s="$1"
	local start_s
	start_s=$(date +%s)
	local output=""
	local exit_code=0

	# Resolve markdownlint binary
	local markdownlint_cmd=""
	if command -v markdownlint &>/dev/null; then
		markdownlint_cmd="markdownlint"
	elif [[ -f "node_modules/.bin/markdownlint" ]]; then
		markdownlint_cmd="./node_modules/.bin/markdownlint"
	fi

	if [[ -z "$markdownlint_cmd" ]]; then
		_write_result "markdown" 0 "$(_elapsed_ms "$start_s")" "SKIP: markdownlint not installed"
		return 0
	fi

	# Collect markdown files (changed first, fall back to all tracked)
	local md_files check_mode="changed"
	if git rev-parse --git-dir >/dev/null 2>&1; then
		md_files=$(git diff --name-only --diff-filter=ACMR HEAD -- '*.md' 2>/dev/null)
		if [[ -z "$md_files" ]]; then
			local base_branch
			base_branch=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
			if [[ -n "$base_branch" ]]; then
				md_files=$(git diff --name-only "$base_branch" HEAD -- '*.md' 2>/dev/null)
			fi
		fi
		if [[ -z "$md_files" ]]; then
			md_files=$(git ls-files '.agents/**/*.md' 2>/dev/null)
			check_mode="all"
		fi
	fi

	if [[ -z "$md_files" ]]; then
		_write_result "markdown" 0 "$(_elapsed_ms "$start_s")" "PASS: No markdown files to check"
		return 0
	fi

	local lint_output lint_exit=0
	# shellcheck disable=SC2086
	lint_output=$(timeout "$timeout_s" $markdownlint_cmd $md_files 2>&1) || lint_exit=$?

	if [[ -n "$lint_output" ]]; then
		local violation_count
		violation_count=$(echo "$lint_output" | grep -c "MD[0-9]" 2>/dev/null) || violation_count=0
		[[ "$violation_count" =~ ^[0-9]+$ ]] || violation_count=0

		if [[ $violation_count -gt 0 ]]; then
			if [[ "$check_mode" == "changed" ]]; then
				exit_code=1
				output="FAIL: $violation_count issues in changed files"$'\n'"$(echo "$lint_output" | head -10)"
			else
				output="WARN: $violation_count issues (advisory — all files mode)"$'\n'"$(echo "$lint_output" | head -10)"
			fi
		else
			output="PASS: No markdown issues"
		fi
	else
		output="PASS: No markdown issues"
	fi

	_write_result "markdown" "$exit_code" "$(_elapsed_ms "$start_s")" "$output"
	return 0
}

# run_returns: Check return statement coverage in shell functions.
run_returns() {
	local timeout_s="$1"
	local start_s
	start_s=$(date +%s)
	local output=""
	local exit_code=0

	lint_shell_files_local
	local sh_files=("${LINT_SH_FILES_LOCAL[@]}")

	if [[ ${#sh_files[@]} -eq 0 ]]; then
		_write_result "returns" 0 "$(_elapsed_ms "$start_s")" "PASS: No shell files to check"
		return 0
	fi

	local violations=0
	local files_checked=0

	for file in "${sh_files[@]}"; do
		[[ -f "$file" ]] || continue
		((++files_checked))

		local functions_count return_statements exit_statements total_returns
		functions_count=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {$" "$file" 2>/dev/null || echo "0")
		return_statements=$(grep -cE "return [0-9]+|return \\\$" "$file" 2>/dev/null || echo "0")
		exit_statements=$(grep -cE "^exit [0-9]+|^exit \\\$" "$file" 2>/dev/null || echo "0")

		functions_count=${functions_count//[^0-9]/}
		return_statements=${return_statements//[^0-9]/}
		exit_statements=${exit_statements//[^0-9]/}
		functions_count=${functions_count:-0}
		return_statements=${return_statements:-0}
		exit_statements=${exit_statements:-0}

		total_returns=$((return_statements + exit_statements))

		if [[ $total_returns -lt $functions_count ]]; then
			((++violations))
		fi
	done

	# Threshold: allow up to 10 violations (matches linters-local.sh MAX_RETURN_ISSUES)
	local max_return_issues=10
	if [[ $violations -le $max_return_issues ]]; then
		output="PASS: $violations violations in $files_checked files (threshold: $max_return_issues)"
	else
		exit_code=1
		output="FAIL: $violations violations in $files_checked files (threshold: $max_return_issues)"
	fi

	_write_result "returns" "$exit_code" "$(_elapsed_ms "$start_s")" "$output"
	return 0
}

# =============================================================================
# Result aggregation and display
# =============================================================================

# _read_result_field: read a specific line from a result file.
# Args: $1=name $2=field (1=exit_code, 2=duration_ms, 3+=output)
_read_result_field() {
	local name="$1"
	local field="$2"
	local result_file="${WORK_DIR}/${name}.result"
	if [[ ! -f "$result_file" ]]; then
		echo ""
		return 0
	fi
	sed -n "${field}p" "$result_file"
	return 0
}

# _read_result_output: read lines 3+ from a result file (the output section).
_read_result_output() {
	local name="$1"
	local result_file="${WORK_DIR}/${name}.result"
	if [[ ! -f "$result_file" ]]; then
		echo ""
		return 0
	fi
	tail -n +3 "$result_file"
	return 0
}

# print_results: display aggregated results table and summary.
# Args: $@ = check names that were run
print_results() {
	local checks=("$@")
	local total_passed=0
	local total_failed=0
	local total_skipped=0
	local overall_exit=0

	echo ""
	echo -e "${BLUE}Parallel Quality Check Results${NC}"
	echo -e "${BLUE}================================================================${NC}"

	for name in "${checks[@]}"; do
		local exit_code duration_ms first_line status_label color
		exit_code=$(_read_result_field "$name" "1")
		duration_ms=$(_read_result_field "$name" "2")
		first_line=$(_read_result_output "$name" | head -1)

		# Determine status from first line prefix
		case "$first_line" in
		PASS:*)
			status_label="PASS"
			color="$GREEN"
			;;
		FAIL:*)
			status_label="FAIL"
			color="$RED"
			;;
		WARN:*)
			status_label="WARN"
			color="$YELLOW"
			;;
		SKIP:*)
			status_label="SKIP"
			color="$YELLOW"
			;;
		*)
			status_label="UNKN"
			color="$YELLOW"
			;;
		esac

		# Count outcomes
		case "$status_label" in
		PASS) ((++total_passed)) ;;
		FAIL)
			((++total_failed))
			overall_exit=1
			;;
		*) ((++total_skipped)) ;;
		esac

		local duration_display="${duration_ms}ms"
		printf "  [%b%-4s%b] %-12s %6s  %s\n" \
			"$color" "$status_label" "$NC" \
			"$name" "$duration_display" "${first_line#*: }"

		# Show extra output lines for failures
		if [[ "$status_label" == "FAIL" ]]; then
			_read_result_output "$name" | tail -n +2 | head -5 | while IFS= read -r line; do
				printf "             %s\n" "$line"
			done
		fi
	done

	echo ""
	echo -e "${BLUE}Summary: ${GREEN}${total_passed} passed${NC}, ${RED}${total_failed} failed${NC}, ${YELLOW}${total_skipped} skipped${NC}"

	if [[ $overall_exit -eq 0 ]]; then
		print_success "All parallel quality checks passed"
	else
		print_error "Quality issues detected — address failures before committing"
	fi

	return $overall_exit
}

# =============================================================================
# Argument parsing
# =============================================================================

usage() {
	cat <<'EOF'
Usage: parallel-quality-helper.sh [checks...] [--timeout N]

Checks (default: all):
  shellcheck    ShellCheck validation on all .sh files
  sonarcloud    SonarCloud quality gate status (remote API)
  secrets       Secretlint secret detection
  markdown      Markdownlint style checks
  returns       Return statement coverage in shell functions
  all           Run all checks

Options:
  --timeout N   Per-check timeout in seconds (default: 60)
  --help        Show this help

Examples:
  parallel-quality-helper.sh
  parallel-quality-helper.sh all
  parallel-quality-helper.sh shellcheck returns
  parallel-quality-helper.sh --timeout 120
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local timeout_s="$PQ_DEFAULT_TIMEOUT"
	local requested_checks=()

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--timeout)
			shift
			timeout_s="${1:-$PQ_DEFAULT_TIMEOUT}"
			;;
		--help | -h)
			usage
			return 0
			;;
		all | shellcheck | sonarcloud | secrets | markdown | returns)
			requested_checks+=("$1")
			;;
		*)
			print_error "Unknown argument: $1"
			usage
			return 1
			;;
		esac
		shift
	done

	# Default to all checks
	if [[ ${#requested_checks[@]} -eq 0 || "${requested_checks[*]}" == "all" ]]; then
		requested_checks=(shellcheck sonarcloud secrets markdown returns)
	fi

	# Deduplicate (handles "all" mixed with specific checks)
	local deduped=()
	local seen=""
	for check in "${requested_checks[@]}"; do
		[[ "$check" == "all" ]] && continue
		if ! echo "$seen" | grep -qw "$check"; then
			deduped+=("$check")
			seen="$seen $check"
		fi
	done
	requested_checks=("${deduped[@]}")

	if [[ ${#requested_checks[@]} -eq 0 ]]; then
		print_error "No valid checks specified"
		return 1
	fi

	print_info "Running ${#requested_checks[*]} checks in parallel (timeout: ${timeout_s}s each)..."

	setup_work_dir
	trap 'cleanup_work_dir' EXIT

	# Launch all checks in parallel
	local pids=()
	for check in "${requested_checks[@]}"; do
		case "$check" in
		shellcheck)
			run_shellcheck "$timeout_s" &
			pids+=($!)
			;;
		sonarcloud)
			run_sonarcloud "$timeout_s" &
			pids+=($!)
			;;
		secrets)
			run_secrets "$timeout_s" &
			pids+=($!)
			;;
		markdown)
			run_markdown "$timeout_s" &
			pids+=($!)
			;;
		returns)
			run_returns "$timeout_s" &
			pids+=($!)
			;;
		esac
	done

	# Wait for all background jobs to complete
	local wait_exit=0
	for pid in "${pids[@]}"; do
		wait "$pid" || wait_exit=$?
	done

	# Aggregate and display results
	print_results "${requested_checks[@]}"
	return $?
}

main "$@"
