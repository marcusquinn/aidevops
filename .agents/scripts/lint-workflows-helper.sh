#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# lint-workflows-helper.sh — validate .github/workflows/*.yml files.
#
# Issue: GH#20489
# Background: A one-extra-leading-space regression in maintainer-gate.yml
# (t2691 / PR #20311) caused silent YAML parse failures that broke the
# Maintainer Review & Assignee Gate framework-wide for ~24 hours.
#
# Usage (standalone):
#   lint-workflows-helper.sh [--staged] [FILE...]
#
#   --staged   lint only files staged for the current git commit
#   FILE...    explicit files to lint (default: all .github/workflows/*.yml)
#
# Exit codes:
#   0 — all checked files are valid
#   1 — one or more files have errors
#   2 — no workflow files found / nothing to check (treated as pass)
#
# Tool priority (first found wins):
#   1. actionlint   — full semantic + YAML validation
#   2. yamllint     — YAML-only structural validation
#   3. python3 yaml — bare YAML parse (lowest fidelity, always available)
#
# Bypass: git commit --no-verify  (standard pre-commit convention)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	# Colour fallbacks when sourced in isolation (e.g. direct CLI invocation
	# before shared-constants.sh has been deployed alongside).
	[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
	[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
	[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
	[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
	[[ -z "${NC+x}" ]]     && NC='\033[0m'

	print_error()   { printf '%b[workflow-lint-error]%b %s\n' "${RED}"    "${NC}" "$*" >&2; return 0; }
	print_warning() { printf '%b[workflow-lint-warn]%b  %s\n' "${YELLOW}" "${NC}" "$*" >&2; return 0; }
	print_info()    { printf '%b[workflow-lint]%b %s\n'        "${BLUE}"   "${NC}" "$*" >&2; return 0; }
	print_success() { printf '%b[workflow-lint]%b %s\n'        "${GREEN}"  "${NC}" "$*" >&2; return 0; }
fi

# ---------------------------------------------------------------------------
# Tool detection (cached in variables, evaluated once at startup)
# ---------------------------------------------------------------------------
_LINT_TOOL=""
_LINT_TOOL_VERSION=""

_detect_lint_tool() {
	if command -v actionlint &>/dev/null; then
		_LINT_TOOL="actionlint"
		_LINT_TOOL_VERSION=$(actionlint --version 2>/dev/null || echo "unknown")
	elif command -v yamllint &>/dev/null; then
		_LINT_TOOL="yamllint"
		_LINT_TOOL_VERSION=$(yamllint --version 2>/dev/null || echo "unknown")
	elif python3 -c "import yaml" &>/dev/null; then
		_LINT_TOOL="python3-yaml"
		_LINT_TOOL_VERSION=$(python3 --version 2>/dev/null || echo "unknown")
	else
		_LINT_TOOL="none"
		_LINT_TOOL_VERSION="n/a"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Per-file linters
# ---------------------------------------------------------------------------

# Run actionlint on a single file.
# Output: actionlint findings on stderr, exit 1 on error.
_lint_with_actionlint() {
	local file="$1"
	# actionlint -format wraps output cleanly; no -oneline needed for file:line.
	# We run with shellcheck disabled to avoid false positives from inline shell
	# expressions in workflow run: blocks — those are validated by shellcheck
	# separately via pre-commit-hook.sh.
	actionlint -shellcheck="" "$file" 2>&1
	return $?
}

# Run yamllint on a single file.
# Output: yamllint findings on stderr, exit 1 on error.
_lint_with_yamllint() {
	local file="$1"
	# -d relaxed: GitHub Actions files intentionally use long lines, missing
	# document-start markers, etc. We only want structural errors.
	yamllint -d "{extends: relaxed, rules: {line-length: disable, document-start: disable}}" "$file" 2>&1
	return $?
}

# Run python3 yaml.safe_load on a single file (bare parse-error detection).
# Output: parse errors on stderr, exit 1 on error.
_lint_with_python_yaml() {
	local file="$1"
	python3 -c "
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f'{sys.argv[1]}: YAML parse error: {e}', file=sys.stderr)
    sys.exit(1)
" "$file" 2>&1
	return $?
}

# ---------------------------------------------------------------------------
# Core lint dispatcher
# ---------------------------------------------------------------------------

# Lint a single workflow file with the best available tool.
# Returns: 0=valid, 1=errors found
_lint_file() {
	local file="$1"
	local exit_code=0

	case "$_LINT_TOOL" in
	actionlint)
		if ! _lint_with_actionlint "$file"; then
			exit_code=1
		fi
		;;
	yamllint)
		if ! _lint_with_yamllint "$file"; then
			exit_code=1
		fi
		;;
	python3-yaml)
		if ! _lint_with_python_yaml "$file"; then
			exit_code=1
		fi
		;;
	none)
		# No tool available — warn and pass (degrade gracefully).
		print_warning "No workflow linter available (actionlint/yamllint/python3-yaml)."
		print_warning "Install actionlint for full validation: brew install actionlint"
		return 0
		;;
	esac

	return $exit_code
}

