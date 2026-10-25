#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worktree ownership, managed launch, readiness and live dispatch tracking tests.
# Sourced by the main runner; depends on its helper imports, mocks and assertions.
# shellcheck disable=SC2016

[[ -n "${_TEST_DSI_TRACKING_LOADED:-}" ]] && return 0
_TEST_DSI_TRACKING_LOADED=1

test_create_worktree_uses_target_repo_path() {
	local failed=1
	if grep -Fq "repo_path=\$(_dsi_repo_path_for_slug \"\$repo_slug\")" "$HELPER_PATH" &&
		grep -Fq "cd \"\$repo_path\" && AIDEVOPS_SKIP_AUTO_CLAIM=1" "$HELPER_PATH" &&
		grep -Fq "git -C \"\$repo_path\" worktree list --porcelain" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worktree creation uses target repo path" "$failed"
	return 0
}

test_create_worktree_registers_dispatch_owner() {
	local test_dir=""
	test_dir=$(mktemp -d)
	MOCK_REPO_PATH="${test_dir}/repo"
	MOCK_WORKTREE_PATH="${test_dir}/worktree"
	MOCK_DATE_UTC="20260515-123456"
	MOCK_WORKTREE_BRANCH="feature/auto-${MOCK_DATE_UTC}-gh12345"
	MOCK_GIT_WORKTREE_LIST="1"
	mkdir -p "$MOCK_REPO_PATH" "$MOCK_WORKTREE_PATH"
	REGISTER_WORKTREE_LOG="${test_dir}/register-worktree.log"
	MOCK_WORKTREE_HELPER_LOG="${test_dir}/worktree-helper.log"
	local repos_file="${test_dir}/repos.json"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","default_branch":"main","pr_base_branch":"develop"}]}' >"$repos_file"
	local -x AIDEVOPS_REPOS_FILE="$repos_file"
	export MOCK_WORKTREE_HELPER_LOG
	: >"$REGISTER_WORKTREE_LOG"
	: >"$MOCK_WORKTREE_HELPER_LOG"

	local original_worktree_helper="$_DSI_WORKTREE_HELPER"
	local positional_args_ref='$*'
	local env_ref='manager=${AIDEVOPS_WORKTREE_MANAGER:-} entry=${AIDEVOPS_LAUNCH_ENTRYPOINT:-} task=${AIDEVOPS_LAUNCH_TASK:-} repo=${AIDEVOPS_LAUNCH_REPO:-}'
	_DSI_WORKTREE_HELPER="${test_dir}/worktree-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf "printf 'worktree-helper %%s %%s\\n' \"%s\" \"%s\" >>%q\n" "$positional_args_ref" "$env_ref" "$MOCK_WORKTREE_HELPER_LOG"
		printf '%s\n' 'exit 0'
	} >"$_DSI_WORKTREE_HELPER"
	chmod +x "$_DSI_WORKTREE_HELPER"

	# Legacy backend chosen before creation: no enrollment request.
	local rc=0
	AIDEVOPS_WORKER_BACKEND=detached _dsi_create_worktree 12345 owner/repo >/dev/null 2>&1 || rc=$?

	local registered=""
	registered=$(<"$REGISTER_WORKTREE_LOG")
	local helper_call=""
	helper_call=$(<"$MOCK_WORKTREE_HELPER_LOG")
	: >"$REGISTER_WORKTREE_LOG"
	: >"$MOCK_WORKTREE_HELPER_LOG"
	local passed=1
	if [[ "$rc" -eq 0 && "$registered" == *"register_worktree ${MOCK_WORKTREE_PATH} ${MOCK_WORKTREE_BRANCH}"* &&
		"$registered" == *"--task 12345"* && "$registered" == *"--session dispatch-precreate-12345"* &&
		"$helper_call" == *"--base origin/develop"* && "$helper_call" == *"--issue 12345"* &&
		"$helper_call" == *"manager= entry=dispatch-single-issue"* && "$_DSI_MANAGED_WORKTREE" == 0 ]]; then
		passed=0
	fi

	# GH#35295: on the systemd backend manual dispatch enrolls exactly like
	# Pulse and binds the created generation; missing enrollment fails closed.
	local managed_result=0
	(
		_dlw_classify_reuse_candidate() {
			printf '%s\n' "$MOCK_CLASSIFY_RESULT"
			return 0
		}
		export AIDEVOPS_WORKER_BACKEND=systemd
		MOCK_CLASSIFY_RESULT="managed gen-0123"
		_dsi_create_worktree 12345 owner/repo >/dev/null 2>&1 || exit 1
		[[ "$_DSI_MANAGED_WORKTREE" == 1 && "$_DLW_WORKTREE_GENERATION" == gen-0123 ]] || exit 1
		grep -Fq "manager=pulse-cgroup-v1 entry=dispatch-single-issue task=12345 repo=owner/repo" "$MOCK_WORKTREE_HELPER_LOG" || exit 1
		MOCK_CLASSIFY_RESULT="legacy"
		if _dsi_create_worktree 12345 owner/repo >/dev/null 2>&1; then exit 1; fi
		[[ "$_DSI_MANAGED_WORKTREE" == 0 ]] || exit 1
		exit 0
	) || managed_result=1
	[[ "$managed_result" -eq 0 ]] || passed=1
	rm -f "$REGISTER_WORKTREE_LOG" "$MOCK_WORKTREE_HELPER_LOG"

	_DSI_WORKTREE_HELPER="$original_worktree_helper"
	MOCK_GIT_WORKTREE_LIST="0"
	MOCK_REPO_PATH=""
	MOCK_WORKTREE_PATH=""
	MOCK_WORKTREE_BRANCH=""
	MOCK_DATE_UTC=""
	REGISTER_WORKTREE_LOG=""
	unset MOCK_WORKTREE_HELPER_LOG
	MOCK_WORKTREE_HELPER_LOG=""
	rm -rf "$test_dir"
	print_result "worktree creation registers dispatch owner metadata and selects the lifetime backend first" "$passed" "rc=$rc managed=$managed_result registered=$registered helper=$helper_call"
	return 0
}

