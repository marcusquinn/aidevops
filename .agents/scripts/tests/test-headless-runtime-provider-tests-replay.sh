#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Escalation, sandbox timeout and model-replay tests.

# Sourced by test-headless-runtime-provider-tests.sh; not run directly.
[[ -n "${_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_REPLAY_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_REPLAY_LOADED=1

test_capability_escalation_ladder_is_bounded_and_exact() {
	local result=0
	local route_output=""
	local route_output_file="${TEST_ROOT}/capability-escalation-route-output.txt"
	local _capability_escalation_tier=""
	local _capability_escalation_model=""
	local _capability_escalation_variant=""
	local _capability_escalation_label=""
	(
		model_tier_next() {
			local current_tier="$1"
			case "$current_tier" in
			simple) printf '%s\n' "standard" ;;
			standard) printf '%s\n' "thinking" ;;
			*) return 1 ;;
			esac
			return 0
		}
		choose_model() {
			local role_name="$1"
			local explicit_model="$2"
			local tier_name="$3"
			: "$role_name" "$explicit_model"
			case "$tier_name" in
			standard) printf '%s\n' "openai/gpt-5.6-terra" ;;
			thinking) printf '%s\n' "openai/gpt-5.6-sol" ;;
			*) return 1 ;;
			esac
			return 0
		}
		resolve_headless_variant() {
			local role_name="$1"
			local tier_name="$2"
			local model_name="$3"
			: "$role_name" "$model_name"
			case "$tier_name" in
			standard) printf '%s\n' "high" ;;
			thinking) printf '%s\n' "medium" ;;
			*) return 1 ;;
			esac
			return 0
		}
		_resolve_capability_escalation "worker" "simple" || exit 1
		printf '%s|%s|%s\n' "$_capability_escalation_tier" "$_capability_escalation_model" "$_capability_escalation_variant"
		_resolve_capability_escalation "worker" "standard" || exit 1
		printf '%s|%s|%s\n' "$_capability_escalation_tier" "$_capability_escalation_model" "$_capability_escalation_variant"
		if _resolve_capability_escalation "worker" "thinking" ||
			_resolve_capability_escalation "pulse" "simple"; then
			exit 1
		fi
	) >"$route_output_file" || result=1
	[[ -f "$route_output_file" ]] && route_output=$(<"$route_output_file")
	local expected_output=$'standard|openai/gpt-5.6-terra|high\nthinking|openai/gpt-5.6-sol|medium'
	[[ "$route_output" == "$expected_output" ]] || result=1
	print_result "Capability escalation follows the bounded configured tier order" "$result"
	return 0
}

test_post_pr_handoff_completion_signal_is_exact() {
	local exact_file="${TEST_ROOT}/post-pr-handoff-exact.jsonl"
	local prose_file="${TEST_ROOT}/post-pr-handoff-prose.jsonl"
	printf '%s\n' '{"type":"text","text":"POST_PR_HANDOFF"}' >"$exact_file"
	printf '%s\n' '{"type":"text","text":"I will mention POST_PR_HANDOFF after more work."}' >"$prose_file"
	# Argv-style tool input (aidevops_bounded_operation) must not crash the
	# classifier and turn a completed handoff into a premature-exit retry loop.
	local argv_file="${TEST_ROOT}/post-pr-handoff-argv-tool.jsonl"
	printf '%s\n' \
		'{"type":"tool_use","part":{"state":{"input":{"action":"start","command":["gh","pr","checks","42"]}}}}' \
		'{"type":"text","part":{"text":"Awaiting required CI.\n\nPOST_PR_HANDOFF"}}' >"$argv_file"

	local result=0
	output_has_post_pr_handoff_signal "$exact_file" || result=1
	output_has_completion_signal "$exact_file" || result=1
	output_has_completion_signal "$argv_file" || result=1
	if output_has_post_pr_handoff_signal "$prose_file" || output_has_completion_signal "$prose_file"; then
		result=1
	fi
	print_result "POST_PR_HANDOFF is accepted only as an exact model-text line" "$result"
	return 0
}

