#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

# Email Signature Parser Helper for AI DevOps Framework
# Detects email signature blocks and extracts contact information into TOON records.
#
# Strategy: Rule-based regex extraction first, LLM fallback for messy signatures.
# Output: contacts/{email-address}.toon files with contact schema.
#
# TOON schema: contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence}
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_CONTACTS_DIR="contacts"
readonly TOON_SCHEMA="contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence}"

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
	# International formats: +1 (555) 123-4567, +44 20 7946 0958, etc.
	# Also: (555) 123-4567, 555-123-4567, 555.123.4567
	echo "$text" | grep -oE '(\+?[0-9]{1,3}[-. ]?)?\(?[0-9]{2,4}\)?[-. ]?[0-9]{3,4}[-. ]?[0-9]{3,4}' |
		grep -E '[0-9]{7,}' |
		head -3 || true
	return 0
}

# Extract URLs/websites from text
extract_websites() {
	local text="$1"
	# Match http(s) URLs and www. prefixed domains
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
		# Skip empty lines
		[[ -z "${line// /}" ]] && continue
		# Skip delimiter lines
		[[ "$line" =~ ^[-_=]{2,}$ ]] && continue
		# Skip lines that are greetings/closings
		[[ "$line" =~ ^(Best|Kind|Warm|Regards|Sincerely|Cheers|Thanks|Thank|Many|All|With|Yours|Sent|Get) ]] && continue
		# Skip lines with email addresses
		[[ "$line" =~ @ ]] && continue
		# Skip lines with phone numbers (start with + or contain mostly digits)
		[[ "$line" =~ $phone_re ]] && continue
		# Skip lines with URLs
		[[ "$line" =~ ^(http|www\.) ]] && continue
		# Skip lines that are just labels
		[[ "$line" =~ $label_re ]] && continue

		# A name line typically has 2-5 words, mostly alphabetic
		local word_count
		word_count=$(echo "$line" | wc -w | tr -d ' ')
		if [[ "$word_count" -ge 1 && "$word_count" -le 6 ]]; then
			# Check the line is mostly alphabetic (allow periods, hyphens)
			local alpha_ratio
			local alpha_chars
			local total_chars
			alpha_chars=$(echo "$line" | tr -cd 'a-zA-Z .\-' | wc -c | tr -d ' ')
			total_chars=$(echo "$line" | wc -c | tr -d ' ')
			if [[ "$total_chars" -gt 0 ]]; then
				alpha_ratio=$((alpha_chars * 100 / total_chars))
				if [[ "$alpha_ratio" -ge 70 ]]; then
					echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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
				echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
				return 0
			fi
			break
		fi
		# Trim and compare to name
		local trimmed
		trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		if [[ "$trimmed" == "$name" ]]; then
			found_name=true
		fi
	done <<<"$sig_block"

	# Strategy 2: look for common title keywords
	local title_keywords='(CEO|CTO|CFO|COO|CMO|CIO|CISO|VP|SVP|EVP|Director|Manager|Engineer|Developer|Architect|Designer|Analyst|Consultant|Specialist|Coordinator|Administrator|Lead|Head|Chief|President|Founder|Co-Founder|Partner|Associate|Senior|Junior|Principal|Staff)'
	while IFS= read -r line; do
		local trimmed
		trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
					echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
					return 0
				fi
				break
			fi
			local trimmed
			trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			if [[ "$trimmed" == "$title" ]]; then
				found_title=true
			fi
		done <<<"$sig_block"
	fi

	# Strategy 2: look for company indicators
	local company_keywords='(Inc\.|LLC|Ltd\.|Corp\.|Corporation|Company|Co\.|Group|Holdings|Technologies|Solutions|Services|Consulting|Partners|Associates|GmbH|AG|S\.A\.|B\.V\.|Pty|PLC|LLP)'
	while IFS= read -r line; do
		local trimmed
		trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
		trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[[ -z "$trimmed" ]] && continue

		# Remove common labels
		trimmed=$(echo "$trimmed" | sed -E 's/^(Address|Office|Location|Addr)[[:space:]]*:[[:space:]]*//')

		# Match address patterns:
		# - Street numbers: 123 Main St
		# - PO Box
		# - Zip/postal codes: 12345, 12345-6789, SW1A 1AA
		# - State abbreviations with zip: CA 90210
		# - City, State patterns
		if echo "$trimmed" | grep -qEi '([0-9]+[[:space:]]+(Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Way|Court|Ct|Place|Pl|Suite|Ste|Floor|Fl)|P\.?O\.?\s*Box|[0-9]{5}(-[0-9]{4})?|[A-Z]{1,2}[0-9][A-Z0-9]?\s*[0-9][A-Z]{2})'; then
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
# TOON Output Generation
# =============================================================================

# Generate a TOON contact record from extracted fields.
# Args: email name title company phone website address source confidence
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

	cat <<EOF
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
EOF
	return 0
}

