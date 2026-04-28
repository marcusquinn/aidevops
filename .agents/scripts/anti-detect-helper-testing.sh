#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Anti-Detect Helper -- Detection Testing & Warmup
# =============================================================================
# Bot-detection testing against multiple sites (BrowserScan, SannySoft, etc.)
# and profile warmup with simulated browsing history.
#
# Usage: source "${SCRIPT_DIR}/anti-detect-helper-testing.sh"
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
[[ -n "${_ANTI_DETECT_TESTING_LIB_LOADED:-}" ]] && return 0
_ANTI_DETECT_TESTING_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ─── Testing ─────────────────────────────────────────────────────────────────

# Parse --profile, --engine, --sites flags; echo three lines: profile engine sites.
test_detection_parse_args() {
	local profile_name=""
	local engine="firefox"
	local sites="browserscan,sannysoft"
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
		--sites)
			sites="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	printf '%s\n%s\n%s\n' "$profile_name" "$engine" "$sites"
	return 0
}

# Resolve config/proxy paths for a profile used in detection testing.
# Args: profile_name
# Outputs two lines: config_arg proxy_arg (may be empty).
test_detection_load_profile() {
	local profile_name="$1"
	local config_arg=""
	local proxy_arg=""

	if [[ -n "$profile_name" ]]; then
		local profile_dir
		profile_dir=$(find_profile_dir "$profile_name")
		[[ -n "$profile_dir" && -f "$profile_dir/fingerprint.json" ]] && config_arg="$profile_dir/fingerprint.json"
		[[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]] && proxy_arg="$profile_dir/proxy.json"
	fi

	printf '%s\n%s\n' "$config_arg" "$proxy_arg"
	return 0
}

# Run Firefox (Camoufox) bot-detection tests against selected sites.
# Args: config_arg proxy_arg sites_csv
test_detection_run_firefox() {
	local config_arg="$1"
	local proxy_arg="$2"
	local sites="$3"

	python3 - <<PYEOF 2>&1
import json

test_sites = {
    'browserscan': 'https://www.browserscan.net/bot-detection',
    'sannysoft': 'https://bot.sannysoft.com',
    'incolumitas': 'https://bot.incolumitas.com',
    'pixelscan': 'https://pixelscan.net',
}

selected = '$sites'.split(',')
from camoufox.sync_api import Camoufox

profile_config, proxy = {}, None
config_file, proxy_file = '$config_arg', '$proxy_arg'
if config_file:
    with open(config_file) as f:
        profile_config = json.load(f)
if proxy_file:
    with open(proxy_file) as f:
        proxy = json.load(f)

kwargs = {'headless': True}
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

with Camoufox(**kwargs) as browser:
    page = browser.new_page()
    results = {}
    for site_key in selected:
        if site_key not in test_sites:
            continue
        url = test_sites[site_key]
        try:
            page.goto(url, timeout=30000)
            page.wait_for_timeout(5000)
            title = page.title()
            screenshot_path = f'/tmp/anti-detect-test-{site_key}.png'
            page.screenshot(path=screenshot_path)
            results[site_key] = {'status': 'OK', 'title': title, 'screenshot': screenshot_path}
            print(f'  {site_key}: PASS - {title}')
        except Exception as e:
            results[site_key] = {'status': 'FAIL', 'error': str(e)}
            print(f'  {site_key}: FAIL - {e}')
    print()
    print(f'Results: {len([r for r in results.values() if r["status"]=="OK"])}/{len(results)} passed')
    print(f'Screenshots saved to /tmp/anti-detect-test-*.png')
PYEOF
	return 0
}

test_detection() {
	local parse_lines
	parse_lines=$(test_detection_parse_args "$@")
	local profile_name engine sites
	profile_name=$(printf '%s' "$parse_lines" | sed -n '1p')
	engine=$(printf '%s' "$parse_lines" | sed -n '2p')
	sites=$(printf '%s' "$parse_lines" | sed -n '3p')

	echo -e "${BLUE}Testing bot detection (engine: $engine)...${NC}"

	# shellcheck source=/dev/null
	source "$VENV_DIR/bin/activate" 2>/dev/null || true

	if [[ "$engine" == "firefox" ]]; then
		local profile_lines config_arg proxy_arg
		profile_lines=$(test_detection_load_profile "$profile_name")
		config_arg=$(printf '%s' "$profile_lines" | sed -n '1p')
		proxy_arg=$(printf '%s' "$profile_lines" | sed -n '2p')
		test_detection_run_firefox "$config_arg" "$proxy_arg" "$sites"
	else
		echo 'Chromium testing requires Node.js - use: anti-detect-helper.sh launch --engine chromium --url <test-url>'
	fi

	deactivate 2>/dev/null || true
	return 0
}

# ─── Warmup ──────────────────────────────────────────────────────────────────

# Parse --duration flag from remaining args; echoes numeric minutes (default 30).
warmup_parse_duration() {
	local duration="30"
	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--duration)
			duration="${2%m}" # Strip optional 'm' suffix
			shift 2
			;;
		*) shift ;;
		esac
	done
	echo "$duration"
	return 0
}

