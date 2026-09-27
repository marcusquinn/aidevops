#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# nostr-vpn-setup-lib.sh — Nostr VPN (nvpn) enrollment, alias, DNS and direct-only
# commands for nostr-vpn-helper.sh (GH#32583). Sourced, not executed.
#
# Validated against nvpn 4.1.16 on two macOS arm64 devices alongside NetBird:
# - The first device creates a network with `nvpn set --device <own npub>`.
# - Joiners use `nvpn join-manual`; the admin approves with `add-device --publish`.
# - MagicDNS (.nvpn) only serves aliased devices; the CLI has no alias command and
#   alias-only roster changes did not propagate, so aliases are written per device
#   to [peer_aliases] in config.toml (mmalmi/nostr-vpn#71).
# - Endpoint hints reject CGNAT (100.64.0.0/10) and the daemon pins its underlay
#   to the physical interface, so nvpn cannot run over NetBird/Tailscale links.

NVPN_DEFAULT_PORT="${NVPN_DEFAULT_PORT:-51821}"
NVPN_MAGIC_DNS_PORT="${NVPN_MAGIC_DNS_PORT:-1053}"
NVPN_NPUB_REGEX='^npub1[02-9ac-hj-np-z]{58}$'
NVPN_ALIAS_SECTION="[peer_aliases]"

is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
	return $?
}

# Print the nvpn CLI to drive (PATH CLI, else the app helper), or fail.
nvpn_cli_required() {
	local cli=""
	cli="$(resolve_nvpn_cli)" || cli=""
	if [[ -z "$cli" && -x "$NVPN_APP_HELPER" ]]; then
		cli="$NVPN_APP_HELPER"
	fi
	if [[ -z "$cli" ]]; then
		printf 'nvpn not found. Install Nostr VPN from https://nostrvpn.org/ then run: nostr-vpn-helper.sh update\n' >&2
		return 1
	fi
	printf '%s\n' "$cli"
	return 0
}

# Same path rules as nvpn: NVPN_CONFIG_PATH, else <config dir>/nvpn/config.toml.
nvpn_config_path() {
	if [[ -n "${NVPN_CONFIG_PATH:-}" ]]; then
		printf '%s\n' "$NVPN_CONFIG_PATH"
		return 0
	fi
	if is_macos; then
		printf '%s\n' "${HOME}/Library/Application Support/nvpn/config.toml"
		return 0
	fi
	printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/nvpn/config.toml"
	return 0
}

validate_npub() {
	local npub="$1"
	if [[ "$npub" =~ $NVPN_NPUB_REGEX ]]; then
		return 0
	fi
	printf 'Invalid npub: %s (expected npub1 followed by 58 bech32 characters)\n' "$npub" >&2
	return 1
}

# Normalise like nvpn: lowercase, non [a-z0-9] runs become '-', trimmed, <=63 chars.
normalize_alias() {
	local raw="$1"
	local alias=""
	alias="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')"
	alias="${alias#-}"
	alias="${alias%-}"
	alias="${alias:0:63}"
	alias="${alias%-}"
	if [[ -z "$alias" ]]; then
		printf 'Alias "%s" has no usable characters (use letters, digits, hyphens)\n' "$raw" >&2
		return 1
	fi
	printf '%s\n' "$alias"
	return 0
}

# Read `device_id=npub…` (own npub) or `network: <id>` from nvpn status.
nvpn_own_npub() {
	local cli="$1"
	local line=""
	while IFS= read -r line; do
		if [[ "$line" == device_id=npub1* ]]; then
			printf '%s\n' "${line#device_id=}"
			return 0
		fi
	done <<<"$("$cli" status 2>/dev/null || true)"
	return 1
}

nvpn_network_id() {
	local cli="$1"
	local value=""
	value="$(nvpn_status_field "$("$cli" status 2>/dev/null || true)" network)" || return 1
	[[ -n "$value" ]] || return 1
	printf '%s\n' "$value"
	return 0
}

