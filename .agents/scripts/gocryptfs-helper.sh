#!/usr/bin/env bash
# shellcheck disable=SC2034

# gocryptfs Helper - Encrypted filesystem overlay for directory-level encryption
# Creates encrypted directories that mount as transparent FUSE filesystems.
# Protects sensitive workspace data, config directories, and project secrets at rest.
#
# Usage:
#   gocryptfs-helper.sh init <cipher-dir>          # Initialize encrypted directory
#   gocryptfs-helper.sh mount <cipher-dir> [mount]  # Mount encrypted directory
#   gocryptfs-helper.sh unmount <mount-point>        # Unmount encrypted directory
#   gocryptfs-helper.sh status                       # Show mount status
#   gocryptfs-helper.sh create <name>                # Create named vault in workspace
#   gocryptfs-helper.sh open <name>                  # Mount named vault
#   gocryptfs-helper.sh close <name>                 # Unmount named vault
#   gocryptfs-helper.sh list                         # List workspace vaults
#   gocryptfs-helper.sh install                      # Install gocryptfs
#   gocryptfs-helper.sh help                         # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Paths
readonly VAULT_BASE_DIR="$HOME/.aidevops/.agent-workspace/vaults"
readonly VAULT_MOUNT_DIR="$HOME/.aidevops/.agent-workspace/mounts"
readonly VAULT_REGISTRY="$HOME/.aidevops/.agent-workspace/vault-registry.json"

# Check if gocryptfs is installed
has_gocryptfs() {
    command -v gocryptfs &>/dev/null
    return $?
}

# Check if FUSE is available
has_fuse() {
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: check for macFUSE
        if [[ -d "/Library/Filesystems/macfuse.fs" ]] || command -v mount_macfuse &>/dev/null; then
            return 0
        fi
        return 1
    else
        # Linux: check for fusermount
        command -v fusermount &>/dev/null || command -v fusermount3 &>/dev/null
        return $?
    fi
}

# Get the fusermount command (Linux: fusermount or fusermount3)
get_fusermount() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "umount"
    elif command -v fusermount3 &>/dev/null; then
        echo "fusermount3 -u"
    elif command -v fusermount &>/dev/null; then
        echo "fusermount -u"
    else
        echo "umount"
    fi
    return 0
}

# Check if a directory is a gocryptfs cipher directory
is_cipher_dir() {
    local dir="$1"
    [[ -f "$dir/gocryptfs.conf" ]]
    return $?
}

# Check if a mount point is currently mounted
is_mounted() {
    local mount_point="$1"
    mount | grep -q " on ${mount_point} " 2>/dev/null
    return $?
}

# Derive default mount point from cipher directory
default_mount_point() {
    local cipher_dir="$1"
    local base
    base=$(basename "$cipher_dir")
    echo "${cipher_dir%/*}/${base}.mnt"
    return 0
}

# --- Commands ---

# Install gocryptfs
cmd_install() {
    if has_gocryptfs; then
        local version
        version=$(gocryptfs --version 2>/dev/null | head -1 || echo "unknown")
        print_info "gocryptfs already installed: $version"
    else
        print_info "Installing gocryptfs..."

        if command -v brew &>/dev/null; then
            brew install gocryptfs
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y gocryptfs
        elif command -v pacman &>/dev/null; then
            sudo pacman -S gocryptfs
        else
            print_error "Cannot auto-install gocryptfs. Install manually: https://github.com/rfjakob/gocryptfs#install"
            return 1
        fi

        print_success "gocryptfs installed"
    fi

    # Check FUSE
    if ! has_fuse; then
        print_warning "FUSE not detected"
        if [[ "$(uname)" == "Darwin" ]]; then
            print_info "Install macFUSE: brew install --cask macfuse"
            print_info "Or download from: https://osxfuse.github.io/"
        else
            print_info "Install FUSE: sudo apt-get install fuse3 (Debian/Ubuntu)"
        fi
        return 1
    fi

    print_success "FUSE available"
    return 0
}

# Initialize a new encrypted directory
cmd_init() {
    local cipher_dir="$1"

    if [[ -z "$cipher_dir" ]]; then
        print_error "Usage: gocryptfs-helper.sh init <cipher-directory>"
        return 1
    fi

    if ! has_gocryptfs; then
        print_error "gocryptfs not installed. Run: gocryptfs-helper.sh install"
        return 1
    fi

    if is_cipher_dir "$cipher_dir"; then
        print_warning "Directory already initialized: $cipher_dir"
        return 0
    fi

    mkdir -p "$cipher_dir"

    # Initialize with AES-256-GCM (default, hardware-accelerated)
    gocryptfs -init "$cipher_dir"

    print_success "Initialized encrypted directory: $cipher_dir"
    print_info "Mount with: gocryptfs-helper.sh mount $cipher_dir"
    return 0
}

