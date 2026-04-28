#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# canonical-recovery-routine.sh — Auto-retry canonical-recovery advisories (t3027)
# =============================================================================
#
# Purpose
# -------
# `pulse-canonical-recovery.sh` writes a per-repo advisory file at
# `~/.aidevops/advisories/canonical-recovery-<basename>.advisory` when it
# cannot stash+pull a canonical repo and gives up. Today the user is
# expected to act on the advisory manually. This routine re-attempts
# recovery on a schedule so a transient failure (uncommitted file user
# resolved, conflicting stash that's now empty, etc.) auto-clears.
#
# Behaviour
# ---------
# 1. Scan `~/.aidevops/advisories/canonical-recovery-*.advisory`
# 2. For each, extract the canonical repo path from line 4 of the advisory
#    (canonical format: `      ~/Git/<basename>`)
# 3. Skip if the repo path is missing, the directory does not exist, or the
#    repo is not git-tracked
# 4. Invoke `pulse-canonical-recovery.sh <repo-path>` (idempotent: exit 0
#    on no-work-needed or success, 1 on persistent failure — re-files
#    advisory on its own)
# 5. On exit 0, REMOVE the advisory file (recovery succeeded, advisory is
#    stale) — `pulse-canonical-recovery.sh` does not clear stale advisories
#    on its own
#
# Schedule recommendation
# -----------------------
# `repeat:cron(*/10 * * * *)` — every 10 min. Chosen because:
#   - canonical-recovery failure modes (uncommitted file, divergent local
#     branch) often resolve within minutes when the user notices and acts
#   - 10 min cap keeps the user-noticeable lag low
#   - The recovery operation is git-only (no API), so 144 invocations/day
#     adds ~zero GraphQL/REST budget cost
#
# CLI
# ---
#   canonical-recovery-routine.sh tick   — scan + retry one cycle (default)
#   canonical-recovery-routine.sh list   — list active advisories without acting
#   canonical-recovery-routine.sh help   — usage
#
# Exit codes
# ----------
#   0  success (cleared zero or more advisories, no fatal error)
#   1  malformed CLI invocation
#
# Env
# ---
#   AIDEVOPS_ADVISORY_DIR         — override advisory dir (default ~/.aidevops/advisories)
#   AIDEVOPS_SKIP_CANONICAL_RECOVERY_ROUTINE=1 — disable (always exit 0)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Resolve script dir for sourcing siblings if needed (currently no shared
# constants needed — this script intentionally has zero external deps so
# it can run from a launchd plist without environment setup).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADVISORY_DIR="${AIDEVOPS_ADVISORY_DIR:-${HOME}/.aidevops/advisories}"
RECOVERY_HELPER="${_SCRIPT_DIR}/pulse-canonical-recovery.sh"

# ---------------------------------------------------------------------------
# _crr_log
#
# Stderr log with timestamp prefix. Routine output goes to stderr so a
# launchd/cron StandardOutPath can capture stdout for structured reporting
# while diagnostics flow to StandardErrorPath.
# ---------------------------------------------------------------------------
_crr_log() {
	local _msg="$*"
	printf '[%s] [canonical-recovery-routine] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_msg" >&2
	return 0
}

