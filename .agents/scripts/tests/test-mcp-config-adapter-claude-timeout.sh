#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ADAPTER="${SCRIPT_DIR}/../mcp-config-adapter.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

make_stub_claude() {
	local temp_dir="$1"
	local mode="$2"

	cat >"${temp_dir}/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mode="${mode}"
if [[ "\${1:-} \${2:-}" == "mcp list" ]]; then
	if [[ -n "\${CLAUDE_STUB_LIST_COUNT_FILE:-}" ]]; then
		count=0
		if [[ -f "\$CLAUDE_STUB_LIST_COUNT_FILE" ]]; then
			read -r count <"\$CLAUDE_STUB_LIST_COUNT_FILE" || count=0
		fi
		count=\$((count + 1))
		printf '%s\n' "\$count" >"\$CLAUDE_STUB_LIST_COUNT_FILE"
	fi
	if [[ "\$mode" == "list-hangs" ]]; then
		sleep 5
	fi
	printf 'openapi-search: npx - status\n'
	exit 0
fi
if [[ "\${1:-} \${2:-}" == "mcp add-json" ]]; then
	if [[ "\$mode" == "add-hangs" ]]; then
		sleep 5
	fi
	printf 'added\n'
	exit 0
fi
exit 1
EOF
	chmod +x "${temp_dir}/claude"
	return 0
}

run_claude_registration_with_stub() {
	local mode="$1"
	local temp_dir
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "$temp_dir"' RETURN

	make_stub_claude "$temp_dir" "$mode"

	PATH="${temp_dir}:$PATH" AIDEVOPS_MCP_CLAUDE_TIMEOUT_SECONDS=1 \
		AIDEVOPS_MCP_TIMEOUT_KILL_AFTER_SECONDS=0.2 bash -c '
		set -euo pipefail
		source "$1"
		_register_mcp_claude "macos-automator" "{\"command\":\"npx\",\"args\":[\"-y\",\"@example/mcp\"]}"
	' bash "$ADAPTER"
	trap - RETURN
	rm -rf "$temp_dir"
	return 0
}

run_two_claude_registrations_with_stub() {
	local mode="$1"
	local temp_dir list_count_file list_count
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "$temp_dir"' RETURN
	list_count_file="${temp_dir}/list-count"

	make_stub_claude "$temp_dir" "$mode"

	PATH="${temp_dir}:$PATH" AIDEVOPS_MCP_CLAUDE_TIMEOUT_SECONDS=1 CLAUDE_STUB_LIST_COUNT_FILE="$list_count_file" bash -c '
		set -euo pipefail
		source "$1"
		_mcp_adapter_reset_claude_registration_cache
		_register_mcp_claude "context7" "{\"command\":\"npx\",\"args\":[\"-y\",\"@example/context7\"]}"
		_register_mcp_claude "playwright" "{\"command\":\"npx\",\"args\":[\"-y\",\"@example/playwright\"]}"
	' bash "$ADAPTER" >/dev/null 2>&1

	list_count=0
	if [[ -f "$list_count_file" ]]; then
		read -r list_count <"$list_count_file" || list_count=0
	fi
	trap - RETURN
	rm -rf "$temp_dir"
	printf '%s\n' "$list_count"
	return 0
}

test_claude_mcp_list_timeout_is_non_blocking() {
	local start end duration output
	start="$(date +%s)"
	output="$(run_claude_registration_with_stub "list-hangs" 2>&1)" || true
	end="$(date +%s)"
	duration=$((end - start))

	if [[ "$duration" -lt 4 && "$output" == *"timed out or failed"* ]]; then
		print_result "Claude MCP list timeout is non-blocking" 0
		return 0
	fi

	print_result "Claude MCP list timeout is non-blocking" 1 "duration=${duration} output=${output}"
	return 0
}

test_claude_mcp_add_timeout_is_non_blocking() {
	local start end duration output
	start="$(date +%s)"
	output="$(run_claude_registration_with_stub "add-hangs" 2>&1)" || true
	end="$(date +%s)"
	duration=$((end - start))

	if [[ "$duration" -lt 4 && "$output" == *"Failed or timed out registering"* ]]; then
		print_result "Claude MCP add-json timeout is non-blocking" 0
		return 0
	fi

	print_result "Claude MCP add-json timeout is non-blocking" 1 "duration=${duration} output=${output}"
	return 0
}

