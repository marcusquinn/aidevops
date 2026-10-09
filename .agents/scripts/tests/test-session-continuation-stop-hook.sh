#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-session-continuation-stop-hook.sh — GH#33143 regression test.
#
# Exercises .agents/hooks/session_continuation_stop.py (Claude Code Stop hook):
#   1. Open todos + no question/blocker → block with a one-sentence reason.
#   2. stop_hook_active, block cap, headless env, disable override → allow.
#   3. No todos, all todos done, question, blocker, user stop, malformed → allow.
# And the settings registration in update-claude-settings.py is idempotent.
#
# Uses an isolated HOME and state dir; never touches the user's settings.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TEST_SCRIPTS_DIR/../hooks/session_continuation_stop.py"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# write_transcript <file> <user_text> <todo_status> <final_assistant_text> [extra_status]
# todo_status "none" omits the TodoWrite call entirely; extra_status adds a
# third todo ("Update the docs") with that status.
write_transcript() {
	local file="$1" user_text="$2" todo_status="$3" final_text="$4" extra_status="${5:-}"
	python3 - "$file" "$user_text" "$todo_status" "$final_text" "$extra_status" <<'PY'
import json, sys
path, user_text, status, final_text, extra_status = sys.argv[1:6]
lines = [{"type": "user", "message": {"role": "user", "content": user_text}}]
if status != "none":
    todos = [
        {"content": "Write the hook", "status": "completed", "activeForm": "Writing"},
        {"content": "Register the hook", "status": status, "activeForm": "Registering"},
    ]
    if extra_status:
        todos.append({"content": "Update the docs", "status": extra_status, "activeForm": "Updating"})
    lines.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t1", "name": "TodoWrite", "input": {"todos": todos}}]}})
    lines.append({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}})
lines.append({"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "text", "text": final_text}]}})
with open(path, "w") as handle:
    for line in lines:
        handle.write(json.dumps(line) + "\n")
PY
	return 0
}

# run_hook <session_id> <transcript> [stop_hook_active] -> prints hook stdout
run_hook() {
	local session="$1" transcript="$2" active="${3:-false}"
	printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":%s}' \
		"$session" "$transcript" "$active" |
		env -u AIDEVOPS_WORKER_ID -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS \
			-u CLAUDE_HEADLESS -u HEADLESS -u GITHUB_ACTIONS -u CLAUDE_CODE_ENTRYPOINT \
			-u AIDEVOPS_STOP_HOOK_DISABLE -u AIDEVOPS_STOP_HOOK_MAX_BLOCKS \
			AIDEVOPS_STOP_HOOK_STATE_DIR="$WORK_DIR/state" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} python3 "$HOOK"
	return 0
}

EXTRA_ENV=()

expect_block() {
	local name="$1" output="$2"
	if printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["decision"] == "block"
reason = d["reason"]
assert "Register the hook" in reason and reason.count(". ") == 0, reason
' 2>/dev/null; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected block, got: ${output:-<empty>}"
	fi
	return 0
}

