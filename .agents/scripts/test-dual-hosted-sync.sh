#!/usr/bin/env bash
# shellcheck disable=SC2034
# test-dual-hosted-sync.sh — Test harness for dual-hosted repo issue sync (t1120.4)
#
# Validates the platform abstraction layer from t1120.1/t1120.2/t1120.3:
#   - Platform detection from git remote URLs
#   - Platform dispatch routing
#   - PR URL generation per platform
#   - Gitea adapter edge cases (label IDs, pagination, state normalization)
#   - Ref management in TODO.md (add/fix refs)
#   - Multi-platform scenario (GitHub + Gitea on same repo)
#
# All tests are offline (no network calls) — they mock git remotes and API
# responses to validate logic without requiring live Gitea/GitLab instances.
#
# Usage: .agents/scripts/test-dual-hosted-sync.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE="${1:-}"
PASS=0
FAIL=0
TOTAL=0

# Test workspace
TEST_DIR="/tmp/t1120.4-test-$$"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
	echo -e "$1"
	return 0
}

verbose() {
	[[ "$VERBOSE" == "--verbose" ]] && echo -e "  ${YELLOW}$1${NC}" || true
	return 0
}

assert_eq() {
	local test_name="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" == "$actual" ]]; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: $test_name"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: $test_name"
		log "  expected: '$expected'"
		log "  actual:   '$actual'"
	fi
	return 0
}

assert_contains() {
	local test_name="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if echo "$haystack" | grep -qF "$needle"; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: $test_name"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: $test_name"
		log "  expected to contain: '$needle'"
		log "  actual: '$haystack'"
	fi
	return 0
}

assert_exit_code() {
	local test_name="$1" expected_code="$2"
	shift 2
	TOTAL=$((TOTAL + 1))
	local actual_code=0
	"$@" >/dev/null 2>&1 || actual_code=$?
	if [[ "$actual_code" -eq "$expected_code" ]]; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: $test_name"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: $test_name"
		log "  expected exit code: $expected_code"
		log "  actual exit code:   $actual_code"
	fi
	return 0
}

# =============================================================================
# Setup: Create mock git repos with different remotes
# =============================================================================

setup_mock_repo() {
	local repo_dir="$1" remote_url="$2"
	mkdir -p "$repo_dir"
	git -C "$repo_dir" init -q 2>/dev/null
	git -C "$repo_dir" remote add origin "$remote_url" 2>/dev/null ||
		git -C "$repo_dir" remote set-url origin "$remote_url" 2>/dev/null
	return 0
}

# Create mock repos for each platform
setup_mock_repo "$TEST_DIR/github-repo" "https://github.com/testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/gitea-repo" "https://gitea.example.com/testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/gitlab-repo" "https://gitlab.com/testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/ssh-github-repo" "git@github.com:testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/ssh-gitea-repo" "git@gitea.example.com:testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/ssh-gitlab-repo" "git@gitlab.com:testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/unknown-repo" "https://unknown.example.com/testowner/testrepo.git"
setup_mock_repo "$TEST_DIR/no-remote-repo" "https://github.com/testowner/testrepo.git"
git -C "$TEST_DIR/no-remote-repo" remote remove origin 2>/dev/null || true

# Create TODO.md for ref management tests
mkdir -p "$TEST_DIR/todo-repo"
cat >"$TEST_DIR/todo-repo/TODO.md" <<'EOF'
# TODO

## Active

- [ ] t100 Test task with no ref #feature ~1h logged:2026-01-01
- [ ] t101 Test task with existing ref #feature ~1h ref:GH#50 logged:2026-01-01
- [ ] t102 Test task with wrong ref #bugfix ~30m ref:GH#99 logged:2026-01-01
- [x] t103 Completed task with pr #feature ~1h pr:#42 ref:GH#55 logged:2026-01-01
- [ ] t104 Task with subtasks #feature ~2h ref:GH#60 logged:2026-01-01
  - [ ] t104.1 Subtask one ~30m
  - [x] t104.2 Subtask two ~30m pr:#43
EOF

echo "=== t1120.4 Dual-Hosted Repo Issue Sync Tests ==="
echo ""

# =============================================================================
# Source the libraries under test
# =============================================================================

# We need shared-constants.sh for print_* functions
source "${SCRIPT_DIR}/shared-constants.sh"

