#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Verify Helper Script
# Local email address verifier with RCPT TO probing, disposable domain
# detection via SQLite DB, and catch-all detection.
#
# 6 checks:
#   1. Syntax/format validation (RFC 5321)
#   2. MX record lookup (dig)
#   3. Disposable domain detection (SQLite FTS5, seeded from
#      github.com/disposable-email-domains/disposable-email-domains)
#   4. SMTP RCPT TO mailbox probing
#   5. Full inbox detection (SMTP 452 response)
#   6. Catch-all detection (probe random address)
#
# Scoring: deliverable / risky / undeliverable / unknown (FixBounce-compatible)
#
# Usage: email-verify-helper.sh [command] [options]
#
# Commands:
#   verify <email>       Verify a single email address
#   bulk <file>          Verify emails from file (one per line)
#   update-domains       Refresh disposable domain database from upstream
#   stats                Show verification statistics
#   help                 Show this help
#
# Dependencies:
#   Required: dig, sqlite3, openssl (or nc/ncat for SMTP)
#   Optional: curl (for domain list updates)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Database paths
readonly DATA_DIR="${HOME}/.aidevops/.agent-workspace/data"
readonly DISPOSABLE_DB="${DATA_DIR}/disposable-domains.db"
readonly STATS_DB="${DATA_DIR}/email-verify-stats.db"

# Upstream disposable domain list
readonly DISPOSABLE_DOMAINS_URL="https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/master/disposable_email_blocklist.conf"

# SMTP settings
readonly SMTP_TIMEOUT=10
readonly SMTP_HELO_DOMAIN="verify.local"

# Scoring thresholds
readonly SCORE_DELIVERABLE="deliverable"
readonly SCORE_RISKY="risky"
readonly SCORE_UNDELIVERABLE="undeliverable"
readonly SCORE_UNKNOWN="unknown"

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
	local msg="$1"
	echo ""
	echo -e "${BLUE}=== $msg ===${NC}"
	return 0
}

# Check if a command exists
command_exists() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1
	return $?
}

# Ensure data directory exists
ensure_data_dir() {
	if [[ ! -d "$DATA_DIR" ]]; then
		mkdir -p "$DATA_DIR"
	fi
	return 0
}

# Extract domain from email address
extract_domain() {
	local email="$1"
	echo "${email#*@}"
	return 0
}

# Extract local part from email address
extract_local() {
	local email="$1"
	echo "${email%%@*}"
	return 0
}

# Generate a random string for catch-all detection
generate_random_local() {
	local random_str
	random_str="verify-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)"
	echo "$random_str"
	return 0
}

# =============================================================================
# Check 1: Syntax/Format Validation (RFC 5321)
# =============================================================================

