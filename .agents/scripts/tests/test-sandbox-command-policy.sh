#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
NETWORK_HELPER="${SCRIPT_DIR}/network-tier-helper.sh"
SANDBOX_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="${TEST_ROOT}/home"
TEST_BIN="${TEST_ROOT}/bin"
MARKER="${TEST_ROOT}/executed"
ARGS_LOG="${TEST_ROOT}/args.json"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_HOME" "$TEST_BIN"

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

reset_marker() {
	rm -f "$MARKER"
	return 0
}

write_fake_network_tools() {
	cat >"${TEST_BIN}/curl" <<EOF
#!/usr/bin/env bash
printf 'curl' >"${MARKER}"
python3 - "\$@" >"${ARGS_LOG}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
return 0 2>/dev/null || exit 0
EOF
	cat >"${TEST_BIN}/dig" <<EOF
#!/usr/bin/env bash
printf 'dig' >"${MARKER}"
return 0 2>/dev/null || exit 0
EOF
	chmod +x "${TEST_BIN}/curl" "${TEST_BIN}/dig"
	return 0
}

test_network_check_command() {
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","https://github.com/aidevops"]' --worker-id test >/dev/null 2>&1; then
		pass "network check-argv allows Tier 1"
	else
		fail "network check-argv allows Tier 1"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--url","HTTPS://requestbin.com/collect"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks Tier 5"
	else
		pass "network check-argv blocks Tier 5"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--proxy","https://requestbin.com","--url","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks proxy destination"
	else
		pass "network check-argv blocks proxy destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--connect-to","github.com:443:requestbin.com:443","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks connect-to destination"
	else
		pass "network check-argv blocks connect-to destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--silent"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed without destination"
	else
		pass "network check-argv fails closed without destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["wget","HTTPS://requestbin.com/file"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks wget Tier 5 destination"
	else
		pass "network check-argv blocks wget Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["wget","-e","https_proxy=https://requestbin.com","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks wget proxy override"
	else
		pass "network check-argv blocks wget proxy override"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-p22","user@requestbin.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks ssh Tier 5 destination"
	else
		pass "network check-argv blocks ssh Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["scp","file.txt","user@requestbin.com:/tmp/file.txt"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks scp Tier 5 destination"
	else
		pass "network check-argv blocks scp Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["git","clone","HTTPS://requestbin.com/repo.git"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks git Tier 5 destination"
	else
		pass "network check-argv blocks git Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-V"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on unclassified ssh destination"
	else
		pass "network check-argv fails closed on unclassified ssh destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-F","custom.conf","github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on hidden ssh config"
	else
		pass "network check-argv fails closed on hidden ssh config"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-W","requestbin.com:443","github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks ssh forwarding destination"
	else
		pass "network check-argv blocks ssh forwarding destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["git","-c","http.proxy=https://requestbin.com","fetch","https://github.com/repo.git"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on Git proxy override"
	else
		pass "network check-argv fails closed on Git proxy override"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["printf","curl https://requestbin.com"]' --worker-id test >/dev/null 2>&1; then
		pass "network check-argv ignores printf text"
	else
		fail "network check-argv ignores printf text"
	fi
	# Shell-string compatibility must reject dynamic expansion before execution.
	# shellcheck disable=SC2016
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-command 'dig $(printf data).example.com' --worker-id test >/dev/null 2>&1; then
		fail "network check-command rejects dynamic DNS destination"
	else
		pass "network check-command rejects dynamic DNS destination"
	fi
	return 0
}

LOCALDEV_REGISTRY="${TEST_ROOT}/ports.json"

expect_local_site() {
	local expected="$1"
	local name="$2"
	local argv_json="$3"
	local cwd="$4"
	local registry="${5:-$LOCALDEV_REGISTRY}"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_LOCALDEV_REGISTRY="$registry" \
		"$NETWORK_HELPER" check-argv "$argv_json" --cwd "$cwd" --worker-id test >/dev/null 2>&1 || status=$?
	if [[ "$expected" == "allow" && "$status" -eq 0 ]] || [[ "$expected" == "deny" && "$status" -ne 0 ]]; then
		pass "local site: ${name}"
	else
		fail "local site: ${name}" "expected=${expected} status=${status}"
	fi
	return 0
}

