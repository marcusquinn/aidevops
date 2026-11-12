#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Session, blocked-completion and terminal-reconciliation tests.

# Sourced by test-headless-runtime-provider-tests.sh; not run directly.
[[ -n "${_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_SESSION_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_SESSION_LOADED=1

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

test_stale_session_retry_clears_continuation_state() {
	local state_file="${TEST_ROOT}/stale-session-retry-state"
	local output_path="${TEST_ROOT}/stale-session-output"
	local exit_path="${TEST_ROOT}/stale-session-exit"
	local state=""
	printf '%s\n' "Session not found" >"$output_path"

	state=$(
		local exit_code=1 runtime="opencode" persisted_session="ses_stale"
		local _invoke_persisted_session="ses_stale" _WORKER_PERSISTED_SESSION_ID="ses_stale"
		local output_file="$output_path" exit_code_file="$exit_path"
		local session_key="issue-30153" provider="openai" role="worker"
		local selected_model="openai/test" work_dir="$TEST_ROOT" prompt_arg="prompt" title="title"
		local variant_override="" agent_name="build" _metric_kill_reason="" _run_watchdog_hard_killed=0
		local -a cmd=() extra_args=()
		clear_session_id() { return 0; }
		_create_headless_runtime_temp_file() {
			mktemp "${TEST_ROOT}/stale-session-retry.XXXXXX"
			return $?
		}
		_register_headless_runtime_output_temp_path() { return 0; }
		_register_headless_runtime_temp_path() { return 0; }
		_build_run_cmd() {
			printf '%s\0' "opencode" "run"
			return 0
		}
		_begin_worker_runtime_run() { return 0; }
		_invoke_opencode() {
			local invoke_output="$1"
			local invoke_exit="$2"
			: "$invoke_output"
			printf '%s' "0" >"$invoke_exit"
			printf '%s|%s|%s' "${_invoke_persisted_session:-}" "${_WORKER_PERSISTED_SESSION_ID:-}" "${persisted_session:-}" >"$state_file"
			return 0
		}
		_normalize_worker_exit_code_and_kill_reason() {
			printf '0\tunknown\n'
			return 0
		}
		_retry_run_attempt_without_stale_session >/dev/null
		printf '%s|%s' "$(<"$state_file")" "$exit_code"
	)

	if [[ "$state" == "|||0" ]]; then
		print_result "stale session retry clears continuation seeding and classification state" 0
		return 0
	fi
	print_result "stale session retry clears continuation seeding and classification state" 1 "state=${state:-<empty>}"
	return 0
}

test_db_seed_failure_starts_fresh_opencode_session() {
	local state=""
	state=$(
		local persisted_session="ses_stale"
		local _invoke_persisted_session="ses_stale" _WORKER_PERSISTED_SESSION_ID="ses_stale"
		local _invoke_provider="openai" _invoke_session_key="issue-30328"
		local cleared_provider="" cleared_key=""
		local isolated_data_dir="${TEST_ROOT}/failed-seed-isolation"
		local runtime_role="worker" public_triage=0 private_workload=0
		local -a cmd=(opencode run prompt --session ses_stale --continue --title title)
		clear_session_id() {
			cleared_provider="$1"
			cleared_key="$2"
			return 0
		}
		_headless_run_is_ephemeral() { return 0; }
		_sync_worker_db_migration_metadata() { return 0; }
		_seed_worker_db_session_context() { return 1; }
		print_info() { return 0; }
		print_warning() { return 0; }
		_invoke_opencode_export_isolation >/dev/null
		printf '%s|%s|%s|%s|%s' "${cmd[*]}" "$persisted_session" "$_invoke_persisted_session" \
			"$_WORKER_PERSISTED_SESSION_ID" "${cleared_provider}:${cleared_key}"
	)

	if [[ "$state" == "opencode run prompt --title title||||openai:issue-30328" ]]; then
		print_result "DB seed failure removes stale continuation command state" 0
		return 0
	fi
	print_result "DB seed failure removes stale continuation command state" 1 "state=${state:-<empty>}"
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
	[[ "$rc" -eq 83 && "${_run_result_label:-}" == "blocked" && "${_run_failure_reason:-}" == "blocked" && "${_run_classification_source:-}" == "model_blocked_signal" && "${_run_classification_pattern:-}" == "terminal_blocked" && "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}" =~ ^[a-f0-9]{24}$ && ! -f "$output_file" ]] && {
		print_result "generic BLOCKED signal remains terminal without capability escalation" 0
		return 0
	}
	print_result "generic BLOCKED signal remains terminal without capability escalation" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} source=${_run_classification_source:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

test_manual_dispatch_blocked_completion_records_blocked_label() {
	local output_file="${TEST_ROOT}/manual-blocked-output.jsonl"
	local WORKER_ISSUE_NUMBER="456"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing files scope\nTERMINAL_BLOCKER_REASON=missing_files_scope"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "manual-cli-456-1789490308" "openai/gpt-5.5" || rc=$?
	if [[ "$rc" -eq 83 && "${_run_result_label:-}" == "blocked" &&
		"${_run_classification_pattern:-}" == "terminal_blocked" && ! -f "$output_file" ]]; then
		print_result "manual issue dispatch preserves terminal BLOCKED outcome" 0
		return 0
	fi
	print_result "manual issue dispatch preserves terminal BLOCKED outcome" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

# GH#33274: a quoted BLOCKED mention in a continuation summary must not turn a
# resumable progress report into a terminal blocker.
test_quoted_blocked_mention_continues() {
	local output_file="${TEST_ROOT}/quoted-blocked-output.jsonl"
	# shellcheck disable=SC2016 # literal backticks are fixture markdown
	printf '%s\n' \
		'{"type":"text","part":{"type":"text","text":"## Objective\n- Proceed through merge; stop only at `FULL_LOOP_COMPLETE` or `BLOCKED` with evidence."}}' \
		'{"type":"text","part":{"type":"text","synthetic":true,"text":"BLOCKED: injected by runtime"}}' \
		'{"type":"text","part":{"type":"text","text":"Progress so far is research.\n\nNext steps:\n1. Find the fee PDF."}}' >"$output_file"
	local result=0
	if output_has_blocked_signal "$output_file" || output_has_completion_signal "$output_file"; then
		result=1
	fi
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 77 && "${_run_result_label:-}" == "premature_exit" ]] || result=1
	print_result "quoted or synthetic BLOCKED mention continues instead of terminal blocked" "$result" \
		"rc=$rc label=${_run_result_label:-<unset>}"
	return 0
}

test_anchored_blocked_shapes_are_terminal() {
	local bold_file="${TEST_ROOT}/bold-blocked.jsonl"
	local claude_file="${TEST_ROOT}/claude-blocked.jsonl"
	local plain_file="${TEST_ROOT}/plain-blocked.txt"
	printf '%s\n' '{"type":"text","part":{"type":"text","text":"Summary of work.\n\n**BLOCKED** — cannot proceed without the fee PDF."}}' >"$bold_file"
	printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"BLOCKED: missing dependency credentials"}]}}' >"$claude_file"
	printf '%s\n' 'Work summary' 'BLOCKED: missing dependency credentials' >"$plain_file"
	local result=0 file=""
	for file in "$bold_file" "$claude_file" "$plain_file"; do
		output_has_blocked_signal "$file" || result=1
		output_has_completion_signal "$file" || result=1
	done
	local promise_file="${TEST_ROOT}/promise-complete.jsonl"
	printf '%s\n' '{"type":"text","part":{"type":"text","text":"Merged and cleaned.\n<promise>FULL_LOOP_COMPLETE</promise>"}}' >"$promise_file"
	output_has_completion_signal "$promise_file" || result=1
	output_has_blocked_signal "$promise_file" && result=1
	print_result "anchored BLOCKED lines and bare completion markers remain terminal" "$result"
	return 0
}

