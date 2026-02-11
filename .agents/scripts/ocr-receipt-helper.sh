#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# OCR Receipt/Invoice Extraction Helper for AI DevOps Framework
# Extracts structured data from receipts and invoices, with optional QuickFile integration
#
# Usage: ocr-receipt-helper.sh [command] [options]
#
# Commands:
#   scan <file>         OCR a receipt/invoice image or PDF (GLM-OCR via Ollama)
#   extract <file>      Structured extraction with Pydantic schema (Docling + ExtractThinker)
#   batch <dir>         Batch process a directory of receipts/invoices
#   quickfile <file>    Extract and create QuickFile purchase invoice
#   preview <file>      Extract and show what would be sent to QuickFile (dry run)
#   status              Check installed OCR/extraction components
#   install             Install OCR dependencies (GLM-OCR model via Ollama)
#   help                Show this help
#
# Options:
#   --type <invoice|receipt>   Document type (default: auto-detect)
#   --privacy <mode>           Privacy mode: local, edge, cloud, none (default: local)
#   --output <format>          Output format: json, text, markdown (default: json)
#   --supplier <name>          Override supplier name for QuickFile
#   --nominal <code>           QuickFile nominal code (default: 7901 - General Purchases)
#   --currency <code>          Currency code (default: GBP)
#   --vat-rate <rate>          VAT rate percentage (default: 20)
#
# Author: AI DevOps Framework
# Version: 2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly OCR_MODEL="glm-ocr"
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/work/ocr-receipts"
readonly VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-extraction"
readonly PIPELINE_PY="${SCRIPT_DIR}/extraction_pipeline.py"
readonly DEFAULT_NOMINAL_CODE="7901"
readonly DEFAULT_CURRENCY="GBP"
readonly DEFAULT_VAT_RATE="20"

# Ensure workspace exists
ensure_workspace() {
    mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true
    return 0
}

# Check if Ollama is running and GLM-OCR model is available
check_ollama() {
    if ! command -v ollama &>/dev/null; then
        print_error "Ollama is not installed. Run: brew install ollama"
        return 1
    fi

    if ! ollama list 2>/dev/null | grep -q "${OCR_MODEL}"; then
        print_error "GLM-OCR model not found. Run: ocr-receipt-helper.sh install"
        return 1
    fi

    return 0
}

# Check if document-extraction venv is available
check_extraction_venv() {
    if [[ -d "${VENV_DIR}/bin" ]]; then
        return 0
    fi
    print_error "Document extraction venv not found at ${VENV_DIR}"
    print_info "Run: document-extraction-helper.sh install --core"
    return 1
}

# Activate the document-extraction venv
activate_venv() {
    if [[ -d "${VENV_DIR}/bin" ]]; then
        # shellcheck disable=SC1091
        source "${VENV_DIR}/bin/activate"
        return 0
    fi
    return 1
}

# Detect file type (image vs PDF vs document)
detect_file_type() {
    local file="$1"
    local ext="${file##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

    case "$ext" in
        png|jpg|jpeg|tiff|bmp|webp|heic)
            echo "image"
            ;;
        pdf)
            echo "pdf"
            ;;
        docx|xlsx|pptx|html|htm)
            echo "document"
            ;;
        *)
            echo "unknown"
            ;;
    esac
    return 0
}

# Auto-detect document type (invoice vs receipt) from OCR text
detect_document_type() {
    local text="$1"
    local lower_text
    lower_text="$(echo "$text" | tr '[:upper:]' '[:lower:]')"

    # Invoice indicators: invoice number, due date, payment terms, PO number
    local invoice_score=0
    if echo "$lower_text" | grep -qE "invoice\s*(no|number|#|:)"; then
        invoice_score=$((invoice_score + 3))
    fi
    if echo "$lower_text" | grep -qE "due\s*date|payment\s*terms|net\s*[0-9]+"; then
        invoice_score=$((invoice_score + 2))
    fi
    if echo "$lower_text" | grep -qE "purchase\s*order|p\.?o\.?\s*(no|number|#)"; then
        invoice_score=$((invoice_score + 2))
    fi
    if echo "$lower_text" | grep -qE "bill\s*to|ship\s*to|remit\s*to"; then
        invoice_score=$((invoice_score + 1))
    fi

    # Receipt indicators: receipt, cash, card, change, thank you
    local receipt_score=0
    if echo "$lower_text" | grep -qE "receipt|till|register"; then
        receipt_score=$((receipt_score + 3))
    fi
    if echo "$lower_text" | grep -qE "cash|card|visa|mastercard|amex|contactless|chip"; then
        receipt_score=$((receipt_score + 2))
    fi
    if echo "$lower_text" | grep -qE "change\s*due|thank\s*you|have\s*a\s*nice"; then
        receipt_score=$((receipt_score + 2))
    fi
    if echo "$lower_text" | grep -qE "subtotal|sub\s*total"; then
        receipt_score=$((receipt_score + 1))
    fi

    if [[ "$invoice_score" -gt "$receipt_score" ]]; then
        echo "invoice"
    elif [[ "$receipt_score" -gt "$invoice_score" ]]; then
        echo "receipt"
    else
        # Default to invoice (more structured, safer assumption)
        echo "invoice"
    fi
    return 0
}

