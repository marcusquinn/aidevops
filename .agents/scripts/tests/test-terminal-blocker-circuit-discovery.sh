#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Fleet, recovery-fallback and owner-scoped discovery cases for the terminal-blocker circuit.
# Sourced by test-terminal-blocker-circuit.sh (shares its fixtures, print_result
# and TEST_* state); not executable standalone.

if [[ -n "${_TBC_DISCOVERY_TESTS_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TBC_DISCOVERY_TESTS_LOADED=1

_default_budget_progress_checks() {
	local issue=0 rc=0
	TBR_ROOT="${TEST_ROOT}/default-budget"
	export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT"
	unset BLOCKER_RECOVERY_BUDGET_SECONDS BLOCKER_RECOVERY_STAGE_SECONDS
	_tbr_init_dirs || return 1
	date +%s >"${TBR_ROOT}/last_seed_epoch"
	for issue in {100..124}; do
		tbr_enqueue owner/repo "$issue" files_scope_excluded || return 1
	done
	gh() {
		local args="$*" issue=""
		case "$args" in
		"api repos/owner/repo/issues/"*"/comments?per_page=100 --paginate --slurp")
			jq -c . "${TB_INTAKE_FIXTURE}/comments.json" ;;
		"api repos/owner/repo/issues/"*)
			issue="${args##*/}"
			if [[ "$issue" -le 109 ]]; then
				if [[ "$issue" -eq 100 ]]; then sleep 9; else sleep 4; fi
				printf '{"state":"closed"}\n'
			else
				jq -c . "${TB_INTAKE_FIXTURE}/issue.json"
			fi ;;
		"api -X GET repos/owner/repo/commits"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	export -f gh
	# A legacy fixture must be retired even when it sorts beyond the budget.
	printf '{"repo":"zz-fixture/repo","issue":42}\n' >"${TBR_ROOT}/queue/zz-fixture--repo--42.json"
	printf '{}\n' >"${TBR_ROOT}/decisions/zz-fixture--repo--42.json"
	tbr_enqueue zz-fixture/repo 42 && return 1
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/first" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && -s "${TBR_ROOT}/pending_cursor" ]] || return 1
	# A legitimate nine-second entry must finish rather than time out at eight.
	[[ ! -f "${TBR_ROOT}/queue/owner--repo--100.json" ]] || return 1
	[[ ! -f "${TBR_ROOT}/queue/zz-fixture--repo--42.json" && ! -f "${TBR_ROOT}/decisions/zz-fixture--repo--42.json" ]] || return 1
	rc=0
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/second" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 0 || "$rc" -eq 2 ]] || return 1
	jq -es 'any(.[]; .issue > 109 and .repo == "owner/repo")' "${TBR_ROOT}/first" "${TBR_ROOT}/second" >/dev/null || return 1
	# Missing registry preserves queued evidence instead of treating it as stale.
	TBR_REPOS_JSON="${TEST_ROOT}/missing-registry.json"
	rc=0
	_tbr_check_entry "${TBR_ROOT}/queue/owner--repo--111.json" >/dev/null || rc=$?
	[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--111.json" ]] || return 1
	return 0
}

test_fleet_capability_hold() {
	local status=0
	if ! (
		local brief='{"title":"Check tools","body":"### Files Scope\n- tool.sh"}'
		local revision="" fingerprint="" comments="" changed="" ready=1 updates=0
		revision=$(terminal_blocker_task_revision "$brief" owner/repo 42 "$TEST_ROOT" runner_capability_unmet)
		fingerprint=$(_terminal_blocker_hash 'v2:runner_capability_unmet')
		comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" '
			["alpha","beta"] | to_entries | map({id:(.key+1),author:.value,author_association:"MEMBER",
			created_at:"2026-10-27T10:00:00Z",body:("CLAIM_RELEASED reason=blocked runner="+.value+" ts=now\n<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->")})')
		_terminal_blocker_fleet_ready() { return "$ready"; }
		_terminal_blocker_fleet_dashboard() { printf '99\n'; return 0; }
		terminal_blocker_fetch_trusted_comments() { printf '[]\n'; return 0; }
		gh() { return 1; }
		_terminal_blocker_fleet_update() { updates=$((updates + 1)); return 0; }
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		[[ "$updates" -eq 1 ]] || exit 1
		# Same author twice, spoofed runner field, outsider and old revision do not hold.
		changed=$(jq -c '.[1].author="alpha" | .[1].body=.[0].body' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].author="mallory"' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].author_association="CONTRIBUTOR"' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		terminal_blocker_fleet_hold_active "$comments" '{"title":"Changed","body":"new brief"}' owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		ready=0
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		[[ "$updates" -eq 2 ]] || exit 1
		# A receipt wakes only its exact observed checkpoint; a new failure,
		# even in the same second, must be probed again.
		local checkpoint="" receipt=""
		checkpoint=$(_terminal_blocker_hash "${revision}:$(_terminal_blocker_fleet_observations "$comments" "$revision" "$fingerprint")")
		receipt=$(jq -nc --arg key "$checkpoint" '{id:123,body:("Ready checkpoints: "+$key)}')
		_terminal_blocker_fleet_existing() { printf '%s\n' "$receipt"; return 0; }
		ready=1
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].id=3' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		[[ "$updates" -eq 3 ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "fleet hold requires distinct authenticated runners and a current revision; readiness wakes it" "$status"
	return 0
}

test_fleet_escalation_upsert() {
	local status=0
	if ! (
		local existing='{}' calls="${TEST_ROOT}/fleet-calls" captured_body="" fingerprint=""
		local fixture_comments='[]' reconciled=""
		fingerprint=$(_terminal_blocker_hash 'v2:runner_capability_unmet')
		gh() {
			local endpoint="$2" method="$4" payload="${6:-}"
			printf '%s --method %s\n' "$endpoint" "$method" >>"$calls"
			captured_body="${payload#body=}"
			if [[ "$method" == PATCH ]]; then
				fixture_comments=$(jq -c --arg body "$captured_body" 'map(if .id == 123 then .body=$body else . end)' <<<"$fixture_comments")
			elif [[ "$method" == DELETE ]]; then
				fixture_comments=$(jq -c 'map(select(.id != 124))' <<<"$fixture_comments")
			fi
			return 0
		}
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 42 held "$existing" || exit 1
		[[ "$captured_body" == *'Held issues: 42'* && "$captured_body" == *'approve <worktree>'* ]] || exit 1
		existing=$(jq -nc --arg body "$captured_body" '{id:123,body:$body}')
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 43 held "$existing" || exit 1
		[[ "$captured_body" == *'Held issues: 42,43'* ]] || exit 1
		existing=$(jq -nc --arg body "$captured_body" '{id:123,body:$body}')
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 43 held "$existing" || exit 1
		[[ "$(wc -l <"$calls" | tr -d ' ')" -eq 2 ]] || exit 1
		rg -q 'comments/123 --method PATCH' "$calls" || exit 1
		# Two simultaneous creators converge without losing either issue list
		# or exact-checkpoint readiness evidence.
		fixture_comments=$(jq -nc --arg marker "<!-- ${_TBC_FLEET_MARKER}${fingerprint} -->" '
			[{id:123,author_association:"MEMBER",body:($marker+"\nHeld issues: 42\nReady checkpoints: aaaaaaaaaaaaaaaaaaaaaaaa")},
			 {id:124,author_association:"MEMBER",body:($marker+"\nHeld issues: 43\nReady checkpoints: bbbbbbbbbbbbbbbbbbbbbbbb")}]')
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$fixture_comments"; return 0; }
		reconciled=$(_terminal_blocker_fleet_existing owner/repo 99 "$fingerprint") || exit 1
		[[ "$reconciled" == *'Held issues: 42,43'* && "$reconciled" == *'aaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbb'* ]] || exit 1
		rg -q 'comments/124 --method DELETE' "$calls" || exit 1
		exit 0
	); then status=1; fi
	print_result "fleet escalation creates once, edits the held issue list and skips unchanged writes" "$status"
	return 0
}

test_capability_checkpoint_attention() {
	local status=0
	if ! (
		# shellcheck source=../pr-checkpoint-continuation-helper.sh
		source "${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh"
		local attention_body="" fixture_reason="runner_capability_unmet"
		# GH#35932: production `gh api --paginate --slurp` returns an array of
		# pages; a flat fixture hid a capability check that never matched.
		_pcc_issue_comments() {
			jq -nc --arg reason "$fixture_reason" '[[{id:10,body:("Terminal blocker: reason="+$reason+" owner=runner-recovery")}]]'
			return 0
		}
		_pr_checkpoint_trusted_logins() { printf '["runner"]\n'; return 0; }
		_pcc_blocked_release_evidence() { printf '10\tattempt:x\tfalse\t-\n'; return 0; }
		gh() {
			local kind="$1" endpoint="${2:-}" payload="${6:-}"
			if [[ "$kind" == pr ]]; then
				printf '{"state":"OPEN","isDraft":true,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","author":{"login":"runner"}}\n'
			elif [[ "$kind" == api && "$endpoint" == */comments ]]; then
				attention_body="${payload#body=}"
			else return 1; fi
			return 0
		}
		_pcc_blocked_attention owner/repo 42 100 >/dev/null || exit 1
		[[ "$attention_body" == *'No brief change'* && "$attention_body" == *'approve <worktree>'* &&
			"$attention_body" != *'Next action for the brief owner'* && "$attention_body" != *'approval-template'* ]] || exit 1
		fixture_reason=files_scope_excluded
		_pcc_blocked_attention owner/repo 42 100 >/dev/null || exit 1
		[[ "$attention_body" == *'approval-template'* ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "capability checkpoint attention names runner remediation, not a brief revision" "$status"
	return 0
}

test_recovery_graphql_fallback() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local api_mode=rest graphql_reply='' result='' rc=0 valid_comments='' id=''
		local calls="${TEST_ROOT}/fallback-calls" entry="${TEST_ROOT}/fallback-entry.json"
		gh() {
			local kind="$1" endpoint="${2:-}"
			printf '%s\n' "$*" >>"$calls"
			[[ "$kind" == api ]] || return 1
			if [[ "$api_mode" == rest ]]; then
				[[ "$endpoint" != graphql ]] || return 1
				printf '[[{"id":7,"user":{"login":"runner"},"author_association":"NONE","body":"hold","created_at":"2026-10-30T01:00:00Z"}]]\n'
			elif [[ "$api_mode" == failed || "$endpoint" != graphql ]]; then
				return 1
			else
				printf '%s\n' "$graphql_reply"
			fi
			return 0
		}
		result=$(terminal_blocker_fetch_trusted_comments 42 owner/repo runner) || exit 1
		[[ "$(jq -r '.[0].id' <<<"$result")" == 7 ]] || exit 1
		! rg -q graphql "$calls" || exit 1
		api_mode=graphql
		# Two pages include same-second IDs, an untrusted comment and this
		# runner's own NONE comment. REST-shaped trust filtering stays intact.
		graphql_reply=$(jq -nc '[
			{data:{repository:{issue:{comments:{nodes:[
				{fullDatabaseId:"8",author:{login:"owner"},authorAssociation:"OWNER",body:"retry",createdAt:"2026-10-30T01:00:00Z"},
				{fullDatabaseId:"9",author:{login:"outsider"},authorAssociation:"NONE",body:"spoof",createdAt:"2026-10-30T01:00:00Z"}],
				pageInfo:{hasNextPage:true,endCursor:"next"}}}}}},
			{data:{repository:{issue:{comments:{nodes:[
				{fullDatabaseId:"10",author:{login:"runner"},authorAssociation:"NONE",body:"hold",createdAt:"2026-10-30T01:00:00Z"}],
				pageInfo:{hasNextPage:false,endCursor:null}}}}}}]')
		result=$(terminal_blocker_fetch_trusted_comments 42 owner/repo runner) || exit 1
		[[ "$(jq -c 'map(.id)' <<<"$result")" == '[8,10]' ]] || exit 1
		[[ "$(jq -r '.[1].created_at' <<<"$result")" == '2026-10-30T01:00:00Z' ]] || exit 1
		rg -q -- '--paginate --slurp.*endCursor' "$calls" || exit 1
		rg -q -- 'nodes\{fullDatabaseId ' "$calls" || exit 1
		valid_comments="$graphql_reply"
		for id in '"9007199254740991"' 9007199254740991; do
			graphql_reply=$(printf '%s' "$valid_comments" | jq -c --argjson id "$id" '.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId=$id')
			result=$(terminal_blocker_fetch_comments owner/repo 42) || exit 1
			[[ "$(printf '%s' "$result" | jq -r '.[-1].id')" == 9007199254740991 ]] || exit 1
		done
		# Invalid IDs on a later page invalidate all evidence, not just that node.
		for id in null true '{}' '[]' '"bad"' '""' 0 -1 1.5 '"1.5"' '"1e2"' '"9007199254740992"' 9007199254740992 '"90071992547409910"'; do
			graphql_reply=$(printf '%s' "$valid_comments" | jq -c --argjson id "$id" '.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId=$id')
			result=$(terminal_blocker_fetch_comments owner/repo 42) && exit 1
			[[ -z "$result" ]] || exit 1
		done
		graphql_reply=$(printf '%s' "$valid_comments" | jq -c 'del(.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId)')
		result=$(terminal_blocker_fetch_comments owner/repo 42) && exit 1
		[[ -z "$result" ]] || exit 1
		graphql_reply="$valid_comments"
		# Truncated, null and partial-error responses are not empty evidence.
		graphql_reply=$(jq -c '.[-1].data.repository.issue.comments.pageInfo.hasNextPage=true' <<<"$graphql_reply")
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"data":{"repository":{"issue":null}}}]'
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"errors":[{"message":"unavailable"}],"data":{"repository":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}]'
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='{"data":{"repository":{"issue":{"number":42,"title":"Brief","body":"scope","state":"OPEN","updatedAt":"now","labels":{"nodes":[{"name":"status:blocked"}],"pageInfo":{"hasNextPage":false}}}}}}'
		result=$(terminal_blocker_fetch_issue owner/repo 42) || exit 1
		jq -e '.state == "open" and .updated_at == "now" and .labels[0].name == "status:blocked"' <<<"$result" >/dev/null || exit 1
		graphql_reply=$(jq -c '.data.repository.issue.labels.pageInfo.hasNextPage=true' <<<"$graphql_reply")
		terminal_blocker_fetch_issue owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"data":{"search":{"nodes":[{"number":42}],"pageInfo":{"hasNextPage":false}}}}]'
		[[ "$(_tbr_seed_candidates owner/repo)" == 42 ]] || exit 1
		graphql_reply='[{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}]'
		[[ -z "$(_tbr_seed_candidates owner/repo)" ]] || exit 1
		unset WORKER_GITHUB_LOGIN AIDEVOPS_WORKER_GITHUB_LOGIN
		graphql_reply=runner
		[[ "$(_tbr_self_login)" == runner ]] || exit 1
		api_mode=failed
		_tbr_self_login >/dev/null && exit 1
		terminal_blocker_fetch_trusted_comments 42 owner/repo runner >/dev/null && exit 1
		terminal_blocker_search_issues 'repo:owner/repo is:issue' >/dev/null && exit 1
		printf '{"repo":"owner/repo","issue":42,"reason":"unknown"}\n' >"$entry"
		_tbr_check_entry "$entry" rearm >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 2 && -f "$entry" ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "recovery falls back to paginated GraphQL without weakening trust or retiring incomplete evidence" "$status"
	return 0
}

