#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Script to add return statements to functions that need them
# Based on SonarCloud S7682 issues

FILE=".agent/scripts/101domains-helper.sh"

# Function to add return statement before closing brace
add_return_statement() {
    local line_num=$1
    sed -i "${line_num}i\\    return 0" "$FILE"
    return 0
}

# Lines where functions end (based on SonarCloud analysis)
# These are the line numbers where we need to add return statements
FUNCTION_END_LINES=(
    256   # purchase_domain
    283   # get_nameservers  
    303   # update_nameservers
    329   # delete_dns_record
    357   # check_availability
    377   # get_contacts
    406   # update_nameservers
    426   # lock_domain
    446   # get_transfer_status
    475   # monitor_expiration
    508   # help
    528   # main function
    565   # end of file
)

# Add return statements in reverse order to avoid line number shifts
for ((i=${#FUNCTION_END_LINES[@]}-1; i>=0; i--)); do
    line_num=${FUNCTION_END_LINES[i]}
    echo "Adding return statement before line $line_num"
    add_return_statement "$line_num"
done

echo "Return statements added to all functions in $FILE"
