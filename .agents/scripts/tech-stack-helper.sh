#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

# Tech Stack Discovery Helper Script
# Multi-provider website technology detection with common schema output.
# Providers: openexplorer (free, open-source), unbuilt (Unbuilt.app CLI), crft (CRFT Lookup)
#
# Usage: tech-stack-helper.sh <provider> <command> [options]
#        tech-stack-helper.sh providers
#        tech-stack-helper.sh compare <url>

# Source shared constants (SC2034: shared-constants.sh exports vars used by other scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC2034
source "${SCRIPT_DIR}/shared-constants.sh"

# Configuration
readonly CACHE_DIR="$HOME/.aidevops/.agent-workspace/tmp/tech-stack-cache"
readonly CACHE_TTL=3600 # 1 hour cache
readonly REPORTS_DIR="${HOME}/.aidevops/.agent-workspace/work/tech-stack/reports"
SCRIPT_NAME="$(basename "$0")" || true
readonly SCRIPT_NAME
readonly UNBUILT_PKG="@unbuilt/cli"
readonly UNBUILT_TIMEOUT="${UNBUILT_TIMEOUT:-120}"

# CRFT Lookup Configuration
readonly CRFT_BASE_URL="https://crft.studio"
readonly CRFT_LOOKUP_URL="${CRFT_BASE_URL}/lookup"
readonly CRFT_GALLERY_URL="${CRFT_BASE_URL}/lookup/gallery"
readonly CRFT_SCAN_TIMEOUT=60

# Ensure directories exist
mkdir -p "$CACHE_DIR" "$REPORTS_DIR" 2>/dev/null || true

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
	local msg="$1"
	echo -e "${CYAN}=== $msg ===${NC}"
	return 0
}

check_dependencies() {
	local missing=()

	if ! command -v curl &>/dev/null; then
		missing+=("curl")
	fi

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		print_error "Missing required tools: ${missing[*]}"
		print_info "Install with: brew install ${missing[*]}"
		return 1
	fi

	return 0
}

# Normalise URL: strip protocol, trailing slash, www prefix
normalise_url() {
	local url="$1"
	url="${url#https://}"
	url="${url#http://}"
	url="${url#www.}"
	url="${url%/}"
	echo "$url"
	return 0
}

# Normalize domain: strip protocol, trailing slash, www prefix
normalize_domain() {
	local url="$1"
	local domain

	# Strip protocol
	domain="${url#http://}"
	domain="${domain#https://}"
	# Strip trailing slash and path
	domain="${domain%%/*}"
	# Strip port
	domain="${domain%%:*}"

	echo "$domain"
	return 0
}

# Cache key from provider + command + args
cache_key() {
	local provider="$1"
	local command="$2"
	local args="$3"
	echo "${provider}_${command}_$(echo "$args" | tr -c '[:alnum:]' '_')"
	return 0
}

# Check cache freshness
cache_get() {
	local key="$1"
	local cache_file="${CACHE_DIR}/${key}.json"

	if [[ -f "$cache_file" ]]; then
		local file_age
		file_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
		if [[ "$file_age" -lt "$CACHE_TTL" ]]; then
			cat "$cache_file"
			return 0
		fi
	fi

	return 1
}

# Store in cache
cache_set() {
	local key="$1"
	local data="$2"
	echo "$data" >"${CACHE_DIR}/${key}.json"
	return 0
}

# Normalise category from OpenExplorer to common schema
normalise_category() {
	local category="$1"
	local lower
	lower="$(echo "$category" | tr '[:upper:]' '[:lower:]')"

	case "$lower" in
	"frontend framework" | "frontend" | "ui framework")
		echo "frontend-framework"
		;;
	"backend" | "backend framework" | "server")
		echo "backend-framework"
		;;
	"analytics" | "tracking")
		echo "analytics"
		;;
	"cms" | "content management")
		echo "cms"
		;;
	"cdn" | "content delivery")
		echo "cdn"
		;;
	"payment" | "payments" | "billing")
		echo "payment"
		;;
	"performance" | "optimization")
		echo "performance"
		;;
	"security" | "authentication")
		echo "security"
		;;
	"database" | "data store")
		echo "database"
		;;
	"hosting" | "infrastructure")
		echo "hosting"
		;;
	"build tool" | "build tools" | "bundler")
		echo "build-tool"
		;;
	"css framework" | "css" | "styling")
		echo "css-framework"
		;;
	"javascript library" | "js library" | "library")
		echo "js-library"
		;;
	*)
		echo "other"
		;;
	esac
	return 0
}

# =============================================================================
# OpenExplorer Provider
# =============================================================================

