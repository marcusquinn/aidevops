#!/usr/bin/env bash
# Plugin functions: deploy_plugins, sanitize_plugin_namespace, generate_agent_skills, create_skill_symlinks, check_skill_updates, scan_imported_skills, multi-tenant
# Part of aidevops setup.sh modularization (t316.3)

sanitize_plugin_namespace() {
	local ns="$1"
	# Strip any path components, keep only the final directory name
	# This prevents ../../../etc/passwd and /absolute/paths
	ns=$(basename "$ns")
	# Additional safety: reject if it starts with . or contains suspicious chars
	if [[ "$ns" =~ ^\.|\.\.|[[:space:]]|[\\/] ]]; then
		return 1
	fi
	# Reject empty result
	if [[ -z "$ns" ]]; then
		return 1
	fi
	echo "$ns"
	return 0
}

deploy_plugins() {
	local target_dir="$1"
	local plugins_file="$2"

	# Skip if no plugins.json or no jq
	if [[ ! -f "$plugins_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found; skipping plugin deployment"
		return 0
	fi

	local plugin_count
	plugin_count=$(jq '.plugins | length' "$plugins_file" 2>/dev/null || echo "0")
	if [[ "$plugin_count" -eq 0 ]]; then
		return 0
	fi

	local enabled_count
	enabled_count=$(jq '[.plugins[] | select(.enabled != false)] | length' "$plugins_file" 2>/dev/null || echo "0")
	if [[ "$enabled_count" -eq 0 ]]; then
		print_info "No enabled plugins to deploy ($plugin_count configured, all disabled)"
		return 0
	fi

	# Remove directories for disabled plugins (cleanup)
	local disabled_ns
	local safe_ns
	while IFS= read -r disabled_ns; do
		[[ -z "$disabled_ns" ]] && continue
		# Sanitize namespace to prevent path traversal
		if ! safe_ns=$(sanitize_plugin_namespace "$disabled_ns"); then
			print_warning "  Skipping invalid plugin namespace: $disabled_ns"
			continue
		fi
		if [[ -d "$target_dir/$safe_ns" ]]; then
			rm -rf "${target_dir:?}/${safe_ns:?}"
			print_info "  Removed disabled plugin directory: $safe_ns"
		fi
	done < <(jq -r '.plugins[] | select(.enabled == false) | .namespace // empty' "$plugins_file" 2>/dev/null)

	print_info "Deploying $enabled_count plugin(s)..."

	local deployed=0
	local failed=0
	local skipped=0

	# Process each enabled plugin
	local safe_pns
	while IFS=$'\t' read -r pname prepo pns pbranch; do
		[[ -z "$pname" ]] && continue
		pbranch="${pbranch:-main}"

		# Sanitize namespace to prevent path traversal
		if ! safe_pns=$(sanitize_plugin_namespace "$pns"); then
			print_warning "  Skipping plugin '$pname' with invalid namespace: $pns"
			failed=$((failed + 1))
			continue
		fi

		local clone_dir="$target_dir/$safe_pns"

		if [[ -d "$clone_dir" ]]; then
			# Plugin directory exists — skip re-clone during setup
			# Users can force update via: aidevops plugin update [name]
			skipped=$((skipped + 1))
			continue
		fi

		# Clone plugin repo
		print_info "  Installing plugin '$pname' ($prepo)..."
		if git clone --branch "$pbranch" --depth 1 "$prepo" "$clone_dir" 2>/dev/null; then
			# Remove .git directory (tracked via plugins.json, not nested git)
			rm -rf "$clone_dir/.git"
			# Set permissions on any scripts
			if [[ -d "$clone_dir/scripts" ]]; then
				chmod +x "$clone_dir/scripts/"*.sh 2>/dev/null || true
			fi
			deployed=$((deployed + 1))
		else
			print_warning "  Failed to install plugin '$pname' (network or auth issue)"
			failed=$((failed + 1))
		fi
	done < <(jq -r '.plugins[] | select(.enabled != false) | [.name, .repo, .namespace, (.branch // "main")] | @tsv' "$plugins_file" 2>/dev/null)

	# Summary
	if [[ "$deployed" -gt 0 ]]; then
		print_success "Deployed $deployed plugin(s)"
	fi
	if [[ "$skipped" -gt 0 ]]; then
		print_info "$skipped plugin(s) already deployed (use 'aidevops plugin update' to refresh)"
	fi
	if [[ "$failed" -gt 0 ]]; then
		print_warning "$failed plugin(s) failed to deploy (non-blocking)"
	fi

	return 0
}

generate_agent_skills() {
	print_info "Generating Agent Skills SKILL.md files..."

	local skills_script="$HOME/.aidevops/agents/scripts/generate-skills.sh"

	if [[ -f "$skills_script" ]]; then
		if bash "$skills_script" 2>/dev/null; then
			print_success "Agent Skills SKILL.md files generated"
		else
			print_warning "Agent Skills generation encountered issues (non-critical)"
		fi
	else
		print_warning "Agent Skills generator not found at $skills_script"
	fi

	return 0
}

create_skill_symlinks() {
	print_info "Creating symlinks for imported skills..."

	local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"
	local agents_dir="$HOME/.aidevops/agents"

	# Skip if no skill-sources.json or jq not available
	if [[ ! -f "$skill_sources" ]]; then
		print_info "No imported skills found (skill-sources.json not present)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot create skill symlinks"
		return 0
	fi

	# Check if there are any skills
	local skill_count
	skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to symlink"
		return 0
	fi

	# AI assistant skill directories
	local skill_dirs=(
		"$HOME/.config/opencode/skills"
		"$HOME/.codex/skills"
		"$HOME/.claude/skills"
		"$HOME/.config/amp/tools"
	)

	# Create skill directories if they don't exist
	for dir in "${skill_dirs[@]}"; do
		mkdir -p "$dir" 2>/dev/null || true
	done

	local created_count=0

	# Read each skill and create symlinks
	while IFS= read -r skill_json; do
		local name local_path
		name=$(echo "$skill_json" | jq -r '.name')
		local_path=$(echo "$skill_json" | jq -r '.local_path')

		# Skip if path doesn't exist
		local full_path="$agents_dir/${local_path#.agents/}"
		if [[ ! -f "$full_path" ]]; then
			print_warning "Skill file not found: $full_path"
			continue
		fi

		# Create symlinks in each AI assistant directory
		for skill_dir in "${skill_dirs[@]}"; do
			local target_file

			# Amp expects <name>.md directly, others expect <name>/SKILL.md
			if [[ "$skill_dir" == *"/amp/tools" ]]; then
				target_file="$skill_dir/${name}.md"
			else
				local target_dir="$skill_dir/$name"
				target_file="$target_dir/SKILL.md"
				# Create skill subdirectory
				mkdir -p "$target_dir" 2>/dev/null || continue
			fi

			# Create symlink (remove existing first)
			rm -f "$target_file" 2>/dev/null || true
			if ln -sf "$full_path" "$target_file" 2>/dev/null; then
				((created_count++)) || true
			fi
		done
	done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)

	if [[ $created_count -gt 0 ]]; then
		print_success "Created $created_count skill symlinks across AI assistants"
	else
		print_info "No skill symlinks created"
	fi

	return 0
}

check_skill_updates() {
	print_info "Checking for skill updates..."

	local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"

	# Skip if no skill-sources.json or required tools not available
	if [[ ! -f "$skill_sources" ]]; then
		print_info "No imported skills to check"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not found - cannot check skill updates"
		return 0
	fi

	if ! command -v curl &>/dev/null; then
		print_warning "curl not found - cannot check skill updates"
		return 0
	fi

	local skill_count
	skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to check"
		return 0
	fi

	local updates_available=0
	local update_list=""

	# Check each skill for updates
	while IFS= read -r skill_json; do
		local name upstream_url upstream_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		upstream_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		# Skip skills without upstream URL or commit (e.g., context7 imports)
		if [[ -z "$upstream_url" || "$upstream_url" == "null" ]]; then
			continue
		fi
		if [[ -z "$upstream_commit" ]]; then
			continue
		fi

		# Extract owner/repo from GitHub URL
		local owner_repo
		owner_repo=$(echo "$upstream_url" | sed -E 's|https://github.com/||; s|\.git$||; s|/tree/.*||')

		if [[ -z "$owner_repo" || ! "$owner_repo" =~ / ]]; then
			continue
		fi

		# Get latest commit from GitHub API (silent, with timeout)
		local api_response latest_commit
		api_response=$(curl -s --max-time 5 "https://api.github.com/repos/$owner_repo/commits?per_page=1" 2>/dev/null)

		# Check if response is an array (success) or object (error like rate limit)
		if echo "$api_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
			latest_commit=$(echo "$api_response" | jq -r '.[0].sha // empty')
		else
			# API returned error object, skip this skill
			continue
		fi

		if [[ -n "$latest_commit" && "$latest_commit" != "$upstream_commit" ]]; then
			((updates_available++)) || true
			update_list="${update_list}\n  - $name (${upstream_commit:0:7} → ${latest_commit:0:7})"
		fi
	done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)

	if [[ $updates_available -gt 0 ]]; then
		print_warning "Skill updates available:$update_list"
		print_info "Run: ~/.aidevops/agents/scripts/add-skill-helper.sh check-updates"
		print_info "To update a skill: ~/.aidevops/agents/scripts/add-skill-helper.sh add <url> --force"
	else
		print_success "All imported skills are up to date"
	fi

	return 0
}

