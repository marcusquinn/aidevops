#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# dependabot-aidevops-exclusion-helper.sh — keep aidevops reusable-workflow pins
# out of downstream Dependabot `github-actions` updates (GH#36723).
#
# Downstream callers pin `uses: marcusquinn/aidevops/...@<sha> # vX.Y.Z` with a
# matching `with.aidevops_ref`. Dependabot bumps only the `uses:` SHA, opening a
# stale PR on every framework release and breaking that pairing. The pins are
# advanced together by `aidevops sync-workflows --force-ref` instead.
#
# For each eligible registered repository this helper reads the default-branch
# `.github/dependabot.yml` through the GitHub API, classifies it, and with
# --apply opens one PR adding `ignore: - dependency-name: "marcusquinn/aidevops*"`
# to every `github-actions` update entry. No local checkout is read or mutated.
# Other ecosystems and dependencies are untouched.
#
# Exit codes: 0 success or no work, 1 one or more repositories failed,
# 2 configuration error.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
[[ -f "$SELF_DIR/shared-constants.sh" ]] && source "$SELF_DIR/shared-constants.sh"
# shellcheck source=/dev/null
[[ -f "$SELF_DIR/shared-gh-wrappers.sh" ]] && source "$SELF_DIR/shared-gh-wrappers.sh"

readonly DAE_REPOS_JSON="${AIDEVOPS_REPOS_JSON:-$HOME/.config/aidevops/repos.json}"
readonly DAE_TRANSFORM="$SELF_DIR/dependabot-aidevops-exclusion.py"
readonly DAE_FRAMEWORK_SLUG="marcusquinn/aidevops"
readonly DAE_BRANCH="chore/dependabot-exclude-aidevops"
readonly DAE_TITLE="chore(deps): exclude aidevops reusable workflows from Dependabot"
readonly DAE_CONFIG_PATHS=(".github/dependabot.yml" ".github/dependabot.yaml")
readonly DAE_MISSING="MISSING"
readonly DAE_SKIPPED="SKIPPED"
readonly DAE_FAILED="FAILED"

_OPT_APPLY=0
_OPT_REPO=""
_OPT_ISSUE=""
_OPT_JSON=0
_FAILURES=0

_usage() {
	cat <<'EOF'
dependabot-aidevops-exclusion-helper.sh — exclude aidevops pins from Dependabot (GH#36723)

Usage:
  aidevops sync-dependabot [--apply] [--repo OWNER/REPO] [--issue NUMBER] [--json]

Reads each eligible registered repository's default-branch .github/dependabot.yml
via the GitHub API and adds `ignore: - dependency-name: "marcusquinn/aidevops*"`
to every github-actions update entry. aidevops caller pins advance together
with their aidevops_ref input via `aidevops sync-workflows --force-ref`.

Default is a dry run. --apply opens one ready PR per repository that needs
the exclusion (branch chore/dependabot-exclude-aidevops).

Eligible: registered in repos.json, not local_only/contributed/contributor,
not archived, ADMIN or MAINTAIN permission, not marcusquinn/aidevops itself.

Classifications:
  EXCLUDED     every github-actions entry already ignores aidevops
  MISSING      at least one github-actions entry needs the exclusion
  NO-ACTIONS   Dependabot config has no github-actions entry
  NO-CONFIG    no .github/dependabot.yml
  UNSUPPORTED  layout cannot be patched safely; edit manually
  INELIGIBLE   skipped by the eligibility rules above

Options:
  --apply         Create branches, commits, and PRs (default: dry run)
  --repo SLUG     Limit to one repository
  --issue NUMBER  Reference a rollout issue (For OWNER/REPO#NUMBER) in PR bodies
  --json          Emit one JSON object per repository
  -h, --help      Show this help
EOF
	return 0
}

_die() {
	local message="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$message" >&2
	exit 2
}

_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local value="${2:-}"
		case "$arg" in
		--apply) _OPT_APPLY=1; shift ;;
		--repo) [[ -n "$value" ]] || _die "--repo requires OWNER/REPO"; _OPT_REPO="$value"; shift 2 ;;
		--issue) [[ "$value" =~ ^[0-9]+$ ]] || _die "--issue requires a number"; _OPT_ISSUE="$value"; shift 2 ;;
		--json) _OPT_JSON=1; shift ;;
		-h | --help | help) _usage; exit 0 ;;
		*) _die "unknown argument: $arg (see --help)" ;;
		esac
	done
	return 0
}

