#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Setup Scheduler Runtime Helpers
# =============================================================================
# Cron, launchd, and scheduler detection helpers used by setup.sh. Kept in a
# focused module so setup.sh remains a thin orchestrator while preserving the
# existing public setup.sh entrypoint.
#
# Usage: source "${SETUP_MODULES_DIR}/_scheduler_runtime.sh"
#
# Dependencies:
#   - setup.sh globals: PLATFORM_MACOS and print_* helpers at runtime
#   - bash 3.2+, launchctl (macOS), crontab, systemctl (Linux)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SETUP_SCHEDULER_RUNTIME_LOADED:-}" ]] && return 0
_SETUP_SCHEDULER_RUNTIME_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Ensure the crontab has a single PATH= line at the top with the current $PATH.
# Individual cron entries must NOT set inline PATH= — it overrides the global one
# and hardcodes system-specific paths (nvm, bun, cargo, etc.). This function
# manages a tagged comment + PATH line pair; re-running setup.sh updates it
# idempotently. The marker must be a separate comment line because crontab does
# NOT support inline comments on environment variable lines — anything after
# PATH= is treated as part of the value.
_ensure_cron_path() {
	local current_crontab marker="# aidevops-path"
	current_crontab=$(crontab -l 2>/dev/null) || current_crontab=""

	# Deduplicate PATH entries (preserving order)
	# Bash 3.2 compat: no associative arrays — use string-based seen list
	local deduped_path=""
	local seen_dirs=" "
	local IFS=':'
	for dir in $PATH; do
		if [[ -n "$dir" && "$seen_dirs" != *" ${dir} "* ]]; then
			seen_dirs="${seen_dirs}${dir} "
			deduped_path="${deduped_path:+${deduped_path}:}${dir}"
		fi
	done
	unset IFS

	# Marker on its own line, PATH on the next — crontab treats everything
	# after PATH= as the value (no inline comments)
	local path_block="${marker}
PATH=${deduped_path}"

	# Remove only the aidevops-managed marker + PATH pair.
	# User-owned PATH= lines are left untouched.
	local filtered
	filtered=$(printf '%s\n' "$current_crontab" | awk -v marker="$marker" '
		$0 == marker { drop_next_path=1; next }
		drop_next_path && /^PATH=/ { drop_next_path=0; next }
		{ drop_next_path=0; print }
	')

	if [[ -n "$filtered" ]]; then
		current_crontab="${path_block}
${filtered}"
	else
		current_crontab="$path_block"
	fi

	printf '%s\n' "$current_crontab" | crontab - 2>/dev/null || true
	return 0
}

# Check if a launchd agent is loaded (SIGPIPE-safe for pipefail, t1265)
_launchd_has_agent() {
	local label="$1"
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$label"
	return $?
}

_launchd_agent_state() {
	local label="$1"
	local state=""
	state=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | awk -F'= ' '/state =/ { print $2; exit }' || true)
	printf '%s\n' "$state"
	return 0
}

_launchd_agent_pid() {
	local label="$1"
	local pid=""
	pid=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | awk -F'= ' '/pid =/ { print $2; exit }' || true)
	printf '%s\n' "$pid"
	return 0
}

_launchd_process_args() {
	local pid="$1"
	if [[ -z "$pid" ]]; then
		return 0
	fi
	ps -p "$pid" -o args= 2>/dev/null || true
	return 0
}

_launchd_bootout_bootstrap() {
	local label="$1"
	local plist_path="$2"
	local domain
	domain="gui/$(id -u)"

	launchctl bootout "${domain}/${label}" 2>/dev/null || true
	launchctl bootstrap "$domain" "$plist_path" 2>/dev/null
	return $?
}

_launchd_recover_xpcproxy_if_stuck() {
	local label="$1"
	local plist_path="$2"
	local state
	state=$(_launchd_agent_state "$label")
	if [[ "$state" != "xpcproxy" ]]; then
		return 0
	fi
	local pid process_args
	pid=$(_launchd_agent_pid "$label")
	process_args=$(_launchd_process_args "$pid")
	if [[ -n "$process_args" && "$process_args" != *xpcproxy* ]]; then
		print_info "LaunchAgent $label reports xpcproxy but pid $pid is running: $process_args"
		return 0
	fi

	print_warning "LaunchAgent $label stuck in xpcproxy; reloading with bootout/bootstrap"
	if ! _launchd_bootout_bootstrap "$label" "$plist_path"; then
		return 1
	fi

	state=$(_launchd_agent_state "$label")
	if [[ "$state" == "xpcproxy" ]]; then
		print_warning "LaunchAgent $label still stuck in xpcproxy after recovery"
		return 1
	fi
	return 0
}

