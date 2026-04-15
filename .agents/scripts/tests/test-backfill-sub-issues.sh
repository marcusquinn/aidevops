#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-backfill-sub-issues.sh — coverage for cmd_backfill_sub_issues (t2114).
#
# Strategy:
#   1. Create a temp directory and install a `gh` stub on PATH that:
#      - Responds to `gh issue list --json number,title,body` with canned JSON
#        from a fixture variable.
#      - Responds to `gh issue view N --json labels` to support the Method 4
#        parent-task label check.
#      - Responds to `gh issue list --search "tNNN: in:title"` for parent
#        resolution (gh_find_issue_by_title calls this shape).
#      - Responds to `gh api graphql` requests for resolve_gh_node_id and
#        addSubIssue with canned responses and records the calls to a trace
#        file so the test can assert which pairs were linked.
#   2. Source issue-sync-helper.sh (it's guarded so main() does not execute
#      when sourced).
#   3. Invoke cmd_backfill_sub_issues against canned fixtures exercising all
#      4 detection methods and assert the trace file contains the expected
#      (parent, child) node pairs.

set -u

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly TEST_REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly HELPER="${TEST_REPO_ROOT}/.agents/scripts/issue-sync-helper.sh"

TEST_TMPDIR=$(mktemp -d /tmp/test-backfill-sub-issues.XXXXXX)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TRACE_FILE="${TEST_TMPDIR}/gh-trace.log"
: >"$TRACE_FILE"

# -----------------------------------------------------------------------------
# gh stub — canned responses driven by FIXTURE_ISSUES_JSON and FIXTURE_LABELS
# -----------------------------------------------------------------------------
mkdir -p "${TEST_TMPDIR}/bin"
cat >"${TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub for test-backfill-sub-issues.sh
# shellcheck disable=SC2034
set -u
TRACE_FILE="${TRACE_FILE:-/dev/null}"
printf 'gh %s\n' "$*" >>"$TRACE_FILE"

# Parse --jq EXPR upfront so every branch can pipe raw JSON through it before
# returning. Real `gh` applies --jq server-side; the stub mimics that with
# jq on the raw response.
_JQ_EXPR=""
_prev=""
for _arg in "$@"; do
	if [[ "$_prev" == "--jq" ]]; then
		_JQ_EXPR="$_arg"
	fi
	_prev="$_arg"
done

# _emit: print JSON, piping through jq if --jq was given. Matches real gh.
_emit() {
	local raw="$1"
	if [[ -n "$_JQ_EXPR" ]]; then
		printf '%s' "$raw" | jq -r "$_JQ_EXPR" 2>/dev/null || printf ''
	else
		printf '%s' "$raw"
	fi
}

cmd="${1:-}"
sub="${2:-}"

# gh repo view
if [[ "$cmd" == "repo" && "$sub" == "view" ]]; then
	printf 'test/repo\n'
	exit 0
fi

# gh issue list ... --json ... [--jq EXPR]
# Always returns the full fixture JSON; --jq (if present) is applied by _emit.
# gh_find_issue_by_title passes a --jq filter that reduces to a single number;
# cmd_backfill_sub_issues main iteration does not, so it gets the full list.
if [[ "$cmd" == "issue" && "$sub" == "list" ]]; then
	# Choose fixture: parent lookup (has --search style or --jq startswith) vs
	# the main list. Both reuse FIXTURE_ISSUES_JSON, but gh_find_issue_by_title
	# needs the parent titles too, so merge them.
	if [[ -n "${FIXTURE_PARENT_TITLES:-}" ]]; then
		# Build augmented array: fixture issues + parent title stubs
		parent_json=$(printf '%s\n' "$FIXTURE_PARENT_TITLES" |
			awk -F'|' 'NF==2 {printf "%s{\"number\": %s, \"title\": \"%sparent\"}", (NR>1?",":""), $2, $1}')
		augmented_json=$(printf '%s' "${FIXTURE_ISSUES_JSON:-[]}" |
			jq --argjson extras "[$parent_json]" '. + $extras' 2>/dev/null || printf '%s' "${FIXTURE_ISSUES_JSON:-[]}")
		_emit "$augmented_json"
	else
		_emit "${FIXTURE_ISSUES_JSON:-[]}"
	fi
	exit 0