test_private_task_complete_requires_exact_model_text_line() {
	local summary_file="${TEST_ROOT}/task-complete-summary.jsonl"
	local prose_file="${TEST_ROOT}/task-complete-prose.jsonl"
	local tool_file="${TEST_ROOT}/task-complete-tool.jsonl"
	printf '%s\n' '{"type":"text","part":{"text":"Applied the requested fix.\n\nTASK_COMPLETE"}}' >"$summary_file"
	printf '%s\n' '{"type":"text","part":{"text":"I will emit TASK_COMPLETE after more work."}}' >"$prose_file"
	printf '%s\n' '{"type":"tool_use","part":{"state":{"output":"TASK_COMPLETE"}}}' >"$tool_file"

	local result=0
	_private_output_has_task_complete "$summary_file" || result=1
	if _private_output_has_task_complete "$prose_file" ||
		_private_output_has_task_complete "$tool_file"; then
		result=1
	fi
	print_result "private completion accepts only an exact model-authored TASK_COMPLETE line" "$result"
	return 0
}

test_post_pr_handoff_records_distinct_result_label() {
	local output_file="${TEST_ROOT}/post-pr-handoff-result.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_handoff","text":"POST_PR_HANDOFF"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	if [[ "$rc" -eq 0 && "${_run_result_label:-}" == "post_pr_handoff" ]]; then
		print_result "POST_PR_HANDOFF remains distinct from raw process success" 0
		return 0
	fi
	print_result "POST_PR_HANDOFF remains distinct from raw process success" 1 \
		"rc=${rc} label=${_run_result_label:-<unset>}"
	return 0
}

test_missing_context_blocked_requests_brief_recovery() {
	local output_file="${TEST_ROOT}/missing-context-blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing implementation context"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 82 && "${_run_result_label:-}" == "brief_recovery" && "${_run_failure_reason:-}" == "missing_implementation_context" && "${_run_classification_pattern:-}" == "missing_implementation_context" ]] && {
		print_result "missing-context BLOCKED requests brief recovery" 0
		return 0
	}
	print_result "missing-context BLOCKED requests brief recovery" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

test_headless_activity_timeout_default_matches_watchdog() {
	local expected="600"
	local actual="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-}"

	if [[ "$actual" == "$expected" ]]; then
		print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 0
		return 0
	fi

	print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 1 \
		"Expected ${expected}s to avoid GPT-5.x no-output false kills; got '${actual:-<unset>}'"
	return 0
}

test_headless_sandbox_timeout_budget() {
	local explicit_timeout=""
	local capped_timeout=""
	local invalid_timeout=""
	explicit_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=14400 \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)
	capped_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=86400 \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)
	invalid_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=invalid \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)

	if [[ "$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT" == "10800" &&
		"$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" == "10800" &&
		"$HEADLESS_SANDBOX_TIMEOUT_MAX" == "21600" &&
		"$explicit_timeout" == "14400" &&
		"$capped_timeout" == "21600" &&
		"$invalid_timeout" == "10800" ]]; then
		print_result "headless sandbox timeout exceeds checkpoint budget and remains bounded" 0
		return 0
	fi

	print_result "headless sandbox timeout exceeds checkpoint budget and remains bounded" 1 \
		"base=$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT resolved=$HEADLESS_SANDBOX_TIMEOUT_DEFAULT max=$HEADLESS_SANDBOX_TIMEOUT_MAX explicit=$explicit_timeout capped=$capped_timeout invalid=$invalid_timeout"
	return 0
}

