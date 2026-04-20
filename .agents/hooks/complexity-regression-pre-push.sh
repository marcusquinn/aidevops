#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# complexity-regression-pre-push.sh — git pre-push hook (t2198).
#
# Runs complexity-regression-helper.sh check for the three metrics
# (function-complexity, nesting-depth, file-size) before a push is accepted.
# If the diff introduces any new violations the push is blocked with a
# formatted message naming the file, function/metric, and threshold crossed.
#
# Install: see .agents/scripts/install-pre-push-guards.sh
# (back-compat: install-privacy-guard.sh install still works for the privacy
# guard; for both guards use install-pre-push-guards.sh install)
#
# Git pre-push protocol:
#   arg1 = remote name
#   arg2 = remote URL
#   stdin: one line per ref being pushed:
#     <local_ref> <local_sha> <remote_ref> <remote_sha>
#
# Exit 0 = allow push. Exit 1 = block push.
#
# Environment:
#   COMPLEXITY_GUARD_DISABLE=1  — bypass for this invocation (same as --no-verify)
#   COMPLEXITY_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - complexity-regression-helper.sh not found
#   - upstream not reachable (git merge-base fails)
#   - helper exits with code 2 (invocation error)

set -u

GUARD_NAME="complexity-guard"

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
	return 0
}

if [[ "${COMPLEXITY_GUARD_DISABLE:-0}" == "1" ]]; then
	_log INFO "COMPLEXITY_GUARD_DISABLE=1 — bypassing"
	exit 0
fi