fi

# gh issue view N --json ...
if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
	issue_num="${3:-}"
	# Find --json argument to decide what to return
	want_json=0
	json_fields=""
	for arg in "$@"; do
		if [[ "$want_json" == 1 ]]; then
			json_fields="$arg"
			want_json=0
		elif [[ "$arg" == "--json" ]]; then
			want_json=1
		fi
	done

	if [[ "$json_fields" == *"labels"* && "$json_fields" != *"number"* ]]; then
		case ",${FIXTURE_PARENT_TASK_NUMS:-}," in
		*",${issue_num},"*)
			_emit '{"labels":[{"name":"parent-task"}]}'
			;;
		*)
			_emit '{"labels":[]}'
			;;
		esac
		exit 0
	fi

	if [[ "$json_fields" == *"number"* && "$json_fields" == *"title"* && "$json_fields" == *"body"* ]]; then
		_emit "${FIXTURE_SINGLE_ISSUE:-null}"
		exit 0
	fi

	_emit '{}'
	exit 0
fi

# gh api graphql — resolve node IDs and addSubIssue mutation
if [[ "$cmd" == "api" && "$sub" == "graphql" ]]; then
	# Extract -F num=N from args
	num=""
	mutation=0
	query_text=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "-F" && "$arg" =~ ^num=([0-9]+)$ ]]; then
			num="${BASH_REMATCH[1]}"
		fi
		if [[ "$prev" == "-f" && "$arg" =~ ^query= ]]; then
			query_text="${arg#query=}"
		fi
		prev="$arg"
	done
	if [[ "$query_text" == *"addSubIssue"* ]]; then
		# Record as a clean "MUTATION|parent=$parent|child=$child" line
		parent_val=""
		child_val=""
		prev=""
		for arg in "$@"; do
			if [[ "$prev" == "-f" ]]; then
				case "$arg" in
				parent=*) parent_val="${arg#parent=}" ;;
				child=*) child_val="${arg#child=}" ;;
				esac
			fi
			prev="$arg"
		done
		printf 'LINKED|parent=%s|child=%s\n' "$parent_val" "$child_val" >>"$TRACE_FILE"
		printf '{"data":{"addSubIssue":{"issue":{"number":1}}}}'
		exit 0
	fi
	if [[ "$query_text" == *"issue(number"* ]]; then
		# Node ID resolution — return canned "NODE_<num>" wrapped in the
		# response schema; --jq (if given) will reduce to just the id.
		_emit "$(printf '{"data":{"repository":{"issue":{"id":"NODE_%s"}}}}' "$num")"
		exit 0
	fi
	_emit '{"data":{}}'
	exit 0
fi

# Fallback
printf '\n'
exit 0
STUB
chmod +x "${TEST_TMPDIR}/bin/gh"
# NOTE: issue-sync-helper.sh prepends "/usr/local/bin:/usr/bin:/bin" to PATH
# on source (line 29), which would shadow our stub. Symlink our stub into
# /usr/local/bin is not portable; instead we install it at a path that the
# helper's prepended PATH will resolve, by placing it in a directory we then
# prepend AFTER sourcing. The cleanest fix is to override the `gh` command
# with a bash function AFTER sourcing the helper — functions take precedence
# over PATH lookups. We therefore define a `gh()` shell function below after
# `source "$HELPER"` and leave PATH alone.
export TRACE_FILE

# -----------------------------------------------------------------------------
# Test fixtures — three issues covering detection methods 1, 2, 3.
# Method 4 (parent-task via blocked-by) is covered in a separate invocation.
# -----------------------------------------------------------------------------

# Parent issues on the repo:
#   100: "t325: Exemplar Cases (parent)"
#   101: "t500: Orchestration epic"
#   200: "Already-linked parent"
export FIXTURE_PARENT_TITLES='t325: |100
t500: |101'

