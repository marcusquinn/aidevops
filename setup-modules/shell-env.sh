#!/usr/bin/env bash
# Shell environment setup functions: oh-my-zsh, shell-compat, aliases, terminal-title
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Detect the shell currently executing this script (zsh, bash, or fallback)
detect_running_shell() {
	if [[ -n "${ZSH_VERSION:-}" ]]; then
		echo "zsh"
	elif [[ -n "${BASH_VERSION:-}" ]]; then
		echo "bash"
	else
		basename "${SHELL:-/bin/bash}"
	fi
	return 0
}

# Detect the user's default login shell from $SHELL
detect_default_shell() {
	basename "${SHELL:-/bin/bash}"
	return 0
}

# Usage: get_shell_rc "zsh" or get_shell_rc "bash"
get_shell_rc() {
	local shell_name
	shell_name="$1"
	case "$shell_name" in
	zsh)
		echo "$HOME/.zshrc"
		;;
	bash)
		if [[ "$(uname)" == "Darwin" ]]; then
			echo "$HOME/.bash_profile"
		else
			echo "$HOME/.bashrc"
		fi
		;;
	fish)
		echo "$HOME/.config/fish/config.fish"
		;;
	ksh)
		echo "$HOME/.kshrc"
		;;
	*)
		# Fallback: check common rc files
		if [[ -f "$HOME/.zshrc" ]]; then
			echo "$HOME/.zshrc"
		elif [[ -f "$HOME/.bashrc" ]]; then
			echo "$HOME/.bashrc"
		elif [[ -f "$HOME/.bash_profile" ]]; then
			echo "$HOME/.bash_profile"
		else
			echo ""
		fi
		;;
	esac
	return 0
}

# Return all relevant shell rc file paths for the current platform
get_all_shell_rcs() {
	local rcs=()

	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: always include zsh (default since Catalina) and bash_profile
		[[ -f "$HOME/.zshrc" ]] && rcs+=("$HOME/.zshrc")
		[[ -f "$HOME/.bash_profile" ]] && rcs+=("$HOME/.bash_profile")
		# If neither exists, create .zshrc (macOS default)
		if [[ ${#rcs[@]} -eq 0 ]]; then
			touch "$HOME/.zshrc"
			rcs+=("$HOME/.zshrc")
		fi
	else
		# Linux: use the default shell's rc file
		local default_shell
		default_shell=$(detect_default_shell)
		local rc
		rc=$(get_shell_rc "$default_shell")
		if [[ -n "$rc" ]]; then
			rcs+=("$rc")
		fi
	fi

	printf '%s\n' "${rcs[@]}"
	return 0
}

# Offer to change the default shell to zsh after Oh My Zsh is installed.
_omz_offer_shell_change() {
	local default_shell="$1"

	if [[ "$default_shell" == "zsh" ]]; then
		return 0
	fi

	echo ""
	setup_prompt change_shell "Change default shell to zsh? [y/N]: " "n"
	if [[ "$change_shell" =~ ^[Yy]$ ]]; then
		if chsh -s "$(command -v zsh)"; then
			print_success "Default shell changed to zsh"
			print_info "Restart your terminal for the change to take effect"
		else
			print_warning "Failed to change shell - run manually: chsh -s $(command -v zsh)"
		fi
	fi

	return 0
}

# Run the Oh My Zsh installer and handle post-install steps.
_omz_run_install() {
	local default_shell="$1"

	print_info "Installing Oh My Zsh..."
	# Use verified download + --unattended to avoid changing the shell or starting zsh
	# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
	VERIFIED_INSTALL_SHELL="sh"
	if verified_install "Oh My Zsh" "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" --unattended; then
		print_success "Oh My Zsh installed"
		if [[ ! -f "$HOME/.zshrc" ]]; then
			print_warning ".zshrc not created - Oh My Zsh may not have installed correctly"
		fi
		_omz_offer_shell_change "$default_shell"
	else
		print_warning "Oh My Zsh installation failed"
		print_info "Install manually: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
	fi

	return 0
}

# Offer to install Oh My Zsh if zsh is the default shell and OMZ is not present
setup_oh_my_zsh() {
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v zsh >/dev/null 2>&1; then
		print_skip "Oh My Zsh" "zsh not installed" "Install zsh first, then re-run setup"
		setup_track_skipped "Oh My Zsh" "zsh not installed"
		return 0
	fi

	if [[ -d "$HOME/.oh-my-zsh" ]]; then
		print_success "Oh My Zsh already installed"
		setup_track_configured "Oh My Zsh"
		return 0
	fi

	local default_shell
	default_shell=$(detect_default_shell)

	if [[ "$default_shell" != "zsh" && "$(uname)" != "Darwin" ]]; then
		print_skip "Oh My Zsh" "default shell is $default_shell (not zsh)" "Change default shell to zsh: chsh -s \$(which zsh)"
		setup_track_skipped "Oh My Zsh" "default shell is $default_shell"
		return 0
	fi

	print_info "Oh My Zsh enhances zsh with themes, plugins, and completions"
	echo "  Many tools installed later (git, fd, brew) benefit from Oh My Zsh plugins."
	echo "  This is optional - plain zsh works fine without it."
	echo ""

	setup_prompt install_omz "Install Oh My Zsh? [y/N]: " "n"

	if [[ "$install_omz" =~ ^[Yy]$ ]]; then
		_omz_run_install "$default_shell"
	else
		print_info "Skipped Oh My Zsh installation"
		print_info "Install later: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
	fi

	return 0
}

# Check that both zsh and bash are installed and collect existing bash config files.
# Prints the bash config file paths (one per line) on success.
# Returns 1 if prerequisites are not met (caller should return 0 early).
_shell_compat_check_prereqs() {
	local shared_profile="$1"
	local zsh_rc="$2"

	if [[ -f "$shared_profile" ]]; then
		print_success "Cross-shell compatibility already configured ($shared_profile)"
		return 1
	fi

	if ! command -v zsh >/dev/null 2>&1; then
		print_info "zsh not installed - cross-shell setup not needed"
		return 1
	fi
	if ! command -v bash >/dev/null 2>&1; then
		print_info "bash not installed - cross-shell setup not needed"
		return 1
	fi

	# Collect all bash config files that exist
	# macOS: .bash_profile (login) + .bashrc (interactive, often sourced by .bash_profile)
	# Linux: .bashrc (primary) + .bash_profile (login, often sources .bashrc)
	# We check all of them on both platforms since tools write to either
	local -a bash_files=()
	[[ -f "$HOME/.bash_profile" ]] && bash_files+=("$HOME/.bash_profile")
	[[ -f "$HOME/.bashrc" ]] && bash_files+=("$HOME/.bashrc")
	[[ -f "$HOME/.profile" ]] && bash_files+=("$HOME/.profile")

	if [[ ${#bash_files[@]} -eq 0 ]]; then
		print_info "No bash config files found - skipping cross-shell setup"
		return 1
	fi

	if [[ ! -f "$zsh_rc" ]]; then
		print_info "No .zshrc found - skipping cross-shell setup"
		return 1
	fi

	printf '%s\n' "${bash_files[@]}"
	return 0
}

# Count portable customizations (exports, aliases, PATH entries) across bash config files.
# Prints "exports aliases paths" space-separated.
_shell_compat_count_customizations() {
	local total_exports=0
	local total_aliases=0
	local total_paths=0

	local src_file
	for src_file in "$@"; do
		local n
		# grep -c exits 1 on no match; || : prevents ERR trap noise
		# File existence already verified when building bash_files array
		n=$(grep -cE '^\s*export\s+[A-Z]' "$src_file" || :)
		total_exports=$((total_exports + ${n:-0}))
		n=$(grep -cE '^\s*alias\s+' "$src_file" || :)
		total_aliases=$((total_aliases + ${n:-0}))
		n=$(grep -cE 'PATH.*=' "$src_file" || :)
		total_paths=$((total_paths + ${n:-0}))
	done

	echo "$total_exports $total_aliases $total_paths"
	return 0
}

# Return 0 if the line is bash-specific and should NOT be extracted to shared profile.
_shell_compat_is_bash_specific() {
	local line="$1"
	case "$line" in
	*shopt*) return 0 ;;
	*PROMPT_COMMAND*) return 0 ;;
	*PS1=*) return 0 ;;
	*PS2=*) return 0 ;;
	*bash_completion*) return 0 ;;
	*"complete "*) return 0 ;;
	*"bind "*) return 0 ;;
	*HISTCONTROL*) return 0 ;;
	*HISTFILESIZE*) return 0 ;;
	*HISTSIZE*) return 0 ;;
	*"source /etc/bash"*) return 0 ;;
	*". /etc/bash"*) return 0 ;;
	*"source /etc/profile"*) return 0 ;;
	*". /etc/profile"*) return 0 ;;
	# Skip lines that source .bashrc from .bash_profile (circular)
	*".bashrc"*) return 0 ;;
	# Skip lines that source .shell_common (we'll add this ourselves)
	*"shell_common"*) return 0 ;;
	esac
	return 1
}

