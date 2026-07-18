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
	local total_bytes="null"
	local confidence="unavailable"
	local error=""
	local protected_bytes="null"
	local reclaimable_bytes=0
	local unknown_bytes="null"

	measured=$(_storage_measure_path "$actual_path")
	IFS='|' read -r total_bytes confidence error <<<"$measured"
	if [[ "$total_bytes" != "null" ]]; then
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

_storage_inventory_records() {
	local home_label="~"
	_storage_emit_record "runtime-bundles" "agent-deploy" "${home_label}/.aidevops/runtime-bundles" "${HOME}/.aidevops/runtime-bundles" "framework" "unknown" "30-day unleased age policy; detailed bounds pending" "unknown" "bundle references require store-specific classification" "Review runtime-bundle status; do not delete manually"
	_storage_emit_record "observability" "opencode-aidevops" "${home_label}/.aidevops/.agent-workspace/observability" "${HOME}/.aidevops/.agent-workspace/observability" "framework" "audit" "append-only audit evidence; compaction contract pending" "protected" "audit evidence" "Use observability-helper.sh for bounded queries"
	_storage_emit_record "agent-backups" "setup-backup" "${home_label}/.aidevops/agents-backups" "${HOME}/.aidevops/agents-backups" "framework" "rollback" "count-based snapshots; byte policy pending" "protected" "rollback safety" "Review backup inventory before any cleanup"
	_storage_emit_record "framework-logs" "multiple-framework-producers" "${home_label}/.aidevops/logs" "${HOME}/.aidevops/logs" "framework" "audit" "producer-specific policies pending" "protected" "audit and unresolved failure evidence" "Use producer-specific diagnostics"
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
	if [[ "$bytes" == "null" ]]; then
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
