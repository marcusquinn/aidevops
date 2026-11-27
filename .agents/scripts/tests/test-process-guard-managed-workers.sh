#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/process-guard-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/process-guard-managed.XXXXXX")"
export HOME="${TEST_ROOT}/home"
export AIDEVOPS_PROCESS_GUARD_PROC_ROOT="${TEST_ROOT}/proc"
mkdir -p "$HOME" "$AIDEVOPS_PROCESS_GUARD_PROC_ROOT"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../process-guard-helper.sh
source "$HELPER"

TESTS_RUN=0
TESTS_FAILED=0
MOCK_PROCESS_LINE=""
MOCK_PROCESS_AGE=0
MOCK_KILL_LOG="${TEST_ROOT}/kill.log"
MOCK_PLATFORM="Linux"
MOCK_EXECUTABLE_PATH=""
MOCK_COMMAND=""
MOCK_COMMANDS=""
MOCK_LAUNCHD_PID=""
# Space-separated "pid:ppid" pairs for the lineage walk.
MOCK_PARENTS=""
MOCK_CHILDREN=""
MOCK_CHILD_STATUS=1
DESKTOP_CLI="/Users/test/Library/Application Support/ai.opencode.desktop/cli/2.0.24/opencode-cli"

pgrep() {
	local option="${1:-}"
	if [[ "$option" == "-P" ]]; then
		printf '%s' "$MOCK_CHILDREN"
		return "$MOCK_CHILD_STATUS"
	fi
	command pgrep "$@"
	return $?
}

_process_guard_platform() {
	printf '%s' "$MOCK_PLATFORM"
	return 0
}

_get_process_executable_path() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_EXECUTABLE_PATH"
	return 0
}

_get_process_command() {
	local pid="$1"
	local entry=""
	# Newline-separated "pid|command" entries override MOCK_COMMAND per PID.
	if [[ -n "$MOCK_COMMANDS" ]]; then
		while IFS= read -r entry; do
			if [[ "${entry%%|*}" == "$pid" ]]; then
				printf '%s' "${entry#*|}"
				return 0
			fi
		done <<<"$MOCK_COMMANDS"
		return 0
	fi
	printf '%s' "$MOCK_COMMAND"
	return 0
}

_launchd_job_pid() {
	local label="$1"
	: "$label"
	printf '%s' "$MOCK_LAUNCHD_PID"
	return 0
}

_get_process_parent_pid() {
	local pid="$1"
	local pair=""
	for pair in $MOCK_PARENTS; do
		if [[ "${pair%%:*}" == "$pid" ]]; then
			printf '%s' "${pair#*:}"
			return 0
		fi
	done
	printf '%s' "1"
	return 0
}

reset_macos_mocks() {
	MOCK_PLATFORM="Darwin"
	MOCK_EXECUTABLE_PATH=""
	MOCK_COMMAND=""
	MOCK_LAUNCHD_PID=""
	MOCK_PARENTS=""
	return 0
}

_list_ai_processes() {
	printf '%s\n' "$MOCK_PROCESS_LINE"
	return 0
}

_get_process_age() {
	local pid="$1"
	: "$pid"
	printf '%s' "$MOCK_PROCESS_AGE"
	return 0
}

_get_process_cwd() {
	local pid="$1"
	: "$pid"
	printf '%s' "${TEST_ROOT}/worktree"
	return 0
}

kill() {
	printf '%s\n' "$*" >>"$MOCK_KILL_LOG"
	return 0
}

sleep() {
	local seconds="$1"
	: "$seconds"
	return 0
}

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n     expected=%s actual=%s\n' "$test_name" "$expected" "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_cgroup() {
	local pid="$1"
	local cgroup_path="$2"
	mkdir -p "${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}"
	printf '0::%s\n' "$cgroup_path" >"${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}/cgroup"
	return 0
}

write_hybrid_cgroup() {
	local pid="$1"
	local cgroup_path="$2"
	mkdir -p "${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}"
	printf '13:pids:/user.slice/user-1000.slice/user@1000.service\n1:name=systemd:%s\n0::%s\n' \
		"$cgroup_path" "$cgroup_path" >"${AIDEVOPS_PROCESS_GUARD_PROC_ROOT}/${pid}/cgroup"
	return 0
}