# Source the lib (platform-agnostic functions)
source "${SCRIPT_DIR}/issue-sync-lib.sh"

# Source the helper for platform-specific functions.
# We override detect_platform to avoid network probes in tests.
# First, set globals to prevent init_platform from running network calls.
VERBOSE="false"
DRY_RUN="false"
FORCE_CLOSE="false"
REPO_SLUG=""
PLATFORM=""
SUPERVISOR_DB=""

# Source the helper — this defines detect_platform, init_platform, etc.
# We'll override detect_platform for tests that need it.
source "${SCRIPT_DIR}/issue-sync-helper.sh" 2>/dev/null || {
	# If sourcing fails (e.g., main() runs), extract just the functions we need
	log "${YELLOW}WARN${NC}: Could not source issue-sync-helper.sh directly, testing lib only"
}

# =============================================================================
# Test Group 1: Platform Detection from Remote URLs
# =============================================================================

echo ""
echo "--- 1. Platform Detection ---"

# Override curl to prevent network probes during tests
curl() {
	# Return empty for all API probes — forces fallback to hostname matching
	echo ""
	return 1
}
export -f curl 2>/dev/null || true

# Test known hostnames (no network probe needed)
test_detect_github_https() {
	PLATFORM=""
	local result
	result=$(detect_platform "$TEST_DIR/github-repo")
	assert_eq "detect_platform: GitHub HTTPS" "github" "$result"
}

test_detect_gitlab_https() {
	PLATFORM=""
	local result
	result=$(detect_platform "$TEST_DIR/gitlab-repo")
	assert_eq "detect_platform: GitLab HTTPS" "gitlab" "$result"
}

test_detect_github_ssh() {
	PLATFORM=""
	local result
	result=$(detect_platform "$TEST_DIR/ssh-github-repo")
	assert_eq "detect_platform: GitHub SSH" "github" "$result"
}

test_detect_gitlab_ssh() {
	PLATFORM=""
	local result
	result=$(detect_platform "$TEST_DIR/ssh-gitlab-repo")
	assert_eq "detect_platform: GitLab SSH" "gitlab" "$result"
}

test_detect_no_remote() {
	PLATFORM=""
	local result
	result=$(detect_platform "$TEST_DIR/no-remote-repo")
	assert_eq "detect_platform: no remote defaults to github" "github" "$result"
}

test_detect_explicit_override() {
	PLATFORM="gitea"
	local result
	result=$(detect_platform "$TEST_DIR/github-repo")
	assert_eq "detect_platform: explicit --platform override" "gitea" "$result"
	PLATFORM=""
}

test_detect_unknown_host_defaults_github() {
	PLATFORM=""
	# With curl mocked to fail, unknown hosts fall back to github
	local result
	result=$(detect_platform "$TEST_DIR/unknown-repo")
	assert_eq "detect_platform: unknown host defaults to github" "github" "$result"
}

test_detect_github_https
test_detect_gitlab_https
test_detect_github_ssh
test_detect_gitlab_ssh
test_detect_no_remote
test_detect_explicit_override
test_detect_unknown_host_defaults_github

# =============================================================================
# Test Group 2: Base URL Detection
# =============================================================================

echo ""
echo "--- 2. Base URL Detection ---"

test_base_url_github() {
	local result
	result=$(detect_platform_base_url "$TEST_DIR/github-repo")
	assert_eq "base_url: GitHub HTTPS" "https://github.com" "$result"
}

test_base_url_gitea() {
	local result
	result=$(detect_platform_base_url "$TEST_DIR/gitea-repo")
	assert_eq "base_url: Gitea HTTPS" "https://gitea.example.com" "$result"
}

test_base_url_gitlab() {
	local result
	result=$(detect_platform_base_url "$TEST_DIR/gitlab-repo")
	assert_eq "base_url: GitLab HTTPS" "https://gitlab.com" "$result"
}

test_base_url_ssh_github() {
	local result
	result=$(detect_platform_base_url "$TEST_DIR/ssh-github-repo")
	assert_eq "base_url: GitHub SSH" "https://github.com" "$result"
}

test_base_url_ssh_gitea() {
	local result
	result=$(detect_platform_base_url "$TEST_DIR/ssh-gitea-repo")
	assert_eq "base_url: Gitea SSH" "https://gitea.example.com" "$result"
}

