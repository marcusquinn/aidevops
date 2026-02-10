#!/usr/bin/env bash
# shellcheck disable=SC2034

# Email Design Test Helper Script
# CLI for local + Email on Acid (EOA) API email design testing.
# Combines local HTML validation with EOA's real-client rendering screenshots.
#
# Usage: email-design-test-helper.sh [command] [options]
#
# Dependencies:
#   Required: curl, jq (for EOA API)
#   Optional: html-validate (npm), mjml (npm)
#
# EOA API credentials:
#   aidevops secret set EOA_API_KEY
#   aidevops secret set EOA_API_PASSWORD
#   Or set in ~/.config/aidevops/credentials.sh:
#     EOA_API_KEY="your-api-key"
#     EOA_API_PASSWORD="your-password"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

init_log_file

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# EOA API constants
readonly EOA_API_BASE="https://api.emailonacid.com/v5"
readonly EOA_API_BASE_V501="https://api.emailonacid.com/v5.0.1"
readonly EOA_POLL_INTERVAL=10
readonly EOA_POLL_MAX_ATTEMPTS=60
readonly EOA_SANDBOX_USER="sandbox"
readonly EOA_SANDBOX_PASS="sandbox"

# =============================================================================
# Credential Management
# =============================================================================

# Load EOA API credentials from aidevops secret store or credentials.sh
load_eoa_credentials() {
    local api_key=""
    local api_password=""

    # Try gopass first (encrypted)
    if command -v gopass &>/dev/null; then
        api_key=$(gopass show -o "aidevops/EOA_API_KEY" 2>/dev/null || echo "")
        api_password=$(gopass show -o "aidevops/EOA_API_PASSWORD" 2>/dev/null || echo "")
    fi

    # Fallback to credentials.sh
    if [[ -z "$api_key" || -z "$api_password" ]]; then
        local creds_file="${HOME}/.config/aidevops/credentials.sh"
        if [[ -f "$creds_file" ]]; then
            # shellcheck source=/dev/null
            source "$creds_file" 2>/dev/null || true
            api_key="${EOA_API_KEY:-$api_key}"
            api_password="${EOA_API_PASSWORD:-$api_password}"
        fi
    fi

    # Environment variable override
    api_key="${EOA_API_KEY:-$api_key}"
    api_password="${EOA_API_PASSWORD:-$api_password}"

    if [[ -z "$api_key" || -z "$api_password" ]]; then
        return 1
    fi

    # Export for use by API functions (base64 encoded for Basic Auth)
    EOA_AUTH_HEADER=$(printf '%s:%s' "$api_key" "$api_password" | base64)
    export EOA_AUTH_HEADER
    return 0
}

# Build authorization header for curl
eoa_auth_args() {
    echo "-H" "Authorization: Basic ${EOA_AUTH_HEADER}"
}

print_header() {
    local msg="$1"
    echo ""
    echo -e "${BLUE}=== $msg ===${NC}"
    return 0
}

# =============================================================================
# Local Design Testing
# =============================================================================

# Run local design tests (delegates to email-test-suite-helper.sh + extras)
test_local() {
    local html_file="$1"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    print_header "Local Email Design Test: $html_file"

    # Run the existing test suite if available
    local test_suite="${SCRIPT_DIR}/email-test-suite-helper.sh"
    if [[ -x "$test_suite" ]]; then
        "$test_suite" test-design "$html_file"
    else
        print_warning "email-test-suite-helper.sh not found, running built-in checks"
        _builtin_html_check "$html_file"
        _builtin_css_check "$html_file"
        _builtin_dark_mode_check "$html_file"
        _builtin_responsive_check "$html_file"
    fi

    echo ""

    # Additional design-specific checks
    _check_accessibility "$html_file"
    _check_image_optimization "$html_file"
    _check_link_validity "$html_file"
    _check_preheader "$html_file"

    print_header "Local Design Test Complete"
    print_info "For real-client rendering: $0 eoa-test $html_file"
    print_info "For sandbox test (no API key): $0 eoa-sandbox $html_file"

    return 0
}