test_public_triage_egress_mode_is_capability_aware() {
	local absent_mode=""
	local configured_mode=""
	local required_mode=""
	local off_mode=""
	local invalid_status=0

	absent_mode=$(_resolve_public_triage_egress_mode "auto" "")
	configured_mode=$(_resolve_public_triage_egress_mode "auto" "/configured/backend")
	required_mode=$(_resolve_public_triage_egress_mode "required" "")
	off_mode=$(_resolve_public_triage_egress_mode "off" "")
	_resolve_public_triage_egress_mode "invalid" "" >/dev/null 2>&1 || invalid_status=$?

	if [[ "$absent_mode" == "auto" && "$configured_mode" == "required" &&
		"$required_mode" == "required" && "$off_mode" == "auto" &&
		"$invalid_status" -ne 0 ]]; then
		print_result "public triage egress is capability-aware and cannot be disabled" 0
		return 0
	fi

	print_result "public triage egress is capability-aware and cannot be disabled" 1 \
		"absent=$absent_mode configured=$configured_mode required=$required_mode off=$off_mode invalid=$invalid_status"
	return 0
}

test_public_triage_always_requires_isolated_sandbox() {
	local failures=0

	_headless_opencode_sandbox_required "triage" "0" "auto" || failures=$((failures + 1))
	_headless_opencode_sandbox_required "model-replay" "0" "auto" || failures=$((failures + 1))
	_headless_opencode_sandbox_required "worker" "0" "required" || failures=$((failures + 1))
	_headless_opencode_sandbox_required "worker" "1" "auto" || failures=$((failures + 1))
	if _headless_opencode_sandbox_required "worker" "0" "auto"; then
		failures=$((failures + 1))
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "public triage and model replay retain the mandatory isolated sandbox" 0
		return 0
	fi

	print_result "public triage and model replay retain the mandatory isolated sandbox" 1 \
		"sandbox policy mismatches=${failures}"
	return 0
}

test_model_replay_sandbox_passthrough_is_bounded() {
	local csv=""
	csv=$(
		OPENAI_API_KEY='openai-test' \
			GH_TOKEN='github-test' \
			WORKER_ISSUE_NUMBER='30560' \
			AIDEVOPS_HEADLESS_METRICS_FILE='/tmp/headless-metrics.jsonl' \
			AIDEVOPS_RESOURCE_METRICS_FILE='/tmp/resource-metrics.jsonl' \
			AIDEVOPS_TEMP_DIR='/tmp/model-replay' \
			AIDEVOPS_WORKTREE_BASE_DIR='/tmp/model-replay/worktrees' \
			OPENCODE_CONFIG='/tmp/model-replay/opencode.json' \
			OPENCODE_CONFIG_DIR='/tmp/model-replay/config' \
			OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
			OPENCODE_DISABLE_PROJECT_CONFIG=1 \
			XDG_DATA_HOME='/tmp/model-replay/data' \
			OTEL_EXPORTER_OTLP_ENDPOINT='https://telemetry.example.invalid' \
			build_sandbox_passthrough_csv "openai" "model-replay" 1
	)

	if [[ ",$csv," != *",OPENAI_API_KEY,"* && ",$csv," != *",GH_TOKEN,"* &&
		",$csv," != *",WORKER_ISSUE_NUMBER,"* &&
		",$csv," != *",AIDEVOPS_HEADLESS_METRICS_FILE,"* &&
		",$csv," != *",AIDEVOPS_RESOURCE_METRICS_FILE,"* &&
		",$csv," != *",OTEL_EXPORTER_OTLP_ENDPOINT,"* &&
		",$csv," != *",AIDEVOPS_TEMP_DIR,"* &&
		",$csv," != *",AIDEVOPS_WORKTREE_BASE_DIR,"* &&
		",$csv," == *",OPENCODE_CONFIG,"* &&
		",$csv," == *",OPENCODE_CONFIG_DIR,"* &&
		",$csv," != *",OPENCODE_DISABLE_DEFAULT_PLUGINS,"* &&
		",$csv," == *",OPENCODE_DISABLE_PROJECT_CONFIG,"* &&
		",$csv," == *",XDG_DATA_HOME,"* ]]; then
		print_result "model replay sandbox receives only bounded runtime configuration" 0
		return 0
	fi

	print_result "model replay sandbox receives only bounded runtime configuration" 1 \
		"Unexpected model replay passthrough names: ${csv}"
	return 0
}

