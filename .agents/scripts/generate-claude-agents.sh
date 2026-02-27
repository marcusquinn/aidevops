#!/usr/bin/env bash
# shellcheck disable=SC2016 # $ARGUMENTS is a Claude Code template placeholder written literally to .md files
# =============================================================================
# Generate Claude Code Configuration
# =============================================================================
# Achieves config parity between OpenCode and Claude Code by:
#   1. Slash commands: Generated in ~/.claude/commands/ (project-level)
#   2. MCP servers: Registered via `claude mcp add-json` (user scope)
#   3. Settings: Enhanced ~/.claude/settings.json (hooks, permissions)
#
# Architecture mirrors generate-opencode-agents.sh / generate-opencode-commands.sh
# but targets Claude Code's native configuration system.
#
# Prerequisites: `claude` binary must be in PATH
# Called by: setup.sh update_claude_config()
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	echo "Error: shared-constants.sh not found at ${SCRIPT_DIR}/shared-constants.sh" >&2
	exit 1
fi

set -euo pipefail

CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# =============================================================================
# GUARD: claude binary must exist
# =============================================================================

if ! command -v claude &>/dev/null; then
	echo -e "${YELLOW}[SKIP]${NC} claude binary not found — Claude Code config skipped"
	exit 0
fi

echo -e "${BLUE}Generating Claude Code configuration...${NC}"

# =============================================================================
# PHASE 1: SLASH COMMANDS
# =============================================================================
# Claude Code uses ~/.claude/commands/*.md for custom slash commands.
# Each file becomes a /command-name available in the CLI.
# Frontmatter format:
#   ---
#   description: Short description
#   allowed-tools: tool1, tool2 (optional)
#   ---
#
# $ARGUMENTS is replaced with user input after the command name.
# =============================================================================

echo -e "${BLUE}Generating Claude Code slash commands...${NC}"

mkdir -p "$CLAUDE_COMMANDS_DIR"

command_count=0

# Helper: write a slash command file
# Args: $1=name, $2=description, $3=body (heredoc content)
write_command() {
	local name="$1"
	local description="$2"
	local body="$3"

	cat >"$CLAUDE_COMMANDS_DIR/$name.md" <<EOF
---
description: $description
---

$body
EOF
	((++command_count))
	echo -e "  ${GREEN}+${NC} /$name"
	return 0
}

# --- Agent Review ---
write_command "agent-review" \
	"Systematic review and improvement of agent instructions" \
	'Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.'

# --- Preflight ---
write_command "preflight" \
	"Run quality checks before version bump and release" \
	'Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)'

# --- Postflight ---
write_command "postflight" \
	"Check code audit feedback on latest push (branch or PR)" \
	'Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If on a feature branch with open PR -> check that PR'\''s feedback
2. If on a feature branch without PR -> check branch CI status
3. If on main -> check latest commit'\''s CI/audit status

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status

**Commands used:**
- `gh pr view --json reviews,comments` (if PR exists)
- `gh run list --branch=<branch>` (CI status)
- `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` (detailed checks)

Report findings and recommend next actions (fix issues, merge, etc.)'

# --- Review Issue/PR ---
write_command "review-issue-pr" \
	"Review external issue or PR - validate problem and evaluate solution" \
	'Read ~/.aidevops/agents/workflows/review-issue-pr.md and follow its instructions.

Review this issue or PR: $ARGUMENTS

**Usage:**
- `/review-issue-pr 123` - Review issue or PR by number
- `/review-issue-pr https://github.com/owner/repo/issues/123` - Review by URL
- `/review-issue-pr https://github.com/owner/repo/pull/456` - Review PR by URL

**Core questions to answer:**
1. Is the issue real? (reproducible, not duplicate, actually a bug)
2. Is this the best solution? (simplest approach, fixes root cause)
3. Is the scope appropriate? (minimal changes, no scope creep)'

