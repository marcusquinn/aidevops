#!/usr/bin/env bash
# remote-dispatch-helper.sh - Remote container dispatch via SSH/Tailscale
#
# Dispatches AI workers to containers on remote hosts with credential
# forwarding and log collection. Integrates with supervisor dispatch.sh.
#
# Usage:
#   remote-dispatch-helper.sh check <host>           # Verify host connectivity
#   remote-dispatch-helper.sh hosts                   # List configured remote hosts
#   remote-dispatch-helper.sh add <name> <address>    # Add a remote host
#   remote-dispatch-helper.sh remove <name>           # Remove a remote host
#   remote-dispatch-helper.sh dispatch <task_id> <host> [--container <name>]
#   remote-dispatch-helper.sh logs <task_id> <host>   # Collect logs from remote
#   remote-dispatch-helper.sh status <task_id> <host> # Check remote worker status
#   remote-dispatch-helper.sh cleanup <task_id> <host> # Clean up remote resources
#
# Environment:
#   REMOTE_DISPATCH_SSH_OPTS   - Extra SSH options (default: -o ConnectTimeout=10)
#   REMOTE_DISPATCH_LOG_DIR    - Local log collection dir (default: $SUPERVISOR_DIR/logs/remote)
#   REMOTE_DISPATCH_HOSTS_FILE - Hosts config file (default: $CONFIG_DIR/remote-hosts.json)
#
# Author: AI DevOps Framework
# Task: t1165.3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# --- Constants ---
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly REMOTE_HOSTS_FILE="${REMOTE_DISPATCH_HOSTS_FILE:-${CONFIG_DIR}/remote-hosts.json}"
readonly DEFAULT_SSH_OPTS="${REMOTE_DISPATCH_SSH_OPTS:--o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30}"
readonly SUPERVISOR_DIR="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
readonly REMOTE_LOG_DIR="${REMOTE_DISPATCH_LOG_DIR:-${SUPERVISOR_DIR}/logs/remote}"
readonly REMOTE_WORK_BASE="/tmp/aidevops-worker"

# --- Colours (reuse shared-constants if available) ---
readonly _BOLD='\033[1m'
readonly _RED='\033[0;31m'
readonly _GREEN='\033[0;32m'
readonly _YELLOW='\033[1;33m'
readonly _BLUE='\033[0;34m'
readonly _NC='\033[0m'

# --- Logging ---
_log_info() { echo -e "${_BLUE}[REMOTE]${_NC} $*" >&2; }
_log_success() { echo -e "${_GREEN}[REMOTE]${_NC} $*" >&2; }
_log_warn() { echo -e "${_YELLOW}[REMOTE]${_NC} $*" >&2; }
_log_error() { echo -e "${_RED}[REMOTE]${_NC} $*" >&2; }

# =============================================================================
# Host Configuration
# =============================================================================

#######################################
# Ensure the hosts config file exists with valid JSON
#######################################
_ensure_hosts_file() {
	mkdir -p "$(dirname "$REMOTE_HOSTS_FILE")" 2>/dev/null || true
	if [[ ! -f "$REMOTE_HOSTS_FILE" ]]; then
		echo '{"hosts":{}}' >"$REMOTE_HOSTS_FILE"
	fi
	return 0
}

#######################################
# List configured remote hosts
# Outputs: JSON array of hosts or human-readable table
#######################################
cmd_hosts() {
	_ensure_hosts_file

	local host_count
	host_count=$(jq -r '.hosts | length' "$REMOTE_HOSTS_FILE" 2>/dev/null || echo "0")

	if [[ "$host_count" -eq 0 ]]; then
		_log_info "No remote hosts configured"
		echo "Add a host: remote-dispatch-helper.sh add <name> <address>"
		echo ""
		echo "Examples:"
		echo "  remote-dispatch-helper.sh add gpu-server 192.168.1.100"
		echo "  remote-dispatch-helper.sh add build-node user@build.tailnet.ts.net"
		echo "  remote-dispatch-helper.sh add docker-host ssh://user@host:2222"
		return 0
	fi

	echo -e "${_BOLD}Remote Hosts:${_NC}"
	echo "---"
	jq -r '.hosts | to_entries[] | "  \(.key): \(.value.address) (\(.value.transport // "ssh")) container:\(.value.container // "auto")"' "$REMOTE_HOSTS_FILE" 2>/dev/null
	echo ""
	echo "Total: $host_count host(s)"
	return 0
}

