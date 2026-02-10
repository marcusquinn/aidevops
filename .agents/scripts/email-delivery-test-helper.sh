#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Delivery Test Helper Script
# CLI for spam testing, inbox placement analysis, and deliverability diagnostics.
# Complements email-health-check-helper.sh (DNS auth) and email-test-suite-helper.sh
# (design rendering) by focusing on content-level spam signals, provider-specific
# deliverability, seed-list inbox placement, and warm-up guidance.
#
# Usage: email-delivery-test-helper.sh [command] [options]
#
# Dependencies:
#   Required: curl, dig, openssl
#   Optional: swaks (SMTP testing), spamassassin (sa-check), python3 (content analysis)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

init_log_file

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

print_header() {
    local msg="$1"
    echo ""
    echo -e "${BLUE}=== $msg ===${NC}"
    return 0
}

# =============================================================================
# Spam Content Analysis
# =============================================================================

# Analyse email content for spam trigger words and patterns
analyze_spam_content() {
    local input_file="$1"

    print_header "Spam Content Analysis"

    if [[ ! -f "$input_file" ]]; then
        print_error "File not found: $input_file"
        return 1
    fi

    local content
    content=$(cat "$input_file")
    local score=0
    local max_score=100
    local issues=0

    # --- Subject line analysis (if HTML email, extract <title>) ---
    local subject=""
    subject=$(echo "$content" | grep -oiE '<title>[^<]+</title>' | sed 's/<[^>]*>//g' | head -1 || true)

    if [[ -n "$subject" ]]; then
        print_header "Subject Line Analysis"
        echo "  Subject: $subject"

        # ALL CAPS check
        local caps_ratio
        local total_chars
        total_chars=$(echo "$subject" | wc -c | tr -d ' ')
        local upper_chars
        upper_chars=$(echo "$subject" | tr -cd '[:upper:]' | wc -c | tr -d ' ')
        if [[ "$total_chars" -gt 0 ]]; then
            caps_ratio=$(( (upper_chars * 100) / total_chars ))
            if [[ "$caps_ratio" -gt 50 && "$total_chars" -gt 10 ]]; then
                print_warning "Subject is >50% uppercase ($caps_ratio%) - spam trigger"
                score=$((score + 10))
                issues=$((issues + 1))
            fi
        fi

        # Excessive punctuation
        local exclaim_count
        exclaim_count=$(echo "$subject" | tr -cd '!' | wc -c | tr -d ' ')
        if [[ "$exclaim_count" -gt 1 ]]; then
            print_warning "Multiple exclamation marks in subject ($exclaim_count) - spam trigger"
            score=$((score + 5))
            issues=$((issues + 1))
        fi

        local question_count
        question_count=$(echo "$subject" | tr -cd '?' | wc -c | tr -d ' ')
        if [[ "$question_count" -gt 2 ]]; then
            print_warning "Excessive question marks in subject ($question_count)"
            score=$((score + 3))
            issues=$((issues + 1))
        fi

        # Dollar signs / currency
        if echo "$subject" | grep -qiE '[$£€]|free|winner|prize|congratulations'; then
            print_warning "Financial/prize language in subject - high spam trigger"
            score=$((score + 15))
            issues=$((issues + 1))
        fi
    fi

    # --- Body content spam triggers ---
    print_header "Body Content Analysis"

    # High-risk spam phrases
    local -a high_risk_phrases=(
        "act now"
        "buy now"
        "click here"
        "click below"
        "congratulations"
        "dear friend"
        "double your"
        "earn extra cash"
        "free access"
        "free gift"
        "free money"
        "get it now"
        "great offer"
        "guarantee"
        "increase your"
        "incredible deal"
        "limited time"
        "make money"
        "no cost"
        "no obligation"
        "offer expires"
        "once in a lifetime"
        "order now"
        "risk free"
        "special promotion"
        "this isn't spam"
        "urgent"
        "winner"
        "you have been selected"
        "you're a winner"
    )

    local high_risk_found=0
    for phrase in "${high_risk_phrases[@]}"; do
        local count
        count=$(echo "$content" | grep -ciE "$phrase" 2>/dev/null || true)
        count="${count:-0}"
        if [[ "$count" -gt 0 ]]; then
            print_warning "High-risk phrase found: '$phrase' ($count occurrences)"
            high_risk_found=$((high_risk_found + 1))
        fi
    done

    if [[ "$high_risk_found" -gt 0 ]]; then
        score=$((score + high_risk_found * 5))
        issues=$((issues + high_risk_found))
        print_error "$high_risk_found high-risk spam phrases detected"
    else
        print_success "No high-risk spam phrases found"
    fi

    # Medium-risk phrases
    local -a medium_risk_phrases=(
        "as seen on"
        "bargain"
        "bonus"
        "cash"
        "cheap"
        "clearance"
        "compare"
        "discount"
        "don't delete"
        "don't miss"
        "exclusive deal"
        "expires"
        "for free"
        "lowest price"
        "luxury"
        "no catch"
        "no strings"
        "obligation"
        "only \$"
        "opt in"
        "please read"
        "promise"
        "pure profit"
        "satisfaction"
        "save big"
        "sign up free"
        "subscribe"
        "trial"
        "while supplies last"
    )

    local medium_risk_found=0
    for phrase in "${medium_risk_phrases[@]}"; do
        local count
        count=$(echo "$content" | grep -ciE "$phrase" 2>/dev/null || true)
        count="${count:-0}"
        if [[ "$count" -gt 0 ]]; then
            medium_risk_found=$((medium_risk_found + 1))
        fi
    done

    if [[ "$medium_risk_found" -gt 0 ]]; then
        score=$((score + medium_risk_found * 2))
        issues=$((issues + 1))
        print_warning "$medium_risk_found medium-risk phrases detected"
    else
        print_success "No medium-risk spam phrases found"
    fi

    # --- Structural spam signals ---
    print_header "Structural Analysis"

    # Image-to-text ratio
    local img_count
    img_count=$(echo "$content" | grep -ciE '<img' 2>/dev/null || true)
    img_count="${img_count:-0}"
    local text_length
    text_length=$(echo "$content" | sed 's/<[^>]*>//g' | tr -s '[:space:]' | wc -c | tr -d ' ')

    if [[ "$img_count" -gt 0 && "$text_length" -lt 200 ]]; then
        print_warning "Low text-to-image ratio ($text_length chars, $img_count images)"
        print_info "Image-heavy emails with little text are flagged as spam"
        score=$((score + 10))
        issues=$((issues + 1))
    elif [[ "$img_count" -gt 0 ]]; then
        print_success "Text-to-image ratio OK ($text_length chars, $img_count images)"
    fi

    # URL analysis
    local url_count
    url_count=$(echo "$content" | grep -coiE 'https?://' 2>/dev/null || true)
    url_count="${url_count:-0}"
    if [[ "$url_count" -gt 20 ]]; then
        print_warning "Excessive URLs ($url_count) - may trigger spam filters"
        score=$((score + 5))
        issues=$((issues + 1))
    fi

    # Shortened URLs
    local short_url_count
    short_url_count=$(echo "$content" | grep -ciE 'bit\.ly|tinyurl|t\.co|goo\.gl|ow\.ly|is\.gd|buff\.ly' 2>/dev/null || true)
    short_url_count="${short_url_count:-0}"
    if [[ "$short_url_count" -gt 0 ]]; then
        print_warning "URL shorteners detected ($short_url_count) - spam trigger"
        print_info "Use full URLs instead of shortened links"
        score=$((score + 8))
        issues=$((issues + 1))
    fi

    # Hidden text (white text on white, font-size: 0, display: none)
    if echo "$content" | grep -qiE 'color:\s*(#fff|#ffffff|white).*background.*white|font-size:\s*0|display:\s*none.*[a-z]'; then
        print_error "Possible hidden text detected - major spam signal"
        score=$((score + 20))
        issues=$((issues + 1))
    fi

    # JavaScript (should never be in email)
    local js_count
    js_count=$(echo "$content" | grep -ciE '<script|javascript:' 2>/dev/null || true)
    js_count="${js_count:-0}"
    if [[ "$js_count" -gt 0 ]]; then
        print_error "JavaScript detected ($js_count) - will be stripped and may trigger spam"
        score=$((score + 15))
        issues=$((issues + 1))
    fi

    # Form elements
    if echo "$content" | grep -qiE '<form|<input|<select|<textarea'; then
        print_warning "Form elements detected - not supported in most email clients"
        score=$((score + 5))
        issues=$((issues + 1))
    fi

    # Unsubscribe link check
    if ! echo "$content" | grep -qi 'unsubscribe'; then
        print_error "No unsubscribe link found - required for marketing emails"
        print_info "Missing unsubscribe is a CAN-SPAM violation and spam trigger"
        score=$((score + 10))
        issues=$((issues + 1))
    else
        print_success "Unsubscribe link found"
    fi

    # Physical address check (CAN-SPAM requirement)
    if ! echo "$content" | grep -qiE '[0-9]+\s+[A-Za-z]+\s+(street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|way|court|ct|suite|ste)'; then
        print_warning "No physical address detected - required by CAN-SPAM"
        score=$((score + 5))
        issues=$((issues + 1))
    else
        print_success "Physical address detected"
    fi

    # --- Score summary ---
    print_header "Spam Score Summary"
    echo ""

    # Invert: lower is better (0 = clean, 100 = definitely spam)
    if [[ "$score" -gt "$max_score" ]]; then
        score="$max_score"
    fi

    local rating
    if [[ "$score" -le 10 ]]; then
        rating="CLEAN"
        print_success "Score: $score/$max_score - $rating"
        print_success "Content is unlikely to trigger spam filters"
    elif [[ "$score" -le 25 ]]; then
        rating="LOW RISK"
        print_success "Score: $score/$max_score - $rating"
        print_info "Minor issues found - should pass most filters"
    elif [[ "$score" -le 50 ]]; then
        rating="MEDIUM RISK"
        print_warning "Score: $score/$max_score - $rating"
        print_warning "Content may trigger spam filters in some providers"
    elif [[ "$score" -le 75 ]]; then
        rating="HIGH RISK"
        print_error "Score: $score/$max_score - $rating"
        print_error "Content is likely to be flagged as spam"
    else
        rating="CRITICAL"
        print_error "Score: $score/$max_score - $rating"
        print_error "Content will almost certainly be flagged as spam"
    fi

    echo ""
    echo "  Issues found: $issues"
    echo ""
    print_info "Lower score = better deliverability (0 = clean, 100 = spam)"

    return 0
}