# --- Release ---
write_command "release" \
	"Full release workflow with version bump, tag, and GitHub release" \
	'Execute a release for the current repository.

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

**CRITICAL**: Use only the single command above - it handles everything atomically.'

# --- Version Bump ---
write_command "version-bump" \
	"Bump project version (major, minor, or patch)" \
	'Read ~/.aidevops/agents/workflows/version-bump.md and follow its instructions.

Bump type: $ARGUMENTS

Valid types: major, minor, patch

This updates:
1. VERSION file
2. package.json (if exists)
3. Other version references as configured'

# --- Linters Local ---
write_command "linters-local" \
	"Run local linting tools (ShellCheck, secretlint, pattern checks)" \
	'Run the local linters script:

```bash
~/.aidevops/agents/scripts/linters-local.sh $ARGUMENTS
```

This runs fast, offline checks:
1. ShellCheck for shell scripts
2. Secretlint for exposed secrets
3. Pattern validation (return statements, positional parameters)
4. Markdown formatting checks'

# --- Code Standards ---
write_command "code-standards" \
	"Check code against documented quality standards" \
	'Read ~/.aidevops/agents/tools/code-review/code-standards.md and follow its instructions.

Check target: $ARGUMENTS

This validates against our documented standards:
- S7682: Explicit return statements
- S7679: Positional parameters assigned to locals
- S1192: Constants for repeated strings
- S1481: No unused variables
- ShellCheck: Zero violations'

# --- Branch Commands ---
write_command "feature" \
	"Create and develop a feature branch" \
	'Read ~/.aidevops/agents/workflows/branch/feature.md and follow its instructions.

Feature: $ARGUMENTS

This will:
1. Create feature branch from main
2. Set up development environment
3. Guide feature implementation'

write_command "bugfix" \
	"Create and resolve a bugfix branch" \
	'Read ~/.aidevops/agents/workflows/branch/bugfix.md and follow its instructions.

Bug: $ARGUMENTS

This will:
1. Create bugfix branch
2. Guide bug investigation
3. Implement and test fix'

write_command "hotfix" \
	"Urgent hotfix for critical production issues" \
	'Read ~/.aidevops/agents/workflows/branch/hotfix.md and follow its instructions.

Issue: $ARGUMENTS

This will:
1. Create hotfix branch from main/production
2. Implement minimal fix
3. Fast-track to release'

# --- Create PR ---
write_command "create-pr" \
	"Create PR from current branch with title and description" \
	'Create a pull request from the current branch.

Additional context: $ARGUMENTS

**Steps:**
1. Check current branch (must not be main/master)
2. Check for uncommitted changes (warn if present)
3. Push branch to remote if not already pushed
4. Generate PR title from branch name
5. Generate PR description from commit messages and changed files
6. Create PR using `gh pr create`
7. Return PR URL'

# --- List TODO ---
write_command "list-todo" \
	"List tasks and plans with sorting, filtering, and grouping" \
	'Read TODO.md and todo/PLANS.md and display tasks based on arguments.

Arguments: $ARGUMENTS

**Default (no args):** Show all pending tasks grouped by status (In Progress -> Backlog)

**Sorting:** `--priority`, `--estimate`, `--date`, `--alpha`
**Filtering:** `--tag <tag>`, `--owner <name>`, `--status <status>`
**Grouping:** `--group-by tag|owner|status|estimate`
**Display:** `--plans`, `--done`, `--all`, `--compact`, `--limit <n>`'

# --- Save TODO ---
write_command "save-todo" \
	"Save current discussion as task or plan (auto-detects complexity)" \
	'Analyze the current conversation and save appropriately based on complexity.

Topic/context: $ARGUMENTS

| Signal | Action |
|--------|--------|
| Single action, < 2h | TODO.md only |
| Multiple steps, > 2h | PLANS.md + TODO.md |

Extract from conversation: title, description, estimate, tags, context.
Classify as Simple or Complex. Save with confirmation.'

