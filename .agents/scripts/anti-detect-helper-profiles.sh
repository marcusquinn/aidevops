#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Anti-Detect Helper -- Profile Management
# =============================================================================
# Profile CRUD operations: create, list, show, delete, clone, update.
# Also includes utility functions used by profiles: validate_profile_name,
# find_profile_dir, generate_fingerprint, parse_proxy_url, update_profiles_index.
#
# Usage: source "${SCRIPT_DIR}/anti-detect-helper-profiles.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - PROFILES_DIR must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ANTI_DETECT_PROFILES_LIB_LOADED:-}" ]] && return 0
_ANTI_DETECT_PROFILES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ─── Utility Functions ───────────────────────────────────────────────────────

find_profile_dir() {
	local name="$1"
	for type in persistent clean warmup disposable; do
		local dir="$PROFILES_DIR/$type/$name"
		if [[ -d "$dir" ]]; then
			echo "$dir"
			return 0
		fi
	done
	echo ""
	return 1
}

generate_fingerprint() {
	local target_os="${1:-random}"
	local browser_type="${2:-firefox}"

	# Generate fingerprint metadata (Camoufox handles actual fingerprint via BrowserForge)
	# We store OS/screen constraints that Camoufox uses to generate consistent fingerprints
	python3 -c "
import json
import random

# Camoufox uses screen constraints, not direct property injection
# BrowserForge generates the actual fingerprint at runtime
screens = {
    'windows': [(1920, 1080), (2560, 1440), (1366, 768), (1536, 864)],
    'macos': [(1920, 1080), (2560, 1440), (1440, 900), (1680, 1050)],
    'linux': [(1920, 1080), (2560, 1440), (1366, 768)],
    'random': [(1920, 1080), (2560, 1440), (1366, 768), (1536, 864), (1440, 900)],
}

os_list = screens.get('$target_os', screens['random'])
screen = random.choice(os_list)

config = {
    'target_os': '$target_os',
    'target_browser': '$browser_type',
    'screen': {'maxWidth': screen[0], 'maxHeight': screen[1]},
}

# Store OS hint for Camoufox's BrowserForge integration
if '$target_os' == 'windows':
    config['os'] = ['windows']
elif '$target_os' == 'macos':
    config['os'] = ['macos']
elif '$target_os' == 'linux':
    config['os'] = ['linux']
else:
    config['os'] = ['windows', 'macos', 'linux']

print(json.dumps(config, indent=2))
" 2>/dev/null || echo '{"mode": "random"}'
}

