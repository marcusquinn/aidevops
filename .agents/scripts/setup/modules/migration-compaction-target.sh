#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#32807: one-time reset of OpenCode compaction-target opt-outs to the 240K
# default. A replay of 42 Opus 5.5 main sessions showed a 240K usable-input
# target costs less than larger targets: every turn re-reads the cached context
# and every pause over five minutes rewrites it. The plugin now uses 240K for
# all models (smaller native windows keep their own target) and OpenCode 2 is
# capped by default. This migration moves existing raised settings to that
# default once, with a backup; a later explicit opt-out is honoured.
#
# Sourced by setup.sh; expects print_info and print_warning.

_COMPACTION_TARGET_240K_MARKER="gh32807-compaction-target-240k"

# jq filter: true when runtime.opencode holds any setting that raises or
# disables the managed 240K compaction target.
_COMPACTION_TARGET_RAISED_FILTER='
	(.runtime.opencode // {})
	| if type == "object" then (
		(has("astra_compaction_target") and .astra_compaction_target != 240000)
		or .astra_context_cap == false
		or .gpt6_context_cap == false
		or .gpt56_context_cap == false
		or (has("v2_compaction_target") and .v2_compaction_target != 240000))
	else false end'

_COMPACTION_TARGET_RESET_FILTER='
	.runtime.opencode |= (
		(if has("astra_compaction_target") then .astra_compaction_target = 240000 else . end)
		| (if .astra_context_cap == false then .astra_context_cap = true else . end)
		| (if .gpt6_context_cap == false then del(.gpt6_context_cap) else . end)
		| (if .gpt56_context_cap == false then del(.gpt56_context_cap) else . end)
		| (if has("v2_compaction_target") then .v2_compaction_target = 240000 else . end))'

_compaction_target_file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || printf '600\n'
	return 0
}

# Rewrite settings.json with the reset filter, preserving its permissions.
# Returns 1 on any failure so the caller leaves the marker unset for retry.
_compaction_target_rewrite_settings() {
	local settings_file="$1"
	local backup_file="$2"
	local mode="" temp_file=""
	mode=$(_compaction_target_file_mode "$settings_file")
	if [[ ! -f "$backup_file" ]]; then
		cp -p "$settings_file" "$backup_file" || return 1
	fi
	temp_file=$(mktemp "${settings_file}.gh32807.XXXXXX") || return 1
	if ! jq "$_COMPACTION_TARGET_RESET_FILTER" "$settings_file" >"$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	chmod "$mode" "$temp_file" 2>/dev/null || chmod 600 "$temp_file"
	if ! mv "$temp_file" "$settings_file"; then
		rm -f "$temp_file"
		return 1
	fi
	return 0
}

migrate_compaction_target_240k() {
	local marker_dir="${HOME:+$HOME/.aidevops/cache/migrations}"
	local marker_file="${marker_dir:+$marker_dir/$_COMPACTION_TARGET_240K_MARKER}"
	local settings_file="${HOME:+$HOME/.config/aidevops/settings.json}"
	local backup_dir="${HOME:+$HOME/.aidevops/config-backups/migrations}"
	local backup_file="${backup_dir:+$backup_dir/gh32807-settings.json}"

	if [[ -z "$marker_file" ]]; then
		print_warning "HOME unavailable; GH#32807 compaction target migration will retry"
		return 0
	fi
	[[ -f "$marker_file" ]] && return 0
	if [[ ! -e "$settings_file" ]]; then
		mkdir -p "$marker_dir" && date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
		return 0
	fi
	if [[ -L "$settings_file" || ! -f "$settings_file" || ! -r "$settings_file" ]]; then
		print_warning "Skipping unsafe or unreadable settings file; GH#32807 compaction target migration will retry"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq unavailable; GH#32807 compaction target migration will retry"
		return 0
	fi
	if ! jq empty "$settings_file" >/dev/null 2>&1; then
		print_warning "Invalid settings.json; GH#32807 compaction target migration will retry"
		return 0
	fi
	mkdir -p "$marker_dir" "$backup_dir" || return 0
	if jq -e "$_COMPACTION_TARGET_RAISED_FILTER" "$settings_file" >/dev/null 2>&1; then
		if ! _compaction_target_rewrite_settings "$settings_file" "$backup_file"; then
			print_warning "Failed to update $settings_file; GH#32807 compaction target migration will retry"
			return 0
		fi
		print_info "OpenCode compaction now targets 240K usable input for all models to cut cache costs (GH#32807). Backup: $backup_file"
		print_info "To opt out again: 'aidevops astra-context disable' for Astra, or set runtime.opencode.v2_compaction_target to false in settings.json for OpenCode 2"
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	return 0
}
