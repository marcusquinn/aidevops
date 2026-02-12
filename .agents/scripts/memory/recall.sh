#!/usr/bin/env bash
# memory/recall.sh - Memory recall/search functions
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_recall, cmd_history, cmd_latest

# Include guard
[[ -n "${_MEMORY_RECALL_LOADED:-}" ]] && return 0
_MEMORY_RECALL_LOADED=1

#######################################
# Recall learnings with search
#######################################
cmd_recall() {
	local query=""
	local limit=5
	local type_filter=""
	local max_age_days=""
	local project_filter=""
	local format="text"
	local recent_mode=false
	local semantic_mode=false
	local hybrid_mode=false
	local shared_mode=false
	local auto_only=false
	local manual_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--query | -q)
			query="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--type | -t)
			type_filter="$2"
			shift 2
			;;
		--max-age-days)
			max_age_days="$2"
			shift 2
			;;
		--project | -p)
			project_filter="$2"
			shift 2
			;;
		--recent)
			recent_mode=true
			limit="${2:-10}"
			shift
			[[ "${1:-}" =~ ^[0-9]+$ ]] && shift
			;;
		--semantic | --similar)
			semantic_mode=true
			shift
			;;
		--hybrid)
			hybrid_mode=true
			shift
			;;
		--shared)
			shared_mode=true
			shift
			;;
		--auto-only)
			auto_only=true
			shift
			;;
		--manual-only)
			manual_only=true
			shift
			;;
		--format)
			format="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--stats)
			cmd_stats
			return 0
			;;
		*)
			# Allow query as positional argument
			if [[ -z "$query" ]]; then
				query="$1"
			fi
			shift
			;;
		esac
	done

	init_db

	# Build auto-capture filter clause
	local auto_filter=""
	if [[ "$auto_only" == true ]]; then
		auto_filter="AND COALESCE(a.auto_captured, 0) = 1"
	elif [[ "$manual_only" == true ]]; then
		auto_filter="AND COALESCE(a.auto_captured, 0) = 0"
	fi

	# Handle --recent mode (no query required)
	if [[ "$recent_mode" == true ]]; then
		local results
		results=$(db -json "$MEMORY_DB" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count, COALESCE(a.auto_captured, 0) as auto_captured FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE 1=1 $auto_filter ORDER BY l.created_at DESC LIMIT $limit;")
		if [[ "$format" == "json" ]]; then
			echo "$results"
		else
			echo ""
			echo "=== Recent Memories (last $limit) ==="
			echo ""
			echo "$results" | format_results_text
		fi
		return 0
	fi

	if [[ -z "$query" ]]; then
		log_error "Query is required. Use --query \"search terms\" or --recent"
		return 1
	fi

	# Handle --semantic or --hybrid mode (delegate to embeddings helper)
	if [[ "$semantic_mode" == true || "$hybrid_mode" == true ]]; then
		local embeddings_script
		embeddings_script="$(dirname "${BASH_SOURCE[0]}")/../memory-embeddings-helper.sh"
		if [[ ! -x "$embeddings_script" ]]; then
			log_error "Semantic search not available. Run: memory-embeddings-helper.sh setup"
			return 1
		fi
		local semantic_args=()
		if [[ -n "$MEMORY_NAMESPACE" ]]; then
			semantic_args+=("--namespace" "$MEMORY_NAMESPACE")
		fi
		semantic_args+=("search" "$query" "--limit" "$limit")
		if [[ "$hybrid_mode" == true ]]; then
			semantic_args+=("--hybrid")
		fi
		if [[ "$format" == "json" ]]; then
			semantic_args+=("--json")
		fi
		"$embeddings_script" "${semantic_args[@]}"
		return $?
	fi

	# Escape query for FTS5 - wrap in double quotes to handle special chars
	# FTS5 treats hyphens as NOT operator, asterisks as prefix, etc.
	# Quoting the query makes it a literal phrase search.
	local escaped_query="${query//"'"/"''"}"
	# Escape embedded double quotes for FTS5 (double them), then wrap in quotes
	escaped_query="\"${escaped_query//\"/\"\"}\""

	# Build filters with validation
	local extra_filters=""
	if [[ -n "$type_filter" ]]; then
		# Validate type to prevent SQL injection
		local type_pattern=" $type_filter "
		if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
			log_error "Invalid type: $type_filter"
			log_error "Valid types: $VALID_TYPES"
			return 1
		fi
		extra_filters="$extra_filters AND type = '$type_filter'"
	fi
	if [[ -n "$max_age_days" ]]; then
		# Validate max_age_days is a positive integer
		if ! [[ "$max_age_days" =~ ^[0-9]+$ ]]; then
			log_error "--max-age-days must be a positive integer"
			return 1
		fi
		extra_filters="$extra_filters AND created_at >= datetime('now', '-$max_age_days days')"
	fi
	if [[ -n "$project_filter" ]]; then
		local escaped_project="${project_filter//"'"/"''"}"
		extra_filters="$extra_filters AND project_path LIKE '%$escaped_project%'"
	fi

	# Build auto-capture filter for main query
	local auto_join_filter=""
	if [[ "$auto_only" == true ]]; then
		auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 1"
	elif [[ "$manual_only" == true ]]; then
		auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 0"
	fi

	# Search using FTS5 with BM25 ranking
	# Note: FTS5 tables require special handling - can't use table alias in bm25()
	local results
	results=$(
		db -json "$MEMORY_DB" <<EOF
SELECT 
    learnings.id,
    learnings.content,
    learnings.type,
    learnings.tags,
    learnings.confidence,
    learnings.created_at,
    COALESCE(learning_access.last_accessed_at, '') as last_accessed_at,
    COALESCE(learning_access.access_count, 0) as access_count,
    COALESCE(learning_access.auto_captured, 0) as auto_captured,
    bm25(learnings) as score
FROM learnings
LEFT JOIN learning_access ON learnings.id = learning_access.id
WHERE learnings MATCH '$escaped_query' $extra_filters $auto_join_filter
ORDER BY score
LIMIT $limit;
EOF
	)

	# Update access tracking for returned results (prevents staleness)
	if [[ -n "$results" && "$results" != "[]" ]]; then
		local ids
		ids=$(echo "$results" | extract_ids_from_json)
		if [[ -n "$ids" ]]; then
			while IFS= read -r id; do
				[[ -z "$id" ]] && continue
				db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$id', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
			done <<<"$ids"
		fi
	fi

	# Shared search: also query global DB when in a namespace with --shared
	local shared_results=""
	if [[ "$shared_mode" == true && -n "$MEMORY_NAMESPACE" ]]; then
		local global_db
		global_db=$(global_db_path)
		if [[ -f "$global_db" ]]; then
			shared_results=$(
				db -json "$global_db" <<EOF
SELECT 
    learnings.id,
    learnings.content,
    learnings.type,
    learnings.tags,
    learnings.confidence,
    learnings.created_at,
    COALESCE(learning_access.last_accessed_at, '') as last_accessed_at,
    COALESCE(learning_access.access_count, 0) as access_count,
    bm25(learnings) as score
FROM learnings
LEFT JOIN learning_access ON learnings.id = learning_access.id
WHERE learnings MATCH '$escaped_query' $extra_filters
ORDER BY score
LIMIT $limit;
EOF
			)
			# Update access tracking in global DB for shared results
			if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
				local shared_ids
				shared_ids=$(echo "$shared_results" | extract_ids_from_json)
				if [[ -n "$shared_ids" ]]; then
					while IFS= read -r sid; do
						[[ -z "$sid" ]] && continue
						db "$global_db" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$sid', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
					done <<<"$shared_ids"
				fi
			fi
		fi
	fi

	# Output based on format
	if [[ "$format" == "json" ]]; then
		if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
			# Merge namespace and global results into single JSON array
			if command -v jq &>/dev/null; then
				local ns_json="${results:-[]}"
				jq -s '.[0] + .[1] | sort_by(.score) | .[:'"$limit"']' \
					<(echo "$ns_json") <(echo "$shared_results")
			else
				echo "$results"
				echo "$shared_results"
			fi
		else
			echo "$results"
		fi
	else
		if [[ -z "$results" || "$results" == "[]" ]] &&
			[[ -z "$shared_results" || "$shared_results" == "[]" ]]; then
			log_warn "No results found for: $query"
			return 0
		fi

		local header_suffix=""
		if [[ -n "$MEMORY_NAMESPACE" ]]; then
			header_suffix=" [namespace: $MEMORY_NAMESPACE]"
		fi

		echo ""
		echo "=== Memory Recall: \"$query\"${header_suffix} ==="
		echo ""

		if [[ -n "$results" && "$results" != "[]" ]]; then
			echo "$results" | format_results_text
		fi

		if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
			echo ""
			echo "--- Shared (global) results ---"
			echo ""
			echo "$shared_results" | format_results_text
		fi
	fi
}

