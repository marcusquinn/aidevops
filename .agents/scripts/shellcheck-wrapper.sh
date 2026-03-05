#!/usr/bin/env bash
# Safe ShellCheck wrapper for language servers (shellcheck-wrapper.sh)
#
# The bash language server hardcodes --external-sources in every ShellCheck
# invocation (bash-language-server/out/shellcheck/index.js:82). Even though
# source-path=SCRIPTDIR has been removed from .shellcheckrc (and SC1091 is
# now globally disabled), this wrapper remains as defense-in-depth: it strips
# --external-sources to prevent any residual source-following expansion.
#
# This wrapper strips --external-sources from the arguments before passing them
# to the real ShellCheck binary. It also enforces a memory limit via ulimit.
#
# Usage:
#   Set SHELLCHECK_PATH to this script's path, or place it earlier on PATH as
#   "shellcheck". The bash language server will use it instead of the real binary.
#
#   Environment variables:
#     SHELLCHECK_REAL_PATH  — Path to the real shellcheck binary (auto-detected)
#     SHELLCHECK_VMEM_MB    — Virtual memory limit in MB (default: 2048)
#
# GH#2915: https://github.com/marcusquinn/aidevops/issues/2915

set -uo pipefail

# --- Find the real ShellCheck binary ---
_find_real_shellcheck() {
	local real_path="${SHELLCHECK_REAL_PATH:-}"

	if [[ -n "$real_path" && -x "$real_path" ]]; then
		printf '%s' "$real_path"
		return 0
	fi

	# Search PATH, skipping this wrapper script
	local self
	self="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

	local dir
	while IFS= read -r -d ':' dir || [[ -n "$dir" ]]; do
		local candidate="${dir}/shellcheck"
		if [[ -x "$candidate" ]]; then
			local resolved
			resolved="$(realpath "$candidate" 2>/dev/null || readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
			if [[ "$resolved" != "$self" ]]; then
				printf '%s' "$candidate"
				return 0
			fi
		fi
	done <<<"$PATH"

	# Common locations
	local loc
	for loc in /opt/homebrew/bin/shellcheck /usr/local/bin/shellcheck /usr/bin/shellcheck; do
		if [[ -x "$loc" ]]; then
			local resolved
			resolved="$(realpath "$loc" 2>/dev/null || readlink -f "$loc" 2>/dev/null || echo "$loc")"
			if [[ "$resolved" != "$self" ]]; then
				printf '%s' "$loc"
				return 0
			fi
		fi
	done

	echo "shellcheck-wrapper: ERROR: cannot find real shellcheck binary" >&2
	return 1
}

# --- Filter arguments ---
_filter_args() {
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--external-sources | -x)
			# Strip this flag — it causes unbounded source chain expansion
			;;
		*)
			args+=("$1")
			;;
		esac
		shift
	done
	printf '%s\n' "${args[@]}"
}

# --- Main ---
main() {
	local real_shellcheck
	real_shellcheck="$(_find_real_shellcheck)" || exit 1

	# Read filtered args into array
	local filtered_args=()
	while IFS= read -r arg; do
		filtered_args+=("$arg")
	done < <(_filter_args "$@")

	# Enforce memory limit (soft limit — ShellCheck can still be killed by the
	# memory pressure monitor if it exceeds this, but this prevents the worst case)
	local vmem_mb="${SHELLCHECK_VMEM_MB:-2048}"
	local vmem_kb=$((vmem_mb * 1024))
	ulimit -v "$vmem_kb" 2>/dev/null || true

	exec "$real_shellcheck" "${filtered_args[@]}"
}

main "$@"
