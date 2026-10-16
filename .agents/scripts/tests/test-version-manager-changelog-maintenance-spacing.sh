#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#29180: maintenance-only releases must not create
# multiple blank lines before the next version heading.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
REPO_ROOT="$(mktemp -d)"
VERSION_FILE="${REPO_ROOT}/VERSION"
trap 'rm -rf "$REPO_ROOT"' EXIT

print_warning() {
	return 0
}

print_success() {
	return 0
}

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager-changelog.sh"

# Angle-bracket placeholders in commit subjects must be escaped (MD033).
GIT_REPO="$(mktemp -d)"
(
	cd "$GIT_REPO" || exit 1
	git init -q . && git config user.email t@example.com && git config user.name t
	git config commit.gpgsign false
	git commit -q --allow-empty -m "chore: init" && git update-ref refs/tags/v0.0.1 HEAD
	# shellcheck disable=SC2016
	git commit -q --allow-empty -m 'feat: support TOKEN_<NAME> and `<kept>` override'
	generate_changelog_content
) >"${GIT_REPO}/out.md"
if ! rg -qF 'TOKEN_\<NAME> and `<kept>` override' "${GIT_REPO}/out.md"; then
	printf 'FAIL angle-bracket token not escaped\n' >&2
	cat "${GIT_REPO}/out.md" >&2
	exit 1
fi
rm -rf "$GIT_REPO"

generate_changelog_content() {
	return 0
}

cat >"${REPO_ROOT}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

Previous unreleased content

## [1.0.0] - 2026-07-31

### Added

- Existing release
EOF

update_changelog "1.0.1"
if ! npx --yes markdownlint-cli2@0.22.0 "${REPO_ROOT}/CHANGELOG.md"; then
	printf 'FAIL generated maintenance changelog is not Markdown-clean\n' >&2
	exit 1
fi

expected="# Changelog

## [Unreleased]

## [1.0.1] - $(date +%Y-%m-%d)

### Changed

- Version bump and maintenance updates

## [1.0.0] - 2026-07-31

### Added

- Existing release"
actual=$(cat "${REPO_ROOT}/CHANGELOG.md")

if [[ "$actual" != "$expected" ]]; then
	printf 'FAIL maintenance changelog spacing\nExpected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
	exit 1
fi

printf 'PASS maintenance changelog spacing\n'
