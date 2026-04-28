#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contributor Activity Helper -- Orchestrator
# =============================================================================
# Compute contributor activity from git history, AI session databases, and
# GitHub Search API. This orchestrator sources three focused sub-libraries:
#
#   contributor-activity-helper-activity.sh  -- git commit activity
#   contributor-activity-helper-session.sh   -- AI session time tracking
#   contributor-activity-helper-person.sh    -- GitHub API person stats
#
# Sources activity data exclusively from immutable git commit history to prevent
# manipulation. Each contributor's activity is measured by commits, active days,
# and commit type (direct vs PR merges). Only default-branch commits are counted
# to avoid double-counting squash-merged PR commits (branch originals + merge).
#
# Commit type detection uses the committer email field:
#   - committer=noreply@github.com -> GitHub squash-merged a PR (automated output)
#   - committer=actions@github.com -> GitHub Actions (bot, filtered out)
#   - committer=author's own email -> direct push (human or headless CLI)
#
# GitHub noreply emails (NNN+login@users.noreply.github.com) are used to map
# git author names to GitHub logins, normalising multiple author name variants
# (e.g., "Marcus Quinn" and "marcusquinn" both map to "marcusquinn").
#
# Session time tracking uses the AI assistant database (OpenCode/Claude Code)
# to measure interactive (human) vs worker/runner (headless) session hours.
# Session type is classified by title pattern matching.
#
# Usage:
#   contributor-activity-helper.sh summary <repo-path> [--period day|week|month|year]
#   contributor-activity-helper.sh table <repo-path> [--format markdown|json]
#   contributor-activity-helper.sh user <repo-path> <github-login>
#   contributor-activity-helper.sh cross-repo-summary <repo-path1> [<repo-path2> ...] [--period month]
#   contributor-activity-helper.sh session-time <repo-path> [--period month] [--all-dirs]
#   contributor-activity-helper.sh cross-repo-session-time <path1> [path2 ...] [--period month]
#   contributor-activity-helper.sh person-stats <repo-path> [--period month] [--logins a,b]
#   contributor-activity-helper.sh cross-repo-person-stats <path1> [path2 ...] [--period month]
#
# Output: markdown table or JSON suitable for embedding in health issues.
#
# Exit codes:
#   0  - success (complete results)
#   1  - error (invalid args, missing repo, etc.)
#   75 - partial results (EX_TEMPFAIL from sysexits.h) -- rate limit exhausted
#        mid-run. Stdout still contains valid output but may be truncated.
#        JSON output includes "partial": true. Markdown output includes an
#        HTML comment <!-- partial-results --> for machine-readable detection.
#        Callers should cache partial data but mark it as incomplete.

set -euo pipefail

# t2458: source sanitize_url / scrub_credentials from shared-constants.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Distinct exit code for partial results (rate limit exhaustion mid-run).
# Callers can distinguish "complete success" (0) from "valid but truncated" (75)
# from "error" (1). 75 = EX_TEMPFAIL from sysexits.h -- a temporary failure
# that may succeed on retry.
readonly EX_PARTIAL=75

# Shared Python helper functions injected into all Python blocks to avoid
# duplication. Defined once here, passed via sys.argv to each invocation.
# shellcheck disable=SC2016
PYTHON_HELPERS='
def email_to_login(email):
    """Map git email to GitHub login. Normalises noreply emails."""
    if email.endswith("@users.noreply.github.com"):
        local_part = email.split("@")[0]
        return local_part.split("+", 1)[1] if "+" in local_part else local_part
    if email in ("actions@github.com", "action@github.com"):
        return "github-actions"
    return email.split("@")[0]

def is_bot(login):
    """Check if a login belongs to a bot account."""
    if login == "github-actions":
        return True
    if login.endswith("[bot]") or login.endswith("-bot"):
        return True
    return False

def is_pr_merge(committer_email):
    """Detect GitHub squash-merge (committer=noreply@github.com)."""
    return committer_email == "noreply@github.com"
'