test_model_replay_requires_trusted_runtime_profile() {
	local replay_root="${TEST_ROOT}/model-replay-contract"
	local work_dir="${replay_root}/replay-worktree"
	local config_dir="${replay_root}/runtime-config"
	local prompt_file="${TEST_ROOT}/model-replay-contract-prompt.md"
	mkdir -p "$work_dir" "${config_dir}/agent"
	cp "${SCRIPT_DIR}/../workflows/model-replay.md" "${config_dir}/agent/model-replay.md"
	printf 'Implement the fixture task.\n' >"$prompt_file"
	cat >"${config_dir}/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "default_agent": "model-replay",
  "agent": {
    "model-replay": {
      "mode": "primary",
      "tools": {"*": false, "read": true, "grep": true, "glob": true, "write": true, "edit": true, "apply_patch": true, "bash": false, "task": false, "webfetch": false, "websearch": false},
      "permission": {"*": "deny", "read": "allow", "grep": "allow", "glob": "allow", "write": "allow", "edit": "allow", "apply_patch": "allow", "bash": "deny", "task": "deny", "external_directory": "deny"}
    }
  },
  "tools": {"*": false, "read": true, "grep": true, "glob": true, "write": true, "edit": true, "apply_patch": true, "bash": false, "task": false, "webfetch": false, "websearch": false},
  "permission": {"*": "deny", "read": "allow", "grep": "allow", "glob": "allow", "write": "allow", "edit": "allow", "apply_patch": "allow", "bash": "deny", "task": "deny", "external_directory": "deny"},
  "mcp": {},
  "formatter": false,
  "lsp": false,
  "share": "disabled",
  "subagent_depth": 0
}
JSON

	local role="$HEADLESS_ROLE_MODEL_REPLAY"
	local session_key="model-replay-0123456789abcdef0123-01234567-89ab-cdef-0123-456789abcdef"
	local title="Model replay"
	local model_override="openai/replay-fixture"
	local initial_model=""
	local variant_override="high"
	local agent_name="model-replay"
	local headless_runtime="opencode"
	local detach=0
	local AIDEVOPS_HEADLESS_APPEND_CONTRACT=0
	local AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"
	local AIDEVOPS_HEADLESS_SANDBOX_DISABLED=0
	local AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE=""
	local AIDEVOPS_WORKER_EGRESS_BACKEND=""
	local AIDEVOPS_WORKER_EGRESS_MODE="required"
	local AIDEVOPS_WORKTREE_BASE_DIR="$replay_root"
	local OPENCODE_CONFIG="${config_dir}/opencode.json"
	local OPENCODE_CONFIG_DIR="$config_dir"
	local OPENCODE_DISABLE_AUTOCOMPACT=1
	local OPENCODE_DISABLE_AUTOUPDATE=1
	local OPENCODE_DISABLE_CLAUDE_CODE=1
	local OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1
	local OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
	local OPENCODE_DISABLE_DEFAULT_PLUGINS=""
	local OPENCODE_DISABLE_EXTERNAL_SKILLS=1
	local OPENCODE_DISABLE_LSP_DOWNLOAD=1
	local OPENCODE_DISABLE_MODELS_FETCH=1
	local OPENCODE_DISABLE_PROJECT_CONFIG=1
	local OPENCODE_DISABLE_SHARE=1
	local OPENCODE_PURE=1
	local -a extra_args=()
	local valid_status=0 provider_plugins_status=0 trusted_status=0 backend_status=0 mismatch_status=0 invalid_posture_status=0
	local invalid_status=0 prewarm_status=0

	_validate_model_replay_args >/dev/null 2>&1 || valid_status=$?
	OPENCODE_DISABLE_DEFAULT_PLUGINS=1
	_validate_model_replay_args >/dev/null 2>&1 || provider_plugins_status=$?
	OPENCODE_DISABLE_DEFAULT_PLUGINS=""
	AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE="trusted-local"
	AIDEVOPS_WORKER_EGRESS_MODE="auto"
	_validate_model_replay_args >/dev/null 2>&1 || trusted_status=$?
	AIDEVOPS_WORKER_EGRESS_BACKEND="/configured/backend"
	_validate_model_replay_args >/dev/null 2>&1 || backend_status=$?
	AIDEVOPS_WORKER_EGRESS_BACKEND=""
	AIDEVOPS_WORKER_EGRESS_MODE="required"
	_validate_model_replay_args >/dev/null 2>&1 || mismatch_status=$?
	AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE="invalid"
	AIDEVOPS_WORKER_EGRESS_MODE="auto"
	_validate_model_replay_args >/dev/null 2>&1 || invalid_posture_status=$?
	AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE=""
	AIDEVOPS_WORKER_EGRESS_MODE="required"
	local AIDEVOPS_WORKER_PREWARM_DIR="${TEST_ROOT}/stale-model-replay-prewarm"
	_validate_model_replay_args >/dev/null 2>&1 || prewarm_status=$?
	unset AIDEVOPS_WORKER_PREWARM_DIR
	session_key="issue-30560"
	_validate_model_replay_args >/dev/null 2>&1 || invalid_status=$?
	if [[ "$valid_status" -eq 0 && "$provider_plugins_status" -ne 0 &&
		"$trusted_status" -eq 0 && "$backend_status" -ne 0 &&
		"$mismatch_status" -ne 0 &&
		"$invalid_posture_status" -ne 0 && "$prewarm_status" -ne 0 && "$invalid_status" -ne 0 ]]; then
		print_result "model replay requires its fresh trusted runtime profile" 0
		return 0
	fi

	print_result "model replay requires its fresh trusted runtime profile" 1 \
		"valid=$valid_status provider_plugins=$provider_plugins_status trusted=$trusted_status backend=$backend_status mismatch=$mismatch_status posture=$invalid_posture_status prewarm=$prewarm_status invalid=$invalid_status"
	return 0
}

