#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pr-less-completion-helper.sh — finish an opted-in PR-less task with an exact,
# runtime-verified completion receipt (GH#40048).
#
# Workers used to hand-compose receipt JSON. One wrong field (for example
# "status":"completed" without "verified":true) left a closed issue that the
# runtime rejected as premature_exit/failed, and the ownership fence then
# refused every repair continuation because the issue was closed. This helper
# composes the exact receipt, closes the issue, verifies it with the runtime's
# own predicate and reopens the issue on rejection, so the worker can repair
# while it still owns the task. It grants no publication or approval authority.
#
# Usage:
#   pr-less-completion-helper.sh report-only --repo OWNER/REPO --issue N \
#     --report-file FILE [--workdir DIR]
#   pr-less-completion-helper.sh data-only --repo OWNER/REPO --issue N \
#     --evidence-url HTTPS_URL|self [--summary-file FILE] [--workdir DIR]
#
# `self` binds evidence_url to the receipt comment itself: use it only when an
# authorized publication API printed the per-record outcome table posted there
# and no single user-facing page shows the result.
#
# Stdout: PR_LESS_COMPLETION=verified contract=<c> issue=<n> evidence_url=<url>
#         PR_LESS_COMPLETION=rejected contract=<c> issue=<n> reason=<constant>
# Exit:   0 verified; 1 rejected (issue reopened) or write failure; 2 usage or
#         precondition (nothing written).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# The runtime predicates below are the single source of truth for acceptance.
# shellcheck source=headless-runtime-worker-output.sh
source "${SCRIPT_DIR}/headless-runtime-worker-output.sh"
# shellcheck source=headless-runtime-worker-terminal.sh
source "${SCRIPT_DIR}/headless-runtime-worker-terminal.sh"
# Mirrors headless-runtime-worker.sh: deferred cleanup markers are not task work.
: "${_HRW_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC:=:(top,exclude,literal).agents/.full-loop-cleanup-deferred}"

readonly PLC_REPORT_ONLY="report-only"
readonly PLC_DATA_ONLY="data-only"
# Evidence value that binds evidence_url to the receipt comment's own URL.
readonly PLC_SELF_EVIDENCE="self"
PLC_GH_WRITE="${PLC_GH_WRITE_HELPER:-${SCRIPT_DIR}/gh-write-helper.sh}"
PLC_VERIFY_ATTEMPTS="${PLC_VERIFY_ATTEMPTS:-3}"
PLC_VERIFY_DELAY="${PLC_VERIFY_DELAY:-2}"

_plc_usage() {
	sed -n '15,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

_plc_fail() {
	local code="$1" message="$2"
	printf '[pr-less-completion] %s\n' "$message" >&2
	return "$code"
}

# Args: contract. Stdout: "<opt-in marker>\t<receipt marker>".
_plc_markers() {
	local contract="$1"
	case "$contract" in
	"$PLC_REPORT_ONLY" | "$PLC_DATA_ONLY")
		printf '<!-- aidevops:completion-contract:%s/v1 -->\t<!-- aidevops:%s-completion:v1 -->\n' "$contract" "$contract"
		;;
	*) return 1 ;;
	esac
	return 0
}

# Refuse before any write: open issue, trusted opt-in present, nothing unpublished.
_plc_preflight() {
	local contract="$1" repo="$2" issue="$3" workdir="$4" opt_marker="$5"
	local issue_json=""
	issue_json=$(gh api "repos/${repo}/issues/${issue}") ||
		{ _plc_fail 2 "issue #${issue} in ${repo} is unreadable"; return 2; }
	jq -e '.state == "open" and .pull_request == null' <<<"$issue_json" >/dev/null ||
		{ _plc_fail 2 "issue #${issue} must be an open issue; reopen it before finishing through this helper"; return 2; }
	jq -e --arg m "$opt_marker" '(.body // "") | contains($m)' <<<"$issue_json" >/dev/null ||
		{ _plc_fail 2 "issue #${issue} has no ${contract} opt-in marker; take the PR path"; return 2; }
	if ! _hrw_pr_less_worktree_clean "$workdir" "$repo" >&2; then
		_plc_fail 2 "worktree is not PR-less clean (${_HRW_PR_LESS_REJECTION:-unknown}); publish the work through a PR instead"
		return 2
	fi
	return 0
}

