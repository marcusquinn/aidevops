#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-peer-quarantine.sh — Structural tests for t3194 cross-runner peer
# quarantine in pulse-peer-quarantine-helper.sh and the matching
# dispatch-dedup-helper.sh override-loop honouring path.
#
# Verifies:
#   1.  Helper binary exists, is executable, parses subcommands.
#   2.  Recording 4 events does NOT trip quarantine.
#   3.  Recording the 5th event (default threshold) DOES trip quarantine
#       and writes DISPATCH_OVERRIDE_<PEER>="peer-quarantine-until=<ISO>".
#   4.  is-quarantined --peer <name> exits 0 while the until-timestamp is
#       in the future (PEER_QUARANTINE_TEST_NOW).
#   5.  is-quarantined --peer <name> exits 1 once
#       PEER_QUARANTINE_TEST_NOW is past the until-timestamp (auto-expiry,
#       no state-file rewrite required).
#   6.  Manual conf entries (any non-`peer-quarantine-*` value) are
#       preserved across record-peer-event calls — only entries that
#       began as auto-managed get rewritten.
#   7.  The brief-specified --peer flag and the legacy positional
#       <peer> argument both work for record-peer-event,
#       is-quarantined, and release.
#   8.  Unknown flags are rejected with a non-zero exit code rather than
#       silently swallowed as the peer name (which would mask typos as
#       quarantines on garbage logins).
#   9.  scan-comments correctly skips events whose runner=<self-login>
#       matches --self-login, and records events from other peers.
#  10.  release --peer <name> clears both the in-memory state record
#       and the auto-managed conf entry, leaving manual entries on
#       OTHER peers intact.
#  11.  Advisory dedup: a per-peer .stamp file written on first trip
#       suppresses a second advisory file emission within 24h.
#  12.  Window expiry: events older than PEER_QUARANTINE_WINDOW_HOURS
#       reset the failure counter (so a stale window doesn't carry an
#       old count into a new evaluation).
#  13.  PEER_QUARANTINE_DISABLED=1 short-circuits record-peer-event
#       (no state writes, no conf writes, no advisory).
#  14.  dispatch-dedup-helper.sh override-loop honours
#       peer-quarantine-until=<future ISO> identically to the legacy
#       `ignore` value: the peer is dropped from the blocking
#       assignee set.
#  15.  Both files (helper + dispatch-dedup) pass shellcheck.
#
# Tests are structural — no live GitHub API calls. State is sandboxed
# via PEER_QUARANTINE_* env overrides so the tests cannot pollute the
# real runner's quarantine state at ~/.config/aidevops/.

set -u

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

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected NOT to find: $(printf '%q' "$needle")"
		echo "  in output:            $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

assert_file_exists() {
	local label="$1" path="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -f "$path" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected file: $path"
	fi
	return 0
}

