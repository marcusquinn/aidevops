#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
# =============================================================================
# Version Manager — Release & Tag Functions
# =============================================================================
# Git tagging, GitHub release creation, hotfix signalling, and post-release
# functions extracted from version-manager.sh to reduce file size.
#
# Covers:
#   - create_git_tag (with GH#20073 bump-commit verification guard)
#   - create_github_release
#   - _verify_maintainer_identity
#   - _create_hotfix_tag
#   - run_post_release_agent_sync
#   - generate_release_notes
#
# Usage: source "${SCRIPT_DIR}/version-manager-release.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - version-manager-git.sh (_verify_bump_commit_at_ref)
#   - REPO_ROOT must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_VERSION_MANAGER_RELEASE_LOADED:-}" ]] && return 0
_VERSION_MANAGER_RELEASE_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# Function to create git tag
create_git_tag() {
	local version="$1"
	local tag_name="v$version"

	print_info "Creating git tag: $tag_name"

	cd "$REPO_ROOT" || exit 1

	# Guard: abort if tag already exists locally or on remote
	if git show-ref --tags "$tag_name" &>/dev/null; then
		local existing_sha
		existing_sha=$(git rev-parse "$tag_name^{}" 2>/dev/null || git rev-parse "$tag_name" 2>/dev/null)
		print_error "Tag $tag_name already exists locally (points to $existing_sha)"
		print_info "This indicates a partial or concurrent release. Diagnose with:"
		print_info "  git show $tag_name"
		print_info "  gh release view $tag_name"
		print_info "If the tag is orphaned (no matching GitHub release), delete it and retry:"
		print_info "  git tag -d $tag_name && git push origin :refs/tags/$tag_name"
		return 1
	fi

	# Also check remote tags to catch tags pushed by a concurrent run
	# Note: --exit-code returns 2 when ref not found; capture exit code to
	# prevent set -e from aborting the script on a "not found" result.
	local remote_tag_exit=0
	git ls-remote -q --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1 || remote_tag_exit=$?
	if [ $remote_tag_exit -eq 0 ]; then
		print_error "Tag $tag_name already exists on remote origin"
		print_info "A concurrent release run may have pushed this tag. Diagnose with:"
		print_info "  git fetch --tags && git show $tag_name"
		print_info "  gh release view $tag_name"
		return 1
	fi

	# t2437/GH#20073: Final guard before `git tag` — HEAD must be the bump
	# commit for $version. This catches any residual case where an upstream
	# caller skipped its own post-commit/post-rebase verification, or called
	# create_git_tag directly (e.g., standalone `version-manager.sh tag`).
	# Opt-out via AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 for maintainer recovery flows
	# that intentionally tag non-bump commits (e.g., annotated release sync
	# tags). Default is strict.
	if [[ "${AIDEVOPS_VM_SKIP_BUMP_VERIFY:-0}" != "1" ]]; then
		if ! _verify_bump_commit_at_ref HEAD "$version"; then
			print_error "Aborting tag creation: HEAD is not the bump commit for v$version"
			print_info "The tag would land on the wrong commit (this is exactly the"
			print_info "GH#20073 foot-gun). Inspect and recover:"
			print_info "  git log -1 --format='%H %s'   # current HEAD"
			print_info "  git log --oneline -5          # recent history"
			print_info "Override only if you truly need to tag a non-bump commit:"
			print_info "  AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 $0 tag"
			return 1
		fi
	fi

	if git tag -a "$tag_name" -m "Release $tag_name - AI DevOps Framework"; then
		print_success "Created git tag: $tag_name"
		return 0
	else
		print_error "Failed to create git tag"
		return 1
	fi
	return 0
}

# Function to create GitHub release
create_github_release() {
	local version="$1"
	local tag_name="v$version"

	print_info "Creating GitHub release: $tag_name"

	# Try GitHub CLI first
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		print_info "Using GitHub CLI for release creation"

		# Guard: check if GitHub release already exists for this tag
		if gh release view "$tag_name" &>/dev/null; then
			print_warning "GitHub release $tag_name already exists — skipping creation"
			print_info "To view the existing release: gh release view $tag_name"
			return 0
		fi

		# Generate release notes based on version
		local release_notes
		release_notes=$(generate_release_notes "$version")

		# Create GitHub release
		if gh release create "$tag_name" \
			--title "$tag_name - AI DevOps Framework" \
			--notes "$release_notes" \
			--latest; then
			print_success "Created GitHub release: $tag_name"
			return 0
		else
			print_error "Failed to create GitHub release with GitHub CLI"
			return 1
		fi
	else
		# GitHub CLI not available
		print_warning "GitHub release creation skipped - GitHub CLI not available"
		print_info "To enable GitHub releases:"
		print_info "1. Install GitHub CLI: brew install gh (macOS)"
		print_info "2. Authenticate: gh auth login"
		return 0
	fi
	return 0
}

