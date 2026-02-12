#!/usr/bin/env bash
# Agent deployment functions: deploy_aidevops_agents, deploy_ai_templates, inject_agents_reference, safety-hooks, beads
# Part of aidevops setup.sh modularization (t316.3)

deploy_ai_templates() {
	print_info "Deploying AI assistant templates..."

	if [[ -f "templates/deploy-templates.sh" ]]; then
		print_info "Running template deployment script..."
		if bash templates/deploy-templates.sh; then
			print_success "AI assistant templates deployed successfully"
		else
			print_warning "Template deployment encountered issues (non-critical)"
		fi
	else
		print_warning "Template deployment script not found - skipping"
	fi
	return 0
}

extract_opencode_prompts() {
	local extract_script=".agents/scripts/extract-opencode-prompts.sh"
	if [[ -f "$extract_script" ]]; then
		if bash "$extract_script"; then
			print_success "OpenCode prompts extracted"
		else
			print_warning "OpenCode prompt extraction encountered issues (non-critical)"
		fi
	fi
	return 0
}

check_opencode_prompt_drift() {
	local drift_script=".agents/scripts/opencode-prompt-drift-check.sh"
	if [[ -f "$drift_script" ]]; then
		local output exit_code=0
		output=$(bash "$drift_script" --quiet 2>/dev/null) || exit_code=$?
		if [[ "$exit_code" -eq 1 && "$output" == PROMPT_DRIFT* ]]; then
			local local_hash upstream_hash
			local_hash=$(echo "$output" | cut -d'|' -f2)
			upstream_hash=$(echo "$output" | cut -d'|' -f3)
			print_warning "OpenCode upstream prompt has changed (${local_hash} → ${upstream_hash})"
			print_info "  Review: https://github.com/anomalyco/opencode/compare/${local_hash}...${upstream_hash}"
			print_info "  Update .agents/prompts/build.txt if needed"
		elif [[ "$exit_code" -eq 0 ]]; then
			print_success "OpenCode prompt in sync with upstream"
		else
			print_warning "Could not check prompt drift (network issue or missing dependency)"
		fi
	fi
	return 0
}

