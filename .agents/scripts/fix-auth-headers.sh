#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Fix Authorization Header String Literals
# Replace repeated "Authorization: Bearer" patterns with constants
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

# Fix Authorization header in a file
fix_auth_header_in_file() {
    local file="$1"
    local count
    count=$(grep -c "Authorization: Bearer" "$file" 2>/dev/null || echo "0")
    
    if [[ $count -ge 3 ]]; then
        print_info "Fixing $count Authorization header occurrences in: $file"
        
        # Add constant if not present
        if ! grep -q "AUTH_BEARER_PREFIX" "$file"; then
            # Find where to insert the constant (after CONTENT_TYPE_JSON or after colors)
            if grep -q "readonly CONTENT_TYPE_JSON" "$file"; then
                sed -i '' '/readonly CONTENT_TYPE_JSON/a\
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
' "$file"
            elif grep -q "NC=.*No Color" "$file"; then
                sed -i '' '/NC=.*No Color/a\
\
# Common constants\
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
' "$file"
            elif grep -q "readonly.*NC=" "$file"; then
                sed -i '' '/readonly.*NC=/a\
\
# Common constants\
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
' "$file"
            fi
        fi
        
        # Replace occurrences - handle different patterns
        sed -i '' "s/\"Authorization: Bearer \\\$api_token\"/\"\$AUTH_BEARER_PREFIX \$api_token\"/g" "$file"
        sed -i '' "s/\"Authorization: Bearer \\\${api_token}\"/\"\$AUTH_BEARER_PREFIX \${api_token}\"/g" "$file"
        sed -i '' "s/\"Authorization: Bearer \\\$token\"/\"\$AUTH_BEARER_PREFIX \$token\"/g" "$file"
        sed -i '' "s/\"Authorization: Bearer \\\${token}\"/\"\$AUTH_BEARER_PREFIX \${token}\"/g" "$file"
        
        # Verify
        local new_count
        new_count=$(grep -c "Authorization: Bearer" "$file" 2>/dev/null || echo "0")
        local const_count
        const_count=$(grep -c "AUTH_BEARER_PREFIX" "$file" 2>/dev/null || echo "0")
        
        if [[ $new_count -eq 1 && $const_count -gt 1 ]]; then
            print_success "Fixed $file: $count → 1 definition + $((const_count-1)) usages"
            return 0
        else
            print_info "Partial fix in $file: $new_count literals remaining, $const_count constant usages"
            return 1
        fi
    else
        print_info "Skipping $file: only $count occurrences (need 3+)"
        return 1
    fi
    return 0
}

# Main execution
main() {
    print_info "Fixing Authorization header string literals in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_auth_header_in_file "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"
