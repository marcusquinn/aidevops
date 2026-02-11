#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Document Extraction Helper for AI DevOps Framework
# Orchestrates document parsing, PII detection, and structured extraction
#
# Usage: document-extraction-helper.sh [command] [options]
#
# Commands:
#   extract <file> [--schema <name>] [--privacy <mode>] [--output <format>]
#   batch <dir> [--schema <name>] [--privacy <mode>] [--pattern <glob>]
#   classify <file>                  Auto-detect document type (invoice/receipt/other)
#   accounting-extract <file> [--privacy <mode>]  Extract invoice/receipt for QuickFile
#   watch <dir> [--schema <name>] [--privacy <mode>] [--interval <secs>]
#   pii-scan <file>                  Scan for PII without extraction
#   pii-redact <file> [--output <file>]  Redact PII from text
#   convert <file> [--output <format>]   Convert document to markdown/JSON
#   install [--all|--core|--pii|--llm]   Install dependencies
#   status                               Check installed components
#   schemas                              List available extraction schemas
#   help                                 Show this help
#
# Privacy modes: local (Ollama), edge (Cloudflare), cloud (OpenAI/Anthropic), none
# Output formats: json, markdown, text
# Schemas: invoice, receipt, contract, id-document, auto
#
# Author: AI DevOps Framework
# Version: 2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-extraction"
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/work/document-extraction"

# Ensure workspace exists
ensure_workspace() {
    mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true
    return 0
}

# Activate or create Python virtual environment
activate_venv() {
    if [[ -d "${VENV_DIR}/bin" ]]; then
        # shellcheck disable=SC1091
        source "${VENV_DIR}/bin/activate"
        return 0
    fi
    print_error "Python venv not found at ${VENV_DIR}"
    print_info "Run: document-extraction-helper.sh install --core"
    return 1
}

# Check if a Python package is installed in the venv
check_python_package() {
    local package="$1"
    if [[ -d "${VENV_DIR}/bin" ]]; then
        "${VENV_DIR}/bin/python3" -c "import ${package}" 2>/dev/null
        return $?
    fi
    return 1
}

# Install dependencies
do_install() {
    local component="${1:-all}"

    case "$component" in
        --all|all)
            install_core
            install_pii
            install_llm
            ;;
        --core|core)
            install_core
            ;;
        --pii|pii)
            install_pii
            ;;
        --llm|llm)
            install_llm
            ;;
        *)
            print_error "Unknown install component: ${component}"
            print_info "Options: --all, --core, --pii, --llm"
            return 1
            ;;
    esac
    return 0
}

install_core() {
    print_info "Installing core document extraction dependencies..."

    # Check Python version
    local python_version
    python_version="$(python3 --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)"
    if [[ -z "$python_version" ]]; then
        print_error "Python 3 is required but not found"
        return 1
    fi

    local major minor
    major="$(echo "$python_version" | cut -d. -f1)"
    minor="$(echo "$python_version" | cut -d. -f2)"
    if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 10 ]]; }; then
        print_error "Python 3.10+ required (found ${python_version})"
        return 1
    fi

    # Create venv
    if [[ ! -d "${VENV_DIR}/bin" ]]; then
        print_info "Creating Python virtual environment at ${VENV_DIR}..."
        python3 -m venv "$VENV_DIR"
    fi

    # Install packages
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet docling extract-thinker

    print_success "Core dependencies installed (docling, extract-thinker)"
    return 0
}

install_pii() {
    print_info "Installing PII detection dependencies..."

    if [[ ! -d "${VENV_DIR}/bin" ]]; then
        print_warning "Core not installed yet. Installing core first..."
        install_core
    fi

    "${VENV_DIR}/bin/pip" install --quiet presidio-analyzer presidio-anonymizer
    "${VENV_DIR}/bin/python3" -m spacy download en_core_web_lg --quiet 2>/dev/null || {
        print_warning "spaCy model download failed. PII detection may have reduced accuracy."
        print_info "Try manually: ${VENV_DIR}/bin/python3 -m spacy download en_core_web_lg"
    }

    print_success "PII dependencies installed (presidio-analyzer, presidio-anonymizer, spaCy)"
    return 0
}

