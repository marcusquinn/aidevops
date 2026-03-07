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
# to the real ShellCheck binary. It also enforces a memory limit via ulimit,
# limits concurrent shellcheck processes, and debounces repeated checks on
# unchanged files.
#
# Usage:
#   Set SHELLCHECK_PATH to this script's path, or place it earlier on PATH as
#   "shellcheck". The bash language server will use it instead of the real binary.
#
#   Environment variables:
#     SHELLCHECK_REAL_PATH    — Path to the real shellcheck binary (auto-detected)
#     SHELLCHECK_VMEM_MB      — Virtual memory limit in MB (default: 2048)
#     SHELLCHECK_MAX_PARALLEL — Max concurrent shellcheck processes (default: nproc)
#     SHELLCHECK_DEBOUNCE_SEC — Skip re-check if file unchanged within N sec (default: 10)
#
# GH#2915: https://github.com/marcusquinn/aidevops/issues/2915

set -uo pipefail

# --- Configuration ---
# Auto-detect CPU count: use all cores by default (shellcheck uses ~1.7MB RSS
# per process with --external-sources stripped, so RAM is not a constraint).
# Override with SHELLCHECK_MAX_PARALLEL=N for constrained environments.
_SC_DEFAULT_PARALLEL=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
_SC_MAX_PARALLEL="${SHELLCHECK_MAX_PARALLEL:-$_SC_DEFAULT_PARALLEL}"
_SC_DEBOUNCE_SEC="${SHELLCHECK_DEBOUNCE_SEC:-10}"
_SC_CACHE_DIR="/tmp/shellcheck-wrapper-cache"
_SC_LOCK_DIR="/tmp/shellcheck-wrapper-locks"

# --- Find the real ShellCheck binary ---
_find_real_shellcheck() {
	local real_path="${SHELLCHECK_REAL_PATH:-}"

	if [[ -n "$real_path" && -x "$real_path" ]]; then
		printf '%s' "$real_path"
		return 0
	fi

	# Fast path: check .real sibling of this script's location first.
	# When setup.sh replaces the binary, it moves it to shellcheck.real.
	# This avoids expensive PATH scanning and realpath resolution.
	local self_dir
	self_dir="$(dirname "${BASH_SOURCE[0]}" 2>/dev/null || echo ".")"
	local sibling="${self_dir}/shellcheck.real"
	if [[ -x "$sibling" ]]; then
		printf '%s' "$sibling"
		return 0
	fi

	# Fast path: check common .real locations before PATH scanning
	local loc
	for loc in /opt/homebrew/bin/shellcheck.real /usr/local/bin/shellcheck.real; do
		if [[ -x "$loc" ]]; then
			printf '%s' "$loc"
			return 0
		fi
	done

	# Slow path: search PATH, skipping this wrapper script
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

	# Last resort: common locations without .real suffix
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

# --- Filter arguments and extract target file ---
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

# --- Debounce: skip if file unchanged since last check ---
# Returns 0 if check should be skipped (file unchanged), 1 if check needed.
# Reads stdin for the target file path when called from a pipe.
_debounce_check() {
	local target_file="$1"

	# Only debounce for real files (not stdin "-")
	[[ -z "$target_file" || "$target_file" == "-" ]] && return 1
	[[ -f "$target_file" ]] || return 1

	mkdir -p "$_SC_CACHE_DIR" 2>/dev/null || return 1

	# Hash the absolute path for the cache key
	local cache_key
	cache_key=$(printf '%s' "$target_file" | cksum | awk '{print $1}')
	local cache_file="${_SC_CACHE_DIR}/${cache_key}"

	# Get file modification time (seconds since epoch)
	local file_mtime
	if [[ "$(uname)" == "Darwin" ]]; then
		file_mtime=$(stat -f '%m' "$target_file" 2>/dev/null) || return 1
	else
		file_mtime=$(stat -c '%Y' "$target_file" 2>/dev/null) || return 1
	fi

	# Check cache: if cache exists, file hasn't changed, and within debounce window
	if [[ -f "$cache_file" ]]; then
		local cached_mtime cached_time
		read -r cached_mtime cached_time 2>/dev/null <"$cache_file" || return 1
		local now
		now=$(date +%s)
		if [[ "$cached_mtime" == "$file_mtime" ]] && [[ $((now - cached_time)) -lt $_SC_DEBOUNCE_SEC ]]; then
			# File unchanged and within debounce window — skip
			return 0
		fi
	fi

	# Update cache with current mtime and timestamp
	printf '%s %s' "$file_mtime" "$(date +%s)" >"$cache_file" 2>/dev/null || true
	return 1
}

# --- Concurrency limiter: acquire a slot or exit ---
# Uses mkdir-based locks (atomic on all filesystems).
# Returns 0 if slot acquired (caller must release), 1 if all slots busy.
_acquire_slot() {
	mkdir -p "$_SC_LOCK_DIR" 2>/dev/null || return 1

	local slot
	for slot in $(seq 1 "$_SC_MAX_PARALLEL"); do
		local lock="${_SC_LOCK_DIR}/slot-${slot}"
		if mkdir "$lock" 2>/dev/null; then
			# Got a slot — record PID for stale lock cleanup
			printf '%s' "$$" >"${lock}/pid" 2>/dev/null || true
			printf '%s' "$slot"
			return 0
		fi
		# Check if the lock holder is still alive (stale lock cleanup)
		local holder_pid
		holder_pid=$(cat "${lock}/pid" 2>/dev/null) || continue
		if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
			# Stale lock — remove and retry
			rm -rf "$lock" 2>/dev/null || true
			if mkdir "$lock" 2>/dev/null; then
				printf '%s' "$$" >"${lock}/pid" 2>/dev/null || true
				printf '%s' "$slot"
				return 0
			fi
		fi
	done
	return 1
}

_release_slot() {
	local slot="$1"
	rm -rf "${_SC_LOCK_DIR}/slot-${slot}" 2>/dev/null || true
	return 0
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

	# Find the target file (last non-flag argument, or "-" for stdin)
	local target_file=""
	local i
	for i in "${filtered_args[@]+"${filtered_args[@]}"}"; do
		case "$i" in
		-*) ;;                 # skip flags
		*) target_file="$i" ;; # last positional arg is the file
		esac
	done

	# Debounce: skip if file unchanged since last check
	if [[ -n "$target_file" ]] && _debounce_check "$target_file"; then
		exit 0
	fi

	# Concurrency limit: wait briefly for a slot, then give up
	local slot=""
	local attempt
	for attempt in 1 2 3; do
		slot=$(_acquire_slot) && break
		slot=""
		sleep 1
	done

	if [[ -z "$slot" ]]; then
		# All slots busy after 3 attempts — exit silently.
		# No output = no diagnostics, which is better than 100 competing processes.
		exit 0
	fi

	# Ensure slot is released on exit (normal, error, or signal)
	trap '_release_slot "'"$slot"'"' EXIT

	# Enforce memory limit (soft limit — ShellCheck can still be killed by the
	# memory pressure monitor if it exceeds this, but this prevents the worst case)
	local vmem_mb="${SHELLCHECK_VMEM_MB:-2048}"
	local vmem_kb=$((vmem_mb * 1024))
	ulimit -v "$vmem_kb" 2>/dev/null || true

	"$real_shellcheck" "${filtered_args[@]+"${filtered_args[@]}"}"
}

main "$@"
