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
# GH#37697: one signed standing policy per package repo authorizes routine
# upstream bumps (cloudron_routine_bump.py) without a per-release signature.
RELEASE_POLICY_LABEL='release-standing-policy'
RELEASE_POLICY_MARKER='<!-- aidevops:cloudron-release-policy v1 -->'
RELEASE_POLICY_KIND='cloudron-standing-upstream-release'
RELEASE_POLICY_MAX_FILES=20
RELEASE_SIGNED_AUTHORITY='signed approval'
RELEASE_TRUSTED_AUTHOR='^(OWNER|MEMBER)$'
RELEASE_RESOLVED_AUTHORITY=''

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

# Raw REST PR snapshot; callers apply their own trust checks.
release_pr_raw() {
	local repo="$1" pr="$2"
	gh api "repos/${repo}/pulls/${pr}" || return 1
	return 0
}

release_pr() {
	local repo="$1" pr="$2" snapshot=""
	snapshot=$(release_pr_raw "$repo" "$pr") || release_error "Unable to read PR #${pr} in ${repo}." || return 1
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

# Label inventory/create runners for managed_labels_ensure_release_approval_set.
release_label_names() {
	local repo="$1"
	gh api "repos/${repo}/labels?per_page=100" --paginate --jq '.[].name' || return 1
	return 0
}

release_label_create() {
	local repo="$1" name="$2" description="$3" color="$4"
	gh label create "$name" --repo "$repo" --description "$description" --color "$color" || return 1
	return 0
}

# GH#36292: managed package repos need not carry aidevops system labels, and
# gh_create_issue never creates caller-supplied labels (GH#34003). Provision
# every label a request applies before the first write, so a missing label can
# neither strand a half-applied hold nor fail issue creation. A converged repo
# costs one label read and no writes.
release_ensure_labels() {
	local repo="$1"
	managed_labels_ensure_release_approval_set "$repo" release_label_names release_label_create ||
		release_error "Unable to provision release approval labels in ${repo}; no approval request." || return 1
	return 0
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
	printf '<!-- aidevops:cloudron-release-approval %s -->\n<!-- aidevops:brief-schema=v2 -->\n## Release approval\n\n```json\n%s\n```\n\nPR number: %s; exact head: `%s`. Package: %s; upstream: %s.\n\n### Changelog\n%s\n\n### Verification\nAll PR checks passed at the recorded head:\n```json\n%s\n```\nPackage tests and preflight-release must be recorded in the PR.\n\n### Publication boundary\nThis is an approval-only issue, not a worker task. Do not auto-dispatch. Signed approval authorizes merging this exact head and its managed catalog workflow only; no deployment or unrelated publication. A routine upstream bump may instead be released under the signed standing release policy of this repository (`release-standing-policy`); without one, sign this request.\n\n%s\n\n### Files Scope\n- `CloudronManifest.json`\n- `CloudronVersions.json`\n' "$version" "$metadata" "$pr" "$sha" "$version" "$upstream" "$notes" "$checks" "$command"
	return 0
}

release_request_interrupted() {
	local repo="$1" pr="$2"
	printf 'ERROR: Release approval request interrupted; leave BOTH release-approval-required and hold-for-review on PR #%s. Retry after API recovery: gh pr edit %s --repo %s --add-label release-approval-required --add-label hold-for-review; cloudron-release-approval-helper.sh request %s %s\n' "$pr" "$pr" "$repo" "$repo" "$pr" >&2
	return 4
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
	#aidevops:trust-boundary — a bare hold belongs to another review workflow.
	jq -e --arg label "$RELEASE_APPROVAL_LABEL" '(all(.labels[]; .name != "hold-for-review") or any(.labels[]; .name == $label)) and .auto_merge == null' <<<"$snapshot" >/dev/null || release_error 'Resolve existing PR hold/auto-merge before requesting a release.' || return 1
	issues=$(release_issues "$repo") || { release_request_interrupted "$repo" "$pr"; return 4; }
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
	release_ensure_labels "$repo" || { release_request_interrupted "$repo" "$pr"; return 4; }
	gh_pr_edit_safe "$pr" --repo "$repo" --add-label release-approval-required --add-label hold-for-review >/dev/null || { release_request_interrupted "$repo" "$pr"; return 4; }
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
	done < <(jq -r --arg version "$version" '.[] | . as $issue | (.body | split("\n") | map(fromjson? | select(type == "object" and .schema == 1)) | .[0].version // "") as $old | select(($old | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (($old | split(".") | map(tonumber)) < ($version | split(".") | map(tonumber)))) | $issue.number' <<<"$issues")
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

# ── Standing release policy (GH#37697) ──────────────────────────────────────

release_policy_body() {
	local repo="$1" command="$2" policy=""
	local mode="${3:-semver}" upstream="${4:-}"
	# Inserted check lines: single-quoted or expansion-free double-quoted
	# changelog assertions only (\x22 ", \x24 $, \x27 ', \x60 backtick).
	local insertion='\t*assert_contains CHANGELOG(\.md)? (\x27[^\x27\x24\x60\\]*\x27|\x22([^\x22\x24\x60\\]|\\\x60)*\x22) \|\| return 1'
	policy=$(jq -cn --arg repo "$repo" --arg kind "$RELEASE_POLICY_KIND" --arg insertion "$insertion" \
		'{schema:1,kind:$kind,repository:$repo,changelog_files:["CHANGELOG","CHANGELOG.md"],pinned_files:["Dockerfile"],check_files:["test/package-test.sh"],check_insertion_pattern:$insertion}') || return 1
	case "$mode" in
	semver) [[ -z "$upstream" ]] || return 1 ;;
	commits)
		[[ "$upstream" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || return 1
		policy=$(jq -c --arg upstream "$upstream" '. + {upstream_mode:"commits",upstream_repository:$upstream}' <<<"$policy") || return 1
		# This additional signed text replaces the semver boundary only for an
		# explicit commit policy. Legacy semver bodies remain byte-for-byte stable.
		# shellcheck disable=SC2016 # Markdown backticks are literal.
		printf 'Commit policy: upstream `%s`; SHA prefixes of 7–40 hex characters must resolve to the exact open trusted finding commit in this upstream. GitHub compare must prove strict forward ancestry (ahead); commits have no major boundary. All other routine-bump rules below still apply; the same-major version clause is replaced by this ancestry rule. A new signature is required for this mode.\n\n' "$upstream"
		;;
	*) return 1 ;;
	esac
	# shellcheck disable=SC2016 # Markdown backticks are literal, not expansions.
	printf '%s\n## Standing release policy\n\n```json\n%s\n```\n\nSigning this issue authorizes routine `r924` to merge and publish **routine upstream bumps** of %s without a per-release signature. A routine bump, checked at its exact PR head:\n\n- links exactly one open, trusted upstream monitor finding, and `upstreamVersion` equals that finding within the same major version;\n- increments only the package patch version; no other `CloudronManifest.json` field changes;\n- modifies in place only the manifest, the changelog files above (additions only), the pinned files (whole-token old to new version substitution only) and the check files (version substitution of existing lines, plus inserted lines that fully match `check_insertion_pattern`);\n- comes from a same-repository OWNER/MEMBER PR against `main` with terminal-green checks, including preflight, no auto-merge and no `needs-maintainer-review`.\n\nEvery other release still needs `sudo aidevops approve issue <request> %s` on its release request. Close this issue to revoke the policy; any edit or comment makes the signature stale. Add `needs-maintainer-review` to a release PR to stop the policy for that PR.\n\n### Publication boundary\nThis is an approval-only issue, not a worker task. Do not auto-dispatch. The policy never deploys an app, changes credentials or branch protection, or authorizes unrelated publication.\n\n%s\n' \
		"$RELEASE_POLICY_MARKER" "$policy" "$repo" "$repo" "$command"
	return 0
}

release_policy_metadata() {
	local body="$1" repo="$2"
	printf '%s\n' "$body" | jq -Rsec --arg repo "$repo" --arg kind "$RELEASE_POLICY_KIND" '
		split("\n") | map(fromjson? | objects | select(.schema == 1))
		| select(length == 1) | .[0]
		| select(.kind == $kind and .repository == $repo)
	' || return 1
	return 0
}

# Print the single open policy issue. Returns 2 when there is none; more than
# one candidate is ambiguous and fails closed.
release_policy_issue() {
	local repo="$1" pages="" candidates="" count=""
	pages=$(gh api "repos/${repo}/issues?state=open&labels=${RELEASE_POLICY_LABEL}&per_page=100" --paginate) || return 1
	candidates=$(jq -sc --arg marker "$RELEASE_POLICY_MARKER" \
		'add // [] | map(select(.pull_request == null and ((.body // "") | split("\n") | map(rtrimstr("\r")) | index($marker) != null)))' <<<"$pages") || return 1
	count=$(jq 'length' <<<"$candidates") || return 1
	[[ "$count" -ne 0 ]] || return 2
	[[ "$count" -eq 1 ]] || release_error "Multiple open standing release policies in ${repo}; none applies." || return 1
	jq -c '.[0]' <<<"$candidates" || return 1
	return 0
}

release_issue_snapshot() {
	local repo="$1" number="$2"
	gh api "repos/${repo}/issues/${number}" || return 1
	return 0
}

# Print "<issue>\t<policy-json>" for a policy carrying a VERIFIED signature.
release_policy_active() {
	local repo="$1" issue='' number='' policy='' verdict='' rc=0 current=''
	issue=$(release_policy_issue "$repo") || return 1
	#aidevops:trust-boundary — a maintainer-authored policy with a VERIFIED
	# signature is the only standing authority; labels and authors never are.
	jq -e --arg trusted "$RELEASE_TRUSTED_AUTHOR" '(.author_association // "") | test($trusted)' <<<"$issue" >/dev/null || return 1
	number=$(jq -r '.number' <<<"$issue")
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
	verdict=$(release_verify "$repo" "$number") || rc=$?
	[[ "$rc" -eq 0 && "$verdict" == VERIFIED ]] || return 1
	# Parse only a re-read that is unchanged since the listing and still open
	# and labelled, so a body swapped around verification is never used.
	current=$(release_issue_snapshot "$repo" "$number") || return 1
	jq -e --argjson listed "$issue" --arg label "$RELEASE_POLICY_LABEL" \
		'.state == $listed.state and .closed_at == null and .body == $listed.body and .updated_at == $listed.updated_at
		 and any(.labels[]; .name == $label)' <<<"$current" >/dev/null || return 1
	policy=$(release_policy_metadata "$(jq -r '.body // ""' <<<"$current")" "$repo") || return 1
	printf '%s\t%s\n' "$number" "$policy"
	return 0
}

# Exact bytes (base64) of a file at a commit; empty or non-base64 fails.
release_raw_contents() {
	local repo="$1" path="$2" sha="$3" content=""
	content=$(gh api "repos/${repo}/contents/${path}?ref=${sha}" --jq 'select(.type == "file" and .encoding == "base64") | .content') || return 1
	[[ -n "$content" ]] || return 1
	printf '%s\n' "$content"
	return 0
}

# Fetch proof from the signed upstream, not a PR-controlled URL or repository.
release_commit_proof() {
	local repo="$1" policy="$2" finding="$3" contents="$4" issue="$5"
	local upstream='' old='' new='' base='' head='' comparison='' snapshot='' versions=''
	upstream=$(jq -er '.upstream_repository | strings | select(test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$"))' <<<"$policy") || return 1
	versions=$(jq -er '."CloudronManifest.json" | [.base, .head] | map(@base64d | fromjson | .upstreamVersion | strings | select(test("^[a-fA-F0-9]{7,40}$"))) | select(length == 2) | @tsv' <<<"$contents") || return 1
	IFS=$'\t' read -r old new <<<"$versions"
	# aidevops:trust-boundary — bind the trusted monitor's structured summary
	# to the signed upstream and full finding SHA, not merely a copied fingerprint.
	snapshot=$(release_issue_snapshot "$repo" "$issue") || return 1
	jq -e --arg upstream "$upstream" --arg sha "$finding" --arg trusted "$RELEASE_TRUSTED_AUTHOR" --arg state open '
		select(.state == $state and (.author_association | test($trusted)))
		| .body | split("\n")
		| any(. == ("<!-- aidevops:cloudron-package-monitor upstream-commit-" + $sha + " -->"))
		  and (map(capture("^Upstream `(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)` branch `[^`]+` head is `(?<sha>[a-f0-9]{40})` ")?)
		       | length == 1 and .[0].repo == $upstream and .[0].sha == $sha)' <<<"$snapshot" >/dev/null || return 1
	base=$(gh api "repos/${upstream}/commits/${old}" --jq '.sha') || return 1
	head=$(gh api "repos/${upstream}/commits/${new}" --jq '.sha') || return 1
	[[ "$base" =~ $RELEASE_SHA_PATTERN && "$head" == "$finding" ]] || return 1
	comparison=$(gh api "repos/${upstream}/compare/${base}...${head}") || return 1
	jq -cn --arg repo "$upstream" --arg base "$base" --arg head "$head" --argjson comparison "$comparison" \
		'{repository:$repo,base:$base,head:$head,status:$comparison.status,merge_base:$comparison.merge_base_commit.sha}' || return 1
	return 0
}

# Print the policy issue number when the signed standing policy authorizes the
# open PR $2 at exact head $3 as a routine upstream bump. Any error fails closed.
release_policy_authorizes() {
	local repo="$1" pr="$2" head="$3"
	local active='' number='' policy='' snapshot='' view='' finding='' fingerprint='' compare='' merge_base=''
	local files='' contents='{}' path='' base_content='' head_content='' document='' verdict='' rc=0
	local finding_state='' main_sha='' mode='' finding_number='' upstream_proof='null' finding_version=''
	active=$(release_policy_active "$repo") || return 1
	IFS=$'\t' read -r number policy <<<"$active"
	snapshot=$(release_pr "$repo" "$pr" 2>/dev/null) || return 1
	#aidevops:trust-boundary — only the exact open head of a trusted author's PR
	# that still carries the release hold, with no auto-merge and no human brake.
	jq -e --arg head "$head" --arg trusted "$RELEASE_TRUSTED_AUTHOR" --arg hold "$RELEASE_APPROVAL_LABEL" \
		'.closed_at == null and .merged == false and .head.sha == $head and .auto_merge == null
		and ((.author_association // "") | test($trusted))
		and any(.labels[]; .name == $hold) and all(.labels[]; .name != "needs-maintainer-review")' <<<"$snapshot" >/dev/null || return 1
	release_checks "$repo" "$pr" >/dev/null || return 1
	view=$(gh pr view "$pr" --repo "$repo" --json closingIssuesReferences,headRefOid) || return 1
	jq -e --arg head "$head" '.headRefOid == $head' <<<"$view" >/dev/null || return 1
	finding=$(release_upstream_finding "$repo" "$(jq -c '{issues: [.closingIssuesReferences[].number]}' <<<"$view")") || return 1
	IFS=$'\t' read -r finding_number fingerprint finding_state <<<"$finding"
	# A finding the maintainer closed (rejected or superseded) never authorizes.
	[[ "$finding_state" == open ]] || return 1
	mode=$(jq -r '.upstream_mode // "semver"' <<<"$policy") || return 1
	case "${mode}:${fingerprint}" in
	semver:upstream-v*) finding_version="${fingerprint#upstream-v}" ;;
	commits:upstream-commit-*) finding_version="${fingerprint#upstream-commit-}" ;;
	*) return 1 ;;
	esac
	# Squash merge applies the merge-base diff; main moving does not change it.
	# Resolve the branch to a SHA so a same-named tag cannot shift the base.
	main_sha=$(gh api "repos/${repo}/git/ref/heads/main" --jq '.object.sha') || return 1
	[[ "$main_sha" =~ $RELEASE_SHA_PATTERN ]] || return 1
	compare=$(gh api "repos/${repo}/compare/${main_sha}...${head}") || return 1
	merge_base=$(jq -er --arg sha_pattern "$RELEASE_SHA_PATTERN" '.merge_base_commit.sha | select(test($sha_pattern))' <<<"$compare") || return 1
	files=$(jq -ec --argjson max "$RELEASE_POLICY_MAX_FILES" '.files | arrays | select(length > 0 and length <= $max)
		| map({filename, status, additions, deletions} + (if has("previous_filename") then {previous_filename} else {} end))' <<<"$compare") || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		base_content=$(release_raw_contents "$repo" "$path" "$merge_base") || return 1
		head_content=$(release_raw_contents "$repo" "$path" "$head") || return 1
		contents=$(jq -c --arg path "$path" --arg base "$base_content" --arg head "$head_content" \
			'. + {($path): {base: $base, head: $head}}' <<<"$contents") || return 1
	done < <(jq -r --argjson policy "$policy" '.[].filename | select(. == "CloudronManifest.json" or (. as $name | (($policy.pinned_files // []) + ($policy.check_files // [])) | index($name) != null))' <<<"$files")
	if [[ "$mode" == commits ]]; then
		upstream_proof=$(release_commit_proof "$repo" "$policy" "$finding_version" "$contents" "$finding_number") || return 1
	fi
	document=$(jq -cn --argjson policy "$policy" --arg finding "$finding_version" --argjson files "$files" --argjson contents "$contents" --argjson proof "$upstream_proof" \
		'{policy: $policy, finding_upstream: $finding, upstream_proof: $proof, files: $files, contents: $contents}') || return 1
	verdict=$(printf '%s\n' "$document" | python3 "${SCRIPT_DIR}/cloudron_routine_bump.py" --repository "$repo") || rc=$?
	if [[ "$rc" -ne 0 || "$verdict" != ROUTINE_BUMP ]]; then
		printf '%s PR #%s: standing policy #%s does not apply (%s)\n' "$repo" "$pr" "$number" "${verdict:-predicate error}" >&2
		return 1
	fi
	# Revocation (close, edit or comment) during the proof must still win.
	[[ "$(release_policy_active "$repo")" == "$active" ]] || return 1
	printf '%s\n' "$number"
	return 0
}

# Trusted record of the authority that drove a merge, written by the pass that
# merged so a later pass can report it. Evidence only; it authorizes nothing.
# Prints the recorded authority (e.g. "policy #50") for the exact head, or nothing.
release_recorded_merge_authority() {
	local repo="$1" issue="$2" head="$3" comments=''
	comments=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate 2>/dev/null) || return 0
	#aidevops:trust-boundary — only an OWNER/MEMBER-authored marker for the exact head counts.
	jq -rs --arg head "$head" --arg trusted "$RELEASE_TRUSTED_AUTHOR" '
		[add // [] | .[] | select((.author_association // "") | test($trusted))
		 | ((.body // "") | capture("(?m)^<!-- aidevops:cloudron-release-merge-authority (?<head>[a-f0-9]{40}) (?<kind>policy #[1-9][0-9]*) -->$")?)
		 | select(. != null and .head == $head) | .kind] | last // empty' <<<"$comments" 2>/dev/null || true
	return 0
}

# Authority for an unsigned request: the policy for an open PR, or an already
# merged exact head (publication verification only; nothing is authorized).
release_policy_for_request() {
	local repo="$1" pr="$2" head="$3" issue="${4:-}" snapshot='' number='' recorded=''
	snapshot=$(release_pr "$repo" "$pr" 2>/dev/null) || return 1
	if jq -e --arg head "$head" '.merged == true and .head.sha == $head' <<<"$snapshot" >/dev/null; then
		# Nothing is authorized here, so the evidence must not claim the policy
		# unless a trusted record shows the policy drove the earlier merge.
		release_policy_active "$repo" >/dev/null || return 1
		[[ -z "$issue" ]] || recorded=$(release_recorded_merge_authority "$repo" "$issue" "$head")
		if [[ -n "$recorded" ]]; then
			printf 'standing %s (merge recorded at %s); publication verified\n' "$recorded" "$head"
		else
			printf 'publication verification only; merge authority not recorded\n'
		fi
		return 0
	fi
	number=$(release_policy_authorizes "$repo" "$pr" "$head") || return 1
	printf 'standing policy #%s\n' "$number"
	return 0
}

# Under an active policy, close an unsigned request whose PR head moved so the
# held-PR reconciliation files a fresh exact-head request. Signed or stale
# requests keep the existing re-approval path.
release_retire_moved_request() {
	local repo="$1" issue="$2" pr="$3" head="$4" snapshot='' verdict='' rc=0
	snapshot=$(release_pr "$repo" "$pr" 2>/dev/null) || return 0
	jq -e --arg head "$head" '.closed_at == null and .merged == false and .head.sha != $head' <<<"$snapshot" >/dev/null || return 0
	release_policy_active "$repo" >/dev/null || return 0
	# Re-verify immediately before closing: a request signed meanwhile keeps
	# the per-release re-approval path.
	verdict=$(release_verify "$repo" "$issue") || rc=$?
	[[ "$rc" -ne 0 && "$verdict" == NO_APPROVAL ]] || return 0
	gh issue close "$issue" --repo "$repo" --reason 'not planned' >/dev/null || return 1
	release_comment "$repo" "$issue" "Superseded: PR #${pr} head changed from ${head}. No release was authorized by this unsigned request; a fresh exact-head request follows under the standing release policy." || return 1
	printf '%s issue %s: unsigned request retired after PR head change\n' "$repo" "$issue"
	return 0
}

release_ensure_policy_labels() {
	local repo="$1"
	managed_labels_ensure_release_policy_set "$repo" release_label_names release_label_create ||
		release_error "Unable to provision standing release policy labels in ${repo}." || return 1
	return 0
}

# Create (or finalize) the repository's standing policy issue. A signed or
# unverifiable policy is never rewritten.
release_policy_request() {
	local repo="$1" existing='' rc=0 url='' issue='' command='' body='' verdict='' verify_rc=0 expected=''
	local mode="${2:-semver}" upstream="${3:-}"
	local maintainer_prefix='Maintainer command:'
	release_authority "$repo" || return 1
	# Validate the requested signed schema before creating any issue.
	release_policy_body "$repo" validation "$mode" "$upstream" >/dev/null || return 1
	existing=$(release_policy_issue "$repo") || rc=$?
	[[ "$rc" -eq 0 || "$rc" -eq 2 ]] || return 1
	if [[ "$rc" -eq 0 ]]; then
		url=$(jq -r '.html_url' <<<"$existing") || return 1
		body=$(jq -r '.body // ""' <<<"$existing") || return 1
	else
		release_ensure_policy_labels "$repo" || return 1
		url=$(release_policy_body "$repo" 'Policy finalization pending. Do not sign until the maintainer command appears.' "$mode" "$upstream" |
			gh_create_issue --repo "$repo" --title "Standing release policy: ${repo##*/} routine upstream bumps" --body-file - \
				--label "$RELEASE_POLICY_LABEL" --label persistent --label no-auto-dispatch) || return 1
	fi
	issue="${url##*/}"
	[[ "$url" == https://* && "$issue" =~ ^[1-9][0-9]*$ ]] || release_error 'Created issue URL has no valid issue number.' || return 1
	printf -v command 'sudo aidevops approve issue %s %s' "$issue" "$repo"
	expected=$(release_policy_body "$repo" "${maintainer_prefix} \`${command}\`" "$mode" "$upstream") || return 1
	if [[ "$rc" -eq 0 ]]; then
		# Only the exact canonical body is ready to sign.
		if [[ "${body//$'\r'/}" == "$expected" ]]; then
			printf '%s\nAPPROVAL_COMMAND=%s\n' "$url" "$command"
			return 0
		fi
		verdict=$(release_verify "$repo" "$issue") || verify_rc=$?
		[[ "$verify_rc" -ne 0 && "$verdict" == NO_APPROVAL ]] || release_error 'Existing policy body needs finalization; signed or unverifiable policies must not be rewritten.' || return 1
	fi
	printf '%s\n' "$expected" |
		gh_issue_edit_safe "$issue" --repo "$repo" --body-file - >/dev/null || return 1
	printf '%s\nAPPROVAL_COMMAND=%s\n' "$url" "$command"
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

# Set RELEASE_RESOLVED_AUTHORITY for a request issue. Returns 0 to proceed,
# 3 when no merge is authorized yet (a wait state), and 1 on error.
release_resolve_authority() {
	local repo="$1" issue="$2" request="$3" pr="$4" head="$5" apply="$6" verdict='' rc=0 policy_authority=''
	RELEASE_RESOLVED_AUTHORITY=''
	verdict=$(release_verify "$repo" "$issue") || rc=$?
	if [[ "$rc" -eq 0 && "$verdict" == VERIFIED ]]; then
		RELEASE_RESOLVED_AUTHORITY="$RELEASE_SIGNED_AUTHORITY"
		return 0
	fi
	#aidevops:trust-boundary — trusted authors and labels cannot replace a signature.
	# Only an unsigned request from a trusted author may rely on the signed
	# standing policy; stale or unverifiable signatures keep their own path.
	if [[ "$rc" -ne 0 && "$verdict" == NO_APPROVAL ]] &&
		jq -e --arg trusted "$RELEASE_TRUSTED_AUTHOR" '(.author_association // "") | test($trusted)' <<<"$request" >/dev/null &&
		policy_authority=$(release_policy_for_request "$repo" "$pr" "$head" "$issue"); then
		RELEASE_RESOLVED_AUTHORITY="$policy_authority"
		return 0
	fi
	printf '%s issue %s: approval %s; no merge\n' "$repo" "$issue" "$verdict"
	if [[ "$verdict" == NO_APPROVAL && "$apply" == true ]]; then
		release_retire_moved_request "$repo" "$issue" "$pr" "$head" || return 1
	fi
	[[ "$verdict" == NO_APPROVAL || "$verdict" == STALE_APPROVAL ]] && return 3
	return 1
}

# Persist the policy authority so a later resume pass reports it. A signed
# approval is verified again on resume, so only the policy needs a record.
release_record_merge_authority() {
	local repo="$1" issue="$2" head="$3" authority="$4"
	[[ "$authority" == "standing policy #"* ]] || return 0
	release_comment "$repo" "$issue" "<!-- aidevops:cloudron-release-merge-authority ${head} policy #${authority##*#} -->
Merged exact head ${head} under ${authority}. Publication verification resumes next routine." ||
		printf 'WARN: %s issue %s: merge authority record not written\n' "$repo" "$issue" >&2
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
	pr=$(jq -r '.pr' <<<"$metadata")
	head=$(jq -r '.head' <<<"$metadata")
	version=$(jq -r '.version' <<<"$metadata")
	local authority=''
	release_resolve_authority "$repo" "$issue" "$before" "$pr" "$head" "$apply" || rc=$?
	[[ "$rc" -ne 3 ]] || return 0
	[[ "$rc" -eq 0 ]] || return 1
	authority="$RELEASE_RESOLVED_AUTHORITY"
	after=$(gh api "repos/${repo}/issues/${issue}") || return 1
	[[ "$before" == "$after" ]] || return 1
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
		if [[ "$authority" == "$RELEASE_SIGNED_AUTHORITY" ]]; then
			verdict=$(release_verify "$repo" "$issue") || return 1
			[[ "$verdict" == VERIFIED ]] || return 1
		else
			# Re-prove the policy at the exact head immediately before merge.
			release_policy_authorizes "$repo" "$pr" "$head" >/dev/null || return 1
		fi
		gh_pr_edit_safe "$pr" --repo "$repo" --remove-label hold-for-review >/dev/null || return 1
		#aidevops:trust-boundary — retain the signed SHA through readiness gates.
		if ! FULL_LOOP_EXPECTED_PR_HEAD_SHA="$head" "${SCRIPT_DIR}/full-loop-helper.sh" merge "$pr" "$repo" --squash; then
			gh_pr_edit_safe "$pr" --repo "$repo" --add-label hold-for-review >/dev/null || return 1
			return 1
		fi
		snapshot=$(release_pr "$repo" "$pr") || return 1
		release_record_merge_authority "$repo" "$issue" "$head" "$authority"
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
	release_comment "$repo" "$issue" "Published approved head ${head} (authority: ${authority}): CloudronVersions.json contains ${version}; tag v${version} descends from merge ${merge_sha}; successful catalog run and GitHub release verified: ${release_url}" || return 1
	return 0
}

# Read-only authorization used by every full-loop merge transport while the
# dedicated PR label remains set. No environment variable grants this authority.
release_authorize() {
	local repo="$1" pr="$2" head="$3" issues="" issue="" current="" number=""
	local metadata=""
	local verdict="" rc=0
	release_authority "$repo" || return 1
	issues=$(release_issues "$repo") || return 1
	while IFS= read -r issue; do
		metadata=$(release_metadata "$(jq -r '.body' <<<"$issue")" "$repo") || continue
		jq -e --arg head "$head" --arg pr "$pr" '.head == $head and (.pr | tostring) == $pr' <<<"$metadata" >/dev/null || continue
		number=$(jq -r '.number' <<<"$issue")
		rc=0
		verdict=$(release_verify "$repo" "$number") || rc=$?
		if [[ "$rc" -ne 0 || "$verdict" != VERIFIED ]]; then
			#aidevops:trust-boundary — an unsigned exact-head request may rely on
			# the signed standing policy; stale or unverifiable signatures never do.
			[[ "$rc" -ne 0 && "$verdict" == NO_APPROVAL ]] || return 1
			jq -e --arg trusted "$RELEASE_TRUSTED_AUTHOR" '(.author_association // "") | test($trusted)' <<<"$issue" >/dev/null || return 1
			release_policy_authorizes "$repo" "$pr" "$head" >/dev/null || return 1
		fi
		current=$(release_issue_snapshot "$repo" "$number") || return 1
		jq -e --argjson original "$issue" --arg label "$RELEASE_APPROVAL_LABEL" '.state == "open" and .body == $original.body and any(.labels[]; .name == $label)' <<<"$current" >/dev/null || return 1
		return 0
	done < <(jq -c '.[]' <<<"$issues")
	return 1
}

# GH#37955: does exact head $3 of PR $2 change the CloudronManifest.json
# version against its base branch tip? Returns 0 for a release bump, 1 when it
# is not one, and 2 when the evidence is unavailable (callers fail closed).
release_is_version_bump() {
	local repo="$1" pr="$2" head="$3" manifest_path='CloudronManifest.json'
	local snapshot="" pages="" touched="" base_ref="" head_version="" base_version=""
	snapshot=$(release_pr_raw "$repo" "$pr") || return 2
	jq -e --arg head "$head" '.head.sha == $head' <<<"$snapshot" >/dev/null || return 2
	base_ref=$(jq -er '.base.ref' <<<"$snapshot") || return 2
	# Catalog publication runs on main only; a stacked base cannot publish, and
	# its eventual PR into main is gated here in turn.
	[[ "$base_ref" == main ]] || return 1
	pages=$(gh api "repos/${repo}/pulls/${pr}/files?per_page=100" --paginate) || return 2
	# Malformed pages make jq fail, which is unknown evidence, not "unchanged".
	touched=$(jq -s --arg path "$manifest_path" 'add // [] | any(.[]; .filename == $path or .previous_filename == $path)' <<<"$pages") || return 2
	[[ "$touched" == true ]] || return 1
	head_version=$(release_contents "$repo" "$manifest_path" "$head" | jq -r '.version // ""') || return 2
	base_version=$(release_contents "$repo" "$manifest_path" "$base_ref" | jq -r '.version // ""') || return 2
	[[ -n "$head_version" && -n "$base_version" ]] || return 2
	[[ "$head_version" != "$base_version" ]] || return 1
	# Third field: whether native auto-merge is pending on this PR. Fourth: an
	# independent review hold (hold-for-review without the release label).
	printf '%s %s %s\n' "$base_version" "$head_version" "$(jq -r --arg label "$RELEASE_APPROVAL_LABEL" '
		(if .auto_merge == null then "manual" else "auto" end) + " " +
		(if any(.labels[]?; .name == "hold-for-review") and all(.labels[]?; .name != $label) then "independent" else "none" end)' <<<"$snapshot")"
	return 0
}

# GH#37955: best-effort cancellation of a pending native auto-merge on a PR the
# release gate denies; otherwise GitHub could merge (and publish) once checks
# pass. $3 is "auto"/"manual" from a fresh snapshot; any other value re-reads,
# and unreadable state still attempts cancellation. Never writes under DRY_RUN
# or CLOUDRON_RELEASE_GUARD_READ_ONLY. Always returns 0.
release_cancel_auto_merge() {
	local repo="$1" pr="$2" mode="${3:-}" snapshot=""
	[[ "${DRY_RUN:-0}" != 1 && "${CLOUDRON_RELEASE_GUARD_READ_ONLY:-0}" != 1 ]] || return 0
	if [[ "$mode" != auto && "$mode" != manual ]]; then
		mode=auto
		if snapshot=$(release_pr_raw "$repo" "$pr" 2>/dev/null) &&
			jq -e '.auto_merge == null' <<<"$snapshot" >/dev/null 2>&1; then
			mode=manual
		fi
	fi
	[[ "$mode" == auto ]] || return 0
	gh pr merge "$pr" --repo "$repo" --disable-auto >/dev/null 2>&1 ||
		printf 'WARN: unable to disable native auto-merge on held PR #%s in %s\n' "$pr" "$repo" >&2
	return 0
}

# GH#37955: merge-time release gate for every transport (pulse and full-loop).
# A manifest version change publishes a catalog release on merge, so it needs
# exact-head release authority whether or not a release request was ever made.
# An unauthorized bump is held for the r924 routine (process --apply), which
# requests approval or applies the signed standing policy. Returns 0 to allow.
release_merge_guard() {
	local repo="$1" pr="$2" head="$3" versions="" rc=0 base_version="" head_version="" merge_mode="" review_hold=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ $RELEASE_SHA_PATTERN ]] ||
		release_error 'merge-guard requires owner/repo, a PR number and a full head SHA.' || return 1
	versions=$(release_is_version_bump "$repo" "$pr" "$head") || rc=$?
	read -r base_version head_version merge_mode review_hold <<<"$versions" || true
	[[ "$rc" -ne 1 ]] || return 0
	#aidevops:trust-boundary — unknown evidence never allows a package merge,
	# and must not leave a native auto-merge able to publish either.
	if [[ "$rc" -ne 0 ]]; then
		release_cancel_auto_merge "$repo" "$pr"
		release_error "Unable to determine whether PR #${pr} changes the ${repo} release version; merge blocked."
		return 1
	fi
	release_authorize "$repo" "$pr" "$head" && return 0
	if [[ "$review_hold" == independent ]]; then
		# #aidevops:trust-boundary — labelling would let release processing
		# adopt and later clear another workflow's hold. The PR stays held; the
		# guard re-labels it once that independent hold is resolved.
		printf 'WARN: PR #%s in %s keeps its independent hold-for-review; release hold labels not added\n' "$pr" "$repo" >&2
	elif [[ "${DRY_RUN:-0}" != 1 && "${CLOUDRON_RELEASE_GUARD_READ_ONLY:-0}" != 1 ]]; then
		# Adding holds only narrows merge eligibility; it never grants authority.
		# r924 requests approval for any held same-repository PR (see
		# release_retry_interrupted) or applies the standing policy.
		if ! release_ensure_labels "$repo" ||
			! gh_pr_edit_safe "$pr" --repo "$repo" --add-label "$RELEASE_APPROVAL_LABEL" --add-label hold-for-review >/dev/null; then
			printf 'WARN: unable to apply release hold labels to PR #%s in %s\n' "$pr" "$repo" >&2
		fi
	fi
	release_cancel_auto_merge "$repo" "$pr" "$merge_mode"
	release_error "PR #${pr} changes the ${repo} release version (${base_version} -> ${head_version}) without exact-head release authority; held for the release routine (signed approval or standing release policy)."
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
		issue=$(release_issue_snapshot "$repo" "$number") || return 1
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
	snapshot=$(release_pr_raw "$repo" "$pr") || return 1
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
		[[ "$rc" -ne 0 ]] || requested=true
	fi
	jq -r --arg requested "$requested" '[(.number | tostring), .fingerprint, .finding, $requested] | join("|")' <<<"$target_json" || return 1
	# GH#36292: a failed request still reports its unrequested target, so the
	# caller counts the failure yet supersedes PRs main already bundles.
	[[ "$rc" -ne 1 ]] || return 1
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
	# A failed request is counted, not fatal: request-independent supersession
	# still runs, while request-dependent supersession waits for a real request.
	target_line=$(release_held_target "$repo" "$apply" "$issues" "$entries") || failures=$((failures + 1))
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

# Recover interrupted requests beyond the newest worker upstream bump handled
# above (including human-created package PRs). Never rewrite an existing request,
# even if it binds an older head: its signature/re-approval belongs to its owner.
release_retry_interrupted() {
	local repo="$1" apply="$2" prs='' issues='' pr='' requests='' rc=0 failures=0
	prs=$(gh pr list --repo "$repo" --state open --label "$RELEASE_APPROVAL_LABEL" \
		--limit "$RELEASE_HELD_PR_LIMIT" --json number,isDraft,isCrossRepository) || return 1
	jq -e --argjson limit "$RELEASE_HELD_PR_LIMIT" 'type == "array" and length < $limit' <<<"$prs" >/dev/null || return 1
	[[ "$(jq 'length' <<<"$prs")" -gt 0 ]] || return 0
	issues=$(release_issues "$repo") || return 1
	while IFS= read -r pr; do
		[[ -n "$pr" ]] || continue
		requests=$(release_requests_for_pr "$repo" "$issues" "$pr") || return 1
		#aidevops:trust-boundary — labels allow requesting approval, never releasing
		# a hold or modifying a signed/stale request for this PR.
		[[ -z "$requests" ]] || continue
		rc=0
		release_request_held "$repo" "$apply" "$pr" || rc=$?
		if [[ "$rc" -eq 0 && "$apply" == true ]]; then
			issues=$(release_issues "$repo") || return 1
		elif [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
			failures=$((failures + 1))
		fi
	done < <(jq -r '.[] | select(.isDraft == false and .isCrossRepository == false) | .number' <<<"$prs")
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
			release_retry_interrupted "$repo" "$apply" || failures=$((failures + 1))
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
	merge-guard)
		[[ $# -eq 4 ]] || return 1
		release_merge_guard "$arg2" "$arg3" "$arg4" || return 1
		;;
	cancel-auto-merge)
		[[ $# -eq 3 && "$arg2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$arg3" =~ ^[1-9][0-9]*$ ]] || return 1
		release_cancel_auto_merge "$arg2" "$arg3"
		;;
	request)
		[[ $# -eq 3 ]] || return 1
		release_request "$arg2" "$arg3" || return $?
		;;
	policy-request)
		[[ $# -eq 2 || ( $# -eq 4 && "$arg3" == commits ) ]] || return 1
		release_policy_request "$arg2" "${arg3:-semver}" "$arg4" || return 1
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
		printf 'Usage: cloudron-release-approval-helper.sh request <repo> <pr> | policy-request <repo> [commits <upstream-owner/repo>] | merge-guard <repo> <pr> <head> | process [--repo owner/repo] [--issue N] [--apply]\n'
		;;
	*) return 1 ;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