check_syntax() {
	local email="$1"
	local result="pass"
	local details=""

	# Basic format: local@domain
	if [[ ! "$email" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
		result="fail"
		details="Invalid email format"
		echo "syntax:${result}:${details}"
		return 1
	fi

	local local_part
	local_part="$(extract_local "$email")"
	local domain
	domain="$(extract_domain "$email")"

	# Local part length (max 64 chars per RFC 5321)
	if [[ ${#local_part} -gt 64 ]]; then
		result="fail"
		details="Local part exceeds 64 characters"
		echo "syntax:${result}:${details}"
		return 1
	fi

	# Domain length (max 255 chars)
	if [[ ${#domain} -gt 255 ]]; then
		result="fail"
		details="Domain exceeds 255 characters"
		echo "syntax:${result}:${details}"
		return 1
	fi

	# No consecutive dots in local part
	if [[ "$local_part" == *..* ]]; then
		result="fail"
		details="Consecutive dots in local part"
		echo "syntax:${result}:${details}"
		return 1
	fi

	# No leading/trailing dots in local part
	if [[ "$local_part" == .* ]] || [[ "$local_part" == *. ]]; then
		result="fail"
		details="Leading or trailing dot in local part"
		echo "syntax:${result}:${details}"
		return 1
	fi

	echo "syntax:${result}:Valid format"
	return 0
}

# =============================================================================
# Check 2: MX Record Lookup
# =============================================================================

check_mx() {
	local domain="$1"
	local mx_records
	local result="pass"
	local details=""

	if ! command_exists dig; then
		echo "mx:skip:dig not available"
		return 0
	fi

	# Query MX records
	mx_records=$(dig MX "$domain" +short +time=5 +tries=2 2>/dev/null | sort -n || true)

	if [[ -z "$mx_records" ]]; then
		# Fall back to A record (some domains accept mail without MX)
		local a_record
		a_record=$(dig A "$domain" +short +time=5 +tries=2 2>/dev/null | head -1 || true)

		if [[ -z "$a_record" ]]; then
			result="fail"
			details="No MX or A records found"
			echo "mx:${result}:${details}"
			return 1
		fi

		result="warn"
		details="No MX records; A record found: ${a_record}"
		echo "mx:${result}:${details}"
		return 0
	fi

	# Get the primary (lowest priority) MX
	local primary_mx
	primary_mx=$(echo "$mx_records" | head -1 | awk '{print $2}' | sed 's/\.$//')

	local mx_count
	mx_count=$(echo "$mx_records" | wc -l | tr -d ' ')

	details="Found ${mx_count} MX record(s), primary=${primary_mx}"
	echo "mx:${result}:${details}:${primary_mx}"
	return 0
}

# =============================================================================
# Check 3: Disposable Domain Detection
# =============================================================================

# Initialize the disposable domains database
init_disposable_db() {
	ensure_data_dir

	if [[ -f "$DISPOSABLE_DB" ]]; then
		return 0
	fi

	print_info "Initializing disposable domain database..."

	sqlite3 "$DISPOSABLE_DB" <<-'DBSQL'
		CREATE TABLE IF NOT EXISTS domains (
			domain TEXT PRIMARY KEY NOT NULL
		);
		CREATE VIRTUAL TABLE IF NOT EXISTS domains_fts USING fts5(
			domain,
			content='domains',
			content_rowid='rowid'
		);
		CREATE TRIGGER IF NOT EXISTS domains_ai AFTER INSERT ON domains BEGIN
			INSERT INTO domains_fts(rowid, domain) VALUES (new.rowid, new.domain);
		END;
		CREATE TRIGGER IF NOT EXISTS domains_ad AFTER DELETE ON domains BEGIN
			INSERT INTO domains_fts(domains_fts, rowid, domain) VALUES('delete', old.rowid, old.domain);
		END;
		CREATE TABLE IF NOT EXISTS metadata (
			key TEXT PRIMARY KEY NOT NULL,
			value TEXT NOT NULL
		);
	DBSQL

	return 0
}

# Check if a domain is disposable
check_disposable() {
	local domain="$1"
	local result="pass"
	local details=""

	# Initialize DB if needed (but don't fail if it can't be created)
	if ! init_disposable_db 2>/dev/null; then
		echo "disposable:skip:Database unavailable"
		return 0
	fi

	# Check if database has any domains
	local domain_count
	domain_count=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains;" 2>/dev/null || echo "0")

	if [[ "$domain_count" == "0" ]]; then
		echo "disposable:skip:Database empty - run 'update-domains' first"
		return 0
	fi

	# Look up domain (exact match via FTS5 for speed)
	local found
	found=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains WHERE domain = '$(echo "$domain" | tr '[:upper:]' '[:lower:]')';" 2>/dev/null || echo "0")

	if [[ "$found" -gt 0 ]]; then
		result="fail"
		details="Disposable/temporary email domain"
		echo "disposable:${result}:${details}"
		return 1
	fi

	# Also check parent domain (e.g., sub.mailinator.com -> mailinator.com)
	local parent_domain
	parent_domain=$(echo "$domain" | sed 's/^[^.]*\.//')
	if [[ "$parent_domain" != "$domain" ]] && [[ "$parent_domain" == *.* ]]; then
		found=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains WHERE domain = '$(echo "$parent_domain" | tr '[:upper:]' '[:lower:]')';" 2>/dev/null || echo "0")
		if [[ "$found" -gt 0 ]]; then
			result="fail"
			details="Subdomain of disposable domain (${parent_domain})"
			echo "disposable:${result}:${details}"
			return 1
		fi
	fi

	echo "disposable:${result}:Not a disposable domain"
	return 0
}

# =============================================================================
# Check 4 & 5: SMTP RCPT TO Probing + Full Inbox Detection
# =============================================================================

# Perform SMTP conversation and return the RCPT TO response code.
# Uses a temporary script with delays piped to nc (plain SMTP on port 25).
# Port 25 is the standard for MX-to-MX delivery and RCPT TO verification.
# openssl STARTTLS is used as fallback when plain connection fails.
#
# Returns: "<3-digit-code>:<summary>" or "smtp:skip:..." / "smtp:unknown:..."
smtp_probe() {
	local mx_host="$1"
	local email="$2"
	local smtp_port="${3:-25}"

	local smtp_response=""
	local rcpt_code=""

	# Write SMTP commands to a temp script with delays between commands.
	# Delays ensure the server processes each command before the next arrives.
	local tmp_script
	tmp_script=$(mktemp)
	local tmp_output
	tmp_output=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_script' '$tmp_output'" RETURN

	cat >"$tmp_script" <<-SMTPEOF
		#!/usr/bin/env bash
		sleep 1
		printf 'EHLO ${SMTP_HELO_DOMAIN}\r\n'
		sleep 1
		printf 'MAIL FROM:<verify@${SMTP_HELO_DOMAIN}>\r\n'
		sleep 1
		printf 'RCPT TO:<${email}>\r\n'
		sleep 1
		printf 'QUIT\r\n'
		sleep 1
	SMTPEOF
	chmod +x "$tmp_script"

	# Try nc first (plain SMTP, port 25 — standard for verification)
	if command_exists nc; then
		bash "$tmp_script" |
			nc -w "$SMTP_TIMEOUT" "$mx_host" "$smtp_port" \
				>"$tmp_output" 2>/dev/null || true
		smtp_response=$(cat "$tmp_output")
	fi

	# If nc failed or unavailable, try openssl with STARTTLS
	if [[ -z "$smtp_response" ]] && command_exists openssl; then
		local tls_commands
		tls_commands=$(printf 'EHLO %s\r\nMAIL FROM:<%s>\r\nRCPT TO:<%s>\r\nQUIT\r\n' \
			"$SMTP_HELO_DOMAIN" "verify@${SMTP_HELO_DOMAIN}" "$email")

		smtp_response=$(echo "$tls_commands" |
			openssl s_client -connect "${mx_host}:${smtp_port}" \
				-starttls smtp -quiet -verify_quiet \
				2>/dev/null || true)
	fi

	rm -f "$tmp_script" "$tmp_output"

	if [[ -z "$smtp_response" ]] && ! command_exists nc && ! command_exists openssl; then
		echo "smtp:skip:No SMTP client available (need nc or openssl)"
		return 0
	fi

	if [[ -z "$smtp_response" ]]; then
		echo "smtp:unknown:No response from ${mx_host}:${smtp_port}"
		return 0
	fi

	# Extract SMTP response codes (lines starting with 3-digit codes).
	# SMTP response codes: 250=OK, 251=forwarded, 252=cannot verify,
	# 450=temp fail, 451=temp error, 452=full inbox,
	# 550=not found, 551=not local, 552=exceeded storage, 553=bad mailbox
	#
	# Typical sequence: 220 (banner), 250 (EHLO x N), 250 (MAIL FROM),
	# XXX (RCPT TO), 221 (QUIT). The RCPT TO response is the last
	# non-221 code.

	# Collect all 3-digit response codes in order
	local all_codes
	all_codes=$(echo "$smtp_response" | grep -oE '^[0-9]{3}' || true)

	if [[ -z "$all_codes" ]]; then
		echo "smtp:unknown:No SMTP response codes in server output"
		return 0
	fi

	# Find the last non-221 code — that's the RCPT TO response.
	rcpt_code=$(echo "$all_codes" | grep -v '^221$' | tail -1 || true)

	if [[ -z "$rcpt_code" ]]; then
		rcpt_code=$(echo "$all_codes" | tail -1 || true)
	fi

	echo "${rcpt_code}:${smtp_response}"
	return 0
}

# Check RCPT TO acceptance
check_rcpt_to() {
	local email="$1"
	local mx_host="$2"
	local result="unknown"
	local details=""

	if [[ -z "$mx_host" ]]; then
		echo "rcpt:skip:No MX host available"
		return 0
	fi

	local probe_result
	probe_result=$(smtp_probe "$mx_host" "$email")

	# The probe returns "code:response" — extract only the first line's code.
	# The response is multi-line, so we must isolate the first line.
	local rcpt_code
	rcpt_code=$(echo "$probe_result" | head -1 | cut -d: -f1)

	case "$rcpt_code" in
	250 | 251)
		result="pass"
		details="Mailbox exists (SMTP ${rcpt_code})"
		;;
	252)
		result="warn"
		details="Cannot verify, but server accepted (SMTP 252)"
		;;
	450 | 451)
		result="warn"
		details="Temporary failure (SMTP ${rcpt_code}) - try again later"
		;;
	452)
		# Check 5: Full inbox detection
		result="full"
		details="Mailbox full (SMTP 452)"
		;;
	550)
		result="fail"
		details="Mailbox does not exist (SMTP 550)"
		;;
	551 | 553)
		result="fail"
		details="Mailbox rejected (SMTP ${rcpt_code})"
		;;
	552)
		result="full"
		details="Exceeded storage allocation (SMTP 552)"
		;;
	"")
		result="unknown"
		details="Could not determine SMTP response"
		;;
	*)
		result="unknown"
		details="Unexpected SMTP response: ${rcpt_code}"
		;;
	esac

	echo "rcpt:${result}:${details}"
	return 0
}

