#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# QuickFile Purchase Helper for AI DevOps Framework
# Bridge between OCR extraction pipeline and QuickFile purchase/expense recording.
# Reads structured JSON from document-extraction-helper.sh and prepares
# QuickFile purchase creation payloads.
#
# Usage: quickfile-purchase-helper.sh [command] [options]
#
# Commands:
#   prepare <json-file>       Validate extraction JSON and prepare QuickFile payload
#   batch <dir>               Prepare payloads for all extraction JSONs in a directory
#   lookup-supplier <name>    Search QuickFile for a matching supplier
#   lookup-nominal <query>    Search chart of accounts for expense category
#   validate <json-file>      Validate extraction JSON without creating payload
#   status                    Check QuickFile MCP connectivity
#   help                      Show this help
#
# The 'prepare' command outputs a JSON payload suitable for quickfile_purchase_create.
# Actual QuickFile API calls are made by the AI agent using MCP tools, not by this script.
# This separation keeps credentials out of shell scripts and lets the agent handle
# supplier matching, nominal code selection, and user confirmation.
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/work/quickfile-purchases"
readonly EXTRACTION_DIR="${HOME}/.aidevops/.agent-workspace/work/document-extraction"

# Ensure workspace exists
ensure_workspace() {
    mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true
    return 0
}

# Check if jq is available
check_jq() {
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        print_info "Install: brew install jq"
        return 1
    fi
    return 0
}

# Validate extraction JSON structure (invoice schema)
validate_invoice_json() {
    local json_file="$1"

    validate_file_exists "$json_file" "Extraction JSON" || return 1
    check_jq || return 1

    local errors=0

    # Check required fields
    local vendor_name
    vendor_name="$(jq -r '.vendor_name // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$vendor_name" ]]; then
        print_warning "Missing vendor_name"
        errors=$((errors + 1))
    fi

    local total
    total="$(jq -r '.total // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$total" ]]; then
        print_warning "Missing total amount"
        errors=$((errors + 1))
    fi

    local invoice_date
    invoice_date="$(jq -r '.invoice_date // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$invoice_date" ]]; then
        print_warning "Missing invoice_date"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        print_warning "Validation found ${errors} issue(s) — payload may need manual review"
        return 2
    fi

    print_success "Extraction JSON is valid"
    return 0
}

# Validate extraction JSON structure (receipt schema)
validate_receipt_json() {
    local json_file="$1"

    validate_file_exists "$json_file" "Extraction JSON" || return 1
    check_jq || return 1

    local errors=0

    local merchant
    merchant="$(jq -r '.merchant // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$merchant" ]]; then
        print_warning "Missing merchant"
        errors=$((errors + 1))
    fi

    local total
    total="$(jq -r '.total // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$total" ]]; then
        print_warning "Missing total amount"
        errors=$((errors + 1))
    fi

    local date_val
    date_val="$(jq -r '.date // empty' "$json_file" 2>/dev/null)"
    if [[ -z "$date_val" ]]; then
        print_warning "Missing date"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        print_warning "Validation found ${errors} issue(s) — payload may need manual review"
        return 2
    fi

    print_success "Extraction JSON is valid"
    return 0
}

# Detect schema type from JSON content
detect_schema() {
    local json_file="$1"

    check_jq || return 1

    # Invoice schema has vendor_name, invoice_number
    if jq -e '.vendor_name' "$json_file" &>/dev/null; then
        echo "invoice"
        return 0
    fi

    # Receipt schema has merchant
    if jq -e '.merchant' "$json_file" &>/dev/null; then
        echo "receipt"
        return 0
    fi

    echo "unknown"
    return 1
}

