#!/usr/bin/env bash
# sandbox-exec-helper.sh — Lightweight execution sandbox for tool/command isolation
# Commands: run | audit | config | help
#
# Wraps command execution with environment clearing, timeout enforcement,
# temp directory isolation, optional network restriction, and network tiering.
# Inspired by OpenFang's WASM sandbox — adapted for shell-native use.
#
# Network tiering (t1412.3): When --network-tiering is enabled, commands that
# access the network have their target domains classified into tiers (1-5).
# Tier 5 domains (exfiltration indicators) are logged and flagged. Tier 4
# (unknown) domains are allowed but flagged for post-session review.
# See network-tier-helper.sh for the full tier model.
#
# Usage:
#   sandbox-exec-helper.sh run "command args"
#   sandbox-exec-helper.sh run --timeout 60 --no-network "curl example.com"
#   sandbox-exec-helper.sh run --network-tiering --worker-id w123 "curl example.com"
#   sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN,NPM_TOKEN" "npm publish"
#   sandbox-exec-helper.sh audit [--last N]
#   sandbox-exec-helper.sh config --show
#   sandbox-exec-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

LOG_PREFIX="SANDBOX"

# =============================================================================
# Constants
# =============================================================================

readonly SANDBOX_DIR="${HOME}/.aidevops/.agent-workspace/sandbox"
readonly SANDBOX_LOG="${SANDBOX_DIR}/executions.jsonl"
readonly SANDBOX_TMP_BASE="${SANDBOX_DIR}/tmp"
readonly DEFAULT_TIMEOUT=120
readonly MAX_TIMEOUT=3600
readonly MAX_OUTPUT_BYTES=10485760 # 10MB per stream

# Minimal environment passthrough — only what's needed for basic operation
readonly DEFAULT_PASSTHROUGH="PATH HOME USER LANG TERM SHELL"

# Network tier helper (t1412.3)
readonly NET_TIER_HELPER="${SCRIPT_DIR}/network-tier-helper.sh"

# Quarantine helper (t1428.4)
readonly QUARANTINE_HELPER="${SCRIPT_DIR}/quarantine-helper.sh"

# =============================================================================
# Helpers
# =============================================================================

log_sandbox() {
	local level="$1"
	local msg="$2"
	printf '[%s] [%s] [%s] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$level" "$msg" >&2
}

# Log execution to JSONL audit trail
log_execution() {
	local command="$1"
	local exit_code="$2"
	local duration="$3"
	local timeout_used="$4"
	local network_blocked="${5:-false}"
	local passthrough_vars="${6:-}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	mkdir -p "$(dirname "$SANDBOX_LOG")"

	# Truncate command for logging (no secrets, max 500 chars)
	local logged_cmd="${command:0:500}"

	printf '{"ts":"%s","cmd":"%s","exit":%d,"duration_s":%.1f,"timeout":%d,"network_blocked":%s,"passthrough":"%s"}\n' \
		"$timestamp" \
		"$(printf '%s' "$logged_cmd" | sed 's/"/\\"/g')" \
		"$exit_code" \
		"$duration" \
		"$timeout_used" \
		"$network_blocked" \
		"$passthrough_vars" \
		>>"$SANDBOX_LOG"
}

# =============================================================================
# Network Tiering Integration (t1412.3)
# =============================================================================