# =============================================================================
# Check 6: Catch-All Detection
# =============================================================================

check_catch_all() {
	local domain="$1"
	local mx_host="$2"
	local result="pass"
	local details=""

	if [[ -z "$mx_host" ]]; then
		echo "catchall:skip:No MX host available"
		return 0
	fi

	# Generate a random address that should not exist
	local random_local
	random_local=$(generate_random_local)
	local random_email="${random_local}@${domain}"

	local probe_result
	probe_result=$(smtp_probe "$mx_host" "$random_email")

	# Extract only the first line's code (probe returns multi-line response)
	local rcpt_code
	rcpt_code=$(echo "$probe_result" | head -1 | cut -d: -f1)

	case "$rcpt_code" in
	250 | 251)
		result="catchall"
		details="Domain accepts all addresses (catch-all detected)"
		;;
	252)
		result="warn"
		details="Cannot determine catch-all status (SMTP 252)"
		;;
	550 | 551 | 553)
		result="pass"
		details="Domain rejects unknown addresses (no catch-all)"
		;;
	"")
		result="unknown"
		details="Could not determine catch-all status"
		;;
	*)
		result="unknown"
		details="Inconclusive catch-all test (SMTP ${rcpt_code})"
		;;
	esac

	echo "catchall:${result}:${details}"
	return 0
}