test_managed_worker_runtime_is_delegated() {
	write_cgroup 4101 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-17.service'
	local actual
	actual=$(_classify_runtime_limit 4101 2064 600)
	assert_eq "managed worker older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_managed_worker_descendant_is_delegated() {
	write_cgroup 4102 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-17.service/runtime.scope'
	local actual
	actual=$(_classify_runtime_limit 4102 966 600)
	assert_eq "managed worker descendant inherits service protection" "MANAGED" "$actual"
	return 0
}

test_managed_observer_runtime_is_delegated() {
	write_cgroup 4103 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-observer-27693-4001-18.service'
	local actual
	actual=$(_classify_runtime_limit 4103 1200 600)
	assert_eq "managed worker observer is delegated" "MANAGED" "$actual"
	return 0
}

test_opencode_web_service_runtime_is_delegated() {
	write_hybrid_cgroup 4104 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service'
	local actual
	actual=$(_classify_runtime_limit 4104 7210 7200)
	assert_eq "OpenCode web server older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_opencode_web_service_descendant_is_delegated() {
	write_cgroup 4105 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service/browser.scope'
	local actual
	actual=$(_classify_runtime_limit 4105 9000 7200)
	assert_eq "OpenCode web-service descendant inherits protection" "MANAGED" "$actual"
	return 0
}

test_opencode_web_template_service_is_delegated() {
	write_cgroup 4106 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web@4096.service'
	local actual
	actual=$(_classify_runtime_limit 4106 9000 7200)
	assert_eq "OpenCode web template service inherits protection" "MANAGED" "$actual"
	return 0
}

test_opencode_web_watchdog_service_is_delegated() {
	write_hybrid_cgroup 4107 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web-watchdog.service'
	local actual
	actual=$(_classify_runtime_limit 4107 7210 7200)
	assert_eq "OpenCode web watchdog older than generic limit is delegated" "MANAGED" "$actual"
	return 0
}

test_unmanaged_lookalike_remains_over_limit() {
	write_cgroup 4201 '/user.slice/user-1000.slice/session-2.scope'
	local actual
	actual=$(_classify_runtime_limit 4201 966 600)
	assert_eq "unmanaged process remains eligible" "OVER" "$actual"
	return 0
}

test_command_string_is_not_lineage_evidence() {
	write_cgroup 4202 '/user.slice/user-1000.slice/aidevops-worker-not-a-real-unit.scope'
	local actual
	actual=$(_classify_runtime_limit 4202 966 600)
	assert_eq "worker-like cgroup text without valid service identity is rejected" "OVER" "$actual"
	return 0
}

test_opencode_web_scope_lookalike_remains_over_limit() {
	write_cgroup 4203 '/user.slice/user-1000.slice/opencode-web.scope'
	local actual
	actual=$(_classify_runtime_limit 4203 7210 7200)
	assert_eq "OpenCode-like scope without service identity is rejected" "OVER" "$actual"
	return 0
}

test_unavailable_cgroup_keeps_existing_behavior() {
	local actual
	actual=$(_classify_runtime_limit 4301 966 600)
	assert_eq "missing cgroup evidence fails closed to generic guard" "OVER" "$actual"
	return 0
}

test_fresh_managed_worker_is_not_misreported() {
	write_cgroup 4401 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-19.service'
	local actual
	actual=$(_classify_runtime_limit 4401 300 600)
	assert_eq "fresh worker remains under limit" "OK" "$actual"
	return 0
}

