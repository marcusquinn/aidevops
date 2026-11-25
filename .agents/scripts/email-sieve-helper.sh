#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
readonly MANAGESIEVE_PYTHON_HELPER="${SCRIPT_DIR}/managesieve_client.py"

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
    address :matches "from" "noreply@*",
    address :matches "from" "no-reply@*",
    address :matches "from" "notifications@*",
    address :matches "from" "donotreply@*",
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

# Determine which Sieve extensions are needed and populate the requires array.
# Outputs: sets needs_fileinto and needs_flags in the caller's scope via stdout.
# Usage: eval "$(_generate_sieve_requires "$patterns_file")"
_generate_sieve_requires() {
	local patterns_file="$1"

	local needs_fileinto=0
	local needs_flags=0

	local pattern_count
	pattern_count=$(jq '.patterns | length' "$patterns_file")

	if [[ "$pattern_count" -gt 0 ]]; then
		needs_fileinto=1
		local flagged_count
		flagged_count=$(jq '[.patterns[] | select(.flags != "")] | length' "$patterns_file")
		if [[ "$flagged_count" -gt 0 ]]; then
			needs_flags=1
		fi
	fi

	# Built-in rule types that always need fileinto
	local has_transaction has_list has_notification
	has_transaction=$(jq '[.patterns[] | select(.type == "transaction")] | length' "$patterns_file")
	has_list=$(jq '[.patterns[] | select(.type == "list-id")] | length' "$patterns_file")
	has_notification=$(jq '[.patterns[] | select(.type == "notification")] | length' "$patterns_file")

	if [[ "$has_transaction" -gt 0 ]] || [[ "$has_list" -gt 0 ]] || [[ "$has_notification" -gt 0 ]]; then
		needs_fileinto=1
	fi

	echo "$needs_fileinto $needs_flags"
	return 0
}