# OCR scan using GLM-OCR via Ollama
cmd_scan() {
    local input_file="$1"
    local output_format="${2:-text}"

    validate_file_exists "$input_file" "Input file" || return 1
    check_ollama || return 1
    ensure_workspace

    local file_type
    file_type="$(detect_file_type "$input_file")"

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"

    case "$file_type" in
        image)
            print_info "OCR scanning image: ${input_file}"
            local ocr_text
            ocr_text="$(ollama run "$OCR_MODEL" "Extract all text from this receipt or invoice exactly as written. Include all amounts, dates, item descriptions, and totals." --images "$input_file" 2>/dev/null)" || {
                print_error "OCR scan failed"
                return 1
            }
            ;;
        pdf)
            print_info "OCR scanning PDF: ${input_file} (converting pages to images first)"
            if ! command -v magick &>/dev/null && ! command -v convert &>/dev/null; then
                print_error "ImageMagick required for PDF OCR. Install: brew install imagemagick"
                return 1
            fi

            local tmp_dir
            tmp_dir="$(mktemp -d)"
            # Use magick (ImageMagick 7) or convert (ImageMagick 6)
            if command -v magick &>/dev/null; then
                magick -density 300 "$input_file" -quality 90 "${tmp_dir}/page-%03d.png" 2>/dev/null || {
                    print_error "PDF to image conversion failed"
                    rm -rf "$tmp_dir"
                    return 1
                }
            else
                convert -density 300 "$input_file" -quality 90 "${tmp_dir}/page-%03d.png" 2>/dev/null || {
                    print_error "PDF to image conversion failed"
                    rm -rf "$tmp_dir"
                    return 1
                }
            fi

            local ocr_text=""
            local page_num=0
            for page in "${tmp_dir}"/page-*.png; do
                [[ -f "$page" ]] || continue
                page_num=$((page_num + 1))
                print_info "  OCR page ${page_num}..."
                local page_text
                page_text="$(ollama run "$OCR_MODEL" "Extract all text from this receipt or invoice exactly as written." --images "$page" 2>/dev/null)" || continue
                if [[ -n "$ocr_text" ]]; then
                    ocr_text="${ocr_text}\n\n--- Page ${page_num} ---\n\n${page_text}"
                else
                    ocr_text="$page_text"
                fi
            done
            rm -rf "$tmp_dir"

            if [[ -z "$ocr_text" ]]; then
                print_error "No text extracted from PDF"
                return 1
            fi
            ;;
        document)
            print_info "For document files, use: document-extraction-helper.sh extract ${input_file}"
            print_info "Or use: ocr-receipt-helper.sh extract ${input_file} (structured extraction)"
            return 1
            ;;
        *)
            print_error "Unsupported file type: ${input_file}"
            return 1
            ;;
    esac

    # Output
    case "$output_format" in
        text)
            echo "$ocr_text"
            ;;
        json)
            local doc_type
            doc_type="$(detect_document_type "$ocr_text")"
            local output_file="${WORKSPACE_DIR}/${basename}-ocr.json"
            printf '{\n  "source_file": "%s",\n  "detected_type": "%s",\n  "ocr_text": %s\n}\n' \
                "$input_file" "$doc_type" "$(echo "$ocr_text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
                > "$output_file"
            print_success "OCR output: ${output_file}"
            echo "$ocr_text"
            ;;
        markdown)
            local doc_type
            doc_type="$(detect_document_type "$ocr_text")"
            echo "# OCR Scan: ${basename}"
            echo ""
            echo "**Source**: ${input_file}"
            echo "**Detected type**: ${doc_type}"
            echo ""
            echo "## Extracted Text"
            echo ""
            echo "$ocr_text"
            ;;
    esac

    return 0
}

