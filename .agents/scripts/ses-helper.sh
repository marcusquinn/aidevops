#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2154,SC2155,SC2162,SC2181,SC2317
set -euo pipefail

# Amazon SES Helper Script
# Comprehensive SES management for AI assistants

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"


# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 <command> [options]"

CONFIG_FILE="${SES_CONFIG_FILE:-${SCRIPT_DIR}/../../configs/ses-config.json}"
PROFILE_OVERRIDE=""
AWS_SELECTED_PROFILE=""
AWS_CREDENTIAL_PREFIX=""
AWS_SELECTED_REGION=""
AWS_USE_SESSION_TOKEN=false

# Constants for repeated strings
readonly ERROR_IDENTITY_REQUIRED="Identity (email or domain) is required"

# Check if AWS CLI is installed
check_aws_cli() {
    # command -v would find this script's aws() injection wrapper, not the CLI.
    if ! type -P aws &> /dev/null; then
        print_error "AWS CLI is not installed. Provision AWS CLI v2 through the approved platform setup."
        exit 1
    fi

    return 0
}

# Load SES configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/ses-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed"
        print_info "Install on macOS: brew install jq"
        print_info "Install on Ubuntu: sudo apt-get install jq"
        exit 1
    fi
    return 0
}

# Get account configuration
get_account_config() {
    local account_name="$1"
    load_config
    
    if [[ -z "$account_name" ]]; then
        print_error "Account name is required"
        list_accounts
        exit 1
    fi
    
    local account_config
    account_config=$(jq -c --arg account "$account_name" '.accounts[$account]' "$CONFIG_FILE")
    if [[ "$account_config" == "null" ]]; then
        print_error "Account '$account_name' not found in configuration"
        list_accounts
        exit 1
    fi
    
    echo "$account_config"
    return 0
}

# Select metadata only. Credentials are injected into each AWS subprocess.
set_aws_credentials() {
    local account_name="$1"
    local config
    config=$(get_account_config "$account_name")
    check_aws_cli
    
    if jq -e 'has("aws_access_key_id") or has("aws_secret_access_key") or has("aws_session_token")' <<<"$config" >/dev/null; then
        print_warning "Plaintext AWS fields are ignored. Migrate with aidevops secret set, remove them from SES config, then rotate the keys." >&2
    fi
    AWS_SELECTED_PROFILE="${PROFILE_OVERRIDE:-$(jq -r '.profile // empty' <<<"$config")}"
    AWS_SELECTED_REGION=$(jq -r '.region // "us-east-1"' <<<"$config")
    AWS_CREDENTIAL_PREFIX=$(jq -r '.credential_prefix // empty' <<<"$config")
    AWS_USE_SESSION_TOKEN=$(jq -r '.session_token // false' <<<"$config")
    if [[ -z "$AWS_SELECTED_PROFILE" && ! "$AWS_CREDENTIAL_PREFIX" =~ ^AWS_[A-Z0-9_]+$ ]]; then
        print_error "Set profile or an account-tagged credential_prefix (AWS_PRODUCTION) in SES metadata"
        exit 1
    fi
    return 0
}

