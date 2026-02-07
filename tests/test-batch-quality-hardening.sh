#!/usr/bin/env bash
# test-batch-quality-hardening.sh
#
# Verification tests for batch quality-hardening-8h deployed tasks.
# Tests each task's fix is actually present and working in the codebase.
#
# Usage: bash tests/test-batch-quality-hardening.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

# --- Configuration ---
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$REPO_DIR/.agents"
SCRIPTS_DIR="$AGENTS_DIR/scripts"
DEPLOYED_DIR="$HOME/.aidevops/agents/scripts"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# ============================================================
# SUPERVISOR DISPATCH FIXES (PR #429, #431)
# ============================================================
section "Supervisor: Worker Launch (nohup + disown)"

# Test: Workers use nohup to survive parent exit
if grep -q 'nohup bash -c' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "cmd_dispatch uses nohup for worker launch"
else
    fail "cmd_dispatch missing nohup for worker launch" \
        "Workers will die when cron pulse exits (~2 min)"
fi

# Test: Workers are disowned after launch
if grep -q 'disown.*worker_pid' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "cmd_dispatch disowns worker process"
else
    fail "cmd_dispatch missing disown" \
        "Workers may receive SIGHUP on parent exit"
fi

# Test: Re-prompt also uses nohup
reprompt_nohup=$(grep -c 'nohup bash -c' "$SCRIPTS_DIR/supervisor-helper.sh")
if [[ "$reprompt_nohup" -ge 3 ]]; then
    pass "cmd_reprompt also uses nohup (found $reprompt_nohup nohup instances)"
else
    fail "cmd_reprompt may be missing nohup (found $reprompt_nohup, expected >= 3)" \
        "Re-prompted workers will also die on cron exit"
fi

section "Supervisor: Dispatch Exit Code Handling"

# Test: Dispatch loop captures exit code correctly (not $? after if)
if grep -q 'cmd_dispatch.*||.*dispatch_exit=\$?' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Dispatch loop uses 'cmd || exit=\$?' pattern (not \$? after if)"
else
    fail "Dispatch loop may still use \$? after if (SC2319 bug)" \
        "Exit code 2 (concurrency) and 3 (provider down) won't be detected"
fi

# Test: Dispatch failures are logged (not swallowed by 2>/dev/null)
if grep -q 'Dispatch failed for.*exit.*trying next' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Dispatch failures are logged with exit code"
else
    fail "Dispatch failures may be silently swallowed" \
        "Cron log will show 'Dispatched: 0' with no explanation"
fi

section "Supervisor: Pulse-Level Health Check Caching"

# Test: _PULSE_HEALTH_VERIFIED flag exists
if grep -q '_PULSE_HEALTH_VERIFIED' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Pulse-level health check flag exists"
else
    fail "Missing _PULSE_HEALTH_VERIFIED flag" \
        "Health check will run 8s probe per task instead of once per pulse"
fi

# Test: check_model_health respects pulse flag
if grep -q 'pulse-verified OK' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "check_model_health has pulse-level fast path"
else
    fail "check_model_health missing pulse-level fast path"
fi

# Test: Health check sets pulse flag on success
pulse_flag_sets=$(grep -c '_PULSE_HEALTH_VERIFIED="true"' "$SCRIPTS_DIR/supervisor-helper.sh")
if [[ "$pulse_flag_sets" -ge 2 ]]; then
    pass "Health check sets pulse flag on success ($pulse_flag_sets locations)"
else
    fail "Health check may not set pulse flag consistently (found $pulse_flag_sets, expected >= 2)"
fi

section "Supervisor: macOS Timeout Compatibility"

# Test: Health check has macOS fallback (no coreutils timeout dependency)
if grep -q 'gtimeout\|background process with manual kill' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Health check has macOS timeout fallback"
else
    fail "Health check may depend on coreutils timeout (not available on macOS)"
fi

section "Supervisor: Model Resolution"

# Test: OpenCode model ID is correct (claude-sonnet-4-5, not claude-sonnet-4)
if grep -q 'claude-sonnet-4-5' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Model ID uses claude-sonnet-4-5 (correct for OpenCode)"
else
    fail "Model ID may be wrong (claude-sonnet-4 instead of claude-sonnet-4-5)"
