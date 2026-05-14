#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23594:
#   1. ai-research-helper.sh::resolve_api_key() must fall back to the OAuth
#      pool when env/gopass/credentials.sh all miss.
#   2. pulse-fix-the-fixer-detector.sh must classify helper rc=2 as an
#      auth-class failure and record the cooldown — regardless of whether
#      the prose stderr message matches the API-response substring patterns
#      in _is_auth_error().

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${TEST_ROOT}/bin"
	# Ensure we don't accidentally inherit a real key or pollute gopass.
	unset ANTHROPIC_API_KEY || true
	# Mask gopass so the env-var-empty test cannot hit a real credential store.
	cat >"${TEST_ROOT}/bin/gopass" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gopass"
	# Prepend our stub PATH; keep real bash/jq/sed/etc by appending the prior PATH.
	export PATH="${TEST_ROOT}/bin:${PATH}"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_pool_with_active_anthropic() {
	local token="$1"
	local expires_ms="$2"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	cat >"$pool_file" <<EOF
{
  "anthropic": [
    {
      "email": "test@example.com",
      "access": "${token}",
      "refresh": "rt_test",
      "expires": ${expires_ms},
      "added": "2026-05-14T00:00:00Z",
      "lastUsed": "2026-05-14T00:00:00Z",
      "status": "active",
      "cooldownUntil": null
    }
  ]
}
EOF
	chmod 600 "$pool_file"
	return 0
}

