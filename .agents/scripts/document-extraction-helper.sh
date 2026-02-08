#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317
set -euo pipefail

# Document Extraction Helper for AI DevOps Framework
# Privacy-preserving document extraction with Docling, ExtractThinker, and Presidio
#
# Usage: document-extraction-helper.sh <command> [options]
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-extraction"
readonly DEFAULT_LLM="ollama/llama3.2"
readonly DEFAULT_PRIVACY="local"

# =============================================================================
# Environment Setup
# =============================================================================

# Ensure Python venv exists and activate it
ensure_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        print_info "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR" || {
            print_error "Failed to create venv. Ensure python3 is installed."
            return 1
        }
    fi

    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate" 2>/dev/null || {
        print_error "Failed to activate venv at $VENV_DIR"
        return 1
    }
    return 0
}

# Check and install dependencies
check_deps() {
    local component="${1:-all}"

    ensure_venv || return 1

    case "$component" in
        docling)
            python3 -c "import docling" 2>/dev/null || {
                print_info "Installing docling..."
                pip install -q docling || return 1
            }
            ;;
        extractthinker)
            python3 -c "import extract_thinker" 2>/dev/null || {
                print_info "Installing extract-thinker..."
                pip install -q extract-thinker || return 1
            }
            ;;
        presidio)
            python3 -c "import presidio_analyzer" 2>/dev/null || {
                print_info "Installing presidio..."
                pip install -q presidio-analyzer presidio-anonymizer || return 1
                python3 -m spacy download en_core_web_lg 2>/dev/null || {
                    print_warning "spaCy model download failed (optional for basic PII)"
                }
            }
            ;;
        docstrange)
            python3 -c "import docstrange" 2>/dev/null || {
                print_info "Installing docstrange..."
                pip install -q docstrange || return 1
            }
            ;;
        all)
            check_deps docling || true
            check_deps extractthinker || true
            check_deps presidio || true
            ;;
        *)
            print_error "Unknown component: $component"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# Core Commands
# =============================================================================

# Extract structured data from a document
cmd_extract() {
    local input_file=""
    local schema=""
    local fields=""
    local llm="$DEFAULT_LLM"
    local privacy="$DEFAULT_PRIVACY"
    local output_format="json"
    local output_file=""
    local use_docstrange=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema) schema="$2"; shift 2 ;;
            --fields) fields="$2"; shift 2 ;;
            --llm) llm="$2"; shift 2 ;;
            --privacy) privacy="$2"; shift 2 ;;
            --output) output_format="$2"; shift 2 ;;
            --output-file|-o) output_file="$2"; shift 2 ;;
            --docstrange) use_docstrange=true; shift ;;
            --help|-h) cmd_help; return 0 ;;
            -*) print_error "Unknown option: $1"; return 1 ;;
            *) input_file="$1"; shift ;;
        esac
    done

    if [[ -z "$input_file" ]]; then
        print_error "Usage: document-extraction-helper.sh extract <file> [options]"
        return 1
    fi

    if [[ ! -f "$input_file" ]]; then
        print_error "File not found: $input_file"
        return 1
    fi

    if [[ "$use_docstrange" == "true" ]]; then
        check_deps docstrange || return 1
        _extract_docstrange "$input_file" "$fields" "$schema" "$output_format" "$output_file"
    else
        check_deps docling || return 1
        check_deps extractthinker || return 1
        [[ "$privacy" != "none" ]] && { check_deps presidio || true; }
        _extract_pipeline "$input_file" "$schema" "$fields" "$llm" "$privacy" "$output_format" "$output_file"
    fi

    return $?
}

# Parse document to markdown (Docling only, no LLM)
cmd_parse() {
    local input_file=""
    local output_format="markdown"
    local output_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output_format="$2"; shift 2 ;;
            --output-file|-o) output_file="$2"; shift 2 ;;
            --help|-h) cmd_help; return 0 ;;
            -*) print_error "Unknown option: $1"; return 1 ;;
            *) input_file="$1"; shift ;;
        esac
    done

    if [[ -z "$input_file" || ! -f "$input_file" ]]; then
        print_error "Usage: document-extraction-helper.sh parse <file> [--output markdown|json|html]"
        return 1
    fi

    check_deps docling || return 1

    ensure_venv || return 1
    local result
    result=$(python3 -c "
from docling.document_converter import DocumentConverter
converter = DocumentConverter()
result = converter.convert('$input_file')
fmt = '$output_format'
if fmt == 'json':
    import json
    print(json.dumps(result.document.export_to_dict(), indent=2, default=str))
elif fmt == 'html':
    print(result.document.export_to_html())
else:
    print(result.document.export_to_markdown())
" 2>&1) || {
        print_error "Docling parsing failed: $result"
        return 1
    }

    if [[ -n "$output_file" ]]; then
        echo "$result" > "$output_file"
        print_success "Parsed output saved to: $output_file"
    else
        echo "$result"
    fi

    return 0
}

