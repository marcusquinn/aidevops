#!/usr/bin/env bash
# memory/maintenance.sh - Memory maintenance functions
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_stats, cmd_validate, cmd_dedup, cmd_prune, cmd_consolidate,
#           cmd_prune_patterns, cmd_export, cmd_namespaces, cmd_namespaces_prune,
#           cmd_namespaces_migrate, cmd_log

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_LOADED=1

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
# Merge tags from remove_id into keep_id (shared by all dedup phases)
# Args: keep_id_esc remove_id_esc
#######################################
_dedup_merge_tags() {
	local keep_id_esc="$1"
	local remove_id_esc="$2"

	local keep_tags remove_tags
	keep_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$keep_id_esc';")
	remove_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$remove_id_esc';")
	if [[ -n "$remove_tags" ]]; then
		local merged_tags
		merged_tags=$(echo "$keep_tags,$remove_tags" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
		local merged_tags_esc="${merged_tags//"'"/"''"}"
		db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$keep_id_esc';"
	fi
	return 0
}

#######################################
# Phase 1: Remove exact duplicate entries (same content string)
# Args: dry_run
# Outputs: number of removed entries on stdout
#######################################
_dedup_exact_phase() {
	local dry_run="$1"
	local exact_removed=0

	local exact_groups
	exact_groups=$(
		db "$MEMORY_DB" <<'EOF'
SELECT GROUP_CONCAT(id, '|') as ids, content, type, COUNT(*) as cnt
FROM learnings
GROUP BY content
HAVING cnt > 1
ORDER BY cnt DESC;
EOF
	)

	[[ -z "$exact_groups" ]] && echo "$exact_removed" && return 0

	local dup_contents
	dup_contents=$(db "$MEMORY_DB" "SELECT content FROM learnings GROUP BY content HAVING COUNT(*) > 1;")

	while IFS= read -r dup_content; do
		[[ -z "$dup_content" ]] && continue
		local escaped_dup="${dup_content//"'"/"''"}"
		local all_ids
		all_ids=$(db "$MEMORY_DB" "SELECT id FROM learnings WHERE content = '$escaped_dup' ORDER BY created_at ASC;")

		local keep_id=""
		while IFS= read -r mem_id; do
			[[ -z "$mem_id" ]] && continue
			if [[ -z "$keep_id" ]]; then
				keep_id="$mem_id"
				continue
			fi
			local escaped_keep="${keep_id//"'"/"''"}"
			local escaped_remove="${mem_id//"'"/"''"}"

			if [[ "$dry_run" == true ]]; then
				log_info "[DRY RUN] Would remove $mem_id (duplicate of $keep_id)"
			else
				_dedup_merge_tags "$escaped_keep" "$escaped_remove"
				# Transfer access history (keep higher count)
				db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
SELECT '$escaped_keep', last_accessed_at, access_count
FROM learning_access WHERE id = '$escaped_remove'
AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$escaped_keep')
ON CONFLICT(id) DO UPDATE SET
    access_count = MAX(learning_access.access_count, excluded.access_count),
    last_accessed_at = MAX(learning_access.last_accessed_at, excluded.last_accessed_at);
EOF
				db_cleanup "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$escaped_keep' WHERE supersedes_id = '$escaped_remove';"
				db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$escaped_remove';"
				db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$escaped_remove';"
				db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$escaped_remove';"
			fi
			exact_removed=$((exact_removed + 1))
		done <<<"$all_ids"
	done <<<"$dup_contents"

	echo "$exact_removed"
	return 0
}

#######################################
# Phase 2: Remove near-duplicate entries (normalized content match)
# Args: dry_run
# Outputs: number of removed entries on stdout
#######################################
_dedup_near_phase() {
	local dry_run="$1"
	local near_removed=0

	local near_groups
	near_groups=$(
		db "$MEMORY_DB" <<'EOF'
SELECT GROUP_CONCAT(id, ',') as ids,
       replace(replace(replace(replace(replace(lower(content),
           '.',''),"'",''),',',''),'!',''),'?','') as norm,
       COUNT(*) as cnt
FROM learnings
GROUP BY norm
HAVING cnt > 1
ORDER BY cnt DESC;
EOF
	)

	[[ -z "$near_groups" ]] && echo "$near_removed" && return 0

	while IFS='|' read -r id_list _norm _cnt; do
		[[ -z "$id_list" ]] && continue
		local id_count
		id_count=$(echo "$id_list" | tr ',' '\n' | wc -l | tr -d ' ')
		[[ "$id_count" -le 1 ]] && continue

		local ids_arr
		IFS=',' read -ra ids_arr <<<"$id_list"

		# Find the oldest entry to keep
		local oldest_id="" oldest_date="9999"
		for nid in "${ids_arr[@]}"; do
			[[ -z "$nid" ]] && continue
			local nid_esc="${nid//"'"/"''"}"
			local nid_exists
			nid_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "0")
			[[ "$nid_exists" == "0" ]] && continue
			local nid_date
			nid_date=$(db "$MEMORY_DB" "SELECT created_at FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "9999")
			# shellcheck disable=SC2071 # Intentional lexicographic comparison for ISO date strings
			if [[ "$nid_date" < "$oldest_date" ]]; then
				oldest_date="$nid_date"
				oldest_id="$nid"
			fi
		done
		[[ -z "$oldest_id" ]] && continue

		local oldest_esc="${oldest_id//"'"/"''"}"
		for nid in "${ids_arr[@]}"; do
			[[ -z "$nid" || "$nid" == "$oldest_id" ]] && continue
			local nid_esc="${nid//"'"/"''"}"
			local nid_exists
			nid_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "0")
			[[ "$nid_exists" == "0" ]] && continue

			if [[ "$dry_run" == true ]]; then
				local preview
				preview=$(db "$MEMORY_DB" "SELECT substr(content, 1, 50) FROM learnings WHERE id = '$nid_esc';")
				log_info "[DRY RUN] Would remove near-dup $nid (keep $oldest_id): $preview..."
			else
				_dedup_merge_tags "$oldest_esc" "$nid_esc"
				db_cleanup "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$oldest_esc' WHERE supersedes_id = '$nid_esc';"
				db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$nid_esc';"
				db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$nid_esc';"
				db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$nid_esc';"
			fi
			near_removed=$((near_removed + 1))
		done
	done <<<"$near_groups"

	echo "$near_removed"
	return 0
}

