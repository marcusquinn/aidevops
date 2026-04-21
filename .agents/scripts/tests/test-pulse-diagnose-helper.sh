#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for pulse-diagnose-helper.sh (t2714)
#
# Uses a fixture pulse.log with 3+ distinct rule outcomes and stubs gh.
# Does NOT require live network or real pulse.log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../pulse-diagnose-helper.sh"
PASS=0
FAIL=0
TOTAL=0

# =============================================================================
# Test framework
# =============================================================================

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" == "$actual" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$desc" "$expected" "$actual"
	fi
	return 0
}

assert_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected to contain: %s\n    actual: %s\n' "$desc" "$needle" "$haystack"
	fi
	return 0
}

assert_not_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if ! printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected NOT to contain: %s\n' "$desc" "$needle"
	fi
	return 0
}

assert_exit_code() {
	local desc="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" -eq "$actual" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s (expected exit %d, got %d)\n' "$desc" "$expected" "$actual"
	fi
	return 0
}

# =============================================================================
# Fixture setup
# =============================================================================

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_LOGFILE="${TMPDIR_TEST}/pulse.log"
FIXTURE_LOGDIR="${TMPDIR_TEST}"

# Create fixture pulse.log with 3+ distinct rule outcomes:
# 1. PR #20329: escalated by dirty-pr-sweep (notify), then admin-bypass merge
# 2. PR #20336: auto-merged (origin:interactive lifecycle)
# 3. PR #20340: skipped due to failing checks
cat > "$FIXTURE_LOGFILE" <<'FIXTURE'
2026-04-21T17:45:03Z [pulse-dirty-pr-sweep] PR #20329 (marcusquinn/aidevops): decision=notify reason=origin-interactive-orphan
2026-04-21T17:45:04Z [pulse-dirty-pr-sweep] PR #20329 (marcusquinn/aidevops): notified (origin-interactive-orphan)
2026-04-21T18:30:00Z [pulse-wrapper] Review bot gate: PASS for PR #20336 in marcusquinn/aidevops
2026-04-21T18:30:01Z [pulse-wrapper] approve_collaborator_pr: PR #20336 is self-authored (marcusquinn) — skipping approval (--admin handles it)
2026-04-21T18:30:02Z [pulse-wrapper] Deterministic merge: merged PR #20336 in marcusquinn/aidevops
2026-04-21T18:30:03Z [pulse-merge] auto-merged origin:interactive PR #20336 (author=marcusquinn, role=admin)
2026-04-21T19:00:00Z [pulse-wrapper] Merge pass: skipping PR #20340 in marcusquinn/aidevops — 2 required status check(s) failing (t2104)
2026-04-21T19:00:01Z [pulse-wrapper] _dispatch_ci_fix_worker: routed CI failure feedback from PR #20340 to issue #20300 in marcusquinn/aidevops
2026-04-21T19:30:00Z [pulse-dirty-pr-sweep] sweep complete: rebased=1 closed=0 notified=2
2026-04-21T20:00:00Z [pulse-wrapper] Deterministic merge pass complete: merged=3, closed_conflicting=0, failed=0
FIXTURE

# Also create a rotated log with older PR #20329 entries
cat > "${TMPDIR_TEST}/pulse.log.1" <<'ROTATED'
2026-04-20T10:00:00Z [pulse-wrapper] Merge pass: skipping PR #20329 in marcusquinn/aidevops — reviewDecision=CHANGES_REQUESTED
ROTATED

