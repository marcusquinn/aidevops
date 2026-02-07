#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Auto Version Bump Script for AI DevOps Framework
# Automatically determines version bump type based on commit message
#
# Author: AI DevOps Framework
# Version: 1.1.1

# Source shared constants (provides sed_inplace, print_*, color constants)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Repository root directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit
VERSION_MANAGER="$REPO_ROOT/.agents/scripts/version-manager.sh"

# Function to determine version bump type from commit message
determine_bump_type() {
    local commit_message="$1"
    
    # Major version indicators (breaking changes)
    if echo "$commit_message" | grep -qE "BREAKING|MAJOR|💥|🚨.*BREAKING"; then
        echo "major"
        return 0
    fi
    
    # Minor version indicators (new features)
    if echo "$commit_message" | grep -qE "FEATURE|FEAT|NEW|ADD|✨|🚀|📦|🎯.*NEW|🎯.*ADD"; then
        echo "minor"
        return 0
    fi
    
    # Patch version indicators (bug fixes, improvements)
    if echo "$commit_message" | grep -qE "FIX|PATCH|BUG|IMPROVE|UPDATE|ENHANCE|🔧|🐛|📝|🎨|♻️|⚡|🔒|📊"; then
        echo "patch"
        return 0
    fi
    
    # Default to patch for any other changes
    echo "patch"
    return 0
}

# Function to check if version should be bumped
should_bump_version() {
    local commit_message="$1"
    
    # Skip version bump for certain commit types
    if echo "$commit_message" | grep -qE "^(docs|style|test|chore|ci|build):|WIP|SKIP.*VERSION|NO.*VERSION"; then
        return 1
    fi
    
    return 0
}

# Function to update version badge in README
update_version_badge() {
    local new_version="$1"
    local readme_file="$REPO_ROOT/README.md"

    if [[ -f "$readme_file" ]]; then
        # Skip if using dynamic GitHub release badge
        if grep -q "img.shields.io/github/v/release" "$readme_file"; then
            print_success "README.md uses dynamic GitHub release badge (no update needed)"
            return 0
        fi
        
        # Use cross-platform sed for hardcoded badge
        sed_inplace "s/Version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-blue/Version-$new_version-blue/" "$readme_file"

        # Validate the update was successful
        if grep -q "Version-$new_version-blue" "$readme_file"; then
            print_success "Updated version badge in README.md to $new_version"
        else
            print_warning "README.md has no version badge (consider adding dynamic GitHub release badge)"
        fi
    fi
    return 0
}

# Main function
main() {
    local commit_message="$1"
    
    if [[ -z "$commit_message" ]]; then
        # Get the last commit message
        commit_message=$(git log -1 --pretty=%B 2>/dev/null)
        if [[ -z "$commit_message" ]]; then
            print_error "No commit message provided and unable to get last commit"
            exit 1
        fi
    fi
    
    print_info "Analyzing commit message: $commit_message"
    
    if ! should_bump_version "$commit_message"; then
        print_info "Skipping version bump for this commit type"
        exit 0
    fi
    
    local bump_type
    bump_type=$(determine_bump_type "$commit_message")
    
    print_info "Determined bump type: $bump_type"
    
    if [[ -x "$VERSION_MANAGER" ]]; then
        local current_version
        current_version=$("$VERSION_MANAGER" get)
        
        local new_version
        new_version=$("$VERSION_MANAGER" bump "$bump_type")
        
        if [[ $? -eq 0 ]]; then
            print_success "Version bumped: $current_version → $new_version"
            update_version_badge "$new_version"
            
            # Add updated files to git (all version-tracked files)
            git add VERSION README.md sonar-project.properties setup.sh aidevops.sh package.json .claude-plugin/marketplace.json 2>/dev/null
            
            echo "$new_version"
        else
            print_error "Failed to bump version"
            exit 1
        fi
    else
        print_error "Version manager script not found or not executable"
        exit 1
    fi
    return 0
}

# Show usage if no arguments and not in git repo
if [[ $# -eq 0 && ! -d .git ]]; then
    echo "Auto Version Bump for AI DevOps Framework"
    echo ""
    echo "Usage: $0 [commit_message]"
    echo ""
    echo "Automatically determines version bump type based on commit message:"
    echo "  MAJOR: BREAKING, MAJOR, 💥, 🚨 BREAKING"
    echo "  MINOR: FEATURE, FEAT, NEW, ADD, ✨, 🚀, 📦, 🎯 NEW/ADD"
    echo "  PATCH: FIX, PATCH, BUG, IMPROVE, UPDATE, ENHANCE, 🔧, 🐛, 📝, 🎨, ♻️, ⚡, 🔒, 📊"
    echo ""
    echo "Skips version bump for: docs, style, test, chore, ci, build, WIP, SKIP VERSION, NO VERSION"
    echo ""
    echo "Examples:"
    echo "  $0 '🚀 FEATURE: Add new Hetzner integration'"
    echo "  $0 '🔧 FIX: Resolve badge display issue'"
    echo "  $0 '💥 BREAKING: Change API structure'"
    exit 0
fi

main "$@"
