#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Publish generated metrics without changing checkout/index or bypassing protection.

set -euo pipefail

METRICS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shared-constants.sh
source "${METRICS_SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./shared-gh-wrappers.sh
source "${METRICS_SCRIPT_DIR}/shared-gh-wrappers.sh"

METRICS_PR_BRANCH="aidevops/repository-metrics"
METRICS_PR_TITLE="chore(metrics): refresh repository metrics [skip ci]"

metrics_validate_dir() {
	local directory="$1"
	local ancestor="$directory"
	case "$directory" in
	'' | /* | -* | *$'\n'* | *$'\r'* | *$'\t'* | *'//'*) return 1 ;;
	esac
	case "/${directory}/" in
	*/../* | */.git/*) return 1 ;;
	esac
	while [[ -n "$ancestor" && "$ancestor" != "." ]]; do
		[[ ! -L "$ancestor" ]] || return 1
		[[ "$ancestor" == */* ]] || break
		ancestor="${ancestor%/*}"
	done
	return 0
}

metrics_pr_lookup() {
	local repo="$1"
	local base="$2"
	AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1 gh_pr_list --repo "$repo" \
		--head "$METRICS_PR_BRANCH" --base "$base" --state open --json url \
		--jq 'if length == 0 then "" elif length == 1 then .[0].url else error("multiple metrics PRs") end'
	return $?
}

metrics_pr_create() {
	local repo="$1"
	local base="$2"
	local body_file="$3"
	local api_token="${4:-${GH_TOKEN:-}}"
	GH_TOKEN="$api_token" AIDEVOPS_PR_CREATE_READY=1 gh_create_pr \
		--repo "$repo" --base "$base" --head "$METRICS_PR_BRANCH" \
		--title "$METRICS_PR_TITLE" --label origin:worker --body-file "$body_file"
	return $?
}

metrics_ensure_pr() {
	local repo="$1"
	local base="$2"
	local state_dir="$3"
	local existing=""
	local fallback_token="${AIDEVOPS_METRICS_PR_TOKEN:-}"
	local body_file="${state_dir}/metrics-pr.md"
	existing=$(metrics_pr_lookup "$repo" "$base") || return 1
	if [[ -n "$existing" ]]; then
		printf '::notice::Updated deterministic metrics PR %s (awaiting normal review/checks and merge)\n' "$existing"
		return 0
	fi
	cat >"$body_file" <<EOF
<!-- aidevops:repository-metrics-pr -->
## Repository metrics publication

Publishes generated metrics through one deterministic PR because the default
branch rejected direct publication with GH006. Only configured generated JSON,
Markdown and SVG artifacts are included; subsequent refreshes replace the snapshot.

Branch protection, administrator enforcement, review and required checks remain
unchanged. The branch commit omits [skip ci]; the eventual squash title retains
it for loop prevention. A successful publisher run means this candidate is
queued, not merged. GITHUB_TOKEN-created PR events can suppress Actions triggers:
use the repository's authorized check-trigger mechanism before merging, never
bypass required checks. No automatic approval or merge is requested.
EOF
	if ! existing=$(metrics_pr_create "$repo" "$base" "$body_file"); then
		# Recover an API partial success or concurrent creator before using a PAT.
		existing=$(metrics_pr_lookup "$repo" "$base") || return 1
		if [[ -z "$existing" && -n "$fallback_token" && "$fallback_token" != "${GH_TOKEN:-}" ]]; then
			printf '::notice::Job token could not create the metrics PR; retrying once with SYNC_PAT PR API fallback\n'
			if ! existing=$(metrics_pr_create "$repo" "$base" "$body_file" "$fallback_token"); then
				existing=$(metrics_pr_lookup "$repo" "$base") || return 1
			fi
		fi
	fi
	if [[ -z "$existing" ]]; then
		printf '::error::Cannot create metrics PR: verify caller/job pull-requests: write and Actions "Allow GitHub Actions to create and approve pull requests". If that setting is disabled, configure per-repo SYNC_PAT with Contents and Pull requests: read/write for the PR API fallback; it does not bypass branch protection.\n' >&2
		return 1
	fi
	printf '::notice::Created deterministic metrics PR %s (awaiting normal review/checks and merge)\n' "$existing"
	return 0
}

