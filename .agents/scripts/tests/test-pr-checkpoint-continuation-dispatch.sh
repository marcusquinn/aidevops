#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-pr-checkpoint-continuation-helper.sh; relies on its fixtures.
# shellcheck disable=SC2154  # fixtures and variables are defined by sibling modules

test_diagnostic_tooling_profile() (
	local repo="${TEST_ROOT}/tooling-repo" commit="" prompt_file="" content="" row="" status=0
	local AIDEVOPS_HEADLESS_APPEND_CONTRACT=1
	git init --quiet "$repo" || return 1
	git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
		commit --quiet --allow-empty -m fixture || return 1
	commit=$(git -C "$repo" rev-parse HEAD) || return 1
	_pcc_validate_diagnostic_tooling "$repo" "$commit" || return 1
	_pcc_validate_diagnostic_tooling "$repo" "" || return 1
	! _pcc_validate_diagnostic_tooling "$repo" main || return 1
	! _pcc_validate_diagnostic_tooling "$repo" "${commit:0:12}" || return 1
	! _pcc_validate_diagnostic_tooling "$repo" "ffffffffffffffffffffffffffffffffffffffff" || return 1
	PCC_DIAGNOSTIC_TOOLING_COMMIT="$commit"
	PCC_REVISION_APPROVAL=500
	PCC_LINKED_ISSUE=123
	[[ "$(_prrts_append_headless_contract)" == 0 ]] || return 1
	prompt_file=$(_prrts_write_prompt_file owner/repo "$repo" 42 title 0 fingerprint preview) || return 1
	content=$(<"$prompt_file")
	[[ "$content" == *"--base ${commit}"* && "$content" == *"separately owned"* &&
		"$content" == *"Do not reuse"* && "$content" == *"NO hosted access"* &&
		"$content" == *"Do not use mark-complete"* && "$content" != *"Commit the continuation"* ]] || return 1
	PCC_REVISION_APPROVAL=0
	! _prrts_write_prompt_file owner/repo "$repo" 42 title 0 fingerprint preview || return 1
	PCC_DIAGNOSTIC_TOOLING_COMMIT=""
	[[ "$(_prrts_append_headless_contract)" == 1 ]] || return 1
	prompt_file=$(_prrts_write_prompt_file owner/repo "$repo" 42 title 0 fingerprint preview) || return 1
	[[ "$(<"$prompt_file")" == *"Work only in the supplied linked worktree"* ]] || return 1
	STUB_PR_JSON=$(valid_pr_json)
	STUB_ISSUE_JSON=$(valid_issue_json '[{"name":"status:available"}]')
	_pr_checkpoint_revised_target() {
		printf '{"issue":123,"pr":42,"runner":"worker-bot","approval_id":500,"diagnostic_tooling_commit":"%s"}' "$commit"
		return 0
	}
	row=$(_pcc_target_row owner/repo 42 123 worker-bot worker-bot) || return 1
	[[ "$row" == *$'\t'"$commit" ]] || return 1
	_pcc_live_checkpoint_author() {
		printf 'worker-bot'
		return 0
	}
	_prrts_retry_continuation_blocker() { return 0; }
	_prrts_dispatch_guarded() {
		printf 'unexpected worker launch\n' >&2
		return 99
	}
	_pcc_target_row() {
		printf 'title\tworker/123\t%s\tworker-bot\tavailable\tworker-bot\t500\tclosing\t0\t%s\n' \
			"$commit" "ffffffffffffffffffffffffffffffffffffffff"
		return 0
	}
	_pcc_dispatch owner/repo "$repo" 42 123 worker-bot worker-bot >/dev/null 2>&1 || status=$?
	[[ "$status" == 1 ]] || return 1
	return 0
)

if test_diagnostic_tooling_profile; then
	print_result "approval-bound diagnostic tooling preserves default scope and refuses missing source before launch" 0
else
	print_result "approval-bound diagnostic tooling preserves default scope and refuses missing source before launch" 1
fi

