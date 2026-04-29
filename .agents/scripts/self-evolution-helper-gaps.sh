#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Gaps -- Gap detection and evidence recording
# =============================================================================
# Detects capability gaps from interaction patterns, upserts them into the
# database with deduplication, and records evidence links.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-gaps.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - self-evolution-helper-db.sh (evol_db, evol_sql_escape, init_evol_db, generate_gap_id)
#   - self-evolution-helper-scan.sh (cmd_scan_patterns)
#   - EVOL_MEMORY_DB must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_GAPS_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_GAPS_LIB_LOADED=1

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
