#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Lint File Discovery - Shared file collection for quality checks
# =============================================================================
# Centralises file-discovery and exclusion logic used by both CI
# (.github/workflows/code-quality.yml) and local linting (linters-local.sh).
#
# Exclusion policy (single source of truth):
#   _archive/            - local archive directories
#
# Usage (CI — git-based):
#   source .agents/scripts/lint-file-discovery.sh
#   lint_shell_files      # populates LINT_SH_FILES (newline-separated)
#   lint_python_files     # populates LINT_PY_FILES (newline-separated)
#
# Usage (local — find-based, includes .agents/scripts/setup/modules/ and setup.sh):
#   source .agents/scripts/lint-file-discovery.sh
#   lint_shell_files_local   # populates LINT_SH_FILES (null-separated array)
#   lint_python_files_local  # populates LINT_PY_FILES_LOCAL (null-separated array)
#
# Both modes apply identical exclusion patterns.
# =============================================================================

# Include guard
[[ -n "${_LINT_FILE_DISCOVERY_LOADED:-}" ]] && return 0
_LINT_FILE_DISCOVERY_LOADED=1

# Exclusion pattern for grep -v (pipe-separated, used with grep -E)
# Single source of truth for all archive/excluded directories.
readonly LINT_EXCLUDE_PATTERN='_archive/'

# -----------------------------------------------------------------------------
# Git-based discovery (CI mode)
# -----------------------------------------------------------------------------
# Uses git ls-files — works in CI where the full repo is checked out.
# Results are newline-separated file paths.

LINT_SH_FILES=""
LINT_PY_FILES=""
LINT_CHANGED_FILES=""
LINT_CHANGED_FILES_FINGERPRINT=""
LINT_CHANGED_FILES_READY=false

# Populate LINT_SH_FILES with all tracked .sh files, excluding archived dirs.
lint_shell_files() {
	LINT_SH_FILES=$(git ls-files '*.sh' | grep -Ev "$LINT_EXCLUDE_PATTERN")
	return 0
}

# Populate LINT_PY_FILES with all tracked .py files, excluding archived dirs.
lint_python_files() {
	LINT_PY_FILES=$(git ls-files '*.py' | grep -Ev "$LINT_EXCLUDE_PATTERN" || true)
	return 0
}

_lint_changed_files_fingerprint() {
	local inventory="$1"
	{
		printf '%s\n' "$inventory"
		local file=""
		while IFS= read -r file; do
			[[ -n "$file" && -f "$file" ]] || continue
			cksum "./${file}" 2>/dev/null || printf 'unreadable=%s\n' "$file"
		done <<<"$inventory"
	} | cksum | awk '{print $1}'
	return 0
}

# Build one normalized changed-file inventory for the complete local lint run.
# Includes branch, unstaged, staged, and untracked non-ignored files.
lint_changed_files() {
	local base_ref="${1:-}"
	local changed_files=""
	local chunk=""
	if [[ -n "$base_ref" ]]; then
		chunk=$(git diff --name-only --diff-filter=ACMR "$base_ref"...HEAD 2>/dev/null || true)
		changed_files="$chunk"
	fi
	chunk=$(git diff --name-only --diff-filter=ACMR 2>/dev/null || true)
	[[ -n "$chunk" ]] && changed_files=$(printf '%s\n%s\n' "$changed_files" "$chunk")
	chunk=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
	[[ -n "$chunk" ]] && changed_files=$(printf '%s\n%s\n' "$changed_files" "$chunk")
	chunk=$(git ls-files --others --exclude-standard 2>/dev/null || true)
	[[ -n "$chunk" ]] && changed_files=$(printf '%s\n%s\n' "$changed_files" "$chunk")

	LINT_CHANGED_FILES=$(printf '%s\n' "$changed_files" |
		sed '/^[[:space:]]*$/d' |
		grep -Ev "$LINT_EXCLUDE_PATTERN" |
		LC_ALL=C sort -u || true)
	LINT_CHANGED_FILES_FINGERPRINT=$(_lint_changed_files_fingerprint "$LINT_CHANGED_FILES")
	LINT_CHANGED_FILES_READY=true
	export LINT_CHANGED_FILES LINT_CHANGED_FILES_FINGERPRINT LINT_CHANGED_FILES_READY
	return 0
}

lint_changed_files_matching() {
	local pattern="$1"
	if [[ "$LINT_CHANGED_FILES_READY" != "true" ]]; then
		lint_changed_files
	fi
	[[ -n "$LINT_CHANGED_FILES" ]] || return 0
	printf '%s\n' "$LINT_CHANGED_FILES" | grep -E "$pattern" || true
	return 0
}

# -----------------------------------------------------------------------------
# Find-based discovery (local mode)
# -----------------------------------------------------------------------------
# Uses find — includes .agents/scripts/setup/modules/ and setup.sh from repo root.
# Results populate bash arrays for safe iteration over paths with spaces.

LINT_SH_FILES_LOCAL=()
LINT_PY_FILES_LOCAL=()

# Populate LINT_SH_FILES_LOCAL array with shell files from .agents/scripts/
# (including setup/modules/) and setup.sh, excluding archived directories.
lint_shell_files_local() {
	LINT_SH_FILES_LOCAL=()
	while IFS= read -r -d '' f; do
		LINT_SH_FILES_LOCAL+=("$f")
	done < <(find .agents/scripts -name "*.sh" \
		-not -path "*/_archive/*" \
		-print0 2>/dev/null | sort -z)

	# Include setup.sh entry point itself
	if [[ -f "setup.sh" ]]; then
		LINT_SH_FILES_LOCAL+=("setup.sh")
	fi
	return 0
}

# Populate LINT_PY_FILES_LOCAL array with Python files from .agents/scripts/,
# excluding archived directories.
lint_python_files_local() {
	LINT_PY_FILES_LOCAL=()
	while IFS= read -r -d '' f; do
		LINT_PY_FILES_LOCAL+=("$f")
	done < <(find .agents/scripts -name "*.py" \
		-not -path "*/_archive/*" \
		-print0 2>/dev/null | sort -z)
	return 0
}
