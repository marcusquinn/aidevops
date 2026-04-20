#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
set -euo pipefail

# Version Manager for AI DevOps Framework
# Manages semantic versioning and automated version bumping
#
# Author: AI DevOps Framework
# Version: 1.1.0
#
# This file is the thin orchestrator. The implementation is in sub-libraries:
#   version-manager-changelog.sh  — CHANGELOG.md read/write/generate
#   version-manager-preflight.sh  — secretlint, shellcheck, patch-release preflight
#   version-manager-files.sh      — VERSION, package.json, README.md, etc.
#   version-manager-git.sh        — remote sync, task auto-complete, commit, push
#   version-manager-release.sh    — git tag, GitHub release, hotfix signal

# Source shared constants (provides sed_inplace, print_*, color constants)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# Repository root directory
# First try git (works when called from any location within a repo)
# Fall back to script-relative path (for when script is sourced or tested standalone)
if git rev-parse --show-toplevel &>/dev/null; then
	REPO_ROOT="$(git rev-parse --show-toplevel)"
else
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
VERSION_FILE="$REPO_ROOT/VERSION"

# Source sub-libraries
# shellcheck source=./version-manager-changelog.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/version-manager-changelog.sh"

# shellcheck source=./version-manager-preflight.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-preflight.sh"

# shellcheck source=./version-manager-files.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-files.sh"

# shellcheck source=./version-manager-git.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-git.sh"

# shellcheck source=./version-manager-release.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-release.sh"

# Function to get current version
get_current_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		cat "$VERSION_FILE"
	else
		echo "1.0.0"
	fi
	return 0
}

# Function to bump version
bump_version() {
	local bump_type="$1"
	local current_version
	current_version=$(get_current_version)

	local major minor patch
	IFS='.' read -r major minor patch <<<"$current_version"

	case "$bump_type" in
	"major")
		major=$((major + 1))
		minor=0
		patch=0
		;;
	"minor")
		minor=$((minor + 1))
		patch=0
		;;
	"patch")
		patch=$((patch + 1))
		;;
	*)
		print_error "Invalid bump type. Use: major, minor, or patch"
		return 1
		;;
	esac

	local new_version="$major.$minor.$patch"
	echo "$new_version" >"$VERSION_FILE"
	echo "$new_version"
	return 0
}

# Handle the "bump" action: bump version and update all files.
# Arguments: bump_type [major|minor|patch]
_main_bump() {
	local bump_type="$1"

	if [[ -z "$bump_type" ]]; then
		print_error "Bump type required. Usage: $0 bump [major|minor|patch]"
		exit 1
	fi

	local current_version
	current_version=$(get_current_version)
	print_info "Current version: $current_version"

	local new_version
	new_version=$(bump_version "$bump_type")

	if [[ $? -eq 0 ]]; then
		print_success "Bumped version: $current_version → $new_version"
		if ! update_version_in_files "$new_version"; then
			print_error "Failed to update version in all files"
			print_info "Run validation to check: $0 validate"
			exit 1
		fi
		echo "$new_version"
	else
		exit 1
	fi
	return 0
}

# Check changelog state before release; exit if nothing to release.
# Arguments: force_flag
_release_check_changelog() {
	local force_flag="$1"

	if ! check_changelog_unreleased; then
		local releasable_commits
		releasable_commits=$(get_releasable_commit_subjects)

		if [[ -n "$releasable_commits" ]]; then
			print_warning "CHANGELOG.md [Unreleased] is empty; proceeding with auto-generated changelog from commit history"
			print_info "Detected releasable commits since last tag:"
			local listed_count=0
			while IFS= read -r commit_subject; do
				[[ -z "$commit_subject" ]] && continue
				print_info "  - $commit_subject"
				listed_count=$((listed_count + 1))
				if [[ "$listed_count" -ge 5 ]]; then
					break
				fi
			done <<<"$releasable_commits"
		else
			if [[ "$force_flag" != "--force" ]]; then
				print_error "CHANGELOG.md [Unreleased] is empty and no releasable commits were found since last tag"
				print_info "Nothing meaningful to release. Add commits or use --force to bypass"
				exit 1
			else
				print_warning "Bypassing changelog and empty-commit checks with --force"
			fi
		fi
	fi
	return 0
}

