#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-root-shell-layout.sh — guard intentional repository root shell layout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

_failures=0

_fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	_failures=$((_failures + 1))
	return 0
}

_pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

root_shell_files=$(git -C "$REPO_ROOT" ls-files '*.sh' | python3 -c 'import sys
allowed={"setup.sh","aidevops.sh"}
bad=[p.strip() for p in sys.stdin if p.strip().endswith(".sh") and "/" not in p.strip() and p.strip() not in allowed]
print("\n".join(bad))')

if [[ -n "$root_shell_files" ]]; then
	_fail "tracked root shell files outside allowlist: ${root_shell_files//$'\n'/, }"
else
	_pass "tracked root shell files are limited to setup.sh and aidevops.sh"
fi

root_module_dirs=$(git -C "$REPO_ROOT" ls-files | python3 -c 'import sys
# scripts/ is an intentional packaging surface for npm lifecycle entrypoints,
# not a shell implementation module tree.
allowed={".agents", ".github", ".githooks", ".husky", ".qlty", "docs", "prompts", "reference", "release", "scripts", "tests", "todo"}
signals=("module", "modules", "lib", "libs", "scripts")
dirs=sorted({p.split("/",1)[0] for p in sys.stdin if "/" in p})
bad=[d for d in dirs if d not in allowed and any(s in d for s in signals)]
print("\n".join(bad))')

if [[ -n "$root_module_dirs" ]]; then
	_fail "top-level implementation module directories need allowlist review: ${root_module_dirs//$'\n'/, }"
else
	_pass "no unreviewed top-level implementation module directories are tracked"
fi

if [[ "$_failures" -gt 0 ]]; then
	exit 1
fi

exit 0
