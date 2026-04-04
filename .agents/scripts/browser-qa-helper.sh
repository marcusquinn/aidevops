#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
readonly BROWSER_QA_DEFAULT_TIMEOUT=30000
readonly BROWSER_QA_DEFAULT_VIEWPORTS="desktop,mobile"
readonly BROWSER_QA_DEFAULT_MAX_IMAGE_DIM=4000
readonly BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM=8000

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

# Resolve max image dimension guardrail from optional user input.
# Args: $1 = requested max dimension (optional)
# Output: validated max dimension integer
resolve_max_image_dim() {
	local requested="${1:-}"
	local resolved="$BROWSER_QA_DEFAULT_MAX_IMAGE_DIM"

	if [[ -n "$requested" ]]; then
		if [[ "$requested" =~ ^[0-9]+$ ]] && [[ "$requested" -gt 0 ]]; then
			resolved="$requested"
		else
			log_warn "Invalid --max-dim '${requested}', using default ${BROWSER_QA_DEFAULT_MAX_IMAGE_DIM}"
		fi
	fi

	if [[ "$resolved" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" ]]; then
		log_warn "--max-dim ${resolved} exceeds Anthropic limit ${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}; clamping to ${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}"
		resolved="$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM"
	fi

	echo "$resolved"
	return 0
}

# Get image dimensions as "widthxheight".
# Args: $1 = image path
# Output: widthxheight
get_image_dimensions() {
	local image_path="$1"
	local width=""
	local height=""

	if command -v sips &>/dev/null; then
		local sips_output
		sips_output=$(sips -g pixelWidth -g pixelHeight "$image_path" 2>/dev/null) || return 1
		while IFS= read -r line; do
			case "$line" in
			*pixelWidth:*) width="${line##*: }" ;;
			*pixelHeight:*) height="${line##*: }" ;;
			esac
		done <<<"$sips_output"
	elif command -v magick &>/dev/null; then
		local identify_output
		identify_output=$(magick identify -format '%w %h' "$image_path" 2>/dev/null) || return 1
		width="${identify_output%% *}"
		height="${identify_output##* }"
	else
		return 1
	fi

	if [[ -z "$width" || -z "$height" || ! "$width" =~ ^[0-9]+$ || ! "$height" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	echo "${width}x${height}"
	return 0
}

# Resize an image down to a max dimension.
# Args: $1 = image path, $2 = max dimension
resize_image_to_max_dim() {
	local image_path="$1"
	local max_dim="$2"

	if command -v sips &>/dev/null; then
		sips --resampleHeightWidthMax "$max_dim" "$image_path" --out "$image_path" >/dev/null
		return 0
	fi

	if command -v magick &>/dev/null; then
		magick "$image_path" -resize "${max_dim}x${max_dim}>" "$image_path"
		return 0
	fi

	return 1
}

# Enforce screenshot size guardrails for Anthropic vision compatibility.
# Args: $1 = output directory, $2 = target max dimension
enforce_screenshot_size_guardrails() {
	local output_dir="$1"
	local max_dim="$2"
	local checked_count=0
	local resized_count=0
	local hard_limit_violations=0

	if ! command -v sips &>/dev/null && ! command -v magick &>/dev/null; then
		log_error "No supported image tool found for guardrails (need sips or magick)"
		return 1
	fi

	local image_found=0
	for image_path in "$output_dir"/*.png; do
		if [[ ! -f "$image_path" ]]; then
			continue
		fi
		image_found=1
		checked_count=$((checked_count + 1))

		local dimensions
		dimensions=$(get_image_dimensions "$image_path") || {
			log_error "Failed to read image dimensions: ${image_path}"
			return 1
		}

		local width="${dimensions%%x*}"
		local height="${dimensions##*x}"

		if [[ "$width" -gt "$max_dim" || "$height" -gt "$max_dim" ]]; then
			if ! resize_image_to_max_dim "$image_path" "$max_dim"; then
				log_error "Failed to resize screenshot: ${image_path}"
				return 1
			fi
			resized_count=$((resized_count + 1))
			local resized_dimensions
			resized_dimensions=$(get_image_dimensions "$image_path") || {
				log_error "Failed to read resized image dimensions: ${image_path}"
				return 1
			}
			width="${resized_dimensions%%x*}"
			height="${resized_dimensions##*x}"
		fi

		if [[ "$width" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" || "$height" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" ]]; then
			hard_limit_violations=$((hard_limit_violations + 1))
			log_error "Image exceeds Anthropic hard limit (${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}px): ${image_path} (${width}x${height})"
		fi
	done

	if [[ "$image_found" -eq 0 ]]; then
		log_warn "No PNG screenshots found in ${output_dir} to guardrail-check"
		return 0
	fi

	log_info "Screenshot guardrails checked ${checked_count} image(s), resized ${resized_count}, max dimension ${max_dim}px"

	if [[ "$hard_limit_violations" -gt 0 ]]; then
		return 1
	fi

	return 0
}

# =============================================================================
# Shared JS Array Builders
# =============================================================================

# Build a JS array literal of viewport objects from a comma-separated viewport string.
# Args: $1 = comma-separated viewport names (e.g. "desktop,mobile")
# Output: JS array fragment like "{ name: 'desktop', width: 1440, height: 900 },"
_build_viewports_js_array() {
	local viewports="$1"
	local result=""
	IFS=',' read -ra vp_list <<<"$viewports"
	for vp in "${vp_list[@]}"; do
		local dims
		dims=$(get_viewport_dimensions "$vp")
		local width="${dims%%x*}"
		local height="${dims##*x}"
		local safe_vp
		safe_vp=$(js_escape_string "$vp")
		result="${result}{ name: '${safe_vp}', width: ${width}, height: ${height} },"
	done
	printf '%s' "$result"
	return 0
}

# Build a JS array literal of page path strings from a space-separated page list.
# Args: $1 = space-separated page paths (e.g. "/ /about /dashboard")
# Output: JS array fragment like "'/','/about','/dashboard',"
_build_pages_js_array() {
	local pages="$1"
	local result=""
	for page in $pages; do
		local safe_page
		safe_page=$(js_escape_string "$page")
		result="${result}'${safe_page}',"
	done
	printf '%s' "$result"
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

# Generate the Playwright screenshot script file.
# Args: $1=script_file $2=safe_url $3=viewport_array $4=pages_array $5=safe_output_dir $6=timeout $7=full_page
_generate_screenshot_script() {
	local script_file="$1"
	local safe_url="$2"
	local viewport_array="$3"
	local pages_array="$4"
	local safe_output_dir="$5"
	local timeout="$6"
	local full_page="$7"

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
	return 0
}

# Capture screenshots of pages at specified viewports using Playwright.
# Args: --url URL --pages "/ /about /dashboard" --viewports "desktop,mobile" --output-dir DIR
# Output: Screenshot file paths, one per line
cmd_screenshot() {
	local url=""
	local pages="/"
	local viewports="$BROWSER_QA_DEFAULT_VIEWPORTS"
	local output_dir="$SCREENSHOTS_DIR"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local full_page="false"
	local max_dim=""

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
		--max-dim)
			max_dim="$2"
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

	max_dim=$(resolve_max_image_dim "$max_dim")
	mkdir -p "$output_dir"

	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-screenshot-XXXXXX.mjs")

	local viewport_array
	viewport_array=$(_build_viewports_js_array "$viewports")
	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url safe_output_dir
	safe_url=$(js_escape_string "$url")
	safe_output_dir=$(js_escape_string "$output_dir")

	_generate_screenshot_script "$script_file" "$safe_url" "$viewport_array" "$pages_array" "$safe_output_dir" "$timeout" "$full_page"

	log_info "Capturing screenshots for ${pages} at viewports: ${viewports}"
	local exit_code=0
	node "$script_file" || exit_code=$?
	rm -f "$script_file"

	if [[ "$exit_code" -ne 0 ]]; then
		return "$exit_code"
	fi

	if ! enforce_screenshot_size_guardrails "$output_dir" "$max_dim"; then
		log_error "Screenshot guardrail enforcement failed"
		return 1
	fi

	return 0
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
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"

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

# Run contrast checks for each page using playwright-contrast.mjs.
# Args: $1=url $2=pages $3=level
# Output: JSON array of contrast results (stdout)
_run_contrast_checks() {
	local url="$1"
	local pages="$2"
	local level="$3"
	local contrast_script="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"
	local contrast_json='[]'

	for page_path in $pages; do
		local full_url="${url%/}${page_path}"
		log_info "Running accessibility check on ${full_url} (level: ${level})"

		if [[ -f "$contrast_script" ]]; then
			local contrast_result
			contrast_result=$(node "$contrast_script" "$full_url" --format json --level "$level" 2>/dev/null) || contrast_result='{"error": "contrast check failed"}'
			contrast_json=$(jq -c \
				--arg page "$page_path" \
				--argjson contrast "$contrast_result" \
				'. + [{page: $page, contrast: $contrast}]' <<<"$contrast_json")
		else
			log_warn "Contrast script not found at ${contrast_script}"
			contrast_json=$(jq -c \
				--arg page "$page_path" \
				'. + [{page: $page, contrast: {error: "script not found"}}]' <<<"$contrast_json")
		fi
	done

	printf '%s' "$contrast_json"
	return 0
}

# Write the JS snippet that checks images, inputs, and headings for a11y issues.
# Output: JS code fragment (no surrounding function wrapper).
_a11y_js_element_checks() {
	cat <<'JSEOF'
        const issues = [];

        // Check images without alt text
        const images = document.querySelectorAll('img');
        images.forEach(img => {
          if (!img.alt && !img.getAttribute('role') && !img.getAttribute('aria-label')) {
            issues.push({
              type: 'missing-alt', severity: 'error',
              element: img.outerHTML.substring(0, 200),
              message: 'Image missing alt text',
            });
          }
        });

        // Check form inputs without labels
        const inputs = document.querySelectorAll('input, select, textarea');
        inputs.forEach(input => {
          const id = input.id;
          const hasLabel = id && document.querySelector(`label[for="${id}"]`);
          const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
          const hasTitle = input.getAttribute('title');
          const hasPlaceholder = input.getAttribute('placeholder');
          if (!hasLabel && !hasAriaLabel && !hasTitle && input.type !== 'hidden' && input.type !== 'submit') {
            issues.push({
              type: 'missing-label', severity: 'warning',
              element: input.outerHTML.substring(0, 200),
              message: `Input ${input.type || 'text'} missing associated label${hasPlaceholder ? ' (has placeholder but not a label)' : ''}`,
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
              type: 'heading-skip', severity: 'warning',
              element: h.outerHTML.substring(0, 200),
              message: `Heading level skipped: h${lastLevel} to h${level}`,
            });
          }
          lastLevel = level;
        });
JSEOF
	return 0
}

# Write the JS snippet that checks document-level and interactive-element a11y issues.
# Output: JS code fragment (no surrounding function wrapper). Assumes `issues` array exists.
_a11y_js_document_checks() {
	cat <<'JSEOF'
        // Check for missing lang attribute
        const html = document.documentElement;
        if (!html.getAttribute('lang')) {
          issues.push({ type: 'missing-lang', severity: 'error', message: 'HTML element missing lang attribute' });
        }

        // Check for missing page title
        if (!document.title || document.title.trim() === '') {
          issues.push({ type: 'missing-title', severity: 'error', message: 'Page missing title element' });
        }

        // Check buttons without accessible names
        const buttons = document.querySelectorAll('button');
        buttons.forEach(btn => {
          const text = btn.textContent?.trim();
          const ariaLabel = btn.getAttribute('aria-label');
          const ariaLabelledBy = btn.getAttribute('aria-labelledby');
          if (!text && !ariaLabel && !ariaLabelledBy) {
            issues.push({
              type: 'empty-button', severity: 'error',
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
              type: 'empty-link', severity: 'warning',
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
JSEOF
	return 0
}

# Generate the Playwright a11y ARIA/structure check script file.
# Args: $1=script_file $2=safe_url $3=pages_array
_generate_a11y_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local element_checks document_checks
	element_checks=$(_a11y_js_element_checks)
	document_checks=$(_a11y_js_document_checks)
	local evaluate_body="${element_checks}
${document_checks}"

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
${evaluate_body}
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
	return 0
}

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

	local contrast_json
	contrast_json=$(_run_contrast_checks "$url" "$pages" "$level")

	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-a11y-XXXXXX.mjs")

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_a11y_script "$script_file" "$safe_url" "$pages_array"

	local exit_code=0
	node "$script_file" "$contrast_json" || exit_code=$?
	rm -f "$script_file"
	return $exit_code
}

# =============================================================================
# Stability Testing (Reload + Polling Quiescence Detection)
# =============================================================================

# Generate the Playwright stability test script file.
# Args: $1=script_file $2=safe_url $3=pages_array $4=reloads $5=timeout $6=poll_interval $7=poll_max_wait
_generate_stability_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local reloads="$4"
	local timeout="$5"
	local poll_interval="$6"
	local poll_max_wait="$7"

	cat >"$script_file" <<SCRIPT
import { chromium } from 'playwright';

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];
const reloads = ${reloads};
const timeout = ${timeout};
const pollInterval = ${poll_interval};
const pollMaxWait = ${poll_max_wait};

// Wait for network quiescence: no in-flight requests for pollInterval ms.
async function waitForNetworkQuiescence(page) {
  let inFlight = 0;
  let quiesceTimer = null;
  let resolved = false;

  return new Promise((resolve) => {
    const hardTimeout = setTimeout(() => {
      if (!resolved) { resolved = true; resolve(false); }
    }, pollMaxWait);

    page.on('request', () => { inFlight++; clearTimeout(quiesceTimer); });
    page.on('requestfinished', () => {
      inFlight = Math.max(0, inFlight - 1);
      if (inFlight === 0) {
        quiesceTimer = setTimeout(() => {
          if (!resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
        }, pollInterval);
      }
    });
    page.on('requestfailed', () => {
      inFlight = Math.max(0, inFlight - 1);
      if (inFlight === 0) {
        quiesceTimer = setTimeout(() => {
          if (!resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
        }, pollInterval);
      }
    });

    // If already quiescent at start, resolve after one interval.
    quiesceTimer = setTimeout(() => {
      if (inFlight === 0 && !resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
    }, pollInterval);
  });
}

// Capture a DOM fingerprint: element counts and text length.
async function domFingerprint(page) {
  return page.evaluate(() => ({
    elementCount: document.querySelectorAll('*').length,
    bodyLength: document.body ? document.body.innerText.length : 0,
    title: document.title || '',
  }));
}

async function run() {
  const browser = await chromium.launch({ headless: true });
  const allResults = [];

  for (const pagePath of pages) {
    const url = baseUrl + pagePath;
    const reloadResults = [];
    let stable = true;
    let baseFingerprint = null;

    const context = await browser.newContext();
    const page = await context.newPage();

    for (let i = 0; i < reloads; i++) {
      const consoleErrors = [];
      const networkErrors = [];

      page.on('console', msg => {
        if (msg.type() === 'error') {
          consoleErrors.push({ text: msg.text(), location: msg.location() });
        }
      });
      page.on('requestfailed', request => {
        networkErrors.push({
          url: request.url(),
          method: request.method(),
          error: request.failure() ? request.failure().errorText : 'unknown',
        });
      });

      const startMs = Date.now();
      let loadOk = true;
      let loadError = null;
      let status = 0;

      try {
        const response = await page.goto(url, { waitUntil: 'networkidle', timeout });
        status = response ? response.status() : 0;
        await waitForNetworkQuiescence(page);
      } catch (err) {
        loadOk = false;
        loadError = err.message;
      }

      const loadMs = Date.now() - startMs;
      let fingerprint = null;
      if (loadOk) {
        try { fingerprint = await domFingerprint(page); } catch (_) {}
      }

      if (i === 0) {
        baseFingerprint = fingerprint;
      } else if (fingerprint && baseFingerprint) {
        // Quiescence check: title and element count must match baseline.
        if (
          fingerprint.title !== baseFingerprint.title ||
          Math.abs(fingerprint.elementCount - baseFingerprint.elementCount) > 5
        ) {
          stable = false;
        }
      }

      reloadResults.push({
        reload: i + 1,
        status,
        loadMs,
        ok: loadOk && status >= 200 && status < 400,
        loadError,
        consoleErrors,
        networkErrors,
        fingerprint,
      });
    }

    await context.close();

    const totalConsoleErrors = reloadResults.reduce((s, r) => s + r.consoleErrors.length, 0);
    const totalNetworkErrors = reloadResults.reduce((s, r) => s + r.networkErrors.length, 0);
    const allLoadsOk = reloadResults.every(r => r.ok);
    const avgLoadMs = Math.round(
      reloadResults.reduce((s, r) => s + r.loadMs, 0) / reloadResults.length
    );

    allResults.push({
      page: pagePath,
      reloads,
      stable: stable && allLoadsOk && totalConsoleErrors === 0,
      allLoadsOk,
      stable_dom: stable,
      totalConsoleErrors,
      totalNetworkErrors,
      avgLoadMs,
      baseFingerprint,
      reloadResults,
    });
  }

  await browser.close();

  const summary = {
    total: allResults.length,
    stable: allResults.filter(r => r.stable).length,
    unstable: allResults.filter(r => !r.stable).length,
  };

  console.log(JSON.stringify({ summary, pages: allResults }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# Run stability testing: reload pages N times and detect quiescence.
# Checks for consistent DOM structure, stable titles, no console errors,
# and network quiescence across reloads.
# Args: --url URL --pages "/ /about" --reloads N --timeout MS
#       --poll-interval MS --poll-max-wait MS --format json|markdown
# Output: JSON or markdown stability report
cmd_stability() {
	local url=""
	local pages="/"
	local reloads=3
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local poll_interval=500
	local poll_max_wait=10000
	local format="json"

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
		--reloads)
			reloads="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--poll-interval)
			poll_interval="$2"
			shift 2
			;;
		--poll-max-wait)
			poll_max_wait="$2"
			shift 2
			;;
		--format)
			format="$2"
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

	if ! [[ "$reloads" =~ ^[0-9]+$ ]] || [[ "$reloads" -lt 1 ]]; then
		log_error "--reloads must be a positive integer, got: ${reloads}"
		return 1
	fi

	local script_file
	script_file=$(mktemp "${TMPDIR:-/tmp}/browser-qa-stability-XXXXXX.mjs")

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_stability_script "$script_file" "$safe_url" "$pages_array" \
		"$reloads" "$timeout" "$poll_interval" "$poll_max_wait"

	log_info "Running stability test on ${url} for pages: ${pages} (${reloads} reloads each)"
	local exit_code=0
	local output
	output=$(node "$script_file") || exit_code=$?
	rm -f "$script_file"

	if [[ $exit_code -ne 0 ]]; then
		printf '%s\n' "$output"
		return $exit_code
	fi

	if [[ "$format" == "markdown" ]]; then
		_format_stability_markdown "$output"
	else
		printf '%s\n' "$output" | jq '.' 2>/dev/null || printf '%s\n' "$output"
	fi
	return 0
}

# Convert stability JSON report to markdown.
# Args: $1 = JSON string with { summary: {...}, pages: [...] }
_format_stability_markdown() {
	local json="$1"

	echo "## Stability Test Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo ""

	local total stable unstable
	total=$(printf '%s' "$json" | jq -r '.summary.total // 0' 2>/dev/null)
	stable=$(printf '%s' "$json" | jq -r '.summary.stable // 0' 2>/dev/null)
	unstable=$(printf '%s' "$json" | jq -r '.summary.unstable // 0' 2>/dev/null)

	echo "### Summary"
	echo ""
	echo "| Metric | Count |"
	echo "|--------|-------|"
	echo "| Pages tested | ${total} |"
	echo "| Stable | ${stable} |"
	echo "| Unstable | ${unstable} |"
	echo ""

	local unstable_count
	unstable_count=$(printf '%s' "$json" | jq '[.pages[] | select(.stable == false)] | length' 2>/dev/null)
	if [[ "${unstable_count:-0}" -gt 0 ]]; then
		echo "### Unstable Pages"
		echo ""
		printf '%s' "$json" | jq -r '
			.pages[] | select(.stable == false) |
			"- **\(.page)**: dom_stable=\(.stable_dom), loads_ok=\(.allLoadsOk), console_errors=\(.totalConsoleErrors), network_errors=\(.totalNetworkErrors), avg_load_ms=\(.avgLoadMs)"
		' 2>/dev/null
		echo ""
	fi

	return 0
}

# =============================================================================
# Smoke Test (Console Errors + Basic Rendering)
# =============================================================================

# Generate the Playwright smoke test script file.
# Args: $1=script_file $2=safe_url $3=pages_array $4=timeout
_generate_smoke_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local timeout="$4"

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
	return 0
}

# Navigate to pages and check for console errors, failed network requests, and basic rendering.
# Args: --url URL --pages "/ /about" --format json|markdown
# Output: JSON or markdown report of console errors and rendering issues
cmd_smoke() {
	local url=""
	local pages="/"
	local format="json"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"

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

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_smoke_script "$script_file" "$safe_url" "$pages_array" "$timeout"

	log_info "Running smoke test on ${url} for pages: ${pages}"
	local exit_code=0
	local output
	output=$(node "$script_file") || exit_code=$?
	rm -f "$script_file"

	if [[ $exit_code -ne 0 ]]; then
		printf '%s\n' "$output"
		return $exit_code
	fi

	if [[ "$format" == "markdown" ]]; then
		_format_smoke_markdown "$output"
	else
		printf '%s\n' "$output"
	fi
	return 0
}

# =============================================================================
# Full QA Run
# =============================================================================

# Execute the four QA phases and combine results into a JSON report string.
# Args: $1=url $2=pages $3=viewports $4=output_dir $5=timestamp $6=timeout $7=max_dim
# Output: combined JSON report (stdout)
_run_qa_phases() {
	local url="$1"
	local pages="$2"
	local viewports="$3"
	local output_dir="$4"
	local timestamp="$5"
	local timeout="$6"
	local max_dim="$7"

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
	screenshot_result=$(cmd_screenshot --url "$url" --pages "$pages" --viewports "$viewports" --output-dir "$screenshot_dir" --timeout "$timeout" --max-dim "$max_dim" 2>/dev/null) || screenshot_result='{"error": "screenshot capture failed"}'

	# Phase 3: Broken links
	log_info "--- Phase 3: Broken Link Check ---"
	local links_result
	links_result=$(cmd_links --url "$url" --timeout "$timeout" 2>/dev/null) || links_result='{"error": "link check failed"}'

	# Phase 4: Accessibility
	log_info "--- Phase 4: Accessibility ---"
	local a11y_result
	a11y_result=$(cmd_a11y --url "$url" --pages "$pages" 2>/dev/null) || a11y_result='{"error": "accessibility check failed"}'

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
	return 0
}

# Run the complete QA pipeline: smoke test, screenshots, broken links, accessibility.
# Args: --url URL --pages "/ /about" --viewports "desktop,mobile" --format json|markdown
# Output: Combined JSON report
cmd_run() {
	local url=""
	local pages="/"
	local viewports="$BROWSER_QA_DEFAULT_VIEWPORTS"
	local format="json"
	local output_dir="$QA_RESULTS_DIR"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local max_dim=""

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
		--max-dim)
			max_dim="$2"
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

	local combined
	combined=$(_run_qa_phases "$url" "$pages" "$viewports" "$output_dir" "$timestamp" "$timeout" "$max_dim")

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

# Convert standalone smoke test JSON to markdown.
# Args: $1 = JSON string with { summary: {...}, pages: [...] }
_format_smoke_markdown() {
	local json="$1"

	echo "## Smoke Test Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo ""

	local total
	total=$(printf '%s' "$json" | jq -r '.summary.total // 0' 2>/dev/null)
	local passed
	passed=$(printf '%s' "$json" | jq -r '.summary.passed // 0' 2>/dev/null)
	local failed
	failed=$(printf '%s' "$json" | jq -r '.summary.failed // 0' 2>/dev/null)
	local console_errs
	console_errs=$(printf '%s' "$json" | jq -r '.summary.consoleErrors // 0' 2>/dev/null)
	local network_errs
	network_errs=$(printf '%s' "$json" | jq -r '.summary.networkErrors // 0' 2>/dev/null)

	echo "### Summary"
	echo ""
	echo "| Metric | Count |"
	echo "|--------|-------|"
	echo "| Pages checked | ${total} |"
	echo "| Passed | ${passed} |"
	echo "| Failed | ${failed} |"
	echo "| Console errors | ${console_errs} |"
	echo "| Network errors | ${network_errs} |"
	echo ""

	# Per-page details for failures
	local fail_count
	fail_count=$(printf '%s' "$json" | jq '[.pages[] | select(.ok == false)] | length' 2>/dev/null)
	if [[ "${fail_count:-0}" -gt 0 ]]; then
		echo "### Failed Pages"
		echo ""
		printf '%s' "$json" | jq -r '.pages[] | select(.ok == false) | "- **\(.page)**: status \(.status // "N/A")\(.error // "" | if . != "" then " — " + . else "" end)"' 2>/dev/null
		echo ""
	fi

	return 0
}

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
  stability    Reload pages N times and verify DOM/network quiescence
  help         Show this help message

Common Options:
  --url URL           Base URL to test (required)
  --pages "/ /about"  Space-separated page paths (default: "/")
  --viewports V       Comma-separated viewports: desktop,tablet,mobile (default: desktop,mobile)
  --format FMT        Output format: json or markdown (default: json)
  --timeout MS        Navigation timeout in milliseconds (default: 30000)
  --output-dir DIR    Directory for screenshots and reports
  --max-dim PX        Resize screenshots to this max dimension (default: 4000, Anthropic hard limit: 8000)

Stability-specific Options:
  --reloads N         Number of reloads per page (default: 3, minimum: 1)
  --poll-interval MS  Quiescence poll interval in milliseconds (default: 500)
  --poll-max-wait MS  Maximum wait for network quiescence per reload (default: 10000)

Examples:
  browser-qa-helper.sh run --url http://localhost:3000 --pages "/ /about /dashboard"
  browser-qa-helper.sh screenshot --url http://localhost:3000 --viewports desktop,tablet,mobile --max-dim 4000
  browser-qa-helper.sh links --url http://localhost:3000 --depth 3
  browser-qa-helper.sh a11y --url http://localhost:3000 --level AAA
  browser-qa-helper.sh smoke --url http://localhost:3000 --pages "/ /login"
  browser-qa-helper.sh stability --url http://localhost:3000 --pages "/ /dashboard" --reloads 5
  browser-qa-helper.sh stability --url http://localhost:3000 --format markdown --reloads 3

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
	stability) cmd_stability "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
