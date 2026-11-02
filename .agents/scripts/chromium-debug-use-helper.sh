#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly NODE_SCRIPT="${SCRIPT_DIR}/chromium-debug-use.mjs"
# Dedicated, aidevops-owned browser profiles (GH#36511). Never the user's
# default profile: Chromium ignores --remote-debugging-port there (Chrome 136+).
readonly PROFILE_BASE_DIR="${AIDEVOPS_BROWSER_PROFILE_DIR:-${HOME}/.aidevops/.agent-workspace/browser-profiles}"
readonly DEFAULT_PROFILE="cdp"
readonly LAUNCH_WAIT_TENTHS=200

show_help() {
	cat <<'EOF'
Chromium Debug Use Helper

Usage:
  chromium-debug-use-helper.sh [--browser-url URL] [--ws-endpoint URL] [--profile NAME] <command> [args]

Launch commands (dedicated aidevops-owned profile; no Node required):
  launch [url]                       Start (or reuse) a plain-process Brave/Chrome on a
                                     dedicated persistent profile with CDP on a free
                                     127.0.0.1 port; prints BROWSER_URL for connectOverCDP
  launch-status                      Show launched profiles: pid, endpoint, page count, orphan
  launch-stop [--all]                Stop the launched browser for --profile (or all)

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
  --profile NAME                     Launched profile name (default: cdp); other commands
                                     then target that launched browser

Environment:
  CHROMIUM_DEBUG_USE_BROWSER_URL     Override browser debugging base URL
  CHROMIUM_DEBUG_USE_WS_ENDPOINT     Override browser WebSocket endpoint
  AIDEVOPS_CDP_BROWSER               Browser executable for launch (default: Brave, then Chrome/Edge/Chromium)
  AIDEVOPS_BROWSER_PROFILE_DIR       Profile root (default: ~/.aidevops/.agent-workspace/browser-profiles)

Example (use a logged-in session with the recommended browser):
  chromium-debug-use-helper.sh launch https://x.com/login   # user logs in once; profile persists
  # Playwright: await chromium.connectOverCDP('<BROWSER_URL printed above>')
  chromium-debug-use-helper.sh launch-stop                   # stop it when the work is done
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

# --- Dedicated-profile launcher (GH#36511, GH#36513) ---

validate_profile_name() {
	local name="$1"
	if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
		print_error "Invalid profile name: ${name} (use letters, digits, '.', '_' or '-')"
		return 1
	fi
	return 0
}

profile_dir_for() {
	local name="$1"
	printf '%s/%s\n' "$PROFILE_BASE_DIR" "$name"
	return 0
}

state_file_for() {
	local name="$1"
	printf '%s/%s.state\n' "$PROFILE_BASE_DIR" "$name"
	return 0
}

state_value() {
	local state_file="$1"
	local key="$2"
	[[ -f "$state_file" ]] || return 1
	local line=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "${key}="* ]]; then
			printf '%s\n' "${line#*=}"
			return 0
		fi
	done <"$state_file"
	return 1
}

