#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# tailscale-client-qa-helper.sh - qualify a Tailscale-compatible control plane
# (Headscale or any --login-server) with two disposable official Tailscale
# clients running in Docker.
#
# Usage:
#   tailscale-client-qa-helper.sh run <app-location> [--force-derp] [--image IMAGE]
#                                     [--server-cmd CMD] [--login-server URL]
#   tailscale-client-qa-helper.sh cleanup [<app-location>] [--server-cmd CMD]
#   tailscale-client-qa-helper.sh help
#
# Reports registration, server view, netcheck, peer ping and DERP status as
# PASS:/FAIL: lines suitable for release evidence. Exits non-zero on failure.
# The pre-auth key is never printed or logged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

readonly QA_CONTAINER_PREFIX="hs-qa"
readonly QA_USER="qa"
readonly QA_DEFAULT_IMAGE="tailscale/tailscale:stable"
readonly QA_DEFAULT_SERVER_CMD="cloudron exec --app <app> -- headscale"
readonly QA_KEY_EXPIRY="30m"
readonly QA_RUNNING_TIMEOUT=90

QA_FAILURES=0
QA_SERVER_ARGV=()
QA_CLEANUP_ARMED=0

# --- output helpers ---------------------------------------------------------

qa_pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

qa_fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message"
	QA_FAILURES=$((QA_FAILURES + 1))
	return 0
}

qa_info() {
	local message="$1"
	printf 'INFO: %s\n' "$message"
	return 0
}

# --- server CLI hook --------------------------------------------------------

# Expand the server command template (<app> placeholder) into QA_SERVER_ARGV.
qa_set_server_cmd() {
	local template="$1"
	local app="$2"
	local expanded="${template//<app>/$app}"
	# Intentional word splitting of the operator-supplied command string.
	read -r -a QA_SERVER_ARGV <<<"$expanded"
	if [[ "${#QA_SERVER_ARGV[@]}" -eq 0 ]]; then
		return 1
	fi
	return 0
}

hs() {
	"${QA_SERVER_ARGV[@]}" "$@"
	return $?
}

# --- cleanup ----------------------------------------------------------------

qa_remove_containers() {
	local names
	names="$(docker ps -a --filter "name=${QA_CONTAINER_PREFIX}-" --format '{{.Names}}' 2>/dev/null || true)"
	local name
	for name in $names; do
		docker rm -f "$name" >/dev/null 2>&1 || true
	done
	return 0
}

qa_remove_nodes() {
	if [[ "${#QA_SERVER_ARGV[@]}" -eq 0 ]]; then
		return 0
	fi
	local ids
	ids="$(hs nodes list -o json 2>/dev/null |
		jq -r --arg u "$QA_USER" '.[] | select(.user.name == $u) | .id' 2>/dev/null || true)"
	local id
	for id in $ids; do
		hs nodes delete --identifier "$id" --force >/dev/null 2>&1 || true
	done
	return 0
}

qa_cleanup() {
	if [[ "$QA_CLEANUP_ARMED" -eq 0 ]]; then
		return 0
	fi
	QA_CLEANUP_ARMED=0
	qa_remove_containers
	qa_remove_nodes
	return 0
}

# --- client helpers ---------------------------------------------------------

qa_start_client() {
	local name="$1"
	local login_server="$2"
	local image="$3"
	local force_derp="$4"
	local key="$5"
	local extra_args="--login-server=${login_server} --hostname=${name}"

	# TS_AUTHKEY is passed by name so the value never appears in argv.
	if [[ "$force_derp" -eq 1 ]]; then
		TS_AUTHKEY="$key" docker run -d --name "$name" --hostname "$name" \
			-e TS_AUTHKEY -e TS_USERSPACE=true -e TS_STATE_DIR=/tmp/ts \
			-e "TS_EXTRA_ARGS=${extra_args}" \
			-e TS_DEBUG_ALWAYS_USE_DERP=true "$image" >/dev/null
	else
		TS_AUTHKEY="$key" docker run -d --name "$name" --hostname "$name" \
			-e TS_AUTHKEY -e TS_USERSPACE=true -e TS_STATE_DIR=/tmp/ts \
			-e "TS_EXTRA_ARGS=${extra_args}" "$image" >/dev/null
	fi
	return $?
}

