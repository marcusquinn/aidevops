#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-issue-reconcile.sh — t2005 regression guard.
#
# Asserts the Phase 12 split of normalize_active_issue_assignments works
# correctly by testing the three extracted helpers independently:
#
#   1. _normalize_reassign_self assigns runner to orphaned active issues
#      (status:queued/in-progress, no assignee) and skips issues already
#      claimed by another runner (dedup guard).
#
#   2. _normalize_clear_status_labels calls gh with the correct flags to
#      remove assignee + active labels and add status:available.
#
#   3. _normalize_unassign_stale skips issues whose local worker log was
#      recently written (active worker guard).
#
# Pattern mirrors test-parent-task-guard.sh: stub gh, source the module,
# call helpers directly, assert outcomes.
#
# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits. Each assertion explicitly captures exit codes.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# =============================================================================
# Environment setup
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Minimal constants required by pulse-issue-reconcile.sh function calls
export LOGFILE="/dev/null"
export PULSE_QUEUED_SCAN_LIMIT=50
export WORKER_MAX_RUNTIME=10800

# Minimal repos.json with one pulse-enabled repo
export REPOS_JSON="${TEST_ROOT}/repos.json"
cat >"$REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":"owner/testrepo","path":"/tmp/testrepo","pulse":true,"local_only":false}],"git_parent_dirs":[]}
EOF

# Stub directory — prepended to PATH
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# =============================================================================
# Source the module under test
# =============================================================================
# t2033: pulse-issue-reconcile.sh uses set_issue_status from shared-constants.sh.
# Source shared-constants first so the helper is defined, matching the
# pulse-wrapper.sh orchestrator sourcing order.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1
# pulse-issue-reconcile.sh has an include guard; clear it so we can source
# it directly without the full pulse-wrapper.sh bootstrap.
unset _PULSE_ISSUE_RECONCILE_LOADED
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-issue-reconcile.sh" >/dev/null 2>&1
set +e

# =============================================================================
# Part 1 — _normalize_reassign_self: self-assigns orphaned active issues
# =============================================================================
# Stub gh:
#   - issue list → one issue (#42) with status:queued, no assignees
#   - api user   → runner_user = "testrunner"
#   - issue edit → record args
GH_EDIT_ARGS_FILE="${TEST_ROOT}/gh_edit_args"
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "user" ]]; then
    echo '{"login":"testrunner"}'
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
    echo '[{"number":42,"assignees":[],"labels":[{"name":"status:queued"},{"name":"tier:standard"}]}]'
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
    echo "\$*" >> "${GH_EDIT_ARGS_FILE}"
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

# No dedup helper available (path won't exist) → assignment proceeds unconditionally
OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

rm -f "$GH_EDIT_ARGS_FILE"
_normalize_reassign_self "testrunner" "$REPOS_JSON" "/nonexistent/dispatch-dedup-helper.sh"

if [[ -f "$GH_EDIT_ARGS_FILE" ]] && grep -q -- "--add-assignee testrunner" "$GH_EDIT_ARGS_FILE"; then
	print_result "_normalize_reassign_self assigns runner to orphaned active issue" 0
else
	print_result "_normalize_reassign_self assigns runner to orphaned active issue" 1 \
		"(edit args: $(cat "$GH_EDIT_ARGS_FILE" 2>/dev/null || echo 'file missing'))"
fi

# =============================================================================
# Part 2 — _normalize_reassign_self: skips issues claimed by another runner
# =============================================================================
# Stub dedup helper that claims the issue is already assigned (exit 0 = blocked)
DEDUP_STUB="${TEST_ROOT}/dedup-dedup-helper.sh"
cat >"$DEDUP_STUB" <<'STUB'
#!/usr/bin/env bash
# Simulate: another runner already owns this issue
echo "ASSIGNED:otherrunner"
exit 0
STUB
chmod +x "$DEDUP_STUB"

rm -f "$GH_EDIT_ARGS_FILE"
_normalize_reassign_self "testrunner" "$REPOS_JSON" "$DEDUP_STUB"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "--add-assignee testrunner" "$GH_EDIT_ARGS_FILE"; then
	print_result "_normalize_reassign_self skips issue already claimed by another runner" 0
else
	print_result "_normalize_reassign_self skips issue already claimed by another runner" 1 \
		"(edit args: $(cat "$GH_EDIT_ARGS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Part 3 — _normalize_clear_status_labels: emits correct gh flags
# =============================================================================
rm -f "$GH_EDIT_ARGS_FILE"
_normalize_clear_status_labels "99" "owner/testrepo" "testrunner"

if [[ -f "$GH_EDIT_ARGS_FILE" ]]; then
	EDIT_ARGS=$(cat "$GH_EDIT_ARGS_FILE")
	if echo "$EDIT_ARGS" | grep -q -- "--remove-assignee testrunner" &&
		echo "$EDIT_ARGS" | grep -q -- "--remove-label status:queued" &&
		echo "$EDIT_ARGS" | grep -q -- "--add-label status:available"; then
		print_result "_normalize_clear_status_labels calls gh with correct flags" 0
	else
		print_result "_normalize_clear_status_labels calls gh with correct flags" 1 \
			"(got: '$EDIT_ARGS')"
	fi