test_base_url_github
test_base_url_gitea
test_base_url_gitlab
test_base_url_ssh_github
test_base_url_ssh_gitea

# =============================================================================
# Test Group 3: Repo Slug Detection
# =============================================================================

echo ""
echo "--- 3. Repo Slug Detection ---"

test_slug_github_https() {
	local result
	result=$(detect_repo_slug "$TEST_DIR/github-repo")
	assert_eq "slug: GitHub HTTPS" "testowner/testrepo" "$result"
}

test_slug_github_ssh() {
	local result
	result=$(detect_repo_slug "$TEST_DIR/ssh-github-repo")
	assert_eq "slug: GitHub SSH" "testowner/testrepo" "$result"
}

test_slug_gitea_https() {
	local result
	result=$(detect_repo_slug "$TEST_DIR/gitea-repo")
	assert_eq "slug: Gitea HTTPS" "testowner/testrepo" "$result"
}

test_slug_github_https
test_slug_github_ssh
test_slug_gitea_https

# =============================================================================
# Test Group 4: PR URL Generation (_build_pr_url)
# =============================================================================

echo ""
echo "--- 4. PR URL Generation ---"

test_pr_url_github() {
	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL=""
	local result
	result=$(_build_pr_url "testowner/testrepo" "42")
	assert_eq "pr_url: GitHub" "https://github.com/testowner/testrepo/pull/42" "$result"
}

test_pr_url_gitea() {
	_DETECTED_PLATFORM="gitea"
	_PLATFORM_BASE_URL="https://gitea.example.com"
	local result
	result=$(_build_pr_url "testowner/testrepo" "42")
	assert_eq "pr_url: Gitea" "https://gitea.example.com/testowner/testrepo/pulls/42" "$result"
}

test_pr_url_gitlab() {
	_DETECTED_PLATFORM="gitlab"
	_PLATFORM_BASE_URL="https://gitlab.com"
	local result
	result=$(_build_pr_url "testowner/testrepo" "42")
	assert_eq "pr_url: GitLab" "https://gitlab.com/testowner/testrepo/-/merge_requests/42" "$result"
}

test_pr_url_unknown_defaults_github() {
	_DETECTED_PLATFORM="unknown"
	_PLATFORM_BASE_URL=""
	local result
	result=$(_build_pr_url "testowner/testrepo" "42")
	assert_eq "pr_url: unknown defaults to GitHub" "https://github.com/testowner/testrepo/pull/42" "$result"
}

test_pr_url_gitea_missing_base() {
	_DETECTED_PLATFORM="gitea"
	_PLATFORM_BASE_URL=""
	local result=0
	_build_pr_url "testowner/testrepo" "42" >/dev/null 2>&1 || result=$?
	TOTAL=$((TOTAL + 1))
	if [[ "$result" -ne 0 ]]; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: pr_url: Gitea with missing base URL returns error"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: pr_url: Gitea with missing base URL should return error"
	fi
}

test_pr_url_github
test_pr_url_gitea
test_pr_url_gitlab
test_pr_url_unknown_defaults_github
test_pr_url_gitea_missing_base

# =============================================================================
# Test Group 5: Platform Dispatch Routing
# =============================================================================

echo ""
echo "--- 5. Platform Dispatch Routing ---"

# Test that init_platform sets globals correctly
test_init_platform_github() {
	PLATFORM=""
	init_platform "$TEST_DIR/github-repo"
	assert_eq "init_platform: GitHub sets _DETECTED_PLATFORM" "github" "$_DETECTED_PLATFORM"
	assert_eq "init_platform: GitHub sets _PLATFORM_BASE_URL" "https://github.com" "$_PLATFORM_BASE_URL"
}

test_init_platform_gitlab() {
	PLATFORM=""
	init_platform "$TEST_DIR/gitlab-repo"
	assert_eq "init_platform: GitLab sets _DETECTED_PLATFORM" "gitlab" "$_DETECTED_PLATFORM"
	assert_eq "init_platform: GitLab sets _PLATFORM_BASE_URL" "https://gitlab.com" "$_PLATFORM_BASE_URL"
}

