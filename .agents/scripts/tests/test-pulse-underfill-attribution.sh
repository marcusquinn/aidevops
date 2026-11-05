#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT"
mkdir -p "$HOME/.aidevops/logs"
LOGFILE="$HOME/.aidevops/logs/pulse.log"
: >"$LOGFILE"
_PULSE_DISPATCH_ENGINE_SCRIPT_DIR="$SCRIPT_DIR"
# Exercise the production functions without launching the Pulse orchestrator.
eval "$(awk '/^_underfill_host_sample\(\)/ {copy=1} /^# Recycle stale workers/ {copy=0} copy' "$SCRIPT_DIR/pulse-dispatch-engine.sh")"
host_sample='24 5.0 99000 10000000'
_underfill_host_sample() {
	printf '%s\n' "$host_sample"
	return 0
}
_preflight_launch_async_cleanup() {
	printf '%s\n' "$*" >>"$TEST_ROOT/cleanup-calls"
	return 0
}
cycle() {
	local id="$1" target="${2:-32}" active="${3:-0}" runnable="${4:-92}"
	_PULSE_CYCLE_ID="$id"
	printf 'pre-launch failure stage=dispatch_with_dedup rc=1 reason=local_capacity_gate\n' >>"$LOGFILE"
	_attribute_sustained_underfill "$target" "$active" "$runnable"
	return 0
}
state="$HOME/.aidevops/cache/pulse-underfill.json"
advisory="$HOME/.aidevops/advisories/underfill-local_capacity_gate.advisory"
cycle one
cycle two
[[ ! -f "$advisory" ]]
# Multiple recycler calls in one cycle must not advance the trigger.
cycle two
jq -e '.streak == 2' "$state" >/dev/null
cycle three
[[ -f "$advisory" ]]
[[ $(rg -c UNDERFILL_ATTRIBUTION "$LOGFILE") == 1 ]]
# wc pads with spaces on macOS; compare numerically.
(($(wc -l <"$TEST_ROOT/cleanup-calls") == 1))
jq -e '.streak == 3 and (.top | startswith("local_capacity_gate:")) and .host.cores == "24"' "$state" >/dev/null
cycle four
[[ $(rg -c UNDERFILL_ATTRIBUTION "$LOGFILE") == 1 ]]
(($(wc -l <"$TEST_ROOT/cleanup-calls") == 1))
cycle recovered 32 30
[[ ! -f "$advisory" ]]
jq -e '.streak == 0 and .escalated == {} and .top == ""' "$state" >/dev/null
cycle five
cycle six
cycle seven
[[ $(rg -c UNDERFILL_ATTRIBUTION "$LOGFILE") == 2 ]]
cycle no-work 32 0 0
jq -e '.streak == 0' "$state" >/dev/null
# CPU load is never a launch gate (t3558): a saturated shared host still
# accumulates the streak so real launch gates surface.
host_sample='24 48.0 99000 10000000'
cycle busy-one
cycle busy-two
jq -e '.streak == 2' "$state" >/dev/null
host_sample='24 5.0 6000 10000000'
cycle low-memory
jq -e '.streak == 0' "$state" >/dev/null
host_sample='24 5.0 99000 10000000'
# Rotation/truncation must not retain a cursor past EOF.
: >"$LOGFILE"
cycle rotated
jq -e '.reasons[0].reason == "local_capacity_gate"' "$state" >/dev/null
# Dedupe expiry, without sleeping or changing the clock.
jq '.escalated.local_capacity_gate = 1' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
cycle eight
cycle nine
[[ $(rg -c UNDERFILL_ATTRIBUTION "$LOGFILE") == 1 ]]
# A full operator-clamped pool still reveals the suppressed capacity.
printf '{"timestamp":%s,"detected_target":32,"config_clamp":true}\n' "$(date +%s)" >"$HOME/.aidevops/cache/pulse-underfill-capacity.json"
cycle clamp-one 3 3
cycle clamp-two 3 3
cycle clamp-three 3 3
jq -e '.deficit == 90 and (.reasons | any(.reason == "config_clamp"))' "$state" >/dev/null
[[ -f "$HOME/.aidevops/advisories/underfill-config_clamp.advisory" ]]
# Real cycles run ~25 minutes: a 1600s gap is still consecutive, a gap beyond
# the window restarts the streak.
rm -f "$HOME/.aidevops/cache/pulse-underfill-capacity.json"
cycle long-one
jq --argjson t "$(($(date +%s) - 1600))" '.timestamp = $t' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
before=$(jq '.streak' "$state")
cycle long-two
jq -e --argjson b "$before" '.streak == $b + 1' "$state" >/dev/null
jq --argjson t "$(($(date +%s) - 6000))" '.timestamp = $t' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
cycle long-gap
jq -e '.streak == 1' "$state" >/dev/null
# The deterministic dispatch path must feed attribution, not only active refill.
awk '/^dispatch_max\(\) \{/ {f=1} f && /^}/ {exit} f' "$SCRIPT_DIR/pulse-dispatch-engine.sh" | rg -q '_dispatch_attribute_round_underfill'
awk '/^_dispatch_attribute_round_underfill\(\) \{/ {f=1} f && /^}/ {exit} f' "$SCRIPT_DIR/pulse-dispatch-engine.sh" | rg -q '_attribute_sustained_underfill'
printf 'Dispatch blocked: waiting for a scoped signed maintainer permission grant\nDispatch blocked: secret store unlock expired\nDispatch blocked: GitHub pacing cooldown\nDispatch blocked: worktree capacity unavailable\n' >"$LOGFILE"
_underfill_reason_tally 0 | jq -e 'length == 4 and any(.reason == "permission_gate") and any(.reason == "secret_gate") and any(.reason == "github_pacing") and any(.reason == "worktree_cap")' >/dev/null
end=$(wc -c <"$LOGFILE")
printf 'pre-launch failure reason=local_capacity_gate\n' >>"$LOGFILE"
_underfill_reason_tally 0 "$end" | jq -e 'all(.reason != "local_capacity_gate")' >/dev/null
printf 'pre-launch failure reason=private_identifier_123\n' >"$LOGFILE"
_underfill_reason_tally 0 | jq -e '.[0].reason == "dispatch_blocked"' >/dev/null
# A replaced log larger than the old cursor must be read from its beginning.
mv "$LOGFILE" "$LOGFILE.old"
printf 'Dispatch blocked: secret store unlock expired\n%4096s\n' '' >"$LOGFILE"
cycle replaced
jq -e '.reasons | any(.reason == "secret_gate")' "$state" >/dev/null
printf 'PASS: sustained trigger, same-cycle guard, dedupe, expiry, recovery, headroom, rotation, config clamp and prose attribution\n'