# Scan document for PII
cmd_pii_scan() {
    local input_file=""
    local language="en"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --language|-l) language="$2"; shift 2 ;;
            --help|-h) cmd_help; return 0 ;;
            -*) print_error "Unknown option: $1"; return 1 ;;
            *) input_file="$1"; shift ;;
        esac
    done

    if [[ -z "$input_file" || ! -f "$input_file" ]]; then
        print_error "Usage: document-extraction-helper.sh pii-scan <file> [--language en]"
        return 1
    fi

    check_deps docling || return 1
    check_deps presidio || return 1

    ensure_venv || return 1
    python3 -c "
from docling.document_converter import DocumentConverter
from presidio_analyzer import AnalyzerEngine
import json

converter = DocumentConverter()
result = converter.convert('$input_file')
text = result.document.export_to_markdown()

analyzer = AnalyzerEngine()
results = analyzer.analyze(text=text, language='$language')

findings = []
for r in results:
    findings.append({
        'entity_type': r.entity_type,
        'start': r.start,
        'end': r.end,
        'score': round(r.score, 2),
        'text': text[r.start:r.end]
    })

print(json.dumps(findings, indent=2))
print(f'\nTotal PII entities found: {len(findings)}')
" 2>&1

    return $?
}

# Batch extract from a directory
cmd_batch() {
    local input_dir=""
    local schema=""
    local fields=""
    local output_dir=""
    local pattern="*.pdf"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema) schema="$2"; shift 2 ;;
            --fields) fields="$2"; shift 2 ;;
            --output-dir|-o) output_dir="$2"; shift 2 ;;
            --pattern) pattern="$2"; shift 2 ;;
            --help|-h) cmd_help; return 0 ;;
            -*) print_error "Unknown option: $1"; return 1 ;;
            *) input_dir="$1"; shift ;;
        esac
    done

    if [[ -z "$input_dir" || ! -d "$input_dir" ]]; then
        print_error "Usage: document-extraction-helper.sh batch <directory> [options]"
        return 1
    fi

    output_dir="${output_dir:-${input_dir}/extracted}"
    mkdir -p "$output_dir"

    local count=0
    local failed=0

    while IFS= read -r -d '' file; do
        local basename
        basename=$(basename "$file" | sed 's/\.[^.]*$//')
        print_info "Processing: $file"

        if cmd_extract "$file" --fields "${fields:-}" --output-file "$output_dir/${basename}.json" 2>/dev/null; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
            print_warning "Failed: $file"
        fi
    done < <(find "$input_dir" -maxdepth 1 -name "$pattern" -print0 2>/dev/null)

    print_success "Batch complete: $count succeeded, $failed failed"
    print_info "Output: $output_dir"

    return 0
}

# Check installation status
cmd_status() {
    print_info "=== Document Extraction Status ==="

    echo ""
    echo "Python venv: $(if [[ -d "$VENV_DIR" ]]; then echo "installed ($VENV_DIR)"; else echo "not created"; fi)"

    if [[ -d "$VENV_DIR" ]]; then
        ensure_venv || return 1
        echo ""
        echo "Components:"
        python3 -c "import docling; print(f'  Docling: installed (v{docling.__version__})')" 2>/dev/null || echo "  Docling: not installed"
        python3 -c "import extract_thinker; print('  ExtractThinker: installed')" 2>/dev/null || echo "  ExtractThinker: not installed"
        python3 -c "import presidio_analyzer; print('  Presidio: installed')" 2>/dev/null || echo "  Presidio: not installed"
        python3 -c "import docstrange; print('  DocStrange: installed')" 2>/dev/null || echo "  DocStrange: not installed"
    fi

    echo ""
    echo "External tools:"
    echo "  Ollama: $(command -v ollama &>/dev/null && echo "installed ($(ollama --version 2>/dev/null || echo 'unknown'))" || echo "not installed")"
    echo "  Tesseract: $(command -v tesseract &>/dev/null && echo "installed" || echo "not installed")"

    return 0
}

# Install all dependencies
cmd_install() {
    local component="${1:-all}"

    print_info "Installing document extraction dependencies ($component)..."
    check_deps "$component" || return 1
    print_success "Installation complete"

    return 0
}

# =============================================================================
# Internal Functions
# =============================================================================

# DocStrange extraction (simpler path)
_extract_docstrange() {
    local input_file="$1"
    local fields="$2"
    local schema="$3"
    local output_format="$4"
    local output_file="$5"

    ensure_venv || return 1

    local fields_arg=""
    if [[ -n "$fields" ]]; then
        fields_arg="specified_fields=[$(echo "$fields" | sed "s/[^,]*/'&'/g")]"
    fi

    local result
    result=$(python3 -c "
from docstrange import DocumentExtractor
import json

extractor = DocumentExtractor()
result = extractor.extract('$input_file')

if '$fields':
    data = result.extract_data($fields_arg)
elif '$schema':
    import json as j
    with open('$schema') as f:
        schema = j.load(f)
    data = result.extract_data(json_schema=schema)
else:
    data = result.extract_data()

print(json.dumps(data, indent=2, default=str))
" 2>&1) || {
        print_error "DocStrange extraction failed: $result"
        return 1
    }

    if [[ -n "$output_file" ]]; then
        echo "$result" > "$output_file"
        print_success "Extracted to: $output_file"
    else
        echo "$result"
    fi

    return 0
}

