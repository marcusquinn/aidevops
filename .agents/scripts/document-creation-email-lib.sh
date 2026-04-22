#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Creation -- Email Import Sub-Library
# =============================================================================
# Batch email import (mbox splitting, per-email processing), contact
# extraction from email signatures, frontmatter parsing, and import
# summary reporting.
#
# Usage: source "${SCRIPT_DIR}/document-creation-email-lib.sh"
#
# Dependencies:
#   - document-creation-helper.sh (log_info, log_ok, log_warn, die, get_ext,
#     BLUE, RED, BOLD, NC)
#   - document-creation-convert-lib.sh (convert_eml_to_md,
#     extract_contact_from_email)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DOCUMENT_CREATION_EMAIL_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_CREATION_EMAIL_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Collection Manifest Generation (t1044.9 / t1055.9)
# ============================================================================

# Parse YAML frontmatter from a markdown file.
# Outputs key=value pairs to stdout, one per line.
# Args: markdown_file
parse_frontmatter() {
	local file="$1"
	local in_frontmatter=false
	local line_num=0

	while IFS= read -r line; do
		line_num=$((line_num + 1))
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == true ]]; then
				# End of frontmatter
				return 0
			elif [[ "$line_num" -eq 1 ]]; then
				in_frontmatter=true
				continue
			fi
		fi
		if [[ "$in_frontmatter" == true ]]; then
			# Only emit top-level scalar key: value pairs (skip lists/nested)
			if [[ "$line" =~ ^([a-z_]+):\ (.+)$ ]]; then
				printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
			fi
		fi
	done <"$file"
	return 0
}

# ============================================================================
# Import-emails command (batch email processing)
# ============================================================================

# Split an mbox file into individual .eml files
split_mbox() {
	local mbox_file="$1"
	local output_dir="$2"

	log_info "Splitting mbox file: $(basename "$mbox_file")"

	python3 - "$mbox_file" "$output_dir" <<'PYEOF'
import sys
import os
import mailbox

mbox_path = sys.argv[1]
output_dir = sys.argv[2]

os.makedirs(output_dir, exist_ok=True)

mbox = mailbox.mbox(mbox_path)
count = 0

for message in mbox:
    count += 1
    eml_path = os.path.join(output_dir, f"msg-{count:06d}.eml")
    with open(eml_path, 'wb') as f:
        f.write(message.as_bytes())

print(f"MBOX_COUNT={count}")
PYEOF

	return 0
}

# Extract sender name and email from a converted email markdown file.
# Prints "name\temail" to stdout, or exits silently if no sender found.
# Args: md_file
_contact_parse_sender() {
	local md_file="$1"

	python3 - "$md_file" <<'PYEOF'
import sys
import re

with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

from_match = re.search(r'\*\*From:\*\*\s*(.+?)(?:<(.+?)>)?$', content, re.MULTILINE)
if not from_match:
    sys.exit(0)

sender_name = (from_match.group(1) or '').strip()
sender_email = (from_match.group(2) or '').strip()

if not sender_email:
    email_in_name = re.search(r'[\w.+-]+@[\w.-]+\.\w+', sender_name)
    if email_in_name:
        sender_email = email_in_name.group(0)
        sender_name = sender_name.replace(sender_email, '').strip()

if not sender_email:
    sys.exit(0)

print(f"{sender_name}\t{sender_email}")
PYEOF

	return 0
}

