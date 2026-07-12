#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Maintenance -- Deduplication Sub-Library
# =============================================================================
# Provides deduplication functions for memory entries: exact, near-duplicate,
# and semantic (AI-judged) duplicate detection and removal.
#
# Usage: source "${SCRIPT_DIR}/maintenance-dedup.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success, log_error)
#   - memory/_common.sh (db, db_cleanup, init_db, MEMORY_DB)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_DEDUP_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_DEDUP_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

_dedup_merge_observation_evidence() {
	local keep_id_esc="$1"
	local remove_id_esc="$2"
	db "$MEMORY_DB" <<EOF
UPDATE observation_sources
SET observation_id = 'obs_learning_' || '$keep_id_esc'
WHERE observation_id = 'obs_learning_' || '$remove_id_esc';
DELETE FROM observations WHERE observation_id = 'obs_learning_' || '$remove_id_esc';
EOF
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
SELECT GROUP_CONCAT(l.id, ',') as ids, COUNT(*) as cnt
FROM learnings l JOIN observations o ON o.observation_id = 'obs_learning_' || l.id
WHERE o.status = 'active' AND (o.expires_at IS NULL OR o.expires_at > datetime('now'))
GROUP BY l.content, o.kind, COALESCE(o.owner_id, ''), COALESCE(o.subject_id, ''),
         COALESCE(o.project_scope, ''), COALESCE(o.organization_scope, ''),
         COALESCE(o.user_scope, ''), o.framework_scope, o.sensitivity, o.status
HAVING cnt > 1
ORDER BY cnt DESC;
EOF
	)

	[[ -z "$exact_groups" ]] && echo "$exact_removed" && return 0

	while IFS='|' read -r id_list _count; do
		[[ -z "$id_list" ]] && continue
		local all_ids="${id_list//,/$'\n'}"

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
				log_info "[DRY RUN] Would remove $mem_id (duplicate of $keep_id)" >&2
			else
				_dedup_merge_tags "$escaped_keep" "$escaped_remove"
				_dedup_merge_observation_evidence "$escaped_keep" "$escaped_remove"
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
	done <<<"$exact_groups"

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
FROM learnings l JOIN observations o ON o.observation_id = 'obs_learning_' || l.id
WHERE o.status = 'active' AND (o.expires_at IS NULL OR o.expires_at > datetime('now'))
GROUP BY norm, o.kind, COALESCE(o.owner_id, ''), COALESCE(o.subject_id, ''),
         COALESCE(o.project_scope, ''), COALESCE(o.organization_scope, ''),
         COALESCE(o.user_scope, ''), o.framework_scope, o.sensitivity, o.status
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

		# Exact duplicates are handled in phase 1. During dry-run they are not
		# physically deleted, so collapse each exact-content set to one
		# representative before counting near-duplicate removals. This mirrors the
		# database state phase 2 sees during a real run and avoids double-counting.
		if [[ "$dry_run" == true ]]; then
			local representative_ids=()
			local seen_contents=$'\n'
			for nid in "${ids_arr[@]}"; do
				[[ -z "$nid" ]] && continue
				local nid_esc="${nid//"'"/"''"}"
				local nid_content
				nid_content=$(db "$MEMORY_DB" "SELECT content FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || true)
				[[ -z "$nid_content" ]] && continue
				if [[ "$seen_contents" == *$'\n'"$nid_content"$'\n'* ]]; then
					continue
				fi
				seen_contents+="${nid_content}"$'\n'
				representative_ids+=("$nid")
			done
			ids_arr=("${representative_ids[@]}")
			[[ "${#ids_arr[@]}" -le 1 ]] && continue
		fi

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
				log_info "[DRY RUN] Would remove near-dup $nid (keep $oldest_id): $preview..." >&2
			else
				_dedup_merge_tags "$oldest_esc" "$nid_esc"
				_dedup_merge_observation_evidence "$oldest_esc" "$nid_esc"
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

	log_info "Scanning for semantic duplicates (AI-judged)..." >&2

	local types
	types=$(db "$MEMORY_DB" "SELECT DISTINCT l.type || '|' || COALESCE(o.owner_id, '') || '|' || COALESCE(o.subject_id, '') || '|' || COALESCE(o.project_scope, '') || '|' || COALESCE(o.organization_scope, '') || '|' || COALESCE(o.user_scope, '') || '|' || o.framework_scope || '|' || o.sensitivity FROM learnings l JOIN observations o ON o.observation_id = 'obs_learning_' || l.id WHERE o.status = 'active' AND (o.expires_at IS NULL OR o.expires_at > datetime('now'));")

	while IFS='|' read -r check_type owner subject project organization user framework sensitivity; do
		[[ -z "$check_type" ]] && continue
		local type_esc="${check_type//"'"/"''"}"
		local scope_where="AND COALESCE(o.owner_id, '') = '${owner//"'"/"''"}' AND COALESCE(o.subject_id, '') = '${subject//"'"/"''"}' AND COALESCE(o.project_scope, '') = '${project//"'"/"''"}' AND COALESCE(o.organization_scope, '') = '${organization//"'"/"''"}' AND COALESCE(o.user_scope, '') = '${user//"'"/"''"}' AND o.framework_scope = '${framework//"'"/"''"}' AND o.sensitivity = '${sensitivity//"'"/"''"}'"
		local entries
		entries=$(db "$MEMORY_DB" "SELECT l.id, substr(l.content, 1, 200), l.created_at FROM learnings l JOIN observations o ON o.observation_id = 'obs_learning_' || l.id WHERE l.type = '$type_esc' $scope_where AND o.status = 'active' AND (o.expires_at IS NULL OR o.expires_at > datetime('now')) ORDER BY l.created_at ASC LIMIT 50;")

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
						log_info "[DRY RUN] Semantic dup: remove $remove_id (keep $keep_id): ${contents_arr[$j]:0:50}..." >&2
					else
						_dedup_merge_tags "$keep_esc" "$remove_esc"
						_dedup_merge_observation_evidence "$keep_esc" "$remove_esc"
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
#   2. Near-duplicates (normalized content match -- punctuation removed)
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
			log_warn "ai-threshold-judge.sh not found -- skipping semantic dedup"
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
