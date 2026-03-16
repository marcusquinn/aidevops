#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Email Composition Helper for AI DevOps Framework
# AI-assisted email drafting with human review before sending.
# Provides draft-review-send workflow, tone calibration, signature injection,
# attachment handling, CC/BCC logic, and legal liability awareness.
#
# Usage:
#   email-compose-helper.sh draft --to <email> [options]
#   email-compose-helper.sh reply --message-id <id> [options]
#   email-compose-helper.sh forward --message-id <id> --to <email> [options]
#   email-compose-helper.sh acknowledge --to <email> [options]
#   email-compose-helper.sh follow-up --to <email> [options]
#   email-compose-helper.sh remind --to <email> [options]
#   email-compose-helper.sh notify --to <email> [options]
#   email-compose-helper.sh help
#
# Model routing:
#   --importance high   → opus (important emails, legal, client-facing)
#   --importance normal → sonnet (routine correspondence)
#   --importance low    → haiku (acknowledgements, brief notifications)
#
# Requires: jq, $EDITOR (or VISUAL), optional: aws CLI for sending via SES
# Config: configs/email-compose-config.json (from .json.txt template)
# Credentials: aidevops secret set EMAIL_FROM / AWS_ACCESS_KEY_ID
#
# Part of aidevops email system (t1495)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================================
# Constants
# ============================================================================

readonly COMPOSE_VERSION="1.0.0"
readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly CONFIG_FILE="${CONFIG_DIR}/email-compose-config.json"
readonly WORKSPACE_DIR="${EMAIL_COMPOSE_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/email-compose}"
readonly DRAFTS_DIR="${WORKSPACE_DIR}/drafts"
readonly SENT_DIR="${WORKSPACE_DIR}/sent"

# Attachment limits (bytes)
readonly ATTACH_WARN_BYTES=$((25 * 1024 * 1024))  # 25 MB
readonly ATTACH_BLOCK_BYTES=$((30 * 1024 * 1024)) # 30 MB

# Overused phrases to flag (case-insensitive)
readonly -a OVERUSED_PHRASES=(
	"quick question"
	"just following up"
	"just checking in"
	"hope this finds you well"
	"hope you are well"
	"hope you're doing well"
	"as per my last email"
	"per my previous email"
	"going forward"
	"circle back"
	"touch base"
	"reach out"
	"synergy"
	"leverage"
	"paradigm shift"
	"move the needle"
	"low-hanging fruit"
	"bandwidth"
	"deep dive"
	"at the end of the day"
)

# ============================================================================
# Configuration
# ============================================================================

load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		# Use defaults if no config — non-fatal
		return 0
	fi
	return 0
}

get_config_value() {
	local key="$1"
	local default="${2:-}"

	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo "$default"
		return 0
	fi

	local value
	value=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

# ============================================================================
# Workspace setup
# ============================================================================

ensure_workspace() {
	mkdir -p "$DRAFTS_DIR" "$SENT_DIR"
	return 0
}

generate_draft_id() {
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	local random
	random=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
	echo "draft-${timestamp}-${random}"
	return 0
}

# ============================================================================
# Signature injection
# ============================================================================

get_signature() {
	local sig_name="${1:-default}"

	# 1. Check config for named signature
	if [[ -f "$CONFIG_FILE" ]]; then
		local sig
		sig=$(jq -r ".signatures.${sig_name} // empty" "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$sig" ]]; then
			echo "$sig"
			return 0
		fi
	fi

	# 2. Check for signature file
	local sig_file="${CONFIG_DIR}/email-signature-${sig_name}.txt"
	if [[ -f "$sig_file" ]]; then
		cat "$sig_file"
		return 0
	fi

	# 3. Try Apple Mail signature parser if available
	local sig_parser="${SCRIPT_DIR}/email-signature-parser-helper.sh"
	if [[ -x "$sig_parser" ]]; then
		local parsed
		parsed=$("$sig_parser" get-default 2>/dev/null || echo "")
		if [[ -n "$parsed" ]]; then
			echo "$parsed"
			return 0
		fi
	fi

	# 4. Return empty — no signature configured
	echo ""
	return 0
}

# ============================================================================
# Attachment validation
# ============================================================================

