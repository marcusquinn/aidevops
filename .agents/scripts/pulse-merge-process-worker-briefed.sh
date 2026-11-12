#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-process-worker-briefed.sh — Worker-Briefed Auto-Merge Trust Chain
# =============================================================================
# Extracted from pulse-merge-process.sh (GH#27171) to keep the merge-process
# orchestrator below the 2000-line file-size-debt threshold.
#
# Decides whether an origin:worker PR may auto-merge based on the trust chain
# of its linked issue (t2449): OWNER/MEMBER authorship, authenticated
# maintainer permission (GH#24958), trusted-issue-author allowlist (t3062),
# scoped OpenCode pin-canary briefs (GH#35752), or a verified cryptographic
# maintainer approval (t3052).
#
# Functions:
#   - _is_trusted_issue_author                — allowlist lookup (t3062)
#   - _pm_canary_shared_constants_patch_ok    — canary pin-metadata diff check
#   - _is_trusted_opencode_canary_issue_pr    — canary brief + scope check
#   - _issue_author_has_maintainer_authority  — collaborator permission check
#   - _issue_has_verified_crypto_approval     — approval-helper.sh verify
#   - _worker_briefed_pr_is_planning_checkpoint — planning-only diff (GH#36922)
#   - _worker_briefed_link_kind               — closing vs For/Ref link (GH#33999)
#   - _attempt_worker_briefed_auto_merge      — gate entry point (t2449)
#
# Usage: source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-process-worker-briefed.sh"
#        (sourced by pulse-merge-process.sh; do not execute directly)
#
# Dependencies (resolved at call time):
#   - LOGFILE, _PULSE_MERGE_DIR (set by pulse-merge.sh / pulse-merge-process.sh)
#   - _pm_issue_api, _extract_linked_issue (defined in pulse-merge.sh)
#   - gh, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_PROCESS_WORKER_BRIEFED_LOADED:-}" ]] && return 0
_PULSE_MERGE_PROCESS_WORKER_BRIEFED_LOADED=1

# Defensive default for standalone sourcing (test harnesses)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# --- Functions ---

#######################################
# Check if a GitHub login appears in the trusted-issue-author allowlist (t3062).
#
# Peer runners with COLLABORATOR association can be added to the allowlist to
# bypass the OWNER/MEMBER author_association gate without requiring per-issue
# cryptographic approval (sudo aidevops approve issue N).
#
# Config: AIDEVOPS_TRUSTED_AUTHORS_CONF env var (override) or
#         <_PULSE_MERGE_DIR>/../configs/trusted-issue-authors.conf (default).
# Empty/missing config = no trusted authors = returns 1 (not trusted).
#
# Args: $1=github_login
# Returns: 0=login is trusted, 1=not trusted
#######################################
_is_trusted_issue_author() {
	local login="$1"
	[[ -z "$login" ]] && return 1
	local _trusted_conf="${AIDEVOPS_TRUSTED_AUTHORS_CONF:-${_PULSE_MERGE_DIR:+${_PULSE_MERGE_DIR}/../configs/trusted-issue-authors.conf}}"
	[[ -z "$_trusted_conf" || ! -f "$_trusted_conf" ]] && return 1
	local _tentry
	while IFS= read -r _tentry || [[ -n "$_tentry" ]]; do
		[[ -z "$_tentry" || "$_tentry" == "#"* ]] && continue
		[[ "$_tentry" == "$login" ]] && return 0
	done < "$_trusted_conf"
	return 1
}

# Files a worker may change when briefed by the scheduled OpenCode pin canary.
# Keep aligned with the Files Scope + verification tests emitted by
# .github/workflows/opencode-pin-canary.yml (GH#35752/GH#35753).
_PM_OPENCODE_CANARY_ALLOWED_FILES=".agents/scripts/opencode-pin-canary.sh
.agents/configs/opencode-runtime-profiles.json
.agents/scripts/shared-constants.sh
.agents/plugins/opencode-aidevops/package.json
.agents/plugins/opencode-aidevops/package-lock.json
.agents/scripts/tests/test-opencode-pin-policy.sh
.agents/scripts/tests/test-opencode-runtime-profile.sh"
_PM_WORKFLOW_BOT_LOGIN="github-actions[bot]"
_PM_OPENCODE_CANARY_MAX_FILES=20

