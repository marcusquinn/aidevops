#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode DB maintenance -- Subcommands: maintenance-window and auto
# =============================================================================
# Split from opencode-db-maintenance-helper.sh (cmd_maintenance_window and cmd_auto).
# Sourced by the helper; relies on its constants and shared helpers.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_OPENCODE_DB_MAINTENANCE_WINDOW_LOADED:-}" ]] && return 0
_OPENCODE_DB_MAINTENANCE_WINDOW_LOADED=1

# -----------------------------------------------------------------------------
# Subcommand: maintenance-window
# -----------------------------------------------------------------------------
# Explicitly disruptive run for off-hours windows. The parent stops the
# aidevops-managed pulse (no new workers), drains in-flight headless
# `opencode run` workers with a bounded wait, then visits the same DB inventory
# as `auto` (default DB plus isolated per-project DBs). Each DB is gated on its
# exact lsof holders, so a TUI open on one project skips only that DB instead of
# aborting the whole run. Pulse restarts even when a step fails. Interactive
# TUIs are never stopped by default; --force-opencode maintains held DBs anyway,
# and --restart-interactive (GH#37663) checkpoints, stops and later resumes
# idle TUIs through opencode-session-restart-helper.sh (busy ones are skipped).

# _headless_worker_count — in-flight headless `opencode run` workers.
_headless_worker_count() {
	local pids
	pids=$(pgrep -f "$HEADLESS_WORKER_PATTERN" 2>/dev/null || true)
	printf '%s\n' "$pids" | awk 'NF' | sort -u | wc -l | tr -d ' '
	return 0
}

