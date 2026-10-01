#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by pulse-dispatch-core.sh after its shared constants and dependencies.
[[ -n "${_PULSE_DISPATCH_COMMIT_GATES_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_COMMIT_GATES_LOADED=1

#######################################
# t1894 + GH#18648: Cryptographic approval gate (ever-NMR) with
# review-followup exemption for bot-generated cleanup issues.
#
# Extracted from _dispatch_dedup_check_layers() to keep the parent
# function under the 100-line complexity threshold while the exemption
# logic grew.
#
# Logic:
#   1. Determine if the issue currently has `needs-maintainer-review`
#      — set known_ever_nmr="true" for the cache-path short-circuit.
#   2. If the issue is bot-generated cleanup (review-followup or
#      source:review-scanner) AND the label is not currently present,
#      override known_ever_nmr=false to skip the historical timeline
#      check. This clears the ever-NMR permanence trap for routine
#      cleanup issues whose NMR label was applied by the fast-fail
#      escalation path and has since been removed.
#   3. If NMR is not currently present, skip historical ever-NMR for
#      trusted maintainer threads: issue author is OWNER/MEMBER and every
#      issue comment is OWNER/MEMBER or a known framework-generated GitHub
#      Actions hold/remediation notice. COLLABORATOR authors/comments are
#      trusted only after an authenticated collaborator-permission lookup
#      confirms write/admin/maintain. This preserves prompt-injection
#      protection while avoiding permanent crypto approval for internal
#      retry/hold labels that a maintainer has already removed.
#   4. Call issue_has_required_approval with the determined state.
#
# The exemption does NOT fire when the label is currently present —
# maintainer-applied or bot-applied NMR still blocks dispatch until
# the label is removed or cryptographic approval is posted.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate blocks dispatch (ever-NMR without approval)
#   1 - gate allows dispatch
#######################################
_issue_thread_is_trusted_maintainer_only() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1

	local issue_api_path="repos/${repo_slug}/issues/"
	issue_api_path="${issue_api_path}${issue_number}"
	local issue_comments_path="${issue_api_path}/comments"
	local issue_json
	local issue_author_association
	local issue_author_login
	issue_json=$(gh api "$issue_api_path" 2>/dev/null) || return 1
	IFS=$'\t' read -r issue_author_association issue_author_login < <(printf '%s' "$issue_json" |
		jq -r '[.author_association // "NONE", (.user.login // .author.login // "")] | @tsv') || {
		issue_author_association=""
		issue_author_login=""
	}
	case "$issue_author_association" in
	OWNER | MEMBER) ;;
	COLLABORATOR)
		_issue_actor_has_repo_write_permission "$repo_slug" "$issue_author_login" || return 1
		;;
	*)
		return 1
		;;
	esac

	local comments_json
	comments_json=$(gh api "$issue_comments_path" \
		--paginate --slurp 2>/dev/null) || return 1
	[[ -n "$comments_json" && "$comments_json" != "null" ]] || comments_json="[]"

	local untrusted_comment_count
	untrusted_comment_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "$_PULSE_DISPATCH_JSON_ARRAY_TYPE" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" --arg unknown_association NONE '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select(
			((.author_association // $unknown_association) as $a | ($a != "OWNER" and $a != "MEMBER" and $a != $collaborator_association))
			and (((.user.login // .author.login // "") as $login
				| ((($login == "github-actions[bot]") or ($login == "github-actions"))
					and ((.body // "") | test("^<!-- (nmr-hold-guidance|ever-nmr-remediation) -->")))) | not)
		) ]
		| length
	') || return 1
	[[ "$untrusted_comment_count" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || return 1
	[[ "$untrusted_comment_count" -eq 0 ]] || return 1

	local missing_collaborator_login_count
	missing_collaborator_login_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "$_PULSE_DISPATCH_JSON_ARRAY_TYPE" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" --arg unknown_association NONE '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select(
			(.author_association // $unknown_association) == $collaborator_association
			and ((.user.login // .author.login // "") == "")
		) ]
		| length
	') || return 1
	[[ "$missing_collaborator_login_count" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || return 1
	[[ "$missing_collaborator_login_count" -eq 0 ]] || return 1

	local collaborator_comment_logins
	collaborator_comment_logins=$(printf '%s' "$comments_json" | jq -r --arg array_type "$_PULSE_DISPATCH_JSON_ARRAY_TYPE" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" --arg unknown_association NONE '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select((.author_association // $unknown_association) == $collaborator_association) | (.user.login // .author.login // "") ]
		| unique | .[]
	') || return 1
	local comment_login
	while IFS= read -r comment_login; do
		[[ -n "$comment_login" ]] || continue
		_issue_actor_has_repo_write_permission "$repo_slug" "$comment_login" || return 1
	done <<<"$collaborator_comment_logins"

	return 0
}

_issue_actor_has_repo_write_permission() {
	local repo_slug="$1"
	local login="$2"

	[[ -n "$repo_slug" && -n "$login" ]] || return 1
	# #aidevops:trust-boundary — never trust bare COLLABORATOR association for
	# ever-NMR bypass. GitHub can use COLLABORATOR for ambiguous private-org
	# events; require an authenticated per-repo permission lookup.
	_gh_actor_has_repo_write_authority "$repo_slug" "$login" "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION"
	return $?
}

_check_nmr_approval_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"

	local known_ever_nmr="unknown"
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | index("needs-maintainer-review")' >/dev/null 2>&1; then
		known_ever_nmr=true
	fi

	# GH#18648: bot-generated cleanup exemption. See
	# _is_bot_generated_cleanup_issue() doc for full rationale.
	if [[ "$known_ever_nmr" != true ]] && _is_bot_generated_cleanup_issue "$issue_meta_json"; then
		known_ever_nmr="$_PULSE_DISPATCH_FALSE"
		echo "[pulse-wrapper] dispatch_with_dedup: review-followup exemption for #${issue_number} in ${repo_slug} — skipping historical ever-NMR check (GH#18648)" >>"$LOGFILE"
	fi

	# <!-- aidevops:trust-boundary -->
	# Historical NMR is a prompt-injection trust boundary only when untrusted
	# content may have entered the worker prompt. If the active NMR label has
	# been removed and both issue author plus every comment author are OWNER or
	# MEMBER, allow dispatch without requiring a cryptographic approval marker.
	if [[ "$known_ever_nmr" != true ]] && _issue_thread_is_trusted_maintainer_only "$issue_number" "$repo_slug"; then
		known_ever_nmr=false
		echo "[pulse-wrapper] dispatch_with_dedup: trusted maintainer thread exemption for #${issue_number} in ${repo_slug} — skipping historical ever-NMR check" >>"$LOGFILE"
	fi

	if ! issue_has_required_approval "$issue_number" "$repo_slug" "$known_ever_nmr"; then
		echo "[pulse-wrapper] dispatch_with_dedup: BLOCKED #${issue_number} in ${repo_slug} — requires cryptographic approval (ever-NMR)" >>"$LOGFILE"
		echo "[pulse-wrapper] DISPATCH_BLOCK_REASON reason=ever_nmr_without_approval issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		# GH#20682: when the NMR label is absent (human removed it) but the
		# ever-NMR block still fires, post a one-shot remediation comment so
		# the maintainer knows why dispatch is still skipped and what to do.
		if [[ "$known_ever_nmr" != 'true' ]]; then
			notify_ever_nmr_without_approval "$issue_number" "$repo_slug"
		fi
		return 0
	fi
	return 1
}

#######################################
# GH#22399: Fail-closed external issue author gate.
#
# GitHub Actions issue-triage-gate.yml applies needs-maintainer-review to
# non-collaborator issues, but Actions can sit queued while the pulse keeps
# dispatching. This gate repeats the trust-boundary check in the dispatch path
# immediately before worker launch. OWNER/MEMBER, write-authorized collaborators,
# and bot-created issues keep the fast path. External, read/triage collaborator,
# or unknown authors must carry a valid cryptographic approval; otherwise the
# pulse applies NMR and blocks this candidate in the current cycle.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0 - gate blocks dispatch (external/unknown author without approval)
#   1 - gate allows dispatch
#######################################
_check_external_issue_author_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local nmr_label="${_PULSE_DISPATCH_NMR_LABEL:-needs-maintainer-review}"

	local issue_author_meta=""
	issue_author_meta=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq 'if (type == "object" and (.labels | arrays) and all(.labels[]; if type == "object" then ((.name | type) == "string" and (.name | length) > 0) else false end)) then [.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[].name] | index("external-contributor") != null) | tostring)] | join("|") else empty end' 2>/dev/null) || issue_author_meta=""

	local author_association=NONE
	local author_type=""
	local author_login=""
	local external_source="unknown"
	local metadata_valid=0
	if [[ -n "$issue_author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login external_source <<<"$issue_author_meta"
		if [[ -n "$author_login" && "$external_source" =~ ^(true|false)$ ]]; then
			metadata_valid=1
		fi
	fi
	[[ -n "$author_association" ]] || author_association=NONE

	# aidevops:trust-boundary — unavailable metadata is not evidence of an
	# external author. Defer this candidate without creating a persistent hold.
	# This predicate returns 0 to block; its caller returns 1 to skip dispatch.
	if [[ "$metadata_valid" -eq 0 ]]; then
		echo "[dispatch_with_dedup] GH#31404: metadata fetch failed for #${issue_number} in ${repo_slug}; skipping dispatch without changing labels (transient)" >>"$LOGFILE"
		return 0
	fi

	if [[ "$metadata_valid" -eq 1 && "$author_type" == "Bot" && "$external_source" != true ]]; then
		return 1
	fi
	local authority_rc=2
	if [[ "$metadata_valid" -eq 1 && "$external_source" != true ]]; then
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo_slug" "$author_login" "$author_association" || authority_rc=$?
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 1
	fi

	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	local verify_result=""
	if [[ -f "$approval_helper" ]]; then
		verify_result=$(bash "$approval_helper" verify "$issue_number" "$repo_slug" 2>/dev/null || true)
		if [[ "$verify_result" == "VERIFIED" ]]; then
			echo "[dispatch_with_dedup] GH#22399: external/unknown issue author for #${issue_number} in ${repo_slug} has cryptographic approval; allowing dispatch" >>"$LOGFILE"
			return 1
		fi
		# <!-- aidevops:trust-boundary -->
		# Distinguish an absent approval from an unverifiable approval marker. A
		# worker missing the approval public key must fail closed for dispatch, but
		# must not mutate lifecycle labels over a maintainer's signed handoff.
		if [[ -n "$verify_result" && "$verify_result" != "NO_APPROVAL" ]]; then
			echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: cryptographic approval marker present but verification returned ${verify_result}; not re-applying ${nmr_label} (GH#22733)" >>"$LOGFILE"
			return 0
		fi
	fi

	echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: author_association=${author_association}, author_type=${author_type:-unknown}, external_source=${external_source}, authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}; applying ${nmr_label} until cryptographic approval lands (GH#22399)" >>"$LOGFILE"
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" \
			--add-label "$nmr_label" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "$nmr_label" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# GH#17574 + GH#18644: Combined commit-subject dedup gate with
# force-dispatch maintainer override.
#
# Wraps the _is_task_committed_to_main call with an early bypass when
# the issue carries the `force-dispatch` label. Extracted from
# _dispatch_dedup_check_layers() to keep the parent function under the
# 100-line complexity threshold while the logic-body grows.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - target_title (issue title from meta_json)
#   $4 - repo_path (local path to the repo)
#   $5 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate fires (block dispatch — task appears committed to main,
#       force-dispatch is NOT set)
#   1 - gate allows dispatch (task not committed, OR force-dispatch
#       override is set)
#######################################
_check_commit_subject_dedup_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_title="$3"
	local repo_path="$4"
	local issue_meta_json="$5"

	# GH#18644: force-dispatch label bypasses the commit-subject dedup
	# entirely. The override is for legacy task-ID collisions where a
	# commit subject accidentally mentions a task ID that was never
	# claimed via claim-task-id.sh. Maintainer-only — workers must not
	# apply this label. Does NOT bypass ever-NMR, claim/lock layers,
	# large-file gates, or blocked-by dependencies.
	if _has_force_dispatch_label "$issue_meta_json"; then
		echo "[pulse-wrapper] dispatch_with_dedup: force-dispatch label active on #${issue_number} in ${repo_slug} — bypassing _is_task_committed_to_main (GH#18644)" >>"$LOGFILE"
		return 1
	fi

	# t2955: cache fast-path. If a previous cycle already verified this
	# issue is committed to main, the `dispatch-blocked:committed-to-main`
	# label was applied. Skip the expensive `gh issue view` + `git fetch` +
	# 3 `git log --grep` ops and block immediately. Production data showed
	# this check was the dominant cost in `preflight_early_dispatch` —
	# 224 affected issues × 5 ops/cycle was timing out the 600s stage on
	# 100% of recent cycles, capping concurrency at 1-2 dispatches/cycle.
	#
	# Force-dispatch override (above) takes precedence — a maintainer
	# applying force-dispatch unblocks the cache too.
	#
	# Revert handling: if a commit is reverted, the cache label sticks
	# (false-positive block). Manual remediation: remove the label via
	# `gh issue edit N --remove-label dispatch-blocked:committed-to-main`.
	# A periodic scrubber to automate this is tracked separately —
	# kept out of this PR per one-fix-per-PR (Review Bot Gate t1382).
	if _has_committed_to_main_cache_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574) (cached, t2955)" >>"$LOGFILE"
		return 0
	fi

	# GH#17574: Skip dispatch if the task has already been committed
	# directly to main. Workers that bypass the PR flow (direct commits)
	# complete the work invisibly — the issue stays open until the
	# pulse's mark-complete pass runs, which happens AFTER dispatch
	# decisions for the next cycle. Without this check, the pulse
	# dispatches redundant workers for already-completed work.
	#
	# GH#17642: Do NOT auto-close the issue on a block. The main-commit
	# check has a high false-positive rate (casual mentions, multi-
	# runner deployment gaps, stale patterns). A false skip is harmless
	# (next cycle retries), a false close is destructive (needs manual
	# reopen, re-dispatch, and loses worker context). Let the verified
	# merge-pass or human close it.
	if _is_task_committed_to_main "$issue_number" "$repo_slug" "$target_title" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574) (scanned, t2955)" >>"$LOGFILE"
		# t2955: apply cache label so subsequent cycles skip the scan.
		# Best-effort — do not fail dispatch decision if label apply errors.
		_apply_committed_to_main_cache_label "$issue_number" "$repo_slug" || true
		return 0
	fi

	return 1
}

#######################################
# GH#18644: Detect the `force-dispatch` maintainer override label.
#
# Purpose: escape hatch for false-positive task-ID collisions in the
# commit-subject dedup (_is_task_committed_to_main). When a commit
# subject accidentally mentions a task ID that was never claimed via
# claim-task-id.sh — e.g., `chore(build.txt): add rule (t2046)` for a
# task that is actually GH#18508, not the canonical t2046 — the dedup
# block fires permanently even though no implementation has happened.
#
# The `force-dispatch` label is a maintainer-only override that
# bypasses this specific check. It does NOT bypass:
#   - The cryptographic approval gate (ever-NMR) above it
#   - Any Layer 1-7 claim/lock/assignee/open-PR machinery below it
#   - Large-file gates, blocked-by dependencies, or supervisor title guards
#
# Workers MUST NOT apply this label themselves. It represents a
# human decision that the dedup signal is wrong for this specific issue.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - force-dispatch label is present
#   1 - force-dispatch label is absent (or meta_json is empty/invalid)
#######################################
_has_force_dispatch_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("force-dispatch")' >/dev/null 2>&1
}

#######################################
# Detect the publication hold label before any claim or worker launch.
#
# `publication:pending` represents an issue that was intentionally created
# before its TODO.md entry and worker brief/stub reached the default branch.
# This dedicated pre-launch check remains effective if candidate filtering or
# the dispatch-dedup helper is bypassed. Malformed metadata fails closed.
#
# Args:
#   $1 - issue metadata JSON with a .labels array
# Exit codes:
#   0 - publication is pending or metadata cannot be safely read
#   1 - publication is not pending
#######################################
_has_publication_pending_label() {
	local issue_meta_json="$1"
	local label_state=""
	[[ -n "$issue_meta_json" ]] || return 0
	label_state=$(printf '%s' "$issue_meta_json" |
		jq -r 'if ((.labels // []) | map(.name) | index("publication:pending")) != null then "pending" else "published" end' 2>/dev/null) || return 0
	[[ "$label_state" == "pending" ]]
}

#######################################
# t2955: Detect the `dispatch-blocked:committed-to-main` cache label.
#
# Purpose: cache fast-path for `_check_commit_subject_dedup_gate`. When
# the expensive `_is_task_committed_to_main` check first detects a block,
# the gate applies this label so subsequent dispatch cycles skip the
# `gh issue view` + `git fetch` + 3 `git log --grep` ops on the same
# issue. Eliminates the spam pattern where 224+ affected issues ran the
# expensive scan every cycle and timed out `preflight_early_dispatch` at
# its 600s budget (100% of last 10 cycles before this fix).
#
# The cache label is set by `_apply_committed_to_main_cache_label` (next
# helper) and never removed automatically by this gate. Periodic
# revalidation for revert handling is a follow-up; for now, manual
# remediation is via `gh issue edit N --remove-label
# dispatch-blocked:committed-to-main`.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - cache label is present (skip the expensive scan)
#   1 - cache label is absent (run the full scan)
#######################################
_has_committed_to_main_cache_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("dispatch-blocked:committed-to-main")' >/dev/null 2>&1
}

#######################################
# Detect terminal consolidated issues before worker dispatch.
#
# Consolidated source issues are archival records and must not be dispatched
# again. Consolidated successor specs are dispatchable only when they carry
# both the explicit auto-dispatch handoff and the canonical body marker.
# Review/CI feedback specs remain dispatchable through their source labels.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - consolidated label is present
#   1 - consolidated label is absent (or meta_json is empty/invalid)
#######################################
_has_consolidated_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	if printf '%s' "$issue_meta_json" | jq -e --arg auto_dispatch_label "$_PULSE_DISPATCH_AUTO_LABEL" '
		(.labels | map(.name)) as $labels
		| (
			(($labels | index($auto_dispatch_label)) != null)
			and ((.body // "") | test("(^|\\n)_Supersedes #[0-9]+ (—|-) this issue is the consolidated spec\\._(\\n|$)"))
		) as $dispatchable_spec
		| (($labels | index("consolidated")) != null)
		and (($labels | index("quality-debt")) == null)
		and (($labels | index("source:review-feedback")) == null)
		and (($labels | index("source:ci-feedback")) == null)
		and ($dispatchable_spec | not)
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Determine whether a GitHub issue-number target is actually a pull request.
#
# `gh issue view` intentionally presents PRs through the issue facade, so the
# dispatch preflight must use the REST issue object and inspect the
# `pull_request` marker before any label/assignee writes. This is a hard
# trust-boundary guard: dispatching a worker against a PR number would mutate an
# interactive review object and can open a competing implementation PR.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
# Returns:
#   0 - target is a PR
#   1 - target is a plain Issue
#   2 - unable to verify safely
#######################################
_dispatch_target_is_pull_request() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_json="" has_pull_request=""

	target_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 2
	has_pull_request=$(printf '%s' "$target_json" | jq -r 'has("pull_request")' 2>/dev/null) || return 2
	if [[ "$has_pull_request" == true ]]; then
		return 0
	fi
	if [[ "$has_pull_request" == "$_PULSE_DISPATCH_FALSE" ]]; then
		return 1
	fi
	return 2
}

#######################################
# t2955: Apply the `dispatch-blocked:committed-to-main` cache label.
#
# Called by `_check_commit_subject_dedup_gate` after the first scan
# detects a committed-to-main block. Best-effort: failures (rate limit,
# label-not-yet-created on the repo, transient API error) do NOT fail
# the dispatch decision. The current cycle's block stands regardless;
# the cache miss simply repeats next cycle.
#
# The `--add-label` call auto-creates the label on the repo if it
# doesn't exist (GitHub default behaviour for `gh issue edit`).
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   Always 0 — best-effort, never blocks the caller.
#######################################
_apply_committed_to_main_cache_label() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "dispatch-blocked:committed-to-main" >/dev/null 2>&1 || true
	return 0
}

#######################################
# GH#18648 (Fix 3a): Detect bot-generated cleanup issues.
#
# Bot-generated cleanup issues carry `review-followup` (from
# post-merge-review-scanner.sh), `source:review-scanner`, or
# `source:review-feedback` (from quality-feedback-helper.sh scan-merged).
# These labels indicate: "this issue was auto-created from already-merged
# PR review comments, no new maintainer decision is required".
#
# Callers use this to exempt the issue from the ever-NMR permanence
# trap — historical NMR labels applied by automated escalation paths
# (dispatch-dedup fast-fail circuit breaker) no longer drain the
# dispatch queue once the label is manually removed.
#
# The exemption does NOT fire when the issue CURRENTLY has the
# needs-maintainer-review label — a present label still requires
# cryptographic approval, regardless of issue provenance. The fix
# is surgical to the historical-timeline false-positive case.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - issue is bot-generated cleanup
#   1 - issue is not bot-generated (or meta_json is empty/invalid)
#######################################
_is_bot_generated_cleanup_issue() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | (index("review-followup") != null or index("source:review-scanner") != null or index("source:review-feedback") != null)' >/dev/null 2>&1
}

_dispatch_waiting_for_maintainer_permission() {
	local issue_meta_json="$1"
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("needs-maintainer-permissions") != null' >/dev/null 2>&1
	return $?
}

_dispatch_permission_history_requires_grant() {
	local issue_number="$1"
	local repo_slug="$2"
	local events_json="" labeled_count="" verification=""
	local attempts="${AIDEVOPS_PERMISSION_HISTORY_ATTEMPTS:-2}"
	local retry_delay="${AIDEVOPS_PERMISSION_HISTORY_RETRY_DELAY:-1}"
	local attempt=1
	_DISPATCH_PERMISSION_VERIFY_RESULT=""
	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=2
	[[ "$attempts" -le 3 ]] || attempts=3
	[[ "$retry_delay" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || retry_delay=1
	[[ "$retry_delay" -le 5 ]] || retry_delay=1
	while [[ "$attempt" -le "$attempts" ]]; do
		if events_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/events?per_page=100" --paginate --slurp 2>/dev/null); then
			break
		fi
		events_json=""
		if [[ "$attempt" -lt "$attempts" ]]; then
			sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done
	if [[ -z "$events_json" ]]; then
		_DISPATCH_PERMISSION_VERIFY_RESULT="API_ERROR"
		return 0
	fi
	labeled_count=$(jq '[.[][]? | select(.event == "labeled" and .label.name == "needs-maintainer-permissions")] | length' <<<"$events_json" 2>/dev/null) || {
		_DISPATCH_PERMISSION_VERIFY_RESULT="API_ERROR"
		return 0
	}
	[[ "$labeled_count" -gt 0 ]] || return 1
	local approval_helper="${BASH_SOURCE[0]%/*}/approval-helper.sh"
	[[ -x "$approval_helper" ]] || {
		_DISPATCH_PERMISSION_VERIFY_RESULT="HELPER_MISSING"
		return 0
	}
	verification=$($approval_helper verify-permissions issue "$issue_number" "$repo_slug" 2>/dev/null) || true
	_DISPATCH_PERMISSION_VERIFY_RESULT="${verification:-NO_APPROVAL}"
	[[ "$verification" == "NO_REQUEST" ]] && return 1
	[[ "$verification" == "VERIFIED" ]] && return 1
	# GH#33330: verify-permissions evaluates only the latest request, so a
	# signed withdrawal releases that request alone; a newer request blocks.
	[[ "$verification" == "WITHDRAWN" ]] && return 1
	return 0
}

#######################################
# GH#17574: Check if a task has already landed on main (via PR merge or direct commit).
#
# Workers that bypass the PR flow (direct commits to main) complete the
# work invisibly — the issue stays open until the pulse's mark-complete
# pass runs, which happens AFTER dispatch decisions for the next cycle.
# This caused 3× token waste in the observed incident (t153–t160).
#
# Delegates to three per-signal helpers (t2004):
#   _task_id_in_recent_commits — task ID in commit subject line
#   _task_id_in_merged_pr      — closing keywords / squash-merge suffix
#   _task_id_in_changed_files  — [x] completion marker in TODO.md
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_title (e.g., "t153: add dark mode toggle")
#   $4 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task IS committed to main (do NOT dispatch)
#   1 - task is NOT committed to main (safe to dispatch)
#######################################
_is_task_committed_to_main() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local repo_path="$4"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$repo_path" ]] || return 1

	# Get the issue creation date for --since filtering.
	# t3027: route through gh_issue_view wrapper for REST fallback under
	# GraphQL exhaustion. The `// .created_at` jq fallback handles both
	# camelCase (gh native) and snake_case (REST) field names — the REST
	# endpoint /repos/.../issues/N returns `created_at`, gh returns `createdAt`.
	local created_at
	created_at=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json createdAt --jq '.createdAt // .created_at' 2>/dev/null) || created_at=""
	if [[ -z "$created_at" ]]; then
		return 1
	fi

	# Ensure we have the latest remote refs (the dispatch loop already
	# does git pull, but fetch is cheaper and sufficient for log queries)
	if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
	else
		return 1
	fi

	_task_id_in_recent_commits "$issue_title" "$repo_path" "$created_at" && return 0
	_task_id_in_merged_pr "$issue_number" "$repo_path" "$created_at" && return 0
	_task_id_in_changed_files "$issue_number" "$issue_title" "$repo_path" && return 0
	return 1
}

#######################################
# Detect labels that mean a human/review workflow owns the target.
#
# status:in-review is a live interactive hold signal while the issue is not
# explicitly worker-dispatchable. origin:interactive is provenance only unless a
# same-session owner/assignee is still attached; unassigned status:available
# issues must remain dispatchable so TODO/brief sync does not strand worker-ready
# backlog items that lack auto-dispatch labels.
#
# Args:
#   $1 - issue metadata JSON with optional .labels[].name
# Returns: 0 when an interactive hold label is present, 1 otherwise
#######################################
