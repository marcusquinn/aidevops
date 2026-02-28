#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2155
set -euo pipefail

# Mission Email Helper - 3rd-party communication for autonomous missions
# Extends SES helper with: templated sending, response parsing, verification
# code extraction, and conversation threading.
#
# Usage:
#   mission-email-helper.sh send --account <acct> --from <email> --to <email> \
#       --subject <subj> --template <name> [--vars key=val ...] [--thread-id <id>]
#   mission-email-helper.sh receive --account <acct> --mailbox <s3-bucket/prefix> \
#       [--since <ISO>] [--thread-id <id>]
#   mission-email-helper.sh parse <eml-file|->
#   mission-email-helper.sh extract-code <text|->
#   mission-email-helper.sh thread --list [--mission <id>]
#   mission-email-helper.sh thread --show <thread-id>
#   mission-email-helper.sh thread --create --mission <id> --subject <subj> \
#       --counterparty <email> [--context <text>]
#   mission-email-helper.sh templates [--list|--show <name>]
#   mission-email-helper.sh help
#
# Thread storage: SQLite at ~/.aidevops/.agent-workspace/mail/mission-email.db
# Templates: ~/.aidevops/agents/templates/email/
#
# Integrates with:
#   - ses-helper.sh (SES credentials and sending)
#   - credential-helper.sh (mission credential management)
#   - mission-orchestrator.md (autonomous mission execution)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Configuration
readonly EMAIL_DB_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly EMAIL_DB="$EMAIL_DB_DIR/mission-email.db"
# Template dir: prefer repo-local, fall back to deployed
if [[ -d "${SCRIPT_DIR}/../templates/email" ]]; then
	readonly TEMPLATE_DIR="${SCRIPT_DIR}/../templates/email"
else
	readonly TEMPLATE_DIR="$HOME/.aidevops/agents/templates/email"
fi
readonly SES_HELPER="${SCRIPT_DIR}/ses-helper.sh"
readonly SES_CONFIG="../configs/ses-config.json"

# Logging prefix
# shellcheck disable=SC2034
LOG_PREFIX="MISSION-EMAIL"

