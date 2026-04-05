#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Agent deployment functions: deploy_aidevops_agents, deploy_ai_templates, inject_agents_reference, safety-hooks, beads
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

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
		# 2>/dev/null is intentional: --quiet mode suppresses expected output; all exit
		# codes (0=in-sync, 1=drift, other=error) are handled explicitly below.
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

# _deploy_agents_clean_mode target_dir [preserved_dirs...]
# Removes stale files from target_dir while preserving listed subdirectories.
_deploy_agents_clean_mode() {
	local target_dir="$1"
	shift
	local -a preserved_dirs=("$@")

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
	for pdir in "${preserved_dirs[@]}"; do
		if [[ -d "$tmp_preserve/$pdir" ]]; then
			cp -R "$tmp_preserve/$pdir" "$target_dir/$pdir"
		fi
	done
	rm -rf "$tmp_preserve"
	return 0
}

# _deploy_agents_copy source_dir target_dir [plugin_namespaces...]
# Copies agent files using rsync (preferred) or tar fallback.
# Returns 0 on success, 1 on failure.
_deploy_agents_copy() {
	local source_dir="$1"
	local target_dir="$2"
	shift 2

	local deploy_ok=false
	if command -v rsync &>/dev/null; then
		local -a rsync_excludes=("--exclude=loop-state/" "--exclude=custom/" "--exclude=draft/")
		for pns in "$@"; do
			rsync_excludes+=("--exclude=${pns}/")
		done
		if rsync -a "${rsync_excludes[@]}" "$source_dir/" "$target_dir/"; then
			deploy_ok=true
		fi
	else
		# Fallback: use tar with exclusions to match rsync behavior
		local -a tar_excludes=("--exclude=loop-state" "--exclude=custom" "--exclude=draft")
		for pns in "$@"; do
			tar_excludes+=("--exclude=$pns")
		done
		if (cd "$source_dir" && tar cf - "${tar_excludes[@]}" .) | (cd "$target_dir" && tar xf -); then
			deploy_ok=true
		fi
	fi

	if [[ "$deploy_ok" == "true" ]]; then
		return 0
	fi
	return 1
}

# _inject_plan_reminder target_dir
# Injects the extracted OpenCode plan-reminder into Plan+ if the placeholder is present.
_inject_plan_reminder() {
	local target_dir="$1"
	local plan_reminder="$HOME/.aidevops/cache/opencode-prompts/plan-reminder.txt"
	local plan_plus="$target_dir/plan-plus.md"
	if [[ ! -f "$plan_reminder" || ! -f "$plan_plus" ]]; then
		return 0
	fi
	if ! grep -q "OPENCODE-PLAN-REMINDER-INJECT" "$plan_plus"; then
		return 0
	fi
	local tmp_file in_placeholder
	tmp_file=$(mktemp)
	trap 'rm -f "${tmp_file:-}"' RETURN
	in_placeholder=false
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
	return 0
}

