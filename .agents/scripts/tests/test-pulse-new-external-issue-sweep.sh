#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT"
LOGFILE="$ROOT/pulse.log"
REPOS_JSON="$ROOT/repos.json"
_PIR_NMR_LABEL="needs-maintainer-review"
_PIR_ADD_LABEL_FLAG="--add-label"
_PIR_REMOVE_LABEL_FLAG="--remove-label"
_PIR_AUTO_DISPATCH_LABEL="auto-dispatch"
_PIR_STATUS_AVAILABLE="status:available"
# shellcheck source=../pulse-issue-reconcile-actions.sh
source "$TEST_DIR/../pulse-issue-reconcile-actions.sh"
# shellcheck source=../pulse-new-external-issues.sh
source "$TEST_DIR/../pulse-new-external-issues.sh"
_PIR_SCRIPT_DIR="$ROOT"
printf '%s\n' '#!/usr/bin/env bash' "[[ \"\$2\" == 4 ]] && printf 'VERIFIED\\n' || printf 'NO_APPROVAL\\n'" >"$ROOT/approval-helper.sh"
chmod +x "$ROOT/approval-helper.sh"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","pulse":true}]}' >"$REPOS_JSON"
MODE=normal
BUDGET=normal
SEARCH_LOG="$ROOT/search.log"
EDIT_LOG="$ROOT/edit.log"
touch "$SEARCH_LOG" "$EDIT_LOG" "$LOGFILE"

is_graphql_budget_sufficient() { return 0; }
_pulse_graphql_budget_priority_decision() {
	printf '%s 4000 5000 1250\n' "$BUDGET"
	return 0
}
_cb_gh_read() {
	"$@"
	return $?
}
_gh_actor_has_repo_write_authority() {
	local slug="$1" login="$2" association="$3"
	: "$slug" "$association"
	[[ "$login" == writer ]] && return 0
	return 1
}
gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$EDIT_LOG"
	return 0
}
gh() {
	local command="$1"
	shift
	if [[ "$command" == api && "${1:-}" == graphql ]]; then
		printf '%s\n' "$*" >>"$SEARCH_LOG"
		[[ "$MODE" != failure ]] || return 1
		if [[ "$MODE" == batches || "$MODE" == overflow ]]; then
			local count=0
			[[ "$MODE" != overflow || "$(wc -l <"$SEARCH_LOG")" -ne 1 ]] || count=1001
			jq -nc --argjson count "$count" '{data:{search:{issueCount:$count,nodes:[],pageInfo:{hasNextPage:false}}}}'
			return 0
		fi
		local second=false
		if [[ "$*" == *cursor=page2* ]]; then
			[[ ! -s "$EDIT_LOG" ]] || return 1
			second=true
		fi
		jq -n --arg mode "$MODE" --argjson second "$second" '
			def issue($n; $association; $login; $type; $labels):
			{number:$n,repository:{nameWithOwner:"owner/repo"},authorAssociation:$association,
			 author:{login:$login,__typename:$type},labels:{nodes:[$labels[]|{name:.}],pageInfo:{hasNextPage:false}}};
			{data:{search:{issueCount:6,pageInfo:{hasNextPage:false,endCursor:null},nodes:[
			 issue(1;"NONE";"outside";"User";if $mode == "rerun" then ["needs-maintainer-review","external-contributor"] else ["auto-dispatch","status:available"] end),
			 issue(2;"COLLABORATOR";"writer";"User";[]),
			 issue(3;"NONE";"robot";"Bot";[]),
			 issue(4;"CONTRIBUTOR";"approved";"User";[]),
			 issue(5;"OWNER";"owner";"User";[]),
			 issue(6;"MEMBER";"member";"User";[])]}}}
			| if $mode == "pages" then
				if $second then .data.search.nodes |= .[3:]
				else .data.search.nodes |= .[:3] |
				.data.search.pageInfo = {hasNextPage:true,endCursor:"page2"} end
			  elif $mode == "partial" then .errors = [{message:"incomplete"}]
			  elif $mode == "casing" then .data.search.nodes[].repository.nameWithOwner = "Owner/Repo"
			  else . end'
		return 0
	fi
	# Protected-label guard's live scanner/thread checks.
	printf '%s\n' '[[]]'
	return 0
}

