#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Browser QA Helper -- Core Utilities
# =============================================================================
# Viewport definitions, image dimension handling, JS array builders,
# prerequisite checks, and screenshot capture.
#
# Usage: source "${SCRIPT_DIR}/browser-qa-helper-core.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error)
#   - sips or magick for image operations
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_BROWSER_QA_CORE_LIB_LOADED:-}" ]] && return 0
_BROWSER_QA_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

# Shared WHATWG URL resolution for generated scripts and contrast checks.
# Omitted --pages loads the supplied URL unchanged, including query/fragment.
_page_url_js() {
	cat <<'JS'
function resolvePageUrl(baseUrl, pagePath, pagesDefault) {
  return pagesDefault ? baseUrl : new URL(pagePath, baseUrl).href;
}
JS
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

# Resolve the exact Playwright package and browser runtime used by generated scripts.
check_playwright() {
	if ! command -v node &>/dev/null; then
		log_error "Node.js not found. Install Node.js first."
		return 1
	fi

	local runtime_script="${SCRIPT_DIR}/playwright-runtime.mjs"
	if [[ ! -f "$runtime_script" ]]; then
		log_error "Playwright runtime resolver not found: ${runtime_script}"
		return 1
	fi

	local resolved_module resolved_executable
	if ! resolved_module=$(node "$runtime_script" check); then
		log_error "Browser QA requires both an importable Playwright Node package and an installed browser binary."
		return 1
	fi
	if ! resolved_executable=$(node "$runtime_script" browser-executable); then
		log_error "Browser QA could not resolve the verified standalone browser executable."
		return 1
	fi
	export AIDEVOPS_PLAYWRIGHT_MODULE="$resolved_module"
	export AIDEVOPS_PLAYWRIGHT_EXECUTABLE="$resolved_executable"
	return 0
}

# Run a Node script with the exact Playwright module verified by check_playwright.
# Args: $1 = script path, remaining args are passed to the script.
run_playwright_node() {
	local script_file="$1"
	shift
	if [[ -z "${AIDEVOPS_PLAYWRIGHT_MODULE:-}" ]]; then
		check_playwright || return 1
	fi
	AIDEVOPS_PLAYWRIGHT_MODULE="$AIDEVOPS_PLAYWRIGHT_MODULE" node "$script_file" "$@"
	return $?
}

# Run an opt-in declarative authenticated read-only journey (GH#32375).
# Credentials are read from the environment-variable names in the config; the
# runner prints one redacted JSON report and writes no artifacts.
# Options: --config <journey.json> --environment <name>
cmd_journey() {
	local config_path=""
	local environment=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local option_value="${2:-}"
		case "$option" in
		--config | --environment)
			if [[ -z "$option_value" ]]; then
				log_error "${option} requires a value"
				return 1
			fi
			if [[ "$option" == "--config" ]]; then
				config_path="$option_value"
			else
				environment="$option_value"
			fi
			shift 2
			;;
		*)
			log_error "Unknown option: $option"
			return 1
			;;
		esac
	done
	if [[ -z "$config_path" || -z "$environment" || ! -f "$config_path" ]]; then
		log_error "journey requires an existing --config file and --environment name"
		return 1
	fi
	run_playwright_node "${SCRIPT_DIR}/browser-qa-journey.mjs" "$config_path" "$environment" || return 1
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
# Args: $1=script_file $2=safe_url $3=viewport_array $4=pages_array $5=safe_output_dir
#       $6=timeout $7=full_page $8=pages_default (true)
#       $9=schemes_array (null: browser default) $10=safe_scroll_to
#       $11=safe_measure_file $12=safe_label (all empty: no scroll, measure or label)
_generate_screenshot_script() {
	local script_file="$1"
	_generate_screenshot_setup "$@"
	_generate_screenshot_capture "$script_file"
	return 0
}

# Shell-supplied constants and URL resolution. Nothing here may use import or
# top-level await: the generator test evaluates this prefix in a bare vm context.
_generate_screenshot_setup() {
	local script_file="$1"
	local safe_url="$2"
	local viewport_array="$3"
	local pages_array="$4"
	local safe_output_dir="$5"
	local timeout="$6"
	local full_page="$7"
	local pages_default="${8:-true}"
	local schemes_array="${9:-null}"
	local safe_scroll_to="${10:-}"
	local safe_measure_file="${11:-}"
	local safe_label="${12:-}"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}';
const pagesDefault = ${pages_default};
$(_page_url_js)
const viewports = [${viewport_array}];
const pages = [${pages_array}];
const outputDir = '${safe_output_dir}';
const timeout = ${timeout};
const fullPage = ${full_page};
const schemes = [${schemes_array}];
const scrollTo = '${safe_scroll_to}';
const measureFile = '${safe_measure_file}';
const label = '${safe_label}';

SCRIPT
	return 0
}

