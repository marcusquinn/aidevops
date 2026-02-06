#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Script to fix misplaced return statements in mainwp-helper.sh
# These were introduced by the earlier mass fix script

cd providers || exit

echo "🔧 Fixing misplaced return statements in mainwp-helper.sh..."

# Remove misplaced return statements that are not at the end of functions
# These are typically in the middle of functions or before other statements

# Fix specific patterns where return 0 appears before other statements
sed -i '' '
# Remove return 0 that appears before exit statements
/return 0$/{
    N
    /return 0\n        exit 1/c\
        exit 1
}
' mainwp-helper.sh

# Remove return 0 that appears before print statements
sed -i '' '
/return 0$/{
    N
    /return 0\n    print_/c\
    print_info "$(echo "$0" | sed "s/.*print_info \"//" | sed "s/\"$//")"
    return 0
}
' mainwp-helper.sh

# Remove return 0 that appears before local variable declarations
sed -i '' '
/return 0$/{
    N
    /return 0\n    local /c\
    local $(echo "$0" | sed "s/.*local //" | sed "s/$/")
    return 0
}
' mainwp-helper.sh

# Remove return 0 that appears before if statements
sed -i '' '
/return 0$/{
    N
    /return 0\n    if /c\
    if $(echo "$0" | sed "s/.*if //")
    return 0
}
' mainwp-helper.sh

# Remove return 0 that appears before jq commands
sed -i '' '
/return 0$/{
    N
    /return 0\n    jq /c\
    jq $(echo "$0" | sed "s/.*jq //")
    return 0
}
' mainwp-helper.sh

# Remove return 0 that appears before echo statements
sed -i '' '
/return 0$/{
    N
    /return 0\n    echo /c\
    echo $(echo "$0" | sed "s/.*echo //")
    return 0
}
' mainwp-helper.sh

echo "✅ Fixed misplaced return statements in mainwp-helper.sh"
