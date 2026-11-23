#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Incremental plans, scoped execution, interactive/non-interactive stages and schedulers.
# Sourced by setup.sh after bootstrap; lock ownership and completion stay there.

[[ -n "${_SETUP_EXECUTION_LOADED:-}" ]] && return 0
_SETUP_EXECUTION_LOADED=1

_setup_ai_session_reset_plan() {
	_SETUP_AI_SESSION_NEEDS_AGENTS=0
	_SETUP_AI_SESSION_NEEDS_CLI=0
	_SETUP_AI_SESSION_NEEDS_HOOKS=0
	_SETUP_AI_SESSION_NEEDS_REPO_VERIFY=0
	_SETUP_AI_SESSION_NEEDS_PULSE=0
	_SETUP_AI_SESSION_NEEDS_SCHEDULERS=0
	_SETUP_AI_SESSION_NEEDS_GUI=0
	_SETUP_AI_SESSION_REQUIRES_FULL=0
	return 0
}

_setup_ai_session_setup_sh_version_only() {
	local deployed_sha="$1"
	local current_sha="$2"
	local diff_output=""
	local line=""
	local payload=""
	local version_prefix=""
	version_prefix="# ""Version:"

	diff_output=$(git -C "$INSTALL_DIR" diff --unified=0 "$deployed_sha" "$current_sha" -- setup.sh 2>/dev/null) || return 1
	while IFS= read -r line; do
		case "$line" in
		"diff --git "* | "index "* | "--- "* | "+++ "* | "@@"*)
			continue
			;;
		+* | -*)
			payload="${line#?}"
			if [[ "$payload" != "$version_prefix "* ]]; then
				return 1
			fi
			;;
		esac
	done <<<"$diff_output"

	return 0
}

