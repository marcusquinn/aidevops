#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Provider classification, canary, sandbox, and credential-scope tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_LOADED=1

# shellcheck source=./test-headless-runtime-provider-tests-session.sh
# shellcheck disable=SC1091  # resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-headless-runtime-provider-tests-session.sh"
# shellcheck source=./test-headless-runtime-provider-tests-replay.sh
# shellcheck disable=SC1091  # resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-headless-runtime-provider-tests-replay.sh"

test_claude_bare_paths_use_resolved_sandbox_timeout() {
	local timeout_log="${TEST_ROOT}/claude-bare-timeout.log"
	local direct_output="${TEST_ROOT}/claude-bare-direct.out"
	local direct_exit="${TEST_ROOT}/claude-bare-direct.exit"
	local stdin_output="${TEST_ROOT}/claude-bare-stdin.out"
	local stdin_exit="${TEST_ROOT}/claude-bare-stdin.exit"
	local stdin_file="${TEST_ROOT}/claude-bare.stdin"
	local AIDEVOPS_HEADLESS_SANDBOX_DISABLED="1"
	local AIDEVOPS_WORKER_EGRESS_MODE="off"

	timeout() {
		local timeout_seconds="$1"
		shift
		printf '%s\n' "$timeout_seconds" >>"$timeout_log"
		"$@"
		return $?
	}

	_HEADLESS_CLAUDE_STDIN_FILE=""
	_invoke_claude "$direct_output" "$direct_exit" "$TEST_ROOT" bash -c 'printf "direct-output\n"' >/dev/null 2>&1
	printf 'stdin-output\n' >"$stdin_file"
	_HEADLESS_CLAUDE_STDIN_FILE="$stdin_file"
	# shellcheck disable=SC2016 # The nested bash expands $line after reading stdin.
	_invoke_claude "$stdin_output" "$stdin_exit" "$TEST_ROOT" bash -c 'IFS= read -r line; printf "%s\n" "$line"' >/dev/null 2>&1

	local timeout_values=""
	local direct_status=""
	local stdin_status=""
	local direct_value=""
	local stdin_value=""
	timeout_values=$(<"$timeout_log")
	direct_status=$(<"$direct_exit")
	stdin_status=$(<"$stdin_exit")
	# Admission writes a registration notice into the combined output stream.
	# Remove only that notice; retain all command output for exact assertions.
	direct_value=$(sed '/^\[worker-lifecycle\] registered run=[^ ]* pid=[0-9][0-9]*$/d' "$direct_output")
	stdin_value=$(sed '/^\[worker-lifecycle\] registered run=[^ ]* pid=[0-9][0-9]*$/d' "$stdin_output")
	unset -f timeout
	unset _HEADLESS_CLAUDE_STDIN_FILE

	if [[ "$timeout_values" == $'10800\n10800' &&
		"$direct_status" == "0" && "$stdin_status" == "0" &&
		"$direct_value" == "direct-output" && "$stdin_value" == "stdin-output" ]]; then
		print_result "Claude bare execution paths use the resolved headless timeout" 0
		return 0
	fi

	print_result "Claude bare execution paths use the resolved headless timeout" 1 \
		"timeouts=${timeout_values//$'\n'/,} direct_status=$direct_status stdin_status=$stdin_status direct=$direct_value stdin=$stdin_value"
	return 0
}

test_activity_watchdog_classifiers_detect_rate_limit_and_ci_wait() {
	local output_file="${TEST_ROOT}/activity-classifier.out"

	printf 'OpenAI error: HTTP 429 rate limit exceeded\n' >"$output_file"
	if _activity_output_has_provider_rate_limit "$output_file"; then
		print_result "activity watchdog detects provider rate-limit marker" 0
	else
		print_result "activity watchdog detects provider rate-limit marker" 1
	fi

	printf 'waiting for CI checks to finish before merge\n' >"$output_file"
	if _activity_output_has_ci_wait "$output_file"; then
		print_result "activity watchdog detects CI-wait marker" 0
	else
		print_result "activity watchdog detects CI-wait marker" 1
	fi

	return 0
}

test_fast_rate_limit_classifier_requires_trusted_provider_evidence() {
	local output_file="${TEST_ROOT}/fast-rate-limit-classifier.out"
	local failures=0

	printf '%s\n' 'attempt_id=attempt:98810bdf-b2f1-4292-b00b-eed9c88a28fc' >"$output_file"
	_output_has_trusted_fast_provider_failure "$output_file" && failures=$((failures + 1))

	printf '%s\n' 'SQLiteError: disk I/O error after local worker cleanup' >"$output_file"
	_output_has_trusted_fast_provider_failure "$output_file" && failures=$((failures + 1))

	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"Too Many Requests","statusCode":429,"isRetryable":true}}}' >"$output_file"
	_output_has_trusted_fast_provider_failure "$output_file" || failures=$((failures + 1))

	printf '%s\n' 'OpenAI HTTP 503 service unavailable' >"$output_file"
	_output_has_trusted_fast_provider_failure "$output_file" || failures=$((failures + 1))

	if [[ "$failures" -eq 0 ]]; then
		print_result "fast rate-limit classifier requires trusted provider evidence" 0
	else
		print_result "fast rate-limit classifier requires trusted provider evidence" 1 \
			"classification failures=$failures"
	fi
	return 0
}