qa_wait_running() {
	local name="$1"
	local waited=0
	local state=""
	while [[ "$waited" -lt "$QA_RUNNING_TIMEOUT" ]]; do
		state="$(docker exec "$name" tailscale status --json 2>/dev/null |
			jq -r '.BackendState // empty' 2>/dev/null || true)"
		if [[ "$state" == "Running" ]]; then
			return 0
		fi
		sleep 3
		waited=$((waited + 3))
	done
	return 1
}

qa_user_id() {
	local id
	id="$(hs users list -o json 2>/dev/null |
		jq -r --arg u "$QA_USER" '[.[] | select(.name == $u) | .id][0] // empty')"
	if [[ -z "$id" ]]; then
		hs users create "$QA_USER" >/dev/null 2>&1 || true
		id="$(hs users list -o json 2>/dev/null |
			jq -r --arg u "$QA_USER" '[.[] | select(.name == $u) | .id][0] // empty')"
	fi
	if [[ -z "$id" ]]; then
		return 1
	fi
	printf '%s\n' "$id"
	return 0
}

# --- run --------------------------------------------------------------------

qa_check_prereqs() {
	local tool
	for tool in docker jq; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			qa_fail "required tool not found: ${tool}"
			return 1
		fi
	done
	return 0
}

qa_ping_peer() {
	local from="$1"
	local to="$2"
	local force_derp="$3"
	local peer_ip
	peer_ip="$(docker exec "$to" tailscale ip -4 2>/dev/null | sed -n '1p')"
	if [[ -z "$peer_ip" ]]; then
		qa_fail "no tailnet IPv4 for ${to}"
		return 1
	fi
	local out
	if ! out="$(docker exec "$from" tailscale ping -c 5 --until-direct=false "$peer_ip" 2>&1)"; then
		printf '%s\n' "$out"
		qa_fail "peer ping ${from} -> ${to} (${peer_ip})"
		return 1
	fi
	printf '%s\n' "$out"
	if [[ "$force_derp" -eq 1 ]]; then
		if [[ "$out" == *'via DERP'* ]]; then
			qa_pass "peer ping ${from} -> ${to} relayed via DERP"
			return 0
		fi
		qa_fail "--force-derp set but ping did not travel via DERP"
		return 1
	fi
	qa_pass "peer ping ${from} -> ${to} (${peer_ip})"
	return 0
}

qa_report_server_view() {
	local view
	view="$(hs nodes list -o json 2>/dev/null |
		jq -r --arg u "$QA_USER" '.[] | select(.user.name == $u) |
			"\(.given_name) \(.ip_addresses | join(",")) online=\(.online)"' 2>/dev/null || true)"
	if [[ -z "$view" ]]; then
		qa_fail "server lists no nodes for user ${QA_USER}"
		return 1
	fi
	printf '%s\n' "$view"
	local count
	count="$(printf '%s\n' "$view" | wc -l | tr -d ' ')"
	if [[ "$count" -lt 2 ]]; then
		qa_fail "server sees ${count} node(s), expected 2"
		return 1
	fi
	qa_pass "server view lists ${count} registered nodes"
	return 0
}

qa_run_checks() {
	local login_server="$1"
	local image="$2"
	local force_derp="$3"
	local name_a="${QA_CONTAINER_PREFIX}-a"
	local name_b="${QA_CONTAINER_PREFIX}-b"

	local user_id
	if ! user_id="$(qa_user_id)"; then
		qa_fail "could not resolve or create server user ${QA_USER}"
		return 1
	fi

	local key
	if ! key="$(hs preauthkeys create --user "$user_id" --reusable --ephemeral \
		--expiration "$QA_KEY_EXPIRY" -o json 2>/dev/null | jq -r '.key // empty')" || [[ -z "$key" ]]; then
		qa_fail "could not create pre-auth key"
		return 1
	fi

	qa_info "starting clients from ${image} against ${login_server} (force-derp=${force_derp})"
	local started=0
	if qa_start_client "$name_a" "$login_server" "$image" "$force_derp" "$key" &&
		qa_start_client "$name_b" "$login_server" "$image" "$force_derp" "$key"; then
		started=1
	fi
	key=""
	if [[ "$started" -eq 0 ]]; then
		qa_fail "could not start Tailscale client containers"
		return 1
	fi

	local name
	for name in "$name_a" "$name_b"; do
		if qa_wait_running "$name"; then
			qa_pass "${name} reached Running"
		else
			qa_fail "${name} did not reach Running within ${QA_RUNNING_TIMEOUT}s"
		fi
	done
	if [[ "$QA_FAILURES" -gt 0 ]]; then
		return 1
	fi

	qa_report_server_view || true

	qa_info "netcheck from ${name_a}"
	docker exec "$name_a" tailscale netcheck 2>&1 || qa_fail "netcheck failed"

	qa_ping_peer "$name_a" "$name_b" "$force_derp" || true

	qa_info "DERP status from ${name_a}"
	if docker exec "$name_a" tailscale debug derp headscale 2>&1; then
		qa_pass "DERP probe against region 'headscale' completed"
	else
		qa_info "DERP probe unavailable or region name differs (not a failure)"
	fi
	return 0
}

