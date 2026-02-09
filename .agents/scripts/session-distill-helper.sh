#!/usr/bin/env bash
# =============================================================================
# Session Distill Helper - Extract learnings from session for memory storage
# =============================================================================
# Analyzes session context and extracts valuable learnings to store in memory.
# Integrates with /session-review and memory-helper.sh.
#
# Usage:
#   session-distill-helper.sh analyze           # Analyze current session context
#   session-distill-helper.sh extract           # Extract and format learnings
#   session-distill-helper.sh store             # Store extracted learnings to memory
#   session-distill-helper.sh auto              # Full pipeline: analyze → extract → store
#
# Integration:
#   - Called by /session-review at end of sessions
#   - Uses memory-helper.sh for storage
#   - Reads git history, TODO.md changes, and session patterns
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly MEMORY_HELPER="$SCRIPT_DIR/memory-helper.sh"
readonly WORKSPACE_DIR="${AIDEVOPS_WORKSPACE:-$HOME/.aidevops/.agent-workspace}"
readonly SESSION_DIR="$WORKSPACE_DIR/sessions"
# shellcheck disable=SC2034  # Reserved for future use
readonly DISTILL_OUTPUT="$SESSION_DIR/distill-output.json"

# shellcheck disable=SC2034  # Available for future use

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# Ensure session directory exists
#######################################
init_session_dir() {
    mkdir -p "$SESSION_DIR"
}

#######################################
# Analyze current session context
# Gathers data from git, TODO.md, and recent activity
#######################################
analyze_session() {
    init_session_dir
    
    log_info "Analyzing session context..."
    
    local analysis_file="$SESSION_DIR/session-analysis.json"
    
    # Gather git context
    local branch commits_today files_changed
    branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    commits_today=$(git log --oneline --since="midnight" 2>/dev/null | wc -l | tr -d ' ')
    files_changed=$(git diff --name-only HEAD~5 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    
    # Get recent commit messages for pattern extraction
    local recent_commits
    recent_commits=$(git log --oneline -10 --format="%s" 2>/dev/null | head -10 || echo "")
    
    # Check for error patterns in recent commits
    local error_fixes
    error_fixes=$(echo "$recent_commits" | grep -ci "fix\|error\|bug\|issue" || echo "0")
    
    # Check TODO.md for completed tasks
    local completed_tasks
    if [[ -f "TODO.md" ]]; then
        completed_tasks=$(grep -c "^\- \[x\]" TODO.md 2>/dev/null || echo "0")
    else
        completed_tasks="0"
    fi
    
    # Build analysis JSON safely using jq to prevent JSON injection
    jq -n \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg branch "$branch" \
        --argjson commits_today "$commits_today" \
        --argjson files_changed "$files_changed" \
        --argjson error_fixes "$error_fixes" \
        --argjson completed_tasks "$completed_tasks" \
        --arg recent_commits "$recent_commits" \
        '{
            timestamp: $timestamp,
            branch: $branch,
            commits_today: $commits_today,
            files_changed: $files_changed,
            error_fixes: $error_fixes,
            completed_tasks: $completed_tasks,
            recent_commits: ($recent_commits | split("\n") | map(select(length > 0)))
        }' > "$analysis_file"
    
    log_success "Session analysis saved to $analysis_file"
    cat "$analysis_file"
    return 0
}