# Capture loop: one context per viewport and colour scheme, one result per page.
_generate_screenshot_capture() {
	local script_file="$1"
	cat >>"$script_file" <<'SCRIPT'
async function run() {
  let measureSource = null;
  if (measureFile) {
    const { readFile } = await import('node:fs/promises');
    measureSource = await readFile(measureFile, 'utf8');
    // Function expressions only: no module imports/exports. This is trusted operator code.
    if (typeof (0, eval)(`(${measureSource}\n)`) !== 'function') throw new Error('--measure-file must contain a function expression');
  }
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const results = [];

  for (const vp of viewports) {
    for (const scheme of schemes) {
      const context = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        ...(scheme ? { colorScheme: scheme } : {}),
      });
      const page = await context.newPage();
      const watch = watchPage(page);
      for (const pagePath of pages) {
        results.push(await capturePage(page, watch, vp, scheme, pagePath, measureSource));
      }
      await context.close();
    }
  }

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}

// Console errors (smoke's { text, location } shape), uncaught page errors and in-flight requests.
function watchPage(page) {
  const watch = { errors: [], inflight: 0 };
  page.on('console', msg => { if (msg.type() === 'error') watch.errors.push({ text: msg.text(), location: msg.location() }); });
  page.on('pageerror', err => watch.errors.push({ text: err.message }));
  page.on('request', () => { watch.inflight += 1; });
  const done = () => { watch.inflight = Math.max(0, watch.inflight - 1); };
  page.on('requestfinished', done);
  page.on('requestfailed', done);
  return watch;
}

// Filename: [label-]page-viewport[-scheme]-WxH.png. Measure after capture so it cannot change the image.
async function capturePage(page, watch, vp, scheme, pagePath, measureSource) {
  const url = resolvePageUrl(baseUrl, pagePath, pagesDefault);
  const safeName = pagePath.replace(/\//g, '_').replace(/^_/, '') || 'index';
  const parts = [label, safeName, vp.name, scheme, `${vp.width}x${vp.height}`].filter(Boolean);
  const filepath = `${outputDir}/${parts.join('-')}.png`;
  const result = { page: pagePath, viewport: vp.name, file: filepath, status: 'ok' };
  if (label) result.label = label;
  if (scheme) result.colorScheme = scheme;
  watch.errors = [];
  result.httpStatus = null;
  result.consoleErrors = watch.errors;
  try {
    const response = await page.goto(url, { waitUntil: 'load', timeout });
    result.httpStatus = response ? response.status() : null;
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    if (scrollTo) await scrollToTarget(page, watch, result);
    await page.screenshot({ path: filepath, fullPage });
  } catch (err) {
    result.status = 'error';
    result.error = err.message;
    return result;
  }
  if (measureSource) {
    try {
      const value = await page.evaluate(`(${measureSource}\n)()`);
      result.measurement = value === undefined ? null : value;
    } catch (err) {
      result.measureError = String(err.message || err).split('\n')[0];
    }
  }
  return result;
}

// Centre the first match; a missing match still captures, with found: false.
async function scrollToTarget(page, watch, result) {
  let target = null;
  try {
    target = await page.$(scrollTo);
  } catch (err) {
    result.scrollError = err.message;
  }
  result.found = Boolean(target);
  if (target) {
    await target.evaluate(el => el.scrollIntoView({ block: 'center', behavior: 'instant' }));
    await settle(page, watch);
  }
  result.scrollY = await page.evaluate(() => window.scrollY);
}

// Wait for 500 ms without in-flight requests (lazy images), capped at 5 s like the load wait.
async function settle(page, watch) {
  const deadline = Date.now() + 5000;
  let quietSince = Date.now();
  while (Date.now() < deadline) {
    await page.waitForTimeout(100);
    if (watch.inflight > 0) quietSince = Date.now();
    else if (Date.now() - quietSince >= 500) return;
  }
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# Parse cmd_screenshot arguments into caller-scope _ss_* variables.
# Args: all original $@ from cmd_screenshot
_parse_screenshot_args() {
	_ss_url=""
	_ss_pages="/"
	_ss_pages_default=true
	_ss_viewports="$BROWSER_QA_DEFAULT_VIEWPORTS"
	_ss_output_dir="$SCREENSHOTS_DIR"
	_ss_timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	_ss_full_page="false"
	_ss_max_dim=""
	_ss_color_schemes=""
	_ss_scroll_to=""
	_ss_measure_file=""
	_ss_label=""

	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--full-page)
			_ss_full_page="true"
			shift
			continue
			;;
		--url | --pages | --viewports | --output-dir | --timeout | --max-dim | --color-schemes | --scroll-to | --measure-file | --label) ;;
		*)
			log_error "Unknown option: $opt"
			return 1
			;;
		esac
		if [[ $# -lt 2 ]]; then
			log_error "$opt needs a value"
			return 1
		fi
		local value="$2"
		case "$opt" in
		--url) _ss_url="$value" ;;
		--pages)
			_ss_pages="$value"
			_ss_pages_default=false
			;;
		--viewports) _ss_viewports="$value" ;;
		--output-dir) _ss_output_dir="$value" ;;
		--timeout) _ss_timeout="$value" ;;
		--max-dim) _ss_max_dim="$value" ;;
		--color-schemes) _ss_color_schemes="$value" ;;
		--scroll-to) _ss_scroll_to="$value" ;;
		--measure-file) _ss_measure_file="$value" ;;
		--label) _ss_label="$value" ;;
		esac
		shift 2
	done
	return 0
}