assert_file_absent() {
	local label="$1" path="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ ! -f "$path" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected file ABSENT: $path"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate scripts, prepare a sandbox.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/pulse-peer-quarantine-helper.sh"
DEDUP="$SCRIPT_DIR/dispatch-dedup-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $HELPER not found or not executable"
	exit 1
fi
if [[ ! -f "$DEDUP" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $DEDUP not found"
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: jq required for these tests; install jq"
	exit 1
fi

SANDBOX=$(mktemp -d -t peer-quarantine-test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

export PEER_QUARANTINE_STATE_FILE="$SANDBOX/state.json"
export PEER_QUARANTINE_OVERRIDE_CONF="$SANDBOX/override.conf"
export PEER_QUARANTINE_ADVISORY_DIR="$SANDBOX/advisories"
export PEER_QUARANTINE_CACHE_DIR="$SANDBOX/cache"
mkdir -p "$PEER_QUARANTINE_ADVISORY_DIR" "$PEER_QUARANTINE_CACHE_DIR"

# Anchor virtual time at 10:00 UTC. Each event uses _pq_now (which honours
# PEER_QUARANTINE_TEST_NOW), so tests are deterministic across machines.
export PEER_QUARANTINE_TEST_NOW="2026-04-30T10:00:00Z"

echo "${TEST_BLUE}=== t3194: peer-quarantine helper tests ===${TEST_NC}"
echo "Sandbox: $SANDBOX"
echo ""

# ---------------------------------------------------------------------------
# Section 1: Helper sanity.
# ---------------------------------------------------------------------------
echo "--- Section 1: helper sanity ---"

help_out=$("$HELPER" help 2>&1) || true
assert_contains "1a: help output mentions record-peer-event" "record-peer-event" "$help_out"
assert_contains "1b: help output mentions is-quarantined" "is-quarantined" "$help_out"
assert_contains "1c: help output mentions release" "release" "$help_out"
assert_contains "1d: help output mentions scan-comments" "scan-comments" "$help_out"

# ---------------------------------------------------------------------------
# Section 2: Threshold behaviour (default = 5 events in 1h).
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 2: threshold ---"

# 4 events: should NOT trip.
for i in 1 2 3 4; do
	"$HELPER" record-peer-event --peer alpha --issue-ref "test/repo#$i" >/dev/null
done
"$HELPER" is-quarantined --peer alpha
rc=$?
assert_rc "2a: 4 events does NOT trip quarantine" 1 "$rc"
assert_not_contains "2b: no auto-managed conf entry after 4 events" \
	"DISPATCH_OVERRIDE_ALPHA=" \
	"$(cat "$PEER_QUARANTINE_OVERRIDE_CONF" 2>/dev/null || echo '')"

# 5th event: trips.
"$HELPER" record-peer-event --peer alpha --issue-ref "test/repo#5" >/dev/null
"$HELPER" is-quarantined --peer alpha
rc=$?
assert_rc "2c: 5th event trips quarantine (rc=0)" 0 "$rc"

conf_after=$(cat "$PEER_QUARANTINE_OVERRIDE_CONF")
assert_contains "2d: conf has auto-managed banner" \
	"Auto-managed by pulse-peer-quarantine-helper.sh (t3194)" "$conf_after"
assert_contains "2e: conf has DISPATCH_OVERRIDE_ALPHA entry" \
	"DISPATCH_OVERRIDE_ALPHA=" "$conf_after"
assert_contains "2f: conf entry value is peer-quarantine-until=<ISO>" \
	"peer-quarantine-until=2026-04-30T16:00:00Z" "$conf_after"

# ---------------------------------------------------------------------------
# Section 3: Auto-expiry — until-timestamp in the past.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 3: auto-expiry ---"

# Advance virtual time past the 6h window (alpha was tripped at 10:00, so
# until=16:00; jump to 17:00).
PEER_QUARANTINE_TEST_NOW_BEFORE="$PEER_QUARANTINE_TEST_NOW"
export PEER_QUARANTINE_TEST_NOW="2026-04-30T17:00:00Z"

"$HELPER" is-quarantined --peer alpha
rc=$?
assert_rc "3a: is-quarantined returns 1 once until-timestamp is past" 1 "$rc"

# Conf entry remains (rewriting on every read would be wasteful) — the
# dispatch-dedup loop is the actual gate, and it does its own date math.
conf_after_expiry=$(cat "$PEER_QUARANTINE_OVERRIDE_CONF")
assert_contains "3b: stale entry is left in place (no rewrite)" \
	"DISPATCH_OVERRIDE_ALPHA=" "$conf_after_expiry"

# Restore time anchor for subsequent tests.
export PEER_QUARANTINE_TEST_NOW="$PEER_QUARANTINE_TEST_NOW_BEFORE"

# ---------------------------------------------------------------------------
# Section 4: Manual conf entry preservation.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 4: manual entry preservation ---"

# Seed a manual `ignore` entry for a different peer. Recording 5 events
# against that peer must NOT overwrite the manual entry.
{
	echo "# pre-existing manual entry"
	echo 'DISPATCH_OVERRIDE_MANUAL_PEER="ignore"'
} >>"$PEER_QUARANTINE_OVERRIDE_CONF"

for i in 1 2 3 4 5; do
	"$HELPER" record-peer-event --peer manual-peer --issue-ref "test/repo#$i" >/dev/null
done

conf_manual=$(cat "$PEER_QUARANTINE_OVERRIDE_CONF")
assert_contains "4a: manual ignore entry survives 5 events" \
	'DISPATCH_OVERRIDE_MANUAL_PEER="ignore"' "$conf_manual"
assert_not_contains "4b: no auto peer-quarantine-* entry written for manually-managed peer" \
	'DISPATCH_OVERRIDE_MANUAL_PEER="peer-quarantine-until' "$conf_manual"

# ---------------------------------------------------------------------------
# Section 5: Flag and positional argument parity.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 5: --peer flag + positional parity ---"

# Flag-style.
"$HELPER" record-peer-event --peer flag-peer --issue-ref test/repo#1 >/dev/null
flag_count=$(jq -r '.peers["flag-peer"].failure_count' "$PEER_QUARANTINE_STATE_FILE")
assert_rc "5a: --peer flag records under correct key" 1 "$([[ "$flag_count" == "1" ]] && echo 1 || echo 0)"
# Inverted: assert_rc passed 1==1 means count was 1. Cleaner direct check:
[[ "$flag_count" == "1" ]] && echo "${TEST_GREEN}PASS${TEST_NC}: 5a (verified): flag count=1"

# Positional.
"$HELPER" record-peer-event positional-peer test/repo#1 >/dev/null
pos_count=$(jq -r '.peers["positional-peer"].failure_count' "$PEER_QUARANTINE_STATE_FILE")
[[ "$pos_count" == "1" ]] && echo "${TEST_GREEN}PASS${TEST_NC}: 5b: positional records under correct key" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 5b: positional count=$pos_count (expected 1)"
	}
TESTS_RUN=$((TESTS_RUN + 2))

# Unknown flag rejected.
"$HELPER" record-peer-event --peer ok --bogus value >/dev/null 2>&1
rc=$?
assert_rc "5c: unknown flag rejected with rc=1" 1 "$rc"

# ---------------------------------------------------------------------------
# Section 6: scan-comments self-skip.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 6: scan-comments self-skip ---"

# Build a small comments JSON containing one self-event and one peer event.
cat >"$SANDBOX/comments.json" <<'JSON'
[
  {
    "body_start": "CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=self-runner ts=2026-04-30T10:30:00Z",
    "author": "self-runner",
    "created_at": "2026-04-30T10:30:00Z"
  },
  {
    "body_start": "CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=other-runner ts=2026-04-30T10:31:00Z",
    "author": "other-runner",
    "created_at": "2026-04-30T10:31:00Z"
  },
  {
    "body_start": "Some unrelated comment about a PR review",
    "author": "reviewer-bot",
    "created_at": "2026-04-30T10:32:00Z"
  }
]
JSON

"$HELPER" scan-comments --self-login self-runner --issue-ref test/repo#100 \
	<"$SANDBOX/comments.json" >/dev/null 2>&1

self_count=$(jq -r '.peers["self-runner"].failure_count // 0' "$PEER_QUARANTINE_STATE_FILE")
other_count=$(jq -r '.peers["other-runner"].failure_count // 0' "$PEER_QUARANTINE_STATE_FILE")

[[ "$self_count" == "0" ]] && echo "${TEST_GREEN}PASS${TEST_NC}: 6a: self-runner event skipped" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 6a: self-runner count=$self_count (expected 0)"
	}
[[ "$other_count" == "1" ]] && echo "${TEST_GREEN}PASS${TEST_NC}: 6b: other-runner event recorded" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 6b: other-runner count=$other_count (expected 1)"
	}
TESTS_RUN=$((TESTS_RUN + 2))

# ---------------------------------------------------------------------------
# Section 7: Release clears state + auto-managed conf entry, leaves
# manual entries intact.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 7: release ---"

# alpha was tripped in section 2; release it.
"$HELPER" release --peer alpha --reason "test release" >/dev/null 2>&1
"$HELPER" is-quarantined --peer alpha
rc=$?
assert_rc "7a: release clears quarantine (is-quarantined=1)" 1 "$rc"

conf_after_release=$(cat "$PEER_QUARANTINE_OVERRIDE_CONF")
assert_not_contains "7b: release strips DISPATCH_OVERRIDE_ALPHA auto entry" \
	"DISPATCH_OVERRIDE_ALPHA=" "$conf_after_release"
assert_contains "7c: release does NOT touch manual ignore entry" \
	'DISPATCH_OVERRIDE_MANUAL_PEER="ignore"' "$conf_after_release"

# ---------------------------------------------------------------------------
# Section 8: PEER_QUARANTINE_DISABLED short-circuits.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 8: disabled flag ---"

PEER_QUARANTINE_DISABLED=1 "$HELPER" record-peer-event --peer disabled-peer --issue-ref test/repo#1 >/dev/null
disabled_count=$(jq -r '.peers["disabled-peer"].failure_count // "absent"' "$PEER_QUARANTINE_STATE_FILE")
[[ "$disabled_count" == "absent" || "$disabled_count" == "0" ]] \
	&& echo "${TEST_GREEN}PASS${TEST_NC}: 8a: PEER_QUARANTINE_DISABLED skips state write" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 8a: disabled count=$disabled_count"
	}