# --- Plan Status ---
write_command "plan-status" \
	"Show active plans and TODO.md status" \
	'Read TODO.md and todo/PLANS.md to show current planning status.

Filter: $ARGUMENTS (optional: "in-progress", "backlog", plan name)

Show In Progress tasks, top 5 Backlog, and Active Plans with progress.'

# --- Onboarding ---
write_command "onboarding" \
	"Interactive onboarding wizard - discover services, configure integrations" \
	'Read ~/.aidevops/agents/aidevops/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions — go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS'

# --- Setup ---
write_command "setup-aidevops" \
	"Deploy latest aidevops agent changes locally" \
	'Run the aidevops setup script to deploy the latest changes.

```bash
cd ~/Git/aidevops && ./setup.sh || exit
```

This deploys agents, updates commands, regenerates configs.
Arguments: $ARGUMENTS'

# --- Ralph Loop ---
write_command "ralph-loop" \
	"Start iterative AI development loop (Ralph Wiggum technique)" \
	'Read ~/.aidevops/agents/workflows/ralph-loop.md and follow its instructions.

Start a Ralph loop for iterative development.

Arguments: $ARGUMENTS

For end-to-end development, prefer `/full-loop` which handles the complete lifecycle.'

# --- Full Loop ---
write_command "full-loop" \
	"Start end-to-end development loop (task -> preflight -> PR -> postflight -> deploy)" \
	'Read ~/.aidevops/agents/scripts/commands/full-loop.md and follow its instructions.

Start a full development loop for: $ARGUMENTS

**Full Loop Phases:**
Task Development -> Preflight -> PR Create -> PR Review -> Postflight -> Deploy

**Completion promise:** `<promise>FULL_LOOP_COMPLETE</promise>`'

# --- Code Simplifier ---
write_command "code-simplifier" \
	"Simplify and refine code for clarity, consistency, and maintainability" \
	'Read ~/.aidevops/agents/tools/code-review/code-simplifier.md and follow its instructions.

Target: $ARGUMENTS

**Key Principles:**
- Preserve exact functionality
- Clarity over brevity
- Remove obvious comments
- Apply project standards'

# --- Session Review ---
write_command "session-review" \
	"Review session for completeness before ending" \
	'Read ~/.aidevops/agents/scripts/commands/session-review.md and follow its instructions.

Review the current session for: $ARGUMENTS

**Checks:** All objectives completed, best practices followed, knowledge captured, next steps identified.'

# --- Remember / Recall ---
write_command "remember" \
	"Store a memory for cross-session recall" \
	'Read ~/.aidevops/agents/scripts/commands/remember.md and follow its instructions.

Remember: $ARGUMENTS

**Memory types:** WORKING_SOLUTION, FAILED_APPROACH, CODEBASE_PATTERN, USER_PREFERENCE, TOOL_CONFIG, DECISION, CONTEXT'

write_command "recall" \
	"Search memories from previous sessions" \
	'Read ~/.aidevops/agents/scripts/commands/recall.md and follow its instructions.

Search for: $ARGUMENTS

**Usage:** `/recall authentication`, `/recall --recent`, `/recall --stats`'

# --- Context ---
write_command "context" \
	"Build token-efficient AI context for complex tasks" \
	'Read ~/.aidevops/agents/tools/context/context-builder.md and follow its instructions.

Context request: $ARGUMENTS'

# --- List Keys ---
write_command "list-keys" \
	"List all API keys available in session with their storage locations" \
	'Run the list-keys helper script and format the output as a markdown table:

```bash
~/.aidevops/agents/scripts/list-keys-helper.sh --json $ARGUMENTS
```

Parse the JSON output and present as markdown tables grouped by source.
Security: Key values are NEVER displayed.'

# --- Create PRD ---
write_command "create-prd" \
	"Generate a Product Requirements Document for a feature" \
	'Read ~/.aidevops/agents/workflows/plans.md and follow its PRD generation instructions.

