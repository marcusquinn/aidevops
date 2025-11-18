#!/bin/bash

# AI DevOps Framework - Version Consistency Validator
# Validates that all version references are synchronized across the framework

set -euo pipefail

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

# Color output functions
print_success() { echo -e "\033[32m✅ $1\033[0m"; }
print_error() { echo -e "\033[31m❌ $1\033[0m"; }
print_warning() { echo -e "\033[33m⚠️  $1\033[0m"; }
print_info() { echo -e "\033[34mℹ️  $1\033[0m"; }

# Function to get current version
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "1.0.0"
    fi
}

# Function to validate version consistency across files
validate_version_consistency() {
    local expected_version="$1"
    local errors=0
    local warnings=0
    
    print_info "🔍 Validating version consistency across files..."
    print_info "Expected version: $expected_version"
    echo ""
    
    # Check VERSION file
    if [[ -f "$VERSION_FILE" ]]; then
        local version_file_content
        version_file_content=$(cat "$VERSION_FILE")
        if [[ "$version_file_content" != "$expected_version" ]]; then
            print_error "VERSION file contains '$version_file_content', expected '$expected_version'"
            errors=$((errors + 1))
        else
            print_success "VERSION file: $expected_version"
        fi
    else
        print_error "VERSION file not found at $VERSION_FILE"
        errors=$((errors + 1))
    fi
    
    # Check README badge
    if [[ -f "$REPO_ROOT/README.md" ]]; then
        if grep -q "Version-$expected_version-blue" "$REPO_ROOT/README.md"; then
            print_success "README.md badge: $expected_version"
        else
            local current_badge
            current_badge=$(grep -o "Version-[0-9]\+\.[0-9]\+\.[0-9]\+-blue" "$REPO_ROOT/README.md" || echo "not found")
            print_error "README.md badge shows '$current_badge', expected 'Version-$expected_version-blue'"
            errors=$((errors + 1))
        fi
    else
        print_warning "README.md not found"
        warnings=$((warnings + 1))
    fi
    
    # Check sonar-project.properties
    if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
        if grep -q "sonar.projectVersion=$expected_version" "$REPO_ROOT/sonar-project.properties"; then
            print_success "sonar-project.properties: $expected_version"
        else
            local current_sonar
            current_sonar=$(grep "sonar.projectVersion=" "$REPO_ROOT/sonar-project.properties" | cut -d'=' -f2 || echo "not found")
            print_error "sonar-project.properties shows '$current_sonar', expected '$expected_version'"
            errors=$((errors + 1))
        fi
    else
        print_warning "sonar-project.properties not found"
        warnings=$((warnings + 1))
    fi
    
    # Check setup.sh
    if [[ -f "$REPO_ROOT/setup.sh" ]]; then
        if grep -q "# Version: $expected_version" "$REPO_ROOT/setup.sh"; then
            print_success "setup.sh: $expected_version"
        else
            local current_setup
            current_setup=$(grep "# Version:" "$REPO_ROOT/setup.sh" | cut -d':' -f2 | xargs || echo "not found")
            print_error "setup.sh shows '$current_setup', expected '$expected_version'"
            errors=$((errors + 1))
        fi
    else
        print_warning "setup.sh not found"
        warnings=$((warnings + 1))
    fi
    
    echo ""
    print_info "📊 Validation Summary:"
    
    if [[ $errors -eq 0 ]]; then
        print_success "All version references are consistent: $expected_version"
        if [[ $warnings -gt 0 ]]; then
            print_warning "Found $warnings optional files missing (not critical)"
        fi
        return 0
    else
        print_error "Found $errors version inconsistencies"
        if [[ $warnings -gt 0 ]]; then
            print_warning "Found $warnings optional files missing"
        fi
        return 1
    fi
}

# Main function
main() {
    local version_to_check="$1"
    
    if [[ -z "$version_to_check" ]]; then
        version_to_check=$(get_current_version)
        print_info "No version specified, using current version from VERSION file: $version_to_check"
    fi
    
    validate_version_consistency "$version_to_check"
}

# Show usage if no arguments provided
if [[ $# -eq 0 ]]; then
    echo "AI DevOps Framework - Version Consistency Validator"
    echo ""
    echo "Usage: $0 [version]"
    echo ""
    echo "Arguments:"
    echo "  version    Version to validate (optional, defaults to VERSION file content)"
    echo ""
    echo "Examples:"
    echo "  $0           # Validate current version from VERSION file"
    echo "  $0 1.6.0     # Validate specific version"
    echo ""
    exit 0
fi

main "$@"
