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
# SCRIPT_DIR: resolve from BASH_SOURCE when available, fall back to deployed path
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "$0" || -f "${BASH_SOURCE[0]}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
	SCRIPT_DIR="${HOME}/.aidevops/agents/scripts"
fi

# ---------------------------------------------------------------------------
# _write_todo_md <path>
# Creates TODO.md with Routines section header, format reference, and
# seeded core routine entries from core-routines.sh.
# ---------------------------------------------------------------------------
_write_todo_md() {
	local repo_path="$1"

	# Header
	cat >"${repo_path}/TODO.md" <<'TODOEOF'
# Routines

Recurring operational jobs. Format reference: .agents/reference/routines.md

Fields:
  repeat: -- schedule: daily(@HH:MM), weekly(day@HH:MM), monthly(N@HH:MM), cron(expr)
  run:    -- deterministic script relative to ~/.aidevops/agents/
  agent:  -- LLM agent dispatched via headless-runtime-helper.sh
  [x] enabled, [ ] disabled/paused

## Core Routines (framework-managed)

<!-- These routines are managed by aidevops setup. They reflect the launchd
     jobs installed by setup.sh. Edit the enabled/disabled state here;
     the schedule and script are authoritative in the launchd plist. -->

TODOEOF

	# Seed core routine entries if core-routines.sh is available
	if [[ -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
		source "${SCRIPT_DIR}/routines/core-routines.sh"
		local line
		while IFS='|' read -r rid enabled title schedule estimate script rtype; do
			[[ -z "$rid" ]] && continue
			echo "- [${enabled}] ${rid} ${title} ${schedule} ${estimate} run:${script}" >>"${repo_path}/TODO.md"
		done < <(get_core_routine_entries)
	fi

	# User routines section + tasks
	cat >>"${repo_path}/TODO.md" <<'TODOEOF'

## User Routines

<!-- Add your own routines below. Use r001-r899 for user routines.
     Core routines use r901+ to avoid ID collisions. Example:
- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
-->

## Tasks

<!-- Non-recurring tasks go here -->
TODOEOF
	return 0
}

# ---------------------------------------------------------------------------
# _seed_routine_descriptions <repo_path>
# Writes core routine description .md files into routines/core/.
# Also creates routines/custom/ for user overrides.
# ---------------------------------------------------------------------------
_seed_routine_descriptions() {
	local repo_path="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would seed routine descriptions into: ${repo_path}/routines/"
		return 0
	fi

	mkdir -p "${repo_path}/routines/core"
	mkdir -p "${repo_path}/routines/custom"

	# Custom dir README
	if [[ ! -f "${repo_path}/routines/custom/README.md" ]]; then
		cat >"${repo_path}/routines/custom/README.md" <<'CUSTOMEOF'
# Custom Routine Descriptions

Place your own routine description files here as `<routine-id>.md` (e.g., `r001.md`).

Custom descriptions override core descriptions when both exist for the same ID.
Use the template at `~/.aidevops/agents/templates/routine-description-template.md`
as a starting point, or copy and modify a core description from `../core/`.

These files survive framework updates — core descriptions may be refreshed,
but custom descriptions are never overwritten.
CUSTOMEOF
	fi

	# Write core descriptions from core-routines.sh describe_* functions
	if [[ ! -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		print_warning "core-routines.sh not found — skipping description seeding"
		return 0
	fi

	# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
	source "${SCRIPT_DIR}/routines/core-routines.sh"

	# Detect OS for platform-specific descriptions
	local detected_os
	detected_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	# Normalise: Darwin → darwin, Linux → linux
	case "$detected_os" in
	darwin) detected_os="darwin" ;;
	*) detected_os="linux" ;;
	esac

	local rid
	while IFS='|' read -r rid _ _ _ _ _ _; do
		[[ -z "$rid" ]] && continue
		local describe_fn="describe_${rid}"
		if declare -f "$describe_fn" &>/dev/null; then
			"$describe_fn" "$detected_os" >"${repo_path}/routines/core/${rid}.md"
		fi
	done < <(get_core_routine_entries)

	print_success "Seeded routine descriptions into: ${repo_path}/routines/"
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
	_seed_routine_descriptions "$repo_path"

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
# _create_core_routine_issues <slug>
# Creates GitHub issues for each core routine using routine-log-helper.sh.
# Skipped for local-only repos. Idempotent — routine-log-helper checks state.
# ---------------------------------------------------------------------------
_create_core_routine_issues() {
	local slug="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[dry-run] Would create GitHub issues for core routines in: $slug"
		return 0
	fi

	local log_helper="${SCRIPT_DIR}/routine-log-helper.sh"
	if [[ ! -f "$log_helper" ]]; then
		print_warning "routine-log-helper.sh not found — skipping issue creation"
		return 0
	fi

	if [[ ! -f "${SCRIPT_DIR}/routines/core-routines.sh" ]]; then
		print_warning "core-routines.sh not found — skipping issue creation"
		return 0
	fi

	# Ensure the routines label exists on the repo
	gh label create "routines" --repo "$slug" --description "Routine tracking" --color "0E8A16" 2>/dev/null || true
	gh label create "core" --repo "$slug" --description "Framework-managed routine" --color "1D76DB" 2>/dev/null || true

	# shellcheck disable=SC1091  # sourced file path is dynamic but verified above
	source "${SCRIPT_DIR}/routines/core-routines.sh"

	local rid enabled title schedule estimate script rtype
	while IFS='|' read -r rid enabled title schedule estimate script rtype; do
		[[ -z "$rid" ]] && continue
		# Extract short title (before the em dash if present)
		local short_title
		short_title=$(echo "$title" | sed 's/ —.*//')

		print_info "Creating issue for ${rid}: ${short_title}..."
		bash "$log_helper" create-issue "$rid" \
			--repo "$slug" \
			--title "${rid}: ${short_title}" \
			--schedule "$schedule" \
			--type "$rtype" 2>&1 || print_warning "Issue creation failed for ${rid} (may already exist)"
	done < <(get_core_routine_entries)

	print_success "Core routine issues created in: $slug"
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
	_create_core_routine_issues "$slug"

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
	_create_core_routine_issues "$slug"

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
# Non-interactive mode: scaffolds local repo + creates personal GH remote only.
# Interactive mode: personal repo + prompts for each admin org.
# Falls back to local-only if gh CLI is unavailable.
# ---------------------------------------------------------------------------
detect_and_create_all() {
	local non_interactive="${1:-false}"

	# If gh is unavailable, fall back to local-only scaffolding so the repo
	# structure exists even without a GitHub remote.
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		print_warning "gh CLI not available or not authenticated — creating local-only routines repo"
		init_local
		return 0
	fi

	local username
	username=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$username" ]]; then
		print_warning "Could not detect GitHub username — creating local-only routines repo"
		init_local
		return 0
	fi

	# Always create personal repo (private GH remote + local clone)
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
  |- TODO.md              # Routine definitions (core + user) with repeat: fields
  |- routines/
  |  |- core/             # Framework-managed routine descriptions (r901+)
  |  |  |- r901.md        # Supervisor pulse
  |  |  |- r902.md        # Auto-update
  |  |  `- ...            # 12 core routines total
  |  `- custom/           # User routine descriptions (r001-r899, survives updates)
  |     `- README.md
  |- .gitignore
  `- .github/
     `- ISSUE_TEMPLATE/
        `- routine.md

For repos with a GitHub remote, a tracking issue is created for each
core routine via routine-log-helper.sh (idempotent, skipped if exists).

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

# Only run main when executed directly, not when sourced by _routines.sh
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