test_unknown_pending_policy() (
	local root="${TEST_ROOT}/unknown-policy" head="1111111111111111111111111111111111111111"
	local comments="" body_hash="" status=0 test_permission="write" metadata="" brief="" STUB_TEMPLATE_FAIL=false
	mkdir -p "$root"
	local SCRIPT_DIR="$root" AIDEVOPS_REPOS_JSON="${root}/repos.json"
	export STUB_APPROVAL_FILE="${root}/approval"
	# shellcheck disable=SC2016 # Expand in the generated fixture, not its writer.
	printf '%s\n' '#!/usr/bin/env bash' 'tee "$STUB_APPROVAL_FILE" >/dev/null' >"${root}/gh-write-helper.sh"
	chmod +x "${root}/gh-write-helper.sh"
	metadata=$(valid_issue_json '[{"name":"auto-dispatch"},{"name":"status:blocked"}]' | jq '.assignees=[] | .body="### Files Scope\n- helper.sh"')
	body_hash=$(jq -r '.body' <<<"$metadata" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()[:-1]).hexdigest())')
	brief="$body_hash"
	comments=$(jq -nc --arg head "$head" --arg brief "$brief" '[{id:20,created_at:"2026-11-02T00:00:00Z",user:{login:"worker-bot"},body:("Terminal blocker: reason=unknown owner=worker-triage task=123\nCHECKPOINT_UNKNOWN_TRIAGE pending_work brief="+$brief+" head="+$head)}]')
	gh() {
		local command="$*"
		case "$command" in
		'api repos/owner/repo/issues/123') printf '%s\n' "$metadata" ;;
		pr\ view*) valid_pr_json ;;
		'api user --jq .login') printf 'maintainer\n' ;;
		api\ repos/owner/repo/collaborators/*) printf '%s\n' "$test_permission" ;;
		*) return 1 ;;
		esac
		return 0
	}
	_pcc_approval_template() {
		[[ "$STUB_TEMPLATE_FAIL" == false ]] || return 1
		printf 'CHECKPOINT_CONTINUATION_APPROVED {"head":"%s","brief_sha256":"%s","release_id":20}\n' "$head" "$body_hash"
		return 0
	}
	_pcc_unknown_digest() { printf 'digest\n' >"${root}/digest"; return 0; }
	printf '{"initialized_repos":[]}\n' >"$AIDEVOPS_REPOS_JSON"
	_pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments" || status=1
	[[ -f "${root}/digest" && ! -f "$STUB_APPROVAL_FILE" ]] || status=1
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","checkpoint_policy":{"auto_continue_unknown_pending_work":true,"configured_by":"maintainer"}}]}' >"$AIDEVOPS_REPOS_JSON"
	_pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments" || status=1
	[[ -s "$STUB_APPROVAL_FILE" ]] || status=1
	rm -f "$STUB_APPROVAL_FILE"
	test_permission='read'
	if _pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments"; then status=1; fi
	test_permission='write'
	if _pcc_unknown_pending_work owner/repo 123 42 "2222222222222222222222222222222222222222" worker-bot 20 attempt:old "$comments"; then status=1; fi
	metadata=$(jq '.labels += [{name:"no-auto-dispatch"}]' <<<"$metadata")
	if _pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments"; then status=1; fi
	metadata=$(jq '.labels=[{name:"auto-dispatch"}] | .assignees=[{login:"new-owner"}]' <<<"$metadata")
	if _pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments"; then status=1; fi
	metadata=$(jq '.assignees=[]' <<<"$metadata")
	STUB_TEMPLATE_FAIL=true
	if _pcc_unknown_pending_work owner/repo 123 42 "$head" worker-bot 20 attempt:old "$comments"; then status=1; fi
	[[ ! -f "$STUB_APPROVAL_FILE" && "$status" == 0 ]] || return 1
	return 0
)
if test_unknown_pending_policy; then
	print_result "unknown pending policy routes off-policy digest and guarded approval; holds, owner, moved head and permissions reject" 0
else
	print_result "unknown pending policy routes off-policy digest and guarded approval; holds, owner, moved head and permissions reject" 1
fi

test_unknown_daily_digest() (
	local root="${TEST_ROOT}/daily-digest" head="1111111111111111111111111111111111111111" first='' second=''
	mkdir -p "$root"
	local SCRIPT_DIR="$root"
	export STUB_DIGEST_BODY="${root}/body" STUB_DIGEST_CALLS="${root}/calls"
	# shellcheck disable=SC2016 # Expand in the generated fixture, not its writer.
	printf '%s\n' '#!/usr/bin/env bash' 'tee "$STUB_DIGEST_BODY" >/dev/null' 'printf "POST\n" >>"$STUB_DIGEST_CALLS"' >"${root}/gh-write-helper.sh"
	chmod +x "${root}/gh-write-helper.sh"
	gh() {
		local args="$*"
		case "$args" in
		'api repos/owner/repo/labels --method POST'*) mkdir "${root}/reservation" ;;
		'api repos/owner/repo/labels/checkpoint-digest:'*) test -d "${root}/reservation" ;;
		*) return 1 ;;
		esac
		return $?
	}
	_pcc_unknown_digest_snapshot() {
		_pcc_unknown_digest_entry owner/repo 123 42 "$head" 20 attempt:old
		_pcc_unknown_digest_entry owner/repo 456 43 "$head" 30 attempt:other
		return 0
	}
	_pcc_unknown_digest owner/repo 123 42 "$head" 20 attempt:old &
	first=$!
	_pcc_unknown_digest owner/repo 456 43 "$head" 30 attempt:other &
	second=$!
	wait "$first" || return 1
	wait "$second" || return 1
	_pcc_unknown_digest owner/repo 123 42 "$head" 20 attempt:old || return 1
	[[ "$(wc -l <"$STUB_DIGEST_CALLS")" -eq 1 ]] || return 1
	jq -eRs 'contains("PR #42") and contains("PR #43") and (contains("CHECKPOINT_CONTINUATION_APPROVED") | not)' "$STUB_DIGEST_BODY" >/dev/null || return 1
	return 0
)
if test_unknown_daily_digest; then
	print_result "concurrent daily digest writers publish one immutable snapshot without approval or lost entries" 0
else
	print_result "concurrent daily digest writers publish one immutable snapshot without approval or lost entries" 1
fi

# GH#36529: a hygiene-hidden (minimized) but never-edited claim bumps REST
# updated_at; only a real body edit (or unreadable GraphQL state) may fence it.
test_hidden_unedited_fence() (
	local pages="" out="" mode="" status=0
	pages='[[{"id":1,"node_id":"IC_hidden","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:02:00Z","body":"DISPATCH_CLAIM x"},{"id":2,"node_id":"IC_edited","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:02:00Z","body":"DISPATCH_CLAIM y"},{"id":3,"node_id":"IC_plain","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","body":"z"}]]'
	gh() {
		[[ "$mode" != fail ]] || return 1
		if [[ "$mode" == missing_field ]]; then
			printf '{"data":{"nodes":[{"id":"IC_hidden"}]}}\n'
		else
			printf '{"data":{"nodes":[{"id":"IC_hidden","lastEditedAt":null},{"id":"IC_edited","lastEditedAt":"2026-11-02T00:02:00Z"}]}}\n'
		fi
		return 0
	}
	mode=ok
	out=$(_pr_checkpoint_normalise_hidden_unedited "$pages")
	jq -e "${_PCC_JQ_RELEASE_DEFS}"'
		[flatten[] | select(unedited) | .id] == [1,3]' <<<"$out" >/dev/null || status=1
	# The shared predicate also accepts flat metadata snapshots.
	out=$(_pr_checkpoint_normalise_hidden_unedited "$(jq -c 'flatten' <<<"$pages")")
	jq -e '[.[] | select(.updated_at == .created_at) | .id] == [1,3]' <<<"$out" >/dev/null || status=1
	for mode in fail missing_field; do
		out=$(_pr_checkpoint_normalise_hidden_unedited "$pages")
		jq -e "${_PCC_JQ_RELEASE_DEFS}"'
			[flatten[] | select(unedited) | .id] == [3]' <<<"$out" >/dev/null || status=1
	done
	[[ "$status" == 0 ]] || return 1
	return 0
)
if test_hidden_unedited_fence; then
	print_result "hidden unedited comments count as unedited; edited or unreadable GraphQL state fails closed" 0
else
	print_result "hidden unedited comments count as unedited; edited or unreadable GraphQL state fails closed" 1
fi

# A trusted approval must not turn an API outage into a consumed-approval
# diagnosis. Exercise the real dispatch-to-target error propagation.
for metadata_failure in pr issue comments; do
	export STUB_METADATA_FAILURE="$metadata_failure"
	metadata_rc=0
	_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" 42 123 worker-bot worker-bot || metadata_rc=$?
	if [[ "$metadata_rc" -eq 1 && "$PCC_TARGET_REJECTED" -eq 2 ]]; then
		print_result "${metadata_failure} API failure is not approval rejection" 0
	else
		print_result "${metadata_failure} API failure is not approval rejection" 1
	fi
done
unset STUB_METADATA_FAILURE
if row=$(_pcc_target_row "owner/repo" "42" "123") && \
	[[ "$row" == $'Continue existing work\tworker/issue-123\t1111111111111111111111111111111111111111\tworker-bot\tin-review\tworker-bot\t0\tclosing\t0' ]]; then
	print_result "accepts exact open worker draft linked to issue" 0
else
	print_result "accepts exact open worker draft linked to issue" 1 "row=${row:-missing}"
fi

for metadata_failure in pr issue comments; do
	export STUB_METADATA_FAILURE="$metadata_failure"
	# Force revision validation (and its comments read) for the comments case.
	STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:blocked"}]')"
	target_rc=0
	_pcc_target_row owner/repo 42 123 worker-bot worker-bot >/dev/null || target_rc=$?
	dispatch_rc=0
	_pcc_dispatch owner/repo "$TEST_ROOT/repo" 42 123 worker-bot worker-bot >/dev/null || dispatch_rc=$?
	if [[ "$target_rc" == 2 && "$dispatch_rc" == 1 && "$PCC_TARGET_REJECTED" == 2 ]]; then
		print_result "$metadata_failure API failure remains metadata-unavailable through dispatch" 0
	else
		print_result "$metadata_failure API failure remains metadata-unavailable through dispatch" 1
	fi
done
unset STUB_METADATA_FAILURE
STUB_ISSUE_JSON="$(valid_issue_json)"

# GH#36887: keep revision scheduling fenced, but never promise that a push or
# the attention age will bypass a historical approval. Full exact-envelope
# validation of current approvals is exercised by test-pr-checkpoint-revision.py.
test_revision_attention_guidance() (
	local approval_case="$1"
	local head="1111111111111111111111111111111111111111"
	local approval_head="$head" created_at="" comments="" body=""
	local post_file="${TEST_ROOT}/revision-attention-${approval_case}"
	created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	case "$approval_case" in
	older_head) approval_head="2222222222222222222222222222222222222222" ;;
	expired_older_head)
		approval_head="2222222222222222222222222222222222222222"
		created_at="2020-01-01T00:00:00Z"
		;;
	esac
	comments=$(jq -nc --arg head "$approval_head" --arg created "$created_at" '[{
		id:77,author_association:"OWNER",user:{login:"maintainer"},created_at:$created,updated_at:$created,
		body:("CHECKPOINT_CONTINUATION_APPROVED " + ({repo:"owner/repo",issue:123,pr:42,head:$head} | tojson))
	}]')
	if [[ "$approval_case" == expired_older_head ]]; then
		# GH#37779: an expired approval can never launch, so it no longer
		# fences the legacy route, its re-arm windows or the per-PR fuse.
		_pcc_comments_have_revision_approval "$comments" '["maintainer"]' && return 1
		_pr_checkpoint_issue_metadata_is_eligible "$STUB_ISSUE_JSON" 123 worker-bot "$comments" worker-bot || return 1
		return 0
	fi
	_pcc_comments_have_revision_approval "$comments" '["maintainer"]' || return 1
	# The real metadata predicate must still reject legacy scheduling, including
	# an unexpired current-head approval; dispatch-approved owns that route.
	if _pr_checkpoint_issue_metadata_is_eligible "$STUB_ISSUE_JSON" 123 worker-bot "$comments" worker-bot; then
		return 1
	fi
	# Capture an attention POST without contacting GitHub.
	# Args: api, endpoint, --method, POST, -f, body=<attention record>.
	# Output: write the body to the enclosing test's post_file for assertions.
	# Returns: 1 for an unexpected call shape, 0 after capturing the body.
	gh() {
		[[ "$1" == api && "$3" == --method && "$4" == POST ]] || return 1
		printf '%s' "${6#body=}" >"$post_file"
		return 0
	}
	_pcc_approved_revision_attention owner/repo 123 42 "$head" 31 clean 0 key false >/dev/null || return 1
	body="$(<"$post_file")"
	[[ "$body" == *'approval-template'* && "$body" == *'publish the generated approval as a new issue comment'* &&
		"$body" == *'Retry when those checks are available'* &&
		"$body" == *'does not prove that the approval was consumed'* &&
		"$body" != *'Push a corrected commit'* && "$body" != *'a new head re-arms'* &&
		"$body" != *'each runner that has not tried this head gets one'* ]] || return 1
	# Ordinary, approval-free attention retains its useful automatic recovery.
	_pcc_post_stall_attention owner/repo 123 42 "$head" 31 clean 2 key false "" attempt:a1 >/dev/null || return 1
	body="$(<"$post_file")"
	[[ "$body" == *'a new head re-arms one automatic continuation'* &&
		"$body" == *'once every runner has tried it Pulse continues it once per window'* &&
		"$body" == *'approval-template owner/repo 42 123 31 attempt:a1`'* ]] || return 1
	# GH#37514: the resume route survives the per-PR fuse; the attempt falls
	# back to a placeholder when no ready lease was found.
	_pcc_post_stall_attention owner/repo 123 42 "$head" 31 clean 6 key true >/dev/null || return 1
	body="$(<"$post_file")"
	[[ "$body" == *'per-PR automatic continuation limit'* &&
		"$body" == *'approval-template owner/repo 42 123 31 attempt:<RELEASED_ATTEMPT_ID>`'* ]] || return 1
	return 0
)
for approval_case in older_head expired_older_head current_head; do
	if test_revision_attention_guidance "$approval_case"; then
		print_result "$approval_case revision attention offers fresh approval without automatic re-arm promises" 0
	else
		print_result "$approval_case revision attention offers fresh approval without automatic re-arm promises" 1
	fi
done

if [[ "$_PCC_APPROVAL_VALIDATION_NOTE" == *'does not prove that the approval was consumed'* &&
	"$_PCC_APPROVAL_VALIDATION_NOTE" == *'Retry when those checks are available'* ]]; then
	print_result "revision attention does not diagnose consumption from validation failure" 0
else
	print_result "revision attention does not diagnose consumption from validation failure" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #1234' '' '[{"number":1234,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects issue-number prefix collisions" 0
else
	print_result "rejects issue-number prefix collisions" 1
fi

STUB_PR_JSON="$(valid_pr_json 'unresolved #123' '' '[]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects bare issue references" 0
else
	print_result "rejects bare issue references" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123 and resolves #456' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}},{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects ambiguous closing identities" 0
else
	print_result "rejects ambiguous closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves other/repo#123' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"other"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository closing identities" 0
else
	print_result "rejects cross-repository closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_PR_JSON="${STUB_PR_JSON/\"isCrossRepository\":false/\"isCrossRepository\":true}"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository checkpoint heads" 0
else
	print_result "rejects cross-repository checkpoint heads" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '[{"name":"origin:worker"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects held worker drafts" 0
else
	print_result "rejects held worker drafts" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects continuation after linked issue hold" 0
else
	print_result "rejects continuation after linked issue hold" 1
fi

for conflicting_status in status:blocked status:done status:in-progress; do
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:in-review\"},{\"name\":\"${conflicting_status}\"}]")"
	if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 0
	else
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 1
	fi
done

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"origin:interactive"}]')"
STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
if _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 0
else
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 1
fi

STUB_COMMENTS_JSON='[]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects interactive-provenance issue without checkpoint release" 0
else
	print_result "rejects interactive-provenance issue without checkpoint release" 1
fi

STUB_COMMENTS_JSON='[[
  {"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=worker-bot ts=2026-08-04T22:29:36Z"},
  {"id":11,"created_at":"2026-08-04T22:30:37Z","author_association":"MEMBER","body":"Interactive session claimed this issue"}
]]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects replayed checkpoint release after a newer human claim" 0
else
	print_result "rejects replayed checkpoint release after a newer human claim" 1
fi

STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'foreign-runner')"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects foreign-authored worker checkpoint" 0
else
	print_result "rejects foreign-authored worker checkpoint" 1
fi

# GH#35883: auto-dispatch authorizes worker pickup of interactive-provenance
# issues, so a capability-released worker draft stays continuable on a capable
# runner, unless a newer trusted interactive claim owns the issue.
interactive_capability_comments() {
	local extra="${1:-}"
	printf '[[{"id":12,"created_at":"2026-08-04T22:40:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"CLAIM_RELEASED reason=blocked runner=worker-bot ts=2026-08-04T22:40:00Z\\n\\nTerminal blocker: reason=runner_capability_unmet owner=runner-recovery task=123 attempt=a1."}%s]]\n' "$extra"
	return 0
}
STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(jq -nc '{number:123,state:"open",labels:[{name:"status:available"},{name:"auto-dispatch"},{name:"origin:interactive"}],assignees:[]}')"
STUB_COMMENTS_JSON="$(interactive_capability_comments)"
PCC_ALLOW_RELEASED=true
if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" 2>/dev/null) &&
	[[ "$row" == *$'\tavailable\tworker-bot\t0\tclosing\t0' ]]; then
	print_result "accepts capability-released draft on auto-dispatch interactive-provenance issue" 0
else
	print_result "accepts capability-released draft on auto-dispatch interactive-provenance issue" 1 "row=${row:-missing}"
fi
STUB_COMMENTS_JSON="$(interactive_capability_comments ',{"id":13,"created_at":"2026-08-04T22:50:00Z","author_association":"MEMBER","user":{"login":"maintainer"},"body":"Interactive session claimed this issue"}')"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
	print_result "rejects auto-dispatch interactive-provenance draft after a newer interactive claim" 0
else
	print_result "rejects auto-dispatch interactive-provenance draft after a newer interactive claim" 1
fi
STUB_ISSUE_JSON="$(jq -nc '{number:123,state:"open",labels:[{name:"status:available"},{name:"origin:interactive"}],assignees:[]}')"
STUB_COMMENTS_JSON="$(interactive_capability_comments)"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
	print_result "keeps interactive-provenance hold without auto-dispatch" 0
else
	print_result "keeps interactive-provenance hold without auto-dispatch" 1
fi
PCC_ALLOW_RELEASED=false
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'

# GH#34008: the pulse's own orphan-recovery draft links its issue only through
# a non-closing `For #N` line. The shared rule accepts exactly that shape.
TAKEOVER_LABELS='[{"name":"origin:worker-takeover"}]'
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'
STUB_PR_JSON="$(valid_pr_json 'Recovered dirty worktree.\nFor #123' "$TAKEOVER_LABELS" '[]')"
if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot") &&
	[[ "$row" == *$'\tworker-bot\t0\tfor\t0' ]]; then
	print_result "accepts For #N origin:worker-takeover recovery draft" 0
else
	print_result "accepts For #N origin:worker-takeover recovery draft" 1 "row=${row:-missing}"
fi

for_reject_case() {
	local name="$1" body="$2" labels="$3" closing="$4" mutate="${5:-}"
	STUB_PR_JSON="$(valid_pr_json "$body" "$labels" "$closing")"
	case "$mutate" in
	ready) STUB_PR_JSON="${STUB_PR_JSON/\"isDraft\":true/\"isDraft\":false}" ;;
	cross) STUB_PR_JSON="${STUB_PR_JSON/\"isCrossRepository\":false/\"isCrossRepository\":true}" ;;
	esac
	if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
		print_result "rejects For #N draft: ${name}" 0
	else
		print_result "rejects For #N draft: ${name}" 1
	fi
	return 0
}
# Worker checkpoint drafts keep `For #N`/`Ref #N` on incomplete work (GH#33374)
# and has-open-pr already holds the issue for them, so continuation must accept
# the same exact single-target shape.
WORKER_LABELS='[{"name":"origin:worker"}]'
for worker_body in 'For #123' 'Ref #123. Incomplete checkpoint.' 'Notes\nRefs #123' 'For #123. Done part.\nRef #900'; do
	STUB_PR_JSON="$(valid_pr_json "$worker_body" "$WORKER_LABELS" '[]')"
	if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot") &&
		[[ "$row" == *$'\tworker-bot\t0\tfor\t0' ]]; then
		print_result "accepts origin:worker non-closing checkpoint: ${worker_body}" 0
	else
		print_result "accepts origin:worker non-closing checkpoint: ${worker_body}" 1 "row=${row:-missing}"
	fi
done
for_reject_case "worker draft naming two For issues" 'For #123\nFor #456' "$WORKER_LABELS" '[]'
for_reject_case "worker draft whose For line names another issue" 'For #456\nRef #123' "$WORKER_LABELS" '[]'
for_reject_case "worker draft with Ref mid-line only" 'Batch for #77. Ref #123 later' "$WORKER_LABELS" '[]'
for_reject_case "worker draft with interactive label" 'Ref #123' '[{"name":"origin:worker"},{"name":"origin:interactive"}]' '[]'
for_reject_case "unlabelled draft" 'For #123' '[{"name":"bug"}]' '[]'
for_reject_case "ready PR" 'For #123' "$TAKEOVER_LABELS" '[]' ready
for_reject_case "cross-repository head" 'For #123' "$TAKEOVER_LABELS" '[]' cross
for_reject_case "protected label" 'For #123' '[{"name":"origin:worker-takeover"},{"name":"hold-for-review"}]' '[]'
for_reject_case "bare #N mention" 'Recovered work for #123' "$TAKEOVER_LABELS" '[]'
for_reject_case "issue-number prefix collision" 'For #1234' "$TAKEOVER_LABELS" '[]'
for_reject_case "closing link to another issue" 'For #123\nResolves #456' "$TAKEOVER_LABELS" \
	'[{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]'

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'

DISPATCH_ARGS=""
DISPATCH_RESULT=0
export STUB_CLAIM_FILE="${TEST_ROOT}/claims.json" STUB_AUTH_LOGIN=worker-bot
export DISPATCH_CLAIM_WINDOW=0 AIDEVOPS_TEST_MODE=1 AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1
export AIDEVOPS_DEVICE_ID=checkpoint-fixture-device
printf '[]' >"$STUB_CLAIM_FILE"
_prrts_dispatch_guarded() {
	local repo_slug="$1"
	local pr_number="$3"
	local head_ref="${11}"
	local head_oid="${12}"
	DISPATCH_ARGS="$*"
	if [[ "$DISPATCH_RESULT" == "$PRRTS_RC_DISPATCH_DEFERRED" || "$DISPATCH_RESULT" == "$PRRTS_RC_MAINTAINER_ATTENTION" ]]; then
		return "$DISPATCH_RESULT"
	fi
	printf '[]' >"$STUB_CLAIM_FILE"
	export STUB_AUTH_LOGIN="$PCC_AUTHENTICATED_LOGIN"
	_prrts_prelaunch_target_fence "$repo_slug" "$pr_number" "$head_ref" "$head_oid" || return 1
	return "$DISPATCH_RESULT"
}

STATUS_CALLS=""
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	local add_assignee=""
	local flag=""
	shift 3
	STATUS_CALLS="${STATUS_CALLS}${STATUS_CALLS:+$'\n'}${issue_number} ${repo_slug} ${status} $*"
	while [[ $# -gt 0 ]]; do
		flag="$1"
		case "$flag" in
		--add-assignee)
			add_assignee="${2:-}"
			shift 2
			;;
		--remove-assignee)
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	[[ -n "$add_assignee" ]] || return 1
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:${status}\"}]" "$add_assignee")"
	export STUB_ISSUE_JSON
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
output_file="${TEST_ROOT}/dispatch-output"
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot" >"$output_file"; then
	output="$(<"$output_file")"
else
	output="$(<"$output_file")"
fi
if [[ "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* ]] && \
	[[ "$DISPATCH_ARGS" == *"draft-checkpoint:1111111111111111111111111111111111111111:contract-4:0"* ]] && \
	[[ "$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* ]]; then
	print_result "dispatch binds continuation to exact PR branch and head" 0
else
	print_result "dispatch binds continuation to exact PR branch and head" 1 "output=${output:-missing} args=${DISPATCH_ARGS:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_DISPATCH_DEFERRED"
if output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_DEDUPLICATED* ]]; then
	print_result "active exact-head continuation is deduplicated as handled" 0
else
	print_result "active exact-head continuation is deduplicated as handled" 1 "output=${output:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_MAINTAINER_ATTENTION"
if ! output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_EXHAUSTED* ]]; then
	print_result "bounded retry exhaustion is explicit" 0
else
	print_result "bounded retry exhaustion is explicit" 1 "output=${output:-missing}"
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'stale-runner')"
STUB_ISSUE_JSON="$(valid_issue_json '' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=0
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner --remove-assignee stale-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "current-runner" ]] &&
	[[ "$(_prrts_worker_login 42)" == "current-runner" ]]; then
	print_result "cross-runner continuation transfers exact issue ownership before launch" 0
else
	print_result "cross-runner continuation transfers exact issue ownership before launch" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:queued"}]' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=1
if ! _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == $'123 owner/repo in-progress --add-assignee current-runner --remove-assignee stale-runner\n123 owner/repo queued --add-assignee stale-runner --remove-assignee current-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "stale-runner" && "$PCC_OWNERSHIP_TRANSFERRED" -eq 0 ]] &&
	printf '%s' "$STUB_ISSUE_JSON" | jq -e '
		.assignees[0].login == "stale-runner" and
		([.labels[].name] | index("status:queued") != null)
	' >/dev/null; then
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 0
else
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi
DISPATCH_RESULT=0

