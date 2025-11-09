#!/bin/bash

# Script to fix common SonarCloud issues in shell scripts
# This addresses the 603 issues found by SonarCloud analysis

echo "🔧 Fixing SonarCloud issues in shell scripts..."

# Function to fix print functions - redirect errors to stderr
fix_print_functions() {
    local file="$1"
    echo "  📝 Fixing print functions in $file"
    
    # Fix print_error to redirect to stderr
    sed -i 's/print_error() { echo -e "${RED}\[ERROR\]${NC} $1"; }/print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >\&2; return 0; }/' "$file"
    
    # Fix other print functions to assign parameter to local variable and add return
    sed -i 's/print_info() { echo -e "${BLUE}\[INFO\]${NC} $1"; }/print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }/' "$file"
    sed -i 's/print_success() { echo -e "${GREEN}\[SUCCESS\]${NC} $1"; }/print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }/' "$file"
    sed -i 's/print_warning() { echo -e "${YELLOW}\[WARNING\]${NC} $1"; }/print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }/' "$file"
}

# Function to add return statements to functions that don't have them
add_return_statements() {
    local file="$1"
    echo "  🔄 Adding return statements to $file"
    
    # This is a complex fix that would require parsing each function
    # For now, we'll add a comment to manually fix these
    echo "    ⚠️  Manual fix needed: Add 'return 0' to end of functions without explicit returns"
}

# Function to fix unused variables
fix_unused_variables() {
    local file="$1"
    echo "  🗑️  Removing unused variables in $file"
    
    # Remove unused api_secret variable if it exists
    sed -i '/local api_secret=/d' "$file"
}

# Process all shell scripts in providers directory
for script in providers/*.sh; do
    if [ -f "$script" ]; then
        echo "🔧 Processing $script"
        fix_print_functions "$script"
        fix_unused_variables "$script"
        add_return_statements "$script"
    fi
done

echo "✅ SonarCloud issue fixes applied to all shell scripts"
echo "📋 Manual fixes still needed:"
echo "   - Add 'return 0' statements to end of functions"
echo "   - Assign positional parameters to local variables in complex functions"
echo "   - Review and test all changes"
