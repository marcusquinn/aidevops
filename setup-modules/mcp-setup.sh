#!/usr/bin/env bash
# MCP setup functions: install_mcp_packages, resolve_mcp_binary, localwp, augment, osgrep, seo, analytics, quickfile, browser-tools, opencode-plugins
# Part of aidevops setup.sh modularization (t316.3)

install_mcp_packages() {
	print_info "Installing MCP server packages globally (eliminates npx startup delay)..."

	# Node.js MCP packages to install globally
	local -a node_mcps=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
	)

	if ! command -v bun &>/dev/null && ! command -v npm &>/dev/null; then
		print_warning "Neither bun nor npm found - cannot install MCP packages"
		print_info "Install bun (recommended): npm install -g bun OR brew install oven-sh/bun/bun"
		return 0
	fi

	local installer="npm"
	command -v bun &>/dev/null && installer="bun"
	print_info "Using $installer to install/update Node.js MCP packages..."

	# Always install latest (bun install -g is fast and idempotent)
	local updated=0
	local failed=0
	local pkg
	for pkg in "${node_mcps[@]}"; do
		local short_name="${pkg##*/}" # Strip @scope/ prefix for display
		if run_with_spinner "Installing $short_name" npm_global_install "${pkg}@latest"; then
			((updated++)) || true
		else
			((failed++)) || true
			print_warning "Failed to install/update $pkg"
		fi
	done

	if [[ $updated -gt 0 ]]; then
		print_success "$updated Node.js MCP packages installed/updated to latest via $installer"
	fi
	if [[ $failed -gt 0 ]]; then
		print_warning "$failed packages failed (check network or package names)"
	fi

	# Python MCP packages (install or upgrade)
	if command -v pipx &>/dev/null; then
		print_info "Installing/updating analytics-mcp via pipx..."
		if command -v analytics-mcp &>/dev/null; then
			pipx upgrade analytics-mcp >/dev/null 2>&1 || true
		else
			pipx install analytics-mcp >/dev/null 2>&1 || print_warning "Failed to install analytics-mcp"
		fi
	fi

	if command -v uv &>/dev/null; then
		print_info "Installing/updating outscraper-mcp-server via uv..."
		if command -v outscraper-mcp-server &>/dev/null; then
			uv tool upgrade outscraper-mcp-server >/dev/null 2>&1 || true
		else
			uv tool install outscraper-mcp-server >/dev/null 2>&1 || print_warning "Failed to install outscraper-mcp-server"
		fi
	fi

	# Update opencode.json with resolved full paths for all MCP binaries
	update_mcp_paths_in_opencode

	print_info "MCP servers will start instantly (no registry lookups on each launch)"
	return 0
}

resolve_mcp_binary_path() {
	local bin_name="$1"
	local resolved=""

	# Check common locations in priority order
	local search_paths=(
		"$HOME/.bun/bin/$bin_name"
		"/opt/homebrew/bin/$bin_name"
		"/usr/local/bin/$bin_name"
		"$HOME/.local/bin/$bin_name"
		"$HOME/.npm-global/bin/$bin_name"
	)

	for path in "${search_paths[@]}"; do
		if [[ -x "$path" ]]; then
			resolved="$path"
			break
		fi
	done

	# Fallback: use command -v if in PATH (portable, POSIX-compliant)
	if [[ -z "$resolved" ]]; then
		resolved=$(command -v "$bin_name" 2>/dev/null || true)
	fi

	echo "$resolved"
	return 0
}