test_model_replay_rejects_generic_canary() {
	local output="" status=0
	output=$(cmd_canary --role "$HEADLESS_ROLE_MODEL_REPLAY" --model "openai/replay-fixture" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"supported only by the run command"* ]]; then
		print_result "model replay rejects the generic provider canary path" 0
		return 0
	fi
	print_result "model replay rejects the generic provider canary path" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_model_replay_does_not_clear_shared_session_state() {
	local state=""
	state=$(
		local role="$HEADLESS_ROLE_MODEL_REPLAY"
		local session_key="model-replay-0123456789abcdef0123-01234567-89ab-cdef-0123-456789abcdef"
		local work_dir="$TEST_ROOT" headless_runtime="opencode"
		local prompt="fixture" force_file_transport=0
		local prompt_arg="" prompt_file_arg="" claude_stdin_file=""
		local provider="" metric_work_dir="" persisted_session=""
		local selected_model="openai/replay-fixture" title="Model replay"
		local variant_override="high" agent_name="model-replay" runtime=""
		local clear_calls=0 prepare_status=0
		local -a cmd=() extra_args=()
		_recover_deleted_cwd_before_launch() { return 0; }
		_prepare_runtime_prompt_transport() {
			_HEADLESS_RUN_PROMPT_ARG="fixture"
			_HEADLESS_RUN_PROMPT_FILE=""
			_HEADLESS_CLAUDE_STDIN_FILE=""
			return 0
		}
		clear_session_id() {
			clear_calls=$((clear_calls + 1))
			return 0
		}
		_build_run_cmd() {
			printf '%s\0' "opencode" "run"
			return 0
		}
		_prepare_run_attempt_command >/dev/null 2>&1 || prepare_status=$?
		printf '%s|%s|%s' "$prepare_status" "$clear_calls" "$metric_work_dir"
	)

	if [[ "$state" == "0|0|" ]]; then
		print_result "model replay does not clear shared continuation session state" 0
		return 0
	fi
	print_result "model replay does not clear shared continuation session state" 1 "state=$state"
	return 0
}

