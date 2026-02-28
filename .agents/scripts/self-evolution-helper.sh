#!/usr/bin/env bash
# self-evolution-helper.sh - Self-evolution loop for aidevops
# Detects capability gaps from entity interaction patterns, creates TODO tasks
# with evidence trails, tracks gap frequency, and manages resolution lifecycle.
#
# Part of the conversational memory system (p035 / t1363).
# Uses the same SQLite database (memory.db) as entity-helper.sh and
# conversation-helper.sh.
#
# Architecture:
#   Entity interactions (Layer 0)
#     → Pattern detection (AI judgment, not regex)
#     → Capability gap identification
#     → TODO creation with evidence trail (interaction IDs)
#     → System upgrade (normal aidevops task lifecycle)
#     → Better service to entity
#     → Updated entity model (Layer 2)
#     → Cycle continues
#
# Usage:
#   self-evolution-helper.sh scan-patterns [--entity <id>] [--since <ISO>] [--limit <n>]
#   self-evolution-helper.sh detect-gaps [--entity <id>] [--since <ISO>]
#   self-evolution-helper.sh create-todo <gap_id> [--repo-path <path>]
#   self-evolution-helper.sh list-gaps [--status detected|todo_created|resolved|wont_fix] [--json]
#   self-evolution-helper.sh update-gap <gap_id> --status <status> [--todo-ref <ref>]
#   self-evolution-helper.sh resolve-gap <gap_id> [--todo-ref <ref>]
#   self-evolution-helper.sh pulse-scan [--since <ISO>]
#   self-evolution-helper.sh stats [--json]
#   self-evolution-helper.sh migrate
#   self-evolution-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — uses same base as entity-helper.sh
readonly EVOL_MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
EVOL_MEMORY_DB="${EVOL_MEMORY_BASE_DIR}/memory.db"

# AI research script for intelligent judgments (haiku tier)
readonly EVOL_AI_RESEARCH_SCRIPT="${SCRIPT_DIR}/ai-research-helper.sh"

# Default lookback window for pattern scanning (24 hours)
readonly DEFAULT_SCAN_WINDOW_HOURS=24

# Valid gap statuses
readonly VALID_GAP_STATUSES="detected todo_created resolved wont_fix"

# Minimum interactions to consider for pattern scanning
readonly MIN_INTERACTIONS_FOR_SCAN=3

# Pulse interval guard — minimum hours between automatic scans
readonly PULSE_INTERVAL_HOURS=6
readonly EVOL_STATE_DIR="${HOME}/.aidevops/logs"
readonly EVOL_STATE_FILE="${EVOL_STATE_DIR}/self-evolution-last-run"

