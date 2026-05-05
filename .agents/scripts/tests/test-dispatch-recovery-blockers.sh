#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '     %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t dispatch-recovery.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

old_epoch=$(($(date -u +%s) - 1200))
old_iso=$(date -u -r "$old_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${old_epoch}" +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"issues/123/comments"* ]]; then
  cat <<JSON
[
  {
    "body": "<!-- ops:start -->\nDispatching worker (deterministic).\n- **Worker PID**: 99999\n- **Issue**: #123\n<!-- ops:end -->",
    "user": {"login": "self-runner"},
    "created_at": "${old_iso}"
  }
]
JSON
  exit 0
fi
exit 1
EOF
chmod +x "${TMP}/bin/gh"

PATH="${TMP}/bin:${PATH}" \
	DISPATCH_COMMENT_MAX_AGE=600 \
	DISPATCH_ACTIVE_WORKER_MAX_AGE=7200 \
	"${SCRIPTS_DIR}/dispatch-dedup-helper.sh" has-dispatch-comment 123 owner/repo self-runner \
	>"${TMP}/dispatch.out" 2>"${TMP}/dispatch.err"
dispatch_rc=$?

if [[ "$dispatch_rc" -eq 1 ]]; then
	pass "self-authored non-terminal dispatch comment is ignored after soft TTL when no local worker exists"
else
	fail "self-authored non-terminal dispatch comment is ignored after soft TTL when no local worker exists" \
		"expected rc=1, got rc=${dispatch_rc}; out=$(cat "${TMP}/dispatch.out" 2>/dev/null); err=$(cat "${TMP}/dispatch.err" 2>/dev/null)"
fi

if grep -q 'worker_launch_rc_\*' "${SCRIPTS_DIR}/pulse-dispatch-core.sh"; then
	pass "all worker_launch_rc pre-launch aborts delete/release dispatch claims"
else
	fail "all worker_launch_rc pre-launch aborts delete/release dispatch claims" \
		"expected worker_launch_rc_* pattern in pulse-dispatch-core.sh"
fi

active_line=$(grep -n 'has active dispatch comment.*active claim' "${SCRIPTS_DIR}/pulse-dispatch-lib.sh" | cut -d: -f1 | head -1)
block_line=$(grep -n 'DISPATCH_BLOCK_REASON reason=' "${SCRIPTS_DIR}/pulse-dispatch-lib.sh" | cut -d: -f1 | head -1)
if [[ -n "$active_line" && -n "$block_line" && "$active_line" -lt "$block_line" ]]; then
	pass "dedup-active evidence takes precedence over stale historical block reasons"
else
	fail "dedup-active evidence takes precedence over stale historical block reasons" \
		"active_line=${active_line:-missing}, block_line=${block_line:-missing}"
fi

echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
