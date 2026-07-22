#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/command-policy-helper.py"
POLICY="${SCRIPT_DIR}/../configs/command-policy.json"
TEST_ROOT="$(mktemp -d)"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

# Fixture construction must bypass the deployed guard shim. Policy assertions
# still invoke canonical-git-command-guard.py through the helper under test.
git() {
	/usr/bin/git "$@"
	return $?
}

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

assert_decision() {
	local name="$1"
	local command_text="$2"
	local expected_decision="$3"
	local expected_rule="$4"
	local expected_status="$5"
	local cwd="${6:-$TEST_ROOT}"
	local output=""
	local status=0
	local actual=""

	output="$(python3 "$HELPER" check-command --cwd "$cwd" --command "$command_text")" || status=$?
	actual="$(
		python3 - "$output" <<'PY'
import json
import sys

try:
    result = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    print("invalid/invalid")
else:
    print(f"{result.get('decision', '')}/{result.get('rule_id', '')}")
PY
	)"
	if [[ "$status" -eq "$expected_status" && "$actual" == "${expected_decision}/${expected_rule}" ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} decision=${actual} output=${output}"
	fi
	return 0
}

assert_argv_decision() {
	local name="$1"
	local expected_decision="$2"
	local expected_rule="$3"
	local expected_status="$4"
	local cwd="$5"
	shift 5
	local argv_json=""
	local output=""
	local status=0
	local actual=""
	argv_json="$(
		python3 - "$@" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
	)"
	output="$(python3 "$HELPER" check-command --cwd "$cwd" --argv-json "$argv_json")" || status=$?
	actual="$(
		python3 - "$output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
print(f"{result.get('decision', '')}/{result.get('rule_id', '')}")
PY
	)"
	if [[ "$status" -eq "$expected_status" && "$actual" == "${expected_decision}/${expected_rule}" ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} decision=${actual} output=${output}"
	fi
	return 0
}