install_llm() {
    print_info "Checking local LLM setup..."

    if command -v ollama &>/dev/null; then
        print_success "Ollama is installed"
        if ollama list 2>/dev/null | grep -q "llama3"; then
            print_success "llama3 model available"
        else
            print_info "Pulling llama3.2 model for local extraction..."
            ollama pull llama3.2 || print_warning "Failed to pull llama3.2. Pull manually: ollama pull llama3.2"
        fi
    else
        print_warning "Ollama not installed. For local LLM processing:"
        print_info "  brew install ollama && ollama pull llama3.2"
    fi
    return 0
}

# Check installation status
do_status() {
    echo "Document Extraction - Component Status"
    echo "======================================="
    echo ""

    # Python
    local python_version
    python_version="$(python3 --version 2>/dev/null | awk '{print $2}')" || python_version="not found"
    echo "Python:           ${python_version}"

    # Venv
    if [[ -d "${VENV_DIR}/bin" ]]; then
        echo "Virtual env:      ${VENV_DIR}"
    else
        echo "Virtual env:      not created"
    fi

    # Core packages
    echo ""
    echo "Core Packages:"
    if check_python_package "docling"; then
        echo "  docling:        installed"
    else
        echo "  docling:        not installed"
    fi

    if check_python_package "extract_thinker"; then
        echo "  extract-thinker: installed"
    else
        echo "  extract-thinker: not installed"
    fi

    # PII packages
    echo ""
    echo "PII Packages:"
    if check_python_package "presidio_analyzer"; then
        echo "  presidio:       installed"
    else
        echo "  presidio:       not installed"
    fi

    # LLM backends
    echo ""
    echo "LLM Backends:"
    if command -v ollama &>/dev/null; then
        local ollama_models
        ollama_models="$(ollama list 2>/dev/null | grep -c "." || echo "0")"
        echo "  ollama:         installed (${ollama_models} models)"
    else
        echo "  ollama:         not installed"
    fi

    # OCR
    echo ""
    echo "OCR Backends:"
    if command -v tesseract &>/dev/null; then
        echo "  tesseract:      installed"
    else
        echo "  tesseract:      not installed"
    fi

    if check_python_package "easyocr"; then
        echo "  easyocr:        installed"
    else
        echo "  easyocr:        not installed"
    fi

    # Related tools
    echo ""
    echo "Related Tools:"
    if command -v pandoc &>/dev/null; then
        echo "  pandoc:         installed"
    else
        echo "  pandoc:         not installed"
    fi

    if command -v mineru &>/dev/null; then
        echo "  mineru:         installed"
    else
        echo "  mineru:         not installed"
    fi

    return 0
}

# Convert document to markdown/JSON using Docling
do_convert() {
    local input_file="$1"
    local output_format="${2:-markdown}"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1
    ensure_workspace

    local output_ext
    case "$output_format" in
        markdown|md) output_ext="md" ;;
        json) output_ext="json" ;;
        text|txt) output_ext="txt" ;;
        *) print_error "Unsupported output format: ${output_format}"; return 1 ;;
    esac

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
    local output_file="${WORKSPACE_DIR}/${basename}.${output_ext}"

    print_info "Converting ${input_file} to ${output_format}..."

    local safe_input safe_output
    safe_input="$(sanitize_path_for_python "$input_file")"
    safe_output="$(sanitize_path_for_python "$output_file")"

    "${VENV_DIR}/bin/python3" - "$safe_input" "$safe_output" "$output_format" <<'PYCONVERT'
import sys
from docling.document_converter import DocumentConverter

input_file = sys.argv[1]
output_file = sys.argv[2]
output_format = sys.argv[3]

converter = DocumentConverter()
result = converter.convert(input_file)

if output_format in ('markdown', 'md'):
    content = result.document.export_to_markdown()
elif output_format == 'json':
    import json
    content = json.dumps(result.document.export_to_dict(), indent=2)
else:
    content = result.document.export_to_markdown()

with open(output_file, 'w') as f:
    f.write(content)

print(f'Converted: {output_file}')
PYCONVERT

    if [[ $? -ne 0 ]]; then
        print_error "Conversion failed"
        return 1
    fi

    print_success "Output: ${output_file}"
    return 0
}

