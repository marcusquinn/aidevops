#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Idempotent, owner-safe development server launcher for saved profiles.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_LOCALDEV_SERVE_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_SERVE_LIB_LOADED=1

SERVE_CHILD_PID=""
SERVE_EXISTING=0
SERVE_LAUNCH_LOCK=""
SERVE_LOCK_HELD=0

_serve_usage() {
	print_error "Usage: localdev-helper.sh serve --port <port> [options] -- <command...>"
	print_info "Options: --name, --root, --lock, --health-url, --startup-timeout, --no-host"
	return 1
}

_serve_parse_value() {
	local flag="$1"
	local value="${2:-}"
	if [[ -z "$value" ]]; then
		print_error "$flag requires a value"
		return 1
	fi
	printf '%s\n' "$value"
	return 0
}

_serve_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--name)
			name="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--port)
			port="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--root)
			root="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--lock)
			stale_lock="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--health-url)
			health_url="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--startup-timeout)
			startup_timeout="$(_serve_parse_value "$arg" "${2:-}")" || return 1
			shift 2
			;;
		--no-host)
			set_host=0
			shift
			;;
		--)
			shift
			cmd_args+=("$@")
			break
			;;
		-*)
			print_error "Unknown serve option: $arg"
			return 1
			;;
		*)
			cmd_args+=("$@")
			break
			;;
		esac
	done
	return 0
}

# Succeeds when $1 is an IPv4 address configured on a local interface.
# AIDEVOPS_LOCALDEV_LOCAL_ADDRS (space-separated) overrides detection for tests.
_serve_ip_is_local() {
	local ip="$1"
	local addrs=""
	if [[ -n "${AIDEVOPS_LOCALDEV_LOCAL_ADDRS+x}" ]]; then
		addrs="$AIDEVOPS_LOCALDEV_LOCAL_ADDRS"
	elif command -v ifconfig >/dev/null 2>&1; then
		addrs="$(ifconfig 2>/dev/null | awk '$1 == "inet" {print $2}')"
	elif command -v ip >/dev/null 2>&1; then
		addrs="$(ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')"
	fi
	local addr
	for addr in $addrs; do
		[[ "$addr" == "$ip" ]] && return 0
	done
	return 1
}

# Succeeds when $1 is http://<RFC1918 IPv4 on a local interface>:<port>[/...].
_serve_private_health_url() {
	local url="$1"
	local port="$2"
	local rest="${url#http://}"
	[[ "$rest" == "$url" ]] && return 1
	local hostport="${rest%%/*}"
	[[ "$hostport" == "${hostport%:*}:${port}" ]] || return 1
	local host="${hostport%:*}"
	local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
	[[ "$host" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]] || return 1
	local o1="${BASH_REMATCH[1]}"
	local o2="${BASH_REMATCH[2]}"
	if [[ "$o1" -eq 10 ]] || { [[ "$o1" -eq 192 ]] && [[ "$o2" -eq 168 ]]; } ||
		{ [[ "$o1" -eq 172 ]] && [[ "$o2" -ge 16 ]] && [[ "$o2" -le 31 ]]; }; then
		_serve_ip_is_local "$host"
		return $?
	fi
	return 1
}

_serve_validate_args() {
	local port="$1"
	local startup_timeout="$2"
	local command_count="$3"
	local health_url="$4"
	if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
		print_error "Invalid or missing --port: ${port:-<empty>}"
		return 1
	fi
	if [[ ! "$startup_timeout" =~ ^[0-9]+$ ]] || [[ "$startup_timeout" -lt 1 ]] || [[ "$startup_timeout" -gt 900 ]]; then
		print_error "Invalid --startup-timeout: $startup_timeout (expected 1-900)"
		return 1
	fi
	if [[ "$command_count" -eq 0 ]]; then
		_serve_usage
		return 1
	fi
	if ! command -v lsof >/dev/null 2>&1; then
		print_error "lsof is required for owner-safe port inspection"
		return 1
	fi
	if [[ -n "$health_url" ]] && ! command -v curl >/dev/null 2>&1; then
		print_error "curl is required when --health-url is supplied"
		return 1
	fi
	if [[ -n "$health_url" ]] && ! _serve_private_health_url "$health_url" "$port"; then
		case "$health_url" in
		"http://127.0.0.1:${port}" | "http://127.0.0.1:${port}/"* | \
			"http://localhost:${port}" | "http://localhost:${port}/"* | \
			"http://[::1]:${port}" | "http://[::1]:${port}/"*) ;;
		*)
			print_error "--health-url must use this port on localhost: $port"
			return 1
			;;
		esac
	fi
	return 0
}

