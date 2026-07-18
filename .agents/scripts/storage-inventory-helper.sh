#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "$SCRIPT_DIR/shared-constants.sh"
fi
OPENCODE_STORAGE_PROBES_AVAILABLE=0
if [[ -f "$SCRIPT_DIR/opencode-db-safety-lib.sh" ]]; then
	# shellcheck source=opencode-db-safety-lib.sh
	source "$SCRIPT_DIR/opencode-db-safety-lib.sh"
	OPENCODE_STORAGE_PROBES_AVAILABLE=1
fi

STORAGE_SCHEMA_VERSION=2
STORAGE_SIZE_TIMEOUT_TENTHS="${AIDEVOPS_STORAGE_SIZE_TIMEOUT_TENTHS:-20}"
STORAGE_DU_COMMAND="${AIDEVOPS_STORAGE_DU_COMMAND:-du}"
STORAGE_UNKNOWN="unknown"
STORAGE_PROTECTED="protected"
STORAGE_JOINT="joint"
STORAGE_ACTIVE="active"
STORAGE_ARCHIVE="archive"
STORAGE_PRODUCER_OPENCODE="opencode"

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

_storage_emit_measured_record() {
	local store_id="$1"
	local producer="$2"
	local display_path="$3"
	local owner="$4"
	local safety_class="$5"
	local policy="$6"
	local disposition="$7"
	local protection_reason="$8"
	local next_action="$9"
	local measured="${10}"
	local total_bytes="null"
	local confidence="unavailable"
	local error=""
	local protected_bytes="null"
	local reclaimable_bytes=0
	local unknown_bytes="null"

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

	measured=$(_storage_measure_path "$actual_path")
	_storage_emit_measured_record "$store_id" "$producer" "$display_path" "$owner" \
		"$safety_class" "$policy" "$disposition" "$protection_reason" "$next_action" "$measured"
	return 0
}

_storage_measure_group() {
	local total_bytes=0
	local path=""
	local measured=""
	local path_bytes=""
	local confidence=""
	local error=""
	local saw_path=0

	for path in "$@"; do
		measured=$(_storage_measure_path "$path")
		IFS='|' read -r path_bytes confidence error <<<"$measured"
		if [[ "$path_bytes" == "null" ]]; then
			printf 'null|unavailable|%s' "${error:-component-unavailable}"
			return 0
		fi
		if [[ "$error" != "missing" ]]; then
			saw_path=1
		fi
		total_bytes=$((total_bytes + path_bytes))
	done
	if [[ "$saw_path" -eq 0 ]]; then
		printf '0|exact|missing'
	else
		printf '%s|exact|' "$total_bytes"
	fi
	return 0
}

_storage_opencode_residual_measurement() {
	local root_path="$1"
	shift
	local root_measure=""
	local root_bytes=""
	local root_confidence=""
	local root_error=""
	local known_bytes=0
	local component_path=""
	local component_measure=""
	local component_bytes=""
	local component_confidence=""
	local component_error=""

	root_measure=$(_storage_measure_path "$root_path")
	IFS='|' read -r root_bytes root_confidence root_error <<<"$root_measure"
	if [[ "$root_bytes" == "null" ]]; then
		printf 'null|unavailable|%s' "${root_error:-root-unavailable}"
		return 0
	fi
	for component_path in "$@"; do
		if [[ "$component_path" != "$root_path" && "$component_path" != "$root_path/"* ]]; then
			continue
		fi
		component_measure=$(_storage_measure_path "$component_path")
		IFS='|' read -r component_bytes component_confidence component_error <<<"$component_measure"
		if [[ "$component_bytes" == "null" ]]; then
			printf 'null|unavailable|known-component-unavailable'
			return 0
		fi
		known_bytes=$((known_bytes + component_bytes))
	done
	root_bytes=$((root_bytes - known_bytes))
	[[ "$root_bytes" -ge 0 ]] || root_bytes=0
	printf '%s|estimated|' "$root_bytes"
	return 0
}

