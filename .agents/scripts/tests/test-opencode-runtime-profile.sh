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

# t18904: detect-based profile mapping and rollback fallbacks.
assert_eq "detect falls back for non-numeric version output" "v1" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE python3 "$HELPER" detect 'nonsense')"
assert_eq "detect maps an unknown major to the rollback default" "v1" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE python3 "$HELPER" detect 'OpenCode 9.9.9')"
assert_eq "detect keeps v1 for pinned 1.x output" "v1" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE python3 "$HELPER" detect 'OpenCode 1.19.5')"
assert_eq "detect keeps v2 for the only installed runtime's output" "v2" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE python3 "$HELPER" detect 'OpenCode 2.2.6')"

# t18904: helper-shell detection wiring in shared-constants.sh.
SHARED="$REPO_ROOT/.agents/scripts/shared-constants.sh"
MODULE="$REPO_ROOT/.agents/scripts/setup/modules/mcp-setup.sh"
cat >"$SANDBOX/bin/opencode" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
	--version) printf 'OpenCode 2.2.6\n' ;;
	*) exit 0 ;;
esac
SHIM
chmod +x "$SANDBOX/bin/opencode"
PYBIN=$(command -v python3) || true
if [[ -n "$PYBIN" ]]; then
	pydir="${PYBIN%/*}"
else
	printf 'FAIL: python3 is required for the t18904 precedence tests\n' >&2
	exit 1
fi
nobin_path="$SANDBOX/nobin:/usr/bin:/bin:$pydir"

# shellcheck disable=SC2016
assert_eq "shell profile detects the installed v2 binary" "v2" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE PATH="$SANDBOX/bin:$PATH" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
		bash -c 'source "$1" && aidevops_opencode_profile_id' _ "$SHARED" 2>/dev/null)"
# shellcheck disable=SC2016
assert_eq "shell profile falls back to v1 without a binary" "v1" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE PATH="$nobin_path" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
		bash -c 'source "$1" && aidevops_opencode_profile_id' _ "$SHARED" 2>/dev/null)"
# shellcheck disable=SC2016
assert_eq "explicit env override wins over a detected v2 binary" "v1" \
	"$(env AIDEVOPS_OPENCODE_PROFILE=v1 PATH="$SANDBOX/bin:$PATH" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
		bash -c 'source "$1" && aidevops_opencode_profile_id' _ "$SHARED" 2>/dev/null)"

# t18904: module-level registration contract over jq fixtures.
mkdir -p "$SANDBOX/reg"
print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_skip() { return 0; }
# shellcheck source=/dev/null
source "$MODULE"
trap - ERR

reg_conf="$SANDBOX/reg/opencode.json"
printf '{"theme":"dark","plugin":["file:///stale/opencode-aidevops/index.mjs"]}\n' >"$reg_conf"
reg_status=$(_setup_opencode_plugins_register_file_url "$reg_conf" \
	"/run/x/.aidevops/agents/plugins/opencode-aidevops/v2-plugin" "plugins")
assert_eq "register reports success under the plugins key" "true" "$reg_status"
assert_eq "register converges aidevops entries to one plugins URL" "v2-plugin" \
	"$(jq -r '.plugins[0]' "$reg_conf" | sed 's|.*/||')"
assert_eq "register removes the superseded v1 plugin key" "absent" \
	"$(jq -r 'if has("plugin") then "present" else "absent" end' "$reg_conf")"
assert_eq "register preserves foreign config keys" "dark" "$(jq -r '.theme' "$reg_conf")"
reg_status=$(_setup_opencode_plugins_register_file_url "$reg_conf" \
	"/run/x/.aidevops/agents/plugins/opencode-aidevops/v2-plugin" "plugins")
assert_eq "register stays idempotent across repeated runs" "1" \
	"$(jq -r '.plugins | length' "$reg_conf")"

# shellcheck disable=SC2016
assert_eq "global contract ignores the env override and detects v2" "v2" \
	"$(env AIDEVOPS_OPENCODE_PROFILE=v1 PATH="$SANDBOX/bin:$PATH" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
		bash -c 'source "$1" && source "$2" && _setup_opencode_global_contract_profile' _ "$SHARED" "$MODULE" 2>/dev/null)"
# shellcheck disable=SC2016
assert_eq "global contract falls back to v1 without a binary" "v1" \
	"$(env -u AIDEVOPS_OPENCODE_PROFILE PATH="$nobin_path" AIDEVOPS_AGENTS_DIR="$REPO_ROOT/.agents" \
		bash -c 'source "$1" && source "$2" && _setup_opencode_global_contract_profile' _ "$SHARED" "$MODULE" 2>/dev/null)"

printf 'OpenCode runtime profile tests passed\n'
