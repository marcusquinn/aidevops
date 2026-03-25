#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Receipt/Invoice Forwarding Helper with Phishing Protection
# Detects transaction emails, verifies sender authenticity via DNS (SPF/DKIM/DMARC),
# forwards verified emails to accounts@ address, and flags suspicious ones for review.
#
# Usage:
#   email-receipt-forward-helper.sh process <email-file>
#   email-receipt-forward-helper.sh scan-mailbox [--mailbox <name>] [--since <ISO-date>]
#   email-receipt-forward-helper.sh verify-sender <from-address>
#   email-receipt-forward-helper.sh detect <email-file>
#   email-receipt-forward-helper.sh forward <email-file> [--dry-run]
#   email-receipt-forward-helper.sh flag <email-file> --reason <reason>
#   email-receipt-forward-helper.sh status
#   email-receipt-forward-helper.sh help
#
# Options:
#   --accounts-email <addr>   Override accounts@ destination (default: from config)
#   --dry-run                 Show what would happen without sending
#   --verbose                 Verbose output
#   --since <ISO-date>        Scan emails since this date (default: 24h ago)
#   --mailbox <name>          Mailbox name to scan (default: INBOX)
#
# Config: ~/.config/aidevops/email-receipt-forward.json
# Credentials: aidevops secret set EMAIL_RECEIPT_FORWARD_ACCOUNTS_EMAIL
#
# Dependencies: dig, jq, aws (SES), python3
# Part of aidevops email system (t1507)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly VERSION="1.0.0"
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly CONFIG_FILE="${CONFIG_DIR}/email-receipt-forward.json"
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/email-receipt-forward"
readonly FLAGGED_DIR="${WORKSPACE_DIR}/flagged"
readonly PROCESSED_DIR="${WORKSPACE_DIR}/processed"
readonly LOG_FILE="${WORKSPACE_DIR}/receipt-forward.log"

# DNS verification score thresholds
readonly SCORE_PASS=2
readonly SCORE_WARN=1
readonly SCORE_FAIL=0

# Common DKIM selectors (same as email-health-check-helper.sh)
readonly DKIM_SELECTORS="google google1 google2 selector1 selector2 k1 k2 s1 s2 pm smtp zoho default dkim"

# =============================================================================
# Transaction email detection patterns
# Subject line keywords indicating receipts/invoices/payment confirmations
# =============================================================================

# Receipt/invoice subject patterns (case-insensitive)
readonly TRANSACTION_SUBJECT_PATTERNS=(
	"receipt"
	"invoice"
	"payment confirmation"
	"payment received"
	"order confirmation"
	"order receipt"
	"purchase confirmation"
	"subscription renewal"
	"billing statement"
	"statement of account"
	"tax invoice"
	"pro forma"
	"proforma"
	"credit note"
	"debit note"
	"refund confirmation"
	"charge confirmation"
	"transaction confirmation"
	"your order"
	"your purchase"
	"your subscription"
	"renewal notice"
	"payment processed"
	"payment successful"
	"payment failed"
	"auto-renewal"
	"autorenewal"
)

# Known legitimate accounting/payment sender domains
# These are well-known services — still verify DNS, but lower suspicion threshold
readonly KNOWN_ACCOUNTING_DOMAINS=(
	"stripe.com"
	"paypal.com"
	"paypal.co.uk"
	"quickfile.co.uk"
	"xero.com"
	"freshbooks.com"
	"invoiceninja.com"
	"wave.com"
	"sage.com"
	"intuit.com"
	"quickbooks.com"
	"zoho.com"
	"shopify.com"
	"amazon.co.uk"
	"amazon.com"
	"aws.amazon.com"
	"digitalocean.com"
	"cloudflare.com"
	"github.com"
	"atlassian.com"
	"slack.com"
	"notion.so"
	"google.com"
	"microsoft.com"
	"apple.com"
)

# Phishing red-flag patterns in subject/body
readonly PHISHING_SUBJECT_PATTERNS=(
	"urgent.*payment"
	"immediate.*action"
	"account.*suspended"
	"verify.*account"
	"confirm.*identity"
	"unusual.*activity"
	"security.*alert"
	"click.*here.*pay"
	"wire.*transfer.*urgent"
	"bitcoin.*payment"
	"cryptocurrency.*payment"
)

# =============================================================================
# Workspace setup
# =============================================================================

ensure_workspace() {
	mkdir -p "$WORKSPACE_DIR" "$FLAGGED_DIR" "$PROCESSED_DIR" 2>/dev/null || true
	return 0
}

