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

	# TODO.md with Routines section header and format reference
	cat >"${repo_path}/TODO.md" <<'TODOEOF'
# Routines

Recurring operational jobs. Format reference: `.agents/reference/routines.md`

- `repeat:` — schedule: `daily(@HH:MM)`, `weekly(day@HH:MM)`, `monthly(N@HH:MM)`, `cron(expr)`
- `run:` — deterministic script relative to `~/.aidevops/agents/`
- `agent:` — LLM agent dispatched with `headless-runtime-helper.sh`
- `[x]` enabled, `[ ]` disabled/paused

## Routines

<!-- Add your routines below. Example:
- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
-->

## Tasks

<!-- Non-recurring tasks go here -->
TODOEOF

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

	# .github/ISSUE_TEMPLATE/routine.md
	cat >"${repo_path}/.github/ISSUE_TEMPLATE/routine.md" <<'TEMPLATEEOF'
---
name: Routine tracking
about: Track a recurring operational routine
title: "r000: <routine name>"
labels: routine
assignees: ''
---

## Routine

**ID:** `r000`
**Schedule:** `repeat:weekly(mon@09:00)`
**Script/Agent:** `run:custom/scripts/example.sh` or `agent:Build+`

## Description

What this routine does and why it exists.

## SOP

Step-by-step procedure for the routine.

## Targets

Who or what this routine applies to.

## Verification

How to confirm the routine ran successfully.
TEMPLATEEOF

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

	if [[ "$local_only" == "true" ]]; then
		jq --arg path "$repo_path" \
			--arg slug "$slug" \
			--arg maintainer "$maintainer" \
			'.initialized_repos += [{
		     "path": $path,
		     "slug": $slug,
		     "pulse": true,
		     "priority": "tooling",
		     "local_only": true,
		     "maintainer": $maintainer,
		     "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		   }]' "$REPOS_JSON" >"$tmp_json"
	else
		jq --arg path "$repo_path" \
			--arg slug "$slug" \
			--arg maintainer "$maintainer" \
			'.initialized_repos += [{
		     "path": $path,
		     "slug": $slug,
		     "pulse": true,
		     "priority": "tooling",
		     "maintainer": $maintainer,
		     "initialized": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		   }]' "$REPOS_JSON" >"$tmp_json"
	fi

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
# init_personal
# Creates <username>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_personal() {
	if ! command -v gh &>/dev/null; then
		print_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi

	if ! gh auth status &>/dev/null 2>&1; then
		print_error "Not authenticated with gh. Run: gh auth login"
		return 1
	fi

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

	# Check if repo already exists on GitHub
	if gh repo view "$slug" &>/dev/null 2>&1; then
		print_info "Repo already exists on GitHub: $slug"
	else
		gh repo create "$slug" --private --description "Private routines for aidevops" 2>&1
		print_success "Created GitHub repo: $slug"
	fi

	# Clone if not already present
	if [[ -d "$repo_path/.git" ]]; then
		print_info "Repo already cloned at: $repo_path"
	else
		mkdir -p "$GIT_PARENT"
		gh repo clone "$slug" "$repo_path" 2>&1
		print_success "Cloned to: $repo_path"
	fi

	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug"

	# Commit and push scaffold
	if [[ -d "$repo_path/.git" ]]; then
		(
			cd "$repo_path"
			git add -A
			if ! git diff --cached --quiet; then
				git commit -m "chore: scaffold aidevops-routines repo"
				git push origin HEAD 2>&1 || print_warning "Push failed — commit exists locally"
			fi
		)
	fi

	print_success "Personal routines repo ready: $repo_path"
	return 0
}