# Scan file for PII
do_pii_scan() {
    local input_file="$1"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1

    if ! check_python_package "presidio_analyzer"; then
        print_error "Presidio not installed. Run: document-extraction-helper.sh install --pii"
        return 1
    fi

    print_info "Scanning ${input_file} for PII..."

    local safe_input
    safe_input="$(sanitize_path_for_python "$input_file")"

    "${VENV_DIR}/bin/python3" - "$safe_input" <<'PYPIISCAN'
import sys
from presidio_analyzer import AnalyzerEngine

input_file = sys.argv[1]
analyzer = AnalyzerEngine()

with open(input_file, 'r') as f:
    text = f.read()

results = analyzer.analyze(text=text, language='en')

if not results:
    print('No PII detected.')
    sys.exit(0)

print(f'Found {len(results)} PII entities:')
print()
for r in sorted(results, key=lambda x: x.score, reverse=True):
    snippet = text[r.start:r.end]
    masked = snippet[0] + '*' * (len(snippet) - 2) + snippet[-1] if len(snippet) > 2 else '**'
    print(f'  {r.entity_type:20s} score={r.score:.2f}  [{masked}]  pos={r.start}-{r.end}')
PYPIISCAN

    if [[ $? -ne 0 ]]; then
        print_error "PII scan failed"
        return 1
    fi

    return 0
}

# Redact PII from text file
do_pii_redact() {
    local input_file="$1"
    local output_file="${2:-}"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1

    if ! check_python_package "presidio_analyzer"; then
        print_error "Presidio not installed. Run: document-extraction-helper.sh install --pii"
        return 1
    fi

    if [[ -z "$output_file" ]]; then
        local basename
        basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
        local ext="${input_file##*.}"
        output_file="${WORKSPACE_DIR}/${basename}-redacted.${ext}"
    fi

    ensure_workspace
    print_info "Redacting PII from ${input_file}..."

    local safe_input safe_output
    safe_input="$(sanitize_path_for_python "$input_file")"
    safe_output="$(sanitize_path_for_python "$output_file")"

    "${VENV_DIR}/bin/python3" - "$safe_input" "$safe_output" <<'PYREDACT'
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
import sys

input_file = sys.argv[1]
output_file = sys.argv[2]

analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

with open(input_file, 'r') as f:
    text = f.read()

results = analyzer.analyze(text=text, language='en')
anonymized = anonymizer.anonymize(text=text, analyzer_results=results)

with open(output_file, 'w') as f:
    f.write(anonymized.text)

print(f'Redacted {len(results)} PII entities')
print(f'Output: {output_file}')
PYREDACT

    if [[ $? -ne 0 ]]; then
        print_error "PII redaction failed"
        return 1
    fi

    print_success "Redacted output: ${output_file}"
    return 0
}

# Resolve LLM backend from privacy mode
# Usage: resolve_llm_backend <privacy_mode>
# Outputs backend string to stdout, returns 1 on error
resolve_llm_backend() {
    local privacy="$1"

    case "$privacy" in
        local)
            if ! command -v ollama &>/dev/null; then
                print_error "Ollama required for local privacy mode but not installed"
                return 1
            fi
            echo "ollama/llama3.2"
            ;;
        edge)
            echo "cloudflare/workers-ai"
            ;;
        cloud)
            echo "openai/gpt-4o"
            ;;
        none)
            if command -v ollama &>/dev/null; then
                echo "ollama/llama3.2"
            else
                print_warning "Ollama not found, falling back to cloud API (data will leave machine)"
                echo "openai/gpt-4o"
            fi
            ;;
        *)
            print_error "Unknown privacy mode: ${privacy}"
            print_info "Options: local, edge, cloud, none"
            return 1
            ;;
    esac
    return 0
}

# Sanitize a file path for safe use in Python string literals
# Escapes backslashes and single quotes to prevent injection
sanitize_path_for_python() {
    local path="$1"
    # Escape backslashes first, then single quotes
    path="${path//\\/\\\\}"
    path="${path//\'/\\\'}"
    echo "$path"
    return 0
}

# Build Pydantic schema code for a given schema name
# Usage: build_schema_code <schema_name>
# Outputs Python code to stdout
build_schema_code() {
    local schema="$1"

    case "$schema" in
        invoice)
            cat <<'PYSCHEMA'
from typing import Optional
from enum import Enum

class VATRate(str, Enum):
    STANDARD = 'standard'
    REDUCED = 'reduced'
    ZERO = 'zero'
    EXEMPT = 'exempt'
    REVERSE_CHARGE = 'reverse_charge'
    UNKNOWN = 'unknown'

class LineItem(BaseModel):
    description: str = ''
    quantity: float = 0
    unit_price: float = 0
    amount: float = 0
    vat_rate: str = 'unknown'
    vat_amount: float = 0
    product_code: str = ''

