#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

# Tech Stack Discovery Helper Script
# Multi-provider website technology detection with common schema output.
# Providers: openexplorer (free, open-source), wappalyzer, httpx+nuclei
#
# Usage: tech-stack-helper.sh <command> [options]
#        tech-stack-helper.sh providers
#        tech-stack-helper.sh compare <url>
#
# Dependencies:
#   Required: curl, jq, sqlite3
#   Optional: wappalyzer (npm), httpx (go), nuclei (go), npx (for Playwright)
#
# BuiltWith API credentials (optional, for reverse lookup):
#   aidevops secret set BUILTWITH_API_KEY
#   Or set in ~/.config/aidevops/credentials.sh:
#     BUILTWITH_API_KEY="your-api-key"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Cache constants
readonly CACHE_DIR="${HOME}/.aidevops/.agent-workspace/work/tech-stack"
readonly CACHE_DB="${CACHE_DIR}/cache.db"
readonly CACHE_TTL_HOURS=24

# Provider constants
readonly WAPPALYZER_TIMEOUT=30
readonly HTTPX_TIMEOUT=10
readonly NUCLEI_TIMEOUT=30

# =============================================================================
# Credential Management
# =============================================================================

# Load BuiltWith API credentials from aidevops secret store or credentials.sh
load_builtwith_credentials() {
	local api_key=""

	# Try gopass first (encrypted)
	if command -v gopass &>/dev/null; then
		api_key=$(gopass show -o "aidevops/BUILTWITH_API_KEY" 2>/dev/null || echo "")
	fi

	# Fallback to credentials.sh
	if [[ -z "$api_key" ]]; then
		local creds_file="${HOME}/.config/aidevops/credentials.sh"
		if [[ -f "$creds_file" ]]; then
			# shellcheck source=/dev/null
			source "$creds_file" 2>/dev/null || true
			api_key="${BUILTWITH_API_KEY:-$api_key}"
		fi
	fi

	# Environment variable override
	api_key="${BUILTWITH_API_KEY:-$api_key}"

	if [[ -z "$api_key" ]]; then
		return 1
	fi

	# Export for use by API functions
	BUILTWITH_API_KEY="$api_key"
	export BUILTWITH_API_KEY
	return 0
}

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
	local msg="$1"
	echo ""
	echo -e "${BLUE}=== $msg ===${NC}"
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

	if ! command -v sqlite3 &>/dev/null; then
		missing+=("sqlite3")
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

# Cache key from provider + command + args
cache_key() {
	local provider="$1"
	local command="$2"
	local args="$3"
	echo "${provider}_${command}_$(echo "$args" | tr -c '[:alnum:]' '_')"
	return 0
}

# Check cache freshness (legacy file-based cache for OpenExplorer)
cache_get() {
	local key="$1"
	local cache_file="${CACHE_DIR}/${key}.json"

	if [[ -f "$cache_file" ]]; then
		local file_age
		file_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
		if [[ "$file_age" -lt $((CACHE_TTL_HOURS * 3600)) ]]; then
			cat "$cache_file"
			return 0
		fi
	fi

	return 1
}