# Run SpamAssassin check if available
check_spamassassin() {
    local input_file="$1"

    print_header "SpamAssassin Analysis"

    if ! command -v spamassassin >/dev/null 2>&1; then
        print_info "SpamAssassin not installed"
        print_info "Install with: brew install spamassassin (macOS) or apt install spamassassin (Linux)"
        print_info "Using built-in content analysis instead"
        analyze_spam_content "$input_file"
        return $?
    fi

    if [[ ! -f "$input_file" ]]; then
        print_error "File not found: $input_file"
        return 1
    fi

    print_info "Running SpamAssassin analysis..."
    local sa_output
    sa_output=$(spamassassin -t < "$input_file" 2>/dev/null || true)

    if [[ -z "$sa_output" ]]; then
        print_warning "SpamAssassin returned no output"
        print_info "Falling back to built-in analysis"
        analyze_spam_content "$input_file"
        return $?
    fi

    # Extract score
    local sa_score
    sa_score=$(echo "$sa_output" | grep -oE 'X-Spam-Status:.*score=[0-9.-]+' | grep -oE '[0-9.-]+$' || true)
    if [[ -n "$sa_score" ]]; then
        echo "  SpamAssassin Score: $sa_score"
        echo "  (Threshold: 5.0 — below = ham, above = spam)"
    fi

    # Extract rules that fired
    local rules
    rules=$(echo "$sa_output" | grep -A 100 'Content analysis details:' | grep -E '^\s+[0-9.-]+' || true)
    if [[ -n "$rules" ]]; then
        print_header "Rules Triggered"
        echo "$rules" | head -20
    fi

    return 0
}