# =============================================================================
# Scoring Engine
# =============================================================================

# Calculate overall score from individual check results
calculate_score() {
	local syntax_result="$1"
	local mx_result="$2"
	local disposable_result="$3"
	local rcpt_result="$4"
	local catchall_result="$5"

	# Immediate undeliverable conditions
	if [[ "$syntax_result" == "fail" ]]; then
		echo "$SCORE_UNDELIVERABLE"
		return 0
	fi

	if [[ "$mx_result" == "fail" ]]; then
		echo "$SCORE_UNDELIVERABLE"
		return 0
	fi

	if [[ "$disposable_result" == "fail" ]]; then
		echo "$SCORE_UNDELIVERABLE"
		return 0
	fi

	if [[ "$rcpt_result" == "fail" ]]; then
		echo "$SCORE_UNDELIVERABLE"
		return 0
	fi

	# Full inbox = risky (exists but can't receive)
	if [[ "$rcpt_result" == "full" ]]; then
		echo "$SCORE_RISKY"
		return 0
	fi

	# Catch-all = risky (can't confirm individual mailbox)
	if [[ "$catchall_result" == "catchall" ]]; then
		echo "$SCORE_RISKY"
		return 0
	fi

	# Warnings = risky
	if [[ "$mx_result" == "warn" ]] || [[ "$rcpt_result" == "warn" ]]; then
		echo "$SCORE_RISKY"
		return 0
	fi

	# Too many unknowns = unknown
	local unknown_count=0
	for r in "$mx_result" "$rcpt_result" "$catchall_result"; do
		if [[ "$r" == "unknown" ]] || [[ "$r" == "skip" ]]; then
			unknown_count=$((unknown_count + 1))
		fi
	done

	if [[ "$unknown_count" -ge 2 ]]; then
		echo "$SCORE_UNKNOWN"
		return 0
	fi

	# All checks passed
	if [[ "$rcpt_result" == "pass" ]]; then
		echo "$SCORE_DELIVERABLE"
		return 0
	fi

	echo "$SCORE_UNKNOWN"
	return 0
}

# =============================================================================
# Stats Database
# =============================================================================

init_stats_db() {
	ensure_data_dir

	sqlite3 "$STATS_DB" <<-'STATSQL'
		CREATE TABLE IF NOT EXISTS verifications (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			email TEXT NOT NULL,
			domain TEXT NOT NULL,
			score TEXT NOT NULL,
			syntax_result TEXT,
			mx_result TEXT,
			disposable_result TEXT,
			rcpt_result TEXT,
			catchall_result TEXT,
			verified_at TEXT DEFAULT (datetime('now'))
		);
		CREATE INDEX IF NOT EXISTS idx_verifications_domain ON verifications(domain);
		CREATE INDEX IF NOT EXISTS idx_verifications_score ON verifications(score);
		CREATE INDEX IF NOT EXISTS idx_verifications_date ON verifications(verified_at);
	STATSQL

	return 0
}

record_verification() {
	local email="$1"
	local domain="$2"
	local score="$3"
	local syntax_r="$4"
	local mx_r="$5"
	local disposable_r="$6"
	local rcpt_r="$7"
	local catchall_r="$8"

	init_stats_db 2>/dev/null || return 0

	sqlite3 "$STATS_DB" "INSERT INTO verifications (email, domain, score, syntax_result, mx_result, disposable_result, rcpt_result, catchall_result) VALUES ('$(echo "$email" | sed "s/'/''/g")', '$(echo "$domain" | sed "s/'/''/g")', '$score', '$syntax_r', '$mx_r', '$disposable_r', '$rcpt_r', '$catchall_r');" 2>/dev/null || true

	return 0
}