test_kill_runaways_skips_managed_worker() {
	write_cgroup 4501 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-20.service'
	MOCK_PROCESS_LINE='4501 1 ? 1024 16:06 bash /usr/bin/bash worker-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips old managed worker" "No runaway processes found" "$output"
	assert_eq "managed worker receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_skips_opencode_web_service() {
	write_hybrid_cgroup 4504 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web.service'
	MOCK_PROCESS_LINE='4504 1 ? 2860032 2:00:10 /home/test/.opencode/bin/opencode serve --port 4096'
	MOCK_PROCESS_AGE=7210
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=4194304
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips long-running OpenCode web service" "No runaway processes found" "$output"
	assert_eq "OpenCode web service receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_skips_opencode_web_watchdog() {
	write_hybrid_cgroup 4505 '/user.slice/user-1000.slice/user@1000.service/app.slice/opencode-web-watchdog.service'
	MOCK_PROCESS_LINE='4505 1 ? 3072 2:00:10 bash /home/test/.local/bin/opencode-web-watchdog.sh'
	MOCK_PROCESS_AGE=7210
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=4194304
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	assert_eq "kill path skips long-running OpenCode web watchdog" "No runaway processes found" "$output"
	assert_eq "OpenCode web watchdog receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	return 0
}

test_kill_runaways_keeps_unmanaged_cleanup() {
	write_cgroup 4502 '/user.slice/user-1000.slice/session-2.scope'
	MOCK_PROCESS_LINE='4502 1 ? 1024 16:06 bash /usr/bin/bash stale-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	if [[ "$output" == *"Killing PID 4502"* && "$(<"$MOCK_KILL_LOG")" == *"4502"* ]]; then
		assert_eq "unmanaged orphan remains kill-eligible" "eligible" "eligible"
	else
		assert_eq "unmanaged orphan remains kill-eligible" "kill signal for 4502" "$output / $(<"$MOCK_KILL_LOG")"
	fi
	return 0
}

test_status_matches_kill_exemption() {
	write_cgroup 4503 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-worker-27693-4001-21.service'
	MOCK_PROCESS_LINE='4503 1 ? 1024 16:06 bash /usr/bin/bash worker-wrapper opencode run'
	MOCK_PROCESS_AGE=966
	CHILD_RUNTIME_LIMIT=600
	local output
	output=$(cmd_status)
	if [[ "$output" == *'"violations":0'* ]]; then
		assert_eq "status excludes managed runtime from violations" "0" "0"
	else
		assert_eq "status excludes managed runtime from violations" '"violations":0' "$output"
	fi
	return 0
}

test_linux_opencode_server_unit_is_delegated() {
	MOCK_PLATFORM="Linux"
	write_cgroup 4601 '/user.slice/user-1000.slice/user@1000.service/app.slice/aidevops-opencode-server.service'
	local actual
	actual=$(_classify_runtime_limit 4601 7210 7200)
	assert_eq "Linux aidevops OpenCode server unit is delegated" "MANAGED" "$actual"
	return 0
}

test_macos_opencode_server_lineage_is_delegated() {
	reset_macos_mocks
	MOCK_LAUNCHD_PID=4700
	MOCK_PARENTS="4702:4701 4701:4700 4700:1"
	assert_eq "macOS launchd OpenCode server job is delegated" "MANAGED" "$(_classify_runtime_limit 4700 7210 7200)"
	assert_eq "macOS launchd OpenCode server descendant is delegated" "MANAGED" "$(_classify_runtime_limit 4702 7210 7200)"
	assert_eq "macOS launchd owner label" "opencode-server-service" "$(_runtime_management_owner 4702)"
	return 0
}

test_macos_unrelated_or_missing_server_job_stays_over() {
	reset_macos_mocks
	MOCK_LAUNCHD_PID=4700
	MOCK_PARENTS="4710:1"
	assert_eq "macOS process outside server lineage stays eligible" "OVER" "$(_classify_runtime_limit 4710 7210 7200)"
	MOCK_LAUNCHD_PID=""
	MOCK_PARENTS="4702:4701 4701:4700"
	assert_eq "macOS lineage without running server job stays eligible" "OVER" "$(_classify_runtime_limit 4702 7210 7200)"
	return 0
}

