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

# Exercise the active setup module rather than the legacy compatibility copy.
# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh"
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
[[ "$(<"$HOME/.aidevops/.opencode-v2-bin-resolved")" == "$HOME/.local/bin/opencode2" ]]
[[ -x "$HOME/.local/bin/opencode2" ]]
[[ ! -e "$HOME/.local/bin/opencode" ]]
grep -Fq '# aidevops:opencode-v2-isolation' "$HOME/.local/bin/opencode2"
grep -Eq '^exec ".*/opencode2" "\$@"$' "$HOME/.local/bin/opencode2"
resolved_v2_binary=$(PATH="/usr/bin:/bin" _setup_opencode_plugins_resolve_binary opencode2 v2)
[[ "$resolved_v2_binary" == "$HOME/.local/bin/opencode2" ]]

cat >"$SANDBOX/bin/opencode" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf '1.18.29\n'
[[ "${1:-}" == "--help" ]] && printf 'opencode run [message]\n'
exit 0
SHIM
chmod +x "$SANDBOX/bin/opencode"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v1 \
	OPENCODE_BIN="$SANDBOX/bin/opencode" setup_opencode_runtimes
[[ "$(<"$HOME/.aidevops/.opencode-bin-resolved")" == "$HOME/.local/bin/opencode" ]]
[[ "$(<"$HOME/.aidevops/.opencode-v1-bin-resolved")" == "$HOME/.local/bin/opencode" ]]
[[ "$(<"$HOME/.aidevops/.opencode-v2-bin-resolved")" == "$HOME/.local/bin/opencode2" ]]
[[ -x "$HOME/.local/bin/opencode" && -x "$HOME/.local/bin/opencode2" ]]
isolated_pool="$SANDBOX/isolated-oauth-pool.json"
resolved_pool=$(AIDEVOPS_OAUTH_POOL_FILE="$isolated_pool" node --input-type=module -e \
	'import(process.argv[1]).then((module) => process.stdout.write(module.POOL_FILE))' \
	"$REPO_ROOT/.agents/plugins/opencode-aidevops/oauth-pool-constants.mjs")
[[ "$resolved_pool" == "$isolated_pool" ]]
grep -Fq "POOL_FILE=\"\${AIDEVOPS_OAUTH_POOL_FILE:-" "$REPO_ROOT/.agents/scripts/oauth-pool-helper.sh"

mkdir -p "$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin"
printf 'export default {};\n' >"$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin/index.mjs"
find_opencode_config() { printf '%s\n' "${OPENCODE_CONFIG:-$config}"; }
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_plugins
v2_config="$HOME/.aidevops/runtimes/opencode-v2/config/opencode/opencode.json"
jq -e '
  (has("plugin") | not)
  and ([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)
' "$v2_config" >/dev/null
v2_symlink="$HOME/.aidevops/runtimes/opencode-v2/config/opencode/plugins/aidevops-v2"
[[ -L "$v2_symlink" ]]
[[ "$(readlink "$v2_symlink")" == "$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin" ]]
jq -e '(.plugins | index("file:///custom/plugin.mjs")) != null' "$config" >/dev/null
custom_v2_root="$SANDBOX/custom-v2-root"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 \
	AIDEVOPS_OPENCODE_V2_ROOT="$custom_v2_root" setup_opencode_plugins
[[ -f "$custom_v2_root/config/opencode/opencode.json" ]]
[[ -L "$custom_v2_root/config/opencode/plugins/aidevops-v2" ]]

printf 'export default {};\n' >"$HOME/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
aidevops_opencode_profile_id() { printf '%s\n' "${AIDEVOPS_OPENCODE_PROFILE:-v1}"; }
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v1 setup_opencode_runtime_plugins
jq -e '
  (has("plugins") | not)
  and ((.plugin | index("file:///custom/plugin.mjs")) != null)
  and ([.plugin[] | select(endswith("/index.mjs"))] | length == 1)
' "$config" >/dev/null
v1_symlink="$HOME/.config/opencode/plugins/opencode-aidevops"
[[ -L "$v1_symlink" ]]
[[ "$(readlink "$v1_symlink")" == "$HOME/.aidevops/agents/plugins/opencode-aidevops" ]]
jq -e '([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)' "$v2_config" >/dev/null
ambient_v2_config="$SANDBOX/ambient-v2.json"
printf '{"plugins":["file:///ambient-v2.mjs"]}\n' >"$ambient_v2_config"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 \
	OPENCODE_CONFIG="$ambient_v2_config" XDG_CONFIG_HOME="$SANDBOX/ambient-v2-xdg" \
	setup_opencode_runtime_plugins
jq -e '
  (.plugins | index("file:///ambient-v2.mjs")) != null
  and ([.plugins[] | select(contains("opencode-aidevops"))] | length == 0)
  and (has("plugin") | not)
' "$ambient_v2_config" >/dev/null
jq -e '([.plugin[] | select(endswith("/index.mjs"))] | length == 1)' "$config" >/dev/null

for helper in "$REPO_ROOT/.agents/scripts/setup/_common.sh" "$REPO_ROOT/.agents/scripts/setup/_runtime_helpers.sh"; do
	xdg_root="$SANDBOX/xdg-$(basename "$helper")"
	mkdir -p "$xdg_root/opencode"
	printf '{}\n' >"$xdg_root/opencode/opencode.json"
	resolved=$(
		unset _SETUP_RUNTIME_HELPERS_LOADED
		# shellcheck source=/dev/null
		source "$helper"
		XDG_CONFIG_HOME="$xdg_root" find_opencode_config
	)
	[[ "$resolved" == "$xdg_root/opencode/opencode.json" ]]
done

grep -Eq '_time_step .* setup_opencode_runtimes$' "$REPO_ROOT/setup.sh"
grep -Eq 'confirm_step .*setup_opencode_runtimes$' "$REPO_ROOT/setup.sh"
grep -Eq '_time_step .* setup_opencode_runtime_plugins$' "$REPO_ROOT/setup.sh"
grep -Eq 'confirm_step .*setup_opencode_runtime_plugins$' "$REPO_ROOT/setup.sh"

printf 'OpenCode V2 setup tests passed\n'
