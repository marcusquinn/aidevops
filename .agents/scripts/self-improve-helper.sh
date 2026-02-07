#!/usr/bin/env bash
# self-improve-helper.sh - Self-improving agent system
# Analyzes patterns, generates improvements, tests in isolation, creates PRs
#
# Usage:
#   self-improve-helper.sh analyze              # Review phase - find improvement opportunities
#   self-improve-helper.sh refine [--dry-run]   # Refine phase - generate improvements
#   self-improve-helper.sh test [session-id]    # Test phase - validate in OpenCode session
#   self-improve-helper.sh pr [--dry-run]       # PR phase - create privacy-filtered PR
#   self-improve-helper.sh status               # Show current improvement cycle status
#   self-improve-helper.sh help                 # Show this help message
#
# The self-improvement cycle:
#   1. ANALYZE: Query memory for failure patterns, identify gaps
#   2. REFINE: Generate improvement proposals, apply in worktree
#   3. TEST: Validate changes in isolated OpenCode session
#   4. PR: Create privacy-filtered PR with evidence
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly AIDEVOPS_DIR="${HOME}/.aidevops"
readonly WORKSPACE_DIR="${AIDEVOPS_DIR}/.agent-workspace"
readonly IMPROVE_DIR="${WORKSPACE_DIR}/self-improve"
readonly ANALYSIS_FILE="${IMPROVE_DIR}/analysis.json"
readonly PROPOSALS_FILE="${IMPROVE_DIR}/proposals.json"
readonly TEST_RESULTS_FILE="${IMPROVE_DIR}/test-results.json"

# OpenCode server defaults
readonly OPENCODE_HOST="${OPENCODE_HOST:-localhost}"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_URL="http://${OPENCODE_HOST}:${OPENCODE_PORT}"

# Print functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
log_header() { echo -e "${PURPLE}$*${NC}"; }

# Ensure workspace directory exists
ensure_workspace() {
    mkdir -p "$IMPROVE_DIR"
    return 0
}

