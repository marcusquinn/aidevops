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

if [[ -f "$HELPER_REPO" ]]; then
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
# Determine the base SHA for the regression check.
# 1. git merge-base HEAD @{u}  — when upstream branch is set and reachable
# 2. git merge-base HEAD origin/main  — fallback
# 3. fail-open                 — when neither resolves (new repo, offline, etc.)
# ---------------------------------------------------------------------------
_resolve_base_sha() {
	local _base
	# Try upstream tracking branch first
	if _base=$(git merge-base HEAD "@{u}" 2>/dev/null) && [[ -n "$_base" ]]; then
		printf '%s' "$_base"
		return 0
	fi
	# Fall back to origin/main
	if git fetch origin main --quiet 2>/dev/null && \
		_base=$(git merge-base HEAD origin/main 2>/dev/null) && [[ -n "$_base" ]]; then
		printf '%s' "$_base"
		return 0
	fi
	# Try without fetch (offline)
	if _base=$(git merge-base HEAD origin/main 2>/dev/null) && [[ -n "$_base" ]]; then
		printf '%s' "$_base"
		return 0
	fi
	return 1
}

BASE_SHA=""
if ! BASE_SHA=$(_resolve_base_sha); then
	_log WARN "cannot determine merge-base (offline or no upstream?) — fail-open"
	exit 0
fi

[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "base SHA: ${BASE_SHA:0:7}"

# ---------------------------------------------------------------------------
# Run the check for each metric. Accumulate exit codes; fail loudly on any
# regression; fail-open on helper invocation errors (exit 2).
# ---------------------------------------------------------------------------
METRICS=("function-complexity" "nesting-depth" "file-size")
exit_code=0

for metric in "${METRICS[@]}"; do
	[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "checking metric: $metric"

	helper_output=$("$COMPLEXITY_HELPER" check --base "$BASE_SHA" --metric "$metric" 2>&1)
	helper_rc=$?

	case "$helper_rc" in
	0)
		[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && _log INFO "[$metric] no new violations"
		;;
	1)
		# New violations detected — extract the REGRESSION summary line(s) for display
		regression_lines=$(printf '%s\n' "$helper_output" | grep "REGRESSION:" || true)
		printf '\n[%s][BLOCK] Push introduces new %s violation(s):\n' "$GUARD_NAME" "$metric" >&2
		printf '\n' >&2
		if [[ -n "$regression_lines" ]]; then
			printf '%s\n' "$regression_lines" >&2
		fi
		printf '%s\n' "$helper_output" | grep -v "^\[complexity" >&2 || true
		printf '\n' >&2
		printf '  Thresholds:\n' >&2
		case "$metric" in
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
		_log WARN "[$metric] helper invocation error (exit 2) — fail-open"
		[[ "${COMPLEXITY_GUARD_DEBUG:-0}" == "1" ]] && printf '%s\n' "$helper_output" >&2
		;;
	*)
		_log WARN "[$metric] unexpected exit code $helper_rc — fail-open"
		;;
	esac
done

exit "$exit_code"