# Structured extraction using Docling + ExtractThinker
cmd_extract() {
    local input_file="$1"
    local doc_type="${2:-auto}"
    local privacy="${3:-local}"
    local output_format="${4:-json}"

    validate_file_exists "$input_file" "Input file" || return 1
    ensure_workspace

    local file_type
    file_type="$(detect_file_type "$input_file")"

    # For images, use GLM-OCR first then parse the text with LLM
    if [[ "$file_type" == "image" ]]; then
        check_ollama || return 1
        print_info "Step 1/2: OCR scanning image..."
        local ocr_text
        ocr_text="$(ollama run "$OCR_MODEL" "Extract all text from this receipt or invoice exactly as written. Include all amounts, dates, item descriptions, and totals." --images "$input_file" 2>/dev/null)" || {
            print_error "OCR scan failed"
            return 1
        }

        # Auto-detect type if needed
        if [[ "$doc_type" == "auto" ]]; then
            doc_type="$(detect_document_type "$ocr_text")"
            print_info "Auto-detected document type: ${doc_type}"
        fi

        print_info "Step 2/2: Extracting structured data from OCR text..."
        extract_from_text "$ocr_text" "$doc_type" "$privacy" "$input_file"
        return $?
    fi

    # For PDFs and documents, use document-extraction-helper.sh if available
    if [[ "$file_type" == "pdf" ]] || [[ "$file_type" == "document" ]]; then
        # Auto-detect type: do a quick OCR scan first
        if [[ "$doc_type" == "auto" ]]; then
            if [[ "$file_type" == "pdf" ]] && check_ollama 2>/dev/null; then
                # Quick OCR of first page for type detection
                local tmp_dir
                tmp_dir="$(mktemp -d)"
                if command -v magick &>/dev/null; then
                    magick -density 150 "${input_file}[0]" -quality 80 "${tmp_dir}/page-000.png" 2>/dev/null
                elif command -v convert &>/dev/null; then
                    convert -density 150 "${input_file}[0]" -quality 80 "${tmp_dir}/page-000.png" 2>/dev/null
                fi
                if [[ -f "${tmp_dir}/page-000.png" ]]; then
                    local quick_text
                    quick_text="$(ollama run "$OCR_MODEL" "Extract all text" --images "${tmp_dir}/page-000.png" 2>/dev/null)" || true
                    if [[ -n "${quick_text:-}" ]]; then
                        doc_type="$(detect_document_type "$quick_text")"
                        print_info "Auto-detected document type: ${doc_type}"
                    fi
                fi
                rm -rf "$tmp_dir"
            fi
            # Fallback to invoice if detection failed
            if [[ "$doc_type" == "auto" ]]; then
                doc_type="invoice"
                print_info "Defaulting to document type: invoice"
            fi
        fi

        # Use document-extraction-helper.sh for structured extraction
        local schema_name="$doc_type"
        if [[ -x "${SCRIPT_DIR}/document-extraction-helper.sh" ]]; then
            print_info "Extracting structured data via document-extraction-helper.sh..."
            "${SCRIPT_DIR}/document-extraction-helper.sh" extract "$input_file" \
                --schema "$schema_name" --privacy "$privacy" --output "$output_format"
            return $?
        else
            print_error "document-extraction-helper.sh not found"
            print_info "Falling back to OCR scan..."
            cmd_scan "$input_file" "$output_format"
            return $?
        fi
    fi

    print_error "Unsupported file type for extraction"
    return 1
}

# Extract structured data from OCR text using an LLM
extract_from_text() {
    local ocr_text="$1"
    local doc_type="$2"
    local privacy="$3"
    local source_file="${4:-unknown}"

    local basename
    basename="$(basename "$source_file" | sed 's/\.[^.]*$//')"
    local output_file="${WORKSPACE_DIR}/${basename}-extracted.json"

    # Determine LLM backend
    local llm_model
    case "$privacy" in
        local|none)
            if command -v ollama &>/dev/null; then
                llm_model="llama3.2"
            else
                print_error "Ollama required for local privacy mode"
                return 1
            fi
            ;;
        edge)
            llm_model="cloudflare"
            ;;
        cloud)
            llm_model="cloud"
            ;;
        *)
            print_error "Unknown privacy mode: ${privacy}"
            return 1
            ;;
    esac

    # Build extraction prompt based on document type (aligned with Pydantic schemas)
    local extraction_prompt
    if [[ "$doc_type" == "invoice" ]]; then
        extraction_prompt="Extract the following fields from this invoice text as JSON. Use null for missing fields.
All dates must be in YYYY-MM-DD format. All amounts must be numbers (not strings).

Fields:
- vendor_name: string (the company/person who issued the invoice)
- vendor_address: string or null
- vendor_vat_number: string or null (VAT registration number if shown)
- invoice_number: string or null
- invoice_date: string (YYYY-MM-DD format)
- due_date: string or null (YYYY-MM-DD format)
- purchase_order: string or null (PO number if referenced)
- currency: string (3-letter ISO code like GBP, USD, EUR)
- subtotal: number (total before VAT)
- vat_amount: number (VAT/tax amount, 0 if none)
- total: number (total including VAT)
- line_items: array of {description: string, quantity: number, unit_price: number, amount: number, vat_rate: string}
- payment_terms: string or null (e.g. 'Net 30', '14 days')
- document_type: \"purchase_invoice\"

Return ONLY valid JSON, no explanation.

Invoice text:
${ocr_text}"
    else
        extraction_prompt="Extract the following fields from this receipt text as JSON. Use null for missing fields.
All dates must be in YYYY-MM-DD format. All amounts must be numbers (not strings).

Fields:
- merchant_name: string (the shop/business name)
- merchant_address: string or null
- merchant_vat_number: string or null (VAT number if shown)
- receipt_number: string or null (transaction/receipt number)
- date: string (YYYY-MM-DD format)
- time: string or null (HH:MM format)
- currency: string (3-letter ISO code like GBP, USD, EUR)
- subtotal: number or null (total before VAT if shown)
- vat_amount: number or null (VAT amount if shown)
- total: number (total amount paid)
- payment_method: string or null (cash, card, contactless, etc.)
- items: array of {name: string, quantity: number, price: number, vat_rate: string or null}
- document_type: \"expense_receipt\"

