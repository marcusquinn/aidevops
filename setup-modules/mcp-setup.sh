#!/usr/bin/env bash
# MCP setup functions: install_mcp_packages, resolve_mcp_binary, localwp, augment, seo, analytics, quickfile, browser-tools, opencode-plugins
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

install_mcp_packages() {
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v bun &>/dev/null && ! command -v npm &>/dev/null; then
		print_skip "MCP packages" "neither bun nor npm found" "Install bun: brew install oven-sh/bun/bun (or npm via Node.js)"
		setup_track_deferred "MCP packages" "Install bun or npm"
		return 0
	fi

	print_info "Installing MCP server packages globally (eliminates npx startup delay)..."

	# Security note: MCP servers run as persistent processes with access to conversation
	# context, credentials, and network. The packages below are from known/vetted sources.
	# Before adding new MCP packages to this list, verify the source repository and scan
	# dependencies with: npx @socketsecurity/cli npm info <package>
	# See: .agents/tools/mcp-toolkit/mcporter.md "Security Considerations"

	# Node.js MCP packages to install globally
	local -a node_mcps=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
	)

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
			((++updated))
		else
			((++failed))
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

	if command -v uv &>/dev/null && uv tool --help &>/dev/null; then
		print_info "Installing/updating outscraper-mcp-server via uv..."
		if command -v outscraper-mcp-server &>/dev/null; then
			uv tool upgrade outscraper-mcp-server >/dev/null 2>&1 || true
		else
			uv tool install outscraper-mcp-server >/dev/null 2>&1 || print_warning "Failed to install outscraper-mcp-server"
		fi
	elif command -v uv &>/dev/null; then
		print_warning "uv is installed but too old to support 'tool' subcommand — skipping outscraper-mcp-server"
		print_info "Update uv with: curl -LsSf https://astral.sh/uv/install.sh | sh"
	fi

	# Update opencode.json with resolved full paths for all MCP binaries
	update_mcp_paths_in_opencode

	print_info "MCP servers will start instantly (no registry lookups on each launch)"
	return 0
}

