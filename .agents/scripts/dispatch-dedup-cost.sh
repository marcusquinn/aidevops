#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-cost.sh — Cost-per-issue circuit breaker for dispatch dedup (t2007)
#
# Extracted from dispatch-dedup-helper.sh (GH#18917) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by dispatch-dedup-helper.sh. Depends on
# shared-constants.sh being sourced first (for set_issue_status).
# SCRIPT_DIR must be set by the sourcing script.
#
# Functions in this module (in source order):
#   - _get_cost_budget_for_tier
#   - _sum_issue_token_spend
#   - _issue_has_cost_breaker_comment
#   - _apply_cost_breaker_side_effects
#   - _check_cost_budget

[[ -n "${_DISPATCH_DEDUP_COST_LOADED:-}" ]] && return 0
_DISPATCH_DEDUP_COST_LOADED=1

#######################################
# Cost-per-issue circuit breaker (t2007)
# ─────────────────────────────────────────
# Tracks cumulative token spend across all worker attempts on an issue
# by parsing signature-footer patterns ("spent N tokens" / "has used N
# tokens") from comments. When spend exceeds the tier-appropriate budget,
# the breaker applies status:blocked, posts one explanatory comment per issue,
# and emits the COST_BUDGET_EXCEEDED signal.
#
# Design (paired with t1986 parent-task guard and t2008 stale escalation):
#   1. The breaker check runs in is_assigned() AFTER the parent-task
#      short-circuit (which is unconditional) but BEFORE the assignee
#      check. Cost-tripped issues should be blocked regardless of who
#      is assigned.
#   2. Aggregation parses ALL comments (not just the authenticated
#      user's) — multiple runners may have worked on the same issue,
#      and the budget is per-ISSUE, not per-runner.
#   3. Failure mode: fail-open. If we can't compute spend (gh failure,
#      no comments, jq error), allow dispatch. The breaker is a safety
#      net, not a hard gate. The other dedup layers still apply.
#   4. Side effects are idempotent through the status state machine and the
#      prior cost-circuit-breaker:fired marker.
#######################################

#######################################
# Look up the per-tier cost budget from .agents/configs/dispatch-cost-budgets.conf.
# Args: $1 = tier label or short name (simple|standard|thinking|tier:simple|...)
# Stdout: integer token budget
#######################################
_get_cost_budget_for_tier() {
	local tier="$1"
	local _conf="${SCRIPT_DIR}/../configs/dispatch-cost-budgets.conf"
	# Defaults match the documented tier sizing (see dispatch-cost-budgets.conf)
	local COST_BUDGET_SIMPLE=800000
	local COST_BUDGET_STANDARD=800000
	local COST_BUDGET_THINKING=800000
	local COST_BUDGET_DEFAULT=800000
	if [[ -f "$_conf" ]]; then
		# shellcheck source=/dev/null
		source "$_conf"
	fi

	# Strip "tier:" prefix if present
	tier="${tier#tier:}"

	case "$tier" in
	simple) printf '%s' "$COST_BUDGET_SIMPLE" ;;
	standard) printf '%s' "$COST_BUDGET_STANDARD" ;;
	thinking) printf '%s' "$COST_BUDGET_THINKING" ;;
	*) printf '%s' "$COST_BUDGET_DEFAULT" ;;
	esac
	return 0
}

