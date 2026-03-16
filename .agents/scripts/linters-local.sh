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

# Complexity thresholds (aligned with Codacy defaults — GH#4939)
# These catch the same issues Codacy flags so they're caught locally before push.
# Thresholds are set above the current baseline to catch regressions, not existing debt.
# Existing debt is tracked by the code-simplifier (priority 8, human-gated).
#
# Baseline (2026-03-16): 373 functions >100 lines, 222 files >8 nesting, 26 files >1500 lines
# These thresholds allow the current baseline but block significant new additions.
# Reduce thresholds as existing debt is paid down.
#
# - Function length: warn >50, block >100. Threshold allows current 373 + small margin.
# - Nesting depth: warn >5, block >8. Threshold allows current 222 + small margin.
# - File size: warn >800, block >1500. Threshold allows current 26 + small margin.
readonly MAX_FUNCTION_LENGTH_WARN=50
readonly MAX_FUNCTION_LENGTH_BLOCK=100
readonly MAX_FUNCTION_LENGTH_VIOLATIONS=400
readonly MAX_NESTING_DEPTH_WARN=5
readonly MAX_NESTING_DEPTH_BLOCK=8
readonly MAX_NESTING_VIOLATIONS=230
readonly MAX_FILE_LINES_WARN=800
readonly MAX_FILE_LINES_BLOCK=1500
readonly MAX_FILE_SIZE_VIOLATIONS=30

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

	# Check quality gate status first — this drives the badge colour
	local gate_response
	if gate_response=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops"); then
		local gate_status
		gate_status=$(echo "$gate_response" | jq -r '.projectStatus.status // "UNKNOWN"')
		if [[ "$gate_status" == "OK" ]]; then
			print_success "SonarCloud Quality Gate: PASSED (badge is green)"
		elif [[ "$gate_status" == "ERROR" ]]; then
			print_error "SonarCloud Quality Gate: FAILED (badge is red)"
			# Show which conditions are failing
			local failing_conditions
			failing_conditions=$(echo "$gate_response" | jq -r '
				[.projectStatus.conditions[]? | select(.status == "ERROR") |
				"  \(.metricKey): actual=\(.actualValue), required \(.comparator) \(.errorThreshold)"]
				| join("\n")
			') || failing_conditions=""
			if [[ -n "$failing_conditions" ]]; then
				echo "Failing conditions:"
				echo "$failing_conditions"
			fi
		else
			print_warning "SonarCloud Quality Gate: ${gate_status}"
		fi
	fi

	local response
	if response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1&facets=rules"); then
		local total_issues
		total_issues=$(echo "$response" | jq -r '.total // 0')

		echo "Total Issues: $total_issues"

		if [[ $total_issues -le $MAX_TOTAL_ISSUES ]]; then
			print_success "SonarCloud: $total_issues issues (within threshold of $MAX_TOTAL_ISSUES)"
		else
			print_warning "SonarCloud: $total_issues issues (exceeds threshold of $MAX_TOTAL_ISSUES)"
		fi

		# Show top rules by issue count for targeted fixes
		echo "Top rules (fix these for maximum badge improvement):"
		echo "$response" | jq -r '.facets[0].values[:10][] | "  \(.val): \(.count) issues"'
	else
		print_error "Failed to fetch SonarCloud status"
		return 1
	fi

	return 0
}