# Create a gh stub that returns canned data
GH_STUB="${TMPDIR_TEST}/gh"
cat > "$GH_STUB" <<'GHSTUB'
#!/usr/bin/env bash
# gh stub for testing pulse-diagnose-helper.sh
if [[ "$*" == *"pr view"*"20329"* ]]; then
  cat <<'JSON'
{"number":20329,"title":"t2710: fix dirty-pr-sweep","state":"CLOSED","author":{"login":"marcusquinn"},"mergedAt":null,"closedAt":"2026-04-21T18:01:09Z","createdAt":"2026-04-20T09:00:00Z","labels":[{"name":"origin:interactive"}],"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"DIRTY","headRefName":"feature/t2710","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"20336"* ]]; then
  cat <<'JSON'
{"number":20336,"title":"t2708: fix interactive sweep","state":"MERGED","author":{"login":"marcusquinn"},"mergedAt":"2026-04-21T18:30:02Z","closedAt":"2026-04-21T18:30:02Z","createdAt":"2026-04-21T17:00:00Z","labels":[{"name":"origin:interactive"}],"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","headRefName":"feature/t2708","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"20340"* ]]; then
  cat <<'JSON'
{"number":20340,"title":"t2711: add rate limit guard","state":"OPEN","author":{"login":"marcusquinn"},"mergedAt":null,"closedAt":null,"createdAt":"2026-04-21T18:50:00Z","labels":[{"name":"origin:worker"}],"reviewDecision":"","mergeStateStatus":"BLOCKED","headRefName":"feature/t2711","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"99999"* ]]; then
  echo '{"number":99999,"title":"ghost PR","state":"MERGED","author":{"login":"someone"},"mergedAt":"2026-04-21T12:00:00Z","closedAt":"2026-04-21T12:00:00Z","createdAt":"2026-04-21T11:00:00Z","labels":[],"reviewDecision":"","mergeStateStatus":"","headRefName":"feature/ghost","baseRefName":"main","isDraft":false}'
  exit 0
fi
if [[ "$*" == *"api"*"timeline"* ]]; then
  echo '[]'
  exit 0
fi
echo '{}' >&2
exit 1
GHSTUB
chmod +x "$GH_STUB"

# =============================================================================
# Tests
# =============================================================================

printf '\n=== pulse-diagnose-helper.sh regression tests ===\n\n'

# --- Test 1: help command ---
printf 'Test 1: help command\n'
output=$("$HELPER" help 2>&1) || true
assert_contains "help shows usage" "COMMANDS:" "$output"
assert_contains "help shows pr subcommand" "pr <N>" "$output"

# --- Test 2: rules command ---
printf '\nTest 2: rules command\n'
output=$("$HELPER" rules 2>&1) || true
assert_contains "rules lists inventory" "Rule Inventory" "$output"
assert_contains "rules shows pm-auto-merge-interactive" "pm-auto-merge-interactive" "$output"
assert_contains "rules shows dps-classify" "dps-classify" "$output"

# Count rules (≥30 required)
rule_count=$(echo "$output" | grep -c '^[a-z]' || echo 0)
TOTAL=$((TOTAL + 1))
if [[ "$rule_count" -ge 30 ]]; then
	PASS=$((PASS + 1))
	printf '  ✓ rule count ≥30 (got %d)\n' "$rule_count"
else
	FAIL=$((FAIL + 1))
	printf '  ✗ rule count ≥30 (got %d)\n' "$rule_count"
fi

# --- Test 3: rules --json ---
printf '\nTest 3: rules --json\n'
output=$("$HELPER" rules --json 2>&1) || true
assert_contains "json output is array" "[" "$output"
# Validate it parses as JSON
if command -v jq >/dev/null 2>&1; then
	jq_count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
	TOTAL=$((TOTAL + 1))
	if [[ "$jq_count" -ge 30 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ JSON rules array has ≥30 entries (got %s)\n' "$jq_count"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ JSON rules array has ≥30 entries (got %s)\n' "$jq_count"
	fi
fi

# --- Test 4: PR #20329 — escalated dirty PR (notify + admin-bypass merge) ---
printf '\nTest 4: PR #20329 — escalated dirty PR\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20329 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows PR number" "PR #20329" "$output"
assert_contains "shows author" "marcusquinn" "$output"
assert_contains "classifies dirty-pr-sweep notify" "dps-classify" "$output"
assert_contains "shows CLOSED state" "CLOSED" "$output"
assert_contains "shows closed without merge" "closed without merge" "$output"
# Also picks up the rotated log entry
assert_contains "picks up rotated log (CHANGES_REQUESTED)" "pw-merge-skip-changes-requested" "$output"

# --- Test 5: PR #20336 — full auto-merge lifecycle ---
printf '\nTest 5: PR #20336 — auto-merge lifecycle\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows review bot gate PASS" "pw-review-bot-gate-pass" "$output"
assert_contains "shows approve skip (self-authored)" "pw-approve-self" "$output"
assert_contains "shows deterministic merge" "pw-merged" "$output"
assert_contains "shows auto-merge interactive" "pm-auto-merge-interactive" "$output"
assert_contains "outcome is pulse auto-merged" "pulse auto-merged" "$output"

# --- Test 6: PR #20340 — skipped due to failing checks ---
printf '\nTest 6: PR #20340 — failing checks skip\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20340 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows check failure skip" "pw-merge-skip-checks" "$output"
assert_contains "shows CI fix routing" "pw-route-ci-fix" "$output"
assert_contains "PR is still open" "still open" "$output"

# --- Test 7: PR #99999 — zero pulse entries (admin-bypass) ---
printf '\nTest 7: PR #99999 — zero pulse entries (admin-bypass)\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 99999 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "notes no pulse entries" "no pulse log entries" "$output"
assert_contains "suggests admin bypass" "admin bypass" "$output"

# --- Test 8: --verbose flag ---
printf '\nTest 8: --verbose flag shows raw lines\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops --verbose 2>&1) || true

assert_contains "verbose shows RAW:" "RAW:" "$output"

# --- Test 9: --json output ---
printf '\nTest 9: --json output for PR\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops --json 2>&1) || true

if command -v jq >/dev/null 2>&1; then
	json_event_count=$(echo "$output" | jq '.event_count' 2>/dev/null || echo 0)
	assert_eq "JSON event_count for PR #20336" "4" "$json_event_count"
	json_merged=$(echo "$output" | jq '.merged' 2>/dev/null || echo "false")
	assert_eq "JSON merged=true for PR #20336" "true" "$json_merged"
fi

# --- Test 10: missing pulse.log ---
printf '\nTest 10: missing pulse.log handled gracefully\n'
output=$(PULSE_DIAGNOSE_LOGFILE="/nonexistent/pulse.log" \
	PULSE_DIAGNOSE_LOGDIR="/nonexistent" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "graceful with missing log" "no pulse log entries" "$output"

# --- Test 11: gh offline mode ---
printf '\nTest 11: gh offline mode\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_GH_OFFLINE=1 \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "works with gh offline" "PR #20336" "$output"
assert_contains "author shows unknown when offline" "unknown" "$output"

# --- Test 12: no arguments ---
printf '\nTest 12: missing PR number shows error\n'
output=$("$HELPER" pr 2>&1) || true
rc=$?
assert_contains "shows usage on missing arg" "usage:" "$output"

# =============================================================================
# Summary
# =============================================================================

printf '\n=== Results: %d passed, %d failed, %d total ===\n\n' "$PASS" "$FAIL" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
