#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Sieve Helper Script
# Generates Sieve filter rules from triage classification patterns and deploys
# them to compatible mail servers via ManageSieve protocol.
#
# Usage:
#   email-sieve-helper.sh generate [--output <file>] [--patterns <file>]
#   email-sieve-helper.sh deploy --server <host> --user <user> [--port <port>] [--script <name>] [--file <sieve-file>]
#   email-sieve-helper.sh validate [--file <sieve-file>]
#   email-sieve-helper.sh list-scripts --server <host> --user <user> [--port <port>]
#   email-sieve-helper.sh show-script --server <host> --user <user> --script <name> [--port <port>]
#   email-sieve-helper.sh delete-script --server <host> --user <user> --script <name> [--port <port>]
#   email-sieve-helper.sh add-pattern --type <type> --value <value> --folder <folder> [--patterns <file>]
#   email-sieve-helper.sh status
#   email-sieve-helper.sh help
#
# Pattern types: sender, domain, subject, list-id, header, transaction
#
# Requires: python3 (for ManageSieve), jq (for pattern files)
# Optional: sieve-connect (alternative ManageSieve client)
# Config: configs/email-sieve-config.json (from .json.txt template)
# Credentials: aidevops secret set SIEVE_PASSWORD
#
# Part of aidevops email system (t1503)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

init_log_file

# ============================================================================
# Constants
# ============================================================================

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly CONFIG_FILE="${CONFIG_DIR}/email-sieve-config.json"
readonly DEFAULT_PATTERNS_FILE="${CONFIG_DIR}/email-sieve-patterns.json"
readonly DEFAULT_OUTPUT_FILE="/tmp/aidevops-generated.sieve"
readonly DEFAULT_SCRIPT_NAME="aidevops-triage"
readonly DEFAULT_SIEVE_PORT=4190
readonly MANAGESIEVE_PYTHON_HELPER="${SCRIPT_DIR}/email-sieve-managesieve.py"

# Sieve RFC 5228 / RFC 5429 capabilities we use
readonly SIEVE_REQUIRES_FILEINTO="fileinto"
readonly SIEVE_REQUIRES_IMAP_FLAGS="imap4flags"
readonly SIEVE_REQUIRES_COPY="copy"
readonly SIEVE_REQUIRES_REGEX="regex"
readonly SIEVE_REQUIRES_ENVELOPE="envelope"

# ============================================================================
# Dependency checks
# ============================================================================

check_dependencies() {
	local missing=0

	if ! command -v python3 &>/dev/null; then
		print_error "python3 is required for ManageSieve deployment"
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

check_deploy_dependencies() {
	if ! python3 -c "import ssl, socket" 2>/dev/null; then
		print_error "python3 ssl/socket modules required for ManageSieve"
		return 1
	fi
	return 0
}

# ============================================================================
# Pattern file management
# ============================================================================

# Initialise an empty patterns file if it doesn't exist
init_patterns_file() {
	local patterns_file="$1"

	if [[ -f "$patterns_file" ]]; then
		return 0
	fi

	local dir
	dir="$(dirname "$patterns_file")"
	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
	fi

	cat >"$patterns_file" <<'PATTERNS_EOF'
{
  "version": "1.0",
  "description": "Email Sieve triage patterns for auto-sort rule generation",
  "patterns": []
}
PATTERNS_EOF
	print_info "Initialised patterns file: $patterns_file"
	return 0
}

# Add a pattern to the patterns file
add_pattern() {
	local pattern_type="$1"
	local pattern_value="$2"
	local target_folder="$3"
	local patterns_file="${4:-$DEFAULT_PATTERNS_FILE}"
	local flags="${5:-}"
	local priority="${6:-50}"

	init_patterns_file "$patterns_file"

	# Validate pattern type
	case "$pattern_type" in
	sender | domain | subject | list-id | header | transaction | mailing-list | notification) ;;
	*)
		print_error "Unknown pattern type: $pattern_type"
		print_info "Valid types: sender, domain, subject, list-id, header, transaction, mailing-list, notification"
		return 1
		;;
	esac

	local new_pattern
	new_pattern=$(jq -n \
		--arg type "$pattern_type" \
		--arg value "$pattern_value" \
		--arg folder "$target_folder" \
		--arg flags "$flags" \
		--argjson priority "$priority" \
		'{type: $type, value: $value, folder: $folder, flags: $flags, priority: $priority}')

	local tmp_file
	tmp_file="$(mktemp)"
	jq --argjson pattern "$new_pattern" '.patterns += [$pattern]' "$patterns_file" >"$tmp_file"
	mv "$tmp_file" "$patterns_file"

	print_success "Added $pattern_type pattern: $pattern_value -> $target_folder"
	return 0
}

