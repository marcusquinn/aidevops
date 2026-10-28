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
	[[ "$login" == "github-actions[bot]" && "$user_type" == "Bot" ]] || return 1
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
		if ! printf '%s\n' "$_PM_OPENCODE_CANARY_ALLOWED_FILES" | grep -Fxq -- "$path"; then
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

#######################################
# Classify how a worker PR links its issue (GH#33999). Prints "closing" for a
# closing-keyword link (unchanged behaviour). For a For/Ref-only association
# #aidevops:trust-boundary — the issue must be open and not parent-task; prints
# "non-closing reference". Never writes a closing keyword.
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=issue API path
# Returns: 0=eligible link kind printed, 1=ineligible or lookup failure
#######################################
_worker_briefed_link_kind() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local issue_api="$4"
	local closing_issue="" state_labels="" issue_state="" issue_labels=""
	closing_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || return 1
	if [[ -n "$closing_issue" ]]; then
		printf '%s' "closing"
		return 0
	fi
	state_labels=$(gh api "${issue_api}" --jq '[.state // "", ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) || return 1
	issue_state="${state_labels%%$'\t'*}"
	issue_labels="${state_labels#*$'\t'}"
	if [[ "$issue_state" != "open" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked via non-closing reference to issue #${linked_issue} which is not open (GH#33999)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$issue_labels" =~ (^|,)parent-task(,|$) ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked via non-closing reference to parent-task issue #${linked_issue} (GH#33999)" >>"$LOGFILE"
		return 1
	fi
	printf '%s' "non-closing reference"
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
_attempt_worker_briefed_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"
	local linked_issue="$5"
	local precomputed_pr_author_permission="${6:-}"
	local precomputed_pr_author_login="${7:-}"
	local _true_status="true"

	# Feature flag — when OFF, all origin:worker PRs fall back to manual merge
	if [[ "${AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE:-1}" == "0" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 for PR #${pr_number} in ${repo_slug} (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: not a draft
	if [[ "$is_draft" == "$_true_status" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: no hold-for-review opt-out label
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — hold-for-review label (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: must have a linked issue (the "brief" in "maintainer-briefed")
	if [[ -z "$linked_issue" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — no linked issue (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Reuse the issue API base path for author-association and NMR checks.
	local _issue_api
	_issue_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
	# Fetch author_association and user.login in one API call (t3062 needs login).
	local _issue_meta
	_issue_meta=$(gh api "${_issue_api}" \
		--jq 'select(.pull_request == null) | [.author_association // "", .user.login // ""] | @tsv' 2>/dev/null) || return 1
	# Explicit body references must resolve to an actual local issue, not a PR
	# sharing the repository number space or unavailable metadata.
	[[ -n "${_issue_meta//[[:space:]]/}" ]] || return 1
	local issue_author_assoc=""
	local issue_author_login=""
	read -r issue_author_assoc issue_author_login <<< "$_issue_meta"

	# GH#33999: a PR with only a non-closing For/Ref reference may be associated
	# with an issue that stays open for later phases. #aidevops:trust-boundary —
	# that association is eligible only for an open, non-parent issue; all trust
	# gates below still apply unchanged. Closing-keyword links are untouched.
	local _link_kind=""
	_link_kind=$(_worker_briefed_link_kind "$pr_number" "$repo_slug" "$linked_issue" "$_issue_api") || return 1
	local issue_author_permission=""
	#aidevops:trust-boundary — reuse PR-author permission only for the same non-empty issue-author login.
	if [[ -n "$precomputed_pr_author_permission" && -n "$precomputed_pr_author_login" && "$precomputed_pr_author_login" == "$issue_author_login" ]]; then
		issue_author_permission="$precomputed_pr_author_permission"
	fi

	local _not_true_status="not-verified"
	local _has_crypto="$_not_true_status"
	if _issue_has_verified_crypto_approval "$linked_issue" "$repo_slug"; then
		_has_crypto="$_true_status"
	fi

	# Gate: linked issue authored by OWNER/MEMBER, OR login has authenticated
	# maintainer-equivalent repo permission (GH#24958), OR login is in the
	# trusted-issue-author allowlist (t3062), OR cryptographically approved
	# by maintainer (t3052). The trust chain "maintainer SSH-signed
	# an approval on the issue" is at least as strong as the OWNER/MEMBER
	# author check — the maintainer personally vouched with their private key.
	if [[ "$issue_author_assoc" != "OWNER" && "$issue_author_assoc" != "MEMBER" ]]; then
		if _issue_author_has_maintainer_authority "$repo_slug" "$issue_author_login" "$issue_author_permission"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via authenticated maintainer permission fallback (GH#24958)" >>"$LOGFILE"
		elif _is_trusted_issue_author "$issue_author_login"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via trusted-issue-author allowlist (t3062)" >>"$LOGFILE"
		elif _is_trusted_opencode_canary_issue_pr "$pr_number" "$repo_slug" "$_issue_api"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} is a scheduled OpenCode pin-canary brief and the diff stays in canary scope (GH#35752)" >>"$LOGFILE"
		elif [[ "$_has_crypto" != "$_true_status" ]]; then
			echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} (not OWNER/MEMBER) and no cryptographic approval signature found (t2449/t3052)" >>"$LOGFILE"
			return 1
		else
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} but cryptographic approval signature present, proceeding (t3052)" >>"$LOGFILE"
		fi
	fi

	# Historical NMR/normalization comments are not current authority signals.
	# Live issue-author authority above is sufficient; external authors still
	# require verified cryptographic approval and live NMR remains blocked by the
	# general merge gates.
	echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} passed all gates (issue #${linked_issue}, link=${_link_kind}, author_assoc=${issue_author_assoc}, crypto_approved=${_has_crypto}) (t2449/t3052)" >>"$LOGFILE"
	return 0
}
