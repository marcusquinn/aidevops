#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# counter-stack-check.sh — ratchet lint gate for grep -c counter-stacking (t2763)
# counter-stack-check:disable — this script documents and detects the anti-pattern;
# it necessarily contains the pattern string in comments and the regex constant.
#
# Detects the anti-pattern:
#   count=$(grep -c 'pattern' file || echo "0")
#
# grep -c exits 1 on zero matches, so the || echo path fires on zero matches,
# producing "0\n0" (grep's own zero output + the echo fallback). See GH#20402
# (incident) and GH#20581 (bug class root cause).
#
# Usage:
#   counter-stack-check.sh                        # ratchet mode (CI default)
#   counter-stack-check.sh --dry-run              # print violations, always exit 0
#   counter-stack-check.sh --baseline PATH        # use custom baseline file
#   counter-stack-check.sh --update-baseline      # rewrite baseline to current violations
#   counter-stack-check.sh --paths PATH [PATH...] # restrict scan to given paths
#   counter-stack-check.sh --help                 # show this help
#
# Exit codes:
#   0 — at or below baseline (ratchet mode) or dry-run
#   1 — regression: new violation(s) found above baseline
#   2 — usage error
#
# Ratchet semantics (t2228): gate only blocks when violation count INCREASES
# beyond baseline. Pre-existing violations do not block unrelated PRs.
# To intentionally accept new violations: run --update-baseline (requires
# deliberate human action — all new violations should be fixed instead).
#
# Canonical fix: replace grep -c … || echo "N" with safe_grep_count() from
# shared-constants.sh, or the inline form:
#   count=$(grep -c 'pat' file 2>/dev/null || true)
#   [[ "$count" =~ ^[0-9]+$ ]] || count=0
#
# See: .agents/reference/shell-style-guide.md § Counter Safety (grep -c)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCRIPT_NAME=$(basename "$0")

# Anti-pattern regex: grep -c followed by || echo "digit(s)"
# Anchored to catch: grep -c ... || echo "0", grep -c ... 2>/dev/null || echo "0"
# etc. Uses POSIX extended regex compatible with rg and grep -E.
readonly COUNTER_STACK_PATTERN='grep -c[^|]*\|\|[[:space:]]*echo[[:space:]]*"[0-9]+"'

# Default scan paths (covers all CI-managed shell and workflow files)
readonly DEFAULT_SCAN_PATHS=(".github/" ".agents/")

# Default baseline file
readonly DEFAULT_BASELINE=".agents/configs/counter-stack-baseline.txt"

# ── helpers ──────────────────────────────────────────────────────────

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '13,30p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# _load_baseline <path> — read baseline file, return sorted file:line list.
# Lines starting with # are comments and are ignored.
_load_baseline() {
	local _path="$1"
	if [[ ! -f "$_path" ]]; then
		# No baseline file = zero known violations
		return 0
	fi
	grep -v '^[[:space:]]*#' "$_path" | grep -v '^[[:space:]]*$' | sort || true
	return 0
}

# _has_disable_directive <file> — returns 0 if file opts out of scanning.
# A file with '# counter-stack-check:disable' in its first 20 lines is skipped.
# Used by test harnesses that embed the anti-pattern in comments as fixtures.
_has_disable_directive() {
	local _file="$1"
	local _head
	_head=$(head -20 "$_file" 2>/dev/null || true)
	if [[ "$_head" == *"# counter-stack-check:disable"* ]]; then
		return 0
	fi
	return 1
}

# ── scan ─────────────────────────────────────────────────────────────

# _scan_paths <path> [...] — scan given paths for violations.
# Prints "file:line" for each violation to stdout.
_scan_paths() {
	local _found=0
	local _path
	for _path in "$@"; do
		if [[ ! -e "$_path" ]]; then
			log "Path not found, skipping: $_path"
			continue
		fi
		local _rg_out
		# rg exits 1 on no matches — use || true for ratchet semantics.
		# --with-filename ensures output format is file:line:match even for single-file args.
		_rg_out=$(rg -n --no-heading --with-filename -g '*.sh' -g '*.yml' -g '*.yaml' \
			"$COUNTER_STACK_PATTERN" "$_path" 2>/dev/null || true)
		if [[ -n "$_rg_out" ]]; then
			local _last_checked_file=""
			local _file_disabled=0
			while IFS= read -r _line; do
				[[ -n "$_line" ]] || continue
				# Output file:linenum (strip match text — we only need location)
				local _loc
				_loc=$(printf '%s\n' "$_line" | cut -d: -f1-2)
				local _file_path
				_file_path=$(printf '%s\n' "$_loc" | cut -d: -f1)
				# Check per-file disable directive (cache to avoid re-reading for same file)
				if [[ "$_file_path" != "$_last_checked_file" ]]; then
					_last_checked_file="$_file_path"
					if _has_disable_directive "$_file_path"; then
						_file_disabled=1
					else
						_file_disabled=0
					fi
				fi
				[[ "$_file_disabled" -eq 1 ]] && continue
				printf '%s\n' "$_loc"
				_found=$((_found + 1))
			done <<<"$_rg_out"
		fi
	done
	return 0
}

# ── subcommands ───────────────────────────────────────────────────────

