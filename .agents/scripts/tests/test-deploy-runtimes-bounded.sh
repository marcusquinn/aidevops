#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for _deploy_agents_to_runtimes_bounded (GH#22087).
# Verifies that the bounded wrapper:
#   1. Returns 0 when deploy_agents_to_runtimes completes quickly.
#   2. Kills a slow deployment within AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT seconds and
#      returns 0 because runtime deployment is non-critical during setup postflight.
#   3. The bounded wrapper is wired into setup.sh's non-interactive path.
#
# Note on process-group cleanup: deploy_agents_to_runtimes does not start any
# background processes of its own (all file operations are synchronous). The bounded
# wrapper's kill of the subshell PID is therefore sufficient — there are no orphaned
# descendants in the real use case.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENT_RUNTIME_SH="${REPO_ROOT}/.agents/scripts/setup/modules/agent-runtime.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DIR=""
TEST_TMP_DIRS=()

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

cleanup() {
	local tmp_dir
	for tmp_dir in "${TEST_TMP_DIRS[@]}"; do
		if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
			rm -rf "$tmp_dir"
		fi
	done
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}

make_test_tmp_dir() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	TEST_TMP_DIRS+=("$tmp_dir")
	printf '%s\n' "$tmp_dir"
	return 0
}

# Write a self-contained test script that stubs deploy_agents_to_runtimes and
# inlines the bounded wrapper implementation for isolation.
_write_bounded_wrapper_script() {
	local out_file="$1"
	local deploy_body="$2"  # shell body for deploy_agents_to_runtimes stub
	local timeout_s="$3"    # AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT value

	cat >"$out_file" <<SCRIPT_EOF
#!/usr/bin/env bash
set -uo pipefail
print_info()    { :; return 0; }
print_warning() { :; return 0; }
print_success() { :; return 0; }

deploy_agents_to_runtimes() {
${deploy_body}
}

AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT=${timeout_s}

_deploy_agents_to_runtimes_bounded() {
	local timeout_s="\${AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT:-120}"
	local _start_s=\$SECONDS
	local _pid="" _rc=0

	deploy_agents_to_runtimes &
	_pid=\$!

	while kill -0 "\$_pid" 2>/dev/null; do
		if (( \${SECONDS:-0} - \${_start_s:-0} >= \${timeout_s:-0} )); then
			kill -TERM "\$_pid" 2>/dev/null || true
			sleep 2
			kill -KILL "\$_pid" 2>/dev/null || true
			wait "\$_pid" 2>/dev/null || true
			print_warning "bounded: exceeded timeout"
			return 0
		fi
		sleep 1
	done

	wait "\$_pid" 2>/dev/null
	_rc=\$?
	return "\$_rc"
}

_deploy_agents_to_runtimes_bounded
SCRIPT_EOF
	chmod +x "$out_file"
	return 0
}

test_bounded_wrapper_present() {
	if grep -q '_deploy_agents_to_runtimes_bounded' "$AGENT_RUNTIME_SH"; then
		print_result "_deploy_agents_to_runtimes_bounded is defined in agent-runtime.sh" 0
	else
		print_result "_deploy_agents_to_runtimes_bounded is defined in agent-runtime.sh" 1 \
			"function not found in ${AGENT_RUNTIME_SH}"
	fi
	return 0
}

test_setup_uses_bounded_wrapper() {
	local setup_sh="${REPO_ROOT}/setup.sh"
	if grep -q '_deploy_agents_to_runtimes_bounded' "$setup_sh"; then
		print_result "setup.sh calls _deploy_agents_to_runtimes_bounded" 0
	else
		print_result "setup.sh calls _deploy_agents_to_runtimes_bounded" 1 \
			"setup.sh still calls bare deploy_agents_to_runtimes — bounded wrapper not wired up"
	fi
	return 0
}

