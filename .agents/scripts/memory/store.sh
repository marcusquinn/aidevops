#!/usr/bin/env bash
# memory/store.sh - Memory storage functions
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_store

# Include guard
[[ -n "${_MEMORY_STORE_LOADED:-}" ]] && return 0
_MEMORY_STORE_LOADED=1

# Module-level state variables used by _store_* helpers and cmd_store.
# These are set by _store_parse_args and read by subsequent helpers.
_store_content=""
_store_type="WORKING_SOLUTION"
_store_tags=""
_store_confidence="medium"
_store_session_id=""
_store_project_path=""
_store_source="manual"
_store_event_date=""
_store_supersedes_id=""
_store_relation_type=""
_store_auto_captured=0
_store_entity_id=""

#######################################
# Parse CLI arguments into _store_* module variables.
# Called by cmd_store before any other helper.
#######################################
_store_parse_args() {
	_store_content=""
	_store_type="WORKING_SOLUTION"
	_store_tags=""
	_store_confidence="medium"
	_store_session_id=""
	_store_project_path=""
	_store_source="manual"
	_store_event_date=""
	_store_supersedes_id=""
	_store_relation_type=""
	_store_auto_captured=0
	_store_entity_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content)
			_store_content="$2"
			shift 2
			;;
		--type)
			_store_type="$2"
			shift 2
			;;
		--tags)
			_store_tags="$2"
			shift 2
			;;
		--confidence)
			_store_confidence="$2"
			shift 2
			;;
		--session-id)
			_store_session_id="$2"
			shift 2
			;;
		--project)
			_store_project_path="$2"
			shift 2
			;;
		--source)
			_store_source="$2"
			shift 2
			;;
		--event-date)
			_store_event_date="$2"
			shift 2
			;;
		--supersedes)
			_store_supersedes_id="$2"
			shift 2
			;;
		--relation)
			_store_relation_type="$2"
			shift 2
			;;
		--auto | --auto-captured)
			_store_auto_captured=1
			_store_source="auto"
			shift
			;;
		--entity)
			_store_entity_id="$2"
			shift 2
			;;
		*)
			# Allow content as positional argument
			if [[ -z "$_store_content" ]]; then
				_store_content="$1"
			fi
			shift
			;;
		esac
	done
	return 0
}

#######################################
# Validate and privacy-filter _store_content in place.
# Returns 0 if content is valid and ready to store.
# Returns 1 if content should be rejected with an error.
# Returns 2 if content is empty after filtering (skip silently).
#######################################
_store_validate_content() {
	# Validate required fields
	if [[ -z "$_store_content" ]]; then
		log_error "Content is required. Use --content \"your learning\""
		return 1
	fi

	# Guard against literal "undefined" or "null" strings passed by JS callers
	# when args.content is undefined in a template literal (produces "undefined").
	if [[ "$_store_content" == "undefined" || "$_store_content" == "null" ]]; then
		log_error "Content is 'undefined' or 'null' — refusing to store. Pass a real value."
		return 1
	fi

	# Privacy filter: strip <private>...</private> blocks
	_store_content=$(echo "$_store_content" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

	# Privacy filter: reject content that looks like secrets
	if echo "$_store_content" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xoxb-[a-zA-Z0-9-]{20,}|api[_-]?key[[:space:]"'"'"':=]+[a-zA-Z0-9_-]{16,})'; then
		log_error "Content appears to contain secrets (API keys, tokens). Refusing to store."
		log_error "Remove sensitive data or wrap in <private>...</private> tags to exclude."
		return 1
	fi

	# If content is empty after privacy filtering, skip
	if [[ -z "$_store_content" ]]; then
		log_warn "Content is empty after privacy filtering. Skipping."
		return 2
	fi

	return 0
}

#######################################
# Validate _store_type, _store_confidence, and _store_relation_type/_store_supersedes_id.
# Returns 0 if all valid, 1 if any validation fails.
#######################################
_store_validate_params() {
	# Validate type
	local type_pattern=" $_store_type "
	if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid type: $_store_type"
		log_error "Valid types: $VALID_TYPES"
		return 1
	fi

	# Validate confidence
	if [[ ! "$_store_confidence" =~ ^(high|medium|low)$ ]]; then
		log_error "Invalid confidence: $_store_confidence (use high, medium, or low)"
		return 1
	fi

	# Validate relation_type if provided
	if [[ -n "$_store_relation_type" ]]; then
		local relation_pattern=" $_store_relation_type "
		if [[ ! " $VALID_RELATIONS " =~ $relation_pattern ]]; then
			log_error "Invalid relation type: $_store_relation_type"
			log_error "Valid relations: $VALID_RELATIONS"
			return 1
		fi

		# If relation_type is provided, supersedes_id is required
		if [[ -z "$_store_supersedes_id" ]]; then
			log_error "When using --relation, --supersedes <id> is required"
			return 1
		fi
	fi

	return 0
}

