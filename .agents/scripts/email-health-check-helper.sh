#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Health Check Helper Script
# Validates email authentication and deliverability for domains
# Checks: SPF, DKIM, DMARC, MX records, blacklist status,
#         BIMI, MTA-STS, TLS-RPT, DANE, and overall health score

set -euo pipefail

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

init_log_file

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [domain] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Common DKIM selectors by provider
readonly DKIM_SELECTORS="google google1 google2 selector1 selector2 k1 k2 s1 s2 pm smtp zoho default dkim"

# Health score tracking (global for accumulation across checks)
HEALTH_SCORE=0
HEALTH_MAX=0

add_score() {
    local points="$1"
    local max_points="$2"
    HEALTH_SCORE=$((HEALTH_SCORE + points))
    HEALTH_MAX=$((HEALTH_MAX + max_points))
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
        add_score 0 2
        return 1
    fi
    
    print_success "SPF record found:"
    echo "  $spf_record"
    
    # Analyze SPF record
    if [[ "$spf_record" == *"+all"* ]]; then
        print_error "CRITICAL: SPF uses +all (allows anyone to send)"
        add_score 0 2
    elif [[ "$spf_record" == *"-all"* ]]; then
        print_success "SPF uses -all (hard fail - strict)"
        add_score 2 2
    elif [[ "$spf_record" == *"~all"* ]]; then
        print_success "SPF uses ~all (soft fail - recommended)"
        add_score 2 2
    elif [[ "$spf_record" == *"?all"* ]]; then
        print_warning "SPF uses ?all (neutral - not recommended)"
        add_score 1 2
    else
        add_score 1 2
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
        add_score 0 2
        return 1
    fi
    
    add_score 2 2
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
        add_score 0 3
        return 1
    fi
    
    print_success "DMARC record found:"
    echo "  $dmarc_record"
    
    # Analyze DMARC policy
    if [[ "$dmarc_record" == *"p=reject"* ]]; then
        print_success "Policy: reject (strongest protection)"
        add_score 3 3
    elif [[ "$dmarc_record" == *"p=quarantine"* ]]; then
        print_success "Policy: quarantine (good protection)"
        add_score 2 3
    elif [[ "$dmarc_record" == *"p=none"* ]]; then
        print_warning "Policy: none (monitoring only - no protection)"
        add_score 1 3
    else
        add_score 1 3
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
        add_score 0 1
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
        add_score 1 1
    else
        print_success "$mx_count MX records provide redundancy"
        add_score 1 1
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
        add_score 2 2
    else
        print_warning "Some IPs are blacklisted - investigate and request delisting"
        add_score 0 2
    fi
    
    print_info "For comprehensive check, visit: https://mxtoolbox.com/blacklists.aspx"
    
    return 0
}

# Check BIMI record (Brand Indicators for Message Identification)
check_bimi() {
    local domain="$1"
    
    print_header "BIMI Check for $domain"
    
    local bimi_record
    bimi_record=$(dig TXT "default._bimi.${domain}" +short 2>/dev/null | tr -d '"' || true)
    
    if [[ -z "$bimi_record" ]]; then
        print_info "No BIMI record found for $domain"
        print_info "BIMI displays your brand logo next to emails in supported clients"
        print_info "Requires: DMARC p=quarantine or p=reject"
        print_info "Example: v=BIMI1; l=https://example.com/logo.svg; a=https://example.com/vmc.pem"
        add_score 0 1
        return 1
    fi
    
    print_success "BIMI record found:"
    echo "  $bimi_record"
    
    # Check for logo URL
    if [[ "$bimi_record" == *"l="* ]]; then
        local logo_url
        logo_url=$(echo "$bimi_record" | grep -oE 'l=https?://[^ ;]+' | cut -d= -f2 || true)
        if [[ -n "$logo_url" ]]; then
            print_success "Logo URL: $logo_url"
            # Check if logo is SVG (required)
            if [[ "$logo_url" == *".svg"* ]]; then
                print_success "Logo format: SVG (correct)"
            else
                print_warning "Logo should be SVG Tiny PS format"
            fi
        fi
    else
        print_warning "No logo URL (l=) in BIMI record"
    fi
    
    # Check for VMC (Verified Mark Certificate)
    if [[ "$bimi_record" == *"a="* ]]; then
        local vmc_url
        vmc_url=$(echo "$bimi_record" | grep -oE 'a=https?://[^ ;]+' | cut -d= -f2 || true)
        if [[ -n "$vmc_url" ]]; then
            print_success "VMC certificate URL: $vmc_url"
            print_info "VMC provides verified checkmark in Gmail"
        fi
    else
        print_info "No VMC certificate (a=) - logo will show without verification mark"
    fi
    
    add_score 1 1
    return 0
}

