#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Upgrade Planning Library — planning template upgrade command
# =============================================================================
# Helper functions for `aidevops upgrade-planning`, extracted from aidevops.sh
# to keep the CLI orchestrator below the large-file gate while preserving behaviour.
#
# Usage: source "${INSTALL_DIR}/aidevops-upgrade-planning-lib.sh"
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_UPGRADE_PLANNING_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_UPGRADE_PLANNING_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_AIDEVOPS_UPGRADE_TRUE=true
_AIDEVOPS_UPGRADE_TOON_META="TOON:meta"

# Upgrade planning helpers (extracted for complexity reduction)

_upgrade_validate() {
	local project_root="$1"
	[[ ! -f "$project_root/.aidevops.json" ]] && {
		print_error "aidevops not initialized in this project"
		print_info "Run 'aidevops init' first"
		return 1
	}
	if command -v jq &>/dev/null; then
		jq -e '.features.planning == true' "$project_root/.aidevops.json" &>/dev/null || {
			print_error "Planning feature not enabled"
			print_info "Run 'aidevops init planning' to enable"
			return 1
		}
	else
		local pe
		pe=$(grep -o '"planning": *true' "$project_root/.aidevops.json" 2>/dev/null || echo "")
		[[ -z "$pe" ]] && {
			print_error "Planning feature not enabled"
			print_info "Run 'aidevops init planning' to enable"
			return 1
		}
	fi
	[[ ! -f "$AGENTS_DIR/templates/todo-template.md" ]] && {
		print_error "TODO template not found: $AGENTS_DIR/templates/todo-template.md"
		return 1
	}
	[[ ! -f "$AGENTS_DIR/templates/plans-template.md" ]] && {
		print_error "PLANS template not found: $AGENTS_DIR/templates/plans-template.md"
		return 1
	}
	return 0
}

