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
# GH#34416: a second one-time pass with its own marker and backup resets
# settings raised after the GH#32807 marker was written.
#
# Sourced by setup.sh; expects print_info and print_warning.

_COMPACTION_TARGET_240K_MARKER="gh32807-compaction-target-240k"
_COMPACTION_TARGET_240K_RESET_MARKER="gh34416-compaction-target-240k-reset"

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
	temp_file=$(mktemp "${settings_file}.compaction.XXXXXX") || return 1
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

# Run one marker-scoped reset pass. Returns 1 when the pass is deferred for a
# later retry (marker left unset) so later passes wait for it.
# Arguments: marker name, issue tag used for backups and messages (e.g. gh32807)
_migrate_compaction_target_pass() {
	local marker="$1"
	local tag="$2"
	local label="GH#${tag#gh}"
	local marker_dir="$HOME/.aidevops/cache/migrations"
	local marker_file="$marker_dir/$marker"
	local settings_file="$HOME/.config/aidevops/settings.json"
	local backup_dir="$HOME/.aidevops/config-backups/migrations"
	local backup_file="$backup_dir/${tag}-settings.json"

	[[ -f "$marker_file" ]] && return 0
	if [[ ! -e "$settings_file" ]]; then
		mkdir -p "$marker_dir" && date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
		return 0
	fi
	if [[ -L "$settings_file" || ! -f "$settings_file" || ! -r "$settings_file" ]]; then
		print_warning "Skipping unsafe or unreadable settings file; ${label} compaction target migration will retry"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq unavailable; ${label} compaction target migration will retry"
		return 1
	fi
	if ! jq empty "$settings_file" >/dev/null 2>&1; then
		print_warning "Invalid settings.json; ${label} compaction target migration will retry"
		return 1
	fi
	mkdir -p "$marker_dir" "$backup_dir" || return 1
	if jq -e "$_COMPACTION_TARGET_RAISED_FILTER" "$settings_file" >/dev/null 2>&1; then
		if ! _compaction_target_rewrite_settings "$settings_file" "$backup_file"; then
			print_warning "Failed to update $settings_file; ${label} compaction target migration will retry"
			return 1
		fi
		print_info "OpenCode compaction now targets 240K usable input for all models to cut cache costs (${label}). Backup: $backup_file"
		print_info "To opt out again: 'aidevops astra-context disable', 'aidevops gpt6-context disable' or 'aidevops gpt56-context disable', or set runtime.opencode.v2_compaction_target to false in settings.json for OpenCode 2"
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	return 0
}

# Each pass runs once. GH#34416 repeats the GH#32807 reset for settings raised
# after that marker was written: larger usable context still has no cost
# advantage, and larger request bodies hit the Codex backend 1 MiB limit.
migrate_compaction_target_240k() {
	if [[ -z "${HOME:-}" ]]; then
		print_warning "HOME unavailable; GH#32807/GH#34416 compaction target migration will retry"
		return 0
	fi
	_migrate_compaction_target_pass "$_COMPACTION_TARGET_240K_MARKER" gh32807 || return 0
	_migrate_compaction_target_pass "$_COMPACTION_TARGET_240K_RESET_MARKER" gh34416 || return 0
	return 0
}