#######################################
# SQLite wrapper (same as entity/memory system)
#######################################
evol_db() {
	sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON;" "$@"
	return $?
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
evol_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

#######################################
# SQL-escape a value for use in LIKE patterns
# Escapes single quotes AND LIKE wildcards (%, _)
# Use with: LIKE '...' ESCAPE '\'
#######################################
evol_sql_escape_like() {
	local val="$1"
	# Escape backslash first (so it doesn't double-escape later replacements)
	val="${val//\\/\\\\}"
	# Escape LIKE wildcards
	val="${val//%/\\%}"
	val="${val//_/\\_}"
	# Escape single quotes for SQL string literal
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

#######################################
# Generate unique gap ID
#######################################
generate_gap_id() {
	echo "gap_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Initialize/verify capability_gaps table exists
# The table is created by entity-helper.sh init_entity_db, but we
# ensure it exists here for standalone usage.
#######################################
init_evol_db() {
	mkdir -p "$EVOL_MEMORY_BASE_DIR"

	# Set WAL mode, busy timeout, and enable foreign keys for CASCADE
	evol_db "$EVOL_MEMORY_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;" >/dev/null 2>&1

	evol_db "$EVOL_MEMORY_DB" <<'SCHEMA'

-- Capability gaps detected from entity interactions
-- Feeds into self-evolution loop: gap -> TODO -> upgrade -> better service
CREATE TABLE IF NOT EXISTS capability_gaps (
    id TEXT PRIMARY KEY,
    entity_id TEXT DEFAULT NULL,
    description TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    frequency INTEGER DEFAULT 1,
    status TEXT DEFAULT 'detected' CHECK(status IN ('detected', 'todo_created', 'resolved', 'wont_fix')),
    todo_ref TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_capability_gaps_status ON capability_gaps(status);
CREATE INDEX IF NOT EXISTS idx_capability_gaps_entity ON capability_gaps(entity_id);
CREATE INDEX IF NOT EXISTS idx_capability_gaps_frequency ON capability_gaps(frequency DESC);

-- Gap evidence links — maps gaps to the specific interactions that revealed them
-- Provides the full evidence trail: gap → interaction IDs → raw messages
CREATE TABLE IF NOT EXISTS gap_evidence (
    gap_id TEXT NOT NULL,
    interaction_id TEXT NOT NULL,
    relevance TEXT DEFAULT 'primary',
    added_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (gap_id, interaction_id),
    FOREIGN KEY (gap_id) REFERENCES capability_gaps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_gap_evidence_gap ON gap_evidence(gap_id);
CREATE INDEX IF NOT EXISTS idx_gap_evidence_interaction ON gap_evidence(interaction_id);

SCHEMA

	return 0
}

#######################################
# Get ISO timestamp for N hours ago
#######################################
hours_ago_iso() {
	local hours="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ"
	else
		date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ"
	fi
	return 0
}

#######################################
# Scan interaction patterns using AI judgment
# Analyses recent interactions to identify:
#   - Repeated requests the system couldn't fulfil
#   - Friction points (user frustration, repeated clarifications)
#   - Feature requests (explicit or implied)
#   - Workflow gaps (manual steps that could be automated)
#
# Uses haiku-tier AI (~$0.001/call) for pattern significance.
# Falls back to heuristic scanning when AI is unavailable.
#######################################
cmd_scan_patterns() {
	local entity_filter=""
	local since=""
	local limit=100
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity_filter="$2"
			shift 2
			;;
		--since)
			since="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		*)
			log_warn "scan-patterns: unknown option: $1"
			shift
			;;
		esac
	done

	init_evol_db

	# Default: scan last 24 hours
	if [[ -z "$since" ]]; then
		since=$(hours_ago_iso "$DEFAULT_SCAN_WINDOW_HOURS")
	fi

	# Build query filters
	local where_clause
	where_clause="i.created_at >= '$(evol_sql_escape "$since")'"
	if [[ -n "$entity_filter" ]]; then
		where_clause="$where_clause AND i.entity_id = '$(evol_sql_escape "$entity_filter")'"
	fi

	# Fetch recent interactions
	local interactions
	interactions=$(
		evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT i.id, i.entity_id, i.channel, i.direction, i.content, i.created_at,
    COALESCE(e.name, 'Unknown') as entity_name
FROM interactions i
LEFT JOIN entities e ON i.entity_id = e.id
WHERE $where_clause
ORDER BY i.created_at ASC
LIMIT $limit;
EOF
	)

	if [[ -z "$interactions" ]]; then
		log_info "No interactions found since $since"
		if [[ "$format" == "json" ]]; then
			echo '{"patterns":[],"interaction_count":0,"scan_window":"'"$since"'"}'
		fi
		return 0
	fi

	local interaction_count
	interaction_count=$(echo "$interactions" | wc -l | tr -d ' ')

	if [[ "$interaction_count" -lt "$MIN_INTERACTIONS_FOR_SCAN" ]]; then
		log_info "Only $interaction_count interactions found (minimum: $MIN_INTERACTIONS_FOR_SCAN). Skipping scan."
		if [[ "$format" == "json" ]]; then
			echo '{"patterns":[],"interaction_count":'"$interaction_count"',"scan_window":"'"$since"'","reason":"below_minimum"}'
		fi
		return 0
	fi

	# Format interactions for AI analysis
	local formatted=""
	while IFS='|' read -r int_id entity_id channel direction content timestamp entity_name; do
		# Truncate long messages for the AI prompt
		local truncated_content
		truncated_content=$(echo "$content" | head -c 200)
		formatted="${formatted}[${int_id}] ${direction} ${channel} (${entity_name}) ${timestamp}: ${truncated_content}
"
	done <<<"$interactions"

	# Try AI-powered pattern detection
	local ai_result=""
	if [[ -x "$EVOL_AI_RESEARCH_SCRIPT" ]]; then
		local ai_prompt
		ai_prompt="Analyse these ${interaction_count} recent interactions from an AI assistant system. Identify capability gaps — things users needed that the system couldn't do well, or patterns suggesting missing features.

Interactions:
${formatted}

Respond with ONLY a JSON array of detected patterns. Each pattern:
{
  \"description\": \"What capability is missing or inadequate\",
  \"evidence_ids\": [\"int_xxx\", \"int_yyy\"],
  \"severity\": \"high|medium|low\",
  \"category\": \"missing_feature|workflow_gap|knowledge_gap|integration_gap|ux_friction\",
  \"frequency_hint\": 1
}

Rules:
- Only include genuine capability gaps, not normal conversation
- Evidence IDs must be from the interaction list above
- If no gaps detected, return empty array []
- Respond with ONLY the JSON array, no markdown fences
- Maximum 10 patterns per scan"

		ai_result=$("$EVOL_AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo "")
	fi

	# Parse AI result or use heuristic fallback
	if [[ -n "$ai_result" ]] && command -v jq &>/dev/null; then
		# Validate JSON
		if echo "$ai_result" | jq -e 'type == "array"' >/dev/null 2>&1; then
			local pattern_count
			pattern_count=$(echo "$ai_result" | jq 'length')

			if [[ "$format" == "json" ]]; then
				echo "{\"patterns\":${ai_result},\"interaction_count\":${interaction_count},\"scan_window\":\"${since}\",\"method\":\"ai\"}"
			else
				echo ""
				echo "=== Pattern Scan Results ==="
				echo "Window: since $since ($interaction_count interactions)"
				echo "Method: AI-judged (haiku)"
				echo "Patterns found: $pattern_count"
				echo ""

				if [[ "$pattern_count" -gt 0 ]]; then
					echo "$ai_result" | jq -r '.[] | "[\(.severity)] \(.category): \(.description)\n  Evidence: \(.evidence_ids | join(", "))\n"' 2>/dev/null
				else
					echo "No capability gaps detected in this window."
				fi
			fi
			return 0
		fi
	fi

	# Heuristic fallback: scan for common gap indicators
	local patterns
	patterns=$(scan_patterns_heuristic "$interactions")

	if [[ "$format" == "json" ]]; then
		echo "{\"patterns\":${patterns:-[]},\"interaction_count\":${interaction_count},\"scan_window\":\"${since}\",\"method\":\"heuristic\"}"
	else
		echo ""
		echo "=== Pattern Scan Results ==="
		echo "Window: since $since ($interaction_count interactions)"
		echo "Method: heuristic (AI unavailable)"
		echo ""

		if [[ "$patterns" == "[]" || -z "$patterns" ]]; then
			echo "No capability gaps detected in this window."
		else
			echo "$patterns" | jq -r '.[] | "[\(.severity)] \(.category): \(.description)\n  Evidence: \(.evidence_ids | join(", "))\n"' 2>/dev/null || echo "$patterns"
		fi
	fi

	return 0
}

#######################################
# Heuristic pattern scanning fallback
# Looks for common indicators of capability gaps in interaction content.
# Less accurate than AI but works without API access.
#######################################
scan_patterns_heuristic() {
	local interactions="$1"
	local patterns="[]"

	# Check for "can't", "unable", "doesn't support", "not possible" in outbound messages
	local inability_ids
	inability_ids=$(echo "$interactions" | grep -i 'outbound' | grep -iE "can.t|unable|doesn.t support|not possible|not available|not implemented|don.t have|no way to" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')

	if [[ -n "$inability_ids" ]]; then
		local inability_count
		inability_count=$(echo "$inability_ids" | tr ',' '\n' | wc -l | tr -d ' ')
		local id_array
		id_array=$(echo "$inability_ids" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
		patterns=$(echo "$patterns" | jq --argjson ids "[$id_array]" --arg count "$inability_count" \
			'. + [{"description":"System expressed inability to fulfil requests","evidence_ids":$ids,"severity":"medium","category":"missing_feature","frequency_hint":($count|tonumber)}]' 2>/dev/null || echo "$patterns")
	fi

	# Check for repeated questions (same entity asking similar things)
	local repeat_ids
	repeat_ids=$(echo "$interactions" | grep -i 'inbound' | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -3 | awk '$1 > 2 {print $2}')

	if [[ -n "$repeat_ids" ]]; then
		while IFS= read -r entity_id; do
			[[ -z "$entity_id" ]] && continue
			local entity_int_ids
			entity_int_ids=$(echo "$interactions" | grep "|${entity_id}|" | grep 'inbound' | cut -d'|' -f1 | head -5 | tr '\n' ',' | sed 's/,$//')
			if [[ -n "$entity_int_ids" ]]; then
				local eid_array
				eid_array=$(echo "$entity_int_ids" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
				patterns=$(echo "$patterns" | jq --argjson ids "[$eid_array]" \
					'. + [{"description":"Entity has high interaction frequency — may indicate unresolved need","evidence_ids":$ids,"severity":"low","category":"ux_friction","frequency_hint":1}]' 2>/dev/null || echo "$patterns")
			fi
		done <<<"$repeat_ids"
	fi

	echo "$patterns"
	return 0
}

#######################################
# Detect capability gaps from interaction patterns
# Runs scan-patterns and records detected gaps in the database.
# Deduplicates against existing gaps (increments frequency if similar).
#######################################
cmd_detect_gaps() {
	local entity_filter=""
	local since=""
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity_filter="$2"
			shift 2
			;;
		--since)
			since="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_warn "detect-gaps: unknown option: $1"
			shift
			;;
		esac
	done

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

	log_info "Processing $pattern_count detected patterns..."

	local new_gaps=0
	local updated_gaps=0
	local skipped=0

	# Process each pattern
	local i=0
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

		# Check for existing similar gap (deduplication)
		# Use LIKE matching on description — AI dedup would be better but
		# this is the heuristic fallback. The key insight: if the same gap
		# description appears again, increment frequency rather than creating
		# a duplicate.
		local esc_desc
		esc_desc=$(evol_sql_escape "$description")
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
			# Increment frequency and add new evidence
			evol_db "$EVOL_MEMORY_DB" <<EOF
UPDATE capability_gaps SET
    frequency = frequency + $frequency_hint,
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$(evol_sql_escape "$existing_gap_id")';
EOF
			# Add evidence links
			record_gap_evidence "$existing_gap_id" "$evidence_ids"
			updated_gaps=$((updated_gaps + 1))
			log_info "Updated existing gap: $existing_gap_id (frequency +$frequency_hint)"
		else
			# Create new gap
			local gap_id
			gap_id=$(generate_gap_id)
			local esc_evidence
			esc_evidence=$(evol_sql_escape "$evidence_ids")

			# Determine entity_id from evidence interactions
			local gap_entity_id=""
			if [[ -n "$entity_filter" ]]; then
				gap_entity_id="$entity_filter"
			else
				# Try to get entity from first evidence interaction
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
			# Record evidence links
			record_gap_evidence "$gap_id" "$evidence_ids"
			new_gaps=$((new_gaps + 1))
			log_success "New gap detected: $gap_id — $description"
		fi

		i=$((i + 1))
	done

	echo ""
	log_success "Gap detection complete: $new_gaps new, $updated_gaps updated, $skipped skipped"
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

	# Fetch gap details
	local gap_data
	gap_data=$(evol_db -json "$EVOL_MEMORY_DB" "SELECT * FROM capability_gaps WHERE id = '$esc_id';" 2>/dev/null)

	if [[ -z "$gap_data" || "$gap_data" == "[]" ]]; then
		log_error "Gap not found: $gap_id"
		return 1
	fi

	local description status frequency evidence entity_id
	description=$(echo "$gap_data" | jq -r '.[0].description // ""')
	status=$(echo "$gap_data" | jq -r '.[0].status // ""')
	frequency=$(echo "$gap_data" | jq -r '.[0].frequency // 1')
	evidence=$(echo "$gap_data" | jq -r '.[0].evidence // ""')
	entity_id=$(echo "$gap_data" | jq -r '.[0].entity_id // ""')

	if [[ "$status" == "todo_created" ]]; then
		local existing_ref
		existing_ref=$(echo "$gap_data" | jq -r '.[0].todo_ref // ""')
		log_warn "TODO already created for this gap: $existing_ref"
		return 0
	fi

	if [[ "$status" == "resolved" || "$status" == "wont_fix" ]]; then
		log_warn "Gap is already $status"
		return 0
	fi

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

	# Build issue body
	local issue_body
	local detected_at
	detected_at=$(echo "$gap_data" | jq -r '.[0].created_at // "unknown"')
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

	# Determine repo path
	if [[ -z "$repo_path" ]]; then
		# Default to aidevops repo
		repo_path="${HOME}/Git/aidevops"
		if [[ ! -d "$repo_path" ]]; then
			repo_path="$(pwd)"
		fi
	fi

	# Use claim-task-id.sh if available
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	local todo_ref=""

	if [[ -x "$claim_script" ]]; then
		local claim_output
		claim_output=$("$claim_script" \
			--repo-path "$repo_path" \
			--title "Self-evolution: ${description}" \
			--description "$issue_body" \
			--labels "self-evolution,auto-dispatch" 2>&1) || {
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

		if [[ -n "$task_id" ]]; then
			todo_ref="$task_id"
			if [[ -n "$gh_ref" ]]; then
				todo_ref="${task_id} (${gh_ref})"
			fi
		else
			todo_ref="claim-pending"
		fi
	else
		log_warn "claim-task-id.sh not found — creating gap record without TODO"
		todo_ref="manual-required"
	fi

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
# List capability gaps
#######################################
cmd_list_gaps() {
	local status_filter=""
	local entity_filter=""
	local format="text"
	local limit=50
	local sort_by="frequency"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			status_filter="$2"
			shift 2
			;;
		--entity)
			entity_filter="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--sort)
			sort_by="$2"
			shift 2
			;;
		*)
			log_warn "list-gaps: unknown option: $1"
			shift
			;;
		esac
	done

	init_evol_db

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

#######################################
# Check pulse scan interval guard
# Returns 0 if enough time has passed, 1 if too soon
#######################################
check_scan_interval() {
	if [[ ! -f "$EVOL_STATE_FILE" ]]; then
		return 0
	fi

	local last_run
	last_run=$(cat "$EVOL_STATE_FILE" 2>/dev/null || echo "0")
	local now
	now=$(date +%s)
	local interval_seconds=$((PULSE_INTERVAL_HOURS * 3600))
	local elapsed=$((now - last_run))

	if [[ "$elapsed" -lt "$interval_seconds" ]]; then
		local remaining=$(((interval_seconds - elapsed) / 60))
		log_info "Pulse scan ran ${elapsed}s ago (interval: ${interval_seconds}s). Next scan in ~${remaining}m. Use --force to override."
		return 1
	fi

	return 0
}

#######################################
# Record pulse scan timestamp
#######################################
record_scan_timestamp() {
	mkdir -p "$EVOL_STATE_DIR"
	date +%s >"$EVOL_STATE_FILE"
	return 0
}

#######################################
# Pulse scan — integration point for supervisor pulse
# Runs the full self-evolution cycle:
#   1. Scan recent interactions for patterns
#   2. Detect and record capability gaps
#   3. Auto-create TODOs for high-frequency gaps
#   4. Report summary
#
# Designed to be called from pulse.md Step 3.5 or similar.
#######################################
cmd_pulse_scan() {
	local since=""
	local auto_todo_threshold=3
	local repo_path=""
	local dry_run=false
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--since)
			since="$2"
			shift 2
			;;
		--auto-todo-threshold)
			auto_todo_threshold="$2"
			shift 2
			;;
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--force)
			force=true
			shift
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	# Interval guard — skip if scanned recently (unless --force)
	if [[ "$force" != true ]] && ! check_scan_interval; then
		return 0
	fi

	init_evol_db

	log_info "=== Self-Evolution Pulse Scan ==="

	# Default: scan last 24 hours
	if [[ -z "$since" ]]; then
		since=$(hours_ago_iso "$DEFAULT_SCAN_WINDOW_HOURS")
	fi

	# Step 1: Detect gaps from recent interactions
	log_info "Step 1: Scanning interactions since $since..."
	local detect_args=("--since" "$since")
	if [[ "$dry_run" == true ]]; then
		detect_args+=("--dry-run")
	fi
	cmd_detect_gaps "${detect_args[@]}" || {
		log_warn "Gap detection encountered errors — continuing with existing gaps"
	}

	if [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Skipping TODO creation"
		return 0
	fi

	# Step 2: Auto-create TODOs for high-frequency gaps
	log_info "Step 2: Checking for gaps above auto-TODO threshold (frequency >= $auto_todo_threshold)..."

	local high_freq_gaps
	high_freq_gaps=$(
		evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT id, description, frequency FROM capability_gaps
WHERE status = 'detected'
  AND frequency >= $auto_todo_threshold
ORDER BY frequency DESC
LIMIT 5;
EOF
	)

	if [[ -z "$high_freq_gaps" ]]; then
		log_info "No gaps above auto-TODO threshold"
	else
		local todo_count=0
		while IFS='|' read -r gap_id description frequency; do
			[[ -z "$gap_id" ]] && continue
			log_info "Creating TODO for gap $gap_id (frequency: $frequency): $description"

			local todo_args=("$gap_id")
			if [[ -n "$repo_path" ]]; then
				todo_args+=("--repo-path" "$repo_path")
			fi

			if cmd_create_todo "${todo_args[@]}"; then
				todo_count=$((todo_count + 1))
			else
				log_warn "Failed to create TODO for gap $gap_id"
			fi
		done <<<"$high_freq_gaps"

		log_success "Created $todo_count TODO(s) from high-frequency gaps"
	fi

	# Step 3: Check for resolved gaps (gaps with merged PRs)
	log_info "Step 3: Checking for resolvable gaps..."
	local todo_created_gaps
	todo_created_gaps=$(
		evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT id, todo_ref FROM capability_gaps
WHERE status = 'todo_created'
  AND todo_ref IS NOT NULL
  AND todo_ref != '';
EOF
	)

	if [[ -n "$todo_created_gaps" ]]; then
		local resolved_count=0
		while IFS='|' read -r gap_id todo_ref; do
			[[ -z "$gap_id" ]] && continue
			# Extract task ID from todo_ref (format: "tNNN" or "tNNN (GH#NNN)")
			local task_id
			task_id=$(echo "$todo_ref" | grep -o 't[0-9]*' | head -1 || echo "")
			if [[ -z "$task_id" ]]; then
				continue
			fi

			# Check if the task is marked complete in TODO.md
			if [[ -n "$repo_path" && -f "${repo_path}/TODO.md" ]]; then
				if grep -q "\[x\].*${task_id}" "${repo_path}/TODO.md" 2>/dev/null; then
					cmd_resolve_gap "$gap_id" --todo-ref "$todo_ref"
					resolved_count=$((resolved_count + 1))
				fi
			fi
		done <<<"$todo_created_gaps"

		if [[ "$resolved_count" -gt 0 ]]; then
			log_success "Resolved $resolved_count gap(s) with completed TODOs"
		fi
	fi

	# Step 4: Summary
	echo ""
	log_info "=== Pulse Scan Summary ==="
	evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT '  Detected: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'detected') ||
    char(10) || '  TODO created: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'todo_created') ||
    char(10) || '  Resolved: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'resolved') ||
    char(10) || '  Won''t fix: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'wont_fix') ||
    char(10) || '  Total evidence links: ' || (SELECT COUNT(*) FROM gap_evidence);
EOF

	# Record scan timestamp for interval guard
	record_scan_timestamp

	return 0
}

#######################################
# Show self-evolution statistics
#######################################
cmd_stats() {
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			format="json"
			shift
			;;
		*)
			log_warn "stats: unknown option: $1"
			shift
			;;
		esac
	done

	init_evol_db

	if [[ "$format" == "json" ]]; then
		evol_db -json "$EVOL_MEMORY_DB" <<'EOF'
SELECT
    (SELECT COUNT(*) FROM capability_gaps) as total_gaps,
    (SELECT COUNT(*) FROM capability_gaps WHERE status = 'detected') as detected,
    (SELECT COUNT(*) FROM capability_gaps WHERE status = 'todo_created') as todo_created,
    (SELECT COUNT(*) FROM capability_gaps WHERE status = 'resolved') as resolved,
    (SELECT COUNT(*) FROM capability_gaps WHERE status = 'wont_fix') as wont_fix,
    (SELECT COUNT(*) FROM gap_evidence) as total_evidence_links,
    (SELECT MAX(frequency) FROM capability_gaps) as max_frequency,
    (SELECT AVG(frequency) FROM capability_gaps) as avg_frequency,
    (SELECT COUNT(DISTINCT entity_id) FROM capability_gaps WHERE entity_id IS NOT NULL) as entities_with_gaps;
EOF
	else
		echo ""
		echo "=== Self-Evolution Statistics ==="
		echo ""

		evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT 'Total gaps' as metric, COUNT(*) as value FROM capability_gaps
UNION ALL
SELECT 'Detected (pending)', COUNT(*) FROM capability_gaps WHERE status = 'detected'
UNION ALL
SELECT 'TODO created', COUNT(*) FROM capability_gaps WHERE status = 'todo_created'
UNION ALL
SELECT 'Resolved', COUNT(*) FROM capability_gaps WHERE status = 'resolved'
UNION ALL
SELECT 'Won''t fix', COUNT(*) FROM capability_gaps WHERE status = 'wont_fix'
UNION ALL
SELECT 'Evidence links', COUNT(*) FROM gap_evidence
UNION ALL
SELECT 'Entities with gaps', COUNT(DISTINCT entity_id) FROM capability_gaps WHERE entity_id IS NOT NULL;
EOF

		echo ""
		echo "Top gaps by frequency:"
		evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT '  [' || cg.status || '] freq:' || cg.frequency || ' — ' || substr(cg.description, 1, 80) ||
    CASE WHEN cg.todo_ref IS NOT NULL AND cg.todo_ref != '' THEN ' (ref:' || cg.todo_ref || ')' ELSE '' END
FROM capability_gaps cg
ORDER BY cg.frequency DESC
LIMIT 10;
EOF

		echo ""
		echo "Recent gaps (last 7 days):"
		evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT '  ' || cg.id || ' | ' || cg.status || ' | freq:' || cg.frequency ||
    ' | ' || substr(cg.description, 1, 60)
FROM capability_gaps cg
WHERE cg.created_at >= datetime('now', '-7 days')
ORDER BY cg.created_at DESC
LIMIT 10;
EOF
	fi

	return 0
}

#######################################
# Run schema migration (idempotent)
#######################################
cmd_migrate() {
	log_info "Running self-evolution schema migration..."

	# Backup before migration
	if [[ -f "$EVOL_MEMORY_DB" ]]; then
		local backup
		backup=$(backup_sqlite_db "$EVOL_MEMORY_DB" "pre-self-evolution-migrate")
		if [[ $? -ne 0 || -z "$backup" ]]; then
			log_warn "Backup failed before migration — proceeding cautiously"
		else
			log_info "Pre-migration backup: $backup"
		fi
	fi

	init_evol_db

	log_success "Self-evolution schema migration complete"

	# Show table status
	evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT 'capability_gaps: ' || (SELECT COUNT(*) FROM capability_gaps) || ' rows' ||
    char(10) || 'gap_evidence: ' || (SELECT COUNT(*) FROM gap_evidence) || ' rows';
EOF

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
self-evolution-helper.sh - Self-evolution loop for aidevops

Part of the conversational memory system (p035 / t1363).
Detects capability gaps from entity interaction patterns, creates TODO tasks
with evidence trails, tracks gap frequency, and manages resolution lifecycle.

USAGE:
    self-evolution-helper.sh <command> [options]

PATTERN SCANNING:
    scan-patterns       Scan recent interactions for capability gap patterns
    detect-gaps         Detect gaps and record them in the database
    pulse-scan          Full self-evolution cycle (for pulse supervisor)

GAP MANAGEMENT:
    list-gaps           List capability gaps
    update-gap <id>     Update a gap's status
    resolve-gap <id>    Mark a gap as resolved
    create-todo <id>    Create a TODO task for a gap

SYSTEM:
    stats               Show self-evolution statistics
    migrate             Run schema migration (idempotent)
    help                Show this help

SCAN-PATTERNS OPTIONS:
    --entity <id>       Filter by entity
    --since <ISO>       Scan window start (default: 24h ago)
    --limit <n>         Max interactions to analyse (default: 100)
    --json              Output as JSON

DETECT-GAPS OPTIONS:
    --entity <id>       Filter by entity
    --since <ISO>       Scan window start (default: 24h ago)
    --dry-run           Show what would be detected without recording

CREATE-TODO OPTIONS:
    --repo-path <path>  Repository path for TODO creation (default: ~/Git/aidevops)

LIST-GAPS OPTIONS:
    --status <status>   Filter: detected, todo_created, resolved, wont_fix
    --entity <id>       Filter by entity
    --sort <field>      Sort by: frequency (default), date, status
    --limit <n>         Max results (default: 50)
    --json              Output as JSON

UPDATE-GAP OPTIONS:
    --status <status>   New status (required)
    --todo-ref <ref>    TODO reference (e.g., "t1234 (GH#567)")

PULSE-SCAN OPTIONS:
    --since <ISO>       Scan window start (default: 24h ago)
    --auto-todo-threshold <n>  Frequency threshold for auto-TODO (default: 3)
    --repo-path <path>  Repository path for TODO creation
    --dry-run           Scan without creating TODOs
    --force             Skip interval guard (default: 6h between scans)

SELF-EVOLUTION LOOP:
    The self-evolution loop is the core differentiator of the entity memory
    system. It works as follows:

    1. Entity interactions are logged (Layer 0) by entity-helper.sh
    2. scan-patterns analyses recent interactions using AI judgment (haiku
       tier, ~$0.001/call) to identify capability gaps — things users needed
       that the system couldn't do well
    3. detect-gaps records these patterns in the capability_gaps table,
       deduplicating against existing gaps (incrementing frequency)
    4. When a gap's frequency exceeds the auto-TODO threshold (default: 3),
       pulse-scan automatically creates a TODO task via claim-task-id.sh
    5. The TODO enters the normal aidevops task lifecycle (dispatch, PR, merge)
    6. When the task is completed, the gap is marked as resolved
    7. The system is now better at serving the entity's needs

    This creates a compound improvement loop: more interactions → more
    pattern data → better gap detection → more targeted improvements →
    better service → more interactions.

GAP LIFECYCLE:
    detected       Gap identified from interaction patterns
    todo_created   TODO task created (with evidence trail)
    resolved       The capability was implemented (task completed)
    wont_fix       Gap acknowledged but won't be addressed

EVIDENCE TRAIL:
    Every gap links to the specific interaction IDs that revealed it via
    the gap_evidence table. This provides full traceability:
    gap → gap_evidence → interactions → raw messages

    When a TODO is created, the issue body includes the evidence trail
    so the implementing worker has full context on what users actually
    needed and when.

AI JUDGMENT:
    Pattern scanning uses AI (haiku tier) to identify genuine capability
    gaps vs normal conversation. This follows the Intelligence Over
    Determinism principle — no regex can reliably distinguish "user asked
    for something we can't do" from "user asked a question we answered."

    When AI is unavailable, heuristic fallbacks scan for common indicators
    (outbound messages containing "can't", "unable", etc.) but with lower
    accuracy.

EXAMPLES:
    # Scan recent interactions for patterns
    self-evolution-helper.sh scan-patterns --since 2026-02-27T00:00:00Z

    # Detect and record gaps
    self-evolution-helper.sh detect-gaps --since 2026-02-27T00:00:00Z

    # Run full pulse scan (for supervisor integration)
    self-evolution-helper.sh pulse-scan --auto-todo-threshold 3

    # Force pulse scan (bypass 6h interval guard)
    self-evolution-helper.sh pulse-scan --force

    # List detected gaps sorted by frequency
    self-evolution-helper.sh list-gaps --status detected --sort frequency

    # Create TODO for a specific gap
    self-evolution-helper.sh create-todo gap_xxx --repo-path ~/Git/aidevops

    # Mark a gap as resolved
    self-evolution-helper.sh resolve-gap gap_xxx --todo-ref "t1400 (GH#2600)"

    # View statistics
    self-evolution-helper.sh stats --json
EOF
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan-patterns) cmd_scan_patterns "$@" ;;
	detect-gaps) cmd_detect_gaps "$@" ;;
	create-todo) cmd_create_todo "$@" ;;
	list-gaps) cmd_list_gaps "$@" ;;
	update-gap) cmd_update_gap "$@" ;;
	resolve-gap) cmd_resolve_gap "$@" ;;
	pulse-scan) cmd_pulse_scan "$@" ;;
	stats) cmd_stats "$@" ;;
	migrate) cmd_migrate ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
exit $?