# Store in cache (legacy file-based cache for OpenExplorer)
cache_set() {
	local key="$1"
	local data="$2"
	mkdir -p "$CACHE_DIR"
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
# SQLite Cache Management (for multi-provider lookup)
# =============================================================================

# Initialize SQLite cache database
init_cache() {
	mkdir -p "$CACHE_DIR"

	if [[ ! -f "$CACHE_DB" ]]; then
		sqlite3 "$CACHE_DB" <<EOF
CREATE TABLE IF NOT EXISTS lookups (
    url TEXT PRIMARY KEY,
    technologies TEXT,
    providers TEXT,
    timestamp INTEGER,
    ttl_hours INTEGER DEFAULT 24
);

CREATE INDEX IF NOT EXISTS idx_timestamp ON lookups(timestamp);
CREATE INDEX IF NOT EXISTS idx_url ON lookups(url);
EOF
	fi
	return 0
}

# Get cached result for URL
get_cached_result() {
	local url="$1"
	local now
	now=$(date +%s)
	local cutoff=$((now - CACHE_TTL_HOURS * 3600))

	init_cache

	local result
	result=$(sqlite3 "$CACHE_DB" "SELECT technologies, providers FROM lookups WHERE url = '$url' AND timestamp > $cutoff LIMIT 1" 2>/dev/null || echo "")

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi
	return 1
}

# Store result in cache
store_cached_result() {
	local url="$1"
	local technologies="$2"
	local providers="$3"
	local now
	now=$(date +%s)

	init_cache

	sqlite3 "$CACHE_DB" <<EOF
INSERT OR REPLACE INTO lookups (url, technologies, providers, timestamp, ttl_hours)
VALUES ('$url', '$technologies', '$providers', $now, $CACHE_TTL_HOURS);
EOF
	return 0
}

# Clear cache entries older than N days
clear_cache() {
	local days="${1:-30}"
	local cutoff
	cutoff=$(date -v-"${days}"d +%s 2>/dev/null || date -d "${days} days ago" +%s)

	init_cache

	local deleted
	deleted=$(sqlite3 "$CACHE_DB" "DELETE FROM lookups WHERE timestamp < $cutoff; SELECT changes();" | tail -1)

	echo "Deleted $deleted cache entries older than $days days"
	return 0
}

# Show cache statistics
cache_stats() {
	init_cache

	local total
	total=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM lookups;" 2>/dev/null || echo "0")

	local size
	size=$(du -h "$CACHE_DB" 2>/dev/null | cut -f1 || echo "0")

	local oldest
	oldest=$(sqlite3 "$CACHE_DB" "SELECT datetime(MIN(timestamp), 'unixepoch') FROM lookups;" 2>/dev/null || echo "N/A")

	local newest
	newest=$(sqlite3 "$CACHE_DB" "SELECT datetime(MAX(timestamp), 'unixepoch') FROM lookups;" 2>/dev/null || echo "N/A")

	print_header "Cache Statistics"
	echo "Total entries: $total"
	echo "Cache size: $size"
	echo "Oldest entry: $oldest"
	echo "Newest entry: $newest"
	echo ""
	echo "Top cached domains:"
	sqlite3 "$CACHE_DB" "SELECT url, COUNT(*) as cnt FROM lookups GROUP BY url ORDER BY cnt DESC LIMIT 5;" 2>/dev/null || echo "No data"

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
# Multi-Provider Detection Functions
# =============================================================================

# Detect technologies using Wappalyzer CLI
detect_wappalyzer() {
	local url="$1"

	if ! command -v wappalyzer &>/dev/null; then
		log_warn "Wappalyzer not installed. Install: npm install -g wappalyzer"
		echo "[]"
		return 0
	fi

	local result
	result=$(timeout "$WAPPALYZER_TIMEOUT" wappalyzer "$url" --pretty 2>/dev/null || echo "[]")

	echo "$result"
	return 0
}

# Detect technologies using httpx + nuclei
detect_httpx_nuclei() {
	local url="$1"

	if ! command -v httpx &>/dev/null || ! command -v nuclei &>/dev/null; then
		log_warn "httpx or nuclei not installed. Install: go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest && go install -v github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest"
		echo "[]"
		return 0
	fi

	# Use httpx for basic fingerprinting
	local httpx_result
	httpx_result=$(echo "$url" | httpx -silent -tech-detect -json -timeout "$HTTPX_TIMEOUT" 2>/dev/null || echo "{}")

	# Use nuclei for template-based detection
	local nuclei_result
	nuclei_result=$(echo "$url" | nuclei -silent -t technologies/ -json -timeout "$NUCLEI_TIMEOUT" 2>/dev/null || echo "[]")

	# Merge results
	local merged
	merged=$(jq -s '.[0].technologies // [] + (.[1] | map(.info.name) // []) | unique' <(echo "$httpx_result") <(echo "$nuclei_result") 2>/dev/null || echo "[]")

	echo "$merged"
	return 0
}

# Merge results from multiple providers
merge_provider_results() {
	local wappalyzer_result="$1"
	local httpx_result="$2"

	# Merge and deduplicate
	local merged
	merged=$(jq -s 'add | group_by(.name) | map({name: .[0].name, version: .[0].version, confidence: (. | length), providers: (. | length)})' <(echo "$wappalyzer_result") <(echo "$httpx_result") 2>/dev/null || echo "[]")

	echo "$merged"
	return 0
}

# =============================================================================
# Single-Site Lookup
# =============================================================================

# Perform single-site tech stack lookup
lookup() {
	local url="$1"
	local format="${2:-table}"

	# Normalize URL
	if [[ ! "$url" =~ ^https?:// ]]; then
		url="https://$url"
	fi

	print_header "Analyzing tech stack for $url"

	# Check cache first
	local cached
	if cached=$(get_cached_result "$url"); then
		log_info "Using cached result (< ${CACHE_TTL_HOURS}h old)"
		local technologies
		technologies=$(echo "$cached" | cut -d'|' -f1)
		local providers
		providers=$(echo "$cached" | cut -d'|' -f2)

		format_output "$technologies" "$format"
		return 0
	fi

	# Run providers in parallel
	log_info "Running detection providers..."

	local wappalyzer_result
	wappalyzer_result=$(detect_wappalyzer "$url")

	local httpx_result
	httpx_result=$(detect_httpx_nuclei "$url")

	# Merge results
	local merged
	merged=$(merge_provider_results "$wappalyzer_result" "$httpx_result")

	# Store in cache
	local providers_used=0
	[[ "$wappalyzer_result" != "[]" ]] && ((providers_used++))
	[[ "$httpx_result" != "[]" ]] && ((providers_used++))

	store_cached_result "$url" "$merged" "$providers_used"

	# Format output
	format_output "$merged" "$format"

	return 0
}

# Format output based on requested format
format_output() {
	local technologies="$1"
	local format="$2"

	case "$format" in
	json)
		echo "$technologies" | jq '.'
		;;
	markdown)
		format_markdown "$technologies"
		;;
	table | *)
		format_table "$technologies"
		;;
	esac

	return 0
}

# Format as terminal table
format_table() {
	local technologies="$1"

	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	# Group by category (simplified - would need category mapping in real implementation)
	echo "$technologies" | jq -r '.[] | "  \(.name) \(.version // "")    \(.confidence * 25)% (\(.providers) sources)"' 2>/dev/null || echo "No technologies detected"

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	local total
	total=$(echo "$technologies" | jq 'length' 2>/dev/null || echo "0")
	echo "Total: $total technologies detected"
	echo ""

	return 0
}

# Format as markdown report
format_markdown() {
	local technologies="$1"

	echo "# Tech Stack Report"
	echo ""
	echo "## Detected Technologies"
	echo ""
	echo "$technologies" | jq -r '.[] | "- **\(.name)** \(.version // "") (Confidence: \(.confidence * 25)%, \(.providers) sources)"' 2>/dev/null || echo "No technologies detected"
	echo ""

	return 0
}

# =============================================================================
# Reverse Lookup
# =============================================================================

# Perform reverse lookup to find sites using a technology
reverse_lookup() {
	local technology="$1"
	shift

	local region=""
	local industry=""
	local traffic=""
	local keywords=""

	# Parse optional filters
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--region)
			region="$2"
			shift 2
			;;
		--industry)
			industry="$2"
			shift 2
			;;
		--traffic)
			traffic="$2"
			shift 2
			;;
		--keywords)
			keywords="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	print_header "Finding sites using $technology"

	# Try BuiltWith API first
	if load_builtwith_credentials; then
		reverse_lookup_builtwith "$technology" "$region" "$industry" "$traffic" "$keywords"
		return 0
	fi

	# Fallback to PublicWWW (free, limited)
	log_warn "BuiltWith API not configured. Using PublicWWW (limited results)"
	reverse_lookup_publicwww "$technology" "$keywords"

	return 0
}

