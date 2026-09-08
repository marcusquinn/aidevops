#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../site-context-helper.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-site-context.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "${TMP_DIR}/home/.config/aidevops"
cat >"${TMP_DIR}/home/.config/aidevops/site-inventory.json" <<'JSON'
{"version":1,"hosting_accounts":{"hostinger":{"ssh_host":"ssh.example.com","ssh_port":65002,"ssh_user":"u123","credential_env":"HOSTINGER_SSH_PASSWORD","last_verified":"2026-01-01T00:00:00Z"}},"sites":{"network":{"name":"Example Network","canonical_hostname":"example.com","aliases":["www.example.com"],"platform":"wordpress-multisite","environment":"production","dns":{"provider":"cloudflare","zone_ref":"example.com"},"hosting":{"provider":"hostinger","account_ref":"hostinger","deployment_path":"/domains/example.com/public_html"},"provenance":"manual","last_verified":"2026-01-01T00:00:00Z","children":{"shop":{"hostname":"shop.example.com","identity":"shop"}}}}}
JSON
run_helper() {
	HOME="${TMP_DIR}/home" "$HELPER" "$@"
	return $?
}
assert_json() {
	local name="$1"
	local output="$2"
	local query="$3"
	if jq -e "$query" <<<"$output" >/dev/null; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	return 1
}

run_helper validate
parent=$(run_helper lookup www.example.com)
assert_json "alias resolves canonical site" "$parent" '.canonical_hostname == "example.com" and .hosting.ssh_host == "ssh.example.com"'
child=$(run_helper readiness shop.example.com)
assert_json "mapped child inherits parent hosting" "$child" '.child.identity == "shop" and .hosting.deployment_path == "/domains/example.com/public_html" and .readiness == "ready"'
gap=$(run_helper readiness missing.example.com)
assert_json "missing inventory remains an evidence gap" "$gap" '.status == "gap" and .discovery == "not_configured"'
stale_config=$(jq 'del(.hosting_accounts.hostinger.last_verified)' "${TMP_DIR}/home/.config/aidevops/site-inventory.json")
printf '%s\n' "$stale_config" >"${TMP_DIR}/home/.config/aidevops/site-inventory.json"
stale=$(run_helper readiness example.com)
assert_json "absent freshness is reported stale" "$stale" '.readiness == "stale"'
[[ "$parent" == *'HOSTINGER_SSH_PASSWORD'* && "$parent" != *'secret-value'* ]] && printf 'PASS credential reference is name-only\n'
