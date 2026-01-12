#!/bin/bash
# shellcheck disable=SC2034,SC2155
# Fix SonarCloud S131: Add default case (*) to case statements
#
# Usage: ./fix-s131-default-cases.sh [--dry-run] [--file <path>] [--all]
#
# This script finds case statements missing a default (*) case and adds one.

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; return 0; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; return 0; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; return 0; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; return 0; }

DRY_RUN=false
TARGET_FILE=""
FIX_ALL=false
SCRIPTS_DIR=".agent/scripts"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --file)
            TARGET_FILE="$2"
            shift 2
            ;;
        --all)
            FIX_ALL=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--file <path>] [--all]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be fixed without making changes"
            echo "  --file PATH  Fix only the specified file"
            echo "  --all        Fix all shell scripts in $SCRIPTS_DIR"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Find case statements missing default case
# Returns: filename:line_number for each violation
find_missing_defaults() {
    local file="$1"
    
    # Use awk to find case statements and check if they have a default
    awk '
    BEGIN { in_case = 0; case_line = 0; has_default = 0; depth = 0 }
    
    # Track case statement start
    /^[[:space:]]*case[[:space:]]/ {
        if (in_case == 0) {
            in_case = 1
            case_line = NR
            has_default = 0
            depth = 1
        }
    }
    
    # Track nested case (increment depth)
    in_case && /^[[:space:]]*case[[:space:]]/ && NR != case_line {
        depth++
    }
    
    # Check for default case pattern
    in_case && depth == 1 && /^[[:space:]]*\*\)/ {
        has_default = 1
    }
    
    # Also check for combined patterns like "help"|*)
    in_case && depth == 1 && /\|\*\)/ {
        has_default = 1
    }
    
    # Track esac (end of case)
    /^[[:space:]]*esac/ {
        if (in_case) {
            depth--
            if (depth == 0) {
                if (!has_default) {
                    print FILENAME ":" case_line ":" NR
                }
                in_case = 0
                has_default = 0
            }
        }
    }
    ' "$file"
    return 0
}

# Add default case before esac
add_default_case() {
    local file="$1"
    local esac_line="$2"
    
    # Detect indentation from the esac line
    local indent
    indent=$(sed -n "${esac_line}p" "$file" | sed 's/esac.*//' | cat -A | sed 's/\$$//')
    indent=$(sed -n "${esac_line}p" "$file" | grep -o '^[[:space:]]*')
    
    # The case pattern should be indented more than esac
    local case_indent="${indent}    "
    
    # Determine appropriate default action based on context
    # Look at the previous case patterns to understand the context
    local prev_lines
    prev_lines=$(sed -n "$((esac_line-10)),$((esac_line-1))p" "$file")
    
    local default_action="# Default case - no action"
    
    # Check if this is a main() function argument parser
    if echo "$prev_lines" | grep -qE '(--help|help\)|-h\))'; then
        default_action="# Unknown option or default behavior"
    fi
    
    # Check if previous cases use 'continue'
    if echo "$prev_lines" | grep -qE '[[:space:]]continue[[:space:]]*;;'; then
        default_action="# Process this item"
    fi
    
    # Check if previous cases use 'return'
    if echo "$prev_lines" | grep -qE '[[:space:]]return[[:space:]]'; then
        default_action="# Default: continue execution"
    fi
    
    # Insert the default case before esac
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "Would add default case at line $esac_line in $file"
        echo "        *)
            $default_action
            ;;"
    else
        # Create temp file and insert default case
        local temp_file
        temp_file=$(mktemp)
        
        head -n $((esac_line - 1)) "$file" > "$temp_file"
        {
            echo "${case_indent}*)"
            echo "${case_indent}    $default_action"
            echo "${case_indent}    ;;"
        } >> "$temp_file"
        tail -n +"$esac_line" "$file" >> "$temp_file"
        
        mv "$temp_file" "$file"
        print_success "Added default case at line $esac_line in $file"
    fi
    
    return 0
}

# Process a single file
process_file() {
    local file="$1"
    local violations
    local count=0
    local offset=0
    
    print_info "Processing: $file"
    
    # Find all violations (case_start_line:esac_line)
    violations=$(find_missing_defaults "$file")
    
    if [[ -z "$violations" ]]; then
        print_info "  No violations found"
        return 0
    fi
    
    # Process each violation (need to process from bottom to top to maintain line numbers)
    local sorted_violations
    sorted_violations=$(echo "$violations" | sort -t: -k3 -rn)
    
    while IFS=: read -r fname case_line esac_line; do
        [[ -z "$esac_line" ]] && continue
        
        print_info "  Found case at line $case_line, esac at line $esac_line"
        add_default_case "$file" "$esac_line"
        ((count++))
    done <<< "$sorted_violations"
    
    print_success "Fixed $count violation(s) in $file"
    return 0
}

# Main execution
main() {
    local total_fixed=0
    local files_processed=0
    
    print_info "SonarCloud S131 Fixer - Add default case to case statements"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi
    
    if [[ -n "$TARGET_FILE" ]]; then
        # Process single file
        if [[ ! -f "$TARGET_FILE" ]]; then
            print_error "File not found: $TARGET_FILE"
            exit 1
        fi
        process_file "$TARGET_FILE"
        
    elif [[ "$FIX_ALL" == "true" ]]; then
        # Process all shell scripts
        print_info "Scanning all scripts in $SCRIPTS_DIR..."
        echo ""
        
        while IFS= read -r -d '' file; do
            process_file "$file"
            ((files_processed++))
            echo ""
        done < <(find "$SCRIPTS_DIR" -name "*.sh" -type f -print0 | sort -z)
        
        print_success "Processed $files_processed files"
        
    else
        print_error "Please specify --file <path> or --all"
        echo "Use --help for usage information"
        exit 1
    fi
    
    return 0
}

main "$@"