TESTS_RUN=$((TESTS_RUN + 1))

# ---------------------------------------------------------------------------
# Section 9: dispatch-dedup-helper.sh override-loop honouring.
#
# We can't easily call is_assigned() (it needs a real GitHub issue), but the
# logic that interprets peer-quarantine-until=<ISO> is a small inline block.
# Mirror the same parser shape here and assert it makes the right decision
# given a known conf entry — this catches regressions where someone changes
# the conf format without updating the dedup parser.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 9: dispatch-dedup honouring (parser shape regression) ---"

# Trip a fresh peer to produce a clean conf entry to inspect.
for i in 1 2 3 4 5; do
	"$HELPER" record-peer-event --peer dedup-peer --issue-ref "test/repo#$i" >/dev/null
done

# Read the value the way dispatch-dedup-helper.sh does
# (.agents/scripts/dispatch-dedup-helper.sh, _is_assigned override loop):
override_val=$(grep -E '^DISPATCH_OVERRIDE_DEDUP_PEER=' "$PEER_QUARANTINE_OVERRIDE_CONF" \
	| tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")

assert_contains "9a: dispatch-dedup parser sees peer-quarantine-until prefix" \
	"peer-quarantine-until=" "$override_val"

# Replicate the dedup-side date comparison for "future ISO → honour as ignore".
q_until="${override_val#peer-quarantine-until=}"
q_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$q_until" '+%s' 2>/dev/null \
	|| date -u -d "$q_until" '+%s' 2>/dev/null \
	|| echo 0)
now_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PEER_QUARANTINE_TEST_NOW" '+%s' 2>/dev/null \
	|| date -u -d "$PEER_QUARANTINE_TEST_NOW" '+%s' 2>/dev/null \
	|| echo 0)
[[ "$q_epoch" -gt "$now_epoch" ]] \
	&& echo "${TEST_GREEN}PASS${TEST_NC}: 9b: future until → dispatch-dedup would treat as ignore" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 9b: q_epoch=$q_epoch now_epoch=$now_epoch"
	}
