#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Aggregate repeated and oversized tool-output evidence without exposing content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly SCRIPT_DIR
readonly OPENCODE_RUNTIME="opencode"

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
the Vault-managed session-history read gate. Active OpenCode conversations are
resolved from the runtime data store by exact ID. Raw tool inputs and outputs
are never emitted.
EOF
	return 0
}

active_opencode_session() {
	if [[ -n "${AIDEVOPS_OPENCODE_SESSION_ID:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_OPENCODE_SESSION_ID"
	else
		printf '%s\n' "${OPENCODE_SESSION_ID:-}"
	fi
	return 0
}

resolve_runtime() {
	local requested="$1"
	if [[ -n "$requested" ]]; then
		printf '%s\n' "$requested"
		return 0
	fi
	if [[ -n "${AIDEVOPS_OPENCODE_SESSION_ID:-}${OPENCODE_SESSION_ID:-}" ]]; then
		printf '%s\n' "$OPENCODE_RUNTIME"
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
		if [[ "$runtime" == "$OPENCODE_RUNTIME" && -n "${AIDEVOPS_OPENCODE_SESSION_ID:-}" && -n "${AIDEVOPS_SESSION_ID:-}" && "$requested" == "$AIDEVOPS_SESSION_ID" ]]; then
			active_opencode_session
			return $?
		fi
		printf '%s\n' "$requested"
		return 0
	fi
	case "$runtime" in
	"$OPENCODE_RUNTIME") active_opencode_session ;;
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

resolve_opencode_history_source() {
	local session_id="$1"
	local configured_source active_source
	configured_source=$(resolve_history_source "$OPENCODE_RUNTIME") || return $?
	if [[ -z "$session_id" || -z "${XDG_DATA_HOME:-}" || "${AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY:-}" == "1" || "${AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY:-}" == "true" ]]; then
		printf '%s\n' "$configured_source"
		return 0
	fi
	active_source="${XDG_DATA_HOME}/opencode/opencode.db"
	if [[ "$active_source" == "$configured_source" || ! -f "$active_source" ]]; then
		printf '%s\n' "$configured_source"
		return 0
	fi
	if python3 - "$active_source" "$session_id" <<'PY' >/dev/null 2>&1; then
import sqlite3
import sys
from pathlib import Path

database_path = Path(sys.argv[1]).absolute()
session_id = sys.argv[2]
uri = f"{database_path.as_uri()}?mode=ro"
with sqlite3.connect(uri, uri=True) as connection:
    row = connection.execute(
        "SELECT 1 FROM session WHERE id = ? LIMIT 1", (session_id,)
    ).fetchone()
raise SystemExit(0 if row else 1)
PY
		printf '%s\n' "$active_source"
		return 0
	fi
	printf '%s\n' "$configured_source"
	return 0
}

main() {
	local runtime="" session_id="" source="" source_mode=""
	local -a analyzer_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--runtime)
			[[ $# -gt 1 ]] || {
				printf '%s\n' "Error: --runtime requires a value" >&2
				return 2
			}
			runtime="$2"
			shift 2
			;;
		--session)
			[[ $# -gt 1 ]] || {
				printf '%s\n' "Error: --session requires a value" >&2
				return 2
			}
			session_id="$2"
			shift 2
			;;
		--input)
			[[ $# -gt 1 ]] || {
				printf '%s\n' "Error: --input requires a path" >&2
				return 2
			}
			source="$2"
			source_mode="input"
			shift 2
			;;
		--db)
			[[ $# -gt 1 ]] || {
				printf '%s\n' "Error: --db requires a path" >&2
				return 2
			}
			source="$2"
			source_mode="db"
			shift 2
			;;
		--min-repeat-bytes | --oversized-bytes | --max-findings)
			[[ $# -gt 1 ]] || {
				printf '%s\n' "Error: $1 requires a value" >&2
				return 2
			}
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
	"$OPENCODE_RUNTIME" | claude-code | normalized) ;;
	*)
		printf '%s\n' "Error: unsupported runtime: $runtime" >&2
		return 2
		;;
	esac
	session_id=$(resolve_session "$runtime" "$session_id") || return $?

	if [[ -z "$source" ]]; then
		if [[ "$runtime" == "$OPENCODE_RUNTIME" ]]; then
			source=$(resolve_opencode_history_source "$session_id") || return $?
		else
			source=$(resolve_history_source "$runtime") || return $?
		fi
	elif [[ "$source_mode" == "db" && "$runtime" == "normalized" ]]; then
		runtime="$OPENCODE_RUNTIME"
	fi
	local source_format="transcript"
	if [[ "$source_mode" == "db" || (-z "$source_mode" && "$runtime" == "$OPENCODE_RUNTIME") ]]; then
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
