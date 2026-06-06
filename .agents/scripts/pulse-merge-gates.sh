#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-gates.sh — PR Gate Checking Functions
# =============================================================================
# Extracted from pulse-merge.sh (GH#21301) to bring the parent file below
# the 1500-line file-size-debt threshold.
#
# Covers PR gate functions that run before the merge processing pipeline:
#   - check_external_contributor_pr   — flag external-contributor PRs (t1391)
#   - _external_pr_has_linked_issue   — linked issue check for external PRs
#   - _external_pr_linked_issue_crypto_approved — crypto approval gate
#   - _has_maintainer_crypto_approval  — PR/linked-issue crypto-approval check (t3063)
#   - _pulse_merge_admin_safety_check — defense-in-depth --admin gate (t2934)
#   - check_permission_failure_pr     — permission API failure handler
#   - approve_collaborator_pr         — auto-approve collaborator PRs
#   - check_pr_modifies_workflows     — workflow file modification check
#   - check_gh_workflow_scope         — token scope check for workflow merges
#   - check_workflow_merge_guard      — combined workflow merge guard
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-gates.sh"
#        (sourced by pulse-merge.sh after shared-phase-filing.sh)
#
# Dependencies:
#   - shared-constants.sh (gh_pr_comment, gh_issue_comment, etc.)
#   - pulse-merge-author-checks.sh (_is_collaborator_author)
#   - LOGFILE variable (set by pulse-merge.sh module defaults or orchestrator)
#   - _extract_linked_issue (defined in pulse-merge.sh, resolved at call time)
#   - _OW_LABEL_PAT (defined in pulse-merge.sh before sourcing this file)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_GATES_LOADED:-}" ]] && return 0
_PULSE_MERGE_GATES_LOADED=1

# Defensive defaults for standalone sourcing (test harnesses, pulse-merge-routine.sh)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# --- Functions ---

#######################################
# Resolve the trusted Dependabot update allowlist path.
# Output: config path
# Returns: 0 always
#######################################
_trusted_dependabot_updates_conf() {
	local default_conf="${_PULSE_MERGE_DIR:+${_PULSE_MERGE_DIR}/../configs/trusted-dependabot-updates.conf}"
	printf '%s' "${AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF:-$default_conf}"
	return 0
}

