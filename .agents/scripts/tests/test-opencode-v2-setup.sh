#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SANDBOX="$(mktemp -d -t aidevops-opencode-v2-setup.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

print_info() { :; }
print_success() { :; }
print_warning() { :; }
print_skip() { :; }
setup_track_skipped() { :; }
setup_track_deferred() { :; }
setup_track_configured() { :; }

# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/setup/modules/mcp-setup.sh"

config="$SANDBOX/opencode.json"
cat >"$config" <<'JSON'
{"plugin":["file:///custom/plugin.mjs","file:///old/plugins/opencode-aidevops/index.mjs"]}
JSON
_setup_opencode_plugins_register_file_url "$config" \
	"$REPO_ROOT/.agents/plugins/opencode-aidevops/v2-plugin" plugins >/dev/null
jq -e '
  (has("plugin") | not)
  and ((.plugins | index("file:///custom/plugin.mjs")) != null)
  and ([.plugins[] | select(contains("/plugins/opencode-aidevops/"))] | length == 1)
  and ([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)
' "$config" >/dev/null

# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/setup/_services.sh"
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/opencode2" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf 'opencode v2.0.3\n'
[[ "${1:-}" == "--help" ]] && printf 'OpenCode command line interface\nrun  Run OpenCode with a message\n'
exit 0
SHIM
chmod +x "$SANDBOX/bin/opencode2"
AIDEVOPS_OPENCODE_PROFILE=v2 _setup_validate_opencode_binary "$SANDBOX/bin/opencode2"
if AIDEVOPS_OPENCODE_PROFILE=v1 _setup_validate_opencode_binary "$SANDBOX/bin/opencode2"; then
	printf 'V1 validator accepted a V2 binary\n' >&2
	exit 1
fi
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 \
	OPENCODE_BIN="$SANDBOX/bin/opencode2" setup_opencode_cli
[[ "$(<"$HOME/.aidevops/.opencode-bin-resolved")" == "$HOME/.local/bin/opencode2" ]]
[[ -x "$HOME/.local/bin/opencode2" ]]
[[ ! -e "$HOME/.local/bin/opencode" ]]
grep -Eq '^exec ".*/opencode2" "\$@"$' "$HOME/.local/bin/opencode2"

mkdir -p "$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin"
printf 'export default {};\n' >"$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin/index.mjs"
find_opencode_config() { printf '%s\n' "$config"; }
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_plugins
jq -e '
  (has("plugin") | not)
  and ([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)
' "$config" >/dev/null

printf 'OpenCode V2 setup tests passed\n'
