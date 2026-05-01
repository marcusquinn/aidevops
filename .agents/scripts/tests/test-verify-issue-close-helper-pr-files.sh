#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for verify-issue-close-helper.sh PR file-list parsing.
#
# GH#22138: `gh pr view --json files` may return `{"files":null}` for merged
# PRs even though the pull files REST endpoint still returns the changed files.
# The helper must treat that as a fallback condition, not a parse failure.

set -euo pipefail

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../verify-issue-close-helper.sh"

if [[ ! -f "$HELPER_PATH" ]]; then
	printf 'FAIL: verify-issue-close-helper.sh not found at %s\n' "$HELPER_PATH" >&2
	exit 1
fi

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	printf '## Files to modify\n- EDIT: .agents/scripts/verify-issue-close-helper.sh — robust PR file parsing\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	case "${3:-}" in
	100)
		printf '{"files":null}\n'
		;;
	101)
		printf '{"files":[{"path":".agents/scripts/verify-issue-close-helper.sh"}]}\n'
		;;
	*)
		printf '{"files":[]}\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	case "${3:-}" in
	repos/owner/repo/pulls/100/files)
		printf '.agents/scripts/verify-issue-close-helper.sh\n'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$TMPDIR/gh"
export PATH="$TMPDIR:$PATH"

assert_check_passes() {
	local label="$1"
	local pr_number="$2"

	local output
	if output=$(bash "$HELPER_PATH" check 200 "$pr_number" owner/repo 2>&1); then
		if printf '%s' "$output" | grep -q 'VERIFIED: PR'; then
			PASS=$((PASS + 1))
			printf 'PASS: %s\n' "$label"
		else
			FAIL=$((FAIL + 1))
			printf 'FAIL: %s — missing VERIFIED verdict\n%s\n' "$label" "$output"
		fi
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — helper exited non-zero\n%s\n' "$label" "$output"
	fi
	return 0
}

assert_check_passes "merged PR files null falls back to REST pull files endpoint" 100
assert_check_passes "standard gh pr view files array still parses" 101

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
