#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper.sh - Coverage for /full-loop headless contract injection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../headless-runtime-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

# Bypass the aidevops git policy shim for disposable repositories created under
# this test's isolated temporary HOME.
git() {
	command -p git "$@"
	return $?
}

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	set +e
	# shellcheck source=/dev/null
	source "$HELPER_SCRIPT" >/dev/null 2>&1
	set -e
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

init_git_worktree() {
	local worktree_dir="$1"
	git -C "$worktree_dir" init -q
	git -C "$worktree_dir" remote add origin "https://github.com/owner/repo.git"
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "initial"
	git -C "$worktree_dir" update-ref refs/remotes/origin/main HEAD
	git -C "$worktree_dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	return 0
}

test_appends_escalation_contract() {
	local prompt='/full-loop Implement issue #14964'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'HEADLESS_CONTINUATION_CONTRACT_V9'* ]] &&
		[[ "$output" == *'Read the issue body FIRST'* ]] &&
		[[ "$output" == *'Look for a "Worker Guidance" or "How" section'* ]] &&
		[[ "$output" == *'do bounded discovery instead of stopping'* ]] &&
		[[ "$output" == *'Auto-generated "Unactioned Review Feedback" / quality-debt issues are not missing context solely because they lack file paths'* ]] &&
		[[ "$output" == *'Exit BLOCKED with reason "missing implementation context" only after bounded discovery'* ]] &&
		[[ "$output" == *'Worktree edit verification (GH#22816)'* ]] &&
		[[ "$output" == *'Incremental WIP commits (GH#23677)'* ]] &&
		[[ "$output" == *'A first WIP commit makes the worktree cleanup-visible as active real work even before a PR exists'* ]] &&
		[[ "$output" == *'Progressive context loading'* ]] &&
		[[ "$output" == *'Load only referenced workflow/reference docs'* ]] &&
		[[ "$output" == *'Stop reading once target files, reference pattern, constraints, and verification are clear.'* ]] &&
		[[ "$output" == *'Never ask for user confirmation, approval, or next steps. No user will respond.'* ]] &&
		[[ "$output" == *'emit POST_PR_HANDOFF on its own line'* ]] &&
		[[ "$output" == *'Valid exit states are FULL_LOOP_COMPLETE, POST_PR_HANDOFF'* ]]; then
		print_result "appends escalation-before-blocked contract to full-loop prompts" 0
		return 0
	fi

	print_result "appends escalation-before-blocked contract to full-loop prompts" 1 "Output missing required contract clauses"
	return 0
}

test_non_full_loop_prompt_unchanged() {
	local prompt='Review this file only'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "leaves non-full-loop prompt unchanged" 0
		return 0
	fi

	print_result "leaves non-full-loop prompt unchanged" 1 "Prompt was unexpectedly modified"
	return 0
}

test_headless_contract_uses_deployed_framework_paths() {
	local AIDEVOPS_HEADLESS_APPEND_CONTRACT
	AIDEVOPS_HEADLESS_APPEND_CONTRACT=1
	local prompt
	prompt='/full-loop Implement issue #24354'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'Normal project repos: full-loop workflow is deployed at ~/.aidevops/agents/scripts/commands/full-loop.md'* ]] &&
		[[ "$output" == *'Normal project repos: aidevops framework scripts live under ~/.aidevops/agents/scripts/ (not project-local .agents/scripts/)'* ]] &&
		[[ "$output" == *'Aidevops source repo only: the same files are edited at .agents/scripts/commands/full-loop.md and under .agents/scripts/'* ]] &&
		[[ "$output" != *'- Full-loop workflow: .agents/scripts/commands/full-loop.md'* ]] &&
		[[ "$output" != *'- All agent scripts live under .agents/scripts/ (not scripts/ at root)'* ]]; then
		print_result "headless contract uses deployed framework paths for project repos" 0
		return 0
	fi

	print_result "headless contract uses deployed framework paths for project repos" 1 \
		"Output still contains ambiguous source-repo framework path guidance"
	return 0
}

test_parse_initial_model_does_not_set_explicit_override() {
	local role="worker" session_key="issue-22862" work_dir="$TEST_ROOT" title="Issue #22862" prompt="/full-loop test" prompt_file=""
	local model_override="" initial_model="" tier_override="" variant_override="" agent_name="" headless_runtime="" detach=0
	local -a extra_args=()

	_parse_run_args --initial-model openai/gpt-5.5 --tier standard --opencode-arg --print-logs

	if [[ "$initial_model" == "openai/gpt-5.5" && -z "$model_override" && "$tier_override" == "standard" ]]; then
		print_result "--initial-model does not set explicit model override" 0
		return 0
	fi

	print_result "--initial-model does not set explicit model override" 1 \
		"initial_model=${initial_model:-<empty>} model_override=${model_override:-<empty>} tier=${tier_override:-<empty>}"
	return 0
}

test_launch_helpers_tolerate_unset_state_under_nounset() {
	local status=0
	(
		unset _HEADLESS_RUNTIME_TEMP_PATHS
		_cleanup_headless_runtime_temp_paths
	) || status=$?

	if [[ "$status" -eq 0 ]]; then
		print_result "launch temp cleanup tolerates unset state under nounset" 0
	else
		print_result "launch temp cleanup tolerates unset state under nounset" 1 "status=$status"
	fi

	local err_out=""
	status=0
	err_out=$(
		unset session_key work_dir title prompt prompt_file
		_validate_run_args 2>&1
	) || status=$?

	if [[ "$status" -eq 1 && "$err_out" == *"run requires --session-key"* ]]; then
		print_result "launch argument validation reports missing caller state under nounset" 0
		return 0
	fi

	print_result "launch argument validation reports missing caller state under nounset" 1 \
		"status=$status output=${err_out:-<empty>}"
	return 0
}

test_runtime_temp_files_use_managed_workspace() {
	local AIDEVOPS_TEMP_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
	local temp_file=""
	temp_file=$(_create_headless_runtime_temp_file) || {
		print_result "runtime temp files use managed aidevops workspace" 1 "Could not create runtime temp file"
		return 0
	}

	if [[ "$temp_file" == "${HOME}/.aidevops/.agent-workspace/tmp/"* && -f "$temp_file" ]]; then
		rm -f "$temp_file"
		print_result "runtime temp files use managed aidevops workspace" 0
		return 0
	fi

	rm -f "$temp_file"
	print_result "runtime temp files use managed aidevops workspace" 1 "Unexpected path: $temp_file"
	return 0
}

test_headless_temp_initialization_preserves_process_scratch() {
	local TMPDIR="/host/tmpdir"
	local TMP="/host/tmp"
	local TEMP="/host/temp"
	local AIDEVOPS_WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace"
	local expected=""

	aidevops_init_temp_workspace || {
		print_result "headless initialization preserves process scratch" 1 "Could not initialize managed temp workspace"
		return 0
	}
	expected=$(cd "$AIDEVOPS_WORKSPACE_DIR/tmp" && pwd -P)

	if [[ "$TMPDIR" == "/host/tmpdir" && "$TMP" == "/host/tmp" && "$TEMP" == "/host/temp" ]] &&
		[[ "$AIDEVOPS_TEMP_DIR" == "$expected" ]] &&
		grep -q 'aidevops_init_temp_workspace' "$HELPER_SCRIPT"; then
		print_result "headless initialization preserves process scratch" 0
		return 0
	fi

	print_result "headless initialization preserves process scratch" 1 \
		"TMPDIR=$TMPDIR TMP=$TMP TEMP=$TEMP AIDEVOPS_TEMP_DIR=${AIDEVOPS_TEMP_DIR:-<unset>}"
	return 0
}

setup_private_workload_profile_fixture() {
	local work_dir="$1"
	mkdir -p "${work_dir}/.opencode/tool"
	chmod 700 "$work_dir" "${work_dir}/.opencode" "${work_dir}/.opencode/tool"
	printf '%s\n' '{}' >"${work_dir}/jobs.jsonl"
	: >"${work_dir}/fetch-audit.jsonl"
	: >"${work_dir}/results.pending.jsonl"
	printf '%s\n' 'Private workload instructions.' >"${work_dir}/instructions.md"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/tool/provisional_fetch.ts"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/tool/provisional_submit.ts"
	cat >"${work_dir}/.opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "default_agent": "provisional-adjudicator",
  "enabled_providers": ["openai"],
  "formatter": false,
  "instructions": ["instructions.md"],
  "lsp": false,
  "model": "openai/gpt-5.6-sol",
  "share": "disabled",
  "snapshot": false,
  "agent": {
    "provisional-adjudicator": {
      "description": "Adjudicates one protected award batch through fixed, capability-restricted tools.",
      "mode": "primary",
      "model": "openai/gpt-5.6-sol",
      "permission": {
        "*": "deny",
        "bash": "deny",
        "edit": "deny",
        "external_directory": "deny",
        "glob": "deny",
        "grep": "deny",
        "list": "deny",
        "lsp": "deny",
        "provisional_fetch": "allow",
        "provisional_submit": "allow",
        "question": "deny",
        "read": "deny",
        "skill": "deny",
        "task": "deny",
        "todowrite": "deny",
        "webfetch": "deny",
        "websearch": "deny"
      },
      "steps": 12
    }
  }
}
EOF
	chmod 600 "${work_dir}/fetch-audit.jsonl" \
		"${work_dir}/instructions.md" \
		"${work_dir}/jobs.jsonl" \
		"${work_dir}/results.pending.jsonl" \
		"${work_dir}/.opencode/opencode.json" \
		"${work_dir}/.opencode/tool/provisional_fetch.ts" \
		"${work_dir}/.opencode/tool/provisional_submit.ts"
	return 0
}

private_workload_profile_sha256() {
	local work_dir="$1"
	python3 - "$work_dir" <<'PY' || return 1
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = (
    ".opencode/opencode.json",
    ".opencode/tool/provisional_fetch.ts",
    ".opencode/tool/provisional_submit.ts",
    "instructions.md",
    "jobs.jsonl",
)
digest = hashlib.sha256()
for relative_path in paths:
    contents = (root / relative_path).read_bytes()
    digest.update(relative_path.encode("utf-8"))
    digest.update(b"\0")
    digest.update(str(len(contents)).encode("ascii"))
    digest.update(b"\0")
    digest.update(contents)
print(digest.hexdigest())
PY
	return 0
}

_private_profile_fixture_statuses() {
	local work_dir="$1"
	local model_override="$2"
	local agent_name="$3"
	local profile_sha256="$4"
	local generated_profile_status=0 generated_profile_removed=0
	local unexpected_profile_entry_status=0 unexpected_instruction_status=0
	mkdir "${work_dir}/.opencode/node_modules"
	printf '%s\n' '*' >"${work_dir}/.opencode/.gitignore"
	printf '%s\n' '{}' >"${work_dir}/.opencode/package.json"
	printf '%s\n' '{}' >"${work_dir}/.opencode/package-lock.json"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || generated_profile_status=$?
	if [[ ! -e "${work_dir}/.opencode/node_modules" && \
		! -e "${work_dir}/.opencode/.gitignore" && \
		! -e "${work_dir}/.opencode/package.json" && \
		! -e "${work_dir}/.opencode/package-lock.json" ]]; then
		generated_profile_removed=1
	fi

	mkdir "${work_dir}/.opencode/plugin"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/plugin/untrusted.ts"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || unexpected_profile_entry_status=$?
	rm -rf "${work_dir}/.opencode/plugin"

	printf '%s\n' 'Unapproved instructions.' >"${work_dir}/AGENTS.md"
	chmod 600 "${work_dir}/AGENTS.md"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || unexpected_instruction_status=$?
	rm -f "${work_dir}/AGENTS.md"
	printf '%s|%s|%s|%s\n' "$generated_profile_status" "$generated_profile_removed" \
		"$unexpected_profile_entry_status" "$unexpected_instruction_status"
	return 0
}

_private_profile_rejection_statuses() {
	local work_dir="$1"
	local model_override="$2"
	local agent_name="$3"
	local unsafe_profile_status=0 unexpected_permission_status=0 unexpected_config_status=0
	local description_status=0 steps_status=0 current_profile_sha256=""
	jq '.agent["provisional-adjudicator"].permission.read = "allow"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unsafe_profile_status=$?

	jq '.agent["provisional-adjudicator"].permission.read = "deny" | .agent["provisional-adjudicator"].permission.exfiltrate = "allow"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unexpected_permission_status=$?

	jq 'del(.agent["provisional-adjudicator"].permission.exfiltrate) | .plugin = ["untrusted-plugin"]' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unexpected_config_status=$?

	jq 'del(.plugin) | .agent["provisional-adjudicator"].description = "Unapproved description"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || description_status=$?

	jq '.agent["provisional-adjudicator"].description = "Adjudicates one protected award batch through fixed, capability-restricted tools." | .agent["provisional-adjudicator"].steps = 13' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || steps_status=$?
	printf '%s|%s|%s|%s|%s\n' "$unsafe_profile_status" "$unexpected_permission_status" \
		"$unexpected_config_status" "$description_status" "$steps_status"
	return 0
}

test_private_workload_arguments_are_fail_closed() {
	local AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"
	local role="triage" session_key="private-0123456789abcdef0123456789abcdef" work_dir="${TEST_ROOT}/private-profile"
	local title="Private workload" prompt="$PRIVATE_WORKLOAD_PROMPT" prompt_file=""
	local model_override="openai/gpt-5.6-sol" initial_model="" tier_override=""
	local variant_override="" agent_name="provisional-adjudicator" headless_runtime="opencode"
	local detach=0 private_workload=0
	local private_profile_sha256=""
	local -a extra_args=("--pure")
	local helper_source=""
	local launch_source=""
	setup_private_workload_profile_fixture "$work_dir"
	private_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	helper_source=$(<"$HELPER_SCRIPT")
	launch_source=$(<"${HELPER_SCRIPT%/*}/headless-runtime-launch.sh")

	_parse_run_args --private-workload --private-profile-sha256 "$private_profile_sha256"
	local valid_status=0
	local valid_output=""
	valid_output=$(_validate_private_workload_args 2>&1) || valid_status=$?
	local descriptive_session_status=0
	session_key="private-client-case"
	_validate_private_workload_args >/dev/null 2>&1 || descriptive_session_status=$?
	session_key="private-0123456789abcdef0123456789abcdef"

	local fixture_statuses=""
	local generated_profile_status=0 generated_profile_removed=0
	local unexpected_profile_entry_status=0 unexpected_instruction_status=0
	fixture_statuses=$(_private_profile_fixture_statuses \
		"$work_dir" "$model_override" "$agent_name" "$private_profile_sha256")
	IFS='|' read -r generated_profile_status generated_profile_removed \
		unexpected_profile_entry_status unexpected_instruction_status <<<"$fixture_statuses"

	local invalid_extra_status=0
	extra_args=("--pure" "--print-logs")
	_validate_private_workload_args >/dev/null 2>&1 || invalid_extra_status=$?

	local missing_profile_hash_status=0
	private_profile_sha256=""
	_validate_private_workload_args >/dev/null 2>&1 || missing_profile_hash_status=$?
	private_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	local mismatched_profile_hash_status=0
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"0000000000000000000000000000000000000000000000000000000000000000" \
		>/dev/null 2>&1 || mismatched_profile_hash_status=$?

	local invalid_prompt_status=0
	extra_args=("--pure")
	prompt="Confidential candidate details"
	_validate_private_workload_args >/dev/null 2>&1 || invalid_prompt_status=$?

	local invalid_provider_status=0
	prompt="$PRIVATE_WORKLOAD_PROMPT"
	model_override="anthropic/claude-sonnet-4-6"
	_validate_private_workload_args >/dev/null 2>&1 || invalid_provider_status=$?

	local missing_allowlist_status=0
	model_override="openai/gpt-5.6-sol"
	AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=""
	_validate_private_workload_args >/dev/null 2>&1 || missing_allowlist_status=$?
	AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"

	local rejection_statuses=""
	local unsafe_profile_status=0 unexpected_permission_status=0 unexpected_config_status=0
	local description_status=0 steps_status=0
	rejection_statuses=$(_private_profile_rejection_statuses "$work_dir" "$model_override" "$agent_name")
	IFS='|' read -r unsafe_profile_status unexpected_permission_status \
		unexpected_config_status description_status steps_status <<<"$rejection_statuses"

	if [[ "$private_workload" -eq 1 && "$valid_status" -eq 0 && "$descriptive_session_status" -eq 1 && \
		"$generated_profile_status" -eq 0 && "$generated_profile_removed" -eq 1 && \
		"$unexpected_profile_entry_status" -eq 1 && "$unexpected_instruction_status" -eq 1 && \
		"$invalid_extra_status" -eq 1 && "$missing_profile_hash_status" -eq 1 && \
		"$mismatched_profile_hash_status" -eq 1 && "$invalid_prompt_status" -eq 1 && \
		"$invalid_provider_status" -eq 1 && "$missing_allowlist_status" -eq 1 && \
		"$unsafe_profile_status" -eq 1 && \
		"$unexpected_permission_status" -eq 1 && "$unexpected_config_status" -eq 1 && \
		"$description_status" -eq 1 && "$steps_status" -eq 1 && \
		"$helper_source" == *'lifecycle_work_dir="[private]"'* && \
		"$launch_source" == *'display_work_dir="[private]"'* && \
		"$launch_source" == *'display_recovery_dir="[private]"'* && \
		"$helper_source" == *'metric_work_dir=""'* && \
		"$helper_source" == *'unset WORKER_WORKTREE_PATH _WORKER_WORKTREE_PATH'* ]]; then
		print_result "private workload arguments enforce the non-content boundary" 0
		return 0
	fi

	print_result "private workload arguments enforce the non-content boundary" 1 \
		"private=${private_workload} valid=${valid_status} descriptive_session=${descriptive_session_status} generated=${generated_profile_status}:${generated_profile_removed} profile_entry=${unexpected_profile_entry_status} instruction=${unexpected_instruction_status} extra=${invalid_extra_status} hash=${missing_profile_hash_status}:${mismatched_profile_hash_status} prompt=${invalid_prompt_status} provider=${invalid_provider_status}:${missing_allowlist_status} profile=${unsafe_profile_status} permission=${unexpected_permission_status} unexpected=${unexpected_config_status} exact=${description_status}:${steps_status} output=${valid_output:-<empty>}"
	return 0
}