test_noninteractive_success_printed_after_postflight() {
	local setup_sh="${REPO_ROOT}/setup.sh"
	local order=""

	order=$(awk '
		/_setup_restart_pulse_if_running$/ { restart=NR }
		/_setup_print_noninteractive_success$/ { success=NR }
		/print_setup_complete_sentinel$/ { sentinel=NR }
		END {
			if (restart && success && sentinel && restart < success && success < sentinel) {
				print "ok"
			}
		}
	' "$setup_sh")

	if [[ "$order" == "ok" ]]; then
		print_result "non-interactive success prints after postflight and before sentinel" 0
	else
		print_result "non-interactive success prints after postflight and before sentinel" 1 \
			"main must restart pulse, drain children, then print Setup complete before [SETUP_COMPLETE]"
	fi
	return 0
}

test_deploy_function_has_no_background_jobs() {
	# deploy_agents_to_runtimes must not start background processes of its own;
	# the bounded wrapper only kills the direct subshell PID, so background jobs
	# inside deploy would otherwise become orphans on timeout.
	#
	# The pattern looks for a standalone '&' (background operator) by requiring
	# it to be preceded by a non-& char and followed by whitespace, semicolon,
	# or end-of-line — excluding '&&', '&>', '>&', and '2>&1' redirects.
	local bg_usages
	bg_usages=$(awk '
		/^deploy_agents_to_runtimes\(\)/{found=1; depth=0}
		found && /\{/{depth++}
		found && /\}/{depth--; if(depth<=0){found=0}}
		found && /[^&][^#]& *($|[;#|)])/{print NR": "$0}
	' "$AGENT_RUNTIME_SH")

	if [[ -z "$bg_usages" ]]; then
		print_result "deploy_agents_to_runtimes contains no background job operators" 0
	else
		print_result "deploy_agents_to_runtimes contains no background job operators" 1 \
			"found background '&' usage in function body — bounded wrapper may not clean up descendants:
${bg_usages}"
	fi
	return 0
}

test_bounded_wrapper_fast_path() {
	local test_tmp_dir
	test_tmp_dir=$(make_test_tmp_dir)
	local script="${test_tmp_dir}/fast.sh"

	_write_bounded_wrapper_script "$script" "  return 0" "5"

	local rc=0
	bash "$script" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "fast deploy_agents_to_runtimes returns 0 through bounded wrapper" 0
	else
		print_result "fast deploy_agents_to_runtimes returns 0 through bounded wrapper" 1 \
			"bounded wrapper returned $rc for a fast no-op stub"
	fi
	return 0
}

test_bounded_wrapper_kills_slow_deployment_without_failing_setup() {
	local test_tmp_dir
	test_tmp_dir=$(make_test_tmp_dir)
	local script="${test_tmp_dir}/slow.sh"

	_write_bounded_wrapper_script "$script" "  sleep 30; return 0" "3"

	local rc=0
	local start_s=$SECONDS
	bash "$script" || rc=$?
	local elapsed=$(( SECONDS - start_s ))

	if [[ "$rc" -eq 0 ]]; then
		print_result "slow deployment timeout is non-critical for setup" 0
	else
		print_result "slow deployment timeout is non-critical for setup" 1 \
			"expected 0 from bounded wrapper timeout, got $rc"
	fi

	# timeout=3 + 2s SIGKILL grace + 1s poll overhead = at most ~7s
	if [[ "$elapsed" -le 10 ]]; then
		print_result "bounded wrapper kills slow deployment within deadline (${elapsed}s)" 0
	else
		print_result "bounded wrapper kills slow deployment within deadline (${elapsed}s)" 1 \
			"took ${elapsed}s — deployment was not killed promptly"
	fi
	return 0
}

test_bounded_wrapper_timeout_env_respected() {
	local test_tmp_dir
	test_tmp_dir=$(make_test_tmp_dir)
	local script="${test_tmp_dir}/env_check.sh"

	# Deploy that sleeps 10s; AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT=2 should terminate it
	# without failing setup's non-interactive path.
	_write_bounded_wrapper_script "$script" "  sleep 10; return 0" "2"

	local rc=0
	local start_s=$SECONDS
	bash "$script" || rc=$?
	local elapsed=$(( SECONDS - start_s ))

	if [[ "$rc" -eq 0 && "$elapsed" -le 7 ]]; then
		print_result "AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT env var respected (${elapsed}s)" 0
	else
		print_result "AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT env var respected (${elapsed}s)" 1 \
			"rc=$rc elapsed=${elapsed}s — timeout env var may not be honoured"
	fi
	return 0
}

test_real_bounded_wrapper_timeout_returns_zero() {
	local test_tmp_dir
	test_tmp_dir=$(make_test_tmp_dir)
	local script="${test_tmp_dir}/real_wrapper_timeout.sh"
	local wrapper_definition=""

	wrapper_definition=$(awk '
		/^_deploy_agents_to_runtimes_bounded\(\)/{found=1; depth=0}
		found {print}
		found && /\{/{depth++}
		found && /\}/{depth--; if(depth<=0){exit}}
	' "$AGENT_RUNTIME_SH")

	if [[ -z "$wrapper_definition" ]]; then
		print_result "real bounded wrapper extraction succeeds" 1 "function not found in ${AGENT_RUNTIME_SH}"
		return 0
	fi

	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -uo pipefail'
		printf '%s\n' 'print_warning() { printf "%s\n" "$*"; return 0; }'
		printf '%s\n' 'deploy_agents_to_runtimes() { sleep 10; return 0; }'
		printf '%s\n' 'AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT=2'
		printf '%s\n' "$wrapper_definition"
		printf '%s\n' '_deploy_agents_to_runtimes_bounded'
	} >"$script"
	chmod +x "$script"

	local output=""
	local rc=0
	output=$(bash "$script" 2>&1) || rc=$?

	if [[ "$rc" -eq 0 && "$output" == *"non-critical"* ]]; then
		print_result "real bounded wrapper timeout returns zero with non-critical warning" 0
	else
		print_result "real bounded wrapper timeout returns zero with non-critical warning" 1 \
			"rc=$rc output=${output}"
	fi
	return 0
}

main() {
	trap cleanup EXIT

	printf 'Running bounded runtime deployment tests...\n\n'

	test_bounded_wrapper_present
	test_setup_uses_bounded_wrapper
	test_noninteractive_success_printed_after_postflight
	test_deploy_function_has_no_background_jobs
	test_bounded_wrapper_fast_path
	test_bounded_wrapper_kills_slow_deployment_without_failing_setup
	test_bounded_wrapper_timeout_env_respected
	test_real_bounded_wrapper_timeout_returns_zero

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
