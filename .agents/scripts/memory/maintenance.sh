#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Maintenance -- Orchestrator
# =============================================================================
# Thin orchestrator that sources focused sub-libraries and provides lightweight
# commands (stats, validate, export, log).
#
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_stats, cmd_validate, cmd_dedup, cmd_prune, cmd_consolidate,
#           cmd_prune_patterns, cmd_export, cmd_namespaces, cmd_namespaces_prune,
#           cmd_namespaces_migrate, cmd_log
#
# Sub-libraries:
#   maintenance-dedup.sh        -- cmd_dedup, _dedup_*
#   maintenance-prune.sh        -- cmd_prune, cmd_prune_patterns, _prune_*
#   maintenance-consolidate.sh  -- cmd_consolidate, _consolidate_*
#   maintenance-namespaces.sh   -- cmd_namespaces, cmd_namespaces_prune,
#                                  cmd_namespaces_migrate, _migrate_*

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_LOADED=1

# Defensive SCRIPT_DIR fallback (for direct sourcing / test harnesses)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Resolve directory containing this file (sub-libraries are siblings)
_MAINT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_MAINT_DIR" == "${BASH_SOURCE[0]}" ]] && _MAINT_DIR="."
_MAINT_DIR="$(cd "$_MAINT_DIR" && pwd)"

# --- Source sub-libraries ---

# shellcheck source=./maintenance-dedup.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $_MAINT_DIR
source "${_MAINT_DIR}/maintenance-dedup.sh"

# shellcheck source=./maintenance-prune.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $_MAINT_DIR
source "${_MAINT_DIR}/maintenance-prune.sh"

# shellcheck source=./maintenance-consolidate.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $_MAINT_DIR
source "${_MAINT_DIR}/maintenance-consolidate.sh"

# shellcheck source=./maintenance-namespaces.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $_MAINT_DIR
source "${_MAINT_DIR}/maintenance-namespaces.sh"

unset _MAINT_DIR

# --- Lightweight commands (kept in orchestrator) ---

#######################################
# Show memory statistics
#######################################
cmd_stats() {
	init_db

	local header_suffix=""
	if [[ -n "$MEMORY_NAMESPACE" ]]; then
		header_suffix=" [namespace: $MEMORY_NAMESPACE]"
	fi

	echo ""
	echo "=== Memory Statistics${header_suffix} ==="
	echo ""

	db "$MEMORY_DB" <<'EOF'
SELECT 'Total learnings' as metric, COUNT(*) as value FROM learnings
UNION ALL
SELECT 'By type: ' || type, COUNT(*) FROM learnings GROUP BY type
UNION ALL
SELECT 'Auto-captured', COUNT(*) FROM learning_access WHERE auto_captured = 1
UNION ALL
SELECT 'Manual', COUNT(*) FROM learnings l 
    LEFT JOIN learning_access a ON l.id = a.id WHERE COALESCE(a.auto_captured, 0) = 0
UNION ALL
SELECT 'Never accessed', COUNT(*) FROM learnings l 
    LEFT JOIN learning_access a ON l.id = a.id WHERE a.id IS NULL
UNION ALL
SELECT 'High confidence', COUNT(*) FROM learnings WHERE confidence = 'high';
EOF

	echo ""

	# Show relation statistics
	echo "Relational versioning:"
	db "$MEMORY_DB" <<'EOF'
SELECT '  Total relations', COUNT(*) FROM learning_relations
UNION ALL
SELECT '  Updates (supersedes)', COUNT(*) FROM learning_relations WHERE relation_type = 'updates'
UNION ALL
SELECT '  Extends (adds detail)', COUNT(*) FROM learning_relations WHERE relation_type = 'extends'
UNION ALL
SELECT '  Derives (inferred)', COUNT(*) FROM learning_relations WHERE relation_type = 'derives';
EOF

	echo ""

	# Show age distribution
	echo "Age distribution:"
	db "$MEMORY_DB" <<'EOF'
SELECT 
    CASE 
        WHEN created_at >= datetime('now', '-7 days') THEN '  Last 7 days'
        WHEN created_at >= datetime('now', '-30 days') THEN '  Last 30 days'
        WHEN created_at >= datetime('now', '-90 days') THEN '  Last 90 days'
        ELSE '  Older than 90 days'
    END as age_bucket,
    COUNT(*) as count
FROM learnings
GROUP BY 1
ORDER BY 1;
EOF
	return 0
}