# Perform the version bump, file updates, tag, push, and GitHub release.
# Arguments: bump_type new_version
_release_execute() {
	local bump_type="$1"
	local new_version="$2"
	local tag_name="v$new_version"

	# Guard: detect partial release state before making any changes.
	# A tag without a matching GitHub release indicates a prior failed run.
	# Abort early with clear diagnostics rather than creating a duplicate tag.
	# Note: --exit-code returns 2 when ref not found; capture exit code to
	# prevent set -e from aborting the script on a "not found" result.
	local preflight_remote_exit=0
	git ls-remote -q --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1 || preflight_remote_exit=$?
	if git show-ref --tags "$tag_name" &>/dev/null || [ $preflight_remote_exit -eq 0 ]; then
		print_error "PARTIAL RELEASE STATE DETECTED: tag $tag_name already exists"
		print_info ""
		print_info "Diagnosis:"
		print_info "  git show $tag_name                    # inspect the existing tag"
		print_info "  gh release view $tag_name             # check if GitHub release exists"
		print_info "  git log $tag_name --oneline -5        # see what the tag points to"
		print_info ""
		print_info "Recovery options:"
		print_info "  A) Tag exists + GitHub release exists → already released, nothing to do"
		print_info "  B) Tag exists + no GitHub release    → run: $0 github-release"
		print_info "  C) Tag is orphaned/wrong commit      → delete and retry:"
		print_info "       git tag -d $tag_name"
		print_info "       git push origin :refs/tags/$tag_name"
		print_info "       $0 release $bump_type"
		exit 1
	fi

	print_info "Updating version references in files..."
	if ! update_version_in_files "$new_version"; then
		print_error "Failed to update version in all files. Aborting release."
		print_info "The VERSION file may have been updated. Run validation to check:"
		print_info "  $0 validate"
		exit 1
	fi

	print_info "Updating CHANGELOG.md..."
	if ! update_changelog "$new_version"; then
		print_warning "Failed to update CHANGELOG.md automatically"
	fi

	# Auto-mark tasks complete based on commit messages
	auto_mark_tasks_complete

	print_info "Validating version consistency..."
	if validate_version_consistency "$new_version"; then
		print_success "Version validation passed"

		# t2437/GH#20073: commit the bump, verify HEAD is the bump commit.
		if ! _release_commit_and_verify_bump "$new_version" "$bump_type"; then
			exit 1
		fi

		if ! create_git_tag "$new_version"; then
			print_error "Aborting release: tag creation failed (see above for diagnosis)"
			exit 1
		fi
		if ! push_changes "$new_version"; then
			# --atomic push failed: tag was NOT pushed to remote.
			# Check whether a concurrent run already pushed the tag before rolling back.
			# Note: --exit-code returns 2 when ref not found; capture exit code to
			# prevent set -e from aborting the script on a "not found" result.
			local push_fail_remote_exit=0
			git ls-remote -q --exit-code --tags origin "refs/tags/v$new_version" >/dev/null 2>&1 || push_fail_remote_exit=$?
			if [ $push_fail_remote_exit -eq 0 ]; then
				print_warning "Push failed but tag v$new_version already exists on remote (concurrent release?)"
				print_info "Deleting local tag to avoid divergence. Check remote state:"
				git tag -d "v$new_version" 2>/dev/null || true
				print_info "  gh release view v$new_version   # check if GitHub release was created"
				print_info "  git fetch --tags && git log v$new_version --oneline -3"
				exit 1
			fi
			# Safe to roll back: tag is local-only
			print_warning "Rolling back local tag v$new_version due to push failure"
			git tag -d "v$new_version" 2>/dev/null || true
			echo ""
			print_info "The version commit exists locally. To complete the release:"
			print_info "  1. Fix the issue (e.g., git fetch origin && git rebase origin/main)"
			print_info "  2. Re-create tag: git tag -a v$new_version -m 'Release v$new_version'"
			print_info "  3. Push: git push --atomic origin main --tags"
			print_info "  4. Create release: $0 github-release"
			exit 1
		fi
		create_github_release "$new_version"
		run_post_release_agent_sync
		print_success "Release $new_version created successfully!"
	else
		print_error "Version validation failed. Please fix inconsistencies before creating release."
		exit 1
	fi
	return 0
}

