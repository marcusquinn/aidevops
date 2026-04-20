#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-cross-runner-coordination.sh — regression tests for t2422 cross-runner coordination
#
# Validates:
#   1. Structured per-runner override: honour-only-above ignores old version
#   2. Structured per-runner override: honour-only-above passes new version
#   3. Structured per-runner override: plain ignore
#   4. Structured per-runner override: warn action
#   5. Structured fallback to DISPATCH_OVERRIDE_DEFAULT
#   6. Legacy flat list still works with deprecation warning
#   7. Override master switch disables all filtering
#   8. Tiebreaker: earlier ts wins
#   9. Tiebreaker: same ts, lower nonce wins
#  10. Tiebreaker: identical inputs → self wins (defensive)
#  11. dispatch-override-resolve.sh check-deprecated detects flat list
#  12. _apply_ignore_filter uses structured resolver when available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../dispatch-override-resolve.sh"
CLAIM_HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"

PASS=0
FAIL=0

assert_eq() {
	local expected="$1"
	local actual="$2"
	local msg="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$msg"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s (expected: %q, got: %q)\n' "$msg" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# Source claim helper's internal functions (strip main invocation)
_source_claim_helper() {
	local tmp
	tmp=$(mktemp)
	sed '/^main "$@"$/d' "$CLAIM_HELPER" >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	# Fix paths — sourcing from temp sets SCRIPT_DIR to /tmp/ which breaks
	# OVERRIDE_RESOLVER resolution. Use the known script directory directly.
	SCRIPT_DIR="${SCRIPT_DIR%/tests}"  # noop if already parent
	OVERRIDE_RESOLVER="${SCRIPT_DIR}/../dispatch-override-resolve.sh"
	# If that doesn't exist, use the scripts-dir-based path
	if [[ ! -x "$OVERRIDE_RESOLVER" ]]; then
		OVERRIDE_RESOLVER="$(cd "$(dirname "$CLAIM_HELPER")" && pwd)/dispatch-override-resolve.sh"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────────────
# Phase B: Structured per-runner overrides via dispatch-override-resolve.sh
# ──────────────────────────────────────────────────────────────────────

test_structured_honour_only_above_old_version() {
	printf '\nTest 1: structured override honour-only-above ignores old version\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"
DISPATCH_OVERRIDE_DEFAULT="honour"
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "alex-solovyev" "3.8.50" 2>/dev/null)
	assert_eq "ignore" "$result" "alex-solovyev 3.8.50 < floor 3.8.78 → ignore"
	rm -f "$tmp_conf"
	return 0
}

test_structured_honour_only_above_new_version() {
	printf '\nTest 2: structured override honour-only-above passes new version\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"
DISPATCH_OVERRIDE_DEFAULT="honour"
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "alex-solovyev" "3.9.0" 2>/dev/null)
	assert_eq "honour" "$result" "alex-solovyev 3.9.0 >= floor 3.8.78 → honour"
	rm -f "$tmp_conf"
	return 0
}

test_structured_ignore() {
	printf '\nTest 3: structured override plain ignore\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_STALE_PEER="ignore"
DISPATCH_OVERRIDE_DEFAULT="honour"
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "stale-peer" "3.9.0" 2>/dev/null)
	assert_eq "ignore" "$result" "stale-peer always ignored regardless of version"
	rm -f "$tmp_conf"
	return 0
}

test_structured_warn() {
	printf '\nTest 4: structured override warn action\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_FLAKY_RUNNER="warn"
DISPATCH_OVERRIDE_DEFAULT="honour"
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "flaky-runner" "3.9.0" 2>/dev/null)
	assert_eq "warn" "$result" "flaky-runner gets warn action"
	rm -f "$tmp_conf"
	return 0
}

