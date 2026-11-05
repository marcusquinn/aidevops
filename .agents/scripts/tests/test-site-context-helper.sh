#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../site-context-helper.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-site-context.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "${TMP_DIR}/home/.config/aidevops"
export AIDEVOPS_SITE_INVENTORY="${TMP_DIR}/home/.config/aidevops/site-inventory.json"
export AIDEVOPS_CREDENTIAL_INVENTORY="${TMP_DIR}/home/.config/aidevops/credential-inventory.json"
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

# Extend the existing fixture with a names-only transport. Unknown commands fail;
# no secret value-reading or hosted connection command is permitted by the stub.
mkdir -p "${TMP_DIR}/bin"
export SITE_TEST_CALLS="${TMP_DIR}/calls"
cat >"${TMP_DIR}/bin/aidevops" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SITE_TEST_CALLS"
[[ "$*" == "secret inventory" ]] || exit 90
[[ "${SITE_TEST_FAILURE:-0}" == 0 ]] || {
	printf 'private backend diagnostic\n' >&2
	exit 1
}
printf '%s\n' "$SITE_TEST_METADATA"
STUB
chmod +x "${TMP_DIR}/bin/aidevops"
export PATH="${TMP_DIR}/bin:${PATH}"
protected_config=$(jq '
	.hosting_accounts.hostinger |= (del(.ssh_host, .ssh_port, .ssh_user) + {
		ssh_host_env:"EXAMPLE_SSH_HOST", ssh_user_env:"EXAMPLE_SSH_USER",
		ssh_port_env:"EXAMPLE_SSH_PORT", last_verified:"2026-01-01T00:00:00Z"})
' <<<"$stale_config")
printf '%s\n' "$protected_config" >"$AIDEVOPS_SITE_INVENTORY"
export SITE_TEST_METADATA='{"version":1,"backends":{"gopass":"available","credentials":"missing"},"secrets":[{"name":"EXAMPLE_SSH_HOST","status":"configured"},{"name":"EXAMPLE_SSH_USER","status":"configured"},{"name":"EXAMPLE_SSH_PORT","status":"configured"}],"debug":"not-for-output"}'
run_helper validate
protected=$(run_helper lookup www.example.com)
assert_json "lookup preserves protected references without materializing values" "$protected" '.hosting.ssh_host_env == "EXAMPLE_SSH_HOST" and .hosting.ssh_host == null and .hosting.ssh_user == null'
[[ ! -e "$SITE_TEST_CALLS" ]] || {
	printf 'FAIL lookup queried secret metadata\n' >&2
	exit 1
}
protected=$(run_helper readiness shop.example.com)
assert_json "child readiness accepts configured names only with explicit scope" "$protected" '.readiness == "ready" and .readiness_scope == "configuration_only" and .hosting.ssh_port_env == "EXAMPLE_SSH_PORT" and (has("debug") | not)'

complete_metadata="$SITE_TEST_METADATA"
for name in EXAMPLE_SSH_HOST EXAMPLE_SSH_USER EXAMPLE_SSH_PORT; do
	SITE_TEST_METADATA=$(jq -c --arg name "$name" '.secrets |= map(select(.name != $name))' <<<"$complete_metadata")
	gap=$(run_helper readiness example.com)
	assert_json "missing declared reference fails closed: $name" "$gap" '.readiness == "gap" and .reason == "SSH connection secret references are not configured"'
done

for metadata in 'not-json' '{"version":1}' \
	'{"version":1,"backends":{"gopass":"error","credentials":"available"},"secrets":[]}' \
	'{"version":1,"backends":{"gopass":"missing"},"secrets":[]}' \
	'{"version":1,"backends":{"gopass":"available"},"secrets":[{"name":"BAD;NAME","status":"configured"}]}'; do
	SITE_TEST_METADATA="$metadata"
	gap=$(run_helper readiness example.com)
	assert_json "unavailable or malformed metadata fails closed" "$gap" '.readiness == "gap" and .reason == "SSH secret-name inventory is unavailable or invalid"'
done
SITE_TEST_METADATA="$complete_metadata"
export SITE_TEST_FAILURE=1
gap=$(run_helper readiness example.com 2>&1)
assert_json "backend command failure emits no private diagnostics" "$gap" '.readiness == "gap"'
unset SITE_TEST_FAILURE

for invalid_ref in 'null' '123' '""' '"lowercase"' '"BAD;NAME"'; do
	jq --argjson ref "$invalid_ref" '.hosting_accounts.hostinger.ssh_host_env = $ref' \
		<<<"$protected_config" >"$AIDEVOPS_SITE_INVENTORY"
	if run_helper validate >/dev/null 2>&1; then
		printf 'FAIL invalid reference passed validation\n' >&2
		exit 1
	fi
	gap=$(run_helper readiness example.com)
	assert_json "invalid reference cannot become ready" "$gap" '.readiness == "gap"'
done
jq '.hosting_accounts.hostinger.ssh_host = "ssh.example.com"' <<<"$protected_config" >"$AIDEVOPS_SITE_INVENTORY"
if run_helper validate >/dev/null 2>&1; then
	printf 'FAIL ambiguous literal/reference passed validation\n' >&2
	exit 1
fi
gap=$(run_helper readiness example.com)
assert_json "conflicting literal cannot bypass a reference" "$gap" '.readiness == "gap" and .reason == "SSH secret references are invalid or ambiguous"'
jq 'del(.hosting_accounts.hostinger.last_verified)' <<<"$protected_config" >"$AIDEVOPS_SITE_INVENTORY"
export SITE_TEST_FAILURE=1
stale=$(run_helper readiness example.com)
assert_json "references do not override missing freshness" "$stale" '.readiness == "stale"'
unset SITE_TEST_FAILURE
[[ "$(sort -u "$SITE_TEST_CALLS")" == 'secret inventory' ]] || {
	printf 'FAIL a non-metadata command was attempted\n' >&2
	exit 1
}
printf 'PASS only the names-only inventory command was used\n'
