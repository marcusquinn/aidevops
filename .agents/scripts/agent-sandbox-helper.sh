#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

SANDBOX_CONFIG="${AIDEVOPS_SANDBOX_CONFIG:-${SCRIPT_DIR}/../configs/agent-sandbox-backends.json}"
SANDBOX_STATE_DIR="${AIDEVOPS_SANDBOX_STATE_DIR:-${HOME}/.aidevops/state/agent-sandboxes}"
SANDBOX_RECEIPT_SCHEMA="aidevops.agent-sandbox.receipt/v1"
SANDBOX_UNAVAILABLE_RC=3
SANDBOX_UNSUPPORTED_RC=4
SANDBOX_LEASE_RC=5

_sandbox_usage() {
	cat <<'EOF'
Usage:
  agent-sandbox-helper.sh resolve
  agent-sandbox-helper.sh capabilities [--backend NAME]
  agent-sandbox-helper.sh create --id ID --backend NAME --image IMAGE --worktree PATH [limits]
  agent-sandbox-helper.sh start|stop|status|snapshot|destroy --id ID
  agent-sandbox-helper.sh exec --id ID -- COMMAND [ARG ...]
  agent-sandbox-helper.sh attach --id ID
  agent-sandbox-helper.sh recover --id ID --image IMAGE --worktree PATH

Create limits:
  --cpus N --memory 2G --command-timeout SECONDS --idle-timeout SECONDS
  --lease-ttl SECONDS

Ownership comes from AIDEVOPS_SANDBOX_SESSION_ID, AIDEVOPS_SESSION_ID,
OPENCODE_SESSION_ID, or CLAUDE_SESSION_ID. Secrets are never accepted as options.
EOF
	return 0
}

_sandbox_error() {
	printf 'agent-sandbox: %s\n' "$1" >&2
	return 0
}

_sandbox_fail() {
	local rc="$1"
	local message="$2"
	_sandbox_error "$message"
	return "$rc"
}

_sandbox_require_dependencies() {
	local dependency=""
	for dependency in jq python3 git; do
		command -v "$dependency" >/dev/null 2>&1 || {
			_sandbox_error "required command unavailable: ${dependency}"
			return 1
		}
	done
	[[ -f "$SANDBOX_CONFIG" && ! -L "$SANDBOX_CONFIG" ]] || {
		_sandbox_error "backend registry is missing or unsafe: ${SANDBOX_CONFIG}"
		return 1
	}
	jq -e '.schema_version == 1 and .default_backend == "local" and (.backends | type == "object")' \
		"$SANDBOX_CONFIG" >/dev/null || {
		_sandbox_error "backend registry is invalid"
		return 1
	}
	return 0
}

_sandbox_hash_text() {
	local value="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$value" | shasum -a 256 | cut -d' ' -f1
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$value" | sha256sum | cut -d' ' -f1
	else
		printf '%s' "$value" | openssl dgst -sha256 | cut -d' ' -f2
	fi
	return 0
}

_sandbox_now_epoch() {
	printf '%s\n' "${AIDEVOPS_SANDBOX_NOW_EPOCH:-$(date +%s)}"
	return 0
}

_sandbox_now_iso() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

_sandbox_session_id() {
	local session_id="${AIDEVOPS_SANDBOX_SESSION_ID:-${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}}"
	[[ -n "$session_id" ]] || {
		_sandbox_error "session identity unavailable; set AIDEVOPS_SANDBOX_SESSION_ID"
		return 1
	}
	printf '%s\n' "$session_id"
	return 0
}

