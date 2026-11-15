#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-claim-handoff.sh — claim-win/handoff-lease tests for
# dispatch-claim-helper.sh. Sourced by test-dispatch-claim-helper.sh, which
# provides CLAIM_HELPER and print_result.

# Include guard
[[ -n "${_TEST_DISPATCH_CLAIM_HANDOFF_LOADED:-}" ]] && return 0
_TEST_DISPATCH_CLAIM_HANDOFF_LOADED=1

test_claim_winner_persisted_expiry() {
	local result=0
	(
		local implementation="" output="" rc=0
		implementation=$(awk '/^_resolve_claim_race_result\(\) \{/,/^}$/ { print }' "$CLAIM_HELPER")
		eval "$implementation"
		LEGACY_DEVICE_MARKER=legacy
		_resolve_device_id() { printf 'fixture-device'; }
		_now_epoch() { printf '1050'; }
		output=$(_resolve_claim_race_result 42 owner/repo runner fixture 10 '[{"nonce":"fixture","runner":"runner","device":"fixture-device","age_seconds":50,"lease_expires_at":1120}]') || return 1
		[[ "$output" == *"expires_at=1120" ]] || return 1
		_now_epoch() { printf '1121'; }
		_resolve_claim_race_result 42 owner/repo runner fixture 10 '[{"nonce":"fixture","runner":"runner","device":"fixture-device","age_seconds":121,"lease_expires_at":1120}]' >/dev/null 2>&1 || rc=$?
		[[ "$rc" == 2 ]]
	) || result=1
	print_result "CLAIM_WON reports persisted expiry and rejects consensus-expired leases" "$result"
	return 0
}

# GH#36771: slow consensus must renew a mostly-consumed winning lease before
# handoff, never renew an expired one, and fail closed when renewal is denied.
test_claim_handoff_lease_after_slow_consensus() {
	local result=0
	(
		local implementation="" calls="" rc=0
		implementation=$(awk '/^_ensure_claim_handoff_lease\(\) \{/,/^}$/ { print }' "$CLAIM_HELPER")
		eval "$implementation"
		DISPATCH_CLAIM_ORPHAN_GRACE=120
		LEASE_PHASE_PRELAUNCH=prelaunch
		_now_epoch() { printf '1000'; }
		cmd_transition() { calls+="$*;"; return "${TRANSITION_RC:-0}"; }
		# Ample remaining lease: no public renewal.
		_ensure_claim_handoff_lease 42 owner/repo token 1100 2>/dev/null || return 1
		[[ -z "$calls" ]] || return 1
		# A newly posted claim cannot use legacy missing-expiry semantics.
		_ensure_claim_handoff_lease 42 owner/repo token 0 2>/dev/null && return 1
		[[ -z "$calls" ]] || return 1
		# 12s left after a 78s final guard: renew once with the grace TTL.
		_ensure_claim_handoff_lease 42 owner/repo token 1012 2>/dev/null || return 1
		[[ "$calls" == "prelaunch 42 owner/repo token issue-42 120;" ]] || return 1
		# Expired during consensus: never renewed or revived.
		calls=""
		_ensure_claim_handoff_lease 42 owner/repo token 999 2>/dev/null && return 1
		[[ -z "$calls" ]] || return 1
		# Denied renewal (owner/device/session/expiry checks) fails closed.
		TRANSITION_RC=1
		rc=0
		_ensure_claim_handoff_lease 42 owner/repo token 1012 2>/dev/null || rc=$?
		[[ "$rc" == 1 ]] || return 1
		_ensure_claim_handoff_lease 42 owner/repo token not-a-number 2>/dev/null && return 1
		return 0
	) || result=1
	print_result "slow consensus renews a mostly-consumed won lease and fails closed when expired" "$result"
	return 0
}

test_claim_publishes_win_only_after_handoff() {
	local result=0
	(
		local implementation="" output="" expiry="" rc=0
		implementation=$(awk '/^cmd_claim\(\) \{/,/^}$/ { print } /^_ensure_claim_handoff_lease\(\) \{/,/^}$/ { print }' "$CLAIM_HELPER")
		eval "$implementation"
		AIDEVOPS_TEST_MODE=1
		DISPATCH_CLAIM_WINDOW=0
		DISPATCH_CLAIM_ORPHAN_GRACE=120
		LEASE_PHASE_PRELAUNCH=prelaunch
		_resolve_runner() { printf 'runner'; return 0; }
		_guard_no_active_assignment_before_claim() { return 0; }
		_generate_nonce() { printf 'fixture'; return 0; }
		_now_utc() { printf 'fixture-time'; return 0; }
		_now_epoch() { printf '1000'; return 0; }
		_detect_stale_worker_takeover_reason() { return 0; }
		_post_claim() { printf '10'; return 0; }
		_dch_timed() { shift; "$@"; return $?; }
		_fetch_claims_until_own_visible() { printf '[{"lease_expires_at":%s}]' "$expiry"; return 0; }
		_resolve_claim_race_result() { printf 'CLAIM_WON: fixture\n'; return 0; }
		cmd_transition() { return 1; }
		# Missing/invalid expiry parses as zero; denied renewal also fails closed.
		for expiry in 0 1012; do
			rc=0
			output=$(cmd_claim 42 owner/repo runner 2>/dev/null) || rc=$?
			[[ "$rc" == 2 && "$output" != *CLAIM_WON* ]] || return 1
		done
		expiry=1100
		output=$(cmd_claim 42 owner/repo runner 2>/dev/null) || return 1
		[[ "$output" == 'CLAIM_WON: fixture' ]] || return 1
		_resolve_claim_race_result() { printf 'CLAIM_LOST: fixture\n'; return 1; }
		rc=0
		output=$(cmd_claim 42 owner/repo runner 2>/dev/null) || rc=$?
		[[ "$rc" == 1 && "$output" == 'CLAIM_LOST: fixture' ]] || return 1
		return 0
	) || result=1
	print_result "claim emits no win on missing expiry or denied handoff and preserves race output" "$result"
	return 0
}