#######################################
# Show version history for a memory
# Traces the chain of updates/extends/derives
#######################################
cmd_history() {
	local memory_id="$1"

	if [[ -z "$memory_id" ]]; then
		log_error "Memory ID is required. Usage: memory-helper.sh history <id>"
		return 1
	fi

	init_db

	# Escape memory_id for SQL (prevents SQL injection)
	local escaped_id="${memory_id//"'"/"''"}"

	# Check if memory exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Memory not found: $memory_id"
		return 1
	fi

	echo ""
	echo "=== Version History for $memory_id ==="
	echo ""

	# Show the current memory
	echo "Current:"
	db "$MEMORY_DB" <<EOF
SELECT '  [' || type || '] ' || substr(content, 1, 80) || '...'
FROM learnings WHERE id = '$escaped_id';
SELECT '  Created: ' || created_at || ' | Event: ' || COALESCE(event_date, 'N/A')
FROM learnings WHERE id = '$escaped_id';
EOF

	# Show what this memory supersedes (ancestors)
	echo ""
	echo "Supersedes (ancestors):"
	local ancestors
	ancestors=$(
		db "$MEMORY_DB" <<EOF
WITH RECURSIVE ancestors AS (
    SELECT lr.supersedes_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.id = '$escaped_id'
    UNION ALL
    SELECT lr.supersedes_id, lr.relation_type, a.depth + 1
    FROM learning_relations lr
    JOIN ancestors a ON lr.id = a.supersedes_id
    WHERE a.depth < 10
)
SELECT a.supersedes_id, a.relation_type, a.depth, 
       l.type, substr(l.content, 1, 60), l.created_at
FROM ancestors a
JOIN learnings l ON a.supersedes_id = l.id
ORDER BY a.depth;
EOF
	)

	if [[ -z "$ancestors" ]]; then
		echo "  (none - this is the original)"
	else
		echo "$ancestors" | while IFS='|' read -r sup_id rel_type depth mem_type content created; do
			local indent
			indent=$(printf '%*s' "$((depth * 2))" '')
			echo "${indent}[${rel_type}] $sup_id"
			echo "${indent}  [${mem_type}] $content..."
			echo "${indent}  Created: $created"
		done
	fi

	# Show what supersedes this memory (descendants)
	echo ""
	echo "Superseded by (descendants):"
	local descendants
	descendants=$(
		db "$MEMORY_DB" <<EOF
WITH RECURSIVE descendants AS (
    SELECT lr.id as child_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.supersedes_id = '$escaped_id'
    UNION ALL
    SELECT lr.id, lr.relation_type, d.depth + 1
    FROM learning_relations lr
    JOIN descendants d ON lr.supersedes_id = d.child_id
    WHERE d.depth < 10
)
SELECT d.child_id, d.relation_type, d.depth,
       l.type, substr(l.content, 1, 60), l.created_at
FROM descendants d
JOIN learnings l ON d.child_id = l.id
ORDER BY d.depth;
EOF
	)

	if [[ -z "$descendants" ]]; then
		echo "  (none - this is the latest)"
	else
		echo "$descendants" | while IFS='|' read -r child_id rel_type depth mem_type content created; do
			local indent
			indent=$(printf '%*s' "$((depth * 2))" '')
			echo "${indent}[${rel_type}] $child_id"
			echo "${indent}  [${mem_type}] $content..."
			echo "${indent}  Created: $created"
		done
	fi

	return 0
}