class TaxBreakdown(BaseModel):
    rate_label: str = ''
    rate_percent: float = 0
    taxable_amount: float = 0
    tax_amount: float = 0

class Invoice(BaseModel):
    vendor_name: str = ''
    vendor_address: str = ''
    vendor_vat_number: str = ''
    vendor_company_number: str = ''
    customer_name: str = ''
    customer_address: str = ''
    customer_vat_number: str = ''
    invoice_number: str = ''
    invoice_date: str = ''
    due_date: str = ''
    payment_terms: str = ''
    purchase_order: str = ''
    subtotal: float = 0
    discount: float = 0
    tax: float = 0
    total: float = 0
    amount_paid: float = 0
    amount_due: float = 0
    currency: str = 'GBP'
    tax_breakdowns: list[TaxBreakdown] = []
    line_items: list[LineItem] = []
    payment_details: str = ''
    notes: str = ''

schema_class = Invoice
PYSCHEMA
            ;;
        receipt)
            cat <<'PYSCHEMA'
from typing import Optional

class ReceiptItem(BaseModel):
    name: str = ''
    quantity: float = 1
    unit_price: float = 0
    price: float = 0
    vat_code: str = ''

class Receipt(BaseModel):
    merchant: str = ''
    merchant_address: str = ''
    merchant_vat_number: str = ''
    merchant_phone: str = ''
    date: str = ''
    time: str = ''
    receipt_number: str = ''
    subtotal: float = 0
    vat_amount: float = 0
    total: float = 0
    currency: str = 'GBP'
    payment_method: str = ''
    card_last_four: str = ''
    items: list[ReceiptItem] = []
    cashier: str = ''
    store_number: str = ''

schema_class = Receipt
PYSCHEMA
            ;;
        contract)
            cat <<'PYSCHEMA'
class ContractSummary(BaseModel):
    parties: list[str] = []
    effective_date: str = ''
    termination_date: str = ''
    key_terms: list[str] = []
    obligations: list[str] = []

schema_class = ContractSummary
PYSCHEMA
            ;;
        id-document)
            cat <<'PYSCHEMA'
class IDDocument(BaseModel):
    document_type: str = ''
    full_name: str = ''
    date_of_birth: str = ''
    document_number: str = ''
    expiry_date: str = ''
    issuing_authority: str = ''

schema_class = IDDocument
PYSCHEMA
            ;;
        auto|*)
            echo "schema_class = None"
            ;;
    esac
    return 0
}

# Extract structured data from document
do_extract() {
    local input_file="$1"
    local schema="${2:-auto}"
    local privacy="${3:-none}"
    local output_format="${4:-json}"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1
    ensure_workspace

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
    local output_file="${WORKSPACE_DIR}/${basename}-extracted.json"

    local llm_backend
    llm_backend="$(resolve_llm_backend "$privacy")" || return 1

    print_info "Extracting from ${input_file} (schema=${schema}, privacy=${privacy}, llm=${llm_backend})..."

    # Build schema code and write to temp file (avoids shell injection)
    local schema_file
    schema_file="$(mktemp "${TMPDIR:-/tmp}/docext-schema-XXXXXX.py")"
    local _prev_trap
    _prev_trap="$(trap -p RETURN)"
    trap 'rm -f "$schema_file"; eval "$_prev_trap"' RETURN

    build_schema_code "$schema" > "$schema_file"

    # Sanitize paths for Python
    local safe_input safe_output
    safe_input="$(sanitize_path_for_python "$input_file")"
    safe_output="$(sanitize_path_for_python "$output_file")"

    "${VENV_DIR}/bin/python3" - "$safe_input" "$safe_output" "$llm_backend" "$schema_file" <<'PYEXTRACT'
import json
import sys
import os
from pydantic import BaseModel

input_file = sys.argv[1]
output_file = sys.argv[2]
llm_backend = sys.argv[3]
schema_file = sys.argv[4]

# Load schema code
schema_ns = {'BaseModel': BaseModel}
with open(schema_file, 'r') as f:
    exec(f.read(), schema_ns)

schema_class = schema_ns.get('schema_class')

try:
    if schema_class is not None:
        from extract_thinker import Extractor
        extractor = Extractor()
        extractor.load_document_loader('docling')
        extractor.load_llm(llm_backend)
        result = extractor.extract(input_file, schema_class)
        output = result.model_dump()
    else:
        from docling.document_converter import DocumentConverter
        converter = DocumentConverter()
        doc_result = converter.convert(input_file)
        output = {'content': doc_result.document.export_to_markdown(), 'format': 'markdown'}

    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2, default=str)

    print(json.dumps(output, indent=2, default=str))