# Check MTA-STS (Mail Transfer Agent Strict Transport Security)
check_mta_sts() {
    local domain="$1"
    
    print_header "MTA-STS Check for $domain"
    
    # Check DNS record
    local mta_sts_record
    mta_sts_record=$(dig TXT "_mta-sts.${domain}" +short 2>/dev/null | tr -d '"' || true)
    
    if [[ -z "$mta_sts_record" ]]; then
        print_info "No MTA-STS DNS record found for $domain"
        print_info "MTA-STS enforces TLS for inbound email delivery"
        print_info "Add TXT record: _mta-sts.$domain -> v=STSv1; id=<unique-id>"
        add_score 0 1
        return 1
    fi
    
    print_success "MTA-STS DNS record found:"
    echo "  $mta_sts_record"
    
    # Check for policy file
    local policy_url="https://mta-sts.${domain}/.well-known/mta-sts.txt"
    local policy_response
    policy_response=$(curl -sL --max-time 10 "$policy_url" 2>/dev/null || true)
    
    if [[ -n "$policy_response" && "$policy_response" == *"version: STSv1"* ]]; then
        print_success "MTA-STS policy file accessible:"
        echo "$policy_response" | while read -r line; do
            echo "  $line"
        done
        
        # Check mode
        if [[ "$policy_response" == *"mode: enforce"* ]]; then
            print_success "Mode: enforce (TLS required)"
        elif [[ "$policy_response" == *"mode: testing"* ]]; then
            print_warning "Mode: testing (TLS failures reported but not enforced)"
        elif [[ "$policy_response" == *"mode: none"* ]]; then
            print_warning "Mode: none (MTA-STS disabled)"
        fi
    else
        print_warning "MTA-STS policy file not accessible at: $policy_url"
        print_info "Host the policy at: https://mta-sts.$domain/.well-known/mta-sts.txt"
    fi
    
    add_score 1 1
    return 0
}

# Check TLS-RPT (TLS Reporting)
check_tls_rpt() {
    local domain="$1"
    
    print_header "TLS-RPT Check for $domain"
    
    local tls_rpt_record
    tls_rpt_record=$(dig TXT "_smtp._tls.${domain}" +short 2>/dev/null | tr -d '"' || true)
    
    if [[ -z "$tls_rpt_record" ]]; then
        print_info "No TLS-RPT record found for $domain"
        print_info "TLS-RPT receives reports about TLS connection failures"
        print_info "Example: v=TLSRPTv1; rua=mailto:tls-reports@$domain"
        add_score 0 1
        return 1
    fi
    
    print_success "TLS-RPT record found:"
    echo "  $tls_rpt_record"
    
    # Check for reporting URI
    if [[ "$tls_rpt_record" == *"rua="* ]]; then
        print_success "Report destination configured"
    else
        print_warning "No report destination (rua=) in TLS-RPT record"
    fi
    
    add_score 1 1
    return 0
}

