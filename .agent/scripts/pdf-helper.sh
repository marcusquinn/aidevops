#!/usr/bin/env bash
# pdf-helper.sh - PDF operations helper using LibPDF
# Usage: pdf-helper.sh [command] [options]
#
# Commands:
#   info <file>              - Show PDF information (pages, form fields, etc.)
#   fields <file>            - List form field names and types
#   fill <file> <json>       - Fill form fields from JSON
#   merge <output> <files..> - Merge multiple PDFs
#   extract <file> <pages>   - Extract pages (e.g., "1-3,5,7-9")
#   text <file>              - Extract text content
#   install                  - Install @libpdf/core
#   help                     - Show this help

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if bun or node is available
get_runtime() {
    if command -v bun &>/dev/null; then
        echo "bun"
    elif command -v node &>/dev/null; then
        echo "node"
    else
        echo ""
    fi
}

# Check if @libpdf/core is installed
check_libpdf() {
    local runtime
    runtime=$(get_runtime)
    
    if [[ -z "$runtime" ]]; then
        echo -e "${RED}Error:${NC} Neither bun nor node found. Install one first."
        return 1
    fi
    
    # Check in current project or global
    if [[ -f "package.json" ]] && grep -q "@libpdf/core" package.json 2>/dev/null; then
        return 0
    fi
    
    # Try to import (use ESM import for consistency)
    if [[ "$runtime" == "bun" ]] && bun -e "import('@libpdf/core')" &>/dev/null; then
        return 0
    elif [[ "$runtime" == "node" ]] && node --input-type=module -e "import('@libpdf/core')" &>/dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}Warning:${NC} @libpdf/core not found."
    echo -e "Install with: ${BLUE}npm install @libpdf/core${NC} or ${BLUE}bun add @libpdf/core${NC}"
    return 1
}

# Run TypeScript/JavaScript code
run_script() {
    local script="$1"
    local runtime
    runtime=$(get_runtime)
    
    if [[ "$runtime" == "bun" ]]; then
        bun -e "$script"
    else
        node --input-type=module -e "$script"
    fi
}

# Show PDF info
cmd_info() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error:${NC} File not found: $file"
        return 1
    fi
    
    check_libpdf || return 1
    
    PDF_FILE="$file" run_script '
import { PDF } from "@libpdf/core";
import { readFileSync } from "fs";

const file = process.env.PDF_FILE;
const bytes = readFileSync(file);
const pdf = await PDF.load(bytes);
const pages = await pdf.getPages();
const form = await pdf.getForm();
const fields = form.getFieldNames();

console.log("File:", file);
console.log("Pages:", pages.length);
console.log("Form fields:", fields.length);

if (pages.length > 0) {
    const { width, height } = pages[0].getSize();
    console.log("Page size:", Math.round(width), "x", Math.round(height), "points");
}
'
}

# List form fields
cmd_fields() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error:${NC} File not found: $file"
        return 1
    fi
    
    check_libpdf || return 1
    
    PDF_FILE="$file" run_script '
import { PDF } from "@libpdf/core";
import { readFileSync } from "fs";

const file = process.env.PDF_FILE;
const bytes = readFileSync(file);
const pdf = await PDF.load(bytes);
const form = await pdf.getForm();
const fields = form.getFields();

if (fields.length === 0) {
    console.log("No form fields found.");
} else {
    console.log("Form fields:");
    for (const field of fields) {
        const name = field.getName();
        const type = field.constructor.name.replace("PDF", "").replace("Field", "");
        console.log("  -", name, "(" + type + ")");
    }
}
'
}

# Fill form fields
cmd_fill() {
    local file="$1"
    local json="$2"
    local output="${3:-${file%.pdf}-filled.pdf}"
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error:${NC} File not found: $file"
        return 1
    fi
    
    check_libpdf || return 1
    
    PDF_FILE="$file" PDF_JSON="$json" PDF_OUTPUT="$output" run_script '
import { PDF } from "@libpdf/core";
import { readFileSync, writeFileSync } from "fs";

const file = process.env.PDF_FILE;
const jsonData = process.env.PDF_JSON;
const outputFile = process.env.PDF_OUTPUT;

const bytes = readFileSync(file);
const pdf = await PDF.load(bytes);
const form = await pdf.getForm();

const data = JSON.parse(jsonData);
form.fill(data);

const output = await pdf.save();
writeFileSync(outputFile, output);
console.log("Filled PDF saved to:", outputFile);
'
}

