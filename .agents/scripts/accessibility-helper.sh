#!/usr/bin/env bash
# shellcheck disable=SC1091

# Accessibility & Contrast Testing Helper Script
# WCAG compliance auditing for websites and HTML emails
# Uses: Lighthouse (accessibility category), pa11y (WCAG runner), contrast checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# Configuration
readonly A11Y_REPORTS_DIR="$HOME/.aidevops/reports/accessibility"
readonly A11Y_WCAG_LEVEL="${A11Y_WCAG_LEVEL:-WCAG2AA}"

# Ensure reports directory exists
mkdir -p "$A11Y_REPORTS_DIR"

# ============================================================================
# Dependency Management
# ============================================================================

check_lighthouse() {
    if ! command -v lighthouse &> /dev/null; then
        print_error "Lighthouse CLI not found"
        print_info "Install: npm install -g lighthouse"
        return 1
    fi
    return 0
}

check_pa11y() {
    if ! command -v pa11y &> /dev/null; then
        print_warning "pa11y not found — install for WCAG-specific testing"
        print_info "Install: npm install -g pa11y"
        return 1
    fi
    return 0
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON parsing"
        print_info "Install: brew install jq"
        return 1
    fi
    return 0
}

install_deps() {
    print_info "Installing accessibility testing dependencies..."

    if ! command -v jq &> /dev/null; then
        if command -v brew &> /dev/null; then
            brew install jq
        else
            print_error "Please install jq manually"
            return 1
        fi
    fi

    if ! command -v lighthouse &> /dev/null; then
        if command -v npm &> /dev/null; then
            npm install -g lighthouse
        else
            print_error "npm required to install Lighthouse"
            return 1
        fi
    fi

    if ! command -v pa11y &> /dev/null; then
        if command -v npm &> /dev/null; then
            npm install -g pa11y
        else
            print_warning "npm required to install pa11y (optional)"
        fi
    fi

    print_success "Dependencies installed"
    return 0
}

# ============================================================================
# Lighthouse Accessibility Audit
# ============================================================================

run_lighthouse_a11y() {
    local url="$1"
    local strategy="${2:-desktop}"

    check_lighthouse || return 1
    check_jq || return 1

    print_info "Running Lighthouse accessibility audit..."
    print_info "URL: $url"
    print_info "Strategy: $strategy"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${A11Y_REPORTS_DIR}/lighthouse_a11y_${timestamp}.json"

    local chrome_flags="--headless --no-sandbox --disable-gpu"
    local form_factor="desktop"
    local screen_emulation="--screenEmulation.disabled"

    if [[ "$strategy" == "mobile" ]]; then
        form_factor="mobile"
        screen_emulation=""
    fi

    if lighthouse "$url" \
        --only-categories=accessibility \
        --output=json \
        --output-path="$report_file" \
        --chrome-flags="$chrome_flags" \
        --preset="$form_factor" \
        ${screen_emulation:+"$screen_emulation"} \
        --quiet 2>/dev/null; then

        print_success "Report saved: $report_file"
        parse_lighthouse_a11y "$report_file"
    else
        print_error "Lighthouse audit failed"
        return 1
    fi

    return 0
}

