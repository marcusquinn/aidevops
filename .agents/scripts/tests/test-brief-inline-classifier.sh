#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-brief-inline-classifier.sh — regression tests for t2063
#
# Covers the brief-first inlining contract for issue bodies:
#
#   1. claim-task-id.sh `_compose_issue_body`: when a brief file exists at
#      `todo/tasks/{task_id}-brief.md`, the composed body MUST contain the
#      `## Task Brief` section inlined, regardless of whether a --description
#      was passed. The body must also end with the shared sentinel footer so
#      `_enrich_update_issue` recognises it as framework-generated.
#
#   2. issue-sync-helper.sh `_enrich_update_issue`: the body-update decision
#      tree is driven by brief-file presence, not body length:
#        - Case 1 (brief exists)               → refresh body (unless no-op)
#        - Case 2 (no brief, has sentinel)     → refresh on diff (existing)
#        - Case 3 (no brief, no sentinel)      → preserve body (existing)
#
#   3. issue-sync-lib.sh `_compose_issue_worker_guidance`: heading match is
#      case-insensitive, so lowercase `### files to modify` still activates
#      Worker Guidance extraction.
#
# Strategy:
#   - Source the libs with stubbed logging helpers.
#   - For claim-task-id paths, synthesise a temp repo with a brief file and
#     call `_compose_issue_body` directly; assert on the returned body text.
#   - For enrich classifier, install a stubbed `gh` on PATH that records
#     `gh issue edit` calls, then call `_enrich_update_issue` with each case
#     and assert whether `--body` was passed.

set -u
# Disable -e so sourced scripts' set -euo pipefail don't kill the test on
# expected non-zero returns (e.g. Test C5 _compose_issue_body stub refusal).
set +e

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
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
LIB="${SCRIPTS_DIR}/issue-sync-lib.sh"
CLAIM="${SCRIPTS_DIR}/claim-task-id.sh"
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"

for f in "$LIB" "$CLAIM" "$HELPER"; do
	if [[ ! -f "$f" ]]; then
		printf 'test harness cannot find %s\n' "$f" >&2
		exit 1
	fi
done