# Reverse lookup using BuiltWith API
reverse_lookup_builtwith() {
	local technology="$1"
	local region="$2"
	local industry="$3"
	local traffic="$4"
	local keywords="$5"

	local api_url="https://api.builtwith.com/v20/api.json"
	local params="KEY=${BUILTWITH_API_KEY}&LOOKUP=${technology}"

	[[ -n "$region" ]] && params="${params}&REGION=${region}"
	[[ -n "$industry" ]] && params="${params}&INDUSTRY=${industry}"
	[[ -n "$traffic" ]] && params="${params}&TRAFFIC=${traffic}"

	local result
	result=$(curl -s "${api_url}?${params}" 2>/dev/null || echo "{}")

	echo "$result" | jq -r '.Results[] | "  \(.Domain)    Traffic: \(.Traffic // "Unknown")    Industry: \(.Industry // "Unknown")"' 2>/dev/null || echo "No results found"

	return 0
}

# Reverse lookup using PublicWWW (free alternative)
reverse_lookup_publicwww() {
	local technology="$1"
	local keywords="$2"

	log_warn "PublicWWW integration not yet implemented. Use BuiltWith API for reverse lookup."
	echo "To configure BuiltWith API: aidevops secret set BUILTWITH_API_KEY"

	return 0
}

# =============================================================================
# Provider Management
# =============================================================================

