#!/usr/bin/env bash
# Migration functions: migrate_* and cleanup_* functions
# Part of aidevops setup.sh modularization (t316.3)

cleanup_deprecated_paths() {
	local agents_dir="$HOME/.aidevops/agents"
	local cleaned=0

	# List of deprecated paths (add new ones here when reorganizing)
	local deprecated_paths=(
		# v2.40.7: wordpress moved from root to tools/wordpress
		"$agents_dir/wordpress.md"
		"$agents_dir/wordpress"
		# v2.41.0: build-agent and build-mcp moved from root to tools/
		"$agents_dir/build-agent.md"
		"$agents_dir/build-agent"
		"$agents_dir/build-mcp.md"
		"$agents_dir/build-mcp"
		# v2.93.3: moltbot renamed to openclaw (formerly clawdbot)
		"$agents_dir/tools/ai-assistants/clawdbot.md"
		"$agents_dir/tools/ai-assistants/moltbot.md"
		# Removed non-OpenCode AI tool docs (focus on OpenCode only)
		"$agents_dir/tools/ai-assistants/windsurf.md"
		"$agents_dir/tools/ai-assistants/configuration.md"
		"$agents_dir/tools/ai-assistants/status.md"
		# Removed oh-my-opencode integration (no longer supported)
		"$agents_dir/tools/opencode/oh-my-opencode.md"
		# t199.8: youtube moved from root to content/distribution/youtube/
		"$agents_dir/youtube.md"
		"$agents_dir/youtube"
	)

	for path in "${deprecated_paths[@]}"; do
		if [[ -e "$path" ]]; then
			rm -rf "$path"
			((cleaned++)) || true
		fi
	done

	if [[ $cleaned -gt 0 ]]; then
		print_info "Cleaned up $cleaned deprecated agent path(s)"
	fi

	# Optionally remove oh-my-opencode config (GH#1142: default to keeping it)
	# Users who independently installed oh-my-opencode should not have their config deleted
	local omo_config="$HOME/.config/opencode/oh-my-opencode.json"
	local has_omo_config=false
	local has_omo_plugin=false
	local opencode_config
	opencode_config=$(find_opencode_config 2>/dev/null) || true

	if [[ -f "$omo_config" ]]; then
		has_omo_config=true
	fi
	if [[ -n "$opencode_config" ]] && [[ -f "$opencode_config" ]] && command -v jq &>/dev/null; then
		if jq -e '.plugin | index("oh-my-opencode")' "$opencode_config" >/dev/null 2>&1; then
			has_omo_plugin=true
		fi
	fi

	if [[ "$has_omo_config" == "true" ]] || [[ "$has_omo_plugin" == "true" ]]; then
		local remove_omo="n"
		if [[ "$NON_INTERACTIVE" != "true" ]] && [[ "$INTERACTIVE_MODE" == "true" ]]; then
			print_info "Found oh-my-opencode config. aidevops no longer bundles oh-my-opencode."
			echo -n -e "${GREEN}Remove oh-my-opencode config and plugin entry? [y/N]: ${NC}"
			read -r remove_omo
			remove_omo=$(echo "$remove_omo" | tr '[:upper:]' '[:lower:]')
		fi

		if [[ "$remove_omo" == "y" ]] || [[ "$remove_omo" == "yes" ]]; then
			if [[ "$has_omo_config" == "true" ]]; then
				rm -f "$omo_config"
				print_info "Removed oh-my-opencode config"
			fi
			if [[ "$has_omo_plugin" == "true" ]]; then
				local tmp_file
				tmp_file=$(mktemp)
				trap 'rm -f "${tmp_file:-}"' RETURN
				jq '.plugin = [.plugin[] | select(. != "oh-my-opencode")]' "$opencode_config" >"$tmp_file" && mv "$tmp_file" "$opencode_config"
				print_info "Removed oh-my-opencode from OpenCode plugin list"
			fi
		else
			if [[ "$NON_INTERACTIVE" != "true" ]]; then
				print_info "Keeping oh-my-opencode config (skipped)"
			fi
		fi
	fi

	return 0
}