# ---------------------------------------------------------------------------
# init_org <org_name>
# Creates <org>/aidevops-routines on GitHub (private), clones, scaffolds.
# ---------------------------------------------------------------------------
init_org() {
	local org_name="$1"

	if ! command -v gh &>/dev/null; then
		print_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi

	if ! gh auth status &>/dev/null 2>&1; then
		print_error "Not authenticated with gh. Run: gh auth login"
		return 1
	fi

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

	# Check if repo already exists on GitHub
	if gh repo view "$slug" &>/dev/null 2>&1; then
		print_info "Repo already exists on GitHub: $slug"
	else
		gh repo create "$slug" --private --description "Private routines for aidevops (${org_name})" 2>&1
		print_success "Created GitHub repo: $slug"
	fi

	# Clone if not already present
	if [[ -d "$repo_path/.git" ]]; then
		print_info "Repo already cloned at: $repo_path"
	else
		mkdir -p "$GIT_PARENT"
		gh repo clone "$slug" "$repo_path" 2>&1
		print_success "Cloned to: $repo_path"
	fi

	scaffold_repo "$repo_path"
	register_repo "$repo_path" "$slug"

	# Commit and push scaffold
	if [[ -d "$repo_path/.git" ]]; then
		(
			cd "$repo_path"
			git add -A
			if ! git diff --cached --quiet; then
				git commit -m "chore: scaffold aidevops-routines repo"
				git push origin HEAD 2>&1 || print_warning "Push failed — commit exists locally"
			fi
		)
	fi

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

	if [[ -d "$repo_path/.git" ]]; then
		print_info "Repo already exists at: $repo_path"
	else
		mkdir -p "$repo_path"
		git -C "$repo_path" init
		print_success "Initialized local git repo at: $repo_path"
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
# detect_and_create_all
# For setup integration: detect username + admin orgs, create all routines repos.
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

	# Org repos require interactive confirmation
	if [[ "$non_interactive" == "true" ]]; then
		print_info "Non-interactive mode: skipping org routines repos (run 'aidevops init-routines --org <name>' for each org)"
		return 0
	fi

	# Detect admin orgs
	local admin_orgs
	admin_orgs=$(gh api user/memberships/orgs --jq '.[] | select(.role == "admin") | .organization.login' 2>/dev/null || echo "")

	if [[ -z "$admin_orgs" ]]; then
		return 0
	fi

	while IFS= read -r org; do
		[[ -z "$org" ]] && continue
		local org_slug="${org}/aidevops-routines"
		# Check if already registered
		if command -v jq &>/dev/null && [[ -f "$REPOS_JSON" ]]; then
			if jq -e --arg slug "$org_slug" '.initialized_repos[] | select(.slug == $slug)' "$REPOS_JSON" &>/dev/null; then
				print_info "Org routines repo already registered: $org_slug"
				continue
			fi
		fi
		print_info "Create routines repo for org: $org? [y/N] "
		local response
		read -r response || response="n"
		case "$response" in
		[yY] | [yY][eE][sS])
			init_org "$org"
			;;
		*)
			print_info "Skipping org: $org"
			;;
		esac
	done <<<"$admin_orgs"

	return 0
}

# ---------------------------------------------------------------------------
# show_help
# ---------------------------------------------------------------------------
show_help() {
	cat <<'HELPEOF'
init-routines-helper.sh — scaffold a private routines repo

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
  ├── TODO.md              # Routine definitions with repeat: fields
  ├── routines/            # YAML specs for complex routines
  │   └── .gitkeep
  ├── .gitignore
  └── .github/
      └── ISSUE_TEMPLATE/
          └── routine.md   # Template for routine tracking issues

The repo is registered in ~/.config/aidevops/repos.json with:
  pulse: true, priority: "tooling"

Privacy: always private — no flag to make public.

Examples:
  init-routines-helper.sh                  # Personal repo
  init-routines-helper.sh --org mycompany  # Org repo
  init-routines-helper.sh --local          # Local-only (no remote)
  init-routines-helper.sh --dry-run        # Preview without changes
HELPEOF
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local mode="personal"
	local org_name=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--org)
			mode="org"
			org_name="${2:-}"
			if [[ -z "$org_name" ]]; then
				print_error "--org requires an organization name"
				exit 1
			fi
			shift 2
			;;
		--local)
			mode="local"
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

	case "$mode" in
	personal)
		init_personal
		;;
	org)
		init_org "$org_name"
		;;
	local)
		init_local
		;;
	esac

	return 0
}

main "$@"