# Validate the screenshot evidence options before anything is written.
# Reads: _ss_color_schemes _ss_label _ss_measure_file _ss_scroll_to
_validate_screenshot_args() {
	if [[ -n "$_ss_color_schemes" ]]; then
		local scheme
		local -a schemes=()
		IFS=',' read -r -a schemes <<<"$_ss_color_schemes"
		[[ ${#schemes[@]} -gt 0 ]] || schemes=("")
		for scheme in "${schemes[@]}"; do
			case "$scheme" in
			light | dark | no-preference) ;;
			*)
				log_error "Unknown colour scheme '${scheme}': use light, dark or no-preference"
				return 1
				;;
			esac
		done
	fi
	if [[ -n "$_ss_label" && ! "$_ss_label" =~ ^[A-Za-z0-9._-]+$ ]]; then
		log_error "--label must match [A-Za-z0-9._-]+"
		return 1
	fi
	if [[ -n "$_ss_measure_file" && ! (-f "$_ss_measure_file" && -r "$_ss_measure_file") ]]; then
		log_error "--measure-file is not a readable file: $_ss_measure_file"
		return 1
	fi
	return 0
}

# Build the JS schemes array: quoted validated schemes, or null for the browser default.
# Args: $1 = comma-separated schemes (may be empty)
_build_schemes_js_array() {
	local list="$1"
	if [[ -z "$list" ]]; then
		printf 'null'
		return 0
	fi
	local scheme out=""
	local -a schemes=()
	IFS=',' read -r -a schemes <<<"$list"
	for scheme in "${schemes[@]}"; do
		out+="${out:+,}'${scheme}'"
	done
	printf '%s' "$out"
	return 0
}

# Capture screenshots of pages at specified viewports using Playwright.
# Args: --url URL --pages "/ /about /dashboard" --viewports "desktop,mobile" --output-dir DIR
# Output: Screenshot file paths, one per line
cmd_screenshot() {
	local _ss_url _ss_pages _ss_pages_default _ss_viewports _ss_output_dir _ss_timeout
	local _ss_full_page _ss_max_dim _ss_color_schemes _ss_scroll_to _ss_measure_file _ss_label
	_parse_screenshot_args "$@" || return 1
	local url="$_ss_url"
	local pages="$_ss_pages"
	local pages_default="$_ss_pages_default"
	local viewports="$_ss_viewports"
	local output_dir="$_ss_output_dir"
	local timeout="$_ss_timeout"
	local full_page="$_ss_full_page"
	local max_dim="$_ss_max_dim"

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	_validate_screenshot_args || return 1
	local measure_file="$_ss_measure_file"
	if [[ -n "$measure_file" && "$measure_file" != /* ]]; then
		measure_file="$(pwd)/${measure_file}"
	fi

	max_dim=$(resolve_max_image_dim "$max_dim")
	local created_output_dir=false
	[[ -d "$output_dir" ]] || created_output_dir=true
	mkdir -p "$output_dir"

	# t2997: node ESM requires exact .mjs extension; use mktemp -d for a unique
	# directory + fixed-name script.mjs inside (XXXXXX must be at end for BSD
	# mktemp). Cleanup is rm -rf on the directory.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-screenshot-XXXXXX")
	script_file="$script_dir/script.mjs"

	local viewport_array
	viewport_array=$(_build_viewports_js_array "$viewports")
	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url safe_output_dir
	safe_url=$(js_escape_string "$url")
	safe_output_dir=$(js_escape_string "$output_dir")
	local schemes_array safe_scroll_to safe_measure_file safe_label
	schemes_array=$(_build_schemes_js_array "$_ss_color_schemes")
	safe_scroll_to=$(js_escape_string "$_ss_scroll_to")
	safe_measure_file=$(js_escape_string "$measure_file")
	safe_label=$(js_escape_string "$_ss_label")

	_generate_screenshot_script "$script_file" "$safe_url" "$viewport_array" "$pages_array" "$safe_output_dir" "$timeout" "$full_page" "$pages_default" \
		"$schemes_array" "$safe_scroll_to" "$safe_measure_file" "$safe_label"

	log_info "Capturing screenshots for ${pages} at viewports: ${viewports}"
	local exit_code=0
	run_playwright_node "$script_file" || exit_code=$?
	rm -rf "$script_dir"

	if [[ "$exit_code" -ne 0 ]]; then
		# A run that failed before capturing leaves no empty directory it created.
		if [[ "$created_output_dir" == true ]]; then
			rmdir "$output_dir" 2>/dev/null || true
		fi
		return "$exit_code"
	fi

	if ! enforce_screenshot_size_guardrails "$output_dir" "$max_dim"; then
		log_error "Screenshot guardrail enforcement failed"
		return 1
	fi

	return 0
}
