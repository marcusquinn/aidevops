#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by terminal-blocker-recovery-helper.sh (GH#38311).
#
# Maintainer-decision holds (hold-for-review) had no wake path: a maintainer's
# reply on the issue changed nothing until someone ran an interactive session,
# and a hold could sit with no stated reason. This stage queues two intakes
# for the runner-local AI recovery supervisor:
#   answered_hold    an unsigned, non-automation OWNER/MEMBER comment by this
#                    runner's own login after the latest hold label: the
#                    replying maintainer's runner carries out what it decides.
#   unexplained_hold a hold this runner's login applied more than
#                    BLOCKER_RECOVERY_HOLD_EXPLAIN_AGE ago, with no trusted
#                    comment from TBR_HOLD_EXPLAIN_LEAD before the label onward.
# #aidevops:trust-boundary — the stage only queues evidence. It never labels,
# comments, closes or removes a hold; the supervisor applies
# reference/worker-discipline.md "Maintainer replies on held issues".

TBR_HOLD_LABEL="hold-for-review"
TBR_HOLD_INTERVAL="${BLOCKER_RECOVERY_HOLD_INTERVAL:-3600}"
TBR_HOLD_EXPLAIN_AGE="${BLOCKER_RECOVERY_HOLD_EXPLAIN_AGE:-86400}"
TBR_HOLD_MAX="${BLOCKER_RECOVERY_HOLD_MAX:-10}"
# The comment that explains a hold is often posted just before the label.
TBR_HOLD_EXPLAIN_LEAD=3600
_TBR_HOLD_EVALUATED=0
# Comment and label predicates. Input for hold_excluded: label names.
# machine_notice: claim, dispatch, ops and blocker records explain no hold.
# automation adds AI-signed provenance; a human reply has neither, nor the
# signature footer. #aidevops:trust-boundary
# shellcheck disable=SC2016 # jq variables are bound by callers.
_TBR_HOLD_JQ='
def hold_excluded: any(.[]; . == "needs-maintainer-review" or . == "needs-maintainer-permissions"
	or . == "status:in-progress" or . == "status:claimed");