# _deploy_agents_post_copy target_dir repo_dir source_dir plugins_file
# Runs all post-copy steps: permissions, VERSION, advisories, plan-reminder,
# mailbox migration, stale-file migration, and plugin deployment.
_deploy_agents_post_copy() {
	local target_dir="$1"
	local repo_dir="$2"
	local source_dir="$3"
	local plugins_file="$4"

	# Set permissions on scripts (top-level and modularised subdirectories)
	chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true
	find "$target_dir/scripts" -mindepth 2 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

	# Count what was deployed
	local agent_count script_count
	agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
	script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
	print_info "Deployed $agent_count agent files and $script_count scripts"

	# Symlink OpenCode's node_modules into the plugin directory (t1551)
	local oc_node_modules="$HOME/.config/opencode/node_modules"
	local plugin_dir="$target_dir/plugins/opencode-aidevops"
	if [[ -d "$oc_node_modules" && -d "$plugin_dir" ]]; then
		ln -sf "$oc_node_modules" "$plugin_dir/node_modules" 2>/dev/null || true
	fi

	# Copy VERSION file from repo root to deployed agents
	if [[ -f "$repo_dir/VERSION" ]]; then
		if cp "$repo_dir/VERSION" "$target_dir/VERSION"; then
			print_info "Copied VERSION file to deployed agents"
		else
			print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
		fi
	else
		print_warning "VERSION file not found in repo root"
	fi

	# Deploy security advisories (shown in session greeting until dismissed)
	local advisories_source="$source_dir/advisories"
	local advisories_target="$HOME/.aidevops/advisories"
	if [[ -d "$advisories_source" ]]; then
		mkdir -p "$advisories_target"
		local adv_count=0
		for adv_file in "$advisories_source"/*.advisory; do
			[[ -f "$adv_file" ]] || continue
			cp "$adv_file" "$advisories_target/"
			adv_count=$((adv_count + 1))
		done
		if [[ "$adv_count" -gt 0 ]]; then
			print_info "Deployed $adv_count security advisory/advisories"
		fi
	fi

	# Inject extracted OpenCode plan-reminder into Plan+ if available
	_inject_plan_reminder "$target_dir"

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
	return 0
}

# _warn_deployed_script_drift source_dir target_dir
# Compares deployed scripts against canonical source and warns if any differ.
# This catches the case where someone edited ~/.aidevops/agents/scripts/ directly
# (those edits are overwritten by every deploy). Emits a warning listing drifted
# files and the canonical source path to edit instead.
# Non-fatal: always returns 0 so deployment proceeds.
_warn_deployed_script_drift() {
	local source_dir="$1"
	local target_dir="$2"
	local source_scripts="$source_dir/scripts"
	local target_scripts="$target_dir/scripts"

	# Only check if both directories exist and diff is available
	if [[ ! -d "$source_scripts" || ! -d "$target_scripts" ]]; then
		return 0
	fi
	if ! command -v diff &>/dev/null; then
		return 0
	fi

	local -a drifted=()
	local f bn
	for f in "$target_scripts"/*.sh; do
		[[ -f "$f" ]] || continue
		bn=$(basename "$f")
		local src="$source_scripts/$bn"
		if [[ -f "$src" ]] && ! diff -q "$src" "$f" &>/dev/null; then
			drifted+=("$bn")
		fi
	done

	if [[ ${#drifted[@]} -gt 0 ]]; then
		print_warning "Deployed scripts differ from canonical source (local edits will be overwritten):"
		for bn in "${drifted[@]}"; do
			print_warning "  $target_scripts/$bn"
			print_warning "    → canonical: $source_scripts/$bn"
		done
		print_warning "To preserve changes: edit the canonical source and re-run setup.sh --non-interactive"
	fi
	return 0
}

deploy_aidevops_agents() {
	print_info "Deploying aidevops agents to ~/.aidevops/agents/..."

	# Use INSTALL_DIR (set by setup.sh) — BASH_SOURCE[0] points to setup-modules/
	# which is not the repo root, so we can't derive .agents/ from it
	local repo_dir="${INSTALL_DIR:?INSTALL_DIR must be set by setup.sh}"
	local source_dir="$repo_dir/.agents"
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
		local ns safe_ns
		while IFS= read -r ns; do
			if [[ -n "$ns" ]] && safe_ns=$(sanitize_plugin_namespace "$ns" 2>/dev/null); then
				plugin_namespaces+=("$safe_ns")
			fi
		done < <(jq -r '.plugins[].namespace // empty' "$plugins_file" 2>/dev/null)
	fi

	# Warn if deployed scripts have been locally modified (GH#17414).
	# These edits will be overwritten — users must edit the canonical source.
	if [[ -d "$target_dir" ]]; then
		_warn_deployed_script_drift "$source_dir" "$target_dir"
	fi

	# Create backup if target exists (with rotation)
	if [[ -d "$target_dir" ]]; then
		create_backup_with_rotation "$target_dir" "agents"
	fi

	# Create target directory
	mkdir -p "$target_dir"

	# Atomic deploy: build a staging directory, then swap it into place.
	# Previously, clean + copy happened in-place, creating a window where
	# scripts were missing. The pulse could dispatch workers mid-deploy,
	# hitting "No such file or directory" errors. Now we:
	#   1. rsync into a staging dir (target_dir.staging)
	#   2. Move preserved dirs (custom/, draft/, plugins) from live to staging
	#   3. mv live → .old, mv staging → live (atomic on same filesystem)
	#   4. rm .old
	local staging_dir="${target_dir}.staging"
	local old_dir="${target_dir}.old"
	rm -rf "$staging_dir" "$old_dir"
	mkdir -p "$staging_dir"

	# Copy source into staging
	local copy_rc
	if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
		_deploy_agents_copy "$source_dir" "$staging_dir" "${plugin_namespaces[@]}"
		copy_rc=$?
	else
		_deploy_agents_copy "$source_dir" "$staging_dir"
		copy_rc=$?
	fi
	if [[ "$copy_rc" -ne 0 ]]; then
		print_error "Failed to deploy agents to staging directory"
		rm -rf "$staging_dir"
		return 1
	fi

	# Carry over preserved directories from live target to staging
	local -a preserved_dirs=("custom" "draft")
	if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
		for pns in "${plugin_namespaces[@]}"; do
			preserved_dirs+=("$pns")
		done
	fi
	for pdir in "${preserved_dirs[@]}"; do
		if [[ -d "$target_dir/$pdir" ]]; then
			# Move user dirs into staging so they survive the swap
			cp -a "$target_dir/$pdir" "$staging_dir/$pdir" 2>/dev/null || true
		fi
	done

	# Atomic swap: mv is atomic on the same filesystem (POSIX rename())
	if [[ -d "$target_dir" ]]; then
		mv "$target_dir" "$old_dir"
	fi
	mv "$staging_dir" "$target_dir"
	rm -rf "$old_dir"

	print_success "Deployed agents to $target_dir"
	_deploy_agents_post_copy "$target_dir" "$repo_dir" "$source_dir" "$plugins_file"

	return 0
}

inject_agents_reference() {
	print_info "Adding aidevops reference to AI assistant configurations..."

	# Delegate to prompt-injection-adapter.sh (t1665.3) which handles all runtimes.
	# The adapter deploys AGENTS.md references via each runtime's native mechanism:
	# OpenCode (json-instructions), Claude (AGENTS.md autodiscovery), Codex, Cursor,
	# Droid, Gemini, Windsurf, Continue, Kilo, Kiro, Aider.
	local adapter_script="${INSTALL_DIR}/.agents/scripts/prompt-injection-adapter.sh"

	if [[ -f "$adapter_script" ]]; then
		# shellcheck source=/dev/null
		source "$adapter_script"
		deploy_prompts_for_all_runtimes
	else
		# Fallback: adapter not yet deployed — use legacy inline logic
		# This path is only hit during initial setup before .agents/ is deployed.
		print_warning "prompt-injection-adapter.sh not found — using legacy deployment"
		_inject_agents_reference_legacy
	fi

	return 0
}

# Legacy fallback for inject_agents_reference — used only when the adapter
# script is not yet available (e.g., during initial setup before .agents/ deploy).
# Will be removed once t1665 migration is complete.
_inject_agents_reference_legacy() {
	local reference_line='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'

	# AI assistant agent directories - these receive AGENTS.md reference
	local ai_agent_dirs=(
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
			mkdir -p "$agents_dir"

			if [[ -f "$agents_file" ]]; then
				local first_line
				first_line=$(head -1 "$agents_file" 2>/dev/null || echo "")
				if [[ "$first_line" != *"aidevops/agents/AGENTS.md"* ]]; then
					local temp_file
					temp_file=$(mktemp)
					trap 'rm -f "${temp_file:-}"' RETURN
					echo "$reference_line" >"$temp_file"
					echo "" >>"$temp_file"
					cat "$agents_file" >>"$temp_file"
					mv "$temp_file" "$agents_file"
					print_success "Added reference to $agents_file"
					((++updated_count))
				else
					print_info "Reference already exists in $agents_file"
				fi
			else
				echo "$reference_line" >"$agents_file"
				print_success "Created $agents_file with aidevops reference"
				((++updated_count))
			fi
		fi
	done

	if [[ $updated_count -eq 0 ]]; then
		print_info "No AI assistant configs found to update (tools may not be installed yet)"
	else
		print_success "Updated $updated_count AI assistant configuration(s)"
	fi

	# Clean up stale AGENTS.md from OpenCode agent dir
	rm -f "$HOME/.config/opencode/agent/AGENTS.md"

	# Deploy OpenCode config-level AGENTS.md from managed template
	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_config_agents="$opencode_config_dir/AGENTS.md"
	local template_source="$INSTALL_DIR/templates/opencode-config-agents.md"

	if [[ -d "$opencode_config_dir" && -f "$template_source" ]]; then
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

	# Deploy Codex instructions.md (Codex reads ~/.codex/instructions.md as system prompt)
	_deploy_codex_instructions

	# Deploy Cursor AGENTS.md (Cursor reads ~/.cursor/rules/*.md as context)
	_deploy_cursor_agents_reference

	# Deploy Droid AGENTS.md (Droid reads ~/.factory/skills/*.md as context)
	_deploy_droid_agents_reference

	return 0
}

# Deploy instructions.md to Codex config directory.
# Codex reads ~/.codex/instructions.md as its system-level instructions.
_deploy_codex_instructions() {
	local codex_dir="$HOME/.codex"
	local instructions_file="$codex_dir/instructions.md"

	# Only deploy if Codex is installed or config dir exists
	if [[ ! -d "$codex_dir" ]] && ! command -v codex >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$codex_dir"

	local reference_content
	reference_content="Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities."

	if [[ -f "$instructions_file" ]]; then
		# Check if our reference is already present
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$instructions_file" 2>/dev/null; then
			print_info "Codex instructions.md already has aidevops reference"
			return 0
		fi
		# Prepend reference to existing instructions
		local temp_file
		temp_file=$(mktemp)
		echo "$reference_content" >"$temp_file"
		echo "" >>"$temp_file"
		cat "$instructions_file" >>"$temp_file"
		mv "$temp_file" "$instructions_file"
		print_success "Added aidevops reference to $instructions_file"
	else
		echo "$reference_content" >"$instructions_file"
		print_success "Created $instructions_file with aidevops reference"
	fi
	return 0
}

# Deploy AGENTS.md reference to Cursor rules directory.
# Cursor reads ~/.cursor/rules/*.md files as additional context.
_deploy_cursor_agents_reference() {
	local cursor_dir="$HOME/.cursor"
	local rules_dir="$cursor_dir/rules"
	local agents_file="$rules_dir/aidevops.md"

	# Only deploy if Cursor is installed or config dir exists
	if [[ ! -d "$cursor_dir" ]] && ! command -v cursor >/dev/null 2>&1 && ! command -v agent >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$rules_dir"

	local reference_content
	reference_content="Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities."

	if [[ -f "$agents_file" ]]; then
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$agents_file" 2>/dev/null; then
			print_info "Cursor rules/aidevops.md already has aidevops reference"
			return 0
		fi
	fi

	echo "$reference_content" >"$agents_file"
	print_success "Deployed aidevops reference to $agents_file"
	return 0
}

# Deploy AGENTS.md reference to Droid skills directory.
# Droid reads ~/.factory/skills/*.md files as additional context.
_deploy_droid_agents_reference() {
	local factory_dir="$HOME/.factory"
	local skills_dir="$factory_dir/skills"
	local agents_file="$skills_dir/aidevops.md"

	# Only deploy if Droid is installed or config dir exists
	if [[ ! -d "$factory_dir" ]] && ! command -v droid >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$skills_dir"

	local reference_content
	reference_content="Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities."

	if [[ -f "$agents_file" ]]; then
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$agents_file" 2>/dev/null; then
			print_info "Droid skills/aidevops.md already has aidevops reference"
			return 0
		fi
	fi

	echo "$reference_content" >"$agents_file"
	print_success "Deployed aidevops reference to $agents_file"
	return 0
}

# =============================================================================
# Deploy aidevops main agents to runtime-native agent directories
# =============================================================================
# Converts aidevops agents from ~/.aidevops/agents/*.md into each runtime's
# native agent format and copies them to the runtime's agent directory.
# Only deploys to installed runtimes that support agent directories.
#
# aidevops frontmatter fields stripped (not understood by target runtimes):
#   mode, subagents
#
# Kept/mapped fields (compatible with Claude Code, Cursor, Amp):
#   name, description, tools, model, permissionMode, hooks, mcpServers,
#   maxTurns, initialPrompt, memory, background, isolation

# _convert_agent_frontmatter: strips aidevops-only fields from agent markdown.
# Reads from stdin, writes converted content to stdout.
# Tracks whether we're inside an indented block (subagents list) to correctly
# skip its child lines without stripping other indented YAML fields.
_convert_agent_frontmatter() {
	local in_frontmatter=false
	local frontmatter_started=false
	local in_skip_block=false
	local line_num=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ $line_num -eq 1 && "$line" == "---" ]]; then
			in_frontmatter=true
			frontmatter_started=true
			echo "$line"
			continue
		fi
		if [[ "$frontmatter_started" == "true" && "$in_frontmatter" == "true" && "$line" == "---" ]]; then
			in_frontmatter=false
			echo "$line"
			continue
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			# Detect top-level keys (no leading whitespace)
			case "$line" in
			mode:*)
				in_skip_block=false
				continue
				;;
			subagents:*)
				in_skip_block=true
				continue
				;;
			esac
			# If inside a skipped block, consume indented continuation lines
			if [[ "$in_skip_block" == "true" ]]; then
				case "$line" in
				[[:space:]]*)
					# Indented line under a skipped key — skip it
					continue
					;;
				*)
					# Non-indented line — we've left the skip block
					in_skip_block=false
					echo "$line"
					;;
				esac
			else
				echo "$line"
			fi
		else
			echo "$line"
		fi
	done
	return 0
}

# _is_agent_definition: check if a markdown file has agent frontmatter (name: field).
# Returns 0 if the file is an agent definition, 1 otherwise.
_is_agent_definition() {
	local file="$1"
	# Check first 30 lines for name: in YAML frontmatter (fast path)
	head -30 "$file" 2>/dev/null | grep -q '^name:' 2>/dev/null
	return $?
}

# _agent_source_dirs: list directories under agents_source that contain subagents.
# Excludes framework infrastructure directories that are not agent definitions.
# Prints directory paths, one per line.
_agent_source_dirs() {
	local agents_source="$1"
	local dir
	for dir in "$agents_source"/*/; do
		[[ -d "$dir" ]] || continue
		local dirname
		dirname=$(basename "$dir")
		# Skip framework infrastructure directories
		case "$dirname" in
		scripts | reference | prompts | templates | configs | hooks | \
			plugins | bundles | loop-state | advisories | aidevops | \
			custom | draft | tests | rules)
			continue
			;;
		*)
			echo "$dir"
			;;
		esac
	done
	return 0
}

