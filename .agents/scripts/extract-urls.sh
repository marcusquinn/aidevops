#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# extract-urls.sh — Extract all URLs from the codebase and generate allowed-urls.txt
#
# Usage:
#   extract-urls.sh [--output FILE] [--repo-root DIR] [--verbose]
#
# Output: .agents/configs/allowed-urls.txt (one hostname per line, sorted)
#
# This script is the maintenance tool for the URL allowlist. Run it when:
#   - Initialising the allowlist for the first time
#   - Adding a batch of new legitimate URLs after a large feature
#   - Auditing what external domains the codebase references
#
# The GitHub Action (url-allowlist-check.yml) uses the allowlist to block
# PRs that introduce unknown hostnames.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"
OUTPUT_FILE="${OUTPUT_FILE:-${REPO_ROOT}/.agents/configs/allowed-urls.txt}"
VERBOSE="${VERBOSE:-false}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output)
		OUTPUT_FILE="$2"
		shift 2
		;;
	--repo-root)
		REPO_ROOT="$2"
		shift 2
		;;
	--verbose | -v)
		VERBOSE=true
		shift
		;;
	--help | -h)
		sed -n '2,20p' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

log() {
	if [[ "$VERBOSE" == "true" ]]; then
		echo "$*" >&2
	fi
	return 0
}

# ---------------------------------------------------------------------------
# URL extraction via Python (portable, handles encoding edge cases)
# Write Python script to a temp file to avoid shell quoting issues
# ---------------------------------------------------------------------------
TMPDIR_WORK="$(mktemp -d)"
PYTHON_SCRIPT="${TMPDIR_WORK}/extract_urls.py"

cleanup() {
	rm -rf "$TMPDIR_WORK"
	return 0
}
trap cleanup EXIT

cat >"$PYTHON_SCRIPT" <<'PYEOF'
import re
import subprocess
import sys
import os

repo_root = sys.argv[1]
verbose = sys.argv[2] == "true"

# Get all tracked files
result = subprocess.run(
    ["git", "-C", repo_root, "ls-files"],
    capture_output=True, text=True
)
files = [f for f in result.stdout.strip().split("\n") if f]

url_pattern = re.compile(r"https?://[^\s\"')\]>`]+")

# Patterns that indicate a non-real hostname
EXCLUDED_RE = re.compile(
    r"(\$\{|\$\(|\$[a-zA-Z_]|"   # shell/template variables
    r"<[a-zA-Z]|"                  # HTML/placeholder tags
    r"%[sd0-9]|"                   # printf format strings
    r"\\[nt]|"                     # escape sequences
    r"\.\.\.|"                     # ellipsis
    r"example\.com|example\.org|example\.net|"  # RFC 2606 examples
    r"localhost|"
    r"127\.0\.0\.1|"
    r"0\.0\.0\.0|"
    r"192\.168\.|"
    r"^10\.\d+\.\d+\.|"
    r"\.local$)"
)

def is_valid_hostname(hostname):
    """Return True if hostname looks like a real, non-placeholder domain."""
    if not hostname or len(hostname) < 4:
        return False
    # Must contain a dot
    if "." not in hostname:
        return False
    # Only valid hostname chars
    if re.search(r"[^a-zA-Z0-9.\-_]", hostname):
        return False
    # Must not start or end with dot/hyphen
    if hostname[0] in (".", "-") or hostname[-1] in (".", "-"):
        return False
    # TLD must be alpha only
    tld = hostname.rsplit(".", 1)[-1]
    if not tld.isalpha() or len(tld) < 2:
        return False
    # Apply exclusion patterns
    if EXCLUDED_RE.search(hostname):
        return False
    return True

hostnames = set()
skipped_files = 0

for rel_path in files:
    abs_path = os.path.join(repo_root, rel_path)
    try:
        with open(abs_path, "r", errors="ignore") as fh:
            content = fh.read()
        for url in url_pattern.findall(content):
            url = url.rstrip(".,;:")
            try:
                after_scheme = url.split("://", 1)[1]
                raw_host = after_scheme.split("/")[0].split("?")[0].split("#")[0]
                # Strip port
                raw_host = raw_host.split(":")[0]
                # Strip auth info
                if "@" in raw_host:
                    raw_host = raw_host.split("@")[1]
                hostname = raw_host.lower().strip()
                if is_valid_hostname(hostname):
                    hostnames.add(hostname)
            except (IndexError, ValueError):
                pass
    except (OSError, PermissionError):
        skipped_files += 1

if verbose:
    print(f"Scanned {len(files)} files, skipped {skipped_files}", file=sys.stderr)
    print(f"Found {len(hostnames)} unique valid hostnames", file=sys.stderr)

for h in sorted(hostnames):
    print(h)
PYEOF

# ---------------------------------------------------------------------------
# Run extraction
# ---------------------------------------------------------------------------
log "Extracting URLs from: $REPO_ROOT"
log "Output file: $OUTPUT_FILE"

HOSTNAMES=$(python3 "$PYTHON_SCRIPT" "$REPO_ROOT" "$VERBOSE")

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
	echo "Output directory does not exist: $OUTPUT_DIR" >&2
	exit 1
fi

{
	echo "# URL Allowlist — auto-generated by extract-urls.sh"
	echo "# One hostname per line. Add new entries here to allow them in PRs."
	echo "# Regenerate baseline: .agents/scripts/extract-urls.sh"
	echo "# Approve a single URL: aidevops approve url <hostname>"
	echo "# Last generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "#"
	echo "$HOSTNAMES"
} >"$OUTPUT_FILE"

COUNT=$(grep -c '^[^#]' "$OUTPUT_FILE" || true)
echo "Wrote $COUNT hostnames to $OUTPUT_FILE"