parse_lighthouse_a11y() {
    local report_file="$1"

    local score
    score=$(jq -r '.categories.accessibility.score // "N/A"' "$report_file")

    echo ""
    print_header_line "Accessibility Score"

    if [[ "$score" != "N/A" ]]; then
        local pct
        pct=$(echo "$score * 100" | bc -l 2>/dev/null || echo "0")
        local int_pct="${pct%.*}"

        if [[ "$int_pct" -ge 90 ]]; then
            echo -e "  Score: ${GREEN}${int_pct}%${NC} (Good)"
        elif [[ "$int_pct" -ge 50 ]]; then
            echo -e "  Score: ${YELLOW}${int_pct}%${NC} (Needs Improvement)"
        else
            echo -e "  Score: ${RED}${int_pct}%${NC} (Poor)"
        fi
    else
        echo "  Score: N/A"
    fi

    echo ""
    print_header_line "Failed Audits"

    local failures
    failures=$(jq -r '
        .audits | to_entries[]
        | select(.value.score != null and .value.score < 1 and .value.scoreDisplayMode == "binary")
        | "  \(.value.id): \(.value.title)"
    ' "$report_file" 2>/dev/null || echo "")

    if [[ -n "$failures" ]]; then
        echo "$failures"
    else
        print_success "No failed accessibility audits"
    fi

    echo ""
    print_header_line "Contrast Issues"

    local contrast
    contrast=$(jq -r '
        .audits["color-contrast"] // empty
        | if .score != null and .score < 1 then
            "  FAIL: \(.title)\n  \(.description // "Elements have insufficient contrast ratio")"
          else
            "  PASS: Color contrast requirements met"
          end
    ' "$report_file" 2>/dev/null || echo "  N/A")

    echo -e "$contrast"

    echo ""
    print_header_line "ARIA Issues"

    local aria_issues
    aria_issues=$(jq -r '
        .audits | to_entries[]
        | select(.key | startswith("aria-"))
        | select(.value.score != null and .value.score < 1)
        | "  FAIL: \(.value.title)"
    ' "$report_file" 2>/dev/null || echo "")

    if [[ -n "$aria_issues" ]]; then
        echo "$aria_issues"
    else
        print_success "No ARIA issues found"
    fi

    echo ""
    return 0
}

# ============================================================================
# pa11y WCAG Testing
# ============================================================================

run_pa11y_audit() {
    local url="$1"
    local standard="${2:-$A11Y_WCAG_LEVEL}"

    check_pa11y || return 1

    print_info "Running pa11y WCAG audit..."
    print_info "URL: $url"
    print_info "Standard: $standard"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${A11Y_REPORTS_DIR}/pa11y_${timestamp}.json"

    if pa11y "$url" \
        --standard "$standard" \
        --reporter json \
        --chromeLaunchConfig '{"args":["--no-sandbox","--headless"]}' \
        > "$report_file" 2>/dev/null; then

        print_success "Report saved: $report_file"
    else
        # pa11y exits non-zero when issues are found — that's expected
        if [[ -s "$report_file" ]]; then
            print_warning "Issues found (report saved: $report_file)"
        else
            print_error "pa11y audit failed"
            return 1
        fi
    fi

    parse_pa11y_report "$report_file"
    return 0
}

parse_pa11y_report() {
    local report_file="$1"

    check_jq || return 1

    local total
    total=$(jq 'length' "$report_file" 2>/dev/null || echo "0")

    local errors
    errors=$(jq '[.[] | select(.type == "error")] | length' "$report_file" 2>/dev/null || echo "0")

    local warnings
    warnings=$(jq '[.[] | select(.type == "warning")] | length' "$report_file" 2>/dev/null || echo "0")

    local notices
    notices=$(jq '[.[] | select(.type == "notice")] | length' "$report_file" 2>/dev/null || echo "0")

    echo ""
    print_header_line "pa11y Results ($A11Y_WCAG_LEVEL)"
    echo "  Total issues: $total"

    if [[ "$errors" -gt 0 ]]; then
        echo -e "  Errors:   ${RED}${errors}${NC}"
    else
        echo -e "  Errors:   ${GREEN}0${NC}"
    fi

    if [[ "$warnings" -gt 0 ]]; then
        echo -e "  Warnings: ${YELLOW}${warnings}${NC}"
    else
        echo -e "  Warnings: ${GREEN}0${NC}"
    fi

    echo "  Notices:  $notices"

    if [[ "$errors" -gt 0 ]]; then
        echo ""
        print_header_line "Errors (must fix)"
        jq -r '
            .[] | select(.type == "error")
            | "  [\(.code)]\n    \(.message)\n    Element: \(.selector)\n"
        ' "$report_file" 2>/dev/null | head -60
    fi

    echo ""
    return 0
}

# ============================================================================
# Email HTML Accessibility Check
# ============================================================================

check_email_a11y() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    print_info "Checking email HTML accessibility: $file"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${A11Y_REPORTS_DIR}/email_a11y_${timestamp}.txt"
    local issues=0
    local warnings=0

    # Run all checks, collecting output to a variable to avoid subshell from tee
    local output=""

    _append() { output="${output}${1}"$'\n'; return 0; }

    # grep -c exits non-zero when count is 0; this wrapper returns "0" cleanly
    _grep_count() { grep -ciE "$@" 2>/dev/null || true; }

    _append "Email Accessibility Report"
    _append "File: $file"
    _append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _append "Standard: WCAG 2.1 AA (email-applicable subset)"
    _append "=========================================="
    _append ""

    # Check: images without alt text
    local total_imgs
    total_imgs=$(_grep_count '<img ' "$file")
    local imgs_with_alt
    imgs_with_alt=$(_grep_count '<img [^>]*alt=' "$file")
    local imgs_missing_alt=$((total_imgs - imgs_with_alt))

    if [[ "$imgs_missing_alt" -gt 0 ]]; then
        _append "FAIL: $imgs_missing_alt image(s) missing alt attribute"
        _append "  WCAG 1.1.1 — All images must have alt text"
        issues=$((issues + imgs_missing_alt))
    else
        _append "PASS: All images have alt attributes ($total_imgs images)"
    fi
    _append ""

    # Check: empty alt on non-decorative images
    local empty_alts
    empty_alts=$(_grep_count '<img [^>]*alt=""' "$file")
    if [[ "$empty_alts" -gt 0 ]]; then
        _append "WARN: $empty_alts image(s) with empty alt=\"\" (OK only if decorative)"
        warnings=$((warnings + 1))
    fi
    _append ""

    # Check: language attribute on html tag
    if grep -qiE '<html[^>]*lang=' "$file" 2>/dev/null; then
        _append "PASS: HTML lang attribute present"
    else
        _append "FAIL: Missing lang attribute on <html> tag"
        _append "  WCAG 3.1.1 — Page language must be specified"
        issues=$((issues + 1))
    fi
    _append ""

    # Check: table role or summary for layout tables
    local tables
    tables=$(_grep_count '<table' "$file")
    local tables_with_role
    tables_with_role=$(_grep_count '<table[^>]*role=' "$file")
    if [[ "$tables" -gt 0 && "$tables_with_role" -eq 0 ]]; then
        _append "WARN: $tables table(s) without role attribute"
        _append "  Email layout tables should have role=\"presentation\""
        warnings=$((warnings + 1))
    elif [[ "$tables" -gt 0 ]]; then
        _append "PASS: Tables have role attributes ($tables_with_role/$tables)"
    fi
    _append ""

    # Check: inline styles with small font sizes
    local small_fonts
    small_fonts=$(_grep_count 'font-size:\s*(([0-9]|1[01])px|0\.[0-9]+em)' "$file")
    if [[ "$small_fonts" -gt 0 ]]; then
        _append "WARN: $small_fonts instance(s) of font-size below 12px"
        _append "  WCAG 1.4.4 — Text should be resizable; small fonts harm readability"
        warnings=$((warnings + 1))
    else
        _append "PASS: No excessively small font sizes detected"
    fi
    _append ""

    # Check: links with descriptive text
    local generic_links
    generic_links=$(_grep_count '<a [^>]*>[[:space:]]*(click here|here|read more|learn more|more)[[:space:]]*</a>' "$file")
    if [[ "$generic_links" -gt 0 ]]; then
        _append "WARN: $generic_links link(s) with generic text (e.g., 'click here')"
        _append "  WCAG 2.4.4 — Link text should describe the destination"
        warnings=$((warnings + 1))
    else
        _append "PASS: No generic link text detected"
    fi
    _append ""

    # Check: sufficient heading structure
    local headings
    headings=$(_grep_count '<h[1-6]' "$file")
    if [[ "$headings" -eq 0 ]]; then
        _append "WARN: No heading elements found"
        _append "  WCAG 1.3.1 — Use headings to convey document structure"
        warnings=$((warnings + 1))
    else
        _append "PASS: $headings heading element(s) found"
    fi
    _append ""

    # Check: color-only information indicators
    local color_only
    color_only=$(_grep_count 'color:\s*(red|green)' "$file")
    if [[ "$color_only" -gt 0 ]]; then
        _append "WARN: $color_only instance(s) of red/green color usage"
        _append "  WCAG 1.4.1 — Do not use color as the only means of conveying information"
        warnings=$((warnings + 1))
    fi
    _append ""

    # Summary
    _append "=========================================="
    _append "Summary: $issues error(s), $warnings warning(s)"
    if [[ "$issues" -eq 0 ]]; then
        _append "Status: PASS (with $warnings advisory warnings)"
    else
        _append "Status: FAIL — $issues issue(s) require attention"
    fi

    # Write report and display (no subshell — issues/warnings preserved)
    echo "$output" | tee "$report_file"

    print_info "Report saved: $report_file"
    echo ""

    if [[ "$issues" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Contrast Ratio Calculator
# ============================================================================

hex_to_rgb() {
    local hex="$1"
    hex="${hex#\#}"

    # Expand shorthand (e.g., #fff -> #ffffff)
    if [[ ${#hex} -eq 3 ]]; then
        hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
    fi

    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))

    echo "$r $g $b"
    return 0
}

relative_luminance() {
    local r="$1"
    local g="$2"
    local b="$3"

    # sRGB to linear, then luminance per WCAG 2.x formula
    # Using awk for floating-point math (bc may not be available)
    awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN {
        rs = r / 255.0
        gs = g / 255.0
        bs = b / 255.0

        if (rs <= 0.03928) rl = rs / 12.92; else rl = ((rs + 0.055) / 1.055) ^ 2.4
        if (gs <= 0.03928) gl = gs / 12.92; else gl = ((gs + 0.055) / 1.055) ^ 2.4
        if (bs <= 0.03928) bl = bs / 12.92; else bl = ((bs + 0.055) / 1.055) ^ 2.4

        printf "%.6f\n", 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
    }'
    return 0
}

check_contrast() {
    local fg="$1"
    local bg="$2"

    local fg_rgb bg_rgb
    fg_rgb=$(hex_to_rgb "$fg")
    bg_rgb=$(hex_to_rgb "$bg")

    local fg_r fg_g fg_b bg_r bg_g bg_b
    read -r fg_r fg_g fg_b <<< "$fg_rgb"
    read -r bg_r bg_g bg_b <<< "$bg_rgb"

    local fg_lum bg_lum
    fg_lum=$(relative_luminance "$fg_r" "$fg_g" "$fg_b")
    bg_lum=$(relative_luminance "$bg_r" "$bg_g" "$bg_b")

    local ratio
    ratio=$(awk -v l1="$fg_lum" -v l2="$bg_lum" 'BEGIN {
        if (l1 > l2) {
            printf "%.2f\n", (l1 + 0.05) / (l2 + 0.05)
        } else {
            printf "%.2f\n", (l2 + 0.05) / (l1 + 0.05)
        }
    }')

    echo ""
    print_header_line "Contrast Ratio Check"
    echo "  Foreground: $fg"
    echo "  Background: $bg"
    echo "  Ratio: ${ratio}:1"
    echo ""

    # WCAG AA: 4.5:1 for normal text, 3:1 for large text
    # WCAG AAA: 7:1 for normal text, 4.5:1 for large text
    local aa_normal aa_large aaa_normal aaa_large
    aa_normal=$(awk -v r="$ratio" 'BEGIN { print (r >= 4.5) ? "PASS" : "FAIL" }')
    aa_large=$(awk -v r="$ratio" 'BEGIN { print (r >= 3.0) ? "PASS" : "FAIL" }')
    aaa_normal=$(awk -v r="$ratio" 'BEGIN { print (r >= 7.0) ? "PASS" : "FAIL" }')
    aaa_large=$(awk -v r="$ratio" 'BEGIN { print (r >= 4.5) ? "PASS" : "FAIL" }')

    echo "  WCAG AA  Normal text (4.5:1): $aa_normal"
    echo "  WCAG AA  Large text  (3.0:1): $aa_large"
    echo "  WCAG AAA Normal text (7.0:1): $aaa_normal"
    echo "  WCAG AAA Large text  (4.5:1): $aaa_large"
    echo ""

    if [[ "$aa_normal" == "FAIL" ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Full Audit (Lighthouse + pa11y combined)
# ============================================================================

run_full_audit() {
    local url="$1"

    print_header_line "Full Accessibility Audit: $url"
    echo ""

    local exit_code=0

    # Lighthouse accessibility
    if check_lighthouse 2>/dev/null; then
        run_lighthouse_a11y "$url" "desktop" || exit_code=1
        echo ""
        run_lighthouse_a11y "$url" "mobile" || exit_code=1
    fi

    echo ""

    # pa11y WCAG
    if check_pa11y 2>/dev/null; then
        run_pa11y_audit "$url" "$A11Y_WCAG_LEVEL" || exit_code=1
    else
        print_warning "Skipping pa11y (not installed). Install: npm install -g pa11y"
    fi

    echo ""
    print_header_line "Audit Complete"
    print_info "Reports saved to: $A11Y_REPORTS_DIR"

    return $exit_code
}

# ============================================================================
# Bulk Audit
# ============================================================================

bulk_audit() {
    local urls_file="$1"

    if [[ ! -f "$urls_file" ]]; then
        print_error "URLs file not found: $urls_file"
        return 1
    fi

    print_header_line "Bulk Accessibility Audit"
    print_info "Processing URLs from: $urls_file"

    local count=0
    local failures=0

    while IFS= read -r url; do
        [[ -z "$url" || "$url" =~ ^#.*$ ]] && continue

        count=$((count + 1))
        echo ""
        print_header_line "Site $count: $url"

        if ! run_full_audit "$url"; then
            failures=$((failures + 1))
        fi

        # Rate limit
        sleep 2
    done < "$urls_file"

    echo ""
    print_header_line "Bulk Audit Summary"
    echo "  Sites audited: $count"
    echo "  Sites with issues: $failures"
    echo "  Reports: $A11Y_REPORTS_DIR"

    if [[ "$failures" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Playwright Contrast Extraction
# ============================================================================

check_playwright() {
    if ! command -v npx &> /dev/null; then
        print_error "npx not found (required for Playwright)"
        print_info "Install Node.js: https://nodejs.org/"
        return 1
    fi
    if ! npx --no-install playwright --version &> /dev/null 2>&1; then
        print_warning "Playwright not installed"
        print_info "Install: npm install playwright && npx playwright install chromium"
        return 1
    fi
    return 0
}

run_playwright_contrast() {
    local url="$1"
    local format="${2:-summary}"
    local level="${3:-AA}"

    check_playwright || return 1

    print_info "Running Playwright contrast extraction..."
    print_info "URL: $url"
    print_info "Format: $format"
    print_info "Level: WCAG $level"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${A11Y_REPORTS_DIR}/playwright_contrast_${timestamp}"
    local script_path="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"

    if [[ ! -f "$script_path" ]]; then
        print_error "Playwright contrast script not found: $script_path"
        return 1
    fi

    local script_dir
    script_dir="$(dirname "$script_path")"
    local exit_code=0

    # Install dependencies if node_modules is missing
    if [[ ! -d "${script_dir}/node_modules" ]]; then
        print_info "Installing Playwright dependencies..."
        if ! (cd "$script_dir" && npm install --silent 2>/dev/null); then
            print_error "Failed to install Playwright dependencies"
            return 1
        fi
    fi

    # Run from the script directory so node resolves local node_modules
    case "$format" in
        "json")
            report_file="${report_file}.json"
            if (cd "$script_dir" && node playwright-contrast.mjs "$url" --format json --level "$level") > "$report_file" 2>&1; then
                exit_code=0
            else
                exit_code=$?
            fi
            ;;
        "markdown"|"md")
            report_file="${report_file}.md"
            if (cd "$script_dir" && node playwright-contrast.mjs "$url" --format markdown --level "$level") > "$report_file" 2>&1; then
                exit_code=0
            else
                exit_code=$?
            fi
            ;;
        "summary"|*)
            report_file="${report_file}.txt"
            if (cd "$script_dir" && node playwright-contrast.mjs "$url" --format summary --level "$level") 2>&1 | tee "$report_file"; then
                exit_code=0
            else
                exit_code=${PIPESTATUS[0]}
            fi
            ;;
    esac

    if [[ "$exit_code" -eq 2 ]]; then
        print_error "Playwright contrast extraction failed"
        return 1
    fi

    print_info "Report saved: $report_file"

    if [[ "$exit_code" -eq 1 ]]; then
        print_warning "Contrast failures detected at WCAG $level"
    else
        print_success "All elements pass WCAG $level contrast requirements"
    fi

    return "$exit_code"
}

# ============================================================================
# Utility
# ============================================================================

print_header_line() {
    local msg="$1"
    echo -e "${PURPLE}--- $msg ---${NC}"
    return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command="${1:-help}"
    local account_name="${2:-}"

    case "$command" in
        "audit"|"check")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide a URL to audit"
                print_info "Usage: $0 audit <url>"
                return 1
            fi
            run_full_audit "$account_name"
            ;;
        "lighthouse"|"lh")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 lighthouse <url> [desktop|mobile]"
                return 1
            fi
            check_jq || return 1
            run_lighthouse_a11y "$account_name" "${3:-desktop}"
            ;;
        "pa11y"|"wcag")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 pa11y <url> [WCAG2A|WCAG2AA|WCAG2AAA]"
                return 1
            fi
            run_pa11y_audit "$account_name" "${3:-$A11Y_WCAG_LEVEL}"
            ;;
        "email")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide an HTML file path"
                print_info "Usage: $0 email <file.html>"
                return 1
            fi
            check_email_a11y "$account_name"
            ;;
        "contrast")
            if [[ -z "$account_name" || -z "${3:-}" ]]; then
                print_error "Please provide foreground and background colors"
                print_info "Usage: $0 contrast <fg-hex> <bg-hex>"
                print_info "Example: $0 contrast '#333333' '#ffffff'"
                return 1
            fi
            check_contrast "$account_name" "$3"
            ;;
        "playwright-contrast"|"pw-contrast"|"extract-contrast")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 playwright-contrast <url> [json|markdown|summary] [AA|AAA]"
                return 1
            fi
            run_playwright_contrast "$account_name" "${3:-summary}" "${4:-AA}"
            ;;
        "bulk")
            if [[ -z "$account_name" ]]; then
                print_error "Please provide a file containing URLs"
                print_info "Usage: $0 bulk <urls-file>"
                return 1
            fi
            bulk_audit "$account_name"
            ;;
        "install-deps")
            install_deps
            ;;
        "help"|*)
            print_header_line "Accessibility & Contrast Testing Helper"
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  audit <url>                    Full accessibility audit (Lighthouse + pa11y)"
            echo "  lighthouse <url> [strategy]    Lighthouse accessibility-only audit"
            echo "  pa11y <url> [standard]         pa11y WCAG compliance test"
            echo "  email <file.html>              Check HTML email accessibility"
            echo "  contrast <fg-hex> <bg-hex>     Calculate WCAG contrast ratio"
            echo "  playwright-contrast <url> [fmt] [level]"
            echo "                                 Extract contrast from all visible elements via Playwright"
            echo "                                 Formats: json, markdown, summary (default)"
            echo "                                 Levels: AA (default), AAA"
            echo "  bulk <urls-file>               Audit multiple URLs from file"
            echo "  install-deps                   Install required dependencies"
            echo "  help                           Show this help"
            echo ""
            echo "Standards: WCAG2A, WCAG2AA (default), WCAG2AAA"
            echo "Strategies: desktop (default), mobile"
            echo ""
            echo "Environment Variables:"
            echo "  A11Y_WCAG_LEVEL    Default WCAG level (default: WCAG2AA)"
            echo ""
            echo "Examples:"
            echo "  $0 audit https://example.com"
            echo "  $0 lighthouse https://example.com mobile"
            echo "  $0 pa11y https://example.com WCAG2AAA"
            echo "  $0 email ./newsletter.html"
            echo "  $0 contrast '#333333' '#ffffff'"
            echo "  $0 playwright-contrast https://example.com json AAA"
            echo "  $0 bulk websites.txt"
            echo ""
            echo "Reports saved to: $A11Y_REPORTS_DIR"
            ;;
    esac
}

main "$@"