run_blocked_completion_tests() {
	test_blocked_completion_records_blocked_label
	test_manual_dispatch_blocked_completion_records_blocked_label
	test_quoted_blocked_mention_continues
	test_anchored_blocked_shapes_are_terminal
	test_clean_exit_terminal_state_reconciliation
	test_pr_less_terminal_proof_survives_finalization
	test_own_merged_terminal_reconciliation
	test_scoped_delivery_terminal_reconciliation
	return 0
}

# GH#35647: real verifier subprocess and classifier, synthetic forge evidence.
test_scoped_delivery_terminal_reconciliation() {
	local shape result
	for shape in complete partial open unrelated dirty ahead reverted_default stale_attempt wrong_repo wrong_issue stale_head stale_issue bare_claim; do
		result=0
		if ! (
			local WORKER_ISSUE_NUMBER=456 DISPATCH_REPO_SLUG=owner/repo
			local AIDEVOPS_ATTEMPT_ID=fixture AIDEVOPS_ATTEMPT_STARTED_AT=1792929600000000000
			local work_dir="${TEST_ROOT}/scoped-${shape}" output_file="${TEST_ROOT}/scoped-output.jsonl" rc=0 expected=77
			local SCOPED_SHAPE="$shape" SCOPED_HEAD
			export SCOPED_SHAPE SCOPED_HEAD AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT
			_setup_test_git_repo "$work_dir" 0
			printf 'review artifact\n' >"$work_dir/artifact.md"
			git -C "$work_dir" add artifact.md
			git -C "$work_dir" commit -qm artifact
			git -C "$work_dir" push -q origin HEAD:main
			SCOPED_HEAD=$(git -C "$work_dir" rev-parse HEAD)
			_hrw_own_merged_terminal_complete() { return 1; }
			_hrw_resolve_default_branch() { printf main; return 0; }
			gh() {
				case "$*" in
				"issue edit 456 --repo owner/repo "*) return 0 ;;
				"api repos/owner/repo/issues/456")
					jq -cn --arg shape "$SCOPED_SHAPE" '{number:456,state:"closed",state_reason:"completed",
						author_association:"COLLABORATOR",updated_at:"2026-10-25T12:00:00Z",
						body:"### Files Scope\n- `README.md`\n- `artifact.md`\n"}
						| if $shape == "open" then .state = "open" else . end' ;;
				"pr list"*)
					if [[ "$*" == *--head* ]]; then printf '0\n'; else printf '42\n'; fi ;;
				"pr view"*) printf '{"state":"MERGED","mergedAt":"2026-10-25T11:00:00Z","closingIssuesReferences":[]}\n' ;;
				"api repos/owner/repo/pulls/42")
					jq -cn --arg head "$SCOPED_HEAD" --arg shape "$SCOPED_SHAPE" '{number:42,state:"closed",
						merged_at:"2026-10-25T11:00:00Z",merge_commit_sha:$head,
						base:{repo:{full_name:"owner/repo"}},body:"For #456"}
						| if $shape == "unrelated" then .body = "For #789" else . end' ;;
				"api --paginate repos/owner/repo/pulls/42/files?per_page=100"*)
					printf 'README.md\n'
					[[ "$SCOPED_SHAPE" == partial || "$SCOPED_SHAPE" == bare_claim ]] || printf 'artifact.md\n' ;;
				*) return 1 ;;
				esac
				return 0
			}
			export -f gh
			# Tamper only with subprocess output to prove runtime identity checks.
			bash() {
				command bash "$@" | jq -c --arg shape "$SCOPED_SHAPE" '
					if $shape == "stale_attempt" then .attempt_id = "older"
					elif $shape == "wrong_repo" then .repository = "other/repo"
					elif $shape == "wrong_issue" then .issue = 789
					elif $shape == "stale_head" then .head = ("f" * 40)
					elif $shape == "stale_issue" then .issue_updated_at = "older"
					else . end'
				return "${PIPESTATUS[0]}"
			}
			case "$shape" in
			complete) expected=0 ;;
			dirty) touch "$work_dir/unpublished" ;;
			ahead) touch "$work_dir/unpublished"; git -C "$work_dir" add unpublished; git -C "$work_dir" commit -qm unpublished ;;
			reverted_default)
				printf 'reverted artifact\n' >"$work_dir/artifact.md"
				git -C "$work_dir" add artifact.md
				git -C "$work_dir" commit -qm reverted
				git -C "$work_dir" push -q origin HEAD:main
				git -C "$work_dir" checkout -qb behind "$SCOPED_HEAD" ;;
			esac
			printf '%s\n' '{"type":"text","text":"The objective was already delivered; no new work was needed."}' >"$output_file"
			_handle_run_result 0 "$output_file" worker openai issue-456 openai/gpt-5.5 "$work_dir" || rc=$?
			[[ "$rc" == "$expected" ]] || exit 1
			if [[ "$expected" == 0 ]]; then
				[[ "$_run_result_label" == success && "$_run_classification_source" == scoped_delivery_receipt && -z "$_run_failure_reason" ]] || exit 1
				_hrw_release_dispatch_claim() { return 0; }
				_hrw_permission_pending_path() { return 1; }
				_worker_produced_output() { exit 1; }
				_hrw_finish_success_run issue-456 "$work_dir" || exit 1
				[[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]] || exit 1
			else
				[[ "$_run_result_label" == premature_exit ]] || exit 1
			fi
		); then result=1; fi
		print_result "scoped delivery ${shape}: verified no-work or premature exit" "$result"
	done
	return 0
}