validate_attachment() {
	local file_path="$1"

	if [[ ! -f "$file_path" ]]; then
		print_error "Attachment not found: $file_path"
		return 1
	fi

	local file_size
	file_size=$(wc -c <"$file_path" 2>/dev/null || echo "0")

	if [[ "$file_size" -ge "$ATTACH_BLOCK_BYTES" ]]; then
		print_error "Attachment too large ($((file_size / 1024 / 1024))MB). Max 30MB. Use a file-share link instead."
		print_info "For confidential files, use PrivateBin with self-destruct: https://privatebin.net"
		return 1
	fi

	if [[ "$file_size" -ge "$ATTACH_WARN_BYTES" ]]; then
		print_warning "Attachment is large ($((file_size / 1024 / 1024))MB). Consider a file-share link for files over 25MB."
		print_info "For confidential files, use PrivateBin with self-destruct: https://privatebin.net"
	fi

	return 0
}

# ============================================================================
# Overused phrase detection
# ============================================================================

check_overused_phrases() {
	local body="$1"
	local found=0

	local phrase
	for phrase in "${OVERUSED_PHRASES[@]}"; do
		local lower_body
		lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')
		local lower_phrase
		lower_phrase=$(echo "$phrase" | tr '[:upper:]' '[:lower:]')
		if echo "$lower_body" | grep -qF "$lower_phrase" 2>/dev/null; then
			print_warning "Overused phrase detected: \"$phrase\" — consider rephrasing"
			found=$((found + 1))
		fi
	done

	return 0
}

# ============================================================================
# Tone detection
# ============================================================================

detect_tone() {
	local recipient="$1"
	local context="${2:-}"

	# Check config for recipient-specific tone
	if [[ -f "$CONFIG_FILE" ]]; then
		local domain
		domain=$(echo "$recipient" | sed 's/.*@//')
		local tone
		tone=$(jq -r ".tone_overrides.\"${domain}\" // empty" "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$tone" ]]; then
			echo "$tone"
			return 0
		fi
	fi

	# Default: formal for business domains, casual for known personal domains
	local personal_domains="gmail.com hotmail.com yahoo.com outlook.com icloud.com me.com"
	local domain
	domain=$(echo "$recipient" | sed 's/.*@//')
	if echo "$personal_domains" | grep -qw "$domain" 2>/dev/null; then
		echo "casual"
	else
		echo "formal"
	fi
	return 0
}

# ============================================================================
# AI composition via ai-research MCP
# ============================================================================

compose_with_ai() {
	local command="$1"
	local to_email="$2"
	local subject="$3"
	local context="$4"
	local tone="$5"
	local importance="$6"
	local extra_instructions="${7:-}"

	# Map importance to model tier
	local model="sonnet"
	case "$importance" in
	high | urgent) model="opus" ;;
	low | brief) model="haiku" ;;
	*) model="sonnet" ;;
	esac

	local signature
	signature=$(get_signature)

	local sig_block=""
	if [[ -n "$signature" ]]; then
		sig_block="

Signature to append:
${signature}"
	fi

	local prompt
	prompt="You are composing a professional email. Follow these rules strictly:

COMPOSITION RULES:
1. One sentence per paragraph (improves mobile readability and threading)
2. Clear subject line that describes the email's purpose
3. Numbered lists for multiple questions or action items
4. Clear CTA (call to action) if a response is needed
5. Tone: ${tone} (formal = professional/respectful, casual = friendly/direct)
6. NEVER use these overused phrases: quick question, just following up, just checking in, hope this finds you well, circle back, touch base, reach out, synergy, leverage, paradigm shift, move the needle, low-hanging fruit, bandwidth, deep dive, at the end of the day
7. Legal awareness: distinguish clearly between what is agreed, what is advised, and what is informational
8. Do NOT add urgency flags unless the context explicitly requires it
9. Keep it concise — every sentence must earn its place

COMMAND: ${command}
TO: ${to_email}
SUBJECT: ${subject}
CONTEXT: ${context}
${extra_instructions:+ADDITIONAL INSTRUCTIONS: ${extra_instructions}}
${sig_block}

Output ONLY the email body text (no JSON, no markdown fences, no meta-commentary).
Start with the salutation. End with the closing and signature if provided."

	# Use ai-research MCP tool if available, otherwise output placeholder
	if command -v ai-research &>/dev/null; then
		ai-research --prompt "$prompt" --model "$model" 2>/dev/null || echo "[AI composition unavailable — edit draft manually]"
	else
		# Fallback: structured template
		cat <<TEMPLATE
[AI composition requires ai-research tool — edit this draft manually]

Subject: ${subject}

