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
PINNED_BASE='cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee'

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
if [[ "${1:-}" == "api" && ( "$*" == *releases\?per_page=100* || "$*" == *tags\?per_page=100* ) ]]; then
    endpoint=""
    for arg in "$@"; do
        [[ "$arg" == /repos/*/releases\?per_page=100 || "$arg" == /repos/*/tags\?per_page=100 ]] && endpoint="$arg"
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
	write_fake_catalog_commands "$bin_dir"
	chmod +x "${bin_dir}/gh"
	return 0
}

write_fake_catalog_commands() {
	local bin_dir="$1"
	cat >>"${bin_dir}/gh-source" <<'CATALOG'
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    printf '%s\n' 'ADMIN'
    exit 0
fi
if [[ "${1:-}" == api && "${2:-}" == /repos/*/actions/variables ]]; then
    printf '%s' "${MONITOR_PUBLICATION_ENABLED:-false}"
    exit 0
fi
if [[ "${1:-}" == api && "${2:-}" == /repos/*/contents/CloudronVersions.json* ]]; then
    [[ "${MONITOR_CATALOG_STATE:-}" != error ]] || exit 1
    if [[ "${MONITOR_CATALOG_STATE:-}" == published ]]; then
        printf '%s\n' '{"versions":{"1.0.0":{}}}'
    else
        printf '%s\n' '{"versions":{}}'
    fi
    exit 0
fi
if [[ "${1:-}" == api && "${2:-}" == /repos/*/actions/workflows/cloudron-catalog-publish.yml/runs* ]]; then
    printf '%s\n' "${MONITOR_ACTIVE_RUNS:-0}"
    exit 0
fi
if [[ "${1:-}" == workflow && "${2:-}" == run ]]; then
    printf 'DISPATCH %s\n' "$*" >>"${MONITOR_TEST_LOG}"
    [[ "${MONITOR_DISPATCH_FAIL:-false}" != true ]] || exit 1
    exit 0
fi
CATALOG
	return 0
}

# Label inventory/create stubs, appended to the gh-source file the gh stub sources.
write_fake_label_commands() {
	local bin_dir="$1"
	cat >>"${bin_dir}/gh-source" <<'LABELS'
if [[ "${1:-}" == "api" && "${2:-}" == /repos/*/labels\?per_page=100 ]]; then
    printf 'LABEL_LIST %s\n' "${2}" >>"${MONITOR_LABEL_LOG:-/dev/null}"
    printf '%s\n' ${MONITOR_LABELS-type:maintenance}
    exit 0
fi
if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
    printf 'LABEL_CREATE %s\n' "$*" >>"${MONITOR_LABEL_LOG:-/dev/null}"
    [[ "${MONITOR_LABEL_CREATE_FAIL:-false}" != true ]] || exit 1
    exit 0
fi
LABELS
	return 0
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

write_fake_commit_source_commands() {
	local bin_dir="$1"
	cat >>"${bin_dir}/gh-source" <<'COMMITS'
if [[ "${1:-}" == "api" && "${2:-}" == "/repos/exampleorg/upstream" ]]; then
    printf '%s\n' '{"default_branch":"trunk"}'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "/repos/exampleorg/upstream/commits/${MONITOR_EXPECT_BRANCH:-trunk}" ]]; then
    printf '{"sha":"%s","commit":{"committer":{"date":"2026-10-16T01:02:03Z"},"message":"Fix crawler\\n\\nbody"}}\n' "${MONITOR_UPSTREAM_HEAD}"
    exit 0
fi
COMMITS
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
if [[ "${MONITOR_IMAGE_STATE:-}" == withdrawn ]]; then
    printf "%s\n" "no such manifest: $*" >&2
    exit 1
fi
if [[ "${MONITOR_IMAGE_STATE:-}" == neterror ]]; then
    printf "%s\n" "dial tcp: connection timed out" >&2
    exit 1
fi
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
	write_fake_label_commands "$bin_dir"
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
	printf 'FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e\n' >"${repo_dir}/Dockerfile"
	local docker_before=""
	docker_before=$(cksum "${repo_dir}/Dockerfile")
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 2 "$(grep -c '^CALL ' "$log_file")" "compatibility finding is deduplicated"
	assert_equal 1 "$(grep -c '^- Upgrade base image' "$log_file")" "legacy upgrade creates one actionable finding"
	grep -Fq 'minBoxVersion' "$log_file" && assert_equal true true "upgrade issue includes platform qualification" || assert_equal true false "upgrade issue includes platform qualification"
	assert_equal "$docker_before" "$(cksum "${repo_dir}/Dockerfile")" "compatibility monitor does not mutate package source"
	return 0
}

