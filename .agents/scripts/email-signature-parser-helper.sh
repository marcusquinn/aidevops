#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Email Signature Parser Helper for AI DevOps Framework
# Detects email signature blocks and extracts contact information into TOON records.
#
# Strategy: Rule-based regex extraction first, LLM fallback for messy signatures.
# Output: contacts/{email-address}.toon files with contact schema.
#
# TOON schema: contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence,history}
#
# t1044.4 enhancements:
# - Contact deduplication: check if contact file exists before creating
# - Field change detection: compare old vs new values, append to history[]
# - Name collision handling: append -001, -002 to filename if different emails share same name
# - Cross-reference: track all email addresses a person has used
#
# Author: AI DevOps Framework
# Version: 1.1.0 (t1044.4)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_CONTACTS_DIR="contacts"
readonly TOON_SCHEMA="contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence,history}"

# Trim leading and trailing whitespace using parameter expansion (avoids sed/SC2001).
# Usage: trimmed=$(trim_whitespace "$string")
trim_whitespace() {
	local str="$1"
	str="${str#"${str%%[![:space:]]*}"}"
	str="${str%"${str##*[![:space:]]}"}"
	printf '%s' "$str"
	return 0
}

# Signature delimiter patterns (order matters — most specific first)
# These mark the beginning of a signature block
readonly -a SIG_DELIMITERS=(
	'^-- $'                                             # RFC 2646 standard sig delimiter
	'^--$'                                              # Common variant (no trailing space)
	'^---+$'                                            # Dashes separator
	'^_{3,}$'                                           # Underscores separator
	'^={3,}$'                                           # Equals separator
	'^Best [Rr]egards'                                  # Best regards / Best Regards
	'^Kind [Rr]egards'                                  # Kind regards / Kind Regards
	'^Warm [Rr]egards'                                  # Warm regards
	'^Regards,'                                         # Regards,
	'^Sincerely,'                                       # Sincerely,
	'^Cheers,'                                          # Cheers,
	'^Thanks,'                                          # Thanks,
	'^Thank you,'                                       # Thank you,
	'^Many thanks'                                      # Many thanks
	'^All the best'                                     # All the best
	'^With appreciation'                                # With appreciation
	'^Yours (sincerely|truly|faithfully)'               # Formal closings
	'^Sent from my (iPhone|iPad|Android|Samsung|Pixel)' # Mobile signatures
	'^Get Outlook for'                                  # Outlook mobile
)

# =============================================================================
# Signature Detection
# =============================================================================

# Find the signature block start line in email text.
# Reads from stdin, prints the line number (1-based) where signature begins.
# Returns 1 if no signature detected.
find_signature_start() {
	local line_num=0
	local sig_start=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		for pattern in "${SIG_DELIMITERS[@]}"; do
			if [[ "$line" =~ $pattern ]]; then
				sig_start=$line_num
				break 2
			fi
		done
	done

	if [[ "$sig_start" -eq 0 ]]; then
		return 1
	fi

	echo "$sig_start"
	return 0
}

# Extract the signature block from email text.
# Reads from stdin, prints the signature portion.
extract_signature_block() {
	local input="$1"
	local sig_start

	sig_start=$(echo "$input" | find_signature_start) || {
		# No delimiter found — try last 10 lines as heuristic
		local total_lines
		total_lines=$(echo "$input" | wc -l | tr -d ' ')
		if [[ "$total_lines" -gt 10 ]]; then
			sig_start=$((total_lines - 9))
		else
			sig_start=1
		fi
	}

	echo "$input" | tail -n +"$sig_start"
	return 0
}

# =============================================================================
# Field Extraction (Rule-Based Regex)
# =============================================================================

# Extract email addresses from text
extract_emails() {
	local text="$1"
	# Match standard email addresses, avoiding common false positives
	echo "$text" | grep -oEi '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' |
		sort -uf || true
	return 0
}

# Extract phone numbers from text
extract_phones() {
	local text="$1"
	# Strip common labels first, then extract phone-like patterns
	# Matches: +1 (555) 123-4567, +44 20 7946 0958, (555) 123-4567, 555-123-4567
	echo "$text" | sed -E 's/^[[:space:]]*(Phone|Tel|Mobile|Cell|Fax|Office|Direct)[[:space:]]*:[[:space:]]*//' |
		grep -oE '[+]?[0-9][0-9 .()\-]{6,}[0-9]' |
		head -3 || true
	return 0
}

# Extract URLs/websites from text
extract_websites() {
	local text="$1"
	# Match http(s) URLs
	echo "$text" | grep -oEi 'https?://[a-zA-Z0-9._~:/?#\[\]@!$&'"'"'()*+,;=%-]+' |
		head -5 || true
	# Also match www. without protocol
	echo "$text" | grep -oEi 'www\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}[/a-zA-Z0-9._~:/?#\[\]@!$&'"'"'()*+,;=-]*' |
		sed 's/^/https:\/\//' |
		head -3 || true
	return 0
}

# Extract name from signature block.
# Heuristic: first non-empty, non-delimiter line that looks like a name.
extract_name() {
	local sig_block="$1"
	local line
	local phone_re='^[+]?[0-9(]'
	local label_re='^(Phone|Tel|Fax|Email|E-mail|Web|Website|Address|Mobile|Cell|Office|Direct|LinkedIn|Twitter|Facebook|Instagram):?'

	while IFS= read -r line; do
		# Trim leading/trailing whitespace for comparison
		local trimmed_line
		trimmed_line="${line#"${line%%[![:space:]]*}"}"
		trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"
		# Skip empty lines
		[[ -z "$trimmed_line" ]] && continue
		# Skip delimiter lines (dashes, underscores, equals — with optional trailing space)
		[[ "$trimmed_line" =~ ^[-_=]{2,}$ ]] && continue
		# Skip lines that are greetings/closings
		[[ "$trimmed_line" =~ ^(Best|Kind|Warm|Regards|Sincerely|Cheers|Thanks|Thank|Many|All|With|Yours|Sent|Get) ]] && continue
		# Skip lines with email addresses
		[[ "$trimmed_line" =~ @ ]] && continue
		# Skip lines with phone numbers (start with + or contain mostly digits)
		[[ "$trimmed_line" =~ $phone_re ]] && continue
		# Skip lines with URLs
		[[ "$trimmed_line" =~ ^(http|www\.) ]] && continue
		# Skip lines that are just labels
		[[ "$trimmed_line" =~ $label_re ]] && continue

		# A name line typically has 2-5 words, mostly alphabetic
		local word_count
		word_count=$(echo "$trimmed_line" | wc -w | tr -d ' ')
		if [[ "$word_count" -ge 1 && "$word_count" -le 6 ]]; then
			# Check the line is mostly alphabetic (allow periods, hyphens)
			local alpha_ratio
			local alpha_chars
			local total_chars
			alpha_chars=$(echo "$trimmed_line" | tr -cd 'a-zA-Z .\-' | wc -c | tr -d ' ')
			total_chars=$(echo "$trimmed_line" | wc -c | tr -d ' ')
			if [[ "$total_chars" -gt 0 ]]; then
				alpha_ratio=$((alpha_chars * 100 / total_chars))
				if [[ "$alpha_ratio" -ge 70 ]]; then
					echo "$trimmed_line"
					return 0
				fi
			fi
		fi
	done <<<"$sig_block"

	return 1
}

# Extract job title from signature block.
# Heuristic: line after name, or line containing common title keywords.
extract_title() {
	local sig_block="$1"
	local name="$2"
	local found_name=false
	local line

	local phone_re='^[+]?[0-9(]'

	# Strategy 1: line immediately after the name
	while IFS= read -r line; do
		if [[ "$found_name" == true ]]; then
			# Skip empty lines right after name
			[[ -z "${line// /}" ]] && continue
			# Skip if it looks like contact info
			[[ "$line" =~ @ ]] && return 1
			[[ "$line" =~ $phone_re ]] && return 1
			[[ "$line" =~ ^(http|www\.) ]] && return 1
			[[ "$line" =~ ^(Phone|Tel|Email|Web|Address|Mobile|Cell|Office|Direct): ]] && return 1

			# Title lines are typically short (1-8 words)
			local word_count
			word_count=$(echo "$line" | wc -w | tr -d ' ')
			if [[ "$word_count" -ge 1 && "$word_count" -le 8 ]]; then
				trim_whitespace "$line"
				echo
				return 0
			fi
			break
		fi
		# Trim and compare to name
		local trimmed
		trimmed=$(trim_whitespace "$line")
		if [[ "$trimmed" == "$name" ]]; then
			found_name=true
		fi
	done <<<"$sig_block"

	# Strategy 2: look for common title keywords
	local title_keywords='(CEO|CTO|CFO|COO|CMO|CIO|CISO|VP|SVP|EVP|Director|Manager|Engineer|Developer|Architect|Designer|Analyst|Consultant|Specialist|Coordinator|Administrator|Lead|Head|Chief|President|Founder|Co-Founder|Partner|Associate|Senior|Junior|Principal|Staff)'
	while IFS= read -r line; do
		local trimmed
		trimmed=$(trim_whitespace "$line")
		[[ "$trimmed" == "$name" ]] && continue
		if echo "$trimmed" | grep -qEi "$title_keywords"; then
			# Avoid lines that are clearly not titles
			[[ "$trimmed" =~ @ ]] && continue
			[[ "$trimmed" =~ ^(http|www\.) ]] && continue
			echo "$trimmed"
			return 0
		fi
	done <<<"$sig_block"

	return 1
}

# Extract company name from signature block.
# Heuristic: line after title, or line containing company indicators.
extract_company() {
	local sig_block="$1"
	local name="$2"
	local title="$3"
	local found_title=false
	local line
	local phone_re='^[+]?[0-9(]'

	# Strategy 1: line after title (if title was found)
	if [[ -n "$title" ]]; then
		while IFS= read -r line; do
			if [[ "$found_title" == true ]]; then
				[[ -z "${line// /}" ]] && continue
				[[ "$line" =~ @ ]] && break
				[[ "$line" =~ $phone_re ]] && break
				[[ "$line" =~ ^(http|www\.) ]] && break
				[[ "$line" =~ ^(Phone|Tel|Email|Web|Address|Mobile|Cell|Office|Direct): ]] && break

				local word_count
				word_count=$(echo "$line" | wc -w | tr -d ' ')
				if [[ "$word_count" -ge 1 && "$word_count" -le 8 ]]; then
					trim_whitespace "$line"
					echo
					return 0
				fi
				break
			fi
			local trimmed
			trimmed=$(trim_whitespace "$line")
			if [[ "$trimmed" == "$title" ]]; then
				found_title=true
			fi
		done <<<"$sig_block"
	fi

	# Strategy 2: look for company indicators
	local company_keywords='(Inc\.|LLC|Ltd\.|Corp\.|Corporation|Company|Co\.|Group|Holdings|Technologies|Solutions|Services|Consulting|Partners|Associates|GmbH|AG|S\.A\.|B\.V\.|Pty|PLC|LLP)'
	while IFS= read -r line; do
		local trimmed
		trimmed=$(trim_whitespace "$line")
		[[ "$trimmed" == "$name" ]] && continue
		[[ "$trimmed" == "$title" ]] && continue
		if echo "$trimmed" | grep -qEi "$company_keywords"; then
			echo "$trimmed"
			return 0
		fi
	done <<<"$sig_block"

	return 1
}

# Extract physical address from signature block.
# Looks for lines with address patterns (street numbers, zip codes, state abbreviations).
extract_address() {
	local sig_block="$1"
	local address_lines=""
	local line

	while IFS= read -r line; do
		local trimmed
		trimmed=$(trim_whitespace "$line")
		[[ -z "$trimmed" ]] && continue

		# Remove common labels (regex alternation — sed is appropriate here)
		trimmed=$(echo "$trimmed" | sed -E 's/^(Address|Office|Location|Addr)[[:space:]]*:[[:space:]]*//')

		# Match address patterns:
		# - Street numbers: 123 Main St
		# - PO Box
		# - Zip/postal codes: 12345, 12345-6789, SW1A 1AA
		# - State abbreviations with zip: CA 90210
		# - City, State patterns
		if echo "$trimmed" | grep -qEi '([0-9]+[[:space:]]+[a-zA-Z]+.*(Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Way|Court|Ct|Place|Pl|Suite|Ste|Floor|Fl)|P\.?O\.?[[:space:]]*Box|[0-9]{5}(-[0-9]{4})?|[A-Z]{1,2}[0-9][A-Z0-9]?[[:space:]]*[0-9][A-Z]{2})'; then
			if [[ -n "$address_lines" ]]; then
				address_lines="${address_lines}, ${trimmed}"
			else
				address_lines="$trimmed"
			fi
		fi
	done <<<"$sig_block"

	if [[ -n "$address_lines" ]]; then
		echo "$address_lines"
		return 0
	fi

	return 1
}

# =============================================================================
# TOON Generation and Merging (t1044.4 Enhanced)
# =============================================================================

# Emit a YAML history entry if a field value changed.
# Args: field_name new_val old_val source now
# Prints a history block to stdout when new_val differs from old_val (and old_val is non-empty).
# Returns:
#   0 — field changed (caller should update the record)
#   1 — field is new/empty (caller should fill it)
#   2 — no change (caller should skip)
_emit_history_entry() {
	local field_name="$1"
	local new_val="$2"
	local old_val="$3"
	local source="$4"
	local now="$5"

	# Skip if new value is empty
	if [[ -z "$new_val" ]]; then
		return 2
	fi

	if [[ -n "$old_val" && "$new_val" != "$old_val" ]]; then
		printf '    - date: %s\n      field: %s\n      old: %s\n      new: %s\n      source: %s\n' \
			"$now" "$field_name" "$old_val" "$new_val" "$source"
		return 0
	elif [[ -z "$old_val" ]]; then
		return 1
	fi

	return 2
}

# Generate a new TOON contact record
generate_toon_record() {
	local email="$1"
	local name="${2:-}"
	local title="${3:-}"
	local company="${4:-}"
	local phone="${5:-}"
	local website="${6:-}"
	local address="${7:-}"
	local source="${8:-email-signature}"
	local confidence="${9:-high}"

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	cat <<TOON
contact:
  email: ${email}
  name: ${name}
  title: ${title}
  company: ${company}
  phone: ${phone}
  website: ${website}
  address: ${address}
  source: ${source}
  first_seen: ${now}
  last_seen: ${now}
  confidence: ${confidence}
TOON
}

# t1044.4: Enhanced merge with field change detection and history tracking
# Merge a new contact record into an existing TOON file.
# If the file exists:
#   - Updates last_seen
#   - Detects field changes (title, company, phone)
#   - Appends to history[] section with date/field/old/new/source
#   - Merges non-empty fields
# If the file doesn't exist, creates a new record.
merge_toon_contact() {
	local toon_file="$1"
	local email="$2"
	local name="${3:-}"
	local title="${4:-}"
	local company="${5:-}"
	local phone="${6:-}"
	local website="${7:-}"
	local address="${8:-}"
	local source="${9:-email-signature}"
	local confidence="${10:-high}"

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# If file doesn't exist, create new record
	if [[ ! -f "$toon_file" ]]; then
		generate_toon_record "$email" "$name" "$title" "$company" "$phone" "$website" "$address" "$source" "$confidence" >"$toon_file"
		return 0
	fi

	# File exists — update last_seen and detect field changes
	local existing
	existing=$(cat "$toon_file")
	existing=$(_merge_update_fields "$existing" "$name" "$title" "$company" "$phone" "$website" "$address" "$source" "$confidence" "$now")

	echo "$existing" >"$toon_file"
	return 0
}

# Extract existing field values, apply updates, build history, and return the updated record.
# Args: existing name title company phone website address source confidence now
# Prints the updated TOON record to stdout.
_merge_update_fields() {
	local existing="$1"
	local name="$2"
	local title="$3"
	local company="$4"
	local phone="$5"
	local website="$6"
	local address="$7"
	local source="$8"
	local confidence="$9"
	local now="${10}"

	# Extract existing field values in a single pass (avoids repeated grep per field)
	local existing_name="" existing_title="" existing_company=""
	local existing_phone="" existing_website="" existing_address=""
	while IFS= read -r _line; do
		case "$_line" in
		"  name: "*) existing_name="${_line#  name: }" ;;
		"  title: "*) existing_title="${_line#  title: }" ;;
		"  company: "*) existing_company="${_line#  company: }" ;;
		"  phone: "*) existing_phone="${_line#  phone: }" ;;
		"  website: "*) existing_website="${_line#  website: }" ;;
		"  address: "*) existing_address="${_line#  address: }" ;;
		esac
	done <<<"$existing"

	# Update last_seen
	existing=$(sed "s/^  last_seen: .*/  last_seen: ${now}/" <<<"$existing")

	# Process each field: emit history entry and update record as needed
	local history_entries=""
	local entry rc field_name new_val old_val

	for _spec in \
		"name|${name}|${existing_name}" \
		"title|${title}|${existing_title}" \
		"company|${company}|${existing_company}" \
		"phone|${phone}|${existing_phone}" \
		"website|${website}|${existing_website}" \
		"address|${address}|${existing_address}"; do
		field_name="${_spec%%|*}"
		new_val="${_spec#*|}"
		new_val="${new_val%|*}"
		old_val="${_spec##*|}"

		entry=$(_emit_history_entry "$field_name" "$new_val" "$old_val" "$source" "$now") || rc=$?
		rc=${rc:-0}

		if [[ "$rc" -eq 0 ]]; then
			# Field changed — record history and update value
			history_entries="${history_entries}${entry}