# Parse signature block from email markdown and extract contact fields.
# Prints tab-separated "phone\twebsite\ttitle\tcompany" to stdout.
# Args: md_file sender_name
_contact_parse_signature() {
	local md_file="$1"
	local sender_name="$2"

	python3 - "$md_file" "$sender_name" <<'PYEOF'
import sys
import re

with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()
sender_name = sys.argv[2]

sig_patterns = [
    r'\n--\s*\n', r'\nBest regards,?\s*\n', r'\nKind regards,?\s*\n',
    r'\nRegards,?\s*\n', r'\nSincerely,?\s*\n', r'\nCheers,?\s*\n',
    r'\nThanks,?\s*\n', r'\nThank you,?\s*\n', r'\nBest,?\s*\n',
    r'\nWarm regards,?\s*\n',
]

signature = ""
for pattern in sig_patterns:
    match = re.search(pattern, content, re.IGNORECASE)
    if match:
        signature = content[match.start():]
        break

sig_lines = signature.strip().split('\n')
sig_body_lines = []
skip_header = True
for line in sig_lines:
    stripped = line.strip()
    if skip_header:
        if not stripped or re.match(
            r'^(--|Best regards|Kind regards|Regards|Sincerely|Cheers|Thanks|Thank you|Best|Warm regards),?\s*$',
            stripped, re.IGNORECASE
        ):
            continue
        if sender_name and stripped.lower() == sender_name.lower():
            continue
        skip_header = False
    sig_body_lines.append(line)
sig_body = '\n'.join(sig_body_lines)

phone_match = re.search(r'(?:(?:tel|phone|mob|cell|fax)[:\s]*)?(\+?[\d\s\-().]{7,20})', sig_body, re.IGNORECASE)
website_match = re.search(r'(?:https?://)?(?:www\.)?[\w.-]+\.\w{2,}(?:/[\w.-]*)*', sig_body, re.IGNORECASE)
title_roles = r'(?:Manager|Director|Engineer|Developer|Designer|Analyst|Consultant|Officer|Lead|Head|VP|CEO|CTO|CFO|COO|President|Founder|Partner|Architect|Coordinator|Specialist|Administrator|Supervisor|Executive|Associate|Assistant|Advisor|Strategist)'
title_match = re.search(r'^([A-Z][\w\s&,]{2,40}' + title_roles + r')\s*$', sig_body, re.MULTILINE | re.IGNORECASE)
company_match = re.search(r'(?:at|@)\s+(.+?)(?:\n|$)', sig_body, re.IGNORECASE)

phone = phone_match.group(1).strip() if phone_match else ""
website = website_match.group(0).strip() if website_match else ""
title = title_match.group(1).strip() if title_match else ""
company = company_match.group(1).strip() if company_match else ""

print(f"{phone}\t{website}\t{title}\t{company}")
PYEOF

	return 0
}

# Write or update a TOON contact record file.
# Args: contacts_dir sender_email sender_name phone website title company
_contact_write_toon() {
	local contacts_dir="$1"
	local sender_email="$2"
	local sender_name="$3"
	local phone="$4"
	local website="$5"
	local title="$6"
	local company="$7"

	python3 - "$contacts_dir" "$sender_email" "$sender_name" \
		"$phone" "$website" "$title" "$company" <<'PYEOF'
import sys
import os
import re
from datetime import datetime

contacts_dir = sys.argv[1]
sender_email = sys.argv[2]
sender_name = sys.argv[3]
phone = sys.argv[4]
website = sys.argv[5]
title = sys.argv[6]
company = sys.argv[7]

os.makedirs(contacts_dir, exist_ok=True)

email_safe = sender_email.replace('@', '-at-').replace('.', '-')
toon_file = os.path.join(contacts_dir, f"{email_safe}.toon")
now = datetime.now().strftime('%Y-%m-%dT%H:%M:%S')

if os.path.exists(toon_file):
    with open(toon_file, 'r', encoding='utf-8') as f:
        existing = f.read()
    existing = re.sub(r'last_seen\t[^\n]+', f'last_seen\t{now}', existing)
    with open(toon_file, 'w', encoding='utf-8') as f:
        f.write(existing)
else:
    with open(toon_file, 'w', encoding='utf-8') as f:
        f.write("contact\n")
        f.write(f"\temail\t{sender_email}\n")
        f.write(f"\tname\t{sender_name}\n")
        if title:
            f.write(f"\ttitle\t{title}\n")
        if company:
            f.write(f"\tcompany\t{company}\n")
        if phone:
            f.write(f"\tphone\t{phone}\n")
        if website:
            f.write(f"\twebsite\t{website}\n")
        f.write(f"\tsource\temail-import\n")
        f.write(f"\tfirst_seen\t{now}\n")
        f.write(f"\tlast_seen\t{now}\n")
        f.write(f"\tconfidence\tlow\n")
PYEOF

	return 0
}

