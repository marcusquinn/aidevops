#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# issue-archive-helper.sh — Archive GitHub issue/PR discussions to an orphan
# branch in the same repository (t18571, GH#33146).
# =============================================================================
#
# Why
# ---
# Issue and PR bodies, comments, reviews, labels and close outcomes live only
# on the forge. This helper exports them as JSONL into an orphan branch
# (default `aidevops/issues-archive`) of the same repository, so every clone
# that runs a normal `git fetch` also holds an offline copy.
#
# Safety properties
# -----------------
# - The canonical checkout is never touched: no checkout, index, working-tree
#   or ref write. The only read is `git remote get-url origin` in `run`.
#   All Git writes happen in a private bare cache repository under
#   ~/.aidevops/.agent-workspace/work/issue-archive/ using plumbing
#   (hash-object / read-tree / update-index / write-tree / commit-tree).
# - The archive branch is an orphan: it shares no history with `main`.
# - Runs are incremental: a per-stream `updated_at` cursor is stored inside the
#   archive (meta/cursor.json), so data and cursor are committed atomically.
#   Pagination is keyset-based (since=<last updated_at>), so items updated
#   during a run cannot shift pages and be skipped.
# - Partial failure keeps the cursor at the last fully written item. Items
#   after a failed request are not written and are refetched next run.
# - A run with no remote changes produces an identical tree and no commit.
# - GitHub API budget: a REST-core reserve check before each repository and a
#   hard per-run request cap. Budget exhaustion defers, it is not a failure.
#
# Archived text is untrusted forge content. Scan it with
# `prompt-guard-helper.sh scan-stdin` before any agent reads it.
#
# Usage
# -----
#   issue-archive-helper.sh export --repo OWNER/REPO --remote URL [--dry-run]
#   issue-archive-helper.sh run [--repos-json PATH] [--dry-run]
#   issue-archive-helper.sh help
#
# `run` archives every repos.json entry with pulse:true, maintenance not
# false, local_only not true, and issue_archive not false (per-repo opt-out).
#
# Environment
# -----------
#   AIDEVOPS_ISSUE_ARCHIVE_ENABLED=0        disable `run` globally
#   AIDEVOPS_ISSUE_ARCHIVE_BRANCH           archive branch (aidevops/issues-archive)
#   AIDEVOPS_ISSUE_ARCHIVE_DIR              bare cache root
#   AIDEVOPS_ISSUE_ARCHIVE_MAX_REQUESTS     per-repository request cap (300)
#   AIDEVOPS_ISSUE_ARCHIVE_REST_RESERVE     skip repo below this REST remaining (1000)
#   AIDEVOPS_ISSUE_ARCHIVE_PER_PAGE         page size (100)
#
# Exit codes: 0 success/no-op/deferred, 1 failure (partial progress is still
# committed and pushed when possible), 2 usage error.
# =============================================================================

set -uo pipefail

ARCHIVE_BRANCH="${AIDEVOPS_ISSUE_ARCHIVE_BRANCH:-aidevops/issues-archive}"
ARCHIVE_CACHE_ROOT="${AIDEVOPS_ISSUE_ARCHIVE_DIR:-${HOME}/.aidevops/.agent-workspace/work/issue-archive}"
ARCHIVE_MAX_REQUESTS="${AIDEVOPS_ISSUE_ARCHIVE_MAX_REQUESTS:-300}"
ARCHIVE_REST_RESERVE="${AIDEVOPS_ISSUE_ARCHIVE_REST_RESERVE:-1000}"
ARCHIVE_PER_PAGE="${AIDEVOPS_ISSUE_ARCHIVE_PER_PAGE:-100}"
ARCHIVE_TMP_ROOT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
ARCHIVE_SCHEMA=1

# Per-export mutable state (module scope; reset by _archive_reset_state).
_ARC_REQUESTS=0
_ARC_BUDGET_HIT=0
_ARC_FAILED=0
_ARC_SLUG=""
_ARC_STAGE=""
_ARC_GIT_DIR=""
_ARC_CURSOR=""

