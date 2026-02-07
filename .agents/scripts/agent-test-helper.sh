#!/usr/bin/env bash
# agent-test-helper.sh - Agent testing framework with isolated AI sessions
#
# Test agent changes by running prompts through isolated AI sessions and
# validating responses against expected patterns. Supports before/after
# comparison for agent modifications.
#
# Usage:
#   agent-test-helper.sh run <test-file>           # Run a test suite
#   agent-test-helper.sh run-one "prompt" [--expect "pattern"] [--agent name]
#   agent-test-helper.sh compare <test-file>        # Compare current vs baseline
#   agent-test-helper.sh baseline <test-file>       # Save current results as baseline
#   agent-test-helper.sh list                       # List available test suites
#   agent-test-helper.sh create <name>              # Create test suite template
#   agent-test-helper.sh results [test-name]        # Show recent results
#   agent-test-helper.sh help                       # Show this help
#
# Test Suite Format (JSON):
#   {
#     "name": "build-agent-tests",
#     "description": "Tests for build-agent subagent",
#     "agent": "Build+",
#     "model": "anthropic/claude-sonnet-4-20250514",
#     "timeout": 120,
#     "tests": [
#       {
#         "id": "t1",
#         "prompt": "What is the instruction budget for agents?",
#         "expect_contains": ["50-100", "instructions"],
#         "expect_not_contains": ["unlimited"],
#         "expect_regex": "\\d+-\\d+ instructions"
#       }
#     ]
#   }
#
# Environment:
#   AGENT_TEST_CLI      - CLI to use: "claude" or "opencode" (default: auto-detect)
#   AGENT_TEST_MODEL    - Override model for all tests
#   AGENT_TEST_TIMEOUT  - Override timeout in seconds (default: 120)
#   OPENCODE_HOST       - OpenCode server host (default: localhost)
#   OPENCODE_PORT       - OpenCode server port (default: 4096)
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck disable=SC2034
readonly SCRIPT_DIR
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true
readonly AIDEVOPS_DIR="${HOME}/.aidevops"
readonly WORKSPACE_DIR="${AIDEVOPS_DIR}/.agent-workspace"
readonly TEST_DIR="${WORKSPACE_DIR}/agent-tests"
readonly SUITES_DIR="${TEST_DIR}/suites"
readonly RESULTS_DIR="${TEST_DIR}/results"
readonly BASELINES_DIR="${TEST_DIR}/baselines"

# CLI detection
detect_cli() {
    local cli="${AGENT_TEST_CLI:-}"
    if [[ -n "$cli" ]]; then
        echo "$cli"
        return 0
    fi
    if command -v claude >/dev/null 2>&1; then
        echo "claude"
    elif command -v opencode >/dev/null 2>&1; then
        echo "opencode"
    else
        echo ""
    fi
}

AI_CLI="$(detect_cli)"
readonly AI_CLI

# OpenCode server defaults (localhost-only, HTTP is intentional for local dev server)
readonly OPENCODE_HOST="${OPENCODE_HOST:-localhost}"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_URL="http://${OPENCODE_HOST}:${OPENCODE_PORT}" # NOSONAR - localhost dev server, no TLS needed

readonly BOLD='\033[1m'
readonly DIM='\033[2m'

# Logging
log_info() { echo -e "${BLUE}[TEST]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_header() { echo -e "${PURPLE}${BOLD}$*${NC}"; }


#######################################
# Ensure workspace directories exist
#######################################
ensure_dirs() {
    mkdir -p "$SUITES_DIR" "$RESULTS_DIR" "$BASELINES_DIR"
    return 0
}

#######################################
# Check if OpenCode server is running
#######################################
check_opencode_server() {
    # NOSONAR - localhost dev server health check, HTTP is intentional
    if curl -s --max-time 3 "${OPENCODE_URL}/global/health" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

#######################################
# Run a prompt through the AI CLI
# Arguments:
#   $1 - prompt text
#   $2 - agent name (optional)
#   $3 - model override (optional)
#   $4 - timeout in seconds (optional)
# Returns:
#   Response text on stdout
#######################################
run_prompt() {
    local prompt="$1"
    local agent="${2:-}"
    local model="${3:-${AGENT_TEST_MODEL:-}}"
    local timeout="${4:-$DEFAULT_TIMEOUT}"

    case "$AI_CLI" in
        claude)
            run_prompt_claude "$prompt" "$agent" "$model" "$timeout"
            ;;
        opencode)
            run_prompt_opencode "$prompt" "$agent" "$model" "$timeout"
            ;;
        *)
            log_fail "No AI CLI available. Install claude or opencode."
            return 1
            ;;
    esac
}

