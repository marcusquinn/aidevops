#!/usr/bin/env bash
# document-creation-helper.sh - Unified document format conversion and creation
# Part of aidevops framework: https://aidevops.sh
#
# Usage: document-creation-helper.sh <command> [options]
# Commands: convert, create, template, install, formats, status, help

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

# Get file extension (lowercase)
get_ext() {
	local file="$1"
	local ext="${file##*.}"
	printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

# Activate Python venv if it exists
activate_venv() {
	if [[ -f "${VENV_DIR}/bin/activate" ]]; then
		# shellcheck disable=SC1091
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

detect_tools() {
	local tools_available=()
	local tools_missing=()

	# Tier 1: Minimal
	if has_cmd pandoc; then
		tools_available+=("pandoc")
	else
		tools_missing+=("pandoc")
	fi

	if has_cmd pdftotext; then
		tools_available+=("poppler")
	else
		tools_missing+=("poppler")
	fi

	# Tier 2: Standard (Python libs)
	if has_python_pkg odf 2>/dev/null; then
		tools_available+=("odfpy")
	else
		tools_missing+=("odfpy")
	fi

	if has_python_pkg docx 2>/dev/null; then
		tools_available+=("python-docx")
	else
		tools_missing+=("python-docx")
	fi

	if has_python_pkg openpyxl 2>/dev/null; then
		tools_available+=("openpyxl")
	else
		tools_missing+=("openpyxl")
	fi

	# Tier 3: Full
	if has_cmd soffice || has_cmd libreoffice; then
		tools_available+=("libreoffice")
	else
		tools_missing+=("libreoffice")
	fi

	# Tier 3: Full
	# (already checked above)

	# OCR tools
	if has_cmd tesseract; then
		tools_available+=("tesseract")
	else
		tools_missing+=("tesseract")
	fi

	if has_python_pkg easyocr 2>/dev/null; then
		tools_available+=("easyocr")
	else
		tools_missing+=("easyocr")
	fi

	if has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
		tools_available+=("glm-ocr")
	else
		tools_missing+=("glm-ocr")
	fi

	# Specialist tools
	if has_cmd mineru; then
		tools_available+=("mineru")
	else
		tools_missing+=("mineru")
	fi

	# Advanced conversion providers
	if has_reader_lm; then
		tools_available+=("reader-lm")
	else
		tools_missing+=("reader-lm")
	fi

	if has_rolm_ocr; then
		tools_available+=("rolm-ocr")
	else
		tools_missing+=("rolm-ocr")
	fi

	printf '%s\n' "AVAILABLE:${tools_available[*]:-none}"
	printf '%s\n' "MISSING:${tools_missing[*]:-none}"
}

# ============================================================================
# Status command
# ============================================================================

cmd_status() {
	printf "${BOLD}Document Conversion Tools Status${NC}\n\n"

	printf "${BOLD}Tier 1 - Minimal (text conversions):${NC}\n"
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

	printf "\n${BOLD}Tier 2 - Standard (programmatic creation):${NC}\n"
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

	printf "\n${BOLD}Tier 3 - Full (highest fidelity):${NC}\n"
	if has_cmd soffice || has_cmd libreoffice; then
		local lo_version
		lo_version=$(soffice --version 2>/dev/null || libreoffice --version 2>/dev/null || echo "unknown")
		log_ok "LibreOffice headless (${lo_version})"
	else
		log_warn "LibreOffice - NOT INSTALLED (brew install --cask libreoffice)"
	fi

	printf "\n${BOLD}OCR tools:${NC}\n"
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

	printf "\n${BOLD}Specialist tools:${NC}\n"
	if has_cmd mineru; then
		log_ok "MinerU (layout-aware PDF to markdown)"
	else
		log_info "MinerU - not installed (optional: pip install 'mineru[all]')"
	fi

	printf "\n${BOLD}Advanced conversion providers:${NC}\n"
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
# Install command
# ============================================================================

cmd_install() {
	local tier="${1:-}"
	local tool="${2:-}"

	case "${tier}" in
	--minimal)
		log_info "Installing Tier 1: pandoc + poppler"
		if [[ "$(uname)" == "Darwin" ]]; then
			brew install pandoc poppler 2>&1 || true
		elif has_cmd apt-get; then
			sudo apt-get update && sudo apt-get install -y pandoc poppler-utils
		else
			die "Unsupported platform. Install pandoc and poppler manually."
		fi
		log_ok "Tier 1 installed"
		;;
	--standard)
		log_info "Installing Tier 2: Python libraries"
		# Ensure Tier 1 first
		if ! has_cmd pandoc; then
			log_info "Installing Tier 1 first..."
			cmd_install --minimal
		fi
		# Create venv
		if [[ ! -d "${VENV_DIR}" ]]; then
			log_info "Creating Python venv at ${VENV_DIR}"
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet odfpy python-docx openpyxl
		log_ok "Tier 2 installed (odfpy, python-docx, openpyxl)"
		;;
	--full)
		log_info "Installing Tier 3: LibreOffice headless"
		# Ensure Tier 1 + 2 first
		if ! has_python_pkg odf 2>/dev/null; then
			cmd_install --standard
		fi
		if [[ "$(uname)" == "Darwin" ]]; then
			brew install --cask libreoffice 2>&1 || true
		elif has_cmd apt-get; then
			sudo apt-get update && sudo apt-get install -y libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress
		else
			die "Unsupported platform. Install LibreOffice manually."
		fi
		log_ok "Tier 3 installed"
		;;
	--ocr)
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
		;;
	--tool)
		if [[ -z "${tool}" ]]; then
			die "Usage: install --tool <name> (pandoc|poppler|odfpy|python-docx|openpyxl|libreoffice|mineru|tesseract|easyocr|glm-ocr)"
		fi
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
	printf "${BOLD}Supported Format Conversions${NC}\n\n"

	printf "${BOLD}Input formats:${NC}\n"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  Email:          eml, msg (with attachment extraction)\n"
	printf "  PDF:            pdf (text extraction + image extraction)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"
	printf "  Data:           json, xml, rst, org\n"

	printf "\n${BOLD}Output formats:${NC}\n"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  PDF:            pdf (via pandoc+engine or LibreOffice)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"

	printf "\n${BOLD}Best quality paths:${NC}\n"
	printf "  eml/msg -> md:    email-to-markdown.py (extracts attachments)\n"
	printf "  odt/docx -> pdf:  LibreOffice headless (preserves layout)\n"
	printf "  md -> docx/odt:   pandoc (excellent)\n"
	printf "  pdf -> md:        MinerU (complex) or pandoc (simple)\n"
	printf "  pdf -> odt:       odfpy + poppler (programmatic rebuild)\n"
	printf "  xlsx <-> ods:     LibreOffice headless\n"

	return 0
}