Return ONLY valid JSON, no explanation.

Receipt text:
${ocr_text}"
    fi

    print_info "Parsing ${doc_type} with LLM (privacy: ${privacy})..."

    local extracted_json
    if [[ "$llm_model" == "llama3.2" ]]; then
        extracted_json="$(echo "$extraction_prompt" | ollama run llama3.2 2>/dev/null)" || {
            print_error "LLM extraction failed"
            return 1
        }
    elif [[ "$llm_model" == "cloudflare" ]] || [[ "$llm_model" == "cloud" ]]; then
        # For edge/cloud modes, fall back to document-extraction-helper.sh
        # which handles API key management
        print_warning "Edge/cloud extraction requires document-extraction-helper.sh"
        print_info "Falling back to local Ollama extraction..."
        if command -v ollama &>/dev/null; then
            extracted_json="$(echo "$extraction_prompt" | ollama run llama3.2 2>/dev/null)" || {
                print_error "LLM extraction failed"
                return 1
            }
        else
            print_error "No LLM backend available"
            return 1
        fi
    fi

    # Clean up the JSON (strip markdown code fences if present)
    extracted_json="$(echo "$extracted_json" | sed -n '/^[{[]/,/^[}\]]/p')"

    # Validate JSON
    if ! echo "$extracted_json" | python3 -m json.tool > /dev/null 2>&1; then
        print_warning "LLM returned invalid JSON. Saving raw output."
        local raw_file="${WORKSPACE_DIR}/${basename}-raw.txt"
        echo "$extracted_json" > "$raw_file"
        print_info "Raw output saved to: ${raw_file}"
        # Attempt to wrap in a basic structure
        printf '{\n  "source_file": "%s",\n  "document_type": "%s",\n  "extraction_status": "partial",\n  "raw_text": %s\n}\n' \
            "$source_file" "$doc_type" "$(echo "$ocr_text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
            > "$output_file"
    else
        # Write raw extraction first
        local raw_output_file="${WORKSPACE_DIR}/${basename}-raw-extracted.json"
        printf '{\n  "source_file": "%s",\n  "document_type": "%s",\n  "extraction_status": "complete",\n  "data": %s\n}\n' \
            "$source_file" "$doc_type" "$extracted_json" \
            > "$raw_output_file"

        # Run validation pipeline if available
        if [[ -f "$PIPELINE_PY" ]]; then
            local pipeline_type
            if [[ "$doc_type" == "invoice" ]]; then
                pipeline_type="purchase_invoice"
            else
                pipeline_type="expense_receipt"
            fi
            print_info "Running validation pipeline..."
            if python3 "$PIPELINE_PY" validate "$raw_output_file" --type "$pipeline_type" > "$output_file" 2>/dev/null; then
                print_info "Validation complete"
            else
                # Validation ran but flagged issues (exit code 2) - output is still valid
                if [[ $? -eq 2 ]]; then
                    print_warning "Extraction requires manual review (see validation.warnings)"
                else
                    # Validation failed entirely, use raw output
                    print_warning "Validation pipeline failed, using raw extraction"
                    cp "$raw_output_file" "$output_file"
                fi
            fi
        else
            cp "$raw_output_file" "$output_file"
        fi
    fi

    # Display the extracted data
    python3 -m json.tool "$output_file" 2>/dev/null || cat "$output_file"
    print_success "Extracted data saved to: ${output_file}"
    return 0
}

