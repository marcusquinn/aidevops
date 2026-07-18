#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="$SCRIPT_DIR/../pulse-batch-prefetch-helper.sh"

# shellcheck source=../shared-constants.sh
source "$SCRIPT_DIR/../shared-constants.sh"

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
	export PULSE_BATCH_SEARCH_LAST_RESORT=1
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

prefetch_raw_gh_read_matches() {
	local file_path="${1:-}"
	if [[ -z "$file_path" || ! -f "$file_path" ]]; then
		return 1
	fi
	if { sed -E 's/^[[:space:]]*#.*//' "$file_path" \
		| awk '{ if (sub(/\\$/, "")) { printf "%s", $0 } else { print } }' \
		| sed -E 's/_prefetch_gh_read[[:space:]]+gh[[:space:]]+(api|search)//g' \
		| grep -nE '^[[:space:]]*([{(][[:space:]]*)?((if|while|until|then|do|else|elif|!)[[:space:]]+)*gh[[:space:]]+(api|search)([[:space:]]|$)|[;|][[:space:]]*gh[[:space:]]+(api|search)([[:space:]]|$)|\$\([[:space:]]*gh[[:space:]]+(api|search)([[:space:]]|$|\))'; } >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

test_prefetch_raw_gh_read_detector_rejects_missing_file() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	setup_env
	push_cleanup "rm -rf '${TEST_ROOT}'"
	local empty_path=""
	local missing_path="${TEST_ROOT:-}/missing.sh"
	local directory_path="${TEST_ROOT:-}"
	if prefetch_raw_gh_read_matches \
		|| prefetch_raw_gh_read_matches "$empty_path" \
		|| prefetch_raw_gh_read_matches "$missing_path" \
		|| prefetch_raw_gh_read_matches "$directory_path"; then
		print_result "prefetch raw gh detector rejects invalid file input" 1
	else
		print_result "prefetch raw gh detector rejects invalid file input" 0
	fi
	teardown_env
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

test_legacy_issue_cache_avoids_search_by_default() {
	setup_env
	seed_legacy_issue_cache
	write_gh_stub not_modified
	"$HELPER" refresh >/dev/null
	local issue_num
	issue_num=$(jq -r '.items[0].number' "$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json")
	if ! grep -q 'search issues' "$TEST_ROOT/gh-calls.log" && [[ "$issue_num" == "1" ]]; then
		print_result "legacy issue cache without state avoids search by default" 0
	else
		print_result "legacy issue cache without state avoids search by default" 1
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

test_read_cache_accepts_fresh_empty_arrays() {
	setup_env
	local now=""
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"timestamp":"%s","items":[]}\n' "$now" \
		>"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json"
	printf '{"timestamp":"%s","items":[]}\n' "$now" \
		>"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
	local issues_output="" prs_output=""
	local issues_meta="$TEST_ROOT/issues-meta.log"
	local prs_meta="$TEST_ROOT/prs-meta.log"
	local passed=0
	if issues_output=$("$HELPER" read-cache --kind issues --slug owner/repo 2>"$issues_meta") \
		&& prs_output=$("$HELPER" read-cache --kind prs --slug owner/repo 2>"$prs_meta") \
		&& [[ "$issues_output" == "[]" && "$prs_output" == "[]" ]] \
		&& grep -q 'cache_state=hit.*cardinality=empty' "$issues_meta" \
		&& grep -q 'cache_state=hit.*cardinality=empty' "$prs_meta"; then
		passed=0
	else
		passed=1
	fi
	print_result "read-cache accepts fresh empty issue and PR arrays" "$passed"
	teardown_env
	return 0
}

test_read_cache_rejects_non_hit_states() {
	setup_env
	local cache_file="$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
	local state_meta="$TEST_ROOT/cache-state.log"
	local now=""
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	if "$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta"; then
		print_result "read-cache rejects missing snapshots" 1
	elif grep -q 'cache_state=missing' "$state_meta"; then
		print_result "read-cache rejects missing snapshots" 0
	else
		print_result "read-cache rejects missing snapshots" 1
	fi

	printf '{malformed\n' >"$cache_file"
	if "$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta"; then
		print_result "read-cache rejects malformed JSON snapshots" 1
	elif grep -q 'cache_state=malformed' "$state_meta"; then
		print_result "read-cache rejects malformed JSON snapshots" 0
	else
		print_result "read-cache rejects malformed JSON snapshots" 1
	fi

	printf '{"timestamp":"%s","items":{}}\n' "$now" >"$cache_file"
	if "$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta"; then
		print_result "read-cache rejects non-array snapshot items" 1
	elif grep -q 'cache_state=malformed' "$state_meta"; then
		print_result "read-cache rejects non-array snapshot items" 0
	else
		print_result "read-cache rejects non-array snapshot items" 1
	fi

	export PULSE_PREFETCH_FULL_SWEEP_INTERVAL=1
	printf '{"timestamp":"2026-01-01T00:00:00Z","items":[]}\n' >"$cache_file"
	if "$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta"; then
		print_result "read-cache rejects stale snapshots" 1
	elif grep -q 'cache_state=stale' "$state_meta"; then
		print_result "read-cache rejects stale snapshots" 0
	else
		print_result "read-cache rejects stale snapshots" 1
	fi

	teardown_env
	return 0
}

test_read_cache_recovers_after_atomic_replacement() {
	setup_env
	local cache_file="$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
	local replacement_file="${cache_file}.new"
	local state_meta="$TEST_ROOT/atomic-state.log"
	local now=""
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"timestamp":"%s","items":[' "$now" >"$cache_file"
	local passed=0
	if "$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta"; then
		passed=1
	elif ! grep -q 'cache_state=malformed' "$state_meta"; then
		passed=1
	fi
	printf '{"timestamp":"%s","items":[]}\n' "$now" >"$replacement_file"
	mv "$replacement_file" "$cache_file"
	local first_read="" second_read=""
	if ! first_read=$("$HELPER" read-cache --kind prs --slug owner/repo 2>"$state_meta") \
		|| ! second_read=$("$HELPER" read-cache --kind prs --slug owner/repo 2>>"$state_meta") \
		|| [[ "$first_read" != "[]" || "$second_read" != "[]" ]] \
		|| [[ "$(grep -c 'cache_state=hit.*cardinality=empty' "$state_meta")" != "2" ]]; then
		passed=1
	fi
	print_result "read-cache rejects partial files and retries after atomic replacement" "$passed"
	teardown_env
	return 0
}

run_prefetch_consumer_case() (
	local mode="$1"
	setup_env
	local scripts_dir=""
	scripts_dir=$(cd "$SCRIPT_DIR/.." && pwd)
	SCRIPT_DIR="$scripts_dir"
	export SCRIPT_DIR LOGFILE PULSE_BATCH_PREFETCH_CACHE_DIR
	export PULSE_BATCH_PREFETCH_ENABLED=1
	export PULSE_PREFETCH_FULL_SWEEP_INTERVAL=999999999
	export PULSE_PREFETCH_PR_LIMIT=100
	export PULSE_PREFETCH_ISSUE_LIMIT=100
	local now=""
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	case "$mode" in
	empty)
		printf '{"timestamp":"%s","items":[]}\n' "$now" \
			>"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json"
		printf '{"timestamp":"%s","items":[]}\n' "$now" \
			>"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
		;;
	nonempty)
		printf '{"timestamp":"%s","items":[{"number":7,"title":"Issue","state":"OPEN","labels":[],"updatedAt":"%s","assignees":[],"body":""}]}\n' \
			"$now" "$now" >"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json"
		printf '{"schema_version":2,"timestamp":"%s","items":[{"number":8,"title":"PR","reviewDecision":"","updatedAt":"%s","headRefName":"test","headRefOid":"abc","createdAt":"%s","author":{"login":"tester"}}]}\n' \
			"$now" "$now" "$now" >"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
		;;
	missing | fetch-failed)
		;;
	stale)
		export PULSE_PREFETCH_FULL_SWEEP_INTERVAL=1
		printf '{"timestamp":"2026-01-01T00:00:00Z","items":[]}\n' \
			>"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json"
		printf '{"timestamp":"2026-01-01T00:00:00Z","items":[]}\n' \
			>"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
		;;
	malformed)
		printf '{malformed\n' >"$PULSE_BATCH_PREFETCH_CACHE_DIR/issues-owner__repo.json"
		printf '{"timestamp":"%s","items":{}}\n' "$now" \
			>"$PULSE_BATCH_PREFETCH_CACHE_DIR/prs-owner__repo.json"
		;;
	*) return 1 ;;
	esac

	local live_calls="$TEST_ROOT/live-calls.log"
	local telemetry_calls="$TEST_ROOT/telemetry-calls.log"
	gh_record_call() {
		printf '%s\n' "$*" >>"$telemetry_calls"
		return 0
	}
	gh_pr_list() {
		printf 'prs\n' >>"$live_calls"
		if [[ "$mode" == "fetch-failed" ]]; then
			printf 'simulated transport failure\n' >&2
			return 1
		fi
		printf '[]'
		return 0
	}
	gh_issue_list() {
		printf 'issues\n' >>"$live_calls"
		if [[ "$mode" == "fetch-failed" ]]; then
			printf 'simulated transport failure\n' >&2
			return 1
		fi
		printf '[]'
		return 0
	}
	_filter_non_task_issues() {
		cat
		return 0
	}
	_pulse_gh_err_is_rate_limit() {
		return 1
	}
	_pulse_mark_rate_limited() {
		return 0
	}

	unset _PULSE_PREFETCH_FETCH_LOADED
	# shellcheck source=../pulse-prefetch-fetch.sh
	source "$scripts_dir/pulse-prefetch-fetch.sh"
	_prefetch_prs_enrich_checks() {
		printf '[]'
		return 0
	}
	_PULSE_HEALTH_BATCH_CACHE_HITS=0
	_prefetch_repo_prs owner/repo '{}' full >"$TEST_ROOT/pr-output.txt"
	_prefetch_repo_issues owner/repo '{}' full >"$TEST_ROOT/issue-output.txt"

	if [[ "$mode" == "empty" || "$mode" == "nonempty" ]]; then
		[[ ! -s "$live_calls" ]] || return 1
		[[ "$_PULSE_HEALTH_BATCH_CACHE_HITS" == "2" ]] || return 1
		local decision="hit-nonempty"
		local cardinality="nonempty"
		if [[ "$mode" == "empty" ]]; then
			decision="hit-empty"
			cardinality="empty"
			[[ "$PREFETCH_UPDATED_PRS" == "[]" && "$PREFETCH_UPDATED_ISSUES" == "[]" ]] || return 1
			grep -q 'Open PRs (0)' "$TEST_ROOT/pr-output.txt" || return 1
			grep -q 'Open Issues (0)' "$TEST_ROOT/issue-output.txt" || return 1
		else
			jq -e 'length == 1' <<<"$PREFETCH_UPDATED_PRS" >/dev/null || return 1
			jq -e 'length == 1' <<<"$PREFETCH_UPDATED_ISSUES" >/dev/null || return 1
		fi
		[[ "$(grep -Ec "^other pulse_batch_prefetch_(prs|issues)_cache unknown other ${decision}  cache$" "$telemetry_calls")" == "2" ]] || return 1
		[[ "$(grep -c "cache_state=hit.*cardinality=${cardinality}" "$LOGFILE")" == "2" ]] || return 1
		return 0
	fi

	[[ "$(grep -c -E '^(prs|issues)$' "$live_calls")" == "2" ]] || return 1
	[[ ! -s "$telemetry_calls" ]] || return 1
	[[ "$_PULSE_HEALTH_BATCH_CACHE_HITS" == "0" ]] || return 1
	local expected_state="$mode"
	[[ "$mode" == "fetch-failed" ]] && expected_state="missing"
	grep -q "cache_state=${expected_state}" "$LOGFILE" || return 1
	if [[ "$mode" == "fetch-failed" ]]; then
		grep -q 'cache_state=fetch-failed kind=prs' "$LOGFILE" || return 1
		grep -q 'cache_state=fetch-failed kind=issues' "$LOGFILE" || return 1
	fi
	return 0
)

