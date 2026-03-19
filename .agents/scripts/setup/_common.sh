#!/usr/bin/env bash
# Common helper functions for setup.sh
# Sourced by all setup modules

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Setup summary tracker (GH#5240)
# Tracks what was configured, skipped, and deferred during setup so we can
# print a clear summary at the end. Uses indexed arrays (bash 3.2 compatible).
# =============================================================================
_SETUP_CONFIGURED=()
_SETUP_SKIPPED=()
_SETUP_DEFERRED=()

# Record a successfully configured item
# Usage: setup_track_configured "Google Analytics MCP"
setup_track_configured() {
	_SETUP_CONFIGURED+=("$1")
	return 0
}

# Record a skipped item with reason
# Usage: setup_track_skipped "Google Analytics MCP" "OpenCode config not found"
setup_track_skipped() {
	local item="$1"
	local reason="${2:-}"
	if [[ -n "$reason" ]]; then
		_SETUP_SKIPPED+=("${item}: ${reason}")
	else
		_SETUP_SKIPPED+=("$item")
	fi
	return 0
}

# Record a deferred item with action needed
# Usage: setup_track_deferred "Google Analytics MCP" "Install pipx, then re-run setup"
setup_track_deferred() {
	local item="$1"
	local action="${2:-}"
	if [[ -n "$action" ]]; then
		_SETUP_DEFERRED+=("${item}: ${action}")
	else
		_SETUP_DEFERRED+=("$item")
	fi
	return 0
}

# Print a prerequisite-skip message (replaces the confusing "Setting up X... skipping" pattern)
# Shows what was skipped, why, and what to do about it — without first saying "Setting up..."
# Usage: print_skip "Google Analytics MCP" "OpenCode not installed" "Install OpenCode first: https://opencode.ai"
print_skip() {
	local item="$1"
	local reason="$2"
	local action="${3:-}"
	echo -e "${GRAY}[SKIP]${NC} ${item} -- ${reason}"
	if [[ -n "$action" ]]; then
		echo -e "       ${BLUE}>>>${NC} ${action}"
	fi
	return 0
}

# Print the setup summary at the end of the run
# Shows: configured items, skipped items (with reasons), deferred items (with actions)
print_setup_summary() {
	local configured_count=${#_SETUP_CONFIGURED[@]}
	local skipped_count=${#_SETUP_SKIPPED[@]}
	local deferred_count=${#_SETUP_DEFERRED[@]}

	# Only print summary if there's something to report
	if [[ $configured_count -eq 0 && $skipped_count -eq 0 && $deferred_count -eq 0 ]]; then
		return 0
	fi

	echo ""
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "${BLUE}  Setup Summary${NC}"
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

	if [[ $configured_count -gt 0 ]]; then
		echo ""
		echo -e "  ${GREEN}Configured ($configured_count):${NC}"
		local item
		for item in "${_SETUP_CONFIGURED[@]}"; do
			echo -e "    ${GREEN}+${NC} $item"
		done
	fi

	if [[ $skipped_count -gt 0 ]]; then
		echo ""
		echo -e "  ${GRAY}Skipped ($skipped_count):${NC}"
		local item
		for item in "${_SETUP_SKIPPED[@]}"; do
			echo -e "    ${GRAY}-${NC} $item"
		done
	fi

	if [[ $deferred_count -gt 0 ]]; then
		echo ""
		echo -e "  ${YELLOW}Deferred ($deferred_count) -- complete these to enable:${NC}"
		local item
		for item in "${_SETUP_DEFERRED[@]}"; do
			echo -e "    ${YELLOW}!${NC} $item"
		done
	fi

	echo ""
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	return 0
}

# Spinner for long-running operations
# Usage: run_with_spinner "Installing package..." command arg1 arg2
run_with_spinner() {
	local message="$1"
	shift
	local pid
	local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	local i=0
	local output_file
	output_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$output_file'" RETURN

	# Start command in background, capturing output for failure diagnosis
	"$@" &>"$output_file" &
	pid=$!

	# Show spinner while command runs
	printf "${BLUE}[INFO]${NC} %s " "$message"
	while kill -0 "$pid" 2>/dev/null; do
		printf "\r${BLUE}[INFO]${NC} %s %s" "$message" "${spin_chars:i++%${#spin_chars}:1}"
		sleep 0.1
	done

	# Check exit status
	wait "$pid"
	local exit_code=$?

	# Clear spinner and show result
	printf "\r"
	if [[ $exit_code -eq 0 ]]; then
		print_success "$message done"
	else
		print_error "$message failed. Output:"
		cat "$output_file"
	fi

	return $exit_code
}

# Verified install: download script to temp file, inspect, then execute
# Replaces unsafe curl|sh patterns with download-verify-execute
# Usage: verified_install "description" "url" [extra_args...]
# Options (set before calling):
#   VERIFIED_INSTALL_SUDO="true"  - run with sudo
#   VERIFIED_INSTALL_SHELL="sh"  - use sh instead of bash (default: bash)
# Returns: 0 on success, 1 on failure
verified_install() {
	local description="$1"
	local url="$2"
	shift 2
	local extra_args=("$@")
	local shell="${VERIFIED_INSTALL_SHELL:-bash}"
	local use_sudo="${VERIFIED_INSTALL_SUDO:-false}"

	# Reset options for next call
	VERIFIED_INSTALL_SUDO="false"
	VERIFIED_INSTALL_SHELL="bash"

	# Create secure temp file
	local tmp_script
	tmp_script=$(mktemp "${TMPDIR:-/tmp}/aidevops-install-XXXXXX.sh") || {
		print_error "Failed to create temp file for $description"
		return 1
	}

	# Ensure cleanup on exit from this function
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_script'" RETURN

	# Download script to file (not piped to shell)
	print_info "Downloading $description install script..."
	if ! curl -fsSL "$url" -o "$tmp_script" 2>/dev/null; then
		print_error "Failed to download $description install script from $url"
		return 1
	fi

	# Verify download is non-empty and looks like a script
	if [[ ! -s "$tmp_script" ]]; then
		print_error "Downloaded $description script is empty"
		return 1
	fi

	# Basic content safety check: reject binary content
	if file "$tmp_script" 2>/dev/null | grep -qv 'text'; then
		print_error "Downloaded $description script appears to be binary, not a shell script"
		return 1
	fi

	# Make executable
	chmod +x "$tmp_script"

	# Execute from file
	# Build cmd array once; prepend sudo conditionally to avoid duplicating the safe expansion
	# Use ${extra_args[@]+"${extra_args[@]}"} for safe expansion under set -u when array is empty
	local cmd=()
	[[ "$use_sudo" == "true" ]] && cmd+=(sudo)
	cmd+=("$shell" "$tmp_script" ${extra_args[@]+"${extra_args[@]}"})

	if "${cmd[@]}"; then
		print_success "$description installed"
		return 0
	else
		print_error "$description installation failed"
		return 1
	fi
}

# Confirm step in interactive mode
# Usage: confirm_step "Step description" && function_to_run
# Returns: 0 if confirmed or not interactive, 1 if skipped
confirm_step() {
	local step_name="$1"

	# Skip confirmation in non-interactive mode
	if [[ "$INTERACTIVE_MODE" != "true" ]]; then
		return 0
	fi

	echo ""
	echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "${BLUE}Step:${NC} $step_name"
	echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

	while true; do
		echo -n -e "${GREEN}Run this step? [Y]es / [n]o / [q]uit: ${NC}"
		read -r response
		# Convert to lowercase (bash 3.2 compatible)
		response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
		case "$response" in
		y | yes | "")
			return 0
			;;
		n | no | s | skip)
			print_warning "Skipped: $step_name"
			return 1
			;;
		q | quit | exit)
			echo ""
			print_info "Setup cancelled by user"
			exit 0
			;;
		*)
			echo "Please answer: y (yes), n (no), or q (quit)"
			;;
		esac
	done
}

