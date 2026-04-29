#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Anti-Detect Helper -- Browser Launch
# =============================================================================
# Browser launch functions: Camoufox (Firefox), Mullvad, Chromium (stealth).
# Handles engine selection, profile loading, and headless/headed modes.
#
# Usage: source "${SCRIPT_DIR}/anti-detect-helper-launch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - anti-detect-helper-profiles.sh (find_profile_dir)
#   - PROFILES_DIR, VENV_DIR must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ANTI_DETECT_LAUNCH_LIB_LOADED:-}" ]] && return 0
_ANTI_DETECT_LAUNCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ─── Launch ──────────────────────────────────────────────────────────────────

launch_browser() {
	local profile_name=""
	local engine="firefox"
	local headless=""
	local disposable=""
	local url=""

	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--profile)
			profile_name="$2"
			shift 2
			;;
		--engine)
			engine="$2"
			shift 2
			;;
		--headless)
			headless="true"
			shift
			;;
		--disposable)
			disposable="true"
			shift
			;;
		--url)
			url="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$profile_name" && -z "$disposable" ]]; then
		echo -e "${RED}Error: --profile <name> or --disposable required.${NC}" >&2
		return 1
	fi

	if [[ "$engine" == "random" ]]; then
		engine=$(python3 -c "import random; print(random.choice(['chromium','firefox','mullvad']))")
	fi

	# Update last_used timestamp
	if [[ -n "$profile_name" ]]; then
		local profile_dir
		profile_dir=$(find_profile_dir "$profile_name")
		if [[ -n "$profile_dir" && -f "$profile_dir/metadata.json" ]]; then
			python3 -c "
import json
with open('$profile_dir/metadata.json', 'r+') as f:
    d = json.load(f)
    d['last_used'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
		fi
	fi

	if [[ "$engine" == "firefox" ]]; then
		launch_camoufox "$profile_name" "$headless" "$url" "$disposable"
	elif [[ "$engine" == "mullvad" ]]; then
		launch_mullvad "$profile_name" "$headless" "$url" "$disposable"
	else
		launch_chromium_stealth "$profile_name" "$headless" "$url" "$disposable"
	fi
	return $?
}

# Resolve fingerprint and proxy file paths for a named profile.
# Args: profile_name
# Outputs two lines: config_arg (fingerprint path) and proxy_arg (proxy path).
# Both may be empty strings if files are absent.
camoufox_load_profile_config() {
	local profile_name="$1"
	local profile_dir=""
	local config_arg=""
	local proxy_arg=""

	if [[ -n "$profile_name" ]]; then
		profile_dir=$(find_profile_dir "$profile_name")
		[[ -n "$profile_dir" && -f "$profile_dir/fingerprint.json" ]] && config_arg="$profile_dir/fingerprint.json"
		[[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]] && proxy_arg="$profile_dir/proxy.json"
	fi

	printf '%s\n%s\n%s\n' "$profile_dir" "$config_arg" "$proxy_arg"
	return 0
}