# GH#35295: resume and launch use the shared managed lifetime adapter.
test_manual_lifetime_binding_and_managed_launch() {
	local result=0 test_dir=""
	test_dir=$(mktemp -d)
	(
		_DSI_WORKTREE_PATH="${test_dir}/wt"
		_dlw_classify_reuse_candidate() {
			printf '%s' "$MOCK_CLASSIFY_RESULT"
			[[ -n "$MOCK_CLASSIFY_RESULT" ]] && printf '\n'
			[[ "$MOCK_CLASSIFY_RESULT" != unavailable ]] || return 1
			return 0
		}
		export AIDEVOPS_WORKER_BACKEND=systemd
		# Resume: managed reuses the exact generation; legacy stays legacy;
		# sealed, foreign-task and unavailable evidence all refuse.
		MOCK_CLASSIFY_RESULT="managed gen-1"
		_dsi_bind_worktree_lifetime 12345 owner/repo resume 2>/dev/null || exit 1
		[[ "$_DSI_MANAGED_WORKTREE" == 1 && "$_DLW_WORKTREE_GENERATION" == gen-1 ]] || exit 1
		MOCK_CLASSIFY_RESULT="legacy"
		_dsi_bind_worktree_lifetime 12345 owner/repo resume >/dev/null 2>&1 || exit 1
		[[ "$_DSI_MANAGED_WORKTREE" == 0 ]] || exit 1
		local refused=""
		for refused in sealed "" unavailable; do
			MOCK_CLASSIFY_RESULT="$refused"
			if _dsi_bind_worktree_lifetime 12345 owner/repo resume 2>/dev/null; then exit 1; fi
		done
		# An enrolled generation never downgrades to the legacy backend.
		MOCK_CLASSIFY_RESULT="managed gen-1"
		if AIDEVOPS_WORKER_BACKEND=detached _dsi_bind_worktree_lifetime 12345 owner/repo resume 2>/dev/null; then exit 1; fi

		# Managed launch: shared reserve/bind launcher, no runtime --detach,
		# no nohup fallback when admission fails.
		_DSI_MANAGED_WORKTREE=1
		_DSI_HEADLESS="${test_dir}/runtime"
		_DSI_LOG_DIR="${test_dir}/logs"
		_DSI_GIT_AUTH_TOKEN_FILE=""
		printf '#!/usr/bin/env bash\nexit 0\n' >"$_DSI_HEADLESS"
		chmod +x "$_DSI_HEADLESS"
		_dlw_launch_systemd_worker() {
			printf '%s\n' "$*" >"${test_dir}/launch-args"
			printf '%s|%s|%s\n' "${_DLW_MANAGED_WORKTREE:-}" "${_DLW_WORKTREE_PATH:-}" "${_DLW_LAUNCH_ENTRYPOINT:-}" >"${test_dir}/launch-env"
			[[ "$MOCK_ADMISSION" == ok ]] || return 1
			printf '4242\n'
			return 0
		}
		nohup() {
			printf 'nohup\n' >"${test_dir}/nohup-called"
			return 1
		}
		_DLW_LAUNCH_ENTRYPOINT=dispatch-single-issue
		MOCK_ADMISSION=ok
		local pid=""
		pid=$(_dsi_launch_worker manual-cli-12345-1 "${test_dir}/wt" t p standard '' Build+ "${test_dir}/launch.log" 12345 owner/repo me 2>/dev/null) || exit 1
		[[ "$pid" == 4242 ]] || exit 1
		grep -Fq -- "--session-key manual-cli-12345-1" "${test_dir}/launch-args" || exit 1
		! grep -Fq -- "--detach" "${test_dir}/launch-args" || exit 1
		[[ "$(<"${test_dir}/launch-env")" == "1|${test_dir}/wt|dispatch-single-issue" ]] || exit 1
		grep -Fq "Dispatched PID: 4242" "${test_dir}/launch.log" || exit 1
		[[ "$(_dsi_detached_runtime_log "${test_dir}/launch.log")" == "${test_dir}/launch.log" ]] || exit 1
		MOCK_ADMISSION=failed
		if _dsi_launch_worker manual-cli-12345-2 "${test_dir}/wt" t p standard '' Build+ "${test_dir}/failed.log" 12345 owner/repo me 2>/dev/null; then exit 1; fi
		[[ ! -e "${test_dir}/nohup-called" ]] || exit 1
		exit 0
	) || result=1
	rm -rf "$test_dir"
	print_result "manual resume binds exact managed generations and launches through the shared launcher without fallback" "$result"
	return 0
}