test_macos_desktop_bundle_processes_are_delegated() {
	reset_macos_mocks
	local bundle="/Applications/OpenCode.app/Contents"
	MOCK_EXECUTABLE_PATH="${bundle}/Frameworks/OpenCode Helper (GPU).app/Contents/MacOS/OpenCode Helper (GPU)"
	assert_eq "desktop Electron helper is delegated" "MANAGED" "$(_classify_runtime_limit 4801 7231 7200)"
	MOCK_EXECUTABLE_PATH="${bundle}/Frameworks/Squirrel.framework/Resources/ShipIt"
	assert_eq "desktop Squirrel ShipIt is delegated" "MANAGED" "$(_classify_runtime_limit 4802 7231 7200)"
	assert_eq "desktop owner label" "opencode-desktop-app" "$(_runtime_management_owner 4802)"
	return 0
}

test_macos_desktop_cli_only_serve_is_delegated() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="$DESKTOP_CLI"
	MOCK_COMMAND="${DESKTOP_CLI} serve --service"
	assert_eq "desktop bundled server is delegated" "MANAGED" "$(_classify_runtime_limit 4803 7231 7200)"
	MOCK_COMMAND="${DESKTOP_CLI} run --model x serve"
	assert_eq "desktop bundled CLI run stays eligible" "OVER" "$(_classify_runtime_limit 4804 7231 7200)"
	MOCK_COMMAND="opencode-cli serve --service"
	assert_eq "relative argv0 bundled server is delegated" "MANAGED" "$(_classify_runtime_limit 4805 7231 7200)"
	MOCK_COMMAND="renamed-argv serve --service"
	assert_eq "unparseable argv fails closed" "OVER" "$(_classify_runtime_limit 4808 7231 7200)"
	return 0
}

test_desktop_argv_text_is_not_ownership_evidence() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="/bin/sleep"
	MOCK_COMMAND="/fake/OpenCode.app/Contents/MacOS/OpenCode --user-data-dir=ai.opencode.desktop"
	assert_eq "spoofed desktop argv stays eligible" "OVER" "$(_classify_runtime_limit 4806 7231 7200)"
	MOCK_PLATFORM="Linux"
	MOCK_EXECUTABLE_PATH="/opt/OpenCode.app/Contents/MacOS/OpenCode"
	assert_eq "desktop path classification is macOS-only" "OVER" "$(_classify_runtime_limit 4807 7231 7200)"
	return 0
}

test_kill_runaways_desktop_runtime_skipped_rss_enforced() {
	reset_macos_mocks
	MOCK_EXECUTABLE_PATH="/Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer).app/Contents/MacOS/OpenCode Helper (Renderer)"
	MOCK_PROCESS_LINE='4901 4900 ?? 693248 02:00:31 /Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer).app/Contents/MacOS/OpenCode Helper (Renderer) --user-data-dir=/Users/test/Library/Application Support/ai.opencode.desktop'
	MOCK_PROCESS_AGE=7231
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=8388608
	: >"$MOCK_KILL_LOG"
	assert_eq "kill path skips old desktop helper" "No runaway processes found" "$(cmd_kill_runaways)"
	assert_eq "desktop helper receives no signal" "" "$(<"$MOCK_KILL_LOG")"
	CHILD_RSS_LIMIT_KB=524288
	: >"$MOCK_KILL_LOG"
	local output
	output=$(cmd_kill_runaways)
	if [[ "$output" == *"Killing PID 4901"* && "$(<"$MOCK_KILL_LOG")" == *"4901"* ]]; then
		assert_eq "desktop helper over RSS limit remains kill-eligible" "eligible" "eligible"
	else
		assert_eq "desktop helper over RSS limit remains kill-eligible" "kill signal for 4901" "$output / $(<"$MOCK_KILL_LOG")"
	fi
	MOCK_PLATFORM="Linux"
	return 0
}