# List available providers
list_providers() {
	print_header "Available Tech Stack Providers"
	echo ""
	echo "  openexplorer  Free, open-source community-driven detection (~72 techs)"
	echo "                https://openexplorer.tech"
	echo "                Commands: search, tech, category, analyse"
	echo ""
	echo "  wappalyzer    NPM-based detection (requires: npm install -g wappalyzer)"
	echo "                Detects 1000+ technologies"
	echo ""
	echo "  httpx+nuclei  Go-based detection (requires: go install httpx, nuclei)"
	echo "                Template-based fingerprinting"
	echo ""
	print_info "Usage: tech-stack-helper.sh <command> [options]"
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

	# Multi-provider lookup
	echo "--- Multi-Provider Lookup ---"
	lookup "$url" "table"

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<EOF
Tech Stack Discovery Helper

${HELP_LABEL_USAGE}
  tech-stack-helper.sh <command> [options]

${HELP_LABEL_COMMANDS}
  lookup <url> [--format <format>]
      Detect tech stack for a single URL using multiple providers
      Formats: table (default), json, markdown

  reverse <technology> [--region <region>] [--industry <industry>] [--traffic <tier>] [--keywords <keywords>]
      Find sites using a specific technology (requires BuiltWith API)
      Filters: region (us, eu, asia), industry (ecommerce, saas), traffic (high, medium, low)

  providers
      List available providers

  compare <url>
      Compare results across all providers

  openexplorer search <url>
      Search by URL (OpenExplorer)

  openexplorer tech <name>
      Search by technology name (OpenExplorer)

  openexplorer category <name>
      Search by category (OpenExplorer)

  openexplorer analyse <url>
      Full analysis via Playwright (OpenExplorer)

  cache-stats
      Show cache statistics

  cache-clear [--older-than <days>]
      Clear cache entries older than N days (default: 30)

  help
      $HELP_SHOW_MESSAGE

${HELP_LABEL_OPTIONS}
  --page <n>                    Page number (default: 1)
  --limit <n>                   Results per page (default: 20)
  --format <format>             Output format: table, json, markdown
  --region <region>             Filter by region (us, eu, asia)
  --industry <industry>         Filter by industry (ecommerce, saas)
  --traffic <tier>              Filter by traffic (high, medium, low)
  --keywords <keywords>         Additional search keywords
  --older-than <days>           Cache clear threshold (default: 30)

${HELP_LABEL_EXAMPLES}
  tech-stack-helper.sh lookup https://vercel.com
  tech-stack-helper.sh lookup vercel.com --format json
  tech-stack-helper.sh reverse "Next.js" --traffic high --region us
  tech-stack-helper.sh openexplorer search github.com
  tech-stack-helper.sh openexplorer analyse https://example.com
  tech-stack-helper.sh providers
  tech-stack-helper.sh compare github.com
  tech-stack-helper.sh cache-stats
  tech-stack-helper.sh cache-clear --older-than 7

Dependencies:
  Required: curl, jq, sqlite3
  Optional: wappalyzer (npm), httpx (go), nuclei (go), npx (for Playwright)

Configuration:
  BuiltWith API (optional, for reverse lookup):
    aidevops secret set BUILTWITH_API_KEY
EOF
	return 0
}

# =============================================================================
# Main Command Router
# =============================================================================

main() {
	check_dependencies || exit 1

	local command="${1:-help}"
	shift || true

	case "$command" in
	help | --help | -h)
		show_help
		;;
	providers)
		list_providers
		;;
	compare)
		local url="${1:?URL required for compare}"
		compare_providers "$url"
		;;
	lookup)
		if [[ $# -lt 1 ]]; then
			log_error "URL required for lookup command"
			echo "$HELP_USAGE_INFO"
			return 1
		fi
		lookup "$@"
		;;
	reverse)
		if [[ $# -lt 1 ]]; then
			log_error "Technology name required for reverse command"
			echo "$HELP_USAGE_INFO"
			return 1
		fi
		reverse_lookup "$@"
		;;
	cache-stats)
		cache_stats
		;;
	cache-clear)
		local days=30
		if [[ "$1" == "--older-than" ]]; then
			days="$2"
		fi
		clear_cache "$days"
		;;
	openexplorer)
		local subcommand="${1:-help}"
		shift || true

		case "$subcommand" in
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
			print_error "Unknown openexplorer command: $subcommand"
			show_help
			return 1
			;;
		esac
		;;
	*)
		log_error "Unknown command: $command"
		echo "$HELP_USAGE_INFO"
		return 1
		;;
	esac

	return 0
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
