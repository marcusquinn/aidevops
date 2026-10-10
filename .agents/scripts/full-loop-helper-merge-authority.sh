#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge Authority -- external/fork merge authority gates
# =============================================================================
# Extracted verbatim from full-loop-helper-merge.sh (GH#30748). Resolves
# needs-maintainer-review holds, cryptographic approvals, trusted issue-sync
# PRs, author write authority and PR label holds, then exposes the common
# final authority guard (_merge_guard_admin_merge_maintainer_review) used by
# every full-loop merge mode before the GitHub merge API is invoked.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge-authority.sh"
#        (sourced by full-loop-helper-merge.sh; do not execute directly)
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning, print_info)
#   - full-loop-helper-merge.sh (_flm_gh_read, _merge_linked_issue_numbers,
#     FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS and _APPROVAL_TARGETS globals)
#   - trusted-dependabot-lib.sh (_is_trusted_dependabot_update_pr)
#   - approval-helper.sh, review-bot-gate-helper.sh (resolved at call time)
#   - Globals: SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_AUTHORITY_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_AUTHORITY_LIB_LOADED=1

_merge_issue_requires_maintainer_review() {
	local issue_number="$1"
	local repo="$2"
	local labels_csv=""
	local labels_padded=""

	labels_csv=$(_flm_gh_read gh issue view "$issue_number" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")') || return 2
	printf -v labels_padded ',%s,' "$labels_csv"
	if [[ "$labels_padded" == *",needs-maintainer-review,"* ]]; then
		return 0
	fi
	return 1
}

# Resolve the verifier from the current framework tree first so worktree fixes
# are exercised before deployment. The public key remains in the user's
# root-protected aidevops approval-key directory and is read by the helper.
_merge_approval_helper_path() {
	local approval_helper="${SCRIPT_DIR}/approval-helper.sh"
	if [[ ! -f "$approval_helper" ]]; then
		approval_helper="${HOME}/.aidevops/agents/scripts/approval-helper.sh"
	fi
	[[ -f "$approval_helper" ]] || return 1
	printf '%s\n' "$approval_helper"
	return 0
}

_merge_target_crypto_approved() {
	local target_type="$1"
	local target_number="$2"
	local repo="$3"
	local expected_head_sha="${4:-}"
	local approval_helper=""
	local result=""

	approval_helper=$(_merge_approval_helper_path) || return 1
	if [[ "$target_type" == "pr" ]]; then
		[[ -n "$expected_head_sha" ]] || return 1
		result=$(bash "$approval_helper" verify pr "$target_number" "$repo" \
			--expect-head "$expected_head_sha" 2>/dev/null) || result=""
	else
		result=$(bash "$approval_helper" verify issue "$target_number" "$repo" 2>/dev/null) || result=""
	fi
	[[ "$result" == "VERIFIED" ]]
	return $?
}

# GH#34052: classify trusted per-task PR-only scope from issue REST JSON.
# Only an OWNER/MEMBER-authored issue body establishes scope; comments and
# contributor-authored bodies never add or remove it, so the original brief
# stays authoritative. A spoofed marker could only add a hold (fail-safe).
# Returns: 0 trusted PR-only scope, 1 absent/untrusted, 2 malformed evidence.
_issue_json_has_trusted_pr_only_contract() {
	local issue_json="$1"
	local marker='<!-- aidevops:completion-contract:pr-only/v1 -->'
	local verdict=""
	#aidevops:trust-boundary GH#34052 -- author association gates the marker.
	verdict=$(printf '%s' "$issue_json" | jq -r --arg marker "$marker" '
		if type != "object" or (.author_association | type) != "string" then "invalid"
		elif (.author_association == "OWNER" or .author_association == "MEMBER")
			and ((.body // "") | type == "string" and contains($marker)) then "trusted"
		else "absent" end' 2>/dev/null) || return 2
	case "$verdict" in
	trusted) return 0 ;;
	absent) return 1 ;;
	*) return 2 ;;
	esac
}

# Returns: 0 trusted PR-only scope, 1 absent/untrusted, 2 lookup failed.
_issue_pr_only_contract_state() {
	local issue_number="$1"
	local repo="$2"
	local issue_json=""
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo" == */* ]] || return 2
	issue_json=$(_flm_gh_read gh api "repos/${repo}/issues/${issue_number}") || return 2
	_issue_json_has_trusted_pr_only_contract "$issue_json"
	return $?
}

# GH#34052: headless workers never hold merge authority for a trusted PR-only
# task, even when the PR lacks its hold label (for example a PR created outside
# commit-and-pr). Interactive maintainers are governed by the live PR
# hold-for-review label instead, which they remove to authorise a merge.
# Checks the dispatched issue plus every linked issue; unknown state fails closed.
_merge_headless_pr_only_scope_clear() {
	local issue_numbers="$1"
	local repo="$2"
	local issue_number="" state_rc=0 candidates=""

	if declare -F detect_session_origin >/dev/null 2>&1; then
		[[ "$(detect_session_origin)" == "worker" ]] || return 0
	elif [[ "${FULL_LOOP_HEADLESS:-}" != "true" && "${AIDEVOPS_HEADLESS:-}" != "true" ]]; then
		return 0
	fi
	candidates=$(printf '%s\n%s\n' "${WORKER_ISSUE_NUMBER:-}" "$issue_numbers" | sort -u)
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		state_rc=0
		_issue_pr_only_contract_state "$issue_number" "$repo" || state_rc=$?
		case "$state_rc" in
		0)
			print_error "Merge blocked: issue #${issue_number} has a trusted PR-only completion contract; stop at the verified ready PR and emit POST_PR_HANDOFF"
			return 1
			;;
		1) ;;
		*)
			print_error "Merge blocked: unable to verify PR-only completion scope for issue #${issue_number}"
			return 1
			;;
		esac
	done <<<"$candidates"
	return 0
}

