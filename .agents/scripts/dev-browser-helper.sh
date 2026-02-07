#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2162

# Dev-Browser Helper - Stateful Browser Automation
# Part of AI DevOps Framework
# Provides setup and management of dev-browser for persistent Playwright automation

set -euo pipefail

# Source shared constants and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
    source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Print functions
# Dev-browser specific constants
readonly DEV_BROWSER_DIR="${HOME}/.aidevops/dev-browser"
readonly DEV_BROWSER_SKILL_DIR="${DEV_BROWSER_DIR}/skills/dev-browser"
readonly DEV_BROWSER_REPO="https://github.com/SawyerHood/dev-browser.git"
readonly SERVER_PORT=9222
readonly PID_FILE="${DEV_BROWSER_DIR}/.server.pid"
readonly PROFILE_DIR="${DEV_BROWSER_SKILL_DIR}/profiles/browser-data"

# Check if Bun is installed
check_bun() {
    if command -v bun &> /dev/null; then
        print_success "Bun $(bun --version) found"
        return 0
    else
        print_error "Bun is required but not installed"
        print_info "Install with: curl -fsSL https://bun.sh/install | bash"
        return 1
    fi
}

# Install Bun if not present
install_bun() {
    if command -v bun &> /dev/null; then
        print_info "Bun already installed: $(bun --version)"
        return 0
    fi
    
    print_info "Installing Bun..."
    # SONAR: Official Bun installer from verified HTTPS source
    curl -fsSL https://bun.sh/install | bash
    
    # Source the updated PATH
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    
    if command -v bun &> /dev/null; then
        print_success "Bun installed: $(bun --version)"
        return 0
    else
        print_error "Bun installation failed"
        return 1
    fi
}

# Install dev-browser
install_dev_browser() {
    print_info "Installing dev-browser..."
    
    # Ensure Bun is installed
    install_bun || return 1
    
    # Create directory
    mkdir -p "${DEV_BROWSER_DIR}"
    
    if [[ -d "${DEV_BROWSER_DIR}/.git" ]]; then
        print_info "Updating existing installation..."
        cd "${DEV_BROWSER_DIR}" || exit
        git pull origin main || {
            print_warning "Git pull failed, continuing with existing version"
        }
    else
        print_info "Cloning dev-browser repository..."
        rm -rf "${DEV_BROWSER_DIR}"
        git clone "${DEV_BROWSER_REPO}" "${DEV_BROWSER_DIR}"
    fi
    
    # Install dependencies
    cd "${DEV_BROWSER_SKILL_DIR}" || exit
    print_info "Installing dependencies..."
    bun install
    
    # Install Playwright browsers
    print_info "Installing Playwright browsers..."
    bunx playwright install chromium
    
    # Create tmp directory for screenshots
    mkdir -p "${DEV_BROWSER_SKILL_DIR}/tmp"
    
    # Create convenience symlink
    ln -sf "${DEV_BROWSER_SKILL_DIR}/server.sh" "${DEV_BROWSER_DIR}/server.sh" 2>/dev/null || true
    
    print_success "Dev-browser installed at: ${DEV_BROWSER_DIR}"
    print_info "Start server with: $0 start"
    return 0
}

# Check if server is running
is_server_running() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    
    # Also check by process name
    if pgrep -f "dev-browser.*start-server" > /dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Start the server
start_server() {
    local headless="${1:-false}"
    
    if ! [[ -d "${DEV_BROWSER_SKILL_DIR}" ]]; then
        print_error "Dev-browser not installed. Run: $0 setup"
        return 1
    fi
    
    # Check if already running
    if is_server_running; then
        print_warning "Dev-browser server already running"
        print_info "Use '$0 restart' to restart"
        return 0
    fi
    
    print_info "Starting dev-browser server on port ${SERVER_PORT}..."
    cd "${DEV_BROWSER_SKILL_DIR}" || exit
    
    # Start server in background
    if [[ "${headless}" == "true" ]]; then
        nohup ./server.sh --headless > "${DEV_BROWSER_DIR}/server.log" 2>&1 &
    else
        nohup ./server.sh > "${DEV_BROWSER_DIR}/server.log" 2>&1 &
    fi
    
    local server_pid=$!
    echo "${server_pid}" > "${PID_FILE}"
    
    # Wait for server to be ready
    print_info "Waiting for server to be ready..."
    local max_wait=30
    local waited=0
    
    while ! curl -s "http://localhost:${SERVER_PORT}" > /dev/null 2>&1; do
        sleep 1
        ((waited++))
        if [[ ${waited} -ge ${max_wait} ]]; then
            print_error "Server failed to start within ${max_wait}s"
            print_info "Check logs: cat ${DEV_BROWSER_DIR}/server.log"
            return 1
        fi
        printf "."
    done
    echo ""
    
    print_success "Server ready on http://localhost:${SERVER_PORT}"
    print_info "Server PID: ${server_pid}"
    print_info "Logs: ${DEV_BROWSER_DIR}/server.log"
    return 0
}

