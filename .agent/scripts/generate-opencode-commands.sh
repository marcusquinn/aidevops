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

OPENCODE_COMMAND_DIR="$HOME/.config/opencode/command"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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
# Full release workflow - direct execution, no subagent needed

cat > "$OPENCODE_COMMAND_DIR/release.md" << 'EOF'
---
description: Full release workflow with version bump, tag, and GitHub release
agent: Build+
---

Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits:
   - Any `feat:` or new feature → minor
   - Only `fix:`, `docs:`, `chore:`, `perf:`, `refactor:` → patch
   - Any `BREAKING CHANGE:` or `!` → major
3. Run the single release command:
   ```bash
   .agent/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL

**CRITICAL**: Use only the single command above - it handles everything atomically.
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
# LIST-KEYS COMMAND
# =============================================================================
# List all API keys available in session

cat > "$OPENCODE_COMMAND_DIR/list-keys.md" << 'EOF'
---
description: List all API keys available in session with their storage locations
agent: Build+
---

Run the list-keys helper script and format the output as a markdown table:

!`~/.aidevops/agents/scripts/list-keys-helper.sh --json $ARGUMENTS`

Parse the JSON output and present as markdown tables grouped by source.

Format with padded columns for readability:

```
### ~/.config/aidevops/mcp-env.sh

| Key                        | Status        |
|----------------------------|---------------|
| OPENAI_API_KEY             | ✓ loaded      |
| ANTHROPIC_API_KEY          | ✓ loaded      |
| TEST_KEY                   | ⚠ placeholder |
```

Status icons:
- ✓ loaded
- ⚠ placeholder (needs real value)  
- ✗ not loaded
- ℹ configured

Pad key names to align columns. End with total count.

Security: Key values are NEVER displayed.
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /list-keys command"

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
# KEYWORD RESEARCH COMMAND
# =============================================================================
# Basic keyword expansion from seed keywords

cat > "$OPENCODE_COMMAND_DIR/keyword-research.md" << 'EOF'
---
description: Keyword research with seed keyword expansion
agent: SEO
---

Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Keywords to research: $ARGUMENTS

**Workflow:**
1. If no locale preference saved, prompt user to select (US/English default)
2. Call the keyword research helper or DataForSEO MCP directly
3. Return first 100 results in markdown table format
4. Ask if user needs more results (up to 10,000)
5. Offer CSV export option

**Output format:**
```
| Keyword                  | Volume  | CPC    | KD  | Intent       |
|--------------------------|---------|--------|-----|--------------|
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial   |
```

**Options from arguments:**
- `--provider dataforseo|serper|both`
- `--locale us-en|uk-en|etc`
- `--limit N`
- `--csv` - Export to ~/Downloads/
- `--min-volume N`, `--max-difficulty N`, `--intent type`
- `--contains "term"`, `--excludes "term"`

Wildcards supported: "best * for dogs" expands to variations.
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /keyword-research command"

# =============================================================================
# AUTOCOMPLETE RESEARCH COMMAND
# =============================================================================
# Google autocomplete long-tail expansion

cat > "$OPENCODE_COMMAND_DIR/autocomplete-research.md" << 'EOF'
---
description: Google autocomplete long-tail keyword expansion
agent: SEO
---

Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Seed keyword for autocomplete: $ARGUMENTS

**Workflow:**
1. Use DataForSEO or Serper autocomplete API
2. Return all autocomplete suggestions
3. Display in markdown table format
4. Offer CSV export option

**Output format:**
```
| Keyword                           | Volume  | CPC    | KD  | Intent       |
|-----------------------------------|---------|--------|-----|--------------|
| how to lose weight fast           |  8,100  | $2.10  | 42  | Informational|
| how to lose weight in a week      |  5,400  | $1.80  | 38  | Informational|
```

**Options:**
- `--provider dataforseo|serper|both`
- `--locale us-en|uk-en|etc`
- `--csv` - Export to ~/Downloads/

This is ideal for discovering question-based and long-tail keywords.
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /autocomplete-research command"

# =============================================================================
# KEYWORD RESEARCH EXTENDED COMMAND
# =============================================================================
# Full SERP analysis with weakness detection and KeywordScore

cat > "$OPENCODE_COMMAND_DIR/keyword-research-extended.md" << 'EOF'
---
description: Full SERP analysis with weakness detection and KeywordScore
agent: SEO
subtask: true
---

Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Research target: $ARGUMENTS

**Modes (from arguments):**
- Default: Full SERP analysis on keywords
- `--domain example.com` - Keywords associated with domain's niche
- `--competitor example.com` - Exact keywords competitor ranks for
- `--gap yourdomain.com,competitor.com` - Keywords they have that you don't

**Analysis levels:**
- `--full` (default): Complete SERP analysis with 17 weaknesses + KeywordScore
- `--quick`: Basic metrics only (Volume, CPC, KD, Intent) - faster, cheaper

**Additional options:**
- `--ahrefs` - Include Ahrefs DR/UR metrics
- `--provider dataforseo|serper|both`
- `--limit N` (default 100, max 10,000)
- `--csv` - Export to ~/Downloads/

**Extended output format:**
```
| Keyword         | Vol    | KD  | KS  | Weaknesses | Weakness Types                   | DS  | PS  |
|-----------------|--------|-----|-----|------------|----------------------------------|-----|-----|
| best seo tools  | 12.1K  | 45  | 72  | 5          | Low DS, Old Content, No HTTPS... | 23  | 15  |
```

**Competitor/Gap output format:**
```
| Keyword         | Vol    | KD  | Position | Est Traffic | Ranking URL                    |
|-----------------|--------|-----|----------|-------------|--------------------------------|
| best seo tools  | 12.1K  | 45  | 3        | 2,450       | example.com/blog/seo-tools     |
```

**KeywordScore (0-100):**
- 90-100: Exceptional opportunity
- 70-89: Strong opportunity
- 50-69: Moderate opportunity
- 30-49: Challenging
- 0-29: Very difficult

**17 SERP Weaknesses detected:**
Domain: Low DS, Low PS, No Backlinks
Technical: Slow Page, High Spam, Non-HTTPS, Broken, Flash, Frames, Non-Canonical
Content: Old Content, Title Mismatch, No Keyword in Headings, No Headings, Unmatched Intent
SERP: UGC-Heavy Results
EOF
((command_count++))
echo -e "  ${GREEN}✓${NC} Created /keyword-research-extended command"

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
echo "  /list-keys        - List API keys with storage locations"
echo "  /keyword-research - Seed keyword expansion"
echo "  /autocomplete-research - Google autocomplete long-tails"
echo "  /keyword-research-extended - Full SERP analysis with weakness detection"
echo ""
echo "Quality workflow: /linters-local -> /code-audit-remote -> /pr"
echo "SEO workflow: /keyword-research -> /autocomplete-research -> /keyword-research-extended"
echo ""
echo "Restart OpenCode to load new commands."