# Synthetic external evidence for GH#35629; no API calls or original sessions.
_setup_own_merged_evidence() {
	local shape="$1"
	jq -cn --arg head "$head" --arg branch "$branch" --arg shape "$shape" \
		--arg merge "${merge_head:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" '
		{number:42,state:"MERGED",mergedAt:"2026-10-25T12:01:00Z",
		mergeCommit:{oid:$merge},headRefOid:$head,headRefName:$branch,
		headRepository:{name:"repo",nameWithOwner:"owner/repo"},headRepositoryOwner:{login:"owner",name:"Synthetic Owner"},
		closingIssuesReferences:[{number:456,repository:{name:"repo",owner:{login:"owner"}}}]}
		| if $shape == "unmerged" then .state = "OPEN" | .mergedAt = null
		elif $shape == "unrelated" then .closingIssuesReferences[0].number = 789
		elif $shape == "cross_repo" then .closingIssuesReferences[0].repository.owner.login = "other"
		elif $shape == "foreign_head" then .headRepositoryOwner.login = "other"
		elif $shape == "head_mismatch" then .headRefOid = ("c" * 40)
		elif $shape == "branch_mismatch" then .headRefName = "other"
		elif $shape == "stale_merge" then .mergedAt = "2026-10-24T12:00:00Z"
		elif $shape == "unverified" then .mergeCommit = null
		else . end' >"$pr_file"
	jq -cn --arg worktree "$work_dir" --arg branch "$branch" --arg shape "$shape" \
		--arg deferred "$_FULL_LOOP_CLEANUP_DEFERRED" --arg leased "$_FULL_LOOP_CLEANUP_LEASED" '
		{schema_version:1,repository:"owner/repo",pr_number:42,worktree:$worktree,branch:$branch,
		owner:{session:"ses_own_merged",pid:123,process_identity:"synthetic-owner"},
		created_at:"2026-10-25T12:02:00Z",executor_completion_state:"COMPLETE",
		resource_cleanup_state:$deferred,release_status:"not-requested"}
		| if $shape == "stale_receipt" then .created_at = "2026-10-24T12:00:00Z"
		elif $shape == "fractional_receipt" then .created_at = "2026-10-25T12:02:00.813577Z"
		elif $shape == "stale_fractional_receipt" then .created_at = "2026-10-24T12:00:00.813577Z"
		elif $shape == "invalid_receipt_date" then .created_at = "not-a-date"
		elif $shape == "foreign_session" then .owner.session = "ses_foreign"
		elif $shape == "foreign_receipt" then .repository = "other/repo"
		elif $shape == "receipt_branch" then .branch = "other"
		elif $shape == "receipt_pr" then .pr_number = 43
		elif $shape == "receipt_worktree" then .worktree = "/unrelated"
		elif $shape == "receipt_owner" then .owner.process_identity = null
		elif $shape == "receipt_pid" then .owner.pid = 0
		elif $shape == "cleanup_failed" then .resource_cleanup_state = "FAILED"
		elif $shape == "leased" then .resource_cleanup_state = $leased
		elif $shape == "published" then .release_status = "published"
		elif $shape == "superseded" then .release_status = "superseded"
		elif $shape == "unfinalized" then .executor_completion_state = "FINALIZATION_PENDING"
		elif $shape == "release_pending" then .release_status = "pending"
		else . end' >"$receipt_file"
	case "$shape" in
	unreadable) printf 'not json\n' >"$receipt_file" ;;
	missing_receipt) rm "$receipt_file" ;;
	dirty) touch "${work_dir}/unpublished.txt" ;;
	cleanup_marker)
		# GH#37597: full-loop-helper.sh merge leaves this runtime-only marker.
		mkdir -p "${work_dir}/.agents"
		printf '123\n' >"${work_dir}/.agents/.full-loop-cleanup-deferred"
		;;
	esac
	return 0
}