test_private_workload_uses_minimal_lifecycle() {
	local lifecycle_state=""
	lifecycle_state=$(
		local AIDEVOPS_PRIVATE_WORKLOAD=1
		local model_override="openai/gpt-5.6-sol"
		local agent_name="provisional-adjudicator"
		local private_profile_sha256="0000000000000000000000000000000000000000000000000000000000000000"
		local _WORKER_WORKTREE_PATH="/private/path-must-not-persist"
		local WORKER_TARGET_BRANCH="private-branch-must-not-persist"
		local WORKER_NO_EXIT_PUSH=0
		local acquired=0 released=0 workload_acquired=0 workload_released=0
		local cleaned=0 lease_released=0 registered=0 updated=0 claimed=0
		local lifecycle_order=""
		_acquire_session_lock() { acquired=$((acquired + 1)); return 0; }
		_release_session_lock() { released=$((released + 1)); lifecycle_order="${lifecycle_order}session,"; return 0; }
		_acquire_private_workload_lock() { workload_acquired=$((workload_acquired + 1)); return 0; }
		_release_private_workload_lock() { workload_released=$((workload_released + 1)); lifecycle_order="${lifecycle_order}workload,"; return 0; }
		_validate_private_workload_profile() { return 0; }
		_cleanup_headless_runtime_temp_paths() { cleaned=$((cleaned + 1)); lifecycle_order="${lifecycle_order}cleanup,"; return 0; }
		aidevops_runtime_bundle_lease_release() { lease_released=$((lease_released + 1)); lifecycle_order="${lifecycle_order}lease,"; return 0; }
		_register_dispatch_ledger() { registered=$((registered + 1)); return 0; }
		_update_dispatch_ledger() { updated=$((updated + 1)); return 0; }
		_hrw_claim_worker_worktree() { claimed=$((claimed + 1)); return 0; }

		local invalid_prepare_status=0
		_cmd_run_prepare "private-client-case" "$TEST_ROOT" || invalid_prepare_status=$?
		local prepare_status=0
		_cmd_run_prepare "private-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$TEST_ROOT" || prepare_status=$?
		local prepared_path="${_WORKER_WORKTREE_PATH:-}"
		local prepared_branch="${WORKER_TARGET_BRANCH:-}"
		local finish_status=0
		_cmd_run_finish "private-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "complete" "$TEST_ROOT" || finish_status=$?
		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
			"$invalid_prepare_status" "$prepare_status" "$finish_status" "$prepared_path" "$prepared_branch" \
			"$WORKER_NO_EXIT_PUSH" "$acquired" "$released" "$workload_acquired" \
			"$workload_released" "$cleaned" "$lease_released" "$registered" "$updated:$claimed" \
			"$lifecycle_order"
	)

	if [[ "$lifecycle_state" == "1|0|0|||1|1|1|1|1|1|1|0|0:0|cleanup,session,workload,lease," ]]; then
		print_result "private workloads bypass persistent worker lifecycle state" 0
		return 0
	fi

	print_result "private workloads bypass persistent worker lifecycle state" 1 \
		"state=${lifecycle_state:-<empty>}"
	return 0
}

test_private_workload_lock_is_cross_process_atomic() {
	local work_dir="${TEST_ROOT}/private-cross-process-lock"
	local child_script="${TEST_ROOT}/headless-runtime-private-lock-child.sh"
	local ready_file="${TEST_ROOT}/private-lock-ready"
	local release_file="${TEST_ROOT}/private-lock-release"
	local lock_key=""
	local child_pid=""
	local child_status=0 second_status=0 third_status=0
	local remaining_lock_count=""
	mkdir -p "$work_dir"
	init_state_db
	lock_key=$(_private_workload_directory_lock_key "$work_dir") || lock_key=""
	cat >"$child_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
helper_script="$1"
lock_key="$2"
ready_file="$3"
release_file="$4"
set --
# shellcheck source=/dev/null
source "$helper_script" >/dev/null
_acquire_private_workload_lock "$lock_key" || exit 2
printf 'ready\n' >"$ready_file"
while [[ ! -f "$release_file" ]]; do
	sleep 0.05
done
_release_private_workload_lock "$lock_key" || exit 3
EOF
	chmod 700 "$child_script"
	bash "$child_script" "$HELPER_SCRIPT" "$lock_key" "$ready_file" "$release_file" &
	child_pid=$!
	local attempt=0
	while [[ ! -f "$ready_file" && "$attempt" -lt 100 ]]; do
		kill -0 "$child_pid" 2>/dev/null || break
		sleep 0.05
		attempt=$((attempt + 1))
	done
	_acquire_private_workload_lock "$lock_key" >/dev/null 2>&1 || second_status=$?
	printf 'release\n' >"$release_file"
	wait "$child_pid" || child_status=$?
	_acquire_private_workload_lock "$lock_key" >/dev/null 2>&1 || third_status=$?
	_release_private_workload_lock "$lock_key" >/dev/null 2>&1 || true
	remaining_lock_count=$(sqlite3_with_timeout "$STATE_DB" \
		"SELECT COUNT(*) FROM private_workload_locks WHERE lock_key = '${lock_key}';" \
		2>/dev/null) || remaining_lock_count="query-failed"

	if [[ -f "$ready_file" && "$child_status" -eq 0 && "$second_status" -eq 1 && \
		"$third_status" -eq 0 && "$remaining_lock_count" == "0" ]]; then
		print_result "private workload lock acquisition is atomic across processes" 0
		return 0
	fi

	print_result "private workload lock acquisition is atomic across processes" 1 \
		"ready=$([[ -f "$ready_file" ]] && printf yes || printf no) child=${child_status} second=${second_status} third=${third_status} remaining=${remaining_lock_count}"
	return 0
}

test_private_workload_directory_lock_blocks_distinct_sessions() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local work_dir="${TEST_ROOT}/private-directory-lock"
	local model="openai/gpt-5.6-sol"
	local agent="provisional-adjudicator"
	local profile_sha256=""
	local first_session="private-11111111111111111111111111111111"
	local second_session="private-22222222222222222222222222222222"
	local third_session="private-33333333333333333333333333333333"
	init_state_db
	setup_private_workload_profile_fixture "$work_dir"
	profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1

	local first_status=0 second_status=0 third_status=0
	_hrw_prepare_private_workload "$first_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || first_status=$?
	local workload_lock_key="${_PRIVATE_WORKLOAD_LOCK_KEY:-}"
	_hrw_prepare_private_workload "$second_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || second_status=$?
	_cmd_run_finish "$first_session" "complete" "$work_dir" >/dev/null 2>&1
	_hrw_prepare_private_workload "$third_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || third_status=$?
	_cmd_run_finish "$third_session" "complete" "$work_dir" >/dev/null 2>&1
	local remaining_lock_count=""
	remaining_lock_count=$(sqlite3_with_timeout "$STATE_DB" \
		"SELECT COUNT(*) FROM private_workload_locks WHERE lock_key = '${workload_lock_key}';" \
		2>/dev/null) || remaining_lock_count="query-failed"

	if [[ "$first_status" -eq 0 && "$second_status" -eq 2 && "$third_status" -eq 0 && \
		"$workload_lock_key" == private-workload-dir-* && \
		"$remaining_lock_count" == "0" ]]; then
		print_result "private workload directory locks span distinct session keys" 0
		return 0
	fi

	print_result "private workload directory locks span distinct session keys" 1 \
		"first=${first_status} second=${second_status} third=${third_status} lock=${workload_lock_key:-<empty>} remaining=${remaining_lock_count}"
	return 0
}

test_private_output_filter_removes_content() {
	local input_file="${TEST_ROOT}/private-filter-input.jsonl"
	local output_file="${TEST_ROOT}/private-filter-output.jsonl"
	local secret_marker="CLIENT_SECRET_AWARD_28491"
	cat >"$input_file" <<EOF
{"type":"step_start","sessionID":"ses_private","part":{"type":"step-start"}}
{"type":"tool_use","sessionID":"ses_private","part":{"tool":"provisional_submit","state":{"status":"completed","input":{"groupId":"${secret_marker}","decision":{"canonicalName":"${secret_marker}"}},"output":"${secret_marker}"}}}
{"type":"text","sessionID":"ses_private","part":{"text":"${secret_marker}"}}
{"type":"text","sessionID":"ses_private","part":{"text":"TASK_COMPLETE"}}
HTTP 429 rate limit for ${secret_marker}
EOF

	python3 "$PRIVATE_OUTPUT_FILTER" <"$input_file" >"$output_file"
	local filtered_output
	filtered_output=$(<"$output_file")
	if [[ "$filtered_output" == *'"type":"step_start"'* && \
		"$filtered_output" == *'"status":"completed"'* && \
		"$filtered_output" == *'"text":"TASK_COMPLETE"'* && \
		"$filtered_output" == *'HTTP 429 rate limit exceeded'* && \
		"$filtered_output" != *"$secret_marker"* && \
		"$filtered_output" != *'provisional_submit'* && \
		"$filtered_output" != *'ses_private'* ]]; then
		print_result "private output filter emits lifecycle evidence without content" 0
		return 0
	fi

	print_result "private output filter emits lifecycle evidence without content" 1 \
		"Filtered output retained content or omitted safe lifecycle evidence"
	return 0
}

test_private_workload_requires_task_complete() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local incomplete_output="${TEST_ROOT}/private-incomplete-output.jsonl"
	local complete_output="${TEST_ROOT}/private-complete-output.jsonl"
	printf '%s\n' '{"type":"step_start"}' >"$incomplete_output"
	printf '%s\n' '{"type":"step_start"}' '{"text":"TASK_COMPLETE","type":"text"}' >"$complete_output"

	local incomplete_status=0
	local complete_status=0
	_handle_run_result 0 "$incomplete_output" "triage" "openai" "private-incomplete" "openai/gpt-5.6-sol" >/dev/null 2>&1 || incomplete_status=$?
	_handle_run_result 0 "$complete_output" "triage" "openai" "private-complete" "openai/gpt-5.6-sol" >/dev/null 2>&1 || complete_status=$?

	if [[ "$incomplete_status" -eq 77 && "$complete_status" -eq 0 && \
		! -f "$incomplete_output" && ! -f "$complete_output" ]]; then
		print_result "private workloads require an exact TASK_COMPLETE marker" 0
		return 0
	fi

	print_result "private workloads require an exact TASK_COMPLETE marker" 1 \
		"incomplete=${incomplete_status} complete=${complete_status}"
	return 0
}

test_private_workload_skips_persistent_failure_output() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local output_file="${TEST_ROOT}/private-worker-output.jsonl"
	local details_file="${TEST_ROOT}/private-provider-details.log"
	local secret_marker="PRIVATE_FAILURE_DETAIL_39182"
	printf '%s\n' "$secret_marker" >"$output_file"
	printf 'HTTP 503 service unavailable: %s\n' "$secret_marker" >"$details_file"

	local candidate_path excerpt_path
	candidate_path=$(_metric_failure_excerpt_candidate_path "$output_file" "private-test")
	excerpt_path=$(_metric_failure_excerpt_path "$output_file" "private-test")
	_preserve_no_activity_output "$output_file" "private-test" "openai/gpt-5.6-sol"
	record_provider_backoff "openai" "provider_error" "$details_file" "openai/private-test"
	local stored_details
	stored_details=$(db_query "SELECT details FROM provider_backoff WHERE provider = 'openai/private-test';")
	clear_provider_backoff "openai/private-test"

	if [[ -z "$candidate_path" && -z "$excerpt_path" && ! -f "$output_file" && \
		"$stored_details" == "private workload details suppressed" && \
		! -d "${HOME}/.aidevops/logs/worker-failure-excerpts" && \
		! -d "${HOME}/.aidevops/logs/worker-no-activity" ]]; then
		print_result "private workloads do not persist transcript-derived diagnostics" 0
		return 0
	fi

	print_result "private workloads do not persist transcript-derived diagnostics" 1 \
		"candidate=${candidate_path:-<empty>} excerpt=${excerpt_path:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no) details=${stored_details:-<empty>}"
	return 0
}

test_sandbox_private_output_avoids_raw_capture() {
	local sandbox_helper="${HELPER_SCRIPT%/*}/sandbox-exec-helper.sh"
	local sandbox_home="${TEST_ROOT}/private-sandbox-home"
	local payload_script="${TEST_ROOT}/private-sandbox-payload.sh"
	local caller_output="${TEST_ROOT}/private-sandbox-caller.log"
	local secret_marker="SANDBOX_PRIVATE_CONTENT_78213"
	mkdir -p "$sandbox_home"
	cat >"$payload_script" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${secret_marker}'
printf '%s\n' '${secret_marker}' >&2
EOF
	chmod +x "$payload_script"

	local unauthorized_status=0 sandbox_status=0
	HOME="$sandbox_home" "$sandbox_helper" run --private-output --allow-secret-io \
		--timeout 10 -- bash "$payload_script" >/dev/null 2>&1 || unauthorized_status=$?
	AIDEVOPS_PRIVATE_WORKLOAD=1 HOME="$sandbox_home" \
		"$sandbox_helper" run --private-output --allow-secret-io \
		--timeout 10 -- bash "$payload_script" >"$caller_output" 2>&1 || sandbox_status=$?
	local persisted_secret=0
	if grep -R -Fq "$secret_marker" "${sandbox_home}/.aidevops/.agent-workspace/sandbox" 2>/dev/null; then
		persisted_secret=1
	fi
	local audit_output=""
	if [[ -f "${sandbox_home}/.aidevops/.agent-workspace/sandbox/executions.jsonl" ]]; then
		audit_output=$(<"${sandbox_home}/.aidevops/.agent-workspace/sandbox/executions.jsonl")
	fi

	if [[ "$unauthorized_status" -eq 2 && "$sandbox_status" -eq 0 && \
		"$persisted_secret" -eq 0 && \
		"$(<"$caller_output")" == *"$secret_marker"* && \
		"$audit_output" == *'[private workload command suppressed]'* ]]; then
		print_result "sandbox private output streams without raw temp or audit capture" 0
		return 0
	fi

	print_result "sandbox private output streams without raw temp or audit capture" 1 \
		"unauthorized=${unauthorized_status} status=${sandbox_status} persisted_secret=${persisted_secret} audit=${audit_output:-<empty>}"
	return 0
}

test_startup_no_activity_timeout_returns_watchdog_continue() {
	local output_file="${TEST_ROOT}/startup-stall.log"
	printf '%s\n' 'sqlite-migration:done' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 124 "$output_file" "worker" "openai" "issue-22862" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "watchdog_startup_continue" && "$_run_failure_reason" == "startup_no_model_activity" && ! -f "$output_file" ]]; then
		print_result "startup no-activity timeout attempts bounded continuation" 0
		return 0
	fi

	print_result "startup no-activity timeout attempts bounded continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_startup_no_activity_can_rotate_after_continuation_budget() {
	local result status action next_model
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="startup_no_model_activity"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		choose_model() { printf '%s' 'anthropic/claude-sonnet-4-6'; return 0; }
		_cmd_run_finish() { return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-24949" "" 1 3 "openai/gpt-5.5" 78 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$cmd_run_action" "$cmd_run_next_model"
	)
	IFS='|' read -r status action next_model <<<"$result"

	if [[ "$status" -eq 0 && "$action" == "switch" && "$next_model" == "anthropic/claude-sonnet-4-6" ]]; then
		print_result "startup no-activity can rotate after continuation budget" 0
		return 0
	fi

	print_result "startup no-activity can rotate after continuation budget" 1 \
		"status=$status action=${action:-<empty>} next=${next_model:-<empty>}"
	return 0
}