metrics_validate_owned_branch() {
	local expected="$1"
	local base_sha="$2"
	local base_branch="$3"
	shift 3
	local exclusions=()
	local path=""
	local unexpected=""
	local source_sha=""
	local parents=""
	source_sha=$(git log -1 --format=%B "$expected" |
		sed -nE 's/^Aidevops-Metrics-Source: ([0-9a-f]{40})$/\1/p') || return 1
	if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
		printf '::error::Refusing to replace an unrecognized metrics branch\n' >&2
		return 1
	fi
	parents=$(git log -1 --format=%P "$expected") || return 1
	if [[ "$parents" != "$source_sha" ]]; then
		printf '::error::Metrics branch has additional history; refusing snapshot replacement\n' >&2
		return 1
	fi
	if ! git merge-base --is-ancestor "$source_sha" "$base_sha"; then
		# Recover history only when a legitimate older snapshot needs it. Never
		# treat shallow-history uncertainty as permission to discard branch work.
		if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
			git fetch -q --unshallow origin "$base_branch" || return 1
		fi
		if ! git merge-base --is-ancestor "$source_sha" "$base_sha"; then
			printf '::error::Metrics snapshot source is not an ancestor of the current publication base\n' >&2
			return 1
		fi
	fi
	for path in "$@"; do
		exclusions+=(":(exclude,literal)${path}")
	done
	unexpected=$(git diff --name-only "${expected}^" "$expected" -- . "${exclusions[@]}") || return 1
	if [[ -n "$unexpected" ]]; then
		printf '::error::Metrics branch contains unrelated changes; refusing snapshot replacement\n' >&2
		return 1
	fi
	return 0
}

