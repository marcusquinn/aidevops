#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# QuickFile Integration Helper for AI DevOps Framework
# Bridges OCR extraction pipeline with QuickFile accounting via MCP tools.
# Handles supplier resolution, purchase/expense recording, and batch processing.
#
# Usage: quickfile-helper.sh [command] [options]
#
# Commands:
#   record-purchase <json>   Record a purchase invoice in QuickFile from extracted JSON
#   record-expense <json>    Record an expense receipt in QuickFile from extracted JSON
#   supplier-resolve <name>  Find or create a supplier by name
#   batch-record <dir>       Batch record all *-quickfile.json files in a directory
#   preview <json>           Show what would be recorded (dry run)
#   status                   Check QuickFile MCP connectivity and credentials
#   help                     Show this help
#
# Options:
#   --dry-run                Preview without recording
#   --nominal <code>         Override nominal code for all line items
#   --supplier-id <id>       Skip supplier lookup, use this ID directly
#   --auto-supplier          Auto-create supplier if not found (default: prompt)
#   --currency <code>        Override currency (default: GBP)
#
# Integration:
#   This script generates MCP tool call instructions for the AI assistant.
#   It does NOT call QuickFile APIs directly — the AI assistant executes
#   the MCP tool calls (quickfile_supplier_search, quickfile_purchase_create, etc.)
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly QF_WORKSPACE="${HOME}/.aidevops/.agent-workspace/work/quickfile"
readonly OCR_WORKSPACE="${HOME}/.aidevops/.agent-workspace/work/ocr-receipts"
readonly QF_MCP_DIR="${HOME}/Git/quickfile-mcp"
readonly QF_CREDENTIALS="${HOME}/.config/.quickfile-mcp/credentials.json"
readonly DEFAULT_NOMINAL="5000"
readonly DEFAULT_CURRENCY="GBP"

# Ensure workspace exists
ensure_workspace() {
    mkdir -p "$QF_WORKSPACE" 2>/dev/null || true
    return 0
}

# Validate JSON file and check it has required fields
validate_extraction_json() {
    local json_file="$1"
    local record_type="${2:-purchase}"

    validate_file_exists "$json_file" "Extraction JSON" || return 1

    # Check it's valid JSON
    if ! python3 -m json.tool "$json_file" > /dev/null 2>&1; then
        print_error "Invalid JSON: ${json_file}"
        return 1
    fi

    # Check required fields based on record type
    local missing_fields
    missing_fields="$(python3 -c "
import json, sys

with open('${json_file}', 'r') as f:
    data = json.load(f)

# Navigate to data payload (may be nested under 'data' key)
payload = data.get('data', data)

record_type = '${record_type}'
missing = []

if record_type == 'purchase':
    if not payload.get('supplier_name') and not payload.get('vendor_name'):
        missing.append('supplier_name or vendor_name')
    if not payload.get('total') and payload.get('total') != 0:
        missing.append('total')
elif record_type == 'expense':
    if not payload.get('supplier_name') and not payload.get('merchant_name') and not payload.get('merchant'):
        missing.append('supplier_name, merchant_name, or merchant')
    if not payload.get('total') and payload.get('total') != 0:
        missing.append('total')

if missing:
    print(', '.join(missing))
" 2>/dev/null)" || {
        print_error "Failed to validate JSON structure"
        return 1
    }

    if [[ -n "$missing_fields" ]]; then
        print_error "Missing required fields: ${missing_fields}"
        return 1
    fi

    return 0
}

# Generate supplier resolution instructions
generate_supplier_instructions() {
    local supplier_name="$1"
    local supplier_id="${2:-}"
    local auto_create="${3:-false}"

    if [[ -n "$supplier_id" ]]; then
        echo "  Supplier ID: ${supplier_id} (provided directly, skip lookup)"
        return 0
    fi

    echo "  1. Search for supplier:"
    echo "     quickfile_supplier_search({ \"searchTerm\": \"${supplier_name}\" })"
    echo ""
    echo "  2. If found: use the returned SupplierId"
    echo "     If NOT found:"
    if [[ "$auto_create" == "true" ]]; then
        echo "     quickfile_supplier_create({"
        echo "       \"companyName\": \"${supplier_name}\""
        echo "     })"
    else
        echo "     Ask user whether to create supplier \"${supplier_name}\" or map to existing"
    fi
    return 0
}