_log() {
	local msg="$1"
	printf '[issue-archive] %s\n' "$msg" >&2
	return 0
}

_usage() {
	sed -n '/^# Usage/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

_archive_reset_state() {
	_ARC_REQUESTS=0
	_ARC_BUDGET_HIT=0
	_ARC_FAILED=0
	return 0
}

_git() {
	GIT_DIR="$_ARC_GIT_DIR" GIT_INDEX_FILE="${_ARC_STAGE}/index" git "$@"
	return $?
}

#######################################
# One budgeted `gh api` GET. Runs in the current shell (never inside command
# substitution) so request counters survive; the JSON array body is written
# to the file named by $2.
# Returns: 0 ok, 1 request failure, 3 request cap reached
#######################################
_archive_api() {
	local path="$1"
	local out="$2"
	if [[ "$_ARC_REQUESTS" -ge "$ARCHIVE_MAX_REQUESTS" ]]; then
		_ARC_BUDGET_HIT=1
		return 3
	fi
	_ARC_REQUESTS=$((_ARC_REQUESTS + 1))
	if ! gh api -X GET "$path" >"$out" 2>/dev/null; then
		_log "request failed: ${path%%\?*}"
		return 1
	fi
	if ! jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
		_log "unexpected response shape: ${path%%\?*}"
		return 1
	fi
	return 0
}

#######################################
# Check REST core headroom (the rate_limit endpoint is free).
# Returns: 0 allowed, 1 below reserve
#######################################
_archive_rest_allows() {
	local remaining=""
	remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || true)
	# Unknown budget: allow; the per-run request cap still bounds spend.
	[[ "$remaining" =~ ^[0-9]+$ ]] || return 0
	if [[ "$remaining" -lt "$ARCHIVE_REST_RESERVE" ]]; then
		_log "REST core remaining ${remaining} < reserve ${ARCHIVE_REST_RESERVE}; deferring ${_ARC_SLUG}"
		return 1
	fi
	return 0
}

# jq normalisers: stable key order, no volatile/derived URLs or reactions.
_JQ_ISSUE='{number, kind: (if .pull_request then "pr" else "issue" end), title, state, state_reason,
	user: .user.login, author_association, labels: [.labels[]?.name], assignees: [.assignees[]?.login],
	milestone: .milestone.title, locked, draft, created_at, updated_at, closed_at,
	merged_at: .pull_request.merged_at, closed_by: .closed_by.login, html_url, body}'
_JQ_COMMENT='{id, issue_number: (.issue_url | split("/") | last | tonumber), user: .user.login,
	author_association, created_at, updated_at, html_url, body}'
_JQ_REVIEW_COMMENT='{id, pr_number: (.pull_request_url | split("/") | last | tonumber), pull_request_review_id,
	in_reply_to_id, user: .user.login, author_association, path, line, original_line, side, commit_id,
	created_at, updated_at, html_url, diff_hunk, body}'