# Primary LAN IPv4 of the default-route interface (physical underlay for nvpn).
primary_lan_ipv4() {
	local iface=""
	local ip=""
	if is_macos; then
		iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
		[[ -n "$iface" ]] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
	elif has_command ip; then
		ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
	fi
	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
	return 0
}

# Pick a listen port that avoids NetBird/WireGuard's default 51820.
choose_listen_port() {
	local port="$NVPN_DEFAULT_PORT"
	local netbird_port=""
	if has_command netbird; then
		netbird_port="$(nvpn_status_field "$(netbird status 2>/dev/null || true)" "Wireguard port")" || netbird_port=""
	fi
	if [[ "$port" == "$netbird_port" ]]; then
		port=$((port + 1))
	fi
	printf '%s\n' "$port"
	return 0
}

# Set a non-clashing listen port and a LAN endpoint that peers can dial.
nvpn_prepare_node() {
	local cli="$1"
	local port=""
	local ip=""
	local -a args=()
	port="$(choose_listen_port)"
	args=(set --listen-port "$port")
	if ip="$(primary_lan_ipv4)"; then
		args+=(--endpoint "${ip}:${port}")
	else
		printf 'WARN: could not detect a LAN IPv4; set it later: nvpn set --endpoint <ip>:%s\n' "$port"
	fi
	"$cli" "${args[@]}" >/dev/null
	printf 'OK: nvpn listens on UDP %s%s\n' "$port" "${ip:+, endpoint ${ip}:${port}}"
	return 0
}