#######################################
# Validate changed shared-constants.sh lines for a canary-briefed PR: only
# comments, `readonly OPENCODE_*="literal"` assignments and profile-table
# `vN:key) printf 'literal\n' ;;` rows may be added or removed. Anything else
# (new functions, sourcing, expansions) fails closed.
# Args: $1=unified diff patch text
# Returns: 0=all changed lines are pin metadata, 1=otherwise
#######################################
_pm_canary_shared_constants_patch_ok() {
	local patch="$1"
	local line="" body=""
	local re_comment='^[[:space:]]*#'
	local re_readonly='^readonly OPENCODE_[A-Z0-9_]+="[^"$`\\]*"$'
	local re_profile_row="^[[:space:]]*v[0-9]+:[A-Za-z]+\\) printf '[^'\$\`\\\\]*\\\\n' ;;\$"
	[[ -n "$patch" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		+++* | ---* | @@* | " "* | "") continue ;;
		"\\ No newline at end of file") continue ;;
		[+-]*) body="${line:1}" ;;
		*) return 1 ;;
		esac
		[[ -z "${body//[[:space:]]/}" ]] && continue
		[[ "$body" =~ $re_comment ]] && continue
		[[ "$body" =~ $re_readonly ]] && continue
		[[ "$body" =~ $re_profile_row ]] && continue
		return 1
	done <<<"$patch"
	return 0
}