test_claude_mcp_list_is_cached_per_registration_pass() {
	local list_count
	list_count="$(run_two_claude_registrations_with_stub "ok")"

	if [[ "$list_count" -eq 1 ]]; then
		print_result "Claude MCP list is cached per registration pass" 0
		return 0
	fi

	print_result "Claude MCP list is cached per registration pass" 1 "list_count=${list_count}"
	return 0
}

test_timeout_terminates_process_group() {
	local temp_dir fixture child_pid_file grandchild_pid_file status child_pid grandchild_pid isolation_mode
	local failure_message=""
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "$temp_dir"' RETURN
	fixture="${temp_dir}/spawn-tree.sh"
	child_pid_file="${temp_dir}/child.pid"
	grandchild_pid_file="${temp_dir}/grandchild.pid"
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
child_pid_file="$1"
grandchild_pid_file="$2"
bash -c 'sleep 30 & printf "%s\n" "$!" >"$1"; wait' bash "$grandchild_pid_file" &
printf '%s\n' "$!" >"$child_pid_file"
wait
EOF
	chmod +x "$fixture"

	for isolation_mode in auto fallback; do
		rm -f "$child_pid_file" "$grandchild_pid_file"
		set +e
		AIDEVOPS_MCP_TIMEOUT_KILL_AFTER_SECONDS=0.2 bash -c '
			set -euo pipefail
			source "$1"
			if [[ "$5" == "fallback" ]]; then
				command() {
					local command_flag="${1:-}"
					local command_name="${2:-}"
					if [[ "$command_flag" == "-v" && "$command_name" == "setsid" ]]; then
						return 1
					fi
					builtin command "$@"
					return $?
				}
			fi
			_mcp_adapter_run_with_timeout 1 "$2" "$3" "$4"
		' bash "$ADAPTER" "$fixture" "$child_pid_file" "$grandchild_pid_file" "$isolation_mode" >/dev/null 2>&1
		status=$?
		set -e

		child_pid="$(read_pid_file "$child_pid_file")" || true
		grandchild_pid="$(read_pid_file "$grandchild_pid_file")" || true
		if [[ "$status" -ne 124 ]] || pid_is_alive "$child_pid" || pid_is_alive "$grandchild_pid"; then
			failure_message="mode=${isolation_mode} status=${status} child=${child_pid:-missing} grandchild=${grandchild_pid:-missing}"
			break
		fi
	done

	trap - RETURN
	rm -rf "$temp_dir"
	if [[ -z "$failure_message" ]]; then
		print_result "timeout terminates process group with setsid and portable fallback" 0
		return 0
	fi

	print_result "timeout terminates child and grandchild process group" 1 \
		"$failure_message"
	return 0
}

read_pid_file() {
	local pid_file="$1"
	local pid=""
	local attempts=20

	while [[ "$attempts" -gt 0 ]]; do
		if [[ -s "$pid_file" ]]; then
			read -r pid <"$pid_file" || pid=""
			printf '%s\n' "$pid"
			return 0
		fi
		sleep 0.1
		attempts=$((attempts - 1))
	done
	return 1
}