metrics_publish_snapshot() {
	local base_branch="$1"
	local output_dir="$2"
	local badge_dir="$3"
	local legacy_dir="$4"
	local subject="$5"
	local state_dir="$6"
	local repo="${GITHUB_REPOSITORY:-}"
	local source_sha=""
	local base_sha=""
	local tree_sha=""
	local candidate=""
	local expected=""
	local path=""
	local attempt=0
	local pr_mode=false
	local branch_subject=""
	local paths=("${output_dir}/repo-metrics.json" "${output_dir}/repo-metrics.md"
		"${badge_dir}/loc.svg" "${badge_dir}/languages.svg" "${badge_dir}/dependencies.svg")
	local pathspecs=()
	if [[ -n "$legacy_dir" ]]; then
		paths+=("${legacy_dir}/loc-total.svg" "${legacy_dir}/loc-languages.svg")
	fi
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
		printf '::error::GITHUB_REPOSITORY is required for metrics publication\n' >&2
		return 1
	}
	git check-ref-format "refs/heads/${base_branch}" || return 1
	metrics_validate_dir "$output_dir" && metrics_validate_dir "$badge_dir" || return 1
	[[ -z "$legacy_dir" ]] || metrics_validate_dir "$legacy_dir" || return 1
	source_sha=$(git rev-parse HEAD) || return 1
	for path in "${paths[@]}"; do
		[[ ! -L "$path" ]] || return 1
		if [[ -f "$path" ]] || git cat-file -e "${source_sha}:${path}" 2>/dev/null; then
			pathspecs+=(":(literal)${path}")
		fi
	done
	[[ "${#pathspecs[@]}" -gt 0 ]] || return 0
	if [[ -z "$(git status --porcelain -- "${pathspecs[@]}")" ]]; then
		printf 'No repository metrics changes to publish\n'
		return 0
	fi
	branch_subject=$(printf '%s\n' "$subject" | sed -E 's/[[:space:]]*\[skip ci\]//g')
	[[ -n "$branch_subject" ]] || branch_subject="chore(metrics): refresh repository metrics"
	while [[ "$attempt" -lt 3 ]]; do
		attempt=$((attempt + 1))
		git fetch -q origin "$base_branch" || return 1
		base_sha=$(git rev-parse FETCH_HEAD) || return 1
		# Queued push events can be older than the current default branch. Never
		# publish that old scan over a newer candidate; the current run will scan it.
		if [[ "$source_sha" != "$base_sha" ]]; then
			printf '::notice::Skipping superseded metrics snapshot; default branch advanced since this scan\n'
			return 0
		fi
		GIT_INDEX_FILE="${state_dir}/index" git read-tree "$base_sha" || return 1
		GIT_INDEX_FILE="${state_dir}/index" git add -A -- "${pathspecs[@]}" || return 1
		tree_sha=$(GIT_INDEX_FILE="${state_dir}/index" git write-tree) || return 1
		if [[ "$tree_sha" == "$(git rev-parse "${base_sha}^{tree}")" ]]; then
			return 0
		fi
		if [[ "$pr_mode" == false ]]; then
			candidate=$(printf '%s\n' "$subject" | git commit-tree "$tree_sha" -p "$base_sha") || return 1
			if git push origin "${candidate}:refs/heads/${base_branch}" >"${state_dir}/push.log" 2>&1; then
				printf '::notice::Published repository metrics directly\n'
				return 0
			fi
			if ! grep -q 'GH006.*Protected branch update failed' "${state_dir}/push.log"; then
				# Retry a moving base or transient failure, but never disguise it as
				# a branch-protection failure or open an unrelated fallback PR.
				continue
			fi
			pr_mode=true
		fi
		expected=$(git ls-remote --heads origin "refs/heads/${METRICS_PR_BRANCH}") || return 1
		expected="${expected%%$'\t'*}"
		if [[ -n "$expected" ]]; then
			git fetch -q --depth=2 origin "$METRICS_PR_BRANCH" || continue
			[[ "$(git rev-parse FETCH_HEAD)" == "$expected" ]] || continue
			metrics_validate_owned_branch "$expected" "$base_sha" "$base_branch" "${paths[@]}" || return 1
			if [[ "$(git rev-parse "${expected}^{tree}")" == "$tree_sha" ]]; then
				metrics_ensure_pr "$repo" "$base_branch" "$state_dir"
				return $?
			fi
		fi
		candidate=$(printf '%s\n\nAidevops-Metrics-Source: %s\n' "$branch_subject" "$source_sha" |
			git commit-tree "$tree_sha" -p "$base_sha") || return 1
		# Replace only this generated branch, with an explicit expected-head lease.
		if git push --force-with-lease="refs/heads/${METRICS_PR_BRANCH}:${expected}" origin \
			"${candidate}:refs/heads/${METRICS_PR_BRANCH}" >"${state_dir}/push.log" 2>&1; then
			metrics_ensure_pr "$repo" "$base_branch" "$state_dir"
			return $?
		fi
	done
	printf '::error::Failed to publish repository metrics after 3 bounded attempts; inspect the Git push failure (not a request to bypass protection)\n' >&2
	cat "${state_dir}/push.log" >&2
	return 1
}

main() {
	local base_branch="${1:-}"
	local output_dir="${2:-docs/metrics}"
	local badge_dir="${3:-docs/metrics/badges}"
	local legacy_dir="${4:-}"
	local subject="${5:-$METRICS_PR_TITLE}"
	local state_dir=""
	local result=0
	state_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/metrics-publish.XXXXXX") || return 1
	metrics_publish_snapshot "$base_branch" "$output_dir" "$badge_dir" "$legacy_dir" "$subject" "$state_dir" || result=$?
	rm -rf "$state_dir"
	if [[ "$result" -ne 0 && "${FAIL_ON_PUSH_ERROR:-true}" == false ]]; then
		printf '::warning::Repository metrics publication failed; fail_on_push_error=false keeps this warning-only\n' >&2
		return 0
	fi
	return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