#######################################
# Check whether a linked issue is a scheduled OpenCode pin-canary brief and the
# PR stays inside that brief's file scope (GH#35752/GH#35753).
#
#aidevops:trust-boundary — github-actions[bot] issues can only be created by
# this repository's own workflows (fork tokens are read-only). Trust is bound to
# the exact canary titles + origin:worker label, and the PR diff must stay
# within the canary allowlist; shared-constants.sh changes are limited to pin
# metadata lines. API errors, truncated file lists or missing patches fail closed.
# All other merge gates (checks, reviews, review-bot, NMR) still apply.
#
# Args: $1=pr_number, $2=repo_slug, $3=issue API path
# Returns: 0=trusted canary brief with in-scope diff, 1=not trusted
#######################################
_is_trusted_opencode_canary_issue_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local issue_api="$3"
	local issue_meta="" login="" user_type="" title="" labels=""
	local re_title='^(Promote passing OpenCode v[0-9]+ compatibility candidate|OpenCode v[0-9]+ compatibility pin review is due)$'

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" && -n "$issue_api" ]] || return 1
	issue_meta=$(gh api "$issue_api" \
		--jq 'select(.pull_request == null) | [(.user.login // ""), (.user.type // ""), ([.labels[].name] | join(",")), (.title // "")] | @tsv' \
		2>/dev/null) || return 1
	IFS=$'\t' read -r login user_type labels title <<<"$issue_meta"
	[[ "$login" == "$_PM_WORKFLOW_BOT_LOGIN" && "$user_type" == "Bot" ]] || return 1
	[[ "$title" =~ $re_title ]] || return 1
	[[ ",${labels}," == *",origin:worker,"* ]] || return 1

	local files_json="" file_count="" path="" patch=""
	files_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/files?per_page=100" 2>/dev/null) || return 1
	# `arrays` emits nothing for non-array payloads, so the integer check fails closed.
	file_count=$(printf '%s' "$files_json" | jq -r 'arrays | length' 2>/dev/null) || return 1
	[[ "$file_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$file_count" -gt 0 && "$file_count" -le "$_PM_OPENCODE_CANARY_MAX_FILES" ]] || return 1

	while IFS= read -r path; do
		[[ -n "$path" ]] || return 1
		if ! grep -Fxq -- "$path" <<<"$_PM_OPENCODE_CANARY_ALLOWED_FILES"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — canary-briefed PR changes out-of-scope file ${path} (GH#35752)" >>"$LOGFILE"
			return 1
		fi
	done < <(printf '%s' "$files_json" | jq -r '.[] | (if .status == "renamed" then "<renamed>" else .filename end)')

	if printf '%s' "$files_json" | jq -e '.[] | select(.filename == ".agents/scripts/shared-constants.sh")' >/dev/null 2>&1; then
		patch=$(printf '%s' "$files_json" | jq -r '.[] | select(.filename == ".agents/scripts/shared-constants.sh") | .patch // ""') || return 1
		if ! _pm_canary_shared_constants_patch_ok "$patch"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — canary-briefed PR changes non-pin lines in shared-constants.sh (GH#35752)" >>"$LOGFILE"
			return 1
		fi
	fi
	return 0
}

#######################################
# Check whether a linked issue is a plugin starter-sync issue and the PR stays
# inside the base core-files list or the trusted issue's Files Scope.
#
#aidevops:trust-boundary — the starter-sync workflow files one issue as
# github-actions[bot] titled exactly "Core files differ from the starter" with
# label starter-sync. Trust is bound to that issue shape AND the PR diff: every
# changed file must match a file or directory prefix in scripts/core-files.txt
# read at the PR BASE sha, an exact path in the trusted issue's Files Scope,
# or changelog.txt; renames are rejected. The issue body must be readable.
# API errors, truncated file lists (>= 100) or missing data fail closed. All
# other merge gates (checks, reviews, review-bot, NMR) still apply. The gate
# order is pinned by test_starter_sync_does_not_bypass_other_gates in
# tests/test-pulse-merge-worker-briefed.sh (GH#37373); keep it passing when
# moving this check.
# Blob-equality hardening against the starter was not implemented: files with
# plugin-own marker blocks legitimately differ and the starter commit is not
# machine-readable from the issue, so these scope lists are the bound.
#
# Args: $1=pr_number, $2=repo_slug, $3=issue API path
# Returns: 0=trusted starter-sync brief with in-scope diff, 1=not trusted
#######################################
_is_trusted_starter_sync_issue_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local issue_api="$3"
	local issue_meta="" login="" user_type="" title="" labels="" issue_scope=""
	local required_title="Core files differ from the starter"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" && -n "$issue_api" ]] || return 1
	issue_meta=$(gh api "$issue_api" 2>/dev/null) || return 1
	login=$(jq -r 'select(.pull_request == null and ([.body | strings] | length == 1)) | .user.login // ""' <<<"$issue_meta") || return 1
	user_type=$(jq -r '.user.type // ""' <<<"$issue_meta") || return 1
	labels=$(jq -r '[.labels[].name] | join(",")' <<<"$issue_meta") || return 1
	title=$(jq -r '.title // ""' <<<"$issue_meta") || return 1
	[[ "$login" == "$_PM_WORKFLOW_BOT_LOGIN" && "$user_type" == "Bot" ]] || return 1
	[[ "$title" == "$required_title" ]] || return 1
	[[ ",${labels}," == *",starter-sync,"* ]] || return 1
	issue_scope=$(jq -r '.body | split("\n") | (index("### Files Scope") // length) as $start |
		.[$start + 1:] | (map(test("^#{1,6} ")) | index(true) // length) as $end |
		.[:$end][] | select(test("^- `[^`]+`$")) | .[3:-1]' <<<"$issue_meta") || return 1

	local base_sha="" scope_list="" files_json=""
	local file_count='' path='' entry='' in_scope=0
	local pr_api="repos/${repo_slug}/pulls"
	pr_api+="/${pr_number}"
	base_sha=$(gh api "$pr_api" --jq '.base.sha // ""' 2>/dev/null) || return 1
	[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	scope_list=$(gh api -H "Accept: application/vnd.github.raw" \
		"repos/${repo_slug}/contents/scripts/core-files.txt?ref=${base_sha}" 2>/dev/null) || {
		echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — starter-sync scope fetch failed (GH#37289)" >>"$LOGFILE"
		return 1
	}
	if [[ -z "$scope_list" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — starter-sync scope list is empty (GH#37289)" >>"$LOGFILE"
		return 1
	fi

	files_json=$(gh api "${pr_api}/files?per_page=100" 2>/dev/null) || return 1
	file_count=$(printf '%s' "$files_json" | jq -r 'arrays | length' 2>/dev/null) || return 1
	[[ "$file_count" =~ ^[0-9]+$ ]] || return 1
	if [[ "$file_count" -eq 0 || "$file_count" -ge 100 ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — starter-sync file count ${file_count} is empty or potentially truncated (GH#37289)" >>"$LOGFILE"
		return 1
	fi
	jq -e 'all(.[]; .status != "renamed" and ([.filename | strings] | length == 1))' <<<"$files_json" >/dev/null 2>&1 || return 1

	while IFS= read -r path; do
		[[ -n "$path" ]] || return 1
		[[ "$path" == "changelog.txt" ]] && continue
		in_scope=0
		while IFS= read -r entry; do
			[[ -z "$entry" || "$entry" == \#* ]] && continue
			if [[ "$path" == "$entry" || ( "$entry" == */ && "$path" == "$entry"* ) ]]; then
				in_scope=1
				break
			fi
		done <<<"$scope_list"
		if [[ "$in_scope" -eq 0 ]] && ! grep -Fxq -- "$path" <<<"$issue_scope"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — starter-sync PR changes out-of-scope file ${path} (GH#37289)" >>"$LOGFILE"
			return 1
		fi
	done < <(printf '%s' "$files_json" | jq -r '.[].filename')
	return 0
}

#######################################
# Check whether an issue author has maintainer-equivalent repository access.
#
# GitHub can expose maintainer-operated issues/PRs as COLLABORATOR rather than
# OWNER/MEMBER. For worker-briefed auto-merge, verify that ambiguous metadata
# through the authenticated collaborator permission endpoint instead of forcing
# per-issue cryptographic approvals for every maintainer-run aidevops worker.
#
# Args: $1=repo_slug, $2=github_login, $3=precomputed_permission(optional)
# Returns: 0=trusted maintainer-equivalent access, 1=not trusted or API error
#######################################
_issue_author_has_maintainer_authority() {
	local repo_slug="$1"
	local login="$2"
	local permission="${3:-}"

	[[ -n "$repo_slug" && -n "$login" ]] || return 1

	if [[ -z "$permission" ]]; then
		#aidevops:trust-boundary GH#24958: ambiguous GitHub issue
		# author_association values are not sufficient to auto-merge worker PRs.
		# Confirm maintainer-equivalent access with authenticated metadata and fail
		# closed on API errors or permissions below write.
		permission=$(gh api "repos/${repo_slug}/collaborators/${login}/permission" \
			--jq '.permission // ""' 2>/dev/null) || return 1
	fi

	case "$permission" in
		admin | maintain | write)
			return 0
			;;
	esac
	return 1
}

#######################################
# Verify that a linked issue has a maintainer cryptographic approval (t3052).
#
# Marker-string presence is not a trust signal: any user able to comment could
# paste the marker. This helper delegates to approval-helper.sh, which verifies
# the SSH signature against the maintainer approval public key.
#
# Args: $1=issue_number, $2=repo_slug
# Returns: 0=verified approval, 1=no verified approval
#######################################
_issue_has_verified_crypto_approval() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 1

	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	[[ ! -f "$approval_helper" ]] && return 1

	local verify_result=""
	verify_result=$(bash "$approval_helper" verify "$issue_number" "$repo_slug" 2>/dev/null) || verify_result=""
	[[ "$verify_result" == "VERIFIED" ]]
	return $?
}

# Planning checkpoints may change at most this many files. GitHub returns at
# most 100 files per page, so any count at or below this bound is a complete
# file list; larger or truncated lists fail closed (GH#36922).
_PM_PLANNING_CHECKPOINT_MAX_FILES=50

#######################################
# Check whether a PR diff is a planning checkpoint (GH#36922): a non-empty,
# complete file list where every path, including both sides of a rename, is
# TODO.md or markdown under todo/. Mirrors the producer classifier
# full-loop-helper.sh::_diff_is_planning_only, which links such PRs with
# `For #N` so the issue stays open.
#
#aidevops:trust-boundary — this only narrows which non-closing parent-task
# links reach the unchanged issue-author trust chain. API errors, malformed
# payloads, oversized/truncated file lists and any non-planning path fail closed.
#
# Args: $1=pr_number, $2=repo_slug
# Returns: 0=planning checkpoint, 1=not a planning checkpoint,
#          2=file metadata unavailable or malformed
#######################################
_worker_briefed_pr_is_planning_checkpoint() {
	local pr_number="$1"
	local repo_slug="$2"
	local files_json="" file_count="" paths="" path="" head_before="" head_after=""
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 2
	# Bind the verdict to one head: read it before and after the file list and
	# fail closed if it moved (a push between reads could swap in other files).
	head_before=$(gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '.head.sha // ""' 2>/dev/null) || return 2
	[[ "$head_before" =~ ^[0-9a-f]{40}$ ]] || return 2
	# Pulse pins the head it will merge; a different head (even one that later
	# reverts) must not reuse a verdict classified for another commit.
	if [[ -n "${WORKER_BRIEFED_EXPECTED_HEAD:-}" && "$head_before" != "$WORKER_BRIEFED_EXPECTED_HEAD" ]]; then
		return 2
	fi
	files_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/files?per_page=100" 2>/dev/null) || return 2
	head_after=$(gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '.head.sha // ""' 2>/dev/null) || return 2
	[[ "$head_after" == "$head_before" ]] || return 2
	# `arrays` emits nothing for non-array payloads, so the integer check fails closed.
	file_count=$(printf '%s' "$files_json" | jq -r 'arrays | length' 2>/dev/null) || return 2
	[[ "$file_count" =~ ^[0-9]+$ ]] || return 2
	[[ "$file_count" -gt 0 && "$file_count" -le "$_PM_PLANNING_CHECKPOINT_MAX_FILES" ]] || return 1
	paths=$(printf '%s' "$files_json" | jq -r '.[] | (.filename // ""), (.previous_filename // empty)' 2>/dev/null) || return 2
	while IFS= read -r path; do
		case "$path" in
		TODO.md | todo/*.md) ;;
		*) return 1 ;;
		esac
	done <<<"$paths"
	# Publish the verified head so the merge transport can pin it
	# (--match-head-commit); a later push then cannot reuse this verdict.
	if [[ -n "${WORKER_BRIEFED_PLANNING_HEAD_FILE:-}" ]]; then
		printf '%s\n' "$head_before" >"$WORKER_BRIEFED_PLANNING_HEAD_FILE" || return 2
	fi
	return 0
}

#######################################
# Classify how a worker PR links its issue (GH#33999). Sets
# WORKER_BRIEFED_LINK_KIND to "closing" for a closing-keyword link (unchanged
# behaviour). For a For/Ref-only association
# #aidevops:trust-boundary — the issue must be open; a parent-task issue is
# eligible only for a planning checkpoint diff (GH#36922), which keeps the
# parent open and never dispatches it. Sets "non-closing reference" or
# "non-closing parent planning checkpoint". Never writes a closing keyword.
# On refusal, sets WORKER_BRIEFED_TRUST_REASON to a stable diagnostic that
# distinguishes metadata failure from link-policy refusal. Call directly, not
# in a command substitution, so both variables reach the caller.
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=issue API path
# Returns: 0=eligible link kind set, 1=ineligible or lookup failure
#######################################
_worker_briefed_link_kind() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local issue_api="$4"
	local closing_issue="" state_labels="" issue_state="" issue_labels="" planning_rc=0
	WORKER_BRIEFED_LINK_KIND=""
	if [[ "${WORKER_BRIEFED_BODY_AVAILABLE:-0}" == 1 ]]; then
		if ! closing_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" "$WORKER_BRIEFED_BODY" 2>/dev/null); then
			WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable: PR closing-reference lookup failed (t2449)"
			return 1
		fi
	elif ! closing_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null); then
		WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable: PR closing-reference lookup failed (t2449)"
		return 1
	fi
	if [[ -n "$closing_issue" ]]; then
		WORKER_BRIEFED_LINK_KIND="closing"
		return 0
	fi
	if ! state_labels=$(gh api "${issue_api}" --jq '[.state // "", ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) ||
		[[ "$state_labels" != *$'\t'* ]]; then
		WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable: issue #${linked_issue} state/labels lookup failed (t2449)"
		return 1
	fi
	issue_state="${state_labels%%$'\t'*}"
	issue_labels="${state_labels#*$'\t'}"
	if [[ "$issue_state" != "open" ]]; then
		WORKER_BRIEFED_TRUST_REASON="non-closing reference to issue #${linked_issue} which is not open (GH#33999)"
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked via non-closing reference to issue #${linked_issue} which is not open (GH#33999)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$issue_labels" =~ (^|,)parent-task(,|$) ]]; then
		_worker_briefed_pr_is_planning_checkpoint "$pr_number" "$repo_slug" || planning_rc=$?
		case "$planning_rc" in
		0)
			WORKER_BRIEFED_LINK_KIND="non-closing parent planning checkpoint"
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — non-closing reference to parent-task issue #${linked_issue} is a planning checkpoint (TODO.md/todo markdown only); parent stays open (GH#36922)" >>"$LOGFILE"
			return 0
			;;
		1)
			WORKER_BRIEFED_TRUST_REASON="non-closing reference to parent-task issue #${linked_issue} is only eligible for a planning checkpoint (TODO.md or todo/**/*.md, at most ${_PM_PLANNING_CHECKPOINT_MAX_FILES} files); link a child phase issue or use the final-phase closing route (GH#33999/GH#36922)"
			;;
		*)
			WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable: PR #${pr_number} file list lookup failed for parent-task planning check (GH#36922)"
			;;
		esac
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — ${WORKER_BRIEFED_TRUST_REASON}" >>"$LOGFILE"
		return 1
	fi
	WORKER_BRIEFED_LINK_KIND="non-closing reference"
	return 0
}

#######################################
# Check origin:worker worker-briefed auto-merge gates (t2449).
#
# Sibling to _check_interactive_pr_gates — validates that an origin:worker
# PR is eligible for auto-merge based on the maintainer-briefed trust chain.
# Called from _check_pr_merge_gates when the PR carries origin:worker.
#
# The trust-chain equivalence argument: if the underlying issue was filed by
# the repo OWNER/MEMBER, the worker faithfully implemented, CI confirms
# correctness, and no human reviewer objected, the trust chain is equivalent
# to (or stronger than) an origin:interactive auto-merge.
#
# Nine criteria (see GH#20204):
#   1. PR carries origin:worker label (caller pre-checks)
#   2. Linked issue authored by OWNER or MEMBER
#   3. Linked issue has live maintainer-author authority or cryptographic approval
#   4. All required status checks PASS/SKIPPED (checked by general gates)
#   5. No CHANGES_REQUESTED from human reviewers (checked by general gates)
#   6. PR is not a draft
#   7. No hold-for-review label
#   8. Passes review-bot-gate (checked by general gates)
#   9. No origin:worker-takeover label (caller pre-checks)
#
# Feature flag: AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE (default: 1=on, 0=off)
# When OFF, all origin:worker PRs fall back to manual merge only.
#
# Args: $1=pr_number, $2=repo_slug, $3=labels_str (comma-separated),
#       $4=is_draft, $5=linked_issue,
#       $6=precomputed_pr_author_permission(optional),
#       $7=precomputed_pr_author_login(optional)
# Returns: 0=all gates pass (eligible for auto-merge), 1=blocked
#######################################
_worker_briefed_trust_check() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"
	local linked_issue="$5"
	local precomputed_pr_author_permission="${6:-}"
	local precomputed_pr_author_login="${7:-}"
	local _true_status="true"
	WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable (t2449)"

	_worker_briefed_pr_eligible "$pr_number" "$repo_slug" "$labels_str" "$is_draft" "$linked_issue" || return 1

	# Reuse the issue API base path for author-association and NMR checks.
	local _issue_api
	_issue_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
	# Fetch author_association and user.login in one API call (t3062 needs login).
	local _issue_meta
	WORKER_BRIEFED_TRUST_REASON="linked issue metadata unavailable: issue #${linked_issue} author lookup failed (t2449)"
	_issue_meta=$(gh api "${_issue_api}" \
		--jq 'select(.pull_request == null) | [.author_association // "", .user.login // ""] | @tsv' 2>/dev/null) || return 1
	# Explicit body references must resolve to an actual local issue, not a PR
	# sharing the repository number space or unavailable metadata.
	if [[ -z "${_issue_meta//[[:space:]]/}" ]]; then
		WORKER_BRIEFED_TRUST_REASON="linked reference #${linked_issue} is not an issue or has no author metadata (t2449)"
		return 1
	fi
	local issue_author_assoc=""
	local issue_author_login=""
	read -r issue_author_assoc issue_author_login <<< "$_issue_meta"

	# GH#33999: non-closing For/Ref links require an open issue; GH#36922:
	# parent-task issues additionally require a planning checkpoint diff.
	# Called directly so its stable refusal reason reaches the verdict.
	local WORKER_BRIEFED_LINK_KIND=""
	_worker_briefed_link_kind "$pr_number" "$repo_slug" "$linked_issue" "$_issue_api" || return 1
	local _link_kind="$WORKER_BRIEFED_LINK_KIND"
	local issue_author_permission=""
	#aidevops:trust-boundary — reuse PR-author permission only for the same non-empty issue-author login.
	if [[ -n "$precomputed_pr_author_permission" && -n "$precomputed_pr_author_login" && "$precomputed_pr_author_login" == "$issue_author_login" ]]; then
		issue_author_permission="$precomputed_pr_author_permission"
	fi

	local _has_crypto="not-verified"
	if _issue_has_verified_crypto_approval "$linked_issue" "$repo_slug"; then
		_has_crypto="$_true_status"
	fi

	# Preserve the existing OWNER/MEMBER, live permission, allowlist, scoped
	# canary and verified signature alternatives at this shared trust boundary.
	if [[ "$issue_author_assoc" != "OWNER" && "$issue_author_assoc" != "MEMBER" ]]; then
		if _issue_author_has_maintainer_authority "$repo_slug" "$issue_author_login" "$issue_author_permission"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via authenticated maintainer permission fallback (GH#24958)" >>"$LOGFILE"
		elif _is_trusted_issue_author "$issue_author_login"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via trusted-issue-author allowlist (t3062)" >>"$LOGFILE"
		elif _is_trusted_opencode_canary_issue_pr "$pr_number" "$repo_slug" "$_issue_api"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} is a scheduled OpenCode pin-canary brief and the diff stays in canary scope (GH#35752)" >>"$LOGFILE"
		elif _is_trusted_starter_sync_issue_pr "$pr_number" "$repo_slug" "$_issue_api"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} is a starter-sync issue and the diff stays within scripts/core-files.txt (GH#37289)" >>"$LOGFILE"
		elif [[ "$_has_crypto" != "$_true_status" ]]; then
			WORKER_BRIEFED_TRUST_REASON="linked issue #${linked_issue} author_association=${issue_author_assoc} (not OWNER/MEMBER) and no cryptographic approval signature found (t2449/t3052)"
			echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — ${WORKER_BRIEFED_TRUST_REASON}" >>"$LOGFILE"
			if [[ "$issue_author_login" == "$_PM_WORKFLOW_BOT_LOGIN" ]]; then
				_worker_briefed_record_bot_decision "$linked_issue" "$repo_slug" ||
					echo "[pulse-merge] could not record bot issue #${linked_issue} approval decision in ${repo_slug}; retry on next pass" >>"$LOGFILE"
			fi
			return 1
		else
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} but cryptographic approval signature present, proceeding (t3052)" >>"$LOGFILE"
		fi
	fi
	echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} passed all gates (issue #${linked_issue}, link=${_link_kind}, author_assoc=${issue_author_assoc}, crypto_approved=${_has_crypto}) (t2449/t3052)" >>"$LOGFILE"
	return 0
}

_worker_briefed_pr_eligible() {
	local pr_number="$1" repo_slug="$2" labels_str="$3" is_draft="$4" linked_issue="$5"
	# Feature flag — when OFF, all origin:worker PRs fall back to manual merge
	if [[ "${AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE:-1}" == "0" ]]; then
		WORKER_BRIEFED_TRUST_REASON="AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 (t2449)"
		echo "[pulse-merge] worker-briefed auto-merge: disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 for PR #${pr_number} in ${repo_slug} (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: not a draft
	if [[ "$is_draft" == "$_true_status" ]]; then
		WORKER_BRIEFED_TRUST_REASON="draft PR not eligible (t2449)"
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: no hold-for-review opt-out label
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		WORKER_BRIEFED_TRUST_REASON="hold-for-review label (t2449)"
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — hold-for-review label (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: must have a linked issue (the "brief" in "maintainer-briefed")
	if [[ -z "$linked_issue" ]]; then
		WORKER_BRIEFED_TRUST_REASON="no linked issue (t2449)"
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — no linked issue (t2449)" >>"$LOGFILE"
		return 1
	fi

	return 0
}

# Record the conservative outcome for workflow-bot issues, without trusting a
# forgeable generator marker. A maintainer can approve through the existing
# SSH-signature path; the scoped pin-canary exception above remains unchanged.
_worker_briefed_record_bot_decision() {
	local issue_number="$1" repo_slug="$2"
	local marker="<!-- aidevops:worker-briefed-trust-decision:v1 -->"
	local actor="" comments="" body_file="" candidate="" rc=0
	[[ "${DRY_RUN:-0}" != "1" ]] || return 0
	# Installation tokens can write repository comments without a /user endpoint.
	actor=$(gh api user --jq '.login' 2>/dev/null) || actor=""
	comments=$(gh api --paginate --slurp "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	jq -e 'arrays | all(.[]; type == "array")' <<<"$comments" >/dev/null || return 1
	#aidevops:trust-boundary — dedupe across authorized runners, but not arbitrary
	# commenters pasting a marker. This record never grants merge authority.
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		if [[ "$candidate" == "$actor" || "$candidate" == "$_PM_WORKFLOW_BOT_LOGIN" ]] ||
			_issue_author_has_maintainer_authority "$repo_slug" "$candidate"; then
			return 0
		fi
	done < <(jq -r --arg marker "$marker" \
		'.[][] | select((.body // "") | contains($marker)) | .user.login // empty' <<<"$comments")
	body_file=$(mktemp "${TMPDIR:-/tmp}/worker-briefed-decision.XXXXXX") || return 1
	printf '%s\n\n%s\n' "$marker" \
		"Automated merge is blocked by the linked-issue trust gate (t2449/t3052). This workflow-bot issue has no verified maintainer approval or applicable scoped trust exception. Next action (maintainer): run \`sudo aidevops approve issue ${issue_number}\` for ${repo_slug}. The next merge pass verifies the signature; all CI, review and hold gates still apply. Reference: pulse-merge-process-worker-briefed.sh, worker_briefed_trust_verdict." >"$body_file"
	gh_issue_comment "$issue_number" --repo "$repo_slug" --body-file "$body_file" >/dev/null || rc=$?
	rm -f "$body_file"
	return "$rc"
}

# Shared t2449 verdict. Optional precomputed arguments use the deterministic
# pass's metadata; the two-argument entry point resolves it with the same parser.
# Prints only allow or deny:<reason>; returns nonzero on denial/API failure.
worker_briefed_trust_verdict() {
	local pr_number="$1" repo_slug="$2"
	local labels_str="${3:-}" is_draft="${4:-}" linked_issue="${5:-}"
	local WORKER_BRIEFED_TRUST_REASON="trust metadata unavailable (t2449)"
	local WORKER_BRIEFED_BODY_AVAILABLE=0 WORKER_BRIEFED_BODY=""
	if [[ "$#" -eq 2 ]]; then
		local pr_meta="" head_sha="" pr_body=""
		pr_meta=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels,isDraft,headRefOid,body) || {
			printf 'deny:%s\n' "$WORKER_BRIEFED_TRUST_REASON"
			return 1
		}
		# Missing/malformed label metadata is not evidence of a non-worker PR.
		if ! jq -e 'type == "object" and (.labels | type == "array")
			and all(.labels[]; .name | type == "string")
			and (.isDraft | type == "boolean") and (.body | type == "string")' <<<"$pr_meta" >/dev/null 2>&1; then
			printf 'deny:%s\n' "$WORKER_BRIEFED_TRUST_REASON"
			return 1
		fi
		labels_str=$(jq -r '[.labels[].name] | join(",")' <<<"$pr_meta") || return 1
		is_draft=$(jq -r '.isDraft' <<<"$pr_meta") || return 1
		[[ ",${labels_str}," == *",origin:worker,"* ]] || { printf 'allow\n'; return 0; }
		# The deterministic pass exempts verified exact-head Issue Sync / TODO
		# handoff PRs before the worker-briefed gate. Preserve that narrow route;
		# the shared predicate verifies bot identity, repo ownership and head.
		head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_meta") || return 1
		if [[ -n "$head_sha" ]] && _pulse_is_trusted_issue_sync_pr "$pr_number" "$repo_slug" "$head_sha"; then
			printf 'allow\n'
			return 0
		fi
		pr_body=$(jq -r '.body' <<<"$pr_meta") || return 1
		WORKER_BRIEFED_BODY="$pr_body"
		WORKER_BRIEFED_BODY_AVAILABLE=1
		linked_issue=$(_extract_pr_work_issue "$pr_number" "$repo_slug" explicit "$pr_body") || {
			printf 'deny:%s\n' "$WORKER_BRIEFED_TRUST_REASON"
			return 1
		}
	fi
	if _worker_briefed_trust_check "$pr_number" "$repo_slug" "$labels_str" "$is_draft" "$linked_issue" "${6:-}" "${7:-}"; then
		printf 'allow\n'
		return 0
	fi
	printf 'deny:%s\n' "$WORKER_BRIEFED_TRUST_REASON"
	return 1
}

_attempt_worker_briefed_auto_merge() {
	worker_briefed_trust_verdict "$@" >/dev/null
	return $?
}

# Full-loop adapter runs in a subshell: loading the deterministic parser and
# its dependencies must not replace full-loop globals/functions. Both automated
# and interactive entry points are checked; only explicit interactive --admin
# with live maintainer authority may override this gate, never other gates.
_merge_worker_briefed_trust_gate() (
	local pr_number="$1" repo_slug="$2" has_admin="${3:-0}"
	local LOGFILE="" verdict="" permission=""
	LOGFILE=$(mktemp "${TMPDIR:-/tmp}/worker-briefed-trust.XXXXXX") || {
		print_error "Merge blocked by t2449: trust-gate log creation failed"
		return 1
	}
	trap 'rm -f "$LOGFILE"' EXIT
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-merge.sh" || {
		print_error "Merge blocked by t2449: trust evaluator loading failed"
		return 1
	}
	# Trust decisions must observe edits made since a cross-cycle cache was warmed.
	if verdict=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 worker_briefed_trust_verdict "$pr_number" "$repo_slug"); then
		return 0
	fi
	local reason="${verdict#deny:}"
	reason="${reason:-trust verdict unavailable}"
	if ! _merge_is_headless_session && [[ "$has_admin" == "1" ]] &&
		permission=$(gh api "repos/${repo_slug}" --jq '.permissions | (.admin or .maintain or .push)' 2>/dev/null) &&
		[[ "$permission" == "true" ]]; then
		print_warning "Explicit interactive --admin overrides t2449: ${reason}"
		return 0
	fi
	print_error "Merge blocked by t2449: ${reason}"
	return 1
)