# Search OpenExplorer by URL query
openexplorer_search() {
	local query="$1"
	local page="${2:-1}"
	local limit="${3:-20}"

	local normalised
	normalised="$(normalise_url "$query")"

	local key
	key="$(cache_key "openexplorer" "search" "${normalised}_${page}_${limit}")"

	# Check cache
	local cached
	if cached="$(cache_get "$key")"; then
		echo "$cached"
		return 0
	fi

	print_info "Searching OpenExplorer for: $normalised"

	# OpenExplorer.tech is a React SPA with a Supabase backend.
	# The API requires auth credentials, so curl-based scraping is not viable.
	# Return structured guidance pointing to Playwright analysis or the web UI.
	local result
	result="$(jq -n \
		--arg url "$normalised" \
		--arg provider "openexplorer" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            url: $url,
            provider: $provider,
            timestamp: $ts,
            technologies: [],
            metadata: {},
            note: "OpenExplorer.tech is a React SPA. Use Playwright for live analysis or install the Chrome extension for community data collection. See: tech-stack-helper.sh openexplorer analyse <url>"
        }')"

	cache_set "$key" "$result"
	echo "$result"
	return 0
}

# Search OpenExplorer by technology name
openexplorer_tech() {
	local tech_name="$1"
	local page="${2:-1}"
	local limit="${3:-20}"

	local key
	key="$(cache_key "openexplorer" "tech" "${tech_name}_${page}_${limit}")"

	local cached
	if cached="$(cache_get "$key")"; then
		echo "$cached"
		return 0
	fi

	print_info "Searching OpenExplorer for technology: $tech_name"

	# Same SPA limitation applies
	local result
	result="$(jq -n \
		--arg tech "$tech_name" \
		--arg provider "openexplorer" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            query: $tech,
            provider: $provider,
            timestamp: $ts,
            results: [],
            note: "OpenExplorer.tech requires Playwright for search. The Supabase API needs authentication credentials. Use the web UI at https://openexplorer.tech or the Chrome extension."
        }')"

	cache_set "$key" "$result"
	echo "$result"
	return 0
}

# Search OpenExplorer by category
openexplorer_category() {
	local category="$1"
	local page="${2:-1}"
	local limit="${3:-20}"

	local key
	key="$(cache_key "openexplorer" "category" "${category}_${page}_${limit}")"

	local cached
	if cached="$(cache_get "$key")"; then
		echo "$cached"
		return 0
	fi

	print_info "Searching OpenExplorer for category: $category"

	local result
	result="$(jq -n \
		--arg cat "$category" \
		--arg provider "openexplorer" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            query: $cat,
            provider: $provider,
            timestamp: $ts,
            results: [],
            note: "OpenExplorer.tech requires Playwright for category search. Use the web UI at https://openexplorer.tech"
        }')"

	cache_set "$key" "$result"
	echo "$result"
	return 0
}