# ============================================================================
# Convert command
# ============================================================================

select_tool() {
	local from_ext="$1"
	local to_ext="$2"
	local force_tool="${3:-}"

	# If user forced a tool, use it
	if [[ -n "${force_tool}" ]]; then
		printf '%s' "${force_tool}"
		return 0
	fi

	# PDF source requires special handling
	if [[ "${from_ext}" == "pdf" ]]; then
		case "${to_ext}" in
		md | markdown)
			# Prefer RolmOCR for GPU-accelerated PDF->md with table preservation
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
	fi

	# Presentation conversions: prefer LibreOffice
	if [[ "${from_ext}" =~ ^(pptx|odp|ppt)$ ]] || [[ "${to_ext}" =~ ^(pptx|odp|ppt)$ ]]; then
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
	fi

	# HTML to markdown: prefer Reader-LM for table preservation
	if [[ "${from_ext}" == "html" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]]; then
		if has_reader_lm; then
			printf 'reader-lm'
		elif has_cmd pandoc; then
			printf 'pandoc'
		else
			die "No tool available for html->md. Run: install --minimal (pandoc) or ollama pull reader-lm"
		fi
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
		size=$(ls -lh "$output" | awk '{print $5}')
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
		size=$(ls -lh "${output_file}" | awk '{print $5}')
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
		size=$(ls -lh "$output" | awk '{print $5}')
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
		size=$(ls -lh "$output" | awk '{print $5}')
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
			size=$(ls -lh "$output" | awk '{print $5}')
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

	# Run the parser
	python3 "${script_path}" "$input" --output "$output" --attachments-dir "$attachments_dir"

	if [[ -f "$output" ]]; then
		local size
		size=$(ls -lh "$output" | awk '{print $5}')
		log_ok "Created: ${output} (${size})"
		if [[ -d "$attachments_dir" ]]; then
			local att_count
			att_count=$(find "$attachments_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${att_count}" -gt 0 ]]; then
				log_ok "Extracted ${att_count} attachment(s) to: ${attachments_dir}"
			fi
		fi
	else
		die "Email conversion failed: output file not created"
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

	# Parse arguments
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
		--ocr)
			ocr_provider="${2:-auto}"
			shift
			# Only shift again if next arg is not a flag
			if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then
				ocr_provider="$1"
				shift
			fi
			;;
		--no-normalise)
			run_normalise=false
			shift
			;;
		--*)
			extra_args="${extra_args} $1"
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
		die "Usage: convert <input-file> --to <format> [--output <file>] [--tool <name>]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	if [[ -z "${to_ext}" ]]; then
		die "Target format required. Use --to <format> (e.g., --to pdf, --to odt)"
	fi

	# Normalise format names
	case "${to_ext}" in
	markdown) to_ext="md" ;;
	text) to_ext="txt" ;;
	esac

	# Determine output path
	if [[ -z "${output}" ]]; then
		local basename_noext
		basename_noext="${input%.*}"
		output="${basename_noext}.${to_ext}"
	fi

	# Get input extension
	local from_ext
	from_ext=$(get_ext "$input")

	# Same format check
	if [[ "${from_ext}" == "${to_ext}" ]]; then
		die "Input and output formats are the same: ${from_ext}"
	fi

	# OCR pre-processing: handle scanned PDFs and images
	if [[ -n "${ocr_provider}" ]] || { [[ "${from_ext}" == "pdf" ]] && is_scanned_pdf "$input"; }; then
		if [[ -z "${ocr_provider}" ]]; then
			ocr_provider="auto"
			log_info "Scanned PDF detected -- activating OCR"
		fi

		local provider
		provider=$(select_ocr_provider "${ocr_provider}")

		# Use workspace dir for temp files (avoids macOS /tmp sandbox issues)
		local ocr_work="${HOME}/.aidevops/.agent-workspace/tmp"
		mkdir -p "$ocr_work"

		if [[ "${from_ext}" == "pdf" ]]; then
			# OCR the scanned PDF pages, then convert the extracted text
			local ocr_text="${ocr_work}/ocr-text-$$.txt"
			ocr_scanned_pdf "$input" "$provider" "$ocr_text"
			# Replace input with the OCR text for downstream conversion
			input="$ocr_text"
			from_ext="txt"
			log_info "Proceeding with OCR text as input"
		elif [[ "${from_ext}" =~ ^(png|jpg|jpeg|tiff|tif|bmp|webp)$ ]]; then
			# OCR an image file directly
			local ocr_text="${ocr_work}/ocr-text-$$.txt"
			log_info "Running OCR on image with ${provider}..."
			run_ocr "$input" "$provider" >"$ocr_text"
			local text_len
			text_len=$(wc -c <"$ocr_text" | tr -d ' ')
			log_ok "OCR extracted ${text_len} bytes from image"
			input="$ocr_text"
			from_ext="txt"
		fi
	fi

	# Select tool
	local tool
	tool=$(select_tool "${from_ext}" "${to_ext}" "${force_tool}")

	# Execute conversion
	case "${tool}" in
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
			size=$(ls -lh "$output" | awk '{print $5}')
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
	email-parser)
		convert_email "$input" "$output"
		;;
	*)
		die "Unknown tool: ${tool}"
		;;
	esac

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