# GH#33523: workers may verify only their repository's registered local site.
test_network_local_site_allowance() {
	local repo="${TEST_ROOT}/demoapp"
	local worktree="${TEST_ROOT}/demoapp-feature-x"
	printf '%s\n' '{"apps":{"demoapp":{"port":3100,"domain":"demoapp.local","branches":{"feature-x":{"port":3101,"subdomain":"feature-x.demoapp.local"}}},"otherapp":{"port":3200,"domain":"otherapp.local"}}}' >"$LOCALDEV_REGISTRY"
	git init -q "$repo" &&
		git -C "$repo" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
			commit -q --allow-empty -m init &&
		git -C "$repo" worktree add -q -b feature-x "$worktree" || {
		fail "local site fixture repository"
		return 0
	}

	expect_local_site allow "registered loopback app port" '["curl","-sI","http://127.0.0.1:3100/wp-admin/"]' "$repo"
	expect_local_site allow "linked worktree uses canonical app name" '["curl","-sI","http://localhost:3101/"]' "$worktree"
	expect_local_site allow "registered https domain" '["curl","-sI","https://demoapp.local/"]' "$worktree"
	expect_local_site allow "registered branch subdomain" '["curl","https://feature-x.demoapp.local/"]' "$worktree"
	expect_local_site allow "documented --resolve mitigation" '["curl","--resolve","demoapp.local:443:127.0.0.1","https://demoapp.local/"]' "$repo"
	expect_local_site allow "wget IPv6 loopback app port" '["wget","-q","-O","-","http://[::1]:3100/"]' "$repo"
	expect_local_site deny "unregistered loopback port" '["curl","http://127.0.0.1:9999/"]' "$repo"
	expect_local_site deny "another repository's app port" '["curl","http://127.0.0.1:3200/"]' "$repo"
	expect_local_site deny "proxy port without registered host" '["curl","http://127.0.0.1:443/"]' "$repo"
	expect_local_site deny "connect-to redirect to unregistered port" '["curl","--connect-to","127.0.0.1:3100:127.0.0.1:22","http://127.0.0.1:3100/"]' "$repo"
	expect_local_site deny "loopback proxy" '["curl","-x","http://127.0.0.1:3100","https://github.com/"]' "$repo"
	expect_local_site deny "private raw IP" '["curl","http://10.0.0.5:3100/"]' "$repo"
	expect_local_site deny "non-HTTP client" '["ssh","-p","3100","127.0.0.1"]' "$repo"
	expect_local_site deny "cwd outside a repository" '["curl","http://127.0.0.1:3100/"]' "$TEST_HOME"
	expect_local_site deny "missing registry" '["curl","http://127.0.0.1:3100/"]' "$repo" "${TEST_ROOT}/missing-ports.json"
	return 0
}

test_network_policy_fail_closed() {
	local malformed="${TEST_ROOT}/network-tiers.conf"
	printf '[tier5\nrequestbin.com\n' >"$malformed"
	if HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_POLICY="${TEST_ROOT}/missing.conf" \
		"$NETWORK_HELPER" check-command "printf safe" >/dev/null 2>&1; then
		fail "missing network policy fails closed"
	else
		pass "missing network policy fails closed"
	fi
	if HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_POLICY="$malformed" \
		"$NETWORK_HELPER" check-command "printf safe" >/dev/null 2>&1; then
		fail "malformed network policy fails closed"
	else
		pass "malformed network policy fails closed"
	fi
	return 0
}