# Analyse a URL using Playwright (requires npx playwright)
openexplorer_analyse() {
	local url="$1"
	local normalised
	normalised="$(normalise_url "$url")"

	local key
	key="$(cache_key "openexplorer" "analyse" "$normalised")"

	local cached
	if cached="$(cache_get "$key")"; then
		echo "$cached"
		return 0
	fi

	# Check if Playwright is available
	if ! command -v npx &>/dev/null; then
		print_error "npx is required for Playwright analysis"
		print_info "Install Node.js from: https://nodejs.org/"
		return 1
	fi

	print_info "Analysing $normalised via OpenExplorer.tech (Playwright)..."

	# Create a temporary Playwright script
	local tmp_script
	tmp_script="$(mktemp /tmp/oe-analyse-XXXXXX.mjs)"

	cat >"$tmp_script" <<'PLAYWRIGHT_SCRIPT'
import { chromium } from 'playwright';

const url = process.argv[2];
if (!url) {
    console.error('Usage: node script.mjs <url>');
    process.exit(1);
}

(async () => {
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();

    try {
        await page.goto('https://openexplorer.tech', { waitUntil: 'networkidle', timeout: 30000 });

        // Find the search input and enter the URL
        const input = await page.locator('input[type="text"], input[type="search"], input[placeholder*="search" i], input[placeholder*="url" i], input[placeholder*="website" i]').first();
        await input.fill(url);

        // Submit the search (press Enter or click search button)
        await input.press('Enter');

        // Wait for results to load
        await page.waitForTimeout(5000);

        // Extract technology results from the page
        const results = await page.evaluate(() => {
            const technologies = [];
            // Look for technology badges/cards/list items
            const techElements = document.querySelectorAll(
                '[class*="tech"], [class*="badge"], [class*="tag"], [class*="chip"], [data-tech], [class*="technology"]'
            );

            techElements.forEach(el => {
                const name = el.textContent?.trim();
                if (name && name.length > 0 && name.length < 100) {
                    technologies.push({
                        name: name,
                        category: el.getAttribute('data-category') || 'other',
                        confidence: 'community'
                    });
                }
            });

            // Also try table rows if results are in a table
            const rows = document.querySelectorAll('table tbody tr, [class*="result"]');
            rows.forEach(row => {
                const cells = row.querySelectorAll('td, [class*="cell"]');
                if (cells.length >= 2) {
                    const name = cells[0]?.textContent?.trim();
                    const category = cells[1]?.textContent?.trim();
                    if (name && name.length > 0 && name.length < 100) {
                        technologies.push({
                            name: name,
                            category: category || 'other',
                            confidence: 'community'
                        });
                    }
                }
            });

            return technologies;
        });

        // Deduplicate by name
        const seen = new Set();
        const unique = results.filter(t => {
            if (seen.has(t.name)) return false;
            seen.add(t.name);
            return true;
        });

        const output = {
            url: url,
            provider: 'openexplorer',
            timestamp: new Date().toISOString(),
            technologies: unique,
            metadata: {},
            method: 'playwright'
        };

        console.log(JSON.stringify(output, null, 2));
    } catch (err) {
        const output = {
            url: url,
            provider: 'openexplorer',
            timestamp: new Date().toISOString(),
            technologies: [],
            metadata: {},
            error: err.message,
            method: 'playwright'
        };
        console.log(JSON.stringify(output, null, 2));
    } finally {
        await browser.close();
    }
})();
PLAYWRIGHT_SCRIPT

	local result
	if result="$(
		npx --yes playwright test --reporter=list 2>/dev/null
		node "$tmp_script" "$normalised" 2>/dev/null
	)"; then
		# Normalise categories in the result
		if echo "$result" | jq -e '.technologies' &>/dev/null; then
			local normalised_result
			normalised_result="$(echo "$result" | jq '
                .technologies = [.technologies[] | .category = (
                    if (.category | ascii_downcase) == "frontend framework" then "frontend-framework"
                    elif (.category | ascii_downcase) == "backend" then "backend-framework"
                    elif (.category | ascii_downcase) == "analytics" then "analytics"
                    elif (.category | ascii_downcase) == "cms" then "cms"
                    elif (.category | ascii_downcase) == "cdn" then "cdn"
                    elif (.category | ascii_downcase) == "payment" then "payment"
                    elif (.category | ascii_downcase) == "performance" then "performance"
                    elif (.category | ascii_downcase) == "security" then "security"
                    else "other"
                    end
                )]
            ')"
			cache_set "$key" "$normalised_result"
			echo "$normalised_result"
		else
			cache_set "$key" "$result"
			echo "$result"
		fi
	else
		print_warning "Playwright analysis failed. Ensure Playwright browsers are installed:"
		print_info "  npx playwright install chromium"

		local fallback
		fallback="$(jq -n \
			--arg url "$normalised" \
			--arg provider "openexplorer" \
			--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			'{
                url: $url,
                provider: $provider,
                timestamp: $ts,
                technologies: [],
                metadata: {},
                error: "Playwright analysis failed. Install browsers with: npx playwright install chromium",
                method: "playwright"
            }')"
		echo "$fallback"
	fi

	rm -f "$tmp_script"
	return 0
}

# =============================================================================
# Unbuilt Provider
# =============================================================================

# Check if Node.js/npm is available
check_node() {
	if ! command -v node &>/dev/null; then
		print_error "Node.js is not installed. Install Node.js 16+ first."
		return 1
	fi
	return 0
}

# Check if the unbuilt CLI is installed
check_unbuilt() {
	if command -v unbuilt &>/dev/null; then
		return 0
	fi
	# Check npx availability as fallback
	if command -v npx &>/dev/null; then
		return 0
	fi
	return 1
}

# Check if Playwright Chromium is available for local analysis
check_playwright() {
	local pw_path
	for pw_path in "${PLAYWRIGHT_BROWSERS_PATH:-}" "${HOME}/Library/Caches/ms-playwright" "${HOME}/.cache/ms-playwright"; do
		if [[ -z "$pw_path" ]]; then
			continue
		fi
		if [[ -d "$pw_path" ]] && ls "$pw_path"/chromium-* &>/dev/null; then
			return 0
		fi
	done
	return 1
}

install_unbuilt() {
	check_node || return 1

	print_info "Installing ${UNBUILT_PKG} globally..."
	if npm install -g "${UNBUILT_PKG}"; then
		print_success "Installed ${UNBUILT_PKG}"
	else
		print_error "Failed to install ${UNBUILT_PKG}"
		return 1
	fi

	# Install Playwright Chromium if not present
	if ! check_playwright; then
		print_info "Installing Playwright Chromium browser..."
		if npx playwright install chromium; then
			print_success "Playwright Chromium installed"
		else
			print_warning "Playwright install failed. Use --remote flag for server-side analysis."
		fi
	fi

	return 0
}

