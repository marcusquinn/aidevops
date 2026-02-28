#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# Email Agent Helper Script
# Autonomous 3rd-party email communication for missions
# Send templated emails, receive/parse responses, extract verification codes,
# thread conversations, integrate with mission credential management.
#
# Usage:
#   email-agent-helper.sh send --mission <id> --to <email> --template <file> [--vars 'key=val,...']
#   email-agent-helper.sh poll --mission <id> [--since <ISO-date>]
#   email-agent-helper.sh extract-codes --message <msg-id> [--mission <id>]
#   email-agent-helper.sh thread --mission <id> [--conversation <conv-id>]
#   email-agent-helper.sh conversations --mission <id>
#   email-agent-helper.sh status [--mission <id>]
#   email-agent-helper.sh help
#
# Requires: aws CLI (SES + S3), jq, python3 (for email parsing)
# Config: configs/email-agent-config.json (from .json.txt template)
# Credentials: aidevops secret set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#
# Part of aidevops mission system (t1360)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================================
# Constants
# ============================================================================

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly CONFIG_FILE="${CONFIG_DIR}/email-agent-config.json"
readonly EMAIL_TO_MD_SCRIPT="${SCRIPT_DIR}/email-to-markdown.py"
readonly THREAD_RECON_SCRIPT="${SCRIPT_DIR}/email-thread-reconstruction.py"
# WORKSPACE_DIR and DB_FILE are overridable via env vars for testing
readonly WORKSPACE_DIR="${EMAIL_AGENT_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/email-agent}"
readonly DB_FILE="${EMAIL_AGENT_DB:-${WORKSPACE_DIR}/conversations.db}"

# Verification code patterns (extended regex, most specific first)
readonly -a CODE_PATTERNS=(
	'[Cc]ode[: ]+[0-9]{6}'
	'[Cc]ode[: ]+is[: ]+[0-9]{6}'
	'[Vv]erification[: ]+[0-9]{4,8}'
	'[Oo][Tt][Pp][: ]+[0-9]{4,8}'
	'[Pp][Ii][Nn][: ]+[0-9]{4,6}'
	'[Cc]onfirmation[: ]+[A-Z0-9]{6,12}'
	'[Tt]oken[: ]+[A-Za-z0-9_-]{20,}'
	'[Tt]oken[: ]+is[: ]+[A-Za-z0-9_-]{20,}'
)

# URL patterns for confirmation/activation links (extended regex)
readonly -a LINK_PATTERNS=(
	'https?://[^ <>"]+[?&](token|code|confirm|activate|verify|key)=[^ <>"&]+'
	'https?://[^ <>"]+/(confirm|activate|verify|validate|approve)/[^ <>"]+'
	'https?://[^ <>"]+/(signup|register|onboard)/[^ <>"]*[?&][^ <>"]+'
)

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

# ============================================================================
# Send command
# ============================================================================