# Merge a new contact record into an existing TOON file.
# If the file exists, updates last_seen and merges non-empty fields.
# If the file has a different primary email, adds the new email as additional.
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

	if [[ ! -f "$toon_file" ]]; then
		generate_toon_record "$email" "$name" "$title" "$company" "$phone" "$website" "$address" "$source" "$confidence" >"$toon_file"
		return 0
	fi

	# File exists — update last_seen and merge non-empty fields
	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local existing
	existing=$(cat "$toon_file")

	# Update last_seen
	existing=$(echo "$existing" | sed "s/last_seen: .*/last_seen: ${now}/")

	# Merge fields: only overwrite if existing field is empty and new value is non-empty
	local field_name new_val existing_val
	local -A field_map=(
		[name]="$name"
		[title]="$title"
		[company]="$company"
		[phone]="$phone"
		[website]="$website"
		[address]="$address"
	)
	for field_name in name title company phone website address; do
		new_val="${field_map[$field_name]}"
		[[ -z "$new_val" ]] && continue

		existing_val=$(echo "$existing" | grep -E "^  ${field_name}: " | sed "s/^  ${field_name}: //" || true)
		if [[ -z "$existing_val" ]]; then
			existing=$(echo "$existing" | sed "s/^  ${field_name}: $/  ${field_name}: ${new_val}/")
		fi
	done

	# Upgrade confidence if new is higher
	local existing_conf
	existing_conf=$(echo "$existing" | grep -E "^  confidence: " | sed "s/^  confidence: //" || true)
	if [[ "$confidence" == "high" && "$existing_conf" != "high" ]]; then
		existing=$(echo "$existing" | sed "s/confidence: .*/confidence: ${confidence}/")
	fi

	echo "$existing" >"$toon_file"
	return 0
}

# =============================================================================
# LLM Fallback Extraction
# =============================================================================

