#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Fix Content-Type String Literals
# Replace repeated "Content-Type: application/json" with constants
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

# Fix Content-Type in a file
fix_content_type_in_file() {
    local file="$1"
    local count
    count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
    count=${count//[^0-9]/}
    
    if [[ $count -ge 2 ]]; then
        print_info "Fixing $count occurrences in: $file"
        
        # Add constant if not present
        if ! grep -q "CONTENT_TYPE_JSON" "$file"; then
            # Find where to insert the constant (after colors, before functions)
            if grep -q "NC=.*No Color" "$file"; then
                sed -i '' '/NC=.*No Color/a\
\
# Common constants\
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
' "$file"
            elif grep -q "readonly.*NC=" "$file"; then
                sed -i '' '/readonly.*NC=/a\
\
# Common constants\
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
' "$file"
            fi
        fi
        
        # Replace occurrences
        sed -i '' 's/"Content-Type: application\/json"/$CONTENT_TYPE_JSON/g' "$file"
        
        # Verify
        local new_count
        new_count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
        new_count=${new_count//[^0-9]/}
        local const_count
        const_count=$(grep -c "CONTENT_TYPE_JSON" "$file" 2>/dev/null || echo "0")
        const_count=${const_count//[^0-9]/}
        
        if [[ $new_count -eq 0 && $const_count -gt 0 ]]; then
            print_success "Fixed $file: $count → 0 literals, $const_count constant usages"
            return 0
        else
            print_info "Partial fix in $file: $new_count literals remaining"
            return 1
        fi
    else
        print_info "Skipping $file: only $count occurrences (need 2+)"
        return 1
    fi
    return 0
}

# Main execution
main() {
    print_info "Fixing Content-Type string literals in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_content_type_in_file "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"