fi

# Test: SUPERVISOR_MODEL env var override exists
if grep -q 'SUPERVISOR_MODEL' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "SUPERVISOR_MODEL env var override supported"
else
    fail "Missing SUPERVISOR_MODEL env var override"
fi

# ============================================================
# t135.4: Fix Corrupted JSON Config Files (PR #423)
# ============================================================
section "t135.4: JSON Config File Integrity"

# Test: pandoc-config.json.txt is valid JSON
if python3 -m json.tool "$REPO_DIR/configs/pandoc-config.json.txt" > /dev/null 2>&1; then
    pass "configs/pandoc-config.json.txt is valid JSON"
else
    fail "configs/pandoc-config.json.txt is INVALID JSON" \
        "$(python3 -m json.tool "$REPO_DIR/configs/pandoc-config.json.txt" 2>&1 | head -3)"
fi

# Test: chrome-devtools.json is valid JSON
if python3 -m json.tool "$REPO_DIR/configs/mcp-templates/chrome-devtools.json" > /dev/null 2>&1; then
    pass "configs/mcp-templates/chrome-devtools.json is valid JSON"
else
    fail "configs/mcp-templates/chrome-devtools.json is INVALID JSON" \
        "$(python3 -m json.tool "$REPO_DIR/configs/mcp-templates/chrome-devtools.json" 2>&1 | head -3)"
fi

# Test: No embedded newlines in JSON keys (the original corruption)
if ! grep -P '\x0a.*:' "$REPO_DIR/configs/pandoc-config.json.txt" 2>/dev/null | grep -q '".*\n.*"'; then
    pass "No embedded newline characters in pandoc-config.json.txt keys"
else
    fail "pandoc-config.json.txt still has embedded newline in keys"
fi

# Test: All git-tracked .json and .json.txt config files are valid
# Note: gitignored working copies (configs/*.json) are excluded -- only tracked files matter
json_invalid=0
while IFS= read -r f; do
    if ! python3 -m json.tool "$REPO_DIR/$f" > /dev/null 2>&1; then
        json_invalid=$((json_invalid + 1))
        [[ "$VERBOSE" == "--verbose" ]] && echo "       Invalid: $f"
    fi
done < <(git -C "$REPO_DIR" ls-files 'configs/*.json' 'configs/*.json.txt' 'configs/**/*.json' 'configs/**/*.json.txt' 2>/dev/null)
if [[ "$json_invalid" -eq 0 ]]; then
    pass "All git-tracked JSON config files in configs/ are valid"
else
    fail "$json_invalid git-tracked JSON config file(s) are invalid in configs/"
fi

# ============================================================
# t135.5: Remove Tracked Artifacts (PR #422)
# ============================================================
section "t135.5: Gitignored Artifacts Removed"

# Test: .scannerwork not tracked
if git -C "$REPO_DIR" ls-files .scannerwork 2>/dev/null | grep -q .; then
    fail ".scannerwork is still tracked in git"
else
    pass ".scannerwork is not tracked in git"
fi

# Test: .playwright-cli not tracked
if git -C "$REPO_DIR" ls-files .playwright-cli 2>/dev/null | grep -q .; then
    fail ".playwright-cli is still tracked in git"
else
    pass ".playwright-cli is not tracked in git"
fi

# Test: .gitignore has entries for these
if grep -q 'scannerwork' "$REPO_DIR/.gitignore" 2>/dev/null; then
    pass ".gitignore contains .scannerwork entry"
else
    fail ".gitignore missing .scannerwork entry"
fi

if grep -q 'playwright-cli' "$REPO_DIR/.gitignore" 2>/dev/null; then
    pass ".gitignore contains .playwright-cli entry"
else
    fail ".gitignore missing .playwright-cli entry"
fi

# ============================================================
# t135.10: Fix package.json Main Field (PR #424)
# ============================================================
section "t135.10: package.json Main Field"

# Test: main field is removed (index.js doesn't exist)
if python3 -c "import json; d=json.load(open('$REPO_DIR/package.json')); exit(0 if 'main' not in d else 1)" 2>/dev/null; then
    pass "package.json has no 'main' field (index.js doesn't exist)"
