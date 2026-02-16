#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

# Tech Stack Discovery Helper Script
# Multi-provider website technology detection with common schema output.
# Providers: openexplorer (free, open-source), unbuilt (Unbuilt.app CLI)
#
# Usage: tech-stack-helper.sh <provider> <command> [options]
#        tech-stack-helper.sh providers
#        tech-stack-helper.sh compare <url>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Configuration
readonly CACHE_DIR="$HOME/.aidevops/.agent-workspace/tmp/tech-stack-cache"
readonly CACHE_TTL=3600 # 1 hour cache
readonly UNBUILT_PKG="@unbuilt/cli"
readonly UNBUILT_TIMEOUT="${UNBUILT_TIMEOUT:-120}"
mkdir -p "$CACHE_DIR"

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
	local pw_browsers
	pw_browsers="${HOME}/Library/Caches/ms-playwright"
	if [[ -d "$pw_browsers" ]] && ls "$pw_browsers"/chromium-* &>/dev/null; then
		return 0
	fi
	# Linux path
	pw_browsers="${HOME}/.cache/ms-playwright"
	if [[ -d "$pw_browsers" ]] && ls "$pw_browsers"/chromium-* &>/dev/null; then
		return 0
	fi
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
		raw_output=$($unbuilt_cmd "$url" "${cmd_args[@]}" 2>/dev/null) || {
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
    } | .detected |= with_entries(select(.value != ""))' 2>/dev/null || {
		print_error "Failed to normalise Unbuilt JSON output"
		return 1
	}

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
		print_info "Available providers: openexplorer, unbuilt"
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
	echo "  openexplorer search <url>     Search by URL"
	echo "  openexplorer tech <name>      Search by technology name"
	echo "  openexplorer category <name>  Search by category"
	echo "  openexplorer analyse <url>    Full analysis via Playwright"
	echo ""
	echo "  unbuilt <url> [flags]         Analyse a URL with Unbuilt.app CLI"
	echo "  normalise                     Normalise unbuilt JSON (stdin) to common schema (stdout)"
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
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  tech-stack-helper.sh openexplorer search github.com"
	echo "  tech-stack-helper.sh openexplorer tech React"
	echo "  tech-stack-helper.sh openexplorer analyse https://example.com"
	echo "  tech-stack-helper.sh unbuilt https://example.com"
	echo "  tech-stack-helper.sh unbuilt https://example.com --json | tech-stack-helper.sh normalise"
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
	*)
		print_error "Unknown provider: $provider"
		list_providers
		return 1
		;;
	esac

	return 0
}

main "$@"