test_network_helper_timeout() {
	if python3 - "$SCRIPT_DIR" "$TEST_ROOT" <<'PY'
import os
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
from command_policy_evaluation import _evaluate_worker_network

helper = Path(sys.argv[2]) / "delayed-network-helper.sh"
# exec avoids leaving a child holding captured pipes open after a timeout.
helper.write_text("exec python3 -c 'import time; time.sleep(11)'\n")
argv = [["git", "push", "origin", "HEAD"]]

def evaluate():
    return _evaluate_worker_network(argv, sys.argv[2], helper, "timeout-test")

with patch.dict(os.environ):
    os.environ.pop("AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS", None)
    # Deterministically reproduce scheduling delay beyond the old 10s budget
    # without saturating a shared runner or actually pushing a branch.
    assert evaluate()["decision"] == "allow"
    with patch("command_policy_evaluation.subprocess.run") as run:
        run.return_value = subprocess.CompletedProcess([], 0, "", "")
        assert evaluate()["decision"] == "allow"
        assert run.call_args.kwargs["timeout"] == 30
        os.environ["AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS"] = "45"
        assert evaluate()["decision"] == "allow"
        assert run.call_args.kwargs["timeout"] == 45
        run.return_value = subprocess.CompletedProcess([], 1, "", "policy denied")
        denied = evaluate()
        assert denied["decision"] == "forbid"
        assert denied["rule_id"] == "network.worker-policy"
        run.side_effect = OSError("helper failed")
        error = evaluate()
        assert error["decision"] == "forbid"
        assert error["rule_id"] == "network.helper-error"
        run.side_effect = OverflowError("timeout exceeds platform limit")
        error = evaluate()
        assert error["decision"] == "forbid"
        assert error["rule_id"] == "network.helper-error"
    for invalid in ("", "0", "-1", "nan", "inf", "1.5", "invalid"):
        os.environ["AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS"] = invalid
        with patch("command_policy_evaluation.subprocess.run") as run:
            invalid_result = evaluate()
            assert invalid_result["decision"] == "forbid"
            assert invalid_result["rule_id"] == "network.helper-error"
            run.assert_not_called()
    os.environ["AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS"] = "1"
    timed_out = evaluate()
    assert timed_out["decision"] == "forbid"
    assert timed_out["rule_id"] == "network.helper-timeout"
    assert "Transient" in timed_out["reason"]
    assert "1 seconds" in timed_out["reason"]
    # Verify classification survives the public worker CLI and its exit status.
    cli = subprocess.run(
        [sys.executable, str(Path(sys.argv[1]) / "command-policy-helper.py"),
         "check-command", "--worker", "--network-helper", str(helper),
         "--argv-json", '["printf", "safe"]', "--cwd", sys.argv[2]],
        capture_output=True, text=True, timeout=15, check=False,
    )
    assert cli.returncode == 20, cli.stderr
    decision = json.loads(cli.stdout)
    assert decision["decision"] == "forbid"
    assert decision["rule_id"] == "network.helper-timeout"
PY
	then
		pass "network helper tolerates delay and classifies timeouts fail-closed"
	else
		fail "network helper tolerates delay and classifies timeouts fail-closed"
	fi
	return 0
}

test_sandbox_enforcement() {
	local status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run curl https://requestbin.com/collect >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox blocks Tier 5 before execution"
	else
		fail "sandbox blocks Tier 5 before execution" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi

	status=0
	reset_marker
	rm -f "$ARGS_LOG"
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run curl "https://github.com/a path" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])) == ["https://github.com/a path"])' "$ARGS_LOG")" == "True" ]]; then
		pass "sandbox preserves exact argv for allowed network command"
	else
		fail "sandbox preserves exact argv for allowed network command" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi

	status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run bash -lc "rm -rf /opt/aidevops-policy-test-nonexistent" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox inspects combined shell flags before execution"
	else
		fail "sandbox inspects combined shell flags before execution" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi
	return 0
}

test_sandbox_required_policy() {
	local status=0
	local malformed="${TEST_ROOT}/command-policy.json"
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" AIDEVOPS_COMMAND_POLICY_HELPER="${TEST_ROOT}/missing.py" \
		"$SANDBOX_HELPER" run curl https://github.com/aidevops >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox fails closed when command policy helper is missing"
	else
		fail "sandbox fails closed when command policy helper is missing" "status=${status}"
	fi

	printf '{not-json\n' >"$malformed"
	status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" AIDEVOPS_COMMAND_POLICY_CONFIG="$malformed" \
		"$SANDBOX_HELPER" run curl https://github.com/aidevops >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox fails closed when command policy is malformed"
	else
		fail "sandbox fails closed when command policy is malformed" "status=${status}"
	fi
	return 0
}

main() {
	write_fake_network_tools
	test_network_check_command
	test_network_local_site_allowance
	test_network_policy_fail_closed
	test_network_helper_timeout
	test_sandbox_enforcement
	test_sandbox_required_policy
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
