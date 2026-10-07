#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#33278: one-time move of user model pins from Claude Haiku 4.5 to
# Claude Haiku 5.5 (anthropic/claude-haiku-5-5, released 2026-10-07; $0.10 in
# and $0.50 out per 1M tokens for prompts up to 100K, 1M context). Framework
# defaults moved in the same release; this rewrites user-owned settings that
# would otherwise keep pinning the old model after update.
#
# Scope is deliberately narrow:
#   - Only first-party provider-prefixed IDs (`anthropic/claude-haiku-4-5` and
#     its dated form). These are routing keys, pins and fallback entries.
#     Bare IDs are skipped: in opencode.json they are provider model
#     definitions, and Claude CLI model names follow Claude Code's catalog.
#     Gateway prefixes such as `openrouter/anthropic/...` are skipped because
#     their slugs are not the Anthropic API IDs.
#   - credentials.sh: only `*_MODEL=` / `*_MODELS=` assignment lines.
#   - Reasoning values are kept: Haiku 5.5 accepts the `high` and `max`
#     variants a Haiku 4.5 route used.
# Each changed file gets a backup; failures leave the marker unset so the
# migration retries on the next setup run. Later explicit pins are honoured.
#
# Sourced by setup.sh; expects print_info and print_warning.

_HAIKU55_MARKER="gh33278-haiku-5-5-settings"
_HAIKU55_TARGET="anthropic/claude-haiku-5-5"
# Haiku 4.5 IDs, anchored so other providers, 4-50 or suffixed IDs never match.
_HAIKU55_OLD='(?<![\w./-])anthropic/claude-haiku-4-5(?:-\d{8})?(?![\w.-])'
_HAIKU55_ENV_LINE='^\s*(?:export\s+)?[A-Z0-9_]*MODELS?='

# Return 0 when the file holds an old Haiku reference within scope.
_haiku55_needs_rewrite() {
	local file="$1"
	local mode="$2"
	HAIKU55_OLD="$_HAIKU55_OLD" HAIKU55_ENV_LINE="$_HAIKU55_ENV_LINE" HAIKU55_MODE="$mode" \
		perl -ne '
			next if $ENV{HAIKU55_MODE} eq "env" && !/$ENV{HAIKU55_ENV_LINE}/;
			if (/$ENV{HAIKU55_OLD}/) { $found = 1; last }
			END { exit($found ? 0 : 1) }
		' "$file" 2>/dev/null
	return $?
}

# Write the rewritten content of $1 to $3 (mode $2: json|env).
_haiku55_render() {
	local file="$1"
	local mode="$2"
	local out="$3"
	HAIKU55_OLD="$_HAIKU55_OLD" HAIKU55_ENV_LINE="$_HAIKU55_ENV_LINE" \
		HAIKU55_MODE="$mode" HAIKU55_TARGET="$_HAIKU55_TARGET" \
		perl -pe '
			if ($ENV{HAIKU55_MODE} ne "env" || /$ENV{HAIKU55_ENV_LINE}/) {
				s/$ENV{HAIKU55_OLD}/$ENV{HAIKU55_TARGET}/g;
			}
		' "$file" >"$out" || return 1
	return 0
}

_haiku55_file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || printf '600\n'
	return 0
}

# Rewrite one file. Returns 0 when unchanged or updated, 1 to request a retry.
_haiku55_rewrite_file() {
	local file="$1"
	local mode="$2"
	local backup_dir="$3"
	local effective_uid="${EUID:-$(id -u)}"
	local backup_name="" backup_file="" temp_file="" file_mode=""

	[[ -e "$file" || -L "$file" ]] || return 0
	if [[ -L "$file" ]]; then
		# Dotfile-managed symlinks belong to the user's own sync tooling.
		if _haiku55_needs_rewrite "$file" "$mode"; then
			print_info "Skipped symlinked $file; update anthropic/claude-haiku-4-5 pins to ${_HAIKU55_TARGET} at its source (GH#33278)"
		fi
		return 0
	fi
	if [[ ! -f "$file" || ! -r "$file" || (! -O "$file" && "$effective_uid" -ne 0) ]]; then
		print_warning "Skipping unsafe or unreadable $file; GH#33278 Haiku 5.5 migration will retry"
		return 1
	fi
	_haiku55_needs_rewrite "$file" "$mode" || return 0

	backup_name="gh33278-${file#"$HOME"/}"
	backup_name="${backup_name//\//_}"
	backup_file="$backup_dir/$backup_name"
	file_mode=$(_haiku55_file_mode "$file")
	temp_file=$(mktemp "${file}.gh33278.XXXXXX") || return 1
	if ! _haiku55_render "$file" "$mode" "$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	if [[ "$file" == *.json ]] && command -v jq >/dev/null 2>&1 && ! jq empty "$temp_file" >/dev/null 2>&1; then
		rm -f "$temp_file"
		print_warning "Rewritten $file would not be valid JSON; GH#33278 Haiku 5.5 migration will retry"
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
	print_info "Moved Haiku model pins to ${_HAIKU55_TARGET} in $file (GH#33278). Backup: $backup_file"
	return 0
}

migrate_haiku_5_5_settings() {
	local marker_dir="${HOME:+$HOME/.aidevops/cache/migrations}"
	local marker_file="${marker_dir:+$marker_dir/$_HAIKU55_MARKER}"
	local backup_dir="${HOME:+$HOME/.aidevops/config-backups/migrations}"
	local config_dir="${HOME:+$HOME/.config/aidevops}"
	local file=""
	local failed=0

	if [[ -z "$marker_file" ]]; then
		print_warning "HOME unavailable; GH#33278 Haiku 5.5 migration will retry"
		return 0
	fi
	[[ -f "$marker_file" ]] && return 0
	if ! command -v perl >/dev/null 2>&1; then
		print_warning "perl unavailable; GH#33278 Haiku 5.5 migration will retry"
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
		_haiku55_rewrite_file "$file" json "$backup_dir" || failed=1
	done
	for file in "$config_dir/credentials.sh" "$config_dir"/tenants/*/credentials.sh; do
		[[ -e "$file" ]] || continue
		_haiku55_rewrite_file "$file" env "$backup_dir" || failed=1
	done

	if [[ "$failed" -ne 0 ]]; then
		print_warning "GH#33278 Haiku 5.5 settings migration incomplete; it will retry on the next setup run"
		return 0
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	return 0
}
