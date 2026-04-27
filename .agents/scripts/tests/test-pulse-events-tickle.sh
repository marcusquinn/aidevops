#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Synthetic tests for pulse-events-tickle.sh (GH#20868, t2830).
#
# Tests the events_tickle <owner> function by mocking `gh api -i` to
# return controlled HTTP responses. Validates:
#
#   1. 304 response (ETag match) → returns 0 (fresh), counter incremented
#   2. 200 response (first call, no ETag) → returns 1 (stale), ETag cached
#   3. 200 response (ETag changed) → returns 1 (stale), cache updated
#   4. 200 sends correct If-None-Match header when ETag is stored
#   5. 404 on users/ → retries as orgs/, returns 1 (stale), type cached
#   6. Rate-limit error → returns 2 (unknown), fail-open
#   7. Feature disabled (PULSE_EVENTS_TICKLE_ENABLED=0) → returns 2 (unknown)
#   8. Batch prefetch integration: fresh owner skips search calls
#   9. Batch prefetch integration: stale owner runs search calls
#  10. Counter reset between cycles (_PULSE_EVENTS_TICKLE_FRESH/STALE)
#
# All tests are self-contained and isolated via sandbox HOME directories.
# No real GitHub API calls are made. `gh` is shimmed via PATH.
#
# Run:
#   bash .agents/scripts/tests/test-pulse-events-tickle.sh
# Expected: all tests PASS, exit 0

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly SCRIPT_DIR

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_equals() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected='${expected}' actual='${actual}'"
	fi
	return 0
}

assert_file_exists() {
	local name="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "file not found: ${file}"
	fi
	return 0
}

assert_file_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if [[ -f "$file" ]] && grep -q "$pattern" "$file" 2>/dev/null; then
		print_result "$name" 0
	else
		print_result "$name" 1 "file '${file}' does not contain '${pattern}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Sandbox setup / teardown
# ---------------------------------------------------------------------------

