#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Fix SC2155 Issues - Simple Approach
# Fix "declare and assign separately" issues
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

# Fix SC2155 in a file using simple patterns
fix_sc2155_simple() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Create backup
    cp "$file" "${file}.backup"
    
    # Count SC2155 issues before
    local before_count
    before_count=$(shellcheck "$file" 2>&1 | grep -c "SC2155" || echo "0")
    
    if [[ $before_count -eq 0 ]]; then
        rm "${file}.backup"
        print_info "No SC2155 issues in: $file"
        return 1
    fi
    
    # Apply simple fixes using sed
    sed '
        # Fix: local var=$(command) -> local var; var=$(command)
        s/^[[:space:]]*local[[:space:]]\+\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*=[[:space:]]*\$(/local \1\n    \1=$(/
        
        # Fix: local var="$(command)" -> local var; var="$(command)"
        s/^[[:space:]]*local[[:space:]]\+\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*=[[:space:]]*"\$(/local \1\n    \1="$(/
        
        # Fix: local var=`command` -> local var; var=`command`
        s/^[[:space:]]*local[[:space:]]\+\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*=[[:space:]]*`/local \1\n    \1=`/
    ' "$file" > "$temp_file"
    
    # Check if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        changes_made=1
        
        # Count SC2155 issues after
        local after_count
        after_count=$(shellcheck "$file" 2>&1 | grep -c "SC2155" || echo "0")
        
        print_success "Fixed SC2155 in $file: $before_count → $after_count issues"
        rm "${file}.backup"
        return 0
    else
        rm "$temp_file"
        mv "${file}.backup" "$file"
        print_info "No fixable SC2155 patterns in: $file"
        return 1
    fi
    return 0
}

# Main execution
main() {
    print_info "Fixing SC2155 issues in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_sc2155_simple "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"