check_qlty_maintainability() {
	echo -e "${BLUE}Checking Qlty Maintainability...${NC}"

	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ ! -x "$qlty_bin" ]]; then
		print_warning "Qlty CLI not installed (run: curl https://qlty.sh | bash)"
		return 0
	fi

	if [[ ! -f ".qlty/qlty.toml" && ! -f ".qlty.toml" ]]; then
		print_warning "No qlty.toml found (run: qlty init)"
		return 0
	fi

	# Get smell count via SARIF for accuracy
	local sarif_output
	sarif_output=$("$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || sarif_output=""

	if [[ -n "$sarif_output" ]]; then
		local smell_count
		smell_count=$(echo "$sarif_output" | jq '.runs[0].results | length' 2>/dev/null) || smell_count=0
		[[ "$smell_count" =~ ^[0-9]+$ ]] || smell_count=0

		if [[ "$smell_count" -eq 0 ]]; then
			print_success "Qlty: 0 smells (clean)"
		elif [[ "$smell_count" -le 20 ]]; then
			print_success "Qlty: ${smell_count} smells (good)"
		elif [[ "$smell_count" -le 50 ]]; then
			print_warning "Qlty: ${smell_count} smells (needs attention)"
		else
			print_warning "Qlty: ${smell_count} smells (high — impacts maintainability grade)"
		fi

		# Show top rules for targeted fixes
		if [[ "$smell_count" -gt 0 ]]; then
			echo "Top smell types:"
			echo "$sarif_output" | jq -r '
				[.runs[0].results[].ruleId] | group_by(.) |
				map({rule: .[0], count: length}) | sort_by(-.count)[:5][] |
				"  \(.rule): \(.count)"
			' 2>/dev/null

			echo "Top files:"
			echo "$sarif_output" | jq -r '
				[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri] |
				group_by(.) | map({file: .[0], count: length}) | sort_by(-.count)[:5][] |
				"  \(.file): \(.count) smells"
			' 2>/dev/null
		fi
	else
		print_warning "Qlty analysis returned empty"
	fi

	# Check badge grade from Qlty Cloud
	local repo_slug
	repo_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || repo_slug=""
	if [[ -n "$repo_slug" ]]; then
		local badge_svg
		badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
			"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
		if [[ -n "$badge_svg" ]]; then
			local grade
			grade=$(python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null) || grade="UNKNOWN"
			if [[ "$grade" == "A" || "$grade" == "B" ]]; then
				print_success "Qlty Cloud grade: ${grade}"
			elif [[ "$grade" == "C" ]]; then
				print_warning "Qlty Cloud grade: ${grade} (target: A)"
			elif [[ "$grade" == "D" || "$grade" == "F" ]]; then
				print_error "Qlty Cloud grade: ${grade} (needs significant improvement)"
			else
				echo "Qlty Cloud grade: ${grade}"
			fi
		fi
	fi

	return 0
}