test_structured_default_fallback() {
	printf '\nTest 5: structured fallback to DISPATCH_OVERRIDE_DEFAULT\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_DEFAULT="honour"
DISPATCH_CLAIM_IGNORE_RUNNERS=""
DISPATCH_CLAIM_MIN_VERSION=""
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "unknown-runner" "3.9.0" 2>/dev/null)
	assert_eq "honour" "$result" "unknown runner falls through to default honour"
	rm -f "$tmp_conf"
	return 0
}

test_legacy_flat_list_with_deprecation() {
	printf '\nTest 6: legacy flat list still works with deprecation warning\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_CLAIM_IGNORE_RUNNERS="legacy-peer"
DISPATCH_CLAIM_MIN_VERSION=""
EOF
	local result stderr_out
	stderr_out=$(mktemp)
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "legacy-peer" "3.9.0" 2>"$stderr_out")
	assert_eq "ignore" "$result" "legacy flat list: legacy-peer → ignore"

	# Check deprecation warning was emitted
	if grep -q "DEPRECATED" "$stderr_out"; then
		printf '  PASS: deprecation warning emitted\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: no deprecation warning emitted\n'
		FAIL=$((FAIL + 1))
	fi
	rm -f "$tmp_conf" "$stderr_out"
	return 0
}

test_master_switch_disabled() {
	printf '\nTest 7: override master switch disables all filtering\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=false
DISPATCH_OVERRIDE_ALEX_SOLOVYEV="ignore"
DISPATCH_CLAIM_IGNORE_RUNNERS="other-peer"
EOF
	local result
	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "alex-solovyev" "3.8.50" 2>/dev/null)
	assert_eq "honour" "$result" "master switch false: alex → honour despite ignore override"

	result=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" resolve "other-peer" "3.9.0" 2>/dev/null)
	assert_eq "honour" "$result" "master switch false: legacy peer → honour despite flat list"
	rm -f "$tmp_conf"
	return 0
}

# ──────────────────────────────────────────────────────────────────────
# Phase C: Tiebreaker for simultaneous claims
# ──────────────────────────────────────────────────────────────────────

test_tiebreaker_earlier_ts_wins() {
	printf '\nTest 8: tiebreaker — earlier ts wins\n'
	_source_claim_helper

	if _tiebreaker "2026-04-20T00:00:01Z" "abc" "2026-04-20T00:00:03Z" "xyz"; then
		printf '  PASS: earlier ts (01Z) beats later ts (03Z)\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: earlier ts should win\n'
		FAIL=$((FAIL + 1))
	fi

	# Reverse: later ts loses
	if _tiebreaker "2026-04-20T00:00:05Z" "abc" "2026-04-20T00:00:03Z" "xyz"; then
		printf '  FAIL: later ts (05Z) should not beat earlier ts (03Z)\n'
		FAIL=$((FAIL + 1))
	else
		printf '  PASS: later ts (05Z) loses to earlier ts (03Z)\n'
		PASS=$((PASS + 1))
	fi
	return 0
}

test_tiebreaker_same_ts_nonce_wins() {
	printf '\nTest 9: tiebreaker — same ts, lower nonce wins\n'
	_source_claim_helper

	if _tiebreaker "2026-04-20T00:00:01Z" "aaa111" "2026-04-20T00:00:01Z" "zzz999"; then
		printf '  PASS: lower nonce (aaa111) beats higher nonce (zzz999)\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: lower nonce should win on same ts\n'
		FAIL=$((FAIL + 1))
	fi

	# Reverse: higher nonce loses
	if _tiebreaker "2026-04-20T00:00:01Z" "zzz999" "2026-04-20T00:00:01Z" "aaa111"; then
		printf '  FAIL: higher nonce (zzz999) should not beat lower nonce (aaa111)\n'
		FAIL=$((FAIL + 1))
	else
		printf '  PASS: higher nonce (zzz999) loses to lower nonce (aaa111)\n'
		PASS=$((PASS + 1))
	fi
	return 0
}

