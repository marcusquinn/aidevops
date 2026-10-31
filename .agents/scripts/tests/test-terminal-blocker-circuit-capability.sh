#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Capability, cooldown and bounded-recovery cases for the terminal-blocker circuit.
# Sourced by test-terminal-blocker-circuit.sh (shares its fixtures, print_result
# and TEST_* state); not executable standalone.

if [[ -n "${_TBC_CAPABILITY_TESTS_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TBC_CAPABILITY_TESTS_LOADED=1

test_push_policy_timeout_checkpoint() {
	local output="${TEST_ROOT}/push-timeout.ndjson"
	local status=0 fingerprint="" release="" head=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: command policy timed out under host load\nTERMINAL_BLOCKER_REASON=push_policy_timeout"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == push_policy_timeout ]] || status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'owner=runner-recovery'* ]] || status=1
	# Even repeated observations must not create a permanent task-revision hold.
	local comments='[{"id":1,"body":"observation","author_association":"OWNER","created_at":"2026-10-01T00:00:00Z"}]'
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == first ]] || status=1
	local repo="${TEST_ROOT}/push-checkpoint"
	command -p git clone -q --shared --bare "${SCRIPT_DIR}/../.." "$repo"
	command -p git -C "$repo" branch feature/push-checkpoint
	command -p git -C "$repo" symbolic-ref HEAD refs/heads/feature/push-checkpoint
	head=$(command -p git -C "$repo" rev-parse HEAD)
	release=$(AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$repo" _hrff_build_claim_released_line push_policy_timeout fixture 0 1)
	[[ "$release" == *'reason=push_policy_timeout'* && "$release" == *"branch=feature/push-checkpoint head=${head}"* ]] || status=1
	[[ "$release" != *"$repo"* ]] || status=1
	if ! (
		# Use the existing classifier-fixture pattern from test-integration-recovery.
		# shellcheck source=../headless-runtime-result.sh
		source "${SCRIPT_DIR}/headless-runtime-result.sh"
		_headless_private_workload_enabled() { return 1; }
		output_has_completion_signal() { return 0; }
		output_has_blocked_signal() { return 0; }
		output_has_post_pr_handoff_signal() { return 1; }
		output_has_missing_context_blocked_signal() { return 1; }
		output_has_capability_blocked_signal() { return 1; }
		print_warning() { return 0; }
		# shellcheck disable=SC2034
		role=worker session_key=issue-42 discovered_session="" selected_model=fixture work_dir="$repo"
		output_file="$output"
		result_rc=0
		_run_failure_reason=""
		_handle_run_result_success_output || result_rc=$?
		[[ "$result_rc" == 83 && "$_run_failure_reason" == push_policy_timeout ]]
	); then
		status=1
	fi
	print_result "push policy timeout stays transient and releases exact branch/HEAD without paths" "$status"
	return 0
}

test_affected_host_reproduction_alias() {
	local output="${TEST_ROOT}/affected-host.ndjson" status=0 fingerprint="" revision="" changed="" comments=""
	local issue='{"title":"Reproduce before fixing","body":"### Files Scope\n- helper.sh"}'
	printf '%s\n' '{"type":"text","text":"BLOCKED: missing affected-runner reproduction target\nTERMINAL_BLOCKER_REASON=affected_host_reproduction_unavailable"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$fingerprint" == "$(_terminal_blocker_hash 'v2:input_required:maintainer')" ]] || status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'owner=maintainer'* ]] || status=1
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT") || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" "$revision" "$fingerprint")" == circuit ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:05:00Z",author_association:"MEMBER"}]')
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT") || status=1
	[[ "$changed" == "$revision" ]] || status=1
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	changed=$(terminal_blocker_task_revision '{"title":"Reproduce before fixing","body":"### Files Scope\n- helper.sh\nAffected-runner target supplied"}' owner/repo 42 "$TEST_ROOT") || status=1
	[[ "$changed" != "$revision" ]] || status=1
	# Only the exact legacy marker is an alias; ambiguous/unknown output stays
	# retryable, and tool evidence cannot override the final assistant dossier.
	printf '%s\n' '{"type":"tool_result","text":"BLOCKED: old evidence\nTERMINAL_BLOCKER_REASON=affected_host_reproduction_unavailable"}' \
		'{"type":"text","text":"BLOCKED: unclassified\nTERMINAL_BLOCKER_REASON=not_a_supported_reason"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "affected-host legacy marker shares maintainer-input hold and ignores unrelated merges" "$status"
	return 0
}

