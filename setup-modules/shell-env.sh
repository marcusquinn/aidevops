#!/usr/bin/env bash
# Shell environment setup functions: oh-my-zsh, shell-compat, aliases, terminal-title
# Part of aidevops setup.sh modularization (t316.3)

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

detect_default_shell() {
	basename "${SHELL:-/bin/bash}"
	return 0
}

# Usage: get_shell_rc "zsh" or get_shell_rc "bash"
get_shell_rc() {
	local shell_name="$1"
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

setup_oh_my_zsh() {
	# Only relevant if zsh is available
	if ! command -v zsh >/dev/null 2>&1; then
		print_info "zsh not found - skipping Oh My Zsh setup"
		return 0
	fi

	# Check if Oh My Zsh is already installed
	if [[ -d "$HOME/.oh-my-zsh" ]]; then
		print_success "Oh My Zsh already installed"
		return 0
	fi

	local default_shell
	default_shell=$(detect_default_shell)

	# Only offer if zsh is the default shell (or on macOS where it's the system default)
	if [[ "$default_shell" != "zsh" && "$(uname)" != "Darwin" ]]; then
		print_info "Default shell is $default_shell (not zsh) - skipping Oh My Zsh"
		return 0
	fi

	print_info "Oh My Zsh enhances zsh with themes, plugins, and completions"
	echo "  Many tools installed later (git, fd, brew) benefit from Oh My Zsh plugins."
	echo "  This is optional - plain zsh works fine without it."
	echo ""

	read -r -p "Install Oh My Zsh? [y/N]: " install_omz

	if [[ "$install_omz" =~ ^[Yy]$ ]]; then
		print_info "Installing Oh My Zsh..."
		# Use verified download + --unattended to avoid changing the shell or starting zsh
		VERIFIED_INSTALL_SHELL="sh"
		if verified_install "Oh My Zsh" "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" --unattended; then
			print_success "Oh My Zsh installed"

			# Ensure .zshrc exists (Oh My Zsh creates it, but verify)
			if [[ ! -f "$HOME/.zshrc" ]]; then
				print_warning ".zshrc not created - Oh My Zsh may not have installed correctly"
			fi

			# If the user's default shell isn't zsh, offer to change it
			if [[ "$default_shell" != "zsh" ]]; then
				echo ""
				read -r -p "Change default shell to zsh? [y/N]: " change_shell
				if [[ "$change_shell" =~ ^[Yy]$ ]]; then
					if chsh -s "$(command -v zsh)"; then
						print_success "Default shell changed to zsh"
						print_info "Restart your terminal for the change to take effect"
					else
						print_warning "Failed to change shell - run manually: chsh -s $(command -v zsh)"
					fi
				fi
			fi
		else
			print_warning "Oh My Zsh installation failed"
			print_info "Install manually: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
		fi
	else
		print_info "Skipped Oh My Zsh installation"
		print_info "Install later: curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/omz-install.sh && sh /tmp/omz-install.sh"
	fi

	return 0
}

setup_shell_compatibility() {
	print_info "Setting up cross-shell compatibility..."

	local shared_profile="$HOME/.shell_common"
	local zsh_rc="$HOME/.zshrc"

	# If shared profile already exists, we've already set this up
	if [[ -f "$shared_profile" ]]; then
		print_success "Cross-shell compatibility already configured ($shared_profile)"
		return 0
	fi

	# Need both bash and zsh to be relevant
	if ! command -v zsh >/dev/null 2>&1; then
		print_info "zsh not installed - cross-shell setup not needed"
		return 0
	fi
	if ! command -v bash >/dev/null 2>&1; then
		print_info "bash not installed - cross-shell setup not needed"
		return 0
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
		return 0
	fi

	if [[ ! -f "$zsh_rc" ]]; then
		print_info "No .zshrc found - skipping cross-shell setup"
		return 0
	fi

	# Count customizations across all bash config files
	local total_exports=0
	local total_aliases=0
	local total_paths=0

	for src_file in "${bash_files[@]}"; do
		local n
		# grep -c outputs "0" on no match (exit 1); "|| true" prevents exit
		# without appending a second "0" line (which breaks arithmetic)
		n=$(grep -cE '^\s*export\s+[A-Z]' "$src_file" 2>/dev/null) || true
		total_exports=$((total_exports + ${n:-0}))
		n=$(grep -cE '^\s*alias\s+' "$src_file" 2>/dev/null) || true
		total_aliases=$((total_aliases + ${n:-0}))
		n=$(grep -cE 'PATH.*=' "$src_file" 2>/dev/null) || true
		total_paths=$((total_paths + ${n:-0}))
	done

	if [[ $total_exports -eq 0 && $total_aliases -eq 0 && $total_paths -eq 0 ]]; then
		print_info "No bash customizations detected - skipping cross-shell setup"
		return 0
	fi

	print_info "Detected bash customizations across ${#bash_files[@]} file(s):"
	echo "  Exports: $total_exports, Aliases: $total_aliases, PATH entries: $total_paths"
	echo ""
	print_info "Best practice: create a shared profile (~/.shell_common) sourced by"
	print_info "both bash and zsh, so your customizations work in either shell."
	echo ""

	local setup_compat="Y"
	if [[ "$NON_INTERACTIVE" != "true" ]]; then
		read -r -p "Create shared shell profile for cross-shell compatibility? [Y/n]: " setup_compat
	fi

	if [[ ! "$setup_compat" =~ ^[Yy]?$ ]]; then
		print_info "Skipped cross-shell compatibility setup"
		print_info "Set up later by creating ~/.shell_common and sourcing it from both shells"
		return 0
	fi

	# Extract portable customizations from bash config into shared profile
	# We extract: exports, PATH modifications, aliases, eval statements, source commands
	# We skip: bash-specific syntax (shopt, PROMPT_COMMAND, PS1, completion, bind, etc.)
	# We deduplicate lines that appear in multiple files (e.g. .bash_profile sources .bashrc)
	print_info "Creating shared profile: $shared_profile"

	{
		echo "# Shared shell profile - sourced by both bash and zsh"
		echo "# Created by aidevops setup to preserve customizations across shell switches"
		echo "# Edit this file for settings you want in BOTH bash and zsh"
		echo "# Shell-specific settings go in ~/.bashrc or ~/.zshrc"
		echo ""
	} >"$shared_profile"

	# Track lines we've already written to avoid duplicates
	# (common on Linux where .bash_profile sources .bashrc)
	local -a seen_lines=()
	local extracted=0

	for src_file in "${bash_files[@]}"; do
		local src_basename
		src_basename=$(basename "$src_file")
		local added_header=false

		while IFS= read -r line || [[ -n "$line" ]]; do
			# Skip empty lines
			[[ -z "$line" ]] && continue
			# Skip pure comment lines
			[[ "$line" =~ ^[[:space:]]*# ]] && continue

			# Skip bash-specific settings that don't work in zsh
			case "$line" in
			*shopt*) continue ;;
			*PROMPT_COMMAND*) continue ;;
			*PS1=*) continue ;;
			*PS2=*) continue ;;
			*bash_completion*) continue ;;
			*"complete "*) continue ;;
			*"bind "*) continue ;;
			*HISTCONTROL*) continue ;;
			*HISTFILESIZE*) continue ;;
			*HISTSIZE*) continue ;;
			*"source /etc/bash"*) continue ;;
			*". /etc/bash"*) continue ;;
			*"source /etc/profile"*) continue ;;
			*". /etc/profile"*) continue ;;
			# Skip lines that source .bashrc from .bash_profile (circular)
			*".bashrc"*) continue ;;
			# Skip lines that source .shell_common (we'll add this ourselves)
			*"shell_common"*) continue ;;
			esac

			# Match portable lines: exports, aliases, PATH, eval, source/dot-source
			local is_portable=false
			case "$line" in
			export\ [A-Z]* | export\ PATH*) is_portable=true ;;
			alias\ *) is_portable=true ;;
			eval\ *) is_portable=true ;;
			*PATH=*) is_portable=true ;;
			esac
			# Also match 'source' and '. ' commands (tool integrations like nvm, rvm, pyenv)
			if [[ "$is_portable" == "false" ]]; then
				case "$line" in
				source\ * | .\ /* | .\ \$* | .\ \~*) is_portable=true ;;
				esac
			fi

			if [[ "$is_portable" == "true" ]]; then
				# Deduplicate: skip if we've already seen this exact line
				local is_dup=false
				local seen
				for seen in "${seen_lines[@]}"; do
					if [[ "$seen" == "$line" ]]; then
						is_dup=true
						break
					fi
				done
				if [[ "$is_dup" == "true" ]]; then
					continue
				fi

				if [[ "$added_header" == "false" ]]; then
					echo "" >>"$shared_profile"
					echo "# From $src_basename" >>"$shared_profile"
					added_header=true
				fi
				echo "$line" >>"$shared_profile"
				seen_lines+=("$line")
				((extracted++)) || true
			fi
		done <"$src_file"
	done

	if [[ $extracted -eq 0 ]]; then
		rm -f "$shared_profile"
		print_info "No portable customizations found to extract"
		return 0
	fi

	chmod 644 "$shared_profile"
	print_success "Extracted $extracted unique customization(s) to $shared_profile"

	# Add sourcing to .zshrc if not already present
	if ! grep -q 'shell_common' "$zsh_rc" 2>/dev/null; then
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
	for src_file in "${bash_files[@]}"; do
		if ! grep -q 'shell_common' "$src_file" 2>/dev/null; then
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

	echo ""
	print_success "Cross-shell compatibility configured"
	print_info "Your customizations are now in: $shared_profile"
	print_info "Both bash and zsh will source this file automatically."
	print_info "Edit ~/.shell_common for settings you want in both shells."
	print_info "Use ~/.bashrc or ~/.zshrc for shell-specific settings only."

	return 0
}

check_optional_deps() {
	print_info "Checking optional dependencies..."

	local missing_optional=()

	if ! command -v sshpass >/dev/null 2>&1; then
		missing_optional+=("sshpass")
	else
		print_success "sshpass found"
	fi

	if [[ ${#missing_optional[@]} -gt 0 ]]; then
		print_warning "Missing optional dependencies: ${missing_optional[*]}"
		echo "  sshpass - needed for password-based SSH (like Hostinger)"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			read -r -p "Install optional dependencies using $pkg_manager? [Y/n]: " install_optional

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

add_local_bin_to_path() {
	local path_line='export PATH="$HOME/.local/bin:$PATH"'
	local added_to=""
	local already_in=""

	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue

		# Create the rc file if it doesn't exist (ensure parent dir exists for fish etc.)
		if [[ ! -f "$rc_file" ]]; then
			mkdir -p "$(dirname "$rc_file")"
			touch "$rc_file"
		fi

		# Check if already added
		if grep -q '\.local/bin' "$rc_file" 2>/dev/null; then
			already_in="${already_in:+$already_in, }$rc_file"
			continue
		fi

		# Add to shell config
		echo "" >>"$rc_file"
		echo "# Added by aidevops setup" >>"$rc_file"
		echo "$path_line" >>"$rc_file"
		added_to="${added_to:+$added_to, }$rc_file"
	done < <(get_all_shell_rcs)

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

	# Also export for current session
	export PATH="$HOME/.local/bin:$PATH"

	return 0
}

setup_aliases() {
	print_info "Setting up shell aliases..."

	local default_shell
	default_shell=$(detect_default_shell)

	# Fish shell uses different alias syntax
	local is_fish=false
	if [[ "$default_shell" == "fish" ]]; then
		is_fish=true
	fi

	local alias_block_bash
	alias_block_bash=$(
		cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers='./.agents/scripts/servers-helper.sh'
alias servers-list='./.agents/scripts/servers-helper.sh list'
alias hostinger='./.agents/scripts/hostinger-helper.sh'
alias hetzner='./.agents/scripts/hetzner-helper.sh'
alias aws-helper='./.agents/scripts/aws-helper.sh'
ALIASES
	)

	local alias_block_fish
	alias_block_fish=$(
		cat <<'ALIASES'

# AI Assistant Server Access Framework
alias servers './.agents/scripts/servers-helper.sh'
alias servers-list './.agents/scripts/servers-helper.sh list'
alias hostinger './.agents/scripts/hostinger-helper.sh'
alias hetzner './.agents/scripts/hetzner-helper.sh'
alias aws-helper './.agents/scripts/aws-helper.sh'
ALIASES
	)

	# Check if aliases already exist in any rc file (including fish config)
	local any_configured=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if grep -q "# AI Assistant Server Access" "$rc_file" 2>/dev/null; then
			any_configured=true
			break
		fi
	done < <(get_all_shell_rcs)
	# Also check fish config (not included in get_all_shell_rcs on macOS)
	if [[ "$any_configured" == "false" ]]; then
		local fish_config="$HOME/.config/fish/config.fish"
		if grep -q "# AI Assistant Server Access" "$fish_config" 2>/dev/null; then
			any_configured=true
		fi
	fi

	if [[ "$any_configured" == "true" ]]; then
		print_info "Server Access aliases already configured - Skipping"
		return 0
	fi

	print_info "Detected default shell: $default_shell"
	read -r -p "Add shell aliases? [Y/n]: " add_aliases

	if [[ "$add_aliases" =~ ^[Yy]?$ ]]; then
		local added_to=""

		# Handle fish separately
		if [[ "$is_fish" == "true" ]]; then
			local fish_rc="$HOME/.config/fish/config.fish"
			mkdir -p "$HOME/.config/fish"
			echo "$alias_block_fish" >>"$fish_rc"
			added_to="$fish_rc"
		else
			# Add to all bash/zsh rc files
			while IFS= read -r rc_file; do
				[[ -z "$rc_file" ]] && continue

				# Create if it doesn't exist
				if [[ ! -f "$rc_file" ]]; then
					touch "$rc_file"
				fi

				# Skip if already has aliases
				if grep -q "# AI Assistant Server Access" "$rc_file" 2>/dev/null; then
					continue
				fi

				echo "$alias_block_bash" >>"$rc_file"
				added_to="${added_to:+$added_to, }$rc_file"
			done < <(get_all_shell_rcs)
		fi

		if [[ -n "$added_to" ]]; then
			print_success "Aliases added to: $added_to"
			print_info "Restart your terminal to use aliases"
		fi
	else
		print_info "Skipped alias setup by user request"
	fi
	return 0
}

setup_terminal_title() {
	print_info "Setting up terminal title integration..."

	local setup_script=".agents/scripts/terminal-title-setup.sh"

	if [[ ! -f "$setup_script" ]]; then
		print_warning "Terminal title setup script not found - skipping"
		return 0
	fi

	# Check if already installed (check all rc files)
	local title_configured=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "aidevops terminal-title" "$rc_file" 2>/dev/null; then
			title_configured=true
			break
		fi
	done < <(get_all_shell_rcs)

	if [[ "$title_configured" == "true" ]]; then
		print_info "Terminal title integration already configured - Skipping"
		return 0
	fi

	# Show current status before asking
	echo ""
	print_info "Terminal title integration syncs your terminal tab with git repo/branch"
	print_info "Example: Tab shows 'aidevops/feature/xyz' when in that branch"
	echo ""
	echo "Current status:"

	# Shell info
	local shell_name
	shell_name=$(detect_default_shell)
	local shell_info="$shell_name"
	if [[ "$shell_name" == "zsh" ]] && [[ -d "$HOME/.oh-my-zsh" ]]; then
		shell_info="$shell_name (Oh-My-Zsh)"
	fi
	echo "  Shell: $shell_info"

	# Tabby info
	local tabby_config="$HOME/Library/Application Support/tabby/config.yaml"
	if [[ -f "$tabby_config" ]]; then
		local disabled_count
		disabled_count=$(grep -c "disableDynamicTitle: true" "$tabby_config" 2>/dev/null || echo "0")
		if [[ "$disabled_count" -gt 0 ]]; then
			echo "  Tabby: detected, dynamic titles disabled in $disabled_count profile(s) (will fix)"
		else
			echo "  Tabby: detected, dynamic titles enabled"
		fi
	fi

	echo ""
	read -r -p "Install terminal title integration? [Y/n]: " install_title

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