test_sigkill_with_activity_attempts_continuation() {
	local output_file="${TEST_ROOT}/sigkill-with-activity.jsonl"
	cat >"$output_file" <<'EOF'
{"type":"text","text":"I made a change after reading docs that mention rate limit."}
[WORKER_EXIT_DIAGNOSTICS] exit_code=137 model=openai/gpt-5.5 role=worker session_key=issue-23036
[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)
EOF
	_run_result_label=""
	_run_failure_reason=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""

	local status=0
	_handle_run_result 137 "$output_file" "worker" "openai" "issue-23036" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "signal_killed_continue" && "$_run_runtime_error_type" == "sigkill" && ! -f "$output_file" ]]; then
		print_result "SIGKILL with activity attempts continuation" 0
		return 0
	fi

	print_result "SIGKILL with activity attempts continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} runtime=${_run_runtime_error_type:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_sigterm_with_local_kill_reason_does_not_resume_as_provider_drop() {
	local output_file="${TEST_ROOT}/sigterm-local-kill.jsonl"
	cat >"$output_file" <<'EOF'
{"type":"text","text":"I was working before the local watchdog killed me."}
[WORKER_EXIT_DIAGNOSTICS] exit_code=143 model=openai/gpt-5.5 role=worker session_key=issue-25394
EOF
	_run_result_label=""
	_run_failure_reason=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""
	_metric_kill_reason="no_output_stall"

	local status=0
	_handle_run_result 143 "$output_file" "worker" "openai" "issue-25394" "openai/gpt-5.5" || status=$?
	unset _metric_kill_reason 2>/dev/null || true

	if [[ "$status" -eq 83 && "$_run_result_label" == "local_kill" && "$_run_failure_reason" == "no_output_stall" && "$_run_runtime_error_type" == "sigterm" && "$_run_classification_source" == "worker_kill_reason_sentinel" && ! -f "$output_file" ]]; then
		print_result "SIGTERM with local kill reason is not treated as provider/runtime drop" 0
		return 0
	fi

	print_result "SIGTERM with local kill reason is not treated as provider/runtime drop" 1 \
		"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} runtime=${_run_runtime_error_type:-<empty>} source=${_run_classification_source:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_handle_run_result_tolerates_empty_or_non_numeric_exit_code() {
	local empty_output_file="${TEST_ROOT}/empty-exit-code.jsonl"
	local text_output_file="${TEST_ROOT}/text-exit-code.jsonl"
	printf '%s\n' 'runtime exited before writing a numeric status' >"$empty_output_file"
	printf '%s\n' 'runtime wrote a non-numeric status' >"$text_output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local empty_status=0 empty_error=""
	set +e
	empty_error=$(_handle_run_result "" "$empty_output_file" "worker" "openai" "issue-25437" "openai/gpt-5.5" 2>&1)
	empty_status=$?
	set -e

	local text_status=0 text_error=""
	set +e
	text_error=$(_handle_run_result "not-a-number" "$text_output_file" "worker" "openai" "issue-25437" "openai/gpt-5.5" 2>&1)
	text_status=$?
	set -e

	if [[ "$empty_status" -eq 1 && "$text_status" -eq 1 ]] && \
		[[ "$empty_error" != *"syntax error"* && "$empty_error" != *"numeric argument"* ]] && \
		[[ "$text_error" != *"syntax error"* && "$text_error" != *"numeric argument"* ]]; then
		print_result "_handle_run_result tolerates empty or non-numeric exit code" 0
		return 0
	fi

	print_result "_handle_run_result tolerates empty or non-numeric exit code" 1 \
		"empty_status=$empty_status empty_error=${empty_error:-<empty>} text_status=$text_status text_error=${text_error:-<empty>}"
	return 0
}

test_dispatcher_initial_model_can_rotate_after_rate_limit() {
	local result status action next_model
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		choose_model() { printf '%s' 'anthropic/claude-sonnet-4-6'; return 0; }
		_cmd_run_finish() { return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$cmd_run_action" "$cmd_run_next_model"
	)
	IFS='|' read -r status action next_model <<<"$result"

	if [[ "$status" -eq 0 && "$action" == "switch" && "$next_model" == "anthropic/claude-sonnet-4-6" ]]; then
		print_result "dispatcher-selected initial model can rotate after rate limit" 0
		return 0
	fi

	print_result "dispatcher-selected initial model can rotate after rate limit" 1 \
		"status=$status action=${action:-<empty>} next=${next_model:-<empty>}"
	return 0
}

test_explicit_model_override_remains_pinned_on_rate_limit() {
	local result status finished_status action
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		local finished_inner=""
		_cmd_run_finish() { local status_arg="$2"; finished_inner="$status_arg"; return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "openai/gpt-5.5" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$finished_inner" "$cmd_run_action"
	)
	IFS='|' read -r status finished_status action <<<"$result"

	if [[ "$status" -eq 124 && "$finished_status" == "fail" && "$action" == "retry" ]]; then
		print_result "explicit model override remains pinned on rate limit" 0
		return 0
	fi

	print_result "explicit model override remains pinned on rate limit" 1 \
		"status=$status finish=${finished_status:-<empty>} action=${action:-<empty>}"
	return 0
}

test_issue_worker_env_contract_rejects_missing_env() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 0
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_issue_worker_env_contract_rejects_missing_worktree() {
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_WORKTREE_PATH unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 1 \
		"status=$status output=${output:-<empty>}"
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
	return 0
}

test_issue_worker_env_contract_accepts_valid_precreated_worktree() {
	local worktree_dir="${TEST_ROOT}/precreated-worktree"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	if _validate_issue_worker_env_contract \
		"worker" "issue-22438" "$worktree_dir" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438"; then
		print_result "issue worker env contract accepts valid precreated worktree" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract accepts valid precreated worktree" 1
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
	return 0
}

test_worker_worktree_claim_transfers_to_runtime_pid() {
	local worktree_dir="${TEST_ROOT}/claim-worktree"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"

	local claimed_path="" claimed_branch="" claimed_session="" claimed_task="" claimed_pid=""
	claim_worktree_ownership() {
		claimed_path="$1"
		claimed_branch="$2"
		shift 2
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--session)
				claimed_session="${2:-}"
				shift 2
				;;
			--task)
				claimed_task="${2:-}"
				shift 2
				;;
			--owner-pid)
				claimed_pid="${2:-}"
				shift 2
				;;
			*) shift ;;
			esac
		done
		return 0
	}

	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null

	unset -f claim_worktree_ownership 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER 2>/dev/null || true

	if [[ "$claimed_path" == "$worktree_dir" ]] &&
		[[ "$claimed_branch" == "detached" ]] &&
		[[ "$claimed_session" == "issue-22438" ]] &&
		[[ "$claimed_task" == "22438" ]] &&
		[[ "$claimed_pid" == "$$" ]]; then
		print_result "worker worktree claim transfers ownership to runtime PID" 0
		return 0
	fi

	print_result "worker worktree claim transfers ownership to runtime PID" 1 \
		"path=$claimed_path branch=$claimed_branch session=$claimed_session task=$claimed_task pid=$claimed_pid"
	return 0
}

test_worker_worktree_claim_reclaims_stale_live_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/claim-stale-live-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="1"
	local claim_calls=0 transfer_called=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "old-session" "" "22438" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_called=$((transfer_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_called" -eq 1 && "$unregister_called" -eq 0 ]]; then
		print_result "worker worktree claim reclaims stale live same-task owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims stale live same-task owner" 1 \
		"status=$status calls=$claim_calls transfer=$transfer_called unregister=$unregister_called"
	return 0
}

test_worker_worktree_claim_reclaims_dispatch_precreate_owner() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="900"
	local claim_calls=0 transfer_called=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "" "22438" "2099-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_called=$((transfer_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_called" -eq 1 && "$unregister_called" -eq 0 ]]; then
		print_result "worker worktree claim reclaims dispatch precreate owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims dispatch precreate owner" 1 \
		"status=$status calls=$claim_calls transfer=$transfer_called unregister=$unregister_called"
	return 0
}

test_worker_worktree_claim_transfers_dispatch_precreate_task_state() {
	local state_kind="" worktree_dir="" expected_head="" actual_head=""
	local preserved_status="" ahead_count="" owner_created_at="" transfer_args=""
	local live_pid="$$" claim_calls=0 transfer_calls=0 unregister_calls=0 status=0

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_calls=$((unregister_calls + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		shift 2
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		transfer_args="$*"
		return 0
	}

	for state_kind in dirty ahead; do
		worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-${state_kind}"
		mkdir -p "$worktree_dir"
		init_git_worktree "$worktree_dir"
		expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
		if [[ "$state_kind" == "dirty" ]]; then
			printf 'preserve me\n' >"${worktree_dir}/precreate-task-state.txt"
			owner_created_at="2026-07-18T00:00:05Z"
		else
			git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
				commit --allow-empty -q -m "precreate checkpoint"
			expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
			owner_created_at="2026-07-18T00:00:06Z"
		fi

		export WORKER_ISSUE_NUMBER="22438"
		claim_calls=0
		transfer_calls=0
		unregister_calls=0
		transfer_args=""
		status=0
		_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
		preserved_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)
		actual_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || true)
		ahead_count=$(git -C "$worktree_dir" rev-list --count origin/main..HEAD 2>/dev/null || true)

		local state_preserved=0
		if [[ "$state_kind" == "dirty" && "$preserved_status" == *"precreate-task-state.txt"* &&
			"$actual_head" == "$expected_head" && "$ahead_count" == "0" ]]; then
			state_preserved=1
		elif [[ "$state_kind" == "ahead" && -z "$preserved_status" &&
			"$actual_head" == "$expected_head" && "$ahead_count" == "1" ]]; then
			state_preserved=1
		fi

		if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_calls" -eq 1 &&
			"$unregister_calls" -eq 0 && "$state_preserved" -eq 1 &&
			"$transfer_args" == *"--expected-session dispatch-precreate-22438"* &&
			"$transfer_args" == *"--expected-batch batch-7"* &&
			"$transfer_args" == *"--expected-task 22438"* ]]; then
			print_result "${state_kind} dispatch-precreate state transfers atomically without data loss" 0
		else
			print_result "${state_kind} dispatch-precreate state transfers atomically without data loss" 1 \
				"status=$status claims=$claim_calls transfers=$transfer_calls unregisters=$unregister_calls preserved=$state_preserved args=${transfer_args:-<empty>}"
		fi
	done

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

test_worker_worktree_claim_rejects_dispatch_precreate_task_mismatch() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-task-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" transfer_calls=0

	claim_worktree_ownership() {
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-99999" "batch-7" "99999" "2026-07-18T00:00:10Z"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_live_owner" ]]; then
		print_result "dispatch-precreate transfer rejects a different task owner" 0
		return 0
	fi
	print_result "dispatch-precreate transfer rejects a different task owner" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_claim_classifies_dispatch_precreate_concurrent_mutation() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-concurrent-mutation"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" transfer_calls=0

	claim_worktree_ownership() {
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "batch-7" "22438" "2026-07-18T00:00:11Z"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 1
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 1 &&
		"$reason" == "worker_worktree_owner_concurrent_mutation" ]]; then
		print_result "dispatch-precreate transfer rejects concurrent owner mutation" 0
		return 0
	fi
	print_result "dispatch-precreate transfer rejects concurrent owner mutation" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

set_continuation_transfer_env() {
	local owner_pid="$1"
	local owner_session="$2"
	local owner_batch="$3"
	local owner_task="$4"
	local owner_created_at="$5"
	export AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE="continuation"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID="$owner_pid"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION="$owner_session"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH="$owner_batch"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK="$owner_task"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT="$owner_created_at"
	return 0
}

clear_continuation_transfer_env() {
	unset AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT \
		WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

test_worker_worktree_continuation_transfers_dirty_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/continuation-dirty"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	printf 'preserve me\n' >"${worktree_dir}/continuation.txt"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:00Z"
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	local claim_calls=0 transfer_calls=0

	claim_worktree_ownership() {
		claim_calls=$((claim_calls + 1))
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 preserved_status=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
	preserved_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)

	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -eq 0 && "$claim_calls" -eq 0 && "$transfer_calls" -eq 1 &&
		"$preserved_status" == *"continuation.txt"* ]]; then
		print_result "dirty same-task continuation transfers without discarding edits" 0
		return 0
	fi
	print_result "dirty same-task continuation transfers without discarding edits" 1 \
		"status=$status claim_calls=$claim_calls transfer_calls=$transfer_calls git_status=${preserved_status:-<empty>}"
	return 0
}

test_worker_worktree_continuation_transfers_ahead_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/continuation-ahead"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "continuation checkpoint"
	local expected_head=""
	expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:01Z"
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	local claim_calls=0 transfer_calls=0

	claim_worktree_ownership() {
		claim_calls=$((claim_calls + 1))
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 actual_head="" ahead_count=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
	actual_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || true)
	ahead_count=$(git -C "$worktree_dir" rev-list --count origin/main..HEAD 2>/dev/null || true)

	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -eq 0 && "$claim_calls" -eq 0 && "$transfer_calls" -eq 1 &&
		"$actual_head" == "$expected_head" && "$ahead_count" == "1" ]]; then
		print_result "ahead same-task continuation transfers without discarding commits" 0
		return 0
	fi
	print_result "ahead same-task continuation transfers without discarding commits" 1 \
		"status=$status claim_calls=$claim_calls transfer_calls=$transfer_calls head=$actual_head ahead=$ahead_count"
	return 0
}

test_worker_worktree_continuation_classifies_task_mismatch() {
	local worktree_dir="${TEST_ROOT}/continuation-task-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:02Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "99999" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "99999" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_continuation_task_mismatch" ]]; then
		print_result "same-task continuation rejects registry task mismatch precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects registry task mismatch precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_owner_mismatch() {
	local worktree_dir="${TEST_ROOT}/continuation-owner-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:03Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "competing-generation" "batch-8" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_continuation_owner_mismatch" ]]; then
		print_result "same-task continuation rejects expected-owner mismatch precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects expected-owner mismatch precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_concurrent_mutation() {
	local worktree_dir="${TEST_ROOT}/continuation-concurrent-mutation"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:04Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 1
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 1 && "$reason" == "worker_worktree_continuation_concurrent_mutation" ]]; then
		print_result "same-task continuation rejects concurrent owner mutation precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects concurrent owner mutation precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_invalid_state() {
	local worktree_dir="${TEST_ROOT}/continuation-invalid-state"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE="continuation"
	unset AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT 2>/dev/null || true

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$reason" == "worker_worktree_continuation_state_rejected" ]]; then
		print_result "same-task continuation rejects incomplete transfer state precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects incomplete transfer state precisely" 1 \
		"status=$status reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_clean_without_upstream_blocks_local_commits() {
	local worktree_dir="${TEST_ROOT}/claim-local-commits"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	git -C "$worktree_dir" config --unset branch.main.remote 2>/dev/null || true
	git -C "$worktree_dir" config --unset branch.main.merge 2>/dev/null || true
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "local-only"

	local status=0
	_hrw_worktree_clean_for_owner_reclaim "$worktree_dir" >/dev/null || status=$?

	if [[ "$status" -ne 0 ]]; then
		print_result "worker worktree clean check blocks no-upstream local commits" 0
		return 0
	fi

	print_result "worker worktree clean check blocks no-upstream local commits" 1 "status=$status"
	return 0
}

test_worker_worktree_claim_classifies_unreclaimed_live_owner() {
	local worktree_dir="${TEST_ROOT}/claim-live-owner-blocked"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "active-session" "" "99999" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() { local unregister_path="$1"; [[ -n "$unregister_path" ]] || return 1; return 0; }

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	local reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$reason" == "worker_worktree_live_owner" ]]; then
		print_result "worker worktree claim classifies unreclaimed live owner" 0
		return 0
	fi

	print_result "worker worktree claim classifies unreclaimed live owner" 1 \
		"status=$status reason=${reason:-<empty>}"
	return 0
}

test_runtime_launch_marker_precedes_invocation() {
	local marker_file="${TEST_ROOT}/runtime-launch-marker.log"
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	_hrw_mark_runtime_launch_started "issue-28060" "opencode" >"$marker_file" 2>&1
	local output=""
	output=$(<"$marker_file")

	local marker_line="" invoke_line=""
	# shellcheck disable=SC2016 # Match the literal caller variables in source.
	marker_line=$(grep -n '_hrw_mark_runtime_launch_started "$session_key" "$runtime"' "$HELPER_SCRIPT" | cut -d: -f1)
	invoke_line=$(grep -n 'claude) _invoke_claude' "$HELPER_SCRIPT" | cut -d: -f1)
	if [[ "$_WORKER_RUNTIME_LAUNCH_STARTED" -eq 1 && "$output" == *"pre_runtime_launch session=issue-28060 runtime=opencode"* &&
		"$marker_line" =~ ^[0-9]+$ && "$invoke_line" =~ ^[0-9]+$ && "$marker_line" -lt "$invoke_line" ]]; then
		print_result "runtime launch marker is emitted immediately before invocation" 0
	else
		print_result "runtime launch marker is emitted immediately before invocation" 1 \
			"started=$_WORKER_RUNTIME_LAUNCH_STARTED marker_line=$marker_line invoke_line=$invoke_line output=$output"
	fi
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	return 0
}