# Check DANE (DNS-based Authentication of Named Entities)
check_dane() {
    local domain="$1"
    
    print_header "DANE/TLSA Check for $domain"
    
    # Get primary MX
    local primary_mx
    primary_mx=$(dig MX "$domain" +short 2>/dev/null | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
    
    if [[ -z "$primary_mx" ]]; then
        print_warning "No MX records found - cannot check DANE"
        add_score 0 1
        return 1
    fi
    
    # Check TLSA record for port 25
    local tlsa_record
    tlsa_record=$(dig TLSA "_25._tcp.${primary_mx}" +short 2>/dev/null || true)
    
    if [[ -z "$tlsa_record" ]]; then
        print_info "No DANE/TLSA record found for $primary_mx"
        print_info "DANE provides cryptographic verification of mail server TLS certificates"
        print_info "Requires DNSSEC-signed domain"
        add_score 0 1
        return 1
    fi
    
    print_success "DANE/TLSA record found for $primary_mx:"
    echo "  $tlsa_record"
    
    # Check DNSSEC
    local dnssec_check
    dnssec_check=$(dig +dnssec "$primary_mx" A 2>/dev/null | grep -c "RRSIG" || echo "0")
    if [[ "$dnssec_check" -gt 0 ]]; then
        print_success "DNSSEC signatures present"
    else
        print_warning "DNSSEC not detected - DANE requires DNSSEC"
    fi
    
    add_score 1 1
    return 0
}

# Check reverse DNS (PTR) for mail server IPs
check_reverse_dns() {
    local domain="$1"
    
    print_header "Reverse DNS (PTR) Check for $domain"
    
    # Get primary MX
    local primary_mx
    primary_mx=$(dig MX "$domain" +short 2>/dev/null | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
    
    if [[ -z "$primary_mx" ]]; then
        print_warning "No MX records found - cannot check reverse DNS"
        add_score 0 1
        return 1
    fi
    
    local mx_ip
    mx_ip=$(dig A "$primary_mx" +short 2>/dev/null | head -1 || true)
    
    if [[ -z "$mx_ip" ]]; then
        print_warning "Could not resolve IP for $primary_mx"
        add_score 0 1
        return 1
    fi
    
    local ptr_record
    ptr_record=$(dig -x "$mx_ip" +short 2>/dev/null | sed 's/\.$//' || true)
    
    if [[ -n "$ptr_record" ]]; then
        print_success "PTR record found for $mx_ip:"
        echo "  $ptr_record"
        
        # Check if PTR matches MX hostname
        if [[ "$ptr_record" == "$primary_mx" ]]; then
            print_success "PTR matches MX hostname (FCrDNS verified)"
            add_score 1 1
        else
            print_warning "PTR ($ptr_record) does not match MX ($primary_mx)"
            print_info "Forward-confirmed reverse DNS (FCrDNS) improves deliverability"
            add_score 0 1
        fi
    else
        print_error "No PTR record for $mx_ip"
        print_info "Reverse DNS is important for email deliverability"
        add_score 0 1
    fi
    
    return 0
}

# Print health score summary
print_score_summary() {
    local domain="$1"
    
    print_header "Health Score for $domain"
    echo ""
    
    if [[ "$HEALTH_MAX" -eq 0 ]]; then
        print_warning "No checks were scored"
        return 0
    fi
    
    local percentage=$(( (HEALTH_SCORE * 100) / HEALTH_MAX ))
    local grade
    
    if [[ "$percentage" -ge 90 ]]; then
        grade="A"
    elif [[ "$percentage" -ge 80 ]]; then
        grade="B"
    elif [[ "$percentage" -ge 70 ]]; then
        grade="C"
    elif [[ "$percentage" -ge 60 ]]; then
        grade="D"
    else
        grade="F"
    fi
    
    echo "  Score: $HEALTH_SCORE / $HEALTH_MAX ($percentage%)"
    echo "  Grade: $grade"
    echo ""
    
    case "$grade" in
        "A")
            print_success "Excellent email health - all critical checks pass"
            ;;
        "B")
            print_success "Good email health - minor improvements possible"
            ;;
        "C")
            print_warning "Fair email health - some issues need attention"
            ;;
        "D")
            print_warning "Poor email health - significant issues found"
            ;;
        "F")
            print_error "Critical email health issues - immediate action needed"
            ;;
    esac
    
    echo ""
    print_info "Score breakdown: SPF(2) + DKIM(2) + DMARC(3) + MX(1) + Blacklist(2)"
    print_info "  + BIMI(1) + MTA-STS(1) + TLS-RPT(1) + DANE(1) + rDNS(1) = 15 max"
    
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
    
    # Reset score for full check
    HEALTH_SCORE=0
    HEALTH_MAX=0
    
    # Run individual checks for detailed output
    # Core checks (required)
    check_spf "$domain" || true
    check_dkim "$domain" || true
    check_dmarc "$domain" || true
    check_mx "$domain" || true
    check_blacklist "$domain" || true
    
    # Enhanced checks (recommended)
    check_bimi "$domain" || true
    check_mta_sts "$domain" || true
    check_tls_rpt "$domain" || true
    check_dane "$domain" || true
    check_reverse_dns "$domain" || true
    
    # Print score summary
    print_score_summary "$domain"
    
    print_header "Next Steps"
    print_info "For detailed deliverability testing, send a test email to mail-tester.com"
    print_info "For MX diagnostics: https://mxtoolbox.com/SuperTool.aspx?action=mx:$domain"
    print_info "For design rendering tests: email-test-suite-helper.sh test-design <html-file>"
    print_info "For inbox placement analysis: email-test-suite-helper.sh check-placement $domain"
    
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
    echo "  check [domain]              Full health check with score (all checks below)"
    echo "  spf [domain]                Check SPF record only"
    echo "  dkim [domain] [selector]    Check DKIM record (optional: specific selector)"
    echo "  dmarc [domain]              Check DMARC record only"
    echo "  mx [domain]                 Check MX records only"
    echo "  blacklist [domain]          Check blacklist status"
    echo "  bimi [domain]               Check BIMI record (brand logo in inbox)"
    echo "  mta-sts [domain]            Check MTA-STS (TLS enforcement for inbound)"
    echo "  tls-rpt [domain]            Check TLS-RPT (TLS failure reporting)"
    echo "  dane [domain]               Check DANE/TLSA records"
    echo "  reverse-dns [domain]        Check reverse DNS for mail server"
    echo "  mail-tester                 Guide for using mail-tester.com"
    echo "  help                        $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 check example.com"
    echo "  $0 spf example.com"
    echo "  $0 dkim example.com google"
    echo "  $0 dmarc example.com"
    echo "  $0 bimi example.com"
    echo "  $0 mta-sts example.com"
    echo ""
    echo "Health Score (out of 15):"
    echo "  SPF(2) + DKIM(2) + DMARC(3) + MX(1) + Blacklist(2)"
    echo "  + BIMI(1) + MTA-STS(1) + TLS-RPT(1) + DANE(1) + rDNS(1)"
    echo "  Grade: A(90%+) B(80%+) C(70%+) D(60%+) F(<60%)"
    echo ""
    echo "Dependencies:"
    echo "  Required: dig (usually pre-installed)"
    echo "  Optional: checkdmarc (pip install checkdmarc), curl (for MTA-STS)"
    echo ""
    echo "Common DKIM selectors by provider:"
    echo "  Google Workspace: google, google1, google2"
    echo "  Microsoft 365:    selector1, selector2"
    echo "  Mailchimp:        k1, k2, k3"
    echo "  SendGrid:         s1, s2, smtpapi"
    echo "  Postmark:         pm, pm2"
    echo ""
    echo "Related:"
    echo "  email-test-suite-helper.sh  Design rendering and delivery testing"
    
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
        "bimi")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_bimi "$domain"
            ;;
        "mta-sts"|"mtasts")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_mta_sts "$domain"
            ;;
        "tls-rpt"|"tlsrpt")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_tls_rpt "$domain"
            ;;
        "dane"|"tlsa")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dane "$domain"
            ;;
        "reverse-dns"|"rdns"|"ptr")
            if [[ -z "$domain" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_reverse_dns "$domain"
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
