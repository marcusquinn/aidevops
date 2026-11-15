#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by the existing continuation test entrypoint, sharing its gh fixtures.
# shellcheck disable=SC2154

test_checkpoint_tier_selector() (
	local real_dir="$SCRIPT_DIR" SCRIPT_DIR="${TEST_ROOT}/tier-resolver"
	local head="1111111111111111111111111111111111111111" comments="" out="" mode=""
	mkdir -p "$SCRIPT_DIR"
	# shellcheck disable=SC2016 # The fixture evaluates its environment at execution.
	printf '#!/usr/bin/env bash\n[[ "${TIER_UNAVAILABLE:-0}" == 0 ]] || exit 1\nprintf "fixture/higher\\n"\n' >"${SCRIPT_DIR}/model-availability-helper.sh"
	chmod +x "${SCRIPT_DIR}/model-availability-helper.sh"
	model_tier_next() {
		local tier="$1"
		[[ "$tier" != thinking ]] || return 1
		printf 'thinking\n'
		return 0
	}
	model_tier_candidate_index() {
		local tier="$1" model="$2"
		[[ "$tier $model" == 'thinking fixture/higher' ]] || return 1
		return 0
	}
	model_tier_variant() {
		printf 'medium\n'
		return 0
	}
	model_tier_next_variant() {
		[[ "${allow_reasoning_escalation:-false}" == true ]] || return 1
		printf 'high\n'
		return 0
	}
	PR_REVIEW_THREAD_RESPONSE_MODEL=""
	comments=$(jq -nc --arg head "$head" '[{id:34,author_association:"MEMBER",user:{login:"worker"},
		created_at:"2026-09-30T02:00:00Z",body:("CLAIM_RELEASED reason=no_activity checkpoint_tier=standard checkpoint_model=fixture/lower checkpoint_variant=medium checkpoint_head="+$head)}]')
	out=$(_pcc_next_stalled_tier "$comments" '[]' 34 "$head") || return 1
	[[ "$out" == $'thinking\tfixture/higher\tmedium' ]] || return 1
	for mode in edited outsider missing duplicate ceiling wrong_head wrong_release override unavailable capability identical; do
		local fixture="$comments" selected_head="$head" release=34
		PR_REVIEW_THREAD_RESPONSE_MODEL=""
		export TIER_UNAVAILABLE=0
		case "$mode" in
		edited) fixture=$(jq '.[0].updated_at="2026-09-30T02:01:00Z"' <<<"$fixture") ;;
		outsider) fixture=$(jq '.[0].author_association="NONE"' <<<"$fixture") ;;
		missing) fixture=$(jq '.[0].body="CLAIM_RELEASED reason=no_activity"' <<<"$fixture") ;;
		duplicate) fixture=$(jq '.[0].body += " checkpoint_tier=simple"' <<<"$fixture") ;;
		ceiling) fixture=$(jq '.[0].body |= sub("tier=standard"; "tier=thinking")' <<<"$fixture") ;;
		wrong_head) selected_head="2222222222222222222222222222222222222222" ;;
		wrong_release) release=35 ;;
		override) PR_REVIEW_THREAD_RESPONSE_MODEL="fixture/pinned" ;;
		unavailable) TIER_UNAVAILABLE=1 ;;
		capability) fixture=$(jq '.[0].body |= sub("reason=no_activity"; "reason=blocked")' <<<"$fixture") ;;
		identical) fixture=$(jq '.[0].body |= sub("model=fixture/lower"; "model=fixture/higher")' <<<"$fixture") ;;
		esac
		if _pcc_next_stalled_tier "$fixture" '[]' "$release" "$selected_head"; then
			printf 'unexpected escalation: %s\n' "$mode" >&2
			return 1
		fi
	done
	PR_REVIEW_THREAD_RESPONSE_MODEL="" TIER_UNAVAILABLE=0
	local allow_reasoning_escalation=true
	fixture=$(jq '.[0].body |= sub("model=fixture/lower"; "model=fixture/higher")' <<<"$comments")
	out=$(_pcc_next_stalled_tier "$fixture" '[]' 34 "$head") || return 1
	[[ "$out" == $'thinking\tfixture/higher\thigh' ]] || return 1
	return 0
)

test_checkpoint_release_provenance() (
	local real_dir="$SCRIPT_DIR" head="1111111111111111111111111111111111111111" out=""
	# The actual release builder publishes only validated effective tier/head.
	# shellcheck source=../headless-runtime-failure.sh
	source "${real_dir}/headless-runtime-failure.sh"
	model_tier_candidate_index() {
		local tier="$1" model="$2"
		[[ "$tier" =~ ^(standard|thinking)$ && "$model" == fixture/higher ]] || return 1
		return 0
	}
	model_tier_variant() {
		printf 'medium\n'
		return 0
	}
	AIDEVOPS_ROUTING_MODEL=fixture/higher AIDEVOPS_ROUTING_VARIANT=medium
	AIDEVOPS_DISPATCH_TIER=standard AIDEVOPS_PR_REPAIR_HEAD_SHA="$head"
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" == *"checkpoint_tier=standard checkpoint_head=${head}"* ]] || return 1
	AIDEVOPS_DISPATCH_TIER=thinking
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" == *"checkpoint_tier=thinking"* ]] || return 1
	AIDEVOPS_ROUTING_MODEL=fixture/unmatched-pinned
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" != *checkpoint_tier=* ]] || return 1
	AIDEVOPS_ROUTING_MODEL=fixture/higher AIDEVOPS_ROUTING_VARIANT=high
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" != *checkpoint_tier=* ]] || return 1
	AIDEVOPS_DISPATCH_TIER='invalid value'
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" != *checkpoint_tier=* ]] || return 1
	AIDEVOPS_DISPATCH_TIER=standard AIDEVOPS_ROUTING_VARIANT=""
	model_tier_variant() { return 1; }
	out=$(_hrff_build_claim_released_line no_activity worker 1 1)
	[[ "$out" != *checkpoint_tier=* ]] || return 1
	return 0
)