test_fast_rate_limit_monitor_ignores_uuid_metadata() {
	local output_file="${TEST_ROOT}/fast-rate-limit-uuid.out"
	local exit_code_file="${TEST_ROOT}/fast-rate-limit-uuid.exit"
	local monitor_pid_file="${TEST_ROOT}/fast-rate-limit-uuid.monitor"
	local worker_pid="" monitor_pid="" worker_alive=0

	printf '%s\n' 'attempt_id=attempt:98810bdf-b2f1-4292-b00b-eed9c88a28fc' >"$output_file"
	sleep 20 &
	worker_pid=$!
	_launch_rate_limit_fast_monitor "$output_file" "$worker_pid" "$exit_code_file" 1 >"$monitor_pid_file"
	monitor_pid=$(<"$monitor_pid_file")
	wait "$monitor_pid" 2>/dev/null || true
	kill -0 "$worker_pid" 2>/dev/null && worker_alive=1
	kill -TERM "$worker_pid" 2>/dev/null || true
	wait "$worker_pid" 2>/dev/null || true

	if [[ "$worker_alive" -eq 1 && ! -e "${exit_code_file}.rate_limit_fast" && ! -e "$exit_code_file" ]]; then
		print_result "fast rate-limit monitor ignores 429 inside UUID metadata" 0
	else
		print_result "fast rate-limit monitor ignores 429 inside UUID metadata" 1 \
			"worker_alive=$worker_alive sentinel=$([[ -e "${exit_code_file}.rate_limit_fast" ]] && printf yes || printf no)"
	fi
	return 0
}

test_fast_rate_limit_monitor_stops_attributable_429() {
	local output_file="${TEST_ROOT}/fast-rate-limit-structured.out"
	local exit_code_file="${TEST_ROOT}/fast-rate-limit-structured.exit"
	local monitor_pid_file="${TEST_ROOT}/fast-rate-limit-structured.monitor"
	local worker_pid="" monitor_pid="" exit_value=""

	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"Too Many Requests","statusCode":429,"isRetryable":true}}}' >"$output_file"
	sleep 20 &
	worker_pid=$!
	_launch_rate_limit_fast_monitor "$output_file" "$worker_pid" "$exit_code_file" 1 >"$monitor_pid_file"
	monitor_pid=$(<"$monitor_pid_file")
	wait "$monitor_pid" 2>/dev/null || true
	wait "$worker_pid" 2>/dev/null || true
	[[ -f "$exit_code_file" ]] && exit_value=$(<"$exit_code_file")

	if ! kill -0 "$worker_pid" 2>/dev/null && [[ "$exit_value" == "0" && -f "${exit_code_file}.rate_limit_fast" ]]; then
		print_result "fast rate-limit monitor stops attributable structured 429" 0
	else
		kill -TERM "$worker_pid" 2>/dev/null || true
		wait "$worker_pid" 2>/dev/null || true
		print_result "fast rate-limit monitor stops attributable structured 429" 1 \
			"exit_value=${exit_value:-<empty>} sentinel=$([[ -e "${exit_code_file}.rate_limit_fast" ]] && printf yes || printf no)"
	fi
	return 0
}

