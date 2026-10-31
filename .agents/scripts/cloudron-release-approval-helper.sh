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
RELEASE_WORKER_ORIGIN_LABEL='origin:worker'
RELEASE_HELD_PR_LIMIT=100

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
		jq -e 'any(.[]; .name == "CLOUDRON_RELEASE_PAT")' <<<"$secrets" >/dev/null || release_error "${repo} is missing CLOUDRON_RELEASE_PAT, which its main branch rules (required PRs or checks) need for the catalog push. Reuse the owner's purpose-scoped fine-grained CLOUDRON_RELEASE_PAT (Contents write and Metadata read only): add this repository to its selected access if needed, then set the repo secret from gopass with aidevops secret CLOUDRON_RELEASE_PAT -- sh -c 'printf %s \"\$CLOUDRON_RELEASE_PAT\" | gh secret set CLOUDRON_RELEASE_PAT --repo ${repo}'. See cloudron-app-publishing-skill.md for first-time or lost-value setup. Never put values in logs or chat. Configure before requesting approval or merging." || return 1
	fi
	caller=$(release_contents "$repo" .github/workflows/cloudron-catalog-publish.yml "$head") || release_error 'Unable to read the exact-head catalog workflow; no approval request or merge.' || return 1
	printf '%s\n' "$caller" | python3 "${SCRIPT_DIR}/cloudron-release-evidence.py" --check-caller || return 1
	return 0
}

release_request_body() {
	local repo="$1" pr="$2" sha="$3" version="$4" upstream="$5"
	local notes="$6" checks="$7" metadata="$8" command="$9"
	# shellcheck disable=SC2016 # Markdown backticks are literal, not expansions.
	printf '<!-- aidevops:cloudron-release-approval %s -->\n<!-- aidevops:brief-schema=v2 -->\n## Release approval\n\n```json\n%s\n```\n\nPR number: %s; exact head: `%s`. Package: %s; upstream: %s.\n\n### Changelog\n%s\n\n### Verification\nAll PR checks passed at the recorded head:\n```json\n%s\n```\nPackage tests and preflight-release must be recorded in the PR.\n\n### Publication boundary\nThis is an approval-only issue, not a worker task. Do not auto-dispatch. Signed approval authorizes merging this exact head and its managed catalog workflow only; no deployment or unrelated publication.\n\n%s\n\n### Files Scope\n- `CloudronManifest.json`\n- `CloudronVersions.json`\n' "$version" "$metadata" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$command"
	return 0
}

