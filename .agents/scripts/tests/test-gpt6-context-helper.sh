#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/../shared-constants.sh"
HELPER="${SCRIPT_DIR}/../gpt6-context-helper.sh"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export AIDEVOPS_TEMP_DIR="$TEST_HOME/tmp"
export AIDEVOPS_SETTINGS_FILE="$HOME/.config/aidevops/settings.json"
export AIDEVOPS_PLUGIN_ENTRY="$TEST_HOME/plugin.mjs"
export TEST_CONFIG_HOOK="${SCRIPT_DIR}/../../plugins/opencode-aidevops/config-hook.mjs"
export OPENCODE_BIN="$TEST_HOME/opencode"
touch "$AIDEVOPS_PLUGIN_ENTRY"
cat >"$OPENCODE_BIN" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == debug ]]; then
  printf '{"plugin":["file://%s"]}\n' "$AIDEVOPS_PLUGIN_ENTRY"
  exit 0
fi
[[ "$1 $2 $3" == 'models openai --verbose' ]]
[[ "${PROBE_MODE:-}" != failed ]] || exit 1
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
const { registerGpt6ContextLimits, getGpt6ContextHealth } = await import(process.env.TEST_CONFIG_HOOK);
const config = {
  compaction: {reserved: 35000, auto: process.env.PROBE_MODE !== 'auto-off'},
  provider: {openai: {models: {
    'gpt-6-sol-fast': {options: {serviceTier: 'priority'}},
    'gpt-6-luna-fast': {options: {serviceTier: 'priority'}, limit: {output: 64000}},
  }}},
};
registerGpt6ContextLimits(config);
const receipt = {schema: 'aidevops.opencode-plugin-health/v1',
  nonce: process.env.AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE,
  stages: ['imported', 'factory_initialized', 'config_applied'],
  details: {config_applied: {gpt6_context: getGpt6ContextHealth(config)}}};
if (process.env.PROBE_MODE === 'old') delete receipt.details.config_applied.gpt6_context;
if (process.env.PROBE_MODE === 'stale') receipt.nonce = 'wrong-nonce';
if (process.env.PROBE_MODE === 'mismatch') receipt.details.config_applied.gpt6_context.target = 1;
writeFileSync(process.env.AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE, JSON.stringify(receipt));
JS
MOCK
chmod +x "$OPENCODE_BIN"

assert_contains() {
	local output="$1" expected="$2"
	if [[ "$output" != *"$expected"* ]]; then
		printf 'Expected: %s\nActual: %s\n' "$expected" "$output" >&2
		return 1
	fi
	return 0
}

output=$(bash "$HELPER" status)
assert_contains "$output" 'requested: disabled'
assert_contains "$output" 'native provider metadata confirmed'
output=$(bash "$HELPER" enable)
assert_contains "$output" 'requested: enabled'
assert_contains "$output" 'gpt-6-sol limits (new process): context=403000, input=275000, output=128000, reserve=35000'
assert_contains "$output" 'gpt-6-luna-fast limits (new process): context=339000, input=275000, output=64000, reserve=35000'
assert_contains "$output" 'target: 240000 (applied)'
jq -e '.runtime.opencode.gpt6_context_cap == true' "$AIDEVOPS_SETTINGS_FILE" >/dev/null

# Normal settings initialization never replaces the saved opt-in.
bash "${SCRIPT_DIR}/../settings-helper.sh" init >/dev/null
[[ "$(bash "${SCRIPT_DIR}/../settings-helper.sh" get runtime.opencode.gpt6_context_cap)" == true ]]
output=$(bash "$HELPER" disable)
assert_contains "$output" 'requested: disabled'
assert_contains "$output" 'native provider metadata confirmed'
jq -e '.runtime.opencode.gpt6_context_cap == false' "$AIDEVOPS_SETTINGS_FILE" >/dev/null

output=$(bash "$HELPER" enable)
assert_contains "$output" 'target: 240000 (applied)'
for mode in old stale mismatch failed; do
	output=$(PROBE_MODE="$mode" bash "$HELPER" status)
	assert_contains "$output" 'Effective GPT-6 context state: unavailable'
done
output=$(PROBE_MODE=auto-off bash "$HELPER" status)
assert_contains "$output" 'Automatic compaction is disabled'
output=$(OPENCODE_BIN="$TEST_HOME/missing" bash "$HELPER" status)
assert_contains "$output" 'OpenCode is not installed'

printf '%s\n' '{"other":{"keep":42},"runtime":{"opencode":{"astra_context_cap":false}}}' >"$AIDEVOPS_SETTINGS_FILE"
bash "$HELPER" enable >/dev/null
jq -e '.other.keep == 42 and .runtime.opencode.astra_context_cap == false and .runtime.opencode.gpt6_context_cap == true' "$AIDEVOPS_SETTINGS_FILE" >/dev/null
for invalid in '' '{} {}' 'broken-json' '[]' '{"runtime":"invalid"}'; do
	printf '%s\n' "$invalid" >"$AIDEVOPS_SETTINGS_FILE"
	if bash "$HELPER" enable >/dev/null 2>&1; then
		printf '%s\n' 'Invalid settings unexpectedly overwritten' >&2
		exit 1
	fi
	[[ "$(<"$AIDEVOPS_SETTINGS_FILE")" == "$invalid" ]]
	output=$(bash "$HELPER" status)
	assert_contains "$output" 'requested: disabled'
done
if bash "$HELPER" unknown >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'PASS: GPT-6 Sol/Luna CLI settings, persistence, native opt-out and health evidence'
