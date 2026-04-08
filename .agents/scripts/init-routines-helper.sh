#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# init-routines-helper.sh — scaffold a private routines repo and register it
#
# Usage:
#   init-routines-helper.sh [--org <name>] [--local] [--dry-run] [--help]
#
# Options:
#   --org <name>   Create per-org variant: <org>/aidevops-routines
#   --local        Create local-only repo (no remote, local_only: true)
#   --dry-run      Print what would be done without making changes
#   --help         Show this help message
#
# Without flags: creates personal <username>/aidevops-routines (always private)

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

REPOS_JSON="${HOME}/.config/aidevops/repos.json"
GIT_PARENT="${HOME}/Git"
DRY_RUN=false

# ---------------------------------------------------------------------------
# _write_todo_md <path>
# Creates TODO.md with Routines section header and format reference.
# ---------------------------------------------------------------------------
_write_todo_md() {
	local repo_path="$1"
	cat >"${repo_path}/TODO.md" <<'TODOEOF'
# Routines

Recurring operational jobs. Format reference: .agents/reference/routines.md

Fields:
  repeat: -- schedule: daily(@HH:MM), weekly(day@HH:MM), monthly(N@HH:MM), cron(expr)
  run:    -- deterministic script relative to ~/.aidevops/agents/
  agent:  -- LLM agent dispatched via headless-runtime-helper.sh
  [x] enabled, [ ] disabled/paused

## Routines

<!-- Add your routines below. Example:
- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
-->

## Tasks

<!-- Non-recurring tasks go here -->
TODOEOF
	return 0
}

# ---------------------------------------------------------------------------
# _write_issue_template <path>
# Creates .github/ISSUE_TEMPLATE/routine.md
# ---------------------------------------------------------------------------
_write_issue_template() {
	local repo_path="$1"
	cat >"${repo_path}/.github/ISSUE_TEMPLATE/routine.md" <<'TEMPLATEEOF'
---
name: Routine tracking
about: Track a recurring operational routine
title: "r000: <routine name>"
labels: routine
assignees: ''
---

## Routine

**ID:** r000
**Schedule:** repeat:weekly(mon@09:00)
**Script/Agent:** run:custom/scripts/example.sh or agent:Build+

## Description

What this routine does and why it exists.

## SOP

Step-by-step procedure.

## Targets

Who or what this routine applies to.

## Verification

How to confirm the routine ran successfully.
TEMPLATEEOF
	return 0
}