parse_proxy_url() {
	local url="$1"
	python3 -c "
import json
from urllib.parse import urlparse

url = '$url'
parsed = urlparse(url)

result = {
    'server': f'{parsed.scheme}://{parsed.hostname}:{parsed.port}',
}

if parsed.username:
    result['username'] = parsed.username
if parsed.password:
    result['password'] = parsed.password

print(json.dumps(result, indent=2))
" 2>/dev/null || echo "{\"server\": \"$url\"}"
}

update_profiles_index() {
	local name="$1"
	local profile_type="$2"
	local action="$3"

	python3 -c "
import json
from pathlib import Path

index_file = Path('$PROFILES_DIR/profiles.json')
if index_file.exists():
    data = json.loads(index_file.read_text())
else:
    data = {'profiles': []}

if '$action' == 'add':
    # Remove existing entry if any
    data['profiles'] = [p for p in data['profiles'] if p.get('name') != '$name']
    data['profiles'].append({'name': '$name', 'type': '$profile_type'})
elif '$action' == 'remove':
    data['profiles'] = [p for p in data['profiles'] if p.get('name') != '$name']

index_file.write_text(json.dumps(data, indent=2))
" 2>/dev/null || true
}

# ─── Profile Management ─────────────────────────────────────────────────────

validate_profile_name() {
	local name="$1"
	if [[ -z "$name" ]]; then
		echo -e "${RED}Error: Profile name cannot be empty.${NC}" >&2
		return 1
	fi
	if [[ "$name" =~ [/\\] || "$name" == *..* ]]; then
		echo -e "${RED}Error: Profile name cannot contain '/', '\\', or '..'.${NC}" >&2
		return 1
	fi
	if [[ "$name" == -* ]]; then
		echo -e "${RED}Error: Profile name cannot start with '-'.${NC}" >&2
		return 1
	fi
	if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo -e "${RED}Error: Profile name must only contain letters, numbers, '.', '_', or '-'.${NC}" >&2
		return 1
	fi
	if [[ ${#name} -gt 64 ]]; then
		echo -e "${RED}Error: Profile name must be 64 characters or fewer.${NC}" >&2
		return 1
	fi
	return 0
}

profile_create() {
	local name="$1"
	local profile_type="persistent"
	local proxy=""
	local target_os="random"
	local browser_type="firefox"
	local notes=""

	local arg
	shift
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--type)
			profile_type="$2"
			shift 2
			;;
		--proxy)
			proxy="$2"
			shift 2
			;;
		--os)
			target_os="$2"
			shift 2
			;;
		--browser)
			browser_type="$2"
			shift 2
			;;
		--notes)
			notes="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	validate_profile_name "$name" || return 1

	# Map profile type to directory name
	local dir_type="$profile_type"
	[[ "$profile_type" == "warm" ]] && dir_type="warmup"

	local profile_dir="$PROFILES_DIR/$dir_type/$name"

	if [[ -d "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$name' already exists.${NC}" >&2
		return 1
	fi

	mkdir -p "$profile_dir"

	# Generate fingerprint
	local fingerprint
	fingerprint=$(generate_fingerprint "$target_os" "$browser_type")
	echo "$fingerprint" >"$profile_dir/fingerprint.json"

	# Save proxy config
	if [[ -n "$proxy" ]]; then
		local proxy_json
		proxy_json=$(parse_proxy_url "$proxy")
		echo "$proxy_json" >"$profile_dir/proxy.json"
	fi

	# Save metadata using jq to prevent injection via user-supplied variables
	jq -n \
		--arg name "$name" --arg type "$profile_type" \
		--arg browser "$browser_type" --arg os "$target_os" \
		--arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg notes "$notes" \
		'{name:$name,type:$type,browser:$browser,target_os:$os,created:$created,last_used:null,notes:$notes}' \
		>"$profile_dir/metadata.json"

	# Update profiles index
	update_profiles_index "$name" "$profile_type" "add"

	echo -e "${GREEN}Profile '$name' created (type: $profile_type, os: $target_os, browser: $browser_type).${NC}"
	return 0
}

profile_list() {
	local format="${1:-text}"

	if [[ "$format" == "json" ]]; then
		cat "$PROFILES_DIR/profiles.json"
		return 0
	fi

	echo -e "${BLUE}Browser Profiles:${NC}"
	echo "─────────────────────────────────────────────────────────────"
	printf "%-20s %-12s %-10s %-10s %s\n" "NAME" "TYPE" "OS" "ENGINE" "PROXY"
	echo "─────────────────────────────────────────────────────────────"

	for type_dir in "$PROFILES_DIR"/{persistent,clean,warmup,disposable}/*/; do
		[[ -d "$type_dir" ]] || continue
		local name
		name=$(basename "$type_dir")
		[[ "$name" == "default" ]] && continue

		local metadata="$type_dir/metadata.json"
		[[ -f "$metadata" ]] || continue

		local ptype pos pengine pproxy
		ptype=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('type','?'))" 2>/dev/null || echo "?")
		pos=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('target_os','?'))" 2>/dev/null || echo "?")
		pengine=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('browser','?'))" 2>/dev/null || echo "?")

		if [[ -f "$type_dir/proxy.json" ]]; then
			pproxy="yes"
		else
			pproxy="none"
		fi

		printf "%-20s %-12s %-10s %-10s %s\n" "$name" "$ptype" "$pos" "$pengine" "$pproxy"
	done
	return 0
}

profile_show() {
	local name="$1"
	local profile_dir
	profile_dir=$(find_profile_dir "$name")

	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
		return 1
	fi

	echo -e "${BLUE}Profile: $name${NC}"
	echo "─────────────────────────────────────────"

	if [[ -f "$profile_dir/metadata.json" ]]; then
		echo -e "${YELLOW}Metadata:${NC}"
		python3 -c "import json; d=json.load(open('$profile_dir/metadata.json')); [print(f'  {k}: {v}') for k,v in d.items()]" 2>/dev/null
	fi

	if [[ -f "$profile_dir/fingerprint.json" ]]; then
		echo -e "${YELLOW}Fingerprint:${NC}"
		python3 -c "import json; d=json.load(open('$profile_dir/fingerprint.json')); [print(f'  {k}: {v}') for k,v in list(d.items())[:10]]" 2>/dev/null
	fi

	if [[ -f "$profile_dir/proxy.json" ]]; then
		echo -e "${YELLOW}Proxy:${NC}"
		python3 -c "import json; d=json.load(open('$profile_dir/proxy.json')); print(f'  server: {d.get(\"server\",\"?\")}')" 2>/dev/null
	fi

	if [[ -f "$profile_dir/storage-state.json" ]]; then
		local cookie_count
		cookie_count=$(python3 -c "import json; d=json.load(open('$profile_dir/storage-state.json')); print(len(d.get('cookies',[])))" 2>/dev/null || echo "0")
		echo -e "${YELLOW}State:${NC}"
		echo "  cookies: $cookie_count saved"
	fi

	return 0
}

profile_delete() {
	local name="$1"
	validate_profile_name "$name" || return 1
	local profile_dir
	profile_dir=$(find_profile_dir "$name")

	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
		return 1
	fi

	rm -rf "$profile_dir"
	update_profiles_index "$name" "" "remove"
	echo -e "${GREEN}Profile '$name' deleted.${NC}"
	return 0
}

profile_clone() {
	local src="$1"
	local dst="$2"
	local src_dir
	src_dir=$(find_profile_dir "$src")

	if [[ -z "$src_dir" ]]; then
		echo -e "${RED}Error: Source profile '$src' not found.${NC}" >&2
		return 1
	fi

	local parent_dir
	parent_dir=$(dirname "$src_dir")
	local dst_dir="$parent_dir/$dst"

	if [[ -d "$dst_dir" ]]; then
		echo -e "${RED}Error: Destination profile '$dst' already exists.${NC}" >&2
		return 1
	fi

	cp -r "$src_dir" "$dst_dir"

	# Update metadata name
	if [[ -f "$dst_dir/metadata.json" ]]; then
		python3 -c "
import json
with open('$dst_dir/metadata.json', 'r+') as f:
    d = json.load(f)
    d['name'] = '$dst'
    d['created'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
	fi

	# Generate new fingerprint (don't share with source)
	local target_os
	target_os=$(python3 -c "import json; print(json.load(open('$dst_dir/metadata.json')).get('target_os','random'))" 2>/dev/null || echo "random")
	local browser_type
	browser_type=$(python3 -c "import json; print(json.load(open('$dst_dir/metadata.json')).get('browser','firefox'))" 2>/dev/null || echo "firefox")
	generate_fingerprint "$target_os" "$browser_type" >"$dst_dir/fingerprint.json"

	# Remove saved state (fresh start)
	rm -f "$dst_dir/storage-state.json" "$dst_dir/cookies.json"
	rm -rf "$dst_dir/user-data"

	update_profiles_index "$dst" "persistent" "add"
	echo -e "${GREEN}Profile '$src' cloned to '$dst' (new fingerprint, no saved state).${NC}"
	return 0
}

profile_update() {
	local name="$1"
	shift
	local profile_dir
	profile_dir=$(find_profile_dir "$name")

	if [[ -z "$profile_dir" ]]; then
		echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
		return 1
	fi

	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--proxy)
			local proxy_json
			proxy_json=$(parse_proxy_url "$2")
			echo "$proxy_json" >"$profile_dir/proxy.json"
			echo -e "${GREEN}Proxy updated for '$name'.${NC}"
			shift 2
			;;
		--notes)
			PROFILE_NOTES="$2" PROFILE_META="$profile_dir/metadata.json" python3 -c "
import json, os
meta_path = os.environ['PROFILE_META']
notes_val = os.environ['PROFILE_NOTES']
with open(meta_path, 'r+') as f:
    d = json.load(f)
    d['notes'] = notes_val
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
			echo -e "${GREEN}Notes updated for '$name'.${NC}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}