cmd_template() {
	local subcmd="${1:-}"
	shift || true

	case "${subcmd}" in
	list)
		printf "${BOLD}Stored Templates${NC}\n\n"
		if [[ -d "${TEMPLATE_DIR}" ]]; then
			find "${TEMPLATE_DIR}" -type f | while read -r f; do
				local rel="${f#"${TEMPLATE_DIR}/"}"
				local size
				size=$(ls -lh "$f" | awk '{print $5}')
				printf "  %s (%s)\n" "$rel" "$size"
			done
		else
			log_info "No templates stored yet."
			log_info "Directory: ${TEMPLATE_DIR}"
		fi
		;;
	draft)
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

		# Determine output path
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

			# Generate ODT template with Python
			python3 - "$output" "$doc_type" "$fields" "$header_logo" "$footer_text" <<'PYEOF'
import sys
import os
from odf.opendocument import OpenDocumentText
from odf.style import Style, MasterPage, PageLayout, PageLayoutProperties
from odf.style import TextProperties, ParagraphProperties, GraphicProperties
from odf.style import Header as StyleHeader, Footer as StyleFooter
from odf.style import FontFace, HeaderStyle, FooterStyle
from odf.text import P, PageNumber, PageCount
from odf.draw import Frame, Image
from odf import dc

output_path = sys.argv[1]
doc_type = sys.argv[2]
fields_str = sys.argv[3] if len(sys.argv) > 3 else ""
header_logo = sys.argv[4] if len(sys.argv) > 4 else ""
footer_text = sys.argv[5] if len(sys.argv) > 5 else ""

