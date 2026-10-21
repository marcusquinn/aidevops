#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#35129: repo-declared queue recovery policy loader, cross-runner circuit
# intake and supervisor prompt contract. GitHub is mocked; no network writes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
FIX_SHA='0123456789abcdef0123456789abcdef01234567'
GH_LOG="${TEST_ROOT}/gh-calls.log"
# GH#35310: never let the recovery queue default to the live ~/.aidevops root.
export AIDEVOPS_BLOCKER_RECOVERY_DIR="${TEST_ROOT}/default-recovery-queue"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../recovery-policy-helper.sh
source "${SCRIPT_DIR}/recovery-policy-helper.sh"
# shellcheck source=../terminal-blocker-circuit.sh
source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"
# shellcheck source=../terminal-blocker-recovery-helper.sh
source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"

# Contents API shape, base64 wrapped at 60 columns like GitHub returns it.
_fixture_content() {
	local text="$1"
	local encoded=""
	encoded=$(printf '%s' "$text" | base64 | tr -d '\n' | fold -w 60)
	jq -nc --arg c "$encoded" '{type:"file",encoding:"base64",size:1024,content:($c + "\n")}'
	return 0
}

# Fixture state: FIX_PUSH (true|false), FIX_CONFIG (JSON text or 404),
# FIX_DOC (Markdown text or 404).
gh() {
	printf '%s\n' "$*" >>"$GH_LOG"
	[[ "${1:-}" == api ]] || return 1
	case "$*" in
	"api repos/owner/repo")
		jq -nc --argjson push "$FIX_PUSH" '{default_branch:"main",permissions:{admin:false,maintain:false,push:$push}}'
		;;
	"api -X GET repos/owner/repo/commits -f sha=main -f per_page=1 --jq .[0].sha")
		printf '%s\n' "$FIX_SHA"
		;;
	"api -X GET repos/owner/repo/contents/.aidevops.json -f ref=${FIX_SHA}")
		[[ "$FIX_CONFIG" != 404 ]] || {
			printf 'gh: Not Found (HTTP 404)\n' >&2
			return 1
		}
		_fixture_content "$FIX_CONFIG"
		;;
	"api -X GET repos/owner/repo/contents/docs/ops.md -f ref=${FIX_SHA}")
		[[ "$FIX_DOC" != 404 ]] || {
			printf 'gh: Not Found (HTTP 404)\n' >&2
			return 1
		}
		_fixture_content "$FIX_DOC"
		;;
	*) return 1 ;;
	esac
	return 0
}

POLICY_CONFIG='{"recovery_policy":"docs/ops.md#Queue recovery"}'
OUTLIER_ACTION='{"conditions":["Approved browser capture and approved provider both failed with source-backed evidence"],"issue_template":"Exhausted outlier: evidence, held chain, reopen conditions.","labels":["hold-for-review"]}'

# Build a policy document whose section holds one JSON block.
_policy_doc() {
	local actions_json="$1"
	local fence='```'
	# A fenced "# Queue recovery" comment precedes the real heading.
	printf '# Operations\n\nIntro.\n\n%sbash\n# Queue recovery\necho not-a-heading\n%s\n\n' "$fence" "$fence"
	printf '## Queue recovery\n\nPolicy for the pulse supervisor.\n\n%sjson\n{"actions": %s}\n%s\n\n' \
		"$fence" "$actions_json" "$fence"
	printf '## Other section\n\n%sjson\n{"actions": {}}\n%s\n' "$fence" "$fence"
	return 0
}

# Run the loader; sets LOAD_OUT and LOAD_RC.
_load() {
	LOAD_RC=0
	: >"$GH_LOG"
	LOAD_OUT=$(recovery_policy_load owner/repo 2>/dev/null) || LOAD_RC=$?
	return 0
}