# Check email accessibility
_check_accessibility() {
    local html_file="$1"

    print_header "Accessibility Check"

    local issues=0

    # Check for lang attribute
    if ! grep -qi 'lang=' "$html_file"; then
        print_warning "Missing lang attribute on <html> tag"
        print_info "Add: <html lang=\"en\"> for screen reader support"
        issues=$((issues + 1))
    else
        print_success "Language attribute found"
    fi

    # Check for role="presentation" on layout tables
    local table_count
    table_count=$(grep -ci '<table' "$html_file" 2>/dev/null || true)
    table_count="${table_count:-0}"
    local role_pres_count
    role_pres_count=$(grep -ci 'role="presentation"' "$html_file" 2>/dev/null || true)
    role_pres_count="${role_pres_count:-0}"
    if [[ "$table_count" -gt 0 && "$role_pres_count" -eq 0 ]]; then
        print_warning "Layout tables missing role=\"presentation\""
        print_info "Add role=\"presentation\" to layout tables for screen readers"
        issues=$((issues + 1))
    elif [[ "$role_pres_count" -gt 0 ]]; then
        print_success "role=\"presentation\" found on tables ($role_pres_count)"
    fi

    # Check for sufficient color contrast hints
    local color_count
    color_count=$(grep -ciE 'color:\s*#[0-9a-fA-F]{3,6}' "$html_file" 2>/dev/null || true)
    color_count="${color_count:-0}"
    if [[ "$color_count" -gt 0 ]]; then
        print_info "$color_count color declarations found - verify contrast ratio >= 4.5:1"
    fi

    # Check for title attribute
    if ! grep -qi '<title' "$html_file"; then
        print_warning "Missing <title> tag"
        print_info "Add a descriptive <title> for accessibility"
        issues=$((issues + 1))
    else
        print_success "Title tag found"
    fi

    # Check for semantic headings
    local heading_count
    heading_count=$(grep -ciE '<h[1-6]' "$html_file" 2>/dev/null || true)
    heading_count="${heading_count:-0}"
    if [[ "$heading_count" -eq 0 ]]; then
        print_info "No semantic headings found - consider using <h1>-<h6> for structure"
    else
        print_success "Semantic headings found ($heading_count)"
    fi

    if [[ "$issues" -eq 0 ]]; then
        print_success "Accessibility checks passed"
    else
        print_warning "$issues accessibility issues found"
    fi

    return 0
}

# Check image optimization
_check_image_optimization() {
    local html_file="$1"

    print_header "Image Optimization Check"

    local issues=0

    # Check for width/height attributes on images
    local img_count
    img_count=$(grep -ci '<img' "$html_file" 2>/dev/null || true)
    img_count="${img_count:-0}"

    if [[ "$img_count" -eq 0 ]]; then
        print_info "No images found"
        return 0
    fi

    # Check for explicit dimensions
    local img_with_dims
    img_with_dims=$(grep -ciE '<img[^>]+(width|height)=' "$html_file" 2>/dev/null || true)
    img_with_dims="${img_with_dims:-0}"
    if [[ "$img_with_dims" -lt "$img_count" ]]; then
        print_warning "Some images missing explicit width/height attributes"
        print_info "Add width/height to prevent layout shift during loading"
        issues=$((issues + 1))
    else
        print_success "All images have explicit dimensions"
    fi

    # Check for display:block on images
    local img_block_count
    img_block_count=$(grep -ciE '<img[^>]+display:\s*block' "$html_file" 2>/dev/null || true)
    img_block_count="${img_block_count:-0}"
    if [[ "$img_block_count" -lt "$img_count" ]]; then
        print_info "Consider adding display:block to images to prevent gaps in Outlook"
    fi

    # Check for retina images (2x)
    if grep -qiE 'srcset|2x|@2x' "$html_file"; then
        print_info "Retina/srcset references found - note: srcset not supported in most email clients"
        print_info "Use width attribute at half the image's actual pixel width instead"
    fi

    # Check image file formats
    local webp_count
    webp_count=$(grep -ciE 'src=.*\.webp' "$html_file" 2>/dev/null || true)
    webp_count="${webp_count:-0}"
    if [[ "$webp_count" -gt 0 ]]; then
        print_warning "$webp_count WebP images found - not supported in Outlook/older clients"
        print_info "Use PNG/JPG/GIF for maximum compatibility"
        issues=$((issues + 1))
    fi

    local svg_count
    svg_count=$(grep -ciE 'src=.*\.svg|<svg' "$html_file" 2>/dev/null || true)
    svg_count="${svg_count:-0}"
    if [[ "$svg_count" -gt 0 ]]; then
        print_warning "$svg_count SVG references found - limited email client support"
        print_info "Use PNG fallback for SVG images"
        issues=$((issues + 1))
    fi

    if [[ "$issues" -eq 0 ]]; then
        print_success "Image optimization checks passed"
    else
        print_warning "$issues image optimization issues found"
    fi

    return 0
}