# Show release plan without executing (--dry-run).
# Args: bump_type hotfix_flag force_flag skip_preflight
_release_dry_run() {
	local bump_type="$1"
	local hotfix_flag="$2"
	local force_flag="$3"
	local skip_preflight="$4"

	local current_version
	current_version=$(get_current_version)
	# Compute planned version without writing to VERSION file
	local dr_major dr_minor dr_patch planned_version
	IFS='.' read -r dr_major dr_minor dr_patch <<<"$current_version"
	case "$bump_type" in
	"major") dr_major=$((dr_major + 1)); dr_minor=0; dr_patch=0 ;;
	"minor") dr_minor=$((dr_minor + 1)); dr_patch=0 ;;
	"patch") dr_patch=$((dr_patch + 1)) ;;
	esac
	planned_version="${dr_major}.${dr_minor}.${dr_patch}"
	print_info "=== DRY RUN: Release Plan ==="
	print_info "  Current version: $current_version"
	print_info "  Planned version: $planned_version"
	print_info "  Bump type: $bump_type"
	print_info "  Tags: v${planned_version}"
	if [[ "$hotfix_flag" -eq 1 ]]; then
		print_info "  Hotfix tag: hotfix-v${planned_version}"
		print_info "  Runners with auto_hotfix_accept=true will pull within ~5 minutes"
		print_info "  Runners with auto_hotfix_accept=false will see a session banner"
	fi
	print_info "  Force: $( [[ "$force_flag" -eq 1 ]] && echo "yes" || echo "no" )"
	print_info "  Skip preflight: $( [[ "$skip_preflight" -eq 1 ]] && echo "yes" || echo "no" )"
	print_info "=== DRY RUN: No changes made ==="
	return 0
}

# Handle the "release" action: full release pipeline.
# Arguments: bump_type [flags...] (all positional args from main, starting at $1=bump_type)
_main_release() {
	local bump_type="$1"
	shift

	if [[ -z "$bump_type" ]]; then
		print_error "Bump type required. Usage: $0 release [major|minor|patch]"
		exit 1
	fi

	# Parse flags (can be in any order after bump_type)
	local force_flag=0 skip_preflight=0 allow_dirty=0 hotfix_flag=0 dry_run=0
	for arg in "$@"; do
		case "$arg" in
		"--force") force_flag=1 ;;
		"--skip-preflight") skip_preflight=1 ;;
		"--allow-dirty") allow_dirty=1 ;;
		"--hotfix") hotfix_flag=1 ;;
		"--dry-run") dry_run=1 ;;
		*) ;; # Ignore unknown flags
		esac
	done

	# Hotfix releases are restricted to patch bumps and require maintainer identity
	if [[ "$hotfix_flag" -eq 1 ]]; then
		if [[ "$bump_type" != "patch" ]]; then
			print_error "Hotfix releases can only be patch bumps (got: $bump_type)"
			exit 1
		fi
		if ! _verify_maintainer_identity; then
			exit 1
		fi
		print_info "Hotfix mode: this release will signal immediate runner propagation"
	fi

	if [[ "$dry_run" -eq 1 ]]; then
		_release_dry_run "$bump_type" "$hotfix_flag" "$force_flag" "$skip_preflight"
		return 0
	fi

	print_info "Creating release with $bump_type version bump..."

	# Verify local branch is in sync with remote
	if ! verify_remote_sync "main"; then
		if [[ "$force_flag" -eq 0 ]]; then
			print_error "Cannot release when local/remote are out of sync."
			print_info "Use --force to bypass (not recommended)"
			exit 1
		else
			print_warning "Bypassing remote sync check with --force"
		fi
	fi

	# Check for uncommitted changes
	if [[ "$allow_dirty" -eq 0 ]]; then
		if ! check_working_tree_clean; then
			print_error "Cannot release with uncommitted changes."
			print_info "Commit your changes first, or use --allow-dirty to bypass"
			exit 1
		fi
	else
		print_warning "Releasing with uncommitted changes (--allow-dirty)"
	fi

	# Run preflight checks unless skipped
	if [[ "$skip_preflight" -eq 0 ]]; then
		if ! run_preflight_checks "$bump_type"; then
			print_error "Preflight checks failed. Fix issues or use --skip-preflight."
			exit 1
		fi
	else
		print_warning "Skipping preflight checks with --skip-preflight"
	fi

	local force_arg=""
	if [[ "$force_flag" -eq 1 ]]; then
		force_arg="--force"
	fi
	_release_check_changelog "$force_arg"

	local new_version
	new_version=$(bump_version "$bump_type")

	if [[ $? -eq 0 ]]; then
		_release_execute "$bump_type" "$new_version"
		if [[ "$hotfix_flag" -eq 1 ]]; then
			_create_hotfix_tag "$new_version"
		fi
	else
		exit 1
	fi
	return 0
}

