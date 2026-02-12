#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2086
# =============================================================================
# Local Linters - Fast Offline Quality Checks
# =============================================================================
# Runs local linting tools without requiring external service APIs.
# Use this for pre-commit checks and fast feedback during development.
#
# Checks performed:
#   - shfmt for shell script formatting (pre-pass, non-blocking)
#   - ShellCheck for shell scripts (batch mode for speed)
#   - Secretlint for exposed secrets
#   - Pattern validation (return statements, positional parameters)
#   - Markdown formatting
#
# Environment variables:
#   LINTERS_DIFF_ONLY=true    - Only check modified files (faster for large repos)
#
# Usage:
#   ./linters-local.sh                    # Full check
#   LINTERS_DIFF_ONLY=true ./linters-local.sh  # Check only modified files
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

    for file in .agents/scripts/*.sh; do
        if [[ -f "$file" ]]; then
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
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${tmp_file}'"

    # Only check inside function bodies, exclude heredocs, awk/sed patterns, and comments
    for file in .agents/scripts/*.sh; do
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
            in_func && /\$[1-9]/ && !/local.*=.*\$[1-9]/ {
                print FILENAME ":" NR ": " $0
            }
            ' "$file" >> "$tmp_file"
        fi
    done

    if [[ -s "$tmp_file" ]]; then
        violations=$(wc -l < "$tmp_file")
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

    for file in .agents/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            # Find strings that appear 3 or more times
            local repeated_strings
            repeated_strings=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print $1, $2}' | wc -l)

            if [[ $repeated_strings -gt 0 ]]; then
                ((violations += repeated_strings))
                print_warning "$file has $repeated_strings repeated string literals"
            fi
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
    echo -e "${BLUE}Running shfmt Format Check...${NC}"
    
    local violations=0
    local diff_only="${LINTERS_DIFF_ONLY:-false}"
    local files_to_check=()
    
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        print_warning "shfmt not installed - skipping format check"
        print_info "Install: brew install shfmt"
        return 0
    fi
    
    # Determine which files to check
    if [[ "$diff_only" == "true" ]] && git rev-parse --git-dir > /dev/null 2>&1; then
        # Diff-only mode: check only modified .sh files
        print_info "Diff-only mode: checking modified .sh files"
        
        local changed_files
        changed_files=$(git diff --name-only --diff-filter=ACMR HEAD -- '*.sh' 2>/dev/null || echo "")
        
        if [[ -z "$changed_files" ]]; then
            local base_branch
            base_branch=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
            if [[ -n "$base_branch" ]]; then
                changed_files=$(git diff --name-only "$base_branch" HEAD -- '*.sh' 2>/dev/null || echo "")
            fi
        fi
        
        while IFS= read -r file; do
            [[ -n "$file" ]] && [[ -f "$file" ]] && files_to_check+=("$file")
        done <<< "$changed_files"
        
        if [[ ${#files_to_check[@]} -eq 0 ]]; then
            print_success "shfmt: No modified .sh files to check"
            return 0
        fi
    else
        # Full mode: check all .sh files in .agents/scripts/
        while IFS= read -r file; do
            [[ -f "$file" ]] && files_to_check+=("$file")
        done < <(find .agents/scripts/ -name "*.sh" -type f 2>/dev/null)
    fi
    
    if [[ ${#files_to_check[@]} -eq 0 ]]; then
        print_success "shfmt: No files to check"
        return 0
    fi
    
    print_info "Checking ${#files_to_check[@]} file(s) for formatting..."
    
    # Run shfmt in diff mode to check formatting
    local unformatted_files=()
    for file in "${files_to_check[@]}"; do
        if ! shfmt -d "$file" > /dev/null 2>&1; then
            unformatted_files+=("$file")
        fi
    done
    
    if [[ ${#unformatted_files[@]} -gt 0 ]]; then
        violations=${#unformatted_files[@]}
        print_warning "shfmt: $violations file(s) need formatting"
        for file in "${unformatted_files[@]}"; do
            echo "  - $file"
        done
        print_info "Fix with: shfmt -w ${unformatted_files[*]}"
        # Don't fail on formatting issues, just warn
        return 0
    else
        print_success "shfmt: All files properly formatted"
    fi
    
    return 0
}

run_shellcheck() {
    echo -e "${BLUE}Running ShellCheck Validation...${NC}"

    local violations=0
    local diff_only="${LINTERS_DIFF_ONLY:-false}"
    local files_to_check=()
    
    # Determine which files to check
    if [[ "$diff_only" == "true" ]] && git rev-parse --git-dir > /dev/null 2>&1; then
        # Diff-only mode: check only modified .sh files
        print_info "Diff-only mode: checking modified .sh files"
        
        # Get uncommitted changes (staged + unstaged)
        local changed_files
        changed_files=$(git diff --name-only --diff-filter=ACMR HEAD -- '*.sh' 2>/dev/null || echo "")
        
        # If no uncommitted changes, check branch diff vs main
        if [[ -z "$changed_files" ]]; then
            local base_branch
            base_branch=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
            if [[ -n "$base_branch" ]]; then
                changed_files=$(git diff --name-only "$base_branch" HEAD -- '*.sh' 2>/dev/null || echo "")
            fi
        fi
        
        # Convert to array
        while IFS= read -r file; do
            [[ -n "$file" ]] && [[ -f "$file" ]] && files_to_check+=("$file")
        done <<< "$changed_files"
        
        if [[ ${#files_to_check[@]} -eq 0 ]]; then
            print_success "ShellCheck: No modified .sh files to check"
            return 0
        fi
    else
        # Full mode: check all .sh files in .agents/scripts/
        while IFS= read -r file; do
            [[ -f "$file" ]] && files_to_check+=("$file")
        done < <(find .agents/scripts/ -name "*.sh" -type f 2>/dev/null)
    fi
    
    if [[ ${#files_to_check[@]} -eq 0 ]]; then
        print_success "ShellCheck: No files to check"
        return 0
    fi
    
    print_info "Checking ${#files_to_check[@]} file(s)..."
    
    # Batch shellcheck: pass all files at once for faster execution
    # shellcheck disable=SC2086
    if command -v shellcheck &> /dev/null; then
        local result
        result=$(shellcheck --severity=warning -x "${files_to_check[@]}" 2>&1) || true
        
        if [[ -n "$result" ]]; then
            # Count files with violations
            violations=$(echo "$result" | grep -c "^In " || echo "0")
            print_error "ShellCheck: $violations file(s) with violations"
            echo "$result" | head -20
            if [[ $(echo "$result" | wc -l) -gt 20 ]]; then
                echo "... (output truncated, run shellcheck directly for full results)"
            fi
            return 1
        else
            print_success "ShellCheck: No violations found"
        fi
    else
        print_warning "ShellCheck not installed - skipping"
        print_info "Install: brew install shellcheck"
    fi

    return 0
}

# Check for secrets in codebase
check_secrets() {
    echo -e "${BLUE}Checking for Exposed Secrets (Secretlint)...${NC}"

    local secretlint_script=".agents/scripts/secretlint-helper.sh"
    local violations=0

    # Check if secretlint is available (global, local, or main repo for worktrees)
    local secretlint_cmd=""
    if command -v secretlint &> /dev/null; then
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
    elif command -v docker &> /dev/null; then
        local timeout_sec=60
        # Use gtimeout (macOS) or timeout (Linux) to prevent Docker from hanging
        local timeout_cmd=""
        if command -v gtimeout &> /dev/null; then
            timeout_cmd="gtimeout ${timeout_sec}"
        elif command -v timeout &> /dev/null; then
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
    if command -v markdownlint &> /dev/null; then
        markdownlint_cmd="markdownlint"
    elif [[ -f "node_modules/.bin/markdownlint" ]]; then
        markdownlint_cmd="node_modules/.bin/markdownlint"
    fi

    # Get markdown files to check:
    # 1. Uncommitted changes (staged + unstaged) - BLOCKING
    # 2. If no uncommitted, check files changed in current branch vs main - BLOCKING
    # 3. Fallback to all tracked .md files in .agents/ - NON-BLOCKING (advisory)
    local check_mode="changed"  # "changed" = blocking, "all" = advisory
    if git rev-parse --git-dir > /dev/null 2>&1; then
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
    if git rev-parse --git-dir > /dev/null 2>&1; then
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
    if command -v toon-lsp &> /dev/null; then
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
        done <<< "$toon_files"
    else
        # Fallback: basic structure validation (non-empty check)
        while IFS= read -r file; do
            if [[ -f "$file" ]] && [[ ! -s "$file" ]]; then
                ((violations++))
                print_warning "TOON: Empty file $file"
            fi
        done <<< "$toon_files"
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
        if command -v secretlint &> /dev/null || [[ -f "node_modules/.bin/secretlint" ]]; then
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
        if bash "$coderabbit_script" status > /dev/null 2>&1; then
            print_success "CodeRabbit CLI: Ready"
        else
            print_info "CodeRabbit CLI: Available for setup"
        fi
    fi

    # Codacy CLI
    local codacy_script=".agents/scripts/codacy-cli.sh"
    if [[ -f "$codacy_script" ]]; then
        if bash "$codacy_script" status > /dev/null 2>&1; then
            print_success "Codacy CLI: Ready"
        else
            print_info "Codacy CLI: Available for setup"
        fi
    fi

    # SonarScanner CLI
    local sonar_script=".agents/scripts/sonarscanner-cli.sh"
    if [[ -f "$sonar_script" ]]; then
        if bash "$sonar_script" status > /dev/null 2>&1; then
            print_success "SonarScanner CLI: Ready"
        else
            print_info "SonarScanner CLI: Available for setup"
        fi
    fi

    return 0
}

main() {
    print_header

    local exit_code=0

    # Run all local quality checks
    check_sonarcloud_status || exit_code=1
    echo ""

    check_return_statements || exit_code=1
    echo ""

    check_positional_parameters || exit_code=1
    echo ""

    check_string_literals || exit_code=1
    echo ""

    run_shfmt || exit_code=1
    echo ""

    run_shellcheck || exit_code=1
    echo ""

    check_secrets || exit_code=1
    echo ""

    check_markdown_lint || exit_code=1
    echo ""

    check_toon_syntax || exit_code=1
    echo ""

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
