#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exact-head, signed authorization for managed Cloudron catalog releases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=cloudron-package-release-lib.sh
source "${SCRIPT_DIR}/cloudron-package-release-lib.sh"
REPOS_FILE="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
RELEASE_SHA_PATTERN='^[a-f0-9]{40}$'
RELEASE_APPROVAL_LABEL='release-approval-required'

release_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

release_authority() {
	local repo="$1" permission=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_error 'Repository must be in owner/repo format.' || return 1
	jq -e --arg repo "$repo" '.initialized_repos[] | select(.slug == $repo and .app_type == "cloudron-package" and .maintenance != false)' "$REPOS_FILE" >/dev/null || release_error "Repository ${repo} is not registered as a maintained cloudron-package." || return 1
	permission=$(gh api "repos/${repo}" --jq '.permissions | .admin == true or .maintain == true') || release_error "Unable to verify admin/maintain permission for ${repo}." || return 1
	#aidevops:trust-boundary — registration alone never grants release authority.
	[[ "$permission" == true ]] || release_error "Admin or maintain permission is required for ${repo}." || return 1
	return 0
}

release_contents() {
	local repo="$1" path="$2" sha="$3"
	gh api "repos/${repo}/contents/${path}?ref=${sha}" --jq '.content | @base64d' || return 1
	return 0
}

release_checks() {
	local repo="$1" pr="$2" checks=""
	checks=$(gh pr checks "$pr" --repo "$repo" --json name,bucket,link) || return 1
	# Main-only publication jobs are intentionally skipped on PRs. Preflight
	# itself must run successfully; an empty or all-skipped suite is not evidence.
	jq -e 'all(.[]; .bucket == "pass" or .bucket == "skipping") and any(.[]; .bucket == "pass" and (.name | test("(^| / )preflight$")))' <<<"$checks" >/dev/null || return 1
	printf '%s\n' "$checks"
	return 0
}

release_pr() {
	local repo="$1" pr="$2" snapshot=""
	snapshot=$(gh api "repos/${repo}/pulls/${pr}") || release_error "Unable to read PR #${pr} in ${repo}." || return 1
	#aidevops:trust-boundary — only same-repository, non-draft main updates.
	jq -e --arg repo "$repo" '.base.repo.full_name == $repo and .head.repo.full_name == $repo and .base.ref == "main"' <<<"$snapshot" >/dev/null || release_error "PR #${pr} must be a same-repository PR against main in ${repo}." || return 1
	jq -e '.draft == false' <<<"$snapshot" >/dev/null || release_error "PR #${pr} is a draft or its draft status is unavailable. Run: gh pr ready ${pr} --repo ${repo}; then wait for re-triggered checks to pass." || return 1
	jq -e --arg sha_pattern "$RELEASE_SHA_PATTERN" '.head.sha | test($sha_pattern)' <<<"$snapshot" >/dev/null || release_error "PR #${pr} has an invalid head SHA." || return 1
	printf '%s\n' "$snapshot"
	return 0
}

release_issues() {
	local repo="$1" pages=""
	pages=$(gh api "repos/${repo}/issues?state=open&labels=release-approval-required&per_page=100" --paginate) || return 1
	jq -sc 'add | map(select(.pull_request == null))' <<<"$pages" || return 1
	return 0
}

release_comment() {
	local repo="$1" issue="$2" body="$3"
	printf '%s\n' "$body" | gh_issue_comment "$issue" --repo "$repo" --body-file - || return 1
	return 0
}

release_verify() {
	local repo="$1" issue="$2"
	"${SCRIPT_DIR}/approval-helper.sh" verify issue "$issue" "$repo" --require-authority
	return $?
}

release_publication_preflight() {
	local repo="$1" head="$2" secrets="" caller="" pat_rc=0
	# The job token publishes unless rules on main block its direct push.
	cloudron_publication_pat_required "$repo" || pat_rc=$?
	[[ "$pat_rc" -ne 2 ]] || release_error "Unable to read branch rules for main in ${repo}; no approval request or merge." || return 1
	if [[ "$pat_rc" -eq 0 ]]; then
		# Names only: never retrieve or print credential values.
		secrets=$(gh secret list --repo "$repo" --app actions --json name) || release_error "Unable to verify CLOUDRON_RELEASE_PAT in ${repo}; no approval request or merge." || return 1
		jq -e 'any(.[]; .name == "CLOUDRON_RELEASE_PAT")' <<<"$secrets" >/dev/null || release_error "${repo} is missing CLOUDRON_RELEASE_PAT, which its main branch rules (required PRs or checks) need for the catalog push. Configure a fine-grained PAT with Contents write access (cloudron-app-publishing-skill.md), or relax those rules, before requesting approval or merging." || return 1
	fi
	caller=$(release_contents "$repo" .github/workflows/cloudron-catalog-publish.yml "$head") || release_error 'Unable to read the exact-head catalog workflow; no approval request or merge.' || return 1
	printf '%s\n' "$caller" | python3 "${SCRIPT_DIR}/cloudron-release-evidence.py" --check-caller || return 1
	return 0
}

