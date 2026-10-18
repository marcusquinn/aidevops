#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tests for _migrate_mcp_npx_to_binary() regression hardening (GH#14220)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_SCRIPT="$REPO_DIR/.agents/scripts/setup/modules/migrations.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$name"
	if [[ -n "$detail" ]]; then
		printf "     %s\n" "$detail"
	fi
	return 0
}

section() {
	echo ""
	echo "=== $1 ==="
	return 0
}

TEST_HOME=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TEST_HOME'" EXIT
export HOME="$TEST_HOME"

# Minimal stubs required for sourcing migrations.sh in isolation.
# shellcheck disable=SC2329
print_info() { return 0; }
# shellcheck disable=SC2329
print_success() { return 0; }
# shellcheck disable=SC2329
print_warning() { return 0; }
# shellcheck disable=SC2329
_launchd_has_agent() { return 1; }
# shellcheck disable=SC2329
find_opencode_config() { return 1; }
# shellcheck disable=SC2329
create_backup_with_rotation() { return 0; }
# shellcheck disable=SC2329
update_mcp_paths_in_opencode() { return 0; }
# shellcheck disable=SC2329
sanitize_plugin_namespace() {
	echo "$1"
	return 0
}
# shellcheck disable=SC2329
resolve_mcp_binary_path() {
	local bin_name="$1"
	if [[ "$bin_name" == "chrome-devtools-mcp" ]]; then
		echo "/usr/local/bin/chrome-devtools-mcp"
		return 0
	fi
	return 1
}

export -f print_info print_success print_warning _launchd_has_agent
export -f find_opencode_config create_backup_with_rotation update_mcp_paths_in_opencode
export -f sanitize_plugin_namespace resolve_mcp_binary_path

# shellcheck disable=SC1090
source "$MIGRATIONS_SCRIPT"

section "Test: minimal config without .mcp does not fail"

config_without_mcp="$TEST_HOME/opencode-empty.json"
printf '{}\n' >"$config_without_mcp"