# Normalise date to YYYY-MM-DD format
normalise_date() {
    local raw_date="$1"

    # Already in YYYY-MM-DD format
    if [[ "$raw_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$raw_date"
        return 0
    fi

    # DD/MM/YYYY (UK format)
    if [[ "$raw_date" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})$ ]]; then
        echo "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"
        return 0
    fi

    # DD-MM-YYYY
    if [[ "$raw_date" =~ ^([0-9]{2})-([0-9]{2})-([0-9]{4})$ ]]; then
        echo "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"
        return 0
    fi

    # MM/DD/YYYY (US format — ambiguous, but try)
    if [[ "$raw_date" =~ ^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$ ]]; then
        printf '%s-%02d-%02d\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    # Try macOS date parsing as fallback
    if date -j -f "%B %d, %Y" "$raw_date" "+%Y-%m-%d" 2>/dev/null; then
        return 0
    fi

    # Return as-is if we can't parse
    echo "$raw_date"
    return 0
}

# Prepare QuickFile purchase payload from invoice extraction JSON
prepare_invoice_payload() {
    local json_file="$1"
    local output_file="$2"

    check_jq || return 1

    local vendor_name invoice_number invoice_date due_date subtotal tax total currency
    vendor_name="$(jq -r '.vendor_name // ""' "$json_file")"
    invoice_number="$(jq -r '.invoice_number // ""' "$json_file")"
    invoice_date="$(jq -r '.invoice_date // ""' "$json_file")"
    due_date="$(jq -r '.due_date // ""' "$json_file")"
    subtotal="$(jq -r '.subtotal // 0' "$json_file")"
    tax="$(jq -r '.tax // 0' "$json_file")"
    total="$(jq -r '.total // 0' "$json_file")"
    currency="$(jq -r '.currency // "GBP"' "$json_file")"

    # Normalise dates
    invoice_date="$(normalise_date "$invoice_date")"
    if [[ -n "$due_date" ]]; then
        due_date="$(normalise_date "$due_date")"
    fi

    # Build line items from extraction
    local line_items
    line_items="$(jq -c '[.line_items[]? | {
        "description": (.description // ""),
        "quantity": (.quantity // 1),
        "unitCost": (.unit_price // .amount // 0),
        "nominalCode": "5000",
        "taxCode": (if (.amount // 0) > 0 then "T1" else "T0" end)
    }]' "$json_file" 2>/dev/null)" || line_items="[]"

    # If no line items, create a single line from totals
    if [[ "$line_items" == "[]" ]] || [[ "$line_items" == "null" ]]; then
        line_items="$(jq -n --arg desc "Purchase from ${vendor_name}" \
            --argjson net "$subtotal" \
            --argjson tax_amt "$tax" \
            '[{
                "description": $desc,
                "quantity": 1,
                "unitCost": (if $net > 0 then $net else ($net + $tax_amt) end),
                "nominalCode": "5000",
                "taxCode": (if $tax_amt > 0 then "T1" else "T0" end)
            }]')"
    fi

    # Build the QuickFile purchase payload
    jq -n \
        --arg vendor "$vendor_name" \
        --arg inv_num "$invoice_number" \
        --arg inv_date "$invoice_date" \
        --arg due "$due_date" \
        --arg curr "$currency" \
        --argjson items "$line_items" \
        --arg source "$json_file" \
        '{
            "quickfile_action": "purchase_create",
            "supplier_name": $vendor,
            "invoice_reference": $inv_num,
            "invoice_date": $inv_date,
            "due_date": $due,
            "currency": $curr,
            "line_items": $items,
            "notes": ("Auto-extracted from: " + $source),
            "requires_review": true,
            "agent_instructions": {
                "step_1": ("Search for supplier: quickfile_supplier_search with name=" + $vendor),
                "step_2": "If no supplier found, create one: quickfile_supplier_create",
                "step_3": "Review nominal codes — default 5000 (Cost of Sales). Common alternatives: 7501 (Postage), 7502 (Office Stationery), 7504 (IT Software & Consumables), 7901 (Bank Charges)",
                "step_4": "Confirm line items and totals with user before creating",
                "step_5": "Create purchase: quickfile_purchase_create with the payload above"
            }
        }' > "$output_file"

    return 0
}

