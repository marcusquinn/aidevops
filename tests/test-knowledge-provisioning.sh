#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Tests for knowledge plane provisioning (knowledge-helper.sh)
#
# Covers:
#   1. Fresh init — repo mode
#   2. Idempotent update (re-provision does not overwrite)
#   3. Personal mode
#   4. off mode no-op
#   5. Gitignore correctness
#   6. _config/knowledge.json created
#
# Usage:
#   bash tests/test-knowledge-provisioning.sh
#   ./tests/test-knowledge-provisioning.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/.agents/scripts/knowledge-helper.sh"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

pass() {
	local name="$1"
	echo "[PASS] $name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local reason="${2:-}"
	echo "[FAIL] $name${reason:+ — $reason}"
	FAIL=$((FAIL + 1))
	return 0
}

assert_dir() {
	local path="$1"
	local label="$2"
	if [[ -d "$path" ]]; then
		pass "$label"
	else
		fail "$label" "directory not found: $path"
	fi
	return 0
}

assert_file() {
	local path="$1"
	local label="$2"
	if [[ -f "$path" ]]; then
		pass "$label"
	else
		fail "$label" "file not found: $path"
	fi
	return 0
}

assert_file_contains() {
	local path="$1"
	local pattern="$2"
	local label="$3"
	if grep -q "$pattern" "$path" 2>/dev/null; then
		pass "$label"
	else
		fail "$label" "pattern '$pattern' not found in $path"
	fi
	return 0
}

assert_not_dir() {
	local path="$1"
	local label="$2"
	if [[ ! -d "$path" ]]; then
		pass "$label"
	else
		fail "$label" "directory should not exist: $path"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

setup_fake_repos_json() {
	local tmp_dir="$1"
	local mode="$2"
	# Resolve symlinks so the path matches what knowledge-helper.sh sees after cd+pwd.
	# On macOS, mktemp -d returns /var/folders/... which cd+pwd resolves to /private/var/...
	local resolved_dir
	resolved_dir="$(cd "$tmp_dir" && pwd)"
	local repos_file="${resolved_dir}/repos.json"
	mkdir -p "$resolved_dir"
	cat >"$repos_file" <<EOF
{
  "initialized_repos": [
    {
      "path": "${resolved_dir}/repo",
      "slug": "test/repo",
      "knowledge": "$mode"
    }
  ],
  "git_parent_dirs": []
}
EOF
	echo "$repos_file"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Fresh init — repo mode
# ---------------------------------------------------------------------------

test_fresh_init_repo_mode() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS /var -> /private/var symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")

	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"

	assert_dir "${tmp_dir}/repo/_knowledge" "1.1 _knowledge root created"
	assert_dir "${tmp_dir}/repo/_knowledge/inbox" "1.2 inbox/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/staging" "1.3 staging/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/sources" "1.4 sources/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/index" "1.5 index/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/collections" "1.6 collections/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/_config" "1.7 _config/ created"
	assert_file "${tmp_dir}/repo/_knowledge/_config/knowledge.json" "1.8 knowledge.json created"
	assert_file "${tmp_dir}/repo/_knowledge/.gitignore" "1.9 .gitignore created"
	assert_file_contains "${tmp_dir}/repo/_knowledge/.gitignore" "inbox/" "1.10 .gitignore contains inbox/"
	assert_file_contains "${tmp_dir}/repo/_knowledge/.gitignore" "staging/" "1.11 .gitignore contains staging/"

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Idempotent — provision twice without error
# ---------------------------------------------------------------------------

test_idempotent_provision() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")

	# Provision once
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	# Write a sentinel to verify existing files are NOT overwritten
	echo "sentinel" >"${tmp_dir}/repo/_knowledge/_config/knowledge.json"

	# Provision again — should not overwrite existing config
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"

	if grep -q "sentinel" "${tmp_dir}/repo/_knowledge/_config/knowledge.json" 2>/dev/null; then
		pass "2.1 idempotent: existing config not overwritten"
	else
		fail "2.1 idempotent: existing config was overwritten"
	fi

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Personal mode — provisions to personal plane
# ---------------------------------------------------------------------------

test_personal_mode() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "personal")

	# With personal mode, the helper provisions to PERSONAL_PLANE_BASE.
	# Verify: repo directory does NOT get _knowledge/ and command exits 0.
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo" && \
		pass "3.1 personal mode: provision exits 0" || \
		fail "3.1 personal mode: provision failed"

	assert_not_dir "${tmp_dir}/repo/_knowledge" "3.2 personal mode: no _knowledge in repo dir"

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: off mode — no-op
# ---------------------------------------------------------------------------

test_off_mode_noop() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "off")

	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo" && \
		pass "4.1 off mode: provision exits 0" || \
		fail "4.1 off mode: provision failed"

	assert_not_dir "${tmp_dir}/repo/_knowledge" "4.2 off mode: no _knowledge created"

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Gitignore entries appended to repo root .gitignore
# ---------------------------------------------------------------------------

test_gitignore_patched() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	echo "node_modules/" >"${tmp_dir}/repo/.gitignore"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"

	assert_file_contains "${tmp_dir}/repo/.gitignore" "_knowledge/inbox/" "5.1 repo .gitignore has _knowledge/inbox/"
	assert_file_contains "${tmp_dir}/repo/.gitignore" "_knowledge/staging/" "5.2 repo .gitignore has _knowledge/staging/"
	assert_file_contains "${tmp_dir}/repo/.gitignore" "knowledge-plane-rules" "5.3 repo .gitignore has marker comment"

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: knowledge.json contains required fields
# ---------------------------------------------------------------------------

test_config_json_content() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"  # resolve macOS symlinks
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"

	local repos_file
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"

	local config_file="${tmp_dir}/repo/_knowledge/_config/knowledge.json"
	assert_file_contains "$config_file" '"version"' "6.1 knowledge.json has version key"
	assert_file_contains "$config_file" '"sensitivity_default"' "6.2 knowledge.json has sensitivity_default"
	assert_file_contains "$config_file" '"trust_default"' "6.3 knowledge.json has trust_default"

	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

echo "Running knowledge plane provisioning tests..."
echo ""

test_fresh_init_repo_mode
test_idempotent_provision
test_personal_mode
test_off_mode_noop
test_gitignore_patched
test_config_json_content

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