test_failure_classifier_records_provenance() {
	local output_file="${TEST_ROOT}/failure-classifier.out"
	local reason_file="${TEST_ROOT}/failure-classifier.reason"
	printf 'Provider returned HTTP 429: Too Many Requests\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "rate_limit" ]] &&
		[[ "${_failure_provider_error_type:-}" == "rate_limit" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]] &&
		[[ "${_failure_classification_pattern:-}" == *"too_many_requests"* ]]; then
		print_result "failure classifier records provider provenance" 0
		return 0
	fi

	print_result "failure classifier records provider provenance" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_failure_classifier_distinguishes_quota_exhaustion() {
	local output_file="${TEST_ROOT}/failure-classifier-quota.out"
	local reason_file="${TEST_ROOT}/failure-classifier-quota.reason"
	printf 'OpenAI provider error HTTP 429: {"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_error_type:-}" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]]; then
		print_result "failure classifier distinguishes OpenAI quota exhaustion" 0
		return 0
	fi

	print_result "failure classifier distinguishes OpenAI quota exhaustion" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_failure_classifier_distinguishes_anthropic_credit_exhaustion() {
	local output_file="${TEST_ROOT}/failure-classifier-anthropic-quota.out"
	local reason_file="${TEST_ROOT}/failure-classifier-anthropic-quota.reason"
	printf 'Anthropic provider error HTTP 429: {"error":{"type":"credit_exhausted","message":"You have exhausted your credit"}}\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_error_type:-}" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]] &&
		[[ "${_failure_classification_pattern:-}" == *"credit_exhausted"* ]]; then
		print_result "failure classifier distinguishes Anthropic credit exhaustion" 0
		return 0
	fi

	print_result "failure classifier distinguishes Anthropic credit exhaustion" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_service_interruption_candidate_uses_separate_path() {
	local output_file="${TEST_ROOT}/service-interruption.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_23037","text":"editing files"}' 'OpenAI 503 service unavailable after tool activity' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 1 "$output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && -f "$output_file" ]]; then
		print_result "service interruption uses dedicated continuation path" 0
	else
		print_result "service interruption uses dedicated continuation path" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	fi

	local local_output_file="${TEST_ROOT}/service-interruption-local.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_local","text":"editing files"}' 'worker received SIGTERM after tool activity' >"$local_output_file"
	_run_result_label=""
	_run_failure_reason=""
	status=0
	_handle_run_result 143 "$local_output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "signal_terminated_continue" && "$_run_runtime_error_type" == "sigterm" && ! -f "$local_output_file" ]]; then
		print_result "SIGTERM uses signal-specific continuation path" 0
	else
		print_result "SIGTERM uses signal-specific continuation path" 1 \
			"status=$status label=${_run_result_label:-<empty>} runtime=${_run_runtime_error_type:-<empty>} output_exists=$([[ -f "$local_output_file" ]] && printf yes || printf no)"
	fi

	if ! service_interruption_continue_candidate "rate_limit" "1" "1" "" "rate_limit"; then
		print_result "rate limits do not consume service interruption budget" 0
	else
		print_result "rate limits do not consume service interruption budget" 1
	fi

	if service_interruption_continue_candidate "auth_error" "1" "1" "" "auth_error"; then
		print_result "auth errors with activity consume service interruption budget" 0
	else
		print_result "auth errors with activity consume service interruption budget" 1
	fi

	if ! service_interruption_continue_candidate "auth_error" "1" "0" "" "auth_error"; then
		print_result "startup auth errors do not consume service interruption budget" 0
	else
		print_result "startup auth errors do not consume service interruption budget" 1
	fi

	local auth_refresh_output_file="${TEST_ROOT}/service-interruption-auth-refresh.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_auth","text":"editing files"}' 'Token refresh failed: 401' >"$auth_refresh_output_file"
	_run_result_label=""
	_run_failure_reason=""
	status=0
	_handle_run_result 1 "$auth_refresh_output_file" "worker" "anthropic" "issue-23037" "anthropic/claude-sonnet-5-5" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && "$_run_failure_reason" == "auth_error" && -f "$auth_refresh_output_file" ]]; then
		print_result "token refresh 401 with session evidence resumes as service interruption" 0
	else
		print_result "token refresh 401 with session evidence resumes as service interruption" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$auth_refresh_output_file" ]] && printf yes || printf no)"
	fi

	if service_interruption_continue_candidate "local_error" "137" "1" "" ""; then
		print_result "SIGKILL with activity can resume as interruption" 0
	else
		print_result "SIGKILL with activity can resume as interruption" 1
	fi

	if ! service_interruption_continue_candidate "local_error" "143" "1" "" ""; then
		print_result "SIGTERM does not consume service interruption budget" 0
	else
		print_result "SIGTERM does not consume service interruption budget" 1
	fi

	local terminated_tail_file="${TEST_ROOT}/terminated-tail.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_tail","text":"editing files"}' 'terminated' >"$terminated_tail_file"
	if runtime_signal_terminated_candidate "$terminated_tail_file" "1" "1"; then
		print_result "terminated tail classifies as signal termination" 0
	else
		print_result "terminated tail classifies as signal termination" 1
	fi

	return 0
}

test_service_interruption_exhausted_metric_preserves_context() {
	local captured_file="${TEST_ROOT}/service-interruption-exhausted.args"
	append_runtime_metric() {
		printf '%s\n' "$@" >"$captured_file"
		return 0
	}
	local WORKER_ISSUE_NUMBER="24099"
	local DISPATCH_REPO_SLUG="owner/repo"
	local _run_provider_error_type=""
	local _run_provider_status=""
	local _run_runtime_error_type=""
	local _run_classification_source="default_local"
	local _run_classification_pattern="default_local"
	local _metric_kill_reason="unknown"

	_append_service_interruption_exhausted_metric \
		"worker" "issue-24099" "openai/gpt-5.5" \
		"${TEST_ROOT}/worktree" "local_error" \
		"${TEST_ROOT}/excerpt.log" "ses_context"

	local captured
	captured=$(<"$captured_file")
	if [[ "$captured" == *$'service_interruption_exhausted\n81\nlocal_error\n1\n0\n24099\nowner/repo\n'* ]] &&
		[[ "$captured" == *$'excerpt.log\nses_context\n'* ]] &&
		[[ "$captured" == *$'mid_session_interruption\nunknown\nresume_existing_session'* ]]; then
		print_result "service interruption exhausted metric preserves diagnostics context" 0
	else
		print_result "service interruption exhausted metric preserves diagnostics context" 1 "$captured"
	fi
	unset -f append_runtime_metric 2>/dev/null || true
	return 0
}