write_pool_with_expired_anthropic() {
	local token="$1"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	cat >"$pool_file" <<EOF
{
  "anthropic": [
    {
      "email": "test@example.com",
      "access": "${token}",
      "refresh": "rt_test",
      "expires": 1,
      "added": "2026-05-14T00:00:00Z",
      "lastUsed": "2026-05-14T00:00:00Z",
      "status": "active",
      "cooldownUntil": null
    }
  ]
}
EOF
	chmod 600 "$pool_file"
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: resolve_oauth_pool_token returns active token; resolve_api_key
#         delegates to it when env/gopass/credentials.sh all miss.
# -----------------------------------------------------------------------------
test_oauth_pool_fallback() {
	local expected_token="sk-ant-oat01-from-pool-DEADBEEF"
	# 1h from now in milliseconds.
	local one_hour_ms=$(( ( $(date +%s) + 3600 ) * 1000 ))
	write_pool_with_active_anthropic "$expected_token" "$one_hour_ms"

	# Source the helper to access resolve_api_key directly.
	# shellcheck source=/dev/null
	(
		set +e
		source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh" 2>/dev/null
		actual=$(resolve_api_key 2>/dev/null)
		rc=$?
		printf 'rc=%s\ntoken=%s\n' "$rc" "$actual"
	) >"${TEST_ROOT}/probe.out" 2>/dev/null || true

	local rc token
	rc=$(grep '^rc=' "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2 || true)
	token=$(grep '^token=' "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2- || true)

	if [[ "$rc" == "0" && "$token" == "$expected_token" ]]; then
		print_result "OAuth pool token is returned when static sources miss" 0
	else
		print_result "OAuth pool token is returned when static sources miss" 1 \
			"rc=${rc} token=${token} expected=${expected_token}"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 2: expired OAuth pool entries are skipped (no token returned).
# -----------------------------------------------------------------------------
test_oauth_pool_expired_skipped() {
	write_pool_with_expired_anthropic "sk-ant-oat01-expired-XXX"

	(
		set +e
		source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh" 2>/dev/null
		actual=$(resolve_api_key 2>/dev/null)
		rc=$?
		printf 'rc=%s\ntoken=%s\n' "$rc" "$actual"
	) >"${TEST_ROOT}/probe.out" 2>/dev/null || true

	local rc token
	rc=$(grep '^rc=' "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2 || true)
	token=$(grep '^token=' "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2- || true)

	if [[ "$rc" == "1" && -z "$token" ]]; then
		print_result "expired OAuth pool entries are skipped" 0
	else
		print_result "expired OAuth pool entries are skipped" 1 \
			"rc=${rc} token=${token} — expected rc=1 empty token"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 3: env var still wins over OAuth pool (precedence preserved).
# -----------------------------------------------------------------------------
test_env_var_precedence_preserved() {
	local one_hour_ms=$(( ( $(date +%s) + 3600 ) * 1000 ))
	write_pool_with_active_anthropic "sk-ant-oat01-from-pool" "$one_hour_ms"

	(
		set +e
		export ANTHROPIC_API_KEY="sk-ant-api03-static-WINS"
		source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh" 2>/dev/null
		actual=$(resolve_api_key 2>/dev/null)
		rc=$?
		printf 'rc=%s\ntoken=%s\n' "$rc" "$actual"
	) >"${TEST_ROOT}/probe.out" 2>/dev/null || true

	local token
	token=$(grep '^token=' "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2- || true)

	if [[ "$token" == "sk-ant-api03-static-WINS" ]]; then
		print_result "env var wins over OAuth pool" 0
	else
		print_result "env var wins over OAuth pool" 1 "got token=${token}"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 4: detector treats helper rc=2 as auth-error (records cooldown),
#         even when stderr message does not match _is_auth_error() patterns.
# -----------------------------------------------------------------------------
test_detector_rc2_records_cooldown() {
	# Stub gh to return one auto-dispatch issue.
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '[{"number":1,"labels":[{"name":"auto-dispatch"}]}]\n'
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	printf '{"title":"fix dispatch path","body":"Touches pulse-wrapper.sh dispatch behaviour.","labels":[{"name":"auto-dispatch"}],"state":"OPEN"}\n'
	exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gh"

	# Stub ai-research-helper.sh to return rc=2 with a prose message that
	# does NOT match _is_auth_error() patterns — proves we trip on exit
	# code, not substring matching.
	local helper_dir="${TEST_ROOT}/helper-shim"
	mkdir -p "$helper_dir"
	cat >"${helper_dir}/ai-research-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '[AI-RESEARCH] No Anthropic API key found (env, gopass, credentials.sh, or OAuth pool)\n' >&2
exit 2
STUB
	chmod +x "${helper_dir}/ai-research-helper.sh"

	# Run detector with helper override.
	(
		set +e
		export PULSE_AI_RESEARCH_HELPER_OVERRIDE="${helper_dir}/ai-research-helper.sh"
		export AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS=3600
		"${REPO_ROOT}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run \
			--repo example/repo --limit 1 \
			>"${TEST_ROOT}/detector.log" 2>&1
	)

	local cooldown_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown"
	if [[ -f "$cooldown_file" ]]; then
		print_result "rc=2 records auth cooldown state file" 0
	else
		print_result "rc=2 records auth cooldown state file" 1 \
			"cooldown file missing — detector.log: $(tr '\n' ' ' <"${TEST_ROOT}/detector.log" | head -c 400)"
	fi

	if grep -q 'skipped:auth-error=1' "${TEST_ROOT}/detector.log"; then
		print_result "rc=2 surfaces as skipped:auth-error in run summary" 0
	else
		print_result "rc=2 surfaces as skipped:auth-error in run summary" 1 \
			"detector.log tail: $(tail -c 400 "${TEST_ROOT}/detector.log" | tr '\n' ' ')"
	fi
	return 0
}

# -----------------------------------------------------------------------------
main() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

	setup_sandbox
	trap teardown_sandbox EXIT

	test_oauth_pool_fallback
	test_oauth_pool_expired_skipped
	test_env_var_precedence_preserved
	# Note: test 4 requires PULSE_AI_RESEARCH_HELPER_OVERRIDE support in the
	# detector. If the detector hard-codes the helper path, this test will
	# fail and the env override needs to be added (see PR description).
	test_detector_rc2_records_cooldown

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
