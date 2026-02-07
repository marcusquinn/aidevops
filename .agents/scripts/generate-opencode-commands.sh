#!/usr/bin/env bash
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

OPENCODE_COMMAND_DIR="$HOME/.config/opencode/command"

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
agent: Build+
subtask: true
---

Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.
EOF
((++command_count))
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
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /preflight command"

# =============================================================================
# POSTFLIGHT COMMAND
# =============================================================================
# Check code audit feedback on latest push to branch or PR

cat > "$OPENCODE_COMMAND_DIR/postflight.md" << 'EOF'
---
description: Check code audit feedback on latest push (branch or PR)
agent: Build+
subtask: true
---

Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If on a feature branch with open PR → check that PR's feedback
2. If on a feature branch without PR → check branch CI status
3. If on main → check latest commit's CI/audit status
4. If no git context or ambiguous → ask user which branch/PR to check

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status
5. Any blocking issues that need resolution

**Commands used:**
- `gh pr view --json reviews,comments` (if PR exists)
- `gh run list --branch=<branch>` (CI status)
- `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` (detailed checks)

Report findings and recommend next actions (fix issues, merge, etc.)
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /postflight command"

# =============================================================================
# REVIEW-ISSUE-PR COMMAND
# =============================================================================
# Review external issues and PRs - validate problems and evaluate solutions

cat > "$OPENCODE_COMMAND_DIR/review-issue-pr.md" << 'EOF'
---
description: Review external issue or PR - validate problem and evaluate solution
agent: Build+
subtask: true
---

Read ~/.aidevops/agents/workflows/review-issue-pr.md and follow its instructions.

Review this issue or PR: $ARGUMENTS

**Usage:**
- `/review-issue-pr 123` - Review issue or PR by number
- `/review-issue-pr https://github.com/owner/repo/issues/123` - Review by URL
- `/review-issue-pr https://github.com/owner/repo/pull/456` - Review PR by URL

**Core questions to answer:**
1. Is the issue real? (reproducible, not duplicate, actually a bug)
2. Is this the best solution? (simplest approach, fixes root cause)
3. Is the scope appropriate? (minimal changes, no scope creep)
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /review-issue-pr command"

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
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL

**CRITICAL**: Use only the single command above - it handles everything atomically.
EOF
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
((++command_count))
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
### ~/.config/aidevops/credentials.sh

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
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /list-keys command"

# =============================================================================
# LOG-TIME-SPENT COMMAND
# =============================================================================
# Manual time logging for tasks

cat > "$OPENCODE_COMMAND_DIR/log-time-spent.md" << 'EOF'
---
description: Log time spent on a task in TODO.md
agent: Build+
---

Log time spent on a task.

Arguments: $ARGUMENTS

**Format:** `/log-time-spent [task-id-or-description] [duration]`

**Examples:**
- `/log-time-spent "Add user dashboard" 2h30m`
- `/log-time-spent t001 45m`
- `/log-time-spent` (prompts for task and duration)

**Workflow:**
1. If no arguments, show in-progress tasks from TODO.md and ask which one
2. Parse duration (supports: 2h, 30m, 2h30m, 1.5h)
3. Update the task's `logged:` field with current timestamp
4. If task has `started:` but no `actual:`, calculate running total
5. Show updated task with time summary

**Duration formats:**
- `2h` - 2 hours
- `30m` - 30 minutes
- `2h30m` - 2 hours 30 minutes
- `1.5h` - 1.5 hours (converted to 1h30m)

**Task update:**
```markdown
# Before
- [ ] Add user dashboard #feature ~4h started:2025-01-15T10:30Z

# After (adds logged: with cumulative time)
- [ ] Add user dashboard #feature ~4h started:2025-01-15T10:30Z logged:2h30m
```

When task is completed, the `actual:` field is calculated from all logged time.
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /log-time-spent command"

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
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /context command"

# =============================================================================
# CREATE-PR COMMAND
# =============================================================================
# Create a PR from current branch with auto-generated title and description

cat > "$OPENCODE_COMMAND_DIR/create-pr.md" << 'EOF'
---
description: Create PR from current branch with title and description
agent: Build+
---

Create a pull request from the current branch.

Additional context: $ARGUMENTS