# Execute the Camoufox browser session with resolved profile paths.
# Args: profile_dir config_arg proxy_arg headless_flag target_url disposable
# Runs the Python session inline; caller must activate venv first.
launch_camoufox_run() {
	local profile_dir="$1"
	local config_arg="$2"
	local proxy_arg="$3"
	local headless_flag="$4"
	local target_url="$5"
	local disposable="$6"

	CAMOUFOX_PROFILE_DIR="$profile_dir" \
	CAMOUFOX_CONFIG_FILE="$config_arg" \
	CAMOUFOX_PROXY_FILE="$proxy_arg" \
	CAMOUFOX_HEADLESS="$headless_flag" \
	CAMOUFOX_TARGET_URL="$target_url" \
	CAMOUFOX_DISPOSABLE="$disposable" \
	python3 - <<'PYEOF' 2>&1
import json, os, os.path
from camoufox.sync_api import Camoufox

profile_config, proxy = {}, None
headless = os.environ.get('CAMOUFOX_HEADLESS', 'False') == 'True'
config_file = os.environ.get('CAMOUFOX_CONFIG_FILE', '')
proxy_file = os.environ.get('CAMOUFOX_PROXY_FILE', '')
target_url = os.environ.get('CAMOUFOX_TARGET_URL', 'https://www.browserscan.net/bot-detection')
profile_dir = os.environ.get('CAMOUFOX_PROFILE_DIR', '')
disposable = os.environ.get('CAMOUFOX_DISPOSABLE', '') == 'true'

if config_file:
    with open(config_file) as f:
        profile_config = json.load(f)
if proxy_file:
    with open(proxy_file) as f:
        proxy = json.load(f)

kwargs = {'headless': headless}
os_list = profile_config.get('os')
if os_list:
    kwargs['os'] = os_list
screen_config = profile_config.get('screen')
if screen_config:
    from browserforge.fingerprints import Screen
    kwargs['screen'] = Screen(
        max_width=screen_config.get('maxWidth', 1920),
        max_height=screen_config.get('maxHeight', 1080),
    )
if proxy:
    kwargs['proxy'] = proxy
    kwargs['geoip'] = True

print(f'Launching Camoufox (headless={headless})...')
with Camoufox(**kwargs) as browser:
    page = browser.new_page()
    page.goto(target_url, timeout=30000)
    print(f'Navigated to: {page.url}')
    print(f'Title: {page.title()}')
    if profile_dir and not disposable:
        profile_type = os.path.basename(os.path.dirname(profile_dir))
        if profile_type in ('persistent', 'warmup'):
            context = browser.contexts[0]
            cookies = context.cookies()
            state = {'cookies': cookies, 'origins': []}
            with open(f'{profile_dir}/storage-state.json', 'w') as f:
                json.dump(state, f, indent=2)
            print(f'State saved ({len(cookies)} cookies)')
        else:
            print('Clean profile - state not saved')
    if not headless:
        input('Press Enter to close browser...')
PYEOF
	return 0
}

launch_camoufox() {
	local profile_name="$1"
	local headless="$2"
	local url="$3"
	local disposable="$4"

	# shellcheck source=/dev/null
	source "$VENV_DIR/bin/activate" 2>/dev/null || {
		echo -e "${RED}Error: Camoufox venv not found. Run: anti-detect-helper.sh setup${NC}" >&2
		return 1
	}

	local profile_dir config_arg proxy_arg
	{
		read -r profile_dir
		read -r config_arg
		read -r proxy_arg
	} <<< "$(camoufox_load_profile_config "$profile_name")"

	local headless_flag="True"
	[[ "$headless" != "true" ]] && headless_flag="False"

	local target_url="${url:-https://www.browserscan.net/bot-detection}"

	launch_camoufox_run "$profile_dir" "$config_arg" "$proxy_arg" "$headless_flag" "$target_url" "$disposable"

	deactivate 2>/dev/null || true
	return 0
}

launch_mullvad() {
	local profile_name="$1"
	local headless="$2"
	local url="$3"
	local disposable="$4"

	# Find Mullvad Browser executable
	local mullvad_path=""
	if [[ -f "/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser" ]]; then
		mullvad_path="/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser"
	elif [[ -f "/usr/bin/mullvad-browser" ]]; then
		mullvad_path="/usr/bin/mullvad-browser"
	elif [[ -f "$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser" ]]; then
		mullvad_path="$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser"
	elif [[ -f "/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe" ]]; then
		mullvad_path="/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe"
	else
		echo -e "${RED}Error: Mullvad Browser not found. Install from https://mullvad.net/browser${NC}" >&2
		return 1
	fi

	local profile_dir=""
	local user_data_dir=""
	local proxy_server=""

	if [[ -n "$profile_name" ]]; then
		profile_dir=$(find_profile_dir "$profile_name")
		if [[ -n "$profile_dir" ]]; then
			user_data_dir="$profile_dir/mullvad-data"
			mkdir -p "$user_data_dir"
		fi
		if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
			proxy_server=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('server',''))" 2>/dev/null)
		fi
	fi

	local headless_flag="true"
	[[ "$headless" != "true" ]] && headless_flag="false"

	local target_url="${url:-https://www.browserscan.net/bot-detection}"

	echo -e "${BLUE}Launching Mullvad Browser (headless=$headless_flag)...${NC}"
	echo -e "${YELLOW}Note: Mullvad Browser uses Tor Browser's uniform fingerprint (no rotation).${NC}"
	echo -e "${YELLOW}For fingerprint rotation, use --engine firefox (Camoufox) instead.${NC}"

	# Use Node.js with Playwright Firefox driver; env vars prevent shell injection
	BROWSER_PATH="$mullvad_path" BROWSER_HEADLESS="$headless_flag" \
	BROWSER_URL="$target_url" BROWSER_PROXY="$proxy_server" \
	BROWSER_DATA="$user_data_dir" BROWSER_DISP="$disposable" \
	node - 2>&1 <<'NODEOF'
