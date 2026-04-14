#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-interactive-session-claim.sh — t2056 regression guard.
#
# Asserts the interactive-session-helper.sh primitive behaves correctly:
#
#   1. claim writes a stamp with the expected schema
#   2. claim is idempotent (re-running refreshes timestamp, never fails)
#   3. release deletes the stamp idempotently
#   4. status lists stamps from the claim dir
#   5. status --issue returns exit 1 when the issue is not claimed
#   6. scan-stale detects dead-PID + missing-worktree claims
#   7. scan-stale ignores claims from other hostnames (can't verify)
#   8. offline gh path warns and exits 0 without blocking the caller
#   9. help subcommand prints usage
#
# The tests stub `gh`, `jq`, `kill`, and `hostname` via a PATH shim so no
# network round-trip or real process check happens. Internal functions are
# tested by sourcing the helper (the `BASH_SOURCE == "$0"` guard on main
# keeps the source call side-effect-free).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_PATH="${TEST_SCRIPTS_DIR}/interactive-session-helper.sh"

# NOT readonly — shared-constants.sh declares readonly RED/GREEN/RESET
# and the collision under `set -e` silently kills the test shell.
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
}

# Sandbox HOME so the stamp dir lands inside the temp root
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"

# -----------------------------------------------------------------------------
# PATH stub for gh — respond to auth status, user, issue view, issue edit.
# Each invocation is logged to $STUB_LOG so assertions can inspect them.
# -----------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/stub-bin"
STUB_LOG="${TEST_ROOT}/stub-calls.log"
mkdir -p "$STUB_BIN"
: >"$STUB_LOG"
# Export STUB_LOG so subprocess invocations of the stub gh see it. Without
# the export, subprocesses spawned by `"$HELPER_PATH" claim ...` inherit an
# unset STUB_LOG and the stub logs to /dev/null, making subprocess-driven
# assertions blind. Added in the GH#18786 regression coverage.
export STUB_LOG

# Default stub mode — override via STUB_GH_MODE
#   online   — gh returns successful responses
#   offline  — gh auth status returns 1 (simulates offline / unauth)
export STUB_GH_MODE=online

cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${STUB_LOG:-/dev/null}"

case "$1" in
auth)
	if [[ "${STUB_GH_MODE:-online}" == "offline" ]]; then
		exit 1
	fi
	exit 0
	;;
api)
	# gh api user --jq '.login'
	if [[ "$2" == "user" ]]; then
		printf 'testuser\n'
		exit 0
	fi
	exit 0
	;;
issue)
	case "$2" in
	view)
		# Echo a minimal issue JSON. STUB_ISSUE_HAS_IN_REVIEW=1 flips the
		# label present so idempotency paths can be exercised.
		if [[ "${STUB_ISSUE_HAS_IN_REVIEW:-0}" == "1" ]]; then
			printf '{"labels":[{"name":"status:in-review"}]}\n'
		else
			printf '{"labels":[]}\n'
		fi
		exit 0
		;;
	edit)
		# Log the edit flags (already captured in STUB_LOG above). Success.
		exit 0
		;;
	esac
	exit 0
	;;
label)
	# `gh label create ... --force` — succeed silently
	exit 0
	;;
esac
exit 0
STUB
chmod +x "${STUB_BIN}/gh"

# jq is used by the helper for stamp creation and label parsing. We let the
# real jq through (it's a framework dependency) — only gh needs stubbing.
export PATH="${STUB_BIN}:${PATH}"

# Verify the stub wins the PATH lookup
if [[ "$(command -v gh)" != "${STUB_BIN}/gh" ]]; then
	printf '%sFATAL%s PATH stub not winning — tests invalid\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# -----------------------------------------------------------------------------
# Source the helper so internal functions are callable.
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$HELPER_PATH" >/dev/null 2>&1
# Helper sets `set -euo pipefail` — drop -e for negative assertions
set +e

# Sanity check — did sourcing expose the functions we need?
if ! declare -f _isc_cmd_claim >/dev/null; then
	printf '%sFATAL%s _isc_cmd_claim not exposed — helper not sourceable\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# =============================================================================
# Test 1 — claim writes a stamp with the expected schema
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
claim_rc=$?

STAMP_FILE="${HOME}/.aidevops/.agent-workspace/interactive-claims/testowner-testrepo-18738.json"
if [[ $claim_rc -eq 0 && -f "$STAMP_FILE" ]]; then
	print_result "claim writes stamp file" 0
