#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Gaps -- Gap detection, evidence, TODO creation, and CRUD
# =============================================================================
# Manages the full lifecycle of capability gaps: detection from scan patterns,
# evidence recording, TODO task creation via claim-task-id.sh, gap listing,
# status updates, and resolution.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-gaps.sh"
#
# Dependencies:
#   - self-evolution-helper-core.sh (evol_db, evol_sql_escape, init_evol_db, etc.)
#   - self-evolution-helper-scan.sh (cmd_scan_patterns)
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - jq (for JSON processing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_GAPS_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_GAPS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Upsert a single detected pattern into capability_gaps
# Arguments: $1=description, $2=severity, $3=category,
#            $4=evidence_ids (JSON array), $5=frequency_hint,
#            $6=entity_filter (optional)
# Outputs: "new" or "updated" to stdout
#######################################
_detect_gaps_upsert_gap() {
	local description="$1"
	local severity="$2"
	local category="$3"
	local evidence_ids="$4"
	local frequency_hint="$5"
	local entity_filter="${6:-}"

	local esc_desc
	esc_desc=$(evol_sql_escape "$description")

	# Check for existing similar gap (deduplication by exact description)
	local existing_gap_id
	existing_gap_id=$(
		evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT id FROM capability_gaps
WHERE description = '$esc_desc'
  AND status IN ('detected', 'todo_created')
LIMIT 1;
EOF
	)

	if [[ -n "$existing_gap_id" ]]; then
		evol_db "$EVOL_MEMORY_DB" <<EOF
UPDATE capability_gaps SET
    frequency = frequency + $frequency_hint,
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$(evol_sql_escape "$existing_gap_id")';
EOF
		record_gap_evidence "$existing_gap_id" "$evidence_ids"
		echo "updated:$existing_gap_id"
	else
		local gap_id
		gap_id=$(generate_gap_id)
		local esc_evidence
		esc_evidence=$(evol_sql_escape "$evidence_ids")

		# Determine entity_id from evidence interactions
		local gap_entity_id=""
		if [[ -n "$entity_filter" ]]; then
			gap_entity_id="$entity_filter"
		else
			local first_evidence_id
			first_evidence_id=$(echo "$evidence_ids" | jq -r '.[0] // ""' 2>/dev/null || echo "")
			if [[ -n "$first_evidence_id" ]]; then
				gap_entity_id=$(evol_db "$EVOL_MEMORY_DB" \
					"SELECT entity_id FROM interactions WHERE id = '$(evol_sql_escape "$first_evidence_id")' LIMIT 1;" 2>/dev/null || echo "")
			fi
		fi

		local entity_clause="NULL"
		if [[ -n "$gap_entity_id" ]]; then
			entity_clause="'$(evol_sql_escape "$gap_entity_id")'"
		fi

		evol_db "$EVOL_MEMORY_DB" <<EOF
INSERT INTO capability_gaps (id, entity_id, description, evidence, frequency, status)
VALUES ('$gap_id', $entity_clause, '$esc_desc', '$esc_evidence', $frequency_hint, 'detected');
EOF
		record_gap_evidence "$gap_id" "$evidence_ids"
		echo "new:$gap_id"
	fi
	return 0
}

#######################################
# Parse arguments for detect-gaps command
# Outputs key=value lines for eval
#######################################
_detect_gaps_parse_args() {
	local _entity_filter=""
	local _since=""
	local _dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			_entity_filter="$2"
			shift 2
			;;
		--since)
			_since="$2"
			shift 2
			;;
		--dry-run)
			_dry_run=true
			shift
			;;
		*)
			log_warn "detect-gaps: unknown option: $1"
			shift
			;;
		esac
	done

	printf 'entity_filter=%s\nsince=%s\ndry_run=%s\n' \
		"$_entity_filter" "$_since" "$_dry_run"
	return 0
}