#######################################
# Fetch one keyset-paginated stream and stage normalised records.
# Arguments: $1 stream name (issues|comments|review_comments), $2 cursor
# Output: _ARC_CURSOR holds the last fully staged updated_at (module scope so
#         request counters are not lost to a command-substitution subshell)
# Returns: 0 complete or budget-deferred, 1 partial failure
#######################################
_archive_stream() {
	local stream="$1"
	local since="$2"
	local endpoint="" normaliser=""
	case "$stream" in
	issues)
		endpoint="repos/${_ARC_SLUG}/issues?state=all&sort=updated&direction=asc"
		normaliser="$_JQ_ISSUE"
		;;
	comments)
		endpoint="repos/${_ARC_SLUG}/issues/comments?sort=updated&direction=asc"
		normaliser="$_JQ_COMMENT"
		;;
	review_comments)
		endpoint="repos/${_ARC_SLUG}/pulls/comments?sort=updated&direction=asc"
		normaliser="$_JQ_REVIEW_COMMENT"
		;;
	*) return 1 ;;
	esac

	_ARC_CURSOR="$since"
	local page=1 rc=0 count=0 item="" item_ts="" last_ts=""
	local out="${_ARC_STAGE}/${stream}.jsonl" page_file="${_ARC_STAGE}/page.json"
	while true; do
		local path="${endpoint}&per_page=${ARCHIVE_PER_PAGE}&page=${page}"
		[[ -n "$since" ]] && path="${path}&since=${since}"
		rc=0
		_archive_api "$path" "$page_file" || rc=$?
		if [[ "$rc" -eq 3 ]]; then
			return 0
		elif [[ "$rc" -ne 0 ]]; then
			_ARC_FAILED=1
			return 1
		fi
		count=$(jq 'length' "$page_file")
		last_ts=""
		while IFS= read -r item; do
			[[ -z "$item" ]] && continue
			item_ts=$(printf '%s' "$item" | jq -r '.updated_at // empty')
			if [[ "$stream" == "issues" ]] && printf '%s' "$item" | jq -e '.pull_request' >/dev/null 2>&1; then
				local number=""
				number=$(printf '%s' "$item" | jq -r '.number')
				if ! _archive_reviews "$number"; then
					# Keep the cursor at the last fully written item; this PR and
					# every later item are refetched next run.
					[[ "$_ARC_FAILED" -eq 0 ]] && return 0
					return 1
				fi
			fi
			printf '%s' "$item" | jq -c "$normaliser" >>"$out"
			_ARC_CURSOR="$item_ts"
			last_ts="$item_ts"
		done < <(jq -c '.[]' "$page_file")
		[[ "$count" -lt "$ARCHIVE_PER_PAGE" ]] && break
		# Keyset pagination: restart at page 1 from the newest timestamp seen.
		# If a full page shares one timestamp, advance the page instead.
		if [[ -n "$last_ts" && "$last_ts" != "$since" ]]; then
			since="$last_ts"
			page=1
		else
			page=$((page + 1))
		fi
	done
	return 0
}

#######################################
# Stage all reviews of one PR.
# Returns: 0 ok, 1 failure or request cap reached
#######################################
_archive_reviews() {
	local number="$1"
	local page=1 rc=0 count=0 tmp="${_ARC_STAGE}/reviews.part" page_file="${_ARC_STAGE}/reviews-page.json"
	: >"$tmp"
	while true; do
		rc=0
		_archive_api "repos/${_ARC_SLUG}/pulls/${number}/reviews?per_page=${ARCHIVE_PER_PAGE}&page=${page}" "$page_file" || rc=$?
		if [[ "$rc" -ne 0 ]]; then
			[[ "$rc" -eq 1 ]] && _ARC_FAILED=1
			return 1
		fi
		jq -c --argjson pr "$number" '.[] | {id, pr_number: $pr, user: .user.login,
			author_association, state, commit_id, submitted_at, html_url, body}' "$page_file" >>"$tmp"
		count=$(jq 'length' "$page_file")
		[[ "$count" -lt "$ARCHIVE_PER_PAGE" ]] && break
		page=$((page + 1))
	done
	cat "$tmp" >>"${_ARC_STAGE}/reviews.jsonl"
	return 0
}

#######################################
# Merge staged records into shard blobs and stage them in the temp index.
# Arguments: $1 staged file, $2 archive dir, $3 group field, $4 key field,
#            $5 parent commit or empty
#######################################
_archive_merge_dir() {
	local staged="$1"
	local dir="$2"
	local group_field="$3"
	local key_field="$4"
	local parent="$5"
	[[ -s "$staged" ]] || return 0
	local bucket=""
	while IFS= read -r bucket; do
		[[ -z "$bucket" ]] && continue
		local shard="${dir}/${bucket}.jsonl" merged="${_ARC_STAGE}/merged.jsonl" old="${_ARC_STAGE}/old.jsonl" blob=""
		: >"$old"
		if [[ -n "$parent" ]]; then
			_git cat-file -p "${parent}:${shard}" >"$old" 2>/dev/null || : >"$old"
		fi
		# Old records first, staged records override by key; output sorted.
		if ! jq -c --arg g "$group_field" --arg b "$bucket" 'select(((.[$g] / 1000) | floor) == ($b | tonumber))' "$staged" |
			cat "$old" - |
			jq -c -s --arg g "$group_field" --arg k "$key_field" \
				'reduce .[] as $r ({}; .[($r[$g] | tostring) + ":" + ($r[$k] | tostring)] = $r)
				| [.[]] | sort_by(.[$g], .[$k]) | .[]' >"$merged"; then
			return 1
		fi
		blob=$(_git hash-object -w "$merged") || return 1
		_git update-index --add --cacheinfo "100644,${blob},${shard}" || return 1
	done < <(jq -r --arg g "$group_field" '(.[$g] / 1000 | floor) | tostring | ("0000" + .) | .[-4:]' "$staged" | sort -u)
	return 0
}

