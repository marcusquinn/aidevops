#!/bin/bash
# =============================================================================
# ClawdHub Helper - Fetch skills from clawdhub.com using browser automation
# =============================================================================
# Uses Playwright to extract SKILL.md content from ClawdHub's SPA since the
# API doesn't expose raw file content. Falls back to clawdhub CLI if available.
#
# Usage:
#   clawdhub-helper.sh fetch <slug> [--output <dir>]
#   clawdhub-helper.sh search <query>
#   clawdhub-helper.sh info <slug>
#   clawdhub-helper.sh help
#
# Examples:
#   clawdhub-helper.sh fetch caldav-calendar
#   clawdhub-helper.sh fetch proxmox-full --output /tmp/skill
#   clawdhub-helper.sh search "calendar"
#   clawdhub-helper.sh info caldav-calendar
# =============================================================================

set -euo pipefail

# Configuration
CLAWDHUB_BASE_URL="https://clawdhub.com"
CLAWDHUB_API="${CLAWDHUB_BASE_URL}/api/v1"
TEMP_DIR="${TMPDIR:-/tmp}/clawdhub-fetch"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[clawdhub]${NC} $1"
    return 0
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
    return 0
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    return 0
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    return 0
}

show_help() {
    cat << 'EOF'
ClawdHub Helper - Fetch skills from clawdhub.com using browser automation

USAGE:
    clawdhub-helper.sh <command> [options]

COMMANDS:
    fetch <slug>            Download skill SKILL.md via Playwright
    search <query>          Search skills via ClawdHub vector search API
    info <slug>             Show skill metadata from API
    help                    Show this help message

OPTIONS:
    --output <dir>          Output directory (default: /tmp/clawdhub-fetch/<slug>)

EXAMPLES:
    # Fetch a skill's SKILL.md content
    clawdhub-helper.sh fetch caldav-calendar

    # Fetch to specific directory
    clawdhub-helper.sh fetch proxmox-full --output ./skills/proxmox

    # Search for skills
    clawdhub-helper.sh search "kubernetes"

    # Get skill metadata
    clawdhub-helper.sh info caldav-calendar

SUPPORTED URL FORMATS:
    clawdhub-helper.sh fetch caldav-calendar
    clawdhub-helper.sh fetch owner/slug
    clawdhub-helper.sh fetch https://clawdhub.com/owner/slug

NOTES:
    - Requires Playwright (npx playwright) for fetch command
    - Falls back to clawdhub CLI if installed (npx clawdhub install)
    - Search uses ClawdHub's vector/semantic search API
    - API endpoints used: /api/v1/skills/{slug}, /api/search?q={query}
EOF
    return 0
}