# Shadow only inside this script; never put credential values in argv or config.
aws() {
    if [[ -n "$AWS_SELECTED_PROFILE" ]]; then
        env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN \
            -u AWS_PROFILE -u AWS_DEFAULT_PROFILE AWS_PAGER="" \
            aws --profile "$AWS_SELECTED_PROFILE" --region "$AWS_SELECTED_REGION" "$@"
        return $?
    fi
    local key_name="${AWS_CREDENTIAL_PREFIX}_ACCESS_KEY_ID"
    local secret_name="${AWS_CREDENTIAL_PREFIX}_SECRET_ACCESS_KEY"
    local token_name=""
    local -a names=("$key_name" "$secret_name")
    if [[ "$AWS_USE_SESSION_TOKEN" == "true" ]]; then
        token_name="${AWS_CREDENTIAL_PREFIX}_SESSION_TOKEN"
        names+=("$token_name")
    fi
    # shellcheck disable=SC2016 # Values expand only inside the injected child.
    "${SCRIPT_DIR}/secret-helper.sh" "${names[@]}" -- bash -c '
        run_aws() {
        local key_name="$1"
        local secret_name="$2"
        local token_name="$3"
        local region="$4"
        shift 4
        unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
        export AWS_ACCESS_KEY_ID="${!key_name}" AWS_SECRET_ACCESS_KEY="${!secret_name}"
        [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || exit 1
        if [[ -n "$token_name" ]]; then
            export AWS_SESSION_TOKEN="${!token_name}"
            [[ -n "$AWS_SESSION_TOKEN" ]] || exit 1
        fi
        export AWS_PAGER="" AWS_EC2_METADATA_DISABLED=true
        exec aws --region "$region" "$@"
        return 1
        }
        run_aws "$@"
    ' aws "$key_name" "$secret_name" "$token_name" "$AWS_SELECTED_REGION" "$@"
    return $?
}

# List all configured accounts
list_accounts() {
    load_config
    print_info "Available SES accounts:"
    jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read account; do
        local description
        description=$(jq -r ".accounts.\"$account\".description" "$CONFIG_FILE")
        local region
        region=$(jq -r ".accounts.\"$account\".region" "$CONFIG_FILE")
        echo "  - $account ($region) - $description"
    done
    return 0
}

# Get sending quota
get_sending_quota() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting sending quota for account: $account_name"
    aws ses get-send-quota --output table
    return 0
}

# Get sending statistics
get_sending_statistics() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting sending statistics for account: $account_name"
    aws ses get-send-statistics --output table
    return 0
}

# List verified email addresses
list_verified_emails() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Verified email addresses for account: $account_name"
    aws ses list-verified-email-addresses --output table
    return 0
}

# List verified domains
list_verified_domains() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Verified domains for account: $account_name"
    aws ses list-identities --identity-type Domain --output table
    return 0
}

# Get identity verification attributes
get_identity_verification() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"
    
    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi
    
    print_info "Getting verification attributes for: $identity"
    aws ses get-identity-verification-attributes --identities "$identity" --output table
    return 0
}

# Get reputation
get_reputation() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting account reputation for: $account_name"
    aws ses get-account-sending-enabled --output table
    echo ""
    print_info "Reputation tracking:"
    aws ses describe-reputation-tracking --output table
    return 0
}

# List suppressed destinations (bounces/complaints)
list_suppressed_destinations() {
    local account_name="$1"
    local filter_option="${2:-}"
    local domain="${3:-}"
    set_aws_credentials "$account_name"

    print_info "Suppressed destinations (bounces/complaints) for account: $account_name"
    if [[ -n "$filter_option" && ( "$filter_option" != "--filter" || -z "$domain" || "$domain" == *"@"* || "$domain" == *"/"* ) ]]; then
        print_error "Usage: suppressed <account> [--filter <domain>]"
        return 1
    fi
    # SESv2 does not provide a paginator for this operation in every CLI version.
    # Follow the service NextToken explicitly; never silently return only page one.
    local destinations='[]' page="" next_token="" previous_token=""
    local -a args=()
    while true; do
        page=$(aws sesv2 list-suppressed-destinations --no-paginate --page-size 100 --output json ${args[@]+"${args[@]}"}) || return 1
        destinations=$(jq -c --argjson all "$destinations" '$all + (.SuppressedDestinationSummaries // [])' <<<"$page") || return 1
        next_token=$(jq -r '.NextToken // empty' <<<"$page") || return 1
        [[ -z "$next_token" ]] && break
        if [[ "$next_token" == "$previous_token" ]]; then
            print_error "SES returned a repeated pagination token; listing incomplete"
            return 1
        fi
        previous_token="$next_token"
        args=(--next-token "$next_token")
    done
    jq --arg domain "$domain" '[.[] | select($domain == "" or ((.EmailAddress | ascii_downcase | split("@") | last) == ($domain | ascii_downcase)))]' <<<"$destinations"
    return $?
}

