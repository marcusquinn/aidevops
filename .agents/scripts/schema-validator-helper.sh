#!/usr/bin/env bash
# shellcheck disable=SC2034

# Schema Validator Helper Script
# Validates structured data (JSON-LD, Microdata, RDFa) against Schema.org
# Uses @adobe/structured-data-validator and @marbec/web-auto-extractor
#
# Usage: schema-validator-helper.sh [command] [target]
# Commands:
#   validate <url|file>       Validate structured data from URL or HTML file
#   validate-json <file>      Validate raw JSON-LD file
#   status                    Check installation status
#   install                   Install/update dependencies
#   help                      Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Constants
readonly TOOL_DIR="$HOME/.aidevops/tools/schema-validator"
readonly JS_SCRIPT="$TOOL_DIR/validate.mjs"
readonly SCHEMA_CACHE="$TOOL_DIR/schemaorg-all-https.jsonld"
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [target]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[FAIL]${NC} $msg" >&2
    return 0
}

# Check if a command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
    return $?
}

# Install npm dependencies to tool directory
install_deps() {
    if ! command_exists npm; then
        print_error "npm is required but not found. Install Node.js 18+ first."
        return 1
    fi
    print_info "Installing schema-validator dependencies in $TOOL_DIR..."
    mkdir -p "$TOOL_DIR"

    if [[ ! -f "$TOOL_DIR/package.json" ]]; then
        (cd "$TOOL_DIR" && npm init -y > /dev/null 2>&1) || {
            print_error "Failed to initialize package.json"
            return 1
        }
    fi

    # Ensure type: module for ESM imports
    if ! grep -q '"type": "module"' "$TOOL_DIR/package.json" 2>/dev/null; then
        if command_exists jq; then
            local tmp
            tmp=$(mktemp)
            jq '. + {"type": "module"}' "$TOOL_DIR/package.json" > "$tmp" && mv "$tmp" "$TOOL_DIR/package.json"
        else
            # Fallback: use sed to inject "type": "module" after the opening brace
            local tmp
            tmp=$(mktemp)
            sed 's/^{$/{\'$'\n''  "type": "module",/' "$TOOL_DIR/package.json" > "$tmp" && mv "$tmp" "$TOOL_DIR/package.json"
            print_info "Added \"type\": \"module\" to package.json via sed (jq not available)"
        fi
    fi

    # Install packages if missing
    if [[ ! -d "$TOOL_DIR/node_modules/@adobe/structured-data-validator" ]]; then
        print_info "Installing @adobe/structured-data-validator, @marbec/web-auto-extractor, node-fetch..."
        (cd "$TOOL_DIR" && npm install --ignore-scripts @adobe/structured-data-validator @marbec/web-auto-extractor node-fetch --silent) || {
            print_error "Failed to install npm dependencies"
            return 1
        }
        print_success "Dependencies installed"
    else
        print_success "Dependencies already installed"
    fi

    return 0
}

# Create the validation JS script
create_js_script() {
    mkdir -p "$TOOL_DIR"
    cat > "$JS_SCRIPT" << 'JSEOF'
import Validator from '@adobe/structured-data-validator';
import WebAutoExtractor from '@marbec/web-auto-extractor';
import fs from 'fs';
import path from 'path';

// Use global fetch (Node 18+) or fall back to node-fetch
let fetchFn = global.fetch;
if (!fetchFn) {
    try {
        const nodeFetch = await import('node-fetch');
        fetchFn = nodeFetch.default;
    } catch {
        console.error("Error: global fetch not available and node-fetch not installed. Requires Node.js 18+.");
        process.exit(1);
    }
}

async function getSchema() {
    const schemaPath = path.join(process.cwd(), 'schemaorg-all-https.jsonld');

    // Cache schema for 24 hours
    if (fs.existsSync(schemaPath)) {
        const stats = fs.statSync(schemaPath);
        const ageMs = Date.now() - new Date(stats.mtime).getTime();
        if (ageMs < 24 * 60 * 60 * 1000) {
            return JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
        }
    }

    console.error("Fetching latest Schema.org definition...");
    try {
        const response = await fetchFn('https://schema.org/version/latest/schemaorg-all-https.jsonld');
        if (!response.ok) throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        const json = await response.json();
        fs.writeFileSync(schemaPath, JSON.stringify(json));
        return json;
    } catch (error) {
        console.error("Error fetching schema:", error.message);
        if (fs.existsSync(schemaPath)) {
            console.error("Falling back to cached schema.");
            return JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
        }
        throw error;
    }
}

async function validate(input, isJson) {
    let html = input;

    // If input is a file path, read it
    if (fs.existsSync(input)) {
        html = fs.readFileSync(input, 'utf8');
    } else if (input.startsWith('http')) {
        console.error(`Fetching URL: ${input}`);
        const res = await fetchFn(input);
        if (!res.ok) throw new Error(`Failed to fetch URL: HTTP ${res.status} ${res.statusText}`);
        html = await res.text();
    } else {
        console.error(`Error: "${input}" is not a valid URL (must start with http) and does not exist as a file.`);
        process.exit(1);
    }

    let extractedData;
    if (isJson) {
        try {
            const json = JSON.parse(html);
            extractedData = { jsonld: Array.isArray(json) ? json : [json], microdata: {}, rdfa: {} };
        } catch {
            console.error("Error: Invalid JSON input");
            process.exit(1);
        }
    } else {
        const extractor = new WebAutoExtractor({ addLocation: true, embedSource: ['rdfa', 'microdata'] });
        extractedData = extractor.parse(html);
    }

    const schema = await getSchema();
    const validator = new Validator(schema);

    // Show what was extracted
    const jsonldCount = extractedData.jsonld ? (Array.isArray(extractedData.jsonld) ? extractedData.jsonld.length : 1) : 0;
    const microdataCount = extractedData.microdata ? Object.keys(extractedData.microdata).length : 0;
    const rdfaCount = extractedData.rdfa ? Object.keys(extractedData.rdfa).length : 0;
    console.error(`Extracted: ${jsonldCount} JSON-LD, ${microdataCount} Microdata, ${rdfaCount} RDFa items`);

    const results = await validator.validate(extractedData);

    if (results && results.length > 0) {
        console.log(JSON.stringify(results, null, 2));
        const errors = results.filter(r => r.severity === 'ERROR');
        const warnings = results.filter(r => r.severity === 'WARNING');
        console.error(`\nResults: ${errors.length} errors, ${warnings.length} warnings, ${results.length - errors.length - warnings.length} info`);
        if (errors.length > 0) {
            process.exit(1);
        }
    } else {
        console.log(JSON.stringify({ status: "pass", message: "Validation passed. No issues found." }, null, 2));
    }
}

const args = process.argv.slice(2);
const command = args[0];
const target = args[1];

if (!command || !target) {
    console.error("Usage: node validate.mjs <validate|validate-json> <file|url>");
    process.exit(1);
}

if (command === 'validate') {
    validate(target, false).catch(e => { console.error("Error:", e.message); process.exit(1); });
} else if (command === 'validate-json') {
    validate(target, true).catch(e => { console.error("Error:", e.message); process.exit(1); });
} else {
    console.error(`Unknown command: ${command}`);
    process.exit(1);
}
JSEOF
    return 0
}

