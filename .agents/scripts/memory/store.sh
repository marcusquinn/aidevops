#!/usr/bin/env bash
# memory/store.sh - Memory storage functions
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_store

# Include guard
[[ -n "${_MEMORY_STORE_LOADED:-}" ]] && return 0
_MEMORY_STORE_LOADED=1

#######################################
# Store a learning
#######################################
cmd_store() {
	local content=""
	local type="WORKING_SOLUTION"
	local tags=""
	local confidence="medium"
	local session_id=""
	local project_path=""
	local source="manual"
	local event_date=""
	local supersedes_id=""
	local relation_type=""
	local auto_captured=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content)
			content="$2"
			shift 2
			;;
		--type)
			type="$2"
			shift 2
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--confidence)
			confidence="$2"
			shift 2
			;;
		--session-id)
			session_id="$2"
			shift 2
			;;
		--project)
			project_path="$2"
			shift 2
			;;
		--source)
			source="$2"
			shift 2
			;;
		--event-date)
			event_date="$2"
			shift 2
			;;
		--supersedes)
			supersedes_id="$2"
			shift 2
			;;
		--relation)
			relation_type="$2"
			shift 2
			;;
		--auto | --auto-captured)
			auto_captured=1
			source="auto"
			shift
			;;
		*)
			# Allow content as positional argument
			if [[ -z "$content" ]]; then
				content="$1"
			fi
			shift
			;;
		esac
	done

	# Validate required fields
	if [[ -z "$content" ]]; then
		log_error "Content is required. Use --content \"your learning\""
		return 1
	fi

	# Privacy filter: strip <private>...</private> blocks
	content=$(echo "$content" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

	# Privacy filter: reject content that looks like secrets
	if echo "$content" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xoxb-[a-zA-Z0-9-]{20,}|api[_-]?key[[:space:]"'"'"':=]+[a-zA-Z0-9_-]{16,})'; then
		log_error "Content appears to contain secrets (API keys, tokens). Refusing to store."
		log_error "Remove sensitive data or wrap in <private>...</private> tags to exclude."
		return 1
	fi

	# If content is empty after privacy filtering, skip
	if [[ -z "$content" ]]; then
		log_warn "Content is empty after privacy filtering. Skipping."
		return 0
	fi

	# Validate type
	local type_pattern=" $type "
	if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid type: $type"
		log_error "Valid types: $VALID_TYPES"
		return 1
	fi

	# Validate confidence
	if [[ ! "$confidence" =~ ^(high|medium|low)$ ]]; then
		log_error "Invalid confidence: $confidence (use high, medium, or low)"
		return 1
	fi

	# Validate relation_type if provided
	if [[ -n "$relation_type" ]]; then
		local relation_pattern=" $relation_type "
		if [[ ! " $VALID_RELATIONS " =~ $relation_pattern ]]; then
			log_error "Invalid relation type: $relation_type"
			log_error "Valid relations: $VALID_RELATIONS"
			return 1
		fi

		# If relation_type is provided, supersedes_id is required
		if [[ -z "$supersedes_id" ]]; then
			log_error "When using --relation, --supersedes <id> is required"
			return 1
		fi
	fi

	# If supersedes_id is provided, relation_type defaults to 'updates'
	if [[ -n "$supersedes_id" && -z "$relation_type" ]]; then
		relation_type="updates"
	fi

	# Generate session_id if not provided
	if [[ -z "$session_id" ]]; then
		session_id="session_$(date +%Y%m%d_%H%M%S)"
	fi

	# Get current project path if not provided
	if [[ -z "$project_path" ]]; then
		project_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
	fi

	init_db

	# Deduplication: skip if content already exists (unless it's a relational update)
	if [[ -z "$supersedes_id" ]]; then
		local existing_id
		if existing_id=$(check_duplicate "$content" "$type"); then
			log_warn "Duplicate detected (matches $existing_id). Skipping store."
			# Update access tracking on the existing entry to keep it fresh
			db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$existing_id', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
			echo "$existing_id"
			return 0
		fi
	fi

	# Opportunistic auto-prune (runs at most once per 24h)
	auto_prune

	local id
	id=$(generate_id)
	local created_at
	created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Default event_date to created_at if not provided
	if [[ -z "$event_date" ]]; then
		event_date="$created_at"
	elif ! [[ "$event_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
		log_warn "event_date '$event_date' may not be a valid ISO format (YYYY-MM-DD...)"
	fi

	# Escape single quotes for SQL (prevents SQL injection)
	local escaped_content="${content//"'"/"''"}"
	local escaped_tags="${tags//"'"/"''"}"
	local escaped_project="${project_path//"'"/"''"}"
	local escaped_supersedes="${supersedes_id//"'"/"''"}"

	# Validate supersedes_id exists if provided
	if [[ -n "$supersedes_id" ]]; then
		local exists
		exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_supersedes';")
		if [[ "$exists" == "0" ]]; then
			log_error "Supersedes ID not found: $supersedes_id"
			return 1
		fi
	fi

	db "$MEMORY_DB" <<EOF
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('$id', '$session_id', '$escaped_content', '$type', '$escaped_tags', '$confidence', '$created_at', '$event_date', '$escaped_project', '$source');
EOF

	# Store auto-captured flag in access table
	if [[ "$auto_captured" -eq 1 ]]; then
		db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, auto_captured)
VALUES ('$id', '$created_at', 0, 1)
ON CONFLICT(id) DO UPDATE SET auto_captured = 1;
EOF
	fi

	# Store relation if provided
	if [[ -n "$supersedes_id" ]]; then
		db "$MEMORY_DB" <<EOF
INSERT INTO learning_relations (id, supersedes_id, relation_type, created_at)
VALUES ('$id', '$escaped_supersedes', '$relation_type', '$created_at');
EOF
		log_info "Relation: $id $relation_type $supersedes_id"
	fi

	log_success "Stored learning: $id"

	# Auto-index for semantic search (non-blocking, background)
	local embeddings_script
	embeddings_script="$(dirname "${BASH_SOURCE[0]}")/../memory-embeddings-helper.sh"
	if [[ -x "$embeddings_script" ]]; then
		local auto_args=()
		if [[ -n "$MEMORY_NAMESPACE" ]]; then
			auto_args+=("--namespace" "$MEMORY_NAMESPACE")
		fi
		auto_args+=("auto-index" "$id")
		"$embeddings_script" "${auto_args[@]}" 2>/dev/null || true
	fi

	echo "$id"
}