test_unknown_blocker_ready_pr_replay() {
	local status=0 scenario=""
	for scenario in pending passed failed unreadable unverified explicit unsupported dirty; do
		if ! (
			# shellcheck source=../headless-runtime-result.sh
			source "${SCRIPT_DIR}/headless-runtime-result.sh"
			_headless_private_workload_enabled() { return 1; }
			output_has_blocked_signal() { return 0; }
			output_has_post_pr_handoff_signal() { return 1; }
			output_has_missing_context_blocked_signal() { return 1; }
			output_has_capability_blocked_signal() { return 1; }
			print_warning() { return 0; }
			_worker_post_pr_handoff_confirmed() { [[ "$scenario" != unverified ]]; return $?; }
			_pr_handoff_state_for_branch_or_issue() { printf 'ready|123'; return 0; }
			gh_pr_checks_observed_json() {
				case "$scenario" in
				failed) return 1 ;;
				unreadable) return 2 ;;
				pending) return 8 ;;
				esac
				return 0
			}
			git() {
				case "$*" in
				*status*) [[ "$scenario" != dirty ]] || printf ' M helper.sh' ;;
				*branch*) printf 'feature/replay' ;;
				*) printf '%040d' 1 ;;
				esac
				return 0
			}
			gh() { printf '%s\n' '{"body":"### Files Scope\n- helper.sh"}'; return 0; }
			export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG=owner/repo WORKER_SESSION_KEY=issue-42
			# shellcheck disable=SC2034
			role=worker session_key=issue-42 discovered_session="" selected_model=fixture work_dir="$TEST_ROOT"
			output_file="${TEST_ROOT}/replay-${scenario}.ndjson"
			local text="BLOCKED: PR is waiting on review"
			[[ "$scenario" != explicit ]] || text+=$'\nTERMINAL_BLOCKER_REASON=permission_required'
			[[ "$scenario" != unsupported ]] || text+=$'\nTERMINAL_BLOCKER_REASON=unsupported'
			jq -nc --arg text "$text" '{type:"text",text:$text}' >"$output_file"
			local rc=0
			_run_result_label=""
			_run_failure_reason=""
			_handle_run_result_success_output || rc=$?
			if [[ "$scenario" == pending || "$scenario" == passed ]]; then
				[[ "$rc" == 0 && "$_run_result_label" == post_pr_handoff && -z "$_run_failure_reason" ]]
			else
				[[ "$rc" == 83 && "$_run_result_label" == blocked ]]
			fi
		); then
			status=1
			printf 'Replay failed: %s\n' "$scenario"
		fi
	done
	print_result "unknown prose blocker becomes handoff only for verified clean PR with nonfailing checks" "$status"
	return 0
}

test_terminal_evidence_retention() {
	local status=0 output="${TEST_ROOT}/retained.ndjson"
	local log="${TEST_ROOT}/retention.jsonl"
	jq -nc --arg text 'BLOCKED: waiting token=fixture-secret-value' '{type:"text",text:$text}' >"$output"
	AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$log" terminal_blocker_capture_output "$output" || status=1
	jq -e '.event == "terminal_blocker_captured" and .blocking == false and
		(.blocker_fingerprint | test("^[a-f0-9]{24}$")) and
		(.detail | contains("[REDACTED]")) and (.detail | contains("fixture-secret-value") | not)' "$log" >/dev/null || status=1
	[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$log")" == 0o600 ]] || status=1
	printf '%s\n' '{"type":"tool","text":"BLOCKED: forged tool evidence"}' >"$output"
	AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$log" terminal_blocker_capture_output "$output" && status=1
	[[ "$(wc -l <"$log" | tr -d ' ')" == 1 ]] || status=1
	print_result "terminal evidence is redacted private bounded-log data and never tool output" "$status"
	return 0
}