test_no_policy_is_distinct_and_unchanged() {
	FIX_PUSH=true FIX_CONFIG=404 FIX_DOC=404
	_load
	local status=1
	[[ "$LOAD_RC" -eq 3 && -z "$LOAD_OUT" ]] && status=0
	print_result "no .aidevops.json returns 3 (no policy) with no output" "$status"

	FIX_CONFIG='{"validator_timeout_seconds":600}'
	_load
	status=1
	[[ "$LOAD_RC" -eq 3 && -z "$LOAD_OUT" ]] && status=0
	print_result "config without recovery_policy returns 3" "$status"

	FIX_CONFIG="$POLICY_CONFIG" FIX_DOC=404
	_load
	status=1
	[[ "$LOAD_RC" -eq 1 ]] && status=0
	print_result "declared but missing policy document fails closed (1)" "$status"
	return 0
}

test_enabled_action_loads_pinned() {
	FIX_PUSH=true FIX_CONFIG="$POLICY_CONFIG"
	FIX_DOC=$(_policy_doc "{\"outlier_hold\": ${OUTLIER_ACTION}}")
	_load
	local status=1
	if [[ "$LOAD_RC" -eq 0 ]] &&
		printf '%s' "$LOAD_OUT" | jq -e --arg sha "$FIX_SHA" '
			.repo == "owner/repo" and .revision == $sha and .path == "docs/ops.md" and
			.heading == "Queue recovery" and (.actions | keys) == ["outlier_hold"] and
			(.actions.outlier_hold.labels | index("hold-for-review")) != null' >/dev/null; then
		status=0
	fi
	print_result "enabled outlier_hold loads from wrapped base64, fenced pseudo-heading ignored" "$status"

	status=1
	# Every file read is pinned to the one resolved default-branch commit.
	if [[ "$(grep -c -- '/contents/' "$GH_LOG")" -eq 2 && "$(grep -c -- "ref=${FIX_SHA}" "$GH_LOG")" -eq 2 ]]; then
		status=0
	fi
	print_result "config and document reads are pinned to the same revision" "$status"

	status=1
	printf '%s' "$LOAD_OUT" | jq -e '.actions | has("session_cap_split") or has("brief_authority") | not' >/dev/null && status=0
	print_result "actions not listed in the policy are not returned (not authorized)" "$status"
	return 0
}

