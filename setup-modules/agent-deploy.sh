#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Agent deployment functions: deploy_aidevops_agents, deploy_ai_templates, inject_agents_reference
# Part of aidevops setup.sh modularization (t316.3)
# Split from original agent-deploy.sh (t1940): runtime conversion → agent-runtime.sh, beads/hooks → tool-beads.sh

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'

#######################################
# Restart the pulse process if it's running, so it picks up newly deployed
# scripts. Bash processes source files at startup only — file changes on
# disk don't affect a running process. The pulse is long-lived (hours/days)
# so it would run stale code indefinitely without a restart.
#
# The pulse auto-restarts via launchd/cron, so killing it is safe. If no
# auto-restart mechanism exists, we start it manually.
#######################################
_restart_pulse_if_running() {
	# Anchor the pattern so it only matches the running script, not editors or
	# grep commands that happen to contain "pulse-wrapper.sh" in their argv.
	local pattern="(^|/)pulse-wrapper\\.sh( |$)"

	if ! pgrep -f "$pattern" >/dev/null; then
		# Not running, nothing to do
		return 0
	fi

	local old_pid
	old_pid=$(pgrep -f "$pattern" | tail -1)
	if [[ -z "$old_pid" ]]; then
		return 0
	fi
	print_info "Restarting pulse (PID $old_pid) to load updated scripts..."
	pkill -f "$pattern" || true

	# Wait for it to die
	local wait_count=0
	while pgrep -f "$pattern" >/dev/null && [[ "$wait_count" -lt 10 ]]; do
		sleep 1
		wait_count=$((wait_count + 1))
	done

	# Give launchd/cron a moment to restart it
	sleep 5

	# Check if it auto-restarted with a different PID (guards against false
	# success if the old process failed to terminate).
	if pgrep -f "$pattern" >/dev/null; then
		local new_pid
		new_pid=$(pgrep -f "$pattern" | tail -1)
		if [[ -n "$new_pid" ]] && [[ "$new_pid" != "$old_pid" ]]; then
			print_success "Pulse restarted (new PID $new_pid)"
			return 0
		fi
	fi

	# No auto-restart — start it manually
	local pulse_script="${HOME}/.aidevops/agents/scripts/pulse-wrapper.sh"
	if [[ -x "$pulse_script" ]]; then
		nohup "$pulse_script" >>"${HOME}/.aidevops/logs/pulse-wrapper.log" 2>&1 &
		print_success "Pulse started manually (PID $!)"
	else
		print_warning "Pulse not restarted — $pulse_script not found"
	fi
	return 0
}
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Shared reference line injected into all runtime agent configs
readonly _AIDEVOPS_REFERENCE_LINE='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'

