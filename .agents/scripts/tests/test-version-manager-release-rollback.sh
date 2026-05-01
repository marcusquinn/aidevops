#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-release-rollback.sh — GH#22034 regression guard.
#
# Asserts that a release failure after version files are bumped but before a
# release commit/tag is created restores the clean pre-release tree. Without
# this guard, retrying with --force can advance VERSION twice and release the
# next+1 patch.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

REMOTE_DIR="${TEST_ROOT}/origin.git"
REPO_DIR="${TEST_ROOT}/repo"
mkdir -p "$REPO_DIR"
git init -q --bare "$REMOTE_DIR"

cd "$REPO_DIR" || exit 1
git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false

cat >VERSION <<'EOF'
1.2.3
EOF
cat >CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-01-01

- Prior release.
EOF
cat >package.json <<'EOF'
{
  "name": "aidevops-test",
  "version": "1.2.3"
}
EOF
cat >sonar-project.properties <<'EOF'
sonar.projectVersion=1.2.3
EOF

git add VERSION CHANGELOG.md package.json sonar-project.properties
git commit -q -m 'chore(release): bump version to 1.2.3'
git tag -a v1.2.3 -m 'Release v1.2.3'
git remote add origin "$REMOTE_DIR"
git push -q -u origin main --tags

# Add releasable work so the changelog/commit gate lets release proceed to the
# mutation phase. Then force a pre-commit validation failure by removing VERSION
# after bump_version captures the next version, before _release_execute validates.
cat >feature.txt <<'EOF'
feature
EOF
git add feature.txt
git commit -q -m 'fix: releasable fixture change'
git push -q origin main

# Source the release orchestrator and override update_version_in_files to mimic
# a late pre-commit gate failure after VERSION/package files have changed.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager.sh"
set +e

update_version_in_files() {
	local new_version="$1"
	_update_version_file "$new_version" >/dev/null 2>&1 || return 1
	_update_package_json_version "$new_version" >/dev/null 2>&1 || return 1
	rm -f "$VERSION_FILE"
	return 0
}

rc=0
(_main_release patch --skip-preflight >/tmp/version-manager-rollback-test.out 2>&1) || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'release fixture: simulated pre-commit gate fails' 0
else
	print_result 'release fixture: simulated pre-commit gate fails' 1 'expected non-zero release exit'
fi

version_after="missing"
[[ -f VERSION ]] && version_after=$(cat VERSION)
package_after=$(jq -r '.version' package.json 2>/dev/null || printf 'jq-failed')
dirty_after=$(git status --porcelain)
head_after=$(git log -1 --pretty=%s)

if [[ "$version_after" == "1.2.3" ]]; then
	print_result 'rollback restores VERSION to original patch target base' 0
else
	print_result 'rollback restores VERSION to original patch target base' 1 "got VERSION=$version_after"
fi

if [[ "$package_after" == "1.2.3" ]]; then
	print_result 'rollback restores version-managed JSON files' 0
else
	print_result 'rollback restores version-managed JSON files' 1 "got package.json version=$package_after"
fi

if [[ -z "$dirty_after" ]]; then
	print_result 'rollback leaves working tree clean' 0
else
	print_result 'rollback leaves working tree clean' 1 "dirty state: $dirty_after"
fi

if [[ "$head_after" == 'fix: releasable fixture change' ]]; then
	print_result 'rollback failure does not create a release commit' 0
else
	print_result 'rollback failure does not create a release commit' 1 "HEAD subject=$head_after"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