#######################################
# Run prompt via Claude Code CLI
#######################################
run_prompt_claude() {
    local prompt="$1"
    local agent="$2"
    local model="$3"
    local timeout="$4"

    local cmd=(claude -p)

    if [[ -n "$model" ]]; then
        cmd+=(--model "$model")
    fi

    # Claude Code doesn't have --agent flag, but we can prepend agent context
    if [[ -n "$agent" ]]; then
        prompt="You are acting as the ${agent} agent. ${prompt}"
    fi

    # Run with timeout
    local stderr_file
    stderr_file=$(mktemp)
    timeout "${timeout}" "${cmd[@]}" "$prompt" 2>"$stderr_file" || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "[TIMEOUT after ${timeout}s]"
        elif [[ -s "$stderr_file" ]]; then
            echo "[ERROR: $(cat "$stderr_file")]"
        fi
        rm -f "$stderr_file"
        return $exit_code
    }
    rm -f "$stderr_file"
}

#######################################
# Run prompt via OpenCode CLI
#######################################
run_prompt_opencode() {
    local prompt="$1"
    local agent="$2"
    local model="$3"
    local timeout="$4"

    # Try server mode first, fall back to CLI
    if check_opencode_server; then
        run_prompt_opencode_server "$prompt" "$agent" "$model" "$timeout"
    else
        run_prompt_opencode_cli "$prompt" "$agent" "$model" "$timeout"
    fi
}

#######################################
# Run prompt via OpenCode server API
#######################################
run_prompt_opencode_server() {
    local prompt="$1"
    local agent="$2"
    local model="$3"
    local timeout="$4"

    # Create session
    local session_payload
    session_payload=$(jq -n --arg title "agent-test-$(date +%s)" '{"title": $title}')
    local session_response
    # NOSONAR - localhost dev server API call, HTTP is intentional
    session_response=$(curl -s --max-time 10 -X POST "${OPENCODE_URL}/session" \
        -H "Content-Type: application/json" \
        -d "$session_payload")

    local session_id
    session_id=$(echo "$session_response" | jq -r '.id // empty' 2>/dev/null)

    if [[ -z "$session_id" ]]; then
        log_warn "Failed to create server session, falling back to CLI"
        run_prompt_opencode_cli "$prompt" "$agent" "$model" "$timeout"
        return $?
    fi

    # Send prompt
    local prompt_json
    prompt_json=$(jq -n --arg text "$prompt" '{"parts": [{"type": "text", "text": $text}]}')

    local response
    # NOSONAR - localhost dev server API call, HTTP is intentional
    response=$(curl -s --max-time "$timeout" -X POST \
        "${OPENCODE_URL}/session/${session_id}/message" \
        -H "Content-Type: application/json" \
        -d "$prompt_json")

    # Extract text from response
    local result
    result=$(echo "$response" | jq -r '.parts[]? | select(.type == "text") | .text' 2>/dev/null)

    if [[ -z "$result" ]]; then
        result=$(echo "$response" | jq -r '.content // .text // .message // empty' 2>/dev/null)
    fi

    # Clean up session (NOSONAR - localhost dev server, HTTP is intentional)
    curl -s -X DELETE "${OPENCODE_URL}/session/${session_id}" > /dev/null 2>&1 || true

    echo "$result"
    return 0
}

#######################################
# Run prompt via OpenCode CLI directly
#######################################
run_prompt_opencode_cli() {
    local prompt="$1"
    local agent="$2"
    local model="$3"
    local timeout="$4"

    local cmd=(opencode run)

    if [[ -n "$agent" ]]; then
        cmd+=(--agent "$agent")
    fi

    if [[ -n "$model" ]]; then
        cmd+=(-m "$model")
    fi

    local stderr_file
    stderr_file=$(mktemp)
    timeout "${timeout}" "${cmd[@]}" "$prompt" 2>"$stderr_file" || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "[TIMEOUT after ${timeout}s]"
        elif [[ -s "$stderr_file" ]]; then
            echo "[ERROR: $(cat "$stderr_file")]"
        fi
        rm -f "$stderr_file"
        return $exit_code
    }
    rm -f "$stderr_file"
}