test_clean_prelaunch_exit_is_precise_nonzero_failure() {
	local output="" status=0
	set +e
	output=$(
		(
			print_info() { printf '%s\n' "$*"; return 0; }
			print_warning() { printf '%s\n' "$*"; return 0; }
			_push_wip_commits_on_exit() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_cleanup_headless_runtime_temp_paths() { return 0; }
			_release_dispatch_claim() { return 0; }
			_release_session_lock() { return 0; }
			_update_dispatch_ledger() { return 0; }
			_WORKER_RUNTIME_LAUNCH_STARTED=0
			_WORKER_START_EPOCH_MS=0
			AIDEVOPS_DISPATCH_LEASE_TOKEN=""
			trap "_exit_trap_handler 'issue-28060'" EXIT
			exit 0
		)
	) || status=$?
	set -e

	if [[ "$status" -eq 1 && "$output" == *"reason=worker_runtime_not_invoked"* &&
		"$output" != *"worker_noop_zero_output"* ]] &&
		_worker_failure_reason_is_launch_preflight "worker_runtime_not_invoked"; then
		print_result "clean exit before runtime invocation is a precise non-zero prelaunch failure" 0
		return 0
	fi
	print_result "clean exit before runtime invocation is a precise non-zero prelaunch failure" 1 \
		"status=$status output=$output"
	return 0
}

test_deleted_cwd_recovery_uses_worker_worktree() {
	local worktree_dir="${TEST_ROOT}/deleted-cwd-worktree"
	local stale_dir="${TEST_ROOT}/deleted-cwd-stale"
	local output=""
	local status=0
	mkdir -p "$worktree_dir" "$stale_dir"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	set +e
	output=$(
		cd "$stale_dir" || exit 20
		rmdir "$stale_dir" || exit 21
		_recover_deleted_cwd_before_launch "$TEST_ROOT" "test" 2>&1 || exit $?
		pwd -P
	)
	status=$?
	set -e

	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	if [[ "$status" -eq 0 && "$output" == *"recovered_deleted_cwd"* && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted cwd recovery cd's to worker worktree before launch" 0
		return 0
	fi

	print_result "deleted cwd recovery cd's to worker worktree before launch" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_cmd_run_aborts_issue_worker_before_canary_when_env_missing() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local canary_called=0
	_run_canary_test() { canary_called=1; return 0; }

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-22438 \
		--dir "$TEST_ROOT" \
		--title "Issue #22438: env contract" \
		--prompt "/full-loop Implement issue #22438" 2>&1) || status=$?

	unset -f _run_canary_test 2>/dev/null || true
	if [[ "$status" -ne 0 && "$canary_called" -eq 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "cmd_run aborts issue worker before canary when env missing" 0
		return 0
	fi

	print_result "cmd_run aborts issue worker before canary when env missing" 1 \
		"status=$status canary_called=$canary_called output=${output:-<empty>}"
	return 0
}

test_cmd_run_preserves_worker_origin_overrides_before_canary() {
	local worktree_dir="${TEST_ROOT}/origin-override-worktree"
	local AIDEVOPS_DISPATCH_LEASE_TOKEN=""
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER=23558
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"
	export AIDEVOPS_SESSION_ORIGIN=interactive
	export AIDEVOPS_HEADLESS=already-set

	choose_model() { printf '%s' 'openai/gpt-5.5'; return 0; }
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() {
		if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "interactive" && "${AIDEVOPS_HEADLESS:-}" == "already-set" ]]; then
			printf '%s\n' 'canary_saw_origin_overrides'
		fi
		return 1
	}

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-23558 \
		--dir "$worktree_dir" \
		--title "Issue #23558: origin overrides" \
		--prompt "/full-loop Implement issue #23558" 2>&1) || status=$?

	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH AIDEVOPS_SESSION_ORIGIN AIDEVOPS_HEADLESS 2>/dev/null || true
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test 2>/dev/null || true
	if [[ "$status" -eq 1 && "$output" == *"canary_saw_origin_overrides"* && "$output" == *"Canary failed"* ]]; then
		print_result "cmd_run preserves worker origin env overrides before canary" 0
		return 0
	fi

	print_result "cmd_run preserves worker origin env overrides before canary" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_deleted_launch_cwd_recovers_to_work_dir() {
	local stale_dir="${TEST_ROOT}/stale-cwd"
	local worktree_dir="${TEST_ROOT}/worker-worktree"
	mkdir -p "$stale_dir" "$worktree_dir"

	local output=""
	local status=0
	output=$(
		cd "$stale_dir" || exit 1
		rmdir "$stale_dir" || exit 1
		_ensure_valid_launch_cwd "$worktree_dir" || exit $?
		pwd -P
	) 2>&1 || status=$?

	if [[ "$status" -eq 0 && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted launch cwd recovers to worker worktree before runtime startup" 0
		return 0
	fi

	print_result "deleted launch cwd recovers to worker worktree before runtime startup" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_does_not_double_append() {
	local prompt='/full-loop Continue issue #14964

[HEADLESS_CONTINUATION_CONTRACT_V9]
This worker run is unattended.'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "does not double-append existing contract" 0
		return 0
	fi

	print_result "does not double-append existing contract" 1 "Existing contract was modified"
	return 0
}

test_extract_session_id_from_output_returns_latest_session_id() {
	local output_file="${TEST_ROOT}/opencode-output.jsonl"
	cat >"$output_file" <<'EOF'
not-json
{"type":"message","sessionID":"ses_early"}
{"type":"tool_use","part":{"sessionID":"ses_latest"}}
EOF

	local session_id
	session_id=$(extract_session_id_from_output "$output_file")
	if [[ "$session_id" == "ses_latest" ]]; then
		print_result "extract_session_id_from_output returns latest session id" 0
		return 0
	fi
	print_result "extract_session_id_from_output returns latest session id" 1 "Expected ses_latest, got ${session_id:-<empty>}"
	return 0
}

test_provider_sessions_scope_issue_keys_by_repo_slug() {
	local provider="openai"
	local model="openai/gpt-5.5"
	local old_repo_slug="${WORKER_REPO_SLUG:-}"
	export WORKER_REPO_SLUG="owner/one"
	store_session_id "$provider" "issue-47" "ses_one" "$model"
	export WORKER_REPO_SLUG="Owner/Two"
	store_session_id "$provider" "issue-47" "ses_two" "$model"

	local first_session="" second_session="" unscoped_count=""
	export WORKER_REPO_SLUG="owner/one"
	first_session=$(get_session_id "$provider" "issue-47")
	export WORKER_REPO_SLUG="owner/two"
	second_session=$(get_session_id "$provider" "issue-47")
	unscoped_count=$(db_query "SELECT count(*) FROM provider_sessions WHERE provider = 'openai' AND session_key = 'issue-47';")
	if [[ -n "$old_repo_slug" ]]; then
		export WORKER_REPO_SLUG="$old_repo_slug"
	else
		unset WORKER_REPO_SLUG
	fi

	if [[ "$first_session" == "ses_one" && "$second_session" == "ses_two" && "$unscoped_count" == "0" ]]; then
		print_result "provider_sessions scope issue keys by repo slug" 0
		return 0
	fi

	print_result "provider_sessions scope issue keys by repo slug" 1 \
		"first=${first_session:-<empty>} second=${second_session:-<empty>} unscoped_count=${unscoped_count:-<empty>}"
	return 0
}

test_provider_sessions_keep_pulse_unscoped() {
	local provider="openai"
	local model="openai/gpt-5.5"
	local old_repo_slug="${WORKER_REPO_SLUG:-}"
	export WORKER_REPO_SLUG="owner/one"
	store_session_id "$provider" "pulse" "ses_pulse" "$model"
	local pulse_session="" pulse_count=""
	pulse_session=$(get_session_id "$provider" "pulse")
	pulse_count=$(db_query "SELECT count(*) FROM provider_sessions WHERE provider = 'openai' AND session_key = 'pulse';")
	if [[ -n "$old_repo_slug" ]]; then
		export WORKER_REPO_SLUG="$old_repo_slug"
	else
		unset WORKER_REPO_SLUG
	fi

	if [[ "$pulse_session" == "ses_pulse" && "$pulse_count" == "1" ]]; then
		print_result "provider_sessions keep pulse sessions unscoped" 0
		return 0
	fi

	print_result "provider_sessions keep pulse sessions unscoped" 1 \
		"pulse=${pulse_session:-<empty>} count=${pulse_count:-<empty>}"
	return 0
}

test_blocked_completion_records_blocked_label() {
	local output_file="${TEST_ROOT}/blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing dependency credentials"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 0 && "${_run_result_label:-}" == "blocked" && "${_run_failure_reason:-}" == "blocked" && "${_run_classification_source:-}" == "model_blocked_signal" ]] && { print_result "BLOCKED terminal signal records blocked label" 0; return 0; }
	print_result "BLOCKED terminal signal records blocked label" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} source=${_run_classification_source:-<unset>}"
	return 0
}

test_post_pr_handoff_completion_signal_is_exact() {
	local exact_file="${TEST_ROOT}/post-pr-handoff-exact.jsonl"
	local prose_file="${TEST_ROOT}/post-pr-handoff-prose.jsonl"
	printf '%s\n' '{"type":"text","text":"POST_PR_HANDOFF"}' >"$exact_file"
	printf '%s\n' '{"type":"text","text":"I will mention POST_PR_HANDOFF after more work."}' >"$prose_file"

	local result=0
	output_has_post_pr_handoff_signal "$exact_file" || result=1
	output_has_completion_signal "$exact_file" || result=1
	if output_has_post_pr_handoff_signal "$prose_file" || output_has_completion_signal "$prose_file"; then
		result=1
	fi
	print_result "POST_PR_HANDOFF is accepted only as an exact model-text line" "$result"
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
	[[ "$rc" -eq 82 && "${_run_result_label:-}" == "brief_recovery" && "${_run_failure_reason:-}" == "missing_implementation_context" && "${_run_classification_pattern:-}" == "missing_implementation_context" ]] && { print_result "missing-context BLOCKED requests brief recovery" 0; return 0; }
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
	_handle_run_result 1 "$auth_refresh_output_file" "worker" "anthropic" "issue-23037" "anthropic/claude-sonnet-4-6" || status=$?

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
	if [[ "$captured" == *$'service_interruption_exhausted\n81\nlocal_error\n1\n0\n24099\nowner/repo\n'* ]] && \
		[[ "$captured" == *$'excerpt.log\nses_context\n'* ]] && \
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
		bash -c 'source "$1" help >/dev/null 2>&1; _run_canary_test "anthropic/claude-sonnet-4-6"' _ "$HELPER_SCRIPT"
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

test_worker_opencode_exec_paths_strip_session_env() {
	if grep -Fq "run_without_opencode_session_env \"\$SANDBOX_EXEC_HELPER\" run" "$HELPER_SCRIPT" &&
		grep -Fq "run_without_opencode_session_env timeout \"\$HEADLESS_SANDBOX_TIMEOUT_DEFAULT\"" "$HELPER_SCRIPT"; then
		print_result "worker OpenCode exec paths strip session env" 0
		return 0
	fi

	print_result "worker OpenCode exec paths strip session env" 1 \
		"Expected sandbox and bare-timeout OpenCode exec paths to use run_without_opencode_session_env"
	return 0
}

test_worker_opencode_invocation_seeds_continuation_session() {
	if grep -Fq "_seed_worker_db_session_context \"\$isolated_data_dir\" \"\$_invoke_persisted_session\"" "$HELPER_SCRIPT" &&
		grep -Fq "[lifecycle] db_seeded session=\$_invoke_persisted_session" "$HELPER_SCRIPT"; then
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

	if [[ "$csv" == *"OPENAI_API_KEY"* ]] &&
		[[ "$csv" != *"ANTHROPIC_API_KEY"* ]] &&
		[[ "$csv" != *"GOOGLE_API_KEY"* ]] &&
		[[ "$csv" == *"OPENCODE_BIN"* ]] &&
		[[ "$csv" == *"OPENCODE_DB"* ]] &&
		[[ "$csv" != *"AIDEVOPS_OPENCODE_SESSION_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_SESSION_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PID"* ]] &&
		[[ "$csv" != *"OPENCODE_RUN_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PROCESS_ROLE"* ]] &&
		[[ "$csv" != *"OPENCODE_SERVER_PASSWORD"* ]] &&
		[[ ",$csv," != *",OPENCODE,"* ]]; then
		print_result "sandbox passthrough scopes env to selected provider" 0
		return 0
	fi

	print_result "sandbox passthrough scopes env to selected provider" 1 \
		"Expected OpenAI env only, got: ${csv}"
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

	if [[ "$item_count" -eq 4 && ",${csv}," == *",XDG_CACHE_HOME,"* && \
		",${csv}," == *",XDG_CONFIG_HOME,"* && ",${csv}," == *",XDG_DATA_HOME,"* && \
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

create_complete_opencode_test_schema() {
	local db_path="$1"
	sqlite3 "$db_path" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE project_directory (project_id TEXT NOT NULL, directory TEXT NOT NULL, PRIMARY KEY(project_id, directory));
CREATE TABLE permission (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE workspace (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE todo (session_id TEXT NOT NULL, position INTEGER NOT NULL, content TEXT NOT NULL, PRIMARY KEY(session_id, position));
CREATE TABLE session_share (session_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE session_context_epoch (session_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE session_input (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE event_sequence (aggregate_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE event (id TEXT PRIMARY KEY, aggregate_id TEXT NOT NULL, seq INTEGER NOT NULL, data TEXT NOT NULL);
SQL
	return 0
}

test_seed_worker_db_session_context_copies_only_selected_session() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-data"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep-1', 'session-keep', 'one');
INSERT INTO message VALUES ('message-keep-2', 'session-keep', 'two');
INSERT INTO message VALUES ('message-other', 'session-other', 'other');
SQL
	sqlite3 "$shared_db" .schema | sqlite3 "$worker_db"

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local sessions messages other_sessions other_messages projects
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")
	other_sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-other';")
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-keep';")

	if [[ "$sessions" == "1" && "$messages" == "2" && "$other_sessions" == "0" && "$other_messages" == "0" && "$projects" == "1" ]]; then
		print_result "seed worker DB copies only selected continuation session" 0
		return 0
	fi

	print_result "seed worker DB copies only selected continuation session" 1 \
		"sessions=$sessions messages=$messages other_sessions=$other_sessions other_messages=$other_messages projects=$projects"
	return 0
}

test_seed_worker_db_session_context_rebinds_replacement_worktree() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-rebound"
	local replacement_dir="${TEST_ROOT}/replacement-worktree"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local stale_dir="${TEST_ROOT}/removed-worktree"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode" "$replacement_dir"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<SQL
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '${stale_dir}', 'Keep');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep" "$replacement_dir"

	local worker_directory="" shared_directory="" expected_replacement=""
	expected_replacement=$(cd "$replacement_dir" && pwd -P)
	worker_directory=$(sqlite3 "$worker_db" "SELECT directory FROM session WHERE id = 'session-keep';")
	shared_directory=$(sqlite3 "$shared_db" "SELECT directory FROM session WHERE id = 'session-keep';")
	if [[ "$worker_directory" == "$expected_replacement" && "$shared_directory" == "$stale_dir" ]]; then
		print_result "seed worker DB rebinds stale session to replacement worktree only in isolation" 0
		return 0
	fi

	print_result "seed worker DB rebinds stale session to replacement worktree only in isolation" 1 \
		"worker_directory=$worker_directory shared_directory=$shared_directory"
	return 0
}

test_seed_worker_db_session_context_copies_migration_metadata() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-metadata"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v16-ready', 1700000000);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local schema_migrations data_migrations migration_rows sessions messages
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	data_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM data_migration WHERE id = 'data-ready';")
	migration_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM migration WHERE id = 'opencode-v16-ready';")
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")

	if [[ "$schema_migrations" == "1" && "$data_migrations" == "1" && "$migration_rows" == "1" && "$sessions" == "1" && "$messages" == "1" ]]; then
		print_result "seed worker DB copies migration metadata for continuation" 0
		return 0
	fi

	print_result "seed worker DB copies migration metadata for continuation" 1 \
		"schema_migrations=$schema_migrations data_migrations=$data_migrations migration_rows=$migration_rows sessions=$sessions messages=$messages"
	return 0
}

test_seed_worker_db_session_context_uses_schema_only_fresh_db() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-backup-seed"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
PRAGMA user_version = 42;
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v17-ready', 1700000000);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
INSERT INTO message VALUES ('message-other', 'session-other', 'other');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local user_version schema_migrations sessions other_sessions messages other_messages projects other_projects
	local seed_definition initialize_definition
	user_version=$(sqlite3 "$worker_db" "PRAGMA user_version;")
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	other_sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-other';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-keep';")
	other_projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-other';")
	seed_definition=$(declare -f _seed_worker_db_session_context)
	initialize_definition=$(declare -f _initialize_worker_db_from_shared_schema)

	if [[ "$user_version" == "42" && "$schema_migrations" == "1" && "$sessions" == "1" && "$other_sessions" == "0" && "$messages" == "1" && "$other_messages" == "0" && "$projects" == "1" && "$other_projects" == "0" && "$seed_definition" != *".backup"* && "$initialize_definition" == *'".schema"'* ]]; then
		print_result "seed worker DB uses shared schema for fresh continuation DB" 0
		return 0
	fi

	print_result "seed worker DB uses shared schema for fresh continuation DB" 1 \
		"user_version=$user_version schema_migrations=$schema_migrations sessions=$sessions other_sessions=$other_sessions messages=$messages other_messages=$other_messages projects=$projects other_projects=$other_projects"
	return 0
}

test_seed_worker_db_session_context_vacuums_pruned_backup() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-vacuum-seed"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data BLOB NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', zeroblob(1024));
INSERT INTO message VALUES ('message-other', 'session-other', zeroblob(1048576));
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local other_messages freelist_count
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	freelist_count=$(sqlite3 "$worker_db" "PRAGMA freelist_count;")

	if [[ "$other_messages" == "0" && "$freelist_count" == "0" ]]; then
		print_result "seed worker DB vacuums pruned backup pages" 0
		return 0
	fi

	print_result "seed worker DB vacuums pruned backup pages" 1 \
		"other_messages=$other_messages freelist_count=$freelist_count"
	return 0
}

test_seed_worker_db_session_context_copies_complete_graph() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-complete-graph"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"

	sqlite3 "$shared_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Keep Project'), ('project-other', 'Other Project');
INSERT INTO project_directory VALUES ('project-keep', '/keep'), ('project-other', '/other');
INSERT INTO permission VALUES ('permission-keep', 'project-keep', 'keep'), ('permission-other', 'project-other', 'other');
INSERT INTO workspace VALUES ('workspace-keep', 'project-keep', 'keep'), ('workspace-other', 'project-other', 'other');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/keep', 'Keep'), ('session-other', 'project-other', '/other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'keep'), ('message-other', 'session-other', 'other');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'keep'), ('part-other', 'message-other', 'session-other', 'other');
INSERT INTO todo VALUES ('session-keep', 0, 'keep'), ('session-other', 0, 'other');
INSERT INTO session_share VALUES ('session-keep', 'keep'), ('session-other', 'other');
INSERT INTO session_context_epoch VALUES ('session-keep', 'keep'), ('session-other', 'other');
INSERT INTO session_input VALUES ('input-keep', 'session-keep', 'keep'), ('input-other', 'session-other', 'other');
INSERT INTO session_message VALUES ('projection-keep', 'session-keep', 'keep'), ('projection-other', 'session-other', 'other');
INSERT INTO event_sequence VALUES ('session-keep', 1), ('session-other', 1);
INSERT INTO event VALUES ('event-keep', 'session-keep', 1, 'keep'), ('event-other', 'session-other', 1, zeroblob(1048576));
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local session_graph_count project_graph_count unrelated_count event_count
	session_graph_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM message) + (SELECT COUNT(*) FROM part) + (SELECT COUNT(*) FROM todo) + (SELECT COUNT(*) FROM session_share) + (SELECT COUNT(*) FROM session_context_epoch) + (SELECT COUNT(*) FROM session_input) + (SELECT COUNT(*) FROM session_message);")
	project_graph_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM project_directory) + (SELECT COUNT(*) FROM permission) + (SELECT COUNT(*) FROM workspace);")
	unrelated_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM session WHERE id = 'session-other') + (SELECT COUNT(*) FROM message WHERE session_id = 'session-other') + (SELECT COUNT(*) FROM part WHERE session_id = 'session-other') + (SELECT COUNT(*) FROM event WHERE aggregate_id = 'session-other');")
	event_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM event_sequence WHERE aggregate_id = 'session-keep') + (SELECT COUNT(*) FROM event WHERE aggregate_id = 'session-keep');")

	if [[ "$session_graph_count" == "7" && "$project_graph_count" == "3" && "$unrelated_count" == "0" && "$event_count" == "2" ]]; then
		print_result "seed worker DB copies complete selected session graph only" 0
		return 0
	fi

	print_result "seed worker DB copies complete selected session graph only" 1 \
		"session_graph=$session_graph_count project_graph=$project_graph_count unrelated=$unrelated_count events=$event_count"
	return 0
}

