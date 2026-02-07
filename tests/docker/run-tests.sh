#!/usr/bin/env bash
# Setup script test runner
set -uo pipefail

SCRIPTS_DIR="${HOME}/git/aidevops/.agents/scripts"
PASS=0
FAIL=0
SKIP=0

pass() { echo -e "\033[32m[PASS]\033[0m $1"; PASS=$((PASS + 1)); }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "\033[33m[SKIP]\033[0m $1"; SKIP=$((SKIP + 1)); }

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
if "$s" help &>/dev/null; then pass "opencode help"; else fail "opencode help"; fi
if "$s" status &>/dev/null; then pass "opencode status"; else fail "opencode status"; fi
if "$s" install &>/dev/null; then pass "opencode install"; else fail "opencode install"; fi
if [[ -d ~/.config/opencode/agent ]]; then pass "agents created"; else fail "agents created"; fi

# setup-local-api-keys.sh
s="${SCRIPTS_DIR}/setup-local-api-keys.sh"
if "$s" help &>/dev/null; then pass "api-keys help"; else fail "api-keys help"; fi
if "$s" list &>/dev/null; then pass "api-keys list"; else fail "api-keys list"; fi
if "$s" set test-svc test-key &>/dev/null; then pass "api-keys set"; else fail "api-keys set"; fi

# setup-mcp-integrations.sh (requires Node.js - skip if not available)
s="${SCRIPTS_DIR}/setup-mcp-integrations.sh"
if command -v node &>/dev/null; then
    if "$s" help &>/dev/null; then pass "mcp help"; else fail "mcp help"; fi
else
    skip "mcp help (requires Node.js)"
fi

# Results
echo -e "\n=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [[ $FAIL -eq 0 ]]; then exit 0; else exit 1; fi
