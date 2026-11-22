#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Sourced by release provenance. No mutable branch reads or writes: callers
# capture a canonical head once and pass immutable range endpoints here.

# Transport retry budget shared with release-provenance-helper.sh (GH#35434).
# GitHub intermittently answers commits/{sha}/pulls with an empty-body HTTP 500
# that gh reports only as a JSON decode error. Snapshots read once per commit,
# so a 3-attempt budget failed most multi-commit captures. Plain assignments:
# this file is sourced by several helpers and must tolerate double sourcing.
_RELEASE_GH_READ_DEFAULT_ATTEMPTS=8
_RELEASE_GH_READ_ATTEMPTS_CAP=12
_RELEASE_GH_READ_DEFAULT_UNIT=2
_RELEASE_GH_READ_UNIT_CAP=30

# Prints the validated attempt budget (RELEASE_SNAPSHOT_MAX_ATTEMPTS, 1..cap).
_release_gh_read_attempts() {
	local value="${RELEASE_SNAPSHOT_MAX_ATTEMPTS:-}"
	if [[ "$value" =~ ^[0-9]{1,3}$ ]] && ((10#$value >= 1 && 10#$value <= _RELEASE_GH_READ_ATTEMPTS_CAP)); then
		printf '%s\n' "$((10#$value))"
		return 0
	fi
	printf '%s\n' "$_RELEASE_GH_READ_DEFAULT_ATTEMPTS"
	return 0
}

# Sleeps attempt * RELEASE_SNAPSHOT_RETRY_UNIT seconds (unit 0..cap, default 2).
_release_gh_read_backoff() {
	local attempt="$1"
	local unit="${RELEASE_SNAPSHOT_RETRY_UNIT:-}"
	if [[ ! "$unit" =~ ^[0-9]{1,3}$ ]] || ((10#$unit > _RELEASE_GH_READ_UNIT_CAP)); then
		unit="$_RELEASE_GH_READ_DEFAULT_UNIT"
	fi
	sleep $((attempt * 10#$unit))
	return 0
}

# Keep transport diagnostics useful without forwarding multiline output, terminal
# controls, credential-bearing URLs, tokens or private paths into release logs.
# Redact before truncating so a token at the boundary cannot leak a prefix.
_release_gh_read_diagnostic() {
	local error_text="$1"
	local first_line="${error_text%%$'\n'*}"
	local summary=""
	summary=$(printf '%s' "$first_line" | jq -Rs '
		gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "")
		| gsub("[[:cntrl:]]"; " ")
		| gsub("(?i)https?://[^[:space:]]+"; "[redacted-url]")
		| gsub("/(Users|home|private|tmp|var)/[^[:space:]]+"; "[redacted-path]")
		| gsub("(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"; "[redacted-token]")
		| sub("(?i)(authorization|bearer|token|password|secret|api[_-]?key)[[:space:]]*[:= ].*"; "[redacted-credential]")
		| if length == 0 then "no stderr diagnostic" else . end
		| if length > 240 then .[:237] + "..." else . end
	' -r) || summary="diagnostic unavailable"
	printf '%s' "$summary"
	return 0
}

# Match known transient network errors from gh's Go HTTP client, never arbitrary
# nonzero exits. Keep the category static so retry logs cannot leak request URLs.
_release_gh_read_network_failure() {
	local error_text="$1"
	local normalized=""
	normalized=$(printf '%s' "$error_text" | LC_ALL=C tr '[:upper:]' '[:lower:]')
	if [[ "$normalized" =~ http[[:space:]]4[0-9][0-9] ||
		"$normalized" =~ (x509:|certificate|permission\ denied|authentication|not\ logged) ]]; then
		return 1
	fi
	if [[ "$normalized" =~ (connection\ reset\ by\ peer|connection\ refused|connection\ timed\ out|i/o\ timeout|tls\ handshake\ timeout|context\ deadline\ exceeded|client\.timeout\ exceeded|temporary\ failure\ in\ name\ resolution|no\ such\ host|network\ is\ unreachable|unexpected\ eof|error\ connecting\ to) ||
		"$normalized" =~ (^|[[:space:]:])eof([[:space:]]|$) ]]; then
		return 0
	fi
	return 1
}

# Read-only GitHub read with bounded retry of transport failures only (empty
# body, HTTP 5xx, network errors, truncated/invalid JSON). Auth, 404 and permission failures and
# wrong response shapes fail on the first attempt. Fail closed after the
# _release_gh_read_attempts budget.
# Usage: _release_snapshot_gh_read <purpose> <jq-shape-test> -- gh-args...
_release_snapshot_gh_read() {
	local purpose="$1"
	local shape="$2"
	shift 3
	local attempt=1
	local max_attempts=""
	local response=""
	local status=0
	local error_file=""
	local error_text=""
	local cause=""
	max_attempts=$(_release_gh_read_attempts)
	error_file=$(mktemp) || return 1
	while [[ "$attempt" -le "$max_attempts" ]]; do
		status=0
		response=$(gh "$@" 2>"$error_file") || status=$?
		error_text=$(<"$error_file")
		if [[ "$status" -eq 0 && "$response" =~ [^[:space:]] ]]; then
			if jq -e "$shape" <<<"$response" >/dev/null 2>&1; then
				rm -f "$error_file"
				printf '%s\n' "$response"
				return 0
			elif jq -e . <<<"$response" >/dev/null 2>&1; then
				rm -f "$error_file"
				printf 'release-snapshot: %s: unexpected response shape\n' "$purpose" >&2
				return 1
			fi
			cause="invalid JSON response"
		elif [[ "$error_text" =~ HTTP[[:space:]]5[0-9][0-9] ]]; then
			cause="HTTP 5xx"
		elif [[ "$error_text" =~ (unexpected\ end\ of\ JSON\ input|invalid\ character) ]]; then
			cause="JSON decode error"
		elif [[ "$status" -ne 0 ]] && _release_gh_read_network_failure "$error_text"; then
			cause="network transport error"
		elif [[ "$status" -eq 0 && -z "$error_text" ]]; then
			cause="empty response"
		else
			rm -f "$error_file"
			printf 'release-snapshot: %s: GitHub read failed (exit %s, attempt %s; not retryable): %s\n' "$purpose" "$status" "$attempt" "$(_release_gh_read_diagnostic "$error_text")" >&2
			return 1
		fi
		[[ "$attempt" -ge "$max_attempts" ]] && break
		printf 'release-snapshot: %s: %s; retrying after attempt %s/%s\n' "$purpose" "$cause" "$attempt" "$max_attempts" >&2
		_release_gh_read_backoff "$attempt"
		attempt=$((attempt + 1))
	done
	rm -f "$error_file"
	printf 'release-snapshot: %s: %s after %s attempts\n' "$purpose" "$cause" "$max_attempts" >&2
	return 1
}

# GH#38932: GitHub can permanently omit a squash merge's commit-to-PR
# association (REST commits/{sha}/pulls and GraphQL associatedPullRequests both
# empty hours later), which blocked every snapshot release containing it.
# The subject's PR number is only a hint: a hinted PR is accepted solely when
# its own GitHub record names this exact commit as its merge commit on the
# release branch. A direct push cannot borrow a PR this way, because that PR
# records a different merge commit. Read failures and two distinct verified
# hints fail closed. Prints {pr,merge}.
# Args: $1=repo $2=branch $3=commit
_release_snapshot_hinted_record() {
	local repo="$1"
	local branch="$2"
	local commit="$3"
	local subject=""
	local hint=""
	local pr_json=""
	local found=""
	subject=$(git log -1 --format=%s "$commit") || return 1
	while IFS= read -r hint; do
		[[ "$hint" =~ ^[1-9][0-9]{0,9}$ ]] || continue
		[[ "$hint" != "$found" ]] || continue
		pr_json=$(_release_snapshot_gh_read "hinted source PR #${hint} in ${repo}" 'type == "object"' -- \
			pr view "$hint" --repo "$repo" --json state,mergedAt,mergeCommit,baseRefName) || return 1
		#aidevops:trust-boundary
		jq -e --arg sha "$commit" --arg branch "$branch" '
			.state == "MERGED" and .mergedAt != null and .baseRefName == $branch
			and .mergeCommit.oid == $sha' <<<"$pr_json" >/dev/null || continue
		[[ -z "$found" ]] || return 1
		found="$hint"
	done < <(printf '%s\n' "$subject" | grep -oE '\(#[0-9]+\)|Merge pull request #[0-9]+' | grep -oE '[0-9]+')
	[[ -n "$found" ]] || return 1
	jq -cn --argjson pr "$found" --arg merge "$commit" '{pr:$pr,merge:$merge}'
	return $?
}

release_snapshot_sources() {
	local repo="$1"
	local branch="$2"
	local base="$3"
	local snapshot="$4"
	local commits=""
	local commit=""
	local records=""
	local matched=""
	local matched_count=""
	local record=""
	local merge_sha=""
	local pr_number=""
	local pr_json=""
	local sources='[]'
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$base" =~ ^[0-9a-f]{40}$ && "$snapshot" =~ ^[0-9a-f]{40}$ ]] || return 1
	git merge-base --is-ancestor "$base" "$snapshot" || return 1
	commits=$(git rev-list --first-parent --reverse "${base}..${snapshot}") || return 1
	[[ -n "$commits" ]] || return 1
	while IFS= read -r commit; do
		# For commits on the default branch GitHub returns the introducing PR.
		# A rebase merge introduces several commits with one final merge tip;
		# verify that tip independently and bind every introduced commit to it.
		records=$(_release_snapshot_gh_read "pull requests for commit ${commit} in ${repo}" 'type == "array"' -- \
			api --paginate --slurp "repos/${repo}/commits/${commit}/pulls?per_page=100") || return 1
		#aidevops:trust-boundary
		matched=$(jq -ce --arg repo "$repo" --arg branch "$branch" '
			flatten | [.[] | select(.merged_at != null and .state == "closed"
				and .base.repo.full_name == $repo and .base.ref == $branch
				and (.merge_commit_sha | type) == "string")]
			| map({pr:.number,merge:.merge_commit_sha})
		' <<<"$records") || return 1
		matched_count=$(jq -r 'length' <<<"$matched") || return 1
		case "$matched_count" in
		1)
			record=$(jq -ce '.[0]
				| select((.pr | type) == "number" and .pr > 0 and (.pr | floor) == .pr)' <<<"$matched") || return 1
			;;
		0)
			record=$(_release_snapshot_hinted_record "$repo" "$branch" "$commit") || {
				printf 'release-snapshot: commit %s has no merged PR association and no verified subject PR hint\n' "$commit" >&2
				return 1
			}
			;;
		*)
			printf 'release-snapshot: commit %s is associated with %s merged PRs; ambiguous\n' "$commit" "$matched_count" >&2
			return 1
			;;
		esac
		merge_sha=$(jq -er '.merge | select(test("^[0-9a-f]{40}$"))' <<<"$record") || return 1
		pr_number=$(jq -er '.pr' <<<"$record") || return 1
		git merge-base --is-ancestor "$commit" "$merge_sha" || return 1
		git merge-base --is-ancestor "$merge_sha" "$snapshot" || return 1
		if git merge-base --is-ancestor "$merge_sha" "$base"; then
			return 1
		fi
		pr_json=$(_release_snapshot_gh_read "source PR #${pr_number} in ${repo}" 'type == "object"' -- \
			pr view "$pr_number" --repo "$repo" --json state,mergedAt,mergeCommit,baseRefName) || return 1
		jq -e --arg sha "$merge_sha" --arg branch "$branch" '
			.state == "MERGED" and .mergedAt != null and .baseRefName == $branch
			and .mergeCommit.oid == $sha' <<<"$pr_json" >/dev/null || return 1
		sources=$(jq -ce --argjson record "$record" '
			if any(.[]; .pr == $record.pr and .merge != $record.merge) then error("conflicting snapshot PR")
			elif any(.[]; . == $record) then . else . + [$record] end
		' <<<"$sources") || return 1
	done <<<"$commits"
	jq -c 'sort_by(.pr)' <<<"$sources"
	return $?
}
