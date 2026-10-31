#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# systemd-scope-launch.sh — launch a detached command in a transient systemd
# user scope so it leaves the caller's unit cgroup (GH#33993, GH#35760).
#
# setsid/nohup detach a process from its session and process group but keep it
# in the caller's cgroup. A Type=oneshot unit with KillMode=control-group (the
# supervisor pulse) therefore SIGTERMs such children when it stops. A scope,
# unlike a transient service, keeps the caller's environment and working
# directory, and systemd-run execs the command, so $! is the command's PID.
#
# Contract: choose the backend BEFORE launching (systemd_scope_available), then
# launch exactly once. Never relaunch after a scope launch: a fast-exiting
# command looks like a failed launch, and relaunching would run it twice.
#
# Functions in this module (in source order):
#   - systemd_scope_available
#   - systemd_scope_pid_in_scope
#   - systemd_scope_launch

[[ -n "${_SYSTEMD_SCOPE_LAUNCH_LOADED:-}" ]] && return 0
_SYSTEMD_SCOPE_LAUNCH_LOADED=1

#######################################
# Return 0 when a Linux systemd user manager can own transient scopes.
# Queries the manager itself: a degraded manager still launches units, and
# status output conflates unrelated failed units with bus availability.
#######################################
systemd_scope_available() {
	command -v systemd-run >/dev/null 2>&1 || return 1
	command -v systemctl >/dev/null 2>&1 || return 1
	[[ "$(uname -s 2>/dev/null || printf '%s' unknown)" == "Linux" ]] || return 1
	systemctl --user show --property=Version --value >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Return 0 when a PID's cgroup is the named transient scope (Linux only).
# Args: $1 = pid, $2 = scope unit name without the .scope suffix
#######################################
systemd_scope_pid_in_scope() {
	local pid="$1"
	local scope_name="$2"
	local cgroup_file="/proc/${pid}/cgroup"
	[[ -r "$cgroup_file" ]] || return 1
	grep -Fq "/${scope_name}.scope" "$cgroup_file" 2>/dev/null && return 0
	return 1
}

#######################################
# Launch a command once in its own transient user scope and report isolation.
# An early exit is not retried: the caller's own readiness/lock evidence owns
# that outcome, with systemd-run's error preserved in the log file.
# Args: $1 = scope unit name (no .scope suffix), $2 = description,
#       $3 = log file (stdout/stderr, appended), $4.. = command
# Output: "<pid> systemd_scope" when membership is confirmed, otherwise
#         "<pid> systemd_scope_unconfirmed"
# Returns: 0 once launched
#######################################
systemd_scope_launch() {
	local scope_name="$1"
	local description="$2"
	local log_file="$3"
	shift 3
	local launched_pid="" attempts=0
	local -a scope_command=(
		systemd-run --user --scope --collect --quiet
		--unit="$scope_name" --description="$description"
		"$@"
	)
	if command -v setsid >/dev/null 2>&1; then
		setsid "${scope_command[@]}" </dev/null >>"$log_file" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	else
		"${scope_command[@]}" </dev/null >>"$log_file" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	fi
	launched_pid=$!
	disown "$launched_pid" 2>/dev/null || true
	while [[ "$attempts" -lt 25 ]]; do
		if systemd_scope_pid_in_scope "$launched_pid" "$scope_name"; then
			printf '%s systemd_scope\n' "$launched_pid"
			return 0
		fi
		kill -0 "$launched_pid" 2>/dev/null || break
		sleep 0.2
		attempts=$((attempts + 1))
	done
	printf '%s systemd_scope_unconfirmed\n' "$launched_pid"
	return 0
}
