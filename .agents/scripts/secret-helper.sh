#!/usr/bin/env bash
# shellcheck disable=SC2034

# Secret Helper - AI-native secret management with gopass backend
# Keeps secret values out of AI agent context windows via subprocess
# injection and output redaction.
#
# Usage:
#   secret-helper.sh set NAME              # Interactive hidden input -> gopass
#   secret-helper.sh list                  # List secret names (never values)
#   secret-helper.sh run CMD [ARGS...]     # Inject all secrets, redact output
#   secret-helper.sh NAME [NAME...] -- CMD # Inject specific secrets, redact output
#   secret-helper.sh init                  # Initialize gopass store
#   secret-helper.sh import-credentials    # Migrate from credentials.sh to gopass
#   secret-helper.sh status                # Show backend status
#   secret-helper.sh help                  # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Paths
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"
readonly GOPASS_PREFIX="aidevops"

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK] $msg${NC}"
    return 0
}

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO] $msg${NC}"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN] $msg${NC}"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR] $msg${NC}" >&2
    return 0
}

# Check if gopass is available and initialized
has_gopass() {
    if ! command -v gopass &>/dev/null; then
        return 1
    fi
    # Check if gopass store is initialized
    if ! gopass ls &>/dev/null; then
        return 1
    fi
    return 0
}

# Get a secret value from gopass (NEVER print to stdout in agent context)
# This function is only used internally for subprocess injection
get_secret_value() {
    local name="$1"
    if has_gopass; then
        gopass show -o "${GOPASS_PREFIX}/${name}" 2>/dev/null
    else
        # Fallback to credentials.sh
        if [[ -f "$CREDENTIALS_FILE" ]]; then
            local value
            value=$(grep "^export ${name}=" "$CREDENTIALS_FILE" 2>/dev/null | head -1 | sed 's/^export [^=]*=//' | sed 's/^"//' | sed 's/"$//')
            echo "$value"
        fi
    fi
    return 0
}

