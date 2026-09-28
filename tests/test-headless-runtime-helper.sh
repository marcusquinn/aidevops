#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Selection and backoff smoke tests. Worker launch/canary integration lives in
# .agents/scripts/tests/test-headless-runtime-*-tests.sh; do not launch a live
# provider or write into the dispatcher's issue/worktree from this suite.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/headless-runtime-helper.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export AIDEVOPS_HEADLESS_RUNTIME_DIR="$TEST_DIR/runtime"
export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-5-5,openai/gpt-5.4"
export ANTHROPIC_API_KEY="[redacted-credential]"
export OPENAI_API_KEY="[redacted-credential]"
unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH AIDEVOPS_DISPATCH_LEASE_TOKEN

assert_model() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS %s\n' "$description"
	return 0
}

bash -n "$HELPER"
first_model=$(bash "$HELPER" select --role worker)
second_model=$(bash "$HELPER" select --role worker)
assert_model 'priority selection' 'anthropic/claude-sonnet-5-5' "$first_model"
assert_model 'priority stays on first healthy model' "$first_model" "$second_model"

allowlisted_model=$(AIDEVOPS_HEADLESS_MODELS=openai/gpt-5.4 AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" select --role worker)
assert_model 'openai-only selection' 'openai/gpt-5.4' "$allowlisted_model"

bash "$HELPER" backoff set anthropic rate_limit 3600
post_backoff_model=$(bash "$HELPER" select --role pulse)
assert_model 'backed-off anthropic skipped' 'openai/gpt-5.4' "$post_backoff_model"

if bash "$HELPER" backoff set anthropic rate_limit '10;rm -rf /'; then
	printf 'FAIL non-numeric backoff was accepted\n' >&2
	exit 1
fi

export AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="sig-old"
bash "$HELPER" backoff set openai auth_error 3600
export AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="sig-new"
recovered_model=$(AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" select --role pulse)
assert_model 'changed auth signature clears backoff' 'openai/gpt-5.4' "$recovered_model"

bash "$HELPER" backoff clear anthropic
bash "$HELPER" backoff clear openai
bash "$HELPER" backoff set anthropic/claude-sonnet-5-5 rate_limit 3600
opus_model=$(AIDEVOPS_HEADLESS_MODELS='anthropic/claude-sonnet-5-5,anthropic/claude-opus-4-6' bash "$HELPER" select --role worker)
assert_model 'model backoff preserves same-provider alternative' 'anthropic/claude-opus-4-6' "$opus_model"

printf 'PASS headless selection and backoff smoke tests\n'
