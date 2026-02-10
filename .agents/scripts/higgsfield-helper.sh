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

# Batch image generation
cmd_batch_image() {
    local batch_file="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${batch_file}" ]]; then
        print_error "Batch manifest file is required"
        print_info "Usage: higgsfield-helper.sh batch-image manifest.json [--concurrency 2] [options]"
        return 1
    fi

    if [[ ! -f "${batch_file}" ]]; then
        print_error "Batch manifest not found: ${batch_file}"
        return 1
    fi

    print_info "Batch image generation from: ${batch_file}"
    run_automator batch-image --batch-file "${batch_file}" "$@"
}

# Batch video generation
cmd_batch_video() {
    local batch_file="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${batch_file}" ]]; then
        print_error "Batch manifest file is required"
        print_info "Usage: higgsfield-helper.sh batch-video manifest.json [--concurrency 3] [options]"
        return 1
    fi

    if [[ ! -f "${batch_file}" ]]; then
        print_error "Batch manifest not found: ${batch_file}"
        return 1
    fi

    print_info "Batch video generation from: ${batch_file}"
    run_automator batch-video --batch-file "${batch_file}" "$@"
}

# Batch lipsync generation
cmd_batch_lipsync() {
    local batch_file="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "${batch_file}" ]]; then
        print_error "Batch manifest file is required"
        print_info "Usage: higgsfield-helper.sh batch-lipsync manifest.json [--concurrency 1] [options]"
        return 1
    fi

    if [[ ! -f "${batch_file}" ]]; then
        print_error "Batch manifest not found: ${batch_file}"
        return 1
    fi

    print_info "Batch lipsync generation from: ${batch_file}"
    run_automator batch-lipsync --batch-file "${batch_file}" "$@"
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

# Auth health check - verify auth is valid
cmd_health_check() {
    print_info "Running auth health check..."
    run_automator health-check "$@"
    return $?
}

# Smoke test - quick end-to-end test
cmd_smoke_test() {
    print_info "Running smoke test (no credits used)..."
    run_automator smoke-test "$@"
    return $?
}

# Show help
show_help() {
    cat <<'EOF'
Higgsfield Helper - UI automation for Higgsfield AI

Usage: higgsfield-helper.sh <command> [arguments] [options]

Commands:
  setup              Install dependencies and verify credentials
  login              Login to Higgsfield (opens browser)
  status             Check auth state (local file check only)
  health-check       Verify auth is valid by testing login (no credits used)
  smoke-test         Run quick end-to-end test (no credits used)
  image <prompt>     Generate image from text prompt
  video <prompt>     Generate video (text or image-to-video)
  lipsync <text>     Generate lipsync video (image + text)
  batch-image <file> Batch image generation from JSON manifest
  batch-video <file> Batch video generation from JSON manifest
  batch-lipsync <file> Batch lipsync generation from JSON manifest
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
  --dry-run          Configure but don't click Generate (no credits used)
  --model, -m        Model: soul, nano_banana, seedream, kling-2.6, etc.
  --output, -o       Output directory
  --project          Project name for organized output dirs ({output}/{project}/{type}/)
  --image-file       Image file for upload
  --timeout          Timeout in milliseconds
  --effect           App/effect slug
  --seed             Seed number for reproducible generation
  --seed-range       Seed range for bracketing (e.g., "1000-1010")
  --brief            Path to pipeline brief JSON file
  --character-image  Character face image for pipeline
  --dialogue         Dialogue text for lipsync
  --unlimited        Prefer unlimited models only
  --no-sidecar       Disable JSON sidecar metadata files
  --no-dedup         Disable SHA-256 duplicate detection
  --concurrency, -C  Max concurrent jobs for batch operations (default varies)
  --resume           Resume a previous batch run (skip completed jobs)

Examples:
  higgsfield-helper.sh setup
  higgsfield-helper.sh login
  higgsfield-helper.sh image "A cyberpunk city at night, neon lights, rain"
  higgsfield-helper.sh image "Portrait of a woman" --model nano_banana
  higgsfield-helper.sh image "Portrait" --project my-video --output ~/Projects/
  higgsfield-helper.sh video "Camera pans across mountain landscape"
  higgsfield-helper.sh video "Person walks forward" --image-file photo.jpg
  higgsfield-helper.sh lipsync "Hello world!" --image-file face.jpg
  higgsfield-helper.sh pipeline --brief brief.json
  higgsfield-helper.sh pipeline "Person reviews product" --character-image face.png
  higgsfield-helper.sh seed-bracket "Elegant woman, golden hour" --seed-range 1000-1010
  higgsfield-helper.sh app face-swap --image-file face.jpg
  higgsfield-helper.sh credits
  higgsfield-helper.sh batch-image prompts.json --concurrency 2 -o ./output
  higgsfield-helper.sh batch-video videos.json --concurrency 3 -o ./output
  higgsfield-helper.sh batch-lipsync lipsync.json -o ./output
  higgsfield-helper.sh batch-image prompts.json --resume -o ./output

Batch manifest format (JSON):
  Simple: ["prompt 1", "prompt 2", "prompt 3"]
  Full:   { "jobs": [{"prompt":"...","model":"soul"}], "defaults": {"aspect":"16:9"} }

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
        health-check|health) cmd_health_check "$@" ;;
        smoke-test|smoke)    cmd_smoke_test "$@" ;;
        image)      cmd_image "$@" ;;
        video)      cmd_video "$@" ;;
        lipsync)    cmd_lipsync "$@" ;;
        batch-image)  cmd_batch_image "$@" ;;
        batch-video)  cmd_batch_video "$@" ;;
        batch-lipsync) cmd_batch_lipsync "$@" ;;
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
