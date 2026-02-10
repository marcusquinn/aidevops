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
    
    # Check for policy file (enforce HTTPS-only to prevent redirect to insecure sites — S6506)
    local policy_url="https://mta-sts.${domain}/.well-known/mta-sts.txt"
    local policy_response
    policy_response=$(curl -s --proto =https --max-time 10 "$policy_url" 2>/dev/null || true)
    
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

# =============================================================================
# Content-Level Checks (v3) - Inspired by EOA Campaign Precheck
# These validate HTML email content quality before sending
# =============================================================================

# Validate that a file exists and is readable HTML
validate_html_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi
    if [[ ! -r "$file" ]]; then
        print_error "File not readable: $file"
        return 1
    fi
    return 0
}

# Content score tracking (separate from infrastructure score)
CONTENT_SCORE=0
CONTENT_MAX=0

add_content_score() {
    local points="$1"
    local max_points="$2"
    CONTENT_SCORE=$((CONTENT_SCORE + points))
    CONTENT_MAX=$((CONTENT_MAX + max_points))
    return 0
}

# Check subject line quality
check_subject() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Subject Line Check"

    local subject=""
    # Extract from <title> tag (common pattern in HTML emails)
    subject=$(sed -n 's/.*<[tT][iI][tT][lL][eE]>\([^<]*\).*/\1/p' "$file" 2>/dev/null | head -1 || true)
    # Fallback: look for subject in meta tag
    if [[ -z "$subject" ]]; then
        subject=$(sed -n 's/.*name="subject"[[:space:]]*content="\([^"]*\)".*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$subject" ]]; then
        print_warning "No subject line found (<title> tag or meta name=\"subject\")"
        print_info "Add a <title> tag to your HTML email for subject line analysis"
        add_content_score 0 2
        return 1
    fi

    print_info "Subject: $subject"
    local subject_len=${#subject}
    local score=2

    # Length check
    if [[ "$subject_len" -le 50 ]]; then
        print_success "Length: $subject_len chars (good, under 50)"
    elif [[ "$subject_len" -le 80 ]]; then
        print_warning "Length: $subject_len chars (may truncate on mobile, aim for under 50)"
        score=$((score - 1))
    else
        print_error "Length: $subject_len chars (will truncate on most clients, max 80)"
        score=$((score - 2))
    fi

    # ALL CAPS check
    local upper_count
    upper_count=$(echo "$subject" | grep -o '[A-Z]' | wc -l | tr -d ' ')
    local alpha_count
    alpha_count=$(echo "$subject" | grep -o '[a-zA-Z]' | wc -l | tr -d ' ')
    if [[ "$alpha_count" -gt 0 ]]; then
        local upper_pct=$(( (upper_count * 100) / alpha_count ))
        if [[ "$upper_pct" -gt 50 ]]; then
            print_warning "ALL CAPS: ${upper_pct}% uppercase (spam filter trigger)"
            score=$((score > 0 ? score - 1 : 0))
        fi
    fi

    # Excessive punctuation
    local excl_count
    excl_count=$(echo "$subject" | grep -o '!' | wc -l | tr -d ' ')
    local quest_count
    quest_count=$(echo "$subject" | grep -o '?' | wc -l | tr -d ' ')
    if [[ "$excl_count" -gt 1 ]]; then
        print_warning "Excessive exclamation marks: $excl_count (use at most 1)"
        score=$((score > 0 ? score - 1 : 0))
    fi
    if [[ "$quest_count" -gt 1 ]]; then
        print_warning "Excessive question marks: $quest_count (use at most 1)"
    fi

    # Spam trigger words in subject
    local spam_words="free act now limited time click here buy now order now no obligation risk free winner congratulations urgent cash guarantee"
    local subject_lower
    subject_lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')
    local spam_found=false
    for word in $spam_words; do
        if [[ "$subject_lower" == *"$word"* ]]; then
            print_warning "Spam trigger word in subject: '$word'"
            spam_found=true
        fi
    done
    if [[ "$spam_found" == true ]]; then
        score=$((score > 0 ? score - 1 : 0))
    fi

    add_content_score "$score" 2
    return 0
}

# Check preheader/preview text
check_preheader() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Preheader Text Check"

    local preheader=""
    # Look for common preheader patterns
    # Pattern 1: hidden div/span with preheader class
    preheader=$(sed -n 's/.*class="[^"]*preheader[^"]*"[^>]*>\([^<]*\).*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
    # Pattern 2: hidden preview text span
    if [[ -z "$preheader" ]]; then
        preheader=$(sed -n 's/.*class="[^"]*preview[^"]*"[^>]*>\([^<]*\).*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
    fi
    # Pattern 3: meta description
    if [[ -z "$preheader" ]]; then
        preheader=$(sed -n 's/.*name="description"[[:space:]]*content="\([^"]*\)".*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$preheader" ]]; then
        print_warning "No preheader/preview text found"
        print_info "Add a hidden preheader element: <span class=\"preheader\">Preview text here</span>"
        print_info "Without a preheader, email clients show the first visible text"
        add_content_score 0 1
        return 1
    fi

    print_info "Preheader: $preheader"
    local preheader_len=${#preheader}
    local score=1

    # Length check
    if [[ "$preheader_len" -ge 40 && "$preheader_len" -le 130 ]]; then
        print_success "Length: $preheader_len chars (optimal range: 40-130)"
    elif [[ "$preheader_len" -lt 40 ]]; then
        print_warning "Length: $preheader_len chars (too short, aim for 40-130)"
        score=0
    else
        print_warning "Length: $preheader_len chars (may truncate, aim for 40-130)"
    fi

    # Check for placeholder text
    local preheader_lower
    preheader_lower=$(echo "$preheader" | tr '[:upper:]' '[:lower:]')
    local placeholders="view in browser email not displaying view this email having trouble viewing"
    for phrase in "view in browser" "email not displaying" "view this email" "having trouble viewing"; do
        if [[ "$preheader_lower" == *"$phrase"* ]]; then
            print_warning "Default/placeholder preheader text detected: '$phrase'"
            score=0
        fi
    done

    add_content_score "$score" 1
    return 0
}

# Check email accessibility
check_accessibility() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Accessibility Check"

    local score=2
    local issues=0
    local content
    content=$(cat "$file")

    # Check lang attribute
    if echo "$content" | grep -qi '<html[^>]*lang='; then
        print_success "Language attribute found on <html> tag"
    else
        print_warning "Missing lang attribute on <html> tag (e.g., <html lang=\"en\">)"
        issues=$((issues + 1))
    fi

    # Check image alt text
    local img_count
    img_count=$(echo "$content" | grep -ioc '<img[[:space:]]' || echo "0")
    local img_with_alt
    img_with_alt=$(echo "$content" | grep -ioc '<img[^>]*alt=' || echo "0")
    local img_no_alt=$((img_count - img_with_alt))
    if [[ "$img_no_alt" -lt 0 ]]; then
        img_no_alt=0
    fi

    if [[ "$img_count" -eq 0 ]]; then
        print_info "No images found in email"
    elif [[ "$img_no_alt" -eq 0 ]]; then
        print_success "All $img_count images have alt attributes"
    else
        print_warning "$img_no_alt of $img_count images missing alt attribute"
        issues=$((issues + 1))
    fi

    # Check for layout table roles
    local table_count
    table_count=$(echo "$content" | grep -ioc '<table[[:space:]]' || echo "0")
    local table_with_role
    table_with_role=$(echo "$content" | grep -ioc '<table[^>]*role=' || echo "0")

    if [[ "$table_count" -gt 0 ]]; then
        if [[ "$table_with_role" -eq "$table_count" ]]; then
            print_success "All $table_count tables have role attributes"
        else
            local missing=$((table_count - table_with_role))
            print_warning "$missing of $table_count tables missing role attribute (use role=\"presentation\" for layout tables)"
            issues=$((issues + 1))
        fi
    fi

    # Check for generic link text
    local generic_links
    generic_links=$(echo "$content" | grep -Eio '<a[^>]*>[^<]*(click here|read more|learn more)[^<]*</a>' | wc -l | tr -d ' ')
    if [[ "$generic_links" -gt 0 ]]; then
        print_warning "$generic_links links with generic text (\"click here\", \"read more\") - use descriptive link text"
        issues=$((issues + 1))
    fi

    # Check for small font sizes
    local small_fonts
    small_fonts=$(echo "$content" | grep -Eio 'font-size:[[:space:]]*[0-9]+px' | sed 's/[^0-9]//g' | while read -r size; do
        if [[ "$size" -lt 14 ]]; then
            echo "$size"
        fi
    done | wc -l | tr -d ' ')
    if [[ "$small_fonts" -gt 0 ]]; then
        print_warning "$small_fonts instances of font-size below 14px (readability concern)"
        issues=$((issues + 1))
    fi

    # Score based on issues
    if [[ "$issues" -eq 0 ]]; then
        print_success "No accessibility issues found"
    elif [[ "$issues" -le 2 ]]; then
        score=1
    else
        score=0
    fi

    add_content_score "$score" 2
    return 0
}

# Check links in email
check_links() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Link Validation"

    local score=2
    local content
    content=$(cat "$file")

    # Count total links
    local link_count
    link_count=$(echo "$content" | grep -ioc '<a[^>]*href=' || echo "0")
    print_info "Total links found: $link_count"

    # Check for empty hrefs
    local empty_hrefs
    empty_hrefs=$(echo "$content" | grep -Eio 'href=["'"'"'][[:space:]]*["'"'"']' | wc -l | tr -d ' ')
    if [[ "$empty_hrefs" -gt 0 ]]; then
        print_error "$empty_hrefs links with empty href"
        score=$((score - 1))
    fi

    # Check for placeholder links
    local placeholder_links
    placeholder_links=$(echo "$content" | grep -Eio 'href=["'"'"'](#|javascript:|https?://example\.com)["'"'"']' | wc -l | tr -d ' ')
    if [[ "$placeholder_links" -gt 0 ]]; then
        print_warning "$placeholder_links placeholder links detected (#, javascript:, example.com)"
        score=$((score > 0 ? score - 1 : 0))
    fi

    # Check for unsubscribe link (CAN-SPAM requirement)
    local unsub_links
    unsub_links=$(echo "$content" | grep -Eio '(unsubscribe|opt.out|manage.preferences|email.preferences)' | wc -l | tr -d ' ')
    if [[ "$unsub_links" -gt 0 ]]; then
        print_success "Unsubscribe/opt-out link found"
    else
        print_error "No unsubscribe link found (CAN-SPAM requirement)"
        score=$((score > 0 ? score - 1 : 0))
    fi

    # Check link count (too many triggers spam filters)
    if [[ "$link_count" -gt 20 ]]; then
        print_warning "High link count: $link_count (over 20 may trigger spam filters)"
    fi

    # Report UTM parameters
    local utm_links
    utm_links=$(echo "$content" | grep -ioc 'utm_' || echo "0")
    if [[ "$utm_links" -gt 0 ]]; then
        print_info "UTM tracking parameters found in $utm_links locations"
    fi

    add_content_score "$score" 2
    return 0
}

# Check images in email
check_images() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Image Validation"

    local score=2
    local content
    content=$(cat "$file")

    # Count images
    local img_count
    img_count=$(echo "$content" | grep -ioc '<img[[:space:]]' || echo "0")

    if [[ "$img_count" -eq 0 ]]; then
        print_info "No images found in email"
        add_content_score 2 2
        return 0
    fi

    print_info "Total images found: $img_count"

    # Check for missing alt text (total images minus images with alt)
    local img_with_alt
    img_with_alt=$(echo "$content" | grep -ioc '<img[^>]*alt=' || echo "0")
    local img_no_alt=$((img_count - img_with_alt))
    if [[ "$img_no_alt" -lt 0 ]]; then
        img_no_alt=0
    fi
    if [[ "$img_no_alt" -gt 0 ]]; then
        print_warning "$img_no_alt images missing alt attribute"
        score=$((score - 1))
    fi

    # Check for missing dimensions (total images minus images with width/height)
    local img_with_width
    img_with_width=$(echo "$content" | grep -ioc '<img[^>]*width=' || echo "0")
    local img_with_height
    img_with_height=$(echo "$content" | grep -ioc '<img[^>]*height=' || echo "0")
    local img_no_width=$((img_count - img_with_width))
    local img_no_height=$((img_count - img_with_height))
    if [[ "$img_no_width" -lt 0 ]]; then
        img_no_width=0
    fi
    if [[ "$img_no_height" -lt 0 ]]; then
        img_no_height=0
    fi
    if [[ "$img_no_width" -gt 0 || "$img_no_height" -gt 0 ]]; then
        print_warning "Images missing dimensions: $img_no_width without width, $img_no_height without height"
        print_info "Missing dimensions cause layout shift when images load"
    fi

    # Count external images
    local external_imgs
    external_imgs=$(echo "$content" | grep -Eio 'src=["'"'"']https?://' | wc -l | tr -d ' ')
    print_info "External images: $external_imgs of $img_count"

    # Estimate image-to-text ratio (rough heuristic)
    local text_length
    # Strip all HTML tags and count remaining text
    text_length=$(echo "$content" | sed 's/<[^>]*>//g' | tr -s '[:space:]' | wc -c | tr -d ' ')
    local total_length
    total_length=$(echo "$content" | wc -c | tr -d ' ')

    if [[ "$total_length" -gt 0 ]]; then
        local text_pct=$(( (text_length * 100) / total_length ))
        if [[ "$text_pct" -lt 40 ]]; then
            print_warning "Low text-to-HTML ratio: ${text_pct}% (image-heavy emails may trigger spam filters)"
            score=$((score > 0 ? score - 1 : 0))
        else
            print_info "Text-to-HTML ratio: ${text_pct}%"
        fi
    fi

    # Check file size (Gmail clips at 102KB)
    local file_size
    file_size=$(wc -c < "$file" | tr -d ' ')
    local file_size_kb=$(( file_size / 1024 ))
    if [[ "$file_size_kb" -gt 102 ]]; then
        print_error "Email HTML is ${file_size_kb}KB (Gmail clips emails over 102KB)"
        score=$((score > 0 ? score - 1 : 0))
    elif [[ "$file_size_kb" -gt 80 ]]; then
        print_warning "Email HTML is ${file_size_kb}KB (approaching Gmail's 102KB clip limit)"
    else
        print_success "Email HTML size: ${file_size_kb}KB (under Gmail's 102KB limit)"
    fi

    add_content_score "$score" 2
    return 0
}

# Check for spam trigger words in email body
check_spam_words() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Spam Word Scan"

    local content
    # Strip HTML tags for text analysis
    content=$(sed 's/<[^>]*>//g' "$file" | tr '[:upper:]' '[:lower:]')

    local score=1
    local high_risk_count=0
    local medium_risk_count=0

    # High-risk spam words (commonly trigger filters)
    local high_risk_words
    high_risk_words="act now limited time buy now order now no obligation risk free winner congratulations urgent cash guarantee double your earn money no cost"

    for phrase in "act now" "limited time" "buy now" "order now" "no obligation" "risk free" "winner" "congratulations" "urgent" "cash" "guarantee" "double your" "earn money" "no cost"; do
        local count
        count=$(echo "$content" | grep -io "$phrase" | wc -l | tr -d ' ')
        if [[ "$count" -gt 0 ]]; then
            print_warning "High-risk spam phrase: '$phrase' (found $count times)"
            high_risk_count=$((high_risk_count + count))
        fi
    done

    # Medium-risk words
    for phrase in "dear friend" "once in a lifetime" "as seen on" "special promotion" "100% free" "click below" "apply now" "no questions asked"; do
        local count
        count=$(echo "$content" | grep -io "$phrase" | wc -l | tr -d ' ')
        if [[ "$count" -gt 0 ]]; then
            print_info "Medium-risk spam phrase: '$phrase' (found $count times)"
            medium_risk_count=$((medium_risk_count + count))
        fi
    done

    if [[ "$high_risk_count" -eq 0 && "$medium_risk_count" -eq 0 ]]; then
        print_success "No spam trigger words detected"
    else
        print_info "High-risk phrases: $high_risk_count, Medium-risk phrases: $medium_risk_count"
        if [[ "$high_risk_count" -gt 3 ]]; then
            score=0
        fi
    fi

    add_content_score "$score" 1
    return 0
}

