#!/usr/bin/env bash
# cch-extract.sh — Extract CCH signing constants from installed Claude CLI
#
# Extracts the salt, version, char indices, and billing header template
# from the locally installed Claude Code CLI (Node.js or Bun binary).
# Output is a JSON object suitable for cch-sign.py consumption.
#
# Usage:
#   cch-extract.sh                    # Extract and print JSON to stdout
#   cch-extract.sh --cache            # Extract and cache to ~/.aidevops/cch-constants.json
#   cch-extract.sh --verify           # Extract and verify against cached version
#   cch-extract.sh --version          # Print detected Claude CLI version only
#
# The extracted constants change with each Claude CLI release.
# Run after every `claude` update to keep signing in sync.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CACHE_FILE="${HOME}/.aidevops/cch-constants.json"
CLAUDE_BIN=""         # Path to the file used for extraction (may be a strings temp file)
CLAUDE_BIN_REAL=""    # Real path to the claude binary (recorded in JSON output)
CLAUDE_BIN_TMPFILE="" # Set when a Bun binary is strings-extracted to a temp file

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

print_info() {
	printf '\033[0;34m[INFO]\033[0m %s\n' "$1" >&2
	return 0
}
print_success() {
	printf '\033[0;32m[OK]\033[0m %s\n' "$1" >&2
	return 0
}
print_error() {
	printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2
	return 0
}

# Clean up any temp files created during extraction
cleanup_tmpfiles() {
	if [[ -n "$CLAUDE_BIN_TMPFILE" && -f "$CLAUDE_BIN_TMPFILE" ]]; then
		rm -f "$CLAUDE_BIN_TMPFILE"
	fi
	return 0
}
trap cleanup_tmpfiles EXIT