# Insert or replace `<npub> = "<alias>"` under [peer_aliases]; keeps a .bak-aidevops copy.
write_peer_alias() {
	local config="$1"
	local npub="$2"
	local alias="$3"
	local tmp=""
	if [[ ! -f "$config" ]]; then
		printf 'nvpn config not found: %s (set NVPN_CONFIG_PATH)\n' "$config" >&2
		return 1
	fi
	tmp="$(mktemp "${config}.XXXXXX")" || return 1
	if ! awk -v key="$npub" -v line="${npub} = \"${alias}\"" -v section="$NVPN_ALIAS_SECTION" '
		/^\[/ { insec = ($0 == section); print; if (insec) { print line; done = 1 }; next }
		insec && index($0, key) == 1 && substr($0, length(key) + 1, 1) ~ /[ =]/ { next }
		{ print }
		END { if (!done) { print ""; print section; print line } }
	' "$config" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	chmod 600 "$tmp"
	cp -p "$config" "${config}.bak-aidevops"
	mv "$tmp" "$config"
	return 0
}

cmd_set_alias() {
	local target="${1:-}"
	local raw_alias="${2:-}"
	local cli=""
	local npub=""
	local alias=""
	if [[ -z "$target" || -z "$raw_alias" ]]; then
		printf 'Usage: nostr-vpn-helper.sh set-alias <npub|self> <alias>\n' >&2
		return 1
	fi
	cli="$(nvpn_cli_required)" || return 1
	if [[ "$target" == "self" ]]; then
		npub="$(nvpn_own_npub "$cli")" || {
			printf 'Could not read own device_id from: nvpn status\n' >&2
			return 1
		}
	else
		npub="$target"
	fi
	validate_npub "$npub" || return 1
	alias="$(normalize_alias "$raw_alias")" || return 1
	write_peer_alias "$(nvpn_config_path)" "$npub" "$alias" || return 1
	"$cli" reload >/dev/null 2>&1 || printf 'WARN: nvpn reload failed; run: nvpn reload\n'
	printf 'OK: %s.nvpn -> %s\n' "$alias" "$npub"
	return 0
}

# Print aliases plus the commands that reproduce them on another device.
cmd_aliases() {
	local config=""
	local line=""
	local insec=0
	config="$(nvpn_config_path)"
	[[ -f "$config" ]] || {
		printf 'nvpn config not found: %s\n' "$config" >&2
		return 1
	}
	printf '# Run on every other device so each resolves all <alias>.nvpn names:\n'
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == \[* ]]; then
			insec=0
			[[ "$line" == "$NVPN_ALIAS_SECTION" ]] && insec=1
			continue
		fi
		if ((insec)) && [[ "$line" =~ ^(npub1[a-z0-9]+)[[:space:]]*=[[:space:]]*\"([a-z0-9-]+)\" ]]; then
			printf 'nostr-vpn-helper.sh set-alias %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		fi
	done <"$config"
	return 0
}

cmd_setup_admin() {
	local raw_alias="${1:-$(hostname -s 2>/dev/null || hostname)}"
	local cli=""
	local npub=""
	local network=""
	cli="$(nvpn_cli_required)" || return 1
	npub="$(nvpn_own_npub "$cli")" || {
		printf 'Could not read own device_id; is the nvpn daemon running? (nvpn status)\n' >&2
		return 1
	}
	nvpn_prepare_node "$cli"
	if network="$(nvpn_network_id "$cli")"; then
		printf 'OK: already in network %s (not creating a new one)\n' "$network"
	else
		"$cli" set --device "$npub" >/dev/null
		network="$(nvpn_network_id "$cli")" || {
			printf 'Network was not created; check: nvpn status\n' >&2
			return 1
		}
		printf 'OK: created network %s with this device as admin\n' "$network"
	fi
	cmd_set_alias self "$raw_alias" || return 1
	printf '\nOn each device to add, run:\n  nostr-vpn-helper.sh join %s %s <that-device-alias> --admin-alias %s\n' \
		"$npub" "$network" "$(normalize_alias "$raw_alias")"
	return 0
}

cmd_join() {
	local admin_npub="${1:-}"
	local network="${2:-}"
	local raw_alias=""
	local admin_alias="admin"
	local cli=""
	local npub=""
	shift 2 2>/dev/null || shift $#
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--admin-alias)
			admin_alias="${2:-admin}"
			shift 2 2>/dev/null || shift $#
			;;
		*)
			raw_alias="$1"
			shift
			;;
		esac
	done
	raw_alias="${raw_alias:-$(hostname -s 2>/dev/null || hostname)}"
	if [[ -z "$admin_npub" || -z "$network" ]]; then
		printf 'Usage: nostr-vpn-helper.sh join <admin-npub> <network-id> [alias] [--admin-alias name]\n' >&2
		return 1
	fi
	validate_npub "$admin_npub" || return 1
	cli="$(nvpn_cli_required)" || return 1
	nvpn_prepare_node "$cli"
	"$cli" join-manual --admin-device-id "$admin_npub" --network-id "$network" >/dev/null
	cmd_set_alias "$admin_npub" "$admin_alias" || return 1
	cmd_set_alias self "$raw_alias" || return 1
	npub="$(nvpn_own_npub "$cli")" || npub="<this device npub from nvpn status>"
	printf '\nOn the admin device, run:\n  nostr-vpn-helper.sh approve %s %s\n' "$npub" "$(normalize_alias "$raw_alias")"
	return 0
}

cmd_approve() {
	local npub="${1:-}"
	local raw_alias="${2:-}"
	local cli=""
	if [[ -z "$npub" || -z "$raw_alias" ]]; then
		printf 'Usage: nostr-vpn-helper.sh approve <device-npub> <alias>\n' >&2
		return 1
	fi
	validate_npub "$npub" || return 1
	cli="$(nvpn_cli_required)" || return 1
	"$cli" add-device --device "$npub" --publish >/dev/null
	cmd_set_alias "$npub" "$raw_alias" || return 1
	printf '\nApproved. For names on every device, run the output of this on each other device:\n  nostr-vpn-helper.sh aliases\n'
	printf 'Then check from here: nostr-vpn-helper.sh dns-check %s\n' "$(normalize_alias "$raw_alias")"
	return 0
}