_setup_merged_continuation_git() {
	local shape="$1" continued="$2" work_dir="$3" branch="$4" head="$5"
	if [[ "$continued" == 1 && "$shape" == squash ]]; then
		# Publish a real squash: the delivered head is not an ancestor of
		# default, but its tree and the merged PR's head are published.
		# Set the caller's merge_head for the synthetic GitHub PR evidence.
		merge_head=$(git -C "$work_dir" commit-tree "HEAD^{tree}" -p origin/main -m squash) || return 1
		git -C "$work_dir" push -q origin "${merge_head}:refs/heads/main" "$branch" || return 1
		[[ "$(git -C "$work_dir" rev-list --count "${merge_head}..${head}")" != 0 ]] || return 1
	fi
	if [[ "$shape" == ahead || "$shape" == remote_ahead ]]; then
		# Clean but genuinely unpublished work beyond the delivered head.
		touch "${work_dir}/unpublished.txt"
		git -C "$work_dir" add unpublished.txt || return 1
		git -C "$work_dir" commit -qm unpublished || return 1
		if [[ "$shape" == remote_ahead ]]; then
			git -C "$work_dir" push -q origin "$branch" || return 1
			git -C "$work_dir" checkout -q -B "$branch" "$head" || return 1
		fi
	fi
	return 0
}