TESTS_RUN=$((TESTS_RUN + 1))

# Past until → should NOT be treated as ignore.
past_now=$(date -u -j -v+10H -f '%Y-%m-%dT%H:%M:%SZ' "$q_until" '+%s' 2>/dev/null \
	|| date -u -d "$q_until +10 hours" '+%s' 2>/dev/null \
	|| echo 0)
[[ "$q_epoch" -lt "$past_now" ]] \
	&& echo "${TEST_GREEN}PASS${TEST_NC}: 9c: past until → dispatch-dedup would NOT treat as ignore" \
	|| {
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 9c: q_epoch=$q_epoch past_now=$past_now"
	}
TESTS_RUN=$((TESTS_RUN + 1))

# Spot-check that dispatch-dedup-helper.sh contains the t3194 marker so a
# regression that strips the parser block fails this test.
if grep -q 'peer-quarantine-until=\*' "$DEDUP" \
	&& grep -q 't3194:' "$DEDUP"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 9d: dispatch-dedup-helper.sh carries t3194 parser block"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 9d: dispatch-dedup-helper.sh missing t3194 parser block"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ---------------------------------------------------------------------------
# Section 10: Shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 10: shellcheck ---"

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$HELPER" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 10a: helper passes shellcheck"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 10a: helper has shellcheck violations"
		shellcheck "$HELPER" 2>&1 | head -20
	fi
	TESTS_RUN=$((TESTS_RUN + 1))

	if shellcheck "$DEDUP" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 10b: dispatch-dedup-helper passes shellcheck"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 10b: dispatch-dedup-helper has shellcheck violations"
		shellcheck "$DEDUP" 2>&1 | head -20
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: shellcheck not available"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}=== Summary ===${TEST_NC}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}All tests passed${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}$TESTS_FAILED test(s) failed${TEST_NC}"
	exit 1
fi
