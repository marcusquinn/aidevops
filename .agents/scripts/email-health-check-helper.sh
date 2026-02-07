#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Health Check Helper Script
# Validates email authentication and deliverability for domains
# Checks: SPF, DKIM, DMARC, MX records, blacklist status

set -euo pipefail

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [domain] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Common DKIM selectors by provider
readonly DKIM_SELECTORS="google google1 google2 selector1 selector2 k1 k2 s1 s2 pm smtp zoho default dkim"

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[FAIL]${NC} $msg" >&2
    return 0
}

print_header() {
    local msg="$1"
    echo ""
    echo -e "${BLUE}=== $msg ===${NC}"
    return 0
}

# Check if a command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
    return $?
}

# Check if checkdmarc is installed
check_checkdmarc() {
    if command_exists checkdmarc; then
        return 0
    else
        print_warning "checkdmarc not installed. Using dig for DNS queries."
        print_info "Install with: pip install checkdmarc"
        return 1
    fi
}

# Check SPF record
check_spf() {
    local domain="$1"
    
    print_header "SPF Check for $domain"
    
    local spf_record
    spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)
    
    if [[ -z "$spf_record" ]]; then
        print_error "No SPF record found for $domain"
        print_info "Recommendation: Add SPF record to authorize mail servers"
        return 1
    fi
    
    print_success "SPF record found:"
    echo "  $spf_record"
    
    # Analyze SPF record
    if [[ "$spf_record" == *"+all"* ]]; then
        print_error "CRITICAL: SPF uses +all (allows anyone to send)"
    elif [[ "$spf_record" == *"-all"* ]]; then
        print_success "SPF uses -all (hard fail - strict)"
    elif [[ "$spf_record" == *"~all"* ]]; then
        print_success "SPF uses ~all (soft fail - recommended)"
    elif [[ "$spf_record" == *"?all"* ]]; then
        print_warning "SPF uses ?all (neutral - not recommended)"
    fi
    
    # Count includes (rough DNS lookup estimate)
    local include_count
    include_count=$(echo "$spf_record" | grep -o "include:" | wc -l | tr -d ' ')
    if [[ "$include_count" -gt 8 ]]; then
        print_warning "SPF has $include_count includes - may exceed 10 DNS lookup limit"
    fi
    
    return 0
}

# Check DKIM record
check_dkim() {
    local domain="$1"
    local selector="${2:-}"
    
    print_header "DKIM Check for $domain"
    
    local found_dkim=false
    local selectors_to_check
    
    if [[ -n "$selector" ]]; then
        selectors_to_check="$selector"
    else
        selectors_to_check="$DKIM_SELECTORS"
    fi
    
    for sel in $selectors_to_check; do
        local dkim_record
        dkim_record=$(dig TXT "${sel}._domainkey.${domain}" +short 2>/dev/null | tr -d '"' || true)
        
        if [[ -n "$dkim_record" && "$dkim_record" != *"NXDOMAIN"* ]]; then
            found_dkim=true
            print_success "DKIM found for selector '$sel':"
            echo "  ${dkim_record:0:80}..."
            
            # Check key type and length
            if [[ "$dkim_record" == *"k=rsa"* ]]; then
                print_info "Key type: RSA"
            fi
        fi
    done
    
    if [[ "$found_dkim" == false ]]; then
        print_error "No DKIM records found for common selectors"
        print_info "Specify selector with: $0 dkim $domain <selector>"
        print_info "Find selector in email headers: DKIM-Signature: s=<selector>"
        return 1
    fi
    
    return 0
}

# Check DMARC record
check_dmarc() {
    local domain="$1"
    
    print_header "DMARC Check for $domain"
    
    local dmarc_record
    dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)
    
    if [[ -z "$dmarc_record" ]]; then
        print_error "No DMARC record found for $domain"
        print_info "Recommendation: Add DMARC record for email authentication policy"
        print_info "Example: v=DMARC1; p=none; rua=mailto:dmarc@$domain"
        return 1
    fi
    
    print_success "DMARC record found:"
    echo "  $dmarc_record"
    
    # Analyze DMARC policy
    if [[ "$dmarc_record" == *"p=reject"* ]]; then
        print_success "Policy: reject (strongest protection)"
    elif [[ "$dmarc_record" == *"p=quarantine"* ]]; then
        print_success "Policy: quarantine (good protection)"
    elif [[ "$dmarc_record" == *"p=none"* ]]; then
        print_warning "Policy: none (monitoring only - no protection)"
    fi
    
    # Check for reporting
    if [[ "$dmarc_record" == *"rua="* ]]; then
        print_success "Aggregate reporting enabled"
    else
        print_warning "No aggregate reporting (rua=) configured"
    fi
    
    if [[ "$dmarc_record" == *"ruf="* ]]; then
        print_info "Forensic reporting enabled"
    fi
    
    return 0
}

# Check MX records
check_mx() {
    local domain="$1"
    
    print_header "MX Check for $domain"
    
    local mx_records
    mx_records=$(dig MX "$domain" +short 2>/dev/null || true)
    
    if [[ -z "$mx_records" ]]; then
        print_error "No MX records found for $domain"
        print_info "Domain cannot receive email without MX records"
        return 1
    fi
    
    print_success "MX records found:"
    echo "$mx_records" | while read -r line; do
        echo "  $line"
    done
    
    # Count MX records
    local mx_count
    mx_count=$(echo "$mx_records" | wc -l | tr -d ' ')
    if [[ "$mx_count" -eq 1 ]]; then
        print_warning "Only 1 MX record - no redundancy"
    else
        print_success "$mx_count MX records provide redundancy"
    fi
    
    return 0
}