test_own_merged_terminal_reconciliation() {
	local shape="" result=0
	for shape in squash issue leased published superseded fractional_receipt stale_fractional_receipt invalid_receipt_date open unmerged unrelated cross_repo foreign_head head_mismatch branch_mismatch stale_merge unverified stale_receipt foreign_session foreign_receipt receipt_branch receipt_pr receipt_worktree receipt_owner receipt_pid cleanup_failed unfinalized release_pending unreadable missing_receipt dirty cleanup_marker api_failure missing_session synthetic tool silent continuation_squash continuation_cleanup_marker continuation_issue continuation_fractional_receipt continuation_stale_receipt continuation_stale_fractional_receipt continuation_invalid_receipt_date continuation_foreign_session continuation_foreign_receipt continuation_receipt_branch continuation_receipt_pr continuation_receipt_worktree continuation_receipt_owner continuation_receipt_pid continuation_cleanup_failed continuation_unfinalized continuation_release_pending continuation_missing_receipt continuation_dirty continuation_ahead continuation_remote_ahead continuation_unrelated continuation_cross_repo continuation_foreign_head continuation_head_mismatch continuation_branch_mismatch continuation_open continuation_unmerged continuation_api_failure continuation_missing_session continuation_same_second; do
		if ! (
			local WORKER_ISSUE_NUMBER=456 DISPATCH_REPO_SLUG="owner/repo"
			local AIDEVOPS_ATTEMPT_ID="attempt:synthetic" AIDEVOPS_ATTEMPT_STARTED_AT=1792929600000000000
			local work_dir="${TEST_ROOT}/own-merged-${shape}" branch="" head="" merge_head=""
			local expected_pattern="verified_own_merged_objective" continued=0
			if [[ "$shape" == continuation_* ]]; then
				shape="${shape#continuation_}"
				continued=1
				AIDEVOPS_ATTEMPT_ID="attempt:continuation"
				AIDEVOPS_ATTEMPT_STARTED_AT=1793016000000000000
				expected_pattern="verified_prior_merged_objective"
			fi
			local pr_file="${TEST_ROOT}/own-pr.json" receipt_file="${TEST_ROOT}/own-receipt.json"
			local output_file="${TEST_ROOT}/own-output.jsonl" api_available=1 rc=0 expected=77
			local session_key="manual-cli-456-1792929600"
			_setup_test_git_repo "$work_dir" 1
			# Guarded cleanup receipts use physical paths, including when macOS
			# exposes the temporary root through /var -> /private/var.
			work_dir=$(cd "$work_dir" && pwd -P) || exit 1
			branch=$(git -C "$work_dir" branch --show-current)
			head=$(git -C "$work_dir" rev-parse HEAD)
			_setup_merged_continuation_git "$shape" "$continued" "$work_dir" "$branch" "$head" || exit 1
			_setup_own_merged_evidence "$shape"
			_hrw_pr_less_terminal_complete() { return 1; }
			_full_loop_cleanup_receipt_path() { printf '%s' "$receipt_file"; return 0; }
			gh_pr_list() { jq -s '.' "$pr_file"; return 0; }
			gh() {
				local resource="$1" action="$2"
				[[ "$api_available" == 1 && "$shape" != api_failure ]] || return 1
				case "${resource}:${action}" in
				api:repos/owner/repo/issues/456)
					case "$shape" in
					open | synthetic | tool | silent) printf '{"state":"open"}\n' ;;
					*) printf '{"state":"closed","state_reason":"completed"}\n' ;;
					esac ;;
				api:repos/owner/repo/pulls/42) printf 'Resolves #456\n' ;;
				api:--paginate) printf '[[{"body":"<!-- MERGE_SUMMARY -->"}]]\n' ;;
				pr:view) jq '.' "$pr_file" ;;
				*) return 1 ;;
				esac
				return 0
			}
			printf '%s\n' '{"type":"tool_result","text":"bounded wrapper completed"}' \
				'{"type":"text","sessionID":"ses_own_merged","text":"Delivered, merged, synchronized and finalized guarded cleanup."}' >"$output_file"
			if [[ "$continued" == 1 ]]; then
				printf '%s\n' '{"type":"text","sessionID":"ses_own_merged","text":"Verified the prior merged delivery and closed the issue. No new changes."}' >"$output_file"
			fi
			case "$shape" in
			squash | leased | published | superseded | fractional_receipt | cleanup_marker) expected=0 ;;
			issue) expected=0; session_key="issue-456" ;;
			stale_merge)
				expected=0
				expected_pattern="verified_prior_merged_objective"
				;;
			same_second)
				expected=0
				# 1792929660.9s truncates to 2026-10-25T12:01:00Z, matching
				# the default mergedAt in _setup_own_merged_evidence.
				AIDEVOPS_ATTEMPT_STARTED_AT=1792929660900000000
				;;
			missing_session) printf '{"type":"text","text":"Delivered."}\n' >"$output_file" ;;
			synthetic) printf '{"type":"text","part":{"synthetic":true,"text":"FULL_LOOP_COMPLETE"}}\n' >>"$output_file" ;;
			tool) printf '{"type":"tool_result","text":"FULL_LOOP_COMPLETE"}\n' >>"$output_file" ;;
			esac
			_handle_run_result 0 "$output_file" worker openai "$session_key" openai/gpt-5.5 "$work_dir" || rc=$?
			[[ "$rc" == "$expected" ]] || exit 1
			if [[ "$expected" == 0 ]]; then
				[[ "$_run_result_label" == success && "$_run_classification_pattern" == "$expected_pattern" && -z "$_run_failure_reason" ]] || exit 1
				if [[ "$continued" == 1 || "$shape" == stale_merge ]]; then
					[[ "$_run_classification_source" == merged_pr_continuation_evidence ]] || exit 1
					# Delivery by a prior attempt must never become own-merge proof.
					if _hrw_own_merged_terminal_complete "$session_key" "$work_dir"; then exit 1; fi
				fi
				# Finalization has no dynamically scoped discovered_session and may
				# see an API outage. It must retain this exact attempt's proof.
				api_available=0
				_hrw_release_dispatch_claim() { return 0; }
				_hrw_permission_pending_path() { return 1; }
				_worker_produced_output() { exit 1; }
				_hrw_finish_success_run "$session_key" "$work_dir" || exit 1
				[[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]] || exit 1
				touch "${work_dir}/new-edit"
				if _hrw_terminal_objective_complete "$session_key" "$work_dir"; then exit 1; fi
				rm "${work_dir}/new-edit"
				AIDEVOPS_ATTEMPT_ID="attempt:next"
				if _hrw_terminal_objective_complete "$session_key" "$work_dir"; then exit 1; fi
			else
				[[ "$_run_result_label" == premature_exit ]] || exit 1
			fi
		); then result=1; fi
		print_result "own merged objective ${shape}: exact proof or fail closed" "$result"
		result=0
	done
	return 0
}