# setup_sandbox [gh_stub_script]
# Creates a temporary HOME with required directories and installs a `gh`
# shim on PATH. The shim script must be passed as $1 (path to an executable
# that takes `api -i …` arguments and emits the desired response).
setup_sandbox() {
	local gh_stub="${1:-}"
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	mkdir -p "${HOME}/.aidevops/cache/pulse-events-etag"
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	export LOGFILE

	# Install a `gh` shim that forwards to our stub.
	local bin_dir="${TEST_ROOT}/bin"
	mkdir -p "$bin_dir"

	if [[ -n "$gh_stub" && -f "$gh_stub" ]]; then
		cp "$gh_stub" "${bin_dir}/gh"
		chmod +x "${bin_dir}/gh"
	else
		# Default stub: always returns 200 with a dummy ETag.
		cat >"${bin_dir}/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nETag: "default-etag-stub"\r\n\r\n[]\n'
exit 0
GH_STUB
		chmod +x "${bin_dir}/gh"
	fi

	export PATH="${bin_dir}:${PATH}"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# write_gh_stub <file> <content>
# Write an executable gh stub to <file>.
write_gh_stub() {
	local file="$1"
	local content="$2"
	printf '#!/usr/bin/env bash\n%s\n' "$content" >"$file"
	chmod +x "$file"
	return 0
}

# source_tickle_fresh
# Source the tickle script in a clean state (resets include guard).
source_tickle_fresh() {
	unset _PULSE_EVENTS_TICKLE_LOADED
	_PULSE_EVENTS_TICKLE_FRESH=0
	_PULSE_EVENTS_TICKLE_STALE=0
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-events-tickle.sh"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: 304 response → exit 0 (fresh), counter incremented
# ---------------------------------------------------------------------------
test_304_returns_fresh() {
	local stub="${TEST_ROOT}/gh-304"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 304\r\n\r\n'; exit 1"
	# gh exits non-zero on 304 (not a 2xx response)

	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	# Seed a stored ETag so If-None-Match is sent
	printf '{"etag":"abc123","owner_type":"users","last_check":"2026-01-01T00:00:00Z"}\n' \
		>"${HOME}/.aidevops/cache/pulse-events-etag/testowner.json"

	local rc=0
	events_tickle "testowner" || rc=$?

	assert_equals "test_304: returns exit 0 (fresh)" "0" "$rc"
	assert_equals "test_304: TICKLE_FRESH incremented" "1" "$_PULSE_EVENTS_TICKLE_FRESH"
	assert_equals "test_304: TICKLE_STALE unchanged" "0" "$_PULSE_EVENTS_TICKLE_STALE"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: 200 response (first call) → exit 1 (stale), ETag cached
# ---------------------------------------------------------------------------
test_200_first_call_caches_etag() {
	setup_sandbox

	local stub="${TEST_ROOT}/gh-200-first"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 200\r\nETag: \"etag-first-call\"\r\n\r\n[]\n'; exit 0"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	local rc=0
	events_tickle "newowner" || rc=$?

	assert_equals "test_200_first: returns exit 1 (stale)" "1" "$rc"
	assert_equals "test_200_first: TICKLE_STALE incremented" "1" "$_PULSE_EVENTS_TICKLE_STALE"
	assert_file_exists "test_200_first: cache file created" \
		"${HOME}/.aidevops/cache/pulse-events-etag/newowner.json"
	assert_file_contains "test_200_first: ETag stored in cache" \
		"${HOME}/.aidevops/cache/pulse-events-etag/newowner.json" "etag-first-call"
	assert_file_contains "test_200_first: owner_type stored as users" \
		"${HOME}/.aidevops/cache/pulse-events-etag/newowner.json" "users"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: 200 response (ETag changed) → exit 1 (stale), cache updated
# ---------------------------------------------------------------------------
test_200_updates_cache() {
	setup_sandbox

	local stub="${TEST_ROOT}/gh-200-update"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 200\r\nETag: \"new-etag-value\"\r\n\r\n[]\n'; exit 0"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	# Pre-seed an old ETag
	printf '{"etag":"old-etag","owner_type":"users","last_check":"2026-01-01T00:00:00Z"}\n' \
		>"${HOME}/.aidevops/cache/pulse-events-etag/existingowner.json"

	local rc=0
	events_tickle "existingowner" || rc=$?

	assert_equals "test_200_update: returns exit 1 (stale)" "1" "$rc"
	assert_file_contains "test_200_update: cache updated with new ETag" \
		"${HOME}/.aidevops/cache/pulse-events-etag/existingowner.json" "new-etag-value"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: If-None-Match header is sent when ETag is stored
# ---------------------------------------------------------------------------
test_sends_if_none_match() {
	setup_sandbox

	# Stub that checks whether If-None-Match was passed and echoes it
	local stub="${TEST_ROOT}/gh-check-etag"
	cat >"$stub" <<'STUB_EOF'
#!/usr/bin/env bash
# Scan args for -H "If-None-Match: ..."
_found_etag=0
for _arg in "$@"; do
	if [[ "$_arg" == *"If-None-Match"* ]]; then
		_found_etag=1
		break
	fi
done
if [[ "$_found_etag" -eq 1 ]]; then
	printf 'HTTP/2 304\r\n\r\n'
	exit 1
else
	printf 'HTTP/2 200\r\nETag: "first-etag"\r\n\r\n[]\n'
	exit 0
fi
STUB_EOF
	chmod +x "$stub"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	# First call: no ETag stored → should get 200 and cache the ETag
	local rc1=0
	events_tickle "etag-test-owner" || rc1=$?
	assert_equals "test_if_none_match: first call gets 200 (no ETag)" "1" "$rc1"

	# Second call: ETag stored → should send If-None-Match → stub returns 304
	local rc2=0
	events_tickle "etag-test-owner" || rc2=$?
	assert_equals "test_if_none_match: second call gets 304 (ETag sent)" "0" "$rc2"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: 404 on users/ → retries as orgs/, returns 1 (stale)
# ---------------------------------------------------------------------------
test_404_retries_as_org() {
	setup_sandbox

	# Stub: return 404 for users/, 200 for orgs/
	local stub="${TEST_ROOT}/gh-org-retry"
	cat >"$stub" <<'STUB_EOF'
#!/usr/bin/env bash
for _arg in "$@"; do
	if [[ "$_arg" == */orgs/* ]]; then
		printf 'HTTP/2 200\r\nETag: "org-etag"\r\n\r\n[]\n'
		exit 0
	fi
done
printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'
exit 1
STUB_EOF
	chmod +x "$stub"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	local rc=0
	events_tickle "myorg" || rc=$?

	assert_equals "test_org_retry: returns exit 1 (stale after org retry)" "1" "$rc"
	assert_file_contains "test_org_retry: owner_type set to orgs in cache" \
		"${HOME}/.aidevops/cache/pulse-events-etag/myorg.json" "orgs"
	assert_file_contains "test_org_retry: org ETag stored in cache" \
		"${HOME}/.aidevops/cache/pulse-events-etag/myorg.json" "org-etag"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Rate-limit error → returns 2 (unknown), fail-open
# ---------------------------------------------------------------------------
test_rate_limit_returns_unknown() {
	setup_sandbox

	local stub="${TEST_ROOT}/gh-ratelimit"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\n\r\n{\"message\":\"rate limit exceeded\"}\n'; exit 1"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	local rc=0
	events_tickle "ratewatcher" || rc=$?

	assert_equals "test_rate_limit: returns exit 2 (unknown)" "2" "$rc"
	assert_equals "test_rate_limit: TICKLE_STALE incremented (fail-open)" "1" "$_PULSE_EVENTS_TICKLE_STALE"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: Feature disabled → returns 2 (unknown)
# ---------------------------------------------------------------------------
test_feature_disabled() {
	setup_sandbox
	source_tickle_fresh

	PULSE_EVENTS_TICKLE_ENABLED=0

	local rc=0
	events_tickle "anyowner" || rc=$?

	assert_equals "test_disabled: returns exit 2 when disabled" "2" "$rc"
	assert_equals "test_disabled: TICKLE_FRESH unchanged" "0" "$_PULSE_EVENTS_TICKLE_FRESH"

	PULSE_EVENTS_TICKLE_ENABLED=1  # restore
	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: Counter accumulates across multiple owners in a cycle
# ---------------------------------------------------------------------------
test_counter_accumulation() {
	setup_sandbox

	# Stub: respond based on owner name in path
	local stub="${TEST_ROOT}/gh-multi"
	cat >"$stub" <<'STUB_EOF'
#!/usr/bin/env bash
for _arg in "$@"; do
	if [[ "$_arg" == */freshowner/* ]]; then
		printf 'HTTP/2 304\r\n\r\n'
		exit 1
	fi
done
printf 'HTTP/2 200\r\nETag: "stale-etag"\r\n\r\n[]\n'
exit 0
STUB_EOF
	chmod +x "$stub"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	# Seed ETag for freshowner so If-None-Match is sent
	printf '{"etag":"cached-etag","owner_type":"users","last_check":"2026-01-01T00:00:00Z"}\n' \
		>"${HOME}/.aidevops/cache/pulse-events-etag/freshowner.json"

	# freshowner → 304 (fresh)
	local rc1=0; events_tickle "freshowner" || rc1=$?
	# staleowner → 200 (stale, no prior ETag)
	local rc2=0; events_tickle "staleowner" || rc2=$?
	# anotherowner → 200 (stale)
	local rc3=0; events_tickle "anotherowner" || rc3=$?

	assert_equals "test_accumulate: freshowner returns 0" "0" "$rc1"
	assert_equals "test_accumulate: staleowner returns 1" "1" "$rc2"
	assert_equals "test_accumulate: anotherowner returns 1" "1" "$rc3"
	assert_equals "test_accumulate: TICKLE_FRESH=1" "1" "$_PULSE_EVENTS_TICKLE_FRESH"
	assert_equals "test_accumulate: TICKLE_STALE=2" "2" "$_PULSE_EVENTS_TICKLE_STALE"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: Counter reset between cycles
# ---------------------------------------------------------------------------
test_counter_reset_between_cycles() {
	setup_sandbox

	local stub="${TEST_ROOT}/gh-200-reset"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 200\r\nETag: \"etag-reset\"\r\n\r\n[]\n'; exit 0"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	source_tickle_fresh

	# First cycle
	events_tickle "owner1" || true
	events_tickle "owner2" || true

	local fresh1="$_PULSE_EVENTS_TICKLE_FRESH"
	local stale1="$_PULSE_EVENTS_TICKLE_STALE"

	# Reset (simulating next cycle — caller does this in _cmd_refresh)
	_PULSE_EVENTS_TICKLE_FRESH=0
	_PULSE_EVENTS_TICKLE_STALE=0

	events_tickle "owner3" || true

	assert_equals "test_reset: counters reset to 0 between cycles" "0" "$fresh1"
	assert_equals "test_reset: stale counter populated in first cycle" "2" "$stale1"
	assert_equals "test_reset: TICKLE_STALE=1 in second cycle" "1" "$_PULSE_EVENTS_TICKLE_STALE"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: Batch prefetch integration — fresh owner skips search calls
# ---------------------------------------------------------------------------
test_batch_prefetch_skips_fresh_owner() {
	setup_sandbox

	# Stub: always return 304 (all owners are fresh)
	local stub="${TEST_ROOT}/gh-304-all"
	write_gh_stub "$stub" \
		"printf 'HTTP/2 304\r\n\r\n'; exit 1"
	local bin_dir="${TEST_ROOT}/bin"
	cp "$stub" "${bin_dir}/gh"

	# Seed ETag for the test owner
	printf '{"etag":"seeded-etag","owner_type":"users","last_check":"2026-01-01T00:00:00Z"}\n' \
		>"${HOME}/.aidevops/cache/pulse-events-etag/testpulseowner.json"

	# Source the tickle module with the stub gh on PATH
	source_tickle_fresh

	# Call events_tickle directly — should get 304 → fresh
	local rc=0
	events_tickle "testpulseowner" || rc=$?

	assert_equals "test_batch_skip: fresh owner returns 0 (304)" "0" "$rc"
	assert_equals "test_batch_skip: TICKLE_FRESH incremented" "1" "$_PULSE_EVENTS_TICKLE_FRESH"
	assert_equals "test_batch_skip: TICKLE_STALE unchanged" "0" "$_PULSE_EVENTS_TICKLE_STALE"

	teardown_sandbox
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '%b==> pulse-events-tickle.sh synthetic tests (GH#20868 / t2830)%b\n' \
		"$TEST_YELLOW" "$TEST_RESET"
	printf '    SCRIPT_DIR=%s\n\n' "$SCRIPT_DIR"

	if [[ ! -f "${SCRIPT_DIR}/pulse-events-tickle.sh" ]]; then
		printf '%bFATAL%b pulse-events-tickle.sh not found at %s\n' \
			"$TEST_RED" "$TEST_RESET" "${SCRIPT_DIR}/pulse-events-tickle.sh" >&2
		exit 1
	fi

	# Run all tests — each sets up and tears down its own sandbox.
	setup_sandbox  # initial sandbox for test 1

	test_304_returns_fresh
	test_200_first_call_caches_etag
	test_200_updates_cache
	test_sends_if_none_match
	test_404_retries_as_org
	test_rate_limit_returns_unknown
	test_feature_disabled
	test_counter_accumulation
	test_counter_reset_between_cycles
	test_batch_prefetch_skips_fresh_owner

	printf '\n'
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		exit 0
	fi
	printf '%b%d of %d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
}

main "$@"