Feature to document: $ARGUMENTS'

# --- Generate Tasks ---
write_command "generate-tasks" \
	"Generate implementation tasks from a PRD" \
	'Read ~/.aidevops/agents/workflows/plans.md and follow its task generation instructions.

PRD or feature: $ARGUMENTS'

# --- Changelog ---
write_command "changelog" \
	"Update CHANGELOG.md following Keep a Changelog format" \
	'Read ~/.aidevops/agents/workflows/changelog.md and follow its instructions.

Action: $ARGUMENTS'

# --- SEO Commands ---
write_command "keyword-research" \
	"Keyword research with seed keyword expansion" \
	'Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Keywords to research: $ARGUMENTS'

write_command "keyword-research-extended" \
	"Full SERP analysis with weakness detection and KeywordScore" \
	'Read ~/.aidevops/agents/seo/keyword-research.md and follow its instructions.

Research target: $ARGUMENTS

**Modes:** Default (SERP analysis), `--domain`, `--competitor`, `--gap`
**Levels:** `--full` (default), `--quick`'

# --- Auto-discover commands from scripts/commands/ ---
COMMANDS_SRC_DIR="$HOME/.aidevops/agents/scripts/commands"

if [[ -d "$COMMANDS_SRC_DIR" ]]; then
	for cmd_file in "$COMMANDS_SRC_DIR"/*.md; do
		[[ -f "$cmd_file" ]] || continue

		cmd_name=$(basename "$cmd_file" .md)

		# Skip non-commands
		[[ "$cmd_name" == "SKILL" ]] && continue

		# Skip if already manually defined
		if [[ -f "$CLAUDE_COMMANDS_DIR/$cmd_name.md" ]]; then
			continue
		fi

		# Copy command file (adapt frontmatter for Claude Code format)
		# Claude Code uses: description (same), no agent/subtask fields
		# Strip OpenCode-specific frontmatter fields (agent, subtask)
		sed -E '/^---$/,/^---$/{/^(agent|subtask):/d;}' "$cmd_file" \
			>"$CLAUDE_COMMANDS_DIR/$cmd_name.md"

		((++command_count))
		echo -e "  ${GREEN}+${NC} /$cmd_name (auto-discovered)"
	done
fi

echo -e "  ${GREEN}Done${NC} — $command_count slash commands in $CLAUDE_COMMANDS_DIR"

# =============================================================================
# PHASE 2: MCP SERVER REGISTRATION
# =============================================================================
# Uses `claude mcp add-json <name> '<json>' -s user` for persistent registration.
# Only adds servers not already registered (idempotent).
# =============================================================================

echo -e "${BLUE}Registering MCP servers with Claude Code...${NC}"

mcp_count=0

# Get currently registered MCP servers (parse names from `claude mcp list`)
existing_mcps=""
if claude mcp list &>/dev/null; then
	existing_mcps=$(claude mcp list 2>/dev/null | grep -oE '^[a-zA-Z0-9_-]+:' | tr -d ':' || true)
fi

# Helper: register an MCP server if not already present
# Args: $1=name, $2=json_config
register_mcp() {
	local name="$1"
	local json_config="$2"

	# Check if already registered
	if echo "$existing_mcps" | grep -qx "$name" 2>/dev/null; then
		echo -e "  ${BLUE}=${NC} $name (already registered)"
		return 0
	fi

	if claude mcp add-json "$name" "$json_config" -s user 2>/dev/null; then
		((++mcp_count))
		echo -e "  ${GREEN}+${NC} $name"
	else
		echo -e "  ${YELLOW}!${NC} $name (registration failed)"
	fi
	return 0
}

# --- Augment Context Engine ---
if command -v auggie &>/dev/null; then
	local_auggie=$(command -v auggie)
	register_mcp "auggie-mcp" "{\"type\":\"stdio\",\"command\":\"$local_auggie\",\"args\":[\"--mcp\"]}"
fi

# --- context7 (library docs) ---
register_mcp "context7" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@upstash/context7-mcp@latest\"]}"

# --- Playwright MCP ---
register_mcp "playwright" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@anthropic-ai/mcp-server-playwright@latest\"]}"

# --- shadcn UI ---
register_mcp "shadcn" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"shadcn@latest\",\"mcp\"]}"

# --- OpenAPI Search (remote, zero install) ---
register_mcp "openapi-search" "{\"type\":\"sse\",\"url\":\"https://openapi-mcp.openapisearch.com/mcp\"}"

# --- macOS Automator (macOS only) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
	register_mcp "macos-automator" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@steipete/macos-automator-mcp@latest\"]}"
fi

# --- Cloudflare API (remote) ---
register_mcp "cloudflare-api" "{\"type\":\"sse\",\"url\":\"https://mcp.cloudflare.com/mcp\"}"

echo -e "  ${GREEN}Done${NC} — $mcp_count new MCP servers registered"

# =============================================================================
# PHASE 3: SETTINGS.JSON
# =============================================================================
# Manages ~/.claude/settings.json:
#   - Safety hooks (PreToolUse for Bash — git safety guard)
#   - Tool permissions (allow/deny/ask rules per Claude Code syntax)
#   - Preserves user customizations (model, etc.)
#
# Merge strategy: read existing, deep-merge new entries, never remove
# user-added rules. Uses Python for JSON manipulation (always available).
# =============================================================================

echo -e "${BLUE}Updating Claude Code settings...${NC}"

# Ensure directory exists
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

# Create minimal settings if file doesn't exist
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
	echo '{}' >"$CLAUDE_SETTINGS"
	chmod 600 "$CLAUDE_SETTINGS"
	echo -e "  ${GREEN}+${NC} Created $CLAUDE_SETTINGS"
fi

# Use Python for JSON manipulation (always available, jq may not be)
python3 <<'PYEOF'
import json
import os
import shutil
import sys

settings_path = os.path.expanduser("~/.claude/settings.json")

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

changed = False

# --- Safety hooks: PreToolUse for Bash ---
# Ensures the git safety guard hook is always present
hook_command = "$HOME/.aidevops/hooks/git_safety_guard.py"
hook_entry = {
    "type": "command",
    "command": hook_command
}
bash_matcher = {
    "matcher": "Bash",
    "hooks": [hook_entry]
}

if "hooks" not in settings:
    settings["hooks"] = {}
if "PreToolUse" not in settings["hooks"]:
    settings["hooks"]["PreToolUse"] = []

# Check if Bash matcher with our hook already exists
has_bash_hook = False
for rule in settings["hooks"]["PreToolUse"]:
    if rule.get("matcher") == "Bash":
        # Ensure our hook is in the hooks list
        existing_commands = [h.get("command", "") for h in rule.get("hooks", [])]
        if hook_command not in existing_commands:
            rule.setdefault("hooks", []).append(hook_entry)
            changed = True
        has_bash_hook = True
        break

if not has_bash_hook:
    settings["hooks"]["PreToolUse"].append(bash_matcher)
    changed = True

# --- Tool permissions (allow / deny / ask) ---
# Claude Code permission rule syntax: Tool or Tool(specifier)
# Rules evaluated: deny first, then ask, then allow. First match wins.
# Merge strategy: add our rules if not already present, never remove user rules.
#
# Design rationale:
#   allow  — safe read-only commands, aidevops scripts, common dev tools
#   deny   — secrets, credentials, destructive ops (defense-in-depth with hooks)
#   ask    — powerful but legitimate operations that benefit from confirmation
#
# Reference: https://docs.anthropic.com/en/docs/claude-code/settings

permissions = settings.setdefault("permissions", {})

# ---- ALLOW rules ----
# Safe operations that should never prompt the user
allow_rules = [
    # --- aidevops framework access ---
    "Read(~/.aidevops/**)",
    "Bash(~/.aidevops/agents/scripts/*)",

    # --- Read-only git commands ---
    "Bash(git status)",
    "Bash(git status *)",
    "Bash(git log *)",
    "Bash(git diff *)",
    "Bash(git diff)",
    "Bash(git branch *)",
    "Bash(git branch)",
    "Bash(git show *)",
    "Bash(git rev-parse *)",
    "Bash(git ls-files *)",
    "Bash(git ls-files)",
    "Bash(git remote -v)",
    "Bash(git stash list)",
    "Bash(git tag *)",
    "Bash(git tag)",

    # --- Safe git write operations ---
    "Bash(git add *)",
    "Bash(git add .)",
    "Bash(git commit *)",
    "Bash(git checkout -b *)",
    "Bash(git switch -c *)",
    "Bash(git switch *)",
    "Bash(git push *)",
    "Bash(git push)",
    "Bash(git pull *)",
    "Bash(git pull)",
    "Bash(git fetch *)",
    "Bash(git fetch)",
    "Bash(git merge *)",
    "Bash(git rebase *)",
    "Bash(git stash *)",
    "Bash(git worktree *)",
    "Bash(git branch -d *)",
    "Bash(git push --force-with-lease *)",
    "Bash(git push --force-if-includes *)",

    # --- GitHub CLI (read + PR operations) ---
    "Bash(gh pr *)",
    "Bash(gh issue *)",
    "Bash(gh run *)",
    "Bash(gh api *)",
    "Bash(gh repo *)",
    "Bash(gh auth status *)",
    "Bash(gh auth status)",

    # --- Common dev tools ---
    "Bash(npm run *)",
    "Bash(npm test *)",
    "Bash(npm test)",
    "Bash(npm install *)",
    "Bash(npm install)",
    "Bash(npm ci)",
    "Bash(npx *)",
    "Bash(bun *)",
    "Bash(pnpm *)",
    "Bash(yarn *)",
    "Bash(node *)",
    "Bash(python3 *)",
    "Bash(python *)",
    "Bash(pip *)",

    # --- File discovery and search ---
    "Bash(fd *)",
    "Bash(rg *)",
    "Bash(find *)",
    "Bash(grep *)",
    "Bash(wc *)",
    "Bash(ls *)",
    "Bash(ls)",
    "Bash(tree *)",

    # --- Quality tools ---
    "Bash(shellcheck *)",
    "Bash(eslint *)",
    "Bash(prettier *)",
    "Bash(tsc *)",

    # --- System info (read-only) ---
    "Bash(which *)",
    "Bash(command -v *)",
    "Bash(uname *)",
    "Bash(date *)",
    "Bash(pwd)",
    "Bash(whoami)",
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
    "Bash(sort *)",
    "Bash(uniq *)",
    "Bash(cut *)",
    "Bash(awk *)",
    "Bash(sed *)",
    "Bash(jq *)",
    "Bash(basename *)",
    "Bash(dirname *)",
    "Bash(realpath *)",
    "Bash(readlink *)",
    "Bash(stat *)",
    "Bash(file *)",
    "Bash(diff *)",
    "Bash(mkdir *)",
    "Bash(touch *)",
    "Bash(cp *)",
    "Bash(mv *)",
    "Bash(chmod *)",
    "Bash(echo *)",
    "Bash(printf *)",
    "Bash(test *)",
    "Bash([ *)",

    # --- Claude CLI (for sub-agent dispatch) ---
    "Bash(claude *)",
]

# ---- DENY rules ----
# Block access to secrets and destructive operations (defense-in-depth)
deny_rules = [
    # --- Secrets and credentials ---
    "Read(./.env)",
    "Read(./.env.*)",
    "Read(./secrets/**)",
    "Read(./**/credentials.json)",
    "Read(./**/.env)",
    "Read(./**/.env.*)",
    "Read(~/.config/aidevops/credentials.sh)",

    # --- Destructive git (also blocked by PreToolUse hook) ---
    "Bash(git push --force *)",
    "Bash(git push -f *)",
    "Bash(git reset --hard *)",
    "Bash(git reset --hard)",
    "Bash(git clean -f *)",
    "Bash(git clean -f)",
    "Bash(git checkout -- *)",
    "Bash(git branch -D *)",

    # --- Dangerous system commands ---
    "Bash(rm -rf /)",
    "Bash(rm -rf /*)",
    "Bash(rm -rf ~)",
    "Bash(rm -rf ~/*)",
    "Bash(sudo *)",
    "Bash(chmod 777 *)",

    # --- Secret exposure prevention ---
    "Bash(gopass show *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
]

