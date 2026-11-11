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
# shellcheck source=pulse-dispatch-sealed-worktree.sh
source "${_DLW_SYSTEMD_MODULE_DIR}/pulse-dispatch-sealed-worktree.sh"

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

# Echo a lifecycle diagnostic field only when it is a short token. Anything
# else (paths, spaces, free text) becomes "redacted"; absent becomes "none".
_dlw_safe_diag_token() {
	local value="$1"
	if [[ -z "$value" ]]; then
		printf 'none\n'
	elif [[ ${#value} -le 80 && "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
		printf '%s\n' "$value"
	else
		printf 'redacted\n'
	fi
	return 0
}

# Log why reuse-status could not classify a candidate without exposing paths.
# Only controlled fields of the CLI error JSON are logged, never raw JSON or
# stderr; a missing or unparsable payload (e.g. Python startup failure) logs
# the caller's generic fallback reason.
_dlw_log_reuse_status_failure() {
	local issue_number="$1" rc="$2" payload="$3" fallback="$4"
	local reason="" category="" detail="" fields=""
	if [[ -n "$payload" ]] && fields=$(jq -er '[.reason // "", .category // "", .detail // ""] | map(tostring) | join("\u001f")' <<<"$payload" 2>/dev/null); then
		IFS=$'\037' read -r reason category detail <<<"$fields"
	fi
	[[ -n "$reason" ]] || reason="$fallback"
	reason=$(_dlw_safe_diag_token "$reason")
	category=$(_dlw_safe_diag_token "$category")
	detail=$(_dlw_safe_diag_token "$detail")
	echo "[dispatch_worker_launch] reuse_status_unavailable issue=#${issue_number} rc=${rc} reason=${reason} category=${category} detail=${detail}" >>"${LOGFILE:-/dev/null}"
	return 0
}

# Classify one branch-nominated candidate. Echoes "managed <generation>",
# "legacy", "sealed" or nothing (different enrolled task). Returns 1 when
# evidence is unavailable: the caller must refuse, not guess.
_dlw_classify_reuse_candidate() {
	local wt_path="$1" issue_number="$2" repo_slug="$3"
	local helper="" output="" rc=0 state_dir="" lifecycle="" reuse=""
	# GH#36920: managed/legacy matching uses a different registry. Preflight
	# lifecycle admission before ownership transfer; launch must still recheck.
	# shellcheck source=./worker-lifecycle-state.sh
	if ! source "${_DLW_SYSTEMD_MODULE_DIR}/worker-lifecycle-state.sh" ||
		! state_dir=$(worker_lifecycle_state_dir) || [[ -z "$state_dir" ]]; then
		_dlw_log_reuse_status_failure "$issue_number" 1 "" "lifecycle_state_dir_unavailable"
		return 1
	fi
	# GH#37028: on failure the CLI prints path-safe error JSON on stdout (exit
	# 2); log its controlled fields. No JSON means Python itself failed.
	lifecycle=$(python3 -E -s -B "${_DLW_SYSTEMD_MODULE_DIR}/../worker-lifecycle/worker-registry.py" \
		--state-dir "$state_dir" reuse-status --path "$wt_path" 2>/dev/null) || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_dlw_log_reuse_status_failure "$issue_number" "$rc" "$lifecycle" "reuse_status_no_diagnostic"
		return 1
	fi
	reuse=$(jq -er '.reuse' <<<"$lifecycle" 2>/dev/null) || reuse=""
	case "$reuse" in
	sealed) _dlw_classify_sealed_candidate "$wt_path" "$issue_number" "$repo_slug"; return $? ;;
	eligible) ;;
	*)
		_dlw_log_reuse_status_failure "$issue_number" 0 "" "reuse_status_unrecognized"
		return 1
		;;
	esac
	helper=$(_dlw_lifetime_helper)
	output=$(WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-}" python3 "$helper" match "$wt_path" "$issue_number" ${repo_slug:+"$repo_slug"} 2>/dev/null) || rc=$?
	case "$rc" in
	0) printf 'managed %s\n' "${output%% *}" ;;
	3) printf 'legacy\n' ;;
	4) ;;
	5) _dlw_classify_sealed_candidate "$wt_path" "$issue_number" "$repo_slug"; return $? ;;
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
	local line="" wt_path="" wt_branch="" class="" count=0 unknown=0 sealed=0 sealed_snapshot="" listing=""
	_DLW_REUSE_PATH="" _DLW_REUSE_BRANCH="" _DLW_REUSE_GENERATION="" _DLW_REUSE_REFUSAL=""
	if ! listing=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null); then
		_DLW_REUSE_REFUSAL="worktree_reuse_evidence_unavailable"
		return 2
	fi
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
			sealed_snapshot=$(_dlw_sealed_snapshot "$repo_path" "$issue_number" "$repo_slug") || sealed_snapshot=""
			if _dlw_retire_empty_sealed "$wt_path" "$wt_branch" "$repo_slug"; then
				continue
			fi
			_dlw_sealed_hold_record "$repo_path" "$issue_number" "$repo_slug" "$_DLW_SEALED_REASON" "$sealed_snapshot" || true
			sealed=$((sealed + 1))
			continue
		fi
		count=$((count + 1))
		_DLW_REUSE_PATH="$wt_path"
		_DLW_REUSE_BRANCH="$wt_branch"
		_DLW_REUSE_GENERATION=""
		[[ "$class" != managed\ * ]] || _DLW_REUSE_GENERATION="${class#managed }"
	done <<<"$listing"
	if [[ "$unknown" -gt 0 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_evidence_unavailable"
	elif [[ "$sealed" -gt 0 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_sealed_generation"
	elif [[ "$count" -gt 1 ]]; then
		_DLW_REUSE_REFUSAL="worktree_reuse_ambiguous"
	fi
	if [[ -n "$_DLW_REUSE_REFUSAL" ]]; then
		if [[ "$_DLW_REUSE_REFUSAL" != "worktree_reuse_sealed_generation" ]]; then
			echo "[dispatch_worker_launch] ${_DLW_REUSE_REFUSAL} issue=#${issue_number} candidates=${count} sealed=${sealed} unavailable=${unknown}; refusing first-match reuse. Inspect: git -C <repo> worktree list; worktree-managed-lifetime.py status <path>" >>"${LOGFILE:-/dev/null}"
		fi
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
#
# On failure, _DLW_SYSTEMD_UNAVAILABLE_REASON names the probe that failed
# (GH#37171) so the launch error line carries an actionable cause. Callers
# running this in a subshell simply do not observe the value.
_dlw_systemd_user_service_available() {
	_DLW_SYSTEMD_UNAVAILABLE_REASON=""
	if [[ "${AIDEVOPS_WORKER_BACKEND:-auto}" == "detached" ]]; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="env_detached"
		return 1
	fi
	if [[ "${AIDEVOPS_WORKER_BACKEND:-auto}" == "auto" && "${AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE:-0}" == "1" ]]; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="env_skip"
		return 1
	fi
	if [[ "$(uname -s 2>/dev/null || printf '%s' unknown)" != "Linux" ]]; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="not_linux"
		return 1
	fi
	if ! command -v systemd-run >/dev/null 2>&1; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="missing_systemd_run"
		return 1
	fi
	if ! command -v systemctl >/dev/null 2>&1; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="missing_systemctl"
		return 1
	fi
	# A degraded manager can still launch services; status conflates unrelated
	# failed units with bus availability. Query the manager itself instead.
	# Keep stderr (bus connection/timeout messages) for diagnostics only.
	local probe_err="" probe_rc=0
	probe_err=$(systemctl --user show --property=Version --value 2>&1 >/dev/null) || probe_rc=$?
	if [[ "$probe_rc" -ne 0 ]]; then
		_DLW_SYSTEMD_UNAVAILABLE_REASON="manager_probe_failed rc=${probe_rc} stderr=$(_dlw_systemd_sanitize_probe_text "$probe_err")"
		return 1
	fi
	return 0
}

# Reduce probe stderr to one bounded, log-safe token: first line only, home
# directory masked, characters outside a conservative set replaced, and at
# most 160 characters. Empty input prints "none".
_dlw_systemd_sanitize_probe_text() {
	local text="${1:-}"
	text="${text%%$'\n'*}"
	text="${text%$'\r'}"
	if [[ -n "${HOME:-}" ]]; then
		text="${text//"$HOME"/'~'}"
	fi
	text="${text//[^A-Za-z0-9 ._:,~\/()=-]/_}"
	text="${text// /_}"
	text="${text:0:160}"
	[[ -n "$text" ]] || text="none"
	printf '%s' "$text"
	return 0
}

# Print set/unset booleans for the session-bus environment; never values.
_dlw_systemd_bus_env_summary() {
	local xdg_set="no" dbus_set="no"
	[[ -z "${XDG_RUNTIME_DIR+x}" ]] || xdg_set="yes"
	[[ -z "${DBUS_SESSION_BUS_ADDRESS+x}" ]] || dbus_set="yes"
	printf 'xdg_runtime_dir_set=%s dbus_session_bus_address_set=%s' "$xdg_set" "$dbus_set"
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
		# A failed call can also mean the manager's submission reply was lost.
		# Only an explicit not-found response proves there is no unit to own;
		# an unreachable manager is inconclusive and must retain ownership.
		local load_state=""
		load_state=$(systemctl --user show "$unit_name" --property=LoadState --value 2>>"$LOGFILE") || true
		if [[ "$load_state" == "not-found" ]]; then
			printf 'LaunchState=submission_failed\n' >>"$state_file"
		else
			printf 'LaunchState=submission_unconfirmed\n' >>"$state_file"
		fi
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
		# Mirror _dlw_handle_systemd_launch_failure's classification line for
		# the pre-submission probe so the cause is visible (GH#37171).
		local unavailable_reason="${_DLW_SYSTEMD_UNAVAILABLE_REASON:-unknown}" bus_env=""
		bus_env=$(_dlw_systemd_bus_env_summary)
		printf '[systemd-launch] classification=backend_unavailable reason=%s %s\n' \
			"$unavailable_reason" "$bus_env" >>"$worker_log" 2>/dev/null || true
		echo "[dispatch_worker_launch] ERROR: selected systemd backend unavailable for #${issue_number} (reason=${unavailable_reason} ${bus_env}); detached fallback suppressed" >>"$LOGFILE"
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
			if grep -q '^LaunchState=submission_failed$' "$systemd_state_file"; then
				printf '[systemd-launch] classification=submission_failed\n'
			elif [[ "$systemd_rc" -eq 2 ]]; then
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