# Parse ClawdHub URL or shorthand into slug
# Accepts: "slug", "owner/slug", "https://clawdhub.com/owner/slug"
parse_clawdhub_input() {
    local input="$1"

    # Strip URL prefix
    input="${input#https://clawdhub.com/}"
    input="${input#http://clawdhub.com/}"
    input="${input#clawdhub.com/}"

    # Strip leading/trailing slashes
    input="${input#/}"
    input="${input%/}"

    # If format is "owner/slug", extract just the slug (last segment)
    if [[ "$input" == */* ]]; then
        echo "${input##*/}"
    else
        echo "$input"
    fi
    return 0
}

# Fetch skill metadata from API
fetch_skill_info() {
    local slug="$1"

    local response
    response=$(curl -s --connect-timeout 10 --max-time 30 "${CLAWDHUB_API}/skills/${slug}")

    if echo "$response" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$response"
    else
        log_error "Failed to fetch skill info for: $slug"
        return 1
    fi
    return 0
}

# Extract SKILL.md content using Playwright
# The ClawdHub SPA renders SKILL.md as HTML on the skill detail page.
# We use Playwright to navigate, wait for render, and extract the markdown content.
fetch_skill_content_playwright() {
    local slug="$1"
    local output_dir="$2"

    mkdir -p "$output_dir"

    # First get the owner handle from API to construct the full URL
    local info
    info=$(fetch_skill_info "$slug") || return 1

    local owner
    owner=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('owner',{}).get('handle',''))" 2>/dev/null)

    if [[ -z "$owner" ]]; then
        log_error "Could not determine owner for skill: $slug"
        return 1
    fi

    local skill_url="${CLAWDHUB_BASE_URL}/${owner}/${slug}"
    log_info "Fetching SKILL.md from: $skill_url"

    # Create a temporary Node.js project with Playwright to extract SKILL.md
    local pw_dir
    pw_dir=$(mktemp -d "${TMPDIR:-/tmp}/clawdhub-pw-XXXXXX")

    # Create package.json for the temporary project
    cat > "$pw_dir/package.json" << 'PKGJSON'
{"name":"clawdhub-fetch","private":true,"type":"module","dependencies":{"playwright":"^1.50.0"}}
PKGJSON

    # Create the extraction script
    cat > "$pw_dir/fetch.mjs" << 'PLAYWRIGHT_SCRIPT'
import { chromium } from 'playwright';
import { writeFileSync } from 'fs';

const url = process.argv[2];
const outputFile = process.argv[3];

if (!url || !outputFile) {
    console.error('Usage: node fetch.mjs <url> <output-file>');
    process.exit(1);
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

try {
    await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

    // Wait for the skill content to render
    await page.waitForSelector('[class*="prose"], [class*="markdown"], article, .skill-content', {
        timeout: 10000
    }).catch(() => {});

    // Extract rendered HTML and convert back to markdown
    let content = await page.evaluate(() => {
        const proseEl = document.querySelector('[class*="prose"]')
            || document.querySelector('[class*="markdown"]')
            || document.querySelector('article')
            || document.querySelector('.skill-content');

        if (!proseEl) return null;

        const lines = [];
        const walk = (node) => {
            if (node.nodeType === Node.TEXT_NODE) {
                const text = node.textContent;
                if (text.trim()) lines.push(text);
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;

            const tag = node.tagName.toLowerCase();

            if (tag === 'h1') { lines.push('\n# ' + node.textContent.trim()); return; }
            if (tag === 'h2') { lines.push('\n## ' + node.textContent.trim()); return; }
            if (tag === 'h3') { lines.push('\n### ' + node.textContent.trim()); return; }
            if (tag === 'h4') { lines.push('\n#### ' + node.textContent.trim()); return; }

            if (tag === 'pre') {
                const code = node.querySelector('code');
                const lang = code?.className?.match(/language-(\w+)/)?.[1] || '';
                lines.push('\n```' + lang);
                lines.push((code || node).textContent.trimEnd());
                lines.push('```\n');
                return;
            }

            if (tag === 'code' && node.parentElement?.tagName !== 'PRE') {
                lines.push('`' + node.textContent + '`');
                return;
            }

            if (tag === 'p') {
                const children = [];
                for (const child of node.childNodes) {
                    if (child.nodeType === Node.TEXT_NODE) children.push(child.textContent);
                    else if (child.tagName === 'CODE') children.push('`' + child.textContent + '`');
                    else if (child.tagName === 'STRONG' || child.tagName === 'B') children.push('**' + child.textContent + '**');
                    else if (child.tagName === 'EM' || child.tagName === 'I') children.push('*' + child.textContent + '*');
                    else if (child.tagName === 'A') children.push('[' + child.textContent + '](' + child.href + ')');
                    else children.push(child.textContent);
                }
                lines.push('\n' + children.join(''));
                return;
            }

            if (tag === 'ul' || tag === 'ol') {
                let idx = 0;
                for (const li of node.children) {
                    idx++;
                    const prefix = tag === 'ol' ? `${idx}. ` : '- ';
                    lines.push(prefix + li.textContent.trim());
                }
                lines.push('');
                return;
            }

            if (tag === 'hr') { lines.push('\n---\n'); return; }
            if (tag === 'br') { lines.push(''); return; }
            if (tag === 'blockquote') { lines.push('> ' + node.textContent.trim()); return; }

            for (const child of node.childNodes) { walk(child); }
        };

        walk(proseEl);
        return lines.join('\n');
    });

    if (!content || content.trim().length < 50) {
        content = await page.evaluate(() => {
            const main = document.querySelector('main') || document.body;
            return main.innerText;
        });
    }

    writeFileSync(outputFile, content.trim() + '\n');
    console.log('OK');
} catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
} finally {
    await browser.close();
}
PLAYWRIGHT_SCRIPT

    local output_file="${output_dir}/SKILL.md"

    # Install playwright and run the fetch script
    log_info "Installing Playwright (temporary)..."
    if (cd "$pw_dir" && npm install --silent 2>/dev/null && npx playwright install chromium --with-deps 2>/dev/null); then
        log_info "Running browser extraction..."
        if (cd "$pw_dir" && node fetch.mjs "$skill_url" "$output_file" 2>/dev/null); then
            rm -rf "$pw_dir"
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                log_success "Extracted SKILL.md ($(wc -c < "$output_file" | tr -d ' ') bytes)"
                return 0
            fi
        fi
    fi

    rm -rf "$pw_dir"
    log_warning "Playwright extraction failed, trying clawdhub CLI fallback..."

    # Fallback: try clawdhub CLI
    if command -v npx &>/dev/null; then
        log_info "Trying: npx clawdhub install $slug"
        if (cd "$output_dir" && npx --yes clawdhub@latest install "$slug" --force 2>/dev/null); then
            # clawdhub installs to ./skills/<slug>/SKILL.md
            local installed_skill
            installed_skill=$(find "$output_dir" -name "SKILL.md" -type f 2>/dev/null | head -1)
            if [[ -n "$installed_skill" && -f "$installed_skill" ]]; then
                if [[ "$installed_skill" != "$output_file" ]]; then
                    cp "$installed_skill" "$output_file"
                fi
                log_success "Fetched via clawdhub CLI"
                return 0
            fi
        fi
    fi

    log_error "Could not fetch SKILL.md for: $slug"
    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_fetch() {
    local input="$1"
    shift || true

    local output_dir=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                output_dir="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    local slug
    slug=$(parse_clawdhub_input "$input")

    if [[ -z "$slug" ]]; then
        log_error "Could not parse slug from: $input"
        return 1
    fi

    log_info "Skill slug: $slug"

    # Set default output directory
    if [[ -z "$output_dir" ]]; then
        output_dir="${TEMP_DIR}/${slug}"
    fi

    # Fetch the skill content
    fetch_skill_content_playwright "$slug" "$output_dir"
    return $?
}

cmd_search() {
    local query="$1"

    if [[ -z "$query" ]]; then
        log_error "Search query required"
        return 1
    fi

    log_info "Searching ClawdHub for: $query"

    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "$query")

    local response
    response=$(curl -s --connect-timeout 10 --max-time 30 "${CLAWDHUB_API}/search?q=${encoded_query}")

    if ! echo "$response" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        log_error "Search failed"
        return 1
    fi

    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if not results:
    print('  No results found')
else:
    for r in results:
        score = r.get('score', 0)
        slug = r.get('slug', '?')
        name = r.get('displayName', slug)
        summary = r.get('summary', '')[:60]
        print(f'  {name} ({slug}) - score: {score:.2f}')
        if summary:
            print(f'    {summary}')
        print()
"
    return 0
}

cmd_info() {
    local input="$1"

    local slug
    slug=$(parse_clawdhub_input "$input")

    if [[ -z "$slug" ]]; then
        log_error "Could not parse slug from: $input"
        return 1
    fi

    log_info "Fetching info for: $slug"

    local response
    response=$(fetch_skill_info "$slug") || return 1

    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
skill = data.get('skill', {})
owner = data.get('owner', {})
version = data.get('latestVersion', {})
stats = skill.get('stats', {})

print(f'  Name: {skill.get(\"displayName\", \"?\")}')
print(f'  Slug: {skill.get(\"slug\", \"?\")}')
print(f'  Owner: @{owner.get(\"handle\", \"?\")}')
print(f'  Version: {version.get(\"version\", \"?\")}')
print(f'  Summary: {skill.get(\"summary\", \"\")}')
print(f'  Stars: {stats.get(\"stars\", 0)}')
print(f'  Downloads: {stats.get(\"downloads\", 0)}')
print(f'  Installs: {stats.get(\"installsCurrent\", 0)}')
print()
"
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        fetch)
            if [[ $# -lt 1 ]]; then
                log_error "Slug or URL required"
                echo "Usage: clawdhub-helper.sh fetch <slug|url> [--output <dir>]"
                return 1
            fi
            cmd_fetch "$@"
            ;;
        search)
            if [[ $# -lt 1 ]]; then
                log_error "Search query required"
                return 1
            fi
            cmd_search "$@"
            ;;
        info)
            if [[ $# -lt 1 ]]; then
                log_error "Slug or URL required"
                return 1
            fi
            cmd_info "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