deploy_ai_templates() {
	print_info "Deploying AI assistant templates..."

	if [[ -f "templates/deploy-templates.sh" ]]; then
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
	local extract_script="${INSTALL_DIR:-.}/.agents/scripts/extract-opencode-prompts.sh"
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
	local drift_script="${INSTALL_DIR:-.}/.agents/scripts/opencode-prompt-drift-check.sh"
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

# _resolve_model_tiers_in_frontmatter target_dir
# Resolves tier shorthands (sonnet, haiku, opus, etc.) in YAML frontmatter
# `model:` fields to fully-qualified provider/model IDs using model-routing-table.json.
# This enables runtimes like OpenCode that consume `model:` literally (GH#18043).
# Source .md files keep tier names; deployed files get FQIDs.
# Only processes files with YAML frontmatter (--- delimited) where `model:` contains
# a bare tier name (no `/`). Already-qualified IDs are left unchanged.
_resolve_model_tiers_in_frontmatter() {
	local target_dir="$1"

	# Locate routing tables: merge custom overrides with default
	local default_table="$target_dir/configs/model-routing-table.json"
	local custom_table="$target_dir/custom/configs/model-routing-table.json"

	if [[ ! -f "$default_table" ]]; then
		print_warning "model-routing-table.json not found — skipping frontmatter model resolution"
		return 0
	fi

	# Requires jq for JSON parsing
	if ! command -v jq &>/dev/null; then
		print_warning "jq not available — skipping frontmatter model resolution"
		return 0
	fi

	# Build a sed script file from the routing table(s) in ONE jq call.
	# Custom table overrides specific tiers; default fills in the rest.
	# Each line is a separate sed command for cross-platform compatibility
	# (macOS sed doesn't support ; as command separator inside {}).
	# Generates replacements for both plain and commented forms:
	#   model: sonnet        → model: anthropic/claude-sonnet-4-6
	#   model: sonnet  # ... → model: anthropic/claude-sonnet-4-6  # ...
	local sed_file
	sed_file=$(mktemp "${TMPDIR:-/tmp}/model-resolve-XXXXXX.sed")
	if [[ -f "$custom_table" ]]; then
		# Merge: custom tiers override default tiers (jq * operator)
		jq -r -s '
			(.[0].tiers // {}) * (.[1].tiers // {}) |
			to_entries[] |
			"s|^model: \(.key)$|model: \(.value.models[0])|",
			"s|^model: \(.key)  #|model: \(.value.models[0])  #|"
		' "$default_table" "$custom_table" >"$sed_file" 2>/dev/null
	else
		jq -r '
			.tiers | to_entries[] |
			"s|^model: \(.key)$|model: \(.value.models[0])|",
			"s|^model: \(.key)  #|model: \(.value.models[0])  #|"
		' "$default_table" >"$sed_file" 2>/dev/null
	fi

	if [[ ! -s "$sed_file" ]]; then
		rm -f "$sed_file"
		print_warning "No tiers found in routing table — skipping frontmatter model resolution"
		return 0
	fi

	# Build a grep pattern to find only files with bare tier names.
	# This avoids scanning all 3000+ .md files — only ~60 need changes.
	# Extract tier names from the sed file (each line has the tier name after "model: ")
	local tier_names
	if [[ -f "$custom_table" ]]; then
		tier_names=$(jq -r -s '(.[0].tiers // {}) * (.[1].tiers // {}) | keys[]' "$default_table" "$custom_table" 2>/dev/null | paste -sd'|' -)
	else
		tier_names=$(jq -r '.tiers | keys[]' "$default_table" 2>/dev/null | paste -sd'|' -)
	fi
	if [[ -z "$tier_names" ]]; then
		rm -f "$sed_file"
		return 0
	fi

	# Find candidate files: have a model: line with a bare tier name (no /)
	# grep -rl is fast — scans content without loading full files
	# The || true prevents set -e from exiting when grep finds no matches
	local md_file
	{ grep -rlE "^model: ($tier_names)(\$|  #)" "$target_dir" --include='*.md' 2>/dev/null || true; } | while IFS= read -r md_file; do
		[[ -n "$md_file" ]] || continue
		# Verify the match is in YAML frontmatter (first line is ---)
		local first_line
		first_line=$(head -1 "$md_file" 2>/dev/null) || continue
		[[ "$first_line" == "---" ]] || continue

		# Apply sed replacements from the script file (macOS sed -i '' vs GNU sed -i)
		sed -i '' -f "$sed_file" "$md_file" 2>/dev/null ||
			sed -i -f "$sed_file" "$md_file" 2>/dev/null || true
	done

	# Count remaining unresolved files
	local remaining
	remaining=$({ grep -rlE "^model: ($tier_names)(\$|  #)" "$target_dir" --include='*.md' 2>/dev/null || true; } | wc -l | tr -d ' ')
	if [[ "$remaining" -eq 0 ]]; then
		print_success "Resolved model tiers to FQIDs in deployed agent files (via model-routing-table.json)"
	else
		print_warning "Some model tiers could not be resolved ($remaining files remaining)"
	fi

	rm -f "$sed_file"
	return 0
}

# _set_script_permissions_and_report target_dir
# Sets execute permissions on all deployed scripts and reports deployed counts.
_set_script_permissions_and_report() {
	local target_dir="$1"

	chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true
	find "$target_dir/scripts" -mindepth 2 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

	local agent_count script_count
	agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
	script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
	print_info "Deployed $agent_count agent files and $script_count scripts"
	return 0
}

# _install_opencode_plugin_deps target_dir
# Installs node_modules for the opencode-aidevops plugin.
# GH#17829: @bufbuild/protobuf was missing; GH#17891: only symlink on first run.
# Uses --omit=peer to skip the 630MB opencode-ai peer dep (the host app).
_install_opencode_plugin_deps() {
	local target_dir="$1"
	local oc_node_modules="$HOME/.config/opencode/node_modules"
	local plugin_dir="$target_dir/plugins/opencode-aidevops"

	if [[ ! -d "$plugin_dir" ]]; then
		return 0
	fi

	# Only symlink if node_modules doesn't exist at all (first run)
	if [[ ! -e "$plugin_dir/node_modules" ]]; then
		if [[ -d "$oc_node_modules" ]]; then
			ln -sf "$oc_node_modules" "$plugin_dir/node_modules" 2>/dev/null || true
		fi
	fi

	# Verify critical dependency is available; npm install if not
	if [[ ! -d "$plugin_dir/node_modules/@bufbuild/protobuf" ]]; then
		if command -v npm &>/dev/null; then
			# Remove symlink if present so npm creates a local node_modules
			[[ -L "$plugin_dir/node_modules" ]] && rm "$plugin_dir/node_modules"
			npm install --omit=dev --omit=peer --prefix "$plugin_dir" >/dev/null 2>&1 ||
				print_warning "Failed to install plugin dependencies (non-blocking)"
		fi
	fi
	return 0
}

# _atomic_stage_and_deploy_agents source_dir target_dir [plugin_namespaces...]
# Stages a copy in target_dir.staging, carries over preserved dirs (custom/,
# draft/, and any plugin namespaces), then atomically swaps staging into place.
# Returns 0 on success, 1 on failure.
_atomic_stage_and_deploy_agents() {
	local source_dir="$1"
	local target_dir="$2"
	shift 2
	local -a plugin_namespaces=("$@")

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
			# Copy user dirs into staging so they survive the swap
			cp -a "$target_dir/$pdir" "$staging_dir/$pdir" 2>/dev/null || true
		fi
	done

	# Atomic swap: mv is atomic on the same filesystem (POSIX rename())
	if [[ -d "$target_dir" ]]; then
		mv "$target_dir" "$old_dir"
	fi
	mv "$staging_dir" "$target_dir"
	rm -rf "$old_dir"
	return 0
}

# _deploy_version_file target_dir repo_dir
# Copies VERSION file from repo root to the deployed agents directory.
_deploy_version_file() {
	local target_dir="$1"
	local repo_dir="$2"

	if [[ -f "$repo_dir/VERSION" ]]; then
		if cp "$repo_dir/VERSION" "$target_dir/VERSION"; then
			print_info "Copied VERSION file to deployed agents"
		else
			print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
		fi
	else
		print_warning "VERSION file not found in repo root"
	fi
	return 0
}

# _deploy_security_advisories_files source_dir
# Copies *.advisory files to ~/.aidevops/advisories/ (shown in session greeting).
_deploy_security_advisories_files() {
	local source_dir="$1"
	local advisories_source="$source_dir/advisories"
	local advisories_target="$HOME/.aidevops/advisories"

	if [[ ! -d "$advisories_source" ]]; then
		return 0
	fi
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
	return 0
}

# _migrate_mailbox_if_needed target_dir
# Migrates mailbox from legacy TOON files to SQLite if old files exist.
_migrate_mailbox_if_needed() {
	local target_dir="$1"
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
	return 0
}

# _migrate_wavespeed_md target_dir
# Removes stale wavespeed.md from deprecated services/ai-generation/ path (v2.111+).
_migrate_wavespeed_md() {
	local target_dir="$1"
	local old_wavespeed="$target_dir/services/ai-generation/wavespeed.md"

	if [[ -f "$old_wavespeed" ]]; then
		rm -f "$old_wavespeed"
		rmdir "$target_dir/services/ai-generation" 2>/dev/null || true
		print_info "Migrated wavespeed.md from services/ai-generation/ to tools/video/"
	fi
	return 0
}

# _deploy_agents_post_copy target_dir repo_dir source_dir plugins_file
# Orchestrates all post-copy steps: permissions, VERSION, advisories, plan-reminder,
# mailbox migration, stale-file migration, model resolution, and plugin deployment.
_deploy_agents_post_copy() {
	local target_dir="$1"
	local repo_dir="$2"
	local source_dir="$3"
	local plugins_file="$4"

	_set_script_permissions_and_report "$target_dir"
	_install_opencode_plugin_deps "$target_dir"
	_deploy_version_file "$target_dir" "$repo_dir"
	_deploy_security_advisories_files "$source_dir"
	_inject_plan_reminder "$target_dir"
	_migrate_mailbox_if_needed "$target_dir"
	_migrate_wavespeed_md "$target_dir"
	# Source files keep tier names (sonnet, haiku, opus); deployed files get
	# fully-qualified IDs (anthropic/claude-sonnet-4-6) that runtimes like
	# OpenCode can consume directly (GH#18043).
	_resolve_model_tiers_in_frontmatter "$target_dir"
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
		print_warning "Deployed scripts differ from canonical source (local edits will be overwritten; backup will be created):"
		for bn in "${drifted[@]}"; do
			print_warning "  $target_scripts/$bn"
			print_warning "    → canonical: $source_scripts/$bn"
		done
		print_warning "To keep personal scripts: use $target_dir/custom/scripts/"
		print_warning "To fix the canonical source: edit $source_scripts/ and re-run setup.sh"
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

	mkdir -p "$target_dir"

	# Atomically copy source to staging, carry over user dirs, then swap.
	if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
		_atomic_stage_and_deploy_agents "$source_dir" "$target_dir" "${plugin_namespaces[@]}" || return 1
	else
		_atomic_stage_and_deploy_agents "$source_dir" "$target_dir" || return 1
	fi

	print_success "Deployed agents to $target_dir"
	_deploy_agents_post_copy "$target_dir" "$repo_dir" "$source_dir" "$plugins_file"

	# Restart pulse if running — bash processes load source files at startup
	# and don't re-read them when files change on disk. Without a restart,
	# fixes to pulse-*.sh, dispatch-dedup-*.sh, headless-runtime-*.sh, and
	# other sourced scripts don't take effect until the next manual restart.
	# This was the root cause of a multi-hour outage where deployed fixes
	# were correct but the running pulse kept using old code in memory.
	_restart_pulse_if_running

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
	local reference_line="$_AIDEVOPS_REFERENCE_LINE"

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

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

	if [[ -f "$instructions_file" ]]; then
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

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

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

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

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
