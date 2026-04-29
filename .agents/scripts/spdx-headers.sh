#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# spdx-headers.sh — Add SPDX license and copyright headers to source files.
# Good stuff for keeping attribution consistent across the codebase.
# Usage: spdx-headers.sh [add|check|update-hashes] [--dry-run]
# -----------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=shared-constants.sh
_spdx_dir="${BASH_SOURCE[0]%/*}"
[[ -f "${_spdx_dir}/shared-constants.sh" ]] && source "${_spdx_dir}/shared-constants.sh"

readonly COPYRIGHT_HOLDER="Marcus Quinn"
readonly COPYRIGHT_YEARS="2025-2026"
readonly LICENSE_ID="MIT"

readonly SH_HEADER_LICENSE="# SPDX-License-Identifier: ${LICENSE_ID}"
readonly SH_HEADER_COPYRIGHT="# SPDX-FileCopyrightText: ${COPYRIGHT_YEARS} ${COPYRIGHT_HOLDER}"
readonly MD_HEADER_LICENSE="<!-- SPDX-License-Identifier: ${LICENSE_ID} -->"
readonly MD_HEADER_COPYRIGHT="<!-- SPDX-FileCopyrightText: ${COPYRIGHT_YEARS} ${COPYRIGHT_HOLDER} -->"
readonly PY_HEADER_LICENSE="# SPDX-License-Identifier: ${LICENSE_ID}"
readonly PY_HEADER_COPYRIGHT="# SPDX-FileCopyrightText: ${COPYRIGHT_YEARS} ${COPYRIGHT_HOLDER}"

DRY_RUN=false
VERBOSE=false

# Replace a file preserving permissions — nice way to avoid losing execute bits
_safe_replace() {
	local tmp_file="$1"
	local target_file="$2"
	chmod --reference="$target_file" "$tmp_file" 2>/dev/null ||
		chmod "$(_file_perms "$target_file")" "$tmp_file" 2>/dev/null ||
		true
	mv "$tmp_file" "$target_file"
	return 0
}

_has_spdx() {
	local file="$1"
	grep -q 'SPDX-License-Identifier' "$file" 2>/dev/null
}

_add_sh_header() {
	local file="$1"
	_has_spdx "$file" && return 0
	[[ "$DRY_RUN" == "true" ]] && {
		echo "  would add: $file"
		return 0
	}
	local tmp_file="${file}.spdx.tmp"
	local first_line
	first_line=$(head -1 "$file")
	if [[ "$first_line" == "#!"* ]]; then
		{
			echo "$first_line"
			echo "$SH_HEADER_LICENSE"
			echo "$SH_HEADER_COPYRIGHT"
			tail -n +2 "$file"
		} >"$tmp_file"
	else
		{
			echo "$SH_HEADER_LICENSE"
			echo "$SH_HEADER_COPYRIGHT"
			cat "$file"
		} >"$tmp_file"
	fi
	_safe_replace "$tmp_file" "$file"
	echo "  added: $file"
	return 0
}

_add_md_header() {
	local file="$1"
	_has_spdx "$file" && return 0
	[[ "$DRY_RUN" == "true" ]] && {
		echo "  would add: $file"
		return 0
	}
	local tmp_file="${file}.spdx.tmp"
	local first_line
	first_line=$(head -1 "$file")
	if [[ "$first_line" == "---" ]]; then
		local frontmatter_end
		frontmatter_end=$(tail -n +2 "$file" | grep -n '^---' | head -1 | cut -d: -f1)
		if [[ -n "$frontmatter_end" ]]; then
			local end_line=$((frontmatter_end + 1))
			{
				head -n "$end_line" "$file"
				echo ""
				echo "$MD_HEADER_LICENSE"
				echo "$MD_HEADER_COPYRIGHT"
				tail -n +"$((end_line + 1))" "$file"
			} >"$tmp_file"
		else
			{
				echo "$MD_HEADER_LICENSE"
				echo "$MD_HEADER_COPYRIGHT"
				echo ""
				cat "$file"
			} >"$tmp_file"
		fi
	else
		{
			echo "$MD_HEADER_LICENSE"
			echo "$MD_HEADER_COPYRIGHT"
			echo ""
			cat "$file"
		} >"$tmp_file"
	fi
	_safe_replace "$tmp_file" "$file"
	echo "  added: $file"
	return 0
}

_add_py_header() {
	local file="$1"
	_has_spdx "$file" && return 0
	[[ "$DRY_RUN" == "true" ]] && {
		echo "  would add: $file"
		return 0
	}
	local tmp_file="${file}.spdx.tmp"
	local first_line
	first_line=$(head -1 "$file")
	if [[ "$first_line" == "#!"* ]] || [[ "$first_line" == "# -*- coding"* ]]; then
		{
			echo "$first_line"
			echo "$PY_HEADER_LICENSE"
			echo "$PY_HEADER_COPYRIGHT"
			tail -n +2 "$file"
		} >"$tmp_file"
	else
		{
			echo "$PY_HEADER_LICENSE"
			echo "$PY_HEADER_COPYRIGHT"
			cat "$file"
		} >"$tmp_file"
	fi
	_safe_replace "$tmp_file" "$file"
	echo "  added: $file"
	return 0
}

