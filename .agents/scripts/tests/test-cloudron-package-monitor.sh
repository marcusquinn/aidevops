#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-monitor-helper.sh"
PULSE_ROUTINES="${SCRIPT_DIR}/../pulse-routines.sh"
GH_COOLDOWN="${SCRIPT_DIR}/../shared-gh-secondary-cooldown.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e'

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

write_fake_commands() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" && "$*" == *releases\?per_page=100* ]]; then
    endpoint=""
    for arg in "$@"; do
        [[ "$arg" == /repos/*/releases\?per_page=100 ]] && endpoint="$arg"
    done
    printf 'API %s\nARGS %s\nTIMEOUT %s\n' "$endpoint" "$*" "${AIDEVOPS_GH_READ_TIMEOUT:-unset}" >>"${MONITOR_API_LOG:-/dev/null}"
    case "${MONITOR_RATE_FIXTURE:-}" in
        primary-403-reset)
            printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\n\r\n{"message":"API rate limit exceeded"}\n'
            exit 1
            ;;
        secondary-403-retry)
            printf 'HTTP/2 403\r\nRetry-After: 45\r\nX-RateLimit-Remaining: 50\r\n\r\n{"message":"You have exceeded a secondary rate limit"}\n'
            exit 1
            ;;
        primary-429-retry)
            printf 'HTTP/2 429\r\nRetry-After: 30\r\nX-RateLimit-Remaining: 0\r\n\r\n{"message":"rate limit exceeded"}\n'
            exit 1
            ;;
        primary-429-reset)
            printf 'HTTP/2 429\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\n\r\n{"message":"rate limit exceeded"}\n'
            exit 1
            ;;
    esac
    if [[ "${MONITOR_API_FAIL:-false}" == true ]]; then
        printf 'HTTP/2 500\r\n\r\n{"message":"temporary server error"}\n'
        exit 1
    fi
    printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 100\r\n\r\n'
    if [[ -n "${MONITOR_RELEASES_FILE:-}" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line"
        done <"${MONITOR_RELEASES_FILE}"
    else
        cat <<'JSON'
[
  {"tag_name":"v1.10.0","draft":false,"prerelease":false},
  {"tag_name":"v9.0.0","draft":true,"prerelease":false},
  {"tag_name":"desktop-v99.0.0","draft":false,"prerelease":false}
]
[
  {"tag_name":"v8.0.0","draft":false,"prerelease":true},
  {"tag_name":"2.0.0","draft":false,"prerelease":false},
  {"tag_name":99,"draft":false,"prerelease":false}
]
JSON
    fi
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "/repos/exampleorg/example-package" ]]; then
	[[ "${MONITOR_REMOTE_FAILURE:-false}" != true ]] || exit 1
    printf '%s\n' '{"default_branch":"main"}'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "/repos/exampleorg/example-package/commits/main" ]]; then
	printf '%s\n' '0123456789012345678901234567890123456789'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "/repos/exampleorg/example-package/contents/CloudronManifest.json?ref=0123456789012345678901234567890123456789" ]]; then
	if [[ -n "${MONITOR_REMOTE_VERSION:-}" ]]; then
		remote_manifest=$(printf '{"id":"com.example.package","title":"Example Package","version":"1.0.0","upstreamVersion":"%s","healthCheckPath":"/","httpPort":8000,"manifestVersion":2}' "$MONITOR_REMOTE_VERSION")
	else
		manifest_path=$(jq -r '.initialized_repos[0].path + "/CloudronManifest.json"' "${HOME}/.config/aidevops/repos.json")
		remote_manifest=$(cat "$manifest_path")
	fi
    printf '%s' "$remote_manifest" | base64 | tr -d '\n'
    printf '\n'
    exit 0
fi
source "${0%/*}/gh-source"
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    printf '%s\n' 'ADMIN'
    exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
    search=""
    shift 2
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--search" ]]; then
            search="${2:-}"
            break
        fi
        shift
    done
    marker="${search% in:body}"
    if [[ -n "$marker" && -f "${MONITOR_TEST_LOG}" ]] && grep -Fq -- "$marker" "${MONITOR_TEST_LOG}"; then
        printf '%s\n' '101'
    fi
    exit 0
fi
exit 1
GH
	write_fake_issue_wrapper "$bin_dir"
	chmod +x "${bin_dir}/gh"
}

write_fake_source_commands() {
	local bin_dir="$1"
	cat >"${bin_dir}/gh-source" <<'SOURCE'
if [[ "${1:-}" == "api" && "${2:-}" == "repos/exampleorg/upstream/git/ref/tags/desktop-v2.0.0" ]]; then
    printf '%s\n' '{"object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/exampleorg/upstream/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]; then
    printf '%s\n' '{"parents":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/exampleorg/example-package/issues/101" ]]; then
    if [[ "${MONITOR_ISSUE_STATE:-}" == claimed ]]; then
        printf '%s\n' '{"state":"open","assignees":[{"login":"exampleorg"}],"labels":[{"name":"auto-dispatch"},{"name":"status:claimed"}]}'
    else
        printf '%s\n' '{"state":"open","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}'
    fi
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/exampleorg/example-package/issues/101/comments?per_page=100" ]]; then
    source_marker='<!-- aidevops:cloudron-source-ready desktop-v2.0.0-ghcr.io/exampleorg/upstream:sha-bbbbbbb-sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->'
    if [[ -n "${MONITOR_FORGED_MARKER:-}" ]]; then
        printf '[{"body":"<!-- aidevops:terminal-blocker-circuit revision=012345678901234567890123 blocker=%s -->","author_association":"OWNER","user":{"login":"exampleorg"}},{"body":"%s","author_association":"COLLABORATOR","user":{"login":"other"}}]\n' "${MONITOR_CIRCUIT_BLOCKER}" "$source_marker"
    elif [[ -f "${MONITOR_TEST_LOG:-/dev/null}" ]] && grep -Fq 'aidevops:cloudron-source-ready ' "$MONITOR_TEST_LOG"; then
        printf '[{"body":"%s","author_association":"OWNER","user":{"login":"exampleorg"}}]\n' "$source_marker"
    elif [[ -n "${MONITOR_NEWER_PERMISSION:-}" ]]; then
        printf '[{"id":1,"created_at":"2026-09-24T01:00:00Z","body":"<!-- aidevops:terminal-blocker-circuit revision=012345678901234567890123 blocker=%s -->","author_association":"OWNER","user":{"login":"exampleorg"}},{"id":2,"created_at":"2026-09-24T02:00:00Z","body":"<!-- aidevops:terminal-blocker-circuit revision=012345678901234567890123 blocker=%s -->","author_association":"OWNER","user":{"login":"exampleorg"}}]\n' "${MONITOR_CIRCUIT_BLOCKER}" "${MONITOR_NEWER_PERMISSION}"
    elif [[ -n "${MONITOR_EXISTING_RETRY:-}" ]]; then
        printf '[{"id":1,"created_at":"2026-09-24T01:00:00Z","body":"<!-- aidevops:terminal-blocker-circuit revision=012345678901234567890123 blocker=%s -->","author_association":"OWNER","user":{"login":"exampleorg"}},{"id":2,"created_at":"2026-09-24T02:00:00Z","body":"terminal-blocker-circuit:retry","author_association":"OWNER","user":{"login":"exampleorg"}}]\n' "${MONITOR_CIRCUIT_BLOCKER}"
    else
        printf '[{"body":"<!-- aidevops:terminal-blocker-circuit revision=012345678901234567890123 blocker=%s -->","author_association":"OWNER","user":{"login":"exampleorg"}}]\n' "${MONITOR_CIRCUIT_BLOCKER:-none}"
    fi
    exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
    printf 'ATTEST %s\n' "$*" >>"${MONITOR_API_LOG:-/dev/null}"
    [[ "${MONITOR_IMAGE_STATE:-}" != unattested ]] || exit 1
    if [[ "$*" == *deployment-eligibility/v1* ]]; then
        [[ "${MONITOR_IMAGE_STATE:-}" != ineligible ]] || exit 1
        printf '%s\n' '[{"verificationResult":{"statement":{"subject":[{"name":"ghcr.io/exampleorg/upstream","digest":{"sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}],"predicate":{"eligible":true,"source":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repository":"exampleorg/upstream"},"build":{"workflow":".github/workflows/docker.yml"},"qualification":{"conclusion":"success"}}},"signature":{"certificate":{"sourceRepositoryDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}]'
        exit 0
    fi
    printf '%s\n' '[{"verificationResult":{"statement":{"subject":[{"name":"ghcr.io/exampleorg/upstream","digest":{"sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}]},"signature":{"certificate":{"sourceRepositoryDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}]'
    exit 0
fi
SOURCE
	return 0
}

write_fake_issue_wrapper() {
	local bin_dir="$1"
	cat >"${bin_dir}/gh_create_issue" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
repo=""
body_file=""
title=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'CALL %s\n' "$repo" >>"${MONITOR_TEST_LOG}"
printf 'TITLE %s\n' "$title" >>"${MONITOR_TEST_LOG}"
while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >>"${MONITOR_TEST_LOG}"
done <"$body_file"
WRAPPER
	cat >"${bin_dir}/gh_issue_comment" <<'COMMENT'
#!/usr/bin/env bash
set -euo pipefail
body_file=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body-file" ]]; then body_file="$2"; break; fi
    shift
done
printf 'CALL_RETRY\n' >>"${MONITOR_TEST_LOG}"
cat "$body_file" >>"${MONITOR_TEST_LOG}"
COMMENT
	cat >"${bin_dir}/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'INSPECT %s\n' "$*" >>"${MONITOR_API_LOG:-/dev/null}"
if [[ "${MONITOR_IMAGE_STATE:-missing}" == missing ]]; then
    printf '%s\n' 'not found' >&2
    exit 1
fi
if [[ "${MONITOR_IMAGE_STATE:-}" == unqualified ]]; then
    printf '%s\n' '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","annotations":{"org.opencontainers.image.revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","qualified":"failure"},"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'
else
    printf '%s\n' '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","annotations":{"org.opencontainers.image.revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","qualified":"success"},"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'
fi
DOCKER
	write_fake_source_commands "$bin_dir"
	chmod +x "${bin_dir}/gh_create_issue" "${bin_dir}/gh_issue_comment" "${bin_dir}/docker"
	return 0
}

write_fixture() {
	local home_dir="$1"
	local repo_dir="$2"
	mkdir -p "${home_dir}/.config/aidevops" "$repo_dir"
	cat >"${repo_dir}/CloudronManifest.json" <<'JSON'
{
  "id": "com.example.package",
  "title": "Example Package",
  "version": "1.0.0",
  "upstreamVersion": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "manifestVersion": 2,
  "addons": {"localstorage": {}}
}
JSON
	printf 'FROM %s\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	cat >"${home_dir}/.config/aidevops/repos.json" <<JSON
{
  "initialized_repos": [{
    "slug": "exampleorg/example-package",
    "path": "${repo_dir}",
    "app_type": "cloudron-package",
    "cloudron_package": {
      "manifest": "CloudronManifest.json",
      "upstream_slug": "exampleorg/upstream",
      "monitor_upstream": true,
      "monitor_compatibility": true
    }
  }]
}
JSON
	return 0
}

write_two_package_fixture() {
	local home_dir="$1"
	local repo_dir="$2"
	local second_repo_dir="${repo_dir}-two"
	local repos_tmp="${home_dir}/.config/aidevops/repos.tmp.json"
	write_fixture "$home_dir" "$repo_dir"
	mkdir -p "$second_repo_dir"
	cp "${repo_dir}/CloudronManifest.json" "${second_repo_dir}/CloudronManifest.json"
	jq --arg path "$second_repo_dir" '
		.initialized_repos += [(.initialized_repos[0]
			| .slug = "exampleorg/example-package-two"
			| .path = $path
			| .cloudron_package.upstream_slug = "exampleorg/upstream-two")]
	' "${home_dir}/.config/aidevops/repos.json" >"$repos_tmp"
	mv "$repos_tmp" "${home_dir}/.config/aidevops/repos.json"
	return 0
}

test_monitor_deduplicates_and_preserves_source() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/package"
	local bin_dir="${TEST_ROOT}/bin"
	local log_file="${TEST_ROOT}/issues.log"
	local api_log="${TEST_ROOT}/api.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	local manifest_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "new upstream release creates one target-local issue"
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v2.0.0 is available$' "$log_file")" "upstream issue title uses package manifest title"
	grep -Fq 'upstream-v2.0.0' "$log_file" && assert_equal true true "upstream issue carries stable fingerprint" || assert_equal true false "upstream issue carries stable fingerprint"
	grep -Fq '<!-- aidevops:brief-schema=v2 -->' "$log_file" && assert_equal true true "upstream issue uses brief schema v2" || assert_equal true false "upstream issue uses brief schema v2"
	grep -Fq '## Files Scope' "$log_file" && assert_equal true true "upstream issue has canonical files scope" || assert_equal true false "upstream issue has canonical files scope"
	grep -Fq '0123456789012345678901234567890123456789' "$log_file" && assert_equal true true "upstream issue records immutable remote evidence" || assert_equal true false "upstream issue records immutable remote evidence"
	grep -Fq -- '--paginate --jq .' "$api_log" && assert_equal true true "paginated release reads request page-delimited JSON" || assert_equal true false "paginated release reads request page-delimited JSON"
	assert_equal 2 "$(grep -c '^TIMEOUT 90$' "$api_log")" "paginated release reads use the monitor-specific timeout"
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "upstream monitor does not mutate manifest"

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL ' "$log_file")" "clean compatibility check creates no issue"
	printf 'FROM cloudron/base:5.1.0\n' >"${repo_dir}/Dockerfile"
	local docker_before=""
	docker_before=$(cksum "${repo_dir}/Dockerfile")
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 2 "$(grep -c '^CALL ' "$log_file")" "compatibility finding is deduplicated"
	assert_equal "$docker_before" "$(cksum "${repo_dir}/Dockerfile")" "compatibility monitor does not mutate package source"
	return 0
}

test_monitor_uses_remote_manifest_and_fails_closed() {
	local home_dir="${TEST_ROOT}/remote-home"
	local repo_dir="${TEST_ROOT}/remote-package"
	local bin_dir="${TEST_ROOT}/remote-bin"
	local log_file="${TEST_ROOT}/remote-issues.log"
	local output=""
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.upstreamVersion = "0.5.14"' "${repo_dir}/CloudronManifest.json" >"${repo_dir}/manifest.tmp"
	mv "${repo_dir}/manifest.tmp" "${repo_dir}/CloudronManifest.json"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		MONITOR_REMOTE_VERSION=0.5.18 \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	grep -Fq "records \`0.5.18\`" "$log_file" && assert_equal true true "remote manifest baseline overrides stale local checkout" || assert_equal true false "remote manifest baseline overrides stale local checkout"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_REMOTE_FAILURE=true bash "$HELPER" upstream 2>&1); then
		assert_equal false true "authoritative manifest failure stops monitoring"
	else
		[[ "$output" == *"Could not resolve the remote default branch"* ]] &&
			assert_equal true true "authoritative manifest failure stops monitoring" ||
			assert_equal true false "authoritative manifest failure reports actionable error"
	fi
	return 0
}

test_monitor_rejects_invalid_release_timeout() {
	local home_dir="${TEST_ROOT}/timeout-home"
	local repo_dir="${TEST_ROOT}/timeout-package"
	local bin_dir="${TEST_ROOT}/timeout-bin"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" AIDEVOPS_CLOUDRON_MONITOR_GH_TIMEOUT=invalid \
		bash "$HELPER" upstream 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "invalid monitor-specific timeout fails closed"
	[[ "$output" == *"AIDEVOPS_CLOUDRON_MONITOR_GH_TIMEOUT must be a positive integer"* ]] &&
		assert_equal true true "invalid monitor-specific timeout reports actionable error" ||
		assert_equal true false "invalid monitor-specific timeout reports actionable error"
	return 0
}

test_monitor_selects_configured_stream() {
	local home_dir="${TEST_ROOT}/stream-home"
	local repo_dir="${TEST_ROOT}/stream-package"
	local bin_dir="${TEST_ROOT}/stream-bin"
	local log_file="${TEST_ROOT}/stream-issues.log"
	local releases_file="${TEST_ROOT}/stream-releases.json"
	local config_tmp="${TEST_ROOT}/stream-repos.json"
	local manifest_tmp="${TEST_ROOT}/stream-manifest.json"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = ["desktop-v"]' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	jq '.upstreamVersion = "0.5.0"' "${repo_dir}/CloudronManifest.json" >"$manifest_tmp"
	mv "$manifest_tmp" "${repo_dir}/CloudronManifest.json"
	cat >"$releases_file" <<'JSON'
[
  {"tag_name":"desktop-v0.5.2","draft":false,"prerelease":false},
  {"tag_name":"v99.0.0","draft":false,"prerelease":false},
  {"tag_name":"desktop-v0.5.3","draft":false,"prerelease":false},
  {"tag_name":"desktop-v9.0.0","draft":true,"prerelease":false},
  {"tag_name":"desktop-v8.0.0","draft":false,"prerelease":true}
]
JSON

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		MONITOR_RELEASES_FILE="$releases_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "configured stream creates one issue"
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v0.5.3 is available$' "$log_file")" "configured prefix selects highest matching stable tag"
	assert_equal 0 "$(grep -c '^TITLE Example Package upstream v99.0.0 is available$' "$log_file" || true)" "configured prefix rejects numerically larger unrelated stream"
	return 0
}

test_monitor_rejects_malformed_prefixes() {
	local home_dir="${TEST_ROOT}/prefix-home"
	local repo_dir="${TEST_ROOT}/prefix-package"
	local bin_dir="${TEST_ROOT}/prefix-bin"
	local log_file="${TEST_ROOT}/prefix-issues.log"
	local config_tmp="${TEST_ROOT}/prefix-repos.json"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = []' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"

	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "empty upstream tag-prefix array fails closed"
	[[ "$output" == *"upstream_tag_prefixes for exampleorg/example-package must be a non-empty array of strings"* ]] &&
		assert_equal true true "malformed tag prefixes report actionable error" ||
		assert_equal true false "malformed tag prefixes report actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "malformed tag prefixes create no issue" || assert_equal true false "malformed tag prefixes create no issue"
	return 0
}

test_monitor_rejects_control_characters_in_prefixes() {
	local home_dir="${TEST_ROOT}/control-prefix-home"
	local repo_dir="${TEST_ROOT}/control-prefix-package"
	local bin_dir="${TEST_ROOT}/control-prefix-bin"
	local log_file="${TEST_ROOT}/control-prefix-issues.log"
	local config_tmp="${TEST_ROOT}/control-prefix-repos.json"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = ["desktop-v\nv"]' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"

	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "control character in upstream tag prefix fails closed"
	[[ "$output" == *"upstream_tag_prefixes for exampleorg/example-package must be a non-empty array of strings; control characters are forbidden"* ]] &&
		assert_equal true true "control character prefix reports actionable error" ||
		assert_equal true false "control character prefix reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "control character prefix creates no issue" || assert_equal true false "control character prefix creates no issue"
	return 0
}

test_monitor_fails_closed_on_release_api_error() {
	local home_dir="${TEST_ROOT}/api-home"
	local repo_dir="${TEST_ROOT}/api-package"
	local bin_dir="${TEST_ROOT}/api-bin"
	local log_file="${TEST_ROOT}/api-issues.log"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_FAIL=true \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "paginated release API failure fails closed"
	[[ "$output" == *"Could not fetch paginated GitHub releases for exampleorg/upstream"* ]] &&
		assert_equal true true "release API failure reports actionable error" ||
		assert_equal true false "release API failure reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "release API failure creates no issue" || assert_equal true false "release API failure creates no issue"
	return 0
}

assert_rate_limit_fixture() {
	local fixture="$1"
	local expected_status="$2"
	local expected_classification="$3"
	local case_root="${TEST_ROOT}/${fixture}"
	local home_dir="${case_root}/home"
	local repo_dir="${case_root}/package"
	local bin_dir="${case_root}/bin"
	local issue_log="${case_root}/issues.log"
	local api_log="${case_root}/api.log"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_two_package_fixture "$home_dir" "$repo_dir"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$issue_log" MONITOR_API_LOG="$api_log" \
		MONITOR_RATE_FIXTURE="$fixture" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 75 "$rc" "${fixture} returns EX_TEMPFAIL"
	assert_equal 1 "$(grep -c '^API ' "$api_log")" "${fixture} stops before the second registration"
	[[ ! -f "$issue_log" ]] && assert_equal true true "${fixture} creates no issue" || assert_equal true false "${fixture} creates no issue"
	local cooldown_file="${home_dir}/.aidevops/cache/gh-secondary-cooldown.json"
	local state_shape=""
	state_shape=$(jq -r '[.diagnostic.http_status, .diagnostic.body_classification] | @tsv' "$cooldown_file")
	assert_equal "${expected_status}"$'\t'"${expected_classification}" "$state_shape" "${fixture} records shared cooldown evidence"
	[[ "$output" == *"DEFERRED: GitHub API cooldown active until epoch"* ]] &&
		assert_equal true true "${fixture} emits a machine-distinguishable safe status" ||
		assert_equal true false "${fixture} emits a machine-distinguishable safe status"
	return 0
}

test_monitor_rate_limit_fixtures() {
	assert_rate_limit_fixture primary-403-reset 403 primary-rate-limit
	assert_rate_limit_fixture secondary-403-retry 403 secondary-rate-limit
	assert_rate_limit_fixture primary-429-retry 429 primary-rate-limit
	assert_rate_limit_fixture primary-429-reset 429 primary-rate-limit
	return 0
}

test_monitor_scheduler_cooldown_integration() {
	local case_root="${TEST_ROOT}/scheduler-integration"
	local home_dir="${case_root}/home"
	local repo_dir="${case_root}/package"
	local bin_dir="${case_root}/bin"
	local issue_log="${case_root}/issues.log"
	local api_log="${case_root}/api.log"
	local state_file="${case_root}/routine-state.json"
	local pulse_log="${case_root}/pulse.log"
	local old_home="$HOME"
	local old_path="$PATH"
	local deferred_until=0
	local blocked_rc=0
	local eligible_count=0
	local iteration=0
	write_fake_commands "$bin_dir"
	write_two_package_fixture "$home_dir" "$repo_dir"
	mkdir -p "${home_dir}/.aidevops/agents/scripts"
	cat >"${home_dir}/.aidevops/agents/scripts/rate-monitor.sh" <<WRAPPER
#!/usr/bin/env bash
exec bash "$HELPER" upstream --apply
WRAPPER
	chmod +x "${home_dir}/.aidevops/agents/scripts/rate-monitor.sh"

	export HOME="$home_dir"
	export PATH="${bin_dir}:${old_path}"
	export MONITOR_TEST_LOG="$issue_log"
	export MONITOR_API_LOG="$api_log"
	export MONITOR_RATE_FIXTURE=primary-403-reset
	export CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${home_dir}/.aidevops/cache/gh-secondary-cooldown.json"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="${home_dir}/.aidevops/cache/gh-cooldown-events.jsonl"
	export AIDEVOPS_ROUTINE_NOW_EPOCH=9999999900
	export AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS=7
	unset _SHARED_GH_SECONDARY_COOLDOWN_LOADED _PULSE_ROUTINES_LOADED
	# shellcheck source=../shared-gh-secondary-cooldown.sh
	source "$GH_COOLDOWN"
	ROUTINE_STATE_FILE="$state_file"
	LOGFILE="$pulse_log"
	ROUTINE_LOG_HELPER="${case_root}/missing-routine-log-helper"
	# shellcheck source=../pulse-routines.sh
	source "$PULSE_ROUTINES"

	_routine_execute r916 "Cloudron packages" scripts/rate-monitor.sh "" "$case_root"
	deferred_until=$(jq -r '.r916.deferred_until' "$state_file")
	assert_equal deferred "$(jq -r '.r916.last_status' "$state_file")" "rate-limited monitor is classified as deferred"
	[[ "$deferred_until" -ge 9999999999 && "$deferred_until" -le 10000000006 ]] &&
		assert_equal true true "scheduler persists reset plus bounded jitter" ||
		assert_equal true false "scheduler persists reset plus bounded jitter"
	assert_equal 1 "$(grep -c '^API ' "$api_log")" "integrated monitor touches only the first registration"

	AIDEVOPS_ROUTINE_NOW_EPOCH=$((deferred_until - 1))
	blocked_rc=0
	_routine_retry_blocked r916 || blocked_rc=$?
	assert_equal 0 "$blocked_rc" "deferred routine remains blocked before eligibility"
	AIDEVOPS_ROUTINE_NOW_EPOCH="$deferred_until"
	for iteration in 1 2; do
		blocked_rc=0
		_routine_retry_blocked r916 || blocked_rc=$?
		if [[ "$blocked_rc" -ne 0 ]]; then
			eligible_count=$((eligible_count + 1))
			_routine_update_state r916 running
		fi
	done
	assert_equal 1 "$eligible_count" "exactly one retry becomes eligible after cooldown expiry"

	export HOME="$old_home"
	export PATH="$old_path"
	unset MONITOR_TEST_LOG MONITOR_API_LOG MONITOR_RATE_FIXTURE CLOUDRON_PACKAGE_ISSUE_WRAPPER \
		AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE \
		AIDEVOPS_ROUTINE_NOW_EPOCH AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS
	return 0
}

test_monitor_rejects_blank_package_title() {
	local home_dir="${TEST_ROOT}/blank-title-home"
	local repo_dir="${TEST_ROOT}/blank-title-package"
	local bin_dir="${TEST_ROOT}/blank-title-bin"
	local log_file="${TEST_ROOT}/blank-title-issues.log"
	local manifest_tmp="${TEST_ROOT}/blank-title-manifest.json"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.title = ""' "${repo_dir}/CloudronManifest.json" >"$manifest_tmp"
	mv "$manifest_tmp" "${repo_dir}/CloudronManifest.json"
	local output=""
	local rc=0
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "blank package title fails closed"
	[[ "$output" == *"Manifest title is missing or blank for registered Cloudron package exampleorg/example-package."* ]] && assert_equal true true "blank package title reports actionable error" || assert_equal true false "blank package title reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "blank package title creates no issue" || assert_equal true false "blank package title creates no issue"
	return 0
}

test_monitor_waits_for_release_parent_image_and_rearms_once() {
	local case_root="${TEST_ROOT}/source-readiness" home_dir="" repo_dir="" bin_dir="" log_file="" api_log="" releases_file="" config_tmp="" blocker="" blocked_log="" permission_blocker=""
	home_dir="${case_root}/home"
	repo_dir="${case_root}/package"
	bin_dir="${case_root}/bin"
	log_file="${case_root}/issues.log"
	api_log="${case_root}/api.log"
	releases_file="${case_root}/releases.json"
	config_tmp="${case_root}/repos.tmp.json"
	blocked_log="${case_root}/blocked-issues.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package += {
		upstream_tag_prefixes: ["desktop-v"], upstream_image: {
		repository: "ghcr.io/exampleorg/upstream",
		signer_workflow: "exampleorg/upstream/.github/workflows/docker.yml",
		qualification_annotation: "qualified",
		eligibility_predicate_type: "https://exampleorg.test/attestations/deployment-eligibility/v1"}}' "${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	printf '%s\n' '[{"tag_name":"desktop-v2.0.0","draft":false,"prerelease":false}]' >"$releases_file"
	blocker=$(printf 'v2:target_code_blocker' | shasum -a 256 | cut -c1-24)
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=missing CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	[[ ! -f "$log_file" ]] && assert_equal true true "missing exact-parent image creates no worker issue" || assert_equal true false "missing exact-parent image creates no worker issue"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=unqualified CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	[[ ! -f "$log_file" ]] && assert_equal true true "unqualified parent image creates no worker issue" || assert_equal true false "unqualified parent image creates no worker issue"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=unattested CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	[[ ! -f "$log_file" ]] && assert_equal true true "unattested parent image creates no worker issue" || assert_equal true false "unattested parent image creates no worker issue"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=ineligible CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	[[ ! -f "$log_file" ]] && assert_equal true true "missing eligibility attestation creates no worker issue" || assert_equal true false "missing eligibility attestation creates no worker issue"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "qualified exact-parent image creates one actionable issue"
	grep -Fq 'desktop-v2.0.0 ghcr.io/exampleorg/upstream:sha-bbbbbbb sha256:cccc' "$log_file" && assert_equal true true "issue records immutable release-parent source proof" || assert_equal true false "issue records immutable release-parent source proof"
	cp "$log_file" "$blocked_log"
	permission_blocker=$(printf 'v2:permission_required' | shasum -a 256 | cut -c1-24)
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$blocked_log" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$permission_blocker" MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	[[ "$(grep -c '^CALL_RETRY$' "$blocked_log" || true)" == 0 ]] && assert_equal true true "positive image proof does not retry permission circuit" || assert_equal true false "positive image proof does not retry permission circuit"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$blocked_log" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_NEWER_PERMISSION="$permission_blocker" MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	[[ "$(grep -c '^CALL_RETRY$' "$blocked_log" || true)" == 0 ]] && assert_equal true true "newer permission hold wins over older target-code circuit" || assert_equal true false "newer permission hold wins over older target-code circuit"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$blocked_log" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_EXISTING_RETRY=true MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	[[ "$(grep -c '^CALL_RETRY$' "$blocked_log" || true)" == 0 ]] && assert_equal true true "existing trusted retry is not duplicated" || assert_equal true false "existing trusted retry is not duplicated"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$blocked_log" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_ISSUE_STATE=claimed MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	[[ "$(grep -c '^CALL_RETRY$' "$blocked_log" || true)" == 0 ]] && assert_equal true true "claimed issue is never rearmed by the routine" || assert_equal true false "claimed issue is never rearmed by the routine"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$blocked_log" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_FORGED_MARKER=true MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL_RETRY$' "$blocked_log")" "untrusted collaborator marker cannot suppress a proven-source retry"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" MONITOR_RELEASES_FILE="$releases_file" MONITOR_CIRCUIT_BLOCKER="$blocker" MONITOR_IMAGE_STATE=ready CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" CLOUDRON_PACKAGE_COMMENT_WRAPPER="${bin_dir}/gh_issue_comment" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL_RETRY$' "$log_file")" "existing target-code circuit receives one proven-source retry"
	grep -Fq 'terminal-blocker-circuit:retry' "$log_file" && assert_equal true true "ready source retry carries standalone circuit directive" || assert_equal true false "ready source retry carries standalone circuit directive"
	grep -Fq -- '--source-digest bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$api_log" && assert_equal true true "upstream attestation is bound to release-parent commit" || assert_equal true false "upstream attestation is bound to release-parent commit"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_monitor_deduplicates_and_preserves_source
	test_monitor_uses_remote_manifest_and_fails_closed
	test_monitor_rejects_invalid_release_timeout
	test_monitor_selects_configured_stream
	test_monitor_rejects_malformed_prefixes
	test_monitor_rejects_control_characters_in_prefixes
	test_monitor_fails_closed_on_release_api_error
	test_monitor_rate_limit_fixtures
	test_monitor_scheduler_cooldown_integration
	test_monitor_rejects_blank_package_title
	test_monitor_waits_for_release_parent_image_and_rearms_once
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
