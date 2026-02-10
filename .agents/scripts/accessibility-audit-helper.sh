#!/usr/bin/env bash
# shellcheck disable=SC1091

# Accessibility Audit Helper — unified CLI wrapping axe-core, WAVE, WebAIM contrast, Lighthouse a11y
# Complements accessibility-helper.sh (Lighthouse/pa11y/email/contrast-calc) with
# additional engines: @axe-core/cli for standalone axe scans, WAVE API for visual
# accessibility reports, and WebAIM contrast-checker API for programmatic colour checks.
#
# Usage: accessibility-audit-helper.sh [command] [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly AUDIT_REPORTS_DIR="$HOME/.aidevops/reports/accessibility-audit"
readonly AUDIT_WCAG_LEVEL="${AUDIT_WCAG_LEVEL:-WCAG2AA}"
readonly WAVE_API_KEY="${WAVE_API_KEY:-}"
readonly WAVE_API_URL="https://wave.webaim.org/api/request"
readonly WEBAIMCC_API_URL="https://webaim.org/resources/contrastchecker/"

mkdir -p "$AUDIT_REPORTS_DIR"

# =============================================================================
# Dependency Checks
# =============================================================================

check_axe_cli() {
    if ! command -v axe &> /dev/null; then
        print_error "@axe-core/cli not found"
        print_info "Install: npm install -g @axe-core/cli"
        return 1
    fi
    return 0
}

check_lighthouse() {
    if ! command -v lighthouse &> /dev/null; then
        print_error "Lighthouse CLI not found"
        print_info "Install: npm install -g lighthouse"
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

check_curl() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is required for API calls"
        return 1
    fi
    return 0
}

check_wave_key() {
    if [[ -z "$WAVE_API_KEY" ]]; then
        print_error "WAVE_API_KEY not set"
        print_info "Get a key at https://wave.webaim.org/api/ and export WAVE_API_KEY=<key>"
        print_info "Or: aidevops secret set WAVE_API_KEY"
        return 1
    fi
    return 0
}

install_deps() {
    print_info "Installing accessibility audit dependencies..."

    if ! command -v jq &> /dev/null; then
        if command -v brew &> /dev/null; then
            brew install jq
        else
            print_error "Please install jq manually"
            return 1
        fi
    fi

    if ! command -v axe &> /dev/null; then
        if command -v npm &> /dev/null; then
            npm install -g @axe-core/cli
        else
            print_error "npm required to install @axe-core/cli"
            return 1
        fi
    fi

    if ! command -v lighthouse &> /dev/null; then
        if command -v npm &> /dev/null; then
            npm install -g lighthouse
        else
            print_warning "npm required to install Lighthouse (optional)"
        fi
    fi

    print_success "Dependencies installed"
    return 0
}

# =============================================================================
# axe-core CLI Audit
# =============================================================================

run_axe_audit() {
    local url="$1"
    local tags="${2:-wcag2a,wcag2aa,best-practice}"

    check_axe_cli || return 1

    print_info "Running axe-core audit..."
    print_info "URL: $url"
    print_info "Tags: $tags"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${AUDIT_REPORTS_DIR}/axe_${timestamp}.json"

    local axe_exit=0
    if axe "$url" \
        --tags "$tags" \
        --save "$report_file" \
        --chrome-flags="--headless --no-sandbox --disable-gpu" 2>/dev/null; then
        axe_exit=0
    else
        axe_exit=$?
    fi

    if [[ -s "$report_file" ]]; then
        print_success "Report saved: $report_file"
        parse_axe_report "$report_file"
    else
        print_error "axe-core audit failed (exit $axe_exit)"
        return 1
    fi

    return $axe_exit
}

parse_axe_report() {
    local report_file="$1"

    check_jq || return 1

    echo ""
    print_header_line "axe-core Results"

    local violations
    violations=$(jq '[.[].violations[]] | length' "$report_file" 2>/dev/null || echo "0")
    local passes
    passes=$(jq '[.[].passes[]] | length' "$report_file" 2>/dev/null || echo "0")
    local incomplete
    incomplete=$(jq '[.[].incomplete[]] | length' "$report_file" 2>/dev/null || echo "0")

    echo "  Violations:  $violations"
    echo "  Passes:      $passes"
    echo "  Incomplete:  $incomplete"

    if [[ "$violations" -gt 0 ]]; then
        echo ""
        print_header_line "Violations (must fix)"

        jq -r '
            [.[].violations[]]
            | group_by(.impact)
            | sort_by(
                if .[0].impact == "critical" then 0
                elif .[0].impact == "serious" then 1
                elif .[0].impact == "moderate" then 2
                else 3 end
            )
            | .[][]
            | "  [\(.impact | ascii_upcase)] \(.id): \(.help)"
            + "\n    WCAG: \((.tags | map(select(startswith("wcag"))) | join(", ")) // "n/a")"
            + "\n    Nodes: \(.nodes | length) element(s) affected\n"
        ' "$report_file" 2>/dev/null | head -80
    else
        print_success "No violations found"
    fi

    echo ""
    return 0
}