update_mcp_paths_in_opencode() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN
	cp "$opencode_config" "$tmp_config"

	local updated=0

	# Get all MCP entries with local commands
	local mcp_keys
	mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | .key' "$tmp_config" 2>/dev/null)

	while IFS= read -r mcp_key; do
		[[ -z "$mcp_key" ]] && continue

		# Get the first element of the command array (the binary)
		local current_cmd
		current_cmd=$(jq -r --arg k "$mcp_key" '.mcp[$k].command[0]' "$tmp_config" 2>/dev/null)

		# Skip if already a full path
		if [[ "$current_cmd" == /* ]]; then
			# Verify the path still exists
			if [[ ! -x "$current_cmd" ]]; then
				# Path is stale, try to resolve
				local bin_name
				bin_name=$(basename "$current_cmd")
				local new_path
				new_path=$(resolve_mcp_binary_path "$bin_name")
				if [[ -n "$new_path" && "$new_path" != "$current_cmd" ]]; then
					jq --arg k "$mcp_key" --arg p "$new_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
					((updated++)) || true
				fi
			fi
			continue
		fi

		# Skip docker (container runtime) and node (resolved separately below)
		case "$current_cmd" in
		docker | node) continue ;;
		esac

		# Resolve the full path
		local full_path
		full_path=$(resolve_mcp_binary_path "$current_cmd")

		if [[ -n "$full_path" && "$full_path" != "$current_cmd" ]]; then
			jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((updated++)) || true
		fi
	done <<<"$mcp_keys"

	# Also resolve 'node' commands (e.g., quickfile, amazon-order-history)
	# These use ["node", "/path/to/index.js"] - node itself should be resolved
	local node_path
	node_path=$(resolve_mcp_binary_path "node")
	if [[ -n "$node_path" ]]; then
		local node_mcp_keys
		node_mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | select(.value.command[0] == "node") | .key' "$tmp_config" 2>/dev/null)
		while IFS= read -r mcp_key; do
			[[ -z "$mcp_key" ]] && continue
			jq --arg k "$mcp_key" --arg p "$node_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((updated++)) || true
		done <<<"$node_mcp_keys"
	fi

	if [[ $updated -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_success "Updated $updated MCP commands to use full binary paths in opencode.json"
	else
		rm -f "$tmp_config"
	fi

	return 0
}

setup_localwp_mcp() {
	print_info "Setting up LocalWP MCP server..."

	# Check if LocalWP is installed
	local localwp_found=false
	if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
		localwp_found=true
	fi

	if [[ "$localwp_found" != "true" ]]; then
		print_info "LocalWP not found - skipping MCP server setup"
		print_info "Install LocalWP from: https://localwp.com/"
		return 0
	fi

	print_success "LocalWP found"

	# Check if npm is available
	if ! command -v npm &>/dev/null; then
		print_warning "npm not found - cannot install LocalWP MCP server"
		print_info "Install Node.js and npm first"
		return 0
	fi

	# Check if mcp-local-wp is already installed
	if command -v mcp-local-wp &>/dev/null; then
		print_success "LocalWP MCP server already installed"
		return 0
	fi

	# Offer to install mcp-local-wp
	print_info "LocalWP MCP server enables AI assistants to query WordPress databases"
	read -r -p "Install LocalWP MCP server (@verygoodplugins/mcp-local-wp)? [Y/n]: " install_mcp

	if [[ "$install_mcp" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing LocalWP MCP server" npm_global_install "@verygoodplugins/mcp-local-wp"; then
			print_info "Start with: ~/.aidevops/agents/scripts/localhost-helper.sh start-mcp"
			print_info "Or configure in OpenCode MCP settings for auto-start"
		else
			print_info "Try manually: sudo npm install -g @verygoodplugins/mcp-local-wp"
		fi
	else
		print_info "Skipped LocalWP MCP server installation"
		print_info "Install later: npm install -g @verygoodplugins/mcp-local-wp"
	fi

	return 0
}

setup_augment_context_engine() {
	print_info "Setting up Augment Context Engine MCP..."

	# Check Node.js version (requires 22+)
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - Augment Context Engine setup skipped"
		print_info "Install Node.js 22+ to enable Augment Context Engine"
		return
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 22 ]]; then
		print_warning "Node.js 22+ required for Augment Context Engine, found v$node_version"
		print_info "Install: brew install node@22 (macOS) or nvm install 22"
		return
	fi

	# Check if auggie is installed
	if ! command -v auggie &>/dev/null; then
		print_warning "Auggie CLI not found"
		print_info "Install with: npm install -g @augmentcode/auggie@prerelease"
		print_info "Then run: auggie login"
		return
	fi

	# Check if logged in
	if [[ ! -f "$HOME/.augment/session.json" ]]; then
		print_warning "Auggie not logged in"
		print_info "Run: auggie login"
		return
	fi

	print_success "Auggie CLI found and authenticated"

	# MCP configuration is handled by generate-opencode-agents.sh for OpenCode

	print_info "Augment Context Engine available as MCP in OpenCode"
	print_info "Verification: 'What is this project? Please use codebase retrieval tool.'"

	return 0
}

setup_osgrep() {
	print_info "Setting up osgrep (local semantic search)..."

	# Check Node.js version (requires 18+)
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - osgrep setup skipped"
		print_info "Install Node.js 18+ to enable osgrep"
		return 0
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 18 ]]; then
		print_warning "Node.js 18+ required for osgrep, found v$node_version"
		print_info "Install: brew install node@18 (macOS) or nvm install 18"
		return 0
	fi

	# Check if osgrep is installed
	if ! command -v osgrep &>/dev/null; then
		echo ""
		print_info "osgrep provides 100% local semantic search (no cloud, no auth)"
		echo "  • Search code by meaning, not just keywords"
		echo "  • Works offline with ~150MB local embedding models"
		echo "  • Configured as MCP in OpenCode"
		echo ""

		read -r -p "Install osgrep CLI? [Y/n]: " install_osgrep
		if [[ "$install_osgrep" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing osgrep CLI" npm_global_install osgrep; then
				print_info "Now downloading embedding models (~150MB)..."
				# osgrep setup is interactive, don't use spinner
				if osgrep setup; then
					print_success "osgrep installed and configured"
				else
					print_warning "Model download failed - run manually: osgrep setup"
				fi
			else
				print_warning "Installation failed - try manually: sudo npm install -g osgrep"
				return 0
			fi
		else
			print_info "Skipped osgrep installation"
			print_info "Install later: npm install -g osgrep && osgrep setup"
			return 0
		fi
	fi

	# Check if models are downloaded
	if [[ ! -d "$HOME/.osgrep" ]]; then
		print_warning "osgrep models not yet downloaded"
		read -r -p "Download embedding models now (~150MB)? [Y/n]: " download_models
		if [[ "$download_models" =~ ^[Yy]?$ ]]; then
			if osgrep setup; then
				print_success "osgrep models downloaded"
			else
				print_warning "Model download failed - run manually: osgrep setup"
			fi
		else
			print_info "Download later: osgrep setup"
		fi
	else
		print_success "osgrep CLI installed and configured"
	fi

	print_info "Verification: 'Search for authentication handling in this codebase'"
	return 0
}

setup_browser_tools() {
	print_info "Setting up browser automation tools..."

	local has_bun=false
	local has_node=false

	# Check Bun
	if command -v bun &>/dev/null; then
		has_bun=true
		print_success "Bun $(bun --version) found"
	fi

	# Check Node.js (for Playwriter)
	if command -v node &>/dev/null; then
		has_node=true
	fi

	# Install Bun if not present (required for dev-browser)
	if [[ "$has_bun" == "false" ]]; then
		print_info "Installing Bun (required for dev-browser)..."
		if verified_install "Bun" "https://bun.sh/install"; then
			# Source the updated PATH
			export BUN_INSTALL="$HOME/.bun"
			export PATH="$BUN_INSTALL/bin:$PATH"
			if command -v bun &>/dev/null; then
				has_bun=true
				print_success "Bun installed: $(bun --version)"

				# Bun's installer may only write to the running shell's rc file.
				# Ensure Bun PATH is in all shell rc files for cross-shell compat.
				local bun_path_line='export BUN_INSTALL="$HOME/.bun"'
				local bun_export_line='export PATH="$BUN_INSTALL/bin:$PATH"'
				local bun_rc
				while IFS= read -r bun_rc; do
					[[ -z "$bun_rc" ]] && continue
					if [[ ! -f "$bun_rc" ]]; then
						touch "$bun_rc"
					fi
					if ! grep -q '\.bun' "$bun_rc" 2>/dev/null; then
						echo "" >>"$bun_rc"
						echo "# Bun (added by aidevops setup)" >>"$bun_rc"
						echo "$bun_path_line" >>"$bun_rc"
						echo "$bun_export_line" >>"$bun_rc"
						print_info "Added Bun to PATH in $bun_rc"
					fi
				done < <(get_all_shell_rcs)
			fi
		else
			print_warning "Bun installation failed - dev-browser will need manual setup"
		fi
	fi

	# Setup dev-browser if Bun is available
	if [[ "$has_bun" == "true" ]]; then
		local dev_browser_dir="$HOME/.aidevops/dev-browser"

		if [[ -d "${dev_browser_dir}/skills/dev-browser" ]]; then
			print_success "dev-browser already installed"
		else
			print_info "Installing dev-browser (stateful browser automation)..."
			local dev_browser_output
			if dev_browser_output=$(bash "$HOME/.aidevops/agents/scripts/dev-browser-helper.sh" setup 2>&1); then
				print_success "dev-browser installed"
				print_info "Start server with: bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start"
			else
				print_warning "dev-browser setup failed:"
				# Show last few lines of error output for debugging
				echo "$dev_browser_output" | tail -5 | sed 's/^/  /'
				echo ""
				print_info "Run manually to see full output:"
				print_info "  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup"
			fi
		fi
	fi

	# Playwriter MCP (Node.js based, runs via npx)
	if [[ "$has_node" == "true" ]]; then
		print_success "Playwriter MCP available (runs via npx playwriter@latest)"
		print_info "Install Chrome extension: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe"
	else
		print_warning "Node.js not found - Playwriter MCP unavailable"
	fi

	# Playwright MCP (cross-browser testing automation)
	if [[ "$has_node" == "true" ]]; then
		print_info "Setting up Playwright MCP..."

		# Check if Playwright browsers are installed (--no-install prevents auto-download)
		if npx --no-install playwright --version &>/dev/null 2>&1; then
			print_success "Playwright already installed"
		else
			local install_playwright
			read -r -p "Install Playwright MCP with browsers (chromium, firefox, webkit)? [Y/n]: " install_playwright

			if [[ "$install_playwright" =~ ^[Yy]?$ ]]; then
				print_info "Installing Playwright browsers..."
				# Use -y to auto-confirm npx install, suppress the "install without dependencies" warning
				# Use PIPESTATUS to check npx exit code, not grep's exit code
				npx -y playwright@latest install 2>&1 | grep -v "WARNING: It looks like you are running"
				if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
					print_success "Playwright browsers installed"
				else
					print_warning "Playwright browser installation failed"
					print_info "Run manually: npx -y playwright@latest install"
				fi
			else
				print_info "Skipped Playwright installation"
				print_info "Install later with: npx playwright install"
			fi
		fi

		print_info "Playwright MCP runs via: npx playwright-mcp@latest"
	fi

	if [[ "$has_node" == "true" ]]; then
		print_info "Browser tools: dev-browser (stateful), Playwriter (extension), Playwright (testing), Stagehand (AI)"
	else
		print_info "Browser tools: dev-browser (stateful), Stagehand (AI)"
	fi
	return 0
}

add_opencode_plugin() {
	local plugin_name="$1"
	local plugin_spec="$2"
	local opencode_config="$3"

	# Check if plugin array exists and if plugin is already configured
	local has_plugin_array
	has_plugin_array=$(jq -e '.plugin' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")

	if [[ "$has_plugin_array" == "true" ]]; then
		# Check if plugin is already in the array
		local plugin_exists
		plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(startswith($p))) | length > 0' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")

		if [[ "$plugin_exists" == "true" ]]; then
			# Update existing plugin to latest version
			local temp_file
			temp_file=$(mktemp)
			trap 'rm -f "${temp_file:-}"' RETURN
			jq --arg old "$plugin_name" --arg new "$plugin_spec" \
				'.plugin = [.plugin[] | if startswith($old) then $new else . end]' \
				"$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
			print_success "Updated $plugin_name to latest version"
		else
			# Add plugin to existing array
			local temp_file
			temp_file=$(mktemp)
			trap 'rm -f "${temp_file:-}"' RETURN
			jq --arg p "$plugin_spec" '.plugin += [$p]' "$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
			print_success "Added $plugin_name plugin to OpenCode config"
		fi
	else
		# Create plugin array with the plugin
		local temp_file
		temp_file=$(mktemp)
		trap 'rm -f "${temp_file:-}"' RETURN
		jq --arg p "$plugin_spec" '. + {plugin: [$p]}' "$opencode_config" >"$temp_file" && mv "$temp_file" "$opencode_config"
		print_success "Created plugin array with $plugin_name"
	fi
}

setup_opencode_plugins() {
	print_info "Setting up OpenCode plugins..."

	# Check if OpenCode is installed
	if ! command -v opencode &>/dev/null; then
		print_warning "OpenCode not found - plugin setup skipped"
		print_info "Install OpenCode first: https://opencode.ai"
		return 0
	fi

	# Check if config exists
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_warning "OpenCode config not found - plugin setup skipped"
		return 0
	fi

	# Check if jq is available
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot update OpenCode config"
		return 0
	fi

	# Setup aidevops compaction plugin (local file plugin)
	local aidevops_plugin_path="$HOME/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
	if [[ -f "$aidevops_plugin_path" ]]; then
		print_info "Setting up aidevops compaction plugin..."
		add_opencode_plugin "file://$HOME/.aidevops" "file://${aidevops_plugin_path}" "$opencode_config"
		print_success "aidevops compaction plugin registered (preserves context across compaction)"
	fi

	# Note: opencode-anthropic-auth is built into OpenCode v1.1.36+
	# Adding it as an external plugin causes TypeError due to double-loading.
	# Removed in v2.90.0 - see PR #230.

	print_info "After setup, authenticate with: opencode auth login"
	print_info "  • For Claude OAuth: Select 'Anthropic' → 'Claude Pro/Max' (built-in)"

	return 0
}

setup_seo_mcps() {
	print_info "Setting up SEO integrations..."

	# SEO services use curl-based subagents (no MCP needed)
	# Subagents: serper.md, dataforseo.md, ahrefs.md, google-search-console.md
	print_info "SEO uses curl-based subagents (zero context cost until invoked)"

	# Check if credentials are configured
	if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
		# shellcheck source=/dev/null
		source "$HOME/.config/aidevops/credentials.sh"

		[[ -n "$DATAFORSEO_USERNAME" ]] && print_success "DataForSEO credentials configured" ||
			print_info "DataForSEO: set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in credentials.sh"

		[[ -n "$SERPER_API_KEY" ]] && print_success "Serper API key configured" ||
			print_info "Serper: set SERPER_API_KEY in credentials.sh"

		[[ -n "$AHREFS_API_KEY" ]] && print_success "Ahrefs API key configured" ||
			print_info "Ahrefs: set AHREFS_API_KEY in credentials.sh"
	else
		print_info "Configure SEO API credentials in ~/.config/aidevops/credentials.sh"
	fi

	# GSC uses MCP (OAuth2 complexity warrants it)
	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"
	if [[ -f "$gsc_creds" ]]; then
		print_success "Google Search Console credentials configured"
	else
		print_info "GSC: Create service account JSON at $gsc_creds"
		print_info "  See: ~/.aidevops/agents/seo/google-search-console.md"
	fi

	print_info "SEO documentation: ~/.aidevops/agents/seo/"
	return 0
}

setup_google_analytics_mcp() {
	print_info "Setting up Google Analytics MCP..."

	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"

	# Check if opencode.json exists
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_warning "OpenCode config not found - skipping Google Analytics MCP"
		return 0
	fi

	# Check if jq is available
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot add Google Analytics MCP to config"
		print_info "Install jq and re-run setup, or manually add the MCP config"
		return 0
	fi

	# Check if pipx is available
	if ! command -v pipx &>/dev/null; then
		print_warning "pipx not found - Google Analytics MCP requires pipx"
		print_info "Install pipx: brew install pipx (macOS) or pip install pipx"
		print_info "Then re-run setup to add Google Analytics MCP"
		return 0
	fi

	# Auto-detect credentials from shared GSC service account
	local creds_path=""
	local project_id=""
	local enable_mcp="false"

	if [[ -f "$gsc_creds" ]]; then
		creds_path="$gsc_creds"
		# Extract project_id from service account JSON
		project_id=$(jq -r '.project_id // empty' "$gsc_creds" 2>/dev/null)
		if [[ -n "$project_id" ]]; then
			enable_mcp="true"
			print_success "Found GSC credentials - sharing with Google Analytics MCP"
			print_info "Project: $project_id"
		fi
	fi

	# Check if google-analytics-mcp already exists in config
	if jq -e '.mcp["google-analytics-mcp"]' "$opencode_config" >/dev/null 2>&1; then
		# Update existing entry if we have credentials now
		if [[ "$enable_mcp" == "true" ]]; then
			local tmp_config
			tmp_config=$(mktemp)
			trap 'rm -f "${tmp_config:-}"' RETURN
			if jq --arg creds "$creds_path" --arg proj "$project_id" \
				'.mcp["google-analytics-mcp"].environment.GOOGLE_APPLICATION_CREDENTIALS = $creds |
                 .mcp["google-analytics-mcp"].environment.GOOGLE_PROJECT_ID = $proj |
                 .mcp["google-analytics-mcp"].enabled = true' \
				"$opencode_config" >"$tmp_config" 2>/dev/null; then
				mv "$tmp_config" "$opencode_config"
				print_success "Updated Google Analytics MCP with GSC credentials (enabled)"
			else
				rm -f "$tmp_config"
				print_warning "Failed to update Google Analytics MCP config"
			fi
		else
			print_info "Google Analytics MCP already configured in OpenCode"
		fi
		return 0
	fi

	# Add google-analytics-mcp to opencode.json
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	if jq --arg creds "$creds_path" --arg proj "$project_id" --argjson enabled "$enable_mcp" \
		'.mcp["google-analytics-mcp"] = {
        "type": "local",
        "command": ["analytics-mcp"],
        "environment": {
            "GOOGLE_APPLICATION_CREDENTIALS": $creds,
            "GOOGLE_PROJECT_ID": $proj
        },
        "enabled": $enabled
    }' "$opencode_config" >"$tmp_config" 2>/dev/null; then
		mv "$tmp_config" "$opencode_config"
		if [[ "$enable_mcp" == "true" ]]; then
			print_success "Added Google Analytics MCP to OpenCode (enabled with GSC credentials)"
		else
			print_success "Added Google Analytics MCP to OpenCode (disabled - no credentials found)"
			print_info "To enable: Create service account JSON at $gsc_creds"
		fi
		print_info "Or use the google-analytics subagent which enables it automatically"
	else
		rm -f "$tmp_config"
		print_warning "Failed to add Google Analytics MCP to config"
	fi

	# Show setup instructions
	print_info "Google Analytics MCP setup:"
	print_info "  1. Enable Google Analytics Admin & Data APIs in Google Cloud Console"
	print_info "  2. Configure ADC: gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
	print_info "  3. Update GOOGLE_APPLICATION_CREDENTIALS path in opencode.json"
	print_info "  4. Set GOOGLE_PROJECT_ID in opencode.json"
	print_info "Documentation: ~/.aidevops/agents/services/analytics/google-analytics.md"

	return 0
}

setup_quickfile_mcp() {
	print_info "Setting up QuickFile MCP server..."

	local quickfile_dir="$HOME/Git/quickfile-mcp"
	local credentials_dir="$HOME/.config/.quickfile-mcp"
	local credentials_file="$credentials_dir/credentials.json"

	# Check if Node.js is available
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - QuickFile MCP setup skipped"
		print_info "Install Node.js 18+ to enable QuickFile MCP"
		return 0
	fi

	# Check if already cloned and built
	if [[ -f "$quickfile_dir/dist/index.js" ]]; then
		print_success "QuickFile MCP already installed at $quickfile_dir"
	else
		print_info "QuickFile MCP provides AI access to UK accounting (invoices, clients, reports)"
		read -r -p "Clone and build QuickFile MCP server? [Y/n]: " install_qf

		if [[ "$install_qf" =~ ^[Yy]?$ ]]; then
			if [[ ! -d "$quickfile_dir" ]]; then
				if run_with_spinner "Cloning quickfile-mcp" git clone https://github.com/marcusquinn/quickfile-mcp.git "$quickfile_dir"; then
					print_success "Cloned quickfile-mcp"
				else
					print_warning "Failed to clone quickfile-mcp"
					return 0
				fi
			fi

			if run_with_spinner "Installing dependencies" npm install --prefix "$quickfile_dir"; then
				if run_with_spinner "Building QuickFile MCP" npm run build --prefix "$quickfile_dir"; then
					print_success "QuickFile MCP built successfully"
				else
					print_warning "Build failed - try manually: cd $quickfile_dir && npm run build"
					return 0
				fi
			else
				print_warning "npm install failed - try manually: cd $quickfile_dir && npm install"
				return 0
			fi
		else
			print_info "Skipped QuickFile MCP installation"
			print_info "Install later: git clone https://github.com/marcusquinn/quickfile-mcp.git ~/Git/quickfile-mcp"
			return 0
		fi
	fi

	# Check credentials
	if [[ -f "$credentials_file" ]]; then
		print_success "QuickFile credentials configured at $credentials_file"
	else
		print_info "QuickFile credentials not found"
		print_info "Create credentials:"
		print_info "  mkdir -p $credentials_dir && chmod 700 $credentials_dir"
		print_info "  Create $credentials_file with:"
		print_info "    accountNumber: from QuickFile dashboard (top-right)"
		print_info "    apiKey: Account Settings > 3rd Party Integrations > API Key"
		print_info "    applicationId: Account Settings > Create a QuickFile App"
	fi

	# Update OpenCode config if available
	local opencode_config
	if opencode_config=$(find_opencode_config); then
		local quickfile_entry
		quickfile_entry=$(jq -r '.mcp.quickfile // empty' "$opencode_config" 2>/dev/null)

		if [[ -z "$quickfile_entry" ]]; then
			print_info "Adding QuickFile MCP to OpenCode config..."
			local node_path
			node_path=$(resolve_mcp_binary_path "node")
			[[ -z "$node_path" ]] && node_path="node"

			local tmp_config
			tmp_config=$(mktemp)
			trap 'rm -f "${tmp_config:-}"' RETURN

			if jq --arg np "$node_path" --arg dp "$quickfile_dir/dist/index.js" \
				'.mcp.quickfile = {"type": "local", "command": [$np, $dp], "enabled": true}' \
				"$opencode_config" >"$tmp_config" 2>/dev/null; then
				create_backup_with_rotation "$opencode_config" "opencode"
				mv "$tmp_config" "$opencode_config"
				print_success "QuickFile MCP added to OpenCode config"
			else
				rm -f "$tmp_config"
				print_warning "Failed to update OpenCode config - add manually"
			fi
		else
			print_success "QuickFile MCP already in OpenCode config"
		fi
	fi

	print_info "Documentation: ~/.aidevops/agents/services/accounting/quickfile.md"
	return 0
}

