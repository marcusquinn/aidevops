#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-no-orphan.sh — t2548 regression guard.
#
# Asserts that `_ensure_todo_entry_written()` in claim-task-id.sh appends a
# TODO.md entry with ref:GH#NNN after a verified issue creation when the
# task ID is not yet present in TODO.md.
#
# Production failure (t2548):
#   `claim-task-id.sh --title X --description Y` created a GitHub issue
#   (via _try_issue_sync_delegation OR the bare `gh issue create` fallback)
#   but NEVER wrote a TODO.md entry when the task ID wasn't already
#   registered in TODO.md. `_push_process_task` in issue-sync-helper.sh
#   silently returns 0 when `target_task` is missing from TODO.md;
#   `add_gh_ref_to_todo` is a modify-existing-line helper and no-ops.
#   Result: issue created on GitHub, counter bumped, TODO entry never
#   written. Evidence: 4/4 orphans from one ILDS session 2026-04-20
#   (GH#555-558, t135-t138). johnwaldo/ilds had 9 open orphans in the
#   corpus.
#
# Fix (Option A, t2548): idempotent `_ensure_todo_entry_written` helper
# called from `create_github_issue` on both the delegation success path
# and the bare-fallback path. If TODO.md already has the entry, delegates
# to `add_gh_ref_to_todo` to stamp the ref; otherwise appends
# `- [ ] <task_id> <description> <tags> ref:GH#<num>` to the `## Backlog`
# section (EOF fallback if that heading is absent).
#
# Tests:
#   1. Missing entry + no Backlog → appended at EOF with ref
#   2. Missing entry + Backlog section present → appended inside Backlog
#   3. Entry already present → ref stamped, no duplicate added
#   4. Empty labels → no tag suffix, still valid line
#   5. Reserved-prefix labels (status:, tier:, origin:) are skipped
#   6. `bug` / `enhancement` labels map to `#bug` / `#feat` tags
#   7. No TODO.md file → silent no-op (non-fatal)
#
# Cross-references: t2548 (this fix), GH#18352 (dispatch-dedup contract).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2548.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Stub the log/print helpers used by the script so sourcing is quiet.
# shellcheck disable=SC2317
print_info() { return 0; }
# shellcheck disable=SC2317
print_warning() { return 0; }
# shellcheck disable=SC2317
print_error() { return 0; }
# shellcheck disable=SC2317
print_success() { return 0; }
# shellcheck disable=SC2317
log_verbose() { return 0; }
# shellcheck disable=SC2317
log_info() { return 0; }
# shellcheck disable=SC2317
log_warn() { return 0; }
# shellcheck disable=SC2317
log_error() { return 0; }
# shellcheck disable=SC2317
log_success() { return 0; }
export -f print_info print_warning print_error print_success \
	log_verbose log_info log_warn log_error log_success

# shellcheck source=../claim-task-id.sh
source "${SCRIPTS_DIR}/claim-task-id.sh" >/dev/null 2>&1 || true

# Sanity: the helper must exist after sourcing.
if ! declare -F _ensure_todo_entry_written >/dev/null 2>&1; then
	printf '%sFATAL%s _ensure_todo_entry_written not defined after sourcing claim-task-id.sh\n' \
		"$TEST_RED" "$TEST_NC"
	exit 1
fi

printf '%sRunning _ensure_todo_entry_written tests (t2548)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Missing entry + no Backlog section → appended at EOF
# =============================================================================
REPO1="${TMP}/repo1"
mkdir -p "$REPO1"
cat >"${REPO1}/TODO.md" <<'EOF'
# Project TODO

## Ready

- [ ] t001 pre-existing ref:GH#1

## Done

- [x] t000 historical ref:GH#0
EOF

_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "bug,auto-dispatch,tier:standard" "$REPO1"

if grep -qE "^- \[ \] t2548 fix orphan bug .*ref:GH#20180" "${REPO1}/TODO.md"; then
	pass "missing entry + no Backlog → appended at EOF with ref:GH#20180"
else
	fail "missing entry + no Backlog → appended at EOF with ref:GH#20180" \
		"TODO.md after:\n$(cat "${REPO1}/TODO.md")"
fi

# Tier/status/origin labels skipped; auto-dispatch & bug become tags.
if grep -qE "^- \[ \] t2548 fix orphan bug #bug #auto-dispatch ref:GH#20180$" "${REPO1}/TODO.md"; then
	pass "reserved-prefix labels (tier:/status:/origin:) filtered from tag list"
else
	fail "reserved-prefix labels filtered" \
		"line: $(grep 't2548' "${REPO1}/TODO.md" || echo '(no match)')"
fi

# =============================================================================
# Test 2 — Missing entry + Backlog section → appended inside Backlog
# =============================================================================
REPO2="${TMP}/repo2"
mkdir -p "$REPO2"
cat >"${REPO2}/TODO.md" <<'EOF'
# Project TODO

## Ready

- [ ] t001 ready task ref:GH#1

## Backlog

- [ ] t002 backlog task ref:GH#2

## Done

- [x] t000 historical ref:GH#0
EOF

_ensure_todo_entry_written "t2548" "20180" "fix orphan" "bug" "$REPO2"