# Validate profile exists, activate venv, and resolve config/proxy paths.
# Outputs two lines: config_arg and proxy_arg (may be empty).
# Returns 1 on error (profile not found or venv missing).
warmup_build_config() {
	local profile_name="$1"
	local profile_dir
	profile_dir=$(find_profile_dir "$profile_name")

	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$profile_name' not found.${NC}" >&2
		return 1
	fi

	# shellcheck source=/dev/null
	source "$VENV_DIR/bin/activate" 2>/dev/null || {
		echo -e "${RED}Error: Camoufox venv not found. Run: anti-detect-helper.sh setup${NC}" >&2
		return 1
	}

	local config_arg=""
	local proxy_arg=""
	[[ -f "$profile_dir/fingerprint.json" ]] && config_arg="$profile_dir/fingerprint.json"
	[[ -f "$profile_dir/proxy.json" ]] && proxy_arg="$profile_dir/proxy.json"

	# Output as two lines so the caller can read them back
	printf '%s\n%s\n' "$config_arg" "$proxy_arg"
	return 0
}

# Write the Python warmup script to a temp file and return its path.
# Args: profile_dir config_arg proxy_arg duration_minutes
# Echoes the temp file path; caller must remove it after use.
warmup_write_script() {
	local profile_dir="$1"
	local config_arg="$2"
	local proxy_arg="$3"
	local duration="$4"

	local tmp_script
	# t2997: drop .py — XXXXXX must be at end for BSD mktemp; python doesn't
	# need a .py extension to execute a script.
	tmp_script=$(mktemp /tmp/warmup-XXXXXX)

	cat >"$tmp_script" <<PYEOF
import json, asyncio, random, time

WARMUP_SITES = [
    'https://www.google.com', 'https://www.youtube.com',
    'https://www.wikipedia.org', 'https://www.reddit.com',
    'https://www.amazon.com', 'https://news.ycombinator.com',
    'https://www.github.com', 'https://stackoverflow.com',
    'https://www.bbc.com', 'https://www.nytimes.com',
]

async def warmup():
    from camoufox.async_api import AsyncCamoufox
    profile_config, proxy = {}, None
    config_file, proxy_file = '${config_arg}', '${proxy_arg}'
    if config_file:
        with open(config_file) as f: profile_config = json.load(f)
    if proxy_file:
        with open(proxy_file) as f: proxy = json.load(f)
    kwargs = {'headless': True, 'humanize': True}
    os_list = profile_config.get('os')
    if os_list: kwargs['os'] = os_list
    screen_config = profile_config.get('screen')
    if screen_config:
        from browserforge.fingerprints import Screen
        kwargs['screen'] = Screen(
            max_width=screen_config.get('maxWidth', 1920),
            max_height=screen_config.get('maxHeight', 1080))
    if proxy:
        kwargs['proxy'] = proxy
        kwargs['geoip'] = True
    duration_seconds = ${duration} * 60
    start_time, sites_visited = time.time(), 0
    async with AsyncCamoufox(**kwargs) as browser:
        page = await browser.new_page()
        while (time.time() - start_time) < duration_seconds:
            url = random.choice(WARMUP_SITES)
            try:
                await page.goto(url, timeout=15000)
                sites_visited += 1
                elapsed = int(time.time() - start_time)
                print(f'  [{elapsed}s] Visited: {url}')
                await asyncio.sleep(random.uniform(3, 12))
                await page.evaluate('window.scrollBy(0, window.innerHeight * Math.random())')
                await asyncio.sleep(random.uniform(1, 4))
                if random.random() > 0.6:
                    links = await page.query_selector_all('a[href^="http"]')
                    if links and len(links) > 2:
                        link = random.choice(links[:8])
                        try:
                            await link.click(timeout=5000)
                            await asyncio.sleep(random.uniform(2, 6))
                            await page.go_back(timeout=5000)
                        except Exception: pass
            except Exception: pass
            await asyncio.sleep(random.uniform(2, 8))
        context = browser.contexts[0]
        cookies = context.cookies()
        state = {'cookies': cookies, 'origins': []}
        with open('${profile_dir}/storage-state.json', 'w') as f:
            json.dump(state, f, indent=2)
        print(f'\nWarmup complete: {sites_visited} sites visited, {len(cookies)} cookies saved.')

asyncio.run(warmup())
PYEOF

	echo "$tmp_script"
	return 0
}

# Execute the async Camoufox warmup browsing session.
# Args: profile_dir config_arg proxy_arg duration_minutes
warmup_run_browser() {
	local profile_dir="$1"
	local config_arg="$2"
	local proxy_arg="$3"
	local duration="$4"

	local tmp_script
	tmp_script=$(warmup_write_script "$profile_dir" "$config_arg" "$proxy_arg" "$duration")
	python3 "$tmp_script" 2>&1
	local exit_code=$?
	rm -f "$tmp_script"
	return $exit_code
}

warmup_profile() {
	local profile_name="$1"
	shift

	local duration
	duration=$(warmup_parse_duration "$@")

	local profile_dir
	profile_dir=$(find_profile_dir "$profile_name")
	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$profile_name' not found.${NC}" >&2
		return 1
	fi

	echo -e "${BLUE}Warming up profile '$profile_name' for ${duration}m...${NC}"

	local config_lines
	config_lines=$(warmup_build_config "$profile_name") || return 1
	local config_arg proxy_arg
	config_arg=$(echo "$config_lines" | sed -n '1p')
	proxy_arg=$(echo "$config_lines" | sed -n '2p')

	warmup_run_browser "$profile_dir" "$config_arg" "$proxy_arg" "$duration"

	deactivate 2>/dev/null || true
	echo -e "${GREEN}Warmup complete for '$profile_name'.${NC}"
	return 0
}