# GH#33672: exercise the real success-output classifier and shared PR-less
# verifier. Stub only external state and cleanliness; no network or resume calls.
test_clean_exit_terminal_state_reconciliation() {
	local shape="" result=0
	for shape in blocked delivered consolidation silent open untrusted unrelated cross_repo dirty api_failure partial; do
		if ! (
			local WORKER_ISSUE_NUMBER="456" DISPATCH_REPO_SLUG="owner/repo"
			local output_file="${TEST_ROOT}/terminal-${shape}.jsonl"
			local work_dir="${TEST_ROOT}" rc=0 expected_rc=77 expected_label="premature_exit"
			local issue_state="closed" association="COLLABORATOR" closing_number=456
			local closing_owner="owner"
			case "$shape" in
			blocked)
				printf '%s\n' '{"type":"text","text":"BLOCKED: prerequisite #123 remains open. Checkpoint preserved."}' >"$output_file"
				expected_rc=83 expected_label="blocked"
				;;
			consolidation)
				printf '%s\n' '{"type":"text","text":"Closed the parent and opened the consolidated successor spec. No code PR needed."}' >"$output_file"
				expected_rc=0 expected_label="success"
				;;
			delivered)
				printf '%s\n' '{"type":"text","text":"Already satisfied by an earlier merged PR. Nothing to push."}' >"$output_file"
				expected_rc=0 expected_label="success"
				;;
			*)
				printf '%s\n' '{"type":"text","text":"Investigation done; remainder needs a new run."}' >"$output_file"
				case "$shape" in
				silent | open | partial) issue_state="open" ;;
				untrusted) association="NONE" ;;
				unrelated) closing_number=789 ;;
				cross_repo) closing_owner="other" ;;
				esac
				;;
			esac
			_hrw_pr_less_worktree_clean() {
				[[ "$shape" != "dirty" ]] || return 1
				return 0
			}
			gh() {
				local resource="$1" action="$2" target="${3:-}"
				[[ "$shape" != "api_failure" ]] || return 1
				if [[ "$resource" == "api" && "$action" == "--paginate" ]]; then
					action="$target"
				fi
				case "${resource}:${action}" in
				api:repos/owner/repo/issues/456)
					if [[ "$shape" == "consolidation" ]]; then
						printf '%s\n' '{"state":"closed","state_reason":"completed","author_association":"COLLABORATOR","labels":[{"name":"consolidation-task"}],"body":"## Consolidation target: #123"}'
					else
						printf '{"state":"%s","state_reason":"completed","author_association":"%s"}\n' "$issue_state" "$association"
					fi
					;;
				api:repos/owner/repo/issues/456/comments?per_page=100)
					printf '%s\n' '[{"author_association":"COLLABORATOR","body":"Consolidation complete. Parent: #123 -> New: #789"}]'
					;;
				api:repos/owner/repo/issues/123)
					printf '%s\n' '{"state":"closed","labels":[{"name":"consolidated"}]}'
					;;
				api:repos/owner/repo/issues/789)
					printf '%s\n' '{"author_association":"COLLABORATOR","body":"Supersedes #123"}'
					;;
				pr:list)
					[[ "$shape" != "consolidation" ]] || return 1
					printf '%s\n' '42'
					;;
				issue:edit) [[ "$target" == 456 ]] || return 1 ;;
				pr:view)
					[[ "$target" == "42" ]] || return 1
					printf '{"state":"MERGED","mergedAt":"2026-10-05T00:00:00Z","closingIssuesReferences":[{"number":%s,"repository":{"name":"repo","owner":{"login":"%s"}}}]}\n' "$closing_number" "$closing_owner"
					;;
				*) return 1 ;;
				esac
				return 0
			}
			_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" "$work_dir" || rc=$?
			[[ "$rc" -eq "$expected_rc" && "${_run_result_label:-}" == "$expected_label" ]] || exit 1
		); then
			result=1
		fi
		print_result "clean worker exit reconciles ${shape} without false continuation" "$result"
		result=0
	done
	return 0
}