const { firefox } = require('playwright');
(async () => {
    const execPath = process.env.BROWSER_PATH;
    const headless = process.env.BROWSER_HEADLESS === 'true';
    const launchOpts = { executablePath: execPath, headless: headless };
    const contextOpts = { viewport: { width: 1280, height: 800 } };
    const proxyServer = process.env.BROWSER_PROXY || '';
    if (proxyServer) { launchOpts.proxy = { server: proxyServer }; }
    const userDataDir = process.env.BROWSER_DATA || '';
    const disposable = process.env.BROWSER_DISP === 'true';
    let browser, context, page;
    if (userDataDir && !disposable) {
        browser = await firefox.launchPersistentContext(userDataDir, {
            ...launchOpts, ...contextOpts,
        });
        page = browser.pages()[0] || await browser.newPage();
    } else {
        browser = await firefox.launch(launchOpts);
        context = await browser.newContext(contextOpts);
        page = await context.newPage();
    }
    console.log('Mullvad Browser launched');
    await page.goto(process.env.BROWSER_URL, { timeout: 30000 });
    console.log('Navigated to:', page.url());
    console.log('Title:', await page.title());
    if (!headless) { await new Promise(r => setTimeout(r, 60000)); }
    await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
NODEOF

	return 0
}

launch_chromium_stealth() {
	local profile_name="$1"
	local headless="$2"
	local url="$3"
	local disposable="$4"

	local profile_dir=""
	local user_data_dir=""
	local proxy_server=""

	if [[ -n "$profile_name" ]]; then
		profile_dir=$(find_profile_dir "$profile_name")
		if [[ -n "$profile_dir" ]]; then
			user_data_dir="$profile_dir/user-data"
			mkdir -p "$user_data_dir"
		fi
		if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
			proxy_server=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('server',''))" 2>/dev/null)
			local proxy_username
			proxy_username=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('username',''))" 2>/dev/null)
			local proxy_password
			proxy_password=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('password',''))" 2>/dev/null)
		fi
	fi

	local headless_flag="true"
	[[ "$headless" != "true" ]] && headless_flag="false"

	local target_url="${url:-https://www.browserscan.net/bot-detection}"

	# Use Node.js with patched Playwright; env vars prevent shell injection
	BROWSER_HEADLESS="$headless_flag" BROWSER_URL="$target_url" \
	BROWSER_PROXY="$proxy_server" BROWSER_PROXY_USER="${proxy_username:-}" \
	BROWSER_PROXY_PASS="${proxy_password:-}" BROWSER_DATA="$user_data_dir" \
	BROWSER_DISP="$disposable" \
	node - 2>&1 <<'NODEOF'
const { chromium } = require('playwright');
(async () => {
    const headless = process.env.BROWSER_HEADLESS === 'true';
    const launchOpts = {
        headless: headless,
        args: [
            '--disable-blink-features=AutomationControlled',
            '--no-first-run',
            '--no-default-browser-check',
        ],
    };
    const contextOpts = {
        viewport: { width: 1920, height: 1080 },
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    };
    const proxyServer = process.env.BROWSER_PROXY || '';
    const proxyUsername = process.env.BROWSER_PROXY_USER || '';
    const proxyPassword = process.env.BROWSER_PROXY_PASS || '';
    if (proxyServer) {
        const proxyConfig = { server: proxyServer };
        if (proxyUsername) proxyConfig.username = proxyUsername;
        if (proxyPassword) proxyConfig.password = proxyPassword;
        launchOpts.proxy = proxyConfig;
    }
    const userDataDir = process.env.BROWSER_DATA || '';
    const disposable = process.env.BROWSER_DISP === 'true';
    let browser, page;
    if (userDataDir && !disposable) {
        browser = await chromium.launchPersistentContext(userDataDir, {
            ...launchOpts, ...contextOpts,
        });
        page = browser.pages()[0] || await browser.newPage();
    } else {
        browser = await chromium.launch(launchOpts);
        const context = await browser.newContext(contextOpts);
        page = await context.newPage();
    }
    console.log('Launching Chromium (stealth patched)...');
    await page.goto(process.env.BROWSER_URL, { timeout: 30000 });
    console.log('Navigated to:', page.url());
    console.log('Title:', await page.title());
    if (!headless) { await new Promise(r => setTimeout(r, 60000)); }
    await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
NODEOF

	return 0
}
