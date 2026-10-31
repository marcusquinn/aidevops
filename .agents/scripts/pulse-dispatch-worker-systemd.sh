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
_DLW_SYSTEMD_MODULE_DIR="${BASH_SOURCE[0]%/*}"
_DLW_MANAGED_WORKTREE_MANAGER="pulse-cgroup-v1"

# Shared managed-launch contract (GH#35295). Automatic Pulse and manual
# dispatch both use these adapters; each caller keeps its own task selection,
# claims, prompt and runtime arguments. Callers set before creation/launch:
#   _DLW_LAUNCH_ENTRYPOINT  pulse | dispatch-single-issue
#   _DLW_LAUNCH_TRIGGER     scheduled | manual (needs _DLW_LAUNCH_TRIGGER_EVIDENCE)
#   _DLW_LAUNCH_TASK/_REPO  issue number and owner/repo for exact reuse identity
#   _DLW_WORKTREE_GENERATION  generation selected for reuse (reserve rechecks it)
# Unknown or missing values are recorded as unknown, never as a human trigger.
_dlw_lifetime_helper() {
	local dir="${SCRIPT_DIR:-}"
	# Sourcing entry points may own SCRIPT_DIR; fall back to this module's tree.
	[[ -n "$dir" && -f "${dir}/worktree-managed-lifetime.py" ]] || dir="$_DLW_SYSTEMD_MODULE_DIR"
	printf '%s/worktree-managed-lifetime.py\n' "$dir"
	return 0
}

_dlw_launch_env() {
	_DLW_LAUNCH_ENV=(
		"AIDEVOPS_LAUNCH_ENTRYPOINT=${_DLW_LAUNCH_ENTRYPOINT:-unknown}"
		"AIDEVOPS_LAUNCH_TRIGGER=${_DLW_LAUNCH_TRIGGER:-unknown}"
		"AIDEVOPS_LAUNCH_TRIGGER_EVIDENCE=${_DLW_LAUNCH_TRIGGER_EVIDENCE:-none}"
		"AIDEVOPS_LAUNCH_TASK=${_DLW_LAUNCH_TASK:-}"
		"AIDEVOPS_LAUNCH_REPO=${_DLW_LAUNCH_REPO:-}"
	)
	return 0
}

# Choose the lifetime backend BEFORE creating a generation. Sets
# _DLW_MANAGED_CREATE_ENV for worktree-helper.sh add: managed enrollment on the
# systemd backend, explicit legacy creation otherwise (never a later fallback).
_dlw_managed_creation_env() {
	local backend="" manager=""
	backend=$(_dlw_select_worker_backend) || return 1
	[[ "$backend" != "systemd" ]] || manager="$_DLW_MANAGED_WORKTREE_MANAGER"
	_dlw_launch_env
	_DLW_MANAGED_CREATE_ENV=("AIDEVOPS_WORKTREE_MANAGER=${manager}" "${_DLW_LAUNCH_ENV[@]}")
	_DLW_MANAGED_CREATE_MODE="$manager"
	return 0
}

# Classify one branch-nominated candidate. Echoes "managed <generation>",
# "legacy", "sealed" or nothing (different enrolled task). Returns 1 when
# evidence is unavailable: the caller must refuse, not guess.
_dlw_classify_reuse_candidate() {
	local wt_path="$1" issue_number="$2" repo_slug="$3"
	local helper="" output="" rc=0
	helper=$(_dlw_lifetime_helper)
	output=$(WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" match "$wt_path" "$issue_number" ${repo_slug:+"$repo_slug"} 2>/dev/null) || rc=$?
	case "$rc" in
	0) printf 'managed %s\n' "${output%% *}" ;;
	3) printf 'legacy\n' ;;
	4) ;;
	5) printf 'sealed\n' ;;
	*) return 1 ;;
	esac
	return 0
}

