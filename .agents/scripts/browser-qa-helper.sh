#!/usr/bin/env bash
# Browser QA Helper — Playwright-based visual testing for milestone validation (t1359)
# Commands: run | screenshot | links | a11y | smoke | help
# Integrates with mission milestone validation pipeline.
# Uses Playwright (fastest) with fallback guidance for Stagehand (self-healing).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly SCREENSHOTS_DIR="${HOME}/.aidevops/.agent-workspace/tmp/browser-qa"
readonly QA_RESULTS_DIR="${HOME}/.aidevops/.agent-workspace/tmp/browser-qa/results"
readonly DEFAULT_TIMEOUT=30000
readonly DEFAULT_VIEWPORTS="desktop,mobile"

# =============================================================================
# Viewport Definitions
# =============================================================================

# Returns viewport dimensions for a named viewport.
# Args: $1 = viewport name (desktop|tablet|mobile)
# Output: "widthxheight"
get_viewport_dimensions() {
	local viewport="$1"
	case "$viewport" in
	desktop) echo "1440x900" ;;
	tablet) echo "768x1024" ;;
	mobile) echo "375x667" ;;
	*) echo "1440x900" ;;
	esac
	return 0
}

# Escape a string for safe embedding in a JavaScript string literal (single-quoted).
# Handles backslashes, single quotes, backticks, newlines, and dollar signs.
# Args: $1 = raw string
# Output: escaped string (without surrounding quotes)
js_escape_string() {
	local raw="$1"
	raw="${raw//\\/\\\\}"
	raw="${raw//\'/\\\'}"
	raw="${raw//\`/\\\`}"
	raw="${raw//\$/\\\$}"
	raw="${raw//$'\n'/\\n}"
	printf '%s' "$raw"
	return 0
}

# =============================================================================
# Prerequisite Checks
# =============================================================================

# Verify Playwright is installed and available.
check_playwright() {
	if ! command -v npx &>/dev/null; then
		log_error "npx not found. Install Node.js first."
		return 1
	fi

	# Check if playwright is available (don't install browsers, just check)
	if ! npx --no-install playwright --version &>/dev/null 2>&1; then
		log_error "Playwright not installed. Run: npm install playwright && npx playwright install"
		return 1
	fi
	return 0
}

# Wait for a URL to become reachable.
# Args: $1 = URL, $2 = max wait seconds (default 30)
wait_for_url() {
	local url="$1"
	local max_wait="${2:-30}"
	local i=0

	log_info "Waiting for ${url} to become reachable (max ${max_wait}s)..."
	while [[ $i -lt $max_wait ]]; do
		if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE '^[23]'; then
			log_info "Server ready at ${url}"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log_error "Server at ${url} not reachable after ${max_wait}s"
	return 1
}

# =============================================================================
# Screenshot Capture
# =============================================================================

# Capture screenshots of pages at specified viewports using Playwright.
# Args: --url URL --pages "/ /about /dashboard" --viewports "desktop,mobile" --output-dir DIR
# Output: Screenshot file paths, one per line
cmd_screenshot() {
	local url=""
	local pages="/"
	local viewports="$DEFAULT_VIEWPORTS"
	local output_dir="$SCREENSHOTS_DIR"
	local timeout="$DEFAULT_TIMEOUT"
	local full_page="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--viewports)
			viewports="$2"
			shift 2
			;;
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--full-page)
			full_page="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	mkdir -p "$output_dir"

	# Generate Playwright script for screenshots
	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-screenshot-XXXXXX.mjs")

	local viewport_array=""
	IFS=',' read -ra vp_list <<<"$viewports"
	for vp in "${vp_list[@]}"; do
		local dims
		dims=$(get_viewport_dimensions "$vp")
		local width="${dims%%x*}"
		local height="${dims##*x}"
		local safe_vp
		safe_vp=$(js_escape_string "$vp")
		viewport_array="${viewport_array}{ name: '${safe_vp}', width: ${width}, height: ${height} },"
	done

	local pages_array=""
	for page in $pages; do
		local safe_page
		safe_page=$(js_escape_string "$page")
		pages_array="${pages_array}'${safe_page}',"
	done

	local safe_url safe_output_dir
	safe_url=$(js_escape_string "$url")
	safe_output_dir=$(js_escape_string "$output_dir")

	cat >"$script_file" <<SCRIPT