# =============================================================================
# Provider-Specific Deliverability
# =============================================================================

# Check Gmail-specific deliverability factors
check_gmail_deliverability() {
    local domain="$1"

    print_header "Gmail Deliverability Check: $domain"

    local score=0
    local max_score=8

    # 1. SPF alignment
    local spf_record
    spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)
    if [[ -n "$spf_record" && ("$spf_record" == *"-all"* || "$spf_record" == *"~all"*) ]]; then
        print_success "SPF: Configured with enforcement"
        score=$((score + 1))
    else
        print_error "SPF: Missing or weak — Gmail requires SPF"
    fi

    # 2. DKIM
    local dkim_found=false
    for sel in google google1 google2 selector1 selector2 k1 s1 default dkim; do
        local dkim_record
        dkim_record=$(dig TXT "${sel}._domainkey.${domain}" +short 2>/dev/null | tr -d '"' || true)
        if [[ -n "$dkim_record" && "$dkim_record" != *"NXDOMAIN"* ]]; then
            dkim_found=true
            break
        fi
    done
    if [[ "$dkim_found" == true ]]; then
        print_success "DKIM: Valid selector found"
        score=$((score + 1))
    else
        print_error "DKIM: No valid selector — Gmail requires DKIM"
    fi

    # 3. DMARC (Gmail requires p=quarantine or p=reject for bulk senders since Feb 2024)
    local dmarc_record
    dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$dmarc_record" ]]; then
        if [[ "$dmarc_record" == *"p=reject"* || "$dmarc_record" == *"p=quarantine"* ]]; then
            print_success "DMARC: Enforcing policy (Gmail bulk sender requirement met)"
            score=$((score + 2))
        elif [[ "$dmarc_record" == *"p=none"* ]]; then
            print_warning "DMARC: p=none — Gmail requires p=quarantine+ for bulk senders (>5000/day)"
            score=$((score + 1))
        fi
    else
        print_error "DMARC: Not configured — required by Gmail since Feb 2024"
    fi

    # 4. List-Unsubscribe (Gmail requires one-click unsubscribe since Feb 2024)
    print_info "Gmail requires List-Unsubscribe + List-Unsubscribe-Post headers"
    print_info "Verify by checking email headers after sending a test"
    score=$((score + 1))

    # 5. PTR record
    local mx_host
    mx_host=$(dig MX "$domain" +short 2>/dev/null | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
    if [[ -n "$mx_host" ]]; then
        local mx_ip
        mx_ip=$(dig A "$mx_host" +short 2>/dev/null | head -1 || true)
        if [[ -n "$mx_ip" ]]; then
            local ptr
            ptr=$(dig -x "$mx_ip" +short 2>/dev/null | sed 's/\.$//' || true)
            if [[ -n "$ptr" ]]; then
                print_success "PTR: Reverse DNS configured for mail server"
                score=$((score + 1))
            else
                print_warning "PTR: No reverse DNS for $mx_ip"
            fi
        fi
    fi

    # 6. Google Postmaster Tools
    print_info "Enrol in Google Postmaster Tools for reputation monitoring:"
    print_info "  https://postmaster.google.com"
    score=$((score + 1))

    # 7. ARC (Authenticated Received Chain) — bonus for forwarding scenarios
    print_info "ARC headers help with forwarding deliverability (optional)"
    score=$((score + 1))

    # Score
    print_header "Gmail Deliverability Score"
    echo "  Score: $score / $max_score"
    echo ""

    if [[ "$score" -ge 7 ]]; then
        print_success "Excellent Gmail deliverability expected"
    elif [[ "$score" -ge 5 ]]; then
        print_success "Good Gmail deliverability — minor improvements possible"
    elif [[ "$score" -ge 3 ]]; then
        print_warning "Fair — some emails may go to Gmail spam"
    else
        print_error "Poor — significant Gmail deliverability issues"
    fi

    echo ""
    print_info "Gmail bulk sender requirements (Feb 2024):"
    echo "  - SPF + DKIM + DMARC (p=quarantine or p=reject)"
    echo "  - One-click unsubscribe (List-Unsubscribe-Post header)"
    echo "  - Spam rate < 0.3% in Google Postmaster Tools"
    echo "  - Valid PTR records for sending IPs"

    return 0
}