_serve_canonical_root() {
	local root="$1"
	if [[ ! -d "$root" ]]; then
		print_error "Project root does not exist: $root"
		return 1
	fi
	local canonical_root=""
	canonical_root="$(cd "$root" && pwd -P)" || return 1
	if [[ "$canonical_root" == "/" ]]; then
		print_error "Project root cannot be the filesystem root"
		return 1
	fi
	printf '%s\n' "$canonical_root"
	return 0
}

_serve_listener_pids() {
	local port="$1"
	local output=""
	local status=0
	output="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)" || status=$?
	if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
		print_error "Unable to inspect port $port (lsof exit $status)"
		return 1
	fi
	if [[ -z "$output" && -d /proc ]] && command -v ss >/dev/null 2>&1; then
		local ss_output=""
		local ss_status=0
		ss_output="$(ss -H -ltnp "sport = :$port" 2>/dev/null)" || ss_status=$?
		if [[ "$ss_status" -ne 0 ]]; then
			print_error "Unable to inspect port $port (ss exit $ss_status)"
			return 1
		fi
		if [[ -n "$ss_output" ]]; then
			output="$(printf '%s\n' "$ss_output" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
			if [[ -z "$output" ]]; then
				print_error "Unable to identify the listener owner on port $port"
				return 1
			fi
		fi
	fi
	[[ -n "$output" ]] && printf '%s\n' "$output"
	return 0
}

_serve_process_cwd() {
	local pid="$1"
	local process_cwd=""
	process_cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{sub(/^n/, ""); print; exit}')"
	if [[ -z "$process_cwd" && -L "/proc/$pid/cwd" ]]; then
		process_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || process_cwd=""
	fi
	if [[ -n "$process_cwd" ]]; then
		(cd "$process_cwd" 2>/dev/null && pwd -P) || true
	fi
	return 0
}

