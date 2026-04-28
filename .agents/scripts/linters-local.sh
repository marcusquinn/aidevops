#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2086
# =============================================================================
# Local Linters - Fast Offline Quality Checks (Orchestrator)
# =============================================================================
# Thin orchestrator that sources sub-libraries and runs all quality gates.
# Split from a monolithic 1567-line file into focused modules (GH#21296).
#
# Sub-libraries:
#   - linters-local-validators.sh — pattern validation, shell linting, secrets
#   - linters-local-analysis.sh   — complexity, formatting, misc checks
#   - linters-local-gates.sh      — bundle-aware gate filtering / dispatch
#   - linters-local-ratchet.sh    — anti-pattern regression ratchets
#
# Checks performed (via sub-libraries):
#   - ShellCheck for shell scripts
#   - Secretlint for exposed secrets
#   - Pattern validation (return statements, positional parameters)
#   - Markdown formatting
#   - Skill frontmatter validation (name field matches skill-sources.json)
#   - Ratchet quality checks (anti-pattern regression prevention)
#   - Function complexity, nesting depth, file size
#   - Bash 3.2 compatibility
#   - Pulse wrapper canary
#
# For remote auditing (CodeRabbit, Codacy, SonarCloud), use:
#   /code-audit-remote or code-audit-helper.sh
#
# Ratchet flags:
#   --update-baseline   Re-count all patterns and write new ratchets.json baseline
#   --init-baseline     Same as --update-baseline (alias for first-time setup)
#   --strict            Make ratchet failures blocking (default: advisory)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/lint-file-discovery.sh"
# shellcheck source=./linters-local-ratchet.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-ratchet.sh"
# shellcheck source=./linters-local-validators.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-validators.sh"
# shellcheck source=./linters-local-analysis.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-analysis.sh"
# shellcheck source=./linters-local-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-gates.sh"

set -euo pipefail

# Color codes for output

# Quality thresholds
# Note: These thresholds are set to allow existing code patterns while catching regressions
# - Return issues: Simple utility functions (log_*, print_*) don't need explicit returns
# - Positional params: Using $1/$2 in case statements and argument parsing is valid
#   SonarCloud S7679 reports ~200 issues; local check is more aggressive (~280)
#   Threshold set to catch regressions while allowing existing patterns
# - String literals: Code duplication is a style issue, not a bug
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=10
readonly MAX_POSITIONAL_ISSUES=300
readonly MAX_STRING_LITERAL_ISSUES=2300

# Complexity thresholds (aligned with Codacy defaults — GH#4939)
# These catch the same issues Codacy flags so they're caught locally before push.
# Thresholds are set above the current baseline to catch regressions, not existing debt.
# Existing debt is tracked by the code-simplifier (priority 8, human-gated).
#
# Baseline (2026-03-16): 404 functions >100 lines, 245 files >8 nesting, 33 files >1500 lines
# These thresholds allow the current baseline but block significant new additions.
# Reduce thresholds as existing debt is paid down.
#
# - Function length: warn >50, block >100. Threshold allows current 404 + small margin.
# - Nesting depth: warn >5, block >8. Threshold allows current 245 + small margin.
# - File size: warn >800, block >1500. Gate is now ratchet-based (t2938) —
#   MAX_FILE_SIZE_VIOLATIONS removed; ratchet compares against origin/main HEAD.
readonly MAX_FUNCTION_LENGTH_WARN=50
readonly MAX_FUNCTION_LENGTH_BLOCK=100
readonly MAX_FUNCTION_LENGTH_VIOLATIONS=420
readonly MAX_NESTING_DEPTH_WARN=5
readonly MAX_NESTING_DEPTH_BLOCK=8
readonly MAX_NESTING_VIOLATIONS=260
readonly MAX_FILE_LINES_WARN=800
readonly MAX_FILE_LINES_BLOCK=1500

print_header() {
	echo -e "${BLUE}Local Linters - Fast Offline Quality Checks${NC}"
	echo -e "${BLUE}================================================================${NC}"
	return 0
}

# Collect all shell scripts to lint via shared file-discovery helper.
# Exclusion policy is centralised in lint-file-discovery.sh (single source of
# truth shared with CI). Populates ALL_SH_FILES array for check functions.
collect_shell_files() {
	lint_shell_files_local
	ALL_SH_FILES=("${LINT_SH_FILES_LOCAL[@]}")
	return 0
}

main() {
	# Parse ratchet flags before running checks
	local arg
	for arg in "$@"; do
		case "$arg" in
		--update-baseline | --init-baseline)
			export RATCHET_UPDATE_BASELINE=true
			;;
		--strict)
			export RATCHET_STRICT=true
			;;
		--dry-run)
			export RATCHET_DRY_RUN=true
			;;
		esac
	done

	print_header

	# Collect shell files once (includes modularised subdirectories, excludes _archive/)
	collect_shell_files

	# Load bundle config for gate filtering (t1364.6)
	load_bundle_gates

	# If --update-baseline, run only the ratchet check (which handles baseline update)
	if [[ "${RATCHET_UPDATE_BASELINE:-false}" == "true" ]]; then
		check_ratchets
		return $?
	fi

	# Run all local quality checks (respecting bundle skip_gates)
	local exit_code=0
	_run_gate_checks || exit_code=1

	check_remote_cli_status
	echo ""

	# Final summary
	if [[ $exit_code -eq 0 ]]; then
		print_success "ALL LOCAL CHECKS PASSED!"
		print_info "For remote auditing, run: /code-audit-remote"
	else
		print_error "QUALITY ISSUES DETECTED. Please address violations before committing."
	fi

	return $exit_code
}

main "$@"