# Check Microsoft/Outlook-specific deliverability
check_outlook_deliverability() {
    local domain="$1"

    print_header "Microsoft/Outlook Deliverability Check: $domain"

    local score=0
    local max_score=7

    # 1. SPF
    local spf_record
    spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)
    if [[ -n "$spf_record" ]]; then
        print_success "SPF: Configured"
        score=$((score + 1))
    else
        print_error "SPF: Not configured"
    fi

    # 2. DKIM
    local dkim_found=false
    for sel in selector1 selector2 google k1 s1 default dkim; do
        local dkim_record
        dkim_record=$(dig TXT "${sel}._domainkey.${domain}" +short 2>/dev/null | tr -d '"' || true)
        if [[ -n "$dkim_record" && "$dkim_record" != *"NXDOMAIN"* ]]; then
            dkim_found=true
            break
        fi
    done
    if [[ "$dkim_found" == true ]]; then
        print_success "DKIM: Valid selector found"
        score=$((score + 1))
    else
        print_error "DKIM: No valid selector found"
    fi

    # 3. DMARC
    local dmarc_record
    dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$dmarc_record" ]]; then
        if [[ "$dmarc_record" == *"p=reject"* || "$dmarc_record" == *"p=quarantine"* ]]; then
            print_success "DMARC: Enforcing policy"
            score=$((score + 2))
        else
            print_warning "DMARC: p=none (monitoring only)"
            score=$((score + 1))
        fi
    else
        print_error "DMARC: Not configured"
    fi

    # 4. MTA-STS (Microsoft supports this)
    local mta_sts
    mta_sts=$(dig TXT "_mta-sts.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$mta_sts" && "$mta_sts" == *"v=STSv1"* ]]; then
        print_success "MTA-STS: Configured"
        score=$((score + 1))
    else
        print_info "MTA-STS: Not configured (recommended for Outlook)"
    fi

    # 5. Blacklist check (Spamhaus)
    local domain_ip
    domain_ip=$(dig A "$domain" +short 2>/dev/null | head -1 || true)
    if [[ -n "$domain_ip" ]]; then
        local reversed_ip
        reversed_ip=$(echo "$domain_ip" | awk -F. '{print $4"."$3"."$2"."$1}')
        local bl_result
        bl_result=$(dig A "${reversed_ip}.zen.spamhaus.org" +short 2>/dev/null || true)
        if [[ -z "$bl_result" || "$bl_result" == *"NXDOMAIN"* ]]; then
            print_success "Blacklist: Clean on Spamhaus"
            score=$((score + 1))
        else
            print_error "Blacklist: Listed on Spamhaus — will affect Outlook delivery"
        fi
    fi

    # 6. SNDS enrolment
    print_info "Enrol in Microsoft SNDS for reputation monitoring:"
    print_info "  https://sendersupport.olc.protection.outlook.com/snds/"
    score=$((score + 1))

    # Score
    print_header "Outlook Deliverability Score"
    echo "  Score: $score / $max_score"
    echo ""

    if [[ "$score" -ge 6 ]]; then
        print_success "Excellent Outlook deliverability expected"
    elif [[ "$score" -ge 4 ]]; then
        print_success "Good Outlook deliverability"
    elif [[ "$score" -ge 3 ]]; then
        print_warning "Fair — some emails may go to Outlook junk"
    else
        print_error "Poor — significant Outlook deliverability issues"
    fi

    echo ""
    print_info "Microsoft Outlook tips:"
    echo "  - Register with SNDS and JMRP (Junk Mail Reporting Program)"
    echo "  - Maintain consistent sending volume"
    echo "  - Keep complaint rate below 0.1%"
    echo "  - Use dedicated IPs for high-volume sending"

    return 0
}