# Batch process a directory
cmd_batch() {
    local input_dir="$1"
    local doc_type="${2:-auto}"
    local privacy="${3:-local}"

    if [[ ! -d "$input_dir" ]]; then
        print_error "Directory not found: ${input_dir}"
        return 1
    fi

    ensure_workspace

    local count=0
    local failed=0
    local supported_extensions="png jpg jpeg tiff bmp webp heic pdf"

    print_info "Batch processing receipts/invoices from: ${input_dir}"
    echo ""

    for file in "${input_dir}"/*; do
        [[ -f "$file" ]] || continue

        local ext="${file##*.}"
        ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

        # Check if extension is supported
        local supported=0
        for supported_ext in $supported_extensions; do
            if [[ "$ext" == "$supported_ext" ]]; then
                supported=1
                break
            fi
        done

        if [[ "$supported" -eq 0 ]]; then
            continue
        fi

        echo "---"
        print_info "Processing: $(basename "$file")"
        if cmd_extract "$file" "$doc_type" "$privacy" "json"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done

    echo "==="
    print_success "Batch complete: ${count} succeeded, ${failed} failed"
    print_info "Output directory: ${WORKSPACE_DIR}"
    return 0
}

# Preview what would be sent to QuickFile (dry run)
cmd_preview() {
    local input_file="$1"
    local doc_type="${2:-auto}"
    local privacy="${3:-local}"
    local supplier_override="${4:-}"
    local nominal_code="${5:-${DEFAULT_NOMINAL_CODE}}"
    local currency="${6:-${DEFAULT_CURRENCY}}"
    local vat_rate="${7:-${DEFAULT_VAT_RATE}}"

    validate_file_exists "$input_file" "Input file" || return 1
    ensure_workspace

    # Extract data first
    print_info "Extracting data for QuickFile preview..."
    cmd_extract "$input_file" "$doc_type" "$privacy" "json" || return 1

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
    local extracted_file="${WORKSPACE_DIR}/${basename}-extracted.json"

    if [[ ! -f "$extracted_file" ]]; then
        print_error "Extraction output not found"
        return 1
    fi

    # Build QuickFile purchase invoice preview
    print_info "QuickFile Purchase Invoice Preview:"
    echo ""

    python3 -c "
import json
import sys

with open('${extracted_file}', 'r') as f:
    data = json.load(f)

extracted = data.get('data', data)
doc_type = data.get('document_type', 'invoice')
supplier_override = '${supplier_override}'
nominal_code = '${nominal_code}'
currency = '${currency}'
vat_rate = float('${vat_rate}')

# Determine supplier name
if supplier_override:
    supplier = supplier_override
elif doc_type == 'receipt':
    supplier = extracted.get('merchant', 'Unknown Supplier')
else:
    supplier = extracted.get('vendor_name', 'Unknown Supplier')

# Determine date
if doc_type == 'receipt':
    inv_date = extracted.get('date', 'Unknown')
else:
    inv_date = extracted.get('invoice_date', 'Unknown')

# Determine totals
total = extracted.get('total', 0)
tax = extracted.get('tax_amount', 0)
if tax is None:
    tax = 0
subtotal = extracted.get('subtotal', total - tax if total else 0)
if subtotal is None:
    subtotal = total - tax if total else 0

# Get line items
if doc_type == 'receipt':
    items = extracted.get('items', [])
else:
    items = extracted.get('line_items', [])

# Currency from extraction or override
doc_currency = extracted.get('currency', currency)
if doc_currency:
    currency = doc_currency

print('  Supplier:       ' + str(supplier))
print('  Date:           ' + str(inv_date))
print('  Currency:       ' + str(currency))
print('  Nominal Code:   ' + str(nominal_code))
print('  VAT Rate:       ' + str(vat_rate) + '%')
print()
print('  Line Items:')
if items:
    for i, item in enumerate(items, 1):
        desc = item.get('description', item.get('name', 'Item'))
        qty = item.get('quantity', 1)
        price = item.get('unit_price', item.get('price', 0))
        amt = item.get('amount', price * qty if price and qty else 0)
        print(f'    {i}. {desc} (qty: {qty}, price: {price}, amount: {amt})')
else:
    print('    (no line items extracted - will use single line)')
print()
print('  Subtotal:       ' + str(subtotal))
print('  VAT:            ' + str(tax))
print('  Total:          ' + str(total))
print()
print('  QuickFile API call: quickfile_purchase_create')
print('  Supplier lookup:    quickfile_supplier_search -> quickfile_supplier_create (if new)')
" 2>/dev/null || {
        print_error "Preview generation failed"
        return 1
    }

    print_info "To create this purchase invoice, run:"
    echo "  ocr-receipt-helper.sh quickfile ${input_file}"
    return 0
}

# Extract and create QuickFile purchase invoice
cmd_quickfile() {
    local input_file="$1"
    local doc_type="${2:-auto}"
    local privacy="${3:-local}"
    local supplier_override="${4:-}"
    local nominal_code="${5:-${DEFAULT_NOMINAL_CODE}}"
    local currency="${6:-${DEFAULT_CURRENCY}}"
    local vat_rate="${7:-${DEFAULT_VAT_RATE}}"

    validate_file_exists "$input_file" "Input file" || return 1
    ensure_workspace

    # Extract data first
    print_info "Step 1/3: Extracting receipt/invoice data..."
    cmd_extract "$input_file" "$doc_type" "$privacy" "json" || return 1

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
    local extracted_file="${WORKSPACE_DIR}/${basename}-extracted.json"

    if [[ ! -f "$extracted_file" ]]; then
        print_error "Extraction output not found"
        return 1
    fi

    # Generate QuickFile-ready JSON
    print_info "Step 2/3: Preparing QuickFile purchase invoice..."
    local qf_file="${WORKSPACE_DIR}/${basename}-quickfile.json"

    python3 -c "
import json
import sys
from datetime import datetime

with open('${extracted_file}', 'r') as f:
    data = json.load(f)

extracted = data.get('data', data)
doc_type = data.get('document_type', 'invoice')
supplier_override = '${supplier_override}'
nominal_code = '${nominal_code}'
currency = '${currency}'
vat_rate = float('${vat_rate}')

# Determine supplier
if supplier_override:
    supplier = supplier_override
elif doc_type == 'receipt':
    supplier = extracted.get('merchant', 'Unknown Supplier')
else:
    supplier = extracted.get('vendor_name', 'Unknown Supplier')

# Determine date
if doc_type == 'receipt':
    inv_date = extracted.get('date', datetime.now().strftime('%Y-%m-%d'))
else:
    inv_date = extracted.get('invoice_date', datetime.now().strftime('%Y-%m-%d'))

# Totals
total = float(extracted.get('total', 0) or 0)
tax = float(extracted.get('tax_amount', 0) or 0)
subtotal = float(extracted.get('subtotal', 0) or 0)
if subtotal == 0 and total > 0:
    subtotal = total - tax

# Line items
if doc_type == 'receipt':
    raw_items = extracted.get('items', [])
else:
    raw_items = extracted.get('line_items', [])

line_items = []
if raw_items:
    for item in raw_items:
        desc = item.get('description', item.get('name', 'Item'))
        qty = float(item.get('quantity', 1) or 1)
        price = float(item.get('unit_price', item.get('price', 0)) or 0)
        amt = float(item.get('amount', price * qty) or 0)
        line_items.append({
            'description': desc,
            'quantity': qty,
            'unit_price': price,
            'amount': amt,
            'nominal_code': nominal_code,
            'vat_rate': vat_rate
        })
else:
    # Single line item for the total
    line_items.append({
        'description': f'{doc_type.title()} from {supplier}',
        'quantity': 1,
        'unit_price': subtotal,
        'amount': subtotal,
        'nominal_code': nominal_code,
        'vat_rate': vat_rate
    })

# Invoice number
inv_number = extracted.get('invoice_number', '')
if not inv_number:
    inv_number = f'OCR-{basename}'

# Build QuickFile-compatible structure
qf_data = {
    'supplier_name': supplier,
    'invoice_number': inv_number,
    'invoice_date': inv_date,
    'currency': currency,
    'subtotal': subtotal,
    'vat_amount': tax,
    'total': total,
    'line_items': line_items,
    'source_file': '${input_file}',
    'extraction_method': 'ocr-receipt-helper',
    'notes': f'Auto-extracted from {doc_type} via OCR pipeline'
}

with open('${qf_file}', 'w') as f:
    json.dump(qf_data, f, indent=2)

print(json.dumps(qf_data, indent=2))
" 2>/dev/null || {
        print_error "QuickFile data preparation failed"
        return 1
    }

    print_success "QuickFile-ready data saved to: ${qf_file}"
    echo ""

    # Step 3: Generate MCP recording instructions via quickfile-helper.sh
    local qf_helper="${SCRIPT_DIR}/quickfile-helper.sh"
    if [[ -x "$qf_helper" ]]; then
        local record_cmd="record-purchase"
        if [[ "$doc_type" == "receipt" ]]; then
            record_cmd="record-expense"
        fi
        print_info "Step 3/3: Generating QuickFile MCP recording instructions..."
        "$qf_helper" "$record_cmd" "$qf_file" --nominal "$nominal_code" --auto-supplier || {
            print_warning "quickfile-helper.sh failed, showing manual instructions"
            echo ""
            echo "  Prompt the AI with:"
            echo "    \"Read ${qf_file} and use quickfile_supplier_search to find or"
            echo "     quickfile_supplier_create to create the supplier, then use"
            echo "     quickfile_purchase_create to record this purchase invoice.\""
        }
    else
        print_info "Step 3/3: To create the purchase invoice in QuickFile, use the AI assistant:"
        echo ""
        echo "  Prompt the AI with:"
        echo "    \"Read ${qf_file} and use quickfile_supplier_search to find or"
        echo "     quickfile_supplier_create to create the supplier, then use"
        echo "     quickfile_purchase_create to record this purchase invoice.\""
        echo ""
        print_info "Or install quickfile-helper.sh for automated MCP instructions."
    fi
    return 0
}

# Check component status
cmd_status() {
    echo "OCR Receipt Pipeline - Component Status"
    echo "========================================"
    echo ""

    # Ollama
    echo "OCR Engine:"
    if command -v ollama &>/dev/null; then
        echo "  ollama:         installed"
        if ollama list 2>/dev/null | grep -q "${OCR_MODEL}"; then
            echo "  glm-ocr model:  available"
        else
            echo "  glm-ocr model:  not pulled (run: ollama pull glm-ocr)"
        fi
        if ollama list 2>/dev/null | grep -q "llama3"; then
            echo "  llama3.2:       available (for structured extraction)"
        else
            echo "  llama3.2:       not pulled (run: ollama pull llama3.2)"
        fi
    else
        echo "  ollama:         not installed (run: brew install ollama)"
    fi

    # ImageMagick (for PDF)
    echo ""
    echo "PDF Support:"
    if command -v magick &>/dev/null; then
        echo "  imagemagick:    installed (v7)"
    elif command -v convert &>/dev/null; then
        echo "  imagemagick:    installed (v6)"
    else
        echo "  imagemagick:    not installed (run: brew install imagemagick)"
    fi

    # Validation pipeline
    echo ""
    echo "Validation Pipeline:"
    if [[ -f "$PIPELINE_PY" ]]; then
        echo "  extraction_pipeline.py: available"
    else
        echo "  extraction_pipeline.py: not found"
    fi
    if python3 -c "import pydantic" 2>/dev/null; then
        echo "  pydantic:       installed"
    else
        echo "  pydantic:       not installed (run: pip install pydantic>=2.0)"
    fi

    # Document extraction venv
    echo ""
    echo "Structured Extraction:"
    if [[ -d "${VENV_DIR}/bin" ]]; then
        echo "  python venv:    ${VENV_DIR}"
        if "${VENV_DIR}/bin/python3" -c "import docling" 2>/dev/null; then
            echo "  docling:        installed"
        else
            echo "  docling:        not installed"
        fi
        if "${VENV_DIR}/bin/python3" -c "import extract_thinker" 2>/dev/null; then
            echo "  extract-thinker: installed"
        else
            echo "  extract-thinker: not installed"
        fi
    else
        echo "  python venv:    not created"
        echo "  (run: document-extraction-helper.sh install --core)"
    fi

    # QuickFile MCP
    echo ""
    echo "QuickFile Integration:"
    if [[ -f "${HOME}/Git/quickfile-mcp/dist/index.js" ]]; then
        echo "  quickfile-mcp:  installed"
    else
        echo "  quickfile-mcp:  not found (optional - for purchase invoice creation)"
    fi
    if [[ -f "${HOME}/.config/.quickfile-mcp/credentials.json" ]]; then
        echo "  credentials:    configured"
    else
        echo "  credentials:    not configured"
    fi

    # Workspace
    echo ""
    echo "Workspace:"
    echo "  output dir:     ${WORKSPACE_DIR}"
    if [[ -d "$WORKSPACE_DIR" ]]; then
        local file_count
        file_count="$(find "$WORKSPACE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        echo "  files:          ${file_count}"
    else
        echo "  files:          (not created yet)"
    fi

    return 0
}

# Install OCR dependencies
cmd_install() {
    print_info "Installing OCR receipt pipeline dependencies..."
    echo ""

    # Ollama
    if command -v ollama &>/dev/null; then
        print_success "Ollama already installed"
    else
        print_info "Installing Ollama..."
        if command -v brew &>/dev/null; then
            brew install ollama || {
                print_error "Ollama installation failed"
                return 1
            }
        else
            print_error "Homebrew not found. Install Ollama manually: https://ollama.com/"
            return 1
        fi
    fi

    # GLM-OCR model
    if ollama list 2>/dev/null | grep -q "${OCR_MODEL}"; then
        print_success "GLM-OCR model already available"
    else
        print_info "Pulling GLM-OCR model (~2GB)..."
        ollama pull "$OCR_MODEL" || {
            print_error "Failed to pull GLM-OCR model"
            return 1
        }
        print_success "GLM-OCR model installed"
    fi

    # llama3.2 for structured extraction
    if ollama list 2>/dev/null | grep -q "llama3"; then
        print_success "llama3.2 model already available"
    else
        print_info "Pulling llama3.2 model (for structured extraction)..."
        ollama pull llama3.2 || {
            print_warning "Failed to pull llama3.2. Structured extraction may be limited."
        }
    fi

    # ImageMagick for PDF support
    if command -v magick &>/dev/null || command -v convert &>/dev/null; then
        print_success "ImageMagick already installed"
    else
        print_info "Installing ImageMagick (for PDF support)..."
        if command -v brew &>/dev/null; then
            brew install imagemagick || print_warning "ImageMagick installation failed. PDF OCR will not work."
        else
            print_warning "Install ImageMagick manually for PDF support"
        fi
    fi

    # Document extraction (optional, handled by document-extraction-helper.sh)
    echo ""
    print_info "For structured extraction with Pydantic schemas, also run:"
    echo "  document-extraction-helper.sh install --core"
    echo ""
    print_success "OCR receipt pipeline installation complete"
    return 0
}

# Show help
cmd_help() {
    echo "OCR Receipt/Invoice Extraction Helper - AI DevOps Framework"
    echo ""
    echo "${HELP_LABEL_USAGE}"
    echo "  ocr-receipt-helper.sh <command> [options]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  scan <file>              Quick OCR text extraction (GLM-OCR)"
    echo "  extract <file>           Structured extraction with validation pipeline"
    echo "  validate <json-file>     Validate extracted JSON (VAT, dates, confidence)"
    echo "  batch <dir>              Batch process directory of receipts/invoices"
    echo "  quickfile <file>         Extract and prepare QuickFile purchase invoice"
    echo "  preview <file>           Dry run - show what would be sent to QuickFile"
    echo "  status                   Check installed components"
    echo "  install                  Install OCR dependencies"
    echo "  help                     Show this help"
    echo ""
    echo "${HELP_LABEL_OPTIONS}"
    echo "  --type <invoice|receipt>   Document type (default: auto-detect)"
    echo "  --privacy <mode>           local, edge, cloud, none (default: local)"
    echo "  --output <format>          json, text, markdown (default: json)"
    echo "  --supplier <name>          Override supplier name for QuickFile"
    echo "  --nominal <code>           QuickFile nominal code (default: 7901)"
    echo "  --currency <code>          Currency code (default: GBP)"
    echo "  --vat-rate <rate>          VAT rate percentage (default: 20)"
    echo ""
    echo "Pipeline:"
    echo "  1. scan      - Raw OCR text extraction (GLM-OCR via Ollama, local)"
    echo "  2. extract   - Structured extraction + validation (auto-detect type)"
    echo "  3. validate  - VAT arithmetic, date checks, confidence scoring"
    echo "  4. preview   - Show QuickFile purchase invoice preview (dry run)"
    echo "  5. quickfile - Generate QuickFile-ready JSON + MCP recording instructions"
    echo ""
    echo "  For recording in QuickFile, also see: quickfile-helper.sh"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  ocr-receipt-helper.sh scan receipt.jpg"
    echo "  ocr-receipt-helper.sh extract invoice.pdf --type invoice --privacy local"
    echo "  ocr-receipt-helper.sh batch ~/Documents/receipts/"
    echo "  ocr-receipt-helper.sh preview receipt.png --supplier 'Amazon UK'"
    echo "  ocr-receipt-helper.sh quickfile invoice.pdf --nominal 7502 --currency GBP"
    echo "  ocr-receipt-helper.sh status"
    echo "  ocr-receipt-helper.sh install"
    echo ""
    echo "Related:"
    echo "  document-extraction-helper.sh  - General document extraction"
    echo "  tools/accounts/receipt-ocr.md  - Subagent documentation"
    echo "  tools/ocr/glm-ocr.md          - GLM-OCR model reference"
    echo "  services/accounting/quickfile.md - QuickFile MCP integration"
    return 0
}

# Parse command-line arguments
parse_args() {
    local command="${1:-help}"
    shift || true

    # Parse named options
    local file=""
    local doc_type="auto"
    local privacy="local"
    local output_format="json"
    local supplier=""
    local nominal_code="${DEFAULT_NOMINAL_CODE}"
    local currency="${DEFAULT_CURRENCY}"
    local vat_rate="${DEFAULT_VAT_RATE}"

    # First positional arg after command is the file/dir
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        file="$1"
        shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                doc_type="${2:-auto}"
                shift 2 || { print_error "Missing value for --type"; return 1; }
                ;;
            --privacy)
                privacy="${2:-local}"
                shift 2 || { print_error "Missing value for --privacy"; return 1; }
                ;;
            --output)
                output_format="${2:-json}"
                shift 2 || { print_error "Missing value for --output"; return 1; }
                ;;
            --supplier)
                supplier="${2:-}"
                shift 2 || { print_error "Missing value for --supplier"; return 1; }
                ;;
            --nominal)
                nominal_code="${2:-${DEFAULT_NOMINAL_CODE}}"
                shift 2 || { print_error "Missing value for --nominal"; return 1; }
                ;;
            --currency)
                currency="${2:-${DEFAULT_CURRENCY}}"
                shift 2 || { print_error "Missing value for --currency"; return 1; }
                ;;
            --vat-rate)
                vat_rate="${2:-${DEFAULT_VAT_RATE}}"
                shift 2 || { print_error "Missing value for --vat-rate"; return 1; }
                ;;
            *)
                print_warning "Unknown option: $1"
                shift
                ;;
        esac
    done

    case "$command" in
        scan)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_scan "$file" "$output_format"
            ;;
        extract)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_extract "$file" "$doc_type" "$privacy" "$output_format"
            ;;
        validate)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            if [[ -f "$PIPELINE_PY" ]]; then
                local pipeline_type="auto"
                if [[ "$doc_type" == "invoice" ]]; then
                    pipeline_type="purchase_invoice"
                elif [[ "$doc_type" == "receipt" ]]; then
                    pipeline_type="expense_receipt"
                fi
                python3 "$PIPELINE_PY" validate "$file" --type "$pipeline_type"
            else
                print_error "Validation pipeline not found: ${PIPELINE_PY}"
                return 1
            fi
            ;;
        batch)
            if [[ -z "$file" ]]; then
                print_error "Input directory is required"
                return 1
            fi
            cmd_batch "$file" "$doc_type" "$privacy"
            ;;
        quickfile|qf)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_quickfile "$file" "$doc_type" "$privacy" "$supplier" "$nominal_code" "$currency" "$vat_rate"
            ;;
        preview)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_preview "$file" "$doc_type" "$privacy" "$supplier" "$nominal_code" "$currency" "$vat_rate"
            ;;
        status)
            cmd_status
            ;;
        install)
            cmd_install
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

# Main entry point
parse_args "$@"