# =============================================================================
# Main Verify Command - Helper Functions
# =============================================================================

# Print verbose result for a named check using pass/warn/fail/skip result codes.
# Args: label result details
_verify_print_check() {
	local label="$1"
	local result="$2"
	local details="$3"
	case "$result" in
	pass) print_success "${label}: ${details}" ;;
	warn) print_warning "${label}: ${details}" ;;
	fail) print_error "${label}: ${details}" ;;
	skip) print_info "${label}: ${details}" ;;
	*) print_info "${label}: ${details}" ;;
	esac
	return 0
}

# Print the final score line in verbose mode.
# Args: score
_verify_print_score() {
	local score="$1"
	echo ""
	case "$score" in
	"$SCORE_DELIVERABLE") echo -e "  Score: ${GREEN}${score}${NC}" ;;
	"$SCORE_RISKY") echo -e "  Score: ${YELLOW}${score}${NC}" ;;
	"$SCORE_UNDELIVERABLE") echo -e "  Score: ${RED}${score}${NC}" ;;
	*) echo -e "  Score: ${BLUE}${score}${NC}" ;;
	esac
	return 0
}

# Run checks 1-3 (syntax, MX, disposable) and short-circuit on hard failures.
# Outputs: sets caller variables via echo to a subshell is not viable in bash 3.2,
# so this function prints "ok:<syntax_result>:<mx_result>:<mx_host>:<disposable_result>"
# on success, or "fail:<score>:<check>:<details>" on short-circuit.
# Args: email domain verbose
_verify_early_checks() {
	local email="$1"
	local domain="$2"
	local verbose="$3"

	# Check 1: Syntax
	local syntax_output syntax_result syntax_details
	syntax_output=$(check_syntax "$email" 2>/dev/null || true)
	syntax_result=$(echo "$syntax_output" | cut -d: -f2)
	syntax_details=$(echo "$syntax_output" | cut -d: -f3-)

	if [[ "$verbose" == "true" ]]; then
		_verify_print_check "Syntax" "$syntax_result" "$syntax_details"
	fi

	if [[ "$syntax_result" == "fail" ]]; then
		echo "fail:${SCORE_UNDELIVERABLE}:syntax_fail:${syntax_details}:${syntax_result}:skip:skip:skip:skip"
		return 1
	fi

	# Check 2: MX Records
	local mx_output mx_result mx_details mx_host
	mx_output=$(check_mx "$domain" 2>/dev/null || true)
	mx_result=$(echo "$mx_output" | cut -d: -f2)
	mx_details=$(echo "$mx_output" | cut -d: -f3)
	mx_host=$(echo "$mx_output" | cut -d: -f4 | tr -d ' ')

	if [[ "$verbose" == "true" ]]; then
		_verify_print_check "MX" "$mx_result" "$mx_details"
	fi

	if [[ "$mx_result" == "fail" ]]; then
		echo "fail:${SCORE_UNDELIVERABLE}:no_mx:${mx_details}:${syntax_result}:${mx_result}:skip:skip:skip"
		return 1
	fi

	# Check 3: Disposable Domain
	local disposable_output disposable_result disposable_details
	disposable_output=$(check_disposable "$domain" 2>/dev/null || true)
	disposable_result=$(echo "$disposable_output" | cut -d: -f2)
	disposable_details=$(echo "$disposable_output" | cut -d: -f3-)

	if [[ "$verbose" == "true" ]]; then
		_verify_print_check "Disposable" "$disposable_result" "$disposable_details"
	fi

	if [[ "$disposable_result" == "fail" ]]; then
		echo "fail:${SCORE_UNDELIVERABLE}:disposable:${disposable_details}:${syntax_result}:${mx_result}:${disposable_result}:skip:skip"
		return 1
	fi

	echo "ok:${syntax_result}:${mx_result}:${mx_host}:${disposable_result}"
	return 0
}

# Run checks 4-6 (RCPT TO, full inbox, catch-all) and print verbose output.
# Prints "rcpt_result:rcpt_details:catchall_result:catchall_details" on stdout.
# Args: email domain mx_host verbose
_verify_smtp_checks() {
	local email="$1"
	local domain="$2"
	local mx_host="$3"
	local verbose="$4"

	# Check 4 & 5: SMTP RCPT TO + Full Inbox
	local rcpt_output rcpt_result rcpt_details
	rcpt_output=$(check_rcpt_to "$email" "$mx_host" 2>/dev/null || true)
	rcpt_result=$(echo "$rcpt_output" | cut -d: -f2)
	rcpt_details=$(echo "$rcpt_output" | cut -d: -f3-)

	if [[ "$verbose" == "true" ]]; then
		_verify_print_check "RCPT TO" "$rcpt_result" "$rcpt_details"
	fi

	# Check 6: Catch-All Detection
	local catchall_output catchall_result catchall_details
	catchall_output=$(check_catch_all "$domain" "$mx_host" 2>/dev/null || true)
	catchall_result=$(echo "$catchall_output" | cut -d: -f2)
	catchall_details=$(echo "$catchall_output" | cut -d: -f3-)

	if [[ "$verbose" == "true" ]]; then
		_verify_print_check "Catch-all" "$catchall_result" "$catchall_details"
	fi

	echo "${rcpt_result}:${rcpt_details}:${catchall_result}:${catchall_details}"
	return 0
}

