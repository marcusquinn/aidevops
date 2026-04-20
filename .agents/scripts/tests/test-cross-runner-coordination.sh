#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-cross-runner-coordination.sh — tests for structured cross-runner
# dispatch coordination (t2422).
#
# Covers the three new mechanisms introduced by t2422:
#   1. Structured per-runner override resolver (dispatch-override-resolve.sh):
#      - honour / ignore / warn actions
#      - honour-only-above:V / ignore-below:V version gating
#      - DISPATCH_OVERRIDE_DEFAULT fallback
#      - DISPATCH_OVERRIDE_ENABLED master switch
#      - Slug normalisation (alex-solovyev → ALEX_SOLOVYEV)
#      - Legacy config detection
#
#   2. Structured filter integration (dispatch-claim-helper.sh):
#      - _apply_structured_filter strips ignore-action claims
#      - warn-action claims pass through with log line
#      - coexists with legacy DISPATCH_CLAIM_IGNORE_RUNNERS / MIN_VERSION
#      - no-op fast paths when nothing configured
#
#   3. Simultaneous-claim tiebreaker + CLAIM_DEFERRED audit:
#      - sort_by([.created_at, .nonce]) in _fetch_claims parse step
#      - _post_deferred comment body format
#      - close-window detection (delta <= DISPATCH_TIEBREAKER_WINDOW)
#
# All tests are hermetic — no network or real GitHub access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAIM_HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"
RESOLVER="${SCRIPT_DIR}/../dispatch-override-resolve.sh"

PASS=0
FAIL=0

_source_claim_helper() {
	# Pre-set DISPATCH_CLAIM_HELPER_DIR so that when the sourced tempfile
	# tries to source dispatch-override-resolve.sh, it finds the real one
	# at the original directory — not the tempfile's /tmp directory.
	export DISPATCH_CLAIM_HELPER_DIR
	DISPATCH_CLAIM_HELPER_DIR="$(dirname "$CLAIM_HELPER")"

	local tmp
	tmp=$(mktemp)
	sed '/^main "$@"$/d' "$CLAIM_HELPER" >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	return 0
}

_source_resolver() {
	# shellcheck disable=SC1090
	source "$RESOLVER"
	return 0
}

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

