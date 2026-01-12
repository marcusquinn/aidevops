#!/usr/bin/env bash
# Google Search Console - Sitemap Submission Helper
# Uses Playwright to automate sitemap submissions to GSC
# Part of AI DevOps Framework

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Configuration
readonly CONFIG_FILE="${HOME}/.config/aidevops/gsc-config.json"
readonly WORK_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly GSC_SCRIPT="${WORK_DIR}/gsc-sitemap-submit.js"
readonly CHROME_PROFILE="${HOME}/.aidevops/.agent-workspace/chrome-gsc-profile"
readonly SCREENSHOT_DIR="/tmp/gsc-screenshots"
readonly DEFAULT_SITEMAP="sitemap.xml"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

show_help() {
    cat << 'HELP'
Usage: gsc-sitemap-helper.sh <command> [options]

Commands:
  submit <domain...>      Submit sitemap for one or more domains
  submit --file <file>    Submit sitemaps for domains listed in file
  status <domain>         Check sitemap status for a domain
  list <domain>           List all sitemaps for a domain
  login                   Open browser to login to Google (first-time setup)
  setup                   Install dependencies (Node.js, Playwright)
  help                    Show this help message

Options:
  --sitemap <path>        Custom sitemap path (default: sitemap.xml)
  --dry-run               Show what would be done without making changes
  --skip-existing         Skip domains that already have sitemaps
  --headless              Run in headless mode (after initial login)
  --timeout <ms>          Timeout in milliseconds (default: 60000)

Examples:
  gsc-sitemap-helper.sh submit example.com
  gsc-sitemap-helper.sh submit example.com example.net example.org
  gsc-sitemap-helper.sh submit --file domains.txt
  gsc-sitemap-helper.sh submit example.com --sitemap news-sitemap.xml
  gsc-sitemap-helper.sh status example.com
  gsc-sitemap-helper.sh login

Requirements:
  - Node.js and npm installed
  - Playwright: npm install playwright
  - Chrome browser installed
  - User logged into Google in the Chrome profile

First-time setup:
  1. Run: gsc-sitemap-helper.sh setup
  2. Run: gsc-sitemap-helper.sh login
  3. Log into Google in the browser that opens
  4. Close browser when done
  5. Now you can submit sitemaps
HELP
}

get_chrome_profile_path() {
    echo "${CHROME_PROFILE}"
    return 0
}

ensure_directories() {
    mkdir -p "${WORK_DIR}"
    mkdir -p "${CHROME_PROFILE}"
    mkdir -p "${SCREENSHOT_DIR}"
    return 0
}

ensure_playwright() {
    if ! command -v npx &> /dev/null; then
        log_error "npx not found. Please install Node.js"
        return 1
    fi
    
    # Check if playwright is available in WORK_DIR
    if [[ ! -d "${WORK_DIR}/node_modules/playwright" ]]; then
        log_info "Installing Playwright in ${WORK_DIR}..."
        # Install in WORK_DIR to avoid polluting other projects
        npm --prefix "${WORK_DIR}" install playwright > /dev/null 2>&1 || {
            log_error "Failed to install Playwright"
            return 1
        }
    fi
    return 0
}

# Sanitize domain for safe embedding in JavaScript
sanitize_domain() {
    local domain="$1"
    # Remove any characters that could break JS string literals
    # Allow only alphanumeric, dots, and hyphens (valid domain chars)
    echo "$domain" | tr -cd 'a-zA-Z0-9.-'
}