else
    main_val=$(python3 -c "import json; d=json.load(open('$REPO_DIR/package.json')); print(d.get('main',''))" 2>/dev/null)
    if [[ -f "$REPO_DIR/$main_val" ]]; then
        pass "package.json main field '$main_val' points to existing file"
    else
        fail "package.json main field '$main_val' points to non-existent file"
    fi
fi

# Test: package.json is valid JSON
if python3 -m json.tool "$REPO_DIR/package.json" > /dev/null 2>&1; then
    pass "package.json is valid JSON"
else
    fail "package.json is INVALID JSON"
fi

# Test: bin field exists (this is a CLI tool)
if python3 -c "import json; d=json.load(open('$REPO_DIR/package.json')); exit(0 if 'bin' in d else 1)" 2>/dev/null; then
    pass "package.json has 'bin' field (CLI entry point)"
else
    fail "package.json missing 'bin' field"
fi

# ============================================================
# t135.14: Standardize Shebangs (PR #428)
# ============================================================
section "t135.14: Shebang Standardization"

# Test: No scripts use #!/bin/bash (should all be #!/usr/bin/env bash)
bin_bash_count=0
while IFS= read -r f; do
    first_line=$(head -1 "$f" 2>/dev/null)
    if [[ "$first_line" == "#!/bin/bash" ]]; then
        bin_bash_count=$((bin_bash_count + 1))
        [[ "$VERBOSE" == "--verbose" ]] && echo "       #!/bin/bash: $f"
    fi
done < <(git -C "$REPO_DIR" ls-files '*.sh' | while read -r f; do echo "$REPO_DIR/$f"; done)

if [[ "$bin_bash_count" -eq 0 ]]; then
    pass "All .sh files use #!/usr/bin/env bash (0 using #!/bin/bash)"
else
    fail "$bin_bash_count script(s) still use #!/bin/bash instead of #!/usr/bin/env bash"
fi

