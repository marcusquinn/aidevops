#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_BASE" || exit 1
TEST_ROOT=$(mktemp -d "$TEMP_BASE/autoagent-metric-test.XXXXXX") || exit 1
FIXTURE_DIR="$TEST_ROOT/fixture"
BIN_DIR="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/suite-count"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"
BASELINE_FILE="$TEST_ROOT/baseline.json"
SUITE_FILE="$TEST_ROOT/suite.json"
GENERATED_BASELINE_FILE="$TEST_ROOT/generated-baseline.json"
HELPER="$FIXTURE_DIR/autoagent-metric-helper.sh"
WORKTREE_DIR="$TEST_ROOT/worktree"
GIT_CHANGED_FILE="$TEST_ROOT/git-changed"
GIT_UNTRACKED_FILE="$TEST_ROOT/git-untracked"
GIT_TRACKED_FILE="$TEST_ROOT/git-tracked"
LINT_LOG_FILE="$TEST_ROOT/lint-log"
ORIGINAL_PATH="$PATH"
TESTS_RUN=0
TESTS_FAILED=0
RUN_STATUS=0
MOCK_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":100}'

cleanup() {
	case "${TEST_ROOT:-}" in
	"$TEMP_BASE"/autoagent-metric-test.*) rm -rf "${TEST_ROOT:-}" ;;
	*) printf 'Refusing unsafe cleanup path: %s\n' "${TEST_ROOT:-}" >&2 ;;
	esac
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" != "$expected" ]]; then
		fail "$message (expected '$expected', got '$actual')"
		return 1
	fi
	pass "$message"
	return 0
}

assert_success() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ $RUN_STATUS -ne 0 ]]; then
		fail "$message (status $RUN_STATUS)"
		return 1
	fi
	pass "$message"
	return 0
}

assert_failure() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ $RUN_STATUS -eq 0 ]]; then
		fail "$message (unexpected success)"
		return 1
	fi
	pass "$message"
	return 0
}

assert_stderr_contains() {
	local expected="$1"
	local message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -Fq -- "$expected" "$STDERR_FILE"; then
		fail "$message (missing '$expected')"
		return 1
	fi
	pass "$message"
	return 0
}

reset_count() {
	printf '%s\n' "0" >"$COUNT_FILE"
	return 0
}

assert_count() {
	local expected="$1"
	local message="$2"
	local actual="0"
	[[ -f "$COUNT_FILE" ]] && actual=$(<"$COUNT_FILE")
	assert_equals "$expected" "$actual" "$message"
	return $?
}

run_metric() {
	RUN_STATUS=0
	PATH="$BIN_DIR:$ORIGINAL_PATH" MOCK_COUNT_FILE="$COUNT_FILE" \
		MOCK_SUITE_JSON="$MOCK_SUITE_JSON" MOCK_GIT_CHANGED_FILE="$GIT_CHANGED_FILE" \
		MOCK_GIT_UNTRACKED_FILE="$GIT_UNTRACKED_FILE" MOCK_GIT_TRACKED_FILE="$GIT_TRACKED_FILE" \
		MOCK_LINT_LOG_FILE="$LINT_LOG_FILE" \
		bash -c 'cd "$1" && shift && bash "$@"' _ "$WORKTREE_DIR" "$HELPER" "$@" \
		>"$STDOUT_FILE" 2>"$STDERR_FILE" || RUN_STATUS=$?
	return 0
}

RUN_STATUS=0
(unset TEST_ROOT; cleanup) >"$STDOUT_FILE" 2>"$STDERR_FILE" || RUN_STATUS=$?
assert_success "cleanup tolerates an unset test root"
assert_stderr_contains "Refusing unsafe cleanup path:" "unset test root refuses cleanup safely"

mkdir -p "$FIXTURE_DIR" "$BIN_DIR" "$WORKTREE_DIR/.agents/scripts" \
	"$WORKTREE_DIR/.agents/docs" "$WORKTREE_DIR/.agents/tests" "$WORKTREE_DIR/unrelated" || exit 1
cp "$REPO_ROOT/.agents/scripts/autoagent-metric-helper.sh" "$HELPER" || exit 1
chmod +x "$HELPER"

cat >"$FIXTURE_DIR/agent-test-helper.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "run" || -z "${2:-}" || "${3:-}" != "--json" ]]; then
	printf 'invalid mock invocation\n' >&2
	exit 2
fi
count=0
[[ -f "$MOCK_COUNT_FILE" ]] && count=$(<"$MOCK_COUNT_FILE")
printf '%s\n' "$((count + 1))" >"$MOCK_COUNT_FILE"
printf '%s\n' "$MOCK_SUITE_JSON"
MOCK
chmod +x "$FIXTURE_DIR/agent-test-helper.sh"