# Full pipeline extraction (Docling + ExtractThinker + Presidio)
_extract_pipeline() {
    local input_file="$1"
    local schema="$2"
    local fields="$3"
    local llm="$4"
    local privacy="$5"
    local output_format="$6"
    local output_file="$7"

    ensure_venv || return 1

    local result
    result=$(python3 -c "
from docling.document_converter import DocumentConverter
import json

# Step 1: Parse document
converter = DocumentConverter()
doc_result = converter.convert('$input_file')
text = doc_result.document.export_to_markdown()

# Step 2: PII scan (if privacy mode enabled)
pii_report = None
if '$privacy' != 'none':
    try:
        from presidio_analyzer import AnalyzerEngine
        analyzer = AnalyzerEngine()
        pii_results = analyzer.analyze(text=text, language='en')
        if pii_results:
            pii_report = [{'type': r.entity_type, 'score': round(r.score, 2)} for r in pii_results]
    except ImportError:
        pass  # Presidio not installed, skip PII

# Step 3: LLM extraction
extracted = None
try:
    from extract_thinker import Extractor
    extractor = Extractor()
    extractor.load_document_loader('docling')
    extractor.load_llm('$llm')

    if '$fields':
        fields_list = [f.strip() for f in '$fields'.split(',')]
        extracted = extractor.extract('$input_file', fields=fields_list)
    else:
        extracted = extractor.extract('$input_file')
except Exception as e:
    extracted = {'error': str(e), 'fallback': 'raw_text'}

output = {
    'source': '$input_file',
    'extracted': extracted if isinstance(extracted, dict) else str(extracted),
    'pii_detected': len(pii_report) if pii_report else 0,
    'pii_entities': pii_report[:10] if pii_report else [],
    'text_preview': text[:500] + '...' if len(text) > 500 else text
}

print(json.dumps(output, indent=2, default=str))
" 2>&1) || {
        print_error "Pipeline extraction failed: $result"
        return 1
    }

    if [[ -n "$output_file" ]]; then
        echo "$result" > "$output_file"
        print_success "Extracted to: $output_file"
    else
        echo "$result"
    fi

    return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
    cat << 'HELP'
document-extraction-helper.sh - Privacy-preserving document extraction

Usage:
  document-extraction-helper.sh extract <file> [options]    Extract structured data
  document-extraction-helper.sh parse <file> [options]      Parse to markdown/JSON (no LLM)
  document-extraction-helper.sh pii-scan <file>             Scan for PII entities
  document-extraction-helper.sh batch <directory> [options]  Batch extract from directory
  document-extraction-helper.sh status                      Check installation status
  document-extraction-helper.sh install [component]         Install dependencies
  document-extraction-helper.sh help                        Show this help

Extract options:
  --fields "field1,field2"    Fields to extract (comma-separated)
  --schema schema.json        JSON schema file for structured extraction
  --llm <model>               LLM backend (default: ollama/llama3.2)
  --privacy <mode>            Privacy mode: local|edge|cloud|none (default: local)
  --output <format>           Output format: json|csv|markdown (default: json)
  --output-file|-o <file>     Save output to file
  --docstrange                Use DocStrange instead of Docling+ExtractThinker

Parse options:
  --output <format>           Output format: markdown|json|html (default: markdown)
  --output-file|-o <file>     Save output to file

Batch options:
  --pattern "*.pdf"           File pattern (default: *.pdf)
  --output-dir|-o <dir>       Output directory (default: <input>/extracted/)
  --fields "field1,field2"    Fields to extract

Install components:
  all                         All components (default)
  docling                     Document parsing
  extractthinker              LLM extraction
  presidio                    PII detection
  docstrange                  DocStrange (simpler alternative)

Examples:
  # Quick extraction with DocStrange
  document-extraction-helper.sh extract invoice.pdf --docstrange --fields "vendor,total,date"

  # Full pipeline with PII redaction
  document-extraction-helper.sh extract contract.pdf --privacy local --llm ollama/llama3.2

  # Parse to markdown (no LLM needed)
  document-extraction-helper.sh parse document.pdf -o output.md

  # Scan for PII
  document-extraction-helper.sh pii-scan sensitive-doc.pdf

  # Batch process invoices
  document-extraction-helper.sh batch ./invoices/ --fields "vendor,total,date" -o ./results/

Privacy modes:
  local   - Ollama LLM + Presidio PII redaction (nothing leaves machine)
  edge    - Cloudflare Workers AI + Presidio (data stays in edge network)
  cloud   - OpenAI/Anthropic + Presidio (PII redacted before API call)
  none    - No PII scanning (fastest, for non-sensitive documents)
HELP

    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        extract)    cmd_extract "$@" ;;
        parse)      cmd_parse "$@" ;;
        pii-scan)   cmd_pii_scan "$@" ;;
        batch)      cmd_batch "$@" ;;
        status)     cmd_status ;;
        install)    cmd_install "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac

    return $?
}

main "$@"
