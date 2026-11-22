#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
HELPER="${HELPER_DIR}/vault-data-policy-helper.sh"
PASS=0
FAIL=0
# Hermetic: the developer's own operator override must not change results.
OVERRIDE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/vault-policy-override.XXXXXX")
trap 'rm -rf "$OVERRIDE_HOME"' EXIT
export XDG_CONFIG_HOME="${OVERRIDE_HOME}/empty-config"

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

# GH#35723: operator-owned local-provider override.
OVERRIDE_FILE="${OVERRIDE_HOME}/.config/aidevops/local-ai-providers.conf"
mkdir -p "${OVERRIDE_FILE%/*}"

bound_check() {
	local model="$1"
	local rc=0
	env -u XDG_CONFIG_HOME HOME="$OVERRIDE_HOME" AIDEVOPS_RUNTIME_POLICY=local-only \
		"$HELPER" check --model "$model" --title "Policy test" --prompt "plain prompt" || rc=$?
	[[ "$rc" -eq 0 ]] && return 0
	return "$rc"
}

write_override() {
	local content="$1"
	local mode="$2"
	rm -f "$OVERRIDE_FILE"
	printf '%s\n' "$content" >"$OVERRIDE_FILE"
	chmod "$mode" "$OVERRIDE_FILE"
	return 0
}

assert_rc "absent override keeps the shared list" 0 bound_check ollama/llama3.1
assert_rc "absent override does not add custom providers" 64 bound_check custom-local/m

write_override "custom-local" 600
assert_rc "0600 override allows its provider" 0 bound_check custom-local/m
assert_rc "0600 override replaces the shared list" 64 bound_check ollama/llama3.1

write_override "custom-local" 644
assert_rc "0644 override denies its provider" 64 bound_check custom-local/m
assert_rc "0644 override does not fall back to the shared list" 64 bound_check ollama/llama3.1

write_override "custom-local
openai/gpt" 600
assert_rc "invalid provider ID denies every provider" 64 bound_check custom-local/m

rm -f "$OVERRIDE_FILE"
printf 'custom-local\n' >"${OVERRIDE_HOME}/real.conf"
chmod 600 "${OVERRIDE_HOME}/real.conf"
ln -s "${OVERRIDE_HOME}/real.conf" "$OVERRIDE_FILE"
assert_rc "symlinked override denies every provider" 64 bound_check custom-local/m
assert_rc "symlinked override does not fall back to the shared list" 64 bound_check ollama/llama3.1

rm -f "$OVERRIDE_FILE"
mkdir -p "${OVERRIDE_HOME}/xdg/aidevops"
printf 'xdg-local\n' >"${OVERRIDE_HOME}/xdg/aidevops/local-ai-providers.conf"
chmod 600 "${OVERRIDE_HOME}/xdg/aidevops/local-ai-providers.conf"
assert_rc "XDG_CONFIG_HOME override is used" 0 \
	env HOME="$OVERRIDE_HOME" XDG_CONFIG_HOME="${OVERRIDE_HOME}/xdg" AIDEVOPS_RUNTIME_POLICY=local-only \
	"$HELPER" check --model xdg-local/m --title "Policy test" --prompt "plain prompt"

printf '\nVault data policy routing test summary: %s passed, %s failed\n' "$PASS" "$FAIL"
rm -f /tmp/aidevops-vault-policy-test.out /tmp/aidevops-vault-policy-test.err
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