deploy_aidevops_agents() {
	print_info "Deploying aidevops agents to ~/.aidevops/agents/..."

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local source_dir="$script_dir/.agents"
	local target_dir="$HOME/.aidevops/agents"
	local plugins_file="$HOME/.config/aidevops/plugins.json"

	# Validate source directory exists (catches curl install from wrong directory)
	if [[ ! -d "$source_dir" ]]; then
		print_error "Agent source directory not found: $source_dir"
		print_info "This usually means setup.sh was run from the wrong directory."
		print_info "The bootstrap should have cloned the repo and re-executed."
		print_info ""
		print_info "To fix manually:"
		print_info "  cd ~/Git/aidevops && ./setup.sh"
		return 1
	fi

	# Collect plugin namespace directories to preserve during deployment
	local -a plugin_namespaces=()
	if [[ -f "$plugins_file" ]] && command -v jq &>/dev/null; then
		local ns
		local safe_ns
		while IFS= read -r ns; do
			if [[ -n "$ns" ]] && safe_ns=$(sanitize_plugin_namespace "$ns" 2>/dev/null); then
				plugin_namespaces+=("$safe_ns")
			fi
		done < <(jq -r '.plugins[].namespace // empty' "$plugins_file" 2>/dev/null)
	fi

	# Create backup if target exists (with rotation)
	if [[ -d "$target_dir" ]]; then
		create_backup_with_rotation "$target_dir" "agents"
	fi

	# Create target directory and copy agents
	mkdir -p "$target_dir"

	# If clean mode, remove stale files first (preserving user and plugin directories)
	if [[ "$CLEAN_MODE" == "true" ]]; then
		# Build list of directories to preserve: custom, draft, plus plugin namespaces
		local -a preserved_dirs=("custom" "draft")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				preserved_dirs+=("$pns")
			done
		fi
		print_info "Clean mode: removing stale files from $target_dir (preserving ${preserved_dirs[*]})"
		local tmp_preserve
		tmp_preserve="$(mktemp -d)"
		trap 'rm -rf "${tmp_preserve:-}"' RETURN
		if [[ -z "$tmp_preserve" || ! -d "$tmp_preserve" ]]; then
			print_error "Failed to create temp dir for preserving agents"
			return 1
		fi
		local preserve_failed=false
		for pdir in "${preserved_dirs[@]}"; do
			if [[ -d "$target_dir/$pdir" ]]; then
				if ! cp -R "$target_dir/$pdir" "$tmp_preserve/$pdir"; then
					preserve_failed=true
				fi
			fi
		done
		if [[ "$preserve_failed" == "true" ]]; then
			print_error "Failed to preserve user/plugin agents; aborting clean"
			rm -rf "$tmp_preserve"
			return 1
		fi
		rm -rf "${target_dir:?}"/*
		# Restore preserved directories
		for pdir in "${preserved_dirs[@]}"; do
			if [[ -d "$tmp_preserve/$pdir" ]]; then
				cp -R "$tmp_preserve/$pdir" "$target_dir/$pdir"
			fi
		done
		rm -rf "$tmp_preserve"
	fi

	# Copy all agent files and folders, excluding:
	# - loop-state/ (local runtime state, not agents)
	# - custom/ (user's private agents, never overwritten)
	# - draft/ (user's experimental agents, never overwritten)
	# - plugin namespace directories (managed separately)
	# Use rsync for selective exclusion
	local deploy_ok=false
	if command -v rsync &>/dev/null; then
		local -a rsync_excludes=("--exclude=loop-state/" "--exclude=custom/" "--exclude=draft/")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				rsync_excludes+=("--exclude=${pns}/")
			done
		fi
		if rsync -a "${rsync_excludes[@]}" "$source_dir/" "$target_dir/"; then
			deploy_ok=true
		fi
	else
		# Fallback: use tar with exclusions to match rsync behavior
		local -a tar_excludes=("--exclude=loop-state" "--exclude=custom" "--exclude=draft")
		if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
			for pns in "${plugin_namespaces[@]}"; do
				tar_excludes+=("--exclude=$pns")
			done
		fi
		if (cd "$source_dir" && tar cf - "${tar_excludes[@]}" .) | (cd "$target_dir" && tar xf -); then
			deploy_ok=true
		fi
	fi

	if [[ "$deploy_ok" == "true" ]]; then
		print_success "Deployed agents to $target_dir"

		# Set permissions on scripts (top-level and modularised subdirectories)
		chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true
		find "$target_dir/scripts" -mindepth 2 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

		# Count what was deployed
		local agent_count
		agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
		local script_count
		script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')

		print_info "Deployed $agent_count agent files and $script_count scripts"

		# Copy VERSION file from repo root to deployed agents
		if [[ -f "$script_dir/VERSION" ]]; then
			if cp "$script_dir/VERSION" "$target_dir/VERSION"; then
				print_info "Copied VERSION file to deployed agents"
			else
				print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
			fi
		else
			print_warning "VERSION file not found in repo root"
		fi

		# Inject extracted OpenCode plan-reminder into Plan+ if available
		local plan_reminder="$HOME/.aidevops/cache/opencode-prompts/plan-reminder.txt"
		local plan_plus="$target_dir/plan-plus.md"
		if [[ -f "$plan_reminder" && -f "$plan_plus" ]]; then
			# Check if plan-plus.md has the placeholder marker
			if grep -q "OPENCODE-PLAN-REMINDER-INJECT" "$plan_plus"; then
				# Replace placeholder with extracted content using sed
				# (awk -v doesn't handle multi-line content with special chars well)
				local tmp_file
				tmp_file=$(mktemp)
				trap 'rm -f "${tmp_file:-}"' RETURN
				local in_placeholder=false
				while IFS= read -r line || [[ -n "$line" ]]; do
					if [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-START"* ]]; then
						echo "$line" >>"$tmp_file"
						cat "$plan_reminder" >>"$tmp_file"
						in_placeholder=true
					elif [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-END"* ]]; then
						echo "$line" >>"$tmp_file"
						in_placeholder=false
					elif [[ "$in_placeholder" == false ]]; then
						echo "$line" >>"$tmp_file"
					fi
				done <"$plan_plus"
				mv "$tmp_file" "$plan_plus"
				print_info "Injected OpenCode plan-reminder into Plan+"
			fi
		fi
		# Migrate mailbox from TOON files to SQLite (if old files exist)
		local aidevops_workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}"
		local mail_dir="${AIDEVOPS_MAIL_DIR:-${aidevops_workspace_dir}/mail}"
		local mail_script="$target_dir/scripts/mail-helper.sh"
		if [[ -x "$mail_script" ]] && find "$mail_dir" -name "*.toon" 2>/dev/null | grep -q .; then
			if "$mail_script" migrate; then
				print_success "Mailbox migration complete"
			else
				print_warning "Mailbox migration had issues (non-critical, old files preserved)"
			fi
		fi

		# Migration: wavespeed.md moved from services/ai-generation/ to tools/video/ (v2.111+)
		local old_wavespeed="$target_dir/services/ai-generation/wavespeed.md"
		if [[ -f "$old_wavespeed" ]]; then
			rm -f "$old_wavespeed"
			rmdir "$target_dir/services/ai-generation" 2>/dev/null || true
			print_info "Migrated wavespeed.md from services/ai-generation/ to tools/video/"
		fi

		# Deploy enabled plugins from plugins.json
		deploy_plugins "$target_dir" "$plugins_file"
	else
		print_error "Failed to deploy agents"
		return 1
	fi

	return 0
}

inject_agents_reference() {
	print_info "Adding aidevops reference to AI assistant configurations..."

	local reference_line='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'

	# AI assistant agent directories - these get cleaned and receive AGENTS.md reference
	# Format: "config_dir:agents_subdir" where agents_subdir is the folder containing agent files
	# Only OpenCode and Claude Code (companion CLI) are actively supported
	local ai_agent_dirs=(
		"$HOME/.config/opencode:agent"
		"$HOME/.claude:commands"
		"$HOME/.opencode:."
	)

	local updated_count=0

	for entry in "${ai_agent_dirs[@]}"; do
		local config_dir="${entry%%:*}"
		local agents_subdir="${entry##*:}"
		local agents_dir="$config_dir/$agents_subdir"
		local agents_file="$agents_dir/AGENTS.md"

		# Only process if the config directory exists (tool is installed)
		if [[ -d "$config_dir" ]]; then
			# Create agents subdirectory if needed
			mkdir -p "$agents_dir"

			# Check if AGENTS.md exists and has our reference
			if [[ -f "$agents_file" ]]; then
				# Check first line for our reference
				local first_line
				first_line=$(head -1 "$agents_file" 2>/dev/null || echo "")
				if [[ "$first_line" != *"~/.aidevops/agents/AGENTS.md"* ]]; then
					# Prepend reference to existing file
					local temp_file
					temp_file=$(mktemp)
					trap 'rm -f "${temp_file:-}"' RETURN
					echo "$reference_line" >"$temp_file"
					echo "" >>"$temp_file"
					cat "$agents_file" >>"$temp_file"
					mv "$temp_file" "$agents_file"
					print_success "Added reference to $agents_file"
					((updated_count++)) || true
				else
					print_info "Reference already exists in $agents_file"
				fi
			else
				# Create new file with just the reference
				echo "$reference_line" >"$agents_file"
				print_success "Created $agents_file with aidevops reference"
				((updated_count++)) || true
			fi
		fi
	done

	if [[ $updated_count -eq 0 ]]; then
		print_info "No AI assistant configs found to update (tools may not be installed yet)"
	else
		print_success "Updated $updated_count AI assistant configuration(s)"
	fi

	# Deploy OpenCode config-level AGENTS.md from managed template
	# This controls the session greeting (auto-loaded by OpenCode from config root)
	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_config_agents="$opencode_config_dir/AGENTS.md"
	local template_source="$INSTALL_DIR/templates/opencode-config-agents.md"

	if [[ -d "$opencode_config_dir" && -f "$template_source" ]]; then
		# Backup if file exists and differs from template
		if [[ -f "$opencode_config_agents" ]]; then
			if ! diff -q "$template_source" "$opencode_config_agents" &>/dev/null; then
				create_backup_with_rotation "$opencode_config_agents" "opencode-agents"
			fi
		fi
		if cp "$template_source" "$opencode_config_agents"; then
			print_success "Deployed greeting template to $opencode_config_agents"
		else
			print_error "Failed to deploy greeting template to $opencode_config_agents"
		fi
	fi

	return 0
}

install_beads_binary() {
	local os arch tarball_name
	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	arch=$(uname -m)

	# Map architecture names to Beads release naming convention
	case "$arch" in
	x86_64 | amd64) arch="amd64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*)
		print_warning "Unsupported architecture for Beads binary download: $arch"
		return 1
		;;
	esac

	# Get latest version tag from GitHub API
	local latest_version
	latest_version=$(curl -fsSL "https://api.github.com/repos/steveyegge/beads/releases/latest" 2>/dev/null |
		grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')

	if [[ -z "$latest_version" ]]; then
		print_warning "Could not determine latest Beads version from GitHub"
		return 1
	fi

	tarball_name="beads_${latest_version}_${os}_${arch}.tar.gz"
	local download_url="https://github.com/steveyegge/beads/releases/download/v${latest_version}/${tarball_name}"

	print_info "Downloading Beads CLI v${latest_version} (${os}/${arch})..."

	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" RETURN

	if ! curl -fsSL "$download_url" -o "$tmp_dir/$tarball_name" 2>/dev/null; then
		print_warning "Failed to download Beads binary from $download_url"
		return 1
	fi

	# Extract and install
	if ! tar -xzf "$tmp_dir/$tarball_name" -C "$tmp_dir" 2>/dev/null; then
		print_warning "Failed to extract Beads binary"
		return 1
	fi

	# Find the bd binary in the extracted files
	local bd_binary
	bd_binary=$(find "$tmp_dir" -name "bd" -type f 2>/dev/null | head -1)
	if [[ -z "$bd_binary" ]]; then
		print_warning "bd binary not found in downloaded archive"
		return 1
	fi

	# Install to a writable location
	local install_dir="/usr/local/bin"
	if [[ ! -w "$install_dir" ]]; then
		if command -v sudo &>/dev/null; then
			sudo install -m 755 "$bd_binary" "$install_dir/bd"
		else
			# Fallback to user-local bin
			install_dir="$HOME/.local/bin"
			mkdir -p "$install_dir"
			install -m 755 "$bd_binary" "$install_dir/bd"
			# Ensure ~/.local/bin is in PATH
			if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
				export PATH="$HOME/.local/bin:$PATH"
				print_info "Added ~/.local/bin to PATH for this session"
			fi
		fi
	else
		install -m 755 "$bd_binary" "$install_dir/bd"
	fi

	if command -v bd &>/dev/null; then
		print_success "Beads CLI installed via binary download (v${latest_version})"
		return 0
	else
		print_warning "Beads binary installed to $install_dir/bd but not found in PATH"
		return 1
	fi
}

install_beads_go() {
	if ! command -v go &>/dev/null; then
		return 1
	fi
	if run_with_spinner "Installing Beads via Go" go install github.com/steveyegge/beads/cmd/bd@latest; then
		print_info "Ensure \$GOPATH/bin is in your PATH"
		return 0
	fi
	print_warning "Go installation failed"
	return 1
}

setup_beads() {
	print_info "Setting up Beads (task graph visualization)..."

	# Check if Beads CLI (bd) is already installed
	if command -v bd &>/dev/null; then
		local bd_version
		bd_version=$(bd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Beads CLI (bd) already installed: $bd_version"
	else
		# Try to install via Homebrew first (macOS/Linux with Homebrew)
		if command -v brew &>/dev/null; then
			if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
				: # Success message handled by spinner
			else
				print_warning "Homebrew tap installation failed, trying alternative..."
				install_beads_binary || install_beads_go
			fi
		elif command -v go &>/dev/null; then
			if run_with_spinner "Installing Beads via Go" go install github.com/steveyegge/beads/cmd/bd@latest; then
				print_info "Ensure \$GOPATH/bin is in your PATH"
			else
				print_warning "Go installation failed, trying binary download..."
				install_beads_binary
			fi
		else
			# No brew, no Go -- try binary download first, then offer Homebrew install
			if ! install_beads_binary; then
				# Binary download failed -- offer to install Homebrew (Linux only)
				if ensure_homebrew; then
					# Homebrew now available, retry via tap
					if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
						: # Success
					else
						print_warning "Homebrew tap installation failed"
					fi
				else
					print_warning "Beads CLI (bd) not installed"
					echo ""
					echo "  Install options:"
					echo "    Binary download:        https://github.com/steveyegge/beads/releases"
					echo "    macOS/Linux (Homebrew):  brew install steveyegge/beads/bd"
					echo "    Go:                      go install github.com/steveyegge/beads/cmd/bd@latest"
					echo ""
				fi
			fi
		fi
	fi

	print_info "Beads provides task graph visualization for TODO.md and PLANS.md"
	print_info "After installation, run: aidevops init beads"

	# Offer to install optional Beads UI tools
	setup_beads_ui

	return 0
}

setup_beads_ui() {
	echo ""
	print_info "Beads UI tools provide enhanced visualization:"
	echo "  • bv (Go)            - PageRank, critical path, graph analytics TUI"
	echo "  • beads-ui (Node.js) - Web dashboard with live updates"
	echo "  • bdui (Node.js)     - React/Ink terminal UI"
	echo "  • perles (Rust)      - BQL query language TUI"
	echo ""

	read -r -p "Install optional Beads UI tools? [Y/n]: " install_beads_ui

	if [[ ! "$install_beads_ui" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Beads UI tools (can install later from beads.md docs)"
		return 0
	fi

	local installed_count=0

	# bv (beads_viewer) - Go TUI installed via Homebrew
	# https://github.com/Dicklesworthstone/beads_viewer
	read -r -p "  Install bv (TUI with PageRank, critical path, graph analytics)? [Y/n]: " install_viewer
	if [[ "$install_viewer" =~ ^[Yy]?$ ]]; then
		if command -v brew &>/dev/null; then
			# brew install user/tap/formula auto-taps
			if run_with_spinner "Installing bv via Homebrew" brew install dicklesworthstone/tap/bv; then
				print_info "Run: bv (in a beads-enabled project)"
				((installed_count++)) || true
			else
				print_warning "Homebrew install failed - try manually:"
				print_info "  brew install dicklesworthstone/tap/bv"
			fi
		else
			# No Homebrew - try install script or Go
			print_warning "Homebrew not found"
			if command -v go &>/dev/null; then
				# Go available - use go install
				if run_with_spinner "Installing bv via Go" go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest; then
					print_info "Run: bv (in a beads-enabled project)"
					((installed_count++)) || true
				else
					print_warning "Go install failed"
				fi
			else
				# Offer verified install script (download-then-execute, not piped)
				read -r -p "  Install bv via install script? [Y/n]: " use_script
				if [[ "$use_script" =~ ^[Yy]?$ ]]; then
					if verified_install "bv (beads viewer)" "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh"; then
						print_info "Run: bv (in a beads-enabled project)"
						((installed_count++)) || true
					else
						print_warning "Install script failed - try manually:"
						print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
					fi
				else
					print_info "Install later:"
					print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
					print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
				fi
			fi
		fi
	fi

	# beads-ui (Node.js)
	if command -v npm &>/dev/null; then
		read -r -p "  Install beads-ui (Web dashboard)? [Y/n]: " install_web
		if [[ "$install_web" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing beads-ui" npm_global_install beads-ui; then
				print_info "Run: beads-ui"
				((installed_count++)) || true
			fi
		fi

		read -r -p "  Install bdui (React/Ink TUI)? [Y/n]: " install_bdui
		if [[ "$install_bdui" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing bdui" npm_global_install bdui; then
				print_info "Run: bdui"
				((installed_count++)) || true
			fi
		fi
	fi

	# perles (Rust)
	if command -v cargo &>/dev/null; then
		read -r -p "  Install perles (BQL query language TUI)? [Y/n]: " install_perles
		if [[ "$install_perles" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing perles (Rust compile)" cargo install perles; then
				print_info "Run: perles"
				((installed_count++)) || true
			fi
		fi
	fi

	if [[ $installed_count -gt 0 ]]; then
		print_success "Installed $installed_count Beads UI tool(s)"
	else
		print_info "No Beads UI tools installed"
	fi

	echo ""
	print_info "Beads UI documentation: ~/.aidevops/agents/tools/task-management/beads.md"

	return 0
}

setup_safety_hooks() {
	print_info "Setting up Claude Code safety hooks..."

	# Check Python is available
	if ! command -v python3 &>/dev/null; then
		print_warning "Python 3 not found - safety hooks require Python 3"
		return 0
	fi

	local helper_script="$HOME/.aidevops/agents/scripts/install-hooks-helper.sh"
	if [[ ! -f "$helper_script" ]]; then
		# Fall back to repo copy
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		helper_script="$script_dir/.agents/scripts/install-hooks-helper.sh"
	fi

	if [[ ! -f "$helper_script" ]]; then
		print_warning "install-hooks-helper.sh not found - skipping safety hooks"
		return 0
	fi

	if bash "$helper_script" install; then
		print_success "Claude Code safety hooks installed"
	else
		print_warning "Safety hook installation encountered issues (non-critical)"
	fi
	return 0
}

