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
#   - tools/build-agent/agent-review.md -> /agent-review
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

# Agent name constants (single source of truth for agent renames)
readonly AGENT_BUILD="Build+"
readonly AGENT_SEO="SEO"

# =============================================================================
# COMMAND CREATION HELPER
# =============================================================================
# Eliminates duplication across all manual command definitions.
#
# Usage:
#   create_command "name" "description" "agent" "subtask" <<'BODY'
#   Command body content here (without frontmatter)
#   BODY
#
# Parameters:
#   $1 - command name (e.g., "agent-review")
#   $2 - description for frontmatter
#   $3 - agent name (e.g., "Build+", "SEO", or "" for no agent field)
#   $4 - subtask flag ("true" to add subtask: true, "" to omit)
# =============================================================================
create_command() {
	(($# == 4)) || {
		echo -e "  ${RED}✗${NC} Error: create_command requires 4 arguments (got $#)" >&2
		return 1
	}
	local name="$1"
	[[ -n "$name" ]] || {
		echo -e "  ${RED}✗${NC} Error: command name required" >&2
		return 1
	}
	local description="$2"
	local agent="$3"
	local subtask="$4"
	local body
	body=$(cat)

	# Write command file
	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		cat <<<"$body"
	} >"${OPENCODE_COMMAND_DIR}/${name}.md"

	((++command_count))
	echo -e "  ${GREEN}✓${NC} Created /${name} command"
	return 0
}

# =============================================================================
# COMMAND DEFINITIONS
# =============================================================================

# --- Agent Review ---
create_command "agent-review" \
	"Systematic review and improvement of agent instructions" \
	"$AGENT_BUILD" "true" <<'BODY'
Read $HOME/.aidevops/agents/tools/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.
BODY

# --- Preflight ---
create_command "preflight" \
	"Run quality checks before version bump and release" \
	"$AGENT_BUILD" "true" <<'BODY'
Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)
BODY

# --- Postflight ---
create_command "postflight" \
	"Check code audit feedback on latest push (branch or PR)" \
	"$AGENT_BUILD" "true" <<'BODY'
Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If on a feature branch with open PR -> check that PR's feedback
2. If on a feature branch without PR -> check branch CI status
3. If on main -> check latest commit's CI/audit status
4. If no git context or ambiguous -> ask user which branch/PR to check

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
BODY

# --- Review Issue/PR ---
create_command "review-issue-pr" \
	"Review external issue or PR - validate problem and evaluate solution" \
	"$AGENT_BUILD" "true" <<'BODY'
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
BODY

# --- Release ---
create_command "release" \
	"Full release workflow with version bump, tag, and GitHub release" \
	"$AGENT_BUILD" "" <<'BODY'
Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits:
   - Any `feat:` or new feature -> minor
   - Only `fix:`, `docs:`, `chore:`, `perf:`, `refactor:` -> patch
   - Any `BREAKING CHANGE:` or `!` -> major
