#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# extract-urls.py — Extract hostnames from a git repo or diff and compare against an allowlist.
#
# Usage (baseline generation):
#   python3 extract-urls.py --repo-root <dir> [--verbose]
#
# Usage (PR diff check):
#   python3 extract-urls.py --diff-file <file> --allowlist <file>
#
# Outputs one hostname per line to stdout.
# Unknown hostnames (not in allowlist) are printed when --allowlist is given.

import argparse
import os
import re
import subprocess
import sys

URL_PATTERN = re.compile(r"https?://[^\s\"')\]>`]+")

EXCLUDED_RE = re.compile(
    r"(\$\{|\$\(|\$[a-zA-Z_]"
    r"|<[a-zA-Z]"
    r"|%[sd0-9]"
    r"|\\[nt]"
    r"|\.\.\."
    r"|example\.com|example\.org|example\.net"
    r"|localhost"
    r"|127\.0\.0\.1"
    r"|0\.0\.0\.0"
    r"|192\.168\."
    r"|^10\.\d+\.\d+\."
    r"|\.local$)"
)


def is_valid_hostname(hostname):
    """Return True if hostname looks like a real, non-placeholder domain."""
    if not hostname or len(hostname) < 4:
        return False
    if "." not in hostname:
        return False
    if re.search(r"[^a-zA-Z0-9.\-_]", hostname):
        return False
    if hostname[0] in (".", "-") or hostname[-1] in (".", "-"):
        return False
    tld = hostname.rsplit(".", 1)[-1]
    if not tld.isalpha() or len(tld) < 2:
        return False
    if EXCLUDED_RE.search(hostname):
        return False
    return True


def extract_hostnames(text):
    """Extract valid hostnames from a block of text."""
    hostnames = set()
    for url in URL_PATTERN.findall(text):
        url = url.rstrip(".,;:")
        try:
            after_scheme = url.split("://", 1)[1]
            raw_host = after_scheme.split("/")[0].split("?")[0].split("#")[0]
            raw_host = raw_host.split(":")[0]
            if "@" in raw_host:
                raw_host = raw_host.split("@")[1]
            hostname = raw_host.lower().strip()
            if is_valid_hostname(hostname):
                hostnames.add(hostname)
        except (IndexError, ValueError):
            pass
    return hostnames


def load_allowlist(path):
    """Load hostnames from an allowlist file."""
    allowlist = set()
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    allowlist.add(line.lower())
    except FileNotFoundError:
        pass
    return allowlist


def scan_repo(repo_root, verbose=False):
    """Scan all tracked files in a git repo and return all hostnames."""
    result = subprocess.run(
        ["git", "-C", repo_root, "ls-files"],
        capture_output=True,
        text=True,
        check=False,
    )
    files = [f for f in result.stdout.strip().split("\n") if f]

    hostnames = set()
    skipped = 0

    for rel_path in files:
        abs_path = os.path.join(repo_root, rel_path)
        try:
            with open(abs_path, "r", errors="ignore") as fh:
                content = fh.read()
            hostnames.update(extract_hostnames(content))
        except (OSError, PermissionError):
            skipped += 1

    if verbose:
        print(f"Scanned {len(files)} files, skipped {skipped}", file=sys.stderr)
        print(f"Found {len(hostnames)} unique valid hostnames", file=sys.stderr)

    return hostnames


def check_diff(diff_file, allowlist_file):
    """Check a diff file for unknown hostnames not in the allowlist."""
    with open(diff_file, "r", errors="ignore") as f:
        diff_text = f.read()

    # Only check added lines (lines starting with +, excluding diff headers)
    added_lines = "\n".join(
        line for line in diff_text.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )

    new_hosts = extract_hostnames(added_lines)
    allowlist = load_allowlist(allowlist_file)
    return sorted(new_hosts - allowlist)


def main():
    parser = argparse.ArgumentParser(description="URL hostname extractor and allowlist checker")
    parser.add_argument("--repo-root", help="Git repo root to scan")
    parser.add_argument("--diff-file", help="Diff file to check against allowlist")
    parser.add_argument("--allowlist", help="Allowlist file to compare against")
    parser.add_argument("--verbose", action="store_true", help="Verbose output to stderr")
    args = parser.parse_args()

    if args.diff_file:
        if not args.allowlist:
            print("--allowlist required with --diff-file", file=sys.stderr)
            sys.exit(1)
        unknown = check_diff(args.diff_file, args.allowlist)
        for h in unknown:
            print(h)
        return

    if args.repo_root:
        hostnames = scan_repo(args.repo_root, verbose=args.verbose)
        for h in sorted(hostnames):
            print(h)
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