test_tiebreaker_identical() {
	printf '\nTest 10: tiebreaker — identical inputs (defensive, self wins)\n'
	_source_claim_helper

	if _tiebreaker "2026-04-20T00:00:01Z" "same" "2026-04-20T00:00:01Z" "same"; then
		printf '  PASS: identical inputs → self wins (defensive)\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: identical inputs should return win (exit 0)\n'
		FAIL=$((FAIL + 1))
	fi
	return 0
}

test_check_deprecated() {
	printf '\nTest 11: check-deprecated detects flat list\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_CLAIM_IGNORE_RUNNERS="old-peer"
DISPATCH_CLAIM_MIN_VERSION="3.8.0"
EOF
	local output
	output=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$RESOLVER" check-deprecated 2>&1)
	local rc=$?
	assert_eq "0" "$rc" "check-deprecated exits 0 when deprecated entries present"

	if echo "$output" | grep -q "DEPRECATED.*DISPATCH_CLAIM_IGNORE_RUNNERS"; then
		printf '  PASS: flat list deprecation detected\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: flat list deprecation not detected\n'
		FAIL=$((FAIL + 1))
	fi

	if echo "$output" | grep -q "DEPRECATED.*DISPATCH_CLAIM_MIN_VERSION"; then
		printf '  PASS: version floor deprecation detected\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: version floor deprecation not detected\n'
		FAIL=$((FAIL + 1))
	fi
	rm -f "$tmp_conf"
	return 0
}

test_apply_filter_uses_resolver() {
	printf '\nTest 12: _apply_ignore_filter uses structured resolver when available\n'
	_source_claim_helper

	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_OVERRIDE_ENABLED=true
DISPATCH_OVERRIDE_ALICE="ignore"
DISPATCH_OVERRIDE_DEFAULT="honour"
DISPATCH_CLAIM_IGNORE_RUNNERS=""
DISPATCH_CLAIM_MIN_VERSION=""
EOF

	local parsed='[{"id":1,"runner":"alice","version":"3.9.0","nonce":"n1","ts":"2026-04-20T00:00:01Z","created_at":"2026-04-20T00:00:01Z","created_epoch":1745107201,"age_seconds":10},{"id":2,"runner":"bob","version":"3.9.0","nonce":"n2","ts":"2026-04-20T00:00:02Z","created_at":"2026-04-20T00:00:02Z","created_epoch":1745107202,"age_seconds":9}]'

	# Export DISPATCH_OVERRIDE_CONF so subprocesses (resolver) can read it.
	# Also set DISPATCH_OVERRIDE_ENABLED in this shell (sourced helper reads it).
	local saved_conf="${DISPATCH_OVERRIDE_CONF:-}"
	local saved_enabled="${DISPATCH_OVERRIDE_ENABLED:-}"
	export DISPATCH_OVERRIDE_CONF="$tmp_conf"
	DISPATCH_OVERRIDE_ENABLED=true
	DISPATCH_CLAIM_IGNORE_RUNNERS=""
	DISPATCH_CLAIM_MIN_VERSION=""

	local result
	result=$(_apply_ignore_filter "$parsed" "42" "owner/repo" 2>/dev/null)

	local runners
	runners=$(printf '%s' "$result" | jq -r '.[].runner' 2>/dev/null | sort | tr '\n' ',')
	assert_eq "bob," "$runners" "structured filter: alice (ignore) removed, bob kept"

	# Restore
	DISPATCH_OVERRIDE_CONF="$saved_conf"
	DISPATCH_OVERRIDE_ENABLED="$saved_enabled"
	rm -f "$tmp_conf"
	return 0
}

# ──────────────────────────────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────────────────────────────

test_structured_honour_only_above_old_version
test_structured_honour_only_above_new_version
test_structured_ignore
test_structured_warn
test_structured_default_fallback
test_legacy_flat_list_with_deprecation
test_master_switch_disabled
test_tiebreaker_earlier_ts_wins
test_tiebreaker_same_ts_nonce_wins
test_tiebreaker_identical
test_check_deprecated
test_apply_filter_uses_resolver

printf '\n========================\n'
printf 'Passed: %d, Failed: %d\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
