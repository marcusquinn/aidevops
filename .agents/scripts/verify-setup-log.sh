#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# verify-setup-log.sh — verify that a captured setup.sh log reached the
# completion sentinel (GH#18492 / t2026).
#
# Exit codes:
#   0 — sentinel present, setup.sh ran to completion
#   1 — sentinel absent, setup.sh terminated early (prints last 15 log lines)
#   2 — usage error (bad args, unreadable log)
#
# Usage:
#   verify-setup-log.sh <log-file>
#   verify-setup-log.sh --help
#
# Intended callers: auto-update-helper.sh, CI workflows, local release
# verification scripts, and human operators for post-hoc log analysis.
#
# The sentinel format is '[SETUP_COMPLETE] aidevops setup.sh v<ver> ...' —
# see setup.sh:print_setup_complete_sentinel. The contract is locked by
# tests/test-setup-completion-sentinel.sh.

set -Eeuo pipefail
IFS=$'\n\t'

_SENTINEL_PREFIX='[SETUP_COMPLETE] aidevops setup.sh'
_TAIL_LINES=15

_print_usage() {
	cat <<'EOF'
verify-setup-log.sh — verify setup.sh log completion sentinel

Usage:
  verify-setup-log.sh <log-file>

Exits 0 if the log contains the [SETUP_COMPLETE] sentinel.
Exits 1 with the last 15 lines printed to stderr if the sentinel is absent.
Exits 2 on usage error or unreadable log.
EOF
	return 0
}

main() {
	local log_file="${1:-}"

	if [[ -z "$log_file" ]]; then
		_print_usage >&2
		return 2
	fi

	if [[ "$log_file" == "--help" ]] || [[ "$log_file" == "-h" ]]; then
		_print_usage
		return 0
	fi

	if [[ ! -r "$log_file" ]]; then
		printf 'verify-setup-log.sh: ERROR: cannot read log file: %s\n' "$log_file" >&2
		return 2
	fi

	if grep -Fq "$_SENTINEL_PREFIX" "$log_file"; then
		return 0
	fi

	printf 'verify-setup-log.sh: FAIL: setup.sh did not reach completion sentinel in %s\n' "$log_file" >&2
	printf 'Last %d lines of log (termination point):\n' "$_TAIL_LINES" >&2
	printf -- '---\n' >&2
	tail -n "$_TAIL_LINES" "$log_file" >&2
	printf -- '---\n' >&2
	return 1
}

main "$@"