test_merge_worker_db_replaces_complete_session_graph_atomically() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-complete-graph"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"
	create_complete_opencode_test_schema "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Shared Project'), ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/old', 'Old'), ('session-other', 'project-other', '/other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'old'), ('message-other', 'session-other', 'other');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'old'), ('part-other', 'message-other', 'session-other', 'other');
INSERT INTO todo VALUES ('session-keep', 0, 'removed-by-worker');
INSERT INTO event_sequence VALUES ('session-keep', 1), ('session-other', 1);
INSERT INTO event VALUES ('event-keep', 'session-keep', 1, 'old'), ('event-other', 'session-other', 1, 'other');
SQL
	sqlite3 "$worker_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Worker Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/new', 'New');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'new');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'new');
INSERT INTO session_context_epoch VALUES ('session-keep', 'new');
INSERT INTO session_input VALUES ('input-keep', 'session-keep', 'new');
INSERT INTO session_message VALUES ('projection-keep', 'session-keep', 'new');
INSERT INTO event_sequence VALUES ('session-keep', 2);
INSERT INTO event VALUES ('event-keep', 'session-keep', 2, 'new');
SQL

	local merge_status=0
	_merge_worker_db "$isolated_dir" || merge_status=$?

	local merged_values unrelated_values
	merged_values=$(sqlite3 "$shared_db" "SELECT title || '|' || directory FROM session WHERE id = 'session-keep'; SELECT data FROM message WHERE id = 'message-keep'; SELECT data FROM part WHERE id = 'part-keep'; SELECT COUNT(*) FROM todo WHERE session_id = 'session-keep'; SELECT data FROM session_context_epoch WHERE session_id = 'session-keep'; SELECT seq || '|' || data FROM event WHERE id = 'event-keep';")
	unrelated_values=$(sqlite3 "$shared_db" "SELECT data FROM message WHERE id = 'message-other'; SELECT data FROM part WHERE id = 'part-other'; SELECT data FROM event WHERE id = 'event-other';")

	if [[ "$merge_status" -eq 0 && "$merged_values" == $'New|/new\nnew\nnew\n0\nnew\n2|new' && "$unrelated_values" == $'other\nother\nother' ]]; then
		print_result "merge worker DB atomically replaces complete session graph" 0
		return 0
	fi

	print_result "merge worker DB atomically replaces complete session graph" 1 \
		"status=$merge_status merged=$merged_values unrelated=$unrelated_values"
	return 0
}

test_merge_worker_db_maps_columns_by_name() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-column-order"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL, note TEXT DEFAULT 'shared-default');
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL, title TEXT NOT NULL, optional_value TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL, optional_value TEXT);
INSERT INTO project VALUES ('project-keep', 'Shared', 'old');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'shared-slug', 'Old', NULL);
INSERT INTO message VALUES ('message-keep', 'session-keep', 'old', NULL);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (name TEXT NOT NULL, id TEXT PRIMARY KEY);
CREATE TABLE session (title TEXT NOT NULL, slug TEXT NOT NULL, id TEXT PRIMARY KEY, project_id TEXT NOT NULL);
CREATE TABLE message (data TEXT NOT NULL, session_id TEXT NOT NULL, id TEXT PRIMARY KEY);
INSERT INTO project VALUES ('Worker', 'project-keep');
INSERT INTO session VALUES ('New', 'worker-slug', 'session-keep', 'project-keep');
INSERT INTO message VALUES ('new', 'session-keep', 'message-keep');
SQL

	local merge_status=0 merged_values=""
	_merge_worker_db "$isolated_dir" || merge_status=$?
	merged_values=$(sqlite3 "$shared_db" "SELECT slug || '|' || title || '|' || COALESCE(optional_value, 'null') FROM session WHERE id = 'session-keep'; SELECT data || '|' || COALESCE(optional_value, 'null') FROM message WHERE id = 'message-keep';")
	if [[ "$merge_status" -eq 0 && "$merged_values" == $'worker-slug|New|null\nnew|null' ]]; then
		print_result "merge worker DB maps reordered and additive columns by name" 0
		return 0
	fi
	print_result "merge worker DB maps reordered and additive columns by name" 1 \
		"status=$merge_status merged=$merged_values"
	return 0
}

test_merge_worker_db_rejects_missing_required_destination_column() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-missing-required"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" "CREATE TABLE project (id TEXT PRIMARY KEY); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL); INSERT INTO project VALUES ('project-keep'); INSERT INTO session VALUES ('session-keep', 'project-keep', 'original');"
	sqlite3 "$worker_db" "CREATE TABLE project (id TEXT PRIMARY KEY); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL); INSERT INTO project VALUES ('project-keep'); INSERT INTO session VALUES ('session-keep', 'project-keep');"

	local merge_status=0 shared_slug=""
	_merge_worker_db "$isolated_dir" || merge_status=$?
	shared_slug=$(sqlite3 "$shared_db" "SELECT slug FROM session WHERE id = 'session-keep';")
	if [[ "$merge_status" -ne 0 && "$shared_slug" == "original" ]]; then
		print_result "merge worker DB rejects missing required destination columns" 0
		return 0
	fi
	print_result "merge worker DB rejects missing required destination columns" 1 \
		"status=$merge_status shared_slug=$shared_slug"
	return 0
}

test_merge_worker_db_failure_preserves_recovery_db_without_auth() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-failure"
	local recovery_root="${TEST_ROOT}/worker-db-recovery"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"
	create_complete_opencode_test_schema "$worker_db"
	sqlite3 "$shared_db" "INSERT INTO project VALUES ('project-keep', 'Shared'); INSERT INTO session VALUES ('session-keep', 'project-keep', '/old', 'Old');"
	sqlite3 "$worker_db" "CREATE TABLE worker_only (id TEXT PRIMARY KEY, session_id TEXT NOT NULL); INSERT INTO project VALUES ('project-keep', 'Worker'); INSERT INTO session VALUES ('session-keep', 'project-keep', '/new', 'New');"
	printf '%s' 'test-auth-must-not-be-preserved' >"${isolated_dir}/opencode/auth.json"

	local merge_status=0
	_merge_worker_db "$isolated_dir" || merge_status=$?
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _preserve_failed_worker_db "$isolated_dir"

	local recovered_db="" recovery_auth_count=0 shared_title candidate
	for candidate in "$recovery_root"/*/opencode.db; do
		[[ -f "$candidate" ]] || continue
		recovered_db="$candidate"
		break
	done
	if compgen -G "${recovery_root}/*/auth.json" >/dev/null; then
		recovery_auth_count=1
	fi
	shared_title=$(sqlite3 "$shared_db" "SELECT title FROM session WHERE id = 'session-keep';")
	if [[ "$merge_status" -ne 0 && -f "$recovered_db" && "$recovery_auth_count" == "0" && -f "${isolated_dir}/opencode/auth.json" && "$shared_title" == "Old" ]]; then
		print_result "failed merge rolls back and preserves DB without worker auth" 0
		return 0
	fi

	print_result "failed merge rolls back and preserves DB without worker auth" 1 \
		"status=$merge_status recovered=${recovered_db:-none} recovery_auth=$recovery_auth_count shared_title=$shared_title"
	return 0
}

