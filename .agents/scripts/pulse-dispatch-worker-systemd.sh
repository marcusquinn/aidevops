#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-worker-systemd.sh — Linux systemd user-service worker launch.
#
# Extracted from pulse-dispatch-worker-launch.sh (GH#28839) to bring that file
# below the 2000-line simplification gate. Sourced by
# pulse-dispatch-worker-launch.sh; callers use _dlw_exec_detached there.
#
# Functions in this module (in source order):
#   - _dlw_systemd_user_service_available
#   - _dlw_systemd_unit_name
#   - _dlw_systemd_snapshot
#   - _dlw_systemd_wait_stable
#   - _dlw_systemd_resolve_main_pid
#   - _dlw_exec_systemd_user_service
#   - _dlw_handle_systemd_launch_failure

[[ -n "${_PULSE_DISPATCH_WORKER_SYSTEMD_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_SYSTEMD_LOADED=1

#######################################
# Return 0 when a Linux systemd user manager is available for transient
# services. `setsid` detaches workers from the pulse process group, but it
# does NOT move them out of the systemd service cgroup. On systemd pulse
# timers, long-lived children therefore remain visible as leftovers after the
# oneshot exits (GH#23073). A transient user service gives each worker an
# intentional lifecycle owner outside aidevops-supervisor-pulse.service.
_dlw_systemd_user_service_available() {
	[[ "${AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE:-0}" == "1" ]] && return 1
	[[ "$(uname -s 2>/dev/null || printf '%s' unknown)" == "Linux" ]] || return 1
	command -v systemd-run >/dev/null 2>&1 || return 1
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user status >/dev/null 2>&1 || return 1
	return 0
}

_dlw_systemd_unit_name() {
	local unit_prefix="$1"
	local issue_number="$2"
	local suffix="${RANDOM:-0}"
	printf '%s-%s-%s-%s' "$unit_prefix" "${issue_number:-unknown}" "$$" "$suffix"
	return 0
}

_dlw_systemd_snapshot() {
	local unit_name="$1"
	local state_file="$2"
	local snapshot=""

	snapshot=$(systemctl --user show "$unit_name" \
		-p Id -p MainPID -p ActiveState -p SubState \
		-p ExecMainCode -p ExecMainStatus -p Result 2>/dev/null || true)
	printf 'Unit=%s\n%s\n' "$unit_name" "$snapshot" >"$state_file"
	printf '%s\n' "$snapshot"
	return 0
}

_dlw_systemd_wait_stable() {
	local unit_name="$1"
	local issue_number="$2"
	local state_file="$3"
	local expected_pid="$4"
	local attempts="${DLW_SYSTEMD_STABILITY_ATTEMPTS:-3}"
	local wait_i=0 stable_count=0 snapshot="" main_pid="" active_state="" sub_state=""
	local exec_main_code="" exec_main_status="" result="" key="" value=""
	local poll_seconds="${DLW_SYSTEMD_STABILITY_POLL_SECONDS:-0.2}"

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll_seconds="0.2"
	while [[ "$wait_i" -lt "$attempts" ]]; do
		snapshot=$(_dlw_systemd_snapshot "$unit_name" "$state_file")
		main_pid=""
		active_state=""
		sub_state=""
		exec_main_code="" exec_main_status="" result=""
		while IFS='=' read -r key value || [[ -n "$key" ]]; do
			case "$key" in
				MainPID) main_pid="$value" ;;
				ActiveState) active_state="$value" ;;
				SubState) sub_state="$value" ;;
				ExecMainCode) exec_main_code="$value" ;;
				ExecMainStatus) exec_main_status="$value" ;;
				Result) result="$value" ;;
			esac
		done <<<"$snapshot"

		if [[ "$active_state" == "failed" || "$active_state" == "inactive" ]]; then
			printf 'LaunchState=startup_failed\n' >>"$state_file"
			echo "[dispatch_worker_launch] systemd startup_failed unit=${unit_name} issue=${issue_number} MainPID=${main_pid:-0} ExecMainCode=${exec_main_code:-unknown} ExecMainStatus=${exec_main_status:-unknown} Result=${result:-unknown} state=${active_state:-unknown}/${sub_state:-unknown}" >>"$LOGFILE"
			return 2
		fi

		if [[ "$main_pid" == "$expected_pid" && "$active_state" == "active" && "$sub_state" == "running" ]]; then
			stable_count=$((stable_count + 1))
		else
			stable_count=0
		fi
		wait_i=$((wait_i + 1))
		[[ "$stable_count" -ge "$attempts" ]] && {
			printf 'LaunchState=worker_ready\n' >>"$state_file"
			return 0
		}
		sleep "$poll_seconds"
	done

	printf 'LaunchState=pid_observed\n' >>"$state_file"
	return 3
}