pid_is_alive() {
	local pid="$1"
	[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
	return $?
}

test_success_preserves_output_and_status() {
	local output status failure_status

	set +e
	output="$(bash -c '
		set -euo pipefail
		source "$1"
		_mcp_adapter_run_with_timeout 5 bash -c '\''printf "ready\\n"; exit 0'\''
	' bash "$ADAPTER")"
	status=$?
	bash -c '
		set -euo pipefail
		source "$1"
		_mcp_adapter_run_with_timeout 5 bash -c '\''exit 7'\''
	' bash "$ADAPTER" >/dev/null 2>&1
	failure_status=$?
	set -e

	if [[ "$status" -eq 0 && "$output" == "ready" && "$failure_status" -eq 7 ]]; then
		print_result "successful command preserves output and status" 0
		return 0
	fi

	print_result "successful command preserves output and status" 1 \
		"status=${status} failure_status=${failure_status} output=${output}"
	return 0
}

test_playwright_launcher_migrations() {
	local status=0
	python3 - "$ADAPTER" "${SCRIPT_DIR}/../setup/modules/config.sh" <<'PYEOF' || status=$?
import json, os, pathlib, subprocess, sys, tempfile

adapter, setup = sys.argv[1:]
old = {"command": "npx", "args": ["-y", "@playwright/mcp@0.0.79", "--headless", "--isolated"]}
variants = [old, dict(old, env={}), dict(old, command="custom-npx"),
            dict(old, args=old["args"] + ["--port", "9000"]),
            dict(old, env={"CUSTOM": "yes"}), dict(old, extra=True)]
with tempfile.TemporaryDirectory() as tmp:
    home = pathlib.Path(tmp)
    stub = home / "claude"
    stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path.home() / ".claude.json"
cfg = json.loads(p.read_text())
op = sys.argv[2]
with (pathlib.Path.home() / "calls").open("a") as f:
    f.write(op + "\\n")
if op == "list":
    print("playwright: npx - status")
elif op == "remove":
    del cfg["mcpServers"][sys.argv[3]]
    p.write_text(json.dumps(cfg))
elif op == "add-json":
    cfg["mcpServers"][sys.argv[3]] = json.loads(sys.argv[6])
    p.write_text(json.dumps(cfg))
else:
    sys.exit(1)
''')
    stub.chmod(0o755)
    env = dict(os.environ, HOME=tmp, PATH=tmp + os.pathsep + os.environ["PATH"],
               AIDEVOPS_MCP_CLAUDE_TIMEOUT_SECONDS="1", AIDEVOPS_MCP_TIMEOUT_KILL_AFTER_SECONDS="0.2")
    launcher = str(home / ".aidevops/agents/scripts/browser-mcp-launcher.sh")
    new = {"command": "bash", "args": [launcher, "playwright", "npx", *old["args"]]}
    paths = {"cursor": ".cursor/mcp.json", "windsurf": ".codeium/windsurf/mcp_config.json",
             "gemini": ".gemini/settings.json", "kilo": ".kilo/mcp.json",
             "kiro": ".kiro/settings/mcp.json", "amp": ".amp/settings.json",
             "claude": ".claude.json", "setup": ".cursor/mcp.json"}
    for runtime, relative in paths.items():
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        for index, entry in enumerate(variants):
            if runtime == "claude":
                entry = dict(entry, type="stdio")
            # Cursor setup registers other defaults too; preseed to isolate writes.
            cfg = {"keep": {"setting": True}, "mcpServers": {
                "playwright": entry, "other": {"command": "custom"},
                **{n: {"custom": True} for n in ["context7", "shadcn", "openapi-search", "cloudflare-api"]}}}
            path.write_text(json.dumps(cfg, separators=(",", ":")))
            before = path.read_bytes()
            calls = home / "calls"
            calls.unlink(missing_ok=True)
            if runtime == "setup":
                script = 'source "$1"; _deploy_cursor_mcps; _deploy_cursor_mcps'
                args = [setup]
            elif runtime == "claude":
                script = 'source "$1"; _register_mcp_claude playwright "$2"; _register_mcp_claude playwright "$2"'
                args = [adapter, json.dumps(new)]
            else:
                script = 'source "$1"; _register_mcp_mcpservers "$2" playwright "$3"; _register_mcp_mcpservers "$2" playwright "$3"'
                args = [adapter, runtime, json.dumps(new)]
            subprocess.run(["bash", "-euc", script, "bash", *args], env=env, check=True, stdout=subprocess.DEVNULL)
            after = path.read_bytes()
            result = json.loads(after)
            assert result["keep"] == cfg["keep"] and result["mcpServers"]["other"] == cfg["mcpServers"]["other"]
            if index < 2:
                assert result["mcpServers"]["playwright"]["command"] == "bash", runtime
                assert result["mcpServers"]["playwright"]["args"] == new["args"], runtime
            else:
                assert after == before, (runtime, index, "custom entry rewritten")
            # A fresh registration pass must also leave the migrated bytes intact.
            subprocess.run(["bash", "-euc", script, "bash", *args], env=env, check=True, stdout=subprocess.DEVNULL)
            assert path.read_bytes() == after, (runtime, "not idempotent")
            if runtime == "claude":
                operations = calls.read_text().splitlines()
                assert operations.count("list") == 2, operations
                assert operations.count("remove") == (1 if index < 2 else 0), operations
                assert operations.count("add-json") == (1 if index < 2 else 0), operations
PYEOF
	print_result "Playwright exact-default migration, custom preservation and idempotency across runtimes" "$status"
	return 0
}

main() {
	test_claude_mcp_list_timeout_is_non_blocking
	test_claude_mcp_add_timeout_is_non_blocking
	test_claude_mcp_list_is_cached_per_registration_pass
	test_timeout_terminates_process_group
	test_success_preserves_output_and_status
	test_playwright_launcher_migrations

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
