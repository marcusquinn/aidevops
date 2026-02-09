#!/usr/bin/env bash
# shellcheck disable=SC2034

# SOPS Helper - Encrypted config file management with Mozilla SOPS
# Encrypts structured files (YAML, JSON, ENV, INI) in-place for git-safe storage.
# Supports age, GPG, AWS KMS, GCP KMS, Azure Key Vault backends.
#
# Usage:
#   sops-helper.sh init [--backend age|gpg]   # Initialize SOPS for current repo
#   sops-helper.sh encrypt <file>             # Encrypt a config file
#   sops-helper.sh decrypt <file>             # Decrypt a config file (to stdout)
#   sops-helper.sh edit <file>                # Edit encrypted file in-place
#   sops-helper.sh rotate <file>              # Rotate encryption keys
#   sops-helper.sh status [<file>]            # Show SOPS status
#   sops-helper.sh diff <file>                # Show decrypted diff for git
#   sops-helper.sh install                    # Install SOPS binary
#   sops-helper.sh help                       # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Paths
readonly SOPS_CONFIG=".sops.yaml"
readonly SOPS_AGE_KEY_DIR="$HOME/.config/sops/age"
readonly SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_DIR/keys.txt"

# Check if SOPS is installed
has_sops() {
    command -v sops &>/dev/null
    return $?
}

# Check if age is installed (preferred backend)
has_age() {
    command -v age &>/dev/null
    return $?
}

# Get the age public key from the key file
get_age_public_key() {
    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        return 1
    fi
    grep "^# public key:" "$SOPS_AGE_KEY_FILE" | head -1 | sed 's/^# public key: //'
    return 0
}

# Detect file type for SOPS
detect_file_type() {
    local file="$1"
    local ext="${file##*.}"

    case "$ext" in
        yaml|yml) echo "yaml" ;;
        json)     echo "json" ;;
        env)      echo "dotenv" ;;
        ini)      echo "ini" ;;
        *)        echo "binary" ;;
    esac
    return 0
}

# Check if a file is already SOPS-encrypted
is_encrypted() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # SOPS adds a "sops" metadata key to encrypted files
    if grep -q '"sops"' "$file" 2>/dev/null || grep -q "sops:" "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Commands ---

# Install SOPS
cmd_install() {
    if has_sops; then
        local version
        version=$(sops --version 2>/dev/null | head -1 || echo "unknown")
        print_info "SOPS already installed: $version"
        return 0
    fi

    print_info "Installing SOPS..."

    if command -v brew &>/dev/null; then
        brew install sops
    elif command -v apt-get &>/dev/null; then
        # Get latest release URL
        local arch
        arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        local latest_url="https://github.com/getsops/sops/releases/latest/download/sops_3.9.4_${arch}.deb"
        local tmp_deb
        tmp_deb=$(mktemp /tmp/sops-XXXXXX.deb)
        trap 'rm -f "${tmp_deb:-}"' RETURN
        curl -fsSL "$latest_url" -o "$tmp_deb"
        sudo dpkg -i "$tmp_deb"
        rm -f "$tmp_deb"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S sops
    else
        print_error "Cannot auto-install SOPS. Install manually: https://github.com/getsops/sops#install"
        return 1
    fi

    # Also install age if not present (preferred backend)
    if ! has_age; then
        print_info "Installing age (encryption backend)..."
        if command -v brew &>/dev/null; then
            brew install age
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y age
        elif command -v pacman &>/dev/null; then
            sudo pacman -S age
        fi
    fi

    print_success "SOPS installed successfully"
    return 0
}

# Initialize SOPS for current repository
cmd_init() {
    local backend="age"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend|-b) backend="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    case "$backend" in
        age)
            if ! has_age; then
                print_error "age not installed. Run: brew install age (macOS) or apt install age (Linux)"
                return 1
            fi

            # Generate age key if not exists
            if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
                print_info "Generating age key pair..."
                mkdir -p "$SOPS_AGE_KEY_DIR"
                chmod 700 "$SOPS_AGE_KEY_DIR"
                age-keygen -o "$SOPS_AGE_KEY_FILE" 2>&1
                chmod 600 "$SOPS_AGE_KEY_FILE"
                print_success "Age key generated at $SOPS_AGE_KEY_FILE"
            fi

            local pub_key
            pub_key=$(get_age_public_key)
            if [[ -z "$pub_key" ]]; then
                print_error "Could not read age public key"
                return 1
            fi

            # Create .sops.yaml config
            if [[ ! -f "$SOPS_CONFIG" ]]; then
                cat > "$SOPS_CONFIG" << EOF
# SOPS configuration for this repository
# See: https://github.com/getsops/sops#using-sopsyaml-conf-to-select-kms-pgp-and-age-for-new-files
creation_rules:
  # Encrypt all files matching these patterns with age
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    age: >-
      ${pub_key}
  # Encrypt secrets directories
  - path_regex: secrets/.*\.(yaml|yml|json|env|ini)$
    age: >-
      ${pub_key}