# _drain_headless_workers <timeout_seconds> — wait (never kill) for headless
# workers to finish. Pulse is already stopped, so the count only falls. On
# timeout, continue: per-DB holder checks still protect any DB a worker holds.
_drain_headless_workers() {
	local timeout="$1"
	local poll="$MAINTENANCE_WINDOW_DRAIN_POLL"
	local waited=0
	local count
	[[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=10
	count=$(_headless_worker_count)
	if [[ "$count" -eq 0 ]]; then
		print_info "No in-flight headless workers to drain"
		return 0
	fi
	if [[ "$timeout" -eq 0 ]]; then
		print_info "Worker drain disabled; ${count} headless worker(s) still running (per-DB holder checks still apply)"
		return 0
	fi
	print_info "Draining ${count} in-flight headless worker(s), up to ${timeout}s (pulse is stopped, so no new workers start)..."
	while [[ "$count" -gt 0 && "$waited" -lt "$timeout" ]]; do
		sleep "$poll"
		waited=$((waited + poll))
		count=$(_headless_worker_count)
		print_info "  drain: ${count} worker(s) remaining after ${waited}s"
	done
	if [[ "$count" -gt 0 ]]; then
		print_warning "Drain timeout: ${count} headless worker(s) still running; continuing without killing them (any DB they hold is skipped)"
		return 0
	fi
	print_success "Headless workers drained"
	return 0
}

# _maintenance_window_db <force> <keep_sessions> <worker_days> <interactive_days> <skip_archive>
# Single-DB body; runs in an OPENCODE_MAINTENANCE_SINGLE_DB=1 child so the
# readonly DB paths, state dir, and exact holder count target that DB only.
# Returns 0 maintained, 2 skipped (held open), other values on failure.
_maintenance_window_db() {
	local force_opencode="$1"
	local keep_sessions="$2"
	local worker_days="$3"
	local interactive_days="$4"
	local skip_archive="$5"

	if ! _opencode_installed; then
		print_info "DB missing — nothing to maintain: $OPENCODE_DB"
		return 0
	fi
	local active_count
	active_count=$(_opencode_process_count)
	if [[ "$active_count" -gt 0 ]] && [[ "$force_opencode" != true ]]; then
		print_warning "Skipping ${OPENCODE_DB}: ${active_count} process(es) hold it open — close those OpenCode sessions or pass --force-opencode"
		_log INFO "maintenance-window: skipped, ${active_count} holder(s)"
		return 2
	fi

	local rc=0
	if [[ "$skip_archive" != true ]] && [[ -x "$OPENCODE_DB_ARCHIVE_HELPER" ]]; then
		print_info "Archiving old OpenCode sessions (headless ${worker_days}+ days, interactive ${interactive_days}+ days and outside newest ${keep_sessions})..."
		# env: OPENCODE_ARCHIVE_DB is readonly here, so a bare prefix assignment fails.
		env OPENCODE_DB_PATH="$OPENCODE_DB" OPENCODE_ARCHIVE_DB="$OPENCODE_ARCHIVE_DB" \
			"$OPENCODE_DB_ARCHIVE_HELPER" archive --worker-retention-days "$worker_days" \
			--interactive-retention-days "$interactive_days" --keep-sessions "$keep_sessions" --max-duration-seconds 300 || rc=$?
		if [[ "$rc" -ne 0 ]]; then
			print_warning "archive step failed (rc=${rc}); continuing to maintenance"
		fi
	fi

	local maintain_args=()
	if [[ "$force_opencode" == true ]]; then
		maintain_args+=(--force)
	fi
	cmd_maintain ${maintain_args[@]+"${maintain_args[@]}"} || rc=$?

	local integrity
	integrity=$("$SQLITE3_BIN" "$OPENCODE_DB" "$SQLITE_QUICK_CHECK" 2>&1 || echo "error")
	if [[ "$integrity" != "ok" ]]; then
		print_error "post-maintenance quick_check failed: $integrity"
		rc=1
	else
		print_success "post-maintenance quick_check: ok"
	fi
	return "$rc"
}

cmd_maintenance_window() {
	local force_opencode=false
	local keep_sessions="$MAINTENANCE_WINDOW_KEEP_SESSIONS"
	local worker_days="$MAINTENANCE_WINDOW_WORKER_RETENTION_DAYS"
	local interactive_days="$MAINTENANCE_WINDOW_INTERACTIVE_RETENTION_DAYS"
	local drain_timeout="$MAINTENANCE_WINDOW_DRAIN_TIMEOUT"
	local skip_archive=false
	local restart_interactive=false
	local assume_yes=false

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--force-opencode)
			force_opencode=true; shift
			;;
		--restart-interactive)
			restart_interactive=true; shift
			;;
		--yes | -y)
			assume_yes=true; shift
			;;
		--keep-sessions)
			keep_sessions="${2:-}"; shift 2
			;;
		--retention-days)
			worker_days="${2:-}"; interactive_days="${2:-}"; shift 2
			;;
		--worker-retention-days)
			worker_days="${2:-}"; shift 2
			;;
		--interactive-retention-days)
			interactive_days="${2:-}"; shift 2
			;;
		--drain-timeout)
			drain_timeout="${2:-}"; shift 2
			;;
		--skip-archive)
			skip_archive=true; shift
			;;
		*)
			print_error "Unknown maintenance-window option: $arg"
			return 1
			;;
		esac
	done

	[[ "$keep_sessions" =~ ^[0-9]+$ ]] || { print_error "--keep-sessions must be a non-negative integer: ${keep_sessions}"; return 1; }
	[[ "$worker_days" =~ ^[0-9]+$ ]] || { print_error "--worker-retention-days must be a non-negative integer: ${worker_days}"; return 1; }
	[[ "$interactive_days" =~ ^[0-9]+$ ]] || { print_error "--interactive-retention-days must be a non-negative integer: ${interactive_days}"; return 1; }
	[[ "$drain_timeout" =~ ^[0-9]+$ ]] || { print_error "--drain-timeout must be a non-negative integer: ${drain_timeout}"; return 1; }
	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available"
		return 1
	fi

	if [[ "${OPENCODE_MAINTENANCE_SINGLE_DB:-0}" == 1 ]]; then
		_maintenance_window_db "$force_opencode" "$keep_sessions" "$worker_days" "$interactive_days" "$skip_archive"
		return $?
	fi
	_maintenance_window_inventory "$force_opencode" "$keep_sessions" "$worker_days" "$interactive_days" "$skip_archive" "$drain_timeout" \
		"$restart_interactive" "$assume_yes"
	return $?
}

# _restart_interactive_stop <assume_yes> — GH#37663: checkpoint and stop idle
# interactive TUIs (never busy ones) and queue their resume as a cleanup, so
# sessions relaunch even when a maintenance step fails. Without terminal
# confirmation or host opt-in, the restart helper only notifies owners.
_restart_interactive_stop() {
	local assume_yes="$1"
	local args=(stop --all --reason "maintenance-window")
	local rc=0
	if [[ ! -x "$OPENCODE_SESSION_RESTART_HELPER" ]]; then
		print_warning "opencode-session-restart-helper.sh not found; interactive TUIs are left running"
		return 0
	fi
	[[ "$assume_yes" != true ]] || args+=(--yes)
	push_cleanup "$(printf '%q resume' "$OPENCODE_SESSION_RESTART_HELPER")"
	"$OPENCODE_SESSION_RESTART_HELPER" "${args[@]}" || rc=$?
	case "$rc" in
	0) _log INFO "maintenance-window: interactive TUIs stopped for restart" ;;
	2) print_warning "Some interactive sessions stayed busy or running; DBs they hold are skipped" ;;
	3) print_info "Interactive TUIs were notified only (no stop authority)" ;;
	*) print_warning "Interactive restart returned ${rc}; continuing with DB holder checks" ;;
	esac
	return 0
}