# Check Yahoo/AOL deliverability
check_yahoo_deliverability() {
    local domain="$1"

    print_header "Yahoo/AOL Deliverability Check: $domain"

    local score=0
    local max_score=5

    # 1. SPF
    local spf_record
    spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)
    if [[ -n "$spf_record" ]]; then
        print_success "SPF: Configured"
        score=$((score + 1))
    else
        print_error "SPF: Not configured — Yahoo requires SPF"
    fi

    # 2. DKIM
    local dkim_found=false
    for sel in google selector1 k1 s1 default dkim; do
        local dkim_record
        dkim_record=$(dig TXT "${sel}._domainkey.${domain}" +short 2>/dev/null | tr -d '"' || true)
        if [[ -n "$dkim_record" && "$dkim_record" != *"NXDOMAIN"* ]]; then
            dkim_found=true
            break
        fi
    done
    if [[ "$dkim_found" == true ]]; then
        print_success "DKIM: Valid selector found"
        score=$((score + 1))
    else
        print_error "DKIM: No valid selector — Yahoo requires DKIM"
    fi

    # 3. DMARC (Yahoo enforces strictly since Feb 2024)
    local dmarc_record
    dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$dmarc_record" ]]; then
        if [[ "$dmarc_record" == *"p=reject"* || "$dmarc_record" == *"p=quarantine"* ]]; then
            print_success "DMARC: Enforcing policy (Yahoo requirement met)"
            score=$((score + 2))
        else
            print_warning "DMARC: p=none — Yahoo requires enforcement for bulk senders"
            score=$((score + 1))
        fi
    else
        print_error "DMARC: Not configured — required by Yahoo since Feb 2024"
    fi

    # 4. One-click unsubscribe
    print_info "Yahoo requires one-click unsubscribe (List-Unsubscribe-Post)"
    print_info "Verify by checking email headers after sending a test"
    score=$((score + 1))

    # Score
    print_header "Yahoo/AOL Deliverability Score"
    echo "  Score: $score / $max_score"
    echo ""

    if [[ "$score" -ge 4 ]]; then
        print_success "Good Yahoo/AOL deliverability expected"
    elif [[ "$score" -ge 3 ]]; then
        print_warning "Fair — some emails may be filtered"
    else
        print_error "Poor — significant Yahoo/AOL deliverability issues"
    fi

    echo ""
    print_info "Yahoo/AOL requirements (Feb 2024):"
    echo "  - SPF + DKIM + DMARC (p=quarantine or p=reject)"
    echo "  - One-click unsubscribe"
    echo "  - Spam complaint rate < 0.3%"

    return 0
}