import { chromium } from 'playwright';

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const viewports = [${viewport_array}];
const pages = [${pages_array}];
const outputDir = '${safe_output_dir}';
const timeout = ${timeout};
const fullPage = ${full_page};

async function run() {
  const browser = await chromium.launch({ headless: true });
  const results = [];

  for (const vp of viewports) {
    const context = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
    });
    const page = await context.newPage();

    for (const pagePath of pages) {
      const url = baseUrl + pagePath;
      const safeName = pagePath.replace(/\\//g, '_').replace(/^_/, '') || 'index';
      const filename = \`\${safeName}-\${vp.name}-\${vp.width}x\${vp.height}.png\`;
      const filepath = \`\${outputDir}/\${filename}\`;

      try {
        await page.goto(url, { waitUntil: 'networkidle', timeout });
        await page.screenshot({ path: filepath, fullPage });
        results.push({ page: pagePath, viewport: vp.name, file: filepath, status: 'ok' });
      } catch (err) {
        results.push({ page: pagePath, viewport: vp.name, file: filepath, status: 'error', error: err.message });
      }
    }

    await context.close();
  }

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT

	log_info "Capturing screenshots for ${pages} at viewports: ${viewports}"
	local exit_code=0
	node "$script_file" || exit_code=$?
	rm -f "$script_file"
	return $exit_code
}

# =============================================================================
# Broken Link Detection
# =============================================================================

# Crawl internal links from a starting URL and report broken ones.
# Args: --url URL --depth N --timeout MS
# Output: JSON array of link check results
cmd_links() {
	local url=""
	local depth=2
	local timeout="$DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--depth)
			depth="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-links-XXXXXX.mjs")

	cat >"$script_file" <<'SCRIPT'
import { chromium } from 'playwright';

const baseUrl = process.argv[2].replace(/\/$/, '');
const maxDepth = parseInt(process.argv[3] || '2', 10);
const timeout = parseInt(process.argv[4] || '30000', 10);

async function run() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  const visited = new Set();
  const results = [];
  const queue = [{ url: baseUrl, depth: 0, source: 'root' }];

  while (queue.length > 0) {
    const { url: currentUrl, depth, source } = queue.shift();

    if (visited.has(currentUrl) || depth > maxDepth) continue;
    visited.add(currentUrl);

    try {
      const response = await page.goto(currentUrl, { waitUntil: 'domcontentloaded', timeout });
      const status = response ? response.status() : 0;
      results.push({ url: currentUrl, status, source, ok: status >= 200 && status < 400 });

      // Only crawl internal links
      if (currentUrl.startsWith(baseUrl) && depth < maxDepth) {
        const links = await page.evaluate(() => {
          return [...document.querySelectorAll('a[href]')]
            .map(a => a.href)
            .filter(href => href.startsWith('http'));
        });

        for (const link of links) {
          if (!visited.has(link) && link.startsWith(baseUrl)) {
            queue.push({ url: link, depth: depth + 1, source: currentUrl });
          }
        }
      }
    } catch (err) {
      results.push({ url: currentUrl, status: 0, source, ok: false, error: err.message });
    }
  }

  await browser.close();

  const broken = results.filter(r => !r.ok);
  console.log(JSON.stringify({
    total: results.length,
    broken: broken.length,
    ok: results.length - broken.length,
    brokenLinks: broken,
    allLinks: results,
  }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT

	log_info "Checking links from ${url} (depth: ${depth})"
	local exit_code=0
	node "$script_file" "$url" "$depth" "$timeout" || exit_code=$?
	rm -f "$script_file"
	return $exit_code
}

# =============================================================================
# Accessibility Checks
# =============================================================================

# Run accessibility checks on pages using Playwright.
# Delegates to playwright-contrast.mjs for contrast, adds ARIA and structure checks.
# Args: --url URL --pages "/ /about" --level AA|AAA
# Output: JSON accessibility report
cmd_a11y() {
	local url=""
	local pages="/"
	local level="AA"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--level)
			level="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	local contrast_script="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"
	local results=()

	for page_path in $pages; do
		local full_url="${url%/}${page_path}"
		log_info "Running accessibility check on ${full_url} (level: ${level})"

		# Run contrast check if script exists
		if [[ -f "$contrast_script" ]]; then
			local contrast_result
			contrast_result=$(node "$contrast_script" "$full_url" --format json --level "$level" 2>/dev/null) || contrast_result='{"error": "contrast check failed"}'
			results+=("{\"page\": \"${page_path}\", \"contrast\": ${contrast_result}}")
		else
			log_warn "Contrast script not found at ${contrast_script}"
			results+=("{\"page\": \"${page_path}\", \"contrast\": {\"error\": \"script not found\"}}")
		fi
	done

	# Run ARIA and structure checks via Playwright
	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-a11y-XXXXXX.mjs")

	local pages_array=""
	for page_path in $pages; do
		local safe_page
		safe_page=$(js_escape_string "$page_path")
		pages_array="${pages_array}'${safe_page}',"
	done

	local safe_url
	safe_url=$(js_escape_string "$url")

	cat >"$script_file" <<SCRIPT
import { chromium } from 'playwright';

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];

async function run() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const a11yResults = [];
  const contrastData = JSON.parse(process.argv[2] || '[]');

  for (const pagePath of pages) {
    const url = baseUrl + pagePath;
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

      const a11yData = await page.evaluate(() => {
        const issues = [];

        // Check images without alt text
        const images = document.querySelectorAll('img');
        images.forEach(img => {
          if (!img.alt && !img.getAttribute('role') && !img.getAttribute('aria-label')) {
            issues.push({
              type: 'missing-alt',
              severity: 'error',
              element: img.outerHTML.substring(0, 200),
              message: 'Image missing alt text',
            });
          }
        });

        // Check form inputs without labels
        const inputs = document.querySelectorAll('input, select, textarea');
        inputs.forEach(input => {
          const id = input.id;
          const hasLabel = id && document.querySelector(\`label[for="\${id}"]\`);
          const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
          const hasTitle = input.getAttribute('title');
          const hasPlaceholder = input.getAttribute('placeholder');
          if (!hasLabel && !hasAriaLabel && !hasTitle && input.type !== 'hidden' && input.type !== 'submit') {
            issues.push({
              type: 'missing-label',
              severity: 'warning',
              element: input.outerHTML.substring(0, 200),
              message: \`Input \${input.type || 'text'} missing associated label\${hasPlaceholder ? ' (has placeholder but not a label)' : ''}\`,
            });
          }
        });

        // Check heading hierarchy
        const headings = [...document.querySelectorAll('h1, h2, h3, h4, h5, h6')];
        let lastLevel = 0;
        headings.forEach(h => {
          const level = parseInt(h.tagName[1], 10);
          if (level > lastLevel + 1 && lastLevel > 0) {
            issues.push({
              type: 'heading-skip',
              severity: 'warning',
              element: h.outerHTML.substring(0, 200),
              message: \`Heading level skipped: h\${lastLevel} to h\${level}\`,
            });
          }
          lastLevel = level;
        });

        // Check for missing lang attribute
        const html = document.documentElement;
        if (!html.getAttribute('lang')) {
          issues.push({
            type: 'missing-lang',
            severity: 'error',
            message: 'HTML element missing lang attribute',
          });
        }

        // Check for missing page title
        if (!document.title || document.title.trim() === '') {
          issues.push({
            type: 'missing-title',
            severity: 'error',
            message: 'Page missing title element',
          });
        }

        // Check buttons without accessible names
        const buttons = document.querySelectorAll('button');
        buttons.forEach(btn => {
          const text = btn.textContent?.trim();
          const ariaLabel = btn.getAttribute('aria-label');
          const ariaLabelledBy = btn.getAttribute('aria-labelledby');
          if (!text && !ariaLabel && !ariaLabelledBy) {
            issues.push({
              type: 'empty-button',
              severity: 'error',
              element: btn.outerHTML.substring(0, 200),
              message: 'Button has no accessible name',
            });
          }
        });

        // Check links without accessible names
        const links = document.querySelectorAll('a');
        links.forEach(link => {
          const text = link.textContent?.trim();
          const ariaLabel = link.getAttribute('aria-label');
          if (!text && !ariaLabel && !link.querySelector('img[alt]')) {
            issues.push({
              type: 'empty-link',
              severity: 'warning',
              element: link.outerHTML.substring(0, 200),
              message: 'Link has no accessible name',
            });
          }
        });

        return {
          issues,
          summary: {
            errors: issues.filter(i => i.severity === 'error').length,
            warnings: issues.filter(i => i.severity === 'warning').length,
            total: issues.length,
          },
        };
      });

      // Merge contrast data for this page if available
      const contrast = contrastData.find(c => c.page === pagePath);
      a11yResults.push({ page: pagePath, ...a11yData, contrast: contrast ? contrast.contrast : null });
    } catch (err) {
      const contrast = contrastData.find(c => c.page === pagePath);
      a11yResults.push({ page: pagePath, error: err.message, contrast: contrast ? contrast.contrast : null });
    }
  }

  await browser.close();
  console.log(JSON.stringify(a11yResults, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT

	# Serialize contrast results as JSON array for the generated script
	local contrast_json="["
	local first=true
	for entry in "${results[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			contrast_json="${contrast_json},"
		fi
		contrast_json="${contrast_json}${entry}"
	done
	contrast_json="${contrast_json}]"

	local exit_code=0
	node "$script_file" "$contrast_json" || exit_code=$?
	rm -f "$script_file"
	return $exit_code
}

# =============================================================================
# Smoke Test (Console Errors + Basic Rendering)
# =============================================================================

# Navigate to pages and check for console errors, failed network requests, and basic rendering.
# Args: --url URL --pages "/ /about" --format json|markdown
# Output: JSON or markdown report of console errors and rendering issues
cmd_smoke() {
	local url=""
	local pages="/"
	local format="json"
	local timeout="$DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-smoke-XXXXXX.mjs")

	local pages_array=""
	for page_path in $pages; do
		local safe_page
		safe_page=$(js_escape_string "$page_path")
		pages_array="${pages_array}'${safe_page}',"
	done

	local safe_url
	safe_url=$(js_escape_string "$url")

	cat >"$script_file" <<SCRIPT
import { chromium } from 'playwright';

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];
const timeout = ${timeout};

async function run() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const results = [];

  for (const pagePath of pages) {
    const page = await context.newPage();
    const consoleErrors = [];
    const networkErrors = [];

    // Capture console errors
    page.on('console', msg => {
      if (msg.type() === 'error') {
        consoleErrors.push({ text: msg.text(), location: msg.location() });
      }
    });

    // Capture failed network requests
    page.on('requestfailed', request => {
      networkErrors.push({
        url: request.url(),
        method: request.method(),
        error: request.failure()?.errorText || 'unknown',
      });
    });

    const url = baseUrl + pagePath;
    try {
      const response = await page.goto(url, { waitUntil: 'networkidle', timeout });
      const status = response ? response.status() : 0;

      // Check basic rendering
      const bodyText = await page.evaluate(() => document.body?.innerText?.length || 0);
      const title = await page.title();
      const hasContent = bodyText > 0;

      // Get ARIA snapshot for AI understanding
      const ariaSnapshot = await page.locator('body').ariaSnapshot().catch(() => '');

      results.push({
        page: pagePath,
        status,
        title,
        hasContent,
        bodyLength: bodyText,
        consoleErrors,
        networkErrors,
        ariaSnapshotLength: ariaSnapshot.length,
        ok: status >= 200 && status < 400 && consoleErrors.length === 0 && hasContent,
      });
    } catch (err) {
      results.push({
        page: pagePath,
        status: 0,
        error: err.message,
        consoleErrors,
        networkErrors,
        ok: false,
      });
    }

    await page.close();
  }

  await browser.close();

  const summary = {
    total: results.length,
    passed: results.filter(r => r.ok).length,
    failed: results.filter(r => !r.ok).length,
    consoleErrors: results.reduce((sum, r) => sum + (r.consoleErrors?.length || 0), 0),
    networkErrors: results.reduce((sum, r) => sum + (r.networkErrors?.length || 0), 0),
  };

  console.log(JSON.stringify({ summary, pages: results }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT

	log_info "Running smoke test on ${url} for pages: ${pages}"
	local exit_code=0
	node "$script_file" || exit_code=$?
	rm -f "$script_file"
	return $exit_code
}

# =============================================================================
# Full QA Run
# =============================================================================

# Run the complete QA pipeline: smoke test, screenshots, broken links, accessibility.
# Args: --url URL --pages "/ /about" --viewports "desktop,mobile" --format json|markdown
# Output: Combined JSON report
cmd_run() {
	local url=""
	local pages="/"
	local viewports="$DEFAULT_VIEWPORTS"
	local format="json"
	local output_dir="$QA_RESULTS_DIR"
	local timeout="$DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--viewports)
			viewports="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	mkdir -p "$output_dir"
	local timestamp
	timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
	local report_file="${output_dir}/qa-report-${timestamp}.json"

	log_info "=== Browser QA Full Run ==="
	log_info "URL: ${url}"
	log_info "Pages: ${pages}"
	log_info "Viewports: ${viewports}"

	# Phase 1: Smoke test
	log_info "--- Phase 1: Smoke Test ---"
	local smoke_result
	smoke_result=$(cmd_smoke --url "$url" --pages "$pages" --timeout "$timeout" 2>/dev/null) || smoke_result='{"error": "smoke test failed"}'

	# Phase 2: Screenshots
	log_info "--- Phase 2: Screenshots ---"
	local screenshot_dir="${output_dir}/screenshots-${timestamp}"
	local screenshot_result
	screenshot_result=$(cmd_screenshot --url "$url" --pages "$pages" --viewports "$viewports" --output-dir "$screenshot_dir" --timeout "$timeout" 2>/dev/null) || screenshot_result='{"error": "screenshot capture failed"}'

	# Phase 3: Broken links
	log_info "--- Phase 3: Broken Link Check ---"
	local links_result
	links_result=$(cmd_links --url "$url" --timeout "$timeout" 2>/dev/null) || links_result='{"error": "link check failed"}'

	# Phase 4: Accessibility
	log_info "--- Phase 4: Accessibility ---"
	local a11y_result
	a11y_result=$(cmd_a11y --url "$url" --pages "$pages" 2>/dev/null) || a11y_result='{"error": "accessibility check failed"}'

	# Combine results
	local combined
	combined=$(
		cat <<REPORT
{
  "timestamp": "${timestamp}",
  "url": "${url}",
  "pages": "$(echo "$pages" | tr ' ' ',')",
  "viewports": "${viewports}",
  "smoke": ${smoke_result},
  "screenshots": ${screenshot_result},
  "links": ${links_result},
  "accessibility": ${a11y_result}
}
REPORT
	)

	if [[ "$format" == "markdown" ]]; then
		format_as_markdown "$combined"
	else
		echo "$combined" | jq '.' 2>/dev/null || echo "$combined"
	fi

	# Save report
	echo "$combined" >"$report_file"
	log_info "Report saved to ${report_file}"
	return 0
}

# =============================================================================
# Markdown Formatter
# =============================================================================

# Convert JSON QA report to markdown format.
# Args: $1 = JSON report string
format_as_markdown() {
	local json="$1"

	echo "## Browser QA Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo "**URL**: $(echo "$json" | jq -r '.url // "unknown"' 2>/dev/null)"
	echo ""

	# Smoke test summary
	echo "### Smoke Test"
	echo ""
	local smoke_passed
	smoke_passed=$(echo "$json" | jq -r '.smoke.summary.passed // 0' 2>/dev/null)
	local smoke_total
	smoke_total=$(echo "$json" | jq -r '.smoke.summary.total // 0' 2>/dev/null)
	local console_errors
	console_errors=$(echo "$json" | jq -r '.smoke.summary.consoleErrors // 0' 2>/dev/null)
	echo "- Pages checked: ${smoke_total}"
	echo "- Passed: ${smoke_passed}"
	echo "- Console errors: ${console_errors}"
	echo ""

	# Links summary
	echo "### Broken Links"
	echo ""
	local links_total
	links_total=$(echo "$json" | jq -r '.links.total // 0' 2>/dev/null)
	local links_broken
	links_broken=$(echo "$json" | jq -r '.links.broken // 0' 2>/dev/null)
	echo "- Total links: ${links_total}"
	echo "- Broken: ${links_broken}"
	echo ""

	# Accessibility summary
	echo "### Accessibility"
	echo ""
	echo "$json" | jq -r '.accessibility[]? | "- \(.page): \(.summary.errors // 0) errors, \(.summary.warnings // 0) warnings"' 2>/dev/null || echo "- No data"
	echo ""

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Browser QA Helper — Playwright-based visual testing for milestone validation

Usage: browser-qa-helper.sh <command> [options]

Commands:
  run          Full QA pipeline (smoke + screenshots + links + a11y)
  screenshot   Capture page screenshots at multiple viewports
  links        Check for broken internal links
  a11y         Run accessibility checks (contrast, ARIA, structure)
  smoke        Check for console errors and basic rendering
  help         Show this help message

Common Options:
  --url URL           Base URL to test (required)
  --pages "/ /about"  Space-separated page paths (default: "/")
  --viewports V       Comma-separated viewports: desktop,tablet,mobile (default: desktop,mobile)
  --format FMT        Output format: json or markdown (default: json)
  --timeout MS        Navigation timeout in milliseconds (default: 30000)
  --output-dir DIR    Directory for screenshots and reports

Examples:
  browser-qa-helper.sh run --url http://localhost:3000 --pages "/ /about /dashboard"
  browser-qa-helper.sh screenshot --url http://localhost:3000 --viewports desktop,tablet,mobile
  browser-qa-helper.sh links --url http://localhost:3000 --depth 3
  browser-qa-helper.sh a11y --url http://localhost:3000 --level AAA
  browser-qa-helper.sh smoke --url http://localhost:3000 --pages "/ /login"

Prerequisites:
  - Node.js and npm installed
  - Playwright installed: npm install playwright && npx playwright install

Integration:
  Used by milestone-validation.md (Phase 3: Browser QA) during mission orchestration.
  See tools/browser/browser-qa.md for the full browser QA subagent documentation.
HELP
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	run) cmd_run "$@" ;;
	screenshot) cmd_screenshot "$@" ;;
	links) cmd_links "$@" ;;
	a11y) cmd_a11y "$@" ;;
	smoke) cmd_smoke "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