scan_imported_skills() {
	print_info "Running security scan on imported skills..."

	local security_helper="$HOME/.aidevops/agents/scripts/security-helper.sh"

	if [[ ! -f "$security_helper" ]]; then
		print_warning "security-helper.sh not found - skipping skill scan"
		return 0
	fi

	# Install skill-scanner if not present
	# Fallback chain: uv -> pipx -> venv+symlink -> pip3 --user (legacy)
	# PEP 668 (Ubuntu 24.04+) blocks pip3 --user, so we try isolated methods first
	if ! command -v skill-scanner &>/dev/null; then
		local installed=false

		# 1. uv tool install (preferred - fast, isolated)
		if [[ "$installed" == "false" ]] && command -v uv &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via uv..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" uv tool install cisco-ai-skill-scanner; then
				print_success "Cisco Skill Scanner installed via uv"
				installed=true
			fi
		fi

		# 2. pipx install (designed for isolated app installs)
		if [[ "$installed" == "false" ]] && command -v pipx &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via pipx..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" pipx install cisco-ai-skill-scanner; then
				print_success "Cisco Skill Scanner installed via pipx"
				installed=true
			fi
		fi

		# 3. venv + symlink (works on PEP 668 systems without uv/pipx)
		if [[ "$installed" == "false" ]] && command -v python3 &>/dev/null; then
			local venv_dir="$HOME/.aidevops/.agent-workspace/work/cisco-scanner-env"
			local bin_dir="$HOME/.local/bin"
			print_info "Installing Cisco Skill Scanner in isolated venv..."
			if python3 -m venv "$venv_dir" 2>/dev/null &&
				"$venv_dir/bin/pip" install cisco-ai-skill-scanner 2>/dev/null; then
				mkdir -p "$bin_dir"
				ln -sf "$venv_dir/bin/skill-scanner" "$bin_dir/skill-scanner"
				print_success "Cisco Skill Scanner installed via venv ($venv_dir)"
				installed=true
			else
				rm -rf "$venv_dir" 2>/dev/null || true
			fi
		fi

		# 4. pip3 --user (legacy fallback, fails on PEP 668 systems)
		if [[ "$installed" == "false" ]] && command -v pip3 &>/dev/null; then
			print_info "Installing Cisco Skill Scanner via pip3 --user..."
			if run_with_spinner "Installing cisco-ai-skill-scanner" pip3 install --user cisco-ai-skill-scanner 2>/dev/null; then
				print_success "Cisco Skill Scanner installed via pip3"
				installed=true
			fi
		fi

		if [[ "$installed" == "false" ]]; then
			print_warning "Failed to install Cisco Skill Scanner - skipping security scan"
			print_info "Install manually with: uv tool install cisco-ai-skill-scanner"
			print_info "Or: pipx install cisco-ai-skill-scanner"
			return 0
		fi
	fi

	if bash "$security_helper" skill-scan all 2>/dev/null; then
		print_success "All imported skills passed security scan"
	else
		print_warning "Some imported skills have security findings - review with: aidevops skill scan"
	fi

	return 0
}