# Check link validity
_check_link_validity() {
    local html_file="$1"

    print_header "Link Validation Check"

    local issues=0

    # Check for links without href
    local empty_href_count
    empty_href_count=$(grep -ciE 'href="\s*"' "$html_file" 2>/dev/null || true)
    empty_href_count="${empty_href_count:-0}"
    if [[ "$empty_href_count" -gt 0 ]]; then
        print_warning "$empty_href_count empty href attributes found"
        issues=$((issues + 1))
    fi

    # Check for javascript: links
    local js_link_count
    js_link_count=$(grep -ciE 'href="javascript:' "$html_file" 2>/dev/null || true)
    js_link_count="${js_link_count:-0}"
    if [[ "$js_link_count" -gt 0 ]]; then
        print_error "$js_link_count javascript: links found - not supported in email"
        issues=$((issues + 1))
    fi

    # Check for http:// links (should be https://)
    local http_link_count
    http_link_count=$(grep -ciE 'href="http://' "$html_file" 2>/dev/null || true)
    http_link_count="${http_link_count:-0}"
    if [[ "$http_link_count" -gt 0 ]]; then
        print_warning "$http_link_count non-HTTPS links found - use HTTPS for security"
        issues=$((issues + 1))
    fi

    # Check for tracking parameters
    local utm_count
    utm_count=$(grep -ciE 'utm_' "$html_file" 2>/dev/null || true)
    utm_count="${utm_count:-0}"
    if [[ "$utm_count" -gt 0 ]]; then
        print_success "UTM tracking parameters found ($utm_count)"
    else
        print_info "No UTM tracking parameters found - consider adding for analytics"
    fi

    # Count total links
    local total_links
    total_links=$(grep -ciE 'href=' "$html_file" 2>/dev/null || true)
    total_links="${total_links:-0}"
    print_info "Total links found: $total_links"

    if [[ "$issues" -eq 0 ]]; then
        print_success "Link validation passed"
    else
        print_warning "$issues link issues found"
    fi

    return 0
}

# Check preheader text
_check_preheader() {
    local html_file="$1"

    print_header "Preheader Text Check"

    # Check for hidden preheader text pattern
    if grep -qiE 'display:\s*none|mso-hide:\s*all|font-size:\s*0|line-height:\s*0' "$html_file"; then
        if grep -qiE 'preview|preheader' "$html_file"; then
            print_success "Preheader text pattern detected"
        else
            print_info "Hidden text found - may be preheader text"
        fi
    else
        print_info "No preheader text detected"
        print_info "Add hidden preheader text to control inbox preview snippet"
        print_info "Pattern: <div style=\"display:none;max-height:0;overflow:hidden;\">Preview text</div>"
    fi

    return 0
}

# Built-in HTML check (fallback when email-test-suite-helper.sh unavailable)
_builtin_html_check() {
    local html_file="$1"

    print_header "HTML Structure Check (built-in)"

    local issues=0

    if ! grep -qi '<!DOCTYPE' "$html_file"; then
        print_error "Missing DOCTYPE"
        issues=$((issues + 1))
    else
        print_success "DOCTYPE found"
    fi

    if ! grep -qi 'charset' "$html_file"; then
        print_error "Missing charset"
        issues=$((issues + 1))
    else
        print_success "Charset found"
    fi

    local file_size
    file_size=$(wc -c < "$html_file" | tr -d ' ')
    if [[ "$file_size" -gt 102400 ]]; then
        print_warning "File size ${file_size} bytes exceeds Gmail 102KB clip limit"
        issues=$((issues + 1))
    else
        print_success "File size OK (${file_size} bytes)"
    fi

    echo "  Issues: $issues"
    return 0
}

# Built-in CSS check (fallback)
_builtin_css_check() {
    local html_file="$1"

    print_header "CSS Compatibility Check (built-in)"

    if grep -qi 'display:\s*flex' "$html_file"; then
        print_error "Flexbox detected - breaks in Outlook"
    fi
    if grep -qi 'display:\s*grid' "$html_file"; then
        print_error "CSS Grid detected - breaks in Outlook"
    fi

    return 0
}

