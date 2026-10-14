#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# =============================================================================
# Git Stash Audit Helper Script
# =============================================================================
# Audit and cleanup git stashes with safety checks.
# Classifies stashes as safe-to-drop, obsolete, or needs-review.
# Never drops stashes containing user work that isn't in HEAD.
#
# Usage:
#   stash-audit-helper.sh <command> [options]
#
# Commands:
#   audit [--repo PATH]        Audit all stashes and show classification
#   clean [--repo PATH]        Drop safe-to-drop stashes (interactive)
#   auto-clean [--repo PATH]   Drop safe-to-drop stashes (non-interactive)
#   list [--repo PATH]         List all stashes with details
#   dedupe-archives [--repo PATH] [--apply]
#                              Report/drop exact duplicate cleanup archives
#   help                       Show this help
#
# Classification:
#   safe-to-drop    All changes are in HEAD (can drop safely)
#   obsolete        Stash is old (>30 days) and likely irrelevant
#   needs-review    Contains changes not in HEAD (manual review needed)
#
# Examples:
#   stash-audit-helper.sh audit
#   stash-audit-helper.sh clean
#   stash-audit-helper.sh auto-clean --repo /path/to/repo
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

[[ -z "${RESET+x}" ]] && RESET="$NC" # Alias for NC from shared-constants.sh
readonly STASH_AGE_THRESHOLD=30      # days
# Message written by the pre-GH#34572 worktree cleanup stash archive path.
STASH_CLEANUP_ARCHIVE_MARKER="aidevops worktree cleanup archive"

# Color constants are defined in shared-constants.sh

# Logging: uses shared log_* from shared-constants.sh

#######################################
# Show help message
# Arguments:
#   None
# Returns:
#   0 always
#######################################
show_help() {
	cat <<'EOF'
Git Stash Audit Helper

Usage:
  stash-audit-helper.sh <command> [options]

Commands:
  audit [--repo PATH]        Audit all stashes and show classification
  clean [--repo PATH]        Drop safe-to-drop stashes (interactive)
  auto-clean [--repo PATH]   Drop safe-to-drop stashes (non-interactive)
  list [--repo PATH]         List all stashes with details
  dedupe-archives [--repo PATH] [--apply]
                             Report (default) or drop exact duplicate
                             "aidevops worktree cleanup archive" stashes
  help                       Show this help

Classification:
  safe-to-drop    All changes are in HEAD (can drop safely)
  obsolete        Stash is old (>30 days) and likely irrelevant
  needs-review    Contains changes not in HEAD (manual review needed)

Examples:
  stash-audit-helper.sh audit
  stash-audit-helper.sh clean
  stash-audit-helper.sh auto-clean --repo /path/to/repo

Safety:
  - Never drops stashes with changes not in HEAD
  - Interactive mode asks for confirmation before dropping
  - Auto-clean only drops stashes classified as safe-to-drop
  - Dry-run available via audit command
  - dedupe-archives drops only archives whose base, worktree, index, and
    untracked trees all match a newer kept archive
EOF
	return 0
}

#######################################
# Get repository root
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Repository root path
#######################################
get_repo_root() {
	local repo_path="${1:-$(pwd)}"

	if [[ ! -d "$repo_path" ]]; then
		log_error "Directory does not exist: $repo_path"
		return 1
	fi

	cd "$repo_path" || return 1

	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null)

	if [[ -z "$root" ]]; then
		log_error "Not a git repository: $repo_path"
		return 1
	fi

	echo "$root"
	return 0
}

#######################################
# Get stash age in days
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Age in days
#######################################
get_stash_age() {
	local stash_ref="$1"
	local stash_timestamp
	local current_timestamp
	local age_seconds
	local age_days

	stash_timestamp=$(git log -1 --format=%ct "$stash_ref" 2>/dev/null)
	if [[ -z "$stash_timestamp" ]]; then
		echo "0"
		return 1
	fi

	current_timestamp=$(date +%s)
	age_seconds=$((current_timestamp - stash_timestamp))
	age_days=$((age_seconds / 86400))

	echo "$age_days"
	return 0
}

