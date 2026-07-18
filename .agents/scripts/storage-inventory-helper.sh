#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "$SCRIPT_DIR/shared-constants.sh"
fi

STORAGE_SCHEMA_VERSION=1
STORAGE_SIZE_TIMEOUT_TENTHS="${AIDEVOPS_STORAGE_SIZE_TIMEOUT_TENTHS:-20}"
STORAGE_DU_COMMAND="${AIDEVOPS_STORAGE_DU_COMMAND:-du}"
STORAGE_JSON_NULL="null"
STORAGE_OWNER_FRAMEWORK="framework"

_storage_usage() {
	cat <<'USAGE'
Usage: storage-inventory-helper.sh [status|json|help]

Read-only inventory of explicitly registered aidevops-related stores.
It never deletes data and reports unavailable classifications as unknown.
USAGE
	return 0
}

_storage_measure_path() {
	local path="$1"
	local output_file=""
	local pid=""
	local elapsed=0
	local kib=""
	local ignored=""

	if [[ ! -e "$path" && ! -L "$path" ]]; then
		printf '0|exact|missing'
		return 0
	fi
	if [[ -L "$path" ]]; then
		printf 'null|unavailable|root-is-symlink'
		return 0
	fi
	if [[ ! -r "$path" ]]; then
		printf 'null|unavailable|root-is-unreadable'
		return 0
	fi
	if ! command -v "$STORAGE_DU_COMMAND" >/dev/null 2>&1; then
		printf 'null|unavailable|sizing-command-unavailable'
		return 0
	fi

	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-storage-size.XXXXXX") || {
		printf 'null|unavailable|temporary-file-unavailable'
		return 0
	}
	LC_ALL=C "$STORAGE_DU_COMMAND" -sk "$path" >"$output_file" 2>/dev/null &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$STORAGE_SIZE_TIMEOUT_TENTHS" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file"
			printf 'null|unavailable|sizing-timeout'
			return 0
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	if ! wait "$pid"; then
		rm -f "$output_file"
		printf 'null|unavailable|sizing-failed'
		return 0
	fi
	IFS=$'\t ' read -r kib ignored <"$output_file" || kib=""
	rm -f "$output_file"
	case "$kib" in
	'' | *[!0-9]*) printf 'null|unavailable|invalid-size-output' ;;
	*) printf '%s|exact|' "$((kib * 1024))" ;;
	esac
	return 0
}

_storage_emit_record() {
	local store_id="$1"
	local producer="$2"
	local display_path="$3"
	local actual_path="$4"
	local owner="$5"
	local safety_class="$6"
	local policy="$7"
	local disposition="$8"
	local protection_reason="$9"
	local next_action="${10}"
	local measured=""
	local total_bytes="$STORAGE_JSON_NULL"
	local confidence="unavailable"
	local error=""
	local protected_bytes="$STORAGE_JSON_NULL"
	local reclaimable_bytes=0
	local unknown_bytes="$STORAGE_JSON_NULL"

	measured=$(_storage_measure_path "$actual_path")
	IFS='|' read -r total_bytes confidence error <<<"$measured"
	if [[ "$total_bytes" != "$STORAGE_JSON_NULL" ]]; then
		case "$disposition" in
		protected)
			protected_bytes="$total_bytes"
			unknown_bytes=0
			;;
		unknown)
			protected_bytes=0
			unknown_bytes="$total_bytes"
			;;
		*)
			protected_bytes=0
			unknown_bytes="$total_bytes"
			error="invalid-disposition"
			confidence="unavailable"
			;;
		esac
	fi

	jq -cn \
		--arg store_id "$store_id" \
		--arg producer "$producer" \
		--arg path "$display_path" \
		--arg owner "$owner" \
		--arg safety_class "$safety_class" \
		--arg policy "$policy" \
		--arg protection_reason "$protection_reason" \
		--arg confidence "$confidence" \
		--arg next_action "$next_action" \
		--arg error "$error" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson reclaimable_bytes "$reclaimable_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{store_id:$store_id,producer:$producer,path:$path,owner:$owner,safety_class:$safety_class,policy:$policy,total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:$reclaimable_bytes,unknown_bytes:$unknown_bytes,protection_reasons:[$protection_reason],sizing_confidence:$confidence,next_action:$next_action,error:(if $error == "" then null else $error end)}'
	return 0
}