test_fail_closed_cases() {
	local status=0 name="" actions=""
	FIX_CONFIG="$POLICY_CONFIG"

	FIX_PUSH=false FIX_DOC=$(_policy_doc "{\"outlier_hold\": ${OUTLIER_ACTION}}")
	_load
	if [[ "$LOAD_RC" -ne 1 ]] || grep -q -- '/contents/' "$GH_LOG"; then
		status=1
	fi
	print_result "read-only access fails closed before reading policy" "$status"

	FIX_PUSH=true
	while IFS='|' read -r name actions; do
		FIX_DOC=$(_policy_doc "$actions")
		_load
		status=1
		[[ "$LOAD_RC" -eq 1 && -z "$LOAD_OUT" ]] && status=0
		print_result "fails closed: ${name}" "$status"
	done <<EOF
unknown action|{"auto_merge": ${OUTLIER_ACTION}}
outlier_hold without hold-for-review|{"outlier_hold": {"conditions":["x"],"issue_template":"t","labels":["blocked"]}}
protected lifecycle label|{"brief_authority": {"conditions":["x"],"issue_template":"t","labels":["status:available"]}}
protected trust label|{"brief_authority": {"conditions":["x"],"issue_template":"t","labels":["ai-approved"]}}
mixed-case protected label|{"brief_authority": {"conditions":["x"],"issue_template":"t","labels":["AI-Approved"]}}
mixed-case protected prefix|{"brief_authority": {"conditions":["x"],"issue_template":"t","labels":["Status:Available"]}}
missing conditions|{"brief_authority": {"conditions":[],"issue_template":"t","labels":["auto-dispatch"]}}
split without session budget|{"session_cap_split": {"conditions":["x"],"issue_template":"t","labels":["auto-dispatch"],"split_pattern":"p"}}
invalid JSON|{"outlier_hold": 
EOF

	FIX_DOC=$(printf '## Queue recovery\n\nA\n\n## Queue recovery\n\nB\n')
	_load
	status=1
	[[ "$LOAD_RC" -eq 1 ]] && status=0
	print_result "fails closed: duplicate heading" "$status"

	local fence='```'
	FIX_DOC=$(printf '## Queue recovery\n\n%sjson\n{"actions":{}}\n%s\n\n%sjson\n{"actions":{}}\n%s\n' \
		"$fence" "$fence" "$fence" "$fence")
	_load
	status=1
	[[ "$LOAD_RC" -eq 1 ]] && status=0
	print_result "fails closed: two JSON blocks in one section" "$status"

	# A json fence quoted as an example inside a longer or tilde fence is
	# content, never an enabled policy.
	local outer=""
	for outer in '````' '~~~'; do
		FIX_DOC=$(printf '## Queue recovery\n\n%stext\n%sjson\n{"actions": {"outlier_hold": %s}}\n%s\n%s\n' \
			"$outer" "$fence" "$OUTLIER_ACTION" "$fence" "$outer")
		_load
		status=1
		[[ "$LOAD_RC" -eq 1 && -z "$LOAD_OUT" ]] && status=0
		print_result "fails closed: json example nested in ${outer} fence" "$status"
	done

	FIX_CONFIG='{"recovery_policy":"../secrets.md#Queue recovery"}'
	_load
	status=1
	[[ "$LOAD_RC" -eq 1 ]] && ! grep -q -- 'secrets' "$GH_LOG" && status=0
	print_result "fails closed: path traversal never fetched" "$status"

	FIX_CONFIG="$POLICY_CONFIG"
	FIX_DOC=$(_policy_doc '{}')
	_load
	status=1
	[[ "$LOAD_RC" -eq 0 ]] && printf '%s' "$LOAD_OUT" | jq -e '.actions == {}' >/dev/null && status=0
	print_result "empty actions object loads and enables nothing" "$status"
	return 0
}

_circuit_comments() {
	local login="$1"
	local association="$2"
	jq -nc --arg login "$login" --arg assoc "$association" '[[
		{id:1,user:{login:$login},author_association:$assoc,created_at:"2026-10-19T10:00:00Z",
		 body:"Terminal blocker: reason=source_access_blocked owner=brief-author"},
		{id:2,user:{login:$login},author_association:$assoc,created_at:"2026-10-19T11:00:00Z",
		 body:"<!-- aidevops:terminal-blocker-circuit -->\nTERMINAL_BLOCKER_CIRCUIT active=true observations=2"}
	]]'
	return 0
}

test_cross_runner_seed_reason() {
	local member="" collaborator="" status=1
	member=$(_circuit_comments other-runner MEMBER)
	collaborator=$(_circuit_comments other-runner COLLABORATOR)
	! _tbr_seed_reason "$member" runner-one false >/dev/null && status=0
	print_result "without policy another runner's circuit is not seeded (unchanged)" "$status"

	status=1
	[[ "$(_tbr_seed_reason "$member" runner-one true)" == source_access_blocked ]] && status=0
	print_result "with enabled policy an OWNER/MEMBER foreign circuit is seeded" "$status"

	status=1
	! _tbr_seed_reason "$collaborator" runner-one true >/dev/null && status=0
	print_result "a foreign bare-COLLABORATOR circuit is never seeded" "$status"

	status=1
	[[ "$(_tbr_seed_reason "$(_circuit_comments runner-one COLLABORATOR)" runner-one false)" == source_access_blocked ]] && status=0
	print_result "own circuit still seeds without policy" "$status"
	return 0
}

