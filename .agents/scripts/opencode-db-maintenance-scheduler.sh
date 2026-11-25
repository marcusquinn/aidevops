#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode DB maintenance -- Subcommands: install, uninstall, status, notice
# =============================================================================
# Split from opencode-db-maintenance-helper.sh (macOS launchd scheduler and notices).
# Sourced by the helper; relies on its constants and shared helpers.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_OPENCODE_DB_MAINTENANCE_SCHEDULER_LOADED:-}" ]] && return 0
_OPENCODE_DB_MAINTENANCE_SCHEDULER_LOADED=1

# -----------------------------------------------------------------------------
# Subcommand: install / uninstall / status (macOS launchd scheduler, t2183)
# -----------------------------------------------------------------------------
# Helper owns its plist generation (Approach B, mirrors repo-sync-helper.sh).
# Linux systemd/cron install is handled by .agents/scripts/setup/modules/schedulers.sh calling
# _install_scheduler_linux — these subcommands are macOS-only; on Linux they
# print an info message and exit 0 (success, nothing to do here).

# _is_macos — 0 on Darwin
_is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
}

# _launchd_is_loaded — 0 if our LaunchAgent is listed
# SIGPIPE-safe under set -o pipefail (t1265): capture to variable first
_launchd_is_loaded() {
	local output
	output=$(launchctl list 2>/dev/null) || true
	grep -qF -- "$LAUNCHD_LABEL" <<<"$output"
}

# _resolve_self_path — emit the path that launchd should exec.
# Prefer the deployed copy at ~/.aidevops/agents/scripts/ so the LaunchAgent
# survives repo moves. Fall back to the running script's dir when the deployed
# copy is missing (first-install from a checkout).
_resolve_self_path() {
	local deployed="${HOME}/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh"
	if [[ -f "$deployed" ]]; then
		printf '%s' "$deployed"
	else
		printf '%s' "${SCRIPT_DIR}/$(basename "${OPENCODE_DB_MAINTENANCE_SELF}")"
	fi
}

# _generate_plist_content <self_path>
# Emit the LaunchAgent plist XML for the r913 weekly schedule.
# Uses StartCalendarInterval (not StartInterval) with Weekday=0 (Sunday),
# Hour=4, Minute=0 — matches the routine's declared "weekly(sun@04:00)".
_generate_plist_content() {
	local self_path="$1"
	local scheduler_subcommand="auto"
	if [[ "$OPENCODE_DB_MAINTENANCE_MODE" == "$MAINTENANCE_WINDOW_MODE" ]]; then
		scheduler_subcommand="$MAINTENANCE_WINDOW_MODE"
	fi
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${self_path}</string>
		<string>${scheduler_subcommand}</string>
$([[ "$scheduler_subcommand" == "$MAINTENANCE_WINDOW_MODE" ]] && printf '\t\t<string>--force-opencode</string>\n')
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Weekday</key>
		<integer>0</integer>
		<key>Hour</key>
		<integer>${OPENCODE_DB_MAINTENANCE_HOUR}</integer>
		<key>Minute</key>
		<integer>${OPENCODE_DB_MAINTENANCE_MINUTE}</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF
}