3. Run the single release command:
   ```bash
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL

**CRITICAL**: Use only the single command above - it handles everything atomically.
BODY

# --- Version Bump ---
create_command "version-bump" \
	"Bump project version (major, minor, or patch)" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/workflows/version-bump.md and follow its instructions.

Bump type: $ARGUMENTS

Valid types: major, minor, patch

This updates:
1. VERSION file
2. package.json (if exists)
3. Other version references as configured
BODY

# --- Changelog ---
create_command "changelog" \
	"Update CHANGELOG.md following Keep a Changelog format" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/workflows/changelog.md and follow its instructions.

Action: $ARGUMENTS

This maintains CHANGELOG.md with:
- Unreleased section for pending changes
- Version sections with dates
- Categories: Added, Changed, Deprecated, Removed, Fixed, Security
BODY

# --- Linters Local ---
create_command "linters-local" \
	"Run local linting tools (ShellCheck, secretlint, pattern checks)" \
	"$AGENT_BUILD" "" <<'BODY'
Run the local linters script:

!`~/.aidevops/agents/scripts/linters-local.sh $ARGUMENTS`

This runs fast, offline checks:
1. ShellCheck for shell scripts
2. Secretlint for exposed secrets
3. Pattern validation (return statements, positional parameters)
4. Markdown formatting checks

For remote auditing (CodeRabbit, Codacy, SonarCloud), use /code-audit-remote
BODY

# --- Code Audit Remote ---
create_command "code-audit-remote" \
	"Run remote code auditing (CodeRabbit, Codacy, SonarCloud)" \
	"$AGENT_BUILD" "true" <<'BODY'
Read ~/.aidevops/agents/workflows/code-audit-remote.md and follow its instructions.

Audit target: $ARGUMENTS

This calls external quality services:
1. CodeRabbit - AI-powered code review
2. Codacy - Code quality analysis
3. SonarCloud - Security and maintainability

For local linting (fast, offline), use /linters-local first
BODY

# --- Code Standards ---
create_command "code-standards" \
	"Check code against documented quality standards" \
	"$AGENT_BUILD" "true" <<'BODY'
Read ~/.aidevops/agents/tools/code-review/code-standards.md and follow its instructions.

Check target: $ARGUMENTS

This validates against our documented standards:
- S7682: Explicit return statements
- S7679: Positional parameters assigned to locals
- S1192: Constants for repeated strings
- S1481: No unused variables
- ShellCheck: Zero violations
BODY

# --- Feature Branch ---
create_command "feature" \
	"Create and develop a feature branch" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/workflows/branch/feature.md and follow its instructions.

Feature: $ARGUMENTS

This will:
1. Create feature branch from main
2. Set up development environment
3. Guide feature implementation
BODY

# --- Bugfix Branch ---
create_command "bugfix" \
	"Create and resolve a bugfix branch" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/workflows/branch/bugfix.md and follow its instructions.

Bug: $ARGUMENTS

This will:
1. Create bugfix branch
2. Guide bug investigation
3. Implement and test fix
BODY

# --- Hotfix Branch ---
create_command "hotfix" \
	"Urgent hotfix for critical production issues" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/workflows/branch/hotfix.md and follow its instructions.

Issue: $ARGUMENTS

This will:
1. Create hotfix branch from main/production
2. Implement minimal fix
3. Fast-track to release
BODY

# --- List Keys ---
create_command "list-keys" \
	"List all API keys available in session with their storage locations" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Log Time Spent ---
create_command "log-time-spent" \
	"Log time spent on a task in TODO.md" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Context Builder ---
create_command "context" \
	"Build token-efficient AI context for complex tasks" \
	"$AGENT_BUILD" "true" <<'BODY'
Read ~/.aidevops/agents/tools/context/context-builder.md and follow its instructions.

Context request: $ARGUMENTS

This generates optimized context for AI assistants including:
1. Relevant code snippets
2. Architecture overview
3. Dependencies and relationships
BODY

# --- Create PR ---
create_command "create-pr" \
	"Create PR from current branch with title and description" \
	"$AGENT_BUILD" "" <<'BODY'
Create a pull request from the current branch.

Additional context: $ARGUMENTS

**Steps:**
1. Check current branch (must not be main/master)
2. Check for uncommitted changes (warn if present)
3. Push branch to remote if not already pushed
4. Generate PR title from branch name (e.g., `feature/add-login` -> "Add login")
5. Generate PR description from:
   - Commit messages on this branch
   - Changed files summary
   - Any TODO.md/PLANS.md task references
   - User-provided context (if any)
6. Create PR using `gh pr create`
7. If creation succeeds, return PR URL; otherwise show error and suggest fixes

**Example:**
- `/create-pr` -> Creates PR with auto-generated title/description
- `/create-pr fixes authentication bug` -> Adds context to description
BODY

# --- PR Alias ---
create_command "pr" \
	"Alias for /create-pr - Create PR from current branch" \
	"$AGENT_BUILD" "" <<'BODY'
This is an alias for /create-pr. Creating PR from current branch.

Context: $ARGUMENTS

Run /create-pr with the same arguments.
BODY

# --- Create PRD ---
create_command "create-prd" \
	"Generate a Product Requirements Document for a feature" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Generate Tasks ---
create_command "generate-tasks" \
	"Generate implementation tasks from a PRD" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- List Todo ---
create_command "list-todo" \
	"List tasks and plans with sorting, filtering, and grouping" \
	"$AGENT_BUILD" "" <<'BODY'
Read TODO.md and todo/PLANS.md and display tasks based on arguments.

Arguments: $ARGUMENTS

**Default (no args):** Show all pending tasks grouped by status (In Progress -> Backlog)

**Sorting options:**
- `--priority` or `-p` - Sort by priority (high -> medium -> low)
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
BODY

# --- Save Todo ---
create_command "save-todo" \
	"Save current discussion as task or plan (auto-detects complexity)" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Plan Status ---
create_command "plan-status" \
	"Show active plans and TODO.md status" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Keyword Research ---
create_command "keyword-research" \
	"Keyword research with seed keyword expansion" \
	"$AGENT_SEO" "" <<'BODY'
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
BODY

# --- Autocomplete Research ---
create_command "autocomplete-research" \
	"Google autocomplete long-tail keyword expansion" \
	"$AGENT_SEO" "" <<'BODY'
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
BODY

# --- Keyword Research Extended ---
create_command "keyword-research-extended" \
	"Full SERP analysis with weakness detection and KeywordScore" \
	"$AGENT_SEO" "true" <<'BODY'
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
BODY

# --- Webmaster Keywords ---
create_command "webmaster-keywords" \
	"Keywords from GSC + Bing for your verified sites" \
	"$AGENT_SEO" "" <<'BODY'
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
BODY

# --- SEO Fan-Out ---
create_command "seo-fanout" \
	"Run thematic query fan-out research for AI search coverage" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/query-fanout-research.md and follow its instructions.

Target: $ARGUMENTS

Produce:
1. Thematic branch map for the target intent set
2. Prioritized sub-query list
3. Coverage matrix against existing pages
4. Remediation backlog for partial/missing high-priority branches
BODY

# --- SEO GEO ---
create_command "seo-geo" \
	"Run GEO strategy workflow for AI search visibility" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/geo-strategy.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Decision-criteria matrix
2. Page-level strong/partial/missing coverage map
3. Prioritized retrieval-first implementation plan
BODY

# --- SEO SRO ---
create_command "seo-sro" \
	"Run Selection Rate Optimization workflow for grounding snippets" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/sro-grounding.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Baseline snippet behavior summary
2. Sentence/structure-level SRO fixes
3. Controlled re-test plan with expected deltas
BODY

# --- SEO Hallucination Defense ---
create_command "seo-hallucination-defense" \
	"Audit and reduce AI brand hallucination risk" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/ai-hallucination-defense.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Critical fact inventory and canonical source map
2. Contradiction report with severities
3. Claim-evidence matrix and remediation priorities
BODY

# --- SEO Agent Discovery ---
create_command "seo-agent-discovery" \
	"Test AI agent discoverability across multi-turn tasks" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/ai-agent-discovery.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Discovery task completion diagnostics
2. Failure classification (missing content vs discoverability vs comprehension)
3. Prioritized remediation and re-test scorecard
BODY

# --- SEO AI Readiness ---
create_command "seo-ai-readiness" \
	"Run end-to-end AI search readiness workflow" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/ai-search-readiness.md and follow its instructions.

Target: $ARGUMENTS

Run chained phases:
1. Fan-out decomposition
2. GEO criteria alignment
3. SRO snippet optimization
4. Hallucination defense
5. Agent discoverability validation

Return one prioritized backlog with readiness scorecard deltas.
BODY

# --- SEO AI Baseline ---
create_command "seo-ai-baseline" \
	"Capture AI-search baseline metrics and output KPI scorecard" \
	"$AGENT_SEO" "" <<'BODY'
Read ~/.aidevops/agents/seo/ai-search-readiness.md and follow its instructions.
Read ~/.aidevops/agents/seo/ai-search-kpi-template.md and follow its format.

Target: $ARGUMENTS

Run baseline checks for fan-out, GEO, SRO, integrity, and discoverability.

Return:
1. Completed KPI scorecard baseline
2. Top 3 remediation priorities
3. Re-test schedule recommendation
BODY

# --- Onboarding ---
create_command "onboarding" \
	"Interactive onboarding wizard - discover services, configure integrations" \
	"" "" <<'BODY'
Read ${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions -- go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS
BODY

# --- Setup aidevops ---
create_command "setup-aidevops" \
	"Deploy latest aidevops agent changes locally" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Ralph Loop ---
create_command "ralph-loop" \
	"Start iterative AI development loop (Ralph Wiggum technique)" \
	"$AGENT_BUILD" "" <<'BODY'
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

For end-to-end development, prefer `/full-loop` which handles the complete lifecycle.

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
BODY

# --- Cancel Ralph ---
create_command "cancel-ralph" \
	"Cancel active Ralph Wiggum loop" \
	"$AGENT_BUILD" "" <<'BODY'
Cancel the active Ralph loop.

Remove the state file to stop the loop:

```bash
rm -f .agents/loop-state/ralph-loop.local.md .agents/loop-state/ralph-loop.local.state
```

If no loop state file exists, no loop is active.
BODY

# --- Ralph Status ---
create_command "ralph-status" \
	"Show current Ralph loop status" \
	"$AGENT_BUILD" "" <<'BODY'
Show the current Ralph loop status.

**Check status:**

```bash
cat .agents/loop-state/ralph-loop.local.md 2>/dev/null || echo "No active Ralph loop"
```

This shows:
- Whether a loop is active
- Current iteration number
- Max iterations setting
- Completion promise (if set)
- When the loop started
BODY

# --- Preflight Loop ---
create_command "preflight-loop" \
	"Run preflight checks in a loop until all pass (Ralph pattern)" \
	"$AGENT_BUILD" "" <<'BODY'
Run preflight checks iteratively until all pass or max iterations reached.

Arguments: $ARGUMENTS

**Usage:**
```bash
/preflight-loop [--auto-fix] [--max-iterations N]
```

**Options:**
- `--auto-fix` - Attempt to automatically fix issues
- `--max-iterations N` - Max iterations (default: 10)

**Run the checks:**

```bash
~/.aidevops/agents/scripts/linters-local.sh
```

**Completion promise:** `<promise>PREFLIGHT_PASS</promise>`

This applies the Ralph Wiggum technique to quality checks:
1. Run all preflight checks (linters-local.sh, shellcheck, markdown lint)
2. If failures and --auto-fix: attempt fixes
3. Re-run checks
4. Repeat until all pass or max iterations

**Examples:**
```bash
/preflight-loop --auto-fix --max-iterations 5
/preflight-loop  # Manual fixes between iterations
```
BODY

# --- PR Loop ---
create_command "pr-loop" \
	"Monitor PR until approved or merged (Ralph pattern)" \
	"$AGENT_BUILD" "" <<'BODY'
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

Read ~/.aidevops/agents/scripts/commands/pr-loop.md and follow its instructions.

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
BODY

# --- Postflight Loop ---
create_command "postflight-loop" \
	"Monitor release health after deployment (Ralph pattern)" \
	"$AGENT_BUILD" "" <<'BODY'
Monitor release health for a specified duration.

Arguments: $ARGUMENTS

**Usage:**
```bash
/postflight-loop [--monitor-duration Nm] [--max-iterations N]
```

**Options:**
- `--monitor-duration Nm` - How long to monitor (e.g., 5m, 10m, 1h)
- `--max-iterations N` - Max checks during monitoring (default: 5)

Read ~/.aidevops/agents/scripts/commands/postflight-loop.md and follow its instructions.

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
BODY

# --- Ralph Task ---
create_command "ralph-task" \
	"Run Ralph loop for a task from TODO.md by ID" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Full Loop ---
create_command "full-loop" \
	"Start end-to-end development loop (task -> preflight -> PR -> postflight -> deploy)" \
	"$AGENT_BUILD" "" <<'BODY'
Read ~/.aidevops/agents/scripts/commands/full-loop.md and follow its instructions.

Start a full development loop for: $ARGUMENTS

**Full Loop Phases:**
```text
Task Development -> Preflight -> PR Create -> PR Review -> Postflight -> Deploy
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
BODY

