#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="$SCRIPT_DIR/../pulse-batch-prefetch-helper.sh"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="$TEST_ROOT/home"
	export REPOS_JSON="$TEST_ROOT/repos.json"
	export PULSE_BATCH_PREFETCH_CACHE_DIR="$TEST_ROOT/cache"
	export LOGFILE="$TEST_ROOT/pulse.log"
	export PULSE_EVENTS_TICKLE_ENABLED=0
	export PULSE_PREFETCH_FULL_SWEEP_INTERVAL=999999999
	unset AIDEVOPS_GH_FORCE_REST_READS
	unset AIDEVOPS_GH_REST_FIRST_READS
	mkdir -p "$HOME" "$PULSE_BATCH_PREFETCH_CACHE_DIR" "$TEST_ROOT/bin"
	cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos":[{"slug":"owner/repo","pulse":true,"local_only":false}],"git_parent_dirs":[]}
JSON
	return 0
}

teardown_env() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

write_gh_stub() {
	local mode="$1"
	cat >"$TEST_ROOT/bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_ROOT/gh-calls.log"
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":5000}}}'
	exit 0
fi
if [[ "\$1" == "api" ]]; then
  if [[ "\$*" == *'/users/owner --jq .type'* ]]; then
    printf 'User'
    exit 0
  fi
  if [[ "\$*" == *'/users/owner/events?per_page=1'* ]]; then
    printf 'HTTP/2 200\\r\\netag: "events"\\r\\n\\r\\n[]'
    exit 0
  fi
  if [[ "$mode" == "not_modified" ]]; then
    printf 'HTTP/2 304\\r\\netag: "etag-v1"\\r\\n\\r\\n'
    exit 1
  fi
  if [[ "$mode" == "changed" ]]; then
    if [[ "\$*" == *'/pulls?state=open'* ]]; then
      printf 'HTTP/2 200\\r\\netag: "etag-pr-v2"\\r\\n\\r\\n[{"number":7,"title":"PR","updated_at":"2026-05-02T00:00:00Z","user":{"login":"dev"},"head":{"sha":"abc","ref":"branch"}}]'
      exit 0
    fi
		printf 'HTTP/2 200\\r\\netag: "etag-issue-v2"\\r\\n\\r\\n[{"number":3,"title":"Issue","state":"open","updated_at":"2026-05-02T00:00:00Z","labels":[],"assignees":[]},{"number":4,"title":"PR-shaped issue","pull_request":{},"updated_at":"2026-05-02T00:00:00Z"}]'
    exit 0
  fi
  printf 'HTTP/2 500\\r\\n\\r\\n{}'
  exit 1
fi
if [[ "\$1" == "search" ]]; then
	if [[ "\$*" == *'search issues'* ]]; then
		printf '[{"number":5,"title":"Search issue","state":"open","updatedAt":"2026-05-03T00:00:00Z","labels":[],"assignees":[],"repository":{"nameWithOwner":"owner/repo"}}]'
		exit 0
	fi
	printf '[]'
	exit 0
fi
exit 1
SH
	chmod +x "$TEST_ROOT/bin/gh"
	export PATH="$TEST_ROOT/bin:$PATH"
	return 0
}

seed_cache() {
	cat >"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json" <<'JSON'
{"timestamp":"2026-05-01T00:00:00Z","etag":"\"etag-v1\"","items":[{"number":1,"title":"Cached issue","state":"open","labels":[],"assignees":[],"updatedAt":"2026-05-01T00:00:00Z"}]}
JSON
	cat >"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json" <<'JSON'
{"timestamp":"2026-05-01T00:00:00Z","etag":"\"etag-v1\"","items":[{"number":2,"title":"Cached PR","labels":[],"assignees":[],"updatedAt":"2026-05-01T00:00:00Z"}]}
JSON
	return 0
}