#######################################
# Find the latest version of a memory
# Follows the chain of 'updates' relations to find the current truth
#######################################
cmd_latest() {
	local memory_id="$1"

	if [[ -z "$memory_id" ]]; then
		log_error "Memory ID is required. Usage: memory-helper.sh latest <id>"
		return 1
	fi

	init_db

	# Escape memory_id for SQL (prevents SQL injection)
	local escaped_id="${memory_id//"'"/"''"}"

	# Find the latest in the chain (no descendants with 'updates' relation)
	local latest_id
	latest_id=$(
		db "$MEMORY_DB" <<EOF
WITH RECURSIVE chain AS (
    SELECT '$escaped_id' as id
    UNION ALL
    SELECT lr.id
    FROM learning_relations lr
    JOIN chain c ON lr.supersedes_id = c.id
    WHERE lr.relation_type = 'updates'
)
SELECT id FROM chain
WHERE id NOT IN (SELECT supersedes_id FROM learning_relations WHERE relation_type = 'updates')
LIMIT 1;
EOF
	)

	if [[ -z "$latest_id" ]]; then
		latest_id="$memory_id"
	fi

	# Escape latest_id for the final query
	local escaped_latest="${latest_id//"'"/"''"}"

	echo "$latest_id"

	# Show the content
	db "$MEMORY_DB" <<EOF
SELECT '[' || type || '] ' || content
FROM learnings WHERE id = '$escaped_latest';
EOF

	return 0
}