# Build a JSON list rather than CLI shorthand, including an explicit empty list.
suppression_reasons() {
    local reason=""
    for reason in "$@"; do
        if [[ "$reason" != "BOUNCE" && "$reason" != "COMPLAINT" ]]; then
            print_error "Suppression reasons must be BOUNCE or COMPLAINT (no reasons means [])" >&2
            return 1
        fi
    done
    jq -cn --args '$ARGS.positional' "$@"
    return 0
}

account_suppression() {
    local account_name="$1"
    local operation="${2:-get}"
    shift 2
    set_aws_credentials "$account_name"
    case "$operation" in
        get) aws sesv2 get-account --query SuppressionAttributes --output json || return 1 ;;
        put)
            local reasons=""
            reasons=$(suppression_reasons "$@") || return 1
            aws sesv2 put-account-suppression-attributes --cli-input-json "{\"SuppressedReasons\":$reasons}" || return 1
            ;;
        *) print_error "Usage: account-suppression <account> get|put [BOUNCE COMPLAINT]"; return 1 ;;
    esac
    return 0
}

configuration_set() {
    local account_name="$1"
    local operation="${2:-list}"
    local name="${3:-}"
    set_aws_credentials "$account_name"
    if [[ "$operation" != "list" && -z "$name" ]]; then
        print_error "Configuration set name is required"
        return 1
    fi
    case "$operation" in
        list) aws sesv2 list-configuration-sets --output table || return 1 ;;
        create) aws sesv2 create-configuration-set --configuration-set-name "$name" || return 1 ;;
        suppression)
            shift 3
            local reasons=""
            reasons=$(suppression_reasons "$@") || return 1
            aws sesv2 put-configuration-set-suppression-options --configuration-set-name "$name" \
                --suppression-options "{\"SuppressedReasons\":$reasons}" || return 1
            ;;
        *) print_error "Usage: config-set <account> create|suppression <name> [BOUNCE COMPLAINT]|list"; return 1 ;;
    esac
    return 0
}

# Get suppression list details
get_suppression_details() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_info "Getting suppression details for: $email"
    aws sesv2 get-suppressed-destination --email-address "$email" --output table
    return 0
}

# Remove from suppression list
remove_from_suppression() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_warning "Removing $email from suppression list..."
    aws sesv2 delete-suppressed-destination --email-address "$email"
    if [[ $? -eq 0 ]]; then
        print_success "Successfully removed $email from suppression list"
        return 0
    else
        print_error "Failed to remove $email from suppression list"
        return 1
    fi
    return 0
}

# Send test email
send_test_email() {
    local account_name="$1"
    local from_email="$2"
    local to_email="$3"
    local subject="${4:-}"
    local body="${5:-}"
    set_aws_credentials "$account_name"

    if [[ -z "$from_email" || -z "$to_email" ]]; then
        print_error "From and to email addresses are required"
        exit 1
    fi

    subject="${subject:-SES Test Email}"
    body="${body:-This is a test email sent via AWS SES.}"

    print_info "Sending test email from $from_email to $to_email"

    local message_id=$(aws ses send-email \
        --source "$from_email" \
        --destination "ToAddresses=$to_email" \
        --message "Subject={Data='$subject'},Body={Text={Data='$body'}}" \
        --query 'MessageId' --output text)

    if [[ $? -eq 0 ]]; then
        print_success "Test email sent successfully. Message ID: $message_id"
        return 0
    else
        print_error "Failed to send test email"
        return 1
    fi
    return 0
}

# Get configuration sets
list_configuration_sets() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Configuration sets for account: $account_name"
    aws ses list-configuration-sets --output table
    return 0
}