assert_exit() {
	local expected="$1"
	local actual="$2"
	local msg="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$msg"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s (expected exit %s, got %s)\n' "$msg" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ==============================================================================
# Phase 1: dispatch-override-resolve.sh — unit tests
# ==============================================================================

# Test 1: slug normalisation
test_slug_normalisation() {
	printf '\nTest 1: slug normalisation (login → UPPER_WITH_UNDERSCORES)\n'
	_source_resolver

	local slug
	slug=$(_override_login_to_slug "alex-solovyev")
	assert_eq "ALEX_SOLOVYEV" "$slug" "alex-solovyev → ALEX_SOLOVYEV"

	slug=$(_override_login_to_slug "bot.user")
	assert_eq "BOT_USER" "$slug" "bot.user → BOT_USER"

	slug=$(_override_login_to_slug "github-actions")
	assert_eq "GITHUB_ACTIONS" "$slug" "github-actions → GITHUB_ACTIONS"

	slug=$(_override_login_to_slug "plain")
	assert_eq "PLAIN" "$slug" "plain → PLAIN"

	slug=$(_override_login_to_slug "user@example.com")
	assert_eq "USER_EXAMPLE_COM" "$slug" "email-like → USER_EXAMPLE_COM"

	slug=$(_override_login_to_slug "")
	assert_eq "" "$slug" "empty → empty"
	return 0
}

# Test 2: action honour + default
test_action_honour() {
	printf '\nTest 2: action=honour (explicit + default)\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ALICE="honour" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "explicit honour"

	# Unlisted runner, no default → honour
	unset DISPATCH_OVERRIDE_ALICE DISPATCH_OVERRIDE_DEFAULT
	out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "unlisted runner → honour default"

	DISPATCH_OVERRIDE_DEFAULT="honour" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "default=honour explicit"
	unset DISPATCH_OVERRIDE_DEFAULT
	return 0
}

# Test 3: action ignore
test_action_ignore() {
	printf '\nTest 3: action=ignore\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ALICE="ignore" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "ignore" "$out" "explicit ignore"

	# version field should not affect plain "ignore"
	DISPATCH_OVERRIDE_ALICE="ignore" out=$(_override_resolve "alice" "unknown")
	assert_eq "ignore" "$out" "ignore ignores version"
	unset DISPATCH_OVERRIDE_ALICE
	return 0
}

# Test 4: action warn
test_action_warn() {
	printf '\nTest 4: action=warn\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ALICE="warn" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "warn" "$out" "warn returns warn"
	unset DISPATCH_OVERRIDE_ALICE
	return 0
}

# Test 5: honour-only-above version gating
test_honour_only_above() {
	printf '\nTest 5: honour-only-above:V version gating\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"

	out=$(_override_resolve "alex-solovyev" "3.8.77")
	assert_eq "ignore" "$out" "version below floor → ignore"

	out=$(_override_resolve "alex-solovyev" "3.8.78")
	assert_eq "honour" "$out" "version equal floor → honour"

	out=$(_override_resolve "alex-solovyev" "3.8.79")
	assert_eq "honour" "$out" "version above floor → honour"

	out=$(_override_resolve "alex-solovyev" "unknown")
	assert_eq "ignore" "$out" "unknown version below any floor → ignore"

	out=$(_override_resolve "alex-solovyev" "3.8.100")
	assert_eq "honour" "$out" "numeric semver (3.8.100 > 3.8.78) → honour"
	unset DISPATCH_OVERRIDE_ALEX_SOLOVYEV
	return 0
}

# Test 6: ignore-below synonym
test_ignore_below_synonym() {
	printf '\nTest 6: ignore-below:V is a synonym of honour-only-above\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_BOB="ignore-below:4.0.0"

	out=$(_override_resolve "bob" "3.9.9")
	assert_eq "ignore" "$out" "ignore-below: version below floor → ignore"

	out=$(_override_resolve "bob" "4.0.0")
	assert_eq "honour" "$out" "ignore-below: version at floor → honour"
	unset DISPATCH_OVERRIDE_BOB
	return 0
}

# Test 7: master switch disable
test_master_switch() {
	printf '\nTest 7: DISPATCH_OVERRIDE_ENABLED=false honours everything\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ENABLED=false \
		DISPATCH_OVERRIDE_ALICE="ignore" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "disabled switch → honour despite ignore"

	DISPATCH_OVERRIDE_ENABLED=false \
		DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.9.0" \
		out=$(_override_resolve "alex-solovyev" "3.8.0")
	assert_eq "honour" "$out" "disabled switch → honour despite version gate"

	unset DISPATCH_OVERRIDE_ALICE DISPATCH_OVERRIDE_ALEX_SOLOVYEV
	return 0
}

# Test 8: ill-formed action defaults to honour
test_ill_formed_action() {
	printf '\nTest 8: ill-formed action defaults to honour\n'
	_source_resolver

	local out
	DISPATCH_OVERRIDE_ALICE="honour-only-above" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "honour-only-above with no min_ver → honour"

	DISPATCH_OVERRIDE_ALICE="nonsense-action" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "unknown action keyword → honour"

	DISPATCH_OVERRIDE_ALICE="" out=$(_override_resolve "alice" "3.9.0")
	assert_eq "honour" "$out" "empty override → honour"
	unset DISPATCH_OVERRIDE_ALICE
	return 0
}

# Test 9: legacy config detection
test_legacy_detection() {
	printf '\nTest 9: check-legacy exits 0 when DISPATCH_CLAIM_IGNORE_RUNNERS is set\n'

	# Use `if ! cmd` pattern to survive `set -e` on non-zero returns.
	local exit_code

	if DISPATCH_CLAIM_IGNORE_RUNNERS="alex-solovyev" bash "$RESOLVER" check-legacy 2>/dev/null; then
		exit_code=0
	else
		exit_code=$?
	fi
	assert_exit "0" "$exit_code" "legacy config → exit 0 with hint"

	if (unset DISPATCH_CLAIM_IGNORE_RUNNERS; bash "$RESOLVER" check-legacy 2>/dev/null); then
		exit_code=0
	else
		exit_code=$?
	fi
	assert_exit "1" "$exit_code" "clean config → exit 1"
	return 0
}

# ==============================================================================
# Phase 2: _apply_structured_filter integration (dispatch-claim-helper.sh)
# ==============================================================================

# Test 10: structured filter strips ignore-action claims
test_structured_filter_ignore() {
	printf '\nTest 10: _apply_structured_filter strips ignore-action claims\n'
	_source_claim_helper

	local parsed='[
		{"id":1,"runner":"alice","version":"3.9.0"},
		{"id":2,"runner":"bob","version":"3.9.0"},
		{"id":3,"runner":"alex-solovyev","version":"3.8.77"}
	]'

	# alex-solovyev with below-floor version → ignored; others kept
	local result runners
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78" \
		result=$(_apply_structured_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	runners=$(printf '%s' "$result" | jq -r '.[].runner' | sort | tr '\n' ',')
	assert_eq "alice,bob," "$runners" "alex filtered out, alice+bob kept"

	# alex upgrades to 3.8.78 → honoured (structured sunset)
	parsed='[
		{"id":1,"runner":"alice","version":"3.9.0"},
		{"id":2,"runner":"alex-solovyev","version":"3.8.78"}
	]'
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78" \
		result=$(_apply_structured_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	runners=$(printf '%s' "$result" | jq -r '.[].runner' | sort | tr '\n' ',')
	assert_eq "alex-solovyev,alice," "$runners" "post-upgrade alex → honoured"

	unset DISPATCH_OVERRIDE_ALEX_SOLOVYEV
	return 0
}