output=$(_migrate_mcp_npx_to_binary "$config_without_mcp" 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	pass "Function succeeds when .mcp is missing"
else
	fail "Function should succeed when .mcp is missing" "exit code: $exit_code"
fi

if [[ "$output" == *"exit 5"* ]]; then
	fail "No jq exit-5 style failure when .mcp is missing" "$output"
else
	pass "No jq exit-5 style failure when .mcp is missing"
fi

if jq -e '. == {}' "$config_without_mcp" >/dev/null 2>&1; then
	pass "Config remains unchanged when .mcp is missing"
else
	fail "Config should remain unchanged when .mcp is missing"
fi

section "Test: npx MCP command migrates to resolved binary path"

config_with_mcp="$TEST_HOME/opencode-mcp.json"
printf '{"mcp":{"chrome":{"command":["npx","-y","chrome-devtools-mcp"]}}}\n' >"$config_with_mcp"

_migrate_mcp_npx_to_binary "$config_with_mcp"
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	pass "Function succeeds when MCP entries are present"
else
	fail "Function should succeed when MCP entries are present" "exit code: $exit_code"
fi

if [[ ${_cleanup_count:-0} -eq 1 ]]; then
	pass "Cleanup counter increments for migrated MCP entry"
else
	fail "Cleanup counter should increment for migrated MCP entry" "_cleanup_count=${_cleanup_count:-unset}"
fi

migrated_command=$(jq -r '.mcp.chrome.command[0]' "$config_with_mcp" 2>/dev/null || echo "")
if [[ "$migrated_command" == "/usr/local/bin/chrome-devtools-mcp" ]]; then
	pass "MCP command migrated to resolved binary path"
else
	fail "MCP command should migrate to resolved binary path" "got: $migrated_command"
fi

section "Test: Outscraper credentials resolve only at launch"

# Exercise the real registration, recurring setup migration, and generated
# launcher with synthetic credentials and local gopass/uv stand-ins only.
python3 - "$REPO_DIR" "$TEST_HOME" <<'PY'
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo, home = map(Path, sys.argv[1:])
sys.path.insert(0, str(repo / '.agents/scripts/lib'))
import mcp_config

fresh = {'mcp': {}, 'tools': {}}
with contextlib.redirect_stdout(io.StringIO()):
    mcp_config._register_outscraper(fresh)
launcher = fresh['mcp']['outscraper']['command']
assert "'mcp<2'" in launcher[2]
assert fresh['mcp']['outscraper']['enabled'] is False
assert 'environment' not in fresh['mcp']['outscraper']

config = home / 'outscraper.json'
sentinel = home / '.aidevops/.migrations/cleanup-deprecated-mcps-v4'
sentinel.parent.mkdir(parents=True)
sentinel.touch()
for field in ('env', 'environment'):
    original = {'mcp': {'outscraper': {
        'type': 'local', 'command': ['/legacy/outscraper-mcp-server'],
        'enabled': True, field: {'OUTSCRAPER_API_KEY': 'synthetic-inline', 'KEEP': 'yes'}
    }}, 'tools': {}}
    registered = copy.deepcopy(original)
    mcp_config._register_outscraper(registered)
    assert registered['mcp']['outscraper']['command'] == launcher
    assert registered['mcp']['outscraper'][field] == {'KEEP': 'yes'}
    config.write_text(json.dumps(original))
    result = subprocess.run(['bash', '-c', '''
source "$1"
find_opencode_config() { printf '%s\\n' "$CONFIG"; return 0; }
print_info() { local message="$1"; printf '%s\\n' "$message"; return 0; }
update_mcp_paths_in_opencode() { return 0; }
cleanup_deprecated_mcps && cleanup_deprecated_mcps
''', 'bash', str(repo / '.agents/scripts/setup/modules/migrations.sh')],
        env={**os.environ, 'CONFIG': str(config)}, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'synthetic-inline' not in result.stdout + result.stderr + config.read_text()
    migrated = json.loads(config.read_text())['mcp']['outscraper']
    assert migrated['command'] == launcher
    assert migrated[field] == {'KEEP': 'yes'} and migrated['enabled'] is True
    assert not list(home.glob('outscraper.json*bak*'))

for command in (['bash', '-c', 'exec ' + mcp_config.LEGACY_OUTSCRAPER_UV_RUN],
                ['bash', '-c', 'exec ' + mcp_config.OUTSCRAPER_UV_RUN],
                ['/legacy/outscraper-mcp-server']):
    cfg = {'mcp': {'outscraper': {'command': command}}, 'tools': {}}
    mcp_config._register_outscraper(cfg)
    assert cfg['mcp']['outscraper']['command'] == launcher
    before = copy.deepcopy(cfg)
    mcp_config._register_outscraper(cfg)
    assert cfg == before
custom = {'mcp': {'outscraper': {'command': ['/custom/launcher']}}, 'tools': {}}
mcp_config._register_outscraper(custom)
assert custom['mcp']['outscraper']['command'] == ['/custom/launcher']

scripts = home / '.aidevops/agents/scripts'
scripts.mkdir(parents=True)
shutil.copyfile(repo / '.agents/scripts/outscraper-credentials.sh', scripts / 'outscraper-credentials.sh')
bin_dir = home / 'bin'
bin_dir.mkdir()
gopass = bin_dir / 'gopass'
gopass.write_text('''#!/usr/bin/env bash
[[ "$*" == 'show -o aidevops/OUTSCRAPER_API_KEY' ]] || exit 2
printf 'called\\n' >> "$HOME/gopass-calls"
printf '%s' "${TEST_GOPASS_VALUE:-}"
exit "${TEST_GOPASS_STATUS:-0}"
''')
uv = bin_dir / 'uv'
uv.write_text('''#!/usr/bin/env bash
[[ "$*" == 'tool run --with mcp<2 outscraper-mcp-server' ]] || exit 2
[[ "${OUTSCRAPER_API_KEY:-}" == "$EXPECTED_KEY" ]] || exit 3
printf 'launcher-ok\\n'
''')
gopass.chmod(0o700)
uv.chmod(0o700)
credentials = home / '.config/aidevops/credentials.sh'
credentials.parent.mkdir(parents=True)
base_env = {k: v for k, v in os.environ.items() if k != 'OUTSCRAPER_API_KEY'}
base_env['PATH'] = str(bin_dir) + os.pathsep + base_env['PATH']
for env_key, file_key, store_key, status, succeeds in (
    ('synthetic-env', 'synthetic-file', 'synthetic-store', '0', True),
    ('', 'synthetic-file', 'synthetic-store', '0', True),
    ('', '', 'synthetic-store', '0', True),
    ('', '', '', '0', False),
    ('', '', 'synthetic-partial', '1', False),
):
    credentials.write_text('printf "suppressed-output\\n"\nexport OUTSCRAPER_API_KEY=' + file_key + '\n')
    calls = home / 'gopass-calls'
    calls.unlink(missing_ok=True)
    env = {**base_env, 'OUTSCRAPER_API_KEY': env_key,
           'TEST_GOPASS_VALUE': store_key, 'TEST_GOPASS_STATUS': status,
           'EXPECTED_KEY': env_key or file_key or store_key}
    result = subprocess.run(launcher, env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds
    assert result.stdout == ('launcher-ok\n' if succeeds else '')
    assert result.stderr == ''
    assert calls.exists() == (not env_key and not file_key)
credentials.unlink()
result = subprocess.run(launcher, env={**base_env, 'TEST_GOPASS_VALUE': 'synthetic-store',
                        'EXPECTED_KEY': 'synthetic-store'}, capture_output=True, text=True)
assert result.returncode == 0 and result.stdout == 'launcher-ok\n'
print('Registration, recurring migration, precedence, gopass fallback and fail-closed launch: PASS')
PY
pass "Outscraper registration, setup migration and launch-time credentials"

echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi
exit 0