# =============================================================================
# Configuration
# =============================================================================

load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		print_warning "Config not found: $CONFIG_FILE"
		print_info "Using defaults. Create config with: email-receipt-forward-helper.sh init-config"
		return 0
	fi
	return 0
}

get_accounts_email() {
	local override="${ACCOUNTS_EMAIL_OVERRIDE:-}"
	if [[ -n "$override" ]]; then
		echo "$override"
		return 0
	fi

	if [[ -f "$CONFIG_FILE" ]]; then
		local addr
		addr=$(jq -r '.accounts_email // empty' "$CONFIG_FILE" 2>/dev/null || true)
		if [[ -n "$addr" ]]; then
			echo "$addr"
			return 0
		fi
	fi

	# Fallback: check env
	if [[ -n "${EMAIL_RECEIPT_FORWARD_ACCOUNTS_EMAIL:-}" ]]; then
		echo "$EMAIL_RECEIPT_FORWARD_ACCOUNTS_EMAIL"
		return 0
	fi

	print_error "accounts@ email not configured"
	print_info "Set via: aidevops secret set EMAIL_RECEIPT_FORWARD_ACCOUNTS_EMAIL"
	print_info "Or create config: email-receipt-forward-helper.sh init-config"
	return 1
}

# =============================================================================
# Email parsing helpers
# =============================================================================

# Extract header value from raw email file
# Arguments: $1=header-name, $2=email-file
get_email_header() {
	local header="$1"
	local email_file="$2"

	python3 - "$email_file" "$header" <<'PYEOF'
import sys
import email

email_file = sys.argv[1]
header_name = sys.argv[2]

with open(email_file, 'rb') as f:
    msg = email.message_from_bytes(f.read())

value = msg.get(header_name, '')
print(value)
PYEOF
	return 0
}