test_monitor_scopes_package_tests_when_present() {
	local presence=""
	local home_dir=""
	local repo_dir=""
	local bin_dir=""
	local log_file=""
	local expected=0
	for presence in absent present; do
		home_dir="${TEST_ROOT}/scope-${presence}-home"
		repo_dir="${TEST_ROOT}/scope-${presence}-package"
		bin_dir="${TEST_ROOT}/scope-${presence}-bin"
		log_file="${TEST_ROOT}/scope-${presence}-issues.log"
		write_fake_commands "$bin_dir"
		write_fixture "$home_dir" "$repo_dir"
		if [[ "$presence" == present ]]; then
			mkdir -p "${repo_dir}/test"
			printf '# Package version and digest assertions\n' >"${repo_dir}/test/package-test.sh"
			expected=2
		fi
		printf 'FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e\n' >"${repo_dir}/Dockerfile"
		HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
		HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
		assert_equal 2 "$(grep -c '^CALL ' "$log_file")" "both finding types generated with package tests ${presence}"
		assert_equal "$expected" "$(grep -c "^- \`test/package-test.sh\`$" "$log_file" || true)" "package tests ${presence}: exact scope path on its own line"
		assert_equal "$expected" "$(grep -c "^- \`test/package-test.sh\`: version and digest assertions that must track the bump\.$" "$log_file" || true)" "package tests ${presence}: matching file note"
	done
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

test_monitor_selects_tag_source() {
	local home_dir="${TEST_ROOT}/tags-home" repo_dir="${TEST_ROOT}/tags-package" bin_dir="${TEST_ROOT}/tags-bin"
	local log_file="${TEST_ROOT}/tags-issues.log" api_log="${TEST_ROOT}/tags-api.log"
	local tags_file="${TEST_ROOT}/tags-pages.json" config_tmp="${TEST_ROOT}/tags-repos.json" output="" rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package |= (.upstream_source = "tags" | .upstream_tag_prefixes = ["desktop-v"])' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	printf '%s\n' '[{"name":"desktop-v1.2.0"},{"name":"v99.0.0"}]' '[{"name":"desktop-v2.0.0-rc.1"},{"name":"desktop-v1.10.0"}]' >"$tags_file"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" \
		MONITOR_RELEASES_FILE="$tags_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v1.10.0 is available$' "$log_file")" "tag source selects highest stable matching semantic tag across pages"
	grep -Fq '/repos/exampleorg/upstream/tags?per_page=100' "$api_log" && assert_equal true true "tag source queries paginated tags" || assert_equal true false "tag source queries paginated tags"
	jq '.initialized_repos[0].cloudron_package.upstream_source = "invalid"' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" bash "$HELPER" upstream 2>&1); then rc=0; else rc=$?; fi
	assert_equal 1 "$rc" "invalid upstream source fails closed"
	[[ "$output" == *"cloudron_package.upstream_source"* ]] && assert_equal true true "invalid source reports diagnostic" || assert_equal true false "invalid source reports diagnostic"
	return 0
}

test_monitor_follows_commit_source() {
	local home_dir="${TEST_ROOT}/commits-home" repo_dir="${TEST_ROOT}/commits-package" bin_dir="${TEST_ROOT}/commits-bin"
	local log_file="${TEST_ROOT}/commits-issues.log" config_tmp="${TEST_ROOT}/commits-repos.json" output="" rc=0
	local pin="05a1372" head_equal="05a1372aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" head_new="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	write_fake_commands "$bin_dir"
	write_fake_commit_source_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_source = "commits"' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_REMOTE_VERSION="$pin" \
		MONITOR_UPSTREAM_HEAD="$head_equal" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply >/dev/null && rc=0 || rc=$?
	assert_equal 0 "$rc" "commit source exits 0 when head matches the pin"
	[[ ! -f "$log_file" ]] && assert_equal true true "commit source files no finding when head matches the pin" || assert_equal true false "commit source files no finding when head matches the pin"

	local run=0
	for run in 1 2; do
		HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_REMOTE_VERSION="$pin" \
			MONITOR_UPSTREAM_HEAD="$head_new" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
			bash "$HELPER" upstream --apply >/dev/null
	done
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "moved head creates one deduplicated finding across reruns"
	grep -Fq "upstream-commit-${head_new}" "$log_file" && assert_equal true true "commit finding fingerprints the head SHA" || assert_equal true false "commit finding fingerprints the head SHA"
	grep -Fq 'Fix crawler' "$log_file" && grep -Fq '2026-10-16T01:02:03Z' "$log_file" && assert_equal true true "commit finding records head date and message" || assert_equal true false "commit finding records head date and message"

	jq '.initialized_repos[0].cloudron_package.upstream_branch = "release/x"' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	rm -f "$log_file"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_REMOTE_VERSION="$pin" MONITOR_EXPECT_BRANCH="release/x" \
		MONITOR_UPSTREAM_HEAD="$head_new" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "explicit upstream_branch is honoured"

	rm -f "$log_file"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_REMOTE_VERSION="1.2.3" \
		MONITOR_EXPECT_BRANCH="release/x" MONITOR_UPSTREAM_HEAD="$head_new" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then rc=0; else rc=$?; fi
	assert_equal 1 "$rc" "non-SHA upstreamVersion fails closed in commit mode"
	[[ "$output" == *"hex commit SHA prefix"* ]] && assert_equal true true "non-SHA upstreamVersion reports diagnostic" || assert_equal true false "non-SHA upstreamVersion reports diagnostic"
	[[ ! -f "$log_file" ]] && assert_equal true true "non-SHA upstreamVersion creates no issue" || assert_equal true false "non-SHA upstreamVersion creates no issue"
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
	local attempts=0
	local terminal_status=""
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
	# Script routines run in a detached child that alone writes state; wait
	# (bounded) for its terminal status instead of racing the dispatcher.
	while [[ "$attempts" -lt 400 ]]; do
		if [[ -f "$state_file" ]]; then
			terminal_status=$(jq -r '.r916.last_status // ""' "$state_file" 2>/dev/null) || terminal_status=""
			[[ -z "$terminal_status" || "$terminal_status" == "running" ]] || break
		fi
		sleep 0.05
		attempts=$((attempts + 1))
	done
	deferred_until=$(jq -r '.r916.deferred_until' "$state_file")
	assert_equal deferred "$(jq -r '.r916.last_status' "$state_file")" "rate-limited monitor is classified as deferred"
	[[ "$deferred_until" -ge 9999999999 && "$deferred_until" -le 10000000006 ]] &&
		assert_equal true true "scheduler persists reset plus bounded jitter" ||
		assert_equal true false "scheduler persists reset plus bounded jitter (deferred_until=${deferred_until})"
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

test_monitor_reports_withdrawn_docker_sources() {
	local home_dir="${TEST_ROOT}/src-home"
	local repo_dir="${TEST_ROOT}/src-package"
	local bin_dir="${TEST_ROOT}/src-bin"
	local log_file="${TEST_ROOT}/src-issues.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	printf 'FROM --platform=linux/amd64 quay.io/minio/minio:RELEASE.1@sha256:aaaa AS minio\nFROM minio AS stage2\nFROM %s\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	: >"$log_file"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_IMAGE_STATE=neterror MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null 2>&1
	assert_equal 0 "$(grep -c '^CALL ' "$log_file" || true)" "network errors create no unavailable-source finding"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_IMAGE_STATE=withdrawn MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null 2>&1
	assert_equal 1 "$(grep -c '^CALL ' "$log_file")" "withdrawn pinned source creates one finding"
	grep -Fq 'quay.io/minio/minio:RELEASE.1@sha256:aaaa (Dockerfile line 1)' "$log_file" && assert_equal true true "finding names image and line" || assert_equal true false "finding names image and line"
	return 0
}

test_monitor_ensures_maintenance_label() {
	local home_dir="${TEST_ROOT}/label-home"
	local repo_dir="${TEST_ROOT}/label-package"
	local bin_dir="${TEST_ROOT}/label-bin"
	local log_file="${TEST_ROOT}/label-issues.log"
	local label_log="${TEST_ROOT}/label-writes.log"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"

	# Label present: read-only, finding filed.
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_LABEL_LOG="$label_log" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "finding filed when label exists"
	assert_equal 0 "$(grep -c '^LABEL_CREATE' "$label_log")" "no label write when type:maintenance exists"

	# Label missing: created, then finding filed.
	rm -f "$log_file" "$label_log"
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_LABEL_LOG="$label_log" MONITOR_LABELS="bug" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^LABEL_CREATE label create type:maintenance --repo exampleorg/example-package' "$label_log")" "missing label is created"
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "finding filed after label creation"

	# Label creation fails: error, non-zero, no unlabelled issue.
	rm -f "$log_file" "$label_log"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_LABEL_LOG="$label_log" MONITOR_LABELS="bug" \
		MONITOR_LABEL_CREATE_FAIL=true CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "failed label creation fails the run"
	[[ "$output" == *"Could not create label type:maintenance in exampleorg/example-package"* ]] &&
		assert_equal true true "label failure names repo and label" ||
		assert_equal true false "label failure names repo and label"
	[[ ! -f "$log_file" ]] && assert_equal true true "no unlabelled issue after label failure" || assert_equal true false "no unlabelled issue after label failure"
	return 0
}

test_monitor_reconciles_catalog_once() {
	local home_dir="${TEST_ROOT}/catalog-home" repo_dir="${TEST_ROOT}/catalog-package" bin_dir="${TEST_ROOT}/catalog-bin"
	local log_file="${TEST_ROOT}/catalog.log" output="" rc=0 run=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	# Keep upstream detection idle, isolating the publication-recovery path.
	output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_REMOTE_VERSION=2.0.0 MONITOR_PUBLICATION_ENABLED=true \
		MONITOR_TEST_LOG="$log_file" bash "$HELPER" upstream)
	[[ "$output" == *"manifest v1.0.0 is absent"* ]] && assert_equal true true "dry run reports catalog drift" || assert_equal true false "dry run reports catalog drift"
	[[ ! -f "$log_file" ]] && assert_equal true true "dry run never dispatches" || assert_equal true false "dry run never dispatches"
	for run in disabled published active error dispatch-error; do
		rc=0
		HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_REMOTE_VERSION=2.0.0 MONITOR_TEST_LOG="$log_file" \
			MONITOR_PUBLICATION_ENABLED="$([[ "$run" != disabled ]] && printf true || printf false)" \
			MONITOR_CATALOG_STATE="$run" MONITOR_ACTIVE_RUNS="$([[ "$run" == active ]] && printf 1 || printf 0)" \
			MONITOR_DISPATCH_FAIL="$([[ "$run" == dispatch-error ]] && printf true || printf false)" \
			bash "$HELPER" upstream --apply >/dev/null 2>&1 || rc=$?
		case "$run" in
		error | dispatch-error) assert_equal 1 "$rc" "$run fails closed" ;;
		*) assert_equal 0 "$rc" "$run does not require dispatch" ;;
		esac
	done
	assert_equal 1 "$(grep -c '^DISPATCH ' "$log_file")" "only failed dispatch was attempted"
	for run in 1 2; do
		HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_REMOTE_VERSION=2.0.0 MONITOR_PUBLICATION_ENABLED=true \
			MONITOR_TEST_LOG="$log_file" bash "$HELPER" upstream --apply >/dev/null
	done
	assert_equal 2 "$(grep -c '^DISPATCH ' "$log_file")" "failed dispatch retries, successful dispatch is deduplicated"
	grep -Fq 'workflow run cloudron-catalog-publish.yml --repo exampleorg/example-package --ref main' "$log_file" &&
		assert_equal true true "reconciliation uses the enabled main caller" || assert_equal true false "reconciliation uses the enabled main caller"
	return 0
}

test_catalog_atomic_push_races() {
	# Execute the actual workflow shell against disposable local bare remotes.
	python3 - "$SCRIPT_DIR/../../../.github/workflows/cloudron-catalog-publish-reusable.yml" "$TEST_ROOT" <<'PY'
import os
import pathlib
import subprocess
import sys
import textwrap

workflow = pathlib.Path(sys.argv[1]).read_text()
step = workflow.split('      - name: Commit catalog and push tag atomically\n', 1)[1]
script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n  release:', 1)[0])
editor = pathlib.Path(sys.argv[2]) / 'tag-editor'
editor.write_text('#!/usr/bin/env python3\nimport pathlib, sys\npathlib.Path(sys.argv[1]).write_text("Catalog test tag\\n")\n')
editor.chmod(0o755)
env = dict(os.environ, GIT_AUTHOR_NAME='Catalog Test', GIT_AUTHOR_EMAIL='test@example.invalid',
           GIT_COMMITTER_NAME='Catalog Test', GIT_COMMITTER_EMAIL='test@example.invalid', GIT_EDITOR=str(editor))

def git(cwd, *args):
    result = subprocess.run(['git', *args], cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()

for scenario in ('unchanged', 'docs', 'source', 'reverted-source', 'renamed-source', 'catalog', 'second-race'):
    root = pathlib.Path(sys.argv[2]) / ('push-' + scenario)
    root.mkdir()
    remote, worker, racer = (root / name for name in ('origin.git', 'worker', 'racer'))
    git(root, 'init', '--bare', '--initial-branch=main', str(remote))
    git(root, 'clone', str(remote), str(worker))
    (worker / 'CloudronVersions.json').write_text('{"versions":{}}\n')
    (worker / 'Dockerfile').write_text('FROM scratch\n')
    git(worker, 'add', '.')
    git(worker, 'commit', '-m', 'validated package')
    source = git(worker, 'rev-parse', 'HEAD')
    git(worker, 'push', 'origin', 'HEAD:main')
    git(root, 'clone', str(remote), str(racer))
    if scenario != 'unchanged':
        path = 'README.md' if scenario in ('docs', 'second-race') else 'CloudronVersions.json' if scenario == 'catalog' else 'Dockerfile'
        (racer / path).write_text('concurrent change\n')
        git(racer, 'add', '.')
        git(racer, 'commit', '-m', 'concurrent change')
        if scenario == 'reverted-source':
            git(racer, 'revert', '--no-edit', 'HEAD')
        if scenario == 'renamed-source':
            git(racer, 'mv', 'Dockerfile', 'README.md')
            git(racer, 'commit', '-m', 'rename source into docs')
        git(racer, 'push', 'origin', 'HEAD:main')
    if scenario == 'second-race':
        # Reject the second push to prove there is no retry loop.
        hook = remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
    expected_main = git(racer, 'ls-remote', 'origin', 'refs/heads/main').split()[0]
    catalog = '{"versions":{"1.0.0":{}}}\n'
    (worker / 'CloudronVersions.json').write_text(catalog)
    result = subprocess.run(['bash', '-c', script], cwd=worker,
                            env=dict(env, SOURCE_SHA=source, VERSION='1.0.0', RELEASE_PAT='test-placeholder'),
                            text=True, capture_output=True)
    success = scenario in ('unchanged', 'docs')
    assert (result.returncode == 0) == success, (scenario, result.stdout, result.stderr)
    tag = git(worker, 'ls-remote', 'origin', 'refs/tags/v1.0.0')
    assert bool(tag) == success, scenario
    if success:
        git(racer, 'fetch', 'origin', 'main', '--tags')
        assert git(racer, 'show', 'v1.0.0:CloudronVersions.json') == catalog.strip()
        assert git(racer, 'show', '-s', '--format=%(trailers:key=Cloudron-Source,valueonly)', 'v1.0.0^{commit}') == source
        git(racer, 'merge-base', '--is-ancestor', source, 'v1.0.0')
        assert git(racer, 'diff-tree', '--no-commit-id', '--name-only', '-r', 'v1.0.0') == 'CloudronVersions.json'
        release = workflow.split('      - name: Verify existing tag, public image and catalog; repair release only\n', 1)[1]
        verification = textwrap.dedent(release.split('        run: |\n', 1)[1]).split('image=$(jq', 1)[0]
        checked = subprocess.run(['bash', '-c', verification + '\ntest "$source_sha" = "$EXPECTED_SOURCE"'],
                                 cwd=racer, env=dict(env, VERSION='1.0.0', RUNNER_TEMP=str(root), EXPECTED_SOURCE=source),
                                 text=True, capture_output=True)
        assert checked.returncode == 0, (scenario, checked.stderr)
    else:
        assert git(racer, 'ls-remote', 'origin', 'refs/heads/main').split()[0] == expected_main
    print('PASS workflow atomic push:', scenario)
PY
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_catalog_atomic_push_races
	test_monitor_reconciles_catalog_once
	test_monitor_deduplicates_and_preserves_source
	test_monitor_scopes_package_tests_when_present
	test_monitor_uses_remote_manifest_and_fails_closed
	test_monitor_rejects_invalid_release_timeout
	test_monitor_selects_configured_stream
	test_monitor_selects_tag_source
	test_monitor_follows_commit_source
	test_monitor_rejects_malformed_prefixes
	test_monitor_rejects_control_characters_in_prefixes
	test_monitor_fails_closed_on_release_api_error
	test_monitor_rate_limit_fixtures
	test_monitor_scheduler_cooldown_integration
	test_monitor_rejects_blank_package_title
	test_monitor_waits_for_release_parent_image_and_rearms_once
	test_monitor_reports_withdrawn_docker_sources
	test_monitor_ensures_maintenance_label
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