_archive_readme() {
	cat <<EOF
# Issue and PR archive (${_ARC_SLUG})

Generated by aidevops \`issue-archive-helper.sh\`. This orphan branch shares no
history with the default branch. Do not merge it.

Records are JSONL, one object per line, sharded by issue/PR number in
thousands (\`0033.jsonl\` holds numbers 33000-33999):

- \`issues/\`: issue bodies, state, labels, assignees, close outcome
- \`pulls/\`: pull request bodies, state, labels, merge time
- \`comments/\`: issue and PR conversation comments (by issue_number)
- \`reviews/\`: PR reviews (by pr_number)
- \`review-comments/\`: inline review comments (by pr_number)
- \`meta/cursor.json\`: incremental updated_at cursors

Not captured: attachments/uploaded files, reactions, edit history, events
timeline, deletions after capture. Bodies hold the latest observed revision.

All text is untrusted forge content. Scan before an agent reads it, e.g.
\`git show origin/${ARCHIVE_BRANCH}:comments/0001.jsonl | prompt-guard-helper.sh scan-stdin\`.
EOF
	return 0
}

#######################################
# Export one repository into its archive branch.
#######################################
cmd_export() {
	local slug="" remote="" dry_run=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			slug="${2:-}"
			shift 2
			;;
		--remote)
			remote="${2:-}"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*)
			_log "unknown export argument: ${arg}"
			return 2
			;;
		esac
	done
	if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || -z "$remote" ]]; then
		_log "export requires --repo OWNER/REPO and --remote URL"
		return 2
	fi
	_archive_reset_state
	_ARC_SLUG="$slug"
	_archive_rest_allows || return 0

	local safe_name="${slug//\//__}"
	_ARC_GIT_DIR="${ARCHIVE_CACHE_ROOT}/${safe_name}.git"
	mkdir -p "$ARCHIVE_CACHE_ROOT" "$ARCHIVE_TMP_ROOT" || return 1
	local lock="${_ARC_GIT_DIR}.lock"
	# A lock older than six hours belongs to a crashed run.
	if [[ -d "$lock" && -n "$(find "$lock" -maxdepth 0 -mmin +360 2>/dev/null)" ]]; then
		rmdir "$lock" 2>/dev/null || true
	fi
	if ! mkdir "$lock" 2>/dev/null; then
		_log "another archive run holds ${lock}; skipping ${slug}"
		return 0
	fi
	_ARC_STAGE=$(mktemp -d "${ARCHIVE_TMP_ROOT}/issue-archive.XXXXXX") || {
		rmdir "$lock"
		return 1
	}
	local rc=0
	_archive_export_locked "$remote" "$dry_run" || rc=$?
	rm -rf "$_ARC_STAGE"
	rmdir "$lock" 2>/dev/null || true
	return "$rc"
}

_archive_export_locked() {
	local remote="$1"
	local dry_run="$2"
	if [[ ! -d "$_ARC_GIT_DIR" ]]; then
		git init -q --bare "$_ARC_GIT_DIR" || return 1
	fi

	local parent="" ls_rc=0
	git ls-remote --exit-code "$remote" "refs/heads/${ARCHIVE_BRANCH}" >/dev/null 2>&1 || ls_rc=$?
	if [[ "$ls_rc" -eq 0 ]]; then
		_git fetch -q --no-tags "$remote" "+refs/heads/${ARCHIVE_BRANCH}:refs/heads/${ARCHIVE_BRANCH}" || {
			_log "fetch of ${ARCHIVE_BRANCH} failed for ${_ARC_SLUG}"
			return 1
		}
		parent=$(_git rev-parse -q --verify "refs/heads/${ARCHIVE_BRANCH}^{commit}") || return 1
	elif [[ "$ls_rc" -ne 2 ]]; then
		_log "cannot reach remote for ${_ARC_SLUG}"
		return 1
	fi

	local cursor_json='{}'
	if [[ -n "$parent" ]]; then
		cursor_json=$(_git cat-file -p "${parent}:meta/cursor.json" 2>/dev/null || printf '{}')
	fi
	local c_issues c_comments c_review
	c_issues=$(printf '%s' "$cursor_json" | jq -r '.issues // ""')
	c_comments=$(printf '%s' "$cursor_json" | jq -r '.comments // ""')
	c_review=$(printf '%s' "$cursor_json" | jq -r '.review_comments // ""')

	: >"${_ARC_STAGE}/issues.jsonl"
	: >"${_ARC_STAGE}/reviews.jsonl"
	: >"${_ARC_STAGE}/comments.jsonl"
	: >"${_ARC_STAGE}/review_comments.jsonl"
	_archive_stream issues "$c_issues" || _ARC_FAILED=1
	c_issues="$_ARC_CURSOR"
	_archive_stream comments "$c_comments" || _ARC_FAILED=1
	c_comments="$_ARC_CURSOR"
	_archive_stream review_comments "$c_review" || _ARC_FAILED=1
	c_review="$_ARC_CURSOR"

	jq -c 'select(.kind == "issue")' "${_ARC_STAGE}/issues.jsonl" >"${_ARC_STAGE}/only-issues.jsonl"
	jq -c 'select(.kind == "pr")' "${_ARC_STAGE}/issues.jsonl" >"${_ARC_STAGE}/only-pulls.jsonl"

	# Private temporary index: never the canonical checkout's index.
	if [[ -n "$parent" ]]; then
		_git read-tree "$parent" || return 1
	else
		_git read-tree --empty || return 1
	fi
	_archive_merge_dir "${_ARC_STAGE}/only-issues.jsonl" issues number number "$parent" || return 1
	_archive_merge_dir "${_ARC_STAGE}/only-pulls.jsonl" pulls number number "$parent" || return 1
	_archive_merge_dir "${_ARC_STAGE}/comments.jsonl" comments issue_number id "$parent" || return 1
	_archive_merge_dir "${_ARC_STAGE}/reviews.jsonl" reviews pr_number id "$parent" || return 1
	_archive_merge_dir "${_ARC_STAGE}/review_comments.jsonl" review-comments pr_number id "$parent" || return 1

	local blob=""
	blob=$(jq -n --arg repo "$_ARC_SLUG" --arg i "$c_issues" --arg c "$c_comments" --arg r "$c_review" \
		--argjson schema "$ARCHIVE_SCHEMA" \
		'{schema: $schema, repository: $repo, issues: $i, comments: $c, review_comments: $r}' |
		_git hash-object -w --stdin) || return 1
	_git update-index --add --cacheinfo "100644,${blob},meta/cursor.json" || return 1
	blob=$(_archive_readme | _git hash-object -w --stdin) || return 1
	_git update-index --add --cacheinfo "100644,${blob},README.md" || return 1

	local tree="" parent_tree=""
	tree=$(_git write-tree) || return 1
	[[ -n "$parent" ]] && parent_tree=$(_git rev-parse "${parent}^{tree}")
	local summary
	summary="issues=$(_lines only-issues) pulls=$(_lines only-pulls) comments=$(_lines comments) reviews=$(_lines reviews) review_comments=$(_lines review_comments) requests=${_ARC_REQUESTS}"

	if [[ "$tree" == "$parent_tree" ]]; then
		_log "${_ARC_SLUG}: no changes (${summary})"
		_archive_finish_status
		return $?
	fi
	if [[ "$dry_run" -eq 1 ]]; then
		_log "${_ARC_SLUG}: dry-run, would commit tree ${tree} (${summary})"
		_archive_finish_status
		return $?
	fi

	local commit="" message=""
	message=$(printf 'archive: %s issue/PR discussions\n\n%s\n' "$_ARC_SLUG" "$summary")
	export GIT_AUTHOR_NAME="aidevops issue archive" GIT_AUTHOR_EMAIL="issue-archive@aidevops.invalid"
	export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
	# The first commit has no parent: the branch is an orphan.
	if [[ -n "$parent" ]]; then
		commit=$(_git commit-tree "$tree" -p "$parent" -m "$message") || return 1
	else
		commit=$(_git commit-tree "$tree" -m "$message") || return 1
	fi
	# Non-force push: a concurrent writer makes this a rejected non-fast-forward.
	if ! _git push -q "$remote" "${commit}:refs/heads/${ARCHIVE_BRANCH}" 2>/dev/null; then
		_log "${_ARC_SLUG}: push of ${ARCHIVE_BRANCH} rejected or failed"
		return 1
	fi
	_git update-ref "refs/heads/${ARCHIVE_BRANCH}" "$commit" || return 1
	_log "${_ARC_SLUG}: committed ${commit} (${summary})"
	_archive_finish_status
	return $?
}

_lines() {
	local name="$1"
	local file="${_ARC_STAGE}/${name}.jsonl"
	[[ -f "$file" ]] || {
		printf '0'
		return 0
	}
	# Keyset pagination refetches boundary items; count unique records.
	sort -u "$file" | wc -l | tr -d ' '
	return 0
}

_archive_finish_status() {
	if [[ "$_ARC_FAILED" -eq 1 ]]; then
		_log "${_ARC_SLUG}: partial failure; cursor kept at last fully written item"
		return 1
	fi
	[[ "$_ARC_BUDGET_HIT" -eq 1 ]] && _log "${_ARC_SLUG}: request cap reached; remaining items deferred to next run"
	return 0
}

#######################################
# Archive every eligible registered repository.
#######################################
cmd_run() {
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}" dry_run_args=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repos-json)
			repos_json="${2:-}"
			shift 2
			;;
		--dry-run)
			dry_run_args=(--dry-run)
			shift
			;;
		*)
			_log "unknown run argument: ${arg}"
			return 2
			;;
		esac
	done
	if [[ "${AIDEVOPS_ISSUE_ARCHIVE_ENABLED:-1}" == "0" ]]; then
		_log "disabled by AIDEVOPS_ISSUE_ARCHIVE_ENABLED=0"
		return 0
	fi
	if [[ ! -f "$repos_json" ]]; then
		_log "repos.json not found: ${repos_json}"
		return 0
	fi
	local failures=0 slug="" path="" remote=""
	while IFS=$'\t' read -r slug path; do
		case "$path" in \~/*) path="${HOME}/${path#\~/}" ;; esac
		[[ -n "$slug" && -n "$path" && -d "$path" ]] || continue
		# Read-only query of the canonical checkout; nothing is written there.
		remote=$(git -C "$path" remote get-url origin 2>/dev/null || true)
		if [[ -z "$remote" ]]; then
			_log "${slug}: no origin remote; skipping"
			continue
		fi
		cmd_export --repo "$slug" --remote "$remote" ${dry_run_args[@]+"${dry_run_args[@]}"} || failures=$((failures + 1))
	done < <(jq -r '.initialized_repos[]?
		| select(.pulse == true and .maintenance != false and (.local_only // false) != true
			and .issue_archive != false and (.slug // "") != "")
		| [.slug, .path] | @tsv' "$repos_json" 2>/dev/null)
	[[ "$failures" -eq 0 ]] && return 0
	_log "${failures} repositor(y/ies) failed"
	return 1
}

main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	export) cmd_export "$@" ;;
	run) cmd_run "$@" ;;
	help | -h | --help) _usage ;;
	*)
		_log "unknown command: ${cmd}"
		_usage
		return 2
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