_setup_ai_session_plan_file() {
	local filepath="$1"
	local deployed_sha="$2"
	local current_sha="$3"

	case "$filepath" in
	setup.sh)
		if _setup_ai_session_setup_sh_version_only "$deployed_sha" "$current_sha"; then
			print_info "setup.sh drift is release-version metadata only; incremental setup can continue"
		else
			print_warning "setup.sh changed beyond the release-version header; full setup required"
			_SETUP_AI_SESSION_REQUIRES_FULL=1
		fi
		;;
	aidevops.sh)
		_SETUP_AI_SESSION_NEEDS_CLI=1
		;;
	.agents/hooks/*)
		_SETUP_AI_SESSION_NEEDS_HOOKS=1
		[[ "$filepath" == ".agents/hooks/repo-verify-pre-push.sh" ]] && _SETUP_AI_SESSION_NEEDS_REPO_VERIFY=1
		;;
	.agents/scripts/repo-verify-config-lib.sh | .agents/scripts/lint-helper.sh | \
		.agents/scripts/install-pre-push-guards.sh | .agents/configs/repo-verify-defaults.conf | \
		.agents/scripts/aidevops-cli/aidevops-init-lib.sh | .agents/scripts/aidevops-cli/aidevops-update-lib.sh)
		_SETUP_AI_SESSION_NEEDS_REPO_VERIFY=1
		;;
	.agents/scripts/setup/modules/schedulers-pulse.sh)
		_SETUP_AI_SESSION_NEEDS_PULSE=1
		;;
	.agents/scripts/setup/modules/schedulers*.sh | .agents/scripts/setup/_scheduler_runtime.sh | \
		.agents/scripts/runtime-env.sh | .agents/scripts/plist-env-overrides-lib.sh)
		# Shared scheduler modules define non-pulse schedulers too (e.g. the
		# Linux screen-activity sampler); refresh every installed one (GH#36709).
		# runtime-env.sh renders every service PATH (aidevops_service_path), so
		# its changes reach installed units only through this refresh (GH#37888);
		# plist-env-overrides-lib.sh renders the plist env overrides (GH#38661).
		_SETUP_AI_SESSION_NEEDS_SCHEDULERS=1
		;;
	.agents/scripts/setup/modules/agent-deploy.sh | .agents/scripts/setup/modules/plugins.sh)
		:
		;;
	.agents/scripts/setup/*)
		print_warning "Setup implementation changed ($filepath); full setup required"
		_SETUP_AI_SESSION_REQUIRES_FULL=1
		;;
	packages/gui-api/* | packages/gui-desktop/* | packages/gui-shared/* | packages/gui-web/*)
		_SETUP_AI_SESSION_NEEDS_GUI=1
		;;
	esac

	return 0
}

_setup_ai_session_build_plan() {
	local changed_files="$1"
	local deployed_sha="$2"
	local current_sha="$3"
	local filepath=""

	_setup_ai_session_reset_plan
	# Deploying agents is the cheap, atomic baseline: it copies .agents/, writes
	# VERSION, writes .deployed-sha, and restarts pulse asynchronously.
	_SETUP_AI_SESSION_NEEDS_AGENTS=1
	while IFS= read -r filepath; do
		[[ -n "$filepath" ]] || continue
		_setup_ai_session_plan_file "$filepath" "$deployed_sha" "$current_sha"
	done <<<"$changed_files"

	return 0
}

_setup_reconcile_runtime_config() {
	pin_aidevops_active_runtime_bundle_root || {
		print_warning "Runtime configuration reconciliation could not resolve the active agents bundle"
		return 1
	}
	update_runtime_configs || return $?
	deploy_commands_to_all_runtimes || return $?
	return 0
}

_setup_git_checkout_available() {
	local checkout_root="$1"
	local git_dir=""
	local git_common_dir=""

	git_dir=$(git -C "$checkout_root" rev-parse --git-dir 2>/dev/null) || return 1
	git_common_dir=$(git -C "$checkout_root" rev-parse --git-common-dir 2>/dev/null) || return 1
	[[ -n "$git_dir" && -n "$git_common_dir" ]] || return 1
	return 0
}

# _setup_ai_session_verify_deploy <floor_sha>
# floor_sha is the checkout commit when this setup began. Canonical main can
# fast-forward during a multi-minute deploy (t19058: 36 logged convergence
# failures, each rolling back a consistent bundle and repeating the deploy as a
# full setup). Accept the activated bundle's commit when it lies between the
# floor and the current HEAD; the verifier still pins manifest, stamp, VERSION
# and sentinels to that commit. The next update cycle deploys the newer HEAD.
_setup_ai_session_verify_deploy() {
	local floor_sha="$1"
	local expected_sha="$floor_sha"
	local stamp_sha=""
	local _AIDEVOPS_RUNTIME_VERIFY_ALLOW_SOURCE_ADVANCE=1

	stamp_sha=$(tr -d '[:space:]' <"$HOME/.aidevops/.deployed-sha" 2>/dev/null) || stamp_sha=""
	if [[ -n "$stamp_sha" && "$stamp_sha" != "$floor_sha" ]] &&
		git -C "$INSTALL_DIR" merge-base --is-ancestor "$floor_sha" "$stamp_sha" 2>/dev/null; then
		expected_sha="$stamp_sha"
	fi
	verify_aidevops_runtime_bundle_convergence \
		"$INSTALL_DIR" \
		"$expected_sha" \
		"$HOME/.aidevops/agents" \
		"$HOME/.aidevops/.deployed-sha" || {
		_runtime_bundle_rollback "$HOME/.aidevops/agents" ||
			print_error "Failed to roll back the runtime bundle after convergence failure"
		return 1
	}
	if [[ -n "${_AIDEVOPS_RUNTIME_VERIFY_SOURCE_ADVANCED_TO:-}" ]]; then
		print_info "Checkout advanced to ${_AIDEVOPS_RUNTIME_VERIFY_SOURCE_ADVANCED_TO:0:12} during deploy; runtime ${expected_sha:0:12} is consistent and the next update deploys the newer commit"
	fi
	return 0
}

# OpenCode DB archive (daily) and maintenance (weekly) schedulers keep the
# session DB small enough to avoid "database is locked" stalls (GH#35492).
# Both installers are idempotent content-diffs, so every auto-update ensures
# they exist even when the incremental plan would not otherwise touch them.
_setup_ensure_opencode_db_schedulers() {
	_time_step "setup_opencode_db_maintenance" setup_opencode_db_maintenance ||
		print_warning "OpenCode DB maintenance scheduler refresh failed (non-fatal)"
	_time_step "setup_opencode_db_archive" setup_opencode_db_archive ||
		print_warning "OpenCode DB archive scheduler refresh failed (non-fatal)"
	return 0
}

_setup_run_ai_session_incremental() {
	local os="$1"
	local stamp_file="$HOME/.aidevops/.deployed-sha"
	local deployed_sha=""
	local current_sha=""
	local changed_files=""

	# Updates must heal scheduler drift even when no deploy stage changed.
	if [[ "$os" != "Darwin" ]]; then
		_reconcile_linux_scheduler_duplicates
	fi
	print_info "AI-session setup mode: applying changed deploy stages only"
	# Idempotent runtime repair must also run when the deployed SHA is unchanged.
	update_mcp_paths_in_opencode
	if ! _setup_git_checkout_available "$INSTALL_DIR" || [[ ! -f "$stamp_file" ]]; then
		print_warning "AI-session incremental setup needs a git checkout and deployed SHA stamp"
		return 1
	fi

	deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
	current_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || current_sha=""
	if [[ -z "$deployed_sha" || -z "$current_sha" ]]; then
		print_warning "AI-session incremental setup could not resolve deployed/current SHAs"
		return 1
	fi

	if [[ "$deployed_sha" == "$current_sha" ]]; then
		print_success "AI-session setup: deployed SHA already matches current checkout"
		_setup_ensure_opencode_db_schedulers
		_time_step "$SETUP_STAGE_TABBY" setup_tabby
		_setup_ai_session_verify_deploy "$current_sha" || return $?
		return 0
	fi

	changed_files=$(git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$current_sha" 2>/dev/null) || {
		print_warning "AI-session incremental setup could not diff ${deployed_sha:0:7}..${current_sha:0:7}"
		return 1
	}

	_setup_ai_session_build_plan "$changed_files" "$deployed_sha" "$current_sha"
	if [[ "$_SETUP_AI_SESSION_REQUIRES_FULL" -eq 1 ]]; then
		return 1
	fi

	_setup_init_stage_timing_log
	if [[ "$_SETUP_AI_SESSION_NEEDS_AGENTS" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents || return $?
		_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_runtime_plugins || return $?
		_time_step "$SETUP_STAGE_OPENCODE_SERVICE" setup_opencode_service
		_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config || return $?
		_time_step "$SETUP_STAGE_RUNTIME_CONFIG" _setup_reconcile_runtime_config || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_CLI" -eq 1 ]]; then
		_time_step "install_aidevops_cli" install_aidevops_cli || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_HOOKS" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_REPO_VERIFY" -eq 1 ]]; then
		_time_step "setup_repo_verify_guard" setup_repo_verify_guard || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_SCHEDULERS" -eq 1 ]]; then
		# Includes the consent-gated pulse refresh; each step is time-stepped.
		_setup_noninteractive_schedulers "$os"
	elif [[ "$_SETUP_AI_SESSION_NEEDS_PULSE" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os" || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_GUI" -eq 1 ]]; then
		_time_step "setup_gui_desktop_app_opt_in" _setup_offer_gui_desktop_app || return $?
	fi
	# After agent deploy so the schedulers point at the freshly deployed helpers.
	_setup_ensure_opencode_db_schedulers

	_time_step "$SETUP_STAGE_TABBY" setup_tabby
	_setup_ai_session_verify_deploy "$current_sha" || return $?
	print_success "AI-session incremental setup complete (${deployed_sha:0:7}→${current_sha:0:7})"
	return 0
}

_setup_run_scoped_stage() {
	local os="$1"
	local stage
	local current_sha=""
	stage="$(_setup_canonical_stage "$SETUP_STAGE")" || return 1

	if [[ "$stage" == "full" ]]; then
		_setup_run_non_interactive
		_setup_post_setup_steps "$os"
		return 0
	fi

	print_info "Scoped setup mode: running ${stage} only"
	_setup_init_stage_timing_log
	case "$stage" in
	"$SETUP_STAGE_OPENCODE")
		_time_step "$SETUP_STAGE_OPENCODE" setup_opencode_runtimes
		_time_step "$SETUP_STAGE_OPENCODE_SERVICE" setup_opencode_service
		_time_step "setup_opencode_desktop_launcher" setup_opencode_desktop_launcher
		;;
	"$SETUP_STAGE_AGENTS")
		_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents
		_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_runtime_plugins
		_time_step "$SETUP_STAGE_OPENCODE_SERVICE" setup_opencode_service
		_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config
		;;
	"$SETUP_STAGE_RUNTIME_CONFIG")
		_time_step "$SETUP_STAGE_RUNTIME_CONFIG" _setup_reconcile_runtime_config
		;;
	"$SETUP_STAGE_SOURCE_ACCESS")
		if [[ "$SETUP_EXPLICIT_NON_INTERACTIVE" == "true" ]]; then
			_time_step "$SETUP_STAGE_SOURCE_ACCESS" setup_source_access_broker
		else
			AIDEVOPS_SOURCE_ACCESS_INTERACTIVE=true \
				_time_step "$SETUP_STAGE_SOURCE_ACCESS" setup_source_access_broker
		fi
		;;
	"$SETUP_STAGE_HOOKS")
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks
		;;
	"$SETUP_STAGE_TABBY")
		_time_step "$SETUP_STAGE_TABBY" setup_tabby
		;;
	"$SETUP_STAGE_PULSE")
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os"
		_time_step "setup_pulse_merge_routine" setup_pulse_merge_routine
		;;
	"$SETUP_STAGE_GUI_DESKTOP")
		_time_step "$SETUP_STAGE_GUI_DESKTOP" setup_gui_desktop_app
		;;
	"$SETUP_STAGE_AI_SESSION")
		if ! _setup_run_ai_session_incremental "$os"; then
			print_warning "AI-session incremental setup unavailable or failed; falling back to full setup"
			# Floor for verification: the deploy below reads HEAD at its own
			# start, which may be later than this point but never earlier.
			current_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || current_sha=""
			[[ -n "$current_sha" ]] || return 1
			_setup_run_non_interactive || return $?
			_setup_post_setup_steps "$os" || return $?
			_setup_ai_session_verify_deploy "$current_sha" || return $?
		fi
		;;
	*)
		print_error "Unsupported canonical setup stage: $stage"
		return 1
		;;
	esac
	return 0
}

reconcile_buzz_desktop_compatibility() {
	local helper="${INSTALL_DIR}/agents/scripts/buzz-desktop-helper.sh"
	[[ -x "$helper" ]] || return 0
	local rc=0
	bash "$helper" reconcile --quiet || rc=$?
	case "$rc" in
	0) return 0 ;;
	2)
		print_warning "Buzz Desktop compatibility reconciliation deferred until Buzz is closed; run: aidevops buzz apply"
		return 0
		;;
	*)
		print_warning "Buzz Desktop compatibility reconciliation failed; inspect with: aidevops buzz status"
		return 0
		;;
	esac
}

# GH#33249: best-effort one-shot cleanup; a refusal must not abort deployment.
_setup_cleanup_retired_prompt_tooling_nonfatal() {
	cleanup_retired_prompt_tooling || print_warning "Retired prompt tooling cleanup incomplete; setup will retry next time"
	return 0
}

_setup_run_noninteractive_migrations() {
	_time_step "migrate_old_backups" migrate_old_backups
	_time_step "migrate_loop_state_directories" migrate_loop_state_directories
	_time_step "migrate_agent_to_agents_folder" migrate_agent_to_agents_folder
	_time_step "migrate_mcp_env_to_credentials" migrate_mcp_env_to_credentials
	_time_step "migrate_pulse_repos_to_repos_json" migrate_pulse_repos_to_repos_json
	_time_step "cleanup_deprecated_paths" cleanup_deprecated_paths
	_time_step "cleanup_retired_prompt_tooling" _setup_cleanup_retired_prompt_tooling_nonfatal
	_time_step "migrate_orphaned_supervisor" migrate_orphaned_supervisor
	_time_step "migrate_custom_model_routing_reasoning_defaults" migrate_custom_model_routing_reasoning_defaults
	_time_step "migrate_obsolete_settings_model_routing" migrate_obsolete_settings_model_routing
	_time_step "migrate_worker_capacity_reset" migrate_worker_capacity_reset
	_time_step "migrate_compaction_target_240k" migrate_compaction_target_240k
	_time_step "migrate_sonnet_5_5_settings" migrate_sonnet_5_5_settings
	_time_step "migrate_haiku_5_5_settings" migrate_haiku_5_5_settings
	_time_step "backfill_issue_relationships" backfill_issue_relationships
	_time_step "cleanup_deprecated_mcps" cleanup_deprecated_mcps
	_time_step "cleanup_stale_bun_opencode" cleanup_stale_bun_opencode
	_time_step "cleanup_stale_health_issue_caches" cleanup_stale_health_issue_caches
	_time_step "cleanup_legacy_aidevops_temp_artifacts" cleanup_legacy_aidevops_temp_artifacts
	_time_step "cleanup_worktree_entries_in_repos_json" cleanup_worktree_entries_in_repos_json
	_time_step "migrate_routines_repo_purpose_marker" migrate_routines_repo_purpose_marker
	_time_step "_cleanup_legacy_model_config" _cleanup_legacy_model_config
	_time_step "cleanup_legacy_dashboard_launchagent" cleanup_legacy_dashboard_launchagent
	_time_step "cleanup_legacy_agents_md_templates" cleanup_legacy_agents_md_templates
	_time_step "review_js_dependency_policies" review_js_dependency_policies
	return 0
}

# Optional user tools refreshed on every non-interactive setup/update. Each
# stage is bounded and non-critical.
_setup_run_noninteractive_optional_tools() {
	# Update-if-installed only; never installs Nostr VPN (GH#23846).
	_time_step "setup_nostr_vpn" _setup_run_noncritical_stage_bounded "Nostr VPN update check" "${AIDEVOPS_SETUP_NOSTR_VPN_TIMEOUT:-120}" setup_nostr_vpn
	# Install-if-missing for supported browsers; browse self-updates (GH#37155).
	_time_step "setup_opencode_browse" _setup_run_noncritical_stage_bounded "OpenCode browse setup" "${AIDEVOPS_SETUP_OPENCODE_BROWSE_TIMEOUT:-120}" setup_opencode_browse
	return 0
}

_setup_run_non_interactive() {
	print_info "Non-interactive mode: deploying agents and running safe migrations only"

	_setup_init_stage_timing_log

	_time_step "protect_current_setup_worktree" protect_current_setup_worktree
	_time_step "verify_location" verify_location
	_time_step "check_requirements" check_requirements
	_time_step "check_quality_tools" check_quality_tools
	_time_step "setup_setsid_advisory" setup_setsid_advisory
	_time_step "check_python_upgrade_available" check_python_upgrade_available
	_time_step "setup_vault_python_env" setup_vault_python_env || print_warning "Vault crypto runtime setup encountered issues; Vault status remains metadata-only"
	_time_step "set_permissions" set_permissions
	_setup_run_noninteractive_migrations
	_time_step "$SETUP_STAGE_OPENCODE" setup_opencode_runtimes
	_time_step "validate_opencode_config" validate_opencode_config
	_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents
	_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_runtime_plugins
	_time_step "$SETUP_STAGE_OPENCODE_SERVICE" setup_opencode_service
	_time_step "reconcile_buzz_desktop_compatibility" reconcile_buzz_desktop_compatibility
	_time_step "_setup_install_pulse_plist_early" _setup_install_pulse_plist_early
	_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config
	_time_step "setup_opencode_desktop_launcher" setup_opencode_desktop_launcher
	_time_step "sync_agent_sources" sync_agent_sources
	_time_step "install_aidevops_cli" install_aidevops_cli || print_warning "aidevops CLI installation encountered issues; continuing configuration reconciliation"
	_time_step "setup_source_access_broker" setup_source_access_broker_nonfatal
	_time_step "setup_shellcheck_wrapper" setup_shellcheck_wrapper
	if is_feature_enabled safety_hooks 2>/dev/null; then
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks
	fi
	_time_step "init_settings_json" init_settings_json

	local _pid_symlinks=""
	if _time_step "generate_agent_skills" generate_agent_skills; then
		_time_step "create_skill_symlinks" create_skill_symlinks &
		_pid_symlinks=$!
		_setup_register_child_pid "$_pid_symlinks"
	else
		print_warning "Agent skills generation failed — skipping skill symlinks"
	fi

	_time_step "scan_imported_skills" scan_imported_skills &
	local _pid_scan=$!
	_setup_register_child_pid "$_pid_scan"

	if [[ -n "$_pid_symlinks" ]]; then
		wait "$_pid_symlinks" 2>/dev/null || print_warning "Skill symlink creation encountered issues (non-critical)"
	fi
	wait "$_pid_scan" 2>/dev/null || print_warning "Skill security scan encountered issues (non-critical)"

	_time_step "inject_agents_reference" inject_agents_reference
	# Use the bounded wrapper so a slow file-system traversal across many agent
	# files does not consume the remaining postflight budget and trip the outer
	# timeout (GH#22087). AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT controls the deadline.
	_time_step "deploy_agents_to_runtimes" _deploy_agents_to_runtimes_bounded || true
	_time_step "update_opencode_config" _setup_run_noncritical_stage_bounded "OpenCode config update" "${AIDEVOPS_UPDATE_OPENCODE_CONFIG_TIMEOUT:-60}" update_opencode_config
	_time_step "update_claude_config" update_claude_config
	_time_step "update_codex_config" update_codex_config_noncritical
	_time_step "update_cursor_config" update_cursor_config
	_time_step "disable_ondemand_mcps" disable_ondemand_mcps
	_setup_run_noninteractive_optional_tools
	# Scaffold personal routines repo if not already present (idempotent).
	# Creates local git repo + private GitHub remote for personal repo only.
	# Org repos require explicit: aidevops init-routines --org <name>
	_time_step "setup_routines" _setup_run_noncritical_stage_bounded "Routine setup" "${AIDEVOPS_SETUP_ROUTINES_TIMEOUT:-120}" setup_routines
	# Install/refresh the privacy-guard pre-push hook in every initialized
	# repo so TODO/todo/README/ISSUE_TEMPLATE pushes to public GitHub repos
	# are scanned for private slug leaks (t1968).
	_time_step "setup_privacy_guard" setup_privacy_guard
	# Install/refresh the complexity-regression pre-push hook in every
	# initialized repo so pushes that introduce new function-complexity,
	# nesting-depth, or file-size violations are caught before CI (t2198).
	_time_step "setup_complexity_guard" setup_complexity_guard
	# Migrate exact repository-native lint policy and install/refresh repo-verify
	# for eligible registered repositories. Explicit opt-outs are preserved.
	_time_step "setup_repo_verify_guard" setup_repo_verify_guard
	# Install/refresh the canonical-on-main post-checkout hook in every
	# initialized repo so branch switches away from main in the canonical
	# directory are warned against (t1995). Complements pre-edit-check.sh's
	# t1990 edit-time check by catching the branch switch itself.
	_time_step "setup_canonical_guard" setup_canonical_guard
	# Install/refresh the task-id collision guard commit-msg hook in every
	# initialized repo so invented t-IDs in commit subjects are rejected
	# at commit time (t2047). Belt-and-braces with the CI check in
	# .github/workflows/task-id-collision-check.yml.
	_time_step "setup_task_id_guard" setup_task_id_guard
	# Configure the centralized flat linked-worktree directory used by helpers.
	_time_step "setup_worktree_location" setup_worktree_location
	# Apply Spotlight + Time Machine exclusions to every worktree across
	# registered repos so the backup/index cascade triggered by node_modules
	# copies doesn't burn CPU (t2885). Idempotent. macOS only — Linux
	# indexers tracked separately.
	_time_step "setup_worktree_exclusions" setup_worktree_exclusions
	# Provision knowledge planes for repos where knowledge != "off" (idempotent).
	_time_step "setup_knowledge_planes" setup_knowledge_planes
	# Provision cases planes for repos where cases != "off" (idempotent).
	_time_step "setup_cases_planes" setup_cases_planes
	_time_step "setup_gui_desktop_app_opt_in" _setup_offer_gui_desktop_app
	return 0
}

# Interactive runtime/tool setup prompts. Extracted so the parent interactive
# setup function stays below the function-complexity gate while preserving the
# prompt order around runtime-specific installers and config updates.
_setup_run_interactive_runtime_tools() {
	confirm_step "Deploy aidevops agents to runtime agent directories" && deploy_agents_to_runtimes
	confirm_step "Setup isolated Vault crypto runtime" && setup_vault_python_env
	confirm_step "Install MCP packages globally (fast startup)" && install_mcp_packages
	confirm_step "Setup LocalWP MCP server" && setup_localwp_mcp
	confirm_step "Setup SEO integrations (curl subagents)" && setup_seo_mcps
	confirm_step "Setup Google Analytics MCP" && setup_google_analytics_mcp
	confirm_step "Setup QuickFile MCP (UK accounting)" && setup_quickfile_mcp
	confirm_step "Setup browser automation tools" && setup_browser_tools
	confirm_step "Setup AI orchestration frameworks info" && setup_ai_orchestration
	confirm_step "Setup Ollama (local LLM for knowledge plane pii/sensitive/privileged tiers)" && setup_ollama_for_knowledge
	confirm_step "Setup Google Workspace CLI (Gmail, Calendar, Drive)" && setup_google_workspace_cli
	confirm_step "Setup Cloudflare cf CLI (full Cloudflare API)" && setup_cloudflare_cf_cli
	confirm_step "Setup OpenCode V1 and isolated V2 preview CLIs" && setup_opencode_runtimes
	confirm_step "Install OpenCode AIDevOps Desktop app wrapper" && setup_opencode_desktop_launcher
	confirm_step "Setup OpenCode plugins" && setup_opencode_runtime_plugins
	confirm_step "Setup persistent OpenCode owner (preserve existing histories)" && setup_opencode_service
	confirm_step "Setup Codex CLI (OpenAI AI coding tool)" && setup_codex_cli
	confirm_step "Setup Droid CLI (Factory.AI coding tool)" && setup_droid_cli
	confirm_step "Update Nostr VPN nvpn CLI (only if Nostr VPN is installed)" && setup_nostr_vpn
	return 0
}

# Silent one-shot migrations for the interactive path (idempotent, flag-guarded
# — no prompt needed). The non-interactive path times the same steps in
# _setup_run_noninteractive_migrations.
_setup_run_interactive_silent_migrations() {
	_setup_cleanup_retired_prompt_tooling_nonfatal
	cleanup_stale_health_issue_caches
	cleanup_legacy_aidevops_temp_artifacts
	cleanup_worktree_entries_in_repos_json
	migrate_routines_repo_purpose_marker
	_cleanup_legacy_model_config
	cleanup_legacy_dashboard_launchagent
	cleanup_legacy_agents_md_templates
	# Prompts (default No) only when a dispatch repo's JS install approval is stale.
	review_js_dependency_policies
	return 0
}

# Interactive path: all optional steps gated behind confirm_step prompts.
_setup_run_interactive() {
	# Required steps (always run)
	verify_location
	check_requirements

	# Quality tools check (optional but recommended)
	confirm_step "Check quality tools (shellcheck, shfmt)" && check_quality_tools

	# Core runtime setup (early - many later steps depend on these)
	confirm_step "Setup Node.js runtime (required for OpenCode and tools)" && setup_nodejs

	# Shell environment setup (early, so later tools benefit from zsh/Oh My Zsh)
	confirm_step "Setup Oh My Zsh (optional, enhances zsh)" && setup_oh_my_zsh
	confirm_step "Setup cross-shell compatibility (preserve bash config in zsh)" && setup_shell_compatibility

	# OrbStack (macOS only - offer VM option early)
	confirm_step "Setup OrbStack (lightweight Linux VMs on macOS)" && setup_orbstack_vm

	# Optional steps with confirmation in interactive mode
	confirm_step "Check optional dependencies (bun, node, python)" && check_optional_deps
	confirm_step "Check Python version (recommend upgrade if outdated)" && check_python_upgrade_available
	confirm_step "Setup recommended tools (Tabby, Zed, etc.)" && setup_recommended_tools
	confirm_step "Setup PIM tools (Reminders, Calendar, Contacts)" && setup_pim_tools
	confirm_step "Setup mobile tools (optional adb, Xcode guidance, MiniSim, serve-sim, Mobile MCP)" && setup_mobile_simulator_tools
	confirm_step "Setup ClaudeBar (AI quota monitor in menu bar)" && setup_claudebar
	confirm_step "Setup Git CLIs (gh, glab, tea)" && setup_git_clis
	confirm_step "Setup file discovery tools (fd, ripgrep, ripgrep-all)" && setup_file_discovery_tools
	confirm_step "Setup rtk (token-optimized CLI output, 60-90% savings)" && setup_rtk
	confirm_step "Setup shell linting tools (shellcheck, shfmt)" && {
		setup_shell_linting_tools
		setup_shellcheck_wrapper
	}
	confirm_step "Setup Qlty CLI (multi-linter code quality)" && setup_qlty_cli
	confirm_step "Rosetta audit (Apple Silicon x86 migration)" && setup_rosetta_audit
	confirm_step "Setup Worktrunk (git worktree management)" && setup_worktrunk
	confirm_step "Setup SSH key" && setup_ssh_key
	confirm_step "Setup configuration files" && setup_configs
	confirm_step "Set secure permissions on config files" && set_permissions
	confirm_step "Setup shell aliases" && setup_aliases
	confirm_step "Setup terminal title integration" && setup_terminal_title
	confirm_step "Deploy agent workspace template" && deploy_ai_templates
	confirm_step "Migrate old backups to new structure" && migrate_old_backups
	confirm_step "Migrate loop state from .claude/.agent/ to .agents/loop-state/" && migrate_loop_state_directories
	confirm_step "Migrate .agent -> .agents in user projects" && migrate_agent_to_agents_folder
	confirm_step "Migrate mcp-env.sh -> credentials.sh" && migrate_mcp_env_to_credentials
	confirm_step "Migrate pulse-repos.json into repos.json" && migrate_pulse_repos_to_repos_json
	confirm_step "Cleanup deprecated agent paths" && cleanup_deprecated_paths
	confirm_step "Migrate orphaned supervisor to pulse-wrapper" && migrate_orphaned_supervisor
	migrate_custom_model_routing_reasoning_defaults
	migrate_obsolete_settings_model_routing
	migrate_worker_capacity_reset
	migrate_compaction_target_240k
	migrate_sonnet_5_5_settings
	migrate_haiku_5_5_settings
	confirm_step "Backfill GitHub issue relationships (blocked-by, sub-issues)" && backfill_issue_relationships
	confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
	confirm_step "Cleanup stale bun opencode install" && cleanup_stale_bun_opencode
	_setup_run_interactive_silent_migrations
	confirm_step "Validate and repair OpenCode config schema" && validate_opencode_config
	confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
	confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
	confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && {
		deploy_aidevops_agents
		_deploy_hotfix_config
	}
	reconcile_buzz_desktop_compatibility
	# Launcher verification reads the deployed VERSION, so it must follow agent
	# deployment on first-run interactive setup as it already does non-interactively.
	confirm_step "Install and verify aidevops CLI command" && install_aidevops_cli
	if confirm_step "Install the secure source-access approval broker"; then
		AIDEVOPS_SOURCE_ACCESS_INTERACTIVE=true setup_source_access_broker_nonfatal
	fi
	confirm_step "Sync agents from private repositories" && sync_agent_sources
	confirm_step "Set up routines repo (private repo for recurring operational jobs)" && setup_routines
	is_feature_enabled safety_hooks 2>/dev/null && confirm_step "Install Claude Code safety hooks (block destructive commands)" && setup_safety_hooks
	confirm_step "Initialize settings.json (canonical config file)" && init_settings_json
	confirm_step "Setup multi-tenant credential storage" && setup_multi_tenant_credentials
	confirm_step "Generate agent skills (SKILL.md files)" && generate_agent_skills
	confirm_step "Create symlinks for imported skills" && create_skill_symlinks
	confirm_step "Check for skill updates from upstream" && check_skill_updates
	confirm_step "Security scan imported skills" && scan_imported_skills
	confirm_step "Inject agents reference into AI configs" && inject_agents_reference
	_setup_run_interactive_runtime_tools
	_setup_offer_gui_desktop_app
	# Run AFTER CLI installs so config dirs may exist for agent config
	confirm_step "Update OpenCode configuration" && update_opencode_config
	# Run AFTER OpenCode config so Claude Code gets equivalent setup
	confirm_step "Update Claude Code configuration (slash commands, MCPs, settings)" && update_claude_config
	# Run AFTER Claude Code config so Codex/Cursor get equivalent setup
	confirm_step "Update Codex configuration (MCPs, instructions)" && update_codex_config_noncritical
	confirm_step "Update Cursor configuration (MCPs)" && update_cursor_config
	# Deploy slash commands to the other installed runtimes (Codex, Cursor,
	# Droid, Gemini CLI, Continue, Kiro, Kimi, Qwen) via the unified generator.
	# OpenCode and Claude Code are already handled by their update_*_config
	# functions above. Closes GH#18106 / t15474.
	confirm_step "Deploy slash commands to remaining runtimes" && deploy_commands_to_all_runtimes
	# Run AFTER all MCP setup functions to ensure disabled state persists
	confirm_step "Disable on-demand MCPs globally" && disable_ondemand_mcps
	return 0
}

# Post-setup steps: schedulers, final instructions, optional tool update check.
# Non-interactive scheduler installation. Extracted from
# `_setup_post_setup_steps` (t2903) to keep the parent under the
# function-complexity gate threshold. Each `_should_setup_noninteractive_*`
# guard returns 0 when the corresponding scheduler is already installed
# (regenerate on update) or first-time install is consented via config.
_setup_noninteractive_schedulers() {
	local os="$1"

	# GH#22012: Wrap every scheduler step with _time_step so the stage-timing
	# log ($HOME/.aidevops/logs/setup-stage-timings.log) covers post-deploy
	# scheduler setup — the same visibility _setup_run_non_interactive has.

	# Auto-update handles non-interactive internally (systemd detection fixed in GH#17861)
	_time_step "setup_auto_update" setup_auto_update
	if _should_setup_noninteractive_supervisor_pulse; then
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os"
	fi
	# t2939: pulse-watchdog (independent revival mechanism). Always installed
	# alongside the pulse — it is a no-op when pulse is disabled. Skipping the
	# `_should_setup_noninteractive_*` guard intentionally: this is layered
	# defense, the cost of installing it is one plist file, and the user opts
	# in by enabling the pulse itself.
	_time_step "setup_pulse_watchdog" setup_pulse_watchdog "${PULSE_ENABLED:-}"
	# Regenerate other schedulers if already installed (GH#17695 Finding B).
	# Stats wrapper is a pulse dependency — also install on first run when
	# the supervisor pulse is consented (t2418, GH#20016).
	if _should_setup_noninteractive_stats_wrapper; then
		_time_step "setup_stats_wrapper" setup_stats_wrapper "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_failure_miner; then
		_time_step "setup_failure_miner" setup_failure_miner "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_scheduler "Process guard" "sh.aidevops.process-guard" "aidevops: process-guard" "aidevops-process-guard"; then
		_time_step "setup_process_guard" setup_process_guard
	fi
	if _should_setup_noninteractive_scheduler "Memory pressure" "sh.aidevops.memory-pressure-monitor" "aidevops: memory-pressure-monitor" "aidevops-memory-pressure-monitor"; then
		_time_step "setup_memory_pressure_monitor" setup_memory_pressure_monitor
	fi
	# GH#36709: Linux profile README installs also need the activity sampler.
	if _should_setup_noninteractive_screen_time; then
		_time_step "setup_screen_time_snapshot" setup_screen_time_snapshot
	fi
	if _should_setup_noninteractive_scheduler "Contribution watch" "sh.aidevops.contribution-watch" "aidevops: contribution-watch" "aidevops-contribution-watch"; then
		_time_step "setup_contribution_watch" setup_contribution_watch
	fi
	# t2903 (#21049): complexity scan — extracted from pulse dispatch preflight.
	# GH#24841: use a pulse-dependency escape hatch so non-interactive updates
	# backfill the standalone timer for existing pulse-enabled installs.
	if _should_setup_noninteractive_complexity_scan; then
		_time_step "setup_complexity_scan" setup_complexity_scan
	fi
	# t2862 (GH#20919): pulse merge routine — fast 120s standalone merge pass.
	# t3036 (GH#21616): use the pulse-dependency escape hatch instead of the
	# generic chicken-and-egg gate so the routine installs on existing systems
	# whenever the supervisor pulse is consented.
	if _should_setup_noninteractive_pulse_merge_routine; then
		_time_step "setup_pulse_merge_routine" _setup_run_noncritical_stage_bounded "Pulse merge routine setup" "${AIDEVOPS_SETUP_PULSE_MERGE_ROUTINE_TIMEOUT:-30}" setup_pulse_merge_routine
		# t19030: a timeout kill can leave the merge scheduler unregenerated
		# before the child reaches its own deferral.
		if [[ "${_SETUP_NONCRITICAL_STAGE_TIMED_OUT:-false}" == "true" ]]; then
			_schedulers_defer_template_hash "pulse merge routine setup timed out"
		fi
	fi
	# t2932 (GH#21125): peer productivity monitor — adaptive cross-runner
	# dispatch coordination, runs every 30 min.
	if _should_setup_noninteractive_scheduler "Peer productivity monitor" "sh.aidevops.peer-productivity-monitor" "aidevops: peer-productivity-monitor" "aidevops-peer-productivity-monitor"; then
		_time_step "setup_peer_productivity_monitor" setup_peer_productivity_monitor
	fi
	# Repo sync handles non-interactive mode internally (systemd detection fixed in GH#17861)
	_time_step "setup_repo_sync" setup_repo_sync
	_time_step "setup_mirror_sync" setup_mirror_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	_time_step "setup_repo_aidevops_health" setup_repo_aidevops_health
	if _should_setup_noninteractive_scheduler "Profile README" "sh.aidevops.profile-readme-update" "aidevops: profile-readme-update" "aidevops-profile-readme-update"; then
		_time_step "setup_profile_readme" setup_profile_readme
	fi
	if _should_setup_noninteractive_scheduler "OAuth token refresh" "sh.aidevops.token-refresh" "aidevops: token-refresh" "aidevops-token-refresh"; then
		_time_step "setup_oauth_token_refresh" setup_oauth_token_refresh
	fi
	# opencode DB maintenance (r913, t2183). Helper self-noops on missing
	# DB — safe to install unconditionally in non-interactive mode too.
	_time_step "setup_opencode_db_maintenance" setup_opencode_db_maintenance
	# opencode DB archive/VACUUM (GH#25136). Dedicated low-priority scheduler;
	# not tied to pulse preflight cadence.
	_time_step "setup_opencode_db_archive" setup_opencode_db_archive
	# r922 storage hygiene (GH#35245). Daily owning-cleaner run, Pulse-independent.
	_time_step "setup_storage_hygiene" setup_storage_hygiene
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	_time_step "migrate_cron_to_systemd" migrate_cron_to_systemd
	# t19030: only a full scheduler pass records the plist drift template hash.
	_schedulers_record_template_hash
	_time_step "$SETUP_STAGE_TABBY" setup_tabby
	return 0
}

_setup_print_noninteractive_success() {
	# Ensure every tracked or discovered child has either exited or been
	# intentionally terminated before emitting the caller-visible success line.
	_setup_cleanup_noninteractive_children
	print_setup_summary
	echo ""
	print_success "Setup complete!"
	return 0
}
