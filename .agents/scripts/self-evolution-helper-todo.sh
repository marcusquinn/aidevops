#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution TODO -- TODO task creation for capability gaps
# =============================================================================
# Fetches gap data, builds GitHub issue bodies with evidence trails, and
# claims task IDs via claim-task-id.sh for the self-evolution lifecycle.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-todo.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - self-evolution-helper-db.sh (evol_db, evol_sql_escape, init_evol_db)
#   - EVOL_MEMORY_DB must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_TODO_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_TODO_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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
