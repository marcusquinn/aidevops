#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Maintenance -- Pruning Sub-Library
# =============================================================================
# Provides pruning functions for memory entries: age-based, AI-judged, and
# pattern-based pruning of stale or repetitive entries.
#
# Usage: source "${SCRIPT_DIR}/maintenance-prune.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success, log_error)
#   - memory/_common.sh (db, db_cleanup, init_db, MEMORY_DB, DEFAULT_MAX_AGE_DAYS,
#     VALID_TYPES, backup_sqlite_db, cleanup_sqlite_backups)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_PRUNE_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_PRUNE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Prune old/stale entries
# With --ai-judged: uses AI to evaluate each candidate entry's relevance
# instead of a flat age cutoff. Falls back to type-aware heuristics.
# Without --ai-judged: uses the original flat age threshold (DEFAULT_MAX_AGE_DAYS).
#######################################
cmd_prune() {
	local older_than_days=$DEFAULT_MAX_AGE_DAYS
	local dry_run=false
	local keep_accessed=true
	local ai_judged=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than-days)
			older_than_days="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--include-accessed)
			keep_accessed=false
			shift
			;;
		--ai-judged)
			ai_judged=true
			shift
			;;
		*) shift ;;
		esac
	done

	init_db

	# Validate older_than_days is a positive integer
	if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
		log_error "--older-than-days must be a positive integer"
		return 1
	fi

	if [[ "$ai_judged" == true ]]; then
		_prune_ai_judged "$older_than_days" "$dry_run" "$keep_accessed"
	else
		_prune_flat_threshold "$older_than_days" "$dry_run" "$keep_accessed"
	fi

	return 0
}

#######################################
# AI-judged prune: evaluate each candidate individually
# Uses ai-threshold-judge.sh for borderline entries
#######################################
_prune_ai_judged() {
	local older_than_days="$1"
	local dry_run="$2"
	local keep_accessed="$3"

	local threshold_judge
	threshold_judge="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-threshold-judge.sh"

	if [[ ! -x "$threshold_judge" ]]; then
		log_warn "ai-threshold-judge.sh not found -- falling back to flat threshold"
		_prune_flat_threshold "$older_than_days" "$dry_run" "$keep_accessed"
		return 0
	fi

	# Use a lower minimum age (60 days) -- the AI judge decides the rest
	local min_age=60
	if [[ "$older_than_days" -lt "$min_age" ]]; then
		min_age="$older_than_days"
	fi

	local candidates
	if [[ "$keep_accessed" == true ]]; then
		candidates=$(db "$MEMORY_DB" "SELECT l.id, l.type, l.confidence, substr(l.content, 1, 300), CAST(julianday('now') - julianday(l.created_at) AS INTEGER) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$min_age days') AND a.id IS NULL;")
	else
		candidates=$(db "$MEMORY_DB" "SELECT l.id, l.type, l.confidence, substr(l.content, 1, 300), CAST(julianday('now') - julianday(l.created_at) AS INTEGER), CASE WHEN a.id IS NOT NULL THEN 'true' ELSE 'false' END FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$min_age days');")
	fi

	if [[ -z "$candidates" ]]; then
		log_success "No entries to prune"
		return 0
	fi

	local prune_count=0
	local keep_count=0
	local prune_ids=""

	while IFS='|' read -r mem_id mem_type mem_confidence mem_content age_days accessed_flag; do
		[[ -z "$mem_id" ]] && continue
		local accessed="${accessed_flag:-false}"

		local verdict
		verdict=$("$threshold_judge" judge-prune-relevance \
			--content "$mem_content" \
			--age-days "$age_days" \
			--type "$mem_type" \
			--accessed "$accessed" \
			--confidence "${mem_confidence:-medium}" 2>/dev/null || echo "keep")

		if [[ "$verdict" == "prune" ]]; then
			if [[ "$dry_run" == true ]]; then
				log_info "[DRY RUN] Would prune $mem_id ($mem_type, ${age_days}d): ${mem_content:0:50}..."
			fi
			if [[ -n "$prune_ids" ]]; then
				prune_ids="${prune_ids},'${mem_id//\'/\'\'}'"
			else
				prune_ids="'${mem_id//\'/\'\'}'"
			fi
			prune_count=$((prune_count + 1))
		else
			keep_count=$((keep_count + 1))
		fi
	done <<<"$candidates"

	if [[ "$prune_count" -eq 0 ]]; then
		log_success "No entries to prune (AI judge kept all $keep_count candidates)"
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Would prune $prune_count entries (AI judge kept $keep_count)"
		return 0
	fi

	# Backup before bulk delete
	local prune_backup
	prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune -- proceeding cautiously"
	fi

	db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($prune_ids);"
	db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($prune_ids);"
	db_cleanup "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($prune_ids);"
	db_cleanup "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($prune_ids);"

	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
	log_success "Pruned $prune_count entries (AI-judged, kept $keep_count)"
	log_info "Rebuilt search index"

	cleanup_sqlite_backups "$MEMORY_DB" 5
	return 0
}

