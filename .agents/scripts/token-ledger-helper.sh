#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# token-ledger-helper.sh — Runtime-agnostic token usage ledger for subagents
# =============================================================================
#
# Records token usage from subagent calls into a JSONL ledger file so that
# signature footers can include total token counts across all subagents in a
# session. The ledger is a plain file — any runtime (Claude Code, OpenCode,
# custom agents) can write to it without runtime-specific DB access.
#
# Ledger location:
#   ~/.aidevops/.agent-workspace/tmp/token-ledger-{session_id}.jsonl
#
# Each line is a JSON object:
#   {"ts":"ISO","agent":"explore","tokens":1234,"model":"haiku","task_id":"abc"}
#
# Usage:
#   token-ledger-helper.sh record --agent NAME --tokens N [--model MODEL] [--task-id ID] [--session-id SID]
#   token-ledger-helper.sh sum    [--session-id SID]
#   token-ledger-helper.sh show   [--session-id SID]
#   token-ledger-helper.sh reset  [--session-id SID]
#   token-ledger-helper.sh help
#
# Environment variables:
#   AIDEVOPS_SESSION_ID   Override session ID for ledger file naming
#   AIDEVOPS_LEDGER_DIR   Override ledger directory (default: ~/.aidevops/.agent-workspace/tmp)

set -euo pipefail

LEDGER_DIR="${AIDEVOPS_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
LEDGER_PREFIX="token-ledger-"
LEDGER_SUFFIX=".jsonl"

# =============================================================================
# Session ID resolution
# =============================================================================
# Determines a stable session identifier for the ledger filename.
# Priority: explicit --session-id > AIDEVOPS_SESSION_ID env > PPID chain.

_resolve_session_id() {
	local explicit_id="$1"

	if [[ -n "$explicit_id" ]]; then
		printf '%s' "$explicit_id"
		return 0
	fi

	if [[ -n "${AIDEVOPS_SESSION_ID:-}" ]]; then
		printf '%s' "$AIDEVOPS_SESSION_ID"
		return 0
	fi

	# Fallback: use the top-level parent PID as a stable session anchor.
	# Walk up the process tree to find the outermost non-init process,
	# capped at 10 levels to avoid infinite loops.
	local pid="${PPID:-$$}"
	local prev_pid="$pid"
	local depth=0
	while [[ "$pid" -gt 1 ]] && [[ "$depth" -lt 10 ]] 2>/dev/null; do
		prev_pid="$pid"
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "1")
		depth=$((depth + 1))
	done

	printf 'pid-%s' "$prev_pid"
	return 0
}

# =============================================================================
# Ledger file path
# =============================================================================

_ledger_path() {
	local session_id="$1"
	printf '%s/%s%s%s' "$LEDGER_DIR" "$LEDGER_PREFIX" "$session_id" "$LEDGER_SUFFIX"
	return 0
}

# =============================================================================
# record — append a token usage entry to the ledger
# =============================================================================

cmd_record() {
	local agent="" tokens="" model="" task_id="" session_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent | -a)
			agent="$2"
			shift 2
			;;
		--tokens | -t)
			tokens="$2"
			shift 2
			;;
		--model | -m)
			model="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
			shift 2
			;;
		--session-id | -s)
			session_id="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$agent" ]]; then
		echo "Error: --agent is required" >&2
		return 1
	fi

	if [[ -z "$tokens" ]] || ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
		echo "Error: --tokens must be a positive integer" >&2
		return 1
	fi

	local sid
	sid=$(_resolve_session_id "$session_id")

	local ledger
	ledger=$(_ledger_path "$sid")

	mkdir -p "$(dirname "$ledger")"

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Build JSON line — use printf for Bash 3.2 compat (no jq dependency)
	local json_line
	json_line=$(printf '{"ts":"%s","agent":"%s","tokens":%s' "$ts" "$agent" "$tokens")
	if [[ -n "$model" ]]; then
		json_line=$(printf '%s,"model":"%s"' "$json_line" "$model")
	fi
	if [[ -n "$task_id" ]]; then
		json_line=$(printf '%s,"task_id":"%s"' "$json_line" "$task_id")
	fi
	json_line="${json_line}}"

	printf '%s\n' "$json_line" >>"$ledger"
	return 0
}

