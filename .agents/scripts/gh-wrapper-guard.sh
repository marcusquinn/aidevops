#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-wrapper-guard.sh — static checker for raw gh issue/pr create calls
#
# Enforces the origin-labelling rule from prompts/build.txt:
#   "NEVER use raw gh pr create or gh issue create directly. Always use
#    the wrappers: gh_create_pr and gh_create_issue."
#
# Subcommands:
#   check        --base <ref>   Scan added/modified lines in diff vs <ref>
#   check-staged                Scan staged changes (git diff --cached)
#   check-full                  Scan all tracked .sh files in the repo
#
# Exit codes:
#   0  — clean (no violations)
#   1  — violations found
#   2  — usage error
#
# Line-level allowlist:
#   Any line ending with "# aidevops-allow: raw-gh-wrapper" is skipped.
#
# File-level exclusions:
#   - shared-constants.sh (definition site for the wrappers)
#   - .agents/scripts/tests/** (test fixtures may legitimately contain raw calls)
#
# Environment:
#   GH_WRAPPER_GUARD_DISABLE=1 — bypass entirely (exit 0)

set -euo pipefail

# --- bypass ----------------------------------------------------------------
if [[ "${GH_WRAPPER_GUARD_DISABLE:-0}" == "1" ]]; then
	exit 0
fi

# --- constants --------------------------------------------------------------
# Patterns that match raw gh issue/pr create invocations.
# We match:  gh issue create  /  gh pr create
# We skip lines containing the allowlist marker.
readonly ALLOWLIST_MARKER='# aidevops-allow: raw-gh-wrapper'

