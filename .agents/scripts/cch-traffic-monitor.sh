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

# Create the mitmproxy addon script that extracts request details
create_mitm_addon() {
	local output_file="$1"
	local addon_file="${MITM_SCRIPT_DIR}/cch_capture_addon.py"

	mkdir -p "$MITM_SCRIPT_DIR"

	OUTPUT_FILE="$output_file" python3 -c '
import os
addon = """
import json
import mitmproxy.http

OUTPUT_FILE = """ + repr(os.environ["OUTPUT_FILE"]) + """

class CCHCapture:
    def __init__(self):
        self.requests = []

    def request(self, flow: mitmproxy.http.HTTPFlow):
        # Only capture Anthropic API requests
        if "api.anthropic.com" not in flow.request.pretty_host:
            if "claude.ai" not in flow.request.pretty_host:
                return

        if "/v1/messages" not in flow.request.path:
            return

        entry = {
            "url": flow.request.pretty_url,
            "method": flow.request.method,
            "path": flow.request.path,
            "headers": dict(flow.request.headers),
            "body": None,
            "billing_header": None,
            "system_blocks": None,
        }

        # Parse body
        if flow.request.content:
            try:
                body = json.loads(flow.request.content)
                # Extract signing-relevant fields (never log tokens)
                entry["body"] = {
                    "model": body.get("model"),
                    "thinking": body.get("thinking"),
                    "speed": body.get("speed"),
                    "research_preview_2026_02": body.get("research_preview_2026_02"),
                    "context_management": body.get("context_management"),
                    "has_tools": "tools" in body,
                    "tool_count": len(body.get("tools", [])),
                    "message_count": len(body.get("messages", [])),
                    "has_metadata": "metadata" in body,
                    "betas": body.get("betas"),
                    "body_keys": sorted(body.keys()),
                }

                # Extract system blocks (billing header is first)
                system = body.get("system", [])
                if isinstance(system, list):
                    entry["system_blocks"] = []
                    for i, block in enumerate(system):
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            if "billing-header" in text or "x-anthropic" in text:
                                entry["billing_header"] = text
                            entry["system_blocks"].append({
                                "index": i,
                                "type": block.get("type"),
                                "has_cache_control": "cache_control" in block,
                                "text_preview": text[:120] + "..." if len(text) > 120 else text,
                            })
            except json.JSONDecodeError:
                entry["body"] = {"error": "not JSON"}

        # Sanitise headers (remove auth tokens)
        safe_headers = {}
        for k, v in entry["headers"].items():
            kl = k.lower()
            if kl == "authorization":
                safe_headers[k] = "Bearer <REDACTED>"
            elif kl == "cookie":
                safe_headers[k] = "<REDACTED>"
            else:
                safe_headers[k] = v
        entry["headers"] = safe_headers

        self.requests.append(entry)

    def done(self):
        with open(OUTPUT_FILE, "w") as f:
            json.dump({
                "capture_count": len(self.requests),
                "requests": self.requests,
            }, f, indent=2)

addons = [CCHCapture()]
"""
print(addon)
' >"$addon_file"

	printf '%s' "$addon_file"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_capture() {
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

	check_deps || return 1

	# Default output file
	local version
	version=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
	if [[ -z "$output_file" ]]; then
		mkdir -p "$BASELINE_DIR"
		output_file="${BASELINE_DIR}/capture-v${version}-$(date +%Y%m%d-%H%M%S).json"
	fi

	# Create the mitmproxy addon
	local addon_file
	addon_file=$(create_mitm_addon "$output_file")

	print_info "Starting mitmproxy capture on port ${MITM_PORT}..."
	print_info "Output: ${output_file}"
	print_info "Duration: ${duration}s"

	# Start mitmdump in background
	local mitm_pid
	mitmdump --listen-port "$MITM_PORT" \
		--set block_global=false \
		--mode regular \
		-s "$addon_file" \
		--quiet &
	mitm_pid=$!

	# Give it a moment to start
	sleep 2

	if ! kill -0 "$mitm_pid" 2>/dev/null; then
		print_error "mitmproxy failed to start (port ${MITM_PORT} may be in use)"
		return 1
	fi

	print_info "Proxy running (PID ${mitm_pid}). Sending test query through Claude CLI..."

	# Run Claude CLI through the proxy
	local test_prompt="Say 'hello' and nothing else."
	HTTPS_PROXY="http://127.0.0.1:${MITM_PORT}" \
		HTTP_PROXY="http://127.0.0.1:${MITM_PORT}" \
		NODE_TLS_REJECT_UNAUTHORIZED=0 \
		claude -p "$test_prompt" --model claude-haiku-4-5 2>/dev/null || true

	# Wait a moment for the capture to complete
	sleep 2

	# Stop mitmproxy
	kill "$mitm_pid" 2>/dev/null || true
	wait "$mitm_pid" 2>/dev/null || true

	# Clean up addon
	rm -f "$addon_file"

	if [[ -f "$output_file" ]]; then
		local count
		count=$(python3 -c "import json; print(json.load(open('$output_file'))['capture_count'])" 2>/dev/null || echo "0")
		print_success "Captured ${count} request(s) to ${output_file}"

		if [[ "$count" != "0" ]]; then
			# Show summary
			python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for i, req in enumerate(data['requests']):
    print(f'  Request {i+1}:')
    print(f'    Path: {req[\"path\"]}')
    print(f'    User-Agent: {req[\"headers\"].get(\"user-agent\", \"unknown\")}')
    if req.get('billing_header'):
        print(f'    Billing: {req[\"billing_header\"][:80]}...')
    if req.get('body'):
        print(f'    Model: {req[\"body\"].get(\"model\", \"unknown\")}')
        print(f'    Body keys: {req[\"body\"].get(\"body_keys\", [])}')
" "$output_file" >&2
		fi
	else
		print_error "No capture file created"
		return 1
	fi
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

	BASELINE="$baseline" CURRENT="$current" python3 -c '
import json, os, sys

with open(os.environ["BASELINE"]) as f:
    base = json.load(f)
with open(os.environ["CURRENT"]) as f:
    curr = json.load(f)

base_req = base["requests"][0] if base["requests"] else {}
curr_req = curr["requests"][0] if curr["requests"] else {}

changes = []

# Compare headers
base_headers = set(base_req.get("headers", {}).keys())
curr_headers = set(curr_req.get("headers", {}).keys())
new_headers = curr_headers - base_headers
removed_headers = base_headers - curr_headers
if new_headers:
    changes.append(f"NEW HEADERS: {sorted(new_headers)}")
if removed_headers:
    changes.append(f"REMOVED HEADERS: {sorted(removed_headers)}")

for h in base_headers & curr_headers:
    bv = base_req["headers"].get(h, "")
    cv = curr_req["headers"].get(h, "")
    if h.lower() == "authorization":
        continue  # always redacted
    if bv != cv:
        changes.append(f"CHANGED HEADER {h}: {bv!r} -> {cv!r}")

# Compare billing header
bb = base_req.get("billing_header", "")
cb = curr_req.get("billing_header", "")
if bb != cb:
    changes.append(f"BILLING HEADER CHANGED:")
    changes.append(f"  OLD: {bb}")
    changes.append(f"  NEW: {cb}")

# Compare body structure
base_body = base_req.get("body", {}) or {}
curr_body = curr_req.get("body", {}) or {}
base_keys = set(base_body.get("body_keys", []))
curr_keys = set(curr_body.get("body_keys", []))
new_keys = curr_keys - base_keys
removed_keys = base_keys - curr_keys
if new_keys:
    changes.append(f"NEW BODY KEYS: {sorted(new_keys)}")
if removed_keys:
    changes.append(f"REMOVED BODY KEYS: {sorted(removed_keys)}")

# Compare betas
base_betas = set(base_body.get("betas") or [])
curr_betas = set(curr_body.get("betas") or [])
new_betas = curr_betas - base_betas
removed_betas = base_betas - curr_betas
if new_betas:
    changes.append(f"NEW BETAS: {sorted(new_betas)}")
if removed_betas:
    changes.append(f"REMOVED BETAS: {sorted(removed_betas)}")

# Compare system blocks
base_sys = base_req.get("system_blocks", []) or []
curr_sys = curr_req.get("system_blocks", []) or []
if len(base_sys) != len(curr_sys):
    changes.append(f"SYSTEM BLOCK COUNT: {len(base_sys)} -> {len(curr_sys)}")

if changes:
    print("## Protocol Changes Detected\n")
    for c in changes:
        print(f"- {c}")
    sys.exit(1)
else:
    print("No protocol changes detected.")
    sys.exit(0)
'
	return $?
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
	if [[ -f "${HOME}/.aidevops/cch-constants.json" ]]; then
		if ~/.aidevops/agents/scripts/cch-extract.sh --verify 2>/dev/null; then
			print_success "Cache is current"
		else
			print_warning "Cache is stale — updating..."
			~/.aidevops/agents/scripts/cch-extract.sh --cache 2>/dev/null
		fi
	else
		print_info "No cache found — creating..."
		~/.aidevops/agents/scripts/cch-extract.sh --cache 2>/dev/null
	fi

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