**Steps:**
1. Check current branch (must not be main/master)
2. Check for uncommitted changes (warn if present)
3. Push branch to remote if not already pushed
4. Generate PR title from branch name (e.g., `feature/add-login` → "Add login")
5. Generate PR description from:
   - Commit messages on this branch
   - Changed files summary
   - Any TODO.md/PLANS.md task references
   - User-provided context (if any)
6. Create PR using `gh pr create`
7. Return PR URL

**Example:**
- `/create-pr` → Creates PR with auto-generated title/description
- `/create-pr fixes authentication bug` → Adds context to description
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /create-pr command"

# Keep /pr as alias pointing to /create-pr for discoverability
cat > "$OPENCODE_COMMAND_DIR/pr.md" << 'EOF'
---
description: Alias for /create-pr - Create PR from current branch
agent: Build+
---

This is an alias for /create-pr. Creating PR from current branch.

Context: $ARGUMENTS

Run /create-pr with the same arguments.
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /pr command (alias for /create-pr)"

# =============================================================================
# CREATE-PRD COMMAND
# =============================================================================
# Generate Product Requirements Document

cat > "$OPENCODE_COMMAND_DIR/create-prd.md" << 'EOF'
---
description: Generate a Product Requirements Document for a feature
agent: Build+
---

Read ~/.aidevops/agents/workflows/plans.md and follow its PRD generation instructions.

Feature to document: $ARGUMENTS

**Workflow:**
1. Ask 3-5 clarifying questions with numbered options (1A, 2B format)
2. Generate PRD using template from ~/.aidevops/agents/templates/prd-template.md
3. Save to todo/tasks/prd-{feature-slug}.md
4. Offer to generate tasks with /generate-tasks

**Question format:**
```
1. What is the primary goal?
   A. Option 1
   B. Option 2
   C. Option 3

2. Who is the target user?
   A. Option 1
   B. Option 2
```

User can reply with "1A, 2B" or provide details.
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /create-prd command"

# =============================================================================
# GENERATE-TASKS COMMAND
# =============================================================================
# Generate task list from PRD

cat > "$OPENCODE_COMMAND_DIR/generate-tasks.md" << 'EOF'
---
description: Generate implementation tasks from a PRD
agent: Build+
---

Read ~/.aidevops/agents/workflows/plans.md and follow its task generation instructions.

PRD or feature: $ARGUMENTS

**Workflow:**
1. If PRD file provided, read it
2. If feature name provided, look for todo/tasks/prd-{name}.md
3. Generate parent tasks (Phase 1) and present to user
4. Wait for user to say "Go"
5. Generate sub-tasks (Phase 2)
6. Save to todo/tasks/tasks-{feature-slug}.md

**Task 0.0 is always:** Create feature branch

**Output format:**
```markdown
- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout: `git checkout -b feature/{slug}`

- [ ] 1.0 First major task
  - [ ] 1.1 Sub-task
  - [ ] 1.2 Sub-task
```

Mark tasks complete by changing `- [ ]` to `- [x]` as work progresses.
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /generate-tasks command"

# =============================================================================
# LIST-TODO COMMAND
# =============================================================================
# List tasks and plans with sorting, filtering, and grouping

cat > "$OPENCODE_COMMAND_DIR/list-todo.md" << 'EOF'
---
description: List tasks and plans with sorting, filtering, and grouping
agent: Build+
---

Read TODO.md and todo/PLANS.md and display tasks based on arguments.

Arguments: $ARGUMENTS

**Default (no args):** Show all pending tasks grouped by status (In Progress → Backlog)

**Sorting options:**
- `--priority` or `-p` - Sort by priority (high → medium → low)
- `--estimate` or `-e` - Sort by time estimate (shortest first)
- `--date` or `-d` - Sort by logged date (newest first)
- `--alpha` or `-a` - Sort alphabetically