# End-to-end seed + pending with mocked GitHub and policy loader.
test_cross_runner_seed_and_pending() {
	local status=0
	if ! (
		TBR_ROOT="${TEST_ROOT}/tbr"
		TBR_REPOS_JSON="${TEST_ROOT}/repos.json"
		TBR_EXCERPT_DIR="${TEST_ROOT}/excerpts"
		export WORKER_GITHUB_LOGIN=runner-one TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		mkdir -p "$TBR_EXCERPT_DIR"
		# A same-number excerpt from an unrelated local attempt must not leak.
		printf 'protected\n' >"${TBR_EXCERPT_DIR}/other-repo-77-20261019.log"
		jq -nc '{initialized_repos:[{slug:"owner/repo",pulse:true,path:""}]}' >"$TBR_REPOS_JSON"
		POLICY_ON=0
		_tbr_policy_enabled() { [[ "$POLICY_ON" -eq 1 ]] || return 1; return 0; }
		gh() {
			case "$*" in
			"api -X GET search/issues"*) printf '77\n' ;;
			"api repos/owner/repo/issues/77/comments?per_page=100 --paginate --slurp") _circuit_comments other-runner MEMBER ;;
			"api repos/owner/repo/issues/77") jq -nc '{state:"open",title:"Award chain",body:"b",labels:[{name:"status:blocked"}]}' ;;
			*) return 1 ;;
			esac
			return 0
		}
		terminal_blocker_fetch_trusted_comments() { _circuit_comments other-runner MEMBER | jq -c '.[0]'; return 0; }
		terminal_blocker_circuit_active() { return 0; }
		queue="${TBR_ROOT}/queue/owner--repo--77.json"

		tbr_seed --force || exit 1
		[[ ! -f "$queue" ]] || exit 1

		POLICY_ON=1
		tbr_seed --force || exit 1
		[[ "$(jq -r '.intake' "$queue")" == policy_remote && "$(jq -r '.reason' "$queue")" == source_access_blocked ]] || exit 1

		out=$(_tbr_check_entry "$queue") || exit 1
		printf '%s' "$out" | jq -e '.intake == "policy_remote" and .local_excerpts == [] and .issue == 77' >/dev/null || exit 1

		# Policy withdrawn: the remote entry retires instead of lingering.
		POLICY_ON=0
		_tbr_check_entry "$queue" >/dev/null && exit 1
		[[ ! -f "$queue" ]] || exit 1

		# Local enqueue (producing runner path) is unchanged and keeps excerpts.
		tbr_enqueue owner/repo 77 source_access_blocked || exit 1
		out=$(_tbr_check_entry "$queue") || exit 1
		printf '%s' "$out" | jq -e '.intake == "local" and (.local_excerpts | length) == 1' >/dev/null || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "policy-gated cross-runner intake: seeded remote, public-only, retired when policy withdrawn" "$status"
	return 0
}

test_record_wake_values() {
	local status=0
	if ! (
		TBR_ROOT="${TEST_ROOT}/record"
		export WORKER_GITHUB_LOGIN=runner-one
		printf '%s' '{"wake":"human_decision","next_action":"held outlier chain","evidence":"decision comment"}' |
			tbr_record owner/repo 77 || exit 1
		printf '%s' '{"wake":"dependency_change","next_action":"split task filed","evidence":"split link"}' |
			tbr_record owner/repo 78 || exit 1
		jq -e '.wake == "human_decision" and .actor == "runner-one"' "${TBR_ROOT}/decisions/owner--repo--77.json" >/dev/null || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "policy outcomes record with human_decision/dependency_change wakes" "$status"
	return 0
}

test_supervisor_prompt_contract() {
	local cycle="${SCRIPT_DIR}/pulse-wrapper-cycle.sh" status=0 needle=""
	for needle in 'recovery-policy-helper.sh <repo>' 'reference/recovery-policy.md' \
		'outlier_hold, session_cap_split, brief_authority' 'Exit 3 or 1 means no policy authority' \
		'intake policy_remote' 'wake=human_decision' 'wake=dependency_change' 'wake=brief_revision'; do
		grep -qF -- "$needle" "$cycle" || status=1
	done
	print_result "supervisor prompt loads policy, limits authority to enabled actions, maps wakes" "$status"
	return 0
}

test_no_policy_is_distinct_and_unchanged
test_enabled_action_loads_pinned
test_fail_closed_cases
test_cross_runner_seed_reason
test_cross_runner_seed_and_pending
test_record_wake_values
test_supervisor_prompt_contract

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