_storage_opencode_records() {
	local data_root="${AIDEVOPS_OPENCODE_DATA_DIR:-${HOME}/.local/share/opencode}"
	local active_db="${AIDEVOPS_OPENCODE_DB_PATH:-${OPENCODE_DB_PATH:-${OPENCODE_DB:-${data_root}/opencode.db}}}"
	local active_dir="${active_db%/*}"
	local archive_db=""
	local legacy_path="${data_root}/storage"
	local tool_path="${data_root}/tool"
	local active_measure=""
	local wal_measure=""
	local archive_measure=""
	local legacy_measure=""
	local tool_measure=""
	local residual_measure=""
	local active_schema="$STORAGE_UNKNOWN"
	local archive_schema="$STORAGE_UNKNOWN"
	local holder_count="$STORAGE_UNKNOWN"
	local wal_state="$STORAGE_UNKNOWN"
	local active_class="$STORAGE_ACTIVE"
	local active_disposition="$STORAGE_PROTECTED"
	local active_reason="OpenCode-owned logical sessions and live SQLite pages are never cleanup candidates"
	local archive_class="$STORAGE_ARCHIVE"
	local archive_disposition="$STORAGE_PROTECTED"
	local archive_reason="archive retention and integrity require explicit OpenCode-aware verification"
	local wal_reason="idle snapshot only; maintenance still requires holder and checkpoint evidence"

	if [[ "$active_dir" == "$active_db" ]]; then
		active_dir="."
	fi
	archive_db="${AIDEVOPS_OPENCODE_ARCHIVE_DB:-${OPENCODE_ARCHIVE_DB:-${active_dir}/opencode-archive.db}}"
	active_measure=$(_storage_measure_group "$active_db")
	wal_measure=$(_storage_measure_group "${active_db}-wal" "${active_db}-shm")
	archive_measure=$(_storage_measure_group "$archive_db" "${archive_db}-wal" "${archive_db}-shm")
	legacy_measure=$(_storage_measure_group "$legacy_path")
	tool_measure=$(_storage_measure_group "$tool_path")
	residual_measure=$(_storage_opencode_residual_measurement "$data_root" \
		"$active_db" "${active_db}-wal" "${active_db}-shm" \
		"$archive_db" "${archive_db}-wal" "${archive_db}-shm" "$legacy_path" "$tool_path")

	if [[ "$OPENCODE_STORAGE_PROBES_AVAILABLE" -eq 1 ]]; then
		active_schema=$(opencode_db_schema_state "$active_db")
		archive_schema=$(opencode_db_schema_state "$archive_db")
		holder_count=$(opencode_db_holder_count "$active_db" "${AIDEVOPS_STORAGE_LSOF_COMMAND:-lsof}")
		wal_state=$(opencode_db_wal_state "$active_db" "${AIDEVOPS_STORAGE_WAL_SAMPLE_DELAY_SECONDS:-0.1}")
	fi
	if [[ "$active_schema" == "$STORAGE_UNKNOWN" ]]; then
		active_class="$STORAGE_UNKNOWN"
		active_disposition="$STORAGE_UNKNOWN"
		active_reason="active database schema is unavailable; all bytes remain unknown and untouched"
	fi
	if [[ "$archive_schema" == "$STORAGE_UNKNOWN" ]]; then
		archive_class="$STORAGE_UNKNOWN"
		archive_disposition="$STORAGE_UNKNOWN"
		archive_reason="archive schema is unavailable; all bytes remain unknown and untouched"
	fi
	if [[ "$holder_count" =~ ^[0-9]+$ && "$holder_count" -gt 0 ]]; then
		wal_reason="active database holder detected; WAL and shared-memory bytes are protected"
	elif [[ "$wal_state" == "changing" ]]; then
		wal_reason="WAL changed during observation; active SQLite state is protected"
	elif [[ "$holder_count" == "$STORAGE_UNKNOWN" || "$wal_state" == "$STORAGE_UNKNOWN" ]]; then
		wal_reason="holder or WAL state is unavailable; active SQLite bytes are protected"
	fi

	_storage_emit_measured_record "opencode-active-db" "$STORAGE_PRODUCER_OPENCODE" "OpenCode active database" "$STORAGE_JOINT" \
		"$active_class" "logical session retention is OpenCode-owned" "$active_disposition" "$active_reason" \
		"Use aidevops opencode-db report; do not select sessions by age or size" "$active_measure"
	_storage_emit_measured_record "opencode-active-wal" "$STORAGE_PRODUCER_OPENCODE" "OpenCode active WAL/SHM" "$STORAGE_JOINT" \
		"$STORAGE_ACTIVE" "checkpoint and VACUUM only after idle-holder evidence" "$STORAGE_PROTECTED" "$wal_reason" \
		"Close OpenCode holders, then use aidevops opencode-db maintain" "$wal_measure"
	_storage_emit_measured_record "opencode-archive" "aidevops-opencode-archive" "OpenCode archive database" "$STORAGE_JOINT" \
		"$archive_class" "archive data is retained; no generic deletion contract" "$archive_disposition" "$archive_reason" \
		"Inspect with aidevops opencode-db sessions --include-archive" "$archive_measure"
	_storage_emit_measured_record "opencode-legacy" "$STORAGE_PRODUCER_OPENCODE" "OpenCode legacy storage" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "legacy format lifecycle is owned upstream" "$STORAGE_UNKNOWN" "legacy format ownership or migration state is unproved" \
		"Use an upstream OpenCode migration/export path; leave data untouched" "$legacy_measure"
	_storage_emit_measured_record "opencode-tool-output" "$STORAGE_PRODUCER_OPENCODE" "OpenCode tool output" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "tool-output lifecycle is owned upstream" "$STORAGE_UNKNOWN" "tool output may be referenced by logical sessions" \
		"Use OpenCode-owned controls; no aidevops cleanup is available" "$tool_measure"
	_storage_emit_measured_record "opencode-unclassified" "$STORAGE_PRODUCER_OPENCODE" "Other OpenCode application data" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "future and unclassified formats fail closed" "$STORAGE_UNKNOWN" "unclassified OpenCode bytes have no proved mutation contract" \
		"Review with current OpenCode documentation and leave untouched" "$residual_measure"
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

_storage_inventory_records() {
	local home_label="~"
	_storage_emit_runtime_bundle_record
	_storage_emit_record "observability" "opencode-aidevops" "${home_label}/.aidevops/.agent-workspace/observability" "${HOME}/.aidevops/.agent-workspace/observability" "framework" "audit" "append-only audit evidence; compaction contract pending" "protected" "audit evidence" "Use observability-helper.sh for bounded queries"
	_storage_emit_record "agent-backups" "setup-backup" "${home_label}/.aidevops/agents-backups" "${HOME}/.aidevops/agents-backups" "framework" "rollback" "count-based snapshots; byte policy pending" "protected" "rollback safety" "Review backup inventory before any cleanup"
	_storage_emit_record "framework-logs" "multiple-framework-producers" "${home_label}/.aidevops/logs" "${HOME}/.aidevops/logs" "framework" "audit" "producer-specific policies pending" "protected" "audit and unresolved failure evidence" "Use producer-specific diagnostics"
	_storage_opencode_records
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
	local next_action=""
	local error=""
	report=$(_storage_inventory_json)
	printf 'Storage Inventory (read-only)\n'
	printf '%-24s %-10s %-10s %12s %12s %12s %12s %-11s\n' "Store" "Owner" "Class" "Total" "Protected" "Reclaimable" "Unknown" "Confidence"
	printf '%s\n' "$report" | jq -r '.stores[] | [.store_id,.owner,.safety_class,(.total_bytes|tostring),(.protected_bytes|tostring),(.reclaimable_bytes|tostring),(.unknown_bytes|tostring),.sizing_confidence,.protection_reasons[0],.next_action,(.error // "")] | @tsv' |
		while IFS=$'\t' read -r store_id owner safety_class total protected reclaimable unknown confidence reason next_action error; do
			printf '%-24s %-10s %-10s %12s %12s %12s %12s %-11s\n' \
				"$store_id" "$owner" "$safety_class" "$(_storage_format_bytes "$total")" "$(_storage_format_bytes "$protected")" "$(_storage_format_bytes "$reclaimable")" "$(_storage_format_bytes "$unknown")" "$confidence"
			printf '  reason: %s' "$reason"
			[[ -n "$error" ]] && printf ' (%s)' "$error"
			printf '\n'
			printf '  next: %s\n' "$next_action"
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
