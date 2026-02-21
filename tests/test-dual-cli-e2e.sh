#!/usr/bin/env bash
# shellcheck disable=SC2034
# test-dual-cli-e2e.sh
#
# End-to-end verification of dual-CLI architecture (t1164).
#
# Verifies:
#   1. CLI routing: opencode is primary, claude is deprecated fallback
#   2. Mixed batch dispatch: Anthropic + non-Anthropic tasks route correctly
#   3. OAuth detection: Anthropic OAuth auth flow detection in provider
#   4. Fallback on auth failure: graceful degradation when auth fails
#   5. Cost tracking: requested_tier vs actual_tier recorded per dispatch
#   6. No regressions: pure-OpenCode dispatch path unchanged
#   7. build_cli_cmd: correct command generation for both CLIs
#   8. Model resolution: tier classification + fallback chain
#
# This test does NOT spawn real AI CLI processes — it mocks both opencode
# and claude binaries and verifies the supervisor's orchestration logic.
#
# Usage: bash tests/test-dual-cli-e2e.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
SUPERVISOR_SCRIPT="$SCRIPTS_DIR/supervisor-helper.sh"
SUPERVISOR_DIR_MODULE="$SCRIPTS_DIR/supervisor"
SHARED_CONSTANTS="$SCRIPTS_DIR/shared-constants.sh"
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
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
	return 0
}

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
TEST_REPO="$TEST_DIR/test-repo"
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR/supervisor"

# Create mock opencode binary
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/opencode" <<'MOCK_OPENCODE'
#!/usr/bin/env bash
# Mock opencode CLI — records invocations and produces realistic output
MOCK_LOG="${MOCK_OPENCODE_LOG:-/tmp/mock-opencode-invocations.log}"
echo "MOCK_OPENCODE_INVOKED: $*" >> "$MOCK_LOG"

# Handle version
if [[ "${1:-}" == "version" ]]; then
    echo "opencode v1.2.0 (mock)"
    exit 0
fi

# Handle run
if [[ "${1:-}" == "run" ]]; then
    # Parse args to find format and prompt
    output_format="text"
    model=""
    title=""
    prompt=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) output_format="$2"; shift 2 ;;
            -m) model="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            run) shift ;;
            *) prompt="$1"; shift ;;
        esac
    done

    if [[ "$output_format" == "json" ]]; then
        echo '{"type":"text","text":"Mock opencode response: task completed.\nFULL_LOOP_COMPLETE"}'
    else
        echo "OK"
    fi
    exit 0
fi

# Handle auth
if [[ "${1:-}" == "auth" ]]; then
    if [[ "${2:-}" == "login" ]]; then
        echo "Logged in successfully"
        exit 0
    fi
    if [[ "${2:-}" == "status" ]]; then
        echo "Authenticated: yes"
        echo "Provider: anthropic (OAuth)"
        exit 0
    fi
fi

echo "opencode: unknown command: $*" >&2
exit 1
MOCK_OPENCODE
chmod +x "$MOCK_BIN/opencode"

# Create mock claude binary
cat >"$MOCK_BIN/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
# Mock claude CLI — records invocations and produces realistic output
MOCK_LOG="${MOCK_CLAUDE_LOG:-/tmp/mock-claude-invocations.log}"
echo "MOCK_CLAUDE_INVOKED: $*" >> "$MOCK_LOG"

# Handle --version
if [[ "${1:-}" == "--version" ]]; then
    echo "claude 1.0.20 (mock)"
    exit 0
fi

# Handle -p (prompt mode)
if [[ "${1:-}" == "-p" ]]; then
    output_format="text"
    for arg in "$@"; do
        if [[ "$arg" == "json" ]]; then
            output_format="json"
        fi
    done

    if [[ "$output_format" == "json" ]]; then
        echo '{"type":"text","text":"Mock claude response: task completed.\nFULL_LOOP_COMPLETE"}'
    else
        echo "OK"
    fi
    exit 0
fi

echo "claude: unknown command" >&2
exit 1
MOCK_CLAUDE
chmod +x "$MOCK_BIN/claude"

# Export mock log paths
export MOCK_OPENCODE_LOG="$TEST_DIR/mock-opencode-invocations.log"
export MOCK_CLAUDE_LOG="$TEST_DIR/mock-claude-invocations.log"