# Select the single reusable worktree for an issue. Branch names only nominate
# candidates; enrolled generations must match the exact task. Never first-match.
# Sets _DLW_REUSE_PATH, _DLW_REUSE_BRANCH, _DLW_REUSE_GENERATION ("" = legacy)
# and _DLW_REUSE_REFUSAL. Returns 0 unique, 1 none, 2 refuse (ambiguous/unknown).
# GH#36132: parse porcelain with shell builtins. Forking awk/sed per listed
# worktree cost ~2 s per dispatch on a repo with 116 linked worktrees and was
# the largest dispatcher-side precreate_worktree residual under load.
_dlw_select_issue_worktree() {
	local repo_path="$1" issue_number="$2" repo_slug="${3:-}"
	local line="" wt_path="" wt_branch="" class="" count=0 unknown=0 sealed=0
	_DLW_REUSE_PATH="" _DLW_REUSE_BRANCH="" _DLW_REUSE_GENERATION="" _DLW_REUSE_REFUSAL=""
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) wt_path="${line#worktree }"; continue ;;
		"branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
		*) continue ;;
		esac
		[[ "$wt_branch" =~ gh-?${issue_number}([^0-9]|$) && -n "$wt_path" && -d "$wt_path" ]] || continue
		if ! class=$(_dlw_classify_reuse_candidate "$wt_path" "$issue_number" "$repo_slug"); then
			unknown=$((unknown + 1))
			continue
		fi
		[[ -n "$class" ]] || continue
		if [[ "$class" == "sealed" ]]; then
			# A closed generation may still hold unpublished work for this
			# task; do not start a parallel generation beside it.
			sealed=$((sealed + 1))
			continue
		fi
		count=$((count + 1))
		_DLW_REUSE_PATH="$wt_path"
		_DLW_REUSE_BRANCH="$wt_branch"
		_DLW_REUSE_GENERATION=""
		[[ "$class" != managed\ * ]] || _DLW_REUSE_GENERATION="${class#managed }"
	done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
	if [[ "$unknown" -gt 0 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_evidence_unavailable"
	elif [[ "$sealed" -gt 0 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_sealed_generation"
	elif [[ "$count" -gt 1 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_ambiguous"
	fi
	if [[ -n "$_DLW_REUSE_REFUSAL" ]]; then
		echo "[dispatch_worker_launch] ${_DLW_REUSE_REFUSAL} issue=#${issue_number} candidates=${count} sealed=${sealed} unavailable=${unknown}; refusing first-match reuse. Inspect: git -C <repo> worktree list; worktree-managed-lifetime.py status <path>" >>"${LOGFILE:-/dev/null}"
		_DLW_REUSE_PATH="" _DLW_REUSE_BRANCH="" _DLW_REUSE_GENERATION=""
		return 2
	fi
	[[ "$count" -eq 1 ]] && return 0
	return 1
}

# Select lifecycle ownership before attempting a launch. Availability failures
# must not silently move a systemd-owned worker into its parent's cgroup.
# The legacy skip flag remains an explicit opt-in to the detached backend.
_dlw_select_worker_backend() {
	local backend="${AIDEVOPS_WORKER_BACKEND:-auto}"
	case "$backend" in
	systemd|detached) printf '%s\n' "$backend"; return 0 ;;
	auto) ;;
	*)
		echo "[dispatch_worker_launch] ERROR: unsupported worker backend: ${backend}" >>"${LOGFILE:-/dev/null}"
		return 1
		;;
	esac
	if [[ "${AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE:-0}" == "1" ]]; then
		printf 'detached\n'
	elif [[ "$(uname -s)" == "Linux" ]] && { [[ -d /run/systemd/system || -n "${INVOCATION_ID:-}" ]] || _dlw_systemd_user_service_available; }; then
		printf 'systemd\n'
	else
		printf 'detached\n'
	fi
	return 0
}

#######################################
# Return 0 when a Linux systemd user manager is available for transient
# services. `setsid` detaches workers from the pulse process group, but it
# does NOT move them out of the systemd service cgroup. On systemd pulse
# timers, long-lived children therefore remain visible as leftovers after the
# oneshot exits (GH#23073). A transient user service gives each worker an
# intentional lifecycle owner outside aidevops-supervisor-pulse.service.
_dlw_systemd_user_service_available() {
	[[ "${AIDEVOPS_WORKER_BACKEND:-auto}" == "detached" ]] && return 1
	if [[ "${AIDEVOPS_WORKER_BACKEND:-auto}" == "auto" && "${AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE:-0}" == "1" ]]; then
		return 1
	fi
	[[ "$(uname -s 2>/dev/null || printf '%s' unknown)" == "Linux" ]] || return 1
	command -v systemd-run >/dev/null 2>&1 || return 1
	command -v systemctl >/dev/null 2>&1 || return 1
	# A degraded manager can still launch services; status conflates unrelated
	# failed units with bus availability. Query the manager itself instead.
	systemctl --user show --property=Version --value >/dev/null 2>&1 || return 1
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
				echo "[dispatch_worker_launch] systemd unit ${unit_name} has no live MainPID state=${active_state:-unknown}/${sub_state:-unknown} for #${issue_number}" >>"$LOGFILE"
				return 2
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
	local -a lifetime_properties=(--collect)
	if [[ "${_DLW_MANAGED_WORKTREE:-0}" == "1" ]]; then
		local generation_suffix=""
		generation_suffix=$(python3 -c 'import uuid; print(uuid.uuid4().hex)') || return 1
		unit_name="${unit_name}-${generation_suffix}"
		# Retain exited units until the cleanup reader durably records quiescence.
		# A wrapper exit alone is not a descendant-lifetime receipt. The reserve
		# rechecks the selected generation and appends this attempt's provenance.
		local lifetime_helper=""
		lifetime_helper=$(_dlw_lifetime_helper)
		_dlw_launch_env
		env "${_DLW_LAUNCH_ENV[@]}" "AIDEVOPS_EXPECTED_GENERATION=${_DLW_WORKTREE_GENERATION:-}" \
			WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$lifetime_helper" reserve "$_DLW_WORKTREE_PATH" "$unit_name" || return 1
		local properties="" property=""
		properties=$(python3 "${lifetime_helper%/*}/worktree-managed-run.py" --print-properties) || return 1
		lifetime_properties=()
		while IFS= read -r property; do
			lifetime_properties+=("$property")
		done <<<"$properties"
		set -- env "WORKTREE_REGISTRY_DB=${WORKTREE_REGISTRY_DB:-${HOME}/.aidevops/.agent-workspace/worktree-registry.db}" \
			python3 "$lifetime_helper" bind-exec "$_DLW_WORKTREE_PATH" "$@"
	fi
	# Persist ownership before submission, including when the manager reply is
	# lost. Failure to retain that identity must prevent an untracked launch.
	printf 'Unit=%s\nLaunchState=submitting\n' "$unit_name" >"$state_file" || return 1
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

	if ! systemd-run --user --unit="$unit_name" "${lifetime_properties[@]}" --quiet \
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

# Return a ready worker PID or fail without changing lifecycle backend.
_dlw_launch_systemd_worker() {
	local worker_log="$1"
	local issue_number="$2"
	shift 2
	local state_file="${worker_log}.systemd-launch" worker_pid="" systemd_rc=0
	if ! _dlw_systemd_user_service_available; then
		echo "[dispatch_worker_launch] ERROR: selected systemd backend unavailable for #${issue_number}; detached fallback suppressed" >>"$LOGFILE"
		return 1
	fi
	if worker_pid=$(_DLW_SYSTEMD_STATE_FILE="$state_file" _dlw_exec_systemd_user_service "aidevops-worker" "$worker_log" "$issue_number" "$@"); then
		echo "[dispatch_worker_launch] Issue #${issue_number}: worker PID=$worker_pid launched via systemd-run transient user service outside pulse cgroup" >>"$LOGFILE"
		printf '%s\n' "$worker_pid"
		return 0
	else
		systemd_rc=$?
	fi
	_dlw_handle_systemd_launch_failure "$systemd_rc" "$state_file" "$worker_log" "$issue_number" || true
	return 1
}

_dlw_handle_systemd_launch_failure() {
	local systemd_rc="$1"
	local systemd_state_file="$2"
	local worker_log="$3"
	local issue_number="$4"

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