release_request() {
	local repo="$1" pr="$2"
	local snapshot="" sha="" manifest="" version="" upstream="" notes="" checks="" issues="" existing="" url="" older="" rc=0
	local metadata=""
	local verdict=""
	[[ "$pr" =~ ^[1-9][0-9]*$ ]] || release_error 'PR number must be a positive integer.' || return 1
	release_authority "$repo" || return 1
	snapshot=$(release_pr "$repo" "$pr") || return 1
	[[ "$(jq -r '.state' <<<"$snapshot")" == open ]] || release_error "PR #${pr} must be open before requesting approval." || return 1
	sha=$(jq -r '.head.sha' <<<"$snapshot")
	release_publication_preflight "$repo" "$sha" || return 1
	checks=$(release_checks "$repo" "$pr") || release_error 'PR checks must all pass before requesting approval.' || return 1
	manifest=$(release_contents "$repo" CloudronManifest.json "$sha") || return 1
	version=$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$manifest") || return 1
	upstream=$(jq -er '.upstreamVersion | select(type == "string" and length > 0)' <<<"$manifest") || return 1
	local changelog=""
	changelog=$(jq -r '.changelog // "file://CHANGELOG.md" | sub("^file://"; "")' <<<"$manifest") || return 1
	[[ "$changelog" =~ ^[A-Za-z0-9_./-]+$ && "$changelog" != *..* && "$changelog" != /* ]] || return 1
	notes=$(release_contents "$repo" "$changelog" "$sha") || return 1
	notes=$(printf '%s\n' "$notes" | awk -v version="$version" '
		$0 == "[" version "]" || index($0, "## [" version "]") == 1 { found=1; next }
		found && ($0 ~ /^\[/ || $0 ~ /^## /) { exit }
		found { print }
	')
	[[ -n "${notes//[[:space:]]/}" ]] || release_error 'Release changelog entry is empty.' || return 1
	issues=$(release_issues "$repo") || return 1
	existing=$(jq -c --arg marker "<!-- aidevops:cloudron-release-approval ${version} -->" '.[] | select(.body | contains($marker))' <<<"$issues") || return 1
	if [[ -n "$existing" ]]; then
		metadata=$(release_metadata "$(jq -r '.body' <<<"$existing")" "$repo") || return 1
		if ! jq -e --arg sha "$sha" --argjson pr "$pr" '.head == $sha and .pr == $pr' <<<"$metadata" >/dev/null; then
			release_error 'Existing version request has a different PR/head: refresh its signed body and obtain re-approval.'
			return 1
		fi
		printf '%s\n' "$existing" | jq -r '.html_url'
		return 0
	fi
	# A durable hold prevents ordinary merge automation from publishing first.
	# Retry an interrupted request only when its dedicated PR label is present.
	jq -e --arg label "$RELEASE_APPROVAL_LABEL" '(all(.labels[]; .name != "hold-for-review") or any(.labels[]; .name == $label)) and .auto_merge == null' <<<"$snapshot" >/dev/null || release_error 'Resolve existing PR hold/auto-merge before requesting a release.' || return 1
	gh label create release-approval-required --repo "$repo" --description 'Publication requires signed exact-head release approval' --color B60205 --force || return 1
	gh_pr_edit_safe "$pr" --repo "$repo" --add-label release-approval-required --add-label hold-for-review >/dev/null || return 1
	snapshot=$(release_pr "$repo" "$pr") || return 1
	[[ "$(jq -r '.head.sha' <<<"$snapshot")" == "$sha" ]] || return 1
	metadata=$(jq -cn --arg repo "$repo" --argjson pr "$pr" --arg sha "$sha" --arg version "$version" --arg upstream "$upstream" '{schema:1,repository:$repo,pr:$pr,head:$sha,version:$version,upstream:$upstream,owns_hold:true}') || return 1
	# shellcheck disable=SC2016 # Markdown backticks are literal, not expansions.
	url=$(printf '<!-- aidevops:cloudron-release-approval %s -->\n<!-- aidevops:brief-schema=v2 -->\n## Release approval\n\n```json\n%s\n```\n\nPR number: %s; exact head: `%s`. Package: %s; upstream: %s.\n\n### Changelog\n%s\n\n### Verification\nAll PR checks passed at the recorded head:\n```json\n%s\n```\nPackage tests and preflight-release must be recorded in the PR.\n\n### Publication boundary\nThis is an approval-only issue, not a worker task. Do not auto-dispatch. Signed approval authorizes merging this exact head and its managed catalog workflow only; no deployment or unrelated publication.\n\nMaintainer command: `sudo aidevops approve issue <this-issue-number> %s`\n\n### Files Scope\n- `CloudronManifest.json`\n- `CloudronVersions.json`\n' "$version" "$metadata" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$repo" |
		gh_create_issue --repo "$repo" --title "Release ${repo##*/} v${version}" --body-file - --label release-approval-required --label no-auto-dispatch) || return 1
	[[ "$url" == https://* ]] || return 1
	# Supersede only unsigned requests. Verification errors never close one.
	while IFS= read -r older; do
		[[ -n "$older" ]] || continue
		rc=0
		verdict=$(release_verify "$repo" "$older") || rc=$?
		if [[ "$rc" -ne 0 && "$verdict" == NO_APPROVAL ]]; then
			release_comment "$repo" "$older" "Superseded by ${url}. No release was authorized by this unsigned request." || return 1
			gh issue close "$older" --repo "$repo" --reason 'not planned' || return 1
		fi
	done < <(jq -r --arg version "$version" '.[] | . as $issue | (.body | split("\n") | map(fromjson? | select(.schema == 1)) | .[0].version // "") as $old | select(($old | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (($old | split(".") | map(tonumber)) < ($version | split(".") | map(tonumber)))) | $issue.number' <<<"$issues")
	printf '%s\n' "$url"
	return 0
}

release_metadata() {
	local body="$1" repo="$2"
	printf '%s\n' "$body" | jq -Rsec --arg repo "$repo" --arg sha_pattern "$RELEASE_SHA_PATTERN" '
		split("\n") | map(fromjson? | select(type == "object" and .schema == 1))
		| select(length == 1) | .[0]
		| select(.repository == $repo and (.pr | type == "number" and . > 0 and floor == .)
		  and (.head | test($sha_pattern)) and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and .owns_hold == true)
	' || return 1
	return 0
}

release_published() {
	local repo="$1" version="$2" merge_sha="$3" catalog="" tag="" release="" tag_sha="" comparison="" runs=""
	runs=$(gh api "repos/${repo}/actions/workflows/cloudron-catalog-publish.yml/runs?branch=main&head_sha=${merge_sha}&per_page=100") || return 1
	jq -e --arg sha "$merge_sha" 'any(.workflow_runs[]; .head_sha == $sha and .status == "completed" and .conclusion == "success")' <<<"$runs" >/dev/null || return 1
	catalog=$(release_contents "$repo" CloudronVersions.json main) || return 1
	jq -e --arg version "$version" '.versions[$version].manifest.version == $version' <<<"$catalog" >/dev/null || return 1
	tag=$(gh api "repos/${repo}/git/ref/tags/v${version}") || return 1
	jq -e --arg sha_pattern "$RELEASE_SHA_PATTERN" '.object.sha | test($sha_pattern)' <<<"$tag" >/dev/null || return 1
	tag_sha=$(jq -r '.object.sha' <<<"$tag")
	if [[ "$(jq -r '.object.type' <<<"$tag")" == tag ]]; then
		tag=$(gh api "repos/${repo}/git/tags/${tag_sha}") || return 1
		tag_sha=$(jq -er '.object | select(.type == "commit") | .sha' <<<"$tag") || return 1
	fi
	comparison=$(gh api "repos/${repo}/compare/${merge_sha}...${tag_sha}" --jq '.status') || return 1
	[[ "$comparison" == ahead || "$comparison" == identical ]] || return 1
	local tagged_catalog=""
	tagged_catalog=$(release_contents "$repo" CloudronVersions.json "$tag_sha") || return 1
	jq -e --argjson tagged "$tagged_catalog" --arg version "$version" '.versions[$version] == $tagged.versions[$version]' <<<"$catalog" >/dev/null || return 1
	release=$(gh api "repos/${repo}/releases/tags/v${version}") || return 1
	jq -er --arg tag "v${version}" 'select(.draft == false and .tag_name == $tag) | .html_url | select(startswith("https://"))' <<<"$release" || return 1
	return 0
}

release_process_issue() {
	local repo="$1" issue="$2" apply="$3"
	local before="" after="" body="" pr="" head="" version="" snapshot="" checks="" release_url="" runs="" run_id="" rc=0
	local metadata=""
	local verdict="" run_status="" run_conclusion=""
	before=$(gh api "repos/${repo}/issues/${issue}") || return 1
	jq -e --arg label "$RELEASE_APPROVAL_LABEL" '.state == "open" and any(.labels[]; .name == $label)' <<<"$before" >/dev/null || return 1
	body=$(jq -r '.body' <<<"$before") || return 1
	metadata=$(release_metadata "$body" "$repo") || return 1
	verdict=$(release_verify "$repo" "$issue") || rc=$?
	#aidevops:trust-boundary — trusted authors and labels cannot replace a signature.
	if [[ "$rc" -ne 0 || "$verdict" != VERIFIED ]]; then
		printf '%s issue %s: approval %s; no merge\n' "$repo" "$issue" "$verdict"
		[[ "$verdict" == NO_APPROVAL || "$verdict" == STALE_APPROVAL ]] && return 0
		return 1
	fi
	after=$(gh api "repos/${repo}/issues/${issue}") || return 1
	[[ "$before" == "$after" ]] || return 1
	pr=$(jq -r '.pr' <<<"$metadata")
	head=$(jq -r '.head' <<<"$metadata")
	version=$(jq -r '.version' <<<"$metadata")
	local manifest=""
	manifest=$(release_contents "$repo" CloudronManifest.json "$head") || return 1
	jq -e --argjson metadata "$metadata" '.version == $metadata.version and .upstreamVersion == $metadata.upstream' <<<"$manifest" >/dev/null || return 1
	snapshot=$(release_pr "$repo" "$pr") || return 1
	if [[ "$(jq -r '.head.sha' <<<"$snapshot")" != "$head" ]]; then
		if [[ "$apply" == true ]]; then
			local marker="<!-- aidevops:cloudron-release-head-changed ${head} -->" comments=""
			comments=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate) || return 1
			if ! jq -se --arg marker "$marker" 'add | any(.[]; .body | contains($marker))' <<<"$comments" >/dev/null; then
				release_comment "$repo" "$issue" "${marker}
PR head changed after approval. No merge occurred. Update this issue's exact head and verification evidence, then run sudo aidevops approve issue ${issue} ${repo} again." || return 1
			fi
		fi
		return 0
	fi
	if [[ "$(jq -r '.state' <<<"$snapshot")" == open ]]; then
		release_publication_preflight "$repo" "$head" || return 1
	fi
	[[ "$apply" == true ]] || {
		printf 'Approved release %s v%s (dry run)\n' "$repo" "$version"
		return 0
	}
	if [[ "$(jq -r '.state' <<<"$snapshot")" == open ]]; then
		checks=$(release_checks "$repo" "$pr") || return 1
		: "$checks"
		verdict=$(release_verify "$repo" "$issue") || return 1
		[[ "$verdict" == VERIFIED ]] || return 1
		gh_pr_edit_safe "$pr" --repo "$repo" --remove-label hold-for-review >/dev/null || return 1
		#aidevops:trust-boundary — retain the signed SHA through readiness gates.
		if ! FULL_LOOP_EXPECTED_PR_HEAD_SHA="$head" "${SCRIPT_DIR}/full-loop-helper.sh" merge "$pr" "$repo" --squash; then
			gh_pr_edit_safe "$pr" --repo "$repo" --add-label hold-for-review >/dev/null || return 1
			return 1
		fi
		snapshot=$(release_pr "$repo" "$pr") || return 1
	fi
	jq -e --arg head "$head" '.merged == true and .head.sha == $head' <<<"$snapshot" >/dev/null || return 1
	# Later invocations resume verification without merging again. GH#35649
	# already owns catalog non-fast-forward recovery and dispatch reconciliation.
	local merge_sha=""
	merge_sha=$(jq -er '.merge_commit_sha' <<<"$snapshot") || return 1
	if ! release_url=$(release_published "$repo" "$version" "$merge_sha" 2>/dev/null); then
		runs=$(gh api "repos/${repo}/actions/workflows/cloudron-catalog-publish.yml/runs?branch=main&per_page=100") || return 1
		run_id=$(jq -r --arg sha "$merge_sha" '[.workflow_runs[] | select(.head_sha == $sha)] | sort_by(.id) | last | .id // empty' <<<"$runs") || return 1
		if [[ -z "$run_id" ]]; then
			printf 'Catalog run not yet visible for %s; retry next routine\n' "$repo"
			return 0
		fi
		# Never block on the run: catalog builds outlast any bounded watch.
		run_status=$(jq -r --arg id "$run_id" '[.workflow_runs[] | select((.id | tostring) == $id)] | first | .status // empty' <<<"$runs") || return 1
		run_conclusion=$(jq -r --arg id "$run_id" '[.workflow_runs[] | select((.id | tostring) == $id)] | first | .conclusion // empty' <<<"$runs") || return 1
		if [[ "$run_status" != completed ]]; then
			printf 'Catalog run %s still running for %s; verification resumes next routine\n' "$run_id" "$repo"
			return 0
		fi
		[[ "$run_conclusion" == success ]] || return 1
		release_url=$(release_published "$repo" "$version" "$merge_sha") || return 1
	fi
	# Close first: a failed close must not leave an approval-significant evidence
	# comment that makes the next attempt stale. No change to snapshot semantics.
	gh issue close "$issue" --repo "$repo" --reason completed || return 1
	release_comment "$repo" "$issue" "Published approved head ${head}: CloudronVersions.json contains ${version}; tag v${version} descends from merge ${merge_sha}; successful catalog run and GitHub release verified: ${release_url}" || return 1
	return 0
}

# Read-only authorization used by every full-loop merge transport while the
# dedicated PR label remains set. No environment variable grants this authority.
release_authorize() {
	local repo="$1" pr="$2" head="$3" issues="" issue="" current="" number=""
	local metadata=""
	local verdict=""
	release_authority "$repo" || return 1
	issues=$(release_issues "$repo") || return 1
	while IFS= read -r issue; do
		metadata=$(release_metadata "$(jq -r '.body' <<<"$issue")" "$repo") || continue
		jq -e --arg head "$head" --arg pr "$pr" '.head == $head and (.pr | tostring) == $pr' <<<"$metadata" >/dev/null || continue
		number=$(jq -r '.number' <<<"$issue")
		verdict=$(release_verify "$repo" "$number") || return 1
		[[ "$verdict" == VERIFIED ]] || return 1
		current=$(gh api "repos/${repo}/issues/${number}") || return 1
		jq -e --argjson original "$issue" --arg label "$RELEASE_APPROVAL_LABEL" '.state == "open" and .body == $original.body and any(.labels[]; .name == $label)' <<<"$current" >/dev/null || return 1
		return 0
	done < <(jq -c '.[]' <<<"$issues")
	return 1
}

release_process() {
	local apply="$1" repo="" issues="" issue="" failures=0 repos=""
	repos=$(jq -er '[.initialized_repos[] | select(.app_type == "cloudron-package" and .maintenance != false) | .slug] | unique | .[]' "$REPOS_FILE") || return 1
	while IFS= read -r repo; do
		release_authority "$repo" || {
			failures=$((failures + 1))
			continue
		}
		issues=$(release_issues "$repo") || {
			failures=$((failures + 1))
			continue
		}
		while IFS= read -r issue; do
			[[ -n "$issue" ]] || continue
			release_process_issue "$repo" "$issue" "$apply" || failures=$((failures + 1))
		done < <(jq -r '.[].number' <<<"$issues")
	done <<<"$repos"
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

main() {
	local command="${1:-help}"
	local arg2="${2:-}" arg3="${3:-}" arg4="${4:-}"
	case "$command" in
	authorize)
		[[ $# -eq 4 ]] || return 1
		release_authorize "$arg2" "$arg3" "$arg4" || return 1
		;;
	request)
		[[ $# -eq 3 ]] || return 1
		release_request "$arg2" "$arg3" || return 1
		;;
	process)
		[[ $# -eq 1 || ($# -eq 2 && "$arg2" == --apply) ]] || return 1
		local apply=false
		[[ "${2:-}" != --apply ]] || apply=true
		release_process "$apply" || return 1
		;;
	help | --help | -h)
		printf 'Usage: cloudron-release-approval-helper.sh request <repo> <pr> | process [--apply]\n'
		;;
	*) return 1 ;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