assert_authorized_decision() {
	local name="$1"
	local authorization="$2"
	local command_text="$3"
	local expected_status="$4"
	local expected_pattern="$5"
	local cwd="${6:-/work}"
	local output=""
	local status=0

	output="$(AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION="$authorization" python3 "$HELPER" check-command --cwd "$cwd" --command "$command_text")" || status=$?
	if [[ "$status" -eq "$expected_status" && "$output" == *"$expected_pattern"* ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} output=${output}"
	fi
	return 0
}

assert_process_decision() {
	local name="$1"
	local command_text="$2"
	local expected_decision="$3"
	local expected_rule="$4"
	local runtime_pid="${5:-200}"
	local runtime_identity="${6-runtime-a}"
	local output=""
	local status=0
	local actual=""

	output="$(python3 "$HELPER" check-command --cwd "$TEST_ROOT" \
		--command "$command_text" --runtime-pid "$runtime_pid" \
		--runtime-process-identity "$runtime_identity" \
		--process-table-fixture "${TEST_ROOT}/processes.json")" || status=$?
	actual="$(
		python3 - "$output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
print(f"{result.get('decision', '')}/{result.get('rule_id', '')}")
PY
	)"
	local expected_status=0
	[[ "$expected_decision" == "allow" ]] || expected_status=20
	if [[ "$status" -eq "$expected_status" && "$actual" == "${expected_decision}/${expected_rule}" ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} decision=${actual} output=${output}"
	fi
	return 0
}

test_validation() {
	if python3 "$HELPER" validate --policy "$POLICY" >/dev/null; then
		pass "validates declarative policy and fixtures"
	else
		fail "validates declarative policy and fixtures"
	fi
	return 0
}

test_evaluate_invocations_compatibility() {
	if python3 - "$HELPER" "$POLICY" <<'PY'; then
import importlib.util
import pathlib
import sys

helper_path, policy_path = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("command_policy_helper", helper_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
policy = module._load_policy(policy_path)
expected = module.evaluate_invocations([["printf", "safe"]], "/work", policy)
positional = module.evaluate_invocations(
    [["printf", "safe"]], "/work", policy, "", False, "test", ""
)
keyword = module.evaluate_invocations(
    [["printf", "safe"]],
    "/work",
    policy,
    guard_path="",
    worker=False,
    worker_id="test",
    network_helper="",
)
assert expected == positional == keyword
PY
		pass "evaluate_invocations preserves positional and keyword interfaces"
	else
		fail "evaluate_invocations preserves positional and keyword interfaces"
	fi
	return 0
}

test_account_mutation_authorization() {
	local command_text="gh repo fork owner/source --clone=false"
	local authorization=""
	local status=0

	assert_decision "blocks direct repository fork" "$command_text" forbid github.account-mutation 20 "/work"
	assert_decision "blocks quoted repository fork" "gh repo fork 'owner/source' --clone=false" forbid github.account-mutation 20 "/work"
	assert_decision "blocks wrapped repository fork" "sudo -n env -i command gh repo fork owner/source --clone=false" forbid github.account-mutation 20 "/work"
	assert_decision "blocks shell-launched repository fork" "bash -lc 'gh repo fork owner/source --clone=false'" forbid github.account-mutation 20 "/work"
	assert_argv_decision "blocks path-qualified repository fork" forbid github.account-mutation 20 "/work" /usr/local/bin/gh repo fork owner/source --clone=false
	assert_decision "blocks equivalent repository creation" "gh repo create owner/new-repo --public" forbid github.account-mutation 20 "/work"
	assert_decision "allows read-only repository view" "gh repo view owner/source" allow command.default-allow 0 "/work"
	assert_decision "allows read-only issue view" "gh issue view 123" allow command.default-allow 0 "/work"
	assert_decision "allows read-only pull request view" "gh pr view 456" allow command.default-allow 0 "/work"
	assert_decision "fails closed on malformed repository fork" "gh repo fork 'owner/source" forbid command.parse-error 20 "/work"
	assert_decision "rejects inline authorization injection" "AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION=sha256:fake gh repo fork owner/source" forbid command.parse-error 20 "/work"
	assert_decision "rejects wrapped authorization injection" "env AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION=sha256:fake gh repo fork owner/source" forbid command.parse-error 20 "/work"
	assert_decision "rejects GitHub target environment override" "GH_REPO=other/target gh repo fork owner/source" forbid command.parse-error 20 "/work"

	authorization="$(python3 "$HELPER" authorization-digest --cwd /work --command "$command_text")" || status=$?
	if [[ "$status" -eq 0 && "$authorization" =~ ^sha256:[a-f0-9]{64}$ ]]; then
		pass "generates a content-bound account-mutation authorization"
	else
		fail "generates a content-bound account-mutation authorization" "status=${status} authorization=${authorization}"
	fi

	assert_authorized_decision "exact inherited authorization permits the approved fork" "$authorization" "$command_text" 0 '"decision": "allow"'
	assert_authorized_decision "direct authorization does not permit a privileged wrapper" "$authorization" "sudo -n gh repo fork owner/source --clone=false" 20 "github.account-mutation"
	assert_authorized_decision "authorization remains bound to exact command quoting" "$authorization" "gh repo fork 'owner/source' --clone=false" 20 "github.account-mutation"
	assert_authorized_decision "authorization does not permit a different fork target" "$authorization" "gh repo fork owner/different --clone=false" 20 "github.account-mutation"
	assert_authorized_decision "authorization remains bound to the approved working directory" "$authorization" "$command_text" 20 "github.account-mutation" "/different"
	assert_authorized_decision "fork authorization does not grant another account write" "$authorization" "gh repo create owner/new-repo --public" 20 "github.account-mutation"
	assert_authorized_decision "authorization cannot widen a compound command" "$authorization" "$command_text && printf done" 20 "github.account-mutation"
	return 0
}

test_static_decisions() {
	assert_decision "allows unmatched command" "printf safe" allow command.default-allow 0
	assert_decision "forbids recursive forced removal" "rm -rf ./build-output" forbid filesystem.rm-recursive-force 20 "/work"
	assert_decision "forbids recursive root removal" "rm --recursive --force /" forbid filesystem.rm-recursive-force-root 20
	assert_decision "allows temporary cleanup" "rm -rf /tmp/aidevops-example" allow command.default-allow 0
	assert_decision "detects nested destructive command" "sh -c 'rm -r -f ./generated'" forbid filesystem.rm-recursive-force 20 "/work"
	assert_decision "fails closed on malformed shell" "printf 'unterminated" forbid command.parse-error 20
	assert_decision "rejects multiline shell" $'printf one\nprintf two' forbid command.parse-error 20
	# Literal command substitution is the unsupported syntax under test.
	# shellcheck disable=SC2016
	assert_decision "rejects command substitution" 'curl https://$(printf example.com)' forbid command.parse-error 20
	# shellcheck disable=SC2016
	assert_decision "rejects variable-expanded destination" 'curl "$TARGET_URL"' forbid command.parse-error 20
	assert_decision "rejects redirection" "printf data > output.txt" forbid command.parse-error 20
	assert_decision "rejects unsupported wrapper option" "sudo --unknown printf safe" forbid command.parse-error 20
	assert_decision "parses wrapper options" "sudo -u root env -i command -p nohup time -p rm -rf ./generated" forbid filesystem.rm-recursive-force 20 "/work"
	assert_decision "parses attached and combined wrapper options" "sudo -n -uroot env -i -uFOO command -p nohup -- time -pv exec -a cleanup rm -rf ./generated" forbid filesystem.rm-recursive-force 20 "/work"
	assert_decision "parses valued shell options before combined flags" "MODE=test bash -O extglob -lc 'rm -rf ./generated'" forbid filesystem.rm-recursive-force 20 "/work"
	assert_decision "rejects network-affecting leading assignment" "HTTPS_PROXY=https://requestbin.com curl https://github.com" forbid command.parse-error 20
	assert_decision "rejects Git target environment override" "GIT_DIR=/tmp/other.git git branch -m renamed" forbid command.parse-error 20
	assert_decision "rejects env cwd-changing option" "env -C /tmp git status" forbid command.parse-error 20
	assert_decision "rejects sudo cwd-changing option" "sudo -D /tmp git status" forbid command.parse-error 20
	assert_decision "rejects shell startup file option" "bash --init-file /tmp/profile -lc 'git status'" forbid command.parse-error 20
	assert_decision "rejects single-line shell control structure" "for target in one; do rm -rf ./generated; done" forbid command.parse-error 20
	assert_decision "rejects dynamic argv launcher" "printf '%s' 'rm -rf ./generated' | xargs sh -c" forbid command.parse-error 20
	assert_argv_decision "parses combined bash flags" forbid filesystem.rm-recursive-force 20 "/work" bash -lc "rm -rf ./generated"
	# shellcheck disable=SC2016
	assert_argv_decision "rejects shell positional-command indirection" forbid command.parse-error 20 "/work" sh -c '$0 https://requestbin.com' curl
	assert_argv_decision "treats dash-prefixed operand after separator as deletion target" forbid filesystem.rm-recursive-force 20 "/work" rm -rf -- -rf
	assert_argv_decision "argv preserves spaces" allow command.default-allow 0 "$TEST_ROOT" printf "%s" "curl https://requestbin.com/a path"
	assert_argv_decision "rejects temp traversal before exemption" forbid filesystem.rm-recursive-force 20 "$TEST_ROOT" rm -rf "/tmp/../home/example"
	local nul_output=""
	local nul_status=0
	nul_output="$(python3 "$HELPER" check-command --argv-json '["printf","\u0000"]')" || nul_status=$?
	if [[ "$nul_status" -eq 20 && "$nul_output" == *command.parse-error* ]]; then
		pass "rejects NUL in argv JSON"
	else
		fail "rejects NUL in argv JSON" "status=${nul_status} output=${nul_output}"
	fi
	return 0
}

test_process_table_parser() {
	if python3 - "$SCRIPT_DIR" <<'PY'; then
import importlib
import subprocess
import sys
from unittest import mock

sys.path.insert(0, sys.argv[1])
module = importlib.import_module("process_termination_identity")
processes = " 200 100 100 Wed Jul 22 12:34:56 2026 /Applications/OpenCode Helper\n"
arguments = " 200 /Applications/OpenCode Helper --serve\n"
results = [
    subprocess.CompletedProcess([], 0, stdout=processes, stderr=""),
    subprocess.CompletedProcess([], 0, stdout=arguments, stderr=""),
]
with mock.patch.object(module.subprocess, "run", side_effect=results) as run:
    records = module._load_live_processes()
assert len(records) == 1
assert records[0].comm == "/Applications/OpenCode Helper"
assert records[0].args == "/Applications/OpenCode Helper --serve"
assert all(call.args[0][1:3] == ["-ww", "-axo"] for call in run.call_args_list)
assert all(call.kwargs["env"]["LC_ALL"] == "C" for call in run.call_args_list)
assert all(call.kwargs["env"]["TZ"] == "UTC" for call in run.call_args_list)
PY
		pass "parses untruncated process names and arguments independently"
	else
		fail "parses untruncated process names and arguments independently"
	fi
	return 0
}

test_process_termination_policy() {
	python3 - "${TEST_ROOT}/processes.json" <<'PY'
import json
import sys

processes = [
    {"pid": 1, "ppid": 0, "pgid": 1, "start": "init-a", "comm": "launchd", "args": "launchd"},
    {"pid": 100, "ppid": 1, "pgid": 100, "start": "terminal-a", "comm": "terminal", "args": "terminal"},
    {"pid": 200, "ppid": 100, "pgid": 100, "start": "runtime-a", "comm": "opencode", "args": "opencode serve"},
    {"pid": 201, "ppid": 100, "pgid": 100, "start": "runtime-b", "comm": "opencode", "args": "opencode serve"},
    {"pid": 400, "ppid": 200, "pgid": 400, "start": "child-a", "comm": "sandbox-worker", "args": "sandbox-worker task"},
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"processes": processes}, handle)
PY
	assert_process_decision "blocks incident-form runtime process-group termination" \
		"kill -TERM -- -100" forbid process.runtime-self-preservation
	assert_process_decision "blocks explicit runtime host termination" \
		"kill 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks explicit launcher ancestor termination" \
		"kill 100" forbid process.runtime-self-preservation
	assert_process_decision "blocks broad all-process termination" \
		"kill -TERM -- -1" forbid process.runtime-self-preservation
	assert_process_decision "blocks shell-wrapped runtime termination" \
		"bash -lc 'kill -TERM -- -100'" forbid process.runtime-self-preservation
	assert_process_decision "blocks command-wrapped runtime termination" \
		"sudo -n env -i command kill -TERM 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks session-wrapper runtime termination" \
		"setsid -f -- kill -TERM 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks timeout-wrapper runtime termination" \
		"timeout --signal TERM 5 kill 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks priority-wrapper runtime termination" \
		"nice -n 5 kill 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks buffering-wrapper runtime termination" \
		"stdbuf -oL kill 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks path-qualified runtime termination" \
		"/bin/kill -TERM 200" forbid process.runtime-self-preservation
	assert_process_decision "blocks BusyBox runtime process-group termination" \
		"busybox kill -TERM -- -100" forbid process.runtime-self-preservation
	assert_process_decision "blocks current process-group shorthand" \
		"kill -TERM 0" forbid process.runtime-self-preservation
	assert_process_decision "blocks pkill pattern matching runtime" \
		"pkill -f opencode" forbid process.runtime-self-preservation
	assert_process_decision "blocks empty pkill patterns that match every process" \
		"pkill ''" forbid process.runtime-self-preservation
	assert_process_decision "blocks pkill selecting the runtime process group" \
		"pkill -g 0 opencode" forbid process.runtime-self-preservation
	assert_process_decision "fails closed on ambiguous pkill session selection" \
		"pkill -s 0 opencode" forbid process.termination-unclassified
	assert_process_decision "fails closed on non-portable pkill expressions" \
		"pkill 'open[[:alpha:]]*'" forbid process.termination-unclassified
	assert_process_decision "blocks killall name matching runtime" \
		"killall opencode" forbid process.runtime-self-preservation
	assert_process_decision "blocks empty killall regular expressions" \
		"killall -r ''" forbid process.runtime-self-preservation
	assert_process_decision "fails closed on ambiguous killall match mode" \
		"killall -m opencode" forbid process.termination-unclassified
	assert_process_decision "allows signal-zero runtime probes" \
		"kill -0 200" allow command.default-allow
	assert_process_decision "allows pkill signal-zero probes without runtime identity" \
		"pkill -0 opencode" allow command.default-allow 200 ""
	assert_process_decision "allows killall signal-zero probes without runtime identity" \
		"killall -0 opencode" allow command.default-allow 200 ""
	assert_process_decision "allows killall signal-list inspection without runtime identity" \
		"killall -l" allow command.default-allow 200 ""
	assert_process_decision "allows distinct sandbox child PID cleanup" \
		"kill -TERM 400" allow command.default-allow
	assert_process_decision "allows distinct sandbox child process-group cleanup" \
		"kill -TERM -- -400" allow command.default-allow
	assert_process_decision "allows parent-scoped sandbox child cleanup" \
		"pkill -P 200 sandbox-worker" allow command.default-allow
	assert_process_decision "fails closed when runtime identity is missing" \
		"kill -TERM 400" forbid process.runtime-identity-unavailable 200 ""
	assert_process_decision "fails closed when a PID was reused" \
		"kill -TERM 400" forbid process.runtime-identity-unavailable 200 "stale-generation"
	assert_process_decision "blocks the current host after session PID rollover" \
		"kill -TERM 201" forbid process.runtime-self-preservation 201 "runtime-b"
	return 0
}

test_canonical_delegation() {
	local repo="${TEST_ROOT}/repo"
	local linked="${TEST_ROOT}/linked"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.name Test
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config commit.gpgsign false
	printf 'seed\n' >"${repo}/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -q -m seed
	assert_decision "forbids canonical branch mutation through canonical guard" "git branch -m main renamed" forbid git.canonical-worktree 20 "$repo"
	git -C "$repo" worktree add -q -b feature/test "$linked"
	assert_decision "allows linked-worktree branch creation" "git switch -c feature/child" allow command.default-allow 0 "$linked"
	assert_decision "forbids generic Git destructive operation in linked worktree" "git reset --hard HEAD" forbid git.reset-destructive 20 "$linked"
	return 0
}

test_worker_network_policy() {
	local output=""
	local status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --command "printf '%s' 'curl https://requestbin.com/collect'")" || status=$?
	if [[ "$status" -eq 0 && "$output" == *command.default-allow* ]]; then
		pass "worker ignores network-looking printf text"
	else
		fail "worker ignores network-looking printf text" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --argv-json '["curl","--url","HTTPS://requestbin.com/collect"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "worker blocks uppercase-scheme Tier 5 URL"
	else
		fail "worker blocks uppercase-scheme Tier 5 URL" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --argv-json '["curl","--url","https://github.com","--proxy","https://requestbin.com"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "worker blocks Tier 5 proxy destination"
	else
		fail "worker blocks Tier 5 proxy destination" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --argv-json '["curl","--resolve","github.com:443:requestbin.com","https://github.com"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "worker blocks Tier 5 resolve override"
	else
		fail "worker blocks Tier 5 resolve override" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --argv-json '["curl","--silent"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "worker fails closed on missing curl destination"
	else
		fail "worker fails closed on missing curl destination" "status=${status} output=${output}"
	fi

	git -C "${TEST_ROOT}/repo" remote add origin https://github.com/example/repo.git
	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --cwd "${TEST_ROOT}/linked" --argv-json '["git","fetch","origin"]')" || status=$?
	if [[ "$status" -eq 0 ]]; then
		pass "worker resolves and allows classified Git remote alias"
	else
		fail "worker resolves and allows classified Git remote alias" "status=${status} output=${output}"
	fi
	git -C "${TEST_ROOT}/repo" remote set-url origin https://requestbin.com/example/repo.git
	status=0
	output="$(python3 "$HELPER" check-command --worker --worker-id test --cwd "${TEST_ROOT}/linked" --argv-json '["git","fetch","origin"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "worker blocks Tier 5 Git remote alias"
	else
		fail "worker blocks Tier 5 Git remote alias" "status=${status} output=${output}"
	fi
	return 0
}