except Exception as e:
    print(f'Extraction error: {e}', file=sys.stderr)
    sys.exit(1)
PYEXTRACT

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Extraction failed"
        return 1
    fi

    print_success "Output: ${output_file}"
    return 0
}

# Classify document type (invoice, receipt, or unknown)
do_classify() {
    local input_file="$1"
    local privacy="${2:-none}"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1

    local llm_backend
    llm_backend="$(resolve_llm_backend "$privacy")" || return 1

    local safe_input
    safe_input="$(sanitize_path_for_python "$input_file")"

    print_info "Classifying document: ${input_file}..."

    "${VENV_DIR}/bin/python3" - "$safe_input" "$llm_backend" <<'PYCLASSIFY'
import json
import sys
from pydantic import BaseModel

input_file = sys.argv[1]
llm_backend = sys.argv[2]

class DocumentClassification(BaseModel):
    document_type: str = 'unknown'
    confidence: float = 0.0
    reasoning: str = ''

try:
    from extract_thinker import Extractor
    extractor = Extractor()
    extractor.load_document_loader('docling')
    extractor.load_llm(llm_backend)
    result = extractor.extract(input_file, DocumentClassification)
    output = result.model_dump()
    print(json.dumps(output, indent=2))
except ImportError:
    # Fallback: use Docling to convert to text, then keyword-match
    from docling.document_converter import DocumentConverter
    converter = DocumentConverter()
    doc_result = converter.convert(input_file)
    text = doc_result.document.export_to_markdown().lower()

    invoice_signals = ['invoice', 'inv no', 'invoice number', 'bill to', 'due date',
                       'payment terms', 'purchase order', 'po number', 'vat reg']
    receipt_signals = ['receipt', 'transaction', 'paid', 'change due', 'cashier',
                       'store', 'thank you for your purchase', 'card ending']

    inv_score = sum(1 for s in invoice_signals if s in text)
    rec_score = sum(1 for s in receipt_signals if s in text)

    if inv_score > rec_score and inv_score >= 2:
        doc_type = 'invoice'
        confidence = min(0.5 + inv_score * 0.1, 0.95)
    elif rec_score > inv_score and rec_score >= 2:
        doc_type = 'receipt'
        confidence = min(0.5 + rec_score * 0.1, 0.95)
    else:
        doc_type = 'unknown'
        confidence = 0.3

    output = {'document_type': doc_type, 'confidence': confidence,
              'reasoning': f'keyword match: invoice={inv_score}, receipt={rec_score}'}
    print(json.dumps(output, indent=2))
except Exception as e:
    print(f'Classification error: {e}', file=sys.stderr)
    sys.exit(1)
PYCLASSIFY

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Classification failed"
        return 1
    fi
    return 0
}

# Extract invoice/receipt for accounting (QuickFile-ready output)
do_accounting_extract() {
    local input_file="$1"
    local privacy="${2:-none}"

    validate_file_exists "$input_file" "Input file" || return 1
    activate_venv || return 1
    ensure_workspace

    local llm_backend
    llm_backend="$(resolve_llm_backend "$privacy")" || return 1

    local basename
    basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"

    print_info "Accounting extraction: ${input_file} (auto-classifying...)"

    # Step 1: Classify the document
    local classification
    classification="$(do_classify "$input_file" "$privacy" 2>/dev/null)" || {
        print_warning "Classification failed, defaulting to invoice schema"
        classification='{"document_type": "invoice"}'
    }

    local doc_type
    doc_type="$(echo "$classification" | "${VENV_DIR}/bin/python3" -c "import json,sys; print(json.load(sys.stdin).get('document_type','invoice'))" 2>/dev/null)" || doc_type="invoice"

    # Normalize to supported schema
    case "$doc_type" in
        invoice|receipt) ;;
        *) doc_type="invoice" ;;
    esac

    print_info "Detected document type: ${doc_type}"

    # Step 2: Extract with the appropriate schema
    local output_file="${WORKSPACE_DIR}/${basename}-accounting.json"

    local schema_file
    schema_file="$(mktemp "${TMPDIR:-/tmp}/docext-schema-XXXXXX.py")"
    local _prev_trap
    _prev_trap="$(trap -p RETURN)"
    trap 'rm -f "$schema_file"; eval "$_prev_trap"' RETURN

    build_schema_code "$doc_type" > "$schema_file"

    local safe_input safe_output
    safe_input="$(sanitize_path_for_python "$input_file")"
    safe_output="$(sanitize_path_for_python "$output_file")"

    "${VENV_DIR}/bin/python3" - "$safe_input" "$safe_output" "$llm_backend" "$schema_file" "$doc_type" <<'PYACCOUNT'
