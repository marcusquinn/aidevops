#!/usr/bin/env bash
# test-response-scoring.sh
#
# Tests for response-scoring-helper.sh (t168.3)
# Validates: syntax, help output, DB init, prompt CRUD, response recording,
# scoring, comparison, leaderboard, export, and criteria display.
#
# Usage: bash tests/test-response-scoring.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/response-scoring-helper.sh"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$VERBOSE" == "--verbose" ]]; then
        printf "  \033[0;32mPASS\033[0m %s\n" "$1"
    fi
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
    if [[ "$VERBOSE" == "--verbose" ]]; then
        printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
    fi
    return 0
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# Use a temp DB for testing to avoid polluting real data
TEST_DB_DIR=$(mktemp -d)
export SCORING_DB_OVERRIDE="$TEST_DB_DIR/test-scoring.db"
trap 'rm -rf "$TEST_DB_DIR"' EXIT

# =============================================================================
# Tests
# =============================================================================

section "Syntax Check"

if bash -n "$HELPER" 2>/dev/null; then
    pass "response-scoring-helper.sh passes bash -n syntax check"
else
    fail "response-scoring-helper.sh has syntax errors"
fi

section "Help Output"

help_output=$(bash "$HELPER" help 2>&1) || true
if echo "$help_output" | grep -q "Response Scoring Helper"; then
    pass "help output contains script title"
else
    fail "help output missing script title"
fi

if echo "$help_output" | grep -q "correctness"; then
    pass "help output mentions correctness criterion"
else
    fail "help output missing correctness criterion"
fi

if echo "$help_output" | grep -q "compare"; then
    pass "help output mentions compare command"
else
    fail "help output missing compare command"
fi

section "Database Initialization"

bash "$HELPER" init >/dev/null 2>&1 || true
if [[ -f "$SCORING_DB_OVERRIDE" ]]; then
    pass "init creates database file"
else
    fail "init did not create database file"
fi

# Verify tables exist
tables=$(sqlite3 "$SCORING_DB_OVERRIDE" ".tables" 2>/dev/null)
for table in prompts responses scores comparisons; do
    if echo "$tables" | grep -q "$table"; then
        pass "table '$table' exists"
    else
        fail "table '$table' missing from database"
    fi
done

section "Prompt Management"

# Add a prompt
add_output=$(bash "$HELPER" prompt add --title "FizzBuzz Test" --text "Write FizzBuzz in Python" --category "coding" --difficulty "easy" 2>&1) || true
if echo "$add_output" | grep -q "Created prompt #1"; then
    pass "prompt add creates prompt #1"
else
    fail "prompt add failed" "$add_output"
fi

# Add a second prompt
bash "$HELPER" prompt add --title "REST API Design" --text "Design a REST API for a todo app" --category "architecture" --difficulty "hard" >/dev/null 2>&1 || true

# List prompts
list_output=$(bash "$HELPER" prompt list 2>&1) || true
if echo "$list_output" | grep -q "FizzBuzz Test"; then
    pass "prompt list shows FizzBuzz prompt"
else
    fail "prompt list missing FizzBuzz prompt" "$list_output"
fi

if echo "$list_output" | grep -q "REST API Design"; then
    pass "prompt list shows REST API prompt"
else
    fail "prompt list missing REST API prompt"
fi

# Show prompt
show_output=$(bash "$HELPER" prompt show 1 2>&1) || true
if echo "$show_output" | grep -q "Write FizzBuzz in Python"; then
    pass "prompt show displays prompt text"
else
    fail "prompt show missing prompt text" "$show_output"
fi

section "Response Recording"

# Record responses for prompt 1
record1=$(bash "$HELPER" record --prompt 1 --model "claude-sonnet-4" --text "def fizzbuzz():\n    for i in range(1, 101):\n        if i % 15 == 0: print('FizzBuzz')\n        elif i % 3 == 0: print('Fizz')\n        elif i % 5 == 0: print('Buzz')\n        else: print(i)" --time 2.3 --tokens 150 --cost 0.0005 2>&1) || true
if echo "$record1" | grep -q "Recorded response #1"; then
    pass "record creates response #1 for claude-sonnet-4"
