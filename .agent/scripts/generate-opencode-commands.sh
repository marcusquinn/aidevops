#!/bin/bash
# =============================================================================
# Generate OpenCode Commands from Agent Files
# =============================================================================
# Creates /commands in OpenCode from agent markdown files
#
# Source: ~/.aidevops/agents/
# Target: ~/.config/opencode/command/
#
# Commands are generated from:
#   - build-agent/agent-review.md -> /agent-review
#   - workflows/*.md -> /workflow-name
#   - Other agents as needed
# =============================================================================

set -euo pipefail

AGENTS_DIR="$HOME/.aidevops/agents"
OPENCODE_COMMAND_DIR="$HOME/.config/opencode/command"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Generating OpenCode commands...${NC}"

# Ensure command directory exists
mkdir -p "$OPENCODE_COMMAND_DIR"

command_count=0

# =============================================================================
# AGENT-REVIEW COMMAND
# =============================================================================
# The agent-review command triggers a systematic review of agent instructions

cat > "$OPENCODE_COMMAND_DIR/agent-review.md" << 'EOF'
---
description: Systematic review and improvement of agent instructions
agent: Build-Agent
subtask: true
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /agent-review command"

# =============================================================================
# PREFLIGHT COMMAND
# =============================================================================
# Quality checks before version bump and release

cat > "$OPENCODE_COMMAND_DIR/preflight.md" << 'EOF'
---
description: Run quality checks before version bump and release
agent: Build+
subtask: true
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /preflight command"

# =============================================================================
# POSTFLIGHT COMMAND
# =============================================================================
# Verify release health after tag and GitHub release

cat > "$OPENCODE_COMMAND_DIR/postflight.md" << 'EOF'
---
description: Verify release health after tag and GitHub release
agent: Build+
subtask: true
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/postflight.md and follow its instructions.

Verify release: $ARGUMENTS

This includes:
1. Tag exists and matches VERSION file
2. GitHub release created successfully
3. CHANGELOG.md updated
4. No uncommitted changes
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /postflight command"

# =============================================================================
# RELEASE COMMAND
# =============================================================================
# Full release workflow

cat > "$OPENCODE_COMMAND_DIR/release.md" << 'EOF'
---
description: Full release workflow with version bump, tag, and GitHub release
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/release.md and follow its instructions.

Release type: $ARGUMENTS

Valid types: major, minor, patch

This will:
1. Run preflight checks
2. Bump version in VERSION file
3. Update CHANGELOG.md
4. Create git tag
5. Push to remote
6. Create GitHub release
7. Run postflight verification
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /release command"

# =============================================================================
# VERSION-BUMP COMMAND
# =============================================================================
# Version management

cat > "$OPENCODE_COMMAND_DIR/version-bump.md" << 'EOF'
---
description: Bump project version (major, minor, or patch)
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/version-bump.md and follow its instructions.

Bump type: $ARGUMENTS

Valid types: major, minor, patch

This updates:
1. VERSION file
2. package.json (if exists)
3. Other version references as configured
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /version-bump command"

# =============================================================================
# CHANGELOG COMMAND
# =============================================================================
# Changelog management

cat > "$OPENCODE_COMMAND_DIR/changelog.md" << 'EOF'
---
description: Update CHANGELOG.md following Keep a Changelog format
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/changelog.md and follow its instructions.

Action: $ARGUMENTS

This maintains CHANGELOG.md with:
- Unreleased section for pending changes
- Version sections with dates
- Categories: Added, Changed, Deprecated, Removed, Fixed, Security
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /changelog command"

# =============================================================================
# CODE-REVIEW COMMAND
# =============================================================================
# Comprehensive code review

cat > "$OPENCODE_COMMAND_DIR/code-review.md" << 'EOF'
---
description: Comprehensive code review checklist and guidance
agent: Build+
subtask: true
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/code-review.md and follow its instructions.

Review target: $ARGUMENTS

This covers:
1. Code quality and style
2. Security considerations
3. Performance implications
4. Test coverage
5. Documentation
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /code-review command"

# =============================================================================
# QUALITY-CHECK COMMAND
# =============================================================================
# Run all quality checks

cat > "$OPENCODE_COMMAND_DIR/quality-check.md" << 'EOF'
---
description: Run comprehensive code quality checks
agent: Build+
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

Run the quality check script:

!`~/.aidevops/agents/scripts/quality-check.sh $ARGUMENTS`

This runs:
1. ShellCheck for shell scripts
2. SonarCloud analysis
3. Secret detection
4. Markdown linting
5. Return statement validation
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /quality-check command"

# =============================================================================
# BRANCH COMMANDS
# =============================================================================
# Git branch workflows

cat > "$OPENCODE_COMMAND_DIR/feature.md" << 'EOF'
---
description: Create and develop a feature branch
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/branch/feature.md and follow its instructions.

Feature: $ARGUMENTS

This will:
1. Create feature branch from main
2. Set up development environment
3. Guide feature implementation
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /feature command"

cat > "$OPENCODE_COMMAND_DIR/bugfix.md" << 'EOF'
---
description: Create and resolve a bugfix branch
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/branch/bugfix.md and follow its instructions.

Bug: $ARGUMENTS

This will:
1. Create bugfix branch
2. Guide bug investigation
3. Implement and test fix
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /bugfix command"

cat > "$OPENCODE_COMMAND_DIR/hotfix.md" << 'EOF'
---
description: Urgent hotfix for critical production issues
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/branch/hotfix.md and follow its instructions.

Issue: $ARGUMENTS

This will:
1. Create hotfix branch from main/production
2. Implement minimal fix
3. Fast-track to release
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /hotfix command"

# =============================================================================
# CONTEXT BUILDER COMMAND
# =============================================================================
# Token-efficient context generation

cat > "$OPENCODE_COMMAND_DIR/context.md" << 'EOF'
---
description: Build token-efficient AI context for complex tasks
agent: Build+
subtask: true
tools:
  read: true
  bash: true
  glob: true
  grep: true
  repomix_*: true
---

Read ~/.aidevops/agents/tools/context/context-builder.md and follow its instructions.

Context request: $ARGUMENTS

This generates optimized context for AI assistants including:
1. Relevant code snippets
2. Architecture overview
3. Dependencies and relationships
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /context command"

# =============================================================================
# PULL-REQUEST COMMAND
# =============================================================================
# Create and manage PRs

cat > "$OPENCODE_COMMAND_DIR/pr.md" << 'EOF'
---
description: Create, review, and manage pull requests
agent: Build+
tools:
  read: true
  edit: true
  write: true
  bash: true
  glob: true
  grep: true
---

Read ~/.aidevops/agents/workflows/pull-request.md and follow its instructions.

Action: $ARGUMENTS

Supports:
- create: Create new PR from current branch
- review: Review an existing PR
- merge: Merge a PR after approval
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /pr command"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Commands created: $command_count"
echo "  Location: $OPENCODE_COMMAND_DIR"
echo ""
echo "Available commands:"
echo "  /agent-review  - Review and improve agent instructions"
echo "  /preflight     - Quality checks before release"
echo "  /postflight    - Verify release health"
echo "  /release       - Full release workflow"
echo "  /version-bump  - Bump project version"
echo "  /changelog     - Update CHANGELOG.md"
echo "  /code-review   - Comprehensive code review"
echo "  /quality-check - Run quality checks"
echo "  /feature       - Create feature branch"
echo "  /bugfix        - Create bugfix branch"
echo "  /hotfix        - Create hotfix branch"
echo "  /context       - Build AI context"
echo "  /pr            - Manage pull requests"
echo ""
echo "Restart OpenCode to load new commands."