# Run all content checks on an HTML email file
check_content() {
    local file="$1"
    validate_html_file "$file" || return 1

    print_header "Content Precheck for $file"
    echo ""

    # Reset content score
    CONTENT_SCORE=0
    CONTENT_MAX=0

    check_subject "$file" || true
    check_preheader "$file" || true
    check_accessibility "$file" || true
    check_links "$file" || true
    check_images "$file" || true
    check_spam_words "$file" || true

    # Print content score summary
    print_content_score_summary "$file"

    return 0
}

# Print content score summary
print_content_score_summary() {
    local file="$1"

    print_header "Content Score for $file"
    echo ""

    if [[ "$CONTENT_MAX" -eq 0 ]]; then
        print_warning "No content checks were scored"
        return 0
    fi

    local percentage=$(( (CONTENT_SCORE * 100) / CONTENT_MAX ))
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

    echo "  Score: $CONTENT_SCORE / $CONTENT_MAX ($percentage%)"
    echo "  Grade: $grade"
    echo ""

    case "$grade" in
        "A")
            print_success "Excellent content quality - ready to send"
            ;;
        "B")
            print_success "Good content quality - minor improvements possible"
            ;;
        "C")
            print_warning "Fair content quality - review flagged issues before sending"
            ;;
        "D")
            print_warning "Poor content quality - significant issues need attention"
            ;;
        "F")
            print_error "Critical content issues - do not send without fixing"
            ;;
    esac

    echo ""
    print_info "Score breakdown: Subject(2) + Preheader(1) + Accessibility(2)"
    print_info "  + Links(2) + Images(2) + Spam Words(1) = 10 max"

    return 0
}