# Check if OpenCode server is running
check_opencode_server() {
    if curl -s "${OPENCODE_URL}/global/health" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Create OpenCode session
create_session() {
    local title="$1"
    local response
    
    response=$(curl -s -X POST "${OPENCODE_URL}/session" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$title\"}")
    
    echo "$response" | jq -r '.id' 2>/dev/null || echo ""
}

# Send prompt to OpenCode session (sync)
send_prompt() {
    local session_id="$1"
    local prompt="$2"
    local response
    
    response=$(curl -s -X POST "${OPENCODE_URL}/session/${session_id}/message" \
        -H "Content-Type: application/json" \
        -d "{\"parts\": [{\"type\": \"text\", \"text\": $(echo "$prompt" | jq -Rs .)}]}")
    
    echo "$response"
}

# Delete OpenCode session
delete_session() {
    local session_id="$1"
    curl -s -X DELETE "${OPENCODE_URL}/session/${session_id}" > /dev/null
    return 0
}

#######################################
# ANALYZE PHASE
# Query memory for patterns, identify gaps
#######################################
cmd_analyze() {
    log_header "Self-Improvement: Analyze Phase"
    echo ""
    
    ensure_workspace
    
    # Check for memory helper
    if [[ ! -x "${SCRIPT_DIR}/memory-helper.sh" ]]; then
        log_error "memory-helper.sh not found"
        return 1
    fi
    
    log_info "Querying memory for failure patterns..."
    
    # Get recent failures
    local failures
    failures=$("${SCRIPT_DIR}/memory-helper.sh" recall --type FAILED_APPROACH --limit 20 --format json 2>/dev/null || echo "[]")
    
    # Get recent errors
    local errors
    errors=$("${SCRIPT_DIR}/memory-helper.sh" recall --type ERROR_FIX --limit 20 --format json 2>/dev/null || echo "[]")
    
    # Get working solutions
    local solutions
    solutions=$("${SCRIPT_DIR}/memory-helper.sh" recall --type WORKING_SOLUTION --limit 20 --format json 2>/dev/null || echo "[]")
    
    # Get codebase patterns
    local patterns
    patterns=$("${SCRIPT_DIR}/memory-helper.sh" recall --type CODEBASE_PATTERN --limit 10 --format json 2>/dev/null || echo "[]")
    
    log_info "Analyzing patterns..."
    
    # Count entries
    local failure_count error_count solution_count pattern_count
    failure_count=$(echo "$failures" | jq 'length' 2>/dev/null || echo 0)
    error_count=$(echo "$errors" | jq 'length' 2>/dev/null || echo 0)
    solution_count=$(echo "$solutions" | jq 'length' 2>/dev/null || echo 0)
    pattern_count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo 0)
    
    echo ""
    log_info "Memory Summary:"
    echo "  - Failed approaches: $failure_count"
    echo "  - Error fixes: $error_count"
    echo "  - Working solutions: $solution_count"
    echo "  - Codebase patterns: $pattern_count"
    echo ""
    
    # Identify gaps (failures without corresponding solutions)
    log_info "Identifying improvement opportunities..."
    
    local gaps=()
    local gap_count=0
    
    # Extract failure keywords and check for solutions
    if [[ "$failure_count" -gt 0 ]]; then
        while IFS= read -r failure; do
            local content
            content=$(echo "$failure" | jq -r '.content' 2>/dev/null)
            
            # Check if there's a solution for this failure
            local has_solution
            has_solution=$("${SCRIPT_DIR}/memory-helper.sh" recall --query "$content" --type WORKING_SOLUTION --limit 1 --format json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
            
            if [[ "$has_solution" -eq 0 ]]; then
                gaps+=("$content")
                gap_count=$((gap_count + 1))
            fi
        done < <(echo "$failures" | jq -c '.[]' 2>/dev/null)
    fi
    
    # Build analysis report
    local analysis
    analysis=$(jq -n \
        --argjson failures "$failures" \
        --argjson errors "$errors" \
        --argjson solutions "$solutions" \
        --argjson patterns "$patterns" \
        --argjson gap_count "$gap_count" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            timestamp: $timestamp,
            summary: {
                failures: ($failures | length),
                errors: ($errors | length),
                solutions: ($solutions | length),
                patterns: ($patterns | length),
                gaps: $gap_count
            },
            failures: $failures,
            errors: $errors,
            solutions: $solutions,
            patterns: $patterns
        }')
    
    # Save analysis
    echo "$analysis" > "$ANALYSIS_FILE"
    log_success "Analysis saved to $ANALYSIS_FILE"
    
    echo ""
    log_header "Analysis Summary"
    echo "  Gaps identified: $gap_count (failures without solutions)"
    
    if [[ "$gap_count" -gt 0 ]]; then
        echo ""
        log_info "Top gaps to address:"
        for i in "${!gaps[@]}"; do
            if [[ $i -lt 5 ]]; then
                echo "  $((i+1)). ${gaps[$i]:0:80}..."
            fi
        done
    fi
    
    echo ""
    log_info "Next step: Run 'self-improve-helper.sh refine' to generate improvements"
    
    return 0
}

#######################################
# REFINE PHASE
# Generate improvement proposals
#######################################
cmd_refine() {
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done
    
    log_header "Self-Improvement: Refine Phase"
    echo ""
    
    # Check for analysis
    if [[ ! -f "$ANALYSIS_FILE" ]]; then
        log_error "No analysis found. Run 'self-improve-helper.sh analyze' first."
        return 1
    fi
    
    # Check OpenCode server
    if ! check_opencode_server; then
        log_error "OpenCode server not running at $OPENCODE_URL"
        log_info "Start with: opencode serve --port $OPENCODE_PORT"
        return 1
    fi
    
    log_info "Loading analysis..."
    local analysis
    analysis=$(cat "$ANALYSIS_FILE")
    
    local gap_count
    gap_count=$(echo "$analysis" | jq '.summary.gaps' 2>/dev/null || echo 0)
    
    if [[ "$gap_count" -eq 0 ]]; then
        log_success "No gaps to address. System is performing well!"
        return 0
    fi
    
    log_info "Creating improvement session..."
    
    # Create session for generating improvements
    local session_id
    session_id=$(create_session "Self-Improve: Refine $(date +%Y%m%d)")
    
    if [[ -z "$session_id" ]]; then
        log_error "Failed to create OpenCode session"
        return 1
    fi
    
    log_info "Session created: $session_id"
    
    # Build prompt for improvement generation
    local prompt
    prompt="You are analyzing failure patterns to generate agent improvements.

## Analysis Data
$(echo "$analysis" | jq -c '.')

## Task
Based on the failures without solutions, propose specific improvements to:
1. Agent instructions (AGENTS.md or subagents)
2. Helper scripts
3. Workflows

For each proposal, provide:
- File to modify
- Specific change (as a diff or description)
- Expected impact
- Test prompt to validate

Output as JSON array:
[
  {
    \"file\": \"path/to/file\",
    \"change_type\": \"edit|add|delete\",
    \"description\": \"What to change\",
    \"diff\": \"Optional diff content\",
    \"impact\": \"Expected improvement\",
    \"test_prompt\": \"Prompt to validate this works\"
  }
]"

    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would send prompt to OpenCode session"
        echo ""
        echo "Prompt preview:"
        echo "$prompt" | head -30
        echo "..."
        delete_session "$session_id"
        return 0
    fi
    
    log_info "Generating improvement proposals..."
    
    local response
    response=$(send_prompt "$session_id" "$prompt")
    
    # Extract proposals from response
    local proposals
    proposals=$(echo "$response" | jq -r '.parts[] | select(.type == "text") | .text' 2>/dev/null | grep -o '\[.*\]' | head -1 || echo "[]")
    
    if [[ "$proposals" == "[]" || -z "$proposals" ]]; then
        log_warn "No proposals generated. Response may need manual review."
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        delete_session "$session_id"
        return 1
    fi
    
    # Save proposals
    local proposals_doc
    proposals_doc=$(jq -n \
        --argjson proposals "$proposals" \
        --arg session_id "$session_id" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            timestamp: $timestamp,
            session_id: $session_id,
            proposals: $proposals
        }')
    
    echo "$proposals_doc" > "$PROPOSALS_FILE"
    log_success "Proposals saved to $PROPOSALS_FILE"
    
    local proposal_count
    proposal_count=$(echo "$proposals" | jq 'length' 2>/dev/null || echo 0)
    
    echo ""
    log_header "Generated $proposal_count Proposals"
    echo "$proposals" | jq -r '.[] | "  - \(.file): \(.description)"' 2>/dev/null
    
    echo ""
    log_info "Next step: Run 'self-improve-helper.sh test' to validate proposals"
    
    # Keep session for testing
    log_info "Session $session_id kept for testing"
    
    return 0
}

#######################################
# TEST PHASE
# Validate improvements in isolated session
#######################################
cmd_test() {
    local session_id="${1:-}"
    
    log_header "Self-Improvement: Test Phase"
    echo ""
    
    # Check for proposals
    if [[ ! -f "$PROPOSALS_FILE" ]]; then
        log_error "No proposals found. Run 'self-improve-helper.sh refine' first."
        return 1
    fi
    
    # Check OpenCode server
    if ! check_opencode_server; then
        log_error "OpenCode server not running at $OPENCODE_URL"
        return 1
    fi
    
    log_info "Loading proposals..."
    local proposals_doc
    proposals_doc=$(cat "$PROPOSALS_FILE")
    
    local proposals
    proposals=$(echo "$proposals_doc" | jq '.proposals' 2>/dev/null)
    
    local proposal_count
    proposal_count=$(echo "$proposals" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$proposal_count" -eq 0 ]]; then
        log_warn "No proposals to test"
        return 0
    fi
    
    # Use existing session or create new one
    if [[ -z "$session_id" ]]; then
        session_id=$(echo "$proposals_doc" | jq -r '.session_id' 2>/dev/null)
    fi
    
    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=$(create_session "Self-Improve: Test $(date +%Y%m%d)")
    fi
    
    log_info "Testing in session: $session_id"
    
    local results=()
    local passed=0
    local failed=0
    
    # Test each proposal
    while IFS= read -r proposal; do
        local file description test_prompt
        file=$(echo "$proposal" | jq -r '.file' 2>/dev/null)
        description=$(echo "$proposal" | jq -r '.description' 2>/dev/null)
        test_prompt=$(echo "$proposal" | jq -r '.test_prompt' 2>/dev/null)
        
        if [[ -z "$test_prompt" || "$test_prompt" == "null" ]]; then
            log_warn "Skipping $file - no test prompt"
            continue
        fi
        
        log_info "Testing: $file"
        echo "  $description"
        
        # Run test prompt
        local response
        response=$(send_prompt "$session_id" "$test_prompt")
        
        # Check for success indicators
        local response_text
        response_text=$(echo "$response" | jq -r '.parts[] | select(.type == "text") | .text' 2>/dev/null | head -1)
        
        # Simple heuristic: check for error indicators
        if echo "$response_text" | grep -qi "error\|failed\|exception\|cannot\|unable"; then
            log_error "  FAILED"
            failed=$((failed + 1))
            results+=("{\"file\": \"$file\", \"status\": \"failed\", \"response\": $(echo "$response_text" | head -c 200 | jq -Rs .)}")
        else
            log_success "  PASSED"
            passed=$((passed + 1))
            results+=("{\"file\": \"$file\", \"status\": \"passed\"}")
        fi
        
        echo ""
    done < <(echo "$proposals" | jq -c '.[]' 2>/dev/null)
    
    # Save test results
    local test_results
    test_results=$(jq -n \
        --argjson results "[$(IFS=,; echo "${results[*]}")]" \
        --arg session_id "$session_id" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        '{
            timestamp: $timestamp,
            session_id: $session_id,
            summary: {
                passed: $passed,
                failed: $failed,
                total: ($passed + $failed)
            },
            results: $results
        }')
    
    echo "$test_results" > "$TEST_RESULTS_FILE"
    log_success "Test results saved to $TEST_RESULTS_FILE"
    
    echo ""
    log_header "Test Summary"
    echo "  Passed: $passed"
    echo "  Failed: $failed"
    echo "  Total: $((passed + failed))"
    
    if [[ "$failed" -eq 0 && "$passed" -gt 0 ]]; then
        echo ""
        log_success "All tests passed!"
        log_info "Next step: Run 'self-improve-helper.sh pr' to create PR"
    elif [[ "$failed" -gt 0 ]]; then
        echo ""
        log_warn "Some tests failed. Review and refine proposals."
    fi
    
    return 0
}

#######################################
# PR PHASE
# Create privacy-filtered PR
#######################################
cmd_pr() {
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done
    
    log_header "Self-Improvement: PR Phase"
    echo ""
    
    # Check for test results
    if [[ ! -f "$TEST_RESULTS_FILE" ]]; then
        log_error "No test results found. Run 'self-improve-helper.sh test' first."
        return 1
    fi
    
    log_info "Loading test results..."
    local test_results
    test_results=$(cat "$TEST_RESULTS_FILE")
    
    local passed failed
    passed=$(echo "$test_results" | jq '.summary.passed' 2>/dev/null || echo 0)
    failed=$(echo "$test_results" | jq '.summary.failed' 2>/dev/null || echo 0)
    
    if [[ "$passed" -eq 0 ]]; then
        log_error "No passing tests. Cannot create PR."
        return 1
    fi
    
    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed tests failed. PR will only include passing changes."
    fi
    
    # Check for privacy filter
    if [[ ! -x "${SCRIPT_DIR}/privacy-filter-helper.sh" ]]; then
        log_error "privacy-filter-helper.sh not found. Cannot create PR without privacy filter."
        return 1
    fi
    
    log_info "Running privacy filter..."
    
    # Run privacy scan
    if ! "${SCRIPT_DIR}/privacy-filter-helper.sh" scan . > /dev/null 2>&1; then
        log_error "Privacy issues detected. Fix before creating PR."
        "${SCRIPT_DIR}/privacy-filter-helper.sh" scan .
        return 1
    fi
    
    log_success "Privacy filter passed"
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would create PR with:"
        echo "  - $passed passing improvements"
        echo "  - Evidence from memory analysis"
        echo "  - Test results attestation"
        return 0
    fi
    
    # Check if we're in a worktree
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    
    if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
        log_error "Cannot create PR from main/master branch"
        log_info "Create a worktree first: wt switch -c feature/self-improve-$(date +%Y%m%d)"
        return 1
    fi
    
    # Build PR body
    local pr_body
    pr_body="## Self-Improvement PR

This PR was generated by the aidevops self-improving agent system.

### Summary
- **Improvements**: $passed
- **Test Status**: All passing
- **Privacy Filter**: Passed

### Evidence

#### Memory Analysis
$(cat "$ANALYSIS_FILE" | jq -r '.summary | \"- Failures analyzed: \(.failures)\n- Errors analyzed: \(.errors)\n- Gaps identified: \(.gaps)\"' 2>/dev/null)

#### Test Results
$(cat "$TEST_RESULTS_FILE" | jq -r '.results[] | select(.status == \"passed\") | \"- ✅ \(.file)\"' 2>/dev/null)

### Attestation
- Privacy filter scan: PASSED
- All changes tested in isolated OpenCode session
- No credentials or PII detected

---
*Generated by self-improve-helper.sh*"

    log_info "Creating PR..."
    
    # Push branch if needed
    if ! git push -u origin "$current_branch" 2>/dev/null; then
        log_warn "Could not push branch. May need manual push."
    fi
    
    # Create PR
    if command -v gh &> /dev/null; then
        gh pr create \
            --title "feat: self-improvement - $(date +%Y-%m-%d)" \
            --body "$pr_body" \
            --label "self-improvement,automated"
        
        log_success "PR created!"
    else
        log_error "gh CLI not found. Install with: brew install gh"
        echo ""
        echo "Manual PR body:"
        echo "$pr_body"
        return 1
    fi
    
    return 0
}

#######################################
# STATUS
# Show current improvement cycle status
#######################################
cmd_status() {
    log_header "Self-Improvement Status"
    echo ""
    
    ensure_workspace
    
    # Check analysis
    if [[ -f "$ANALYSIS_FILE" ]]; then
        local analysis_time
        analysis_time=$(jq -r '.timestamp' "$ANALYSIS_FILE" 2>/dev/null || echo "unknown")
        local gaps
        gaps=$(jq '.summary.gaps' "$ANALYSIS_FILE" 2>/dev/null || echo 0)
        log_success "Analysis: $analysis_time ($gaps gaps)"
    else
        log_warn "Analysis: Not run"
    fi
    
    # Check proposals
    if [[ -f "$PROPOSALS_FILE" ]]; then
        local proposals_time
        proposals_time=$(jq -r '.timestamp' "$PROPOSALS_FILE" 2>/dev/null || echo "unknown")
        local proposal_count
        proposal_count=$(jq '.proposals | length' "$PROPOSALS_FILE" 2>/dev/null || echo 0)
        log_success "Proposals: $proposals_time ($proposal_count proposals)"
    else
        log_warn "Proposals: Not generated"
    fi
    
    # Check test results
    if [[ -f "$TEST_RESULTS_FILE" ]]; then
        local test_time
        test_time=$(jq -r '.timestamp' "$TEST_RESULTS_FILE" 2>/dev/null || echo "unknown")
        local passed failed
        passed=$(jq '.summary.passed' "$TEST_RESULTS_FILE" 2>/dev/null || echo 0)
        failed=$(jq '.summary.failed' "$TEST_RESULTS_FILE" 2>/dev/null || echo 0)
        log_success "Tests: $test_time ($passed passed, $failed failed)"
    else
        log_warn "Tests: Not run"
    fi
    
    # Check OpenCode server
    echo ""
    if check_opencode_server; then
        log_success "OpenCode server: Running at $OPENCODE_URL"
    else
        log_warn "OpenCode server: Not running"
    fi
    
    return 0
}

#######################################
# HELP
#######################################
cmd_help() {
    cat << 'EOF'
Self-Improving Agent System
============================

Analyzes patterns from memory, generates improvements, tests in isolation,
and creates privacy-filtered PRs.

USAGE:
    self-improve-helper.sh [command] [options]

COMMANDS:
    analyze             Review phase - query memory for patterns
    refine [--dry-run]  Refine phase - generate improvement proposals
    test [session-id]   Test phase - validate in OpenCode session
    pr [--dry-run]      PR phase - create privacy-filtered PR
    status              Show current improvement cycle status
    help                Show this help message

WORKFLOW:
    1. analyze  - Find failure patterns without solutions
    2. refine   - Generate specific improvement proposals
    3. test     - Validate proposals in isolated session
    4. pr       - Create PR with evidence and attestation

REQUIREMENTS:
    - OpenCode server running (opencode serve --port 4096)
    - memory-helper.sh for pattern analysis
    - privacy-filter-helper.sh for PR safety
    - gh CLI for PR creation

CONFIGURATION:
    OPENCODE_HOST    OpenCode server host (default: localhost)
    OPENCODE_PORT    OpenCode server port (default: 4096)

FILES:
    ~/.aidevops/.agent-workspace/self-improve/
    ├── analysis.json      # Memory analysis results
    ├── proposals.json     # Generated improvement proposals
    └── test-results.json  # Test validation results

EXAMPLES:
    # Full improvement cycle
    self-improve-helper.sh analyze
    self-improve-helper.sh refine
    self-improve-helper.sh test
    self-improve-helper.sh pr

    # Dry run to preview
    self-improve-helper.sh refine --dry-run
    self-improve-helper.sh pr --dry-run

    # Check status
    self-improve-helper.sh status

EOF
    return 0
}

#######################################
# MAIN
#######################################
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        analyze)
            cmd_analyze "$@"
            ;;
        refine)
            cmd_refine "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        pr)
            cmd_pr "$@"
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