# Extract From address domain
# Arguments: $1=from-header-value
extract_sender_domain() {
	local from_header="$1"

	# Handle "Name <email@domain.com>" and "email@domain.com" formats
	local email_addr
	email_addr=$(echo "$from_header" | python3 -c "
import sys, email.utils
_, addr = email.utils.parseaddr(sys.stdin.read().strip())
print(addr.lower())
" 2>/dev/null || echo "")

	if [[ -z "$email_addr" || "$email_addr" == *"@"* ]]; then
		echo "${email_addr##*@}"
	else
		echo ""
	fi
	return 0
}

# Extract email subject from file
get_email_subject() {
	local email_file="$1"
	get_email_header "Subject" "$email_file"
	return 0
}

# Extract From header from file
get_email_from() {
	local email_file="$1"
	get_email_header "From" "$email_file"
	return 0
}

# Extract plain text body from email
get_email_body_text() {
	local email_file="$1"

	python3 - "$email_file" <<'PYEOF'
import sys
import email

with open(sys.argv[1], 'rb') as f:
    msg = email.message_from_bytes(f.read())

body = ''
if msg.is_multipart():
    for part in msg.walk():
        if part.get_content_type() == 'text/plain':
            charset = part.get_content_charset() or 'utf-8'
            body += part.get_payload(decode=True).decode(charset, errors='replace')
else:
    if msg.get_content_type() == 'text/plain':
        charset = msg.get_content_charset() or 'utf-8'
        body = msg.get_payload(decode=True).decode(charset, errors='replace')

print(body[:2000])  # Limit to first 2000 chars for pattern matching
PYEOF
	return 0
}

# =============================================================================
# Transaction email detection
# =============================================================================

# Detect if email is a transaction email (receipt/invoice/payment confirmation)
# Arguments: $1=email-file
# Returns: 0 if transaction email, 1 if not
detect_transaction_email() {
	local email_file="$1"

	if [[ ! -f "$email_file" ]]; then
		print_error "Email file not found: $email_file"
		return 1
	fi

	local subject
	subject=$(get_email_subject "$email_file" 2>/dev/null || echo "")
	local subject_lower
	subject_lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')

	# Check subject against transaction patterns
	local pattern
	for pattern in "${TRANSACTION_SUBJECT_PATTERNS[@]}"; do
		if [[ "$subject_lower" == *"$pattern"* ]]; then
			print_info "Transaction detected via subject pattern: '$pattern'"
			print_info "Subject: $subject"
			return 0
		fi
	done

	# Check body for transaction indicators (secondary check)
	local body
	body=$(get_email_body_text "$email_file" 2>/dev/null || echo "")
	local body_lower
	body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

	# Body patterns indicating financial transaction
	local body_patterns=(
		"total amount"
		"amount due"
		"amount paid"
		"invoice number"
		"invoice #"
		"receipt number"
		"receipt #"
		"order number"
		"order #"
		"transaction id"
		"payment method"
		"billing address"
		"subtotal"
		"vat number"
		"tax invoice"
	)

	local bp
	for bp in "${body_patterns[@]}"; do
		if [[ "$body_lower" == *"$bp"* ]]; then
			print_info "Transaction detected via body pattern: '$bp'"
			return 0
		fi
	done

	print_info "Not a transaction email: $subject"
	return 1
}

# =============================================================================
# Phishing detection
# =============================================================================

# Check for phishing red flags in email
# Arguments: $1=email-file
# Returns: 0 if suspicious (phishing indicators found), 1 if clean
check_phishing_indicators() {
	local email_file="$1"

	local subject
	subject=$(get_email_subject "$email_file" 2>/dev/null || echo "")
	local subject_lower
	subject_lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')

	local flags=0
	local flag_reasons=""

	# Check subject for phishing patterns
	local pattern
	for pattern in "${PHISHING_SUBJECT_PATTERNS[@]}"; do
		if echo "$subject_lower" | grep -qE "$pattern" 2>/dev/null; then
			flags=$((flags + 1))
			flag_reasons="${flag_reasons}Subject matches phishing pattern '${pattern}'; "
		fi
	done

	# Check for mismatched display name vs email domain
	local from_header
	from_header=$(get_email_from "$email_file" 2>/dev/null || echo "")

	# Check for suspicious URL patterns in body
	local body
	body=$(get_email_body_text "$email_file" 2>/dev/null || echo "")

	# Shortened URLs are suspicious in financial emails
	if echo "$body" | grep -qE "bit\.ly|tinyurl\.com|t\.co|goo\.gl|ow\.ly" 2>/dev/null; then
		flags=$((flags + 1))
		flag_reasons="${flag_reasons}Contains URL shorteners (suspicious in financial emails); "
	fi

	# Urgent payment language
	if echo "$body" | grep -qiE "wire transfer|western union|moneygram|gift card|bitcoin|cryptocurrency" 2>/dev/null; then
		flags=$((flags + 1))
		flag_reasons="${flag_reasons}Contains high-risk payment method references; "
	fi

	if [[ "$flags" -gt 0 ]]; then
		print_warning "Phishing indicators found ($flags flags):"
		print_warning "$flag_reasons"
		return 0
	fi

	return 1
}

# =============================================================================
# DNS sender verification (SPF/DKIM/DMARC)
# =============================================================================

# Check SPF record for a domain; appends to score/max_score/details via nameref-style
# Arguments: $1=domain, $2=score_var (name), $3=max_score_var (name), $4=details_var (name)
# Returns: always 0 (scoring is additive)
_check_spf() {
	local domain="$1"
	local spf_record
	spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)

	eval "$3=\$((\$$3 + 2))"
	if [[ -z "$spf_record" ]]; then
		print_warning "SPF: No record found for $domain"
		eval "$4=\"\$$4SPF=MISSING; \""
	elif [[ "$spf_record" == *"-all"* || "$spf_record" == *"~all"* ]]; then
		print_success "SPF: Valid record with strict/soft-fail policy"
		eval "$2=\$((\$$2 + 2))"
		eval "$4=\"\$$4SPF=PASS; \""
	elif [[ "$spf_record" == *"+all"* ]]; then
		print_warning "SPF: Record uses +all (allows anyone — suspicious)"
		eval "$4=\"\$$4SPF=FAIL(+all); \""
	else
		print_info "SPF: Record found (neutral policy)"
		eval "$2=\$((\$$2 + 1))"
		eval "$4=\"\$$4SPF=WARN; \""
	fi
	return 0
}

