#!/usr/bin/env bash
# shellcheck disable=SC1091

# Rosetta Audit Helper - Detect x86 Homebrew binaries on Apple Silicon
# Helps migrate from x86 Homebrew to ARM-native versions for better performance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# ============================================================================
# Architecture Detection
# ============================================================================

is_apple_silicon() {
    local arch
    arch=$(uname -m)
    [[ "$arch" == "arm64" ]] && return 0
    return 1
}

is_intel_mac() {
    local os
    local arch
    os=$(uname -s)
    arch=$(uname -m)
    [[ "$os" == "Darwin" ]] && [[ "$arch" == "x86_64" ]] && return 0
    return 1
}

# ============================================================================
# Rosetta Detection
# ============================================================================

check_rosetta_installed() {
    if [[ -f /Library/Apple/usr/share/rosetta/rosetta ]]; then
        return 0
    fi
    return 1
}

get_binary_arch() {
    local binary="$1"
    local arch_output
    
    if [[ ! -f "$binary" ]]; then
        echo "not_found"
        return 1
    fi
    
    # Use file command to detect architecture
    arch_output=$(file "$binary" 2>/dev/null || echo "")
    
    if [[ "$arch_output" == *"Mach-O 64-bit executable x86_64"* ]]; then
        echo "x86_64"
        return 0
    elif [[ "$arch_output" == *"Mach-O 64-bit executable arm64"* ]]; then
        echo "arm64"
        return 0
    elif [[ "$arch_output" == *"universal binary"* ]]; then
        echo "universal"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

# ============================================================================
# Homebrew Detection
# ============================================================================

detect_homebrew_installations() {
    local x86_brew="/usr/local/bin/brew"
    local arm_brew="/opt/homebrew/bin/brew"
    local installations=()
    
    if [[ -f "$x86_brew" ]]; then
        installations+=("x86:$x86_brew")
    fi
    
    if [[ -f "$arm_brew" ]]; then
        installations+=("arm:$arm_brew")
    fi
    
    printf '%s\n' "${installations[@]}"
    return 0
}

scan_homebrew_binaries() {
    local brew_prefix="$1"
    local x86_binaries=()
    
    if [[ ! -d "$brew_prefix/bin" ]]; then
        return 0
    fi
    
    print_info "Scanning binaries in $brew_prefix/bin..."
    
    # Scan all binaries in Homebrew bin directory
    while IFS= read -r binary; do
        local arch
        arch=$(get_binary_arch "$binary")
        
        if [[ "$arch" == "x86_64" ]]; then
            x86_binaries+=("$binary")
        fi
    done < <(find "$brew_prefix/bin" -type f -perm +111 2>/dev/null)
    
    printf '%s\n' "${x86_binaries[@]}"
    return 0
}

# ============================================================================
# Audit Commands
# ============================================================================

audit_system() {
    print_header "Rosetta Audit - Architecture Analysis"
    
    # Check if running on Apple Silicon
    if ! is_apple_silicon; then
        if is_intel_mac; then
            print_success "Running on Intel Mac - Rosetta audit not applicable"
        else
            print_success "Not running on macOS - Rosetta audit not applicable"
        fi
        return 0
    fi
    
    print_success "Detected Apple Silicon (arm64)"
    echo ""
    
    # Check Rosetta installation
    if check_rosetta_installed; then
        print_info "Rosetta 2 is installed"
    else
        print_warning "Rosetta 2 is not installed"
        print_info "Install with: softwareupdate --install-rosetta"
    fi
    echo ""
    
    # Detect Homebrew installations
    print_info "Detecting Homebrew installations..."
    local installations=()
    while IFS= read -r install; do
        installations+=("$install")
    done < <(detect_homebrew_installations)
    
    if [[ ${#installations[@]} -eq 0 ]]; then
        print_warning "No Homebrew installations found"
        return 0
    fi
    
    local has_x86_brew=false
    local has_arm_brew=false
    
    for install in "${installations[@]}"; do
        local type="${install%%:*}"
        local path="${install#*:}"
        
        if [[ "$type" == "x86" ]]; then
            has_x86_brew=true
            print_warning "Found x86 Homebrew: $path"
        elif [[ "$type" == "arm" ]]; then
            has_arm_brew=true
            print_success "Found ARM Homebrew: $path"
        fi
    done
    echo ""
    
    # Scan for x86 binaries if x86 Homebrew exists
    if [[ "$has_x86_brew" == "true" ]]; then
        local x86_prefix="/usr/local"
        print_warning "Scanning for x86 binaries in $x86_prefix..."
        
        local x86_binaries=()
        while IFS= read -r binary; do
            x86_binaries+=("$binary")
        done < <(scan_homebrew_binaries "$x86_prefix")
        
        if [[ ${#x86_binaries[@]} -gt 0 ]]; then
            print_error "Found ${#x86_binaries[@]} x86 binaries running under Rosetta:"
            
            # Show first 10 binaries
            local count=0
            for binary in "${x86_binaries[@]}"; do
                if [[ $count -lt 10 ]]; then
                    echo "  - $(basename "$binary")"
                    ((count++))
                fi
            done
            
            if [[ ${#x86_binaries[@]} -gt 10 ]]; then
                echo "  ... and $((${#x86_binaries[@]} - 10)) more"
            fi
            
            echo ""
            print_info "Migration recommended:"
            print_info "1. Install ARM Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            print_info "2. Reinstall packages with ARM Homebrew"
            print_info "3. Remove x86 Homebrew: sudo rm -rf /usr/local/Homebrew"
        else
            print_success "No x86 binaries found in $x86_prefix"
        fi
    fi
    
    # Recommendation
    echo ""
    if [[ "$has_x86_brew" == "true" ]] && [[ "$has_arm_brew" == "false" ]]; then
        print_warning "RECOMMENDATION: Migrate to ARM-native Homebrew for better performance"
    elif [[ "$has_x86_brew" == "true" ]] && [[ "$has_arm_brew" == "true" ]]; then
        print_warning "RECOMMENDATION: Both x86 and ARM Homebrew detected - consider removing x86 version"
    elif [[ "$has_arm_brew" == "true" ]]; then
        print_success "Using ARM-native Homebrew - optimal configuration"
    fi
    
    return 0
}

show_help() {
    cat << 'EOF'
Rosetta Audit Helper - Detect x86 binaries on Apple Silicon

USAGE:
    rosetta-audit-helper.sh [COMMAND]

COMMANDS:
    audit           Scan system for x86 binaries running under Rosetta
    check           Quick check for Rosetta and Homebrew architecture
    help            Show this help message

EXAMPLES:
    # Full system audit
    rosetta-audit-helper.sh audit
    
    # Quick architecture check
    rosetta-audit-helper.sh check

NOTES:
    - Only runs on Apple Silicon Macs (arm64)
    - Intel Macs skip gracefully with success message
    - Detects both x86 and ARM Homebrew installations
    - Recommends migration path for x86 binaries

EOF
    return 0
}

quick_check() {
    if ! is_apple_silicon; then
        if is_intel_mac; then
            print_success "Intel Mac - Rosetta audit not applicable"
        else
            print_success "Not macOS - Rosetta audit not applicable"
        fi
        return 0
    fi
    
    print_info "Apple Silicon detected"
    
    if check_rosetta_installed; then
        print_info "Rosetta 2: installed"
    else
        print_info "Rosetta 2: not installed"
    fi
    
    local installations=()
    while IFS= read -r install; do
        installations+=("$install")
    done < <(detect_homebrew_installations)
    
    for install in "${installations[@]}"; do
        local type="${install%%:*}"
        local path="${install#*:}"
        
        if [[ "$type" == "x86" ]]; then
            print_warning "Homebrew (x86): $path"
        elif [[ "$type" == "arm" ]]; then
            print_success "Homebrew (ARM): $path"
        fi
    done
    
    return 0
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    local command="${1:-audit}"
    
    case "$command" in
        audit)
            audit_system
            ;;
        check)
            quick_check
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
