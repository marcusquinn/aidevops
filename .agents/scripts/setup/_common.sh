#!/usr/bin/env bash
# Common helper functions for setup.sh
# Sourced by all setup modules

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Spinner for long-running operations
# Usage: run_with_spinner "Installing package..." command arg1 arg2
run_with_spinner() {
	local message="$1"
	shift
	local pid
	local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	local i=0

	# Start command in background
	"$@" &>/dev/null &
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
		print_error "$message failed"
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
	local cmd=("$shell" "$tmp_script" "${extra_args[@]}")
	if [[ "$use_sudo" == "true" ]]; then
		cmd=(sudo "$shell" "$tmp_script" "${extra_args[@]}")
	fi

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

	# Non-interactive mode: skip
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
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
			eval "$("$brew_prefix/bin/brew" shellenv)"
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

# Find best python3 binary (prefer Homebrew/pyenv over system)
find_python3() {
	local candidates=(
		"/opt/homebrew/bin/python3"
		"/usr/local/bin/python3"
		"$HOME/.pyenv/shims/python3"
	)
	for candidate in "${candidates[@]}"; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	# Fallback to PATH
	if command -v python3 &>/dev/null; then
		command -v python3
		return 0
	fi
	return 1
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