qa_need_value() {
	local opt="$1"
	local count="$2"
	if [[ "$count" -lt 2 ]]; then
		print_error "${opt} needs a value"
		return 1
	fi
	return 0
}

cmd_run() {
	local app=""
	local force_derp=0
	local image="$QA_DEFAULT_IMAGE"
	local server_cmd="$QA_DEFAULT_SERVER_CMD"
	local login_server=""
	local arg=""
	local val=""

	while [[ $# -gt 0 ]]; do
		arg="${1:-}"
		val="${2:-}"
		case "$arg" in
		--force-derp) force_derp=1 ;;
		--image | --server-cmd | --login-server)
			qa_need_value "$arg" "$#" || return 1
			case "$arg" in
			--image) image="$val" ;;
			--server-cmd) server_cmd="$val" ;;
			*) login_server="$val" ;;
			esac
			shift
			;;
		-*)
			print_error "unknown option: ${arg}"
			return 1
			;;
		*)
			if [[ -n "$app" ]]; then
				print_error "unexpected argument: ${arg}"
				return 1
			fi
			app="$arg"
			;;
		esac
		shift
	done

	if [[ -z "$app" ]]; then
		print_error "run needs <app-location>"
		return 1
	fi
	[[ -n "$login_server" ]] || login_server="https://${app}"

	qa_check_prereqs || return 1
	qa_set_server_cmd "$server_cmd" "$app" || {
		print_error "empty --server-cmd"
		return 1
	}

	QA_CLEANUP_ARMED=1
	trap qa_cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	qa_run_checks "$login_server" "$image" "$force_derp" || true

	if [[ "$QA_FAILURES" -gt 0 ]]; then
		printf 'FAIL: %s check(s) failed for %s\n' "$QA_FAILURES" "$app"
		return 1
	fi
	printf 'PASS: tailscale client qualification succeeded for %s (force-derp=%s)\n' "$app" "$force_derp"
	return 0
}

cmd_cleanup() {
	local app=""
	local server_cmd="$QA_DEFAULT_SERVER_CMD"
	local arg=""
	local val=""
	while [[ $# -gt 0 ]]; do
		arg="${1:-}"
		val="${2:-}"
		case "$arg" in
		--server-cmd)
			qa_need_value "$arg" "$#" || return 1
			server_cmd="$val"
			shift
			;;
		-*)
			print_error "unknown option: ${arg}"
			return 1
			;;
		*) app="$arg" ;;
		esac
		shift
	done
	if command -v docker >/dev/null 2>&1; then
		qa_remove_containers
	fi
	if [[ -n "$app" ]] && command -v jq >/dev/null 2>&1; then
		qa_set_server_cmd "$server_cmd" "$app" && qa_remove_nodes
	fi
	qa_info "cleanup complete"
	return 0
}

cmd_help() {
	cat <<'EOF'
tailscale-client-qa-helper.sh - qualify a Tailscale-compatible control plane

Usage:
  tailscale-client-qa-helper.sh run <app-location> [options]
  tailscale-client-qa-helper.sh cleanup [<app-location>] [--server-cmd CMD]
  tailscale-client-qa-helper.sh help

Run options:
  --force-derp         Force relay-only paths (TS_DEBUG_ALWAYS_USE_DERP) and
                       require the peer ping to travel via DERP
  --image IMAGE        Client image (default: tailscale/tailscale:stable)
  --server-cmd CMD     Server CLI hook; "<app>" is replaced by <app-location>
                       (default: cloudron exec --app <app> -- headscale)
  --login-server URL   Control-plane URL (default: https://<app-location>)

Starts two disposable containers (hs-qa-a, hs-qa-b) registered with an
ephemeral, 30m pre-auth key for server user "qa", then reports registration,
server view, netcheck, peer ping and DERP status as PASS:/FAIL: lines.
The key is never printed. Containers and the "qa" user's nodes are removed on
exit. Exit status is non-zero if any check fails.

Requires: docker, jq, and the server CLI hook command.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	run) cmd_run "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