else
	print_result "_normalize_clear_status_labels calls gh with correct flags" 1 \
		"(gh was not called — edit args file missing)"
fi

# =============================================================================
# Part 4 — _normalize_unassign_stale: active log file guards against reset
# =============================================================================
# Stub gh issue list (stale candidate) and gh api (dispatch comment has no PID)
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
    # Issue #77: assigned to testrunner, status:queued, updated 2h ago
    echo '[{"number":77,"labels":[{"name":"status:queued"}],"updatedAt":"2020-01-01T00:00:00Z"}]'
    exit 0
fi
if [[ "\$1" == "api" ]]; then
    # No dispatch comment found
    echo '[]'
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
    echo "\$*" >> "${GH_EDIT_ARGS_FILE}"
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

# Create a worker log with current timestamp (active guard should fire: < 600s old)
# slug "owner/testrepo" → tr '/:' '--' → "owner-testrepo"
SAFE_SLUG="owner-testrepo"
WORKER_LOG="/tmp/pulse-${SAFE_SLUG}-77.log"
touch "$WORKER_LOG"

rm -f "$GH_EDIT_ARGS_FILE"
NOW_EPOCH=$(date +%s)
_normalize_unassign_stale "testrunner" "$REPOS_JSON" "$NOW_EPOCH" "10800"

rm -f "$WORKER_LOG"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "--remove-assignee testrunner" "$GH_EDIT_ARGS_FILE"; then
	print_result "_normalize_unassign_stale skips issue with recently-written worker log" 0
else
	print_result "_normalize_unassign_stale skips issue with recently-written worker log" 1 \
		"(should not have reset — log was fresh but edit was called)"
fi

# =============================================================================
# Part 5 (t2148) — _normalize_unassign_stampless_interactive:
# Positive case: origin:interactive + assigned + no stamp + updated >24h ago
# → should call `gh issue edit --remove-assignee`.
# =============================================================================
# Reset gh stub to emit a stampless-interactive candidate (#555) updated long
# ago. The helper filters on `updatedAt < (now - threshold)` server-side via jq.
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
    echo '[{"number":555,"updatedAt":"2020-01-01T00:00:00Z"}]'
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
    echo "\$*" >> "${GH_EDIT_ARGS_FILE}"
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

# Ensure no stamp exists for #555 in the stamp dir convention used by the helper
STAMP_DIR="${HOME}/.aidevops/.agent-workspace/interactive-claims"
mkdir -p "$STAMP_DIR"
rm -f "${STAMP_DIR}/owner-testrepo-555.json"

rm -f "$GH_EDIT_ARGS_FILE"
NOW_EPOCH_P5=$(date +%s)
_normalize_unassign_stampless_interactive "testrunner" "$REPOS_JSON" "$NOW_EPOCH_P5" "86400"

if [[ -f "$GH_EDIT_ARGS_FILE" ]] && grep -q -- "--remove-assignee testrunner" "$GH_EDIT_ARGS_FILE" &&
	grep -q -- "issue edit 555" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2148: _normalize_unassign_stampless_interactive unassigns stampless claim >24h old" 0
else
	print_result "t2148: _normalize_unassign_stampless_interactive unassigns stampless claim >24h old" 1 \
		"(edit args: $(cat "$GH_EDIT_ARGS_FILE" 2>/dev/null || echo 'file missing'))"
fi

# =============================================================================
# Part 6 (t2148) — negative case: stamp present → do NOT unassign.
# The stamp indicates a genuine interactive session owns the claim; scan-stale
# Phase 1 handles these via dead-PID + missing-worktree detection.
# =============================================================================
# Write a stamp for #555 using the flattened slug convention
jq -n '{
	issue: 555, slug: "owner/testrepo", worktree_path: "/tmp/wt",
	claimed_at: "2026-01-01T00:00:00Z", pid: 1, hostname: "h", user: "testrunner"
}' >"${STAMP_DIR}/owner-testrepo-555.json"

rm -f "$GH_EDIT_ARGS_FILE"
_normalize_unassign_stampless_interactive "testrunner" "$REPOS_JSON" "$NOW_EPOCH_P5" "86400"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "--remove-assignee testrunner" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2148: stampless auto-recovery skips issues with a stamp file" 0
else
	print_result "t2148: stampless auto-recovery skips issues with a stamp file" 1 \
		"(should not have unassigned — stamp exists but gh edit was called)"
fi

# Clean up
rm -f "${STAMP_DIR}/owner-testrepo-555.json"