# Combined precheck: infrastructure + content
check_precheck() {
    local domain="$1"
    local file="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain required for precheck"
        return 1
    fi
    if [[ -z "$file" ]]; then
        print_error "HTML file required for precheck"
        print_info "Usage: $0 precheck <domain> <html-file>"
        return 1
    fi

    print_header "Full Email Precheck: $domain + $file"
    echo ""

    # Run infrastructure checks
    check_full "$domain"

    local infra_score="$HEALTH_SCORE"
    local infra_max="$HEALTH_MAX"

    # Run content checks
    echo ""
    check_content "$file"

    # Print combined summary
    print_header "Combined Precheck Summary"
    echo ""

    local combined_score=$((infra_score + CONTENT_SCORE))
    local combined_max=$((infra_max + CONTENT_MAX))

    if [[ "$combined_max" -eq 0 ]]; then
        print_warning "No checks were scored"
        return 0
    fi

    local infra_pct=0
    if [[ "$infra_max" -gt 0 ]]; then
        infra_pct=$(( (infra_score * 100) / infra_max ))
    fi
    local content_pct=0
    if [[ "$CONTENT_MAX" -gt 0 ]]; then
        content_pct=$(( (CONTENT_SCORE * 100) / CONTENT_MAX ))
    fi
    local combined_pct=$(( (combined_score * 100) / combined_max ))

    local combined_grade
    if [[ "$combined_pct" -ge 90 ]]; then
        combined_grade="A"
    elif [[ "$combined_pct" -ge 80 ]]; then
        combined_grade="B"
    elif [[ "$combined_pct" -ge 70 ]]; then
        combined_grade="C"
    elif [[ "$combined_pct" -ge 60 ]]; then
        combined_grade="D"
    else
        combined_grade="F"
    fi

    echo "  Infrastructure: $infra_score/$infra_max ($infra_pct%)"
    echo "  Content:        $CONTENT_SCORE/$CONTENT_MAX ($content_pct%)"
    echo "  Combined:       $combined_score/$combined_max ($combined_pct%) - Grade: $combined_grade"

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
    print_info "For email accessibility audit: $0 accessibility <html-file>"
    
    return 0
}