EOF
                print_success "Created $SOPS_CONFIG with age backend"
                print_info "Public key: $pub_key"
            else
                print_warning "$SOPS_CONFIG already exists"
            fi
            ;;

        gpg)
            # Use existing GPG key
            local gpg_fingerprint
            gpg_fingerprint=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

            if [[ -z "$gpg_fingerprint" ]]; then
                print_error "No GPG secret key found. Generate one: gpg --full-generate-key"
                return 1
            fi

            if [[ ! -f "$SOPS_CONFIG" ]]; then
                cat > "$SOPS_CONFIG" << EOF
# SOPS configuration for this repository
creation_rules:
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    pgp: >-
      ${gpg_fingerprint}
  - path_regex: secrets/.*\.(yaml|yml|json|env|ini)$
    pgp: >-
      ${gpg_fingerprint}
EOF
                print_success "Created $SOPS_CONFIG with GPG backend"
                print_info "GPG fingerprint: $gpg_fingerprint"
            else
                print_warning "$SOPS_CONFIG already exists"
            fi
            ;;

        *)
            print_error "Unknown backend: $backend. Use 'age' or 'gpg'"
            return 1
            ;;
    esac

    # Set up git diff driver for SOPS files
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local gitattributes=".gitattributes"
        local sops_diff_line="*.enc.* diff=sopsdiffer"

        if [[ ! -f "$gitattributes" ]] || ! grep -q "sopsdiffer" "$gitattributes" 2>/dev/null; then
            echo "$sops_diff_line" >> "$gitattributes"
            git config diff.sopsdiffer.textconv "sops decrypt"
            print_info "Configured git diff driver for SOPS files"
        fi
    fi

    print_success "SOPS initialized for this repository"
    return 0
}

# Encrypt a file
cmd_encrypt() {
    local file="$1"

    if [[ -z "$file" ]]; then
        print_error "Usage: sops-helper.sh encrypt <file>"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    if is_encrypted "$file"; then
        print_warning "File is already encrypted: $file"
        return 0
    fi

    # Encrypt in-place
    sops encrypt -i "$file"
    print_success "Encrypted: $file"
    return 0
}

# Decrypt a file (to stdout by default, or in-place with --in-place)
cmd_decrypt() {
    local file=""
    local in_place=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --in-place|-i) in_place=true; shift ;;
            *) file="$1"; shift ;;
        esac
    done

    if [[ -z "$file" ]]; then
        print_error "Usage: sops-helper.sh decrypt <file> [--in-place]"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    if ! is_encrypted "$file"; then
        print_warning "File does not appear to be SOPS-encrypted: $file"
        return 1
    fi

    if [[ "$in_place" == "true" ]]; then
        sops decrypt -i "$file"
        print_success "Decrypted in-place: $file"
    else
        sops decrypt "$file"
    fi

    return 0
}

# Edit an encrypted file (decrypts, opens editor, re-encrypts)
cmd_edit() {
    local file="$1"

    if [[ -z "$file" ]]; then
        print_error "Usage: sops-helper.sh edit <file>"
        return 1
    fi

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    sops "$file"
    return $?
}

# Rotate encryption keys
cmd_rotate() {
    local file="$1"

    if [[ -z "$file" ]]; then
        print_error "Usage: sops-helper.sh rotate <file>"
        return 1
    fi

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    sops rotate -i "$file"
    print_success "Rotated keys for: $file"
    return 0
}

# Show decrypted diff (for git integration)
cmd_diff() {
    local file="$1"

    if [[ -z "$file" ]]; then
        print_error "Usage: sops-helper.sh diff <file>"
        return 1
    fi

    if ! has_sops; then
        print_error "SOPS not installed. Run: sops-helper.sh install"
        return 1
    fi

    sops decrypt "$file" 2>/dev/null
    return $?
}