# Migrate .agent -> .agents in user projects and local config
# v2.104.0: Industry converging on .agents/ folder convention (aligning with AGENTS.md)
# This migrates:
# 1. .agent symlinks in user projects -> .agents
# 2. .agent/loop-state/ -> .agents/loop-state/ in user projects
# 3. .gitignore entries in user projects
# 4. References in user's AI assistant configs
# 5. References in ~/.aidevops/ config files
migrate_agent_to_agents_folder() {
	print_info "Checking for .agent -> .agents migration..."

	local migrated=0

	# 1. Migrate .agent symlinks in registered repos
	local repos_file="$HOME/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path" ]] && continue

			# Migrate .agent symlink to .agents
			if [[ -L "$repo_path/.agent" ]]; then
				local target
				target=$(readlink "$repo_path/.agent")
				rm -f "$repo_path/.agent"
				ln -s "$target" "$repo_path/.agents" 2>/dev/null || true
				print_info "  Migrated symlink: $repo_path/.agent -> .agents"
				((migrated++)) || true
			elif [[ -d "$repo_path/.agent" && ! -L "$repo_path/.agent" ]]; then
				# Real directory (not symlink) - rename it
				if [[ ! -e "$repo_path/.agents" ]]; then
					mv "$repo_path/.agent" "$repo_path/.agents"
					print_info "  Renamed directory: $repo_path/.agent -> .agents"
					((migrated++)) || true
				fi
			fi

			# Update .gitignore: add .agents, keep .agent for backward compat
			local gitignore="$repo_path/.gitignore"
			if [[ -f "$gitignore" ]]; then
				# Add .agents entry if not present
				if ! grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
					# Replace .agent with .agents if it exists
					if grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
						sed -i '' 's/^\.agent$/.agents/' "$gitignore" 2>/dev/null ||
							sed -i 's/^\.agent$/.agents/' "$gitignore" 2>/dev/null || true
					else
						echo ".agents" >>"$gitignore"
					fi
					print_info "  Updated .gitignore in $(basename "$repo_path")"
				fi

				# Update .agent/loop-state/ -> .agents/loop-state/
				if grep -q "^\.agent/loop-state/" "$gitignore" 2>/dev/null; then
					sed -i '' 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null ||
						sed -i 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null || true
				fi
			fi
		done < <(jq -r '.initialized_repos[].path' "$repos_file" 2>/dev/null)
	fi

	# 2. Also scan ~/Git/ for any .agent symlinks or directories not in repos.json
	if [[ -d "$HOME/Git" ]]; then
		while IFS= read -r -d '' agent_path; do
			local repo_dir
			repo_dir=$(dirname "$agent_path")

			if [[ -L "$agent_path" ]]; then
				# Symlink: migrate or clean up stale
				if [[ ! -e "$repo_dir/.agents" ]]; then
					local target
					target=$(readlink "$agent_path")
					rm -f "$agent_path"
					ln -s "$target" "$repo_dir/.agents" 2>/dev/null || true
					print_info "  Migrated symlink: $agent_path -> .agents"
					((migrated++)) || true
				else
					# .agents already exists, remove stale .agent symlink
					rm -f "$agent_path"
					print_info "  Removed stale symlink: $agent_path (.agents already exists)"
					((migrated++)) || true
				fi
			elif [[ -d "$agent_path" ]]; then
				# Directory: rename to .agents if .agents doesn't exist
				if [[ ! -e "$repo_dir/.agents" ]]; then
					mv "$agent_path" "$repo_dir/.agents"
					print_info "  Renamed directory: $agent_path -> .agents"
					((migrated++)) || true
				fi
			fi
		done < <(find "$HOME/Git" -maxdepth 3 -name ".agent" \( -type l -o -type d \) -print0 2>/dev/null)
	fi

	# 3. Update AI assistant config files that reference .agent/
	local ai_config_files=(
		"$HOME/.config/opencode/agent/AGENTS.md"
		"$HOME/.config/Claude/AGENTS.md"
		"$HOME/.claude/commands/AGENTS.md"
		"$HOME/.opencode/AGENTS.md"
	)

	for config_file in "${ai_config_files[@]}"; do
		if [[ -f "$config_file" ]]; then
			if grep -q '\.agent/' "$config_file" 2>/dev/null; then
				sed -i '' 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null ||
					sed -i 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null || true
				print_info "  Updated references in $config_file"
				((migrated++)) || true
			fi
		fi
	done

	# 4. Update session greeting cache if it references .agent/
	local greeting_cache="$HOME/.aidevops/cache/session-greeting.txt"
	if [[ -f "$greeting_cache" ]]; then
		if grep -q '\.agent/' "$greeting_cache" 2>/dev/null; then
			sed -i '' 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null ||
				sed -i 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null || true
		fi
	fi

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated .agent -> .agents reference(s)"
	else
		print_info "No .agent -> .agents migration needed"
	fi

	return 0
}