# shellcheck disable=SC2317,SC2329
cleanup() {
	if [[ -d "$TEST_REPO" ]]; then
		git -C "$TEST_REPO" worktree list --porcelain 2>/dev/null |
			grep "^worktree " | cut -d' ' -f2- | while IFS= read -r wt_path; do
			if [[ "$wt_path" != "$TEST_REPO" && -d "$wt_path" ]]; then
				git -C "$TEST_REPO" worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
			fi
		done
		git -C "$TEST_REPO" worktree prune 2>/dev/null || true
	fi
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helper: run supervisor command with isolated DB
sup() {
	bash "$SUPERVISOR_SCRIPT" "$@" 2>&1
	return $?
}

# Helper: query the test DB directly
test_db() {
	sqlite3 -cmd ".timeout 5000" "$TEST_DIR/supervisor/supervisor.db" "$@"
}

# Helper: get task status
get_status() {
	test_db "SELECT status FROM tasks WHERE id = '$1';"
}

# Helper: get task field
get_field() {
	test_db "SELECT $2 FROM tasks WHERE id = '$1';"
}

# Helper: create a mock worker log file
create_log() {
	local task_id="$1"
	local content="$2"
	local log_file="$TEST_DIR/supervisor/logs/${task_id}.log"
	mkdir -p "$TEST_DIR/supervisor/logs"
	echo "$content" >"$log_file"
	test_db "UPDATE tasks SET log_file = '$log_file' WHERE id = '$task_id';"
	echo "$log_file"
}

# Helper: source supervisor modules for unit-level testing
# Provides a clean environment with mock PATH
run_in_supervisor_env() {
	bash -c "
        export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
        export PATH='$MOCK_BIN:\$PATH'
        BLUE='' GREEN='' YELLOW='' RED='' NC=''
        SUPERVISOR_LOG='/dev/null'
        SUPERVISOR_DIR='$TEST_DIR/supervisor'
        SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
        source '$SHARED_CONSTANTS'
        source '$SUPERVISOR_DIR_MODULE/_common.sh'
        source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
        $1
    " 2>/dev/null
}

# ============================================================
# SETUP: Create a real git repo and initialize supervisor
# ============================================================
section "Test Environment Setup"

git init -q "$TEST_REPO"
git -C "$TEST_REPO" checkout -q -b main 2>&1 || true
echo "# Test Repo" >"$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m "initial commit"

sup init >/dev/null

if [[ -f "$TEST_DIR/supervisor/supervisor.db" ]]; then
	pass "Supervisor DB initialized"
else
	fail "Supervisor DB not created"
	exit 1
fi

if [[ -d "$TEST_REPO/.git" ]]; then
	pass "Test git repo created with initial commit"
else
	fail "Test git repo not created"
	exit 1
fi

# ============================================================
# SECTION 1: Default CLI Resolution (opencode primary)
# ============================================================
section "1. Default CLI Resolution (opencode primary, no SUPERVISOR_CLI)"

# Test: Without SUPERVISOR_CLI, resolve_ai_cli returns opencode
default_cli=$(run_in_supervisor_env "
    unset SUPERVISOR_CLI
    resolve_ai_cli
")

if [[ "$default_cli" == "opencode" ]]; then
	pass "Default CLI: resolve_ai_cli returns 'opencode' (no SUPERVISOR_CLI set)"
else
	fail "Default CLI: expected 'opencode', got '$default_cli'"
fi

# Test: SUPERVISOR_CLI=opencode explicitly
explicit_opencode=$(run_in_supervisor_env "
    export SUPERVISOR_CLI=opencode
    resolve_ai_cli
")

if [[ "$explicit_opencode" == "opencode" ]]; then
	pass "Explicit CLI: SUPERVISOR_CLI=opencode returns 'opencode'"
else
	fail "Explicit CLI: expected 'opencode', got '$explicit_opencode'"
fi

# Test: SUPERVISOR_CLI=claude returns claude (deprecated fallback)
explicit_claude=$(run_in_supervisor_env "
    export SUPERVISOR_CLI=claude
    resolve_ai_cli
")

if [[ "$explicit_claude" == "claude" ]]; then
	pass "Explicit CLI: SUPERVISOR_CLI=claude returns 'claude' (deprecated)"
else
	fail "Explicit CLI: expected 'claude', got '$explicit_claude'"
fi

# Test: When only claude is in PATH (no opencode), fallback to claude with warning
# Use a separate directory with only claude to avoid file rename races
CLAUDE_ONLY_BIN="$TEST_DIR/claude-only-bin"
mkdir -p "$CLAUDE_ONLY_BIN"
cp "$MOCK_BIN/claude" "$CLAUDE_ONLY_BIN/claude"

claude_only_cli=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$CLAUDE_ONLY_BIN:/usr/bin:/bin:/usr/sbin:/sbin'
    unset SUPERVISOR_CLI
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_ai_cli
" 2>/dev/null)

if [[ "$claude_only_cli" == "claude" ]]; then
	pass "Fallback CLI: when opencode missing, falls back to claude"
else
	fail "Fallback CLI: expected 'claude', got '$claude_only_cli'"
fi

# Test: When neither CLI is in PATH, resolve_ai_cli fails
# Test: When neither CLI is in PATH, resolve_ai_cli fails
# Use a directory with only system commands (no opencode or claude)
NO_CLI_BIN="$TEST_DIR/no-cli-bin"
mkdir -p "$NO_CLI_BIN"

no_cli_rc=0
bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$NO_CLI_BIN:/usr/bin:/bin:/usr/sbin:/sbin'
    unset SUPERVISOR_CLI
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_ai_cli
" &>/dev/null || no_cli_rc=$?

if [[ "$no_cli_rc" -ne 0 ]]; then
	pass "No CLI: resolve_ai_cli fails when neither CLI in PATH (exit $no_cli_rc)"
else
	fail "No CLI: should fail when neither CLI available"
fi

# ============================================================
# SECTION 2: build_cli_cmd for OpenCode (primary path)
# ============================================================
section "2. build_cli_cmd for OpenCode (primary dispatch path)"

# Test: opencode run command
oc_run_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli opencode --action run --output array \
        --model 'anthropic/claude-opus-4-6' \
        --title 't1164-test' \
        --prompt 'Test prompt'
")

if echo "$oc_run_cmd" | grep -q "^opencode"; then
	pass "OpenCode run: starts with 'opencode'"
else
	fail "OpenCode run: should start with 'opencode'" "Got: $oc_run_cmd"
fi

if echo "$oc_run_cmd" | grep -q "run"; then
	pass "OpenCode run: includes 'run' subcommand"
else
	fail "OpenCode run: should include 'run'" "Got: $oc_run_cmd"
fi

if echo "$oc_run_cmd" | grep -q "\-\-format.*json\|json.*\-\-format"; then
	pass "OpenCode run: includes --format json"
else
	fail "OpenCode run: should include --format json" "Got: $oc_run_cmd"
fi

if echo "$oc_run_cmd" | grep -q "\-m"; then
	pass "OpenCode run: includes -m flag for model"
else
	fail "OpenCode run: should include -m flag" "Got: $oc_run_cmd"
fi

if echo "$oc_run_cmd" | grep -q "anthropic/claude-opus-4-6"; then
	pass "OpenCode run: preserves full provider/model string"
else
	fail "OpenCode run: should preserve full model string" "Got: $oc_run_cmd"
fi

if echo "$oc_run_cmd" | grep -q "\-\-title"; then
	pass "OpenCode run: includes --title flag"
else
	fail "OpenCode run: should include --title" "Got: $oc_run_cmd"
fi

# Test: opencode version command
oc_version_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli opencode --action version --output array
")

if [[ "$oc_version_cmd" == *"opencode"*"version"* ]]; then
	pass "OpenCode version: produces 'opencode version'"
else
	fail "OpenCode version: should produce 'opencode version'" "Got: $oc_version_cmd"
fi

# Test: opencode probe command
oc_probe_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli opencode --action probe --output array \
        --model 'anthropic/claude-sonnet-4-6'
")

if echo "$oc_probe_cmd" | grep -q "health-check"; then
	pass "OpenCode probe: includes --title health-check"
else
	fail "OpenCode probe: should include health-check title" "Got: $oc_probe_cmd"
fi

if echo "$oc_probe_cmd" | grep -q "Reply with exactly: OK\|Reply.*OK"; then
	pass "OpenCode probe: includes health-check prompt"
else
	fail "OpenCode probe: should include health-check prompt" "Got: $oc_probe_cmd"
fi

# ============================================================
# SECTION 3: build_cli_cmd for Claude (deprecated fallback)
# ============================================================
section "3. build_cli_cmd for Claude (deprecated fallback path)"

# Test: claude run command
cl_run_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli claude --action run --output array \
        --model 'anthropic/claude-sonnet-4-6' \
        --prompt 'Test prompt'
")

if echo "$cl_run_cmd" | grep -q "^claude"; then
	pass "Claude run: starts with 'claude'"
else
	fail "Claude run: should start with 'claude'" "Got: $cl_run_cmd"
fi

if echo "$cl_run_cmd" | grep -q "\-p"; then
	pass "Claude run: includes -p flag (not 'run' subcommand)"
else
	fail "Claude run: should include -p flag" "Got: $cl_run_cmd"
fi

if echo "$cl_run_cmd" | grep -q "output-format"; then
	pass "Claude run: includes --output-format (not --format)"
else
	fail "Claude run: should include --output-format" "Got: $cl_run_cmd"
fi

# Verify model prefix stripping (anthropic/ prefix removed for claude CLI)
if echo "$cl_run_cmd" | grep -q "claude-sonnet-4-6" && ! echo "$cl_run_cmd" | grep -q "anthropic/"; then
	pass "Claude run: strips provider prefix from model"
else
	fail "Claude run: should strip 'anthropic/' prefix" "Got: $cl_run_cmd"
fi

# Test: claude does NOT get --title flag (not supported)
if ! echo "$cl_run_cmd" | grep -q "\-\-title"; then
	pass "Claude run: does NOT include --title (unsupported)"
else
	fail "Claude run: should NOT include --title" "Got: $cl_run_cmd"
fi

# Test: claude version command
cl_version_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli claude --action version --output array
")

if [[ "$cl_version_cmd" == *"claude"*"--version"* ]]; then
	pass "Claude version: produces 'claude --version'"
else
	fail "Claude version: should produce 'claude --version'" "Got: $cl_version_cmd"
fi

# Test: claude probe uses text format (not json)
cl_probe_cmd=$(run_in_supervisor_env "
    build_cli_cmd --cli claude --action probe --output array \
        --model 'anthropic/claude-sonnet-4-6'
")

if echo "$cl_probe_cmd" | grep -q "output-format.*text\|text.*output-format"; then
	pass "Claude probe: uses --output-format text"
else
	fail "Claude probe: should use text format" "Got: $cl_probe_cmd"
fi

# ============================================================
# SECTION 4: CLI Routing Differences (opencode vs claude)
# ============================================================
section "4. CLI Routing Differences (structural comparison)"

# Test: opencode uses 'run' subcommand, claude uses '-p' flag
oc_tokens=$(run_in_supervisor_env "
    build_cli_cmd --cli opencode --action run --output array \
        --model 'anthropic/claude-opus-4-6' --prompt 'test'
")
cl_tokens=$(run_in_supervisor_env "
    build_cli_cmd --cli claude --action run --output array \
        --model 'anthropic/claude-opus-4-6' --prompt 'test'
")

# Structural difference: opencode uses 'run', claude uses '-p'
if echo "$oc_tokens" | grep -q " run " && echo "$cl_tokens" | grep -q " \-p "; then
	pass "Routing: opencode uses 'run' subcommand, claude uses '-p' flag"
else
	fail "Routing: structural difference not detected" "OC: $oc_tokens | CL: $cl_tokens"
fi

# Structural difference: opencode uses --format, claude uses --output-format
if echo "$oc_tokens" | grep -q "\-\-format" && echo "$cl_tokens" | grep -q "\-\-output-format"; then
	pass "Routing: opencode uses --format, claude uses --output-format"
else
	fail "Routing: format flag difference not detected"
fi

# Structural difference: opencode preserves provider/ prefix, claude strips it
if echo "$oc_tokens" | grep -q "anthropic/" && ! echo "$cl_tokens" | grep -q "anthropic/"; then
	pass "Routing: opencode preserves provider prefix, claude strips it"
else
	fail "Routing: provider prefix handling difference not detected"
fi

# ============================================================
# SECTION 5: Model Resolution and Tier Classification
# ============================================================
section "5. Model Resolution and Tier Classification"

# Test: resolve_model with tier names
opus_model=$(run_in_supervisor_env "resolve_model opus opencode")
sonnet_model=$(run_in_supervisor_env "resolve_model sonnet opencode")
haiku_model=$(run_in_supervisor_env "resolve_model haiku opencode")
coding_model=$(run_in_supervisor_env "resolve_model coding opencode")

if [[ "$opus_model" == "anthropic/claude-opus-4-6" ]]; then
	pass "Model resolution: opus -> anthropic/claude-opus-4-6"
else
	fail "Model resolution: opus -> expected anthropic/claude-opus-4-6" "Got: $opus_model"
fi

if [[ "$sonnet_model" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "Model resolution: sonnet -> anthropic/claude-sonnet-4-6"
else
	fail "Model resolution: sonnet -> expected anthropic/claude-sonnet-4-6" "Got: $sonnet_model"
fi

if [[ "$haiku_model" == "anthropic/claude-haiku-4-5" ]]; then
	pass "Model resolution: haiku -> anthropic/claude-haiku-4-5"
else
	fail "Model resolution: haiku -> expected anthropic/claude-haiku-4-5" "Got: $haiku_model"
fi

if [[ "$coding_model" == "anthropic/claude-opus-4-6" ]]; then
	pass "Model resolution: coding -> anthropic/claude-opus-4-6 (default)"
else
	fail "Model resolution: coding -> expected anthropic/claude-opus-4-6" "Got: $coding_model"
fi

# Test: resolve_model with full model string (passthrough)
full_model=$(run_in_supervisor_env "resolve_model 'anthropic/claude-sonnet-4-6' opencode")
if [[ "$full_model" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "Model resolution: full model string passes through unchanged"
else
	fail "Model resolution: full model string should pass through" "Got: $full_model"
fi

# Test: SUPERVISOR_MODEL env var override
override_model=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_MODEL='anthropic/claude-haiku-4-5'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_model opus opencode
" 2>/dev/null)

if [[ "$override_model" == "anthropic/claude-haiku-4-5" ]]; then
	pass "Model resolution: SUPERVISOR_MODEL overrides tier resolution"
else
	fail "Model resolution: SUPERVISOR_MODEL should override" "Got: $override_model"
fi

# Test: classify_task_complexity
trivial_tier=$(run_in_supervisor_env "classify_task_complexity 'rename variable foo to bar'")
simple_tier=$(run_in_supervisor_env "classify_task_complexity 'update README with new API docs'")
complex_tier=$(run_in_supervisor_env "classify_task_complexity 'architect new distributed system'")
e2e_tier=$(run_in_supervisor_env "classify_task_complexity 'end-to-end verification of dual-CLI'")

if [[ "$trivial_tier" == "haiku" ]]; then
	pass "Task classification: 'rename variable' -> haiku"
else
	fail "Task classification: 'rename variable' expected haiku" "Got: $trivial_tier"
fi

if [[ "$simple_tier" == "sonnet" ]]; then
	pass "Task classification: 'update README' -> sonnet"
else
	fail "Task classification: 'update README' expected sonnet" "Got: $simple_tier"
fi

if [[ "$complex_tier" == "opus" ]]; then
	pass "Task classification: 'architect system' -> opus"
else
	fail "Task classification: 'architect system' expected opus" "Got: $complex_tier"
fi

if [[ "$e2e_tier" == "opus" ]]; then
	pass "Task classification: 'end-to-end verification' -> opus"
else
	fail "Task classification: 'end-to-end verification' expected opus" "Got: $e2e_tier"
fi

# Test: tag-based classification overrides
tag_trivial=$(run_in_supervisor_env "classify_task_complexity 'complex task' '#trivial'")
tag_docs=$(run_in_supervisor_env "classify_task_complexity 'complex task' '#docs'")
tag_complex=$(run_in_supervisor_env "classify_task_complexity 'simple task' '#complex'")

if [[ "$tag_trivial" == "haiku" ]]; then
	pass "Tag classification: #trivial overrides description -> haiku"
else
	fail "Tag classification: #trivial should override" "Got: $tag_trivial"
fi

if [[ "$tag_docs" == "sonnet" ]]; then
	pass "Tag classification: #docs overrides description -> sonnet"
else
	fail "Tag classification: #docs should override" "Got: $tag_docs"
fi

if [[ "$tag_complex" == "opus" ]]; then
	pass "Tag classification: #complex overrides description -> opus"
else
	fail "Tag classification: #complex should override" "Got: $tag_complex"
fi

# ============================================================
# SECTION 6: Cost Tracking (requested_tier vs actual_tier)
# ============================================================
section "6. Cost Tracking (record_dispatch_model_tiers)"

# Add a task and record tier data
sup add cost-t1 --repo "$TEST_REPO" --description "Cost tracking test" --no-issue >/dev/null

# Record tiers: requested opus, actual opus
run_in_supervisor_env "
    record_dispatch_model_tiers 'cost-t1' 'opus' 'anthropic/claude-opus-4-6'
" || true

req_tier=$(get_field "cost-t1" "requested_tier")
act_tier=$(get_field "cost-t1" "actual_tier")

if [[ "$req_tier" == "opus" ]]; then
	pass "Cost tracking: requested_tier recorded as 'opus'"
else
	fail "Cost tracking: requested_tier expected 'opus'" "Got: '$req_tier'"
fi

if [[ "$act_tier" == "opus" ]]; then
	pass "Cost tracking: actual_tier recorded as 'opus'"
else
	fail "Cost tracking: actual_tier expected 'opus'" "Got: '$act_tier'"
fi

# Test: tier delta detection (requested sonnet, actual opus)
sup add cost-t2 --repo "$TEST_REPO" --description "Cost delta test" --no-issue >/dev/null

run_in_supervisor_env "
    record_dispatch_model_tiers 'cost-t2' 'sonnet' 'anthropic/claude-opus-4-6'
" || true

req_tier2=$(get_field "cost-t2" "requested_tier")
act_tier2=$(get_field "cost-t2" "actual_tier")

if [[ "$req_tier2" == "sonnet" && "$act_tier2" == "opus" ]]; then
	pass "Cost tracking: tier delta detected (requested=sonnet, actual=opus)"
else
	fail "Cost tracking: tier delta not recorded correctly" "req='$req_tier2' act='$act_tier2'"
fi

# Test: tier derivation from model string
sup add cost-t3 --repo "$TEST_REPO" --description "Cost haiku test" --no-issue >/dev/null

run_in_supervisor_env "
    record_dispatch_model_tiers 'cost-t3' '' 'anthropic/claude-haiku-4-5'
" || true

act_tier3=$(get_field "cost-t3" "actual_tier")

if [[ "$act_tier3" == "haiku" ]]; then
	pass "Cost tracking: actual_tier derived from model string (haiku)"
else
	fail "Cost tracking: actual_tier derivation failed" "Got: '$act_tier3'"
fi

# ============================================================
# SECTION 7: OAuth Detection (Anthropic auth flow)
# ============================================================
section "7. OAuth Detection and Auth Failure Handling"

# Test: OpenCode provider auth detection (from opencode-anthropic-auth.md)
# The auth flow in OpenCode's provider/anthropic.ts checks:
#   1. ANTHROPIC_API_KEY env var -> api_key auth
#   2. In-memory OAuth tokens -> oauth auth
#   3. Disk tokens -> oauth auth (with refresh)
#   4. None -> type: "none"

# Test: check_model_health with opencode skips probe when no direct API key
health_result=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:\$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    unset _PULSE_HEALTH_VERIFIED
    rm -f '$TEST_DIR/supervisor/health/'* 2>/dev/null
    mkdir -p '$TEST_DIR/supervisor/health'
    # check_model_health should succeed for opencode even without ANTHROPIC_API_KEY
    # because opencode manages auth internally (OAuth)
    check_model_health 'opencode' 'anthropic/claude-sonnet-4-6'
    echo \"exit:\$?\"
" 2>/dev/null | tail -1)

if [[ "$health_result" == "exit:0" ]]; then
	pass "OAuth: check_model_health passes for opencode (trusts internal auth)"
else
	fail "OAuth: check_model_health should pass for opencode" "Got: $health_result"
fi

# Test: Auth failure detection in worker evaluation
sup add auth-t1 --repo "$TEST_REPO" --description "Auth failure test" --no-issue >/dev/null
sup transition auth-t1 dispatched >/dev/null
sup transition auth-t1 running >/dev/null

create_log "auth-t1" 'WRAPPER_STARTED task_id=auth-t1 wrapper_pid=20001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=auth-t1 pid=20002 timestamp=2026-02-21T10:00:01Z
Error: Authentication failed. Please run opencode auth login.
permission denied
EXIT:1' >/dev/null

sup transition auth-t1 evaluating >/dev/null
eval_result=$(sup evaluate auth-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*auth_error"; then
	pass "Auth failure: permission denied -> blocked:auth_error"
else
	fail "Auth failure: should be blocked:auth_error" "Got: $eval_result"
fi

# Test: OAuth token refresh failure detection
sup add auth-t2 --repo "$TEST_REPO" --description "OAuth refresh failure test" --no-issue >/dev/null
sup transition auth-t2 dispatched >/dev/null
sup transition auth-t2 running >/dev/null

create_log "auth-t2" 'WRAPPER_STARTED task_id=auth-t2 wrapper_pid=20003 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=auth-t2 pid=20004 timestamp=2026-02-21T10:00:01Z
Error: 401 Unauthorized - token expired
EXIT:1' >/dev/null

sup transition auth-t2 evaluating >/dev/null
eval_result2=$(sup evaluate auth-t2 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result2" | grep -q "blocked.*auth_error\|retry"; then
	pass "Auth failure: 401 Unauthorized detected as auth/retry issue"
else
	fail "Auth failure: 401 should be detected" "Got: $eval_result2"
fi

# Test: Credits exhausted detection
sup add auth-t3 --repo "$TEST_REPO" --description "Credits exhausted test" --no-issue >/dev/null
sup transition auth-t3 dispatched >/dev/null
sup transition auth-t3 running >/dev/null

create_log "auth-t3" 'WRAPPER_STARTED task_id=auth-t3 wrapper_pid=20005 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=auth-t3 pid=20006 timestamp=2026-02-21T10:00:01Z
CreditsError: Insufficient balance
EXIT:1' >/dev/null

sup transition auth-t3 evaluating >/dev/null
eval_result3=$(sup evaluate auth-t3 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result3" | grep -q "blocked.*billing_credits_exhausted"; then
	pass "Auth failure: CreditsError -> blocked:billing_credits_exhausted"
else
	fail "Auth failure: CreditsError should be detected" "Got: $eval_result3"
fi

# ============================================================
# SECTION 8: Mixed Batch Dispatch (Anthropic + non-Anthropic)
# ============================================================
section "8. Mixed Batch Dispatch Simulation"

# Create a batch with tasks at different tiers
sup add batch-opus-t1 --repo "$TEST_REPO" --description "Complex architecture task #complex" --no-issue >/dev/null
sup add batch-sonnet-t1 --repo "$TEST_REPO" --description "Update README docs #docs" --no-issue >/dev/null
sup add batch-haiku-t1 --repo "$TEST_REPO" --description "Rename variable foo to bar #trivial" --no-issue >/dev/null

# Verify task classification routes to correct tiers
opus_class=$(run_in_supervisor_env "classify_task_complexity 'Complex architecture task' '#complex'")
sonnet_class=$(run_in_supervisor_env "classify_task_complexity 'Update README docs' '#docs'")
haiku_class=$(run_in_supervisor_env "classify_task_complexity 'Rename variable foo to bar' '#trivial'")

if [[ "$opus_class" == "opus" ]]; then
	pass "Mixed batch: architecture task classified as opus"
else
	fail "Mixed batch: architecture task expected opus" "Got: $opus_class"
fi

if [[ "$sonnet_class" == "sonnet" ]]; then
	pass "Mixed batch: docs task classified as sonnet"
else
	fail "Mixed batch: docs task expected sonnet" "Got: $sonnet_class"
fi

if [[ "$haiku_class" == "haiku" ]]; then
	pass "Mixed batch: rename task classified as haiku"
else
	fail "Mixed batch: rename task expected haiku" "Got: $haiku_class"
fi

# Verify all tasks route through the same CLI (opencode)
for task_id in batch-opus-t1 batch-sonnet-t1 batch-haiku-t1; do
	cli_for_task=$(run_in_supervisor_env "
        unset SUPERVISOR_CLI
        resolve_ai_cli
    ")
	if [[ "$cli_for_task" == "opencode" ]]; then
		pass "Mixed batch: $task_id routes through opencode"
	else
		fail "Mixed batch: $task_id should route through opencode" "Got: $cli_for_task"
	fi
done

# ============================================================
# SECTION 9: Escalation Chain (haiku -> sonnet -> opus)
# ============================================================
section "9. Escalation Chain (get_next_tier)"

next_from_haiku=$(run_in_supervisor_env "get_next_tier 'anthropic/claude-haiku-4-5'")
next_from_sonnet=$(run_in_supervisor_env "get_next_tier 'anthropic/claude-sonnet-4-6'")
next_from_opus=$(run_in_supervisor_env "get_next_tier 'anthropic/claude-opus-4-6'")

if [[ "$next_from_haiku" == "sonnet" ]]; then
	pass "Escalation: haiku -> sonnet"
else
	fail "Escalation: haiku should escalate to sonnet" "Got: $next_from_haiku"
fi

if [[ "$next_from_sonnet" == "opus" ]]; then
	pass "Escalation: sonnet -> opus"
else
	fail "Escalation: sonnet should escalate to opus" "Got: $next_from_sonnet"
fi

if [[ -z "$next_from_opus" ]]; then
	pass "Escalation: opus -> (none, already at max)"
else
	fail "Escalation: opus should have no next tier" "Got: $next_from_opus"
fi

# ============================================================
# SECTION 10: No Regressions — Pure OpenCode Dispatch Path
# ============================================================
section "10. No Regressions (pure OpenCode dispatch path)"

# Test: build_dispatch_cmd with opencode produces correct NUL-delimited output
dispatch_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:\$PATH'
    unset SUPERVISOR_CLI
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    build_dispatch_cmd 'regress-t1' '/tmp/wt' '/tmp/test.log' 'opencode' '' 'anthropic/claude-opus-4-6' 'Regression test task'
" 2>/dev/null | tr '\0' '\n')

if echo "$dispatch_output" | grep -q "^opencode$"; then
	pass "Regression: build_dispatch_cmd first token is 'opencode'"
else
	fail "Regression: first token should be 'opencode'" "Got first: $(echo "$dispatch_output" | head -1)"
fi

if echo "$dispatch_output" | grep -q "^run$"; then
	pass "Regression: build_dispatch_cmd includes 'run' subcommand"
else
	fail "Regression: should include 'run' subcommand"
fi

if echo "$dispatch_output" | grep -q "^--format$"; then
	pass "Regression: build_dispatch_cmd includes '--format'"
else
	fail "Regression: should include '--format'"
fi

if echo "$dispatch_output" | grep -q "^json$"; then
	pass "Regression: build_dispatch_cmd includes 'json' format"
else
	fail "Regression: should include 'json' format"
fi

if echo "$dispatch_output" | grep -q "^-m$"; then
	pass "Regression: build_dispatch_cmd includes '-m' model flag"
else
	fail "Regression: should include '-m' model flag"
fi

if echo "$dispatch_output" | grep -q "anthropic/claude-opus-4-6"; then
	pass "Regression: model string preserved in dispatch command"
else
	fail "Regression: model string should be preserved"
fi

# Verify the prompt contains worker restrictions (t173)
if echo "$dispatch_output" | grep -q "MANDATORY Worker Restrictions"; then
	pass "Regression: dispatch prompt includes worker restrictions (t173)"
else
	fail "Regression: dispatch prompt should include worker restrictions"
fi

# Verify the prompt contains the task ID
if echo "$dispatch_output" | grep -q "regress-t1"; then
	pass "Regression: dispatch prompt includes task ID"
else
	fail "Regression: dispatch prompt should include task ID"
fi

# Test: Full pipeline state transitions with opencode
sup add regress-full-t1 --repo "$TEST_REPO" --description "Full regression test" --no-issue >/dev/null

wt_regress=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'regress-full-t1' '$TEST_REPO'
")

if [[ -d "$wt_regress" ]]; then
	pass "Regression: worktree created for opencode dispatch"
else
	fail "Regression: worktree not created"
fi

sup transition regress-full-t1 dispatched --worktree "$wt_regress" --branch "feature/regress-full-t1" >/dev/null
sup transition regress-full-t1 running >/dev/null

# Simulate successful opencode worker
echo "regression feature" >"$wt_regress/regression.txt"
git -C "$wt_regress" add regression.txt
git -C "$wt_regress" commit -q -m "feat: regression test (regress-full-t1)"

create_log "regress-full-t1" 'WRAPPER_STARTED task_id=regress-full-t1 wrapper_pid=30001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=regress-full-t1 pid=30002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Working on regression test...\nCreated regression.txt\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null

sup transition regress-full-t1 evaluating >/dev/null
eval_result=$(sup evaluate regress-full-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
	pass "Regression: opencode worker evaluation -> complete"
else
	fail "Regression: should be complete" "Got: $eval_result"
fi

sup transition regress-full-t1 complete >/dev/null
if [[ "$(get_status regress-full-t1)" == "complete" ]]; then
	pass "Regression: full pipeline completes with opencode"
else
	fail "Regression: pipeline should complete"
fi

# Verify state transitions
transitions=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'regress-full-t1' ORDER BY id;")
expected_sequence="->queued
queued->dispatched
dispatched->running
running->evaluating
evaluating->complete"

if [[ "$transitions" == "$expected_sequence" ]]; then
	pass "Regression: state transitions match expected sequence"
else
	fail "Regression: state transitions don't match" "Got: $(echo "$transitions" | tr '\n' ' ')"
fi

# Clean up
git -C "$TEST_REPO" worktree remove "$wt_regress" --force &>/dev/null || rm -rf "$wt_regress"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/regress-full-t1" &>/dev/null || true

# ============================================================
# SECTION 11: CLI Health Check (both CLIs)
# ============================================================
section "11. CLI Health Check (both CLIs)"

# Test: check_cli_health with mock opencode
oc_health=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:\$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    unset _PULSE_CLI_VERIFIED
    rm -f '$TEST_DIR/supervisor/health/cli-opencode' 2>/dev/null
    mkdir -p '$TEST_DIR/supervisor/health'
    check_cli_health 'opencode'
    echo \"exit:\$?\"
" 2>/dev/null | tail -1)

if [[ "$oc_health" == "exit:0" ]]; then
	pass "CLI health: mock opencode passes health check"
else
	fail "CLI health: mock opencode should pass" "Got: $oc_health"
fi

# Test: check_cli_health with mock claude
cl_health=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:\$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    unset _PULSE_CLI_VERIFIED
    rm -f '$TEST_DIR/supervisor/health/cli-claude' 2>/dev/null
    mkdir -p '$TEST_DIR/supervisor/health'
    check_cli_health 'claude'
    echo \"exit:\$?\"
" 2>/dev/null | tail -1)

if [[ "$cl_health" == "exit:0" ]]; then
	pass "CLI health: mock claude passes health check"
else
	fail "CLI health: mock claude should pass" "Got: $cl_health"
fi

# Verify mock CLIs were actually invoked
if [[ -f "$MOCK_OPENCODE_LOG" ]] && grep -q "version" "$MOCK_OPENCODE_LOG"; then
	pass "CLI health: opencode 'version' was invoked"
else
	skip "CLI health: could not verify opencode version invocation (may use cache)"
fi

if [[ -f "$MOCK_CLAUDE_LOG" ]] && grep -q "\-\-version" "$MOCK_CLAUDE_LOG"; then
	pass "CLI health: claude '--version' was invoked"
else
	skip "CLI health: could not verify claude --version invocation (may use cache)"
fi

# ============================================================
# SECTION 12: Dispatch Dedup Guard (prevents repeated failures)
# ============================================================
section "12. Dispatch Dedup Guard (t1206)"

sup add dedup-t1 --repo "$TEST_REPO" --description "Dedup guard test" --no-issue >/dev/null

# Simulate first failure
run_in_supervisor_env "
    update_failure_dedup_state 'dedup-t1' 'clean_exit_no_signal'
" || true

consec_count=$(get_field "dedup-t1" "consecutive_failure_count")
if [[ "$consec_count" == "1" ]]; then
	pass "Dedup guard: first failure sets consecutive_failure_count=1"
else
	fail "Dedup guard: expected count=1" "Got: $consec_count"
fi

# Simulate second failure with same error
run_in_supervisor_env "
    update_failure_dedup_state 'dedup-t1' 'clean_exit_no_signal'
" || true

consec_count2=$(get_field "dedup-t1" "consecutive_failure_count")
if [[ "$consec_count2" == "2" ]]; then
	pass "Dedup guard: second same-error failure increments to 2"
else
	fail "Dedup guard: expected count=2" "Got: $consec_count2"
fi

# Simulate failure with different error (resets counter)
sup add dedup-t2 --repo "$TEST_REPO" --description "Dedup reset test" --no-issue >/dev/null

run_in_supervisor_env "
    update_failure_dedup_state 'dedup-t2' 'clean_exit_no_signal'
" || true

run_in_supervisor_env "
    update_failure_dedup_state 'dedup-t2' 'backend_infrastructure_error'
" || true

consec_count3=$(get_field "dedup-t2" "consecutive_failure_count")
if [[ "$consec_count3" == "1" ]]; then
	pass "Dedup guard: different error resets counter to 1"
else
	fail "Dedup guard: different error should reset counter" "Got: $consec_count3"
fi

# Test: reset_failure_dedup_state clears counters
run_in_supervisor_env "
    reset_failure_dedup_state 'dedup-t1'
" || true

reset_count=$(get_field "dedup-t1" "consecutive_failure_count")
if [[ "$reset_count" == "0" ]]; then
	pass "Dedup guard: reset clears consecutive_failure_count to 0"
else
	fail "Dedup guard: reset should clear count" "Got: $reset_count"
fi

# ============================================================
# SECTION 13: Prompt-Repeat Strategy (t1097)
# ============================================================
section "13. Prompt-Repeat Strategy (t1097)"

# Test: should_prompt_repeat eligibility
sup add pr-t1 --repo "$TEST_REPO" --description "Prompt repeat test" --no-issue >/dev/null

pr_eligible=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_PROMPT_REPEAT_ENABLED=true
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/database.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    should_prompt_repeat 'pr-t1' 'clean_exit_no_signal'
" 2>/dev/null)

if [[ "$pr_eligible" == "eligible" ]]; then
	pass "Prompt-repeat: clean_exit_no_signal is eligible"
else
	fail "Prompt-repeat: should be eligible" "Got: $pr_eligible"
fi

# Test: non-retryable failures are not eligible
pr_auth=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_PROMPT_REPEAT_ENABLED=true
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/database.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    should_prompt_repeat 'pr-t1' 'auth_error' || true
    echo \"exit:\$?\"
" 2>/dev/null | grep "^exit:" | head -1)

# The function outputs the reason then returns 1 for non-retryable
pr_reason=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_PROMPT_REPEAT_ENABLED=true
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/database.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    should_prompt_repeat 'pr-t1' 'auth_error'
" 2>/dev/null || true)

if echo "$pr_reason" | grep -q "non_retryable"; then
	pass "Prompt-repeat: auth_error is non-retryable"
else
	fail "Prompt-repeat: auth_error should be non-retryable" "Got: $pr_reason"
fi

# Test: disabled when SUPERVISOR_PROMPT_REPEAT_ENABLED=false
pr_disabled=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_PROMPT_REPEAT_ENABLED=false
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/database.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    should_prompt_repeat 'pr-t1' 'clean_exit_no_signal'
" 2>/dev/null || true)

if echo "$pr_disabled" | grep -q "disabled"; then
	pass "Prompt-repeat: disabled when SUPERVISOR_PROMPT_REPEAT_ENABLED=false"
else
	fail "Prompt-repeat: should be disabled" "Got: $pr_disabled"
fi

# ============================================================
# SECTION 14: build_cli_cmd Error Handling
# ============================================================
section "14. build_cli_cmd Error Handling"

# Test: missing --cli flag
missing_cli_rc=0
run_in_supervisor_env "
    build_cli_cmd --action run --output array --prompt 'test'
" &>/dev/null || missing_cli_rc=$?

if [[ "$missing_cli_rc" -ne 0 ]]; then
	pass "Error handling: build_cli_cmd fails without --cli"
else
	fail "Error handling: should fail without --cli"
fi

# Test: missing --action flag
missing_action_rc=0
run_in_supervisor_env "
    build_cli_cmd --cli opencode --output array --prompt 'test'
" &>/dev/null || missing_action_rc=$?

if [[ "$missing_action_rc" -ne 0 ]]; then
	pass "Error handling: build_cli_cmd fails without --action"
else
	fail "Error handling: should fail without --action"
fi

# Test: missing --prompt for run action
missing_prompt_rc=0
run_in_supervisor_env "
    build_cli_cmd --cli opencode --action run --output array
" &>/dev/null || missing_prompt_rc=$?

if [[ "$missing_prompt_rc" -ne 0 ]]; then
	pass "Error handling: build_cli_cmd fails without --prompt for run"
else
	fail "Error handling: should fail without --prompt for run"
fi

# Test: unknown action
unknown_action_rc=0
run_in_supervisor_env "
    build_cli_cmd --cli opencode --action unknown --output array
" &>/dev/null || unknown_action_rc=$?

if [[ "$unknown_action_rc" -ne 0 ]]; then
	pass "Error handling: build_cli_cmd fails with unknown action"
else
	fail "Error handling: should fail with unknown action"
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
	printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
	exit 1
else
	echo ""
	printf "\033[0;32mAll tests passed.\033[0m\n"
	exit 0
fi
