#!/usr/bin/env bash
# security-helper.sh - AI-powered security vulnerability analysis
# Supports: code analysis, dependency scanning, git history, AI CLI configs
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/mcp-env.sh" ]] && source "${HOME}/.config/aidevops/mcp-env.sh"

# Script directory (exported for subprocesses)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
readonly SCRIPT_DIR
readonly OUTPUT_DIR=".security-analysis"
readonly VERSION="1.0.0"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           Security Analysis Helper v${VERSION}               ║"
    echo "║   AI-powered vulnerability detection for code & configs   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
  status                    Check installation status of security tools
  analyze [scope]           Analyze code for vulnerabilities
                            Scopes: diff (default), staged, branch, full
  history [commits|range]   Scan git history for vulnerabilities
  scan-deps [path]          Scan dependencies for known vulnerabilities (OSV)
  ferret [path]             Scan AI CLI configurations (Ferret)
  report [format]           Generate comprehensive security report
                            Formats: text (default), json, sarif
  install [tool]            Install security tools
  help                      Show this help message

Examples:
  $(basename "$0") analyze                    # Analyze git diff
  $(basename "$0") analyze full               # Full codebase scan
  $(basename "$0") history 50                 # Scan last 50 commits
  $(basename "$0") scan-deps                  # Scan dependencies
  $(basename "$0") ferret                     # Scan AI CLI configs
  $(basename "$0") report --format=sarif      # Generate SARIF report
EOF
}

check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

print_status() {
    local name="$1"
    local installed="$2"
    local version="${3:-}"
    
    if [[ "$installed" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} ${name} ${version:+($version)}"
    else
        echo -e "  ${RED}✗${NC} ${name} (not installed)"
    fi
}

cmd_status() {
    print_header
    echo -e "${BLUE}Security Tools Status:${NC}"
    echo ""
    
    # OSV-Scanner
    if check_command osv-scanner; then
        local osv_version
        osv_version=$(osv-scanner --version 2>/dev/null | head -1 || echo "unknown")
        print_status "OSV-Scanner" "true" "$osv_version"
    else
        print_status "OSV-Scanner" "false"
    fi
    
    # Ferret
    if check_command ferret; then
        local ferret_version
        ferret_version=$(ferret --version 2>/dev/null | head -1 || echo "unknown")
        print_status "Ferret" "true" "$ferret_version"
    elif check_command npx && npx ferret-scan --version &>/dev/null 2>&1; then
        print_status "Ferret (via npx)" "true"
    else
        print_status "Ferret" "false"
    fi
    
    # Secretlint
    if check_command secretlint; then
        local secretlint_version
        secretlint_version=$(secretlint --version 2>/dev/null || echo "unknown")
        print_status "Secretlint" "true" "$secretlint_version"
    elif check_command npx && npx secretlint --version &>/dev/null 2>&1; then
        print_status "Secretlint (via npx)" "true"
    else
        print_status "Secretlint" "false"
    fi
    
    # Snyk (optional)
    if check_command snyk; then
        local snyk_version
        snyk_version=$(snyk --version 2>/dev/null || echo "unknown")
        print_status "Snyk (optional)" "true" "$snyk_version"
    else
        print_status "Snyk (optional)" "false"
    fi
    
    # Git
    if check_command git; then
        local git_version
        git_version=$(git --version 2>/dev/null | awk '{print $3}')
        print_status "Git" "true" "$git_version"
    else
        print_status "Git" "false"
    fi
    
    echo ""
    echo -e "${BLUE}Output Directory:${NC} ${OUTPUT_DIR}"
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        echo -e "  ${GREEN}✓${NC} Directory exists"
        local report_count
        report_count=$(find "$OUTPUT_DIR" -name "*.md" -o -name "*.json" -o -name "*.sarif" 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  Reports: ${report_count}"
    else
        echo -e "  ${YELLOW}○${NC} Directory will be created on first scan"
    fi
    
    return 0
}

ensure_output_dir() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        echo -e "${GREEN}Created output directory: ${OUTPUT_DIR}${NC}"
    fi
}

cmd_analyze() {
    local scope="${1:-diff}"
    shift || true
    
    print_header
    ensure_output_dir
    
    # Guard: ensure we're in a git repository
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo -e "${RED}Not inside a git repository.${NC}"
        echo "Run this command from within a git repository."
        return 1
    fi
    
    echo -e "${BLUE}Security Analysis - Scope: ${scope}${NC}"
    echo ""
    
    local files_to_scan=""
    local scan_description=""
    
    case "$scope" in
        diff)
            scan_description="Uncommitted changes (git diff)"
            if git rev-parse --verify origin/HEAD &>/dev/null; then
                files_to_scan=$(git diff --merge-base origin/HEAD --name-only 2>/dev/null || git diff --name-only)
            else
                files_to_scan=$(git diff --name-only)
            fi
            ;;
        staged)
            scan_description="Staged changes"
            files_to_scan=$(git diff --cached --name-only)
            ;;
        branch)
            scan_description="All changes on current branch"
            local base_branch
            base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
            files_to_scan=$(git diff --name-only "${base_branch}"...HEAD 2>/dev/null || git diff --name-only main...HEAD 2>/dev/null || git diff --name-only)
            ;;
        full)
            scan_description="Full codebase"
            files_to_scan=$(git ls-files 2>/dev/null || find . -type f -not -path '*/\.*' -not -path '*/node_modules/*')
            ;;
        *)
            echo -e "${RED}Unknown scope: ${scope}${NC}"
            echo "Valid scopes: diff, staged, branch, full"
            return 1
            ;;
    esac
    
    local file_count
    file_count=$(echo "$files_to_scan" | grep -c . || echo "0")
    
    echo -e "Scan: ${scan_description}"
    echo -e "Files: ${file_count}"
    echo ""
    
    if [[ "$file_count" -eq 0 ]]; then
        echo -e "${YELLOW}No files to scan.${NC}"
        return 0
    fi
    
    # Run secretlint if available
    echo -e "${CYAN}Running secret detection...${NC}"
    if check_command secretlint || (check_command npx && npx secretlint --version &>/dev/null 2>&1); then
        local secretlint_cmd="secretlint"
        if ! check_command secretlint; then
            secretlint_cmd="npx secretlint"
        fi
        
        # Use xargs -I {} to handle filenames with spaces correctly
        # shellcheck disable=SC2086
        echo "$files_to_scan" | grep . | xargs -I {} $secretlint_cmd "{}" 2>/dev/null || true
    else
        echo -e "${YELLOW}Secretlint not available. Install with: npm install -g secretlint${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}Analysis complete.${NC}"
    echo -e "For AI-powered deep analysis, use the security-analysis subagent."
    
    return 0
}