# Iterate over sorted patterns and emit Sieve rules to stdout.
_generate_sieve_rules() {
	local patterns_file="$1"

	local total
	total=$(jq '.patterns | length' "$patterns_file")

	local idx=0
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

	local pattern_count
	pattern_count=$(jq '.patterns | length' "$patterns_file")

	# Determine required Sieve extensions
	local req_result needs_fileinto needs_flags
	req_result=$(_generate_sieve_requires "$patterns_file")
	needs_fileinto=$(echo "$req_result" | cut -d' ' -f1)
	needs_flags=$(echo "$req_result" | cut -d' ' -f2)

	# Build requires array
	local requires=()
	if [[ "$needs_fileinto" -eq 1 ]]; then
		requires+=("$SIEVE_REQUIRES_FILEINTO")
	fi
	if [[ "$needs_flags" -eq 1 ]]; then
		requires+=("$SIEVE_REQUIRES_IMAP_FLAGS")
	fi

	# Write header + rules + footer to output file
	{
		# Use "${requires[@]+"${requires[@]}"}" to handle empty array under set -u (bash 3.2 compat)
		if [[ "${#requires[@]}" -gt 0 ]]; then
			generate_header "${requires[@]}"
		else
			generate_header
		fi

		_generate_sieve_rules "$patterns_file"

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
	# Use grep -c to count lines with matches; returns 0 (not exit 1) when no match found
	local open_braces close_braces
	open_braces=$(grep -o '{' "$sieve_file" 2>/dev/null | wc -l | tr -d ' \n' || true)
	close_braces=$(grep -o '}' "$sieve_file" 2>/dev/null | wc -l | tr -d ' \n' || true)
	open_braces="${open_braces:-0}"
	close_braces="${close_braces:-0}"
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

# Run only the shared client; passwords stay in its environment, never argv.
_sieve() {
	local operation="$1"
	shift
	check_deploy_dependencies || return 1
	if [[ "$secret" == "SIEVE_PASSWORD" && -n "${SIEVE_PASSWORD:-}" ]]; then
		SIEVE_HOST="$server" SIEVE_PORT="$port" python3 "$MANAGESIEVE_PYTHON_HELPER" SIEVE_PASSWORD "$user" "$operation" "$@"
	else
		SIEVE_HOST="$server" SIEVE_PORT="$port" "${SCRIPT_DIR}/secret-helper.sh" "$secret" -- \
			python3 "$MANAGESIEVE_PYTHON_HELPER" "$secret" "$user" "$operation" "$@"
	fi
	return $?
}

# ============================================================================
# Status
# ============================================================================

_sieve_copy_script() {
	local target="$1"
	printf 'require ["copy"];\n# rule:[Copy to owner]\nif true\n{\n\tredirect :copy "%s";\n}\n' "$target"
	return 0
}

_sieve_same() {
	local left="$1"
	local right="$2"
	[[ "$(tr -d '\r' <<<"$left")" == "$(tr -d '\r' <<<"$right")" ]] && return 0
	return 1
}

_sieve_copy_target() {
	local script="$1"
	local re='redirect :copy "([^"]+)";'
	[[ "$script" =~ $re ]] || return 1
	local target="${BASH_REMATCH[1]}"
	_sieve_same "$script" "$(_sieve_copy_script "$target")" || return 1
	printf '%s\n' "$target"
	return 0
}

_sieve_list_or_fail() {
	_sieve list && return 0
	print_error "ManageSieve failed for $user (needs the mailbox password or an app password with SIEVE scope)"
	return 1
}

_sieve_copy_to() {
	# Restrict addresses to characters safe inside a quoted Sieve string.
	if [[ ! "$target" =~ ^[A-Za-z0-9._%+-]+@[a-z0-9.-]+$ ]]; then
		print_error "Invalid mail address: $target"
		return 1
	fi
	local script scripts names current
	script=$(_sieve_copy_script "$target")
	if [[ "$option" == "--dry-run" ]]; then
		print_info "Would set Sieve script '$script_name' on $user and make it active:"
		printf '%s\n' "$script"
		return 0
	fi
	scripts=$(_sieve_list_or_fail) || return 1
	names=$(cut -f1 <<<"$scripts")
	if [[ -n "$scripts" && "$names" != "$script_name" ]]; then
		print_error "$user already has Sieve scripts: $(tr '\n' ' ' <<<"$names")"
		print_info "Edit them in webmail (Settings > Filters) instead; see: sieve-list $user $secret"
		return 1
	fi
	if [[ -n "$scripts" ]]; then
		current=$(_sieve get "$script_name") || return 1
		if ! _sieve_same "$current" "$script"; then
			print_error "$user has a different '$script_name' script; edit it in webmail or run copy-to-remove first"
			return 1
		fi
		if [[ "$scripts" == "${script_name}"$'\t'"active" ]]; then
			print_info "No change: $user already keeps its mail and copies to $target"
			return 0
		fi
	fi
	if ! _sieve install "$script_name" "$script"; then
		print_error "Could not set the Sieve script on $user"
		return 1
	fi
	print_success "$user keeps its mail and sends a copy to $target (script read back and active)"
	return 0
}

_sieve_copy_to_remove() {
	local scripts name _state has_main=0 has_parked=0
	local parked="${script_name}.aidevops-remove"
	scripts=$(_sieve_list_or_fail) || return 1
	while IFS=$'\t' read -r name _state; do
		[[ "$name" == "$script_name" ]] && has_main=1
		[[ "$name" == "$parked" ]] && has_parked=1
	done <<<"$scripts"
	if [[ "$has_main" -eq 0 && "$has_parked" -eq 0 ]]; then
		print_info "No '$script_name' Sieve script on $user; nothing to remove"
		return 0
	fi
	if [[ "$has_parked" -eq 1 ]]; then
		print_info "Found '$parked' left by an interrupted copy-to-remove on $user"
		_sieve_copy_remove_one "$parked" || return 1
	fi
	if [[ "$has_main" -eq 1 ]]; then
		_sieve_copy_remove_one "$script_name" || return 1
	fi
	return 0
}

_sieve_copy_remove_one() {
	local name="$1"
	local current target
	current=$(_sieve get "$name") || return 1
	if ! target=$(_sieve_copy_target "$current"); then
		print_error "The '$name' script on $user is not the helper's copy script; change it in webmail instead"
		return 1
	fi
	if [[ "$confirm" != "--yes" ]]; then
		print_info "Re-run with --yes to stop copying $user to $target"
		return 0
	fi
	if ! _sieve remove "$name" "$current"; then
		print_error "Could not remove the Sieve script '$name' on $user"
		return 1
	fi
	print_success "Removed the copy to $target from $user"
	return 0
}

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
# Argument parsers for main() sub-commands
# ============================================================================

# Parse and execute the 'generate' sub-command.
_cmd_generate() {
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
	return $?
}

# Connection settings are dynamically scoped to _sieve and copy helpers.
_cmd_remote() {
	local action="$1"
	shift
	local server="" user="" script_name="" port="$DEFAULT_SIEVE_PORT"
	local secret="SIEVE_PASSWORD" target="" option="" confirm=""
	local sieve_file="$DEFAULT_OUTPUT_FILE" current scripts
	case "$action" in
	deploy) script_name="$DEFAULT_SCRIPT_NAME" ;;
	copy-to | copy-to-remove) script_name="roundcube" ;;
	esac
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--server | --user | --script | --port | --secret | --target | --file)
			if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
				print_error "Missing value for $1"
				return 1
			fi
			;;
		esac
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
		--secret) secret="$2"; shift 2 ;;
		--target) target="$2"; shift 2 ;;
		--file) sieve_file="$2"; shift 2 ;;
		--dry-run) option="$1"; shift ;;
		--yes) confirm="$1"; shift ;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	if [[ -z "$server" || -z "$user" ]]; then
		print_error "--server and --user are required"
		return 1
	fi
	if [[ ! "$secret" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
		print_error "Invalid secret name (UPPER_SNAKE_CASE): $secret"
		return 1
	fi
	if [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
		print_error "Invalid ManageSieve port: $port"
		return 1
	fi
	if [[ "$action" != "list-scripts" && -z "$script_name" ]]; then
		print_error "--script is required"
		return 1
	fi
	if [[ -n "$option" && "$action" != "copy-to" ]] || [[ -n "$confirm" && "$action" != "copy-to-remove" ]]; then
		print_error "--dry-run is only for copy-to; --yes is only for copy-to-remove"
		return 1
	fi
	case "$action" in
	deploy)
		if [[ ! -f "$sieve_file" ]]; then
			print_error "Sieve file not found: $sieve_file"
			return 1
		fi
		current=$(<"$sieve_file")
		_sieve install "$script_name" "$current" || return $?
		print_success "Sieve script deployed and activated: $script_name"
		;;
	list-scripts)
		scripts=$(_sieve list) || return $?
		if [[ -z "$scripts" ]]; then
			print_info "No Sieve scripts on $user"
		else
			printf '%s\n' "$scripts"
		fi
		;;
	show-script) _sieve get "$script_name" || return $? ;;
	delete-script)
		current=$(_sieve get "$script_name") || return $?
		_sieve remove "$script_name" "$current" || return $?
		;;
	copy-to) _sieve_copy_to || return $? ;;
	copy-to-remove) _sieve_copy_to_remove || return $? ;;
	esac
	return $?
}

# Parse and execute the 'add-pattern' sub-command.
_cmd_add_pattern() {
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
	return $?
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	generate)
		_cmd_generate "$@"
		;;
	deploy | list-scripts | show-script | delete-script | copy-to | copy-to-remove)
		_cmd_remote "$command" "$@"
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
	add-pattern)
		_cmd_add_pattern "$@"
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