check_return_statements() {
	echo -e "${BLUE}Checking Return Statements (S7682)...${NC}"

	local violations=0
	local files_checked=0

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		((++files_checked))

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
			((++violations))
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

	# ShellCheck invocation — no source following.
	#
	# SC1091 is disabled globally in .shellcheckrc. We no longer pass -x
	# (--external-sources) or -P SCRIPTDIR because source-path=SCRIPTDIR
	# combined with -x caused exponential memory expansion (11 GB RSS,
	# kernel panics — GH#2915). Per-file timeout + ulimit remain as
	# defense-in-depth against any future regression.
	local violations=0
	local result=""
	local timed_out=0
	local file_count=${#ALL_SH_FILES[@]}

	# Per-file mode with timeout: prevents any single file from causing
	# exponential expansion. Each file gets max 30s and 1GB virtual memory.
	# timeout_sec (from shared-constants.sh) handles Linux timeout, macOS
	# gtimeout, and bare macOS (background + kill fallback) transparently.
	local sc_timeout=30
	local file_result
	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		file_result=""
		# Run in subshell with ulimit -v to cap virtual memory
		file_result=$(
			ulimit -v 1048576 2>/dev/null || true
			timeout_sec "$sc_timeout" shellcheck --severity=warning --format=gcc "$file" 2>&1
		) || {
			local sc_exit=$?
			# Exit code 124 = timeout killed the process
			if [[ $sc_exit -eq 124 ]]; then
				timed_out=$((timed_out + 1))
				print_warning "ShellCheck: $file timed out after ${sc_timeout}s (likely recursive source expansion)"
				continue
			fi
		}
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
		local sl_timeout=60
		print_info "Secretlint: Using Docker for scan (${sl_timeout}s timeout)..."

		# timeout_sec (from shared-constants.sh) handles macOS + Linux portably
		local docker_result
		docker_result=$(timeout_sec "$sl_timeout" docker run --init -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm secretlint/secretlint secretlint "**/*" --format compact 2>&1) || true

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
		# Run markdownlint and capture output; preserve exit code separately
		local lint_output lint_exit=0
		lint_output=$($markdownlint_cmd $md_files 2>&1) || lint_exit=$?

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
			elif [[ $lint_exit -ne 0 ]]; then
				# markdownlint failed for a non-rule reason (bad config, invalid args, etc.)
				# Output doesn't match MD[0-9] pattern so violation_count=0, but the tool itself errored
				print_error "Markdown: markdownlint failed with exit code $lint_exit (non-rule error)"
				echo "$lint_output"
				if [[ "$check_mode" == "changed" ]]; then
					return 1
				else
					return 0
				fi
			fi
		elif [[ $lint_exit -ne 0 ]]; then
			# markdownlint failed with no output (e.g., config parse error with no stderr)
			print_error "Markdown: markdownlint failed with exit code $lint_exit (no output)"
			if [[ "$check_mode" == "changed" ]]; then
				return 1
			else
				return 0
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
					((++violations))
					print_warning "TOON syntax issue in $file"
				fi
			fi
		done <<<"$toon_files"
	else
		# Fallback: basic structure validation (non-empty check)
		while IFS= read -r file; do
			if [[ -f "$file" ]] && [[ ! -s "$file" ]]; then
				((++violations))
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

# =============================================================================
# Function Complexity Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy flags functions exceeding length thresholds. This local check catches
# the same issues before code reaches Codacy, preventing quality gate failures.
# Aligned with Codacy's ShellCheck + complexity engine.

check_function_complexity() {
	echo -e "${BLUE}Checking Function Complexity (Codacy alignment)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue

		# Use awk to find function boundaries and measure line counts
		awk -v file="$file" -v warn="$MAX_FUNCTION_LENGTH_WARN" -v block="$MAX_FUNCTION_LENGTH_BLOCK" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
				fname = $1
				sub(/\(\)/, "", fname)
				start = NR
				next
			}
			fname && /^[[:space:]]*\}[[:space:]]*$/ {
				lines = NR - start
				if (lines > block) {
					printf "BLOCK %s:%d %s() %d lines (max %d)\n", file, start, fname, lines, block
				} else if (lines > warn) {
					printf "WARN %s:%d %s() %d lines (max %d)\n", file, start, fname, lines, warn
				}
				fname = ""
			}
		' "$file" >>"$tmp_file"
	done

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(grep -c '^BLOCK' "$tmp_file" 2>/dev/null || echo "0")
		warn_violations=$(grep -c '^WARN' "$tmp_file" 2>/dev/null || echo "0")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		if [[ "$block_violations" -gt 0 ]]; then
			print_error "Function complexity: $block_violations functions exceed ${MAX_FUNCTION_LENGTH_BLOCK} lines (must refactor)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
			if [[ "$block_violations" -gt 10 ]]; then
				echo "  ... and $((block_violations - 10)) more"
			fi
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "Function complexity: $warn_violations functions exceed ${MAX_FUNCTION_LENGTH_WARN} lines (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
			if [[ "$warn_violations" -gt 5 ]]; then
				echo "  ... and $((warn_violations - 5)) more"
			fi
		fi
	fi

	if [[ "$block_violations" -le "$MAX_FUNCTION_LENGTH_VIOLATIONS" ]]; then
		local total=$((block_violations + warn_violations))
		print_success "Function complexity: $total oversized functions ($block_violations blocking, $warn_violations advisory)"
		return 0
	fi

	print_error "Function complexity: $block_violations blocking violations (threshold: $MAX_FUNCTION_LENGTH_VIOLATIONS)"
	return 1
}

# =============================================================================
# Nesting Depth Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy flags deeply nested control flow (if/for/while/case). Deep nesting
# indicates functions that should be decomposed. This catches the same pattern
# locally.