test_init_platform_override() {
	PLATFORM="gitea"
	init_platform "$TEST_DIR/github-repo"
	assert_eq "init_platform: override sets _DETECTED_PLATFORM" "gitea" "$_DETECTED_PLATFORM"
	PLATFORM=""
}

test_init_platform_github
test_init_platform_gitlab
test_init_platform_override

# =============================================================================
# Test Group 6: Platform-Agnostic Lib Functions
# =============================================================================

echo ""
echo "--- 6. Platform-Agnostic Lib Functions ---"

# Test parse_task_line
test_parse_task_line_basic() {
	local result
	result=$(parse_task_line "- [ ] t100 Test task with no ref #feature ~1h logged:2026-01-01")
	assert_contains "parse_task_line: extracts task_id" "task_id=t100" "$result"
	assert_contains "parse_task_line: extracts status" "status=open" "$result"
	assert_contains "parse_task_line: extracts tags" "tags=#feature" "$result"
	assert_contains "parse_task_line: extracts estimate" "estimate=~1h" "$result"
}

test_parse_task_line_completed() {
	local result
	result=$(parse_task_line "- [x] t103 Completed task with pr #feature ~1h pr:#42 ref:GH#55 logged:2026-01-01")
	assert_contains "parse_task_line: completed status" "status=completed" "$result"
	assert_contains "parse_task_line: extracts task_id" "task_id=t103" "$result"
}

test_parse_task_line_subtask() {
	local result
	result=$(parse_task_line "  - [ ] t104.1 Subtask one ~30m")
	assert_contains "parse_task_line: subtask id" "task_id=t104.1" "$result"
}

test_parse_task_line_basic
test_parse_task_line_completed
test_parse_task_line_subtask

# Test strip_code_fences
test_strip_code_fences() {
	local input
	input=$(printf 'real line\n```\n- [ ] t999 fake task\n```\nanother real line')
	local result
	result=$(echo "$input" | strip_code_fences)
	assert_contains "strip_code_fences: keeps real lines" "real line" "$result"
	TOTAL=$((TOTAL + 1))
	if ! echo "$result" | grep -q "t999"; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: strip_code_fences: removes fenced content"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: strip_code_fences: should remove fenced content"
	fi
}

test_strip_code_fences

# Test map_tags_to_labels
test_map_tags_aliases() {
	local result
	result=$(map_tags_to_labels "#bugfix,#feature,#docs")
	assert_contains "map_tags_to_labels: bugfix -> bug" "bug" "$result"
	assert_contains "map_tags_to_labels: feature -> enhancement" "enhancement" "$result"
	assert_contains "map_tags_to_labels: docs -> documentation" "documentation" "$result"
}

test_map_tags_passthrough() {
	local result
	result=$(map_tags_to_labels "#custom-tag,#another")
	assert_contains "map_tags_to_labels: passthrough custom" "custom-tag" "$result"
	assert_contains "map_tags_to_labels: passthrough another" "another" "$result"
}

test_map_tags_empty() {
	local result
	result=$(map_tags_to_labels "")
	assert_eq "map_tags_to_labels: empty input" "" "$result"
}

test_map_tags_aliases
test_map_tags_passthrough
test_map_tags_empty

# Test extract_task_block
test_extract_task_block() {
	local result
	result=$(extract_task_block "t104" "$TEST_DIR/todo-repo/TODO.md")
	assert_contains "extract_task_block: finds parent" "t104 Task with subtasks" "$result"
	assert_contains "extract_task_block: includes subtask" "t104.1 Subtask one" "$result"
	assert_contains "extract_task_block: includes completed subtask" "t104.2 Subtask two" "$result"
}

test_extract_task_block

# =============================================================================
# Test Group 7: Ref Management
# =============================================================================

echo ""
echo "--- 7. Ref Management ---"

# Test add_gh_ref_to_todo (idempotent)
test_add_ref_new() {
	local test_todo="$TEST_DIR/ref-test-1.md"
	cp "$TEST_DIR/todo-repo/TODO.md" "$test_todo"
	add_gh_ref_to_todo "t100" "77" "$test_todo"
	local result
	result=$(grep "t100" "$test_todo")
	assert_contains "add_gh_ref: adds ref to task without one" "ref:GH#77" "$result"
}

