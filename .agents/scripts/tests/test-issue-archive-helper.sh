#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Offline coverage for issue-archive-helper.sh (t18571, GH#33146): orphan
# branch creation, no-op runs, incremental cursor, partial failure, per-repo
# opt-out, and canonical-checkout isolation. `gh` is stubbed from fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../issue-archive-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FIX="${TEST_ROOT}/fixtures"
STUB_BIN="${TEST_ROOT}/bin"
REMOTE="${TEST_ROOT}/remote.git"
BRANCH="aidevops/issues-archive"
mkdir -p "$FIX" "$STUB_BIN"
export FIX
export PATH="${STUB_BIN}:${PATH}"
export AIDEVOPS_ISSUE_ARCHIVE_DIR="${TEST_ROOT}/cache"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export AIDEVOPS_ISSUE_ARCHIVE_PER_PAGE=2
export GIT_CONFIG_NOSYSTEM=1
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME"

PASS=0
FAIL=0
pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}
fail() {
	local name="$1"
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$name"
	return 0
}
check() {
	local name="$1"
	shift
	if "$@"; then pass "$name"; else fail "$name"; fi
	return 0
}

# gh stub: serves `gh api rate_limit` and `gh api -X GET <path>` from fixture
# arrays, honouring since/sort-asc/page/per_page like the REST API.
cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 1
shift
if [[ "${1:-}" == "rate_limit" ]]; then
	printf '5000\n'
	exit 0