#######################################
# Flat threshold prune: original behavior (age-based cutoff)
#######################################
_prune_flat_threshold() {
	local older_than_days="$1"
	local dry_run="$2"
	local keep_accessed="$3"

	# Build query to find stale entries
	local count
	if [[ "$keep_accessed" == true ]]; then
		count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL;")
	else
		count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE created_at < datetime('now', '-$older_than_days days');")
	fi

	if [[ "$count" -eq 0 ]]; then
		log_success "No entries to prune"
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Would delete $count entries"
		echo ""
		if [[ "$keep_accessed" == true ]]; then
			db "$MEMORY_DB" <<EOF
SELECT l.id, l.type, substr(l.content, 1, 50) || '...' as preview, l.created_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL
LIMIT 20;
EOF
		else
			db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 50) || '...' as preview, created_at
FROM learnings 
WHERE created_at < datetime('now', '-$older_than_days days')
LIMIT 20;
EOF
		fi
		return 0
	fi

	# Backup before bulk delete (t188)
	local prune_backup
	prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune -- proceeding cautiously"
	fi

	# Use efficient single DELETE with subquery
	local subquery
	if [[ "$keep_accessed" == true ]]; then
		subquery="SELECT l.id FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL"
	else
		subquery="SELECT id FROM learnings WHERE created_at < datetime('now', '-$older_than_days days')"
	fi

	# Delete from all tables using the subquery (much faster than loop)
	# Clean up relations first to avoid orphaned references
	db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($subquery);"
	db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($subquery);"
	db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($subquery);"
	db "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($subquery);"

	log_success "Pruned $count stale entries"

	# Rebuild FTS index
	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
	log_info "Rebuilt search index"

	# Clean up old backups (t188)
	cleanup_sqlite_backups "$MEMORY_DB" 5
	return 0
}