# cmd_check — ratchet mode: exit 1 only when above baseline
cmd_check() {
	local _baseline_path="$1"
	local _dry_run="$2"
	shift 2
	local _scan_paths=("$@")

	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	cd "$_repo_root" || return 1

	# Resolve paths relative to repo root
	local _resolved_paths=()
	local _p
	for _p in "${_scan_paths[@]}"; do
		_resolved_paths+=("$_p")
	done

	# Run scan
	local _current_violations
	_current_violations=$(_scan_paths "${_resolved_paths[@]}" | sort)

	local _current_count=0
	if [[ -n "$_current_violations" ]]; then
		_current_count=$(printf '%s\n' "$_current_violations" | grep -c . || true)
	fi

	# Load baseline
	local _baseline_violations
	_baseline_violations=$(_load_baseline "$_baseline_path")
	local _baseline_count=0
	if [[ -n "$_baseline_violations" ]]; then
		_baseline_count=$(printf '%s\n' "$_baseline_violations" | grep -c . || true)
	fi

	# Compute new violations (in current but not in baseline)
	local _new_violations=""
	if [[ -n "$_current_violations" && -n "$_baseline_violations" ]]; then
		_new_violations=$(comm -23 \
			<(printf '%s\n' "$_current_violations") \
			<(printf '%s\n' "$_baseline_violations") || true)
	elif [[ -n "$_current_violations" ]]; then
		_new_violations="$_current_violations"
	fi

	local _new_count=0
	if [[ -n "$_new_violations" ]]; then
		_new_count=$(printf '%s\n' "$_new_violations" | grep -c . || true)
	fi

	# Print report
	printf '\n--- Counter-Stack Check (grep -c safety) ---\n'
	printf 'Baseline: %d known violation(s) in %s\n' "$_baseline_count" "$_baseline_path"
	printf 'Current:  %d violation(s) detected\n' "$_current_count"

	if [[ "$_current_count" -gt 0 ]]; then
		printf '\nAll detected violations:\n'
		printf '%s\n' "$_current_violations"
	fi

	if [[ "$_new_count" -gt 0 ]]; then
		printf '\n*** NEW violations (not in baseline): %d ***\n' "$_new_count"
		printf '%s\n' "$_new_violations"
		printf '\nFix: use safe_grep_count() from shared-constants.sh, or:\n'
		# shellcheck disable=SC2016  # literal shell code shown as example, not expanded
		printf '  count=$(grep -c '"'"'pat'"'"' file 2>/dev/null || true)\n'
		# shellcheck disable=SC2016  # literal shell code shown as example, not expanded
		printf '  [[ "$count" =~ ^[0-9]+$ ]] || count=0\n'
		printf 'See: .agents/reference/shell-style-guide.md \247 Counter Safety (grep -c)\n'
	fi

	if [[ "$_dry_run" -eq 1 ]]; then
		if [[ "$_new_count" -gt 0 ]]; then
			printf '\n(dry-run: would fail with %d new violation(s))\n' "$_new_count"
		else
			printf '\nDry-run: clean (at or below baseline).\n'
		fi
		return 0
	fi

	if [[ "$_new_count" -gt 0 ]]; then
		printf '\nRatchet gate: FAIL (%d new violation(s) above baseline)\n' "$_new_count"
		return 1
	fi

	printf '\nRatchet gate: PASS (at or below baseline).\n'
	return 0
}

# cmd_update_baseline — rewrite baseline to current violations
cmd_update_baseline() {
	local _baseline_path="$1"
	shift
	local _scan_paths=("$@")

	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	cd "$_repo_root" || return 1

	local _current_violations
	_current_violations=$(_scan_paths "${_scan_paths[@]}" | sort)

	local _count=0
	if [[ -n "$_current_violations" ]]; then
		_count=$(printf '%s\n' "$_current_violations" | grep -c . || true)
	fi

	# Ensure directory exists
	local _dir
	_dir=$(dirname "$_baseline_path")
	mkdir -p "$_dir"

	{
		printf '# counter-stack-baseline.txt\n'
		printf '# Auto-generated by counter-stack-check.sh --update-baseline\n'
		printf '# Format: file:line (one per line, # lines are comments)\n'
		printf '# Known violations of: grep -c … || echo "N" anti-pattern\n'
		printf '# See: GH#20581 (bug class), GH#20594 (gate), GH#20402 (incident)\n'
		printf '#\n'
		if [[ -n "$_current_violations" ]]; then
			printf '%s\n' "$_current_violations"
		fi
	} >"$_baseline_path"

	log "Baseline updated: $_count violation(s) written to $_baseline_path"
	return 0
}

# ── main dispatch ─────────────────────────────────────────────────────

main() {
	# Use integers for boolean flags to avoid repeated string literals ("true"/"false").
	local _dry_run=0
	local _baseline_path="$DEFAULT_BASELINE"
	local _update_baseline=0
	local _scan_paths=("${DEFAULT_SCAN_PATHS[@]}")

	# Parse arguments — capture each $1 into a local before use (style rule).
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		shift
		case "$_arg" in
		--dry-run)
			_dry_run=1
			;;
		--baseline)
			[[ $# -ge 1 ]] || die "--baseline requires a PATH argument"
			local _bv="$1"
			shift
			_baseline_path="$_bv"
			;;
		--update-baseline)
			_update_baseline=1
			;;
		--paths)
			_scan_paths=()
			while [[ $# -gt 0 ]]; do
				local _pv="$1"
				[[ "$_pv" == --* ]] && break
				_scan_paths+=("$_pv")
				shift
			done
			[[ ${#_scan_paths[@]} -gt 0 ]] || die "--paths requires at least one PATH"
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			die "Unknown argument: $_arg. Use --help for usage."
			;;
		esac
	done

	if [[ "$_update_baseline" -eq 1 ]]; then
		cmd_update_baseline "$_baseline_path" "${_scan_paths[@]}"
		return $?
	fi

	cmd_check "$_baseline_path" "$_dry_run" "${_scan_paths[@]}"
	return $?
}

main "$@"