# Print usage/help text.
_main_usage() {
	echo "AI DevOps Framework Version Manager"
	echo ""
	echo "Usage: $0 [action] [options]"
	echo ""
	echo "Actions:"
	echo "  get                           Get current version"
	echo "  bump [major|minor|patch]      Bump version"
	echo "  tag                           Create git tag for current version"
	echo "  github-release                Create GitHub release for current version"
	echo "  release [major|minor|patch]   Bump version, update files, create tag and GitHub release"
	echo "  release patch --hotfix       Patch release with hotfix signal for immediate runner propagation"
	echo "  preflight [major|minor|patch] Run release preflight checks only"
	echo "  validate                      Validate version consistency across all files"
	echo "  changelog-check               Check CHANGELOG.md has entry for current version"
	echo "  changelog-preview             Generate changelog entry from commits since last tag"
	echo "  auto-mark-tasks               Auto-mark tasks complete based on commit messages"
	echo "  list-task-ids                 List task IDs found in commits since last release"
	echo ""
	echo "Options:"
	echo "  --force                       Bypass changelog check (use with release)"
	echo "  --skip-preflight              Bypass quality checks (use with release)"
	echo "  --hotfix                      Signal hotfix for immediate runner propagation (patch only)"
	echo "  --dry-run                     Show release plan without executing (use with release)"
	echo ""
	echo "Examples:"
	echo "  $0 get"
	echo "  $0 bump minor"
	echo "  $0 release patch"
	echo "  $0 release minor --force"
	echo "  $0 release patch --skip-preflight"
	echo "  $0 release patch --force --skip-preflight"
	echo "  $0 release patch --hotfix"
	echo "  $0 release patch --hotfix --dry-run"
	echo "  $0 github-release"
	echo "  $0 validate"
	echo "  $0 changelog-check"
	echo "  $0 changelog-preview"
	return 0
}

# Main function
main() {
	local action="${1:-}"
	local bump_type="${2:-}"

	case "$action" in
	"get")
		get_current_version
		;;
	"bump")
		_main_bump "$bump_type"
		;;
	"tag")
		local version
		version=$(get_current_version)
		create_git_tag "$version"
		;;
	"release")
		_main_release "$bump_type" "${@:3}"
		;;
	"github-release")
		local version
		version=$(get_current_version)
		create_github_release "$version"
		;;
	"validate")
		local version
		version=$(get_current_version)
		validate_version_consistency "$version"
		;;
	"preflight")
		if [[ -z "$bump_type" ]]; then
			print_error "Bump type required. Usage: $0 preflight [major|minor|patch]"
			exit 1
		fi
		run_preflight_checks "$bump_type"
		;;
	"changelog-check")
		local version
		version=$(get_current_version)
		print_info "Checking CHANGELOG.md for version $version..."
		if check_changelog_version "$version"; then
			print_success "CHANGELOG.md is in sync with VERSION"
		else
			print_error "CHANGELOG.md is out of sync with VERSION ($version)"
			print_info "Run: $0 changelog-preview to see suggested entries"
			exit 1
		fi
		;;
	"changelog-preview")
		print_info "Generating changelog preview from commits..."
		echo ""
		generate_changelog_preview
		;;
	"auto-mark-tasks")
		print_info "Auto-marking tasks complete from commit messages..."
		auto_mark_tasks_complete
		;;
	"list-task-ids")
		print_info "Task IDs found in commits since last release:"
		extract_task_ids_from_commits
		;;
	*)
		_main_usage
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
