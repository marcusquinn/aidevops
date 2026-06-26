#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
HELPER="${HELPER_DIR}/vault-data-policy-helper.sh"
PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	printf 'FAIL: %s\n' "$name" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_rc() {
	local name="$1"
	local expected="$2"
	shift 2
	local rc=0
	set +e
	"$@" >/tmp/aidevops-vault-policy-test.out 2>/tmp/aidevops-vault-policy-test.err
	rc=$?
	set -e
	if [[ "$rc" -eq "$expected" ]]; then
		pass "$name"
	else
		printf '  expected rc: %s\n  actual rc:   %s\n' "$expected" "$rc" >&2
		fail "$name"
	fi
	return 0
}

provider_prompt='Task metadata
data_classification: client-confidential
runtime_policy: provider-ai'
local_prompt='Task metadata
data_classification: local-LLM-only
runtime_policy: local-ai'
approved_prompt='Task metadata
data_classification: client-confidential provider-allowed
runtime_policy: provider-ai-approved'
secret_prompt='Task metadata
data_classification: secret provider-allowed
runtime_policy: provider-ai-approved'

assert_rc "provider model blocked for client-confidential without approval" 64 \
	"$HELPER" check --model openai/gpt-5.5 --title "Policy test" --prompt "$provider_prompt"
assert_rc "local model allowed for local-LLM-only task" 0 \
	"$HELPER" check --model ollama/llama3.1 --title "Policy test" --prompt "$local_prompt"
assert_rc "provider model allowed with provider-allowed metadata" 0 \
	"$HELPER" check --model openai/gpt-5.5 --title "Policy test" --prompt "$approved_prompt"
assert_rc "secret classification denied even with provider approval" 64 \
	"$HELPER" check --model ollama/llama3.1 --title "Policy test" --prompt "$secret_prompt"

printf '\nVault data policy routing test summary: %s passed, %s failed\n' "$PASS" "$FAIL"
rm -f /tmp/aidevops-vault-policy-test.out /tmp/aidevops-vault-policy-test.err
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
