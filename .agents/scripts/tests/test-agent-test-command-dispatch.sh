#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../../.." && pwd)" || exit
TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT/home"
export AGENT_TEST_CLI="opencode"
mkdir -p "$HOME" "$TEST_ROOT/bin"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OPENCODE_INVOCATIONS"
if [[ " $* " == *" --agent subagent-only "* ]]; then
  printf '%s\n' 'Warning: requested agent is a subagent; falling back to default agent' >&2
fi
printf '\033[33mwarning before json\033[0m\n'
printf '%s\n' '{"type":"text","part":{"text":"DISPATCH_OK=yes"}}'
exit 0
MOCK
chmod +x "$TEST_ROOT/bin/opencode"
export PATH="$TEST_ROOT/bin:$PATH"
export OPENCODE_INVOCATIONS="$TEST_ROOT/invocations"

# shellcheck source=../agent-test-helper.sh
source "$REPO_ROOT/.agents/scripts/agent-test-helper.sh"
check_opencode_server() { return 1; }
_cmd_run_sync_pattern_tracker() { return 0; }

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

command_suite="$TEST_ROOT/command-suite.json"
cat >"$command_suite" <<'JSON'
{"name":"command-dispatch","agent":"subagent-only","command":"aidevops-specialist","tests":[{"id":"dispatch","prompt":"test prompt","expect_contains":["DISPATCH_OK=yes"]}]}
JSON
cmd_run "$command_suite" >/dev/null 2>&1 || fail "command-dispatched suite failed"
grep -q -- '--command aidevops-specialist' "$OPENCODE_INVOCATIONS" ||
	fail "suite command did not reach opencode"
if grep -q -- '--agent subagent-only' "$OPENCODE_INVOCATIONS"; then
	fail "command dispatch also passed the subagent selector"
fi

primary_response=$(run_prompt_opencode_cli "primary prompt" "Build+" "" 10 "")
[[ "$primary_response" == "DISPATCH_OK=yes" ]] || fail "mixed output was not reduced to text events"
grep -q -- '--agent Build+' "$OPENCODE_INVOCATIONS" || fail "primary agent behavior changed"

subagent_status=0
subagent_response=$(run_prompt_opencode_cli "subagent prompt" "subagent-only" "" 10 "") || subagent_status=$?
[[ $subagent_status -ne 0 ]] || fail "subagent fallback was silently accepted"
[[ "$subagent_response" == *"use a suite command"* ]] || fail "subagent rejection lacked actionable guidance"

printf '%s\n' "PASS: agent test command dispatch is explicit and warning-safe"
