#!/usr/bin/env bash
# Google Search Console - Add Service Account to All Properties
# Uses Playwright to automate adding a service account to all GSC properties

set -euo pipefail

WORK_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
GSC_SCRIPT="${WORK_DIR}/gsc-add-user.js"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; return 0; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; return 0; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; return 0; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; return 0; }

show_help() {
    cat << 'HELP'
Usage: gsc-add-user-helper.sh <command> [options]

Commands:
  add <email>           Add service account to all GSC properties
  add <email> <domain>  Add service account to specific domain only
  list                  List all GSC properties (requires logged-in Chrome)
  check <email>         Check which properties have the service account

Options:
  --exclude <domain>    Exclude domain from bulk add (can be repeated)
  --dry-run             Show what would be done without making changes

Examples:
  gsc-add-user-helper.sh add aidevops@project.iam.gserviceaccount.com
  gsc-add-user-helper.sh add aidevops@project.iam.gserviceaccount.com --exclude synel.co.uk
  gsc-add-user-helper.sh list
  gsc-add-user-helper.sh check aidevops@project.iam.gserviceaccount.com

Requirements:
  - Node.js and npm installed
  - Playwright: npm install playwright
  - Chrome browser with logged-in Google session
  - User must have Owner access to GSC properties
HELP
    return 0
}

get_chrome_profile_path() {
    case "$(uname -s)" in
        Darwin)
            echo "${HOME}/Library/Application Support/Google/Chrome/Default"
            ;;
        Linux)
            echo "${HOME}/.config/google-chrome/Default"
            ;;
        MINGW*|CYGWIN*|MSYS*)
            echo "${LOCALAPPDATA}/Google/Chrome/User Data/Default"
            ;;
        *)
            log_error "Unsupported OS"
            exit 1
            ;;
    esac
    return 0
}

ensure_playwright() {
    if ! command -v npx &> /dev/null; then
        log_error "npx not found. Please install Node.js"
        exit 1
    fi
    
    # Check if playwright is available
    if ! npx playwright --version &> /dev/null 2>&1; then
        log_info "Installing Playwright..."
        npm install playwright
    fi
    return 0
}