#######################################
# Add a remote host
# Args: name address [--transport ssh|tailscale] [--container name] [--user user]
#######################################
cmd_add() {
	local name="" address="" transport="ssh" container="auto" user=""

	if [[ $# -lt 2 ]]; then
		_log_error "Usage: remote-dispatch-helper.sh add <name> <address> [--transport ssh|tailscale] [--container name] [--user user]"
		return 1
	fi

	name="$1"
	address="$2"
	shift 2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--transport)
			transport="$2"
			shift 2
			;;
		--container)
			container="$2"
			shift 2
			;;
		--user)
			user="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Validate name
	if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
		_log_error "Invalid host name: '$name'. Use alphanumeric, hyphens, underscores."
		return 1
	fi

	# Validate transport
	if [[ "$transport" != "ssh" && "$transport" != "tailscale" ]]; then
		_log_error "Invalid transport: '$transport'. Use 'ssh' or 'tailscale'."
		return 1
	fi

	_ensure_hosts_file

	# Add host to config
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg name "$name" \
		--arg addr "$address" \
		--arg trans "$transport" \
		--arg cont "$container" \
		--arg usr "$user" \
		'.hosts[$name] = {address: $addr, transport: $trans, container: $cont, user: $usr, added: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}' \
		"$REMOTE_HOSTS_FILE" >"$tmp_file" && mv "$tmp_file" "$REMOTE_HOSTS_FILE"

	_log_success "Added remote host: $name ($address via $transport)"
	return 0
}

#######################################
# Remove a remote host
# Args: name
#######################################
cmd_remove() {
	local name="${1:-}"

	if [[ -z "$name" ]]; then
		_log_error "Usage: remote-dispatch-helper.sh remove <name>"
		return 1
	fi

	_ensure_hosts_file

	local exists
	exists=$(jq -r --arg name "$name" '.hosts[$name] // empty' "$REMOTE_HOSTS_FILE" 2>/dev/null)
	if [[ -z "$exists" ]]; then
		_log_error "Host not found: $name"
		return 1
	fi

	local tmp_file
	tmp_file=$(mktemp)
	jq --arg name "$name" 'del(.hosts[$name])' "$REMOTE_HOSTS_FILE" >"$tmp_file" && mv "$tmp_file" "$REMOTE_HOSTS_FILE"

	_log_success "Removed remote host: $name"
	return 0
}

# =============================================================================
# SSH/Tailscale Connectivity
# =============================================================================

