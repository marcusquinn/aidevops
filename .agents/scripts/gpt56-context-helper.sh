#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SETTINGS_FILE="${AIDEVOPS_SETTINGS_FILE:-${HOME}/.config/aidevops/settings.json}"

usage() {
	cat <<'EOF'
Usage: aidevops gpt56-context [enable|disable|status]

Controls the aidevops GPT-5.6 context cap in OpenCode.
  enable   Advertise a 300K context window (default), causing OpenCode's 80%
           auto-compaction to run near 240K and avoid long-context pricing.
  disable  Use OpenCode/OpenAI's native GPT-5.6 context metadata.
  status   Show the current setting.

Restart OpenCode after changing this setting.
EOF
	return 0
}

require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "Error: jq is required to update ${SETTINGS_FILE}" >&2
		return 1
	fi
	return 0
}

is_enabled() {
	local enabled="true"
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		return 0
	fi
	enabled=$(jq -r 'if .runtime.opencode.gpt56_context_cap == false then false else true end' "$SETTINGS_FILE" 2>/dev/null) || enabled="true"
	[[ "$enabled" == "true" ]]
}

show_status() {
	if is_enabled; then
		printf '%s\n' "GPT-5.6 OpenCode context cap: enabled (300K; auto-compaction near 240K)"
	else
		printf '%s\n' "GPT-5.6 OpenCode context cap: disabled (native provider limit)"
	fi
	return 0
}

set_enabled() {
	local enabled="$1"
	local settings_dir temp_file source_file
	settings_dir="${SETTINGS_FILE%/*}"
	mkdir -p "$settings_dir"
	temp_file=$(mktemp "${settings_dir}/settings.json.XXXXXX")
	source_file="$SETTINGS_FILE"
	if [[ ! -f "$source_file" ]]; then
		printf '%s\n' '{}' >"$temp_file"
		source_file="$temp_file"
	fi
	if ! jq --argjson enabled "$enabled" \
		'.runtime = (.runtime // {}) | .runtime.opencode = (.runtime.opencode // {}) | .runtime.opencode.gpt56_context_cap = $enabled' \
		"$source_file" >"${temp_file}.new"; then
		rm -f "$temp_file" "${temp_file}.new"
		return 1
	fi
	mv "${temp_file}.new" "$SETTINGS_FILE"
	rm -f "$temp_file"
	chmod 600 "$SETTINGS_FILE"
	show_status
	printf '%s\n' "Restart OpenCode to apply the change."
	return 0
}

main() {
	local action="${1:-status}"
	require_jq || return 1
	case "$action" in
	enable | on) set_enabled true ;;
	disable | off) set_enabled false ;;
	status) show_status ;;
	help | --help | -h) usage ;;
	*)
		printf '%s\n' "Unknown action: $action" >&2
		usage >&2
		return 2
		;;
	esac
	return 0
}

main "$@"