# _maintenance_window_inventory <force> <keep_sessions> <worker_days> <interactive_days> <skip_archive> <drain_timeout> [restart_interactive] [assume_yes]
# Parent run: stop pulse once, drain workers, then visit each inventory DB in a
# single-DB child. Returns 1 on any failure, 2 when only holder skips occurred.
_maintenance_window_inventory() {
	local force_opencode="$1"
	local keep_sessions="$2"
	local worker_days="$3"
	local interactive_days="$4"
	local skip_archive="$5"
	local drain_timeout="$6"
	local restart_interactive="${7:-false}"
	local assume_yes="${8:-false}"

	local dbs=()
	local db
	while IFS= read -r -d '' db; do
		dbs+=("$db")
	done < <(opencode_db_inventory "$OPENCODE_DB")
	if [[ "${#dbs[@]}" -eq 0 ]]; then
		print_info "opencode not installed — nothing to maintain"
		return 0
	fi

	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	if command -v "$PULSE_LIFECYCLE_HELPER" >/dev/null 2>&1; then
		print_info "Stopping pulse for maintenance window (no new workers will start)..."
		"$PULSE_LIFECYCLE_HELPER" stop || print_warning "pulse stop returned non-zero; continuing with DB holder checks"
		local restart_cmd
		restart_cmd=$(printf '%q start' "$PULSE_LIFECYCLE_HELPER")
		push_cleanup "$restart_cmd"
	else
		print_warning "pulse lifecycle helper not found; skipping pulse stop/start"
	fi

	_drain_headless_workers "$drain_timeout"
	[[ "$restart_interactive" != true ]] || _restart_interactive_stop "$assume_yes"

	local child_args=(--keep-sessions "$keep_sessions" --worker-retention-days "$worker_days" --interactive-retention-days "$interactive_days")
	[[ "$force_opencode" != true ]] || child_args+=(--force-opencode)
	[[ "$skip_archive" != true ]] || child_args+=(--skip-archive)

	local maintained=0 skipped=0 failed=0
	local child_rc state_dir
	for db in "${dbs[@]}"; do
		state_dir="$STATE_DIR"
		if [[ ! "$db" -ef "$OPENCODE_DB" ]]; then state_dir="${db%/*}/aidevops-maintenance"; fi
		print_info "Maintenance window DB: $db"
		child_rc=0
		env OPENCODE_DB_PATH="$db" OPENCODE_ARCHIVE_DB="${db%/*}/opencode-archive.db" \
			OPENCODE_MAINTENANCE_SINGLE_DB=1 OPENCODE_MAINTENANCE_STATE_DIR="$state_dir" \
			bash "${OPENCODE_DB_MAINTENANCE_SELF}" maintenance-window "${child_args[@]}" || child_rc=$?
		case "$child_rc" in
		0) maintained=$((maintained + 1)) ;;
		2) skipped=$((skipped + 1)) ;;
		*) failed=$((failed + 1)) ;;
		esac
	done

	print_info "Maintenance window summary: ${maintained} maintained, ${skipped} skipped (held open), ${failed} failed"
	trap - RETURN
	_run_cleanups
	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	if [[ "$skipped" -gt 0 ]]; then
		return 2
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: auto
# -----------------------------------------------------------------------------
# Safe wrapper for the weekly r913 routine. Exits 0 silently when opencode
# isn't installed (other users benefit from the routine being registered
# without seeing errors).

_prune_layout_backups() {
	local helper="${SCRIPT_DIR}/repo-layout-migrate-helper.sh"
	[[ -x "$helper" ]] || return 0
	if "$helper" prune --apply >/dev/null 2>&1; then
		_log INFO "auto: repo-layout migration backup prune complete"
	else
		_log WARN "auto: repo-layout migration backup prune failed (non-fatal)"
	fi
	return 0
}