# Prepare QuickFile purchase payload from receipt extraction JSON
prepare_receipt_payload() {
    local json_file="$1"
    local output_file="$2"

    check_jq || return 1

    local merchant date_val total payment_method
    merchant="$(jq -r '.merchant // ""' "$json_file")"
    date_val="$(jq -r '.date // ""' "$json_file")"
    total="$(jq -r '.total // 0' "$json_file")"
    payment_method="$(jq -r '.payment_method // ""' "$json_file")"

    # Normalise date
    date_val="$(normalise_date "$date_val")"

    # Build line items from receipt items
    local line_items
    line_items="$(jq -c '[.items[]? | {
        "description": (.name // ""),
        "quantity": 1,
        "unitCost": (.price // 0),
        "nominalCode": "5000",
        "taxCode": "T1"
    }]' "$json_file" 2>/dev/null)" || line_items="[]"

    # If no items, create single line from total
    if [[ "$line_items" == "[]" ]] || [[ "$line_items" == "null" ]]; then
        line_items="$(jq -n --arg desc "Purchase from ${merchant}" \
            --argjson amount "$total" \
            '[{
                "description": $desc,
                "quantity": 1,
                "unitCost": $amount,
                "nominalCode": "5000",
                "taxCode": "T1"
            }]')"
    fi

    # Build the QuickFile purchase payload
    jq -n \
        --arg vendor "$merchant" \
        --arg inv_date "$date_val" \
        --arg payment "$payment_method" \
        --argjson items "$line_items" \
        --arg source "$json_file" \
        '{
            "quickfile_action": "purchase_create",
            "supplier_name": $vendor,
            "invoice_reference": "",
            "invoice_date": $inv_date,
            "due_date": "",
            "currency": "GBP",
            "line_items": $items,
            "payment_method": $payment,
            "notes": ("Auto-extracted from receipt: " + $source),
            "requires_review": true,
            "agent_instructions": {
                "step_1": ("Search for supplier: quickfile_supplier_search with name=" + $vendor),
                "step_2": "If no supplier found, create one: quickfile_supplier_create",
                "step_3": "Review nominal codes — default 5000 (Cost of Sales). Common alternatives: 7501 (Postage), 7502 (Office Stationery), 7504 (IT Software & Consumables), 7901 (Bank Charges)",
                "step_4": "If payment_method is known, consider recording as paid immediately",
                "step_5": "Confirm with user before creating: quickfile_purchase_create"
            }
        }' > "$output_file"

    return 0
}

# Main prepare command
do_prepare() {
    local json_file="$1"

    validate_file_exists "$json_file" "Extraction JSON" || return 1
    check_jq || return 1
    ensure_workspace

    # Detect schema type
    local schema
    schema="$(detect_schema "$json_file")" || {
        print_error "Cannot detect schema type from JSON. Expected invoice or receipt format."
        print_info "Invoice schema: vendor_name, invoice_number, total, line_items"
        print_info "Receipt schema: merchant, date, total, items"
        return 1
    }

    print_info "Detected schema: ${schema}"

    # Validate
    local validation_result=0
    case "$schema" in
        invoice)
            validate_invoice_json "$json_file" || validation_result=$?
            ;;
        receipt)
            validate_receipt_json "$json_file" || validation_result=$?
            ;;
    esac

    # validation_result 2 = warnings (proceed), 1 = fatal error
    if [[ "$validation_result" -eq 1 ]]; then
        return 1
    fi

    # Generate output filename
    local basename
    basename="$(basename "$json_file" | sed 's/\.[^.]*$//')"
    local output_file="${WORKSPACE_DIR}/${basename}-qf-payload.json"

    # Prepare payload
    case "$schema" in
        invoice)
            prepare_invoice_payload "$json_file" "$output_file" || return 1
            ;;
        receipt)
            prepare_receipt_payload "$json_file" "$output_file" || return 1
            ;;
    esac

    print_success "QuickFile payload prepared: ${output_file}"
    echo ""
    print_info "Payload summary:"
    jq '{
        supplier: .supplier_name,
        date: .invoice_date,
        reference: .invoice_reference,
        items: (.line_items | length),
        review_required: .requires_review
    }' "$output_file"
    echo ""
    print_info "Next steps (for AI agent):"
    jq -r '.agent_instructions | to_entries[] | "  \(.key): \(.value)"' "$output_file"

    return 0
}