# Email accessibility check (delegates to accessibility-helper.sh)
check_email_accessibility() {
    local html_file="$1"

    print_header "Email Accessibility Check"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local a11y_helper="${SCRIPT_DIR}/accessibility-helper.sh"
    if [[ -x "$a11y_helper" ]]; then
        "$a11y_helper" email "$html_file"
        local exit_code=$?

        print_header "Accessibility Next Steps"
        print_info "For contrast ratio checks: accessibility-helper.sh contrast '#fg' '#bg'"
        print_info "For design rendering tests: email-test-suite-helper.sh test-design $html_file"
        print_info "For full web accessibility audit: accessibility-helper.sh audit <url>"

        return $exit_code
    else
        print_error "accessibility-helper.sh not found at: $a11y_helper"
        print_info "Run email accessibility checks manually with: accessibility-helper.sh email $html_file"
        return 1
    fi
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
    echo "Infrastructure Commands (domain checks):"
    echo "  check [domain]              Full infrastructure health check with score"
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
    echo ""
    echo "Content Commands (HTML email file checks):"
    echo "  content-check [file]        Full content precheck with score (all below)"
    echo "  check-subject [file]        Check subject line quality"
    echo "  check-preheader [file]      Check preheader/preview text"
    echo "  check-accessibility [file]  Check email accessibility (alt text, lang, roles)"
    echo "  check-links [file]          Validate links (empty, placeholder, unsubscribe)"
    echo "  check-images [file]         Validate images (alt, dimensions, size, ratio)"
    echo "  check-spam-words [file]     Scan for spam trigger words"
    echo ""
    echo "Combined Commands:"
    echo "  precheck [domain] [file]    Full precheck: infrastructure + content"
    echo "  accessibility [html-file]   Check email HTML accessibility (WCAG 2.1)"
    echo ""
    echo "Other:"
    echo "  mail-tester                 Guide for using mail-tester.com"
    echo "  help                        $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 check example.com                    # Infrastructure check"
    echo "  $0 content-check newsletter.html        # Content check"
    echo "  $0 precheck example.com newsletter.html # Combined check"
    echo "  $0 spf example.com"
    echo "  $0 dkim example.com google"
    echo "  $0 accessibility newsletter.html"
    echo "  $0 check-subject newsletter.html"
    echo "  $0 check-links campaign.html"
    echo ""
    echo "Infrastructure Score (out of 15):"
    echo "  SPF(2) + DKIM(2) + DMARC(3) + MX(1) + Blacklist(2)"
    echo "  + BIMI(1) + MTA-STS(1) + TLS-RPT(1) + DANE(1) + rDNS(1)"
    echo ""
    echo "Content Score (out of 10):"
    echo "  Subject(2) + Preheader(1) + Accessibility(2)"
    echo "  + Links(2) + Images(2) + Spam Words(1)"
    echo ""
    echo "Combined Score (out of 25):"
    echo "  Grade: A(90%+) B(80%+) C(70%+) D(60%+) F(<60%)"
    echo ""
    echo "Dependencies:"
    echo "  Required: dig (usually pre-installed), sed, grep"
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
    echo "  accessibility-helper.sh     WCAG accessibility auditing (web + email)"
    
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local arg2="${2:-}"
    local arg3="${3:-}"
    
    case "$command" in
        # Infrastructure commands
        "check"|"full")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            check_full "$arg2"
            ;;
        "spf")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_spf "$arg2"
            ;;
        "dkim")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dkim "$arg2" "$arg3"
            ;;
        "dmarc")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dmarc "$arg2"
            ;;
        "mx")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_mx "$arg2"
            ;;
        "blacklist"|"bl")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_blacklist "$arg2"
            ;;
        "bimi")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_bimi "$arg2"
            ;;
        "mta-sts"|"mtasts")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_mta_sts "$arg2"
            ;;
        "tls-rpt"|"tlsrpt")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_tls_rpt "$arg2"
            ;;
        "dane"|"tlsa")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_dane "$arg2"
            ;;
        "reverse-dns"|"rdns"|"ptr")
            if [[ -z "$arg2" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_reverse_dns "$arg2"
            ;;
        # Content commands
        "content-check"|"content")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                echo "Usage: $0 content-check <html-file>"
                exit 1
            fi
            check_content "$arg2"
            ;;
        "check-subject")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_subject "$arg2"
            ;;
        "check-preheader")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_preheader "$arg2"
            ;;
        "check-accessibility"|"check-a11y")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_accessibility "$arg2"
            ;;
        "check-links")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_links "$arg2"
            ;;
        "check-images"|"check-imgs")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_images "$arg2"
            ;;
        "check-spam-words"|"check-spam")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_spam_words "$arg2"
            ;;
        # Combined commands
        "precheck")
            if [[ -z "$arg2" ]]; then
                print_error "Domain and HTML file required"
                echo "Usage: $0 precheck <domain> <html-file>"
                exit 1
            fi
            check_precheck "$arg2" "$arg3"
            ;;
        # Accessibility
        "accessibility"|"a11y")
            if [[ -z "$arg2" ]]; then
                print_error "HTML file required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            check_email_accessibility "$arg2"
            ;;
        # Other
        "mail-tester"|"mailtester")
            mail_tester_guide
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            # Assume first arg is domain if it looks like one (contains dot, no file extension)
            if [[ "$command" == *"."* && ! -f "$command" ]]; then
                check_full "$command"
            elif [[ -f "$command" ]]; then
                check_content "$command"
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