else
	print_result "claim writes stamp file" 1 "(rc=$claim_rc, stamp=$STAMP_FILE exists=$([[ -f "$STAMP_FILE" ]] && echo yes || echo no))"
fi

# Validate stamp schema
if [[ -f "$STAMP_FILE" ]]; then
	stamp_issue=$(jq -r '.issue' "$STAMP_FILE" 2>/dev/null)
	stamp_slug=$(jq -r '.slug' "$STAMP_FILE" 2>/dev/null)
	stamp_user=$(jq -r '.user' "$STAMP_FILE" 2>/dev/null)
	stamp_worktree=$(jq -r '.worktree_path' "$STAMP_FILE" 2>/dev/null)

	if [[ "$stamp_issue" == "18738" && "$stamp_slug" == "testowner/testrepo" && "$stamp_user" == "testuser" && "$stamp_worktree" == "/tmp/wt-fake" ]]; then
		print_result "claim stamp schema populated" 0
	else
		print_result "claim stamp schema populated" 1 "(issue=$stamp_issue slug=$stamp_slug user=$stamp_user wt=$stamp_worktree)"
	fi
fi

# =============================================================================
# Test 2 — claim is idempotent (second call refreshes, never fails)
# =============================================================================
# Flip the stub so view returns in-review — simulates already-claimed state
export STUB_ISSUE_HAS_IN_REVIEW=1
sleep 1 # ensure timestamp delta is visible
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
claim2_rc=$?

if [[ $claim2_rc -eq 0 && -f "$STAMP_FILE" ]]; then
	print_result "claim idempotent on re-call" 0
else
	print_result "claim idempotent on re-call" 1 "(rc=$claim2_rc)"
fi

# =============================================================================
# Test 3 — release deletes the stamp
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=1
_isc_cmd_release 18738 testowner/testrepo >/dev/null 2>&1
release_rc=$?

if [[ $release_rc -eq 0 && ! -f "$STAMP_FILE" ]]; then
	print_result "release deletes stamp" 0
else
	print_result "release deletes stamp" 1 "(rc=$release_rc, stamp exists=$([[ -f "$STAMP_FILE" ]] && echo yes || echo no))"
fi

# =============================================================================
# Test 4 — release without prior claim is a no-op (idempotent)
# =============================================================================
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_release 99999 testowner/testrepo >/dev/null 2>&1
release2_rc=$?

if [[ $release2_rc -eq 0 ]]; then
	print_result "release idempotent on unclaimed issue" 0
else
	print_result "release idempotent on unclaimed issue" 1 "(rc=$release2_rc)"
fi

# =============================================================================
# Test 5 — status lists active claims
# =============================================================================
# Re-claim to populate a stamp
export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_cmd_claim 18738 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1
_isc_cmd_claim 18739 testowner/testrepo --worktree /tmp/wt-fake >/dev/null 2>&1

status_out=$(_isc_cmd_status 2>&1)
status_rc=$?

if [[ $status_rc -eq 0 ]] && printf '%s' "$status_out" | grep -q '#18738' && printf '%s' "$status_out" | grep -q '#18739'; then
	print_result "status lists active claims" 0
else
	print_result "status lists active claims" 1 "(rc=$status_rc, out=${status_out:0:100})"
fi

# =============================================================================
# Test 6 — scan-stale detects dead-PID + missing-worktree claims
# =============================================================================
# Forge a stamp with PID 1 (process exists) but missing worktree — should NOT
# be flagged (PID alive). Then forge a stamp with PID 999999 (dead) and
# missing worktree — SHOULD be flagged.

claim_dir="${HOME}/.aidevops/.agent-workspace/interactive-claims"
current_host=$(hostname 2>/dev/null || echo "unknown")

# Stamp A: dead PID + missing worktree + current host → stale
jq -n --arg host "$current_host" '{
	issue: 77701,
	slug: "stale/test",
	worktree_path: "/tmp/definitely-does-not-exist-77701",
	claimed_at: "2020-01-01T00:00:00Z",
	pid: 999999,
	hostname: $host,
	user: "testuser"
}' >"${claim_dir}/stale-test-77701.json"

# Stamp B: cross-host → ignored
jq -n '{
	issue: 77702,
	slug: "stale/test",
	worktree_path: "/tmp/missing-77702",
	claimed_at: "2020-01-01T00:00:00Z",
	pid: 999998,
	hostname: "not-this-host-at-all",
	user: "testuser"
}' >"${claim_dir}/stale-test-77702.json"