test_checkpoint_tier_dispatch() (
	local output="" captured="" head="1111111111111111111111111111111111111111"
	local output_file="${TEST_ROOT}/tier-dispatch"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | with_head_commit)"
	STUB_COMMENTS_JSON="$(stall_comments stall-lease | jq -c 'map(. + [
		{id:33,created_at:"2026-09-30T01:40:00Z",author_association:"MEMBER",user:{login:"current-runner"},
		 body:"DISPATCH_CLAIM nonce=n2 runner=current-runner"},
		{id:34,created_at:"2026-09-30T02:00:00Z",author_association:"MEMBER",user:{login:"current-runner"},
		 body:"CLAIM_RELEASED reason=no_activity runner=current-runner"}])')"
	export STUB_ISSUE_JSON STUB_PR_JSON STUB_COMMENTS_JSON
	printf '[]' >"$STUB_CLAIM_FILE"
	_PCC_ATTENTION_REARM_SECONDS="$ATTENTION_REARM_CLOSED"
	_pcc_next_stalled_tier() {
		printf 'thinking\tfixture/higher\tmedium\n'
		return 0
	}
	_prrts_dispatch_guarded() {
		local repo_slug="$1" pr_number="$3" head_ref="${11}" head_oid="${12}"
		captured="$* tier=${PCC_ESCALATION_TIER:-} model=${PCC_ESCALATION_MODEL:-}"
		export STUB_AUTH_LOGIN="$PCC_AUTHENTICATED_LOGIN"
		_prrts_prelaunch_target_fence "$repo_slug" "$pr_number" "$head_ref" "$head_oid" || return 1
		return 0
	}
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || return 1
	output="$(<"$output_file")"
	[[ "$output" == *STALLED_CHECKPOINT_TIER_ESCALATED* && "$output" != *STALLED_CHECKPOINT_ATTENTION_POSTED* &&
		"$captured" == *"tier-thinking:release-34"* && "$captured" == *"tier=thinking model=fixture/higher"* ]] || return 1
	[[ -z "${PCC_ESCALATION_TIER:-}" ]] || return 1
	# The real fenced claim created by the first dispatch owns the head. Even a
	# fresh scanner invocation on a different runner must not reach the launcher.
	captured=""
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 other-runner >"$output_file" || true
	[[ -z "$captured" ]] || return 1
	return 0
)

test_checkpoint_tier_command() (
	local PCC_ESCALATION_TIER=thinking PCC_ESCALATION_MODEL=fixture/higher PCC_ESCALATION_VARIANT=high
	local PR_REVIEW_THREAD_RESPONSE_MODEL="" mode="" PCC_ESCALATION_HEAD=original PCC_HEAD_OID=changed
	local -a cmd=()
	# Head advancement between evidence and target refresh must fail closed.
	if _pcc_escalated_fingerprint base; then return 1; fi
	for mode in checkpoint ordinary pinned; do
		cmd=(headless run)
		PR_REVIEW_THREAD_RESPONSE_MODEL=""
		case "$mode" in
		checkpoint)
			_prrts_append_worker_model_args 123
			[[ "${cmd[*]}" == 'headless run --tier thinking --variant high --model fixture/higher' ]] || return 1
			;;
		ordinary)
			_prrts_append_worker_model_args ''
			[[ "${cmd[*]}" == 'headless run' ]] || return 1
			;;
		pinned)
			PR_REVIEW_THREAD_RESPONSE_MODEL=fixture/pinned
			_prrts_append_worker_model_args 123
			[[ "${cmd[*]}" == 'headless run --model fixture/pinned' ]] || return 1
			;;
		esac
	done
	return 0
)

test_checkpoint_tier_fuses() (
	local PCC_ESCALATION_TIER="" PCC_ESCALATION_MODEL="" PCC_ESCALATION_RELEASE="" PCC_ESCALATION_HEAD=""
	local selected=false
	_pcc_next_stalled_tier() {
		selected=true
		return 0
	}
	# Reject before model selection at the first stall and either fuse.
	if _pcc_prepare_stall_escalation owner/repo 42 head 34 1 1 1 '[]' '[]'; then return 1; fi
	if _pcc_prepare_stall_escalation owner/repo 42 head 34 2 "$_PCC_MAX_PR_RELEASES" 2 '[]' '[]'; then return 1; fi
	if _pcc_prepare_stall_escalation owner/repo 42 head 34 2 2 "$_PCC_MAX_PR_PROGRESS_RELEASES" '[]' '[]'; then return 1; fi
	[[ "$selected" == false && -z "$PCC_ESCALATION_TIER" ]] || return 1
	return 0
)

for tier_test in test_checkpoint_tier_selector test_checkpoint_release_provenance test_checkpoint_tier_dispatch test_checkpoint_tier_command test_checkpoint_tier_fuses; do
	if "$tier_test"; then
		print_result "$tier_test" 0
	else
		print_result "$tier_test" 1
	fi
done