TMP=$(mktemp -d -t t2063-brief-inline.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubs for sourcing libs standalone
# -----------------------------------------------------------------------------

print_warning() { :; }
print_info() { :; }
print_error() { :; }
print_success() { :; }
log_verbose() { :; }
log_info() { :; }
log_error() { :; }
log_warn() { :; }
export -f print_warning print_info print_error print_success log_verbose log_info log_error log_warn

# Source issue-sync-lib.sh for composition helpers
# shellcheck source=../issue-sync-lib.sh
source "$LIB" >/dev/null 2>&1 || true

printf '%sRunning t2063 brief inline classifier tests%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Class A: _compose_issue_worker_guidance case-insensitive heading match
# =============================================================================

printf '\n%sClass A: case-insensitive heading match%s\n' "$TEST_BLUE" "$TEST_NC"

# Test A1: canonical casing (sanity — should still work)
cat >"$TMP/brief-canonical.md" <<'BRIEF'
# t9001: canonical brief

## What
Canonical task.

## How

### Files to Modify
- EDIT: foo.sh

### Verification
echo ok
BRIEF

result=$(_compose_issue_worker_guidance "base body" "$TMP/brief-canonical.md")
if [[ "$result" == *"## Worker Guidance"* ]]; then
	pass "A1 canonical ### Files to Modify activates Worker Guidance extraction"
else
	fail "A1 canonical heading extraction" \
		"expected '## Worker Guidance' in output"
fi

# Test A2: lowercase heading (the t2063 fragility)
cat >"$TMP/brief-lowercase.md" <<'BRIEF'
# t9002: lowercase brief

## What
Lowercase task.

## How

### files to modify
- EDIT: bar.sh

### verification
echo ok
BRIEF

result=$(_compose_issue_worker_guidance "base body" "$TMP/brief-lowercase.md")
if [[ "$result" == *"## Worker Guidance"* ]]; then
	pass "A2 lowercase ### files to modify activates Worker Guidance (case-insensitive)"
else
	fail "A2 case-insensitive heading extraction" \
		"expected '## Worker Guidance' in output — case-insensitive match failed"
fi

# Test A3: no brief file → returns input unchanged
result=$(_compose_issue_worker_guidance "base body" "$TMP/nonexistent.md")
if [[ "$result" == "base body" ]]; then
	pass "A3 no brief file returns input body unchanged"
else
	fail "A3 no brief file" "expected 'base body', got '$result'"
fi

# =============================================================================
# Class B: _compose_issue_brief inlining (full brief append)
# =============================================================================

printf '\n%sClass B: _compose_issue_brief full brief append%s\n' "$TEST_BLUE" "$TEST_NC"

# Test B1: brief with frontmatter → frontmatter stripped, content appended
cat >"$TMP/brief-with-frontmatter.md" <<'BRIEF'
---
mode: subagent
---

# t9003: brief with frontmatter

## What
Test frontmatter stripping.
BRIEF

result=$(_compose_issue_brief "base body" "$TMP/brief-with-frontmatter.md")
if [[ "$result" == *"## Task Brief"* ]] && [[ "$result" != *"mode: subagent"* ]]; then
	pass "B1 full brief appended with frontmatter stripped"
else
	fail "B1 frontmatter strip + append" \
		"expected '## Task Brief' present and 'mode: subagent' absent"
fi

# =============================================================================
# Class C: claim-task-id _compose_issue_body brief-first inlining (t2063)
# =============================================================================

printf '\n%sClass C: claim-task-id brief-first inlining%s\n' "$TEST_BLUE" "$TEST_NC"

# Source claim-task-id.sh to get _compose_issue_body. Claim script has its
# own set -euo pipefail and executes main(); we need to source the function
# definitions without running main(). The script gates main() on BASH_SOURCE
# vs $0 check (t2063) — sourcing is safe.
#
# IMPORTANT: claim-task-id.sh sets REPO_PATH="$PWD" at source-time (line 92),
# which OVERRIDES any value we set here. We therefore set REPO_PATH AFTER
# sourcing, and point it at a TMP fakerepo so test briefs don't pollute the
# real worktree.
# shellcheck source=../claim-task-id.sh
source "$CLAIM" >/dev/null 2>&1 || true
# Re-disable -e after sourcing in case the sourced script enabled it.
set +e

# Override REPO_PATH AFTER sourcing to point at an isolated TMP fakerepo.
REPO_PATH="$TMP/fakerepo"
mkdir -p "$REPO_PATH/todo/tasks"
export REPO_PATH

# Test C1: brief exists + --description provided → body contains both
cat >"$REPO_PATH/todo/tasks/t9010-brief.md" <<'BRIEF'
---
mode: subagent
---

# t9010: test task

## What
The deliverable.

## How

### Files to Modify
- EDIT: foo.sh — add the thing
BRIEF

result=$(_compose_issue_body "t9010: test task title" "terse caller description" 2>/dev/null)
rc=$?

if [[ $rc -eq 0 ]] && [[ "$result" == *"terse caller description"* ]] && [[ "$result" == *"## Task Brief"* ]]; then
	pass "C1 brief exists + description → body contains both summary and brief"
else
	fail "C1 brief + description inlining" \
		"rc=$rc, contains description: $([[ "$result" == *"terse caller description"* ]] && echo yes || echo no), contains ## Task Brief: $([[ "$result" == *"## Task Brief"* ]] && echo yes || echo no)"
fi

# Test C2: brief exists, no description → body contains What section + brief
result=$(_compose_issue_body "t9010: test task title" "" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]] && [[ "$result" == *"The deliverable"* ]] && [[ "$result" == *"## Task Brief"* ]]; then
	pass "C2 brief exists + no description → What section + brief inlined"
else
	fail "C2 brief What fallback inlining" \
		"rc=$rc, contains 'The deliverable': $([[ "$result" == *"The deliverable"* ]] && echo yes || echo no)"
fi

# Test C3: brief exists → body contains sentinel footer (so enrich can refresh)
result=$(_compose_issue_body "t9010: test task title" "terse" 2>/dev/null)
if [[ "$result" == *"Synced from TODO.md by issue-sync-helper.sh"* ]]; then
	pass "C3 brief-composed body contains sentinel footer for future enrichment"
else
	fail "C3 sentinel footer present" \
		"expected 'Synced from TODO.md by issue-sync-helper.sh' in body"
fi

# Test C4: no brief + description → body is description verbatim (fallback path)
result=$(_compose_issue_body "t9011: other task" "just a description" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]] && [[ "$result" == *"just a description"* ]] && [[ "$result" != *"## Task Brief"* ]]; then
	pass "C4 no brief + description → description-only body (fallback)"
else
	fail "C4 no-brief fallback" \
		"rc=$rc, unexpected content"
fi

# Test C5: no brief + no description → returns empty + non-zero rc (t1937)
result=$(_compose_issue_body "t9012: missing" "" 2>/dev/null)
rc=$?
if [[ $rc -ne 0 ]] && [[ -z "$result" ]]; then
	pass "C5 no brief + no description → empty body, non-zero rc (stub refusal)"
else
	fail "C5 stub refusal" \
		"rc=$rc, result='$result'"
fi

# =============================================================================
# Class D: _enrich_update_issue brief-first classifier (t2063)
# =============================================================================

printf '\n%sClass D: _enrich_update_issue brief-first classifier%s\n' "$TEST_BLUE" "$TEST_NC"

# Install a stubbed `gh` on PATH that records calls to /tmp/gh-calls.log
# and returns canned JSON for issue view.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
GH_CALLS_LOG="$TMP/gh-calls.log"
: >"$GH_CALLS_LOG"