test_bounded_operation_supervisor_runtime_and_rss() {
	reset_macos_mocks
	local platform=""
	local output=""
	local script="${TEST_ROOT}/plugins/opencode-aidevops/bounded-operation-supervisor.mjs"
	for platform in Linux Darwin; do
		MOCK_PLATFORM="$platform"
		MOCK_COMMAND="node $script"
		assert_eq "$platform supervisor runtime is delegated" "MANAGED" "$(_classify_runtime_limit 4951 7300 7200)"
		assert_eq "$platform supervisor owner label" "bounded-operation-supervisor" "$(_runtime_management_owner 4951)"
		MOCK_COMMAND="/opt/homebrew/bin/node $script"
		assert_eq "$platform absolute Node path is delegated" "MANAGED" "$(_classify_runtime_limit 4951 7300 7200)"
		MOCK_PROCESS_LINE="4951 4950 ? 1024 02:01:40 $MOCK_COMMAND"
		MOCK_PROCESS_AGE=7300
		CHILD_RUNTIME_LIMIT=7200
		CHILD_RSS_LIMIT_KB=8388608
		: >"$MOCK_KILL_LOG"
		assert_eq "$platform kill path skips old supervisor" "No runaway processes found" "$(cmd_kill_runaways)"
		assert_eq "$platform supervisor receives no runtime signal" "" "$(<"$MOCK_KILL_LOG")"
		output=$(cmd_scan)
		assert_eq "$platform scan delegates supervisor runtime" "yes" "$(if [[ "$output" == *MANAGED* && "$output" == *bounded-operation-supervisor* ]]; then printf yes; fi)"
		CHILD_RSS_LIMIT_KB=512
		output=$(cmd_kill_runaways)
		assert_eq "$platform supervisor remains RSS kill-eligible" "yes" "$(if [[ "$output" == *"Killing PID 4951"* && "$(<"$MOCK_KILL_LOG")" == *4951* ]]; then printf yes; fi)"
	done
	for MOCK_COMMAND in "node ${TEST_ROOT}/job.mjs" "bash $script" "node -e $script" "node ${TEST_ROOT}/job.mjs $script" "node $script --extra" "node ${script}.bak" "node ${TEST_ROOT}/bounded-operation-supervisor.mjs"; do
		assert_eq "lookalike stays runtime-governed: $MOCK_COMMAND" "OVER" "$(_classify_runtime_limit 4951 7300 7200)"
	done
	MOCK_COMMAND=""
	MOCK_PLATFORM="Linux"
	return 0
}

test_buzz_acp_runtime_delegated_rss_enforced() {
	reset_macos_mocks
	local agents="${HOME}/.aidevops/agents/scripts"
	local worktree="${TEST_ROOT}/worktrees/repo-buzz"
	local proxy="node ${agents}/team-interface-acp-cwd-proxy.mjs --cwd ${worktree} --no-publish -- ${agents}/opencode-launcher-helper.sh remote-interactive --overlay ${TEST_ROOT}/o.json --dir ${worktree} --session-id host-agent-plugin"
	local acp="/opt/homebrew/bin/opencode acp --cwd ${worktree}"
	local output=""
	MOCK_COMMANDS="5001|${proxy}
5002|${acp}
5003|node /usr/lib/node_modules/opencode-ai/bin/opencode acp --cwd /w
5004|/usr/lib/node_modules/opencode-ai/bin/.opencode acp --cwd /w
5010|node ${TEST_ROOT}/job.mjs ${agents}/team-interface-acp-cwd-proxy.mjs --cwd /w --no-publish -- ${agents}/opencode-launcher-helper.sh remote-interactive
5011|node ${agents}/team-interface-acp-cwd-proxy.mjs --cwd /w -- ${agents}/opencode-launcher-helper.sh remote-interactive
5012|${acp}
5013|/opt/homebrew/bin/opencode run --cwd /w
5020|bash ${agents}/opencode-launcher-helper.sh remote-interactive
5021|${acp}"
	MOCK_PARENTS="5002:5001 5003:5001 5004:5003 5012:4999 5013:5001 5021:5020"
	assert_eq "Buzz ACP proxy is delegated" "MANAGED" "$(_classify_runtime_limit 5001 7259 7200)"
	assert_eq "Buzz ACP owner label" "buzz-acp-plugin" "$(_runtime_management_owner 5001)"
	assert_eq "opencode acp child of the proxy is delegated" "MANAGED" "$(_classify_runtime_limit 5002 7259 7200)"
	assert_eq "npm opencode acp wrapper is delegated" "MANAGED" "$(_classify_runtime_limit 5003 7259 7200)"
	assert_eq "npm opencode acp binary under wrapper is delegated" "MANAGED" "$(_classify_runtime_limit 5004 7259 7200)"
	assert_eq "Node mentioning the proxy in arguments stays eligible" "OVER" "$(_classify_runtime_limit 5010 7259 7200)"
	assert_eq "proxy without --no-publish stays eligible" "OVER" "$(_classify_runtime_limit 5011 7259 7200)"
	assert_eq "opencode acp without a proxy parent stays eligible" "OVER" "$(_classify_runtime_limit 5012 7259 7200)"
	assert_eq "non-acp opencode under the proxy stays eligible" "OVER" "$(_classify_runtime_limit 5013 7259 7200)"
	assert_eq "opencode acp under a non-proxy launcher stays eligible" "OVER" "$(_classify_runtime_limit 5021 7259 7200)"
	MOCK_PROCESS_LINE="5001 4990 ?? 32768 02:00:59 ${proxy}"
	MOCK_PROCESS_AGE=7259
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=8388608
	: >"$MOCK_KILL_LOG"
	assert_eq "kill path skips old Buzz ACP proxy" "No runaway processes found" "$(cmd_kill_runaways)"
	assert_eq "Buzz ACP proxy receives no runtime signal" "" "$(<"$MOCK_KILL_LOG")"
	CHILD_RSS_LIMIT_KB=512
	output=$(cmd_kill_runaways)
	assert_eq "Buzz ACP proxy remains RSS kill-eligible" "yes" "$(if [[ "$output" == *"Killing PID 5001"* && "$(<"$MOCK_KILL_LOG")" == *5001* ]]; then printf yes; fi)"
	MOCK_COMMANDS=""
	MOCK_PLATFORM="Linux"
	return 0
}