import json
import sys
import os
from datetime import datetime
from pydantic import BaseModel

input_file = sys.argv[1]
output_file = sys.argv[2]
llm_backend = sys.argv[3]
schema_file = sys.argv[4]
doc_type = sys.argv[5]

# Load schema
schema_ns = {'BaseModel': BaseModel}
with open(schema_file, 'r') as f:
    exec(f.read(), schema_ns)

schema_class = schema_ns.get('schema_class')

try:
    from extract_thinker import Extractor
    extractor = Extractor()
    extractor.load_document_loader('docling')
    extractor.load_llm(llm_backend)
    result = extractor.extract(input_file, schema_class)
    extracted = result.model_dump()

    # Wrap in accounting envelope with QuickFile-compatible metadata
    accounting_output = {
        'source_file': os.path.basename(input_file),
        'document_type': doc_type,
        'extracted_at': datetime.utcnow().isoformat() + 'Z',
        'extraction_model': llm_backend,
        'data': extracted,
        'quickfile_mapping': {}
    }

    # Generate QuickFile field mapping hints
    if doc_type == 'invoice':
        accounting_output['quickfile_mapping'] = {
            'endpoint': 'POST /invoice/create',
            'field_map': {
                'InvoiceDescription': extracted.get('vendor_name', ''),
                'InvoiceDate': extracted.get('invoice_date', ''),
                'DueDate': extracted.get('due_date', ''),
                'Currency': extracted.get('currency', 'GBP'),
                'NetAmount': extracted.get('subtotal', 0),
                'VATAmount': extracted.get('tax', 0),
                'GrossAmount': extracted.get('total', 0),
                'SupplierRef': extracted.get('invoice_number', ''),
            },
            'line_items': [
                {
                    'ItemDescription': item.get('description', ''),
                    'UnitCost': item.get('unit_price', 0),
                    'Qty': item.get('quantity', 0),
                    'NetAmount': item.get('amount', 0),
                    'VATAmount': item.get('vat_amount', 0),
                }
                for item in extracted.get('line_items', [])
            ]
        }
    elif doc_type == 'receipt':
        accounting_output['quickfile_mapping'] = {
            'endpoint': 'POST /expense/create',
            'field_map': {
                'Description': extracted.get('merchant', ''),
                'Date': extracted.get('date', ''),
                'Currency': extracted.get('currency', 'GBP'),
                'NetAmount': extracted.get('subtotal', 0),
                'VATAmount': extracted.get('vat_amount', 0),
                'GrossAmount': extracted.get('total', 0),
                'PaymentMethod': extracted.get('payment_method', ''),
            }
        }

    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(accounting_output, f, indent=2, default=str)

    print(json.dumps(accounting_output, indent=2, default=str))
except Exception as e:
    print(f'Accounting extraction error: {e}', file=sys.stderr)
    sys.exit(1)
PYACCOUNT

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Accounting extraction failed"
        return 1
    fi

    print_success "Accounting output: ${output_file}"
    return 0
}