# Detect package manager
detect_package_manager() {
	if command -v brew >/dev/null 2>&1; then
		echo "brew"
	elif command -v apt-get >/dev/null 2>&1; then
		echo "apt"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v yum >/dev/null 2>&1; then
		echo "yum"
	elif command -v pacman >/dev/null 2>&1; then
		echo "pacman"
	elif command -v apk >/dev/null 2>&1; then
		echo "apk"
	else
		echo "unknown"
	fi
}

# Install packages using detected package manager
install_packages() {
	local pkg_manager="$1"
	shift
	local packages=("$@")

	case "$pkg_manager" in
	brew)
		brew install "${packages[@]}"
		;;
	apt)
		sudo apt-get update && sudo apt-get install -y "${packages[@]}"
		;;
	dnf)
		sudo dnf install -y "${packages[@]}"
		;;
	yum)
		sudo yum install -y "${packages[@]}"
		;;
	pacman)
		sudo pacman -S --noconfirm "${packages[@]}"
		;;
	apk)
		sudo apk add "${packages[@]}"
		;;
	*)
		return 1
		;;
	esac
}

# Offer to install Homebrew (Linuxbrew) on Linux when brew is not available
# Returns: 0 if brew is now available, 1 if user declined or install failed
ensure_homebrew() {
	# Already available
	if command -v brew &>/dev/null; then
		return 0
	fi

	# Only offer on Linux (macOS users should install Homebrew themselves)
	if [[ "$(uname)" == "Darwin" ]]; then
		print_warning "Homebrew not found. Install from https://brew.sh"
		return 1
	fi

	# Non-interactive mode or non-TTY stdin: skip
	if [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
		return 1
	fi

	echo ""
	print_info "Homebrew (Linuxbrew) is not installed."
	print_info "Several optional tools (Beads CLI, Worktrunk, bv) install via Homebrew taps."
	echo ""
	read -r -p "Install Homebrew for Linux? [Y/n]: " install_brew

	if [[ ! "$install_brew" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Homebrew installation"
		return 1
	fi

	print_info "Installing Homebrew (Linuxbrew)..."

	# Prerequisites for Linuxbrew
	if command -v apt-get &>/dev/null; then
		sudo apt-get update -qq
		sudo apt-get install -y -qq build-essential procps curl file git
	elif command -v dnf &>/dev/null; then
		sudo dnf groupinstall -y 'Development Tools'
		sudo dnf install -y procps-ng curl file git
	elif command -v yum &>/dev/null; then
		sudo yum groupinstall -y 'Development Tools'
		sudo yum install -y procps-ng curl file git
	fi

	# Install Homebrew using verified_install pattern
	if verified_install "Homebrew" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"; then
		# Add Homebrew to PATH for this session
		local brew_prefix="/home/linuxbrew/.linuxbrew"
		if [[ -x "$brew_prefix/bin/brew" ]]; then
			# Use source with process substitution instead of eval (style guide: eval is forbidden)
			# shellcheck disable=SC1090
			source <("$brew_prefix/bin/brew" shellenv)
		fi

		# Persist to shell rc files
		local brew_line="eval \"\$($brew_prefix/bin/brew shellenv)\""
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue
			if ! grep -q 'linuxbrew' "$rc_file" 2>/dev/null; then
				{
					echo ""
					echo "# Homebrew (Linuxbrew) - added by aidevops setup"
					echo "$brew_line"
				} >>"$rc_file"
			fi
		done < <(get_all_shell_rcs)

		if command -v brew &>/dev/null; then
			print_success "Homebrew installed and added to PATH"
			return 0
		else
			print_warning "Homebrew installed but not yet in PATH. Restart your shell or run:"
			echo "  $brew_line"
			return 1
		fi
	else
		print_warning "Homebrew installation failed"
		return 1
	fi
}

# Find OpenCode config file (checks multiple possible locations)
# Returns: path to config file, or empty string if not found
find_opencode_config() {
	local candidates=(
		"$HOME/.config/opencode/opencode.json"                     # XDG standard (Linux, some macOS)
		"$HOME/.opencode/opencode.json"                            # Alternative location
		"$HOME/Library/Application Support/opencode/opencode.json" # macOS standard
	)
	for candidate in "${candidates[@]}"; do
		if [[ -f "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# Return latest Homebrew python@3.x formula (e.g. python@3.13).
# Returns 0 and prints formula on success, 1 if unavailable.
get_latest_homebrew_python_formula() {
	if ! command -v brew >/dev/null 2>&1; then
		return 1
	fi

	local latest_formula
	latest_formula=$(brew search --formula '/^python@3\.[0-9]+$/' 2>/dev/null |
		sort -t. -k2 -n -r | head -n 1)

	if [[ -n "$latest_formula" ]]; then
		echo "$latest_formula"
		return 0
	fi

	return 1
}

# Find best python3 binary (prefer Homebrew/pyenv over system)
find_python3() {
	local candidates=(
		"/opt/homebrew/bin/python3"
		"/usr/local/bin/python3"
		"$HOME/.pyenv/shims/python3"
	)

	# Add installed Homebrew versioned Python paths (including keg-only formulae)
	if command -v brew >/dev/null 2>&1; then
		local formula
		while IFS= read -r formula; do
			[[ -z "$formula" ]] && continue
			local prefix
			prefix=$(brew --prefix "$formula" 2>/dev/null || true)
			[[ -z "$prefix" ]] && continue
			local minor
			minor="${formula#python@3.}"
			candidates+=("$prefix/bin/python3")
			candidates+=("$prefix/bin/python3.${minor}")
		done < <(brew list --formula 2>/dev/null | awk '/^python@3\.[0-9]+$/ {print}')
	fi

	# Fallback to python3 on PATH
	if command -v python3 >/dev/null 2>&1; then
		candidates+=("$(command -v python3)")
	fi

	# Choose newest available Python by major.minor
	local best_candidate=""
	local best_major=-1
	local best_minor=-1
	local seen_candidates=" "
	local candidate
	for candidate in "${candidates[@]}"; do
		[[ -x "$candidate" ]] || continue
		if [[ "$seen_candidates" == *" ${candidate} "* ]]; then
			continue
		fi
		seen_candidates="${seen_candidates}${candidate} "

		local version
		version=$("$candidate" -c 'import sys; print("{}.{}".format(sys.version_info[0], sys.version_info[1]))' 2>/dev/null || true)
		local major
		major=$(echo "$version" | cut -d. -f1)
		local minor
		minor=$(echo "$version" | cut -d. -f2)
		if [[ ! "$major" =~ ^[0-9]+$ ]] || [[ ! "$minor" =~ ^[0-9]+$ ]]; then
			continue
		fi

		if ((major > best_major)) || { ((major == best_major)) && ((minor > best_minor)); }; then
			best_major=$major
			best_minor=$minor
			best_candidate="$candidate"
		fi
	done

	if [[ -n "$best_candidate" ]]; then
		echo "$best_candidate"
		return 0
	fi

	return 1
}

# Return the recommended Homebrew Python formula name.
# Uses get_latest_homebrew_python_formula if brew is available, otherwise
# falls back to a sensible default. Reads PYTHON_REQUIRED_MAJOR/MINOR from
# the environment (exported by setup.sh).
# Usage: local formula; formula=$(get_recommended_python_formula)
get_recommended_python_formula() {
	local formula="python@3.13"
	if command -v brew >/dev/null 2>&1; then
		local detected
		detected=$(get_latest_homebrew_python_formula 2>/dev/null || true)
		if [[ -n "$detected" ]]; then
			formula="$detected"
		fi
	fi
	echo "$formula"
	return 0
}

# Offer to install or upgrade Python via Homebrew (interactive prompt).
# Handles both "Python too old" and "Python not found" cases.
# Arguments:
#   $1 - action: "upgrade" or "install"
#   $2 - recommended formula (e.g. python@3.13)
# Prints status messages. Returns 0 on success, 1 on skip/failure.
offer_python_brew_install() {
	local action="$1"
	local recommended_formula="$2"
	local python_required_major="${PYTHON_REQUIRED_MAJOR:-3}"
	local python_required_minor="${PYTHON_REQUIRED_MINOR:-10}"

	if ! command -v brew >/dev/null 2>&1; then
		# No Homebrew — print manual instructions
		if [[ "$action" == "upgrade" ]]; then
			echo "  Upgrade recommendation (macOS): brew install $recommended_formula"
		else
			echo "  Install recommendation: Python $python_required_major.$python_required_minor+"
			echo "    Ubuntu/Debian: sudo apt install python3"
			echo "    Fedora:        sudo dnf install python3"
			echo "    Arch:          sudo pacman -S python"
		fi
		return 1
	fi

	local prompt_verb="Install"
	[[ "$action" == "upgrade" ]] && prompt_verb="Install/upgrade"
	echo "  ${prompt_verb} recommendation: brew install $recommended_formula"

	# Skip interactive prompt in CI or non-interactive runs
	if [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
		print_info "Skipped Python ${action} (non-interactive)"
		return 1
	fi

	read -r -p "${prompt_verb} Python via Homebrew now? [Y/n]: " install_python
	if [[ "$install_python" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing $recommended_formula" brew install "$recommended_formula"; then
			local python3_bin
			if python3_bin=$(find_python3); then
				local python_version
				python_version=$("$python3_bin" -c 'import sys; print("{}.{}.{}".format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))' 2>/dev/null || true)
				print_success "Python ${action}d and available: $python_version"
				return 0
			else
				print_warning "Python formula installed, but python3 is not on PATH yet"
				print_info "Restart your shell or use Homebrew's shellenv instructions"
				return 1
			fi
		else
			print_warning "Python ${action} failed (non-critical)"
			return 1
		fi
	else
		print_info "Skipped Python ${action}"
		return 1
	fi
}

# Install a package globally via npm or bun, with sudo when needed on Linux.
# Usage: npm_global_install "package-name" OR npm_global_install "package@version"
# Uses bun if available (no sudo needed), falls back to npm.
# On Linux with apt-installed npm, automatically prepends sudo.
# Returns: 0 on success, 1 on failure
npm_global_install() {
	local pkg="$1"

	if command -v bun >/dev/null 2>&1; then
		bun install -g "$pkg"
		return $?
	elif command -v npm >/dev/null 2>&1; then
		# npm global installs need sudo on Linux when prefix dir isn't writable
		if [[ "$(uname)" != "Darwin" ]] && [[ ! -w "$(npm config get prefix 2>/dev/null)/lib" ]]; then
			sudo npm install -g "$pkg"
		else
			npm install -g "$pkg"
		fi
		return $?
	else
		return 1
	fi
}

# Validate namespace string for safe use in paths and shell commands
# Returns 0 if valid, 1 if invalid
# Valid: alphanumeric, dash, underscore, forward slash (no .., no shell metacharacters)
validate_namespace() {
	local ns="$1"
	# Reject empty
	[[ -z "$ns" ]] && return 1
	# Reject path traversal
	[[ "$ns" == *".."* ]] && return 1
	# Reject shell metacharacters and dangerous characters
	[[ "$ns" =~ [^a-zA-Z0-9/_-] ]] && return 1
	# Reject absolute paths
	[[ "$ns" == /* ]] && return 1
	# Reject trailing slash (causes issues with rsync/tar exclusions)
	[[ "$ns" == */ ]] && return 1
	return 0
}
