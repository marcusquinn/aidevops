#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# rtk-helper.sh - Run RTK explicit commands without repeated no-hook advisory noise

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="RTK"

usage() {
	cat <<'EOF'
Usage:
  rtk-helper.sh COMMAND [ARGS...]

Runs `rtk COMMAND [ARGS...]` for explicit token-optimized commands and strips
RTK's repeated no-hook advisory from output. Exit status is preserved.

Use only for supported noisy summaries such as:
  rtk-helper.sh git status
  rtk-helper.sh git log --oneline -20
  rtk-helper.sh gh pr list --repo owner/repo

Do not use for file reads, JSON assertions, security scans, exact/verbatim diffs,
or credential-sensitive output.
EOF
	return 0
}

filter_rtk_advisory() {
	local input_file="$1"
	python3 - "$input_file" <<'PY'
import sys
path = sys.argv[1]
needle = "[rtk] /!\\ No hook installed — run `rtk init -g` for automatic token savings"
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.rstrip("\n") == needle:
            continue
        sys.stdout.write(line)
PY
	return 0
}

main() {
	if [[ $# -eq 0 ]]; then
		usage
		return 0
	fi

	case "${1:-}" in
	--help | -h | help)
		usage
		return 0
		;;
	esac

	if ! command -v rtk >/dev/null 2>&1; then
		log_error "rtk not found; run setup.sh or install RTK first"
		return 127
	fi

	local tmp_output
	tmp_output=$(mktemp "${TMPDIR:-/tmp}/aidevops-rtk.XXXXXX")
	trap 'rm -f "${tmp_output:-}"' EXIT

	local rc=0
	set +e
	rtk "$@" >"$tmp_output" 2>&1
	rc=$?
	set -e

	filter_rtk_advisory "$tmp_output"
	return "$rc"
}

main "$@"