#######################################
# Build validated SQL IN-list for type filter
# Args: types_csv (comma-separated type names)
# Outputs: SQL fragment on stdout, e.g. 'TYPE_A','TYPE_B'
# Returns 1 on invalid type
#######################################
_prune_patterns_build_type_sql() {
	local types_csv="$1"

	local IFS=','
	local type_parts=()
	read -ra type_parts <<<"$types_csv"
	unset IFS

	local type_conditions=()
	for t in "${type_parts[@]}"; do
		local valid=false
		for vt in $VALID_TYPES; do
			if [[ "$t" == "$vt" ]]; then
				valid=true
				break
			fi
		done
		if [[ "$valid" != true ]]; then
			log_error "Invalid type '$t'. Valid types: $VALID_TYPES"
			return 1
		fi
		type_conditions+=("'$t'")
	done

	if [[ ${#type_conditions[@]} -eq 0 ]]; then
		log_error "No valid types specified"
		return 1
	fi

	local type_sql
	type_sql=$(printf "%s," "${type_conditions[@]}")
	echo "${type_sql%,}"
	return 0
}

#######################################
# Show dry-run preview for prune-patterns
# Args: type_sql escaped_keyword keep_count to_remove
#######################################
_prune_patterns_dry_run() {
	local type_sql="$1"
	local escaped_keyword="$2"
	local keep_count="$3"
	local to_remove="$4"

	log_info "[DRY RUN] Would remove $to_remove entries. Entries to keep:"
	db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 80) || '...' as preview, created_at
FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT $keep_count;
EOF
	echo ""
	log_info "[DRY RUN] Sample entries to remove:"
	db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 80) || '...' as preview, created_at
FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT 5 OFFSET $keep_count;
EOF
	return 0
}

#######################################
# Execute the prune-patterns deletion
# Args: type_sql escaped_keyword keep_count to_remove keyword
#######################################
_prune_patterns_execute() {
	local type_sql="$1"
	local escaped_keyword="$2"
	local keep_count="$3"
	local to_remove="$4"
	local keyword="$5"

	local prune_backup
	prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune-patterns")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune-patterns -- proceeding cautiously"
	fi

	local keep_ids
	keep_ids=$(
		db "$MEMORY_DB" <<EOF
SELECT id FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT $keep_count;
EOF
	)

	local exclude_sql=""
	while IFS= read -r kid; do
		[[ -z "$kid" ]] && continue
		local kid_esc="${kid//"'"/"''"}"
		if [[ -z "$exclude_sql" ]]; then
			exclude_sql="'$kid_esc'"
		else
			exclude_sql="$exclude_sql,'$kid_esc'"
		fi
	done <<<"$keep_ids"

	local delete_where="type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'"
	if [[ -n "$exclude_sql" ]]; then
		delete_where="$delete_where AND id NOT IN ($exclude_sql)"
	fi

	db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN (SELECT id FROM learnings WHERE $delete_where);"
	db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN (SELECT id FROM learnings WHERE $delete_where);"
	db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN (SELECT id FROM learnings WHERE $delete_where);"
	db "$MEMORY_DB" "DELETE FROM learnings WHERE $delete_where;"
	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"

	log_success "Pruned $to_remove repetitive '$keyword' entries (kept $keep_count newest)"
	cleanup_sqlite_backups "$MEMORY_DB" 5
	return 0
}

#######################################
# Prune repetitive pattern entries by keyword (t230)
# Consolidates entries where the same error/pattern keyword appears
# across many tasks, keeping only a few representative entries
#######################################
cmd_prune_patterns() {
	local keyword=""
	local dry_run=false
	local keep_count=3
	local types="FAILURE_PATTERN,ERROR_FIX,FAILED_APPROACH"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--keyword)
			keyword="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--keep)
			keep_count="$2"
			shift 2
			;;
		--types)
			types="$2"
			shift 2
			;;
		*)
			if [[ -z "$keyword" ]]; then
				keyword="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$keyword" ]]; then
		log_error "Usage: memory-helper.sh prune-patterns <keyword> [--keep N] [--dry-run]"
		log_error "Example: memory-helper.sh prune-patterns clean_exit_no_signal --keep 3"
		return 1
	fi

	if ! [[ "$keep_count" =~ ^[1-9][0-9]*$ ]]; then
		log_error "--keep must be a positive integer (got: $keep_count)"
		return 1
	fi

	init_db

	local type_sql
	type_sql=$(_prune_patterns_build_type_sql "$types") || return 1

	local escaped_keyword="${keyword//"'"/"''"}"
	local total_count
	total_count=$(db "$MEMORY_DB" \
		"SELECT COUNT(*) FROM learnings WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%';")

	if [[ "$total_count" -le "$keep_count" ]]; then
		log_success "Only $total_count entries match '$keyword' (keep=$keep_count). Nothing to prune."
		return 0
	fi

	local to_remove=$((total_count - keep_count))
	log_info "Found $total_count entries matching '$keyword' across types ($types)"
	log_info "Will keep $keep_count newest entries, remove $to_remove"

	if [[ "$dry_run" == true ]]; then
		_prune_patterns_dry_run "$type_sql" "$escaped_keyword" "$keep_count" "$to_remove"
		return 0
	fi

	_prune_patterns_execute "$type_sql" "$escaped_keyword" "$keep_count" "$to_remove" "$keyword"
	return 0
}
