#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Git Stash Audit and Cleanup Helper
# =============================================================================
# Audit git stashes and safely clean up obsolete ones.
# Stashes accumulate from autostash, aborted edits, and manual saves.
# Most become obsolete as their changes land in HEAD.
#
# Usage:
#   git-stash-helper.sh <command> [options]
#
# Commands:
#   audit              List all stashes with classification
#   clean              Interactively drop safe stashes
#   auto-clean         Silent cleanup (for supervisor integration)
#   stats              Show stash statistics
#   help               Show this help
#
# Options:
#   --age-threshold N  Days before stash is considered old (default: 30)
#   --dry-run          Show what would be done without doing it
#   --force            Skip confirmation prompts
#
# Examples:
#   git-stash-helper.sh audit
#   git-stash-helper.sh clean --dry-run
#   git-stash-helper.sh auto-clean --age-threshold 60
#
# Classification:
#   safe-to-drop  - Changes already in HEAD
#   obsolete      - Old stash with no unique content
#   needs-review  - Contains unique work not in HEAD
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly BOLD='\033[1m'
readonly DIM='\033[2m'

# Default configuration
readonly DEFAULT_AGE_THRESHOLD=30
AGE_THRESHOLD="${AGE_THRESHOLD:-$DEFAULT_AGE_THRESHOLD}"
DRY_RUN=false
FORCE=false

# Get stash age in days
get_stash_age_days() {
	local stash_ref="$1"
	local stash_date
	stash_date=$(git log -1 --format="%ct" "$stash_ref" 2>/dev/null || echo "0")
	local now
	now=$(date +%s)
	local age_seconds=$((now - stash_date))
	local age_days=$((age_seconds / 86400))
	echo "$age_days"
}

# Check if stash changes are in HEAD
stash_changes_in_head() {
	local stash_ref="$1"

	# Get the diff of the stash
	local stash_diff
	stash_diff=$(git stash show -p "$stash_ref" 2>/dev/null || echo "")

	if [[ -z "$stash_diff" ]]; then
		return 1
	fi

	# Check if applying the stash would result in no changes
	# (meaning all changes are already in HEAD)
	if git apply --check --reverse <<<"$stash_diff" 2>/dev/null; then
		return 0
	fi

	return 1
}

# Classify a single stash
classify_stash() {
	local stash_ref="$1"
	local age_days
	age_days=$(get_stash_age_days "$stash_ref")

	# Check if changes are already in HEAD
	if stash_changes_in_head "$stash_ref"; then
		echo "safe-to-drop"
		return 0
	fi

	# Check if stash is old
	if [[ $age_days -gt $AGE_THRESHOLD ]]; then
		echo "obsolete"
		return 0
	fi

	echo "needs-review"
}

# Audit all stashes
cmd_audit() {
	local stash_count
	stash_count=$(git stash list | wc -l | tr -d ' ')

	if [[ $stash_count -eq 0 ]]; then
		print_info "No stashes found"
		return 0
	fi

	print_info "Auditing $stash_count stash(es)..."
	echo ""

	local safe_count=0
	local obsolete_count=0
	local review_count=0

	while IFS='|' read -r stash_ref age message; do
		local classification
		classification=$(classify_stash "$stash_ref")

		local color=""
		case "$classification" in
		safe-to-drop)
			color="${GREEN}"
			((safe_count++))
			;;
		obsolete)
			color="${YELLOW}"
			((obsolete_count++))
			;;
		needs-review)
			color="${BLUE}"
			((review_count++))
			;;
		esac

		printf "${color}%-15s${NC} ${BOLD}%s${NC} ${DIM}(%s)${NC} %s\n" \
			"$classification" "$stash_ref" "$age" "$message"
	done < <(git stash list --format="%gd|%cr|%gs")

	echo ""
	print_info "Summary:"
	echo "  ${GREEN}Safe to drop:${NC} $safe_count"
	echo "  ${YELLOW}Obsolete:${NC} $obsolete_count"
	echo "  ${BLUE}Needs review:${NC} $review_count"
}