#######################################
# Validate and warn about stale entries
#######################################
cmd_validate() {
	init_db

	echo ""
	echo "=== Memory Validation ==="
	echo ""

	# Check for stale entries (old + never accessed)
	local stale_count
	stale_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$STALE_WARNING_DAYS days') AND a.id IS NULL;")

	if [[ "$stale_count" -gt 0 ]]; then
		log_warn "Found $stale_count potentially stale entries (>$STALE_WARNING_DAYS days old, never accessed)"
		echo ""
		echo "Stale entries:"
		db "$MEMORY_DB" <<EOF
SELECT l.id, l.type, substr(l.content, 1, 60) || '...' as content_preview, l.created_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.created_at < datetime('now', '-$STALE_WARNING_DAYS days') 
AND a.id IS NULL
LIMIT 10;
EOF
		echo ""
		echo "Run 'memory-helper.sh prune --older-than-days $STALE_WARNING_DAYS' to clean up"
	else
		log_success "No stale entries found"
	fi

	# Check for exact duplicate content
	local dup_count
	dup_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM (SELECT content, COUNT(*) as cnt FROM learnings GROUP BY content HAVING cnt > 1);" 2>/dev/null || echo "0")

	if [[ "$dup_count" -gt 0 ]]; then
		log_warn "Found $dup_count groups of exact duplicate entries"
		echo ""
		echo "Exact duplicates:"
		db "$MEMORY_DB" <<'EOF'
SELECT substr(l.content, 1, 60) || '...' as content_preview,
       l.type,
       COUNT(*) as copies,
       GROUP_CONCAT(l.id, ', ') as ids
FROM learnings l
GROUP BY l.content
HAVING COUNT(*) > 1
ORDER BY copies DESC
LIMIT 10;
EOF
		echo ""
		echo "Run 'memory-helper.sh dedup --dry-run' to preview cleanup"
		echo "Run 'memory-helper.sh dedup' to remove duplicates"
	else
		log_success "No exact duplicate entries found"
	fi

	# Check for near-duplicate content (normalized comparison)
	local near_dup_count
	near_dup_count=$(
		db "$MEMORY_DB" <<'EOF'
SELECT COUNT(*) FROM (
    SELECT replace(replace(replace(replace(replace(lower(content),
        '.',''),"'",''),',',''),'!',''),'?','') as norm,
        COUNT(*) as cnt
    FROM learnings
    GROUP BY norm
    HAVING cnt > 1
);
EOF
	)
	near_dup_count="${near_dup_count:-0}"

	if [[ "$near_dup_count" -gt "$dup_count" ]]; then
		local near_only=$((near_dup_count - dup_count))
		log_warn "Found $near_only additional near-duplicate groups (differ only in case/punctuation)"
		echo "  Run 'memory-helper.sh dedup' to consolidate"
	fi

	# Check for superseded entries that may be obsolete
	local superseded_count
	superseded_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learning_relations WHERE relation_type = 'updates';") || log_warn "Failed to query superseded count"
	if [[ "${superseded_count:-0}" -gt 0 ]]; then
		log_info "$superseded_count memories have been superseded by newer versions"
	fi

	# Check database size
	local db_size
	db_size=$(du -h "$MEMORY_DB" | cut -f1)
	log_info "Database size: $db_size"
	return 0
}

#######################################
# Export memories
#######################################
cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			format="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	case "$format" in
	json)
		db -json "$MEMORY_DB" "SELECT l.*, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id ORDER BY l.created_at DESC;"
		;;
	toon)
		# TOON format for token efficiency
		local count
		count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;")
		echo "learnings[$count]{id,type,confidence,content,tags,created_at}:"
		db -separator ',' "$MEMORY_DB" "SELECT id, type, confidence, content, tags, created_at FROM learnings ORDER BY created_at DESC;" | while read -r line; do
			echo "  $line"
		done
		;;
	*)
		log_error "Unknown format: $format (use json or toon)"
		return 1
		;;
	esac
}

#######################################
# Show auto-capture log
# Convenience command: recall --recent --auto-only
#######################################
cmd_log() {
	local limit=20
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--format)
			format="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local results
	results=$(db -json "$MEMORY_DB" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, l.source, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count, COALESCE(a.auto_captured, 0) as auto_captured FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE COALESCE(a.auto_captured, 0) = 1 ORDER BY l.created_at DESC LIMIT $limit;")

	if [[ "$format" == "json" ]]; then
		echo "$results"
	else
		local header_suffix=""
		if [[ -n "$MEMORY_NAMESPACE" ]]; then
			header_suffix=" [namespace: $MEMORY_NAMESPACE]"
		fi

		echo ""
		echo "=== Auto-Capture Log (last $limit)${header_suffix} ==="
		echo ""

		if [[ -z "$results" || "$results" == "[]" ]]; then
			log_info "No auto-captured memories yet."
			echo ""
			echo "Auto-capture stores memories when AI agents detect:"
			echo "  - Working solutions after debugging"
			echo "  - Failed approaches to avoid"
			echo "  - Architecture decisions"
			echo "  - Tool configurations"
			echo ""
			echo "Use --auto flag when storing: memory-helper.sh store --auto --content \"...\""
		else
			echo "$results" | format_results_text

			# Show summary
			local total_auto
			total_auto=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learning_access WHERE auto_captured = 1;")
			echo "---"
			echo "Total auto-captured: $total_auto"
		fi
	fi
	return 0
}