# GH#34598: installation-authenticated REST (pulse App routing) reports private
# org members as CONTRIBUTOR, so association alone dropped every closeout receipt
# and re-charged delivered work. Resolve ambiguous authors of checkpoint
# nominations (closeout markers, signed PR reports) through the collaborator
# permission endpoint; at most 5 distinct logins to bound REST calls.
# Args: repo slug, slurped comments JSON.
# Stdout: JSON array of logins with admin/maintain/write permission.
# Returns 1 on lookup failure (caller fail-open: cannot classify the evidence).
_COST_TRUSTED_ASSOCIATIONS='["OWNER","MEMBER","COLLABORATOR"]'
_cost_verified_nominator_logins() {
	local repo_slug="$1" comments_json="$2"
	local logins login permission lookup_rc
	local verified='[]'
	logins=$(printf '%s' "$comments_json" | jq -r --argjson assoc "$_COST_TRUSTED_ASSOCIATIONS" '
		[.[][] | select((.author_association // "NONE") as $a | $assoc | index($a) | not)
		 | select(.body // "" | test("<!-- PARTIAL_PARENT_CLOSEOUT:PR#[0-9]+ -->")
			or (contains("<!-- aidevops:sig -->") and test("\\bPR #[0-9]+\\b")))
		 | .user.login // empty] | unique | .[:5][]
	' 2>/dev/null) || return 1
	while IFS= read -r login; do
		[[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || continue
		permission=""
		lookup_rc=0
		#aidevops:trust-boundary GH#34598: only an authenticated write-level
		# permission verdict promotes an ambiguous association; a confirmed
		# non-collaborator (404 → none) stays untrusted, uncertainty fails open.
		# Without the shared lookup a 404 is indistinguishable from an outage,
		# so the bare fallback treats any failure as untrusted.
		if declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
			_gh_collaborator_permission_lookup "$repo_slug" "$login" permission || lookup_rc=$?
			[[ "$lookup_rc" -eq 0 ]] || return 1
		else
			permission=$(gh api "repos/${repo_slug}/collaborators/${login}/permission" \
				--jq '.permission // ""' 2>/dev/null) || permission=""
		fi
		case "$permission" in
		admin | maintain | write)
			verified=$(printf '%s' "$verified" | jq -c --arg login "$login" '. + [$login]') || return 1
			;;
		esac
	done <<<"$logins"
	printf '%s' "$verified"
	return 0
}

# GH#34248: GitHub can omit cross-reference events for delivered partial PRs.
# Closeout markers supply candidates only; verify each PR through REST before
# treating its actual merge time as a checkpoint. Never reset from prose alone.
# Args: issue number, repo slug, slurped comments JSON.
# Stdout: JSON with latest verified merge epoch and verified closeout PRs.
# Returns 1 on fetch/parse failure.
_cost_checkpoint_from_closeouts() {
	local issue_number="$1" repo_slug="$2" comments_json="$3"
	# Delivered checkpoints start a new spend window, not a lifetime budget.
	# Reference creation time is not merge time; unrelated PRs cannot reset spend.
	local timeline_json checkpoint_epoch
	timeline_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/timeline" --paginate --slurp 2>/dev/null) || return 1
	checkpoint_epoch=$(printf '%s' "$timeline_json" | jq -r --arg repo "$repo_slug" --arg issue "$issue_number" '
		[.[][]
		 | select(.event == "cross-referenced")
		 | .source.issue
		 | select(.repository.full_name == $repo)
		 | select(((.title // "") + "\n" + (.body // ""))
			| test("(?i)\\b(for|ref|resolves)\\s+#" + $issue + "([^0-9]|$)"))
		 | .pull_request.merged_at // empty
		 | fromdateiso8601] | max // 0
	' 2>/dev/null) || return 1

	# GH#34342: continuation workers often report merged checkpoints only as
	# "PR #N" prose in their signed comments, with neither timeline events nor a
	# closeout marker. Those mentions are candidates only (at most the three
	# highest numbers, to bound REST calls); unlike closeouts, an unreadable or
	# non-PR mention is skipped rather than failing the whole aggregation.
	local candidates kind pr_number pr_json merge_epoch trusted_logins
	local verified_closeouts='[]'
	trusted_logins=$(_cost_verified_nominator_logins "$repo_slug" "$comments_json") || return 1
	candidates=$(printf '%s' "$comments_json" | jq -r --argjson logins "$trusted_logins" \
		--argjson assoc "$_COST_TRUSTED_ASSOCIATIONS" '
		[.[][] | select(((.author_association // "NONE") as $a | $assoc | index($a) != null)
			or ((.user.login // "") as $who | $logins | index($who) != null))
		 | .body // ""] as $trusted
		| ([$trusted[] | scan("<!-- PARTIAL_PARENT_CLOSEOUT:PR#([0-9]+) -->") | .[0] | tonumber]
			| unique) as $closeouts
		| ($closeouts[] | "closeout \(.)"),
		  ([$trusted[] | select(contains("<!-- aidevops:sig -->"))
			| select(test("<!-- PARTIAL_PARENT_CLOSEOUT:PR#[0-9]+ -->") | not)
			| scan("\\bPR #([0-9]+)\\b") | .[0] | tonumber]
			| unique - $closeouts | reverse | .[:3][] | "report \(.)")
	' 2>/dev/null) || return 1
	while read -r kind pr_number; do
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue
		if ! pr_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null); then
			[[ "$kind" == "report" ]] && continue
			return 1
		fi
		if ! merge_epoch=$(printf '%s' "$pr_json" | jq -r --arg repo "$repo_slug" --arg issue "$issue_number" '
			select(.base.repo.full_name == $repo)
			| select(((.title // "") + "\n" + (.body // ""))
				| test("(?i)\\b(for|ref|resolves)\\s+#" + $issue + "([^0-9]|$)"))
			| .merged_at // empty | fromdateiso8601
		' 2>/dev/null); then
			[[ "$kind" == "report" ]] && continue
			return 1
		fi
		if [[ "$merge_epoch" =~ ^[0-9]+$ ]]; then
			if [[ "$kind" == "closeout" ]]; then
				verified_closeouts=$(printf '%s' "$verified_closeouts" | jq -c \
					--argjson pr "$pr_number" --argjson epoch "$merge_epoch" \
					'. + [{pr: $pr, epoch: $epoch}]') || return 1
			fi
			if [[ "$merge_epoch" -gt "$checkpoint_epoch" ]]; then
				checkpoint_epoch="$merge_epoch"
			fi
		fi
	done <<<"$candidates"
	jq -cn --argjson epoch "$checkpoint_epoch" --argjson closeouts "$verified_closeouts" \
		--argjson logins "$trusted_logins" \
		'{epoch: $epoch, closeouts: $closeouts, trusted_logins: $logins}' || return 1
	return 0
}

#######################################
# Sum token spend across all signature footers in an issue's comments.
# Aggregates ALL workers (no author filter) — the breaker is per-issue,
# not per-runner.
#
# Args: $1 = issue number, $2 = repo slug
# Stdout: "spent_tokens|attempt_count"
# Returns: 0 on success, 1 on fetch/parse failure (caller fail-open)
#######################################
_sum_issue_token_spend() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate --slurp 2>/dev/null) || return 1
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		return 1
	fi

	local checkpoint_data
	checkpoint_data=$(_cost_checkpoint_from_closeouts "$issue_number" "$repo_slug" \
		"$comments_json") || return 1

	_cost_spend_from_comments "$comments_json" "$checkpoint_data" || return 1
	return 0
}

# Aggregate fetched comments against verified checkpoint data, without API calls.
# Args: slurped comments JSON, checkpoint JSON. Stdout: spent_tokens|attempt_count.
# Returns 1 on parse failure or malformed output (caller fail-open).
_cost_spend_from_comments() {
	local comments_json="$1" checkpoint_data="$2"
	# Extract comment bodies, excluding interactive-session signature footers and
	# comments predating the latest approval, cost reset marker or merged checkpoint.
	# Interactive footers are maintainer triage/review activity that should
	# NOT count toward the per-issue worker cost budget — including them
	# produces false-positive circuit-breaker trips every time a maintainer
	# comments on an active issue (t2425 / GH#20047). Comments without either
	# marker (historical or non-standard footers) are kept: worker is the
	# fail-open default, matching the function's existing fail-open posture.
	#
	# t3077: a signed maintainer approval is also a budget reset boundary. Without
	# this, approving/removing NMR after a cost trip immediately re-trips on the
	# same historical worker footers and no new dispatch can occur.
	#
	# Footer shapes: "spent 30,000 tokens", "spent 4m and 30,000 tokens",
	# "spent 1h 30m and …", "spent 1d 3h and …", historical "has used N tokens".
	# The cumulative "N total tokens on this issue." line is intentionally NOT
	# matched — it is the running aggregate and would double-count.
	#
	# GH#34342: footer tokens and time are cumulative for the OpenCode session
	# (gh-signature-helper-session.sh), and continuation dispatches can resume
	# that session. A later footer then repeats every earlier footer's spend
	# ("6m and 89,214" → "6h 5m and 217,569" → "13h 2m and 356,637"). Footers
	# by the same author whose implied session start (created_at − duration,
	# widened by the display resolution and posting slack) overlaps and whose
	# tokens do not decrease are one session: count only the increment. A
	# pre-window footer of that session is the baseline, never window spend.
	local spend_data
	spend_data=$(printf '%s' "$comments_json" | jq -r --argjson checkpoint "$checkpoint_data" '
		def epoch: try ((.created_at // "") | fromdateiso8601) catch 0;
		# Durations are truncated to their smallest displayed unit
		# (_format_duration drops minutes once days are shown).
		def duration:
			if test("^[0-9]+[dhms]( [0-9]+[dhms])*$") then
				{secs: ([scan("([0-9]+)([dhms])")
					| (.[0] | tonumber) * ({"d": 86400, "h": 3600, "m": 60, "s": 1}[.[1]])] | add),
				 res: (if test("d") then 3600 elif test("[hm]") then 60 else 1 end)}
			else null end;
		120 as $slack
		| [.[][]] as $all
		| ($all | map(select(
				((.body // "") | contains("<!-- aidevops-signed-approval -->"))
				or ((.body // "") | contains("<!-- cost-circuit-breaker:reset"))
			) | epoch) + [$checkpoint.epoch] | max // 0) as $reset_epoch
		| [$all[]
			| select((.body // "") | contains("with the user in an interactive session") | not)
			| epoch as $t
			| ((.body // "") | test("<!-- PARTIAL_PARENT_CLOSEOUT:PR#[0-9]+ -->")) as $receipt
			# GH#34510: a trusted receipt posted within posting slack of its
			# verified merge supplies a cumulative session baseline, never spend.
			# Delayed copies cannot reliably identify the original session start.
			| select($receipt == false or (
				(.author_association == "OWNER" or .author_association == "MEMBER"
					or .author_association == "COLLABORATOR"
					# GH#34598: permission-verified author (ambiguous association).
					or ((.user.login // "") as $who
						| ($checkpoint.trusted_logins // []) | index($who) != null)) and
				([(.body // "" | scan("<!-- PARTIAL_PARENT_CLOSEOUT:PR#([0-9]+) -->")
					| .[0] | tonumber)] as $prs
				 | any($checkpoint.closeouts[]; .pr as $pr
					| ($prs | index($pr)) != null and $t >= .epoch and $t <= .epoch + $slack))))
			| (.user.login // "") as $who
			| (.body // "")
			| match("(spent|has used) (?:(.*) and )?([0-9,]+) tokens"; "g")
			| (.captures[2].string | gsub(","; "")) as $raw
			| select($raw | test("^[0-9]+$"))
			| ((.captures[1].string // "") | duration) as $dur
			| {t: $t, who: $who, tok: ($raw | tonumber),
			   inwin: ($receipt == false and (($reset_epoch == 0) or ($t > $reset_epoch))),
			   session: (if $dur != null and $who != "" and $t > 0 then
				{lo: ($t - $dur.secs - $dur.res - $slack), hi: ($t - $dur.secs + $slack)}
				else null end)}]
		| sort_by(.t)
		| reduce .[] as $f ({chains: [], total: 0, attempts: 0};
			(if $f.session == null then null else
				([.chains | to_entries[] | .value as $c
					| select($c.who == $f.who and $c.last <= $f.tok
						and $c.lo <= $f.session.hi and $f.session.lo <= $c.hi) | .key]
				 | last) end) as $idx
			| (if $idx == null then $f.tok else $f.tok - .chains[$idx].last end) as $inc
			| (if $f.session == null then .
				elif $idx == null then .chains += [$f.session + {who: $f.who, last: $f.tok}]
				else .chains[$idx] = ($f.session + {who: $f.who, last: $f.tok}) end)
			| if $f.inwin then .total += $inc | .attempts += 1 else . end)
		| "\(.total)|\(.attempts)"
	' 2>/dev/null) || return 1
	if [[ ! "$spend_data" =~ ^[0-9]+\|[0-9]+$ ]]; then
		return 1
	fi

	printf '%s' "$spend_data"
	return 0
}

#######################################
# Check whether a cost-breaker explanatory comment already exists.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#
# Returns:
#   0 = prior cost-circuit-breaker:fired marker found
#   1 = no marker found or comments could not be inspected (fail-open)
#######################################
_issue_has_cost_breaker_comment() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate --slurp 2>/dev/null) || return 1
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		return 1
	fi

	local marker_count
	marker_count=$(printf '%s' "$comments_json" | jq -r '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [.[] | select((.body // "") | test("cost-circuit-breaker:fired"))]
		| length
	' 2>/dev/null) || return 1
	if ! [[ "$marker_count" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ "$marker_count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

#######################################
# Apply cost-breaker side effects: structural block + one explanatory comment.
# The root-cause meta-issue provides the machine-recoverable release path.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = spent (tokens, integer)
#   $4 = budget (tokens, integer)
#   $5 = tier short name (simple|standard|thinking)
#   $6 = attempts count (integer)
#######################################
_apply_cost_breaker_side_effects() {
	local issue_number="$1"
	local repo_slug="$2"
	local spent="$3"
	local budget="$4"
	local tier="$5"
	local attempts="$6"
	# NMR is an external-author trust gate, not a circuit breaker. Preserve any
	# independently valid trust gate while recording the budget stop as lifecycle state.
	set_issue_status "$issue_number" "$repo_slug" "blocked" 2>/dev/null || true

	local _spent_k=$((spent / 1000))
	local _budget_k=$((budget / 1000))

	local already_commented="false"
	if _issue_has_cost_breaker_comment "$issue_number" "$repo_slug"; then
		already_commented="true"
	fi

	if [[ "$already_commented" != "true" ]]; then
		gh_issue_comment "$issue_number" --repo "$repo_slug" \
			--body "$(aidevops_ops_marker cost-circuit-breaker)"$'\n'"<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- cost-circuit-breaker:fired tier=${tier} spent=${spent} budget=${budget} -->
🛑 **Cost circuit breaker fired** (t2007)

Cumulative spend **${_spent_k}K tokens** across **${attempts}** worker attempt(s) exceeds \`tier:${tier}\` budget of **${_budget_k}K tokens**.

Further automated dispatch is suspended with \`status:blocked\` while a root-cause meta-issue is investigated.

Maintainer review required before further dispatch. Possible causes:
- Brief is unimplementable as written (refine scope or split the task)
- Hidden blocker (missing dependency, environment issue, design conflict)
- Worker stuck in a loop (model can't decompose the task — escalate tier)
- Wrong tier assigned (downgrade a tier:thinking task to standard, or vice versa)

The circuit-breaker meta flow restores \`status:available\` automatically after its fix merges. Manual recovery should requeue only after the root cause is fixed.

_This is the cost-runaway fail-safe from t2007 (paired with t1986 parent-task guard and t2008 stale-recovery escalation)._
<!-- ops:end -->" 2>/dev/null || true
	fi

	# t3076: file root-cause meta-issue with forensics and dispatch a
	# tier:thinking worker against it. Idempotent — second trip on the
	# same original is a no-op. Best-effort: failures are logged but
	# never propagate (status:blocked is canonical; the meta-issue is the
	# self-healing channel).
	local _cb_meta_filer="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/circuit-breaker-meta-filer.sh"
	if [[ -x "$_cb_meta_filer" ]]; then
		"$_cb_meta_filer" file \
			--issue "$issue_number" --repo "$repo_slug" \
			--breaker cost --tier "$tier" \
			--spent "$spent" --budget "$budget" \
			--failure-count "$attempts" >/dev/null 2>&1 || true
	fi

	return 0
}

#######################################
# Check whether the cost-per-issue circuit breaker should fire for an issue.
#
# Aggregates token spend from all signature footers on the issue's comments
# and compares against the tier-appropriate budget. If over budget, applies
# the side effects (idempotent) and emits the COST_BUDGET_EXCEEDED signal.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = (optional) tier label or short name (default: standard)
#   $4 = (optional) issue_meta_json — used for has-label idempotency check
#
# Stdout: COST_BUDGET_EXCEEDED line on block, nothing on allow.
# Returns:
#   0 = breaker fired (block dispatch)
#   1 = under budget OR aggregation failed (fail-open: allow dispatch)
#
# t2061 audit (2026-04-14):
#
# Error path classification for _check_cost_budget:
#
#   Invalid args (non-numeric issue_number, empty repo_slug):
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: guard cannot operate without valid inputs.
#       Cannot enforce a budget we can't identify the issue for.
#
#   _get_cost_budget_for_tier failure or non-numeric budget:
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot enforce a budget we can't determine.
#
#   _sum_issue_token_spend failure (gh API error, sed/grep error):
#     → || return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot enforce a budget we can't measure.
#       Transient GitHub API failures should not permanently block dispatch.
#
#   Non-numeric spent/attempts values from _sum_issue_token_spend:
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: defensive guard against malformed aggregation.
#
#   jq label_hit extraction failure (idempotency check on over-budget path):
#     → || label_hit="false" → has_label="false" → side effects re-applied
#     → _apply_cost_breaker_side_effects is idempotent (gh label ops are
#       idempotent), so re-application is harmless.
#     → FAIL-OPEN INTENTIONAL for idempotency check only; the COST_BUDGET_EXCEEDED
#       signal and return 0 (block) still fire correctly.
#
# t2007 design intent: the cost budget is a secondary safety measure for
# runaway spending. Fail-open prevents spending limits from becoming permanent
# dispatch deadlocks. The critical safety gates (parent-task GUARD_UNCERTAIN,
# gh-api-failure GUARD_UNCERTAIN) sit above this function in is_assigned() and
# do not tolerate errors. This is confirmed by the docstring:
# "1 = under budget OR aggregation failed (fail-open: allow dispatch)".
# ALREADY CONFIRMED FAIL-OPEN BY DESIGN — no hardening needed (t2061).
#######################################
_check_cost_budget() {
	local issue_number="$1"
	local repo_slug="$2"
	local tier="${3:-standard}"
	local issue_meta_json="${4:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# GH#29691: assignment inspection can run while completion reconciliation is
	# still removing a task from the dispatch projection.  A completed worker's
	# footer may exceed the budget, but terminal work cannot consume another
	# dispatch and must not be relabelled or spawn a root-cause meta-issue.  Check
	# the metadata already fetched by is_assigned() before the side-effectful cost
	# path.  The direct diagnostic command omits metadata and retains its existing
	# aggregation behaviour.
	if [[ -n "$issue_meta_json" ]] && printf '%s' "$issue_meta_json" |
		jq -e '((.state // "" | ascii_downcase) == "closed") or any(.labels[]?.name; . == "status:done" or . == "status:resolved")' \
			>/dev/null 2>&1; then
		return 1
	fi

	local budget
	budget=$(_get_cost_budget_for_tier "$tier")
	if [[ -z "$budget" ]] || ! [[ "$budget" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	local spend_data
	spend_data=$(_sum_issue_token_spend "$issue_number" "$repo_slug") || return 1

	local spent attempts
	spent="${spend_data%%|*}"
	attempts="${spend_data##*|}"

	if ! [[ "$spent" =~ ^[0-9]+$ ]] || ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ "$spent" -le "$budget" ]]; then
		# Under budget — allow dispatch
		return 1
	fi

	local _cost_trip_msg
	_cost_trip_msg="cost-circuit-breaker:fired issue=#${issue_number} repo=${repo_slug} tier=${tier#tier:} spent=${spent} budget=${budget} attempts=${attempts}"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-wrapper] %s\n' "$_cost_trip_msg" >>"$LOGFILE" 2>/dev/null || true
	fi
	local _audit_log_helper="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/audit-log-helper.sh"
	if [[ -x "$_audit_log_helper" ]]; then
		"$_audit_log_helper" log cost-circuit-breaker "$_cost_trip_msg" >/dev/null 2>&1 || true
	fi

	# Apply the structural block and marker-idempotent diagnostics.
	_apply_cost_breaker_side_effects "$issue_number" "$repo_slug" \
		"$spent" "$budget" "${tier#tier:}" "$attempts"

	# Emit signal for caller pattern matching (mirrors PARENT_TASK_BLOCKED)
	printf 'COST_BUDGET_EXCEEDED (spent=%dK budget=%dK tier=%s attempts=%d)\n' \
		"$((spent / 1000))" "$((budget / 1000))" "${tier#tier:}" "$attempts"
	return 0
}