release_request() {
	local repo="$1" pr="$2"
	local snapshot="" sha="" manifest="" version="" upstream="" notes="" checks="" issues="" existing="" url="" older="" rc=0
	local issue="" metadata="" command="" existing_body="" maintainer_prefix='Maintainer command:'
	local verdict="" publication_body=""
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
		url=$(jq -r '.html_url' <<<"$existing") || return 1
		issue="${url##*/}"
		[[ "$url" == https://* && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
		command="sudo aidevops approve issue ${issue} ${repo}"
		existing_body=$(jq -r '.body' <<<"$existing") || return 1
		publication_body="${existing_body##*$'\n### Publication boundary\n'}"
		publication_body="${publication_body%%$'\n### Files Scope\n'*}"
		if [[ "$existing_body" != *'Request finalization pending.'* &&
			"$publication_body" == *$'\n\n'"${maintainer_prefix} \`${command}\`"$'\n' ]]; then
			printf '%s\nAPPROVAL_COMMAND=%s\n' "$url" "$command"
			return 0
		fi
		# Recover interrupted creation or legacy bodies only when unsigned.
		# Never invalidate a signature by silently rewriting an existing body.
		rc=0
		verdict=$(release_verify "$repo" "$issue") || rc=$?
		[[ "$rc" -ne 0 && "$verdict" == NO_APPROVAL ]] || release_error 'Existing request body needs finalization; signed or unverifiable requests must not be rewritten.' || return 1
		release_request_body "$repo" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$metadata" "${maintainer_prefix} \`${command}\`" |
			gh_issue_edit_safe "$issue" --repo "$repo" --body-file - >/dev/null || return 1
		printf '%s\nAPPROVAL_COMMAND=%s\n' "$url" "$command"
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
	url=$(release_request_body "$repo" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$metadata" 'Request finalization pending. Do not sign until the maintainer command appears.' |
		gh_create_issue --repo "$repo" --title "Release ${repo##*/} v${version}" --body-file - --label release-approval-required --label no-auto-dispatch) || return 1
	issue="${url##*/}"
	[[ "$url" == https://* && "$issue" =~ ^[1-9][0-9]*$ ]] || release_error 'Created issue URL has no valid issue number.' || return 1
	command="sudo aidevops approve issue ${issue} ${repo}"
	# Finalize the digest-bound body before exposing a signable command.
	release_request_body "$repo" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$metadata" "${maintainer_prefix} \`${command}\`" |
		gh_issue_edit_safe "$issue" --repo "$repo" --body-file - >/dev/null || return 1
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
	printf '%s\nAPPROVAL_COMMAND=%s\n' "$url" "$command"
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

# Held worker PRs: same-repository, non-draft, labelled for release approval.
# Prints a number-sorted array of {number, head, issues}. Fails closed on a
# malformed or possibly truncated page.
release_held_worker_prs() {
	local repo="$1" prs=""
	prs=$(gh pr list --repo "$repo" --state open --label "$RELEASE_APPROVAL_LABEL" \
		--limit "$RELEASE_HELD_PR_LIMIT" \
		--json number,isDraft,isCrossRepository,headRefOid,labels,closingIssuesReferences) || return 1
	jq -ec --arg origin "$RELEASE_WORKER_ORIGIN_LABEL" --argjson limit "$RELEASE_HELD_PR_LIMIT" '
		if type == "array" and length < $limit then
			[.[] | select(.isDraft == false and .isCrossRepository == false
				and any(.labels[]; .name == $origin))
			 | {number, head: .headRefOid, issues: [.closingIssuesReferences[].number]}]
			| sort_by(.number)
		else error("invalid held PR page") end' <<<"$prs" || return 1
	return 0
}

# Print "<issue>\t<fingerprint>\t<state>" for the PR's single package-monitor
# upstream finding. Returns 2 when there is none or more than one, 1 on error.
release_upstream_finding() {
	local repo="$1" pr_json="$2" number='' issue='' finding='' found=''
	while IFS= read -r number; do
		[[ -n "$number" ]] || continue
		[[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
		issue=$(gh api "repos/${repo}/issues/${number}") || return 1
		#aidevops:trust-boundary — only a trusted author's exact own-line monitor
		# marker identifies a finding; copied markers on outsider issues never do.
		# Binding the capture drops marker-less issues: capture emits nothing, so
		# an array literal would silently shift .state into the fingerprint slot.
		finding=$(jq -r --arg number "$number" '
			select(.pull_request == null and ((.author_association // "") | test("^(OWNER|MEMBER)$")))
			| ((.body // "") | capture("(?m)^<!-- aidevops:cloudron-package-monitor (?<fp>upstream-(v[0-9]+\\.[0-9]+\\.[0-9]+|commit-[a-f0-9]{40})) -->$").fp) as $fp
			| [$number, $fp, .state] | @tsv' <<<"$issue") || return 1
		[[ -n "$finding" ]] || continue
		[[ -z "$found" ]] || return 2
		found="$finding"
	done < <(jq -r '.issues[]' <<<"$pr_json")
	[[ -n "$found" ]] || return 2
	printf '%s\n' "$found"
	return 0
}

# Succeeds when semantic version $1 is strictly newer than $2.
release_version_newer() {
	local newer="$1" older="$2"
	[[ "$newer" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$older" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	jq -en --arg newer "$newer" --arg older "$older" \
		'($newer | split(".") | map(tonumber)) > ($older | split(".") | map(tonumber))' >/dev/null || return 1
	return 0
}

# Succeeds when main's manifest already bundles the finding's upstream.
release_finding_on_main() {
	local fingerprint="$1" main_upstream="$2"
	case "$fingerprint" in
	upstream-v*)
		[[ "${fingerprint#upstream-v}" != "$main_upstream" ]] || return 0
		release_version_newer "$main_upstream" "${fingerprint#upstream-v}" || return 1
		;;
	upstream-commit-*)
		[[ ${#main_upstream} -ge 7 && "${fingerprint#upstream-commit-}" == "$main_upstream"* ]] || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

# Succeeds when finding $1/$2 (number/fingerprint) subsumes finding $3/$4.
release_finding_newer() {
	local new_number="$1" new_fp="$2" old_number="$3" old_fp="$4"
	case "${new_fp}:${old_fp}" in
	upstream-v*:upstream-v*)
		release_version_newer "${new_fp#upstream-v}" "${old_fp#upstream-v}" || return 1
		;;
	upstream-commit-*:upstream-commit-*)
		[[ "$new_fp" != "$old_fp" && "$new_number" -gt "$old_number" ]] || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

# Print the open approval-request issue numbers whose metadata targets PR $3.
release_requests_for_pr() {
	local repo="$1" issues="$2" pr="$3" issue='' metadata='' numbers=''
	while IFS= read -r issue; do
		[[ -n "$issue" ]] || continue
		metadata=$(release_metadata "$(jq -r '.body // ""' <<<"$issue")" "$repo") || continue
		jq -e --argjson pr "$pr" '.pr == $pr' <<<"$metadata" >/dev/null || continue
		numbers="${numbers}$(jq -r '.number' <<<"$issue") "
	done < <(jq -c '.[]' <<<"$issues")
	printf '%s' "$numbers"
	return 0
}

# Annotate held PRs with their upstream finding and whether main bundles it.
release_held_findings() {
	local repo="$1" held="$2" main_upstream="$3"
	local pr_json='' finding='' rc=0 out='[]' number='' fingerprint='' state='' on_main=false
	while IFS= read -r pr_json; do
		[[ -n "$pr_json" ]] || continue
		rc=0
		finding=$(release_upstream_finding "$repo" "$pr_json") || rc=$?
		[[ "$rc" -ne 1 ]] || return 1
		number='' fingerprint='' state='' on_main=false
		if [[ "$rc" -eq 0 ]]; then
			IFS=$'\t' read -r number fingerprint state <<<"$finding"
			if release_finding_on_main "$fingerprint" "$main_upstream"; then
				on_main=true
			fi
		fi
		out=$(jq -c --argjson pr "$pr_json" --arg number "$number" --arg fp "$fingerprint" \
			--arg state "$state" --argjson on_main "$on_main" \
			'. + [$pr + {finding: $number, fingerprint: $fp, finding_state: $state, on_main: $on_main}]' <<<"$out") || return 1
	done < <(jq -c '.[]' <<<"$held")
	printf '%s\n' "$out"
	return 0
}

# Request approval for a held PR once its checks are terminal-green.
# Returns 0 when requested (or would be, in a dry run), 3 while waiting.
release_request_held() {
	local repo="$1" apply="$2" pr="$3"
	if ! release_checks "$repo" "$pr" >/dev/null 2>&1; then
		printf '%s PR #%s: release approval request waits for terminal-green checks\n' "$repo" "$pr"
		return 3
	fi
	if [[ "$apply" != true ]]; then
		printf '%s PR #%s: would request release approval (dry run)\n' "$repo" "$pr"
		return 0
	fi
	release_request "$repo" "$pr" || return 1
	return 0
}

# Close one obsolete held bump with its unsigned requests and finding.
# Args: repo apply issues pr head finding finding_state reason
release_supersede_held_pr() {
	local repo="$1" apply="$2" issues="$3" pr="$4" head="$5" finding="$6" finding_state="$7" reason="$8"
	local requests='' request='' verdict='' rc=0 snapshot=''
	requests=$(release_requests_for_pr "$repo" "$issues" "$pr") || return 1
	for request in $requests; do
		rc=0
		verdict=$(release_verify "$repo" "$request") || rc=$?
		#aidevops:trust-boundary — signed, stale or unverifiable approvals are
		# maintainer authority; automation never supersedes them.
		if [[ "$rc" -eq 0 || "$verdict" != NO_APPROVAL ]]; then
			printf '%s PR #%s: retained; approval request #%s is %s\n' "$repo" "$pr" "$request" "${verdict:-unverifiable}"
			return 0
		fi
	done
	if [[ "$apply" != true ]]; then
		printf '%s PR #%s: would supersede (%s) (dry run)\n' "$repo" "$pr" "$reason"
		return 0
	fi
	snapshot=$(gh api "repos/${repo}/pulls/${pr}") || return 1
	#aidevops:trust-boundary — re-read before closing: only an unchanged,
	# same-repository, trusted worker PR that is still held may be superseded.
	if ! jq -e --arg repo "$repo" --arg head "$head" --arg approval "$RELEASE_APPROVAL_LABEL" \
		--arg origin "$RELEASE_WORKER_ORIGIN_LABEL" --arg open_state open '
		.state == $open_state and .merged == false and .head.sha == $head
		and .head.repo.full_name == $repo and .base.repo.full_name == $repo
		and ((.author_association // "") | test("^(OWNER|MEMBER)$"))
		and any(.labels[]; .name == $approval) and any(.labels[]; .name == $origin)' <<<"$snapshot" >/dev/null; then
		printf '%s PR #%s: retained; PR changed before supersession\n' "$repo" "$pr"
		return 0
	fi
	# Close before commenting so an interrupted run never repeats a comment.
	for request in $requests; do
		gh issue close "$request" --repo "$repo" --reason 'not planned' >/dev/null || return 1
		release_comment "$repo" "$request" "Superseded: ${reason}. No release was authorized by this unsigned request." || return 1
	done
	if [[ "$finding_state" == open ]]; then
		gh issue close "$finding" --repo "$repo" --reason 'not planned' >/dev/null || return 1
		release_comment "$repo" "$finding" "Superseded: ${reason}. Closed with its unsigned bump PR #${pr}; no release was authorized." || return 1
	fi
	gh_pr_close_safe "$pr" --repo "$repo" >/dev/null || return 1
	printf 'Superseded: %s. This unsigned upstream bump is obsolete; no release was authorized. The branch is retained for audit.\n' "$reason" |
		gh_pr_comment "$pr" --repo "$repo" --body-file - >/dev/null || return 1
	printf '%s PR #%s: superseded (%s)\n' "$repo" "$pr" "$reason"
	return 0
}

# Pick the newest held PR main does not already bundle, and request its approval
# when none is open. Prints "<pr>|<fingerprint>|<finding>|<requested>"; a
# non-whitespace delimiter keeps empty fields (non-upstream PRs) in place.
release_held_target() {
	local repo="$1" apply="$2" issues="$3" entries="$4"
	local target_json='' target='' requests='' requested=false rc=0
	target_json=$(jq -c '[.[] | select(.on_main | not)] | last // empty' <<<"$entries") || return 1
	[[ -n "$target_json" ]] || return 0
	target=$(jq -r '.number' <<<"$target_json")
	requests=$(release_requests_for_pr "$repo" "$issues" "$target") || return 1
	if [[ -n "$requests" ]]; then
		requested=true
	else
		release_request_held "$repo" "$apply" "$target" >&2 || rc=$?
		[[ "$rc" -ne 1 ]] || return 1
		[[ "$rc" -ne 0 ]] || requested=true
	fi
	jq -r --arg requested "$requested" '[(.number | tostring), .fingerprint, .finding, $requested] | join("|")' <<<"$target_json" || return 1
	return 0
}

# GH#36268: a worker's release handoff cannot request approval while PR checks
# are pending, and defers to this routine. Request approval for the newest held
# worker PR once its checks pass, then supersede older unsigned upstream bumps
# that main or the requested PR already bundles. Signed approvals, human PRs
# and non-upstream PRs are never superseded.
release_reconcile_held() {
	local repo="$1" apply="$2" issues="$3"
	local held='' main_upstream='' entries='' target_line='' target='' target_fp='' target_finding='' requested=false
	local number='' head='' finding='' fingerprint='' state='' on_main='' reason='' failures=0
	held=$(release_held_worker_prs "$repo") || return 1
	[[ "$(jq 'length' <<<"$held")" -gt 0 ]] || return 0
	main_upstream=$(release_contents "$repo" CloudronManifest.json main |
		jq -er '.upstreamVersion | select(type == "string" and length > 0) | ltrimstr("v")') || return 1
	entries=$(release_held_findings "$repo" "$held" "$main_upstream") || return 1
	target_line=$(release_held_target "$repo" "$apply" "$issues" "$entries") || return 1
	[[ -z "$target_line" ]] || IFS='|' read -r target target_fp target_finding requested <<<"$target_line"
	if [[ "$apply" == true && "$requested" == true ]]; then
		# A request created above must be visible to the signed-approval check.
		issues=$(release_issues "$repo") || return 1
	fi
	while IFS='|' read -r number head finding fingerprint state on_main; do
		[[ -n "$number" && "$number" != "$target" && -n "$fingerprint" ]] || continue
		reason=""
		if [[ "$on_main" == true ]]; then
			reason="main already bundles upstream ${main_upstream}"
		elif [[ "$requested" == true && "$number" -lt "$target" && -n "$target_fp" ]] &&
			release_finding_newer "$target_finding" "$target_fp" "$finding" "$fingerprint"; then
			reason="PR #${target} bundles newer ${target_fp#upstream-} (finding #${target_finding})"
		fi
		[[ -n "$reason" ]] || continue
		release_supersede_held_pr "$repo" "$apply" "$issues" "$number" "$head" "$finding" "$state" "$reason" ||
			failures=$((failures + 1))
	done < <(jq -r '.[] | [(.number | tostring), .head, .finding, .fingerprint, .finding_state, (.on_main | tostring)] | join("|")' <<<"$entries")
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

release_process() {
	local apply="$1" repo_filter="${2:-}" issue_filter="${3:-}"
	local repo="" issues="" issue="" failures=0 repos=""
	if [[ -n "$repo_filter" ]]; then
		repos="$repo_filter"
	else
		repos=$(jq -er '[.initialized_repos[] | select(.app_type == "cloudron-package" and .maintenance != false) | .slug] | unique | .[]' "$REPOS_FILE") || return 1
	fi
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
			[[ -z "$issue_filter" || "$issue" == "$issue_filter" ]] || continue
			release_process_issue "$repo" "$issue" "$apply" || failures=$((failures + 1))
		done < <(jq -r '.[].number' <<<"$issues")
		# A single-issue run targets one approval; held-PR reconciliation is repo-wide.
		if [[ -z "$issue_filter" ]]; then
			release_reconcile_held "$repo" "$apply" "$issues" || failures=$((failures + 1))
		fi
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
		local apply=false repo_filter="" issue_filter=""
		shift
		while [[ $# -gt 0 ]]; do
			local option="$1" value="${2:-}"
			case "$option" in
			--apply)
				apply=true
				shift
				;;
			--repo)
				[[ $# -ge 2 && -z "$repo_filter" ]] || return 1
				repo_filter="$value"
				[[ "$repo_filter" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_error 'Repository must be in owner/repo format.' || return 1
				shift 2
				;;
			--issue)
				[[ $# -ge 2 && -z "$issue_filter" ]] || return 1
				issue_filter="$value"
				[[ "$issue_filter" =~ ^[1-9][0-9]*$ ]] || release_error 'Issue number must be a positive integer.' || return 1
				shift 2
				;;
			*) return 1 ;;
			esac
		done
		release_process "$apply" "$repo_filter" "$issue_filter" || return 1
		;;
	help | --help | -h)
		printf 'Usage: cloudron-release-approval-helper.sh request <repo> <pr> | process [--repo owner/repo] [--issue N] [--apply]\n'
		;;
	*) return 1 ;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