# Mount an encrypted directory
cmd_mount() {
    local cipher_dir="$1"
    local mount_point="${2:-}"

    if [[ -z "$cipher_dir" ]]; then
        print_error "Usage: gocryptfs-helper.sh mount <cipher-dir> [mount-point]"
        return 1
    fi

    if ! has_gocryptfs; then
        print_error "gocryptfs not installed. Run: gocryptfs-helper.sh install"
        return 1
    fi

    if ! has_fuse; then
        print_error "FUSE not available. Install macFUSE (macOS) or fuse3 (Linux)"
        return 1
    fi

    if ! is_cipher_dir "$cipher_dir"; then
        print_error "Not a gocryptfs directory: $cipher_dir"
        print_info "Initialize first: gocryptfs-helper.sh init $cipher_dir"
        return 1
    fi

    # Default mount point
    if [[ -z "$mount_point" ]]; then
        mount_point=$(default_mount_point "$cipher_dir")
    fi

    if is_mounted "$mount_point"; then
        print_warning "Already mounted: $mount_point"
        return 0
    fi

    mkdir -p "$mount_point"

    # Mount (will prompt for password)
    gocryptfs "$cipher_dir" "$mount_point"

    print_success "Mounted: $cipher_dir -> $mount_point"
    return 0
}

# Unmount an encrypted directory
cmd_unmount() {
    local mount_point="$1"

    if [[ -z "$mount_point" ]]; then
        print_error "Usage: gocryptfs-helper.sh unmount <mount-point>"
        return 1
    fi

    if ! is_mounted "$mount_point"; then
        print_warning "Not mounted: $mount_point"
        return 0
    fi

    local fusermount_cmd
    fusermount_cmd=$(get_fusermount)

    # Unmount
    $fusermount_cmd "$mount_point"

    print_success "Unmounted: $mount_point"
    return 0
}

# Create a named vault in the workspace
cmd_create() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Usage: gocryptfs-helper.sh create <vault-name>"
        return 1
    fi

    # Validate name
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        print_error "Invalid vault name: '$name'. Use alphanumeric, hyphens, underscores."
        return 1
    fi

    if ! has_gocryptfs; then
        print_error "gocryptfs not installed. Run: gocryptfs-helper.sh install"
        return 1
    fi

    local cipher_dir="$VAULT_BASE_DIR/$name"

    if is_cipher_dir "$cipher_dir"; then
        print_warning "Vault already exists: $name"
        return 0
    fi

    mkdir -p "$VAULT_BASE_DIR" "$VAULT_MOUNT_DIR"

    # Initialize the vault
    mkdir -p "$cipher_dir"
    gocryptfs -init "$cipher_dir"

    print_success "Created vault: $name"
    print_info "Cipher dir: $cipher_dir"
    print_info "Mount with: gocryptfs-helper.sh open $name"
    return 0
}

# Open (mount) a named vault
cmd_open() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Usage: gocryptfs-helper.sh open <vault-name>"
        return 1
    fi

    local cipher_dir="$VAULT_BASE_DIR/$name"
    local mount_dir="$VAULT_MOUNT_DIR/$name"

    if ! is_cipher_dir "$cipher_dir"; then
        print_error "Vault not found: $name"
        print_info "Create with: gocryptfs-helper.sh create $name"
        return 1
    fi

    if is_mounted "$mount_dir"; then
        print_warning "Vault already open: $name"
        print_info "Mount point: $mount_dir"
        return 0
    fi

    mkdir -p "$mount_dir"
    cmd_mount "$cipher_dir" "$mount_dir"
    return $?
}

# Close (unmount) a named vault
cmd_close() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Usage: gocryptfs-helper.sh close <vault-name>"
        return 1
    fi

    local mount_dir="$VAULT_MOUNT_DIR/$name"

    cmd_unmount "$mount_dir"
    return $?
}