# Batch prepare payloads
do_batch() {
    local input_dir="$1"

    if [[ ! -d "$input_dir" ]]; then
        print_error "Directory not found: ${input_dir}"
        return 1
    fi

    check_jq || return 1
    ensure_workspace

    local count=0
    local failed=0
    local skipped=0

    print_info "Batch preparing QuickFile payloads from ${input_dir}..."

    for json_file in "${input_dir}"/*-extracted.json; do
        [[ -f "$json_file" ]] || continue

        echo ""
        print_info "Processing: ${json_file}"

        if do_prepare "$json_file"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done

    # Also check for non-suffixed JSON files
    for json_file in "${input_dir}"/*.json; do
        [[ -f "$json_file" ]] || continue
        # Skip already-processed payload files
        if [[ "$json_file" == *"-qf-payload.json" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        # Skip if we already processed the -extracted version
        if [[ "$json_file" == *"-extracted.json" ]]; then
            continue
        fi

        echo ""
        print_info "Processing: ${json_file}"

        if do_prepare "$json_file"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    print_success "Batch complete: ${count} prepared, ${failed} failed, ${skipped} skipped"
    print_info "Output directory: ${WORKSPACE_DIR}"
    return 0
}

# Validate extraction JSON
do_validate() {
    local json_file="$1"

    validate_file_exists "$json_file" "Extraction JSON" || return 1
    check_jq || return 1

    # Check valid JSON
    if ! jq empty "$json_file" 2>/dev/null; then
        print_error "Invalid JSON: ${json_file}"
        return 1
    fi

    # Detect and validate schema
    local schema
    schema="$(detect_schema "$json_file")" || {
        print_error "Cannot detect schema type"
        return 1
    }

    print_info "Schema: ${schema}"

    case "$schema" in
        invoice)
            validate_invoice_json "$json_file"
            ;;
        receipt)
            validate_receipt_json "$json_file"
            ;;
    esac

    # Show summary
    echo ""
    print_info "Content summary:"
    case "$schema" in
        invoice)
            jq '{
                vendor: .vendor_name,
                invoice_number: .invoice_number,
                date: .invoice_date,
                due_date: .due_date,
                subtotal: .subtotal,
                tax: .tax,
                total: .total,
                currency: .currency,
                line_items: (.line_items | length)
            }' "$json_file"
            ;;
        receipt)
            jq '{
                merchant: .merchant,
                date: .date,
                total: .total,
                payment_method: .payment_method,
                items: (.items | length)
            }' "$json_file"
            ;;
    esac

    return 0
}

# Check QuickFile MCP status
do_status() {
    echo "QuickFile Purchase Integration - Status"
    echo "========================================"
    echo ""

    # Check jq
    if command -v jq &>/dev/null; then
        echo "jq:               installed"
    else
        echo "jq:               NOT installed (required)"
    fi

    # Check extraction helper
    if [[ -x "${SCRIPT_DIR}/document-extraction-helper.sh" ]]; then
        echo "extraction helper: available"
    else
        echo "extraction helper: not found"
    fi

    # Check QuickFile credentials
    local creds_file="${HOME}/.config/.quickfile-mcp/credentials.json"
    if [[ -f "$creds_file" ]]; then
        echo "QF credentials:   configured"
    else
        echo "QF credentials:   NOT configured"
        echo "                  Create: ${creds_file}"
    fi

    # Check QuickFile MCP server
    local mcp_dir="${HOME}/Git/quickfile-mcp"
    if [[ -d "$mcp_dir" ]] && [[ -f "${mcp_dir}/dist/index.js" ]]; then
        echo "QF MCP server:    built (${mcp_dir})"
    elif [[ -d "$mcp_dir" ]]; then
        echo "QF MCP server:    cloned but not built"
        echo "                  Run: cd ${mcp_dir} && npm run build"
    else
        echo "QF MCP server:    not installed"
        echo "                  Run: cd ~/Git && git clone https://github.com/marcusquinn/quickfile-mcp.git"
    fi

    # Check workspace
    echo ""
    echo "Workspace:"
    echo "  Extraction output: ${EXTRACTION_DIR}"
    echo "  Purchase payloads: ${WORKSPACE_DIR}"

    if [[ -d "$EXTRACTION_DIR" ]]; then
        local extraction_count
        extraction_count="$(find "$EXTRACTION_DIR" -name '*-extracted.json' 2>/dev/null | wc -l | tr -d ' ')"
        echo "  Pending extractions: ${extraction_count}"
    fi

    if [[ -d "$WORKSPACE_DIR" ]]; then
        local payload_count
        payload_count="$(find "$WORKSPACE_DIR" -name '*-qf-payload.json' 2>/dev/null | wc -l | tr -d ' ')"
        echo "  Prepared payloads: ${payload_count}"
    fi

    echo ""
    echo "Common Nominal Codes (UK):"
    echo "  5000  Cost of Sales"
    echo "  7501  Postage & Carriage"
    echo "  7502  Office Stationery"
    echo "  7504  IT Software & Consumables"
    echo "  7505  IT Hardware"
    echo "  7901  Bank Charges"
    echo "  7903  Subscriptions"
    echo "  7904  Accountancy Fees"

    return 0
}

# Show help
do_help() {
    echo "QuickFile Purchase Helper - AI DevOps Framework"
    echo ""
    echo "${HELP_LABEL_USAGE}"
    echo "  quickfile-purchase-helper.sh <command> [options]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  prepare <json-file>"
    echo "      Validate extraction JSON and prepare QuickFile purchase payload."
    echo "      Accepts output from document-extraction-helper.sh (invoice or receipt schema)."
    echo ""
    echo "  batch <dir>"
    echo "      Prepare payloads for all extraction JSONs in a directory."
    echo "      Looks for *-extracted.json files by default."
    echo ""
    echo "  validate <json-file>"
    echo "      Validate extraction JSON structure without creating a payload."
    echo ""
    echo "  status"
    echo "      Check QuickFile MCP connectivity and workspace status."
    echo ""
    echo "  help"
    echo "      Show this help."
    echo ""
    echo "Pipeline:"
    echo "  1. Extract:  document-extraction-helper.sh extract receipt.pdf --schema receipt"
    echo "  2. Prepare:  quickfile-purchase-helper.sh prepare receipt-extracted.json"
    echo "  3. Review:   AI agent reviews payload and confirms with user"
    echo "  4. Create:   AI agent calls quickfile_purchase_create via MCP"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  quickfile-purchase-helper.sh prepare invoice-extracted.json"
    echo "  quickfile-purchase-helper.sh batch ~/.aidevops/.agent-workspace/work/document-extraction/"
    echo "  quickfile-purchase-helper.sh validate receipt-extracted.json"
    echo "  quickfile-purchase-helper.sh status"
    echo ""
    echo "Nominal Codes (common UK):"
    echo "  5000  Cost of Sales          7501  Postage & Carriage"
    echo "  7502  Office Stationery      7504  IT Software & Consumables"
    echo "  7505  IT Hardware            7901  Bank Charges"
    echo "  7903  Subscriptions          7904  Accountancy Fees"
    return 0
}

# Parse command-line arguments
parse_args() {
    local command="${1:-help}"
    shift || true

    local file=""

    # First positional arg after command is the file/dir
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        file="$1"
        shift || true
    fi

    case "$command" in
        prepare)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_prepare "$file"
            ;;
        batch)
            if [[ -z "$file" ]]; then
                # Default to extraction workspace
                file="$EXTRACTION_DIR"
                print_info "Using default extraction directory: ${file}"
            fi
            do_batch "$file"
            ;;
        validate)
            if [[ -z "$file" ]]; then
                print_error "${ERROR_INPUT_FILE_REQUIRED}"
                return 1
            fi
            do_validate "$file"
            ;;
        status)
            do_status
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
