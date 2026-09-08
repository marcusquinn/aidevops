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
	jq -e '(.version | type == "number") and (.sites | type == "object") and ([.sites[] | (.canonical_hostname | type == "string") and (.hosting | type == "object")] | all)' "$INVENTORY_PATH" >/dev/null
	return $?
}

lookup_record() {
	local hostname="$1"
	jq -ce --arg hostname "$hostname" '
		def selected: to_entries[] | select(.key == $hostname or .value.canonical_hostname == $hostname or (.value.aliases // [] | index($hostname)) or (.value.children // {} | to_entries[]? | select(.value.hostname == $hostname)));
		(.sites | selected) as $match
		| ([($match.value.children // {} | to_entries[]? | select(.value.hostname == $hostname) | .value)][0] // null) as $child
		| (.hosting_accounts[$match.value.hosting.account_ref] // {}) as $account
		| {status:"found", matched_hostname:$hostname, site_id:$match.key, name:$match.value.name, canonical_hostname:$match.value.canonical_hostname, platform:$match.value.platform, environment:$match.value.environment, dns:$match.value.dns, hosting:($match.value.hosting + {deployment_path:($child.deployment_path // $match.value.hosting.deployment_path), ssh_host:$account.ssh_host, ssh_port:$account.ssh_port, ssh_user:$account.ssh_user, credential_env:$account.credential_env, last_verified:$account.last_verified}), child:$child, provenance:$match.value.provenance, last_verified:$match.value.last_verified}
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
