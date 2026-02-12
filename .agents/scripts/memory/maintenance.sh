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
	superseded_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learning_relations WHERE relation_type = 'updates';" 2>/dev/null || echo "0")
	if [[ "$superseded_count" -gt 0 ]]; then
		log_info "$superseded_count memories have been superseded by newer versions"
	fi

	# Check database size
	local db_size
	db_size=$(du -h "$MEMORY_DB" | cut -f1)
	log_info "Database size: $db_size"
	return 0
}

#######################################
# Deduplicate memories
# Removes exact and near-duplicate entries, keeping the oldest (most established)
# Merges tags from removed entries into the surviving one
#######################################
cmd_dedup() {
	local dry_run=false
	local include_near=true

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
		*) shift ;;
		esac
	done

	init_db

	log_info "Scanning for duplicate memories..."

	# Phase 1: Exact duplicates (same content string)
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

	local exact_removed=0
	if [[ -n "$exact_groups" ]]; then
		# Query each duplicate group individually for reliable parsing
		local dup_contents
		dup_contents=$(db "$MEMORY_DB" "SELECT content FROM learnings GROUP BY content HAVING COUNT(*) > 1;")

		while IFS= read -r dup_content; do
			[[ -z "$dup_content" ]] && continue
			local escaped_dup="${dup_content//"'"/"''"}"

			# Get all IDs for this content, ordered by created_at (oldest first)
			local all_ids
			all_ids=$(db "$MEMORY_DB" "SELECT id FROM learnings WHERE content = '$escaped_dup' ORDER BY created_at ASC;")

			local keep_id=""
			while IFS= read -r mem_id; do
				[[ -z "$mem_id" ]] && continue
				if [[ -z "$keep_id" ]]; then
					keep_id="$mem_id"
					continue
				fi

				# This is a duplicate to remove
				local escaped_keep="${keep_id//"'"/"''"}"
				local escaped_remove="${mem_id//"'"/"''"}"

				if [[ "$dry_run" == true ]]; then
					log_info "[DRY RUN] Would remove $mem_id (duplicate of $keep_id)"
				else
					# Merge tags
					local keep_tags remove_tags
					keep_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$escaped_keep';")
					remove_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$escaped_remove';")
					if [[ -n "$remove_tags" ]]; then
						local merged_tags
						merged_tags=$(echo "$keep_tags,$remove_tags" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
						local merged_tags_esc="${merged_tags//"'"/"''"}"
						db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$escaped_keep';"
					fi

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

					# Re-point relations
					db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$escaped_keep' WHERE supersedes_id = '$escaped_remove';" 2>/dev/null || true
					db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$escaped_remove';" 2>/dev/null || true

					# Delete duplicate
					db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$escaped_remove';"
					db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$escaped_remove';"
				fi
				exact_removed=$((exact_removed + 1))
			done <<<"$all_ids"
		done <<<"$dup_contents"
	fi

	# Phase 2: Near-duplicates (normalized content match)
	local near_removed=0
	if [[ "$include_near" == true ]]; then
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

		if [[ -n "$near_groups" ]]; then
			while IFS='|' read -r id_list _norm _cnt; do
				[[ -z "$id_list" ]] && continue
				# Skip if this was already handled as an exact duplicate
				local id_count
				id_count=$(echo "$id_list" | tr ',' '\n' | wc -l | tr -d ' ')
				[[ "$id_count" -le 1 ]] && continue

				local ids_arr
				IFS=',' read -ra ids_arr <<<"$id_list"

				# Find the oldest entry to keep
				local oldest_id=""
				local oldest_date="9999"
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

				for nid in "${ids_arr[@]}"; do
					[[ -z "$nid" || "$nid" == "$oldest_id" ]] && continue
					local nid_esc="${nid//"'"/"''"}"
					local nid_exists
					nid_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "0")
					[[ "$nid_exists" == "0" ]] && continue

					local oldest_esc="${oldest_id//"'"/"''"}"

					if [[ "$dry_run" == true ]]; then
						local preview
						preview=$(db "$MEMORY_DB" "SELECT substr(content, 1, 50) FROM learnings WHERE id = '$nid_esc';")
						log_info "[DRY RUN] Would remove near-dup $nid (keep $oldest_id): $preview..."
					else
						# Merge tags
						local keep_tags remove_tags
						keep_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$oldest_esc';")
						remove_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$nid_esc';")
						if [[ -n "$remove_tags" ]]; then
							local merged_tags
							merged_tags=$(echo "$keep_tags,$remove_tags" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
							local merged_tags_esc="${merged_tags//"'"/"''"}"
							db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$oldest_esc';"
						fi

						# Re-point relations and delete
						db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$oldest_esc' WHERE supersedes_id = '$nid_esc';" 2>/dev/null || true
						db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$nid_esc';" 2>/dev/null || true
						db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$nid_esc';"
						db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$nid_esc';"
					fi
					near_removed=$((near_removed + 1))
				done
			done <<<"$near_groups"
		fi
	fi

	local total_removed=$((exact_removed + near_removed))

	if [[ "$total_removed" -eq 0 ]]; then
		log_success "No duplicates found"
	elif [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Would remove $total_removed duplicates ($exact_removed exact, $near_removed near)"
	else
		# Rebuild FTS index
		db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
		log_success "Removed $total_removed duplicates ($exact_removed exact, $near_removed near)"
	fi

	return 0
}

#######################################
# Prune old/stale entries
#######################################
cmd_prune() {
	local older_than_days=$DEFAULT_MAX_AGE_DAYS
	local dry_run=false
	local keep_accessed=true

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
		*) shift ;;
		esac
	done

	init_db

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
	else
		# Validate older_than_days is a positive integer
		if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
			log_error "--older-than-days must be a positive integer"
			return 1
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
	fi
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
			similarity_threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate similarity_threshold is a valid decimal
	if ! [[ "$similarity_threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		log_error "--threshold must be a decimal number (e.g., 0.5)"
		return 1
	fi

	init_db

	log_info "Analyzing memories for consolidation..."

	# Find potential duplicates using FTS5 similarity
	# Group by type and look for similar content
	local duplicates
	duplicates=$(
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
    -- Check for significant word overlap
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
	)

	if [[ -z "$duplicates" ]]; then
		log_success "No similar memories found for consolidation"
		return 0
	fi

	local count
	count=$(echo "$duplicates" | wc -l | tr -d ' ')

	if [[ "$dry_run" == true ]]; then
		log_info "[DRY RUN] Found $count potential consolidation pairs:"
		echo ""
		echo "$duplicates" | while IFS='|' read -r id1 id2 type content1 content2 created1 created2; do
			echo "  [$type] #$id1 vs #$id2"
			echo "    1: $content1..."
			echo "    2: $content2..."
			echo ""
		done
		echo ""
		log_info "Run without --dry-run to consolidate"
	else
		# Backup before consolidation deletes (t188)
		local consolidate_backup
		consolidate_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-consolidate")
		if [[ $? -ne 0 || -z "$consolidate_backup" ]]; then
			log_warn "Backup failed before consolidation — proceeding cautiously"
		fi

		local consolidated=0

		# Use here-string instead of pipe to avoid subshell variable scope issue
		while IFS='|' read -r id1 id2 type content1 content2 created1 created2; do
			[[ -z "$id1" ]] && continue

			# Keep the older entry (more established), merge tags
			local older_id newer_id
			if [[ "$created1" < "$created2" ]]; then
				older_id="$id1"
				newer_id="$id2"
			else
				older_id="$id2"
				newer_id="$id1"
			fi

			# Escape IDs for SQL injection prevention
			local older_id_esc="${older_id//"'"/"''"}"
			local newer_id_esc="${newer_id//"'"/"''"}"

			# Merge tags from newer into older
			local older_tags newer_tags
			older_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$older_id_esc';")
			newer_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$newer_id_esc';")

			if [[ -n "$newer_tags" ]]; then
				local merged_tags
				merged_tags=$(echo "$older_tags,$newer_tags" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
				# Escape merged_tags for SQL injection prevention
				local merged_tags_esc="${merged_tags//"'"/"''"}"
				db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$older_id_esc';"
			fi

			# Transfer access history
			db "$MEMORY_DB" "UPDATE learning_access SET id = '$older_id_esc' WHERE id = '$newer_id_esc' AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$older_id_esc');" || echo "[WARN] Failed to transfer access history from $newer_id_esc to $older_id_esc" >&2

			# Re-point relations that referenced the deleted memory to the surviving one
			db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$older_id_esc' WHERE supersedes_id = '$newer_id_esc';"
			db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$newer_id_esc';"

			# Delete the newer duplicate
			db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$newer_id_esc';"
			db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$newer_id_esc';"

			consolidated=$((consolidated + 1))
		done <<<"$duplicates"

		# Rebuild FTS index
		db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"

		log_success "Consolidated $consolidated memory pairs"

		# Clean up old backups (t188)
		cleanup_sqlite_backups "$MEMORY_DB" 5
	fi
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

	# Validate keep_count is a positive integer
	if ! [[ "$keep_count" =~ ^[1-9][0-9]*$ ]]; then
		log_error "--keep must be a positive integer (got: $keep_count)"
		return 1
	fi

	init_db

	# Build type filter SQL
	local type_sql=""
	local IFS=','
	local type_parts=()
	read -ra type_parts <<<"$types"
	unset IFS
	local type_conditions=()
	for t in "${type_parts[@]}"; do
		type_conditions+=("'$t'")
	done
	type_sql=$(printf "%s," "${type_conditions[@]}")
	type_sql="${type_sql%,}"

	local escaped_keyword="${keyword//"'"/"''"}"

	# Count matching entries
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
	fi

	# Backup before bulk delete
	local prune_backup
	prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune-patterns")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune-patterns — proceeding cautiously"
	fi

	# Get IDs to keep (newest N per type combination)
	local keep_ids
	keep_ids=$(
		db "$MEMORY_DB" <<EOF
SELECT id FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT $keep_count;
EOF
	)

	# Build exclusion list
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

	# Delete matching entries except the ones we're keeping
	local delete_where="type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'"
	if [[ -n "$exclude_sql" ]]; then
		delete_where="$delete_where AND id NOT IN ($exclude_sql)"
	fi

	# Clean up relations first
	db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN (SELECT id FROM learnings WHERE $delete_where);" 2>/dev/null || true
	db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN (SELECT id FROM learnings WHERE $delete_where);" 2>/dev/null || true
	db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN (SELECT id FROM learnings WHERE $delete_where);"
	db "$MEMORY_DB" "DELETE FROM learnings WHERE $delete_where;"

	# Rebuild FTS index
	db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"

	log_success "Pruned $to_remove repetitive '$keyword' entries (kept $keep_count newest)"

	# Clean up old backups
	cleanup_sqlite_backups "$MEMORY_DB" 5

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

	# Resolve source DB
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

	# Resolve target DB
	local to_db
	local to_dir
	if [[ "$to_ns" == "global" ]]; then
		to_db="$MEMORY_BASE_DIR/memory.db"
		to_dir="$MEMORY_BASE_DIR"
	else
		to_dir="$MEMORY_BASE_DIR/namespaces/$to_ns"
		to_db="$to_dir/memory.db"
	fi

	# Count entries to migrate
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

	# Ensure target DB exists with correct schema
	mkdir -p "$to_dir"
	local saved_dir="$MEMORY_DIR"
	local saved_db="$MEMORY_DB"
	MEMORY_DIR="$to_dir"
	MEMORY_DB="$to_db"
	init_db
	MEMORY_DIR="$saved_dir"
	MEMORY_DB="$saved_db"

	# Migrate using ATTACH DATABASE
	db "$to_db" <<EOF
ATTACH DATABASE '$from_db' AS source;

-- Insert entries that don't already exist (by id)
INSERT OR IGNORE INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
SELECT id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source
FROM source.learnings;

-- Migrate access tracking
INSERT OR IGNORE INTO learning_access (id, last_accessed_at, access_count)
SELECT id, last_accessed_at, access_count
FROM source.learning_access;

-- Migrate relations
INSERT OR IGNORE INTO learning_relations (id, supersedes_id, relation_type, created_at)
SELECT id, supersedes_id, relation_type, created_at
FROM source.learning_relations;

DETACH DATABASE source;
EOF

	log_success "Migrated $count entries from '$from_ns' to '$to_ns'"

	# If --move, delete from source (with backup — t188)
	if [[ "$move" == true ]]; then
		backup_sqlite_db "$from_db" "pre-move-to-${to_ns}" >/dev/null 2>&1 || log_warn "Backup of source failed before move"
		db "$from_db" "DELETE FROM learning_relations;"
		db "$from_db" "DELETE FROM learning_access;"
		db "$from_db" "DELETE FROM learnings;"
		db "$from_db" "INSERT INTO learnings(learnings) VALUES('rebuild');"
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
