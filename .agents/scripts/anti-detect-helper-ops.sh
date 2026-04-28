#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Anti-Detect Helper -- Operations (Setup, Status, Proxy, Cookies)
# =============================================================================
# Tool setup (Camoufox, rebrowser-patches), installation status, proxy health
# checks, and cookie import/export operations.
#
# Usage: source "${SCRIPT_DIR}/anti-detect-helper-ops.sh"
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
[[ -n "${_ANTI_DETECT_OPS_LIB_LOADED:-}" ]] && return 0
_ANTI_DETECT_OPS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ─── Setup ───────────────────────────────────────────────────────────────────

setup_all() {
	local engine="${1:-all}"

	echo -e "${BLUE}Setting up anti-detect tools (engine: $engine)...${NC}"

	# Create directories
	mkdir -p "$PROFILES_DIR"/{persistent,clean/default,warmup,disposable}
	mkdir -p "$VENV_DIR"

	if [[ "$engine" == "all" || "$engine" == "firefox" ]]; then
		setup_camoufox
	fi

	if [[ "$engine" == "all" || "$engine" == "chromium" ]]; then
		setup_rebrowser
	fi

	# Create default clean profile template
	if [[ ! -f "$PROFILES_DIR/clean/default/fingerprint.json" ]]; then
		echo '{"mode": "random"}' >"$PROFILES_DIR/clean/default/fingerprint.json"
	fi

	# Create profiles index if not exists
	if [[ ! -f "$PROFILES_DIR/profiles.json" ]]; then
		echo '{"profiles": []}' >"$PROFILES_DIR/profiles.json"
	fi

	echo -e "${GREEN}Setup complete.${NC}"
	return 0
}

setup_camoufox() {
	echo -e "${BLUE}Setting up Camoufox (Firefox anti-detect)...${NC}"

	# Create/use venv
	if [[ ! -d "$VENV_DIR" ]]; then
		python3 -m venv "$VENV_DIR"
	fi

	# Install camoufox + browserforge
	# shellcheck source=/dev/null
	source "$VENV_DIR/bin/activate"
	pip install --quiet --upgrade camoufox browserforge 2>/dev/null || {
		echo -e "${YELLOW}Warning: pip install failed. Trying with --break-system-packages...${NC}"
		pip install --quiet --upgrade --break-system-packages camoufox browserforge 2>/dev/null || true
	}

	# Fetch browser binary
	python3 -m camoufox fetch 2>/dev/null || {
		echo -e "${YELLOW}Warning: Camoufox binary fetch failed. May need manual download.${NC}"
	}

	deactivate 2>/dev/null || true
	echo -e "${GREEN}Camoufox installed.${NC}"
	return 0
}

setup_rebrowser() {
	echo -e "${BLUE}Setting up rebrowser-patches (Chromium stealth)...${NC}"

	# Check if playwright is installed
	if ! command -v npx &>/dev/null; then
		echo -e "${RED}Error: npx not found. Install Node.js first.${NC}" >&2
		return 1
	fi

	# Patch playwright
	npx rebrowser-patches@latest patch 2>/dev/null || {
		echo -e "${YELLOW}Warning: rebrowser-patches failed. Playwright may not be installed.${NC}"
		echo -e "${YELLOW}Run: npm install playwright && npx rebrowser-patches patch${NC}"
	}

	echo -e "${GREEN}rebrowser-patches applied.${NC}"
	return 0
}

# ─── Status ──────────────────────────────────────────────────────────────────

