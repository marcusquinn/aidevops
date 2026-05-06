#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression tests for dispatch prompt comment metrics reuse and zero-output
# evidence pattern consistency.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlw-comment-metrics-XXXXXX")"
FAKE_BIN="${TEST_TMP}/bin"
GH_CALLS_FILE="${TEST_TMP}/gh-calls"
mkdir -p "$FAKE_BIN" || exit 1

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${GH_CALLS_FILE:?}"
case "$*" in
*'issues/123/comments'*'@tsv'*)
	printf '3\t0\t1\t120\n'
	;;
*'issues/123/comments'*)
	printf '1\n'
	;;
*)
	printf 'unexpected gh call: %s\n' "$*" >&2
	exit 1
	;;
esac
EOF
chmod +x "${FAKE_BIN}/gh" || fail "failed to make fake gh executable"

PATH="${FAKE_BIN}:${PATH}"
export GH_CALLS_FILE

LOGFILE="${TEST_TMP}/pulse.log" \
	CLEAN_ROOM_COMMENT_THRESHOLD=100 \
	CLEAN_ROOM_OPS_COMMENT_THRESHOLD=50 \
	CLEAN_ROOM_ZERO_OUTPUT_COMMENT_THRESHOLD=10 \
	CLEAN_ROOM_COMMENT_CHARS_THRESHOLD=50000 \
	ZERO_OUTPUT_URL_FALLBACK_THRESHOLD=1 \
	FAST_FAIL_STATE_FILE="" \
	_dlw_prepare_prompt_for_launch "123" "owner/repo" "Metric test" "original prompt" >"${TEST_TMP}/prompt"

if [[ "$(<"${TEST_TMP}/prompt")" != *"Previous dispatch attempts"* ]]; then
	fail "prepare prompt did not use precomputed zero-output evidence"
fi

gh_calls="$(wc -l <"$GH_CALLS_FILE" | tr -d '[:space:]')"
if [[ "$gh_calls" != "1" ]]; then
	fail "prepare prompt made ${gh_calls} GitHub calls instead of reusing one metrics fetch"
fi

if [[ "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"worker_noop_zero_output"* || "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"zero[- ]output"* ]]; then
	fail "shared zero-output evidence pattern lost expected alternatives"
fi

printf 'PASS: dispatch prompt reuses comment metrics for zero-output fallback\n'
printf 'PASS: zero-output evidence detection uses one shared pattern\n'
exit 0
