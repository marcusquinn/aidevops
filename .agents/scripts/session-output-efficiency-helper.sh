#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Aggregate repeated and oversized tool-output evidence without exposing content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly SCRIPT_DIR

usage() {
	cat <<'EOF'
Usage: session-output-efficiency-helper.sh [options]

Options:
  --runtime opencode|claude-code  Runtime history format (auto-detected from session env)
  --session ID                    Session identifier (defaults to runtime session env)
  --input PATH                    Explicit JSONL transcript or normalized fixture
  --db PATH                       Explicit OpenCode SQLite database
  --json                          Emit aidevops.session-output-efficiency/v1 JSON
  --min-repeat-bytes N            Ignore exact repeats smaller than N bytes (default: 80)
  --oversized-bytes N             Flag individual results at N bytes (default: 8192)
  --max-findings N                Limit aggregate findings (default: 5)

Without --input or --db, the helper resolves the runtime history path through
the Vault-managed session-history read gate. Raw tool inputs and outputs are
never emitted.
EOF
	return 0
}

resolve_runtime() {
	local requested="$1"
	if [[ -n "$requested" ]]; then
		printf '%s\n' "$requested"
		return 0
	fi
	if [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then
		printf '%s\n' "opencode"
		return 0
	fi
	if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		printf '%s\n' "claude-code"
		return 0
	fi
	printf '%s\n' "normalized"
	return 0
}

resolve_session() {
	local runtime="$1"
	local requested="$2"
	if [[ -n "$requested" ]]; then
		printf '%s\n' "$requested"
		return 0
	fi
	case "$runtime" in
	opencode) printf '%s\n' "${OPENCODE_SESSION_ID:-}" ;;
	claude-code) printf '%s\n' "${CLAUDE_SESSION_ID:-}" ;;
	*) printf '\n' ;;
	esac
	return 0
}

resolve_history_source() {
	local runtime="$1"
	local vault_helper="${SCRIPT_DIR}/vault-managed-session-history-helper.sh"
	if [[ "$runtime" == "normalized" ]]; then
		printf '%s\n' "Error: --input is required when no runtime session is active" >&2
		return 2
	fi
	if [[ ! -x "$vault_helper" ]]; then
		printf '%s\n' "Error: session-history read gate is unavailable" >&2
		return 2
	fi
	"$vault_helper" require-read "$runtime"
	return $?
}

main() {
	local runtime="" session_id="" source="" source_mode=""
	local -a analyzer_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--runtime)
			[[ $# -gt 1 ]] || { printf '%s\n' "Error: --runtime requires a value" >&2; return 2; }
			runtime="$2"
			shift 2
			;;
		--session)
			[[ $# -gt 1 ]] || { printf '%s\n' "Error: --session requires a value" >&2; return 2; }
			session_id="$2"
			shift 2
			;;
		--input)
			[[ $# -gt 1 ]] || { printf '%s\n' "Error: --input requires a path" >&2; return 2; }
			source="$2"
			source_mode="input"
			shift 2
			;;
		--db)
			[[ $# -gt 1 ]] || { printf '%s\n' "Error: --db requires a path" >&2; return 2; }
			source="$2"
			source_mode="db"
			shift 2
			;;
		--min-repeat-bytes | --oversized-bytes | --max-findings)
			[[ $# -gt 1 ]] || { printf '%s\n' "Error: $1 requires a value" >&2; return 2; }
			analyzer_args+=("$1" "$2")
			shift 2
			;;
		--json)
			analyzer_args+=("--json")
			shift
			;;
		--help | -h | help)
			usage
			return 0
			;;
		*)
			printf '%s\n' "Error: unknown option: $1" >&2
			usage >&2
			return 2
			;;
		esac
	done

	runtime=$(resolve_runtime "$runtime") || return $?
	case "$runtime" in
	opencode | claude-code | normalized) ;;
	*)
		printf '%s\n' "Error: unsupported runtime: $runtime" >&2
		return 2
		;;
	esac
	session_id=$(resolve_session "$runtime" "$session_id") || return $?

	if [[ -z "$source" ]]; then
		source=$(resolve_history_source "$runtime") || return $?
	elif [[ "$source_mode" == "db" && "$runtime" == "normalized" ]]; then
		runtime="opencode"
	fi
	local source_format="transcript"
	if [[ "$source_mode" == "db" || ( -z "$source_mode" && "$runtime" == "opencode" ) ]]; then
		source_format="database"
	fi

	local analyzer="${SCRIPT_DIR}/session-output-efficiency.py"
	if [[ ! -x "$analyzer" ]]; then
		printf '%s\n' "Error: output-efficiency analyzer is unavailable" >&2
		return 2
	fi
	local -a command=("$analyzer" "--runtime" "$runtime" "--source" "$source" "--source-format" "$source_format")
	if [[ -n "$session_id" ]]; then
		command+=("--session" "$session_id")
	fi
	command+=("${analyzer_args[@]+"${analyzer_args[@]}"}")
	"${command[@]}"
	return $?
}

main "$@"