# ---------------------------------------------------------------------------
# _crr_extract_repo_path <advisory-file>
#
# Extracts the canonical repo path from the 4th line of the advisory body
# (format produced by pulse-canonical-recovery.sh::_pcr_advisory_body).
# Resolves leading `~` to $HOME. Returns the path on stdout, empty string
# if the advisory does not contain a parseable path.
# ---------------------------------------------------------------------------
_crr_extract_repo_path() {
	local _file="$1"
	[[ -f "$_file" ]] || { printf ''; return 0; }
	local _path
	# Line 4 format: "      ~/Git/<basename>" (4 leading spaces + `~/Git/...`)
	_path=$(sed -n '4p' "$_file" 2>/dev/null | sed -E 's/^[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
	# Tilde-expand if the advisory body recorded a `~/`-prefixed path.
	# We intentionally compare against the literal two-character string
	# `~/` (no shell expansion) — shellcheck's SC2088 is wrong here because
	# the goal is a string-prefix test, not a tilde expansion.
	# shellcheck disable=SC2088
	if [[ "${_path:0:2}" == "~/" ]]; then
		_path="${HOME}/${_path:2}"
	fi
	printf '%s' "$_path"
	return 0
}

# ---------------------------------------------------------------------------
# _crr_retry_advisory <advisory-file>
#
# Attempt recovery for one advisory. Returns 0 if the advisory was cleared
# (recovery succeeded), 1 if it was retained (recovery still failing or
# the advisory was un-actionable).
# ---------------------------------------------------------------------------
_crr_retry_advisory() {
	local _file="$1"
	local _basename
	_basename=$(basename "$_file" .advisory)

	local _repo_path
	_repo_path=$(_crr_extract_repo_path "$_file")
	if [[ -z "$_repo_path" ]]; then
		_crr_log "skip ${_basename}: could not extract repo path from advisory"
		return 1
	fi

	if [[ ! -d "$_repo_path" ]]; then
		_crr_log "skip ${_basename}: repo path '${_repo_path}' does not exist (user may have moved/removed it)"
		return 1
	fi

	if [[ ! -d "${_repo_path}/.git" ]]; then
		_crr_log "skip ${_basename}: '${_repo_path}' is not a git repository"
		return 1
	fi

	if [[ ! -x "$RECOVERY_HELPER" ]]; then
		_crr_log "skip ${_basename}: pulse-canonical-recovery.sh not executable at ${RECOVERY_HELPER}"
		return 1
	fi

	_crr_log "retry ${_basename}: invoking pulse-canonical-recovery.sh on ${_repo_path}"
	# Helper exits 0 on no-work or success; 1 on persistent failure.
	# It re-files the advisory on its own when failing, so we just need to
	# clear the advisory ourselves on success.
	local _rc=0
	"$RECOVERY_HELPER" "$_repo_path" >/dev/null 2>&1 || _rc=$?

	if [[ "$_rc" -eq 0 ]]; then
		# Recovery succeeded — clear the stale advisory.
		# Use rm -f for idempotency (helper may have cleared it already in
		# a future-version scenario, or another routine instance may have
		# raced us).
		rm -f "$_file" 2>/dev/null || true
		_crr_log "cleared ${_basename}: recovery succeeded, advisory removed"
		return 0
	fi

	_crr_log "retained ${_basename}: recovery still failing (exit ${_rc}), advisory left in place"
	return 1
}

# ---------------------------------------------------------------------------
# _crr_cmd_tick
#
# Scan + retry. Iterates all `canonical-recovery-*.advisory` files in
# ADVISORY_DIR. Always returns 0 — partial failures are logged but do not
# fail the routine (next tick will try again).
# ---------------------------------------------------------------------------
_crr_cmd_tick() {
	if [[ "${AIDEVOPS_SKIP_CANONICAL_RECOVERY_ROUTINE:-0}" == "1" ]]; then
		_crr_log "AIDEVOPS_SKIP_CANONICAL_RECOVERY_ROUTINE=1 — skipping"
		return 0
	fi

	if [[ ! -d "$ADVISORY_DIR" ]]; then
		_crr_log "advisory dir '${ADVISORY_DIR}' does not exist — nothing to retry"
		return 0
	fi

	local _scanned=0 _cleared=0 _retained=0
	# Use nullglob via shopt to avoid matching the literal pattern when no
	# advisories exist. Restore prior nullglob state on exit.
	local _had_nullglob=0
	shopt -q nullglob && _had_nullglob=1
	shopt -s nullglob
	local _files=("$ADVISORY_DIR"/canonical-recovery-*.advisory)
	[[ "$_had_nullglob" -eq 0 ]] && shopt -u nullglob

	for _f in "${_files[@]}"; do
		_scanned=$((_scanned + 1))
		if _crr_retry_advisory "$_f"; then
			_cleared=$((_cleared + 1))
		else
			_retained=$((_retained + 1))
		fi
	done

	_crr_log "tick complete: scanned=${_scanned} cleared=${_cleared} retained=${_retained}"
	return 0
}

# ---------------------------------------------------------------------------
# _crr_cmd_list
#
# List active advisories without invoking the recovery helper. Useful for
# `aidevops security` integration and ad-hoc diagnosis.
# ---------------------------------------------------------------------------
_crr_cmd_list() {
	if [[ ! -d "$ADVISORY_DIR" ]]; then
		_crr_log "advisory dir '${ADVISORY_DIR}' does not exist"
		return 0
	fi

	local _had_nullglob=0
	shopt -q nullglob && _had_nullglob=1
	shopt -s nullglob
	local _files=("$ADVISORY_DIR"/canonical-recovery-*.advisory)
	[[ "$_had_nullglob" -eq 0 ]] && shopt -u nullglob

	if [[ "${#_files[@]}" -eq 0 ]]; then
		printf 'No active canonical-recovery advisories.\n'
		return 0
	fi

	printf 'Active canonical-recovery advisories (%d):\n' "${#_files[@]}"
	for _f in "${_files[@]}"; do
		local _basename _path
		_basename=$(basename "$_f" .advisory)
		_path=$(_crr_extract_repo_path "$_f")
		printf '  - %s → %s\n' "$_basename" "${_path:-<unparseable>}"
	done
	return 0
}

# ---------------------------------------------------------------------------
# _crr_cmd_help
# ---------------------------------------------------------------------------
_crr_cmd_help() {
	cat <<EOF
canonical-recovery-routine.sh — Auto-retry canonical-recovery advisories

Usage:
  canonical-recovery-routine.sh [tick]    Scan + retry recovery for each advisory
  canonical-recovery-routine.sh list      List active advisories without acting
  canonical-recovery-routine.sh help      This message

Env:
  AIDEVOPS_ADVISORY_DIR                       Override advisory dir
  AIDEVOPS_SKIP_CANONICAL_RECOVERY_ROUTINE=1  Disable (always exit 0)

Part of aidevops framework: https://aidevops.sh
EOF
	return 0
}

# ---------------------------------------------------------------------------
# main dispatcher
# ---------------------------------------------------------------------------
main() {
	local _cmd="${1:-tick}"
	case "$_cmd" in
		tick) _crr_cmd_tick ;;
		list) _crr_cmd_list ;;
		help|--help|-h) _crr_cmd_help ;;
		*)
			_crr_log "unknown subcommand: ${_cmd}"
			_crr_cmd_help
			return 1
			;;
	esac
	return 0
}

main "$@"
