#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Validators -- project auto-fix and typecheck execution
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh. The parent library owns
# project detection and changed-file classification; this module executes the
# selected validators and preserves the parent library's function API.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-validators.sh"
#
# Dependencies:
#   - full-loop-helper-commit.sh validator detection helpers
#   - shared-constants.sh (print_error, print_info)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED=1

_restore_validator_repo_root() {
	local repo_root="$1"
	local phase="$2"

	if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
		print_error "[validators] repository root disappeared during ${phase}: ${repo_root:-<unknown>}"
		print_error "[validators] refusing to run git amend from a missing working directory"
		return 1
	fi
	if ! cd "$repo_root" 2>/dev/null; then
		print_error "[validators] failed to restore repository root after ${phase}: $repo_root"
		return 1
	fi
	return 0
}

_validator_file_is_node_related() {
	local changed_file="$1"
	case "$changed_file" in
	package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb | \
		*.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.mts | *.cts | \
		*.eslintrc.* | eslint.config.* | tsconfig*.json | jsconfig*.json | prettier.config.* | .prettierrc*) return 0 ;;
	esac
	return 1
}

_validator_workspace_patterns() {
	jq -r '.workspaces // empty | if type == "array" then .[] elif type == "object" then (.packages // [])[] else empty end' package.json 2>/dev/null
}

_validator_workspace_matches() {
	local scope="$1"
	local workspace_patterns="$2"
	local pattern=""
	while IFS= read -r pattern; do
		# Workspace declarations are glob patterns (for example packages/*).
		# shellcheck disable=SC2053
		[[ -n "$pattern" && "$scope" == $pattern ]] && return 0
	done <<<"$workspace_patterns"
	return 1
}

_validator_all_workspace_scopes() {
	local workspace_patterns="$1"
	local manifest="" scope="" scopes=""
	while IFS= read -r manifest; do
		[[ "$manifest" == "package.json" ]] && continue
		scope=${manifest%/package.json}
		_validator_workspace_matches "$scope" "$workspace_patterns" || continue
		case $'\n'"$scopes"$'\n' in
		*$'\n'"$scope"$'\n'*) ;;
		*) scopes="${scopes}${scopes:+$'\n'}${scope}" ;;
		esac
	done < <(git ls-files '*package.json')
	if _validator_package_has_check package.json; then
		scopes=".${scopes:+$'\n'}${scopes}"
	fi
	if [[ -z "$scopes" ]]; then
		print_error "[validators] root/shared change requires broader checks, but no check-only workspace scripts are available"
		return 1
	fi
	printf '%s\n' "$scopes"
	return 0
}