Dear [Recipient],

[Your message here]

[Closing],
[Your name]
${signature}
TEMPLATE
	fi
	return 0
}

# ============================================================================
# Draft review workflow
# ============================================================================

open_draft_for_review() {
	local draft_file="$1"

	local editor="${VISUAL:-${EDITOR:-vi}}"

	print_info "Opening draft for review in ${editor}..."
	print_info "Save and close to continue. Delete all content to abort."

	"$editor" "$draft_file"

	# Check if user deleted content (abort signal)
	if [[ ! -s "$draft_file" ]]; then
		print_warning "Draft is empty — aborting send."
		return 1
	fi

	return 0
}

save_draft() {
	local draft_id="$1"
	local to_email="$2"
	local subject="$3"
	local body="$4"
	local cc="${5:-}"
	local bcc="${6:-}"
	local attachments="${7:-}"

	local draft_file="${DRAFTS_DIR}/${draft_id}.md"

	cat >"$draft_file" <<DRAFT
---
draft_id: ${draft_id}
to: ${to_email}
cc: ${cc}
bcc: ${bcc}
subject: ${subject}
attachments: ${attachments}
created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
status: draft
---

${body}
DRAFT

	echo "$draft_file"
	return 0
}

read_draft_body() {
	local draft_file="$1"

	# Strip YAML frontmatter (between --- delimiters) and return body
	awk '/^---$/{if(++c==2){found=1;next}} found{print}' "$draft_file"
	return 0
}

read_draft_field() {
	local draft_file="$1"
	local field="$2"

	grep "^${field}:" "$draft_file" 2>/dev/null | sed "s/^${field}: *//" | head -1
	return 0
}

# ============================================================================
# Send via SES (delegates to email-agent-helper.sh if available)
# ============================================================================

send_email() {
	local to_email="$1"
	local subject="$2"
	local body="$3"
	local from_email="${4:-}"
	local cc="${5:-}"
	local bcc="${6:-}"

	# Resolve from address
	if [[ -z "$from_email" ]]; then
		from_email=$(get_config_value '.default_from_email' '')
	fi
	if [[ -z "$from_email" ]]; then
		print_error "No from address configured. Set default_from_email in config or use --from."
		return 1
	fi

	# Prefer email-agent-helper.sh for actual sending (handles SES credentials)
	local agent_helper="${SCRIPT_DIR}/email-agent-helper.sh"
	if [[ -x "$agent_helper" ]]; then
		local send_args=(--to "$to_email" --subject "$subject" --body "$body" --from "$from_email")
		# Use a synthetic mission ID for composition-originated emails
		send_args+=(--mission "compose")
		"$agent_helper" send "${send_args[@]}"
		return $?
	fi

	# Fallback: direct SES send
	if ! command -v aws &>/dev/null; then
		print_error "AWS CLI not found. Install: brew install awscli"
		return 1
	fi

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

	print_success "Sent: $ses_result"
	return 0
}

# ============================================================================
# Confirm before send
# ============================================================================

confirm_send() {
	local to_email="$1"
	local subject="$2"

	echo ""
	echo "Ready to send:"
	echo "  To:      $to_email"
	echo "  Subject: $subject"
	echo ""
	printf "Send? [y/N] "
	read -r answer
	case "$answer" in
	[yY] | [yY][eE][sS]) return 0 ;;
	*) return 1 ;;
	esac
}

# ============================================================================
# Parse common options
# ============================================================================