# Built-in dark mode check (fallback)
_builtin_dark_mode_check() {
    local html_file="$1"

    print_header "Dark Mode Check (built-in)"

    if grep -qi 'color-scheme' "$html_file"; then
        print_success "color-scheme meta found"
    else
        print_warning "Missing color-scheme meta"
    fi

    if grep -qi 'prefers-color-scheme' "$html_file"; then
        print_success "prefers-color-scheme query found"
    else
        print_warning "Missing prefers-color-scheme media query"
    fi

    return 0
}

# Built-in responsive check (fallback)
_builtin_responsive_check() {
    local html_file="$1"

    print_header "Responsive Check (built-in)"

    if grep -qi 'viewport' "$html_file"; then
        print_success "Viewport meta found"
    else
        print_warning "Missing viewport meta"
    fi

    if grep -qi '@media' "$html_file"; then
        print_success "Media queries found"
    else
        print_warning "No media queries found"
    fi

    return 0
}

# =============================================================================
# Email on Acid API Integration
# =============================================================================

# Verify EOA API authentication
eoa_auth() {
    local sandbox="${1:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    else
        if ! load_eoa_credentials; then
            print_error "EOA API credentials not configured"
            print_info "Set up credentials:"
            print_info "  aidevops secret set EOA_API_KEY"
            print_info "  aidevops secret set EOA_API_PASSWORD"
            print_info "Or use sandbox mode: $0 eoa-sandbox <html-file>"
            return 1
        fi
    fi

    print_info "Testing EOA API authentication..."

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/auth" 2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" ]]; then
        print_success "EOA API authentication successful"
        if [[ "$sandbox" == "true" ]]; then
            print_info "Running in sandbox mode (no actual tests created)"
        fi
        return 0
    else
        print_error "EOA API authentication failed (HTTP $http_code)"
        if [[ -n "$body" ]]; then
            echo "  Response: $body"
        fi
        return 1
    fi
}

# List available email clients from EOA
eoa_clients() {
    local sandbox="${1:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "Available Email Clients (EOA)"

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/clients" 2>/dev/null) || true

    if [[ -z "$response" ]]; then
        print_error "No response from EOA API"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        print_warning "jq not installed - showing raw response"
        echo "$response"
        return 0
    fi

    # Parse and display clients by category
    local categories="Application Mobile Web"
    for category in $categories; do
        echo ""
        echo -e "${CYAN}  $category:${NC}"
        echo "$response" | jq -r \
            ".clients | to_entries[] | select(.value.category == \"$category\") | \"    \(.value.id) - \(.value.client) (\(.value.os))\"" \
            2>/dev/null || true
    done

    # Show default clients
    echo ""
    print_info "Default clients:"
    echo "$response" | jq -r \
        '.clients | to_entries[] | select(.value.default == true) | "    \(.value.id) - \(.value.client)"' \
        2>/dev/null || true

    return 0
}

# Get default client list from EOA
eoa_default_clients() {
    local sandbox="${1:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "Default Email Clients (EOA)"

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/clients/default" 2>/dev/null) || true

    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.clients[]' 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi

    return 0
}

# Create an email test on EOA
eoa_create_test() {
    local html_file="$1"
    local subject="${2:-Email Design Test}"
    local clients="${3:-}"
    local sandbox="${4:-false}"
    local image_blocking="${5:-false}"

    if [[ ! -f "$html_file" ]]; then
        print_error "HTML file not found: $html_file"
        return 1
    fi

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        print_error "jq is required for EOA API integration"
        print_info "Install with: brew install jq"
        return 1
    fi

    print_header "Creating EOA Email Test"
    print_info "File: $html_file"
    print_info "Subject: $subject"

    # Read HTML content
    local html_content
    html_content=$(cat "$html_file")

    # Build request JSON
    local request_json
    if [[ -n "$clients" ]]; then
        # Parse comma-separated client list into JSON array
        local clients_json
        clients_json=$(echo "$clients" | tr ',' '\n' | jq -R . | jq -s .)
        request_json=$(jq -n \
            --arg subject "$subject" \
            --arg html "$html_content" \
            --argjson clients "$clients_json" \
            --argjson image_blocking "$image_blocking" \
            '{subject: $subject, html: $html, clients: $clients, image_blocking: $image_blocking}')
    else
        request_json=$(jq -n \
            --arg subject "$subject" \
            --arg html "$html_content" \
            --argjson image_blocking "$image_blocking" \
            '{subject: $subject, html: $html, image_blocking: $image_blocking}')
    fi

    if [[ "$sandbox" == "true" ]]; then
        request_json=$(echo "$request_json" | jq '. + {sandbox: true}')
    fi

    # Submit test
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$request_json" \
        "${EOA_API_BASE}/email/tests" 2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        local test_id
        test_id=$(echo "$body" | jq -r '.id' 2>/dev/null || echo "")

        if [[ -n "$test_id" && "$test_id" != "null" ]]; then
            print_success "Test created: $test_id"
            echo "$body" | jq '.' 2>/dev/null || echo "$body"
            echo ""
            print_info "Check results: $0 eoa-results $test_id"
            print_info "Poll until complete: $0 eoa-poll $test_id"
            echo "$test_id"
        else
            print_error "Test created but no ID returned"
            echo "$body"
        fi
        return 0
    else
        print_error "Failed to create test (HTTP $http_code)"
        if [[ -n "$body" ]]; then
            echo "$body" | jq '.' 2>/dev/null || echo "$body"
        fi
        return 1
    fi
}