scan_out=$(_isc_cmd_scan_stale 2>&1)
scan_rc=$?

if [[ $scan_rc -eq 0 ]] && printf '%s' "$scan_out" | grep -q '#77701' && ! printf '%s' "$scan_out" | grep -q '#77702'; then
	print_result "scan-stale flags dead-PID + missing-worktree, ignores cross-host" 0
else
	print_result "scan-stale flags dead-PID + missing-worktree, ignores cross-host" 1 "(rc=$scan_rc, out=${scan_out:0:200})"
fi

# =============================================================================
# Test 7 — offline gh path: claim warns and exits 0, no stamp written
# =============================================================================
export STUB_GH_MODE=offline
rm -f "${claim_dir}"/*.json 2>/dev/null || true

offline_out=$(_isc_cmd_claim 88888 offline/repo 2>&1)
offline_rc=$?

offline_stamp="${claim_dir}/offline-repo-88888.json"

if [[ $offline_rc -eq 0 && ! -f "$offline_stamp" ]] && printf '%s' "$offline_out" | grep -q 'offline'; then
	print_result "offline gh: warn and continue, no stamp" 0
else
	print_result "offline gh: warn and continue, no stamp" 1 "(rc=$offline_rc, out=${offline_out:0:100})"
fi

export STUB_GH_MODE=online

# =============================================================================
# Test 8 — help subcommand
# =============================================================================
help_out=$(_isc_cmd_help 2>&1)
if printf '%s' "$help_out" | grep -q 'interactive-session-helper.sh'; then
	print_result "help prints usage" 0
else
	print_result "help prints usage" 1
fi

# =============================================================================
# Test 9 — status on unknown issue returns exit 1
# =============================================================================
_isc_cmd_status 99999 >/dev/null 2>&1
st_rc=$?
if [[ $st_rc -eq 1 ]]; then
	print_result "status <unknown> returns exit 1" 0
else
	print_result "status <unknown> returns exit 1" 1 "(rc=$st_rc, expected 1)"
fi

# =============================================================================
# Test 10 — missing arguments return exit 2
# =============================================================================
_isc_cmd_claim 2>/dev/null
no_args_rc=$?
if [[ $no_args_rc -eq 2 ]]; then
	print_result "claim without args returns exit 2" 0
else
	print_result "claim without args returns exit 2" 1 "(rc=$no_args_rc, expected 2)"
fi

_isc_cmd_claim "notanumber" testowner/repo 2>/dev/null
bad_issue_rc=$?
if [[ $bad_issue_rc -eq 2 ]]; then
	print_result "claim with non-numeric issue returns exit 2" 0
else
	print_result "claim with non-numeric issue returns exit 2" 1 "(rc=$bad_issue_rc, expected 2)"
fi

# =============================================================================
# Test 11 — GH#18786 regression: claim must reach the label-apply branch
# under the script's own `set -euo pipefail` when the label is absent.
#
# The reported bug was that a bare `_isc_has_in_review` call followed by
# `has_rc=$?` capture killed _isc_cmd_claim before it could apply the
# label — because `set -e` propagates unchecked non-zero returns out of
# the parent function immediately, so `has_rc=$?` never runs. The other
# tests in this file source the helper and run with `set +e`, which masks
# this class entirely. This test EXECUTES the helper as a subprocess so
# the script's `set -euo pipefail` at line 42 is live.
#
# A second latent bug was a broken `jq -e 'any(.name; ...)'` query in
# _isc_has_in_review that raised "Cannot index array with string 'name'"
# on jq 1.7+, swallowed by `2>&1 /dev/null`, and caused the function to
# always report "label absent" — masking the set -e bug from Test 2's
# idempotency assertion (which runs under set +e in source mode).
#
# A third latent bug was `"${extra_flags[@]}"` under bash 3.2 set -u,
# previously unreachable because of the broken jq query.
#
# This regression test covers all three by asserting that:
#   (a) The subprocess exits 0 (set -e did not kill it mid-flight)
#   (b) `gh issue edit` was called with --add-label status:in-review
#       (i.e. the label-apply branch actually ran)
#   (c) A stamp file landed (end-of-claim side effect ran)
#   (d) The idempotent path (label present) exits 0 AND hits the
#       "already has status:in-review" info message without calling
#       `gh issue edit` (no transition spam on repeat claims)
#
# Reference: GH#18786, reference/bash-compat.md checklist item 4, sibling
# set -e bug class GH#18770 and GH#18784.
# =============================================================================

# Reset stamp dir for a clean run
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

# --- Case (a-c): label absent, subprocess exit must be 0 with label applied ---
STUB_ISSUE_HAS_IN_REVIEW=0 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 56001 regress/test --worktree /tmp/regress-wt \
	>/dev/null 2>&1
subprocess_rc=$?

regress_stamp="${claim_dir}/regress-test-56001.json"
if [[ $subprocess_rc -eq 0 && -f "$regress_stamp" ]]; then
	print_result "GH#18786: claim subprocess exits 0 under set -euo pipefail" 0
else
	print_result "GH#18786: claim subprocess exits 0 under set -euo pipefail" 1 \
		"(rc=$subprocess_rc, stamp exists=$([[ -f "$regress_stamp" ]] && echo yes || echo no))"
fi

# Verify the label-apply branch actually ran (gh issue edit was called with
# the add-label flag). This closes the test gap where Test 1 only checks the
# stamp, not whether the label transition API call happened.
if grep -q 'issue edit 56001' "$STUB_LOG" && grep -q 'add-label status:in-review' "$STUB_LOG"; then
	print_result "GH#18786: claim applies status:in-review when absent" 0
else
	print_result "GH#18786: claim applies status:in-review when absent" 1 \
		"(stub log: $(tr '\n' '|' <"$STUB_LOG"))"
fi

# --- Case (d): idempotent path — label already present, no transition ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

idempotent_out=$(STUB_ISSUE_HAS_IN_REVIEW=1 STUB_GH_MODE=online \
	"$HELPER_PATH" claim 56001 regress/test --worktree /tmp/regress-wt \
	2>&1)
idempotent_rc=$?

if [[ $idempotent_rc -eq 0 ]] && printf '%s' "$idempotent_out" | grep -q 'already has status:in-review'; then
	print_result "GH#18786: claim idempotent when label already present (subprocess)" 0
else
	print_result "GH#18786: claim idempotent when label already present (subprocess)" 1 \
		"(rc=$idempotent_rc, out=${idempotent_out:0:200})"
fi

# Idempotent path MUST NOT call gh issue edit (saves an API round-trip and
# prevents spurious label-change noise on every re-claim).
if ! grep -q 'issue edit' "$STUB_LOG"; then
	print_result "GH#18786: idempotent claim skips gh issue edit" 0
else
	print_result "GH#18786: idempotent claim skips gh issue edit" 1 \
		"(stub log: $(tr '\n' '|' <"$STUB_LOG"))"
fi

# --- Case (e): release subprocess also survives set -euo pipefail ---
rm -f "${claim_dir}"/*.json 2>/dev/null || true
: >"$STUB_LOG"

# Pre-populate a stamp so release has something to delete
STUB_ISSUE_HAS_IN_REVIEW=0 "$HELPER_PATH" claim 56002 regress/test >/dev/null 2>&1

release_sub_rc=0
STUB_ISSUE_HAS_IN_REVIEW=1 "$HELPER_PATH" release 56002 regress/test >/dev/null 2>&1 || release_sub_rc=$?
release_stamp="${claim_dir}/regress-test-56002.json"

if [[ $release_sub_rc -eq 0 && ! -f "$release_stamp" ]]; then
	print_result "GH#18786: release subprocess exits 0 under set -euo pipefail" 0
else
	print_result "GH#18786: release subprocess exits 0 under set -euo pipefail" 1 \
		"(rc=$release_sub_rc, stamp exists=$([[ -f "$release_stamp" ]] && echo yes || echo no))"
fi

# --- Case (f): _isc_has_in_review jq query is not broken (dead-code gate) ---
# The previous `any(.name; ...)` form raised "Cannot index array with string".
# Assert the repaired query correctly distinguishes present from absent and
# from lookup-failure by driving _isc_has_in_review directly with stub modes.
export STUB_ISSUE_HAS_IN_REVIEW=1
_isc_has_in_review 56003 regress/test
jq_present_rc=$?

export STUB_ISSUE_HAS_IN_REVIEW=0
_isc_has_in_review 56003 regress/test
jq_absent_rc=$?

if [[ $jq_present_rc -eq 0 && $jq_absent_rc -eq 1 ]]; then
	print_result "GH#18786: _isc_has_in_review jq query returns 0/1 correctly" 0
else
	print_result "GH#18786: _isc_has_in_review jq query returns 0/1 correctly" 1 \
		"(present_rc=$jq_present_rc, absent_rc=$jq_absent_rc, expected 0/1)"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
else
	printf '%s%d test(s) failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