_merge_is_trusted_issue_sync_pr() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local rbg_helper=""

	[[ -n "$expected_head_sha" ]] || return 1
	rbg_helper=$(_full_loop_review_bot_gate_helper_path) || return 1
	#aidevops:trust-boundary -- bind the exact generated Issue Sync identity to
	# the already verified merge head; helper/API failures remain external.
	bash "$rbg_helper" is-trusted-issue-sync-pr \
		"$pr_number" "$repo" "$expected_head_sha" >/dev/null 2>&1
	return $?
}

# Returns 0 for live admin/maintain/write authority, 1 for a confirmed external
# author, 2 when GitHub cannot provide a trustworthy verdict, or 75 on deferral.
_merge_author_has_write_authority() {
	local author="$1"
	local repo="$2"
	local permission=""
	local AIDEVOPS_GH_READ_TIMEOUT="${AIDEVOPS_GH_READ_TIMEOUT:-60}"
	export AIDEVOPS_GH_READ_TIMEOUT
	local permission_rc=0

	# shared-constants.sh loads the App-aware helper in normal full-loop use. It
	# distinguishes a confirmed 404 non-collaborator (permission=none) from API
	# uncertainty; the direct gh fallback keeps this library sourceable in tests.
	if declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		_merge_with_admission_retry _gh_collaborator_permission_lookup "$repo" "$author" permission || permission_rc=$?
	else
		permission=$(_flm_gh_read gh api "repos/${repo}/collaborators/${author}/permission" \
			--jq '.permission // "none"') || permission_rc=$?
	fi
	[[ "$permission_rc" -ne 75 ]] || return 75
	[[ "$permission_rc" -eq 0 ]] || return 2
	case "$permission" in
	admin | maintain | write) return 0 ;;
	none | read | triage) return 1 ;;
	*) return 2 ;;
	esac
}

