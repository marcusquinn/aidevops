#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_DIR}/.agents/scripts/full-loop-helper.sh"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t full-loop-worktree-gh-shim)
trap 'rm -rf "$TMP"' EXIT

STALE_DIR="${TMP}/runtime-bundles/stale/agents/scripts"
NATIVE_DIR="${TMP}/native"
STALE_LOG="${TMP}/stale.log"
NATIVE_LOG="${TMP}/native.log"
mkdir -p "$STALE_DIR" "$NATIVE_DIR"

cat >"${STALE_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'stale shim selected\n' >>"$STALE_GH_LOG"
exit 0
EOF
chmod +x "${STALE_DIR}/gh"

cat >"${NATIVE_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NATIVE_GH_LOG"
printf '%s\n' '{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"fixture-head","headRefName":"fixture"}'
exit 0
EOF
chmod +x "${NATIVE_DIR}/gh"

set +e
STALE_GH_LOG="$STALE_LOG" NATIVE_GH_LOG="$NATIVE_LOG" \
	PATH="${STALE_DIR}:${NATIVE_DIR}:${PATH}" \
	"$HELPER" pre-merge-gate 42 fixture/repo >/dev/null 2>&1
helper_status=$?
set -e

if [[ -s "$STALE_LOG" ]]; then
	printf 'FAIL: inherited stale gh shim handled a full-loop helper call\n' >&2
	exit 1
fi
if [[ ! -s "$NATIVE_LOG" ]]; then
	printf 'FAIL: worktree gh shim did not forward the helper call to native gh (status=%s)\n' "$helper_status" >&2
	exit 1
fi

printf 'PASS: worktree full-loop helper resolves its sibling gh shim before an inherited stale shim\n'

# The sibling directory may already be inherited later on PATH. Presence is
# not precedence: the helper must still promote it ahead of a stale generation.
: >"$NATIVE_LOG"
set +e
STALE_GH_LOG="$STALE_LOG" NATIVE_GH_LOG="$NATIVE_LOG" \
	PATH="${STALE_DIR}:${NATIVE_DIR}:${REPO_DIR}/.agents/scripts:${PATH}" \
	"$HELPER" pre-merge-gate 42 fixture/repo >/dev/null 2>&1
helper_status=$?
set -e
if [[ -s "$STALE_LOG" || ! -s "$NATIVE_LOG" ]]; then
	printf 'FAIL: sibling gh shim already later on PATH was not promoted (status=%s)\n' "$helper_status" >&2
	exit 1
fi
printf 'PASS: sibling gh shim already later on PATH is promoted ahead of stale shim\n'

# Exercise the real lifecycle gate without network calls or lifecycle writes.
# Successful stderr stays out of JSON; failed stderr survives the refusal.
SCRIPT_DIR="${REPO_DIR}/.agents/scripts"
# shellcheck source=../full-loop-helper-state-lifecycle.sh
source "${REPO_DIR}/.agents/scripts/full-loop-helper-state-lifecycle.sh"
_FULL_LOOP_BOOL_TRUE=true
is_headless() { return 1; }
print_error() { printf '%s\n' "$*" >&2; return 0; }
_linked_issue_trust_blocks_start() {
	local raw_issue="$3"
	if printf '%s\n' "$raw_issue" | jq -e '.state == "open"' >/dev/null 2>&1; then
		return 1
	fi
	_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON="fixture received invalid issue JSON"
	return 0
}
_linked_issue_structural_blocker_reasons() { return 1; }
gh() {
	printf 'fixture shim diagnostic\n' >&2
	if [[ "$GATE_FAIL" == 1 ]]; then
		return 42
	fi
	printf '%s\n' '{"state":"open","labels":[],"assignees":[{"login":"fixture"}],"author_association":"OWNER"}'
	return 0
}
GATE_FAIL=0
if ! _check_linked_issue_gate 'GH#42 fixture' fixture/repo; then
	printf 'FAIL: readable issue with stderr diagnostics did not pass gate\n' >&2
	exit 1
fi
GATE_FAIL=1
if _check_linked_issue_gate 'GH#42 fixture' fixture/repo 2>"${TMP}/gate-error"; then
	printf 'FAIL: failed issue lookup did not fail closed\n' >&2
	exit 1
fi
if ! grep -q 'gh lookup error: fixture shim diagnostic' "${TMP}/gate-error"; then
	printf 'FAIL: lookup refusal lost shim stderr\n' >&2
	exit 1
fi
printf 'PASS: linked issue gate preserves failure stderr and accepts successful JSON\n'
exit 0