test_canary_pins_vanilla_agent_with_isolated_plugin_config() {
	local canary_root="${TEST_ROOT}/canary-agent"
	local fake_bin_dir="${canary_root}/bin"
	local plugin_dir="${canary_root}/plugin path"
	local plugin_path="${plugin_dir}/index.mjs"
	local args_file="${canary_root}/args.txt"
	local env_file="${canary_root}/env.txt"
	mkdir -p "$fake_bin_dir" "$plugin_dir"
	printf '%s\n' 'export default {};' >"$plugin_path"

	cat >"${fake_bin_dir}/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	printf '1.14.31\n'
	exit 0
fi
if [[ -n "${AIDEVOPS_OPENCODE_SESSION_ID:-}${OPENCODE_SESSION_ID:-}${OPENCODE_PID:-}${OPENCODE_RUN_ID:-}${OPENCODE_PROCESS_ROLE:-}${OPENCODE:-}${OPENCODE_SERVER_PASSWORD:-}" ]]; then
	printf 'leaked session env\n' >"$AIDEVOPS_CANARY_ENV_FILE"
	exit 42
fi
printf '%s\n' "$*" >"$AIDEVOPS_CANARY_ARGS_FILE"
printf 'OPENCODE_BIN=%s\nOPENCODE_DB=%s\nAIDEVOPS_HEADLESS=%s\n' \
	"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}" "${AIDEVOPS_HEADLESS:-}" >"$AIDEVOPS_CANARY_ENV_FILE"
if [[ -f "${XDG_CONFIG_HOME:-}/opencode/opencode.json" ]]; then
	printf 'CONFIG=%s\n' "$(<"${XDG_CONFIG_HOME}/opencode/opencode.json")" >>"$AIDEVOPS_CANARY_ENV_FILE"
fi
printf 'The answer is Four.\n'
exit 0
EOF
	chmod +x "${fake_bin_dir}/opencode"

	local output
	if output=$(
		PATH="${fake_bin_dir}:$PATH" \
			HOME="${canary_root}/home" \
			OPENCODE_BIN="${fake_bin_dir}/opencode" \
			OPENCODE_DB="${canary_root}/opencode.db" \
			AIDEVOPS_OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_PID="12345" \
			OPENCODE_RUN_ID="run_parent" \
			OPENCODE_PROCESS_ROLE="tui" \
			OPENCODE="1" \
			OPENCODE_SERVER_PASSWORD="session-password" \
			AIDEVOPS_PLUGIN_INDEX="$plugin_path" \
			AIDEVOPS_CANARY_ARGS_FILE="$args_file" \
			AIDEVOPS_CANARY_ENV_FILE="$env_file" \
			AIDEVOPS_HEADLESS_RUNTIME_DIR="${canary_root}/runtime" \
			CANARY_CACHE_TTL_SECONDS=0 \
			CANARY_TIMEOUT_SECONDS=5 \
			bash -c 'source "$1" help >/dev/null 2>&1; _run_canary_test "anthropic/claude-sonnet-5-5"' _ "$HELPER_SCRIPT"
	) && [[ -f "$args_file" && -f "$env_file" ]]; then
		local args
		args=$(<"$args_file")
		local env_output
		env_output=$(<"$env_file")
		local expected_plugin_url
		expected_plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$plugin_path")
		if [[ "$args" == *'What is two plus two?'* && "$args" != *'--pure'* && "$args" == *'--agent build'* ]] &&
			[[ "$env_output" == *"OPENCODE_BIN=${fake_bin_dir}/opencode"* ]] &&
			[[ "$env_output" == *"OPENCODE_DB=${canary_root}/opencode.db"* ]] &&
			[[ "$env_output" == *"AIDEVOPS_HEADLESS=1"* ]] &&
			[[ "$env_output" == *"$expected_plugin_url"* ]]; then
			print_result "canary pins vanilla agent with isolated plugin config" 0
			return 0
		fi
		print_result "canary pins vanilla agent with isolated plugin config" 1 \
			"Expected benign prompt, no --pure, but with --agent build, headless env, plugin config, and preserved OpenCode config env; got args: ${args}; env: ${env_output}"
		return 0
	fi

	print_result "canary pins vanilla agent with isolated plugin config" 1 \
		"Canary stub did not run successfully: ${output:-<empty>}"
	return 0
}

