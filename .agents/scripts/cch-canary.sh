#!/usr/bin/env bash
# cch-canary.sh — Daily verification that our signing matches the real Claude CLI
#
# Makes a cheap real Claude CLI call, extracts the billing header from its
# debug log, computes our version, and compares. Logs a framework issue
# if they diverge.
#
# Usage:
#   cch-canary.sh              # Run canary check (default: quiet, exit code only)
#   cch-canary.sh --verbose    # Show details
#   cch-canary.sh --cron       # Cron/launchd mode (logs to file, issues on drift)
#   cch-canary.sh --install    # Install as daily launchd job
#   cch-canary.sh --uninstall  # Remove launchd job
#
# Exit codes:
#   0 = match (or no CLI available)
#   1 = drift detected
#   2 = infrastructure error (can't run CLI, missing deps)

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CANARY_LOG="${HOME}/.aidevops/logs/cch-canary.log"
CANARY_STATE="${HOME}/.aidevops/cch-canary-state.json"
SCRIPTS_DIR="${HOME}/.aidevops/agents/scripts"
PLIST_LABEL="sh.aidevops.cch-canary"
PLIST_FILE="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

# Cheap test prompt — short to minimise token cost
CANARY_PROMPT="hi"
CANARY_MODEL="claude-haiku-4-5"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

print_info() {
	printf '\033[0;34m[INFO]\033[0m %s\n' "$1" >&2
	return 0
}
print_success() {
	printf '\033[0;32m[OK]\033[0m %s\n' "$1" >&2
	return 0
}
print_error() {
	printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2
	return 0
}
print_warning() {
	printf '\033[0;33m[WARN]\033[0m %s\n' "$1" >&2
	return 0
}

log_to_file() {
	local msg="$1"
	local log_dir
	log_dir=$(dirname "$CANARY_LOG")
	mkdir -p "$log_dir"
	printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" >>"$CANARY_LOG"
	return 0
}

# ---------------------------------------------------------------------------
# Core helpers (decomposed from run_canary)
# ---------------------------------------------------------------------------

# _canary_preflight: verify deps and detect CLI version.
# Outputs cli_version to stdout. Returns 0=ok, 2=infra error.
_canary_preflight() {
	local verbose="$1"

	if ! command -v claude &>/dev/null; then
		[[ "$verbose" == "true" ]] && print_warning "Claude CLI not installed — skipping canary"
		return 0
	fi

	if ! command -v python3 &>/dev/null; then
		[[ "$verbose" == "true" ]] && print_error "python3 required"
		return 2
	fi

	local cli_version
	cli_version=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
	if [[ -z "$cli_version" ]]; then
		[[ "$verbose" == "true" ]] && print_error "Could not detect Claude CLI version"
		return 2
	fi

	[[ "$verbose" == "true" ]] && print_info "Claude CLI v${cli_version}"
	printf '%s' "$cli_version"
	return 0
}

