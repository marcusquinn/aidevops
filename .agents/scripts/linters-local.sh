#!/usr/bin/env bash
# shellcheck disable=SC2086
# =============================================================================
# Local Linters - Fast Offline Quality Checks
# =============================================================================
# Runs local linting tools without requiring external service APIs.
# Use this for pre-commit checks and fast feedback during development.
#
# Checks performed:
#   - ShellCheck for shell scripts
#   - Secretlint for exposed secrets
#   - Pattern validation (return statements, positional parameters)
#   - Markdown formatting
#   - Skill frontmatter validation (name field matches skill-sources.json)
#
# For remote auditing (CodeRabbit, Codacy, SonarCloud), use:
#   /code-audit-remote or code-audit-helper.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Color codes for output

# Quality thresholds
# Note: These thresholds are set to allow existing code patterns while catching regressions
# - Return issues: Simple utility functions (log_*, print_*) don't need explicit returns
# - Positional params: Using $1/$2 in case statements and argument parsing is valid
#   SonarCloud S7679 reports ~200 issues; local check is more aggressive (~280)
#   Threshold set to catch regressions while allowing existing patterns
# - String literals: Code duplication is a style issue, not a bug
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=10
readonly MAX_POSITIONAL_ISSUES=300
readonly MAX_STRING_LITERAL_ISSUES=2300

print_header() {
	echo -e "${BLUE}Local Linters - Fast Offline Quality Checks${NC}"
	echo -e "${BLUE}================================================================${NC}"
	return 0
}

# Collect all shell scripts to lint, including modularised subdirectories
# (e.g. memory/, supervisor-modules/, setup/) but excluding archived code.
# Excludes: _archive/, archived/, supervisor-archived/ — these are versioned
# for reference but not actively maintained (reduces lint noise).
# Also includes setup-modules/ and setup.sh from the repo root.
# Populates the ALL_SH_FILES array for use by check functions.
collect_shell_files() {
	ALL_SH_FILES=()
	while IFS= read -r -d '' f; do
		ALL_SH_FILES+=("$f")
	done < <(find .agents/scripts -name "*.sh" -not -path "*/_archive/*" -not -path "*/archived/*" -not -path "*/supervisor-archived/*" -print0 2>/dev/null | sort -z)

	# Include setup-modules/ (extracted setup.sh modules) if present
	while IFS= read -r -d '' f; do
		ALL_SH_FILES+=("$f")
	done < <(find setup-modules -name "*.sh" -print0 2>/dev/null | sort -z)

	# Include setup.sh entry point itself
	if [[ -f "setup.sh" ]]; then
		ALL_SH_FILES+=("setup.sh")
	fi
	return 0
}

check_sonarcloud_status() {
	echo -e "${BLUE}Checking SonarCloud Status (remote API)...${NC}"

	local response
	if response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1"); then
		local total_issues
		total_issues=$(echo "$response" | jq -r '.total // 0')

		echo "Total Issues: $total_issues"

		if [[ $total_issues -le $MAX_TOTAL_ISSUES ]]; then
			print_success "SonarCloud: $total_issues issues (within threshold of $MAX_TOTAL_ISSUES)"
		else
			print_warning "SonarCloud: $total_issues issues (exceeds threshold of $MAX_TOTAL_ISSUES)"
		fi

		# Get detailed breakdown
		local breakdown_response
		if breakdown_response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=10&facets=rules"); then
			echo "Issue Breakdown:"
			echo "$breakdown_response" | jq -r '.facets[0].values[] | "  \(.val): \(.count) issues"'
		fi
	else
		print_error "Failed to fetch SonarCloud status"
		return 1
	fi

	return 0
}

