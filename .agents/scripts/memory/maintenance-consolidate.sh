#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Maintenance -- Consolidation Sub-Library
# =============================================================================
# Provides consolidation functions for memory entries: merging similar memories
# based on word-overlap similarity to reduce redundancy.
#
# Usage: source "${SCRIPT_DIR}/maintenance-consolidate.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success, log_error)
#   - memory/_common.sh (db, init_db, MEMORY_DB, backup_sqlite_db,
#     cleanup_sqlite_backups)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_CONSOLIDATE_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_CONSOLIDATE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Show dry-run output for consolidation candidates
# Args: duplicates_str count
#######################################
_consolidate_dry_run() {
	local duplicates="$1"
	local count="$2"

	log_info "[DRY RUN] Found $count potential consolidation pairs:"
	echo ""
	echo "$duplicates" | while IFS='|' read -r id1 id2 type content1 content2 _created1 _created2; do
		echo "  [$type] #$id1 vs #$id2"
		echo "    1: $content1..."
		echo "    2: $content2..."
		echo ""
	done
	echo ""
	log_info "Run without --dry-run to consolidate"
	return 0
}

#######################################
# Merge a single consolidation pair (older survives, newer removed)
# Args: id1 id2 created1 created2
#######################################
_consolidate_merge_pair() {
	local id1="$1"
	local id2="$2"
	local created1="$3"
	local created2="$4"

	local older_id newer_id
	# shellcheck disable=SC2071 # Intentional lexicographic comparison for ISO date strings
	if [[ "$created1" < "$created2" ]]; then
		older_id="$id1"
		newer_id="$id2"
	else
		older_id="$id2"
		newer_id="$id1"
	fi

	local older_id_esc="${older_id//"'"/"''"}"
	local newer_id_esc="${newer_id//"'"/"''"}"

	# Merge tags from newer into older
	local older_tags newer_tags
	older_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$older_id_esc';")
	newer_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$newer_id_esc';")
	if [[ -n "$newer_tags" ]]; then
		local merged_tags
		merged_tags=$(echo "$older_tags,$newer_tags" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
		local merged_tags_esc="${merged_tags//"'"/"''"}"
		db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$older_id_esc';"
	fi

	# Transfer access history
	db "$MEMORY_DB" "UPDATE learning_access SET id = '$older_id_esc' WHERE id = '$newer_id_esc' AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$older_id_esc');" ||
		echo "[WARN] Failed to transfer access history from $newer_id_esc to $older_id_esc" >&2

	# Re-point relations and delete newer entry
	db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$older_id_esc' WHERE supersedes_id = '$newer_id_esc';"
	db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$newer_id_esc';"
	db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$newer_id_esc';"
	db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$newer_id_esc';"
	return 0
}

#######################################
# Query similar memory pairs from the database
# Args: similarity_threshold
# Outputs: duplicate pairs on stdout (pipe-separated)
#######################################
_consolidate_query_duplicates() {
	local similarity_threshold="$1"

	db "$MEMORY_DB" <<EOF
SELECT
    l1.id as id1,
    l2.id as id2,
    l1.type,
    substr(l1.content, 1, 50) as content1,
    substr(l2.content, 1, 50) as content2,
    l1.created_at as created1,
    l2.created_at as created2
FROM learnings l1
JOIN learnings l2 ON l1.type = l2.type
    AND l1.id < l2.id
    AND l1.content != l2.content
WHERE (
    (SELECT COUNT(*) FROM (
        SELECT value FROM json_each('["' || replace(lower(l1.content), ' ', '","') || '"]')
        INTERSECT
        SELECT value FROM json_each('["' || replace(lower(l2.content), ' ', '","') || '"]')
    )) * 2.0 / (
        length(l1.content) - length(replace(l1.content, ' ', '')) + 1 +
        length(l2.content) - length(replace(l2.content, ' ', '')) + 1
    ) > $similarity_threshold
)
LIMIT 20;
EOF
	return 0
}

#######################################
# Execute the consolidation merge loop
# Args: duplicates_str
# Outputs: number of consolidated pairs on stdout
#######################################
_consolidate_execute_merges() {
	local duplicates="$1"
	local consolidated=0
	# Track removed IDs to skip stale pairs from the static snapshot.
	# A result set like A|B, A|C, B|C would otherwise try to merge B|C after B
	# was already deleted, repointing relations to a non-existent keep row.
	# removed_set is newline-delimited; grep -qxF matches exact lines only.
	local removed_set=""

	while IFS='|' read -r id1 id2 _type _content1 _content2 created1 created2; do
		[[ -z "$id1" ]] && continue
		# Skip if either side was already removed by an earlier iteration
		printf '%s\n' "$removed_set" | grep -qxF "$id1" && continue
		printf '%s\n' "$removed_set" | grep -qxF "$id2" && continue
		_consolidate_merge_pair "$id1" "$id2" "$created1" "$created2"
		consolidated=$((consolidated + 1))
		# Record the deleted (older) ID so subsequent pairs skip it
		local _del_id
		# shellcheck disable=SC2071 # Intentional lexicographic comparison for ISO date strings
		if [[ "$created1" < "$created2" ]]; then
			_del_id="$id1"
		else
			_del_id="$id2"
		fi
		removed_set="${removed_set}
${_del_id}"
	done <<<"$duplicates"

	echo "$consolidated"
	return 0
}

#######################################
# Consolidate similar memories
# Merges memories with similar content to reduce redundancy
#######################################
cmd_consolidate() {
	local dry_run=false
	local similarity_threshold=0.5

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--threshold)
			if [[ $# -lt 2 ]]; then
				log_error "--threshold requires a value"
				return 1
			fi
			similarity_threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if ! [[ "$similarity_threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		log_error "--threshold must be a decimal number (e.g., 0.5)"
		return 1
	fi
	if ! awk "BEGIN { exit !($similarity_threshold >= 0 && $similarity_threshold <= 1) }"; then
		log_error "--threshold must be between 0 and 1"
		return 1
	fi

	init_db
	log_info "Analyzing memories for consolidation..."

	local duplicates
	duplicates=$(_consolidate_query_duplicates "$similarity_threshold")

	if [[ -z "$duplicates" ]]; then
		log_success "No similar memories found for consolidation"
		return 0
	fi

	local count
	count=$(echo "$duplicates" | wc -l | tr -d ' ')

	if [[ "$dry_run" == true ]]; then
		_consolidate_dry_run "$duplicates" "$count"
		return 0
	fi

	# Backup before consolidation deletes (t188)
	local consolidate_backup
	consolidate_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-consolidate")
	if [[ $? -ne 0 || -z "$consolidate_backup" ]]; then
		log_warn "Backup failed before consolidation -- proceeding cautiously"
	fi

	local consolidated
	consolidated=$(_consolidate_execute_merges "$duplicates")

	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
	log_success "Consolidated $consolidated memory pairs"
	cleanup_sqlite_backups "$MEMORY_DB" 5
	return 0
}