# Test 11: structured filter keeps warn-action claims
test_structured_filter_warn() {
	printf '\nTest 11: warn action keeps claim (emits stderr)\n'
	_source_claim_helper

	local parsed='[{"id":1,"runner":"alice","version":"3.9.0"}]'

	# warn → claim kept
	local result count
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_OVERRIDE_ALICE="warn" \
		result=$(_apply_structured_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	count=$(printf '%s' "$result" | jq 'length')
	assert_eq "1" "$count" "warn claim retained (length=1)"

	unset DISPATCH_OVERRIDE_ALICE
	return 0
}

# Test 12: no-op fast paths
test_structured_filter_noop() {
	printf '\nTest 12: _apply_structured_filter no-op fast paths\n'
	_source_claim_helper

	local parsed='[{"id":1,"runner":"alice","version":"3.9.0"}]'
	local result

	# No DISPATCH_OVERRIDE_* vars and no DEFAULT → no-op
	unset DISPATCH_OVERRIDE_DEFAULT
	local v
	for v in $(compgen -v | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$v" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED) ;;
		DISPATCH_OVERRIDE_*) unset "$v" ;;
		esac
	done

	DISPATCH_OVERRIDE_ENABLED=true \
		result=$(_apply_structured_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	assert_eq "$parsed" "$result" "no structured vars → input unchanged"

	# Master switch disabled → no-op even with vars set
	DISPATCH_OVERRIDE_ENABLED=false \
		DISPATCH_OVERRIDE_ALICE="ignore" \
		result=$(_apply_structured_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	assert_eq "$parsed" "$result" "disabled switch → input unchanged"

	unset DISPATCH_OVERRIDE_ALICE
	return 0
}

# Test 13: structured + legacy coexistence
test_combined_filters() {
	printf '\nTest 13: structured + legacy filters coexist via _apply_ignore_filter\n'
	_source_claim_helper

	# Scenario: alice legacy-ignored, bob structurally ignored (version below),
	# charlie surviving both.
	local parsed='[
		{"id":1,"runner":"alice","version":"3.9.0"},
		{"id":2,"runner":"bob","version":"3.8.0"},
		{"id":3,"runner":"charlie","version":"3.9.0"}
	]'

	# Unset any leftovers from prior tests
	unset DISPATCH_OVERRIDE_ALICE DISPATCH_OVERRIDE_BOB DISPATCH_OVERRIDE_CHARLIE DISPATCH_OVERRIDE_DEFAULT
	local v
	for v in $(compgen -v | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$v" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED) ;;
		DISPATCH_OVERRIDE_*) unset "$v" ;;
		esac
	done

	local result runners
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_CLAIM_IGNORE_RUNNERS="alice" \
		DISPATCH_CLAIM_MIN_VERSION="" \
		DISPATCH_OVERRIDE_BOB="honour-only-above:3.9.0" \
		result=$(_apply_ignore_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	runners=$(printf '%s' "$result" | jq -r '.[].runner' | sort | tr '\n' ',')
	assert_eq "charlie," "$runners" "legacy-ignore alice + structured-ignore bob"

	unset DISPATCH_CLAIM_IGNORE_RUNNERS DISPATCH_OVERRIDE_BOB
	return 0
}

# ==============================================================================
# Phase 3: tiebreaker + CLAIM_DEFERRED
# ==============================================================================

# Test 14: sort_by with nonce tiebreaker (jq logic mirroring _fetch_claims)
test_nonce_tiebreaker() {
	printf '\nTest 14: sort_by([.created_at, .nonce]) deterministic tiebreaker\n'

	# Two claims with the same timestamp but different nonces — the one with
	# lexicographically-smaller nonce should win.
	local input='[
		{"nonce":"zzz","created_at":"2026-04-20T10:00:00Z","runner":"bob"},
		{"nonce":"aaa","created_at":"2026-04-20T10:00:00Z","runner":"alice"}
	]'
	local result
	result=$(printf '%s' "$input" | jq -c 'sort_by([.created_at, .nonce]) | .[0].nonce')
	assert_eq '"aaa"' "$result" "same ts → lex-smaller nonce wins"

	# Different timestamps → earlier wins regardless of nonce
	input='[
		{"nonce":"aaa","created_at":"2026-04-20T10:00:01Z","runner":"alice"},
		{"nonce":"zzz","created_at":"2026-04-20T10:00:00Z","runner":"bob"}
	]'
	result=$(printf '%s' "$input" | jq -c 'sort_by([.created_at, .nonce]) | .[0].nonce')
	assert_eq '"zzz"' "$result" "earlier ts wins despite larger nonce"

	# Tiebreaker determinism: same input across two runners → same winner
	local result2
	result2=$(printf '%s' "$input" | jq -c 'sort_by([.created_at, .nonce]) | .[0].nonce')
	assert_eq "$result" "$result2" "sort is deterministic across observers"

	return 0
}

# Test 15: CLAIM_DEFERRED comment body format
test_claim_deferred_body_format() {
	printf '\nTest 15: CLAIM_DEFERRED body format is parseable and includes required fields\n'

	# Build the body string exactly as _post_deferred would
	local our_runner="marcusquinn"
	local our_nonce="nonce-ours-123"
	local winner_runner="alex-solovyev"
	local winner_nonce="nonce-theirs-456"
	local delta_s="2"
	local ts="2026-04-20T10:00:02Z"

	local body
	body="CLAIM_DEFERRED runner=${our_runner} nonce=${our_nonce} ts=${ts} deferring_to_runner=${winner_runner} deferring_to_nonce=${winner_nonce} delta_s=${delta_s}"

	# Verify all required fields are present and parseable
	[[ "$body" == *"CLAIM_DEFERRED"* ]] && {
		printf '  PASS: body contains CLAIM_DEFERRED marker\n'
		PASS=$((PASS + 1))
	} || {
		printf '  FAIL: body missing CLAIM_DEFERRED marker\n'
		FAIL=$((FAIL + 1))
	}

	# Regex-extract each field
	local extracted_runner extracted_deferring_to extracted_delta
	extracted_runner=$(printf '%s' "$body" | sed -E 's/.*runner=([^ ]+) nonce=.*/\1/')
	assert_eq "marcusquinn" "$extracted_runner" "runner field parseable"

	extracted_deferring_to=$(printf '%s' "$body" | sed -E 's/.*deferring_to_runner=([^ ]+) .*/\1/')
	assert_eq "alex-solovyev" "$extracted_deferring_to" "deferring_to_runner field parseable"

	extracted_delta=$(printf '%s' "$body" | sed -E 's/.*delta_s=([0-9]+).*/\1/')
	assert_eq "2" "$extracted_delta" "delta_s field parseable"

	return 0
}

# Test 16: close-race detection (delta <= TIEBREAKER_WINDOW)
test_close_race_detection() {
	printf '\nTest 16: close-race detection arithmetic matches claim-helper logic\n'

	# Simulate the jq calls that cmd_claim makes
	local claims='[
		{"nonce":"winner","runner":"alex-solovyev","created_at":"2026-04-20T10:00:00Z","created_epoch":1774468800},
		{"nonce":"loser","runner":"marcusquinn","created_at":"2026-04-20T10:00:02Z","created_epoch":1774468802}
	]'

	local winner_epoch loser_epoch delta_s
	winner_epoch=$(printf '%s' "$claims" | jq -r '.[0].created_epoch // 0')
	loser_epoch=$(printf '%s' "$claims" | jq -r --arg n "loser" '[.[] | select(.nonce == $n)] | .[0].created_epoch // 0')

	assert_eq "1774468800" "$winner_epoch" "winner_epoch parseable"
	assert_eq "1774468802" "$loser_epoch" "loser_epoch parseable"

	if ((loser_epoch >= winner_epoch)); then
		delta_s=$((loser_epoch - winner_epoch))
	else
		delta_s=$((winner_epoch - loser_epoch))
	fi
	assert_eq "2" "$delta_s" "delta_s computed"

	# Default window is 5s; 2s is within window
	local window=5
	local in_window="no"
	((delta_s <= window)) && in_window="yes"
	assert_eq "yes" "$in_window" "delta_s=2 within TIEBREAKER_WINDOW=5 → CLAIM_DEFERRED fires"

	# 10s delta is outside window → no CLAIM_DEFERRED
	delta_s=10
	in_window="no"
	((delta_s <= window)) && in_window="yes"
	assert_eq "no" "$in_window" "delta_s=10 outside TIEBREAKER_WINDOW=5 → no CLAIM_DEFERRED"
	return 0
}

# ==============================================================================
# Run suite
# ==============================================================================

# Reset env to avoid contamination from the real user's config that was sourced
# by dispatch-override-resolve.sh on load.
unset DISPATCH_CLAIM_IGNORE_RUNNERS DISPATCH_CLAIM_MIN_VERSION DISPATCH_OVERRIDE_DEFAULT
_var=""
for _var in $(compgen -v | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
	case "$_var" in
	DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED) ;;
	DISPATCH_OVERRIDE_*) unset "$_var" ;;
	esac
done
unset _var
# Point the resolver at a non-existent conf so it doesn't reload the user's config
DISPATCH_OVERRIDE_CONF=/dev/null
export DISPATCH_OVERRIDE_CONF

test_slug_normalisation
test_action_honour
test_action_ignore
test_action_warn
test_honour_only_above
test_ignore_below_synonym
test_master_switch
test_ill_formed_action
test_legacy_detection
test_structured_filter_ignore
test_structured_filter_warn
test_structured_filter_noop
test_combined_filters
test_nonce_tiebreaker
test_claim_deferred_body_format
test_close_race_detection

printf '\n========================\n'
printf 'Passed: %d, Failed: %d\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