# =============================================================================
# sum — total tokens across all ledger entries for a session
# =============================================================================

cmd_sum() {
	local session_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-id | -s)
			session_id="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local sid
	sid=$(_resolve_session_id "$session_id")

	local ledger
	ledger=$(_ledger_path "$sid")

	if [[ ! -f "$ledger" ]]; then
		echo "0"
		return 0
	fi

	# Sum tokens field from each JSONL line.
	# Use grep + awk for portability (no jq dependency).
	local total=0
	local line
	while IFS= read -r line; do
		# Extract tokens value: match "tokens":NNNN
		local val
		val=$(printf '%s' "$line" | grep -oE '"tokens":[0-9]+' | grep -oE '[0-9]+' || echo "0")
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			total=$((total + val))
		fi
	done <"$ledger"

	printf '%d\n' "$total"
	return 0
}

# =============================================================================
# show — display all ledger entries for a session
# =============================================================================

cmd_show() {
	local session_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-id | -s)
			session_id="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local sid
	sid=$(_resolve_session_id "$session_id")

	local ledger
	ledger=$(_ledger_path "$sid")

	if [[ ! -f "$ledger" ]]; then
		echo "No ledger entries for session: ${sid}"
		return 0
	fi

	echo "Session: ${sid}"
	echo "Ledger: ${ledger}"
	echo "---"
	cat "$ledger"
	echo "---"

	local total
	total=$(cmd_sum --session-id "$sid")
	echo "Total: ${total} tokens"
	return 0
}

# =============================================================================
# reset — delete the ledger file for a session
# =============================================================================

cmd_reset() {
	local session_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-id | -s)
			session_id="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local sid
	sid=$(_resolve_session_id "$session_id")

	local ledger
	ledger=$(_ledger_path "$sid")

	if [[ -f "$ledger" ]]; then
		rm -f "$ledger"
		echo "Ledger reset for session: ${sid}"
	else
		echo "No ledger to reset for session: ${sid}"
	fi
	return 0
}

# =============================================================================
# help
# =============================================================================

cmd_help() {
	cat <<'EOF'
token-ledger-helper.sh — Runtime-agnostic token usage ledger for subagents

Usage:
  token-ledger-helper.sh record --agent NAME --tokens N [--model MODEL] [--task-id ID] [--session-id SID]
  token-ledger-helper.sh sum    [--session-id SID]
  token-ledger-helper.sh show   [--session-id SID]
  token-ledger-helper.sh reset  [--session-id SID]
  token-ledger-helper.sh help

Commands:
  record    Append a token usage entry to the session ledger
  sum       Print total tokens for the session (integer)
  show      Display all ledger entries and total
  reset     Delete the ledger file for the session
  help      Show this help

Options:
  --agent NAME       Subagent name (e.g., "explore", "pr", "general")
  --tokens N         Token count (positive integer)
  --model MODEL      Model used (e.g., "haiku", "sonnet", "opus")
  --task-id ID       Task ID from the Task tool invocation
  --session-id SID   Override session ID (default: auto-detected from env/PID)

Environment:
  AIDEVOPS_SESSION_ID   Override session ID for ledger file naming
  AIDEVOPS_LEDGER_DIR   Override ledger directory

Ledger format (JSONL):
  {"ts":"2025-01-15T10:30:00Z","agent":"explore","tokens":1234,"model":"haiku","task_id":"abc"}

Integration with gh-signature-helper.sh:
  The signature helper reads the ledger via --subagent-tokens flag or
  auto-detects it when generating footers. Subagent tokens are added to
  the session total and shown as a breakdown in the signature.

Example:
  # Record subagent usage
  token-ledger-helper.sh record --agent explore --tokens 500 --model haiku
  token-ledger-helper.sh record --agent pr --tokens 2000 --model sonnet

  # Check total
  token-ledger-helper.sh sum
  # Output: 2500

  # Show breakdown
  token-ledger-helper.sh show
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	record) cmd_record "$@" ;;
	sum) cmd_sum "$@" ;;
	show) cmd_show "$@" ;;
	reset) cmd_reset "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Error: Unknown command: $command" >&2
		cmd_help >&2
		return 1
		;;
	esac
}

main "$@"
