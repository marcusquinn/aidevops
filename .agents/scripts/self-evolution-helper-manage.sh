#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Manage -- Gap listing, updating, and resolution
# =============================================================================
# List, filter, update, and resolve capability gaps in the database.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-manage.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - self-evolution-helper-db.sh (evol_db, evol_sql_escape, init_evol_db)
#   - EVOL_MEMORY_DB, VALID_GAP_STATUSES must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_MANAGE_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_MANAGE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Parse arguments and build WHERE/ORDER clauses for list-gaps
# Outputs key=value lines for eval
#######################################
_list_gaps_parse_args() {
	local _status_filter=""
	local _entity_filter=""
	local _format="text"
	local _limit=50
	local _sort_by="frequency"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			_status_filter="$2"
			shift 2
			;;
		--entity)
			_entity_filter="$2"
			shift 2
			;;
		--json)
			_format="json"
			shift
			;;
		--limit)
			_limit="$2"
			shift 2
			;;
		--sort)
			_sort_by="$2"
			shift 2
			;;
		*)
			log_warn "list-gaps: unknown option: $1"
			shift
			;;
		esac
	done

	printf 'status_filter=%s\nentity_filter=%s\nformat=%s\nlimit=%s\nsort_by=%s\n' \
		"$_status_filter" "$_entity_filter" "$_format" "$_limit" "$_sort_by"
	return 0
}

#######################################
# Build SQL WHERE and ORDER clauses for list-gaps
# Arguments: $1=status_filter, $2=entity_filter, $3=sort_by
# Outputs: "WHERE_CLAUSE|ORDER_CLAUSE" to stdout; returns 1 on invalid status
#######################################
_list_gaps_build_query() {
	local status_filter="$1"
	local entity_filter="$2"
	local sort_by="$3"

	local where_clause="1=1"
	if [[ -n "$status_filter" ]]; then
		local st_pattern=" $status_filter "
		if [[ ! " $VALID_GAP_STATUSES " =~ $st_pattern ]]; then
			log_error "Invalid status: $status_filter. Valid: $VALID_GAP_STATUSES"
			return 1
		fi
		where_clause="$where_clause AND cg.status = '$(evol_sql_escape "$status_filter")'"
	fi
	if [[ -n "$entity_filter" ]]; then
		where_clause="$where_clause AND cg.entity_id = '$(evol_sql_escape "$entity_filter")'"
	fi

	local order_clause="cg.frequency DESC, cg.updated_at DESC"
	if [[ "$sort_by" == "date" ]]; then
		order_clause="cg.updated_at DESC"
	elif [[ "$sort_by" == "status" ]]; then
		order_clause="cg.status, cg.frequency DESC"
	fi

	echo "${where_clause}|${order_clause}"
	return 0
}

#######################################
# List capability gaps
#######################################
cmd_list_gaps() {
	local status_filter="" entity_filter="" format="text" limit=50 sort_by="frequency"

	local parsed
	parsed=$(_list_gaps_parse_args "$@")
	while IFS='=' read -r key val; do
		case "$key" in
		status_filter) status_filter="$val" ;;
		entity_filter) entity_filter="$val" ;;
		format) format="$val" ;;
		limit) limit="$val" ;;
		sort_by) sort_by="$val" ;;
		esac
	done <<<"$parsed"

	init_evol_db

	local query_parts
	query_parts=$(_list_gaps_build_query "$status_filter" "$entity_filter" "$sort_by") || return 1

	local where_clause="${query_parts%%|*}"
	local order_clause="${query_parts##*|}"

	if [[ "$format" == "json" ]]; then
		evol_db -json "$EVOL_MEMORY_DB" <<EOF
SELECT cg.id, cg.entity_id, COALESCE(e.name, '') as entity_name,
    cg.description, cg.frequency, cg.status, cg.todo_ref,
    cg.created_at, cg.updated_at,
    (SELECT COUNT(*) FROM gap_evidence ge WHERE ge.gap_id = cg.id) as evidence_count