# Run all provider checks
check_all_providers() {
    local domain="$1"

    print_header "Multi-Provider Deliverability Analysis: $domain"

    check_gmail_deliverability "$domain"
    echo ""
    check_outlook_deliverability "$domain"
    echo ""
    check_yahoo_deliverability "$domain"

    print_header "Provider Summary"
    echo ""
    print_info "For comprehensive testing, send test emails to seed addresses at each provider"
    print_info "Use: $0 seed-test $domain"

    return 0
}

# =============================================================================
# Seed-List Inbox Placement Testing
# =============================================================================

# Guide for seed-list inbox placement testing
seed_test_guide() {
    local domain="${1:-}"

    print_header "Seed-List Inbox Placement Testing"
    echo ""
    print_info "Seed testing sends emails to test addresses across providers"
    print_info "to verify inbox vs spam placement."
    echo ""

    echo "Manual Seed Test Process:"
    echo ""
    echo "  1. Create test accounts at major providers:"
    echo "     - Gmail (gmail.com)"
    echo "     - Outlook (outlook.com / hotmail.com)"
    echo "     - Yahoo (yahoo.com)"
    echo "     - iCloud (icloud.com)"
    echo "     - ProtonMail (protonmail.com)"
    echo ""
    echo "  2. Send identical test emails from your domain to each"
    echo ""
    echo "  3. Check placement at each provider:"
    echo "     - Inbox (primary/focused tab)"
    echo "     - Promotions/Other tab"
    echo "     - Spam/Junk folder"
    echo "     - Not delivered"
    echo ""
    echo "  4. Record results and compare over time"
    echo ""

    print_header "Automated Seed Testing Services"
    echo ""
    echo "  Service             | Free Tier | URL"
    echo "  --------------------|-----------|----"
    echo "  mail-tester.com     | 3/day     | https://mail-tester.com"
    echo "  GlockApps           | 3/month   | https://glockapps.com"
    echo "  Mailtrap            | 100/month | https://mailtrap.io"
    echo "  Mailreach           | Trial     | https://mailreach.co"
    echo "  InboxAlly           | Trial     | https://inboxally.com"
    echo "  Warmup Inbox        | Trial     | https://warmupinbox.com"
    echo ""

    if [[ -n "$domain" ]]; then
        print_header "Quick Seed Test for $domain"
        echo ""
        print_info "Send a test email from $domain to each of these addresses:"
        echo ""
        echo "  1. Your Gmail test account"
        echo "  2. Your Outlook test account"
        echo "  3. mail-tester.com (get address from website)"
        echo ""
        print_info "Then run: $0 providers $domain"
        print_info "to verify DNS configuration supports delivery"
    fi

    return 0
}

# =============================================================================
# SMTP Send Test (using swaks or openssl)
# =============================================================================