#######################################
# Process detected patterns: upsert each into capability_gaps
# Arguments: $1=patterns (JSON array), $2=pattern_count,
#            $3=dry_run (true/false), $4=entity_filter
#######################################
_detect_gaps_process_patterns() {
	local patterns="$1"
	local pattern_count="$2"
	local dry_run="$3"
	local entity_filter="$4"

	log_info "Processing $pattern_count detected patterns..."

	local new_gaps=0 updated_gaps=0 skipped=0 i=0

	while [[ "$i" -lt "$pattern_count" ]]; do
		local pattern
		pattern=$(echo "$patterns" | jq -c ".[$i]")
		local description severity category evidence_ids frequency_hint
		description=$(echo "$pattern" | jq -r '.description // ""')
		severity=$(echo "$pattern" | jq -r '.severity // "medium"')
		category=$(echo "$pattern" | jq -r '.category // "missing_feature"')
		evidence_ids=$(echo "$pattern" | jq -c '.evidence_ids // []')
		frequency_hint=$(echo "$pattern" | jq -r '.frequency_hint // 1')

		if [[ -z "$description" ]]; then
			skipped=$((skipped + 1))
			i=$((i + 1))
			continue
		fi

		if [[ "$dry_run" == true ]]; then
			log_info "[DRY RUN] Would record gap: $description (severity: $severity, category: $category)"
			i=$((i + 1))
			continue
		fi

		local upsert_result
		upsert_result=$(_detect_gaps_upsert_gap \
			"$description" "$severity" "$category" \
			"$evidence_ids" "$frequency_hint" "$entity_filter")

		case "${upsert_result%%:*}" in
		new)
			local gap_id="${upsert_result#new:}"
			new_gaps=$((new_gaps + 1))
			log_success "New gap detected: $gap_id — $description"
			;;
		updated)
			local existing_id="${upsert_result#updated:}"
			updated_gaps=$((updated_gaps + 1))
			log_info "Updated existing gap: $existing_id (frequency +$frequency_hint)"
			;;
		esac

		i=$((i + 1))
	done

	echo ""
	log_success "Gap detection complete: $new_gaps new, $updated_gaps updated, $skipped skipped"
	return 0
}

#######################################
# Detect capability gaps from interaction patterns
# Runs scan-patterns and records detected gaps in the database.
# Deduplicates against existing gaps (increments frequency if similar).
#######################################
cmd_detect_gaps() {
	local entity_filter="" since="" dry_run=false

	local parsed
	parsed=$(_detect_gaps_parse_args "$@")
	while IFS='=' read -r key val; do
		case "$key" in
		entity_filter) entity_filter="$val" ;;
		since) since="$val" ;;
		dry_run) dry_run="$val" ;;
		esac
	done <<<"$parsed"

	init_evol_db

	# Run pattern scan
	local scan_args=("--json")
	if [[ -n "$entity_filter" ]]; then
		scan_args+=("--entity" "$entity_filter")
	fi
	if [[ -n "$since" ]]; then
		scan_args+=("--since" "$since")
	fi

	local scan_result
	scan_result=$(cmd_scan_patterns "${scan_args[@]}")

	if [[ -z "$scan_result" ]]; then
		log_info "No scan results"
		return 0
	fi

	# Extract patterns from scan result
	local patterns
	patterns=$(echo "$scan_result" | jq -c '.patterns // []' 2>/dev/null || echo "[]")
	local pattern_count
	pattern_count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$pattern_count" == "0" ]]; then
		log_info "No capability gaps detected"
		return 0
	fi

	_detect_gaps_process_patterns "$patterns" "$pattern_count" "$dry_run" "$entity_filter"
	return 0
}