#######################################
# Check whether a Dependabot dependency is on the maintainer allowlist.
#
# Config entries are exact, one per line: `package` or `manager:package`.
# Empty/missing config is fail-closed. `*` is accepted only when explicitly
# configured by the maintainer.
# Args: $1=package_manager, $2=dependency_name
# Returns: 0 allowed, 1 not allowed
#######################################
_trusted_dependabot_dependency_allowed() {
	local package_manager="$1"
	local dependency_name="$2"
	local conf_path
	conf_path=$(_trusted_dependabot_updates_conf)

	[[ -n "$dependency_name" && -f "$conf_path" ]] || return 1
	local entries
	entries=$(sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$conf_path" 2>/dev/null | sed '/^$/d') || entries=""
	[[ -n "$entries" ]] || return 1
	if printf '%s\n' "$entries" | grep -Fxq '*'; then
		return 0
	fi
	if [[ -n "$package_manager" ]] \
		&& printf '%s\n' "$entries" | grep -Fxq "${package_manager}:${dependency_name}"; then
		return 0
	fi
	printf '%s\n' "$entries" | grep -Fxq "$dependency_name"
	return $?
}

#######################################
# Verify a Dependabot PR is an authentic, maintainer-allowed version update.
#
# This is intentionally narrow: it only grants the collaborator/review-bot
# allowance for GitHub's Dependabot bot, same-repository branches, commits by
# dependabot[bot], dependency-file-only diffs, allowlisted dependency names,
# and no terminal security-scan failures. Required CI still gates the merge in
# the caller; this helper only answers whether the bot-origin trust boundary is
# strong enough to avoid treating the PR like an untrusted external author.
#
# #aidevops:trust-boundary — Dependabot bypass is not author-name trust. It
# validates API author identity, repository ownership, commit authorship, diff
# shape, explicit dependency allowlist, and security-scan status before granting
# any merge/approval allowance.
# Args: $1=pr_number, $2=repo_slug, $3=pr_author
# Returns: 0 trusted Dependabot update, 1 not trusted
#######################################
_is_trusted_dependabot_update_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-}"

	[[ "${AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES:-1}" != "0" ]] || return 1
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1
	case "$pr_author" in
	dependabot\[bot\] | app/dependabot | "") ;;
	*) return 1 ;;
	esac

	local pr_json
	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json author,body,commits,files,headRepository,headRepositoryOwner,statusCheckRollup \
		2>/dev/null) || return 1
	[[ -n "$pr_json" && "$pr_json" != "null" ]] || return 1

	local repo_owner="${repo_slug%%/*}"
	local api_author="" head_owner="" head_repo=""
	api_author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""' 2>/dev/null) || return 1
	head_owner=$(printf '%s' "$pr_json" | jq -r '.headRepositoryOwner.login // .headRepositoryOwner.name // ""' 2>/dev/null) || return 1
	head_repo=$(printf '%s' "$pr_json" | jq -r '.headRepository.nameWithOwner // ""' 2>/dev/null) || return 1
	case "$api_author" in
	dependabot\[bot\] | app/dependabot) ;;
	*) return 1 ;;
	esac
	[[ "$head_owner" == "$repo_owner" && "$head_repo" == "$repo_slug" ]] || return 1

	local bad_commits
	bad_commits=$(printf '%s' "$pr_json" | jq '[.commits[]? | select([.authors[]?.login] | index("dependabot[bot]") | not)] | length' 2>/dev/null) || return 1
	[[ "$bad_commits" == "0" ]] || return 1

	local bad_files
	bad_files=$(printf '%s' "$pr_json" | jq -r '[.files[]?.path | select(test("(^|/)(requirements(-lock)?\\.txt|requirements.*\\.txt|pyproject\\.toml|poetry\\.lock|uv\\.lock|Pipfile\\.lock|package(-lock)?\\.json|pnpm-lock\\.yaml|yarn\\.lock|composer\\.(json|lock)|Gemfile\\.lock|go\\.(mod|sum)|Cargo\\.(toml|lock))$|^\\.github/dependabot\\.yml$"; "i") | not)] | length' 2>/dev/null) || return 1
	[[ "$bad_files" == "0" ]] || return 1

	local security_failures
	security_failures=$(printf '%s' "$pr_json" | jq 'def up(v): (v // "" | ascii_upcase); [.statusCheckRollup[]? | select(((.name // .context // "") | test("security|socket|codeql|dependabot"; "i")) and (up(.conclusion) == "FAILURE" or up(.conclusion) == "ERROR" or up(.state) == "FAILURE" or up(.state) == "ERROR"))] | length' 2>/dev/null) || return 1
	[[ "$security_failures" == "0" ]] || return 1

	local body package_manager dependencies dependency_name allowed_count=0
	body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	package_manager=$(printf '%s' "$body" | sed -nE 's/^Bumps the ([A-Za-z0-9_.-]+) group.*$/\1/p' | head -1)
	dependencies=$(printf '%s\n' "$body" | sed -nE 's/^[[:space:]]*-[[:space:]]*dependency-name:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p')
	[[ -n "$dependencies" ]] || return 1
	while IFS= read -r dependency_name; do
		[[ -n "$dependency_name" ]] || continue
		if ! _trusted_dependabot_dependency_allowed "$package_manager" "$dependency_name"; then
			echo "[pulse-wrapper] trusted Dependabot gate: PR #${pr_number} in ${repo_slug} dependency ${package_manager:+${package_manager}:}${dependency_name} is not allowlisted" >>"$LOGFILE"
			return 1
		fi
		allowed_count=$((allowed_count + 1))
	done <<<"$dependencies"
	[[ "$allowed_count" -gt 0 ]] || return 1

	echo "[pulse-wrapper] trusted Dependabot gate: PR #${pr_number} in ${repo_slug} passed bot identity, same-repo, commit, file, allowlist, and security-scan checks" >>"$LOGFILE"
	return 0
}