check_nesting_depth() {
	echo -e "${BLUE}Checking Nesting Depth (Codacy alignment)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue

		# Track nesting depth through control structures
		# This is a heuristic — not a full parser — but catches the worst offenders
		awk -v file="$file" -v warn="$MAX_NESTING_DEPTH_WARN" -v block="$MAX_NESTING_DEPTH_BLOCK" '
			BEGIN { depth = 0; max_depth = 0; max_line = 0 }
			# Skip comments and strings (rough heuristic)
			/^[[:space:]]*#/ { next }
			# Opening control structures
			/^[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if (depth > max_depth) { max_depth = depth; max_line = NR } }
			# Closing control structures
			/^[[:space:]]*(fi|done|esac)($|[[:space:]])/ { if (depth > 0) depth-- }
			END {
				if (max_depth > block) {
					printf "BLOCK %s:%d max nesting depth %d (max %d)\n", file, max_line, max_depth, block
				} else if (max_depth > warn) {
					printf "WARN %s:%d max nesting depth %d (max %d)\n", file, max_line, max_depth, warn
				}
			}
		' "$file" >>"$tmp_file"
	done

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(grep -c '^BLOCK' "$tmp_file" 2>/dev/null || echo "0")
		warn_violations=$(grep -c '^WARN' "$tmp_file" 2>/dev/null || echo "0")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		if [[ "$block_violations" -gt 0 ]]; then
			print_error "Nesting depth: $block_violations files exceed depth ${MAX_NESTING_DEPTH_BLOCK} (must refactor)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "Nesting depth: $warn_violations files exceed depth ${MAX_NESTING_DEPTH_WARN} (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
		fi
	fi

	if [[ "$block_violations" -le "$MAX_NESTING_VIOLATIONS" ]]; then
		local total=$((block_violations + warn_violations))
		print_success "Nesting depth: $total files with deep nesting ($block_violations blocking, $warn_violations advisory)"
		return 0
	fi

	print_error "Nesting depth: $block_violations blocking violations (threshold: $MAX_NESTING_VIOLATIONS)"
	return 1
}

append_file_size_result() {
	local file="$1"
	local result_file="$2"
	local warn_limit="$3"
	local block_limit="$4"

	[[ -f "$file" ]] || return 0

	local line_count
	line_count=$(wc -l <"$file")
	line_count=${line_count//[^0-9]/}
	line_count=${line_count:-0}

	if [[ "$line_count" -gt "$block_limit" ]]; then
		printf 'BLOCK %s: %d lines (max %d)\n' "$file" "$line_count" "$block_limit" >>"$result_file"
	elif [[ "$line_count" -gt "$warn_limit" ]]; then
		printf 'WARN %s: %d lines (max %d)\n' "$file" "$line_count" "$warn_limit" >>"$result_file"
	fi

	return 0
}

# =============================================================================
# File Size Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy flags files exceeding line count thresholds. Large files are harder
# to maintain and review. This catches monolithic scripts that should be split.

check_file_size() {
	echo -e "${BLUE}Checking File Size (Codacy alignment)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	for file in "${ALL_SH_FILES[@]}"; do
		append_file_size_result "$file" "$tmp_file" "$MAX_FILE_LINES_WARN" "$MAX_FILE_LINES_BLOCK"
	done

	# Also check Python files in the scripts directory
	local py_files=()
	while IFS= read -r -d '' f; do
		py_files+=("$f")
	done < <(find .agents/scripts -name "*.py" -not -path "*/_archive/*" -not -path "*/archived/*" -print0 2>/dev/null | sort -z)

	for file in "${py_files[@]}"; do
		append_file_size_result "$file" "$tmp_file" "$MAX_FILE_LINES_WARN" "$MAX_FILE_LINES_BLOCK"
	done

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(grep -c '^BLOCK' "$tmp_file" 2>/dev/null || echo "0")
		warn_violations=$(grep -c '^WARN' "$tmp_file" 2>/dev/null || echo "0")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		if [[ "$block_violations" -gt 0 ]]; then
			print_error "File size: $block_violations files exceed ${MAX_FILE_LINES_BLOCK} lines (should be split)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "File size: $warn_violations files exceed ${MAX_FILE_LINES_WARN} lines (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
		fi
	fi

	if [[ "$block_violations" -le "$MAX_FILE_SIZE_VIOLATIONS" ]]; then
		local total=$((block_violations + warn_violations))
		print_success "File size: $total oversized files ($block_violations blocking, $warn_violations advisory)"
		return 0
	fi

	print_error "File size: $block_violations blocking violations (threshold: $MAX_FILE_SIZE_VIOLATIONS)"
	return 1
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
			((++errors))
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
			((++errors))
		elif [[ "$fm_name" != "$name" ]]; then
			print_error "Name mismatch in $local_path: got '$fm_name', expected '$name'"
			((++errors))
		fi

		((++checked))
	done <<<"$skill_entries"

	if [[ $errors -eq 0 ]]; then
		print_success "Skill frontmatter: $checked skills validated, all have correct 'name' field"
	else
		print_error "Skill frontmatter: $errors error(s) in $checked skills"
		return 1
	fi

	return 0
}

check_secret_policy() {
	echo -e "${BLUE}Checking Secret Safety Policy...${NC}"

	local policy_script=".agents/scripts/safety-policy-check.sh"
	if [[ ! -x "$policy_script" ]]; then
		print_error "Missing executable policy checker: $policy_script"
		return 1
	fi

	if bash "$policy_script"; then
		print_success "Secret safety policy checks passed"
		return 0
	fi

	print_error "Secret safety policy check failed"
	return 1
}

# =============================================================================
# Bash 3.2 Compatibility Check
# =============================================================================
# macOS ships bash 3.2.57. Bash 4.0+ features silently crash or produce wrong
# results — no error message, just broken behaviour. ShellCheck does NOT catch
# most version incompatibilities, so this is a dedicated scanner.

check_bash32_compat() {
	echo -e "${BLUE}Checking Bash 3.2 Compatibility...${NC}"

	local violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	# Use grep -nE (ERE) — NOT grep -nP (PCRE) — because macOS BSD grep
	# does not support -P. This check itself must be bash 3.2 / macOS compatible.
	# Skip this file (linters-local.sh) — its grep patterns contain the
	# forbidden strings as search targets, not as bash code.
	local self_basename
	self_basename=$(basename "${BASH_SOURCE[0]}")
	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		[[ "$(basename "$file")" == "$self_basename" ]] && continue

		# declare -A / local -A (associative arrays — bash 4.0+)
		grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-A[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
			printf '%s:%s [associative array — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done

		# mapfile / readarray (bash 4.0+)
		grep -nE '^[[:space:]]*(mapfile|readarray)[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
			printf '%s:%s [mapfile/readarray — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done

		# ${var,,} / ${var^^} case conversion (bash 4.0+)
		# Exclude comments — grep -n prefixes "NNN:" so comments appear as "NNN:\s*#"
		grep -n ',,}' "$file" 2>/dev/null | grep '\${' | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
			printf '%s:%s [case conversion ,,} — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done
		grep -n '^^}' "$file" 2>/dev/null | grep '\${' | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
			printf '%s:%s [case conversion ^^} — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done

		# declare -n / local -n namerefs (bash 4.3+)
		grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-n[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
			printf '%s:%s [nameref — bash 4.3+]\n' "$file" "$line" >>"$tmp_file"
		done

		# coproc (bash 4.0+)
		grep -nE '^[[:space:]]*coproc[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
			printf '%s:%s [coproc — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done

		# &>> append-both (bash 4.0+)
		grep -n '&>>' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
			printf '%s:%s [&>> append — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
		done

		# "\t" or "\n" in string concatenation (likely wants $'\t' or $'\n')
		# Only flag += or = assignments, not awk/sed/printf/echo -e/python contexts
		grep -nE '\+="\\[tn]|="\\[tn]' "$file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' |
			grep -vE 'awk|sed|printf|echo.*-e|python|f\.write|gsub|join|split|print |replace|coords|excerpt|delimiter|regex|pattern' |
			while IFS= read -r line; do
				printf '%s:%s ["\t"/"\n" — use $'"'"'\\t'"'"' or $'"'"'\\n'"'"' for actual whitespace]\n' "$file" "$line" >>"$tmp_file"
			done
	done

	if [[ -s "$tmp_file" ]]; then
		violations=$(wc -l <"$tmp_file")
		violations=${violations//[^0-9]/}
		violations=${violations:-0}

		if [[ "$violations" -gt 0 ]]; then
			print_error "Bash 3.2 compatibility: $violations violations (macOS default bash)"
			head -20 "$tmp_file"
			if [[ "$violations" -gt 20 ]]; then
				echo "... and $((violations - 20)) more"
			fi
			rm -f "$tmp_file"
			return 1
		fi
	fi

	rm -f "$tmp_file"
	print_success "Bash 3.2 compatibility: no violations"

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

	if ! should_skip_gate "qlty"; then
		check_qlty_maintainability || exit_code=1
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

	if ! should_skip_gate "secret-policy"; then
		check_secret_policy || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "bash32-compat"; then
		check_bash32_compat || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "function-complexity"; then
		check_function_complexity || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "nesting-depth"; then
		check_nesting_depth || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "file-size"; then
		check_file_size || exit_code=1
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