cmd_install() {
	if ! _is_macos; then
		print_info "install: Linux scheduling is handled by .agents/scripts/setup/modules/schedulers.sh (systemd/cron)"
		print_info "This helper's install subcommand is macOS-only — exiting cleanly"
		return 0
	fi

	mkdir -p "$LAUNCHD_DIR" "$SCHEDULER_LOG_DIR"

	local self_path new_content
	self_path=$(_resolve_self_path)
	new_content=$(_generate_plist_content "$self_path")

	# Content-diff: skip reload if identical and already loaded (same semantics
	# as _launchd_install_if_changed in setup.sh).
	if [[ -f "$LAUNCHD_PLIST" ]] && _launchd_is_loaded; then
		local existing
		existing=$(cat "$LAUNCHD_PLIST" 2>/dev/null || echo "")
		if [[ "$existing" == "$new_content" ]]; then
			print_info "Already installed with identical config ($LAUNCHD_LABEL)"
			return 0
		fi
	fi

	# Unload before replacing plist (avoid stale config)
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
	fi

	printf '%s\n' "$new_content" >"$LAUNCHD_PLIST"
	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		print_success "opencode DB maintenance scheduled (weekly, Sun 04:00 local)"
		print_info "  Label:  $LAUNCHD_LABEL"
		print_info "  Plist:  $LAUNCHD_PLIST"
		print_info "  Script: $self_path"
		print_info "  Logs:   $SCHEDULER_LOG_FILE"
		_log INFO "install: LaunchAgent loaded ($LAUNCHD_LABEL → $self_path)"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		_log ERROR "install: launchctl load failed"
		return 1
	fi
	return 0
}

cmd_uninstall() {
	if ! _is_macos; then
		print_info "uninstall: Linux scheduling is handled by .agents/scripts/setup/modules/schedulers.sh"
		return 0
	fi

	local changed=false
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
		changed=true
	fi
	if [[ -f "$LAUNCHD_PLIST" ]]; then
		rm -f "$LAUNCHD_PLIST"
		changed=true
	fi

	if [[ "$changed" == true ]]; then
		print_success "LaunchAgent removed ($LAUNCHD_LABEL)"
		_log INFO "uninstall: LaunchAgent removed"
	else
		print_info "Not installed (nothing to remove)"
	fi
	return 0
}

cmd_status() {
	local installed=false
	if _is_macos; then
		if _launchd_is_loaded; then
			print_success "macOS LaunchAgent loaded: $LAUNCHD_LABEL"
			installed=true
		fi
		if [[ -f "$LAUNCHD_PLIST" ]]; then
			print_info "  Plist: $LAUNCHD_PLIST"
		fi
	fi

	if command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled aidevops-opencode-db-maintenance.timer >/dev/null 2>&1; then
		print_success "Linux systemd timer enabled: aidevops-opencode-db-maintenance.timer"
		installed=true
	fi

	local cron_listing=""
	command -v crontab >/dev/null 2>&1 && cron_listing=$(crontab -l 2>/dev/null || true)
	if grep -qF -- "aidevops: opencode-db-maintenance" <<<"$cron_listing"; then
		print_success "Cron entry installed"
		installed=true
	fi

	if [[ "$installed" == false ]]; then
		print_info "Scheduler not installed (run: opencode-db-maintenance-helper.sh install)"
	fi

	if [[ -f "$SCHEDULER_LOG_FILE" ]]; then
		print_info "  Log:   $SCHEDULER_LOG_FILE"
	fi
	return 0
}

# _event_growth_notice — GH#38630: print one warning and return 0 when event
# payload exceeds the cap or the DB grew > 5 GB since the previous report.
_event_growth_notice() {
	local stats rows bytes max growth
	[[ -f "$OPENCODE_DB" ]] && _sqlite_available || return 1
	stats=$(_event_stats "$OPENCODE_DB")
	[[ -n "$stats" ]] || return 1
	read -r rows bytes <<<"$stats"
	max=$(_event_max_bytes)
	if ((max > 0 && bytes > max)); then
		printf '[OPENCODE MAINTENANCE] event table holds %s payload (%s rows), above the %s cap. Expiry of idle-session events runs hourly; run aidevops opencode-db report for details.\n' \
			"$(_db_size_human "$bytes")" "$rows" "$(_db_size_human "$max")"
		return 0
	fi
	growth=$(_db_growth_since_last_report "$(_db_size_bytes "$OPENCODE_DB")" 0)
	if ((growth > DB_GROWTH_WARN_BYTES)); then
		printf '[OPENCODE MAINTENANCE] opencode.db grew %s since the previous report (event payload %s). Run aidevops opencode-db report for details.\n' \
			"$(_db_size_human "$growth")" "$(_db_size_human "$bytes")"
		return 0
	fi
	return 1
}

