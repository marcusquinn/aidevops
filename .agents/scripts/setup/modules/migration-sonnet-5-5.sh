#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#32848: one-time move of user model pins from older Claude Sonnet IDs to
# Claude Sonnet 5.5 (anthropic/claude-sonnet-5-5, released 2026-09-28; same
# price as Sonnet 5, faster, fewer tokens per task). Framework defaults moved
# in the same release; this rewrites user-owned settings that would otherwise
# keep pinning the old model after update.
#
# Scope is deliberately narrow:
#   - Only provider-prefixed IDs (`anthropic/claude-sonnet-{4,4-5,4-6,5}` and
#     dated 4.x forms). These are routing keys, pins and fallback entries.
#     Bare IDs are skipped: in opencode.json they are provider model
#     definitions, and Claude CLI model names follow Claude Code's catalog.
#   - credentials.sh: only `*_MODEL=` / `*_MODELS=` assignment lines.
# Each changed file gets a backup; failures leave the marker unset so the
# migration retries on the next setup run. Later explicit pins are honoured.
#
# Sourced by setup.sh; expects print_info and print_warning.

_SONNET55_MARKER="gh32848-sonnet-5-5-settings"
_SONNET55_TARGET="anthropic/claude-sonnet-5-5"
# Older Sonnet IDs, anchored so 5-1/5-5 and unrelated suffixes never match.
_SONNET55_OLD='anthropic/claude-sonnet-(?:4-6|4-5(?:-\d{8})?|4-\d{8}|4|5)(?![\w.-])'
_SONNET55_ENV_LINE='^\s*(?:export\s+)?[A-Z0-9_]*MODELS?='

# Return 0 when the file holds an old Sonnet reference within scope.
_sonnet55_needs_rewrite() {
	local file="$1"
	local mode="$2"
	SONNET55_OLD="$_SONNET55_OLD" SONNET55_ENV_LINE="$_SONNET55_ENV_LINE" SONNET55_MODE="$mode" \
		perl -ne '
			next if $ENV{SONNET55_MODE} eq "env" && !/$ENV{SONNET55_ENV_LINE}/;
			if (/$ENV{SONNET55_OLD}/) { $found = 1; last }
			END { exit($found ? 0 : 1) }
		' "$file" 2>/dev/null
	return $?
}

# Write the rewritten content of $1 to $3 (mode $2: json|env).
_sonnet55_render() {
	local file="$1"
	local mode="$2"
	local out="$3"
	SONNET55_OLD="$_SONNET55_OLD" SONNET55_ENV_LINE="$_SONNET55_ENV_LINE" \
		SONNET55_MODE="$mode" SONNET55_TARGET="$_SONNET55_TARGET" \
		perl -pe '
			if ($ENV{SONNET55_MODE} ne "env" || /$ENV{SONNET55_ENV_LINE}/) {
				s/$ENV{SONNET55_OLD}/$ENV{SONNET55_TARGET}/g;
			}
		' "$file" >"$out" || return 1
	return 0
}

_sonnet55_file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || printf '600\n'
	return 0
}

# Rewrite one file. Returns 0 when unchanged or updated, 1 to request a retry.
_sonnet55_rewrite_file() {
	local file="$1"
	local mode="$2"
	local backup_dir="$3"
	local effective_uid="${EUID:-$(id -u)}"
	local backup_name="" backup_file="" temp_file="" file_mode=""

	[[ -e "$file" || -L "$file" ]] || return 0
	if [[ -L "$file" ]]; then
		# Dotfile-managed symlinks belong to the user's own sync tooling.
		if _sonnet55_needs_rewrite "$file" "$mode"; then
			print_info "Skipped symlinked $file; update old anthropic/claude-sonnet-* pins to ${_SONNET55_TARGET} at its source (GH#32848)"
		fi
		return 0
	fi
	if [[ ! -f "$file" || ! -r "$file" || (! -O "$file" && "$effective_uid" -ne 0) ]]; then
		print_warning "Skipping unsafe or unreadable $file; GH#32848 Sonnet 5.5 migration will retry"
		return 1
	fi
	_sonnet55_needs_rewrite "$file" "$mode" || return 0

	backup_name="gh32848-${file#"$HOME"/}"
	backup_name="${backup_name//\//_}"
	backup_file="$backup_dir/$backup_name"
	file_mode=$(_sonnet55_file_mode "$file")
	temp_file=$(mktemp "${file}.gh32848.XXXXXX") || return 1
	if ! _sonnet55_render "$file" "$mode" "$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	if [[ "$file" == *.json ]] && command -v jq >/dev/null 2>&1 && ! jq empty "$temp_file" >/dev/null 2>&1; then
		rm -f "$temp_file"
		print_warning "Rewritten $file would not be valid JSON; GH#32848 Sonnet 5.5 migration will retry"
		return 1
	fi
	if [[ ! -f "$backup_file" ]]; then
		if ! cp -p "$file" "$backup_file"; then
			rm -f "$temp_file"
			return 1
		fi
		chmod 600 "$backup_file" 2>/dev/null || true
	fi
	chmod "$file_mode" "$temp_file" 2>/dev/null || chmod 600 "$temp_file"
	if ! mv "$temp_file" "$file"; then
		rm -f "$temp_file"
		return 1
	fi
	print_info "Moved Sonnet model pins to ${_SONNET55_TARGET} in $file (GH#32848). Backup: $backup_file"
	return 0
}

migrate_sonnet_5_5_settings() {
	local marker_dir="${HOME:+$HOME/.aidevops/cache/migrations}"
	local marker_file="${marker_dir:+$marker_dir/$_SONNET55_MARKER}"
	local backup_dir="${HOME:+$HOME/.aidevops/config-backups/migrations}"
	local config_dir="${HOME:+$HOME/.config/aidevops}"
	local file=""
	local failed=0

	if [[ -z "$marker_file" ]]; then
		print_warning "HOME unavailable; GH#32848 Sonnet 5.5 migration will retry"
		return 0
	fi
	[[ -f "$marker_file" ]] && return 0
	if ! command -v perl >/dev/null 2>&1; then
		print_warning "perl unavailable; GH#32848 Sonnet 5.5 migration will retry"
		return 0
	fi
	mkdir -p "$marker_dir" "$backup_dir" || return 0

	for file in \
		"$config_dir/config.jsonc" \
		"$config_dir/settings.json" \
		"$config_dir/plist-env-overrides.json" \
		"$HOME/.aidevops/agents/custom/configs/model-routing-table.json" \
		"$HOME/.config/opencode/opencode.json" \
		"$HOME/.config/opencode/opencode.jsonc"; do
		_sonnet55_rewrite_file "$file" json "$backup_dir" || failed=1
	done
	for file in "$config_dir/credentials.sh" "$config_dir"/tenants/*/credentials.sh; do
		[[ -e "$file" ]] || continue
		_sonnet55_rewrite_file "$file" env "$backup_dir" || failed=1
	done

	if [[ "$failed" -ne 0 ]]; then
		print_warning "GH#32848 Sonnet 5.5 settings migration incomplete; it will retry on the next setup run"
		return 0
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	return 0
}
