#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Interactive postflight and non-interactive scheduler dispatch.
# Sourced by setup.sh; completion and pulse reconciliation remain in the caller.

[[ -n "${_SETUP_POSTFLIGHT_LOADED:-}" ]] && return 0
_SETUP_POSTFLIGHT_LOADED=1

_setup_post_setup_steps() {
	local os="$1"

	# Non-interactive mode still has post-deploy scheduler and pulse-restart
	# work to do. Do not print the human "Setup complete!" marker until those
	# bounded postflight steps and the final child-process drain have finished;
	# callers treat that line as a completion signal.
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_noninteractive_schedulers "$os"
		return 0
	fi

	# Print setup summary before final success message (GH#5240)
	print_setup_summary

	echo ""
	print_success "Setup complete!"

	# Cache client request format constants if CLI is installed (~50ms)
	if command -v claude &>/dev/null && [[ -x "${INSTALL_DIR}/.agents/scripts/cch-extract.sh" ]]; then
		"${INSTALL_DIR}/.agents/scripts/cch-extract.sh" --cache >/dev/null 2>&1 || true
	else
		echo ""
		echo -e "${YELLOW}[TIP]${NC} Install Claude CLI for automatic request format alignment:"
		echo "      npm install -g @anthropic-ai/claude-code"
	fi

	# Post-setup: auto-update, schedulers, final instructions (GH#5793)
	setup_auto_update
	setup_supervisor_pulse "$os"
	# t2939: pulse-watchdog — independent revival mechanism, layered defense.
	setup_pulse_watchdog "${PULSE_ENABLED:-}"
	setup_stats_wrapper "${PULSE_ENABLED:-}"
	setup_failure_miner "${PULSE_ENABLED:-}"
	setup_repo_sync
	setup_mirror_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	setup_repo_aidevops_health
	setup_process_guard
	setup_memory_pressure_monitor
	setup_screen_time_snapshot
	setup_contribution_watch
	setup_complexity_scan
	setup_pulse_merge_routine
	setup_peer_productivity_monitor
	setup_draft_responses
	setup_profile_readme
	setup_oauth_token_refresh
	setup_opencode_db_maintenance
	setup_opencode_db_archive
	setup_storage_hygiene
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	migrate_cron_to_systemd
	# t19030: only a full scheduler pass records the plist drift template hash.
	_schedulers_record_template_hash
	setup_tabby
	print_final_instructions

	# Check for tool updates if --update flag was passed
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo ""
		check_tool_updates
	fi

	setup_onboarding_prompt
	return 0
}