cat >"$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GH_CALLS_LOG"
# Return the current body from a test-controlled file
if [[ "\$*" == *"issue view"* && "\$*" == *"--json body"* ]]; then
	cat "$TMP/current-body.txt" 2>/dev/null || echo ""
	exit 0
fi
# issue edit → success
exit 0
EOF
chmod +x "$STUB_BIN/gh"
PATH="$STUB_BIN:$PATH"
export PATH

# Source issue-sync-helper.sh (which uses issue-sync-lib.sh already sourced).
# The helper defines _enrich_update_issue at the top level.
# NOTE: the helper prepends /usr/local/bin:/usr/bin:/bin to PATH on line 29,
# which shadows our stub. We re-prepend $STUB_BIN AFTER sourcing to restore it.
# shellcheck source=../issue-sync-helper.sh
source "$HELPER" >/dev/null 2>&1 || true
PATH="$STUB_BIN:$PATH"
export PATH

# Setup for Class D tests — simulate PROJECT_ROOT + brief paths
D_REPO_ROOT="$TMP/drepo"
mkdir -p "$D_REPO_ROOT/todo/tasks"
export PROJECT_ROOT="$D_REPO_ROOT"

# Helper: count edit calls that include --body. Uses awk so grep -c non-match
# (rc=1) doesn't produce two "0" lines via || fallback.
_count_body_edits() {
	awk '/--body/ {n++} END {print n+0}' "$GH_CALLS_LOG"
}
# Helper: reset call log
_reset_calls() {
	: >"$GH_CALLS_LOG"
}

# Test D1: brief exists → body refreshed (--body passed)
_reset_calls
echo "old stub body" >"$TMP/current-body.txt"
cat >"$D_REPO_ROOT/todo/tasks/t9020-brief.md" <<'BRIEF'
# t9020: brief for enrich test
## What
Thing.
BRIEF

FORCE_ENRICH=false _enrich_update_issue "owner/repo" 9020 "t9020" "t9020: title" "new rich body" >/dev/null 2>&1 || true

if [[ "$(_count_body_edits)" -ge 1 ]]; then
	pass "D1 brief exists → body refreshed (edit with --body called)"
else
	fail "D1 brief-exists refresh" \
		"expected --body in gh calls, none found: $(cat "$GH_CALLS_LOG" 2>/dev/null)"
fi

# Test D2: brief exists AND body matches → no-op (no --body call)
_reset_calls
echo "already correct" >"$TMP/current-body.txt"
FORCE_ENRICH=false _enrich_update_issue "owner/repo" 9020 "t9020" "t9020: title" "already correct" >/dev/null 2>&1 || true

if [[ "$(_count_body_edits)" -eq 0 ]]; then
	pass "D2 brief exists + body unchanged → no-op skip"
else
	fail "D2 brief no-op skip" \
		"expected no --body call, found: $(cat "$GH_CALLS_LOG" 2>/dev/null)"
fi

# Test D3: no brief, has sentinel → refresh on diff (existing behaviour)
_reset_calls
rm -f "$D_REPO_ROOT/todo/tasks/t9021-brief.md"
echo "old body
*Synced from TODO.md by issue-sync-helper.sh*" >"$TMP/current-body.txt"
FORCE_ENRICH=false _enrich_update_issue "owner/repo" 9021 "t9021" "t9021: title" "new body with content" >/dev/null 2>&1 || true

if [[ "$(_count_body_edits)" -ge 1 ]]; then
	pass "D3 no brief + has sentinel → refresh on diff"
else
	fail "D3 sentinel refresh" \
		"expected --body call, none found"
fi

# Test D4: no brief, no sentinel → preserve (existing behaviour)
_reset_calls
rm -f "$D_REPO_ROOT/todo/tasks/t9022-brief.md"
echo "genuine external bug report body" >"$TMP/current-body.txt"
FORCE_ENRICH=false _enrich_update_issue "owner/repo" 9022 "t9022" "t9022: title" "composed body" >/dev/null 2>&1 || true

if [[ "$(_count_body_edits)" -eq 0 ]]; then
	pass "D4 no brief + no sentinel → preserve external body"
else
	fail "D4 preserve external" \
		"expected no --body call, found: $(cat "$GH_CALLS_LOG" 2>/dev/null)"
fi

# Test D5: FORCE_ENRICH=true bypasses all gates
_reset_calls
echo "anything" >"$TMP/current-body.txt"
FORCE_ENRICH=true _enrich_update_issue "owner/repo" 9023 "t9023" "t9023: title" "forced new body" >/dev/null 2>&1 || true

if [[ "$(_count_body_edits)" -ge 1 ]]; then
	pass "D5 FORCE_ENRICH=true bypasses all gates"
else
	fail "D5 force enrich" \
		"expected --body call, none found"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s✓ All %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s✗ %d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