resolve_mcp_binary_path() {
	local bin_name
	bin_name="$1"
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
					((++updated))
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
			((++updated))
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
			((++updated))
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
	# Check prerequisites before announcing setup (GH#5240)
	local localwp_found=false
	if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
		localwp_found=true
	fi

	if [[ "$localwp_found" != "true" ]]; then
		print_skip "LocalWP MCP" "LocalWP not installed" "Install from https://localwp.com/ then re-run setup"
		setup_track_skipped "LocalWP MCP" "LocalWP not installed"
		return 0
	fi

	if ! command -v npm &>/dev/null; then
		print_skip "LocalWP MCP" "npm not found" "Install Node.js and npm first"
		setup_track_deferred "LocalWP MCP" "Install Node.js/npm, then re-run setup"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up LocalWP MCP server..."

	if command -v mcp-local-wp &>/dev/null; then
		print_success "LocalWP MCP server already installed"
		setup_track_configured "LocalWP MCP"
		return 0
	fi

	print_info "LocalWP MCP server enables AI assistants to query WordPress databases"
	read -r -p "Install LocalWP MCP server (@verygoodplugins/mcp-local-wp)? [Y/n]: " install_mcp

	if [[ "$install_mcp" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing LocalWP MCP server" npm_global_install "@verygoodplugins/mcp-local-wp"; then
			print_info "Start with: ~/.aidevops/agents/scripts/localhost-helper.sh start-mcp"
			print_info "Or configure in OpenCode MCP settings for auto-start"
			setup_track_configured "LocalWP MCP"
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
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v node &>/dev/null; then
		print_skip "Augment Context Engine" "Node.js not installed" "Install Node.js 22+: brew install node@22 (macOS) or nvm install 22"
		setup_track_deferred "Augment Context Engine" "Install Node.js 22+"
		return 0
	fi

	local node_version
	node_version=$(node --version 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ -z "$node_version" ]] || ! [[ "$node_version" =~ ^[0-9]+$ ]]; then
		print_skip "Augment Context Engine" "could not determine Node.js version"
		setup_track_skipped "Augment Context Engine" "Node.js version unknown"
		return 0
	fi
	if [[ "$node_version" -lt 22 ]]; then
		print_skip "Augment Context Engine" "requires Node.js 22+, found v$node_version" "Upgrade: brew install node@22 (macOS) or nvm install 22"
		setup_track_deferred "Augment Context Engine" "Upgrade Node.js to 22+ (currently v$node_version)"
		return 0
	fi

	if ! command -v auggie &>/dev/null; then
		print_skip "Augment Context Engine" "Auggie CLI not installed" "Install: npm install -g @augmentcode/auggie@prerelease && auggie login"
		setup_track_deferred "Augment Context Engine" "Install Auggie CLI: npm install -g @augmentcode/auggie@prerelease"
		return 0
	fi

	if [[ ! -f "$HOME/.augment/session.json" ]]; then
		print_skip "Augment Context Engine" "Auggie not logged in" "Run: auggie login"
		setup_track_deferred "Augment Context Engine" "Run: auggie login"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up Augment Context Engine MCP..."
	print_success "Auggie CLI found and authenticated"

	# MCP configuration is handled by generate-opencode-agents.sh for OpenCode

	print_info "Augment Context Engine available as MCP in OpenCode"
	print_info "Verification: 'What is this project? Please use codebase retrieval tool.'"
	setup_track_configured "Augment Context Engine"

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
				# shellcheck disable=SC2016 # written to rc files; must expand at shell startup, not now
				local bun_path_line='export BUN_INSTALL="$HOME/.bun"'
				# shellcheck disable=SC2016 # written to rc files; must expand at shell startup, not now
				local bun_export_line='export PATH="$BUN_INSTALL/bin:$PATH"'
				local bun_rc
				while IFS= read -r bun_rc; do
					[[ -z "$bun_rc" ]] && continue
					if [[ ! -f "$bun_rc" ]]; then
						touch "$bun_rc"
					fi
					if ! grep -q '\.bun' "$bun_rc" 2>/dev/null; then
						{
							echo ""
							echo "# Bun (added by aidevops setup)"
							echo "$bun_path_line"
							echo "$bun_export_line"
						} >>"$bun_rc"
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

setup_opencode_plugins() {
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v opencode &>/dev/null; then
		print_skip "OpenCode plugins" "OpenCode not installed" "Install from https://opencode.ai"
		setup_track_skipped "OpenCode plugins" "OpenCode not installed"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up OpenCode plugins..."

	# Setup aidevops plugin via local plugin directory (not opencode.json plugin array).
	# OpenCode's plugin array is npm-only. Local plugins must be symlinked to:
	#   ~/.config/opencode/plugins/  (global)
	#   .opencode/plugins/           (project-level)
	# See: https://opencode.ai/docs/plugins/
	local plugins_dir="$HOME/.config/opencode/plugins"
	local aidevops_plugin_src="$HOME/.aidevops/agents/plugins/opencode-aidevops"
	local aidevops_plugin_dst="$plugins_dir/opencode-aidevops"
	local pool_plugin_registered="false"
	local aidevops_plugin_entrypoint="$aidevops_plugin_src/index.mjs"

	if [[ ! -f "$aidevops_plugin_entrypoint" ]]; then
		print_skip "OpenCode plugins" "aidevops plugin entry point not found: $aidevops_plugin_entrypoint"
		setup_track_deferred "OpenCode plugins" "Install/restore aidevops plugin at $aidevops_plugin_entrypoint"
		return 0
	fi

	# Create plugins directory if needed
	mkdir -p "$plugins_dir"

	# Register plugin if needed; treat broken symlinks as unregistered.
	if [[ -L "$aidevops_plugin_dst" && -e "$aidevops_plugin_dst" ]]; then
		print_success "aidevops plugin already registered at ~/.config/opencode/plugins/"
		setup_track_configured "OpenCode plugins"
		pool_plugin_registered="true"
	elif [[ -L "$aidevops_plugin_dst" ]]; then
		print_warning "Broken aidevops plugin symlink detected; recreating ~/.config/opencode/plugins/opencode-aidevops"
		ln -sfn "$aidevops_plugin_src" "$aidevops_plugin_dst"
		print_success "aidevops plugin registered at ~/.config/opencode/plugins/"
		setup_track_configured "OpenCode plugins"
		pool_plugin_registered="true"
	elif [[ -d "$aidevops_plugin_dst" && -f "$aidevops_plugin_dst/index.mjs" ]]; then
		print_success "aidevops plugin already registered at ~/.config/opencode/plugins/"
		setup_track_configured "OpenCode plugins"
		pool_plugin_registered="true"
	else
		ln -sfn "$aidevops_plugin_src" "$aidevops_plugin_dst"
		print_success "aidevops plugin registered at ~/.config/opencode/plugins/"
		setup_track_configured "OpenCode plugins"
		pool_plugin_registered="true"
	fi

	# Note: opencode-anthropic-auth is built into OpenCode v1.1.36+
	# Adding it as an external plugin causes TypeError due to double-loading.
	# Removed in v2.90.0 - see PR #230.

	# Detect OpenCode version to give appropriate auth guidance (t1546, GH#5312)
	# v1.2.30+ removes the built-in anthropic-auth plugin entirely.
	# The aidevops OAuth pool (oauth-pool.mjs) is the replacement for all versions.
	local oc_raw_version
	oc_raw_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

	local oc_major oc_minor oc_patch
	IFS='.' read -r oc_major oc_minor oc_patch <<<"$oc_raw_version"
	oc_major="${oc_major:-0}"
	oc_minor="${oc_minor:-0}"
	oc_patch="${oc_patch:-0}"

	# Compare against 1.2.30 (where built-in anthropic-auth was removed)
	local builtin_auth_removed="false"
	if [[ "$oc_major" -gt 1 ]] ||
		[[ "$oc_major" -eq 1 && "$oc_minor" -gt 2 ]] ||
		[[ "$oc_major" -eq 1 && "$oc_minor" -eq 2 && "$oc_patch" -ge 30 ]]; then
		builtin_auth_removed="true"
	fi

	if [[ "$builtin_auth_removed" == "true" ]]; then
		print_info "OpenCode v${oc_raw_version}: built-in Anthropic OAuth removed in v1.2.30"
		if [[ "$pool_plugin_registered" == "true" ]]; then
			print_info "Use the aidevops OAuth pool (provided by the aidevops plugin above):"
			print_info "  1. Run: opencode auth login"
			print_info "  2. Select: 'Anthropic Pool' (added by aidevops plugin)"
			print_info "  3. Enter your Claude account email"
			print_info "  4. Complete the OAuth flow in your browser"
			print_info "  5. Repeat to add more accounts for automatic rotation"
			print_info "  Manage accounts: /model-accounts-pool list|status|remove"
			print_info "  Docs: ~/.aidevops/agents/tools/opencode/opencode-anthropic-auth.md"
		else
			print_warning "aidevops OpenCode plugin was not registered; 'Anthropic Pool' may be unavailable"
			print_info "Re-run aidevops setup to register the plugin, then run: opencode auth login"
		fi
	else
		print_info "After setup, authenticate with: opencode auth login"
		print_info "  - For Claude OAuth (v1.1.36-v1.2.29): Select 'Anthropic' -> 'Claude Pro/Max' (built-in)"
		print_info "  - Or use the aidevops OAuth pool: Select 'Anthropic Pool' for multi-account rotation"
	fi

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

		if [[ -n "${DATAFORSEO_USERNAME:-}" ]]; then
			print_success "DataForSEO credentials configured"
		else
			print_info "DataForSEO: set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in credentials.sh"
		fi

		if [[ -n "${SERPER_API_KEY:-}" ]]; then
			print_success "Serper API key configured"
		else
			print_info "Serper: set SERPER_API_KEY in credentials.sh"
		fi

		if [[ -n "${AHREFS_API_KEY:-}" ]]; then
			print_success "Ahrefs API key configured"
		else
			print_info "Ahrefs: set AHREFS_API_KEY in credentials.sh"
		fi
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
	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"

	# Check prerequisites before announcing setup (GH#5240)
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_skip "Google Analytics MCP" "OpenCode config not found" "Run 'opencode' once to create config, then re-run setup"
		setup_track_skipped "Google Analytics MCP" "OpenCode config not found"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_skip "Google Analytics MCP" "jq not installed" "Install jq: brew install jq (macOS) or apt install jq"
		setup_track_deferred "Google Analytics MCP" "Install jq"
		return 0
	fi

	if ! command -v pipx &>/dev/null; then
		print_skip "Google Analytics MCP" "pipx not installed" "Install pipx: brew install pipx (macOS) or pip install pipx"
		setup_track_deferred "Google Analytics MCP" "Install pipx"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up Google Analytics MCP..."

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
	local quickfile_dir="$HOME/Git/quickfile-mcp"
	local credentials_dir="$HOME/.config/.quickfile-mcp"
	local credentials_file="$credentials_dir/credentials.json"

	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v node &>/dev/null; then
		print_skip "QuickFile MCP" "Node.js not installed" "Install Node.js 18+: brew install node (macOS) or nvm install 18"
		setup_track_deferred "QuickFile MCP" "Install Node.js 18+"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up QuickFile MCP server..."

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
