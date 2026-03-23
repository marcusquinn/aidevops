#!/usr/bin/env bash
# doctor-helper.sh — Detect and consolidate duplicate aidevops/opencode installs
#
# Finds all install locations for both `aidevops` and `opencode` binaries,
# identifies the install method for each, flags conflicts (PATH shadowing,
# version mismatches), and recommends consolidation.
#
# Usage:
#   doctor-helper.sh              # Full diagnostic report
#   doctor-helper.sh --fix        # Interactive consolidation (with confirmation)
#   doctor-helper.sh --json       # Machine-readable JSON output
#   doctor-helper.sh --quiet      # Exit code only (0=clean, 1=conflicts found)

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Globals
CONFLICTS_FOUND=0
FIX_MODE=false
JSON_MODE=false
QUIET_MODE=false

# --- Utility functions ---

print_info() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${BLUE}[INFO]${NC} $1"
	return 0
}
print_success() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}
print_warning() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}
print_error() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}
print_header() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "\n${BOLD}${CYAN}$1${NC}"
	return 0
}
print_detail() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "$1"
	return 0
}

# Resolve symlinks to find the real path (portable, bash 3.2 compatible)
resolve_path() {
	local path="$1"
	local resolved="$path"

	# Follow symlinks iteratively (bash 3.2 compatible — no readlink -f on macOS)
	while [[ -L "$resolved" ]]; do
		local dir
		dir="$(cd "$(dirname "$resolved")" && pwd)"
		resolved="$(readlink "$resolved")"
		# Handle relative symlinks
		if [[ "$resolved" != /* ]]; then
			resolved="$dir/$resolved"
		fi
	done

	# Normalise the path
	if [[ -e "$resolved" ]]; then
		(cd "$(dirname "$resolved")" && echo "$(pwd)/$(basename "$resolved")")
	else
		echo "$resolved"
	fi
	return 0
}

# Identify install method from a resolved binary path
identify_method() {
	local resolved_path="$1"

	case "$resolved_path" in
	*/node_modules/*)
		echo "npm"
		;;
	*/.bun/*)
		echo "bun"
		;;
	*/Cellar/* | */opt/homebrew/* | */usr/local/Homebrew/*)
		echo "brew"
		;;
	*/Git/aidevops/*)
		echo "git-repo"
		;;
	*/Git/opencode/*)
		echo "git-repo"
		;;
	*/.cargo/*)
		echo "cargo"
		;;
	*/go/bin/* | */gopath/*)
		echo "go"
		;;
	*)
		echo "unknown"
		;;
	esac
	return 0
}

# Get version from a binary
get_binary_version() {
	local binary_path="$1"
	local version=""

	# Try --version first, then -v, then version subcommand
	version=$("$binary_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	if [[ -z "$version" ]]; then
		version=$("$binary_path" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	fi
	if [[ -z "$version" ]]; then
		version=$("$binary_path" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	fi

	echo "${version:-unknown}"
	return 0
}

# Find all locations of a binary on PATH using `which -a` or `type -a`
find_all_locations() {
	local binary_name="$1"
	local locations=""

	# which -a is available on macOS and most Linux
	if locations=$(which -a "$binary_name" 2>/dev/null); then
		echo "$locations"
	elif locations=$(type -aP "$binary_name" 2>/dev/null); then
		echo "$locations"
	fi
	return 0
}

# --- Core diagnostic functions ---

# Diagnose a single binary (aidevops or opencode)
# Outputs: sets global arrays via temp files (bash 3.2 compatible — no assoc arrays)
diagnose_binary() {
	local binary_name="$1"
	local locations_raw=""
	local location_count=0
	local active_path=""
	local active_method=""
	local active_version=""
	local has_conflicts=false

	print_header "Checking: $binary_name"

	# Find all locations
	locations_raw=$(find_all_locations "$binary_name")

	if [[ -z "$locations_raw" ]]; then
		print_info "$binary_name is not installed"
		return 0
	fi

	# Deduplicate by resolved path
	local seen_resolved=""
	local unique_paths=""
	local unique_resolved=""
	local unique_methods=""
	local unique_versions=""

	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		local resolved
		resolved=$(resolve_path "$loc")
		local method
		method=$(identify_method "$resolved")

		# Check if we've already seen this resolved path
		local already_seen=false
		while IFS= read -r seen; do
			[[ -z "$seen" ]] && continue
			if [[ "$seen" == "$resolved" ]]; then
				already_seen=true
				break
			fi
		done <<<"$seen_resolved"

		if [[ "$already_seen" == "true" ]]; then
			continue
		fi

		seen_resolved="${seen_resolved}${resolved}"$'\n'

		local version
		version=$(get_binary_version "$loc")

		location_count=$((location_count + 1))

		# First location is the active one (highest PATH priority)
		if [[ $location_count -eq 1 ]]; then
			active_path="$loc"
			active_method="$method"
			active_version="$version"
		fi

		unique_paths="${unique_paths}${loc}"$'\n'
		unique_resolved="${unique_resolved}${resolved}"$'\n'
		unique_methods="${unique_methods}${method}"$'\n'
		unique_versions="${unique_versions}${version}"$'\n'
	done <<<"$locations_raw"

	# Report findings
	if [[ $location_count -eq 0 ]]; then
		print_info "$binary_name is not installed"
		return 0
	fi

	if [[ $location_count -eq 1 ]]; then
		local resolved
		resolved=$(resolve_path "$active_path")
		print_success "$binary_name: 1 install found"
		print_detail "  ${DIM}Path:${NC}    $active_path"
		if [[ "$active_path" != "$resolved" ]]; then
			print_detail "  ${DIM}Target:${NC}  $resolved"
		fi
		print_detail "  ${DIM}Method:${NC}  $active_method"
		print_detail "  ${DIM}Version:${NC} $active_version"
		return 0
	fi

	# Multiple installs found — this is a conflict
	has_conflicts=true
	CONFLICTS_FOUND=1
	print_warning "$binary_name: $location_count installs found (conflict!)"
	print_detail ""

	local idx=0
	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		idx=$((idx + 1))

		local resolved=""
		local method=""
		local version=""

		# Read corresponding resolved/method/version by line number
		resolved=$(echo "$unique_resolved" | sed -n "${idx}p")
		method=$(echo "$unique_methods" | sed -n "${idx}p")
		version=$(echo "$unique_versions" | sed -n "${idx}p")

		if [[ $idx -eq 1 ]]; then
			print_detail "  ${GREEN}#$idx (active on PATH)${NC}"
		else
			print_detail "  ${YELLOW}#$idx (shadowed)${NC}"
		fi
		print_detail "    ${DIM}Path:${NC}    $loc"
		if [[ "$loc" != "$resolved" ]]; then
			print_detail "    ${DIM}Target:${NC}  $resolved"
		fi
		print_detail "    ${DIM}Method:${NC}  $method"
		print_detail "    ${DIM}Version:${NC} $version"
		print_detail ""
	done <<<"$unique_paths"

	# Check for version mismatches
	local first_version=""
	local version_mismatch=false
	while IFS= read -r ver; do
		[[ -z "$ver" ]] && continue
		[[ "$ver" == "unknown" ]] && continue
		if [[ -z "$first_version" ]]; then
			first_version="$ver"
		elif [[ "$ver" != "$first_version" ]]; then
			version_mismatch=true
			break
		fi
	done <<<"$unique_versions"

	if [[ "$version_mismatch" == "true" ]]; then
		print_error "Version mismatch detected across installs!"
		print_detail "  This means \`$binary_name update\` may update one copy while the"
		print_detail "  stale copy continues to run from PATH."
	fi

	# Recommend consolidation
	recommend_consolidation "$binary_name" "$unique_paths" "$unique_methods" "$active_path" "$active_method"

	return 0
}

# Recommend which install to keep and which to remove
recommend_consolidation() {
	local binary_name="$1"
	local paths="$2"
	local methods="$3"
	local active_path="$4"
	local active_method="$5"

	# Preferred method: git-repo for aidevops (always current via `aidevops update`)
	# For opencode: npm or cargo (depending on what's available)
	local preferred_method=""
	if [[ "$binary_name" == "aidevops" ]]; then
		preferred_method="git-repo"
	else
		preferred_method="npm"
	fi

	print_header "Recommendation for $binary_name"

	if [[ "$active_method" == "$preferred_method" ]]; then
		print_success "Active install uses the recommended method ($preferred_method)"
		print_detail "  Remove the other installs to prevent future confusion:"
	else
		print_warning "Active install uses $active_method, but $preferred_method is recommended"
		print_detail "  The $preferred_method install should take PATH priority."
		print_detail "  Remove the others and ensure $preferred_method is first on PATH:"
	fi

	print_detail ""

	local idx=0
	while IFS= read -r method; do
		[[ -z "$method" ]] && continue
		idx=$((idx + 1))
		local path
		path=$(echo "$paths" | sed -n "${idx}p")

		if [[ "$method" == "$preferred_method" ]]; then
			print_detail "  ${GREEN}KEEP${NC}   [$method] $path"
		else
			local remove_cmd=""
			case "$method" in
			npm)
				remove_cmd="npm uninstall -g $binary_name"
				;;
			bun)
				remove_cmd="bun remove -g $binary_name"
				;;
			brew)
				remove_cmd="brew uninstall $binary_name"
				;;
			cargo)
				remove_cmd="cargo uninstall $binary_name"
				;;
			go)
				remove_cmd="rm $path"
				;;
			*)
				remove_cmd="rm $path"
				;;
			esac
			print_detail "  ${RED}REMOVE${NC} [$method] $path"
			print_detail "         ${DIM}Run: $remove_cmd${NC}"
		fi
	done <<<"$methods"

	print_detail ""
	return 0
}

# Interactive fix mode — remove duplicates with user confirmation
run_fix() {
	local binary_name="$1"

	local locations_raw=""
	locations_raw=$(find_all_locations "$binary_name")
	[[ -z "$locations_raw" ]] && return 0

	# Build unique list
	local seen_resolved=""
	local unique_paths=""
	local unique_methods=""
	local count=0

	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		local resolved
		resolved=$(resolve_path "$loc")

		local already_seen=false
		while IFS= read -r seen; do
			[[ -z "$seen" ]] && continue
			if [[ "$seen" == "$resolved" ]]; then
				already_seen=true
				break
			fi
		done <<<"$seen_resolved"

		[[ "$already_seen" == "true" ]] && continue
		seen_resolved="${seen_resolved}${resolved}"$'\n'

		local method
		method=$(identify_method "$resolved")
		count=$((count + 1))
		unique_paths="${unique_paths}${loc}"$'\n'
		unique_methods="${unique_methods}${method}"$'\n'
	done <<<"$locations_raw"

	[[ $count -le 1 ]] && return 0

	# Determine preferred method
	local preferred_method=""
	if [[ "$binary_name" == "aidevops" ]]; then
		preferred_method="git-repo"
	else
		preferred_method="npm"
	fi

	local idx=0
	while IFS= read -r method; do
		[[ -z "$method" ]] && continue
		idx=$((idx + 1))

		if [[ "$method" == "$preferred_method" ]]; then
			continue
		fi

		local path
		path=$(echo "$unique_paths" | sed -n "${idx}p")

		local remove_cmd=""
		case "$method" in
		npm) remove_cmd="npm uninstall -g $binary_name" ;;
		bun) remove_cmd="bun remove -g $binary_name" ;;
		brew) remove_cmd="brew uninstall $binary_name" ;;
		*) remove_cmd="rm \"$path\"" ;;
		esac

		echo ""
		echo -e "${YELLOW}Remove $binary_name [$method] at $path?${NC}"
		echo -e "  Command: $remove_cmd"
		echo -n "  Proceed? [y/N] "
		read -r confirm
		if [[ "$confirm" =~ ^[Yy]$ ]]; then
			echo -e "  ${BLUE}Running:${NC} $remove_cmd"
			if eval "$remove_cmd" 2>&1; then
				print_success "Removed $binary_name [$method]"
			else
				print_error "Failed to remove $binary_name [$method]"
			fi
		else
			print_info "Skipped $binary_name [$method]"
		fi
	done <<<"$unique_methods"

	return 0
}

# --- JSON output ---

json_diagnose_binary() {
	local binary_name="$1"
	local locations_raw=""
	locations_raw=$(find_all_locations "$binary_name")

	if [[ -z "$locations_raw" ]]; then
		echo "  \"$binary_name\": { \"installed\": false, \"locations\": [] }"
		return 0
	fi

	local entries=""
	local seen_resolved=""
	local count=0
	local first_entry=true

	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		local resolved
		resolved=$(resolve_path "$loc")

		local already_seen=false
		while IFS= read -r seen; do
			[[ -z "$seen" ]] && continue
			if [[ "$seen" == "$resolved" ]]; then
				already_seen=true
				break
			fi
		done <<<"$seen_resolved"

		[[ "$already_seen" == "true" ]] && continue
		seen_resolved="${seen_resolved}${resolved}"$'\n'

		local method
		method=$(identify_method "$resolved")
		local version
		version=$(get_binary_version "$loc")
		count=$((count + 1))

		local is_active="false"
		[[ $count -eq 1 ]] && is_active="true"

		if [[ "$first_entry" == "true" ]]; then
			first_entry=false
		else
			entries="${entries},"
		fi

		entries="${entries}
      {
        \"path\": \"$loc\",
        \"resolved\": \"$resolved\",
        \"method\": \"$method\",
        \"version\": \"$version\",
        \"active\": $is_active
      }"
	done <<<"$locations_raw"

	local has_conflicts="false"
	[[ $count -gt 1 ]] && has_conflicts="true"

	echo "  \"$binary_name\": {
    \"installed\": true,
    \"conflict\": $has_conflicts,
    \"location_count\": $count,
    \"locations\": [$entries
    ]
  }"
	return 0
}

# --- Main ---

main() {
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--fix)
			FIX_MODE=true
			shift
			;;
		--json)
			JSON_MODE=true
			shift
			;;
		--quiet | -q)
			QUIET_MODE=true
			shift
			;;
		--help | -h)
			echo "Usage: doctor-helper.sh [--fix] [--json] [--quiet]"
			echo ""
			echo "Detect and consolidate duplicate aidevops/opencode installs."
			echo ""
			echo "Options:"
			echo "  --fix     Interactive removal of duplicate installs"
			echo "  --json    Machine-readable JSON output"
			echo "  --quiet   Exit code only (0=clean, 1=conflicts)"
			echo "  --help    Show this help"
			return 0
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	if [[ "$JSON_MODE" == "true" ]]; then
		echo "{"
		json_diagnose_binary "aidevops"
		echo ","
		json_diagnose_binary "opencode"
		echo ""
		echo "}"
		return 0
	fi

	if [[ "$FIX_MODE" == "true" ]]; then
		print_header "AI DevOps Doctor — Fix Mode"
		echo "This will interactively remove duplicate installs."
		echo ""
		run_fix "aidevops"
		run_fix "opencode"
		echo ""
		print_info "Re-running diagnostics..."
		echo ""
		diagnose_binary "aidevops"
		diagnose_binary "opencode"
		return 0
	fi

	if [[ "$QUIET_MODE" != "true" ]]; then
		print_header "AI DevOps Doctor"
		echo -e "${DIM}Checking for duplicate or conflicting installs...${NC}"
	fi

	diagnose_binary "aidevops"
	diagnose_binary "opencode"

	if [[ "$QUIET_MODE" != "true" ]]; then
		echo ""
		if [[ $CONFLICTS_FOUND -eq 0 ]]; then
			print_success "No conflicts detected. All clean!"
		else
			print_warning "Conflicts detected. Run 'aidevops doctor --fix' to resolve interactively."
		fi
	fi

	return $CONFLICTS_FOUND
}

main "$@"