test_secondary_layers() {
	if python3 - \
		"${SCRIPT_DIR}/update-claude-settings.py" \
		"${SCRIPT_DIR}/agent-discovery.py" \
		"${SCRIPT_DIR}/../configs/verification-triggers.json" <<'PY'; then
import ast
import json
import sys

update_path, discovery_path, triggers_path = sys.argv[1:]

def assignments(path, function=None):
    tree = ast.parse(open(path, encoding="utf-8").read())
    nodes = tree.body
    if function:
        nodes = next(node.body for node in nodes if isinstance(node, ast.FunctionDef) and node.name == function)
    values = {}
    for node in nodes:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in {"deny_rules", "ask_rules"}:
                values[node.targets[0].id] = ast.literal_eval(node.value)
    return values

update = assignments(update_path)
discovery = assignments(discovery_path, "_build_permission_rules")
assert update == discovery, (update, discovery)
managed = {
    "Bash(git reset --hard *)", "Bash(git push --force *)",
    "Bash(rm -rf *)", "Bash(curl *)", "Bash(wget *)",
}
assert not managed.intersection(update["deny_rules"] + update["ask_rules"])
triggers = json.load(open(triggers_path, encoding="utf-8"))
assert triggers["_authority"] == "verification-only"
patterns = [p for category in triggers["categories"].values() for p in category["command_patterns"]]
assert "git reset --hard" not in patterns
assert "git push --force-with-lease" not in patterns
assert "rm -rf /" not in patterns
PY
		pass "permission mirrors and verification triggers remain secondary"
	else
		fail "permission mirrors and verification triggers remain secondary"
	fi

	local settings_home="${TEST_ROOT}/settings-home"
	mkdir -p "${settings_home}/.claude"
	python3 - "${settings_home}/.claude/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"permissions": {"deny": ["Bash(git reset --hard *)"], "ask": ["Bash(curl *)"]}}, handle)
PY
	if HOME="$settings_home" python3 "${SCRIPT_DIR}/update-claude-settings.py" >/dev/null &&
		python3 - "${settings_home}/.claude/settings.json" <<'PY'; then
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
matchers = {
    rule.get("matcher")
    for rule in settings.get("hooks", {}).get("PreToolUse", [])
    if any("git_safety_guard.py" in hook.get("command", "") for hook in rule.get("hooks", []))
}
assert {"Bash", "Edit|Write"}.issubset(matchers)
assert "Bash(git reset --hard *)" not in settings["permissions"]["deny"]
assert "Bash(curl *)" not in settings["permissions"]["ask"]
PY
		pass "Claude settings migration removes duplicate decisions and preserves hook surfaces"
	else
		fail "Claude settings migration removes duplicate decisions and preserves hook surfaces"
	fi
	return 0
}

