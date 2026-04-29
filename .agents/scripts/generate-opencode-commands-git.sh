#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Generate OpenCode Commands -- Git & Release
# =============================================================================
# Git workflow, branch, PR, and release command definitions for OpenCode.
#
# Usage: source "${SCRIPT_DIR}/generate-opencode-commands-git.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - create_command() from the orchestrator
#   - AGENT_BUILD constant from the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OPENCODE_CMDS_GIT_LOADED:-}" ]] && return 0
_OPENCODE_CMDS_GIT_LOADED=1

# --- Git & Release Commands ---
# Split into release, branch, and PR sub-groups.

define_release_commands() {
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

	create_command "version-bump" \
		"Bump project version (major, minor, or patch)" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/version-bump.md and follow its instructions.

Bump type: $ARGUMENTS

Valid types: major, minor, patch

This updates:
1. VERSION file
2. package.json (if exists)
3. Other version references as configured
BODY

	create_command "changelog" \
		"Update CHANGELOG.md following Keep a Changelog format" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/changelog.md and follow its instructions.

Action: $ARGUMENTS

This maintains CHANGELOG.md with:
- Unreleased section for pending changes
- Version sections with dates
- Categories: Added, Changed, Deprecated, Removed, Fixed, Security
BODY

	return 0
}

define_branch_commands() {
	create_command "feature" \
		"Create and develop a feature branch" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/branch/feature.md and follow its instructions.

Feature: $ARGUMENTS

This will:
1. Create feature branch from main
2. Set up development environment
3. Guide feature implementation
BODY

	create_command "bugfix" \
		"Create and resolve a bugfix branch" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/branch/bugfix.md and follow its instructions.

Bug: $ARGUMENTS

This will:
1. Create bugfix branch
2. Guide bug investigation
3. Implement and test fix
BODY

	create_command "hotfix" \
		"Urgent hotfix for critical production issues" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/branch/hotfix.md and follow its instructions.

Issue: $ARGUMENTS

This will:
1. Create hotfix branch from main/production
2. Implement minimal fix
3. Fast-track to release
BODY

	return 0
}

define_pr_commands() {
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

	create_command "pr" \
		"Alias for /create-pr - Create PR from current branch" \
		"$AGENT_BUILD" "" <<'BODY'
This is an alias for /create-pr. Creating PR from current branch.

Context: $ARGUMENTS

Run /create-pr with the same arguments.
BODY

	return 0
}

define_git_commands() {
	define_release_commands
	define_branch_commands
	define_pr_commands
	return 0
}
