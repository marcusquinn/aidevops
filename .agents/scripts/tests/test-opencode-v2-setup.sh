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
# Run from an opencode2 shell, the shim's exports point at the live V2 runtime.
# HOME alone does not isolate them; leaking them let this test overwrite the
# live V2 config and break V2 provider auth (GH#32738).
unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME \
	AIDEVOPS_OPENCODE_PROFILE AIDEVOPS_OPENCODE_V2_ROOT AIDEVOPS_OPENCODE_V2_CONFIG_HOME \
	AIDEVOPS_OPENCODE_V2_CONFIG_DIR AIDEVOPS_OPENCODE_V2_CONFIG AIDEVOPS_OPENCODE_V2_STATE_HOME \
	AIDEVOPS_OAUTH_POOL_FILE AIDEVOPS_SKIP_OPENCODE_V2_SERVICE_RESTART

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
# setup.sh's print_* helpers write to stdout; the captured status must stay clean.
print_success() { printf '[SUCCESS] %s\n' "$1"; }
registered_status=$(_setup_opencode_plugins_register_file_url "$config" \
	"$REPO_ROOT/.agents/plugins/opencode-aidevops/v2-plugin" plugins 2>/dev/null)
print_success() { :; }
[[ "$registered_status" == "true" ]]
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
grep -Fxq "$(_setup_opencode_v2_shim_version_marker)" "$HOME/.local/bin/opencode2"
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
framework_guide="$HOME/.aidevops/agents/AGENTS.md"
printf '# AI DevOps Framework - User Guide\n' >"$framework_guide"
find_opencode_config() { printf '%s\n' "${OPENCODE_CONFIG:-$config}"; }
# Pre-seed the legacy auto-discovered symlink that caused OpenCode V2 to reject
# the config entry with "Duplicate plugin ID: aidevops"; setup must remove it.
v2_plugins_dir="$HOME/.aidevops/runtimes/opencode-v2/config/opencode/plugins"
v2_symlink="$v2_plugins_dir/aidevops-v2"
mkdir -p "$v2_plugins_dir"
ln -s "$HOME/.aidevops/agents/plugins/opencode-aidevops/v2-plugin" "$v2_symlink"
ln -s "$SANDBOX/user-owned-plugin" "$v2_plugins_dir/user-owned"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_plugins
v2_config="$HOME/.aidevops/runtimes/opencode-v2/config/opencode/opencode.json"
jq -e '
  (has("plugin") | not)
  and ([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)
' "$v2_config" >/dev/null
[[ ! -e "$v2_symlink" && ! -L "$v2_symlink" ]]
[[ -L "$v2_plugins_dir/user-owned" ]]
jq -e '(.plugins | index("file:///custom/plugin.mjs")) != null' "$config" >/dev/null
# V2 loads <config>/opencode/AGENTS.md; setup links the framework guide there.
v2_guide="$HOME/.aidevops/runtimes/opencode-v2/config/opencode/AGENTS.md"
[[ -L "$v2_guide" && "$(readlink "$v2_guide")" == "$framework_guide" ]] ||
	{ printf 'V2 config does not link the framework AGENTS.md\n' >&2; exit 1; }
ln -sfn "$HOME/.aidevops/agents/stale-guide.md" "$v2_guide"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_plugins
[[ "$(readlink "$v2_guide")" == "$framework_guide" ]] ||
	{ printf 'stale managed V2 AGENTS.md link was not repaired\n' >&2; exit 1; }
custom_v2_root="$SANDBOX/custom-v2-root"
mkdir -p "$custom_v2_root/config/opencode"
printf 'user guide\n' >"$custom_v2_root/config/opencode/AGENTS.md"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 \
	AIDEVOPS_OPENCODE_V2_ROOT="$custom_v2_root" setup_opencode_plugins
[[ -f "$custom_v2_root/config/opencode/opencode.json" ]]
[[ ! -L "$custom_v2_root/config/opencode/AGENTS.md" ]]
[[ "$(<"$custom_v2_root/config/opencode/AGENTS.md")" == "user guide" ]] ||
	{ printf 'user-authored V2 AGENTS.md was replaced\n' >&2; exit 1; }
[[ ! -L "$custom_v2_root/config/opencode/plugins/aidevops-v2" ]]
jq -e '([.plugins[] | select(endswith("/v2-plugin"))] | length == 1)' \
	"$custom_v2_root/config/opencode/opencode.json" >/dev/null
# When the config entry cannot be written, the symlink remains the sole fallback.
fallback_v2_root="$SANDBOX/fallback-v2-root"
mkdir -p "$fallback_v2_root/config/opencode"
ln -s "$SANDBOX/user-guide.md" "$fallback_v2_root/config/opencode/AGENTS.md"
(
	_setup_opencode_plugins_register_file_url() { printf 'false\n'; }
	PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 \
		AIDEVOPS_OPENCODE_V2_ROOT="$fallback_v2_root" setup_opencode_plugins
)
[[ -L "$fallback_v2_root/config/opencode/plugins/aidevops-v2" ]]
[[ "$(readlink "$fallback_v2_root/config/opencode/AGENTS.md")" == "$SANDBOX/user-guide.md" ]] ||
	{ printf 'user-managed V2 AGENTS.md link was replaced\n' >&2; exit 1; }

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
# GH#32738: a V1 pass started from an opencode2 shell inherits the shim's V2
# config env. The V1 pass alone (no V2 pass to repair it afterwards) must leave
# the V2 config and plugins dir alone and still target the V1 config.
v2_config_before=$(<"$v2_config")
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v1 AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 \
	OPENCODE_CONFIG="$v2_config" OPENCODE_CONFIG_DIR="${v2_config%/*}" \
	XDG_CONFIG_HOME="$HOME/.aidevops/runtimes/opencode-v2/config" setup_opencode_runtime_plugins
[[ "$(<"$v2_config")" == "$v2_config_before" ]] ||
	{ printf 'V1 plugin pass rewrote the V2 config from ambient V2 env\n' >&2; exit 1; }
[[ ! -e "$v2_plugins_dir/opencode-aidevops" && ! -L "$v2_plugins_dir/opencode-aidevops" ]] ||
	{ printf 'V1 plugin pass linked the V1 plugin into the V2 plugins dir\n' >&2; exit 1; }
[[ "$(readlink "$v1_symlink")" == "$HOME/.aidevops/agents/plugins/opencode-aidevops" ]]
jq -e '([.plugin[] | select(endswith("/index.mjs"))] | length == 1)' "$config" >/dev/null
# A redeploy's V2 pass removes V1 link residue from the V2 plugins dir.
ln -s "$HOME/.aidevops/agents/plugins/opencode-aidevops" "$v2_plugins_dir/opencode-aidevops"
PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_plugins
[[ ! -e "$v2_plugins_dir/opencode-aidevops" && ! -L "$v2_plugins_dir/opencode-aidevops" ]] ||
	{ printf 'V1 plugin link remained in the V2 plugins dir\n' >&2; exit 1; }
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

# GH#33046: another tool's per-process OPENCODE_CONFIG must never become a
# setup write target; user-owned and opted-in locations stay honoured.
user_config="$HOME/.config/opencode/opencode.json"
mkdir -p "${user_config%/*}"
[[ -f "$user_config" ]] || printf '{}\n' >"$user_config"
foreign_config="$SANDBOX/foreign-tool/analysis-opencode.json"
mkdir -p "${foreign_config%/*}"
printf '{"agent":{"image-analyzer":{"permission":{"*":"deny"}}}}\n' >"$foreign_config"
foreign_before=$(<"$foreign_config")
dotfiles_config="$SANDBOX/dotfiles/opencode.json"
mkdir -p "${dotfiles_config%/*}"
printf '{}\n' >"$dotfiles_config"
for helper in "$REPO_ROOT/.agents/scripts/setup/_common.sh" "$REPO_ROOT/.agents/scripts/setup/_runtime_helpers.sh"; do
	resolved_set=$(
		unset _SETUP_RUNTIME_HELPERS_LOADED
		# shellcheck source=/dev/null
		source "$helper"
		printf '%s|' "$(OPENCODE_CONFIG="$foreign_config" find_opencode_config 2>/dev/null)"
		printf '%s|' "$(OPENCODE_CONFIG_DIR="${foreign_config%/*}" find_opencode_config 2>/dev/null)"
		printf '%s|' "$(OPENCODE_CONFIG="$user_config" find_opencode_config 2>/dev/null)"
		printf '%s|' "$(AIDEVOPS_OPENCODE_USER_CONFIG="$dotfiles_config" OPENCODE_CONFIG="$dotfiles_config" find_opencode_config 2>/dev/null)"
		printf '%s' "$(AIDEVOPS_OPENCODE_USER_CONFIG="${dotfiles_config%/*}" find_opencode_config 2>/dev/null)"
	)
	expected_set="${user_config}|${user_config}|${user_config}|${dotfiles_config}|${dotfiles_config}"
	[[ "$resolved_set" == "$expected_set" ]] ||
		{ printf '%s resolved ambient configs unexpectedly: %s\n' "$(basename "$helper")" "$resolved_set" >&2; exit 1; }
done
notice=$(
	unset -f find_opencode_config
	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/setup/_common.sh"
	OPENCODE_CONFIG="$foreign_config" find_opencode_config 2>&1 >/dev/null || true
)
[[ "$notice" == *"AIDEVOPS_OPENCODE_USER_CONFIG"* ]] ||
	{ printf 'foreign ambient config skip was silent\n' >&2; exit 1; }
(
	# Exercise the real resolver, not the stub used by the earlier passes.
	unset -f find_opencode_config
	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/setup/_common.sh"
	PATH="$SANDBOX/bin:$PATH" AIDEVOPS_OPENCODE_PROFILE=v1 AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 \
		OPENCODE_CONFIG="$foreign_config" setup_opencode_runtime_plugins
) >/dev/null 2>&1
[[ "$(<"$foreign_config")" == "$foreign_before" ]] ||
	{ printf 'V1 plugin pass rewrote a foreign OPENCODE_CONFIG\n' >&2; exit 1; }
jq -e '([.plugin[] | select(endswith("/opencode-aidevops/index.mjs"))] | length == 1)' "$user_config" >/dev/null ||
	{ printf 'V1 plugin pass did not register in the user config\n' >&2; exit 1; }

grep -Eq '_time_step .* setup_opencode_runtimes$' "$REPO_ROOT/setup.sh"
grep -Eq 'confirm_step .*setup_opencode_runtimes$' "$REPO_ROOT/setup.sh"
grep -Eq '_time_step .* setup_opencode_runtime_plugins$' "$REPO_ROOT/setup.sh"
grep -Eq 'confirm_step .*setup_opencode_runtime_plugins$' "$REPO_ROOT/setup.sh"

# A redeploy must restart a running V2 background service (stale plugin
# resolution drops provider OAuth hooks) but never the service hosting setup.
# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-deploy.sh"
set +e
service_state="$SANDBOX/v2-state"
restart_log="$SANDBOX/v2-restart.log"
mkdir -p "$service_state/opencode"
cat >"$SANDBOX/bin/opencode2-service" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$restart_log"
exit 0
SHIM
chmod +x "$SANDBOX/bin/opencode2-service"
printf '%s\n' "$SANDBOX/bin/opencode2-service" >"$HOME/.aidevops/.opencode-v2-bin-resolved"
sleep 30 &
fake_service_pid=$!
printf '{"pid":%s}\n' "$fake_service_pid" >"$service_state/opencode/service.json"
AIDEVOPS_OPENCODE_V2_STATE_HOME="$service_state" _restart_opencode_v2_service_after_deploy
grep -Fxq 'service restart' "$restart_log" || { printf 'running V2 service was not restarted\n' >&2; exit 1; }
: >"$restart_log"
AIDEVOPS_SKIP_OPENCODE_V2_SERVICE_RESTART=1 AIDEVOPS_OPENCODE_V2_STATE_HOME="$service_state" \
	_restart_opencode_v2_service_after_deploy
printf '{"pid":%s}\n' "$$" >"$service_state/opencode/service.json"
AIDEVOPS_OPENCODE_V2_STATE_HOME="$service_state" _restart_opencode_v2_service_after_deploy
kill "$fake_service_pid" 2>/dev/null
wait "$fake_service_pid" 2>/dev/null || true
printf '{"pid":%s}\n' "$fake_service_pid" >"$service_state/opencode/service.json"
AIDEVOPS_OPENCODE_V2_STATE_HOME="$service_state" _restart_opencode_v2_service_after_deploy
[[ ! -s "$restart_log" ]] || { printf 'V2 service restarted when it must be skipped\n' >&2; exit 1; }
set -e

printf 'OpenCode V2 setup tests passed\n'