fi
[[ "${1:-}" == "-X" ]] && shift 2
path="$1"
printf '%s\n' "$path" >>"${FIX}/calls.log"
base="${path%%\?*}"
query="${path#*\?}"
param() {
	local key="$1"
	printf '%s' "$query" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -1
	return 0
}
case "$base" in
*/pulls/comments) name="review_comments" ;;
*/issues/comments) name="comments" ;;
*/issues) name="issues" ;;
*/pulls/*/reviews) name="reviews-$(printf '%s' "$base" | awk -F/ '{print $(NF-1)}')" ;;
*) exit 1 ;;
esac
[[ -f "${FIX}/fail-${name}" ]] && { echo "stub failure" >&2; exit 1; }
file="${FIX}/${name}.json"
[[ -f "$file" ]] || { printf '[]'; exit 0; }
since=$(param since)
page=$(param page)
per=$(param per_page)
jq -c --arg since "${since:-}" --argjson page "${page:-1}" --argjson per "${per:-30}" '
	[.[] | select($since == "" or (.updated_at // "") >= $since)]
	| sort_by(.updated_at // "")
	| .[(($page - 1) * $per):($page * $per)]' "$file"
STUB
chmod +x "${STUB_BIN}/gh"

issue() {
	local number="$1" title="$2" updated="$3" pr="${4:-}"
	jq -cn --argjson n "$number" --arg t "$title" --arg u "$updated" --arg pr "$pr" '
		{number: $n, title: $t, state: "open", state_reason: null, user: {login: "alice"},
		 author_association: "OWNER", labels: [{name: "bug"}], assignees: [], milestone: null,
		 locked: false, created_at: "2026-01-01T00:00:00Z", updated_at: $u, closed_at: null,
		 html_url: "https://example.invalid/\($n)", body: "body \($n)", reactions: {total_count: 3}}
		+ (if $pr == "pr" then {pull_request: {merged_at: null}, draft: false} else {} end)'
	return 0
}
comment() {
	local id="$1" number="$2" updated="$3"
	jq -cn --argjson id "$id" --argjson n "$number" --arg u "$updated" '
		{id: $id, issue_url: "https://api.example.invalid/repos/o/r/issues/\($n)", user: {login: "bob"},
		 author_association: "NONE", created_at: $u, updated_at: $u, html_url: "x", body: "comment \($id)"}'
	return 0
}

set_fixtures() {
	local issues_json="$1" comments_json="$2"
	printf '%s\n' "$issues_json" | jq -s '.' >"${FIX}/issues.json"
	printf '%s\n' "$comments_json" | jq -s '.' >"${FIX}/comments.json"
	return 0
}

git init -q --bare "$REMOTE"
printf '[{"id": 71, "pull_request_url": "https://api.example.invalid/repos/o/r/pulls/2", "pull_request_review_id": 9,
  "in_reply_to_id": null, "user": {"login": "carol"}, "author_association": "MEMBER", "path": "a.sh", "line": 3,
  "original_line": 3, "side": "RIGHT", "commit_id": "abc", "created_at": "2026-02-01T00:00:00Z",
  "updated_at": "2026-02-01T00:00:00Z", "html_url": "x", "diff_hunk": "@@", "body": "inline"}]\n' >"${FIX}/review_comments.json"
printf '[{"id": 9, "user": {"login": "carol"}, "author_association": "MEMBER", "state": "APPROVED",
  "commit_id": "abc", "submitted_at": "2026-02-01T00:00:00Z", "html_url": "x", "body": "lgtm"}]\n' >"${FIX}/reviews-2.json"

set_fixtures "$(issue 1 'first' 2026-01-02T00:00:00Z)
$(issue 2 'a pr' 2026-01-03T00:00:00Z pr)
$(issue 1001 'later bucket' 2026-01-04T00:00:00Z)" "$(comment 11 1 2026-01-05T00:00:00Z)
$(comment 12 2 2026-01-06T00:00:00Z)"

remote_head() {
	git --git-dir="$REMOTE" rev-parse -q --verify "refs/heads/${BRANCH}" 2>/dev/null || true
	return 0
}
show() {
	local file="$1"
	git --git-dir="$REMOTE" show "${BRANCH}:${file}"
	return 0
}
export_once() {
	local rc=0
	bash "$HELPER" export --repo o/r --remote "$REMOTE" 2>>"${TEST_ROOT}/helper.log" || rc=$?
	[[ "$rc" -eq 0 ]] && return 0
	return 1
}

# 1. First run creates the orphan branch with JSONL shards.
check "first run succeeds" export_once
HEAD1=$(remote_head)
check "archive branch created" test -n "$HEAD1"
check "archive branch is an orphan" test "$(git --git-dir="$REMOTE" rev-list --count "$HEAD1")" = 1
TREE=$(git --git-dir="$REMOTE" ls-tree -r --name-only "$BRANCH")
for f in README.md meta/cursor.json issues/0000.jsonl issues/0001.jsonl pulls/0000.jsonl comments/0000.jsonl reviews/0000.jsonl review-comments/0000.jsonl; do
	check "tree has ${f}" grep -qx "$f" <<<"$TREE"
done
check "issue shard has 1 record" test "$(show issues/0000.jsonl | wc -l | tr -d ' ')" = 1
check "labels flattened, reactions dropped" test "$(show issues/0000.jsonl | jq -c '[.labels, has("reactions")]')" = '[["bug"],false]'
check "review archived for PR" test "$(show reviews/0000.jsonl | jq -r '.pr_number')" = 2
check "issues cursor at newest item" test "$(show meta/cursor.json | jq -r '.issues')" = 2026-01-04T00:00:00Z
check "keyset pagination used since" grep -q 'issues?.*since=2026-01-03T00:00:00Z' "${FIX}/calls.log"

# 2. No remote changes: no new commit.
: >"${FIX}/calls.log"
check "no-op run succeeds" export_once
check "no-op run creates no commit" test "$(remote_head)" = "$HEAD1"
check "no-op run is incremental" grep -q 'issues?.*since=2026-01-04T00:00:00Z' "${FIX}/calls.log"

# 3. Incremental update replaces records by key and appends new ones.
set_fixtures "$(issue 1 'first renamed' 2026-01-07T00:00:00Z)
$(issue 2 'a pr' 2026-01-03T00:00:00Z pr)
$(issue 1001 'later bucket' 2026-01-04T00:00:00Z)" "$(comment 11 1 2026-01-05T00:00:00Z)
$(comment 12 2 2026-01-06T00:00:00Z)
$(comment 13 1 2026-01-08T00:00:00Z)"
check "incremental run succeeds" export_once
HEAD2=$(remote_head)
check "incremental run commits on top" test "$(git --git-dir="$REMOTE" rev-parse "${HEAD2}^")" = "$HEAD1"
check "updated issue replaced, not duplicated" test "$(show issues/0000.jsonl | jq -sc '[length, .[0].title]')" = '[1,"first renamed"]'
check "new comment appended in issue order" test "$(show comments/0000.jsonl | jq -sc 'map(.id)')" = '[11,13,12]'
check "cursor advanced" test "$(show meta/cursor.json | jq -c '[.issues, .comments]')" = '["2026-01-07T00:00:00Z","2026-01-08T00:00:00Z"]'

# 4. Partial failure keeps the cursor at the last fully written item.
set_fixtures "$(issue 1 'first renamed' 2026-01-07T00:00:00Z)
$(issue 2 'a pr' 2026-01-03T00:00:00Z pr)
$(issue 1001 'later bucket' 2026-01-04T00:00:00Z)
$(issue 3 'new pr' 2026-01-09T00:00:00Z pr)
$(issue 4 'after pr' 2026-01-10T00:00:00Z)" "$(comment 11 1 2026-01-05T00:00:00Z)
$(comment 12 2 2026-01-06T00:00:00Z)
$(comment 13 1 2026-01-08T00:00:00Z)"
touch "${FIX}/fail-reviews-3"
rc=0
export_once || rc=$?
check "partial failure exits non-zero" test "$rc" -eq 1
check "partial failure keeps issues cursor" test "$(show meta/cursor.json | jq -r '.issues')" = 2026-01-07T00:00:00Z
check "items after failure not written" test -z "$(show issues/0000.jsonl | jq -r 'select(.number == 4)')"
check "failed PR not written" test -z "$(git --git-dir="$REMOTE" ls-tree -r --name-only "$BRANCH" -- pulls | xargs -I{} git --git-dir="$REMOTE" show "${BRANCH}:{}" | jq -r 'select(.number == 3)')"
rm -f "${FIX}/fail-reviews-3"
check "retry after failure succeeds" export_once
check "retry archives PR and later issue" test "$(show issues/0000.jsonl | jq -sc 'map(.number)')" = '[1,4]'
check "retry cursor at newest item" test "$(show meta/cursor.json | jq -r '.issues')" = 2026-01-10T00:00:00Z

# 5. `run`: registered repos only, per-repo opt-out, canonical untouched.
CANON="${TEST_ROOT}/canonical"
git init -q -b main "$CANON"
git -C "$CANON" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$CANON" remote add origin "$REMOTE"
OPTOUT="${TEST_ROOT}/optout"
git init -q -b main "$OPTOUT"
git -C "$OPTOUT" remote add origin "${TEST_ROOT}/optout-remote.git"
CANON_HEAD=$(git -C "$CANON" rev-parse HEAD)
jq -n --arg c "$CANON" --arg o "$OPTOUT" '{initialized_repos: [
	{slug: "o/r", path: $c, pulse: true},
	{slug: "o/optout", path: $o, pulse: true, issue_archive: false},
	{slug: "o/nopulse", path: $o, pulse: false}]}' >"${TEST_ROOT}/repos.json"
: >"${FIX}/calls.log"
check "run succeeds" bash "$HELPER" run --repos-json "${TEST_ROOT}/repos.json" 2>>"${TEST_ROOT}/helper.log"
check "run skips opted-out and non-pulse repos" test -z "$(grep -E 'o/(optout|nopulse)' "${FIX}/calls.log" "${TEST_ROOT}/helper.log" || true)"
check "run archived registered repo" grep -q 'repos/o/r/issues' "${FIX}/calls.log"
check "canonical HEAD unchanged" test "$(git -C "$CANON" rev-parse HEAD)" = "$CANON_HEAD"
check "canonical branch unchanged" test "$(git -C "$CANON" symbolic-ref --short HEAD)" = main
check "canonical has no archive ref" test -z "$(git -C "$CANON" for-each-ref "refs/heads/${BRANCH}")"
check "canonical worktree clean" test -z "$(git -C "$CANON" status --porcelain)"
check "global disable is a no-op" env AIDEVOPS_ISSUE_ARCHIVE_ENABLED=0 bash "$HELPER" run --repos-json "${TEST_ROOT}/repos.json"

# 6. Pulse registration dispatches the framework routine; host opt-out skips it.
ROUTINE_CAPTURE="${TEST_ROOT}/routine-capture"
evaluate_archive_routine() {
	(
		unset _PULSE_ROUTINES_LOADED
		# shellcheck source=../pulse-routines.sh
		source "${SCRIPT_DIR}/../pulse-routines.sh"
		LOGFILE="${TEST_ROOT}/routine.log"
		PULSE_DIR="$TEST_ROOT"
		_routine_retry_blocked() { return 1; }
		_routine_last_run_epoch() { printf '0'; }
		_routine_schedule_is_due() { return 0; }
		_routine_rest_core_allows_next() { return 0; }
		_routine_execute() { printf '%s\n' "$*" >"$ROUTINE_CAPTURE"; }
		_evaluate_issue_archive_routine
	)
	return 0
}
evaluate_archive_routine
check "pulse dispatches r-issue-archive" grep -q '^r-issue-archive .* scripts/issue-archive-helper.sh run ' "$ROUTINE_CAPTURE"
rm -f "$ROUTINE_CAPTURE"
AIDEVOPS_ISSUE_ARCHIVE_ENABLED=0 evaluate_archive_routine
check "host opt-out skips pulse dispatch" test ! -e "$ROUTINE_CAPTURE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	printf -- '--- helper log ---\n'
	cat "${TEST_ROOT}/helper.log"
fi
[[ "$FAIL" -eq 0 ]]