_sandbox_validate_id() {
	local sandbox_id="$1"
	[[ "$sandbox_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
	return $?
}

_sandbox_prepare_state_dir() {
	if [[ -L "$SANDBOX_STATE_DIR" ]]; then
		_sandbox_error "state directory must not be a symlink"
		return 1
	fi
	(umask 077 && mkdir -p "$SANDBOX_STATE_DIR") || return 1
	chmod 700 "$SANDBOX_STATE_DIR" || return 1
	return 0
}

_sandbox_receipt_path() {
	local sandbox_id="$1"
	_sandbox_validate_id "$sandbox_id" || return 1
	printf '%s/%s.json\n' "$SANDBOX_STATE_DIR" "$sandbox_id"
	return 0
}

_sandbox_atomic_write() {
	local receipt_path="$1"
	local payload="$2"
	local temp_path="${receipt_path}.tmp.$$-${RANDOM}"
	[[ "$receipt_path" == "${SANDBOX_STATE_DIR}/"*.json ]] || return 1
	[[ ! -L "$receipt_path" && ! -e "$temp_path" && ! -L "$temp_path" ]] || return 1
	jq -e --arg schema "$SANDBOX_RECEIPT_SCHEMA" \
		'.schema == $schema and (.sandbox_id | type == "string")' <<<"$payload" >/dev/null || return 1
	(umask 077 && printf '%s\n' "$payload" >"$temp_path") || return 1
	chmod 600 "$temp_path" || return 1
	mv "$temp_path" "$receipt_path" || return 1
	chmod 600 "$receipt_path" || return 1
	return 0
}

_sandbox_load_receipt() {
	local sandbox_id="$1"
	local receipt_path=""
	receipt_path=$(_sandbox_receipt_path "$sandbox_id") || return 1
	[[ -f "$receipt_path" && ! -L "$receipt_path" ]] || {
		_sandbox_error "receipt not found for ${sandbox_id}"
		return 1
	}
	jq -e --arg schema "$SANDBOX_RECEIPT_SCHEMA" --arg id "$sandbox_id" \
		'.schema == $schema and .sandbox_id == $id' "$receipt_path" >/dev/null || {
		_sandbox_error "receipt validation failed for ${sandbox_id}"
		return 1
	}
	printf '%s\n' "$receipt_path"
	return 0
}

_sandbox_backend_json() {
	local backend="$1"
	jq -ce --arg backend "$backend" '.backends[$backend] // empty' "$SANDBOX_CONFIG"
	return $?
}

_sandbox_backend_supports() {
	local backend="$1"
	local operation="$2"
	jq -e --arg backend "$backend" --arg operation "$operation" \
		'.backends[$backend].executable == true and .backends[$backend].capabilities[$operation] == true' \
		"$SANDBOX_CONFIG" >/dev/null
	return $?
}

_sandbox_run_bounded() {
	local timeout_seconds="$1"
	shift
	python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
PY
	return $?
}

_sandbox_apple_probe() {
	local os_name="${AIDEVOPS_SANDBOX_OS:-$(uname -s)}"
	local architecture="${AIDEVOPS_SANDBOX_ARCH:-$(uname -m)}"
	local macos_major="${AIDEVOPS_SANDBOX_MACOS_MAJOR:-}"
	local version_json="" status_json="" version=""

	if [[ -z "$macos_major" && "$os_name" == "Darwin" ]] && command -v sw_vers >/dev/null 2>&1; then
		macos_major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
	fi
	if [[ "$os_name" != "Darwin" ]]; then
		jq -nc --arg reason "requires Darwin" '{available:false,reason:$reason}'
		return 1
	fi
	if [[ "$architecture" != "arm64" ]]; then
		jq -nc --arg reason "requires Apple silicon arm64" '{available:false,reason:$reason}'
		return 1
	fi
	if [[ ! "$macos_major" =~ ^[0-9]+$ || "$macos_major" -lt 26 ]]; then
		jq -nc --arg reason "requires macOS 26 or newer" '{available:false,reason:$reason}'
		return 1
	fi
	if ! command -v container >/dev/null 2>&1; then
		jq -nc --arg reason "container CLI not installed" '{available:false,reason:$reason}'
		return 1
	fi
	version_json=$(_sandbox_run_bounded 15 container system version --format json 2>/dev/null) || {
		jq -nc --arg reason "container version probe failed" '{available:false,reason:$reason}'
		return 1
	}
	version=$(jq -r 'if type == "array" then (.[] | select(.appName == "container") | .version) else empty end' \
		<<<"$version_json" 2>/dev/null | head -1)
	[[ -n "$version" ]] || {
		jq -nc --arg reason "container version response was not recognized" '{available:false,reason:$reason}'
		return 1
	}
	status_json=$(_sandbox_run_bounded 15 container system status --format json 2>/dev/null) || {
		jq -nc --arg version "$version" --arg reason "container service is unavailable" \
			'{available:false,version:$version,reason:$reason}'
		return 1
	}
	jq -e 'type == "object" or type == "array"' <<<"$status_json" >/dev/null 2>&1 || {
		jq -nc --arg version "$version" --arg reason "container status response was not recognized" \
			'{available:false,version:$version,reason:$reason}'
		return 1
	}
	jq -nc --arg version "$version" '{available:true,version:$version,reason:null}'
	return 0
}

_sandbox_provider_probe() {
	local backend="$1"
	case "$backend" in
	local)
		jq -nc '{available:true,reason:"local execution remains the unsandboxed default"}'
		return 0
		;;
	apple-container)
		_sandbox_apple_probe
		return $?
		;;
	bubbles)
		local installed=false
		if command -v flatpak >/dev/null 2>&1 && flatpak info de.gonicus.bubbles >/dev/null 2>&1; then
			installed=true
		fi
		jq -nc --argjson installed "$installed" \
			'{available:false,installed:$installed,reason:"no verified non-interactive lifecycle API"}'
		return 1
		;;
	cloudron)
		local configured=false
		[[ -n "${AIDEVOPS_CLOUDRON_WORKER_URL:-}" ]] && configured=true
		jq -nc --argjson configured "$configured" \
			'{available:false,configured:$configured,reason:"remote worker dispatch is not a per-agent sandbox lifecycle"}'
		return 1
		;;
	*)
		jq -nc --arg reason "unknown backend" '{available:false,reason:$reason}'
		return 1
		;;
	esac
}

