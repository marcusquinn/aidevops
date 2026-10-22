#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-helper.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee'
LEGACY_BASE='cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e'

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

pass() {
	local description="$1"
	printf 'PASS %s\n' "$description"
	PASSED=$((PASSED + 1))
	return 0
}

fail() {
	local description="$1"
	printf 'FAIL %s\n' "$description" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	[[ "$expected" == "$actual" ]] && pass "$description" || fail "$description (expected=$expected actual=$actual)"
	return 0
}

make_fixture() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	cat >"${repo_dir}/CloudronManifest.json" <<'JSON'
{
  "id": "com.example.package",
  "title": "Example Package",
  "version": "1.0.0",
  "upstreamVersion": "4.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "manifestVersion": 2,
  "addons": {"localstorage": {}}
}
JSON
	printf 'FROM %s\nCMD ["/app/code/start.sh"]\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	cat >"${repo_dir}/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [1.0.0] - 2026-01-01

- Initial package.
CHANGELOG
	printf '%s\n' '- Package upstream 4.5.6 and refresh compatibility checks.' >"${repo_dir}/release-notes.md"
	return 0
}

run_helper() {
	local repo_dir="$1"
	shift
	(cd "$repo_dir" && bash "$HELPER" "$@")
	return $?
}

write_fake_docker() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "buildx" ]]; then
	[[ "${FAKE_BUILDX:-}" == available ]] || exit 1
	[[ "${2:-}" == version ]] && exit 0
	[[ "${2:-}" == imagetools && "${3:-}" == inspect ]] || exit 1
	[[ "${5:-}" == --format && "${6:-}" == '{{json .Manifest.MediaType}}' ]] || exit 1
	[[ "${4:-}" != *"unavailable"* ]]
	exit $?
fi
[[ "${1:-}" == "manifest" && "${2:-}" == "inspect" ]] || exit 1
if [[ "${FAKE_BUILDX:-}" == available ]]; then
	# Reject valid OCI sources, but accept unavailable sources to catch fallback.
	[[ "${3:-}" == *"unavailable"* ]]
	exit $?
fi
[[ "${3:-}" != *"unavailable"* ]]
DOCKER
	chmod +x "${bin_dir}/docker"
	return 0
}

test_prepare_and_validate_release() {
	local repo_dir="${TEST_ROOT}/valid"
	make_fixture "$repo_dir"
	if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null; then
		pass "valid release preparation succeeds"
	else
		fail "valid release preparation succeeds"
	fi
	assert_equal 1.2.0 "$(jq -r '.version' "${repo_dir}/CloudronManifest.json")" "package version updated"
	assert_equal 4.5.6 "$(jq -r '.upstreamVersion' "${repo_dir}/CloudronManifest.json")" "upstream version updated"
	grep -Fq '## [1.2.0]' "${repo_dir}/CHANGELOG.md" && pass "changelog release heading added" || fail "changelog release heading added"
	grep -Fq 'Package upstream 4.5.6' "${repo_dir}/CHANGELOG.md" && pass "non-empty release notes added" || fail "non-empty release notes added"
	run_helper "$repo_dir" check-release v1.2.0 >/dev/null && pass "matching tag validates" || fail "matching tag validates"
	if run_helper "$repo_dir" check-release v1.2.1 >/dev/null 2>&1; then
		fail "mismatched tag rejected"
	else
		pass "mismatched tag rejected"
	fi
	return 0
}