# =============================================================================
# WAVE API Audit
# =============================================================================

run_wave_audit() {
    local url="$1"
    local report_type="${2:-2}"

    check_curl || return 1
    check_jq || return 1
    check_wave_key || return 1

    print_info "Running WAVE API audit..."
    print_info "URL: $url"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${AUDIT_REPORTS_DIR}/wave_${timestamp}.json"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        "${WAVE_API_URL}?key=${WAVE_API_KEY}&url=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$url', safe=''))" 2>/dev/null || echo "$url")&reporttype=${report_type}" \
        2>/dev/null) || {
        print_error "WAVE API request failed"
        return 1
    }

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "WAVE API returned HTTP $http_code"
        return 1
    fi

    echo "$body" > "$report_file"

    # Check for API-level errors
    local api_error
    api_error=$(echo "$body" | jq -r '.status.error // empty' 2>/dev/null || echo "")
    if [[ -n "$api_error" ]]; then
        print_error "WAVE API error: $api_error"
        return 1
    fi

    print_success "Report saved: $report_file"
    parse_wave_report "$report_file"
    return 0
}

parse_wave_report() {
    local report_file="$1"

    check_jq || return 1

    echo ""
    print_header_line "WAVE Results"

    local errors
    errors=$(jq -r '.categories.error.count // 0' "$report_file" 2>/dev/null)
    local alerts
    alerts=$(jq -r '.categories.alert.count // 0' "$report_file" 2>/dev/null)
    local features
    features=$(jq -r '.categories.feature.count // 0' "$report_file" 2>/dev/null)
    local structure
    structure=$(jq -r '.categories.structure.count // 0' "$report_file" 2>/dev/null)
    local contrast_issues
    contrast_issues=$(jq -r '.categories.contrast.count // 0' "$report_file" 2>/dev/null)
    local aria_items
    aria_items=$(jq -r '.categories.aria.count // 0' "$report_file" 2>/dev/null)

    if [[ "$errors" -gt 0 ]]; then
        echo -e "  Errors:     ${RED}${errors}${NC}"
    else
        echo -e "  Errors:     ${GREEN}0${NC}"
    fi

    if [[ "$alerts" -gt 0 ]]; then
        echo -e "  Alerts:     ${YELLOW}${alerts}${NC}"
    else
        echo -e "  Alerts:     ${GREEN}0${NC}"
    fi

    if [[ "$contrast_issues" -gt 0 ]]; then
        echo -e "  Contrast:   ${RED}${contrast_issues}${NC}"
    else
        echo -e "  Contrast:   ${GREEN}0${NC}"
    fi

    echo "  Features:   $features"
    echo "  Structure:  $structure"
    echo "  ARIA:       $aria_items"

    # Show error details if present
    if [[ "$errors" -gt 0 ]]; then
        echo ""
        print_header_line "Errors (must fix)"
        jq -r '
            .categories.error.items // {}
            | to_entries[]
            | "  \(.key): \(.value.description // "No description")"
            + "\n    Count: \(.value.count // 0)\n"
        ' "$report_file" 2>/dev/null | head -60
    fi

    # Show contrast details if present
    if [[ "$contrast_issues" -gt 0 ]]; then
        echo ""
        print_header_line "Contrast Issues"
        jq -r '
            .categories.contrast.items // {}
            | to_entries[]
            | "  \(.key): \(.value.description // "No description")"
            + "\n    Count: \(.value.count // 0)\n"
        ' "$report_file" 2>/dev/null | head -40
    fi

    echo ""
    return 0
}

# =============================================================================
# WebAIM Contrast Checker API
# =============================================================================

