#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Email Agent Core -- Configuration, database, and template utilities
# =============================================================================
# Provides dependency checking, config loading, AWS credential setup,
# SQLite database management, and email template rendering.
#
# Usage: source "${SCRIPT_DIR}/email-agent-helper-core.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_info, etc.)
#   - Constants from email-agent-helper.sh orchestrator (CONFIG_DIR, CONFIG_FILE, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_AGENT_CORE_LIB_LOADED:-}" ]] && return 0
_EMAIL_AGENT_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Dependency checks
# ============================================================================

check_dependencies() {
	local missing=0

	if ! command -v aws &>/dev/null; then
		print_error "AWS CLI is required. Install: brew install awscli"
		missing=1
	fi

	if ! command -v jq &>/dev/null; then
		print_error "jq is required. Install: brew install jq"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Configuration
# ============================================================================

load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		print_error "Config not found: $CONFIG_FILE"
		print_info "Copy template: cp ${CONFIG_DIR}/email-agent-config.json.txt ${CONFIG_FILE}"
		return 1
	fi
	return 0
}

get_config_value() {
	local key="$1"
	local default="${2:-}"

	local value
	value=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

# Set AWS credentials from config or gopass
set_aws_credentials() {
	local region
	region=$(get_config_value '.aws_region' 'eu-west-2')
	export AWS_DEFAULT_REGION="$region"

	# Try gopass first, then env vars
	if command -v gopass &>/dev/null; then
		local key_id secret_key
		key_id=$(gopass show -o "aidevops/AWS_ACCESS_KEY_ID" 2>/dev/null || echo "")
		secret_key=$(gopass show -o "aidevops/AWS_SECRET_ACCESS_KEY" 2>/dev/null || echo "")
		if [[ -n "$key_id" && -n "$secret_key" ]]; then
			export AWS_ACCESS_KEY_ID="$key_id"
			export AWS_SECRET_ACCESS_KEY="$secret_key"
			return 0
		fi
	fi

	# Fall back to existing env vars or credentials.sh
	if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
		local creds_file="${HOME}/.config/aidevops/credentials.sh"
		if [[ -f "$creds_file" ]]; then
			# shellcheck disable=SC1090
			source "$creds_file"
		fi
	fi

	if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
		print_error "AWS credentials not found. Set via: aidevops secret set AWS_ACCESS_KEY_ID && aidevops secret set AWS_SECRET_ACCESS_KEY"
		return 1
	fi
	return 0
}

# ============================================================================
# Database (SQLite)
# ============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

ensure_db() {
	mkdir -p "$WORKSPACE_DIR"

	if [[ ! -f "$DB_FILE" ]]; then
		init_db
		return 0
	fi

	# Ensure WAL mode for existing databases
	local current_mode
	current_mode=$(db "$DB_FILE" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$DB_FILE" "PRAGMA journal_mode=WAL;" 2>/dev/null || true
	fi

	return 0
}

init_db() {
	db "$DB_FILE" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS conversations (
    id          TEXT PRIMARY KEY,
    mission_id  TEXT NOT NULL,
    subject     TEXT NOT NULL,
    to_email    TEXT NOT NULL,
    from_email  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','waiting','completed','failed')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS messages (
    id          TEXT PRIMARY KEY,
    conv_id     TEXT NOT NULL REFERENCES conversations(id),
    mission_id  TEXT NOT NULL,
    direction   TEXT NOT NULL CHECK(direction IN ('outbound','inbound')),
    from_email  TEXT NOT NULL,
    to_email    TEXT NOT NULL,
    subject     TEXT NOT NULL,
    body_text   TEXT,
    body_html   TEXT,
    message_id  TEXT,
    in_reply_to TEXT,
    ses_message_id TEXT,
    s3_key      TEXT,
    raw_path    TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS extracted_codes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id  TEXT NOT NULL REFERENCES messages(id),
    mission_id  TEXT NOT NULL,
    code_type   TEXT NOT NULL CHECK(code_type IN ('otp','token','link','api_key','password','other')),
    code_value  TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 1.0,
    used        INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_conv_mission ON conversations(mission_id);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conv_id);
CREATE INDEX IF NOT EXISTS idx_msg_mission ON messages(mission_id);
CREATE INDEX IF NOT EXISTS idx_msg_message_id ON messages(message_id);
CREATE INDEX IF NOT EXISTS idx_codes_mission ON extracted_codes(mission_id);
CREATE INDEX IF NOT EXISTS idx_codes_message ON extracted_codes(message_id);
SQL

	log_info "Initialized email agent database: $DB_FILE"
	return 0
}

# Escape a string for safe use in SQLite single-quoted literals.
# Returns the escaped string WITHOUT surrounding single quotes.
# Callers MUST wrap the result in single quotes, e.g.:
#   WHERE col = '$(sql_escape "$var")'
sql_escape() {
	local input="$1"
	echo "${input//\'/\'\'}"
	return 0
}

generate_id() {
	local prefix="${1:-ea}"
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	local random
	random=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
	echo "${prefix}-${timestamp}-${random}"
	return 0
}

# ============================================================================
# Template processing
# ============================================================================

# Render a template file with variable substitution
# Template format: {{variable_name}} placeholders
# Variables passed as: key1=val1,key2=val2
render_template() {
	local template_file="$1"
	local vars_string="${2:-}"

	if [[ ! -f "$template_file" ]]; then
		print_error "Template not found: $template_file"
		return 1
	fi

	local content
	content=$(cat "$template_file")

	# Parse and apply variable substitutions
	if [[ -n "$vars_string" ]]; then
		local -a pairs
		IFS=',' read -ra pairs <<<"$vars_string"
		local pair
		for pair in "${pairs[@]}"; do
			local key="${pair%%=*}"
			local value="${pair#*=}"
			# Replace {{key}} with value
			content="${content//\{\{${key}\}\}/${value}}"
		done
	fi

	# Check for unreplaced variables
	local unreplaced
	unreplaced=$(echo "$content" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u || true)
	if [[ -n "$unreplaced" ]]; then
		print_warning "Unreplaced template variables: $unreplaced"
	fi

	echo "$content"
	return 0
}

# Extract subject from template (first line starting with "Subject: ")
extract_template_subject() {
	local template_file="$1"

	local subject
	subject=$(grep -m1 '^Subject: ' "$template_file" 2>/dev/null | sed 's/^Subject: //' || echo "")
	echo "$subject"
	return 0
}

# Extract body from template (everything after the first blank line)
extract_template_body() {
	local template_content="$1"

	# Skip header lines (Subject:, From:, etc.) until first blank line
	echo "$template_content" | sed -n '/^$/,$ { /^$/d; p; }'
	return 0
}