#######################################
# Check if stash changes are in HEAD
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 if all changes are in HEAD, 1 otherwise
#######################################
stash_changes_in_head() {
	local stash_ref="$1"

	# Include the third-parent tree created by `git stash push -u`. The default
	# inventory omits untracked-only files and can misclassify unique data as an
	# empty, safe-to-drop stash (GH#27794).
	local stash_files
	stash_files=$(git stash show --name-only --include-untracked "$stash_ref" 2>/dev/null || echo "")

	if [[ -z "$stash_files" ]]; then
		# Empty stash, safe to drop
		return 0
	fi

	# For each file in stash, compare content with HEAD
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue

		# Compare blob identities so binary content is safe. Untracked files live
		# only under stash^3; tracked files remain in the stash commit tree.
		local stash_blob=""
		local head_blob=""
		stash_blob=$(git rev-parse "${stash_ref}:${file}" 2>/dev/null || true)
		if [[ -z "$stash_blob" ]]; then
			stash_blob=$(git rev-parse "${stash_ref}^3:${file}" 2>/dev/null || true)
		fi
		head_blob=$(git rev-parse "HEAD:${file}" 2>/dev/null || true)

		# Missing or different HEAD content means the stash contains unique data.
		if [[ -z "$stash_blob" || "$stash_blob" != "$head_blob" ]]; then
			return 1
		fi
	done <<<"$stash_files"

	# All files match HEAD
	return 0
}

#######################################
# Classify a stash
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Classification: safe-to-drop, obsolete, or needs-review
#######################################
classify_stash() {
	local stash_ref="$1"

	# Check if all changes are in HEAD
	if stash_changes_in_head "$stash_ref"; then
		echo "safe-to-drop"
		return 0
	fi

	# Check age
	local age_days
	age_days=$(get_stash_age "$stash_ref")

	if [[ "$age_days" -ge "$STASH_AGE_THRESHOLD" ]]; then
		echo "obsolete"
		return 0
	fi

	echo "needs-review"
	return 0
}

#######################################
# Audit all stashes
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_audit() {
	local repo_path="${1:-$(pwd)}"
	local repo_root

	if ! repo_root=$(get_repo_root "$repo_path"); then
		return 1
	fi

	cd "$repo_root" || return 1

	# Get stash list
	local stash_list
	stash_list=$(git stash list 2>/dev/null)

	if [[ -z "$stash_list" ]]; then
		log_info "No stashes found"
		return 0
	fi

	log_info "Auditing stashes in: $repo_root"
	echo ""

	local safe_count=0
	local obsolete_count=0
	local review_count=0

	while IFS= read -r stash_line; do
		local stash_ref
		stash_ref=$(echo "$stash_line" | cut -d: -f1)

		local classification
		classification=$(classify_stash "$stash_ref")

		local age_days
		age_days=$(get_stash_age "$stash_ref")

		local message
		message=$(echo "$stash_line" | cut -d: -f2- | sed 's/^ //')

		case "$classification" in
		safe-to-drop)
			echo -e "${GREEN}✓${RESET} $stash_ref (${age_days}d): $message"
			echo "  → safe-to-drop (all changes in HEAD)"
			safe_count=$((safe_count + 1))
			;;
		obsolete)
			echo -e "${YELLOW}⚠${RESET} $stash_ref (${age_days}d): $message"
			echo "  → obsolete (>$STASH_AGE_THRESHOLD days old)"
			obsolete_count=$((obsolete_count + 1))
			;;
		needs-review)
			echo -e "${RED}✗${RESET} $stash_ref (${age_days}d): $message"
			echo "  → needs-review (contains unique changes)"
			review_count=$((review_count + 1))
			;;
		esac
		echo ""
	done <<<"$stash_list"

	log_info "Summary:"
	echo "  Safe to drop:  $safe_count"
	echo "  Obsolete:      $obsolete_count"
	echo "  Needs review:  $review_count"
	echo "  Total:         $((safe_count + obsolete_count + review_count))"

	return 0
}

#######################################
# List all stashes with details
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_list() {
	local repo_path="${1:-$(pwd)}"
	local repo_root

	if ! repo_root=$(get_repo_root "$repo_path"); then
		return 1
	fi

	cd "$repo_root" || return 1

	log_info "Stashes in: $repo_root"
	echo ""

	git stash list --format="%gd: %cr - %s" 2>/dev/null

	return 0
}

