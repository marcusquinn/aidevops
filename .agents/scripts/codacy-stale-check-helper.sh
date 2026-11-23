#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# codacy-stale-check-helper.sh - classify a failing Codacy PR check as STALE or REAL (GH#38385).
#
# Codacy's PR aggregation can keep reporting an issue after a later commit removed
# it. The head commit's deltaIssues are authoritative for the head; the PR-level
# issues are stale only when every flagged lineText is absent from the head file.
#
# Usage: codacy-stale-check-helper.sh classify PR_NUMBER --repo OWNER/REPO
# Stdout: "STALE (codacy PR aggregation): <evidence>" and exit 0 when proven stale.
#         "REAL: <reason>" and exit 1 otherwise. Exit 2 when unobservable.
# Fails closed: any missing token, API error, or malformed data is never STALE.
# Test overrides: CODACY_API_BASE, AIDEVOPS_CODACY_FIXTURE_DIR (see tests).

set -euo pipefail

CODACY_API_BASE="${CODACY_API_BASE:-https://app.codacy.com/api/v3}"

_codacy_get() {
	local path="$1"
	curl -fsS --max-time 30 -H "api-token: ${CODACY_API_TOKEN}" -H "Accept: application/json" \
		"${CODACY_API_BASE}${path}"
	return $?
}

# Build the GitHub contents endpoint once for all reads.
_contents_endpoint() {
	local repo="$1" head="$2" file_path="$3"
	printf 'repos/%s/contents/%s?ref=%s' "$repo" "$file_path" "$head"
	return 0
}

# Print the file at the PR head (raw), exit non-zero when unreadable.
_head_file() {
	local repo="$1" head="$2" file_path="$3"
	gh api -H "Accept: application/vnd.github.raw" "$(_contents_endpoint "$repo" "$head" "$file_path")" 2>/dev/null
	return $?
}

# Decide staleness from PR issues JSON + delta JSON. Reads head files via _head_file.
_decide() {
	local repo="$1" head="$2" pr_issues="$3" delta="$4"
	local delta_count=""
	delta_count=$(printf '%s' "$delta" | jq -er 'if .analyzed == true and (.data | type) == "array" then .data | length else error("incomplete") end') || {
		printf 'REAL: deltaIssues response malformed\n'
		return 2
	}
	if [[ "$delta_count" -gt 0 ]]; then
		printf 'REAL: head commit deltaIssues reports %s new issue(s)\n' "$delta_count"
		return 1
	fi
	local entries="" total=0
	entries=$(printf '%s' "$pr_issues" | jq -c '(.data // [])[]
		| {path: (.commitIssue.filePath // .filePath // ""), text: (.commitIssue.lineText // .lineText // "")}') || {
		printf 'REAL: PR issues response malformed\n'
		return 2
	}
	local entry="" path="" text="" content=""
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		total=$((total + 1))
		path=$(printf '%s' "$entry" | jq -r '.path')
		text=$(printf '%s' "$entry" | jq -r '.text')
		# Empty path or text cannot prove absence.
		if [[ -z "$path" || -z "${text//[[:space:]]/}" ]]; then
			printf 'REAL: PR issue lacks file path or line text; cannot prove it is fixed\n'
			return 1
		fi
		if content=$(_head_file "$repo" "$head" "$path"); then
			# Capture grep status (no -q: it must consume all input) to separate match/no match/error.
			local grep_rc=0
			printf '%s\n' "$content" | grep -F -- "$text" >/dev/null || grep_rc=$?
			if [[ "$grep_rc" -eq 0 ]]; then
				printf 'REAL: flagged line still present in %s at head\n' "$path"
				return 1
			elif [[ "$grep_rc" -ne 1 ]]; then
				printf 'REAL: search of %s at head failed\n' "$path"
				return 2
			fi
		else
			# Only a verified 404 proves the file is gone; other failures are unobservable.
			local status_out=""
			status_out=$(gh api -i "$(_contents_endpoint "$repo" "$head" "$path")" 2>&1) || true
			status_out="${status_out%%$'\n'*}"
			if [[ "$status_out" != *" 404"* ]]; then
				printf 'REAL: could not read %s at head\n' "$path"
				return 2
			fi
		fi
		# Verified absent file or absent text => line is gone.
	done <<<"$entries"
	if [[ "$total" -eq 0 ]]; then
		printf 'REAL: no PR-level issues listed; staleness not provable\n'
		return 1
	fi
	printf 'STALE (codacy PR aggregation): head %s deltaIssues=0; %s PR-level issue(s) have lineText absent from head files\n' "${head:0:12}" "$total"
	return 0
}

cmd_classify() {
	local pr_number="${1:-}"
	[[ "$pr_number" =~ ^[0-9]+$ ]] || {
		printf 'classify requires a numeric PR number\n' >&2
		return 2
	}
	shift
	local repo=""
	while [[ $# -gt 0 ]]; do
		local opt="$1" opt_value="${2:-}"
		case "$opt" in
		--repo) repo="$opt_value"; shift 2 ;;
		*) printf 'Unknown option: %s\n' "$opt" >&2; return 2 ;;
		esac
	done
	[[ "$repo" == */* ]] || {
		printf 'classify requires --repo OWNER/REPO\n' >&2
		return 2
	}
	if [[ -z "${CODACY_API_TOKEN:-}" ]]; then
		printf 'REAL: CODACY_API_TOKEN unavailable; cannot verify staleness\n'
		return 2
	fi
	local org="${repo%%/*}" name="${repo##*/}" head="" pr_meta="" analysed="" pr_issues="" delta=""
	head=$(gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null) || {
		printf 'REAL: cannot read PR head\n'
		return 2
	}
	local base="/analysis/organizations/gh/${org}/repositories/${name}"
	pr_meta=$(_codacy_get "${base}/pull-requests/${pr_number}") || {
		printf 'REAL: Codacy PR endpoint unavailable\n'
		return 2
	}
	# Only trust Codacy data analysed at the current head.
	analysed=$(printf '%s' "$pr_meta" | jq -r '[.pullRequest.headCommitSha, .pullRequest.headCommit.sha, .headCommitSha] | map(select(. != null)) | first // ""')
	if [[ -n "$analysed" && "$analysed" != "$head" ]]; then
		printf 'REAL: Codacy analysed %s, not PR head\n' "${analysed:0:12}"
		return 1
	fi
	if [[ "$(printf '%s' "$pr_meta" | jq -r '.isAnalysing // .pullRequest.isAnalysing // false')" == "true" ]]; then
		printf 'REAL: Codacy is still analysing\n'
		return 1
	fi
	pr_issues=$(_codacy_get "${base}/pull-requests/${pr_number}/issues?status=new&limit=100") || {
		printf 'REAL: Codacy PR issues unavailable\n'
		return 2
	}
	# Another page remaining means the first 100 issues cannot prove staleness.
	if printf '%s' "$pr_issues" | jq -e '(.pagination.cursor // "") != ""' >/dev/null 2>&1; then
		printf 'REAL: Codacy PR issues span multiple pages; staleness not provable\n'
		return 2
	fi
	delta=$(_codacy_get "${base}/commits/${head}/deltaIssues?status=new&limit=100") || {
		printf 'REAL: Codacy deltaIssues unavailable\n'
		return 2
	}
	_decide "$repo" "$head" "$pr_issues" "$delta"
	return $?
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	classify) cmd_classify "$@" ;;
	_decide) _decide "$@" ;;
	*) printf 'Usage: codacy-stale-check-helper.sh classify PR_NUMBER --repo OWNER/REPO\n' >&2; return 2 ;;
	esac
	return $?
}

# Allow sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
