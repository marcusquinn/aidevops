#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Browser QA Helper -- Accessibility Checks
# =============================================================================
# Contrast checks, ARIA validation, heading hierarchy, and document-level
# accessibility audits using Playwright.
#
# Usage: source "${SCRIPT_DIR}/browser-qa-helper-a11y.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error)
#   - browser-qa-helper-core.sh (js_escape_string, _build_pages_js_array)
#   - accessibility/playwright-contrast.mjs (optional, for contrast checks)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_BROWSER_QA_A11Y_LIB_LOADED:-}" ]] && return 0
_BROWSER_QA_A11Y_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
	local pages_default="${4:-false}"
	local viewport="${5:-desktop}"
	local contrast_script="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"
	local contrast_json='[]'

	for page_path in $pages; do
		local full_url
		full_url=$(node -e "$(_page_url_js); console.log(resolvePageUrl(process.argv[1], process.argv[2], process.argv[3] === 'true'));" "$url" "$page_path" "$pages_default") || return 1
		log_info "Running accessibility check on ${full_url} (level: ${level})"

		if [[ -f "$contrast_script" ]]; then
			local contrast_result
			local contrast_exit=0
			contrast_result=$(run_playwright_node "$contrast_script" "$full_url" --format json --level "$level" --viewport "$viewport" 2>/dev/null) || contrast_exit=$?
			# Exit 1 means findings, not a tool error. Require one complete JSON value.
			if [[ "$contrast_exit" -gt 1 ]] || ! jq -e -s 'length == 1' >/dev/null 2>&1 <<<"$contrast_result"; then
				contrast_result=$(jq -cn --argjson exit "$contrast_exit" '{error: "contrast check failed", exit: $exit}')
			fi
			contrast_json=$(printf '%s\n%s\n' "$contrast_json" "$contrast_result" | jq -cs \
				--arg page "$page_path" \
				'.[0] + [{page: $page, contrast: .[1]}]') || return 1
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
	local pages_default="${4:-true}"
	local element_checks document_checks
	element_checks=$(_a11y_js_element_checks)
	document_checks=$(_a11y_js_document_checks)
	local evaluate_body="${element_checks}
${document_checks}"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}';
const pagesDefault = ${pages_default};
$(_page_url_js)
const pages = [${pages_array}];

async function run() {
  const { readFile } = await import('node:fs/promises');
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const viewports = { desktop: { width: 1440, height: 900 }, tablet: { width: 768, height: 1024 }, mobile: { width: 375, height: 812 } };
  const context = await browser.newContext({ viewport: viewports[process.argv[3]] });
  const page = await context.newPage();
  const a11yResults = [];
  // Keep potentially large reports off argv (and the process startup stack).
  const contrastData = JSON.parse(await readFile(process.argv[2], 'utf8'));

  for (const pagePath of pages) {
    const url = resolvePageUrl(baseUrl, pagePath, pagesDefault);
    try {
      await page.goto(url, { waitUntil: 'load', timeout: 30000 });
      await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});

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

# Format an a11y report from stdin without placing report data in argv.
_format_a11y_markdown() {
	local level="$1"
	printf '## Accessibility report (WCAG %s)\n\n' "$level"
	jq -r --arg level "$level" '.[] |
		"### \(.page) — \(.viewport)\n",
		(if .error then "Error: \(.error)" else
		"Structure: \(.summary.errors) errors, \(.summary.warnings) warnings",
		(.issues[] | "- \(.severity): \(.message)") end),
		(if (.contrast | type) == "array" then
		(.contrast | group_by(if .complexBackground then "manual" elif (if $level == "AAA" then .aaa.pass else .aa.pass end) then "pass" else "fail" end)[] |
		"Contrast \(.[0] | if .complexBackground then "needs manual/pixel check" elif (if $level == "AAA" then .aaa.pass else .aa.pass end) then "pass" else "fail" end): \(length)",
		(.[] | "- \(.selector): \(if .complexBackground then "needs manual/pixel check (" + (.complexBackground | join(", ")) + ")" else (.ratio | tostring) + ":1" end)"))
		else "Contrast check error: \(.contrast.error // "no data")" end), ""' || return 1
	return 0
}

# Run accessibility checks on pages using Playwright.
# Delegates to playwright-contrast.mjs for contrast, adds ARIA and structure checks.
# Args: --url URL --pages "/ /about" --level AA|AAA --format json|markdown
#       --viewports desktop,tablet,mobile (default: desktop)
# Output: JSON or Markdown accessibility report
cmd_a11y() {
	local url=""
	local pages="/"
	local pages_default=true
	local level="AA"
	local format="json"
	local viewports="desktop"

	while [[ $# -gt 0 ]]; do
		local option="$1"
		local value="${2:-}"
		if [[ -z "$value" || "$value" == --* ]]; then
			log_error "$option requires a value"
			return 1
		fi
		case "$option" in
		--url)
			url="$value"
			;;
		--pages)
			pages="$value"
			pages_default=false
			;;
		--level)
			level="$value"
			;;
		--format)
			format="$value"
			;;
		--viewports)
			viewports="$value"
			;;
		*)
			log_error "Unknown option: $option"
			return 1
			;;
		esac
		shift 2
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	if [[ "$format" != "json" && "$format" != "markdown" ]] || [[ "$level" != "AA" && "$level" != "AAA" ]]; then
		log_error "Use --format json|markdown and --level AA|AAA"
		return 1
	fi
	if [[ ! "$viewports" =~ ^(desktop|tablet|mobile)(,(desktop|tablet|mobile))*$ ]]; then
		log_error "Use --viewports desktop,tablet,mobile (one or more)"
		return 1
	fi

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-a11y-XXXXXX") || return 1
	script_file="$script_dir/script.mjs"

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_a11y_script "$script_file" "$safe_url" "$pages_array" "$pages_default"

	local exit_code=0
	local viewport contrast_json output
	local report='[]'
	local -a viewport_list
	IFS=',' read -r -a viewport_list <<<"$viewports"
	for viewport in "${viewport_list[@]}"; do
		contrast_json=$(_run_contrast_checks "$url" "$pages" "$level" "$pages_default" "$viewport") || {
			exit_code=1
			break
		}
		printf '%s\n' "$contrast_json" >"$script_dir/contrast.json"
		output=$(run_playwright_node "$script_file" "$script_dir/contrast.json" "$viewport") || {
			exit_code=$?
			break
		}
		report=$(printf '%s\n%s\n' "$report" "$output" | jq -cs --arg viewport "$viewport" \
			'.[0] + (.[1] | map(. + {viewport: $viewport}))') || {
			exit_code=1
			break
		}
	done
	rm -rf "$script_dir"
	if [[ "$exit_code" -ne 0 ]]; then
		return "$exit_code"
	fi
	if [[ "$format" == "markdown" ]]; then
		printf '%s\n' "$report" | _format_a11y_markdown "$level" || return 1
	else
		printf '%s\n' "$report"
	fi
	return $exit_code
}
