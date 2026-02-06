#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# TOON Format Helper for AI DevOps Framework
# Token-Oriented Object Notation (TOON) - Compact, human-readable, schema-aware JSON for LLM prompts
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >&2; return 0; }

# Determine package runner (bun x or npx)
get_pkg_runner() {
    if command -v bun &> /dev/null; then
        echo "bun x"
    elif command -v npx &> /dev/null; then
        echo "npx"
    else
        echo ""
    fi
    return 0
}

PKG_RUNNER=""

# Check if TOON CLI is available
check_toon() {
    PKG_RUNNER=$(get_pkg_runner)
    
    if [[ -z "$PKG_RUNNER" ]]; then
        print_error "bun or npx is required. Install Bun (recommended):"
        echo ""
        echo "Bun:     curl -fsSL https://bun.sh/install | bash"
        echo ""
        echo "Or Node.js:"
        echo "macOS:   brew install node"
        echo "Ubuntu:  sudo apt-get install nodejs npm"
        return 1
    fi
    
    # Test TOON CLI availability
    if ! $PKG_RUNNER @toon-format/cli --help &> /dev/null; then
        print_warning "TOON CLI not found, will install on first use"
    fi
    
    return 0
}

# Convert JSON to TOON format
json_to_toon() {
    local input_file="$1"
    local output_file="$2"
    local delimiter="${3:-,}"
    local show_stats="${4:-false}"
    
    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        return 1
    fi
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi
    
    local cmd_args=()
    # Handle tab delimiter properly
    if [[ "$delimiter" == "\\t" || "$delimiter" == "\t" ]]; then
        cmd_args+=("--delimiter" $'\t')
    else
        cmd_args+=("--delimiter" "$delimiter")
    fi
    
    if [[ "$show_stats" == "true" ]]; then
        cmd_args+=("--stats")
    fi
    
    if [[ -n "$output_file" ]]; then
        cmd_args+=("-o" "$output_file")
    fi
    
    print_info "Converting JSON to TOON format..."
    if $PKG_RUNNER @toon-format/cli "${cmd_args[@]}" "$input_file"; then
        if [[ -n "$output_file" ]]; then
            print_success "Converted to TOON: $output_file"
        else
            print_success "Conversion completed"
        fi
        return 0
    else
        print_error "Failed to convert JSON to TOON"
        return 1
    fi
    return 0
}

# Convert TOON to JSON format
toon_to_json() {
    local input_file="$1"
    local output_file="$2"
    local strict_mode="${3:-true}"
    
    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        return 1
    fi
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi
    
    local cmd_args=("--decode")
    
    if [[ "$strict_mode" == "false" ]]; then
        cmd_args+=("--no-strict")
    fi
    
    if [[ -n "$output_file" ]]; then
        cmd_args+=("-o" "$output_file")
    fi
    
    print_info "Converting TOON to JSON format..."
    if $PKG_RUNNER @toon-format/cli "${cmd_args[@]}" "$input_file"; then
        if [[ -n "$output_file" ]]; then
            print_success "Converted to JSON: $output_file"
        else
            print_success "Conversion completed"
        fi
        return 0
    else
        print_error "Failed to convert TOON to JSON"
        return 1
    fi
    return 0
}

# Convert from stdin
convert_stdin() {
    local format="$1"
    local delimiter="${2:-,}"
    local show_stats="${3:-false}"
    
    local cmd_args=()
    
    case "$format" in
        "encode"|"json-to-toon")
            cmd_args+=("--encode")
            # Handle tab delimiter properly
            if [[ "$delimiter" == "\\t" || "$delimiter" == "\t" ]]; then
                cmd_args+=("--delimiter" $'\t')
            else
                cmd_args+=("--delimiter" "$delimiter")
            fi
            if [[ "$show_stats" == "true" ]]; then
                cmd_args+=("--stats")
            fi
            ;;
        "decode"|"toon-to-json")
            cmd_args+=("--decode")
            ;;
        *)
            print_error "Invalid format: $format. Use 'encode' or 'decode'"
            return 1
            ;;
    esac
    
    print_info "Converting from stdin..."
    if $PKG_RUNNER @toon-format/cli "${cmd_args[@]}"; then
        print_success "Conversion completed"
        return 0
    else
        print_error "Failed to convert from stdin"
        return 1
    fi
    return 0
}

