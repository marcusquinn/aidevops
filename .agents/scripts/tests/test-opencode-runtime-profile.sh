#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)
HELPER="$REPO_ROOT/.agents/scripts/opencode-runtime-profile.py"

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
		exit 1
	fi
}

assert_eq "default remains rollback-safe until canary promotion" "v1" "$(python3 "$HELPER" default)"
assert_eq "V1 package" "opencode-ai" "$(python3 "$HELPER" get v1 package)"
assert_eq "V2 package" "@opencode/cli" "$(python3 "$HELPER" get v2 package)"
assert_eq "V2 plugin entry" "v2.mjs" "$(python3 "$HELPER" get v2 pluginEntry)"
assert_eq "V2 config plugin target" "v2-plugin" "$(python3 "$HELPER" get v2 pluginConfigTarget)"
assert_eq "V2 detection" "v2" "$(python3 "$HELPER" detect 'OpenCode 2.0.3')"
assert_eq "explicit rollback selection" "v1" "$(AIDEVOPS_OPENCODE_PROFILE=v1 python3 "$HELPER" selected)"

SANDBOX=$(mktemp -d -t aidevops-opencode-profile.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/npm" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == "view" && "${2:-}" == "@opencode/cli" ]] || exit 1
printf '2.0.3\n'
SHIM
cat >"$SANDBOX/bin/opencode2" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] || exit 1
printf '2.0.3\n'
SHIM
chmod +x "$SANDBOX/bin/npm" "$SANDBOX/bin/opencode2"
status_json=$(PATH="$SANDBOX/bin:$PATH" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
	AIDEVOPS_OPENCODE_PROFILE=v2 "$REPO_ROOT/.agents/scripts/opencode-pin-canary.sh" status --json)
assert_eq "V2 canary profile" "v2" "$(jq -r '.profile' <<<"$status_json")"
assert_eq "V2 canary package registry" "2.0.3" "$(jq -r '.registry_latest' <<<"$status_json")"
assert_eq "V2 canary metadata" "$(python3 "$HELPER" get v2 lastCanaryResult)" "$(jq -r '.last_canary_result' <<<"$status_json")"

# Exercise the actual setup entry point in an isolated home, never the live config.
export HOME="$SANDBOX/home" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents"
unset AIDEVOPS_OPENCODE_PROFILE OPENCODE_CONFIG OPENCODE_CONFIG_DIR XDG_CONFIG_HOME
unset AIDEVOPS_OPENCODE_V2_ROOT AIDEVOPS_OPENCODE_V2_CONFIG_HOME AIDEVOPS_OPENCODE_V2_CONFIG_DIR AIDEVOPS_OPENCODE_V2_CONFIG
export PATH="$SANDBOX/bin:$PATH"
mkdir -p "$HOME/.config/opencode/plugins" "$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin"
touch "$HOME/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
cat >"$SANDBOX/bin/opencode" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${TEST_OPENCODE_VERSION:-2.2.6}"
SHIM
chmod +x "$SANDBOX/bin/opencode"
print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_skip() { return 0; }
setup_track_skipped() { return 0; }
setup_track_deferred() { return 0; }
setup_track_configured() { return 0; }
opencode_config_path_is_v2_owned() { return 1; }
find_opencode_config() { printf '%s\n' "$HOME/.config/opencode/opencode.json"; return 0; }
aidevops_opencode_profile_id() { printf '%s\n' "${AIDEVOPS_OPENCODE_PROFILE:-v1}"; return 0; }
# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/setup/modules/mcp-setup.sh"
config="$HOME/.config/opencode/opencode.json"
managed="$HOME/.aidevops/agents/plugins/opencode-aidevops"
jq -n --arg old "file://$managed/index.mjs" --arg current "file://$managed/v2-plugin" \
  '{plugin:[$old,"file:///foreign/plugins/opencode-aidevops/index.mjs"],plugins:[$current,"other-plugin"]}' >"$config"
ln -s "$managed" "$HOME/.config/opencode/plugins/opencode-aidevops"
chmod 755 "$HOME/.config" "$HOME/.config/opencode"
AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 setup_opencode_runtime_plugins
jq -e --arg url "file://$managed/v2-plugin" \
  '(.plugins | index($url)) != null and (.plugins | index("other-plugin")) != null and (.plugins | index("file:///foreign/plugins/opencode-aidevops/index.mjs")) != null and (has("plugin") | not)' "$config" >/dev/null
[[ ! -L "$HOME/.config/opencode/plugins/opencode-aidevops" ]]
assert_eq "global config mode unchanged" "755" "$(stat -c %a "$HOME/.config/opencode")"
before=$(<"$config")
AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 setup_opencode_runtime_plugins
assert_eq "v2 registration is idempotent" "$before" "$(<"$config")"
AIDEVOPS_OPENCODE_PROFILE=v1 AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 setup_opencode_runtime_plugins
jq -e --arg url "file://$managed/index.mjs" '(.plugin | index($url)) != null and (has("plugins") | not)' "$config" >/dev/null
[[ -L "$HOME/.config/opencode/plugins/opencode-aidevops" ]]
TEST_OPENCODE_VERSION=1.19.5 AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=1 setup_opencode_runtime_plugins
jq -e 'has("plugin") and (has("plugins") | not)' "$config" >/dev/null
TEST_OPENCODE_VERSION=nonsense AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 setup_opencode_runtime_plugins
jq -e 'has("plugin") and (has("plugins") | not)' "$config" >/dev/null
AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_runtime_plugins
jq -e 'has("plugins")' "$HOME/.aidevops/runtimes/opencode-v2/config/opencode/opencode.json" >/dev/null

printf 'OpenCode runtime profile tests passed\n'