seed_legacy_issue_cache() {
	cat >"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json" <<'JSON'
{"timestamp":"2026-05-01T00:00:00Z","etag":"\"etag-v1\"","items":[{"number":1,"title":"Legacy cached issue","labels":[],"assignees":[],"updatedAt":"2026-05-01T00:00:00Z"}]}
JSON
	cat >"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json" <<'JSON'
{"timestamp":"2026-05-01T00:00:00Z","etag":"\"etag-v1\"","items":[{"number":2,"title":"Cached PR","labels":[],"assignees":[],"updatedAt":"2026-05-01T00:00:00Z"}]}
JSON
	return 0
}

test_unchanged_repo_uses_304_cache() {
	setup_env
	seed_cache
	write_gh_stub not_modified
	local output
	output=$("$HELPER" refresh)
	if grep -q 'conditional_304=2' <<<"$output" && ! grep -q 'search issues' "$TEST_ROOT/gh-calls.log"; then
		print_result "unchanged repo returns conditional 304 and skips search" 0
	else
		print_result "unchanged repo returns conditional 304 and skips search" 1
	fi
	teardown_env
	return 0
}

test_changed_repo_refreshes_cache() {
	setup_env
	write_gh_stub changed
	local output
	output=$("$HELPER" refresh)
	local issue_count pr_author
	issue_count=$(jq '.items | length' "$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json")
	pr_author=$(jq -r '.items[0].author.login' "$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json")
	local issue_state
	issue_state=$(jq -r '.items[0].state' "$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json")
	if grep -q 'conditional_refreshes=2' <<<"$output" && [[ "$issue_count" == "1" && "$pr_author" == "dev" && "$issue_state" == "open" ]]; then
		print_result "changed repo refreshes normalized issue and PR caches" 0
	else
		print_result "changed repo refreshes normalized issue and PR caches" 1
	fi
	teardown_env
	return 0
}

test_legacy_issue_cache_falls_open_to_search() {
	setup_env
	seed_legacy_issue_cache
	write_gh_stub not_modified
	"$HELPER" refresh >/dev/null
	local issue_num
	issue_num=$(jq -r '.items[0].number' "$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json")
	if grep -q 'search issues' "$TEST_ROOT/gh-calls.log" && [[ "$issue_num" == "5" ]]; then
		print_result "legacy issue cache without state falls open to search refresh" 0
	else
		print_result "legacy issue cache without state falls open to search refresh" 1
	fi
	teardown_env
	return 0
}

test_read_cache_filters_closed_issues() {
	setup_env
	mkdir -p "$PULSE_BATCH_PREFETCH_CACHE_DIR"
	cat >"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json" <<'JSON'
{"timestamp":"2026-05-01T00:00:00Z","items":[{"number":10,"title":"Open","state":"open"},{"number":11,"title":"Closed","state":"closed"}]}
JSON
	local output count first
	output=$("$HELPER" read-cache --kind issues --slug owner/repo)
	count=$(printf '%s' "$output" | jq 'length')
	first=$(printf '%s' "$output" | jq -r '.[0].number')
	if [[ "$count" == "1" && "$first" == "10" ]]; then
		print_result "read-cache filters closed issue rows" 0
	else
		print_result "read-cache filters closed issue rows" 1
	fi
	teardown_env
	return 0
}

test_conditional_failure_falls_open_to_search() {
	setup_env
	seed_cache
	write_gh_stub fail
	"$HELPER" refresh >/dev/null
	if grep -q 'search issues' "$TEST_ROOT/gh-calls.log" && grep -q 'search prs' "$TEST_ROOT/gh-calls.log"; then
		print_result "conditional failure falls open to owner search" 0
	else
		print_result "conditional failure falls open to owner search" 1
	fi
	teardown_env
	return 0
}

test_unchanged_repo_uses_304_cache
test_changed_repo_refreshes_cache
test_conditional_failure_falls_open_to_search
test_legacy_issue_cache_falls_open_to_search
test_read_cache_filters_closed_issues

printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