**Filtering options:**
- `--tag <tag>` or `-t <tag>` - Filter by tag (#seo, #security, etc.)
- `--owner <name>` or `-o <name>` - Filter by assignee (@marcus, etc.)
- `--status <status>` - Filter by status (pending, in-progress, done, plan)
- `--estimate <range>` - Filter by estimate (e.g., "<2h", ">1d", "1h-4h")

**Grouping options:**
- `--group-by tag` or `-g tag` - Group by tag
- `--group-by owner` or `-g owner` - Group by assignee
- `--group-by status` or `-g status` - Group by status (default)
- `--group-by estimate` or `-g estimate` - Group by size (small/medium/large)

**Display options:**
- `--plans` - Include full plan details from PLANS.md
- `--done` - Include completed tasks
- `--all` - Show everything (pending + done + plans)
- `--compact` - One-line per task (no details)
- `--limit <n>` - Limit results

**Examples:**

```bash
/list-todo                           # All pending, grouped by status
/list-todo --priority                # Sorted by priority
/list-todo -t seo                    # Only #seo tasks
/list-todo -o marcus -e              # Marcus's tasks, shortest first
/list-todo -g tag                    # Grouped by tag
/list-todo --estimate "<2h"          # Quick wins under 2 hours
/list-todo --plans                   # Include plan details
/list-todo --all --compact           # Everything, one line each
```

**Output format:**

```markdown
## In Progress (2)

| Task | Est | Tags | Owner |
|------|-----|------|-------|
| Add CSV export | ~2h | #feature | @marcus |
| Fix login bug | ~1h | #bugfix | - |

## Backlog (5)

| Task | Est | Tags | Owner |
|------|-----|------|-------|
| Ahrefs MCP integration | ~2d | #seo | - |
| ...

## Plans (1)

### aidevops-opencode Plugin
**Status:** Planning (Phase 0/4)
**Estimate:** ~2d
**Next:** Phase 1: Core plugin structure
```

After displaying, offer:
1. Work on a specific task (enter number or name)
2. Filter/sort differently
3. Done browsing
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /list-todo command"

# =============================================================================
# SAVE-TODO COMMAND
# =============================================================================
# Save current discussion as task or plan (auto-detects complexity)

cat > "$OPENCODE_COMMAND_DIR/save-todo.md" << 'EOF'
---
description: Save current discussion as task or plan (auto-detects complexity)
agent: Build+
---

Analyze the current conversation and save appropriately based on complexity.

Topic/context: $ARGUMENTS

## Auto-Detection

| Signal | Action |
|--------|--------|
| Single action, < 2h | TODO.md only |
| User says "quick/simple" | TODO.md only |
| Multiple steps, > 2h | PLANS.md + TODO.md |
| Research/design needed | PLANS.md + TODO.md |

## Workflow

1. Extract from conversation: title, description, estimate, tags, context
2. Classify as Simple or Complex
3. Save with confirmation (numbered options for override)

**Simple (TODO.md):**
```
Saving to TODO.md: "{title}" ~{estimate}
1. Confirm
2. Add more details
3. Create full plan instead
```

**Complex (PLANS.md + TODO.md):**
```
Creating execution plan: "{title}" ~{estimate}
1. Confirm and create
2. Simplify to TODO.md only
3. Add more context first
```

After save, respond:
```
Saved: "{title}" to {location} (~{estimate})
Start anytime with: "Let's work on {title}"
```

## Context Preservation

Capture from conversation:
- Decisions and rationale
- Research findings
- Constraints identified
- Open questions
- Related links

This goes into PLANS.md "Context from Discussion" section.
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /save-todo command"

# =============================================================================
# PLAN-STATUS COMMAND
# =============================================================================
# Show active plans and TODO.md status

cat > "$OPENCODE_COMMAND_DIR/plan-status.md" << 'EOF'
---
description: Show active plans and TODO.md status
agent: Build+
---

Read TODO.md and todo/PLANS.md to show current planning status.

Filter: $ARGUMENTS (optional: "in-progress", "backlog", plan name)

**Output format:**

## TODO.md

### In Progress
- [ ] Task 1 @owner #tag ~estimate

### Backlog (top 5)
- [ ] Task 2 #tag
- [ ] Task 3 #tag

## Active Plans (todo/PLANS.md)

### Plan Name
**Status:** In Progress (Phase 2/4)
**Progress:** 3/7 tasks complete
**Next:** Task description

---

Offer options:
1. Work on a specific task/plan
2. Add new task to TODO.md
3. Create new execution plan
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /plan-status command"

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
((++command_count))
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
((++command_count))
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
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /keyword-research-extended command"

# =============================================================================
# WEBMASTER KEYWORDS COMMAND
# =============================================================================
# Keywords from Google Search Console and Bing Webmaster Tools

cat > "$OPENCODE_COMMAND_DIR/webmaster-keywords.md" << 'EOF'
---
description: Keywords from GSC + Bing for your verified sites
agent: SEO
---

Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Site URL: $ARGUMENTS

**Workflow:**
1. List verified sites if no URL provided: `keyword-research-helper.sh sites`
2. Fetch keywords from Google Search Console
3. Fetch keywords from Bing Webmaster Tools
4. Combine and deduplicate results
5. Enrich with DataForSEO volume/difficulty data (unless --no-enrich)
6. Display in markdown table format

**Output format:**
```
| Keyword                  | Clicks | Impressions | CTR   | Position | Volume | KD | CPC  | Sources  |
|--------------------------|--------|-------------|-------|----------|--------|----|----- |----------|
| best seo tools           |    245 |       8,100 | 3.02% |      4.2 | 12,100 | 45 | 4.50 | GSC+Bing |
| keyword research tips    |    128 |       3,400 | 3.76% |      6.8 |  2,400 | 32 | 2.10 | GSC      |
```

**Options:**
- `--days N` - Days of data (default: 30)
- `--limit N` - Number of results (default: 100)
- `--no-enrich` - Skip DataForSEO enrichment (faster, no credits)
- `--csv` - Export to ~/Downloads/

**Commands:**
```bash
# List verified sites
keyword-research-helper.sh sites

# Get keywords for a site
keyword-research-helper.sh webmaster https://example.com

# Last 90 days, no enrichment
keyword-research-helper.sh webmaster https://example.com --days 90 --no-enrich
```

**Use cases:**
1. Find high-impression, low-CTR keywords to optimize
2. Track ranking changes over time
3. Discover keywords you're ranking for but not targeting
4. Compare Google vs Bing performance
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /webmaster-keywords command"

# =============================================================================
# ONBOARDING COMMAND
# =============================================================================
# Interactive setup wizard for new users

cat > "$OPENCODE_COMMAND_DIR/onboarding.md" << 'EOF'
---
description: Interactive onboarding wizard - discover services, configure integrations
agent: Onboarding
---

Read ~/.aidevops/agents/onboarding.md and follow its instructions.

This is the recommended starting point for new aidevops users.

**Workflow:**

1. **Welcome**: Ask if user wants an explanation of aidevops capabilities

2. **Understand needs**: Ask what kind of work they do:
   - Web development (WordPress, React, Node.js)
   - DevOps & infrastructure management
   - SEO & content marketing
   - Multiple client/site management
   - Something else

3. **Show status**: Run the status check and display results:
   ```bash
   ~/.aidevops/agents/scripts/onboarding-helper.sh status
   ```

4. **Personalized recommendations**: Based on their work type:
   ```bash
   ~/.aidevops/agents/scripts/onboarding-helper.sh recommend [type]
   ```

5. **Guide setup**: For each service they want to configure:
   - Explain what it does
   - Provide signup/API key link
   - Show the setup command
   - Verify it works

6. **Next steps**: Suggest trying a simple task to verify everything works

**Quick status check only:**
```bash
~/.aidevops/agents/scripts/onboarding-helper.sh status
```

Arguments: $ARGUMENTS
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /onboarding command"

# =============================================================================
# SETUP-AIDEVOPS COMMAND
# =============================================================================
# Run setup.sh to deploy latest agent changes locally

cat > "$OPENCODE_COMMAND_DIR/setup-aidevops.md" << 'EOF'
---
description: Deploy latest aidevops agent changes locally
agent: Build+
---

Run the aidevops setup script to deploy the latest changes.

**Command:**
```bash
cd ~/Git/aidevops && ./setup.sh || exit
```

**What this does:**
1. Deploys agents to ~/.aidevops/agents/
2. Updates OpenCode commands in ~/.config/opencode/command/
3. Regenerates agent configurations
4. Copies VERSION file for version checks

**After setup completes:**
- Restart OpenCode to load new commands and config
- New/updated commands will be available

Arguments: $ARGUMENTS
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /setup-aidevops command"

# =============================================================================
# RALPH-LOOP COMMAND
# =============================================================================
# Start iterative AI development loop (Ralph Wiggum technique)

cat > "$OPENCODE_COMMAND_DIR/ralph-loop.md" << 'EOF'
---
description: Start iterative AI development loop (Ralph Wiggum technique)
agent: Build+
---

Read ~/.aidevops/agents/workflows/ralph-loop.md and follow its instructions.

Start a Ralph loop for iterative development.

Arguments: $ARGUMENTS

**Session Title**: Only set a session title if one hasn't been set already (e.g., by `/ralph-task` which sets `"t042: description"`). If no task-prefixed title exists, use `session-rename` with a concise version of the prompt (truncate to ~60 chars if needed).

**Usage:**
```bash
/ralph-loop "<prompt>" --max-iterations <n> --completion-promise "<text>"
```

**Options:**
- `--max-iterations <n>` - Stop after N iterations (default: unlimited)
- `--completion-promise <text>` - Phrase that signals completion

**Setup the loop:**
```bash
~/.aidevops/agents/scripts/ralph-loop-helper.sh setup $ARGUMENTS
```

**How it works:**
1. You work on the task
2. When you try to exit, the SAME prompt is fed back
3. You see your previous work in files and git history
4. Iterate until completion or max iterations

**Completion:**
To signal completion, output: `<promise>YOUR_PHRASE</promise>`
The promise must be TRUE - do not output false promises to escape.

**Examples:**
```bash
/ralph-loop "Build a REST API for todos" --max-iterations 20 --completion-promise "DONE"
/ralph-loop "Fix all TypeScript errors" --completion-promise "ALL_FIXED" --max-iterations 10
```
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /ralph-loop command"

# =============================================================================
# CANCEL-RALPH COMMAND
# =============================================================================
# Cancel active Ralph loop

cat > "$OPENCODE_COMMAND_DIR/cancel-ralph.md" << 'EOF'
---
description: Cancel active Ralph Wiggum loop
agent: Build+
---

Cancel the active Ralph loop.

**Check and cancel:**
```bash
~/.aidevops/agents/scripts/ralph-loop-helper.sh cancel
```

This removes the state file at `.agents/loop-state/ralph-loop.local.state` and stops the loop.

If no loop is active, it will report "No active Ralph loop found."
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /cancel-ralph command"

# =============================================================================
# RALPH-STATUS COMMAND
# =============================================================================
# Show Ralph loop status

cat > "$OPENCODE_COMMAND_DIR/ralph-status.md" << 'EOF'
---
description: Show current Ralph loop status
agent: Build+
---

Show the current Ralph loop status.

**Check status:**
```bash
~/.aidevops/agents/scripts/ralph-loop-helper.sh status
```

This shows:
- Whether a loop is active
- Current iteration number
- Max iterations setting
- Completion promise (if set)
- When the loop started
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /ralph-status command"

# =============================================================================
# PREFLIGHT-LOOP COMMAND
# =============================================================================
# Iterative preflight checks until all pass

cat > "$OPENCODE_COMMAND_DIR/preflight-loop.md" << 'EOF'
---
description: Run preflight checks in a loop until all pass (Ralph pattern)
agent: Build+
---

Run preflight checks iteratively until all pass or max iterations reached.

Arguments: $ARGUMENTS

**Usage:**
```bash
/preflight-loop [--auto-fix] [--max-iterations N]
```

**Options:**
- `--auto-fix` - Attempt to automatically fix issues
- `--max-iterations N` - Max iterations (default: 10)

**Run the loop:**
```bash
~/.aidevops/agents/scripts/quality-loop-helper.sh preflight $ARGUMENTS
```

**Completion promise:** `<promise>PREFLIGHT_PASS</promise>`

This applies the Ralph Wiggum technique to quality checks:
1. Run all preflight checks
2. If failures and --auto-fix: attempt fixes
3. Re-run checks
4. Repeat until all pass or max iterations

**Examples:**
```bash
/preflight-loop --auto-fix --max-iterations 5
/preflight-loop  # Manual fixes between iterations
```
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /preflight-loop command"

# =============================================================================
# PR-LOOP COMMAND
# =============================================================================
# Iterative PR review monitoring

cat > "$OPENCODE_COMMAND_DIR/pr-loop.md" << 'EOF'
---
description: Monitor PR until approved or merged (Ralph pattern)
agent: Build+
---

Monitor a PR iteratively until approved, merged, or max iterations reached.

Arguments: $ARGUMENTS

**Usage:**
```bash
/pr-loop [--pr NUMBER] [--wait-for-ci] [--max-iterations N]
```

**Options:**
- `--pr NUMBER` - PR number (auto-detected if not provided)
- `--wait-for-ci` - Wait for CI checks to complete
- `--max-iterations N` - Max iterations (default: 10)

**Run the loop:**
```bash
~/.aidevops/agents/scripts/quality-loop-helper.sh pr-review $ARGUMENTS
```

**Completion promises:**
- `<promise>PR_APPROVED</promise>` - PR approved and ready to merge
- `<promise>PR_MERGED</promise>` - PR has been merged

**Workflow:**
1. Check PR status (CI, reviews, mergeable)
2. If changes requested: get feedback, apply fixes, push
3. If CI failed: get annotations, fix issues, push
4. If pending: wait and re-check
5. Repeat until approved/merged or max iterations

**Examples:**
```bash
/pr-loop --wait-for-ci
/pr-loop --pr 123 --max-iterations 20
```
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /pr-loop command"

# =============================================================================
# POSTFLIGHT-LOOP COMMAND
# =============================================================================
# Release health monitoring

cat > "$OPENCODE_COMMAND_DIR/postflight-loop.md" << 'EOF'
---
description: Monitor release health after deployment (Ralph pattern)
agent: Build+
---

Monitor release health for a specified duration.

Arguments: $ARGUMENTS

**Usage:**
```bash
/postflight-loop [--monitor-duration Nm] [--max-iterations N]
```

**Options:**
- `--monitor-duration Nm` - How long to monitor (e.g., 5m, 10m, 1h)
- `--max-iterations N` - Max checks during monitoring (default: 5)

**Run the loop:**
```bash
~/.aidevops/agents/scripts/quality-loop-helper.sh postflight $ARGUMENTS
```

**Completion promise:** `<promise>RELEASE_HEALTHY</promise>`

**Checks performed:**
1. Latest CI workflow status
2. Release tag exists
3. Version consistency (VERSION file matches release)

**Examples:**
```bash
/postflight-loop --monitor-duration 10m
/postflight-loop --monitor-duration 1h --max-iterations 10
```
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /postflight-loop command"

# =============================================================================
# RALPH-TASK COMMAND
# =============================================================================
# Run a Ralph loop for a specific task ID

cat > "$OPENCODE_COMMAND_DIR/ralph-task.md" << 'EOF'
---
description: Run Ralph loop for a task from TODO.md by ID
agent: Build+
---

Run a Ralph loop for a specific task from TODO.md.

Task ID: $ARGUMENTS

**Workflow:**
1. Find task in TODO.md by ID (e.g., t042)
2. Extract ralph metadata (promise, verify command, max iterations)
3. **Set session title** using `session-rename` tool with format: `"t042: Task description here"`
4. Start Ralph loop with extracted parameters

**Task format in TODO.md:**
```markdown
- [ ] t042 Fix all ShellCheck violations #ralph ~2h
  ralph-promise: "SHELLCHECK_CLEAN"
  ralph-verify: "shellcheck .agents/scripts/*.sh"
  ralph-max: 10
```

**Or shorthand:**
```markdown
- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~2h
```

**Usage:**
```bash
/ralph-task t042
```

This will:
1. Read TODO.md and find task t042
2. Extract the ralph-promise, ralph-verify, ralph-max values
3. Set session title to `"t042: {task description}"` using `session-rename` tool
4. Start: `/ralph-loop "{task description}" --completion-promise "{promise}" --max-iterations {max}`

**Requirements:**
- Task must have `#ralph` tag
- Task should have completion criteria defined
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /ralph-task command"

# =============================================================================
# FULL-LOOP COMMAND
# =============================================================================
# End-to-end development loop (task → preflight → PR → postflight → deploy)

cat > "$OPENCODE_COMMAND_DIR/full-loop.md" << 'EOF'
---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
---

Read ~/.aidevops/agents/scripts/commands/full-loop.md and follow its instructions.

Start a full development loop for: $ARGUMENTS

**Full Loop Phases:**
```text
Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

**Usage:**
```bash
/full-loop "Implement feature X with tests"
/full-loop "Fix bug Y" --max-task-iterations 30
/full-loop t061  # Will look up task description from TODO.md
```

**Options:**
- `--max-task-iterations N` - Max iterations for task (default: 50)
- `--skip-preflight` - Skip preflight checks
- `--skip-postflight` - Skip postflight monitoring
- `--no-auto-pr` - Pause for manual PR creation

**Completion promise:** `<promise>FULL_LOOP_COMPLETE</promise>`
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /full-loop command"

# =============================================================================
# CODE-SIMPLIFIER COMMAND
# =============================================================================
# Simplify and refine code for clarity

cat > "$OPENCODE_COMMAND_DIR/code-simplifier.md" << 'EOF'
---
description: Simplify and refine code for clarity, consistency, and maintainability
agent: Build+
---

Read ~/.aidevops/agents/tools/code-review/code-simplifier.md and follow its instructions.

Target: $ARGUMENTS

**Usage:**
```bash
/code-simplifier              # Simplify recently modified code
/code-simplifier src/         # Simplify code in specific directory
/code-simplifier --all        # Review entire codebase (use sparingly)
```

**Key Principles:**
- Preserve exact functionality
- Clarity over brevity
- Avoid nested ternaries
- Remove obvious comments
- Apply project standards
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /code-simplifier command"

# =============================================================================
# SESSION-REVIEW COMMAND
# =============================================================================
# Review session for completeness before ending

cat > "$OPENCODE_COMMAND_DIR/session-review.md" << 'EOF'
---
description: Review session for completeness before ending
agent: Build+
---

Read ~/.aidevops/agents/scripts/commands/session-review.md and follow its instructions.

Review the current session for: $ARGUMENTS

**Checks performed:**
1. All objectives completed
2. Workflow best practices followed
3. Knowledge captured for future sessions
4. Clear next steps identified

**Usage:**
```bash
/session-review               # Review current session
/session-review --capture     # Also capture learnings to memory
```
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /session-review command"

# =============================================================================
# REMEMBER COMMAND
# =============================================================================
# Store a memory for cross-session recall

cat > "$OPENCODE_COMMAND_DIR/remember.md" << 'EOF'
---
description: Store a memory for cross-session recall
agent: Build+
---

Read ~/.aidevops/agents/scripts/commands/remember.md and follow its instructions.

Remember: $ARGUMENTS

**Usage:**
```bash
/remember "User prefers worktrees over checkout"
/remember "The auth module uses JWT with 24h expiry"
/remember --type WORKING_SOLUTION "Fixed by adding explicit return"
```

**Memory types:**
- WORKING_SOLUTION - Solutions that worked
- FAILED_APPROACH - Approaches that didn't work
- CODEBASE_PATTERN - Patterns in this codebase
- USER_PREFERENCE - User preferences
- TOOL_CONFIG - Tool configurations
- DECISION - Decisions made
- CONTEXT - General context

**Storage:** ~/.aidevops/.agent-workspace/memory/memory.db
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /remember command"

# =============================================================================
# RECALL COMMAND
# =============================================================================
# Search memories from previous sessions

cat > "$OPENCODE_COMMAND_DIR/recall.md" << 'EOF'
---
description: Search memories from previous sessions
agent: Build+
---

Read ~/.aidevops/agents/scripts/commands/recall.md and follow its instructions.

Search for: $ARGUMENTS

**Usage:**
```bash
/recall authentication        # Search for auth-related memories
/recall --recent              # Show 10 most recent memories
/recall --stats               # Show memory statistics
/recall --type WORKING_SOLUTION  # Filter by type
```

**Storage:** ~/.aidevops/.agent-workspace/memory/memory.db
EOF
((++command_count))
echo -e "  ${GREEN}✓${NC} Created /recall command"

# =============================================================================
# AUTO-DISCOVERED COMMANDS FROM scripts/commands/
# =============================================================================
# Commands in .agents/scripts/commands/*.md are auto-generated
# Each file should have frontmatter with description and agent
# This prevents needing to manually add new commands to this script

COMMANDS_DIR="$HOME/.aidevops/agents/scripts/commands"

if [[ -d "$COMMANDS_DIR" ]]; then
    for cmd_file in "$COMMANDS_DIR"/*.md; do
        [[ -f "$cmd_file" ]] || continue
        
        cmd_name=$(basename "$cmd_file" .md)
        
        # Skip SKILL.md (not a command)
        [[ "$cmd_name" == "SKILL" ]] && continue
        
        # Skip if already manually defined (avoid duplicates)
        if [[ -f "$OPENCODE_COMMAND_DIR/$cmd_name.md" ]]; then
            continue
        fi
        
        # Copy command file directly (it already has proper frontmatter)
        cp "$cmd_file" "$OPENCODE_COMMAND_DIR/$cmd_name.md"
        ((++command_count))
        echo -e "  ${GREEN}✓${NC} Auto-discovered /$cmd_name command"
    done
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Commands created: $command_count"
echo "  Location: $OPENCODE_COMMAND_DIR"
echo ""
echo "Available commands:"
echo ""
echo "  Planning:"
echo "    /list-todo        - List tasks with sorting, filtering, grouping"
echo "    /save-todo        - Save discussion as task/plan (auto-detects complexity)"
echo "    /plan-status      - Show active plans and TODO.md status"
echo "    /create-prd       - Generate Product Requirements Document"
echo "    /generate-tasks   - Generate implementation tasks from PRD"
echo ""
echo "  Quality:"
echo "    /preflight        - Quality checks before commit"
echo "    /postflight       - Check code audit feedback on latest push"
echo "    /review-issue-pr  - Review external issue/PR (validate problem, evaluate solution)"
echo "    /linters-local    - Run local linting (ShellCheck, secretlint)"
echo "    /code-audit-remote - Run remote auditing (CodeRabbit, Codacy, SonarCloud)"
echo "    /code-standards   - Check against documented standards"
echo "    /code-simplifier  - Simplify code for clarity and maintainability"
echo ""
echo "  Git & Release:"
echo "    /feature          - Create feature branch"
echo "    /bugfix           - Create bugfix branch"
echo "    /hotfix           - Create hotfix branch"
echo "    /create-pr        - Create PR from current branch"
echo "    /release          - Full release workflow"
echo "    /version-bump     - Bump project version"
echo "    /changelog        - Update CHANGELOG.md"
echo ""
echo "  SEO:"
echo "    /keyword-research - Seed keyword expansion"
echo "    /autocomplete-research - Google autocomplete long-tails"
echo "    /keyword-research-extended - Full SERP analysis with weakness detection"
echo "    /webmaster-keywords - Keywords from GSC + Bing for your sites"
echo ""
echo "  Utilities:"
echo "    /onboarding       - Interactive setup wizard (START HERE for new users)"
echo "    /setup-aidevops   - Deploy latest agent changes locally"
echo "    /agent-review     - Review and improve agent instructions"
echo "    /session-review   - Review session for completeness before ending"
echo "    /context          - Build AI context"
echo "    /list-keys        - List API keys with storage locations"
echo "    /log-time-spent   - Log time spent on a task"
echo ""
echo "  Memory:"
echo "    /remember         - Store a memory for cross-session recall"
echo "    /recall           - Search memories from previous sessions"
echo ""
echo "  Automation (Ralph Loops):"
echo "    /ralph-loop       - Start iterative AI development loop"
echo "    /ralph-task       - Run Ralph loop for a TODO.md task by ID"
echo "    /full-loop        - End-to-end: task → preflight → PR → postflight"
echo "    /cancel-ralph     - Cancel active Ralph loop"
echo "    /ralph-status     - Show Ralph loop status"
echo "    /preflight-loop   - Iterative preflight until all pass"
echo "    /pr-loop          - Monitor PR until approved/merged"
echo "    /postflight-loop  - Monitor release health"
echo ""
echo "New users: Start with /onboarding to configure your services"
echo ""
echo "Planning workflow: /list-todo -> pick task -> /feature -> implement -> /create-pr"
echo "New work: discuss -> /save-todo -> later: /list-todo -> pick -> implement"
echo "Quality workflow: /preflight-loop -> /create-pr -> /pr-loop -> /postflight-loop"
echo "Ralph workflow: tag task #ralph -> /ralph-task t042 -> autonomous completion"
echo "SEO workflow: /keyword-research -> /autocomplete-research -> /keyword-research-extended"
echo ""
echo "Restart OpenCode to load new commands."