# Merge PDFs
cmd_merge() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error:${NC} 'jq' is not installed. Please install it to use the merge command."
        return 1
    fi
    
    local output="$1"
    shift
    local files=("$@")
    
    if [[ ${#files[@]} -lt 2 ]]; then
        echo -e "${RED}Error:${NC} Need at least 2 files to merge"
        return 1
    fi
    
    check_libpdf || return 1
    
    local files_json
    files_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)
    
    PDF_FILES="$files_json" PDF_OUTPUT="$output" run_script '
import { PDF } from "@libpdf/core";
import { readFileSync, writeFileSync } from "fs";

const files = JSON.parse(process.env.PDF_FILES);
const outputFile = process.env.PDF_OUTPUT;
const pdfs = files.map(f => readFileSync(f));

const merged = await PDF.merge(pdfs);
const output = await merged.save();
writeFileSync(outputFile, output);
console.log("Merged", files.length, "PDFs into:", outputFile);
'
}

# Extract text
cmd_text() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error:${NC} File not found: $file"
        return 1
    fi
    
    check_libpdf || return 1
    
    PDF_FILE="$file" run_script '
import { PDF } from "@libpdf/core";
import { readFileSync } from "fs";

const file = process.env.PDF_FILE;
const bytes = readFileSync(file);
const pdf = await PDF.load(bytes);
const pages = await pdf.getPages();

for (let i = 0; i < pages.length; i++) {
    const text = await pages[i].getTextContent();
    if (pages.length > 1) {
        console.log("--- Page", i + 1, "---");
    }
    console.log(text);
}
'
}

# Install @libpdf/core
cmd_install() {
    local runtime
    runtime=$(get_runtime)
    
    if [[ -z "$runtime" ]]; then
        echo -e "${RED}Error:${NC} Neither bun nor node found. Install one first."
        return 1
    fi
    
    echo -e "${BLUE}Installing @libpdf/core...${NC}"
    
    if [[ "$runtime" == "bun" ]]; then
        bun add @libpdf/core
    else
        npm install @libpdf/core
    fi
    
    echo -e "${GREEN}Done!${NC}"
}

# Show help
cmd_help() {
    cat << 'EOF'
pdf-helper.sh - PDF operations helper using LibPDF

Usage: pdf-helper.sh [command] [options]

Commands:
  info <file>              - Show PDF information (pages, form fields, etc.)
  fields <file>            - List form field names and types
  fill <file> <json> [out] - Fill form fields from JSON
  merge <output> <files..> - Merge multiple PDFs
  text <file>              - Extract text content
  install                  - Install @libpdf/core
  help                     - Show this help

Examples:
  # Show PDF info
  pdf-helper.sh info document.pdf

  # List form fields
  pdf-helper.sh fields form.pdf

  # Fill form fields
  pdf-helper.sh fill form.pdf '{"name":"John","email":"john@example.com"}'

  # Merge PDFs
  pdf-helper.sh merge combined.pdf doc1.pdf doc2.pdf doc3.pdf

  # Extract text
  pdf-helper.sh text document.pdf

Requirements:
  - Node.js 20+ or Bun
  - @libpdf/core (install with: npm install @libpdf/core)

For more advanced operations (signing, encryption, etc.), use LibPDF directly
in your TypeScript/JavaScript code. See: https://libpdf.dev
EOF
}

# Main
main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        info)
            [[ $# -lt 1 ]] && { echo -e "${RED}Error:${NC} Missing file argument"; return 1; }
            cmd_info "$1"
            ;;
        fields)
            [[ $# -lt 1 ]] && { echo -e "${RED}Error:${NC} Missing file argument"; return 1; }
            cmd_fields "$1"
            ;;
        fill)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error:${NC} Missing file or json argument"; return 1; }
            cmd_fill "$@"
            ;;
        merge)
            [[ $# -lt 3 ]] && { echo -e "${RED}Error:${NC} Need output file and at least 2 input files"; return 1; }
            cmd_merge "$@"
            ;;
        text)
            [[ $# -lt 1 ]] && { echo -e "${RED}Error:${NC} Missing file argument"; return 1; }
            cmd_text "$1"
            ;;
        install)
            cmd_install
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo -e "${RED}Error:${NC} Unknown command: $cmd"
            echo "Run 'pdf-helper.sh help' for usage"
            return 1
            ;;
    esac
}

main "$@"