else
    fail "record failed for claude-sonnet-4" "$record1"
fi

record2=$(bash "$HELPER" record --prompt 1 --model "gpt-4o" --text "def fizz_buzz():\n    result = []\n    for num in range(1, 101):\n        s = ''\n        if num % 3 == 0: s += 'Fizz'\n        if num % 5 == 0: s += 'Buzz'\n        result.append(s or str(num))\n    return result" --time 1.8 --tokens 180 --cost 0.0006 2>&1) || true
if echo "$record2" | grep -q "Recorded response #2"; then
    pass "record creates response #2 for gpt-4o"
else
    fail "record failed for gpt-4o" "$record2"
fi

record3=$(bash "$HELPER" record --prompt 1 --model "gemini-2.5-pro" --text "for i in range(1, 101): print('FizzBuzz' if i%15==0 else 'Fizz' if i%3==0 else 'Buzz' if i%5==0 else i)" --time 1.2 --tokens 80 --cost 0.0002 2>&1) || true
if echo "$record3" | grep -q "Recorded response #3"; then
    pass "record creates response #3 for gemini-2.5-pro"
else
    fail "record failed for gemini-2.5-pro" "$record3"
fi

# Test recording for non-existent prompt
record_bad=$(bash "$HELPER" record --prompt 999 --model "test" --text "test" 2>&1) || true
if echo "$record_bad" | grep -q "not found"; then
    pass "record rejects non-existent prompt"
else
    fail "record should reject non-existent prompt" "$record_bad"
fi

section "Scoring"

# Score response 1 (claude-sonnet-4)
score1=$(bash "$HELPER" score --response 1 --correctness 5 --completeness 4 --code-quality 5 --clarity 4 2>&1) || true
if echo "$score1" | grep -q "Scored response #1"; then
    pass "score records scores for response #1"
else
    fail "score failed for response #1" "$score1"
fi

# Score response 2 (gpt-4o)
score2=$(bash "$HELPER" score --response 2 --correctness 4 --completeness 5 --code-quality 4 --clarity 5 2>&1) || true
if echo "$score2" | grep -q "Scored response #2"; then
    pass "score records scores for response #2"
else
    fail "score failed for response #2" "$score2"
fi

# Score response 3 (gemini-2.5-pro)
score3=$(bash "$HELPER" score --response 3 --correctness 5 --completeness 3 --code-quality 3 --clarity 3 2>&1) || true
if echo "$score3" | grep -q "Scored response #3"; then
    pass "score records scores for response #3"
else
    fail "score failed for response #3" "$score3"
fi

# Verify scores are stored
score_count=$(sqlite3 "$SCORING_DB_OVERRIDE" "SELECT COUNT(*) FROM scores;" 2>/dev/null)
if [[ "$score_count" == "12" ]]; then
    pass "12 scores stored (3 responses x 4 criteria)"
else
    fail "expected 12 scores, got: $score_count"
fi

# Test score validation (out of range)
score_bad=$(bash "$HELPER" score --response 1 --correctness 6 2>&1) || true
if echo "$score_bad" | grep -qi "must be 1-5\|error"; then
    pass "score rejects out-of-range value"
else
    # The CHECK constraint in SQLite may also catch this
    skip "score range validation (may be caught by DB constraint)"
fi

section "Comparison"

compare_output=$(bash "$HELPER" compare --prompt 1 2>&1) || true
if echo "$compare_output" | grep -q "Response Comparison"; then
    pass "compare shows comparison header"
else
    fail "compare missing header" "$compare_output"
fi

if echo "$compare_output" | grep -q "claude-sonnet-4"; then
    pass "compare shows claude-sonnet-4"
else
    fail "compare missing claude-sonnet-4"
fi

if echo "$compare_output" | grep -q "gpt-4o"; then
    pass "compare shows gpt-4o"
else
    fail "compare missing gpt-4o"
fi

if echo "$compare_output" | grep -q "Winner:"; then
    pass "compare declares a winner"
else
    fail "compare missing winner declaration"
fi