_emit() {
	local slug="$1" classification="$2" status="$3" detail="$4"
	if [[ "$_OPT_JSON" -eq 1 ]]; then
		jq -cn --arg repo "$slug" --arg classification "$classification" \
			--arg status "$status" --arg detail "$detail" \
			'{repo: $repo, classification: $classification, status: $status, detail: $detail}'
	else
		printf '%-55s %-12s %-8s %s\n' "$slug" "$classification" "$status" "$detail"
	fi
	return 0
}

# Registered slugs, excluding local-only, contributed and contributor repos.
_candidate_slugs() {
	jq -r --arg only "$_OPT_REPO" '
		.initialized_repos[]?
		| select((.slug // "") != "")
		| select(($only == "") or (.slug == $only))
		| select((.local_only // false) != true)
		| select((.contributed // false) != true and (.role // "") != "contributor")
		| .slug
	' "$DAE_REPOS_JSON" | LC_ALL=C sort -u
	return 0
}

# Print the default branch for an eligible repo; print a skip reason on stderr
# and return 1 otherwise.
_eligible_default_branch() {
	local slug="$1"
	local repo_json=""
	if [[ "$slug" == "$DAE_FRAMEWORK_SLUG" ]]; then
		printf 'framework-repo' >&2
		return 1
	fi
	repo_json=$(gh api "repos/${slug}" 2>/dev/null) || {
		printf 'inaccessible' >&2
		return 1
	}
	if jq -e '.archived == true' >/dev/null 2>&1 <<<"$repo_json"; then
		printf 'archived' >&2
		return 1
	fi
	if ! jq -e '(.permissions.admin == true) or (.permissions.maintain == true)' >/dev/null 2>&1 <<<"$repo_json"; then
		printf 'insufficient-permission' >&2
		return 1
	fi
	jq -r '.default_branch // empty' <<<"$repo_json"
	return 0
}

# Fetch the Dependabot config into $content_file. Prints "PATH<TAB>BLOB_SHA".
# Returns 0 found, 3 absent, 1 API error.
_fetch_config() {
	local slug="$1" branch="$2" content_file="$3"
	local err_file="${content_file}.err"
	local path="" response="" rc=0 blob_sha=""
	for path in "${DAE_CONFIG_PATHS[@]}"; do
		rc=0
		response=$(gh api "repos/${slug}/contents/${path}?ref=${branch}" 2>"$err_file") || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			jq -r '.content' <<<"$response" | base64 --decode >"$content_file" || return 1
			blob_sha=$(jq -r '.sha // empty' <<<"$response")
			[[ "$blob_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
			printf '%s\t%s\n' "$path" "$blob_sha"
			return 0
		fi
		grep -qE 'HTTP 404|Not Found' "$err_file" || return 1
	done
	return 3
}

# shellcheck disable=SC2016  # backticks are intentional markdown literals
_write_pr_body() {
	local body_file="$1" config_path="$2"
	{
		printf '## Summary\n\n'
		printf 'Add `ignore: - dependency-name: "marcusquinn/aidevops*"` to the `github-actions` update entries in `%s`.\n\n' "$config_path"
		printf '## Why\n\n'
		printf 'aidevops reusable-workflow callers pin `uses:` to a release SHA together with a matching `with.aidevops_ref` input. '
		printf 'aidevops releases several times a day, and Dependabot bumps only the `uses:` SHA, so each release produced a stale PR that also broke the pairing. '
		printf 'Those pins are advanced together by `aidevops sync-workflows --force-ref`.\n\n'
		printf 'Other GitHub Actions and ecosystems keep their existing Dependabot schedule.\n\n'
		printf '## Verification\n\n'
		printf -- '- Change is insert-only; existing entries are unchanged.\n'
		printf -- '- Generated by `aidevops sync-dependabot --apply`; re-running reports `EXCLUDED`.\n'
		[[ -n "$_OPT_ISSUE" ]] && printf '\nFor %s#%s\n' "$DAE_FRAMEWORK_SLUG" "$_OPT_ISSUE"
	} >"$body_file"
	return 0
}

# Create branch, commit the patched config, and open a ready PR.
_apply_repo() {
	local slug="$1" branch="$2" config_path="$3" blob_sha="$4" patched_file="$5" body_file="$6"
	local existing="" base_sha="" content_b64="" pr_url="" commit_result="" commit_sha="" head_sha=""
	local err_file="${body_file}.pr-error" diagnostic=""
	existing=$(gh pr list --repo "$slug" --head "$DAE_BRANCH" --state open \
		--json url --jq '.[0].url // empty' 2>/dev/null) || existing=""
	if [[ -n "$existing" ]]; then
		printf '%s' "$existing"
		return 0
	fi
	if gh api "repos/${slug}/git/ref/heads/${DAE_BRANCH}" >/dev/null 2>&1; then
		printf 'branch %s exists without an open PR; open or delete it, then re-run' "$DAE_BRANCH"
		return 1
	fi
	base_sha=$(gh api "repos/${slug}/git/ref/heads/${branch}" --jq '.object.sha' 2>/dev/null) || {
		printf 'cannot resolve %s head' "$branch"
		return 1
	}
	gh api -X POST "repos/${slug}/git/refs" -f "ref=refs/heads/${DAE_BRANCH}" \
		-f "sha=${base_sha}" >/dev/null 2>&1 || {
		printf 'branch creation failed'
		return 1
	}
	content_b64=$(base64 <"$patched_file" | tr -d '\n')
	if ! commit_result=$(gh api -X PUT "repos/${slug}/contents/${config_path}" -f "message=${DAE_TITLE}" \
		-f "content=${content_b64}" -f "sha=${blob_sha}" -f "branch=${DAE_BRANCH}" 2>/dev/null); then
		gh api -X DELETE "repos/${slug}/git/refs/heads/${DAE_BRANCH}" >/dev/null 2>&1 || true
		printf 'commit failed; branch removed'
		return 1
	fi
	commit_sha=$(jq -r '.commit.sha // empty' <<<"$commit_result")
	if ! declare -F gh_create_pr >/dev/null 2>&1; then
		printf 'gh_create_pr unavailable; branch %s pushed without PR' "$DAE_BRANCH"
		return 1
	fi
	if ! pr_url=$(AIDEVOPS_PR_CREATE_READY=1 gh_create_pr --repo "$slug" --title "$DAE_TITLE" \
		--body-file "$body_file" --head "$DAE_BRANCH" --base "$branch" 2>"$err_file"); then
		diagnostic=$(<"$err_file")
		if ! existing=$(gh pr list --repo "$slug" --head "$DAE_BRANCH" --state open \
			--json url --jq '.[0].url // empty' 2>/dev/null); then
			printf 'PR creation failed; branch %s pushed; PR lookup failed: %s' "$DAE_BRANCH" "$diagnostic"
			return 1
		fi
		if [[ -n "$existing" ]]; then
			printf '%s' "$existing"
			return 0
		fi
		head_sha=$(gh api "repos/${slug}/git/ref/heads/${DAE_BRANCH}" --jq '.object.sha' 2>/dev/null) || head_sha=""
		if [[ ! "$commit_sha" =~ ^[0-9a-f]{40}$ || "$head_sha" != "$commit_sha" ]]; then
			printf 'PR creation failed; branch %s pushed; head not verified: %s' "$DAE_BRANCH" "$diagnostic"
			return 1
		fi
		if ! pr_url=$(AIDEVOPS_PR_CREATE_READY=1 gh_create_pr --repo "$slug" --title "$DAE_TITLE" \
			--body-file "$body_file" --head "$DAE_BRANCH" --base "$branch" 2>"$err_file"); then
			printf 'PR creation failed; branch %s pushed: %s; retry: %s' "$DAE_BRANCH" "$diagnostic" "$(<"$err_file")"
			return 1
		fi
	fi
	printf '%s' "$(printf '%s' "$pr_url" | tail -n 1)"
	return 0
}

_process_repo() {
	local slug="$1" work_dir="$2"
	local branch="" reason="" fetched="" fetch_rc=0 config_path="" blob_sha=""
	local classification="" detail="" rc=0
	local content_file="$work_dir/current.yml" patched_file="$work_dir/patched.yml"
	local body_file="$work_dir/body.md" reason_file="$work_dir/reason"

	branch=$(_eligible_default_branch "$slug" 2>"$reason_file") || {
		reason=$(<"$reason_file")
		_emit "$slug" "INELIGIBLE" "$DAE_SKIPPED" "$reason"
		return 0
	}
	fetched=$(_fetch_config "$slug" "$branch" "$content_file") || fetch_rc=$?
	case "$fetch_rc" in
	0) IFS=$'\t' read -r config_path blob_sha <<<"$fetched" ;;
	3) _emit "$slug" "NO-CONFIG" "$DAE_SKIPPED" "no Dependabot config"; return 0 ;;
	*) _emit "$slug" "ERROR" "$DAE_FAILED" "Dependabot config read failed"; _FAILURES=$((_FAILURES + 1)); return 0 ;;
	esac
	classification=$(python3 "$DAE_TRANSFORM" classify <"$content_file") || classification="UNSUPPORTED:transform-error"
	case "$classification" in
	EXCLUDED | NO-ACTIONS) _emit "$slug" "$classification" "$DAE_SKIPPED" "$config_path"; return 0 ;;
	UNSUPPORTED:*) _emit "$slug" "UNSUPPORTED" "$DAE_SKIPPED" "${classification#UNSUPPORTED:}; edit ${config_path} manually"; return 0 ;;
	"$DAE_MISSING") ;;
	*) _emit "$slug" "ERROR" "$DAE_FAILED" "unexpected classification: $classification"; _FAILURES=$((_FAILURES + 1)); return 0 ;;
	esac
	if [[ "$_OPT_APPLY" -eq 0 ]]; then
		_emit "$slug" "$DAE_MISSING" "PLANNED" "would open PR updating ${config_path}"
		return 0
	fi
	python3 "$DAE_TRANSFORM" patch <"$content_file" >"$patched_file" || {
		_emit "$slug" "$DAE_MISSING" "$DAE_FAILED" "patch failed"
		_FAILURES=$((_FAILURES + 1))
		return 0
	}
	_write_pr_body "$body_file" "$config_path"
	rc=0
	detail=$(_apply_repo "$slug" "$branch" "$config_path" "$blob_sha" "$patched_file" "$body_file") || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		_emit "$slug" "$DAE_MISSING" "APPLIED" "$detail"
	else
		_emit "$slug" "$DAE_MISSING" "$DAE_FAILED" "$detail"
		_FAILURES=$((_FAILURES + 1))
	fi
	return 0
}

main() {
	_parse_args "$@"
	command -v jq >/dev/null 2>&1 || _die "jq is required"
	command -v gh >/dev/null 2>&1 || _die "gh is required"
	command -v python3 >/dev/null 2>&1 || _die "python3 is required"
	[[ -f "$DAE_TRANSFORM" ]] || _die "transform not found: $DAE_TRANSFORM"
	[[ -f "$DAE_REPOS_JSON" ]] || _die "repos.json not found: $DAE_REPOS_JSON"

	local temp_root="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || _die "cannot create $temp_root"
	local work_dir=""
	work_dir=$(mktemp -d "${temp_root%/}/dependabot-exclusion.XXXXXX") || _die "cannot create work dir"
	# shellcheck disable=SC2064  # expand work_dir now
	trap "rm -rf '$work_dir'" EXIT

	local slugs="" slug="" count=0
	slugs=$(_candidate_slugs)
	[[ -n "$slugs" ]] || {
		[[ -n "$_OPT_REPO" ]] && _die "repository not registered or not eligible: $_OPT_REPO"
		printf 'No registered repositories.\n'
		return 0
	}
	[[ "$_OPT_JSON" -eq 1 ]] || printf '%-55s %-12s %-8s %s\n' "REPO" "CLASS" "STATUS" "DETAIL"
	# fd 3 keeps the slug list away from commands that may read stdin.
	while IFS= read -r slug <&3; do
		_process_repo "$slug" "$work_dir"
		count=$((count + 1))
	done 3<<<"$slugs"
	if [[ "$_OPT_JSON" -eq 0 ]]; then
		printf '\n%d repositories checked, %d failed.' "$count" "$_FAILURES"
		[[ "$_OPT_APPLY" -eq 1 ]] || printf ' Dry run: re-run with --apply to open PRs.'
		printf '\n'
	fi
	[[ "$_FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