# Check DKIM records for a domain across common selectors
# Arguments: $1=domain, $2=score_var (name), $3=max_score_var (name), $4=details_var (name)
# Returns: always 0 (scoring is additive)
_check_dkim() {
	local domain="$1"
	local found_dkim=false
	local sel

	eval "$3=\$((\$$3 + 2))"
	for sel in $DKIM_SELECTORS; do
		local dkim_record
		dkim_record=$(dig TXT "${sel}._domainkey.${domain}" +short 2>/dev/null | tr -d '"' || true)
		if [[ -n "$dkim_record" && "$dkim_record" != *"NXDOMAIN"* ]]; then
			found_dkim=true
			print_success "DKIM: Record found (selector: $sel)"
			eval "$2=\$((\$$2 + 2))"
			eval "$4=\"\$$4DKIM=PASS(${sel}); \""
			break
		fi
	done

	if [[ "$found_dkim" == false ]]; then
		print_warning "DKIM: No records found for common selectors"
		eval "$4=\"\$$4DKIM=MISSING; \""
	fi
	return 0
}

# Check DMARC record for a domain
# Arguments: $1=domain, $2=score_var (name), $3=max_score_var (name), $4=details_var (name)
# Returns: always 0 (scoring is additive)
_check_dmarc() {
	local domain="$1"
	local dmarc_record
	dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)

	eval "$3=\$((\$$3 + 3))"
	if [[ -z "$dmarc_record" ]]; then
		print_warning "DMARC: No record found for $domain"
		eval "$4=\"\$$4DMARC=MISSING; \""
	elif [[ "$dmarc_record" == *"p=reject"* ]]; then
		print_success "DMARC: Policy=reject (strongest protection)"
		eval "$2=\$((\$$2 + 3))"
		eval "$4=\"\$$4DMARC=PASS(reject); \""
	elif [[ "$dmarc_record" == *"p=quarantine"* ]]; then
		print_success "DMARC: Policy=quarantine (good protection)"
		eval "$2=\$((\$$2 + 2))"
		eval "$4=\"\$$4DMARC=PASS(quarantine); \""
	elif [[ "$dmarc_record" == *"p=none"* ]]; then
		print_warning "DMARC: Policy=none (monitoring only)"
		eval "$2=\$((\$$2 + 1))"
		eval "$4=\"\$$4DMARC=WARN(none); \""
	else
		print_info "DMARC: Record found (unknown policy)"
		eval "$2=\$((\$$2 + 1))"
		eval "$4=\"\$$4DMARC=WARN; \""
	fi
	return 0
}

# Evaluate DNS score percentage and print pass/warn/fail verdict
# Arguments: $1=score, $2=max_score, $3=details
# Returns: 0 if pass, 1 if warn or fail
_evaluate_dns_score() {
	local score="$1"
	local max_score="$2"
	local details="$3"
	local pct=0

	if [[ "$max_score" -gt 0 ]]; then
		pct=$(((score * 100) / max_score))
	fi

	print_info "DNS verification score: ${score}/${max_score} (${pct}%) — ${details}"

	# Pass threshold: >= 57% (4/7 minimum: SPF pass + DMARC warn)
	if [[ "$pct" -ge 57 ]]; then
		print_success "Sender DNS verification: PASS"
		return 0
	elif [[ "$pct" -ge 28 ]]; then
		print_warning "Sender DNS verification: WARN (partial authentication)"
		return 1
	else
		print_error "Sender DNS verification: FAIL (insufficient authentication)"
		return 1
	fi
}

# Verify sender domain DNS authentication records
# Arguments: $1=sender-domain
# Returns: 0 if verified (pass), 1 if suspicious (warn/fail)
verify_sender_dns() {
	local domain="$1"

	if [[ -z "$domain" ]]; then
		print_error "Domain required for DNS verification"
		return 1
	fi

	print_info "Verifying DNS authentication for: $domain"

	local score=0
	local max_score=0
	local details=""

	_check_spf "$domain" score max_score details
	_check_dkim "$domain" score max_score details
	_check_dmarc "$domain" score max_score details
	_evaluate_dns_score "$score" "$max_score" "$details"
	return $?
}

# Check if sender domain is a known legitimate accounting/payment service
# Arguments: $1=sender-domain
# Returns: 0 if known, 1 if unknown
is_known_sender_domain() {
	local domain="$1"
	local domain_lower
	domain_lower=$(echo "$domain" | tr '[:upper:]' '[:lower:]')

	local known
	for known in "${KNOWN_ACCOUNTING_DOMAINS[@]}"; do
		if [[ "$domain_lower" == "$known" || "$domain_lower" == *".$known" ]]; then
			return 0
		fi
	done
	return 1
}

# =============================================================================
# Forwarding
# =============================================================================