# Extract domains from a command string and check them against network tiers.
# Best-effort heuristic: parses URLs and hostnames from common patterns
# (curl, wget, git clone, npm install from URL, etc.).
# Arguments:
#   $1 - command string
#   $2 - worker ID for logging
_sandbox_check_network_tiers() {
	local command="$1"
	local wid="$2"

	# Extract potential domains from the command using multiple strategies:
	# 1. Full URLs: https://domain.com/... or http://domain.com/...
	# 2. Bare hostnames after networking tools: curl example.com, wget host.io
	# 3. Git SSH patterns: git@github.com:user/repo.git
	# 4. SCP-style: scp file user@host.example.com:/path
	# Excludes: @scope/package (npm), single-label names (localhost, etc.)
	local domains=""
	local url_domains bare_domains git_ssh_domains

	# Strategy 1: Extract domains from http(s) URLs
	url_domains="$(printf '%s' "$command" | grep -oE 'https?://[a-zA-Z0-9._-]+' | sed -E 's|https?://||')" || true

	# Strategy 2: Extract bare hostnames after networking tools that take a URL/host
	# as their primary argument (curl, wget, etc.). Tools where arguments are mixed
	# (scp, rsync) are handled by Strategy 3 via user@host patterns instead.
	# Requires TLD of 2+ alpha chars to avoid matching filenames like "file.txt"
	# and excludes common file extensions (.sh, .py, .js, .json, .txt, .log, .yml, .yaml, .md, .conf)
	bare_domains="$(printf '%s' "$command" | grep -oE '(curl|wget|fetch|nc|ncat|telnet)\s+(-[a-zA-Z0-9]+\s+)*([a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,})' | grep -oE '[a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,}$' | grep -vE '\.(sh|py|js|ts|json|txt|log|yml|yaml|md|conf|cfg|xml|html|css|gz|tar|zip)$')" || true

	# Strategy 3: Extract hosts from user@host patterns (git SSH, ssh, scp, etc.)
	# Matches both git@github.com:user/repo and user@server.example.com
	git_ssh_domains="$(printf '%s' "$command" | grep -oE '[a-zA-Z0-9_-]+@([a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,})' | sed 's/.*@//')" || true

	# Combine and deduplicate all extracted domains
	domains="$(printf '%s\n%s\n%s' "$url_domains" "$bare_domains" "$git_ssh_domains" | grep -v '^$' | sort -u)" || true

	if [[ -z "$domains" ]]; then
		return 0
	fi

	local domain tier_result
	while IFS= read -r domain; do
		[[ -z "$domain" ]] && continue
		tier_result="$("$NET_TIER_HELPER" classify "$domain")" || true

		if [[ "$tier_result" == "5" ]]; then
			log_sandbox "WARN" "Network tier DENY: ${domain} (Tier 5 — exfiltration indicator)"
			"$NET_TIER_HELPER" log-access "$domain" "$wid" "pre-check-deny" || true
			# Quarantine denied domains for review — user may want to allow (t1428.4)
			if [[ -x "$QUARANTINE_HELPER" ]]; then
				"$QUARANTINE_HELPER" add \
					--source sandbox-exec \
					--severity HIGH \
					--category denied_domain \
					--content "$domain" \
					--worker-id "$wid" \
					>/dev/null 2>&1 || true
			fi
		elif [[ "$tier_result" == "4" ]]; then
			log_sandbox "INFO" "Network tier FLAG: ${domain} (Tier 4 — unknown domain)"
			# Note: Tier 4 quarantine is handled by network-tier-helper.sh log_access
			"$NET_TIER_HELPER" log-access "$domain" "$wid" "pre-check-flag" || true
		else
			# Tiers 1-3: log silently (tier helper handles routing)
			"$NET_TIER_HELPER" log-access "$domain" "$wid" "pre-check-allow" || true
		fi
	done <<<"$domains"

	return 0
}

# =============================================================================
# Sandbox Execution
# =============================================================================