#######################################
# Resolve the default branch for a repo
#
# Tries origin/HEAD first (set by clone), falls back to checking for
# main/master branches. Works correctly from worktrees on non-default
# branches, which is critical since this script is called from headless
# workers and worktrees.
#
# Arguments:
#   $1 - repo path
# Output: default branch name (e.g., "main") to stdout
#######################################
_resolve_default_branch() {
	local repo_path="$1"
	local default_branch=""

	# Try origin/HEAD (most reliable -- set by git clone)
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch=""

	# Fallback: check for main, then master
	if [[ -z "$default_branch" ]]; then
		if git -C "$repo_path" rev-parse --verify "refs/heads/main" &>/dev/null; then
			default_branch="main"
		elif git -C "$repo_path" rev-parse --verify "refs/heads/master" &>/dev/null; then
			default_branch="master"
		else
			default_branch="main"
		fi
	fi

	echo "$default_branch"
	return 0
}

_period_to_since_arg() {
	local period="$1"
	case "$period" in
	day) echo "--since=1.day.ago" ;;
	week) echo "--since=1.week.ago" ;;
	month) echo "--since=1.month.ago" ;;
	year) echo "--since=1.year.ago" ;;
	*) echo "--since=1.month.ago" ;;
	esac
	return 0
}

# --- Source sub-libraries ---

# shellcheck source=./contributor-activity-helper-activity.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contributor-activity-helper-activity.sh"

# shellcheck source=./contributor-activity-helper-session.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contributor-activity-helper-session.sh"

# shellcheck source=./contributor-activity-helper-person.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/contributor-activity-helper-person.sh"

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	summary | table)
		local repo_path="${1:-.}"
		shift || true
		local period="month"
		local format="markdown"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--period)
				period="${2:-month}"
				shift 2
				;;
			--format)
				format="${2:-markdown}"
				shift 2
				;;
			*)
				shift
				;;
			esac
		done
		compute_activity "$repo_path" "$period" "$format"
		;;
	user)
		local repo_path="${1:-.}"
		local login="${2:-}"
		if [[ -z "$login" ]]; then
			echo "Usage: $0 user <repo-path> <github-login>" >&2
			return 1
		fi
		user_activity "$repo_path" "$login"
		;;
	cross-repo-summary)
		cross_repo_summary "$@"
		;;
	session-time)
		session_time "$@"
		;;
	cross-repo-session-time)
		cross_repo_session_time "$@"
		;;
	person-stats)
		person_stats "$@"
		;;
	cross-repo-person-stats)
		cross_repo_person_stats "$@"
		;;
	help | *)
		echo "Usage: $0 <command> [options]"
		echo ""
		echo "Commands:"
		echo "  summary <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  table   <repo-path> [--period day|week|month|year] [--format markdown|json]"
		echo "  user    <repo-path> <github-login>"
		echo "  cross-repo-summary <path1> [path2 ...] [--period month] [--format markdown]"
		echo "  session-time <repo-path> [--period day|week|month|quarter|year|all] [--format markdown|json] [--all-dirs]"
		echo "  cross-repo-session-time <path1> [path2 ...] [--period month|all] [--format markdown|json]"
		echo "  person-stats <repo-path> [--period day|week|month|quarter|year] [--format markdown|json] [--logins a,b]"
		echo "  cross-repo-person-stats <path1> [path2 ...] [--period month] [--format markdown|json] [--logins a,b]"
		echo ""
		echo "Computes contributor commit activity from default-branch git history."
		echo "Only default-branch commits are counted (no --all) to avoid"
		echo "double-counting squash-merged PR commits."
		echo "Session time stats from AI assistant database (OpenCode/Claude Code)."
		echo "Per-person GitHub output stats from GitHub Search API."
		echo "GitHub noreply emails are used to normalise author names to logins."
		echo ""
		echo "Commit types:"
		echo "  Direct Pushes - committer is the author (push, CLI commit)"
		echo "  PRs Merged    - committer is noreply@github.com (GitHub squash-merge)"
		echo ""
		echo "Session time (human vs machine):"
		echo "  Human hours   - time spent reading, thinking, typing (between AI responses)"
		echo "  Machine hours - time AI spent generating responses"
		echo "  Interactive   - human-driven sessions (conversations, debugging)"
		echo "  Worker        - headless dispatched tasks (Issue #N, PR #N, Supervisor Pulse)"
		echo ""
		echo "Person stats (GitHub output per contributor):"
		echo "  Issues    - issues created by this person"
		echo "  PRs       - pull requests created by this person"
		echo "  Merged    - pull requests merged (authored by this person)"
		echo "  Commented - unique issues/PRs this person commented on"
		return 0
		;;
	esac

	return 0
}

main "$@"
