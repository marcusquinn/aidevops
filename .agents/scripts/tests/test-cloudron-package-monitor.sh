#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-monitor-helper.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c'

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
if [[ "${1:-}" == "api" && "${2:-}" == repos/*/releases/latest ]]; then
    printf '%s\n' 'v2.0.0'
    exit 0
fi
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
	cat >"${bin_dir}/gh_create_issue" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
repo=""
body_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'CALL %s\n' "$repo" >>"${MONITOR_TEST_LOG}"
while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >>"${MONITOR_TEST_LOG}"
done <"$body_file"
WRAPPER
	chmod +x "${bin_dir}/gh" "${bin_dir}/gh_create_issue"
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

test_monitor_deduplicates_and_preserves_source() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/package"
	local bin_dir="${TEST_ROOT}/bin"
	local log_file="${TEST_ROOT}/issues.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	local manifest_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "new upstream release creates one target-local issue"
	grep -Fq 'upstream-v2.0.0' "$log_file" && assert_equal true true "upstream issue carries stable fingerprint" || assert_equal true false "upstream issue carries stable fingerprint"
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "upstream monitor does not mutate manifest"

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL ' "$log_file")" "clean compatibility check creates no issue"
	printf 'FROM cloudron/base:5.0.0\n' >"${repo_dir}/Dockerfile"
	local docker_before=""
	docker_before=$(cksum "${repo_dir}/Dockerfile")
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 2 "$(grep -c '^CALL ' "$log_file")" "compatibility finding is deduplicated"
	assert_equal "$docker_before" "$(cksum "${repo_dir}/Dockerfile")" "compatibility monitor does not mutate package source"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_monitor_deduplicates_and_preserves_source
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
