#!/usr/bin/env bash
# shellcheck disable=SC1091

# Higgsfield Helper - UI automation for Higgsfield AI via Playwright
# Part of AI DevOps Framework
# Uses browser automation to access Higgsfield UI with subscription credits

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
    source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Constants
readonly HIGGSFIELD_DIR="${SCRIPT_DIR}/higgsfield"
readonly AUTOMATOR="${HIGGSFIELD_DIR}/playwright-automator.mjs"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/work/higgsfield"
readonly STATE_FILE="${STATE_DIR}/auth-state.json"

# Print helpers (fallback if shared-constants not loaded)
if ! command -v print_info &>/dev/null; then
    print_info() { echo "[INFO] $*"; }
    print_success() { echo "[OK] $*"; }
    print_error() { echo "[ERROR] $*" >&2; }
    print_warning() { echo "[WARN] $*"; }
fi

# Check dependencies
check_deps() {
    local missing=0

    if ! command -v node &>/dev/null && ! command -v bun &>/dev/null; then
        print_error "Node.js or Bun is required"
        missing=1
    fi

    if ! node -e "require('playwright')" 2>/dev/null && ! bun -e "import 'playwright'" 2>/dev/null; then
        print_warning "Playwright not found, installing..."
        if command -v bun &>/dev/null; then
            bun install playwright 2>/dev/null || npm install playwright 2>/dev/null
        else
            npm install playwright 2>/dev/null
        fi
    fi

    return "${missing}"
}

# Run the automator script
run_automator() {
    local runner="node"
    if command -v bun &>/dev/null; then
        runner="bun"
    fi

    "${runner}" "${AUTOMATOR}" "$@"
}

# Setup - install dependencies and create directories
setup() {
    print_info "Setting up Higgsfield UI automator..."

    mkdir -p "${STATE_DIR}"

    # Check for playwright
    if ! node -e "require('playwright')" 2>/dev/null; then
        print_info "Installing Playwright..."
        if command -v bun &>/dev/null; then
            bun install playwright
        else
            npm install playwright
        fi
        npx playwright install chromium 2>/dev/null || true
    fi

    # Check credentials
    local cred_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "${cred_file}" ]]; then
        if grep -q "HIGGSFIELD_USER" "${cred_file}" && grep -q "HIGGSFIELD_PASS" "${cred_file}"; then
            print_success "Higgsfield credentials found"
        else
            print_warning "Higgsfield credentials not found in ${cred_file}"
            print_info "Add HIGGSFIELD_USER and HIGGSFIELD_PASS to credentials.sh"
        fi
    else
        print_error "Credentials file not found: ${cred_file}"
        return 1
    fi

    print_success "Setup complete"
    return 0
}

# Login to Higgsfield
cmd_login() {
    print_info "Logging into Higgsfield UI..."
    run_automator login --headed "$@"
}

# Generate image
cmd_image() {
    local prompt="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${prompt}" ]]; then
        print_error "Prompt is required"
        print_info "Usage: higgsfield-helper.sh image \"your prompt here\" [options]"
        return 1
    fi

    print_info "Generating image: ${prompt}"
    run_automator image --prompt "${prompt}" "$@"
}

# Generate video
cmd_video() {
    local prompt="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${prompt}" ]]; then
        print_error "Prompt is required"
        print_info "Usage: higgsfield-helper.sh video \"your prompt here\" [options]"
        return 1
    fi

    print_info "Generating video: ${prompt}"
    run_automator video --prompt "${prompt}" "$@"
}

# Use an app/effect
cmd_app() {
    local effect="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${effect}" ]]; then
        print_error "App/effect slug is required"
        print_info "Usage: higgsfield-helper.sh app <effect-slug> [options]"
        print_info "Examples: face-swap, 3d-render, comic-book, transitions"
        return 1
    fi

    print_info "Using app: ${effect}"
    run_automator app --effect "${effect}" "$@"
}

# List assets
cmd_assets() {
    print_info "Listing recent assets..."
    run_automator assets "$@"
}

# Check credits
cmd_credits() {
    print_info "Checking account credits..."
    run_automator credits "$@"
}

# Take screenshot
cmd_screenshot() {
    local url="${1:-}"
    shift 2>/dev/null || true

    run_automator screenshot --prompt "${url}" "$@"
}

# Download latest
cmd_download() {
    print_info "Downloading latest generation..."
    run_automator download "$@"
}

# Check auth status
cmd_status() {
    if [[ -f "${STATE_FILE}" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -f %m "${STATE_FILE}" 2>/dev/null || stat -c %Y "${STATE_FILE}" 2>/dev/null || echo 0) ))
        local hours=$(( age / 3600 ))
        print_success "Auth state exists (${hours}h old)"
        print_info "State file: ${STATE_FILE}"
    else
        print_warning "No auth state found. Run: higgsfield-helper.sh login"
    fi
}

# Show help
show_help() {
    cat <<'EOF'
Higgsfield Helper - UI automation for Higgsfield AI

Usage: higgsfield-helper.sh <command> [arguments] [options]

Commands:
  setup              Install dependencies and verify credentials
  login              Login to Higgsfield (opens browser)
  status             Check auth state
  image <prompt>     Generate image from text prompt
  video <prompt>     Generate video (text or image-to-video)
  app <effect>       Use a Higgsfield app/effect
  assets             List recent generations
  credits            Check account credits/plan
  screenshot [url]   Take screenshot of a page
  download           Download latest generation
  help               Show this help

Options (pass after command):
  --headed           Show browser window
  --headless         Run without browser window (default)
  --model, -m        Model: soul, nano_banana, seedream
  --output, -o       Output directory
  --image-file       Image file for upload
  --timeout          Timeout in milliseconds
  --effect           App/effect slug

Examples:
  higgsfield-helper.sh setup
  higgsfield-helper.sh login
  higgsfield-helper.sh image "A cyberpunk city at night, neon lights, rain"
  higgsfield-helper.sh image "Portrait of a woman" --model nano_banana
  higgsfield-helper.sh video "Camera pans across mountain landscape"
  higgsfield-helper.sh video "Person walks forward" --image-file photo.jpg
  higgsfield-helper.sh app face-swap --image-file face.jpg
  higgsfield-helper.sh app 3d-render --image-file product.jpg
  higgsfield-helper.sh assets
  higgsfield-helper.sh credits
  higgsfield-helper.sh screenshot https://higgsfield.ai/image/soul

Available Apps/Effects:
  face-swap, 3d-render, comic-book, transitions, recast,
  skin-enhancer, angles, relight, shots, zooms, poster,
  sketch-to-real, renaissance, mugshot, and many more.
  See: https://higgsfield.ai/apps
EOF
}

# Main
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "${command}" in
        setup)      setup "$@" ;;
        login)      cmd_login "$@" ;;
        status)     cmd_status "$@" ;;
        image)      cmd_image "$@" ;;
        video)      cmd_video "$@" ;;
        app)        cmd_app "$@" ;;
        assets)     cmd_assets "$@" ;;
        credits)    cmd_credits "$@" ;;
        screenshot) cmd_screenshot "$@" ;;
        download)   cmd_download "$@" ;;
        help|--help|-h)
            show_help ;;
        *)
            print_error "Unknown command: ${command}"
            show_help
            return 1
            ;;
    esac
}

main "$@"
