#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# repo-layout-audit-helper.sh — non-destructive top-level repository layout audit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 2
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 2
POLICY_FILE="${REPO_ROOT}/.agents/configs/repo-layout-policy.conf"
MODE="check"
WARN_ONLY=0

usage() {
	sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
	printf '\nUsage: repo-layout-audit-helper.sh [--check] [--warn-only] [--policy FILE] [--repo DIR]\n'
	return 0
}

die() {
	local msg="$1"
	printf 'repo-layout-audit-helper.sh: ERROR: %s\n' "$msg" >&2
	exit 2
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--check)
			MODE="check"
			shift
			;;
		--warn-only)
			WARN_ONLY=1
			shift
			;;
		--policy)
			[[ $# -ge 2 ]] || die "--policy requires a file path"
			POLICY_FILE="$2"
			shift 2
			;;
		--repo)
			[[ $# -ge 2 ]] || die "--repo requires a directory path"
			REPO_ROOT="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $arg"
			;;
		esac
	done
	return 0
}

load_policy_paths() {
	local policy="$1"
	[[ -f "$policy" ]] || die "policy file not found: $policy"

	while IFS=$'\t' read -r path class rationale extra; do
		[[ -z "${path:-}" || "${path:0:1}" == "#" ]] && continue
		if [[ -z "${class:-}" || -z "${rationale:-}" || -n "${extra:-}" ]]; then
			die "invalid policy row for '$path' — expected: path<TAB>class<TAB>rationale"
		fi
		printf '%s\n' "$path"
	done <"$policy"
	return 0
}

tracked_top_level_paths() {
	local repo="$1"
	git -C "$repo" ls-files | while IFS= read -r tracked_path; do
		[[ -z "$tracked_path" ]] && continue
		printf '%s\n' "${tracked_path%%/*}"
	done | LC_ALL=C sort -u
	return 0
}

path_allowed() {
	local path="$1"
	local allowed_paths="$2"
	grep -qxF "$path" <<<"$allowed_paths"
	return $?
}

suggest_home() {
	local path="$1"
	case "$path" in
	_* )
		printf 'repo-local data planes should be documented in .agents/configs/repo-layout-policy.conf if intentional'
		;;
	*.md | *.mdx)
		printf 'docs/ or .agents/reference/ unless this is a public root entrypoint'
		;;
	*.sh)
		printf '.agents/scripts/ for framework helpers, setup-modules/ for setup internals, or root only for public entrypoints'
		;;
	*.json | *.jsonc | *.yml | *.yaml | *.toml | *.properties)
		printf '.agents/configs/ for framework policy, configs/ for user templates, or tool-specific tracked config when required at root'
		;;
	*)
		printf 'choose an existing policy class, then add a rationale to .agents/configs/repo-layout-policy.conf'
		;;
	esac
	return 0
}

run_check() {
	local allowed_paths tracked_paths unknown_count=0
	allowed_paths=$(load_policy_paths "$POLICY_FILE") || return 2
	tracked_paths=$(tracked_top_level_paths "$REPO_ROOT") || die "git ls-files failed in $REPO_ROOT"

	printf 'Repository layout audit\n'
	printf 'Policy: %s\n' "$POLICY_FILE"
	printf 'Repo: %s\n' "$REPO_ROOT"
	printf '\n'

	local path
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		if path_allowed "$path" "$allowed_paths"; then
			printf 'ALLOW\t%s\n' "$path"
		else
			unknown_count=$((unknown_count + 1))
			printf 'UNKNOWN\t%s\t%s\n' "$path" "$(suggest_home "$path")"
		fi
	done <<<"$tracked_paths"

	printf '\n'
	if [[ "$unknown_count" -eq 0 ]]; then
		print_success "Repository layout policy covers all tracked top-level paths"
		return 0
	fi

	print_warning "Repository layout policy has ${unknown_count} unknown tracked top-level path(s)"
	print_info "Add intentional paths to .agents/configs/repo-layout-policy.conf with a class and rationale; otherwise move files under an existing surface."
	if [[ "$WARN_ONLY" -eq 1 ]]; then
		return 0
	fi
	return 1
}

main() {
	parse_args "$@"
	case "$MODE" in
	check)
		run_check
		return $?
		;;
	*)
		die "unsupported mode: $MODE"
		;;
	esac
}

main "$@"