test_stale_bounded_operation_supervisor_reaping() {
	reset_macos_mocks
	local script="${TEST_ROOT}/old-bundle/agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs"
	local output="" platform=""
	MOCK_COMMAND="node $script"
	MOCK_PROCESS_LINE="4952 1 ? 1024 2-00:00:00 $MOCK_COMMAND"
	MOCK_PROCESS_AGE=172800
	CHILD_RUNTIME_LIMIT=7200
	CHILD_RSS_LIMIT_KB=8388608
	MOCK_CHILDREN=""
	MOCK_CHILD_STATUS=1
	for platform in Linux Darwin; do
		MOCK_PLATFORM="$platform"
		: >"$MOCK_KILL_LOG"
		assert_eq "$platform stale missing supervisor exceeds runtime" "OVER" "$(_classify_runtime_limit 4952 172800 7200)"
		assert_eq "$platform stale supervisor has no lifecycle owner" "" "$(_runtime_management_owner 4952)"
		output=$(cmd_scan)
		assert_eq "$platform scan identifies stale supervisor violation" "yes" "$(if [[ "$output" == *OVER* ]]; then printf yes; fi)"
		assert_eq "$platform scan never signals" "" "$(<"$MOCK_KILL_LOG")"
		output=$(cmd_kill_runaways)
		assert_eq "$platform stale orphan gets only direct SIGKILL" "-9 4952" "$(<"$MOCK_KILL_LOG")"
		assert_eq "$platform reap is explained" "yes" "$(if [[ "$output" == *"stale orphan bounded-operation supervisor"* ]]; then printf yes; fi)"
		MOCK_PARENTS="4952:4950"
		: >"$MOCK_KILL_LOG"
		assert_eq "$platform live parent protects even exhausted supervisor" "No runaway processes found" "$(cmd_kill_runaways)"
		assert_eq "$platform live parent receives no signal" "" "$(<"$MOCK_KILL_LOG")"
		MOCK_PARENTS=""
	done
	MOCK_PLATFORM="Linux"
	MOCK_PROCESS_AGE=86700
	assert_eq "budget plus maximum grace boundary is protected" "No runaway processes found" "$(cmd_kill_runaways)"
	MOCK_PROCESS_AGE=86400
	assert_eq "maximum budget boundary is protected" "MANAGED" "$(_classify_runtime_limit 4952 86400 7200)"
	MOCK_PROCESS_AGE=86701
	MOCK_CHILDREN=4953
	MOCK_CHILD_STATUS=0
	assert_eq "supervisor with children remains protected" "No runaway processes found" "$(cmd_kill_runaways)"
	MOCK_CHILDREN=""
	MOCK_CHILD_STATUS=2
	assert_eq "failed child inspection remains protected" "No runaway processes found" "$(cmd_kill_runaways)"
	MOCK_CHILD_STATUS=1
	mkdir -p "${script%/*}" "${TEST_ROOT}/old-bundle/agents" "${HOME}/.aidevops/agents"
	: >"$script"
	printf '3.39.289\n' >"${HOME}/.aidevops/agents/VERSION"
	printf '3.39.277\n' >"${TEST_ROOT}/old-bundle/agents/VERSION"
	assert_eq "existing older bundle is reapable" "OVER" "$(_classify_runtime_limit 4952 86701 7200)"
	printf '3.39.289\n' >"${TEST_ROOT}/old-bundle/agents/VERSION"
	assert_eq "current bundle remains protected" "No runaway processes found" "$(cmd_kill_runaways)"
	printf '3.40.0\n' >"${TEST_ROOT}/old-bundle/agents/VERSION"
	assert_eq "newer bundle remains protected" "MANAGED" "$(_classify_runtime_limit 4952 86701 7200)"
	printf 'unknown\n' >"${TEST_ROOT}/old-bundle/agents/VERSION"
	assert_eq "invalid version is not stale evidence" "MANAGED" "$(_classify_runtime_limit 4952 86701 7200)"
	assert_eq "protected supervisors received no signals" "" "$(<"$MOCK_KILL_LOG")"
	MOCK_COMMAND=""
	return 0
}