create_submit_script() {
    local domains_json="$1"
    local sitemap_path="$2"
    local dry_run="$3"
    local headless="$4"
    local timeout="$5"
    
    local chrome_profile
    chrome_profile="$(get_chrome_profile_path)"
    
    cat > "${GSC_SCRIPT}" << SCRIPT
import { chromium } from 'playwright';

const DOMAINS = ${domains_json};
const SITEMAP_PATH = "${sitemap_path}";
const DRY_RUN = ${dry_run};
const HEADLESS = ${headless};
const TIMEOUT = ${timeout};
const SCREENSHOT_DIR = "${SCREENSHOT_DIR}";

async function waitForGSCLoad(page) {
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(2000);
}

async function main() {
    console.log("=".repeat(60));
    console.log("Google Search Console - Sitemap Submission Tool");
    console.log("=".repeat(60));
    
    const browser = await chromium.launchPersistentContext(
        '${chrome_profile}',
        { 
            headless: HEADLESS, 
            channel: 'chrome',
            ignoreDefaultArgs: ['--enable-automation'],
            args: [
                '--disable-blink-features=AutomationControlled',
                '--disable-infobars',
                '--no-first-run',
                '--no-default-browser-check'
            ],
            viewport: { width: 1400, height: 900 }
        }
    );
    
    const page = await browser.newPage();
    const results = { success: [], skipped: [], failed: [] };
    
    for (let i = 0; i < DOMAINS.length; i++) {
        const domain = DOMAINS[i];
        console.log(\`\\n\${'─'.repeat(60)}\`);
        console.log(\`[\${i + 1}/\${DOMAINS.length}] \${domain}\`);
        console.log('─'.repeat(60));
        
        try {
            const gscUrl = \`https://search.google.com/search-console/sitemaps?resource_id=sc-domain:\${domain}\`;
            console.log(\`Opening: \${gscUrl}\`);
            await page.goto(gscUrl, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });
            await waitForGSCLoad(page);
            
            const pageContent = await page.content();
            if (pageContent.includes("don't have access") || pageContent.includes("Request access")) {
                console.log(\`⏭ No access to \${domain}\`);
                results.failed.push(\`\${domain} (no access)\`);
                continue;
            }
            
            // Check for existing sitemap in table
            const sitemapInTable = await page.\$('table:has-text("' + SITEMAP_PATH + '")') ||
                                   await page.\$('tr:has-text("' + SITEMAP_PATH + '")') ||
                                   await page.\$('[role="row"]:has-text("' + SITEMAP_PATH + '")') ||
                                   await page.\$('a:has-text("' + SITEMAP_PATH + '")');
            
            if (sitemapInTable) {
                console.log(\`⏭ Sitemap already submitted for \${domain}\`);
                results.skipped.push(domain);
                continue;
            }
            
            if (DRY_RUN) {
                console.log(\`🔍 Would submit sitemap for \${domain} (dry-run)\`);
                results.success.push(\`\${domain} (dry-run)\`);
                continue;
            }
            
            // Find the "Add a new sitemap" input
            console.log("Looking for 'Add a new sitemap' input...");
            const addSitemapSection = await page.\$('text="Add a new sitemap"');
            
            let input = null;
            if (addSitemapSection) {
                const container = await addSitemapSection.evaluateHandle(el => {
                    let parent = el.parentElement;
                    for (let i = 0; i < 5; i++) {
                        if (parent && parent.querySelector('input')) {
                            return parent;
                        }
                        parent = parent?.parentElement;
                    }
                    return parent;
                });
                input = await container.\$('input');
            }
            
            // Fallback: find input that's not search
            if (!input) {
                const allInputs = await page.\$\$('input[type="text"]');
                for (const inp of allInputs) {
                    const placeholder = await inp.getAttribute('placeholder') || '';
                    const ariaLabel = await inp.getAttribute('aria-label') || '';
                    if (placeholder.toLowerCase().includes('search') || 
                        ariaLabel.toLowerCase().includes('search') ||
                        placeholder.toLowerCase().includes('filter')) {
                        continue;
                    }
                    input = inp;
                    break;
                }
            }
            
            if (!input) {
                console.log(\`✗ No 'Add sitemap' input found for \${domain}\`);
                await page.screenshot({ path: \`\${SCREENSHOT_DIR}/\${domain.replace(/\\./g, '-')}-error.png\`, fullPage: true });
                results.failed.push(\`\${domain} (no input)\`);
                continue;
            }
            
            // Fill with full URL - use domain as-is (don't force www.)
            // GSC accepts both www and non-www depending on how the property is verified
            const fullSitemapUrl = \`https://\${domain}/\${SITEMAP_PATH}\`;
            console.log(\`Found input, filling \${fullSitemapUrl}...\`);
            await input.click();
            await page.waitForTimeout(300);
            await input.fill(fullSitemapUrl);
            await page.waitForTimeout(500);
            
            await page.screenshot({ path: \`\${SCREENSHOT_DIR}/\${domain.replace(/\\./g, '-')}-filled.png\`, fullPage: true });
            
            // Find and click SUBMIT button relative to input
            console.log("Clicking SUBMIT button...");
            try {
                await page.waitForTimeout(500);
                
                const submitBtn = await input.evaluateHandle(el => {
                    let parent = el.parentElement;
                    for (let i = 0; i < 10; i++) {
                        if (!parent) break;
                        const btn = parent.querySelector('[role="button"]');
                        if (btn && btn.textContent.trim().toUpperCase() === 'SUBMIT') {
                            return btn;
                        }
                        parent = parent.parentElement;
                    }
                    return null;
                });
                
                if (submitBtn) {
                    await submitBtn.click();
                } else {
                    throw new Error("Could not find SUBMIT button near input");
                }
                
                await page.waitForTimeout(3000);
                await waitForGSCLoad(page);
                
                await page.screenshot({ path: \`\${SCREENSHOT_DIR}/\${domain.replace(/\\./g, '-')}-submitted.png\`, fullPage: true });
                console.log(\`✓ Submitted sitemap for \${domain}\`);
                results.success.push(domain);
                
            } catch (e) {
                console.log(\`Submit failed: \${e.message}\`);
                await page.screenshot({ path: \`\${SCREENSHOT_DIR}/\${domain.replace(/\\./g, '-')}-submit-error.png\`, fullPage: true });
                results.failed.push(\`\${domain} (submit failed)\`);
            }
            
        } catch (error) {
            console.error(\`✗ Error for \${domain}: \${error.message}\`);
            results.failed.push(\`\${domain} (error)\`);
        }
        
        await page.waitForTimeout(1000);
    }
    
    // Summary
    console.log("\\n" + "=".repeat(60));
    console.log("SUMMARY");
    console.log("=".repeat(60));
    console.log(\`\\n✓ Submitted: \${results.success.length}\`);
    results.success.forEach(d => console.log(\`    \${d}\`));
    console.log(\`\\n⏭ Already done: \${results.skipped.length}\`);
    results.skipped.forEach(d => console.log(\`    \${d}\`));
    console.log(\`\\n✗ Failed: \${results.failed.length}\`);
    results.failed.forEach(d => console.log(\`    \${d}\`));
    
    await browser.close();
    
    // Exit with error if any failed
    if (results.failed.length > 0) {
        process.exit(1);
    }
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
SCRIPT
    return 0
}

create_status_script() {
    local domain="$1"
    local chrome_profile
    chrome_profile="$(get_chrome_profile_path)"
    
    cat > "${GSC_SCRIPT}" << SCRIPT
import { chromium } from 'playwright';

const DOMAIN = "${domain}";

async function main() {
    const browser = await chromium.launchPersistentContext(
        '${chrome_profile}',
        { 
            headless: false, 
            channel: 'chrome',
            ignoreDefaultArgs: ['--enable-automation'],
            args: [
                '--disable-blink-features=AutomationControlled',
                '--disable-infobars',
                '--no-first-run',
                '--no-default-browser-check'
            ]
        }
    );
    
    const page = await browser.newPage();
    const gscUrl = \`https://search.google.com/search-console/sitemaps?resource_id=sc-domain:\${DOMAIN}\`;
    
    console.log(\`Checking sitemap status for \${DOMAIN}...\`);
    await page.goto(gscUrl, { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForTimeout(2000);
    
    const pageContent = await page.content();
    
    if (pageContent.includes("don't have access")) {
        console.log("❌ No access to this property");
        await browser.close();
        process.exit(1);
    }
    
    // Look for sitemaps in the table
    const sitemapRows = await page.\$\$('tr:has-text("sitemap")');
    
    if (sitemapRows.length === 0) {
        console.log("📭 No sitemaps submitted yet");
    } else {
        console.log(\`📋 Found \${sitemapRows.length} sitemap(s):\`);
        for (const row of sitemapRows) {
            const text = await row.textContent();
            console.log(\`   • \${text.trim()}\`);
        }
    }
    
    await browser.close();
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
SCRIPT
    return 0
}

create_login_script() {
    local chrome_profile
    chrome_profile="$(get_chrome_profile_path)"
    
    cat > "${GSC_SCRIPT}" << SCRIPT
import { chromium } from 'playwright';

async function main() {
    console.log("Opening Chrome for Google login...");
    console.log("Please log into your Google account in the browser.");
    console.log("Close the browser when done.");
    
    const browser = await chromium.launchPersistentContext(
        '${chrome_profile}',
        { 
            headless: false, 
            channel: 'chrome',
            ignoreDefaultArgs: ['--enable-automation'],
            args: [
                '--disable-blink-features=AutomationControlled',
                '--disable-infobars',
                '--no-first-run',
                '--no-default-browser-check'
            ]
        }
    );
    
    const page = await browser.newPage();
    await page.goto('https://search.google.com/search-console', { waitUntil: 'networkidle' });
    
    console.log("\\nBrowser opened. Please:");
    console.log("1. Log into your Google account");
    console.log("2. Verify you can see your GSC properties");
    console.log("3. Close the browser when done");
    
    // Wait for browser to close
    await new Promise(() => {});
}

main().catch(console.error);
SCRIPT
    return 0
}

run_script() {
    cd "${WORK_DIR}" || return 1
    node "${GSC_SCRIPT}"
    return $?
}

cmd_submit() {
    local domains=()
    local sitemap_path="${DEFAULT_SITEMAP}"
    local dry_run="false"
    local headless="false"
    local timeout="60000"
    local file=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sitemap)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    log_error "--sitemap requires a value"
                    return 1
                fi
                sitemap_path="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --headless)
                headless="true"
                shift
                ;;
            --timeout)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    log_error "--timeout requires a value"
                    return 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--timeout must be a number (milliseconds)"
                    return 1
                fi
                timeout="$2"
                shift 2
                ;;
            --file)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    log_error "--file requires a value"
                    return 1
                fi
                file="$2"
                shift 2
                ;;
            --skip-existing)
                # Already handled by script logic
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                # Sanitize domain input
                domains+=("$(sanitize_domain "$1")")
                shift
                ;;
        esac
    done
    
    # Read domains from file if specified
    if [[ -n "$file" ]]; then
        if [[ ! -f "$file" ]]; then
            log_error "File not found: $file"
            return 1
        fi
        while IFS= read -r line; do
            [[ -n "$line" && ! "$line" =~ ^# ]] && domains+=("$line")
        done < "$file"
    fi
    
    if [[ ${#domains[@]} -eq 0 ]]; then
        log_error "No domains specified"
        show_help
        return 1
    fi
    
    # Convert domains array to JSON safely using jq
    local domains_json
    if command -v jq &> /dev/null; then
        domains_json=$(printf '%s\n' "${domains[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    else
        # Fallback: manual construction with basic escaping
        domains_json="["
        for i in "${!domains[@]}"; do
            [[ $i -gt 0 ]] && domains_json+=","
            # Escape quotes and backslashes
            local escaped_domain="${domains[$i]//\\/\\\\}"
            escaped_domain="${escaped_domain//\"/\\\"}"
            domains_json+="\"${escaped_domain}\""
        done
        domains_json+="]"
    fi
    
    ensure_directories
    ensure_playwright || return 1
    
    log_info "Submitting sitemaps for ${#domains[@]} domain(s)..."
    [[ "$dry_run" == "true" ]] && log_warn "DRY RUN - no changes will be made"
    
    create_submit_script "$domains_json" "$sitemap_path" "$dry_run" "$headless" "$timeout"
    run_script
    return $?
}

cmd_status() {
    local domain="${1:-}"
    
    if [[ -z "$domain" ]]; then
        log_error "Domain required"
        return 1
    fi
    
    ensure_directories
    ensure_playwright || return 1
    
    create_status_script "$domain"
    run_script
    return $?
}

cmd_list() {
    # Same as status for now
    cmd_status "$@"
    return $?
}

cmd_login() {
    ensure_directories
    ensure_playwright || return 1
    
    log_info "Opening browser for Google login..."
    create_login_script
    run_script
    return $?
}

cmd_setup() {
    log_info "Setting up GSC Sitemap Helper..."
    
    ensure_directories
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        log_error "Node.js not found. Please install Node.js first."
        log_info "Install with: brew install node (macOS) or see https://nodejs.org"
        return 1
    fi
    log_success "Node.js $(node --version) found"
    
    # Check npm
    if ! command -v npm &> /dev/null; then
        log_error "npm not found. Please install npm."
        return 1
    fi
    log_success "npm $(npm --version) found"
    
    # Install Playwright
    log_info "Installing Playwright..."
    cd "${WORK_DIR}" || return 1
    
    if [[ ! -f "package.json" ]]; then
        npm init -y > /dev/null 2>&1
    fi
    
    # NOSONAR - npm scripts required for Playwright browser automation binaries
    npm install playwright > /dev/null 2>&1
    log_success "Playwright installed"
    
    # Create config file if it doesn't exist
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" << 'CONFIG'
{
  "chrome_profile_dir": "~/.aidevops/.agent-workspace/chrome-gsc-profile",
  "default_sitemap_path": "sitemap.xml",
  "screenshot_dir": "/tmp/gsc-screenshots",
  "timeout_ms": 60000,
  "headless": false
}
CONFIG
        log_success "Created config file: $CONFIG_FILE"
    fi
    
    log_success "Setup complete!"
    log_info "Next steps:"
    log_info "  1. Run: gsc-sitemap-helper.sh login"
    log_info "  2. Log into Google in the browser that opens"
    log_info "  3. Close browser when done"
    log_info "  4. Now you can submit sitemaps!"
    return 0
}

# Main
case "${1:-}" in
    submit)
        shift
        cmd_submit "$@"
        ;;
    status)
        shift
        cmd_status "${1:-}"
        ;;
    list)
        shift
        cmd_list "${1:-}"
        ;;
    login)
        cmd_login
        ;;
    setup)
        cmd_setup
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
