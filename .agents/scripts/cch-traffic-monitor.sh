#!/usr/bin/env bash
# cch-traffic-monitor.sh — Capture and diff Claude CLI API traffic
#
# Uses mitmproxy to intercept Claude CLI requests to the Anthropic API,
# extracts the signing-relevant fields, and compares them against our
# computed values to detect protocol changes.
#
# Usage:
#   cch-traffic-monitor.sh capture [--duration N] [--output FILE]
#   cch-traffic-monitor.sh diff <baseline.json> <current.json>
#   cch-traffic-monitor.sh analyse [--output FILE]
#   cch-traffic-monitor.sh check-deps
#
# Prerequisites:
#   brew install mitmproxy   # or pip install mitmproxy
#
# The capture command:
#   1. Starts mitmproxy on localhost:8080
#   2. Runs a simple Claude CLI query through the proxy
#   3. Extracts headers, billing header, body structure
#   4. Saves as a JSON baseline file
#
# The diff command compares two baselines and reports changes.
# The analyse command does capture + compare against cached constants.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
BASELINE_DIR="${HOME}/.aidevops/cch-baselines"
MITM_PORT=8180
MITM_SCRIPT_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
CAPTURE_TIMEOUT=60

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

check_deps() {
	local missing=()
	if ! command -v mitmdump &>/dev/null; then
		missing+=("mitmproxy (brew install mitmproxy)")
	fi
	if ! command -v claude &>/dev/null; then
		missing+=("claude (npm install -g @anthropic-ai/claude-code)")
	fi
	if ! command -v python3 &>/dev/null; then
		missing+=("python3")
	fi
	if ! command -v jq &>/dev/null; then
		missing+=("jq (brew install jq)")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		print_error "Missing dependencies:"
		for dep in "${missing[@]}"; do
			printf '  - %s\n' "$dep" >&2
		done
		return 1
	fi

	print_success "All dependencies available"
	return 0
}

# Create the mitmproxy addon script that extracts request details.
# Copies the external Python addon and sets OUTPUT_FILE for the capture session.
# Prints the path to the created addon file.
create_mitm_addon() {
	local output_file="$1"
	local addon_src="${SCRIPT_DIR}/cch-mitm-addon.py"
	local addon_file="${MITM_SCRIPT_DIR}/cch_capture_addon.py"

	mkdir -p "$MITM_SCRIPT_DIR"
	cp "$addon_src" "$addon_file"
	# Inject the output path — the addon reads OUTPUT_FILE from env at import time
	printf '%s' "$addon_file"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# Parse --duration and --output args for cmd_capture.
# Outputs: CAPTURE_DURATION and CAPTURE_OUTPUT_FILE via stdout as shell assignments.
_capture_parse_args() {
	local duration="$CAPTURE_TIMEOUT"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--duration)
			duration="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	printf 'CAPTURE_DURATION=%s\n' "$duration"
	printf 'CAPTURE_OUTPUT_FILE=%s\n' "$output_file"
	return 0
}

# Start mitmproxy, run a test Claude CLI query through it, then stop it.
# Returns 0 on success, 1 if mitmproxy fails to start.
_capture_run_proxy() {
	local addon_file="$1"
	local duration="$2"
	local capture_output="$3"

	print_info "Starting mitmproxy capture on port ${MITM_PORT}..."
	print_info "Duration: ${duration}s"

	local mitm_pid
	OUTPUT_FILE="$capture_output" \
		mitmdump --listen-port "$MITM_PORT" \
		--set block_global=false \
		--mode regular \
		-s "$addon_file" \
		--quiet &
	mitm_pid=$!

	sleep 2

	if ! kill -0 "$mitm_pid" 2>/dev/null; then
		print_error "mitmproxy failed to start (port ${MITM_PORT} may be in use)"
		return 1
	fi

	print_info "Proxy running (PID ${mitm_pid}). Sending test query through Claude CLI..."

	local test_prompt="Say 'hello' and nothing else."
	HTTPS_PROXY="http://127.0.0.1:${MITM_PORT}" \
		HTTP_PROXY="http://127.0.0.1:${MITM_PORT}" \
		NODE_TLS_REJECT_UNAUTHORIZED=0 \
		claude -p "$test_prompt" --model claude-haiku-4-5 2>/dev/null || true

	sleep 2

	kill "$mitm_pid" 2>/dev/null || true
	wait "$mitm_pid" 2>/dev/null || true
	return 0
}

# Print a human-readable summary of a capture file to stderr.
_capture_show_summary() {
	local output_file="$1"

	if [[ ! -f "$output_file" ]]; then
		print_error "No capture file created"
		return 1
	fi

	local count
	count=$(python3 -c "import json; print(json.load(open('$output_file'))['capture_count'])" 2>/dev/null || echo "0")
	print_success "Captured ${count} request(s) to ${output_file}"

	if [[ "$count" != "0" ]]; then
		python3 "${SCRIPT_DIR}/cch-traffic-summary.py" "$output_file" >&2
	fi
	return 0
}