#######################################
# Validate response against expectations
# Arguments:
#   $1 - response text
#   $2 - test JSON object
# Returns:
#   0 if all checks pass, 1 otherwise
#######################################
validate_response() {
    local response="$1"
    local test_json="$2"
    local failures=0

    # Check expect_contains
    local contains
    contains=$(echo "$test_json" | jq -r '.expect_contains[]? // empty' 2>/dev/null)
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if ! echo "$response" | grep -qi "$pattern"; then
            log_fail "  Expected to contain: \"$pattern\""
            failures=$((failures + 1))
        fi
    done <<< "$contains"

    # Check expect_not_contains
    local not_contains
    not_contains=$(echo "$test_json" | jq -r '.expect_not_contains[]? // empty' 2>/dev/null)
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if echo "$response" | grep -qi "$pattern"; then
            log_fail "  Expected NOT to contain: \"$pattern\""
            failures=$((failures + 1))
        fi
    done <<< "$not_contains"

    # Check expect_regex
    local regex
    regex=$(echo "$test_json" | jq -r '.expect_regex // empty' 2>/dev/null)
    if [[ -n "$regex" ]]; then
        if ! echo "$response" | grep -qEi "$regex"; then
            log_fail "  Expected to match regex: \"$regex\""
            failures=$((failures + 1))
        fi
    fi

    # Check expect_not_regex
    local not_regex
    not_regex=$(echo "$test_json" | jq -r '.expect_not_regex // empty' 2>/dev/null)
    if [[ -n "$not_regex" ]]; then
        if echo "$response" | grep -qEi "$not_regex"; then
            log_fail "  Expected NOT to match regex: \"$not_regex\""
            failures=$((failures + 1))
        fi
    fi

    # Check min_length
    local min_length
    min_length=$(echo "$test_json" | jq -r '.min_length // empty' 2>/dev/null)
    if [[ -n "$min_length" ]]; then
        local actual_length
        actual_length=${#response}
        if [[ $actual_length -lt $min_length ]]; then
            log_fail "  Response too short: ${actual_length} < ${min_length} chars"
            failures=$((failures + 1))
        fi
    fi

    # Check max_length
    local max_length
    max_length=$(echo "$test_json" | jq -r '.max_length // empty' 2>/dev/null)
    if [[ -n "$max_length" ]]; then
        local actual_length
        actual_length=${#response}
        if [[ $actual_length -gt $max_length ]]; then
            log_fail "  Response too long: ${actual_length} > ${max_length} chars"
            failures=$((failures + 1))
        fi
    fi

    if [[ $failures -eq 0 ]]; then
        return 0
    fi
    return 1
}

#######################################
# RUN command - execute a test suite
#######################################
cmd_run() {
    local test_file="$1"
    ensure_dirs

    # Resolve test file path
    if [[ ! -f "$test_file" ]]; then
        if [[ -f "${SUITES_DIR}/${test_file}" ]]; then
            test_file="${SUITES_DIR}/${test_file}"
        elif [[ -f "${SUITES_DIR}/${test_file}.json" ]]; then
            test_file="${SUITES_DIR}/${test_file}.json"
        else
            log_fail "Test file not found: $test_file"
            return 1
        fi
    fi

    # Parse test suite
    local suite
    suite=$(cat "$test_file")

    local suite_name
    suite_name=$(echo "$suite" | jq -r '.name // "unnamed"')
    local suite_desc
    suite_desc=$(echo "$suite" | jq -r '.description // ""')
    local suite_agent
    suite_agent=$(echo "$suite" | jq -r '.agent // ""')
    local suite_model
    suite_model=$(echo "$suite" | jq -r '.model // ""')
    local suite_timeout
    suite_timeout=$(echo "$suite" | jq -r '.timeout // 120')

    local test_count
    test_count=$(echo "$suite" | jq '.tests | length')

    log_header "Test Suite: ${suite_name}"
    if [[ -n "$suite_desc" ]]; then
        echo -e "${DIM}${suite_desc}${NC}"
    fi
    echo ""
    log_info "CLI: ${AI_CLI:-none}"
    log_info "Agent: ${suite_agent:-default}"
    log_info "Tests: ${test_count}"
    echo ""

    if [[ -z "$AI_CLI" ]]; then
        log_fail "No AI CLI available. Install claude or opencode."
        return 1
    fi

    local passed=0
    local failed=0
    local skipped=0
    local start_time
    start_time=$(date +%s)

    # Results array for JSON output
    local results="[]"

    # Run each test
    local i=0
    while [[ $i -lt $test_count ]]; do
        local test_json
        test_json=$(echo "$suite" | jq -c ".tests[$i]")

        local test_id
        test_id=$(echo "$test_json" | jq -r '.id // "test-'"$i"'"')
        local test_prompt
        test_prompt=$(echo "$test_json" | jq -r '.prompt')
        local test_agent
        test_agent=$(echo "$test_json" | jq -r '.agent // empty')
        local test_model
        test_model=$(echo "$test_json" | jq -r '.model // empty')
        local test_timeout
        test_timeout=$(echo "$test_json" | jq -r '.timeout // empty')
        local test_skip
        test_skip=$(echo "$test_json" | jq -r '.skip // false')

        # Use suite defaults if test doesn't override
        test_agent="${test_agent:-$suite_agent}"
        test_model="${test_model:-$suite_model}"
        test_timeout="${test_timeout:-$suite_timeout}"

        echo -e "${BOLD}[$((i+1))/${test_count}] ${test_id}${NC}"

        if [[ "$test_skip" == "true" ]]; then
            echo -e "  ${YELLOW}SKIPPED${NC}"
            skipped=$((skipped + 1))
            results=$(echo "$results" | jq --arg id "$test_id" --arg status "skipped" \
                '. + [{"id": $id, "status": $status}]')
            i=$((i + 1))
            continue
        fi

        echo -e "  ${DIM}Prompt: ${test_prompt:0:80}...${NC}"

        # Run the prompt
        local test_start
        test_start=$(date +%s)
        local response=""
        local run_status="pass"

        response=$(run_prompt "$test_prompt" "$test_agent" "$test_model" "$test_timeout" 2>&1) || {
            run_status="error"
        }

        local test_end
        test_end=$(date +%s)
        local test_duration=$((test_end - test_start))

        # Check for timeout/error
        if [[ "$run_status" == "error" ]] || echo "$response" | grep -q '^\[TIMEOUT'; then
            log_fail "  Error/timeout after ${test_duration}s"
            failed=$((failed + 1))
            results=$(echo "$results" | jq \
                --arg id "$test_id" \
                --arg status "fail" \
                --arg error "timeout_or_error" \
                --argjson duration "$test_duration" \
                '. + [{"id": $id, "status": $status, "error": $error, "duration": $duration}]')
            i=$((i + 1))
            continue
        fi

        # Validate response
        if validate_response "$response" "$test_json"; then
            log_pass "  Passed (${test_duration}s)"
            passed=$((passed + 1))
            run_status="pass"
        else
            failed=$((failed + 1))
            run_status="fail"
        fi

        # Store result
        local response_preview
        response_preview=$(echo "$response" | head -c 500)
        results=$(echo "$results" | jq \
            --arg id "$test_id" \
            --arg status "$run_status" \
            --arg response "$response_preview" \
            --argjson duration "$test_duration" \
            '. + [{"id": $id, "status": $status, "response_preview": $response, "duration": $duration}]')

        i=$((i + 1))
    done

    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    # Summary
    echo ""
    log_header "Results: ${suite_name}"
    echo -e "  ${GREEN}Passed: ${passed}${NC}"
    echo -e "  ${RED}Failed: ${failed}${NC}"
    if [[ $skipped -gt 0 ]]; then
        echo -e "  ${YELLOW}Skipped: ${skipped}${NC}"
    fi
    echo -e "  Total time: ${total_duration}s"
    echo ""

    # Save results
    local result_file
    result_file="${RESULTS_DIR}/${suite_name}-$(date +%Y%m%d-%H%M%S).json"
    jq -n \
        --arg name "$suite_name" \
        --arg cli "$AI_CLI" \
        --arg agent "$suite_agent" \
        --arg model "$suite_model" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson skipped "$skipped" \
        --argjson duration "$total_duration" \
        --argjson results "$results" \
        '{
            name: $name,
            cli: $cli,
            agent: $agent,
            model: $model,
            timestamp: $timestamp,
            summary: {passed: $passed, failed: $failed, skipped: $skipped, duration: $duration},
            results: $results
        }' > "$result_file"

    log_info "Results saved: $result_file"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

#######################################
# RUN-ONE command - run a single prompt test
#######################################
cmd_run_one() {
    local prompt=""
    local expect=""
    local agent=""
    local model=""
    local timeout="$DEFAULT_TIMEOUT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expect) expect="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --model) model="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            *)
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$prompt" ]]; then
        log_fail "Usage: agent-test-helper.sh run-one \"prompt\" [--expect \"pattern\"]"
        return 1
    fi

    if [[ -z "$AI_CLI" ]]; then
        log_fail "No AI CLI available. Install claude or opencode."
        return 1
    fi

    log_header "Single Test"
    echo -e "  ${DIM}Prompt: ${prompt:0:100}${NC}"
    echo -e "  ${DIM}CLI: ${AI_CLI}${NC}"
    echo ""

    local start_time
    start_time=$(date +%s)

    local response
    response=$(run_prompt "$prompt" "$agent" "$model" "$timeout" 2>&1) || true

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "${BOLD}Response (${duration}s):${NC}"
    echo "$response"
    echo ""

    if [[ -n "$expect" ]]; then
        if echo "$response" | grep -qi "$expect"; then
            log_pass "Contains expected pattern: \"$expect\""
        else
            log_fail "Missing expected pattern: \"$expect\""
            return 1
        fi
    fi

    return 0
}

#######################################
# COMPARE command - compare current vs baseline
#######################################
cmd_compare() {
    local test_file="$1"
    ensure_dirs

    # Resolve test file
    if [[ ! -f "$test_file" ]]; then
        if [[ -f "${SUITES_DIR}/${test_file}" ]]; then
            test_file="${SUITES_DIR}/${test_file}"
        elif [[ -f "${SUITES_DIR}/${test_file}.json" ]]; then
            test_file="${SUITES_DIR}/${test_file}.json"
        else
            log_fail "Test file not found: $test_file"
            return 1
        fi
    fi

    local suite_name
    suite_name=$(jq -r '.name // "unnamed"' "$test_file")

    # Check for baseline
    local baseline_file="${BASELINES_DIR}/${suite_name}.json"
    if [[ ! -f "$baseline_file" ]]; then
        log_warn "No baseline found for ${suite_name}"
        log_info "Run 'agent-test-helper.sh baseline ${test_file}' to create one"
        return 1
    fi

    log_header "Comparison: ${suite_name}"
    echo ""

    # Run current tests
    log_info "Running current tests..."
    cmd_run "$test_file" || true

    # Find most recent result
    local latest_result
    latest_result=$(find "$RESULTS_DIR" -name "${suite_name}-*.json" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1)

    if [[ -z "$latest_result" ]]; then
        log_fail "No results found after running tests"
        return 1
    fi

    # Compare
    local baseline_passed current_passed
    baseline_passed=$(jq '.summary.passed' "$baseline_file")
    current_passed=$(jq '.summary.passed' "$latest_result")

    local baseline_failed current_failed
    baseline_failed=$(jq '.summary.failed' "$baseline_file")
    current_failed=$(jq '.summary.failed' "$latest_result")

    echo ""
    log_header "Comparison Results"
    echo "  Baseline: ${baseline_passed} passed, ${baseline_failed} failed"
    echo "  Current:  ${current_passed} passed, ${current_failed} failed"
    echo ""

    if [[ "$current_failed" -lt "$baseline_failed" ]]; then
        log_pass "Improvement: fewer failures ($current_failed < $baseline_failed)"
    elif [[ "$current_failed" -gt "$baseline_failed" ]]; then
        log_fail "Regression: more failures ($current_failed > $baseline_failed)"
        return 1
    else
        log_info "No change in pass/fail counts"
    fi

    # Per-test comparison
    local test_count
    test_count=$(jq '.results | length' "$baseline_file")
    local regressions=0

    local j=0
    while [[ $j -lt $test_count ]]; do
        local test_id
        test_id=$(jq -r ".results[$j].id" "$baseline_file")
        local baseline_status
        baseline_status=$(jq -r ".results[$j].status" "$baseline_file")
        local current_status
        current_status=$(jq -r ".results[] | select(.id == \"$test_id\") | .status" "$latest_result" 2>/dev/null)

        if [[ -z "$current_status" ]]; then
            log_fail "  Missing: ${test_id} (in baseline but not in current run)"
            regressions=$((regressions + 1))
        elif [[ "$baseline_status" == "pass" && "$current_status" == "fail" ]]; then
            log_fail "  Regression: ${test_id} (was pass, now fail)"
            regressions=$((regressions + 1))
        elif [[ "$baseline_status" == "fail" && "$current_status" == "pass" ]]; then
            log_pass "  Fixed: ${test_id} (was fail, now pass)"
        fi

        j=$((j + 1))
    done

    if [[ $regressions -gt 0 ]]; then
        return 1
    fi
    return 0
}

#######################################
# BASELINE command - save current results as baseline
#######################################
cmd_baseline() {
    local test_file="$1"
    ensure_dirs

    # Resolve test file
    if [[ ! -f "$test_file" ]]; then
        if [[ -f "${SUITES_DIR}/${test_file}" ]]; then
            test_file="${SUITES_DIR}/${test_file}"
        elif [[ -f "${SUITES_DIR}/${test_file}.json" ]]; then
            test_file="${SUITES_DIR}/${test_file}.json"
        else
            log_fail "Test file not found: $test_file"
            return 1
        fi
    fi

    local suite_name
    suite_name=$(jq -r '.name // "unnamed"' "$test_file")

    log_info "Running tests to establish baseline..."
    cmd_run "$test_file" || true

    # Find most recent result
    local latest_result
    latest_result=$(find "$RESULTS_DIR" -name "${suite_name}-*.json" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1)

    if [[ -z "$latest_result" ]]; then
        log_fail "No results found after running tests"
        return 1
    fi

    # Copy as baseline
    local baseline_file="${BASELINES_DIR}/${suite_name}.json"
    cp "$latest_result" "$baseline_file"
    log_pass "Baseline saved: $baseline_file"

    return 0
}

#######################################
# LIST command - list available test suites
#######################################
cmd_list() {
    ensure_dirs

    log_header "Available Test Suites"
    echo ""

    local count=0
    for suite_file in "${SUITES_DIR}"/*.json; do
        [[ -f "$suite_file" ]] || continue

        local name desc test_count
        name=$(jq -r '.name // "unnamed"' "$suite_file")
        desc=$(jq -r '.description // ""' "$suite_file")
        test_count=$(jq '.tests | length' "$suite_file")

        echo -e "  ${BOLD}${name}${NC} (${test_count} tests)"
        if [[ -n "$desc" ]]; then
            echo -e "    ${DIM}${desc}${NC}"
        fi

        # Check for baseline
        if [[ -f "${BASELINES_DIR}/${name}.json" ]]; then
            echo -e "    ${GREEN}Baseline available${NC}"
        fi

        echo ""
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        log_info "No test suites found in ${SUITES_DIR}"
        log_info "Create one with: agent-test-helper.sh create <name>"
    fi

    return 0
}

#######################################
# CREATE command - create test suite template
#######################################
cmd_create() {
    local name="$1"
    ensure_dirs

    local suite_file="${SUITES_DIR}/${name}.json"

    if [[ -f "$suite_file" ]]; then
        log_warn "Test suite already exists: $suite_file"
        return 1
    fi

    cat > "$suite_file" << 'TEMPLATE'
{
  "name": "SUITE_NAME",
  "description": "Description of what this test suite validates",
  "agent": "",
  "model": "",
  "timeout": 120,
  "tests": [
    {
      "id": "t1",
      "prompt": "What is your primary purpose?",
      "expect_contains": ["help", "assist"],
      "expect_not_contains": ["error"],
      "min_length": 50
    },
    {
      "id": "t2",
      "prompt": "List the main features you support",
      "expect_contains": ["feature"],
      "min_length": 100
    }
  ]
}
TEMPLATE

    # Replace placeholder with actual name
    local safe_name
    safe_name="${name//[^a-zA-Z0-9_-]/-}"
    sed_inplace "s/SUITE_NAME/${safe_name}/" "$suite_file"

    log_pass "Created test suite: $suite_file"
    log_info "Edit the file to add your test cases, then run:"
    echo "  agent-test-helper.sh run ${name}"

    return 0
}

#######################################
# RESULTS command - show recent results
#######################################
cmd_results() {
    local filter="${1:-}"
    ensure_dirs

    log_header "Recent Test Results"
    echo ""

    local result_files
    if [[ -n "$filter" ]]; then
        result_files=$(find "$RESULTS_DIR" -name "${filter}*.json" -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null | head -10)
    else
        result_files=$(find "$RESULTS_DIR" -name "*.json" -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null | head -10)
    fi

    if [[ -z "$result_files" ]]; then
        log_info "No results found"
        return 0
    fi

    while IFS= read -r result_file; do
        local name timestamp passed failed duration
        name=$(jq -r '.name' "$result_file")
        timestamp=$(jq -r '.timestamp' "$result_file")
        passed=$(jq '.summary.passed' "$result_file")
        failed=$(jq '.summary.failed' "$result_file")
        duration=$(jq '.summary.duration' "$result_file")

        local status_color="$GREEN"
        if [[ "$failed" -gt 0 ]]; then
            status_color="$RED"
        fi

        echo -e "  ${BOLD}${name}${NC} @ ${DIM}${timestamp}${NC}"
        echo -e "    ${GREEN}${passed} passed${NC} ${status_color}${failed} failed${NC} (${duration}s)"
        echo ""
    done <<< "$result_files"

    return 0
}

#######################################
# HELP command
#######################################
cmd_help() {
    cat << 'EOF'
agent-test-helper.sh - Agent testing framework with isolated AI sessions

USAGE:
  agent-test-helper.sh <command> [options]

COMMANDS:
  run <test-file>           Run a test suite (JSON file or name in suites/)
  run-one "prompt"          Run a single prompt test
    --expect "pattern"        Expected pattern in response
    --agent <name>            Agent to use
    --model <model>           Model override
    --timeout <seconds>       Timeout (default: 120)
  compare <test-file>       Run tests and compare against baseline
  baseline <test-file>      Save current results as baseline
  list                      List available test suites
  create <name>             Create a test suite template
  results [name]            Show recent test results
  help                      Show this help

TEST SUITE FORMAT (JSON):
  {
    "name": "suite-name",
    "description": "What this tests",
    "agent": "Build+",
    "model": "anthropic/claude-sonnet-4-20250514",
    "timeout": 120,
    "tests": [
      {
        "id": "t1",
        "prompt": "Test prompt",
        "expect_contains": ["word1", "word2"],
        "expect_not_contains": ["bad-word"],
        "expect_regex": "pattern",
        "expect_not_regex": "bad-pattern",
        "min_length": 50,
        "max_length": 5000,
        "skip": false
      }
    ]
  }

ENVIRONMENT:
  AGENT_TEST_CLI      CLI to use: "claude" or "opencode" (auto-detected)
  AGENT_TEST_MODEL    Override model for all tests
  AGENT_TEST_TIMEOUT  Override timeout in seconds (default: 120)
  OPENCODE_HOST       OpenCode server host (default: localhost)
  OPENCODE_PORT       OpenCode server port (default: 4096)

EXAMPLES:
  # Create and run a test suite
  agent-test-helper.sh create my-tests
  agent-test-helper.sh run my-tests

  # Quick single-prompt test
  agent-test-helper.sh run-one "What tools do you have?" --expect "bash"

  # Before/after comparison
  agent-test-helper.sh baseline my-tests    # Save current as baseline
  # ... make agent changes ...
  agent-test-helper.sh compare my-tests     # Compare against baseline

  # View results
  agent-test-helper.sh results
EOF
    return 0
}

#######################################
# Main entry point
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        run)
            if [[ $# -lt 1 ]]; then
                log_fail "Usage: agent-test-helper.sh run <test-file>"
                return 1
            fi
            cmd_run "$1"
            ;;
        run-one)
            cmd_run_one "$@"
            ;;
        compare)
            if [[ $# -lt 1 ]]; then
                log_fail "Usage: agent-test-helper.sh compare <test-file>"
                return 1
            fi
            cmd_compare "$1"
            ;;
        baseline)
            if [[ $# -lt 1 ]]; then
                log_fail "Usage: agent-test-helper.sh baseline <test-file>"
                return 1
            fi
            cmd_baseline "$1"
            ;;
        list)
            cmd_list
            ;;
        create)
            if [[ $# -lt 1 ]]; then
                log_fail "Usage: agent-test-helper.sh create <name>"
                return 1
            fi
            cmd_create "$1"
            ;;
        results)
            cmd_results "${1:-}"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_fail "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
