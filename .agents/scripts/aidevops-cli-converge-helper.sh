#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u

_CLI_LOCK_OWNED=false
_CLI_PROCESS_TOKEN=""
_CLI_READ_PID=""
_CLI_READ_TOKEN=""

_cli_log() {
	local level="$1"
	local message="$2"
	printf '[aidevops-cli:%s] %s\n' "$level" "$message" >&2
	return 0
}

_cli_aidevops_path() {
	local relative_path="$1"
	local aidevops_dir="${AIDEVOPS_DIR:-${HOME:+$HOME/.aidevops}}"
	[[ -n "$aidevops_dir" ]] || return 1
	printf '%s/%s\n' "$aidevops_dir" "$relative_path"
	return 0
}

_cli_warning_file() {
	if [[ -n "${AIDEVOPS_CLI_WARNING_FILE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_CLI_WARNING_FILE"
		return 0
	fi
	_cli_aidevops_path "logs/cli-convergence-warning.txt" || return 1
	return 0
}

_cli_write_warning() {
	local message="$1"
	local warning_file
	warning_file=$(_cli_warning_file)
	local warning_dir="${warning_file%/*}"
	local warning_tmp="${warning_file}.tmp.$$"

	mkdir -p "$warning_dir" 2>/dev/null || return 1
	printf '%s\n' "$message" >"$warning_tmp" || return 1
	mv -f "$warning_tmp" "$warning_file" || return 1
	_cli_log warning "$message"
	_cli_log warning "Durable remediation notice: $warning_file"
	return 0
}

_cli_clear_warning() {
	local warning_file
	warning_file=$(_cli_warning_file)
	rm -f "$warning_file" 2>/dev/null || true
	return 0
}

_cli_release_lock() {
	local lock_dir="${AIDEVOPS_CLI_LOCK_DIR:-}"
	[[ -n "$lock_dir" ]] || lock_dir=$(_cli_aidevops_path "locks/cli-launcher.lock") || return 0
	local owner_pid=""
	local owner_token=""
	if [[ "$_CLI_LOCK_OWNED" == "true" && -r "$lock_dir/initialized" ]]; then
		IFS= read -r owner_pid <"$lock_dir/pid" || owner_pid=""
		IFS= read -r owner_token <"$lock_dir/command-token" || owner_token=""
	fi
	if [[ "$owner_pid" == "$$" && "$owner_token" == "$_CLI_PROCESS_TOKEN" ]]; then
		rm -f "$lock_dir/initialized" "$lock_dir/pid" "$lock_dir/lstart" "$lock_dir/command-token" 2>/dev/null || true
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	_CLI_LOCK_OWNED=false
	return 0
}

_cli_process_lstart() {
	local pid="$1"
	local process_lstart=""
	process_lstart=$(LC_ALL=C TZ=UTC ps -ww -p "$pid" -o lstart= 2>/dev/null || true)
	process_lstart="${process_lstart#"${process_lstart%%[![:space:]]*}"}"
	printf '%s\n' "$process_lstart"
	return 0
}

_cli_process_command() {
	local pid="$1"
	LC_ALL=C TZ=UTC ps -ww -p "$pid" -o command= 2>/dev/null || true
	return 0
}

_cli_lock_owner_active() {
	local lock_dir="$1"
	local owner_pid=""
	local owner_lstart=""
	local owner_token=""
	local current_lstart=""
	local current_args=""

	[[ -r "$lock_dir/initialized" && -r "$lock_dir/pid" && -r "$lock_dir/lstart" && -r "$lock_dir/command-token" ]] || return 2
	IFS= read -r owner_pid <"$lock_dir/pid" || owner_pid=""
	IFS= read -r owner_lstart <"$lock_dir/lstart" || owner_lstart=""
	IFS= read -r owner_token <"$lock_dir/command-token" || owner_token=""
	[[ "$owner_pid" =~ ^[0-9]+$ && -n "$owner_lstart" && -n "$owner_token" ]] || return 1
	kill -0 "$owner_pid" 2>/dev/null || return 1
	current_lstart=$(_cli_process_lstart "$owner_pid")
	current_args=$(_cli_process_command "$owner_pid")
	[[ "$current_lstart" == "$owner_lstart" && "$current_args" == *"$owner_token"* ]]
	return $?
}

_cli_release_reclaim_mutex() {
	local reclaim_dir="$1"
	local owner_pid=""
	local owner_token=""
	if [[ -r "$reclaim_dir/initialized" ]]; then
		IFS= read -r owner_pid <"$reclaim_dir/pid" || owner_pid=""
		IFS= read -r owner_token <"$reclaim_dir/command-token" || owner_token=""
	fi
	if [[ "$owner_pid" == "$$" && "$owner_token" == "$_CLI_PROCESS_TOKEN" ]]; then
		rm -f "$reclaim_dir/initialized" "$reclaim_dir/pid" "$reclaim_dir/lstart" "$reclaim_dir/command-token" 2>/dev/null || true
		rmdir "$reclaim_dir" 2>/dev/null || true
	fi
	return 0
}

_cli_read_lock_identity() {
	local lock_dir="$1"

	_CLI_READ_PID=""
	_CLI_READ_TOKEN=""
	[[ -r "$lock_dir/pid" ]] && IFS= read -r _CLI_READ_PID <"$lock_dir/pid" || _CLI_READ_PID=""
	[[ -r "$lock_dir/command-token" ]] && IFS= read -r _CLI_READ_TOKEN <"$lock_dir/command-token" || _CLI_READ_TOKEN=""
	return 0
}

_cli_initialize_lock_dir() {
	local lock_dir="$1"
	local process_lstart=""

	process_lstart=$(_cli_process_lstart "$$")
	if [[ -z "$process_lstart" || -z "$_CLI_PROCESS_TOKEN" ]] ||
		! printf '%s\n' "$$" >"$lock_dir/pid" ||
		! printf '%s\n' "$process_lstart" >"$lock_dir/lstart" ||
		! printf '%s\n' "$_CLI_PROCESS_TOKEN" >"$lock_dir/command-token" ||
		! : >"$lock_dir/initialized"; then
		rm -f "$lock_dir/initialized" "$lock_dir/pid" "$lock_dir/lstart" "$lock_dir/command-token" 2>/dev/null || true
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	return 0
}

_cli_acquire_reclaim_mutex() {
	local reclaim_dir="$1"
	local grace_seconds="${AIDEVOPS_CLI_RECLAIM_GRACE_SECONDS:-2}"
	local waited=0
	local lock_state=0
	local observed_pid=""
	local observed_token=""
	local current_pid=""
	local current_token=""

	while ! mkdir "$reclaim_dir" 2>/dev/null; do
		lock_state=0
		_cli_lock_owner_active "$reclaim_dir" || lock_state=$?
		if [[ "$lock_state" -eq 0 ]]; then
			return 1
		fi
		if [[ "$waited" -lt "$grace_seconds" ]]; then
			sleep 1
			waited=$((waited + 1))
			continue
		fi
		_cli_read_lock_identity "$reclaim_dir"
		observed_pid="$_CLI_READ_PID"
		observed_token="$_CLI_READ_TOKEN"
		lock_state=0
		_cli_lock_owner_active "$reclaim_dir" || lock_state=$?
		if [[ "$lock_state" -eq 0 ]]; then
			return 1
		fi
		_cli_read_lock_identity "$reclaim_dir"
		current_pid="$_CLI_READ_PID"
		current_token="$_CLI_READ_TOKEN"
		if [[ "$current_pid" != "$observed_pid" || "$current_token" != "$observed_token" ]]; then
			waited=0
			continue
		fi
		rm -f "$reclaim_dir/initialized" "$reclaim_dir/pid" "$reclaim_dir/lstart" "$reclaim_dir/command-token" 2>/dev/null || true
		rmdir "$reclaim_dir" 2>/dev/null || true
		waited=0
	done

	_cli_initialize_lock_dir "$reclaim_dir"
	return $?
}

_cli_try_reclaim_lock() {
	local lock_dir="$1"
	local observed_pid="$2"
	local observed_token="$3"
	local observed_initialized="$4"
	local reclaim_dir="${lock_dir}.reclaim"
	local current_pid=""
	local current_token=""
	local current_initialized=false
	local lock_state=0

	_cli_acquire_reclaim_mutex "$reclaim_dir" || return 1
	[[ -r "$lock_dir/pid" ]] && IFS= read -r current_pid <"$lock_dir/pid" || current_pid=""
	[[ -r "$lock_dir/command-token" ]] && IFS= read -r current_token <"$lock_dir/command-token" || current_token=""
	[[ -r "$lock_dir/initialized" ]] && current_initialized=true
	if [[ "$current_pid" != "$observed_pid" || "$current_token" != "$observed_token" || "$current_initialized" != "$observed_initialized" ]]; then
		_cli_release_reclaim_mutex "$reclaim_dir"
		return 1
	fi
	if [[ "$current_initialized" == "true" ]]; then
		lock_state=0
		_cli_lock_owner_active "$lock_dir" || lock_state=$?
		if [[ "$lock_state" -eq 0 ]]; then
			_cli_release_reclaim_mutex "$reclaim_dir"
			return 1
		fi
	fi
	rm -f "$lock_dir/initialized" "$lock_dir/pid" "$lock_dir/lstart" "$lock_dir/command-token" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	_cli_release_reclaim_mutex "$reclaim_dir"
	return 0
}

_cli_acquire_lock() {
	local lock_dir="${AIDEVOPS_CLI_LOCK_DIR:-}"
	[[ -n "$lock_dir" ]] || lock_dir=$(_cli_aidevops_path "locks/cli-launcher.lock") || return 1
	local lock_parent="${lock_dir%/*}"
	local wait_seconds="${AIDEVOPS_CLI_LOCK_WAIT_SECONDS:-30}"
	local incomplete_grace="${AIDEVOPS_CLI_INCOMPLETE_GRACE_SECONDS:-2}"
	local waited=0
	local incomplete_waited=0
	local lock_state=0
	local observed_pid=""
	local observed_token=""
	local observed_initialized=false

	mkdir -p "$lock_parent" || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		observed_initialized=false
		_cli_read_lock_identity "$lock_dir"
		observed_pid="$_CLI_READ_PID"
		observed_token="$_CLI_READ_TOKEN"
		[[ -r "$lock_dir/initialized" ]] && observed_initialized=true
		lock_state=0
		_cli_lock_owner_active "$lock_dir" || lock_state=$?
		if [[ "$lock_state" -eq 1 ]]; then
			if _cli_try_reclaim_lock "$lock_dir" "$observed_pid" "$observed_token" "$observed_initialized"; then
				incomplete_waited=0
				continue
			fi
		elif [[ "$lock_state" -eq 2 ]]; then
			incomplete_waited=$((incomplete_waited + 1))
			if [[ "$incomplete_waited" -ge "$incomplete_grace" ]] &&
				_cli_try_reclaim_lock "$lock_dir" "$observed_pid" "$observed_token" "$observed_initialized"; then
				incomplete_waited=0
				continue
			fi
		else
			incomplete_waited=0
		fi
		if [[ "$waited" -ge "$wait_seconds" ]]; then
			_cli_write_warning "CLI launcher convergence timed out waiting for lock $lock_dir. Re-run setup after the active deployment finishes." || true
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	_cli_initialize_lock_dir "$lock_dir" || return 1
	_CLI_LOCK_OWNED=true
	return 0
}

_cli_files_match() {
	local source_file="$1"
	local target_file="$2"
	[[ -f "$target_file" && -x "$target_file" ]] || return 1
	cmp -s "$source_file" "$target_file"
	return $?
}

_cli_install_atomic() {
	local source_file="$1"
	local target_file="$2"
	local privilege_mode="${3:-none}"
	local target_dir="${target_file%/*}"
	local target_tmp="${target_file}.tmp.$$"

	if [[ "$privilege_mode" == "sudo-n" ]]; then
		sudo -n install -m 0755 "$source_file" "$target_tmp" || return 1
		if sudo -n mv -f "$target_tmp" "$target_file"; then
			return 0
		fi
		sudo -n rm -f "$target_tmp" 2>/dev/null || true
		return 1
	fi
	if [[ "$privilege_mode" == "sudo" ]]; then
		sudo install -m 0755 "$source_file" "$target_tmp" || return 1
		if sudo mv -f "$target_tmp" "$target_file"; then
			return 0
		fi
		sudo rm -f "$target_tmp" 2>/dev/null || true
		return 1
	fi

	mkdir -p "$target_dir" || return 1
	install -m 0755 "$source_file" "$target_tmp" || return 1
	if mv -f "$target_tmp" "$target_file"; then
		return 0
	fi
	rm -f "$target_tmp" 2>/dev/null || true
	return 1
}

_cli_global_dir_writable() {
	local global_dir="$1"
	if [[ "${AIDEVOPS_CLI_FORCE_GLOBAL_UNWRITABLE:-0}" == "1" ]]; then
		return 1
	fi
	[[ -w "$global_dir" ]]
	return $?
}

_cli_verify() {
	local source_file="$1"
	local version_file="$2"
	local expected_version=""
	local resolved=""
	local version_output=""

	IFS= read -r expected_version <"$version_file" || expected_version=""
	hash -r 2>/dev/null || true
	resolved=$(command -v aidevops 2>/dev/null || true)
	if [[ -z "$resolved" || ! -x "$resolved" ]]; then
		_cli_write_warning "CLI convergence failed: command -v aidevops did not resolve an executable. Ensure ~/.local/bin or /usr/local/bin is on PATH, then re-run setup." || true
		return 1
	fi
	if ! _cli_files_match "$source_file" "$resolved"; then
		_cli_write_warning "CLI convergence failed: command -v aidevops resolves to stale launcher $resolved. Re-run interactive setup to replace the earlier PATH entry." || true
		return 1
	fi
	version_output=$("$resolved" --version 2>/dev/null || true)
	if [[ "$version_output" != "aidevops $expected_version" && "$version_output" != "aidevops $expected_version"$'\n'* ]]; then
		_cli_write_warning "CLI convergence failed: $resolved does not report deployed version $expected_version. Re-run setup after checking ~/.aidevops/agents/VERSION." || true
		return 1
	fi
	_cli_clear_warning
	_cli_log success "Resolved $resolved reports deployed version $expected_version"
	return 0
}

_cli_converge_locked() {
	local source_file="$1"
	local orchestrator_source="$2"
	local orchestrator_target="$3"
	local version_file="$4"
	local global_target="${AIDEVOPS_CLI_GLOBAL_TARGET:-/usr/local/bin/aidevops}"
	local user_target="${AIDEVOPS_CLI_USER_TARGET:-${HOME:+$HOME/.local/bin/aidevops}}"
	local global_dir="${global_target%/*}"
	local non_interactive="${AIDEVOPS_CLI_NON_INTERACTIVE:-true}"

	if ! _cli_files_match "$orchestrator_source" "$orchestrator_target"; then
		_cli_install_atomic "$orchestrator_source" "$orchestrator_target" || return 1
		_cli_log success "Installed deployed CLI orchestrator at $orchestrator_target"
	else
		_cli_log info "Deployed CLI orchestrator is already current"
	fi

	if _cli_files_match "$source_file" "$global_target"; then
		_cli_log info "Global launcher is already current"
	elif _cli_global_dir_writable "$global_dir"; then
		_cli_install_atomic "$source_file" "$global_target" || return 1
		_cli_log success "Installed current launcher at $global_target"
	elif [[ -e "$global_target" ]]; then
		if [[ "$non_interactive" == "true" ]]; then
			if _cli_install_atomic "$source_file" "$global_target" sudo-n; then
				_cli_log success "Replaced stale privileged launcher at $global_target"
			else
				_cli_install_atomic "$source_file" "$user_target" || return 1
				_cli_log info "sudo -n unavailable; installed current user launcher at $user_target"
				_cli_verify "$source_file" "$version_file"
				return $?
			fi
		elif _cli_install_atomic "$source_file" "$global_target" sudo; then
			_cli_log success "Replaced stale privileged launcher at $global_target"
		else
			_cli_write_warning "Could not replace stale privileged launcher $global_target. Re-run interactive setup after confirming sudo access." || true
			return 1
		fi
	else
		_cli_install_atomic "$source_file" "$user_target" || return 1
		_cli_log success "Installed current user launcher at $user_target"
	fi

	_cli_verify "$source_file" "$version_file"
	return $?
}

main() {
	local action="${1:-}"
	local source_file="${2:-}"
	local orchestrator_source="${3:-}"
	local orchestrator_target="${4:-}"
	local version_file="${5:-}"

	if [[ "$action" != "converge" || ! -f "$source_file" || ! -f "$orchestrator_source" || -z "$orchestrator_target" || ! -r "$version_file" ]]; then
		printf 'Usage: %s converge <launcher-source> <orchestrator-source> <deployed-orchestrator> <deployed-version-file>\n' "$0" >&2
		return 2
	fi
	_cli_acquire_lock || return 1
	trap '_cli_release_lock' EXIT HUP INT TERM
	_cli_converge_locked "$source_file" "$orchestrator_source" "$orchestrator_target" "$version_file"
	local converge_rc=$?
	_cli_release_lock
	trap - EXIT HUP INT TERM
	return "$converge_rc"
}

if [[ "${1:-}" != "--lock-token" ]]; then
	_cli_reexec_token="aidevops-cli-lock-$$-${RANDOM}-$(date +%s)"
	exec "$0" --lock-token "$_cli_reexec_token" "$@"
fi
_CLI_PROCESS_TOKEN="${2:-}"
shift 2
main "$@"