test_replay_preserved_worker_db_verifies_before_deletion() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/replay-opencode-worker"
	local recovery_root="${TEST_ROOT}/replay-worker-db-recovery"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" "CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL, title TEXT NOT NULL); CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL); INSERT INTO project VALUES ('project-replay', 'Shared'); INSERT INTO session VALUES ('session-replay', 'project-replay', 'old-slug', 'Old');"
	sqlite3 "$worker_db" "CREATE TABLE project (name TEXT, id TEXT PRIMARY KEY); CREATE TABLE session (title TEXT NOT NULL, slug TEXT NOT NULL, project_id TEXT NOT NULL, id TEXT PRIMARY KEY); CREATE TABLE message (data TEXT NOT NULL, id TEXT PRIMARY KEY, session_id TEXT NOT NULL); INSERT INTO project VALUES ('Worker', 'project-replay'); INSERT INTO session VALUES ('Recovered', 'new-slug', 'project-replay', 'session-replay'); INSERT INTO message VALUES ('recovered-child', 'message-replay', 'session-replay');"
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _preserve_failed_worker_db "$isolated_dir"

	local first_status=0 second_status=0 merged_values="" artifact_count=0
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _replay_preserved_worker_dbs || first_status=$?
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _replay_preserved_worker_dbs || second_status=$?
	merged_values=$(sqlite3 "$shared_db" "SELECT slug || '|' || title FROM session WHERE id = 'session-replay'; SELECT data FROM message WHERE session_id = 'session-replay';")
	for worker_db in "$recovery_root"/*/opencode.db; do
		[[ -f "$worker_db" ]] && artifact_count=$((artifact_count + 1))
	done
	if [[ "$first_status" -eq 0 && "$second_status" -eq 0 && "$merged_values" == $'new-slug|Recovered\nrecovered-child' && "$artifact_count" -eq 0 ]]; then
		print_result "recovery replay verifies graph, deletes artifact, and is idempotent" 0
		return 0
	fi
	print_result "recovery replay verifies graph, deletes artifact, and is idempotent" 1 \
		"first=$first_status second=$second_status merged=$merged_values artifacts=$artifact_count"
	return 0
}

test_worker_db_replay_lock_recovers_stale_owner_and_waits_for_pid() {
	local recovery_root="${TEST_ROOT}/replay-lock-recovery"
	local replay_lock="${recovery_root}/.replay.lock"
	local stale_status=0 live_status=0 race_status=0
	local acquired_pid="" observed_pid="" race_pid=""
	local lock_holder_pid="" pid_writer_pid=""

	mkdir -p "$replay_lock"
	printf '%s\n' '99999999' >"${replay_lock}/pid"
	_acquire_worker_db_replay_lock "$replay_lock" || stale_status=$?
	acquired_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	_release_worker_db_replay_lock "$replay_lock"

	mkdir -p "$replay_lock"
	command sleep 5 &
	lock_holder_pid=$!
	(
		command sleep 0.2
		printf '%s\n' "$lock_holder_pid" >"${replay_lock}/pid"
	) &
	pid_writer_pid=$!
	_acquire_worker_db_replay_lock "$replay_lock" || live_status=$?
	wait "$pid_writer_pid" 2>/dev/null || true
	observed_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	kill "$lock_holder_pid" 2>/dev/null || true
	wait "$lock_holder_pid" 2>/dev/null || true
	rm -rf "$replay_lock"

	mkdir -p "$replay_lock"
	printf '%s\n' '99999999' >"${replay_lock}/pid"
	mkdir() {
		local mkdir_target="$1"
		if [[ "$mkdir_target" == "${replay_lock}/.reclaim" ]]; then
			command rm -rf "$replay_lock"
			return 1
		fi
		command mkdir "$@"
		return $?
	}
	_acquire_worker_db_replay_lock "$replay_lock" || race_status=$?
	unset -f mkdir
	race_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	_release_worker_db_replay_lock "$replay_lock"

	if [[ "$stale_status" -eq 0 && "$acquired_pid" == "$$" && "$live_status" -eq 1 && "$observed_pid" == "$lock_holder_pid" && "$race_status" -eq 0 && "$race_pid" == "$$" ]]; then
		print_result "worker DB replay lock reclaims stale owners, waits for PIDs, and retries owner release races" 0
		return 0
	fi
	print_result "worker DB replay lock reclaims stale owners, waits for PIDs, and retries owner release races" 1 \
		"stale_status=$stale_status acquired=$acquired_pid live_status=$live_status observed=$observed_pid holder=$lock_holder_pid race_status=$race_status race_pid=$race_pid"
	return 0
}

test_sync_worker_db_migration_metadata_repairs_prewarmed_project_table() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-prewarm"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v16-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local schema_migrations data_migrations migration_rows projects
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	data_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM data_migration WHERE id = 'data-ready';")
	migration_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM migration WHERE id = 'opencode-v16-ready';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'prewarmed-project';")

	if [[ "$schema_migrations" == "1" && "$data_migrations" == "1" && "$migration_rows" == "1" && "$projects" == "1" ]]; then
		print_result "sync worker DB migration metadata repairs prewarmed project table" 0
		return 0
	fi

	print_result "sync worker DB migration metadata repairs prewarmed project table" 1 \
		"schema_migrations=$schema_migrations data_migrations=$data_migrations migration_rows=$migration_rows projects=$projects"
	return 0
}

test_sync_worker_db_migration_metadata_replaces_stale_ledgers() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-stale-ledger"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
INSERT INTO data_migration VALUES ('shared-data-ready', 67890);
INSERT INTO migration VALUES ('shared-opencode-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'stale-schema-row', 11111);
INSERT INTO data_migration VALUES ('shared-data-ready', 22222);
INSERT INTO migration VALUES ('shared-opencode-ready', 33333);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local schema_hash data_updated_at migration_completed projects
	schema_hash=$(sqlite3 "$worker_db" "SELECT hash FROM __drizzle_migrations WHERE id = 1;")
	data_updated_at=$(sqlite3 "$worker_db" "SELECT updated_at FROM data_migration WHERE id = 'shared-data-ready';")
	migration_completed=$(sqlite3 "$worker_db" "SELECT time_completed FROM migration WHERE id = 'shared-opencode-ready';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'prewarmed-project';")

	if [[ "$schema_hash" == "shared-schema-ready" && "$data_updated_at" == "67890" && "$migration_completed" == "1700000000" && "$projects" == "1" ]]; then
		print_result "sync worker DB replaces stale migration ledger rows" 0
		return 0
	fi

	print_result "sync worker DB replaces stale migration ledger rows" 1 \
		"schema_hash=$schema_hash data_updated_at=$data_updated_at migration_completed=$migration_completed projects=$projects"
	return 0
}

test_copy_worker_db_migration_ledger_preserves_rows_when_attach_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-attach-failure"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local sqlite_wrapper
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'stale-schema-row', 11111);
SQL

	sqlite_wrapper=$(declare -f sqlite3_with_timeout | sed '1s/sqlite3_with_timeout/sqlite3_with_timeout_original_for_test/')
	eval "$sqlite_wrapper"
	sqlite3_with_timeout() {
		local db_path="${1:-}"
		local line
		local sql_input

		if [[ "$db_path" == "$worker_db" && "$#" -eq 1 ]]; then
			sql_input=""
			while IFS= read -r line; do
				sql_input+="${line}"$'\n'
			done
			if [[ "$sql_input" == *"ATTACH DATABASE"* ]]; then
				return 1
			fi
			printf '%s\n' "$sql_input" | sqlite3_with_timeout_original_for_test "$db_path"
			return $?
		fi

		sqlite3_with_timeout_original_for_test "$@"
		return $?
	}

	_copy_worker_db_migration_ledger_table "$worker_db" "$shared_db" "__drizzle_migrations" >/dev/null 2>&1 || true

	eval "$(declare -f sqlite3_with_timeout_original_for_test | sed '1s/sqlite3_with_timeout_original_for_test/sqlite3_with_timeout/')"
	unset -f sqlite3_with_timeout_original_for_test

	local schema_hash
	schema_hash=$(sqlite3 "$worker_db" "SELECT hash FROM __drizzle_migrations WHERE id = 1;")
	if [[ "$schema_hash" == "stale-schema-row" ]]; then
		print_result "copy worker DB migration ledger preserves rows when attach fails" 0
		return 0
	fi

	print_result "copy worker DB migration ledger preserves rows when attach fails" 1 "schema_hash=$schema_hash"
	return 0
}

test_copy_worker_db_migration_ledger_stops_when_schema_query_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-schema-query-failure"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local sqlite_wrapper
	local create_attempts=0
	local rc=0
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
SQL

	sqlite_wrapper=$(declare -f sqlite3_with_timeout | sed '1s/sqlite3_with_timeout/sqlite3_with_timeout_original_for_test/')
	eval "$sqlite_wrapper"
	sqlite3_with_timeout() {
		local db_path="${1:-}"
		local sql_arg="${2:-}"
		local line

		if [[ "$db_path" == "$shared_db" && "$sql_arg" == ".schema __drizzle_migrations" ]]; then
			return 1
		fi
		if [[ "$db_path" == "$worker_db" && "$#" -eq 1 ]]; then
			create_attempts=$((create_attempts + 1))
			while IFS= read -r line; do
				:
			done
			return 0
		fi

		sqlite3_with_timeout_original_for_test "$@"
		return $?
	}

	_copy_worker_db_migration_ledger_table "$worker_db" "$shared_db" "__drizzle_migrations" >/dev/null 2>&1 || rc=$?

	eval "$(declare -f sqlite3_with_timeout_original_for_test | sed '1s/sqlite3_with_timeout_original_for_test/sqlite3_with_timeout/')"
	unset -f sqlite3_with_timeout_original_for_test

	if [[ "$rc" == "1" && "$create_attempts" == "0" ]]; then
		print_result "copy worker DB migration ledger stops when schema query fails" 0
		return 0
	fi

	print_result "copy worker DB migration ledger stops when schema query fails" 1 "rc=$rc create_attempts=$create_attempts"
	return 0
}

test_sync_worker_db_migration_metadata_archives_unrepairable_project_table() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-unrepairable"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local backup_count=0 backup_file
	for backup_file in "${isolated_dir}"/opencode/opencode.db.incomplete-migration-ledgers.*.bak; do
		[[ -f "$backup_file" ]] || continue
		backup_count=$((backup_count + 1))
	done
	if [[ ! -f "$worker_db" && "$backup_count" == "1" ]]; then
		print_result "sync worker DB archives unrepairable prewarmed project table" 0
		return 0
	fi

	print_result "sync worker DB archives unrepairable prewarmed project table" 1 \
		"Expected worker DB archived once, file_exists=$([[ -f "$worker_db" ]] && printf yes || printf no) backups=${backup_count}"
	return 0
}

test_sync_worker_db_migration_metadata_preserves_worker_db_when_shared_query_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-shared-query-fails"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	printf '%s\n' 'not a sqlite database' >"$shared_db"
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local backup_count=0 backup_file
	for backup_file in "${isolated_dir}"/opencode/opencode.db.incomplete-migration-ledgers.*.bak; do
		[[ -f "$backup_file" ]] || continue
		backup_count=$((backup_count + 1))
	done
	if [[ -f "$worker_db" && "$backup_count" == "0" ]]; then
		print_result "sync worker DB preserves prewarmed DB when shared query fails" 0
		return 0
	fi

	print_result "sync worker DB preserves prewarmed DB when shared query fails" 1 \
		"Expected worker DB preserved, file_exists=$([[ -f "$worker_db" ]] && printf yes || printf no) backups=${backup_count}"
	return 0
}

test_sync_worker_db_migration_metadata_repeated_launch_reaches_seed() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-repeat"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local attempts=0 failures=0 launch_output=""
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (name TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v17-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	while [[ "$attempts" -lt 2 ]]; do
		attempts=$((attempts + 1))
		_sync_worker_db_migration_metadata "$isolated_dir"
		if ! _worker_db_migration_ledgers_match_shared "$worker_db" "$shared_db"; then
			failures=$((failures + 1))
			launch_output="${launch_output}SQLiteError: table project already exists\n"
			continue
		fi
		launch_output="${launch_output}SEED_PROMPT_REACHED attempt=${attempts}\n"
	done

	if [[ "$attempts" -eq 2 && "$failures" -eq 0 && "$launch_output" == *"SEED_PROMPT_REACHED attempt=1"* && "$launch_output" == *"SEED_PROMPT_REACHED attempt=2"* ]]; then
		print_result "sync worker DB lets repeated prewarmed launches reach seed prompt" 0
		return 0
	fi

	print_result "sync worker DB lets repeated prewarmed launches reach seed prompt" 1 \
		"attempts=${attempts} failures=${failures} output=${launch_output}"
	return 0
}

test_opencode_project_table_migration_replay_detected() {
	local output_file="${TEST_ROOT}/opencode-project-replay.log"
	local project_table_error="table \`project\` already exists"
	printf '%s\n' 'Error: Unexpected error' "$project_table_error" >"$output_file"

	if _opencode_project_table_migration_replay_detected 1 "$output_file" && \
		! _opencode_project_table_migration_replay_detected 0 "$output_file"; then
		print_result "detects OpenCode project table migration replay startup failure" 0
		return 0
	fi

	print_result "detects OpenCode project table migration replay startup failure" 1 \
		"Expected non-zero exit with project table replay output to be detected only on failure"
	return 0
}

test_large_opencode_prompt_uses_file_attachment() {
	local prompt="large-seed-prompt-with-worker-contract"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "opencode" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_run_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "" "" "" --file "$prompt_file")
	)

	if [[ "$prompt_arg" != *"$prompt"* ]] &&
		[[ -f "$prompt_file" ]] &&
		[[ "$(<"$prompt_file")" == "$prompt" ]] &&
		[[ "$cmd_text" == *"<--file><${prompt_file}>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "large opencode prompts use file attachment instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "large opencode prompts use file attachment instead of argv" 1 \
		"prompt_arg=${prompt_arg} prompt_file=${prompt_file} cmd=${cmd_text}"
	return 0
}

test_large_claude_prompt_uses_stdin_file() {
	local prompt="large-claude-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "claude" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local stdin_file="$_HEADLESS_CLAUDE_STDIN_FILE"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_claude_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "")
	)

	if [[ -z "$prompt_arg" ]] &&
		[[ -f "$stdin_file" ]] &&
		[[ "$(<"$stdin_file")" == "$prompt" ]] &&
		[[ "$cmd_text" == "<claude><-p>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "large claude prompts use stdin file instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "large claude prompts use stdin file instead of argv" 1 \
		"prompt_arg=${prompt_arg} stdin_file=${stdin_file} cmd=${cmd_text}"
	return 0
}

test_registered_prompt_temp_cleanup_removes_dir() {
	local prompt="cleanup-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=1

	_prepare_runtime_prompt_transport "opencode" "$prompt"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local prompt_dir="${prompt_file%/*}"
	_cleanup_headless_runtime_temp_paths

	if [[ -n "$prompt_dir" && ! -e "$prompt_dir" ]]; then
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "registered prompt temp cleanup removes prompt dir" 0
		return 0
	fi

	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "registered prompt temp cleanup removes prompt dir" 1 \
		"Prompt temp dir still exists: ${prompt_dir:-<empty>}"
	return 0
}

test_launch_helpers_tolerate_unset_state() {
	if (
		unset _HEADLESS_RUNTIME_TEMP_PATHS session_key work_dir title prompt prompt_file
		_cleanup_headless_runtime_temp_paths &&
			! _validate_run_args >/dev/null 2>&1
	); then
		print_result "launch helpers tolerate unset state under nounset" 0
		return 0
	fi

	print_result "launch helpers tolerate unset state under nounset" 1 \
		"Expected cleanup to succeed and validation to report missing arguments"
	return 0
}

# Helper: create a bare git repo and a feature branch with optional commits.
# Each call uses work_dir-derived remote path to avoid inter-test collisions.
# Args: $1 = work_dir path, $2 = 1 to add a commit (0 for none)
_setup_test_git_repo() {
	local work_dir="$1"
	local add_commit="${2:-0}"
	mkdir -p "$work_dir"
	git -C "$work_dir" init -q
	git -C "$work_dir" config user.email "test@test.local"
	git -C "$work_dir" config user.name "Test"
	# Create initial commit on main so origin/main reference exists
	touch "$work_dir/README.md"
	git -C "$work_dir" add README.md
	git -C "$work_dir" commit -q -m "init"
	git -C "$work_dir" branch -M main
	# Create remote stub unique to this repo (bare repo alongside work_dir)
	local remote_dir="${work_dir}.remote.git"
	git init -q --bare "$remote_dir"
	git -C "$work_dir" remote add origin "$remote_dir"
	git -C "$work_dir" push -q origin main
	# Switch to feature branch
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	if [[ "$add_commit" -eq 1 ]]; then
		echo "change" >"$work_dir/change.txt"
		git -C "$work_dir" add change.txt
		git -C "$work_dir" commit -q -m "feat: add change"
	fi
	return 0
}

test_worker_produced_output_no_commits_returns_noop() {
	local work_dir="${TEST_ROOT}/repo-no-commits"
	_setup_test_git_repo "$work_dir" 0
	# No gh available in test env, no DISPATCH_REPO_SLUG set — signal 3 skipped
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' with zero commits" 0
	else
		print_result "_worker_produced_output returns 'noop' with zero commits" 1 \
			"Expected 'noop' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_with_commits_returns_pr_exists_failopen() {
	# Commits present but no DISPATCH_REPO_SLUG → cannot confirm PR absence → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-with-commits"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 1 \
			"Expected 'pr_exists' (fail-open) but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_non_worker_session_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pulse"
	_setup_test_git_repo "$work_dir" 0

	# Non-worker session keys (pulse, triage) must always return pr_exists (fail-open)
	local classification
	classification=$(_worker_produced_output "pulse-main" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 1 \
			"Non-worker session should always return 'pr_exists' (fail-open), got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_invalid_workdir_returns_pr_exists() {
	# Missing / non-git work_dir must fail-open
	local classification
	classification=$(_worker_produced_output "issue-99999" "/nonexistent/path/$$")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 1 \
			"Invalid work_dir should fail-open as 'pr_exists', got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_zero_diff_pushed_branch_returns_noop() {
	# A successful zero-count comparison proves no PR can exist for this head,
	# even when the feature ref was pushed and repo slug context is unavailable.
	local work_dir="${TEST_ROOT}/repo-pushed-noslug"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 0
	else
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 1 \
			"Expected 'noop' after a successful zero-count base comparison, got '${classification}'"
	fi
	return 0
}

# AC#2: pushed branch + confirmed no PR → branch_orphan
test_worker_produced_output_branch_no_pr_returns_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-orphan"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	# Set DISPATCH_REPO_SLUG and stub gh to return 0 PRs
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "branch_orphan" ]]; then
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 0
	else
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 1 \
			"Expected 'branch_orphan' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_local_branch_no_remote_returns_local_branch_unpushed() {
	local work_dir="${TEST_ROOT}/repo-local-unpushed"
	_setup_test_git_repo "$work_dir" 1
	# Do not push the feature branch: local commits exist, remote branch absent.
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "local_branch_unpushed" ]]; then
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 0
	else
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 1 \
			"Expected 'local_branch_unpushed' but got '${classification}'"
	fi
	return 0
}

# AC#2 variant: PR confirmed → pr_exists even when branch is pushed
test_worker_produced_output_branch_with_pr_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pr-exists"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	gh() {
		if [[ "${*}" == *"api --paginate"* && "${*}" == *"/issues/123/comments"* ]]; then
			printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
		elif [[ "${*}" == *"--head"* && "${*}" == *"statusCheckRollup"* ]]; then
			printf '[{"number":123,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]\n' "$expected_head"
		else
			printf '%s\n' '[]'
		fi
		return 0
	}

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 1 \
			"Expected 'pr_exists' but got '${classification}'"
	fi
	return 0
}

test_release_dispatch_claim_ignores_non_issue_session_key_digits() {
	local result status gh_called active_called unlock_called output
	result=$(
		unset WORKER_ISSUE_NUMBER 2>/dev/null || true
		DISPATCH_REPO_SLUG="owner/repo"
		WORKER_GITHUB_LOGIN="test-runner"
		gh_called=0
		active_called=0
		unlock_called=0
		gh() { gh_called=$((gh_called + 1)); return 0; }
		clear_active_status_on_release() { active_called=1; return 0; }
		_unlock_issue_after_dispatch_release() { unlock_called=1; return 0; }

		local release_output="" release_status=0
		release_output=$(_release_dispatch_claim "validation-gh3343-positive-review-20260705" "worker_complete" 0 1 2>&1) || release_status=$?
		printf '%s|%s|%s|%s|%s' "$release_status" "$gh_called" "$active_called" "$unlock_called" "$release_output"
	)
	IFS='|' read -r status gh_called active_called unlock_called output <<<"$result"

	if [[ "$status" -eq 0 && "$gh_called" -eq 0 && "$active_called" -eq 0 && "$unlock_called" -eq 0 && -z "$output" ]]; then
		print_result "release claim ignores non-issue session keys ending in digits" 0
		return 0
	fi

	print_result "release claim ignores non-issue session keys ending in digits" 1 \
		"status=$status gh=$gh_called active=$active_called unlock=$unlock_called output=${output:-<empty>}"
	return 0
}

test_cmd_run_finish_emits_noop_for_zero_output() {
	local work_dir="${TEST_ROOT}/repo-finish-noop"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	# Stub lifecycle functions to capture what was called
	local released_reason="" fast_fail_reason="" fast_fail_crash="" recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; fast_fail_crash="$3"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_noop" ]]; then
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 0
	else
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 1 \
			"Expected released_reason=worker_noop, got '${released_reason}'"
	fi

	if [[ "$fast_fail_reason" == "worker_noop_zero_output" && "$fast_fail_crash" == "no_work" ]]; then
		print_result "_cmd_run_finish increments fast-fail on noop" 0
	else
		print_result "_cmd_run_finish increments fast-fail on noop" 1 \
			"Expected fast_fail reason=worker_noop_zero_output/crash=no_work, got '${fast_fail_reason}'/'${fast_fail_crash}'"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 0
	else
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_for_real_output() {
	local work_dir="${TEST_ROOT}/repo-finish-complete"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete for real output" 0
	else
		print_result "_cmd_run_finish emits worker_complete for real output" 1 \
			"Expected released_reason=worker_complete, got '${released_reason}'"
	fi

	if [[ "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 0
	else
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 1 \
			"fast-fail should not be called when worker produced real output"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success telemetry for real output" 0
	else
		print_result "_cmd_run_finish records success telemetry for real output" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_appends_reconciled_attempt_outcome() {
	local work_dir="${TEST_ROOT}/repo-finish-reconciled"
	local capture_file="${TEST_ROOT}/reconciled-outcome.capture"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="premature_exit"
		_run_failure_reason="model_stopped_before_completion"
		_release_dispatch_claim() { return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
	)

	local captured=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	if [[ "$captured" == "issue-99999|premature_exit|success|premature_exit|model_stopped_before_completion" ]]; then
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 0
	else
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 1 \
			"captured=${captured:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_rejects_unverified_post_pr_handoff() {
	local work_dir="${TEST_ROOT}/repo-finish-unverified-handoff"
	local capture_file="${TEST_ROOT}/unverified-handoff.capture"
	local release_file="${TEST_ROOT}/unverified-handoff.release"
	local ledger_file="${TEST_ROOT}/unverified-handoff.ledger"
	local result_file="${TEST_ROOT}/unverified-handoff.result"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="post_pr_handoff"
		_run_failure_reason=""
		_release_dispatch_claim() { printf '%s' "$2" >"$release_file"; return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { printf '%s' "$2" >"$ledger_file"; return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_worker_post_pr_handoff_confirmed() { return 1; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		set +e
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
		printf '%s' "$?" >"$result_file"
		set -e
	)

	local captured="" release_reason="" ledger_status="" finish_result=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	[[ -s "$release_file" ]] && release_reason=$(<"$release_file")
	[[ -s "$ledger_file" ]] && ledger_status=$(<"$ledger_file")
	[[ -s "$result_file" ]] && finish_result=$(<"$result_file")
	if [[ "$captured" == "issue-99999|post_pr_handoff|failed|failed|worker_post_pr_handoff_unverified" ]] &&
		[[ "$release_reason" == "worker_post_pr_handoff_unverified" && "$ledger_status" == "fail" && "$finish_result" == "1" ]]; then
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 0
	else
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 1 \
			"captured=${captured:-<empty>} release=${release_reason:-<empty>} ledger=${ledger_status:-<empty>} result=${finish_result:-<empty>}"
	fi
	return 0
}

test_permission_finish_failure_recovers_draft_and_runs_cleanup() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() {
				recovery_called=1
				_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
				return 0
			}
			_report_failure_to_fast_fail() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() {
				local session_key="$1"
				local ledger_status="$2"
				cleanup_called=1
				printf "cleanup_ledger=%s\n" "$ledger_status"
				return 0
			}

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|terminal=%s|classification=%s|failure=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$_HRW_FINAL_RUNTIME_STATUS" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION" "$_run_failure_reason"
		)
	)
	if [[ "$result" == *"cleanup_ledger=fail"* && \
		"$result" == *"status=1|recovery=1|cleanup=1|terminal=escalated|classification=worker_draft_checkpoint|failure=permission_request_persistence_failed"* ]]; then
		print_result "permission persistence failure recovers draft and runs common cleanup" 0
	else
		print_result "permission persistence failure recovers draft and runs common cleanup" 1 "$result"
	fi
	return 0
}

test_permission_finish_failure_without_output_releases_and_cleans_up() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0 released_reason="" fast_fail_reason=""
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() { recovery_called=1; return 1; }
			_release_dispatch_claim() {
				local session_key="$1"
				local reason="$2"
				released_reason="$reason"
				return 0
			}
			_report_failure_to_fast_fail() {
				local session_key="$1"
				local reason="$2"
				fast_fail_reason="$reason"
				return 0
			}
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { cleanup_called=1; return 0; }

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|released=%s|fast_fail=%s|classification=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$released_reason" "$fast_fail_reason" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == "status=1|recovery=1|cleanup=1|released=worker_failed|fast_fail=permission_request_persistence_failed|classification=permission_request_persistence_failed" ]]; then
		print_result "permission persistence failure without output releases and cleans up" 0
	else
		print_result "permission persistence failure without output releases and cleans up" 1 "$result"
	fi
	return 0
}

test_begin_worker_runtime_run_refreshes_run_id() {
	local first_run_id="" second_run_id=""
	AIDEVOPS_RUN_ID="run:stale"
	_begin_worker_runtime_run
	first_run_id="$AIDEVOPS_RUN_ID"
	_begin_worker_runtime_run
	second_run_id="$AIDEVOPS_RUN_ID"

	if [[ "$first_run_id" == run:* && "$second_run_id" == run:* ]] &&
		[[ "$first_run_id" != "run:stale" && "$second_run_id" != "$first_run_id" ]]; then
		print_result "each runtime process invocation receives a fresh run ID" 0
	else
		print_result "each runtime process invocation receives a fresh run ID" 1 \
			"first=${first_run_id:-<empty>} second=${second_run_id:-<empty>}"
	fi
	return 0
}

test_internal_opencode_retries_refresh_run_id() {
	local refresh_count=""
	refresh_count=$(python3 - "$HELPER_SCRIPT" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("_execute_run_attempt() {")
end = source.index("\n#######################################\n# _discover_actual_worktree_dir", start)
body = source[start:end]
print(len(re.findall(r"_begin_worker_runtime_run\s*\n\s*_invoke_opencode", body)))
PY
	)

	if [[ "$refresh_count" == "2" ]]; then
		print_result "internal OpenCode retries refresh run identity before invocation" 0
	else
		print_result "internal OpenCode retries refresh run identity before invocation" 1 \
			"Expected two guarded internal retries, got ${refresh_count:-<empty>}"
	fi
	return 0
}

test_reconciled_outcome_persistence_retries() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper.sh"
	local count_file="${TEST_ROOT}/fake-objective-helper.count"
	local args_file="${TEST_ROOT}/fake-objective-helper.args"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
set -u
count=0
[[ -f "$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE" ]] && read -r count <"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" >"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
printf '%s\n' "$*" >"$AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE"
[[ "$count" -ge 3 ]]
SH
	chmod +x "$fake_helper"

	(
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE="$count_file"
		export AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE="$args_file"
		export AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS=3
		export AIDEVOPS_ATTEMPT_ID="attempt:retry-test"
		export AIDEVOPS_ATTEMPT_STARTED_AT=700
		export AIDEVOPS_RUN_ID="run:retry-test"
		export WORKER_ISSUE_NUMBER=99999
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "issue-99999" "premature_exit" \
			"success" "recovered" "worker_complete"
	)

	local call_count="" captured_args=""
	[[ -f "$count_file" ]] && read -r call_count <"$count_file"
	[[ -f "$args_file" ]] && read -r captured_args <"$args_file"
	if [[ "$call_count" == "3" && "$captured_args" == *"--attempt-id attempt:retry-test"* ]] &&
		[[ "$captured_args" == *"--run-id run:retry-test"* ]]; then
		print_result "reconciled outcome persistence retries bounded transient failures" 0
	else
		print_result "reconciled outcome persistence retries bounded transient failures" 1 \
			"calls=${call_count:-<empty>} args=${captured_args:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_when_no_workdir() {
	# When work_dir is absent (fail paths), behaviour is unchanged: worker_complete
	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 0
	else
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 1 \
			"Expected worker_complete (fail-open), got '${released_reason}'"
	fi
	return 0
}

# AC#3: orphan-recovery attempts gh pr create with correct args
test_attempt_orphan_recovery_pr_calls_gh_create() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	printf '{"pr_base_branch":"develop"}\n' >"${work_dir}/.aidevops.json"

	local gh_head="" gh_base="" gh_repo="" gh_labels=""
	local gh_called=0
	gh() {
		# Capture pr create args
		local arg
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			"--repo") gh_repo="$arg" ;;
			"--label")
				if [[ -z "$gh_labels" ]]; then
					gh_labels="$arg"
				else
					gh_labels="${gh_labels},${arg}"
				fi
				;;
			esac
			_last_flag="$arg"
		done
		gh_called=1
		return 0
	}
	_last_flag=""

	_attempt_orphan_recovery_pr \
		"issue-99999" "$work_dir" "feature/auto-test-issue-99999" "test-owner/test-repo"

	unset -f gh 2>/dev/null || true

	if [[ "$gh_called" -eq 1 ]]; then
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 0
	else
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 1 \
			"gh was not called"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" ]]; then
		print_result "_attempt_orphan_recovery_pr passes correct --head" 0
	else
		print_result "_attempt_orphan_recovery_pr passes correct --head" 1 \
			"Expected --head=feature/auto-test-issue-99999, got '${gh_head}'"
	fi

	if [[ ",${gh_labels}," == *",origin:worker-takeover,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 1 \
			"Expected --label=origin:worker-takeover, got '${gh_labels}'"
	fi

	if [[ ",${gh_labels}," == *",status:in-review,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 1 \
			"Expected --label=status:in-review, got '${gh_labels}'"
	fi

	if [[ "$gh_base" == "develop" ]]; then
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 0
	else
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 1 \
			"Expected --base=develop, got '${gh_base}'"
	fi

	return 0
}

test_ensure_orphan_recovery_rejects_empty_branch() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery-empty-branch"
	_setup_test_git_repo "$work_dir" 1

	local recovery_state=""
	if recovery_state=$(_ensure_orphan_recovery_branch_remote "$work_dir" "" "99999" "test-owner/test-repo"); then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected failure for empty branch, got '${recovery_state}'"
		return 0
	fi

	if [[ -z "$recovery_state" ]]; then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 0
	else
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected no state for empty branch, got '${recovery_state}'"
	fi
	return 0
}

test_build_orphan_recovery_pr_body_tolerates_missing_publish_flag() {
	local pr_body=""
	if ! pr_body=$(_build_orphan_recovery_pr_body "issue-99999" "feature/auto-test-issue-99999" "Resolves #99999"); then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Function failed when published_local_branch arg was omitted"
		return 0
	fi

	if [[ "$pr_body" == *"worker_branch_orphan"* ]] && [[ "$pr_body" != *"worker_local_branch_unpushed"* ]]; then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 0
	else
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Expected default orphan marker, got '${pr_body}'"
	fi
	return 0
}

# AC#4: on auto-PR success, _cmd_run_finish emits worker_complete with orphan note
test_cmd_run_finish_orphan_recovery_success_emits_worker_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-ok"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0 (no PR); pr create succeeds; issue view = OPEN
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 0
	else
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 1 \
			"Expected worker_complete (PR auto-created), got '${released_reason}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_pushes_and_recovers_pr() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-ok"
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	local gh_head="" gh_base="" gh_called=0
	gh() {
		local arg=""
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			esac
			_last_flag="$arg"
		done
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		elif [[ "${*}" == *"pr create"* ]]; then gh_called=1
		fi
		return 0
	}
	_last_flag=""

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	local remote_ref=""
	remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/feature/auto-test-issue-99999" 2>/dev/null || true)
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" && "$gh_called" -eq 1 && -n "$remote_ref" ]]; then
		print_result "_cmd_run_finish pushes local branch and recovers PR" 0
	else
		print_result "_cmd_run_finish pushes local branch and recovers PR" 1 \
			"Expected worker_complete, gh pr create, and remote ref; got reason='${released_reason}' gh_called=${gh_called} remote_ref='${remote_ref}'"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" && "$gh_base" == "main" ]]; then
		print_result "local unpushed recovery creates PR from pushed branch against base" 0
	else
		print_result "local unpushed recovery creates PR from pushed branch against base" 1 \
			"Expected head feature/auto-test-issue-99999 base main, got head='${gh_head}' base='${gh_base}'"
	fi
	return 0
}

test_handle_worker_branch_orphan_empty_branch_issue_search_is_not_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-cleaned"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Empty branch forces issue-search fallback, which is dedup evidence but cannot
	# prove an exact-head completed handoff.
	gh() {
		if [[ "${*}" == *"pr list"* && "${*}" == *"--search #99999 in:body"* ]]; then
			printf '%s\n' '[{"number":123}]'
			return 0
		fi
		printf '%s\n' '[]'
		return 0
	}

	local released_reason=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_increment_orphan_count_stat() { return 0; }

	_handle_worker_branch_orphan "issue-99999" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 0
	else
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 1 \
			"Expected worker_branch_orphan for inconclusive issue search, got '${released_reason}'"
	fi
	return 0
}

# AC#4: on auto-PR failure, _cmd_run_finish emits worker_branch_orphan
test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	# Stub gh: pr list returns 0, issue view = OPEN, pr create FAILS
	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		elif [[ "${*}" == *"pr create"* ]]; then
			return 1  # Simulate pr create failure
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 0
	else
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 1 \
			"Expected worker_branch_orphan (PR create failed), got '${released_reason}'"
	fi

	if [[ "$posted_body" == *"gh pr create --head feature/auto-test-issue-99999 --base develop --repo test-owner/test-repo"* ]]; then
		print_result "worker_branch_orphan comment uses configured PR base" 0
	else
		print_result "worker_branch_orphan comment uses configured PR base" 1 \
			"Expected orphan recovery comment with --base develop, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_push_failure_emits_distinct_reason() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" remote set-url origin "${TEST_ROOT}/missing-remote.git"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_local_branch_unpushed" ]]; then
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 0
	else
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 1 \
			"Expected worker_local_branch_unpushed, got '${released_reason}'"
	fi

	local expected_push_ref="HE""AD:feature/auto-test-issue-99999"
	if [[ "$posted_body" == *"WORKER_LOCAL_BRANCH_UNPUSHED"* && "$posted_body" == *"git -C ${work_dir} push origin ${expected_push_ref}"* ]]; then
		print_result "local unpushed failure comment is distinct and includes push recovery" 0
	else
		print_result "local unpushed failure comment is distinct and includes push recovery" 1 \
			"Expected local-unpushed recovery comment, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_fail_recovers_branch_orphan_output() {
	local work_dir="${TEST_ROOT}/repo-fail-orphan-ok"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }
	_cmd_run_finish "issue-99999" "fail" "$work_dir"
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail recovers branch-orphan output" 0
	else
		print_result "_cmd_run_finish fail recovers branch-orphan output" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success for recovered failed run" 0
	else
		print_result "_cmd_run_finish records success for recovered failed run" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_closed_issue_without_merged_pr_fails() {
	local work_dir="${TEST_ROOT}/repo-fail-issue-closed"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 0
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* ]]; then printf ''
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_failed" && "$fast_fail_called" -eq 1 ]]; then
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 0
	else
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 1 \
			"Expected worker_failed and fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 0
	else
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_existing_pr_recovery_remains_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-pr-merged"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--state merged"* ]]; then printf '1'
		else printf '0'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 0
	else
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}

test_cmd_run_finish_fail_confirmed_terminal_state_releases_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-terminal-complete"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	WORKER_TARGET_BRANCH=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD)
	export WORKER_TARGET_BRANCH
	rm -rf "$work_dir"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--head"* && "${*}" == *"--state merged"* ]]; then printf '123'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--search"* && "${*}" == *"--state merged"* ]]; then printf '123'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset WORKER_TARGET_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail uses cached branch when live worktree lookup is invalid" 0
	else
		print_result "_cmd_run_finish fail treats confirmed terminal GitHub state as complete" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}

test_post_pr_handoff_detects_open_pending_pr() {
	local work_dir="${TEST_ROOT}/repo-post-pr-handoff"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* && "$args" == *"--state open"* && "$args" == *"--head feature/auto-test-issue-99999"* ]]; then
			printf '[{"number":123,"isDraft":false,"headRefOid":"%s","statusCheckRollup":[]}]' "$expected_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* && "$args" == *"/issues/123/comments"* ]]; then
			printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			return 0
		fi
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff detects open pending PR" 0
	else
		print_result "post-PR watchdog handoff detects open pending PR" 1 \
			"Expected open PR on worker branch to classify as handoff"
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_post_pr_handoff_rejects_mismatched_head_or_missing_summary() {
	local work_dir="${TEST_ROOT}/repo-post-pr-incomplete"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	local remote_head="different-head"
	local summary_count=1

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* ]]; then
			printf '[{"number":125,"isDraft":false,"headRefOid":"%s","statusCheckRollup":[]}]' "$remote_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* ]]; then
			if [[ "$summary_count" -gt 0 ]]; then
				printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			else
				printf '%s' '[[]]'
			fi
			return 0
		fi
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects mismatched PR head" 1
	else
		print_result "post-PR watchdog handoff rejects mismatched PR head" 0
	fi
	remote_head="$expected_head"
	summary_count=0
	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects missing MERGE_SUMMARY" 1
	else
		print_result "post-PR watchdog handoff rejects missing MERGE_SUMMARY" 0
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_failed_worker_draft_checkpoint_escalates_without_completion() {
	local result=""
	local escalation_marker="${TEST_ROOT}/draft-checkpoint-escalated"
	rm -f "$escalation_marker"
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				if [[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]]; then
					printf 'feature/auto-test-issue-99999'
				fi
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'draft_checkpoint|456'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			set_issue_status() { : >"$escalation_marker"; return 0; }
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf '%s\n' '{"labels":[{"name":"needs-maintainer-review"}]}'
				fi
				return 0
			}
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	if [[ "$result" == *"release=worker_draft_checkpoint"* && -f "$escalation_marker" && "$result" == *"classification=worker_draft_checkpoint"* ]]; then
		print_result "failed worker draft checkpoint escalates without worker_complete" 0
	else
		print_result "failed worker draft checkpoint escalates without worker_complete" 1 "$result"
	fi
	return 0
}

test_failed_worker_draft_retains_claim_when_block_not_visible() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'draft_checkpoint|456'; return 0; }
			set_issue_status() { return 0; }
			gh() { printf '%s\n' '{"labels":[]}'; return 0; }
			_release_dispatch_claim() { printf 'unexpected-release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	if [[ "$result" == *"classification=worker_draft_checkpoint_escalation_failed"* && "$result" != *"unexpected-release="* ]]; then
		print_result "draft checkpoint retains claim when blocking label read-back fails" 0
	else
		print_result "draft checkpoint retains claim when blocking label read-back fails" 1 "$result"
	fi
	return 0
}

test_protected_draft_is_not_mutated_or_completed() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'protected_draft|458'; return 0; }
			set_issue_status() { printf 'unexpected-mutation\n'; return 0; }
			_release_dispatch_claim() { printf 'unexpected-release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	if [[ "$result" == *"classification=worker_protected_draft"* && "$result" != *"unexpected-mutation"* && "$result" != *"unexpected-release="* ]]; then
		print_result "protected draft is neither mutated nor reported complete" 0
	else
		print_result "protected draft is neither mutated nor reported complete" 1 "$result"
	fi
	return 0
}

test_checkpoint_terminal_telemetry_is_failed_escalated() {
	local fixture_class="draft_checkpoint"
	local expected_reason="worker_draft_checkpoint"
	local result
	result=$(
		(
			_worker_produced_output() { printf '%s' "$fixture_class"; return 0; }
			_escalate_worker_pr_checkpoint() { _HRW_RECOVERY_CLASSIFICATION="$expected_reason"; return 0; }
			_hrw_finish_success_run "issue-99999" "${TEST_ROOT}"
			printf '%s|%s|%s|%s' "$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_EVENT" \
				"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == "failed|worker.failed|escalated|${expected_reason}" ]]; then
		print_result "${fixture_class} records failed/escalated terminal telemetry" 0
	else
		print_result "${fixture_class} records failed/escalated terminal telemetry" 1 "$result"
	fi
	return 0
}

test_failed_ci_ready_pr_is_durable_handoff() {
	local pr_json result
	pr_json='[{"number":457,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"abc123","labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"},{"name":"tests","conclusion":"SUCCESS"}]}]'
	result=$(_pr_handoff_state_from_json "$pr_json" "abc123")
	if [[ "$result" == "ready|457" ]]; then
		print_result "failed or historical CI does not invalidate a ready PR handoff" 0
	else
		print_result "failed or historical CI does not invalidate a ready PR handoff" 1 "$result"
	fi
	return 0
}

test_closed_unmerged_pr_is_failed_not_completed() {
	local result=""
	result=$(
		(
			_worker_produced_output() { printf 'closed_unmerged'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_report_failure_to_fast_fail() { return 0; }
			_hrw_finish_success_run "issue-99999" "${TEST_ROOT}"
			printf 'terminal=%s|%s|%s|%s\n' "$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_EVENT" \
				"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == *"release=worker_closed_unmerged_pr"* && \
		"$result" == *"terminal=failed|worker.failed|failed|worker_closed_unmerged_pr"* && \
		"$result" != *"release=worker_complete"* ]]; then
		print_result "closed-unmerged PR records failure and never worker_complete" 0
	else
		print_result "closed-unmerged PR records failure and never worker_complete" 1 "$result"
	fi
	return 0
}

test_failed_worker_ready_pr_remains_completed_handoff() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'ready|457'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
		)
	)
	if [[ "$result" == *"release=worker_complete"* && "$result" != *"worker_draft_checkpoint"* ]]; then
		print_result "failed worker ready PR remains a completed handoff" 0
	else
		print_result "failed worker ready PR remains a completed handoff" 1 "$result"
	fi
	return 0
}

test_post_pr_handoff_rejects_pre_pr_stall() {
	local work_dir="${TEST_ROOT}/repo-pre-pr-stall"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	gh() {
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects pre-PR stall" 1 \
			"Expected no open PR to remain redispatchable"
	else
		print_result "post-PR watchdog handoff rejects pre-PR stall" 0
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_post_pr_handoff_overrides_watchdog_next_action() {
	local work_dir="${TEST_ROOT}/repo-watchdog-next-action"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* && "$args" == *"--state open"* ]]; then
			printf '[{"number":124,"isDraft":false,"headRefOid":"%s","statusCheckRollup":[]}]' "$expected_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* && "$args" == *"/issues/124/comments"* ]]; then
			printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			return 0
		fi
		printf '[]'
		return 0
	}

	local evidence_fields="" launch_failure_cause="" next_action=""
	evidence_fields=$(_derive_worker_failure_evidence "watchdog_stall_killed" "79" "1" "hard_kill_stall" "watchdog_stall_killed")
	launch_failure_cause="${evidence_fields%%$'\t'*}"
	next_action="${evidence_fields#*$'\t'}"
	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		launch_failure_cause="post_pr_pending_ci_handoff"
		next_action="monitor_open_pr"
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$launch_failure_cause" == "post_pr_pending_ci_handoff" && "$next_action" == "monitor_open_pr" ]]; then
		print_result "post-PR watchdog handoff suppresses redispatch next_action" 0
	else
		print_result "post-PR watchdog handoff suppresses redispatch next_action" 1 \
			"Expected monitor_open_pr, got cause='${launch_failure_cause}' next='${next_action}'"
	fi
	return 0
}

test_completion_infrastructure_resumes_without_implementation_penalty() {
	local reason="" evidence_fields="" launch_failure_cause="" next_action=""
	for reason in github_api_timeout command_policy_timeout prepared_commit_push_blocked completed_locally_remote_completion_blocked; do
		if ! _worker_failure_reason_is_completion_infrastructure "$reason"; then
			print_result "completion infrastructure class ${reason}" 1 "Reason was not classified"
			continue
		fi
		evidence_fields=$(_derive_worker_failure_evidence "blocked" "1" "1" "natural" "$reason")
		launch_failure_cause="${evidence_fields%%$'\t'*}"
		next_action="${evidence_fields#*$'\t'}"
		if [[ "$launch_failure_cause" == "$reason" && "$next_action" == "resume_session_with_completion_contract" ]]; then
			print_result "completion infrastructure class ${reason}" 0
		else
			print_result "completion infrastructure class ${reason}" 1 \
				"cause='${launch_failure_cause}' next='${next_action}'"
		fi
	done
	return 0
}

test_pr_checkpoint_lifecycle_cases() {
	test_post_pr_handoff_detects_open_pending_pr
	test_post_pr_handoff_rejects_mismatched_head_or_missing_summary
	test_failed_worker_draft_checkpoint_escalates_without_completion
	test_failed_worker_draft_retains_claim_when_block_not_visible
	test_protected_draft_is_not_mutated_or_completed
	test_checkpoint_terminal_telemetry_is_failed_escalated
	test_failed_ci_ready_pr_is_durable_handoff
	test_closed_unmerged_pr_is_failed_not_completed
	test_failed_worker_ready_pr_remains_completed_handoff
	return 0
}

run_worker_db_persistence_tests() {
	test_seed_worker_db_session_context_copies_only_selected_session
	test_seed_worker_db_session_context_rebinds_replacement_worktree
	test_seed_worker_db_session_context_copies_migration_metadata
	test_seed_worker_db_session_context_uses_schema_only_fresh_db
	test_seed_worker_db_session_context_vacuums_pruned_backup
	test_seed_worker_db_session_context_copies_complete_graph
	test_merge_worker_db_replaces_complete_session_graph_atomically
	test_merge_worker_db_maps_columns_by_name
	test_merge_worker_db_rejects_missing_required_destination_column
	test_merge_worker_db_failure_preserves_recovery_db_without_auth
	test_replay_preserved_worker_db_verifies_before_deletion
	test_worker_db_replay_lock_recovers_stale_owner_and_waits_for_pid
	test_sync_worker_db_migration_metadata_repairs_prewarmed_project_table
	test_sync_worker_db_migration_metadata_replaces_stale_ledgers
	test_copy_worker_db_migration_ledger_preserves_rows_when_attach_fails
	test_copy_worker_db_migration_ledger_stops_when_schema_query_fails
	test_sync_worker_db_migration_metadata_archives_unrepairable_project_table
	test_sync_worker_db_migration_metadata_preserves_worker_db_when_shared_query_fails
	test_sync_worker_db_migration_metadata_repeated_launch_reaches_seed
	return 0
}

run_private_workload_security_tests() {
	test_private_workload_arguments_are_fail_closed
	test_private_workload_uses_minimal_lifecycle
	test_private_workload_directory_lock_blocks_distinct_sessions
	test_private_workload_lock_is_cross_process_atomic
	test_private_output_filter_removes_content
	test_private_workload_requires_task_complete
	test_private_workload_skips_persistent_failure_output
	test_sandbox_private_output_avoids_raw_capture
	test_sandbox_passthrough_scopes_provider_env
	test_private_sandbox_passthrough_excludes_parent_credentials
	test_copy_scoped_opencode_auth_keeps_selected_provider_only
	return 0
}

run_worker_finish_tests() {
	test_release_dispatch_claim_ignores_non_issue_session_key_digits
	test_cmd_run_finish_emits_noop_for_zero_output
	test_cmd_run_finish_emits_complete_for_real_output
	test_cmd_run_finish_appends_reconciled_attempt_outcome
	test_cmd_run_finish_rejects_unverified_post_pr_handoff
	test_permission_finish_failure_recovers_draft_and_runs_cleanup
	test_permission_finish_failure_without_output_releases_and_cleans_up
	test_begin_worker_runtime_run_refreshes_run_id
	test_internal_opencode_retries_refresh_run_id
	test_reconciled_outcome_persistence_retries
	test_cmd_run_finish_emits_complete_when_no_workdir
	test_attempt_orphan_recovery_pr_calls_gh_create
	test_ensure_orphan_recovery_rejects_empty_branch
	test_build_orphan_recovery_pr_body_tolerates_missing_publish_flag
	test_cmd_run_finish_orphan_recovery_success_emits_worker_complete
	test_cmd_run_finish_local_unpushed_pushes_and_recovers_pr
	test_handle_worker_branch_orphan_empty_branch_issue_search_is_not_complete
	test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan
	test_cmd_run_finish_local_unpushed_push_failure_emits_distinct_reason
	test_cmd_run_finish_fail_recovers_branch_orphan_output
	test_cmd_run_finish_fail_closed_issue_without_merged_pr_fails
	test_cmd_run_finish_fail_existing_pr_recovery_remains_complete
	test_cmd_run_finish_fail_confirmed_terminal_state_releases_complete
	return 0
}

run_worker_worktree_ownership_tests() {
	test_worker_worktree_claim_transfers_to_runtime_pid
	test_worker_worktree_claim_reclaims_stale_live_same_task_owner
	test_worker_worktree_claim_reclaims_dispatch_precreate_owner
	test_worker_worktree_claim_transfers_dispatch_precreate_task_state
	test_worker_worktree_claim_rejects_dispatch_precreate_task_mismatch
	test_worker_worktree_claim_classifies_dispatch_precreate_concurrent_mutation
	test_worker_worktree_continuation_transfers_dirty_same_task_owner
	test_worker_worktree_continuation_transfers_ahead_same_task_owner
	test_worker_worktree_continuation_classifies_task_mismatch
	test_worker_worktree_continuation_classifies_owner_mismatch
	test_worker_worktree_continuation_classifies_concurrent_mutation
	test_worker_worktree_continuation_classifies_invalid_state
	test_worker_worktree_clean_without_upstream_blocks_local_commits
	test_worker_worktree_claim_classifies_unreclaimed_live_owner
	return 0
}

main() {
	setup_test_env
	test_appends_escalation_contract
	test_non_full_loop_prompt_unchanged
	test_headless_contract_uses_deployed_framework_paths
	test_parse_initial_model_does_not_set_explicit_override
	test_launch_helpers_tolerate_unset_state_under_nounset
	test_runtime_temp_files_use_managed_workspace
	test_headless_temp_initialization_preserves_process_scratch
	run_private_workload_security_tests
	test_startup_no_activity_timeout_returns_watchdog_continue
	test_startup_no_activity_can_rotate_after_continuation_budget
	test_sigkill_with_activity_attempts_continuation
	test_sigterm_with_local_kill_reason_does_not_resume_as_provider_drop
	test_handle_run_result_tolerates_empty_or_non_numeric_exit_code
	test_dispatcher_initial_model_can_rotate_after_rate_limit
	test_explicit_model_override_remains_pinned_on_rate_limit
	test_issue_worker_env_contract_rejects_missing_env
	test_issue_worker_env_contract_rejects_missing_worktree
	test_issue_worker_env_contract_accepts_valid_precreated_worktree
	run_worker_worktree_ownership_tests
	test_runtime_launch_marker_precedes_invocation
	test_clean_prelaunch_exit_is_precise_nonzero_failure
	test_deleted_cwd_recovery_uses_worker_worktree
	test_cmd_run_aborts_issue_worker_before_canary_when_env_missing
	test_cmd_run_preserves_worker_origin_overrides_before_canary
	test_deleted_launch_cwd_recovers_to_work_dir
	test_does_not_double_append
	test_extract_session_id_from_output_returns_latest_session_id
	test_provider_sessions_scope_issue_keys_by_repo_slug
	test_provider_sessions_keep_pulse_unscoped
	test_blocked_completion_records_blocked_label
	test_post_pr_handoff_completion_signal_is_exact
	test_post_pr_handoff_records_distinct_result_label
	test_missing_context_blocked_requests_brief_recovery
	test_headless_activity_timeout_default_matches_watchdog
	test_activity_watchdog_classifiers_detect_rate_limit_and_ci_wait
	test_failure_classifier_records_provenance
	test_failure_classifier_distinguishes_quota_exhaustion
	test_failure_classifier_distinguishes_anthropic_credit_exhaustion
	test_service_interruption_candidate_uses_separate_path
	test_service_interruption_exhausted_metric_preserves_context
	test_pr_checkpoint_lifecycle_cases
	test_post_pr_handoff_rejects_pre_pr_stall
	test_post_pr_handoff_overrides_watchdog_next_action
	test_completion_infrastructure_resumes_without_implementation_penalty
	test_canary_pins_vanilla_agent_with_isolated_plugin_config
	test_opencode_session_env_wrapper_strips_session_vars_only
	test_worker_opencode_exec_paths_strip_session_env
	test_worker_opencode_invocation_seeds_continuation_session
	run_worker_db_persistence_tests
	test_opencode_project_table_migration_replay_detected
	test_large_opencode_prompt_uses_file_attachment
	test_large_claude_prompt_uses_stdin_file
	test_registered_prompt_temp_cleanup_removes_dir
	test_launch_helpers_tolerate_unset_state
	test_worker_produced_output_no_commits_returns_noop
	test_worker_produced_output_with_commits_returns_pr_exists_failopen
	test_worker_produced_output_non_worker_session_returns_pr_exists
	test_worker_produced_output_invalid_workdir_returns_pr_exists
	test_worker_produced_output_zero_diff_pushed_branch_returns_noop
	test_worker_produced_output_branch_no_pr_returns_branch_orphan
	test_worker_produced_output_local_branch_no_remote_returns_local_branch_unpushed
	test_worker_produced_output_branch_with_pr_returns_pr_exists
	run_worker_finish_tests
	teardown_test_env
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