resolve_launch_browser() {
	local configured="${AIDEVOPS_CDP_BROWSER:-}"
	if [[ -n "$configured" ]]; then
		if [[ -x "$configured" ]]; then
			printf '%s\n' "$configured"
			return 0
		fi
		if command -v "$configured" >/dev/null 2>&1; then
			command -v "$configured"
			return 0
		fi
		print_error "AIDEVOPS_CDP_BROWSER is not executable: ${configured}"
		return 1
	fi

	local candidate=""
	local candidates=(
		"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
		"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
		"/Applications/Chromium.app/Contents/MacOS/Chromium"
		brave-browser brave google-chrome google-chrome-stable chromium chromium-browser microsoft-edge
	)
	for candidate in "${candidates[@]}"; do
		if [[ "$candidate" == /* ]]; then
			if [[ -x "$candidate" ]]; then
				printf '%s\n' "$candidate"
				return 0
			fi
		elif command -v "$candidate" >/dev/null 2>&1; then
			command -v "$candidate"
			return 0
		fi
	done
	print_error "No Brave/Chrome/Edge/Chromium executable found; set AIDEVOPS_CDP_BROWSER"
	return 1
}

# Succeeds only when PID is alive AND its command line still owns this profile,
# so a recycled PID is never treated as (or signalled as) our browser.
pid_owns_profile() {
	local pid="$1"
	local profile_dir="$2"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	local cmdline=""
	cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
	[[ "$cmdline" == *"--user-data-dir=${profile_dir}"* ]] || return 1
	return 0
}

read_active_port() {
	local profile_dir="$1"
	local port_file="${profile_dir}/DevToolsActivePort"
	[[ -f "$port_file" ]] || return 1
	local port=""
	IFS= read -r port <"$port_file" || true
	[[ "$port" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$port"
	return 0
}

endpoint_ok() {
	local url="$1"
	curl -fsS --max-time 2 "${url}/json/version" >/dev/null 2>&1 || return 1
	return 0
}

page_count() {
	local url="$1"
	local body=""
	body="$(curl -fsS --max-time 2 "${url}/json/list" 2>/dev/null || true)"
	local count=0
	local rest="$body"
	while [[ "$rest" == *'"type": "page"'* ]]; do
		count=$((count + 1))
		rest="${rest#*\"type\": \"page\"}"
	done
	printf '%s\n' "$count"
	return 0
}

# Resolve the http://127.0.0.1:<port> endpoint of a live launched profile.
profile_browser_url() {
	local name="$1"
	local profile_dir state_file pid port
	profile_dir="$(profile_dir_for "$name")"
	state_file="$(state_file_for "$name")"
	pid="$(state_value "$state_file" pid || true)"
	pid_owns_profile "$pid" "$profile_dir" || return 1
	port="$(read_active_port "$profile_dir")" || return 1
	printf 'http://127.0.0.1:%s\n' "$port"
	return 0
}

print_launch_result() {
	local name="$1"
	local status="$2"
	local url="$3"
	local pid="$4"
	printf 'LAUNCH=%s\nPROFILE=%s\nPROFILE_DIR=%s\nPID=%s\nBROWSER_URL=%s\n' \
		"$status" "$name" "$(profile_dir_for "$name")" "$pid" "$url"
	printf 'Attach: chromium.connectOverCDP(%s) | %s --profile %s list\n' "$url" "$(basename "$0")" "$name"
	printf 'Stop when done: %s --profile %s launch-stop\n' "$(basename "$0")" "$name"
	return 0
}

wait_for_endpoint() {
	local profile_dir="$1"
	local pid="$2"
	local tries=0 port=""
	while ((tries < LAUNCH_WAIT_TENTHS)); do
		if ! kill -0 "$pid" 2>/dev/null; then
			print_error "Browser exited during startup (another instance may already own ${profile_dir})"
			return 1
		fi
		if port="$(read_active_port "$profile_dir")" && endpoint_ok "http://127.0.0.1:${port}"; then
			printf 'http://127.0.0.1:%s\n' "$port"
			return 0
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	if [[ -n "$port" ]] && endpoint_ok "http://[::1]:${port}"; then
		print_error "Debug port ${port} is listening on [::1] only; use http://[::1]:${port}"
		return 1
	fi
	print_error "Timed out waiting for the debugging endpoint in ${profile_dir}"
	return 1
}

launch_browser() {
	local name="$1"
	local url="${2:-about:blank}"
	validate_profile_name "$name" || return 1
	# The URL is passed to the browser as a positional argument; never allow it
	# to be parsed as a switch.
	if [[ ! "$url" =~ ^(https?://|about:) ]]; then
		print_error "URL must start with http://, https:// or about: (got: ${url})"
		return 1
	fi
	command -v curl >/dev/null 2>&1 || {
		print_error "curl is required"
		return 1
	}

	local profile_dir state_file existing_url pid
	profile_dir="$(profile_dir_for "$name")"
	state_file="$(state_file_for "$name")"

	if existing_url="$(profile_browser_url "$name")" && endpoint_ok "$existing_url"; then
		pid="$(state_value "$state_file" pid)"
		if [[ "$url" != "about:blank" ]]; then
			curl -fsS --max-time 5 -X PUT "${existing_url}/json/new?${url}" >/dev/null 2>&1 || true
		fi
		print_launch_result "$name" reused "$existing_url" "$pid"
		return 0
	fi

	local browser
	browser="$(resolve_launch_browser)" || return 1
	mkdir -p "$profile_dir" || return 1
	chmod 700 "$PROFILE_BASE_DIR" "$profile_dir" 2>/dev/null || true
	rm -f "${profile_dir}/DevToolsActivePort" "$state_file"

	# Plain process: no Playwright automation switches (--enable-automation and
	# its infobar). Remote debugging alone still sets navigator.webdriver=true in
	# current Chromium, so AutomationControlled is disabled explicitly (GH#36512).
	# Port 0 lets Chromium pick a free loopback port, avoiding the 9222
	# collision that pushes the listener onto [::1] (GH#36513).
	nohup "$browser" \
		"--user-data-dir=${profile_dir}" \
		--remote-debugging-port=0 \
		--disable-blink-features=AutomationControlled \
		--no-first-run \
		--no-default-browser-check \
		"$url" >/dev/null 2>&1 &
	pid=$!
	disown "$pid" 2>/dev/null || true

	local endpoint
	if ! endpoint="$(wait_for_endpoint "$profile_dir" "$pid")"; then
		kill "$pid" 2>/dev/null || true
		return 1
	fi

	printf 'pid=%s\nbrowser=%s\nstarted=%s\n' "$pid" "$browser" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_file"
	chmod 600 "$state_file" 2>/dev/null || true
	print_launch_result "$name" started "$endpoint" "$pid"
	return 0
}

launch_status_one() {
	local name="$1"
	local profile_dir state_file pid url pages state
	profile_dir="$(profile_dir_for "$name")"
	state_file="$(state_file_for "$name")"
	pid="$(state_value "$state_file" pid || true)"
	if ! pid_owns_profile "$pid" "$profile_dir"; then
		printf '%s\tstopped\tpid=%s\n' "$name" "${pid:--}"
		return 0
	fi
	url="$(profile_browser_url "$name" || true)"
	if [[ -z "$url" ]] || ! endpoint_ok "$url"; then
		printf '%s\tno-endpoint\tpid=%s\n' "$name" "$pid"
		return 0
	fi
	pages="$(page_count "$url")"
	state="running"
	[[ "$pages" == "0" ]] && state="orphan"
	printf '%s\t%s\tpid=%s\turl=%s\tpages=%s\n' "$name" "$state" "$pid" "$url" "$pages"
	return 0
}

launch_status() {
	local only="${1:-}"
	if [[ -n "$only" ]]; then
		launch_status_one "$only"
		return 0
	fi
	local state_file found=0
	for state_file in "$PROFILE_BASE_DIR"/*.state; do
		[[ -f "$state_file" ]] || continue
		found=1
		launch_status_one "$(basename "$state_file" .state)"
	done
	((found)) || printf 'No launched profiles under %s\n' "$PROFILE_BASE_DIR"
	return 0
}

launch_stop_one() {
	local name="$1"
	local profile_dir state_file pid tries=0
	profile_dir="$(profile_dir_for "$name")"
	state_file="$(state_file_for "$name")"
	pid="$(state_value "$state_file" pid || true)"
	if ! pid_owns_profile "$pid" "$profile_dir"; then
		rm -f "$state_file"
		printf '%s\talready-stopped\n' "$name"
		return 0
	fi
	kill "$pid" 2>/dev/null || true
	while ((tries < 100)) && kill -0 "$pid" 2>/dev/null; do
		sleep 0.1
		tries=$((tries + 1))
	done
	if pid_owns_profile "$pid" "$profile_dir"; then
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$state_file" "${profile_dir}/DevToolsActivePort"
	printf '%s\tstopped\tpid=%s\n' "$name" "$pid"
	return 0
}

launch_stop() {
	local name="$1"
	local all="${2:-}"
	if [[ "$all" != "--all" ]]; then
		validate_profile_name "$name" || return 1
		launch_stop_one "$name"
		return 0
	fi
	local state_file
	for state_file in "$PROFILE_BASE_DIR"/*.state; do
		[[ -f "$state_file" ]] || continue
		launch_stop_one "$(basename "$state_file" .state)"
	done
	return 0
}

main() {
	local browser_url="${CHROMIUM_DEBUG_USE_BROWSER_URL:-http://127.0.0.1:9222}"
	local ws_endpoint="${CHROMIUM_DEBUG_USE_WS_ENDPOINT:-}"
	local profile=""

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
		--profile)
			if [[ $# -lt 2 ]]; then
				print_error "--profile requires a value"
				return 1
			fi
			local profile_arg="$2"
			validate_profile_name "$profile_arg" || return 1
			profile="$profile_arg"
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

	case "$command" in
	launch)
		launch_browser "${profile:-$DEFAULT_PROFILE}" "${2:-}"
		return $?
		;;
	launch-status)
		launch_status "$profile"
		return $?
		;;
	launch-stop)
		launch_stop "${profile:-$DEFAULT_PROFILE}" "${2:-}"
		return $?
		;;
	esac

	if [[ -n "$profile" ]]; then
		if ! browser_url="$(profile_browser_url "$profile")"; then
			print_error "Launched profile '${profile}' is not running; start it with: launch --profile ${profile}"
			return 1
		fi
		ws_endpoint=""
	fi

	check_node || return 1
	dispatch_cdp_command "$browser_url" "$ws_endpoint" "$@"
	return $?
}

dispatch_cdp_command() {
	local browser_url="$1"
	local ws_endpoint="$2"
	shift 2
	local command="$1"

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
