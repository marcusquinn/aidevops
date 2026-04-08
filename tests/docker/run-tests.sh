#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Setup script test runner
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
PASS=0
FAIL=0
SKIP=0

pass() {
	echo -e "\033[32m[PASS]\033[0m $1"
	PASS=$((PASS + 1))
}
fail() {
	echo -e "\033[31m[FAIL]\033[0m $1"
	FAIL=$((FAIL + 1))
}
skip() {
	echo -e "\033[33m[SKIP]\033[0m $1"
	SKIP=$((SKIP + 1))
}

# Test syntax for all scripts
echo "=== Syntax Tests ==="
for s in "${SCRIPTS_DIR}"/*.sh; do
	name=$(basename "$s")
	if bash -n "$s" 2>/dev/null; then
		pass "$name"
	else
		fail "$name"
	fi
done

# Test setup scripts
echo -e "\n=== Setup Script Tests ==="

# generate-opencode-agents.sh
s="${SCRIPTS_DIR}/generate-opencode-agents.sh"
"$s" help &>/dev/null && pass "opencode help" || fail "opencode help"
"$s" status &>/dev/null && pass "opencode status" || fail "opencode status"
"$s" install &>/dev/null && pass "opencode install" || fail "opencode install"
[[ -d ~/.config/opencode/agent ]] && pass "agents created" || fail "agents created"

# setup-local-api-keys.sh
s="${SCRIPTS_DIR}/setup-local-api-keys.sh"
"$s" help &>/dev/null && pass "api-keys help" || fail "api-keys help"
"$s" list &>/dev/null && pass "api-keys list" || fail "api-keys list"
"$s" set test-svc test-key &>/dev/null && pass "api-keys set" || fail "api-keys set"

# setup-mcp-integrations.sh (requires Node.js - skip if not available)
s="${SCRIPTS_DIR}/setup-mcp-integrations.sh"
if command -v node &>/dev/null; then
	"$s" help &>/dev/null && pass "mcp help" || fail "mcp help"
else
	skip "mcp help (requires Node.js)"
fi

# Results
echo -e "\n=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