# ---------------------------------------------------------------------------
# File collection helpers
# ---------------------------------------------------------------------------

# Collect staged .github/workflows/*.yml files from git index.
_get_staged_workflow_files() {
	git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
		| grep -E '^\.github/workflows/[^/]+\.ya?ml$' \
		|| true
	return 0
}

# Collect all .github/workflows/*.yml files in the repo.
_get_all_workflow_files() {
	git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null \
		|| find .github/workflows -maxdepth 1 -name '*.yml' -o -name '*.yaml' 2>/dev/null \
		|| true
	return 0
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# lint_workflows [--staged] [FILE...]
#
# Main entry point. Returns 0 on success, 1 on lint failures.
lint_workflows() {
	local staged_only=0
	local explicit_files=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--staged)
			staged_only=1
			shift
			;;
		--)
			shift
			explicit_files+=("$@")
			break
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			explicit_files+=("$1")
			shift
			;;
		esac
	done

	_detect_lint_tool

	# Determine file list
	local files_to_lint=()
	if [[ ${#explicit_files[@]} -gt 0 ]]; then
		files_to_lint=("${explicit_files[@]}")
	elif [[ "$staged_only" -eq 1 ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && files_to_lint+=("$f")
		done < <(_get_staged_workflow_files)
	else
		while IFS= read -r f; do
			[[ -n "$f" ]] && files_to_lint+=("$f")
		done < <(_get_all_workflow_files)
	fi

	if [[ ${#files_to_lint[@]} -eq 0 ]]; then
		# Nothing to check — not an error
		return 0
	fi

	print_info "Linting ${#files_to_lint[@]} workflow file(s) with $_LINT_TOOL..."

	local total_errors=0
	local failed_files=()

	for wf_file in "${files_to_lint[@]}"; do
		if [[ ! -f "$wf_file" ]]; then
			print_warning "Skipping missing file: $wf_file"
			continue
		fi

		local lint_output exit_val
		exit_val=0
		lint_output=$(_lint_file "$wf_file" 2>&1) || exit_val=$?

		if [[ $exit_val -ne 0 ]]; then
			print_error "Workflow lint FAILED: $wf_file"
			# Re-emit the linter output with context prefix
			while IFS= read -r line; do
				[[ -n "$line" ]] && printf '  %s\n' "$line" >&2
			done <<< "$lint_output"
			failed_files+=("$wf_file")
			((++total_errors))
		fi
	done

	if [[ $total_errors -eq 0 ]]; then
		print_success "All ${#files_to_lint[@]} workflow file(s) are valid."
		return 0
	fi

	print_error ""
	print_error "$total_errors workflow file(s) failed linting:"
	for f in "${failed_files[@]}"; do
		print_error "  - $f"
	done
	print_error ""
	print_error "Fix the YAML errors before committing."
	print_error "Use 'git commit --no-verify' to bypass (not recommended)."
	return 1
}

# ---------------------------------------------------------------------------
# CLI entry point (when invoked directly, not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	lint_workflows "$@"
fi
