#!/usr/bin/env bash
# shellcheck disable=SC1091
# =============================================================================
# Rosetta Audit Helper - Detect x86 Homebrew binaries on Apple Silicon
# =============================================================================
# Finds Homebrew packages running under Rosetta 2 emulation on Apple Silicon
# Macs and offers to migrate them to native ARM versions for better performance.
#
# On Intel Macs or Linux, exits cleanly with a skip message.
#
# Usage:
#   rosetta-audit-helper.sh scan          # Audit x86 packages (default)
#   rosetta-audit-helper.sh migrate       # Migrate x86 packages to ARM
#   rosetta-audit-helper.sh migrate --dry-run  # Preview migration
#   rosetta-audit-helper.sh status        # Quick summary
#   rosetta-audit-helper.sh help          # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly X86_BREW="/usr/local/bin/brew"
readonly ARM_BREW="/opt/homebrew/bin/brew"
readonly CACHE_DIR="${HOME}/.aidevops/cache"
readonly SCAN_CACHE="${CACHE_DIR}/rosetta-audit-scan.txt"
readonly SCAN_CACHE_TTL=3600 # 1 hour

# =============================================================================
# Platform Detection
# =============================================================================

# Check if running on Apple Silicon
# Returns: 0 if Apple Silicon, 1 otherwise
is_apple_silicon() {
	if [[ "$(uname)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
		return 0
	fi
	return 1
}

# Check if both x86 and ARM Homebrew exist
# Returns: 0 if dual-brew setup detected, 1 otherwise
has_dual_brew() {
	if [[ -x "$X86_BREW" ]] && [[ -x "$ARM_BREW" ]]; then
		return 0
	fi
	return 1
}

# =============================================================================
# Package Analysis
# =============================================================================

# Get x86-only packages (installed in x86 brew but not ARM brew)
# Output: newline-separated package names
get_x86_only_packages() {
	comm -23 \
		<("$X86_BREW" list --formula 2>/dev/null | sort) \
		<("$ARM_BREW" list --formula 2>/dev/null | sort)
	return 0
}

# Get duplicate packages (installed in both x86 and ARM brew)
# Output: newline-separated package names
get_duplicate_packages() {
	comm -12 \
		<("$X86_BREW" list --formula 2>/dev/null | sort) \
		<("$ARM_BREW" list --formula 2>/dev/null | sort)
	return 0
}

# Check if a package has an ARM formula available
# Arguments: $1 - package name
# Returns: 0 if available, 1 if not
has_arm_formula() {
	local pkg="$1"
	"$ARM_BREW" info "$pkg" >/dev/null 2>&1
	return $?
}

# Categorise x86-only packages into migratable and non-migratable
# Output: writes to two temp files passed as arguments
# Arguments: $1 - migratable output file, $2 - non-migratable output file
categorise_packages() {
	local migratable_file="$1"
	local non_migratable_file="$2"
	local x86_only

	x86_only=$(get_x86_only_packages)

	if [[ -z "$x86_only" ]]; then
		return 0
	fi

	while IFS= read -r pkg; do
		[[ -z "$pkg" ]] && continue
		if has_arm_formula "$pkg"; then
			echo "$pkg" >>"$migratable_file"
		else
			echo "$pkg" >>"$non_migratable_file"
		fi
	done <<<"$x86_only"

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Full scan of x86 Homebrew packages
cmd_scan() {
	if ! is_apple_silicon; then
		print_info "Intel Mac or non-macOS detected — Rosetta audit not applicable"
		return 0
	fi

	if ! has_dual_brew; then
		if [[ -x "$ARM_BREW" ]] && [[ ! -x "$X86_BREW" ]]; then
			print_success "Clean ARM-only Homebrew setup — no x86 packages to audit"
			return 0
		fi
		print_warning "Homebrew not found or only x86 Homebrew installed"
		print_info "ARM Homebrew: $ARM_BREW ($([[ -x "$ARM_BREW" ]] && echo "found" || echo "missing"))"
		print_info "x86 Homebrew: $X86_BREW ($([[ -x "$X86_BREW" ]] && echo "found" || echo "missing"))"
		return 1
	fi

	echo -e "${BLUE}Rosetta Audit — Scanning Homebrew packages${NC}"
	echo "================================================================"
	echo ""

	# Count packages in each brew
	local x86_count arm_count
	x86_count=$("$X86_BREW" list --formula 2>/dev/null | wc -l | tr -d ' ')
	arm_count=$("$ARM_BREW" list --formula 2>/dev/null | wc -l | tr -d ' ')

	print_info "x86 Homebrew (/usr/local): $x86_count packages"
	print_info "ARM Homebrew (/opt/homebrew): $arm_count packages"
	echo ""

	# Get duplicates
	local duplicates
	duplicates=$(get_duplicate_packages)
	local dup_count=0
	if [[ -n "$duplicates" ]]; then
		dup_count=$(echo "$duplicates" | wc -l | tr -d ' ')
	fi

	# Categorise x86-only packages
	local migratable_file non_migratable_file
	migratable_file=$(mktemp "${TMPDIR:-/tmp}/rosetta-migrate.XXXXXX")
	non_migratable_file=$(mktemp "${TMPDIR:-/tmp}/rosetta-nomigrate.XXXXXX")
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '$migratable_file' '$non_migratable_file'"

	print_info "Checking ARM formula availability (this may take a moment)..."
	categorise_packages "$migratable_file" "$non_migratable_file"

	local migratable_count=0 non_migratable_count=0
	[[ -s "$migratable_file" ]] && migratable_count=$(wc -l <"$migratable_file" | tr -d ' ')
	[[ -s "$non_migratable_file" ]] && non_migratable_count=$(wc -l <"$non_migratable_file" | tr -d ' ')

	# Report
	echo ""
	echo -e "${BLUE}=== Summary ===${NC}"
	echo ""

	if [[ "$dup_count" -gt 0 ]]; then
		print_warning "Duplicates (in both brews, x86 copy wasting disk): $dup_count"
		echo "$duplicates" | while IFS= read -r pkg; do
			echo "  - $pkg"
		done
		echo ""
	fi

	if [[ "$migratable_count" -gt 0 ]]; then
		print_info "Migratable to ARM (formula available): $migratable_count"
		while IFS= read -r pkg; do
			echo "  - $pkg"
		done <"$migratable_file"
		echo ""
	fi

	if [[ "$non_migratable_count" -gt 0 ]]; then
		print_warning "No ARM formula (keep as x86 or remove): $non_migratable_count"
		while IFS= read -r pkg; do
			echo "  - $pkg"
		done <"$non_migratable_file"
		echo ""
	fi

	if [[ "$migratable_count" -eq 0 ]] && [[ "$dup_count" -eq 0 ]]; then
		print_success "No x86 packages to migrate — your setup is clean"
		return 0
	fi

	# Recommendations
	echo -e "${BLUE}=== Recommendations ===${NC}"
	echo ""

	if [[ "$migratable_count" -gt 0 ]]; then
		print_info "Migrate $migratable_count packages to ARM:"
		echo "  rosetta-audit-helper.sh migrate --dry-run  # Preview"
		echo "  rosetta-audit-helper.sh migrate             # Execute"
		echo ""
	fi

	if [[ "$dup_count" -gt 0 ]]; then
		print_info "Remove $dup_count duplicate x86 packages (ARM versions already installed):"
		echo "  rosetta-audit-helper.sh migrate  # Handles duplicates too"
		echo ""
	fi

	# Cache results for quick status checks
	mkdir -p "$CACHE_DIR" 2>/dev/null || true
	{
		echo "timestamp=$(date +%s)"
		echo "x86_count=$x86_count"
		echo "arm_count=$arm_count"
		echo "duplicates=$dup_count"
		echo "migratable=$migratable_count"
		echo "non_migratable=$non_migratable_count"
	} >"$SCAN_CACHE"

	return 0
}

# Migrate x86 packages to ARM
cmd_migrate() {
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	if ! is_apple_silicon; then
		print_info "Intel Mac or non-macOS detected — Rosetta audit not applicable"
		return 0
	fi

	if ! has_dual_brew; then
		print_error "Dual Homebrew setup not detected"
		return 1
	fi

	echo -e "${BLUE}Rosetta Migration$([[ "$dry_run" = true ]] && echo " (DRY RUN)")${NC}"
	echo "================================================================"
	echo ""

	local migrated=0 removed_dups=0 failed=0 skipped=0

	# Suppress brew cleanup during migration (it interferes with batch installs)
	export HOMEBREW_NO_INSTALL_CLEANUP=1

	# Phase 1: Install ARM versions of x86-only packages
	# (Must happen BEFORE removing anything — x86 packages depend on each other)
	local x86_only
	x86_only=$(get_x86_only_packages)

	if [[ -n "$x86_only" ]]; then
		echo -e "${BLUE}Phase 1: Installing ARM versions of x86-only packages${NC}"
		echo ""

		while IFS= read -r pkg; do
			[[ -z "$pkg" ]] && continue

			if ! has_arm_formula "$pkg"; then
				print_warning "Skipped: $pkg (no ARM formula available)"
				((skipped++))
				continue
			fi

			if [[ "$dry_run" = true ]]; then
				echo "  [DRY RUN] Would install ARM: $pkg"
				((migrated++))
			else
				if "$ARM_BREW" install "$pkg" 2>&1 | tail -1; then
					print_success "Installed ARM: $pkg"
					((migrated++))
				else
					print_error "Failed to install ARM: $pkg"
					((failed++))
				fi
			fi
		done <<<"$x86_only"
		echo ""
	fi

	# Phase 2: Remove ALL x86 packages (duplicates + migrated)
	# Now safe because ARM versions are installed for everything migratable
	local all_x86
	all_x86=$("$X86_BREW" list --formula 2>/dev/null)

	if [[ -n "$all_x86" ]]; then
		echo -e "${BLUE}Phase 2: Removing x86 packages${NC}"
		echo ""

		# Count duplicates for summary
		local duplicates
		duplicates=$(get_duplicate_packages)
		local dup_count=0
		if [[ -n "$duplicates" ]]; then
			dup_count=$(echo "$duplicates" | wc -l | tr -d ' ')
		fi

		if [[ "$dry_run" = true ]]; then
			while IFS= read -r pkg; do
				[[ -z "$pkg" ]] && continue
				echo "  [DRY RUN] Would remove x86: $pkg"
			done <<<"$all_x86"
			removed_dups=$dup_count
		else
			# Use --force --ignore-dependencies to remove all x86 packages in one pass
			# Safe because ARM versions are now installed for everything migratable
			local x86_list=()
			while IFS= read -r pkg; do
				[[ -z "$pkg" ]] && continue
				x86_list+=("$pkg")
			done <<<"$all_x86"

			if [[ ${#x86_list[@]} -gt 0 ]]; then
				print_info "Removing ${#x86_list[@]} x86 packages..."
				if "$X86_BREW" uninstall --force --ignore-dependencies "${x86_list[@]}" 2>&1 | tail -3; then
					removed_dups=${#x86_list[@]}
					print_success "Removed ${#x86_list[@]} x86 packages"
				else
					print_warning "Some x86 packages could not be removed"
					# Count what's left
					local remaining_after
					remaining_after=$("$X86_BREW" list --formula 2>/dev/null | wc -l | tr -d ' ')
					removed_dups=$((${#x86_list[@]} - remaining_after))
				fi
			fi
		fi
		echo ""
	fi
	# Summary
	echo -e "${BLUE}=== Migration Summary$([[ "$dry_run" = true ]] && echo " (DRY RUN)") ===${NC}"
	echo ""
	echo "  Installed ARM versions: $migrated"
	echo "  x86 packages removed:  $removed_dups"
	echo "  Skipped (no ARM):      $skipped"
	echo "  Failed:                 $failed"
	echo ""

	if [[ "$dry_run" = true ]]; then
		print_info "Run without --dry-run to execute migration"
	elif [[ "$failed" -eq 0 ]]; then
		print_success "Migration complete"

		# Check if x86 brew is now empty
		local remaining
		remaining=$("$X86_BREW" list --formula 2>/dev/null | wc -l | tr -d ' ')
		if [[ "$remaining" -eq 0 ]]; then
			echo ""
			print_info "x86 Homebrew is now empty. You can remove it:"
			echo "  sudo rm -rf /usr/local/Homebrew"
			echo "  sudo rm -rf /usr/local/Cellar"
			echo "  sudo rm -rf /usr/local/bin/brew"
		else
			echo ""
			print_info "$remaining x86 packages remain (no ARM formula or have dependents)"
		fi
	else
		print_warning "Migration completed with $failed failures"
	fi

	# Invalidate cache
	rm -f "$SCAN_CACHE" 2>/dev/null || true

	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Quick status summary
cmd_status() {
	if ! is_apple_silicon; then
		print_info "Intel Mac or non-macOS — Rosetta audit not applicable"
		return 0
	fi

	if ! has_dual_brew; then
		if [[ -x "$ARM_BREW" ]] && [[ ! -x "$X86_BREW" ]]; then
			print_success "Clean ARM-only Homebrew — no Rosetta overhead"
			return 0
		fi
		print_info "No dual-brew setup detected"
		return 0
	fi

	# Use cache if fresh
	if [[ -f "$SCAN_CACHE" ]]; then
		local cache_ts
		cache_ts=$(grep '^timestamp=' "$SCAN_CACHE" 2>/dev/null | cut -d= -f2)
		local now
		now=$(date +%s)
		if [[ -n "$cache_ts" ]] && [[ $((now - cache_ts)) -lt $SCAN_CACHE_TTL ]]; then
			echo "Rosetta Audit Status (cached):"
			grep -E '^(duplicates|migratable|non_migratable)=' "$SCAN_CACHE" | while IFS='=' read -r key val; do
				case "$key" in
				duplicates) echo "  Duplicate x86 packages: $val" ;;
				migratable) echo "  Migratable to ARM: $val" ;;
				non_migratable) echo "  x86-only (no ARM formula): $val" ;;
				esac
			done
			echo ""
			print_info "Run 'rosetta-audit-helper.sh scan' for fresh data"
			return 0
		fi
	fi

	# Quick count without full categorisation
	local x86_count dup_count x86_only_count
	x86_count=$("$X86_BREW" list --formula 2>/dev/null | wc -l | tr -d ' ')
	dup_count=$(get_duplicate_packages | wc -l | tr -d ' ')
	x86_only_count=$(get_x86_only_packages | wc -l | tr -d ' ')

	echo "Rosetta Audit Status:"
	echo "  x86 Homebrew packages: $x86_count"
	echo "  Duplicates (safe to remove): $dup_count"
	echo "  x86-only (need migration check): $x86_only_count"

	if [[ "$x86_only_count" -gt 0 ]] || [[ "$dup_count" -gt 0 ]]; then
		echo ""
		print_info "Run 'rosetta-audit-helper.sh scan' for detailed analysis"
	else
		echo ""
		print_success "No action needed"
	fi

	return 0
}

# Show help
cmd_help() {
	echo "rosetta-audit-helper.sh - Detect and migrate x86 Homebrew packages on Apple Silicon"
	echo ""
	echo "$HELP_LABEL_USAGE"
	echo "  rosetta-audit-helper.sh <command> [options]"
	echo ""
	echo "$HELP_LABEL_COMMANDS"
	echo "  scan              Full audit of x86 packages (default)"
	echo "  migrate           Migrate x86 packages to ARM native"
	echo "  migrate --dry-run Preview migration without changes"
	echo "  status            Quick summary of Rosetta overhead"
	echo "  help              Show this help"
	echo ""
	echo "What this does:"
	echo "  Apple Silicon Macs can run x86 binaries via Rosetta 2 emulation."
	echo "  If you migrated from Intel or installed tools before switching to"
	echo "  ARM Homebrew (/opt/homebrew), you may have x86 packages running"
	echo "  under emulation — typically 30-40% slower than native ARM builds."
	echo ""
	echo "  This tool finds those packages and migrates them to ARM versions."
	echo "  Intel Macs and Linux systems skip gracefully."
	echo ""
	echo "$HELP_LABEL_EXAMPLES"
	echo "  rosetta-audit-helper.sh scan              # See what needs migration"
	echo "  rosetta-audit-helper.sh migrate --dry-run  # Preview changes"
	echo "  rosetta-audit-helper.sh migrate            # Execute migration"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-scan}"
	shift || true

	case "$command" in
	scan) cmd_scan "$@" ;;
	migrate) cmd_migrate "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