fields = [f.strip() for f in fields_str.split(",") if f.strip()] if fields_str else []

doc = OpenDocumentText()

# Font
ff = FontFace(attributes={
    "name": "Arial",
    "fontfamily": "Arial",
    "fontfamilygeneric": "swiss",
    "fontpitch": "variable",
})
doc.fontfacedecls.addElement(ff)

# Page layout
pl = PageLayout(name="ContentLayout")
pl.addElement(PageLayoutProperties(
    pagewidth="21.001cm", pageheight="29.7cm",
    margintop="2.5cm", marginbottom="3cm",
    marginleft="2cm", marginright="2cm",
    printorientation="portrait",
))
pl.addElement(HeaderStyle())
pl.addElement(FooterStyle())
doc.automaticstyles.addElement(pl)

# Styles
heading = Style(name="Heading", family="paragraph")
heading.addElement(TextProperties(fontname="Arial", fontsize="14pt", fontweight="bold"))
heading.addElement(ParagraphProperties(marginbottom="0.3cm", margintop="0.5cm"))
doc.styles.addElement(heading)

body = Style(name="Body", family="paragraph")
body.addElement(TextProperties(fontname="Arial", fontsize="11pt"))
body.addElement(ParagraphProperties(lineheight="150%", marginbottom="0.3cm", textalign="justify"))
doc.styles.addElement(body)

placeholder = Style(name="Placeholder", family="paragraph")
placeholder.addElement(TextProperties(fontname="Arial", fontsize="11pt", color="#cc0000"))
placeholder.addElement(ParagraphProperties(lineheight="150%", marginbottom="0.3cm"))
doc.styles.addElement(placeholder)

footer_s = Style(name="FooterText", family="paragraph")
footer_s.addElement(TextProperties(fontname="Arial", fontsize="7pt", color="#888888"))
footer_s.addElement(ParagraphProperties(textalign="center", lineheight="120%"))
doc.styles.addElement(footer_s)

footer_pg = Style(name="FooterPage", family="paragraph")
footer_pg.addElement(TextProperties(fontname="Arial", fontsize="9pt", color="#666666"))
footer_pg.addElement(ParagraphProperties(textalign="center"))
doc.styles.addElement(footer_pg)

header_s = Style(name="HeaderPara", family="paragraph")
header_s.addElement(ParagraphProperties(textalign="end"))
doc.styles.addElement(header_s)

img_style = Style(name="ImgFrame", family="graphic")
img_style.addElement(GraphicProperties(
    verticalpos="top", verticalrel="paragraph",
    horizontalpos="center", horizontalrel="paragraph",
    wrap="none",
))
doc.automaticstyles.addElement(img_style)

# Master page with header/footer
master = MasterPage(name="Standard", pagelayoutname="ContentLayout")

# Header
header = StyleHeader()
hp = P(stylename="HeaderPara")
if header_logo and os.path.isfile(header_logo):
    href = doc.addPicture(header_logo)
    frame = Frame(stylename=img_style, width="4.5cm", height="1.13cm", anchortype="as-char")
    frame.addElement(Image(href=href))
    hp.addElement(frame)
else:
    hp.addText("{{header_logo}}")
header.addElement(hp)
master.addElement(header)

# Footer
footer = StyleFooter()
fp1 = P(stylename="FooterPage")
fp1.addText("Page ")
fp1.addElement(PageNumber(selectpage="current"))
fp1.addText(" of ")
fp1.addElement(PageCount())
footer.addElement(fp1)
if footer_text:
    fp2 = P(stylename="FooterText")
    fp2.addText(footer_text)
    footer.addElement(fp2)
else:
    fp2 = P(stylename="FooterText")
    fp2.addText("{{footer_text}}")
    footer.addElement(fp2)
master.addElement(footer)
doc.masterstyles.addElement(master)

# Content: title + placeholder fields
title_s = Style(name="TitlePara", family="paragraph", masterpagename="Standard")
title_s.addElement(TextProperties(fontname="Arial", fontsize="18pt", fontweight="bold"))
title_s.addElement(ParagraphProperties(textalign="center", marginbottom="1cm", breakbefore="page"))
doc.automaticstyles.addElement(title_s)

p = P(stylename="TitlePara")
p.addText("{{title}}")
doc.text.addElement(p)

doc.text.addElement(P(stylename="Body"))