# Fixture issue set — uses heredocs composed via jq for robust JSON.
FIXTURE_ISSUES_JSON=$(
	cat <<'JSON'
[
  {
    "number": 2395,
    "title": "t325.2: feat: types + anonymizer",
    "body": "Shared types and LLM-based text anonymization module.\n\nBrief: `todo/tasks/t325.2-brief.md`\nParent: t325\nBlocked by: t325.1\n\n## Files\n- NEW: types.ts"
  },
  {
    "number": 2396,
    "title": "Follow-up: clarify anonymizer contract",
    "body": "No parent reference in this one; detection must return empty.\n"
  },
  {
    "number": 2397,
    "title": "Hotfix: exemplar cache",
    "body": "Parent: #200\nSome details here.\n"
  }
]
JSON
)
export FIXTURE_ISSUES_JSON
export FIXTURE_PARENT_TASK_NUMS=""

# -----------------------------------------------------------------------------
# Load the helper and run cmd_backfill_sub_issues
# -----------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$HELPER" # main() is guarded by BASH_SOURCE check

# Override `gh` as a bash function so it takes precedence over PATH lookups
# (issue-sync-helper.sh prepends /usr/local/bin:/usr/bin:/bin on source).
gh() {
	"${TEST_TMPDIR}/bin/gh" "$@"
}
export -f gh

export REPO_SLUG="test/repo"
export DRY_RUN="false"
unset TARGET_ISSUE_NUM

if ! cmd_backfill_sub_issues >"${TEST_TMPDIR}/cmd.out" 2>&1; then
	printf 'FAIL: cmd_backfill_sub_issues exited non-zero\n'
	cat "${TEST_TMPDIR}/cmd.out"
	exit 1
fi

# -----------------------------------------------------------------------------
# Assertions on the trace file.
# Expected mutations:
#   LINKED|parent=NODE_100|child=NODE_2395  (method 1: dot-notation title → t325)
#   LINKED|parent=NODE_200|child=NODE_2397  (method 3: Parent: #200)
# Expected absent:
#   LINKED|...|child=NODE_2396              (no parent detected)
# -----------------------------------------------------------------------------
failed=0
assert_trace_contains() {
	if ! grep -Fq -- "$1" "$TRACE_FILE"; then
		printf 'FAIL: trace missing: %s\n' "$1"
		failed=1
	fi
}
assert_trace_absent() {
	if grep -Fq -- "$1" "$TRACE_FILE"; then
		printf 'FAIL: trace unexpectedly contains: %s\n' "$1"
		failed=1
	fi
}

assert_trace_contains 'LINKED|parent=NODE_100|child=NODE_2395'
assert_trace_contains 'LINKED|parent=NODE_200|child=NODE_2397'
assert_trace_absent 'child=NODE_2396'

# -----------------------------------------------------------------------------
# Direct _detect_parent_from_gh_state unit tests for each method.
# -----------------------------------------------------------------------------
got=$(_detect_parent_from_gh_state "t325.2: feat: types" "Parent: t325" "test/repo")
if [[ "$got" != "100" ]]; then
	printf 'FAIL: dot-notation title detection returned "%s", expected "100"\n' "$got"
	failed=1
fi

got=$(_detect_parent_from_gh_state "Non-dot title" "Parent: #200" "test/repo")
if [[ "$got" != "200" ]]; then
	printf 'FAIL: Parent: #NNN detection returned "%s", expected "200"\n' "$got"
	failed=1
fi

# Method 2: explicit "Parent: tNNN" body line, non-dot child title — must
# bypass Method 1 and hit the body parser. Regression coverage for CR#7.
got=$(_detect_parent_from_gh_state "No dot here: a follow-up" "Parent: t325" "test/repo")
if [[ "$got" != "100" ]]; then
	printf 'FAIL: Parent: tNNN (Method 2) returned "%s", expected "100"\n' "$got"
	failed=1
fi

