#!/usr/bin/env bash
# document-creation-helper.sh - Unified document format conversion and creation
# Part of aidevops framework: https://aidevops.sh
#
# Usage: document-creation-helper.sh <command> [options]
# Commands: convert, create, template, normalise, pageindex, install, formats, status, help

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_NAME="document-creation-helper"
VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-creation"
TEMPLATE_DIR="${HOME}/.aidevops/.agent-workspace/templates"
# LOG_DIR used by future logging features
LOG_DIR="${HOME}/.aidevops/logs"
export LOG_DIR

# Colour output (disable if not a terminal)
if [[ -t 1 ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	BOLD='\033[1m'
	NC='\033[0m'
else
	RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ============================================================================
# Utility functions
# ============================================================================

log_info() {
	local msg="$1"
	printf "${BLUE}[info]${NC} %s\n" "$msg"
}

log_ok() {
	local msg="$1"
	printf "${GREEN}[ok]${NC} %s\n" "$msg"
}

log_warn() {
	local msg="$1"
	printf "${YELLOW}[warn]${NC} %s\n" "$msg" >&2
}

log_error() {
	local msg="$1"
	printf "${RED}[error]${NC} %s\n" "$msg" >&2
}

die() {
	local msg="$1"
	log_error "$msg"
	return 1
}

# Check if a command exists
has_cmd() {
	local bin_name="$1"
	command -v "$bin_name" &>/dev/null
}

# Get human-readable file size without using ls (SC2012)
human_filesize() {
	local file="$1"
	local bytes
	if [[ "$(uname)" == "Darwin" ]]; then
		bytes=$(stat -f%z -- "$file" || echo "0")
	else
		bytes=$(stat -c%s -- "$file" || echo "0")
	fi
	if [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%sG' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%sM' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	elif [[ "$bytes" -ge 1024 ]]; then
		printf '%s.%sK' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
	else
		printf '%sB' "$bytes"
	fi
	return 0
}

# Get file extension (lowercase)
get_ext() {
	local file="$1"
	local ext="${file##*.}"
	printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

# Activate Python venv if it exists
activate_venv() {
	if [[ -f "${VENV_DIR}/bin/activate" ]]; then
		source "${VENV_DIR}/bin/activate"
		return 0
	fi
	return 1
}

# Check if a Python package is available in the venv
has_python_pkg() {
	local pkg="$1"
	if activate_venv 2>/dev/null; then
		python3 -c "import ${pkg}" 2>/dev/null
		return $?
	fi
	return 1
}

# ============================================================================
# Advanced conversion provider detection
# ============================================================================

# Check if Reader-LM is available via Ollama
has_reader_lm() {
	if has_cmd ollama; then
		ollama list 2>/dev/null | grep -q "reader-lm"
		return $?
	fi
	return 1
}

# Check if RolmOCR is available via vLLM
has_rolm_ocr() {
	# Check if vLLM server is running with RolmOCR model
	# vLLM typically runs on port 8000 by default
	if command -v curl &>/dev/null; then
		local response
		response=$(curl -s http://localhost:8000/v1/models 2>/dev/null || echo "")
		if [[ -n "$response" ]] && echo "$response" | grep -q "rolm"; then
			return 0
		fi
	fi
	return 1
}

# ============================================================================
# OCR functions
# ============================================================================

# Detect if a PDF is scanned (image-only, no selectable text)
is_scanned_pdf() {
	local file="$1"

	if [[ "$(get_ext "$file")" != "pdf" ]]; then
		return 1
	fi

	# Check if pdftotext produces meaningful output
	if has_cmd pdftotext; then
		local text_len
		text_len=$(pdftotext "$file" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
		if [[ "${text_len}" -lt 50 ]]; then
			return 0 # Likely scanned
		fi
	fi

	# Check if any fonts are embedded
	if has_cmd pdffonts; then
		local font_count
		font_count=$(pdffonts "$file" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
		if [[ "${font_count}" -eq 0 ]]; then
			return 0 # No fonts = image-only
		fi
	fi

	return 1 # Has text content
}

# Select the best available OCR provider
select_ocr_provider() {
	local preferred="${1:-auto}"

	if [[ "${preferred}" != "auto" ]]; then
		case "${preferred}" in
		tesseract)
			if has_cmd tesseract; then
				printf 'tesseract'
				return 0
			fi
			die "Tesseract not installed. Run: install --tool tesseract"
			;;
		easyocr)
			if has_python_pkg easyocr 2>/dev/null; then
				printf 'easyocr'
				return 0
			fi
			die "EasyOCR not installed. Run: install --tool easyocr"
			;;
		glm-ocr)
			if has_cmd ollama; then
				printf 'glm-ocr'
				return 0
			fi
			die "Ollama not installed. Run: brew install ollama && ollama pull glm-ocr"
			;;
		*)
			die "Unknown OCR provider: ${preferred}. Use: tesseract, easyocr, glm-ocr, or auto"
			;;
		esac
	fi

	# Auto-select: fastest available first
	if has_cmd tesseract; then
		printf 'tesseract'
	elif has_python_pkg easyocr 2>/dev/null; then
		printf 'easyocr'
	elif has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
		printf 'glm-ocr'
	else
		die "No OCR tool available. Run: install --ocr"
	fi

	return 0
}

# Run OCR on an image file, output text to stdout
run_ocr() {
	local image_file="$1"
	local provider="$2"

	case "${provider}" in
	tesseract)
		# Tesseract's Leptonica has issues reading from /tmp on macOS.
		# Work around by copying to a non-tmp location if needed.
		local tess_input="$image_file"
		if [[ "$image_file" == /tmp/* || "$image_file" == /private/tmp/* || "$image_file" == /var/folders/* ]]; then
			local work_dir="${HOME}/.aidevops/.agent-workspace/tmp"
			mkdir -p "$work_dir"
			tess_input="${work_dir}/ocr-input-$$.$(get_ext "$image_file")"
			cp "$image_file" "$tess_input"
		fi
		tesseract "$tess_input" stdout 2>/dev/null
		# Clean up temp copy
		if [[ "$tess_input" != "$image_file" ]]; then
			rm -f "$tess_input"
		fi
		;;
	easyocr)
		activate_venv 2>/dev/null
		python3 -c "
import easyocr, sys
reader = easyocr.Reader(['en'], verbose=False)
results = reader.readtext(sys.argv[1], detail=0)
print('\n'.join(results))
" "$image_file" 2>/dev/null
		;;
	glm-ocr)
		# GLM-OCR via Ollama API
		local b64
		b64=$(base64 <"$image_file")
		local response
		response=$(curl -s http://localhost:11434/api/generate \
			-d "{\"model\":\"glm-ocr\",\"prompt\":\"Extract all text from this image.\",\"images\":[\"${b64}\"],\"stream\":false}" 2>/dev/null)
		printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" 2>/dev/null
		;;
	*)
		die "Unknown OCR provider: ${provider}"
		;;
	esac

	return 0
}

# OCR a scanned PDF: extract page images, OCR each, combine text
ocr_scanned_pdf() {
	local input="$1"
	local provider="$2"
	local output_text="$3"

	# Use workspace dir instead of /tmp to avoid macOS Leptonica sandbox issues
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/ocr-$$"
	mkdir -p "${tmp_dir}"
	local img_dir="${tmp_dir}/pages"
	mkdir -p "${img_dir}"

	log_info "Extracting page images from scanned PDF..."
	pdfimages -png "$input" "${img_dir}/page" 2>/dev/null

	local img_count
	img_count=$(find "${img_dir}" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')

	if [[ "${img_count}" -eq 0 ]]; then
		die "No images extracted from PDF. File may be empty."
	fi

	log_info "OCR processing ${img_count} page images with ${provider}..."

	# Process each image and combine
	: >"$output_text"
	local img_file
	for img_file in "${img_dir}"/page-*.png; do
		[[ -f "$img_file" ]] || continue
		log_info "  OCR: $(basename "$img_file")"
		run_ocr "$img_file" "$provider" >>"$output_text"
		printf '\n\n' >>"$output_text"
	done

	local text_len
	text_len=$(wc -c <"$output_text" | tr -d ' ')
	log_ok "OCR complete: ${text_len} bytes extracted"

	# Clean up
	rm -rf "${tmp_dir}"

	return 0
}

# ============================================================================
# Tool detection
# ============================================================================

# ============================================================================
# Status command
# ============================================================================

cmd_status() {
	printf '%b\n\n' "${BOLD}Document Conversion Tools Status${NC}"

	printf '%b\n' "${BOLD}Tier 1 - Minimal (text conversions):${NC}"
	if has_cmd pandoc; then
		log_ok "pandoc $(pandoc --version | head -1 | awk '{print $2}')"
	else
		log_warn "pandoc - NOT INSTALLED (brew install pandoc)"
	fi
	if has_cmd pdftotext; then
		log_ok "poppler (pdftotext, pdfimages, pdfinfo)"
	else
		log_warn "poppler - NOT INSTALLED (brew install poppler)"
	fi

	printf '\n%b\n' "${BOLD}Tier 2 - Standard (programmatic creation):${NC}"
	if [[ -d "${VENV_DIR}" ]]; then
		log_ok "Python venv: ${VENV_DIR}"
	else
		log_warn "Python venv not created (run: install --standard)"
	fi
	if has_python_pkg odf 2>/dev/null; then
		log_ok "odfpy (ODT/ODS creation)"
	else
		log_warn "odfpy - NOT INSTALLED"
	fi
	if has_python_pkg docx 2>/dev/null; then
		log_ok "python-docx (DOCX creation)"
	else
		log_warn "python-docx - NOT INSTALLED"
	fi
	if has_python_pkg openpyxl 2>/dev/null; then
		log_ok "openpyxl (XLSX creation)"
	else
		log_warn "openpyxl - NOT INSTALLED"
	fi

	printf '\n%b\n' "${BOLD}Tier 3 - Full (highest fidelity):${NC}"
	if has_cmd soffice || has_cmd libreoffice; then
		local lo_version
		lo_version=$(soffice --version 2>/dev/null || libreoffice --version 2>/dev/null || echo "unknown")
		log_ok "LibreOffice headless (${lo_version})"
	else
		log_warn "LibreOffice - NOT INSTALLED (brew install --cask libreoffice)"
	fi

	printf '\n%b\n' "${BOLD}OCR tools:${NC}"
	if has_cmd tesseract; then
		local tess_version
		tess_version=$(tesseract --version 2>&1 | head -1)
		log_ok "Tesseract (${tess_version})"
	else
		log_info "Tesseract - not installed (brew install tesseract)"
	fi
	if has_python_pkg easyocr 2>/dev/null; then
		log_ok "EasyOCR (Python, 80+ languages)"
	else
		log_info "EasyOCR - not installed (pip install easyocr)"
	fi
	if has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
		log_ok "GLM-OCR (local AI via Ollama)"
	else
		log_info "GLM-OCR - not installed (ollama pull glm-ocr)"
	fi

	printf '\n%b\n' "${BOLD}Specialist tools:${NC}"
	if has_cmd mineru; then
		log_ok "MinerU (layout-aware PDF to markdown)"
	else
		log_info "MinerU - not installed (optional: pip install 'mineru[all]')"
	fi

	printf '\n%b\n' "${BOLD}Advanced conversion providers:${NC}"
	if has_reader_lm; then
		log_ok "Reader-LM (Jina, 1.5B via Ollama - HTML to markdown with table preservation)"
	else
		log_info "Reader-LM - not installed (ollama pull reader-lm)"
	fi
	if has_rolm_ocr; then
		log_ok "RolmOCR (Reducto, 7B via vLLM - PDF page images to markdown with table preservation)"
	else
		log_info "RolmOCR - not available (requires vLLM server with RolmOCR model)"
	fi

	printf "\n${BOLD}Template directory:${NC} %s\n" "${TEMPLATE_DIR}"
	if [[ -d "${TEMPLATE_DIR}" ]]; then
		local count
		count=$(find "${TEMPLATE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')
		log_ok "${count} template(s) stored"
	else
		log_info "Not created yet (created on first use)"
	fi

	return 0
}

# ============================================================================
# Helper functions for cmd_install (extracted for complexity reduction)
# ============================================================================

_install_tier_minimal() {
	log_info "Installing Tier 1: pandoc + poppler"
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install pandoc poppler 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y pandoc poppler-utils
	else
		die "Unsupported platform. Install pandoc and poppler manually."
	fi
	log_ok "Tier 1 installed"
	return 0
}

_install_tier_standard() {
	log_info "Installing Tier 2: Python libraries"
	if ! has_cmd pandoc; then
		log_info "Installing Tier 1 first..."
		_install_tier_minimal
	fi
	if [[ ! -d "${VENV_DIR}" ]]; then
		log_info "Creating Python venv at ${VENV_DIR}"
		mkdir -p "$(dirname "${VENV_DIR}")"
		python3 -m venv "${VENV_DIR}"
	fi
	activate_venv
	pip install --quiet odfpy python-docx openpyxl
	log_ok "Tier 2 installed (odfpy, python-docx, openpyxl)"
	return 0
}

_install_tier_full() {
	log_info "Installing Tier 3: LibreOffice headless"
	if ! has_python_pkg odf 2>/dev/null; then
		_install_tier_standard
	fi
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install --cask libreoffice 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress
	else
		die "Unsupported platform. Install LibreOffice manually."
	fi
	log_ok "Tier 3 installed"
	return 0
}

_install_tier_ocr() {
	log_info "Installing OCR tools"
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install tesseract 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y tesseract-ocr
	fi
	if [[ ! -d "${VENV_DIR}" ]]; then
		mkdir -p "$(dirname "${VENV_DIR}")"
		python3 -m venv "${VENV_DIR}"
	fi
	activate_venv
	pip install --quiet easyocr
	if has_cmd ollama; then
		log_info "Pulling GLM-OCR model via Ollama..."
		ollama pull glm-ocr 2>&1 || true
	else
		log_info "Ollama not installed -- skipping GLM-OCR (brew install ollama)"
	fi
	log_ok "OCR tools installed"
	return 0
}

_install_specific_tool() {
	local tool="$1"
	case "${tool}" in
	pandoc)
		if [[ "$(uname)" == "Darwin" ]]; then brew install pandoc; else sudo apt-get install -y pandoc; fi
		;;
	poppler)
		if [[ "$(uname)" == "Darwin" ]]; then brew install poppler; else sudo apt-get install -y poppler-utils; fi
		;;
	odfpy | python-docx | openpyxl)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet "${tool}"
		;;
	libreoffice)
		if [[ "$(uname)" == "Darwin" ]]; then
			brew install --cask libreoffice
		else
			sudo apt-get install -y libreoffice-core
		fi
		;;
	mineru)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install "mineru[all]"
		;;
	tesseract)
		if [[ "$(uname)" == "Darwin" ]]; then brew install tesseract; else sudo apt-get install -y tesseract-ocr; fi
		;;
	easyocr)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet easyocr
		;;
	glm-ocr)
		if has_cmd ollama; then
			ollama pull glm-ocr
		else
			die "Ollama required for GLM-OCR. Install: brew install ollama"
		fi
		;;
	*)
		die "Unknown tool: ${tool}"
		;;
	esac
	log_ok "${tool} installed"
	return 0
}

# ============================================================================
# Install command
# ============================================================================

cmd_install() {
	local tier="${1:-}"
	local tool="${2:-}"

	case "${tier}" in
	--minimal)
		_install_tier_minimal
		;;
	--standard)
		_install_tier_standard
		;;
	--full)
		_install_tier_full
		;;
	--ocr)
		_install_tier_ocr
		;;
	--tool)
		if [[ -z "${tool}" ]]; then
			die "Usage: install --tool <name> (pandoc|poppler|odfpy|python-docx|openpyxl|libreoffice|mineru|tesseract|easyocr|glm-ocr)"
		fi
		_install_specific_tool "${tool}"
		;;
	*)
		printf "Usage: %s install <tier>\n\n" "${SCRIPT_NAME}"
		printf "Tiers:\n"
		printf "  --minimal    pandoc + poppler (text conversions)\n"
		printf "  --standard   + odfpy, python-docx, openpyxl (programmatic creation)\n"
		printf "  --full       + LibreOffice headless (highest fidelity)\n"
		printf "  --ocr        tesseract + easyocr + glm-ocr (scanned document support)\n"
		printf "  --tool NAME  Install a specific tool\n"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Formats command
# ============================================================================

cmd_formats() {
	printf '%b\n\n' "${BOLD}Supported Format Conversions${NC}"

	printf '%b\n' "${BOLD}Input formats:${NC}"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  Email:          eml, msg (MIME parsing with attachments)\n"
	printf "  PDF:            pdf (text extraction + image extraction)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"
	printf "  Data:           json, xml, rst, org\n"

	printf '\n%b\n' "${BOLD}Output formats:${NC}"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  PDF:            pdf (via pandoc+engine or LibreOffice)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"

	printf '\n%b\n' "${BOLD}Best quality paths:${NC}"
	printf "  eml/msg -> md:    email-to-markdown.py (extracts attachments)\n"
	printf "  odt/docx -> pdf:  LibreOffice headless (preserves layout)\n"
	printf "  md -> docx/odt:   pandoc (excellent)\n"
	printf "  pdf -> md:        MinerU (complex) or pandoc (simple)\n"
	printf "  pdf -> odt:       odfpy + poppler (programmatic rebuild)\n"
	printf "  xlsx <-> ods:     LibreOffice headless\n"

	return 0
}

# ============================================================================
# MIME/Email conversion functions
# ============================================================================

# Resolve email metadata and build the output directory path.
# Prints the email_dir and base_name (tab-separated) to stdout.
# Args: input_file output_dir
_eml_resolve_paths() {
	local input="$1"
	local output_dir="$2"

	python3 - "$input" "$output_dir" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file
from email.utils import parsedate_to_datetime, parseaddr
from datetime import datetime
import re

input_file = sys.argv[1]
output_dir = sys.argv[2]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

subject = msg.get('Subject', 'no-subject')
from_header = msg.get('From', '')
date_header = msg.get('Date', '')

sender_name, sender_email = parseaddr(from_header)
if not sender_email:
    sender_email = 'unknown'
if not sender_name:
    sender_name = 'unknown'

try:
    dt = parsedate_to_datetime(date_header)
    timestamp = dt.strftime('%Y-%m-%d-%H%M%S')
except Exception:
    timestamp = datetime.now().strftime('%Y-%m-%d-%H%M%S')

def sanitize(s):
    s = re.sub(r'[^\w\s.-]', '', s)
    s = re.sub(r'\s+', '-', s)
    return s[:50]

subject_safe = sanitize(subject)
sender_email_safe = sanitize(sender_email.replace('@', '-at-'))
sender_name_safe = sanitize(sender_name)

base_name = f"{timestamp}-{subject_safe}-{sender_email_safe}-{sender_name_safe}"
email_dir = os.path.join(output_dir, base_name)
os.makedirs(email_dir, exist_ok=True)

print(f"{email_dir}\t{base_name}")
PYEOF

	return 0
}

# Write markdown and raw-headers files from a parsed .eml.
# Prints "Email converted: <path>" and "Raw headers: <path>" to stdout.
# Args: input_file email_dir base_name
_eml_write_markdown() {
	local input="$1"
	local email_dir="$2"
	local base_name="$3"

	python3 - "$input" "$email_dir" "$base_name" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file

input_file = sys.argv[1]
email_dir = sys.argv[2]
base_name = sys.argv[3]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

subject = msg.get('Subject', 'no-subject')
from_header = msg.get('From', '')
date_header = msg.get('Date', '')
to_header = msg.get('To', '')
cc_header = msg.get('Cc', '')

from email.utils import parseaddr
sender_name, sender_email = parseaddr(from_header)
if not sender_email:
    sender_email = 'unknown'
if not sender_name:
    sender_name = 'unknown'

# Extract body
body_text = ""
body_html = ""
if msg.is_multipart():
    for part in msg.walk():
        content_disposition = str(part.get("Content-Disposition", ""))
        if "attachment" in content_disposition:
            continue
        ct = part.get_content_type()
        if ct == "text/plain":
            try:
                body_text = part.get_content()
            except Exception:
                pass
        elif ct == "text/html":
            try:
                body_html = part.get_content()
            except Exception:
                pass
else:
    ct = msg.get_content_type()
    if ct == "text/plain":
        try:
            body_text = msg.get_content()
        except Exception:
            pass
    elif ct == "text/html":
        try:
            body_html = msg.get_content()
        except Exception:
            pass

body = body_text if body_text else body_html

md_file = os.path.join(email_dir, f"{base_name}.md")
with open(md_file, 'w', encoding='utf-8') as f:
    f.write(f"# Email: {subject}\n\n")
    f.write(f"**From:** {sender_name} <{sender_email}>\n")
    f.write(f"**Date:** {date_header}\n")
    if to_header:
        f.write(f"**To:** {to_header}\n")
    if cc_header:
        f.write(f"**Cc:** {cc_header}\n")
    f.write("\n---\n\n")
    f.write(body)

raw_headers_file = os.path.join(email_dir, f"{base_name}-raw-headers.md")
with open(raw_headers_file, 'w', encoding='utf-8') as f:
    f.write("# Raw Email Headers\n\n```\n")
    for key, value in msg.items():
        f.write(f"{key}: {value}\n")
    f.write("```\n")

print(f"Email converted: {md_file}")
print(f"Raw headers: {raw_headers_file}")
PYEOF

	return 0
}

# Extract attachments from a .eml file into email_dir.
# Prints "Extracted attachment: <name>" lines and "Attachments: N" to stdout.
# Args: input_file email_dir
_eml_extract_attachments() {
	local input="$1"
	local email_dir="$2"

	python3 - "$input" "$email_dir" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file

input_file = sys.argv[1]
email_dir = sys.argv[2]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

attachment_count = 0
if msg.is_multipart():
    for part in msg.walk():
        content_disposition = str(part.get("Content-Disposition", ""))
        if "attachment" in content_disposition:
            filename = part.get_filename()
            if filename:
                attachment_count += 1
                attachment_path = os.path.join(email_dir, filename)
                with open(attachment_path, 'wb') as f:
                    f.write(part.get_payload(decode=True))
                print(f"  Extracted attachment: {filename}")

print(f"Attachments: {attachment_count}")
PYEOF

	return 0
}

# Python MIME parser for a single .eml file.
# Writes markdown + raw-headers files and prints status lines to stdout.
# Orchestrates _eml_resolve_paths, _eml_write_markdown, _eml_extract_attachments.
# Args: input_file output_dir
_eml_parse_mime() {
	local input="$1"
	local output_dir="$2"

	# Step 1: resolve output paths from email metadata
	local path_info
	path_info=$(_eml_resolve_paths "$input" "$output_dir")
	local email_dir
	email_dir=$(printf '%s' "$path_info" | cut -f1)
	local base_name
	base_name=$(printf '%s' "$path_info" | cut -f2)

	if [[ -z "$email_dir" || -z "$base_name" ]]; then
		die "Failed to resolve email paths for: ${input}"
	fi

	# Step 2: write markdown and raw headers
	_eml_write_markdown "$input" "$email_dir" "$base_name"

	# Step 3: extract attachments
	_eml_extract_attachments "$input" "$email_dir"

	printf 'Output directory: %s\n' "$email_dir"

	return 0
}

# Run normalise on the converted markdown path extracted from eml_output_log.
# Args: eml_output_log no_normalise
_eml_run_normalise() {
	local eml_output_log="$1"
	local no_normalise="$2"

	if [[ "${no_normalise}" == true ]] || [[ ! -f "${eml_output_log}" ]]; then
		return 0
	fi

	local md_path
	md_path=$(grep '^Email converted: ' "${eml_output_log}" | sed 's/^Email converted: //')
	if [[ -n "${md_path}" ]] && [[ -f "${md_path}" ]]; then
		log_info "Running email normalisation on: $(basename "${md_path}")"
		cmd_normalise "${md_path}" --inplace --email
	fi

	return 0
}

# Convert .eml or .msg file to markdown with attachments
convert_eml_to_md() {
	local input="$1"
	local output_dir="$2"
	local no_normalise="${3:-false}"

	log_info "Parsing email: $(basename "$input")"

	# Capture Python output to temp file for md path extraction
	local eml_output_log
	eml_output_log=$(mktemp)

	# Use Python email stdlib to parse MIME
	_eml_parse_mime "$input" "$output_dir" | tee "${eml_output_log}"

	# Extract markdown file path from captured output and run normalise
	_eml_run_normalise "${eml_output_log}" "${no_normalise}"
	rm -f "${eml_output_log}"

	return 0
}

# ============================================================================
# Convert command
# ============================================================================

# OCR pre-processing helper for cmd_convert.
# Modifies input/from_ext via nameref if OCR is needed.
# Args: input_ref from_ext_ref ocr_provider_ref
# Returns 0 always (errors are fatal via die).
_convert_ocr_preprocess() {
	local input_ref="$1"
	local from_ext_ref="$2"
	local ocr_provider_ref="$3"

	local _input="${!input_ref}"
	local _from_ext="${!from_ext_ref}"
	local _ocr_provider="${!ocr_provider_ref}"

	if [[ -z "${_ocr_provider}" ]] && ! { [[ "${_from_ext}" == "pdf" ]] && is_scanned_pdf "${_input}"; }; then
		return 0
	fi

	if [[ -z "${_ocr_provider}" ]]; then
		_ocr_provider="auto"
		log_info "Scanned PDF detected -- activating OCR"
	fi

	local provider
	provider=$(select_ocr_provider "${_ocr_provider}")

	local ocr_work="${HOME}/.aidevops/.agent-workspace/tmp"
	mkdir -p "$ocr_work"

	if [[ "${_from_ext}" == "pdf" ]]; then
		local ocr_text="${ocr_work}/ocr-text-$$.txt"
		ocr_scanned_pdf "${_input}" "$provider" "$ocr_text"
		printf -v "${input_ref}" '%s' "$ocr_text"
		printf -v "${from_ext_ref}" '%s' "txt"
		log_info "Proceeding with OCR text as input"
	elif [[ "${_from_ext}" =~ ^(png|jpg|jpeg|tiff|tif|bmp|webp)$ ]]; then
		local ocr_text="${ocr_work}/ocr-text-$$.txt"
		log_info "Running OCR on image with ${provider}..."
		run_ocr "${_input}" "$provider" >"$ocr_text"
		local text_len
		text_len=$(wc -c <"$ocr_text" | tr -d ' ')
		log_ok "OCR extracted ${text_len} bytes from image"
		printf -v "${input_ref}" '%s' "$ocr_text"
		printf -v "${from_ext_ref}" '%s' "txt"
	fi

	return 0
}

# Tool execution helper for cmd_convert.
# Args: tool input output to_ext template extra_args dedup_registry
_convert_execute_tool() {
	local tool="$1"
	local input="$2"
	local output="$3"
	local to_ext="$4"
	local template="$5"
	local extra_args="$6"
	local dedup_registry="$7"

	case "${tool}" in
	email-parser)
		convert_email "$input" "$output" "$dedup_registry"
		;;
	pandoc)
		convert_with_pandoc "$input" "$output" "$extra_args"
		;;
	libreoffice)
		local output_dir
		output_dir=$(dirname "$output")
		convert_with_libreoffice "$input" "${to_ext}" "${output_dir}"
		;;
	odfpy-pipeline)
		convert_pdf_to_odt "$input" "$output" "$template"
		;;
	mineru)
		local output_dir
		output_dir=$(dirname "$output")
		log_info "Converting with MinerU: $(basename "$input") -> markdown"
		mineru -p "$input" -o "${output_dir}"
		log_ok "MinerU output in: ${output_dir}"
		;;
	pdftotext)
		log_info "Extracting text with pdftotext"
		pdftotext -layout "$input" "$output"
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created: ${output} (${size})"
		fi
		;;
	pdftohtml)
		log_info "Converting with pdftohtml"
		pdftohtml -s "$input" "$output"
		log_ok "Created: ${output}"
		;;
	reader-lm)
		convert_with_reader_lm "$input" "$output"
		;;
	rolm-ocr)
		convert_with_rolm_ocr "$input" "$output"
		;;
	*)
		die "Unknown tool: ${tool}"
		;;
	esac

	return 0
}

# ============================================================================
# Helper functions for select_tool (extracted for complexity reduction)
# ============================================================================

# ============================================================================
# Helper functions for select_tool (extracted for complexity reduction)
# ============================================================================

_select_tool_pdf() {
	local to_ext="$1"
	case "${to_ext}" in
	md | markdown)
		if has_rolm_ocr; then
			printf 'rolm-ocr'
		elif has_cmd mineru; then
			printf 'mineru'
		elif has_cmd pdftotext; then
			printf 'pdftotext'
		else
			die "No tool available for pdf->md. Run: install --minimal (poppler) or install MinerU"
		fi
		;;
	odt)
		if has_python_pkg odf 2>/dev/null && has_cmd pdftotext; then
			printf 'odfpy-pipeline'
		else
			die "No tool available for pdf->odt. Run: install --standard (odfpy + poppler)"
		fi
		;;
	docx)
		if has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		else
			die "No tool available for pdf->docx. Run: install --full (LibreOffice)"
		fi
		;;
	html)
		if has_cmd pdftohtml; then
			printf 'pdftohtml'
		else
			die "No tool available for pdf->html. Run: install --minimal (poppler)"
		fi
		;;
	txt | text)
		printf 'pdftotext'
		;;
	*)
		die "Unsupported conversion: pdf -> ${to_ext}"
		;;
	esac
	return 0
}

_select_tool_spreadsheet() {
	local from_ext="$1"
	local to_ext="$2"
	if [[ "${to_ext}" == "csv" ]] || [[ "${from_ext}" == "csv" ]]; then
		if has_python_pkg openpyxl 2>/dev/null; then
			printf 'openpyxl'
		elif has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		elif has_cmd pandoc; then
			printf 'pandoc'
		else
			die "No tool available for spreadsheet conversion."
		fi
	elif has_cmd soffice || has_cmd libreoffice; then
		printf 'libreoffice'
	else
		die "LibreOffice required for ${from_ext}->${to_ext}. Run: install --full"
	fi
	return 0
}

_select_tool_presentation() {
	local from_ext="$1"
	local to_ext="$2"
	if [[ "${to_ext}" == "md" ]] || [[ "${to_ext}" == "markdown" ]]; then
		if has_cmd pandoc; then
			printf 'pandoc'
		else
			die "pandoc required for presentation->md."
		fi
	elif has_cmd soffice || has_cmd libreoffice; then
		printf 'libreoffice'
	elif has_cmd pandoc; then
		printf 'pandoc'
	else
		die "No tool available for presentation conversion."
	fi
	return 0
}

_select_tool_html_to_md() {
	if has_reader_lm; then
		printf 'reader-lm'
	elif has_cmd pandoc; then
		printf 'pandoc'
	else
		die "No tool available for html->md. Run: install --minimal (pandoc) or ollama pull reader-lm"
	fi
	return 0
}

select_tool() {
	local from_ext="$1"
	local to_ext="$2"
	local force_tool="${3:-}"

	if [[ -n "${force_tool}" ]]; then
		printf '%s' "${force_tool}"
		return 0
	fi

	# Email formats (.eml, .msg) to markdown
	if [[ "${from_ext}" =~ ^(eml|msg)$ ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]]; then
		printf 'email-parser'
		return 0
	fi

	# PDF source requires special handling
	if [[ "${from_ext}" == "pdf" ]]; then
		_select_tool_pdf "${to_ext}"
		return 0
	fi

	# Email source requires special handling
	if [[ "${from_ext}" =~ ^(eml|msg)$ ]]; then
		case "${to_ext}" in
		md | markdown)
			printf 'email-parser'
			;;
		*)
			die "Email files can only be converted to markdown. Use: --to md"
			;;
		esac
		return 0
	fi

	# Office format to PDF: prefer LibreOffice
	if [[ "${to_ext}" == "pdf" ]]; then
		if has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		elif has_cmd pandoc; then
			printf 'pandoc'
		else
			die "No tool available for ${from_ext}->pdf."
		fi
		return 0
	fi

	# Spreadsheet conversions: prefer LibreOffice
	if [[ "${from_ext}" =~ ^(xlsx|ods|xls)$ ]] || [[ "${to_ext}" =~ ^(xlsx|ods|xls)$ ]]; then
		_select_tool_spreadsheet "${from_ext}" "${to_ext}"
		return 0
	fi

	# Presentation conversions: prefer LibreOffice
	if [[ "${from_ext}" =~ ^(pptx|odp|ppt)$ ]] || [[ "${to_ext}" =~ ^(pptx|odp|ppt)$ ]]; then
		_select_tool_presentation "${from_ext}" "${to_ext}"
		return 0
	fi

	# HTML to markdown: prefer Reader-LM for table preservation
	if [[ "${from_ext}" == "html" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]]; then
		_select_tool_html_to_md
		return 0
	fi

	# Default: pandoc handles most text format conversions
	if has_cmd pandoc; then
		printf 'pandoc'
	else
		die "pandoc required. Run: install --minimal"
	fi

	return 0
}

convert_with_pandoc() {
	local input="$1"
	local output="$2"
	local extra_args="${3:-}"

	log_info "Converting with pandoc: $(basename "$input") -> $(basename "$output")"

	local pandoc_cmd=(pandoc "$input" -o "$output" --wrap=none)

	# Add PDF engine if outputting PDF
	if [[ "${output}" == *.pdf ]]; then
		if has_cmd xelatex; then
			pandoc_cmd+=(--pdf-engine=xelatex)
		elif has_cmd pdflatex; then
			pandoc_cmd+=(--pdf-engine=pdflatex)
		elif has_cmd wkhtmltopdf; then
			pandoc_cmd+=(--pdf-engine=wkhtmltopdf)
		fi
	fi

	# Extract media for formats that support it
	local from_ext
	from_ext=$(get_ext "$input")
	if [[ "${from_ext}" =~ ^(docx|odt|epub|html)$ ]]; then
		local media_dir
		media_dir="$(dirname "$output")/media"
		pandoc_cmd+=(--extract-media="$media_dir")
	fi

	# shellcheck disable=SC2086
	"${pandoc_cmd[@]}" ${extra_args}

	if [[ -f "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		log_ok "Created: ${output} (${size})"
	else
		die "Conversion failed: output file not created"
	fi

	return 0
}

convert_with_libreoffice() {
	local input="$1"
	local to_ext="$2"
	local output_dir="$3"

	log_info "Converting with LibreOffice: $(basename "$input") -> ${to_ext}"

	local lo_cmd
	if has_cmd soffice; then
		lo_cmd="soffice"
	else
		lo_cmd="libreoffice"
	fi

	"${lo_cmd}" --headless --convert-to "${to_ext}" --outdir "${output_dir}" "$input" 2>&1

	local basename_noext
	basename_noext="$(basename "${input%.*}")"
	local output_file="${output_dir}/${basename_noext}.${to_ext}"

	if [[ -f "${output_file}" ]]; then
		local size
		size=$(human_filesize "${output_file}")
		log_ok "Created: ${output_file} (${size})"
	else
		die "LibreOffice conversion failed"
	fi

	return 0
}

convert_with_reader_lm() {
	local input="$1"
	local output="$2"

	log_info "Converting with Reader-LM: $(basename "$input") -> markdown"

	if ! has_reader_lm; then
		die "Reader-LM not available. Run: ollama pull reader-lm"
	fi

	# Read HTML content
	local html_content
	html_content=$(cat "$input")

	# Use Ollama API to convert HTML to markdown
	local response
	response=$(curl -s http://localhost:11434/api/generate \
		-d "{\"model\":\"reader-lm\",\"prompt\":\"Convert this HTML to markdown, preserving tables and structure:\n\n${html_content}\",\"stream\":false}" 2>/dev/null)

	if [[ -z "$response" ]]; then
		die "Reader-LM conversion failed: no response from Ollama"
	fi

	# Extract markdown from response
	printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" >"$output" 2>/dev/null

	if [[ -f "$output" ]] && [[ -s "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		log_ok "Created: ${output} (${size})"
	else
		die "Reader-LM conversion failed: output file empty or not created"
	fi

	return 0
}

convert_with_rolm_ocr() {
	local input="$1"
	local output="$2"

	log_info "Converting with RolmOCR: $(basename "$input") -> markdown"

	if ! has_rolm_ocr; then
		die "RolmOCR not available. Ensure vLLM server is running with RolmOCR model on port 8000"
	fi

	# Use workspace dir for temp files
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/rolm-$$"
	mkdir -p "${tmp_dir}"
	local img_dir="${tmp_dir}/pages"
	mkdir -p "${img_dir}"

	# Extract page images from PDF
	log_info "Extracting page images from PDF..."
	pdfimages -png "$input" "${img_dir}/page" 2>/dev/null

	local img_count
	img_count=$(find "${img_dir}" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')

	if [[ "${img_count}" -eq 0 ]]; then
		die "No images extracted from PDF. File may be empty or text-based (use pdftotext instead)."
	fi

	log_info "Processing ${img_count} page images with RolmOCR..."

	# Process each image and combine
	: >"$output"
	local img_file
	for img_file in "${img_dir}"/page-*.png; do
		[[ -f "$img_file" ]] || continue
		log_info "  RolmOCR: $(basename "$img_file")"

		# Convert image to base64
		local b64
		b64=$(base64 <"$img_file")

		# Call vLLM API with RolmOCR model
		local response
		response=$(curl -s http://localhost:8000/v1/chat/completions \
			-H "Content-Type: application/json" \
			-d "{\"model\":\"rolm-ocr\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,${b64}\"}},{\"type\":\"text\",\"text\":\"Convert this page to markdown, preserving tables and structure.\"}]}]}" 2>/dev/null)

		if [[ -n "$response" ]]; then
			# Extract markdown from response
			local page_md
			page_md=$(printf '%s' "$response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content',''))" 2>/dev/null)
			printf '%s\n\n' "$page_md" >>"$output"
		else
			log_warn "  RolmOCR failed for $(basename "$img_file"), skipping"
		fi
	done

	local text_len
	text_len=$(wc -c <"$output" | tr -d ' ')
	log_ok "RolmOCR complete: ${text_len} bytes extracted"

	# Clean up
	rm -rf "${tmp_dir}"

	if [[ -f "$output" ]] && [[ -s "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		log_ok "Created: ${output} (${size})"
	else
		die "RolmOCR conversion failed: output file empty or not created"
	fi

	return 0
}

convert_pdf_to_odt() {
	local input="$1"
	local output="$2"
	local _template="${3:-}" # reserved for future template-based conversion

	log_info "Converting PDF to ODT (programmatic pipeline)"

	if ! has_cmd pdftotext; then
		die "pdftotext required. Run: install --minimal"
	fi

	if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
		die "odfpy required. Run: install --standard"
	fi

	# Extract text
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local text_file="${tmp_dir}/content.txt"
	local img_dir="${tmp_dir}/images"
	mkdir -p "${img_dir}"

	log_info "Extracting text..."
	pdftotext -layout "$input" "$text_file"

	log_info "Extracting images..."
	pdfimages -png "$input" "${img_dir}/img" 2>/dev/null || true

	# Get metadata
	local page_count="unknown"
	if has_cmd pdfinfo; then
		page_count=$(pdfinfo "$input" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "unknown")
	fi

	local img_count
	img_count=$(find "${img_dir}" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')

	log_info "Extracted: ${page_count} pages, ${img_count} images"
	log_info "Text and images saved to: ${tmp_dir}"
	log_info "Building ODT requires AI agent assistance for layout reconstruction."
	log_info "Text file: ${text_file}"
	log_info "Images dir: ${img_dir}"

	# For now, create a basic ODT with the extracted text using pandoc as fallback
	# Full layout reconstruction requires the AI agent to analyse structure
	if has_cmd pandoc; then
		log_info "Creating basic ODT with pandoc (text only, no layout reconstruction)..."
		pandoc "$text_file" -o "$output" --wrap=none
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created basic ODT: ${output} (${size})"
			log_info "For full layout reconstruction with images, headers, and footers,"
			log_info "use the AI agent: 'convert this PDF to ODT with full layout'"
			log_info "Extracted assets available at: ${tmp_dir}"
		fi
	else
		log_info "Extracted assets ready for AI agent to build ODT."
		log_info "Text: ${text_file}"
		log_info "Images: ${img_dir}"
	fi

	return 0
}

convert_email() {
	local input="$1"
	local output="$2"
	local dedup_registry="${3:-}"

	log_info "Converting email with email-to-markdown.py: $(basename "$input") -> $(basename "$output")"

	# Determine attachments directory
	local attachments_dir
	attachments_dir="$(dirname "$output")/$(basename "${output%.md}")_attachments"

	# Check if Python script exists
	local script_path
	script_path="$(dirname "${BASH_SOURCE[0]}")/email-to-markdown.py"
	if [[ ! -f "${script_path}" ]]; then
		die "Email parser script not found: ${script_path}"
	fi

	# Activate venv and run the parser
	if ! activate_venv 2>/dev/null; then
		die "Python venv required. Run: install --standard"
	fi

	# Check for required Python packages
	if ! python3 -c "import html2text" 2>/dev/null; then
		log_info "Installing html2text..."
		pip install --quiet html2text
	fi

	# Check if input is .msg and install extract-msg if needed
	local ext
	ext=$(get_ext "$input")
	if [[ "${ext}" == "msg" ]]; then
		if ! python3 -c "import extract_msg" 2>/dev/null; then
			log_info "Installing extract-msg for .msg file support..."
			pip install --quiet extract-msg
		fi
	fi

	# Build parser command with optional dedup registry
	local parser_args=("$input" --output "$output" --attachments-dir "$attachments_dir")
	if [[ -n "${dedup_registry}" ]]; then
		parser_args+=(--dedup-registry "$dedup_registry")
	fi

	# Run the parser
	python3 "${script_path}" "${parser_args[@]}"

	if [[ -f "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		log_ok "Created: ${output} (${size})"
		if [[ -d "$attachments_dir" ]]; then
			local att_count
			att_count=$(find "$attachments_dir" -type f -o -type l 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${att_count}" -gt 0 ]]; then
				log_ok "Extracted ${att_count} attachment(s) to: ${attachments_dir}"
			fi
		fi
	else
		die "Email conversion failed: output file not created"
	fi

	return 0
}

# ============================================================================
# Extracted helpers for complexity reduction (t1044.12)
# ============================================================================

# Helpers for cmd_convert - extract argument parsing
_convert_parse_args() {
	local -n input_ref=$1 to_ext_ref=$2 output_ref=$3 force_tool_ref=$4
	local -n template_ref=$5 extra_args_ref=$6 ocr_provider_ref=$7
	local -n run_normalise_ref=$8 dedup_registry_ref=$9
	shift 9

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to_ext_ref="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--output | -o)
			output_ref="$2"
			shift 2
			;;
		--tool)
			force_tool_ref="$2"
			shift 2
			;;
		--template)
			template_ref="$2"
			shift 2
			;;
		--engine)
			extra_args_ref="--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			dedup_registry_ref="$2"
			shift 2
			;;
		--ocr)
			ocr_provider_ref="${2:-auto}"
			shift
			[[ $# -gt 0 && "$1" != --* ]] && {
				ocr_provider_ref="$1"
				shift
			}
			;;
		--no-normalise | --no-normalize)
			run_normalise_ref=false
			shift
			;;
		--*)
			extra_args_ref="${extra_args_ref} $1"
			shift
			;;
		*)
			[[ -z "${input_ref}" ]] && input_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_create - extract argument parsing
_create_parse_args() {
	local -n template_ref=$1 data_ref=$2 output_ref=$3 script_ref=$4
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			data_ref="$2"
			shift 2
			;;
		--output | -o)
			output_ref="$2"
			shift 2
			;;
		--script)
			script_ref="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${template_ref}" ]] && template_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_import_emails - extract argument parsing
_import_parse_args() {
	local -n input_path_ref=$1 output_dir_ref=$2 skip_contacts_ref=$3
	shift 3

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output_dir_ref="$2"
			shift 2
			;;
		--skip-contacts)
			skip_contacts_ref=true
			shift
			;;
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${input_path_ref}" ]] && input_path_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_template - extract argument parsing
_template_parse_args() {
	local -n doc_type_ref=$1 format_ref=$2 fields_ref=$3
	local -n header_logo_ref=$4 footer_text_ref=$5 output_ref=$6
	shift 6

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			doc_type_ref="$2"
			shift 2
			;;
		--format)
			format_ref="$2"
			shift 2
			;;
		--fields)
			fields_ref="$2"
			shift 2
			;;
		--header-logo)
			header_logo_ref="$2"
			shift 2
			;;
		--footer-text)
			footer_text_ref="$2"
			shift 2
			;;
		--output)
			output_ref="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Helpers for cmd_normalise - extract argument parsing
_normalise_parse_args() {
	local -n input_ref=$1 output_ref=$2 inplace_ref=$3
	local -n generate_pageindex_ref=$4 email_mode_ref=$5
	shift 5

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output_ref="$2"
			shift 2
			;;
		--inplace | -i)
			inplace_ref=true
			shift
			;;
		--pageindex)
			generate_pageindex_ref=true
			shift
			;;
		--email | -e)
			email_mode_ref=true
			shift
			;;
		--*) shift ;;
		*)
			[[ -z "${input_ref}" ]] && input_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_pageindex - extract argument parsing
_pageindex_parse_args() {
	local -n input_ref=$1 output_ref=$2 source_pdf_ref=$3 ollama_model_ref=$4
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output_ref="$2"
			shift 2
			;;
		--source-pdf)
			source_pdf_ref="$2"
			shift 2
			;;
		--ollama-model)
			ollama_model_ref="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${input_ref}" ]] && input_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_generate_manifest - extract argument parsing
_manifest_parse_args() {
	local -n output_dir_ref=$1
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${output_dir_ref}" ]] && output_dir_ref="$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate and resolve paths for cmd_convert.
# Sets output and from_ext; validates input/to_ext.
# Args: input to_ext output_ref from_ext_ref
_convert_validate_paths() {
	local input="$1"
	local to_ext="$2"
	local output_ref="$3"
	local from_ext_ref="$4"

	if [[ -z "${input}" ]]; then
		die "Usage: convert <input-file> --to <format> [--output <file>] [--tool <name>]"
	fi
	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi
	if [[ -z "${to_ext}" ]]; then
		die "Target format required. Use --to <format> (e.g., --to pdf, --to odt)"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		_output="${input%.*}.${to_ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	local _from_ext
	_from_ext=$(get_ext "$input")
	printf -v "${from_ext_ref}" '%s' "${_from_ext}"

	if [[ "${_from_ext}" == "${to_ext}" ]]; then
		die "Input and output formats are the same: ${_from_ext}"
	fi

	return 0
}

cmd_convert() {
	local input=""
	local to_ext=""
	local output=""
	local force_tool=""
	local template=""
	local extra_args=""
	local ocr_provider=""
	local run_normalise=true
	local dedup_registry=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to_ext="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--output | -o)
			output="$2"
			shift 2
			;;
		--tool)
			force_tool="$2"
			shift 2
			;;
		--template)
			template="$2"
			shift 2
			;;
		--engine)
			extra_args="--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			dedup_registry="$2"
			shift 2
			;;
		--ocr)
			ocr_provider="${2:-auto}"
			shift
			if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then
				ocr_provider="$1"
				shift
			fi
			;;
		--no-normalise | --no-normalize)
			run_normalise=false
			shift
			;;
		--*)
			extra_args="${extra_args} $1"
			shift
			;;
		*)
			[[ -z "${input}" ]] && input="$1"
			shift
			;;
		esac
	done

	# Normalise format aliases
	case "${to_ext}" in
	markdown) to_ext="md" ;;
	text) to_ext="txt" ;;
	esac

	# Validate inputs and resolve output/from_ext
	local from_ext=""
	_convert_validate_paths "${input}" "${to_ext}" output from_ext

	# OCR pre-processing: handle scanned PDFs and images (modifies input/from_ext)
	_convert_ocr_preprocess input from_ext ocr_provider

	# Select tool and execute conversion
	local tool
	tool=$(select_tool "${from_ext}" "${to_ext}" "${force_tool}")
	_convert_execute_tool "${tool}" "$input" "$output" "${to_ext}" \
		"${template}" "${extra_args}" "${dedup_registry}"

	# Auto-run normalise after *→md conversions (unless --no-normalise flag is set)
	if [[ "${run_normalise}" == "true" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]] && [[ -f "$output" ]]; then
		log_info "Running normalisation on converted markdown..."
		if "${BASH_SOURCE[0]}" normalise "$output"; then
			log_ok "Normalisation complete"
		else
			log_warn "Normalisation failed (non-fatal)"
		fi
	fi

	return 0
}

# ============================================================================
# Template command
# ============================================================================

# Helper: handle 'template draft' subcommand logic
_template_draft_subcommand() {
	local doc_type=""
	local format="odt"
	local fields=""
	local header_logo=""
	local footer_text=""
	local output=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			doc_type="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--fields)
			fields="$2"
			shift 2
			;;
		--header-logo)
			header_logo="$2"
			shift 2
			;;
		--footer-text)
			footer_text="$2"
			shift 2
			;;
		--output)
			output="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "${doc_type}" ]]; then
		die "Usage: template draft --type <name> [--format odt|docx] [--fields f1,f2,f3]"
	fi

	if [[ -z "${output}" ]]; then
		mkdir -p "${TEMPLATE_DIR}/documents"
		output="${TEMPLATE_DIR}/documents/${doc_type}-template.${format}"
	fi

	log_info "Generating draft template: ${doc_type} (${format})"
	log_info "Fields: ${fields:-auto}"
	log_info "Output: ${output}"

	if [[ "${format}" == "odt" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required for ODT template generation. Run: install --standard"
		fi
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		python3 "${script_dir}/template-draft.py" \
			"$output" "$doc_type" "$fields" "$header_logo" "$footer_text"
		log_ok "Draft template created: ${output}"
		log_info "Edit in LibreOffice or your preferred editor to refine layout."
		log_info "Replace {{placeholders}} markers with your design, keeping the field names."
	elif [[ "${format}" == "docx" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required for DOCX template generation. Run: install --standard"
		fi
		log_warn "DOCX template generation not yet implemented. Use ODT format."
	else
		die "Unsupported template format: ${format}. Use odt or docx."
	fi

	return 0
}

cmd_template() {
	local subcmd="${1:-}"
	shift || true

	case "${subcmd}" in
	list)
		printf '%b\n\n' "${BOLD}Stored Templates${NC}"
		if [[ -d "${TEMPLATE_DIR}" ]]; then
			find "${TEMPLATE_DIR}" -type f | while read -r f; do
				local rel="${f#"${TEMPLATE_DIR}/"}"
				local size
				size=$(human_filesize "$f")
				printf "  %s (%s)\n" "$rel" "$size"
			done
		else
			log_info "No templates stored yet."
			log_info "Directory: ${TEMPLATE_DIR}"
		fi
		;;
	draft)
		_template_draft_subcommand "$@"
		;;
	*)
		printf "Usage: %s template <subcommand>\n\n" "${SCRIPT_NAME}"
		printf "Subcommands:\n"
		printf "  list                          List stored templates\n"
		printf "  draft --type <name> [opts]     Generate a draft template\n"
		printf "\nDraft options:\n"
		printf "  --type <name>         Document type (letter, report, invoice, statement)\n"
		printf "  --format <odt|docx>   Output format (default: odt)\n"
		printf "  --fields <f1,f2,...>   Comma-separated placeholder field names\n"
		printf "  --header-logo <path>  Logo image for header\n"
		printf "  --footer-text <text>  Footer text\n"
		printf "  --output <path>       Output file path\n"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Create command (fill template with data)
# ============================================================================

# Script mode: run a Python creation script with optional data/output args.
# Args: script data output
_create_run_script() {
	local script="$1"
	local data="$2"
	local output="$3"

	if [[ ! -f "${script}" ]]; then
		die "Script not found: ${script}"
	fi
	log_info "Running creation script: ${script}"
	activate_venv 2>/dev/null || true
	# shellcheck disable=SC2086
	python3 "${script}" ${data:+--data "$data"} ${output:+--output "$output"}
	return $?
}

# Fill an ODT template with data using Python zipfile manipulation.
# Args: template data output
_create_fill_odt_python() {
	local template="$1"
	local data="$2"
	local output="$3"

	python3 - "$template" "$data" "$output" <<'PYEOF'
import sys
import os
import json
import zipfile
import shutil
import tempfile
import re

template_path = sys.argv[1]
data_arg = sys.argv[2]
output_path = sys.argv[3]

# Load data
if os.path.isfile(data_arg):
    with open(data_arg, 'r') as f:
        data = json.load(f)
else:
    data = json.loads(data_arg)

# ODT is a ZIP file. Extract, replace placeholders in content.xml and styles.xml, repack.
tmp_dir = tempfile.mkdtemp()
try:
    with zipfile.ZipFile(template_path, 'r') as z:
        z.extractall(tmp_dir)

    # Replace in content.xml and styles.xml
    for xml_file in ['content.xml', 'styles.xml']:
        xml_path = os.path.join(tmp_dir, xml_file)
        if os.path.exists(xml_path):
            with open(xml_path, 'r', encoding='utf-8') as f:
                content = f.read()
            for key, value in data.items():
                # Replace {{key}} patterns (may be split across XML tags)
                # First try simple replacement
                content = content.replace('{{' + key + '}}', str(value))
                # Also try URL-encoded variants
                content = content.replace('%7B%7B' + key + '%7D%7D', str(value))
            with open(xml_path, 'w', encoding='utf-8') as f:
                f.write(content)

    # Repack as ZIP (ODT)
    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as z:
        # mimetype must be first and uncompressed
        mimetype_path = os.path.join(tmp_dir, 'mimetype')
        if os.path.exists(mimetype_path):
            z.write(mimetype_path, 'mimetype', compress_type=zipfile.ZIP_STORED)
        for root, dirs, files in os.walk(tmp_dir):
            for file in files:
                if file == 'mimetype':
                    continue
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, tmp_dir)
                z.write(file_path, arcname)

    print(f"Created: {output_path}")
finally:
    shutil.rmtree(tmp_dir)
PYEOF

	return 0
}

# Parse create command arguments.
# Sets _CREATE_TEMPLATE, _CREATE_DATA, _CREATE_OUTPUT, _CREATE_SCRIPT in caller scope.
_create_cmd_parse_args() {
	_CREATE_TEMPLATE=""
	_CREATE_DATA=""
	_CREATE_OUTPUT=""
	_CREATE_SCRIPT=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			_CREATE_DATA="$2"
			shift 2
			;;
		--output | -o)
			_CREATE_OUTPUT="$2"
			shift 2
			;;
		--script)
			_CREATE_SCRIPT="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${_CREATE_TEMPLATE}" ]] && _CREATE_TEMPLATE="$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate template inputs and resolve output path.
# Returns 1 on validation failure.
_create_validate_template() {
	local template="$1"
	local data="$2"
	local output_ref="$3"

	if [[ -z "${template}" ]]; then
		die "Usage: create <template-file> --data <json|file> --output <file>"
	fi
	if [[ ! -f "${template}" ]]; then
		die "Template not found: ${template}"
	fi
	if [[ -z "${data}" ]]; then
		die "Data required. Use --data '{\"field\": \"value\"}' or --data fields.json"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		local ext
		ext=$(get_ext "$template")
		_output="${template%.*}-filled.${ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	return 0
}

# Fill a template file with data, dispatching by extension.
_create_fill_template() {
	local template="$1"
	local data="$2"
	local output="$3"

	local ext
	ext=$(get_ext "$template")

	log_info "Creating document from template: $(basename "$template")"

	case "${ext}" in
	odt)
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required. Run: install --standard"
		fi
		_create_fill_odt_python "$template" "$data" "$output"
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created: ${output} (${size})"
		fi
		;;
	docx)
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required. Run: install --standard"
		fi
		log_warn "DOCX template filling not yet implemented. Use ODT format."
		;;
	*)
		die "Unsupported template format: ${ext}. Use odt or docx."
		;;
	esac

	return 0
}

cmd_create() {
	_create_cmd_parse_args "$@"

	local template="${_CREATE_TEMPLATE}"
	local data="${_CREATE_DATA}"
	local output="${_CREATE_OUTPUT}"
	local script="${_CREATE_SCRIPT}"

	if [[ -n "${script}" ]]; then
		_create_run_script "${script}" "${data}" "${output}"
		return $?
	fi

	_create_validate_template "${template}" "${data}" output || return 1
	_create_fill_template "${template}" "${data}" "${output}"

	return 0
}

# ============================================================================
# Entity extraction (t1044.6)
# ============================================================================

cmd_extract_entities() {
	local input=""
	local method="auto"
	local update_frontmatter=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--method)
			method="${2:-auto}"
			shift 2
			;;
		--update-frontmatter)
			update_frontmatter=true
			shift
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			input="$1"
			shift
			;;
		esac
	done

	if [[ -z "$input" ]]; then
		die "Usage: ${SCRIPT_NAME} extract-entities <markdown-file> [--method auto|spacy|ollama|regex] [--update-frontmatter]"
	fi

	if [[ ! -f "$input" ]]; then
		die "File not found: ${input}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local extractor="${script_dir}/entity-extraction.py"

	if [[ ! -f "$extractor" ]]; then
		die "Entity extraction script not found: ${extractor}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$input" "--method" "$method")
	if [[ "$update_frontmatter" == true ]]; then
		args+=("--update-frontmatter")
	else
		args+=("--json")
	fi

	log_info "Extracting entities from: ${input} (method: ${method})"
	"$python_cmd" "$extractor" "${args[@]}"

	return $?
}

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
		case "$1" in
		--output | -o)
			output_dir="$2"
			shift 2
			;;
		--skip-contacts)
			skip_contacts=true
			shift
			;;
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${input_path}" ]] && input_path="$1"
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

# ============================================================================
# Collection manifest (_index.toon) generation
# ============================================================================

# Generate _index.toon collection manifest for an email import output directory.
# Scans .md files for YAML frontmatter, .toon contact files, and builds three
# TOON indexes: documents, threads, contacts.
cmd_generate_manifest() {
	local output_dir=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "${output_dir}" ]]; then
				output_dir="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "${output_dir}" ]]; then
		die "Usage: generate-manifest <output-dir>"
	fi

	if [[ ! -d "${output_dir}" ]]; then
		die "Directory not found: ${output_dir}"
	fi

	local index_file="${output_dir}/_index.toon"

	log_info "Generating collection manifest: ${index_file}"

	# Use the extracted generate-manifest.py script for TOON generation
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/generate-manifest.py" "${output_dir}" "${index_file}"

	local manifest_result=$?
	if [[ "${manifest_result}" -ne 0 ]]; then
		log_error "Failed to generate collection manifest"
		return 1
	fi

	log_ok "Collection manifest generated: ${index_file}"
	return 0
}

# ============================================================================
# Normalise command - Fix markdown heading hierarchy and structure
# ============================================================================

cmd_normalise() {
	local input=""
	local output=""
	local inplace=false
	local generate_pageindex=false
	local email_mode=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--inplace | -i)
			inplace=true
			shift
			;;
		--pageindex)
			generate_pageindex=true
			shift
			;;
		--email | -e)
			email_mode=true
			shift
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: normalise <input.md> [--output <file>] [--inplace] [--pageindex] [--email]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ "${inplace}" == true ]]; then
		output="${input}"
	elif [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}-normalised.md"
	fi

	if [[ "${email_mode}" == true ]]; then
		log_info "Normalising email markdown: $(basename "$input")"
	else
		log_info "Normalising markdown: $(basename "$input")"
	fi

	# Create temp file for processing
	local tmp_file
	tmp_file=$(mktemp)

	# Process the markdown file with the extracted normalise-markdown.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/normalise-markdown.py" "$input" "$tmp_file" "${email_mode}"

	# Check if processing succeeded
	if [[ ! -f "${tmp_file}" ]]; then
		die "Normalisation failed: temp file not created"
	fi

	# Move temp file to output
	mv "${tmp_file}" "${output}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		log_ok "Normalised: ${output} (${size})"

		if [[ "${inplace}" == true ]]; then
			log_info "File updated in place"
		fi
	else
		die "Normalisation failed: output file not created"
	fi

	# Generate PageIndex tree if requested
	if [[ "${generate_pageindex}" == true ]]; then
		log_info "Generating PageIndex tree..."
		cmd_pageindex "${output}"
	fi

	return 0
}

# ============================================================================
# PageIndex command - Generate .pageindex.json from markdown heading hierarchy
# ============================================================================

cmd_pageindex() {
	local input=""
	local output=""
	local source_pdf=""
	local ollama_model="llama3.2:1b"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--source-pdf)
			source_pdf="$2"
			shift 2
			;;
		--ollama-model)
			ollama_model="$2"
			shift 2
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: pageindex <input.md> [--output <file>] [--source-pdf <file>] [--ollama-model <model>]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}.pageindex.json"
	fi

	# Detect Ollama availability for LLM summaries
	local use_ollama=false
	if has_cmd ollama; then
		if ollama list 2>/dev/null | grep -q "${ollama_model%%:*}"; then
			use_ollama=true
			log_info "Ollama available — using ${ollama_model} for section summaries"
		else
			log_info "Ollama model ${ollama_model} not found — using first-sentence fallback"
		fi
	else
		log_info "Ollama not available — using first-sentence fallback for summaries"
	fi

	# Extract page count from source PDF if available
	local page_count="0"
	if [[ -n "${source_pdf}" ]] && [[ -f "${source_pdf}" ]]; then
		if has_cmd pdfinfo; then
			page_count=$(pdfinfo "${source_pdf}" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "0")
			log_info "Source PDF: ${source_pdf} (${page_count} pages)"
		fi
	fi

	log_info "Generating PageIndex: $(basename "$input") -> $(basename "$output")"

	# Generate the PageIndex JSON with the extracted pageindex-generator.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/pageindex-generator.py" \
		"$input" "$output" "${use_ollama}" "${ollama_model}" "${source_pdf}" "${page_count}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		local node_count
		node_count=$(python3 -c "
import json, sys
def count_nodes(node):
    c = 1
    for child in node.get('children', []):
        c += count_nodes(child)
    return c
with open(sys.argv[1]) as f:
    data = json.load(f)
print(count_nodes(data.get('tree', {})))
" "${output}" 2>/dev/null || echo "?")
		log_ok "PageIndex created: ${output} (${size}, ${node_count} nodes)"
	else
		die "PageIndex generation failed: output file not created"
	fi

	return 0
}

# ============================================================================
# Add related docs (t1044.11)
# ============================================================================

cmd_add_related_docs() {
	local input="${1:-}"
	local directory=""
	local update_all=false
	local dry_run=false

	# Parse arguments
	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--directory | -d)
			directory="$2"
			shift 2
			;;
		--update-all)
			update_all=true
			shift
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			die "Usage: ${SCRIPT_NAME} add-related-docs <file|directory> [--directory <dir>] [--update-all] [--dry-run]"
			;;
		esac
	done

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/add-related-docs.py"

	if [[ ! -f "$linker" ]]; then
		die "Related docs script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	# Check for PyYAML
	if ! "$python_cmd" -c "import yaml" 2>/dev/null; then
		log_warn "PyYAML not installed. Installing..."
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet PyYAML
	fi

	local args=()
	if [[ -n "$input" ]]; then
		args+=("$input")
	fi
	if [[ -n "$directory" ]]; then
		args+=("--directory" "$directory")
	fi
	if [[ "$update_all" == true ]]; then
		args+=("--update-all")
	fi
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Adding related_docs to markdown files..."
	"$python_cmd" "$linker" "${args[@]}"

	return 0
}

# ============================================================================
# Cross-document linking (t1049.11)
# ============================================================================

cmd_link_documents() {
	local directory=""
	local dry_run=false
	local min_shared=2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--min-shared-entities)
			min_shared="${2:-2}"
			shift 2
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			directory="$1"
			shift
			;;
		esac
	done

	if [[ -z "$directory" ]]; then
		die "Usage: ${SCRIPT_NAME} link-documents <directory> [--dry-run] [--min-shared-entities N]"
	fi

	if [[ ! -d "$directory" ]]; then
		die "Directory not found: ${directory}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/cross-document-linking.py"

	if [[ ! -f "$linker" ]]; then
		die "Cross-document linking script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$directory" "--min-shared-entities" "$min_shared")
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Building cross-document links in: ${directory}"
	"$python_cmd" "$linker" "${args[@]}"

	return $?
}

# ============================================================================
# Help
# ============================================================================

cmd_help() {
	printf '%b%s%b - Document format conversion and creation\n\n' "${BOLD}" "${SCRIPT_NAME}" "${NC}"
	printf "Usage: %s <command> [options]\n\n" "${SCRIPT_NAME}"
	printf '%b\n' "${BOLD}Commands:${NC}"
	printf "  convert           Convert between document formats\n"
	printf "  import-emails     Batch import .eml directory or mbox file to markdown\n"
	printf "  create            Create a document from a template + data\n"
	printf "  template          Manage document templates (list, draft)\n"
	printf "  normalise         Fix markdown heading hierarchy and structure\n"
	printf "  pageindex         Generate .pageindex.json tree from markdown headings\n"
	printf "  extract-entities  Extract named entities from markdown (t1044.6)\n"
	printf "  generate-manifest Generate collection manifest (_index.toon) (t1044.9)\n"
	printf "  add-related-docs  Add related_docs frontmatter and navigation links (t1044.11)\n"
	printf "  enforce-frontmatter Enforce YAML frontmatter on markdown files\n"
	printf "  link-documents    Add cross-document links to email collection (t1049.11)\n"
	printf "  install           Install conversion tools (--minimal, --standard, --full, --ocr)\n"
	printf "  formats           Show supported format conversions\n"
	printf "  status            Show installed tools and availability\n"
	printf "  help              Show this help\n"
	printf '\n%b\n' "${BOLD}Examples:${NC}"
	printf "  %s convert report.pdf --to odt\n" "${SCRIPT_NAME}"
	printf "  %s convert letter.odt --to pdf\n" "${SCRIPT_NAME}"
	printf "  %s convert notes.md --to docx\n" "${SCRIPT_NAME}"
	printf "  %s convert email.eml --to md\n" "${SCRIPT_NAME}"
	printf "  %s convert message.msg --to md\n" "${SCRIPT_NAME}"
	printf "  %s import-emails ~/Mail/inbox/ --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s import-emails archive.mbox --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported\n" "${SCRIPT_NAME}"
	printf "  %s convert scanned.pdf --to odt --ocr tesseract\n" "${SCRIPT_NAME}"
	printf "  %s convert screenshot.png --to md --ocr auto\n" "${SCRIPT_NAME}"
	printf "  %s convert report.pdf --to md --no-normalise\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --output clean.md\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --inplace --pageindex\n" "${SCRIPT_NAME}"
	printf "  %s normalise email.md --inplace --email\n" "${SCRIPT_NAME}"
	printf "  %s pageindex document.md --source-pdf original.pdf\n" "${SCRIPT_NAME}"
	printf "  %s create template.odt --data fields.json -o letter.odt\n" "${SCRIPT_NAME}"
	printf "  %s template draft --type letter --format odt\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --update-frontmatter\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --method spacy --json\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported-emails\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./emails -o manifest.toon\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs email.md\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs --directory ./emails --update-all\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --min-shared-entities 3\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --dry-run\n" "${SCRIPT_NAME}"
	printf "  %s install --standard\n" "${SCRIPT_NAME}"
	printf "  %s install --ocr\n" "${SCRIPT_NAME}"
	printf "\nSee: tools/document/document-creation.md for full documentation.\n"
	printf "\nNote: Markdown conversions are automatically normalised unless --no-normalise is specified.\n"

	return 0
}

# ============================================================================
# Main dispatch
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "${cmd}" in
	convert) cmd_convert "$@" ;;
	import-emails) cmd_import_emails "$@" ;;
	generate-manifest) cmd_generate_manifest "$@" ;;
	create) cmd_create "$@" ;;
	template) cmd_template "$@" ;;
	normalise | normalize) cmd_normalise "$@" ;;
	extract-entities) cmd_extract_entities "$@" ;;
	pageindex) cmd_pageindex "$@" ;;
	add-related-docs) cmd_add_related_docs "$@" ;;
	enforce-frontmatter | frontmatter) "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/frontmatter-helper.sh" "$@" ;;
	link-documents) cmd_link_documents "$@" ;;
	install) cmd_install "$@" ;;
	formats) cmd_formats ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
