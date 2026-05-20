#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# nostr-vpn-helper.sh — Read-only diagnostics and guidance for Nostr VPN/FIPS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

CONFIG_TEMPLATE="${SCRIPT_DIR}/../../configs/nostr-vpn-config.json.txt"

print_usage() {
	cat <<'USAGE'
Usage: nostr-vpn-helper.sh <command>

Commands:
  check            Check local FIPS/Nostr VPN tooling availability
  status           Show FIPS status when fipsctl is installed
  identity         Show public identity information when available
  peers            Show peer information when available
  firewall-status  Show fips0 firewall/service status hints
  diagnostics      Run non-destructive local diagnostics
  secrets-help     Show aidevops secret setup guidance
  opencode-guide   Show secure OpenCode remote compute guidance
  help             Show this help
USAGE
	return 0
}

has_command() {
	local command_name="$1"
	if command -v "$command_name" >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

run_fipsctl() {
	local subcommand="$1"
	shift || true

	if ! has_command fipsctl; then
		printf 'fipsctl not found. Install FIPS first and verify upstream checksums.\n' >&2
		return 1
	fi

	fipsctl "$subcommand" "$@"
	return 0
}

check_tools() {
	local missing=0
	local tool

	for tool in fips fipsctl; do
		if has_command "$tool"; then
			printf 'OK: %s found at %s\n' "$tool" "$(command -v "$tool")"
		else
			printf 'MISSING: %s\n' "$tool"
			missing=1
		fi
	done

	for tool in fipstop fips-gateway jq systemctl launchctl; do
		if has_command "$tool"; then
			printf 'OPTIONAL: %s found at %s\n' "$tool" "$(command -v "$tool")"
		fi
	done

	if [[ -r "$CONFIG_TEMPLATE" ]]; then
		printf 'OK: config template exists: %s\n' "$CONFIG_TEMPLATE"
	else
		printf 'WARN: config template missing: %s\n' "$CONFIG_TEMPLATE"
	fi

	return "$missing"
}

show_status() {
	if run_fipsctl show status; then
		return 0
	fi

	printf 'No FIPS status available. Try upstream command: fipsctl show status\n'
	return 1
}

show_identity() {
	if run_fipsctl show identity-cache; then
		return 0
	fi

	printf 'Identity cache command unavailable or changed upstream. Inspect: fipsctl show --help\n'
	return 1
}

show_peers() {
	if run_fipsctl show peers; then
		return 0
	fi

	printf 'Peer command unavailable or changed upstream. Inspect: fipsctl show --help\n'
	return 1
}

show_firewall_status() {
	if has_command systemctl; then
		systemctl status fips-firewall --no-pager || true
	fi

	if has_command launchctl; then
		launchctl print system 2>/dev/null | grep -F 'fips' || true
	fi

	printf '\nSecurity baseline: enable upstream fips0 firewall rules before exposing SSH, OpenCode, dashboards, LAN gateway, or exit-node paths.\n'
	return 0
}

run_diagnostics() {
	printf 'Nostr VPN/FIPS diagnostics (read-only)\n'
	printf '=====================================\n'
	check_tools || true
	printf '\nStatus:\n'
	show_status || true
	printf '\nPeers:\n'
	show_peers || true
	printf '\nFirewall:\n'
	show_firewall_status || true
	printf '\nSecret hygiene:\n'
	show_secrets_help
	return 0
}

show_secrets_help() {
	cat <<'SECRETS'
WARNING: Never paste secret values into AI chat.

Use aidevops secret storage for sensitive values:
  aidevops secret set FIPS_NSEC
  aidevops secret set OPENCODE_SERVER_TOKEN

Guidance:
  - Prefer one fresh Nostr/FIPS identity per device.
  - Use FIPS_NSEC only for import/recovery; never commit nsec values or key files.
  - Pass secrets via environment or aidevops secret execution context, not CLI arguments.
  - Keep key files owner-only (0600) and outside repositories.
SECRETS
	return 0
}

show_opencode_guide() {
	cat <<'GUIDE'
Secure OpenCode remote compute over Nostr VPN/FIPS:
  1. Start FIPS and verify the client can reach the compute node over .fips/IPv6.
  2. Bind OpenCode server to loopback or the FIPS interface only, never a public interface.
  3. Store auth with: aidevops secret set OPENCODE_SERVER_TOKEN
  4. Allow only the client npub in FIPS peer ACLs and fips0 firewall rules.
  5. Test SSH first, then test an authenticated OpenCode request over the mesh.
  6. Disable LAN gateway and exit-node modes unless the trust boundary is reviewed.
GUIDE
	return 0
}

main() {
	local command_name="${1:-help}"
	shift || true

	case "$command_name" in
	check)
		check_tools "$@"
		return $?
		;;
	status)
		show_status "$@"
		return $?
		;;
	identity)
		show_identity "$@"
		return $?
		;;
	peers)
		show_peers "$@"
		return $?
		;;
	firewall-status)
		show_firewall_status "$@"
		return $?
		;;
	diagnostics)
		run_diagnostics "$@"
		return $?
		;;
	secrets-help)
		show_secrets_help "$@"
		return $?
		;;
	opencode-guide)
		show_opencode_guide "$@"
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		printf 'Unknown command: %s\n\n' "$command_name" >&2
		print_usage >&2
		return 1
		;;
	esac
}

main "$@"
