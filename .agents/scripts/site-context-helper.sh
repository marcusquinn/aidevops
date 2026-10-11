#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Read-only, privacy-safe local site/application inventory lookup.
set -euo pipefail

readonly INVENTORY_PATH="${AIDEVOPS_SITE_INVENTORY:-${HOME}/.config/aidevops/site-inventory.json}"

usage() {
	printf 'Usage: %s <lookup|readiness|discover|validate> [hostname]\n' "${0##*/}"
	return 0
}

require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		printf 'jq is required\n' >&2
		return 1
	fi
	return 0
}

require_inventory() {
	if [[ ! -f "$INVENTORY_PATH" ]]; then
		printf 'Site inventory not found: %s\n' "$INVENTORY_PATH" >&2
		return 1
	fi
	return 0
}

validate_inventory() {
	jq -e '
		def valid_metadata($accounts):
			(if has("ownership") then
				.ownership | type == "object"
				and (if has("type") then .type as $type | ["client", "former-client", "business", "personal", "partner", "community", "unknown"] | index($type) != null else true end)
				and (if has("confirmed") then .confirmed | type == "boolean" else true end)
			else true end)
			and (if (.dns // {} | has("account_ref")) then
				.dns.account_ref as $ref | ($ref | type == "string") and ($accounts | has($ref))
			else true end);
		(.dns_accounts // {}) as $accounts
		| (.version | type == "number") and (.sites | type == "object")
		and ($accounts | type == "object")
		and ([.sites[] | (.canonical_hostname | type == "string") and (.hosting | type == "object")
			and valid_metadata($accounts)
			and ([.children // {} | .[] | valid_metadata($accounts)] | all)] | all)
	' "$INVENTORY_PATH" >/dev/null
	return $?
}

lookup_record() {
	local hostname="$1"
	jq -ce --arg hostname "$hostname" '
		def selected: to_entries[] | select(.key == $hostname or .value.canonical_hostname == $hostname or (.value.aliases // [] | index($hostname)) or (.value.children // {} | to_entries[]? | select(.value.hostname == $hostname or (.value.aliases // [] | index($hostname)))));
		(.sites | selected) as $match
		| ([($match.value.children // {} | to_entries[]? | select(.value.hostname == $hostname or (.value.aliases // [] | index($hostname))) | .value)][0] // null) as $child
		| (.hosting_accounts[$match.value.hosting.account_ref] // {}) as $account
		| ($child.dns // $match.value.dns) as $dns
		| (if $dns.account_ref != null then $dns + {account:(.dns_accounts[$dns.account_ref] | {name, credential_env, account_id_env, last_verified})} else $dns end) as $resolved_dns
		| {status:"found", matched_hostname:$hostname, site_id:$match.key, name:$match.value.name, canonical_hostname:$match.value.canonical_hostname, platform:$match.value.platform, environment:$match.value.environment, dns:$resolved_dns, hosting:($match.value.hosting + {deployment_path:($child.deployment_path // $match.value.hosting.deployment_path), ssh_host:$account.ssh_host, ssh_port:$account.ssh_port, ssh_user:$account.ssh_user, credential_env:$account.credential_env, last_verified:$account.last_verified}), child:$child, provenance:$match.value.provenance, last_verified:$match.value.last_verified}
		+ (if ($child.purpose // $match.value.purpose) != null then {purpose:($child.purpose // $match.value.purpose)} else {} end)
		+ (if ($child.ownership // $match.value.ownership) != null then {ownership:($child.ownership // $match.value.ownership)} else {} end)
	' "$INVENTORY_PATH"
	return $?
}

readiness() {
	local hostname="$1"
	local record
	if ! record=$(lookup_record "$hostname" 2>/dev/null); then
		jq -cn --arg hostname "$hostname" '{status:"gap", hostname:$hostname, reason:"no local inventory record", discovery:"not_configured"}'
		return 0
	fi
	printf '%s\n' "$record" | jq -c 'def missing: . == null or . == ""; if (.last_verified | missing) or (.hosting.last_verified | missing) then . + {readiness:"stale", reason:"inventory or account freshness is absent"} elif (.hosting.ssh_host | missing) or (.hosting.ssh_user | missing) then . + {readiness:"gap", reason:"SSH connection metadata is incomplete"} else . + {readiness:"ready"} end'
	return $?
}

main() {
	local command="${1:-}"
	local hostname="${2:-}"
	require_jq
	case "$command" in
	validate) require_inventory && validate_inventory && printf 'Site inventory is valid\n' ;;
	lookup)
		[[ -n "$hostname" ]] || {
			usage >&2
			return 2
		}
		require_inventory && lookup_record "$hostname"
		;;
	readiness)
		[[ -n "$hostname" ]] || {
			usage >&2
			return 2
		}
		[[ -f "$INVENTORY_PATH" ]] && readiness "$hostname" || jq -cn --arg hostname "$hostname" '{status:"gap", hostname:$hostname, reason:"site inventory is absent", discovery:"not_configured"}'
		;;
	discover)
		[[ -n "$hostname" ]] || {
			usage >&2
			return 2
		}
		readiness "$hostname" | jq -c '. + {discovery:"read_only_local"}'
		;;
	*)
		usage >&2
		return 2
		;;
	esac
	local command_status=$?
	if [[ "$command_status" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