test_opencode_session_env_wrapper_strips_session_vars_only() {
	local output
	# shellcheck disable=SC2016 # Inner bash expands these after env stripping.
	output=$(
		AIDEVOPS_OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_PID="12345" \
			OPENCODE_RUN_ID="run_parent" \
			OPENCODE_PROCESS_ROLE="tui" \
			OPENCODE="1" \
			OPENCODE_SERVER_PASSWORD="session-password" \
			OPENCODE_BIN="opencode" \
			OPENCODE_DB="/tmp/opencode.db" \
			run_without_opencode_session_env bash -c '
			printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" \
				"${AIDEVOPS_OPENCODE_SESSION_ID:-}" "${OPENCODE_SESSION_ID:-}" "${OPENCODE_PID:-}" "${OPENCODE_RUN_ID:-}" \
				"${OPENCODE_PROCESS_ROLE:-}" "${OPENCODE:-}" "${OPENCODE_SERVER_PASSWORD:-}" \
				"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}"
		'
	)

	if [[ "$output" == "|||||||opencode|/tmp/opencode.db" ]]; then
		print_result "OpenCode session env wrapper strips only session-bound vars" 0
		return 0
	fi

	print_result "OpenCode session env wrapper strips only session-bound vars" 1 \
		"Expected session vars stripped and config env preserved, got: ${output}"
	return 0
}

test_ambient_server_attachment_respects_isolation() {
	if (
		_detect_opencode_server() {
			printf '%s\n' 'http://localhost:4096' 'fixture-password'
			return 0
		}
		local role="worker" AIDEVOPS_OPENCODE_PROFILE="v1" args=""
		local AIDEVOPS_HEADLESS_AUTH_ISOLATION=""
		args=$(_build_run_cmd "provider/model" "$TEST_ROOT" "prompt" "title" "" "" "" | tr '\0' '\n')
		[[ "$args" != *--attach* ]] || exit 1
		AIDEVOPS_HEADLESS_AUTH_ISOLATION=0
		args=$(_build_run_cmd "provider/model" "$TEST_ROOT" "prompt" "title" "" "" "" | tr '\0' '\n')
		[[ "$args" == *$'--attach\nhttp://localhost:4096\n--password\nfixture-password'* ]] || exit 1
		role="triage"
		args=$(_build_run_cmd "provider/model" "$TEST_ROOT" "prompt" "title" "" "" "" | tr '\0' '\n')
		[[ "$args" != *--attach* ]] || exit 1
		role="worker" AIDEVOPS_OPENCODE_PROFILE="v2"
		args=$(_build_run_cmd "provider/model" "$TEST_ROOT" "prompt" "title" "" "" "" | tr '\0' '\n')
		[[ "$args" != *--attach* && "$args" == *--standalone* ]] || exit 1
	); then
		print_result "ambient attachment respects isolation, ephemeral roles, and v2" 0
	else
		print_result "ambient attachment respects isolation, ephemeral roles, and v2" 1
	fi
	return 0
}

test_worker_opencode_exec_paths_strip_session_env() {
	test_ambient_server_attachment_respects_isolation
	local invoke_helper="${SCRIPT_DIR}/headless-runtime-invoke.sh"
	# shellcheck disable=SC2016 # Match literal caller-scoped variables in source.
	if grep -Fq 'run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" "${sandbox_args[@]}"' "$invoke_helper" &&
		grep -Fq 'run_without_opencode_session_env timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' "$invoke_helper"; then
		print_result "worker OpenCode exec paths strip session env" 0
		return 0
	fi

	print_result "worker OpenCode exec paths strip session env" 1 \
		"Expected sandbox and bare-timeout OpenCode exec paths to use run_without_opencode_session_env"
	return 0
}

test_worker_opencode_invocation_seeds_continuation_session() {
	local invoke_helper="${SCRIPT_DIR}/headless-runtime-invoke.sh"
	# shellcheck disable=SC2016 # Match literal continuation variables in source.
	if grep -Fq '_seed_worker_db_session_context "$isolated_data_dir" "$_invoke_persisted_session"' "$invoke_helper" &&
		grep -Fq '[lifecycle] db_seeded session=$_invoke_persisted_session' "$invoke_helper"; then
		print_result "worker OpenCode invocation seeds persisted continuation session" 0
		return 0
	fi

	print_result "worker OpenCode invocation seeds persisted continuation session" 1 \
		"Expected persisted session seeding before opencode continuation launch"
	return 0
}