# Use LLM to extract contact fields from a messy signature block.
# Requires: Anthropic API key or Claude CLI available.
# Returns extracted fields as key=value pairs on stdout.
llm_extract_signature() {
	local sig_block="$1"
	local result=""

	# Check for Claude CLI (headless subagent)
	if command -v claude &>/dev/null; then
		result=$(claude -p "Extract contact information from this email signature. Return ONLY key=value pairs, one per line, for these fields: name, title, company, phone, email, website, address. If a field is not found, omit it. No explanations, no markdown.

Signature:
${sig_block}" 2>/dev/null) || true
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
# Main Parse Pipeline
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

	# Create contacts directory
	mkdir -p "$contacts_dir"

	# Extract signature block
	local sig_block
	sig_block=$(extract_signature_block "$email_text")

	# Rule-based extraction
	local emails_raw phones_raw websites_raw
	local name="" title="" company="" phone="" website="" address=""

	emails_raw=$(extract_emails "$sig_block")
	phones_raw=$(extract_phones "$sig_block")
	websites_raw=$(extract_websites "$sig_block")
	name=$(extract_name "$sig_block" 2>/dev/null) || true
	phone=$(echo "$phones_raw" | head -1)
	website=$(echo "$websites_raw" | head -1)
	address=$(extract_address "$sig_block" 2>/dev/null) || true

	# Extract title and company (depend on name)
	if [[ -n "$name" ]]; then
		title=$(extract_title "$sig_block" "$name" 2>/dev/null) || true
		company=$(extract_company "$sig_block" "$name" "$title" 2>/dev/null) || true
	fi

	# Determine confidence based on how many fields we extracted
	local field_count=0
	[[ -n "$name" ]] && field_count=$((field_count + 1))
	[[ -n "$title" ]] && field_count=$((field_count + 1))
	[[ -n "$company" ]] && field_count=$((field_count + 1))
	[[ -n "$phone" ]] && field_count=$((field_count + 1))
	[[ -n "$website" ]] && field_count=$((field_count + 1))
	[[ -n "$address" ]] && field_count=$((field_count + 1))

	local confidence="high"
	if [[ "$field_count" -le 1 ]]; then
		confidence="low"
	elif [[ "$field_count" -le 3 ]]; then
		confidence="medium"
	fi

	# LLM fallback if regex extraction was poor
	local used_llm=false
	if [[ "$confidence" == "low" || -z "$emails_raw" ]]; then
		print_info "Low confidence from regex — attempting LLM extraction..."
		local llm_output
		if llm_output=$(llm_extract_signature "$sig_block"); then
			parse_llm_output "$llm_output"
			used_llm=true

			# Fill in missing fields from LLM
			[[ -z "$name" && -n "$LLM_NAME" ]] && name="$LLM_NAME"
			[[ -z "$title" && -n "$LLM_TITLE" ]] && title="$LLM_TITLE"
			[[ -z "$company" && -n "$LLM_COMPANY" ]] && company="$LLM_COMPANY"
			[[ -z "$phone" && -n "$LLM_PHONE" ]] && phone="$LLM_PHONE"
			[[ -z "$website" && -n "$LLM_WEBSITE" ]] && website="$LLM_WEBSITE"
			[[ -z "$address" && -n "$LLM_ADDRESS" ]] && address="$LLM_ADDRESS"

			# Add LLM-discovered emails
			if [[ -n "$LLM_EMAIL" ]]; then
				emails_raw=$(printf '%s\n%s' "$emails_raw" "$LLM_EMAIL" | sort -uf | grep -v '^$' || true)
			fi

			# Recalculate confidence
			field_count=0
			[[ -n "$name" ]] && field_count=$((field_count + 1))
			[[ -n "$title" ]] && field_count=$((field_count + 1))
			[[ -n "$company" ]] && field_count=$((field_count + 1))
			[[ -n "$phone" ]] && field_count=$((field_count + 1))
			[[ -n "$website" ]] && field_count=$((field_count + 1))
			[[ -n "$address" ]] && field_count=$((field_count + 1))

			if [[ "$field_count" -le 1 ]]; then
				confidence="low"
			elif [[ "$field_count" -le 3 ]]; then
				confidence="medium"
			else
				confidence="high"
			fi

			# Downgrade slightly since LLM was needed
			if [[ "$confidence" == "high" ]]; then
				confidence="medium"
			fi
		fi
	fi

	# Check we have at least one email
	if [[ -z "$emails_raw" ]]; then
		print_warning "No email addresses found in signature"
		return 1
	fi

	# Determine the source label
	if [[ "$used_llm" == true ]]; then
		source_label="${source_label}+llm"
	fi

	# Save contact records — one file per email, all emails for same person in same file
	local primary_email
	primary_email=$(echo "$emails_raw" | head -1)
	local safe_filename
	safe_filename=$(echo "$primary_email" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9@._-]/_/g')
	local toon_file="${contacts_dir}/${safe_filename}.toon"

	merge_toon_contact "$toon_file" "$primary_email" "$name" "$title" "$company" "$phone" "$website" "$address" "$source_label" "$confidence"

	# If multiple emails, add additional emails as a list in the file
	local email_count
	email_count=$(echo "$emails_raw" | wc -l | tr -d ' ')
	if [[ "$email_count" -gt 1 ]]; then
		local additional_emails
		additional_emails=$(echo "$emails_raw" | tail -n +2)
		# Append additional_emails section if not already present
		if ! grep -q "additional_emails" "$toon_file" 2>/dev/null; then
			{
				echo "  additional_emails[$((email_count - 1))]:"
				while IFS= read -r extra_email; do
					echo "    - ${extra_email}"
				done <<<"$additional_emails"
			} >>"$toon_file"
		fi
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

	echo "$toon_file"
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
		email=$(grep -E "^  email: " "$toon_file" | head -1 | sed 's/^  email: //')
		name=$(grep -E "^  name: " "$toon_file" | head -1 | sed 's/^  name: //')
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
  contact{email,name,title,company,phone,website,address,source,first_seen,last_seen,confidence}

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
  4. Save to contacts/{email-address}.toon
  5. Multiple emails per person merged into same file
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