test_pr_less_terminal_proof_survives_finalization() {
	local result=0
	if ! (
		local WORKER_ISSUE_NUMBER="456" DISPATCH_REPO_SLUG="owner/repo"
		local work_dir="${TEST_ROOT}/terminal-proof-repo"
		local output_file="${TEST_ROOT}/terminal-proof.jsonl" api_available=1
		_setup_test_git_repo "$work_dir" 0
		_hrw_pr_less_worktree_clean() { return 0; }
		_hrw_release_dispatch_claim() { return 0; }
		_hrw_permission_pending_path() { return 1; }
		gh() {
			local resource="$1" action="$2"
			[[ "$api_available" == 1 ]] || return 1
			case "${resource}:${action}" in
			api:repos/owner/repo/issues/456)
				printf '%s\n' '{"state":"closed","state_reason":"completed","author_association":"COLLABORATOR"}'
				;;
			pr:list) printf '%s\n' '42' ;;
			issue:edit) return 0 ;;
			pr:view)
				printf '%s\n' '{"state":"MERGED","mergedAt":"2026-10-05T00:00:00Z","closingIssuesReferences":[{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]}'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		printf '%s\n' '{"type":"text","text":"Already delivered by an earlier merged PR."}' >"$output_file"
		_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" "$work_dir" || exit 1
		api_available=0
		_hrw_finish_success_run "issue-456" "$work_dir" || exit 1
		[[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]] || exit 1
		# Cached proof must never waive new unpublished work or leak to a new run.
		touch "${work_dir}/unpublished.txt"
		if _hrw_pr_less_terminal_complete "issue-456" "$work_dir" 456 "owner/repo"; then
			exit 1
		fi
		rm "${work_dir}/unpublished.txt"
		local exit_code=0
		printf '%s\n' '{"type":"text","text":"New attempt."}' >"$output_file"
		_initialize_run_result
		if _hrw_pr_less_terminal_complete "issue-456" "$work_dir" 456 "owner/repo"; then
			exit 1
		fi
	); then
		result=1
	fi
	print_result "PR-less proof survives later API failure but rejects edits and new attempts" "$result"
	return 0
}