# ---- ASK rules ----
# Powerful operations that benefit from user confirmation
ask_rules = [
    # --- Potentially destructive file operations ---
    "Bash(rm -rf *)",
    "Bash(rm -r *)",

    # --- Network operations ---
    "Bash(curl *)",
    "Bash(wget *)",

    # --- Docker/container operations ---
    "Bash(docker *)",
    "Bash(docker-compose *)",
    "Bash(orbctl *)",
]

# Merge function: add rules not already present, preserve user additions
def merge_rules(existing, new_rules):
    """Add new_rules to existing list if not already present. Returns True if changed."""
    added = False
    for rule in new_rules:
        if rule not in existing:
            existing.append(rule)
            added = True
    return added

# Also clean up any expanded-path rules from prior versions
# (e.g., /Users/foo/.aidevops/** should become ~/.aidevops/**)
home = os.path.expanduser("~")
existing_allow = permissions.get("allow", [])
cleaned_allow = []
for rule in existing_allow:
    if rule.startswith(home + "/"):
        # Convert expanded path to portable form
        portable = "Read(~" + rule[len(home):] + ")"
        # Only convert bare path patterns (not already Tool(specifier) format)
        if "(" not in rule:
            # This was a bare path from the old format — skip it,
            # the new rules below use proper Tool(specifier) syntax
            continue
    cleaned_allow.append(rule)

