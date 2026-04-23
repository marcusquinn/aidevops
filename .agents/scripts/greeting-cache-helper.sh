#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# =============================================================================
# greeting-cache-helper.sh — Write per-runtime greeting cache files
# =============================================================================
# Part of the multi-runtime greeting architecture (t2737, Phase A / GH#20599).
# Writes ~/.aidevops/cache/session-greeting-{runtime}.txt with a normalised
# line 1 in the format:
#   aidevops vX running in {display_name} vY | {repo_slug}
#
# Also writes to the shared ~/.aidevops/cache/session-greeting.txt for
# backward compatibility (the OpenCode plugin reads this path).
#
# Usage:
#   greeting-cache-helper.sh write <runtime-id>
#   greeting-cache-helper.sh help
#
# Commands:
#   write <runtime-id>   — write greeting cache for the given runtime ID
#   help                 — show this help
#
# Examples:
#   greeting-cache-helper.sh write opencode
#   greeting-cache-helper.sh write claude-code
#
# Environment:
#   AIDEVOPS_GREETING_REPO_SLUG — override repo slug (default: from git remote)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=runtime-registry.sh
source "${SCRIPT_DIR}/runtime-registry.sh"
set -euo pipefail
init_log_file

readonly CACHE_DIR="${HOME}/.aidevops/cache"
readonly VERSION_FILE="${SCRIPT_DIR%/scripts}/VERSION"

# =============================================================================
# Helpers
# =============================================================================

_read_aidevops_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		head -1 "$VERSION_FILE"
		return 0
	fi
	# Fallback: try one level up (if sourced from a non-standard location)
	local alt_version="${SCRIPT_DIR}/../../VERSION"
	if [[ -f "$alt_version" ]]; then
		head -1 "$alt_version"
		return 0
	fi
	echo "unknown"
	return 0
}

_detect_repo_slug() {
	if [[ -n "${AIDEVOPS_GREETING_REPO_SLUG:-}" ]]; then
		echo "${AIDEVOPS_GREETING_REPO_SLUG}"
		return 0
	fi
	local slug
	slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]\(.*\)\.git|\1|;s|.*github.com[:/]\(.*\)|\1|' 2>/dev/null) || slug=""
	echo "${slug:-local}"
	return 0
}

# =============================================================================
# Main function
# =============================================================================

# write_greeting_cache: write cache files for the given runtime ID.
# Args: $1 = runtime-id
# Returns: 0 on success, 1 on error
write_greeting_cache() {
	local runtime_id="$1"

	# Validate runtime ID
	if ! rt_binary "$runtime_id" >/dev/null 2>&1; then
		print_error "Unknown runtime ID: $runtime_id"
		print_info "Run: greeting-cache-helper.sh help  (for usage)"
		return 1
	fi

	local display_name
	display_name=$(rt_display_name "$runtime_id")

	local runtime_version
	runtime_version=$(rt_version "$runtime_id")

	local aidevops_version
	aidevops_version=$(_read_aidevops_version)

	local repo_slug
	repo_slug=$(_detect_repo_slug)

	# Normalised line 1 format (as specified in issue #20599 / t2737 Phase A)
	local greeting_line_1="aidevops v${aidevops_version} running in ${display_name} v${runtime_version} | ${repo_slug}"

	mkdir -p "$CACHE_DIR"

	# Write per-runtime cache file
	local runtime_cache="${CACHE_DIR}/session-greeting-${runtime_id}.txt"
	printf '%s\n' "$greeting_line_1" >"$runtime_cache"
	print_info "Written: $runtime_cache"

	# Write shared backward-compat cache file
	local shared_cache="${CACHE_DIR}/session-greeting.txt"
	printf '%s\n' "$greeting_line_1" >"$shared_cache"
	print_info "Written: $shared_cache"

	return 0
}

# =============================================================================
# CLI dispatch
# =============================================================================

_usage() {
	cat <<'EOF'
greeting-cache-helper.sh — Write per-runtime greeting cache files

Usage:
  greeting-cache-helper.sh write <runtime-id>
  greeting-cache-helper.sh help

Commands:
  write <runtime-id>   Write greeting cache for the given runtime ID.
                       Creates ~/.aidevops/cache/session-greeting-<id>.txt
                       and updates ~/.aidevops/cache/session-greeting.txt.
  help                 Show this help message.

Runtime IDs (from runtime-registry.sh):
  opencode, claude-code, codex, cursor, droid, gemini-cli,
  windsurf, continue, kilo, kiro, aider, amp, kimi, qwen

Examples:
  greeting-cache-helper.sh write opencode
  greeting-cache-helper.sh write claude-code

Environment:
  AIDEVOPS_GREETING_REPO_SLUG  Override detected repo slug in line 1.
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	write)
		if [[ $# -lt 1 ]]; then
			print_error "write requires a runtime-id argument"
			_usage
			return 1
		fi
		local runtime_arg="$1"
		write_greeting_cache "$runtime_arg"
		return 0
		;;
	help | --help | -h)
		_usage
		return 0
		;;
	*)
		print_error "Unknown command: $cmd"
		_usage
		return 1
		;;
	esac
}

# Only run main when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