test_policy_fail_closed() {
	local output=""
	local status=0
	local missing_account_guard="${TEST_ROOT}/missing-account-guard.json"
	local missing_process_guard="${TEST_ROOT}/missing-process-guard.json"
	output="$(python3 "$HELPER" check-command --policy "${TEST_ROOT}/missing.json" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *'"decision": "forbid"'* && "$output" == *'"rule_id": "policy.invalid"'* ]]; then
		pass "missing required policy fails closed"
	else
		fail "missing required policy fails closed" "status=${status} output=${output}"
	fi

	local malformed="${TEST_ROOT}/malformed.json"
	printf '{not-json\n' >"$malformed"
	status=0
	output="$(python3 "$HELPER" check-command --policy "$malformed" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *'"decision": "forbid"'* && "$output" == *malformed* ]]; then
		pass "malformed required policy fails closed"
	else
		fail "malformed required policy fails closed" "status=${status} output=${output}"
	fi

	python3 - "$POLICY" "$missing_account_guard" "$missing_process_guard" <<'PY'
import json
import sys

source, account_target, process_target = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    policy = json.load(handle)
for excluded_kind, target in (
    ("trusted_account_mutation", account_target),
    ("process_termination", process_target),
):
    candidate = dict(policy)
    candidate["dynamic_guards"] = [
        guard
        for guard in policy["dynamic_guards"]
        if guard.get("kind") != excluded_kind
    ]
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(candidate, handle)
PY
	status=0
	output="$(python3 "$HELPER" check-command --policy "$missing_account_guard" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *policy.invalid* && "$output" == *account-mutation* ]]; then
		pass "missing account-mutation guard fails closed"
	else
		fail "missing account-mutation guard fails closed" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --policy "$missing_process_guard" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *policy.invalid* && "$output" == *process-termination* ]]; then
		pass "missing process-termination guard fails closed"
	else
		fail "missing process-termination guard fails closed" "status=${status} output=${output}"
	fi

	local malformed_process_guard="${TEST_ROOT}/malformed-process-guard.py"
	printf 'print("{\\"decision\\": \\"allow\\"}")\n' >"$malformed_process_guard"
	status=0
	output="$(python3 "$HELPER" check-command --command "kill 400" \
		--process-termination-guard "$malformed_process_guard" \
		--runtime-pid 200 --runtime-process-identity runtime-a \
		--process-table-fixture "${TEST_ROOT}/processes.json")" || status=$?
	if [[ "$status" -eq 20 && "$output" == *process.guard-error* ]]; then
		pass "malformed process-termination guard output fails closed"
	else
		fail "malformed process-termination guard output fails closed" "status=${status} output=${output}"
	fi

	status=0
	output="$(python3 "$HELPER" check-command --worker --network-helper "${TEST_ROOT}/missing-network-helper.sh" --argv-json '["printf","safe"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.helper-unavailable* ]]; then
		pass "missing required worker network policy fails closed"
	else
		fail "missing required worker network policy fails closed" "status=${status} output=${output}"
	fi

	local malformed_network="${TEST_ROOT}/network-tiers.conf"
	printf '[tier5\nrequestbin.com\n' >"$malformed_network"
	status=0
	output="$(AIDEVOPS_NETWORK_TIER_POLICY="$malformed_network" python3 "$HELPER" check-command --worker --argv-json '["printf","safe"]')" || status=$?
	if [[ "$status" -eq 20 && "$output" == *network.worker-policy* ]]; then
		pass "malformed required worker network policy fails closed"
	else
		fail "malformed required worker network policy fails closed" "status=${status} output=${output}"
	fi
	return 0
}

main() {
	test_validation
	test_evaluate_invocations_compatibility
	test_static_decisions
	test_process_table_parser
	test_process_termination_policy
	test_account_mutation_authorization
	test_canonical_delegation
	test_worker_network_policy
	test_policy_fail_closed
	test_secondary_layers
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