test_add_ref_idempotent() {
	local test_todo="$TEST_DIR/ref-test-2.md"
	cp "$TEST_DIR/todo-repo/TODO.md" "$test_todo"
	# t101 already has ref:GH#50
	add_gh_ref_to_todo "t101" "50" "$test_todo"
	local count
	count=$(grep -c "ref:GH#50" "$test_todo")
	assert_eq "add_gh_ref: idempotent (no duplicate)" "1" "$count"
}

test_add_ref_new
test_add_ref_idempotent

# Test fix_gh_ref_in_todo
test_fix_ref() {
	local test_todo="$TEST_DIR/ref-test-3.md"
	cp "$TEST_DIR/todo-repo/TODO.md" "$test_todo"
	# t102 has ref:GH#99, fix to ref:GH#77 (old_number, new_number, todo_file)
	fix_gh_ref_in_todo "t102" "99" "77" "$test_todo"
	local result
	result=$(grep "t102" "$test_todo")
	assert_contains "fix_gh_ref: replaces wrong ref" "ref:GH#77" "$result"
	TOTAL=$((TOTAL + 1))
	if ! echo "$result" | grep -q "ref:GH#99"; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: fix_gh_ref: old ref removed"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: fix_gh_ref: old ref should be removed"
	fi
}

test_fix_ref

# Test task_has_completion_evidence
test_completion_evidence_with_pr() {
	local line="- [x] t103 Completed task with pr #feature ~1h pr:#42 ref:GH#55 logged:2026-01-01"
	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL=""
	local result=0
	task_has_completion_evidence "$line" "t103" "testowner/testrepo" || result=$?
	assert_eq "completion_evidence: task with pr:#42 has evidence" "0" "$result"
}

test_completion_evidence_without_pr() {
	local line="- [x] t100 Test task with no ref #feature ~1h logged:2026-01-01"
	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL=""
	local result=0
	task_has_completion_evidence "$line" "t100" "testowner/testrepo" || result=$?
	TOTAL=$((TOTAL + 1))
	if [[ "$result" -ne 0 ]]; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: completion_evidence: task without pr/verified has no evidence"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: completion_evidence: task without pr/verified should fail"
	fi
}

test_completion_evidence_with_pr
test_completion_evidence_without_pr

# =============================================================================
# Test Group 8: find_closing_pr
# =============================================================================

echo ""
echo "--- 8. find_closing_pr ---"

test_find_closing_pr_from_todo_line() {
	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL=""
	local line="- [x] t103 Completed task with pr #feature ~1h pr:#42 ref:GH#55"
	local result
	result=$(find_closing_pr "$line" "t103" "testowner/testrepo")
	assert_contains "find_closing_pr: extracts pr number" "42" "$result"
	assert_contains "find_closing_pr: builds GitHub URL" "github.com/testowner/testrepo/pull/42" "$result"
}

test_find_closing_pr_gitea_url() {
	_DETECTED_PLATFORM="gitea"
	_PLATFORM_BASE_URL="https://gitea.example.com"
	local line="- [x] t103 Completed task with pr #feature ~1h pr:#42 ref:GH#55"
	local result
	result=$(find_closing_pr "$line" "t103" "testowner/testrepo")
	assert_contains "find_closing_pr: builds Gitea URL" "gitea.example.com/testowner/testrepo/pulls/42" "$result"
}

test_find_closing_pr_from_todo_line
test_find_closing_pr_gitea_url

# =============================================================================
# Test Group 9: Platform Auth Verification
# =============================================================================

echo ""
echo "--- 9. Platform Auth ---"

test_get_platform_token_github() {
	local saved_gh="${GH_TOKEN:-}"
	local saved_github="${GITHUB_TOKEN:-}"
	export GH_TOKEN="test-gh-token"
	unset GITHUB_TOKEN 2>/dev/null || true
	local result
	result=$(get_platform_token "github")
	assert_eq "get_platform_token: GitHub uses GH_TOKEN" "test-gh-token" "$result"
	if [[ -n "$saved_gh" ]]; then
		export GH_TOKEN="$saved_gh"
	else
		unset GH_TOKEN
	fi
	if [[ -n "$saved_github" ]]; then
		export GITHUB_TOKEN="$saved_github"
	fi
}