# _prune_old_sessions — delete sessions past the configured retention for the
# current single DB (active + sibling archive). No-op when the setting is 0/invalid.
# Protected skips (rc 2) are expected; failures are logged but non-fatal.
_prune_old_sessions() {
	local days="" rc=0
	[[ -x "$OPENCODE_DB_ARCHIVE_HELPER" ]] || return 0
	days=$("$OPENCODE_DB_ARCHIVE_HELPER" retention-days 2>/dev/null) || days=0
	[[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] || return 0
	_log INFO "auto: session retention ${days} days — pruning ${OPENCODE_DB}"
	env OPENCODE_DB_PATH="$OPENCODE_DB" OPENCODE_ARCHIVE_DB="${OPENCODE_DB%/*}/opencode-archive.db" \
		"$OPENCODE_DB_ARCHIVE_HELPER" prune --older-than-days "$days" --apply --max-duration-seconds 300 || rc=$?
	if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
		_log WARN "auto: session retention prune failed (rc=${rc}, non-fatal)"
	fi
	return 0
}

cmd_auto() {
	# Children preserve the existing per-DB safety/throttle path, with independent
	# state so a recent default-DB run cannot suppress isolated DB maintenance.
	if [[ "${OPENCODE_MAINTENANCE_SINGLE_DB:-0}" != 1 ]]; then
		local db rc=0 result=0 state_dir
		while IFS= read -r -d '' db; do
			state_dir="$STATE_DIR"
			if [[ ! "$db" -ef "$OPENCODE_DB" ]]; then state_dir="${db%/*}/aidevops-maintenance"; fi
			print_info "Maintenance inventory: $db"
			rc=0
			OPENCODE_DB_PATH="$db" OPENCODE_MAINTENANCE_SINGLE_DB=1 \
				OPENCODE_MAINTENANCE_STATE_DIR="$state_dir" \
				bash "${OPENCODE_DB_MAINTENANCE_SELF}" auto "$@" || rc=$?
			[[ "$rc" -eq 0 ]] || result="$rc"
		done < <(opencode_db_inventory "$OPENCODE_DB")
		return "$result"
	fi
	# Silent no-op if opencode not installed
	if ! _opencode_installed; then
		_log INFO "auto: opencode not installed — no-op"
		return 0
	fi

	# Reclaim superseded/expired repo-layout migration DB backups (best-effort).
	_prune_layout_backups

	# Opt-in permanent session retention (storage.opencode_session_retention_days).
	# Unset/0 keeps everything; runs ahead of the throttle so the daily r922 run applies it.
	_prune_old_sessions

	# Throttle: skip if last run was recent
	if [[ -f "$STATE_FILE" ]]; then
		local last_ts_str last_epoch now_epoch delta
		if command -v jq >/dev/null 2>&1; then
			last_ts_str=$(jq -r '.timestamp // empty' "$STATE_FILE" 2>/dev/null || true)
		else
			last_ts_str=$(grep -Eo '"timestamp":[[:space:]]*"[^"]+"' "$STATE_FILE" 2>/dev/null |
				sed 's/.*"\([^"]*\)"$/\1/' || true)
		fi
		if [[ -n "$last_ts_str" ]]; then
			# Try GNU date first, then BSD date
			last_epoch=$(date -u -d "$last_ts_str" +%s 2>/dev/null ||
				date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts_str" +%s 2>/dev/null ||
				echo 0)
			now_epoch=$(date +%s)
			delta=$((now_epoch - last_epoch))
			if [[ "$delta" -lt "$AUTO_MIN_SECONDS_BETWEEN" ]]; then
				_log INFO "auto: throttled (last run ${delta}s ago, min ${AUTO_MIN_SECONDS_BETWEEN}s)"
				print_info "Skipping: last maintenance was ${delta}s ago (threshold: ${AUTO_MIN_SECONDS_BETWEEN}s)"
				return 0
			fi
		fi
	fi

	# Delegate to maintain without --force (respects active processes).
	# Exit 2 = "opencode is running, skipping" — this is expected state for
	# a scheduled routine, not a failure. Translate to exit 0 so the
	# scheduler doesn't flag it as a failed run.
	local rc=0
	cmd_maintain --auto || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		_log INFO "auto: skipped — opencode active"
		_auto_skip_record "$(_opencode_process_count)"
		if [[ "$(_auto_skip_count)" -ge "$AUTO_SKIP_ESCALATION_COUNT" ]]; then
			_interactive_holder_notify "scheduled maintenance"
		fi
		return 0
	fi
	return "$rc"
}