test_cloudron_changelog() {
	local repo_dir="${TEST_ROOT}/cloudron"
	local manifest_path="${repo_dir}/CloudronManifest.json"
	local changelog_path="${repo_dir}/CHANGELOG"
	local manifest_before=""
	local changelog_before=""
	make_fixture "$repo_dir"
	jq '.changelog = "file://CHANGELOG"' "$manifest_path" >"${manifest_path}.tmp"
	mv "${manifest_path}.tmp" "$manifest_path"
	rm "${repo_dir}/CHANGELOG.md"
	printf '[1.0.0]\n\n- Initial package.\n' >"$changelog_path"
	run_helper "$repo_dir" check-release v1.0.0 >/dev/null && pass "manifest Cloudron changelog validates without CHANGELOG.md" || fail "manifest Cloudron changelog validates without CHANGELOG.md"
	chmod 640 "$changelog_path"
	run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null && pass "Cloudron preparation succeeds" || fail "Cloudron preparation succeeds"
	grep -Fxq '[1.2.0]' "$changelog_path" && pass "Cloudron heading has no prefix or date" || fail "Cloudron heading has no prefix or date"
	grep -Fxq '[1.0.0]' "$changelog_path" && pass "existing Cloudron section preserved" || fail "existing Cloudron section preserved"
	[[ ! -f "${repo_dir}/CHANGELOG.md" ]] && pass "prepare does not create a second changelog" || fail "prepare does not create a second changelog"
	run_helper "$repo_dir" check-release v1.2.0 >/dev/null && pass "prepared Cloudron notes validate" || fail "prepared Cloudron notes validate"
	manifest_before=$(cksum "$manifest_path")
	changelog_before=$(cksum "$changelog_path")
	if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null 2>&1; then
		fail "duplicate Cloudron version rejected"
	else
		pass "duplicate Cloudron version rejected"
	fi
	assert_equal "$manifest_before" "$(cksum "$manifest_path")" "duplicate preserves manifest"
	assert_equal "$changelog_before" "$(cksum "$changelog_path")" "duplicate preserves Cloudron changelog"
	printf '[1.2.0]\n\n## [1.0.0] - 2026-01-01\n\n- Older notes.\n' >"$changelog_path"
	if run_helper "$repo_dir" check-release v1.2.0 >/dev/null 2>&1; then
		fail "empty Cloudron section cannot borrow Markdown notes"
	else
		pass "empty Cloudron section cannot borrow Markdown notes"
	fi
	printf '## [1.2.0]\n\n[1.0.0]\n\n- Older notes.\n' >"$changelog_path"
	if run_helper "$repo_dir" check-release v1.2.0 >/dev/null 2>&1; then
		fail "empty Markdown section cannot borrow Cloudron notes"
	else
		pass "empty Markdown section cannot borrow Cloudron notes"
	fi
	printf 'Mention [1.2.0]\n[1x2x0]\n\n- Not this version.\n' >"$changelog_path"
	if run_helper "$repo_dir" check-release v1.2.0 >/dev/null 2>&1; then
		fail "headings require literal version at line start"
	else
		pass "headings require literal version at line start"
	fi
	return 0
}

test_changelog_paths() {
	local repo_dir="${TEST_ROOT}/paths"
	local manifest_path="${repo_dir}/CloudronManifest.json"
	local changelog=""
	local manifest_before=""
	local changelog_before=""
	make_fixture "$repo_dir"
	for changelog in 'file://' 'file:///CHANGELOG' 'file://../CHANGELOG' 'file://notes/../CHANGELOG' 'file://notes/..'; do
		jq --arg changelog "$changelog" '.changelog = $changelog' "$manifest_path" >"${manifest_path}.tmp"
		mv "${manifest_path}.tmp" "$manifest_path"
		manifest_before=$(cksum "$manifest_path")
		changelog_before=$(cksum "${repo_dir}/CHANGELOG.md")
		if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null 2>&1; then
			fail "unsafe changelog path rejected: $changelog"
		else
			pass "unsafe changelog path rejected: $changelog"
		fi
		assert_equal "$manifest_before" "$(cksum "$manifest_path")" "unsafe path preserves manifest"
		assert_equal "$changelog_before" "$(cksum "${repo_dir}/CHANGELOG.md")" "unsafe path preserves fallback"
	done
	jq '.changelog = "https://example.com/changelog"' "$manifest_path" >"${manifest_path}.tmp"
	mv "${manifest_path}.tmp" "$manifest_path"
	run_helper "$repo_dir" check-release v1.0.0 >/dev/null && pass "non-file changelog falls back to CHANGELOG.md" || fail "non-file changelog falls back to CHANGELOG.md"
	mkdir "${repo_dir}/release notes"
	mv "${repo_dir}/CHANGELOG.md" "${repo_dir}/release notes/CHANGELOG"
	jq '.changelog = "file://release notes/CHANGELOG"' "$manifest_path" >"${manifest_path}.tmp"
	mv "${manifest_path}.tmp" "$manifest_path"
	run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null && pass "nested manifest path with spaces prepares" || fail "nested manifest path with spaces prepares"
	grep -Eq '^## \[1\.2\.0\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "${repo_dir}/release notes/CHANGELOG" && pass "manifest Markdown file keeps dated format" || fail "manifest Markdown file keeps dated format"
	run_helper "$repo_dir" check-release v1.2.0 >/dev/null && pass "nested manifest path validates" || fail "nested manifest path validates"
	return 0
}

test_release_preflight_validates_immutable_sources() {
	local repo_dir="${TEST_ROOT}/preflight"
	local bin_dir="${TEST_ROOT}/preflight-bin"
	make_fixture "$repo_dir"
	write_fake_docker "$bin_dir"
	PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.0.0 >/dev/null && pass "available immutable sources pass preflight" || fail "available immutable sources pass preflight"
	FAKE_BUILDX=available PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.0.0 >/dev/null && pass "Buildx resolves sources rejected by legacy manifest inspection" || fail "Buildx resolves sources rejected by legacy manifest inspection"
	printf 'FROM example/unavailable:1.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nFROM %s\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	local output=""
	if output=$(FAKE_BUILDX=available PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.0.0 2>&1); then
		fail "Buildx unavailable immutable source blocks preflight"
	elif [[ "$output" == *"Immutable Docker source is unavailable"* ]]; then
		pass "Buildx unavailable immutable source reports expected error"
	else
		fail "Buildx unavailable immutable source reports expected error"
	fi
	if PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.0.0 >/dev/null 2>&1; then
		fail "unavailable immutable source blocks preflight"
	else
		pass "unavailable immutable source blocks preflight"
	fi
	printf 'FROM --platform=linux/amd64 %s AS build\nFROM %s\n' "$PINNED_BASE" "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.0.0 >/dev/null 2>&1 && pass "FROM platform flag skipped in preflight" || fail "FROM platform flag skipped in preflight"
	return 0
}