_storage_bundle_root_from_link() {
	local link_path="$1"
	local bundles_dir="$2"
	local agents_root=""
	local bundle_root=""
	local canonical_bundles=""
	[[ -L "$link_path" ]] || return 1
	agents_root=$(cd "$link_path" 2>/dev/null && pwd -P) || return 1
	bundle_root="${agents_root%/agents}"
	canonical_bundles=$(cd "$bundles_dir" 2>/dev/null && pwd -P) || return 1
	[[ "$agents_root" == "$bundle_root/agents" && "$bundle_root" == "$canonical_bundles/"* ]] || return 1
	printf '%s' "$bundle_root"
	return 0
}

_storage_bundle_lease_is_live() {
	local lease_dir="$1"
	local lease_file=""
	local lease_pid=""
	[[ -d "$lease_dir" ]] || return 1
	for lease_file in "$lease_dir"/*; do
		[[ -f "$lease_file" ]] || continue
		lease_pid="${lease_file##*/}"
		case "$lease_pid" in
		'' | *[!0-9]*) continue ;;
		esac
		kill -0 "$lease_pid" 2>/dev/null && return 0
	done
	return 1
}

_storage_emit_runtime_bundle_record() {
	local bundles_dir="${HOME}/.aidevops/runtime-bundles"
	local measured=""
	local total_bytes="null"
	local confidence="unavailable"
	local error=""
	local protected_bytes=0
	local reclaimable_bytes=0
	local unknown_bytes="null"
	local active_bundle=""
	local previous_bundle=""
	local protected_list=$'\n'
	local lease_dir=""
	local leased_bundle=""
	local bundle_root=""
	local bundle_measure=""
	local bundle_bytes=""
	local bundle_confidence=""
	local bundle_error=""

	measured=$(_storage_measure_path "$bundles_dir")
	IFS='|' read -r total_bytes confidence error <<<"$measured"
	if [[ "$total_bytes" == "0" ]]; then
		unknown_bytes=0
	elif [[ "$total_bytes" != "null" ]]; then
		if ! active_bundle=$(_storage_bundle_root_from_link "${HOME}/.aidevops/agents" "$bundles_dir"); then
			error="active-reference-unavailable"
			unknown_bytes="$total_bytes"
		else
			protected_list+="${active_bundle}"$'\n'
			if [[ -L "${HOME}/.aidevops/previous-runtime-bundle" ]]; then
				if previous_bundle=$(_storage_bundle_root_from_link "${HOME}/.aidevops/previous-runtime-bundle" "$bundles_dir"); then
					[[ "$protected_list" == *$'\n'"${previous_bundle}"$'\n'* ]] || protected_list+="${previous_bundle}"$'\n'
				else
					error="previous-reference-unavailable"
				fi
			fi
			for lease_dir in "$bundles_dir/.leases"/*; do
				[[ -d "$lease_dir" ]] || continue
				_storage_bundle_lease_is_live "$lease_dir" || continue
				leased_bundle="$bundles_dir/${lease_dir##*/}"
				[[ -d "$leased_bundle/agents" ]] || {
					error="live-lease-target-unavailable"
					continue
				}
				[[ "$protected_list" == *$'\n'"${leased_bundle}"$'\n'* ]] || protected_list+="${leased_bundle}"$'\n'
			done
			if [[ -z "$error" ]]; then
				while IFS= read -r bundle_root; do
					[[ -n "$bundle_root" ]] || continue
					bundle_measure=$(_storage_measure_path "$bundle_root")
					IFS='|' read -r bundle_bytes bundle_confidence bundle_error <<<"$bundle_measure"
					if [[ "$bundle_bytes" == "null" ]]; then
						error="protected-size-unavailable"
						break
					fi
					protected_bytes=$((protected_bytes + bundle_bytes))
				done <<<"$protected_list"
			fi
			if [[ -z "$error" ]]; then
				bundle_measure=$(_storage_measure_path "$bundles_dir/.leases")
				IFS='|' read -r bundle_bytes bundle_confidence bundle_error <<<"$bundle_measure"
				if [[ "$bundle_bytes" == "null" ]]; then
					error="lease-metadata-size-unavailable"
				else
					protected_bytes=$((protected_bytes + bundle_bytes))
				fi
			fi
			if [[ -z "$error" ]]; then
				[[ "$protected_bytes" -le "$total_bytes" ]] || protected_bytes="$total_bytes"
				reclaimable_bytes=$((total_bytes - protected_bytes))
				unknown_bytes=0
			else
				protected_bytes=0
				reclaimable_bytes=0
				unknown_bytes="$total_bytes"
				confidence="unavailable"
			fi
		fi
	fi

	jq -cn \
		--arg error "$error" \
		--arg confidence "$confidence" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson reclaimable_bytes "$reclaimable_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{store_id:"runtime-bundles",producer:"agent-deploy",path:"~/.aidevops/runtime-bundles",owner:"framework",safety_class:"mixed",policy:"30-day age, 30-bundle count, and 8 GiB soft limits; references and live leases veto deletion",total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:$reclaimable_bytes,unknown_bytes:$unknown_bytes,protection_reasons:["current bundle, previous rollback bundle, live leases, and lease metadata"],sizing_confidence:$confidence,next_action:"Use setup activation for policy-owned pruning; do not delete protected bundles manually",error:(if $error == "" or $error == "missing" then null else $error end)}'
	return 0
}