# =============================================================================
# Part 7 (t2148) — age-threshold guard: recently-updated issues are not touched
# even when no stamp exists, to protect work just begun.
# =============================================================================
# Override stub to return a RECENT updatedAt (now, so it's younger than threshold)
RECENT_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
    echo "[{\"number\":556,\"updatedAt\":\"${RECENT_ISO}\"}]"
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
    echo "\$*" >> "${GH_EDIT_ARGS_FILE}"
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

rm -f "$GH_EDIT_ARGS_FILE"
_normalize_unassign_stampless_interactive "testrunner" "$REPOS_JSON" "$NOW_EPOCH_P5" "86400"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "issue edit 556" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2148: stampless auto-recovery respects age threshold (recent → skip)" 0
else
	print_result "t2148: stampless auto-recovery respects age threshold (recent → skip)" 1 \
		"(issue 556 was too recent but was unassigned anyway)"
fi

# =============================================================================
# Part 8 (t2372) — _normalize_unassign_stale: default threshold (600s) resets
# an issue whose updatedAt is older than the cutoff.
#
# Stubs:
#   gh issue list  → one candidate (#12301) with a fixed updatedAt of
#                    2020-01-01T00:00:00Z (epoch 1577836800).
#   gh api ...     → [] (no dispatch comment, so inner skip check 2 is inert).
#
# Harness:
#   now_epoch = 1577836800 + 900  (makes the issue appear 15 min "old")
#   default STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS = 600 (10 min)
#   → cutoff = 1577837700 - 600 = 1577837100; updatedAt < cutoff → INCLUDED.
#   No worker log exists → inner skip check 3 is inert.
#   High issue number (12301) → pgrep pattern won't match local processes.
#
# Expected: _normalize_clear_status_labels is invoked, emitting
# `gh issue edit 12301 ... --remove-assignee testrunner`.
# =============================================================================
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
    echo '[{"number":12301,"labels":[{"name":"status:queued"}],"updatedAt":"2020-01-01T00:00:00Z"}]'
    exit 0
fi
if [[ "\$1" == "api" ]]; then
    echo '[]'
    exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
    echo "\$*" >> "${GH_EDIT_ARGS_FILE}"
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

# Guarantee no worker log exists for #12301 so inner skip check 3 is inert.
rm -f "/tmp/pulse-owner-testrepo-12301.log"

rm -f "$GH_EDIT_ARGS_FILE"
unset STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS
NOW_EPOCH_15MIN=1577837700  # 2020-01-01T00:00:00Z + 900s
_normalize_unassign_stale "testrunner" "$REPOS_JSON" "$NOW_EPOCH_15MIN" "10800"

if [[ -f "$GH_EDIT_ARGS_FILE" ]] &&
	grep -q -- "--remove-assignee testrunner" "$GH_EDIT_ARGS_FILE" &&
	grep -q -- "issue edit 12301" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2372: default 600s threshold resets issue with updatedAt 15 min ago" 0
else
	print_result "t2372: default 600s threshold resets issue with updatedAt 15 min ago" 1 \
		"(edit args: $(cat "$GH_EDIT_ARGS_FILE" 2>/dev/null || echo 'file missing'))"
fi

# =============================================================================
# Part 9 (t2372) — _normalize_unassign_stale: default threshold (600s) skips
# an issue whose updatedAt is newer than the cutoff.
#
# Same stub output, but now_epoch = updatedAt + 300s, so the issue is 5 min
# "old" — younger than the 10 min default cutoff. The jq filter excludes it
# server-side; _normalize_clear_status_labels is never invoked.
# =============================================================================
rm -f "$GH_EDIT_ARGS_FILE"
unset STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS
NOW_EPOCH_5MIN=1577837100  # 2020-01-01T00:00:00Z + 300s
_normalize_unassign_stale "testrunner" "$REPOS_JSON" "$NOW_EPOCH_5MIN" "10800"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "issue edit 12301" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2372: default 600s threshold skips issue with updatedAt 5 min ago" 0
else
	print_result "t2372: default 600s threshold skips issue with updatedAt 5 min ago" 1 \
		"(issue was too young but was reset anyway; edit args: $(cat "$GH_EDIT_ARGS_FILE"))"
fi

# =============================================================================
# Part 10 (t2372) — STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS env var override:
# with threshold set to 1800s (30 min), a 15-min-old issue is now younger
# than the cutoff and should NOT be reset. Proves the env hook works.
# =============================================================================
rm -f "$GH_EDIT_ARGS_FILE"
export STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=1800
_normalize_unassign_stale "testrunner" "$REPOS_JSON" "$NOW_EPOCH_15MIN" "10800"

if [[ ! -f "$GH_EDIT_ARGS_FILE" ]] || ! grep -q -- "issue edit 12301" "$GH_EDIT_ARGS_FILE"; then
	print_result "t2372: STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=1800 excludes 15-min-old issue" 0
else
	print_result "t2372: STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=1800 excludes 15-min-old issue" 1 \
		"(override set but issue was still reset; edit args: $(cat "$GH_EDIT_ARGS_FILE"))"
fi
unset STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