if len(cleaned_allow) != len(existing_allow):
    permissions["allow"] = cleaned_allow
    changed = True

allow_list = permissions.setdefault("allow", [])
deny_list = permissions.setdefault("deny", [])
ask_list = permissions.setdefault("ask", [])

if merge_rules(allow_list, allow_rules):
    changed = True
if merge_rules(deny_list, deny_rules):
    changed = True
if merge_rules(ask_list, ask_rules):
    changed = True

settings["permissions"] = permissions

# --- JSON Schema reference for editor autocomplete ---
if "$schema" not in settings:
    settings["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
    changed = True

# Write back if changed
if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print(f"  \033[0;32m+\033[0m Updated {settings_path}")
else:
    print(f"  \033[0;34m=\033[0m {settings_path} (no changes needed)")

PYEOF

echo -e "  ${GREEN}Done${NC} — settings.json updated"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Claude Code configuration complete!${NC}"
echo "  Slash commands: $command_count in $CLAUDE_COMMANDS_DIR"
echo "  MCP servers: $mcp_count newly registered (user scope)"
echo "  Settings: $CLAUDE_SETTINGS (hooks, plugins, tool permissions)"
echo ""
echo "Available slash commands (subset):"
echo "  /onboarding       - Interactive setup wizard"
echo "  /full-loop        - End-to-end development loop"
echo "  /preflight        - Quality checks before release"
echo "  /create-pr        - Create PR from current branch"
echo "  /release          - Full release workflow"
echo "  /remember         - Store cross-session memory"
echo "  /recall           - Search previous memories"
echo ""
echo "Run 'claude /help' to see all available commands."