# Show SOPS status
cmd_status() {
    local file="${1:-}"

    echo ""
    print_info "SOPS Encryption Status"
    echo "======================="
    echo ""

    # SOPS binary
    if has_sops; then
        local version
        version=$(sops --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "  SOPS:         ${GREEN}installed${NC} ($version)"
    else
        echo -e "  SOPS:         ${YELLOW}not installed${NC}"
        echo -e "                Run: sops-helper.sh install"
    fi

    # age backend
    if has_age; then
        local age_version
        age_version=$(age --version 2>/dev/null || echo "unknown")
        echo -e "  age:          ${GREEN}installed${NC} ($age_version)"

        if [[ -f "$SOPS_AGE_KEY_FILE" ]]; then
            local pub_key
            pub_key=$(get_age_public_key)
            echo -e "  age key:      ${GREEN}configured${NC}"
            echo -e "                ${DIM}$pub_key${NC}"
        else
            echo -e "  age key:      ${YELLOW}not generated${NC}"
            echo -e "                Run: sops-helper.sh init"
        fi
    else
        echo -e "  age:          ${DIM}not installed${NC}"
    fi

    # GPG backend
    if command -v gpg &>/dev/null; then
        local gpg_keys
        gpg_keys=$(gpg --list-secret-keys 2>/dev/null | grep -c "^sec" || echo "0")
        echo -e "  GPG:          ${GREEN}installed${NC} ($gpg_keys secret key(s))"
    else
        echo -e "  GPG:          ${DIM}not installed${NC}"
    fi

    # .sops.yaml config
    if [[ -f "$SOPS_CONFIG" ]]; then
        echo -e "  Config:       ${GREEN}$SOPS_CONFIG${NC}"
    else
        echo -e "  Config:       ${YELLOW}no .sops.yaml${NC}"
    fi

    # Check specific file if provided
    if [[ -n "$file" ]]; then
        echo ""
        if [[ -f "$file" ]]; then
            if is_encrypted "$file"; then
                echo -e "  $file: ${GREEN}encrypted${NC}"
                local file_type
                file_type=$(detect_file_type "$file")
                echo -e "  Type: $file_type"
            else
                echo -e "  $file: ${YELLOW}not encrypted${NC}"
            fi
        else
            echo -e "  $file: ${RED}not found${NC}"
        fi
    fi

    # List encrypted files in repo
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo ""
        local enc_files
        enc_files=$(git ls-files '*.enc.*' 2>/dev/null || true)
        local secrets_files
        secrets_files=$(git ls-files 'secrets/*' 2>/dev/null || true)

        local all_enc="${enc_files}${secrets_files:+$'\n'$secrets_files}"
        all_enc=$(echo "$all_enc" | sort -u | grep -v '^$' || true)

        if [[ -n "$all_enc" ]]; then
            print_info "Encrypted files in repo:"
            echo ""
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if is_encrypted "$f"; then
                    echo -e "  ${GREEN}*${NC} $f"
                else
                    echo -e "  ${YELLOW}?${NC} $f (not SOPS-encrypted)"
                fi
            done <<< "$all_enc"
        else
            echo -e "  ${DIM}No encrypted files found${NC}"
        fi
    fi

    echo ""
    return 0
}

# Show help
cmd_help() {
    echo ""
    print_info "AI DevOps - SOPS Encrypted Config Management"
    echo ""
    echo "  Encrypt structured config files (YAML, JSON, ENV, INI) for safe git storage."
    echo "  Uses Mozilla SOPS with age (preferred) or GPG backends."
    echo ""
    print_info "Commands:"
    echo ""
    echo "  install                           Install SOPS and age"
    echo "  init [--backend age|gpg]          Initialize SOPS for current repo"
    echo "  encrypt <file>                    Encrypt a config file in-place"
    echo "  decrypt <file> [--in-place]       Decrypt (stdout or in-place)"
    echo "  edit <file>                       Edit encrypted file (decrypt/edit/re-encrypt)"
    echo "  rotate <file>                     Rotate encryption keys"
    echo "  diff <file>                       Show decrypted content (for git diff)"
    echo "  status [<file>]                   Show SOPS status and encrypted files"
    echo ""
    print_info "File naming convention:"
    echo ""
    echo "  config.enc.yaml                   Encrypted YAML config"
    echo "  secrets/database.enc.json         Encrypted JSON in secrets dir"
    echo "  .env.enc.env                      Encrypted dotenv file"
    echo ""
    print_info "Examples:"
    echo ""
    echo "  # Initialize SOPS with age backend (recommended)"
    echo "  sops-helper.sh init"
    echo ""
    echo "  # Encrypt a config file"
    echo "  sops-helper.sh encrypt config.enc.yaml"
    echo ""
    echo "  # View decrypted content (never stored on disk)"
    echo "  sops-helper.sh decrypt config.enc.yaml"
    echo ""
    echo "  # Edit encrypted file (opens \$EDITOR)"
    echo "  sops-helper.sh edit config.enc.yaml"
    echo ""
    print_info "Integration with aidevops:"
    echo ""
    echo "  - gopass: Individual secrets (API keys, tokens)"
    echo "  - SOPS:  Structured config files (committed to git, encrypted)"
    echo "  - gocryptfs: Encrypted directories (workspace protection)"
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
        encrypt|enc)
            cmd_encrypt "$@"
            ;;
        decrypt|dec)
            cmd_decrypt "$@"
            ;;
        edit)
            cmd_edit "$@"
            ;;
        rotate)
            cmd_rotate "$@"
            ;;
        diff)
            cmd_diff "$@"
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