cat >"$BIN_DIR/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
rev-parse) exit 0 ;;
diff)
	if [[ "${2:-}" == "--name-only" && "${3:-}" == "origin/main" && "${4:-}" == "--" && -f "$MOCK_GIT_CHANGED_FILE" ]]; then
		while IFS= read -r path; do printf '%s\n' "$path"; done <"$MOCK_GIT_CHANGED_FILE"
	fi
	exit 0
	;;
ls-files)
	if [[ "${2:-}" == "--others" && "${3:-}" == "--exclude-standard" && "${4:-}" == "--" ]]; then
		[[ -f "$MOCK_GIT_UNTRACKED_FILE" ]] && while IFS= read -r path; do printf '%s\n' "$path"; done <"$MOCK_GIT_UNTRACKED_FILE"
	else
		[[ -f "$MOCK_GIT_TRACKED_FILE" ]] && while IFS= read -r path; do printf '%s\n' "$path"; done <"$MOCK_GIT_TRACKED_FILE"
	fi
	exit 0
	;;
*) exit 0 ;;
esac
MOCK
chmod +x "$BIN_DIR/git"

cat >"$BIN_DIR/shellcheck" <<'MOCK'
#!/usr/bin/env bash
path=""
for argument in "$@"; do path="$argument"; done
printf 'shell:%s\n' "$path" >>"$MOCK_LINT_LOG_FILE"
exit 0
MOCK
chmod +x "$BIN_DIR/shellcheck"

cat >"$BIN_DIR/markdownlint-cli2" <<'MOCK'
#!/usr/bin/env bash
path=""
for argument in "$@"; do path="$argument"; done
printf 'markdown:%s\n' "$path" >>"$MOCK_LINT_LOG_FILE"
exit 0
MOCK
chmod +x "$BIN_DIR/markdownlint-cli2"

printf '%s\n' '{}' >"$SUITE_FILE"
printf '%s\n' '{"comprehension_score":1.0,"linter_score":1.0,"avg_tokens":100}' >"$BASELINE_FILE"
printf '%s\n' '{}' >"$WORKTREE_DIR/.agents/tests/agents-md-knowledge.json"
: >"$GIT_CHANGED_FILE"
: >"$GIT_UNTRACKED_FILE"
: >"$GIT_TRACKED_FILE"
: >"$LINT_LOG_FILE"
printf '%s\n' '#!/usr/bin/env bash' >"$WORKTREE_DIR/.agents/scripts/modified.sh"
printf '%s\n' '# New document' >"$WORKTREE_DIR/.agents/docs/new.md"
printf '%s\n' '#!/usr/bin/env bash' >"$WORKTREE_DIR/unrelated/outside.sh"

reset_count
MOCK_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":100}'
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_success "score succeeds"
assert_equals "1.0000" "$(<"$STDOUT_FILE")" "perfect inputs score 1.0000"
assert_count "1" "score invokes suite once"

reset_count
run_metric score --baseline-file "$BASELINE_FILE"
assert_success "default shipped suite score succeeds"
assert_count "1" "default shipped suite is executed once"

reset_count
MOCK_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":50}'
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_equals "1.0000" "$(<"$STDOUT_FILE")" "lower token cost earns no bonus beyond full weight"
assert_count "1" "lower-cost score invokes suite once"

reset_count
MOCK_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":200}'
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_equals "0.9000" "$(<"$STDOUT_FILE")" "two-times token cost earns zero token weight"
assert_count "1" "boundary score invokes suite once"

reset_count
MOCK_SUITE_JSON='{"pass_rate":1.0,"avg_response_chars":300}'
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_equals "0.9000" "$(<"$STDOUT_FILE")" "worse than two-times token cost remains clamped"
assert_count "1" "over-boundary score invokes suite once"

reset_count
MOCK_SUITE_JSON='{"pass_rate":0.5,"avg_response_chars":100}'
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_equals "0.7000" "$(<"$STDOUT_FILE")" "weighted comprehension formula is normalized"

reset_count
run_metric comprehension --suite "$SUITE_FILE"
assert_equals "0.5" "$(<"$STDOUT_FILE")" "standalone comprehension uses suite result"
assert_count "1" "standalone comprehension invokes suite once"

printf '%s\n' '.agents/scripts/modified.sh' 'unrelated/outside.sh' >"$GIT_CHANGED_FILE"
printf '%s\n' '.agents/docs/new.md' '.agents/scripts/modified.sh' 'unrelated/new.md' >"$GIT_UNTRACKED_FILE"
: >"$LINT_LOG_FILE"
run_metric lint
assert_success "lint scores candidate working-tree files"
assert_equals "1.0000" "$(<"$STDOUT_FILE")" "candidate lint score includes passing tracked and untracked files"
assert_equals "2" "$(wc -l <"$LINT_LOG_FILE" | tr -d ' ')" "only relevant candidate files are linted"
if grep -Fq 'shell:.agents/scripts/modified.sh' "$LINT_LOG_FILE" &&
	grep -Fq 'markdown:.agents/docs/new.md' "$LINT_LOG_FILE" &&
	! grep -Fq 'unrelated/' "$LINT_LOG_FILE"; then
	pass "tracked and untracked candidates are scored while unrelated paths are ignored"
	TESTS_RUN=$((TESTS_RUN + 1))