#######################################
# Phase 3: Remove semantic duplicates (AI-judged similarity)
# Only called when --semantic flag is set (~$0.001/pair API cost)
# Args: dry_run threshold_judge
# Outputs: number of removed entries on stdout
#######################################
_dedup_semantic_phase() {
	local dry_run="$1"
	local threshold_judge="$2"
	local semantic_removed=0

	log_info "Scanning for semantic duplicates (AI-judged)..."

	local types
	types=$(db "$MEMORY_DB" "SELECT DISTINCT type FROM learnings;")

	while IFS= read -r check_type; do
		[[ -z "$check_type" ]] && continue
		local type_esc="${check_type//"'"/"''"}"
		local entries
		entries=$(db "$MEMORY_DB" "SELECT id, substr(content, 1, 200), created_at FROM learnings WHERE type = '$type_esc' ORDER BY created_at ASC LIMIT 50;")

		local ids_arr=() contents_arr=()
		while IFS='|' read -r eid econtent _edate; do
			[[ -z "$eid" ]] && continue
			ids_arr+=("$eid")
			contents_arr+=("$econtent")
		done <<<"$entries"

		local len=${#ids_arr[@]}
		local removed_set=""
		for ((i = 0; i < len; i++)); do
			echo "$removed_set" | grep -qF "${ids_arr[$i]}" && continue
			for ((j = i + 1; j < len; j++)); do
				echo "$removed_set" | grep -qF "${ids_arr[$j]}" && continue
				local verdict
				verdict=$("$threshold_judge" judge-dedup-similarity \
					--content-a "${contents_arr[$i]}" \
					--content-b "${contents_arr[$j]}" 2>/dev/null || echo "distinct")
				if [[ "$verdict" == "duplicate" ]]; then
					local remove_id="${ids_arr[$j]}"
					local keep_id="${ids_arr[$i]}"
					local remove_esc="${remove_id//"'"/"''"}"
					local keep_esc="${keep_id//"'"/"''"}"
					if [[ "$dry_run" == true ]]; then
						log_info "[DRY RUN] Semantic dup: remove $remove_id (keep $keep_id): ${contents_arr[$j]:0:50}..."
					else
						_dedup_merge_tags "$keep_esc" "$remove_esc"
						db_cleanup "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$keep_esc' WHERE supersedes_id = '$remove_esc';"
						db_cleanup "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$remove_esc';"
						db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$remove_esc';"
						db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$remove_esc';"
					fi
					semantic_removed=$((semantic_removed + 1))
					removed_set="${removed_set} ${remove_id}"
				fi
			done
		done
	done <<<"$types"

	echo "$semantic_removed"
	return 0
}

#######################################
# Deduplicate memories
# Removes exact, near-duplicate, and semantic duplicate entries.
# Keeps the oldest (most established) entry; merges tags from removed entries.
#
# Phases:
#   1. Exact duplicates (same content string)
#   2. Near-duplicates (normalized content match — punctuation removed)
#   3. Semantic duplicates (AI-judged similarity via ai-threshold-judge.sh)
#      Only runs with --semantic flag to control API costs (~$0.001/pair)
#######################################
cmd_dedup() {
	local dry_run=false
	local include_near=true
	local include_semantic=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--exact-only)
			include_near=false
			shift
			;;
		--semantic)
			include_semantic=true
			shift
			;;
		*) shift ;;
		esac
	done

	init_db
	log_info "Scanning for duplicate memories..."

	local exact_removed
	exact_removed=$(_dedup_exact_phase "$dry_run")

	local near_removed=0
	if [[ "$include_near" == true ]]; then
		near_removed=$(_dedup_near_phase "$dry_run")
	fi

	local semantic_removed=0
	if [[ "$include_semantic" == true ]]; then
		local threshold_judge
		threshold_judge="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-threshold-judge.sh"
		if [[ -x "$threshold_judge" ]]; then
			semantic_removed=$(_dedup_semantic_phase "$dry_run" "$threshold_judge")
		else
			log_warn "ai-threshold-judge.sh not found — skipping semantic dedup"
		fi
	fi

	local total_removed=$((exact_removed + near_removed + semantic_removed))

	if [[ "$total_removed" -eq 0 ]]; then
		log_success "No duplicates found"
	elif [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Would remove $total_removed duplicates ($exact_removed exact, $near_removed near, $semantic_removed semantic)"
	else
		db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
		log_success "Removed $total_removed duplicates ($exact_removed exact, $near_removed near, $semantic_removed semantic)"
	fi

	return 0
}

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
		log_warn "ai-threshold-judge.sh not found — falling back to flat threshold"
		_prune_flat_threshold "$older_than_days" "$dry_run" "$keep_accessed"
		return 0
	fi

	# Use a lower minimum age (60 days) — the AI judge decides the rest
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
		log_warn "Backup failed before prune — proceeding cautiously"
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
		log_warn "Backup failed before prune — proceeding cautiously"
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
		log_warn "Backup failed before consolidation — proceeding cautiously"
	fi

	local consolidated
	consolidated=$(_consolidate_execute_merges "$duplicates")

	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
	log_success "Consolidated $consolidated memory pairs"
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
		log_warn "Backup failed before prune-patterns — proceeding cautiously"
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
# List all memory namespaces
#######################################
cmd_namespaces() {
	local output_format="table"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			output_format="$2"
			shift 2
			;;
		--json)
			output_format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	local ns_dir="$MEMORY_BASE_DIR/namespaces"

	if [[ ! -d "$ns_dir" ]]; then
		log_info "No namespaces configured"
		echo ""
		echo "Create one with:"
		echo "  memory-helper.sh --namespace my-runner store --content \"learning\""
		return 0
	fi

	local namespaces
	namespaces=$(find "$ns_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

	if [[ -z "$namespaces" ]]; then
		log_info "No namespaces configured"
		return 0
	fi

	if [[ "$output_format" == "json" ]]; then
		echo "["
		local first=true
		for ns_path in $namespaces; do
			local ns_name
			ns_name=$(basename "$ns_path")
			local ns_db="$ns_path/memory.db"
			local count=0
			if [[ -f "$ns_db" ]]; then
				count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
			fi
			if [[ "$first" == true ]]; then
				first=false
			else
				echo ","
			fi
			printf '  {"namespace": "%s", "entries": %d, "path": "%s"}' "$ns_name" "$count" "$ns_path"
		done
		echo ""
		echo "]"
		return 0
	fi

	echo ""
	echo "=== Memory Namespaces ==="
	echo ""

	# Global DB stats
	local global_db
	global_db=$(global_db_path)
	local global_count=0
	if [[ -f "$global_db" ]]; then
		global_count=$(db "$global_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
	fi
	printf "  %-25s %s entries\n" "(global)" "$global_count"

	for ns_path in $namespaces; do
		local ns_name
		ns_name=$(basename "$ns_path")
		local ns_db="$ns_path/memory.db"
		local count=0
		if [[ -f "$ns_db" ]]; then
			count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
		fi
		printf "  %-25s %s entries\n" "$ns_name" "$count"
	done

	echo ""
	return 0
}

#######################################
# Prune orphaned namespaces
# Removes namespace directories that have no matching runner
#######################################
cmd_namespaces_prune() {
	local dry_run=false
	local runners_dir="${AIDEVOPS_RUNNERS_DIR:-$HOME/.aidevops/.agent-workspace/runners}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	local ns_dir="$MEMORY_BASE_DIR/namespaces"

	if [[ ! -d "$ns_dir" ]]; then
		log_info "No namespaces to prune"
		return 0
	fi

	local namespaces
	namespaces=$(find "$ns_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

	if [[ -z "$namespaces" ]]; then
		log_info "No namespaces to prune"
		return 0
	fi

	local orphaned=0
	local kept=0

	for ns_path in $namespaces; do
		local ns_name
		ns_name=$(basename "$ns_path")
		local runner_path="$runners_dir/$ns_name"

		if [[ -d "$runner_path" && -f "$runner_path/config.json" ]]; then
			kept=$((kept + 1))
			continue
		fi

		local ns_db="$ns_path/memory.db"
		local count=0
		if [[ -f "$ns_db" ]]; then
			count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
		fi

		if [[ "$dry_run" == true ]]; then
			log_warn "[DRY RUN] Would remove orphaned namespace: $ns_name ($count entries)"
		else
			rm -rf "$ns_path"
			log_info "Removed orphaned namespace: $ns_name ($count entries)"
		fi
		orphaned=$((orphaned + 1))
	done

	if [[ "$orphaned" -eq 0 ]]; then
		log_success "No orphaned namespaces found ($kept active)"
	elif [[ "$dry_run" == true ]]; then
		log_warn "[DRY RUN] Would remove $orphaned orphaned namespaces ($kept active)"
	else
		log_success "Removed $orphaned orphaned namespaces ($kept active)"
	fi

	return 0
}

#######################################
# Resolve source and target DB paths for namespace migration
# Args: from_ns to_ns
# Outputs: "from_db|to_db|to_dir" on stdout
# Returns 1 if source DB does not exist
#######################################
_migrate_resolve_dbs() {
	local from_ns="$1"
	local to_ns="$2"

	local from_db
	if [[ "$from_ns" == "global" ]]; then
		from_db="$MEMORY_BASE_DIR/memory.db"
	else
		from_db="$MEMORY_BASE_DIR/namespaces/$from_ns/memory.db"
	fi

	if [[ ! -f "$from_db" ]]; then
		log_error "Source not found: $from_db"
		return 1
	fi

	local to_db to_dir
	if [[ "$to_ns" == "global" ]]; then
		to_db="$MEMORY_BASE_DIR/memory.db"
		to_dir="$MEMORY_BASE_DIR"
	else
		to_dir="$MEMORY_BASE_DIR/namespaces/$to_ns"
		to_db="$to_dir/memory.db"
	fi

	echo "${from_db}|${to_db}|${to_dir}"
	return 0
}

#######################################
# Copy entries from source DB to target DB using ATTACH DATABASE
# Args: from_db to_db to_dir from_ns to_ns count
#######################################
_migrate_execute() {
	local from_db="$1"
	local to_db="$2"
	local to_dir="$3"
	local _from_ns="$4"
	local to_ns="$5"
	local count="$6"

	mkdir -p "$to_dir"
	local saved_dir="$MEMORY_DIR"
	local saved_db="$MEMORY_DB"
	MEMORY_DIR="$to_dir"
	MEMORY_DB="$to_db"
	init_db
	MEMORY_DIR="$saved_dir"
	MEMORY_DB="$saved_db"

	db "$to_db" <<EOF
ATTACH DATABASE '$from_db' AS source;

-- Wrap all three INSERTs in a transaction so either all tables are migrated
-- or none are, preventing partial copies (learnings without relations, etc.).
BEGIN TRANSACTION;

INSERT OR IGNORE INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
SELECT id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source
FROM source.learnings;

INSERT OR IGNORE INTO learning_access (id, last_accessed_at, access_count)
SELECT id, last_accessed_at, access_count
FROM source.learning_access;

INSERT OR IGNORE INTO learning_relations (id, supersedes_id, relation_type, created_at)
SELECT id, supersedes_id, relation_type, created_at
FROM source.learning_relations;

COMMIT;

DETACH DATABASE source;
EOF

	log_success "Migrated $count entries to '$to_ns'"
	return 0
}

#######################################
# Clear source DB after a --move migration (with backup)
# Args: from_db to_ns
#######################################
_migrate_move_source() {
	local from_db="$1"
	local to_ns="$2"

	backup_sqlite_db "$from_db" "pre-move-to-${to_ns}" >/dev/null 2>&1 ||
		log_warn "Backup of source failed before move"

	# All DELETEs in a single transaction for atomicity (GH#3776)
	db "$from_db" <<'EOF'
BEGIN TRANSACTION;
DELETE FROM learning_relations;
DELETE FROM learning_access;
DELETE FROM learnings;
INSERT INTO learnings(learnings) VALUES('rebuild');
COMMIT;
EOF
	return 0
}

#######################################
# Migrate memories between namespaces
# Copies entries from one namespace (or global) to another
#######################################
cmd_namespaces_migrate() {
	local from_ns=""
	local to_ns=""
	local dry_run=false
	local move=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--from)
			from_ns="$2"
			shift 2
			;;
		--to)
			to_ns="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--move)
			move=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$from_ns" || -z "$to_ns" ]]; then
		log_error "Both --from and --to are required"
		echo "Usage: memory-helper.sh namespaces migrate --from <ns|global> --to <ns|global> [--dry-run] [--move]"
		return 1
	fi

	local db_paths
	db_paths=$(_migrate_resolve_dbs "$from_ns" "$to_ns") || return 1

	local from_db to_db to_dir
	IFS='|' read -r from_db to_db to_dir <<<"$db_paths"

	local count
	count=$(db "$from_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		log_info "No entries to migrate from $from_ns"
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Would migrate $count entries from '$from_ns' to '$to_ns'"
		if [[ "$move" == true ]]; then
			log_info "[DRY RUN] Would delete entries from source after migration"
		fi
		return 0
	fi

	_migrate_execute "$from_db" "$to_db" "$to_dir" "$from_ns" "$to_ns" "$count"

	if [[ "$move" == true ]]; then
		_migrate_move_source "$from_db" "$to_ns"
		log_info "Cleared source: $from_ns"
	fi

	return 0
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