test_model_replay_rate_limit_does_not_mutate_shared_backoff() {
	local state=""
	state=$(
		local role="$HEADLESS_ROLE_MODEL_REPLAY" provider="openai"
		local session_key="model-replay-0123456789abcdef0123-01234567-89ab-cdef-0123-456789abcdef"
		local selected_model="openai/replay-fixture" output_file="${TEST_ROOT}/model-replay-rate-limit.out"
		local permission_request_file="${TEST_ROOT}/model-replay-permission.json"
		local _rl_fast_sentinel="${TEST_ROOT}/model-replay-rate-limit"
		local metric_work_dir="" _metric_kill_reason="unknown" start_ms=0
		local resource_sampler_pid="" resource_result_file="" resource_stop_file=""
		local backoff_calls=0 finish_status=0
		printf 'rate limited\n' >"$output_file"
		record_provider_backoff() {
			backoff_calls=$((backoff_calls + 1))
			return 0
		}
		_hrw_reconcile_session_permission_blockers() { return 0; }
		append_runtime_metric() { return 0; }
		print_info() { return 0; }
		_finish_run_attempt_rate_limit_fast >/dev/null 2>&1 || finish_status=$?
		printf '%s|%s' "$finish_status" "$backoff_calls"
	)

	if [[ "$state" == "80|0" ]]; then
		print_result "model replay rate limits do not mutate shared provider backoff" 0
		return 0
	fi
	print_result "model replay rate limits do not mutate shared provider backoff" 1 "state=$state"
	return 0
}

test_model_replay_skips_shared_oauth_pool_rotation() {
	local evidence=""
	evidence=$(
		_rotation_count_for_role() {
			local runtime_role="$1"
			local isolated_data_dir="${TEST_ROOT}/oauth-rotation-${runtime_role}"
			local private_workload=0 public_triage=1 rotation_calls=0
			local _invoke_persisted_session="" _WORKER_ISOLATED_DB_PATH=""
			mkdir -p "${isolated_data_dir}/opencode"
			printf '{}\n' >"${isolated_data_dir}/opencode/auth.json"
			_sync_worker_db_migration_metadata() { return 0; }
			_maybe_rotate_isolated_auth() {
				rotation_calls=$((rotation_calls + 1))
				return 0
			}
			_invoke_opencode_export_isolation >/dev/null || return 1
			printf '%s' "$rotation_calls"
			return 0
		}
		printf '%s|' "$(_rotation_count_for_role "$HEADLESS_ROLE_MODEL_REPLAY")"
		_rotation_count_for_role "$HEADLESS_ROLE_TRIAGE"
	)

	if [[ "$evidence" == "0|1" ]]; then
		print_result "model replay skips shared OAuth pool rotation" 0
		return 0
	fi
	print_result "model replay skips shared OAuth pool rotation" 1 \
		"evidence=${evidence:-<empty>}"
	return 0
}