# ============================================================================
# Sieve rule generation
# ============================================================================

# Emit the Sieve file header with require declarations
generate_header() {
	local requires=("$@")
	local req_list=""

	if [[ "${#requires[@]}" -gt 0 ]]; then
		local first=1
		for req in "${requires[@]}"; do
			if [[ "$first" -eq 1 ]]; then
				req_list="\"$req\""
				first=0
			else
				req_list="${req_list}, \"$req\""
			fi
		done
		echo "require [${req_list}];"
	fi

	cat <<'HEADER_EOF'

# Generated by aidevops email-sieve-helper.sh
# Task: t1503 — Sieve rule generator
# DO NOT EDIT MANUALLY — regenerate from patterns file

HEADER_EOF
	return 0
}

# Generate a fileinto action, creating the folder if needed
action_fileinto() {
	local folder="$1"
	local flags="$2"
	local copy="${3:-0}"

	local action=""
	if [[ -n "$flags" ]]; then
		action="addflag \"${flags}\";"$'\n'
	fi

	if [[ "$copy" -eq 1 ]]; then
		action="${action}fileinto :copy \"${folder}\";"
	else
		action="${action}fileinto \"${folder}\";"
	fi

	echo "$action"
	return 0
}

# Generate a sender-based rule
generate_sender_rule() {
	local sender="$1"
	local folder="$2"
	local flags="$3"

	cat <<RULE_EOF
if address :is "from" "${sender}" {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate a domain-based rule (matches any sender from that domain)
generate_domain_rule() {
	local domain="$1"
	local folder="$2"
	local flags="$3"

	cat <<RULE_EOF
if address :domain :is "from" "${domain}" {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate a subject pattern rule (substring match)
generate_subject_rule() {
	local subject_pattern="$1"
	local folder="$2"
	local flags="$3"

	cat <<RULE_EOF
if header :contains "subject" "${subject_pattern}" {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate a mailing list detection rule (List-Id header)
generate_list_id_rule() {
	local list_id="$1"
	local folder="$2"
	local flags="$3"

	cat <<RULE_EOF
if header :contains "list-id" "${list_id}" {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate a generic header match rule
generate_header_rule() {
	local header_name="$1"
	local header_value="$2"
	local folder="$3"
	local flags="$4"

	cat <<RULE_EOF
if header :contains "${header_name}" "${header_value}" {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate transaction email routing rules (receipts, invoices, notifications)
generate_transaction_rules() {
	local folder="$1"
	local flags="$2"

	cat <<RULE_EOF
# Transaction email detection (receipts, invoices, order confirmations)
if anyof (
    header :contains "subject" "receipt",
    header :contains "subject" "invoice",
    header :contains "subject" "order confirmation",
    header :contains "subject" "payment confirmation",
    header :contains "subject" "your order",
    header :contains "subject" "order #",
    header :contains "subject" "booking confirmation",
    header :contains "subject" "reservation confirmation",
    header :contains "x-mailer" "transactional",
    header :contains "x-message-type" "transactional",
    header :is "auto-submitted" "auto-generated",
    header :contains "x-auto-response-suppress" "All"
) {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate mailing list auto-detection rules
generate_mailing_list_rules() {
	local folder="$1"
	local flags="$2"

	cat <<RULE_EOF
# Mailing list auto-detection (RFC 2369 headers)
if anyof (
    exists "list-id",
    exists "list-unsubscribe",
    exists "list-post",
    exists "list-archive",
    header :contains "precedence" "list",
    header :contains "precedence" "bulk"
) {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Generate notification/automated email rules
generate_notification_rules() {
	local folder="$1"
	local flags="$2"

	cat <<RULE_EOF
# Automated notification detection
if anyof (
    address :is "from" "noreply@*",
    address :is "from" "no-reply@*",
    address :is "from" "notifications@*",
    address :is "from" "donotreply@*",
    header :is "auto-submitted" "auto-generated",
    header :is "auto-submitted" "auto-replied",
    header :contains "x-notifications" "true"
) {
    $(action_fileinto "$folder" "$flags")
    stop;
}
RULE_EOF
	return 0
}

# Main Sieve generation function — reads patterns file and emits Sieve script
generate_sieve() {
	local patterns_file="${1:-$DEFAULT_PATTERNS_FILE}"
	local output_file="${2:-$DEFAULT_OUTPUT_FILE}"

	if [[ ! -f "$patterns_file" ]]; then
		print_error "Patterns file not found: $patterns_file"
		print_info "Create one with: $0 add-pattern --type sender --value user@example.com --folder INBOX/Work"
		return 1
	fi

	# Determine which Sieve extensions are needed
	local needs_fileinto=0
	local needs_flags=0

	local pattern_count
	pattern_count=$(jq '.patterns | length' "$patterns_file")

	if [[ "$pattern_count" -gt 0 ]]; then
		needs_fileinto=1
		# Check if any pattern uses flags
		local flagged_count
		flagged_count=$(jq '[.patterns[] | select(.flags != "")] | length' "$patterns_file")
		if [[ "$flagged_count" -gt 0 ]]; then
			needs_flags=1
		fi
	fi

	# Check for built-in rule types that need fileinto
	local has_transaction has_list has_notification
	has_transaction=$(jq '[.patterns[] | select(.type == "transaction")] | length' "$patterns_file")
	has_list=$(jq '[.patterns[] | select(.type == "list-id")] | length' "$patterns_file")
	has_notification=$(jq '[.patterns[] | select(.type == "notification")] | length' "$patterns_file")

	if [[ "$has_transaction" -gt 0 ]] || [[ "$has_list" -gt 0 ]] || [[ "$has_notification" -gt 0 ]]; then
		needs_fileinto=1
	fi

	# Build requires list
	local requires=()
	if [[ "$needs_fileinto" -eq 1 ]]; then
		requires+=("$SIEVE_REQUIRES_FILEINTO")
	fi
	if [[ "$needs_flags" -eq 1 ]]; then
		requires+=("$SIEVE_REQUIRES_IMAP_FLAGS")
	fi

	# Write to output file
	{
		generate_header "${requires[@]}"

		# Sort patterns by priority (lower number = higher priority) and generate rules
		local sorted_patterns
		sorted_patterns=$(jq -c '[.patterns | sort_by(.priority) | .[]]' "$patterns_file")

		# Process each pattern
		local idx=0
		local total
		total=$(jq '.patterns | length' "$patterns_file")

		while [[ "$idx" -lt "$total" ]]; do
			local pattern
			pattern=$(jq -c ".patterns | sort_by(.priority) | .[$idx]" "$patterns_file")

			local ptype pvalue pfolder pflags
			ptype=$(echo "$pattern" | jq -r '.type')
			pvalue=$(echo "$pattern" | jq -r '.value')
			pfolder=$(echo "$pattern" | jq -r '.folder')
			pflags=$(echo "$pattern" | jq -r '.flags // ""')

			case "$ptype" in
			sender)
				generate_sender_rule "$pvalue" "$pfolder" "$pflags"
				;;
			domain)
				generate_domain_rule "$pvalue" "$pfolder" "$pflags"
				;;
			subject)
				generate_subject_rule "$pvalue" "$pfolder" "$pflags"
				;;
			list-id)
				generate_list_id_rule "$pvalue" "$pfolder" "$pflags"
				;;
			header)
				local hname hval
				hname=$(echo "$pvalue" | cut -d: -f1)
				hval=$(echo "$pvalue" | cut -d: -f2-)
				generate_header_rule "$hname" "$hval" "$pfolder" "$pflags"
				;;
			transaction)
				generate_transaction_rules "$pfolder" "$pflags"
				;;
			mailing-list)
				generate_mailing_list_rules "$pfolder" "$pflags"
				;;
			notification)
				generate_notification_rules "$pfolder" "$pflags"
				;;
			*)
				print_warning "Unknown pattern type '$ptype' — skipping"
				;;
			esac

			idx=$((idx + 1))
		done

		# Always end with a keep (implicit, but explicit is clearer)
		echo ""
		echo "# Default: keep all other messages in INBOX"
		echo "keep;"

	} >"$output_file"

	print_success "Generated Sieve script: $output_file"
	print_info "Rules generated: $pattern_count patterns"
	return 0
}

# ============================================================================
# Sieve validation
# ============================================================================

validate_sieve() {
	local sieve_file="${1:-$DEFAULT_OUTPUT_FILE}"

	if [[ ! -f "$sieve_file" ]]; then
		print_error "Sieve file not found: $sieve_file"
		return 1
	fi

	print_info "Validating Sieve script: $sieve_file"

	# Basic structural validation
	local errors=0

	# Check require statement exists if fileinto is used
	if grep -q "fileinto" "$sieve_file" && ! grep -q 'require.*fileinto' "$sieve_file"; then
		print_error "fileinto used but not declared in require"
		errors=$((errors + 1))
	fi

	# Check imap4flags require if addflag is used
	if grep -q "addflag\|setflag\|removeflag" "$sieve_file" && ! grep -q 'require.*imap4flags' "$sieve_file"; then
		print_error "imap4flags actions used but not declared in require"
		errors=$((errors + 1))
	fi

	# Check balanced braces
	local open_braces close_braces
	open_braces=$(grep -o '{' "$sieve_file" | wc -l | tr -d ' ')
	close_braces=$(grep -o '}' "$sieve_file" | wc -l | tr -d ' ')
	if [[ "$open_braces" -ne "$close_braces" ]]; then
		print_error "Unbalanced braces: $open_braces open, $close_braces close"
		errors=$((errors + 1))
	fi

	# Check for semicolons after actions (basic check)
	if grep -qE "^[[:space:]]*(fileinto|keep|discard|redirect|stop)[^;]*$" "$sieve_file"; then
		print_warning "Possible missing semicolons detected — review generated script"
	fi

	# Use sieve-connect for validation if available
	if command -v sieve-connect &>/dev/null; then
		print_info "sieve-connect available — use 'sieve-connect --validate $sieve_file' for full RFC validation"
	fi

	# Use python3 sievelib if available
	if python3 -c "import sievelib" 2>/dev/null; then
		local py_result
		py_result=$(
			python3 - "$sieve_file" <<'PYEOF'
import sys
try:
    from sievelib.parser import Parser
    p = Parser()
    with open(sys.argv[1]) as f:
        content = f.read()
    result = p.parse(content)
    if result:
        print("VALID")
    else:
        print("INVALID: " + str(p.error))
        sys.exit(1)
except ImportError:
    print("sievelib not available")
except Exception as e:
    print("ERROR: " + str(e))
    sys.exit(1)
PYEOF
		)
		if echo "$py_result" | grep -q "^VALID"; then
			print_success "sievelib validation: VALID"
		elif echo "$py_result" | grep -q "^INVALID"; then
			print_error "sievelib validation: $py_result"
			errors=$((errors + 1))
		fi
	fi

	if [[ "$errors" -eq 0 ]]; then
		print_success "Validation passed: $sieve_file"
		return 0
	else
		print_error "Validation failed with $errors error(s)"
		return 1
	fi
}

# ============================================================================
# ManageSieve deployment (RFC 5804)
# ============================================================================

# Write the Python ManageSieve helper to a temp file
write_managesieve_helper() {
	local helper_file="$1"

	cat >"$helper_file" <<'PYEOF'
#!/usr/bin/env python3
"""
ManageSieve client helper for email-sieve-helper.sh
Implements RFC 5804 ManageSieve protocol over TLS.
Usage: python3 <this_file> <command> <host> <port> <user> <password_env_var> [args...]
Commands: list, get <script_name>, put <script_name> <sieve_file>, delete <script_name>
Password is read from the environment variable named by password_env_var.
"""
import sys
import os
import ssl
import socket
import re

def read_response(sock):
    """Read a ManageSieve response, handling multi-line and literal strings."""
    lines = []
    while True:
        line = b""
        while not line.endswith(b"\r\n"):
            chunk = sock.recv(1)
            if not chunk:
                break
            line += chunk
        line = line.rstrip(b"\r\n").decode("utf-8", errors="replace")
        lines.append(line)
        # Check for terminal response
        if re.match(r'^(OK|NO|BYE)(\s|$)', line, re.IGNORECASE):
            break
        # Check for literal string continuation {N+}
        m = re.match(r'^\{(\d+)\+?\}$', line)
        if m:
            size = int(m.group(1))
            data = b""
            while len(data) < size:
                data += sock.recv(size - len(data))
            lines.append(data.decode("utf-8", errors="replace"))
    return lines

def send_command(sock, cmd):
    """Send a ManageSieve command."""
    sock.sendall((cmd + "\r\n").encode("utf-8"))

def connect_managesieve(host, port, user, password):
    """Connect and authenticate to ManageSieve server."""
    context = ssl.create_default_context()
    # Allow self-signed certs for local/Cloudron servers
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    raw_sock = socket.create_connection((host, int(port)), timeout=30)

    # Read greeting
    greeting = b""
    while True:
        chunk = raw_sock.recv(4096)
        greeting += chunk
        if b"OK" in greeting or b"\r\n" in greeting:
            break

    greeting_str = greeting.decode("utf-8", errors="replace")

    # Check if STARTTLS is available
    if "STARTTLS" in greeting_str:
        raw_sock.sendall(b"STARTTLS\r\n")
        resp = b""
        while b"\r\n" not in resp:
            resp += raw_sock.recv(4096)
        if b"OK" in resp:
            sock = context.wrap_socket(raw_sock, server_hostname=host)
        else:
            sock = raw_sock
    else:
        # Try direct TLS
        try:
            sock = context.wrap_socket(raw_sock, server_hostname=host)
            # Re-read greeting over TLS
            greeting = b""
            while True:
                chunk = sock.recv(4096)
                greeting += chunk
                if b"OK" in greeting:
                    break
        except ssl.SSLError:
            sock = raw_sock

    # Authenticate with PLAIN SASL
    import base64
    auth_str = "\x00" + user + "\x00" + password
    auth_b64 = base64.b64encode(auth_str.encode("utf-8")).decode("ascii")
    send_command(sock, 'AUTHENTICATE "PLAIN" "' + auth_b64 + '"')
    resp = read_response(sock)
    resp_str = "\n".join(resp)
    if not re.search(r'^OK', resp_str, re.MULTILINE | re.IGNORECASE):
        raise RuntimeError("Authentication failed: " + resp_str)

    return sock

def cmd_list(sock):
    send_command(sock, "LISTSCRIPTS")
    resp = read_response(sock)
    for line in resp:
        if line and not re.match(r'^(OK|NO|BYE)', line, re.IGNORECASE):
            print(line)
    return 0

def cmd_get(sock, script_name):
    send_command(sock, 'GETSCRIPT "' + script_name + '"')
    resp = read_response(sock)
    for line in resp:
        if not re.match(r'^(OK|NO|BYE)', line, re.IGNORECASE):
            print(line)
    return 0

def cmd_put(sock, script_name, sieve_file):
    with open(sieve_file, "r", encoding="utf-8") as f:
        content = f.read()
    size = len(content.encode("utf-8"))
    send_command(sock, 'PUTSCRIPT "' + script_name + '" {' + str(size) + '+}')
    sock.sendall(content.encode("utf-8"))
    sock.sendall(b"\r\n")
    resp = read_response(sock)
    resp_str = "\n".join(resp)
    if re.search(r'^OK', resp_str, re.MULTILINE | re.IGNORECASE):
        print("OK: Script uploaded: " + script_name)
        # Activate the script
        send_command(sock, 'SETACTIVE "' + script_name + '"')
        resp2 = read_response(sock)
        resp2_str = "\n".join(resp2)
        if re.search(r'^OK', resp2_str, re.MULTILINE | re.IGNORECASE):
            print("OK: Script activated: " + script_name)
        else:
            print("WARNING: Upload succeeded but activation failed: " + resp2_str, file=sys.stderr)
        return 0
    else:
        print("ERROR: " + resp_str, file=sys.stderr)
        return 1

def cmd_delete(sock, script_name):
    send_command(sock, 'DELETESCRIPT "' + script_name + '"')
    resp = read_response(sock)
    resp_str = "\n".join(resp)
    if re.search(r'^OK', resp_str, re.MULTILINE | re.IGNORECASE):
        print("OK: Script deleted: " + script_name)
        return 0
    else:
        print("ERROR: " + resp_str, file=sys.stderr)
        return 1

def main():
    if len(sys.argv) < 6:
        print("Usage: managesieve.py <cmd> <host> <port> <user> <pass_env> [args...]", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]
    host = sys.argv[2]
    port = sys.argv[3]
    user = sys.argv[4]
    pass_env = sys.argv[5]
    extra_args = sys.argv[6:]

    password = os.environ.get(pass_env, "")
    if not password:
        print("ERROR: Password env var '" + pass_env + "' is not set or empty", file=sys.stderr)
        sys.exit(1)

    try:
        sock = connect_managesieve(host, port, user, password)
    except Exception as e:
        print("ERROR: Connection failed: " + str(e), file=sys.stderr)
        sys.exit(1)

    try:
        if command == "list":
            rc = cmd_list(sock)
        elif command == "get":
            if not extra_args:
                print("ERROR: get requires script name", file=sys.stderr)
                rc = 1
            else:
                rc = cmd_get(sock, extra_args[0])
        elif command == "put":
            if len(extra_args) < 2:
                print("ERROR: put requires script name and file", file=sys.stderr)
                rc = 1
            else:
                rc = cmd_put(sock, extra_args[0], extra_args[1])
        elif command == "delete":
            if not extra_args:
                print("ERROR: delete requires script name", file=sys.stderr)
                rc = 1
            else:
                rc = cmd_delete(sock, extra_args[0])
        else:
            print("ERROR: Unknown command: " + command, file=sys.stderr)
            rc = 1
    finally:
        try:
            send_command(sock, "LOGOUT")
        except Exception:
            pass
        sock.close()

    sys.exit(rc)

if __name__ == "__main__":
    main()
PYEOF
	chmod 0700 "$helper_file"
	return 0
}

# Deploy a Sieve script to a ManageSieve server
deploy_sieve() {
	local server="$1"
	local user="$2"
	local port="${3:-$DEFAULT_SIEVE_PORT}"
	local script_name="${4:-$DEFAULT_SCRIPT_NAME}"
	local sieve_file="${5:-$DEFAULT_OUTPUT_FILE}"

	if [[ ! -f "$sieve_file" ]]; then
		print_error "Sieve file not found: $sieve_file"
		print_info "Generate one first: $0 generate"
		return 1
	fi

	check_deploy_dependencies || return 1

	# Password must be in environment — never accept as argument
	local pass_env_var="SIEVE_PASSWORD"
	if [[ -z "${SIEVE_PASSWORD:-}" ]]; then
		print_error "SIEVE_PASSWORD environment variable is not set"
		print_info "Set it with: export SIEVE_PASSWORD=\$(gopass show -o mail/sieve)"
		print_info "Or: aidevops secret set SIEVE_PASSWORD"
		return 1
	fi

	print_info "Deploying Sieve script to $server:$port as $user"
	print_info "Script name: $script_name"
	print_info "Source file: $sieve_file"

	# Write Python helper to temp file
	local helper_tmp
	helper_tmp="$(mktemp /tmp/aidevops-managesieve-XXXXXX.py)"
	# Ensure cleanup on exit
	trap 'rm -f "$helper_tmp"' EXIT

	write_managesieve_helper "$helper_tmp"

	if python3 "$helper_tmp" put "$server" "$port" "$user" "$pass_env_var" "$script_name" "$sieve_file"; then
		print_success "Sieve script deployed and activated: $script_name"
		rm -f "$helper_tmp"
		trap - EXIT
		return 0
	else
		print_error "Deployment failed"
		rm -f "$helper_tmp"
		trap - EXIT
		return 1
	fi
}

# List scripts on a ManageSieve server
list_scripts() {
	local server="$1"
	local user="$2"
	local port="${3:-$DEFAULT_SIEVE_PORT}"

	check_deploy_dependencies || return 1

	if [[ -z "${SIEVE_PASSWORD:-}" ]]; then
		print_error "SIEVE_PASSWORD environment variable is not set"
		return 1
	fi

	local helper_tmp
	helper_tmp="$(mktemp /tmp/aidevops-managesieve-XXXXXX.py)"
	trap 'rm -f "$helper_tmp"' EXIT

	write_managesieve_helper "$helper_tmp"

	print_info "Listing Sieve scripts on $server:$port"
	python3 "$helper_tmp" list "$server" "$port" "$user" "SIEVE_PASSWORD"
	local rc=$?

	rm -f "$helper_tmp"
	trap - EXIT
	return $rc
}

# Show a specific script from a ManageSieve server
show_script() {
	local server="$1"
	local user="$2"
	local script_name="$3"
	local port="${4:-$DEFAULT_SIEVE_PORT}"

	check_deploy_dependencies || return 1

	if [[ -z "${SIEVE_PASSWORD:-}" ]]; then
		print_error "SIEVE_PASSWORD environment variable is not set"
		return 1
	fi

	local helper_tmp
	helper_tmp="$(mktemp /tmp/aidevops-managesieve-XXXXXX.py)"
	trap 'rm -f "$helper_tmp"' EXIT

	write_managesieve_helper "$helper_tmp"

	print_info "Fetching script '$script_name' from $server:$port"
	python3 "$helper_tmp" get "$server" "$port" "$user" "SIEVE_PASSWORD" "$script_name"
	local rc=$?

	rm -f "$helper_tmp"
	trap - EXIT
	return $rc
}

# Delete a script from a ManageSieve server
delete_script() {
	local server="$1"
	local user="$2"
	local script_name="$3"
	local port="${4:-$DEFAULT_SIEVE_PORT}"

	check_deploy_dependencies || return 1

	if [[ -z "${SIEVE_PASSWORD:-}" ]]; then
		print_error "SIEVE_PASSWORD environment variable is not set"
		return 1
	fi

	local helper_tmp
	helper_tmp="$(mktemp /tmp/aidevops-managesieve-XXXXXX.py)"
	trap 'rm -f "$helper_tmp"' EXIT

	write_managesieve_helper "$helper_tmp"

	print_info "Deleting script '$script_name' from $server:$port"
	python3 "$helper_tmp" delete "$server" "$port" "$user" "SIEVE_PASSWORD" "$script_name"
	local rc=$?

	rm -f "$helper_tmp"
	trap - EXIT
	return $rc
}

# ============================================================================
# Status
# ============================================================================

show_status() {
	print_info "Email Sieve Helper Status"
	echo ""

	# Check dependencies
	echo "Dependencies:"
	if command -v python3 &>/dev/null; then
		echo "  python3: $(python3 --version 2>&1)"
	else
		echo "  python3: NOT FOUND (required for deployment)"
	fi

	if command -v jq &>/dev/null; then
		echo "  jq: $(jq --version)"
	else
		echo "  jq: NOT FOUND (required)"
	fi

	if command -v sieve-connect &>/dev/null; then
		echo "  sieve-connect: $(sieve-connect --version 2>&1 | head -1)"
	else
		echo "  sieve-connect: not installed (optional)"
	fi

	if python3 -c "import sievelib" 2>/dev/null; then
		echo "  sievelib: available (enhanced validation)"
	else
		echo "  sievelib: not installed (optional, pip install sievelib)"
	fi

	echo ""

	# Check patterns file
	echo "Patterns file: ${DEFAULT_PATTERNS_FILE}"
	if [[ -f "$DEFAULT_PATTERNS_FILE" ]]; then
		local count
		count=$(jq '.patterns | length' "$DEFAULT_PATTERNS_FILE" 2>/dev/null || echo "0")
		echo "  Status: exists ($count patterns)"
	else
		echo "  Status: not found (run 'add-pattern' to create)"
	fi

	echo ""

	# Check config file
	echo "Config file: ${CONFIG_FILE}"
	if [[ -f "$CONFIG_FILE" ]]; then
		echo "  Status: exists"
	else
		echo "  Status: not found (optional)"
	fi

	echo ""

	# Check SIEVE_PASSWORD
	if [[ -n "${SIEVE_PASSWORD:-}" ]]; then
		echo "SIEVE_PASSWORD: set"
	else
		echo "SIEVE_PASSWORD: not set (required for deployment)"
	fi

	return 0
}

# ============================================================================
# Help
# ============================================================================

show_help() {
	cat <<HELP_EOF
Email Sieve Helper — Generate and deploy Sieve filter rules

USAGE
  email-sieve-helper.sh <command> [options]

COMMANDS
  generate        Generate Sieve script from patterns file
  deploy          Deploy Sieve script to ManageSieve server
  validate        Validate a Sieve script file
  list-scripts    List scripts on ManageSieve server
  show-script     Show a specific script from ManageSieve server
  delete-script   Delete a script from ManageSieve server
  add-pattern     Add a triage pattern to the patterns file
  status          Show dependency and configuration status
  help            Show this help

GENERATE OPTIONS
  --output <file>       Output file (default: /tmp/aidevops-generated.sieve)
  --patterns <file>     Patterns file (default: configs/email-sieve-patterns.json)

DEPLOY OPTIONS
  --server <host>       ManageSieve server hostname (required)
  --user <email>        Mailbox username/email (required)
  --port <port>         ManageSieve port (default: 4190)
  --script <name>       Script name on server (default: aidevops-triage)
  --file <sieve-file>   Sieve file to deploy (default: /tmp/aidevops-generated.sieve)

  Password: set SIEVE_PASSWORD environment variable before deploying.
  Never pass password as argument.

VALIDATE OPTIONS
  --file <sieve-file>   File to validate (default: /tmp/aidevops-generated.sieve)

LIST/SHOW/DELETE OPTIONS
  --server <host>       ManageSieve server hostname (required)
  --user <email>        Mailbox username/email (required)
  --port <port>         ManageSieve port (default: 4190)
  --script <name>       Script name (required for show/delete)

ADD-PATTERN OPTIONS
  --type <type>         Pattern type: sender|domain|subject|list-id|header|transaction|mailing-list|notification
  --value <value>       Pattern value (email, domain, subject text, or header:value)
  --folder <folder>     Target IMAP folder (e.g. INBOX/Work, INBOX/Lists)
  --flags <flags>       IMAP flags to set (e.g. \\Seen, \\Flagged)
  --priority <n>        Sort priority 0-100, lower = higher priority (default: 50)
  --patterns <file>     Patterns file (default: configs/email-sieve-patterns.json)

PATTERN TYPES
  sender        Match exact From address
  domain        Match From domain (e.g. github.com)
  subject       Match subject substring
  list-id       Match List-Id header (mailing lists)
  header        Match any header (value format: HeaderName:value)
  transaction   Auto-detect receipts, invoices, order confirmations
  mailing-list  Auto-detect mailing lists (RFC 2369 headers)
  notification  Auto-detect automated notifications (noreply, etc.)

EXAMPLES
  # Add patterns
  email-sieve-helper.sh add-pattern --type sender --value boss@company.com --folder INBOX/Priority --flags "\\\\Flagged"
  email-sieve-helper.sh add-pattern --type domain --value github.com --folder INBOX/GitHub
  email-sieve-helper.sh add-pattern --type subject --value "[JIRA]" --folder INBOX/Jira
  email-sieve-helper.sh add-pattern --type transaction --value "" --folder INBOX/Receipts
  email-sieve-helper.sh add-pattern --type mailing-list --value "" --folder INBOX/Lists

  # Generate and validate
  email-sieve-helper.sh generate --output ~/my-rules.sieve
  email-sieve-helper.sh validate --file ~/my-rules.sieve

  # Deploy to Cloudron/Fastmail
  export SIEVE_PASSWORD=\$(gopass show -o mail/sieve)
  email-sieve-helper.sh deploy --server mail.example.com --user me@example.com

  # Manage remote scripts
  email-sieve-helper.sh list-scripts --server mail.example.com --user me@example.com
  email-sieve-helper.sh show-script --server mail.example.com --user me@example.com --script aidevops-triage

CLOUDRON NOTES
  Cloudron uses Dovecot with ManageSieve on port 4190.
  Server: your Cloudron mail hostname (e.g. mail.yourdomain.com)
  User: full email address

FASTMAIL NOTES
  Fastmail ManageSieve: imap.fastmail.com:4190
  User: your Fastmail email address
  Password: app-specific password (not your login password)

HELP_EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	generate)
		local output_file="$DEFAULT_OUTPUT_FILE"
		local patterns_file="$DEFAULT_PATTERNS_FILE"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--output)
				output_file="$2"
				shift 2
				;;
			--patterns)
				patterns_file="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		check_dependencies || return 1
		generate_sieve "$patterns_file" "$output_file"
		;;

	deploy)
		local server="" user="" port="$DEFAULT_SIEVE_PORT"
		local script_name="$DEFAULT_SCRIPT_NAME"
		local sieve_file="$DEFAULT_OUTPUT_FILE"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--server)
				server="$2"
				shift 2
				;;
			--user)
				user="$2"
				shift 2
				;;
			--port)
				port="$2"
				shift 2
				;;
			--script)
				script_name="$2"
				shift 2
				;;
			--file)
				sieve_file="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if [[ -z "$server" ]]; then
			print_error "--server is required"
			return 1
		fi
		if [[ -z "$user" ]]; then
			print_error "--user is required"
			return 1
		fi
		check_dependencies || return 1
		deploy_sieve "$server" "$user" "$port" "$script_name" "$sieve_file"
		;;

	validate)
		local sieve_file="$DEFAULT_OUTPUT_FILE"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--file)
				sieve_file="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		validate_sieve "$sieve_file"
		;;

	list-scripts)
		local server="" user="" port="$DEFAULT_SIEVE_PORT"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--server)
				server="$2"
				shift 2
				;;
			--user)
				user="$2"
				shift 2
				;;
			--port)
				port="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if [[ -z "$server" ]] || [[ -z "$user" ]]; then
			print_error "--server and --user are required"
			return 1
		fi
		list_scripts "$server" "$user" "$port"
		;;

	show-script)
		local server="" user="" script_name="" port="$DEFAULT_SIEVE_PORT"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--server)
				server="$2"
				shift 2
				;;
			--user)
				user="$2"
				shift 2
				;;
			--script)
				script_name="$2"
				shift 2
				;;
			--port)
				port="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if [[ -z "$server" ]] || [[ -z "$user" ]] || [[ -z "$script_name" ]]; then
			print_error "--server, --user, and --script are required"
			return 1
		fi
		show_script "$server" "$user" "$script_name" "$port"
		;;

	delete-script)
		local server="" user="" script_name="" port="$DEFAULT_SIEVE_PORT"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--server)
				server="$2"
				shift 2
				;;
			--user)
				user="$2"
				shift 2
				;;
			--script)
				script_name="$2"
				shift 2
				;;
			--port)
				port="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if [[ -z "$server" ]] || [[ -z "$user" ]] || [[ -z "$script_name" ]]; then
			print_error "--server, --user, and --script are required"
			return 1
		fi
		delete_script "$server" "$user" "$script_name" "$port"
		;;

	add-pattern)
		local ptype="" pvalue="" pfolder="" pflags="" ppriority="50"
		local patterns_file="$DEFAULT_PATTERNS_FILE"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--type)
				ptype="$2"
				shift 2
				;;
			--value)
				pvalue="$2"
				shift 2
				;;
			--folder)
				pfolder="$2"
				shift 2
				;;
			--flags)
				pflags="$2"
				shift 2
				;;
			--priority)
				ppriority="$2"
				shift 2
				;;
			--patterns)
				patterns_file="$2"
				shift 2
				;;
			*)
				print_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if [[ -z "$ptype" ]]; then
			print_error "--type is required"
			return 1
		fi
		if [[ -z "$pfolder" ]]; then
			print_error "--folder is required"
			return 1
		fi
		check_dependencies || return 1
		add_pattern "$ptype" "$pvalue" "$pfolder" "$patterns_file" "$pflags" "$ppriority"
		;;

	status)
		show_status
		;;

	help | --help | -h)
		show_help
		;;

	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