run_webaim_contrast() {
    local fg="$1"
    local bg="$2"

    check_curl || return 1
    check_jq || return 1

    # Strip # prefix for API
    fg="${fg#\#}"
    bg="${bg#\#}"

    print_info "Checking contrast via WebAIM API..."
    print_info "Foreground: #$fg"
    print_info "Background: #$bg"

    local response
    response=$(curl -s "${WEBAIMCC_API_URL}?fcolor=${fg}&bcolor=${bg}&api" 2>/dev/null) || {
        print_error "WebAIM contrast API request failed"
        return 1
    }

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${AUDIT_REPORTS_DIR}/webaim_contrast_${timestamp}.json"
    echo "$response" > "$report_file"

    echo ""
    print_header_line "WebAIM Contrast Check"
    echo "  Foreground: #$fg"
    echo "  Background: #$bg"

    local ratio
    ratio=$(echo "$response" | jq -r '.ratio // "N/A"' 2>/dev/null)
    echo "  Ratio: ${ratio}"
    echo ""

    local aa_normal
    aa_normal=$(echo "$response" | jq -r '.AA // "N/A"' 2>/dev/null)
    local aa_large
    aa_large=$(echo "$response" | jq -r '.AALarge // "N/A"' 2>/dev/null)
    local aaa_normal
    aaa_normal=$(echo "$response" | jq -r '.AAA // "N/A"' 2>/dev/null)
    local aaa_large
    aaa_large=$(echo "$response" | jq -r '.AAALarge // "N/A"' 2>/dev/null)

    _format_pass_fail() {
        local val="$1"
        local label="$2"
        if [[ "$val" == "pass" ]]; then
            echo -e "  ${label}: ${GREEN}PASS${NC}"
        elif [[ "$val" == "fail" ]]; then
            echo -e "  ${label}: ${RED}FAIL${NC}"
        else
            echo "  ${label}: $val"
        fi
        return 0
    }

    _format_pass_fail "$aa_normal" "WCAG AA  Normal text (4.5:1)"
    _format_pass_fail "$aa_large" "WCAG AA  Large text  (3.0:1)"
    _format_pass_fail "$aaa_normal" "WCAG AAA Normal text (7.0:1)"
    _format_pass_fail "$aaa_large" "WCAG AAA Large text  (4.5:1)"

    echo ""
    print_info "Report saved: $report_file"

    if [[ "$aa_normal" == "fail" ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Lighthouse Accessibility Audit
# =============================================================================

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
    local report_file="${AUDIT_REPORTS_DIR}/lighthouse_a11y_${timestamp}.json"

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
    print_header_line "Lighthouse Accessibility Score"

    if [[ "$score" != "N/A" ]]; then
        local pct
        pct=$(awk -v s="$score" 'BEGIN { printf "%.0f", s * 100 }')

        if [[ "$pct" -ge 90 ]]; then
            echo -e "  Score: ${GREEN}${pct}%${NC} (Good)"
        elif [[ "$pct" -ge 50 ]]; then
            echo -e "  Score: ${YELLOW}${pct}%${NC} (Needs Improvement)"
        else
            echo -e "  Score: ${RED}${pct}%${NC} (Poor)"
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
    return 0
}

# =============================================================================
# Full Audit (all engines)
# =============================================================================

run_full_audit() {
    local url="$1"

    print_header_line "Full Accessibility Audit: $url"
    echo ""

    local exit_code=0
    local engines_run=0

    # 1. axe-core
    if command -v axe &> /dev/null; then
        run_axe_audit "$url" || exit_code=1
        engines_run=$((engines_run + 1))
        echo ""
    else
        print_warning "Skipping axe-core (not installed). Install: npm install -g @axe-core/cli"
    fi

    # 2. Lighthouse accessibility
    if command -v lighthouse &> /dev/null; then
        run_lighthouse_a11y "$url" "desktop" || exit_code=1
        engines_run=$((engines_run + 1))
        echo ""
    else
        print_warning "Skipping Lighthouse (not installed). Install: npm install -g lighthouse"
    fi

    # 3. WAVE API (if key available)
    if [[ -n "$WAVE_API_KEY" ]]; then
        run_wave_audit "$url" || exit_code=1
        engines_run=$((engines_run + 1))
        echo ""
    else
        print_warning "Skipping WAVE (no WAVE_API_KEY). Get one at https://wave.webaim.org/api/"
    fi

    print_header_line "Audit Complete ($engines_run engine(s) run)"
    print_info "Reports saved to: $AUDIT_REPORTS_DIR"

    if [[ "$engines_run" -eq 0 ]]; then
        print_error "No audit engines available. Run: $0 install-deps"
        return 1
    fi

    return $exit_code
}

# =============================================================================
# Bulk Audit
# =============================================================================

bulk_audit() {
    local urls_file="$1"
    local engine="${2:-all}"

    if [[ ! -f "$urls_file" ]]; then
        print_error "$ERROR_INPUT_FILE_NOT_FOUND: $urls_file"
        return 1
    fi

    print_header_line "Bulk Accessibility Audit"
    print_info "Processing URLs from: $urls_file"
    print_info "Engine: $engine"

    local count=0
    local failures=0

    while IFS= read -r url; do
        [[ -z "$url" || "$url" =~ ^#.*$ ]] && continue

        count=$((count + 1))
        echo ""
        print_header_line "Site $count: $url"

        local site_exit=0
        case "$engine" in
            axe)
                run_axe_audit "$url" || site_exit=1
                ;;
            lighthouse|lh)
                run_lighthouse_a11y "$url" || site_exit=1
                ;;
            wave)
                run_wave_audit "$url" || site_exit=1
                ;;
            all|*)
                run_full_audit "$url" || site_exit=1
                ;;
        esac

        if [[ "$site_exit" -ne 0 ]]; then
            failures=$((failures + 1))
        fi

        # Rate limit between sites
        sleep 2
    done < "$urls_file"

    echo ""
    print_header_line "Bulk Audit Summary"
    echo "  Sites audited:      $count"
    echo "  Sites with issues:  $failures"
    echo "  Reports:            $AUDIT_REPORTS_DIR"

    if [[ "$failures" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Summary / Compare Engines
# =============================================================================

compare_engines() {
    local url="$1"

    print_header_line "Engine Comparison: $url"
    echo ""

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local summary_file="${AUDIT_REPORTS_DIR}/comparison_${timestamp}.txt"

    {
        echo "Accessibility Engine Comparison"
        echo "URL: $url"
        echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "=========================================="
        echo ""
    } > "$summary_file"

    # axe-core
    if command -v axe &> /dev/null; then
        echo "--- axe-core ---" | tee -a "$summary_file"
        run_axe_audit "$url" 2>&1 | tee -a "$summary_file"
        echo "" | tee -a "$summary_file"
    fi

    # Lighthouse
    if command -v lighthouse &> /dev/null; then
        echo "--- Lighthouse ---" | tee -a "$summary_file"
        run_lighthouse_a11y "$url" 2>&1 | tee -a "$summary_file"
        echo "" | tee -a "$summary_file"
    fi

    # WAVE
    if [[ -n "$WAVE_API_KEY" ]]; then
        echo "--- WAVE ---" | tee -a "$summary_file"
        run_wave_audit "$url" 2>&1 | tee -a "$summary_file"
        echo "" | tee -a "$summary_file"
    fi

    print_info "Comparison saved: $summary_file"
    return 0
}

# =============================================================================
# Status / Dependency Check
# =============================================================================

show_status() {
    print_header_line "Accessibility Audit Tool Status"
    echo ""

    echo -n "  @axe-core/cli:  "
    if command -v axe &> /dev/null; then
        local axe_ver
        axe_ver=$(axe --version 2>/dev/null || echo "unknown")
        echo -e "${GREEN}installed${NC} (v${axe_ver})"
    else
        echo -e "${RED}not installed${NC}  (npm install -g @axe-core/cli)"
    fi

    echo -n "  Lighthouse:     "
    if command -v lighthouse &> /dev/null; then
        local lh_ver
        lh_ver=$(lighthouse --version 2>/dev/null || echo "unknown")
        echo -e "${GREEN}installed${NC} (v${lh_ver})"
    else
        echo -e "${RED}not installed${NC}  (npm install -g lighthouse)"
    fi

    echo -n "  jq:             "
    if command -v jq &> /dev/null; then
        local jq_ver
        jq_ver=$(jq --version 2>/dev/null || echo "unknown")
        echo -e "${GREEN}installed${NC} (${jq_ver})"
    else
        echo -e "${RED}not installed${NC}  (brew install jq)"
    fi

    echo -n "  curl:           "
    if command -v curl &> /dev/null; then
        echo -e "${GREEN}installed${NC}"
    else
        echo -e "${RED}not installed${NC}"
    fi

    echo -n "  WAVE API key:   "
    if [[ -n "$WAVE_API_KEY" ]]; then
        echo -e "${GREEN}configured${NC}"
    else
        echo -e "${YELLOW}not set${NC}  (export WAVE_API_KEY=<key>)"
    fi

    echo ""
    echo "  Reports dir:    $AUDIT_REPORTS_DIR"
    local report_count
    report_count=$(find "$AUDIT_REPORTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  Saved reports:  $report_count"
    echo ""

    return 0
}

# =============================================================================
# Utility
# =============================================================================

print_header_line() {
    local msg="$1"
    echo -e "${PURPLE}--- $msg ---${NC}"
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        "audit"|"full")
            local url="${1:-}"
            if [[ -z "$url" ]]; then
                print_error "Please provide a URL to audit"
                print_info "Usage: $0 audit <url>"
                return 1
            fi
            run_full_audit "$url"
            ;;
        "axe"|"axe-core")
            local url="${1:-}"
            if [[ -z "$url" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 axe <url> [tags]"
                return 1
            fi
            run_axe_audit "$url" "${2:-wcag2a,wcag2aa,best-practice}"
            ;;
        "wave")
            local url="${1:-}"
            if [[ -z "$url" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 wave <url> [report-type]"
                return 1
            fi
            run_wave_audit "$url" "${2:-2}"
            ;;
        "contrast"|"webaim-contrast")
            local fg="${1:-}"
            local bg="${2:-}"
            if [[ -z "$fg" || -z "$bg" ]]; then
                print_error "Please provide foreground and background colours"
                print_info "Usage: $0 contrast <fg-hex> <bg-hex>"
                print_info "Example: $0 contrast '#333333' '#ffffff'"
                return 1
            fi
            run_webaim_contrast "$fg" "$bg"
            ;;
        "lighthouse"|"lh")
            local url="${1:-}"
            if [[ -z "$url" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 lighthouse <url> [desktop|mobile]"
                return 1
            fi
            run_lighthouse_a11y "$url" "${2:-desktop}"
            ;;
        "bulk")
            local urls_file="${1:-}"
            if [[ -z "$urls_file" ]]; then
                print_error "Please provide a file containing URLs"
                print_info "Usage: $0 bulk <urls-file> [engine]"
                return 1
            fi
            bulk_audit "$urls_file" "${2:-all}"
            ;;
        "compare")
            local url="${1:-}"
            if [[ -z "$url" ]]; then
                print_error "Please provide a URL"
                print_info "Usage: $0 compare <url>"
                return 1
            fi
            compare_engines "$url"
            ;;
        "status")
            show_status
            ;;
        "install-deps")
            install_deps
            ;;
        "help"|*)
            print_header_line "Accessibility Audit Helper"
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  audit <url>                    Full audit (axe-core + Lighthouse + WAVE)"
            echo "  axe <url> [tags]               axe-core standalone audit"
            echo "  wave <url> [report-type]        WAVE API accessibility report"
            echo "  contrast <fg-hex> <bg-hex>     WebAIM contrast checker API"
            echo "  lighthouse <url> [strategy]    Lighthouse accessibility-only audit"
            echo "  bulk <urls-file> [engine]      Audit multiple URLs from file"
            echo "  compare <url>                  Run all engines and compare results"
            echo "  status                         Show installed tools and configuration"
            echo "  install-deps                   Install required dependencies"
            echo "  help                           Show this help"
            echo ""
            echo "Engines:"
            echo "  axe-core     @axe-core/cli — standalone axe accessibility scanner"
            echo "  lighthouse   Google Lighthouse — accessibility category audit"
            echo "  wave         WAVE API — WebAIM visual accessibility evaluator"
            echo "  webaim       WebAIM contrast checker API — programmatic colour checks"
            echo ""
            echo "axe-core Tags (comma-separated):"
            echo "  wcag2a, wcag2aa, wcag2aaa, wcag21a, wcag21aa, wcag22aa, best-practice"
            echo ""
            echo "WAVE Report Types:"
            echo "  1 = WAVE report (full)    2 = Statistics only (default)"
            echo "  3 = Categories + items    4 = WAVE + statistics"
            echo ""
            echo "Environment Variables:"
            echo "  WAVE_API_KEY          WAVE API key (required for wave command)"
            echo "  AUDIT_WCAG_LEVEL      Default WCAG level (default: WCAG2AA)"
            echo ""
            echo "Examples:"
            echo "  $0 audit https://example.com"
            echo "  $0 axe https://example.com wcag2aa,wcag21aa"
            echo "  $0 wave https://example.com"
            echo "  $0 contrast '#333333' '#ffffff'"
            echo "  $0 lighthouse https://example.com mobile"
            echo "  $0 bulk websites.txt axe"
            echo "  $0 compare https://example.com"
            echo "  $0 status"
            echo ""
            echo "Reports saved to: $AUDIT_REPORTS_DIR"
            ;;
    esac
}

main "$@"
