#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
LEDGER="${SCRIPTS_DIR}/dispatch-ledger-helper.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export AIDEVOPS_DISPATCH_LEDGER_DIR="${TMP_DIR}/ledger"
export AIDEVOPS_DEVICE_ID="device-fixture-a"
mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"

fail() { printf 'FAIL %s\n' "$1" >&2; return 1; }
pass() { printf 'PASS %s\n' "$1"; return 0; }

"$LEDGER" register --session-key issue-27165 --issue 27165 --repo owner/repo \
	--pid 99999999 --lease-token token-a --device-id device-fixture-a --lease-ttl 60
[[ $(jq -r 'select(.session_key=="issue-27165") | .lease_phase' "$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl") == prelaunch ]] \
	|| fail "prelaunch lease is persisted"
pass "prelaunch lease is persisted"

if "$LEDGER" ready --session-key issue-27165 --lease-token wrong-token >/dev/null 2>&1; then
	fail "wrong token cannot transition lease"
fi
pass "wrong token cannot transition lease"

"$LEDGER" ready --session-key issue-27165 --lease-token token-a --lease-ttl 60
latest=$(jq -sc '[.[] | select(.session_key=="issue-27165")] | last' "$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl")
[[ $(printf '%s' "$latest" | jq -r '.lease_phase') == ready ]] || fail "token-qualified ready transition"
[[ $(printf '%s' "$latest" | jq -r '.runner_device') == device-fixture-a ]] || fail "device identity survives transition"
pass "token-qualified ready transition preserves device identity"

# A dead local PID must not imply remote completion for a lease-aware record.
"$LEDGER" check --session-key issue-27165 >/dev/null || fail "ready lease survives local PID exit"
pass "ready lease survives local PID exit"

"$LEDGER" complete --session-key issue-27165 --lease-token token-a
latest=$(jq -sc '[.[] | select(.session_key=="issue-27165")] | last' "$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl")
[[ $(printf '%s' "$latest" | jq -r '.lease_phase + ":" + .status') == terminal:completed ]] \
	|| fail "terminal transition is append-only"
[[ $(wc -l <"$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl" | tr -d ' ') -eq 3 ]] \
	|| fail "lease history contains prelaunch ready terminal records"
pass "terminal transition appends immutable evidence"

# Backward compatibility: legacy records remain readable and retain their
# historical dead-PID cleanup semantics.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"session_key":"legacy","issue_number":"1","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$now" "$now" >>"$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl"
if "$LEDGER" check --session-key legacy >/dev/null 2>&1; then
	fail "legacy dead-PID marker remains readable"
fi
pass "legacy markers remain readable"

grep -Fq 'AIDEVOPS_DISPATCH_LEASE_TOKEN=' "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" || fail "launch token wiring"
grep -Fq 'transition ready' "${SCRIPTS_DIR}/headless-runtime-worker.sh" || fail "readiness wiring"
grep -Fq 'transition terminal' "${SCRIPTS_DIR}/worker-lifecycle-common.sh" || fail "terminal wiring"
grep -Fq '_stale_recovery_final_evidence_recheck' "${SCRIPTS_DIR}/dispatch-dedup-stale.sh" || fail "takeover recheck wiring"
pass "launch readiness terminal and takeover wiring is present"

printf '\nAtomic lease tests passed\n'
exit 0
