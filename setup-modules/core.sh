#!/usr/bin/env bash
# Core setup functions: requirements, permissions, location
# Part of aidevops setup.sh modularization (t316.3)

bootstrap_repo() {
	# Detect if running from curl (no script directory context)
	local script_path="${BASH_SOURCE[0]}"

	# If script_path is empty, stdin, bash, or /dev/fd/* (process substitution), we're running from curl
	# bash <(curl ...) produces paths like /dev/fd/63
	if [[ -z "$script_path" || "$script_path" == "/dev/stdin" || "$script_path" == "bash" || "$script_path" == /dev/fd/* ]]; then
		print_info "Remote install detected - bootstrapping repository..."

		# On macOS, offer choice: install locally or in an OrbStack VM
		if [[ "$(uname)" == "Darwin" ]]; then
			echo ""
			echo "Where would you like to install aidevops?"
			echo ""
			echo "  1) Install on this Mac (recommended)"
			echo "  2) Install in a Linux VM (via OrbStack)"
			echo ""
			read -r -p "Choose [1/2] (default: 1): " install_target

			if [[ "$install_target" == "2" ]]; then
				print_info "Setting up OrbStack VM installation..."

				# Install OrbStack if not present
				if ! command -v orb >/dev/null 2>&1 && [[ ! -d "/Applications/OrbStack.app" ]]; then
					if command -v brew >/dev/null 2>&1; then
						print_info "Installing OrbStack via Homebrew..."
						brew install --cask orbstack
					else
						print_error "Homebrew is required to install OrbStack"
						echo "Install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
						echo "Then re-run this installer."
						exit 1
					fi
				fi

				# Wait for OrbStack to be ready
				if ! command -v orb >/dev/null 2>&1; then
					print_info "Waiting for OrbStack CLI to become available..."
					# OrbStack installs the CLI at /usr/local/bin/orb
					local wait_count=0
					while ! command -v orb >/dev/null 2>&1 && [[ $wait_count -lt 30 ]]; do
						sleep 2
						((wait_count++)) || true
					done
					if ! command -v orb >/dev/null 2>&1; then
						print_error "OrbStack CLI not found after installation"
						echo "Open OrbStack.app manually, then re-run this installer."
						exit 1
					fi
				fi

				# Create or use existing Ubuntu VM
				local vm_name="aidevops"
				if orb list 2>/dev/null | grep -qxF "$vm_name"; then
					print_info "Using existing OrbStack VM: $vm_name"
				else
					print_info "Creating Ubuntu VM: $vm_name..."
					orb create ubuntu "$vm_name"
				fi

				# Run the installer inside the VM
				print_info "Installing aidevops inside the VM..."
				echo ""
				orb run -m "$vm_name" bash -c 'bash <(curl -fsSL https://aidevops.sh/install)'

				echo ""
				print_success "aidevops installed in OrbStack VM: $vm_name"
				echo ""
				echo "To use aidevops in the VM:"
				echo "  orb shell $vm_name              # Enter the VM"
				echo "  orb run -m $vm_name opencode    # Run OpenCode directly"
				echo ""
				exit 0
			fi
		fi

		# Auto-install git if missing (required for cloning)
		if ! command -v git >/dev/null 2>&1; then
			print_warning "git is required but not installed - attempting auto-install..."
			if [[ "$(uname)" == "Darwin" ]]; then
				# macOS: xcode-select --install triggers git install
				print_info "Installing Xcode Command Line Tools (includes git)..."
				if xcode-select --install 2>/dev/null; then
					# Wait for installation to complete (timeout after 5 minutes)
					print_info "Waiting for Xcode CLT installation to complete (timeout: 5m)..."
					local xcode_wait=0
					local xcode_max_wait=300
					until command -v git >/dev/null 2>&1; do
						sleep 5
						xcode_wait=$((xcode_wait + 5))
						if [[ $xcode_wait -ge $xcode_max_wait ]]; then
							print_error "Timed out waiting for Xcode CLT installation after ${xcode_max_wait}s"
							echo "Complete the installation manually, then re-run this installer."
							exit 1
						fi
					done
					print_success "git installed via Xcode Command Line Tools"
				else
					# Already installed or failed
					if ! command -v git >/dev/null 2>&1; then
						print_error "git installation failed"
						echo "Install git manually: brew install git (macOS)"
						exit 1
					fi
				fi
			elif command -v apt-get >/dev/null 2>&1; then
				print_info "Installing git via apt..."
				sudo apt-get update -qq && sudo apt-get install -y -qq git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v dnf >/dev/null 2>&1; then
				print_info "Installing git via dnf..."
				sudo dnf install -y git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v yum >/dev/null 2>&1; then
				print_info "Installing git via yum..."
				sudo yum install -y git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v pacman >/dev/null 2>&1; then
				print_info "Installing git via pacman..."
				sudo pacman -S --noconfirm git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			elif command -v apk >/dev/null 2>&1; then
				print_info "Installing git via apk..."
				sudo apk add git
				if ! command -v git >/dev/null 2>&1; then
					print_error "git installation failed"
					exit 1
				fi
				print_success "git installed"
			else
				print_error "git is required but not installed and no supported package manager found"
				echo "Install git manually and re-run the installer"
				exit 1
			fi
		fi

		# Create parent directory
		mkdir -p "$(dirname "$INSTALL_DIR")"

		if [[ -d "$INSTALL_DIR/.git" ]]; then
			print_info "Existing installation found - updating..."
			cd "$INSTALL_DIR" || exit 1
			if ! git pull --ff-only; then
				print_warning "Git pull failed - trying reset to origin/main"
				git fetch origin
				git reset --hard origin/main
			fi
		else
			print_info "Cloning aidevops to $INSTALL_DIR..."
			if [[ -d "$INSTALL_DIR" ]]; then
				print_warning "Directory exists but is not a git repo - backing up"
				mv "$INSTALL_DIR" "$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
			fi
			if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
				print_error "Failed to clone repository"
				exit 1
			fi
		fi

		print_success "Repository ready at $INSTALL_DIR"

		# Re-execute the local script
		cd "$INSTALL_DIR" || exit 1
		exec bash "./setup.sh" "$@"
	fi
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
# Many tools in the aidevops ecosystem (Beads, Worktrunk, bv) are distributed
# via Homebrew taps. On macOS, brew is almost always present. On Linux, this
# function offers to install it so those tools can be installed automatically.
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

# Check system requirements
check_requirements() {
	print_info "Checking system requirements..."

	# Ensure Homebrew is in PATH (macOS Apple Silicon)
	if [[ -x "/opt/homebrew/bin/brew" ]] && ! echo "$PATH" | grep -q "/opt/homebrew/bin"; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
		print_warning "Homebrew not in PATH - added for this session"

		# Auto-fix: add Homebrew to all existing shell rc files
		local brew_line='eval "$(/opt/homebrew/bin/brew shellenv)"'
		local fixed_rc=false
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue
			if ! grep -q '/opt/homebrew/bin/brew' "$rc_file" 2>/dev/null; then
				echo "" >>"$rc_file"
				echo "# Homebrew (added by aidevops setup)" >>"$rc_file"
				echo "$brew_line" >>"$rc_file"
				print_success "Added Homebrew to PATH in $rc_file"
				fixed_rc=true
			fi
		done < <(get_all_shell_rcs)

		if [[ "$fixed_rc" == "false" ]]; then
			echo ""
			echo "  To fix permanently, add to your shell rc file:"
			echo "    $brew_line"
			echo ""
		fi
	fi

	# Also check Intel Mac Homebrew location
	if [[ -x "/usr/local/bin/brew" ]] && ! echo "$PATH" | grep -q "/usr/local/bin"; then
		eval "$(/usr/local/bin/brew shellenv)"
		print_warning "Homebrew (/usr/local/bin) not in PATH - added for this session"

		local intel_brew_line='eval "$(/usr/local/bin/brew shellenv)"'
		local intel_rc
		while IFS= read -r intel_rc; do
			[[ -z "$intel_rc" ]] && continue
			if ! grep -q '/usr/local/bin/brew' "$intel_rc" 2>/dev/null; then
				echo "" >>"$intel_rc"
				echo "# Homebrew Intel Mac (added by aidevops setup)" >>"$intel_rc"
				echo "$intel_brew_line" >>"$intel_rc"
				print_success "Added Homebrew to PATH in $intel_rc"
			fi
		done < <(get_all_shell_rcs)
	fi

	local missing_deps=()

	# Check for required commands
	command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
	command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
	command -v ssh >/dev/null 2>&1 || missing_deps+=("ssh")

	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		print_warning "Missing required dependencies: ${missing_deps[*]}"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" == "unknown" ]]; then
			print_error "Could not detect package manager"
			echo ""
			echo "Please install manually:"
			echo "  macOS: brew install ${missing_deps[*]}"
			echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
			echo "  Fedora: sudo dnf install ${missing_deps[*]}"
			echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
			echo "  Arch: sudo pacman -S ${missing_deps[*]}"
			echo "  Alpine: sudo apk add ${missing_deps[*]}"
			exit 1
		fi

		# In non-interactive mode, fail fast on missing deps
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			print_error "Cannot continue without required dependencies (non-interactive mode)"
			exit 1
		fi

		echo ""
		read -r -p "Install missing dependencies using $pkg_manager? [Y/n]: " install_deps

		if [[ "$install_deps" =~ ^[Yy]?$ ]]; then
			print_info "Installing ${missing_deps[*]}..."
			if install_packages "$pkg_manager" "${missing_deps[@]}"; then
				print_success "Dependencies installed successfully"
			else
				print_error "Failed to install dependencies"
				exit 1
			fi
		else
			print_error "Cannot continue without required dependencies"
			exit 1
		fi
	fi

	print_success "All required dependencies found"
}

# Check for quality/linting tools (shellcheck, shfmt)
# These are optional but recommended for development
check_quality_tools() {
	print_info "Checking quality tools..."

	local missing_tools=()

	# Check for shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		print_success "shellcheck: $(shellcheck --version | head -1)"
	else
		missing_tools+=("shellcheck")
	fi

	# Check for shfmt
	if command -v shfmt >/dev/null 2>&1; then
		print_success "shfmt: $(shfmt --version)"
	else
		missing_tools+=("shfmt")
	fi

	# If all tools present, return early
	if [[ ${#missing_tools[@]} -eq 0 ]]; then
		print_success "All quality tools installed"
		return 0
	fi

	# Show missing tools
	print_warning "Missing quality tools: ${missing_tools[*]}"
	print_info "These tools are used by linters-local.sh for code quality checks"

	# In non-interactive mode, just warn and continue
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		print_info "Install later: brew install ${missing_tools[*]}"
		return 0
	fi

	# Offer to install
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$pkg_manager" == "unknown" ]]; then
		print_info "Install manually:"
		echo "  macOS: brew install ${missing_tools[*]}"
		echo "  Ubuntu/Debian: sudo apt-get install ${missing_tools[*]}"
		echo "  Fedora: sudo dnf install ${missing_tools[*]}"
		return 0
	fi

	echo ""
	read -r -p "Install quality tools using $pkg_manager? [Y/n]: " install_quality

	if [[ "$install_quality" =~ ^[Yy]?$ ]]; then
		print_info "Installing ${missing_tools[*]}..."
		if install_packages "$pkg_manager" "${missing_tools[@]}"; then
			print_success "Quality tools installed successfully"
		else
			print_warning "Failed to install some quality tools - continuing anyway"
		fi
	else
		print_info "Skipped quality tools installation"
		print_info "Install later: $pkg_manager install ${missing_tools[*]}"
	fi

	return 0
}

verify_location() {
	local current_dir
	current_dir="$(pwd)"
	local expected_location="$HOME/Git/aidevops"

	if [[ "$current_dir" != "$expected_location" ]]; then
		print_warning "Repository is not in the recommended location"
		print_info "Current location: $current_dir"
		print_info "Recommended location: $expected_location"
		echo ""
		echo "For optimal AI assistant integration, consider moving this repository to:"
		echo "  mkdir -p ~/git"
		echo "  mv '$current_dir' '$expected_location'"
		echo ""
	else
		print_success "Repository is in the recommended location: $expected_location"
	fi
	return 0
}

set_permissions() {
	print_info "Setting proper file permissions..."

	# Make scripts executable (suppress errors for missing paths)
	chmod +x ./*.sh 2>/dev/null || true
	chmod +x .agents/scripts/*.sh 2>/dev/null || true
	# Also handle modularised subdirectories (e.g. memory/, supervisor-modules/)
	find .agents/scripts -mindepth 2 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
	chmod +x ssh/*.sh 2>/dev/null || true

	# Secure configuration files
	chmod 600 configs/*.json 2>/dev/null || true

	print_success "File permissions set"
	return 0
}