# Subcommand: notice
# Emits at most one warning line for OpenCode's session-start toast.
cmd_notice() {
	if ! _opencode_installed; then
		return 0
	fi

	# GH#37663: sessions stopped for maintenance that await a manual resume,
	# then long-deferred maintenance caused by interactive TUI holders.
	local restart_notice=""
	if [[ -x "$OPENCODE_SESSION_RESTART_HELPER" ]]; then
		restart_notice=$("$OPENCODE_SESSION_RESTART_HELPER" notice 2>/dev/null || true)
	fi
	if [[ -n "$restart_notice" ]]; then
		printf '%s\n' "$restart_notice"
		return 0
	fi
	if _interactive_holder_advisory; then
		return 0
	fi
	if _event_growth_notice; then
		return 0
	fi

	if [[ "$OPENCODE_DB_MAINTENANCE_MODE" == "$MAINTENANCE_WINDOW_MODE" ]]; then
		printf '[OPENCODE MAINTENANCE] Scheduled weekly Sun %02d:%02d local: maintenance-window pauses pulse/headless workers while compacting opencode.db.\n' \
			"$OPENCODE_DB_MAINTENANCE_HOUR" "$OPENCODE_DB_MAINTENANCE_MINUTE"
		return 0
	fi

	# Repeated holder-blocked auto skips with reclaimable free pages: actionable.
	if _auto_skip_advisory; then
		return 0
	fi

	local now last_ts age db_bytes wal_bytes db_mb wal_mb due=false reason="" compact_notice=false
	now=$(date +%s)
	last_ts=$(_state_mtime_epoch "$STATE_FILE")
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")
	db_mb=$((db_bytes / 1048576))
	wal_mb=$((wal_bytes / 1048576))

	if [[ "$last_ts" -eq 0 ]]; then
		due=true
		reason="no previous run recorded"
	else
		age=$((now - last_ts))
		if [[ "$age" -ge "$AUTO_MIN_SECONDS_BETWEEN" ]]; then
			due=true
			reason="last run older than scheduler interval"
		fi
	fi

	if [[ "$wal_mb" -ge "$WAL_LARGE_THRESHOLD_MB" ]]; then
		due=true
		reason="WAL ${wal_mb}MB >= ${WAL_LARGE_THRESHOLD_MB}MB"
	elif [[ "$db_mb" -ge "$FORCE_VACUUM_SIZE_MB" ]]; then
		if [[ "$due" == true ]]; then
			reason="${reason}; DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
		elif _sqlite_available; then
			local page_count freelist_count state_outcome
			page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
			freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
			[[ "$page_count" =~ ^[0-9]+$ ]] || page_count=0
			[[ "$freelist_count" =~ ^[0-9]+$ ]] || freelist_count=0
			state_outcome=$(_state_json_field "outcome")
			if [[ "$last_ts" -gt 0 ]] && [[ "$state_outcome" == "success" ]] && \
				! _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
				compact_notice=true
			else
				due=true
				reason="DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
			fi
		else
			due=true
			reason="DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
		fi
	fi

	if [[ "$due" == true ]]; then
		printf '[OPENCODE MAINTENANCE] Recommended: %s. Run aidevops opencode-db maintenance-window off-hours; pulse/headless workers pause during the window.\n' "$reason"
	elif [[ "$compact_notice" == true ]]; then
		printf '[OPENCODE MAINTENANCE] Compact but large: DB %sMB >= %sMB, WAL is low, and free pages are below threshold after recent successful maintenance. Re-running maintenance-window is unlikely to reclaim space; run aidevops opencode-db report for retained-data details.\n' \
			"$db_mb" "$FORCE_VACUUM_SIZE_MB"
	fi
	return 0
}