# Watch a directory for new documents and auto-extract
do_watch() {
    local watch_dir="$1"
    local schema="${2:-auto}"
    local privacy="${3:-none}"
    local interval="${4:-10}"

    if [[ ! -d "$watch_dir" ]]; then
        print_error "Watch directory not found: ${watch_dir}"
        return 1
    fi

    ensure_workspace

    local processed_log="${WORKSPACE_DIR}/.watch-processed.log"
    touch "$processed_log"

    local supported_extensions="pdf docx pptx xlsx html htm png jpg jpeg tiff bmp"

    print_info "Watching ${watch_dir} for new documents (interval=${interval}s, schema=${schema})..."
    print_info "Press Ctrl+C to stop"

    while true; do
        for file in "${watch_dir}"/*; do
            [[ -f "$file" ]] || continue

            local ext="${file##*.}"
            ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

            # Check if extension is supported
            local supported=0
            local supported_ext
            for supported_ext in $supported_extensions; do
                if [[ "$ext" == "$supported_ext" ]]; then
                    supported=1
                    break
                fi
            done
            [[ "$supported" -eq 1 ]] || continue

            # Check if already processed (by inode + mtime to handle renames)
            local file_id
            file_id="$(stat -f '%i:%m' "$file" 2>/dev/null || stat -c '%i:%Y' "$file" 2>/dev/null)"
            if grep -qF "$file_id" "$processed_log" 2>/dev/null; then
                continue
            fi

            echo ""
            print_info "New document detected: ${file}"

            # Use accounting-extract for auto schema, otherwise regular extract
            if [[ "$schema" == "auto" ]]; then
                if do_accounting_extract "$file" "$privacy"; then
                    echo "$file_id" >> "$processed_log"
                fi
            else
                if do_extract "$file" "$schema" "$privacy" "json"; then
                    echo "$file_id" >> "$processed_log"
                fi
            fi
        done

        sleep "$interval"
    done
}

# Batch extract from directory
do_batch() {
    local input_dir="$1"
    local schema="${2:-auto}"
    local privacy="${3:-none}"
    local pattern="${4:-*}"

    if [[ ! -d "$input_dir" ]]; then
        print_error "Directory not found: ${input_dir}"
        return 1
    fi

    ensure_workspace

    local count=0
    local failed=0
    local supported_extensions="pdf docx pptx xlsx html htm png jpg jpeg tiff bmp"

    print_info "Batch extracting from ${input_dir} (pattern=${pattern}, schema=${schema})..."

    for file in "${input_dir}"/${pattern}; do
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

        echo ""
        print_info "Processing: ${file}"
        if do_extract "$file" "$schema" "$privacy" "json"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    print_success "Batch complete: ${count} succeeded, ${failed} failed"
    print_info "Output directory: ${WORKSPACE_DIR}"
    return 0
}

# List available schemas
do_schemas() {
    echo "Available Extraction Schemas"
    echo "============================"
    echo ""
    echo "  invoice       - Vendor/customer details, VAT breakdowns, line items,"
    echo "                  payment terms, PO numbers, multi-currency (default: GBP)"
    echo "  receipt       - Merchant, items with VAT codes, payment method,"
    echo "                  card details, store/cashier info"
    echo "  contract      - Parties, dates, key terms, obligations"
    echo "  id-document   - Name, DOB, document number, expiry"
    echo "  auto          - Auto-detect and convert to markdown (default)"
    echo ""
    echo "Accounting Schemas (invoice/receipt) include:"
    echo "  - UK VAT support (standard/reduced/zero/exempt/reverse charge)"
    echo "  - Multi-currency with GBP default"
    echo "  - Tax breakdown by rate"
    echo "  - QuickFile field mapping in accounting-extract output"
    echo ""
    echo "Custom schemas can be defined as Pydantic models in Python."
    echo "See: .agents/tools/document/document-extraction.md"
    return 0
}

# Show help
do_help() {
    echo "Document Extraction Helper - AI DevOps Framework"
    echo ""
    echo "${HELP_LABEL_USAGE}"
    echo "  document-extraction-helper.sh <command> [options]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  extract <file> [--schema <name>] [--privacy <mode>] [--output <format>]"
    echo "      Extract structured data from a document"
    echo ""
    echo "  classify <file> [--privacy <mode>]"
    echo "      Auto-detect document type (invoice, receipt, or unknown)"
    echo ""
    echo "  accounting-extract <file> [--privacy <mode>]"
    echo "      Auto-classify and extract for accounting (QuickFile-ready output)"
    echo ""
    echo "  batch <dir> [--schema <name>] [--privacy <mode>] [--pattern <glob>]"
    echo "      Batch extract from all documents in a directory"
    echo ""
    echo "  watch <dir> [--schema <name>] [--privacy <mode>] [--interval <secs>]"
    echo "      Watch directory for new documents and auto-extract"
    echo ""
    echo "  pii-scan <file>"
    echo "      Scan a text file for PII entities"
    echo ""
    echo "  pii-redact <file> [--output <file>]"
    echo "      Redact PII from a text file"
    echo ""
    echo "  convert <file> [--output <format>]"
    echo "      Convert document to markdown/JSON/text (no LLM needed)"
    echo ""
    echo "  install [--all|--core|--pii|--llm]"
    echo "      Install dependencies (default: --all)"
    echo ""
    echo "  status"
    echo "      Check installed components"
    echo ""
    echo "  schemas"
    echo "      List available extraction schemas"
    echo ""
    echo "Privacy Modes:"
    echo "  local   - Fully local via Ollama (no data leaves machine)"
    echo "  edge    - Cloudflare Workers AI (privacy-preserving cloud)"
    echo "  cloud   - OpenAI/Anthropic APIs (best quality)"
    echo "  none    - Auto-select best available backend (default)"
    echo ""
    echo "Output Formats: json, markdown, text"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  # Extract invoice with UK VAT support"
    echo "  document-extraction-helper.sh extract invoice.pdf --schema invoice --privacy local"
    echo ""
    echo "  # Auto-classify and extract for QuickFile accounting"
    echo "  document-extraction-helper.sh accounting-extract receipt.jpg"
    echo ""
    echo "  # Batch process a folder of invoices"
    echo "  document-extraction-helper.sh batch ./invoices --schema invoice"
    echo ""
    echo "  # Watch a folder for new receipts (e.g. phone camera uploads)"
    echo "  document-extraction-helper.sh watch ~/Downloads/receipts --interval 30"
    echo ""
    echo "  # Classify a document before extraction"
    echo "  document-extraction-helper.sh classify unknown-doc.pdf"
    echo ""
    echo "  # PII operations"
    echo "  document-extraction-helper.sh pii-scan document.txt"
    echo "  document-extraction-helper.sh pii-redact document.txt --output redacted.txt"
    echo ""
    echo "  # Simple conversion (no LLM needed)"
    echo "  document-extraction-helper.sh convert report.pdf --output markdown"
    echo ""
    echo "  # Install dependencies"
    echo "  document-extraction-helper.sh install --core"
    return 0
}

# Parse command-line arguments
parse_args() {
    local command="${1:-help}"
    shift || true

    # Parse named options
    local file=""
    local schema="auto"
    local privacy="none"
    local output_format="json"
    local output_file=""
    local pattern="*"
    local install_component="all"
    local interval="10"

    # First positional arg after command is the file/dir
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        file="$1"
        shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema)
                schema="${2:-auto}"
                shift 2 || { print_error "Missing value for --schema"; return 1; }
                ;;
            --privacy)
                privacy="${2:-none}"
                shift 2 || { print_error "Missing value for --privacy"; return 1; }
                ;;
            --output)
                output_format="${2:-json}"
                shift 2 || { print_error "Missing value for --output"; return 1; }
                ;;
            --pattern)
                pattern="${2:-*}"
                shift 2 || { print_error "Missing value for --pattern"; return 1; }
                ;;
            --interval)
                interval="${2:-10}"
                shift 2 || { print_error "Missing value for --interval"; return 1; }
                ;;
            --all|--core|--pii|--llm)
                install_component="${1#--}"
                shift
                ;;
            *)
                # Treat as output file for pii-redact
                if [[ "$command" == "pii-redact" ]] && [[ -z "$output_file" ]]; then
                    output_file="$1"
                fi
                shift
                ;;
        esac
    done

    case "$command" in
        extract)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_extract "$file" "$schema" "$privacy" "$output_format"
            ;;
        classify)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_classify "$file" "$privacy"
            ;;
        accounting-extract)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_accounting_extract "$file" "$privacy"
            ;;
        batch)
            if [[ -z "$file" ]]; then
                print_error "Input directory is required"
                return 1
            fi
            do_batch "$file" "$schema" "$privacy" "$pattern"
            ;;
        watch)
            if [[ -z "$file" ]]; then
                print_error "Watch directory is required"
                return 1
            fi
            do_watch "$file" "$schema" "$privacy" "$interval"
            ;;
        pii-scan)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_pii_scan "$file"
            ;;
        pii-redact)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_pii_redact "$file" "$output_file"
            ;;
        convert)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_convert "$file" "$output_format"
            ;;
        install)
            do_install "$install_component"
            ;;
        status)
            do_status
            ;;
        schemas)
            do_schemas
            ;;
        help|--help|-h)
            do_help
            ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
            do_help
            return 1
            ;;
    esac
}

# Main entry point
parse_args "$@"
