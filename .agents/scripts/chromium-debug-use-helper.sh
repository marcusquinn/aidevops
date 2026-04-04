#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly NODE_SCRIPT="${SCRIPT_DIR}/chromium-debug-use.mjs"

show_help() {
	cat <<'EOF'
Chromium Debug Use Helper

Usage:
  chromium-debug-use-helper.sh [--browser-url URL] [--ws-endpoint URL] <command> [args]

Commands:
  help                               Show this help
  version                            Show connected browser version info
  list                               List open pages and target prefixes
  open [url]                         Open a new tab
  snapshot <target>                  Accessibility snapshot
  html <target> [selector]           Full page or element HTML
  eval <target> <expression...>      Evaluate JavaScript in the page
  screenshot <target> [file]         Save viewport screenshot
  navigate <target> <url>            Navigate target and wait for load
  click <target> <selector>          Click a CSS selector
  clickxy <target> <x> <y>           Click CSS pixel coordinates
  type <target> <text...>            Type text at current focus
  loadall <target> <selector> [ms]   Click a load-more selector until gone
  raw <target> <method> [json]       Send a raw CDP command
  stop [target]                      Stop daemon(s)

Options:
  --browser-url URL                  Browser debugging base URL (default: http://127.0.0.1:9222)
  --ws-endpoint URL                  Explicit browser WebSocket endpoint

Environment:
  CHROMIUM_DEBUG_USE_BROWSER_URL     Override browser debugging base URL
  CHROMIUM_DEBUG_USE_WS_ENDPOINT     Override browser WebSocket endpoint
EOF
	return 0
}

print_error() {
	local message="$1"
	printf 'Error: %s\n' "$message" >&2
	return 0
}

check_node() {
	if ! command -v node >/dev/null 2>&1; then
		print_error "Node.js 22+ is required"
		return 1
	fi

	local major
	major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
	if [[ -z "$major" ]]; then
		print_error "Unable to determine Node.js version"
		return 1
	fi
	if ((major < 22)); then
		print_error "Node.js 22+ is required (found $(node --version 2>/dev/null || printf 'unknown'))"
		return 1
	fi
	return 0
}

run_helper() {
	local browser_url="$1"
	local ws_endpoint="$2"
	shift 2

	if [[ ! -f "$NODE_SCRIPT" ]]; then
		print_error "Helper script not found: $NODE_SCRIPT"
		return 1
	fi

	CHROMIUM_DEBUG_USE_BROWSER_URL="$browser_url" \
		CHROMIUM_DEBUG_USE_WS_ENDPOINT="$ws_endpoint" \
		node "$NODE_SCRIPT" "$@"
	return $?
}

main() {
	local browser_url="${CHROMIUM_DEBUG_USE_BROWSER_URL:-http://127.0.0.1:9222}"
	local ws_endpoint="${CHROMIUM_DEBUG_USE_WS_ENDPOINT:-}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--browser-url)
			if [[ $# -lt 2 ]]; then
				print_error "--browser-url requires a value"
				return 1
			fi
			browser_url="$2"
			shift 2
			;;
		--ws-endpoint)
			if [[ $# -lt 2 ]]; then
				print_error "--ws-endpoint requires a value"
				return 1
			fi
			ws_endpoint="$2"
			shift 2
			;;
		help | -h | --help)
			show_help
			return 0
			;;
		*)
			break
			;;
		esac
	done

	local command="${1:-help}"
	if [[ "$command" == "help" ]]; then
		show_help
		return 0
	fi

	check_node || return 1

	case "$command" in
	version)
		shift
		run_helper "$browser_url" "$ws_endpoint" version "$@"
		return $?
		;;
	list | open | stop)
		run_helper "$browser_url" "$ws_endpoint" "$@"
		return $?
		;;
	snapshot)
		shift
		run_helper "$browser_url" "$ws_endpoint" snap "$@"
		return $?
		;;
	html | eval | click | clickxy | type | loadall)
		run_helper "$browser_url" "$ws_endpoint" "$@"
		return $?
		;;
	screenshot)
		shift
		run_helper "$browser_url" "$ws_endpoint" shot "$@"
		return $?
		;;
	navigate)
		shift
		run_helper "$browser_url" "$ws_endpoint" nav "$@"
		return $?
		;;
	raw)
		shift
		run_helper "$browser_url" "$ws_endpoint" evalraw "$@"
		return $?
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