# Add placeholder fields
if fields:
    for field in fields:
        p = P(stylename="Placeholder")
        p.addText("{{" + field + "}}")
        doc.text.addElement(p)
else:
    # Default fields based on document type
    defaults = {
        "letter": ["date", "recipient_name", "recipient_address", "subject", "body", "signoff", "author"],
        "report": ["title", "author", "date", "summary", "body"],
        "invoice": ["invoice_number", "date", "client_name", "client_address", "items", "subtotal", "vat", "total"],
        "statement": ["title", "property_name", "property_address", "date", "author", "body"],
    }
    for field in defaults.get(doc_type, ["title", "date", "author", "body"]):
        p = P(stylename="Placeholder")
        p.addText("{{" + field + "}}")
        doc.text.addElement(p)

# Metadata
doc.meta.addElement(dc.Title(text=f"{doc_type.title()} Template"))
doc.meta.addElement(dc.Description(text=f"Draft template for {doc_type} documents. Replace {{{{placeholders}}}} with actual content."))

doc.save(output_path)
print(f"Template saved: {output_path}")
PYEOF
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

cmd_create() {
	local template=""
	local data=""
	local output=""
	local script=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			data="$2"
			shift 2
			;;
		--output | -o)
			output="$2"
			shift 2
			;;
		--script)
			script="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			if [[ -z "${template}" ]]; then
				template="$1"
			fi
			shift
			;;
		esac
	done

	# Script mode: delegate to a Python script
	if [[ -n "${script}" ]]; then
		if [[ ! -f "${script}" ]]; then
			die "Script not found: ${script}"
		fi
		log_info "Running creation script: ${script}"
		if activate_venv 2>/dev/null; then
			python3 "${script}" ${data:+--data "$data"} ${output:+--output "$output"}
		else
			python3 "${script}" ${data:+--data "$data"} ${output:+--output "$output"}
		fi
		return $?
	fi

	# Template mode
	if [[ -z "${template}" ]]; then
		die "Usage: create <template-file> --data <json|file> --output <file>"
	fi

	if [[ ! -f "${template}" ]]; then
		die "Template not found: ${template}"
	fi

	if [[ -z "${data}" ]]; then
		die "Data required. Use --data '{\"field\": \"value\"}' or --data fields.json"
	fi

	if [[ -z "${output}" ]]; then
		local ext
		ext=$(get_ext "$template")
		output="${template%.*}-filled.${ext}"
	fi

	local ext
	ext=$(get_ext "$template")

	log_info "Creating document from template: $(basename "$template")"

	case "${ext}" in
	odt)
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required. Run: install --standard"
		fi

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
		if [[ -f "$output" ]]; then
			local size
			size=$(ls -lh "$output" | awk '{print $5}')
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
# Help
# ============================================================================

cmd_help() {
	printf "${BOLD}%s${NC} - Document format conversion and creation\n\n" "${SCRIPT_NAME}"
	printf "Usage: %s <command> [options]\n\n" "${SCRIPT_NAME}"
	printf "${BOLD}Commands:${NC}\n"
	printf "  convert           Convert between document formats\n"
	printf "  create            Create a document from a template + data\n"
	printf "  template          Manage document templates (list, draft)\n"
	printf "  extract-entities  Extract named entities from markdown (t1044.6)\n"
	printf "  install           Install conversion tools (--minimal, --standard, --full, --ocr)\n"
	printf "  formats           Show supported format conversions\n"
	printf "  status            Show installed tools and availability\n"
	printf "  help              Show this help\n"
	printf "\n${BOLD}Examples:${NC}\n"
	printf "  %s convert report.pdf --to odt\n" "${SCRIPT_NAME}"
	printf "  %s convert letter.odt --to pdf\n" "${SCRIPT_NAME}"
	printf "  %s convert notes.md --to docx\n" "${SCRIPT_NAME}"
	printf "  %s convert scanned.pdf --to odt --ocr tesseract\n" "${SCRIPT_NAME}"
	printf "  %s convert screenshot.png --to md --ocr auto\n" "${SCRIPT_NAME}"
	printf "  %s convert report.pdf --to md --no-normalise\n" "${SCRIPT_NAME}"
	printf "  %s create template.odt --data fields.json -o letter.odt\n" "${SCRIPT_NAME}"
	printf "  %s template draft --type letter --format odt\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --update-frontmatter\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --method spacy --json\n" "${SCRIPT_NAME}"
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
	create) cmd_create "$@" ;;
	template) cmd_template "$@" ;;
	extract-entities) cmd_extract_entities "$@" ;;
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