test_dispatch_base_ref_prefers_repo_configured_pr_base() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local repos_file="${test_dir}/repos.json"
	local repo_path="${test_dir}/repo"
	mkdir -p "$repo_path"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","default_branch":"main","pr_base_branch":"develop"}]}' >"$repos_file"

	local -x AIDEVOPS_REPOS_FILE="$repos_file"
	unset AIDEVOPS_DISPATCH_BASE_REF AIDEVOPS_WORKTREE_BASE AIDEVOPS_DISPATCH_BASE_BRANCH DISPATCH_REPO_PR_BASE_BRANCH AIDEVOPS_PR_BASE_BRANCH

	local base_ref=""
	base_ref=$(_dsi_dispatch_base_ref owner/repo "$repo_path")
	local passed=1
	[[ "$base_ref" == "origin/develop" ]] && passed=0

	rm -rf "$test_dir"
	print_result "dispatch base ref uses configured PR base over default branch" "$passed" "base_ref=$base_ref"
	return 0
}

test_dispatch_base_ref_prefers_explicit_env_ref() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local repo_path="${test_dir}/repo"
	mkdir -p "$repo_path"
	export AIDEVOPS_DISPATCH_BASE_REF="upstream/integration"

	local base_ref=""
	base_ref=$(_dsi_dispatch_base_ref owner/repo "$repo_path")
	local base_branch=""
	base_branch=$(_dsi_branch_from_ref "$base_ref")
	local passed=1
	[[ "$base_ref" == "upstream/integration" && "$base_branch" == "upstream/integration" ]] && passed=0

	unset AIDEVOPS_DISPATCH_BASE_REF
	rm -rf "$test_dir"
	print_result "dispatch base ref honors explicit env override" "$passed" "base_ref=$base_ref branch=$base_branch"
	return 0
}

test_create_worktree_registration_fails_closed() {
	local failed=1
	if grep -Fq "register_worktree \"\$_DSI_WORKTREE_PATH\" \"\$_DSI_WORKTREE_BRANCH\"" "$HELPER_PATH" &&
		grep -Fq "Worktree ownership registration failed; dispatch is unsafe" "$HELPER_PATH" &&
		! grep -Fq -- "--session \"dispatch-precreate-\${issue_number}\" 2>/dev/null || true" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worktree registration failure blocks dispatch" "$failed"
	return 0
}