# ---------------------------------------------------------------------------
# scaffold_repo <path>
# Creates the standard routines repo structure at the given path.
# ---------------------------------------------------------------------------
scaffold_repo() {
	local repo_path="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would scaffold repo at: $repo_path"
		return 0
	fi

	mkdir -p "${repo_path}/routines"
	mkdir -p "${repo_path}/.github/ISSUE_TEMPLATE"

	_write_todo_md "$repo_path"

	# routines/.gitkeep
	touch "${repo_path}/routines/.gitkeep"

	# .gitignore
	cat >"${repo_path}/.gitignore" <<'GITIGNOREEOF'
# OS
.DS_Store
Thumbs.db

# Editor
.vscode/
.idea/
*.swp
*.swo

# Runtime
*.log
tmp/
GITIGNOREEOF

	_write_issue_template "$repo_path"

	print_success "Scaffolded repo at: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# register_repo <path> <slug> [local_only]
# Appends the repo to repos.json initialized_repos array.
# ---------------------------------------------------------------------------
register_repo() {
	local repo_path="$1"
	local slug="$2"
	local local_only="${3:-false}"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would register in repos.json: path=$repo_path slug=$slug local_only=$local_only"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found — skipping repos.json registration. Add manually:"
		echo "  path: $repo_path"
		echo "  slug: $slug"
		return 0
	fi

	# Ensure repos.json exists with correct structure
	if [[ ! -f "$REPOS_JSON" ]]; then
		mkdir -p "$(dirname "$REPOS_JSON")"
		echo '{"initialized_repos": [], "git_parent_dirs": ["~/Git"]}' >"$REPOS_JSON"
	fi

	# Check if already registered
	if jq -e --arg path "$repo_path" '.initialized_repos[] | select(.path == $path)' "$REPOS_JSON" &>/dev/null; then
		print_info "Already registered in repos.json: $repo_path"
		return 0
	fi

	local tmp_json
	tmp_json=$(mktemp)

	local maintainer=""
	if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		maintainer=$(gh api user --jq '.login' 2>/dev/null || echo "")
	fi

	local jq_filter
	# shellcheck disable=SC2016  # jq uses $path/$slug/$maintainer as jq vars, not shell vars
	if [[ "$local_only" == "true" ]]; then
		jq_filter='.initialized_repos += [{
		  "path": $path,
		  "slug": $slug,
		  "pulse": true,
		  "priority": "tooling",
		  "local_only": true,
		  "maintainer": $maintainer,
		  "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		}]'
	else
		jq_filter='.initialized_repos += [{
		  "path": $path,
		  "slug": $slug,
		  "pulse": true,
		  "priority": "tooling",
		  "maintainer": $maintainer,
		  "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		}]'
	fi

	jq --arg path "$repo_path" \
		--arg slug "$slug" \
		--arg maintainer "$maintainer" \
		"$jq_filter" "$REPOS_JSON" >"$tmp_json"

	if jq empty "$tmp_json" 2>/dev/null; then
		mv "$tmp_json" "$REPOS_JSON"
		print_success "Registered in repos.json: $slug"
	else
		print_error "repos.json write produced invalid JSON — aborting (GH#16746)"
		rm -f "$tmp_json"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _commit_and_push <path>
# Commits scaffolded files and pushes to remote.
# ---------------------------------------------------------------------------
_commit_and_push() {
	local repo_path="$1"
	(
		cd "$repo_path"
		git add -A
		if ! git diff --cached --quiet; then
			git commit -m "chore: scaffold aidevops-routines repo"
			git push origin HEAD 2>&1 || print_warning "Push failed — commit exists locally"
		fi
	)
	return 0
}

# ---------------------------------------------------------------------------
# _check_gh_auth
# Returns 0 if gh CLI is available and authenticated, 1 otherwise.
# ---------------------------------------------------------------------------
_check_gh_auth() {
	if ! command -v gh &>/dev/null; then
		print_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		print_error "Not authenticated with gh. Run: gh auth login"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _ensure_gh_repo <slug> <description>
# Creates the GitHub repo if it doesn't exist. Always private.
# ---------------------------------------------------------------------------
_ensure_gh_repo() {
	local slug="$1"
	local description="$2"
	if gh repo view "$slug" &>/dev/null 2>&1; then
		print_info "Repo already exists on GitHub: $slug"
		return 0
	fi
	gh repo create "$slug" --private --description "$description" 2>&1
	print_success "Created GitHub repo: $slug"
	return 0
}

# ---------------------------------------------------------------------------
# _ensure_cloned <slug> <path>
# Clones the repo if not already present locally.
# ---------------------------------------------------------------------------
_ensure_cloned() {
	local slug="$1"
	local repo_path="$2"
	if [[ -d "$repo_path/.git" ]]; then
		print_info "Repo already cloned at: $repo_path"
		return 0
	fi
	mkdir -p "$GIT_PARENT"
	gh repo clone "$slug" "$repo_path" 2>&1
	print_success "Cloned to: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_personal
# Creates <username>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_personal() {
	_check_gh_auth || return 1

	local username
	username=$(gh api user --jq '.login' 2>/dev/null)
	if [[ -z "$username" ]]; then
		print_error "Could not detect GitHub username"
		return 1
	fi

	local slug="${username}/aidevops-routines"
	local repo_path="${GIT_PARENT}/aidevops-routines"

	print_info "Creating personal routines repo: $slug"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create: gh repo create $slug --private"
		print_info "[dry-run] Would clone to: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug"
		return 0
	fi

	_ensure_gh_repo "$slug" "Private routines"
	_ensure_cloned "$slug" "$repo_path"
	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug"
	_commit_and_push "$repo_path"

	print_success "Personal routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_org <org_name>
# Creates <org>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_org() {
	local org_name="$1"

	_check_gh_auth || return 1

	local slug="${org_name}/aidevops-routines"
	local repo_path="${GIT_PARENT}/${org_name}-aidevops-routines"

	print_info "Creating org routines repo: $slug"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create: gh repo create $slug --private"
		print_info "[dry-run] Would clone to: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug"
		return 0
	fi

	_ensure_gh_repo "$slug" "Private routines (${org_name})"
	_ensure_cloned "$slug" "$repo_path"
	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug"
	_commit_and_push "$repo_path"

	print_success "Org routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_local
# Creates a local-only git repo (no remote), scaffolds, registers with local_only: true.
# ---------------------------------------------------------------------------
init_local() {
	local repo_path="${GIT_PARENT}/aidevops-routines"
	local slug="local/aidevops-routines"

	print_info "Creating local-only routines repo at: $repo_path"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would git init at: $repo_path"
		scaffold_repo "$repo_path"
		register_repo "$repo_path" "$slug" "true"
		return 0
	fi

	if [[ ! -d "$repo_path/.git" ]]; then
		mkdir -p "$repo_path"
		git -C "$repo_path" init
		print_success "Initialized local git repo at: $repo_path"
	else
		print_info "Repo already exists at: $repo_path"
	fi

	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug" "true"

	# Initial commit
	(
		cd "$repo_path"
		git add -A
		if ! git diff --cached --quiet; then
			git commit -m "chore: scaffold aidevops-routines repo"
		fi
	)

	print_success "Local routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# _prompt_org <org>
# Prompts user to create org routines repo. Returns 0 to create, 1 to skip.
# ---------------------------------------------------------------------------
_prompt_org() {
	local org="$1"
	local org_slug="${org}/aidevops-routines"

	# Check if already registered
	if command -v jq &>/dev/null && [[ -f "$REPOS_JSON" ]]; then
		if jq -e --arg slug "$org_slug" '.initialized_repos[] | select(.slug == $slug)' "$REPOS_JSON" &>/dev/null; then
			print_info "Org routines repo already registered: $org_slug"
			return 1
		fi
	fi

	print_info "Create routines repo for org: $org? [y/N] "
	local response
	read -r response || response="n"
	case "$response" in
	[yY] | [yY][eE][sS])
		return 0
		;;
	*)
		print_info "Skipping org: $org"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# detect_and_create_all
# Setup integration: detect username + admin orgs, create all routines repos.
# In non-interactive mode: only creates personal repo.
# ---------------------------------------------------------------------------
detect_and_create_all() {
	local non_interactive="${1:-false}"

	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		print_warning "gh CLI not available or not authenticated — skipping routines repo creation"
		return 0
	fi

	local username
	username=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$username" ]]; then
		print_warning "Could not detect GitHub username — skipping routines repo creation"
		return 0
	fi

	# Always create personal repo
	init_personal

	if [[ "$non_interactive" == "true" ]]; then
		print_info "Non-interactive mode: skipping org repos (run 'aidevops init-routines --org <name>')"
		return 0
	fi

	# Detect admin orgs
	local admin_orgs
	admin_orgs=$(gh api user/memberships/orgs --jq '.[] | select(.role == "admin") | .organization.login' 2>/dev/null || echo "")

	[[ -z "$admin_orgs" ]] && return 0

	while IFS= read -r org; do
		[[ -z "$org" ]] && continue
		if _prompt_org "$org"; then
			init_org "$org"
		fi
	done <<<"$admin_orgs"

	return 0
}

# ---------------------------------------------------------------------------
# show_help
# ---------------------------------------------------------------------------
show_help() {
	cat <<'HELPEOF'
init-routines-helper.sh -- scaffold a private routines repo

Usage:
  init-routines-helper.sh [options]

Options:
  --org <name>   Create per-org variant: <org>/aidevops-routines (always private)
  --local        Create local-only repo (no remote, local_only: true in repos.json)
  --dry-run      Print what would be done without making changes
  --help         Show this help message

Without flags: creates personal <username>/aidevops-routines (always private).

Scaffolded structure:
  ~/Git/aidevops-routines/
  |- TODO.md              # Routine definitions with repeat: fields
  |- routines/            # YAML specs
  |  `- .gitkeep
  |- .gitignore
  `- .github/
     `- ISSUE_TEMPLATE/
        `- routine.md

The repo is registered in ~/.config/aidevops/repos.json with:
  pulse: true, priority: "tooling"

Privacy: always private -- no flag to make public.

Examples:
  init-routines-helper.sh                  # Personal repo
  init-routines-helper.sh --org mycompany  # Org repo
  init-routines-helper.sh --local          # Local-only (no remote)
  init-routines-helper.sh --dry-run        # Preview without changes
HELPEOF
	return 0
}

# ---------------------------------------------------------------------------
# _parse_args <args...>
# Parse command-line arguments. Sets MODE and ORG_NAME globals.
# ---------------------------------------------------------------------------
MODE="personal"
ORG_NAME=""

_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--org)
			MODE="org"
			ORG_NAME="${2:-}"
			if [[ -z "$ORG_NAME" ]]; then
				print_error "--org requires an organization name"
				exit 1
			fi
			shift 2
			;;
		--local)
			MODE="local"
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			print_error "Unknown option: $1"
			echo "Run with --help for usage."
			exit 1
			;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	_parse_args "$@"

	case "$MODE" in
	personal)
		init_personal
		;;
	org)
		init_org "$ORG_NAME"
		;;
	local)
		init_local
		;;
	esac

	return 0
}

main "$@"