test_invalid_prepare_is_non_mutating() {
	local repo_dir="${TEST_ROOT}/invalid"
	make_fixture "$repo_dir"
	local manifest_before=""
	local changelog_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")
	changelog_before=$(cksum "${repo_dir}/CHANGELOG.md")
	if run_helper "$repo_dir" prepare-release invalid 4.5.6 release-notes.md >/dev/null 2>&1; then
		fail "malformed package version rejected"
	else
		pass "malformed package version rejected"
	fi
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "invalid preparation preserves manifest"
	assert_equal "$changelog_before" "$(cksum "${repo_dir}/CHANGELOG.md")" "invalid preparation preserves changelog"
	: >"${repo_dir}/empty-notes.md"
	if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 empty-notes.md >/dev/null 2>&1; then
		fail "empty release notes rejected"
	else
		pass "empty release notes rejected"
	fi
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "empty notes preserve manifest"
	return 0
}

test_release_gate_rejects_package_defects() {
	local repo_dir="${TEST_ROOT}/defects"
	make_fixture "$repo_dir"
	printf 'FROM cloudron/base:5.1.0\n' >"${repo_dir}/Dockerfile"
	if run_helper "$repo_dir" check-release v1.0.0 >/dev/null 2>&1; then
		fail "unpinned final Cloudron base rejected"
	else
		pass "unpinned final Cloudron base rejected"
	fi
	printf '{invalid\n' >"${repo_dir}/CloudronManifest.json"
	if run_helper "$repo_dir" check-release v1.0.0 >/dev/null 2>&1; then
		fail "invalid manifest rejected"
	else
		pass "invalid manifest rejected"
	fi
	return 0
}

test_base_transition() {
	local repo_dir="${TEST_ROOT}/transition"
	local bin_dir="${TEST_ROOT}/transition-bin"
	local output=""
	local image=""
	make_fixture "$repo_dir"
	write_fake_docker "$bin_dir"
	PATH="${bin_dir}:$PATH" run_helper "$repo_dir" check-compatibility >/dev/null && pass "current base passes audit" || fail "current base passes audit"
	printf 'FROM %s\n' "$LEGACY_BASE" >"${repo_dir}/Dockerfile"
	if output=$(PATH="${bin_dir}:$PATH" run_helper "$repo_dir" check-compatibility 2>&1); then
		fail "legacy base produces audit finding"
	else
		pass "legacy base produces audit finding"
	fi
	assert_equal 1 "$(printf '%s\n' "$output" | grep -c '^- Upgrade base image')" "legacy base produces exactly one upgrade finding"
	[[ "$output" == *minBoxVersion*9.1.0* ]] && pass "upgrade finding includes platform qualification" || fail "upgrade finding includes platform qualification"
	PATH="${bin_dir}:$PATH" run_helper "$repo_dir" prepare-release 1.1.0 4.5.6 release-notes.md >/dev/null && pass "legacy base allows upstream release preparation" || fail "legacy base allows upstream release preparation"
	PATH="${bin_dir}:$PATH" run_helper "$repo_dir" preflight-release v1.1.0 >/dev/null && pass "legacy base passes release check and preflight" || fail "legacy base passes release check and preflight"
	for image in \
		'cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34' \
		'cloudron/php-base:8.5-20260920@sha256:a59a4334fbf50ebfdf8f6cc5527e099e4586349a1aefc546e85f7401ea366d65' \
		'cloudron/php-base:8.4-20260920@sha256:e9352b5fba7ad0a231b8a9e454034400a3a34a7fe1800425f634d32ffcae4a52'; do
		printf 'FROM %s\n' "$image" >"${repo_dir}/Dockerfile"
		PATH="${bin_dir}:$PATH" run_helper "$repo_dir" check-compatibility >/dev/null && pass "reviewed runtime pin passes audit: $image" || fail "reviewed runtime pin passes audit: $image"
	done
	printf 'FROM cloudron/base:6.0.0@sha256:%064d\n' 0 >"${repo_dir}/Dockerfile"
	if PATH="${bin_dir}:$PATH" run_helper "$repo_dir" check-release v1.1.0 >/dev/null 2>&1; then
		fail "unknown digest still blocks release"
	else
		pass "unknown digest still blocks release"
	fi
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_prepare_and_validate_release
	test_cloudron_changelog
	test_changelog_paths
	test_invalid_prepare_is_non_mutating
	test_release_gate_rejects_package_defects
	test_release_preflight_validates_immutable_sources
	test_base_transition
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