# Test: All .sh files have a shebang
no_shebang_count=0
while IFS= read -r f; do
    first_line=$(head -1 "$f" 2>/dev/null)
    if [[ ! "$first_line" =~ ^#! ]]; then
        no_shebang_count=$((no_shebang_count + 1))
        [[ "$VERBOSE" == "--verbose" ]] && echo "       No shebang: $f"
    fi
done < <(git -C "$REPO_DIR" ls-files '*.sh' | while read -r f; do echo "$REPO_DIR/$f"; done)

if [[ "$no_shebang_count" -eq 0 ]]; then
    pass "All .sh files have a shebang line"
else
    fail "$no_shebang_count script(s) missing shebang line"
fi

# ============================================================
# t135.15: System Resource Monitoring in Supervisor (PR #425)
# ============================================================
section "t135.15: Supervisor Resource Monitoring"

# Test: calculate_adaptive_concurrency function exists
if grep -q 'calculate_adaptive_concurrency()' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "calculate_adaptive_concurrency() function exists"
else
    fail "calculate_adaptive_concurrency() function missing"
fi

# Test: Pulse outputs system resource info
if grep -q 'System resources' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Pulse outputs system resource summary"
else
    fail "Pulse missing system resource output"
fi

# Test: Load monitoring uses sysctl on macOS
if grep -q 'sysctl\|vm_stat\|/proc/loadavg' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Resource monitoring supports macOS (sysctl/vm_stat)"
else
    fail "Resource monitoring may not work on macOS"
fi

# Test: Adaptive concurrency reduces under load
if grep -q 'effective_concurrency=1\|halve concurrency' "$SCRIPTS_DIR/supervisor-helper.sh"; then
    pass "Adaptive concurrency throttles under high load"
else
    fail "Adaptive concurrency missing throttle logic"
fi

# ============================================================
# t137: Deploy opencode-config-agents.md Template (PR #421)
# ============================================================
section "t137: OpenCode Config Template Deployment"

# Test: Template file exists
if [[ -f "$REPO_DIR/templates/opencode-config-agents.md" ]]; then
    pass "templates/opencode-config-agents.md exists"
else
    fail "templates/opencode-config-agents.md missing"
fi

# Test: setup.sh has deployment logic for the template
if grep -q 'opencode-config-agents.md' "$REPO_DIR/setup.sh"; then
    pass "setup.sh references opencode-config-agents.md for deployment"
else
    fail "setup.sh missing opencode-config-agents.md deployment logic"
fi

# Test: Deployed template exists (if setup has been run)
if [[ -f "$HOME/.config/opencode/AGENTS.md" ]]; then
    pass "\$HOME/.config/opencode/AGENTS.md is deployed"
else
    skip "\$HOME/.config/opencode/AGENTS.md not deployed (run setup.sh to deploy)"
fi

# ============================================================
# t138: Bound aidevops update Output (PR #426)
# ============================================================
section "t138: Update Output Bounding"

# Test: git pull uses --quiet flag
if grep -q 'git pull.*--quiet\|git pull.*-q' "$REPO_DIR/aidevops.sh"; then
    pass "aidevops update uses --quiet git pull"
else
    fail "aidevops update may produce unbounded git pull output"
fi

# Test: Commit log is filtered to meaningful changes
if grep -q 'feat|fix|refactor|perf|docs' "$REPO_DIR/aidevops.sh"; then
    pass "Update output filters to meaningful commit types (feat/fix/refactor/perf/docs)"
else
    fail "Update output may show all commits (including chore/merge)"
fi

# Test: Output is bounded with head
if grep -q 'head -20' "$REPO_DIR/aidevops.sh"; then
    pass "Update output bounded to 20 lines max"
else
    fail "Update output may be unbounded (missing head -20)"
fi

# Test: Overflow message for large updates
if grep -q 'and more\|full list' "$REPO_DIR/aidevops.sh"; then
    pass "Shows overflow message when > 20 commits"
else
    fail "Missing overflow message for large updates"
fi

# ============================================================
# t139: FTS5 Hyphen Escaping in memory-helper.sh (PR #427)
# ============================================================
section "t139: Memory FTS5 Hyphen Escaping"

# Test: Query is wrapped in double quotes for FTS5
if grep -q 'escaped_query=.*".*"' "$SCRIPTS_DIR/memory-helper.sh"; then
    pass "FTS5 query is wrapped in double quotes"
else
    fail "FTS5 query may not be quoted (hyphens interpreted as NOT operator)"
fi

# Test: Comment explains the hyphen issue
if grep -q 'hyphens.*NOT operator\|FTS5 treats hyphens' "$SCRIPTS_DIR/memory-helper.sh"; then
    pass "Code documents the FTS5 hyphen issue"
else
    fail "Missing documentation about FTS5 hyphen behavior"
fi

# Test: Functional test - recall with hyphenated query doesn't error
if command -v "$DEPLOYED_DIR/memory-helper.sh" &>/dev/null || [[ -f "$DEPLOYED_DIR/memory-helper.sh" ]]; then
    recall_output=$(bash "$DEPLOYED_DIR/memory-helper.sh" recall "test-hyphen-query" 2>&1 || true)
    if echo "$recall_output" | grep -qi "error.*column\|fts5.*syntax\|no such column"; then
        fail "memory-helper.sh recall fails on hyphenated query" \
            "$recall_output"
    else
        pass "memory-helper.sh recall handles hyphenated query without FTS5 error"
    fi
else
    skip "memory-helper.sh not deployed (can't run functional test)"
fi

# ============================================================
# t140: PEP 668 Fallback Chain for Cisco Skill Scanner (PR #430)
# ============================================================
section "t140: PEP 668 Skill Scanner Fallback Chain"

# Test: setup.sh has uv fallback
if grep -q 'uv tool install cisco-ai-skill-scanner' "$REPO_DIR/setup.sh"; then
    pass "setup.sh has uv tool install fallback"
else
    fail "setup.sh missing uv tool install fallback"
fi

# Test: setup.sh has pipx fallback
if grep -q 'pipx install cisco-ai-skill-scanner' "$REPO_DIR/setup.sh"; then
    pass "setup.sh has pipx install fallback"
else
    fail "setup.sh missing pipx install fallback"
fi

# Test: setup.sh has venv+symlink fallback
# The venv dir and python3 -m venv are on separate lines, so check both exist
if grep -q 'python3 -m venv' "$REPO_DIR/setup.sh" && grep -q 'cisco-scanner-env' "$REPO_DIR/setup.sh"; then
    pass "setup.sh has venv+symlink fallback"
else
    fail "setup.sh missing venv+symlink fallback"
fi

# Test: setup.sh has pip3 --user legacy fallback
if grep -q 'pip3 install --user cisco-ai-skill-scanner' "$REPO_DIR/setup.sh"; then
    pass "setup.sh has pip3 --user legacy fallback"
else
    fail "setup.sh missing pip3 --user legacy fallback"
fi

# Test: Fallback chain is in correct order (uv -> pipx -> venv -> pip3)
uv_line=$(grep -n 'uv tool install cisco' "$REPO_DIR/setup.sh" | head -1 | cut -d: -f1 || true)
pipx_line=$(grep -n 'pipx install cisco' "$REPO_DIR/setup.sh" | head -1 | cut -d: -f1 || true)
venv_line=$(grep -n 'cisco-scanner-env' "$REPO_DIR/setup.sh" | head -1 | cut -d: -f1 || true)
pip3_line=$(grep -n 'pip3 install --user cisco' "$REPO_DIR/setup.sh" | head -1 | cut -d: -f1 || true)

if [[ -n "$uv_line" && -n "$pipx_line" && -n "$venv_line" && -n "$pip3_line" ]]; then
    if [[ "$uv_line" -lt "$pipx_line" && "$pipx_line" -lt "$venv_line" && "$venv_line" -lt "$pip3_line" ]]; then
        pass "Fallback chain order is correct: uv ($uv_line) -> pipx ($pipx_line) -> venv ($venv_line) -> pip3 ($pip3_line)"
    else
        fail "Fallback chain order is wrong: uv=$uv_line pipx=$pipx_line venv=$venv_line pip3=$pip3_line"
    fi
else
    fail "Could not determine fallback chain order (missing line numbers)"
fi

# Test: Venv cleanup on failure
if grep -q 'rm -rf.*cisco-scanner-env\|rm -rf.*venv_dir' "$REPO_DIR/setup.sh"; then
    pass "Venv is cleaned up on installation failure"
else
    fail "Venv may not be cleaned up on failure"
fi

# Test: Helpful error message when all fallbacks fail
if grep -q 'Install manually with.*uv tool install\|Or:.*pipx install' "$REPO_DIR/setup.sh"; then
    pass "Shows helpful manual install instructions on total failure"
else
    fail "Missing helpful error message when all fallbacks fail"
fi

# ============================================================
# CROSS-CUTTING: Script Quality
# ============================================================
section "Cross-Cutting: Script Quality"

# Test: supervisor-helper.sh passes bash syntax check
if bash -n "$SCRIPTS_DIR/supervisor-helper.sh" 2>/dev/null; then
    pass "supervisor-helper.sh passes bash -n syntax check"
else
    fail "supervisor-helper.sh has syntax errors"
fi

# Test: memory-helper.sh passes bash syntax check
if bash -n "$SCRIPTS_DIR/memory-helper.sh" 2>/dev/null; then
    pass "memory-helper.sh passes bash -n syntax check"
else
    fail "memory-helper.sh has syntax errors"
fi

# Test: setup.sh passes bash syntax check
if bash -n "$REPO_DIR/setup.sh" 2>/dev/null; then
    pass "setup.sh passes bash -n syntax check"
else
    fail "setup.sh has syntax errors"
fi

# Test: aidevops.sh passes bash syntax check
if bash -n "$REPO_DIR/aidevops.sh" 2>/dev/null; then
    pass "aidevops.sh passes bash -n syntax check"
else
    fail "aidevops.sh has syntax errors"
fi

# Test: ShellCheck on supervisor-helper.sh (no errors, only warnings allowed)
if command -v shellcheck &>/dev/null; then
    sc_errors=$(shellcheck -S error "$SCRIPTS_DIR/supervisor-helper.sh" 2>&1 | grep -c "error" || true)
    if [[ "$sc_errors" -eq 0 ]]; then
        pass "supervisor-helper.sh has 0 ShellCheck errors"
    else
        fail "supervisor-helper.sh has $sc_errors ShellCheck errors"
    fi
else
    skip "shellcheck not installed"
fi

# Test: No TODO/FIXME/HACK markers in the specific changed functions
# Exclude legitimate references like "TODO.md" and "auto-dispatch"
hack_count=$(grep -nE '# (TODO|FIXME|HACK|XXX):' "$SCRIPTS_DIR/supervisor-helper.sh" | grep -cE 'dispatch|health|nohup|reprompt' || true)
if [[ "$hack_count" -eq 0 ]]; then
    pass "No TODO/FIXME/HACK markers in dispatch/health/reprompt code"
else
    fail "$hack_count TODO/FIXME/HACK markers found in critical supervisor code"
fi

# ============================================================
# FUNCTIONAL: Supervisor Dispatch (live test)
# ============================================================
section "Functional: Supervisor Dispatch (live)"

# Test: Deployed supervisor script matches repo
if [[ -f "$DEPLOYED_DIR/supervisor-helper.sh" ]]; then
    if diff -q "$SCRIPTS_DIR/supervisor-helper.sh" "$DEPLOYED_DIR/supervisor-helper.sh" > /dev/null 2>&1; then
        pass "Deployed supervisor-helper.sh matches repo version"
    else
        fail "Deployed supervisor-helper.sh differs from repo version" \
            "Run: cp $SCRIPTS_DIR/supervisor-helper.sh $DEPLOYED_DIR/supervisor-helper.sh"
    fi
else
    skip "supervisor-helper.sh not deployed"
fi

# Test: Deployed memory-helper.sh matches repo
if [[ -f "$DEPLOYED_DIR/memory-helper.sh" ]]; then
    if diff -q "$SCRIPTS_DIR/memory-helper.sh" "$DEPLOYED_DIR/memory-helper.sh" > /dev/null 2>&1; then
        pass "Deployed memory-helper.sh matches repo version"
    else
        fail "Deployed memory-helper.sh differs from repo version"
    fi
else
    skip "memory-helper.sh not deployed"
fi

# Test: Supervisor DB exists and is accessible
if [[ -f "$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db" ]]; then
    task_count=$(sqlite3 "$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db" "SELECT COUNT(*) FROM tasks;" 2>/dev/null || echo "0")
    if [[ "$task_count" -gt 0 ]]; then
        pass "Supervisor DB accessible ($task_count tasks)"
    else
        fail "Supervisor DB exists but has 0 tasks"
    fi
else
    skip "Supervisor DB not found (supervisor not initialized)"
fi

# Test: Cron pulse is installed
if crontab -l 2>/dev/null | grep -q 'supervisor-helper.sh pulse'; then
    pass "Cron pulse is installed"
else
    skip "Cron pulse not installed (autonomous mode not active)"
fi

# Test: Running workers have valid PIDs (if any)
if [[ -d "$HOME/.aidevops/.agent-workspace/supervisor/pids" ]]; then
    stale_pids=0
    live_pids=0
    for pid_file in "$HOME/.aidevops/.agent-workspace/supervisor/pids"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        pid=$(cat "$pid_file")
        task=$(basename "$pid_file" .pid)
        status=$(sqlite3 "$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db" \
            "SELECT status FROM tasks WHERE id = '$task';" 2>/dev/null || echo "unknown")
        if [[ "$status" == "running" || "$status" == "dispatched" ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                live_pids=$((live_pids + 1))
            else
                stale_pids=$((stale_pids + 1))
                [[ "$VERBOSE" == "--verbose" ]] && echo "       Stale: $task (PID $pid, status=$status)"
            fi
        fi
    done
    if [[ "$stale_pids" -eq 0 ]]; then
        pass "No stale PIDs for running/dispatched tasks ($live_pids alive)"
    else
        fail "$stale_pids stale PID(s) for running/dispatched tasks" \
            "Workers may have died — pulse should clean these up"
    fi
else
    skip "No PID directory (no workers dispatched)"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    printf "\033[0;31mFAILURES DETECTED — review output above\033[0m\n"
    exit 1
else
    echo ""
    printf "\033[0;32mAll tests passed.\033[0m\n"
    exit 0
fi