_dlw_systemd_resolve_main_pid() {
	local unit_name="$1"
	local issue_number="$2"
	local state_file="${3:-${TMPDIR:-/tmp}/aidevops-systemd-state.$$}"
	local wait_i=0 snapshot="" main_pid="" active_state="" sub_state="" key="" value=""

	while [[ "$wait_i" -lt 15 ]]; do
		snapshot=$(_dlw_systemd_snapshot "$unit_name" "$state_file")
		main_pid=""
		active_state=""
		sub_state=""
		while IFS='=' read -r key value || [[ -n "$key" ]]; do
			case "$key" in
				MainPID)
					main_pid="$value"
					;;
				ActiveState)
					active_state="$value"
					;;
				SubState)
					sub_state="$value"
					;;
			esac
		done <<<"$snapshot"

		if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
			echo "[dispatch_worker_launch] WARNING: systemd worker PID handoff missing for unit ${unit_name}; resolved MainPID=${main_pid} state=${active_state:-unknown}/${sub_state:-unknown} via systemctl, not launching fallback" >>"$LOGFILE"
			local stable_rc=0
			if _dlw_systemd_wait_stable "$unit_name" "$issue_number" "$state_file" "$main_pid"; then
				printf '%s\n' "$main_pid"
				return 0
			else
				stable_rc=$?
			fi
			return "$stable_rc"
		fi

		case "${active_state:-unknown}" in
			inactive|failed)
				echo "[dispatch_worker_launch] systemd unit ${unit_name} has no live MainPID state=${active_state:-unknown}/${sub_state:-unknown}; falling back to setsid/nohup for #${issue_number}" >>"$LOGFILE"
				return 1
				;;
		esac

		sleep 0.2
		wait_i=$((wait_i + 1))
	done

	echo "[dispatch_worker_launch] ERROR: systemd-run launched ${unit_name} for #${issue_number} but no child PID or live MainPID was reported" >>"$LOGFILE"
	return 1
}

_dlw_exec_systemd_user_service() {
	local unit_prefix="$1"
	local worker_log="$2"
	local issue_number="$3"
	shift 3
	local state_file="${_DLW_SYSTEMD_STATE_FILE:-${TMPDIR:-/tmp}/aidevops-systemd-state.$$}"

	local pid_file=""
	pid_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-systemd-worker.XXXXXX") || return 1
	rm -f "$pid_file" 2>/dev/null || true

	local unit_name=""
	unit_name=$(_dlw_systemd_unit_name "$unit_prefix" "$issue_number")
	local runner_script
	# shellcheck disable=SC2016  # Expanded by the child bash launched by systemd-run.
	runner_script='
		_dlw_systemd_child() {
			local pid_file="$1" out_log="$2"
			shift 2
			printf "%s\n" "$$" >"$pid_file" 2>/dev/null || true
			exec "$@" </dev/null >>"$out_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
		}
		_dlw_systemd_child "$@"
	'

	if ! systemd-run --user --unit="$unit_name" --collect --quiet \
		--description="aidevops worker ${issue_number:-unknown}" \
		/usr/bin/env bash -lc "$runner_script" _ "$pid_file" "$worker_log" "$@" \
		>/dev/null 2>>"$LOGFILE"; then
		rm -f "$pid_file" 2>/dev/null || true
		return 1
	fi

	local wait_i=0 service_pid=""
	while [[ "$wait_i" -lt 25 ]]; do
		if [[ -s "$pid_file" ]]; then
			read -r service_pid <"$pid_file" || service_pid=""
			break
		fi
		sleep 0.2
		wait_i=$((wait_i + 1))
	done
	rm -f "$pid_file" 2>/dev/null || true

	if [[ "$service_pid" =~ ^[0-9]+$ ]]; then
		echo "[dispatch_worker_launch] systemd unit ${unit_name} reported child PID=${service_pid} for #${issue_number}" >>"$LOGFILE"
		local stable_rc=0
		if _dlw_systemd_wait_stable "$unit_name" "$issue_number" "$state_file" "$service_pid"; then
			printf '%s\n' "$service_pid"
			return 0
		else
			stable_rc=$?
		fi
		return "$stable_rc"
	fi

	_dlw_systemd_resolve_main_pid "$unit_name" "$issue_number" "$state_file"
	return $?
}

_dlw_handle_systemd_launch_failure() {
	local systemd_rc="$1"
	local systemd_state_file="$2"
	local worker_log="$3"
	local issue_number="$4"

	if [[ "$systemd_rc" -ne 2 && "$systemd_rc" -ne 3 ]]; then
		echo "[dispatch_worker_launch] WARNING: systemd-run worker launch unresolved for #${issue_number}; falling back to setsid/nohup" >>"$LOGFILE"
		return 0
	fi

	if [[ -f "$systemd_state_file" ]]; then
		{
			if [[ "$systemd_rc" -eq 2 ]]; then
				printf '[systemd-launch] classification=crash_during_startup\n'
			else
				printf '[systemd-launch] classification=readiness_unconfirmed\n'
			fi
			cat "$systemd_state_file"
		} >>"$worker_log"
	fi
	echo "[dispatch_worker_launch] ERROR: systemd worker for #${issue_number} did not reach durable readiness (rc=${systemd_rc}); duplicate fallback suppressed" >>"$LOGFILE"
	return 1
}