# Verify MagicDNS in layers: daemon answer, OS resolver registration, system lookup.
cmd_dns_check() {
	local name="${1:-}"
	local fqdn=""
	local answer=""
	if [[ -z "$name" ]]; then
		printf 'Usage: nostr-vpn-helper.sh dns-check <alias>\n' >&2
		return 1
	fi
	fqdn="${name%.nvpn}.nvpn"
	if has_command dig; then
		answer="$(dig +short +time=2 +tries=1 @127.0.0.1 -p "$NVPN_MAGIC_DNS_PORT" "$fqdn" A 2>/dev/null || true)"
		if [[ -z "$answer" ]]; then
			printf 'FAIL 1/3 daemon has no record for %s. Set aliases (set-alias/aliases); daemon.log "magicdns: skipped" means none are set.\n' "$fqdn"
			return 1
		fi
		printf 'OK   1/3 daemon answers %s -> %s\n' "$fqdn" "$answer"
	fi
	if is_macos; then
		local resolvers=""
		# Capture first: grep -q closing the pipe early makes scutil SIGPIPE under pipefail.
		resolvers="$(scutil --dns 2>/dev/null || true)"
		if [[ ! "$resolvers" =~ domain[[:space:]]+:[[:space:]]+nvpn[[:space:]] ]]; then
			printf 'FAIL 2/3 macOS has not registered /etc/resolver/nvpn. mDNSResponder HUP does not help; cycle the default interface (e.g. networksetup -setairportpower en0 off; sleep 3; networksetup -setairportpower en0 on) or reboot.\n'
			return 1
		fi
		printf 'OK   2/3 macOS resolver registered for .nvpn\n'
		answer="$(dscacheutil -q host -a name "$fqdn" 2>/dev/null | awk '/ip_address/{print $2; exit}')"
	else
		# shell-portability: ignore next - Linux-only branch; macOS uses dscacheutil above.
		answer="$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1; exit}')"
	fi
	if [[ -z "$answer" ]]; then
		printf 'FAIL 3/3 system resolver cannot resolve %s\n' "$fqdn"
		return 1
	fi
	printf 'OK   3/3 system resolves %s -> %s\n' "$fqdn" "$answer"
	return 0
}

# Disable third-party bootstrap peers and Nostr relay discovery; dial only the
# given peer endpoints. `--off` restores upstream defaults.
cmd_direct_only() {
	local cli=""
	local spec=""
	local host=""
	local -a args=()
	cli="$(nvpn_cli_required)" || return 1
	if [[ "${1:-}" == "--off" ]]; then
		"$cli" set --fips-bootstrap-enabled true --fips-nostr-discovery-enabled true >/dev/null
		printf 'OK: bootstrap peers and Nostr discovery re-enabled (upstream defaults)\n'
		return 0
	fi
	if [[ $# -eq 0 ]]; then
		printf 'Usage: nostr-vpn-helper.sh direct-only <peer-npub>=<lan-or-public-host>[:port]... | --off\n' >&2
		return 1
	fi
	args=(set --fips-bootstrap-enabled false --fips-nostr-discovery-enabled false)
	for spec in "$@"; do
		validate_npub "${spec%%=*}" || return 1
		host="${spec#*=}"
		host="${host%:*}"
		if [[ "$host" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
			printf 'Rejected %s: nvpn refuses CGNAT (100.64.0.0/10) hints and cannot run over NetBird/Tailscale; use a LAN, public, or DNS address.\n' "$spec" >&2
			return 1
		fi
		args+=(--fips-peer-endpoint "$spec")
	done
	"$cli" "${args[@]}" >/dev/null
	printf 'OK: direct-only; no bootstrap peers or Nostr discovery. Peers connect only via the listed endpoints (and LAN mDNS if enabled).\n'
	printf 'Away from these networks the peers cannot find each other; revert with: nostr-vpn-helper.sh direct-only --off\n'
	return 0
}