# Python implementation: parse signature and write/update a TOON contact record.
# Orchestrates _contact_parse_sender, _contact_parse_signature, _contact_write_toon.
# Args: md_file contacts_dir
_extract_contact_python() {
	local md_file="$1"
	local contacts_dir="$2"

	# Step 1: extract sender name and email
	local sender_info
	sender_info=$(_contact_parse_sender "$md_file") || return 0
	if [[ -z "$sender_info" ]]; then
		return 0
	fi
	local sender_name
	sender_name=$(printf '%s' "$sender_info" | cut -f1)
	local sender_email
	sender_email=$(printf '%s' "$sender_info" | cut -f2)

	# Step 2: parse signature for contact fields
	local sig_fields
	sig_fields=$(_contact_parse_signature "$md_file" "$sender_name") || true
	local phone website title company
	phone=$(printf '%s' "$sig_fields" | cut -f1)
	website=$(printf '%s' "$sig_fields" | cut -f2)
	title=$(printf '%s' "$sig_fields" | cut -f3)
	company=$(printf '%s' "$sig_fields" | cut -f4)

	# Step 3: write/update TOON contact record
	_contact_write_toon "$contacts_dir" "$sender_email" "$sender_name" \
		"$phone" "$website" "$title" "$company"

	return 0
}

# Extract contact info from an email body (signature parsing)
# Produces TOON-format contact records in contacts/ directory
extract_contact_from_email() {
	local md_file="$1"
	local contacts_dir="$2"

	_extract_contact_python "$md_file" "$contacts_dir"

	return 0
}

# Batch import emails from a directory of .eml files or an mbox file
# Resolve input to a directory of .eml files.
# Sets eml_dir_ref and tmp_eml_dir_ref (tmp is set if mbox was split).
# Args: input_path eml_dir_ref tmp_eml_dir_ref
_import_resolve_eml_dir() {
	local input_path="$1"
	local eml_dir_ref="$2"
	local tmp_eml_dir_ref="$3"

	if [[ -d "${input_path}" ]]; then
		printf -v "${eml_dir_ref}" '%s' "${input_path}"
		log_info "Input: directory of .eml files"
		return 0
	fi

	if [[ ! -f "${input_path}" ]]; then
		die "Input must be a directory or mbox file: ${input_path}"
	fi

	local ext
	ext=$(get_ext "${input_path}")
	if [[ "${ext}" != "mbox" ]] && ! file "${input_path}" 2>/dev/null | grep -qi "mail\|mbox\|text"; then
		die "Input file is not a recognized mbox format: ${input_path}"
	fi

	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/mbox-split-$$"
	mkdir -p "${tmp_dir}"
	printf -v "${tmp_eml_dir_ref}" '%s' "${tmp_dir}"

	local split_output
	split_output=$(split_mbox "${input_path}" "${tmp_dir}")
	local mbox_count
	mbox_count=$(printf '%s' "$split_output" | grep -oE 'MBOX_COUNT=[0-9]+' | cut -d= -f2)
	mbox_count="${mbox_count:-0}"

	if [[ "${mbox_count}" -eq 0 ]]; then
		rm -rf "${tmp_dir}"
		die "No emails found in mbox file: ${input_path}"
	fi

	log_info "Extracted ${mbox_count} emails from mbox"
	printf -v "${eml_dir_ref}" '%s' "${tmp_dir}"
	return 0
}

# Process a single email file: convert and optionally extract contacts.
# Args: eml_file output_dir contacts_dir skip_contacts processed total start_time
# Outputs: "FAILED" to stdout if conversion failed, nothing otherwise.
_import_process_one_email() {
	local eml_file="$1"
	local output_dir="$2"
	local contacts_dir="$3"
	local skip_contacts="$4"
	local processed="$5"
	local total="$6"
	local start_time="$7"

	local pct=$((processed * 100 / total))
	local elapsed=$(($(date +%s) - start_time))
	local eta="calculating..."
	if [[ "${elapsed}" -gt 0 ]]; then
		local secs_per_email=$((elapsed / processed))
		local eta_secs=$(((total - processed) * secs_per_email))
		if [[ "${eta_secs}" -ge 60 ]]; then
			eta="$((eta_secs / 60))m $((eta_secs % 60))s"
		else
			eta="${eta_secs}s"
		fi
	fi

	printf "${BLUE}[%d/%d %d%%]${NC} Processing: %s (ETA: %s)\n" \
		"${processed}" "${total}" "${pct}" "$(basename "${eml_file}")" "${eta}"

	local convert_output
	if ! convert_output=$(convert_eml_to_md "${eml_file}" "${output_dir}" 2>/dev/null); then
		log_warn "Failed to process: $(basename "${eml_file}")"
		printf 'FAILED\n'
		return 0
	fi

	if [[ "${skip_contacts}" != true ]]; then
		local converted_md
		converted_md=$(printf '%s' "$convert_output" | grep '^Email converted:' | sed 's/^Email converted: //')
		if [[ -n "${converted_md}" ]] && [[ -f "${converted_md}" ]]; then
			extract_contact_from_email "${converted_md}" "${contacts_dir}" 2>/dev/null || true
		fi
	fi

	return 0
}