# _collect_agent_files: print "abspath|relpath" lines for all deployable agent files
# under agents_source. Excludes AGENTS.md, SKILL.md stubs, and non-agent markdown.
# Output is consumed by deploy_agents_to_runtimes via a process substitution.
_collect_agent_files() {
	local agents_source="$1"
	local f bn

	# Top-level agents
	for f in "$agents_source"/*.md; do
		[[ -f "$f" ]] || continue
		bn=$(basename "$f")
		[[ "$bn" == "AGENTS.md" ]] && continue
		if _is_agent_definition "$f"; then
			printf '%s|%s\n' "$f" "$bn"
		fi
	done

	# Subagent directories (recursive)
	local subdir
	while IFS= read -r subdir; do
		while IFS= read -r f; do
			[[ -f "$f" ]] || continue
			bn=$(basename "$f")
			# Skip SKILL.md stubs — they're directory indexes, not real agents
			[[ "$bn" == "SKILL.md" ]] && continue
			if _is_agent_definition "$f"; then
				local relpath="${f#"$agents_source"/}"
				printf '%s|%s\n' "$f" "$relpath"
			fi
		done < <(find "$subdir" -name '*.md' -type f 2>/dev/null)
	done < <(_agent_source_dirs "$agents_source")
	return 0
}

# _deploy_agents_to_single_runtime: convert and copy all agent files to one runtime.
# Arguments: runtime_id agent_dir agent_list_file
# agent_list_file contains "abspath|relpath" lines produced by _collect_agent_files.
# Prints the count of successfully deployed agents to stdout.
_deploy_agents_to_single_runtime() {
	local runtime_id="$1"
	local agent_dir="$2"
	local agent_list_file="$3"

	# Only deploy if the runtime is actually installed
	local binary config_path config_dir
	binary=$(rt_binary "$runtime_id")
	config_path=$(rt_config_path "$runtime_id")
	config_dir="$(dirname "$config_path" 2>/dev/null)"

	if ! type -P "$binary" >/dev/null 2>&1 && [[ ! -d "$config_dir" ]]; then
		echo "0"
		return 0
	fi

	mkdir -p "$agent_dir"
	local agent_count=0
	local src rel target target_parent

	while IFS='|' read -r src rel; do
		[[ -n "$src" && -n "$rel" ]] || continue
		target="$agent_dir/$rel"
		target_parent=$(dirname "$target")
		[[ -d "$target_parent" ]] || mkdir -p "$target_parent"
		if _convert_agent_frontmatter <"$src" >"$target"; then
			agent_count=$((agent_count + 1))
		fi
	done <"$agent_list_file"

	echo "$agent_count"
	return 0
}

# deploy_agents_to_runtimes: main entry point called by setup.sh.
# Iterates all installed runtimes with agent directory support, converts and
# deploys aidevops agents (top-level and subagent directories) to each runtime's
# native agent directory. Only files with name: frontmatter are deployed.
# SKILL.md stubs (directory indexes) are excluded.
deploy_agents_to_runtimes() {
	# Source runtime registry if not already loaded
	local registry_script="${INSTALL_DIR:-.}/.agents/scripts/runtime-registry.sh"
	if [[ -z "${_RUNTIME_REGISTRY_LOADED:-}" ]]; then
		if [[ -f "$registry_script" ]]; then
			# shellcheck source=/dev/null
			source "$registry_script"
		else
			print_warning "Runtime registry not found — skipping agent deployment to runtimes"
			return 0
		fi
	fi

	local agents_source="${HOME}/.aidevops/agents"
	if [[ ! -d "$agents_source" ]]; then
		print_warning "No deployed agents found at $agents_source — skipping"
		return 0
	fi

	# Build the agent file list once (shared across all runtimes) into a temp file.
	# Each line: "abspath|relpath"
	local agent_list_file
	agent_list_file=$(mktemp)
	trap 'rm -f "${agent_list_file:-}"' RETURN
	_collect_agent_files "$agents_source" >"$agent_list_file"

	local total_agents
	total_agents=$(wc -l <"$agent_list_file" | tr -d ' ')
	if [[ "$total_agents" -eq 0 ]]; then
		print_warning "No agent definitions found in $agents_source"
		return 0
	fi

	local deployed_count=0
	local runtime_count=0

	# Deploy to each installed runtime
	local runtime_id agent_dir agent_count display_name
	while IFS= read -r runtime_id; do
		agent_dir=$(rt_agent_dir "$runtime_id")
		[[ -z "$agent_dir" ]] && continue

		agent_count=$(_deploy_agents_to_single_runtime "$runtime_id" "$agent_dir" "$agent_list_file")
		# A count of 0 means runtime not installed (skipped) — don't increment runtime_count
		if [[ "$agent_count" -gt 0 ]]; then
			display_name=$(rt_display_name "$runtime_id")
			print_info "Deployed $agent_count agents to $display_name ($agent_dir)"
			deployed_count=$((deployed_count + agent_count))
			runtime_count=$((runtime_count + 1))
		fi
	done < <(rt_list_with_agents)

	if [[ $runtime_count -eq 0 ]]; then
		print_info "No runtimes with agent directory support detected — skipping"
	else
		print_success "Deployed $deployed_count agent(s) across $runtime_count runtime(s)"
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
	# shellcheck disable=SC2064  # Intentional: $tmp_dir must expand at trap definition time, not execution time
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
			if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
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

# _install_bv_tool: install the bv (beads_viewer) TUI tool.
# Returns 0 if installed, 1 if skipped or failed.
_install_bv_tool() {
	setup_prompt install_viewer "  Install bv (TUI with PageRank, critical path, graph analytics)? [Y/n]: " "Y"
	if [[ ! "$install_viewer" =~ ^[Yy]?$ ]]; then
		print_info "Install later:"
		print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
		print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
		return 1
	fi
	if command -v brew &>/dev/null; then
		if run_with_spinner "Installing bv via Homebrew" brew install dicklesworthstone/tap/bv; then
			print_info "Run: bv (in a beads-enabled project)"
			return 0
		else
			print_warning "Homebrew install failed - try manually:"
			print_info "  brew install dicklesworthstone/tap/bv"
			return 1
		fi
	elif command -v go &>/dev/null; then
		if run_with_spinner "Installing bv via Go" go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest; then
			print_info "Run: bv (in a beads-enabled project)"
			return 0
		else
			print_warning "Go install failed"
			return 1
		fi
	else
		# Offer verified install script (download-then-execute, not piped)
		setup_prompt use_script "  Install bv via install script? [Y/n]: " "Y"
		if [[ "$use_script" =~ ^[Yy]?$ ]]; then
			if verified_install "bv (beads viewer)" "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh"; then
				print_info "Run: bv (in a beads-enabled project)"
				return 0
			else
				print_warning "Install script failed - try manually:"
				print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
				return 1
			fi
		else
			print_info "Install later:"
			print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
			print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
			return 1
		fi
	fi
}

# _install_beads_node_tools: install beads-ui and bdui via npm.
# Echoes the count of tools installed to stdout.
# All informational output (spinner, status) goes to stderr so that
# command-substitution callers receive only the numeric count.
_install_beads_node_tools() {
	local count=0
	if ! command -v npm &>/dev/null; then
		echo "$count"
		return 0
	fi
	setup_prompt install_web "  Install beads-ui (Web dashboard)? [Y/n]: " "Y"
	if [[ "$install_web" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing beads-ui" npm_global_install beads-ui 1>&2; then
			print_info "Run: beads-ui" >&2
			count=$((count + 1))
		fi
	fi
	setup_prompt install_bdui "  Install bdui (React/Ink TUI)? [Y/n]: " "Y"
	if [[ "$install_bdui" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing bdui" npm_global_install bdui 1>&2; then
			print_info "Run: bdui" >&2
			count=$((count + 1))
		fi
	fi
	echo "$count"
	return 0
}

# _install_perles: install the perles BQL query language TUI via cargo.
# Returns 0 if installed, 1 if skipped or unavailable.
_install_perles() {
	if ! command -v cargo &>/dev/null; then
		return 1
	fi
	setup_prompt install_perles "  Install perles (BQL query language TUI)? [Y/n]: " "Y"
	if [[ ! "$install_perles" =~ ^[Yy]?$ ]]; then
		return 1
	fi
	if run_with_spinner "Installing perles (Rust compile)" cargo install perles; then
		print_info "Run: perles"
		return 0
	fi
	return 1
}

setup_beads_ui() {
	echo ""
	print_info "Beads UI tools provide enhanced visualization:"
	echo "  • bv (Go)            - PageRank, critical path, graph analytics TUI"
	echo "  • beads-ui (Node.js) - Web dashboard with live updates"
	echo "  • bdui (Node.js)     - React/Ink terminal UI"
	echo "  • perles (Rust)      - BQL query language TUI"
	echo ""

	setup_prompt install_beads_ui "Install optional Beads UI tools? [Y/n]: " "Y"

	if [[ ! "$install_beads_ui" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Beads UI tools (can install later from beads.md docs)"
		return 0
	fi

	local installed_count=0

	# bv (beads_viewer) - Go TUI installed via Homebrew
	# https://github.com/Dicklesworthstone/beads_viewer
	if _install_bv_tool; then
		installed_count=$((installed_count + 1))
	fi

	# beads-ui and bdui (Node.js)
	local node_count
	node_count=$(_install_beads_node_tools)
	installed_count=$((installed_count + node_count))

	# perles (Rust)
	if _install_perles; then
		installed_count=$((installed_count + 1))
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
		# Fall back to repo copy (INSTALL_DIR set by setup.sh)
		helper_script="${INSTALL_DIR:-.}/.agents/scripts/install-hooks-helper.sh"
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