setup_multi_tenant_credentials() {
	print_info "Multi-tenant credential storage..."

	local credential_helper="$HOME/.aidevops/agents/scripts/credential-helper.sh"

	if [[ ! -f "$credential_helper" ]]; then
		# Try local script if deployed version not available yet
		credential_helper=".agents/scripts/credential-helper.sh"
	fi

	if [[ ! -f "$credential_helper" ]]; then
		print_warning "credential-helper.sh not found - skipping"
		return 0
	fi

	# Check if already initialized
	if [[ -d "$HOME/.config/aidevops/tenants" ]]; then
		local tenant_count
		tenant_count=$(find "$HOME/.config/aidevops/tenants" -maxdepth 1 -type d | wc -l)
		# Subtract 1 for the tenants/ dir itself
		tenant_count=$((tenant_count - 1))
		print_success "Multi-tenant already initialized ($tenant_count tenant(s))"
		bash "$credential_helper" status
		return 0
	fi

	# Check if there are existing credentials to migrate
	if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
		local key_count
		key_count=$(grep -c "^export " "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || echo "0")
		print_info "Found $key_count existing API keys in credentials.sh"
		print_info "Multi-tenant enables managing separate credential sets for:"
		echo "  - Multiple clients (agency/freelance work)"
		echo "  - Multiple environments (production, staging)"
		echo "  - Multiple accounts (personal, work)"
		echo ""
		print_info "Your existing keys will be migrated to a 'default' tenant."
		print_info "Everything continues to work as before - this is non-breaking."
		echo ""

		read -r -p "Enable multi-tenant credential storage? [Y/n]: " enable_mt
		enable_mt=$(echo "$enable_mt" | tr '[:upper:]' '[:lower:]')

		if [[ "$enable_mt" =~ ^[Yy]?$ || "$enable_mt" == "yes" ]]; then
			bash "$credential_helper" init
			print_success "Multi-tenant credential storage enabled"
			echo ""
			print_info "Quick start:"
			echo "  credential-helper.sh create client-name    # Create a tenant"
			echo "  credential-helper.sh switch client-name    # Switch active tenant"
			echo "  credential-helper.sh set KEY val --tenant X  # Add key to tenant"
			echo "  credential-helper.sh status                # Show current state"
		else
			print_info "Skipped. Enable later: credential-helper.sh init"
		fi
	else
		print_info "No existing credentials found. Multi-tenant available when needed."
		print_info "Enable later: credential-helper.sh init"
	fi

	return 0
}

check_tool_updates() {
	print_info "Checking for tool updates..."

	local tool_check_script="$HOME/.aidevops/agents/scripts/tool-version-check.sh"

	if [[ ! -f "$tool_check_script" ]]; then
		# Try local script if deployed version not available yet
		tool_check_script=".agents/scripts/tool-version-check.sh"
	fi

	if [[ ! -f "$tool_check_script" ]]; then
		print_warning "Tool version check script not found - skipping update check"
		return 0
	fi

	# Run the check in quiet mode first to see if there are updates
	# Capture both output and exit code
	local outdated_output
	local check_exit_code
	outdated_output=$(bash "$tool_check_script" --quiet 2>&1) || check_exit_code=$?
	check_exit_code=${check_exit_code:-0}

	# If the script failed, warn and continue
	if [[ $check_exit_code -ne 0 ]]; then
		print_warning "Tool version check encountered an error (exit code: $check_exit_code)"
		print_info "Run 'aidevops update-tools' manually to check for updates"
		return 0
	fi

	if [[ -z "$outdated_output" ]]; then
		print_success "All tools are up to date!"
		return 0
	fi

	# Show what's outdated
	echo ""
	print_warning "Some tools have updates available:"
	echo ""
	bash "$tool_check_script" --quiet
	echo ""

	read -r -p "Update all outdated tools now? [Y/n]: " do_update

	if [[ "$do_update" =~ ^[Yy]?$ || "$do_update" == "Y" ]]; then
		print_info "Updating tools..."
		bash "$tool_check_script" --update
		print_success "Tool updates complete!"
	else
		print_info "Skipped tool updates"
		print_info "Run 'aidevops update-tools' anytime to update tools"
	fi

	return 0
}

