#!/bin/bash
# =============================================================================
# Pre-Edit Git Branch Check
# =============================================================================
# Run this BEFORE any file edit to enforce the git workflow.
# Returns exit code 1 if on main/master branch (should create branch first).
#
# Usage:
#   ~/.aidevops/agents/scripts/pre-edit-check.sh
#
# AI assistants should call this before any Edit/Write tool and STOP if it
# returns a warning about being on main branch.
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${YELLOW}Not in a git repository - no branch check needed${NC}"
    exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")

if [[ -z "$current_branch" ]]; then
    echo -e "${YELLOW}Detached HEAD state - consider creating a branch${NC}"
    exit 0
fi

# Check if on main or master
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    echo ""
    echo -e "${RED}${BOLD}======================================================${NC}"
    echo -e "${RED}${BOLD}  STOP - ON PROTECTED BRANCH: $current_branch${NC}"
    echo -e "${RED}${BOLD}======================================================${NC}"
    echo ""
    echo -e "${YELLOW}You must create a branch before making changes.${NC}"
    echo ""
    echo "Suggested branch names based on change type:"
    echo "  feature/description  - New functionality"
    echo "  bugfix/description   - Bug fixes"
    echo "  chore/description    - Maintenance, docs, config"
    echo "  hotfix/description   - Urgent production fixes"
    echo "  refactor/description - Code restructuring"
    echo ""
    echo "To create a branch:"
    echo "  git checkout -b chore/your-description"
    echo ""
    echo -e "${RED}DO NOT proceed with edits until on a feature branch.${NC}"
    echo ""
    exit 1
else
    echo -e "${GREEN}OK${NC} - On branch: ${BOLD}$current_branch${NC}"
    
    # Sync terminal tab title with repo/branch (silent, non-blocking)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
    if [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
        "$SCRIPT_DIR/terminal-title-helper.sh" sync 2>/dev/null || true
    fi
    
    exit 0
fi