cmd_history() {
    local commits="${1:-50}"
    shift || true
    
    print_header
    ensure_output_dir
    
    echo -e "${BLUE}Git History Security Scan${NC}"
    echo ""
    
    # Parse commits argument
    local git_log_args=""
    if [[ "$commits" =~ ^[0-9]+$ ]]; then
        git_log_args="-n $commits"
        echo -e "Scanning last ${commits} commits..."
    elif [[ "$commits" =~ \.\. ]]; then
        git_log_args="$commits"
        echo -e "Scanning commit range: ${commits}..."
    elif [[ "$commits" == --* ]]; then
        git_log_args="$commits $*"
        echo -e "Scanning with options: ${git_log_args}..."
    else
        git_log_args="-n 50"
        echo -e "Scanning last 50 commits (default)..."
    fi
    
    echo ""
    
    # Get commits
    local commit_list
    # shellcheck disable=SC2086
    commit_list=$(git log $git_log_args --format="%H" 2>/dev/null || echo "")
    
    if [[ -z "$commit_list" ]]; then
        echo -e "${YELLOW}No commits found.${NC}"
        return 0
    fi
    
    local commit_count
    commit_count=$(echo "$commit_list" | wc -l | tr -d ' ')
    echo -e "Found ${commit_count} commits to analyze."
    echo ""
    
    # Analyze each commit for potential security issues
    local issues_found=0
    local current=0
    
    while IFS= read -r commit; do
        current=$((current + 1))
        local short_hash="${commit:0:8}"
        local commit_msg
        commit_msg=$(git log -1 --format="%s" "$commit" 2>/dev/null | head -c 50)
        
        printf "\r[%d/%d] Analyzing %s..." "$current" "$commit_count" "$short_hash"
        
        # Get diff for this commit
        local diff_content
        diff_content=$(git show "$commit" --format="" 2>/dev/null || echo "")
        
        # Quick pattern matching for common security issues (word boundaries to reduce false positives)
        if echo "$diff_content" | grep -qiE '\b(password|secret|api[_-]?key|token|credential)s?\b' 2>/dev/null; then
            issues_found=$((issues_found + 1))
            echo ""
            echo -e "${YELLOW}[POTENTIAL] ${short_hash}: ${commit_msg}${NC}"
            echo -e "  May contain sensitive data patterns"
        fi
        
    done <<< "$commit_list"
    
    echo ""
    echo ""
    echo -e "${GREEN}History scan complete.${NC}"
    echo -e "Commits analyzed: ${commit_count}"
    echo -e "Potential issues: ${issues_found}"
    echo ""
    echo -e "For deep analysis of specific commits, use:"
    echo -e "  security-helper.sh history <commit>^..<commit>"
    
    return 0
}