else
	fail "candidate lint selection is incorrect"
	TESTS_RUN=$((TESTS_RUN + 1))
fi
: >"$GIT_CHANGED_FILE"
: >"$GIT_UNTRACKED_FILE"
: >"$LINT_LOG_FILE"

reset_count
run_metric tokens --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_equals "1.0000" "$(<"$STDOUT_FILE")" "standalone tokens uses suite result"
assert_count "1" "standalone tokens invokes suite once"

reset_count
run_metric tokens --suite "$SUITE_FILE" --baseline-file "$TEST_ROOT/missing-baseline.json"
assert_success "standalone tokens degrades without a baseline"
assert_equals "1.0" "$(<"$STDOUT_FILE")" "missing baseline returns neutral token ratio"
assert_count "0" "standalone tokens skips suite when baseline is absent"

reset_count
run_metric score --suite "$TEST_ROOT/missing-suite.json" --baseline-file "$BASELINE_FILE"
assert_success "missing suite degrades gracefully"
assert_equals "1.0000" "$(<"$STDOUT_FILE")" "missing suite produces neutral score"
assert_count "0" "missing suite does not invoke helper"

reset_count
run_metric score --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE" --weights "0.5,0.25,0.25"
assert_success "normalized custom weights are accepted"
assert_equals "0.7500" "$(<"$STDOUT_FILE")" "custom weights affect score"

for invalid_weights in "0.5,0.5" "a,0,1" "0.5,-0.1,0.6" "0.6,0.3,0.2" "0.4,0.3,0.2,0.1"; do
	run_metric score --weights "$invalid_weights"
	assert_failure "invalid weights '$invalid_weights' are rejected"
done
assert_stderr_contains "Invalid weights:" "invalid weights explain the expected contract"

run_metric score --weights
assert_failure "missing --weights value is rejected"
assert_stderr_contains "Missing value for --weights" "missing weights value is explained"
run_metric score --suite
assert_failure "missing --suite value is rejected"
assert_stderr_contains "Missing value for --suite" "missing suite value is explained"
run_metric score --baseline-file
assert_failure "missing --baseline-file value is rejected"
assert_stderr_contains "Missing value for --baseline-file" "missing baseline value is explained"

run_metric score unexpected-argument
assert_failure "unexpected CLI arguments are rejected"
assert_stderr_contains "Unexpected argument: unexpected-argument" "unexpected argument is explained"

run_metric score --weights "invalid"
assert_failure "main propagates subcommand failure status"

reset_count
MOCK_SUITE_JSON='{"pass_rate":0.75,"avg_response_chars":123}'
run_metric baseline --suite "$SUITE_FILE" --baseline-file "$GENERATED_BASELINE_FILE"
assert_success "baseline subcommand succeeds"
assert_count "1" "baseline invokes suite once"
if jq -e '.comprehension_score == 0.75 and .avg_tokens == 123 and (.linter_score | type) == "number" and .suite != null and (.created | type) == "string"' "$GENERATED_BASELINE_FILE" >/dev/null; then
	pass "baseline writes a valid sidecar"
	TESTS_RUN=$((TESTS_RUN + 1))
else
	fail "baseline sidecar is invalid"
	TESTS_RUN=$((TESTS_RUN + 1))
fi

reset_count
MOCK_SUITE_JSON='{"pass_rate":0.5,"avg_response_chars":200}'
run_metric compare --suite "$SUITE_FILE" --baseline-file "$BASELINE_FILE"
assert_success "compare succeeds"
assert_count "1" "compare invokes suite once"
if jq -e '.composite_score == 0.6 and .sub_scores.comprehension == 0.5 and .sub_scores.token_cost_ratio == 2 and .sub_scores.token_efficiency == 0 and .weights.tokens == 0.1' "$STDOUT_FILE" >/dev/null; then
	pass "compare emits correct JSON"
	TESTS_RUN=$((TESTS_RUN + 1))
else
	fail "compare JSON is incorrect"
	TESTS_RUN=$((TESTS_RUN + 1))
fi

if [[ $TESTS_FAILED -ne 0 ]]; then
	printf '%s tests failed out of %s\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
	exit 1
fi

printf 'All %s autoagent metric helper tests passed\n' "$TESTS_RUN"
