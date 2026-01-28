#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# SEO Data Export Helper Script
# Unified router for exporting SEO data from multiple platforms to TOON format
# Platforms: GSC, Bing, Ahrefs, DataForSEO
#
# Usage: seo-export-helper.sh [platform|all] [domain] [options]
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
    source "$SCRIPT_DIR/shared-constants.sh"
fi

# =============================================================================
# Configuration
# =============================================================================

readonly SEO_DATA_DIR="$HOME/.aidevops/.agent-workspace/work/seo-data"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly DEFAULT_DAYS=90

# Colors (fallback if shared-constants not loaded)
readonly RED="${COLOR_RED:-\033[0;31m}"
readonly GREEN="${COLOR_GREEN:-\033[0;32m}"
readonly BLUE="${COLOR_BLUE:-\033[0;34m}"
readonly YELLOW="${COLOR_YELLOW:-\033[1;33m}"
readonly PURPLE="${COLOR_PURPLE:-\033[0;35m}"
readonly NC="${COLOR_RESET:-\033[0m}"

# =============================================================================
# Utility Functions
# =============================================================================

print_header() { local msg="$1"; echo -e "${PURPLE}=== $msg ===${NC}"; return 0; }
print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >&2; return 0; }

# Ensure data directory exists
ensure_directories() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    mkdir -p "$domain_dir"
    echo "$domain_dir"
    return 0
}

# Calculate date range
get_date_range() {
    local days="$1"
    local end_date
    local start_date
    
    end_date=$(date +%Y-%m-%d)
    # macOS vs Linux date compatibility
    if date -v-1d &>/dev/null; then
        start_date=$(date -v-${days}d +%Y-%m-%d)
    else
        start_date=$(date -d "$days days ago" +%Y-%m-%d)
    fi
    
    echo "$start_date $end_date"
    return 0
}

# Check if platform script exists
check_platform_script() {
    local platform="$1"
    local script_path="$SCRIPT_DIR/seo-export-${platform}.sh"
    
    if [[ ! -f "$script_path" ]]; then
        print_error "Platform script not found: $script_path"
        return 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi
    
    return 0
}

# List available platforms
list_platforms() {
    print_header "Available SEO Export Platforms"
    echo ""
    echo "Platform      Status      Description"
    echo "--------      ------      -----------"
    
    local platforms=("gsc" "bing" "ahrefs" "dataforseo")
    
    for platform in "${platforms[@]}"; do
        local script_path="$SCRIPT_DIR/seo-export-${platform}.sh"
        local status="missing"
        local desc=""
        
        if [[ -f "$script_path" ]]; then
            status="ready"
        fi
        
        case "$platform" in
            gsc) desc="Google Search Console" ;;
            bing) desc="Bing Webmaster Tools" ;;
            ahrefs) desc="Ahrefs organic keywords" ;;
            dataforseo) desc="DataForSEO ranked keywords" ;;
        esac
        
        if [[ "$status" == "ready" ]]; then
            echo -e "${GREEN}$platform${NC}         $status      $desc"
        else
            echo -e "${YELLOW}$platform${NC}         $status      $desc"
        fi
    done
    
    echo ""
    return 0
}

# List exported data for a domain
list_exports() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    
    if [[ ! -d "$domain_dir" ]]; then
        print_warning "No exports found for domain: $domain"
        return 0
    fi
    
    print_header "Exports for $domain"
    echo ""
    
    local count=0
    for file in "$domain_dir"/*.toon; do
        if [[ -f "$file" ]]; then
            local filename
            filename=$(basename "$file")
            local size
            size=$(du -h "$file" | cut -f1)
            local modified
            modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1-2)
            echo "$filename  ($size)  $modified"
            ((count++))
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        echo "No .toon files found"
    fi
    
    echo ""
    return 0
}

# Export from a single platform
export_platform() {
    local platform="$1"
    local domain="$2"
    local days="$3"
    
    check_platform_script "$platform" || return 1
    
    local script_path="$SCRIPT_DIR/seo-export-${platform}.sh"
    
    print_info "Exporting from $platform for $domain (last $days days)..."
    
    if "$script_path" "$domain" --days "$days"; then
        print_success "Export complete: $platform"
        return 0
    else
        print_error "Export failed: $platform"
        return 1
    fi
}

# Export from all platforms
export_all() {
    local domain="$1"
    local days="$2"
    
    local platforms=("gsc" "bing" "ahrefs" "dataforseo")
    local success_count=0
    local fail_count=0
    
    print_header "Exporting from all platforms for $domain"
    echo ""
    
    for platform in "${platforms[@]}"; do
        local script_path="$SCRIPT_DIR/seo-export-${platform}.sh"
        
        if [[ ! -f "$script_path" ]]; then
            print_warning "Skipping $platform (script not found)"
            continue
        fi
        
        if export_platform "$platform" "$domain" "$days"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        echo ""
    done
    
    print_header "Export Summary"
    echo "Successful: $success_count"
    echo "Failed: $fail_count"
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
SEO Data Export Helper

Export SEO data from multiple platforms to TOON format for analysis.

Usage:
    seo-export-helper.sh [command] [options]

Commands:
    gsc <domain>           Export from Google Search Console
    bing <domain>          Export from Bing Webmaster Tools
    ahrefs <domain>        Export from Ahrefs
    dataforseo <domain>    Export from DataForSEO
    all <domain>           Export from all configured platforms
    list                   List available platforms
    exports <domain>       List exports for a domain

Options:
    --days N               Number of days to export (default: 90)
    --help, -h             Show this help message

Examples:
    # Export last 90 days from GSC
    seo-export-helper.sh gsc example.com

    # Export last 30 days from all platforms
    seo-export-helper.sh all example.com --days 30

    # List available platforms
    seo-export-helper.sh list

    # List exports for a domain
    seo-export-helper.sh exports example.com

Output:
    Data is saved to: ~/.aidevops/.agent-workspace/work/seo-data/{domain}/
    Filename format: {platform}-{start-date}-{end-date}.toon

TOON Format:
    domain	example.com
    source	gsc
    exported	2026-01-28T10:00:00Z
    start_date	2025-10-30
    end_date	2026-01-28
    ---
    query	page	clicks	impressions	ctr	position
    best seo tools	/blog/seo-tools	150	5000	0.03	8.2

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-}"
    shift || true
    
    # Parse global options
    local domain=""
    local days="$DEFAULT_DAYS"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                days="${2:-$DEFAULT_DAYS}"
                shift 2
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            -*)
                print_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"
                fi
                shift
                ;;
        esac
    done
    
    case "$command" in
        gsc|bing|ahrefs|dataforseo)
            if [[ -z "$domain" ]]; then
                print_error "Domain is required"
                echo "Usage: seo-export-helper.sh $command <domain> [--days N]"
                return 1
            fi
            ensure_directories "$domain" >/dev/null
            export_platform "$command" "$domain" "$days"
            ;;
        all)
            if [[ -z "$domain" ]]; then
                print_error "Domain is required"
                echo "Usage: seo-export-helper.sh all <domain> [--days N]"
                return 1
            fi
            ensure_directories "$domain" >/dev/null
            export_all "$domain" "$days"
            ;;
        list)
            list_platforms
            ;;
        exports)
            if [[ -z "$domain" ]]; then
                print_error "Domain is required"
                echo "Usage: seo-export-helper.sh exports <domain>"
                return 1
            fi
            list_exports "$domain"
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Use 'seo-export-helper.sh help' for usage information"
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