# Stop the server
stop_server() {
    print_info "Stopping dev-browser server..."
    
    # Kill by PID file
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            print_info "Killed process ${pid}"
        fi
        rm -f "${PID_FILE}"
    fi
    
    # Also kill any remaining processes
    pkill -f "dev-browser.*start-server" 2>/dev/null || true
    pkill -f "chromium.*remote-debugging-port=${SERVER_PORT}" 2>/dev/null || true
    
    # Wait a moment for cleanup
    sleep 1
    
    if is_server_running; then
        print_warning "Some processes may still be running"
        return 1
    fi
    
    print_success "Server stopped"
    return 0
}

# Show status
show_status() {
    echo "=== Dev-Browser Status ==="
    echo ""
    
    # Installation
    if [[ -d "${DEV_BROWSER_SKILL_DIR}" ]]; then
        print_success "Installed: ${DEV_BROWSER_DIR}"
    else
        print_error "Not installed"
        print_info "Run: $0 setup"
        return 1
    fi
    
    # Bun
    if command -v bun &> /dev/null; then
        print_success "Bun: $(bun --version)"
    else
        print_error "Bun: not found"
    fi
    
    # Server
    if is_server_running; then
        print_success "Server: running"
        if [[ -f "${PID_FILE}" ]]; then
            print_info "  PID: $(cat "${PID_FILE}")"
        fi
    else
        print_warning "Server: not running"
    fi
    
    # Port
    if curl -s "http://localhost:${SERVER_PORT}" > /dev/null 2>&1; then
        print_success "Port ${SERVER_PORT}: responding"
    else
        print_warning "Port ${SERVER_PORT}: not responding"
    fi
    
    # Profile (persistent browser data)
    if [[ -d "${PROFILE_DIR}" ]]; then
        local profile_size
        profile_size=$(du -sh "${PROFILE_DIR}" 2>/dev/null | cut -f1)
        print_success "Profile: ${PROFILE_DIR} (${profile_size})"
        print_info "  Cookies, localStorage, extensions persist across restarts"
    else
        print_info "Profile: not yet created (will be created on first start)"
    fi
    
    # Logs
    if [[ -f "${DEV_BROWSER_DIR}/server.log" ]]; then
        print_info "Logs: ${DEV_BROWSER_DIR}/server.log"
    fi
    
    echo ""
    return 0
}

# Reset browser profile (clean start)
reset_profile() {
    if is_server_running; then
        print_error "Server is running. Stop it first with: $0 stop"
        return 1
    fi
    
    if [[ -d "${PROFILE_DIR}" ]]; then
        print_warning "This will delete all browser data including:"
        print_info "  - Cookies and login sessions"
        print_info "  - localStorage and sessionStorage"
        print_info "  - Browser cache"
        print_info "  - Extension data"
        echo ""
        read -p "Are you sure? (y/N): " confirm
        if [[ "${confirm}" =~ ^[Yy]$ ]]; then
            rm -rf "${PROFILE_DIR}"
            print_success "Profile reset. Next start will use a fresh browser."
        else
            print_info "Cancelled."
        fi
    else
        print_info "No profile exists yet."
    fi
    return 0
}

# Show profile info
show_profile() {
    echo "=== Browser Profile ==="
    echo ""
    print_info "Location: ${PROFILE_DIR}"
    echo ""
    
    if [[ -d "${PROFILE_DIR}" ]]; then
        local profile_size
        profile_size=$(du -sh "${PROFILE_DIR}" 2>/dev/null | cut -f1)
        print_success "Profile exists (${profile_size})"
        echo ""
        print_info "Contents:"
        (cd "${PROFILE_DIR}" && find . -maxdepth 1 -mindepth 1 -exec ls -ld {} +) 2>/dev/null | head -20
        echo ""
        print_info "This profile persists:"
        print_info "  - Cookies (stay logged into sites)"
        print_info "  - localStorage/sessionStorage"
        print_info "  - Browser cache"
        print_info "  - Extension data"
        echo ""
        print_info "To reset: $0 reset-profile"
    else
        print_warning "No profile yet. Will be created on first server start."
    fi
    
    echo ""
    return 0
}