# Generate purchase invoice creation instructions from JSON
generate_purchase_instructions() {
    local json_file="$1"
    local nominal_override="${2:-}"
    local currency_override="${3:-}"
    local supplier_id="${4:-}"

    python3 -c "
import json
import sys

with open('${json_file}', 'r') as f:
    data = json.load(f)

payload = data.get('data', data)
nominal_override = '${nominal_override}' or None
currency_override = '${currency_override}' or None
supplier_id = '${supplier_id}' or None

# Resolve supplier name
supplier = (payload.get('supplier_name')
            or payload.get('vendor_name')
            or payload.get('merchant_name')
            or payload.get('merchant')
            or 'Unknown Supplier')

# Resolve dates
inv_date = (payload.get('invoice_date')
            or payload.get('date')
            or 'YYYY-MM-DD')
due_date = payload.get('due_date', '')

# Resolve amounts
total = float(payload.get('total', 0) or 0)
vat = float(payload.get('vat_amount', 0) or payload.get('tax_amount', 0) or 0)
subtotal = float(payload.get('subtotal', 0) or 0)
if subtotal == 0 and total > 0:
    subtotal = total - vat

# Currency
currency = currency_override or payload.get('currency', '${DEFAULT_CURRENCY}')

# Invoice reference
inv_ref = (payload.get('invoice_number')
           or payload.get('receipt_number')
           or '')

# Build line items
raw_items = payload.get('line_items', payload.get('items', []))
lines = []
if raw_items:
    for item in raw_items:
        desc = item.get('description', item.get('name', 'Item'))
        qty = float(item.get('quantity', 1) or 1)
        unit_cost = float(item.get('unit_price', item.get('price', 0)) or 0)
        nominal = nominal_override or item.get('nominal_code', '${DEFAULT_NOMINAL}')
        vat_pct = item.get('vat_rate', '20')
        if vat_pct is None:
            vat_pct = '20'
        lines.append({
            'description': desc,
            'quantity': qty,
            'unitCost': unit_cost,
            'nominalCode': str(nominal),
            'vatPercentage': str(vat_pct)
        })
else:
    # Single line item from totals
    nominal = nominal_override or '${DEFAULT_NOMINAL}'
    lines.append({
        'description': f'Purchase from {supplier}',
        'quantity': 1,
        'unitCost': subtotal,
        'nominalCode': str(nominal),
        'vatPercentage': '20'
    })

# Output the MCP call
print('  quickfile_purchase_create({')
if supplier_id:
    print(f'    \"supplierId\": \"{supplier_id}\",')
else:
    print(f'    \"supplierId\": \"<from supplier lookup>\",')
if inv_ref:
    print(f'    \"supplierRef\": \"{inv_ref}\",')
print(f'    \"issueDate\": \"{inv_date}\",')
if due_date:
    print(f'    \"dueDate\": \"{due_date}\",')
print(f'    \"currency\": \"{currency}\",')
print(f'    \"lines\": [')
for i, line in enumerate(lines):
    comma = ',' if i < len(lines) - 1 else ''
    print(f'      {{')
    print(f'        \"description\": \"{line[\"description\"]}\",')
    print(f'        \"quantity\": {line[\"quantity\"]},')
    print(f'        \"unitCost\": {line[\"unitCost\"]},')
    print(f'        \"nominalCode\": \"{line[\"nominalCode\"]}\",')
    print(f'        \"vatPercentage\": \"{line[\"vatPercentage\"]}\"')
    print(f'      }}{comma}')
print(f'    ]')
print(f'  }})')
print()
print(f'  Summary: {supplier} | {inv_date} | {currency} {total:.2f} (net {subtotal:.2f} + VAT {vat:.2f})')
" 2>/dev/null || {
        print_error "Failed to generate purchase instructions"
        return 1
    }

    return 0
}

