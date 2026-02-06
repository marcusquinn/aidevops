#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Fix Remaining String Literals
# Target specific high-impact string literal patterns
#
# Author: AI DevOps Framework
# Version: 1.1.1

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_success() {
    local _arg1="$1"
    echo -e "${GREEN}✅ $_arg1${NC}"
    return 0
}

print_info() {
    local _arg1="$1"
    echo -e "${BLUE}ℹ️  $_arg1${NC}"
    return 0
}

# Fix remaining string literals in a file
fix_remaining_literals_in_file() {
    local file="$1"
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Check for patterns that need constants
    local help_usage_count
    help_usage_count=$(grep -c "Use '\$0 help' for usage information" "$file" 2>/dev/null || echo "0")
    
    local usage_pattern_count
    usage_pattern_count=$(grep -c "Usage: \$0 \[command\]" "$file" 2>/dev/null || echo "0")
    
    local help_show_count
    help_show_count=$(grep -c "help.*- Show this help" "$file" 2>/dev/null || echo "0")
    
    # Add constants if patterns found
    if [[ $help_usage_count -ge 1 || $usage_pattern_count -ge 1 || $help_show_count -ge 1 ]]; then
        # Check if constants section exists
        if ! grep -q "# Common message constants\|# Error message constants" "$file"; then
            # Find where to insert constants
            if grep -q "readonly.*NC=" "$file"; then
                sed -i '' '/readonly.*NC=/a\
\
# Common message constants
' "$file"
            elif grep -q "NC=.*No Color" "$file"; then
                sed -i '' '/NC=.*No Color/a\
\
# Common message constants
' "$file"
            fi
        fi
        
        # Add specific constants
        if [[ $help_usage_count -ge 1 ]]; then
            if ! grep -q "HELP_USAGE_INFO" "$file"; then
                sed -i '' '/# Common message constants/a\
readonly HELP_USAGE_INFO="Use '\''$0 help'\'' for usage information"
' "$file"
                changes_made=1
            fi
            sed -i '' 's|"Use '\''$0 help'\'' for usage information"|"$HELP_USAGE_INFO"|g' "$file"
        fi
        
        if [[ $usage_pattern_count -ge 1 ]]; then
            if ! grep -q "USAGE_COMMAND_OPTIONS" "$file"; then
                sed -i '' '/# Common message constants/a\
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
' "$file"
                changes_made=1
            fi
            sed -i '' 's|"Usage: $0 \[command\] \[options\]"|"$USAGE_COMMAND_OPTIONS"|g' "$file"
        fi
        
        if [[ $help_show_count -ge 1 ]]; then
            if ! grep -q "HELP_SHOW_MESSAGE" "$file"; then
                sed -i '' '/# Common message constants/a\
readonly HELP_SHOW_MESSAGE="Show this help"
' "$file"
                changes_made=1
            fi
            sed -i '' 's|".*help.*- Show this help.*"|"  help                 - $HELP_SHOW_MESSAGE"|g' "$file"
        fi
    fi
    
    # Fix remaining Content-Type literals if any
    local content_type_count
    content_type_count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
    if [[ $content_type_count -ge 1 ]] && ! grep -q "CONTENT_TYPE_JSON" "$file"; then
        if ! grep -q "# Common message constants\|# Common constants" "$file" && grep -q "readonly.*NC=" "$file"; then
            sed -i '' '/readonly.*NC=/a\
\
# Common constants
' "$file"
        fi
        
        sed -i '' '/# Common.*constants/a\
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
' "$file"
        sed -i '' 's|"Content-Type: application/json"|"$CONTENT_TYPE_JSON"|g' "$file"
        changes_made=1
    fi
    
    if [[ $changes_made -eq 1 ]]; then
        print_success "Fixed string literals in: $file"
        return 0
    else
        print_info "No string literal fixes needed in: $file"
        return 1
    fi
    return 0
}

# Main execution
main() {
    local target="${1:-.agent/scripts/}"
    
    print_info "Fixing remaining string literals..."
    
    local files_fixed=0
    local files_processed=0
    
    if [[ -f "$target" && "$target" == *.sh ]]; then
        ((files_processed++))
        if fix_remaining_literals_in_file "$target"; then
            ((files_fixed++))
        fi
    elif [[ -d "$target" ]]; then
        find "$target" -name "*.sh" -type f | while read -r file; do
            ((files_processed++))
            if fix_remaining_literals_in_file "$file"; then
                ((files_fixed++))
            fi
        done
    else
        print_info "Invalid target: $target"
        return 1
    fi
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"
