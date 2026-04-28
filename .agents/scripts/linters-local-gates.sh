#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Linters — Bundle-Aware Gate Filtering Sub-Library
# =============================================================================
# Gate orchestration extracted from linters-local.sh (GH#21418).
# Resolves the project bundle and dispatches all quality gates in order,
# honouring bundle skip_gates overrides.
#
# Usage: source "${SCRIPT_DIR}/linters-local-gates.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - All check_* functions defined in linters-local.sh and its other sub-libraries
#   - bundle-helper.sh (optional — missing bundle is not an error)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_GATES_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_GATES_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Bundle-Aware Gate Filtering (t1364.6)
# =============================================================================
# Resolves the project bundle and checks whether a gate should be skipped.
# Bundle skip_gates override: if a bundle says skip a gate, it's skipped.
# BUNDLE_SKIP_GATES is populated once in main() and checked per gate.

BUNDLE_SKIP_GATES=""

# Load bundle skip_gates for the current project directory.
# Populates BUNDLE_SKIP_GATES (newline-separated gate names).
# Returns: 0 always (bundle is optional — missing bundle is not an error)
load_bundle_gates() {
	local bundle_helper="${SCRIPT_DIR}/bundle-helper.sh"
	if [[ ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local bundle_json
	bundle_json=$("$bundle_helper" resolve "." 2>/dev/null) || true
	if [[ -z "$bundle_json" ]]; then
		return 0
	fi

	BUNDLE_SKIP_GATES=$(echo "$bundle_json" | jq -r '.skip_gates[]? // empty' 2>/dev/null) || true

	local bundle_name
	bundle_name=$(echo "$bundle_json" | jq -r '.name // "unknown"' 2>/dev/null) || true
	if [[ -n "$BUNDLE_SKIP_GATES" ]]; then
		local skip_count
		skip_count=$(echo "$BUNDLE_SKIP_GATES" | wc -l | tr -d ' ')
		print_info "Bundle '${bundle_name}': skipping ${skip_count} gates"
	else
		print_info "Bundle '${bundle_name}': no gates skipped"
	fi
	return 0
}

# Check if a gate should be skipped based on bundle config.
# Arguments:
#   $1 - gate name (e.g., "shellcheck", "return-statements")
# Returns: 0 if gate should be SKIPPED, 1 if gate should RUN
should_skip_gate() {
	local gate_name="$1"
	if [[ -z "$BUNDLE_SKIP_GATES" ]]; then
		return 1
	fi
	if echo "$BUNDLE_SKIP_GATES" | grep -qxF "$gate_name"; then
		print_info "Skipping '${gate_name}' (bundle skip_gates)"
		return 0
	fi
	return 1
}

# _run_gate_checks_static: run static analysis gates (sonarcloud through secret-policy).
# Returns: 0 if all passed, 1 if any failed.
_run_gate_checks_static() {
	local exit_code=0

	if ! should_skip_gate "sonarcloud"; then
		check_sonarcloud_status || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "qlty"; then
		check_qlty_maintainability || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "return-statements"; then
		check_return_statements || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "positional-parameters"; then
		check_positional_parameters || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "string-literals"; then
		check_string_literals || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "forbidden-exec-fd"; then
		check_forbidden_exec_fd || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shfmt"; then
		run_shfmt
		echo ""
	fi

	if ! should_skip_gate "shellcheck"; then
		run_shellcheck || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shellcheckrc-parity"; then
		check_shellcheckrc_parity || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "secretlint"; then
		check_secrets || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "markdownlint"; then
		check_markdown_lint || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "toon-syntax"; then
		check_toon_syntax || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "skill-frontmatter"; then
		check_skill_frontmatter || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "secret-policy"; then
		check_secret_policy || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "pulse-canary"; then
		check_pulse_canary || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "ratchets"; then
		check_ratchets || exit_code=1
		echo ""
	fi

	return $exit_code
}

check_shell_portability() {
	echo -e "${BLUE}Checking Shell Portability (Linux/macOS command portability)...${NC}"

	local scanner_script="${SCRIPT_DIR}/lint-shell-portability.sh"
	if [[ ! -x "$scanner_script" ]]; then
		print_warning "lint-shell-portability.sh not found at $scanner_script"
		return 0
	fi

	local output violations=0
	output=$(bash "$scanner_script" --summary 2>&1) || violations=1

	if [[ "$violations" -eq 0 ]]; then
		print_success "Shell portability: no unguarded platform-specific commands"
	else
		print_error "Shell portability: unguarded platform-specific commands found"
		# Re-run without --summary to show details
		bash "$scanner_script" 2>&1 || true
		return 1
	fi

	return 0
}

# _run_gate_checks_complexity: run complexity and compatibility gates (bash32 through python).
# Returns: 0 if all passed, 1 if any failed.
_run_gate_checks_complexity() {
	local exit_code=0

	if ! should_skip_gate "bash32-compat"; then
		check_bash32_compat || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shell-portability"; then
		check_shell_portability || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "function-complexity"; then
		check_function_complexity || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "nesting-depth"; then
		check_nesting_depth || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "file-size"; then
		check_file_size || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "python-complexity"; then
		check_python_complexity || exit_code=1
		echo ""
	fi

	return $exit_code
}

# Run all gate checks in order, respecting bundle skip_gates.
# Returns: 0 if all gates passed, 1 if any gate failed.
_run_gate_checks() {
	local exit_code=0

	_run_gate_checks_static || exit_code=1
	_run_gate_checks_complexity || exit_code=1

	return $exit_code
}