test_model_replay_captures_concrete_runtime_request_evidence() {
	local isolated_dir="${TEST_ROOT}/model-replay-runtime-evidence"
	local runtime_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "${isolated_dir}/opencode"
	sqlite3 "$runtime_db" <<'SQL'
CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL);
INSERT INTO message VALUES ('m1', '{"role":"assistant","providerID":"openai","modelID":"replay-fixture","variant":"high","tokens":{"input":10,"output":5},"cost":0.01}');
INSERT INTO message VALUES ('m2', '{"role":"assistant","providerID":"openai","modelID":"replay-fixture","variant":"high","tokens":{"total":20},"cost_usd":0.02}');
INSERT INTO message VALUES ('m3', '{"role":"assistant","model":{"providerID":"openai","modelID":"replay-other","variant":"xhigh"},"tokens":{"input":2,"output":3}}');
INSERT INTO message VALUES ('m4', '{"role":"user","variant":"unrelated"}');
SQL

	local evidence=""
	evidence=$(
		local runtime_role="$HEADLESS_ROLE_MODEL_REPLAY"
		local _MODEL_REPLAY_OBSERVED_MODEL=""
		local _MODEL_REPLAY_OBSERVED_VARIANT=""
		local _MODEL_REPLAY_REQUEST_COUNT=""
		local _MODEL_REPLAY_USAGE_COUNT=""
		local _MODEL_REPLAY_TOKENS_TOTAL=""
		local _MODEL_REPLAY_COST_COUNT=""
		local _MODEL_REPLAY_COST_USD=""
		_capture_model_replay_runtime_evidence "$isolated_dir" || exit 1
		printf '%s|%s|%s|%s|%s|%s|%s' "$_MODEL_REPLAY_OBSERVED_MODEL" \
			"$_MODEL_REPLAY_OBSERVED_VARIANT" "$_MODEL_REPLAY_REQUEST_COUNT" \
			"$_MODEL_REPLAY_USAGE_COUNT" "$_MODEL_REPLAY_TOKENS_TOTAL" \
			"$_MODEL_REPLAY_COST_COUNT" "$_MODEL_REPLAY_COST_USD"
	)

	if [[ "$evidence" == "openai/replay-fixture,openai/replay-other|high,xhigh|3|3|40|2|0.03" ]]; then
		print_result "model replay captures concrete runtime request evidence before cleanup" 0
		return 0
	fi
	print_result "model replay captures concrete runtime request evidence before cleanup" 1 \
		"evidence=${evidence:-<empty>}"
	return 0
}

test_model_replay_ignores_ambient_variant_defaults() {
	local resolved=""
	resolved=$(AIDEVOPS_HEADLESS_VARIANT="xhigh" AIDEVOPS_HEADLESS_VARIANT_SIMPLE="high" \
		resolve_headless_variant "$HEADLESS_ROLE_MODEL_REPLAY" "simple" "openai/replay-fixture")
	if [[ -z "$resolved" ]]; then
		print_result "model replay default effort ignores ambient and routed variants" 0
		return 0
	fi
	print_result "model replay default effort ignores ambient and routed variants" 1 \
		"resolved=${resolved}"
	return 0
}

test_model_replay_never_attaches_to_ambient_server() {
	local command_text=""
	command_text=$(
		local role="$HEADLESS_ROLE_MODEL_REPLAY"
		_detect_opencode_server() {
			printf '%s\n%s\n' "http://localhost:4096" "test-only-password"
			return 0
		}
		while IFS= read -r -d '' argument; do
			printf '<%s>' "$argument"
		done < <(_build_run_cmd "openai/replay-fixture" "$TEST_ROOT" "prompt" \
			"Model replay" "" "model-replay" "")
	)
	if [[ "$command_text" != *"--attach"* && "$command_text" != *"--password"* &&
		"$command_text" != *"test-only-password"* ]]; then
		print_result "model replay never attaches to an ambient OpenCode server" 0
		return 0
	fi
	print_result "model replay never attaches to an ambient OpenCode server" 1 "$command_text"
	return 0
}