def comment_author: .author // .user.login // "";
def maintainer: (.author_association // "") | . == "OWNER" or . == "MEMBER";
def trusted_or($self): maintainer or ($self != "" and comment_author == $self);
def comment_epoch: (.created_at // "") | try fromdateiso8601 catch null;
def machine_notice: (.body // "") | test("<!-- ops:start|aidevops:terminal-blocker-|<!-- dispatch-|aidevops:ops |aidevops:dispatch |aidevops-interactive-claim|aidevops:hold-reply:|(?m)^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED|TERMINAL_BLOCKER_CIRCUIT) ");
def automation: machine_notice or ((.body // "") | test("aidevops:origin:(worker|interactive)|<!-- aidevops:sig -->"));
def human_reply: automation | not;
def flat_comments: if type == "array" then [.[] | if type == "array" then .[] else . end] else error("comments") end;
'

#######################################
# 0 when an OWNER/MEMBER (or this runner's own login) human reply is newer
# than the epoch, 1 otherwise or on unreadable comments. Accepts flattened
# trusted comments or raw paginated REST pages. A newer reply ends the
# suppression of a recorded decision so the supervisor re-assesses it.
# Args: comments_json epoch
#######################################
_tbr_reply_after() {
	local comments="$1" since="$2"
	[[ "$since" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$comments" | jq -e --argjson since "$since" --arg self "${TERMINAL_BLOCKER_SELF_LOGIN:-}" "${_TBR_HOLD_JQ}"'
		any(flat_comments[]; trusted_or($self) and human_reply and ((comment_epoch // 0) > $since))
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Classify one held issue from its label events and comments.
# Prints "answered<TAB>reply_id<TAB>0", "unexplained<TAB>0<TAB>0" or
# "none<TAB>0<TAB>due", where due is the epoch at which a not-yet-aged
# unexplained hold must be evaluated again (0 when none). Returns 1 on
# unreadable input, which callers treat as incomplete evidence.
# Args: events_json comments_json self_login handled_reply_id now_epoch
#######################################
_tbr_hold_verdict() {
	local events="$1" comments="$2" self="$3" handled="$4" now="$5"
	[[ "$self" =~ ^[A-Za-z0-9-]+$ && "$handled" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n%s\n' "$events" "$comments" | jq -rse --arg self "$self" --argjson handled "$handled" \
		--argjson now "$now" --arg label "$TBR_HOLD_LABEL" --argjson age "$TBR_HOLD_EXPLAIN_AGE" \
		--argjson lead "$TBR_HOLD_EXPLAIN_LEAD" "${_TBR_HOLD_JQ}"'
		if length != 2 then error("inputs") else . end
		| (.[0] | flat_comments) as $events | (.[1] | flat_comments) as $comments
		| ([$events[] | select(.event == "labeled" and (.label.name // "") == $label)] | sort_by(.created_at) | last) as $hold
		| if $hold == null then "none\t0\t0" else
			($hold.created_at | fromdateiso8601) as $at
			# Only trusted receipts count: an untrusted fake must not suppress a wake.
			| ([$comments[] | select(trusted_or($self))
				| (.body // "") | scan("aidevops:hold-reply:([0-9]+)") | .[0] | tonumber]) as $receipts
			# A reply must also be maintainer-side: a collaborator runner never
			# overrides a hold. #aidevops:trust-boundary
			| [$comments[] | select(comment_author == $self and maintainer
				and human_reply and (comment_epoch // 0) > $at
				and (.id | type) == "number" and .id > $handled)
				| select(.id as $id | any($receipts[]; . == $id) | not)] as $replies
			| [$comments[] | select(trusted_or($self))
				| select((machine_notice | not) and (comment_epoch // 0) >= ($at - $lead))] as $explained
			| if ($replies | length) > 0 then "answered\t\($replies | max_by(.id) | .id)\t0"
			elif ($hold.actor.login // "") != $self or ($explained | length) > 0 then "none\t0\t0"
			elif ($now - $at) >= $age then "unexplained\t0\t0"
			else "none\t0\t\($at + $age)" end
		end
	' 2>/dev/null || return 1
	return 0
}

# Paginated listing of open hold-for-review issues without an excluded label.
# Prints "number<TAB>updatedAt" sorted by number; any read or shape failure
# returns 2 and prints nothing, because an unreadable listing is not absence.
_tbr_hold_listing() {
	local repo="$1" pages=""
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	pages=$(gh api graphql --paginate --slurp -f owner="${repo%%/*}" -f name="${repo#*/}" -f label="$TBR_HOLD_LABEL" \
		-f query='query($owner:String!,$name:String!,$label:String!,$endCursor:String){repository(owner:$owner,name:$name){issues(states:OPEN,labels:[$label],first:100,after:$endCursor){nodes{number updatedAt labels(first:50){nodes{name} pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}}}' \
		2>/dev/null) || return 2
	printf '%s' "$pages" | jq -r "${_TBR_SHAPE_JQ}${_TBR_HOLD_JQ}"'
		if arr and length > 0
			and all(.[]; (.errors // [] | length) == 0 and (.data.repository.issues.nodes | arr))
			and .[-1].data.repository.issues.pageInfo.hasNextPage == false
		then [.[] | .data.repository.issues.nodes[]] else error("invalid listing") end
		| if all(.[]; (.number | type) == "number" and (.updatedAt | type) == "string"
			and (.labels.nodes | arr) and (.labels.pageInfo.hasNextPage | bool))
		then . else error("invalid node") end
		| sort_by(.number)[]
		| select(.labels.pageInfo.hasNextPage == false and (.labels.nodes | map(.name) | hold_excluded | not))
		| "\(.number)\t\(.updatedAt)"
	' 2>/dev/null || return 2
	return 0
}

# Fresh reads and classification for one held issue; the shared verdict is
# used by discovery and by the queued-entry check. Prints the verdict line.
_tbr_hold_read_verdict() {
	local slug="$1" issue="$2" self="$3" handled="$4" now="$5" events="" comments=""
	printf 'blocker-recovery: checking stage=hold_issue repo=%s issue=%s\n' "$slug" "$issue" >&2
	events=$(gh api "repos/${slug}/issues/${issue}/events?per_page=100" --paginate --slurp 2>/dev/null) || return 2
	comments=$(terminal_blocker_fetch_comments "$slug" "$issue") || return 2
	_tbr_hold_verdict "$events" "$comments" "$self" "$handled" "$now" || return 2
	return 0
}

# Memo "updatedAt|due_epoch|handled_reply_id" per issue: unchanged issues are
# skipped until due, and a handled reply is never queued again. The separator
# is not IFS whitespace, so an empty first field survives `read`.
_tbr_hold_memo_read() {
	local key="$1" seen="" due="" handled=""
	[[ ! -f "${TBR_ROOT}/holds-evaluated/${key}" ]] ||
		IFS='|' read -r seen due handled <"${TBR_ROOT}/holds-evaluated/${key}" || true
	[[ "$due" =~ ^[0-9]+$ ]] || due=0
	[[ "$handled" =~ ^[0-9]+$ ]] || handled=0
	printf '%s|%s|%s\n' "$seen" "$due" "$handled"
	return 0
}

_tbr_hold_memo_write() {
	local key="$1" updated="$2" due="$3" handled="$4"
	mkdir -p "${TBR_ROOT}/holds-evaluated" || return 1
	_tbr_save_cursor "holds-evaluated/${key}" "${updated}|${due}|${handled}" || return 1
	return 0
}

# Queue one listed held issue when it has an unhandled reply or no stated
# reason. Returns 0 when queued, skipped or ineligible, 2 on unreadable
# evidence or a failed write (the issue is evaluated again next pass), 3 when
# the per-pass evaluation cap is reached before any read.
_tbr_hold_intake() {
	local slug="$1" issue="$2" listed_at="$3" self="$4" now="$5"
	local key="" seen="" due=0 handled=0 verdict="" kind="" reply="" next_due=0
	key=$(_tbr_key "$slug" "$issue")
	# Already queued: the queue pass owns it.
	[[ ! -f "${TBR_ROOT}/queue/${key}.json" ]] || return 0
	IFS='|' read -r seen due handled <<<"$(_tbr_hold_memo_read "$key")"
	if [[ -n "$seen" && "$seen" == "$listed_at" ]] && [[ "$due" -eq 0 || "$now" -lt "$due" ]]; then
		return 0
	fi
	[[ "$_TBR_HOLD_EVALUATED" -lt "$TBR_HOLD_MAX" ]] || return 3
	_TBR_HOLD_EVALUATED=$((_TBR_HOLD_EVALUATED + 1))
	verdict=$(_tbr_hold_read_verdict "$slug" "$issue" "$self" "$handled" "$now") || return 2
	IFS=$'\t' read -r kind reply next_due <<<"$verdict"
	case "$kind" in
	answered)
		[[ "$reply" =~ ^[1-9][0-9]*$ ]] || return 2
		tbr_enqueue "$slug" "$issue" unknown answered_hold "{\"reply_comment_id\":${reply}}" || return 2
		;;
	unexplained) tbr_enqueue "$slug" "$issue" unknown unexplained_hold || return 2 ;;
	esac
	_tbr_hold_memo_write "$key" "$listed_at" "${next_due:-0}" "$handled" || return 2
	return 0
}

# One repo of the holds stage. 0 complete, 2 incomplete, 3 cap reached.
_tbr_holds_repo() {
	local slug="$1" self="$2" now="$3" listing="" number="" listed_at="" incomplete=0 rc=0
	local rkey="${slug//\//--}" cursor="" row="" list=""
	list="${TBR_ROOT}/holds/${rkey}.list"
	# GH#40656: keep the snapshot and attempted-item cursor across stage kills.
	# Rotate rather than discard attempted items: an interrupted/failed read is
	# retried after its peers, never treated as a completed observation.
	if [[ ! -f "$list" ]]; then
		printf 'blocker-recovery: checking stage=hold_list repo=%s\n' "$slug" >&2
		listing=$(_tbr_hold_listing "$slug") || return 2
		_tbr_save_cursor "holds/${rkey}.list" "$listing" || return 2
		_tbr_restore_cursor "holds/${rkey}.cursor" "" || return 2
	fi
	[[ ! -f "${TBR_ROOT}/holds/${rkey}.cursor" ]] || read -r cursor <"${TBR_ROOT}/holds/${rkey}.cursor" || true
	listing=$(_tbr_rotate "$(<"$list")" "$cursor") || return 2
	printf 'blocker-recovery: resuming stage=holds repo=%s cursor=%s\n' "$slug" "${cursor%%$'\t'*}" >&2
	while IFS=$'\t' read -r number listed_at; do
		[[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
		# Do not move past an item the per-pass cap prevented us from reading.
		[[ "$_TBR_HOLD_EVALUATED" -lt "$TBR_HOLD_MAX" ]] || return 3
		printf -v row '%s\t%s' "$number" "$listed_at"
		_tbr_save_cursor "holds/${rkey}.cursor" "$row" || return 2
		rc=0
		_tbr_hold_intake "$slug" "$number" "$listed_at" "$self" "$now" || rc=$?
		[[ "$rc" -ne 3 ]] || return 3
		[[ "$rc" -eq 0 ]] || incomplete=1
	done <<<"$listing"
	# A full traversal may refresh its snapshot even after a quick read error;
	# otherwise one permanently failing issue hides newly held issues forever.
	# Killed/capped traversals never reach this cleanup and retain their place.
	rm -f "$list" "${TBR_ROOT}/holds/${rkey}.cursor"
	[[ "$incomplete" -eq 0 ]] || return 2
	return 0
}

#######################################
# GH#38311 stage: every pulse repo at most every TBR_HOLD_INTERVAL seconds.
# A repo is stamped only after a complete pass; the per-pass cap bounds fresh
# reads, and the memo lets the next pass skip issues already evaluated.
#######################################
tbr_discover_holds() {
	_tbr_init_dirs || return 1
	local dir="${TBR_ROOT}/holds" repos="" slug="" rkey="" last=0 now="" self="" incomplete=0 rc=0 repo_cursor=""
	mkdir -p "$dir" "${TBR_ROOT}/holds-evaluated" || return 1
	[[ "$TBR_HOLD_INTERVAL" =~ ^[0-9]+$ && "$TBR_HOLD_EXPLAIN_AGE" =~ ^[0-9]+$ ]] || return 2
	[[ "$TBR_HOLD_MAX" =~ ^[1-9][0-9]*$ ]] || return 2
	now=$(date +%s)
	repos=$(_tbr_pulse_repos) || return 2
	[[ ! -f "${TBR_ROOT}/holds_repo_cursor" ]] || read -r repo_cursor <"${TBR_ROOT}/holds_repo_cursor" || true
	repos=$(_tbr_rotate "$repos" "$repo_cursor") || return 2
	_TBR_HOLD_EVALUATED=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_tbr_valid_ref "$slug" 1 || {
			incomplete=1
			continue
		}
		rkey="${slug//\//--}"
		last=0
		[[ ! -f "${dir}/${rkey}.epoch" ]] || read -r last <"${dir}/${rkey}.epoch" || true
		[[ "$last" =~ ^[0-9]+$ ]] || last=0
		[[ $((now - last)) -ge "$TBR_HOLD_INTERVAL" ]] || continue
		# Identity only when a repo is due: replies are matched to this login.
		if [[ -z "$self" ]]; then
			self="${TERMINAL_BLOCKER_SELF_LOGIN:-}"
			[[ -n "$self" ]] || self=$(_tbr_self_login) || return 2
		fi
		_tbr_save_cursor holds_repo_cursor "$slug" || return 2
		rc=0
		_tbr_holds_repo "$slug" "$self" "$now" || rc=$?
		[[ "$rc" -ne 3 ]] || return 0
		if [[ "$rc" -eq 0 ]]; then
			_tbr_save_cursor "holds/${rkey}.epoch" "$now" || return 2
		else
			incomplete=1
		fi
	done <<<"$repos"
	[[ "$incomplete" -eq 0 ]] || return 2
	rm -f "${TBR_ROOT}/holds_repo_cursor"
	find "${TBR_ROOT}/holds-evaluated" -type f -mtime +"$TBR_DISCOVERY_RETENTION_DAYS" -delete 2>/dev/null || true
	return 0
}

# 0 when the issue still carries the hold and no excluded label, 1 when not,
# 2 when its labels are unreadable.
_tbr_hold_labels_ok() {
	local issue_json="$1" rc=0
	jq -e --arg label "$TBR_HOLD_LABEL" "${_TBR_SHAPE_JQ}${_TBR_HOLD_JQ}"'
		(.labels | if arr then map(.name) else error("labels") end)
		| (index($label) != null) and (hold_excluded | not)
	' <<<"$issue_json" >/dev/null 2>&1 || rc=$?
	[[ "$rc" -le 1 ]] || return 2
	return "$rc"
}

#######################################
# Re-check an answered_hold or unexplained_hold entry (supervisor pass only).
# Retires it when the hold is gone or owned by a trust gate, when a decision
# was recorded after it was queued (an answered reply is then memoed as
# handled), or when fresh evidence no longer matches its intake. Otherwise
# prints the usual JSON line with public evidence only (plus the reply id).
# Makes no GitHub write. Returns 0 when printed, 1 otherwise, 2 on unreadable
# evidence. Args: file repo issue key issue_json opened_at intake
#######################################
_tbr_check_hold_entry() {
	local file="$1" repo="$2" issue="$3" key="$4" issue_json="$5" opened_at="$6" intake="$7"
	local rc=0 reply="" updated="" opened=0 recorded=0 verdict="" kind="" fresh="" handled=0 self=""
	reply=$(jq -r '.reply_comment_id // 0' "$file" 2>/dev/null) || reply=0
	[[ "$reply" =~ ^[0-9]+$ ]] || reply=0
	updated=$(jq -r '.updated_at // ""' <<<"$issue_json")
	_tbr_hold_labels_ok "$issue_json" || rc=$?
	[[ "$rc" -lt 2 ]] || return 2
	if [[ "$rc" -eq 1 ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	opened=$(jq -nr --arg t "$opened_at" '$t | fromdateiso8601' 2>/dev/null) || opened=0
	[[ ! -f "${TBR_ROOT}/decisions/${key}.json" ]] ||
		recorded=$(jq -r '.recorded_epoch // 0' "${TBR_ROOT}/decisions/${key}.json" 2>/dev/null) || recorded=0
	[[ "$recorded" =~ ^[0-9]+$ && "$opened" =~ ^[0-9]+$ ]] || recorded=0
	IFS='|' read -r _ _ handled <<<"$(_tbr_hold_memo_read "$key")"
	if [[ "$recorded" -gt 0 && "$recorded" -ge "$opened" ]]; then
		[[ "$intake" != answered_hold || "$reply" -le "$handled" ]] || handled="$reply"
		_tbr_hold_memo_write "$key" "$updated" 0 "$handled" || return 2
		rm -f "$file"
		return 1
	fi
	self="${TERMINAL_BLOCKER_SELF_LOGIN:-}"
	[[ -n "$self" ]] || self=$(_tbr_self_login) || return 2
	verdict=$(_tbr_hold_read_verdict "$repo" "$issue" "$self" "$handled" "$(date +%s)") || return 2
	IFS=$'\t' read -r kind fresh _ <<<"$verdict"
	if [[ "${kind}_hold" != "$intake" ]]; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	local extra='{}'
	[[ "$intake" != answered_hold ]] || extra="{\"reply_comment_id\":${fresh}}"
	_tbr_print_entry "$repo" "$issue" unknown "$opened_at" "$intake" "$issue_json" "$extra"
	return $?
}

#######################################
# t19178: re-check a persistent_exclusion entry (supervisor pass only). A
# deterministic dispatch filter has skipped this auto-dispatch issue for longer
# than AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS. Retires the entry and its
# decision (no GitHub write) once the filter stopped skipping it or the issue
# lost auto-dispatch; otherwise prints public evidence unless a recorded
# decision stands. Returns 0 when printed, 1 otherwise, 2 on unreadable labels.
# Args: file repo issue key issue_json reason opened_at
#######################################
_tbr_check_exclusion_entry() {
	local file="$1" repo="$2" issue="$3" key="$4" issue_json="$5" reason="$6" opened_at="$7"
	local has_label=""
	# arrays yields nothing for a malformed labels value: unreadable, keep the entry.
	has_label=$(jq -r '(.labels // []) | arrays | map(.name? // .) | index("auto-dispatch") != null' \
		<<<"$issue_json" 2>/dev/null) || return 2
	[[ -n "$has_label" ]] || return 2
	if [[ "$has_label" != true ]] ||
		! bash "${_TBR_SCRIPT_DIR}/dispatch-exclusion-age-helper.sh" active "$repo" "$issue" >/dev/null 2>&1; then
		rm -f "$file" "${TBR_ROOT}/decisions/${key}.json"
		return 1
	fi
	_tbr_decision_active "$key" && return 1
	_tbr_print_entry "$repo" "$issue" "$reason" "$opened_at" persistent_exclusion "$issue_json"
	return $?
}

#######################################
# Route one open entry of a supervisor-only intake to its checker. Returns the
# checker's status, or 3 when the intake has no dedicated checker (the caller
# continues with the circuit path).
# Args: file repo issue key issue_json reason opened_at intake
#######################################
_tbr_check_intake_entry() {
	local file="$1" repo="$2" issue="$3" key="$4" issue_json="$5" reason="$6" opened_at="$7" intake="$8"
	case "$intake" in
	unclassified_hold)
		_tbr_check_unclassified_entry "$file" "$repo" "$issue" "$key" "$issue_json" "$reason" "$opened_at"
		return $?
		;;
	answered_hold | unexplained_hold)
		_tbr_check_hold_entry "$file" "$repo" "$issue" "$key" "$issue_json" "$opened_at" "$intake"
		return $?
		;;
	persistent_exclusion)
		_tbr_check_exclusion_entry "$file" "$repo" "$issue" "$key" "$issue_json" "$reason" "$opened_at"
		return $?
		;;
	esac
	return 3
}
