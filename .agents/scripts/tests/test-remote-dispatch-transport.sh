#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for mesh transport detection in remote-dispatch-helper.sh
# (GH#32583): NetBird and Tailscale share 100.64.0.0/10, so a bare 100.x
# address must not be assumed to be Tailscale.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/remote-dispatch-helper.sh"
TEST_ROOT=""
FAILED=0

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

write_stub() {
	local name="$1"
	local output="$2"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$output" >"${TEST_ROOT}/bin/${name}"
	chmod +x "${TEST_ROOT}/bin/${name}"
	return 0
}

# Add a host via the real CLI and print the stored transport.
added_transport() {
	local name="$1"
	shift
	PATH="${TEST_ROOT}/bin:${PATH}" REMOTE_DISPATCH_HOSTS_FILE="${TEST_ROOT}/hosts.json" \
		bash "$HELPER" add "$name" "$@" >/dev/null 2>&1 || {
		printf 'rejected\n'
		return 0
	}
	jq -r --arg n "$name" '.hosts[$n].transport' "${TEST_ROOT}/hosts.json"
	return 0
}

expect() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf '  PASS %s\n' "$label"
		return 0
	fi
	printf '  FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
	FAILED=1
	return 0
}

main() {
	trap cleanup EXIT
	TEST_ROOT="$(mktemp -d)"
	mkdir -p "${TEST_ROOT}/bin"
	write_stub tailscale "100.101.1.2  build-node  user@  linux  -"
	write_stub netbird "  NetBird IP: 100.75.13.55"

	expect "NetBird 100.x peer is not misclassified as Tailscale" netbird "$(added_transport nb 100.75.13.55)"
	expect "100.x listed by tailscale status is Tailscale" tailscale "$(added_transport ts 100.101.1.2)"
	expect "unknown 100.x falls back to plain SSH" ssh "$(added_transport unknown 100.75.9.9)"
	expect ".nvpn name is Nostr VPN" nvpn "$(added_transport nv user@mini.nvpn)"
	expect ".ts.net name is Tailscale" tailscale "$(added_transport tsn build.tailnet.ts.net)"
	expect ".netbird.selfhosted name is NetBird" netbird "$(added_transport nbn peer.netbird.selfhosted)"
	expect "explicit wireguard transport accepted" wireguard "$(added_transport wg 10.8.0.2 --transport wireguard)"
	expect "invalid transport rejected" rejected "$(added_transport bad 10.8.0.3 --transport bogus)"

	if [[ "$FAILED" -ne 0 ]]; then
		return 1
	fi
	printf 'All transport tests passed\n'
	return 0
}

main "$@"