_launchd_load_agent() {
	local label="$1"
	local plist_path="$2"

	if launchctl load "$plist_path" 2>/dev/null; then
		_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
		return 0
	fi

	if _launchd_bootout_bootstrap "$label" "$plist_path"; then
		_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
		return 0
	fi
	return 1
}

_launchd_kickstart_and_recover() {
	local label="$1"
	local plist_path="$2"
	local domain
	domain="gui/$(id -u)"

	launchctl kickstart -k "${domain}/${label}" 2>/dev/null || return 1
	_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path"
	return $?
}

# Install a launchd plist only if its content has changed.
# Avoids unnecessary unload/reload which resets StartInterval timers.
# Usage: _launchd_install_if_changed <label> <plist_path> <new_content>
# Returns: 0 = installed or unchanged, 1 = failed to load
_launchd_install_if_changed() {
	local label="$1"
	local plist_path="$2"
	local new_content="$3"

	# Compare with existing plist — skip reload if identical
	if [[ -f "$plist_path" ]]; then
		local existing_content
		existing_content=$(cat "$plist_path")
		if [[ "$existing_content" == "$new_content" ]]; then
			# Ensure it's loaded even if content unchanged
			if ! _launchd_has_agent "$label"; then
				_launchd_load_agent "$label" "$plist_path" || return 1
			else
				_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
			fi
			return 0
		fi
		# Content changed — unload before replacing
		if _launchd_has_agent "$label"; then
			launchctl unload "$plist_path" 2>/dev/null || true
		fi
	fi

	# Atomic write: build at sibling tmp path, then rename into place.
	# If printf is killed mid-write, the destination is untouched.
	# mktemp avoids predictable tmp names (defense-in-depth against symlink attacks).
	local tmp_plist
	tmp_plist=$(mktemp "${plist_path}.XXXXXX") || return 1
	# Guard: refuse to write empty content — catching this before the write avoids
	# creating a tmp file that the file-size check would also catch, but the
	# content check is more direct and gives a clearer failure point.
	if [[ -z "$new_content" ]]; then
		rm -f "$tmp_plist"
		return 1
	fi
	if ! printf '%s\n' "$new_content" >"$tmp_plist"; then
		rm -f "$tmp_plist"
		return 1
	fi
	# Defensive: refuse to install an empty file (should be guaranteed by the
	# caller's content check, but guard here too).
	if [[ ! -s "$tmp_plist" ]]; then
		rm -f "$tmp_plist"
		return 1
	fi
	if ! mv -f "$tmp_plist" "$plist_path"; then
		rm -f "$tmp_plist"
		return 1
	fi
	_launchd_load_agent "$label" "$plist_path" || return 1
	return 0
}

# Detect whether a scheduler is already installed via launchd, cron, or systemd.
# Optionally migrates legacy launchd labels / cron entries to launchd on macOS.
# Args: arg1=scheduler_name, arg2=launchd_label, arg3=legacy_launchd_label,
#       arg4=cron_marker, arg5=migrate_script, arg6=migrate_arg, arg7=migrate_hint
#       arg8=systemd_unit (optional — base name without .timer suffix, e.g. "aidevops-supervisor-pulse")
_scheduler_detect_installed() {
	local scheduler_name="$1"
	local launchd_label="$2"
	local legacy_launchd_label="$3"
	local cron_marker="$4"
	local migrate_script="$5"
	local migrate_arg="$6"
	local migrate_hint="$7"
	local systemd_unit="${8:-}"
	local installed=false

	if _launchd_has_agent "$launchd_label"; then
		installed=true
	elif [[ -n "$legacy_launchd_label" ]] && _launchd_has_agent "$legacy_launchd_label"; then
		if [[ -n "$migrate_script" ]] && [[ -x "$migrate_script" ]]; then
			if bash "$migrate_script" "$migrate_arg" >/dev/null 2>&1; then
				print_info "$scheduler_name LaunchAgent migrated to new label"
			else
				print_warning "$scheduler_name label migration failed. Run: $migrate_hint"
			fi
		fi
		installed=true
	elif crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
		if [[ "$PLATFORM_MACOS" == "true" ]] && [[ -n "$migrate_script" ]] && [[ -x "$migrate_script" ]]; then
			if bash "$migrate_script" "$migrate_arg" >/dev/null 2>&1; then
				print_info "$scheduler_name migrated from cron to launchd"
			else
				print_warning "$scheduler_name cron->launchd migration failed. Run: $migrate_hint"
			fi
		fi
		installed=true
	elif [[ -n "$systemd_unit" ]] && command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled "${systemd_unit}.timer" >/dev/null 2>&1; then
		# Systemd user timer detected (GH#17381 — Linux systemd path was missing)
		installed=true
	fi

	if [[ "$installed" == "true" ]]; then
		return 0
	fi

	return 1
}