test_sandbox_passthrough_scopes_provider_env() {
	local csv
	csv=$(
		OPENAI_API_KEY='openai-test' \
			ANTHROPIC_API_KEY='anthropic-test' \
			GOOGLE_API_KEY='google-test' \
			OPENCODE_BIN='opencode' \
			OPENCODE_DB='/tmp/opencode.db' \
			AIDEVOPS_OPENCODE_SESSION_ID='ses_parent' \
			OPENCODE_SESSION_ID='ses_parent' \
			OPENCODE_PID='12345' \
			OPENCODE_RUN_ID='run_parent' \
			OPENCODE_PROCESS_ROLE='tui' \
			OPENCODE='1' \
			OPENCODE_SERVER_PASSWORD='session-password' \
			build_sandbox_passthrough_csv "openai"
	)

	if [[ ",$csv," == *",OPENAI_API_KEY,"* ]] &&
		[[ ",$csv," != *",ANTHROPIC_API_KEY,"* ]] &&
		[[ ",$csv," != *",GOOGLE_API_KEY,"* ]] &&
		[[ ",$csv," == *",OPENCODE_BIN,"* ]] &&
		[[ ",$csv," == *",OPENCODE_DB,"* ]] &&
		[[ ",$csv," != *",AIDEVOPS_OPENCODE_SESSION_ID,"* ]] &&
		[[ ",$csv," != *",OPENCODE_SESSION_ID,"* ]] &&
		[[ ",$csv," != *",OPENCODE_PID,"* ]] &&
		[[ ",$csv," != *",OPENCODE_RUN_ID,"* ]] &&
		[[ ",$csv," != *",OPENCODE_PROCESS_ROLE,"* ]] &&
		[[ ",$csv," != *",OPENCODE_SERVER_PASSWORD,"* ]] &&
		[[ ",$csv," != *",OPENCODE,"* ]]; then
		print_result "sandbox passthrough scopes env to selected provider" 0
		return 0
	fi

	print_result "sandbox passthrough scopes env to selected provider" 1 \
		"Expected OpenAI env only, got: ${csv}"
	return 0
}

test_sandbox_passthrough_rejects_unvalidated_git_config() {
	local csv=""
	csv=$(
		GIT_CONFIG_COUNT=1 \
			GIT_CONFIG_KEY_0='http.extraHeader' \
			GIT_CONFIG_VALUE_0='unrelated' \
			build_sandbox_passthrough_csv "openai" "worker"
	)
	if [[ ",$csv," != *",GIT_CONFIG_COUNT,"* && ",$csv," != *",GIT_CONFIG_KEY_0,"* &&
		",$csv," != *",GIT_CONFIG_VALUE_0,"* ]]; then
		print_result "sandbox passthrough rejects unvalidated ambient Git configuration" 0
		return 0
	fi
	print_result "sandbox passthrough rejects unvalidated ambient Git configuration" 1 "$csv"
	return 0
}

test_sandbox_passthrough_accepts_validated_git_auth_contract() {
	local csv=""
	csv=$(
		export _AIDEVOPS_HEADLESS_GIT_AUTH_ENV_CONFIGURED=1
		export AIDEVOPS_GIT_AUTH_TOKEN_FILE='/tmp/worker-fixture.token'
		export AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN='https://github.com/owner/repo'
		export GIT_ASKPASS="${SCRIPT_DIR}/github-auth-askpass.sh"
		export GIT_TERMINAL_PROMPT=0
		export GIT_AUTHOR_NAME='fixture-app[bot]'
		export GIT_AUTHOR_EMAIL='fixture-app[bot]@users.noreply.github.com'
		export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
		export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
		build_sandbox_passthrough_csv "openai" "worker"
	)
	if [[ ",$csv," == *",AIDEVOPS_GIT_AUTH_TOKEN_FILE,"* &&
		",$csv," == *",AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN,"* &&
		",$csv," == *",GIT_ASKPASS,"* && ",$csv," == *",GIT_TERMINAL_PROMPT,"* &&
		",$csv," == *",GIT_AUTHOR_NAME,"* && ",$csv," == *",GIT_COMMITTER_EMAIL,"* ]]; then
		print_result "sandbox passthrough accepts only normalized worker Git auth" 0
		return 0
	fi
	print_result "sandbox passthrough accepts only normalized worker Git auth" 1 "$csv"
	return 0
}