# Remove deprecated MCP entries from opencode.json
# These MCPs have been replaced by curl-based subagents (zero context cost)
cleanup_deprecated_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# MCPs replaced by curl subagents in v2.79.0
	local deprecated_mcps=(
		"hetzner-awardsapp"
		"hetzner-brandlight"
		"hetzner-marcusquinn"
		"hetzner-storagebox"
		"ahrefs"
		"serper"
		"dataforseo"
		"hostinger-api"
		"shadcn"
		"repomix"
	)

	# Tool rules to remove (for MCPs that no longer exist)
	local deprecated_tools=(
		"hetzner-*"
		"hostinger-api_*"
		"ahrefs_*"
		"dataforseo_*"
		"serper_*"
		"shadcn_*"
		"repomix_*"
	)

	local cleaned=0
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	cp "$opencode_config" "$tmp_config"

	for mcp in "${deprecated_mcps[@]}"; do
		if jq -e ".mcp[\"$mcp\"]" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.mcp[\"$mcp\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((cleaned++)) || true
		fi
	done

	for tool in "${deprecated_tools[@]}"; do
		if jq -e ".tools[\"$tool\"]" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.tools[\"$tool\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
		fi
	done

	# Also remove deprecated tool refs from SEO agent
	if jq -e '.agent.SEO.tools["dataforseo_*"]' "$tmp_config" >/dev/null 2>&1; then
		jq 'del(.agent.SEO.tools["dataforseo_*"]) | del(.agent.SEO.tools["serper_*"]) | del(.agent.SEO.tools["ahrefs_*"])' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
	fi

	# Migrate npx/pipx commands to full binary paths (faster startup, PATH-independent)
	# Parallel arrays avoid bash associative array issues with @ in package names
	local -a mcp_pkgs=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
		"analytics-mcp"
	)
	local -a mcp_bins=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"macos-automator-mcp"
		"claude-code-mcp"
		"analytics-mcp"
	)

	local i
	for i in "${!mcp_pkgs[@]}"; do
		local pkg="${mcp_pkgs[$i]}"
		local bin_name="${mcp_bins[$i]}"
		# Find MCP key using npx/bunx/pipx for this package (single query)
		local mcp_key
		mcp_key=$(jq -r --arg pkg "$pkg" '.mcp | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' "$tmp_config" 2>/dev/null | head -1)

		if [[ -n "$mcp_key" ]]; then
			# Resolve full path for the binary
			local full_path
			full_path=$(resolve_mcp_binary_path "$bin_name")
			if [[ -n "$full_path" ]]; then
				jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command = [$p]' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((cleaned++)) || true
			fi
		fi
	done

	# Migrate outscraper from bash -c wrapper to full binary path
	if jq -e '.mcp.outscraper.command | join(" ") | test("bash.*outscraper")' "$tmp_config" >/dev/null 2>&1; then
		local outscraper_path
		outscraper_path=$(resolve_mcp_binary_path "outscraper-mcp-server")
		if [[ -n "$outscraper_path" ]]; then
			# Source the API key and set it in environment
			local outscraper_key=""
			if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
				# shellcheck source=/dev/null
				outscraper_key=$(source "$HOME/.config/aidevops/credentials.sh" && echo "${OUTSCRAPER_API_KEY:-}")
			fi
			jq --arg p "$outscraper_path" --arg key "$outscraper_key" '.mcp.outscraper.command = [$p] | .mcp.outscraper.environment = {"OUTSCRAPER_API_KEY": $key}' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((cleaned++)) || true
		fi
	fi

	if [[ $cleaned -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_info "Updated $cleaned MCP entry/entries in opencode.json (using full binary paths)"
	else
		rm -f "$tmp_config"
	fi

	# Always resolve bare binary names to full paths (fixes PATH-dependent startup)
	update_mcp_paths_in_opencode

	return 0
}

# Disable MCPs globally that should only be enabled on-demand via subagents
# This reduces session startup context by disabling rarely-used MCPs
# - playwriter: ~3K tokens - enable via @playwriter subagent
# - augment-context-engine: ~1K tokens - enable via @augment-context-engine subagent
# - gh_grep: ~600 tokens - replaced by @github-search subagent (uses rg/bash)
# - google-analytics-mcp: ~800 tokens - enable via @google-analytics subagent
# - context7: ~800 tokens - enable via @context7 subagent (for library docs lookup)
disable_ondemand_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# MCPs to disable globally (these have subagent alternatives or are unused)
	# Note: use exact MCP key names from opencode.json
	local -a ondemand_mcps=(
		"playwriter"
		"augment-context-engine"
		"gh_grep"
		"google-analytics-mcp"
		"grep_app"
		"websearch"
		# KEEP ENABLED: osgrep (semantic code search), context7 (library docs)
	)

	local disabled=0
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	cp "$opencode_config" "$tmp_config"

	for mcp in "${ondemand_mcps[@]}"; do
		# Only disable MCPs that exist in the config
		# Don't add fake entries - they break OpenCode's config validation
		if jq -e ".mcp[\"$mcp\"]" "$tmp_config" >/dev/null 2>&1; then
			local current_enabled
			current_enabled=$(jq -r ".mcp[\"$mcp\"].enabled // \"true\"" "$tmp_config")
			if [[ "$current_enabled" != "false" ]]; then
				jq ".mcp[\"$mcp\"].enabled = false" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((disabled++)) || true
			fi
		fi
	done

	# Remove invalid MCP entries added by v2.100.16 bug
	# These have type "stdio" (invalid - only "local" or "remote" are valid)
	# or command ["echo", "disabled"] which breaks OpenCode
	local invalid_mcps=("grep_app" "websearch" "context7" "augment-context-engine")
	for mcp in "${invalid_mcps[@]}"; do
		# Check for invalid type "stdio" or dummy command
		if jq -e ".mcp[\"$mcp\"].type == \"stdio\" or .mcp[\"$mcp\"].command[0] == \"echo\"" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.mcp[\"$mcp\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			print_info "Removed invalid MCP entry: $mcp"
			disabled=1 # Mark as changed
		fi
	done

	# Re-enable MCPs that were accidentally disabled (v2.100.16-17 bug)
	local -a keep_enabled=("osgrep" "context7")
	for mcp in "${keep_enabled[@]}"; do
		if jq -e ".mcp[\"$mcp\"].enabled == false" "$tmp_config" >/dev/null 2>&1; then
			jq ".mcp[\"$mcp\"].enabled = true" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			print_info "Re-enabled $mcp MCP"
			disabled=1 # Mark as changed
		fi
	done

	if [[ $disabled -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_info "Disabled $disabled MCP(s) globally (use subagents to enable on-demand)"
	else
		rm -f "$tmp_config"
	fi

	return 0
}

# Validate and repair OpenCode config schema
# Fixes common issues from manual editing or AI-generated configs:
# - MCP entries missing "type": "local" field
# - tools entries as objects {} instead of booleans
# If invalid, backs up and regenerates using the generator script
validate_opencode_config() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local needs_repair=false
	local issues=""

	# Check 0: Remove deprecated top-level keys that OpenCode no longer recognizes
	# "compaction" was removed in OpenCode v1.1.x - causes "Unrecognized key" error
	local deprecated_keys=("compaction")
	for key in "${deprecated_keys[@]}"; do
		if jq -e ".[\"$key\"]" "$opencode_config" >/dev/null 2>&1; then
			local tmp_fix
			tmp_fix=$(mktemp)
			trap 'rm -f "${tmp_fix:-}"' RETURN
			if jq "del(.[\"$key\"])" "$opencode_config" >"$tmp_fix" 2>/dev/null; then
				create_backup_with_rotation "$opencode_config" "opencode"
				mv "$tmp_fix" "$opencode_config"
				print_info "Removed deprecated '$key' key from OpenCode config"
			else
				rm -f "$tmp_fix"
			fi
		fi
	done

	# Check 1: MCP entries must have "type" field (usually "local")
	# Invalid: {"mcp": {"foo": {"command": "..."}}}
	# Valid:   {"mcp": {"foo": {"type": "local", "command": "..."}}}
	local mcps_without_type
	mcps_without_type=$(jq -r '.mcp // {} | to_entries[] | select(.value.type == null and .value.command != null) | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$mcps_without_type" ]]; then
		needs_repair=true
		issues="${issues}\n  - MCP entries missing 'type' field: $(echo "$mcps_without_type" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 2: tools entries must be booleans, not objects
	# Invalid: {"tools": {"gh_grep": {}}}
	# Valid:   {"tools": {"gh_grep": true}}
	local tools_as_objects
	tools_as_objects=$(jq -r '.tools // {} | to_entries[] | select(.value | type == "object") | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$tools_as_objects" ]]; then
		needs_repair=true
		issues="${issues}\n  - tools entries as objects instead of booleans: $(echo "$tools_as_objects" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 3: Try to parse with opencode (if available) to catch other schema issues
	if command -v opencode &>/dev/null; then
		local validation_output
		if ! validation_output=$(opencode --version 2>&1); then
			# If opencode fails to start, config might be invalid
			if echo "$validation_output" | grep -q "Configuration is invalid"; then
				needs_repair=true
				issues="${issues}\n  - OpenCode reports invalid configuration"
			fi
		fi
	fi

	if [[ "$needs_repair" == "true" ]]; then
		print_warning "OpenCode config has schema issues:$issues"

		# Backup the invalid config
		create_backup_with_rotation "$opencode_config" "opencode"
		print_info "Backed up invalid config"

		# Remove the invalid config so generator creates fresh one
		rm -f "$opencode_config"

		# Regenerate using the generator script
		local generator_script="$HOME/.aidevops/agents/scripts/generate-opencode-agents.sh"
		if [[ -x "$generator_script" ]]; then
			print_info "Regenerating OpenCode config with correct schema..."
			if "$generator_script" >/dev/null 2>&1; then
				print_success "OpenCode config regenerated successfully"
			else
				print_warning "Config regeneration failed - run manually: $generator_script"
			fi
		else
			print_warning "Generator script not found - run setup.sh again after agents are deployed"
		fi
	fi

	return 0
}

# Migrate mcp-env.sh to credentials.sh (v2.105.0)
# Renames the credential file and creates backward-compatible symlink
migrate_mcp_env_to_credentials() {
	local config_dir="$HOME/.config/aidevops"
	local old_file="$config_dir/mcp-env.sh"
	local new_file="$config_dir/credentials.sh"
	local migrated=0

	# Migrate root-level mcp-env.sh -> credentials.sh
	if [[ -f "$old_file" && ! -L "$old_file" ]]; then
		if [[ ! -f "$new_file" ]]; then
			mv "$old_file" "$new_file"
			chmod 600 "$new_file"
			((migrated++)) || true
			print_info "Renamed mcp-env.sh to credentials.sh"
		fi
		# Create backward-compatible symlink
		if [[ ! -L "$old_file" ]]; then
			ln -sf "credentials.sh" "$old_file"
			print_info "Created symlink mcp-env.sh -> credentials.sh"
		fi
	fi

	# Migrate tenant-level mcp-env.sh -> credentials.sh
	local tenants_dir="$config_dir/tenants"
	if [[ -d "$tenants_dir" ]]; then
		for tenant_dir in "$tenants_dir"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local tenant_old="$tenant_dir/mcp-env.sh"
			local tenant_new="$tenant_dir/credentials.sh"
			if [[ -f "$tenant_old" && ! -L "$tenant_old" ]]; then
				if [[ ! -f "$tenant_new" ]]; then
					mv "$tenant_old" "$tenant_new"
					chmod 600 "$tenant_new"
					((migrated++)) || true
				fi
				if [[ ! -L "$tenant_old" ]]; then
					ln -sf "credentials.sh" "$tenant_old"
				fi
			fi
		done
	fi

	# Update shell rc files that source the old path
	for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
		if [[ -f "$rc_file" ]] && grep -q 'source.*mcp-env\.sh' "$rc_file" 2>/dev/null; then
			# shellcheck disable=SC2016
			sed -i '' 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null ||
				sed -i 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null || true
			((migrated++)) || true
			print_info "Updated $rc_file to source credentials.sh"
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated mcp-env.sh -> credentials.sh reference(s)"
	fi

	return 0
}

# Migrate old config-backups to new per-type backup structure
# This runs once to clean up the legacy backup directory
migrate_old_backups() {
	local old_backup_dir="$HOME/.aidevops/config-backups"

	# Skip if old directory doesn't exist
	if [[ ! -d "$old_backup_dir" ]]; then
		return 0
	fi

	# Count old backups
	local old_count
	old_count=$(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')

	if [[ $old_count -eq 0 ]]; then
		# Empty directory, just remove it
		rm -rf "$old_backup_dir"
		return 0
	fi

	print_info "Migrating $old_count old backups to new structure..."

	# Create new backup directories
	mkdir -p "$HOME/.aidevops/agents-backups"
	mkdir -p "$HOME/.aidevops/opencode-backups"

	# Move the most recent backups (up to BACKUP_KEEP_COUNT) to new locations
	# Old backups contained mixed content, so we'll just keep the newest ones as agents backups
	local migrated=0
	for backup in $(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -n "$BACKUP_KEEP_COUNT"); do
		local backup_name
		backup_name=$(basename "$backup")

		# Check if it contains agents folder (most common)
		if [[ -d "$backup/agents" ]]; then
			mv "$backup" "$HOME/.aidevops/agents-backups/$backup_name"
			((migrated++)) || true
		# Check if it contains opencode.json
		elif [[ -f "$backup/opencode.json" ]]; then
			mv "$backup" "$HOME/.aidevops/opencode-backups/$backup_name"
			((migrated++)) || true
		fi
	done

	# Remove remaining old backups and the old directory
	rm -rf "$old_backup_dir"

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated recent backups, removed $((old_count - migrated)) old backups"
	else
		print_info "Cleaned up $old_count old backups"
	fi

	return 0
}

# Migrate loop state from .claude/ to .agents/loop-state/ in user projects
# Also migrates from legacy .agents/loop-state/ to .agents/loop-state/
# The migration is non-destructive: moves files, doesn't delete originals until confirmed
migrate_loop_state_directories() {
	print_info "Checking for legacy loop state directories..."

	local migrated=0
	local git_dirs=()

	# Find Git repositories in common locations
	# Check ~/Git/ and current directory's parent
	for search_dir in "$HOME/Git" "$(dirname "$(pwd)")"; do
		if [[ -d "$search_dir" ]]; then
			while IFS= read -r -d '' git_dir; do
				git_dirs+=("$(dirname "$git_dir")")
			done < <(find "$search_dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
		fi
	done

	for repo_dir in "${git_dirs[@]}"; do
		local old_state_dir="$repo_dir/.claude"
		local legacy_state_dir="$repo_dir/.agent/loop-state"
		local new_state_dir="$repo_dir/.agents/loop-state"

		# Migrate from .claude/ (oldest legacy path)
		if [[ -d "$old_state_dir" ]]; then
			local has_loop_state=false
			if [[ -f "$old_state_dir/ralph-loop.local.state" ]] ||
				[[ -f "$old_state_dir/loop-state.json" ]] ||
				[[ -d "$old_state_dir/receipts" ]]; then
				has_loop_state=true
			fi

			if [[ "$has_loop_state" == "true" ]]; then
				print_info "Found legacy loop state in: $repo_dir/.claude/"
				mkdir -p "$new_state_dir"

				for file in ralph-loop.local.state loop-state.json re-anchor.md guardrails.md; do
					if [[ -f "$old_state_dir/$file" ]]; then
						mv "$old_state_dir/$file" "$new_state_dir/"
						print_info "  Moved $file"
					fi
				done

				if [[ -d "$old_state_dir/receipts" ]]; then
					mv "$old_state_dir/receipts" "$new_state_dir/"
					print_info "  Moved receipts/"
				fi

				local remaining
				remaining=$(find "$old_state_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

				if [[ "$remaining" -eq 0 ]]; then
					rmdir "$old_state_dir" 2>/dev/null && print_info "  Removed empty .claude/"
				else
					print_warning "  .claude/ has other files, not removing"
				fi

				((migrated++)) || true
			fi
		fi

		# Migrate from .agents/loop-state/ (v2.51.0-v2.103.0 path) to .agents/loop-state/
		if [[ -d "$legacy_state_dir" ]] && [[ "$legacy_state_dir" != "$new_state_dir" ]]; then
			print_info "Found legacy loop state in: $repo_dir/.agent/loop-state/"
			mkdir -p "$new_state_dir"

			# Move all files from old to new
			if [[ -n "$(ls -A "$legacy_state_dir" 2>/dev/null)" ]]; then
				cp -R "$legacy_state_dir"/* "$new_state_dir/" 2>/dev/null || true
				rm -rf "$legacy_state_dir"
				print_info "  Migrated .agents/loop-state/ -> .agents/loop-state/"
				((migrated++)) || true
			fi
		fi

		# Update .gitignore if needed
		local gitignore="$repo_dir/.gitignore"
		if [[ -f "$gitignore" ]]; then
			if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
				echo ".agents/loop-state/" >>"$gitignore"
				print_info "  Added .agents/loop-state/ to .gitignore"
			fi
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated loop state in $migrated repositories"
	else
		print_info "No legacy loop state directories found"
	fi

	return 0
}
