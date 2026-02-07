#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Find Functions Missing Return Statements
# Identify functions that need return statements for S7682 compliance
#
# Author: AI DevOps Framework
# Version: 1.1.1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Find functions missing return statements in a file
find_missing_returns_in_file() {
    local file="$1"

    print_info "Analyzing: $file"
    
    # Extract function definitions and check for return statements
    awk '
    BEGIN {
        in_function = 0
        function_name = ""
        function_content = ""
        brace_count = 0
    }
    
    # Function start
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
        if (in_function) {
            # Previous function ended without proper closing
            if (function_content !~ /return[[:space:]]+[0-9]+/ && 
                function_content !~ /return[[:space:]]+\$/ &&
                function_content !~ /return[[:space:]]*$/ &&
                function_content !~ /exit[[:space:]]+[0-9]+/) {
                print "Missing return: " function_name
            }
        }
        
        in_function = 1
        function_name = $1
        gsub(/\(\).*/, "", function_name)
        function_content = ""
        brace_count = 1
        next
    }
    
    # Inside function
    in_function == 1 {
        function_content = function_content "\n" $0
        
        # Count braces
        brace_count += gsub(/\{/, "&")
        brace_count -= gsub(/\}/, "&")
        
        # Function ends
        if (brace_count == 0) {
            if (function_content !~ /return[[:space:]]+[0-9]+/ && 
                function_content !~ /return[[:space:]]+\$/ &&
                function_content !~ /return[[:space:]]*$/ &&
                function_content !~ /exit[[:space:]]+[0-9]+/) {
                print "Missing return: " function_name
            }
            in_function = 0
            function_name = ""
            function_content = ""
        }
    }
    
    END {
        # Handle case where file ends while in function
        if (in_function && function_content !~ /return[[:space:]]+[0-9]+/ && 
            function_content !~ /return[[:space:]]*$/ &&
            function_content !~ /exit[[:space:]]+[0-9]+/) {
            print "Missing return: " function_name
        }
    }
    ' "$file"
    return 0
}

# Main execution
main() {
    local target="${1:-.}"
    
    if [[ -f "$target" && "$target" == *.sh ]]; then
        find_missing_returns_in_file "$target"
    elif [[ -d "$target" ]]; then
        find "$target" -name "*.sh" -type f | while read -r file; do
            find_missing_returns_in_file "$file"
        done
    else
        print_error "Invalid target: $target"
        return 1
    fi
    return 0
}

main "$@"