test_command_basename_handles_spaced_paths() {
	local spaced_dir="${TEST_ROOT}/Library/Application Support/ai.opencode.desktop/cli/2.0.24"
	mkdir -p "$spaced_dir"
	: >"${spaced_dir}/opencode-cli"
	assert_eq "basename keeps spaced executable path" "opencode-cli" \
		"$(_command_basename "${spaced_dir}/opencode-cli serve --service")"
	assert_eq "basename of plain command" "shellcheck" "$(_command_basename "/usr/bin/shellcheck --shell=bash x.sh")"
	assert_eq "basename of relative command" "bash" "$(_command_basename "bash /usr/bin/bash worker-wrapper")"
	return 0
}

main() {
	test_managed_worker_runtime_is_delegated
	test_managed_worker_descendant_is_delegated
	test_managed_observer_runtime_is_delegated
	test_opencode_web_service_runtime_is_delegated
	test_opencode_web_service_descendant_is_delegated
	test_opencode_web_template_service_is_delegated
	test_opencode_web_watchdog_service_is_delegated
	test_unmanaged_lookalike_remains_over_limit
	test_command_string_is_not_lineage_evidence
	test_opencode_web_scope_lookalike_remains_over_limit
	test_unavailable_cgroup_keeps_existing_behavior
	test_fresh_managed_worker_is_not_misreported
	test_kill_runaways_skips_managed_worker
	test_kill_runaways_skips_opencode_web_service
	test_kill_runaways_skips_opencode_web_watchdog
	test_kill_runaways_keeps_unmanaged_cleanup
	test_status_matches_kill_exemption
	test_linux_opencode_server_unit_is_delegated
	test_macos_opencode_server_lineage_is_delegated
	test_macos_unrelated_or_missing_server_job_stays_over
	test_macos_desktop_bundle_processes_are_delegated
	test_macos_desktop_cli_only_serve_is_delegated
	test_desktop_argv_text_is_not_ownership_evidence
	test_kill_runaways_desktop_runtime_skipped_rss_enforced
	test_bounded_operation_supervisor_runtime_and_rss
	test_buzz_acp_runtime_delegated_rss_enforced
	test_stale_bounded_operation_supervisor_reaping
	test_command_basename_handles_spaced_paths

	printf '\n%s/%s tests passed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