cmd_scan_deps() {
    local path="${1:-.}"
    shift || true
    
    print_header
    ensure_output_dir
    
    echo -e "${BLUE}Dependency Vulnerability Scan${NC}"
    echo -e "Path: ${path}"
    echo ""
    
    if ! check_command osv-scanner; then
        echo -e "${YELLOW}OSV-Scanner not installed.${NC}"
        echo ""
        echo "Install with:"
        echo "  go install github.com/google/osv-scanner/cmd/osv-scanner@latest"
        echo "  # or"
        echo "  brew install osv-scanner"
        echo ""
        return 1
    fi
    
    echo -e "${CYAN}Running OSV-Scanner...${NC}"
    echo ""
    
    # Run OSV-Scanner
    # Exit codes: 0=clean, 1=vulnerabilities found, 127=general error, 128=no packages, 129+=other errors
    osv-scanner --recursive "$path" "$@" || {
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            echo ""
            echo -e "${RED}Vulnerabilities found!${NC}"
            return 1
        fi
        # Propagate actual errors (not just vulnerability findings)
        echo ""
        echo -e "${RED}OSV-Scanner failed with exit code ${exit_code}.${NC}"
        return "$exit_code"
    }
    
    echo ""
    echo -e "${GREEN}No vulnerabilities found.${NC}"
    return 0
}

cmd_ferret() {
    local path="${1:-.}"
    shift || true
    
    print_header
    ensure_output_dir
    
    echo -e "${BLUE}AI CLI Configuration Security Scan (Ferret)${NC}"
    echo -e "Path: ${path}"
    echo ""
    
    local ferret_cmd=""
    
    if check_command ferret; then
        ferret_cmd="ferret"
    elif check_command npx; then
        ferret_cmd="npx ferret-scan"
    else
        echo -e "${YELLOW}Ferret not installed.${NC}"
        echo ""
        echo "Install with:"
        echo "  npm install -g ferret-scan"
        echo "  # or run directly"
        echo "  npx ferret-scan scan ."
        echo ""
        return 1
    fi
    
    echo -e "${CYAN}Running Ferret security scan...${NC}"
    echo ""
    
    # Run Ferret
    $ferret_cmd scan "$path" "$@" || {
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            echo ""
            echo -e "${RED}Security issues found in AI CLI configurations!${NC}"
            return 1
        fi
    }
    
    return 0
}