parse_common_opts() {
	# Sets variables in caller scope via nameref-free approach:
	# opt_to, opt_subject, opt_context, opt_from, opt_cc, opt_bcc,
	# opt_importance, opt_tone, opt_attachments, opt_no_review, opt_dry_run
	# Remaining args left in "$@" after parsing

	opt_to=""
	opt_subject=""
	opt_context=""
	opt_from=""
	opt_cc=""
	opt_bcc=""
	opt_importance="normal"
	opt_tone=""
	opt_attachments=""
	opt_no_review=0
	opt_dry_run=0
	opt_signature="default"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			[[ $# -lt 2 ]] && {
				print_error "--to requires a value"
				return 1
			}
			opt_to="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				print_error "--subject requires a value"
				return 1
			}
			opt_subject="$2"
			shift 2
			;;
		--context | --message | --body)
			[[ $# -lt 2 ]] && {
				print_error "$1 requires a value"
				return 1
			}
			opt_context="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				print_error "--from requires a value"
				return 1
			}
			opt_from="$2"
			shift 2
			;;
		--cc)
			[[ $# -lt 2 ]] && {
				print_error "--cc requires a value"
				return 1
			}
			opt_cc="$2"
			shift 2
			;;
		--bcc)
			[[ $# -lt 2 ]] && {
				print_error "--bcc requires a value"
				return 1
			}
			opt_bcc="$2"
			shift 2
			;;
		--importance)
			[[ $# -lt 2 ]] && {
				print_error "--importance requires a value"
				return 1
			}
			opt_importance="$2"
			shift 2
			;;
		--tone)
			[[ $# -lt 2 ]] && {
				print_error "--tone requires a value"
				return 1
			}
			opt_tone="$2"
			shift 2
			;;
		--attach)
			[[ $# -lt 2 ]] && {
				print_error "--attach requires a value"
				return 1
			}
			opt_attachments="${opt_attachments:+${opt_attachments},}$2"
			shift 2
			;;
		--signature)
			[[ $# -lt 2 ]] && {
				print_error "--signature requires a value"
				return 1
			}
			opt_signature="$2"
			shift 2
			;;
		--no-review)
			opt_no_review=1
			shift
			;;
		--dry-run)
			opt_dry_run=1
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	return 0
}

# ============================================================================
# draft command — compose new email, hold for review
# ============================================================================

cmd_draft() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	parse_common_opts "$@" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi
	if [[ -z "$opt_subject" ]]; then
		print_error "Subject required: --subject 'Your subject'"
		return 1
	fi

	ensure_workspace
	load_config

	# Validate attachments
	if [[ -n "$opt_attachments" ]]; then
		local attach
		IFS=',' read -ra attach_list <<<"$opt_attachments"
		for attach in "${attach_list[@]}"; do
			validate_attachment "$attach" || return 1
		done
	fi

	# Detect tone if not specified
	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	print_info "Composing draft (tone: ${opt_tone}, importance: ${opt_importance})..."

	local body
	body=$(compose_with_ai "draft" "$opt_to" "$opt_subject" "$opt_context" "$opt_tone" "$opt_importance")

	# Check for overused phrases
	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$opt_subject" "$body" "$opt_cc" "$opt_bcc" "$opt_attachments")

	print_success "Draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== DRAFT PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	# Re-read body after potential edits
	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$opt_subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$opt_subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"

	# Archive sent draft
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Email sent and archived."
	return 0
}

# ============================================================================
# reply command — compose reply to an existing message
# ============================================================================

cmd_reply() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	local opt_message_id="" opt_reply_all=0

	# Parse reply-specific options first
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--message-id)
			[[ $# -lt 2 ]] && {
				print_error "--message-id requires a value"
				return 1
			}
			opt_message_id="$2"
			shift 2
			;;
		--reply-all)
			opt_reply_all=1
			shift
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	parse_common_opts "${args[@]}" || return 1

	if [[ -z "$opt_to" && -z "$opt_message_id" ]]; then
		print_error "Specify --to <email> or --message-id <id> to reply"
		return 1
	fi

	ensure_workspace
	load_config

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "${opt_to:-reply}" "$opt_context")
	fi

	local reply_context="Reply to message"
	if [[ -n "$opt_message_id" ]]; then
		reply_context="Reply to message ID: ${opt_message_id}"
	fi
	if [[ -n "$opt_context" ]]; then
		reply_context="${reply_context}. Context: ${opt_context}"
	fi

	local reply_type="reply"
	if [[ "$opt_reply_all" -eq 1 ]]; then
		reply_type="reply-all"
	fi

	print_info "Composing ${reply_type} (tone: ${opt_tone}, importance: ${opt_importance})..."

	local subject="${opt_subject:-Re: [original subject]}"
	local body
	body=$(compose_with_ai "reply" "${opt_to:-[original sender]}" "$subject" "$reply_context" "$opt_tone" "$opt_importance")

	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "${opt_to:-[original sender]}" "$subject" "$body" "$opt_cc" "$opt_bcc" "$opt_attachments")

	print_success "Reply draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== REPLY DRAFT PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "${opt_to:-[original sender]}" "${final_subject:-$subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "${opt_to:-}" "${final_subject:-$subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Reply sent and archived."
	return 0
}

# ============================================================================
# forward command — forward with optional commentary
# ============================================================================

