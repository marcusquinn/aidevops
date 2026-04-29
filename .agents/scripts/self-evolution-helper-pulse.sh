#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Pulse -- Pulse integration, stats, migration, and help
# =============================================================================
# Provides the pulse supervisor integration point (cmd_pulse_scan), the
# interval guard, statistics reporting, schema migration, and help output.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-pulse.sh"
#
# Dependencies:
#   - self-evolution-helper-core.sh (evol_db, init_evol_db, hours_ago_iso, etc.)
#   - self-evolution-helper-gaps.sh (cmd_detect_gaps, cmd_create_todo, cmd_resolve_gap)
#   - shared-constants.sh (log_info, log_warn, log_success, backup_sqlite_db)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_PULSE_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_PULSE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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
	# Validate numeric — treat corrupted state file as stale (allow scan)
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid timestamp in state file, allowing scan"
		return 0
	fi
	local now
	now=$(date +%s)
	# Guard against future timestamps (clock skew, corruption) that would
	# permanently suppress scans by making elapsed always negative.
	if [[ "$last_run" -gt "$now" ]]; then
		log_warn "State timestamp is in the future (${last_run} > ${now}), allowing scan"
		return 0
	fi
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
	# Graceful degradation: persistence errors are logged but never propagated.
	# A successful scan must not be reported as failed due to timestamp issues.
	if ! mkdir -p "$EVOL_STATE_DIR" 2>/dev/null; then
		log_warn "Failed to create state directory: $EVOL_STATE_DIR"
		return 0
	fi
	# Atomic write: temp file + mv prevents partial/corrupt state files
	local tmp_file="${EVOL_STATE_FILE}.tmp.$$"
	if ! date +%s >"$tmp_file" 2>/dev/null; then
		log_warn "Failed to write scan timestamp to temp file: $tmp_file"
		rm -f "$tmp_file" 2>/dev/null
		return 0
	fi
	if ! mv -f "$tmp_file" "$EVOL_STATE_FILE" 2>/dev/null; then
		log_warn "Failed to atomically update state file: $EVOL_STATE_FILE"
		rm -f "$tmp_file" 2>/dev/null
		return 0
	fi
	return 0
}

#######################################
# Parse arguments for pulse-scan command
# Outputs key=value lines for eval
#######################################
_pulse_scan_parse_args() {
	local _since=""
	local _auto_todo_threshold=3
	local _repo_path=""
	local _dry_run=false
	local _force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--since)
			_since="$2"
			shift 2
			;;
		--auto-todo-threshold)
			_auto_todo_threshold="$2"
			shift 2
			;;
		--repo-path)
			_repo_path="$2"
			shift 2
			;;
		--dry-run)
			_dry_run=true
			shift
			;;
		--force)
			_force=true
			shift
			;;
		*)
			log_warn "pulse-scan: unknown option: $1"
			shift
			;;
		esac
	done

	printf 'since=%s\nauto_todo_threshold=%s\nrepo_path=%s\ndry_run=%s\nforce=%s\n' \
		"$_since" "$_auto_todo_threshold" "$_repo_path" "$_dry_run" "$_force"
	return 0
}

#######################################
# Auto-create TODOs for high-frequency gaps (pulse-scan step 2)
# Arguments: $1=auto_todo_threshold, $2=repo_path
#######################################
_pulse_scan_auto_todos() {
	local auto_todo_threshold="$1"
	local repo_path="$2"

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
		return 0
	fi

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
	return 0
}

#######################################
# Resolve gaps whose TODOs are completed (pulse-scan step 3)
# Arguments: $1=repo_path
#######################################
_pulse_scan_resolve_completed() {
	local repo_path="$1"

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

	if [[ -z "$todo_created_gaps" ]]; then
		return 0
	fi

	local resolved_count=0
	while IFS='|' read -r gap_id todo_ref; do
		[[ -z "$gap_id" ]] && continue
		local task_id
		task_id=$(echo "$todo_ref" | grep -o 't[0-9]*' | head -1 || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

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
	return 0
}

#######################################
# Print pulse-scan summary (step 4)
#######################################
_pulse_scan_summary() {
	echo ""
	log_info "=== Pulse Scan Summary ==="
	evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT '  Detected: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'detected') ||
    char(10) || '  TODO created: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'todo_created') ||
    char(10) || '  Resolved: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'resolved') ||
    char(10) || '  Won''t fix: ' || (SELECT COUNT(*) FROM capability_gaps WHERE status = 'wont_fix') ||
    char(10) || '  Total evidence links: ' || (SELECT COUNT(*) FROM gap_evidence);
EOF
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
	local since="" auto_todo_threshold=3 repo_path="" dry_run=false force=false

	local parsed
	parsed=$(_pulse_scan_parse_args "$@")
	while IFS='=' read -r key val; do
		case "$key" in
		since) since="$val" ;;
		auto_todo_threshold) auto_todo_threshold="$val" ;;
		repo_path) repo_path="$val" ;;
		dry_run) dry_run="$val" ;;
		force) force="$val" ;;
		esac
	done <<<"$parsed"

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
	_pulse_scan_auto_todos "$auto_todo_threshold" "$repo_path"

	# Step 3: Check for resolved gaps (gaps with merged PRs)
	_pulse_scan_resolve_completed "$repo_path"

	# Step 4: Summary
	_pulse_scan_summary

	# Record scan timestamp for interval guard (always succeeds — errors logged internally)
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
# Print command reference section of help
#######################################
_help_commands() {
	cat <<'EOF'
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
EOF
	return 0
}

#######################################
# Print concepts and examples section of help
#######################################
_help_concepts() {
	cat <<'EOF'
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
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
self-evolution-helper.sh - Self-evolution loop for aidevops

Part of the conversational memory system (p035 / t1363).
Detects capability gaps from entity interaction patterns, creates TODO tasks
with evidence trails, tracks gap frequency, and manages resolution lifecycle.

EOF
	_help_commands
	echo ""
	_help_concepts
	return 0
}