show_status() {
	echo -e "${BLUE}Anti-Detect Browser Status:${NC}"
	echo "─────────────────────────────────────────"

	# Camoufox
	if [[ -d "$VENV_DIR" ]]; then
		local camoufox_version
		camoufox_version=$("$VENV_DIR/bin/python3" -c "from camoufox.__version__ import __version__; print(__version__)" 2>/dev/null || echo "unknown")
		echo -e "  Camoufox:          ${GREEN}installed${NC} (v$camoufox_version)"
	else
		echo -e "  Camoufox:          ${RED}not installed${NC}"
	fi

	# Mullvad Browser
	local mullvad_path=""
	if [[ -f "/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser" ]]; then
		mullvad_path="/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser"
	elif [[ -f "/usr/bin/mullvad-browser" ]]; then
		mullvad_path="/usr/bin/mullvad-browser"
	elif [[ -f "$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser" ]]; then
		mullvad_path="$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser"
	elif [[ -f "/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe" ]]; then
		mullvad_path="/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe"
	fi
	if [[ -n "$mullvad_path" ]]; then
		echo -e "  Mullvad Browser:   ${GREEN}installed${NC} ($mullvad_path)"
	else
		echo -e "  Mullvad Browser:   ${YELLOW}not installed${NC} (https://mullvad.net/browser)"
	fi

	# rebrowser-patches
	if npx rebrowser-patches@latest --version &>/dev/null 2>&1; then
		echo -e "  rebrowser-patches: ${GREEN}available${NC}"
	else
		echo -e "  rebrowser-patches: ${YELLOW}not patched${NC} (run: npx rebrowser-patches patch)"
	fi

	# Playwright
	if command -v npx &>/dev/null && npx playwright --version &>/dev/null 2>&1; then
		local pw_version
		pw_version=$(npx playwright --version 2>/dev/null || echo "unknown")
		echo -e "  Playwright:        ${GREEN}installed${NC} ($pw_version)"
	else
		echo -e "  Playwright:        ${RED}not installed${NC}"
	fi

	# Profiles
	local profile_count=0
	for dir in "$PROFILES_DIR"/{persistent,clean,warmup}/*/; do
		if [[ -d "$dir" ]] && [[ "$(basename "$dir")" != "default" ]]; then
			((++profile_count))
		fi
	done
	echo -e "  Profiles:          ${GREEN}$profile_count${NC} configured"

	# Profile directory
	echo -e "  Profile dir:       $PROFILES_DIR"
	echo -e "  Venv dir:          $VENV_DIR"

	return 0
}

# ─── Proxy Operations ────────────────────────────────────────────────────────

proxy_check() {
	local proxy_url="$1"

	echo -e "${BLUE}Checking proxy: $proxy_url${NC}"

	local result
	result=$(curl -s --proxy "$proxy_url" --max-time 15 "https://httpbin.org/ip" 2>/dev/null)

	if [[ $? -eq 0 && -n "$result" ]]; then
		local ip
		ip=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('origin','unknown'))" 2>/dev/null || echo "unknown")
		echo -e "  Status: ${GREEN}OK${NC}"
		echo "  IP: $ip"

		# Get geo info
		local geo
		geo=$(curl -s --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null)
		if [[ -n "$geo" ]]; then
			local country city isp
			country=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('country','?'))" 2>/dev/null || echo "?")
			city=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('city','?'))" 2>/dev/null || echo "?")
			isp=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('org','?'))" 2>/dev/null || echo "?")
			echo "  Location: $city, $country"
			echo "  ISP: $isp"
		fi
	else
		echo -e "  Status: ${RED}FAIL${NC} (connection timeout or refused)"
	fi
	return 0
}

proxy_check_all() {
	echo -e "${BLUE}Checking all profile proxies...${NC}"

	for type_dir in "$PROFILES_DIR"/{persistent,clean,warmup}/*/; do
		[[ -d "$type_dir" ]] || continue
		local name
		name=$(basename "$type_dir")
		[[ "$name" == "default" ]] && continue

		if [[ -f "$type_dir/proxy.json" ]]; then
			local server
			server=$(python3 -c "import json; print(json.load(open('$type_dir/proxy.json')).get('server',''))" 2>/dev/null)
			if [[ -n "$server" ]]; then
				echo -e "\n${YELLOW}Profile: $name${NC}"
				proxy_check "$server"
			fi
		fi
	done
	return 0
}

# ─── Cookie Operations ───────────────────────────────────────────────────────

cookies_export() {
	local profile_name="$1"
	shift
	local output=""
	local arg

	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--output)
			output="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local profile_dir
	profile_dir=$(find_profile_dir "$profile_name")

	if [[ -z "$profile_dir" || ! -f "$profile_dir/storage-state.json" ]]; then
		echo -e "${RED}Error: No saved state for profile '$profile_name'.${NC}" >&2
		return 1
	fi

	local out_file="${output:-/tmp/${profile_name}-cookies.txt}"

	python3 -c "
import json

with open('$profile_dir/storage-state.json') as f:
    state = json.load(f)

cookies = state.get('cookies', [])
lines = ['# Netscape HTTP Cookie File']

for c in cookies:
    domain = c.get('domain', '')
    flag = 'TRUE' if domain.startswith('.') else 'FALSE'
    path = c.get('path', '/')
    secure = 'TRUE' if c.get('secure', False) else 'FALSE'
    expires = str(int(c.get('expires', 0)))
    name = c.get('name', '')
    value = c.get('value', '')
    lines.append(f'{domain}\t{flag}\t{path}\t{secure}\t{expires}\t{name}\t{value}')

with open('$out_file', 'w') as f:
    f.write('\n'.join(lines))

print(f'Exported {len(cookies)} cookies to $out_file')
" 2>&1

	return 0
}

cookies_clear() {
	local profile_name="$1"
	local profile_dir
	profile_dir=$(find_profile_dir "$profile_name")

	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$profile_name' not found.${NC}" >&2
		return 1
	fi

	rm -f "$profile_dir/storage-state.json" "$profile_dir/cookies.json"
	rm -rf "$profile_dir/user-data"
	echo -e "${GREEN}Cookies cleared for '$profile_name'.${NC}"
	return 0
}