cmd_forward() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	local opt_message_id=""

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--message-id)
			[[ $# -lt 2 ]] && {
				print_error "--message-id requires a value"
				return 1
			}
			opt_message_id="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	parse_common_opts "${args[@]}" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi

	ensure_workspace
	load_config

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	local fwd_context="Forward message"
	if [[ -n "$opt_message_id" ]]; then
		fwd_context="Forward message ID: ${opt_message_id}"
	fi
	if [[ -n "$opt_context" ]]; then
		fwd_context="${fwd_context}. Commentary: ${opt_context}"
	fi

	local subject="${opt_subject:-Fwd: [original subject]}"

	print_info "Composing forward (tone: ${opt_tone}, importance: ${opt_importance})..."

	local body
	body=$(compose_with_ai "forward" "$opt_to" "$subject" "$fwd_context" "$opt_tone" "$opt_importance")

	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$subject" "$body" "$opt_cc" "$opt_bcc" "$opt_attachments")

	print_success "Forward draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== FORWARD DRAFT PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Forward sent and archived."
	return 0
}

# ============================================================================
# acknowledge command — holding-pattern response (sent immediately by default)
# ============================================================================

cmd_acknowledge() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	parse_common_opts "$@" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi

	ensure_workspace
	load_config

	# Acknowledgements are brief — default to haiku unless overridden
	if [[ "$opt_importance" == "normal" ]]; then
		opt_importance="low"
	fi

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	local subject="${opt_subject:-Re: [original subject]}"
	local ack_context="Acknowledgement email: confirm receipt, manage expectations for full response. Context: ${opt_context:-received their message}"

	print_info "Composing acknowledgement (haiku-tier, tone: ${opt_tone})..."

	local body
	body=$(compose_with_ai "acknowledge" "$opt_to" "$subject" "$ack_context" "$opt_tone" "$opt_importance" \
		"Keep this very brief — 2-3 sentences maximum. Confirm receipt, state when a full response will follow.")

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$subject" "$body" "$opt_cc" "$opt_bcc" "")

	print_success "Acknowledgement draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== ACKNOWLEDGEMENT PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Acknowledgement sent."
	return 0
}

# ============================================================================
# follow-up command — follow up when replying is delayed
# ============================================================================

cmd_follow_up() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	local opt_days_since="3"

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days-since)
			[[ $# -lt 2 ]] && {
				print_error "--days-since requires a value"
				return 1
			}
			opt_days_since="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	parse_common_opts "${args[@]}" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi

	ensure_workspace
	load_config

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	local subject="${opt_subject:-Re: [original subject]}"
	local followup_context="Follow-up email: ${opt_days_since} days since last contact. Confirm awareness of pending response. Context: ${opt_context:-awaiting response}"

	print_info "Composing follow-up (tone: ${opt_tone}, importance: ${opt_importance})..."

	local body
	body=$(compose_with_ai "follow-up" "$opt_to" "$subject" "$followup_context" "$opt_tone" "$opt_importance" \
		"Acknowledge the delay, confirm you are still working on it, give a realistic timeline. Do NOT use 'just following up' or 'just checking in'.")

	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$subject" "$body" "$opt_cc" "$opt_bcc" "")

	print_success "Follow-up draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== FOLLOW-UP PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Follow-up sent."
	return 0
}

# ============================================================================
# remind command — reminder for things we asked for
# ============================================================================

cmd_remind() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	local opt_original_date=""

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--original-date)
			[[ $# -lt 2 ]] && {
				print_error "--original-date requires a value"
				return 1
			}
			opt_original_date="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	parse_common_opts "${args[@]}" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi

	ensure_workspace
	load_config

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	local subject="${opt_subject:-Reminder: [original subject]}"
	local remind_context="Reminder email for something we requested"
	if [[ -n "$opt_original_date" ]]; then
		remind_context="${remind_context} (originally requested: ${opt_original_date})"
	fi
	if [[ -n "$opt_context" ]]; then
		remind_context="${remind_context}. Context: ${opt_context}"
	fi

	print_info "Composing reminder (tone: ${opt_tone}, importance: ${opt_importance})..."

	local body
	body=$(compose_with_ai "remind" "$opt_to" "$subject" "$remind_context" "$opt_tone" "$opt_importance" \
		"Politely remind them of the outstanding request. Reference the original request date if provided. Be direct but not pushy.")

	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$subject" "$body" "$opt_cc" "$opt_bcc" "")

	print_success "Reminder draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== REMINDER PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Reminder sent."
	return 0
}

