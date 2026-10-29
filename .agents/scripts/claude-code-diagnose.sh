#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Claude Code read-only diagnostics (GH#35929)
# Usage: claude-code-diagnose.sh agent-summary
#
# agent-summary: reports whether the installed Claude Code CLI contains the
# background-agent progress summary source (query_source=agent_summary) and
# whether its CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES opt-in is set. It makes no
# model call, changes no setting, and only string-probes the installed file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly SUMMARY_SOURCE="agent_summary"
readonly SUMMARY_OPT_IN="CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES"
readonly PROBE_TIMEOUT_SECS=20

show_usage() {
	printf 'Usage: claude-code-diagnose.sh agent-summary\n'
	return 0
}

# Print the symlink-resolved file behind `claude` (cli.js for npm installs,
# the compiled binary for native and cask installs), or nothing.
resolve_claude_file() {
	local path link depth=0
	path=$(command -v claude 2>/dev/null || true)
	[[ "$path" == /* ]] || return 0
	while [[ -L "$path" && "$depth" -lt 16 ]]; do
		link=$(readlink "$path" 2>/dev/null) || break
		case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
		depth=$((depth + 1))
	done
	[[ -f "$path" ]] && printf '%s\n' "$path"
	return 0
}

# Print yes/no/unreadable for the opt-in in an aidevops-managed settings file.
settings_opt_in() {
	local settings="$1"
	[[ -f "$settings" ]] || {
		printf 'no (no %s)\n' "$settings"
		return 0
	}
	python3 - "$settings" "$SUMMARY_OPT_IN" <<'PY' 2>/dev/null || printf 'unreadable\n'
import json, sys
env = (json.load(open(sys.argv[1])) or {}).get('env') or {}
value = env.get(sys.argv[2])
print('no' if value in (None, '', '0', 'false') else f'yes ({value})')
PY
	return 0
}

agent_summary() {
	local file version owner probe classification reason env_state
	file=$(resolve_claude_file)
	owner=$(aidevops_claude_code_install_owner)
	if [[ -z "$file" ]]; then
		version="not installed"
		classification="unverified"
		reason="no claude executable on PATH"
	else
		version=$(timeout_sec 10 claude --version 2>/dev/null | head -n 1 || true)
		[[ -n "$version" ]] || version="unknown"
		probe=0
		LC_ALL=C timeout_sec "$PROBE_TIMEOUT_SECS" grep -a -q -F "$SUMMARY_SOURCE" "$file" || probe=$?
		case "$probe" in
		0)
			classification="potentially-affected"
			reason="installed CLI contains the ${SUMMARY_SOURCE} query source"
			;;
		1)
			classification="not-present"
			reason="installed CLI has no ${SUMMARY_SOURCE} query source"
			;;
		*)
			classification="unverified"
			reason="string probe failed or timed out (exit ${probe})"
			;;
		esac
	fi
	env_state="no"
	[[ -n "${!SUMMARY_OPT_IN:-}" ]] && env_state="yes (${!SUMMARY_OPT_IN})"

	printf 'Claude Code agent_summary exposure\n'
	printf '  CLI version: %s\n' "$version"
	printf '  Install owner: %s\n' "$owner"
	printf '  Classification: %s (%s)\n' "$classification" "$reason"
	printf '  %s opt-in, current environment: %s\n' "$SUMMARY_OPT_IN" "$env_state"
	printf '  %s opt-in, ~/.claude/settings.json env: %s\n' "$SUMMARY_OPT_IN" "$(settings_opt_in "${HOME}/.claude/settings.json")"
	printf '  Scope: interactive background agents can request summaries without the opt-in;\n'
	printf '         -p/SDK runs request them only when the opt-in is set; OpenCode direct\n'
	printf '         provider sessions do not run this code. No supported disable control is known.\n'
	printf '  Verify spend: with OTel enabled, aggregate claude_code.api_request by query_source=%s.\n' "$SUMMARY_SOURCE"
	printf '  Guidance: tools/ai-assistants/claude-code.md "Background agent summaries"\n'
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	agent-summary) agent_summary ;;
	help | --help | -h | "") show_usage ;;
	*)
		show_usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
