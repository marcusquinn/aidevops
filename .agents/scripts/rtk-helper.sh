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
  rtk-helper.sh --compare COMMAND [ARGS...]

Runs `rtk COMMAND [ARGS...]` for explicit token-optimized commands and strips
RTK's repeated no-hook advisory from output. Exit status is preserved.

`--compare` runs both raw and RTK-filtered forms, then prints a diagnostic
summary with exit codes, bytes, approximate token counts, and reduction. It does
not print command output; rerun the raw command when exact evidence is needed.

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

compare_rtk_output() {
	if [[ $# -eq 0 ]]; then
		usage
		return 2
	fi

	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local tmp_raw=""
	local tmp_rtk=""
	local tmp_filtered=""
	tmp_raw=$(mktemp "${TMPDIR:-/tmp}/aidevops-rtk-raw.XXXXXX")
	push_cleanup "rm -f '${tmp_raw}'"
	tmp_rtk=$(mktemp "${TMPDIR:-/tmp}/aidevops-rtk-proxied.XXXXXX")
	push_cleanup "rm -f '${tmp_rtk}'"
	tmp_filtered=$(mktemp "${TMPDIR:-/tmp}/aidevops-rtk-filtered.XXXXXX")
	push_cleanup "rm -f '${tmp_filtered}'"

	local raw_rc=0
	local rtk_rc=0
	set +e
	"$@" >"$tmp_raw" 2>&1
	raw_rc=$?
	rtk "$@" >"$tmp_rtk" 2>&1
	rtk_rc=$?
	set -e

	filter_rtk_advisory "$tmp_rtk" >"$tmp_filtered"
	rm -f "$tmp_rtk"

	python3 - "$tmp_raw" "$tmp_filtered" "$raw_rc" "$rtk_rc" "$*" <<'PY'
import math
import sys

raw_path, rtk_path, raw_rc, rtk_rc, command = sys.argv[1:]

def stats(path):
    with open(path, "rb") as fh:
        data = fh.read()
    text = data.decode("utf-8", errors="replace")
    return {
        "bytes": len(data),
        "lines": 0 if not text else len(text.splitlines()),
        "approx_tokens": int(math.ceil(len(data) / 4.0)),
    }

raw = stats(raw_path)
rtk = stats(rtk_path)
delta = raw["bytes"] - rtk["bytes"]
percent = (delta / raw["bytes"] * 100.0) if raw["bytes"] else 0.0
same_rc = "yes" if raw_rc == rtk_rc else "no"

print("## RTK output comparison")
print("")
print(f"Command: `{command}`")
print("")
print("| Form | Exit | Bytes | Approx tokens | Lines |")
print("|---|---:|---:|---:|---:|")
print(f"| Raw | {raw_rc} | {raw['bytes']} | {raw['approx_tokens']} | {raw['lines']} |")
print(f"| RTK-filtered | {rtk_rc} | {rtk['bytes']} | {rtk['approx_tokens']} | {rtk['lines']} |")
print("")
print(f"Reduction: {delta} bytes ({percent:.1f}%). Same exit code: {same_rc}.")
print("")
print("Decision guidance:")
if raw_rc != rtk_rc:
    print("- Broaden immediately: exit codes differ, so use the raw command for diagnosis.")
elif delta <= 0:
    print("- Prefer raw or a narrower structured command: RTK did not reduce this output.")
else:
    print("- RTK is useful for first-pass discovery if all decision facts are present.")
print("- For exact evidence, JSON assertions, diffs, security scans, or terminal failures, rerun raw/direct commands.")
PY

	rm -f "$tmp_raw" "$tmp_filtered"
	return "$rtk_rc"
}

main() {
	if [[ $# -eq 0 ]]; then
		usage
		return 0
	fi

	local mode="${1:-}"
	case "$mode" in
	--help | -h | help)
		usage
		return 0
		;;
	esac

	if ! command -v rtk >/dev/null 2>&1; then
		log_error "rtk not found; run setup.sh or install RTK first"
		return 127
	fi

	case "$mode" in
	--compare | compare)
		shift
		compare_rtk_output "$@"
		return $?
		;;
	esac

	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local tmp_output=""
	tmp_output=$(mktemp "${TMPDIR:-/tmp}/aidevops-rtk.XXXXXX")
	push_cleanup "rm -f '${tmp_output}'"

	local rc=0
	set +e
	rtk "$@" >"$tmp_output" 2>&1
	rc=$?
	set -e

	filter_rtk_advisory "$tmp_output"
	rm -f "$tmp_output"
	return "$rc"
}

main "$@"