# Return 0 if the line is a portable shell customization (exports, aliases, PATH, etc.).
_shell_compat_is_portable() {
	local line="$1"
	case "$line" in
	export\ [A-Z]* | export\ PATH*) return 0 ;;
	alias\ *) return 0 ;;
	eval\ *) return 0 ;;
	*PATH=*) return 0 ;;
	# Also match 'source' and '. ' commands (tool integrations like nvm, rvm, pyenv)
	source\ * | .\ /* | .\ \$* | .\ \~*) return 0 ;;
	esac
	return 1
}

# Write the header block for the shared profile file.
_shell_compat_write_profile_header() {
	local shared_profile="$1"

	{
		echo "# Shared shell profile - sourced by both bash and zsh"
		echo "# Created by aidevops setup to preserve customizations across shell switches"
		echo "# Edit this file for settings you want in BOTH bash and zsh"
		echo "# Shell-specific settings go in ~/.bashrc or ~/.zshrc"
		echo ""
	} >"$shared_profile"

	return 0
}

# Extract portable lines from one source file into the shared profile.
# Skips duplicates (tracked via seen_lines nameref-style via global).
# Prints the number of lines extracted from this file.
# Args: shared_profile src_file [seen_line1 seen_line2 ...]
# Returns extracted count via stdout; seen lines via stdout after count (newline-separated).
_shell_compat_extract_one_file() {
	local shared_profile="$1"
	local src_file="$2"
	shift 2
	# remaining args are already-seen lines

	local src_basename
	src_basename=$(basename "$src_file")
	local added_header=false
	local extracted=0

	# Build a local seen set from passed args
	local -a seen_lines=("$@")

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" ]] && continue
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		_shell_compat_is_bash_specific "$line" && continue
		_shell_compat_is_portable "$line" || continue

		# Deduplicate
		local is_dup=false
		local seen
		for seen in "${seen_lines[@]+"${seen_lines[@]}"}"; do
			if [[ "$seen" == "$line" ]]; then
				is_dup=true
				break
			fi
		done
		[[ "$is_dup" == "true" ]] && continue

		if [[ "$added_header" == "false" ]]; then
			echo "" >>"$shared_profile"
			echo "# From $src_basename" >>"$shared_profile"
			added_header=true
		fi
		echo "$line" >>"$shared_profile"
		seen_lines+=("$line")
		((++extracted))
	done <"$src_file"

	# Output: count on first line, then new seen lines (for caller to accumulate)
	echo "$extracted"
	printf '%s\n' "${seen_lines[@]+"${seen_lines[@]}"}"
	return 0
}

# Extract portable customizations from bash config files into the shared profile.
# Returns the count of extracted lines.
_shell_compat_extract_to_shared_profile() {
	local shared_profile="$1"
	shift
	# remaining args are bash_files

	_shell_compat_write_profile_header "$shared_profile"

	local -a seen_lines=()
	local extracted=0

	local src_file
	for src_file in "$@"; do
		local file_out
		file_out=$(_shell_compat_extract_one_file "$shared_profile" "$src_file" "${seen_lines[@]+"${seen_lines[@]}"}")
		local file_count
		file_count=$(printf '%s\n' "$file_out" | head -1)
		extracted=$((extracted + file_count))
		# Rebuild seen_lines from output (skip first line = count)
		local -a new_seen=()
		while IFS= read -r seen_line; do
			[[ -n "$seen_line" ]] && new_seen+=("$seen_line")
		done < <(printf '%s\n' "$file_out" | tail -n +2)
		seen_lines=("${new_seen[@]+"${new_seen[@]}"}")
	done

	echo "$extracted"
	return 0
}

# Add sourcing of the shared profile to .zshrc and all bash config files.
_shell_compat_add_sourcing() {
	local zsh_rc="$1"
	shift
	# remaining args are bash_files

	# Add sourcing to .zshrc if not already present (existence verified above)
	if ! grep -q 'shell_common' "$zsh_rc"; then
		{
			echo ""
			echo "# Cross-shell compatibility (added by aidevops setup)"
			echo "# Sources shared profile so bash customizations work in zsh too"
			# shellcheck disable=SC2016
			echo '[ -f "$HOME/.shell_common" ] && . "$HOME/.shell_common"'
		} >>"$zsh_rc"
		print_success "Added shared profile sourcing to .zshrc"
	fi

	# Add sourcing to bash config files if not already present
	# File existence already verified when building bash_files array
	local src_file
	for src_file in "$@"; do
		if ! grep -q 'shell_common' "$src_file"; then
			{
				echo ""
				echo "# Cross-shell compatibility (added by aidevops setup)"
				echo "# Shared profile - edit ~/.shell_common for settings in both shells"
				# shellcheck disable=SC2016
				echo '[ -f "$HOME/.shell_common" ] && . "$HOME/.shell_common"'
			} >>"$src_file"
			print_success "Added shared profile sourcing to $(basename "$src_file")"
		fi
	done

	return 0
}

# Print detected customization counts and prompt the user.
# Returns 1 if the user declines (caller should return 0).
_shell_compat_prompt_user() {
	local file_count="$1"
	local total_exports="$2"
	local total_aliases="$3"
	local total_paths="$4"

	print_info "Detected bash customizations across ${file_count} file(s):"
	echo "  Exports: $total_exports, Aliases: $total_aliases, PATH entries: $total_paths"
	echo ""
	print_info "Best practice: create a shared profile (~/.shell_common) sourced by"
	print_info "both bash and zsh, so your customizations work in either shell."
	echo ""

	local setup_compat
	setup_prompt setup_compat "Create shared shell profile for cross-shell compatibility? [Y/n]: " "Y"

	if [[ ! "$setup_compat" =~ ^[Yy]?$ ]]; then
		print_info "Skipped cross-shell compatibility setup"
		print_info "Set up later by creating ~/.shell_common and sourcing it from both shells"
		return 1
	fi

	return 0
}

# Do the extraction and sourcing steps, then print the success summary.
_shell_compat_do_extract() {
	local shared_profile="$1"
	local zsh_rc="$2"
	shift 2
	# remaining args are bash_files

	# We extract: exports, PATH modifications, aliases, eval statements, source commands
	# We skip: bash-specific syntax (shopt, PROMPT_COMMAND, PS1, completion, bind, etc.)
	# We deduplicate lines that appear in multiple files (e.g. .bash_profile sources .bashrc)
	print_info "Creating shared profile: $shared_profile"

	local extracted
	extracted=$(_shell_compat_extract_to_shared_profile "$shared_profile" "$@")

	if [[ $extracted -eq 0 ]]; then
		rm -f "$shared_profile"
		print_info "No portable customizations found to extract"
		return 0
	fi

	chmod 644 "$shared_profile"
	print_success "Extracted $extracted unique customization(s) to $shared_profile"
	_shell_compat_add_sourcing "$zsh_rc" "$@"

	echo ""
	print_success "Cross-shell compatibility configured"
	print_info "Your customizations are now in: $shared_profile"
	print_info "Both bash and zsh will source this file automatically."
	print_info "Edit ~/.shell_common for settings you want in both shells."
	print_info "Use ~/.bashrc or ~/.zshrc for shell-specific settings only."

	return 0
}

# Extract portable customizations from bash configs into a shared profile for cross-shell use
setup_shell_compatibility() {
	print_info "Setting up cross-shell compatibility..."

	local shared_profile="$HOME/.shell_common"
	local zsh_rc="$HOME/.zshrc"

	# Check prerequisites; collect bash config files
	local -a bash_files=()
	local prereq_out
	prereq_out=$(_shell_compat_check_prereqs "$shared_profile" "$zsh_rc") || return 0
	while IFS= read -r line; do
		[[ -n "$line" ]] && bash_files+=("$line")
	done <<<"$prereq_out"

	# Count customizations across all bash config files
	local counts
	counts=$(_shell_compat_count_customizations "${bash_files[@]}")
	local total_exports total_aliases total_paths
	read -r total_exports total_aliases total_paths <<<"$counts"

	if [[ $total_exports -eq 0 && $total_aliases -eq 0 && $total_paths -eq 0 ]]; then
		print_info "No bash customizations detected - skipping cross-shell setup"
		return 0
	fi

	_shell_compat_prompt_user "${#bash_files[@]}" "$total_exports" "$total_aliases" "$total_paths" || return 0
	_shell_compat_do_extract "$shared_profile" "$zsh_rc" "${bash_files[@]}"

	return 0
}

# Check for optional dependencies (sshpass) and offer to install them
check_optional_deps() {
	print_info "Checking optional dependencies..."

	local missing_optional=()

	if ! command -v sshpass >/dev/null 2>&1; then
		missing_optional+=("sshpass")
	else
		print_success "sshpass found"
	fi

	check_python_version "" "skills/tools" >/dev/null || true

	if [[ ${#missing_optional[@]} -gt 0 ]]; then
		print_warning "Missing optional dependencies: ${missing_optional[*]}"
		echo "  sshpass - needed for password-based SSH (like Hostinger)"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			setup_prompt install_optional "Install optional dependencies using $pkg_manager? [Y/n]: " "Y"

			if [[ "$install_optional" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_optional[*]}..."
				if install_packages "$pkg_manager" "${missing_optional[@]}"; then
					print_success "Optional dependencies installed"
				else
					print_warning "Failed to install optional dependencies (non-critical)"
				fi
			else
				print_info "Skipped optional dependencies"
			fi
		fi
	fi
	return 0
}

# Update a single rc file to include ~/.local/bin on PATH.
# Prints "added:<file>" or "already:<file>" to stdout.
_local_bin_update_rc_file() {
	local rc_file="$1"
	local path_line="$2"

	# Create the rc file if it doesn't exist (ensure parent dir exists for fish etc.)
	if [[ ! -f "$rc_file" ]]; then
		mkdir -p "$(dirname "$rc_file")"
		touch "$rc_file"
	fi

	# Check if already added (file created above if it didn't exist)
	if grep -q '\.local/bin' "$rc_file"; then
		echo "already:$rc_file"
		return 0
	fi

	# Add to shell config
	{
		echo ""
		echo "# Added by aidevops setup"
		echo "$path_line"
	} >>"$rc_file"
	echo "added:$rc_file"
	return 0
}

# Print result messages for add_local_bin_to_path.
_local_bin_report_results() {
	local added_to="$1"
	local already_in="$2"
	local path_line="$3"

	if [[ -n "$added_to" ]]; then
		print_success "Added $HOME/.local/bin to PATH in: $added_to"
		print_info "Restart your terminal to use 'aidevops' command"
	fi

	if [[ -n "$already_in" ]]; then
		print_info "$HOME/.local/bin already in PATH in: $already_in"
	fi

	if [[ -z "$added_to" && -z "$already_in" ]]; then
		print_warning "Could not detect shell config file"
		print_info "Add this to your shell config: $path_line"
	fi

	return 0
}

# Add ~/.local/bin to PATH in all shell rc files for the aidevops CLI
add_local_bin_to_path() {
	# shellcheck disable=SC2016 # path_line is written to rc files; must expand at shell startup, not now
	local path_line='export PATH="$HOME/.local/bin:$PATH"'
	local added_to=""
	local already_in=""

	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		local result
		result=$(_local_bin_update_rc_file "$rc_file" "$path_line")
		case "$result" in
		added:*) added_to="${added_to:+$added_to, }${result#added:}" ;;
		already:*) already_in="${already_in:+$already_in, }${result#already:}" ;;
		esac
	done < <(get_all_shell_rcs)

	_local_bin_report_results "$added_to" "$already_in" "$path_line"

	# Also export for current session
	export PATH="$HOME/.local/bin:$PATH"

	return 0
}

# GH#2915, GH#2993: Ensure all processes use the safe ShellCheck wrapper.
#
# The bash language server hardcodes --external-sources in every ShellCheck
# invocation, causing exponential memory growth (9+ GB) when source chains
# span 463+ scripts. The wrapper strips --external-sources and enforces a
# background RSS watchdog (ulimit -v is broken on macOS ARM — EINVAL).
#
# GH#2915 set SHELLCHECK_PATH env var, but bash-language-server ignores it —
# it resolves `shellcheck` via PATH lookup, finding /opt/homebrew/bin/shellcheck
# directly. GH#2993 fixes this by placing a shim on PATH ahead of the real binary.
#
# Four layers ensure all processes use the wrapper:
#   0. PATH shim — ~/.aidevops/bin/shellcheck symlink + PATH prepend (GH#2993)
#   1. launchctl setenv (macOS) — GUI-launched apps (current boot only)
#   2. .zshenv — ALL zsh processes including non-interactive (persists)
#   3. Shell rc files (.zshrc, .bash_profile) — interactive terminals
#
# Layer 0 is the primary fix: bash-language-server does a PATH lookup for
# "shellcheck". By placing ~/.aidevops/bin first on PATH with a symlink to
# the wrapper, the language server finds the wrapper instead of the real binary.
# Layers 1-3 are retained for tools that honour SHELLCHECK_PATH.
#
# CRITICAL: ~/.aidevops/bin MUST be at the START of PATH, not the end.
# If it appears after /opt/homebrew/bin, the real shellcheck is found first
# and the wrapper is bypassed entirely. The launchctl setenv always prepends,
# and the case-guard in shell rc files ensures it stays first.

# Verify the shellcheck wrapper exists and is executable.
# Returns 1 if setup should be aborted (caller returns 0).
_shellcheck_wrapper_verify() {
	local wrapper_path="$1"

	if [[ ! -x "$wrapper_path" ]]; then
		if [[ -f "$wrapper_path" ]]; then
			chmod +x "$wrapper_path"
		else
			print_warning "ShellCheck wrapper not found at $wrapper_path (will be available after deploy)"
			return 1
		fi
	fi

	if ! "$wrapper_path" --version >/dev/null 2>&1; then
		print_warning "ShellCheck wrapper cannot find real shellcheck binary — skipping"
		return 1
	fi

	return 0
}

# Layer 0: Create the PATH shim (GH#2993).
# Places a symlink to the wrapper in ~/.aidevops/bin so bash-language-server
# finds the wrapper via PATH lookup before the real shellcheck binary.
_shellcheck_wrapper_setup_shim() {
	local wrapper_path="$1"
	local shim_dir="$HOME/.aidevops/bin"
	local shim_path="$shim_dir/shellcheck"

	mkdir -p "$shim_dir"

	local wrapper_realpath
	wrapper_realpath="$(realpath "$wrapper_path" 2>/dev/null || readlink -f "$wrapper_path" 2>/dev/null || echo "$wrapper_path")"

	if [[ -L "$shim_path" ]]; then
		local current_target
		current_target="$(realpath "$shim_path" 2>/dev/null || readlink -f "$shim_path" 2>/dev/null || echo "")"
		if [[ "$current_target" != "$wrapper_realpath" ]]; then
			ln -sf "$wrapper_path" "$shim_path"
			print_info "Updated shellcheck shim symlink: $shim_path → $wrapper_path"
		fi
	elif [[ -e "$shim_path" ]]; then
		# Regular file exists — back up and replace with symlink
		mv "$shim_path" "${shim_path}.bak.$(date +%Y%m%d_%H%M%S)"
		ln -sf "$wrapper_path" "$shim_path"
		print_info "Replaced shellcheck shim with symlink: $shim_path → $wrapper_path"
	else
		ln -sf "$wrapper_path" "$shim_path"
		print_success "Created shellcheck shim: $shim_path → $wrapper_path"
	fi

	return 0
}

# Layer 1: Set SHELLCHECK_PATH and prepend shim dir via launchctl (macOS only).
# Affects all GUI-launched processes for the current boot session.
_shellcheck_wrapper_setup_launchctl() {
	local wrapper_path="$1"
	local shim_dir="$2"

	# Note: 2>/dev/null on launchctl is intentional — launchctl may not be
	# available in non-GUI contexts (SSH, containers). Unlike grep where we
	# want errors visible, launchctl failure is a non-fatal fallback.
	if launchctl setenv SHELLCHECK_PATH "$wrapper_path" 2>/dev/null; then
		print_info "Set SHELLCHECK_PATH via launchctl (GUI processes)"
	fi

	# Build a clean PATH with shim_dir at the front, removing any existing
	# occurrence to prevent duplicates while ensuring first position.
	# Handle the empty-PATH edge case to avoid a trailing colon (which
	# resolves to "." and is a PATH injection vector).
	local clean_path
	clean_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -Fxv "$shim_dir" | tr '\n' ':' | sed 's/:$//')
	local new_path
	if [[ -n "$clean_path" ]]; then
		new_path="${shim_dir}:${clean_path}"
	else
		new_path="${shim_dir}"
	fi
	if launchctl setenv PATH "$new_path" 2>/dev/null; then
		print_info "Prepended $shim_dir to PATH via launchctl (GUI processes)"
	fi

	return 0
}

# Layer 2: Configure SHELLCHECK_PATH and PATH shim in .zshenv.
# Affects ALL zsh processes including non-interactive (e.g. bash-language-server).
_shellcheck_wrapper_setup_zshenv() {
	local env_line="$1"
	local path_line="$2"
	local shim_dir="$3"
	local zshenv="$HOME/.zshenv"
	local added_to_out=""
	local already_in_out=""

	if [[ -f "$zshenv" ]] || command -v zsh >/dev/null 2>&1; then
		touch "$zshenv"

		# SHELLCHECK_PATH env var (for tools that honour it)
		if grep -q 'SHELLCHECK_PATH' "$zshenv"; then
			already_in_out="$zshenv"
		else
			{
				echo ""
				echo "# Added by aidevops setup (GH#2915: prevent ShellCheck memory explosion)"
				echo "$env_line"
			} >>"$zshenv"
			added_to_out="$zshenv"
		fi

		# PATH prepend for ~/.aidevops/bin (GH#2993: shim must be on PATH)
		# Remove stale old-form entries (case guard that only checked presence,
		# not position — left the shim at the end of PATH on upgrades)
		# shellcheck disable=SC2016 # Matching literal $PATH text in rc files, not expanding
		if grep -q 'case ":$PATH:" in.*\.aidevops/bin' "$zshenv"; then
			# Remove the old case-guard line (sed is appropriate here — targeted single-line removal)
			# shellcheck disable=SC2016
			sed -i.bak '/case ":$PATH:" in.*\.aidevops\/bin/d' "$zshenv"
			rm -f "${zshenv}.bak"
		fi
		# Use exact-line match for the new sanitize-and-prepend form
		if ! grep -Fq '_aidevops_shim' "$zshenv"; then
			{
				echo ""
				echo "# Added by aidevops setup (GH#2993: shellcheck shim on PATH)"
				echo "$path_line"
			} >>"$zshenv"
			print_success "Prepended $shim_dir to PATH in .zshenv"
		else
			print_info "$shim_dir already on PATH in .zshenv"
		fi
	fi

	# Return values via stdout (space-separated)
	echo "$added_to_out $already_in_out"
	return 0
}

# Remove stale old-form PATH entries for the aidevops shim from an rc file.
# Handles both bash/zsh case-guard form and fish 'contains' form.
_shellcheck_wrapper_remove_stale_path() {
	local rc_file="$1"
	local is_fish_rc="$2"

	# Remove stale old-form entries (case guard that only checked presence,
	# not position — left the shim at the end of PATH on upgrades)
	# shellcheck disable=SC2016 # Matching literal $PATH text in rc files, not expanding
	if grep -q 'case ":$PATH:" in.*\.aidevops/bin' "$rc_file"; then
		# shellcheck disable=SC2016
		sed -i.bak '/case ":$PATH:" in.*\.aidevops\/bin/d' "$rc_file"
		rm -f "${rc_file}.bak"
	fi
	# For fish: also remove old 'contains' form that only checked presence
	if [[ "$is_fish_rc" == "true" ]] && grep -q 'contains.*\.aidevops/bin' "$rc_file"; then
		sed -i.bak '/contains.*\.aidevops\/bin/d' "$rc_file"
		rm -f "${rc_file}.bak"
	fi

	return 0
}

# Configure SHELLCHECK_PATH and PATH shim in a single rc file.
# Prints "added:<file>" or "already:<file>" to stdout.
_shellcheck_wrapper_setup_one_rc() {
	local rc_file="$1"
	local env_line="$2"
	local path_line="$3"
	local env_line_fish="$4"
	local path_line_fish="$5"

	if [[ ! -f "$rc_file" ]]; then
		mkdir -p "$(dirname "$rc_file")"
		touch "$rc_file"
	fi

	# Detect fish config — uses set -gx syntax, not export
	local is_fish_rc=false
	[[ "$rc_file" == *"/fish/config.fish" ]] && is_fish_rc=true

	# Select the correct syntax for this shell
	local rc_env_line="$env_line"
	local rc_path_line="$path_line"
	if [[ "$is_fish_rc" == "true" ]]; then
		rc_env_line="$env_line_fish"
		rc_path_line="$path_line_fish"
	fi

	# SHELLCHECK_PATH env var
	if grep -q 'SHELLCHECK_PATH' "$rc_file"; then
		echo "already:$rc_file"
	else
		{
			echo ""
			echo "# Added by aidevops setup (GH#2915: prevent ShellCheck memory explosion)"
			echo "$rc_env_line"
		} >>"$rc_file"
		echo "added:$rc_file"
	fi

	# PATH prepend for ~/.aidevops/bin (GH#2993)
	_shellcheck_wrapper_remove_stale_path "$rc_file" "$is_fish_rc"
	# Check for the new sanitize-and-prepend form (uses _aidevops_shim variable)
	if ! grep -Fq '_aidevops_shim' "$rc_file"; then
		{
			echo ""
			echo "# Added by aidevops setup (GH#2993: shellcheck shim on PATH)"
			echo "$rc_path_line"
		} >>"$rc_file"
	fi

	return 0
}

# Layer 3: Configure SHELLCHECK_PATH and PATH shim in interactive shell rc files.
_shellcheck_wrapper_setup_rc_files() {
	local env_line="$1"
	local path_line="$2"
	local env_line_fish="$3"
	local path_line_fish="$4"
	local added_to_out=""
	local already_in_out=""

	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		local result
		result=$(_shellcheck_wrapper_setup_one_rc "$rc_file" "$env_line" "$path_line" "$env_line_fish" "$path_line_fish")
		case "$result" in
		added:*) added_to_out="${added_to_out:+$added_to_out, }${result#added:}" ;;
		already:*) already_in_out="${already_in_out:+$already_in_out, }${result#already:}" ;;
		esac
	done < <(get_all_shell_rcs)

	echo "$added_to_out|$already_in_out"
	return 0
}

# Merge results from zshenv and rc-file layers and print status messages.
_shellcheck_wrapper_report_results() {
	local env_line="$1"
	local zshenv_result="$2"
	local rc_result="$3"

	local zshenv_added zshenv_already
	zshenv_added="${zshenv_result%% *}"
	zshenv_already="${zshenv_result##* }"

	local rc_added rc_already
	rc_added="${rc_result%%|*}"
	rc_already="${rc_result##*|}"

	# Merge results from layers 2 and 3
	local added_to=""
	local already_in=""
	[[ -n "$zshenv_added" && "$zshenv_added" != " " ]] && added_to="${zshenv_added}"
	[[ -n "$rc_added" ]] && added_to="${added_to:+$added_to, }${rc_added}"
	[[ -n "$zshenv_already" && "$zshenv_already" != " " ]] && already_in="${zshenv_already}"
	[[ -n "$rc_already" ]] && already_in="${already_in:+$already_in, }${rc_already}"

	if [[ -n "$added_to" ]]; then
		print_success "Configured SHELLCHECK_PATH wrapper in: $added_to"
	fi

	if [[ -n "$already_in" ]]; then
		print_info "SHELLCHECK_PATH already configured in: $already_in"
	fi

	if [[ -z "$added_to" && -z "$already_in" && "$PLATFORM_MACOS" != "true" ]]; then
		print_warning "Could not configure SHELLCHECK_PATH automatically"
		print_info "Add this to your shell config: $env_line"
	fi

	return 0
}

setup_shellcheck_wrapper() {
	local wrapper_path="$HOME/.aidevops/agents/scripts/shellcheck-wrapper.sh"

	_shellcheck_wrapper_verify "$wrapper_path" || return 0

	local env_line
	# shellcheck disable=SC2016 # env_line is written to rc files; must expand at shell startup
	env_line='export SHELLCHECK_PATH="$HOME/.aidevops/agents/scripts/shellcheck-wrapper.sh"'
	# shellcheck disable=SC2016 # path_line is written to rc files; must expand at shell startup
	# Sanitize-and-prepend: strip any existing occurrence of the shim dir from PATH
	# (it may be at the END from a previous setup run), then prepend it. This ensures
	# the shim is always first, even on machines upgrading from the old append form.
	# The ${PATH:+:$PATH} guard handles the empty-PATH edge case without a trailing colon.
	local path_line='_aidevops_shim="$HOME/.aidevops/bin"; PATH="$(printf '\''%s'\'' "$PATH" | tr '\'':'\'' '\''\n'\'' | grep -Fxv -- "$_aidevops_shim" | paste -sd: -)"; export PATH="$_aidevops_shim${PATH:+:$PATH}"; unset _aidevops_shim'
	# Fish shell uses different syntax (set -gx instead of export)
	# shellcheck disable=SC2016 # fish lines are written to config.fish; must expand at shell startup
	local env_line_fish='set -gx SHELLCHECK_PATH "$HOME/.aidevops/agents/scripts/shellcheck-wrapper.sh"'
	# shellcheck disable=SC2016 # fish path line: strip existing, then prepend
	local path_line_fish='set -l _aidevops_shim "$HOME/.aidevops/bin"; set -l _aidevops_rest (string match -v -- "$_aidevops_shim" $PATH); set -gx PATH $_aidevops_shim $_aidevops_rest'

	local shim_dir="$HOME/.aidevops/bin"

	# Layer 0: PATH shim (GH#2993)
	_shellcheck_wrapper_setup_shim "$wrapper_path"

	# Layer 1: launchctl setenv (macOS) — GUI-launched processes
	if [[ "$PLATFORM_MACOS" == "true" ]]; then
		_shellcheck_wrapper_setup_launchctl "$wrapper_path" "$shim_dir"
	fi

	# Layer 2: .zshenv — ALL zsh processes (interactive AND non-interactive)
	local zshenv_result
	zshenv_result=$(_shellcheck_wrapper_setup_zshenv "$env_line" "$path_line" "$shim_dir")

	# Layer 3: Shell rc files — interactive terminal sessions
	local rc_result
	rc_result=$(_shellcheck_wrapper_setup_rc_files "$env_line" "$path_line" "$env_line_fish" "$path_line_fish")

	# Report merged results from layers 2 and 3
	_shellcheck_wrapper_report_results "$env_line" "$zshenv_result" "$rc_result"

	# Also export for current session
	export SHELLCHECK_PATH="$wrapper_path"
	export PATH="$HOME/.aidevops/bin:$PATH"

	return 0
}

# Check whether server access aliases are already configured in any rc file.
# Returns 0 (true) if already configured, 1 (false) if not.
_aliases_check_configured() {
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "# AI Assistant Server Access" "$rc_file"; then
			return 0
		fi
	done < <(get_all_shell_rcs)

	# Also check fish config (not included in get_all_shell_rcs on macOS)
	local fish_config="$HOME/.config/fish/config.fish"
	if [[ -f "$fish_config" ]] && grep -q "# AI Assistant Server Access" "$fish_config"; then
		return 0
	fi

	return 1
}

# Write alias blocks to fish or bash/zsh rc files.
# Prints the list of files aliases were added to (comma-separated).
_aliases_write_to_rc_files() {
	local is_fish="$1"
	local alias_block_bash="$2"
	local alias_block_fish="$3"
	local added_to=""

	# Handle fish separately
	if [[ "$is_fish" == "true" ]]; then
		local fish_rc="$HOME/.config/fish/config.fish"
		mkdir -p "$HOME/.config/fish"
		echo "$alias_block_fish" >>"$fish_rc"
		added_to="$fish_rc"
	else
		# Add to all bash/zsh rc files
		local rc_file
		while IFS= read -r rc_file; do
			[[ -z "$rc_file" ]] && continue

			# Create if it doesn't exist
			if [[ ! -f "$rc_file" ]]; then
				touch "$rc_file"
			fi

			# Skip if already has aliases (file created above if it didn't exist)
			if grep -q "# AI Assistant Server Access" "$rc_file"; then
				continue
			fi

			echo "$alias_block_bash" >>"$rc_file"
			added_to="${added_to:+$added_to, }$rc_file"
		done < <(get_all_shell_rcs)
	fi

	echo "$added_to"
	return 0
}

# Build the bash/zsh and fish alias blocks for server access.
# Prints two lines: "bash:<block>" and "fish:<block>" — callers split on newline.
# Since blocks are multi-line, we use process substitution via temp files.
# Outputs bash block to stdout, fish block to fd3 (caller must set up fd3).
_aliases_build_blocks() {
	cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers='./.agents/scripts/servers-helper.sh'
alias servers-list='./.agents/scripts/servers-helper.sh list'
alias hostinger='./.agents/scripts/hostinger-helper.sh'
alias hetzner='./.agents/scripts/hetzner-helper.sh'
alias aws-helper='./.agents/scripts/aws-helper.sh'
ALIASES
	return 0
}

# Build the fish-syntax alias block for server access.
_aliases_build_fish_block() {
	cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers './.agents/scripts/servers-helper.sh'
alias servers-list './.agents/scripts/servers-helper.sh list'
alias hostinger './.agents/scripts/hostinger-helper.sh'
alias hetzner './.agents/scripts/hetzner-helper.sh'
alias aws-helper './.agents/scripts/aws-helper.sh'
ALIASES
	return 0
}

# Add server access aliases to shell rc files (bash/zsh/fish)
setup_aliases() {
	print_info "Setting up shell aliases..."

	local default_shell
	default_shell=$(detect_default_shell)

	# Fish shell uses different alias syntax
	local is_fish=false
	[[ "$default_shell" == "fish" ]] && is_fish=true

	local alias_block_bash
	alias_block_bash=$(_aliases_build_blocks)

	local alias_block_fish
	alias_block_fish=$(_aliases_build_fish_block)

	if _aliases_check_configured; then
		print_info "Server Access aliases already configured - Skipping"
		return 0
	fi

	print_info "Detected default shell: $default_shell"
	setup_prompt add_aliases "Add shell aliases? [Y/n]: " "Y"

	if [[ "$add_aliases" =~ ^[Yy]?$ ]]; then
		local added_to
		added_to=$(_aliases_write_to_rc_files "$is_fish" "$alias_block_bash" "$alias_block_fish")

		if [[ -n "$added_to" ]]; then
			print_success "Aliases added to: $added_to"
			print_info "Restart your terminal to use aliases"
		fi
	else
		print_info "Skipped alias setup by user request"
	fi
	return 0
}

# Check if terminal title integration is already configured in any rc file.
# Returns 0 if configured, 1 if not.
_terminal_title_is_configured() {
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "aidevops terminal-title" "$rc_file"; then
			return 0
		fi
	done < <(get_all_shell_rcs)
	return 1
}

# Print current shell and Tabby status for terminal title setup.
_terminal_title_show_status() {
	echo ""
	print_info "Terminal title integration syncs your terminal tab with git repo/branch"
	print_info "Example: Tab shows 'aidevops/feature/xyz' when in that branch"
	echo ""
	echo "Current status:"

	local shell_name
	shell_name=$(detect_default_shell)
	local shell_info="$shell_name"
	if [[ "$shell_name" == "zsh" ]] && [[ -d "$HOME/.oh-my-zsh" ]]; then
		shell_info="$shell_name (Oh-My-Zsh)"
	fi
	echo "  Shell: $shell_info"

	local tabby_config="$HOME/Library/Application Support/tabby/config.yaml"
	if [[ -f "$tabby_config" ]]; then
		local disabled_count
		# grep -c exits 1 on no match; || : inside subshell prevents ERR trap noise
		disabled_count=$(grep -c "disableDynamicTitle: true" "$tabby_config" || :)
		if [[ "${disabled_count:-0}" -gt 0 ]]; then
			echo "  Tabby: detected, dynamic titles disabled in $disabled_count profile(s) (will fix)"
		else
			echo "  Tabby: detected, dynamic titles enabled"
		fi
	fi

	return 0
}

# Prompt the user and run the terminal title installer.
_terminal_title_prompt_and_install() {
	local setup_script="$1"

	echo ""
	setup_prompt install_title "Install terminal title integration? [Y/n]: " "Y"

	if [[ "$install_title" =~ ^[Yy]?$ ]]; then
		if bash "$setup_script" install; then
			print_success "Terminal title integration installed"
		else
			print_warning "Terminal title setup encountered issues (non-critical)"
		fi
	else
		print_info "Skipped terminal title setup by user request"
		print_info "You can install later with: ~/.aidevops/agents/scripts/terminal-title-setup.sh install"
	fi

	return 0
}

# Install terminal title integration that syncs tab titles with git repo/branch
setup_terminal_title() {
	# Check prerequisites before announcing setup (GH#5240)
	local setup_script=".agents/scripts/terminal-title-setup.sh"

	if [[ ! -f "$setup_script" ]]; then
		print_skip "Terminal title" "setup script not found" "Deploy agents first (setup.sh), then re-run"
		setup_track_skipped "Terminal title" "setup script not found"
		return 0
	fi

	if _terminal_title_is_configured; then
		print_success "Terminal title integration already configured"
		setup_track_configured "Terminal title"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up terminal title integration..."
	_terminal_title_show_status
	_terminal_title_prompt_and_install "$setup_script"

	return 0
}