# Collect all secret values for redaction
collect_secret_values() {
    local -a values=()

    if has_gopass; then
        local secrets
        secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
        while IFS= read -r secret_path; do
            [[ -z "$secret_path" ]] && continue
            local val
            val=$(gopass show -o "$secret_path" 2>/dev/null || true)
            if [[ -n "$val" && ${#val} -ge 4 ]]; then
                values+=("$val")
            fi
        done <<< "$secrets"
    fi

    # Also collect from credentials.sh as fallback
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^export[[:space:]]+[A-Z_][A-Z0-9_]*= ]]; then
                local val="${line#*=}"
                val="${val#\"}"
                val="${val%\"}"
                val="${val#\'}"
                val="${val%\'}"
                if [[ -n "$val" && ${#val} -ge 4 ]]; then
                    values+=("$val")
                fi
            fi
        done < "$CREDENTIALS_FILE"
    fi

    # Output values one per line for the redaction filter
    printf '%s\n' "${values[@]}"
    return 0
}

# Redact secret values from a stream
# Reads stdin, replaces any secret value with [REDACTED]
redact_stream() {
    local -a secret_values=()

    # Read secret values into array
    while IFS= read -r val; do
        [[ -n "$val" ]] && secret_values+=("$val")
    done < <(collect_secret_values)

    if [[ ${#secret_values[@]} -eq 0 ]]; then
        # No secrets to redact, pass through
        cat
        return 0
    fi

    # Build sed script for redaction
    # Sort by length descending to redact longer values first
    local sed_script=""
    local sorted_values
    sorted_values=$(printf '%s\n' "${secret_values[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

    while IFS= read -r val; do
        [[ -z "$val" ]] && continue
        # Escape special sed characters in the value
        local escaped
        escaped=$(printf '%s' "$val" | sed 's/[&/\]/\\&/g; s/\[/\\[/g; s/\]/\\]/g')
        sed_script="${sed_script}s|${escaped}|[REDACTED]|g;"
    done <<< "$sorted_values"

    if [[ -n "$sed_script" ]]; then
        sed "$sed_script"
    else
        cat
    fi

    return 0
}

# Build environment from gopass secrets
build_secret_env() {
    local -a specific_names=("$@")
    local env_vars=""

    if has_gopass; then
        if [[ ${#specific_names[@]} -gt 0 ]]; then
            # Inject only specific secrets
            for name in "${specific_names[@]}"; do
                local val
                val=$(gopass show -o "${GOPASS_PREFIX}/${name}" 2>/dev/null || true)
                if [[ -n "$val" ]]; then
                    env_vars="${env_vars}${name}=${val}\n"
                fi
            done
        else
            # Inject all secrets
            local secrets
            secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
            while IFS= read -r secret_path; do
                [[ -z "$secret_path" ]] && continue
                local name="${secret_path#"${GOPASS_PREFIX}"/}"
                local val
                val=$(gopass show -o "$secret_path" 2>/dev/null || true)
                if [[ -n "$val" ]]; then
                    env_vars="${env_vars}${name}=${val}\n"
                fi
            done <<< "$secrets"
        fi
    fi

    # Also load from credentials.sh as fallback/supplement
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
                local name="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                val="${val#\"}"
                val="${val%\"}"
                # Only add if not already set by gopass
                if ! printf '%b' "$env_vars" | grep -q "^${name}="; then
                    env_vars="${env_vars}${name}=${val}\n"
                fi
            fi
        done < "$CREDENTIALS_FILE"
    fi

    printf '%b' "$env_vars"
    return 0
}

# --- Commands ---

# Initialize gopass store for aidevops
cmd_init() {
    if ! command -v gopass &>/dev/null; then
        print_info "gopass not found. Installing..."
        if command -v brew &>/dev/null; then
            brew install gopass
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y gopass
        elif command -v pacman &>/dev/null; then
            sudo pacman -S gopass
        else
            print_error "Cannot auto-install gopass. Install manually: https://github.com/gopasspw/gopass#installation"
            return 1
        fi
    fi

    if ! gopass ls &>/dev/null; then
        print_info "Initializing gopass store..."
        gopass setup
    fi

    # Create aidevops subfolder if it doesn't exist
    if ! gopass ls "${GOPASS_PREFIX}/" &>/dev/null; then
        print_info "Creating ${GOPASS_PREFIX}/ prefix in gopass store"
        # gopass creates folders implicitly when secrets are added
    fi

    print_success "gopass initialized for aidevops"
    print_info "Store secrets: aidevops secret set SECRET_NAME"
    print_info "Import existing: aidevops secret import-credentials"
    return 0
}

# Set a secret (interactive hidden input)
cmd_set() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Usage: aidevops secret set SECRET_NAME"
        return 1
    fi

    # Normalize to uppercase
    name=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')

    if has_gopass; then
        print_info "Enter value for $name (input hidden):"
        gopass insert "${GOPASS_PREFIX}/${name}"
        print_success "Stored $name in gopass"
    else
        print_warning "gopass not available, falling back to credentials.sh"
        print_info "Enter value for $name (input hidden):"
        local value
        read -rs value
        echo ""

        mkdir -p "$CONFIG_DIR"
        if [[ -f "$CREDENTIALS_FILE" ]] && grep -q "^export ${name}=" "$CREDENTIALS_FILE" 2>/dev/null; then
            local tmp_file="${CREDENTIALS_FILE}.tmp"
            grep -v "^export ${name}=" "$CREDENTIALS_FILE" > "$tmp_file"
            echo "export ${name}=\"${value}\"" >> "$tmp_file"
            mv "$tmp_file" "$CREDENTIALS_FILE"
        else
            echo "export ${name}=\"${value}\"" >> "$CREDENTIALS_FILE"
        fi
        chmod 600 "$CREDENTIALS_FILE"
        print_success "Stored $name in credentials.sh"
        print_info "Recommend: aidevops secret init (to enable encrypted storage)"
    fi

    return 0
}

# List secret names (NEVER values)
cmd_list() {
    local has_secrets=false

    if has_gopass; then
        local secrets
        secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
        if [[ -n "$secrets" ]]; then
            print_info "Secrets in gopass (${GOPASS_PREFIX}/):"
            echo ""
            while IFS= read -r secret_path; do
                [[ -z "$secret_path" ]] && continue
                local name="${secret_path#"${GOPASS_PREFIX}"/}"
                echo "  $name"
                has_secrets=true
            done <<< "$secrets"
            echo ""
        fi
    fi

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        local cred_keys
        cred_keys=$(grep "^export " "$CREDENTIALS_FILE" 2>/dev/null | sed 's/=.*//' | sed 's/export //' | sort || true)
        if [[ -n "$cred_keys" ]]; then
            print_info "Secrets in credentials.sh:"
            echo ""
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                echo "  $key"
                has_secrets=true
            done <<< "$cred_keys"
            echo ""
        fi
    fi

    if [[ "$has_secrets" == "false" ]]; then
        print_info "No secrets configured"
        print_info "Add secrets: aidevops secret set SECRET_NAME"
    fi

    return 0
}

# Run a command with secrets injected and output redacted
cmd_run() {
    local -a cmd_args=("$@")

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        print_error "Usage: aidevops secret run COMMAND [ARGS...]"
        return 1
    fi

    # Build environment
    local env_file
    env_file=$(mktemp)
    build_secret_env > "$env_file"

    # Execute command with secrets in environment, redact output
    local exit_code=0
    (
        # Load secrets into subprocess environment
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            export "$key=$val"
        done < "$env_file"

        # Execute the command
        "${cmd_args[@]}"
    ) 2>&1 | redact_stream || exit_code=$?

    # Clean up
    rm -f "$env_file"

    return "$exit_code"
}

# Run with specific secrets: secret NAME1 NAME2 -- command args
cmd_run_specific() {
    local -a secret_names=()
    local -a cmd_args=()
    local found_separator=false

    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            found_separator=true
            continue
        fi
        if [[ "$found_separator" == "true" ]]; then
            cmd_args+=("$arg")
        else
            secret_names+=("$arg")
        fi
    done

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        print_error "Usage: aidevops secret NAME [NAME...] -- COMMAND [ARGS...]"
        return 1
    fi

    # Build environment with specific secrets only
    local env_file
    env_file=$(mktemp)
    build_secret_env "${secret_names[@]}" > "$env_file"

    # Execute command with secrets in environment, redact output
    local exit_code=0
    (
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            export "$key=$val"
        done < "$env_file"

        "${cmd_args[@]}"
    ) 2>&1 | redact_stream || exit_code=$?

    rm -f "$env_file"

    return "$exit_code"
}

# Import credentials from credentials.sh to gopass
cmd_import_credentials() {
    if ! has_gopass; then
        print_error "gopass not initialized. Run: aidevops secret init"
        return 1
    fi

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        print_info "No credentials.sh found to import"
        return 0
    fi

    local imported=0
    local skipped=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
            local name="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"

            # Skip empty/placeholder values
            if [[ -z "$val" || "$val" == "YOUR_"* || "$val" == "CHANGE_ME"* ]]; then
                ((skipped++))
                continue
            fi

            # Check if already in gopass
            if gopass show -o "${GOPASS_PREFIX}/${name}" &>/dev/null; then
                print_info "Skipping $name (already in gopass)"
                ((skipped++))
                continue
            fi

            # Import to gopass
            echo "$val" | gopass insert --force "${GOPASS_PREFIX}/${name}"
            ((imported++))
            print_success "Imported $name"
        fi
    done < "$CREDENTIALS_FILE"

    print_success "Imported $imported secret(s), skipped $skipped"

    if [[ $imported -gt 0 ]]; then
        print_info "Verify with: aidevops secret list"
        print_info "You can now remove plaintext values from credentials.sh"
    fi

    return 0
}

# Show backend status
cmd_status() {
    echo ""
    print_info "Secret Management Status"
    echo "========================="
    echo ""

    # gopass status
    if command -v gopass &>/dev/null; then
        local gopass_version
        gopass_version=$(gopass version 2>/dev/null | head -1 || echo "unknown")
        echo -e "  gopass:       ${GREEN}installed${NC} ($gopass_version)"

        if gopass ls &>/dev/null; then
            local secret_count
            secret_count=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  gopass store: ${GREEN}initialized${NC} ($secret_count secrets in ${GOPASS_PREFIX}/)"
        else
            echo -e "  gopass store: ${YELLOW}not initialized${NC}"
            echo -e "                Run: aidevops secret init"
        fi
    else
        echo -e "  gopass:       ${YELLOW}not installed${NC}"
        echo -e "                Install: brew install gopass"
    fi

    # GPG status
    if command -v gpg &>/dev/null; then
        local gpg_keys
        gpg_keys=$(gpg --list-secret-keys 2>/dev/null | grep -c "^sec" || echo "0")
        echo -e "  GPG:          ${GREEN}installed${NC} ($gpg_keys secret key(s))"
    else
        echo -e "  GPG:          ${YELLOW}not installed${NC}"
    fi

    # credentials.sh status
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        local key_count
        key_count=$(grep -c "^export " "$CREDENTIALS_FILE" 2>/dev/null || echo "0")
        echo -e "  credentials:  ${GREEN}$key_count key(s)${NC} in $CREDENTIALS_FILE"
    else
        echo -e "  credentials:  ${DIM}no file${NC}"
    fi

    echo ""
    return 0
}

# Show help
cmd_help() {
    echo ""
    print_info "AI DevOps - Secret Management"
    echo ""
    echo "  Manage secrets with gopass (encrypted) or credentials.sh (plaintext fallback)."
    echo "  Secret values are NEVER exposed to AI agent context windows."
    echo ""
    print_info "Commands:"
    echo ""
    echo "  init                              Initialize gopass store"
    echo "  set <NAME>                        Store a secret (interactive hidden input)"
    echo "  list                              List secret names (never values)"
    echo "  status                            Show backend status"
    echo ""
    echo "  run CMD [ARGS...]                 Run command with all secrets injected"
    echo "  NAME [NAME...] -- CMD [ARGS...]   Run command with specific secrets"
    echo "  import-credentials                Import from credentials.sh to gopass"
    echo ""
    print_info "Examples:"
    echo ""
    echo "  # Store a secret (value entered at terminal, hidden)"
    echo "  aidevops secret set STRIPE_KEY"
    echo ""
    echo "  # Run a command with secrets injected (output redacted)"
    echo "  aidevops secret run curl -H 'Authorization: Bearer \$STRIPE_KEY' https://api.stripe.com/v1/charges"
    echo ""
    echo "  # Inject specific secrets only"
    echo "  aidevops secret GITHUB_TOKEN -- gh api /user"
    echo ""
    echo "  # Import existing credentials to gopass"
    echo "  aidevops secret import-credentials"
    echo ""
    print_info "Security:"
    echo ""
    echo "  - Secret values are injected via subprocess environment (never in agent context)"
    echo "  - All command output is automatically redacted (secret values -> [REDACTED])"
    echo "  - gopass encrypts secrets at rest with GPG"
    echo "  - credentials.sh is plaintext fallback (chmod 600)"
    echo ""
    return 0
}

# Main dispatch
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        init)
            cmd_init "$@"
            ;;
        set)
            cmd_set "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        run)
            cmd_run "$@"
            ;;
        import-credentials|import)
            cmd_import_credentials "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            # Check if it looks like "NAME [NAME...] -- CMD"
            # (specific secret injection pattern)
            if [[ "$command" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                cmd_run_specific "$command" "$@"
            else
                print_error "Unknown command: $command"
                echo ""
                cmd_help
                return 1
            fi
            ;;
    esac

    return 0
}

main "$@"