# Record a purchase invoice
cmd_record_purchase() {
    local json_file="$1"
    local dry_run="${2:-false}"
    local nominal_override="${3:-}"
    local supplier_id="${4:-}"
    local auto_supplier="${5:-false}"
    local currency_override="${6:-}"

    validate_extraction_json "$json_file" "purchase" || return 1
    ensure_workspace

    # Extract supplier name for resolution
    local supplier_name
    supplier_name="$(python3 -c "
import json
with open('${json_file}', 'r') as f:
    data = json.load(f)
payload = data.get('data', data)
print(payload.get('supplier_name', '')
      or payload.get('vendor_name', '')
      or payload.get('merchant_name', '')
      or payload.get('merchant', '')
      or 'Unknown Supplier')
" 2>/dev/null)" || supplier_name="Unknown Supplier"

    echo ""
    echo "QuickFile Purchase Invoice Recording"
    echo "====================================="
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo "  [DRY RUN - no changes will be made]"
        echo ""
    fi

    echo "Step 1: Resolve Supplier"
    echo "------------------------"
    generate_supplier_instructions "$supplier_name" "$supplier_id" "$auto_supplier"
    echo ""

    echo "Step 2: Create Purchase Invoice"
    echo "-------------------------------"
    generate_purchase_instructions "$json_file" "$nominal_override" "$currency_override" "$supplier_id"
    echo ""

    if [[ "$dry_run" != "true" ]]; then
        # Save the instruction set for the AI assistant
        local basename
        basename="$(basename "$json_file" | sed 's/\.[^.]*$//')"
        local instruction_file="${QF_WORKSPACE}/${basename}-instructions.md"

        {
            echo "# QuickFile Purchase Invoice Instructions"
            echo ""
            echo "Source: ${json_file}"
            echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo ""
            echo "## Step 1: Resolve Supplier"
            echo ""
            echo '```'
            generate_supplier_instructions "$supplier_name" "$supplier_id" "$auto_supplier"
            echo '```'
            echo ""
            echo "## Step 2: Create Purchase Invoice"
            echo ""
            echo '```'
            generate_purchase_instructions "$json_file" "$nominal_override" "$currency_override" "$supplier_id"
            echo '```'
        } > "$instruction_file"

        print_success "Instructions saved to: ${instruction_file}"
        echo ""
        print_info "Execute these MCP tool calls in your AI assistant session to record the purchase."
    fi

    return 0
}

# Record an expense receipt (same flow as purchase but with expense-specific handling)
cmd_record_expense() {
    local json_file="$1"
    local dry_run="${2:-false}"
    local nominal_override="${3:-}"
    local supplier_id="${4:-}"
    local auto_supplier="${5:-true}"
    local currency_override="${6:-}"

    validate_extraction_json "$json_file" "expense" || return 1
    ensure_workspace

    # For expenses, auto-categorise nominal code if not overridden
    if [[ -z "$nominal_override" ]]; then
        local auto_nominal
        auto_nominal="$(python3 -c "
import json

with open('${json_file}', 'r') as f:
    data = json.load(f)

payload = data.get('data', data)
supplier = (payload.get('supplier_name', '')
            or payload.get('merchant_name', '')
            or payload.get('merchant', '')
            or '').lower()

# Check line items for category hints
items = payload.get('items', payload.get('line_items', []))
item_text = ' '.join(
    (i.get('description', '') or i.get('name', '')).lower()
    for i in items
)

combined = supplier + ' ' + item_text

# Pattern-based categorisation (matches extraction-schemas.md)
categories = [
    (['shell', 'bp', 'esso', 'fuel', 'petrol', 'diesel'], '7401'),
    (['hotel', 'airbnb', 'accommodation', 'booking.com'], '7403'),
    (['restaurant', 'cafe', 'food', 'lunch', 'dinner', 'coffee'], '7402'),
    (['train', 'bus', 'taxi', 'uber', 'parking', 'travel'], '7400'),
    (['royal mail', 'dhl', 'fedex', 'postage', 'shipping'], '7501'),
    (['bt', 'vodafone', 'phone', 'broadband', 'internet'], '7502'),
    (['adobe', 'microsoft', 'saas', 'subscription', 'software'], '7404'),
    (['google ads', 'facebook ads', 'marketing', 'advertising'], '6201'),
    (['accountant', 'solicitor', 'legal', 'professional'], '7600'),
    (['plumber', 'electrician', 'repair', 'maintenance'], '7300'),
    (['amazon', 'staples', 'office', 'stationery', 'supplies'], '7504'),
]

nominal = '5000'  # Default: General Purchases
for keywords, code in categories:
    if any(kw in combined for kw in keywords):
        nominal = code
        break

print(nominal)
" 2>/dev/null)" || auto_nominal="${DEFAULT_NOMINAL}"
        nominal_override="$auto_nominal"
        print_info "Auto-categorised nominal code: ${nominal_override}"
    fi

    # Delegate to purchase recording (expenses are purchase invoices in QuickFile)
    cmd_record_purchase "$json_file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override"
    return $?
}