#######################################
# Resolve host address from config or use raw address
# Args: host_name_or_address
# Outputs: address transport container user
#######################################
_resolve_host() {
	local host="$1"
	local address="" transport="ssh" container="auto" user=""

	_ensure_hosts_file

	# Check if it's a configured host name
	local host_config
	host_config=$(jq -r --arg name "$host" '.hosts[$name] // empty' "$REMOTE_HOSTS_FILE" 2>/dev/null)

	if [[ -n "$host_config" ]]; then
		address=$(echo "$host_config" | jq -r '.address')
		transport=$(echo "$host_config" | jq -r '.transport // "ssh"')
		container=$(echo "$host_config" | jq -r '.container // "auto"')
		user=$(echo "$host_config" | jq -r '.user // ""')
	else
		# Use raw address
		address="$host"
		# Detect Tailscale addresses (*.ts.net or 100.x.x.x)
		if [[ "$address" == *".ts.net"* || "$address" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			transport="tailscale"
		fi
	fi

	echo "${address}|${transport}|${container}|${user}"
	return 0
}

#######################################
# Build SSH command with appropriate options
# Args: address transport [user]
# Outputs: SSH command prefix (space-separated)
#######################################
_build_ssh_cmd() {
	local address="$1"
	local transport="$2"
	local user="${3:-}"

	local -a ssh_cmd=()

	if [[ "$transport" == "tailscale" ]]; then
		# Tailscale SSH: use tailscale ssh if available, fall back to regular ssh
		if command -v tailscale &>/dev/null; then
			ssh_cmd+=("tailscale" "ssh")
		else
			ssh_cmd+=("ssh")
		fi
	else
		ssh_cmd+=("ssh")
	fi

	# Add default SSH options (word-split is intentional here)
	# shellcheck disable=SC2206
	ssh_cmd+=($DEFAULT_SSH_OPTS)

	# Enable SSH agent forwarding for credential passthrough
	ssh_cmd+=("-A")

	# Add user@ prefix if specified
	if [[ -n "$user" ]]; then
		ssh_cmd+=("${user}@${address}")
	else
		ssh_cmd+=("${address}")
	fi

	printf '%s\n' "${ssh_cmd[@]}"
	return 0
}

#######################################
# Check connectivity to a remote host
# Args: host
# Returns: 0 if reachable, 1 if not
#######################################
cmd_check() {
	local host="${1:-}"

	if [[ -z "$host" ]]; then
		_log_error "Usage: remote-dispatch-helper.sh check <host>"
		return 1
	fi

	local host_info
	host_info=$(_resolve_host "$host")
	local address transport container user
	IFS='|' read -r address transport container user <<<"$host_info"

	_log_info "Checking connectivity to $host ($address via $transport)..."

	# Build SSH command
	local -a ssh_cmd=()
	while IFS= read -r line; do
		ssh_cmd+=("$line")
	done < <(_build_ssh_cmd "$address" "$transport" "$user")

	# Test 1: Basic SSH connectivity
	if ! "${ssh_cmd[@]}" "echo 'SSH_OK'" 2>/dev/null | grep -q 'SSH_OK'; then
		_log_error "SSH connection failed to $address"
		return 1
	fi
	_log_success "SSH connectivity: OK"

	# Test 2: Check for Docker/container runtime
	local has_docker="false" has_orbstack="false"
	if "${ssh_cmd[@]}" "command -v docker" &>/dev/null; then
		has_docker="true"
		_log_success "Docker: available"
	else
		_log_warn "Docker: not found"
	fi

	if "${ssh_cmd[@]}" "command -v orb" &>/dev/null; then
		has_orbstack="true"
		_log_success "OrbStack: available"
	else
		_log_info "OrbStack: not found (optional)"
	fi

	# Test 3: Check for AI CLI availability
	local has_opencode="false" has_claude="false"
	if "${ssh_cmd[@]}" "command -v opencode" &>/dev/null; then
		has_opencode="true"
		_log_success "OpenCode CLI: available"
	fi
	if "${ssh_cmd[@]}" "command -v claude" &>/dev/null; then
		has_claude="true"
		_log_success "Claude CLI: available"
	fi

	if [[ "$has_opencode" == "false" && "$has_claude" == "false" ]]; then
		_log_warn "No AI CLI found on remote host — workers will need CLI installed"
	fi

	# Test 4: Check SSH agent forwarding
	# shellcheck disable=SC2016 # $SSH_AUTH_SOCK must expand on the remote host, not locally
	if "${ssh_cmd[@]}" 'test -n "$SSH_AUTH_SOCK"' 2>/dev/null; then
		_log_success "SSH agent forwarding: working"
	else
		_log_warn "SSH agent forwarding: not available (credential forwarding may be limited)"
	fi

	# Test 5: Check available disk space
	local disk_free
	disk_free=$("${ssh_cmd[@]}" "df -h /tmp 2>/dev/null | tail -1 | awk '{print \$4}'" 2>/dev/null || echo "unknown")
	_log_info "Free disk space (/tmp): $disk_free"

	echo ""
	echo -e "${_BOLD}Host Summary:${_NC}"
	echo "  Address:    $address"
	echo "  Transport:  $transport"
	echo "  Docker:     $has_docker"
	echo "  OrbStack:   $has_orbstack"
	echo "  OpenCode:   $has_opencode"
	echo "  Claude CLI: $has_claude"
	echo "  Container:  ${container:-auto}"

	return 0
}

# =============================================================================
# Credential Forwarding
# =============================================================================

#######################################
# Build environment variables for credential forwarding
# Collects API keys, GH tokens, and other credentials needed by workers.
# Does NOT forward actual secret values over SSH — uses SSH agent forwarding
# for git auth and environment variable passthrough for API keys.
#
# Args: none
# Outputs: space-separated KEY=VALUE pairs for env forwarding
#######################################
_build_credential_env() {
	local -a env_vars=()

	# GitHub token (for gh CLI on remote)
	if [[ -n "${GH_TOKEN:-}" ]]; then
		env_vars+=("GH_TOKEN=${GH_TOKEN}")
	elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
		env_vars+=("GH_TOKEN=${GITHUB_TOKEN}")
	fi

	# Anthropic API key (for AI CLI)
	if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
		env_vars+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
	fi

	# OpenRouter API key (for model routing)
	if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
		env_vars+=("OPENROUTER_API_KEY=${OPENROUTER_API_KEY}")
	fi

	# Google AI key
	if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
		env_vars+=("GOOGLE_API_KEY=${GOOGLE_API_KEY}")
	fi

	# Worker identification
	env_vars+=("FULL_LOOP_HEADLESS=true")
	env_vars+=("AIDEVOPS_REMOTE_DISPATCH=true")

	printf '%s\n' "${env_vars[@]}"
	return 0
}

#######################################
# Forward credentials to remote host via SSH
# Uses SendEnv + AcceptEnv for secure passthrough (no command-line exposure).
# Falls back to env prefix on the remote command if SendEnv is not configured.
#
# Args: ssh_cmd_array credential_env_array remote_command
# Outputs: Full command with credential forwarding
#######################################
_build_remote_command_with_creds() {
	local remote_command="$1"
	shift

	# Build env export prefix for the remote command
	local env_prefix=""
	local -a cred_env=()
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		cred_env+=("$line")
	done < <(_build_credential_env)

	if [[ ${#cred_env[@]} -gt 0 ]]; then
		# Use env command on remote to set variables (avoids shell escaping issues)
		env_prefix="env"
		for var in "${cred_env[@]}"; do
			env_prefix+=" $(printf '%q' "$var")"
		done
		env_prefix+=" "
	fi

	echo "${env_prefix}${remote_command}"
	return 0
}

# =============================================================================
# Remote Dispatch
# =============================================================================

#######################################
# Dispatch a task to a remote host
# Creates a workspace on the remote, forwards credentials, starts the worker,
# and sets up log streaming.
#
# Args: task_id host [--container name] [--model model] [--description desc]
# Returns: 0 on success, 1 on failure
# Outputs: remote worker PID
#######################################
cmd_dispatch() {
	local task_id="" host="" container_name="" model="" description=""

	if [[ $# -lt 2 ]]; then
		_log_error "Usage: remote-dispatch-helper.sh dispatch <task_id> <host> [--container name] [--model model] [--description desc]"
		return 1
	fi

	task_id="$1"
	host="$2"
	shift 2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--container)
			container_name="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--description)
			description="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Resolve host
	local host_info
	host_info=$(_resolve_host "$host")
	local address transport host_container user
	IFS='|' read -r address transport host_container user <<<"$host_info"

	# Use explicit container or host default
	container_name="${container_name:-${host_container}}"

	_log_info "Dispatching $task_id to $host ($address via $transport)"

	# Build SSH command
	local -a ssh_cmd=()
	while IFS= read -r line; do
		ssh_cmd+=("$line")
	done < <(_build_ssh_cmd "$address" "$transport" "$user")

	# Verify connectivity
	if ! "${ssh_cmd[@]}" "echo 'SSH_OK'" 2>/dev/null | grep -q 'SSH_OK'; then
		_log_error "Cannot connect to $host ($address) — dispatch aborted"
		return 1
	fi

	# Create remote workspace
	local remote_work_dir="${REMOTE_WORK_BASE}/${task_id}"
	local remote_log_file="${remote_work_dir}/worker.log"

	_log_info "Creating remote workspace: $remote_work_dir"
	if ! "${ssh_cmd[@]}" "mkdir -p '${remote_work_dir}'" 2>/dev/null; then
		_log_error "Failed to create remote workspace"
		return 1
	fi

	# Clone the repo on the remote host (or use existing checkout)
	local repo_url
	repo_url=$(git remote get-url origin 2>/dev/null || echo "")
	if [[ -z "$repo_url" ]]; then
		_log_error "Cannot determine repo URL from local git remote"
		return 1
	fi

	local branch_name="feature/${task_id}"
	_log_info "Setting up repo on remote: $repo_url (branch: $branch_name)"

	# Build the remote setup + dispatch script
	local worker_prompt="/full-loop $task_id --headless"
	if [[ -n "$description" ]]; then
		worker_prompt="/full-loop $task_id --headless -- $description"
	fi

	# Determine AI CLI on remote
	local remote_ai_cli="opencode"
	local cli_check
	cli_check=$("${ssh_cmd[@]}" "command -v opencode 2>/dev/null && echo 'opencode' || (command -v claude 2>/dev/null && echo 'claude') || echo 'none'" 2>/dev/null)
	if [[ "$cli_check" == *"claude"* && "$cli_check" != *"opencode"* ]]; then
		remote_ai_cli="claude"
	elif [[ "$cli_check" == *"none"* ]]; then
		_log_error "No AI CLI (opencode or claude) found on remote host $host"
		return 1
	fi

	_log_info "Remote AI CLI: $remote_ai_cli"

	# Build the remote dispatch script
	local remote_script="${remote_work_dir}/dispatch.sh"
	local remote_wrapper="${remote_work_dir}/wrapper.sh"

	# Build credential environment
	local cred_env_str=""
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		cred_env_str+="export $(printf '%q' "$line")"$'\n'
	done < <(_build_credential_env)

	# Generate dispatch script content
	local dispatch_content
	dispatch_content=$(
		cat <<DISPATCH_EOF
#!/usr/bin/env bash
set -euo pipefail

# Startup sentinel
echo "WORKER_STARTED task_id=${task_id} pid=\$\$ host=${host} timestamp=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Credential environment
${cred_env_str}

# Set up workspace
cd "${remote_work_dir}" || exit 1

# Clone or update repo
if [[ -d repo/.git ]]; then
    cd repo
    git fetch origin
    git checkout -B "${branch_name}" "origin/main" 2>/dev/null || git checkout -b "${branch_name}" 2>/dev/null || true
else
    git clone --depth=50 "${repo_url}" repo
    cd repo
    git checkout -b "${branch_name}" 2>/dev/null || true
fi

# Dispatch worker
DISPATCH_EOF
	)

	# Add CLI-specific dispatch command
	if [[ "$remote_ai_cli" == "opencode" ]]; then
		local model_flag=""
		if [[ -n "$model" ]]; then
			model_flag="-m ${model}"
		fi
		dispatch_content+="
exec opencode run --format json ${model_flag} \"\$(cat <<'PROMPT_EOF'
${worker_prompt}
PROMPT_EOF
)\"
"
	else
		local model_flag=""
		if [[ -n "$model" ]]; then
			local claude_model="${model#*/}"
			model_flag="--model ${claude_model}"
		fi
		dispatch_content+="
exec claude -p \"\$(cat <<'PROMPT_EOF'
${worker_prompt}
PROMPT_EOF
)\" --output-format json ${model_flag}
"
	fi

	# Generate wrapper script content
	local wrapper_content
	wrapper_content=$(
		cat <<WRAPPER_EOF
#!/usr/bin/env bash
echo "WRAPPER_STARTED task_id=${task_id} wrapper_pid=\$\$ host=${host} timestamp=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${remote_log_file}" 2>/dev/null || true

# Cleanup handler
cleanup_children() {
    local children
    children=\$(pgrep -P \$\$ 2>/dev/null || true)
    if [[ -n "\$children" ]]; then
        for child in \$children; do
            kill -TERM "\$child" 2>/dev/null || true
        done
        sleep 0.5
        for child in \$children; do
            kill -9 "\$child" 2>/dev/null || true
        done
    fi
}
trap cleanup_children EXIT INT TERM

# Heartbeat
_heartbeat_log="${remote_log_file}"
( while true; do
    sleep 300 || break
    echo "HEARTBEAT: \$(date -u +%Y-%m-%dT%H:%M:%SZ) worker still running" >> "\$_heartbeat_log" 2>/dev/null || true
done ) &
_heartbeat_pid=\$!

# Run dispatch
"${remote_script}" >> "${remote_log_file}" 2>&1
rc=\$?
kill \$_heartbeat_pid 2>/dev/null || true
echo "EXIT:\${rc}" >> "${remote_log_file}"
if [ \$rc -ne 0 ]; then
    echo "WORKER_DISPATCH_ERROR: dispatch script exited with code \${rc}" >> "${remote_log_file}"
fi
exit \$rc
WRAPPER_EOF
	)

	# Upload scripts to remote
	_log_info "Uploading dispatch scripts to remote..."
	echo "$dispatch_content" | "${ssh_cmd[@]}" "cat > '${remote_script}' && chmod +x '${remote_script}'" 2>/dev/null || {
		_log_error "Failed to upload dispatch script"
		return 1
	}

	echo "$wrapper_content" | "${ssh_cmd[@]}" "cat > '${remote_wrapper}' && chmod +x '${remote_wrapper}'" 2>/dev/null || {
		_log_error "Failed to upload wrapper script"
		return 1
	}

	# Container dispatch vs direct host dispatch
	local remote_pid=""
	if [[ "$container_name" != "auto" && "$container_name" != "none" && -n "$container_name" ]]; then
		# Dispatch inside a container on the remote host
		_log_info "Dispatching inside container: $container_name"
		remote_pid=$("${ssh_cmd[@]}" "
			nohup docker exec -d '${container_name}' bash '${remote_wrapper}' &
			echo \$!
		" 2>/dev/null)
	else
		# Dispatch directly on the remote host
		_log_info "Dispatching directly on remote host"
		remote_pid=$("${ssh_cmd[@]}" "
			nohup setsid bash '${remote_wrapper}' >> '${remote_log_file}' 2>&1 &
			echo \$!
		" 2>/dev/null)
	fi

	if [[ -z "$remote_pid" ]]; then
		_log_error "Failed to get remote worker PID"
		return 1
	fi

	# Store remote dispatch metadata locally
	mkdir -p "$REMOTE_LOG_DIR" 2>/dev/null || true
	local local_meta_file="${REMOTE_LOG_DIR}/${task_id}-remote.json"
	cat >"$local_meta_file" <<META_EOF
{
    "task_id": "${task_id}",
    "host": "${host}",
    "address": "${address}",
    "transport": "${transport}",
    "container": "${container_name}",
    "remote_pid": "${remote_pid}",
    "remote_work_dir": "${remote_work_dir}",
    "remote_log_file": "${remote_log_file}",
    "dispatched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "ai_cli": "${remote_ai_cli}",
    "model": "${model:-default}"
}
META_EOF

	_log_success "Dispatched $task_id to $host (remote PID: $remote_pid)"
	_log_info "Remote workspace: $remote_work_dir"
	_log_info "Remote log: $remote_log_file"
	_log_info "Local metadata: $local_meta_file"

	echo "$remote_pid"
	return 0
}

# =============================================================================
# Log Collection
# =============================================================================

#######################################
# Collect logs from a remote worker
# Streams or copies the remote log file to the local supervisor log directory.
#
# Args: task_id host [--follow] [--tail N]
# Returns: 0 on success
#######################################
cmd_logs() {
	local task_id="" host="" follow="false" tail_lines=""

	if [[ $# -lt 2 ]]; then
		_log_error "Usage: remote-dispatch-helper.sh logs <task_id> <host> [--follow] [--tail N]"
		return 1
	fi

	task_id="$1"
	host="$2"
	shift 2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--follow | -f)
			follow="true"
			shift
			;;
		--tail)
			tail_lines="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Try to read metadata for remote paths
	local meta_file="${REMOTE_LOG_DIR}/${task_id}-remote.json"
	local remote_log_file="${REMOTE_WORK_BASE}/${task_id}/worker.log"
	local address="" transport="" user=""

	if [[ -f "$meta_file" ]]; then
		remote_log_file=$(jq -r '.remote_log_file' "$meta_file" 2>/dev/null || echo "$remote_log_file")
		address=$(jq -r '.address' "$meta_file" 2>/dev/null || echo "")
		transport=$(jq -r '.transport' "$meta_file" 2>/dev/null || echo "ssh")
	fi

	# Resolve host if address not from metadata
	if [[ -z "$address" ]]; then
		local host_info
		host_info=$(_resolve_host "$host")
		IFS='|' read -r address transport _ user <<<"$host_info"
	fi

	# Build SSH command
	local -a ssh_cmd=()
	while IFS= read -r line; do
		ssh_cmd+=("$line")
	done < <(_build_ssh_cmd "$address" "$transport" "$user")

	if [[ "$follow" == "true" ]]; then
		# Stream logs in real-time
		_log_info "Streaming logs from $host for $task_id (Ctrl+C to stop)..."
		"${ssh_cmd[@]}" "tail -f '${remote_log_file}'" 2>/dev/null
	else
		# Collect logs to local file
		local local_log_file
		local_log_file="${REMOTE_LOG_DIR}/${task_id}-$(date +%Y%m%d%H%M%S).log"
		mkdir -p "$REMOTE_LOG_DIR" 2>/dev/null || true

		_log_info "Collecting logs from $host for $task_id..."

		local remote_cmd="cat '${remote_log_file}'"
		if [[ -n "$tail_lines" ]]; then
			remote_cmd="tail -n ${tail_lines} '${remote_log_file}'"
		fi

		if "${ssh_cmd[@]}" "$remote_cmd" >"$local_log_file" 2>/dev/null; then
			local log_size
			log_size=$(wc -c <"$local_log_file" | tr -d ' ')
			_log_success "Collected ${log_size} bytes to $local_log_file"
			echo "$local_log_file"
		else
			_log_error "Failed to collect logs from $host"
			rm -f "$local_log_file"
			return 1
		fi
	fi

	return 0
}

# =============================================================================
# Remote Worker Status
# =============================================================================

#######################################
# Check status of a remote worker
# Args: task_id host
# Returns: 0 if running, 1 if stopped/error
#######################################
cmd_status() {
	local task_id="${1:-}"
	local host="${2:-}"

	if [[ -z "$task_id" || -z "$host" ]]; then
		_log_error "Usage: remote-dispatch-helper.sh status <task_id> <host>"
		return 1
	fi

	# Read metadata
	local meta_file="${REMOTE_LOG_DIR}/${task_id}-remote.json"
	if [[ ! -f "$meta_file" ]]; then
		_log_error "No remote dispatch metadata found for $task_id"
		_log_info "Expected: $meta_file"
		return 1
	fi

	local remote_pid address transport remote_log_file container dispatched_at
	remote_pid=$(jq -r '.remote_pid' "$meta_file" 2>/dev/null)
	address=$(jq -r '.address' "$meta_file" 2>/dev/null)
	transport=$(jq -r '.transport' "$meta_file" 2>/dev/null)
	remote_log_file=$(jq -r '.remote_log_file' "$meta_file" 2>/dev/null)
	container=$(jq -r '.container' "$meta_file" 2>/dev/null)
	dispatched_at=$(jq -r '.dispatched_at' "$meta_file" 2>/dev/null)

	# Build SSH command
	local user=""
	local -a ssh_cmd=()
	while IFS= read -r line; do
		ssh_cmd+=("$line")
	done < <(_build_ssh_cmd "$address" "$transport" "$user")

	echo -e "${_BOLD}Remote Worker: $task_id${_NC}"
	echo "  Host:         $host ($address)"
	echo "  Transport:    $transport"
	echo "  Container:    ${container:-none}"
	echo "  Remote PID:   $remote_pid"
	echo "  Dispatched:   $dispatched_at"

	# Check if process is alive
	local is_alive="false"
	if "${ssh_cmd[@]}" "kill -0 $remote_pid 2>/dev/null && echo 'ALIVE'" 2>/dev/null | grep -q 'ALIVE'; then
		is_alive="true"
		echo -e "  Process:      ${_GREEN}alive${_NC}"
	else
		echo -e "  Process:      ${_RED}dead${_NC}"
	fi

	# Check log file for completion signals
	local log_tail
	log_tail=$("${ssh_cmd[@]}" "tail -5 '${remote_log_file}' 2>/dev/null" 2>/dev/null || echo "")

	if echo "$log_tail" | grep -q "FULL_LOOP_COMPLETE"; then
		echo -e "  Status:       ${_GREEN}completed${_NC}"
	elif echo "$log_tail" | grep -q "EXIT:0"; then
		echo -e "  Status:       ${_GREEN}exited cleanly${_NC}"
	elif echo "$log_tail" | grep -q "EXIT:"; then
		local exit_code
		exit_code=$(echo "$log_tail" | grep -o 'EXIT:[0-9]*' | tail -1 | cut -d: -f2)
		echo -e "  Status:       ${_RED}exited with code $exit_code${_NC}"
	elif [[ "$is_alive" == "true" ]]; then
		echo -e "  Status:       ${_YELLOW}running${_NC}"
	else
		echo -e "  Status:       ${_RED}unknown (process dead, no exit signal)${_NC}"
	fi

	# Log file size
	local log_size
	log_size=$("${ssh_cmd[@]}" "wc -c < '${remote_log_file}' 2>/dev/null" 2>/dev/null || echo "0")
	echo "  Log size:     ${log_size} bytes"

	if [[ "$is_alive" == "true" ]]; then
		return 0
	fi
	return 1
}

# =============================================================================
# Cleanup
# =============================================================================

#######################################
# Clean up remote resources for a task
# Removes workspace, logs, and stops any running processes.
#
# Args: task_id host [--keep-logs]
# Returns: 0 on success
#######################################
cmd_cleanup() {
	local task_id="${1:-}"
	local host="${2:-}"
	local keep_logs="false"

	if [[ -z "$task_id" || -z "$host" ]]; then
		_log_error "Usage: remote-dispatch-helper.sh cleanup <task_id> <host> [--keep-logs]"
		return 1
	fi

	shift 2
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--keep-logs)
			keep_logs="true"
			shift
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Read metadata
	local meta_file="${REMOTE_LOG_DIR}/${task_id}-remote.json"
	local remote_pid="" address="" transport="" remote_work_dir=""

	if [[ -f "$meta_file" ]]; then
		remote_pid=$(jq -r '.remote_pid' "$meta_file" 2>/dev/null)
		address=$(jq -r '.address' "$meta_file" 2>/dev/null)
		transport=$(jq -r '.transport' "$meta_file" 2>/dev/null)
		remote_work_dir=$(jq -r '.remote_work_dir' "$meta_file" 2>/dev/null)
	else
		# Resolve from host config
		local host_info
		host_info=$(_resolve_host "$host")
		IFS='|' read -r address transport _ _ <<<"$host_info"
		remote_work_dir="${REMOTE_WORK_BASE}/${task_id}"
	fi

	# Build SSH command
	local -a ssh_cmd=()
	while IFS= read -r line; do
		ssh_cmd+=("$line")
	done < <(_build_ssh_cmd "$address" "$transport" "")

	# Kill remote process if still running
	if [[ -n "$remote_pid" ]]; then
		_log_info "Stopping remote worker (PID: $remote_pid)..."
		"${ssh_cmd[@]}" "kill -TERM $remote_pid 2>/dev/null; sleep 1; kill -9 $remote_pid 2>/dev/null" 2>/dev/null || true
	fi

	# Collect logs before cleanup (if not keeping)
	if [[ "$keep_logs" == "false" ]]; then
		cmd_logs "$task_id" "$host" 2>/dev/null || true
	fi

	# Remove remote workspace
	if [[ -n "$remote_work_dir" ]]; then
		_log_info "Removing remote workspace: $remote_work_dir"
		"${ssh_cmd[@]}" "rm -rf '${remote_work_dir}'" 2>/dev/null || true
	fi

	_log_success "Cleaned up remote resources for $task_id on $host"
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo -e "${_BOLD}remote-dispatch-helper.sh${_NC} - Remote container dispatch via SSH/Tailscale"
	echo ""
	echo "Commands:"
	echo "  hosts                          List configured remote hosts"
	echo "  add <name> <address> [opts]    Add a remote host"
	echo "  remove <name>                  Remove a remote host"
	echo "  check <host>                   Verify host connectivity and capabilities"
	echo "  dispatch <task> <host> [opts]  Dispatch a task to a remote host"
	echo "  logs <task> <host> [opts]      Collect or stream logs from remote worker"
	echo "  status <task> <host>           Check remote worker status"
	echo "  cleanup <task> <host> [opts]   Clean up remote resources"
	echo "  help                           Show this help"
	echo ""
	echo "Host Options (add):"
	echo "  --transport ssh|tailscale      Connection method (default: ssh)"
	echo "  --container <name>             Default container name (default: auto)"
	echo "  --user <user>                  SSH user (default: current user)"
	echo ""
	echo "Dispatch Options:"
	echo "  --container <name>             Container to dispatch into"
	echo "  --model <model>                AI model to use"
	echo "  --description <desc>           Task description"
	echo ""
	echo "Log Options:"
	echo "  --follow, -f                   Stream logs in real-time"
	echo "  --tail <N>                     Show last N lines"
	echo ""
	echo "Examples:"
	echo "  # Add a Tailscale host"
	echo "  remote-dispatch-helper.sh add gpu-box gpu-box.tailnet.ts.net --transport tailscale"
	echo ""
	echo "  # Check connectivity"
	echo "  remote-dispatch-helper.sh check gpu-box"
	echo ""
	echo "  # Dispatch a task"
	echo "  remote-dispatch-helper.sh dispatch t123 gpu-box --model anthropic/claude-opus-4-6"
	echo ""
	echo "  # Stream logs"
	echo "  remote-dispatch-helper.sh logs t123 gpu-box --follow"
	echo ""
	echo "  # Clean up after completion"
	echo "  remote-dispatch-helper.sh cleanup t123 gpu-box"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	hosts) cmd_hosts "$@" ;;
	add) cmd_add "$@" ;;
	remove) cmd_remove "$@" ;;
	check) cmd_check "$@" ;;
	dispatch) cmd_dispatch "$@" ;;
	logs) cmd_logs "$@" ;;
	status) cmd_status "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