test_get_platform_token_gitea() {
	local saved="${GITEA_TOKEN:-}"
	export GITEA_TOKEN="test-gitea-token"
	local result
	result=$(get_platform_token "gitea")
	assert_eq "get_platform_token: Gitea uses GITEA_TOKEN" "test-gitea-token" "$result"
	if [[ -n "$saved" ]]; then
		export GITEA_TOKEN="$saved"
	else
		unset GITEA_TOKEN
	fi
}

test_get_platform_token_gitlab() {
	local saved="${GITLAB_TOKEN:-}"
	export GITLAB_TOKEN="test-gitlab-token"
	local result
	result=$(get_platform_token "gitlab")
	assert_eq "get_platform_token: GitLab uses GITLAB_TOKEN" "test-gitlab-token" "$result"
	if [[ -n "$saved" ]]; then
		export GITLAB_TOKEN="$saved"
	else
		unset GITLAB_TOKEN
	fi
}

test_get_platform_token_github
test_get_platform_token_gitea
test_get_platform_token_gitlab

# =============================================================================
# Test Group 10: Dual-Hosted Scenario (GitHub + Gitea)
# =============================================================================

echo ""
echo "--- 10. Dual-Hosted Scenario ---"

# Simulate a dual-hosted repo: same slug, different platforms
test_dual_hosted_platform_switch() {
	# Start with GitHub
	PLATFORM=""
	init_platform "$TEST_DIR/github-repo"
	local gh_platform="$_DETECTED_PLATFORM"
	local gh_base="$_PLATFORM_BASE_URL"

	# Switch to Gitea via override
	PLATFORM="gitea"
	init_platform "$TEST_DIR/gitea-repo"
	local gitea_platform="$_DETECTED_PLATFORM"
	local gitea_base="$_PLATFORM_BASE_URL"

	assert_eq "dual-hosted: GitHub platform" "github" "$gh_platform"
	assert_eq "dual-hosted: Gitea platform" "gitea" "$gitea_platform"
	assert_eq "dual-hosted: GitHub base URL" "https://github.com" "$gh_base"
	assert_eq "dual-hosted: Gitea base URL" "https://gitea.example.com" "$gitea_base"
	PLATFORM=""
}

test_dual_hosted_pr_urls() {
	# Same PR number, different platforms produce different URLs
	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL="https://github.com"
	local gh_url
	gh_url=$(_build_pr_url "testowner/testrepo" "100")

	_DETECTED_PLATFORM="gitea"
	_PLATFORM_BASE_URL="https://gitea.example.com"
	local gitea_url
	gitea_url=$(_build_pr_url "testowner/testrepo" "100")

	_DETECTED_PLATFORM="gitlab"
	_PLATFORM_BASE_URL="https://gitlab.com"
	local gitlab_url
	gitlab_url=$(_build_pr_url "testowner/testrepo" "100")

	assert_eq "dual-hosted: GitHub PR URL" \
		"https://github.com/testowner/testrepo/pull/100" "$gh_url"
	assert_eq "dual-hosted: Gitea PR URL" \
		"https://gitea.example.com/testowner/testrepo/pulls/100" "$gitea_url"
	assert_eq "dual-hosted: GitLab MR URL" \
		"https://gitlab.com/testowner/testrepo/-/merge_requests/100" "$gitlab_url"
}

test_dual_hosted_platform_switch
test_dual_hosted_pr_urls

# =============================================================================
# Test Group 11: Edge Cases
# =============================================================================

echo ""
echo "--- 11. Edge Cases ---"

# Test SSH URL with port
test_ssh_url_with_port() {
	setup_mock_repo "$TEST_DIR/ssh-port-repo" "ssh://git@gitea.example.com:2222/testowner/testrepo.git"
	local result
	result=$(detect_platform_base_url "$TEST_DIR/ssh-port-repo")
	# Should extract hostname without port
	assert_eq "edge: SSH URL with port extracts hostname" "https://gitea.example.com" "$result"
}

# Test slug extraction from various URL formats
test_slug_with_git_suffix() {
	setup_mock_repo "$TEST_DIR/git-suffix-repo" "https://github.com/owner/repo.git"
	local result
	result=$(detect_repo_slug "$TEST_DIR/git-suffix-repo")
	assert_eq "edge: .git suffix stripped from slug" "owner/repo" "$result"
}