#######################################
# SQLite wrapper with busy timeout
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Ensure database exists and is initialized
#######################################
ensure_db() {
	mkdir -p "$EMAIL_DB_DIR"

	if [[ ! -f "$EMAIL_DB" ]]; then
		init_db
		return 0
	fi

	# Ensure WAL mode for existing databases
	local current_mode
	current_mode=$(db "$EMAIL_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$EMAIL_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || log_warn "Failed to enable WAL mode"
	fi

	return 0
}

#######################################
# Initialize SQLite database
#######################################
init_db() {
	db "$EMAIL_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS threads (
    id              TEXT PRIMARY KEY,
    mission_id      TEXT NOT NULL,
    subject         TEXT NOT NULL,
    counterparty    TEXT NOT NULL,
    our_address     TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','waiting','resolved','abandoned')),
    context         TEXT DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_threads_mission ON threads(mission_id);
CREATE INDEX IF NOT EXISTS idx_threads_status ON threads(status);
CREATE INDEX IF NOT EXISTS idx_threads_counterparty ON threads(counterparty);

CREATE TABLE IF NOT EXISTS messages (
    id              TEXT PRIMARY KEY,
    thread_id       TEXT NOT NULL REFERENCES threads(id),
    direction       TEXT NOT NULL CHECK(direction IN ('outbound','inbound')),
    from_addr       TEXT NOT NULL,
    to_addr         TEXT NOT NULL,
    subject         TEXT NOT NULL DEFAULT '',
    body_text       TEXT DEFAULT '',
    body_html       TEXT DEFAULT '',
    ses_message_id  TEXT DEFAULT '',
    template_used   TEXT DEFAULT '',
    raw_headers     TEXT DEFAULT '',
    received_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    parsed_at       TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_messages_direction ON messages(direction);
CREATE INDEX IF NOT EXISTS idx_messages_received ON messages(received_at);

CREATE TABLE IF NOT EXISTS extracted_codes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id      TEXT NOT NULL REFERENCES messages(id),
    code_type       TEXT NOT NULL DEFAULT 'unknown',
    code_value      TEXT NOT NULL,
    extracted_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    used            INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_codes_message ON extracted_codes(message_id);
CREATE INDEX IF NOT EXISTS idx_codes_unused ON extracted_codes(used) WHERE used = 0;
SQL

	log_info "Initialized mission email database: $EMAIL_DB"
	return 0
}

#######################################
# SQL escape helper
#######################################
sql_escape() {
	local input="$1"
	echo "${input//\'/\'\'}"
}

#######################################
# Generate unique ID
# Format: me-YYYYMMDD-HHMMSS-RANDOM
#######################################
generate_id() {
	local prefix="${1:-me}"
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	local random
	random=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
	echo "${prefix}-${timestamp}-${random}"
}

#######################################
# Load and render a template
# Arguments: template_name, key=value pairs
# Output: rendered template text
#######################################
render_template() {
	local template_name="$1"
	shift

	local template_file="${TEMPLATE_DIR}/${template_name}.txt"
	if [[ ! -f "$template_file" ]]; then
		log_error "Template not found: $template_file"
		return 1
	fi

	local content
	content=$(cat "$template_file")

	# Replace {{KEY}} placeholders with provided values
	local pair key val
	for pair in "$@"; do
		key="${pair%%=*}"
		val="${pair#*=}"
		content="${content//\{\{${key}\}\}/${val}}"
	done

	echo "$content"
	return 0
}

#######################################
# Send a templated email via SES
#######################################
cmd_send() {
	local account="" from_addr="" to_addr="" subject="" template="" body=""
	local thread_id="" region=""
	local -a template_vars=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--account)
			[[ $# -lt 2 ]] && {
				log_error "--account requires a value"
				return 1
			}
			account="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				log_error "--from requires a value"
				return 1
			}
			from_addr="$2"
			shift 2
			;;
		--to)
			[[ $# -lt 2 ]] && {
				log_error "--to requires a value"
				return 1
			}
			to_addr="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				log_error "--subject requires a value"
				return 1
			}
			subject="$2"
			shift 2
			;;
		--template)
			[[ $# -lt 2 ]] && {
				log_error "--template requires a value"
				return 1
			}
			template="$2"
			shift 2
			;;
		--body)
			[[ $# -lt 2 ]] && {
				log_error "--body requires a value"
				return 1
			}
			body="$2"
			shift 2
			;;
		--var)
			[[ $# -lt 2 ]] && {
				log_error "--var requires key=value"
				return 1
			}
			template_vars+=("$2")
			shift 2
			;;
		--thread-id)
			[[ $# -lt 2 ]] && {
				log_error "--thread-id requires a value"
				return 1
			}
			thread_id="$2"
			shift 2
			;;
		--region)
			[[ $# -lt 2 ]] && {
				log_error "--region requires a value"
				return 1
			}
			region="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Validate required fields
	if [[ -z "$account" ]]; then
		log_error "Missing --account"
		return 1
	fi
	if [[ -z "$from_addr" ]]; then
		log_error "Missing --from"
		return 1
	fi
	if [[ -z "$to_addr" ]]; then
		log_error "Missing --to"
		return 1
	fi
	if [[ -z "$subject" ]]; then
		log_error "Missing --subject"
		return 1
	fi
	if [[ -z "$template" && -z "$body" ]]; then
		log_error "Either --template or --body is required"
		return 1
	fi

	# Render template if specified
	if [[ -n "$template" ]]; then
		if ! body=$(render_template "$template" "${template_vars[@]}"); then
			return 1
		fi
	fi

	# Load SES credentials from config
	if [[ ! -f "$SES_CONFIG" ]]; then
		log_error "SES config not found: $SES_CONFIG"
		log_info "Copy and customize: cp configs/ses-config.json.txt $SES_CONFIG"
		return 1
	fi

	local account_config
	account_config=$(jq -r ".accounts.\"$account\"" "$SES_CONFIG")
	if [[ "$account_config" == "null" ]]; then
		log_error "Account '$account' not found in SES config"
		return 1
	fi

	local aws_key aws_secret ses_region
	aws_key=$(echo "$account_config" | jq -r '.aws_access_key_id')
	aws_secret=$(echo "$account_config" | jq -r '.aws_secret_access_key')
	ses_region="${region:-$(echo "$account_config" | jq -r '.region // "us-east-1"')}"

	export AWS_ACCESS_KEY_ID="$aws_key"
	export AWS_SECRET_ACCESS_KEY="$aws_secret"
	export AWS_DEFAULT_REGION="$ses_region"

	# Build In-Reply-To header for threading
	local extra_headers=""
	if [[ -n "$thread_id" ]]; then
		ensure_db
		local last_ses_id
		last_ses_id=$(db "$EMAIL_DB" "
			SELECT ses_message_id FROM messages
			WHERE thread_id = '$(sql_escape "$thread_id")'
			AND ses_message_id != ''
			ORDER BY received_at DESC LIMIT 1;
		")
		if [[ -n "$last_ses_id" ]]; then
			extra_headers="In-Reply-To: <${last_ses_id}>"
		fi
	fi

	# Send via SES using raw email for header control
	local raw_message
	raw_message=$(build_raw_email "$from_addr" "$to_addr" "$subject" "$body" "$extra_headers")

	local encoded_message
	encoded_message=$(echo "$raw_message" | base64)

	local send_result
	send_result=$(aws ses send-raw-email \
		--raw-message "Data=${encoded_message}" \
		--query 'MessageId' --output text 2>&1)

	local rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "SES send failed: $send_result"
		return 1
	fi

	local ses_message_id="$send_result"
	log_success "Email sent. SES Message ID: $ses_message_id"

	# Record in database
	ensure_db
	local msg_id
	msg_id=$(generate_id "msg")

	# Auto-create thread if thread_id provided but doesn't exist
	if [[ -n "$thread_id" ]]; then
		local thread_exists
		thread_exists=$(db "$EMAIL_DB" "SELECT count(*) FROM threads WHERE id = '$(sql_escape "$thread_id")';")
		if [[ "$thread_exists" -eq 0 ]]; then
			log_warn "Thread $thread_id not found, creating it"
			db "$EMAIL_DB" "
				INSERT INTO threads (id, mission_id, subject, counterparty, our_address)
				VALUES ('$(sql_escape "$thread_id")', 'unknown', '$(sql_escape "$subject")', '$(sql_escape "$to_addr")', '$(sql_escape "$from_addr")');
			"
		fi
	else
		# Create a new thread for this conversation
		thread_id=$(generate_id "thr")
		db "$EMAIL_DB" "
			INSERT INTO threads (id, mission_id, subject, counterparty, our_address)
			VALUES ('$(sql_escape "$thread_id")', 'unknown', '$(sql_escape "$subject")', '$(sql_escape "$to_addr")', '$(sql_escape "$from_addr")');
		"
	fi

	db "$EMAIL_DB" "
		INSERT INTO messages (id, thread_id, direction, from_addr, to_addr, subject, body_text, ses_message_id, template_used)
		VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$thread_id")', 'outbound', '$(sql_escape "$from_addr")', '$(sql_escape "$to_addr")', '$(sql_escape "$subject")', '$(sql_escape "$body")', '$(sql_escape "$ses_message_id")', '$(sql_escape "$template")');
	"

	# Update thread timestamp
	db "$EMAIL_DB" "
		UPDATE threads SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'waiting'
		WHERE id = '$(sql_escape "$thread_id")';
	"

	echo "thread_id=$thread_id"
	echo "message_id=$msg_id"
	echo "ses_message_id=$ses_message_id"
	return 0
}

#######################################
# Build a raw MIME email
#######################################
build_raw_email() {
	local from_addr="$1"
	local to_addr="$2"
	local subject="$3"
	local body="$4"
	local extra_headers="${5:-}"

	local message_id
	message_id="<$(generate_id "mid")@aidevops.sh>"
	local date_header
	date_header=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

	local raw=""
	raw+="From: ${from_addr}"$'\n'
	raw+="To: ${to_addr}"$'\n'
	raw+="Subject: ${subject}"$'\n'
	raw+="Date: ${date_header}"$'\n'
	raw+="Message-ID: ${message_id}"$'\n'
	raw+="MIME-Version: 1.0"$'\n'
	raw+="Content-Type: text/plain; charset=UTF-8"$'\n'
	raw+="Content-Transfer-Encoding: 7bit"$'\n'
	raw+="X-Mailer: aidevops-mission-email/1.0"$'\n'

	if [[ -n "$extra_headers" ]]; then
		raw+="${extra_headers}"$'\n'
	fi

	raw+=$'\n'
	raw+="${body}"$'\n'

	echo "$raw"
	return 0
}

#######################################
# Receive and parse emails from S3 (SES receipt rule destination)
#######################################
cmd_receive() {
	local account="" mailbox="" since="" thread_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--account)
			[[ $# -lt 2 ]] && {
				log_error "--account requires a value"
				return 1
			}
			account="$2"
			shift 2
			;;
		--mailbox)
			[[ $# -lt 2 ]] && {
				log_error "--mailbox requires a value"
				return 1
			}
			mailbox="$2"
			shift 2
			;;
		--since)
			[[ $# -lt 2 ]] && {
				log_error "--since requires ISO date"
				return 1
			}
			since="$2"
			shift 2
			;;
		--thread-id)
			[[ $# -lt 2 ]] && {
				log_error "--thread-id requires a value"
				return 1
			}
			thread_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$account" ]]; then
		log_error "Missing --account"
		return 1
	fi
	if [[ -z "$mailbox" ]]; then
		log_error "Missing --mailbox (S3 bucket/prefix)"
		return 1
	fi

	# Load SES credentials
	local account_config
	account_config=$(jq -r ".accounts.\"$account\"" "$SES_CONFIG")
	if [[ "$account_config" == "null" ]]; then
		log_error "Account '$account' not found"
		return 1
	fi

	local aws_key aws_secret ses_region
	aws_key=$(echo "$account_config" | jq -r '.aws_access_key_id')
	aws_secret=$(echo "$account_config" | jq -r '.aws_secret_access_key')
	ses_region=$(echo "$account_config" | jq -r '.region // "us-east-1"')

	export AWS_ACCESS_KEY_ID="$aws_key"
	export AWS_SECRET_ACCESS_KEY="$aws_secret"
	export AWS_DEFAULT_REGION="$ses_region"

	# Parse bucket and prefix from mailbox
	local bucket prefix
	bucket="${mailbox%%/*}"
	prefix="${mailbox#*/}"
	if [[ "$prefix" == "$bucket" ]]; then
		prefix=""
	fi

	# List objects in S3
	local list_args=("s3api" "list-objects-v2" "--bucket" "$bucket")
	if [[ -n "$prefix" ]]; then
		list_args+=("--prefix" "$prefix")
	fi

	local objects
	objects=$(aws "${list_args[@]}" --query 'Contents[].Key' --output text 2>&1)
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		log_error "Failed to list S3 objects: $objects"
		return 1
	fi

	if [[ -z "$objects" || "$objects" == "None" ]]; then
		log_info "No emails found in $mailbox"
		return 0
	fi

	ensure_db
	local ingested=0
	local tmp_dir
	tmp_dir=$(mktemp -d)

	local key
	for key in $objects; do
		# Skip if already ingested (check by S3 key as a proxy)
		local already_seen
		already_seen=$(db "$EMAIL_DB" "SELECT count(*) FROM messages WHERE raw_headers LIKE '%s3-key: $(sql_escape "$key")%';")
		if [[ "$already_seen" -gt 0 ]]; then
			continue
		fi

		# Download the raw email
		local tmp_file="${tmp_dir}/$(basename "$key")"
		if ! aws s3 cp "s3://${bucket}/${key}" "$tmp_file" --quiet 2>/dev/null; then
			log_warn "Failed to download: s3://${bucket}/${key}"
			continue
		fi

		# Parse the email
		local parsed
		parsed=$(parse_email_file "$tmp_file")
		if [[ -z "$parsed" ]]; then
			log_warn "Failed to parse: $key"
			continue
		fi

		# Extract fields from parsed output
		local from_addr to_addr subj body_text msg_date in_reply_to
		from_addr=$(echo "$parsed" | jq -r '.from // ""')
		to_addr=$(echo "$parsed" | jq -r '.to // ""')
		subj=$(echo "$parsed" | jq -r '.subject // ""')
		body_text=$(echo "$parsed" | jq -r '.body_text // ""')
		msg_date=$(echo "$parsed" | jq -r '.date // ""')
		in_reply_to=$(echo "$parsed" | jq -r '.in_reply_to // ""')

		# Filter by since date if specified
		if [[ -n "$since" && -n "$msg_date" ]]; then
			if [[ "$msg_date" < "$since" ]]; then
				continue
			fi
		fi

		# Match to thread
		local matched_thread=""
		if [[ -n "$thread_id" ]]; then
			matched_thread="$thread_id"
		elif [[ -n "$in_reply_to" ]]; then
			# Find thread by SES message ID reference
			matched_thread=$(db "$EMAIL_DB" "
				SELECT thread_id FROM messages
				WHERE ses_message_id = '$(sql_escape "$in_reply_to")'
				LIMIT 1;
			")
		fi

		if [[ -z "$matched_thread" ]]; then
			# Try matching by counterparty email
			matched_thread=$(db "$EMAIL_DB" "
				SELECT id FROM threads
				WHERE counterparty = '$(sql_escape "$from_addr")'
				AND status IN ('active', 'waiting')
				ORDER BY updated_at DESC LIMIT 1;
			")
		fi

		if [[ -z "$matched_thread" ]]; then
			# Create a new thread for unmatched inbound
			matched_thread=$(generate_id "thr")
			db "$EMAIL_DB" "
				INSERT INTO threads (id, mission_id, subject, counterparty, our_address)
				VALUES ('$(sql_escape "$matched_thread")', 'unknown', '$(sql_escape "$subj")', '$(sql_escape "$from_addr")', '$(sql_escape "$to_addr")');
			"
		fi

		# Store the message
		local msg_id
		msg_id=$(generate_id "msg")
		db "$EMAIL_DB" "
			INSERT INTO messages (id, thread_id, direction, from_addr, to_addr, subject, body_text, raw_headers, received_at)
			VALUES (
				'$(sql_escape "$msg_id")',
				'$(sql_escape "$matched_thread")',
				'inbound',
				'$(sql_escape "$from_addr")',
				'$(sql_escape "$to_addr")',
				'$(sql_escape "$subj")',
				'$(sql_escape "$body_text")',
				's3-key: $(sql_escape "$key")',
				'$(sql_escape "${msg_date:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}")'
			);
		"

		# Update thread
		db "$EMAIL_DB" "
			UPDATE threads SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'active'
			WHERE id = '$(sql_escape "$matched_thread")';
		"

		# Extract verification codes
		extract_and_store_codes "$msg_id" "$body_text"

		ingested=$((ingested + 1))
	done

	rm -rf "$tmp_dir"

	if [[ "$ingested" -gt 0 ]]; then
		log_success "Ingested $ingested emails from $mailbox"
	else
		log_info "No new emails to ingest from $mailbox"
	fi

	return 0
}

#######################################
# Parse a raw email file into JSON
# Uses Python's email module for reliable MIME parsing
#######################################
parse_email_file() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		log_error "File not found: $file"
		return 1
	fi

	python3 -c "
import email
import email.policy
import json
import sys

with open(sys.argv[1], 'rb') as f:
    msg = email.message_from_binary_file(f, policy=email.policy.default)

body_text = ''
body_html = ''
if msg.is_multipart():
    for part in msg.walk():
        ct = part.get_content_type()
        if ct == 'text/plain' and not body_text:
            body_text = part.get_content()
        elif ct == 'text/html' and not body_html:
            body_html = part.get_content()
else:
    ct = msg.get_content_type()
    content = msg.get_content()
    if ct == 'text/html':
        body_html = content
    else:
        body_text = content

result = {
    'from': str(msg.get('From', '')),
    'to': str(msg.get('To', '')),
    'subject': str(msg.get('Subject', '')),
    'date': str(msg.get('Date', '')),
    'message_id': str(msg.get('Message-ID', '')),
    'in_reply_to': str(msg.get('In-Reply-To', '')).strip('<>'),
    'references': str(msg.get('References', '')),
    'body_text': body_text if isinstance(body_text, str) else str(body_text),
    'body_html': body_html if isinstance(body_html, str) else str(body_html),
}
print(json.dumps(result))
" "$file" 2>/dev/null

	return $?
}

#######################################
# Parse command: parse an email from file or stdin
#######################################
cmd_parse() {
	local input="${1:--}"

	if [[ "$input" == "-" ]]; then
		local tmp_file
		tmp_file=$(mktemp)
		cat >"$tmp_file"
		parse_email_file "$tmp_file"
		local rc=$?
		rm -f "$tmp_file"
		return $rc
	fi

	if [[ ! -f "$input" ]]; then
		log_error "File not found: $input"
		return 1
	fi

	parse_email_file "$input"
	return $?
}

#######################################
# Extract verification/confirmation codes from text
# Supports: 6-digit codes, alphanumeric tokens, URLs with tokens
# Output: JSON array of {type, value} objects
#######################################
extract_codes() {
	local text="$1"

	python3 -c "
import re
import json
import sys

text = sys.argv[1]
codes = []

# 6-digit numeric codes (most common verification codes)
for m in re.finditer(r'(?:code|pin|otp|verification|confirm)[^0-9]{0,30}(\d{4,8})', text, re.IGNORECASE):
    codes.append({'type': 'numeric_code', 'value': m.group(1)})

# Standalone 6-digit codes on their own line or after colon
for m in re.finditer(r'(?:^|:\s*|is\s+)(\d{6})(?:\s*$|[.\s])', text, re.MULTILINE):
    val = m.group(1)
    if not any(c['value'] == val for c in codes):
        codes.append({'type': 'numeric_code', 'value': val})

# Alphanumeric tokens (API keys, confirmation tokens)
for m in re.finditer(r'(?:token|key|code|secret)[^a-zA-Z0-9]{0,20}([A-Za-z0-9_-]{16,64})', text, re.IGNORECASE):
    val = m.group(1)
    if not any(c['value'] == val for c in codes):
        codes.append({'type': 'token', 'value': val})

# Verification/confirmation URLs
for m in re.finditer(r'(https?://[^\s<>\"]+(?:verify|confirm|activate|validate|token|code)[^\s<>\"]*)', text, re.IGNORECASE):
    val = m.group(1).rstrip('.')
    if not any(c['value'] == val for c in codes):
        codes.append({'type': 'verification_url', 'value': val})

# Password reset / temporary password patterns
for m in re.finditer(r'(?:password|temporary\s+password)[^a-zA-Z0-9]{0,20}([A-Za-z0-9!@#\$%^&*_-]{8,32})', text, re.IGNORECASE):
    val = m.group(1)
    if not any(c['value'] == val for c in codes):
        codes.append({'type': 'temporary_password', 'value': val})

print(json.dumps(codes))
" "$text" 2>/dev/null

	return $?
}

#######################################
# Extract codes command: from text or stdin
#######################################
cmd_extract_code() {
	local input="${1:--}"
	local text

	if [[ "$input" == "-" ]]; then
		text=$(cat)
	elif [[ -f "$input" ]]; then
		text=$(cat "$input")
	else
		text="$input"
	fi

	local codes
	codes=$(extract_codes "$text")
	echo "$codes"

	local count
	count=$(echo "$codes" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
	if [[ "$count" -gt 0 ]]; then
		log_success "Extracted $count code(s)/token(s)"
	else
		log_info "No verification codes found"
	fi

	return 0
}

#######################################
# Extract codes from message body and store in DB
#######################################
extract_and_store_codes() {
	local message_id="$1"
	local body_text="$2"

	if [[ -z "$body_text" ]]; then
		return 0
	fi

	local codes
	codes=$(extract_codes "$body_text")
	if [[ -z "$codes" || "$codes" == "[]" ]]; then
		return 0
	fi

	local count
	count=$(echo "$codes" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

	if [[ "$count" -gt 0 ]]; then
		echo "$codes" | python3 -c "
import json, sys
codes = json.load(sys.stdin)
for c in codes:
    # Output tab-separated for shell consumption
    print(f\"{c['type']}\t{c['value']}\")
" | while IFS=$'\t' read -r code_type code_value; do
			db "$EMAIL_DB" "
				INSERT INTO extracted_codes (message_id, code_type, code_value)
				VALUES ('$(sql_escape "$message_id")', '$(sql_escape "$code_type")', '$(sql_escape "$code_value")');
			"
		done

		log_info "Extracted $count code(s) from message $message_id"
	fi

	return 0
}

#######################################
# Thread management commands
#######################################
cmd_thread() {
	local action="" thread_id="" mission_id="" subject="" counterparty="" context=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--list)
			action="list"
			shift
			;;
		--show)
			[[ $# -lt 2 ]] && {
				log_error "--show requires thread-id"
				return 1
			}
			action="show"
			thread_id="$2"
			shift 2
			;;
		--create)
			action="create"
			shift
			;;
		--mission)
			[[ $# -lt 2 ]] && {
				log_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				log_error "--subject requires a value"
				return 1
			}
			subject="$2"
			shift 2
			;;
		--counterparty)
			[[ $# -lt 2 ]] && {
				log_error "--counterparty requires a value"
				return 1
			}
			counterparty="$2"
			shift 2
			;;
		--context)
			[[ $# -lt 2 ]] && {
				log_error "--context requires a value"
				return 1
			}
			context="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	case "$action" in
	list)
		local where_clause="1=1"
		if [[ -n "$mission_id" ]]; then
			where_clause="mission_id = '$(sql_escape "$mission_id")'"
		fi

		local results
		results=$(db -separator '|' "$EMAIL_DB" "
			SELECT t.id, t.mission_id, t.subject, t.counterparty, t.status, t.updated_at,
				(SELECT count(*) FROM messages m WHERE m.thread_id = t.id) as msg_count,
				(SELECT count(*) FROM extracted_codes ec JOIN messages m2 ON ec.message_id = m2.id WHERE m2.thread_id = t.id AND ec.used = 0) as pending_codes
			FROM threads t
			WHERE $where_clause
			ORDER BY t.updated_at DESC;
		")

		echo "Email Threads"
		echo "============="
		if [[ -z "$results" ]]; then
			echo "  (no threads)"
			return 0
		fi

		while IFS='|' read -r tid mid subj cp status updated msgs codes; do
			echo ""
			echo "  [$status] $tid"
			echo "    Mission:      $mid"
			echo "    Subject:      $subj"
			echo "    Counterparty: $cp"
			echo "    Messages:     $msgs"
			if [[ "$codes" -gt 0 ]]; then
				echo "    Pending codes: $codes"
			fi
			echo "    Updated:      $updated"
		done <<<"$results"
		;;

	show)
		if [[ -z "$thread_id" ]]; then
			log_error "Thread ID required"
			return 1
		fi

		local thread_info
		thread_info=$(db -separator '|' "$EMAIL_DB" "
			SELECT id, mission_id, subject, counterparty, our_address, status, context, created_at, updated_at
			FROM threads WHERE id = '$(sql_escape "$thread_id")';
		")

		if [[ -z "$thread_info" ]]; then
			log_error "Thread not found: $thread_id"
			return 1
		fi

		local tid mid subj cp our_addr status ctx created updated
		IFS='|' read -r tid mid subj cp our_addr status ctx created updated <<<"$thread_info"

		echo "Thread: $tid"
		echo "  Mission:      $mid"
		echo "  Subject:      $subj"
		echo "  Counterparty: $cp"
		echo "  Our address:  $our_addr"
		echo "  Status:       $status"
		echo "  Created:      $created"
		echo "  Updated:      $updated"
		if [[ -n "$ctx" ]]; then
			echo "  Context:      $ctx"
		fi

		echo ""
		echo "Messages:"
		echo "---------"

		local messages
		messages=$(db -separator '|' "$EMAIL_DB" "
			SELECT id, direction, from_addr, to_addr, subject, body_text, received_at
			FROM messages
			WHERE thread_id = '$(sql_escape "$thread_id")'
			ORDER BY received_at ASC;
		")

		if [[ -z "$messages" ]]; then
			echo "  (no messages)"
		else
			while IFS='|' read -r mid dir from_a to_a msg_subj msg_body recv_at; do
				local arrow
				if [[ "$dir" == "outbound" ]]; then
					arrow=">>>"
				else
					arrow="<<<"
				fi
				echo ""
				echo "  $arrow [$recv_at] $from_a -> $to_a"
				echo "      Subject: $msg_subj"
				echo "      ${msg_body:0:200}"
				if [[ ${#msg_body} -gt 200 ]]; then
					echo "      ... (truncated)"
				fi
			done <<<"$messages"
		fi

		# Show extracted codes
		local codes
		codes=$(db -separator '|' "$EMAIL_DB" "
			SELECT ec.code_type, ec.code_value, ec.used, ec.extracted_at
			FROM extracted_codes ec
			JOIN messages m ON ec.message_id = m.id
			WHERE m.thread_id = '$(sql_escape "$thread_id")'
			ORDER BY ec.extracted_at DESC;
		")

		if [[ -n "$codes" ]]; then
			echo ""
			echo "Extracted Codes:"
			echo "----------------"
			while IFS='|' read -r ctype cval cused cat; do
				local used_label="unused"
				if [[ "$cused" -eq 1 ]]; then
					used_label="USED"
				fi
				echo "  [$used_label] $ctype: $cval (extracted: $cat)"
			done <<<"$codes"
		fi
		;;

	create)
		if [[ -z "$mission_id" ]]; then
			log_error "Missing --mission"
			return 1
		fi
		if [[ -z "$subject" ]]; then
			log_error "Missing --subject"
			return 1
		fi
		if [[ -z "$counterparty" ]]; then
			log_error "Missing --counterparty"
			return 1
		fi

		local new_thread_id
		new_thread_id=$(generate_id "thr")

		db "$EMAIL_DB" "
			INSERT INTO threads (id, mission_id, subject, counterparty, context)
			VALUES ('$(sql_escape "$new_thread_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$subject")', '$(sql_escape "$counterparty")', '$(sql_escape "$context")');
		"

		log_success "Created thread: $new_thread_id"
		echo "thread_id=$new_thread_id"
		;;

	*)
		log_error "Thread command requires --list, --show, or --create"
		return 1
		;;
	esac

	return 0
}

#######################################
# Template management
#######################################
cmd_templates() {
	local action="list" template_name=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--list)
			action="list"
			shift
			;;
		--show)
			[[ $# -lt 2 ]] && {
				log_error "--show requires template name"
				return 1
			}
			action="show"
			template_name="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	case "$action" in
	list)
		echo "Email Templates"
		echo "==============="
		echo "  Directory: $TEMPLATE_DIR"
		echo ""

		if [[ ! -d "$TEMPLATE_DIR" ]]; then
			echo "  (no templates directory - run setup to create)"
			return 0
		fi

		local template_file
		for template_file in "$TEMPLATE_DIR"/*.txt; do
			[[ -f "$template_file" ]] || continue
			local name
			name=$(basename "$template_file" .txt)
			local first_line
			first_line=$(head -1 "$template_file")
			echo "  $name - $first_line"
		done
		;;

	show)
		local template_file="${TEMPLATE_DIR}/${template_name}.txt"
		if [[ ! -f "$template_file" ]]; then
			log_error "Template not found: $template_name"
			log_info "Available templates in: $TEMPLATE_DIR"
			return 1
		fi

		echo "Template: $template_name"
		echo "========================"
		cat "$template_file"
		;;
	esac

	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'EOF'
mission-email-helper.sh - Email communication for autonomous missions

Usage:
  mission-email-helper.sh send --account <acct> --from <email> --to <email> \
      --subject <subj> [--template <name> --var key=val ...] [--body <text>] \
      [--thread-id <id>]
  mission-email-helper.sh receive --account <acct> --mailbox <s3-bucket/prefix> \
      [--since <ISO>] [--thread-id <id>]
  mission-email-helper.sh parse <eml-file|->
  mission-email-helper.sh extract-code <text-file|->
  mission-email-helper.sh thread --list [--mission <id>]
  mission-email-helper.sh thread --show <thread-id>
  mission-email-helper.sh thread --create --mission <id> --subject <subj> \
      --counterparty <email> [--context <text>]
  mission-email-helper.sh templates [--list|--show <name>]
  mission-email-helper.sh help

Commands:
  send            Send a templated or plain email via SES
  receive         Fetch and parse emails from S3 (SES receipt rule)
  parse           Parse a raw .eml file into structured JSON
  extract-code    Extract verification codes, tokens, URLs from text
  thread          Manage conversation threads
  templates       List or show email templates

Send Options:
  --account       SES account name from ses-config.json
  --from          Sender email address (must be SES-verified)
  --to            Recipient email address
  --subject       Email subject line
  --template      Template name (from templates/email/*.txt)
  --var           Template variable (key=value), repeatable
  --body          Plain text body (alternative to --template)
  --thread-id     Attach to existing conversation thread
  --region        Override SES region

Receive Options:
  --account       SES account name
  --mailbox       S3 bucket/prefix where SES stores received emails
  --since         Only process emails after this ISO date
  --thread-id     Only match emails to this thread

Thread Statuses:
  active          Conversation in progress
  waiting         We sent, waiting for reply
  resolved        Conversation complete
  abandoned       No longer needed

Templates:
  Templates use {{KEY}} placeholders replaced by --var arguments.
  Store templates in: ~/.aidevops/agents/templates/email/

Integration:
  - SES credentials: configs/ses-config.json (same as ses-helper.sh)
  - Mission state: thread IDs recorded in mission.md Resources table
  - Credential management: extracted codes available for credential-helper.sh
  - Orchestrator: dispatches email tasks, checks for responses

Examples:
  # Send API access request
  mission-email-helper.sh send --account production \
    --from noreply@yourdomain.com --to api-support@vendor.com \
    --subject "API Access Request" \
    --template api-access-request \
    --var COMPANY_NAME="My Company" --var USE_CASE="Automated integration"

  # Check for responses
  mission-email-helper.sh receive --account production \
    --mailbox my-ses-bucket/inbound

  # Extract verification code from email text
  echo "Your code is 847291" | mission-email-helper.sh extract-code -

  # List all threads for a mission
  mission-email-helper.sh thread --list --mission m001

  # View full conversation
  mission-email-helper.sh thread --show thr-20260228-143022-a1b2c3d4
EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	send) cmd_send "$@" ;;
	receive) cmd_receive "$@" ;;
	parse) cmd_parse "$@" ;;
	extract-code) cmd_extract_code "$@" ;;
	thread) cmd_thread "$@" ;;
	templates) cmd_templates "$@" ;;
	help | --help | -h) show_help ;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