test_prefetch_consumers_accept_fresh_empty_hits() {
	if run_prefetch_consumer_case empty; then
		print_result "PR and issue consumers accept fresh empty cache hits without live calls" 0
	else
		print_result "PR and issue consumers accept fresh empty cache hits without live calls" 1
	fi
	return 0
}

test_prefetch_consumers_accept_nonempty_legacy_and_versioned_hits() {
	if run_prefetch_consumer_case nonempty; then
		print_result "PR and issue consumers accept nonempty legacy and versioned cache hits" 0
	else
		print_result "PR and issue consumers accept nonempty legacy and versioned cache hits" 1
	fi
	return 0
}

test_prefetch_consumers_fallback_on_non_hit_states() {
	local mode=""
	for mode in missing stale malformed fetch-failed; do
		if ! run_prefetch_consumer_case "$mode"; then
			print_result "PR and issue consumers preserve fallback and failure classification" 1
			return 0
		fi
	done
	print_result "PR and issue consumers preserve fallback and failure classification" 0
	return 0
}

test_conditional_failure_routes_to_rest_by_default() {
	setup_env
	seed_cache
	write_gh_stub fail
	"$HELPER" refresh >/dev/null
	if ! grep -q 'search issues' "$TEST_ROOT/gh-calls.log" && ! grep -q 'search prs' "$TEST_ROOT/gh-calls.log"; then
		print_result "conditional failure routes to REST instead of owner search" 0
	else
		print_result "conditional failure routes to REST instead of owner search" 1
	fi
	teardown_env
	return 0
}