_sandbox_require_operation() {
	local backend="$1"
	local operation="$2"
	local probe=""
	_sandbox_backend_json "$backend" >/dev/null 2>&1 || {
		_sandbox_fail "$SANDBOX_UNSUPPORTED_RC" "unknown backend: ${backend}"
		return $?
	}
	_sandbox_backend_supports "$backend" "$operation" || {
		_sandbox_fail "$SANDBOX_UNSUPPORTED_RC" "${backend} does not support ${operation}"
		return $?
	}
	probe=$(_sandbox_provider_probe "$backend") || {
		_sandbox_error "${backend} unavailable: $(jq -r '.reason // "probe failed"' <<<"$probe" 2>/dev/null)"
		return "$SANDBOX_UNAVAILABLE_RC"
	}
	return 0
}

_sandbox_worktree_evidence() {
	local requested_path="$1"
	local root="" git_dir="" head_sha="" branch=""
	[[ -d "$requested_path" ]] || return 1
	root=$(cd "$requested_path" && pwd -P) || return 1
	git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
	git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	if [[ "${AIDEVOPS_SANDBOX_ALLOW_NON_LINKED_WORKTREE:-0}" != "1" && "$git_dir" != */worktrees/* ]]; then
		_sandbox_error "sandbox workspace must be a linked Git worktree"
		return 1
	fi
	head_sha=$(git -C "$root" rev-parse HEAD 2>/dev/null) || return 1
	branch=$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null) || branch="detached"
	_SANDBOX_WORKTREE_PATH="$root"
	_SANDBOX_WORKTREE_PATH_HASH=$(_sandbox_hash_text "$root")
	_SANDBOX_WORKTREE_GIT_DIR_HASH=$(_sandbox_hash_text "$git_dir")
	_SANDBOX_WORKTREE_HEAD="$head_sha"
	_SANDBOX_WORKTREE_BRANCH_HASH=$(_sandbox_hash_text "$branch")
	return 0
}

_sandbox_apple_state() {
	local resource_id="$1"
	local inspect_json="" state=""
	inspect_json=$(_sandbox_run_bounded 20 container inspect "$resource_id" 2>/dev/null) || {
		printf 'missing\n'
		return 1
	}
	state=$(jq -r '
		(if type == "array" then .[0] else . end) as $item |
		($item.status // $item.state // $item.runtimeStatus // "unknown") | tostring | ascii_downcase
	' <<<"$inspect_json" 2>/dev/null) || state="unknown"
	case "$state" in
	running | started) printf 'running\n' ;;
	stopped | exited | created | configured) printf 'stopped\n' ;;
	*) printf 'unknown\n' ;;
	esac
	return 0
}

_sandbox_apple_create() {
	local resource_id="$1"
	local network_id="$2"
	local image="$3"
	local worktree="$4"
	local cpus="$5"
	local memory="$6"
	local idle_timeout="$7"
	local command_timeout="$8"
	local network_created=0
	local -a create_args=()

	if ! _sandbox_run_bounded "$command_timeout" container network inspect "$network_id" >/dev/null 2>&1; then
		_sandbox_run_bounded "$command_timeout" container network create --internal "$network_id" >/dev/null || return $?
		network_created=1
	fi
	create_args=(container create --name "$resource_id" --cpus "$cpus" --memory "$memory")
	create_args+=(--cap-drop ALL --network "$network_id" --no-dns --init --read-only)
	create_args+=(--tmpfs /tmp --tmpfs /run)
	create_args+=(--mount "type=bind,source=${worktree},target=/workspace" --workdir /workspace)
	create_args+=("$image" sleep "$idle_timeout")
	if ! _sandbox_run_bounded "$command_timeout" "${create_args[@]}" >/dev/null; then
		if [[ "$network_created" -eq 1 ]]; then
			_sandbox_run_bounded "$command_timeout" container network delete "$network_id" >/dev/null 2>&1 || true
		fi
		return 1
	fi
	return 0
}

_sandbox_apple_start() {
	local resource_id="$1"
	local command_timeout="$2"
	local state=""
	state=$(_sandbox_apple_state "$resource_id") || return 1
	[[ "$state" == "running" ]] && return 0
	_sandbox_run_bounded "$command_timeout" container start "$resource_id" >/dev/null
	return $?
}

_sandbox_apple_stop() {
	local resource_id="$1"
	local command_timeout="$2"
	local state=""
	state=$(_sandbox_apple_state "$resource_id") || return 0
	[[ "$state" == "stopped" ]] && return 0
	_sandbox_run_bounded "$command_timeout" container stop --time 10 "$resource_id" >/dev/null
	return $?
}

_sandbox_apple_destroy() {
	local resource_id="$1"
	local network_id="$2"
	local command_timeout="$3"
	_sandbox_apple_stop "$resource_id" "$command_timeout" || return $?
	if _sandbox_apple_state "$resource_id" >/dev/null 2>&1; then
		_sandbox_run_bounded "$command_timeout" container delete "$resource_id" >/dev/null || return $?
	fi
	_sandbox_run_bounded "$command_timeout" container network delete "$network_id" >/dev/null 2>&1 || true
	return 0
}

_sandbox_receipt_owner_matches() {
	local receipt_path="$1"
	local session_id="" session_hash="" now_epoch="" owner_hash="" lease_expires=""
	session_id=$(_sandbox_session_id) || return 1
	session_hash=$(_sandbox_hash_text "$session_id")
	now_epoch=$(_sandbox_now_epoch)
	owner_hash=$(jq -r '.lease.owner_session_sha256' "$receipt_path")
	lease_expires=$(jq -r '.lease.expires_at_epoch' "$receipt_path")
	[[ "$session_hash" == "$owner_hash" && "$lease_expires" =~ ^[0-9]+$ && "$now_epoch" -le "$lease_expires" ]]
	return $?
}

_sandbox_update_state() {
	local receipt_path="$1"
	local state="$2"
	local runtime_expires_epoch="$3"
	local now_epoch="" now_iso="" lease_ttl="" updated=""
	now_epoch=$(_sandbox_now_epoch)
	now_iso=$(_sandbox_now_iso)
	lease_ttl=$(jq -r '.bounds.lease_ttl_seconds' "$receipt_path")
	updated=$(jq -c --arg state "$state" --arg now "$now_iso" \
		--argjson now_epoch "$now_epoch" --argjson lease_expires "$((now_epoch + lease_ttl))" \
		--argjson runtime_expires "$runtime_expires_epoch" '
		.state = $state |
		.updated_at = $now |
		.last_activity_at_epoch = $now_epoch |
		.lease.expires_at_epoch = $lease_expires |
		.runtime_expires_at_epoch = (if $runtime_expires > 0 then $runtime_expires else null end)
	' "$receipt_path") || return 1
	_sandbox_atomic_write "$receipt_path" "$updated"
	return $?
}

_sandbox_acquire_recovery_lease() {
	local receipt_path="$1"
	local session_id="" session_hash="" owner_hash="" now_epoch="" lease_expires="" lease_ttl="" now_iso="" updated=""
	session_id=$(_sandbox_session_id) || return 1
	session_hash=$(_sandbox_hash_text "$session_id")
	now_epoch=$(_sandbox_now_epoch)
	owner_hash=$(jq -r '.lease.owner_session_sha256' "$receipt_path")
	lease_expires=$(jq -r '.lease.expires_at_epoch' "$receipt_path")
	lease_ttl=$(jq -r '.bounds.lease_ttl_seconds' "$receipt_path")
	if [[ "$session_hash" != "$owner_hash" && "$lease_expires" =~ ^[0-9]+$ && "$now_epoch" -le "$lease_expires" ]]; then
		_sandbox_error "live lease is owned by another session"
		return "$SANDBOX_LEASE_RC"
	fi
	now_iso=$(_sandbox_now_iso)
	updated=$(jq -c --arg owner "$session_hash" --arg now "$now_iso" \
		--argjson now_epoch "$now_epoch" --argjson expires "$((now_epoch + lease_ttl))" '
		.lease.owner_session_sha256 = $owner |
		.lease.generation += 1 |
		.lease.acquired_at = $now |
		.lease.acquired_at_epoch = $now_epoch |
		.lease.expires_at_epoch = $expires |
		.recovery_count += 1 |
		.updated_at = $now
	' "$receipt_path") || return 1
	_sandbox_atomic_write "$receipt_path" "$updated"
	return $?
}

_sandbox_parse_id_only() {
	_SANDBOX_ID=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--id)
			_SANDBOX_ID="${2:-}"
			shift 2
			;;
		*)
			_sandbox_error "unknown option: $1"
			return 2
			;;
		esac
	done
	_sandbox_validate_id "$_SANDBOX_ID" || {
		_sandbox_error "--id must match [a-z0-9][a-z0-9._-]{0,63}"
		return 2
	}
	return 0
}

cmd_resolve() {
	local backend="${AIDEVOPS_SANDBOX_BACKEND:-local}"
	local required="${AIDEVOPS_SANDBOX_REQUIRED:-0}"
	local probe=""
	_sandbox_backend_json "$backend" >/dev/null 2>&1 || return "$SANDBOX_UNSUPPORTED_RC"
	if [[ "$backend" == "local" ]]; then
		if [[ "$required" == "1" ]]; then
			_sandbox_error "sandbox required but no sandbox backend is configured"
			return "$SANDBOX_UNAVAILABLE_RC"
		fi
		jq -nc '{backend:"local",sandboxed:false,decision:"local-default"}'
		return 0
	fi
	probe=$(_sandbox_provider_probe "$backend") || {
		jq -nc --arg backend "$backend" --argjson probe "$probe" \
			'{backend:$backend,sandboxed:true,decision:"blocked",runtime:$probe}'
		return "$SANDBOX_UNAVAILABLE_RC"
	}
	jq -nc --arg backend "$backend" --argjson probe "$probe" \
		'{backend:$backend,sandboxed:true,decision:"sandbox",runtime:$probe}'
	return 0
}

cmd_capabilities() {
	local backend="${AIDEVOPS_SANDBOX_BACKEND:-local}"
	local backend_json="" probe=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend)
			backend="${2:-}"
			shift 2
			;;
		*)
			_sandbox_error "unknown option: $1"
			return 2
			;;
		esac
	done
	backend_json=$(_sandbox_backend_json "$backend") || return "$SANDBOX_UNSUPPORTED_RC"
	probe=$(_sandbox_provider_probe "$backend") || true
	jq -n --arg backend "$backend" --argjson definition "$backend_json" --argjson runtime "$probe" \
		'{schema:"aidevops.agent-sandbox.capabilities/v1",backend:$backend,definition:$definition,runtime:$runtime}'
	return 0
}

_sandbox_parse_create() {
	_SANDBOX_ID=""
	_SANDBOX_BACKEND=""
	_SANDBOX_IMAGE=""
	_SANDBOX_WORKTREE=""
	_SANDBOX_CPUS=$(jq -r '.defaults.cpus' "$SANDBOX_CONFIG")
	_SANDBOX_MEMORY=$(jq -r '.defaults.memory' "$SANDBOX_CONFIG")
	_SANDBOX_COMMAND_TIMEOUT=$(jq -r '.defaults.command_timeout_seconds' "$SANDBOX_CONFIG")
	_SANDBOX_IDLE_TIMEOUT=$(jq -r '.defaults.idle_timeout_seconds' "$SANDBOX_CONFIG")
	_SANDBOX_LEASE_TTL=$(jq -r '.defaults.lease_ttl_seconds' "$SANDBOX_CONFIG")
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--id)
			_SANDBOX_ID="${2:-}"
			shift 2
			;;
		--backend)
			_SANDBOX_BACKEND="${2:-}"
			shift 2
			;;
		--image)
			_SANDBOX_IMAGE="${2:-}"
			shift 2
			;;
		--worktree)
			_SANDBOX_WORKTREE="${2:-}"
			shift 2
			;;
		--cpus)
			_SANDBOX_CPUS="${2:-}"
			shift 2
			;;
		--memory)
			_SANDBOX_MEMORY="${2:-}"
			shift 2
			;;
		--command-timeout)
			_SANDBOX_COMMAND_TIMEOUT="${2:-}"
			shift 2
			;;
		--idle-timeout)
			_SANDBOX_IDLE_TIMEOUT="${2:-}"
			shift 2
			;;
		--lease-ttl)
			_SANDBOX_LEASE_TTL="${2:-}"
			shift 2
			;;
		*)
			_sandbox_error "unknown option: $1"
			return 2
			;;
		esac
	done
	_sandbox_validate_id "$_SANDBOX_ID" || return 2
	[[ -n "$_SANDBOX_BACKEND" && -n "$_SANDBOX_IMAGE" && -n "$_SANDBOX_WORKTREE" ]] || return 2
	[[ "$_SANDBOX_CPUS" =~ ^[1-9][0-9]*$ && "$_SANDBOX_MEMORY" =~ ^[1-9][0-9]*[MG]$ ]] || return 2
	[[ "$_SANDBOX_COMMAND_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || return 2
	[[ "$_SANDBOX_IDLE_TIMEOUT" =~ ^[0-9]+$ && "$_SANDBOX_IDLE_TIMEOUT" -ge 60 ]] || return 2
	[[ "$_SANDBOX_LEASE_TTL" =~ ^[0-9]+$ && "$_SANDBOX_LEASE_TTL" -ge 60 ]] || return 2
	return 0
}

cmd_create() {
	_sandbox_parse_create "$@" || {
		_sandbox_usage >&2
		return 2
	}
	_sandbox_require_operation "$_SANDBOX_BACKEND" create || return $?
	_sandbox_worktree_evidence "$_SANDBOX_WORKTREE" || return 2
	local session_id="" session_hash="" agent_hash="" image_hash="" immutable_json="" immutable_hash=""
	local receipt_path="" resource_id="" network_id="" now_epoch="" now_iso="" receipt=""
	session_id=$(_sandbox_session_id) || return 2
	session_hash=$(_sandbox_hash_text "$session_id")
	agent_hash=$(_sandbox_hash_text "${AIDEVOPS_AGENT_ID:-build-plus}")
	image_hash=$(_sandbox_hash_text "$_SANDBOX_IMAGE")
	resource_id="aidevops-${_SANDBOX_ID}"
	network_id="${resource_id}-net"
	immutable_json=$(jq -nc --arg backend "$_SANDBOX_BACKEND" --arg image "$image_hash" \
		--arg path "$_SANDBOX_WORKTREE_PATH_HASH" --arg git_dir "$_SANDBOX_WORKTREE_GIT_DIR_HASH" \
		--arg branch "$_SANDBOX_WORKTREE_BRANCH_HASH" --argjson cpus "$_SANDBOX_CPUS" \
		--arg memory "$_SANDBOX_MEMORY" --argjson command_timeout "$_SANDBOX_COMMAND_TIMEOUT" \
		--argjson idle_timeout "$_SANDBOX_IDLE_TIMEOUT" \
		'{backend:$backend,image_sha256:$image,worktree_path_sha256:$path,worktree_git_dir_sha256:$git_dir,worktree_branch_sha256:$branch,cpus:$cpus,memory:$memory,command_timeout_seconds:$command_timeout,idle_timeout_seconds:$idle_timeout,network_mode:"internal",workspace_target:"/workspace"}')
	immutable_hash=$(_sandbox_hash_text "$immutable_json")
	_sandbox_prepare_state_dir || return 1
	receipt_path=$(_sandbox_receipt_path "$_SANDBOX_ID") || return 2
	if [[ -f "$receipt_path" ]]; then
		if jq -e --arg digest "$immutable_hash" '.immutable_parameters_sha256 == $digest and .state != "DESTROYED"' \
			"$receipt_path" >/dev/null 2>&1; then
			jq '.' "$receipt_path"
			return 0
		fi
		_sandbox_error "sandbox ID already has a conflicting or terminal receipt"
		return "$SANDBOX_LEASE_RC"
	fi
	_sandbox_apple_create "$resource_id" "$network_id" "$_SANDBOX_IMAGE" "$_SANDBOX_WORKTREE_PATH" \
		"$_SANDBOX_CPUS" "$_SANDBOX_MEMORY" "$_SANDBOX_IDLE_TIMEOUT" "$_SANDBOX_COMMAND_TIMEOUT" || return $?
	now_epoch=$(_sandbox_now_epoch)
	now_iso=$(_sandbox_now_iso)
	receipt=$(jq -nc --arg schema "$SANDBOX_RECEIPT_SCHEMA" --arg id "$_SANDBOX_ID" \
		--arg backend "$_SANDBOX_BACKEND" --arg resource "$resource_id" --arg network "$network_id" \
		--arg state "CREATED" --arg now "$now_iso" --arg immutable "$immutable_hash" \
		--arg agent "$agent_hash" --arg session "$session_hash" --arg image "$image_hash" \
		--arg path "$_SANDBOX_WORKTREE_PATH_HASH" --arg git_dir "$_SANDBOX_WORKTREE_GIT_DIR_HASH" \
		--arg branch "$_SANDBOX_WORKTREE_BRANCH_HASH" --arg head "$_SANDBOX_WORKTREE_HEAD" \
		--arg memory "$_SANDBOX_MEMORY" --argjson now_epoch "$now_epoch" \
		--argjson cpus "$_SANDBOX_CPUS" --argjson command_timeout "$_SANDBOX_COMMAND_TIMEOUT" \
		--argjson idle_timeout "$_SANDBOX_IDLE_TIMEOUT" --argjson lease_ttl "$_SANDBOX_LEASE_TTL" '
		{
			schema:$schema,sandbox_id:$id,backend:$backend,backend_resource_id:$resource,
			backend_network_id:$network,state:$state,created_at:$now,updated_at:$now,
			created_at_epoch:$now_epoch,last_activity_at_epoch:$now_epoch,runtime_expires_at_epoch:null,
			immutable_parameters_sha256:$immutable,agent_id_sha256:$agent,image_sha256:$image,
			worktree:{path_sha256:$path,git_dir_sha256:$git_dir,branch_sha256:$branch,created_head:$head},
			bounds:{cpus:$cpus,memory:$memory,command_timeout_seconds:$command_timeout,
				idle_timeout_seconds:$idle_timeout,lease_ttl_seconds:$lease_ttl,
				network_mode:"internal",workspace_target:"/workspace",storage_isolated:true,
				storage_quota:false,retained_snapshots:0},
			lease:{owner_session_sha256:$session,generation:1,acquired_at:$now,
				acquired_at_epoch:$now_epoch,expires_at_epoch:($now_epoch + $lease_ttl)},
			recovery_count:0,last_error:null
		}')
	if ! _sandbox_atomic_write "$receipt_path" "$receipt"; then
		_sandbox_apple_destroy "$resource_id" "$network_id" "$_SANDBOX_COMMAND_TIMEOUT" || true
		return 1
	fi
	jq '.' "$receipt_path"
	return 0
}

cmd_start() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend="" resource_id="" timeout="" idle_timeout="" now_epoch=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" start || return $?
	_sandbox_receipt_owner_matches "$receipt_path" || return "$SANDBOX_LEASE_RC"
	[[ "$(jq -r '.state' "$receipt_path")" != "DESTROYED" ]] || return "$SANDBOX_LEASE_RC"
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	idle_timeout=$(jq -r '.bounds.idle_timeout_seconds' "$receipt_path")
	_sandbox_apple_start "$resource_id" "$timeout" || return $?
	now_epoch=$(_sandbox_now_epoch)
	_sandbox_update_state "$receipt_path" RUNNING "$((now_epoch + idle_timeout))" || return 1
	jq '.' "$receipt_path"
	return 0
}

_sandbox_parse_exec() {
	_SANDBOX_ID=""
	_SANDBOX_EXEC_ARGS=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--id)
			_SANDBOX_ID="${2:-}"
			shift 2
			;;
		--)
			shift
			_SANDBOX_EXEC_ARGS=("$@")
			break
			;;
		*)
			_sandbox_error "expected -- before command argv"
			return 2
			;;
		esac
	done
	_sandbox_validate_id "$_SANDBOX_ID" || return 2
	[[ "${#_SANDBOX_EXEC_ARGS[@]}" -gt 0 ]] || return 2
	return 0
}

cmd_exec() {
	_sandbox_parse_exec "$@" || return $?
	local receipt_path="" backend="" resource_id="" timeout="" state="" exec_rc=0 runtime_expires=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" exec || return $?
	_sandbox_receipt_owner_matches "$receipt_path" || return "$SANDBOX_LEASE_RC"
	[[ "$(jq -r '.state' "$receipt_path")" == "RUNNING" ]] || return "$SANDBOX_LEASE_RC"
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	state=$(_sandbox_apple_state "$resource_id") || return 1
	[[ "$state" == "running" ]] || return 1
	_sandbox_run_bounded "$timeout" container exec --workdir /workspace "$resource_id" \
		"${_SANDBOX_EXEC_ARGS[@]}" || exec_rc=$?
	[[ "$exec_rc" -eq 0 ]] || return "$exec_rc"
	runtime_expires=$(jq -r '.runtime_expires_at_epoch // 0' "$receipt_path")
	_sandbox_update_state "$receipt_path" RUNNING "$runtime_expires" || return 1
	return 0
}

cmd_attach() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend="" resource_id="" timeout="" runtime_expires="" attach_rc=0
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" attach || return $?
	_sandbox_receipt_owner_matches "$receipt_path" || return "$SANDBOX_LEASE_RC"
	[[ "$(jq -r '.state' "$receipt_path")" == "RUNNING" ]] || return "$SANDBOX_LEASE_RC"
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	_sandbox_run_bounded "$timeout" container exec --interactive --tty --workdir /workspace \
		"$resource_id" /bin/sh || attach_rc=$?
	[[ "$attach_rc" -eq 0 ]] || return "$attach_rc"
	runtime_expires=$(jq -r '.runtime_expires_at_epoch // 0' "$receipt_path")
	_sandbox_update_state "$receipt_path" RUNNING "$runtime_expires"
	return $?
}

cmd_stop() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend="" resource_id="" timeout=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" stop || return $?
	_sandbox_receipt_owner_matches "$receipt_path" || return "$SANDBOX_LEASE_RC"
	[[ "$(jq -r '.state' "$receipt_path")" != "DESTROYED" ]] || return 0
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	_sandbox_apple_stop "$resource_id" "$timeout" || return $?
	_sandbox_update_state "$receipt_path" STOPPED 0 || return 1
	jq '.' "$receipt_path"
	return 0
}

cmd_status() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend="" resource_id="" backend_state="" probe="" probe_rc=0
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	probe=$(_sandbox_provider_probe "$backend") || probe_rc=$?
	if [[ "$probe_rc" -eq 0 ]]; then
		backend_state=$(_sandbox_apple_state "$resource_id") || backend_state="missing"
	else
		backend_state="unavailable"
	fi
	jq -n --argjson receipt "$(jq -c '.' "$receipt_path")" --arg backend_state "$backend_state" \
		--argjson runtime "$probe" '{receipt:$receipt,backend_state:$backend_state,runtime:$runtime}'
	return "$probe_rc"
}

cmd_snapshot() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" snapshot
	return $?
}

_sandbox_parse_recover() {
	_SANDBOX_ID=""
	_SANDBOX_IMAGE=""
	_SANDBOX_WORKTREE=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--id)
			_SANDBOX_ID="${2:-}"
			shift 2
			;;
		--image)
			_SANDBOX_IMAGE="${2:-}"
			shift 2
			;;
		--worktree)
			_SANDBOX_WORKTREE="${2:-}"
			shift 2
			;;
		*)
			_sandbox_error "unknown option: $1"
			return 2
			;;
		esac
	done
	_sandbox_validate_id "$_SANDBOX_ID" || return 2
	[[ -n "$_SANDBOX_IMAGE" && -n "$_SANDBOX_WORKTREE" ]] || return 2
	return 0
}

cmd_recover() {
	_sandbox_parse_recover "$@" || return $?
	local receipt_path="" backend="" resource_id="" network_id="" timeout="" cpus="" memory="" idle_timeout=""
	local image_hash="" expected_image="" expected_path="" expected_git_dir="" backend_state="" recovered_state=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" recover || return $?
	[[ "$(jq -r '.state' "$receipt_path")" != "DESTROYED" ]] || return "$SANDBOX_LEASE_RC"
	_sandbox_worktree_evidence "$_SANDBOX_WORKTREE" || return 2
	image_hash=$(_sandbox_hash_text "$_SANDBOX_IMAGE")
	expected_image=$(jq -r '.image_sha256' "$receipt_path")
	expected_path=$(jq -r '.worktree.path_sha256' "$receipt_path")
	expected_git_dir=$(jq -r '.worktree.git_dir_sha256' "$receipt_path")
	if [[ "$image_hash" != "$expected_image" || "$_SANDBOX_WORKTREE_PATH_HASH" != "$expected_path" ||
		"$_SANDBOX_WORKTREE_GIT_DIR_HASH" != "$expected_git_dir" ]]; then
		_sandbox_error "recovery inputs do not match immutable receipt identity"
		return "$SANDBOX_LEASE_RC"
	fi
	_sandbox_acquire_recovery_lease "$receipt_path" || return $?
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	network_id=$(jq -r '.backend_network_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	cpus=$(jq -r '.bounds.cpus' "$receipt_path")
	memory=$(jq -r '.bounds.memory' "$receipt_path")
	idle_timeout=$(jq -r '.bounds.idle_timeout_seconds' "$receipt_path")
	if backend_state=$(_sandbox_apple_state "$resource_id"); then
		[[ "$backend_state" == "running" ]] && recovered_state="RUNNING" || recovered_state="STOPPED"
	else
		_sandbox_apple_create "$resource_id" "$network_id" "$_SANDBOX_IMAGE" "$_SANDBOX_WORKTREE_PATH" \
			"$cpus" "$memory" "$idle_timeout" "$timeout" || return $?
		recovered_state="CREATED"
	fi
	_sandbox_update_state "$receipt_path" "$recovered_state" 0 || return 1
	jq '.' "$receipt_path"
	return 0
}

cmd_destroy() {
	_sandbox_parse_id_only "$@" || return $?
	local receipt_path="" backend="" resource_id="" network_id="" timeout=""
	receipt_path=$(_sandbox_load_receipt "$_SANDBOX_ID") || return 1
	if [[ "$(jq -r '.state' "$receipt_path")" == "DESTROYED" ]]; then
		jq '.' "$receipt_path"
		return 0
	fi
	backend=$(jq -r '.backend' "$receipt_path")
	_sandbox_require_operation "$backend" destroy || return $?
	_sandbox_receipt_owner_matches "$receipt_path" || return "$SANDBOX_LEASE_RC"
	resource_id=$(jq -r '.backend_resource_id' "$receipt_path")
	network_id=$(jq -r '.backend_network_id' "$receipt_path")
	timeout=$(jq -r '.bounds.command_timeout_seconds' "$receipt_path")
	_sandbox_apple_destroy "$resource_id" "$network_id" "$timeout" || return $?
	_sandbox_update_state "$receipt_path" DESTROYED 0 || return 1
	jq '.' "$receipt_path"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	_sandbox_require_dependencies || return 1
	case "$command" in
	resolve) cmd_resolve "$@" ;;
	capabilities) cmd_capabilities "$@" ;;
	create) cmd_create "$@" ;;
	start) cmd_start "$@" ;;
	exec) cmd_exec "$@" ;;
	attach) cmd_attach "$@" ;;
	stop) cmd_stop "$@" ;;
	status) cmd_status "$@" ;;
	snapshot) cmd_snapshot "$@" ;;
	recover) cmd_recover "$@" ;;
	destroy) cmd_destroy "$@" ;;
	help | --help | -h) _sandbox_usage ;;
	*)
		_sandbox_usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