# Get bounce and complaint notifications
get_bounce_complaint_notifications() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "Bounce and complaint notifications for: $identity"
    aws ses get-identity-notification-attributes --identities "$identity" --output table
    return 0
}

# Verify email address
verify_email() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_info "Sending verification email to: $email"
    aws ses verify-email-identity --email-address "$email"
    if [[ $? -eq 0 ]]; then
        print_success "Verification email sent to $email"
        print_info "Check the inbox and click the verification link"
    else
        print_error "Failed to send verification email"
    fi
    return 0
}

# Verify domain
verify_domain() {
    local account_name="$1"
    local domain="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$domain" ]]; then
        print_error "Domain is required"
        exit 1
    fi

    print_info "Starting domain verification for: $domain"
    local verification_token
    verification_token=$(aws ses verify-domain-identity --domain "$domain" --query 'VerificationToken' --output text)

    if [[ $? -eq 0 ]]; then
        print_success "Domain verification initiated for $domain"
        print_info "Add this TXT record to your DNS:"
        echo "  Name: _amazonses.$domain"
        echo "  Value: $verification_token"
    else
        print_error "Failed to initiate domain verification"
    fi
    return 0
}

# Get DKIM attributes
get_dkim_attributes() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "DKIM attributes for: $identity"
    aws ses get-identity-dkim-attributes --identities "$identity" --output table
    return 0
}

# Enable DKIM
enable_dkim() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "Enabling DKIM for: $identity"
    aws ses put-identity-dkim-attributes --identity "$identity" --dkim-enabled
    if [[ $? -eq 0 ]]; then
        print_success "DKIM enabled for $identity"
        get_dkim_attributes "$account_name" "$identity"
    else
        print_error "Failed to enable DKIM"
    return 0
    fi
    return 0
}

# Monitor email delivery
monitor_delivery() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Email delivery monitoring for account: $account_name"
    echo ""

    print_info "=== SENDING QUOTA ==="
    get_sending_quota "$account_name"
    echo ""

    print_info "=== SENDING STATISTICS (Last 24 hours) ==="
    get_sending_statistics "$account_name"
    echo ""

    print_info "=== REPUTATION STATUS ==="
    get_reputation "$account_name"
    echo ""

    return 0
    print_info "=== SUPPRESSED DESTINATIONS ==="
    list_suppressed_destinations "$account_name"
    return 0
}

# Audit SES configuration
audit_configuration() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "SES Configuration Audit for account: $account_name"
    echo ""

    print_info "=== VERIFIED IDENTITIES ==="
    print_info "Verified Email Addresses:"
    list_verified_emails "$account_name"
    echo ""

    print_info "Verified Domains:"
    list_verified_domains "$account_name"
    echo ""

    print_info "=== CONFIGURATION SETS ==="
    list_configuration_sets "$account_name"
    echo ""
    return 0

    print_info "=== ACCOUNT STATUS ==="
    get_reputation "$account_name"
    return 0
}

# Debug delivery issues
debug_delivery() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required for debugging"
        exit 1
    fi

    print_info "Debugging delivery issues for: $email"
    echo ""

    print_info "=== SUPPRESSION STATUS ==="
    if aws sesv2 get-suppressed-destination --email-address "$email" &>/dev/null; then
        print_warning "$email is in the suppression list"
        get_suppression_details "$account_name" "$email"
        echo ""
        print_info "To remove from suppression list, run:"
        echo "  $0 remove-suppression $account_name $email"
    else
        print_success "$email is not in the suppression list"
    fi
    echo ""

    print_info "=== RECENT SENDING STATISTICS ==="
    get_sending_statistics "$account_name"
    return 0
    echo ""

    print_info "=== ACCOUNT REPUTATION ==="
    get_reputation "$account_name"
    return 0
}

