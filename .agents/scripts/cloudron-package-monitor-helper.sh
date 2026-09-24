#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Monitor registered Cloudron packages and file package-local findings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=cloudron-package-release-lib.sh
source "${SCRIPT_DIR}/cloudron-package-release-lib.sh"
# shellcheck source=terminal-blocker-circuit.sh
source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"

REPOS_FILE="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
_CLOUDRON_MONITOR_JSON_TYPE_ARRAY=array
_CLOUDRON_MONITOR_JSON_TYPE_STRING=string
_CLOUDRON_MONITOR_JSON_TYPE_OBJECT=object
_CLOUDRON_MONITOR_GH_TIMEOUT_DEFAULT=90

_cloudron_monitor_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

_cloudron_monitor_deferred() {
	local expires_at=""
	expires_at="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$expires_at" =~ ^[0-9]+$ ]] || expires_at="unknown"
	printf 'DEFERRED: GitHub API cooldown active until epoch %s.\n' "$expires_at" >&2
	return 75
}

_cloudron_monitor_response_bodies() {
	local response_text="$1"
	printf '%s\n' "$response_text" | awk '
		{
			line = $0
			sub(/\r$/, "", line)
			if (line ~ /^HTTP\//) { in_headers = 1; next }
			if (in_headers && line == "") { in_headers = 0; next }
			if (!in_headers) { print line }
		}
	'
	return 0
}

_cloudron_monitor_fetch_releases() {
	local upstream_slug="$1"
	local endpoint="/repos/${upstream_slug}/releases?per_page=100"
	local read_timeout="${AIDEVOPS_CLOUDRON_MONITOR_GH_TIMEOUT:-$_CLOUDRON_MONITOR_GH_TIMEOUT_DEFAULT}"
	local response=""
	local api_rc=0
	[[ "$read_timeout" =~ ^[1-9][0-9]*$ ]] || {
		_cloudron_monitor_error "AIDEVOPS_CLOUDRON_MONITOR_GH_TIMEOUT must be a positive integer."
		return 1
	}
	response=$(AIDEVOPS_GH_READ_TIMEOUT="$read_timeout" _gh_with_timeout read gh api -i "$endpoint" --paginate --jq '.' 2>/dev/null) || api_rc=$?
	if [[ "$api_rc" -eq 75 ]] || _gh_secondary_cooldown_active; then
		_cloudron_monitor_deferred
		return $?
	fi
	if [[ "$api_rc" -ne 0 ]]; then
		_cloudron_monitor_error "Could not fetch paginated GitHub releases for $upstream_slug."
		return 1
	fi
	if ! _cloudron_monitor_response_bodies "$response" | jq -sc '
		if all(.[]; type == "array") then
			add // []
		else
			error("expected release page arrays")
		end
	'; then
		_cloudron_monitor_error "Could not normalize paginated GitHub releases for $upstream_slug."
		return 1
	fi
	return 0
}

# Fetch the target manifest from the remote default branch. The commit SHA is
# captured before the content request so a finding cannot silently describe a
# stale registered checkout.
_cloudron_monitor_fetch_remote_manifest() {
	local slug="$1"
	local manifest_rel="$2"
	local repository_json=""
	local default_branch=""
	local commit_sha=""
	local encoded_manifest=""
	local manifest=""
	repository_json=$(gh api "/repos/${slug}") || _cloudron_monitor_error "Could not resolve the remote default branch for $slug." || return 1
	default_branch=$(jq -er '.default_branch | select(type == "string" and length > 0)' <<<"$repository_json") || _cloudron_monitor_error "Remote default branch is missing for $slug." || return 1
	commit_sha=$(gh api "/repos/${slug}/commits/${default_branch}" --jq '.sha') || _cloudron_monitor_error "Could not resolve the remote default-branch commit for $slug." || return 1
	[[ "$commit_sha" =~ ^[0-9A-Fa-f]{40}$ ]] || _cloudron_monitor_error "Remote default-branch commit SHA is invalid for $slug." || return 1
	encoded_manifest=$(gh api "/repos/${slug}/contents/${manifest_rel}?ref=${commit_sha}" --jq '.content') || _cloudron_monitor_error "Could not fetch the remote manifest for $slug at ${commit_sha}." || return 1
	manifest=$(printf '%s' "$encoded_manifest" | tr -d '\n' | base64 -D 2>/dev/null) ||
		manifest=$(printf '%s' "$encoded_manifest" | tr -d '\n' | base64 --decode 2>/dev/null) ||
		_cloudron_monitor_error "Remote manifest content could not be decoded for $slug." || return 1
	jq -e 'type == "object"' <<<"$manifest" >/dev/null 2>&1 || _cloudron_monitor_error "Remote manifest is not valid JSON for $slug." || return 1
	printf '%s\n%s\n' "$commit_sha" "$manifest"
	return 0
}

_cloudron_monitor_require_tools() {
	command -v jq >/dev/null 2>&1 || _cloudron_monitor_error "jq is required." || return 1
	command -v gh >/dev/null 2>&1 || _cloudron_monitor_error "GitHub CLI is required." || return 1
	[[ -f "$REPOS_FILE" ]] || _cloudron_monitor_error "repos.json not found: $REPOS_FILE" || return 1
	jq -e --arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" \
		'.initialized_repos | type == $array_type' "$REPOS_FILE" >/dev/null 2>&1 || _cloudron_monitor_error "repos.json has no initialized_repos array." || return 1
	return 0
}

_cloudron_monitor_component_newer() {
	local candidate="$1"
	local current="$2"
	if [[ "${#candidate}" -ne "${#current}" ]]; then
		[[ "${#candidate}" -gt "${#current}" ]]
		return $?
	fi
	[[ "$candidate" > "$current" ]]
	return $?
}

_cloudron_monitor_version_newer() {
	local candidate="${1#v}"
	local current="${2#v}"
	cloudron_package_is_semver "$candidate" || return 1
	cloudron_package_is_semver "$current" || return 0
	local candidate_core="${candidate%%[-+]*}"
	local current_core="${current%%[-+]*}"
	local candidate_major=0 candidate_minor=0 candidate_patch=0
	local current_major=0 current_minor=0 current_patch=0
	IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate_core"
	IFS=. read -r current_major current_minor current_patch <<<"$current_core"
	if [[ "$candidate_major" != "$current_major" ]]; then
		_cloudron_monitor_component_newer "$candidate_major" "$current_major"
		return $?
	fi
	if [[ "$candidate_minor" != "$current_minor" ]]; then
		_cloudron_monitor_component_newer "$candidate_minor" "$current_minor"
		return $?
	fi
	if [[ "$candidate_patch" != "$current_patch" ]]; then
		_cloudron_monitor_component_newer "$candidate_patch" "$current_patch"
		return $?
	fi
	if [[ "$candidate" != *-* && "$current" == *-* ]]; then
		return 0
	fi
	return 1
}

_cloudron_monitor_tag_version() {
	local tag="$1"
	local prefixes_json="$2"
	local prefix=""
	local version=""
	while IFS= read -r prefix; do
		[[ "$tag" == "$prefix"* ]] || continue
		version="${tag#"$prefix"}"
		cloudron_package_is_semver "$version" || continue
		[[ "${version%%+*}" != *-* ]] || continue
		printf '%s\n' "$version"
		return 0
	done < <(jq -r '.[]' <<<"$prefixes_json")
	return 1
}

_cloudron_monitor_latest_release_version() {
	local releases_json="$1"
	local prefixes_json="$2"
	local upstream_slug="$3"
	local stable_tags=""
	local tag=""
	local version=""
	local latest_version=""

	[[ -n "$releases_json" ]] || _cloudron_monitor_error "GitHub returned an empty releases response for $upstream_slug." || return 1
	if ! stable_tags=$(jq -r \
		--arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" \
		--arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" '
		if type != $array_type then
			error("expected a release array")
		else
			.[]
			| select(type == "object" and .draft != true and .prerelease != true and (.tag_name | type == $string_type))
			| .tag_name
		end
	' <<<"$releases_json"); then
		_cloudron_monitor_error "GitHub releases response for $upstream_slug was not a valid release array." || return 1
	fi

	while IFS= read -r tag; do
		[[ -n "$tag" ]] || continue
		version=$(_cloudron_monitor_tag_version "$tag" "$prefixes_json") || continue
		if [[ -z "$latest_version" ]] || _cloudron_monitor_version_newer "$version" "$latest_version"; then
			latest_version="$version"
		fi
	done <<<"$stable_tags"

	[[ -n "$latest_version" ]] || _cloudron_monitor_error "No stable semantic release tag for $upstream_slug matches cloudron_package.upstream_tag_prefixes ${prefixes_json}; configure the tag streams or publish a matching stable release." || return 1
	printf '%s\n' "$latest_version"
	return 0
}

# Some upstreams publish a desktop release before the package's source image is
# qualified. Only an explicitly configured release-parent image can gate work;
# a successful image built from a later commit is NOT the released source.
_cloudron_monitor_upstream_image_ready() {
	local entry="$1" upstream_slug="$2" releases_json="$3" prefixes_json="$4" version="$5"
	local image="" signer="" annotation="" eligibility_type="" tag="" candidate="" release_ref="" release_sha=""
	local object_type="" commit="" source_sha="" image_ref="" manifest="" digest="" proof="" depth=0
	image=$(jq -r '.cloudron_package.upstream_image.repository // empty' <<<"$entry") || return 1
	signer=$(jq -r '.cloudron_package.upstream_image.signer_workflow // empty' <<<"$entry") || return 1
	annotation=$(jq -r '.cloudron_package.upstream_image.qualification_annotation // empty' <<<"$entry") || return 1
	eligibility_type=$(jq -r '.cloudron_package.upstream_image.eligibility_predicate_type // empty' <<<"$entry") || return 1
	[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
		"$signer" == "$upstream_slug"/.github/workflows/* &&
		"$signer" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ &&
		"$annotation" =~ ^[A-Za-z0-9_.-]+$ &&
		(-z "$eligibility_type" || "$eligibility_type" =~ ^https://[A-Za-z0-9._/-]+$) ]] ||
		_cloudron_monitor_error "Invalid upstream_image repository, signer_workflow, qualification_annotation or eligibility_predicate_type for $upstream_slug." || return 1
	command -v docker >/dev/null 2>&1 || _cloudron_monitor_error "Docker Buildx is required for upstream_image monitoring." || return 1
	while IFS= read -r tag; do
		[[ "$tag" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
		candidate=$(_cloudron_monitor_tag_version "$tag" "$prefixes_json") || continue
		[[ "$candidate" == "$version" ]] && break
	done < <(jq -r --arg object_type "$_CLOUDRON_MONITOR_JSON_TYPE_OBJECT" \
		'.[] | select(type == $object_type and .draft != true and .prerelease != true) | .tag_name | select(type == "string")' <<<"$releases_json")
	[[ "$candidate" == "$version" && "$tag" =~ ^[A-Za-z0-9_.-]+$ ]] || _cloudron_monitor_error "No stable tag resolves upstream v$version." || return 1
	release_ref=$(gh api "repos/${upstream_slug}/git/ref/tags/${tag}") || return 1
	object_type=$(jq -r '.object.type // empty' <<<"$release_ref") || return 1
	release_sha=$(jq -r '.object.sha // empty' <<<"$release_ref") || return 1
	while [[ "$object_type" == tag && "$depth" -lt 10 ]]; do
		depth=$((depth + 1))
		release_ref=$(gh api "repos/${upstream_slug}/git/tags/${release_sha}") || return 1
		object_type=$(jq -r '.object.type // empty' <<<"$release_ref") || return 1
		release_sha=$(jq -r '.object.sha // empty' <<<"$release_ref") || return 1
	done
	[[ "$object_type" == commit && "$release_sha" =~ ^[a-f0-9]{40}$ ]] || _cloudron_monitor_error "Release tag $tag does not resolve to a commit." || return 1
	commit=$(gh api "repos/${upstream_slug}/commits/${release_sha}") || return 1
	source_sha=$(jq -r 'if (.parents | length) == 1 then .parents[0].sha else empty end' <<<"$commit") || return 1
	[[ "$source_sha" =~ ^[a-f0-9]{40}$ ]] || _cloudron_monitor_error "Release $tag is not a one-parent release commit." || return 1
	image_ref="${image}:sha-${source_sha:0:7}"
	if ! manifest=$(docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest}}' 2>&1); then
		[[ "$manifest" == *"not found"* ]] || _cloudron_monitor_error "Could not inspect upstream image $image_ref." || return 1
		printf 'WAITING %s: release-parent image %s is not published.\n' "$upstream_slug" "$image_ref" >&2
		return 3
	fi
	digest=$(jq -er --arg revision "$source_sha" --arg annotation "$annotation" '
		select(.mediaType == "application/vnd.oci.image.index.v1+json")
		| select(.annotations["org.opencontainers.image.revision"] == $revision and .annotations[$annotation] == "success")
		| select(any(.manifests[]; .platform.os == "linux" and .platform.architecture == "amd64")
		  and any(.manifests[]; .platform.os == "linux" and .platform.architecture == "arm64"))
		| .digest | select(test("^sha256:[a-f0-9]{64}$"))' <<<"$manifest") || {
		printf 'WAITING %s: %s lacks the qualified multi-architecture release-parent index.\n' "$upstream_slug" "$image_ref" >&2
		return 3
	}
	proof=$(gh attestation verify "oci://${image}@${digest}" --repo "$upstream_slug" \
		--signer-workflow "$signer" --source-digest "$source_sha" \
		--predicate-type 'https://slsa.dev/provenance/v1' --format json 2>/dev/null) || {
		printf 'WAITING %s: %s has no matching upstream provenance attestation.\n' "$upstream_slug" "$image_ref" >&2
		return 3
	}
	jq -e --arg image "$image" --arg digest "${digest#sha256:}" --arg revision "$source_sha" '
		any(.[]; any(.verificationResult.statement.subject[]?; .name == $image and .digest.sha256 == $digest)
		  and .verificationResult.signature.certificate.sourceRepositoryDigest == $revision)' <<<"$proof" >/dev/null || {
		printf 'WAITING %s: source provenance does not match the release-parent index.\n' "$upstream_slug" >&2
		return 3
	}
	if [[ -n "$eligibility_type" ]]; then
		proof=$(gh attestation verify "oci://${image}@${digest}" --repo "$upstream_slug" \
			--signer-workflow "$signer" --source-digest "$source_sha" \
			--predicate-type "$eligibility_type" --format json 2>/dev/null) || {
			printf 'WAITING %s: %s has no matching deployment-eligibility attestation.\n' "$upstream_slug" "$image_ref" >&2
			return 3
		}
		jq -e --arg image "$image" --arg digest "${digest#sha256:}" --arg revision "$source_sha" \
			--arg upstream "$upstream_slug" --arg workflow "${signer#"$upstream_slug"/}" '
			any(.[]; any(.verificationResult.statement.subject[]?; .name == $image and .digest.sha256 == $digest)
			  and .verificationResult.signature.certificate.sourceRepositoryDigest == $revision
			  and .verificationResult.statement.predicate.eligible == true
			  and .verificationResult.statement.predicate.source.sha == $revision
			  and .verificationResult.statement.predicate.source.repository == $upstream
			  and .verificationResult.statement.predicate.build.workflow == $workflow
			  and .verificationResult.statement.predicate.qualification.conclusion == "success")' <<<"$proof" >/dev/null || {
			printf 'WAITING %s: deployment eligibility does not match the release-parent index.\n' "$upstream_slug" >&2
			return 3
		}
	fi
	printf '%s %s %s %s %s\n' "$tag" "$image_ref" "$digest" "$source_sha" "$release_sha"
	return 0
}

_cloudron_monitor_has_authority() {
	local slug="$1"
	local permission=""
	permission=$(gh repo view "$slug" --json viewerPermission --jq '.viewerPermission') || return 1
	case "$permission" in
	ADMIN | MAINTAIN) return 0 ;;
	*) return 1 ;;
	esac
}

_cloudron_monitor_issue_exists() {
	local slug="$1"
	local fingerprint="$2"
	local issue_number=""
	_CLOUDRON_MONITOR_ISSUE_NUMBER=""
	if ! issue_number=$(gh issue list --repo "$slug" --state all --search "${fingerprint} in:body" --limit 1 --json number --jq '.[0].number // empty'); then
		return 2
	fi
	_CLOUDRON_MONITOR_ISSUE_NUMBER="$issue_number"
	[[ -n "$issue_number" ]]
	return $?
}

# A previously blocked issue gets one trusted retry only on positive, immutable
# source proof. Never retry a permission hold or a claimed/paused issue.
_cloudron_monitor_rearm_ready_issue() {
	local slug="$1" issue_number="$2" proof="$3" issue="" comments="" marker="" blocker="" circuit="" retry=""
	local body_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}" body_file=""
	local comment_wrapper="${CLOUDRON_PACKAGE_COMMENT_WRAPPER:-gh_issue_comment}"
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	issue=$(gh api "repos/${slug}/issues/${issue_number}") || return 1
	jq -e '.state == "open" and (.assignees | length == 0) and
		([.labels[].name] | index("auto-dispatch") != null and index("status:available") != null)' \
		<<<"$issue" >/dev/null || return 0
	comments=$(terminal_blocker_fetch_trusted_comments "$issue_number" "$slug") || return 1
	blocker=$(_terminal_blocker_hash 'v2:target_code_blocker') || return 1
	marker="aidevops:cloudron-source-ready ${proof// /-}"
	if jq -e --arg marker "$marker" 'any(.[]; .body | contains($marker))' <<<"$comments" >/dev/null; then
		return 0
	fi
	# aidevops:trust-boundary — only the latest OWNER/MEMBER circuit may be
	# re-armed. A newer permission hold or an existing trusted retry wins.
	circuit=$(_terminal_blocker_latest_marker "$comments" 'aidevops:terminal-blocker-circuit revision=') || return 1
	[[ -n "$circuit" ]] || return 0
	jq -e --arg blocker "$blocker" '.body | contains("blocker=" + $blocker)' <<<"$circuit" >/dev/null || return 0
	retry=$(_terminal_blocker_latest_retry_comment "$comments") || return 1
	if _terminal_blocker_retry_after "$retry" "$circuit"; then
		return 0
	fi
	_cloudron_monitor_has_authority "$slug" || return 1
	command -v "$comment_wrapper" >/dev/null 2>&1 || return 1
	mkdir -p "$body_dir"
	body_file=$(mktemp "${body_dir}/cloudron-source-ready.XXXXXX") || return 1
	printf '<!-- %s -->\nVerified upstream source image for the existing package task: %s. Recheck the pinned source and package preflight before changing code.\n\nterminal-blocker-circuit:retry\n' \
		"$marker" "$proof" >"$body_file"
	if ! "$comment_wrapper" "$issue_number" --repo "$slug" --body-file "$body_file" >/dev/null; then
		rm -f "$body_file"
		return 1
	fi
	rm -f "$body_file"
	return 0
}

_cloudron_monitor_create_issue() {
	local slug="$1"
	local title="$2"
	local fingerprint="$3"
	local summary="$4"
	local verification="$5"
	local manifest_rel="${6:-CloudronManifest.json}"
	local repo_path="${7:-}"
	local changelog_scope=""
	local body_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local body_file=""
	local issue_wrapper="${CLOUDRON_PACKAGE_ISSUE_WRAPPER:-gh_create_issue}"
	command -v "$issue_wrapper" >/dev/null 2>&1 || _cloudron_monitor_error "gh_create_issue wrapper is required for managed issue writes." || return 1
	mkdir -p "$body_dir"
	body_file=$(mktemp "${body_dir}/cloudron-package-monitor.XXXXXX") || return 1
	if [[ -n "$repo_path" && -f "${repo_path}/CHANGELOG" ]]; then
		changelog_scope="- \`CHANGELOG\` — Cloudron-format package release notes."
	fi
	if [[ -n "$repo_path" && -f "${repo_path}/CHANGELOG.md" ]]; then
		changelog_scope="${changelog_scope}
- \`CHANGELOG.md\` — package release notes before any version bump."
	fi
	cat >"$body_file" <<EOF
<!-- aidevops:cloudron-package-monitor ${fingerprint} -->
<!-- aidevops:brief-schema=v2 -->
## What

${summary}

The monitor did not build, publish, tag, deploy, or modify package source.

## Files Scope

- \`${manifest_rel}\` — package and upstream version metadata.
- \`Dockerfile\` or \`Dockerfile.cloudron\` — final Cloudron base image and packaged upstream artifacts.
${changelog_scope:-\`CHANGELOG.md\` — package release notes before any version bump.}

## Acceptance criteria

- Reproduce and assess the finding against current upstream and Cloudron packaging guidance.
- Update package source and tests only when the finding remains actionable.
- Run the package release preflight before proposing a tag.
- Do not publish a release, image, catalog entry, or deployment without separate operator authorization.

## Verification

${verification}
EOF
	if "$issue_wrapper" --repo "$slug" --title "$title" --body-file "$body_file" \
		--label "type:maintenance" --label "tier:standard" --label "auto-dispatch" >/dev/null; then
		rm -f "$body_file"
		printf 'Created Cloudron package finding in %s: %s\n' "$slug" "$title"
		return 0
	fi
	rm -f "$body_file"
	return 1
}

_cloudron_monitor_apply_finding() {
	local apply="$1"
	local slug="$2"
	local title="$3"
	local fingerprint="$4"
	local summary="$5"
	local verification="$6"
	local manifest_rel="${7:-CloudronManifest.json}"
	local repo_path="${8:-}"
	local source_proof="${9:-}"
	local exists_rc=0
	if _cloudron_monitor_issue_exists "$slug" "$fingerprint"; then
		if [[ "$apply" == true && -n "$source_proof" ]]; then
			_cloudron_monitor_rearm_ready_issue "$slug" "$_CLOUDRON_MONITOR_ISSUE_NUMBER" "$source_proof" || return 1
		fi
		printf 'Already handled in %s: %s\n' "$slug" "$fingerprint"
		return 0
	else
		exists_rc=$?
	fi
	[[ "$exists_rc" -ne 2 ]] || _cloudron_monitor_error "Could not check issue deduplication for $slug." || return 1
	if [[ "$apply" != true ]]; then
		printf 'FINDING %s %s\n' "$slug" "$title"
		return 0
	fi
	_cloudron_monitor_has_authority "$slug" || _cloudron_monitor_error "ADMIN or MAINTAIN issue authority is required for $slug." || return 1
	_cloudron_monitor_create_issue "$slug" "$title" "$fingerprint" "$summary" "$verification" "$manifest_rel" "$repo_path"
	return $?
}

_cloudron_monitor_upstream_entry() {
	local entry="$1"
	local apply="$2"
	local slug=""
	local repo_path=""
	local manifest_rel=""
	local upstream_slug=""
	local monitor_enabled=""
	local tag_prefixes=""
	slug=$(jq -r '.slug // empty' <<<"$entry")
	repo_path=$(jq -r '.path // empty' <<<"$entry")
	manifest_rel=$(jq -r '.cloudron_package.manifest // "CloudronManifest.json"' <<<"$entry")
	upstream_slug=$(jq -r '.cloudron_package.upstream_slug // empty' <<<"$entry")
	monitor_enabled=$(jq -r '.cloudron_package.monitor_upstream // ((.cloudron_package.upstream_slug // "") != "")' <<<"$entry")
	[[ "$monitor_enabled" == true ]] || return 0
	[[ "$slug" == */* && "$upstream_slug" == */* ]] || _cloudron_monitor_error "Cloudron upstream monitoring requires target and upstream slugs." || return 1
	[[ "$manifest_rel" != /* && "$manifest_rel" != *..* ]] || _cloudron_monitor_error "Unsafe manifest path configured for $slug." || return 1
	repo_path="${repo_path/#\~/$HOME}"
	local remote_manifest_result=""
	local remote_commit_sha=""
	local remote_manifest=""
	remote_manifest_result=$(_cloudron_monitor_fetch_remote_manifest "$slug" "$manifest_rel") || return $?
	remote_commit_sha=$(printf '%s\n' "$remote_manifest_result" | awk 'NR == 1 { print; exit }')
	remote_manifest=$(printf '%s\n' "$remote_manifest_result" | awk 'NR > 1 { print }')
	local package_title=""
	if ! package_title=$(jq -er --arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" \
		'.title | select(type == $string_type and test("\\S"))' <<<"$remote_manifest"); then
		_cloudron_monitor_error "Manifest title is missing or blank for registered Cloudron package $slug." || return 1
	fi
	tag_prefixes=$(jq -c '.cloudron_package.upstream_tag_prefixes as $prefixes | if $prefixes == null then ["v", ""] else $prefixes end' <<<"$entry") || return 1
	jq -e --arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" --arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" \
		'type == $array_type and length > 0 and all(.[]; type == $string_type and all(explode[]; . >= 32 and . != 127))' <<<"$tag_prefixes" >/dev/null 2>&1 ||
		_cloudron_monitor_error "cloudron_package.upstream_tag_prefixes for $slug must be a non-empty array of strings; control characters are forbidden." || return 1
	local releases_json=""
	releases_json=$(_cloudron_monitor_fetch_releases "$upstream_slug") || return $?
	local latest_version=""
	latest_version=$(_cloudron_monitor_latest_release_version "$releases_json" "$tag_prefixes" "$upstream_slug") || return 1
	local current_version=""
	current_version=$(jq -r '.upstreamVersion // empty' <<<"$remote_manifest") || return 1
	if [[ -n "$current_version" ]] && ! _cloudron_monitor_version_newer "$latest_version" "$current_version"; then
		return 0
	fi
	local source_proof="" ready_rc=0
	if jq -e '.cloudron_package.upstream_image != null' <<<"$entry" >/dev/null; then
		source_proof=$(_cloudron_monitor_upstream_image_ready "$entry" "$upstream_slug" "$releases_json" "$tag_prefixes" "$latest_version") || ready_rc=$?
		[[ "$ready_rc" -ne 3 ]] || return 0
		[[ "$ready_rc" -eq 0 ]] || return "$ready_rc"
	fi
	local fingerprint="upstream-v${latest_version}"
	local title="${package_title} upstream v${latest_version} is available"
	local summary=""
	local verification=""
	printf -v summary "Upstream package \`%s\` released \`v%s\`; remote default-branch manifest commit \`%s\` records \`%s\`." \
		"$upstream_slug" "$latest_version" "$remote_commit_sha" "${current_version:-no upstreamVersion}"
	if [[ -n "$source_proof" ]]; then
		summary="${summary}

Qualified release-parent image: \`${source_proof}\`. Use this exact source; a later qualified main image does not establish that the release-parent commit was published."
	fi
	printf -v verification "Run \`cloudron-package-helper.sh preflight-release v<package-version>\` after updating and testing the package."
	_cloudron_monitor_apply_finding "$apply" "$slug" "$title" "$fingerprint" "$summary" "$verification" "$manifest_rel" "$repo_path" "$source_proof"
	return $?
}

_cloudron_monitor_compatibility_entry() {
	local entry="$1"
	local apply="$2"
	local slug=""
	local repo_path=""
	local manifest_rel=""
	local monitor_enabled=""
	slug=$(jq -r '.slug // empty' <<<"$entry")
	repo_path=$(jq -r '.path // empty' <<<"$entry")
	manifest_rel=$(jq -r '.cloudron_package.manifest // "CloudronManifest.json"' <<<"$entry")
	monitor_enabled=$(jq -r '.cloudron_package.monitor_compatibility // true' <<<"$entry")
	[[ "$monitor_enabled" == true ]] || return 0
	[[ "$slug" == */* ]] || _cloudron_monitor_error "Cloudron compatibility monitoring requires a target slug." || return 1
	[[ "$manifest_rel" != /* && "$manifest_rel" != *..* ]] || _cloudron_monitor_error "Unsafe manifest path configured for $slug." || return 1
	repo_path="${repo_path/#\~/$HOME}"
	[[ -d "$repo_path" ]] || _cloudron_monitor_error "Registered Cloudron package path is unavailable for $slug." || return 1
	local findings=""
	if findings=$(cloudron_package_compatibility_findings "$repo_path" "$manifest_rel"); then
		return 0
	fi
	[[ -n "$findings" ]] || return 1
	local checksum=""
	checksum=$(printf '%s\n' "$findings" | cksum | awk '{ print $1 }')
	local fingerprint="compatibility-${checksum}"
	local title="Cloudron package compatibility audit found actionable drift"
	local summary=""
	local verification=""
	printf -v summary 'The weekly compatibility audit reported:\n\n%s' "$findings"
	printf -v verification "Run \`cloudron-package-helper.sh check-compatibility\` and the package-specific test suite."
	_cloudron_monitor_apply_finding "$apply" "$slug" "$title" "$fingerprint" "$summary" "$verification"
	return $?
}

_cloudron_monitor_run() {
	local mode="$1"
	local apply="$2"
	local failures=0
	local entry=""
	local entry_rc=0
	while IFS= read -r entry; do
		entry_rc=0
		if [[ "$mode" == "upstream" ]]; then
			_cloudron_monitor_upstream_entry "$entry" "$apply" || entry_rc=$?
		else
			_cloudron_monitor_compatibility_entry "$entry" "$apply" || entry_rc=$?
		fi
		if [[ "$entry_rc" -eq 75 ]]; then
			return 75
		fi
		[[ "$entry_rc" -eq 0 ]] || failures=$((failures + 1))
	done < <(jq -c '.initialized_repos[] | select(.maintenance != false and .app_type == "cloudron-package")' "$REPOS_FILE")
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

show_help() {
	cat <<'HELP'
Cloudron Package Monitor

Usage:
  cloudron-package-monitor-helper.sh upstream [--apply]
  cloudron-package-monitor-helper.sh compatibility [--apply]

Without --apply, findings are reported without creating issues. With --apply,
deduplicated issues are created in each registered package repository after an
ADMIN/MAINTAIN permission check. No package source or release state is changed.
HELP
	return 0
}

main() {
	local mode="${1:-help}"
	local apply=false
	[[ "${2:-}" == "--apply" ]] && apply=true
	case "$mode" in
	upstream | compatibility)
		_cloudron_monitor_require_tools || return 1
		_cloudron_monitor_run "$mode" "$apply"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		_cloudron_monitor_error "Unknown command: $mode" || true
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