test_triage_sandbox_passthrough_excludes_github_and_worker_authority() {
	local csv=""
	csv=$(
		OPENAI_API_KEY='openai-test' \
			OPENAI_ADMIN_KEY='openai-admin-test' \
			OPENAI_BASE_URL='https://openai-endpoint.example.invalid' \
			ANTHROPIC_API_KEY='anthropic-test' \
			CLAUDE_CODE_OAUTH_TOKEN='anthropic-oauth-test' \
			GOOGLE_OAUTH_ACCESS_TOKEN='google-oauth-test' \
			GH_TOKEN='github-test' \
			GITHUB_TOKEN='github-test' \
			WORKER_ISSUE_NUMBER='28705' \
			AIDEVOPS_PERMISSION_GRANT_FILE='/tmp/grant.json' \
			AIDEVOPS_HEADLESS='1' \
			AIDEVOPS_HEADLESS_AUTH_ISOLATION='1' \
			AIDEVOPS_SESSION_ORIGIN='triage' \
			XDG_CACHE_HOME='/tmp/triage-cache' \
			XDG_CONFIG_HOME='/tmp/triage-config' \
			XDG_DATA_HOME='/tmp/triage-data' \
			XDG_STATE_HOME='/tmp/triage-state' \
			OPENCODE_PURE=1 \
			OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
			OPENCODE_DISABLE_EXTERNAL_SKILLS=1 \
			OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
			OTEL_EXPORTER_OTLP_ENDPOINT='https://telemetry.example.invalid' \
			build_sandbox_passthrough_csv "openai" "triage" 1
	)
	local env_auth_csv=""
	env_auth_csv=$(OPENAI_API_KEY='openai-test' build_sandbox_passthrough_csv "openai" "triage" 0)

	if [[ ",$csv," != *",OPENAI_API_KEY,"* && ",$env_auth_csv," == *",OPENAI_API_KEY,"* &&
		",$csv," != *",OPENAI_ADMIN_KEY,"* &&
		",$csv," != *",OPENAI_BASE_URL,"* && ",$csv," != *",ANTHROPIC_API_KEY,"* &&
		",$csv," != *",CLAUDE_CODE_OAUTH_TOKEN,"* &&
		",$csv," != *",GOOGLE_OAUTH_ACCESS_TOKEN,"* &&
		",$csv," != *",GH_TOKEN,"* && ",$csv," != *",GITHUB_TOKEN,"* &&
		",$csv," != *",WORKER_ISSUE_NUMBER,"* && ",$csv," != *",AIDEVOPS_PERMISSION_GRANT_FILE,"* &&
		",$csv," != *",OTEL_EXPORTER_OTLP_ENDPOINT,"* && ",$csv," == *",AIDEVOPS_HEADLESS,"* &&
		",$csv," == *",AIDEVOPS_SESSION_ORIGIN,"* &&
		",$csv," == *",XDG_DATA_HOME,"* && ",$csv," == *",OPENCODE_PURE,"* &&
		",$csv," != *",OPENCODE_DISABLE_DEFAULT_PLUGINS,"* &&
		",$csv," == *",OPENCODE_DISABLE_EXTERNAL_SKILLS,"* &&
		",$csv," == *",OPENCODE_DISABLE_CLAUDE_CODE_SKILLS,"* ]]; then
		print_result "triage sandbox passthrough excludes GitHub and worker authority" 0
		return 0
	fi

	print_result "triage sandbox passthrough excludes GitHub and worker authority" 1 \
		"Unexpected triage passthrough names: ${csv}"
	return 0
}

test_strict_scoped_auth_rejects_malformed_source() {
	local auth_root="${TEST_ROOT}/strict-scoped-auth"
	local source_auth="${auth_root}/source.json"
	local dest_auth="${auth_root}/dest/opencode/auth.json"
	mkdir -p "$auth_root"
	printf '%s\n' '{malformed' >"$source_auth"
	local status=0
	copy_scoped_opencode_auth "$source_auth" "$dest_auth" "openai" true || status=$?
	if [[ "$status" -ne 0 && ! -e "$dest_auth" ]]; then
		print_result "strict scoped auth fails closed on malformed source" 0
		return 0
	fi

	print_result "strict scoped auth fails closed on malformed source" 1 \
		"status=${status} destination_exists=$([[ -e "$dest_auth" ]] && printf yes || printf no)"
	return 0
}

test_triage_runtime_directory_is_framework_owned_and_empty() {
	local runtime_dir=""
	local managed_root="${TEST_ROOT}/managed-triage-runtime"
	local triage_agent=""
	if ! AIDEVOPS_SENSITIVE_TEMP_DIR="$managed_root" \
		_prepare_triage_runtime_directory "runtime_dir"; then
		print_result "triage runtime directory is isolated from target repository" 1 \
			"runtime directory preparation failed"
		return 0
	fi
	managed_root=$(cd "$managed_root" && pwd -P) || return 1

	local runtime_config="${runtime_dir}/.opencode/opencode.json"
	triage_agent="${runtime_dir}/.opencode/agent/triage-review.md"
	if [[ "$runtime_dir" == "$managed_root"/aidevops-headless-triage.* &&
		-f "$triage_agent" &&
		-f "$runtime_config" && ! -e "${runtime_dir}/.git" &&
		$(jq -r '(.default_agent == "triage-review") and (.permission["*"] == "deny") and (.tools["*"] == false) and (.mcp == {}) and (.formatter == false) and (.lsp == false) and (.share == "disabled") and (.subagent_depth == 0)' "$runtime_config") == true ]] &&
		grep -q '^mode: primary$' "$triage_agent" &&
		grep -q '^  "\*": deny$' "$triage_agent"; then
		print_result "triage runtime directory is isolated from target repository" 0
	else
		print_result "triage runtime directory is isolated from target repository" 1 \
			"Unexpected runtime directory: ${runtime_dir:-<empty>}"
	fi
	rm -rf "$runtime_dir" 2>/dev/null || true
	_HEADLESS_RUNTIME_TEMP_PATHS=""
	return 0
}