# Forward email to accounts@ address
# Arguments: $1=email-file, $2=accounts-email, $3=original-from, $4=original-subject
# Options: --dry-run
forward_to_accounts() {
	local email_file="$1"
	local accounts_email="$2"
	local original_from="$3"
	local original_subject="$4"
	local dry_run="${5:-false}"

	local forward_subject="[Receipt Forward] ${original_subject}"

	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY-RUN] Would forward to: $accounts_email"
		print_info "[DRY-RUN] Subject: $forward_subject"
		print_info "[DRY-RUN] Original from: $original_from"
		return 0
	fi

	# Use AWS SES if available, otherwise log for manual forwarding
	if command -v aws &>/dev/null; then
		local sender_email
		sender_email=$(get_config_value_from_file ".sender_email" "${CONFIG_FILE}" "noreply@aidevops.sh")

		# Build forwarding message with original email as attachment
		local tmp_msg
		tmp_msg=$(mktemp /tmp/receipt-forward-XXXXXX.json)
		# Ensure cleanup on exit
		trap 'rm -f "$tmp_msg"' EXIT

		python3 - "$email_file" "$accounts_email" "$sender_email" "$forward_subject" "$original_from" >"$tmp_msg" <<'PYEOF'
import sys
import json
import email
import base64

email_file = sys.argv[1]
to_addr = sys.argv[2]
from_addr = sys.argv[3]
subject = sys.argv[4]
original_from = sys.argv[5]

with open(email_file, 'rb') as f:
    raw = f.read()

# Build SES raw message
import email.mime.multipart
import email.mime.text
import email.mime.base
from email.mime.application import MIMEApplication

outer = email.mime.multipart.MIMEMultipart()
outer['Subject'] = subject
outer['From'] = from_addr
outer['To'] = to_addr

body_text = f"""Receipt/invoice forwarded by AI DevOps email-receipt-forward-helper.

Original sender: {original_from}
Forwarded at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

The original email is attached below.
"""

outer.attach(email.mime.text.MIMEText(body_text, 'plain'))

# Attach original email as .eml
attachment = MIMEApplication(raw, Name='original.eml')
attachment['Content-Disposition'] = 'attachment; filename="original.eml"'
outer.attach(attachment)

raw_msg = outer.as_bytes()
print(json.dumps({
    "RawMessage": {"Data": base64.b64encode(raw_msg).decode()},
    "Destinations": [to_addr],
    "Source": from_addr
}))
PYEOF

		if aws ses send-raw-email --cli-input-json "file://${tmp_msg}" >/dev/null 2>&1; then
			print_success "Forwarded to $accounts_email via SES"
			rm -f "$tmp_msg"
			return 0
		else
			print_error "SES forwarding failed"
			rm -f "$tmp_msg"
			return 1
		fi
	else
		# No SES — log for manual forwarding
		print_warning "AWS CLI not available — logging for manual forwarding"
		local log_entry
		log_entry=$(printf '{"timestamp":"%s","action":"pending_forward","to":"%s","from":"%s","subject":"%s","file":"%s"}' \
			"$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
			"$accounts_email" \
			"$original_from" \
			"$original_subject" \
			"$email_file")
		echo "$log_entry" >>"${WORKSPACE_DIR}/pending-forwards.jsonl"
		print_info "Logged to: ${WORKSPACE_DIR}/pending-forwards.jsonl"
		return 0
	fi
}

# =============================================================================
# Flagging suspicious emails
# =============================================================================