# Send a test email via SMTP
send_test_email() {
    local from_email="$1"
    local to_email="$2"
    local smtp_server="${3:-}"
    local smtp_port="${4:-587}"

    print_header "SMTP Send Test"

    if [[ -z "$from_email" || -z "$to_email" ]]; then
        print_error "Usage: $0 send-test <from> <to> [smtp-server] [port]"
        return 1
    fi

    # Auto-discover SMTP server from domain if not provided
    if [[ -z "$smtp_server" ]]; then
        local from_domain
        from_domain=$(echo "$from_email" | cut -d@ -f2)
        local mx_host
        mx_host=$(dig MX "$from_domain" +short 2>/dev/null | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
        if [[ -n "$mx_host" ]]; then
            smtp_server="$mx_host"
            print_info "Auto-discovered SMTP server: $smtp_server"
        else
            print_error "Could not auto-discover SMTP server for $from_domain"
            print_info "Specify server: $0 send-test $from_email $to_email smtp.example.com"
            return 1
        fi
    fi

    # Prefer swaks if available
    if command -v swaks >/dev/null 2>&1; then
        print_info "Using swaks for SMTP test..."
        local subject
        subject="Deliverability Test - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local body
        body="This is a deliverability test email sent from $from_email at $(date -u).\n\nIf you received this in your inbox, deliverability is working.\nIf this is in spam/junk, check your DNS authentication.\n\nSent via: email-delivery-test-helper.sh"

        swaks \
            --to "$to_email" \
            --from "$from_email" \
            --server "$smtp_server" \
            --port "$smtp_port" \
            --tls \
            --header "Subject: $subject" \
            --header "List-Unsubscribe: <mailto:unsubscribe@$(echo "$from_email" | cut -d@ -f2)>" \
            --header "List-Unsubscribe-Post: List-Unsubscribe=One-Click" \
            --body "$body" \
            2>&1 || {
                print_error "swaks send failed"
                return 1
            }

        print_success "Test email sent via swaks"
        print_info "Check the recipient's inbox/spam folder"
    else
        print_info "swaks not installed — using openssl for basic SMTP test"
        print_info "Install swaks for full send testing: brew install swaks (macOS)"
        echo ""

        # Basic SMTP connectivity test
        print_info "Testing SMTP connectivity to $smtp_server:$smtp_port..."
        if timeout 10 nc -z "$smtp_server" "$smtp_port" 2>/dev/null; then
            print_success "SMTP server reachable at $smtp_server:$smtp_port"
        else
            print_error "Cannot connect to $smtp_server:$smtp_port"
            return 1
        fi

        # STARTTLS test
        local tls_result
        tls_result=$(echo "EHLO test.local" | timeout 10 openssl s_client -starttls smtp -connect "$smtp_server:$smtp_port" 2>&1 | head -3 || true)
        if [[ "$tls_result" == *"CONNECTED"* ]]; then
            print_success "STARTTLS supported"
        else
            print_warning "STARTTLS may not be supported"
        fi

        echo ""
        print_info "To send a full test email, install swaks:"
        echo "  brew install swaks    # macOS"
        echo "  apt install swaks     # Debian/Ubuntu"
        echo ""
        echo "Then run:"
        echo "  $0 send-test $from_email $to_email $smtp_server $smtp_port"
    fi

    return 0
}

# =============================================================================
# IP/Domain Warm-Up Guidance
# =============================================================================

# Provide warm-up schedule and guidance
warmup_guide() {
    local domain="${1:-}"

    print_header "IP/Domain Warm-Up Guide"
    echo ""
    print_info "New IPs and domains need gradual volume increases to build reputation."
    print_info "Sending too much too fast triggers spam filters."
    echo ""

    print_header "Recommended Warm-Up Schedule"
    echo ""
    echo "  Day  | Daily Volume | Notes"
    echo "  -----|-------------|------"
    echo "  1-2  |          50 | Send to most engaged contacts only"
    echo "  3-4  |         100 | Monitor bounce/complaint rates"
    echo "  5-6  |         250 | Check Google Postmaster Tools"
    echo "  7-8  |         500 | Review inbox placement"
    echo "  9-10 |       1,000 | Expand to broader audience"
    echo "  11-14|       2,500 | Continue monitoring"
    echo "  15-21|       5,000 | Steady increase"
    echo "  22-28|      10,000 | Approaching normal volume"
    echo "  29+  |      25,000+| Full volume (if metrics are healthy)"
    echo ""

    print_header "Warm-Up Best Practices"
    echo ""
    echo "  1. Start with your most engaged subscribers (recent openers/clickers)"
    echo "  2. Send consistent volumes daily (don't skip days)"
    echo "  3. Monitor key metrics at each stage:"
    echo "     - Bounce rate: keep below 2%"
    echo "     - Spam complaint rate: keep below 0.1%"
    echo "     - Open rate: should be above 20%"
    echo "  4. If metrics degrade, reduce volume and investigate"
    echo "  5. Use dedicated IPs for marketing vs transactional email"
    echo "  6. Authenticate everything: SPF + DKIM + DMARC"
    echo ""

    print_header "Warm-Up Services"
    echo ""
    echo "  Service         | Type       | URL"
    echo "  ----------------|------------|----"
    echo "  Warmup Inbox    | Automated  | https://warmupinbox.com"
    echo "  Mailreach       | Automated  | https://mailreach.co"
    echo "  InboxAlly       | Automated  | https://inboxally.com"
    echo "  Lemwarm         | Automated  | https://lemwarm.com"
    echo "  Instantly       | Automated  | https://instantly.ai"
    echo ""

    if [[ -n "$domain" ]]; then
        print_header "Current Status for $domain"
        echo ""

        # Quick DNS check
        local spf
        spf=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" || true)
        local dmarc
        dmarc=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null || true)

        if [[ -n "$spf" ]]; then
            print_success "SPF configured — ready for warm-up"
        else
            print_error "SPF not configured — set up before warm-up"
        fi

        if [[ -n "$dmarc" ]]; then
            print_success "DMARC configured — ready for warm-up"
        else
            print_error "DMARC not configured — set up before warm-up"
        fi

        echo ""
        print_info "Run full check: $0 providers $domain"
    fi

    return 0
}

# =============================================================================
# Comprehensive Deliverability Report
# =============================================================================