# Locate the Claude CLI source file (follows symlinks for npm global installs)
find_claude_source() {
	local bin_path
	bin_path=$(command -v claude 2>/dev/null || true)
	if [[ -z "$bin_path" ]]; then
		print_error "Claude CLI not found in PATH"
		return 1
	fi

	# Resolve symlinks (npm global install symlinks to lib/node_modules/...)
	local resolved
	resolved=$(readlink -f "$bin_path" 2>/dev/null || python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$bin_path" 2>/dev/null || true)
	if [[ -z "$resolved" ]]; then
		resolved="$bin_path"
	fi

	# Check if it's a JS file (Node.js) or binary (Bun)
	local file_type
	file_type=$(file "$resolved" 2>/dev/null || true)

	if [[ "$file_type" == *"script"* || "$file_type" == *"text"* ]]; then
		# Node.js script — the source IS the CLI file
		CLAUDE_BIN="$resolved"
		CLAUDE_BIN_REAL="$resolved"
	elif [[ "$file_type" == *"Mach-O"* || "$file_type" == *"ELF"* ]]; then
		# Bun-compiled binary (the default "native" install since Claude Code ~1.0).
		# Extract printable strings to a temp file so the existing Python regex
		# extractors can run on it unchanged.
		if ! command -v strings >/dev/null 2>&1; then
			print_error "Bun binary detected but 'strings' utility not found."
			print_error "Install binutils (Linux) or Xcode Command Line Tools (macOS) and retry."
			return 1
		fi
		print_info "Bun binary detected — extracting strings for analysis: $resolved"
		CLAUDE_BIN_TMPFILE=$(mktemp /tmp/cch-extract-strings.XXXXXX)
		if ! strings "$resolved" >"$CLAUDE_BIN_TMPFILE" 2>/dev/null; then
			rm -f "$CLAUDE_BIN_TMPFILE"
			print_error "Failed to extract strings from binary: $resolved"
			return 1
		fi
		CLAUDE_BIN="$CLAUDE_BIN_TMPFILE"
		CLAUDE_BIN_REAL="$resolved"
	else
		# Try it as a JS file anyway (some systems report odd file types)
		CLAUDE_BIN="$resolved"
		CLAUDE_BIN_REAL="$resolved"
	fi

	return 0
}

# Extract the Claude CLI version from the source
extract_version() {
	local source_file="$1"
	local version
	# The VERSION constant is embedded in build-time config objects like:
	# VERSION:"2.1.92"
	version=$(python3 -c "
import re, sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
# Find VERSION in the build config object (near PACKAGE_URL or BUILD_TIME)
# This distinguishes from other version strings in the bundle
m = re.search(r'PACKAGE_URL:\"@anthropic-ai/claude-code\"[^}]*?VERSION:\"(\d+\.\d+\.\d+)\"', content)
if not m:
    m = re.search(r'VERSION:\"(\d+\.\d+\.\d+)\"[^}]*?BUILD_TIME:', content)
if not m:
    # Last resort: just find VERSION: with 3-part semver
    import subprocess
    try:
        r = subprocess.run(['claude', '--version'], capture_output=True, text=True, timeout=5)
        vm = re.match(r'^(\d+\.\d+\.\d+)', r.stdout.strip())
        if vm:
            print(vm.group(1))
        else:
            print('')
    except Exception:
        print('')
if m:
    print(m.group(1))
else:
    print('')
" "$source_file" 2>/dev/null)

	if [[ -z "$version" ]]; then
		# Fallback to CLI invocation
		version=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
	fi

	if [[ -z "$version" ]]; then
		print_error "Could not extract version from Claude CLI"
		return 1
	fi

	printf '%s' "$version"
	return 0
}

# Extract the SHA-256 salt used for version suffix computation
extract_salt() {
	local source_file="$1"
	local salt
	# The salt is a 12-char hex string assigned to a variable just before
	# the version suffix function. Pattern: var XXXX="<12hex>";
	# In v2.1.92: var jBY="59cf53e54c78";
	salt=$(python3 -c "
import re, sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
# Find the salt: a 12-char hex constant near the version suffix function.
# Node.js source: var <name>=\"<12hex>\";
# Bun strings output: lines like  u21=\"59cf53e54c78\"  (no 'var' prefix, one per line)
# Strategy: collect all 12-char lowercase hex strings, exclude known non-salt values,
# and return the first match. Known non-salts: all-zeros, all-4s, all-3s.
NON_SALT = {'000000000000', '444444444444', '333333333333'}
# Try full-source pattern first (Node.js)
m = re.search(r'var\s+\w+=\"([0-9a-f]{12})\";', content)
if m and m.group(1) not in NON_SALT:
    print(m.group(1))
    sys.exit(0)
# Bun strings output: bare assignment pattern  <name>=\"<12hex>\"
m = re.search(r'\w+=\"([0-9a-f]{12})\"', content)
if m and m.group(1) not in NON_SALT:
    print(m.group(1))
    sys.exit(0)
# Last resort: find any 12-char hex string in quotes, skip known non-salts
for candidate in re.findall(r'\"([0-9a-f]{12})\"', content):
    if candidate not in NON_SALT:
        print(candidate)
        sys.exit(0)
print('')
" "$source_file" 2>/dev/null)

	if [[ -z "$salt" ]]; then
		print_error "Could not extract salt from Claude CLI source"
		return 1
	fi

	printf '%s' "$salt"
	return 0
}

# Extract the character indices used for version suffix
extract_char_indices() {
	local source_file="$1"
	local indices
	# The char indices are in an array like [4,7,20] in the suffix function
	indices=$(SOURCE_FILE="$source_file" python3 -c '
import re, os
with open(os.environ["SOURCE_FILE"], "r", errors="replace") as f:
    content = f.read()
m = re.search(r"\[(\d+),(\d+),(\d+)\]\.map\(", content)
if m:
    print(f"{m.group(1)},{m.group(2)},{m.group(3)}")
else:
    print("")
' 2>/dev/null)

	if [[ -z "$indices" ]]; then
		print_error "Could not extract char indices from Claude CLI source"
		return 1
	fi

	printf '%s' "$indices"
	return 0
}

# Check if cch=00000 is present (placeholder for body hash)
detect_cch_placeholder() {
	local source_file="$1"
	local has_cch
	has_cch=$(python3 -c "
import sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
# Check if cch=00000 placeholder exists
if 'cch=00000' in content:
    print('true')
else:
    print('false')
" "$source_file" 2>/dev/null)

	printf '%s' "$has_cch"
	return 0
}

# Detect if xxHash is present (Bun binary had it; Node.js doesn't)
detect_xxhash() {
	local source_file="$1"
	local has_xxhash
	has_xxhash=$(python3 -c "
import re, sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
# Check for xxHash constants or references
if '0x6E52736AC806831E' in content or 'xxhash' in content.lower() or 'xxh64' in content.lower():
    print('true')
else:
    print('false')
" "$source_file" 2>/dev/null)

	printf '%s' "$has_xxhash"
	return 0
}

# Detect the entrypoint value
detect_entrypoint() {
	local source_file="$1"
	local entrypoint
	entrypoint=$(python3 -c "
import re, sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
# Find CLAUDE_CODE_ENTRYPOINT reference
m = re.search(r'CLAUDE_CODE_ENTRYPOINT\?\?\"(\w+)\"', content)
if m:
    print(m.group(1))
else:
    print('unknown')
" "$source_file" 2>/dev/null)

	printf '%s' "$entrypoint"
	return 0
}

# Build the complete JSON output
# $1 = source_file (may be a strings-extracted temp file for Bun binaries)
# $2 = real_bin_path (the actual claude binary path, for recording in JSON)
build_json() {
	local source_file="$1"
	local real_bin_path="${2:-$1}"

	local version salt char_indices has_cch has_xxhash entrypoint build_time
	version=$(extract_version "$source_file") || return 1
	salt=$(extract_salt "$source_file") || return 1
	char_indices=$(extract_char_indices "$source_file") || return 1
	has_cch=$(detect_cch_placeholder "$source_file")
	has_xxhash=$(detect_xxhash "$source_file")
	entrypoint=$(detect_entrypoint "$source_file")

	# Extract build time if available
	build_time=$(python3 -c "
import re, sys
with open(sys.argv[1], 'r', errors='replace') as f:
    content = f.read()
m = re.search(r'BUILD_TIME:\"([^\"]+)\"', content)
if m:
    print(m.group(1))
else:
    print('')
" "$source_file" 2>/dev/null)

	# Build JSON
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	VERSION="$version" SALT="$salt" CHAR_INDICES="$char_indices" \
		HAS_CCH="$has_cch" HAS_XXHASH="$has_xxhash" \
		ENTRYPOINT="$entrypoint" BUILD_TIME="$build_time" \
		SOURCE_FILE="$real_bin_path" NOW_ISO="$now_iso" \
		python3 -c "
import json, os
print(json.dumps({
    'version': os.environ['VERSION'],
    'salt': os.environ['SALT'],
    'char_indices': [int(x) for x in os.environ['CHAR_INDICES'].split(',')],
    'has_cch_placeholder': os.environ['HAS_CCH'] == 'true',
    'has_xxhash': os.environ['HAS_XXHASH'] == 'true',
    'entrypoint': os.environ['ENTRYPOINT'],
    'build_time': os.environ['BUILD_TIME'] or None,
    'source_file': os.environ['SOURCE_FILE'],
    'extracted_at': os.environ['NOW_ISO'],
    'notes': (
        'Node.js client — cch=00000 sent as-is (no xxHash replacement)'
        if os.environ['HAS_XXHASH'] == 'false'
        else 'Bun binary — xxHash body hash required'
    ),
}, indent=2))
"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_extract() {
	find_claude_source || return 1
	print_info "Claude CLI source: ${CLAUDE_BIN_REAL}" >&2
	build_json "$CLAUDE_BIN" "$CLAUDE_BIN_REAL"
	return 0
}

cmd_cache() {
	find_claude_source || return 1
	print_info "Claude CLI source: ${CLAUDE_BIN_REAL}" >&2
	local json
	json=$(build_json "$CLAUDE_BIN" "$CLAUDE_BIN_REAL") || return 1

	local cache_dir
	cache_dir=$(dirname "$CACHE_FILE")
	mkdir -p "$cache_dir"
	printf '%s\n' "$json" >"$CACHE_FILE"
	chmod 600 "$CACHE_FILE"

	local version
	version=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
	print_success "Cached CCH constants for Claude CLI v${version} to ${CACHE_FILE}"
	printf '%s\n' "$json"
	return 0
}

cmd_verify() {
	if [[ ! -f "$CACHE_FILE" ]]; then
		print_error "No cached constants found. Run: cch-extract.sh --cache"
		return 1
	fi

	find_claude_source || return 1
	local current_json cached_version current_version
	current_json=$(build_json "$CLAUDE_BIN" "$CLAUDE_BIN_REAL") || return 1

	cached_version=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1]))['version'])" "$CACHE_FILE" 2>/dev/null)
	current_version=$(printf '%s' "$current_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)

	if [[ "$cached_version" == "$current_version" ]]; then
		print_success "Cache is current: v${current_version}"
	else
		print_error "Cache is stale: cached v${cached_version}, installed v${current_version}"
		print_info "Run: cch-extract.sh --cache"
		return 1
	fi
	return 0
}

cmd_version() {
	find_claude_source || return 1
	extract_version "$CLAUDE_BIN"
	printf '\n'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local action="${1:---extract}"

	case "$action" in
	--cache | -c)
		cmd_cache
		;;
	--verify | -v)
		cmd_verify
		;;
	--version | -V)
		cmd_version
		;;
	--extract | -e | "")
		cmd_extract
		;;
	--help | -h)
		printf 'Usage: cch-extract.sh [--extract|--cache|--verify|--version]\n'
		printf '\n'
		printf 'Extract CCH signing constants from installed Claude CLI.\n'
		printf '\n'
		printf 'Options:\n'
		printf '  --extract   Extract and print JSON (default)\n'
		printf '  --cache     Extract and save to %s\n' "$CACHE_FILE"
		printf '  --verify    Check if cache matches installed version\n'
		printf '  --version   Print detected Claude CLI version\n'
		return 0
		;;
	*)
		print_error "Unknown option: $action"
		return 1
		;;
	esac
}

main "$@"