_storage_observability_record() {
	local home_label="~"
	local display_path="${home_label}/.aidevops/.agent-workspace/observability"
	local actual_path="${HOME}/.aidevops/.agent-workspace/observability"
	local report=""
	local measured=""
	local total_bytes="$STORAGE_JSON_NULL"
	local confidence="unavailable"
	local sizing_error=""

	report=$(bash "$SCRIPT_DIR/observability-helper.sh" storage --json 2>/dev/null || true)
	if [[ -z "$report" ]] || ! printf '%s\n' "$report" | jq -e '
		def is_number: type == "number";
		type == "object" and (.active_bytes | is_number) and
		(.archive_bytes | is_number) and (.protected_bytes | is_number) and
		(.reclaimable_bytes | is_number) and (.unknown_bytes | is_number)
	' >/dev/null 2>&1; then
		_storage_emit_record "observability" "opencode-aidevops" "$display_path" "$actual_path" \
			"$STORAGE_OWNER_FRAMEWORK" "unknown" "retention inventory unavailable" "unknown" \
			"classification unavailable" "Use observability-helper.sh storage --json" |
			jq -c '.error = "retention-inventory-unavailable"'
		return 0
	fi

	measured=$(_storage_measure_path "$actual_path")
	IFS='|' read -r total_bytes confidence sizing_error <<<"$measured"
	jq -cn \
		--arg path "$display_path" \
		--arg owner "$STORAGE_OWNER_FRAMEWORK" \
		--arg confidence "$confidence" \
		--arg sizing_error "$sizing_error" \
		--argjson total_bytes "$total_bytes" \
		--argjson retention "$report" '
		($retention.protected_bytes | if $total_bytes == null then null elif . > $total_bytes then $total_bytes else . end) as $protected |
		(if $total_bytes == null then null else ($total_bytes - ($protected // 0)) end) as $unknown |
		{store_id:"observability",producer:"opencode-aidevops",path:$path,owner:$owner,safety_class:"audit",
		 policy:$retention.policy,total_bytes:$total_bytes,active_bytes:$retention.active_bytes,
		 archive_bytes:$retention.archive_bytes,candidate_bytes:$retention.candidate_bytes,
		 protected_bytes:$protected,reclaimable_bytes:0,unknown_bytes:$unknown,
		 protection_reasons:["verified archives and pinned state-recovery evidence"],
		 sizing_confidence:(if $sizing_error == "" and $retention.error == null then "estimated" else "unavailable" end),
		 next_action:$retention.next_action,
		 error:(if $sizing_error != "" then $sizing_error else $retention.error end)}'
	return 0
}

_storage_inventory_records() {
	local home_label="~"
	_storage_emit_runtime_bundle_record
	_storage_observability_record
	_storage_emit_record "agent-backups" "setup-backup" "${home_label}/.aidevops/agents-backups" "${HOME}/.aidevops/agents-backups" "$STORAGE_OWNER_FRAMEWORK" "rollback" "count-based snapshots; byte policy pending" "protected" "rollback safety" "Review backup inventory before any cleanup"
	_storage_emit_record "framework-logs" "multiple-framework-producers" "${home_label}/.aidevops/logs" "${HOME}/.aidevops/logs" "$STORAGE_OWNER_FRAMEWORK" "audit" "producer-specific policies pending" "protected" "audit and unresolved failure evidence" "Use producer-specific diagnostics"
	_storage_emit_record "opencode-data" "opencode" "OpenCode application data" "${AIDEVOPS_OPENCODE_DATA_DIR:-${HOME}/.local/share/opencode}" "joint" "unknown" "runtime-aware maintenance only" "unknown" "OpenCode ownership and active-session state require runtime-aware queries" "Use aidevops opencode-db report"
	_storage_emit_record "npm-cache" "npm" "npm cache" "${AIDEVOPS_NPM_CACHE_DIR:-${HOME}/.npm}" "external" "cache" "package-manager owned; no aidevops cleanup authority" "protected" "external owner" "Use npm-owned diagnostics and cleanup explicitly"
	return 0
}

_storage_inventory_json() {
	local records=""
	local generated_at=""
	records=$(_storage_inventory_records)
	generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '%s\n' "$records" | jq -s \
		--argjson schema_version "$STORAGE_SCHEMA_VERSION" \
		--arg generated_at "$generated_at" \
		'{schema_version:$schema_version,generated_at:$generated_at,read_only:true,stores:.}'
	return 0
}

_storage_format_bytes() {
	local bytes="$1"
	if [[ "$bytes" == "$STORAGE_JSON_NULL" ]]; then
		printf 'unavailable'
	elif [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%s GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%s MiB' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	elif [[ "$bytes" -ge 1024 ]]; then
		printf '%s.%s KiB' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
	else
		printf '%s B' "$bytes"
	fi
	return 0
}

_storage_status() {
	local report=""
	local store_id=""
	local owner=""
	local safety_class=""
	local total=""
	local protected=""
	local reclaimable=""
	local unknown=""
	local confidence=""
	local reason=""
	local error=""
	report=$(_storage_inventory_json)
	printf 'Storage Inventory (read-only)\n'
	printf '%-20s %-10s %-10s %12s %12s %12s %12s %-11s\n' "Store" "Owner" "Class" "Total" "Protected" "Reclaimable" "Unknown" "Confidence"
	printf '%s\n' "$report" | jq -r '.stores[] | [.store_id,.owner,.safety_class,(.total_bytes|tostring),(.protected_bytes|tostring),(.reclaimable_bytes|tostring),(.unknown_bytes|tostring),.sizing_confidence,.protection_reasons[0],(.error // "")] | @tsv' |
		while IFS=$'\t' read -r store_id owner safety_class total protected reclaimable unknown confidence reason error; do
			printf '%-20s %-10s %-10s %12s %12s %12s %12s %-11s\n' \
				"$store_id" "$owner" "$safety_class" "$(_storage_format_bytes "$total")" "$(_storage_format_bytes "$protected")" "$(_storage_format_bytes "$reclaimable")" "$(_storage_format_bytes "$unknown")" "$confidence"
			printf '  reason: %s' "$reason"
			[[ -n "$error" ]] && printf ' (%s)' "$error"
			printf '\n'
		done
	printf 'No cleanup was performed. Unknown or unavailable classifications are never reclaimable.\n'
	return 0
}

main() {
	local command_name="${1:-status}"
	case "$command_name" in
	status) _storage_status ;;
	json) _storage_inventory_json ;;
	help | --help | -h) _storage_usage ;;
	*)
		_storage_usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