# File-level exclusions (basename or path-suffix match)
_is_excluded_file() {
	local file="$1"
	# Definition site
	case "$file" in
	*shared-constants.sh) return 0 ;;
	*agents/scripts/tests/*) return 0 ;;
	esac
	return 1
}

# --- helpers -----------------------------------------------------------------

_scan_line() {
	# Returns 0 if the line contains a raw gh issue/pr create call that is
	# NOT allowlisted. Returns 1 otherwise (clean).
	local line="$1"

	# Skip allowlisted lines
	if [[ "$line" == *"$ALLOWLIST_MARKER"* ]]; then
		return 1
	fi

	# Skip comment-only lines (leading # after optional whitespace)
	local stripped="${line#"${line%%[![:space:]]*}"}"
	if [[ "$stripped" == \#* ]]; then
		return 1
	fi

	# Match raw "gh issue create" or "gh pr create"
	# Use word-boundary-like matching: the gh command should be preceded by
	# start-of-line, whitespace, pipe, semicolon, $( or backtick.
	if echo "$line" | grep -qE '(^|[[:space:];|`]|\$\()gh[[:space:]]+issue[[:space:]]+create'; then
		return 0
	fi
	if echo "$line" | grep -qE '(^|[[:space:];|`]|\$\()gh[[:space:]]+pr[[:space:]]+create'; then
		return 0
	fi

	return 1
}

_format_violation() {
	local file="$1"
	local lineno="$2"
	local line="$3"
	printf '  %s:%s: %s\n' "$file" "$lineno" "$line"
}

# --- subcommands -------------------------------------------------------------

cmd_check() {
	local base_ref="${1:-}"
	if [[ -z "$base_ref" ]]; then
		printf 'Usage: gh-wrapper-guard.sh check --base <ref>\n' >&2
		return 2
	fi

	local violations=0
	local violation_output=""

	# Get list of .sh files changed relative to base
	local changed_files
	changed_files=$(git diff --name-only "$base_ref"...HEAD -- '*.sh' 2>/dev/null || true)
	if [[ -z "$changed_files" ]]; then
		return 0
	fi

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_is_excluded_file "$file" && continue
		[[ -f "$file" ]] || continue

		# Scan only added/modified lines (+ lines in unified diff)
		local diff_output
		diff_output=$(git diff "$base_ref"...HEAD -- "$file" 2>/dev/null || true)
		[[ -z "$diff_output" ]] && continue

		local current_lineno=0
		while IFS= read -r diff_line; do
			# Track line numbers from @@ hunks
			if [[ "$diff_line" =~ ^@@.*\+([0-9]+) ]]; then
				current_lineno=$((BASH_REMATCH[1] - 1))
				continue
			fi

			# Only look at added lines
			if [[ "$diff_line" == +* && "$diff_line" != "+++"* ]]; then
				current_lineno=$((current_lineno + 1))
				local content="${diff_line:1}"
				if _scan_line "$content"; then
					violation_output+=$(_format_violation "$file" "$current_lineno" "$content")
					violation_output+=$'\n'
					violations=$((violations + 1))
				fi
			elif [[ "$diff_line" != -* && "$diff_line" != "---"* ]]; then
				current_lineno=$((current_lineno + 1))
			fi
		done <<<"$diff_output"
	done <<<"$changed_files"

	if [[ "$violations" -gt 0 ]]; then
		printf 'gh-wrapper-guard: %d violation(s) found — use gh_create_issue / gh_create_pr wrappers instead of raw gh commands.\n' "$violations"
		printf 'Rule: prompts/build.txt → "Origin labelling (MANDATORY)"\n'
		printf 'Suppress: append "# aidevops-allow: raw-gh-wrapper" to the line.\n\n'
		printf '%s' "$violation_output"
		return 1
	fi
	return 0
}

cmd_check_staged() {
	local violations=0
	local violation_output=""

	# Get staged .sh files
	local staged_files
	staged_files=$(git diff --cached --name-only -- '*.sh' 2>/dev/null || true)
	if [[ -z "$staged_files" ]]; then
		return 0
	fi

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_is_excluded_file "$file" && continue

		local diff_output
		diff_output=$(git diff --cached -- "$file" 2>/dev/null || true)
		[[ -z "$diff_output" ]] && continue

		local current_lineno=0
		while IFS= read -r diff_line; do
			if [[ "$diff_line" =~ ^@@.*\+([0-9]+) ]]; then
				current_lineno=$((BASH_REMATCH[1] - 1))
				continue
			fi

			if [[ "$diff_line" == +* && "$diff_line" != "+++"* ]]; then
				current_lineno=$((current_lineno + 1))
				local content="${diff_line:1}"
				if _scan_line "$content"; then
					violation_output+=$(_format_violation "$file" "$current_lineno" "$content")
					violation_output+=$'\n'
					violations=$((violations + 1))
				fi
			elif [[ "$diff_line" != -* && "$diff_line" != "---"* ]]; then
				current_lineno=$((current_lineno + 1))
			fi
		done <<<"$diff_output"
	done <<<"$staged_files"

	if [[ "$violations" -gt 0 ]]; then
		printf 'gh-wrapper-guard: %d violation(s) found — use gh_create_issue / gh_create_pr wrappers instead of raw gh commands.\n' "$violations"
		printf 'Rule: prompts/build.txt → "Origin labelling (MANDATORY)"\n'
		printf 'Suppress: append "# aidevops-allow: raw-gh-wrapper" to the line.\n\n'
		printf '%s' "$violation_output"
		return 1
	fi
	return 0
}

cmd_check_full() {
	local violations=0
	local violation_output=""

	# Scan all tracked .sh files using grep for speed (661+ files).
	# Exclude shared-constants.sh and tests/ at the grep level (not bash loop).
	local file_count
	file_count=$(git ls-files '*.sh' 2>/dev/null | grep -cvE '(shared-constants\.sh|agents/scripts/tests/)' || true)
	[[ "$file_count" -eq 0 ]] && return 0

	# Fast grep pass: find candidate files with raw gh issue/pr create
	local candidates
	candidates=$(git ls-files '*.sh' 2>/dev/null |
		grep -vE '(shared-constants\.sh|agents/scripts/tests/)' |
		xargs grep -lE 'gh[[:space:]]+(issue|pr)[[:space:]]+create' 2>/dev/null ||
		true)

	if [[ -z "$candidates" ]]; then
		printf 'gh-wrapper-guard: all %s .sh files clean.\n' "$file_count"
		return 0
	fi

	# Detailed scan of candidate files only (verify line-level: skip comments + allowlist)
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		[[ -f "$file" ]] || continue
		# Use grep -n for fast line+number extraction, then filter
		while IFS=: read -r lineno line; do
			if _scan_line "$line"; then
				violation_output+=$(_format_violation "$file" "$lineno" "$line")
				violation_output+=$'\n'
				violations=$((violations + 1))
			fi
		done < <(grep -nE 'gh[[:space:]]+(issue|pr)[[:space:]]+create' "$file" 2>/dev/null || true)
	done <<<"$candidates"

	if [[ "$violations" -gt 0 ]]; then
		printf 'gh-wrapper-guard: %d violation(s) found — use gh_create_issue / gh_create_pr wrappers instead of raw gh commands.\n' "$violations"
		printf 'Rule: prompts/build.txt → "Origin labelling (MANDATORY)"\n'
		printf 'Suppress: append "# aidevops-allow: raw-gh-wrapper" to the line.\n\n'
		printf '%s' "$violation_output"
		return 1
	fi

	printf 'gh-wrapper-guard: all %s .sh files clean.\n' "$file_count"
	return 0
}

show_help() {
	printf 'gh-wrapper-guard.sh — enforce gh_create_issue / gh_create_pr wrapper usage\n\n'
	printf 'Usage:\n'
	printf '  gh-wrapper-guard.sh check --base <ref>   Scan PR diff vs base ref\n'
	printf '  gh-wrapper-guard.sh check-staged          Scan staged changes\n'
	printf '  gh-wrapper-guard.sh check-full             Scan all tracked .sh files\n'
	printf '  gh-wrapper-guard.sh help                   Show this help\n\n'
	printf 'Environment:\n'
	printf '  GH_WRAPPER_GUARD_DISABLE=1  Bypass entirely\n\n'
	printf 'Line suppression:\n'
	printf '  Append "# aidevops-allow: raw-gh-wrapper" to any line to skip it.\n'
	return 0
}

# --- main --------------------------------------------------------------------
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	check)
		local base=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--base)
				base="${2:-}"
				shift 2
				;;
			*)
				base="$1"
				shift
				;;
			esac
		done
		cmd_check "$base"
		;;
	check-staged)
		cmd_check_staged
		;;
	check-full)
		cmd_check_full
		;;
	help | --help | -h)
		show_help
		;;
	*)
		printf 'Unknown command: %s\n' "$cmd" >&2
		show_help
		return 2
		;;
	esac
}

main "$@"