test_metric_path_overrides_and_replay_usage_fields() {
	local override_root="${TEST_ROOT}/metric-overrides"
	local runtime_metrics="${override_root}/runtime.jsonl"
	local resource_metrics="${override_root}/resources.jsonl"
	mkdir -p "$override_root"
	local paths=""
	paths=$(
		HOME="${override_root}/home" \
			AIDEVOPS_HEADLESS_RUNTIME_DIR="${override_root}/state" \
			AIDEVOPS_HEADLESS_METRICS_FILE="$runtime_metrics" \
			AIDEVOPS_RESOURCE_METRICS_FILE="$resource_metrics" \
			bash -c '
				source "$1" help >/dev/null 2>&1
				_MODEL_REPLAY_OBSERVED_MODEL="openai/replay-fixture"
				_MODEL_REPLAY_OBSERVED_VARIANT="high"
				_MODEL_REPLAY_REQUEST_COUNT="1"
				_MODEL_REPLAY_USAGE_COUNT="1"
				_MODEL_REPLAY_TOKENS_TOTAL="15"
				_MODEL_REPLAY_COST_COUNT="1"
				_MODEL_REPLAY_COST_USD="0"
				AIDEVOPS_DISPATCH_TIER="simple"
				append_runtime_metric "model-replay" "model-replay-test" \
					"openai/replay-fixture" "openai" "success" "0" "" "1" "10"
				printf "%s|%s" "$METRICS_FILE" "$RESOURCE_METRICS_FILE"
			' _ "$HELPER_SCRIPT"
	)
	if [[ "$paths" == "${runtime_metrics}|${resource_metrics}" ]] &&
		jq -e 'select(.routing_tier == "simple" and .observed_usage_count == 1 and .observed_tokens_total == 15 and .observed_cost_count == 1 and .observed_cost_usd == 0)' \
			"$runtime_metrics" >/dev/null 2>&1; then
		print_result "metric producers honor path overrides and preserve replay usage" 0
		return 0
	fi
	print_result "metric producers honor path overrides and preserve replay usage" 1 \
		"paths=${paths:-<empty>} runtime_metrics=$runtime_metrics"
	return 0
}

test_model_replay_explicit_model_ignores_shared_backoff() {
	local evidence=""
	evidence=$(
		local replay_model="" replay_status=0 worker_status=0
		model_backoff_active() { return 0; }
		replay_model=$(_choose_model_explicit "openai/replay-fixture" "$HEADLESS_ROLE_MODEL_REPLAY") || replay_status=$?
		_choose_model_explicit "openai/replay-fixture" "worker" >/dev/null 2>&1 || worker_status=$?
		printf '%s|%s|%s' "$replay_model" "$replay_status" "$worker_status"
	)
	if [[ "$evidence" == "openai/replay-fixture|0|75" ]]; then
		print_result "model replay explicit selection ignores shared provider backoff" 0
		return 0
	fi
	print_result "model replay explicit selection ignores shared provider backoff" 1 \
		"evidence=${evidence:-<empty>}"
	return 0
}

test_model_replay_failures_do_not_mutate_shared_provider_state() {
	local evidence=""
	evidence=$(
		local pool_calls=0 backoff_calls=0
		attempt_pool_recovery() {
			pool_calls=$((pool_calls + 1))
			return 1
		}
		record_provider_backoff() {
			backoff_calls=$((backoff_calls + 1))
			return 0
		}
		_capture_model_replay_failure() {
			local failure_reason="$1"
			local output_file="${TEST_ROOT}/model-replay-${failure_reason}.out"
			local role="$HEADLESS_ROLE_MODEL_REPLAY" provider="openai"
			local selected_model="openai/replay-fixture" exit_code=1 status=0
			local _run_failure_reason="" _run_should_retry=9
			: >"$output_file"
			_finish_failed_run_result "$failure_reason" || status=$?
			printf '%s:%s:%s:%s:%s' "$failure_reason" "$status" \
				"$_run_should_retry" "$pool_calls" "$backoff_calls"
			return 0
		}
		_capture_model_replay_failure "auth_error"
		printf '|'
		_capture_model_replay_failure "provider_error"
	)
	if [[ "$evidence" == "auth_error:1:0:0:0|provider_error:1:0:0:0" ]]; then
		print_result "model replay failures avoid shared provider recovery and backoff state" 0
		return 0
	fi
	print_result "model replay failures avoid shared provider recovery and backoff state" 1 \
		"evidence=${evidence:-<empty>}"
	return 0
}