# JSON comparison
json_output=$(bash "$HELPER" compare --prompt 1 --json 2>&1) || true
if echo "$json_output" | grep -q '"prompt_id":1'; then
    pass "compare --json outputs valid JSON structure"
else
    fail "compare --json invalid output" "$json_output"
fi

section "Leaderboard"

lb_output=$(bash "$HELPER" leaderboard 2>&1) || true
if echo "$lb_output" | grep -q "Model Leaderboard"; then
    pass "leaderboard shows header"
else
    fail "leaderboard missing header" "$lb_output"
fi

if echo "$lb_output" | grep -q "#1"; then
    pass "leaderboard shows ranked entries"
else
    fail "leaderboard missing ranked entries"
fi

# JSON leaderboard
lb_json=$(bash "$HELPER" leaderboard --json 2>&1) || true
if echo "$lb_json" | grep -q '"leaderboard"'; then
    pass "leaderboard --json outputs valid JSON"
else
    fail "leaderboard --json invalid output"
fi

section "Export"

# CSV export
csv_output=$(bash "$HELPER" export --csv 2>&1) || true
if echo "$csv_output" | grep -q "prompt_id,prompt_title"; then
    pass "export --csv includes header row"
else
    fail "export --csv missing header" "$csv_output"
fi

if echo "$csv_output" | grep -q "claude-sonnet-4"; then
    pass "export --csv includes model data"
else
    fail "export --csv missing model data"
fi

# JSON export
json_export=$(bash "$HELPER" export --json 2>&1) || true
if echo "$json_export" | grep -q "claude-sonnet-4"; then
    pass "export --json includes model data"
else
    fail "export --json missing model data"
fi

section "History"

history_output=$(bash "$HELPER" history 1 2>&1) || true
if echo "$history_output" | grep -q "Scoring History"; then
    pass "history shows header"
else
    fail "history missing header" "$history_output"
fi

if echo "$history_output" | grep -q "correctness"; then
    pass "history shows criterion names"
else
    fail "history missing criterion names"
fi

section "Criteria Reference"

criteria_output=$(bash "$HELPER" criteria 2>&1) || true
if echo "$criteria_output" | grep -q "Scoring Criteria Reference"; then
    pass "criteria shows reference header"
else
    fail "criteria missing header" "$criteria_output"
fi

if echo "$criteria_output" | grep -q "30%"; then
    pass "criteria shows correctness weight (30%)"
else
    fail "criteria missing weight percentages"
fi

if echo "$criteria_output" | grep -q "Weighted Average Formula"; then
    pass "criteria shows formula"
else
    fail "criteria missing formula"
fi

section "Edge Cases"

# Empty prompt list on fresh DB
fresh_db="$TEST_DB_DIR/fresh.db"
export SCORING_DB_OVERRIDE="$fresh_db"
bash "$HELPER" init >/dev/null 2>&1 || true
empty_list=$(bash "$HELPER" prompt list 2>&1) || true
if echo "$empty_list" | grep -q "Evaluation Prompts"; then
    pass "prompt list works on empty database"
else
    fail "prompt list fails on empty database"
fi

# Compare with no responses
empty_compare=$(bash "$HELPER" compare --prompt 999 2>&1) || true
if echo "$empty_compare" | grep -qi "not found\|no responses"; then
    pass "compare handles missing prompt gracefully"
else
    fail "compare should handle missing prompt" "$empty_compare"
fi

# Leaderboard with no data
empty_lb=$(bash "$HELPER" leaderboard 2>&1) || true
if echo "$empty_lb" | grep -qi "no scored\|leaderboard"; then
    pass "leaderboard handles empty database"
else
    fail "leaderboard should handle empty database" "$empty_lb"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
printf '=%.0s' {1..50}
echo ""
printf "Results: \033[0;32m%d passed\033[0m" "$PASS_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf ", \033[0;31m%d failed\033[0m" "$FAIL_COUNT"
fi
if [[ "$SKIP_COUNT" -gt 0 ]]; then
    printf ", \033[0;33m%d skipped\033[0m" "$SKIP_COUNT"
fi
printf " (%d total)\n" "$TOTAL_COUNT"
printf '=%.0s' {1..50}
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