# Clean safe stashes
cmd_clean() {
	local stash_count
	stash_count=$(git stash list | wc -l | tr -d ' ')

	if [[ $stash_count -eq 0 ]]; then
		print_info "No stashes found"
		return 0
	fi

	local safe_stashes=()

	while IFS='|' read -r stash_ref age message; do
		local classification
		classification=$(classify_stash "$stash_ref")

		if [[ "$classification" == "safe-to-drop" ]]; then
			safe_stashes+=("$stash_ref")
		fi
	done < <(git stash list --format="%gd|%cr|%gs")

	if [[ ${#safe_stashes[@]} -eq 0 ]]; then
		print_info "No safe-to-drop stashes found"
		return 0
	fi

	print_info "Found ${#safe_stashes[@]} safe-to-drop stash(es)"

	if [[ "$DRY_RUN" == true ]]; then
		print_info "Dry run - would drop:"
		for stash_ref in "${safe_stashes[@]}"; do
			echo "  $stash_ref"
		done
		return 0
	fi

	if [[ "$FORCE" != true ]]; then
		echo ""
		read -rp "Drop ${#safe_stashes[@]} stash(es)? [y/N] " confirm
		if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
			print_info "Cancelled"
			return 0
		fi
	fi

	local dropped=0
	for stash_ref in "${safe_stashes[@]}"; do
		if git stash drop "$stash_ref" 2>/dev/null; then
			((dropped++))
			print_success "Dropped $stash_ref"
		else
			print_error "Failed to drop $stash_ref"
		fi
	done

	print_success "Dropped $dropped stash(es)"
}

# Auto-clean for supervisor integration
cmd_auto_clean() {
	local stash_count
	stash_count=$(git stash list | wc -l | tr -d ' ')

	if [[ $stash_count -eq 0 ]]; then
		return 0
	fi

	local dropped=0

	while IFS='|' read -r stash_ref age message; do
		local classification
		classification=$(classify_stash "$stash_ref")

		if [[ "$classification" == "safe-to-drop" ]]; then
			if [[ "$DRY_RUN" != true ]]; then
				if git stash drop "$stash_ref" 2>/dev/null; then
					((dropped++))
				fi
			else
				((dropped++))
			fi
		fi
	done < <(git stash list --format="%gd|%cr|%gs")

	if [[ $dropped -gt 0 ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			echo "Would drop $dropped stash(es)"
		else
			echo "Dropped $dropped stash(es)"
		fi
	fi
}

# Show stash statistics
cmd_stats() {
	local stash_count
	stash_count=$(git stash list | wc -l | tr -d ' ')

	if [[ $stash_count -eq 0 ]]; then
		print_info "No stashes found"
		return 0
	fi

	local safe_count=0
	local obsolete_count=0
	local review_count=0
	local total_age=0

	while IFS='|' read -r stash_ref age message; do
		local classification
		classification=$(classify_stash "$stash_ref")

		case "$classification" in
		safe-to-drop) ((safe_count++)) ;;
		obsolete) ((obsolete_count++)) ;;
		needs-review) ((review_count++)) ;;
		esac

		local age_days
		age_days=$(get_stash_age_days "$stash_ref")
		total_age=$((total_age + age_days))
	done < <(git stash list --format="%gd|%cr|%gs")

	local avg_age=0
	if [[ $stash_count -gt 0 ]]; then
		avg_age=$((total_age / stash_count))
	fi

	print_info "Stash Statistics:"
	echo "  Total stashes: $stash_count"
	echo "  Safe to drop: $safe_count"
	echo "  Obsolete: $obsolete_count"
	echo "  Needs review: $review_count"
	echo "  Average age: ${avg_age} days"
	echo "  Age threshold: ${AGE_THRESHOLD} days"
}

# Show help
cmd_help() {
	cat <<'EOF'
Git Stash Audit and Cleanup Helper

Usage:
  git-stash-helper.sh <command> [options]

Commands:
  audit              List all stashes with classification
  clean              Interactively drop safe stashes
  auto-clean         Silent cleanup (for supervisor integration)
  stats              Show stash statistics
  help               Show this help

Options:
  --age-threshold N  Days before stash is considered old (default: 30)
  --dry-run          Show what would be done without doing it
  --force            Skip confirmation prompts

Examples:
  git-stash-helper.sh audit
  git-stash-helper.sh clean --dry-run
  git-stash-helper.sh auto-clean --age-threshold 60

Classification:
  safe-to-drop  - Changes already in HEAD
  obsolete      - Old stash with no unique content
  needs-review  - Contains unique work not in HEAD
EOF
}

# Main entry point
main() {
	local command="${1:-help}"
	shift || true

	# Parse options
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--age-threshold)
			AGE_THRESHOLD="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--force)
			FORCE=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			cmd_help
			exit 1
			;;
		esac
	done

	# Verify we're in a git repo
	if ! git rev-parse --git-dir &>/dev/null; then
		print_error "Not in a git repository"
		exit 1
	fi

	case "$command" in
	audit)
		cmd_audit
		;;
	clean)
		cmd_clean
		;;
	auto-clean)
		cmd_auto_clean
		;;
	stats)
		cmd_stats
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