# Line must appear AFTER the ## Backlog heading and BEFORE ## Done.
BACKLOG_LINE=$(grep -nE '^## Backlog' "${REPO2}/TODO.md" | head -1 | cut -d: -f1)
T2548_LINE=$(grep -nE '^- \[ \] t2548' "${REPO2}/TODO.md" | head -1 | cut -d: -f1)
DONE_LINE=$(grep -nE '^## Done' "${REPO2}/TODO.md" | head -1 | cut -d: -f1)

if [[ -n "$BACKLOG_LINE" && -n "$T2548_LINE" && -n "$DONE_LINE" ]] \
	&& [[ "$T2548_LINE" -gt "$BACKLOG_LINE" && "$T2548_LINE" -lt "$DONE_LINE" ]]; then
	pass "missing entry + Backlog section → inserted between ## Backlog and ## Done"
else
	fail "missing entry + Backlog section → inserted between ## Backlog and ## Done" \
		"BACKLOG_LINE=${BACKLOG_LINE} T2548_LINE=${T2548_LINE} DONE_LINE=${DONE_LINE}"
fi

# =============================================================================
# Test 3 — Entry already present → ref stamped, no duplicate added
# =============================================================================
REPO3="${TMP}/repo3"
mkdir -p "$REPO3"
cat >"${REPO3}/TODO.md" <<'EOF'
# Project TODO

## Backlog

- [ ] t2548 pre-existing manual entry
EOF

_ensure_todo_entry_written "t2548" "20180" "ignored description" "bug" "$REPO3"

T2548_COUNT=$(grep -cE '^- \[ \] t2548' "${REPO3}/TODO.md" 2>/dev/null || echo 0)
if [[ "$T2548_COUNT" == "1" ]]; then
	pass "entry already present → no duplicate added"
else
	fail "entry already present → no duplicate added" \
		"found ${T2548_COUNT} t2548 lines:\n$(grep 't2548' "${REPO3}/TODO.md" || echo '(none)')"
fi

if grep -qE '^- \[ \] t2548 pre-existing manual entry.*ref:GH#20180' "${REPO3}/TODO.md"; then
	pass "entry already present → ref:GH#20180 stamped via add_gh_ref_to_todo"
else
	fail "entry already present → ref:GH#20180 stamped via add_gh_ref_to_todo" \
		"line: $(grep 't2548' "${REPO3}/TODO.md" || echo '(no match)')"
fi

# =============================================================================
# Test 4 — Empty labels → no tag suffix, still valid line
# =============================================================================
REPO4="${TMP}/repo4"
mkdir -p "$REPO4"
printf '# TODO\n\n## Backlog\n\n' >"${REPO4}/TODO.md"

_ensure_todo_entry_written "t2548" "20180" "no tags" "" "$REPO4"

if grep -qE "^- \[ \] t2548 no tags ref:GH#20180$" "${REPO4}/TODO.md"; then
	pass "empty labels → no tag suffix, ref appended directly"
else
	fail "empty labels → no tag suffix, ref appended directly" \
		"line: $(grep 't2548' "${REPO4}/TODO.md" || echo '(no match)')"
fi

# =============================================================================
# Test 5 — `bug` / `enhancement` labels map to `#bug` / `#feat`
# =============================================================================
REPO5="${TMP}/repo5"
mkdir -p "$REPO5"
printf '# TODO\n\n## Backlog\n\n' >"${REPO5}/TODO.md"

_ensure_todo_entry_written "t2548" "20180" "label mapping" "bug,enhancement,framework" "$REPO5"

if grep -qE "^- \[ \] t2548 label mapping #bug #feat #framework ref:GH#20180$" "${REPO5}/TODO.md"; then
	pass "bug→#bug, enhancement→#feat, passthrough tags preserved"
else
	fail "bug→#bug, enhancement→#feat, passthrough tags preserved" \
		"line: $(grep 't2548' "${REPO5}/TODO.md" || echo '(no match)')"
fi

# =============================================================================
# Test 6 — No TODO.md file → silent no-op (non-fatal)
# =============================================================================
REPO6="${TMP}/repo6"
mkdir -p "$REPO6"

if _ensure_todo_entry_written "t2548" "20180" "desc" "bug" "$REPO6"; then
	pass "no TODO.md file → non-fatal no-op, exit 0"
else
	fail "no TODO.md file → non-fatal no-op, exit 0" \
		"helper returned non-zero when TODO.md missing"
fi

if [[ ! -f "${REPO6}/TODO.md" ]]; then
	pass "no TODO.md file → file not created"
else
	fail "no TODO.md file → file not created" \
		"TODO.md was created unexpectedly"
fi

# =============================================================================
# Test 7 — Empty task_id or issue_num → non-fatal no-op
# =============================================================================
REPO7="${TMP}/repo7"
mkdir -p "$REPO7"
printf '# TODO\n\n## Backlog\n\n' >"${REPO7}/TODO.md"
ORIG_CONTENT=$(cat "${REPO7}/TODO.md")

_ensure_todo_entry_written "" "20180" "desc" "bug" "$REPO7"
_ensure_todo_entry_written "t2548" "" "desc" "bug" "$REPO7"

NEW_CONTENT=$(cat "${REPO7}/TODO.md")
if [[ "$ORIG_CONTENT" == "$NEW_CONTENT" ]]; then
	pass "empty task_id or issue_num → TODO.md unchanged"
else
	fail "empty task_id or issue_num → TODO.md unchanged" \
		"TODO.md was mutated with empty inputs"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
