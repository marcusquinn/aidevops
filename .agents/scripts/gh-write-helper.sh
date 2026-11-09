#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
trap '_run_cleanups' EXIT
trap '_run_cleanups; exit 130' HUP INT TERM

usage() {
	printf 'Usage: gh-write-helper.sh {issue|pr} create [gh create options]\n'
	printf '       gh-write-helper.sh {issue|pr} edit <number-or-url> [gh edit options]\n'
	printf '       gh-write-helper.sh {issue|pr} comment <number-or-url> [gh comment options]\n'
	printf '         (--edit-last/--delete-last/--create-if-none are refused; use comment-edit)\n'
	printf '       gh-write-helper.sh {issue|pr} comment-edit <comment-id> --repo <owner/repo> --body-file <file> [--target <number>]\n'
	printf '       gh-write-helper.sh issue review-handoff <number> --repo <owner/repo> --pr <number>\n'
	printf '       gh-write-helper.sh issue status <number> --repo <owner/repo> <status>\n'
	printf '         (status: available|queued|claimed|in-progress|in-review|done|blocked)\n'
	printf '       gh-write-helper.sh batch MANIFEST.json\n'
	printf 'Bodies may use --body-file - to read stdin once through the safe wrapper.\n'
	return 0
}

# Explicit, owned PR handoff; generic issue edits never acquire this provenance.
_issue_review_handoff() {
	local number="${1:-}"
	local repo="" pr="" issue_json="" status=""
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
	shift
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo) repo="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--pr) pr="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		*) return 2 ;;
		esac
	done
	_gh_verify_owned_review_handoff_pr "$repo" "$number" "$pr" || return $?
	issue_json=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || {
		_gh_review_handoff_failure api-unavailable; return 3
	}
	status=$(printf '%s\n' "$issue_json" | jq -er '
		if (.state | type) != "string" or (.labels | type) != "array" then "api-unavailable"
		elif .state != "open" then "issue-not-open"
		elif .pull_request != null then "issue-is-pr"
		elif ([.labels[]?.name] | index("status:in-review")) != null then "already-in-review"
		elif ([.labels[]?.name] | index("status:in-progress")) != null then "in-progress"
		else "issue-not-in-progress" end
	' 2>/dev/null) || status="api-unavailable"
	if [[ "$status" == already-in-review ]]; then
		# No write means no audit event or exemption is acquired.
		printf 'REVIEW_HANDOFF=already-in-review\n'
		return 0
	fi
	[[ "$status" == in-progress ]] || { _gh_review_handoff_failure "$status"; return 3; }
	# Dynamically scoped PR identifier is only a hint; the audit rechecks GitHub.
	local _GH_REVIEW_HANDOFF_PR="$pr"
	gh_issue_edit_safe "$number" --repo "$repo" \
		--remove-label status:in-progress --add-label status:in-review || return 1
	return 0
}

# GH#34846: policy-compatible CLI for set_issue_status, the sanctioned status
# transition (exactly one core status label). Workers still may not change
# their own dispatched issue's lifecycle: the runtime projects it.
_issue_status() {
	local number="${1:-}"
	local repo="" status=""
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
	shift
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo) repo="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--repo=*) repo="${option#--repo=}"; shift ;;
		-*) return 2 ;;
		*) [[ -z "$status" ]] || return 2; status="${option#status:}"; shift ;;
		esac
	done
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && -n "$status" ]] || return 2
	if [[ -n "${WORKER_ISSUE_NUMBER:-}" && "$number" == "$WORKER_ISSUE_NUMBER" ]]; then
		# shellcheck disable=SC2016 # Literal worker signal, not shell code.
		printf 'emit `BLOCKED: <reason>`; the runtime projects lifecycle state\n' >&2
		return 2
	fi
	set_issue_status "$number" "$repo" "$status" || return $?
	return 0
}

# Apply the same signing path as issue creation before the safe edit wrapper.
# Normalize stdin first so signing never consumes it independently of validation.
_issue_edit_signed() {
	_gh_wrapper_enter_cleanup_scope
	_gh_wrapper_normalize_stdin_body_file "$@" || return 1
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	# Signing must not turn an empty/stub body into substantive edit content.
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	gh_issue_edit_safe "$@"
	return $?
}

# GH#37406: edit exactly one comment by ID. Refuses comments not authored by
# the authenticated user or, with --target, not on that issue/PR; then applies
# the same signature and privacy guards as comment creation.
_comment_edit_usage() {
	printf 'Usage: gh-write-helper.sh {issue|pr} comment-edit <comment-id> --repo <owner/repo> --body-file <file> [--target <number>]\n' >&2
	return 2
}