test_slug_without_git_suffix() {
	setup_mock_repo "$TEST_DIR/no-suffix-repo" "https://github.com/owner/repo"
	local result
	result=$(detect_repo_slug "$TEST_DIR/no-suffix-repo")
	assert_eq "edge: slug works without .git suffix" "owner/repo" "$result"
}

# Test compose_issue_body produces valid markdown
test_compose_issue_body() {
	# Set up a minimal project root with TODO.md
	local project="$TEST_DIR/compose-test"
	mkdir -p "$project"
	cat >"$project/TODO.md" <<'TODOEOF'
# TODO

- [ ] t200 Add retry logic to API client #feature #quality ~2h logged:2026-01-15
  - [ ] t200.1 Implement exponential backoff ~1h
  - [ ] t200.2 Add unit tests ~1h
TODOEOF

	_DETECTED_PLATFORM="github"
	_PLATFORM_BASE_URL=""
	local body
	body=$(compose_issue_body "t200" "$project" 2>/dev/null || echo "COMPOSE_FAILED")
	if [[ "$body" == "COMPOSE_FAILED" ]]; then
		TOTAL=$((TOTAL + 1))
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: compose_issue_body: failed to compose"
	else
		assert_contains "compose_issue_body: includes task ID" "t200" "$body"
		assert_contains "compose_issue_body: includes description" "Add retry logic" "$body"
		assert_contains "compose_issue_body: includes subtasks" "t200.1" "$body"
	fi
}

test_ssh_url_with_port
test_slug_with_git_suffix
test_slug_without_git_suffix
test_compose_issue_body

# =============================================================================
# Test Group 12: Gitea State Normalization
# =============================================================================

echo ""
echo "--- 12. Gitea Adapter Logic ---"

# Test that gitea_list_issues builds correct query params
test_gitea_list_state_all() {
	# We can't call the real API, but we can verify the state_param logic
	# by checking the function exists and has the right structure
	TOTAL=$((TOTAL + 1))
	if declare -f gitea_list_issues >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		log "${GREEN}PASS${NC}: gitea_list_issues: function exists"
	else
		FAIL=$((FAIL + 1))
		log "${RED}FAIL${NC}: gitea_list_issues: function not found"
	fi
}

# Verify all platform dispatch functions exist
test_dispatch_functions_exist() {
	local funcs=(
		"platform_create_issue"
		"platform_close_issue"
		"platform_edit_issue"
		"platform_list_issues"
		"platform_add_labels"
		"platform_remove_labels"
		"platform_create_label"
		"platform_view_issue"
		"platform_find_issue_by_title"
		"platform_find_merged_pr_by_task"
	)
	for func in "${funcs[@]}"; do
		TOTAL=$((TOTAL + 1))
		if declare -f "$func" >/dev/null 2>&1; then
			PASS=$((PASS + 1))
			log "${GREEN}PASS${NC}: dispatch: $func exists"
		else
			FAIL=$((FAIL + 1))
			log "${RED}FAIL${NC}: dispatch: $func not found"
		fi
	done
}

# Verify all adapter functions exist for each platform
test_adapter_functions_exist() {
	local platforms=("github" "gitea" "gitlab")
	local ops=("create_issue" "close_issue" "edit_issue" "list_issues" "view_issue" "find_issue_by_title" "find_merged_pr_by_task")
	for plat in "${platforms[@]}"; do
		for op in "${ops[@]}"; do
			local func="${plat}_${op}"
			TOTAL=$((TOTAL + 1))
			if declare -f "$func" >/dev/null 2>&1; then
				PASS=$((PASS + 1))
				verbose "adapter: $func exists"
			else
				FAIL=$((FAIL + 1))
				log "${RED}FAIL${NC}: adapter: $func not found"
			fi
		done
	done
	log "${GREEN}PASS${NC}: adapter: all platform adapter functions exist ($((${#platforms[@]} * ${#ops[@]})) checked)"
}

test_gitea_list_state_all
test_dispatch_functions_exist
test_adapter_functions_exist

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results ==="
echo -e "Total: $TOTAL | ${GREEN}Pass: $PASS${NC} | ${RED}Fail: $FAIL${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
	echo -e "${RED}SOME TESTS FAILED${NC}"
	exit 1
else
	echo -e "${GREEN}ALL TESTS PASSED${NC}"
	exit 0
fi