# Resolve a supplier by name
cmd_supplier_resolve() {
    local supplier_name="$1"
    local auto_create="${2:-false}"

    echo ""
    echo "Supplier Resolution"
    echo "==================="
    echo ""
    generate_supplier_instructions "$supplier_name" "" "$auto_create"
    echo ""
    print_info "Execute the quickfile_supplier_search MCP tool call in your AI session."
    return 0
}

# Batch record all quickfile JSON files in a directory
cmd_batch_record() {
    local input_dir="$1"
    local dry_run="${2:-false}"
    local nominal_override="${3:-}"
    local auto_supplier="${4:-true}"
    local currency_override="${5:-}"

    if [[ ! -d "$input_dir" ]]; then
        print_error "Directory not found: ${input_dir}"
        return 1
    fi

    ensure_workspace

    local count=0
    local failed=0
    local skipped=0

    print_info "Batch recording QuickFile purchases from: ${input_dir}"
    echo ""

    for json_file in "${input_dir}"/*-quickfile.json "${input_dir}"/*-extracted.json; do
        [[ -f "$json_file" ]] || continue

        echo "=== $(basename "$json_file") ==="
        if cmd_record_purchase "$json_file" "$dry_run" "$nominal_override" "" "$auto_supplier" "$currency_override"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done

    if [[ "$count" -eq 0 ]] && [[ "$failed" -eq 0 ]]; then
        print_warning "No *-quickfile.json or *-extracted.json files found in ${input_dir}"
        return 1
    fi

    echo "=== Batch Summary ==="
    print_success "Processed: ${count} succeeded, ${failed} failed"
    if [[ "$dry_run" == "true" ]]; then
        print_info "[DRY RUN - no changes were made]"
    fi
    return 0
}

# Preview what would be recorded
cmd_preview() {
    local json_file="$1"
    local nominal_override="${2:-}"
    local currency_override="${3:-}"

    cmd_record_purchase "$json_file" "true" "$nominal_override" "" "false" "$currency_override"
    return $?
}

# Check QuickFile MCP status
cmd_status() {
    echo "QuickFile Integration - Status"
    echo "==============================="
    echo ""

    # QuickFile MCP server
    echo "MCP Server:"
    if [[ -f "${QF_MCP_DIR}/dist/index.js" ]]; then
        echo "  quickfile-mcp:  installed (${QF_MCP_DIR})"
    else
        echo "  quickfile-mcp:  not found"
        echo "  Install: cd ~/Git && git clone https://github.com/marcusquinn/quickfile-mcp.git"
        echo "           cd quickfile-mcp && npm install && npm run build"
    fi

    # Credentials
    echo ""
    echo "Credentials:"
    if [[ -f "$QF_CREDENTIALS" ]]; then
        echo "  credentials:    configured (${QF_CREDENTIALS})"
        # Check file permissions
        local perms
        perms="$(stat -f '%Lp' "$QF_CREDENTIALS" 2>/dev/null || stat -c '%a' "$QF_CREDENTIALS" 2>/dev/null || echo "unknown")"
        if [[ "$perms" == "600" ]]; then
            echo "  permissions:    600 (correct)"
        else
            echo "  permissions:    ${perms} (should be 600)"
        fi
    else
        echo "  credentials:    not configured"
        echo "  Setup: mkdir -p ~/.config/.quickfile-mcp && chmod 700 ~/.config/.quickfile-mcp"
        echo "         Create ~/.config/.quickfile-mcp/credentials.json with:"
        echo "         { \"accountNumber\": \"...\", \"apiKey\": \"...\", \"applicationId\": \"...\" }"
    fi

    # OCR pipeline
    echo ""
    echo "OCR Pipeline:"
    if [[ -x "${SCRIPT_DIR}/ocr-receipt-helper.sh" ]]; then
        echo "  ocr-receipt-helper:  available"
    else
        echo "  ocr-receipt-helper:  not found"
    fi

    # Workspace
    echo ""
    echo "Workspace:"
    echo "  quickfile dir:  ${QF_WORKSPACE}"
    echo "  ocr dir:        ${OCR_WORKSPACE}"
    local qf_count=0
    local ocr_count=0
    if [[ -d "$QF_WORKSPACE" ]]; then
        qf_count="$(find "$QF_WORKSPACE" -type f 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [[ -d "$OCR_WORKSPACE" ]]; then
        ocr_count="$(find "$OCR_WORKSPACE" -name '*-quickfile.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
    fi
    echo "  instruction files: ${qf_count}"
    echo "  pending records:   ${ocr_count} (quickfile JSON files in OCR workspace)"

    return 0
}

# Show help
cmd_help() {
    echo "QuickFile Integration Helper - AI DevOps Framework"
    echo ""
    echo "${HELP_LABEL_USAGE}"
    echo "  quickfile-helper.sh <command> [options]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  record-purchase <json>   Record purchase invoice from extracted JSON"
    echo "  record-expense <json>    Record expense receipt (auto-categorises nominal code)"
    echo "  supplier-resolve <name>  Find or create a supplier by name"
    echo "  batch-record <dir>       Batch record all *-quickfile.json files"
    echo "  preview <json>           Dry run - show what would be recorded"
    echo "  status                   Check QuickFile MCP and credential status"
    echo "  help                     Show this help"
    echo ""
    echo "${HELP_LABEL_OPTIONS}"
    echo "  --dry-run                Preview without recording"
    echo "  --nominal <code>         Override nominal code (default: auto-categorise)"
    echo "  --supplier-id <id>       Skip supplier lookup, use this ID"
    echo "  --auto-supplier          Auto-create supplier if not found"
    echo "  --currency <code>        Override currency (default: GBP)"
    echo ""
    echo "Workflow:"
    echo "  1. Extract:  ocr-receipt-helper.sh extract invoice.pdf"
    echo "  2. Prepare:  ocr-receipt-helper.sh quickfile invoice.pdf"
    echo "  3. Preview:  quickfile-helper.sh preview invoice-quickfile.json"
    echo "  4. Record:   quickfile-helper.sh record-purchase invoice-quickfile.json"
    echo "  5. Execute:  Run the MCP tool calls in your AI assistant session"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  quickfile-helper.sh record-purchase ~/receipts/invoice-quickfile.json"
    echo "  quickfile-helper.sh record-expense ~/receipts/receipt-quickfile.json --auto-supplier"
    echo "  quickfile-helper.sh supplier-resolve 'Amazon UK'"
    echo "  quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/"
    echo "  quickfile-helper.sh preview invoice-quickfile.json --nominal 7502"
    echo "  quickfile-helper.sh status"
    echo ""
    echo "Related:"
    echo "  ocr-receipt-helper.sh              - OCR extraction pipeline"
    echo "  services/accounting/quickfile.md    - QuickFile MCP subagent"
    echo "  tools/document/extraction-schemas.md - Extraction schema contracts"
    return 0
}

# Parse command-line arguments
parse_args() {
    local command="${1:-help}"
    shift || true

    # Parse named options
    local file=""
    local dry_run="false"
    local nominal_override=""
    local supplier_id=""
    local auto_supplier="false"
    local currency_override=""

    # First positional arg after command is the file/dir/name
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        file="$1"
        shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run="true"
                shift
                ;;
            --nominal)
                nominal_override="${2:-}"
                shift 2 || { print_error "Missing value for --nominal"; return 1; }
                ;;
            --supplier-id)
                supplier_id="${2:-}"
                shift 2 || { print_error "Missing value for --supplier-id"; return 1; }
                ;;
            --auto-supplier)
                auto_supplier="true"
                shift
                ;;
            --currency)
                currency_override="${2:-}"
                shift 2 || { print_error "Missing value for --currency"; return 1; }
                ;;
            *)
                print_warning "Unknown option: $1"
                shift
                ;;
        esac
    done

    case "$command" in
        record-purchase|rp)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_record_purchase "$file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override"
            ;;
        record-expense|re)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_record_expense "$file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override"
            ;;
        supplier-resolve|sr)
            if [[ -z "$file" ]]; then
                print_error "Supplier name is required"
                return 1
            fi
            cmd_supplier_resolve "$file" "$auto_supplier"
            ;;
        batch-record|br)
            if [[ -z "$file" ]]; then
                print_error "Input directory is required"
                return 1
            fi
            cmd_batch_record "$file" "$dry_run" "$nominal_override" "$auto_supplier" "$currency_override"
            ;;
        preview)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            cmd_preview "$file" "$nominal_override" "$currency_override"
            ;;
        status)
            cmd_status
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