cmd_capture() {
	local parsed
	parsed=$(_capture_parse_args "$@")
	local duration output_file
	eval "$parsed"
	duration="$CAPTURE_DURATION"
	output_file="$CAPTURE_OUTPUT_FILE"

	check_deps || return 1

	# Default output file
	local version
	version=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
	if [[ -z "$output_file" ]]; then
		mkdir -p "$BASELINE_DIR"
		output_file="${BASELINE_DIR}/capture-v${version}-$(date +%Y%m%d-%H%M%S).json"
	fi

	print_info "Output: ${output_file}"

	local addon_file
	addon_file=$(create_mitm_addon "$output_file")

	_capture_run_proxy "$addon_file" "$duration" "$output_file" || {
		rm -f "$addon_file"
		return 1
	}
	rm -f "$addon_file"

	_capture_show_summary "$output_file" || return 1
	return 0
}

cmd_diff() {
	local baseline="$1"
	local current="$2"

	if [[ ! -f "$baseline" ]]; then
		print_error "Baseline file not found: $baseline"
		return 1
	fi
	if [[ ! -f "$current" ]]; then
		print_error "Current file not found: $current"
		return 1
	fi

	python3 "${SCRIPT_DIR}/cch-traffic-diff.py" "$baseline" "$current"
	return $?
}

# Verify or create the CCH constants cache.
_analyse_verify_cache() {
	local cache_file="${HOME}/.aidevops/cch-constants.json"
	local extract_cmd="${HOME}/.aidevops/agents/scripts/cch-extract.sh"

	if [[ ! -f "$cache_file" ]]; then
		print_info "No cache found — creating..."
		"$extract_cmd" --cache 2>/dev/null
		return 0
	fi

	if "$extract_cmd" --verify 2>/dev/null; then
		print_success "Cache is current"
		return 0
	fi

	print_warning "Cache is stale — updating..."
	"$extract_cmd" --cache 2>/dev/null
	return 0
}

cmd_analyse() {
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	print_info "Running full CCH analysis..."

	# Step 1: Extract constants
	local constants_json
	constants_json=$(~/.aidevops/agents/scripts/cch-extract.sh --extract 2>/dev/null) || {
		print_error "Failed to extract constants"
		return 1
	}
	print_success "Constants extracted"
	printf '%s\n' "$constants_json" >&2

	# Step 2: Verify against cache
	_analyse_verify_cache

	# Step 3: Generate a test header and verify computation
	local test_msg="Say hello and nothing else."
	local our_header
	our_header=$(python3 ~/.aidevops/agents/scripts/cch-sign.py header "$test_msg" --cache 2>/dev/null)
	print_info "Our computed header: ${our_header}"

	# Step 4: If mitmproxy available, capture real traffic
	if command -v mitmdump &>/dev/null; then
		print_info "mitmproxy available — capturing real traffic for comparison..."
		cmd_capture --duration 30 ${output_file:+--output "$output_file"} || {
			print_warning "Traffic capture failed (Claude CLI may not support proxy)"
		}
	else
		print_warning "mitmproxy not installed — skipping traffic capture"
		print_info "Install with: brew install mitmproxy"
	fi

	# Step 5: Check for xxHash presence (protocol change indicator)
	local has_xxhash
	has_xxhash=$(printf '%s' "$constants_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('has_xxhash', False))" 2>/dev/null)
	if [[ "$has_xxhash" == "True" ]]; then
		print_warning "xxHash detected in CLI — body hash computation required"
		print_info "Ensure xxhash Python package is installed: pip install xxhash"
	else
		print_success "No xxHash in CLI — cch=00000 placeholder is sufficient"
	fi

	print_success "Analysis complete"
	return 0
}

cmd_check_deps() {
	check_deps
	return $?
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local action="${1:-analyse}"
	shift || true

	case "$action" in
	capture)
		cmd_capture "$@"
		;;
	diff)
		if [[ $# -lt 2 ]]; then
			print_error "Usage: cch-traffic-monitor.sh diff <baseline.json> <current.json>"
			return 1
		fi
		cmd_diff "$1" "$2"
		;;
	analyse | analyze)
		cmd_analyse "$@"
		;;
	check-deps)
		cmd_check_deps
		;;
	--help | -h | help)
		printf 'Usage: cch-traffic-monitor.sh <command> [options]\n'
		printf '\n'
		printf 'Commands:\n'
		printf '  capture [--duration N] [--output FILE]  Capture Claude CLI API traffic\n'
		printf '  diff <baseline> <current>               Compare two capture files\n'
		printf '  analyse [--output FILE]                  Full analysis pipeline\n'
		printf '  check-deps                               Verify prerequisites\n'
		return 0
		;;
	*)
		print_error "Unknown command: $action"
		return 1
		;;
	esac
}

main "$@"
