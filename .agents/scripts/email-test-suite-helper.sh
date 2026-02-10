#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Test Suite Helper Script
# Comprehensive email testing: design rendering validation, delivery testing,
# SMTP connectivity, header analysis, and inbox placement checks.
#
# Usage: email-test-suite-helper.sh [command] [options]
#
# Dependencies:
#   Required: curl, dig, openssl
#   Optional: html-validate (npm), mjml (npm), litmus-cli, email-on-acid

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

# Email client rendering engines
readonly EMAIL_CLIENTS_WEBKIT="Apple Mail, iOS Mail, Outlook macOS"
readonly EMAIL_CLIENTS_BLINK="Gmail Web, Gmail Android"
readonly EMAIL_CLIENTS_WORD="Outlook 2016+, Outlook 365"
readonly EMAIL_CLIENTS_CUSTOM="Yahoo Mail, AOL Mail, Thunderbird"

# CSS property support matrix (properties that commonly break)
readonly CSS_UNSUPPORTED_OUTLOOK="position, float, max-width, background-image (in some contexts), flexbox, grid, border-radius (on images)"
readonly CSS_UNSUPPORTED_GMAIL="style blocks in head (non-inlined), media queries (partially), custom fonts"
readonly CSS_UNSUPPORTED_YAHOO="media queries (partially), animation, transform"

# =============================================================================
# Design Rendering Tests
# =============================================================================