# GH#36114 fixtures. Emulate `gh api --paginate --jq` by applying the caller's
# production filter to every fixture page (incomplete_results included).
_discovery_search_pages() {
	local filter="" prev="" arg="" page=""
	for arg in "$@"; do
		[[ "$prev" != --jq ]] || filter="$arg"
		prev="$arg"
	done
	[[ -n "$filter" ]] || return 1
	for page in "${TB_DISCOVERY_FIXTURE}"/search-page-*.json; do
		[[ -f "$page" ]] || continue
		jq -r "$filter" "$page" 2>/dev/null || return 1
	done
	return 0
}

_discovery_gh() {
	local args="$*" path="${2:-}" file="" key=""
	printf '%s\n' "$args" >>"${TB_DISCOVERY_FIXTURE}/requests"
	case "$args" in
	"api -X GET search/issues --paginate "*)
		[[ "$args" == *"-f per_page=100"* ]] || return 1
		_discovery_search_pages "$@"
		return $?
		;;
	"api repos/owner/repo") printf '{"permissions":{"push":true},"default_branch":"main"}\n' ;;
	"api -X GET repos/owner/repo/commits"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
	"api -X GET repos/owner/repo/contents/.aidevops.json"*) printf 'HTTP 404\n' >&2; return 1 ;;
	"api repos/"*"/comments?per_page=100 --paginate --slurp")
		[[ "$path" =~ ^repos/([^/]+)/([^/]+)/issues/([0-9]+)/comments ]] || return 1
		key="${BASH_REMATCH[1]}--${BASH_REMATCH[2]}--${BASH_REMATCH[3]}"
		file="${TB_DISCOVERY_FIXTURE}/comments-${key}.json"
		printf '%s\n' "$key" >>"${TB_DISCOVERY_FIXTURE}/comment-reads"
		[[ ! -f "${file%.json}.slow" ]] || sleep 5
		[[ -f "$file" ]] || return 1
		jq -c . "$file"
		;;
	"api repos/owner/repo/issues/42") jq -c . "${TB_DISCOVERY_FIXTURE}/issue-42.json" ;;
	*) return 1 ;;
	esac
	return 0
}