# Run a test script
run_test() {
    if ! is_server_running; then
        print_error "Server not running. Start with: $0 start"
        return 1
    fi
    
    print_info "Running test script..."
    cd "${DEV_BROWSER_SKILL_DIR}" && bun x tsx <<'EOF' || exit
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("test");

await page.goto("https://example.com");
await waitForPageLoad(page);

console.log({
    title: await page.title(),
    url: page.url()
});

await page.screenshot({ path: "tmp/test.png" });
console.log("Screenshot saved to tmp/test.png");

await client.disconnect();
EOF
    
    local result=$?
    if [[ ${result} -eq 0 ]]; then
        print_success "Test passed!"
    else
        print_error "Test failed"
    fi
    return ${result}
}

# Show help
show_help() {
    cat << 'EOF'
Dev-Browser Helper - Stateful Browser Automation with Persistent Profile

USAGE:
    dev-browser-helper.sh [COMMAND] [OPTIONS]

COMMANDS:
    help            Show this help message
    setup           Install dev-browser and dependencies
    start           Start server (reuses existing browser profile)
    start-headless  Start server in headless mode
    start-clean     Start with a fresh browser profile (no cookies/data)
    stop            Stop the dev-browser server
    restart         Restart the server (keeps profile)
    status          Check installation, server, and profile status
    profile         Show browser profile details
    reset-profile   Delete browser profile for clean start
    test            Run a test script to verify setup
    update          Update dev-browser to latest version
    logs            Show server logs
    clean           Remove temporary files (keeps profile)

BROWSER PROFILE:
    The browser profile persists across restarts, preserving:
    - Cookies (stay logged into sites)
    - localStorage and sessionStorage
    - Browser cache
    - Extension data (if installed manually in the browser)

    Location: ~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/

EXAMPLES:
    dev-browser-helper.sh setup            # Install dev-browser
    dev-browser-helper.sh start            # Start (keeps logins)
    dev-browser-helper.sh start-clean      # Start fresh (no logins)
    dev-browser-helper.sh profile          # Show profile info
    dev-browser-helper.sh reset-profile    # Delete all browser data

USAGE WITH OPENCODE:
    1. Setup: dev-browser-helper.sh setup
    2. Start: dev-browser-helper.sh start
    3. Use @dev-browser subagent in OpenCode
    4. Browser stays logged in between sessions!

DOCUMENTATION:
    See: ~/.aidevops/agents/tools/browser/dev-browser.md
    GitHub: https://github.com/SawyerHood/dev-browser
EOF
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    
    case "${command}" in
        help|--help|-h)
            show_help
            ;;
        setup|install)
            install_dev_browser
            ;;
        start)
            start_server false
            ;;
        start-headless|headless)
            start_server true
            ;;
        start-clean)
            # Start with fresh profile
            if is_server_running; then
                print_error "Server is running. Stop it first with: $0 stop"
                return 1
            fi
            if [[ -d "${PROFILE_DIR}" ]]; then
                print_info "Removing existing browser profile for clean start..."
                rm -rf "${PROFILE_DIR}"
            fi
            start_server false
            ;;
        stop)
            stop_server
            ;;
        restart)
            stop_server
            sleep 2
            start_server false
            ;;
        status)
            show_status
            ;;
        profile)
            show_profile
            ;;
        reset-profile)
            reset_profile
            ;;
        test)
            run_test
            ;;
        update)
            install_dev_browser
            ;;
        logs)
            if [[ -f "${DEV_BROWSER_DIR}/server.log" ]]; then
                tail -f "${DEV_BROWSER_DIR}/server.log"
            else
                print_error "No log file found"
                return 1
            fi
            ;;
        clean)
            rm -rf "${DEV_BROWSER_SKILL_DIR}/tmp"/*
            print_success "Cleaned temporary files (profile preserved)"
            ;;
        *)
            print_error "Unknown command: ${command}"
            show_help
            return 1
            ;;
    esac
    
    return $?
}

main "$@"
