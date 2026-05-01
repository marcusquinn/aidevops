#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${AGENTS_SCRIPTS}/headless-runtime-model.sh"

failures=0

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
		failures=$((failures + 1))
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

with_clean_variant_env() {
	unset AIDEVOPS_HEADLESS_VARIANT || true
	unset AIDEVOPS_HEADLESS_VARIANT_SONNET || true
	unset AIDEVOPS_HEADLESS_VARIANT_OPUS || true
	unset AIDEVOPS_HEADLESS_WORKER_VARIANT || true
	unset AIDEVOPS_HEADLESS_PULSE_VARIANT || true
	return 0
}

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_SONNET="high"
actual=$(resolve_headless_variant "worker" "sonnet" "openai/gpt-5.5")
assert_equals "" "$actual" "GPT-5.5 sonnet worker omits env-derived high variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_SONNET="high"
actual=$(resolve_headless_variant "worker" "sonnet" "openai/gpt-5.4")
assert_equals "high" "$actual" "non-GPT-5.5 sonnet worker keeps high variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_OPUS="xhigh"
actual=$(resolve_headless_variant "worker" "opus" "openai/gpt-5.5")
assert_equals "xhigh" "$actual" "GPT-5.5 opus worker keeps thinking-tier variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_SONNET="high"
actual=$(resolve_headless_variant "pulse" "sonnet" "openai/gpt-5.5")
assert_equals "high" "$actual" "pulse sonnet routing keeps configured variant" || true

with_clean_variant_env

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d variant regression test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll headless runtime variant tests passed\n'
exit 0
