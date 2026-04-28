#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Maintenance -- Namespaces Sub-Library
# =============================================================================
# Provides namespace management functions: listing, pruning orphans, and
# migrating entries between namespaces (including global).
#
# Usage: source "${SCRIPT_DIR}/maintenance-namespaces.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success, log_error)
#   - memory/_common.sh (db, init_db, MEMORY_DB, MEMORY_DIR, MEMORY_BASE_DIR,
#     global_db_path, backup_sqlite_db)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_MAINTENANCE_NAMESPACES_LOADED:-}" ]] && return 0
_MEMORY_MAINTENANCE_NAMESPACES_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
