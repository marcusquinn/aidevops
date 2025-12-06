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
# LINTERS-LOCAL COMMAND
# =============================================================================
# Run local linting tools (fast, offline)

cat > "$OPENCODE_COMMAND_DIR/linters-local.md" << 'EOF'
---
description: Run local linting tools (ShellCheck, secretlint, pattern checks)
agent: Build+
---

Run the local linters script:

!`~/.aidevops/agents/scripts/linters-local.sh $ARGUMENTS`

This runs fast, offline checks:
1. ShellCheck for shell scripts
2. Secretlint for exposed secrets
3. Pattern validation (return statements, positional parameters)
4. Markdown formatting checks

For remote auditing (CodeRabbit, Codacy, SonarCloud), use /code-audit-remote
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /linters-local command"

# =============================================================================
# CODE-AUDIT-REMOTE COMMAND
# =============================================================================
# Run remote code auditing services

cat > "$OPENCODE_COMMAND_DIR/code-audit-remote.md" << 'EOF'
---
description: Run remote code auditing (CodeRabbit, Codacy, SonarCloud)
agent: Build+
subtask: true
---

Read ~/.aidevops/agents/workflows/code-audit-remote.md and follow its instructions.

Audit target: $ARGUMENTS

This calls external quality services:
1. CodeRabbit - AI-powered code review
2. Codacy - Code quality analysis
3. SonarCloud - Security and maintainability

For local linting (fast, offline), use /linters-local first
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /code-audit-remote command"

# =============================================================================
# CODE-STANDARDS COMMAND
# =============================================================================
# Check against documented code standards

cat > "$OPENCODE_COMMAND_DIR/code-standards.md" << 'EOF'
---
description: Check code against documented quality standards
agent: Build+
subtask: true
---

Read ~/.aidevops/agents/tools/code-review/code-standards.md and follow its instructions.

Check target: $ARGUMENTS

This validates against our documented standards:
- S7682: Explicit return statements
- S7679: Positional parameters assigned to locals
- S1192: Constants for repeated strings
- S1481: No unused variables
- ShellCheck: Zero violations
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /code-standards command"

# =============================================================================
# BRANCH COMMANDS
# =============================================================================
# Git branch workflows

cat > "$OPENCODE_COMMAND_DIR/feature.md" << 'EOF'
---
description: Create and develop a feature branch
agent: Build+
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
# PR COMMAND (UNIFIED ORCHESTRATOR)
# =============================================================================
# Unified PR workflow - orchestrates all quality checks

cat > "$OPENCODE_COMMAND_DIR/pr.md" << 'EOF'
---
description: Unified PR workflow - orchestrates linting, auditing, standards, and intent vs reality
agent: Build+
---

Read ~/.aidevops/agents/workflows/pr.md and follow its instructions.

Action: $ARGUMENTS

This orchestrates all quality checks:
1. /linters-local - ShellCheck, secretlint, pattern checks
2. /code-audit-remote - CodeRabbit, Codacy, SonarCloud
3. /code-standards - Documented standards compliance
4. Intent vs Reality - Compare PR description to actual changes

Supports:
- review: Run all checks and analyze PR
- create: Create new PR after checks pass
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
echo "  /agent-review     - Review and improve agent instructions"
echo "  /preflight        - Quality checks before release"
echo "  /postflight       - Verify release health"
echo "  /release          - Full release workflow"
echo "  /version-bump     - Bump project version"
echo "  /changelog        - Update CHANGELOG.md"
echo "  /linters-local    - Run local linting (ShellCheck, secretlint)"
echo "  /code-audit-remote - Run remote auditing (CodeRabbit, Codacy, SonarCloud)"
echo "  /code-standards   - Check against documented standards"
echo "  /pr               - Unified PR workflow (orchestrates all checks)"
echo "  /feature          - Create feature branch"
echo "  /bugfix           - Create bugfix branch"
echo "  /hotfix           - Create hotfix branch"
echo "  /context          - Build AI context"
echo ""
echo "Quality workflow: /linters-local -> /code-audit-remote -> /pr"
echo ""
echo "Restart OpenCode to load new commands."