# Run unbuilt analysis on a URL
run_unbuilt() {
	local url="$1"
	shift

	# Validate URL
	if [[ -z "$url" ]]; then
		print_error "URL is required. Usage: tech-stack-helper.sh unbuilt <url>"
		return 1
	fi

	# Auto-install if missing
	if ! check_unbuilt; then
		print_warning "Unbuilt CLI not found. Installing..."
		install_unbuilt || return 1
	fi

	# Build command args
	local -a cmd_args=()
	local use_json=false
	local use_remote=false

	# Parse passthrough flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json | -j)
			use_json=true
			cmd_args+=("--json")
			;;
		--remote | -r)
			use_remote=true
			cmd_args+=("--remote")
			;;
		--timeout | -t)
			cmd_args+=("--timeout" "${2:-$UNBUILT_TIMEOUT}")
			shift
			;;
		--session | --refresh | --async | -n)
			cmd_args+=("$1")
			;;
		*)
			cmd_args+=("$1")
			;;
		esac
		shift
	done

	# Warn if no Playwright and not using remote
	if [[ "$use_remote" == "false" ]] && ! check_playwright; then
		print_warning "Playwright Chromium not found. Falling back to --remote mode."
		cmd_args+=("--remote")
	fi

	# Run analysis
	local unbuilt_cmd
	if command -v unbuilt &>/dev/null; then
		unbuilt_cmd="unbuilt"
	else
		unbuilt_cmd="npx ${UNBUILT_PKG}"
	fi

	if [[ "$use_json" == "true" ]]; then
		# JSON mode: capture output for potential post-processing
		local raw_output
		raw_output=$($unbuilt_cmd "$url" "${cmd_args[@]}") || {
			print_error "Unbuilt analysis failed for: ${url}"
			return 1
		}
		echo "$raw_output"
	else
		# Human-readable mode: stream output directly
		print_info "Analysing: ${url}"
		$unbuilt_cmd "$url" "${cmd_args[@]}" || {
			print_error "Unbuilt analysis failed for: ${url}"
			return 1
		}
	fi

	return 0
}