test_runner_capability_class() {
	local status=0 output="$TEST_ROOT/capability-output.jsonl" fingerprint="" revision="" fragment="" comments=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: staging secret cannot resolve\nTERMINAL_BLOCKER_REASON=runner_capability_unmet"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == runner_capability_unmet ]] || status=1
	revision=$(terminal_blocker_task_revision '{}' owner/repo 42 '' runner_capability_unmet) || status=1
	[[ "$(terminal_blocker_release_mode '[]' "$revision" "$fingerprint")" == first ]] || status=1
	fragment=$(terminal_blocker_observation_fragment "$revision" "$fingerprint" first) || status=1
	[[ "$fragment" == *'reason=runner_capability_unmet'* && "$fragment" == *'status:available'* ]] || status=1
	terminal_blocker_circuit_comment release "$revision" "$fingerprint" >/dev/null && status=1
	comments=$(jq -nc --arg body "CLAIM_RELEASED reason=blocked runner=maintainer ts=2026-01-01T00:00:00Z
$fragment" '[{author_association:"OWNER",author:"maintainer",body:$body,created_at:"2026-01-01T00:00:00Z"},{author_association:"OWNER",author:"maintainer",body:$body,created_at:"2026-01-01T00:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1767225660 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	print_result "runner capability is known and never opens a shared circuit or backoff" "$status"
	return 0
}

# GH#35090 replay: a later lease/label write bumps updatedAt, and App-routed
# private-org reads report the runner's own comments as CONTRIBUTOR/NONE. The
# live gate must re-import its own observation; another login's comment cools
# nobody else. Runs inside test_worker_capability_cooldown's subshell and uses
# its candidate, fixture_comments, login and gh stub through dynamic scope.
_capability_cooldown_own_contributor_replay() {
	local trusted_comments="$fixture_comments" bumped="" association="" before="" after=""
	bumped=$(jq -c '.updatedAt = "2026-10-18T12:05:00Z"' <<<"$candidate") || return 1
	for association in CONTRIBUTOR NONE; do
		fixture_comments=$(jq -c --arg a "$association" 'map(.author_association = $a)' <<<"$trusted_comments")
		rm -f "$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42"
		before=$(rg -c 'runner_capability_unmet cooldown active' "$LOGFILE" || true)
		_dispatch_skip_for_capability_cooldown "$bumped" 42 owner/repo '' || return 1
		after=$(rg -c 'runner_capability_unmet cooldown active' "$LOGFILE" || true)
		((${after:-0} == ${before:-0} + 1)) || return 1
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$bumped]")" == '[]' ]] || return 1
		login=runner-two
		_dispatch_skip_for_capability_cooldown "$bumped" 42 owner/repo '' && return 1
		login=runner-one
	done
	fixture_comments="$trusted_comments"
	return 0
}

