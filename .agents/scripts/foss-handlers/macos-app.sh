#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# foss-handlers/macos-app.sh — macOS app handler stub for FOSS contributions (t1698)
#
# Implements the standard handler interface for macOS applications built with
# Xcode or Swift Package Manager. Detects project type, runs xcodebuild/swift,
# and reports the built .app path or binary location.
#
# Handler interface (called by foss-contribution-helper.sh):
#   macos-app.sh setup   <slug> <fork-path>   Detect Xcode project vs Swift Package
#   macos-app.sh build   <slug> <fork-path>   xcodebuild or swift build
#   macos-app.sh test    <slug> <fork-path>   xcodebuild test or swift test
#   macos-app.sh review  <slug> <fork-path>   Open built .app or report binary path
#   macos-app.sh cleanup <slug> <fork-path>   Remove derived data, clean build artefacts
#
# Note: macOS apps have no localdev URL — review is native app launch or binary path.
#
# Exit codes: 0 = success, 1 = error, 2 = not applicable (no Xcode/Swift toolchain)

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HANDLERS_DIR="$SCRIPT_DIR"
AGENTS_SCRIPTS_DIR="$(dirname "$HANDLERS_DIR")"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Project type detection
# =============================================================================

# detect_project_type <fork-path>
# Prints "swift-package", "xcode-project", or "" to stdout.
detect_project_type() {
	local fork_path="$1"

	if [[ -f "${fork_path}/Package.swift" ]]; then
		echo "swift-package"
		return 0
	fi

	local xcodeproj=""
	for _xp in "${fork_path}"/*.xcodeproj; do
		[[ -d "$_xp" ]] && xcodeproj="$_xp" && break
	done
	if [[ -n "$xcodeproj" ]]; then
		echo "xcode-project"
		return 0
	fi

	echo ""
	return 0
}

# detect_scheme <fork-path>
# For Xcode projects, attempts to detect the primary build scheme.
# Prints scheme name or empty string.
detect_scheme() {
	local fork_path="$1"

	if ! command -v xcodebuild &>/dev/null; then
		echo ""
		return 0
	fi

	local xcodeproj=""
	for _xp in "${fork_path}"/*.xcodeproj; do
		[[ -d "$_xp" ]] && xcodeproj="$_xp" && break
	done
	if [[ -z "$xcodeproj" ]]; then
		echo ""
		return 0
	fi

	# List schemes and pick the first non-test scheme
	local scheme
	scheme="$(xcodebuild -project "$xcodeproj" -list 2>/dev/null |
		awk '/Schemes:/,0' |
		grep -v 'Schemes:' |
		grep -v 'Tests\|Test' |
		head -1 |
		xargs 2>/dev/null || echo "")"
	echo "$scheme"
	return 0
}

# =============================================================================
# State file helpers
# =============================================================================

state_file() {
	local fork_path="$1"
	echo "${fork_path}/.aidevops-handler-state.json"
}

write_state() {
	local fork_path="$1"
	local key="$2"
	local value="$3"
	local sf
	sf="$(state_file "$fork_path")"

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local current="{}"
	[[ -f "$sf" ]] && current="$(cat "$sf")"
	echo "$current" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}' >"${sf}.tmp" && mv "${sf}.tmp" "$sf"
	return 0
}

read_state() {
	local fork_path="$1"
	local key="$2"
	local sf
	sf="$(state_file "$fork_path")"

	if ! command -v jq &>/dev/null || [[ ! -f "$sf" ]]; then
		echo ""
		return 0
	fi

	jq -r --arg k "$key" '.[$k] // empty' "$sf" 2>/dev/null || echo ""
	return 0
}

# =============================================================================
# Toolchain check
# =============================================================================

require_toolchain() {
	local project_type="$1"

	if [[ "$project_type" == "swift-package" ]]; then
		if ! command -v swift &>/dev/null; then
			printf "${RED}Error: swift toolchain not found. Install Xcode or Swift toolchain.${NC}\n" >&2
			return 2
		fi
	else
		if ! command -v xcodebuild &>/dev/null; then
			printf "${RED}Error: xcodebuild not found. Install Xcode.${NC}\n" >&2
			return 2
		fi
	fi
	return 0
}

# =============================================================================
# Handler commands
# =============================================================================

cmd_setup() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[macos-app] setup: %s at %s${NC}\n" "$slug" "$fork_path"

	if [[ ! -d "$fork_path" ]]; then
		printf "${RED}Error: fork path not found: %s${NC}\n" "$fork_path" >&2
		return 1
	fi

	local project_type
	project_type="$(detect_project_type "$fork_path")"

	if [[ -z "$project_type" ]]; then
		printf "${RED}Error: no Xcode project or Package.swift found in %s${NC}\n" "$fork_path" >&2
		return 1
	fi

	printf "  Project type: %s\n" "$project_type"
	write_state "$fork_path" "project_type" "$project_type"

	require_toolchain "$project_type" || return $?

	if [[ "$project_type" == "xcode-project" ]]; then
		local scheme
		scheme="$(detect_scheme "$fork_path")"
		printf "  Detected scheme: %s\n" "${scheme:-"(auto-detect at build time)"}"
		write_state "$fork_path" "scheme" "$scheme"

		local xcodeproj=""
		for _xp in "${fork_path}"/*.xcodeproj; do
			[[ -d "$_xp" ]] && xcodeproj="$_xp" && break
		done
		write_state "$fork_path" "xcodeproj" "$xcodeproj"
	fi

	# Resolve Swift Package dependencies
	if [[ "$project_type" == "swift-package" ]]; then
		printf "  Resolving Swift Package dependencies\n"
		(cd "$fork_path" && swift package resolve) 2>&1 || {
			printf "${YELLOW}Warning: swift package resolve failed — continuing${NC}\n"
		}
	fi

	printf "${GREEN}[macos-app] setup complete${NC}\n"
	return 0
}

cmd_build() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[macos-app] build: %s${NC}\n" "$slug"

	local project_type
	project_type="$(read_state "$fork_path" "project_type")"
	if [[ -z "$project_type" ]]; then
		printf "${RED}Error: run setup first${NC}\n" >&2
		return 1
	fi

	require_toolchain "$project_type" || return $?

	if [[ "$project_type" == "swift-package" ]]; then
		printf "  Running: swift build\n"
		(cd "$fork_path" && swift build) 2>&1 || {
			printf "${RED}[macos-app] swift build failed${NC}\n" >&2
			return 1
		}
		# Record binary path
		local bin_path
		bin_path="$(cd "$fork_path" && swift build --show-bin-path 2>/dev/null || echo "${fork_path}/.build/debug")"
		write_state "$fork_path" "bin_path" "$bin_path"
	else
		local xcodeproj scheme
		xcodeproj="$(read_state "$fork_path" "xcodeproj")"
		scheme="$(read_state "$fork_path" "scheme")"

		local build_cmd="xcodebuild"
		[[ -n "$xcodeproj" ]] && build_cmd="$build_cmd -project $xcodeproj"
		[[ -n "$scheme" ]] && build_cmd="$build_cmd -scheme $scheme"
		build_cmd="$build_cmd -configuration Release build"

		printf "  Running: %s\n" "$build_cmd"
		(cd "$fork_path" && eval "$build_cmd") 2>&1 || {
			printf "${RED}[macos-app] xcodebuild failed${NC}\n" >&2
			return 1
		}
	fi

	printf "${GREEN}[macos-app] build complete${NC}\n"
	return 0
}

cmd_test() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[macos-app] test: %s${NC}\n" "$slug"

	local project_type
	project_type="$(read_state "$fork_path" "project_type")"
	if [[ -z "$project_type" ]]; then
		printf "${RED}Error: run setup first${NC}\n" >&2
		return 1
	fi

	require_toolchain "$project_type" || return $?

	if [[ "$project_type" == "swift-package" ]]; then
		printf "  Running: swift test\n"
		local exit_code=0
		(cd "$fork_path" && swift test) 2>&1 || exit_code=$?
		if [[ $exit_code -ne 0 ]]; then
			printf "${RED}[macos-app] swift test failed (exit %d)${NC}\n" "$exit_code" >&2
			return 1
		fi
	else
		local xcodeproj scheme
		xcodeproj="$(read_state "$fork_path" "xcodeproj")"
		scheme="$(read_state "$fork_path" "scheme")"

		# xcodebuild test requires a destination; use generic macOS simulator
		local test_cmd="xcodebuild"
		[[ -n "$xcodeproj" ]] && test_cmd="$test_cmd -project $xcodeproj"
		[[ -n "$scheme" ]] && test_cmd="$test_cmd -scheme $scheme"
		test_cmd="$test_cmd -destination 'platform=macOS' test"

		printf "  Running: %s\n" "$test_cmd"
		local exit_code=0
		(cd "$fork_path" && eval "$test_cmd") 2>&1 || exit_code=$?
		if [[ $exit_code -ne 0 ]]; then
			printf "${RED}[macos-app] xcodebuild test failed (exit %d)${NC}\n" "$exit_code" >&2
			return 1
		fi
	fi

	printf "${GREEN}[macos-app] Tests passed${NC}\n"
	return 0
}

cmd_review() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[macos-app] review: %s${NC}\n" "$slug"
	printf "  Note: macOS apps have no localdev URL — review is native app launch\n"

	local project_type
	project_type="$(read_state "$fork_path" "project_type")"

	if [[ "$project_type" == "swift-package" ]]; then
		local bin_path
		bin_path="$(read_state "$fork_path" "bin_path")"
		if [[ -n "$bin_path" ]] && [[ -d "$bin_path" ]]; then
			printf "  Binary directory: %s\n" "$bin_path"
			# List binaries, excluding object/debug files
			local _count=0
			for _bin in "${bin_path}"/*; do
				[[ "$_bin" == *.o ]] || [[ "$_bin" == *.d ]] || [[ "$_bin" == *.swp ]] && continue
				[[ -e "$_bin" ]] && printf "    %s\n" "$(basename "$_bin")"
				_count=$((_count + 1))
				[[ $_count -ge 10 ]] && break
			done
		else
			printf "  Run 'swift build' first to produce a binary\n"
		fi
	else
		# Look for .app in DerivedData or build directory
		local app_path
		app_path="$(find "${fork_path}" -name "*.app" -maxdepth 5 2>/dev/null | head -1 || echo "")"
		if [[ -n "$app_path" ]]; then
			printf "  Built app: %s\n" "$app_path"
			printf "  Open with: open \"%s\"\n" "$app_path"
		else
			printf "  No .app found — run build first\n"
		fi
	fi

	printf "${GREEN}[macos-app] review info reported${NC}\n"
	return 0
}

cmd_cleanup() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[macos-app] cleanup: %s${NC}\n" "$slug"

	local project_type
	project_type="$(read_state "$fork_path" "project_type")"

	if [[ "$project_type" == "swift-package" ]]; then
		printf "  Running: swift package clean\n"
		(cd "$fork_path" && swift package clean) 2>/dev/null || true
	else
		printf "  Running: xcodebuild clean\n"
		local xcodeproj scheme
		xcodeproj="$(read_state "$fork_path" "xcodeproj")"
		scheme="$(read_state "$fork_path" "scheme")"

		local clean_cmd="xcodebuild"
		[[ -n "$xcodeproj" ]] && clean_cmd="$clean_cmd -project $xcodeproj"
		[[ -n "$scheme" ]] && clean_cmd="$clean_cmd -scheme $scheme"
		clean_cmd="$clean_cmd clean"

		(cd "$fork_path" && eval "$clean_cmd") 2>/dev/null || true
	fi

	# Remove state file
	local sf
	sf="$(state_file "$fork_path")"
	[[ -f "$sf" ]] && rm -f "$sf"

	printf "${GREEN}[macos-app] cleanup complete${NC}\n"
	return 0
}

cmd_help() {
	cat <<'EOF'
foss-handlers/macos-app.sh — macOS app handler for FOSS contributions

Usage:
  macos-app.sh setup   <slug> <fork-path>   Detect Xcode project vs Swift Package
  macos-app.sh build   <slug> <fork-path>   xcodebuild or swift build
  macos-app.sh test    <slug> <fork-path>   xcodebuild test or swift test
  macos-app.sh review  <slug> <fork-path>   Report built .app path or binary directory
  macos-app.sh cleanup <slug> <fork-path>   Clean build artefacts, remove state file
  macos-app.sh help                         Show this help

Supported project types:
  swift-package    Package.swift present — uses swift build/test
  xcode-project    *.xcodeproj present — uses xcodebuild

Note: macOS apps have no localdev URL. Review is native app launch or binary path.

Exit codes:
  0  Success
  1  Error (build/test failed, directory not found, etc.)
  2  Toolchain not available (Xcode/Swift not installed)

State file: <fork-path>/.aidevops-handler-state.json
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local command="${1:-help}"
	local slug="${2:-}"
	local fork_path="${3:-}"

	case "$command" in
	setup)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: macos-app.sh setup <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_setup "$slug" "$fork_path"
		;;
	build)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: macos-app.sh build <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_build "$slug" "$fork_path"
		;;
	test)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: macos-app.sh test <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_test "$slug" "$fork_path"
		;;
	review)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: macos-app.sh review <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_review "$slug" "$fork_path"
		;;
	cleanup)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: macos-app.sh cleanup <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_cleanup "$slug" "$fork_path"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		printf "Unknown command: %s\n" "$command" >&2
		cmd_help >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