#######################################
# Record evidence links for a gap
# Arguments:
#   $1 - gap_id
#   $2 - JSON array of interaction IDs
#######################################
record_gap_evidence() {
	local gap_id="$1"
	local evidence_json="$2"

	if [[ -z "$evidence_json" || "$evidence_json" == "[]" || "$evidence_json" == "null" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local esc_gap_id
	esc_gap_id=$(evol_sql_escape "$gap_id")

	local int_id
	while IFS= read -r int_id; do
		[[ -z "$int_id" || "$int_id" == "null" ]] && continue
		local esc_int_id
		esc_int_id=$(evol_sql_escape "$int_id")
		evol_db "$EVOL_MEMORY_DB" <<EOF
INSERT OR IGNORE INTO gap_evidence (gap_id, interaction_id)
VALUES ('$esc_gap_id', '$esc_int_id');
EOF
	done < <(echo "$evidence_json" | jq -r '.[]' 2>/dev/null)

	return 0
}

#######################################
# Fetch and validate gap record for create-todo
# Arguments: $1=gap_id
# Outputs JSON gap data to stdout; returns 1 if not found or already processed
#######################################
_create_todo_fetch_gap() {
	local gap_id="$1"
	local esc_id
	esc_id=$(evol_sql_escape "$gap_id")

	local gap_data
	gap_data=$(evol_db -json "$EVOL_MEMORY_DB" "SELECT * FROM capability_gaps WHERE id = '$esc_id';" 2>/dev/null)

	if [[ -z "$gap_data" || "$gap_data" == "[]" ]]; then
		log_error "Gap not found: $gap_id"
		return 1
	fi

	local status
	status=$(echo "$gap_data" | jq -r '.[0].status // ""')

	if [[ "$status" == "todo_created" ]]; then
		local existing_ref
		existing_ref=$(echo "$gap_data" | jq -r '.[0].todo_ref // ""')
		log_warn "TODO already created for this gap: $existing_ref"
		return 1
	fi

	if [[ "$status" == "resolved" || "$status" == "wont_fix" ]]; then
		log_warn "Gap is already $status"
		return 1
	fi

	echo "$gap_data"
	return 0
}

#######################################
# Build GitHub issue body for a capability gap TODO
# Arguments: $1=gap_id, $2=gap_data (JSON), $3=esc_id
# Outputs issue body text to stdout
#######################################
_create_todo_build_issue_body() {
	local gap_id="$1"
	local gap_data="$2"
	local esc_id="$3"

	local description frequency evidence entity_id detected_at
	description=$(echo "$gap_data" | jq -r '.[0].description // ""')
	frequency=$(echo "$gap_data" | jq -r '.[0].frequency // 1')
	evidence=$(echo "$gap_data" | jq -r '.[0].evidence // ""')
	entity_id=$(echo "$gap_data" | jq -r '.[0].entity_id // ""')
	detected_at=$(echo "$gap_data" | jq -r '.[0].created_at // "unknown"')

	# Get evidence interaction IDs for the issue body
	local evidence_interactions=""
	evidence_interactions=$(
		evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT ge.interaction_id || ' (' || i.channel || ', ' || i.created_at || '): ' ||
    substr(i.content, 1, 100)
FROM gap_evidence ge
LEFT JOIN interactions i ON ge.interaction_id = i.id
WHERE ge.gap_id = '$esc_id'
ORDER BY ge.added_at ASC
LIMIT 10;
EOF
	)

	# Get entity name if available
	local entity_name=""
	if [[ -n "$entity_id" && "$entity_id" != "null" ]]; then
		entity_name=$(evol_db "$EVOL_MEMORY_DB" \
			"SELECT name FROM entities WHERE id = '$(evol_sql_escape "$entity_id")';" 2>/dev/null || echo "")
	fi

	local issue_body
	issue_body="## Capability Gap (auto-detected)

**Description:** ${description}
**Frequency:** Observed ${frequency} time(s)
**Detected:** ${detected_at}
**Gap ID:** \`${gap_id}\`"

	if [[ -n "$entity_name" ]]; then
		issue_body="${issue_body}
**Entity:** ${entity_name}"
	fi

	issue_body="${issue_body}

## Evidence Trail

The following interactions revealed this capability gap:"

	if [[ -n "$evidence_interactions" ]]; then
		issue_body="${issue_body}

\`\`\`
${evidence_interactions}
\`\`\`"
	else
		issue_body="${issue_body}

Evidence IDs: ${evidence}"
	fi

	issue_body="${issue_body}

## Source

Auto-created by self-evolution-helper.sh from entity interaction pattern analysis.
Gap lifecycle: detected → todo_created → resolved"

	echo "$issue_body"
	return 0
}

#######################################
# Claim a task ID for a gap TODO via claim-task-id.sh
# Arguments: $1=gap_id, $2=description, $3=issue_body, $4=repo_path
# Outputs todo_ref to stdout; returns 1 on failure
#######################################
_create_todo_claim_task() {
	local gap_id="$1"
	local description="$2"
	local issue_body="$3"
	local repo_path="$4"
	local esc_id
	esc_id=$(evol_sql_escape "$gap_id")

	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"

	if [[ ! -x "$claim_script" ]]; then
		log_warn "claim-task-id.sh not found — creating gap record without TODO"
		echo "manual-required"
		return 0
	fi

	local claim_output
	claim_output=$("$claim_script" \
		--repo-path "$repo_path" \
		--title "Self-evolution: ${description}" \
		--description "$issue_body" \
		--labels "self-evolution,auto-dispatch,source:self-evolution" 2>&1) || {
		log_warn "claim-task-id.sh failed — recording gap without TODO"
		log_warn "Output: $claim_output"
		# Still update the gap status to avoid re-processing
		evol_db "$EVOL_MEMORY_DB" <<EOF
UPDATE capability_gaps SET
    status = 'detected',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF
		return 1
	}

	# Parse claim output for task_id and ref
	local task_id
	task_id=$(echo "$claim_output" | grep -o 'task_id=t[0-9]*' | head -1 | cut -d= -f2 || echo "")
	local gh_ref
	gh_ref=$(echo "$claim_output" | grep -o 'ref=GH#[0-9]*' | head -1 | cut -d= -f2 || echo "")

	local todo_ref
	if [[ -n "$task_id" ]]; then
		todo_ref="$task_id"
		if [[ -n "$gh_ref" ]]; then
			todo_ref="${task_id} (${gh_ref})"
		fi
	else
		todo_ref="claim-pending"
	fi

	echo "$todo_ref"
	return 0
}

#######################################
# Create a TODO task for a capability gap
# Uses claim-task-id.sh for atomic ID allocation and creates a GitHub issue.
# The gap is updated with the TODO reference.
#######################################
cmd_create_todo() {
	local gap_id="${1:-}"
	local repo_path=""

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		*)
			log_warn "create-todo: unknown option: $1"
			shift
			;;
		esac
	done

	if [[ -z "$gap_id" ]]; then
		log_error "Gap ID is required. Usage: self-evolution-helper.sh create-todo <gap_id>"
		return 1
	fi

	init_evol_db

	local esc_id
	esc_id=$(evol_sql_escape "$gap_id")

	# Fetch and validate gap
	local gap_data
	gap_data=$(_create_todo_fetch_gap "$gap_id") || return 0

	local description
	description=$(echo "$gap_data" | jq -r '.[0].description // ""')

	# Determine repo path
	if [[ -z "$repo_path" ]]; then
		repo_path="${HOME}/Git/aidevops"
		if [[ ! -d "$repo_path" ]]; then
			repo_path="$(pwd)"
		fi
	fi

	# Build issue body
	local issue_body
	issue_body=$(_create_todo_build_issue_body "$gap_id" "$gap_data" "$esc_id")

	# Claim task ID
	local todo_ref
	todo_ref=$(_create_todo_claim_task "$gap_id" "$description" "$issue_body" "$repo_path") || return 1

	# Update gap with TODO reference
	local esc_ref
	esc_ref=$(evol_sql_escape "$todo_ref")
	evol_db "$EVOL_MEMORY_DB" <<EOF
UPDATE capability_gaps SET
    status = 'todo_created',
    todo_ref = '$esc_ref',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Created TODO for gap $gap_id: $todo_ref"
	echo "$todo_ref"
	return 0
}

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