cmd_report() {
    local format="text"
    
    # Parse --format flag or positional argument
    if [[ "${1:-}" == --format=* ]]; then
        format="${1#--format=}"
        shift || true
    elif [[ "${1:-}" == "--format" ]]; then
        format="${2:-text}"
        shift 2 || true
    elif [[ -n "${1:-}" && "${1:-}" != -* ]]; then
        format="$1"
        shift || true
    fi
    
    print_header
    ensure_output_dir
    
    echo -e "${BLUE}Generating Security Report${NC}"
    echo -e "Format: ${format}"
    echo ""
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local report_file="${OUTPUT_DIR}/SECURITY_REPORT"
    
    case "$format" in
        text|md|markdown)
            report_file="${report_file}.md"
            {
                echo "# Security Analysis Report"
                echo ""
                echo "**Generated**: ${timestamp}"
                echo "**Directory**: $(pwd)"
                echo ""
                echo "## Summary"
                echo ""
                echo "Run individual scans to populate this report:"
                echo ""
                echo "- \`security-helper.sh analyze\` - Code analysis"
                echo "- \`security-helper.sh scan-deps\` - Dependency scan"
                echo "- \`security-helper.sh ferret\` - AI CLI config scan"
                echo "- \`security-helper.sh history\` - Git history scan"
                echo ""
            } > "$report_file"
            ;;
        json)
            report_file="${report_file}.json"
            {
                echo "{"
                echo "  \"generated\": \"${timestamp}\","
                echo "  \"directory\": \"$(pwd)\","
                echo "  \"findings\": [],"
                echo "  \"summary\": {"
                echo "    \"critical\": 0,"
                echo "    \"high\": 0,"
                echo "    \"medium\": 0,"
                echo "    \"low\": 0"
                echo "  }"
                echo "}"
            } > "$report_file"
            ;;
        sarif)
            report_file="${report_file}.sarif"
            {
                echo "{"
                echo "  \"\$schema\": \"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json\","
                echo "  \"version\": \"2.1.0\","
                echo "  \"runs\": [{"
                echo "    \"tool\": {"
                echo "      \"driver\": {"
                echo "        \"name\": \"security-helper\","
                echo "        \"version\": \"${VERSION}\""
                echo "      }"
                echo "    },"
                echo "    \"results\": []"
                echo "  }]"
                echo "}"
            } > "$report_file"
            ;;
        *)
            echo -e "${RED}Unknown format: ${format}${NC}"
            echo "Valid formats: text, json, sarif"
            return 1
            ;;
    esac
    
    echo -e "${GREEN}Report generated: ${report_file}${NC}"
    return 0
}

cmd_install() {
    local tool="${1:-all}"
    
    print_header
    echo -e "${BLUE}Installing Security Tools${NC}"
    echo ""
    
    case "$tool" in
        osv|osv-scanner)
            echo "Installing OSV-Scanner..."
            if check_command brew; then
                brew install osv-scanner
            elif check_command go; then
                go install github.com/google/osv-scanner/cmd/osv-scanner@latest
            else
                echo -e "${RED}Please install via Homebrew or Go${NC}"
                return 1
            fi
            ;;
        ferret|ferret-scan)
            echo "Installing Ferret..."
            npm install -g ferret-scan
            ;;
        secretlint)
            echo "Installing Secretlint..."
            npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
            ;;
        all)
            echo "Installing all security tools..."
            echo ""
            
            # OSV-Scanner
            if ! check_command osv-scanner; then
                echo -e "${CYAN}Installing OSV-Scanner...${NC}"
                if check_command brew; then
                    brew install osv-scanner || true
                elif check_command go; then
                    go install github.com/google/osv-scanner/cmd/osv-scanner@latest || true
                fi
            fi
            
            # Ferret
            if ! check_command ferret; then
                echo -e "${CYAN}Installing Ferret...${NC}"
                npm install -g ferret-scan || true
            fi
            
            # Secretlint
            if ! check_command secretlint; then
                echo -e "${CYAN}Installing Secretlint...${NC}"
                npm install -g secretlint @secretlint/secretlint-rule-preset-recommend || true
            fi
            
            echo ""
            echo -e "${GREEN}Installation complete.${NC}"
            cmd_status
            ;;
        *)
            echo -e "${RED}Unknown tool: ${tool}${NC}"
            echo "Valid tools: osv-scanner, ferret, secretlint, all"
            return 1
            ;;
    esac
    
    return 0
}

# Main entry point
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        status)
            cmd_status "$@"
            ;;
        analyze)
            cmd_analyze "$@"
            ;;
        history)
            cmd_history "$@"
            ;;
        scan-deps|deps)
            cmd_scan_deps "$@"
            ;;
        ferret|ai-config)
            cmd_ferret "$@"
            ;;
        report)
            cmd_report "$@"
            ;;
        install)
            cmd_install "$@"
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            echo -e "${RED}Unknown command: ${command}${NC}"
            echo ""
            print_usage
            return 1
            ;;
    esac
}

main "$@"