# =============================================================================
# Main Verify Command
# =============================================================================

verify_email() {
	local email="$1"
	local verbose="${2:-false}"

	# Normalize to lowercase
	email=$(echo "$email" | tr '[:upper:]' '[:lower:]')

	local domain
	domain=$(extract_domain "$email")

	if [[ "$verbose" == "true" ]]; then
		print_header "Verifying: ${email}"
	fi

	# Checks 1-3: syntax, MX, disposable (with short-circuit on failure)
	local early_out
	early_out=$(_verify_early_checks "$email" "$domain" "$verbose")
	local early_status="$?"

	if [[ "$early_status" -ne 0 ]]; then
		# Short-circuit: parse fail:<score>:<check>:<details>:<s>:<m>:<d>:<r>:<c>
		local score check details s_r m_r d_r r_r c_r
		score=$(echo "$early_out" | cut -d: -f2)
		check=$(echo "$early_out" | cut -d: -f3)
		details=$(echo "$early_out" | cut -d: -f4)
		s_r=$(echo "$early_out" | cut -d: -f5)
		m_r=$(echo "$early_out" | cut -d: -f6)
		d_r=$(echo "$early_out" | cut -d: -f7)
		r_r=$(echo "$early_out" | cut -d: -f8)
		c_r=$(echo "$early_out" | cut -d: -f9)
		if [[ "$verbose" == "true" ]]; then
			_verify_print_score "$score"
		else
			echo "${email},${score},${check},${details}"
		fi
		record_verification "$email" "$domain" "$score" "$s_r" "$m_r" "$d_r" "$r_r" "$c_r"
		return 0
	fi

	# Parse ok:<syntax_result>:<mx_result>:<mx_host>:<disposable_result>
	local syntax_result mx_result mx_host disposable_result
	syntax_result=$(echo "$early_out" | cut -d: -f2)
	mx_result=$(echo "$early_out" | cut -d: -f3)
	mx_host=$(echo "$early_out" | cut -d: -f4)
	disposable_result=$(echo "$early_out" | cut -d: -f5)

	# Checks 4-6: SMTP RCPT TO, full inbox, catch-all
	local smtp_out rcpt_result rcpt_details catchall_result
	smtp_out=$(_verify_smtp_checks "$email" "$domain" "$mx_host" "$verbose")
	rcpt_result=$(echo "$smtp_out" | cut -d: -f1)
	rcpt_details=$(echo "$smtp_out" | cut -d: -f2)
	catchall_result=$(echo "$smtp_out" | cut -d: -f3)

	# Calculate and output score
	local score
	score=$(calculate_score "$syntax_result" "$mx_result" "$disposable_result" "$rcpt_result" "$catchall_result")

	if [[ "$verbose" == "true" ]]; then
		_verify_print_score "$score"
	else
		echo "${email},${score},${rcpt_result},${rcpt_details}"
	fi

	record_verification "$email" "$domain" "$score" \
		"$syntax_result" "$mx_result" "$disposable_result" \
		"$rcpt_result" "$catchall_result"

	return 0
}

# =============================================================================
# Bulk Verify Command
# =============================================================================