# Check installation status
cmd_status() {
    print_info "Schema Validator Status"
    echo ""

    if [[ -d "$TOOL_DIR/node_modules/@adobe/structured-data-validator" ]]; then
        print_success "Dependencies installed at $TOOL_DIR"
    else
        print_warning "Dependencies not installed"
        print_info "Run: $0 install"
    fi

    if command_exists node; then
        local node_version
        node_version=$(node --version 2>/dev/null || echo "unknown")
        print_success "Node.js: $node_version"
    else
        print_error "Node.js not found"
    fi

    if [[ -f "$SCHEMA_CACHE" ]]; then
        local cache_age
        cache_age=$(( ($(date +%s) - $(stat -f %m "$SCHEMA_CACHE" 2>/dev/null || stat -c %Y "$SCHEMA_CACHE" 2>/dev/null || echo 0)) / 3600 ))
        print_success "Schema cache: ${cache_age}h old (24h TTL)"
    else
        print_info "Schema cache: not yet fetched (will download on first run)"
    fi

    return 0
}

# Run validation
cmd_validate() {
    local target="$1"
    local is_json="${2:-false}"

    if [[ -z "$target" ]]; then
        print_error "Target URL or file path required"
        echo "$HELP_USAGE_INFO"
        return 1
    fi

    # Ensure dependencies are installed
    if [[ ! -d "$TOOL_DIR/node_modules/@adobe/structured-data-validator" ]]; then
        install_deps || return 1
    fi

    # Create/update the JS script
    create_js_script || {
        print_error "Failed to create validation script"
        return 1
    }

    local node_cmd="validate"
    if [[ "$is_json" == "true" ]]; then
        node_cmd="validate-json"
    fi

    print_info "Validating: $target"
    # Capture exit code explicitly — node returns non-zero for validation
    # errors, which is expected. Without || guard, set -e would kill the
    # script before we can report results to the user.
    local exit_code=0
    (cd "$TOOL_DIR" && node "$JS_SCRIPT" "$node_cmd" "$target") || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        print_success "Validation complete"
    else
        print_error "Validation found errors (exit code: $exit_code)"
    fi

    return $exit_code
}

# Show help
show_help() {
    echo "Schema Validator Helper Script"
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Validates structured data (JSON-LD, Microdata, RDFa) against Schema.org"
    echo "specifications and Google Rich Results requirements."
    echo ""
    echo "Commands:"
    echo "  validate <url|file>       Validate structured data from URL or HTML file"
    echo "  validate-json <file>      Validate raw JSON-LD file"
    echo "  status                    Check installation status"
    echo "  install                   Install/update dependencies"
    echo "  help                      $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 validate https://example.com"
    echo "  $0 validate ./page.html"
    echo "  $0 validate-json ./schema.json"
    echo "  $0 status"
    echo ""
    echo "Dependencies:"
    echo "  Required: Node.js 18+ (for native fetch)"
    echo "  Auto-installed: @adobe/structured-data-validator"
    echo "  Auto-installed: @marbec/web-auto-extractor"
    echo "  Auto-installed: node-fetch (fallback for Node <18)"
    echo ""
    echo "Install directory: $TOOL_DIR"

    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local target="${2:-}"

    case "$command" in
        "validate")
            cmd_validate "$target" "false"
            ;;
        "validate-json")
            cmd_validate "$target" "true"
            ;;
        "status")
            cmd_status
            ;;
        "install")
            install_deps
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            # If first arg looks like a URL or file, treat as validate
            if [[ "$command" == http* || -f "$command" ]]; then
                cmd_validate "$command" "false"
            else
                print_error "Unknown command: $command"
                echo "$HELP_USAGE_INFO"
                return 1
            fi
            ;;
    esac
}

main "$@"