# Flag email as suspicious for manual review
# Arguments: $1=email-file, $2=reason
flag_suspicious_email() {
	local email_file="$1"
	local reason="$2"

	ensure_workspace

	local basename
	basename=$(basename "$email_file")
	local timestamp
	timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
	local flagged_path="${FLAGGED_DIR}/${timestamp}-${basename}"

	# Copy to flagged directory
	cp "$email_file" "$flagged_path" 2>/dev/null || true

	# Log the flag
	local subject
	subject=$(get_email_subject "$email_file" 2>/dev/null || echo "unknown")
	local from_header
	from_header=$(get_email_from "$email_file" 2>/dev/null || echo "unknown")

	local log_entry
	log_entry=$(printf '{"timestamp":"%s","action":"flagged","reason":"%s","from":"%s","subject":"%s","original_file":"%s","flagged_file":"%s"}' \
		"$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		"$reason" \
		"$from_header" \
		"$subject" \
		"$email_file" \
		"$flagged_path")
	echo "$log_entry" >>"${WORKSPACE_DIR}/flagged.jsonl"

	print_warning "Email flagged for manual review"
	print_warning "Reason: $reason"
	print_warning "Flagged copy: $flagged_path"
	print_info "Review flagged emails: ls ${FLAGGED_DIR}/"
	return 0
}

# =============================================================================
# Core processing pipeline
# =============================================================================

# Process a single email file through the full pipeline:
# 1. Detect if transaction email
# 2. Check phishing indicators
# 3. Verify sender DNS
# 4. Forward or flag
# Arguments: $1=email-file
# Options: --dry-run, --verbose
process_email() {
	local email_file="$1"
	local dry_run="${DRY_RUN:-false}"

	if [[ ! -f "$email_file" ]]; then
		print_error "Email file not found: $email_file"
		return 1
	fi

	ensure_workspace

	local subject
	subject=$(get_email_subject "$email_file" 2>/dev/null || echo "")
	local from_header
	from_header=$(get_email_from "$email_file" 2>/dev/null || echo "")
	local sender_domain
	sender_domain=$(extract_sender_domain "$from_header")

	print_info "Processing: $email_file"
	print_info "From: $from_header"
	print_info "Subject: $subject"
	print_info "Sender domain: $sender_domain"
	echo ""

	# Step 1: Detect transaction email
	if ! detect_transaction_email "$email_file"; then
		print_info "Skipping: not a transaction email"
		return 0
	fi

	echo ""
	print_info "Transaction email detected — proceeding with phishing check"

	# Step 2: Check phishing indicators (hard block — never forward if flagged)
	if check_phishing_indicators "$email_file"; then
		flag_suspicious_email "$email_file" "Phishing indicators detected in subject/body"
		return 0
	fi

	echo ""
	print_info "No phishing indicators — proceeding with DNS verification"

	# Step 3: Verify sender DNS
	local dns_verified=false
	if [[ -n "$sender_domain" ]]; then
		if verify_sender_dns "$sender_domain"; then
			dns_verified=true
		fi
	else
		print_warning "Could not extract sender domain — treating as unverified"
	fi

	# Step 4: Decision — forward or flag
	local accounts_email
	if ! accounts_email=$(get_accounts_email); then
		print_error "Cannot forward: accounts@ email not configured"
		return 1
	fi

	echo ""
	if [[ "$dns_verified" == true ]]; then
		print_success "Sender verified — forwarding to $accounts_email"
		forward_to_accounts "$email_file" "$accounts_email" "$from_header" "$subject" "$dry_run"
	else
		# Check if it's a known sender domain — apply lower threshold
		if [[ -n "$sender_domain" ]] && is_known_sender_domain "$sender_domain"; then
			print_warning "DNS verification incomplete but domain is known ($sender_domain)"
			print_info "Forwarding with warning annotation"
			forward_to_accounts "$email_file" "$accounts_email" "$from_header" "[DNS-WARN] ${subject}" "$dry_run"
		else
			flag_suspicious_email "$email_file" "DNS verification failed for sender domain: ${sender_domain:-unknown}"
		fi
	fi

	# Mark as processed
	local basename
	basename=$(basename "$email_file")
	local timestamp
	timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
	local log_entry
	log_entry=$(printf '{"timestamp":"%s","action":"processed","from":"%s","subject":"%s","dns_verified":%s,"file":"%s"}' \
		"$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		"$from_header" \
		"$subject" \
		"$dns_verified" \
		"$email_file")
	echo "$log_entry" >>"${WORKSPACE_DIR}/processed.jsonl"

	return 0
}

# =============================================================================
# Mailbox scanning
# =============================================================================

# Scan a mailbox directory for unprocessed transaction emails
# Arguments: $1=mailbox-dir (optional, defaults to config)
scan_mailbox_dir() {
	local mailbox_dir="${1:-}"

	if [[ -z "$mailbox_dir" ]]; then
		if [[ -f "$CONFIG_FILE" ]]; then
			mailbox_dir=$(jq -r '.mailbox_dir // empty' "$CONFIG_FILE" 2>/dev/null || true)
		fi
	fi

	if [[ -z "$mailbox_dir" || ! -d "$mailbox_dir" ]]; then
		print_error "Mailbox directory not found: ${mailbox_dir:-not configured}"
		print_info "Set mailbox_dir in $CONFIG_FILE"
		return 1
	fi

	print_info "Scanning mailbox: $mailbox_dir"

	local count=0
	local processed=0
	local skipped=0

	# Process .eml files in mailbox directory
	while IFS= read -r -d '' email_file; do
		count=$((count + 1))
		if process_email "$email_file"; then
			processed=$((processed + 1))
		else
			skipped=$((skipped + 1))
		fi
		echo ""
	done < <(find "$mailbox_dir" -name "*.eml" -print0 2>/dev/null)

	print_info "Scan complete: $count emails found, $processed processed, $skipped skipped"
	return 0
}

# =============================================================================
# Config helpers
# =============================================================================

get_config_value_from_file() {
	local key="$1"
	local file="$2"
	local default="${3:-}"

	if [[ -f "$file" ]]; then
		local value
		value=$(jq -r "${key} // empty" "$file" 2>/dev/null || true)
		if [[ -n "$value" ]]; then
			echo "$value"
			return 0
		fi
	fi
	echo "$default"
	return 0
}

# Create default config file
init_config() {
	mkdir -p "$CONFIG_DIR" 2>/dev/null || true

	if [[ -f "$CONFIG_FILE" ]]; then
		print_warning "Config already exists: $CONFIG_FILE"
		print_info "Delete it first to reinitialise"
		return 1
	fi

	cat >"$CONFIG_FILE" <<'JSONEOF'
{
  "_comment": "email-receipt-forward-helper.sh configuration",
  "accounts_email": "accounts@example.com",
  "sender_email": "noreply@example.com",
  "mailbox_dir": "",
  "dns_pass_threshold_pct": 57,
  "known_domains_bypass_dns_fail": true,
  "dry_run": false,
  "log_level": "info"
}
JSONEOF

	chmod 600 "$CONFIG_FILE"
	print_success "Config created: $CONFIG_FILE"
	print_info "Edit accounts_email and sender_email before use"
	return 0
}

# =============================================================================
# Status
# =============================================================================

show_status() {
	print_info "email-receipt-forward-helper.sh v${VERSION}"
	echo ""

	# Config
	if [[ -f "$CONFIG_FILE" ]]; then
		print_success "Config: $CONFIG_FILE"
		local accounts_email
		accounts_email=$(jq -r '.accounts_email // "not set"' "$CONFIG_FILE" 2>/dev/null || echo "not set")
		print_info "  accounts_email: $accounts_email"
	else
		print_warning "Config: not found ($CONFIG_FILE)"
	fi

	# Workspace
	if [[ -d "$WORKSPACE_DIR" ]]; then
		print_success "Workspace: $WORKSPACE_DIR"
		local flagged_count=0
		local pending_count=0
		if [[ -f "${WORKSPACE_DIR}/flagged.jsonl" ]]; then
			flagged_count=$(wc -l <"${WORKSPACE_DIR}/flagged.jsonl" | tr -d ' ')
		fi
		if [[ -f "${WORKSPACE_DIR}/pending-forwards.jsonl" ]]; then
			pending_count=$(wc -l <"${WORKSPACE_DIR}/pending-forwards.jsonl" | tr -d ' ')
		fi
		print_info "  Flagged emails: $flagged_count"
		print_info "  Pending forwards (no SES): $pending_count"
	else
		print_info "Workspace: not yet created (will be created on first run)"
	fi

	# Dependencies
	echo ""
	print_info "Dependencies:"
	local dep
	for dep in dig jq python3 aws; do
		if command -v "$dep" &>/dev/null; then
			print_success "  $dep: available"
		else
			if [[ "$dep" == "aws" ]]; then
				print_warning "  $dep: not available (SES forwarding disabled, will log to pending-forwards.jsonl)"
			else
				print_error "  $dep: MISSING (required)"
			fi
		fi
	done
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<HELPEOF

email-receipt-forward-helper.sh v${VERSION}
Receipt/invoice forwarding with phishing protection

USAGE
  email-receipt-forward-helper.sh <command> [options]

COMMANDS
  process <email-file>          Full pipeline: detect → verify → forward/flag
  scan-mailbox [--dir <path>]   Scan mailbox directory for transaction emails
  verify-sender <domain>        DNS verification only (SPF/DKIM/DMARC)
  detect <email-file>           Detection only (is this a transaction email?)
  forward <email-file>          Forward to accounts@ (skips detection/verification)
  flag <email-file> --reason    Flag email for manual review
  init-config                   Create default config file
  status                        Show configuration and dependency status
  help                          Show this help

OPTIONS
  --accounts-email <addr>       Override accounts@ destination
  --dry-run                     Show what would happen without sending
  --verbose                     Verbose output
  --dir <path>                  Mailbox directory for scan-mailbox

PIPELINE
  1. Detect transaction email (subject/body patterns)
  2. Check phishing indicators (hard block — never forward if flagged)
  3. Verify sender DNS (SPF/DKIM/DMARC)
  4. Forward verified emails to accounts@
  5. Flag suspicious emails for manual review

CONFIG
  $CONFIG_FILE
  Run 'init-config' to create default config.

CREDENTIALS
  aidevops secret set EMAIL_RECEIPT_FORWARD_ACCOUNTS_EMAIL

EXAMPLES
  # Process a single email
  email-receipt-forward-helper.sh process ~/Downloads/invoice.eml

  # Dry run to see what would happen
  email-receipt-forward-helper.sh process ~/Downloads/invoice.eml --dry-run

  # Verify a sender domain
  email-receipt-forward-helper.sh verify-sender stripe.com

  # Scan a mailbox directory
  email-receipt-forward-helper.sh scan-mailbox --dir ~/Maildir/INBOX/new/

  # Check status
  email-receipt-forward-helper.sh status

HELPEOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

# Parse global flags from argument list into named variables
# Populates: dry_run, verbose, accounts_email_override, mailbox_dir_override,
#            flag_reason, remaining_args (array)
# Arguments: all remaining positional args after the command has been shifted off
_parse_global_flags() {
	dry_run=false
	verbose=false
	accounts_email_override=""
	mailbox_dir_override=""
	flag_reason=""
	remaining_args=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--verbose)
			verbose=true
			shift
			;;
		--accounts-email)
			accounts_email_override="${2:-}"
			shift 2
			;;
		--dir)
			mailbox_dir_override="${2:-}"
			shift 2
			;;
		--reason)
			flag_reason="${2:-}"
			shift 2
			;;
		*)
			remaining_args+=("$1")
			shift
			;;
		esac
	done
	return 0
}