sandbox_run() {
	local timeout_secs="$DEFAULT_TIMEOUT"
	local block_network=false
	local network_tiering=false
	local worker_id="sandbox-$$"
	local extra_passthrough=""
	local command=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case $1 in
		--timeout)
			timeout_secs="$2"
			if ((timeout_secs > MAX_TIMEOUT)); then
				log_sandbox "WARN" "Timeout capped at ${MAX_TIMEOUT}s (requested ${timeout_secs}s)"
				timeout_secs=$MAX_TIMEOUT
			fi
			shift 2
			;;
		--no-network)
			block_network=true
			shift
			;;
		--network-tiering)
			network_tiering=true
			shift
			;;
		--worker-id)
			worker_id="$2"
			shift 2
			;;
		--passthrough)
			extra_passthrough="$2"
			shift 2
			;;
		--)
			shift
			command="$*"
			break
			;;
		*)
			command="$*"
			break
			;;
		esac
	done

	if [[ -z "$command" ]]; then
		log_sandbox "ERROR" "No command provided"
		return 1
	fi

	# Create isolated temp directory
	local exec_id
	exec_id="$(date +%s)-$$"
	local exec_tmpdir="${SANDBOX_TMP_BASE}/${exec_id}"
	mkdir -p "$exec_tmpdir"

	# Build environment — start with env -i then add vars
	local -a env_args=("env" "-i")

	# Add default passthrough vars (only if they exist in current env)
	local var
	for var in $DEFAULT_PASSTHROUGH; do
		if [[ -n "${!var:-}" ]]; then
			env_args+=("${var}=${!var}")
		fi
	done

	# Override TMPDIR to isolated directory
	env_args+=("TMPDIR=${exec_tmpdir}")

	# Add extra passthrough vars
	if [[ -n "$extra_passthrough" ]]; then
		local extra_var
		while IFS= read -r extra_var; do
			# trim whitespace
			extra_var="${extra_var#"${extra_var%%[![:space:]]*}"}"
			extra_var="${extra_var%"${extra_var##*[![:space:]]}"}"
			if [[ -n "${!extra_var:-}" ]]; then
				env_args+=("${extra_var}=${!extra_var}")
			else
				log_sandbox "WARN" "Passthrough var '${extra_var}' not set in environment, skipping"
			fi
		done < <(printf '%s\n' "$extra_passthrough" | tr ',' '\n')
	fi

	# Capture output files
	local stdout_file="${exec_tmpdir}/stdout"
	local stderr_file="${exec_tmpdir}/stderr"

	log_sandbox "INFO" "Executing (timeout=${timeout_secs}s, network_blocked=${block_network}, tiering=${network_tiering}): ${command:0:200}"

	# Network tiering pre-check (t1412.3): extract domains from the command
	# and check them against the tier classification before execution.
	# This is a best-effort heuristic — it catches obvious cases like
	# "curl evil.ngrok.io" but cannot intercept runtime DNS resolution.
	# The primary value is logging + post-session review, not hard blocking.
	if [[ "$network_tiering" == true ]] && [[ -x "$NET_TIER_HELPER" ]]; then
		_sandbox_check_network_tiers "$command" "$worker_id"
	fi

	local start_time
	start_time="$(date +%s)"
	local exit_code=0

	# Execute with timeout and clean environment
	if [[ "$block_network" == true ]] && command -v sandbox-exec &>/dev/null; then
		# macOS seatbelt: deny network access
		local seatbelt_profile="(version 1)(allow default)(deny network*)"
		timeout_sec "$timeout_secs" \
			sandbox-exec -p "$seatbelt_profile" \
			"${env_args[@]}" \
			bash -c "$command" \
			>"$stdout_file" 2>"$stderr_file" || exit_code=$?
	else
		if [[ "$block_network" == true ]]; then
			log_sandbox "WARN" "Network blocking requested but sandbox-exec not available (non-macOS); proceeding without"
		fi
		timeout_sec "$timeout_secs" \
			"${env_args[@]}" \
			bash -c "$command" \
			>"$stdout_file" 2>"$stderr_file" || exit_code=$?
	fi

	local end_time
	end_time="$(date +%s)"
	local duration=$((end_time - start_time))

	# Handle timeout (exit code 124 from timeout command)
	if [[ $exit_code -eq 124 ]]; then
		log_sandbox "WARN" "Command timed out after ${timeout_secs}s"
	fi

	# Output results (truncated to MAX_OUTPUT_BYTES)
	if [[ -f "$stdout_file" ]] && [[ -s "$stdout_file" ]]; then
		head -c "$MAX_OUTPUT_BYTES" "$stdout_file"
	fi
	if [[ -f "$stderr_file" ]] && [[ -s "$stderr_file" ]]; then
		head -c "$MAX_OUTPUT_BYTES" "$stderr_file" >&2
	fi

	# Audit log
	log_execution "$command" "$exit_code" "$duration" "$timeout_secs" "$block_network" "$extra_passthrough"

	# Async cleanup of old temp dirs (older than 60 minutes)
	find "$SANDBOX_TMP_BASE" -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + 2>/dev/null &

	return "$exit_code"
}