create_add_script() {
    local service_account="$1"
    local excludes="$2"
    local dry_run="$3"
    local single_domain="${4:-}"
    
    local chrome_profile
    chrome_profile="$(get_chrome_profile_path)"
    
    mkdir -p "${WORK_DIR}"
    
    cat > "${GSC_SCRIPT}" << SCRIPT
import { chromium } from 'playwright';

const SERVICE_ACCOUNT = "${service_account}";
const EXCLUDES = new Set([${excludes}]);
const DRY_RUN = ${dry_run};
const SINGLE_DOMAIN = "${single_domain}";

async function main() {
    console.log("Launching Chrome with user profile...");
    
    const browser = await chromium.launchPersistentContext(
        '${chrome_profile}',
        { headless: false, channel: 'chrome' }
    );
    
    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);
    
    let domains = [];
    
    if (SINGLE_DOMAIN) {
        domains = [SINGLE_DOMAIN];
    } else {
        // Extract all domains from page
        const html = await page.content();
        const domainRegex = /sc-domain:([a-z0-9.-]+)/g;
        const matches = [...html.matchAll(domainRegex)];
        domains = [...new Set(matches.map(m => m[1]))].filter(d => !EXCLUDES.has(d));
    }
    
    console.log(\`Found \${domains.length} properties to process\`);
    
    const results = { success: [], skipped: [], failed: [] };
    
    for (const domain of domains) {
        console.log(\`\\n=== \${domain} ===\`);
        
        try {
            await page.goto(\`https://search.google.com/search-console/users?resource_id=sc-domain:\${domain}\`, 
                { waitUntil: 'networkidle' });
            await page.waitForTimeout(400);
            
            const content = await page.content();
            
            if (content.includes("don't have access")) {
                console.log("  ⏭ No access to property");
                results.failed.push(domain + " (no access)");
                continue;
            }
            
            if (content.includes(SERVICE_ACCOUNT)) {
                console.log("  ⏭ Already has service account");
                results.skipped.push(domain);
                continue;
            }
            
            if (DRY_RUN) {
                console.log("  🔍 Would add service account (dry-run)");
                results.success.push(domain + " (dry-run)");
                continue;
            }
            
            await page.click('text=ADD USER');
            await page.waitForTimeout(400);
            await page.keyboard.type(SERVICE_ACCOUNT, { delay: 5 });
            await page.keyboard.press('Enter');
            await page.waitForTimeout(1000);
            
            console.log("  ✓ Added service account");
            results.success.push(domain);
            
        } catch (error) {
            console.error(\`  ✗ Error: \${error.message}\`);
            results.failed.push(domain);
        }
    }
    
    console.log("\\n========== SUMMARY ==========");
    console.log(\`Added: \${results.success.length}\`);
    results.success.forEach(d => console.log(\`  ✓ \${d}\`));
    console.log(\`Skipped: \${results.skipped.length}\`);
    results.skipped.forEach(d => console.log(\`  ⏭ \${d}\`));
    console.log(\`Failed: \${results.failed.length}\`);
    results.failed.forEach(d => console.log(\`  ✗ \${d}\`));
    
    await browser.close();
}

main().catch(console.error);
SCRIPT
    return 0
}

create_list_script() {
    local chrome_profile
    chrome_profile="$(get_chrome_profile_path)"
    
    mkdir -p "${WORK_DIR}"
    
    cat > "${GSC_SCRIPT}" << SCRIPT
import { chromium } from 'playwright';

async function main() {
    const browser = await chromium.launchPersistentContext(
        '${chrome_profile}',
        { headless: false, channel: 'chrome' }
    );
    
    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);
    
    const html = await page.content();
    const domainRegex = /sc-domain:([a-z0-9.-]+)/g;
    const matches = [...html.matchAll(domainRegex)];
    const domains = [...new Set(matches.map(m => m[1]))].sort();
    
    console.log(\`\\nFound \${domains.length} GSC properties:\\n\`);
    domains.forEach((d, i) => console.log(\`  \${(i+1).toString().padStart(2)}. \${d}\`));
    
    await browser.close();
}

main().catch(console.error);
SCRIPT
    return 0
}

run_script() {
    cd "${WORK_DIR}" || exit
    node "${GSC_SCRIPT}"
    return 0
}

cmd_add() {
    local service_account=""
    local excludes=""
    local dry_run="false"
    local single_domain=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --exclude)
                if [[ -n "$excludes" ]]; then
                    excludes="${excludes}, "
                fi
                excludes="${excludes}'$2'"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            *)
                if [[ -z "$service_account" ]]; then
                    service_account="$1"
                elif [[ -z "$single_domain" ]]; then
                    single_domain="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$service_account" ]]; then
        log_error "Service account email required"
        show_help
        exit 1
    fi
    
    ensure_playwright
    create_add_script "$service_account" "$excludes" "$dry_run" "$single_domain"
    
    log_info "Adding ${service_account} to GSC properties..."
    [[ "$dry_run" == "true" ]] && log_warn "DRY RUN - no changes will be made"
    [[ -n "$excludes" ]] && log_info "Excluding: ${excludes}"
    
    run_script
    return 0
}

cmd_list() {
    ensure_playwright
    create_list_script
    
    log_info "Listing all GSC properties..."
    run_script
    return 0
}

cmd_check() {
    local service_account="$1"
    
    if [[ -z "$service_account" ]]; then
        log_error "Service account email required"
        exit 1
    fi
    
    # Use the GSC MCP to check access
    log_info "Checking GSC API access for ${service_account}..."
    log_info "Run: opencode mcp call google-search-console list-sites"
    return 0
}

# Main
case "${1:-}" in
    add)
        shift
        cmd_add "$@"
        ;;
    list)
        cmd_list
        ;;
    check)
        shift
        cmd_check "${1:-}"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