test_search_opt_in_preserves_owner_search() {
	setup_env
	seed_cache
	write_gh_stub fail
	export PULSE_BATCH_SEARCH_LAST_RESORT=0
	export AIDEVOPS_GH_READ_RAMP_ENABLED=0
	"$HELPER" refresh >/dev/null
	if grep -q 'search issues' "$TEST_ROOT/gh-calls.log" && grep -q 'search prs' "$TEST_ROOT/gh-calls.log"; then
		print_result "search opt-in preserves owner search fallback" 0
	else
		print_result "search opt-in preserves owner search fallback" 1
	fi
	teardown_env
	return 0
}

test_prefetch_gh_reads_are_timeout_wrapped() {
	if prefetch_raw_gh_read_matches "$HELPER"; then
		print_result "prefetch gh reads use timeout wrapper" 1
	else
		print_result "prefetch gh reads use timeout wrapper" 0
	fi
	return 0
}

test_prefetch_raw_gh_read_detector_covers_shell_edges() {
	local fixture=""
	fixture=$(mktemp)
	cat >"$fixture" <<'SH'
# gh api repos/owner/repo/issues
printf '%s\n' "mentioning gh api is documentation, not execution"
if ! gh api repos/owner/repo/issues; then
	return 1
fi
{ gh search prs --repo owner/repo; }
for repo in $( gh api repos/owner/repo/issues --jq '.[].number'); do
	printf '%s\n' "$repo"
done
SH
	if prefetch_raw_gh_read_matches "$fixture"; then
		print_result "prefetch raw gh detector covers shell edges" 0
	else
		print_result "prefetch raw gh detector covers shell edges" 1
	fi
	rm -f "$fixture"
	return 0
}

test_unchanged_repo_uses_304_cache
test_changed_repo_refreshes_cache
test_conditional_failure_routes_to_rest_by_default
test_search_opt_in_preserves_owner_search
test_legacy_issue_cache_avoids_search_by_default
test_read_cache_filters_closed_issues
test_read_cache_accepts_fresh_empty_arrays
test_read_cache_rejects_non_hit_states
test_read_cache_recovers_after_atomic_replacement
test_prefetch_consumers_accept_fresh_empty_hits
test_prefetch_consumers_accept_nonempty_legacy_and_versioned_hits
test_prefetch_consumers_fallback_on_non_hit_states
test_prefetch_raw_gh_read_detector_rejects_missing_file
test_prefetch_gh_reads_are_timeout_wrapped
test_prefetch_raw_gh_read_detector_covers_shell_edges

printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
