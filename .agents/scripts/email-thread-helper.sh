#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Email Thread Helper (t2856)
# =============================================================================
# Shell wrapper around email_thread.py for JWZ thread reconstruction.
# Reads email source meta.json files from _knowledge/sources/ and builds
# thread indexes at _knowledge/index/email-threads/<thread-id>.json.
#
# Usage:
#   email-thread-helper.sh build  [<knowledge-root>] [--force]
#   email-thread-helper.sh thread <message-id> [<knowledge-root>]
#   email-thread-helper.sh list   [<knowledge-root>]
#   email-thread-helper.sh help
#
# <knowledge-root> defaults to the nearest _knowledge/ directory (searching
# from $PWD upward).  May also be set via KNOWLEDGE_ROOT env var.
#
# Part of aidevops email channel (P5c).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

readonly EMAIL_THREAD_PY="${SCRIPT_DIR}/email_thread.py"

# =============================================================================
# Helpers
# =============================================================================

_find_knowledge_root() {
	# Walk upward from PWD looking for _knowledge/ directory
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -d "${dir}/_knowledge" ]]; then
			echo "${dir}/_knowledge"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

_resolve_root() {
	local candidate="${1:-}"
	if [[ -n "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi
	if [[ -n "${KNOWLEDGE_ROOT:-}" ]]; then
		echo "$KNOWLEDGE_ROOT"
		return 0
	fi
	if ! _find_knowledge_root; then
		print_error "No _knowledge/ directory found. Pass <knowledge-root> or set KNOWLEDGE_ROOT."
		return 1
	fi
	return 0
}

_check_python() {
	if ! command -v python3 &>/dev/null; then
		print_error "python3 is required for email-thread-helper. Install Python 3.9+."
		return 1
	fi
	return 0
}

# =============================================================================
# build: reconstruct threads across email corpus
# =============================================================================

cmd_build() {
	local knowledge_root="" force_flag=""
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}"
		case "$_cur" in
		--force) force_flag="--force" ;;
		-*) print_error "Unknown option: ${_cur}"; return 1 ;;
		*) knowledge_root="$_cur" ;;
		esac
		shift
	done

	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_python || return 1

	print_info "Building email thread index from ${knowledge_root}…"
	python3 "${EMAIL_THREAD_PY}" build "${knowledge_root}" ${force_flag:+"$force_flag"}
	return 0
}

# =============================================================================
# thread: look up a thread by message-id or source-id
# =============================================================================

cmd_thread() {
	local knowledge_root="" message_id=""
	# Accept: thread <message-id> [knowledge-root]
	if [[ $# -eq 0 ]]; then
		print_error "Usage: email-thread-helper.sh thread <message-id> [knowledge-root]"
		return 1
	fi
	local _mid="${1:-}"; message_id="$_mid"; shift

	if [[ $# -gt 0 ]]; then local _kr="${1:-}"; knowledge_root="$_kr"; shift; fi
	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_python || return 1

	python3 "${EMAIL_THREAD_PY}" thread "${knowledge_root}" "${message_id}"
	return 0
}

# =============================================================================
# list: show all thread indexes
# =============================================================================

cmd_list() {
	local knowledge_root=""
	if [[ $# -gt 0 ]]; then local _kr="${1:-}"; knowledge_root="$_kr"; shift; fi
	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1

	local index_dir="${knowledge_root}/index/email-threads"
	if [[ ! -d "$index_dir" ]]; then
		print_info "No thread index found at ${index_dir}. Run 'build' first."
		return 0
	fi

	local count=0
	for f in "${index_dir}"/*.json; do
		[[ -f "$f" ]] || continue
		if command -v jq &>/dev/null; then
			local thread_id root_subj src_count
			thread_id="$(jq -r '.thread_id // "unknown"' "$f" 2>/dev/null || true)"
			root_subj="$(jq -r '.root_subject // ""' "$f" 2>/dev/null || true)"
			src_count="$(jq -r '.sources | length' "$f" 2>/dev/null || true)"
			printf '  %-40s  %-50s  %s messages\n' \
				"${thread_id:0:40}" "${root_subj:0:50}" "${src_count:-?}"
		else
			echo "  $(basename "$f" .json)"
		fi
		count=$((count + 1))
	done

	print_info "Total: ${count} thread(s)"
	return 0
}

# =============================================================================
# help
# =============================================================================

cmd_help() {
	cat <<'EOF'
email-thread-helper.sh — JWZ email thread reconstruction

Commands:
  build  [<knowledge-root>] [--force]       Reconstruct threads from email sources
  thread <message-id> [<knowledge-root>]    Look up thread containing message-id
  list   [<knowledge-root>]                 List all thread indexes
  help                                      Show this help

Environment:
  KNOWLEDGE_ROOT    Override knowledge root path

Thread indexes are written to:
  <knowledge-root>/index/email-threads/<thread-id>.json

Incremental: re-threads only when source meta.json files change (mtime).
Use --force to rebuild regardless.

Part of aidevops email channel (t2856 / P5c).
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift

	case "$command" in
	build) cmd_build "$@" ;;
	thread) cmd_thread "$@" ;;
	list) cmd_list "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