_merge_collect_linked_issue_authority_gaps() {
	local issue_numbers="$1"
	local repo="$2"
	local require_crypto="$3"
	local issue_number=""
	local verify_rc=0

	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		verify_rc=0
		_merge_issue_requires_maintainer_review "$issue_number" "$repo" || verify_rc=$?
		if [[ "$verify_rc" -eq 0 ]]; then
			print_error "Merge blocked: linked issue #${issue_number} still requires maintainer review"
			return 1
		elif [[ "$verify_rc" -ne 1 ]]; then
			print_error "Merge blocked: unable to verify maintainer-review labels on issue #${issue_number}"
			return 1
		fi
		if [[ "$require_crypto" -eq 1 ]]; then
			FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS+=("issue:${issue_number}")
			if ! _merge_target_crypto_approved issue "$issue_number" "$repo"; then
				FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS+=("issue:${issue_number}")
			fi
		fi
	done <<<"$issue_numbers"
	return 0
}

# Report a non-verdict author permission lookup: 75 is a deferral, not a denial.
_merge_report_author_lookup_failure() {
	local author_rc="$1"
	local pr_author="$2"

	if [[ "$author_rc" -eq 75 ]]; then
		print_warning "Merge deferred: GitHub permission read admission deferred for PR author ${pr_author}; retry when capacity returns"
	else
		print_error "Merge blocked: unable to verify live repository permission for PR author ${pr_author}"
	fi
	return 0
}

# Live PR labels that hold every merge transport before any trust exception or
# approval target is evaluated. Returns 1 when a hold is present.
_merge_pr_label_holds_clear() {
	local pr_number="$1"
	local labels_padded="$2"
	#aidevops:trust-boundary GH#17671/GH#28622 -- a live PR NMR label is an
	# explicit hold. Marker text is never merge authority at this boundary.
	if [[ "$labels_padded" == *",needs-maintainer-review,"* ]]; then
		print_error "Merge blocked: PR #${pr_number} still requires maintainer review"
		return 1
	fi
	#aidevops:trust-boundary GH#33775 -- a live PR hold-for-review label is an
	# explicit primary-review hold, matching pulse merge (t2411/t2449). It is
	# never resolved by signed approval, so callers must stop before collecting
	# approval targets.
	if [[ "$labels_padded" == *",hold-for-review,"* ]]; then
		print_error "Merge blocked: PR #${pr_number} carries \`hold-for-review\` (maintainer review hold). Remove the label when the hold is resolved."
		return 1
	fi
	return 0
}