#######################################
# Extract learnings from session
# Identifies patterns worth remembering
#######################################
extract_learnings() {
    init_session_dir
    
    log_info "Extracting learnings from session..."
    
    local analysis_file="$SESSION_DIR/session-analysis.json"
    local learnings_file="$SESSION_DIR/extracted-learnings.json"
    
    if [[ ! -f "$analysis_file" ]]; then
        log_warn "No session analysis found. Running analyze first..."
        analyze_session
    fi
    
    # Read analysis
    local branch commits_today error_fixes
    branch=$(jq -r '.branch' "$analysis_file" 2>/dev/null || echo "unknown")
    commits_today=$(jq -r '.commits_today' "$analysis_file" 2>/dev/null || echo "0")
    error_fixes=$(jq -r '.error_fixes' "$analysis_file" 2>/dev/null || echo "0")
    
    # Extract learnings based on patterns
    local learnings=()
    
    # Pattern 1: Error fixes → WORKING_SOLUTION or ERROR_FIX
    if [[ "$error_fixes" -gt 0 ]]; then
        # Get the fix commit messages
        local fix_commits
        fix_commits=$(git log --oneline -10 --format="%s" 2>/dev/null | grep -i "fix\|error\|bug" | head -3 || echo "")
        
        if [[ -n "$fix_commits" ]]; then
            while IFS= read -r commit_msg; do
                if [[ -n "$commit_msg" ]]; then
                    # Use jq to safely build JSON and prevent injection
                    local learning_json
                    learning_json=$(jq -n --arg type "ERROR_FIX" --arg content "$commit_msg" --arg tags "session,auto-distill,$branch" \
                        '{type: $type, content: $content, tags: $tags}')
                    learnings+=("$learning_json")
                fi
            done <<< "$fix_commits"
        fi
    fi
    
    # Pattern 2: Feature branch completion → WORKING_SOLUTION
    if [[ "$branch" == feature/* ]] && [[ "$commits_today" -gt 2 ]]; then
        local feature_name="${branch#feature/}"
        local learning_json
        learning_json=$(jq -n --arg type "WORKING_SOLUTION" --arg content "Implemented feature: $feature_name" --arg tags "session,feature,$feature_name" \
            '{type: $type, content: $content, tags: $tags}')
        learnings+=("$learning_json")
    fi
    
    # Pattern 3: Refactor patterns → CODEBASE_PATTERN
    local refactor_commits
    refactor_commits=$(git log --oneline -10 --format="%s" 2>/dev/null | grep -i "refactor\|restructure\|reorganize" | head -2 || echo "")
    if [[ -n "$refactor_commits" ]]; then
        while IFS= read -r commit_msg; do
            if [[ -n "$commit_msg" ]]; then
                local learning_json
                learning_json=$(jq -n --arg type "CODEBASE_PATTERN" --arg content "$commit_msg" --arg tags "session,refactor,$branch" \
                    '{type: $type, content: $content, tags: $tags}')
                learnings+=("$learning_json")
            fi
        done <<< "$refactor_commits"
    fi
    
    # Pattern 4: Documentation updates → CONTEXT
    local doc_commits
    doc_commits=$(git log --oneline -10 --format="%s" 2>/dev/null | grep -i "doc\|readme\|comment" | head -2 || echo "")
    if [[ -n "$doc_commits" ]]; then
        while IFS= read -r commit_msg; do
            if [[ -n "$commit_msg" ]]; then
                local learning_json
                learning_json=$(jq -n --arg type "CONTEXT" --arg content "$commit_msg" --arg tags "session,documentation,$branch" \
                    '{type: $type, content: $content, tags: $tags}')
                learnings+=("$learning_json")
            fi
        done <<< "$doc_commits"
    fi
    
    # Build learnings JSON
    local learnings_json="["
    local first=true
    for learning in "${learnings[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            learnings_json+=","
        fi
        learnings_json+="$learning"
    done
    learnings_json+="]"
    
    echo "$learnings_json" | jq '.' > "$learnings_file"
    
    local count
    count=$(echo "$learnings_json" | jq 'length')
    log_success "Extracted $count learnings to $learnings_file"
    
    cat "$learnings_file"
    return 0
}

#######################################
# Store extracted learnings to memory
#######################################
store_learnings() {
    init_session_dir
    
    log_info "Storing learnings to memory..."
    
    local learnings_file="$SESSION_DIR/extracted-learnings.json"
    
    if [[ ! -f "$learnings_file" ]]; then
        log_warn "No extracted learnings found. Running extract first..."
        extract_learnings
    fi
    
    if [[ ! -f "$MEMORY_HELPER" ]]; then
        log_error "Memory helper not found: $MEMORY_HELPER"
        return 1
    fi
    
    # Read and store each learning
    local count=0
    local stored=0
    
    while IFS= read -r learning; do
        local type content tags
        type=$(echo "$learning" | jq -r '.type')
        content=$(echo "$learning" | jq -r '.content')
        tags=$(echo "$learning" | jq -r '.tags')
        
        if [[ -n "$content" && "$content" != "null" ]]; then
            # Store to memory
            if "$MEMORY_HELPER" store --content "$content" --type "$type" --tags "$tags" 2>/dev/null; then
                stored=$((stored + 1))
            fi
            count=$((count + 1))
        fi
    done < <(jq -c '.[]' "$learnings_file" 2>/dev/null)
    
    log_success "Stored $stored of $count learnings to memory"
    
    # Clean up session files
    rm -f "$SESSION_DIR/session-analysis.json" "$SESSION_DIR/extracted-learnings.json"
    return 0
}

#######################################
# Full auto pipeline
#######################################
auto_distill() {
    log_info "Running full session distillation pipeline..."
    echo ""
    
    analyze_session
    echo ""
    
    extract_learnings
    echo ""
    
    store_learnings
    echo ""
    
    emit_checkpoint
    echo ""
    
    log_success "Session distillation complete (learnings + operational state)"
    return 0
}

#######################################
# Emit operational state checkpoint
# Captures what tasks are running, PRs pending, etc.
# Complements learnings (what we learned) with state (where we are)
#######################################
emit_checkpoint() {
    init_session_dir
    
    log_info "Capturing operational state..."
    
    local checkpoint_helper="$SCRIPT_DIR/session-checkpoint-helper.sh"
    
    if [[ -x "$checkpoint_helper" ]]; then
        # Generate continuation prompt (captures git, supervisor, PR, TODO state)
        local continuation_output
        continuation_output="$(bash "$checkpoint_helper" continuation 2>/dev/null || echo "Checkpoint helper unavailable")"
        
        # Save to session dir for inclusion in distill output
        local checkpoint_file="$SESSION_DIR/operational-state.md"
        echo "$continuation_output" > "$checkpoint_file"
        
        log_success "Operational state saved to $checkpoint_file"
        echo "$continuation_output"
    else
        log_warn "session-checkpoint-helper.sh not found at $checkpoint_helper"
        
        # Fallback: gather minimal state directly
        local branch
        branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        local open_prs
        open_prs=$(gh pr list --state open --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || echo "none")
        
        cat <<FALLBACK_EOF
## Operational State (fallback)

**Branch**: $branch
**Open PRs**: $open_prs
**Uncommitted**: $(git status --short 2>/dev/null || echo "unknown")
FALLBACK_EOF
    fi
    return 0
}

#######################################
# Generate distillation prompt for AI
# Returns a prompt the AI can use to reflect on the session
#######################################
generate_prompt() {
    init_session_dir
    
    # Gather context
    local branch commits_today
    branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    commits_today=$(git log --oneline --since="midnight" 2>/dev/null || echo "")
    
    cat << EOF
## Session Reflection Prompt

Review this session and identify learnings worth remembering:

**Branch**: $branch

**Today's commits**:
$commits_today

**Questions to consider**:
1. What problems were solved? (→ WORKING_SOLUTION)
2. What approaches failed? (→ FAILED_APPROACH)
3. What patterns were discovered? (→ CODEBASE_PATTERN)
4. What user preferences were expressed? (→ USER_PREFERENCE)
5. What tool configurations worked well? (→ TOOL_CONFIG)
6. What decisions were made and why? (→ DECISION)

For each learning, use:
\`\`\`bash
~/.aidevops/agents/scripts/memory-helper.sh store \\
  --content "Description of learning" \\
  --type TYPE \\
  --tags "relevant,tags"
\`\`\`

Or use the /remember command:
\`/remember Fixed CORS issue by adding proxy_set_header in nginx config\`
EOF
    return 0
}

#######################################
# Show help
#######################################
show_help() {
    cat << 'EOF'
Session Distill Helper - Extract learnings from session for memory storage

Usage:
  session-distill-helper.sh analyze     Analyze current session context
  session-distill-helper.sh extract     Extract and format learnings
  session-distill-helper.sh store       Store extracted learnings to memory
  session-distill-helper.sh checkpoint  Capture operational state (tasks, PRs, git)
  session-distill-helper.sh auto        Full pipeline: analyze → extract → store → checkpoint
  session-distill-helper.sh prompt      Generate reflection prompt for AI
  session-distill-helper.sh help        Show this help

The distillation process:
  1. analyze    - Gathers git history, TODO.md changes, session patterns
  2. extract    - Identifies valuable learnings from patterns
  3. store      - Saves learnings to memory via memory-helper.sh
  4. checkpoint - Captures operational state for session continuity

Learning types detected:
  - ERROR_FIX: Bug fixes and error resolutions
  - WORKING_SOLUTION: Successful implementations
  - CODEBASE_PATTERN: Refactoring and structural changes
  - CONTEXT: Documentation and context updates

Integration:
  - Called by /session-review at end of sessions
  - Works with memory-helper.sh for persistent storage
  - Works with session-checkpoint-helper.sh for operational state
  - Supports both automatic and AI-assisted distillation

Examples:
  # Full automatic distillation (learnings + operational state)
  session-distill-helper.sh auto

  # Just capture operational state
  session-distill-helper.sh checkpoint

  # Generate prompt for AI-assisted reflection
  session-distill-helper.sh prompt

  # Manual step-by-step
  session-distill-helper.sh analyze
  session-distill-helper.sh extract
  session-distill-helper.sh store
EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        analyze)
            analyze_session
            ;;
        extract)
            extract_learnings
            ;;
        store)
            store_learnings
            ;;
        checkpoint)
            emit_checkpoint
            ;;
        auto)
            auto_distill
            ;;
        prompt)
            generate_prompt
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