cmd_send() {
	local mission_id="" to_email="" template_file="" vars_string=""
	local subject="" body="" from_email="" reply_to_msg=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		--to)
			[[ $# -lt 2 ]] && {
				print_error "--to requires a value"
				return 1
			}
			to_email="$2"
			shift 2
			;;
		--template)
			[[ $# -lt 2 ]] && {
				print_error "--template requires a value"
				return 1
			}
			template_file="$2"
			shift 2
			;;
		--vars)
			[[ $# -lt 2 ]] && {
				print_error "--vars requires a value"
				return 1
			}
			vars_string="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				print_error "--subject requires a value"
				return 1
			}
			subject="$2"
			shift 2
			;;
		--body)
			[[ $# -lt 2 ]] && {
				print_error "--body requires a value"
				return 1
			}
			body="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				print_error "--from requires a value"
				return 1
			}
			from_email="$2"
			shift 2
			;;
		--reply-to)
			[[ $# -lt 2 ]] && {
				print_error "--reply-to requires a value"
				return 1
			}
			reply_to_msg="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Validate required fields
	if [[ -z "$mission_id" ]]; then
		print_error "Mission ID is required (--mission M001)"
		return 1
	fi
	if [[ -z "$to_email" ]]; then
		print_error "Recipient email is required (--to user@example.com)"
		return 1
	fi

	check_dependencies || return 1
	load_config || return 1
	set_aws_credentials || return 1
	ensure_db

	# Resolve from address
	if [[ -z "$from_email" ]]; then
		from_email=$(get_config_value '.default_from_email' '')
		if [[ -z "$from_email" ]]; then
			print_error "No from address. Set --from or configure default_from_email in config"
			return 1
		fi
	fi

	# Process template or direct subject/body
	if [[ -n "$template_file" ]]; then
		local rendered
		rendered=$(render_template "$template_file" "$vars_string")
		if [[ -z "$subject" ]]; then
			subject=$(echo "$rendered" | grep -m1 '^Subject: ' | sed 's/^Subject: //' || echo "Mission $mission_id Communication")
		fi
		if [[ -z "$body" ]]; then
			body=$(extract_template_body "$rendered")
		fi
	fi

	if [[ -z "$subject" ]]; then
		print_error "Subject is required (--subject or template with Subject: header)"
		return 1
	fi
	if [[ -z "$body" ]]; then
		print_error "Body is required (--body or --template)"
		return 1
	fi

	# Find or create conversation
	local conv_id=""
	if [[ -n "$reply_to_msg" ]]; then
		# Find conversation by message reference
		conv_id=$(db "$DB_FILE" "
			SELECT conv_id FROM messages
			WHERE message_id = '$(sql_escape "$reply_to_msg")' OR id = '$(sql_escape "$reply_to_msg")'
			LIMIT 1;
		")
	fi

	if [[ -z "$conv_id" ]]; then
		conv_id=$(generate_id "conv")
		db "$DB_FILE" "
			INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
			VALUES ('$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$subject")', '$(sql_escape "$to_email")', '$(sql_escape "$from_email")', 'active');
		"
	fi

	# Add In-Reply-To header if replying
	if [[ -n "$reply_to_msg" ]]; then
		local original_message_id
		original_message_id=$(db "$DB_FILE" "
			SELECT message_id FROM messages
			WHERE id = '$(sql_escape "$reply_to_msg")' OR message_id = '$(sql_escape "$reply_to_msg")'
			LIMIT 1;
		")
		if [[ -n "$original_message_id" ]]; then
			# SES doesn't support custom headers in basic send-email
			# Use send-raw-email for threading headers
			local raw_message
			raw_message=$(printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s' \
				"$from_email" "$to_email" "$subject" "$original_message_id" "$original_message_id" "$body")

			local encoded_message
			encoded_message=$(printf '%s' "$raw_message" | base64 | tr -d '\n')

			local ses_result
			ses_result=$(aws ses send-raw-email \
				--raw-message "Data=$encoded_message" \
				--query 'MessageId' --output text 2>&1) || {
				print_error "Failed to send email: $ses_result"
				return 1
			}

			local msg_id
			msg_id=$(generate_id "msg")
			db "$DB_FILE" "
				INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, ses_message_id, in_reply_to)
				VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'outbound', '$(sql_escape "$from_email")', '$(sql_escape "$to_email")', '$(sql_escape "$subject")', '$(sql_escape "$body")', '$(sql_escape "$ses_result")', '$(sql_escape "$original_message_id")');
			"

			# Update conversation timestamp
			db "$DB_FILE" "
				UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'waiting'
				WHERE id = '$(sql_escape "$conv_id")';
			"

			print_success "Sent reply: $msg_id (SES: $ses_result) in conversation $conv_id"
			echo "$msg_id"
			return 0
		fi
	fi

	# Standard send — build JSON input for safe escaping of all characters
	local ses_input_json ses_tmpfile
	ses_input_json=$(jq -n \
		--arg from "$from_email" \
		--arg to "$to_email" \
		--arg subject "$subject" \
		--arg body "$body" \
		'{
			Source: $from,
			Destination: { ToAddresses: [$to] },
			Message: {
				Subject: { Data: $subject },
				Body: { Text: { Data: $body } }
			}
		}')
	ses_tmpfile=$(mktemp)
	printf '%s' "$ses_input_json" >"$ses_tmpfile"

	local ses_result
	ses_result=$(aws ses send-email \
		--cli-input-json "file://${ses_tmpfile}" \
		--query 'MessageId' --output text 2>&1) || {
		rm -f "$ses_tmpfile"
		print_error "Failed to send email: $ses_result"
		return 1
	}
	rm -f "$ses_tmpfile"

	local msg_id
	msg_id=$(generate_id "msg")
	db "$DB_FILE" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, ses_message_id)
		VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'outbound', '$(sql_escape "$from_email")', '$(sql_escape "$to_email")', '$(sql_escape "$subject")', '$(sql_escape "$body")', '$(sql_escape "$ses_result")');
	"

	# Update conversation to waiting for response
	db "$DB_FILE" "
		UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'waiting'
		WHERE id = '$(sql_escape "$conv_id")';
	"

	print_success "Sent: $msg_id (SES: $ses_result) in conversation $conv_id"
	echo "$msg_id"
	return 0
}