bulk_verify() {
	local input_file="$1"
	local output_file="${2:-}"

	if [[ ! -f "$input_file" ]]; then
		print_error "File not found: ${input_file}"
		return 1
	fi

	local total
	total=$(grep -cE '\S' "$input_file" || echo "0")
	local count=0
	local deliverable=0
	local risky=0
	local undeliverable=0
	local unknown=0

	print_header "Bulk Verification: ${total} addresses"
	echo "email,score,check,details" >"${output_file:-/dev/stdout}" 2>/dev/null || true

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip empty lines and comments
		line=$(echo "$line" | tr -d '\r' | xargs 2>/dev/null || echo "$line")
		[[ -z "$line" ]] && continue
		[[ "$line" == \#* ]] && continue

		count=$((count + 1))
		local result
		result=$(verify_email "$line" "false" 2>/dev/null || true)

		if [[ -n "$output_file" ]]; then
			echo "$result" >>"$output_file"
		else
			echo "$result"
		fi

		# Count scores
		local score
		score=$(echo "$result" | cut -d, -f2)
		case "$score" in
		"$SCORE_DELIVERABLE") deliverable=$((deliverable + 1)) ;;
		"$SCORE_RISKY") risky=$((risky + 1)) ;;
		"$SCORE_UNDELIVERABLE") undeliverable=$((undeliverable + 1)) ;;
		*) unknown=$((unknown + 1)) ;;
		esac

		# Progress indicator every 10 emails
		if [[ $((count % 10)) -eq 0 ]]; then
			echo -e "${BLUE}[${count}/${total}]${NC} processed..." >&2
		fi

		# Rate limiting: 1 second between SMTP probes to avoid blocks
		sleep 1
	done <"$input_file"

	# Summary
	echo "" >&2
	print_header "Bulk Verification Summary"
	echo "  Total:         ${count}" >&2
	echo -e "  Deliverable:   ${GREEN}${deliverable}${NC}" >&2
	echo -e "  Risky:         ${YELLOW}${risky}${NC}" >&2
	echo -e "  Undeliverable: ${RED}${undeliverable}${NC}" >&2
	echo -e "  Unknown:       ${BLUE}${unknown}${NC}" >&2

	if [[ -n "$output_file" ]]; then
		print_success "Results written to: ${output_file}" >&2
	fi

	return 0
}

# =============================================================================
# Update Domains Command
# =============================================================================