test_worker_capability_cooldown() {
	local status=0
	if ! (
		# shellcheck source=../pulse-dispatch-lib-candidates.sh
		source "${SCRIPT_DIR}/pulse-dispatch-lib-candidates.sh"
		HOME="$TEST_ROOT/capability-home"
		LOGFILE="$TEST_ROOT/capability-pulse.log"
		_DISPATCH_ELIGIBILITY_INELIGIBLE=ineligible
		_DISPATCH_VALUE_UNKNOWN=unknown
		_DISPATCH_CAPABILITY_COOLDOWN_TTL_SECONDS=21600
		_dispatch_stats_increment() { return 0; }
		local fixture_issue='{"title":"Fix native test","body":"### Files Scope\n- helper.sh"}'
		local candidate='{"number":42,"repo_slug":"owner/repo","repo_path":"","updatedAt":"2026-10-18T12:00:00Z","labels":[]}'
		local revision="" fingerprint="" fragment="" fixture_comments="" login=runner-one now="" filtered="" changed=""
		local fixture_reads=true
		now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 '' runner_capability_unmet)
		fingerprint=$(_terminal_blocker_hash v2:runner_capability_unmet)
		fragment=$(terminal_blocker_observation_fragment "$revision" "$fingerprint" first)
		fixture_comments=$(jq -nc --arg body "$fragment" --arg now "$now" \
			'[{id:1,user:{login:"runner-one"},author_association:"COLLABORATOR",body:$body,created_at:$now}]')
		gh() {
			local operation="$1" endpoint="$2"
			[[ "$operation" == api ]] || return 1
			[[ "$endpoint" == user || "$fixture_reads" == true ]] || return 1
			case "$endpoint" in
			user) printf '%s\n' "$login" ;;
			repos/owner/repo/issues/42) printf '%s\n' "$fixture_issue" ;;
			repos/owner/repo/issues/42/comments*) printf '%s\n' "$fixture_comments" ;;
			*) return 1 ;;
			esac
			return 0
		}
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' || exit 1
		filtered=$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")
		[[ "$filtered" == '[]' ]] || exit 1
		rg -q 'runner_capability_unmet cooldown recorded signal=worker_observation' "$LOGFILE" || exit 1
		# Cached passes only verify the login, not refetch issues/comments or
		# refresh the observation TTL.
		local original="" retained=""
		original=$(<"$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42")
		fixture_reads=false
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' || exit 1
		retained=$(<"$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42")
		[[ "$original" == "$retained" ]] || exit 1
		login=runner-two
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")" == "[$candidate]" ]] || exit 1
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		login=runner-one
		fixture_reads=true
		_capability_cooldown_own_contributor_replay || exit 1
		# Selection rejects a different runner, edited brief, later different
		# blocker, and explicit retry without a global hold; it accepts the
		# runner's own comment whatever association GitHub reports.
		fixture_comments=$(jq -c 'map(.author = .user.login)' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-two terminal_blocker_runner_capability_observation_epoch \
			"$fixture_comments" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c 'map(.author_association="CONTRIBUTOR")' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 >/dev/null || exit 1
		changed=$(jq -c 'map(.author_association="CONTRIBUTOR" | .author="runner-two")' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$fixture_comments" '{"title":"Fix native test","body":"changed"}' owner/repo 42 && exit 1
		changed=$(jq -c --arg blocker "$(_terminal_blocker_hash v2:target_code_blocker)" \
			'. + [ (.[0] | .id=2 | .body |= sub("blocker=[a-f0-9]{24}"; "blocker=" + $blocker)) ]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c '. + [{id:2,author:"maintainer",author_association:"OWNER",created_at:.[0].created_at,body:"terminal-blocker-circuit:retry"}]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c '. + [(.[0] | .id=2 | .author="runner-two" | .author_association="OWNER")]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 >/dev/null || exit 1
		HOME="$TEST_ROOT/other-runner"
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")" == "[$candidate]" ]] || exit 1
		fixture_comments=$(jq -c 'map(.created_at="2020-01-01T00:00:00Z")' <<<"$fixture_comments")
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		fixture_comments=$(jq -c 'map(.created_at="2999-01-01T00:00:00Z")' <<<"$fixture_comments")
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		exit 0
	); then
		status=1
	fi
	print_result "worker observation cools only its own runner and enumeration reuses bounded trusted evidence" "$status"
	return 0
}

test_verification_environment_alias() {
	local output="$TEST_ROOT/environment-alias.jsonl" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: native test binary absent\nTERMINAL_BLOCKER_REASON=verification_environment_missing_prerequisites"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == runner_capability_unmet ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: unknown\nTERMINAL_BLOCKER_REASON=some_other_environment_problem"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	print_result "only exact allowlisted environment alias becomes runner capability" "$status"
	return 0
}