# Post the body through the signed wrapper and print the new comment's id.
# A nonce, not stdout parsing, identifies the comment across REST fallbacks.
_plc_post_comment() {
	local repo="$1" issue="$2" body_file="$3"
	local nonce="" post_file="" viewer="" comment_id=""
	nonce="$(date +%s)-$$-${RANDOM}"
	post_file=$(mktemp) || return 1
	{ cat "$body_file"; printf '\n<!-- aidevops:pr-less-nonce:%s -->\n' "$nonce"; } >"$post_file"
	if ! "$PLC_GH_WRITE" issue comment "$issue" --repo "$repo" --body-file "$post_file" >&2; then
		rm -f "$post_file"
		return 1
	fi
	rm -f "$post_file"
	viewer=$(gh api user --jq .login) || return 1
	comment_id=$(gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100" |
		jq -rs --arg n "aidevops:pr-less-nonce:${nonce} " --arg v "$viewer" \
			'[.[][] | select(.user.login == $v and ((.body // "") | contains($n)))] | last | .id // empty') || return 1
	[[ "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s\n' "$comment_id"
	return 0
}

# Prepend "<marker>\n<receipt JSON>\n\n" to the comment, keeping its signature.
# Args: contract repo issue comment_id receipt_marker evidence_url(self|URL)
# Stdout: the evidence URL bound into the receipt.
_plc_bind_receipt() {
	local contract="$1" repo="$2" issue="$3" comment_id="$4" receipt_marker="$5" evidence="$6"
	local comment_json="" url="" body="" status="" receipt="" edit_file=""
	comment_json=$(gh api "repos/${repo}/issues/comments/${comment_id}") || return 1
	url=$(jq -r '.html_url // empty' <<<"$comment_json")
	body=$(jq -r '.body // ""' <<<"$comment_json")
	[[ "$url" == https://* ]] || return 1
	[[ "$evidence" == "$PLC_SELF_EVIDENCE" ]] && evidence="$url"
	[[ "$evidence" == https://* ]] || return 1
	status="reported"
	[[ "$contract" == "$PLC_DATA_ONLY" ]] && status="published"
	receipt=$(jq -cn --arg repo "$repo" --argjson issue "$issue" --arg status "$status" --arg url "$evidence" \
		'{repository: $repo, issue: $issue, status: $status, verified: true, evidence_url: $url}') || return 1
	edit_file=$(mktemp) || return 1
	printf '%s\n%s\n\n%s\n' "$receipt_marker" "$receipt" "$body" >"$edit_file"
	if ! "$PLC_GH_WRITE" issue comment-edit "$comment_id" --repo "$repo" --body-file "$edit_file" --target "$issue" >&2; then
		rm -f "$edit_file"
		return 1
	fi
	rm -f "$edit_file"
	printf '%s\n' "$evidence"
	return 0
}

# Run the runtime's own acceptance predicate against fresh forge state.
_plc_verify() {
	local contract="$1" repo="$2" issue="$3" workdir="$4"
	local attempt=1 issue_json=""
	while ((attempt <= PLC_VERIFY_ATTEMPTS)); do
		_HRW_PR_LESS_REJECTION="issue_evidence_unavailable"
		_HRW_PR_LESS_OPTED_REJECTION=""
		if issue_json=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null); then
			if [[ "$contract" == "$PLC_REPORT_ONLY" ]]; then
				_hrw_report_only_terminal_complete "issue-${issue}" "$workdir" "$issue" "$repo" "$issue_json" >&2 && return 0
			else
				WORKER_ISSUE_NUMBER="$issue" _hrw_data_only_terminal_complete "issue-${issue}" "$workdir" "$issue" "$repo" "$issue_json" >&2 && return 0
			fi
		fi
		((attempt < PLC_VERIFY_ATTEMPTS)) && sleep "$PLC_VERIFY_DELAY"
		attempt=$((attempt + 1))
	done
	return 1
}

_plc_finish() {
	local contract="$1" repo="$2" issue="$3" workdir="$4" body_file="$5" evidence="$6"
	local markers="" opt_marker="" receipt_marker="" comment_id="" evidence_url="" reason=""
	markers=$(_plc_markers "$contract") || { _plc_fail 2 "unknown contract ${contract}"; return 2; }
	IFS=$'\t' read -r opt_marker receipt_marker <<<"$markers"
	_plc_preflight "$contract" "$repo" "$issue" "$workdir" "$opt_marker" || return 2
	comment_id=$(_plc_post_comment "$repo" "$issue" "$body_file") ||
		{ _plc_fail 1 "could not post the ${contract} comment on #${issue}; nothing was closed"; return 1; }
	evidence_url=$(_plc_bind_receipt "$contract" "$repo" "$issue" "$comment_id" "$receipt_marker" "$evidence") ||
		{ _plc_fail 1 "could not bind the receipt to comment ${comment_id}; nothing was closed"; return 1; }
	gh issue close "$issue" --repo "$repo" --reason completed >&2 ||
		{ _plc_fail 1 "receipt posted but closing #${issue} failed; rerun the close, then verify"; return 1; }
	if _plc_verify "$contract" "$repo" "$issue" "$workdir"; then
		printf 'PR_LESS_COMPLETION=verified contract=%s issue=%s evidence_url=%s\n' "$contract" "$issue" "$evidence_url"
		return 0
	fi
	reason="${_HRW_PR_LESS_OPTED_REJECTION:-${_HRW_PR_LESS_REJECTION:-unknown}}"
	gh issue reopen "$issue" --repo "$repo" >&2 || _plc_fail 0 "reopening #${issue} failed; reopen it before repairing"
	printf 'PR_LESS_COMPLETION=rejected contract=%s issue=%s reason=%s\n' "$contract" "$issue" "$reason"
	return 1
}

main() {
	local contract="${1:-}"
	[[ "$contract" == "$PLC_REPORT_ONLY" || "$contract" == "$PLC_DATA_ONLY" ]] || { _plc_usage >&2; return 2; }
	shift
	local repo="" issue="" body_file="" evidence="" workdir="" generated_body="" rc=0
	while [[ $# -gt 0 ]]; do
		local option="$1" value="${2:-}"
		[[ $# -ge 2 ]] || { _plc_usage >&2; return 2; }
		case "$option" in
		--repo) repo="$value" ;;
		--issue) issue="$value" ;;
		--report-file | --summary-file) body_file="$value" ;;
		--evidence-url) evidence="$value" ;;
		--workdir) workdir="$value" ;;
		*) _plc_usage >&2; return 2 ;;
		esac
		shift 2
	done
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || { _plc_usage >&2; return 2; }
	workdir="${workdir:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
	if [[ "$contract" == "$PLC_REPORT_ONLY" ]]; then
		[[ -n "$body_file" && -s "$body_file" && -z "$evidence" ]] || { _plc_fail 2 "report-only needs a non-empty --report-file and no --evidence-url"; return 2; }
		# A report's evidence is always the URL of the report comment itself.
		evidence="$PLC_SELF_EVIDENCE"
	else
		[[ "$evidence" == "$PLC_SELF_EVIDENCE" || "$evidence" =~ ^https://[^/[:space:]]+/[^[:space:]]+$ ]] ||
			{ _plc_fail 2 "data-only needs --evidence-url with an https URL or self"; return 2; }
		if [[ -z "$body_file" ]]; then
			generated_body=$(mktemp) || return 1
			printf 'Data-only publication verified.\n' >"$generated_body"
			body_file="$generated_body"
		fi
		[[ -s "$body_file" ]] || { _plc_fail 2 "--summary-file is empty"; return 2; }
	fi
	_plc_finish "$contract" "$repo" "$issue" "$workdir" "$body_file" "$evidence" || rc=$?
	[[ -z "$generated_body" ]] || rm -f "$generated_body"
	return "$rc"
}

main "$@"