# Normalise unbuilt JSON output to common tech-stack schema
normalise_unbuilt() {
	if ! command -v jq &>/dev/null; then
		print_error "jq is required for JSON normalisation. Install with: brew install jq"
		return 1
	fi

	jq '{
        url: .url,
        provider: "unbuilt",
        detected: {
            bundler:          ((.technologies.bundlers // []) | join(", ")),
            ui_library:       ((.technologies.uiLibraries // []) | join(", ")),
            framework:        ((.technologies.frameworks // []) | join(", ")),
            css_framework:    (((.technologies.styling // []) + (.technologies.stylingLibraries // [])) | unique | join(", ")),
            state_management: ((.technologies.stateManagement // []) | join(", ")),
            http_client:      ((.technologies.httpClients // []) | join(", ")),
            router:           ((.technologies.routers // []) | join(", ")),
            i18n:             ((.technologies.translationLibraries // []) | join(", ")),
            date_library:     ((.technologies.dateLibraries // []) | join(", ")),
            analytics:        ((.technologies.analytics // []) | join(", ")),
            monitoring:       ((.technologies.monitoring // []) | join(", ")),
            platform:         ((.technologies.platforms // []) | join(", ")),
            minifier:         ((.technologies.minifiers // []) | join(", ")),
            transpiler:       ((.technologies.transpilers // []) | join(", ")),
            module_system:    ((.technologies.moduleSystems // []) | join(", "))
        }
    } | .detected |= with_entries(select(.value != ""))' || {
		print_error "Failed to normalise Unbuilt JSON output"
		return 1
	}

	return 0
}

# =============================================================================
# CRFT Lookup Provider
# =============================================================================

# Convert domain to gallery slug (e.g., basecamp.com -> basecamp)
domain_to_slug() {
	local domain="$1"

	# Strip www. prefix
	domain="${domain#www.}"
	# Take the part before the TLD for simple domains
	# e.g., basecamp.com -> basecamp, linear.app -> linear
	local slug="${domain%%.*}"

	echo "$slug"
	return 0
}

# Fetch a CRFT gallery report page and extract data
fetch_gallery_report() {
	local domain="$1"
	local slug
	slug=$(domain_to_slug "$domain")

	local gallery_url="${CRFT_GALLERY_URL}/${slug}"
	local response

	print_info "Fetching report from: $gallery_url"

	response=$(curl -sL \
		-H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
		-H "Accept: text/html" \
		--max-time "$CRFT_SCAN_TIMEOUT" \
		"$gallery_url" 2>/dev/null) || {
		print_warning "Could not fetch gallery page for: $domain"
		echo ""
		return 1
	}

	# Check if we got a valid report page (not a 404)
	if echo "$response" | grep -q "Technology Stack\|Performance\|Lighthouse" 2>/dev/null; then
		echo "$response"
		return 0
	fi

	print_warning "No existing report found for: $domain"
	echo ""
	return 1
}

# Parse technologies from HTML report
parse_technologies() {
	local html="$1"
	local json_output="${2:-false}"

	if [[ -z "$html" ]]; then
		print_warning "No HTML content to parse"
		return 1
	fi

	# Extract technology names from icon filenames in the gallery page HTML
	# Icons appear as /icons/React.svg, /icons/Next.js.svg, etc.
	local techs_raw
	techs_raw=$(echo "$html" | grep -oE '/icons/[^."]+' 2>/dev/null |
		sed 's|/icons/||' |
		grep -v "Open Graph" |
		sort -u) || true

	if [[ "$json_output" == "true" ]]; then
		local json_array="["
		local first=true
		while IFS= read -r tech; do
			[[ -z "$tech" ]] && continue
			if [[ "$first" == "true" ]]; then
				first=false
			else
				json_array+=","
			fi
			local escaped_tech
			escaped_tech=$(echo "$tech" | sed 's/"/\\"/g')
			json_array+="{\"name\":\"$escaped_tech\"}"
		done <<<"$techs_raw"
		json_array+="]"
		echo "$json_array"
	else
		if [[ -n "$techs_raw" ]]; then
			echo "$techs_raw"
		else
			print_warning "Could not extract technologies from report"
		fi
	fi

	return 0
}

# Parse Lighthouse scores from HTML report
parse_lighthouse() {
	local html="$1"
	local json_output="${2:-false}"

	if [[ -z "$html" ]]; then
		print_warning "No HTML content to parse"
		return 1
	fi

	# Extract Lighthouse scores from the HTML
	# Scores appear near category labels as plain numbers (0-100)
	# The page has Desktop scores first, then Mobile scores
	local performance accessibility best_practices seo

	# Helper: extract number following a label (portable, no grep -P)
	_extract_score() {
		local label="$1"
		local occurrence="${2:-1}"
		echo "$html" | sed -n "s/.*${label}[^0-9]*\([0-9]\{1,3\}\).*/\1/p" | sed -n "${occurrence}p"
	}

	# Desktop scores (first occurrence)
	performance=$(_extract_score "Performance" 1) || performance=""
	accessibility=$(_extract_score "Accessibility" 1) || accessibility=""
	best_practices=$(_extract_score "Best Practices" 1) || best_practices=""
	seo=$(_extract_score "SEO" 1) || seo=""

	# Mobile scores (second occurrence)
	local m_performance m_accessibility m_best_practices m_seo
	m_performance=$(_extract_score "Performance" 2) || m_performance=""
	m_accessibility=$(_extract_score "Accessibility" 2) || m_accessibility=""
	m_best_practices=$(_extract_score "Best Practices" 2) || m_best_practices=""
	m_seo=$(_extract_score "SEO" 2) || m_seo=""

	if [[ "$json_output" == "true" ]]; then
		cat <<ENDJSON
{
  "desktop": {
    "performance": ${performance:-null},
    "accessibility": ${accessibility:-null},
    "best_practices": ${best_practices:-null},
    "seo": ${seo:-null}
  },
  "mobile": {
    "performance": ${m_performance:-null},
    "accessibility": ${m_accessibility:-null},
    "best_practices": ${m_best_practices:-null},
    "seo": ${m_seo:-null}
  }
}
ENDJSON
	else
		print_header "Lighthouse Scores"
		echo ""
		echo "  Desktop:"
		echo "    Performance:    ${performance:-N/A}"
		echo "    Accessibility:  ${accessibility:-N/A}"
		echo "    Best Practices: ${best_practices:-N/A}"
		echo "    SEO:            ${seo:-N/A}"
		echo ""
		echo "  Mobile:"
		echo "    Performance:    ${m_performance:-N/A}"
		echo "    Accessibility:  ${m_accessibility:-N/A}"
		echo "    Best Practices: ${m_best_practices:-N/A}"
		echo "    SEO:            ${m_seo:-N/A}"
	fi

	return 0
}

# Parse meta tags from HTML report
parse_meta() {
	local html="$1"
	local json_output="${2:-false}"

	if [[ -z "$html" ]]; then
		print_warning "No HTML content to parse"
		return 1
	fi

	# Extract meta information from the report page
	local title description og_image

	# The report page includes the scanned site's meta info (portable sed extraction)
	title=$(echo "$html" | sed -n 's/.*<meta property="og:title" content="\([^"]*\)".*/\1/p' | head -1) || title=""
	description=$(echo "$html" | sed -n 's/.*<meta property="og:description" content="\([^"]*\)".*/\1/p' | head -1) || description=""
	og_image=$(echo "$html" | sed -n 's/.*<meta property="og:image" content="\([^"]*\)".*/\1/p' | head -1) || og_image=""

	if [[ "$json_output" == "true" ]]; then
		local escaped_title escaped_desc
		escaped_title=$(echo "$title" | sed 's/"/\\"/g')
		escaped_desc=$(echo "$description" | sed 's/"/\\"/g')
		cat <<ENDJSON
{
  "title": "$escaped_title",
  "description": "$escaped_desc",
  "og_image": "$og_image"
}
ENDJSON
	else
		print_header "Meta Tags"
		echo ""
		echo "  Title:       ${title:-N/A}"
		echo "  Description: ${description:-N/A}"
		echo "  OG Image:    ${og_image:-N/A}"
	fi

	return 0
}

# Full scan: tech stack + Lighthouse + meta tags
crft_scan() {
	local domain="$1"
	local json_output="${2:-false}"

	domain=$(normalize_domain "$domain")
	local slug
	slug=$(domain_to_slug "$domain")
	local report_url="${CRFT_GALLERY_URL}/${slug}"

	print_header "CRFT Lookup: $domain"
	print_info "Report URL: $report_url"
	echo ""

	local html
	html=$(fetch_gallery_report "$domain") || {
		print_error "Could not fetch report for: $domain"
		print_info "Try scanning manually at: ${CRFT_LOOKUP_URL}"
		print_info "Then re-run this command after the report generates (~20s)"
		return 1
	}

	if [[ -z "$html" ]]; then
		print_error "Empty report for: $domain"
		print_info "The site may not have been scanned yet."
		print_info "Visit ${CRFT_LOOKUP_URL} and submit the URL first."
		return 1
	fi

	if [[ "$json_output" == "true" ]]; then
		local techs_json lighthouse_json meta_json
		techs_json=$(parse_technologies "$html" "true")
		lighthouse_json=$(parse_lighthouse "$html" "true")
		meta_json=$(parse_meta "$html" "true")

		jq -n \
			--arg url "$domain" \
			--arg report_url "$report_url" \
			--argjson technologies "$techs_json" \
			--argjson lighthouse "$lighthouse_json" \
			--argjson meta "$meta_json" \
			'{url: $url, report_url: $report_url, technologies: $technologies, lighthouse: $lighthouse, meta: $meta}'
	else
		parse_technologies "$html" "false"
		echo ""
		parse_lighthouse "$html" "false"
		echo ""
		parse_meta "$html" "false"
		echo ""
		print_info "Full report: $report_url"
	fi

	# Cache the report
	local cache_file
	cache_file="${REPORTS_DIR}/${slug}-$(date -u +%Y%m%d).html"
	echo "$html" >"$cache_file" 2>/dev/null || true

	return 0
}

# Technology detection only
crft_techs() {
	local domain="$1"
	local json_output="${2:-false}"

	domain=$(normalize_domain "$domain")

	print_header "Tech Stack: $domain"
	echo ""

	local html
	html=$(fetch_gallery_report "$domain") || {
		print_error "Could not fetch report for: $domain"
		return 1
	}

	if [[ -z "$html" ]]; then
		print_error "Empty report for: $domain"
		return 1
	fi

	parse_technologies "$html" "$json_output"
	return 0
}

# Lighthouse scores only
crft_lighthouse() {
	local domain="$1"
	local json_output="${2:-false}"

	domain=$(normalize_domain "$domain")

	local html
	html=$(fetch_gallery_report "$domain") || {
		print_error "Could not fetch report for: $domain"
		return 1
	}

	if [[ -z "$html" ]]; then
		print_error "Empty report for: $domain"
		return 1
	fi

	parse_lighthouse "$html" "$json_output"
	return 0
}

# Meta tags only
crft_meta() {
	local domain="$1"
	local json_output="${2:-false}"

	domain=$(normalize_domain "$domain")

	local html
	html=$(fetch_gallery_report "$domain") || {
		print_error "Could not fetch report for: $domain"
		return 1
	}

	if [[ -z "$html" ]]; then
		print_error "Empty report for: $domain"
		return 1
	fi

	parse_meta "$html" "$json_output"
	return 0
}

# Compare two sites
crft_compare() {
	local domain1="$1"
	local domain2="$2"
	local json_output="${3:-false}"

	domain1=$(normalize_domain "$domain1")
	domain2=$(normalize_domain "$domain2")

	print_header "Comparing: $domain1 vs $domain2"
	echo ""

	local html1 html2
	html1=$(fetch_gallery_report "$domain1") || true
	html2=$(fetch_gallery_report "$domain2") || true

	if [[ -z "$html1" ]]; then
		print_error "Could not fetch report for: $domain1"
		return 1
	fi

	if [[ -z "$html2" ]]; then
		print_error "Could not fetch report for: $domain2"
		return 1
	fi

	if [[ "$json_output" == "true" ]]; then
		local techs1 techs2 lh1 lh2
		techs1=$(parse_technologies "$html1" "true")
		techs2=$(parse_technologies "$html2" "true")
		lh1=$(parse_lighthouse "$html1" "true")
		lh2=$(parse_lighthouse "$html2" "true")

		jq -n \
			--arg site1 "$domain1" \
			--arg site2 "$domain2" \
			--argjson techs1 "$techs1" \
			--argjson techs2 "$techs2" \
			--argjson lighthouse1 "$lh1" \
			--argjson lighthouse2 "$lh2" \
			'{site1: $site1, site2: $site2, technologies: {site1: $techs1, site2: $techs2}, lighthouse: {site1: $lighthouse1, site2: $lighthouse2}}'
	else
		echo "--- $domain1 ---"
		parse_technologies "$html1" "false"
		echo ""
		parse_lighthouse "$html1" "false"
		echo ""
		echo "--- $domain2 ---"
		parse_technologies "$html2" "false"
		echo ""
		parse_lighthouse "$html2" "false"
	fi

	return 0
}

# Show report URL for a domain
crft_report_url() {
	local domain="$1"
	domain=$(normalize_domain "$domain")
	local slug
	slug=$(domain_to_slug "$domain")
	echo "${CRFT_GALLERY_URL}/${slug}"
	return 0
}

# =============================================================================
# Provider Management
# =============================================================================

install_provider() {
	local provider="$1"

	case "$provider" in
	unbuilt)
		install_unbuilt
		;;
	*)
		print_error "Unknown provider: ${provider}"
		print_info "Available providers: openexplorer, unbuilt, crft"
		return 1
		;;
	esac

	return $?
}

# List available providers
list_providers() {
	print_header "Available Tech Stack Providers"
	echo ""
	echo "  openexplorer  Free, open-source community-driven detection (~72 techs)"
	echo "                https://openexplorer.tech"
	echo "                Commands: search, tech, category, analyse"
	echo ""
	echo "  unbuilt       Unbuilt.app: real-time frontend JS analysis (MIT)"
	echo "                Detects: bundlers, frameworks, UI libs, styling, state, analytics, monitoring"
	echo "                CLI: npm install -g @unbuilt/cli"
	echo "                Requires: Node.js 16+, Playwright Chromium (or --remote)"
	echo ""
	echo "  crft          CRFT Lookup - free, no API key required (2500+ techs)"
	echo "                https://crft.studio/lookup"
	echo "                Commands: scan, techs, lighthouse, meta, compare, report-url"
	echo ""

	# Show installation status
	echo -e "${CYAN}Installation Status${NC}"
	echo ""
	if check_unbuilt 2>/dev/null; then
		local version
		version=$(unbuilt --version 2>/dev/null || echo "unknown")
		echo -e "  unbuilt: ${GREEN}installed${NC} (${version})"
	else
		echo -e "  unbuilt: ${RED}not installed${NC}"
		echo "           Install: tech-stack-helper.sh install unbuilt"
	fi
	echo ""

	print_info "Usage: tech-stack-helper.sh <provider> <command> [args]"
	return 0
}

# Compare results across providers for a URL
compare_providers() {
	local url="$1"
	local normalised
	normalised="$(normalise_url "$url")"

	print_header "Comparing tech stack providers for: $normalised"
	echo ""

	# OpenExplorer
	echo "--- OpenExplorer ---"
	openexplorer_search "$normalised"
	echo ""

	# Unbuilt
	echo "--- Unbuilt ---"
	run_unbuilt "$normalised" --json 2>/dev/null || echo "Unbuilt analysis unavailable"
	echo ""

	# CRFT Lookup
	echo "--- CRFT Lookup ---"
	crft_scan "$normalised" "false"
	echo ""

	print_info "Add more providers to tech-stack-helper.sh for cross-reference."
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	echo "Tech Stack Discovery Helper"
	echo ""
	echo "${HELP_LABEL_USAGE}"
	echo "  tech-stack-helper.sh <provider> <command> [options]"
	echo "  tech-stack-helper.sh providers"
	echo "  tech-stack-helper.sh compare <url>"
	echo "  tech-stack-helper.sh install <provider>"
	echo ""
	echo "${HELP_LABEL_COMMANDS}"
	echo "  providers                     List available providers"
	echo "  compare <url>                 Compare results across all providers"
	echo "  install <provider>            Install a provider CLI"
	echo ""
	echo "  OpenExplorer Commands:"
	echo "    openexplorer search <url>     Search by URL"
	echo "    openexplorer tech <name>      Search by technology name"
	echo "    openexplorer category <name>  Search by category"
	echo "    openexplorer analyse <url>    Full analysis via Playwright"
	echo ""
	echo "  Unbuilt Commands:"
	echo "    unbuilt <url> [flags]         Analyse a URL with Unbuilt.app CLI"
	echo "    normalise                     Normalise unbuilt JSON (stdin) to common schema (stdout)"
	echo ""
	echo "  CRFT Lookup Commands:"
	echo "    crft scan <domain>            Full analysis (tech + Lighthouse + meta)"
	echo "    crft techs <domain>           Technology detection only"
	echo "    crft lighthouse <domain>      Lighthouse scores only"
	echo "    crft meta <domain>            Meta tag preview only"
	echo "    crft compare <domain1> <domain2>  Compare two sites"
	echo "    crft report-url <domain>      Show report URL"
	echo ""
	echo "${HELP_LABEL_OPTIONS}"
	echo "  --page <n>                    Page number (default: 1)"
	echo "  --limit <n>                   Results per page (default: 20)"
	echo "  --no-cache                    Skip cache"
	echo "  --json, -j                    Output results in JSON format"
	echo "  --remote, -r                  Run analysis on unbuilt.app server"
	echo "  --timeout, -t <secs>          Max wait time (default: 120)"
	echo "  --session                     Use local Chrome profile for auth"
	echo "  --refresh                     Force fresh analysis (bypass cache)"
	echo "  --category <cat>              Filter techs by category"
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  tech-stack-helper.sh openexplorer search github.com"
	echo "  tech-stack-helper.sh openexplorer tech React"
	echo "  tech-stack-helper.sh openexplorer analyse https://example.com"
	echo "  tech-stack-helper.sh unbuilt https://example.com"
	echo "  tech-stack-helper.sh unbuilt https://example.com --json | tech-stack-helper.sh normalise"
	echo "  tech-stack-helper.sh crft scan basecamp.com"
	echo "  tech-stack-helper.sh crft techs linear.app --json"
	echo "  tech-stack-helper.sh crft compare basecamp.com notion.com"
	echo "  tech-stack-helper.sh providers"
	echo "  tech-stack-helper.sh compare github.com"
	echo "  tech-stack-helper.sh install unbuilt"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	check_dependencies || exit 1

	local provider="${1:-help}"
	shift || true

	case "$provider" in
	help | --help | -h)
		show_help
		;;
	providers | list)
		list_providers
		;;
	compare)
		local url="${1:?URL required for compare}"
		compare_providers "$url"
		;;
	install)
		local install_provider_name="${1:-}"
		if [[ -z "$install_provider_name" ]]; then
			print_error "Provider name required. Usage: tech-stack-helper.sh install <provider>"
			return 1
		fi
		install_provider "$install_provider_name"
		;;
	normalise | normalize)
		normalise_unbuilt
		;;
	openexplorer)
		local command="${1:-help}"
		shift || true

		case "$command" in
		search)
			local query="${1:?URL or query required}"
			openexplorer_search "$query" "${2:-1}" "${3:-20}"
			;;
		tech)
			local tech_name="${1:?Technology name required}"
			openexplorer_tech "$tech_name" "${2:-1}" "${3:-20}"
			;;
		category)
			local category="${1:?Category name required}"
			openexplorer_category "$category" "${2:-1}" "${3:-20}"
			;;
		analyse | analyze)
			local url="${1:?URL required for analysis}"
			openexplorer_analyse "$url"
			;;
		help | --help | -h)
			show_help
			;;
		*)
			print_error "Unknown openexplorer command: $command"
			show_help
			return 1
			;;
		esac
		;;
	unbuilt)
		run_unbuilt "$@"
		;;
	crft)
		local command="${1:-help}"
		shift || true

		# Parse arguments
		local target=""
		local target2=""
		local json_output=false
		local category=""

		local opt
		while [[ $# -gt 0 ]]; do
			opt="$1"
			case "$opt" in
			--json | -j)
				json_output=true
				shift
				;;
			--category | -c)
				category="${2:-}"
				shift 2
				;;
			-*)
				print_error "Unknown option: $opt"
				return 1
				;;
			*)
				if [[ -z "$target" ]]; then
					target="$opt"
				elif [[ -z "$target2" ]]; then
					target2="$opt"
				fi
				shift
				;;
			esac
		done

		case "$command" in
		"scan" | "analyze" | "check")
			if [[ -z "$target" ]]; then
				print_error "Domain required"
				print_info "Usage: tech-stack-helper.sh crft scan <domain>"
				return 1
			fi
			crft_scan "$target" "$json_output"
			;;
		"techs" | "technologies" | "tech" | "stack")
			if [[ -z "$target" ]]; then
				print_error "Domain required"
				print_info "Usage: tech-stack-helper.sh crft techs <domain>"
				return 1
			fi
			crft_techs "$target" "$json_output"
			;;
		"lighthouse" | "lh" | "scores" | "performance")
			if [[ -z "$target" ]]; then
				print_error "Domain required"
				print_info "Usage: tech-stack-helper.sh crft lighthouse <domain>"
				return 1
			fi
			crft_lighthouse "$target" "$json_output"
			;;
		"meta" | "metatags" | "og")
			if [[ -z "$target" ]]; then
				print_error "Domain required"
				print_info "Usage: tech-stack-helper.sh crft meta <domain>"
				return 1
			fi
			crft_meta "$target" "$json_output"
			;;
		"compare" | "diff" | "vs")
			if [[ -z "$target" || -z "$target2" ]]; then
				print_error "Two domains required"
				print_info "Usage: tech-stack-helper.sh crft compare <domain1> <domain2>"
				return 1
			fi
			crft_compare "$target" "$target2" "$json_output"
			;;
		"report-url" | "url" | "link")
			if [[ -z "$target" ]]; then
				print_error "Domain required"
				print_info "Usage: tech-stack-helper.sh crft report-url <domain>"
				return 1
			fi
			crft_report_url "$target"
			;;
		"help" | "-h" | "--help" | "")
			show_help
			;;
		*)
			print_error "Unknown crft command: $command"
			print_info "Use 'tech-stack-helper.sh help' for usage information"
			return 1
			;;
		esac
		;;
	*)
		print_error "Unknown provider: $provider"
		list_providers
		return 1
		;;
	esac

	return 0
}

main "$@"