reconcile_new_external_issues
[[ "$(wc -l <"$EDIT_LOG")" -eq 1 ]]
grep -q -- '--add-label needs-maintainer-review --add-label external-contributor' "$EDIT_LOG"
grep -q -- '--remove-label auto-dispatch --remove-label status:available' "$EDIT_LOG"
grep -q 'New external issue sweep: checked=6 gated=1' "$LOGFILE"
[[ -f "$HOME/.aidevops/state/pulse-new-external-issues.json" ]]
printf 'PASS external intake, write collaborator, owner, member, bot and approved exclusions\n'

MODE=rerun
reconcile_new_external_issues
[[ "$(wc -l <"$EDIT_LOG")" -eq 1 ]]
printf 'PASS rerun does not edit already-gated issue\n'

printf '{"last_run":100000}\n' >"$HOME/.aidevops/state/pulse-new-external-issues.json"
MODE=failure
if reconcile_new_external_issues; then exit 1; fi
[[ "$(jq -r .last_run "$HOME/.aidevops/state/pulse-new-external-issues.json")" == 100000 ]]
MODE=normal
BUDGET=reserve
calls="$(wc -l <"$SEARCH_LOG")"
if reconcile_new_external_issues; then exit 1; fi
[[ "$(wc -l <"$SEARCH_LOG")" -eq "$calls" ]]
[[ "$(jq -r .last_run "$HOME/.aidevops/state/pulse-new-external-issues.json")" == 100000 ]]
printf 'PASS failed query and reserve mode retain watermark without retry storms\n'

BUDGET=normal
MODE=pages
: >"$SEARCH_LOG"
: >"$EDIT_LOG"
reconcile_new_external_issues
[[ "$(wc -l <"$SEARCH_LOG")" -eq 2 && "$(wc -l <"$EDIT_LOG")" -eq 1 ]]
printf 'PASS all pages are read before any label mutation\n'

MODE=casing
: >"$EDIT_LOG"
reconcile_new_external_issues
[[ "$(wc -l <"$EDIT_LOG")" -eq 1 ]]
printf 'PASS repository allowlist matches canonical GitHub casing\n'

MODE=partial
: >"$EDIT_LOG"
if reconcile_new_external_issues; then exit 1; fi
[[ ! -s "$EDIT_LOG" ]]
printf 'PASS partial GraphQL errors never mutate issues\n'

MODE=overflow
: >"$SEARCH_LOG"
reconcile_new_external_issues
[[ "$(wc -l <"$SEARCH_LOG")" -eq 3 ]]
printf 'PASS oversized search splits its time window\n'

MODE=batches
: >"$SEARCH_LOG"
jq -n '{initialized_repos:[range(0;12)|{slug:("owner/long-repository-name-"+tostring),pulse:true}]}' >"$REPOS_JSON"
reconcile_new_external_issues
[[ "$(wc -l <"$SEARCH_LOG")" -gt 1 ]]
for number in {0..11}; do
	grep -q "repo:owner/long-repository-name-${number} " "$SEARCH_LOG"
done
while IFS= read -r search; do
	search="${search##*search=}"
	[[ "${#search}" -le 240 ]]
done <"$SEARCH_LOG"
printf 'PASS repository batching includes every repo within search length limit\n'

# An unavailable approval verifier cannot be treated as NO_APPROVAL.
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$ROOT/approval-helper.sh"
: >"$EDIT_LOG"
_action_reconcile_external_issue_gate owner/repo 7 "" NONE outside || true
[[ ! -s "$EDIT_LOG" && "$_PIR_EXTERNAL_GATE_MUTATED" -eq 0 ]]
printf 'PASS unavailable approval verification leaves labels unchanged\n'

# Prove the runtime call order without prefetch data or a functioning single pass.
# shellcheck source=../pulse-dispatch-preflight-lib.sh
source "$TEST_DIR/../pulse-dispatch-preflight-lib.sh"
ORDER="$ROOT/order"
prefetch_contribution_watch() { return 0; }
_log_substage_timing() { return 0; }
run_stage_with_timeout() {
	local stage="$1"
	printf '%s\n' "$stage" >>"$ORDER"
	[[ "$stage" != reconcile_issues_single_pass ]] || return 124
	return 0
}
_preflight_ownership_reconcile 600
[[ "$(sed -n '1p' "$ORDER")" == reconcile_new_external_issues ]]
[[ "$(sed -n '2p' "$ORDER")" == reconcile_issues_single_pass ]]
printf 'PASS live sweep runs before budget-aborted cached single pass\n'