# Show help
show_help() {
    echo "Amazon SES Helper Script"
    echo "Usage: $0 [--profile <name>] [command] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  accounts                           - List all configured accounts"
    echo "  quota [account]                    - Get sending quota"
    echo "  stats [account]                    - Get sending statistics"
    echo "  verified-emails [account]          - List verified email addresses"
    echo "  verified-domains [account]         - List verified domains"
    echo "  verify-identity [account] [identity] - Get identity verification status"
    echo "  reputation [account]               - Get account reputation"
    echo "  suppressed [account] [--filter domain] - List all pages; optionally filter domain"
    echo "  account-suppression [account] get|put [BOUNCE COMPLAINT] - Account settings"
    echo "  config-set [account] create|suppression <name> [BOUNCE COMPLAINT]|list"
    echo "  suppression-details [account] [email] - Get suppression details"
    echo "  remove-suppression [account] [email] - Remove email from suppression list"
    echo "  send-test [account] [from] [to] [subject] [body] - Send test email"
    echo "  config-sets [account]              - List configuration sets"
    echo "  notifications [account] [identity] - Get bounce/complaint notifications"
    echo "  verify-email [account] [email]     - Verify email address"
    echo "  verify-domain [account] [domain]   - Verify domain"
    echo "  dkim [account] [identity]          - Get DKIM attributes"
    echo "  enable-dkim [account] [identity]   - Enable DKIM"
    echo "  monitor [account]                  - Monitor email delivery"
    echo "  audit [account]                    - Audit SES configuration"
    echo "  debug [account] [email]            - Debug delivery issues"
    echo "  help                 - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 accounts"
    echo "  $0 quota production"
    echo "  $0 monitor production"
    echo "  $0 debug production user@example.com"
    echo "  $0 send-test production noreply@yourdomain.com test@example.com"
    echo "  $0 verify-domain production yourdomain.com"
    return 0
}

# Main script logic
main() {
    if [[ "${1:-}" == "--profile" ]]; then
        PROFILE_OVERRIDE="${2:-}"
        if [[ -z "$PROFILE_OVERRIDE" ]]; then
            print_error "--profile requires a named AWS profile"
            return 1
        fi
        shift 2
    fi
    local subcommand="${1:-help}"
    local account_name="${2:-}"
    local identity="${3:-}"
    local destination="${4:-}"
    local subject="${5:-}"
    local body="${6:-}"

    case "$subcommand" in
        "accounts")
            list_accounts
            ;;
        "quota")
            get_sending_quota "$account_name"
            ;;
        "stats")
            get_sending_statistics "$account_name"
            ;;
        "verified-emails")
            list_verified_emails "$account_name"
            ;;
        "verified-domains")
            list_verified_domains "$account_name"
            ;;
        "verify-identity")
            get_identity_verification "$account_name" "$identity"
            ;;
        "reputation")
            get_reputation "$account_name"
            ;;
        "suppressed")
            list_suppressed_destinations "$account_name" "$identity" "$destination"
            ;;
        "account-suppression")
            shift 2
            account_suppression "$account_name" "${1:-get}" "${@:2}"
            ;;
        "config-set")
            shift 2
            configuration_set "$account_name" "${@:-list}"
            ;;
        "suppression-details")
            get_suppression_details "$account_name" "$identity"
            ;;
        "remove-suppression")
            remove_from_suppression "$account_name" "$identity"
            ;;
        "send-test")
            send_test_email "$account_name" "$identity" "$destination" "$subject" "$body"
            ;;
        "config-sets")
            list_configuration_sets "$account_name"
            ;;
        "notifications")
            get_bounce_complaint_notifications "$account_name" "$identity"
            ;;
        "verify-email")
            verify_email "$account_name" "$identity"
            ;;
        "verify-domain")
            verify_domain "$account_name" "$identity"
            ;;
        "dkim")
            get_dkim_attributes "$account_name" "$identity"
            ;;
        "enable-dkim")
            enable_dkim "$account_name" "$identity"
            ;;
        "monitor")
            monitor_delivery "$account_name"
            ;;
        "audit")
            audit_configuration "$account_name"
            ;;
        "debug")
            debug_delivery "$account_name" "$identity"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
