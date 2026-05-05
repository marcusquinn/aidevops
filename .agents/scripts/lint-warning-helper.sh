#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# lint-warning-helper.sh — Detect actionable lint warnings after successful runs
# =============================================================================
#
# Some JavaScript/TypeScript lint commands exit 0 while still emitting ESLint
# warnings. For React stacks, warnings such as react-hooks/exhaustive-deps are
# correctness-relevant and should be treated as actionable verification output.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh"

usage() {
	printf 'Usage:\n'
	printf '  %s analyze <lint-output-file> [project-dir]\n' "${0##*/}"
	printf '  %s run [--project-dir DIR] -- <lint command> [args...]\n' "${0##*/}"
	return 0
}

project_has_react_typescript_stack() {
	local project_dir="$1"
	local package_file="${project_dir%/}/package.json"

	if [[ -f "$package_file" ]] && grep -Eq '"(react|next|@vitejs/plugin-react|typescript)"[[:space:]]*:' "$package_file" 2>/dev/null; then
		return 0
	fi

	if command -v git >/dev/null 2>&1 && git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if git -C "$project_dir" ls-files '*.tsx' '*.ts' 2>/dev/null | grep -q .; then
			return 0
		fi
	fi

	return 1
}

lint_output_has_actionable_eslint_warning() {
	local output_file="$1"
	local project_dir="$2"

	# React Hooks dependency warnings are always actionable: fixing them prevents
	# stale closures and accidental collaboration/state regressions.
	if grep -Eq 'warning[[:space:]].*react-hooks/exhaustive-deps' "$output_file" 2>/dev/null; then
		return 0
	fi

	# In React/TypeScript stacks, typed ESLint warnings are usually intentional
	# quality gates even when the command exits 0.
	if project_has_react_typescript_stack "$project_dir" && \
		grep -Eq 'warning[[:space:]].*(@typescript-eslint/|react-hooks/|jsx-a11y/)' "$output_file" 2>/dev/null; then
		return 0
	fi

	return 1
}

analyze_lint_output() {
	local output_file="$1"
	local project_dir="${2:-$PWD}"

	if [[ ! -f "$output_file" ]]; then
		printf 'ERROR: lint output file not found: %s\n' "$output_file" >&2
		return 1
	fi

	if lint_output_has_actionable_eslint_warning "$output_file" "$project_dir"; then
		printf 'ACTIONABLE_LINT_WARNINGS: ESLint warning output requires follow-up despite a successful lint exit.\n' >&2
		printf 'Use an ESLint-compatible zero-warning gate when supported, e.g. lint -- --max-warnings=0, or fix/create a tracked task for the warning.\n' >&2
		grep -En 'warning[[:space:]].*(react-hooks/|@typescript-eslint/|jsx-a11y/)' "$output_file" 2>/dev/null >&2 || true
		return 2
	fi

	printf 'LINT_WARNINGS_CLEAN: no actionable React/TypeScript ESLint warnings detected.\n'
	return 0
}

run_lint_command() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local project_dir="$PWD"
	local current_arg=""
	local next_arg=""

	while [[ $# -gt 0 ]]; do
		current_arg="${1:-}"
		case "$current_arg" in
		--project-dir)
			if [[ $# -lt 2 ]]; then
				usage >&2
				return 1
			fi
			next_arg="${2:-}"
			project_dir="$next_arg"
			shift 2
			;;
		--)
			shift
			break
			;;
		*)
			break
			;;
		esac
	done

	if [[ $# -eq 0 ]]; then
		usage >&2
		return 1
	fi

	local output_file
	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-lint-output.XXXXXX") || return 1
	push_cleanup "rm -f '${output_file}'"

	local lint_rc=0
	"$@" >"$output_file" 2>&1 || lint_rc=$?
	cat "$output_file"

	if [[ $lint_rc -ne 0 ]]; then
		rm -f "$output_file"
		return "$lint_rc"
	fi

	analyze_lint_output "$output_file" "$project_dir"
	local analyze_rc=$?
	rm -f "$output_file"
	return "$analyze_rc"
}

main() {
	local command="${1:-}"
	local output_arg=""
	local project_arg=""
	case "$command" in
	analyze)
		shift
		output_arg="${1:-}"
		project_arg="${2:-$PWD}"
		analyze_lint_output "$output_arg" "$project_arg"
		return $?
		;;
	run)
		shift
		run_lint_command "$@"
		return $?
		;;
	-h | --help | help | '')
		usage
		return 0
		;;
	*)
		usage >&2
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