# ---------------------------------------------------------------------------
# Locate complexity-regression-helper.sh: prefer repo-local, fall back to
# deployed copy so this hook works in every repo, not just the aidevops repo.
# ---------------------------------------------------------------------------
_resolve_self_dir() {
	local _src="${BASH_SOURCE[0]}"
	while [[ -L "$_src" ]]; do
		local _dir
		_dir=$(cd -P "$(dirname "$_src")" && pwd)
		_src=$(readlink "$_src")
		[[ "$_src" != /* ]] && _src="$_dir/$_src"
	done
	cd -P "$(dirname "$_src")" && pwd
	return 0
}

HOOK_DIR=$(_resolve_self_dir)
HELPER_REPO="${HOOK_DIR}/../scripts/complexity-regression-helper.sh"
HELPER_DEPLOYED="${HOME}/.aidevops/agents/scripts/complexity-regression-helper.sh"

# Allow env var override for testing (GH#19921: enables tests to inject a stub)
if [[ -n "${COMPLEXITY_HELPER:-}" && -x "$COMPLEXITY_HELPER" ]]; then
	: # Use the env-provided helper
elif [[ -f "$HELPER_REPO" ]]; then
	COMPLEXITY_HELPER="$HELPER_REPO"
elif [[ -f "$HELPER_DEPLOYED" ]]; then
	COMPLEXITY_HELPER="$HELPER_DEPLOYED"
else
	_log WARN "complexity-regression-helper.sh not found — fail-open"
	_log WARN "  checked: $HELPER_REPO"
	_log WARN "  checked: $HELPER_DEPLOYED"
	exit 0
fi

[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "helper: $COMPLEXITY_HELPER"

# ---------------------------------------------------------------------------
# Determine the base SHA for the regression check (GH#20045).
# Uses the default remote branch rather than @{u} to avoid false-positives
# after a rebase. After rebase, @{u} points at the feature branch's own
# remote — not the merge target — so merge-base HEAD @{u} returns an
# outdated commit making every change since look "new" to the scanner.
#
# Priority:
# 1. git symbolic-ref refs/remotes/origin/HEAD  (repo-configured default)
# 2. origin/main  (conventional default)
# 3. origin/master  (legacy default)
# 4. @{u}  (last resort — warns to stderr; exotic repos with non-standard remotes)
# 5. fail-open  — when nothing resolves (new repo, offline, etc.)
# ---------------------------------------------------------------------------
_compute_baseline() {
	local default_remote_head baseline
	# Try origin/HEAD first (repo-configured default branch)
	default_remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
		| sed 's@^refs/remotes/origin/@origin/@')
	if [[ -z "$default_remote_head" ]]; then
		# Fallback: try origin/main, then origin/master
		for candidate in origin/main origin/master; do
			git rev-parse --verify "$candidate" >/dev/null 2>&1 \
				&& { default_remote_head="$candidate"; break; }
		done
	fi
	if [[ -z "$default_remote_head" ]]; then
		# Last resort: old behaviour (warn)
		printf '[%s] warning: no origin HEAD resolved; falling back to @{u}\n' \
			"$GUARD_NAME" >&2
		git merge-base HEAD '@{u}' 2>/dev/null
		return
	fi
	# Happy path: merge-base against default remote head
	baseline=$(git merge-base HEAD "$default_remote_head" 2>/dev/null)
	if [[ -z "$baseline" ]]; then
		printf '[%s] warning: no merge-base with %s; using %s as base\n' \
			"$GUARD_NAME" "$default_remote_head" "$default_remote_head" >&2
		baseline="$default_remote_head"
	fi
	printf '%s\n' "$baseline"
	return 0
}

BASE_SHA=""
if ! BASE_SHA=$(_compute_baseline) || [[ -z "$BASE_SHA" ]]; then
	_log WARN "cannot determine merge-base (offline or no upstream?) — fail-open"
	exit 0
fi

[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "base SHA: ${BASE_SHA:0:7}"

# ---------------------------------------------------------------------------
# Run the check for each metric IN PARALLEL. Accumulate exit codes; fail
# loudly on any regression; fail-open on helper invocation errors (exit 2).
#
# Parallelization (t2381): all 3 metric checks run concurrently via background
# subshells, reducing wall-clock time from ~3min to ~1min (the slowest single
# check). Results are collected via temp files and processed in order so output
# format is identical to the sequential version.
# ---------------------------------------------------------------------------
METRICS=("function-complexity" "nesting-depth" "file-size")
exit_code=0

# Create temp dir for parallel result collection
_parallel_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/complexity-guard.XXXXXX")
if [[ -z "$_parallel_tmpdir" || ! -d "$_parallel_tmpdir" ]]; then
	_log WARN "failed to create temp dir for parallel checks — fail-open"
	exit 0
fi
trap 'rm -rf "$_parallel_tmpdir"' EXIT

# Launch all metric checks in parallel, tracking PIDs explicitly (GH#19921).
# Explicit PID tracking avoids waiting on unrelated background processes if
# this script is ever sourced or expanded.
_pids=()
for _i in "${!METRICS[@]}"; do
	_metric="${METRICS[$_i]}"
	[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "launching metric: $_metric (parallel)"
	(
		"$COMPLEXITY_HELPER" check --base "$BASE_SHA" --metric "$_metric" \
			> "${_parallel_tmpdir}/${_i}.out" 2>&1
		printf '%d' "$?" > "${_parallel_tmpdir}/${_i}.rc"
	) &
	_pids+=($!)
done

# Wait for the specific background jobs we launched
wait "${_pids[@]}"

# Process results in original metric order (preserves output format)
for _i in "${!METRICS[@]}"; do
	_metric="${METRICS[$_i]}"
	helper_rc=$(cat "${_parallel_tmpdir}/${_i}.rc" 2>/dev/null || echo "0")
	helper_output=$(cat "${_parallel_tmpdir}/${_i}.out" 2>/dev/null || echo "")

	case "$helper_rc" in
	0)
		[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "[$_metric] no new violations"
		;;
	1)
		# New violations detected — extract the REGRESSION summary line(s) for display
		regression_lines=$(printf '%s\n' "$helper_output" | grep "REGRESSION:" || true)
		printf '\n[%s][BLOCK] Push introduces new %s violation(s):\n' "$GUARD_NAME" "$_metric" >&2
		printf '\n' >&2
		if [[ -n "$regression_lines" ]]; then
			printf '%s\n' "$regression_lines" >&2
		fi
		printf '%s\n' "$helper_output" | grep -v "^\[complexity" >&2 || true
		printf '\n' >&2
		printf '  Thresholds:\n' >&2
		case "$_metric" in
		function-complexity) printf '    function-complexity: shell functions must be <= 100 lines\n' >&2 ;;
		nesting-depth)       printf '    nesting-depth: shell files must have max nesting depth <= 8\n' >&2 ;;
		file-size)           printf '    file-size: .sh/.py files must be <= 1500 lines\n' >&2 ;;
		esac
		printf '\n' >&2
		printf '  Remediation: extract logic into smaller functions or separate files.\n' >&2
		printf '  Bypass (with justification): COMPLEXITY_GUARD_DISABLE=1 git push ...\n' >&2
		printf '  Or:                          git push --no-verify\n' >&2
		printf '\n' >&2
		exit_code=1
		;;
	2)
		# Helper invocation error — fail-open so a broken env doesn't block all pushes
		_log WARN "[$_metric] helper invocation error (exit 2) — fail-open"
		[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && printf '%s\n' "$helper_output" >&2
		;;
	*)
		_log WARN "[$_metric] unexpected exit code $helper_rc — fail-open"
		;;
	esac
done

exit "$exit_code"