# Verify current user is a maintainer (repo OWNER or MEMBER) for hotfix releases.
# Returns 0 if the user is authorized, 1 otherwise.
_verify_maintainer_identity() {
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		print_error "hotfix release requires GitHub CLI authentication (gh auth login)"
		return 1
	fi

	local remote_url slug current_user user_association
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")
	slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')

	if [[ -z "$slug" ]]; then
		print_error "Cannot determine repo slug from origin remote"
		return 1
	fi

	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		print_error "Cannot determine current GitHub user"
		return 1
	fi

	# Check repo collaboration level — OWNER and MEMBER can push hotfixes
	user_association=$(gh api "repos/${slug}/collaborators/${current_user}/permission" --jq '.role_name' 2>/dev/null || echo "")

	case "$user_association" in
	admin | maintain | write)
		return 0
		;;
	*)
		# Fallback: check if the user is the repo owner (slug prefix matches)
		local repo_owner="${slug%%/*}"
		if [[ "$current_user" == "$repo_owner" ]]; then
			return 0
		fi
		print_error "hotfix release requires maintainer identity (current: ${current_user}, role: ${user_association:-unknown})"
		return 1
		;;
	esac
}

# Create a hotfix signal tag alongside the normal release tag.
# The hotfix tag triggers accelerated polling on remote runners.
# Arguments: version (e.g. "3.8.79")
_create_hotfix_tag() {
	local version="$1"
	local hotfix_tag="hotfix-v${version}"

	cd "$REPO_ROOT" || return 1

	# Check for existing hotfix tag
	if git show-ref --tags "$hotfix_tag" &>/dev/null; then
		print_warning "Hotfix tag $hotfix_tag already exists locally — skipping"
		return 0
	fi

	local remote_tag_exit=0
	git ls-remote -q --exit-code --tags origin "refs/tags/$hotfix_tag" >/dev/null 2>&1 || remote_tag_exit=$?
	if [ $remote_tag_exit -eq 0 ]; then
		print_warning "Hotfix tag $hotfix_tag already exists on remote — skipping"
		return 0
	fi

	if git tag -a "$hotfix_tag" -m "Hotfix signal: v${version} — triggers immediate runner propagation"; then
		print_success "Created hotfix signal tag: $hotfix_tag"
	else
		print_error "Failed to create hotfix signal tag"
		return 1
	fi

	# Push the hotfix tag (the release tag is pushed by push_changes;
	# the hotfix tag needs a separate push since --tags only pushes
	# tags that point to reachable commits, which this one does).
	if git push origin "$hotfix_tag" 2>/dev/null; then
		print_success "Pushed hotfix signal tag: $hotfix_tag"
	else
		print_warning "Failed to push hotfix signal tag (non-blocking)"
		# Non-blocking: the release itself succeeded, just the signal is delayed
	fi
	return 0
}

run_post_release_agent_sync() {
	local sync_repo_root="${AIDEVOPS_SYNC_REPO_ROOT:-$REPO_ROOT}"
	local remote_url
	remote_url=$(git -C "$sync_repo_root" remote get-url origin 2>/dev/null || echo "")

	if [[ "$remote_url" != *"marcusquinn/aidevops"* ]]; then
		return 0
	fi

	local deploy_script="${AIDEVOPS_SYNC_DEPLOY_SCRIPT:-$sync_repo_root/.agents/scripts/deploy-agents-on-merge.sh}"
	if [[ ! -f "$deploy_script" ]]; then
		print_warning "Post-release sync skipped: deploy script not found at $deploy_script"
		return 0
	fi

	print_info "Running post-release aidevops agent sync..."
	local sync_output=""
	local sync_exit=0
	sync_output=$(bash "$deploy_script" --repo "$sync_repo_root" --quiet 2>&1) || sync_exit=$?

	if [[ "$sync_exit" -eq 0 || "$sync_exit" -eq 2 ]]; then
		print_success "Post-release aidevops agent sync completed"
		return 0
	fi

	print_warning "Post-release aidevops agent sync failed (non-blocking): $sync_output"
	return 0
}

# Function to generate release notes
generate_release_notes() {
	local version="$1"
	# Parse version components (reserved for version-specific logic)
	# shellcheck disable=SC2034
	local major minor patch
	IFS='.' read -r major minor patch <<<"$version"

	cat <<EOF
## AI DevOps Framework v$version

### Installation

\`\`\`bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# curl
bash <(curl -fsSL https://aidevops.sh/install)
\`\`\`

### What's New

See [CHANGELOG.md](CHANGELOG.md) for detailed changes.

### Quick Start

\`\`\`bash
# Check installation
aidevops status

# Initialize in a project
aidevops init

# Update framework + projects
aidevops update

# List registered projects
aidevops repos
\`\`\`

### Documentation

- **[Setup Guide](README.md)**: Complete framework setup
- **[User Guide](.agents/AGENTS.md)**: AI assistant integration
- **[API Integrations](.agents/aidevops/api-integrations.md)**: Service APIs

### Links

- **Website**: https://aidevops.sh
- **Repository**: https://github.com/marcusquinn/aidevops
- **Issues**: https://github.com/marcusquinn/aidevops/issues

---

**Full Changelog**: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v$version
EOF
	return 0
}