# ============================================================================
# notify command — project update notification
# ============================================================================

cmd_notify() {
	local opt_to opt_subject opt_context opt_from opt_cc opt_bcc
	local opt_importance opt_tone opt_attachments opt_no_review opt_dry_run opt_signature
	local opt_project=""

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--project)
			[[ $# -lt 2 ]] && {
				print_error "--project requires a value"
				return 1
			}
			opt_project="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	parse_common_opts "${args[@]}" || return 1

	if [[ -z "$opt_to" ]]; then
		print_error "Recipient required: --to user@example.com"
		return 1
	fi
	if [[ -z "$opt_subject" ]]; then
		print_error "Subject required: --subject 'Project Update: ...'"
		return 1
	fi

	ensure_workspace
	load_config

	if [[ -z "$opt_tone" ]]; then
		opt_tone=$(detect_tone "$opt_to" "$opt_context")
	fi

	local notify_context="Project update notification"
	if [[ -n "$opt_project" ]]; then
		notify_context="${notify_context} for project: ${opt_project}"
	fi
	if [[ -n "$opt_context" ]]; then
		notify_context="${notify_context}. Update details: ${opt_context}"
	fi

	print_info "Composing notification (tone: ${opt_tone}, importance: ${opt_importance})..."

	local body
	body=$(compose_with_ai "notify" "$opt_to" "$opt_subject" "$notify_context" "$opt_tone" "$opt_importance" \
		"Project update notification. State what happened, what it means for the recipient, and any action required from them (if any).")

	check_overused_phrases "$body"

	local draft_id
	draft_id=$(generate_draft_id)

	local draft_file
	draft_file=$(save_draft "$draft_id" "$opt_to" "$opt_subject" "$body" "$opt_cc" "$opt_bcc" "$opt_attachments")

	print_success "Notification draft saved: $draft_file"

	if [[ "$opt_dry_run" -eq 1 ]]; then
		echo ""
		echo "=== NOTIFICATION PREVIEW ==="
		cat "$draft_file"
		echo "=== END DRAFT ==="
		return 0
	fi

	if [[ "$opt_no_review" -eq 0 ]]; then
		open_draft_for_review "$draft_file" || {
			print_info "Send aborted."
			return 0
		}
	fi

	local final_body
	final_body=$(read_draft_body "$draft_file")
	local final_subject
	final_subject=$(read_draft_field "$draft_file" "subject")

	confirm_send "$opt_to" "${final_subject:-$opt_subject}" || {
		print_info "Send cancelled. Draft saved at: $draft_file"
		return 0
	}

	send_email "$opt_to" "${final_subject:-$opt_subject}" "$final_body" "$opt_from" "$opt_cc" "$opt_bcc"
	mv "$draft_file" "${SENT_DIR}/$(basename "$draft_file")"
	print_success "Notification sent."
	return 0
}

# ============================================================================
# list command — show saved drafts
# ============================================================================