_merge_collect_external_authority_gaps() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local pr_json="" pr_author="" current_head_sha="" labels_csv="" labels_padded="" is_fork="false"
	local issue_numbers=""
	local author_rc=0 treat_as_external=0 trusted_dependabot=0 trusted_issue_sync=0

	FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS=()
	FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS=()
	if ! pr_json=$(_flm_gh_read gh pr view "$pr_number" --repo "$repo" \
		--json author,labels,isCrossRepository,headRefOid,closingIssuesReferences,body); then
		print_error "Merge blocked: unable to verify PR #${pr_number} authority metadata"
		return 1
	fi
	if ! printf '%s' "$pr_json" | jq -e '
		def is_string: type == "string";
		type == "object"
		and (.author.login | is_string and length > 0)
		and (.headRefOid | is_string and length > 0)
		and (.labels | type == "array")
		and (.isCrossRepository | type == "boolean")
		and (.closingIssuesReferences | type == "array")
		and ((.body == null) or (.body | is_string))
	' >/dev/null 2>&1; then
		print_error "Merge blocked: PR #${pr_number} returned malformed authority metadata"
		return 1
	fi

	pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login') || return 1
	current_head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid') || return 1
	labels_csv=$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")') || return 1
	printf -v labels_padded ',%s,' "$labels_csv"
	is_fork=$(printf '%s' "$pr_json" | jq -r '.isCrossRepository') || return 1
	if [[ -n "$expected_head_sha" && "$current_head_sha" != "$expected_head_sha" ]]; then
		print_error "Merge blocked: PR #${pr_number} head changed before the final authority check"
		return 1
	fi
	# GH#33374: a native sidebar/development closing link must not override a
	# For/Ref checkpoint. Fail closed before any merge write; do not silently
	# unlink issues or infer completion from GitHub's closing metadata alone.
	if ! printf '%s' "$pr_json" | jq -e '
		(.body // "") as $body
		| all(.closingIssuesReferences[]; .number as $num
			| if ($body | test("\\b(for|ref)[[:space:]]+#" + ($num | tostring) + "\\b"; "i"))
			then ($body | test("\\b(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#" + ($num | tostring) + "\\b"; "i"))
			else true end)' >/dev/null 2>&1; then
		print_error "Merge blocked: PR #${pr_number} has a closing link contradicting its For/Ref-only issue reference"
		return 1
	fi

	_merge_pr_label_holds_clear "$pr_number" "$labels_padded" || return 1

	#aidevops:trust-boundary -- repository-generated Issue Sync and Dependabot
	# PRs may lack collaborator permission. Both narrow predicates bind immutable
	# bot identity and repository ownership to the exact current head. Live PR and
	# linked-issue NMR labels remain unconditional holds.
	if [[ "$pr_author" == "app/github-actions" || "$pr_author" == "github-actions[bot]" ]] &&
		_merge_is_trusted_issue_sync_pr "$pr_number" "$repo" "$current_head_sha"; then
		trusted_issue_sync=1
	elif _is_trusted_dependabot_update_pr "$pr_number" "$repo" "$pr_author" "$current_head_sha"; then
		trusted_dependabot=1
	else
		_merge_author_has_write_authority "$pr_author" "$repo" || author_rc=$?
		if [[ "$author_rc" -eq 75 || "$author_rc" -eq 2 ]]; then
			_merge_report_author_lookup_failure "$author_rc" "$pr_author"
			return 1
		fi
		if [[ "$labels_padded" == *",external-contributor,"* ]] ||
			[[ "$is_fork" == "true" ]] || [[ "$author_rc" -ne 0 ]]; then
			treat_as_external=1
		fi
	fi

	issue_numbers=$(_merge_linked_issue_numbers "$pr_number" "$repo" "$pr_json") || {
		print_error "Merge blocked: unable to verify linked issues for PR #${pr_number}"
		return 1
	}

	_merge_headless_pr_only_scope_clear "$issue_numbers" "$repo" || return 1
	_merge_collect_linked_issue_authority_gaps "$issue_numbers" "$repo" "$treat_as_external" || return 1
	if [[ "$trusted_dependabot" -eq 1 || "$trusted_issue_sync" -eq 1 || "$treat_as_external" -eq 0 ]]; then
		return 0
	fi
	if [[ -z "$issue_numbers" ]]; then
		print_error "Merge blocked: external/fork PR #${pr_number} has no linked issue"
		return 1
	fi
	FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS+=("pr:${pr_number}")
	if ! _merge_target_crypto_approved pr "$pr_number" "$repo" "$current_head_sha"; then
		FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS+=("pr:${pr_number}")
	fi

	return 0
}

# Legacy name retained for sourced callers and tests. This is now the common
# final authority guard for every full-loop merge mode, not only --admin.
_merge_linked_issue_authority_clear() {
	local issue_numbers="$1"
	local repo="$2"
	local require_crypto="$3"
	local target=""

	FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS=()
	FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS=()
	_merge_collect_linked_issue_authority_gaps "$issue_numbers" "$repo" "$require_crypto" || return 1
	for target in "${FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS[@]}"; do
		print_error "Merge blocked: external/fork PR linked issue #${target#issue:} lacks current cryptographic development authority"
		return 1
	done
	return 0
}

# Legacy name retained for sourced callers and tests. This is now the common
# final authority guard for every full-loop merge mode, not only --admin.
_merge_guard_admin_merge_maintainer_review() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local target=""

	_merge_collect_external_authority_gaps "$pr_number" "$repo" "$expected_head_sha" || return 1
	for target in "${FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS[@]}"; do
		case "$target" in
		issue:*)
			print_error "Merge blocked: external/fork PR linked issue #${target#issue:} lacks current cryptographic development authority"
			;;
		pr:*)
			print_error "Merge blocked: external/fork PR #${target#pr:} lacks V2 merge authority for the current head"
			;;
		esac
		return 1
	done

	return 0
}