# Generate a full deliverability report
full_report() {
    local domain="$1"

    print_header "Full Deliverability Report: $domain"
    echo "  Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # DNS Authentication
    print_header "1. DNS Authentication"
    local health_script="$SCRIPT_DIR/email-health-check-helper.sh"
    if [[ -x "$health_script" ]]; then
        "$health_script" check "$domain" 2>/dev/null || true
    else
        print_info "Run: email-health-check-helper.sh check $domain"
    fi

    echo ""

    # Provider-specific checks
    print_header "2. Provider Deliverability"
    check_gmail_deliverability "$domain"
    echo ""
    check_outlook_deliverability "$domain"
    echo ""
    check_yahoo_deliverability "$domain"

    echo ""

    # Recommendations
    print_header "3. Recommendations"
    echo ""
    echo "  Next steps:"
    echo "  1. Fix any DNS authentication issues above"
    echo "  2. Send test emails to seed addresses at each provider"
    echo "  3. Register with monitoring services:"
    echo "     - Google Postmaster Tools: https://postmaster.google.com"
    echo "     - Microsoft SNDS: https://sendersupport.olc.protection.outlook.com/snds/"
    echo "  4. Test content with: $0 spam-check <email.html>"
    echo "  5. If new domain/IP, follow warm-up guide: $0 warmup $domain"
    echo ""

    print_info "For design rendering tests: email-test-suite-helper.sh test-design <file>"
    print_info "For DNS health check: email-health-check-helper.sh check $domain"

    return 0
}

# =============================================================================
# Help and Main
# =============================================================================

show_help() {
    echo "Email Delivery Test Helper Script"
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Spam Content Analysis:"
    echo "  spam-check [file]             Analyse email content for spam triggers"
    echo "  spamassassin [file]           Run SpamAssassin analysis (if installed)"
    echo ""
    echo "Provider Deliverability:"
    echo "  gmail [domain]                Check Gmail-specific deliverability"
    echo "  outlook [domain]              Check Outlook-specific deliverability"
    echo "  yahoo [domain]                Check Yahoo/AOL deliverability"
    echo "  providers [domain]            Check all major providers"
    echo ""
    echo "Inbox Placement:"
    echo "  seed-test [domain]            Seed-list inbox placement testing guide"
    echo "  send-test [from] [to] [smtp]  Send test email via SMTP"
    echo ""
    echo "Warm-Up & Reputation:"
    echo "  warmup [domain]               IP/domain warm-up schedule and guidance"
    echo ""
    echo "Reports:"
    echo "  report [domain]               Full deliverability report"
    echo ""
    echo "General:"
    echo "  help                          $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 spam-check newsletter.html"
    echo "  $0 gmail example.com"
    echo "  $0 providers example.com"
    echo "  $0 seed-test example.com"
    echo "  $0 send-test me@example.com test@gmail.com smtp.example.com 587"
    echo "  $0 warmup example.com"
    echo "  $0 report example.com"
    echo ""
    echo "Dependencies:"
    echo "  Required: curl, dig, openssl, nc"
    echo "  Optional: swaks (SMTP send), spamassassin (content analysis)"
    echo ""
    echo "Related:"
    echo "  email-health-check-helper.sh  DNS authentication checks (SPF/DKIM/DMARC)"
    echo "  email-test-suite-helper.sh    Design rendering and delivery testing"

    return 0
}

main() {
    local command="${1:-help}"
    local arg1="${2:-}"
    local arg2="${3:-}"
    local arg3="${4:-}"
    local arg4="${5:-}"

    case "$command" in
        "spam-check"|"spam"|"content"|"analyze")
            if [[ -z "$arg1" ]]; then
                print_error "Email file required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            analyze_spam_content "$arg1"
            ;;
        "spamassassin"|"sa"|"sa-check")
            if [[ -z "$arg1" ]]; then
                print_error "Email file required"
                exit 1
            fi
            check_spamassassin "$arg1"
            ;;
        "gmail")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_gmail_deliverability "$arg1"
            ;;
        "outlook"|"microsoft"|"hotmail")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_outlook_deliverability "$arg1"
            ;;
        "yahoo"|"aol")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_yahoo_deliverability "$arg1"
            ;;
        "providers"|"all-providers"|"multi")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_all_providers "$arg1"
            ;;
        "seed-test"|"seed"|"placement")
            seed_test_guide "$arg1"
            ;;
        "send-test"|"send")
            send_test_email "$arg1" "$arg2" "$arg3" "$arg4"
            ;;
        "warmup"|"warm-up"|"warm")
            warmup_guide "$arg1"
            ;;
        "report"|"full"|"full-report")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            full_report "$arg1"
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            # Assume first arg is domain if it looks like one
            if [[ "$command" == *"."* ]]; then
                full_report "$command"
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