FROM capability_gaps cg
LEFT JOIN entities e ON cg.entity_id = e.id
WHERE $where_clause
ORDER BY $order_clause
LIMIT $limit;
EOF
	else
		echo ""
		echo "=== Capability Gaps ==="
		if [[ -n "$status_filter" ]]; then
			echo "Filter: status=$status_filter"
		fi
		echo ""

		local gaps
		gaps=$(
			evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT cg.id || ' | freq:' || cg.frequency || ' | ' || cg.status ||
    CASE WHEN cg.todo_ref IS NOT NULL AND cg.todo_ref != '' THEN ' | ref:' || cg.todo_ref ELSE '' END ||
    CASE WHEN e.name IS NOT NULL THEN ' | entity:' || e.name ELSE '' END ||
    char(10) || '  ' || substr(cg.description, 1, 100) ||
    CASE WHEN length(cg.description) > 100 THEN '...' ELSE '' END
FROM capability_gaps cg
LEFT JOIN entities e ON cg.entity_id = e.id
WHERE $where_clause
ORDER BY $order_clause
LIMIT $limit;
EOF
		)

		if [[ -z "$gaps" ]]; then
			echo "  (no gaps found)"
		else
			echo "$gaps"
		fi
	fi

	return 0
}

#######################################
# Update a gap's status
#######################################
cmd_update_gap() {
	local gap_id="${1:-}"
	local new_status=""
	local todo_ref=""

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			new_status="$2"
			shift 2
			;;
		--todo-ref)
			todo_ref="$2"
			shift 2
			;;
		*)
			log_warn "update-gap: unknown option: $1"
			shift
			;;
		esac
	done

	if [[ -z "$gap_id" ]]; then
		log_error "Gap ID is required. Usage: self-evolution-helper.sh update-gap <gap_id> --status <status>"
		return 1
	fi

	if [[ -z "$new_status" ]]; then
		log_error "Status is required. Use --status detected|todo_created|resolved|wont_fix"
		return 1
	fi

	local st_pattern=" $new_status "
	if [[ ! " $VALID_GAP_STATUSES " =~ $st_pattern ]]; then
		log_error "Invalid status: $new_status. Valid: $VALID_GAP_STATUSES"
		return 1
	fi

	init_evol_db

	local esc_id
	esc_id=$(evol_sql_escape "$gap_id")

	# Check existence
	local exists
	exists=$(evol_db "$EVOL_MEMORY_DB" "SELECT COUNT(*) FROM capability_gaps WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Gap not found: $gap_id"
		return 1
	fi

	local set_parts
	set_parts="status = '$(evol_sql_escape "$new_status")'"
	set_parts="$set_parts, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"

	if [[ -n "$todo_ref" ]]; then
		set_parts="$set_parts, todo_ref = '$(evol_sql_escape "$todo_ref")'"
	fi

	evol_db "$EVOL_MEMORY_DB" "UPDATE capability_gaps SET $set_parts WHERE id = '$esc_id';"

	log_success "Updated gap $gap_id: status=$new_status"
	return 0
}

#######################################
# Resolve a gap (mark as resolved)
#######################################
cmd_resolve_gap() {
	local gap_id="${1:-}"
	local todo_ref=""

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--todo-ref)
			todo_ref="$2"
			shift 2
			;;
		*)
			log_warn "resolve-gap: unknown option: $1"
			shift
			;;
		esac
	done

	if [[ -z "$gap_id" ]]; then
		log_error "Gap ID is required. Usage: self-evolution-helper.sh resolve-gap <gap_id>"
		return 1
	fi

	local args=("$gap_id" "--status" "resolved")
	if [[ -n "$todo_ref" ]]; then
		args+=("--todo-ref" "$todo_ref")
	fi

	cmd_update_gap "${args[@]}"
	return $?
}