update_domains() {
	print_header "Updating Disposable Domain Database"

	if ! command_exists curl; then
		print_error "curl is required for domain list updates"
		return 1
	fi

	ensure_data_dir
	init_disposable_db

	# Download the domain list
	local tmp_file
	tmp_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_file'" EXIT

	print_info "Downloading disposable domain list..."
	if ! curl -sS -L --max-time 60 -o "$tmp_file" "$DISPOSABLE_DOMAINS_URL"; then
		print_error "Failed to download domain list"
		rm -f "$tmp_file"
		return 1
	fi

	local new_count
	new_count=$(grep -cE '\S' "$tmp_file" || echo "0")

	if [[ "$new_count" -lt 100 ]]; then
		print_error "Downloaded list seems too small (${new_count} domains) - aborting"
		rm -f "$tmp_file"
		return 1
	fi

	# Get current count
	local old_count
	old_count=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains;" 2>/dev/null || echo "0")

	print_info "Current: ${old_count} domains, New: ${new_count} domains"

	# Rebuild the database (faster than incremental for large lists)
	print_info "Rebuilding database..."

	sqlite3 "$DISPOSABLE_DB" "DELETE FROM domains;" 2>/dev/null || true
	sqlite3 "$DISPOSABLE_DB" "DELETE FROM domains_fts;" 2>/dev/null || true

	# Batch insert for performance
	local batch_size=1000
	local batch_count=0
	local insert_sql="BEGIN TRANSACTION;"

	while IFS= read -r domain || [[ -n "$domain" ]]; do
		domain=$(echo "$domain" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || echo "$domain")
		[[ -z "$domain" ]] && continue
		[[ "$domain" == \#* ]] && continue

		# Escape single quotes for SQL
		domain=$(echo "$domain" | sed "s/'/''/g")
		insert_sql="${insert_sql}INSERT OR IGNORE INTO domains(domain) VALUES('${domain}');"
		batch_count=$((batch_count + 1))

		if [[ $((batch_count % batch_size)) -eq 0 ]]; then
			insert_sql="${insert_sql}COMMIT;BEGIN TRANSACTION;"
		fi
	done <"$tmp_file"

	insert_sql="${insert_sql}COMMIT;"

	echo "$insert_sql" | sqlite3 "$DISPOSABLE_DB" 2>/dev/null

	# Update metadata
	sqlite3 "$DISPOSABLE_DB" "INSERT OR REPLACE INTO metadata(key, value) VALUES('last_updated', datetime('now'));" 2>/dev/null || true
	sqlite3 "$DISPOSABLE_DB" "INSERT OR REPLACE INTO metadata(key, value) VALUES('source_url', '${DISPOSABLE_DOMAINS_URL}');" 2>/dev/null || true

	# Rebuild FTS index
	sqlite3 "$DISPOSABLE_DB" "INSERT INTO domains_fts(domains_fts) VALUES('rebuild');" 2>/dev/null || true

	local final_count
	final_count=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains;" 2>/dev/null || echo "0")

	rm -f "$tmp_file"

	print_success "Database updated: ${final_count} disposable domains loaded"

	local last_updated
	last_updated=$(sqlite3 "$DISPOSABLE_DB" "SELECT value FROM metadata WHERE key='last_updated';" 2>/dev/null || echo "unknown")
	print_info "Last updated: ${last_updated}"

	return 0
}

# =============================================================================
# Stats Command
# =============================================================================

show_stats() {
	print_header "Email Verification Statistics"

	if [[ ! -f "$STATS_DB" ]]; then
		print_info "No verification history yet"
		return 0
	fi

	local total
	total=$(sqlite3 "$STATS_DB" "SELECT COUNT(*) FROM verifications;" 2>/dev/null || echo "0")

	if [[ "$total" == "0" ]]; then
		print_info "No verifications recorded yet"
		return 0
	fi

	echo "  Total verifications: ${total}"
	echo ""

	# Score breakdown
	echo "  Score breakdown:"
	sqlite3 -separator ' ' "$STATS_DB" \
		"SELECT '    ' || score || ': ' || COUNT(*) || ' (' || ROUND(COUNT(*) * 100.0 / ${total}, 1) || '%)' FROM verifications GROUP BY score ORDER BY COUNT(*) DESC;" 2>/dev/null || true

	echo ""

	# Top domains
	echo "  Top 10 domains verified:"
	sqlite3 -separator ' ' "$STATS_DB" \
		"SELECT '    ' || domain || ': ' || COUNT(*) FROM verifications GROUP BY domain ORDER BY COUNT(*) DESC LIMIT 10;" 2>/dev/null || true

	echo ""

	# Recent verifications
	echo "  Last 5 verifications:"
	sqlite3 -separator ' ' "$STATS_DB" \
		"SELECT '    ' || email || ' -> ' || score || ' (' || verified_at || ')' FROM verifications ORDER BY id DESC LIMIT 5;" 2>/dev/null || true

	# Disposable domain DB stats
	if [[ -f "$DISPOSABLE_DB" ]]; then
		echo ""
		echo "  Disposable domain database:"
		local domain_count
		domain_count=$(sqlite3 "$DISPOSABLE_DB" "SELECT COUNT(*) FROM domains;" 2>/dev/null || echo "0")
		echo "    Domains loaded: ${domain_count}"

		local last_updated
		last_updated=$(sqlite3 "$DISPOSABLE_DB" "SELECT value FROM metadata WHERE key='last_updated';" 2>/dev/null || echo "never")
		echo "    Last updated: ${last_updated}"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	echo "Email Verify Helper - Local email address verification"
	echo ""
	echo "$USAGE_COMMAND_OPTIONS"
	echo ""
	echo "Commands:"
	echo "  verify <email>           Verify a single email address"
	echo "  verify <email> --quiet   Verify with CSV output (no colors)"
	echo "  bulk <file> [output]     Verify emails from file (one per line)"
	echo "  update-domains           Refresh disposable domain database"
	echo "  stats                    Show verification statistics"
	echo "  help                     ${HELP_SHOW_MESSAGE}"
	echo ""
	echo "Checks performed:"
	echo "  1. Syntax/format validation (RFC 5321)"
	echo "  2. MX record lookup (dig)"
	echo "  3. Disposable domain detection (SQLite FTS5)"
	echo "  4. SMTP RCPT TO mailbox probing"
	echo "  5. Full inbox detection (SMTP 452)"
	echo "  6. Catch-all detection (random address probe)"
	echo ""
	echo "Scoring:"
	echo "  deliverable    - All checks passed, mailbox confirmed"
	echo "  risky          - Catch-all, full inbox, or warnings"
	echo "  undeliverable  - Invalid syntax, no MX, disposable, or rejected"
	echo "  unknown        - Could not determine (SMTP blocked, etc.)"
	echo ""
	echo "Examples:"
	echo "  $0 verify user@example.com"
	echo "  $0 bulk emails.txt results.csv"
	echo "  $0 update-domains"
	echo "  $0 stats"
	echo ""
	echo "Dependencies:"
	echo "  Required: dig, sqlite3"
	echo "  SMTP:     openssl or nc/ncat"
	echo "  Updates:  curl"
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	verify)
		local email="${1:-}"
		if [[ -z "$email" ]]; then
			print_error "Email address required"
			echo "$HELP_USAGE_INFO"
			return 1
		fi
		local verbose="true"
		if [[ "${2:-}" == "--quiet" ]] || [[ "${2:-}" == "-q" ]]; then
			verbose="false"
		fi
		verify_email "$email" "$verbose"
		;;
	bulk)
		local input_file="${1:-}"
		local output_file="${2:-}"
		if [[ -z "$input_file" ]]; then
			print_error "$ERROR_INPUT_FILE_REQUIRED"
			echo "$HELP_USAGE_INFO"
			return 1
		fi
		bulk_verify "$input_file" "$output_file"
		;;
	update-domains | update)
		update_domains
		;;
	stats)
		show_stats
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		echo "$HELP_USAGE_INFO"
		return 1
		;;
	esac

	return 0
}

main "$@"