_comment_edit() {
	local comment_id="${1:-}"
	local repo="" target="" body_file=""
	[[ "$comment_id" =~ ^[1-9][0-9]*$ ]] || { _comment_edit_usage; return 2; }
	shift
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo | -R) repo="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--repo=*) repo="${option#--repo=}"; shift ;;
		--target) target="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--target=*) target="${option#--target=}"; shift ;;
		--body-file) body_file="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--body-file=*) body_file="${option#--body-file=}"; shift ;;
		*) _comment_edit_usage; return 2 ;;
		esac
	done
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || -z "$body_file" ]] ||
		[[ -n "$target" && ! "$target" =~ ^[1-9][0-9]*$ ]]; then
		_comment_edit_usage
		return 2
	fi

	local endpoint="repos/${repo}/issues/comments/${comment_id}"
	local meta="" author="" parent="" viewer="" read_rc=0
	meta=$(gh api "$endpoint" --jq '[.user.login, (.issue_url | split("/") | last)] | @tsv') || read_rc=$?
	if [[ "$read_rc" -eq 75 ]]; then
		printf 'comment %s not checked: GitHub read deferred by rate pacing; retry later\n' "$comment_id" >&2
		return 75
	elif [[ "$read_rc" -ne 0 ]]; then
		printf 'comment %s not found or unreadable in %s\n' "$comment_id" "$repo" >&2
		return 1
	fi
	IFS=$'\t' read -r author parent <<<"$meta"
	viewer=$(gh api user --jq .login) || return 1
	if [[ -z "$author" || "$author" != "$viewer" ]]; then
		printf 'refusing to edit comment %s: author %s is not %s\n' "$comment_id" "${author:-unknown}" "$viewer" >&2
		return 1
	fi
	if [[ -n "$target" && "$parent" != "$target" ]]; then
		printf 'refusing to edit comment %s: it belongs to #%s, not #%s\n' "$comment_id" "$parent" "$target" >&2
		return 1
	fi

	_gh_wrapper_enter_cleanup_scope
	_gh_wrapper_normalize_stdin_body_file --repo "$repo" --body-file "$body_file" || return 1
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	_gh_validate_edit_args "$@" || return 1
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	_gh_guard_public_write_args "$@" || return 1
	local signed_file="${4:-}"
	[[ "${3:-}" == "--body-file" && -f "$signed_file" ]] || return 1
	_gh_with_timeout write gh api -X PATCH "$endpoint" -F "body=@${signed_file}" --jq .html_url || return 1
	return 0
}

main() {
	local resource="${1:-}"
	local action="${2:-}"
	# Dynamically scoped for shared validation diagnostics, not exported to children.
	local _GH_WRITE_OPERATION="${resource} ${action}"
	if [[ "$resource" == "help" || "$resource" == "--help" || "$resource" == "-h" ]]; then
		usage
		return 0
	fi
	if [[ "$resource" == "batch" ]]; then
		shift
		gh_write_batch "$@"
		return $?
	fi
	if [[ "$action" != "create" && "$action" != "edit" && "$action" != "comment" &&
		"$action" != "comment-edit" && "$action" != "review-handoff" && "$action" != "status" ]]; then
		usage >&2
		return 2
	fi
	shift 2
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
			usage
			return 0
		fi
	done
	case "${resource}:${action}" in
	issue:create) gh_create_issue "$@" ;;
	issue:edit)
		local edit_target="" skip_value=0 target_arg=""
		for target_arg in "$@"; do
			if [[ "$skip_value" == 1 ]]; then
				skip_value=0
				continue
			fi
			case "$target_arg" in
			--*=* | --) continue ;;
			-*) skip_value=1 ;;
			*) edit_target="${target_arg##*/issues/}"; break ;;
			esac
		done
		if [[ -n "${WORKER_ISSUE_NUMBER:-}" && "$edit_target" == "$WORKER_ISSUE_NUMBER" ]]; then
			local label_arg="" label_value="" previous=""
			for label_arg in "$@"; do
				label_value=""
				case "$label_arg" in
				--add-label=* | --remove-label=*) label_value="${label_arg#*=}" ;;
				*)
					if [[ "$previous" == --add-label || "$previous" == --remove-label ]]; then
						label_value="$label_arg"
					fi
					;;
				esac
				if [[ ",$label_value" =~ ,[[:space:]]*status: ]]; then
					# shellcheck disable=SC2016 # Literal worker signal, not shell code.
					printf 'emit `BLOCKED: <reason>`; the runtime projects lifecycle state\n' >&2
					return 2
				fi
				previous="$label_arg"
			done
		fi
		_issue_edit_signed "$@"
		;;
	issue:review-handoff) _issue_review_handoff "$@" ;;
	issue:status) _issue_status "$@" ;;
	issue:comment) gh_issue_comment "$@" ;;
	issue:comment-edit | pr:comment-edit) _comment_edit "$@" ;;
	pr:create) gh_create_pr "$@" ;;
	pr:edit) gh_pr_edit_safe "$@" ;;
	pr:comment) gh_pr_comment "$@" ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

# Keep failures inside an explicit status check so captured transport stderr is
# replayed before errexit can terminate the CLI. Preserve the original status.
main "$@" || {
	rc=$?
	if [[ "${1:-}:${2:-}" == issue:review-handoff && "$rc" == 3 ]]; then
		printf '[aidevops][gh-write-helper][ERROR] Review handoff precondition failed (exit 3).\n' >&2
	else
		printf '[aidevops][gh-write-helper][ERROR] GitHub write failed (exit %s).\n' "$rc" >&2
	fi
	exit "$rc"
}
