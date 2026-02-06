#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Fix Common Error Message String Literals
# Replace repeated error message patterns with constants
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

# Fix error messages in a file
fix_error_messages_in_file() {
    local file="$1"
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Check for common error patterns
    local unknown_cmd_count
    unknown_cmd_count=$(grep -c "Unknown command" "$file" 2>/dev/null || echo "0")
    
    local usage_count
    usage_count=$(grep -c "Usage:" "$file" 2>/dev/null || echo "0")
    
    local help_count
    help_count=$(grep -c "help.*Show this help" "$file" 2>/dev/null || echo "0")
    
    # Add constants section if needed
    if [[ $unknown_cmd_count -ge 1 || $usage_count -ge 2 || $help_count -ge 2 ]]; then
        if ! grep -q "# Error message constants\|# Common constants" "$file"; then
            # Find where to insert constants
            if grep -q "readonly.*NC=" "$file"; then
                sed -i '' '/readonly.*NC=/a\
\
# Error message constants
' "$file"
            elif grep -q "NC=.*No Color" "$file"; then
                sed -i '' '/NC=.*No Color/a\
\
# Error message constants
' "$file"
            fi
        fi
        
        # Fix Unknown command pattern
        if [[ $unknown_cmd_count -ge 1 ]]; then
            if ! grep -q "ERROR_UNKNOWN_COMMAND" "$file"; then
                sed -i '' '/# Error message constants/a\
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
' "$file"
                changes_made=1
            fi
            sed -i '' "s/\"Unknown command: \\\$command\"/\"\$ERROR_UNKNOWN_COMMAND \$command\"/g" "$file"
            sed -i '' "s/\"Unknown command: \$command\"/\"\$ERROR_UNKNOWN_COMMAND \$command\"/g" "$file"
            print_success "Fixed $unknown_cmd_count Unknown command messages"
        fi
        
        # Fix Usage pattern
        if [[ $usage_count -ge 2 ]]; then
            if ! grep -q "USAGE_PREFIX" "$file"; then
                sed -i '' '/# Error message constants/a\
readonly USAGE_PREFIX="Usage:"
' "$file"
                changes_made=1
            fi
            sed -i '' "s/\"Usage: \\\$0\"/\"\$USAGE_PREFIX \$0\"/g" "$file"
            sed -i '' "s/\"Usage: \$0\"/\"\$USAGE_PREFIX \$0\"/g" "$file"
            print_success "Fixed $usage_count Usage messages"
        fi
        
        # Fix help message pattern
        if [[ $help_count -ge 2 ]]; then
            if ! grep -q "HELP_MESSAGE_SUFFIX" "$file"; then
                sed -i '' '/# Error message constants/a\
readonly HELP_MESSAGE_SUFFIX="Show this help message"
' "$file"
                changes_made=1
            fi
            sed -i '' "s/\".*help.*- Show this help message\"/\"  help                 - \$HELP_MESSAGE_SUFFIX\"/g" "$file"
            print_success "Fixed $help_count help messages"
        fi
    fi
    
    if [[ $changes_made -gt 0 ]]; then
        print_success "Fixed error messages in: $file"
        return 0
    else
        print_info "No error message patterns requiring fixes in: $file"
        return 1
    fi
    return 0
}

# Main execution
main() {
    print_info "Fixing error message string literals in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_error_messages_in_file "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"