_serve_validate_owners() {
	local listener_pids="$1"
	local root="$2"
	local pid=""
	local owner_cwd=""
	while IFS= read -r pid; do
		[[ -z "$pid" ]] && continue
		owner_cwd="$(_serve_process_cwd "$pid")"
		case "$owner_cwd" in
		"$root" | "$root"/*) ;;
		*)
			print_error "Port owner PID $pid is outside project root: ${owner_cwd:-unknown}"
			return 1
			;;
		esac
	done <<<"$listener_pids"
	return 0
}

_serve_health_ready() {
	local health_url="$1"
	[[ -z "$health_url" ]] && return 0
	curl --fail --silent --output /dev/null --noproxy '*' --connect-timeout 2 --max-time 5 "$health_url"
	return $?
}

_serve_check_existing() {
	local port="$1"
	local root="$2"
	local health_url="$3"
	local allow_unhealthy="${4:-0}"
	local announce="${5:-1}"
	local listener_pids=""
	SERVE_EXISTING=0
	listener_pids="$(_serve_listener_pids "$port")" || return 1
	[[ -z "$listener_pids" ]] && return 0
	_serve_validate_owners "$listener_pids" "$root" || return 1
	if ! _serve_health_ready "$health_url"; then
		[[ "$allow_unhealthy" -eq 1 ]] && return 0
		print_error "Owned listener on port $port is unhealthy; stop it explicitly before restarting"
		return 1
	fi
	SERVE_EXISTING=1
	[[ "$announce" -eq 1 ]] && print_success "Reusing $name on port $port"
	return 0
}

_serve_resolve_stale_lock() {
	local root="$1"
	local stale_lock="$2"
	local candidate=""
	local parent=""
	local relative=""
	local ancestor=""
	local next_ancestor=""
	local canonical_ancestor=""
	[[ -z "$stale_lock" ]] && return 0
	case "$stale_lock" in
	/*)
		case "$stale_lock" in
		"$root"/*)
			candidate="$stale_lock"
			relative="${stale_lock#"$root"/}"
			;;
		*)
			print_error "Refusing stale-lock path outside project root: $stale_lock"
			return 1
			;;
		esac
		;;
	*)
		candidate="$root/$stale_lock"
		relative="$stale_lock"
		;;
	esac
	case "/$relative/" in
	*/../*)
		print_error "Refusing stale-lock path outside project root: $stale_lock"
		return 1
		;;
	esac
	parent="$(dirname "$candidate")"
	ancestor="$parent"
	while [[ ! -d "$ancestor" ]]; do
		next_ancestor="$(dirname "$ancestor")"
		[[ "$next_ancestor" == "$ancestor" ]] && return 1
		ancestor="$next_ancestor"
	done
	canonical_ancestor="$(cd "$ancestor" && pwd -P)" || return 1
	case "$canonical_ancestor" in
	"$root" | "$root"/*) ;;
	*)
		print_error "Refusing stale-lock path outside project root: $candidate"
		return 1
		;;
	esac
	[[ ! -e "$candidate" && ! -L "$candidate" ]] && return 0
	printf '%s/%s\n' "$canonical_ancestor" "$(basename "$candidate")"
	return 0
}

_serve_cleanup_launch_lock() {
	if [[ "$SERVE_LOCK_HELD" -eq 1 && -n "$SERVE_LAUNCH_LOCK" ]]; then
		rm -f -- "$SERVE_LAUNCH_LOCK/pid"
		rmdir "$SERVE_LAUNCH_LOCK" 2>/dev/null || true
		SERVE_LOCK_HELD=0
	fi
	return 0
}

_serve_remove_stale_launch_lock() {
	local lock_dir="$1"
	local holder_pid=""
	local modified_at=""
	local now=""
	local age=0
	[[ -f "$lock_dir/pid" ]] && IFS= read -r holder_pid <"$lock_dir/pid" || true
	if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
		return 1
	fi
	# Do not reclaim a just-created directory before its owner writes the PID.
	modified_at="$(_file_mtime_epoch "$lock_dir")" || return 1
	now="$(date +%s)"
	[[ "$modified_at" =~ ^[0-9]+$ ]] || return 1
	age=$((now - modified_at))
	[[ "$age" -ge 5 ]] || return 1
	rm -f -- "$lock_dir/pid"
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_serve_acquire_launch_lock() {
	local port="$1"
	local startup_timeout="$2"
	local lock_root="${LOCALDEV_DIR:-$HOME/.local-dev-proxy}/run-locks"
	local attempts=$((startup_timeout * 4))
	local attempt=0
	if ! mkdir -p "$lock_root"; then
		print_error "Unable to create launch-lock directory: $lock_root"
		return 1
	fi
	SERVE_LAUNCH_LOCK="$lock_root/port-${port}.lock"
	while [[ "$attempt" -lt "$attempts" ]]; do
		if mkdir "$SERVE_LAUNCH_LOCK" 2>/dev/null; then
			if ! printf '%s\n' "$$" >"$SERVE_LAUNCH_LOCK/pid"; then
				rmdir "$SERVE_LAUNCH_LOCK" 2>/dev/null || true
				print_error "Unable to record launch-lock owner for port $port"
				return 1
			fi
			SERVE_LOCK_HELD=1
			return 0
		fi
		if [[ -L "$SERVE_LAUNCH_LOCK" || (-e "$SERVE_LAUNCH_LOCK" && ! -d "$SERVE_LAUNCH_LOCK") ]]; then
			print_error "Refusing invalid launch-lock path: $SERVE_LAUNCH_LOCK"
			return 1
		fi
		_serve_remove_stale_launch_lock "$SERVE_LAUNCH_LOCK" || true
		sleep 0.25
		attempt=$((attempt + 1))
	done
	print_error "Timed out waiting for launch lock on port $port"
	return 1
}

_serve_forward_signal() {
	local signal="$1"
	if [[ "$SERVE_CHILD_PID" =~ ^[0-9]+$ ]] && kill -0 "$SERVE_CHILD_PID" 2>/dev/null; then
		kill -s "$signal" "$SERVE_CHILD_PID" 2>/dev/null || true
	fi
	return 0
}

_serve_wait_for_readiness() {
	local port="$1"
	local root="$2"
	local health_url="$3"
	local startup_timeout="$4"
	local attempt=0
	local check_status=0
	local child_status=0
	while [[ "$attempt" -lt "$startup_timeout" ]]; do
		check_status=0
		_serve_check_existing "$port" "$root" "$health_url" 1 0 || check_status=$?
		if [[ "$check_status" -ne 0 ]]; then
			return "$check_status"
		fi
		if [[ "$SERVE_EXISTING" -eq 1 ]]; then
			return 0
		fi
		if ! kill -0 "$SERVE_CHILD_PID" 2>/dev/null; then
			wait "$SERVE_CHILD_PID" || child_status=$?
			print_error "Server command exited before port $port became ready (status $child_status)"
			[[ "$child_status" -eq 0 ]] && return 1
			return "$child_status"
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	print_error "Server did not become ready on port $port within ${startup_timeout}s"
	return 1
}

_serve_stop_failed_child() {
	if [[ "$SERVE_CHILD_PID" =~ ^[0-9]+$ ]] && kill -0 "$SERVE_CHILD_PID" 2>/dev/null; then
		kill -TERM "$SERVE_CHILD_PID" 2>/dev/null || true
		sleep 1
		kill -0 "$SERVE_CHILD_PID" 2>/dev/null && kill -KILL "$SERVE_CHILD_PID" 2>/dev/null || true
		wait "$SERVE_CHILD_PID" 2>/dev/null || true
	fi
	return 0
}

_serve_launch() {
	local port="$1"
	local root="$2"
	local health_url="$3"
	local startup_timeout="$4"
	local set_host="$5"
	local child_status=0
	shift 5
	export PORT="$port"
	[[ "$set_host" -eq 1 ]] && export HOST="0.0.0.0"
	"$@" &
	SERVE_CHILD_PID=$!
	trap '_serve_forward_signal INT' INT
	trap '_serve_forward_signal TERM' TERM
	trap '_serve_forward_signal HUP' HUP
	if ! _serve_wait_for_readiness "$port" "$root" "$health_url" "$startup_timeout"; then
		_serve_stop_failed_child
		return 1
	fi
	_serve_cleanup_launch_lock
	print_success "$name is ready on port $port"
	wait "$SERVE_CHILD_PID" || child_status=$?
	return "$child_status"
}

cmd_serve() {
	local name
	local port=""
	local root
	local stale_lock=""
	local health_url=""
	local startup_timeout=120
	local set_host=1
	local cmd_args=()
	name="$(basename "$(pwd -P)")"
	root="$(pwd -P)"
	_serve_parse_args "$@" || return 1
	_serve_validate_args "$port" "$startup_timeout" "${#cmd_args[@]}" "$health_url" || return 1
	root="$(_serve_canonical_root "$root")" || return 1
	_serve_check_existing "$port" "$root" "$health_url" || return 1
	[[ "$SERVE_EXISTING" -eq 1 ]] && return 0
	_serve_acquire_launch_lock "$port" "$startup_timeout" || return 1
	trap '_serve_cleanup_launch_lock' EXIT
	if ! _serve_check_existing "$port" "$root" "$health_url"; then
		_serve_cleanup_launch_lock
		trap - EXIT
		return 1
	fi
	if [[ "$SERVE_EXISTING" -eq 1 ]]; then
		_serve_cleanup_launch_lock
		trap - EXIT
		return 0
	fi
	local resolved_lock=""
	if ! resolved_lock="$(_serve_resolve_stale_lock "$root" "$stale_lock")"; then
		_serve_cleanup_launch_lock
		trap - EXIT
		return 1
	fi
	if [[ -n "$resolved_lock" ]]; then
		print_warning "Removing stale lock after confirming port $port is unused: $resolved_lock"
		rm -f -- "$resolved_lock"
	fi
	print_info "Starting $name on port $port: ${cmd_args[*]}"
	local launch_status=0
	_serve_launch "$port" "$root" "$health_url" "$startup_timeout" "$set_host" "${cmd_args[@]}" || launch_status=$?
	_serve_cleanup_launch_lock
	trap - EXIT INT TERM HUP
	return "$launch_status"
}
