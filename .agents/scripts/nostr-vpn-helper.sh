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
  macos-source     Show macOS package verification and source fallback guidance
  safe-posture     Show safe install, disable, and re-enable guidance
  privacy-guide    Show privacy/anonymity best-practice guidance
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
	return $?
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

	# shell-portability: ignore next - this is a read-only optional tool-name list, not invocation.
	for tool in fipstop fips-gateway jq systemctl launchctl git cargo pkgbuild xcode-select; do
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
		systemctl status fips-firewall --no-pager 2>/dev/null || true
	fi

	if [[ "$(uname -s)" == "Darwin" ]] && has_command launchctl; then
		# shell-portability: ignore next - launchctl is only used inside the Darwin branch.
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

show_safe_posture_guide() {
	cat <<'GUIDE'
Safe FIPS/Nostr VPN local posture:
  - A successful macOS package install creates a root LaunchDaemon and may start FIPS immediately.
  - Initial installs can listen on 0.0.0.0:2121/udp and 0.0.0.0:8443/tcp with ACL default-open.
  - With no trusted second node ready, stop and disable the daemon after install validation.

Check current state:
  fipsctl show status
  fipsctl acl show
  # shell-portability: ignore next - printed macOS-only operator guidance.
  launchctl print system/com.fips.daemon
  netstat -an -p tcp | rg '(:8443|\.8443)' || true
  netstat -an -p udp | rg '(:2121|\.2121)' || true

Disable until ready to pair trusted peers:
  # shell-portability: ignore next - printed macOS-only operator guidance.
  sudo launchctl bootout system /Library/LaunchDaemons/com.fips.daemon.plist
  # shell-portability: ignore next - printed macOS-only operator guidance.
  sudo launchctl disable system/com.fips.daemon

Expected disabled check:
  # shell-portability: ignore next - printed macOS-only operator guidance.
  launchctl print system/com.fips.daemon
  # Bad request. Could not find service "com.fips.daemon" in domain for system

Re-enable only when ready to test with an allowlisted peer:
  # shell-portability: ignore next - printed macOS-only operator guidance.
  sudo launchctl enable system/com.fips.daemon
  # shell-portability: ignore next - printed macOS-only operator guidance.
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.fips.daemon.plist

Do not expose SSH, OpenCode, dashboards, or gateway/exit-node modes until peer ACLs are explicit and default-open behavior is reviewed.
GUIDE
	return 0
}

show_privacy_guide() {
	cat <<'GUIDE'
FIPS/Nostr VPN privacy guidance:
  - Treat FIPS as a private self-sovereign mesh, not as an anonymity network.
  - Use fresh per-device Nostr/FIPS identities; never reuse a public/social npub.
  - Separate identities by purpose: personal devices, experiments, client/work, travel, and high-risk research.
  - Prefer self-hosted or trusted private Nostr relays; public relays may observe discovery metadata.
  - Keep peer ACLs explicit and default-deny; do not expose services while ACL state is default-open.
  - Disable LAN gateway, exit-node, and broad service exposure unless the trust boundary is documented.
  - Bind SSH, OpenCode, MCP servers, and dashboards to loopback or the FIPS interface only.
  - Keep the daemon disabled when no trusted peer is ready; enable only for an intentional test window.
  - Rotate identities after suspected compromise and remove stale peers from ACLs, known-hosts, and local host maps.
  - Do not paste nsec/private keys into chat; store recovery material only with aidevops secret storage.

Companion privacy tooling:
  - Network privacy: use a reputable no-logs VPN or Tor where the threat model requires IP hiding.
  - Relay privacy: self-host relays where possible; otherwise assume relay IP/timing metadata exists.
  - Communications: use SimpleX or Signal for human messages when metadata minimisation matters more than mesh networking.
  - Browser isolation: use separate browser profiles, CamoFox, or hardened Firefox/Arkenfox for web identity separation.
  - Device hygiene: FileVault/LUKS/BitLocker, strong passphrases, YubiKey-backed SSH/FIDO2, and EXIF stripping.

Hard limit:
  - Full privacy and anonymity cannot be guaranteed by FIPS alone. IP addresses, relay timing,
    traffic correlation, device fingerprints, writing style, and compromised endpoints can still identify users.
GUIDE
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

show_macos_source_guide() {
	cat <<'GUIDE'
macOS package verification for FIPS v0.4.0-rc1 and later:
  1. Download the package for this Mac's architecture and checksums-macos.txt.
  2. Verify the package hash before any install:
       shasum -a 256 fips-0.4.0-rc1-macos-$(uname -m).pkg
  3. Confirm the hash matches the architecture line in checksums-macos.txt.
  4. Run structural checks before installing:
       pkgutil --check-signature fips-0.4.0-rc1-macos-$(uname -m).pkg
       pkgutil --payload-files fips-0.4.0-rc1-macos-$(uname -m).pkg
       pkgutil --expand fips-0.4.0-rc1-macos-$(uname -m).pkg /tmp/fips-pkg-expanded
       xar -tf fips-0.4.0-rc1-macos-$(uname -m).pkg
  5. Install only after hash and structural checks pass:
       sudo installer -pkg fips-0.4.0-rc1-macos-$(uname -m).pkg -target /

Source-build fallback if release packages are unavailable or fail integrity:
  1. Install prerequisites outside AI chat:
       - Rust toolchain from https://rustup.rs
       - Xcode command line tools: xcode-select --install
  2. Clone upstream source in a temporary working directory:
       git clone https://github.com/jmcorgan/fips.git
       cd fips
       git checkout v0.4.0-rc1
  3. Build the macOS package for the local architecture:
       ./packaging/macos/build-pkg.sh
  4. Verify the generated package before installing:
       pkgutil --check-signature deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg
       pkgutil --payload-files deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg
       pkgutil --expand deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg /tmp/fips-source-pkg-expanded
  5. Install only after package integrity checks pass:
       sudo installer -pkg deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg -target /

Do not paste nsec/private keys into chat. Store recovery material with:
  aidevops secret set FIPS_NSEC
GUIDE
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

Useful aidevops service candidates after SSH is proven:
  - OpenCode remote server for heavier local or workstation compute.
  - Git operations and repo maintenance over private SSH between devices.
  - Self-hosted dashboards or MCP services bound to loopback/FIPS only.
  - Homelab storage, GPU workers, or staging services without public ports.
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
	macos-source)
		show_macos_source_guide "$@"
		return $?
		;;
	safe-posture)
		show_safe_posture_guide "$@"
		return $?
		;;
	privacy-guide)
		show_privacy_guide "$@"
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