# Page fixture; each ref is "owner/repo number updated_at".
_discovery_page() {
	local page="$1" incomplete="$2"
	shift 2
	printf '%s\n' "$@" | jq -Rn --argjson incomplete "$incomplete" '
		{incomplete_results: $incomplete, items: [inputs | split(" ") |
			{repository_url: ("https://ghe.invalid/api/v3/repos/" + .[0]), number: (.[1] | tonumber), updated_at: .[2]}]}' \
		>"${TB_DISCOVERY_FIXTURE}/search-page-${page}.json"
	return 0
}

_discovery_comments() {
	local key="$1" login="$2" association="$3" body="$4"
	jq -nc --arg login "$login" --arg association "$association" --arg body "$body" \
		'[[{id:10,user:{login:$login},author_association:$association,created_at:"2026-10-30T00:00:00Z",body:$body}]]' \
		>"${TB_DISCOVERY_FIXTURE}/comments-${key}.json"
	return 0
}

# Interrupted discovery keeps its cursor and window; the next real CLI pass
# resumes after the stalled candidate and completes.
_discovery_timeout_checks() {
	local observation="$1" rc=0
	TBR_ROOT="${TEST_ROOT}/discovery-timeout"
	TBR_REPOS_JSON="${TEST_ROOT}/discovery-repos.json"
	export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT" REPOS_JSON="$TBR_REPOS_JSON"
	export BLOCKER_RECOVERY_BUDGET_SECONDS=6 BLOCKER_RECOVERY_STAGE_SECONDS=2
	_tbr_init_dirs || return 1
	rm -f "${TB_DISCOVERY_FIXTURE}"/search-page-*.json
	_discovery_page 1 false 'owner/repo 50 2026-10-30T01:00:00Z' 'owner/repo 51 2026-10-30T01:00:00Z'
	_discovery_comments owner--repo--50 other-runner MEMBER "$observation"
	_discovery_comments owner--repo--51 other-runner MEMBER "$observation"
	: >"${TB_DISCOVERY_FIXTURE}/comments-owner--repo--50.slow"
	export -f gh _discovery_gh _discovery_search_pages
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" discover 2>/dev/null || rc=$?
	[[ "$rc" -eq 2 && "$(cut -f2 "${TBR_ROOT}/discovery_cursor")" == 50 ]] || return 1
	[[ ! -f "${TBR_ROOT}/last_discovery_epoch" && ! -f "${TBR_ROOT}/queue/owner--repo--51.json" ]] || return 1
	rm -f "${TB_DISCOVERY_FIXTURE}/comments-owner--repo--50.slow"
	: >"${TB_DISCOVERY_FIXTURE}/comment-reads"
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" discover 2>/dev/null || return 1
	[[ "$(head -1 "${TB_DISCOVERY_FIXTURE}/comment-reads")" == owner--repo--51 ]] || return 1
	[[ -s "${TBR_ROOT}/last_discovery_epoch" && ! -f "${TBR_ROOT}/discovery_cursor" ]] || return 1
	[[ -f "${TBR_ROOT}/queue/owner--repo--50.json" && -f "${TBR_ROOT}/queue/owner--repo--51.json" ]] || return 1
	return 0
}

