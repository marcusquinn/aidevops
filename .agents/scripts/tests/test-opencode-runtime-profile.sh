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
assert_eq "V2 canary metadata" "pass:2.0.3" "$(jq -r '.last_canary_result' <<<"$status_json")"

printf 'OpenCode runtime profile tests passed\n'