# ============================================================================
# Poll command — retrieve new emails from S3
# ============================================================================

cmd_poll() {
	local mission_id="" since=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		--since)
			[[ $# -lt 2 ]] && {
				print_error "--since requires a value"
				return 1
			}
			# Validate and normalize to ISO 8601 (YYYY-MM-DDTHH:MM:SSZ)
			# Accept: ISO 8601 with/without time, with Z/+offset, or date-only
			# GNU date uses -d, BSD/macOS date uses -j -f
			if since=$(date -d "$2" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
				: # GNU date succeeded
			elif since=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$2" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
				: # BSD date with full ISO format
			elif since=$(date -j -u -f '%Y-%m-%d' "$2" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
				: # BSD date with date-only format
			else
				print_error "Invalid date format for --since: '$2' (expected ISO 8601, e.g. 2026-01-15T00:00:00Z or 2026-01-15)"
				return 1
			fi
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mission_id" ]]; then
		print_error "Mission ID is required (--mission M001)"
		return 1
	fi

	check_dependencies || return 1
	load_config || return 1
	set_aws_credentials || return 1
	ensure_db

	local s3_bucket
	s3_bucket=$(get_config_value '.s3_receive_bucket' '')
	if [[ -z "$s3_bucket" ]]; then
		print_error "S3 receive bucket not configured. Set s3_receive_bucket in config"
		return 1
	fi

	local s3_prefix
	s3_prefix=$(get_config_value '.s3_receive_prefix' 'incoming/')

	# Create local download directory
	local download_dir="${WORKSPACE_DIR}/inbox/${mission_id}"
	mkdir -p "$download_dir"

	# List new objects in S3
	local list_args=(s3api list-objects-v2 --bucket "$s3_bucket" --prefix "$s3_prefix")
	if [[ -n "$since" ]]; then
		# S3 doesn't support date filtering natively; we filter client-side
		true
	fi

	local objects_json
	objects_json=$(aws "${list_args[@]}" --output json 2>/dev/null) || {
		print_error "Failed to list S3 objects in $s3_bucket/$s3_prefix"
		return 1
	}

	local object_count
	object_count=$(echo "$objects_json" | jq -r '.KeyCount // 0')
	if [[ "$object_count" -eq 0 ]]; then
		print_info "No new emails in $s3_bucket/$s3_prefix"
		return 0
	fi

	local ingested=0
	local keys
	keys=$(echo "$objects_json" | jq -r '.Contents[]?.Key // empty')

	while IFS= read -r s3_key; do
		[[ -z "$s3_key" ]] && continue

		# Skip if already ingested
		local already_exists
		already_exists=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE s3_key = '$(sql_escape "$s3_key")';")
		if [[ "$already_exists" -gt 0 ]]; then
			continue
		fi

		# Filter by date if --since specified
		if [[ -n "$since" ]]; then
			local obj_date
			obj_date=$(echo "$objects_json" | jq -r --arg s3_key "$s3_key" '.Contents[] | select(.Key == $s3_key) | .LastModified' 2>/dev/null)
			if [[ -n "$obj_date" && "$obj_date" < "$since" ]]; then
				continue
			fi
		fi

		# Download the email
		local local_file="${download_dir}/$(basename "$s3_key")"
		aws s3 cp "s3://${s3_bucket}/${s3_key}" "$local_file" --quiet 2>/dev/null || {
			print_warning "Failed to download: $s3_key"
			continue
		}

		# Parse the email
		local parsed_json=""
		if [[ -x "$EMAIL_TO_MD_SCRIPT" ]] && command -v python3 &>/dev/null; then
			parsed_json=$(python3 "$EMAIL_TO_MD_SCRIPT" "$local_file" --json 2>/dev/null || echo "")
		fi

		# Extract basic fields from raw email if python parsing fails
		local from_addr="" to_addr="" subj="" msg_id_header="" in_reply_to="" body_text=""
		if [[ -n "$parsed_json" ]]; then
			from_addr=$(echo "$parsed_json" | jq -r '.from // empty' 2>/dev/null)
			to_addr=$(echo "$parsed_json" | jq -r '.to // empty' 2>/dev/null)
			subj=$(echo "$parsed_json" | jq -r '.subject // empty' 2>/dev/null)
			msg_id_header=$(echo "$parsed_json" | jq -r '.message_id // empty' 2>/dev/null)
			in_reply_to=$(echo "$parsed_json" | jq -r '.in_reply_to // empty' 2>/dev/null)
			body_text=$(echo "$parsed_json" | jq -r '.body_text // empty' 2>/dev/null)
		else
			# Fallback: grep headers from raw .eml
			from_addr=$(grep -m1 -i '^From: ' "$local_file" 2>/dev/null | sed 's/^[Ff]rom: //' || echo "unknown")
			to_addr=$(grep -m1 -i '^To: ' "$local_file" 2>/dev/null | sed 's/^[Tt]o: //' || echo "unknown")
			subj=$(grep -m1 -i '^Subject: ' "$local_file" 2>/dev/null | sed 's/^[Ss]ubject: //' || echo "(no subject)")
			msg_id_header=$(grep -m1 -i '^Message-ID: ' "$local_file" 2>/dev/null | sed 's/^[Mm]essage-[Ii][Dd]: //' || echo "")
			in_reply_to=$(grep -m1 -i '^In-Reply-To: ' "$local_file" 2>/dev/null | sed 's/^[Ii]n-[Rr]eply-[Tt]o: //' || echo "")
			# Extract body (everything after first blank line)
			body_text=$(sed -n '/^$/,$ { /^$/d; p; }' "$local_file" 2>/dev/null | head -200 || echo "")
		fi

		# Find matching conversation by In-Reply-To or subject+email
		local conv_id=""
		if [[ -n "$in_reply_to" ]]; then
			conv_id=$(db "$DB_FILE" "
				SELECT conv_id FROM messages
				WHERE (message_id = '$(sql_escape "$in_reply_to")' OR ses_message_id = '$(sql_escape "$in_reply_to")')
				AND mission_id = '$(sql_escape "$mission_id")'
				LIMIT 1;
			")
		fi

		if [[ -z "$conv_id" ]]; then
			# Try matching by subject (strip Re:/Fwd: prefixes) and email address
			local clean_subject
			clean_subject=$(echo "$subj" | sed -E 's/^(Re|Fwd|FW|Fw): *//gi')
			conv_id=$(db "$DB_FILE" "
				SELECT id FROM conversations
				WHERE mission_id = '$(sql_escape "$mission_id")'
				AND (to_email = '$(sql_escape "$from_addr")' OR from_email = '$(sql_escape "$from_addr")')
				AND subject LIKE '%$(sql_escape "$clean_subject")%'
				LIMIT 1;
			")
		fi

		# Create new conversation if no match
		if [[ -z "$conv_id" ]]; then
			conv_id=$(generate_id "conv")
			db "$DB_FILE" "
				INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
				VALUES ('$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$subj")', '$(sql_escape "$to_addr")', '$(sql_escape "$from_addr")', 'active');
			"
		fi

		# Store the message
		local ea_msg_id
		ea_msg_id=$(generate_id "msg")
		db "$DB_FILE" "
			INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, message_id, in_reply_to, s3_key, raw_path)
			VALUES ('$(sql_escape "$ea_msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'inbound', '$(sql_escape "$from_addr")', '$(sql_escape "$to_addr")', '$(sql_escape "$subj")', '$(sql_escape "$body_text")', '$(sql_escape "$msg_id_header")', '$(sql_escape "$in_reply_to")', '$(sql_escape "$s3_key")', '$(sql_escape "$local_file")');
		"

		# Update conversation
		db "$DB_FILE" "
			UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'active'
			WHERE id = '$(sql_escape "$conv_id")';
		"

		# Auto-extract verification codes
		extract_codes_from_text "$ea_msg_id" "$mission_id" "$body_text"

		ingested=$((ingested + 1))
		log_info "Ingested: $ea_msg_id from $from_addr (conv: $conv_id)"
	done <<<"$keys"

	if [[ "$ingested" -gt 0 ]]; then
		print_success "Polled $ingested new emails for mission $mission_id"
	else
		print_info "No new emails for mission $mission_id"
	fi

	return 0
}

# ============================================================================
# Verification code extraction
# ============================================================================

# Extract codes from text and store in database
extract_codes_from_text() {
	local msg_id="$1"
	local mission_id="$2"
	local text="$3"

	[[ -z "$text" ]] && return 0

	local found=0

	# Check OTP/code patterns
	local pattern
	for pattern in "${CODE_PATTERNS[@]}"; do
		local matches
		matches=$(echo "$text" | grep -oE "$pattern" 2>/dev/null || true)
		if [[ -n "$matches" ]]; then
			while IFS= read -r match; do
				[[ -z "$match" ]] && continue
				# Extract just the code value — strip leading label (e.g. "Code: ", "Token is ")
				# then require at least one digit to avoid matching keywords
				local code_value normalized
				normalized=$(echo "$match" | sed -E 's/^[[:alpha:]][[:alpha:] ]*(:[[:space:]]*|[[:space:]]+is[[:space:]]+)//')
				code_value=$(echo "$normalized" | grep -oE '[0-9A-Za-z_-]{4,}' | grep '[0-9]' | head -1 || echo "")
				if [[ -z "$code_value" ]]; then
					# Fallback: try extracting pure digit sequences
					code_value=$(echo "$match" | grep -oE '[0-9]{4,}' | head -1 || echo "")
				fi
				[[ -z "$code_value" ]] && continue

				local code_type="otp"
				if echo "$match" | grep -qi 'token'; then
					code_type="token"
				elif echo "$match" | grep -qi 'api.key\|apikey'; then
					code_type="api_key"
				elif echo "$match" | grep -qi 'password\|passwd'; then
					code_type="password"
				fi

				# Avoid duplicates
				local exists
				exists=$(db "$DB_FILE" "
					SELECT count(*) FROM extracted_codes
					WHERE message_id = '$(sql_escape "$msg_id")' AND code_value = '$(sql_escape "$code_value")';
				")
				if [[ "$exists" -eq 0 ]]; then
					db "$DB_FILE" "
						INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value, confidence)
						VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$code_type")', '$(sql_escape "$code_value")', 0.9);
					"
					found=$((found + 1))
					log_info "Extracted $code_type: ${code_value:0:4}*** from $msg_id"
				fi
			done <<<"$matches"
		fi
	done

	# Check confirmation/activation link patterns
	local link_pattern
	for link_pattern in "${LINK_PATTERNS[@]}"; do
		local link_matches
		link_matches=$(echo "$text" | grep -oE "$link_pattern" 2>/dev/null || true)
		if [[ -n "$link_matches" ]]; then
			while IFS= read -r link; do
				[[ -z "$link" ]] && continue

				local exists
				exists=$(db "$DB_FILE" "
					SELECT count(*) FROM extracted_codes
					WHERE message_id = '$(sql_escape "$msg_id")' AND code_value = '$(sql_escape "$link")';
				")
				if [[ "$exists" -eq 0 ]]; then
					db "$DB_FILE" "
						INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value, confidence)
						VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$mission_id")', 'link', '$(sql_escape "$link")', 0.85);
					"
					found=$((found + 1))
					log_info "Extracted confirmation link from $msg_id"
				fi
			done <<<"$link_matches"
		fi
	done

	if [[ "$found" -gt 0 ]]; then
		print_success "Extracted $found codes/links from message $msg_id"
	fi

	return 0
}

cmd_extract_codes() {
	local message_id="" mission_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--message)
			[[ $# -lt 2 ]] && {
				print_error "--message requires a value"
				return 1
			}
			message_id="$2"
			shift 2
			;;
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ -n "$message_id" ]]; then
		# Extract from specific message
		local body_text
		body_text=$(db "$DB_FILE" "SELECT body_text FROM messages WHERE id = '$(sql_escape "$message_id")';")
		if [[ -z "$body_text" ]]; then
			print_error "Message not found: $message_id"
			return 1
		fi
		local msg_mission
		msg_mission=$(db "$DB_FILE" "SELECT mission_id FROM messages WHERE id = '$(sql_escape "$message_id")';")
		extract_codes_from_text "$message_id" "$msg_mission" "$body_text"
	elif [[ -n "$mission_id" ]]; then
		# Extract from all unprocessed messages in mission
		# Fetch IDs only — body_text may contain pipes and newlines that break
		# pipe-separated parsing, so we fetch each body in a separate query.
		local message_ids
		message_ids=$(db "$DB_FILE" "
			SELECT m.id FROM messages m
			LEFT JOIN extracted_codes ec ON m.id = ec.message_id
			WHERE m.mission_id = '$(sql_escape "$mission_id")'
			AND m.direction = 'inbound'
			AND ec.id IS NULL
			AND m.body_text IS NOT NULL;
		")
		if [[ -z "$message_ids" ]]; then
			print_info "No unprocessed inbound messages for mission $mission_id"
			return 0
		fi
		while IFS= read -r mid; do
			[[ -z "$mid" ]] && continue
			local body
			body=$(db "$DB_FILE" "SELECT body_text FROM messages WHERE id = '$(sql_escape "$mid")';")
			extract_codes_from_text "$mid" "$mission_id" "$body"
		done <<<"$message_ids"
	else
		print_error "Specify --message <id> or --mission <id>"
		return 1
	fi

	# Show extracted codes
	local where_clause=""
	if [[ -n "$mission_id" ]]; then
		where_clause="WHERE mission_id = '$(sql_escape "$mission_id")'"
	elif [[ -n "$message_id" ]]; then
		where_clause="WHERE message_id = '$(sql_escape "$message_id")'"
	fi

	local codes
	codes=$(db -separator '|' "$DB_FILE" "
		SELECT code_type, code_value, confidence, used, created_at
		FROM extracted_codes $where_clause
		ORDER BY created_at DESC;
	")

	if [[ -n "$codes" ]]; then
		echo ""
		echo "Extracted Codes:"
		echo "================"
		while IFS='|' read -r ctype cval conf used created; do
			local status_label="available"
			if [[ "$used" -eq 1 ]]; then
				status_label="used"
			fi
			# Mask sensitive values
			local display_val
			if [[ ${#cval} -gt 8 ]]; then
				display_val="${cval:0:4}...${cval: -4}"
			else
				display_val="${cval:0:2}****"
			fi
			echo "  [$ctype] $display_val (confidence: $conf, $status_label, $created)"
		done <<<"$codes"
	fi

	return 0
}

# ============================================================================
# Thread / conversation commands
# ============================================================================

cmd_thread() {
	local mission_id="" conv_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		--conversation)
			[[ $# -lt 2 ]] && {
				print_error "--conversation requires a value"
				return 1
			}
			conv_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mission_id" && -z "$conv_id" ]]; then
		print_error "Specify --mission <id> or --conversation <id>"
		return 1
	fi

	ensure_db

	if [[ -n "$conv_id" ]]; then
		# Show specific conversation thread
		local conv_info
		conv_info=$(db -separator '|' "$DB_FILE" "
			SELECT id, mission_id, subject, to_email, from_email, status, created_at
			FROM conversations WHERE id = '$(sql_escape "$conv_id")';
		")
		if [[ -z "$conv_info" ]]; then
			print_error "Conversation not found: $conv_id"
			return 1
		fi

		local cid cmission csubject cto cfrom cstatus ccreated
		IFS='|' read -r cid cmission csubject cto cfrom cstatus ccreated <<<"$conv_info"

		echo "Conversation: $cid"
		echo "  Mission:  $cmission"
		echo "  Subject:  $csubject"
		echo "  Between:  $cfrom <-> $cto"
		echo "  Status:   $cstatus"
		echo "  Started:  $ccreated"
		echo ""
		echo "Messages:"
		echo "---------"

		local messages
		messages=$(db -separator '|' "$DB_FILE" "
			SELECT id, direction, from_email, subject, created_at,
				   substr(body_text, 1, 200) as preview
			FROM messages
			WHERE conv_id = '$(sql_escape "$conv_id")'
			ORDER BY created_at ASC;
		")

		if [[ -n "$messages" ]]; then
			while IFS='|' read -r mid mdir mfrom msubj mcreated mpreview; do
				local arrow="<-"
				if [[ "$mdir" == "outbound" ]]; then
					arrow="->"
				fi
				echo "  [$mcreated] $arrow $mfrom"
				echo "    Subject: $msubj"
				if [[ -n "$mpreview" ]]; then
					echo "    Preview: ${mpreview:0:120}..."
				fi
				echo ""
			done <<<"$messages"
		else
			echo "  (no messages)"
		fi

		# Show extracted codes for this conversation
		local codes
		codes=$(db -separator '|' "$DB_FILE" "
			SELECT ec.code_type, ec.code_value, ec.confidence, ec.used
			FROM extracted_codes ec
			JOIN messages m ON ec.message_id = m.id
			WHERE m.conv_id = '$(sql_escape "$conv_id")'
			ORDER BY ec.created_at DESC;
		")
		if [[ -n "$codes" ]]; then
			echo "Extracted Codes:"
			while IFS='|' read -r ctype cval conf used; do
				local display_val
				if [[ ${#cval} -gt 8 ]]; then
					display_val="${cval:0:4}...${cval: -4}"
				else
					display_val="${cval:0:2}****"
				fi
				local status_label="available"
				if [[ "$used" -eq 1 ]]; then
					status_label="used"
				fi
				echo "  [$ctype] $display_val ($status_label)"
			done <<<"$codes"
		fi
	else
		# Show all conversations for mission
		cmd_conversations "--mission" "$mission_id"
	fi

	return 0
}

cmd_conversations() {
	local mission_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mission_id" ]]; then
		print_error "Mission ID is required (--mission M001)"
		return 1
	fi

	ensure_db

	local conversations
	conversations=$(db -separator '|' "$DB_FILE" "
		SELECT c.id, c.subject, c.to_email, c.from_email, c.status, c.created_at, c.updated_at,
			   (SELECT count(*) FROM messages WHERE conv_id = c.id) as msg_count,
			   (SELECT count(*) FROM extracted_codes ec JOIN messages m ON ec.message_id = m.id WHERE m.conv_id = c.id) as code_count
		FROM conversations c
		WHERE c.mission_id = '$(sql_escape "$mission_id")'
		ORDER BY c.updated_at DESC;
	")

	if [[ -z "$conversations" ]]; then
		print_info "No conversations for mission $mission_id"
		return 0
	fi

	echo "Conversations for mission $mission_id:"
	echo "========================================"
	while IFS='|' read -r cid csubject cto cfrom cstatus ccreated cupdated msg_count code_count; do
		echo "  [$cstatus] $cid"
		echo "    Subject:  $csubject"
		echo "    With:     $cto <-> $cfrom"
		echo "    Messages: $msg_count | Codes: $code_count"
		echo "    Updated:  $cupdated"
		echo ""
	done <<<"$conversations"

	return 0
}

# ============================================================================
# Status command
# ============================================================================

cmd_status() {
	local mission_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ -n "$mission_id" ]]; then
		local conv_count msg_count code_count
		conv_count=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mission_id")';")
		msg_count=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE mission_id = '$(sql_escape "$mission_id")';")
		code_count=$(db "$DB_FILE" "SELECT count(*) FROM extracted_codes WHERE mission_id = '$(sql_escape "$mission_id")';")

		local waiting_count
		waiting_count=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mission_id")' AND status = 'waiting';")

		echo "Email Agent Status (Mission: $mission_id)"
		echo "==========================================="
		echo "  Conversations: $conv_count ($waiting_count awaiting response)"
		echo "  Messages:      $msg_count"
		echo "  Codes found:   $code_count"
	else
		local total_conv total_msg total_codes
		total_conv=$(db "$DB_FILE" "SELECT count(*) FROM conversations;")
		total_msg=$(db "$DB_FILE" "SELECT count(*) FROM messages;")
		total_codes=$(db "$DB_FILE" "SELECT count(*) FROM extracted_codes;")

		local missions
		missions=$(db "$DB_FILE" "SELECT DISTINCT mission_id FROM conversations ORDER BY mission_id;")

		echo "Email Agent Status (All Missions)"
		echo "==================================="
		echo "  Total conversations: $total_conv"
		echo "  Total messages:      $total_msg"
		echo "  Total codes found:   $total_codes"
		echo "  Database:            $DB_FILE"

		if [[ -n "$missions" ]]; then
			echo ""
			echo "  Active missions:"
			while IFS= read -r mid; do
				local mc mm
				mc=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mid")';")
				mm=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE mission_id = '$(sql_escape "$mid")';")
				echo "    $mid: $mc conversations, $mm messages"
			done <<<"$missions"
		fi
	fi

	return 0
}

# ============================================================================
# Help
# ============================================================================

show_help() {
	cat <<'EOF'
email-agent-helper.sh - Autonomous 3rd-party email communication for missions

Usage:
  email-agent-helper.sh send --mission <id> --to <email> [options]
  email-agent-helper.sh poll --mission <id> [--since <ISO-date>]
  email-agent-helper.sh extract-codes --message <msg-id> | --mission <id>
  email-agent-helper.sh thread --mission <id> [--conversation <conv-id>]
  email-agent-helper.sh conversations --mission <id>
  email-agent-helper.sh status [--mission <id>]
  email-agent-helper.sh help

Send Options:
  --mission <id>       Mission ID (required)
  --to <email>         Recipient email (required)
  --template <file>    Template file with {{variable}} placeholders
  --vars 'k=v,k=v'    Template variable substitutions
  --subject <text>     Email subject (or from template Subject: header)
  --body <text>        Email body (or from template)
  --from <email>       Sender email (or from config default_from_email)
  --reply-to <msg-id>  Reply to a previous message (adds In-Reply-To header)

Poll Options:
  --mission <id>       Mission ID (required)
  --since <ISO-date>   Only poll emails after this date (ISO 8601 format,
                       e.g. 2026-01-15T00:00:00Z or 2026-01-15)

Extract Options:
  --message <msg-id>   Extract codes from specific message
  --mission <id>       Extract codes from all unprocessed mission messages

Thread Options:
  --mission <id>       Show all conversations for mission
  --conversation <id>  Show specific conversation thread

Verification Code Types:
  otp        Numeric codes (4-8 digits)
  token      Alphanumeric tokens (20+ chars)
  link       Confirmation/activation URLs
  api_key    API keys
  password   Temporary passwords

Template Format:
  Subject: Your API Access Request for {{service_name}}

  Dear {{contact_name}},

  I am writing to request API access for {{project_name}}.
  {{custom_message}}

  Best regards,
  {{sender_name}}

Configuration:
  Config file: configs/email-agent-config.json
  Template:    configs/email-agent-config.json.txt

  Required config fields:
    default_from_email   Verified SES sender address
    aws_region           AWS region for SES
    s3_receive_bucket    S3 bucket for SES Receipt Rules
    s3_receive_prefix    S3 prefix for incoming emails

Environment:
  AWS_ACCESS_KEY_ID        AWS credentials (or via gopass/credentials.sh)
  AWS_SECRET_ACCESS_KEY    AWS credentials
  AWS_DEFAULT_REGION       AWS region (overridden by config)

Integration with Missions:
  The email agent integrates with the mission orchestrator:
  1. Mission identifies need for 3rd-party communication
  2. Orchestrator invokes: email-agent-helper.sh send --mission M001 ...
  3. Agent polls for responses: email-agent-helper.sh poll --mission M001
  4. Codes extracted automatically on poll
  5. Mission reads codes: email-agent-helper.sh extract-codes --mission M001
  6. Conversation history: email-agent-helper.sh thread --mission M001

Examples:
  # Send a templated email
  email-agent-helper.sh send --mission M001 --to api@vendor.com \
    --template templates/api-request.md --vars 'service_name=Acme API,project_name=MyProject'

  # Poll for responses
  email-agent-helper.sh poll --mission M001

  # Check for verification codes
  email-agent-helper.sh extract-codes --mission M001

  # View conversation thread
  email-agent-helper.sh thread --mission M001 --conversation conv-20260301-120000-abcd

  # Check status
  email-agent-helper.sh status --mission M001
EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	send) cmd_send "$@" ;;
	poll) cmd_poll "$@" ;;
	extract-codes) cmd_extract_codes "$@" ;;
	thread) cmd_thread "$@" ;;
	conversations) cmd_conversations "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

# Allow sourcing for tests: only run main when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