expect_allow() {
	local name="$1" output="$2"
	if [[ -z "$output" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected allow, got: $output"
	fi
	return 0
}

test_hook_decisions() {
	local t="$WORK_DIR/open.jsonl"
	write_transcript "$t" "Implement the stop hook" "in_progress" "I have written the hook."
	expect_block "open todos, no question → block" "$(run_hook s-open "$t")"
	expect_allow "stop_hook_active true → allow" "$(run_hook s-active "$t" true)"

	run_hook s-cap "$t" >/dev/null
	run_hook s-cap "$t" >/dev/null
	expect_allow "cap of 2 blocks per session reached → allow" "$(run_hook s-cap "$t")"

	EXTRA_ENV=(FULL_LOOP_HEADLESS=1)
	expect_allow "headless worker session → allow" "$(run_hook s-headless "$t")"
	EXTRA_ENV=(AIDEVOPS_STOP_HOOK_DISABLE=1)
	expect_allow "AIDEVOPS_STOP_HOOK_DISABLE=1 override → allow" "$(run_hook s-disable "$t")"
	EXTRA_ENV=()

	write_transcript "$t" "Implement the stop hook" "pending" "Should I also update the docs?"
	expect_allow "final message asks a question → allow" "$(run_hook s-question "$t")"
	write_transcript "$t" "Implement the stop hook" "pending" "BLOCKED: missing credentials for the API."
	expect_allow "final message reports a blocker → allow" "$(run_hook s-blocker "$t")"
	# GH#33888: with 2+ open todos a blocker pauses only its own path.
	write_transcript "$t" "Implement the stop hook" "in_progress" "BLOCKED: dependency audit fails." "pending"
	local mixed
	mixed=$(run_hook s-blocker-mixed "$t")
	expect_block "blocker with another open todo → block" "$mixed"
	if [[ "$mixed" == *"Update the docs"* && "$mixed" == *"pauses only its own path"* ]]; then
		print_result "blocker nudge lists remaining todos and path scope" 0
	else
		print_result "blocker nudge lists remaining todos and path scope" 1 "got: ${mixed:-<empty>}"
	fi
	write_transcript "$t" "Implement the stop hook" "in_progress" "BLOCKED: dependency audit fails." "cancelled"
	expect_allow "blocker with only its own todo open → allow" "$(run_hook s-blocker-single "$t")"
	write_transcript "$t" "Implement the stop hook" "in_progress" "Blocked on the audit. Should I skip it?" "pending"
	expect_allow "blocker plus question with open todos → allow" "$(run_hook s-blocker-question "$t")"
	write_transcript "$t" "Implement the stop hook" "in_progress" "Blocked: this needs your approval to rotate the token." "pending"
	expect_allow "human dependency with open todos → allow" "$(run_hook s-blocker-human "$t")"
	write_transcript "$t" "stop here for now" "in_progress" "BLOCKED: dependency audit fails." "pending"
	expect_allow "user stop with mixed blocker todos → allow" "$(run_hook s-blocker-userstop "$t")"
	# GH#34123: a What next block with a numbered ask hands back to the user.
	write_transcript "$t" "Implement the stop hook" "in_progress" $'PR is open.\n\n**What next**\n- **Session:** stop hook — Blocked\n- **Needed from you:**\n  1. **Approve the release?** (explicit)\n- **Close:** Not yet: waiting on 1\n- **Reply:** `1y`' "pending"
	expect_allow "What next ask with open todos → allow" "$(run_hook s-whatnext-ask "$t")"
	# GH#34123: a negated blocker is not a blocker report.
	write_transcript "$t" "Implement the stop hook" "in_progress" "Docs updated; no blocker remains." "pending"
	local negated
	negated=$(run_hook s-negated "$t")
	expect_block "negated blocker with open todos → generic block" "$negated"
	if [[ "$negated" != *"pauses only its own path"* ]]; then
		print_result "negated blocker does not get the path-blocker nudge" 0
	else
		print_result "negated blocker does not get the path-blocker nudge" 1 "got: $negated"
	fi

	write_transcript "$t" "stop here for now" "pending" "Stopping."
	expect_allow "user asked to stop → allow" "$(run_hook s-userstop "$t")"
	write_transcript "$t" "Implement the stop hook" "none" "Done."
	expect_allow "no todos → allow" "$(run_hook s-none "$t")"
	write_transcript "$t" "Implement the stop hook" "cancelled" "Done."
	expect_allow "all todos terminal → allow" "$(run_hook s-done "$t")"

	write_transcript "$t" "Implement the stop hook" "pending" "Still working."
	printf 'not json\n' >>"$t"
	expect_allow "malformed later transcript entry → allow" "$(run_hook s-bad-later "$t")"
	printf 'not json\n{"type":\n' >"$t"
	expect_allow "malformed transcript → allow" "$(run_hook s-bad "$t")"
	expect_allow "missing transcript → allow" "$(run_hook s-missing "$WORK_DIR/absent.jsonl")"
	local out
	out=$(printf 'garbage' | python3 "$HOOK")
	expect_allow "malformed stdin → allow" "$out"
	return 0
}

test_settings_registration() {
	local home="$WORK_DIR/home"
	mkdir -p "$home/.claude"
	HOME="$home" python3 "$TEST_SCRIPTS_DIR/update-claude-settings.py" >/dev/null 2>&1
	HOME="$home" python3 "$TEST_SCRIPTS_DIR/update-claude-settings.py" >/dev/null 2>&1
	local count
	count=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for r in d["hooks"].get("Stop", []) for h in r.get("hooks", [])
          if "session_continuation_stop" in h.get("command", "")))
' "$home/.claude/settings.json" 2>/dev/null)
	if [[ "$count" == "1" ]]; then
		print_result "update-claude-settings.py registers Stop hook once (idempotent)" 0
	else
		print_result "update-claude-settings.py registers Stop hook once (idempotent)" 1 "count=${count:-error}"
	fi
	if grep -q 'session_continuation_stop' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "install-hooks-helper.sh installs the Stop hook" 0
	else
		print_result "install-hooks-helper.sh installs the Stop hook" 1
	fi
	return 0
}

main() {
	echo "=== session_continuation_stop.py tests (GH#33143) ==="
	test_hook_decisions
	test_settings_registration
	echo ""
	echo "Tests: $TESTS_RUN, failed: $TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && return 0
	return 1
}

main "$@"