# =============================================================================
# Audit
# =============================================================================

sandbox_audit() {
	local last_n=20

	while [[ $# -gt 0 ]]; do
		case $1 in
		--last)
			last_n="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$SANDBOX_LOG" ]]; then
		echo "No sandbox executions logged yet."
		return 0
	fi

	echo "Last ${last_n} sandboxed executions:"
	echo "---"
	tail -n "$last_n" "$SANDBOX_LOG" | while IFS= read -r line; do
		local ts cmd exit_code duration
		ts="$(printf '%s' "$line" | jq -r '.ts // "?"')"
		cmd="$(printf '%s' "$line" | jq -r '.cmd // "?"' | head -c 80)"
		exit_code="$(printf '%s' "$line" | jq -r '.exit // "?"')"
		duration="$(printf '%s' "$line" | jq -r '.duration_s // "?"')"
		printf '%s  exit=%s  %ss  %s\n' "$ts" "$exit_code" "$duration" "$cmd"
	done
}

# =============================================================================
# Config
# =============================================================================

sandbox_config() {
	echo "Sandbox configuration:"
	echo "  Log:          ${SANDBOX_LOG}"
	echo "  Tmp base:     ${SANDBOX_TMP_BASE}"
	echo "  Timeout:      ${DEFAULT_TIMEOUT}s (max ${MAX_TIMEOUT}s)"
	echo "  Max output:   $((MAX_OUTPUT_BYTES / 1048576))MB per stream"
	echo "  Passthrough:  ${DEFAULT_PASSTHROUGH}"
	echo "  Net tiering:  $([ -x "$NET_TIER_HELPER" ] && echo "available" || echo "not found")"
	echo ""
	if [[ -f "$SANDBOX_LOG" ]]; then
		local count
		count="$(wc -l <"$SANDBOX_LOG" | xargs)"
		echo "  Executions logged: ${count}"
	else
		echo "  Executions logged: 0"
	fi
}

# =============================================================================
# Help
# =============================================================================

sandbox_help() {
	cat <<'HELP'
sandbox-exec-helper.sh — Lightweight execution sandbox

Commands:
  run "command"              Execute command in sandboxed environment
  audit [--last N]           Show recent sandboxed executions
  config --show              Show sandbox configuration
  help                       Show this help

Run options:
  --timeout N                Timeout in seconds (default: 120, max: 3600)
  --no-network               Block network access (macOS only, uses seatbelt)
  --network-tiering          Enable domain classification and logging (t1412.3)
  --worker-id ID             Worker identifier for network tier logs
  --passthrough "VAR1,VAR2"  Additional env vars to pass through

Examples:
  sandbox-exec-helper.sh run "ls -la /tmp"
  sandbox-exec-helper.sh run --timeout 60 "npm test"
  sandbox-exec-helper.sh run --no-network "python3 script.py"
  sandbox-exec-helper.sh run --network-tiering --worker-id w123 "curl https://api.github.com/repos"
  sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN" "gh pr list"
  sandbox-exec-helper.sh audit --last 10

Security model:
  - Environment cleared (env -i) with minimal passthrough
  - Each execution gets isolated TMPDIR
  - Configurable timeout with hard kill
  - Optional network blocking (macOS seatbelt)
  - Network domain tiering: classify, log, flag unknown domains (t1412.3)
  - All executions logged to JSONL audit trail
  - Output capped at 10MB per stream
HELP
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	run) sandbox_run "$@" ;;
	audit) sandbox_audit "$@" ;;
	config) sandbox_config "$@" ;;
	help) sandbox_help ;;
	*)
		log_sandbox "ERROR" "Unknown command: ${cmd}"
		sandbox_help
		return 1
		;;
	esac
}

main "$@"