test_readiness_timeout_tracks_canary_budget() {
	local default_timeout="" custom_canary_timeout="" explicit_timeout="" invalid_timeout=""
	default_timeout=$(
		unset AIDEVOPS_DSI_READY_TIMEOUT_SECONDS CANARY_TIMEOUT_SECONDS
		_dsi_ready_timeout_seconds
	)
	custom_canary_timeout=$(CANARY_TIMEOUT_SECONDS=42 _dsi_ready_timeout_seconds)
	explicit_timeout=$(CANARY_TIMEOUT_SECONDS=180 AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_ready_timeout_seconds)
	invalid_timeout=$(CANARY_TIMEOUT_SECONDS=invalid AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=invalid _dsi_ready_timeout_seconds)

	local passed=1
	if [[ "$default_timeout" == "240" && "$custom_canary_timeout" == "102" &&
		"$explicit_timeout" == "0" && "$invalid_timeout" == "240" ]]; then
		passed=0
	fi
	print_result "readiness timeout covers canary budget and preserves overrides" "$passed" \
		"default=$default_timeout custom=$custom_canary_timeout explicit=$explicit_timeout invalid=$invalid_timeout"
	return 0
}

# GH#34556: readiness reads the runtime log path that _detach_worker emits in
# the launcher log. Creates "<dir>/launcher.log" pointing at "<dir>/runtime log".
_readiness_fixture_dir() {
	local dir=""
	dir=$(mktemp -d) || return 1
	printf '[INFO] Detaching worker (log: %s)\n' "${dir}/runtime log" >"${dir}/launcher.log"
	printf '%s\n' "$dir"
	return 0
}

test_readiness_accepts_worker_started_marker() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-ready-$$"
	local dir="" runtime_log=""
	dir=$(_readiness_fixture_dir)
	runtime_log=$(_dsi_detached_runtime_log "${dir}/launcher.log")
	printf '%s\n' "[lifecycle] worker_started session=${session_key}" >"$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" "${dir}/launcher.log" 2>&1) || rc=$?
	rm -rf "$dir"

	local passed=1
	[[ "$rc" -eq 0 && -z "$out" && "$runtime_log" == "${dir}/runtime log" ]] && passed=0
	print_result "readiness gate accepts worker_started marker at the emitted log path" "$passed" "rc=$rc runtime_log=$runtime_log output=$out"
	return 0
}

test_readiness_rejects_live_child_without_ready_signal() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-not-ready-$$"
	local dir=""
	dir=$(_readiness_fixture_dir)

	local out="" rc=0 unreported="" unreported_rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" "${dir}/launcher.log" 2>&1) || rc=$?
	# A launcher that never reported a log path must not be guessed into /tmp.
	: >"${dir}/launcher.log"
	unreported=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" "${dir}/launcher.log" 2>&1) || unreported_rc=$?
	rm -rf "$dir"

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* && "$out" == *"Runtime log:  ${dir}/runtime log"* &&
		"$unreported_rc" -eq 1 && "$unreported" == *"<not reported by launcher>"* && "$unreported" != *"/tmp/worker-"* ]] && passed=0
	print_result "readiness gate rejects live child without ready signal or reported log" "$passed" "rc=$rc output=$out unreported=$unreported"
	return 0
}

test_readiness_rejects_ledger_without_worker_started() {
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-ledger'
	local session_key="manual-cli-ledger-only-$$"
	local dir=""
	dir=$(_readiness_fixture_dir)

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" "${dir}/launcher.log" 2>&1) || rc=$?
	rm -rf "$dir"
	MOCK_LEDGER_RECORD=""

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* ]] && passed=0
	print_result "readiness gate rejects ledger without worker_started" "$passed" "rc=$rc output=$out"
	return 0
}

test_launch_report_waits_before_success_message() {
	local wait_line="" ok_line=""
	wait_line=$(grep -n '_dsi_wait_for_worker_readiness' "$HELPER_PATH" | tail -1 | cut -d: -f1)
	ok_line=$(grep -n '_dsi_ok "Worker launched"' "$HELPER_PATH" | tail -1 | cut -d: -f1)

	local passed=1
	if [[ -n "$wait_line" && -n "$ok_line" && "$wait_line" -lt "$ok_line" ]]; then
		passed=0
	fi
	print_result "launch report waits for readiness before Worker launched" "$passed" "wait_line=$wait_line ok_line=$ok_line"
	return 0
}