test_ai_research_runtime_directory_stages_inference_only_agent() {
	local runtime_dir=""
	local managed_root="${TEST_ROOT}/managed-ai-research-runtime"
	local agent_name="research-only"
	local research_agent=""
	if ! AIDEVOPS_SESSION_ORIGIN="ai-research" \
		AIDEVOPS_AI_RESEARCH_TOOL_CEILING=1 \
		AIDEVOPS_SENSITIVE_TEMP_DIR="$managed_root" \
		_prepare_triage_runtime_directory "runtime_dir"; then
		print_result "ai-research runtime stages the inference-only agent" 1 \
			"runtime directory preparation failed"
		return 0
	fi
	managed_root=$(cd "$managed_root" && pwd -P) || return 1

	local runtime_config="${runtime_dir}/.opencode/opencode.json"
	research_agent="${runtime_dir}/.opencode/agent/research-only.md"
	if [[ "$runtime_dir" == "$managed_root"/aidevops-headless-triage.* &&
		-f "$research_agent" && ! -e "${runtime_dir}/.opencode/agent/triage-review.md" &&
		-f "$runtime_config" && ! -e "${runtime_dir}/.git" &&
		$(jq -r '(.default_agent == "research-only") and (.agent["research-only"].mode == "primary") and (.agent["research-only"].permission["*"] == "deny") and (.agent["research-only"].tools["*"] == false) and (.permission["*"] == "deny") and (.tools["*"] == false) and (.mcp == {}) and (.formatter == false) and (.lsp == false) and (.share == "disabled") and (.subagent_depth == 0)' "$runtime_config") == true ]] &&
		grep -q '^mode: primary$' "$research_agent" &&
		grep -q '^# Sandboxed Focused Research Agent$' "$research_agent"; then
		print_result "ai-research runtime stages the inference-only agent" 0
	else
		print_result "ai-research runtime stages the inference-only agent" 1 \
			"Unexpected runtime directory: ${runtime_dir:-<empty>}"
	fi
	rm -rf "$runtime_dir" 2>/dev/null || true
	_HEADLESS_RUNTIME_TEMP_PATHS=""
	return 0
}

test_private_sandbox_passthrough_excludes_parent_credentials() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local csv=""
	csv=$(
		OPENAI_API_KEY='openai-test' \
			GH_TOKEN='github-test' \
			OPENCODE_CONFIG='/tmp/untrusted-opencode.json' \
			OPENCODE_BIN='opencode' \
			XDG_CACHE_HOME='/tmp/private-cache' \
			XDG_CONFIG_HOME='/tmp/private-config' \
			XDG_DATA_HOME='/tmp/private-data' \
			XDG_STATE_HOME='/tmp/private-state' \
			build_sandbox_passthrough_csv "openai"
	)
	local item_count=0
	item_count=$(printf '%s\n' "$csv" | tr ',' '\n' | wc -l | tr -d ' ')

	if [[ "$item_count" -eq 4 && ",${csv}," == *",XDG_CACHE_HOME,"* &&
		",${csv}," == *",XDG_CONFIG_HOME,"* && ",${csv}," == *",XDG_DATA_HOME,"* &&
		",${csv}," == *",XDG_STATE_HOME,"* ]]; then
		print_result "private sandbox passthrough excludes parent credentials and config overrides" 0
		return 0
	fi

	print_result "private sandbox passthrough excludes parent credentials and config overrides" 1 \
		"Expected isolated XDG paths only, got: ${csv}"
	return 0
}

test_copy_scoped_opencode_auth_keeps_selected_provider_only() {
	local auth_root="${TEST_ROOT}/scoped-auth"
	local source_auth="${auth_root}/source.json"
	local dest_auth="${auth_root}/dest/opencode/auth.json"
	mkdir -p "$auth_root"
	cat >"$source_auth" <<'EOF'
{
  "openai": {"type": "oauth", "access": "openai-token"},
  "anthropic": {"type": "oauth", "access": "anthropic-token"}
}
EOF

	copy_scoped_opencode_auth "$source_auth" "$dest_auth" "openai"

	local has_openai has_anthropic
	has_openai=$(jq -r 'has("openai")' "$dest_auth")
	has_anthropic=$(jq -r 'has("anthropic")' "$dest_auth")
	if [[ "$has_openai" == "true" && "$has_anthropic" == "false" ]]; then
		print_result "copy_scoped_opencode_auth keeps selected provider only" 0
		return 0
	fi

	print_result "copy_scoped_opencode_auth keeps selected provider only" 1 \
		"Expected only openai auth entry in ${dest_auth}"
	return 0
}