# Dispatch a parsed command with pre-populated globals from _parse_global_flags
# Arguments: $1=command
_dispatch_command() {
	local command="$1"

	case "$command" in
	"process")
		local email_file="${remaining_args[0]:-}"
		if [[ -z "$email_file" ]]; then
			print_error "Email file required"
			echo "Usage: $0 process <email-file> [--dry-run]"
			exit 1
		fi
		process_email "$email_file"
		;;
	"scan-mailbox" | "scan")
		scan_mailbox_dir "${mailbox_dir_override:-}"
		;;
	"verify-sender" | "verify")
		local domain="${remaining_args[0]:-}"
		if [[ -z "$domain" ]]; then
			print_error "Domain required"
			echo "Usage: $0 verify-sender <domain>"
			exit 1
		fi
		verify_sender_dns "$domain"
		;;
	"detect")
		local email_file="${remaining_args[0]:-}"
		if [[ -z "$email_file" ]]; then
			print_error "Email file required"
			echo "Usage: $0 detect <email-file>"
			exit 1
		fi
		if detect_transaction_email "$email_file"; then
			print_success "TRANSACTION EMAIL DETECTED"
		else
			print_info "NOT a transaction email"
		fi
		;;
	"forward")
		local email_file="${remaining_args[0]:-}"
		if [[ -z "$email_file" ]]; then
			print_error "Email file required"
			echo "Usage: $0 forward <email-file> [--dry-run]"
			exit 1
		fi
		local accounts_email
		if ! accounts_email=$(get_accounts_email); then
			exit 1
		fi
		local subject
		subject=$(get_email_subject "$email_file" 2>/dev/null || echo "")
		local from_header
		from_header=$(get_email_from "$email_file" 2>/dev/null || echo "")
		forward_to_accounts "$email_file" "$accounts_email" "$from_header" "$subject" "$dry_run"
		;;
	"flag")
		local email_file="${remaining_args[0]:-}"
		if [[ -z "$email_file" ]]; then
			print_error "Email file required"
			echo "Usage: $0 flag <email-file> --reason <reason>"
			exit 1
		fi
		if [[ -z "$flag_reason" ]]; then
			print_error "--reason is required"
			exit 1
		fi
		flag_suspicious_email "$email_file" "$flag_reason"
		;;
	"init-config")
		init_config
		;;
	"status")
		show_status
		;;
	"help" | "--help" | "-h")
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		exit 1
		;;
	esac
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	_parse_global_flags "$@"

	# Export overrides for sub-functions
	export DRY_RUN="$dry_run"
	export ACCOUNTS_EMAIL_OVERRIDE="$accounts_email_override"

	load_config
	_dispatch_command "$command"
	return 0
}

main "$@"