# List workspace vaults
cmd_list() {
    echo ""
    print_info "Workspace Vaults"
    echo "================="
    echo ""

    if [[ ! -d "$VAULT_BASE_DIR" ]]; then
        echo -e "  ${DIM}No vaults configured${NC}"
        echo ""
        print_info "Create a vault: gocryptfs-helper.sh create <name>"
        echo ""
        return 0
    fi

    local found=false
    for vault_dir in "$VAULT_BASE_DIR"/*/; do
        [[ -d "$vault_dir" ]] || continue
        local vault_name
        vault_name=$(basename "$vault_dir")
        local mount_dir="$VAULT_MOUNT_DIR/$vault_name"

        if ! is_cipher_dir "$vault_dir"; then
            continue
        fi

        found=true
        local status_icon status_text
        if is_mounted "$mount_dir"; then
            status_icon="${GREEN}*${NC}"
            status_text="${GREEN}mounted${NC}"
        else
            status_icon="${YELLOW}-${NC}"
            status_text="${YELLOW}locked${NC}"
        fi

        echo -e "  ${status_icon} ${BLUE}$vault_name${NC} ($status_text)"
        echo -e "    ${DIM}cipher: $vault_dir${NC}"
        if is_mounted "$mount_dir"; then
            echo -e "    ${DIM}mount:  $mount_dir${NC}"
        fi
    done

    if [[ "$found" == "false" ]]; then
        echo -e "  ${DIM}No vaults found${NC}"
    fi

    echo ""
    return 0
}

# Show overall status
cmd_status() {
    echo ""
    print_info "gocryptfs Encryption Status"
    echo "============================"
    echo ""

    # gocryptfs binary
    if has_gocryptfs; then
        local version
        version=$(gocryptfs --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "  gocryptfs:    ${GREEN}installed${NC} ($version)"
    else
        echo -e "  gocryptfs:    ${YELLOW}not installed${NC}"
        echo -e "                Run: gocryptfs-helper.sh install"
    fi

    # FUSE status
    if has_fuse; then
        echo -e "  FUSE:         ${GREEN}available${NC}"
    else
        echo -e "  FUSE:         ${RED}not available${NC}"
        if [[ "$(uname)" == "Darwin" ]]; then
            echo -e "                Install: brew install --cask macfuse"
        else
            echo -e "                Install: sudo apt-get install fuse3"
        fi
    fi

    # Active mounts
    local active_mounts
    active_mounts=$(mount 2>/dev/null | grep -c "gocryptfs" || true)
    echo -e "  Active mounts: $active_mounts"

    # Workspace vaults
    local vault_count=0
    if [[ -d "$VAULT_BASE_DIR" ]]; then
        for vault_dir in "$VAULT_BASE_DIR"/*/; do
            [[ -d "$vault_dir" ]] || continue
            is_cipher_dir "$vault_dir" && vault_count=$((vault_count + 1))
        done
    fi
    echo -e "  Vaults:       $vault_count"

    echo ""

    # List vaults if any exist
    if [[ $vault_count -gt 0 ]]; then
        cmd_list
    fi

    return 0
}

# Show help
cmd_help() {
    echo ""
    print_info "AI DevOps - gocryptfs Encrypted Filesystem"
    echo ""
    echo "  Create encrypted directories with transparent FUSE filesystem overlay."
    echo "  Protects sensitive workspace data, configs, and project secrets at rest."
    echo ""
    print_info "Low-level commands:"
    echo ""
    echo "  install                           Install gocryptfs and FUSE"
    echo "  init <cipher-dir>                 Initialize encrypted directory"
    echo "  mount <cipher-dir> [mount-point]  Mount encrypted directory"
    echo "  unmount <mount-point>             Unmount encrypted directory"
    echo "  status                            Show gocryptfs status"
    echo ""
    print_info "Workspace vault commands:"
    echo ""
    echo "  create <name>                     Create named vault in workspace"
    echo "  open <name>                       Mount (unlock) a vault"
    echo "  close <name>                      Unmount (lock) a vault"
    echo "  list                              List workspace vaults"
    echo ""
    print_info "Examples:"
    echo ""
    echo "  # Create a vault for sensitive project data"
    echo "  gocryptfs-helper.sh create project-secrets"
    echo ""
    echo "  # Open the vault (prompts for password)"
    echo "  gocryptfs-helper.sh open project-secrets"
    echo ""
    echo "  # Files in ~/.aidevops/.agent-workspace/mounts/project-secrets/"
    echo "  # are transparently encrypted at rest"
    echo ""
    echo "  # Close the vault when done"
    echo "  gocryptfs-helper.sh close project-secrets"
    echo ""
    echo "  # Encrypt an arbitrary directory"
    echo "  gocryptfs-helper.sh init /path/to/encrypted"
    echo "  gocryptfs-helper.sh mount /path/to/encrypted /path/to/mount"
    echo ""
    print_info "Integration with aidevops:"
    echo ""
    echo "  - gopass:    Individual secrets (API keys, tokens)"
    echo "  - SOPS:     Structured config files (committed to git, encrypted)"
    echo "  - gocryptfs: Encrypted directories (workspace protection at rest)"
    echo ""
    return 0
}

# Main dispatch
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        install)
            cmd_install "$@"
            ;;
        init)
            cmd_init "$@"
            ;;
        mount)
            cmd_mount "$@"
            ;;
        unmount|umount)
            cmd_unmount "$@"
            ;;
        create)
            cmd_create "$@"
            ;;
        open)
            cmd_open "$@"
            ;;
        close)
            cmd_close "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            cmd_help
            return 1
            ;;
    esac

    return 0
}

main "$@"