# Check blacklist status
check_blacklist() {
    local domain="$1"
    
    print_header "Blacklist Check for $domain"
    
    # Get IP addresses for domain
    local ips
    ips=$(dig A "$domain" +short 2>/dev/null || true)
    
    if [[ -z "$ips" ]]; then
        # Try MX records
        local mx_host
        mx_host=$(dig MX "$domain" +short 2>/dev/null | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
        if [[ -n "$mx_host" ]]; then
            ips=$(dig A "$mx_host" +short 2>/dev/null || true)
        fi
    fi
    
    if [[ -z "$ips" ]]; then
        print_warning "Could not resolve IP addresses for blacklist check"
        return 1
    fi
    
    print_info "Checking IPs: $ips"
    
    # Common blacklists to check
    local blacklists="zen.spamhaus.org bl.spamcop.net b.barracudacentral.org"
    local listed=false
    
    for ip in $ips; do
        # Reverse IP for DNSBL lookup
        local reversed_ip
        reversed_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
        
        for bl in $blacklists; do
            local result
            result=$(dig A "${reversed_ip}.${bl}" +short 2>/dev/null || true)
            
            if [[ -n "$result" && "$result" != *"NXDOMAIN"* ]]; then
                print_error "$ip is listed on $bl"
                listed=true
            fi
        done
    done
    
    if [[ "$listed" == false ]]; then
        print_success "No blacklist entries found for checked IPs"
    else
        print_warning "Some IPs are blacklisted - investigate and request delisting"
    fi
    
    print_info "For comprehensive check, visit: https://mxtoolbox.com/blacklists.aspx"
    
    return 0
}

# Full health check using checkdmarc if available
check_full() {
    local domain="$1"
    
    print_header "Full Email Health Check for $domain"
    echo ""
    
    if check_checkdmarc; then
        print_info "Using checkdmarc for comprehensive analysis..."
        echo ""
        checkdmarc "$domain" 2>/dev/null || true
        echo ""
    fi
    
    # Run individual checks for detailed output
    check_spf "$domain" || true
    check_dkim "$domain" || true
    check_dmarc "$domain" || true
    check_mx "$domain" || true
    check_blacklist "$domain" || true
    
    print_header "Summary"
    print_info "For detailed deliverability testing, send a test email to mail-tester.com"
    print_info "For MX diagnostics: https://mxtoolbox.com/SuperTool.aspx?action=mx:$domain"
    
    return 0
}

# Guide for mail-tester.com
mail_tester_guide() {
    print_header "Mail-Tester.com Guide"
    
    print_info "Mail-Tester provides comprehensive deliverability scoring (1-10)"
    echo ""
    echo "Steps:"
    echo "  1. Visit https://mail-tester.com"
    echo "  2. Copy the unique test email address shown"
    echo "  3. Send a test email from your domain to that address"
    echo "  4. Click 'Then check your score' on the website"
    echo "  5. Review the detailed report"
    echo ""
    print_info "Aim for a score of 9/10 or higher"
    echo ""
    echo "Common issues that reduce score:"
    echo "  - Missing or invalid SPF record"
    echo "  - Missing DKIM signature"
    echo "  - No DMARC policy"
    echo "  - Blacklisted IP"
    echo "  - Spam-like content"
    echo "  - Missing unsubscribe header"
    
    return 0
}

# Show help
show_help() {
    echo "Email Health Check Helper Script"
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Commands:"
    echo "  check [domain]              Full health check (SPF, DKIM, DMARC, MX, blacklist)"
    echo "  spf [domain]                Check SPF record only"
    echo "  dkim [domain] [selector]    Check DKIM record (optional: specific selector)"
    echo "  dmarc [domain]              Check DMARC record only"
    echo "  mx [domain]                 Check MX records only"
    echo "  blacklist [domain]          Check blacklist status"
    echo "  mail-tester                 Guide for using mail-tester.com"
    echo "  help                        $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 check example.com"
    echo "  $0 spf example.com"
    echo "  $0 dkim example.com google"
    echo "  $0 dmarc example.com"
    echo "  $0 mx example.com"
    echo "  $0 blacklist example.com"
    echo ""
    echo "Dependencies:"
    echo "  Required: dig (usually pre-installed)"
    echo "  Optional: checkdmarc (pip install checkdmarc)"
    echo ""
    echo "Common DKIM selectors by provider:"
    echo "  Google Workspace: google, google1, google2"
    echo "  Microsoft 365:    selector1, selector2"
    echo "  Mailchimp:        k1, k2, k3"
    echo "  SendGrid:         s1, s2, smtpapi"
    echo "  Postmark:         pm, pm2"
    
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local domain="${2:-}"
    local selector="${3:-}"
    
    case "$command" in
        "check"|"full")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            check_full "$domain"
            ;;
        "spf")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_spf "$domain"
            ;;
        "dkim")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dkim "$domain" "$selector"
            ;;
        "dmarc")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dmarc "$domain"
            ;;
        "mx")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_mx "$domain"
            ;;
        "blacklist"|"bl")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_blacklist "$domain"
            ;;
        "mail-tester"|"mailtester")
            mail_tester_guide
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            # Assume first arg is domain if it looks like one
            if [[ "$command" == *"."* ]]; then
                check_full "$command"
            else
                print_error "Unknown command: $command"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            ;;
    esac
    
    return 0
}

main "$@"