cmd_list() {
	ensure_workspace

	local show_sent=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--sent)
			show_sent=1
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local target_dir="$DRAFTS_DIR"
	local label="Drafts"
	if [[ "$show_sent" -eq 1 ]]; then
		target_dir="$SENT_DIR"
		label="Sent"
	fi

	local files
	files=$(ls -t "${target_dir}"/*.md 2>/dev/null || echo "")

	if [[ -z "$files" ]]; then
		print_info "No ${label} found in ${target_dir}"
		return 0
	fi

	echo "${label}:"
	echo "========"
	while IFS= read -r f; do
		[[ -z "$f" ]] && continue
		local to subject created
		to=$(read_draft_field "$f" "to")
		subject=$(read_draft_field "$f" "subject")
		created=$(read_draft_field "$f" "created")
		echo "  $(basename "$f")"
		echo "    To:      ${to}"
		echo "    Subject: ${subject}"
		echo "    Created: ${created}"
		echo ""
	done <<<"$files"

	return 0
}

# ============================================================================
# Help
# ============================================================================

show_help() {
	cat <<EOF
email-compose-helper.sh v${COMPOSE_VERSION} - AI-assisted email composition

Usage:
  email-compose-helper.sh draft --to <email> --subject <text> [options]
  email-compose-helper.sh reply --to <email> [--message-id <id>] [options]
  email-compose-helper.sh forward --to <email> [--message-id <id>] [options]
  email-compose-helper.sh acknowledge --to <email> [options]
  email-compose-helper.sh follow-up --to <email> [--days-since <n>] [options]
  email-compose-helper.sh remind --to <email> [--original-date <date>] [options]
  email-compose-helper.sh notify --to <email> --subject <text> [options]
  email-compose-helper.sh list [--sent]
  email-compose-helper.sh help

Commands:
  draft        Compose new email — AI drafts, human reviews before send
  reply        Compose reply (auto-detect reply vs reply-all)
  forward      Forward with optional commentary
  acknowledge  Send brief holding-pattern response (receipt confirmation)
  follow-up    Follow up when replying is delayed
  remind       Reminder for outstanding requests
  notify       Project update notification
  list         Show saved drafts (--sent for sent archive)

Common Options:
  --to <email>         Recipient (required for most commands)
  --subject <text>     Email subject
  --context <text>     Context for AI composition (what the email is about)
  --from <email>       Sender (or from config default_from_email)
  --cc <email>         CC recipients (comma-separated)
  --bcc <email>        BCC recipients (comma-separated)
  --importance <level> high (opus) | normal (sonnet) | low (haiku)
  --tone <tone>        formal | casual (auto-detected from recipient if omitted)
  --attach <file>      Attachment path (validates size, warns >25MB, blocks >30MB)
  --signature <name>   Signature name from config (default: "default")
  --no-review          Skip editor review (use with caution)
  --dry-run            Preview draft without opening editor or sending

Reply Options:
  --message-id <id>    Message ID to reply to (for threading)
  --reply-all          Reply to all recipients

Follow-up Options:
  --days-since <n>     Days since last contact (default: 3)

Remind Options:
  --original-date <d>  Date of original request

Notify Options:
  --project <name>     Project name for context

Model Routing:
  --importance high    → opus  (client-facing, legal, important)
  --importance normal  → sonnet (routine correspondence)
  --importance low     → haiku  (acknowledgements, brief notifications)

Attachment Limits:
  >25MB  Warning — consider file-share link
  >30MB  Blocked — use file-share link
  Confidential files: use PrivateBin (https://privatebin.net) with self-destruct

Overused Phrases (auto-detected and flagged):
  "quick question", "just following up", "hope this finds you well",
  "circle back", "touch base", "synergy", "leverage", and more

Configuration:
  Config: configs/email-compose-config.json (from .json.txt template)
  Signatures: configs/email-signature-<name>.txt or config .signatures.<name>
  Tone overrides: config .tone_overrides.<domain>

Workflow:
  1. Command composes draft via AI
  2. Draft saved to ~/.aidevops/.agent-workspace/email-compose/drafts/
  3. Editor opens for human review (unless --no-review)
  4. Confirm send prompt
  5. Sent archive: ~/.aidevops/.agent-workspace/email-compose/sent/

Examples:
  # Compose new email
  email-compose-helper.sh draft --to client@example.com \\
    --subject "Project Update: Phase 2 Complete" \\
    --context "Phase 2 delivered on time, Phase 3 starts Monday" \\
    --importance high

  # Quick acknowledgement
  email-compose-helper.sh acknowledge --to support@vendor.com \\
    --subject "Re: Your inquiry" \\
    --context "received their support ticket, will respond within 24h"

  # Follow up on delayed response
  email-compose-helper.sh follow-up --to partner@example.com \\
    --subject "Re: Partnership proposal" \\
    --days-since 5

  # Reminder for outstanding request
  email-compose-helper.sh remind --to contractor@example.com \\
    --subject "Invoice #1234" \\
    --original-date "2026-03-01" \\
    --context "invoice for February work, payment due 30 days"

  # Dry run preview
  email-compose-helper.sh draft --to test@example.com \\
    --subject "Test" --context "test email" --dry-run

Related:
  email-agent-helper.sh    — Autonomous mission email (send/poll/extract)
  email-mailbox.md         — Mailbox management and triage
  email-composition.md     — Composition guidance and tone calibration
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
	draft) cmd_draft "$@" ;;
	reply) cmd_reply "$@" ;;
	forward) cmd_forward "$@" ;;
	acknowledge | ack) cmd_acknowledge "$@" ;;
	follow-up | followup) cmd_follow_up "$@" ;;
	remind) cmd_remind "$@" ;;
	notify) cmd_notify "$@" ;;
	list) cmd_list "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

# Allow sourcing for tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