# Validate HTML email structure
validate_html_structure() {
    local html_file="$1"

    print_header "HTML Email Structure Validation"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local issues=0
    local warnings=0

    # Check for DOCTYPE
    if ! grep -qi '<!DOCTYPE' "$html_file"; then
        print_error "Missing DOCTYPE declaration"
        print_info "Add: <!DOCTYPE html>"
        issues=$((issues + 1))
    else
        print_success "DOCTYPE declaration found"
    fi

    # Check for html xmlns
    if ! grep -qi 'xmlns=' "$html_file"; then
        print_warning "Missing xmlns attribute on html tag"
        print_info "Add: xmlns=\"http://www.w3.org/1999/xhtml\" for Outlook compatibility"
        warnings=$((warnings + 1))
    else
        print_success "xmlns attribute found"
    fi

    # Check for meta charset
    if ! grep -qi 'charset' "$html_file"; then
        print_error "Missing charset meta tag"
        print_info "Add: <meta charset=\"UTF-8\">"
        issues=$((issues + 1))
    else
        print_success "Charset declaration found"
    fi

    # Check for meta viewport
    if ! grep -qi 'viewport' "$html_file"; then
        print_warning "Missing viewport meta tag (needed for mobile)"
        print_info "Add: <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
        warnings=$((warnings + 1))
    else
        print_success "Viewport meta tag found"
    fi

    # Check for table-based layout (recommended for email)
    local table_count
    table_count=$(grep -ci '<table' "$html_file" 2>/dev/null || true)
    table_count="${table_count:-0}"
    if [[ "$table_count" -eq 0 ]]; then
        print_warning "No table elements found - table-based layout recommended for email"
        warnings=$((warnings + 1))
    else
        print_success "Table-based layout detected ($table_count tables)"
    fi

    # Check for inline styles vs style blocks
    local style_block_count
    style_block_count=$(grep -ci '<style' "$html_file" 2>/dev/null || true)
    style_block_count="${style_block_count:-0}"
    local inline_style_count
    inline_style_count=$(grep -ci 'style=' "$html_file" 2>/dev/null || true)
    inline_style_count="${inline_style_count:-0}"

    if [[ "$style_block_count" -gt 0 && "$inline_style_count" -eq 0 ]]; then
        print_warning "Style blocks found but no inline styles - Gmail strips <style> blocks"
        print_info "Use CSS inlining tools (juice, premailer) before sending"
        warnings=$((warnings + 1))
    elif [[ "$inline_style_count" -gt 0 ]]; then
        print_success "Inline styles detected ($inline_style_count occurrences)"
    fi

    # Check for images without alt text
    local img_total
    img_total=$(grep -ci '<img' "$html_file" 2>/dev/null || true)
    img_total="${img_total:-0}"
    if [[ "$img_total" -gt 0 ]]; then
        local img_with_alt
        img_with_alt=$(grep -ci 'alt=' "$html_file" 2>/dev/null || true)
        img_with_alt="${img_with_alt:-0}"
        if [[ "$img_with_alt" -lt "$img_total" ]]; then
            print_warning "Some images missing alt text ($img_with_alt/$img_total have alt)"
            warnings=$((warnings + 1))
        else
            print_success "All images have alt text ($img_total images)"
        fi
    fi

    # Check for absolute URLs in images
    local relative_imgs
    relative_imgs=$(grep -ciE 'src="[^h/]' "$html_file" 2>/dev/null || true)
    relative_imgs="${relative_imgs:-0}"
    if [[ "$relative_imgs" -gt 0 ]]; then
        print_error "Relative image URLs found ($relative_imgs) - use absolute URLs"
        issues=$((issues + 1))
    fi

    # Check for unsubscribe link
    if ! grep -qi 'unsubscribe' "$html_file"; then
        print_warning "No unsubscribe link detected (required for marketing emails)"
        warnings=$((warnings + 1))
    else
        print_success "Unsubscribe link found"
    fi

    # Check total file size
    local file_size
    file_size=$(wc -c < "$html_file" | tr -d ' ')
    if [[ "$file_size" -gt 102400 ]]; then
        print_warning "Email HTML is large (${file_size} bytes) - Gmail clips emails >102KB"
        warnings=$((warnings + 1))
    elif [[ "$file_size" -gt 80000 ]]; then
        print_warning "Email HTML approaching Gmail clip limit (${file_size}/102400 bytes)"
        warnings=$((warnings + 1))
    else
        print_success "Email size OK (${file_size} bytes, limit 102400)"
    fi

    # Summary
    print_header "Validation Summary"
    echo "  Issues:   $issues"
    echo "  Warnings: $warnings"

    if [[ "$issues" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Check CSS compatibility across email clients
check_css_compatibility() {
    local html_file="$1"

    print_header "CSS Compatibility Check"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local issues=0

    # Check for flexbox usage
    if grep -qi 'display:\s*flex\|display:\s*inline-flex' "$html_file"; then
        print_error "Flexbox detected - not supported in Outlook (Word rendering engine)"
        print_info "Use table-based layout instead"
        issues=$((issues + 1))
    fi

    # Check for CSS Grid
    if grep -qi 'display:\s*grid\|display:\s*inline-grid' "$html_file"; then
        print_error "CSS Grid detected - not supported in Outlook or older clients"
        issues=$((issues + 1))
    fi

    # Check for position: absolute/fixed
    if grep -qi 'position:\s*absolute\|position:\s*fixed' "$html_file"; then
        print_error "CSS position absolute/fixed detected - not supported in most email clients"
        issues=$((issues + 1))
    fi

    # Check for float
    if grep -qi 'float:\s*left\|float:\s*right' "$html_file"; then
        print_warning "CSS float detected - inconsistent support across email clients"
        print_info "Use align attribute on tables/cells instead"
        issues=$((issues + 1))
    fi

    # Check for background-image
    if grep -qi 'background-image' "$html_file"; then
        print_warning "background-image detected - limited support in Outlook"
        print_info "Use VML fallback for Outlook: <!--[if mso]><v:rect>..."
        issues=$((issues + 1))
    fi

    # Check for border-radius
    if grep -qi 'border-radius' "$html_file"; then
        print_info "border-radius detected - not supported in Outlook for images"
        print_info "Works on table cells in most clients"
    fi

    # Check for custom fonts
    if grep -qi '@font-face\|font-family.*[^"]*sans-serif\|font-family.*[^"]*serif' "$html_file"; then
        local custom_fonts
        custom_fonts=$(grep -oiE "font-family:\s*['\"][^'\"]+['\"]" "$html_file" | head -5 || true)
        if [[ -n "$custom_fonts" ]]; then
            print_info "Custom fonts detected - provide web-safe fallbacks"
            echo "  Found: $custom_fonts"
        fi
    fi

    # Check for media queries
    if grep -qi '@media' "$html_file"; then
        print_success "Media queries found (responsive design)"
        print_info "Note: Gmail app strips media queries; use fluid/hybrid approach as fallback"
    fi

    # Check for max-width
    if grep -qi 'max-width' "$html_file"; then
        print_info "max-width detected - not supported in Outlook"
        print_info "Use: <!--[if mso]><table width=\"600\"><![endif]--> as fallback"
    fi

    # Check for CSS animations
    if grep -qi 'animation\|@keyframes\|transition' "$html_file"; then
        print_warning "CSS animations/transitions detected - limited email client support"
        print_info "Only Apple Mail and some webkit clients support animations"
        issues=$((issues + 1))
    fi

    if [[ "$issues" -eq 0 ]]; then
        print_success "No major CSS compatibility issues found"
    else
        print_warning "$issues CSS compatibility issues found"
    fi

    return 0
}

# Check dark mode compatibility
check_dark_mode() {
    local html_file="$1"

    print_header "Dark Mode Compatibility Check"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local issues=0

    # Check for color-scheme meta tag
    if grep -qi 'color-scheme' "$html_file"; then
        print_success "color-scheme meta tag found"
    else
        print_warning "Missing color-scheme meta tag"
        print_info "Add: <meta name=\"color-scheme\" content=\"light dark\">"
        print_info "Add: <meta name=\"supported-color-schemes\" content=\"light dark\">"
        issues=$((issues + 1))
    fi

    # Check for prefers-color-scheme media query
    if grep -qi 'prefers-color-scheme' "$html_file"; then
        print_success "prefers-color-scheme media query found"
    else
        print_warning "No prefers-color-scheme media query found"
        print_info "Add dark mode styles: @media (prefers-color-scheme: dark) { ... }"
        issues=$((issues + 1))
    fi

    # Check for hardcoded white backgrounds
    local white_bg_count
    white_bg_count=$(grep -ciE 'background(-color)?:\s*(#fff|#ffffff|white|rgb\(255)' "$html_file" 2>/dev/null || true)
    white_bg_count="${white_bg_count:-0}"
    if [[ "$white_bg_count" -gt 0 ]]; then
        print_warning "$white_bg_count hardcoded white backgrounds found"
        print_info "These will appear as bright patches in dark mode"
        print_info "Use transparent or dark-mode-aware colors"
        issues=$((issues + 1))
    fi

    # Check for hardcoded dark text on transparent backgrounds
    local dark_text_count
    dark_text_count=$(grep -ciE 'color:\s*(#000|#333|#222|black|rgb\(0)' "$html_file" 2>/dev/null || true)
    dark_text_count="${dark_text_count:-0}"
    if [[ "$dark_text_count" -gt 0 ]]; then
        print_warning "$dark_text_count hardcoded dark text colors found"
        print_info "Dark text on auto-inverted backgrounds becomes invisible in dark mode"
        issues=$((issues + 1))
    fi

    # Check for images with transparent backgrounds
    local png_count
    png_count=$(grep -ciE 'src=.*\.png' "$html_file" 2>/dev/null || true)
    png_count="${png_count:-0}"
    if [[ "$png_count" -gt 0 ]]; then
        print_info "$png_count PNG images found - check for transparent backgrounds"
        print_info "Transparent PNGs may look wrong on dark backgrounds"
        print_info "Consider adding a subtle background or border to images"
    fi

    # Check for logo images (common dark mode issue)
    if grep -qiE 'logo|brand|header.*img' "$html_file"; then
        print_info "Logo/brand images detected - ensure they work on both light and dark backgrounds"
        print_info "Consider providing light and dark versions with prefers-color-scheme"
    fi

    if [[ "$issues" -eq 0 ]]; then
        print_success "Dark mode compatibility looks good"
    else
        print_warning "$issues dark mode issues found"
    fi

    return 0
}

# Check responsive design
check_responsive() {
    local html_file="$1"

    print_header "Responsive Design Check"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local issues=0

    # Check viewport meta
    if ! grep -qi 'viewport' "$html_file"; then
        print_error "Missing viewport meta tag"
        issues=$((issues + 1))
    else
        print_success "Viewport meta tag present"
    fi

    # Check for fixed widths
    local fixed_width_count
    fixed_width_count=$(grep -ciE 'width:\s*[0-9]{4,}px|width="[0-9]{4,}"' "$html_file" 2>/dev/null || true)
    fixed_width_count="${fixed_width_count:-0}"
    if [[ "$fixed_width_count" -gt 0 ]]; then
        print_warning "$fixed_width_count elements with large fixed widths (>999px)"
        print_info "Use max-width or percentage-based widths for mobile"
        issues=$((issues + 1))
    fi

    # Check for media queries
    local media_query_count
    media_query_count=$(grep -ci '@media' "$html_file" 2>/dev/null || true)
    media_query_count="${media_query_count:-0}"
    if [[ "$media_query_count" -gt 0 ]]; then
        print_success "Media queries found ($media_query_count)"
    else
        print_warning "No media queries found - consider adding responsive breakpoints"
        print_info "Common breakpoint: @media screen and (max-width: 600px)"
        issues=$((issues + 1))
    fi

    # Check for fluid tables
    if grep -qiE 'width:\s*100%\|width="100%"' "$html_file"; then
        print_success "Fluid width elements found"
    fi

    # Check for MSO conditionals (Outlook fallbacks)
    if grep -qi '\[if mso\]' "$html_file"; then
        print_success "Outlook conditional comments found (MSO fallbacks)"
    else
        print_info "No Outlook conditionals - consider adding for width fallbacks"
        print_info "Example: <!--[if mso]><table width=\"600\"><![endif]-->"
    fi

    # Check font sizes
    local small_font_count
    small_font_count=$(grep -ciE 'font-size:\s*([0-9]|1[0-3])px' "$html_file" 2>/dev/null || true)
    small_font_count="${small_font_count:-0}"
    if [[ "$small_font_count" -gt 0 ]]; then
        print_warning "$small_font_count elements with small font sizes (<14px)"
        print_info "Minimum recommended: 14px body, 22px headings for mobile"
        issues=$((issues + 1))
    fi

    # Check CTA button sizes
    if grep -qiE 'class=.*btn\|class=.*button\|class=.*cta' "$html_file"; then
        print_info "CTA buttons detected - ensure minimum 44px touch target on mobile"
    fi

    if [[ "$issues" -eq 0 ]]; then
        print_success "Responsive design checks passed"
    else
        print_warning "$issues responsive design issues found"
    fi

    return 0
}

# Check email accessibility (delegates to accessibility-helper.sh)
check_accessibility() {
    local html_file="$1"

    print_header "Email Accessibility Check (WCAG 2.1)"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    local a11y_helper="${SCRIPT_DIR}/accessibility-helper.sh"
    if [[ -x "$a11y_helper" ]]; then
        "$a11y_helper" email "$html_file"
        return $?
    fi

    # Fallback: inline accessibility checks if helper is not available
    print_warning "accessibility-helper.sh not found — running basic checks"

    local issues=0
    local warnings=0

    # Check: images without alt text (WCAG 1.1.1)
    local total_imgs
    total_imgs=$(grep -ciE '<img ' "$html_file" 2>/dev/null || true)
    total_imgs="${total_imgs:-0}"
    local imgs_with_alt
    imgs_with_alt=$(grep -ciE '<img [^>]*alt=' "$html_file" 2>/dev/null || true)
    imgs_with_alt="${imgs_with_alt:-0}"
    local imgs_missing_alt=$((total_imgs - imgs_with_alt))

    if [[ "$imgs_missing_alt" -gt 0 ]]; then
        print_error "$imgs_missing_alt image(s) missing alt attribute (WCAG 1.1.1)"
        issues=$((issues + imgs_missing_alt))
    else
        print_success "All images have alt attributes ($total_imgs images)"
    fi

    # Check: language attribute on html tag (WCAG 3.1.1)
    if grep -qiE '<html[^>]*lang=' "$html_file" 2>/dev/null; then
        print_success "HTML lang attribute present"
    else
        print_error "Missing lang attribute on <html> tag (WCAG 3.1.1)"
        issues=$((issues + 1))
    fi

    # Check: layout tables without role="presentation" (WCAG 1.3.1)
    local tables
    tables=$(grep -ciE '<table' "$html_file" 2>/dev/null || true)
    tables="${tables:-0}"
    local tables_with_role
    tables_with_role=$(grep -ciE '<table[^>]*role=' "$html_file" 2>/dev/null || true)
    tables_with_role="${tables_with_role:-0}"
    if [[ "$tables" -gt 0 && "$tables_with_role" -eq 0 ]]; then
        print_warning "$tables table(s) without role attribute — use role=\"presentation\" for layout tables (WCAG 1.3.1)"
        warnings=$((warnings + 1))
    elif [[ "$tables" -gt 0 ]]; then
        print_success "Tables have role attributes ($tables_with_role/$tables)"
    fi

    # Check: small font sizes (WCAG 1.4.4)
    local small_fonts
    small_fonts=$(grep -ciE 'font-size:\s*(([0-9]|1[0-3])px)' "$html_file" 2>/dev/null || true)
    small_fonts="${small_fonts:-0}"
    if [[ "$small_fonts" -gt 0 ]]; then
        print_warning "$small_fonts instance(s) of font-size below 14px (WCAG 1.4.4)"
        warnings=$((warnings + 1))
    else
        print_success "No excessively small font sizes detected"
    fi

    # Check: generic link text (WCAG 2.4.4)
    local generic_links
    generic_links=$(grep -ciE '<a [^>]*>[[:space:]]*(click here|here|read more|learn more|more)[[:space:]]*</a>' "$html_file" 2>/dev/null || true)
    generic_links="${generic_links:-0}"
    if [[ "$generic_links" -gt 0 ]]; then
        print_warning "$generic_links link(s) with generic text like 'click here' (WCAG 2.4.4)"
        warnings=$((warnings + 1))
    else
        print_success "No generic link text detected"
    fi

    # Check: heading structure (WCAG 1.3.1)
    local headings
    headings=$(grep -ciE '<h[1-6]' "$html_file" 2>/dev/null || true)
    headings="${headings:-0}"
    if [[ "$headings" -eq 0 ]]; then
        print_warning "No heading elements found (WCAG 1.3.1)"
        warnings=$((warnings + 1))
    else
        print_success "$headings heading element(s) found"
    fi

    # Check: colour-only indicators (WCAG 1.4.1)
    local color_only
    color_only=$(grep -ciE 'color:\s*(red|green)' "$html_file" 2>/dev/null || true)
    color_only="${color_only:-0}"
    if [[ "$color_only" -gt 0 ]]; then
        print_warning "$color_only instance(s) of red/green colour usage — avoid colour as sole indicator (WCAG 1.4.1)"
        warnings=$((warnings + 1))
    fi

    # Summary
    print_header "Accessibility Summary"
    echo "  Errors:   $issues"
    echo "  Warnings: $warnings"

    if [[ "$issues" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Run full design rendering test suite
test_design() {
    local html_file="$1"

    print_header "Full Design Rendering Test Suite"
    echo ""

    validate_html_structure "$html_file" || true
    echo ""
    check_css_compatibility "$html_file" || true
    echo ""
    check_dark_mode "$html_file" || true
    echo ""
    check_responsive "$html_file" || true
    echo ""
    check_accessibility "$html_file" || true

    print_header "Client Compatibility Summary"
    echo ""
    echo "  Rendering Engines:"
    echo "    WebKit:  $EMAIL_CLIENTS_WEBKIT"
    echo "    Blink:   $EMAIL_CLIENTS_BLINK"
    echo "    Word:    $EMAIL_CLIENTS_WORD"
    echo "    Custom:  $EMAIL_CLIENTS_CUSTOM"
    echo ""
    print_info "For visual rendering tests, use:"
    echo "  - Litmus:        https://litmus.com"
    echo "  - Email on Acid: https://emailonacid.com"
    echo "  - Mailtrap:      https://mailtrap.io"
    echo "  - Testi@:        https://testi.at"

    return 0
}

# =============================================================================
# Delivery Testing
# =============================================================================

# Test SMTP connectivity to a mail server
test_smtp() {
    local server="$1"
    local port="${2:-25}"

    print_header "SMTP Connectivity Test: $server:$port"

    # Test basic TCP connectivity using nc (avoids clear-text /dev/tcp — S5332)
    if timeout 10 nc -z "$server" "$port" 2>/dev/null; then
        print_success "TCP connection to $server:$port successful"
    else
        print_error "Cannot connect to $server:$port"
        print_info "Check firewall rules and server availability"
        return 1
    fi

    # Test SMTP banner
    local banner
    banner=$(echo "" | timeout 10 nc -w 5 "$server" "$port" 2>/dev/null | head -1 || true)
    if [[ -n "$banner" ]]; then
        print_success "SMTP banner received:"
        echo "  $banner"
    fi

    # Test STARTTLS support
    if [[ "$port" == "25" || "$port" == "587" ]]; then
        local starttls_result
        starttls_result=$(echo "EHLO test.local" | timeout 10 openssl s_client -starttls smtp -connect "$server:$port" 2>&1 | head -5 || true)
        if [[ "$starttls_result" == *"BEGIN CERTIFICATE"* || "$starttls_result" == *"SSL handshake"* ]]; then
            print_success "STARTTLS supported"
        else
            print_warning "STARTTLS may not be supported on port $port"
        fi
    fi

    # Test TLS on port 465
    if [[ "$port" == "465" ]]; then
        local tls_result
        tls_result=$(echo "EHLO test.local" | timeout 10 openssl s_client -connect "$server:$port" 2>&1 | head -5 || true)
        if [[ "$tls_result" == *"BEGIN CERTIFICATE"* || "$tls_result" == *"SSL handshake"* ]]; then
            print_success "Implicit TLS connection successful"
        else
            print_warning "TLS connection issue on port $port"
        fi
    fi

    return 0
}

# Test SMTP for a domain (auto-discover MX and test)
test_smtp_domain() {
    local domain="$1"

    print_header "SMTP Domain Test: $domain"

    # Get MX records
    local mx_records
    mx_records=$(dig MX "$domain" +short 2>/dev/null | sort -n || true)

    if [[ -z "$mx_records" ]]; then
        print_error "No MX records found for $domain"
        return 1
    fi

    print_success "MX records found:"
    echo "$mx_records" | while read -r line; do
        echo "  $line"
    done
    echo ""

    # Test connectivity to primary MX
    local primary_mx
    primary_mx=$(echo "$mx_records" | head -1 | awk '{print $2}' | sed 's/\.$//')

    if [[ -n "$primary_mx" ]]; then
        print_info "Testing primary MX: $primary_mx"
        test_smtp "$primary_mx" 25 || true
    fi

    return 0
}

# Analyze email headers from a file or stdin
analyze_headers() {
    local header_file="${1:-}"

    print_header "Email Header Analysis"

    local headers
    if [[ -n "$header_file" && -f "$header_file" ]]; then
        headers=$(cat "$header_file")
    else
        print_info "Paste email headers below (end with Ctrl+D):"
        headers=$(cat)
    fi

    if [[ -z "$headers" ]]; then
        print_error "No headers provided"
        return 1
    fi

    # Extract key headers
    local from
    from=$(echo "$headers" | grep -i '^From:' | head -1 || true)
    local to
    to=$(echo "$headers" | grep -i '^To:' | head -1 || true)
    local subject
    subject=$(echo "$headers" | grep -i '^Subject:' | head -1 || true)
    local date_header
    date_header=$(echo "$headers" | grep -i '^Date:' | head -1 || true)
    local message_id
    message_id=$(echo "$headers" | grep -i '^Message-ID:' | head -1 || true)

    echo "  $from"
    echo "  $to"
    echo "  $subject"
    echo "  $date_header"
    echo "  $message_id"
    echo ""

    # Check authentication results
    print_header "Authentication Results"

    local auth_results
    auth_results=$(echo "$headers" | grep -i 'Authentication-Results:' || true)
    if [[ -n "$auth_results" ]]; then
        echo "$auth_results" | while read -r line; do
            if echo "$line" | grep -qi 'spf=pass'; then
                print_success "SPF: PASS"
            elif echo "$line" | grep -qi 'spf=fail'; then
                print_error "SPF: FAIL"
            elif echo "$line" | grep -qi 'spf='; then
                local spf_status
                spf_status=$(echo "$line" | grep -oiE 'spf=[a-z]+' || true)
                print_warning "SPF: $spf_status"
            fi

            if echo "$line" | grep -qi 'dkim=pass'; then
                print_success "DKIM: PASS"
            elif echo "$line" | grep -qi 'dkim=fail'; then
                print_error "DKIM: FAIL"
            elif echo "$line" | grep -qi 'dkim='; then
                local dkim_status
                dkim_status=$(echo "$line" | grep -oiE 'dkim=[a-z]+' || true)
                print_warning "DKIM: $dkim_status"
            fi

            if echo "$line" | grep -qi 'dmarc=pass'; then
                print_success "DMARC: PASS"
            elif echo "$line" | grep -qi 'dmarc=fail'; then
                print_error "DMARC: FAIL"
            elif echo "$line" | grep -qi 'dmarc='; then
                local dmarc_status
                dmarc_status=$(echo "$line" | grep -oiE 'dmarc=[a-z]+' || true)
                print_warning "DMARC: $dmarc_status"
            fi
        done
    else
        print_warning "No Authentication-Results header found"
    fi

    # Check for DKIM signature
    local dkim_sig
    dkim_sig=$(echo "$headers" | grep -i '^DKIM-Signature:' || true)
    if [[ -n "$dkim_sig" ]]; then
        local dkim_domain
        dkim_domain=$(echo "$dkim_sig" | grep -oiE 'd=[^ ;]+' | head -1 || true)
        local dkim_selector
        dkim_selector=$(echo "$dkim_sig" | grep -oiE 's=[^ ;]+' | head -1 || true)
        print_info "DKIM Signature: $dkim_domain $dkim_selector"
    fi

    # Check Received headers (trace route)
    print_header "Delivery Path"
    local received_count
    received_count=$(echo "$headers" | grep -ci '^Received:' 2>/dev/null || true)
    received_count="${received_count:-0}"
    print_info "Hops: $received_count"

    echo "$headers" | grep -i '^Received:' | head -5 | while read -r line; do
        local hop_from
        hop_from=$(echo "$line" | grep -oiE 'from [^ ]+' | head -1 || true)
        local hop_by
        hop_by=$(echo "$line" | grep -oiE 'by [^ ]+' | head -1 || true)
        echo "  $hop_from -> $hop_by"
    done

    # Check for spam indicators
    print_header "Spam Indicators"

    local spam_score
    spam_score=$(echo "$headers" | grep -i 'X-Spam-Score:' | head -1 || true)
    if [[ -n "$spam_score" ]]; then
        echo "  $spam_score"
    fi

    local spam_status
    spam_status=$(echo "$headers" | grep -i 'X-Spam-Status:' | head -1 || true)
    if [[ -n "$spam_status" ]]; then
        echo "  $spam_status"
    fi

    # Check List-Unsubscribe header
    local list_unsub
    list_unsub=$(echo "$headers" | grep -i 'List-Unsubscribe:' || true)
    if [[ -n "$list_unsub" ]]; then
        print_success "List-Unsubscribe header present"
        # Check for one-click unsubscribe
        local one_click
        one_click=$(echo "$headers" | grep -i 'List-Unsubscribe-Post:' || true)
        if [[ -n "$one_click" ]]; then
            print_success "One-click unsubscribe (RFC 8058) supported"
        else
            print_warning "Missing List-Unsubscribe-Post header (one-click unsubscribe)"
            print_info "Required by Gmail/Yahoo since Feb 2024"
        fi
    else
        print_warning "Missing List-Unsubscribe header"
        print_info "Required for bulk/marketing emails"
    fi

    return 0
}

# Check inbox placement factors for a domain
check_inbox_placement() {
    local domain="$1"

    print_header "Inbox Placement Analysis: $domain"

    local score=0
    local max_score=10

    # 1. SPF check
    local spf_record
    spf_record=$(dig TXT "$domain" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"' || true)
    if [[ -n "$spf_record" ]]; then
        if [[ "$spf_record" == *"-all"* || "$spf_record" == *"~all"* ]]; then
            print_success "SPF: Configured with enforcement"
            score=$((score + 1))
        else
            print_warning "SPF: Configured but weak policy"
        fi
    else
        print_error "SPF: Not configured"
    fi

    # 2. DKIM check (common selectors)
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
        print_success "DKIM: At least one selector found"
        score=$((score + 1))
    else
        print_error "DKIM: No common selectors found"
    fi

    # 3. DMARC check
    local dmarc_record
    dmarc_record=$(dig TXT "_dmarc.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$dmarc_record" ]]; then
        if [[ "$dmarc_record" == *"p=reject"* || "$dmarc_record" == *"p=quarantine"* ]]; then
            print_success "DMARC: Enforcing policy"
            score=$((score + 2))
        elif [[ "$dmarc_record" == *"p=none"* ]]; then
            print_warning "DMARC: Monitoring only (p=none)"
            score=$((score + 1))
        fi
    else
        print_error "DMARC: Not configured"
    fi

    # 4. MX records
    local mx_records
    mx_records=$(dig MX "$domain" +short 2>/dev/null || true)
    if [[ -n "$mx_records" ]]; then
        local mx_count
        mx_count=$(echo "$mx_records" | wc -l | tr -d ' ')
        if [[ "$mx_count" -gt 1 ]]; then
            print_success "MX: $mx_count records (redundant)"
            score=$((score + 1))
        else
            print_success "MX: Configured (single server)"
            score=$((score + 1))
        fi
    else
        print_error "MX: Not configured"
    fi

    # 5. Reverse DNS (PTR) for MX
    local primary_mx
    primary_mx=$(echo "$mx_records" | head -1 | awk '{print $2}' | sed 's/\.$//' || true)
    if [[ -n "$primary_mx" ]]; then
        local mx_ip
        mx_ip=$(dig A "$primary_mx" +short 2>/dev/null | head -1 || true)
        if [[ -n "$mx_ip" ]]; then
            local ptr_record
            ptr_record=$(dig -x "$mx_ip" +short 2>/dev/null || true)
            if [[ -n "$ptr_record" ]]; then
                print_success "Reverse DNS: PTR record exists for MX IP"
                score=$((score + 1))
            else
                print_warning "Reverse DNS: No PTR record for MX IP ($mx_ip)"
            fi
        fi
    fi

    # 6. MTA-STS check
    local mta_sts
    mta_sts=$(dig TXT "_mta-sts.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$mta_sts" && "$mta_sts" == *"v=STSv1"* ]]; then
        print_success "MTA-STS: Configured"
        score=$((score + 1))
    else
        print_info "MTA-STS: Not configured (optional but recommended)"
    fi

    # 7. TLS-RPT check
    local tls_rpt
    tls_rpt=$(dig TXT "_smtp._tls.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$tls_rpt" && "$tls_rpt" == *"v=TLSRPTv1"* ]]; then
        print_success "TLS-RPT: Configured"
        score=$((score + 1))
    else
        print_info "TLS-RPT: Not configured (optional)"
    fi

    # 8. BIMI check
    local bimi
    bimi=$(dig TXT "default._bimi.${domain}" +short 2>/dev/null | tr -d '"' || true)
    if [[ -n "$bimi" && "$bimi" == *"v=BIMI1"* ]]; then
        print_success "BIMI: Configured (brand logo in inbox)"
        score=$((score + 1))
    else
        print_info "BIMI: Not configured (optional, requires DMARC p=quarantine+)"
    fi

    # 9. Blacklist check (quick)
    local domain_ip
    domain_ip=$(dig A "$domain" +short 2>/dev/null | head -1 || true)
    if [[ -n "$domain_ip" ]]; then
        local reversed_ip
        reversed_ip=$(echo "$domain_ip" | awk -F. '{print $4"."$3"."$2"."$1}')
        local bl_result
        bl_result=$(dig A "${reversed_ip}.zen.spamhaus.org" +short 2>/dev/null || true)
        if [[ -z "$bl_result" || "$bl_result" == *"NXDOMAIN"* ]]; then
            print_success "Blacklist: Not listed on Spamhaus"
            score=$((score + 1))
        else
            print_error "Blacklist: Listed on Spamhaus ($bl_result)"
        fi
    fi

    # Score summary
    print_header "Inbox Placement Score"
    echo ""
    echo "  Score: $score / $max_score"
    echo ""

    if [[ "$score" -ge 8 ]]; then
        print_success "Excellent - high inbox placement expected"
    elif [[ "$score" -ge 6 ]]; then
        print_success "Good - most emails should reach inbox"
    elif [[ "$score" -ge 4 ]]; then
        print_warning "Fair - some emails may go to spam"
    else
        print_error "Poor - significant deliverability issues"
    fi

    echo ""
    print_info "For comprehensive testing, send to: mail-tester.com"
    print_info "For ongoing monitoring: Google Postmaster Tools, Microsoft SNDS"

    return 0
}

# Test TLS certificate for mail server
test_mail_tls() {
    local server="$1"
    local port="${2:-465}"

    print_header "Mail Server TLS Check: $server:$port"

    local connect_flag=""
    if [[ "$port" == "25" || "$port" == "587" ]]; then
        connect_flag="-starttls smtp"
    fi

    local cert_info
    # shellcheck disable=SC2086
    cert_info=$(echo "QUIT" | timeout 10 openssl s_client $connect_flag -connect "$server:$port" -servername "$server" 2>/dev/null || true)

    if [[ -z "$cert_info" ]]; then
        print_error "Could not establish TLS connection to $server:$port"
        return 1
    fi

    # Extract certificate details
    local subject
    subject=$(echo "$cert_info" | openssl x509 -noout -subject 2>/dev/null || true)
    local issuer
    issuer=$(echo "$cert_info" | openssl x509 -noout -issuer 2>/dev/null || true)
    local dates
    dates=$(echo "$cert_info" | openssl x509 -noout -dates 2>/dev/null || true)
    local san
    san=$(echo "$cert_info" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)

    if [[ -n "$subject" ]]; then
        print_success "TLS certificate found:"
        echo "  $subject"
        echo "  $issuer"
        echo "  $dates"
    fi

    # Check expiry
    local not_after
    not_after=$(echo "$dates" | grep 'notAfter' | cut -d= -f2 || true)
    if [[ -n "$not_after" ]]; then
        local expiry_epoch
        expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$not_after" "+%s" 2>/dev/null || date -d "$not_after" "+%s" 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date "+%s")
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ "$days_left" -lt 0 ]]; then
            print_error "Certificate EXPIRED ($days_left days ago)"
        elif [[ "$days_left" -lt 30 ]]; then
            print_warning "Certificate expires in $days_left days"
        else
            print_success "Certificate valid for $days_left days"
        fi
    fi

    # Check TLS version
    local tls_version
    tls_version=$(echo "$cert_info" | grep -i 'Protocol' | head -1 || true)
    if [[ -n "$tls_version" ]]; then
        echo "  $tls_version"
        if echo "$tls_version" | grep -qi 'TLSv1.3'; then
            print_success "TLS 1.3 supported"
        elif echo "$tls_version" | grep -qi 'TLSv1.2'; then
            print_success "TLS 1.2 supported"
        elif echo "$tls_version" | grep -qi 'TLSv1\b\|TLSv1.0\|TLSv1.1'; then
            print_warning "Outdated TLS version - upgrade to TLS 1.2+"
        fi
    fi

    return 0
}

# Generate a test email (HTML) for rendering tests
generate_test_email() {
    local output_file="${1:-test-email.html}"

    print_header "Generating Test Email Template"

    cat > "$output_file" << 'HTMLEOF'
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="color-scheme" content="light dark">
    <meta name="supported-color-schemes" content="light dark">
    <title>Email Rendering Test</title>
    <!--[if mso]>
    <noscript>
        <xml>
            <o:OfficeDocumentSettings>
                <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
        </xml>
    </noscript>
    <![endif]-->
    <style>
        /* Reset */
        body, table, td, p, a, li { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
        table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
        img { -ms-interpolation-mode: bicubic; border: 0; outline: none; text-decoration: none; }

        /* Dark mode */
        @media (prefers-color-scheme: dark) {
            .email-body { background-color: #1a1a2e !important; }
            .email-container { background-color: #16213e !important; }
            .text-primary { color: #e8e8e8 !important; }
            .text-secondary { color: #b0b0b0 !important; }
            .header-bg { background-color: #0f3460 !important; }
        }

        /* Responsive */
        @media screen and (max-width: 600px) {
            .email-container { width: 100% !important; max-width: 100% !important; }
            .responsive-table { width: 100% !important; }
            .mobile-padding { padding: 10px !important; }
            .mobile-text-center { text-align: center !important; }
            .mobile-full-width { width: 100% !important; display: block !important; }
        }
    </style>
</head>
<body style="margin: 0; padding: 0; background-color: #f4f4f4;" class="email-body">
    <!--[if mso]><table role="presentation" width="600" align="center" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width: 600px; margin: 0 auto;" class="email-container">
        <!-- Header -->
        <tr>
            <td style="background-color: #2c3e50; padding: 30px 20px; text-align: center;" class="header-bg">
                <h1 style="color: #ffffff; font-family: Arial, Helvetica, sans-serif; font-size: 24px; margin: 0;" class="text-primary">
                    Email Rendering Test
                </h1>
            </td>
        </tr>
        <!-- Body -->
        <tr>
            <td style="background-color: #ffffff; padding: 30px 20px;" class="mobile-padding">
                <p style="color: #333333; font-family: Arial, Helvetica, sans-serif; font-size: 16px; line-height: 1.5;" class="text-primary">
                    This is a test email to validate rendering across email clients.
                </p>
                <p style="color: #666666; font-family: Arial, Helvetica, sans-serif; font-size: 14px; line-height: 1.5;" class="text-secondary">
                    Check the following elements render correctly:
                </p>
                <ul style="color: #333333; font-family: Arial, Helvetica, sans-serif; font-size: 14px;">
                    <li>Header background color</li>
                    <li>Font rendering and sizes</li>
                    <li>Button styling and clickability</li>
                    <li>Dark mode color inversion</li>
                    <li>Mobile responsive layout</li>
                </ul>
                <!-- CTA Button -->
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin: 20px auto;">
                    <tr>
                        <td style="background-color: #3498db; border-radius: 4px; padding: 12px 30px;">
                            <a href="https://example.com" style="color: #ffffff; font-family: Arial, Helvetica, sans-serif; font-size: 16px; text-decoration: none; display: inline-block;">
                                Test Button
                            </a>
                        </td>
                    </tr>
                </table>
                <!-- Image test -->
                <p style="text-align: center;">
                    <img src="https://via.placeholder.com/200x100?text=Test+Image" alt="Test image placeholder" width="200" height="100" style="display: block; margin: 0 auto; max-width: 100%; height: auto;">
                </p>
            </td>
        </tr>
        <!-- Footer -->
        <tr>
            <td style="background-color: #ecf0f1; padding: 20px; text-align: center;">
                <p style="color: #999999; font-family: Arial, Helvetica, sans-serif; font-size: 12px; margin: 0;">
                    This is a test email from AI DevOps Email Test Suite.
                </p>
                <p style="color: #999999; font-family: Arial, Helvetica, sans-serif; font-size: 12px; margin: 5px 0 0 0;">
                    <a href="https://example.com/unsubscribe" style="color: #3498db;">Unsubscribe</a>
                </p>
            </td>
        </tr>
    </table>
    <!--[if mso]></td></tr></table><![endif]-->
</body>
</html>
HTMLEOF

    print_success "Test email generated: $output_file"
    print_info "Run: $0 test-design $output_file"

    return 0
}

# =============================================================================
# Help and Main
# =============================================================================

show_help() {
    echo "Email Test Suite Helper Script"
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Design Rendering Commands:"
    echo "  test-design [html-file]       Full design rendering test suite (includes accessibility)"
    echo "  validate-html [html-file]     Validate HTML email structure"
    echo "  check-css [html-file]         Check CSS compatibility across clients"
    echo "  check-dark-mode [html-file]   Check dark mode compatibility"
    echo "  check-responsive [html-file]  Check responsive design"
    echo "  check-accessibility [html]    Check email accessibility (WCAG 2.1)"
    echo "  generate-test-email [file]    Generate a test email template"
    echo ""
    echo "Delivery Testing Commands:"
    echo "  test-smtp [server] [port]     Test SMTP connectivity"
    echo "  test-smtp-domain [domain]     Test SMTP via MX record discovery"
    echo "  analyze-headers [file]        Analyze email headers"
    echo "  check-placement [domain]      Check inbox placement factors"
    echo "  test-tls [server] [port]      Test mail server TLS certificate"
    echo ""
    echo "General:"
    echo "  help                          $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 test-design newsletter.html"
    echo "  $0 validate-html campaign.html"
    echo "  $0 check-dark-mode template.html"
    echo "  $0 check-accessibility newsletter.html"
    echo "  $0 test-smtp smtp.gmail.com 587"
    echo "  $0 test-smtp-domain example.com"
    echo "  $0 analyze-headers headers.txt"
    echo "  $0 check-placement example.com"
    echo "  $0 test-tls mail.example.com 465"
    echo "  $0 generate-test-email test.html"
    echo ""
    echo "Dependencies:"
    echo "  Required: curl, dig, openssl"
    echo "  Optional: html-validate (npm), mjml (npm)"
    echo ""
    echo "Related:"
    echo "  accessibility-helper.sh       WCAG accessibility auditing (web + email)"
    echo "  email-health-check-helper.sh  DNS authentication and deliverability"

    return 0
}

main() {
    local command="${1:-help}"
    local arg1="${2:-}"
    local arg2="${3:-}"

    case "$command" in
        "test-design")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            test_design "$arg1"
            ;;
        "validate-html"|"validate")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            validate_html_structure "$arg1"
            ;;
        "check-css"|"css")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_css_compatibility "$arg1"
            ;;
        "check-dark-mode"|"dark-mode"|"darkmode")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_dark_mode "$arg1"
            ;;
        "check-responsive"|"responsive")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_responsive "$arg1"
            ;;
        "check-accessibility"|"accessibility"|"a11y")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            check_accessibility "$arg1"
            ;;
        "generate-test-email"|"generate")
            generate_test_email "$arg1"
            ;;
        "test-smtp"|"smtp")
            if [[ -z "$arg1" ]]; then
                print_error "SMTP server required"
                exit 1
            fi
            test_smtp "$arg1" "$arg2"
            ;;
        "test-smtp-domain"|"smtp-domain")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            test_smtp_domain "$arg1"
            ;;
        "analyze-headers"|"headers")
            analyze_headers "$arg1"
            ;;
        "check-placement"|"placement"|"inbox")
            if [[ -z "$arg1" ]]; then
                print_error "Domain required"
                exit 1
            fi
            check_inbox_placement "$arg1"
            ;;
        "test-tls"|"tls")
            if [[ -z "$arg1" ]]; then
                print_error "Mail server required"
                exit 1
            fi
            test_mail_tls "$arg1" "$arg2"
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "$HELP_USAGE_INFO"
            exit 1
            ;;
    esac

    return 0
}

main "$@"