# Print import summary.
# Args: processed failed total start_time output_dir contacts_dir skip_contacts
_import_print_summary() {
	local processed="$1"
	local failed="$2"
	local total="$3"
	local start_time="$4"
	local output_dir="$5"
	local contacts_dir="$6"
	local skip_contacts="$7"

	local total_time=$(($(date +%s) - start_time))
	local total_time_fmt="${total_time}s"
	if [[ "${total_time}" -ge 60 ]]; then
		total_time_fmt="$((total_time / 60))m $((total_time % 60))s"
	fi

	printf "\n"
	log_ok "Batch import complete"
	printf '%b\n' "${BOLD}Summary:${NC}"
	printf "  Processed:  %d / %d emails\n" "$((processed - failed))" "${total}"
	if [[ "${failed}" -gt 0 ]]; then
		printf '  %bFailed:     %d%b\n' "${RED}" "${failed}" "${NC}"
	fi
	printf "  Duration:   %s\n" "${total_time_fmt}"
	printf "  Output:     %s\n" "${output_dir}"

	if [[ "${skip_contacts}" != true ]]; then
		local contact_count
		contact_count=$(find "${contacts_dir}" -name "*.toon" -type f 2>/dev/null | wc -l | tr -d ' ')
		printf "  Contacts:   %s unique contact(s) in %s\n" "${contact_count}" "${contacts_dir}"
	fi

	return 0
}

cmd_import_emails() {
	local input_path=""
	local output_dir=""
	local skip_contacts=false

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "${_arg}" in
		--output | -o)
			local _val="${2:-}"
			output_dir="${_val}"
			shift 2
			;;
		--skip-contacts)
			skip_contacts=true
			shift
			;;
		--*)
			log_warn "Unknown option: ${_arg}"
			shift
			;;
		*)
			[[ -z "${input_path}" ]] && input_path="${_arg}"
			shift
			;;
		esac
	done

	if [[ -z "${input_path}" ]]; then
		die "Usage: import-emails <dir|mbox-file> --output <dir> [--skip-contacts]"
	fi
	if [[ ! -e "${input_path}" ]]; then
		die "Input not found: ${input_path}"
	fi
	if [[ -z "${output_dir}" ]]; then
		die "Output directory required. Use --output <dir>"
	fi

	mkdir -p "${output_dir}"

	local eml_dir=""
	local tmp_eml_dir=""
	_import_resolve_eml_dir "${input_path}" eml_dir tmp_eml_dir

	local eml_files=()
	while IFS= read -r -d '' f; do
		eml_files+=("$f")
	done < <(find "${eml_dir}" -maxdepth 1 -type f \( -name "*.eml" -o -name "*.msg" \) -print0 2>/dev/null | sort -z)

	local total="${#eml_files[@]}"
	if [[ "${total}" -eq 0 ]]; then
		[[ -n "${tmp_eml_dir}" ]] && rm -rf "${tmp_eml_dir}"
		die "No .eml or .msg files found in: ${eml_dir}"
	fi

	log_info "Found ${total} email(s) to process"
	log_info "Output directory: ${output_dir}"

	local contacts_dir="${output_dir}/contacts"
	[[ "${skip_contacts}" != true ]] && mkdir -p "${contacts_dir}"

	local processed=0
	local failed=0
	local start_time
	start_time=$(date +%s)

	local eml_file
	for eml_file in "${eml_files[@]}"; do
		processed=$((processed + 1))
		local result
		result=$(_import_process_one_email \
			"${eml_file}" "${output_dir}" "${contacts_dir}" \
			"${skip_contacts}" "${processed}" "${total}" "${start_time}")
		if [[ "${result}" == "FAILED" ]]; then
			failed=$((failed + 1))
		fi
	done

	[[ -n "${tmp_eml_dir}" ]] && rm -rf "${tmp_eml_dir}"

	_import_print_summary "${processed}" "${failed}" "${total}" \
		"${start_time}" "${output_dir}" "${contacts_dir}" "${skip_contacts}"

	cmd_generate_manifest "${output_dir}" || log_warn "Manifest generation failed (non-fatal)"

	if [[ "${failed}" -gt 0 ]]; then
		return 1
	fi

	return 0
}
