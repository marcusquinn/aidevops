#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
AGENTS_DIR="${SCRIPT_DIR}/../.."
DOMAIN_GUIDE="${AGENTS_DIR}/services/hosting/cloudron.md"
SKILL_GUIDE="${AGENTS_DIR}/tools/deployment/cloudron-server-ops-skill.md"
SITE_OPERATIONS="${AGENTS_DIR}/reference/site-operations.md"

tests_run=0
tests_failed=0

assert_contains() {
	local case_name="$1"
	local file="$2"
	local expected="$3"

	tests_run=$((tests_run + 1))
	if grep -Fq -- "$expected" "$file"; then
		printf 'PASS: %s\n' "$case_name"
		return 0
	fi

	printf 'FAIL: %s (%s lacks %s)\n' "$case_name" "$file" "$expected" >&2
	tests_failed=$((tests_failed + 1))
}

assert_contains "domain guide checks SSH before login" "$DOMAIN_GUIDE" "Before requesting"
assert_contains "domain guide requires authorised SSH" "$DOMAIN_GUIDE" "check authorised root SSH."
assert_contains "skill guide checks SSH before login" "$SKILL_GUIDE" "first preserve any valid scoped token and check authorised root SSH."
assert_contains "site operations points to Cloudron recovery" "$SITE_OPERATIONS" "For Cloudron, an expired local CLI token requires a capability-first check:"
assert_contains "domain guide preserves active support login" "$DOMAIN_GUIDE" "do not replace an active support/ghost login"
assert_contains "skill guide rejects unsafe recovery" "$SKILL_GUIDE" "Never reset owner passwords, write raw tokens to storage, bypass authentication, or disable host-key checking."

printf 'Tests run: %d, failed: %d\n' "$tests_run" "$tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
