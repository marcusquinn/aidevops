#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SETUP_SCRIPT="$REPO_ROOT/setup.sh"
RELEASE_LIB="$REPO_ROOT/.agents/scripts/version-manager-release.sh"

line_for() {
	local pattern="$1"
	local file="$2"
	grep -n "$pattern" "$file" | cut -d: -f1
	return 0
}

main() {
	local acquire_line=""
	local dispatch_line=""
	local noninteractive_function_line=""
	local deploy_line=""
	local converge_line=""
	local exit_trap_line=""
	# shellcheck disable=SC2016 # Match the literal release-library command.
	local full_deploy_pattern='bash "$deploy_script" --repo "$sync_repo_root" --full --quiet'

	acquire_line=$(line_for '_setup_acquire_noninteractive_setup_lock "$@"' "$SETUP_SCRIPT")
	dispatch_line=$(line_for '^[[:space:]]*_setup_run_non_interactive$' "$SETUP_SCRIPT" | while IFS= read -r line_number; do
		[[ "$line_number" -gt "$acquire_line" ]] && printf '%s\n' "$line_number" && break
	done)
	noninteractive_function_line=$(line_for '^_setup_run_non_interactive()' "$SETUP_SCRIPT")
	# shellcheck disable=SC2016 # Match literal source expressions.
	deploy_line=$(line_for '_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents' "$SETUP_SCRIPT" | while IFS= read -r line_number; do
		[[ "$line_number" -gt "$noninteractive_function_line" ]] && printf '%s\n' "$line_number" && break
	done)
	converge_line=$(line_for '_time_step "install_aidevops_cli" install_aidevops_cli' "$SETUP_SCRIPT" | while IFS= read -r line_number; do
		[[ "$line_number" -gt "$deploy_line" ]] && printf '%s\n' "$line_number" && break
	done)
	exit_trap_line=$(line_for "trap '_setup_cleanup_noninteractive_children; _setup_release_noninteractive_setup_lock' EXIT" "$SETUP_SCRIPT")

	if [[ -n "$exit_trap_line" && "$exit_trap_line" -lt "$acquire_line" &&
		"$acquire_line" -lt "$dispatch_line" && "$deploy_line" -lt "$converge_line" ]] &&
		grep -q "$full_deploy_pattern" "$RELEASE_LIB"; then
		printf 'PASS full-loop setup mutex covers agent deployment through CLI convergence\n'
		return 0
	fi

	printf 'FAIL setup mutex contract: trap=%s acquire=%s dispatch=%s deploy=%s converge=%s\n' \
		"$exit_trap_line" "$acquire_line" "$dispatch_line" "$deploy_line" "$converge_line" >&2
	return 1
}

main "$@"