# Get test status/info from EOA
eoa_test_info() {
    local test_id="$1"
    local sandbox="${2:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/tests/${test_id}" 2>/dev/null) || true

    if command -v jq &>/dev/null; then
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi

    return 0
}

# Get test results from EOA (with full thumbnails via v5.0.1)
eoa_results() {
    local test_id="$1"
    local client_id="${2:-}"
    local sandbox="${3:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "EOA Test Results: $test_id"

    local url="${EOA_API_BASE_V501}/email/tests/${test_id}/results"
    if [[ -n "$client_id" ]]; then
        url="${url}/${client_id}"
    fi

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "$url" 2>/dev/null) || true

    if [[ -z "$response" ]]; then
        print_error "No response from EOA API"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "$response"
        return 0
    fi

    # Parse and display results by status
    local completed processing bounced
    completed=$(echo "$response" | jq -r '[to_entries[] | select(.value.status == "Complete")] | length' 2>/dev/null || echo "0")
    processing=$(echo "$response" | jq -r '[to_entries[] | select(.value.status == "Processing")] | length' 2>/dev/null || echo "0")
    bounced=$(echo "$response" | jq -r '[to_entries[] | select(.value.status == "Bounced")] | length' 2>/dev/null || echo "0")

    echo ""
    echo "  Completed:  $completed"
    echo "  Processing: $processing"
    echo "  Bounced:    $bounced"
    echo ""

    # Show completed results
    if [[ "$completed" -gt 0 ]]; then
        echo -e "${GREEN}Completed Results:${NC}"
        echo "$response" | jq -r '
            to_entries[]
            | select(.value.status == "Complete")
            | "  \(.value.display_name) [\(.value.category)]"
            + "\n    Screenshot: \(.value.screenshots.default // "N/A")"
            + "\n    Thumbnail:  \(.value.full_thumbnail // .value.thumbnail // "N/A")"
        ' 2>/dev/null || true
    fi

    # Show processing
    if [[ "$processing" -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Still Processing:${NC}"
        echo "$response" | jq -r '
            to_entries[]
            | select(.value.status == "Processing")
            | "  \(.value.display_name) [\(.value.category)]"
        ' 2>/dev/null || true
    fi

    # Show bounced
    if [[ "$bounced" -gt 0 ]]; then
        echo ""
        echo -e "${RED}Bounced:${NC}"
        echo "$response" | jq -r '
            to_entries[]
            | select(.value.status == "Bounced")
            | "  \(.value.display_name) - \(.value.status_details.bounce_code // "unknown") \(.value.status_details.bounce_message // "")"
        ' 2>/dev/null || true
    fi

    return 0
}

# Poll EOA test until all results complete
eoa_poll() {
    local test_id="$1"
    local sandbox="${2:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "Polling EOA Test: $test_id"
    print_info "Checking every ${EOA_POLL_INTERVAL}s (max ${EOA_POLL_MAX_ATTEMPTS} attempts)"

    local attempt=0
    while [[ $attempt -lt $EOA_POLL_MAX_ATTEMPTS ]]; do
        attempt=$((attempt + 1))

        local response
        response=$(curl -s \
            -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
            -H "Accept: application/json" \
            "${EOA_API_BASE}/email/tests/${test_id}" 2>/dev/null) || true

        if [[ -z "$response" ]]; then
            print_warning "No response (attempt $attempt/$EOA_POLL_MAX_ATTEMPTS)"
            sleep "$EOA_POLL_INTERVAL"
            continue
        fi

        local completed_count=0
        local processing_count=0

        if command -v jq &>/dev/null; then
            completed_count=$(echo "$response" | jq -r '.completed | length' 2>/dev/null || echo "0")
            processing_count=$(echo "$response" | jq -r '.processing | length' 2>/dev/null || echo "0")
        else
            # Rough count without jq
            completed_count=$(echo "$response" | grep -c '"completed"' 2>/dev/null || echo "0")
            processing_count=$(echo "$response" | grep -c '"processing"' 2>/dev/null || echo "0")
        fi

        echo -e "  [${attempt}/${EOA_POLL_MAX_ATTEMPTS}] Completed: ${completed_count}, Processing: ${processing_count}"

        if [[ "$processing_count" -eq 0 ]]; then
            print_success "All results complete!"
            echo ""
            eoa_results "$test_id" "" "$sandbox"
            return 0
        fi

        sleep "$EOA_POLL_INTERVAL"
    done

    print_warning "Polling timed out after $EOA_POLL_MAX_ATTEMPTS attempts"
    print_info "Check results manually: $0 eoa-results $test_id"
    return 1
}

# Full EOA test workflow: create + poll + display results
eoa_test() {
    local html_file="$1"
    local subject="${2:-Email Design Test}"
    local clients="${3:-}"
    local sandbox="${4:-false}"

    # Run local tests first
    test_local "$html_file" || true

    echo ""
    print_header "Submitting to Email on Acid"

    # Create test
    local output
    output=$(eoa_create_test "$html_file" "$subject" "$clients" "$sandbox" "false") || return 1

    # Extract test ID (last line of output)
    local test_id
    test_id=$(echo "$output" | tail -1)

    if [[ -z "$test_id" || "$test_id" == "null" ]]; then
        print_error "Could not extract test ID"
        return 1
    fi

    echo ""

    # Poll for results
    eoa_poll "$test_id" "$sandbox"

    return 0
}

# Sandbox test (no API key required)
eoa_sandbox() {
    local html_file="$1"
    local subject="${2:-Sandbox Design Test}"

    print_info "Running in EOA sandbox mode (no actual tests created)"
    eoa_test "$html_file" "$subject" "" "true"

    return 0
}

# Delete an EOA test
eoa_delete() {
    local test_id="$1"

    if ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_info "Deleting EOA test: $test_id"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X DELETE \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/tests/${test_id}" 2>/dev/null) || true

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" == "200" ]]; then
        print_success "Test deleted: $test_id"
    else
        print_error "Failed to delete test (HTTP $http_code)"
    fi

    return 0
}

# List recent EOA tests
eoa_list() {
    local sandbox="${1:-false}"

    if [[ "$sandbox" == "true" ]]; then
        EOA_AUTH_HEADER=$(printf '%s:%s' "$EOA_SANDBOX_USER" "$EOA_SANDBOX_PASS" | base64)
        export EOA_AUTH_HEADER
    elif ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "Recent EOA Tests"

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/tests" 2>/dev/null) || true

    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.[] | "  \(.id) [\(.type)] \(.date | todate)"' 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi

    return 0
}

# Get inlined CSS version of test content
eoa_inline_css() {
    local test_id="$1"

    if ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    print_header "Inlined CSS Content: $test_id"

    local response
    response=$(curl -s \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        "${EOA_API_BASE}/email/tests/${test_id}/content/inlinecss" 2>/dev/null) || true

    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.content' 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi

    return 0
}

# Reprocess failed screenshots
eoa_reprocess() {
    local test_id="$1"
    local clients="$2"

    if ! load_eoa_credentials; then
        print_error "EOA API credentials not configured"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        return 1
    fi

    print_info "Reprocessing screenshots for test: $test_id"

    local clients_json
    clients_json=$(echo "$clients" | tr ',' '\n' | jq -R . | jq -s '{clients: .}')

    local response
    response=$(curl -s \
        -X PUT \
        -H "Authorization: Basic ${EOA_AUTH_HEADER}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$clients_json" \
        "${EOA_API_BASE}/email/tests/${test_id}/results/reprocess" 2>/dev/null) || true

    if command -v jq &>/dev/null; then
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi

    return 0
}

# =============================================================================
# Help and Main
# =============================================================================

show_help() {
    echo "Email Design Test Helper Script"
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Local Testing Commands:"
    echo "  test [html-file]                    Run local design tests (HTML, CSS, a11y, images, links)"
    echo ""
    echo "Email on Acid (EOA) API Commands:"
    echo "  eoa-auth                            Test EOA API authentication"
    echo "  eoa-sandbox [html-file] [subject]   Run full test in sandbox mode (no API key needed)"
    echo "  eoa-test [html-file] [subject] [clients]  Run local + EOA test (full workflow)"
    echo "  eoa-create [html-file] [subject] [clients]  Create EOA test only"
    echo "  eoa-results [test-id] [client-id]   Get test results (screenshots)"
    echo "  eoa-poll [test-id]                  Poll until all results complete"
    echo "  eoa-info [test-id]                  Get test status info"
    echo "  eoa-list                            List recent tests"
    echo "  eoa-clients                         List available email clients"
    echo "  eoa-defaults                        Show default client list"
    echo "  eoa-delete [test-id]                Delete a test"
    echo "  eoa-inline-css [test-id]            Get inlined CSS version of test content"
    echo "  eoa-reprocess [test-id] [clients]   Reprocess failed screenshots"
    echo ""
    echo "General:"
    echo "  help                                $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 test newsletter.html"
    echo "  $0 eoa-sandbox newsletter.html \"My Newsletter\""
    echo "  $0 eoa-test newsletter.html \"Campaign\" outlook16,gmail_chr26_win"
    echo "  $0 eoa-results abc123"
    echo "  $0 eoa-poll abc123"
    echo "  $0 eoa-clients"
    echo ""
    echo "EOA API Credentials:"
    echo "  aidevops secret set EOA_API_KEY"
    echo "  aidevops secret set EOA_API_PASSWORD"
    echo "  Or: export EOA_API_KEY=... EOA_API_PASSWORD=..."
    echo "  Sandbox mode uses built-in test credentials (no setup needed)"
    echo ""
    echo "Dependencies:"
    echo "  Required: curl"
    echo "  Required for EOA: jq"
    echo "  Optional: html-validate (npm), mjml (npm)"
    echo ""
    echo "Related:"
    echo "  email-test-suite-helper.sh    Full design rendering + delivery testing"
    echo "  email-health-check-helper.sh  DNS authentication checks (SPF, DKIM, DMARC)"

    return 0
}

main() {
    local command="${1:-help}"
    local arg1="${2:-}"
    local arg2="${3:-}"
    local arg3="${4:-}"

    case "$command" in
        "test"|"local"|"test-local")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                echo "$HELP_USAGE_INFO"
                exit 1
            fi
            test_local "$arg1"
            ;;
        "eoa-auth"|"auth")
            eoa_auth "false"
            ;;
        "eoa-sandbox"|"sandbox")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            eoa_sandbox "$arg1" "${arg2:-Sandbox Design Test}"
            ;;
        "eoa-test"|"eoa")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            eoa_test "$arg1" "${arg2:-Email Design Test}" "$arg3" "false"
            ;;
        "eoa-create"|"create")
            if [[ -z "$arg1" ]]; then
                print_error "HTML file required"
                exit 1
            fi
            eoa_create_test "$arg1" "${arg2:-Email Design Test}" "$arg3" "false" "false"
            ;;
        "eoa-results"|"results")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            eoa_results "$arg1" "$arg2" "false"
            ;;
        "eoa-poll"|"poll")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            eoa_poll "$arg1" "false"
            ;;
        "eoa-info"|"info")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            eoa_test_info "$arg1" "false"
            ;;
        "eoa-list"|"list")
            eoa_list "false"
            ;;
        "eoa-clients"|"clients")
            eoa_clients "false"
            ;;
        "eoa-defaults"|"defaults")
            eoa_default_clients "false"
            ;;
        "eoa-delete"|"delete")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            eoa_delete "$arg1"
            ;;
        "eoa-inline-css"|"inline-css")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            eoa_inline_css "$arg1"
            ;;
        "eoa-reprocess"|"reprocess")
            if [[ -z "$arg1" ]]; then
                print_error "Test ID required"
                exit 1
            fi
            if [[ -z "$arg2" ]]; then
                print_error "Client list required (comma-separated)"
                exit 1
            fi
            eoa_reprocess "$arg1" "$arg2"
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