# Print the package roots that own Node-related files in the complete PR range.
# A root/shared change intentionally selects the root package and broader checks.
_validator_scopes() {
	local changed_files="" workspace_patterns="" changed_file=""
	local scope=""
	changed_files=$(_validator_changed_files) || return 1
	workspace_patterns=$(_validator_workspace_patterns)
	if [[ -z "$workspace_patterns" ]]; then
		printf '.\n'
		return 0
	fi
	local scopes=""
	while IFS= read -r changed_file; do
		_validator_file_is_node_related "$changed_file" || continue
		scope=${changed_file%/*}
		[[ "$scope" == "$changed_file" ]] && scope="."
		while [[ "$scope" != "." && ! -f "$scope/package.json" ]]; do
			if [[ "$scope" == */* ]]; then
				scope=${scope%/*}
			else
				scope="."
			fi
		done
		if [[ "$scope" == "." ]]; then
			_validator_all_workspace_scopes "$workspace_patterns"
			return $?
		fi
		if ! _validator_workspace_matches "$scope" "$workspace_patterns" && ! _validator_package_has_check "$scope/package.json"; then
			print_error "[validators] cannot map changed Node file to a declared workspace: $changed_file"
			print_error "[validators] add a package-level check script or correct package.json workspaces before publication"
			return 1
		fi
		case $'\n'"$scopes"$'\n' in
		*$'\n'"$scope"$'\n'*) ;;
		*) scopes="${scopes}${scopes:+$'\n'}${scope}" ;;
		esac
	done <<<"$changed_files"
	[[ -n "$scopes" ]] || return 1
	printf '%s\n' "$scopes"
	return 0
}

_validator_select_script() {
	local package_json="$1" phase="$2" script_name=""
	local candidates=""
	case "$phase" in
	format) candidates=$'format:check\ncheck:format\nprettier:check' ;;
	lint) candidates=$'lint:check\nlint' ;;
	typecheck) candidates=$'typecheck\ncheck:types\ntsc' ;;
	test) candidates='test' ;;
	esac
	while IFS= read -r script_name; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' "$package_json" >/dev/null 2>&1; then
			printf '%s\n' "$script_name"
			return 0
		fi
	done <<<"$candidates"
	return 1
}

_validator_package_has_check() {
	local package_json="$1" phase=""
	for phase in format lint typecheck test; do
		_validator_select_script "$package_json" "$phase" >/dev/null && return 0
	done
	return 1
}

_validator_snapshot() {
	local prefix="$1"
	git diff --binary --no-ext-diff >"${prefix}.worktree" || return 1
	git diff --cached --binary --no-ext-diff >"${prefix}.index" || return 1
	return 0
}

_validator_state_unchanged() {
	local before="$1" after="$2" command_label="$3"
	if cmp -s "${before}.worktree" "${after}.worktree" && cmp -s "${before}.index" "${after}.index"; then
		return 0
	fi
	print_error "[validators] check-only command modified tracked files or index state: $command_label"
	print_error "[validators] changes were preserved but will not be staged or amended; inspect git status and configure a non-mutating check"
	git status --short >&2
	return 1
}

_run_scoped_node_checks() {
	local pm="$1" scope="$2" t="$3" snapshot_dir="$4"
	local package_json="package.json" scope_label="repository root"
	if [[ "$scope" != "." ]]; then
		package_json="$scope/package.json"
		scope_label="$scope"
	fi
	local phase="" script_name="" check_count=0 command_rc=0 check_index=0
	for phase in format lint typecheck test; do
		script_name=$(_validator_select_script "$package_json" "$phase") || continue
		check_count=$((check_count + 1))
		check_index=$((check_index + 1))
		print_info "[validators] scope=${scope_label} reason=$([[ "$scope" == "." ]] && printf 'root-or-shared-change' || printf 'affected-workspace') command=$pm run $script_name"
		_validator_snapshot "${snapshot_dir}/before-${check_index}" || return 1
		command_rc=0
		(
			cd "$scope" || exit 1
			timeout_sec "$t" "$pm" run "$script_name"
		) >"${snapshot_dir}/command-${check_index}.log" 2>&1 || command_rc=$?
		_restore_validator_repo_root "$(git rev-parse --show-toplevel 2>/dev/null)" "$script_name" || return 1
		_validator_snapshot "${snapshot_dir}/after-${check_index}" || return 1
		_validator_state_unchanged "${snapshot_dir}/before-${check_index}" "${snapshot_dir}/after-${check_index}" "$pm run $script_name ($scope_label)" || return 1
		if [[ "$command_rc" -eq 124 ]]; then
			print_error "[validators] TIMEOUT after ${t}s: $pm run $script_name ($scope_label)"
			return 1
		elif [[ "$command_rc" -ne 0 ]]; then
			print_error "[validators] CHECK FAILED (exit ${command_rc}): $pm run $script_name ($scope_label)"
			tail -20 "${snapshot_dir}/command-${check_index}.log" >&2
			return 1
		fi
	done
	if [[ "$check_count" -eq 0 ]]; then
		print_error "[validators] NO SCOPED CHECKS AVAILABLE for ${scope_label}"
		print_error "[validators] configure lint, typecheck, or a check-only format script in ${package_json}"
		return 1
	fi
	return 0
}

# Orchestrator. Args: $1=skip_hooks (0|1). Returns 0 on pass/skip, 1 on fail.
_run_project_validators() {
	local skip_hooks="${1:-0}"
	# _validators_should_run returns 0 when validators should run, 1 otherwise.
	if ! _validators_should_run "$skip_hooks"; then
		return 0
	fi
	if ! _commit_touches_node_files; then
		print_info "[validators] no Node/TypeScript files changed, skipping node project validators"
		return 0
	fi
	local pm=""
	if ! _detect_node_project; then
		# Silent skip when no project detected (non-node project = most aidevops paths).
		return 0
	fi
	print_info "[validators] running node project validators ($pm)..."
	local validator_timeout
	validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT:-300}"
	if ! [[ "$validator_timeout" =~ ^[1-9][0-9]*$ ]]; then
		print_error "[validators] AIDEVOPS_VALIDATOR_TIMEOUT must be a positive integer"
		return 1
	fi
	if ! command -v "$pm" >/dev/null 2>&1; then
		print_error "[validators] REQUIRED COMMAND UNAVAILABLE: $pm"
		return 1
	fi
	local scopes="" snapshot_dir=""
	local scope=""
	scopes=$(_validator_scopes) || return 1
	snapshot_dir=$(mktemp -d) || return 1
	while IFS= read -r scope; do
		[[ -n "$scope" ]] || continue
		_run_scoped_node_checks "$pm" "$scope" "$validator_timeout" "$snapshot_dir" || {
			rm -rf "$snapshot_dir"
			return 1
		}
	done <<<"$scopes"
	rm -rf "$snapshot_dir"
	print_info "[validators] passed (check-only scope: ${scopes//$'\n'/, })"
	return 0
}