# Batch convert directory
batch_convert() {
    local source_dir="$1"
    local target_dir="$2"
    local format="$3"
    local delimiter="${4:-,}"
    
    if [[ -z "$source_dir" || -z "$target_dir" || -z "$format" ]]; then
        print_error "Usage: batch_convert <source_dir> <target_dir> <json-to-toon|toon-to-json> [delimiter]"
        return 1
    fi
    
    if [[ ! -d "$source_dir" ]]; then
        print_error "Source directory not found: $source_dir"
        return 1
    fi
    
    mkdir -p "$target_dir"
    
    local count=0
    local success_count=0
    
    case "$format" in
        "json-to-toon")
            for file in "$source_dir"/*.json; do
                if [[ -f "$file" ]]; then
                    local basename
                    basename=$(basename "$file" .json)
                    local target_file="$target_dir/$basename.toon"
                    
                    ((count++))
                    if json_to_toon "$file" "$target_file" "$delimiter" "false"; then
                        ((success_count++))
                    fi
                fi
            done
            ;;
        "toon-to-json")
            for file in "$source_dir"/*.toon; do
                if [[ -f "$file" ]]; then
                    local basename
                    basename=$(basename "$file" .toon)
                    local target_file="$target_dir/$basename.json"
                    
                    ((count++))
                    if toon_to_json "$file" "$target_file" "true"; then
                        ((success_count++))
                    fi
                fi
            done
            ;;
        *)
            print_error "Invalid format: $format. Use 'json-to-toon' or 'toon-to-json'"
            return 1
            ;;
    esac
    
    print_success "Batch conversion completed: $success_count/$count files converted"
    return 0
}

# Compare token efficiency
compare_formats() {
    local input_file="$1"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        return 1
    fi

    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi

    print_info "Comparing token efficiency for: $input_file"
    echo ""

    # Show TOON with stats
    print_info "TOON format with token statistics:"
    $PKG_RUNNER @toon-format/cli --stats "$input_file"

    return 0
}

# Validate TOON format
validate_toon() {
    local input_file="$1"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        return 1
    fi

    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi

    print_info "Validating TOON format: $input_file"

    # Try to decode with strict validation
    if $PKG_RUNNER @toon-format/cli --decode "$input_file" > /dev/null 2>&1; then
        print_success "TOON format is valid"
        return 0
    else
        print_error "TOON format validation failed"
        return 1
    fi
    return 0
}

# Show TOON CLI version and info
show_info() {
    print_info "TOON Format Helper - AI DevOps Framework Integration"
    echo ""

    if check_toon; then
        print_info "TOON CLI version:"
        $PKG_RUNNER @toon-format/cli --help | head -1
        echo ""

        print_info "TOON Format Benefits:"
        echo "• 20-60% token reduction vs JSON"
        echo "• Human-readable tabular format"
        echo "• Schema-aware with explicit array lengths"
        echo "• Better LLM comprehension and generation"
        echo "• Supports nested structures and mixed data"
        echo ""

        print_info "Use cases in AI DevOps:"
        echo "• Configuration data for LLM prompts"
        echo "• API response formatting"
        echo "• Data exchange between AI tools"
        echo "• Structured logging and reports"
        echo "• Database exports for AI analysis"
    fi

    return 0
}

# Show help
show_help() {
    echo "TOON Format Helper Script"
    echo "Usage: $0 [command] [options...]"
    echo ""
    echo "Commands:"
    echo "  encode <input.json> [output.toon] [delimiter] [show_stats]"
    echo "    - Convert JSON to TOON format"
    printf "    - delimiter: ',' (default), '\\t' (tab), '|' (pipe)\\n"
    echo "    - show_stats: true/false (default: false)"
    echo ""
    echo "  decode <input.toon> [output.json] [strict_mode]"
    echo "    - Convert TOON to JSON format"
    echo "    - strict_mode: true (default)/false"
    echo ""
    echo "  stdin-encode [delimiter] [show_stats]"
    echo "    - Convert JSON from stdin to TOON"
    echo ""
    echo "  stdin-decode"
    echo "    - Convert TOON from stdin to JSON"
    echo ""
    echo "  batch <source_dir> <target_dir> <json-to-toon|toon-to-json> [delimiter]"
    echo "    - Batch convert directory of files"
    echo ""
    echo "  compare <input.json>"
    echo "    - Show token efficiency comparison"
    echo ""
    echo "  validate <input.toon>"
    echo "    - Validate TOON format"
    echo ""
    echo "  info"
    echo "    - Show TOON format information"
    echo ""
    echo "  help"
    echo "    - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 encode data.json output.toon"
    printf "  %s encode data.json output.toon '\\t' true\\n" "$0"
    echo "  $0 decode data.toon output.json"
    echo "  $0 batch ./json-files ./toon-files json-to-toon"
    echo "  cat data.json | $0 stdin-encode"
    printf "  cat data.json | %s stdin-encode \$'\\t' true  # Tab delimiter\\n" "$0"
    echo "  $0 compare large-dataset.json"
    echo "  $0 validate data.toon"

    return 0
}

# Main script logic
main() {
    local command="${1:-help}"
    local arg2="$2"
    local arg3="$3"
    local arg4="$4"
    local arg5="$5"

    case "$command" in
        "encode"|"json-to-toon")
            local input_file="$arg2"
            local output_file="$arg3"
            local delimiter="${arg4:-,}"
            local show_stats="${arg5:-false}"

            if check_toon; then
                json_to_toon "$input_file" "$output_file" "$delimiter" "$show_stats"
            fi
            ;;
        "decode"|"toon-to-json")
            local input_file="$arg2"
            local output_file="$arg3"
            local strict_mode="${arg4:-true}"

            if check_toon; then
                toon_to_json "$input_file" "$output_file" "$strict_mode"
            fi
            ;;
        "stdin-encode")
            local delimiter="${arg2:-,}"
            local show_stats="${arg3:-false}"

            if check_toon; then
                convert_stdin "encode" "$delimiter" "$show_stats"
            fi
            ;;
        "stdin-decode")
            if check_toon; then
                convert_stdin "decode"
            fi
            ;;
        "batch")
            local source_dir="$arg2"
            local target_dir="$arg3"
            local format="$arg4"
            local delimiter="${arg5:-,}"

            if check_toon; then
                batch_convert "$source_dir" "$target_dir" "$format" "$delimiter"
            fi
            ;;
        "compare")
            local input_file="$arg2"

            if check_toon; then
                compare_formats "$input_file"
            fi
            ;;
        "validate")
            local input_file="$arg2"

            if check_toon; then
                validate_toon "$input_file"
            fi
            ;;
        "info")
            show_info
            ;;
        "help"|*)
            show_help
            ;;
    esac

    return 0
}

# Execute main function with all arguments
main "$@"
