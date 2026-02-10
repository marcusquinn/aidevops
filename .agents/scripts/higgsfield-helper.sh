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

    # Check for playwright in the higgsfield directory (where package.json lives)
    if ! (cd "${HIGGSFIELD_DIR}" && node -e "require('playwright')" 2>/dev/null) && \
       ! (cd "${HIGGSFIELD_DIR}" && bun -e "import 'playwright'" 2>/dev/null); then
        print_warning "Playwright not found, installing..."
        if command -v bun &>/dev/null; then
            (cd "${HIGGSFIELD_DIR}" && bun install playwright 2>/dev/null) || \
            (cd "${HIGGSFIELD_DIR}" && npm install playwright 2>/dev/null)
        else
            (cd "${HIGGSFIELD_DIR}" && npm install playwright 2>/dev/null)
        fi
    fi

    return "${missing}"
}

# Run the automator script (from HIGGSFIELD_DIR for correct module resolution)
run_automator() {
    local runner="node"
    if command -v bun &>/dev/null; then
        runner="bun"
    fi

    (cd "${HIGGSFIELD_DIR}" && "${runner}" "${AUTOMATOR}" "$@")
    return $?
}

# Setup - install dependencies and create directories
setup() {
    print_info "Setting up Higgsfield UI automator..."

    mkdir -p "${STATE_DIR}"

    # Check for playwright (in HIGGSFIELD_DIR where package.json lives)
    if ! (cd "${HIGGSFIELD_DIR}" && node -e "require('playwright')" 2>/dev/null); then
        print_info "Installing Playwright..."
        if command -v bun &>/dev/null; then
            (cd "${HIGGSFIELD_DIR}" && bun install playwright)
        else
            (cd "${HIGGSFIELD_DIR}" && npm install playwright)
        fi
        (cd "${HIGGSFIELD_DIR}" && npx playwright install chromium 2>/dev/null) || true
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
    return $?
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
    return $?
}

# Check credits
cmd_credits() {
    print_info "Checking account credits..."
    run_automator credits "$@"
    return $?
}

# Take screenshot
cmd_screenshot() {
    local url="${1:-}"
    shift 2>/dev/null || true

    run_automator screenshot --prompt "${url}" "$@"
    return $?
}

# Generate lipsync
cmd_lipsync() {
    local text="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${text}" ]]; then
        print_error "Text is required"
        print_info "Usage: higgsfield-helper.sh lipsync \"text to speak\" --image-file face.jpg [options]"
        return 1
    fi

    print_info "Generating lipsync: ${text}"
    run_automator lipsync --prompt "${text}" "$@"
}

# Run production pipeline
cmd_pipeline() {
    local first_arg="${1:-}"

    # If first arg doesn't start with --, treat it as a prompt
    if [[ -n "${first_arg}" && "${first_arg}" != --* ]]; then
        shift
        print_info "Running pipeline with prompt: ${first_arg}"
        run_automator pipeline --prompt "${first_arg}" "$@"
    else
        print_info "Running production pipeline..."
        run_automator pipeline "$@"
    fi
}

# Seed bracketing
cmd_seed_bracket() {
    local prompt="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${prompt}" ]]; then
        print_error "Prompt is required"
        print_info "Usage: higgsfield-helper.sh seed-bracket \"your prompt\" --seed-range 1000-1010 [options]"
        return 1
    fi

    print_info "Seed bracketing: ${prompt}"
    run_automator seed-bracket --prompt "${prompt}" "$@"
}

# Download latest
cmd_download() {
    print_info "Downloading latest generation..."
    run_automator download "$@"
    return $?
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
    return 0
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
  lipsync <text>     Generate lipsync video (image + text)
  pipeline           Full production: image -> video -> lipsync -> assembly
  seed-bracket       Test seed range to find best seeds for a prompt
  app <effect>       Use a Higgsfield app/effect
  assets             List recent generations
  credits            Check account credits/plan
  screenshot [url]   Take screenshot of a page
  download           Download latest generation
  help               Show this help

Options (pass after command):
  --headed           Show browser window
  --headless         Run without browser window (default)
  --model, -m        Model: soul, nano_banana, seedream, kling-2.6, etc.
  --output, -o       Output directory
  --image-file       Image file for upload
  --timeout          Timeout in milliseconds
  --effect           App/effect slug
  --seed             Seed number for reproducible generation
  --seed-range       Seed range for bracketing (e.g., "1000-1010")
  --brief            Path to pipeline brief JSON file
  --character-image  Character face image for pipeline
  --dialogue         Dialogue text for lipsync
  --unlimited        Prefer unlimited models only

Examples:
  higgsfield-helper.sh setup
  higgsfield-helper.sh login
  higgsfield-helper.sh image "A cyberpunk city at night, neon lights, rain"
  higgsfield-helper.sh image "Portrait of a woman" --model nano_banana
  higgsfield-helper.sh video "Camera pans across mountain landscape"
  higgsfield-helper.sh video "Person walks forward" --image-file photo.jpg
  higgsfield-helper.sh lipsync "Hello world!" --image-file face.jpg
  higgsfield-helper.sh pipeline --brief brief.json
  higgsfield-helper.sh pipeline "Person reviews product" --character-image face.png
  higgsfield-helper.sh seed-bracket "Elegant woman, golden hour" --seed-range 1000-1010
  higgsfield-helper.sh app face-swap --image-file face.jpg
  higgsfield-helper.sh credits

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
        lipsync)    cmd_lipsync "$@" ;;
        pipeline)   cmd_pipeline "$@" ;;
        seed-bracket) cmd_seed_bracket "$@" ;;
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
