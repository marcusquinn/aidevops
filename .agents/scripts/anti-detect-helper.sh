#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Anti-Detect Browser Helper -- Orchestrator
# =============================================================================
# Thin orchestrator for anti-detect browser tools. Sources focused sub-libraries
# for profile management, browser launch, detection testing, and operations.
#
# Usage: anti-detect-helper.sh [command] [options]
#
# Sub-libraries:
#   - anti-detect-helper-profiles.sh  (profile CRUD, utilities)
#   - anti-detect-helper-launch.sh    (browser launch: Camoufox, Mullvad, Chromium)
#   - anti-detect-helper-testing.sh   (detection testing, warmup)
#   - anti-detect-helper-ops.sh       (setup, status, proxy, cookies)
#
# Part of aidevops framework: https://aidevops.sh
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "$HOME/.config/aidevops/credentials.sh" ]] && source "$HOME/.config/aidevops/credentials.sh"

PROFILES_DIR="$HOME/.aidevops/.agent-workspace/browser-profiles"
VENV_DIR="$HOME/.aidevops/anti-detect-venv"

# Script directory (for relative path references and sub-library sourcing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# --- Source sub-libraries ---

# shellcheck source=./anti-detect-helper-profiles.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/anti-detect-helper-profiles.sh"

# shellcheck source=./anti-detect-helper-launch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/anti-detect-helper-launch.sh"

# shellcheck source=./anti-detect-helper-testing.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/anti-detect-helper-testing.sh"

# shellcheck source=./anti-detect-helper-ops.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/anti-detect-helper-ops.sh"

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
	cat <<'EOF'
Anti-Detect Browser Helper

USAGE:
    anti-detect-helper.sh <command> [options]

COMMANDS:
    setup               Install anti-detect tools (Camoufox, rebrowser-patches)
    launch              Launch browser with anti-detect profile
    profile             Manage browser profiles (create/list/show/delete/clone)
    cookies             Manage profile cookies (export/clear)
    proxy               Proxy operations (check/check-all)
    test                Test detection status against bot-detection sites
    warmup              Warm up a profile with browsing history
    status              Show installation status of all tools

SETUP OPTIONS:
    --engine <type>     Engine to setup: all|chromium|firefox (default: all)

LAUNCH OPTIONS:
    --profile <name>    Profile to launch (required unless --disposable)
    --engine <type>     Browser engine: chromium|firefox|mullvad|random (default: firefox)
    --headless          Run headless (default: headed)
    --disposable        Single-use profile (auto-deleted)
    --url <url>         URL to navigate to after launch

PROFILE SUBCOMMANDS:
    create <name>       Create new profile
    list                List all profiles
    show <name>         Show profile details
    delete <name>       Delete profile
    clone <src> <dst>   Clone profile
    update <name>       Update profile settings

PROFILE CREATE OPTIONS:
    --type <type>       Profile type: persistent|clean|warm|disposable (default: persistent)
    --proxy <url>       Assign proxy URL
    --os <os>           Target OS: windows|macos|linux (default: random)
    --browser <type>    Browser type: firefox|chrome (default: firefox)
    --notes <text>      Profile notes

TEST OPTIONS:
    --profile <name>    Profile to test (uses its fingerprint/proxy)
    --engine <type>     Engine: chromium|firefox (default: firefox)
    --sites <list>      Comma-separated test sites (default: all)

EXAMPLES:
    anti-detect-helper.sh setup
    anti-detect-helper.sh profile create "my-account" --type persistent --proxy "http://user:pass@host:port"
    anti-detect-helper.sh launch --profile "my-account" --headless
    anti-detect-helper.sh test --profile "my-account"
    anti-detect-helper.sh warmup "my-account" --duration 30m
    anti-detect-helper.sh profile list
EOF
	return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	setup)
		local engine="all"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--engine)
				engine="$2"
				shift 2
				;;
			*) shift ;;
			esac
		done
		setup_all "$engine"
		;;
	launch)
		launch_browser "$@"
		;;
	profile)
		local subcmd="${1:-list}"
		shift 2>/dev/null || true
		case "$subcmd" in
		create) profile_create "$@" ;;
		list) profile_list "$@" ;;
		show) profile_show "$@" ;;
		delete) profile_delete "$@" ;;
		clone) profile_clone "$@" ;;
		update) profile_update "$@" ;;
		*)
			echo -e "${RED}Unknown profile command: $subcmd${NC}"
			show_help
			;;
		esac
		;;
	cookies)
		local subcmd="${1:-}"
		shift 2>/dev/null || true
		case "$subcmd" in
		export) cookies_export "$@" ;;
		clear) cookies_clear "$@" ;;
		*)
			echo -e "${RED}Unknown cookies command: $subcmd${NC}"
			show_help
			;;
		esac
		;;
	proxy)
		local subcmd="${1:-}"
		shift 2>/dev/null || true
		case "$subcmd" in
		check) proxy_check "$@" ;;
		check-all) proxy_check_all ;;
		*)
			echo -e "${RED}Unknown proxy command: $subcmd${NC}"
			show_help
			;;
		esac
		;;
	test)
		test_detection "$@"
		;;
	warmup)
		warmup_profile "$@"
		;;
	status)
		show_status
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo -e "${RED}Unknown command: $command${NC}"
		show_help
		return 1
		;;
	esac
}

main "$@"