#######################################
# Prepare metadata for the INSERT: generate IDs, timestamps, SQL-escaped values.
# Populates module variables: _store_id, _store_created_at,
# _store_esc_content, _store_esc_tags, _store_esc_project,
# _store_esc_supersedes, _store_esc_session, _store_esc_source, _store_esc_event_date.
# Returns 0 on success, 1 if supersedes_id is not found in DB.
#######################################
_store_prepare_metadata() {
	# Generate session_id if not provided
	if [[ -z "$_store_session_id" ]]; then
		_store_session_id="session_$(date +%Y%m%d_%H%M%S)"
	fi

	# Get current project path if not provided
	if [[ -z "$_store_project_path" ]]; then
		_store_project_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
	fi

	_store_id=$(generate_id)
	_store_created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Default event_date to created_at if not provided
	if [[ -z "$_store_event_date" ]]; then
		_store_event_date="$_store_created_at"
	elif ! [[ "$_store_event_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]]; then
		log_warn "event_date '$_store_event_date' may not be a valid ISO format (YYYY-MM-DD...)"
	fi

	# Escape single quotes for SQL (prevents SQL injection)
	_store_esc_content="${_store_content//"'"/"''"}"
	_store_esc_tags="${_store_tags//"'"/"''"}"
	_store_esc_project="${_store_project_path//"'"/"''"}"
	_store_esc_supersedes="${_store_supersedes_id//"'"/"''"}"
	_store_esc_session="${_store_session_id//"'"/"''"}"
	_store_esc_source="${_store_source//"'"/"''"}"
	_store_esc_event_date="${_store_event_date//"'"/"''"}"

	# Validate supersedes_id exists if provided
	if [[ -n "$_store_supersedes_id" ]]; then
		local exists
		exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$_store_esc_supersedes';")
		if [[ "$exists" == "0" ]]; then
			log_error "Supersedes ID not found: $_store_supersedes_id"
			return 1
		fi
	fi

	return 0
}

#######################################
# Insert the learning row plus optional access, relation, and entity rows.
# Reads all _store_* module variables set by _store_prepare_metadata.
# Returns 0 on success.
#######################################
_store_insert_record() {
	db "$MEMORY_DB" <<EOF
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('$_store_id', '$_store_esc_session', '$_store_esc_content', '$_store_type', '$_store_esc_tags', '$_store_confidence', '$_store_created_at', '$_store_esc_event_date', '$_store_esc_project', '$_store_esc_source');
EOF

	# Store auto-captured flag in access table
	if [[ "$_store_auto_captured" -eq 1 ]]; then
		db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, auto_captured)
VALUES ('$_store_id', '$_store_created_at', 0, 1)
ON CONFLICT(id) DO UPDATE SET auto_captured = 1;
EOF
	fi

	# Store relation if provided
	if [[ -n "$_store_supersedes_id" ]]; then
		db "$MEMORY_DB" <<EOF
INSERT INTO learning_relations (id, supersedes_id, relation_type, created_at)
VALUES ('$_store_id', '$_store_esc_supersedes', '$_store_relation_type', '$_store_created_at');
EOF
		log_info "Relation: $_store_id $_store_relation_type $_store_supersedes_id"
	fi

	# Link to entity if --entity was provided (t1363.3)
	if [[ -n "$_store_entity_id" ]]; then
		if ! validate_entity_id "$_store_entity_id"; then
			log_warn "Entity '$_store_entity_id' not found — learning stored but not linked to entity"
		else
			link_learning_entity "$_store_id" "$_store_entity_id"
			log_info "Linked to entity: $_store_entity_id"
		fi
	fi

	return 0
}

#######################################
# Trigger background auto-indexing for semantic search (non-blocking).
# Args: $1 = learning id
#######################################
_store_auto_index() {
	local id="$1"

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
	return 0
}

#######################################
# Store a learning
#######################################
cmd_store() {
	_store_parse_args "$@"

	# Validate and privacy-filter content (updates _store_content in place)
	_store_validate_content
	local _validate_rc=$?
	if [[ "$_validate_rc" -eq 1 ]]; then
		return 1
	elif [[ "$_validate_rc" -eq 2 ]]; then
		return 0
	fi

	# Validate type, confidence, and relation parameters
	_store_validate_params || return 1

	# If supersedes_id is provided, relation_type defaults to 'updates'
	if [[ -n "$_store_supersedes_id" && -z "$_store_relation_type" ]]; then
		_store_relation_type="updates"
	fi

	init_db

	# Deduplication: skip if content already exists (unless it's a relational update)
	if [[ -z "$_store_supersedes_id" ]]; then
		local existing_id
		if existing_id=$(check_duplicate "$_store_content" "$_store_type"); then
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

	# Prepare metadata: IDs, timestamps, SQL-escaped values
	_store_prepare_metadata || return 1

	# Insert all records into the database
	_store_insert_record || return 1

	log_success "Stored learning: $_store_id"

	# Auto-index for semantic search (non-blocking, background)
	_store_auto_index "$_store_id"

	echo "$_store_id"
	return 0
}