"
			existing=$(sed "s|^  ${field_name}: .*|  ${field_name}: ${new_val}|" <<<"$existing")
		elif [[ "$rc" -eq 1 ]]; then
			# Field was empty — fill it
			existing=$(sed "s|^  ${field_name}: $|  ${field_name}: ${new_val}|" <<<"$existing")
		fi
		rc=0
	done

	# Append history entries if any changes detected
	if [[ -n "$history_entries" ]]; then
		if ! echo "$existing" | grep -q "^  history:"; then
			existing="${existing}
  history:
${history_entries}"
		else
			existing="${existing}
${history_entries}"
		fi
	fi

	# Upgrade confidence if new is higher
	local existing_conf _field_line
	_field_line=$(echo "$existing" | grep -E "^  confidence: " || true)
	existing_conf="${_field_line#  confidence: }"
	if [[ "$confidence" == "high" && "$existing_conf" != "high" ]]; then
		existing=$(sed "s/^  confidence: .*/  confidence: ${confidence}/" <<<"$existing")
	fi

	printf '%s' "$existing"
	return 0
}

# t1044.4: Handle name collisions
# If two different email addresses share the same name, append -001, -002 to the filename.
# Returns the safe filename to use.
resolve_contact_filename() {
	local contacts_dir="$1"
	local email="$2"
	local name="$3"

	# Default: use email as filename
	local safe_email
	safe_email=$(echo "$email" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9@._-]/_/g')
	local base_file="${contacts_dir}/${safe_email}.toon"
	local file
	local existing_email
	local existing_name

	# If this contact already exists (base or suffixed), reuse that file.
	for file in "${contacts_dir}/${safe_email}"*.toon; do
		if [[ ! -f "$file" ]]; then
			continue
		fi

		existing_email=$(grep -m1 "^  email: " "$file" | sed 's/^  email: //')
		if [[ "$existing_email" == "$email" ]]; then
			echo "$file"
			return 0
		fi
	done

	# Different email but same name = name collision.
	# Scan all contacts, not just the base filename, so collisions are detected
	# even when this email has not been seen before.
	if [[ -n "$name" ]]; then
		local name_lower existing_name_lower
		name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

		for file in "$contacts_dir"/*.toon; do
			if [[ ! -f "$file" ]]; then
				continue
			fi

			existing_name=$(grep -m1 "^  name: " "$file" | sed 's/^  name: //')
			existing_email=$(grep -m1 "^  email: " "$file" | sed 's/^  email: //')
			existing_name_lower=$(echo "$existing_name" | tr '[:upper:]' '[:lower:]')

			if [[ -n "$existing_name" && "$existing_name_lower" == "$name_lower" && "$existing_email" != "$email" ]]; then
				local suffix=1
				local collision_file
				while true; do
					collision_file="${contacts_dir}/${safe_email}-$(printf '%03d' "$suffix").toon"
					if [[ ! -f "$collision_file" ]]; then
						echo "$collision_file"
						return 0
					fi
					suffix=$((suffix + 1))
				done
			fi
		done
	fi

	# No collision, use base file
	echo "$base_file"
	return 0
}

# t1044.4: Cross-reference all email addresses a person has used
# Adds additional_emails section to the TOON file if multiple emails are found.
add_email_cross_reference() {
	local toon_file="$1"
	local new_email="$2"

	# Check if this email is already in the file
	if grep -qF "$new_email" "$toon_file" 2>/dev/null; then
		return 0
	fi

	# Add to additional_emails section
	if ! grep -q "^  additional_emails:" "$toon_file" 2>/dev/null; then
		# Create additional_emails section
		echo "  additional_emails:" >>"$toon_file"
	fi

	# Append the new email
	echo "    - ${new_email}" >>"$toon_file"
	return 0
}

# =============================================================================
# AI CLI Resolution
# =============================================================================

# Resolve the available AI CLI tool (opencode preferred, claude fallback).
# Mirrors resolve_ai_cli() from supervisor/dispatch.sh but uses print_* logging
# to avoid requiring the full supervisor stack.
# shellcheck disable=SC2120
resolve_ai_cli() {
	# Allow env var override for explicit CLI preference
	if [[ -n "${SUPERVISOR_CLI:-}" ]]; then
		if [[ "$SUPERVISOR_CLI" != "opencode" && "$SUPERVISOR_CLI" != "claude" ]]; then
			print_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' is not a supported CLI (opencode|claude)"
			return 1
		fi
		if command -v "$SUPERVISOR_CLI" &>/dev/null; then
			echo "$SUPERVISOR_CLI"
			return 0
		fi
		print_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' not found in PATH"
		return 1
	fi
	# opencode is the primary and only supported CLI
	if command -v opencode &>/dev/null; then
		echo "opencode"
		return 0
	fi
	# DEPRECATED: claude CLI fallback - will be removed
	if command -v claude &>/dev/null; then
		print_warning "Using deprecated claude CLI fallback. Install opencode: npm i -g opencode"
		echo "claude"
		return 0
	fi
	print_error "opencode CLI not found. Install it: npm i -g opencode"
	return 1
}

# =============================================================================
# LLM Fallback Extraction
# =============================================================================

# Use LLM to extract contact fields from a messy signature block.
# Requires: AI CLI (opencode/claude) or Anthropic API key.
# Returns extracted fields as key=value pairs on stdout.
llm_extract_signature() {
	local sig_block="$1"
	local result=""

	# Skip LLM if explicitly disabled
	if [[ "${EMAIL_PARSER_NO_LLM:-}" == "true" ]]; then
		print_info "LLM extraction disabled via EMAIL_PARSER_NO_LLM"
		return 1
	fi

	# Try AI CLI (opencode preferred, claude fallback)
	# timeout_sec (from shared-constants.sh) handles macOS + Linux portably
	local ai_cli=""
	ai_cli=$(resolve_ai_cli 2>/dev/null) || true

	local prompt="Extract contact information from this email signature. Return ONLY key=value pairs, one per line, for these fields: name, title, company, phone, email, website, address. If a field is not found, omit it. No explanations, no markdown.

Signature:
${sig_block}"

	if [[ -n "$ai_cli" ]]; then
		if [[ "$ai_cli" == "opencode" ]]; then
			result=$(timeout_sec 30 opencode run \
				--format default \
				--title "email-sig-parse-$$" \
				"$prompt" 2>/dev/null) || true
			# Strip ANSI escape codes from opencode output
			if [[ -n "$result" ]]; then
				result=$(printf '%s' "$result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
			fi
		else
			result=$(timeout_sec 30 claude -p "$prompt" \
				--output-format text 2>/dev/null) || true
		fi
	fi

	# Fallback: check for Anthropic API via curl
	if [[ -z "$result" ]]; then
		local api_key=""
		# Try gopass first
		if command -v gopass &>/dev/null; then
			api_key=$(gopass show -o "aidevops/anthropic-api-key" 2>/dev/null) || true
		fi
		# Try credentials file
		if [[ -z "$api_key" && -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
			api_key=$(grep -E '^ANTHROPIC_API_KEY=' "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" || true)
		fi
		# Try environment
		if [[ -z "$api_key" ]]; then
			api_key="${ANTHROPIC_API_KEY:-}"
		fi

		if [[ -n "$api_key" ]]; then
			local escaped_sig
			escaped_sig=$(printf '%s' "$sig_block" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${sig_block//\"/\\\"}\"")

			local response
			response=$(curl -sS --max-time 30 \
				-H "x-api-key: ${api_key}" \
				-H "anthropic-version: 2023-06-01" \
				-H "${CONTENT_TYPE_JSON}" \
				-d "{
                    \"model\": \"claude-haiku-4-20250414\",
                    \"max_tokens\": 300,
                    \"messages\": [{
                        \"role\": \"user\",
                        \"content\": \"Extract contact information from this email signature. Return ONLY key=value pairs, one per line, for these fields: name, title, company, phone, email, website, address. If a field is not found, omit it. No explanations, no markdown.\\n\\nSignature:\\n${escaped_sig}\"
                    }]
                }" \
				"https://api.anthropic.com/v1/messages" 2>/dev/null) || true

			if [[ -n "$response" ]]; then
				result=$(echo "$response" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data["content"][0]["text"])' 2>/dev/null) || true
			fi
		fi
	fi

	if [[ -z "$result" ]]; then
		print_warning "LLM extraction unavailable (no Claude CLI or API key)"
		return 1
	fi

	echo "$result"
	return 0
}

# Parse LLM key=value output into individual variables.
# Sets global variables: LLM_NAME, LLM_TITLE, LLM_COMPANY, LLM_PHONE, LLM_EMAIL, LLM_WEBSITE, LLM_ADDRESS
parse_llm_output() {
	local llm_output="$1"

	LLM_NAME=""
	LLM_TITLE=""
	LLM_COMPANY=""
	LLM_PHONE=""
	LLM_EMAIL=""
	LLM_WEBSITE=""
	LLM_ADDRESS=""

	local line
	while IFS= read -r line; do
		case "$line" in
		name=*) LLM_NAME="${line#name=}" ;;
		title=*) LLM_TITLE="${line#title=}" ;;
		company=*) LLM_COMPANY="${line#company=}" ;;
		phone=*) LLM_PHONE="${line#phone=}" ;;
		email=*) LLM_EMAIL="${line#email=}" ;;
		website=*) LLM_WEBSITE="${line#website=}" ;;
		address=*) LLM_ADDRESS="${line#address=}" ;;
		esac
	done <<<"$llm_output"

	return 0
}

# =============================================================================
# Main Parsing Logic — Helpers
# =============================================================================

# Calculate confidence level from a count of extracted fields.
# Args: field_count [downgrade]
# downgrade=1 caps the result at "medium" (used after LLM fallback).
# Prints: "low", "medium", or "high"
_calculate_confidence() {
	local field_count="$1"
	local downgrade="${2:-0}"
	local confidence="high"

	if [[ "$field_count" -le 1 ]]; then
		confidence="low"
	elif [[ "$field_count" -le 3 ]]; then
		confidence="medium"
	fi

	if [[ "$downgrade" -eq 1 && "$confidence" == "high" ]]; then
		confidence="medium"
	fi

	printf '%s' "$confidence"
	return 0
}

# Count non-empty fields from the six contact fields.
# Args: name title company phone website address
# Prints the integer count.
_count_fields() {
	local count=0
	local f
	for f in "$@"; do
		[[ -n "$f" ]] && count=$((count + 1))
	done
	printf '%d' "$count"
	return 0
}

# Fill missing contact fields from LLM output globals (LLM_*).
# Modifies the caller's variables via printf to stdout as KEY=VALUE lines.
# Args: name title company phone website address emails_raw
# Prints lines: NAME=... TITLE=... COMPANY=... PHONE=... WEBSITE=... ADDRESS=... EMAILS=...
_apply_llm_fields() {
	local name="$1"
	local title="$2"
	local company="$3"
	local phone="$4"
	local website="$5"
	local address="$6"
	local emails_raw="$7"

	[[ -z "$name" && -n "$LLM_NAME" ]] && name="$LLM_NAME"
	[[ -z "$title" && -n "$LLM_TITLE" ]] && title="$LLM_TITLE"
	[[ -z "$company" && -n "$LLM_COMPANY" ]] && company="$LLM_COMPANY"
	[[ -z "$phone" && -n "$LLM_PHONE" ]] && phone="$LLM_PHONE"
	[[ -z "$website" && -n "$LLM_WEBSITE" ]] && website="$LLM_WEBSITE"
	[[ -z "$address" && -n "$LLM_ADDRESS" ]] && address="$LLM_ADDRESS"

	if [[ -n "$LLM_EMAIL" ]]; then
		emails_raw=$(printf '%s\n%s' "$emails_raw" "$LLM_EMAIL" | sort -uf | grep -v '^$' || true)
	fi

	printf 'NAME=%s\nTITLE=%s\nCOMPANY=%s\nPHONE=%s\nWEBSITE=%s\nADDRESS=%s\nEMAILS=%s\n' \
		"$name" "$title" "$company" "$phone" "$website" "$address" "$emails_raw"
	return 0
}

# Save contact to TOON, cross-reference additional emails, and print summary.
# Args: contacts_dir emails_raw name title company phone website address source_label confidence used_llm
# Prints the toon_file path to stdout.
_persist_contact() {
	local contacts_dir="$1"
	local emails_raw="$2"
	local name="$3"
	local title="$4"
	local company="$5"
	local phone="$6"
	local website="$7"
	local address="$8"
	local source_label="$9"
	local confidence="${10}"
	local used_llm="${11}"

	local primary_email toon_file
	primary_email=$(printf '%s' "$emails_raw" | head -1)
	toon_file=$(resolve_contact_filename "$contacts_dir" "$primary_email" "$name")

	merge_toon_contact "$toon_file" "$primary_email" "$name" "$title" "$company" \
		"$phone" "$website" "$address" "$source_label" "$confidence"

	# Cross-reference additional emails
	local email_count additional_email
	email_count=$(echo "$emails_raw" | wc -l | tr -d ' ')
	if [[ "$email_count" -gt 1 ]]; then
		while IFS= read -r additional_email; do
			[[ "$additional_email" == "$primary_email" ]] && continue
			add_email_cross_reference "$toon_file" "$additional_email"
		done <<<"$emails_raw"
	fi

	print_success "Contact saved: ${toon_file}"
	print_info "  Name: ${name:-<not found>}"
	print_info "  Title: ${title:-<not found>}"
	print_info "  Company: ${company:-<not found>}"
	print_info "  Email: ${primary_email}"
	print_info "  Phone: ${phone:-<not found>}"
	print_info "  Website: ${website:-<not found>}"
	print_info "  Address: ${address:-<not found>}"
	print_info "  Confidence: ${confidence}"
	[[ "$used_llm" == true ]] && print_info "  LLM fallback: yes"

	printf '%s' "$toon_file"
	return 0
}

# =============================================================================
# Main Parsing Logic
# =============================================================================

# Parse an email (text or file) and extract contact info to TOON.
# Args: input_source [contacts_dir] [source_label]
# input_source: file path or "-" for stdin
parse_email_signature() {
	local input_source="$1"
	local contacts_dir="${2:-$DEFAULT_CONTACTS_DIR}"
	local source_label="${3:-email-signature}"
	local email_text=""

	# Read input
	if [[ "$input_source" == "-" ]]; then
		email_text=$(cat)
	elif [[ -f "$input_source" ]]; then
		email_text=$(cat "$input_source")
	else
		print_error "Input not found: $input_source"
		return 1
	fi

	if [[ -z "$email_text" ]]; then
		print_error "Empty input"
		return 1
	fi

	mkdir -p "$contacts_dir"

	# Extract signature block
	local sig_block
	sig_block=$(extract_signature_block "$email_text")
	if [[ -z "$sig_block" ]]; then
		print_warning "No signature block detected"
		return 1
	fi

	# Rule-based field extraction
	local emails_raw phones_raw websites_raw
	local name="" title="" company="" phone="" website="" address=""

	emails_raw=$(extract_emails "$sig_block")
	phones_raw=$(extract_phones "$sig_block")
	websites_raw=$(extract_websites "$sig_block")
	name=$(extract_name "$sig_block" 2>/dev/null) || true
	phone=$(printf '%s' "$phones_raw" | head -1)
	website=$(printf '%s' "$websites_raw" | head -1)
	address=$(extract_address "$sig_block" 2>/dev/null) || true

	if [[ -n "$name" ]]; then
		title=$(extract_title "$sig_block" "$name" 2>/dev/null) || true
		company=$(extract_company "$sig_block" "$name" "$title" 2>/dev/null) || true
	fi

	local field_count confidence
	field_count=$(_count_fields "$name" "$title" "$company" "$phone" "$website" "$address")
	confidence=$(_calculate_confidence "$field_count")

	# LLM fallback if regex extraction was poor
	local used_llm=false
	if [[ "$confidence" == "low" || -z "$emails_raw" ]]; then
		print_info "Low confidence from regex — attempting LLM extraction..."
		local llm_output llm_fields
		if llm_output=$(llm_extract_signature "$sig_block"); then
			parse_llm_output "$llm_output"
			used_llm=true

			llm_fields=$(_apply_llm_fields "$name" "$title" "$company" "$phone" "$website" "$address" "$emails_raw")
			name=$(printf '%s' "$llm_fields" | grep '^NAME=' | cut -d= -f2-)
			title=$(printf '%s' "$llm_fields" | grep '^TITLE=' | cut -d= -f2-)
			company=$(printf '%s' "$llm_fields" | grep '^COMPANY=' | cut -d= -f2-)
			phone=$(printf '%s' "$llm_fields" | grep '^PHONE=' | cut -d= -f2-)
			website=$(printf '%s' "$llm_fields" | grep '^WEBSITE=' | cut -d= -f2-)
			address=$(printf '%s' "$llm_fields" | grep '^ADDRESS=' | cut -d= -f2-)
			emails_raw=$(printf '%s' "$llm_fields" | grep '^EMAILS=' | cut -d= -f2-)

			field_count=$(_count_fields "$name" "$title" "$company" "$phone" "$website" "$address")
			confidence=$(_calculate_confidence "$field_count" 1)
		fi
	fi

	if [[ -z "$emails_raw" ]]; then
		print_warning "No email addresses found in signature"
		return 1
	fi

	[[ "$used_llm" == true ]] && source_label="${source_label}+llm"

	local toon_file
	toon_file=$(_persist_contact "$contacts_dir" "$emails_raw" "$name" "$title" "$company" \
		"$phone" "$website" "$address" "$source_label" "$confidence" "$used_llm")

	printf '%s\n' "$toon_file"
	return 0
}

# =============================================================================
# Batch Processing
# =============================================================================

# Parse all email files in a directory.
# Args: input_dir [contacts_dir] [file_pattern]
batch_parse() {
	local input_dir="$1"
	local contacts_dir="${2:-$DEFAULT_CONTACTS_DIR}"
	local file_pattern="${3:-*.eml}"

	if [[ ! -d "$input_dir" ]]; then
		print_error "Input directory not found: $input_dir"
		return 1
	fi

	mkdir -p "$contacts_dir"

	local count=0
	local success=0
	local failed=0

	while IFS= read -r -d '' file; do
		count=$((count + 1))
		print_info "Processing: $(basename "$file")"
		if parse_email_signature "$file" "$contacts_dir" "email-signature:$(basename "$file")"; then
			success=$((success + 1))
		else
			failed=$((failed + 1))
			print_warning "Failed to parse: $(basename "$file")"
		fi
	done < <(find "$input_dir" -name "$file_pattern" -type f -print0 2>/dev/null)

	print_info "Batch complete: ${success}/${count} parsed, ${failed} failed"
	return 0
}

# =============================================================================
# Utility Commands
# =============================================================================

# List all contacts in the contacts directory
list_contacts() {
	local contacts_dir="${1:-$DEFAULT_CONTACTS_DIR}"

	if [[ ! -d "$contacts_dir" ]]; then
		print_info "No contacts directory found: $contacts_dir"
		return 0
	fi

	local count=0
	while IFS= read -r -d '' toon_file; do
		count=$((count + 1))
		local email name
		email=""
		name=""
		while IFS= read -r _line; do
			case "$_line" in
			"  email: "*) email="${_line#  email: }" ;;
			"  name: "*) name="${_line#  name: }" ;;
			esac
		done <"$toon_file"
		printf "%-40s %s\n" "${email:-<unknown>}" "${name:-<no name>}"
	done < <(find "$contacts_dir" -name "*.toon" -type f -print0 2>/dev/null | sort -z)

	print_info "Total contacts: ${count}"
	return 0
}

# Show a single contact record
show_contact() {
	local contacts_dir="${1:-$DEFAULT_CONTACTS_DIR}"
	local search="$2"

	if [[ -z "$search" ]]; then
		print_error "Search term required (email or name)"
		return 1
	fi

	local found=false
	while IFS= read -r -d '' toon_file; do
		if grep -qi "$search" "$toon_file" 2>/dev/null; then
			echo "--- $(basename "$toon_file") ---"
			cat "$toon_file"
			echo ""
			found=true
		fi
	done < <(find "$contacts_dir" -name "*.toon" -type f -print0 2>/dev/null)

	if [[ "$found" == false ]]; then
		print_info "No contacts matching: $search"
		return 1
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
Email Signature Parser Helper - AI DevOps Framework

Usage: email-signature-parser-helper.sh <command> [options]

Commands:
  parse <file|->  [contacts_dir]    Parse email and extract contact to TOON
  batch <dir>     [contacts_dir]    Parse all emails in directory
  list            [contacts_dir]    List all saved contacts
  show <search>   [contacts_dir]    Show contact matching search term
  help                              Show this help

Options:
  file|-          Email file path, or "-" for stdin
  contacts_dir    Output directory (default: contacts/)

TOON Schema:
  contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence,history}

t1044.4 Enhancements:
  - Contact deduplication: checks if contact file exists before creating
  - Field change detection: compares old vs new values, appends to history[]
  - Name collision handling: appends -001, -002 to filename if different emails share same name
  - Cross-reference: tracks all email addresses a person has used

Examples:
  # Parse a single email file
  email-signature-parser-helper.sh parse email.txt

  # Parse from stdin
  cat email.txt | email-signature-parser-helper.sh parse -

  # Parse all .eml files in a directory
  email-signature-parser-helper.sh batch ./emails ./contacts

  # List all contacts
  email-signature-parser-helper.sh list ./contacts

  # Search for a contact
  email-signature-parser-helper.sh show "john@example.com"

Strategy:
  1. Detect signature block (after --, Best regards, etc.)
  2. Rule-based regex extraction for structured fields
  3. LLM fallback (Claude API) for messy/unstructured signatures
  4. Check if contact file exists (deduplication)
  5. Detect field changes and append to history[] section
  6. Handle name collisions with numeric suffixes
  7. Cross-reference all email addresses per person
  8. Save to contacts/{email-address}.toon
HELP
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	parse)
		local input="${1:--}"
		local contacts_dir="${2:-$DEFAULT_CONTACTS_DIR}"
		local source_label="${3:-email-signature}"
		parse_email_signature "$input" "$contacts_dir" "$source_label"
		;;
	batch)
		local input_dir="${1:-.}"
		local contacts_dir="${2:-$DEFAULT_CONTACTS_DIR}"
		local pattern="${3:-*.eml}"
		batch_parse "$input_dir" "$contacts_dir" "$pattern"
		;;
	list)
		local contacts_dir="${1:-$DEFAULT_CONTACTS_DIR}"
		list_contacts "$contacts_dir"
		;;
	show)
		local search="${1:-}"
		local contacts_dir="${2:-$DEFAULT_CONTACTS_DIR}"
		show_contact "$contacts_dir" "$search"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