test_target_code_blocker_observation_rearms() {
	local status=0 issue='{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}'
	local fingerprint="" revision="" comments="" held=0
	fingerprint=$(_terminal_blocker_hash 'v2:target_code_blocker')
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" target_code_blocker) || status=1
	comments=$(jq -nc --arg body "Terminal blocker: reason=target_code_blocker owner=target-maintainer
<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{id:5,body:$body,author_association:"MEMBER",created_at:"2026-10-16T23:00:00Z"}]')
	# Same target revision: still held.
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	# Target code changed: re-armed.
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	# Trusted OWNER retry after the observation re-arms an unchanged revision.
	terminal_blocker_observation_hold_active "$(jq -c '. + [{id:6,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-16T23:30:00Z"}]' <<<"$comments")" \
		"$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	# An unreadable target revision fails closed (rc 2), never releases.
	TEST_TARGET_REVISION=unavailable
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || held=$?
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	[[ "$held" -eq 2 ]] || status=1
	# Other hold labels keep the release helper from touching the issue.
	(
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local touched=""
		set_issue_status() { touched="x"; return 0; }
		_tbr_release_circuit_hold owner/repo 42 '{"labels":[{"name":"status:blocked"},{"name":"needs-maintainer-review"}]}' "$comments"
		_tbr_release_circuit_hold owner/repo 42 '{"labels":[{"name":"status:blocked"},{"name":"needs-maintainer-permissions"}]}' "$comments"
		[[ -z "$touched" ]]
	) || status=1
	print_result "target_code_blocker first observation holds at same revision, re-arms on target change or retry" "$status"
	return 0
}

# GH#35290: exercise the real CLI and timeout boundary with inherited GitHub
# fixtures, not a replacement pending implementation. No live queue is touched.
_bounded_seed_resume_checks() {
	local rc=0
	# Seed resumes after a slow candidate; newly seeded entries cannot
	# masquerade as empty intake. Reuse the caller's isolated GitHub fixture.
	export TB_SEED=1 BLOCKER_RECOVERY_STAGE_SECONDS=2 BLOCKER_RECOVERY_BUDGET_SECONDS=6
	rm -f "${TBR_ROOT}/queue/owner--repo--42.json"
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && "$(<"${TBR_ROOT}/seed-owner--repo.cursor")" == 1 ]] || return 1
	rc=0
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || return 1
	[[ "$(<"${TBR_ROOT}/err")" == *'reason=unobserved_entries'* && ! -f "${TBR_ROOT}/last_seed_epoch" ]] || return 1
	export TB_SEED_FAST=1
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" seed >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || return 1
	[[ -f "${TBR_ROOT}/last_seed_epoch" ]] || return 1
	# A failed remote-policy observation is not permission to retire evidence.
	(
		_tbr_policy_enabled() { return 2; }
		tbr_enqueue owner/repo 42 files_scope_excluded policy_remote || exit 1
		rc=0
		_tbr_check_entry "${TBR_ROOT}/queue/owner--repo--42.json" >/dev/null || rc=$?
		[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--42.json" && -f "${TBR_ROOT}/decisions/owner--repo--42.json" ]]
	) || return 1
	return 0
}

test_bounded_recovery_intake() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/bounded-intake"
		TBR_REPOS_JSON="${TEST_ROOT}/bounded-repos.json"
		export TB_INTAKE_FIXTURE="$TBR_ROOT" WORKER_GITHUB_LOGIN=runner-one TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT" REPOS_JSON="$TBR_REPOS_JSON"
		export BLOCKER_RECOVERY_STAGE_SECONDS=1 BLOCKER_RECOVERY_BUDGET_SECONDS=1
		_tbr_init_dirs || exit 1
		printf '{"initialized_repos":[{"slug":"owner/repo"}]}\n' >"$TBR_REPOS_JSON"
		date +%s >"${TBR_ROOT}/last_seed_epoch"
		local fixture_brief='{"title":"Held integration","body":"### Files Scope\n- helper.sh"}' revision=""
		revision=$(terminal_blocker_task_revision "$fixture_brief" owner/repo 42 "" files_scope_excluded) || exit 1
		jq -nc --argjson brief "$fixture_brief" '$brief + {state:"open",labels:[{name:"status:blocked"}]}' >"${TBR_ROOT}/issue.json"
		jq -nc --arg body "Terminal blocker: reason=files_scope_excluded owner=brief-author