# _canary_invoke_cli: run the CLI with a timeout and capture debug output.
# Outputs the debug file path to stdout. Returns 0=ok, 2=infra error.
_canary_invoke_cli() {
	local verbose="$1"
	local debug_file
	debug_file=$(mktemp "${TMPDIR:-/tmp}/cch-canary-debug.XXXXXX")

	[[ "$verbose" == "true" ]] && print_info "Sending canary request via real CLI..."

	# Use background process + kill for portable timeout (macOS lacks coreutils timeout)
	local cli_exit=0
	claude -p "$CANARY_PROMPT" \
		--model "$CANARY_MODEL" \
		--debug-file "$debug_file" \
		>/dev/null 2>/dev/null &
	local cli_pid=$!
	local waited=0
	while kill -0 "$cli_pid" 2>/dev/null && [[ $waited -lt 45 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "$cli_pid" 2>/dev/null; then
		kill "$cli_pid" 2>/dev/null || true
		wait "$cli_pid" 2>/dev/null || true
		cli_exit=124
	else
		wait "$cli_pid" 2>/dev/null || cli_exit=$?
	fi

	if [[ "$cli_exit" -ne 0 && "$cli_exit" -ne 124 ]]; then
		[[ "$verbose" == "true" ]] && print_warning "Claude CLI exited ${cli_exit} — may be auth issue"
		rm -f "$debug_file"
		return 2
	fi

	printf '%s' "$debug_file"
	return 0
}

# _canary_extract_header: pull the billing header from the debug log file.
# Outputs the header string to stdout. Returns 0=ok, 2=not found.
_canary_extract_header() {
	local verbose="$1"
	local debug_file="$2"

	local real_header
	real_header=$(grep -oP 'attribution header \K.*' "$debug_file" 2>/dev/null | head -1 || true)
	rm -f "$debug_file"

	if [[ -z "$real_header" ]]; then
		[[ "$verbose" == "true" ]] && print_warning "No billing header in debug log — CLI may have changed logging format"
		return 2
	fi

	[[ "$verbose" == "true" ]] && print_info "Real header: ${real_header}"
	printf '%s' "$real_header"
	return 0
}

# _canary_compare_versions: compare our computed suffix against the real one.
# Sets DRIFT_DETECTED and DRIFT_DETAILS in the caller's scope via stdout lines:
#   drift_detected=<true|false>
#   drift_details=<string>
# Returns 0 always (drift state is communicated via output).
_canary_compare_versions() {
	local verbose="$1"
	local cli_version="$2"
	local our_suffix="$3"
	local real_version_suffix="$4"
	local real_cch="$5"

	local drift_detected="false"
	local drift_details=""
	local our_cc_version="${cli_version}.${our_suffix}"

	[[ "$verbose" == "true" ]] && print_info "Our cc_version: ${our_cc_version}"
	[[ "$verbose" == "true" ]] && print_info "Real cc_version: ${real_version_suffix}"

	if [[ "$our_cc_version" != "$real_version_suffix" ]]; then
		local real_suffix="${real_version_suffix##*.}"
		[[ "$verbose" == "true" ]] && print_warning "SHA-256 mismatch (ours=${our_suffix}, real=${real_suffix}). Trying alternatives..."

		local algo_match=""
		algo_match=$(PROMPT="$CANARY_PROMPT" VERSION="$cli_version" REAL_SUFFIX="$real_suffix" python3 -c '
import hashlib, hmac, os

prompt = os.environ["PROMPT"]
version = os.environ["VERSION"]
real_suffix = os.environ["REAL_SUFFIX"]
salt = "59cf53e54c78"
indices = [4, 7, 20]
chars = "".join(prompt[i] if i < len(prompt) else "0" for i in indices)
payload = f"{salt}{chars}{version}"

algos = {
    "sha256": lambda: hashlib.sha256(payload.encode()).hexdigest()[:3],
    "sha512": lambda: hashlib.sha512(payload.encode()).hexdigest()[:3],
    "sha384": lambda: hashlib.sha384(payload.encode()).hexdigest()[:3],
    "sha3_256": lambda: hashlib.sha3_256(payload.encode()).hexdigest()[:3],
    "md5": lambda: hashlib.md5(payload.encode()).hexdigest()[:3],
    "hmac_sha256_salt": lambda: hmac.new(salt.encode(), (chars + version).encode(), hashlib.sha256).hexdigest()[:3],
    "hmac_sha256_version": lambda: hmac.new(version.encode(), (salt + chars).encode(), hashlib.sha256).hexdigest()[:3],
    "sha256_no_salt": lambda: hashlib.sha256((chars + version).encode()).hexdigest()[:3],
    "sha256_reverse": lambda: hashlib.sha256((version + chars + salt).encode()).hexdigest()[:3],
}

for name, fn in algos.items():
    try:
        if fn() == real_suffix:
            print(name)
            break
    except Exception:
        pass
else:
    print("")
' 2>/dev/null || true)

		if [[ -n "$algo_match" ]]; then
			[[ "$verbose" == "true" ]] && print_warning "Alternative algorithm matched: ${algo_match}"
			drift_detected="true"
			drift_details="algorithm_changed: sha256->${algo_match} (suffix still computable)"
		else
			drift_detected="true"
			drift_details="cc_version: ours=${our_cc_version} real=${real_version_suffix} (no known algorithm matched)"
		fi
	fi

	# Check if cch is still 00000 (Node.js behaviour)
	if [[ "$real_cch" != "00000" && -n "$real_cch" ]]; then
		drift_detected="true"
		drift_details="${drift_details:+${drift_details}; }cch: expected=00000 real=${real_cch} (body hash now active)"
	fi

	printf 'drift_detected=%s\ndrift_details=%s\n' "$drift_detected" "$drift_details"
	return 0
}

# _canary_save_state: persist check results to the state JSON file.
_canary_save_state() {
	local drift_detected="$1"
	local drift_details="$2"
	local cli_version="$3"
	local our_suffix="$4"
	local real_header="$5"
	local real_cch="$6"
	local real_entrypoint="$7"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local state_dir
	state_dir=$(dirname "$CANARY_STATE")
	mkdir -p "$state_dir"

	local state_json
	state_json=$(DRIFT="$drift_detected" DRIFT_DETAILS="$drift_details" CLI_VERSION="$cli_version" \
		OUR_SUFFIX="$our_suffix" REAL_HEADER="$real_header" NOW_ISO="$now_iso" \
		REAL_CCH="$real_cch" REAL_ENTRYPOINT="$real_entrypoint" \
		python3 -c '
import json, os
print(json.dumps({
    "last_check": os.environ["NOW_ISO"],
    "cli_version": os.environ["CLI_VERSION"],
    "drift_detected": os.environ["DRIFT"] == "true",
    "drift_details": os.environ["DRIFT_DETAILS"] or None,
    "our_suffix": os.environ["OUR_SUFFIX"],
    "real_header": os.environ["REAL_HEADER"],
    "real_cch": os.environ["REAL_CCH"],
    "real_entrypoint": os.environ["REAL_ENTRYPOINT"],
}, indent=2))
' 2>/dev/null || true)

	if [[ -n "$state_json" ]]; then
		printf '%s\n' "$state_json" >"$CANARY_STATE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Core: run canary and compare (orchestrator)
# ---------------------------------------------------------------------------

run_canary() {
	local verbose="${1:-false}"

	# Pre-flight: check deps and get CLI version
	local cli_version
	cli_version=$(_canary_preflight "$verbose") || return $?
	# Empty output means Claude CLI not installed — skip gracefully
	[[ -z "$cli_version" ]] && return 0

	# Invoke CLI and capture debug log
	local debug_file
	debug_file=$(_canary_invoke_cli "$verbose") || return $?

	# Extract billing header from debug log
	local real_header
	real_header=$(_canary_extract_header "$verbose" "$debug_file") || return $?

	# Parse header fields
	local real_version_suffix real_entrypoint real_cch
	real_version_suffix=$(printf '%s' "$real_header" | grep -oP 'cc_version=\K[^;]+' || true)
	real_entrypoint=$(printf '%s' "$real_header" | grep -oP 'cc_entrypoint=\K[^;]+' || true)
	real_cch=$(printf '%s' "$real_header" | grep -oP 'cch=\K[^;]+' || true)

	# Compute our version suffix
	local our_suffix
	our_suffix=$(python3 "${SCRIPTS_DIR}/cch-sign.py" suffix "$CANARY_PROMPT" --cache 2>/dev/null || true)
	if [[ -z "$our_suffix" ]]; then
		[[ "$verbose" == "true" ]] && print_error "cch-sign.py failed — cache may be missing"
		[[ "$verbose" == "true" ]] && print_info "Run: cch-extract.sh --cache"
		return 2
	fi

	# Compare versions and detect drift
	local compare_out drift_detected drift_details
	compare_out=$(_canary_compare_versions "$verbose" "$cli_version" "$our_suffix" \
		"$real_version_suffix" "$real_cch")
	drift_detected=$(printf '%s' "$compare_out" | grep '^drift_detected=' | cut -d= -f2-)
	drift_details=$(printf '%s' "$compare_out" | grep '^drift_details=' | cut -d= -f2-)

	# Persist state
	_canary_save_state "$drift_detected" "$drift_details" "$cli_version" \
		"$our_suffix" "$real_header" "$real_cch" "$real_entrypoint"

	# Report
	if [[ "$drift_detected" == "true" ]]; then
		[[ "$verbose" == "true" ]] && print_error "DRIFT DETECTED: ${drift_details}"
		log_to_file "DRIFT: ${drift_details} (CLI v${cli_version})"
		return 1
	fi

	[[ "$verbose" == "true" ]] && print_success "No drift — signing matches CLI v${cli_version}"
	log_to_file "OK: CLI v${cli_version} suffix=${our_suffix} cch=${real_cch}"
	return 0
}

# ---------------------------------------------------------------------------
# Helper: update canary state file with drift-logged timestamp
# ---------------------------------------------------------------------------

_canary_update_drift_state() {
	[[ -f "$CANARY_STATE" ]] || return 0
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local updated
	updated=$(NOW_ISO="$now_iso" python3 -c '
import json, os, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
state["last_drift_logged"] = os.environ["NOW_ISO"]
print(json.dumps(state, indent=2))
' "$CANARY_STATE" 2>/dev/null)
	[[ -z "$updated" ]] || printf '%s\n' "$updated" >"$CANARY_STATE"
	return 0
}

# ---------------------------------------------------------------------------
# Cron/launchd mode: run canary, log framework issue on drift
# ---------------------------------------------------------------------------

cmd_cron() {
	local exit_code=0
	run_canary "false" || exit_code=$?

	if [[ "$exit_code" -eq 1 ]]; then
		# Drift detected — log a framework issue if not already logged recently
		local already_logged="false"
		if [[ -f "$CANARY_STATE" ]]; then
			already_logged=$(python3 -c "
import json, sys
from datetime import datetime, timedelta, timezone
with open(sys.argv[1]) as f:
    state = json.load(f)
# Don't re-log if we logged within the last 24h
last = state.get('last_drift_logged')
if last:
    last_dt = datetime.fromisoformat(last.replace('Z', '+00:00'))
    if datetime.now(timezone.utc) - last_dt < timedelta(hours=24):
        print('true')
        sys.exit(0)
print('false')
" "$CANARY_STATE" 2>/dev/null || echo "false")
		fi

		if [[ "$already_logged" == "false" ]]; then
			log_to_file "DRIFT: logging framework issue"
			_canary_update_drift_state
			# Log the issue via framework helper if available
			[[ ! -x "${SCRIPTS_DIR}/framework-routing-helper.sh" ]] ||
				"${SCRIPTS_DIR}/framework-routing-helper.sh" log-framework-issue \
					"Client request format drift detected — review signing constants" \
					2>/dev/null || true
		fi
	fi

	return "$exit_code"
}

# ---------------------------------------------------------------------------
# launchd install/uninstall
# ---------------------------------------------------------------------------

cmd_install() {
	local script_path="${SCRIPTS_DIR}/cch-canary.sh"

	if [[ ! -x "$script_path" ]]; then
		print_error "Script not found at ${script_path}"
		print_info "Run: aidevops setup"
		return 1
	fi

	mkdir -p "$(dirname "$PLIST_FILE")"

	# Run daily at 06:00 local time
	cat >"$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script_path}</string>
        <string>--cron</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${HOME}/.aidevops/logs/cch-canary-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.aidevops/logs/cch-canary-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

	launchctl unload "$PLIST_FILE" 2>/dev/null || true
	launchctl load "$PLIST_FILE"

	print_success "Installed daily canary: ${PLIST_LABEL} (runs at 06:00)"
	print_info "Plist: ${PLIST_FILE}"
	print_info "Log: ${CANARY_LOG}"
	return 0
}

cmd_uninstall() {
	if [[ -f "$PLIST_FILE" ]]; then
		launchctl unload "$PLIST_FILE" 2>/dev/null || true
		rm -f "$PLIST_FILE"
		print_success "Removed daily canary: ${PLIST_LABEL}"
	else
		print_info "No canary plist found"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local action="${1:-}"

	case "$action" in
	--verbose | -v)
		run_canary "true"
		;;
	--cron | -c)
		cmd_cron
		;;
	--install)
		cmd_install
		;;
	--uninstall)
		cmd_uninstall
		;;
	--help | -h)
		printf 'Usage: cch-canary.sh [--verbose|--cron|--install|--uninstall]\n'
		printf '\n'
		printf 'Daily verification that our request signing matches the real CLI.\n'
		printf '\n'
		printf 'Options:\n'
		printf '  (default)     Quiet check — exit code only (0=match, 1=drift, 2=error)\n'
		printf '  --verbose     Show comparison details\n'
		printf '  --cron        Cron mode — logs drift and creates framework issue\n'
		printf '  --install     Install as daily launchd job (06:00)\n'
		printf '  --uninstall   Remove launchd job\n'
		return 0
		;;
	"")
		run_canary "false"
		;;
	*)
		print_error "Unknown option: $action"
		return 1
		;;
	esac
}

main "$@"
