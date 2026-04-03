#!/usr/bin/env bash
# design-preview-helper.sh — Generate screenshots from DESIGN.md preview HTML
#
# Usage:
#   design-preview-helper.sh screenshot <preview.html> [--output-dir <dir>] [--format png|webp|avif] [--dark]
#   design-preview-helper.sh generate <DESIGN.md> [--output-dir <dir>]
#
# Commands:
#   screenshot  Capture a preview HTML file as optimised image (light + optional dark)
#   generate    Generate preview.html from a DESIGN.md, then capture screenshots
#
# Requires: node, npx (for playwright), cwebp/avifenc (optional, for format conversion)
#
# Screenshots respect the aidevops screenshot size limit (max 1568px longest side
# for AI review). Full-resolution captures are saved separately.

set -Eeuo pipefail

# shellcheck disable=SC2034
readonly SCRIPT_NAME="design-preview-helper"
readonly MAX_AI_REVIEW_PX=1568
readonly DEFAULT_VIEWPORT_WIDTH=1440
readonly DEFAULT_FORMAT="png"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
	cat <<'EOF'
Usage:
  design-preview-helper.sh screenshot <preview.html> [options]
  design-preview-helper.sh generate <DESIGN.md> [options]

Commands:
  screenshot   Capture preview HTML as optimised screenshots
  generate     Generate preview.html from DESIGN.md, then capture

Options:
  --output-dir <dir>   Output directory (default: same as input file)
  --format <fmt>       Output format: png, webp, avif, all (default: png)
  --dark               Also capture dark mode variant
  --width <px>         Viewport width (default: 1440)
  --full-page          Capture full page (WARNING: may exceed AI review limits)
  --ai-safe            Resize to max 1568px longest side (default: on)

Examples:
  design-preview-helper.sh screenshot preview.html --format all --dark
  design-preview-helper.sh screenshot preview.html --output-dir ./screenshots
EOF
	return 0
}

# Check if a command exists
require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" &>/dev/null; then
		print_error "Required command not found: $cmd"
		return 1
	fi
	return 0
}

# Ensure Playwright is available (install if needed)
ensure_playwright() {
	if ! npx --yes playwright --version &>/dev/null 2>&1; then
		print_info "Installing Playwright..."
		npx --yes playwright install chromium 2>/dev/null || {
			print_error "Failed to install Playwright. Run: npx playwright install chromium"
			return 1
		}
	fi
	return 0
}

# Capture a screenshot of an HTML file using Playwright
# Args: $1=html_path, $2=output_path, $3=viewport_width, $4=theme (light|dark), $5=full_page (true|false)
capture_screenshot() {
	local html_path="$1"
	local output_path="$2"
	local viewport_width="$3"
	local theme="$4"
	local full_page="$5"

	local abs_html_path
	abs_html_path="$(cd "$(dirname "$html_path")" && pwd)/$(basename "$html_path")"

	local full_page_js="false"
	[[ "$full_page" == "true" ]] && full_page_js="true"

	local theme_script=""
	if [[ "$theme" == "dark" ]]; then
		theme_script="await page.evaluate(() => { document.documentElement.setAttribute('data-theme', 'dark'); const btns = document.querySelectorAll('.theme-toggle button'); btns.forEach(b => b.classList.remove('active')); btns.forEach(b => { if (b.textContent.toLowerCase() === 'dark') b.classList.add('active'); }); });"
	fi

	# Use Node.js with Playwright to capture
	node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: ${viewport_width}, height: 900 }
  });
  await page.goto('file://${abs_html_path}', { waitUntil: 'networkidle' });
  await page.waitForTimeout(500); // Allow fonts to render
  ${theme_script}
  await page.waitForTimeout(200); // Allow theme transition
  await page.screenshot({
    path: '${output_path}',
    fullPage: ${full_page_js},
    type: 'png'
  });
  await browser.close();
  process.exit(0);
})().catch(e => { console.error(e.message); process.exit(1); });
" 2>&1 || {
		print_error "Screenshot capture failed for $html_path"
		return 1
	}

	return 0
}

# Convert PNG to WebP
convert_to_webp() {
	local input="$1"
	local output="$2"
	local quality="${3:-90}"

	if command -v cwebp &>/dev/null; then
		cwebp -q "$quality" "$input" -o "$output" 2>/dev/null
		return $?
	elif command -v magick &>/dev/null; then
		magick "$input" -quality "$quality" "$output" 2>/dev/null
		return $?
	else
		print_warning "No WebP converter found (install: brew install webp or imagemagick)"
		return 1
	fi
}

# Convert PNG to AVIF
convert_to_avif() {
	local input="$1"
	local output="$2"
	local quality="${3:-80}"

	if command -v avifenc &>/dev/null; then
		avifenc --min 0 --max 63 -a end-usage=q -a cq-level="$((63 - quality * 63 / 100))" "$input" "$output" 2>/dev/null
		return $?
	elif command -v magick &>/dev/null; then
		magick "$input" -quality "$quality" "$output" 2>/dev/null
		return $?
	else
		print_warning "No AVIF converter found (install: brew install libavif or imagemagick)"
		return 1
	fi
}