<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=$(_terminal_blocker_hash 'v2:files_scope_excluded') -->" \
			'[[{id:7,body:$body,user:{login:"runner-one"},author_association:"MEMBER",created_at:"2026-10-16T23:32:17Z"}]]' >"${TBR_ROOT}/comments.json"
		gh() {
			local args="$*"
			printf '%s\n' "$args" >>"${TB_INTAKE_FIXTURE}/requests"
			case "$args" in
			"api repos/owner/repo/issues/1" | "api repos/owner/repo/issues/1/comments?per_page=100 --paginate --slurp")
				[[ "${TB_SEED_FAST:-0}" -eq 0 ]] || { printf '[]\n'; return 0; }
				sleep 5
				return 1
				;;
			"api repos/owner/repo/issues/2") printf '{"state":"closed"}\n' ;;
			"api repos/owner/repo/issues/42") jq -c . "${TB_INTAKE_FIXTURE}/issue.json" ;;
			"api repos/owner/repo/issues/42/comments?per_page=100 --paginate --slurp") jq -c . "${TB_INTAKE_FIXTURE}/comments.json" ;;
			"api repos/owner/repo")
				[[ "${TB_SEED:-0}" -eq 1 ]] || return 1
				printf '{"permissions":{"push":true},"default_branch":"main"}\n'
				;;
			"api -X GET repos/owner/repo/commits"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
			"api -X GET repos/owner/repo/contents/.aidevops.json"*) printf 'HTTP 404\n' >&2; return 1 ;;
			"api -X GET search/issues"*)
				[[ "${TB_SEED:-0}" -eq 1 ]] || return 1
				printf '1\n42\n'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		export -f gh
		tbr_enqueue owner/repo 1 permission_required || exit 1
		tbr_enqueue owner/repo 2 permission_required || exit 1
		tbr_enqueue owner/repo 42 files_scope_excluded || exit 1
		printf '{"wake":"brief_revision","next_action":"hold unchanged brief","evidence":"fixture"}\n' |
			tbr_record owner/repo 42 || exit 1
		local rc=0 started="$SECONDS" decision=""
		decision=$(jq -c . "${TBR_ROOT}/decisions/owner--repo--42.json")
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && $((SECONDS - started)) -le 3 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ "$(<"${TBR_ROOT}/err")" == *'incomplete stage=entry'* && "$(<"${TBR_ROOT}/err")" == *'stage=entry_issue'* ]] || exit 1
		[[ "$(<"${TBR_ROOT}/pending_cursor")" == owner--repo--1.json && -f "${TBR_ROOT}/queue/owner--repo--1.json" ]] || exit 1
		# Resume past the stalled entry: retire closed entries and suppress an
		# unchanged held decision, then wrap and retry (not delete) the slow one.
		export BLOCKER_RECOVERY_BUDGET_SECONDS=4
		rc=0
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending --count >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && "$(<"${TBR_ROOT}/out")" == 0 ]] || exit 1
		[[ ! -f "${TBR_ROOT}/queue/owner--repo--2.json" && -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || exit 1
		[[ "$(jq -c . "${TBR_ROOT}/decisions/owner--repo--42.json")" == "$decision" ]] || exit 1
		# With only the unchanged held entry, observation is complete and empty.
		rm -f "${TBR_ROOT}/queue/owner--repo--1.json"
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || exit 1
		[[ ! -s "${TBR_ROOT}/out" ]] || exit 1
		# Seed failures are explicit too, and never stamp an incomplete scan.
		rm -f "${TBR_ROOT}/last_seed_epoch"
		printf '{"initialized_repos":[{"slug":"owner/repo","pulse":true}]}\n' >"$TBR_REPOS_JSON"
		rc=0
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && ! -f "${TBR_ROOT}/last_seed_epoch" ]] || exit 1
		[[ "$(<"${TBR_ROOT}/err")" == *'incomplete stage=seed'* ]] || exit 1
		_bounded_seed_resume_checks || exit 1
		_default_budget_progress_checks || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "bounded intake resumes past stalled reads, preserves held decisions, and distinguishes incomplete from empty" "$status"
	return 0
}

# Exercise two real default-budget CLI calls with 25 entries, not a substituted
# pending loop. Slow closed entries consume the first pass; the cursor must let
# the next pass reach actionable entries beyond the first ten.