test_owner_scoped_discovery() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/discovery"
		TBR_REPOS_JSON="${TEST_ROOT}/discovery-repos.json"
		export TB_DISCOVERY_FIXTURE="${TEST_ROOT}/discovery-fixture" TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		mkdir -p "$TB_DISCOVERY_FIXTURE" || exit 1
		# Load shared runtime functions before installing write stubs.
		_tbr_start_budget || exit 1
		_tbr_init_dirs || exit 1
		jq -nc '{initialized_repos:[{slug:"owner/repo",pulse:true},{slug:"other/repo2",pulse:true},
			{slug:"owner/local",pulse:true,local_only:true},{slug:"third/quiet",pulse:false}]}' >"$TBR_REPOS_JSON"
		local issue_json='{"state":"open","title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		local revision="" fingerprint="" observation="" rc=0 projected=0 receipts=0
		revision=$(terminal_blocker_task_revision "$issue_json" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		observation="Terminal blocker: reason=permission_required owner=maintainer
<!-- ${_TBC_OBSERVATION_MARKER} revision=${revision} blocker=${fingerprint} -->"
		# Another trusted runner's observation is eligible; an untrusted author's is not.
		_discovery_comments owner--repo--42 other-runner MEMBER "$observation"
		_discovery_comments owner--repo--43 outsider NONE "$observation"
		_discovery_comments other--repo2--7 maintainer OWNER "$observation"
		_discovery_page 1 false 'owner/repo 42 2026-10-30T01:00:00Z' 'owner/repo 43 2026-10-30T01:00:00Z' \
			'owner/repo 44 2026-10-30T01:00:00Z'
		_discovery_page 2 false 'Other/Repo2 7 2026-10-30T01:00:00Z' 'owner/local 9 2026-10-30T01:00:00Z' \
			'stranger/repo 5 2026-10-30T01:00:00Z'
		gh() { _discovery_gh "$@"; return $?; }
		_tbr_policy_enabled() { return 1; }
		# Every page is read; the REST path no longer stops at the first page.
		[[ "$(terminal_blocker_search_issues q | wc -l | tr -d ' ')" == 6 ]] || exit 1
		tbr_enqueue owner/repo 44 permission_required || exit 1
		: >"${TB_DISCOVERY_FIXTURE}/requests"
		tbr_discover 2>/dev/null || exit 1
		# Only another runner observed it: public evidence only (excerpt
		# gating is covered in test-recovery-policy.sh).
		[[ "$(jq -r '.reason + " " + .intake' "${TBR_ROOT}/queue/owner--repo--42.json")" == "permission_required remote_observation" ]] || exit 1
		[[ -f "${TBR_ROOT}/queue/other--repo2--7.json" && ! -f "${TBR_ROOT}/queue/owner--repo--43.json" ]] || exit 1
		[[ ! -f "${TBR_ROOT}/queue/owner--local--9.json" && ! -f "${TBR_ROOT}/queue/stranger--repo--5.json" ]] || exit 1
		# Queued and unregistered refs are never read.
		[[ "$(sort "${TB_DISCOVERY_FIXTURE}/comment-reads" | tr '\n' ' ')" == 'other--repo2--7 owner--repo--42 owner--repo--43 ' ]] || exit 1
		[[ -s "${TBR_ROOT}/last_discovery_epoch" && ! -f "${TBR_ROOT}/discovery_cursor" ]] || exit 1
		# One owner-scoped search for both pulse owners, no window on backfill.
		[[ "$(rg -c 'search/issues' "${TB_DISCOVERY_FIXTURE}/requests")" == 1 ]] || exit 1
		rg -q -F 'in:comments user:other user:owner -f per_page=100' "${TB_DISCOVERY_FIXTURE}/requests" || exit 1
		! rg -q -e 'user:third' -e 'updated:' "${TB_DISCOVERY_FIXTURE}/requests" || exit 1
		# Unchanged evaluated issues are not re-read or re-queued after the queue
		# retires them; an updated one is evaluated again inside the window.
		rm -f "${TBR_ROOT}/queue/owner--repo--42.json"
		: >"${TB_DISCOVERY_FIXTURE}/comment-reads"
		: >"${TB_DISCOVERY_FIXTURE}/requests"
		_discovery_page 1 false 'owner/repo 42 2026-10-30T01:00:00Z' 'owner/repo 43 2026-10-30T03:00:00Z' \
			'owner/repo 44 2026-10-30T01:00:00Z'
		tbr_discover 2>/dev/null || exit 1
		[[ "$(<"${TB_DISCOVERY_FIXTURE}/comment-reads")" == owner--repo--43 && ! -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || exit 1
		rg -q -F 'in:comments updated:>=' "${TB_DISCOVERY_FIXTURE}/requests" || exit 1
		# incomplete_results is a failed read: no GraphQL answer means incomplete,
		# and the window does not advance.
		printf '1000\n' >"${TBR_ROOT}/last_discovery_epoch"
		_discovery_page 2 true 'Other/Repo2 7 2026-10-30T01:00:00Z'
		terminal_blocker_search_issues q >/dev/null && exit 1
		tbr_discover 2>/dev/null || rc=$?
		[[ "$rc" -eq 2 && "$(<"${TBR_ROOT}/last_discovery_epoch")" == 1000 ]] || exit 1
		# rearm: discovery queues a hold no runner had queued, and the queue pass
		# applies its later trusted retry in the same run.
		TBR_ROOT="${TEST_ROOT}/discovery-rearm"
		_tbr_init_dirs || exit 1
		rm -f "${TB_DISCOVERY_FIXTURE}"/search-page-*.json
		_discovery_page 1 false 'owner/repo 42 2026-10-30T02:00:00Z'
		jq -c '.[0] += [{id:11,user:{login:"maintainer"},author_association:"OWNER",created_at:"2026-10-30T01:30:00Z",body:"terminal-blocker-circuit:retry"}]' \
			"${TB_DISCOVERY_FIXTURE}/comments-owner--repo--42.json" >"${TB_DISCOVERY_FIXTURE}/retry.json" || exit 1
		mv -f "${TB_DISCOVERY_FIXTURE}/retry.json" "${TB_DISCOVERY_FIXTURE}/comments-owner--repo--42.json" || exit 1
		jq -c '. + {updated_at:"2026-10-30T02:00:00Z"}' <<<"$issue_json" >"${TB_DISCOVERY_FIXTURE}/issue-42.json" || exit 1
		_tbr_run_stage() { shift; "$@"; return $?; }
		tbr_seed() { exit 1; }
		_tbr_decision_active() { exit 1; }
		terminal_blocker_fetch_trusted_comments() { jq -c flatten "${TB_DISCOVERY_FIXTURE}/comments-owner--repo--42.json"; return 0; }
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() { receipts=$((receipts + 1)); return 0; }
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 && ! -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || exit 1
		[[ -s "${TBR_ROOT}/last_discovery_epoch" && -f "${TBR_ROOT}/discovered/owner--repo--42" ]] || exit 1
		# CLI subprocesses re-source the helper; in-process stubs do not leak.
		_discovery_timeout_checks "$observation" || exit 1
		exit 0
	); then status=1; fi
	print_result "owner-scoped discovery paginates, queues unqueued trusted holds once, resumes interrupted passes, and lets rearm apply retries" "$status"
	return 0
}