# --- Code Simplifier ---
create_command "code-simplifier" \
	"Simplify and refine code for clarity, consistency, and maintainability" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Session Review ---
create_command "session-review" \
	"Review session for completeness before ending" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Remember ---
create_command "remember" \
	"Store a memory for cross-session recall" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

# --- Recall ---
create_command "recall" \
	"Search memories from previous sessions" \
	"$AGENT_BUILD" "" <<'BODY'
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
BODY

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
		if cp "$cmd_file" "$OPENCODE_COMMAND_DIR/$cmd_name.md"; then
			((++command_count))
			echo -e "  ${GREEN}✓${NC} Auto-discovered /$cmd_name command"
		else
			echo -e "  ${RED}✗${NC} Failed to copy /$cmd_name command" >&2
			exit 1
		fi
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
echo "    /seo-fanout                - Thematic sub-query fan-out planning"
echo "    /seo-geo                   - GEO criteria and coverage strategy"
echo "    /seo-sro                   - SRO grounding snippet optimization"
echo "    /seo-hallucination-defense - Fact consistency and claim-evidence audit"
echo "    /seo-agent-discovery       - Multi-turn AI discoverability diagnostics"
echo "    /seo-ai-readiness          - End-to-end AI search readiness workflow"
echo "    /seo-ai-baseline           - Baseline KPI scorecard generation"
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
echo "    /full-loop        - End-to-end: task -> preflight -> PR -> postflight"
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
echo "AI-baseline workflow: /seo-ai-baseline -> /seo-ai-readiness"
echo "AI-search workflow: /seo-fanout -> /seo-geo -> /seo-sro ->"
echo "                      /seo-hallucination-defense -> /seo-agent-discovery"
echo ""
echo "Restart OpenCode to load new commands."