_add_txt_header() {
	local file="$1"
	local basename_file
	basename_file=$(basename "$file")
	# Skip files that cannot have comments — JSON templates, data files
	case "$basename_file" in VERSION | *.log | *.csv) return 0 ;; esac
	# JSON template files use .json.txt extension but are still JSON — skip
	case "$file" in *.json.txt) return 0 ;; esac
	_has_spdx "$file" && return 0
	[[ "$DRY_RUN" == "true" ]] && {
		echo "  would add: $file"
		return 0
	}
	local tmp_file="${file}.spdx.tmp"
	{
		echo "$SH_HEADER_LICENSE"
		echo "$SH_HEADER_COPYRIGHT"
		echo ""
		cat "$file"
	} >"$tmp_file"
	_safe_replace "$tmp_file" "$file"
	echo "  added: $file"
	return 0
}

# Update simplification-state.json hashes after SPDX additions — yeah, this
# prevents the simplification routine from re-processing header-only changes
_update_simplification_hashes() {
	local state_file=".agents/configs/simplification-state.json"
	[[ ! -f "$state_file" ]] && {
		echo "[INFO] No simplification-state.json found"
		return 0
	}
	command -v jq &>/dev/null || {
		echo "[WARN] jq required for hash update"
		return 1
	}
	echo "[INFO] Updating simplification hashes..."
	local updated=0
	local tmp_file="${state_file}.tmp"
	cp "$state_file" "$tmp_file"
	local file_path
	while IFS= read -r file_path; do
		[[ -z "$file_path" || ! -f "$file_path" ]] && continue
		local new_hash old_hash
		new_hash=$(git hash-object "$file_path" 2>/dev/null || echo "")
		[[ -z "$new_hash" ]] && continue
		old_hash=$(jq -r --arg f "$file_path" '.files[$f].hash // empty' "$tmp_file" 2>/dev/null)
		[[ -n "$old_hash" && "$old_hash" != "$new_hash" ]] && {
			jq --arg f "$file_path" --arg h "$new_hash" '.files[$f].hash = $h' "$tmp_file" >"${tmp_file}.2" && mv "${tmp_file}.2" "$tmp_file"
			updated=$((updated + 1))
		}
	done < <(jq -r '.files | keys[]' "$state_file" 2>/dev/null)
	[[ "$updated" -gt 0 ]] && {
		mv "$tmp_file" "$state_file"
		echo "[OK] Updated $updated hash(es)"
	} || {
		rm -f "$tmp_file"
		echo "[OK] No updates needed"
	}
	return 0
}

cmd_add() {
	echo "Adding SPDX headers (${LICENSE_ID}, ${COPYRIGHT_YEARS} ${COPYRIGHT_HOLDER})"
	echo ""
	echo "--- Shell scripts ---"
	git ls-files '*.sh' 2>/dev/null | while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_add_sh_header "$file"
	done
	echo ""
	echo "--- Markdown files ---"
	git ls-files '*.md' 2>/dev/null | while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_add_md_header "$file"
	done
	echo ""
	echo "--- Python files ---"
	git ls-files '*.py' 2>/dev/null | while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_add_py_header "$file"
	done
	echo ""
	echo "--- Text files (excluding .json.txt) ---"
	git ls-files '*.txt' 2>/dev/null | while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_add_txt_header "$file"
	done
	echo ""
	[[ "$DRY_RUN" != "true" ]] && _update_simplification_hashes
	echo ""
	echo "Done. Go for it — commit when ready."
	return 0
}

_is_spdx_exempt() {
	local file="$1"
	local bn
	bn=$(basename "$file")
	# Exempt: VERSION, log files, csv files, json.txt files
	[[ "$bn" == "VERSION" || "$bn" == *.log || "$bn" == *.csv ]] && return 0
	[[ "$file" == *.json.txt ]] && return 0
	return 1
}

# Count missing SPDX headers for a single file extension.
# Outputs "missing_count total_count" to stdout.
_check_ext_files() {
	local ext="$1"
	local missing=0 total=0
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		total=$((total + 1))
		_is_spdx_exempt "$file" && continue
		_has_spdx "$file" && continue
		echo "  missing: $file" >&2
		missing=$((missing + 1))
	done < <(git ls-files "*.${ext}" 2>/dev/null)
	echo "$missing $total"
	return 0
}

cmd_check() {
	echo "Checking SPDX header coverage..."
	local total_missing=0 total_files=0
	local ext result m t
	for ext in sh md py txt; do
		result=$(_check_ext_files "$ext")
		m="${result%% *}"
		t="${result##* }"
		total_missing=$((total_missing + m))
		total_files=$((total_files + t))
	done
	echo ""
	echo "Coverage: $((total_files - total_missing))/$total_files files ($total_missing missing)"
	[[ "$total_missing" -eq 0 ]] && return 0 || return 1
}

cmd_help() {
	echo "spdx-headers.sh — SPDX license header management"
	echo ""
	echo "Commands:"
	echo "  add              Add SPDX headers to all tracked source files"
	echo "  check            Report files missing SPDX headers"
	echo "  update-hashes    Refresh simplification-state.json hashes"
	echo ""
	echo "Options:"
	echo "  --dry-run        Show what would change"
	echo "  --verbose        Show skipped files"
	echo ""
	echo "Files: .sh, .md, .py, .txt (git-tracked only, excludes .json.txt)"
	return 0
}

_parse_options() {
	local arg
	for arg in "$@"; do
		[[ "$arg" == "--dry-run" ]] && DRY_RUN=true
		[[ "$arg" == "--verbose" ]] && VERBOSE=true
	done
	return 0
}

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true
	_parse_options "$@"
	case "$command" in
	add) cmd_add ;;
	check) cmd_check ;;
	update-hashes) _update_simplification_hashes ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