_upgrade_check_version() {
	local file="$1" template="$2" label="$3"
	if check_planning_file_version "$file" "$template"; then
		if [[ -f "$file" ]]; then
			if ! grep -q "$_AIDEVOPS_UPGRADE_TOON_META" "$file" 2>/dev/null; then
				print_warning "$label uses minimal template (missing TOON markers)"
			else
				local cv tv
				cv=$(grep -A1 "$_AIDEVOPS_UPGRADE_TOON_META" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
				tv=$(grep -A1 "$_AIDEVOPS_UPGRADE_TOON_META" "$template" 2>/dev/null | tail -1 | cut -d',' -f1)
				print_warning "$label format version $cv -> $tv"
			fi
		else print_info "$label not found - will create from template"; fi
		return 0
	else
		local cv
		cv=$(grep -A1 "$_AIDEVOPS_UPGRADE_TOON_META" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
		print_success "$label already up to date (v${cv})"
		return 1
	fi
}

# t2434: Extract lines under "## <section>" until the next "## " header.
# Skips ## Format block entirely (its content is documentation, not tasks).
# Skips fenced code blocks.
# Exact-match on the section header — no regex escaping concerns.
_extract_todo_section() {
	local file="$1" section="$2"
	awk -v target="## $section" '
		/^## Format/ { in_format=1; next }
		in_format && /^## / { in_format=0 }
		in_format { next }
		/^```/ { in_codeblock = !in_codeblock; next }
		in_codeblock { next }
		$0 == target { found=1; next }
		found && /^## / { exit }
		found
	' "$file" 2>/dev/null || echo ""
}

# t2434: Filter stdin, removing only the literal Format-block placeholder IDs
# (tXXX, tYYY, tZZZ). Real-world repos have historic IDs that don't follow the
# strict t<digits> shape (e.g. "t059b", "t043-merge" from webapp) — we must
# preserve those. A blocklist is safer than an allowlist here: extraction
# already skips the Format section, so the filter is a secondary guard rather
# than primary validation.
_filter_todo_placeholders() {
	awk '
		!/^- \[[ x-]\] t/ { print; next }
		{
			id = $0
			sub(/^- \[[ x-]\] /, "", id)
			sub(/ .*/, "", id)
			if (id == "tXXX" || id == "tYYY" || id == "tZZZ") next
			print
		}
	'
}

# t2434: Insert content_file into target_file immediately after the closing
# "-->" of the named TOON marker block (<!--TOON:<tag>...-->).
# Idempotent only in the sense that each call inserts once per marker; repeated
# calls would stack insertions. Intended to be called once per tag per upgrade.
_insert_after_toon_marker() {
	local target_file="$1" toon_tag="$2" content_file="$3"
	local temp_file="${target_file}.insert"
	local marker_open="<!--TOON:${toon_tag}"
	local in_marker=false
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == *"$marker_open"* ]] && in_marker=true
		if [[ "$in_marker" == true && "$line" == "-->" ]]; then
			echo "$line"
			echo ""
			cat "$content_file"
			in_marker=false
			continue
		fi
		echo "$line"
	done <"$target_file" >"$temp_file"
	mv "$temp_file" "$target_file"
}

# t2434: Preserve each of the 6 task sections into $workdir/<tag>.txt for
# later re-insertion after the template is applied. Placeholder filter runs
# per section so Format-block tXXX-style examples never reach the new file.
_upgrade_todo_preserve_sections() {
	local todo_file="$1" workdir="$2"
	local sections=("Ready" "Backlog" "In Progress" "In Review" "Done" "Declined")
	local tags=("ready" "backlog" "in_progress" "in_review" "done" "declined")
	local i=0
	while [[ $i -lt ${#sections[@]} ]]; do
		local section="${sections[$i]}" tag="${tags[$i]}"
		local content
		content=$(_extract_todo_section "$todo_file" "$section")
		if [[ -n "$content" ]]; then
			content=$(printf '%s\n' "$content" | _filter_todo_placeholders)
			[[ -n "$content" ]] && printf '%s\n' "$content" >"$workdir/${tag}.txt"
		fi
		i=$((i + 1))
	done
	return 0
}

# t2434: Re-insert preserved section content after its matching TOON marker
# in the freshly-applied new template. Caller is responsible for counting
# merged tasks from the final file — keeping count out of the hot loop avoids
# subshell/arithmetic edge cases under `set -u` when content contains `GH#`-
# style IDs that don't match a naive `t[0-9]` count pattern.
_upgrade_todo_reinsert_sections() {
	local todo_file="$1" workdir="$2"
	local tags=("ready" "backlog" "in_progress" "in_review" "done" "declined")
	local tag content_file
	for tag in "${tags[@]}"; do
		content_file="$workdir/${tag}.txt"
		[[ -f "$content_file" && -s "$content_file" ]] || continue
		grep -q "<!--TOON:${tag}" "$todo_file" || continue
		_insert_after_toon_marker "$todo_file" "$tag" "$content_file"
	done
	return 0
}

# t2434: Upgrade TODO.md to the latest TOON-enhanced template, preserving
# tasks from all 6 sections (Ready, Backlog, In Progress, In Review, Done,
# Declined). Prior behaviour (GH#20077) only preserved Backlog and silently
# dropped the other 5 sections into TODO.md.bak, losing audit-trail data.
_upgrade_todo() {
	local todo_file="$1" todo_template="$2" backup="$3"
	print_info "Upgrading TODO.md..."
	local workdir=""
	workdir=$(mktemp -d)
	# shellcheck disable=SC2064  # intentional $workdir expansion at trap-set time
	trap "rm -rf \"${workdir}\"" RETURN
	if [[ -f "$todo_file" ]]; then
		_upgrade_todo_preserve_sections "$todo_file" "$workdir"
		[[ "$backup" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && {
			cp "$todo_file" "${todo_file}.bak"
			print_success "Backup created: TODO.md.bak"
		}
	fi
	local temp_todo="${todo_file}.new"
	if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$todo_template" >"$temp_todo" 2>/dev/null && [[ -s "$temp_todo" ]]; then
		mv "$temp_todo" "$todo_file"
	else
		rm -f "$temp_todo"
		cp "$todo_template" "$todo_file"
	fi
	sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$todo_file" 2>/dev/null || true
	_upgrade_todo_reinsert_sections "$todo_file" "$workdir"
	local merged=0
	merged=$(grep -cE '^- \[[ x-]\] (t[0-9]|GH#[0-9])' "$todo_file" 2>/dev/null || true)
	merged="${merged:-0}"
	[[ "$merged" -gt 0 ]] && print_success "Merged $merged existing task(s) across sections"
	print_success "TODO.md upgraded to TOON-enhanced template"
	return 0
}

_upgrade_plans() {
	local plans_file="$1" plans_template="$2" backup="$3" project_root="$4"
	print_info "Upgrading todo/PLANS.md..."
	mkdir -p "$project_root/todo/tasks"
	local existing_plans=""
	if [[ -f "$plans_file" ]]; then
		existing_plans=$(awk '/^### /{found=1} found{print}' "$plans_file" 2>/dev/null || echo "")
		[[ "$backup" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && {
			cp "$plans_file" "${plans_file}.bak"
			print_success "Backup created: todo/PLANS.md.bak"
		}
	fi
	local temp_plans="${plans_file}.new"
	if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$plans_template" >"$temp_plans" 2>/dev/null && [[ -s "$temp_plans" ]]; then
		mv "$temp_plans" "$plans_file"
	else
		rm -f "$temp_plans"
		cp "$plans_template" "$plans_file"
	fi
	sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$plans_file" 2>/dev/null || true
	if [[ -n "$existing_plans" ]] && grep -q "<!--TOON:active_plans" "$plans_file"; then
		local temp_file="${plans_file}.merge" pcf
		pcf=$(mktemp)
		trap 'rm -f "${pcf:-}"' RETURN
		printf '%s\n' "$existing_plans" >"$pcf"
		local in_active=false
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ "$line" == *"<!--TOON:active_plans"* ]] && in_active=true
			if [[ "$in_active" == true && "$line" == "-->" ]]; then
				echo "$line"
				echo ""
				cat "$pcf"
				in_active=false
				continue
			fi
			echo "$line"
		done <"$plans_file" >"$temp_file"
		rm -f "$pcf"
		mv "$temp_file" "$plans_file"
		print_success "Merged existing plans into Active Plans"
	fi
	print_success "todo/PLANS.md upgraded to TOON-enhanced template"
	return 0
}

_upgrade_config_version() {
	local config_file="$1"
	local av
	av=$(get_version)
	if command -v jq &>/dev/null; then
		local tj="${config_file}.tmp"
		jq --arg version "$av" '.templates_version = $version' "$config_file" >"$tj" && mv "$tj" "$config_file"
	else
		if ! grep -q '"templates_version"' "$config_file" 2>/dev/null; then
			local tj="${config_file}.tmp"
			awk -v ver="$av" '/"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" ver "\",\n  \"templates_version\": \"" ver "\"") } { print }' "$config_file" >"$tj" && mv "$tj" "$config_file"
		else sed_inplace "s/\"templates_version\": \"[^\"]*\"/\"templates_version\": \"$av\"/" "$config_file" 2>/dev/null || true; fi
	fi
	return 0
}

# Upgrade planning files to latest templates
cmd_upgrade_planning() {
	local force=false backup=true dry_run=false
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in --force | -f)
			force=true
			shift
			;;
		--no-backup)
			backup=false
			shift
			;;
		--dry-run | -n)
			dry_run=true
			shift
			;;
		*) shift ;; esac
	done
	print_header "Upgrade Planning Files"
	echo ""
	git rev-parse --is-inside-work-tree &>/dev/null || {
		print_error "Not in a git repository"
		return 1
	}
	[[ "$dry_run" != "$_AIDEVOPS_UPGRADE_TRUE" ]] && { check_protected_branch "chore" "upgrade-planning" || return 1; }
	local project_root
	project_root=$(git rev-parse --show-toplevel)
	_upgrade_validate "$project_root" || return 1
	local todo_file="$project_root/TODO.md" plans_file="$project_root/todo/PLANS.md"
	local todo_template="$AGENTS_DIR/templates/todo-template.md" plans_template="$AGENTS_DIR/templates/plans-template.md"
	local needs_upgrade=false todo_needs=false plans_needs=false
	_upgrade_check_version "$todo_file" "$todo_template" "TODO.md" && {
		todo_needs=true
		needs_upgrade=true
	}
	_upgrade_check_version "$plans_file" "$plans_template" "todo/PLANS.md" && {
		plans_needs=true
		needs_upgrade=true
	}
	[[ "$needs_upgrade" == "false" ]] && {
		echo ""
		print_success "Planning files are up to date!"
		return 0
	}
	echo ""
	if [[ "$dry_run" == "$_AIDEVOPS_UPGRADE_TRUE" ]]; then
		print_info "Dry run - no changes will be made"
		echo ""
		[[ "$todo_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  Would upgrade: TODO.md"
		[[ "$plans_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  Would upgrade: todo/PLANS.md"
		return 0
	fi
	if [[ "$force" == "false" ]]; then
		echo "Files to upgrade:"
		[[ "$todo_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  - TODO.md"
		[[ "$plans_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  - todo/PLANS.md"
		echo ""
		echo "This will:"
		echo "  1. Extract existing tasks from current files"
		echo "  2. Create backups (.bak files)"
		echo "  3. Apply new TOON-enhanced templates"
		echo "  4. Merge existing tasks into new structure"
		echo ""
		read -r -p "Continue? [y/N] " response
		[[ ! "$response" =~ ^[Yy]$ ]] && {
			print_info "Upgrade cancelled"
			return 0
		}
	fi
	echo ""
	[[ "$todo_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && _upgrade_todo "$todo_file" "$todo_template" "$backup"
	[[ "$plans_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && _upgrade_plans "$plans_file" "$plans_template" "$backup" "$project_root"
	_upgrade_config_version "$project_root/.aidevops.json"
	echo ""
	print_success "Planning files upgraded!"
	echo ""
	echo "Next steps:"
	echo "  1. Review the upgraded files"
	echo "  2. Verify your tasks were preserved"
	if [[ "$backup" == "$_AIDEVOPS_UPGRADE_TRUE" ]]; then
		echo "  3. Remove .bak files when satisfied"
		echo ""
		echo "If issues occurred, restore from backups:"
		[[ "$todo_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  mv TODO.md.bak TODO.md"
		[[ "$plans_needs" == "$_AIDEVOPS_UPGRADE_TRUE" ]] && echo "  mv todo/PLANS.md.bak todo/PLANS.md"
	fi
	return 0
}