# Resize image to AI-safe dimensions (max 1568px longest side)
resize_ai_safe() {
	local input="$1"
	local output="$2"
	local max_px="$3"

	if command -v magick &>/dev/null; then
		magick "$input" -resize "${max_px}x${max_px}>" "$output" 2>/dev/null
		return $?
	elif command -v sips &>/dev/null; then
		# macOS built-in
		cp "$input" "$output"
		sips --resampleLargest "$max_px" "$output" &>/dev/null
		return $?
	else
		print_warning "No image resizer found. AI review may fail with large images."
		cp "$input" "$output"
		return 0
	fi
}

# Main screenshot command
cmd_screenshot() {
	local html_path=""
	local output_dir=""
	local format="$DEFAULT_FORMAT"
	local capture_dark=false
	local viewport_width="$DEFAULT_VIEWPORT_WIDTH"
	local full_page=true
	local ai_safe=true

	# Parse args
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--dark)
			capture_dark=true
			shift
			;;
		--width)
			viewport_width="$2"
			shift 2
			;;
		--full-page)
			full_page=true
			shift
			;;
		--no-ai-safe)
			ai_safe=false
			shift
			;;
		--ai-safe)
			ai_safe=true
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			usage
			return 1
			;;
		*)
			if [[ -z "$html_path" ]]; then
				html_path="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$html_path" ]]; then
		print_error "Missing required argument: <preview.html>"
		usage
		return 1
	fi

	if [[ ! -f "$html_path" ]]; then
		print_error "File not found: $html_path"
		return 1
	fi

	# Default output dir to same as input
	if [[ -z "$output_dir" ]]; then
		output_dir="$(dirname "$html_path")"
	fi
	mkdir -p "$output_dir"

	# Check dependencies
	require_cmd node || return 1
	require_cmd npx || return 1
	ensure_playwright || return 1

	local basename
	basename="$(basename "$html_path" .html)"

	# Capture light mode
	local light_png="$output_dir/${basename}-light.png"
	print_info "Capturing light mode screenshot..."
	if capture_screenshot "$html_path" "$light_png" "$viewport_width" "light" "$full_page"; then
		print_success "Light mode: $light_png"
	else
		return 1
	fi

	# Capture dark mode
	local dark_png=""
	if [[ "$capture_dark" == "true" ]]; then
		dark_png="$output_dir/${basename}-dark.png"
		print_info "Capturing dark mode screenshot..."
		if capture_screenshot "$html_path" "$dark_png" "$viewport_width" "dark" "$full_page"; then
			print_success "Dark mode: $dark_png"
		fi
	fi

	# AI-safe resize
	if [[ "$ai_safe" == "true" ]]; then
		local ai_light="$output_dir/${basename}-light-ai.png"
		resize_ai_safe "$light_png" "$ai_light" "$MAX_AI_REVIEW_PX"
		print_info "AI-safe copy: $ai_light (max ${MAX_AI_REVIEW_PX}px)"

		if [[ -n "$dark_png" && -f "$dark_png" ]]; then
			local ai_dark="$output_dir/${basename}-dark-ai.png"
			resize_ai_safe "$dark_png" "$ai_dark" "$MAX_AI_REVIEW_PX"
			print_info "AI-safe copy: $ai_dark (max ${MAX_AI_REVIEW_PX}px)"
		fi
	fi

	# Format conversions
	local all_pngs=("$light_png")
	[[ -n "$dark_png" && -f "$dark_png" ]] && all_pngs+=("$dark_png")

	for png in "${all_pngs[@]}"; do
		local base="${png%.png}"
		if [[ "$format" == "webp" || "$format" == "all" ]]; then
			if convert_to_webp "$png" "${base}.webp"; then
				print_success "WebP: ${base}.webp"
			fi
		fi
		if [[ "$format" == "avif" || "$format" == "all" ]]; then
			if convert_to_avif "$png" "${base}.avif"; then
				print_success "AVIF: ${base}.avif"
			fi
		fi
	done

	echo ""
	print_success "Screenshots saved to: $output_dir"
	return 0
}

# Main
main() {
	local cmd="${1:-}"
	shift 2>/dev/null || true

	case "$cmd" in
	screenshot | s) cmd_screenshot "$@" ;;
	generate | g)
		print_info "Generate is not yet implemented."
		print_info "Generate a preview.html from your DESIGN.md using the template at:"
		print_info "  ~/.aidevops/agents/tools/design/library/_template/preview.html.template"
		print_info "Then run: design-preview-helper.sh screenshot <preview.html>"
		return 0
		;;
	-h | --help | help) usage ;;
	*)
		print_error "Unknown command: $cmd"
		usage
		return 1
		;;
	esac
}

main "$@"