check_return_statements() {
	echo -e "${BLUE}Checking Return Statements (S7682)...${NC}"

	local violations=0
	local files_checked=0

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		((files_checked++))

		# Count multi-line functions (exclude one-liners like: func() { echo "x"; })
		# One-liners don't need explicit return statements
		local functions_count
		functions_count=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {$" "$file" 2>/dev/null || echo "0")

		# Count all return patterns: return 0, return 1, return $var, return $((expr))
		local return_statements
		return_statements=$(grep -cE "return [0-9]+|return \\\$" "$file" 2>/dev/null || echo "0")

		# Also count exit statements at script level (exit 0, exit $?)
		local exit_statements
		exit_statements=$(grep -cE "^exit [0-9]+|^exit \\\$" "$file" 2>/dev/null || echo "0")

		# Ensure variables are numeric
		functions_count=${functions_count//[^0-9]/}
		return_statements=${return_statements//[^0-9]/}
		exit_statements=${exit_statements//[^0-9]/}
		functions_count=${functions_count:-0}
		return_statements=${return_statements:-0}
		exit_statements=${exit_statements:-0}

		# Total returns = return statements + exit statements (for main)
		local total_returns=$((return_statements + exit_statements))

		if [[ $total_returns -lt $functions_count ]]; then
			((violations++))
			print_warning "Missing return statements in $file"
		fi
	done

	echo "Files checked: $files_checked"
	echo "Files with violations: $violations"

	if [[ $violations -le $MAX_RETURN_ISSUES ]]; then
		print_success "Return statements: $violations violations (within threshold)"
	else
		print_error "Return statements: $violations violations (exceeds threshold of $MAX_RETURN_ISSUES)"
		return 1
	fi

	return 0
}

check_positional_parameters() {
	echo -e "${BLUE}Checking Positional Parameters (S7679)...${NC}"

	local violations=0

	# Find direct usage of positional parameters inside functions (not in local assignments)
	# Exclude: heredocs (<<), awk scripts, main script body, and local assignments
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	# Only check inside function bodies, exclude heredocs, awk/sed patterns, and comments
	for file in "${ALL_SH_FILES[@]}"; do
		if [[ -f "$file" ]]; then
			# Use awk to find $1-$9 usage inside functions, excluding:
			# - local assignments (local var="$1")
			# - heredocs (<<EOF ... EOF)
			# - awk/sed scripts (contain $1, $2 for field references)
			# - comments (lines starting with #)
			# - echo/print statements showing usage examples
			awk '
            /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { in_func=1; next }
            in_func && /^\}$/ { in_func=0; next }
            /<<.*EOF/ || /<<.*"EOF"/ || /<<-.*EOF/ { in_heredoc=1; next }
            in_heredoc && /^EOF/ { in_heredoc=0; next }
            in_heredoc { next }
            # Track multi-line awk scripts (awk ... single-quote opens, closes on later line)
            /awk[[:space:]]+\047[^\047]*$/ { in_awk=1; next }
            in_awk && /\047/ { in_awk=0; next }
            in_awk { next }
            # Skip single-line awk/sed scripts (they use $1, $2 for fields)
            /awk.*\047.*\047/ { next }
            /awk.*".*"/ { next }
            /sed.*\047/ || /sed.*"/ { next }
            # Skip comments and usage examples
            /^[[:space:]]*#/ { next }
            /echo.*\$[1-9]/ { next }
            /print.*\$[1-9]/ { next }
            /Usage:/ { next }
            # Skip currency/pricing patterns: $[1-9] followed by digit, decimal, comma,
            # slash (e.g. $28/mo, $1.99, $1,000), pipe (markdown table), or common
            # currency/pricing unit words (per, mo, month, flat, etc.).
            /\$[1-9][0-9.,\/]/ { next }
            /\$[1-9][[:space:]]*\|/ { next }
            /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)[[:space:][:punct:]]/ { next }
            /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)$/ { next }
            in_func && /\$[1-9]/ && !/local.*=.*\$[1-9]/ {
                print FILENAME ":" NR ": " $0
            }
            ' "$file" >>"$tmp_file"
		fi
	done

	if [[ -s "$tmp_file" ]]; then
		violations=$(wc -l <"$tmp_file")
		violations=${violations//[^0-9]/}
		violations=${violations:-0}

		if [[ $violations -gt 0 ]]; then
			print_warning "Found $violations positional parameter violations:"
			head -10 "$tmp_file"
			if [[ $violations -gt 10 ]]; then
				echo "... and $((violations - 10)) more"
			fi
		fi
	fi

	rm -f "$tmp_file"

	if [[ $violations -le $MAX_POSITIONAL_ISSUES ]]; then
		print_success "Positional parameters: $violations violations (within threshold)"
	else
		print_error "Positional parameters: $violations violations (exceeds threshold of $MAX_POSITIONAL_ISSUES)"
		return 1
	fi

	return 0
}

check_string_literals() {
	echo -e "${BLUE}Checking String Literals (S1192)...${NC}"

	local violations=0

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		# Find strings that appear 3 or more times
		local repeated_strings
		repeated_strings=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print $1, $2}' | wc -l)

		if [[ $repeated_strings -gt 0 ]]; then
			((violations += repeated_strings))
			print_warning "$file has $repeated_strings repeated string literals"
		fi
	done

	if [[ $violations -le $MAX_STRING_LITERAL_ISSUES ]]; then
		print_success "String literals: $violations violations (within threshold)"
	else
		print_error "String literals: $violations violations (exceeds threshold of $MAX_STRING_LITERAL_ISSUES)"
		return 1
	fi

	return 0
}

run_shfmt() {
	echo -e "${BLUE}Running shfmt Syntax Check (fast pre-pass)...${NC}"

	if ! command -v shfmt &>/dev/null; then
		print_warning "shfmt not installed (install: brew install shfmt)"
		return 0
	fi

	local violations=0
	local files_checked=0

	files_checked=${#ALL_SH_FILES[@]}

	if [[ $files_checked -eq 0 ]]; then
		print_success "shfmt: No shell files to check"
		return 0
	fi

	# Batch check: shfmt -l lists files that differ from formatted output (syntax errors)
	local result
	result=$(shfmt -l "${ALL_SH_FILES[@]}" 2>&1) || true
	if [[ -n "$result" ]]; then
		violations=$(echo "$result" | wc -l | tr -d ' ')
	fi

	if [[ $violations -eq 0 ]]; then
		print_success "shfmt: $files_checked files passed syntax check"
	else
		print_warning "shfmt: $violations files have formatting differences (advisory)"
		echo "$result" | head -5
		if [[ $violations -gt 5 ]]; then
			echo "... and $((violations - 5)) more"
		fi
		print_info "Auto-fix: find .agents/scripts -name '*.sh' -not -path '*/_archive/*' -exec shfmt -w {} +"
	fi

	# shfmt is advisory, not blocking
	return 0
}

run_shellcheck() {
	echo -e "${BLUE}Running ShellCheck Validation...${NC}"

	if ! command -v shellcheck &>/dev/null; then
		print_warning "shellcheck not installed (install: brew install shellcheck)"
		return 0
	fi

	if [[ ${#ALL_SH_FILES[@]} -eq 0 ]]; then
		print_success "ShellCheck: No shell files to check"
		return 0
	fi

	# t1398.2: Hardened ShellCheck invocation to prevent exponential expansion.
	#
	# Root cause: shellcheck --external-sources (-x) with source-path=SCRIPTDIR
	# follows source directives across 100+ scripts, causing exponential
	# expansion (5.7 GB RSS, 88% CPU, 35+ min observed — March 3 kernel panic).
	#
	# Hardening layers (defense in depth):
	#   1. Per-file mode with timeout (30s) to cap each invocation
	#   2. ulimit -v (1 GB) to cap virtual memory per shellcheck subprocess
	#   3. -P SCRIPTDIR restricts source resolution to the script's own directory
	#      (prevents cross-directory recursive expansion chains)
	#   4. .shellcheckrc source-path=SCRIPTDIR is intentionally kept for
	#      interactive use — the per-file timeout + ulimit prevent runaway
	#
	# Trade-off: linters-local.sh keeps -x for better source resolution
	# (unlike pulse-wrapper.sh which uses --norc). This is acceptable because
	# linters-local.sh is interactive with per-file timeout + ulimit guards.
	local violations=0
	local result=""
	local timed_out=0
	local file_count=${#ALL_SH_FILES[@]}

	# Determine timeout command (gtimeout on macOS, timeout on Linux)
	local timeout_cmd=""
	if command -v timeout &>/dev/null; then
		timeout_cmd="timeout"
	elif command -v gtimeout &>/dev/null; then
		timeout_cmd="gtimeout"
	fi

	# Per-file mode with timeout: prevents any single file from causing
	# exponential expansion. Each file gets max 30s and 1GB virtual memory.
	local sc_timeout=30
	local file_result
	# t1404: warn once when no timeout utility is available (degraded protection)
	if [[ -z "$timeout_cmd" ]]; then
		print_warning "ShellCheck: no timeout/gtimeout utility found; using portable fallback (less reliable process cleanup)"
	fi
	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		file_result=""
		if [[ -n "$timeout_cmd" ]]; then
			# t1398.2: run in subshell with ulimit -v to cap virtual memory
			file_result=$(
				ulimit -v 1048576 2>/dev/null || true
				$timeout_cmd "${sc_timeout}s" shellcheck -x -P SCRIPTDIR --severity=warning --format=gcc "$file" 2>&1
			) || {
				local sc_exit=$?
				# Exit code 124 = timeout killed the process
				if [[ $sc_exit -eq 124 ]]; then
					timed_out=$((timed_out + 1))
					print_warning "ShellCheck: $file timed out after ${sc_timeout}s (likely recursive source expansion)"
					continue
				fi
			}
		else
			# Portable timeout wrapper: no timeout/gtimeout available.
			# Run ShellCheck in background with a sleep-based watcher that kills it
			# after sc_timeout seconds. Drop -x to reduce recursive expansion risk.
			local sc_tmpfile
			sc_tmpfile=$(mktemp) || {
				file_result=""
				continue
			}
			# t1398.2: no -x in fallback path (no timeout utility = higher risk)
			# t1404: use process group kill to clean up ShellCheck child processes
			(
				ulimit -v 1048576 2>/dev/null || true
				shellcheck -P SCRIPTDIR --severity=warning --format=gcc "$file"
			) >"$sc_tmpfile" 2>&1 &
			local sc_bg_pid=$!
			# Watcher: kill the process group (- prefix) to catch child processes,
			# falling back to single-process kill if group kill fails (e.g., not a
			# process group leader on some shells).
			(sleep "$sc_timeout" && kill -- -"$sc_bg_pid" 2>/dev/null || kill "$sc_bg_pid" 2>/dev/null) &
			local sc_watcher_pid=$!
			local sc_exit_code=0
			wait "$sc_bg_pid" 2>/dev/null || sc_exit_code=$?
			# Clean up watcher (may already be done if ShellCheck finished before timeout)
			kill "$sc_watcher_pid" 2>/dev/null || true
			wait "$sc_watcher_pid" 2>/dev/null || true
			file_result=$(cat "$sc_tmpfile")
			rm -f "$sc_tmpfile"
			# Exit codes >128 indicate signal kill (timeout fired)
			if [[ $sc_exit_code -gt 128 ]]; then
				timed_out=$((timed_out + 1))
				print_warning "ShellCheck: $file killed after ${sc_timeout}s (portable fallback)"
				file_result=""
				continue
			fi
		fi
		if [[ -n "$file_result" ]]; then
			result="${result}${file_result}
"
		fi
	done

	if [[ -n "$result" ]]; then
		# Count unique files with violations (grep -c avoids SC2126)
		violations=$(echo "$result" | grep -v '^$' | cut -d: -f1 | sort -u | grep -c . || true)
		local issue_count
		issue_count=$(echo "$result" | grep -vc '^$' || true)

		print_error "ShellCheck: $violations files with $issue_count issues"
		# Show first few issues
		echo "$result" | grep -v '^$' | head -10
		if [[ $issue_count -gt 10 ]]; then
			echo "... and $((issue_count - 10)) more"
		fi
		if [[ $timed_out -gt 0 ]]; then
			print_warning "ShellCheck: $timed_out file(s) timed out (recursive source expansion)"
		fi
		return 1
	fi

	local msg="ShellCheck: ${file_count} files passed (no warnings)"
	if [[ $timed_out -gt 0 ]]; then
		msg="ShellCheck: $((file_count - timed_out)) of ${file_count} files passed, $timed_out timed out"
	fi
	print_success "$msg"
	return 0
}

# Check for secrets in codebase
check_secrets() {
	echo -e "${BLUE}Checking for Exposed Secrets (Secretlint)...${NC}"

	local secretlint_script=".agents/scripts/secretlint-helper.sh"
	local violations=0

	# Check if secretlint is available (global, local, or main repo for worktrees)
	local secretlint_cmd=""
	if command -v secretlint &>/dev/null; then
		secretlint_cmd="secretlint"
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		secretlint_cmd="./node_modules/.bin/secretlint"
	else
		# Check main repo node_modules (handles git worktrees)
		local repo_root
		repo_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs -I{} sh -c 'cd "{}/.." && pwd' 2>/dev/null || echo "")
		if [[ -n "$repo_root" ]] && [[ "$repo_root" != "$(pwd)" ]] && [[ -f "$repo_root/node_modules/.bin/secretlint" ]]; then
			secretlint_cmd="$repo_root/node_modules/.bin/secretlint"
		fi
	fi

	if [[ -n "$secretlint_cmd" ]]; then

		if [[ -f ".secretlintrc.json" ]]; then
			# Run scan and capture exit code
			if $secretlint_cmd "**/*" --format compact 2>/dev/null; then
				print_success "Secretlint: No secrets detected"
			else
				violations=1
				print_error "Secretlint: Potential secrets detected!"
				print_info "Run: bash $secretlint_script scan (for detailed results)"
			fi
		else
			print_warning "Secretlint: Configuration not found"
			print_info "Run: bash $secretlint_script init"
		fi
	elif command -v docker &>/dev/null; then
		local timeout_sec=60
		# Use gtimeout (macOS) or timeout (Linux) to prevent Docker from hanging
		local timeout_cmd=""
		if command -v gtimeout &>/dev/null; then
			timeout_cmd="gtimeout ${timeout_sec}"
		elif command -v timeout &>/dev/null; then
			timeout_cmd="timeout ${timeout_sec}"
		fi

		if [[ -n "$timeout_cmd" ]]; then
			print_info "Secretlint: Using Docker for scan (${timeout_sec}s timeout)..."
		else
			print_info "Secretlint: Using Docker for scan (no timeout available)..."
		fi

		local docker_result
		if [[ -n "$timeout_cmd" ]]; then
			docker_result=$($timeout_cmd docker run --init -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm secretlint/secretlint secretlint "**/*" --format compact 2>&1) || true
		else
			# No timeout available, run without (may hang on large repos)
			docker_result=$(docker run --init -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm secretlint/secretlint secretlint "**/*" --format compact 2>&1) || true
		fi

		if [[ -z "$docker_result" ]] || [[ "$docker_result" == *"0 problems"* ]]; then
			print_success "Secretlint: No secrets detected"
		elif [[ "$docker_result" == *"timed out"* ]] || [[ "$docker_result" == *"timeout"* ]]; then
			print_warning "Secretlint: Timed out (skipped)"
			print_info "Install native secretlint for faster scans: npm install -g secretlint"
		else
			violations=1
			print_error "Secretlint: Potential secrets detected!"
		fi
	else
		print_warning "Secretlint: Not installed (install with: npm install secretlint)"
		print_info "Run: bash $secretlint_script install"
	fi

	return $violations
}

# Check AI-Powered Quality CLIs integration
check_markdown_lint() {
	print_info "Checking Markdown Style..."

	local md_files
	local violations=0
	local markdownlint_cmd=""

	# Find markdownlint command
	if command -v markdownlint &>/dev/null; then
		markdownlint_cmd="markdownlint"
	elif [[ -f "node_modules/.bin/markdownlint" ]]; then
		markdownlint_cmd="node_modules/.bin/markdownlint"
	fi

	# Get markdown files to check:
	# 1. Uncommitted changes (staged + unstaged) - BLOCKING
	# 2. If no uncommitted, check files changed in current branch vs main - BLOCKING
	# 3. Fallback to all tracked .md files in .agents/ - NON-BLOCKING (advisory)
	local check_mode="changed" # "changed" = blocking, "all" = advisory
	if git rev-parse --git-dir >/dev/null 2>&1; then
		# First try uncommitted changes
		md_files=$(git diff --name-only --diff-filter=ACMR HEAD -- '*.md' 2>/dev/null)

		# If no uncommitted, check branch diff vs main
		if [[ -z "$md_files" ]]; then
			local base_branch
			base_branch=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
			if [[ -n "$base_branch" ]]; then
				md_files=$(git diff --name-only "$base_branch" HEAD -- '*.md' 2>/dev/null)
			fi
		fi

		# Fallback: check all .agents/*.md files (advisory only)
		if [[ -z "$md_files" ]]; then
			md_files=$(git ls-files '.agents/**/*.md' 2>/dev/null)
			check_mode="all"
		fi
	else
		md_files=$(find . -name "*.md" -type f 2>/dev/null | grep -v node_modules)
		check_mode="all"
	fi

	if [[ -z "$md_files" ]]; then
		print_success "Markdown: No markdown files to check"
		return 0
	fi

	if [[ -n "$markdownlint_cmd" ]]; then
		# Run markdownlint and capture output
		local lint_output
		lint_output=$($markdownlint_cmd $md_files 2>&1) || true

		if [[ -n "$lint_output" ]]; then
			# Count violations - ensure single integer (grep -c can fail, use wc -l as fallback)
			local violation_count
			violation_count=$(echo "$lint_output" | grep -c "MD[0-9]" 2>/dev/null) || violation_count=0
			# Ensure it's a valid integer
			if ! [[ "$violation_count" =~ ^[0-9]+$ ]]; then
				violation_count=0
			fi
			violations=$violation_count

			if [[ $violations -gt 0 ]]; then
				# Show violations first (common to both modes)
				echo "$lint_output" | head -10
				if [[ $violations -gt 10 ]]; then
					echo "... and $((violations - 10)) more"
				fi
				print_info "Run: markdownlint --fix <file> to auto-fix"

				# Mode-specific message and return code
				if [[ "$check_mode" == "changed" ]]; then
					print_error "Markdown: $violations style issues in changed files (BLOCKING)"
					return 1
				else
					print_warning "Markdown: $violations style issues found (advisory)"
					return 0
				fi
			fi
		fi
		print_success "Markdown: No style issues found"
	else
		# Fallback: basic checks without markdownlint
		# NOTE: Without markdownlint, we can't reliably detect MD031/MD040 violations
		# because we can't distinguish opening fences (need language) from closing fences (always bare)
		# So fallback is always advisory-only and recommends installing markdownlint
		print_warning "Markdown: markdownlint not installed - cannot perform full lint checks"
		print_info "Install: npm install -g markdownlint-cli"
		print_info "Then re-run to get blocking checks for changed files"
		# Advisory only - don't block without proper tooling
		return 0
	fi

	return 0
}

# Check TOON file syntax
check_toon_syntax() {
	print_info "Checking TOON Syntax..."

	local toon_files
	local violations=0

	# Find .toon files in the repo
	if git rev-parse --git-dir >/dev/null 2>&1; then
		toon_files=$(git ls-files '*.toon' 2>/dev/null)
	else
		toon_files=$(find . -name "*.toon" -type f 2>/dev/null | grep -v node_modules)
	fi

	if [[ -z "$toon_files" ]]; then
		print_success "TOON: No .toon files to check"
		return 0
	fi

	local file_count
	file_count=$(echo "$toon_files" | wc -l | tr -d ' ')

	# Use toon-lsp check if available, otherwise basic validation
	if command -v toon-lsp &>/dev/null; then
		while IFS= read -r file; do
			if [[ -f "$file" ]]; then
				local result
				result=$(toon-lsp check "$file" 2>&1)
				local exit_code=$?
				if [[ $exit_code -ne 0 ]] || [[ "$result" == *"error"* ]]; then
					((violations++))
					print_warning "TOON syntax issue in $file"
				fi
			fi
		done <<<"$toon_files"
	else
		# Fallback: basic structure validation (non-empty check)
		while IFS= read -r file; do
			if [[ -f "$file" ]] && [[ ! -s "$file" ]]; then
				((violations++))
				print_warning "TOON: Empty file $file"
			fi
		done <<<"$toon_files"
	fi

	if [[ $violations -eq 0 ]]; then
		print_success "TOON: All $file_count files valid"
	else
		print_warning "TOON: $violations of $file_count files with issues"
	fi

	return 0
}

check_remote_cli_status() {
	print_info "Remote Audit CLIs Status (use /code-audit-remote for full analysis)..."

	# Secretlint
	local secretlint_script=".agents/scripts/secretlint-helper.sh"
	if [[ -f "$secretlint_script" ]]; then
		# Check global, local, and main repo node_modules (worktree support)
		local sl_found=false
		if command -v secretlint &>/dev/null || [[ -f "node_modules/.bin/secretlint" ]]; then
			sl_found=true
		else
			local sl_repo_root
			sl_repo_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs -I{} sh -c 'cd "{}/.." && pwd' 2>/dev/null || echo "")
			if [[ -n "$sl_repo_root" ]] && [[ "$sl_repo_root" != "$(pwd)" ]] && [[ -f "$sl_repo_root/node_modules/.bin/secretlint" ]]; then
				sl_found=true
			fi
		fi
		if [[ "$sl_found" == "true" ]]; then
			print_success "Secretlint: Ready"
		else
			print_info "Secretlint: Available for setup"
		fi
	fi

	# CodeRabbit CLI
	local coderabbit_script=".agents/scripts/coderabbit-cli.sh"
	if [[ -f "$coderabbit_script" ]]; then
		if bash "$coderabbit_script" status >/dev/null 2>&1; then
			print_success "CodeRabbit CLI: Ready"
		else
			print_info "CodeRabbit CLI: Available for setup"
		fi
	fi

	# Codacy CLI
	local codacy_script=".agents/scripts/codacy-cli.sh"
	if [[ -f "$codacy_script" ]]; then
		if bash "$codacy_script" status >/dev/null 2>&1; then
			print_success "Codacy CLI: Ready"
		else
			print_info "Codacy CLI: Available for setup"
		fi
	fi

	# SonarScanner CLI
	local sonar_script=".agents/scripts/sonarscanner-cli.sh"
	if [[ -f "$sonar_script" ]]; then
		if bash "$sonar_script" status >/dev/null 2>&1; then
			print_success "SonarScanner CLI: Ready"
		else
			print_info "SonarScanner CLI: Available for setup"
		fi
	fi

	return 0
}

# =============================================================================
# Skill Frontmatter Validation
# =============================================================================
# Validates that all imported skills registered in skill-sources.json have a
# 'name' field in their YAML frontmatter matching the registered skill name.
# This prevents opencode startup errors from missing name fields.

check_skill_frontmatter() {
	echo -e "${BLUE}Checking Skill Frontmatter...${NC}"

	local skill_sources=".agents/configs/skill-sources.json"

	if [[ ! -f "$skill_sources" ]]; then
		print_info "No skill-sources.json found (skipping)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_info "jq not available (skipping skill frontmatter check)"
		return 0
	fi

	local skill_count
	if ! skill_count=$(jq -er '
		if (.skills | type) == "array" then (.skills | length)
		else error(".skills must be an array")
		end
	' "$skill_sources" 2>/dev/null); then
		print_error "Invalid $skill_sources (cannot parse .skills array)"
		return 1
	fi

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to validate"
		return 0
	fi

	local errors=0
	local checked=0

	local skill_entries
	if ! skill_entries=$(jq -er '.skills[] | "\(.name)|\(.local_path)"' "$skill_sources" 2>/dev/null); then
		print_error "Failed to read skill entries from $skill_sources"
		return 1
	fi

	while IFS='|' read -r name local_path; do
		if [[ ! -f "$local_path" ]]; then
			print_warning "Skill file missing: $local_path (skill: $name)"
			((errors++)) || true
			continue
		fi

		# Extract name from YAML frontmatter (initial block only)
		local fm_name
		fm_name=$(awk '
			NR == 1 && /^---$/ { in_fm = 1; next }
			in_fm && /^---$/ { exit }
			in_fm && /^[[:space:]]*name:[[:space:]]*/ {
				sub(/^[[:space:]]*name:[[:space:]]*/, "")
				sub(/[[:space:]]+#.*$/, "")
				gsub(/^["'"'"']|["'"'"']$/, "")
				print
				exit
			}
		' "$local_path")

		if [[ -z "$fm_name" ]]; then
			print_error "Missing 'name' field in frontmatter: $local_path (expected: $name)"
			((errors++)) || true
		elif [[ "$fm_name" != "$name" ]]; then
			print_error "Name mismatch in $local_path: got '$fm_name', expected '$name'"
			((errors++)) || true
		fi

		((checked++)) || true
	done <<<"$skill_entries"

	if [[ $errors -eq 0 ]]; then
		print_success "Skill frontmatter: $checked skills validated, all have correct 'name' field"
	else
		print_error "Skill frontmatter: $errors error(s) in $checked skills"
		return 1
	fi

	return 0
}

# =============================================================================
# Bundle-Aware Gate Filtering (t1364.6)
# =============================================================================
# Resolves the project bundle and checks whether a gate should be skipped.
# Bundle skip_gates override: if a bundle says skip a gate, it's skipped.
# BUNDLE_SKIP_GATES is populated once in main() and checked per gate.

BUNDLE_SKIP_GATES=""

# Load bundle skip_gates for the current project directory.
# Populates BUNDLE_SKIP_GATES (newline-separated gate names).
# Returns: 0 always (bundle is optional — missing bundle is not an error)
load_bundle_gates() {
	local bundle_helper="${SCRIPT_DIR}/bundle-helper.sh"
	if [[ ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local bundle_json
	bundle_json=$("$bundle_helper" resolve "." 2>/dev/null) || true
	if [[ -z "$bundle_json" ]]; then
		return 0
	fi

	BUNDLE_SKIP_GATES=$(echo "$bundle_json" | jq -r '.skip_gates[]? // empty' 2>/dev/null) || true

	local bundle_name
	bundle_name=$(echo "$bundle_json" | jq -r '.name // "unknown"' 2>/dev/null) || true
	if [[ -n "$BUNDLE_SKIP_GATES" ]]; then
		local skip_count
		skip_count=$(echo "$BUNDLE_SKIP_GATES" | wc -l | tr -d ' ')
		print_info "Bundle '${bundle_name}': skipping ${skip_count} gates"
	else
		print_info "Bundle '${bundle_name}': no gates skipped"
	fi
	return 0
}

# Check if a gate should be skipped based on bundle config.
# Arguments:
#   $1 - gate name (e.g., "shellcheck", "return-statements")
# Returns: 0 if gate should be SKIPPED, 1 if gate should RUN
should_skip_gate() {
	local gate_name="$1"
	if [[ -z "$BUNDLE_SKIP_GATES" ]]; then
		return 1
	fi
	if echo "$BUNDLE_SKIP_GATES" | grep -qxF "$gate_name"; then
		print_info "Skipping '${gate_name}' (bundle skip_gates)"
		return 0
	fi
	return 1
}

main() {
	print_header

	local exit_code=0

	# Collect shell files once (includes modularised subdirectories, excludes _archive/)
	collect_shell_files

	# Load bundle config for gate filtering (t1364.6)
	load_bundle_gates

	# Run all local quality checks (respecting bundle skip_gates)
	if ! should_skip_gate "sonarcloud"; then
		check_sonarcloud_status || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "return-statements"; then
		check_return_statements || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "positional-parameters"; then
		check_positional_parameters || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "string-literals"; then
		check_string_literals || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shfmt"; then
		run_shfmt
		echo ""
	fi

	if ! should_skip_gate "shellcheck"; then
		run_shellcheck || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "secretlint"; then
		check_secrets || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "markdownlint"; then
		check_markdown_lint || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "toon-syntax"; then
		check_toon_syntax || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "skill-frontmatter"; then
		check_skill_frontmatter || exit_code=1
		echo ""
	fi

	check_remote_cli_status
	echo ""

	# Final summary
	if [[ $exit_code -eq 0 ]]; then
		print_success "ALL LOCAL CHECKS PASSED!"
		print_info "For remote auditing, run: /code-audit-remote"
	else
		print_error "QUALITY ISSUES DETECTED. Please address violations before committing."
	fi

	return $exit_code
}

main "$@"