#######################################
# Clean safe-to-drop stashes (interactive)
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_clean() {
	local repo_path="${1:-$(pwd)}"
	local repo_root

	if ! repo_root=$(get_repo_root "$repo_path"); then
		return 1
	fi

	cd "$repo_root" || return 1

	# Get stash list
	local stash_list
	stash_list=$(git stash list 2>/dev/null)

	if [[ -z "$stash_list" ]]; then
		log_info "No stashes found"
		return 0
	fi

	log_info "Finding safe-to-drop stashes..."
	echo ""

	local safe_stashes=()

	while IFS= read -r stash_line; do
		local stash_ref
		stash_ref=$(echo "$stash_line" | cut -d: -f1)

		local classification
		classification=$(classify_stash "$stash_ref")

		if [[ "$classification" == "safe-to-drop" ]]; then
			safe_stashes+=("$stash_ref")
			local message
			message=$(echo "$stash_line" | cut -d: -f2- | sed 's/^ //')
			echo "  $stash_ref: $message"
		fi
	done <<<"$stash_list"

	if [[ ${#safe_stashes[@]} -eq 0 ]]; then
		log_info "No safe-to-drop stashes found"
		return 0
	fi

	echo ""
	log_warn "Found ${#safe_stashes[@]} safe-to-drop stash(es)"
	echo -n "Drop these stashes? [y/N] "
	read -r response

	if [[ ! "$response" =~ ^[Yy]$ ]]; then
		log_info "Cancelled"
		return 0
	fi

	local dropped=0
	for stash_ref in "${safe_stashes[@]}"; do
		if git stash drop "$stash_ref" 2>/dev/null; then
			log_success "Dropped: $stash_ref"
			dropped=$((dropped + 1))
		else
			log_error "Failed to drop: $stash_ref"
		fi
	done

	log_success "Dropped $dropped stash(es)"

	return 0
}

#######################################
# Auto-clean safe-to-drop stashes (non-interactive)
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_auto_clean() {
	local repo_path="${1:-$(pwd)}"
	local repo_root

	if ! repo_root=$(get_repo_root "$repo_path"); then
		return 1
	fi

	cd "$repo_root" || return 1

	# Get stash list
	local stash_list
	stash_list=$(git stash list 2>/dev/null)

	if [[ -z "$stash_list" ]]; then
		log_info "No stashes found in: $repo_root"
		return 0
	fi

	local safe_stashes=()

	while IFS= read -r stash_line; do
		local stash_ref
		stash_ref=$(echo "$stash_line" | cut -d: -f1)

		local classification
		classification=$(classify_stash "$stash_ref")

		if [[ "$classification" == "safe-to-drop" ]]; then
			safe_stashes+=("$stash_ref")
		fi
	done <<<"$stash_list"

	if [[ ${#safe_stashes[@]} -eq 0 ]]; then
		log_info "No safe-to-drop stashes found in: $repo_root"
		return 0
	fi

	log_info "Auto-cleaning ${#safe_stashes[@]} safe-to-drop stash(es) in: $repo_root"

	local dropped=0
	for stash_ref in "${safe_stashes[@]}"; do
		if git stash drop "$stash_ref" 2>/dev/null; then
			log_info "  Dropped: $stash_ref"
			dropped=$((dropped + 1))
		else
			log_warn "  Failed to drop: $stash_ref"
		fi
	done

	if [[ "$dropped" -gt 0 ]]; then
		log_success "Auto-cleaned $dropped stash(es) in: $repo_root"
	fi

	return 0
}

#######################################
# Print the exact content identity of a stash commit: base commit, worktree
# tree, index tree, and untracked tree ("none" when the stash has no ^3).
# Arguments:
#   $1 - Stash commit OID
# Returns:
#   0 on success, 1 when any required object is unreadable
#######################################
stash_content_identity() {
	local stash_oid="$1"
	local base_oid=""
	local worktree_tree=""
	local index_tree=""
	local untracked_tree="none"

	base_oid=$(git rev-parse --verify --quiet "${stash_oid}^1") || return 1
	worktree_tree=$(git rev-parse --verify --quiet "${stash_oid}^{tree}") || return 1
	index_tree=$(git rev-parse --verify --quiet "${stash_oid}^2^{tree}") || return 1
	if git rev-parse --verify --quiet "${stash_oid}^3" >/dev/null; then
		untracked_tree=$(git rev-parse --verify --quiet "${stash_oid}^3^{tree}") || return 1
	fi
	printf '%s:%s:%s:%s\n' "$base_oid" "$worktree_tree" "$index_tree" "$untracked_tree"
	return 0
}

#######################################
# Drop exact duplicate worktree-cleanup archive stashes (GH#34572).
# Only stashes whose message contains STASH_CLEANUP_ARCHIVE_MARKER are
# considered. A stash is a duplicate only when its base commit and its
# worktree, index, and untracked trees all equal a newer kept archive, so
# dropping it loses no content. Distinct archives are always kept.
# Arguments:
#   $1 - Optional repo path
#   $2 - "true" to drop; anything else is a dry run
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_dedupe_archives() {
	local repo_path="${1:-$(pwd)}"
	local apply="${2:-false}"
	local repo_root=""
	if ! repo_root=$(get_repo_root "$repo_path"); then
		return 1
	fi
	cd "$repo_root" || return 1

	local stash_entries=""
	stash_entries=$(git stash list --format='%gd%x09%H%x09%gs' 2>/dev/null) || return 1
	# seen_keys holds "<identity> <kept-oid>" lines, newest archive first.
	local seen_keys=""
	local duplicates=""
	local archive_count=0
	local duplicate_count=0
	local stash_ref="" stash_oid="" stash_subject="" identity="" keeper_oid=""
	while IFS=$'\t' read -r stash_ref stash_oid stash_subject; do
		[[ -n "$stash_ref" ]] || continue
		case "$stash_subject" in
		*"$STASH_CLEANUP_ARCHIVE_MARKER"*) ;;
		*) continue ;;
		esac
		archive_count=$((archive_count + 1))
		if ! identity=$(stash_content_identity "$stash_oid"); then
			log_warn "Keeping unreadable archive: $stash_ref"
			continue
		fi
		case $'\n'"$seen_keys" in
		*$'\n'"$identity "*)
			keeper_oid="${seen_keys#*"$identity "}"
			keeper_oid="${keeper_oid%%$'\n'*}"
			duplicates="${stash_ref}"$'\t'"${stash_oid}"$'\t'"${keeper_oid}"$'\n'"${duplicates}"
			duplicate_count=$((duplicate_count + 1))
			[[ "$apply" == "true" ]] || echo "  duplicate: $stash_ref: $stash_subject"
			;;
		*)
			seen_keys="${seen_keys}${identity} ${stash_oid}"$'\n'
			;;
		esac
	done <<<"$stash_entries"

	log_info "Cleanup archives: $archive_count; exact duplicates: $duplicate_count; distinct kept: $((archive_count - duplicate_count))"
	if [[ "$duplicate_count" -eq 0 ]]; then
		return 0
	fi
	if [[ "$apply" != "true" ]]; then
		log_info "Dry run; re-run with --apply to drop the exact duplicates"
		return 0
	fi

	# `duplicates` is ordered oldest (highest index) first, so each drop leaves
	# the indices of the remaining entries unchanged.
	local dropped=0
	while IFS=$'\t' read -r stash_ref stash_oid keeper_oid; do
		[[ -n "$stash_ref" ]] || continue
		drop_duplicate_archive "$stash_ref" "$stash_oid" "$keeper_oid" || return 1
		dropped=$((dropped + 1))
	done <<<"$duplicates"
	log_success "Dropped $dropped exact duplicate cleanup archive(s)"
	return 0
}

#######################################
# Drop one duplicate archive losslessly. Refuses when the kept copy is gone or
# the index no longer names the expected OID; if a concurrent stash change
# still makes `git stash drop` remove a different entry, that entry is
# re-stored with its original message before stopping.
# Arguments:
#   $1 - Stash reference (e.g., stash@{4})
#   $2 - Expected duplicate stash OID
#   $3 - OID of the kept archive with identical content
# Returns:
#   0 when exactly the expected duplicate was dropped, 1 otherwise
#######################################
drop_duplicate_archive() {
	local stash_ref="$1"
	local expected_oid="$2"
	local keeper_oid="$3"
	local current_oids=""
	local drop_output=""
	local dropped_oid=""
	local dropped_message=""

	current_oids=$(git stash list --format='%H' 2>/dev/null) || return 1
	case $'\n'"$current_oids"$'\n' in
	*$'\n'"$keeper_oid"$'\n'*) ;;
	*)
		log_error "Kept archive $keeper_oid is gone; refusing to drop $stash_ref"
		return 1
		;;
	esac
	if [[ "$(git rev-parse --verify --quiet "$stash_ref" 2>/dev/null || true)" != "$expected_oid" ]]; then
		log_error "Stash list changed during dedupe; stopping at $stash_ref"
		return 1
	fi
	if ! drop_output=$(git stash drop "$stash_ref" 2>/dev/null); then
		log_error "Failed to drop: $stash_ref"
		return 1
	fi
	dropped_oid="${drop_output##*(}"
	dropped_oid="${dropped_oid%%)*}"
	if [[ "$dropped_oid" == "$expected_oid" ]]; then
		return 0
	fi
	dropped_message=$(git log -1 --format=%B "$dropped_oid" 2>/dev/null || true)
	if git stash store -m "${dropped_message:-restored by stash-audit-helper}" "$dropped_oid" 2>/dev/null; then
		log_error "Stash list changed during dedupe; re-stored $dropped_oid and stopped"
	else
		log_error "Stash list changed during dedupe; re-store failed, recover with: git stash store $dropped_oid"
	fi
	return 1
}

#######################################
# Main entry point
# Arguments:
#   $@ - Command and options
# Returns:
#   0 on success, 1 on failure
#######################################
main() {
	if [[ $# -eq 0 ]]; then
		show_help
		return 1
	fi

	local command="$1"
	shift

	local repo_path=""
	local apply="false"

	# Parse common options
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_path="$2"
			shift 2
			;;
		--apply)
			apply="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	case "$command" in
	audit)
		cmd_audit "$repo_path"
		;;
	clean)
		cmd_clean "$repo_path"
		;;
	auto-clean)
		cmd_auto_clean "$repo_path"
		;;
	list)
		cmd_list "$repo_path"
		;;
	dedupe-archives)
		cmd_dedupe_archives "$repo_path" "$apply"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac

	return $?
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