# Method 1 multi-level: t325.2.3 must resolve to its immediate parent t325.2,
# not the root t325. In the fixture, issue 2395 has title "t325.2: feat: types",
# so gh_find_issue_by_title("t325.2: ") returns 2395. This is regression
# coverage for CR#4 (multi-level dot-notation handling): the previous regex
# `^t[0-9]+\.[0-9]+[a-z]?` matched only one dot segment, so t325.2.3 was
# not recognised as a Method-1 candidate and nested sub-issues went
# unbackfilled.
got=$(_detect_parent_from_gh_state "t325.2.3: deeper child" "" "test/repo")
if [[ "$got" != "2395" ]]; then
	printf 'FAIL: multi-level dot-notation returned "%s", expected "2395" (parent t325.2)\n' "$got"
	failed=1
fi

got=$(_detect_parent_from_gh_state "Unrelated title" "Just a body, no parent." "test/repo")
if [[ -n "$got" ]]; then
	printf 'FAIL: no-parent case returned "%s", expected empty\n' "$got"
	failed=1
fi

# Method 4: blocked-by a parent-tagged task
export FIXTURE_PARENT_TASK_NUMS="101"
got=$(_detect_parent_from_gh_state "t600: leaf task" "Blocked by: t500" "test/repo")
if [[ "$got" != "101" ]]; then
	printf 'FAIL: parent-task blocked-by detection returned "%s", expected "101"\n' "$got"
	failed=1
fi

# Method 4 negative: blocked-by an issue that is NOT parent-tagged
export FIXTURE_PARENT_TASK_NUMS=""
got=$(_detect_parent_from_gh_state "t600: leaf task" "Blocked by: t500" "test/repo")
if [[ -n "$got" ]]; then
	printf 'FAIL: non-parent blocked-by returned "%s", expected empty\n' "$got"
	failed=1
fi

# -----------------------------------------------------------------------------
# --dry-run does not emit LINKED entries
# -----------------------------------------------------------------------------
: >"$TRACE_FILE"
export DRY_RUN="true"
export FIXTURE_PARENT_TASK_NUMS=""
if ! cmd_backfill_sub_issues >"${TEST_TMPDIR}/dryrun.out" 2>&1; then
	printf 'FAIL: dry-run exited non-zero\n'
	cat "${TEST_TMPDIR}/dryrun.out"
	exit 1
fi
if grep -Fq 'LINKED|' "$TRACE_FILE"; then
	printf 'FAIL: dry-run produced LINKED mutations\n'
	failed=1
fi

# -----------------------------------------------------------------------------
# Single-issue mode (TARGET_ISSUE_NUM set). CR#7 regression coverage — the
# single-issue `gh issue view` path was never exercised because the earlier
# block always cleared TARGET_ISSUE_NUM. Serves one fixture via
# FIXTURE_SINGLE_ISSUE to the stub's `gh issue view N --json number,title,body`
# branch and asserts the parent link is written.
# -----------------------------------------------------------------------------
: >"$TRACE_FILE"
export DRY_RUN="false"
export FIXTURE_SINGLE_ISSUE='{"number":2395,"title":"t325.2: feat: types","body":"Parent: t325\nShared types module."}'
export TARGET_ISSUE_NUM="2395"
if ! cmd_backfill_sub_issues >"${TEST_TMPDIR}/single.out" 2>&1; then
	printf 'FAIL: single-issue mode exited non-zero\n'
	cat "${TEST_TMPDIR}/single.out"
	failed=1
fi
if ! grep -Fq 'LINKED|parent=NODE_100|child=NODE_2395' "$TRACE_FILE"; then
	printf 'FAIL: single-issue mode did not link #2395 to parent 100\n'
	printf 'trace:\n'
	cat "$TRACE_FILE"
	failed=1
fi
unset TARGET_ISSUE_NUM FIXTURE_SINGLE_ISSUE

if [[ "$failed" -eq 0 ]]; then
	printf 'PASS: test-backfill-sub-issues — all assertions green\n'
	exit 0
fi
printf '\nFAIL: test-backfill-sub-issues — see diagnostics above\n'
printf '\n--- trace file ---\n'
cat "$TRACE_FILE"
exit 1
