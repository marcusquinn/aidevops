#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Read-only, privacy-safe local site/application inventory lookup.
set -euo pipefail

readonly INVENTORY_PATH="${AIDEVOPS_SITE_INVENTORY:-${HOME}/.config/aidevops/site-inventory.json}"
readonly CREDENTIAL_REGISTRY_PATH="${AIDEVOPS_CREDENTIAL_INVENTORY:-${HOME}/.config/aidevops/credential-inventory.json}"

# Keep reference syntax and ambiguity checks identical in validation/readiness.
# shellcheck disable=SC2016 # jq variables must remain literal shell text.
readonly SSH_REFERENCE_JQ='
	def is_string: type == "string";
	def secret_name: is_string and test("^[A-Z][A-Z0-9_]*$");
	def ssh_ref_keys: ["ssh_host_env", "ssh_port_env", "ssh_user_env"];
	def ssh_refs: [ssh_ref_keys[] as $key | .[$key] | select(. != null)];
	def valid_ssh_refs:
		. as $account | all(ssh_ref_keys[];
			. as $key | if ($account | has($key)) then
				($account[$key] | secret_name) and
				(($account[$key | rtrimstr("_env")] // "") == "")
			else true end);
'

# Non-secret account view from the credential registry (GH#34722), keyed by
# account ref; used only for dns.account_ref values absent from dns_accounts.
# Prints {} when the registry is absent or unreadable.
registry_accounts() {
	local path="${CREDENTIAL_REGISTRY_PATH/#\~/$HOME}"
	if [[ ! -f "$path" ]]; then
		printf '{}\n'
		return 0
	fi
	jq -c '
		(.credentials // {}) as $creds | (.defaults // {}) as $defaults
		| (.provider_accounts // {}) | with_entries(.key as $ref | .value |= (
			. as $account
			| [$creds | to_entries[] | select(.value.account_ref == $ref) | .key] as $own
			| ($defaults[$account.provider] // null) as $default
			| {name, account_id_env, provider, source:"credential-registry", credentials:$own,
				credential_env:(if ($own | length) == 1 then $own[0] elif ($default != null and ($own | index($default)) != null) then $default else null end),
				last_verified:([$creds[$own[]].verification.verified_at // empty] | max)}))
	' "$path" 2>/dev/null || printf '{}\n'
	return 0
}

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
	local registry
	registry=$(registry_accounts)
	jq -e --argjson registry "$registry" "${SSH_REFERENCE_JQ}"'
		def valid_metadata($accounts):
			(if has("ownership") then
				.ownership | type == "object"
				and (if has("type") then .type as $type | ["client", "former-client", "business", "personal", "partner", "community", "unknown"] | index($type) != null else true end)
				and (if has("confirmed") then .confirmed | type == "boolean" else true end)
			else true end)
			and (if (.dns // {} | has("account_ref")) then
				.dns.account_ref as $ref | ($ref | is_string) and (($accounts | has($ref)) or ($registry | has($ref)))
			else true end);
		(.dns_accounts // {}) as $accounts
		| (.hosting_accounts // {}) as $hosting
		| (.version | type == "number") and (.sites | type == "object")
		and ($accounts | type == "object")
		and ($hosting | type == "object")
		and ([$hosting[] | type == "object" and valid_ssh_refs] | all)
		and ([.sites[] | (.canonical_hostname | is_string) and (.hosting | type == "object")
			and valid_metadata($accounts)
			and ([.children // {} | .[] | valid_metadata($accounts)] | all)] | all)
	' "$INVENTORY_PATH" >/dev/null
	return $?
}

lookup_record() {
	local hostname="$1"
	local registry
	registry=$(registry_accounts)
	jq -ce --arg hostname "$hostname" --argjson registry "$registry" "${SSH_REFERENCE_JQ}"'
		def selected: to_entries[] | select(.key == $hostname or .value.canonical_hostname == $hostname or (.value.aliases // [] | index($hostname)) or (.value.children // {} | to_entries[]? | select(.value.hostname == $hostname or (.value.aliases // [] | index($hostname)))));
		(.sites | selected) as $match
		| ([($match.value.children // {} | to_entries[]? | select(.value.hostname == $hostname or (.value.aliases // [] | index($hostname))) | .value)][0] // null) as $child
		| (.hosting_accounts[$match.value.hosting.account_ref] // {}) as $account
		| ($child.dns // $match.value.dns) as $dns
		| (if $dns.account_ref == null then $dns
			elif (.dns_accounts // {} | has($dns.account_ref)) then $dns + {account:(.dns_accounts[$dns.account_ref] | {name, credential_env, account_id_env, last_verified})}
			else $dns + {account:($registry[$dns.account_ref] // null)} end) as $resolved_dns
		| ($account | with_entries(.key as $key | select(ssh_ref_keys | index($key)))) as $refs
		| {status:"found", matched_hostname:$hostname, site_id:$match.key, name:$match.value.name, canonical_hostname:$match.value.canonical_hostname, platform:$match.value.platform, environment:$match.value.environment, dns:$resolved_dns, hosting:($match.value.hosting + {deployment_path:($child.deployment_path // $match.value.hosting.deployment_path), ssh_host:$account.ssh_host, ssh_port:$account.ssh_port, ssh_user:$account.ssh_user, credential_env:$account.credential_env, last_verified:$account.last_verified} + $refs), child:$child, provenance:$match.value.provenance, last_verified:$match.value.last_verified}
		+ (if ($child.purpose // $match.value.purpose) != null then {purpose:($child.purpose // $match.value.purpose)} else {} end)
		+ (if ($child.ownership // $match.value.ownership) != null then {ownership:($child.ownership // $match.value.ownership)} else {} end)
	' "$INVENTORY_PATH"
	return $?
}

# Inspect only the existing names-only secret inventory. Never retrieve values,
# inject credentials, print backend diagnostics, or contact a hosted service.
ssh_reference_readiness() {
	local record="$1" inventory="" reason=""
	if ! inventory=$(aidevops secret inventory 2>/dev/null) ||
		! jq -e "${SSH_REFERENCE_JQ}"'
			.version == 1 and (.backends | type == "object") and
			([.backends[]] | all(. == "available" or . == "missing") and any(. == "available")) and
			(.secrets | type == "array") and
			all(.secrets[]; (.name | secret_name) and .status == "configured")
		' <<<"$inventory" >/dev/null 2>&1; then
		reason="SSH secret-name inventory is unavailable or invalid"
	elif ! jq -e --argjson record "$record" "${SSH_REFERENCE_JQ}"'
		[.secrets[].name] as $names |
		all($record.hosting | ssh_refs[]; . as $name | ($names | index($name)) != null)
	' <<<"$inventory" >/dev/null 2>&1; then
		reason="SSH connection secret references are not configured"
	fi
	if [[ -n "$reason" ]]; then
		jq -c --arg reason "$reason" '. + {readiness:"gap", reason:$reason}' <<<"$record" || return 1
	else
		printf '%s\n' "$record"
	fi
	return 0
}

readiness() {
	local hostname="$1"
	local record
	if ! record=$(lookup_record "$hostname" 2>/dev/null); then
		jq -cn --arg hostname "$hostname" '{status:"gap", hostname:$hostname, reason:"no local inventory record", discovery:"not_configured"}'
		return 0
	fi
	record=$(jq -c "${SSH_REFERENCE_JQ}"'
		def missing: . == null or . == "";
		. + {readiness_scope:"configuration_only"} |
		if (.last_verified | missing) or (.hosting.last_verified | missing) then
			. + {readiness:"stale", reason:"inventory or account freshness is absent"}
		elif (.hosting | valid_ssh_refs | not) then
			. + {readiness:"gap", reason:"SSH secret references are invalid or ambiguous"}
		elif ((.hosting.ssh_host | missing) and (.hosting.ssh_host_env | missing)) or
			((.hosting.ssh_user | missing) and (.hosting.ssh_user_env | missing)) then
			. + {readiness:"gap", reason:"SSH connection metadata is incomplete"}
		else . + {readiness:"ready"} end
	' <<<"$record") || return 1
	if jq -e "${SSH_REFERENCE_JQ}"'.readiness == "ready" and (.hosting | ssh_refs | length > 0)' \
		<<<"$record" >/dev/null; then
		ssh_reference_readiness "$record" || return 1
	else
		printf '%s\n' "$record"
	fi
	return 0
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