#######################################
# Verify all non-review-bot checks are green for trusted Dependabot updates.
#
# GitHub's review-bot-gate workflow can remain red on Dependabot PRs because
# AI review bots often skip dependency-only updates. This helper is the narrow
# escape hatch: it ignores only review-bot-gate contexts and requires every
# other check/status in the rollup to be terminal-success/neutral/skipped.
# Args: $1=pr_number, $2=repo_slug
# Returns: 0 non-review checks green, 1 otherwise
#######################################
_trusted_dependabot_non_review_checks_green() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_json=""
	local result=""
	local non_review_count="0" blocker_count="0"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1
	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json statusCheckRollup 2>/dev/null) || return 1
	[[ -n "$pr_json" && "$pr_json" != "null" ]] || return 1

	result=$(printf '%s' "$pr_json" | jq -r '
		def up(v): (v // "" | ascii_upcase);
		def check_label: (.name // .context // "");
		def is_review_gate: ((check_label | test("(^|/ )review-bot-gate$|^review-bot-gate$"; "i")) or ((.workflowName // "") == "Review Bot Gate"));
		def passish: (up(.conclusion) == "SUCCESS" or up(.conclusion) == "NEUTRAL" or up(.conclusion) == "SKIPPED" or up(.state) == "SUCCESS");
		def pendingish: (up(.status) == "QUEUED" or up(.status) == "IN_PROGRESS" or up(.state) == "PENDING" or up(.state) == "EXPECTED" or ((up(.conclusion) == "") and (up(.state) != "SUCCESS") and (up(.status) != "COMPLETED")));
		[([.statusCheckRollup[]? | select(is_review_gate | not)] | length),
		 ([.statusCheckRollup[]? | select((is_review_gate | not) and (pendingish or (passish | not)))] | length)] | @tsv
	' 2>/dev/null) || return 1
	read -r non_review_count blocker_count <<<"$result"
	[[ "$non_review_count" =~ ^[0-9]+$ && "$blocker_count" =~ ^[0-9]+$ ]] || return 1
	if [[ "$non_review_count" -gt 0 && "$blocker_count" -eq 0 ]]; then
		echo "[pulse-wrapper] trusted Dependabot checks: PR #${pr_number} in ${repo_slug} has all non-review-bot checks green" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] trusted Dependabot checks: PR #${pr_number} in ${repo_slug} blocked (non_review=${non_review_count}, blockers=${blocker_count})" >>"$LOGFILE"
	return 1
}

#######################################
# Check and flag external-contributor PRs (t1391)
#
# Deterministic idempotency guard for the external-contributor comment.
# Moved from pulse.md inline bash to a shell function because the LLM
# kept getting the fail-closed logic wrong (4 prior fix attempts:
# PRs #2794, #2796, #2801, #2803 — all in pulse.md prompt text).
#
# This is exactly the kind of logic that belongs in the harness, not
# the prompt: it has one correct answer regardless of context.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#
# Exit codes:
#   0 - already flagged (label or comment exists) — no action needed
#   1 - not yet flagged AND API calls succeeded — caller should post
#   2 - API error (fail closed) — caller must skip, next pulse retries
#
# Side effects when exit=1 (caller invokes with --post):
#   Posts the external-contributor comment and adds the label.
#######################################
check_external_contributor_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local do_post="${4:-}"

	# Validate arguments
	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_external_contributor_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check for existing label (capture exit code separately from output)
	local label_output
	label_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels --jq '.labels[].name')
	local label_exit=$?

	local has_label=false
	if [[ $label_exit -eq 0 ]] && echo "$label_output" | grep -q '^external-contributor$'; then
		has_label=true
	fi

	# Step 2: Check for existing comment
	local comment_output
	comment_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comment_exit=$?

	local has_comment=false
	if [[ $comment_exit -eq 0 ]] && echo "$comment_output" | grep -qiF 'external contributor'; then
		has_comment=true
	fi

	# Step 3: Decide action based on results
	if [[ $label_exit -ne 0 || $comment_exit -ne 0 ]]; then
		# API error on label or comment check — fail closed, skip posting entirely.
		# The next pulse cycle will retry. Never post when we can't confirm absence.
		echo "[pulse-wrapper] check_external_contributor_pr: API error (label_exit=$label_exit, comment_exit=$comment_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if $has_label || $has_comment; then
		# Already flagged. Re-add label if missing (comment exists but label doesn't).
		if [[ "$has_label" == "false" ]]; then
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' || true
		fi
		return 0
	fi

	# Both API calls succeeded AND neither label nor comment exists.
	if [[ "$do_post" == "--post" ]]; then
		# Safe to post — this is the only code path that creates a comment.
			gh_pr_comment "$pr_number" --repo "$repo_slug" \
			--body "This PR is from an external contributor (@${pr_author}). Auto-merge is disabled for external PRs — a maintainer must review and approve manually.

External contributor PRs have two requirements before they can merge:
1. A linked issue (\`Resolves #NNN\` in the PR body, or \`GH#NNN:\` prefix in the title)
2. Cryptographic approval on that linked issue (\`sudo aidevops approve issue NNN ${repo_slug}\`)

---
**To approve or decline**, comment on this PR:
- \`approved\` — removes the review gate and allows merge (CI permitting)
- \`declined: <reason>\` — closes this PR (include your reason after the colon)" &&
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' \
				-f 'labels[]=needs-maintainer-review' || true
		echo "[pulse-wrapper] check_external_contributor_pr: flagged PR #$pr_number in $repo_slug as external contributor (@$pr_author)" >>"$LOGFILE"

		# Post a second comment if no linked issue found (t1958)
		local linked_for_check
		linked_for_check=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_for_check=""
		if [[ -z "$linked_for_check" ]]; then
		gh_pr_comment "$pr_number" --repo "$repo_slug" \
				--body "**Missing linked issue.** This PR has no linked issue. External contributor PRs require a linked issue before they can be considered for merge. Add \`Resolves #NNN\` to the PR body (or use \`GH#NNN:\` in the title), then ensure that issue has been cryptographically approved by a maintainer (\`sudo aidevops approve issue NNN ${repo_slug}\`)." || true
			echo "[pulse-wrapper] check_external_contributor_pr: PR #$pr_number in $repo_slug has no linked issue — posted missing-linked-issue comment" >>"$LOGFILE"
		fi
	fi
	return 1
}

#######################################
# Check if an external-contributor PR has a linked issue (t1958).
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Returns: 0 if linked issue found, 1 if not
#######################################
_external_pr_has_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked
	linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	[[ -n "$linked" ]]
	return $?
}

#######################################
# Check if an external-contributor PR's linked issue has crypto approval (t1958).
#
# Unlike issue_has_required_approval() (which gates on ever-NMR history),
# this function requires approval unconditionally for all external PRs.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Returns: 0 if approved, 1 if not approved or no linked issue
#######################################
_external_pr_linked_issue_crypto_approved() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked
	linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	[[ -z "$linked" ]] && return 1
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	[[ ! -f "$approval_helper" ]] && return 1
	local result
	result=$(bash "$approval_helper" verify "$linked" "$repo_slug" 2>/dev/null) || result=""
	[[ "$result" == "VERIFIED" ]]
	return $?
}

#######################################
# Check whether a PR or its linked issue has a maintainer crypto-approval
# signature (t3063 — symmetric extension of t3052 to the deterministic merge
# cascade and the approve_collaborator_pr gate).
#
# A cryptographic approval (sudo aidevops approve) is at least as strong a
# trust signal as author-association because it requires a root-owned SSH
# private key that workers cannot forge.
#
# Checks PR-level comments first, then linked-issue comments. Uses
# approval-helper.sh for cryptographic verification when available; falls back
# to marker presence when the helper is absent (the marker can only be posted
# by someone with write access, and full verification is provided by the
# existing downstream gate in _external_pr_linked_issue_crypto_approved).
#
# #aidevops:trust-boundary — this function gates security-relevant approval
# decisions. Changes here require preserving the four-layer defence-in-depth
# documented in reference/incident-gh17671-supply-chain.md.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Returns: 0 if crypto approval found, 1 if not
#######################################
_has_maintainer_crypto_approval() {
	local pr_number="$1"
	local repo_slug="$2"
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"

	# Marker string embedded in every signed approval comment by approval-helper.sh.
	# Source of truth: approval-helper.sh line ~65 APPROVAL_MARKER constant.
	local _approval_marker="aidevops-signed-approval"
	# Use a named local for the approval-helper success status to keep the
	# literal string count below the repeated-string-literal ratchet threshold.
	local _approved_status="VERIFIED"

	# Check PR-level comments for a crypto-approval signature.
	local pr_marker_count
	pr_marker_count=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq "[.[].body | strings | select(contains(\"${_approval_marker}\"))] | length" \
		2>/dev/null || true)
	[[ "$pr_marker_count" =~ ^[0-9]+$ ]] || pr_marker_count=0
	if [[ "$pr_marker_count" -gt 0 ]]; then
		if [[ -f "$approval_helper" ]]; then
			local _pr_verify
			_pr_verify=$(bash "$approval_helper" verify "$pr_number" "$repo_slug" 2>/dev/null) || _pr_verify=""
			if [[ "$_pr_verify" == "$_approved_status" ]]; then
				return 0
			fi
		else
			# Trust the marker when the helper is absent — full cryptographic
			# verification is provided by _external_pr_linked_issue_crypto_approved
			# in the downstream gate chain.
			return 0
		fi
	fi

	# Check linked-issue comments for a crypto-approval signature.
	local linked
	linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	[[ -z "$linked" ]] && return 1

	local issue_marker_count
	issue_marker_count=$(gh api "repos/${repo_slug}/issues/${linked}/comments" \
		--jq "[.[].body | strings | select(contains(\"${_approval_marker}\"))] | length" \
		2>/dev/null || true)
	[[ "$issue_marker_count" =~ ^[0-9]+$ ]] || issue_marker_count=0
	if [[ "$issue_marker_count" -gt 0 ]]; then
		if [[ -f "$approval_helper" ]]; then
			local _issue_verify
			_issue_verify=$(bash "$approval_helper" verify "$linked" "$repo_slug" 2>/dev/null) || _issue_verify=""
			if [[ "$_issue_verify" == "$_approved_status" ]]; then
				return 0
			fi
		else
			return 0
		fi
	fi

	return 1
}

#######################################
# Defense-in-depth: refuse `gh pr merge --admin` for external-contributor
# (or unlabeled fork) PRs without crypto approval (t2934).
#
# Background. Workers run with admin-equivalent permissions. The `--admin`
# flag at the merge call site bypasses GitHub branch protection (required
# status checks, required reviewers). The 2026-04-07 incident merged three
# external-contributor PRs (#17671, #17685, #3846) because the
# `maintainer-gate.yml` workflow's Check 0 only inspected the linked-issue
# label, not the PR's own label. PR #17868 hardened the workflow, and the
# external-contributor gate inside `_check_pr_merge_gates` is the primary
# client-side check today.
#
# This function is a deliberately-redundant LAST gate, evaluated immediately
# before the `gh pr merge … --admin` invocation in `_process_single_ready_pr`.
# It restates the external-contributor gate at the call site so the safety
# property becomes local to the bypass operation — independent of:
#
#   * upstream gate ordering (a future refactor that reshuffles
#     `_check_pr_merge_gates` cannot remove the protection),
#   * label-application timing races (pr-triage-gate.yml has not yet
#     applied `external-contributor` when the merge pass fires),
#   * any future code path that reaches the merge invocation without
#     traversing the existing gate chain.
#
# Two complementary triggers treat a PR as "external" for this gate:
#
#   1. `external-contributor` label present, OR
#   2. `isCrossRepository=true` (the PR head is on a fork) — even if the
#      label is absent. An unlabeled fork PR is a HIGHER-severity signal
#      than a labeled one, because the labeling system itself failed.
#
# When external: require linked issue + cryptographic approval (the same
# evidence the upstream gate requires). When not external: pass — the
# existing collaborator gates apply.
#
# Args:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Returns:
#   0 - safe to invoke `--admin` merge (not external, OR external with
#       linked issue + crypto approval)
#   1 - REFUSE: external/fork PR without crypto approval
#######################################
_pulse_merge_admin_safety_check() {
	local pr_number="$1"
	local repo_slug="$2"

	# t2863: initialise multi-var locals at declaration time so set -u
	# is safe even on a partial-failure path through the assignments.
	local pr_meta_json="" labels_str="" is_fork="false"
	pr_meta_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels,isCrossRepository 2>/dev/null) || pr_meta_json=""
	labels_str=$(printf '%s' "$pr_meta_json" \
		| jq -r '[.labels[].name] | join(",")' 2>/dev/null) || labels_str=""
	is_fork=$(printf '%s' "$pr_meta_json" \
		| jq -r '.isCrossRepository // false' 2>/dev/null) || is_fork="false"

	local treat_as_external=0
	if [[ ",${labels_str}," == *",external-contributor,"* ]]; then
		treat_as_external=1
	elif [[ "$is_fork" == "true" ]]; then
		treat_as_external=1
		echo "[pulse-merge] DEFENSE-IN-DEPTH: PR #${pr_number} in ${repo_slug} — fork PR missing external-contributor label (label-system race or failure), treating as external (t2934)" >>"$LOGFILE"
	fi

	if [[ "$treat_as_external" -eq 0 ]]; then
		return 0
	fi

	# External / fork PR — require linked issue + crypto approval.
	if ! _external_pr_has_linked_issue "$pr_number" "$repo_slug"; then
		echo "[pulse-merge] DEFENSE-IN-DEPTH: REFUSING --admin merge of PR #${pr_number} in ${repo_slug} — external/fork PR has no linked issue (t2934)" >>"$LOGFILE"
		return 1
	fi
	if ! _external_pr_linked_issue_crypto_approved "$pr_number" "$repo_slug"; then
		local linked
		linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked="unknown"
		echo "[pulse-merge] DEFENSE-IN-DEPTH: REFUSING --admin merge of PR #${pr_number} in ${repo_slug} — external/fork PR linked issue #${linked} lacks crypto approval (t2934)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Check and post permission-failure comment on a PR (t1391)
#
# Companion to check_external_contributor_pr() for the case where the
# collaborator permission API itself fails (403, 429, 5xx, network error).
# Posts a distinct "Permission check failed" comment so a maintainer
# knows to review manually. Idempotent — checks for existing comment
# before posting, fails closed on API errors.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#   $4 - HTTP status code from the failed permission check
#
# Exit codes:
#   0 - comment already exists or was just posted
#   2 - API error checking for existing comment (fail closed, skip)
#######################################
check_permission_failure_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local http_status="${4:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check for existing permission-failure comment (fail closed on API error)
	local perm_comments
	perm_comments=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local perm_exit=$?

	if [[ $perm_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: API error (exit=$perm_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if echo "$perm_comments" | grep -qF 'Permission check failed'; then
		# Already posted — nothing to do
		return 0
	fi

	# Safe to post — no existing comment and API call succeeded
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "Permission check failed for this PR (HTTP ${http_status} from collaborator permission API). Unable to determine if @${pr_author} is a maintainer or external contributor. **A maintainer must review and merge this PR manually.** This is a fail-closed safety measure — the pulse will not auto-merge until the permission API succeeds." || true

	echo "[pulse-wrapper] check_permission_failure_pr: posted permission-failure comment on PR #$pr_number in $repo_slug (HTTP $http_status)" >>"$LOGFILE"
	return 0
}

#######################################
# Auto-approve a collaborator's PR before merging (GH#10522, t1691)
#
# Branch protection requires required_approving_review_count=1.
# The pulse runs with the repo admin's token, which can approve PRs.
# This function approves the PR so that gh pr merge succeeds.
#
# SAFETY: Only call this AFTER the external contributor gate has
# confirmed the PR author is a collaborator (admin/maintain/write).
# NEVER call this for external contributor PRs.
#
# Idempotent — if the PR already has an approving review from the
# current user, this is a no-op (GitHub ignores duplicate approvals).
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login (for logging only)
#
# Exit codes:
#   0 - PR approved (or already approved)
#   1 - approval failed (caller should skip merge this cycle)
#   2 - missing arguments
#######################################
approve_collaborator_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check if we already approved (avoid noisy duplicate approvals in the timeline)
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")

	if [[ -n "$current_user" ]]; then
		# Skip self-approval — GitHub rejects it and the failed review state
		# blocks subsequent --admin merge. Admin bypass works without approval
		# when the PR author is the authenticated user (repo admin).
		if [[ "$current_user" == "$pr_author" ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number is self-authored ($current_user) — skipping approval (--admin handles it)" >>"$LOGFILE"
			return 0
		fi

		# Guard: only collaborators (write/maintain/admin) may approve.
		# Non-collaborator approvals are accepted by GitHub on public repos
		# but don't count toward branch protection — they just create noise.
		if ! _is_collaborator_author "$current_user" "$repo_slug"; then
			echo "[pulse-wrapper] approve_collaborator_pr: current user ($current_user) lacks write access to $repo_slug — skipping approval" >>"$LOGFILE"
			return 0
		fi

		local existing_approval
		existing_approval=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" \
			--jq "[.[] | select(.user.login == \"${current_user}\" and .state == \"APPROVED\")] | length" 2>/dev/null || echo "0")

		if [[ "$existing_approval" -gt 0 ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number in $repo_slug already approved by $current_user — skipping" >>"$LOGFILE"
			return 0
		fi
	fi

	# Defense-in-depth: refuse to approve when the PR author is not a
	# collaborator on this repo. The merge cycle's _check_pr_merge_gates
	# already short-circuits on this condition, but a future
	# refactor could remove that gate. Self-protecting at the function
	# boundary closes the regression window. (GH#17671 post-mortem,
	# t2933.) The misleading "collaborator PR" approval body shipped for
	# years until the surrounding gates landed; a lone caller would
	# re-introduce the supply-chain hole.
	#
	# #aidevops:trust-boundary — t3063 crypto-approval bypass:
	# A verified maintainer signature on the PR or its linked issue is a
	# stronger trust signal than author-association: it requires a
	# root-owned SSH private key that workers cannot forge. This bypass is
	# symmetric with t3052 (PR #21767) which extended the worker-briefed
	# gate the same way. The GH#17671 four-layer defence is preserved —
	# crypto-approval is an additional path through the author gate, not a
	# removal of the gate. Case B (CONTRIBUTOR + no crypto = refuse) is
	# pinned by test-pulse-merge-approve-collaborator-guard.sh Case P.
	local approval_body
	approval_body="Auto-approved by pulse runner @${current_user:-unknown} — author @${pr_author} confirmed collaborator, pre-merge gates passed."
	if [[ -n "$pr_author" ]] && [[ "$pr_author" != "unknown" ]] && ! _is_collaborator_author "$pr_author" "$repo_slug"; then
		if _is_trusted_dependabot_update_pr "$pr_number" "$repo_slug" "$pr_author"; then
			approval_body="Auto-approved by pulse runner @${current_user:-unknown} — trusted Dependabot dependency update verified: GitHub bot identity, same-repo branch, dependabot-authored commits, dependency-file-only diff, maintainer allowlist, no security-scan failures, and pre-merge gates passed."
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number author (@$pr_author) is trusted Dependabot with allowlisted dependency update — proceeding (GH#24473)" >>"$LOGFILE"
		elif _has_maintainer_crypto_approval "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number author (@$pr_author) is not a collaborator on $repo_slug, but maintainer crypto-approval found — proceeding (t3063)" >>"$LOGFILE"
			# fall through to the approval block below
		else
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number author (@$pr_author) is not a collaborator on $repo_slug — refusing to auto-approve (GH#17671 defense-in-depth, t2933)" >>"$LOGFILE"
			return 0
		fi
	fi

	# Approve the PR — body now states the actual checks performed
	# (author confirmed collaborator + pulse runner has write access),
	# not just the misleading "collaborator PR" claim.
	local approve_output
	approve_output=$(gh pr review "$pr_number" --repo "$repo_slug" --approve --body "$approval_body" 2>&1)
	local approve_exit=$?

	if [[ $approve_exit -eq 0 ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: approved PR #$pr_number in $repo_slug (author: $pr_author, runner: ${current_user:-unknown})" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] approve_collaborator_pr: failed to approve PR #$pr_number in $repo_slug — $approve_output" >>"$LOGFILE"
	return 1
}

#######################################
# Check if a PR modifies GitHub Actions workflow files (t3934)
#
# PRs that modify .github/workflows/ files require the `workflow` scope
# on the GitHub OAuth token. Without it, `gh pr merge` fails with:
#   "refusing to allow an OAuth App to create or update workflow ... without workflow scope"
#
# This function checks the PR's changed files for workflow modifications
# so the pulse can skip auto-merge and post a helpful comment instead of
# failing with a cryptic GraphQL error.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - PR modifies workflow files
#   1 - PR does NOT modify workflow files
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_pr_modifies_workflows() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: missing arguments" >>"$LOGFILE"
		return 2
	fi

	local files_output
	files_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path')
	local files_exit=$?

	if [[ $files_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: API error (exit=$files_exit) for PR #$pr_number in $repo_slug — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$files_output" | grep -qE '^\.github/workflows/'; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: PR #$pr_number in $repo_slug modifies workflow files" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# Check if the current GitHub token has the `workflow` scope (t3934)
#
# The `workflow` scope is required to merge PRs that modify
# .github/workflows/ files. This function checks the current
# token's scopes via `gh auth status`.
#
# Exit codes:
#   0 - token HAS workflow scope
#   1 - token does NOT have workflow scope
#   2 - unable to determine (fail open)
#######################################
check_gh_workflow_scope() {
	local auth_output
	auth_output=$(gh auth status 2>&1)
	local auth_exit=$?

	if [[ $auth_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_gh_workflow_scope: gh auth status failed (exit=$auth_exit) — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi

	# Also check for the scope without quotes (format varies by gh version)
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	echo "[pulse-wrapper] check_gh_workflow_scope: token lacks workflow scope" >>"$LOGFILE"
	return 1
}

#######################################
# Guard merge of PRs that modify workflow files (t3934)
#
# Combines check_pr_modifies_workflows() and check_gh_workflow_scope()
# into a single pre-merge guard. If the PR modifies workflow files and
# the token lacks the workflow scope, posts a comment explaining the
# issue and how to fix it. Idempotent — checks for existing comment.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - safe to merge (no workflow files, or token has scope)
#   1 - blocked (workflow files + missing scope, comment posted)
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_workflow_merge_guard() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check if PR modifies workflow files
	check_pr_modifies_workflows "$pr_number" "$repo_slug"
	local wf_exit=$?

	if [[ $wf_exit -eq 1 ]]; then
		# No workflow files modified — safe to merge
		return 0
	fi

	if [[ $wf_exit -eq 2 ]]; then
		# API error — fail open, let merge attempt proceed
		return 2
	fi

	# Step 2: PR modifies workflow files — check token scope
	check_gh_workflow_scope
	local scope_exit=$?

	if [[ $scope_exit -eq 0 ]]; then
		# Token has workflow scope — safe to merge
		return 0
	fi

	if [[ $scope_exit -eq 2 ]]; then
		# Unable to determine — fail open
		return 2
	fi

	# Step 3: PR modifies workflows AND token lacks scope — check for existing comment
	local comments_output
	comments_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comments_exit=$?

	if [[ $comments_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: API error reading comments for PR #$pr_number — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$comments_output" | grep -qF 'workflow scope'; then
		# Already commented — still blocked
		echo "[pulse-wrapper] check_workflow_merge_guard: PR #$pr_number already has workflow scope comment — skipping merge" >>"$LOGFILE"
		return 1
	fi

	# Post comment explaining the issue
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "**Cannot auto-merge: workflow scope required** (GH#3934)

This PR modifies \`.github/workflows/\` files but the GitHub OAuth token used by the pulse lacks the \`workflow\` scope. GitHub requires this scope to merge PRs that modify workflow files.

**To fix:**
1. Run \`gh auth refresh -s workflow\` to add the \`workflow\` scope to your token
2. The next pulse cycle will merge this PR automatically

**Alternatively:** Merge manually via the GitHub UI." ||
		true

	# Add a label for visibility
	gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
		-X POST -f 'labels[]=needs-workflow-scope' || true

	echo "[pulse-wrapper] check_workflow_merge_guard: blocked PR #$pr_number in $repo_slug — workflow files + missing scope" >>"$LOGFILE"
	return 1
}
