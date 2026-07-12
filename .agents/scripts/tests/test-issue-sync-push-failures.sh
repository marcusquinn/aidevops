#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$ROOT_DIR/.agents/scripts/issue-sync-helper-push.sh"

pass() { printf 'PASS: %s\n' "$1"; return 0; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
print_info() { printf '[INFO] %s\n' "$*"; return 0; }
print_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }

# shellcheck source=../issue-sync-helper-push.sh
source "$HELPER"

_init_cmd() {
	_CMD_REPO="example/repo"
	_CMD_TODO="/tmp/todo.md"
	_CMD_ROOT="/tmp"
	return 0
}

gh_create_label() { return 0; }
ensure_labels_exist() { return 0; }
_push_build_task_list() { printf 't999\n'; return 0; }

_push_process_task() {
	local task_id="$1"
	printf 'FAILED\n'
	[[ "$task_id" == "t999" ]] || return 1
	return 1
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

GITHUB_ACTIONS=true
FORCE_PUSH=false
if cmd_push "" >"$TMPDIR_TEST/push.out" 2>"$TMPDIR_TEST/push.err"; then
	fail "cmd_push succeeded despite failed issue creation"
fi
grep -q '1 failed' "$TMPDIR_TEST/push.out" || fail "cmd_push did not report failed task count"
grep -q 'Issue creation failed' "$TMPDIR_TEST/push.err" || fail "cmd_push did not emit actionable failure"
pass "cmd_push returns non-zero when issue creation fails"

cat >"$TMPDIR_TEST/gh" <<'GH_EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue create" ]]; then
	printf 'https://github.com/example/repo/issues/123\n'
	exit 0
fi
exit 1
GH_EOF
chmod +x "$TMPDIR_TEST/gh"
PATH="$TMPDIR_TEST:$PATH"

fallback_output=$(_push_create_issue_without_labels "example/repo" "t999: title" "body" "") || \
	fail "degraded issue creation helper failed"
[[ "$fallback_output" == *"/issues/123"* ]] || fail "degraded issue creation helper lost issue URL"
pass "degraded issue creation without labels preserves durable tracker creation"

# Post-create assignment and locking must remain behind immutable mapping
# validation, including the hard-failure path after GitHub created the issue.
WRITE_LOG="$TMPDIR_TEST/write-order.log"
: >"$WRITE_LOG"
session_origin_label() { printf 'origin:interactive\n'; return 0; }
gh_find_issue_by_title() { return 0; }
add_gh_ref_to_todo() { return 0; }
log_verbose() { return 0; }
_push_auto_assign_interactive() { printf 'ASSIGN\n' >>"$WRITE_LOG"; return 0; }
gh() {
	if [[ "$1 $2" == "issue create" ]]; then
		printf 'https://github.com/example/repo/issues/123\n'
		return 0
	fi
	if [[ "$1 $2" == "issue lock" ]]; then
		printf 'LOCK\n' >>"$WRITE_LOG"
		return 0
	fi
	return 1
}
require_task_issue_mapping() { printf 'VALIDATE\n' >>"$WRITE_LOG"; return 1; }
AIDEVOPS_SESSION_USER=example
if _push_create_issue t999 example/repo /tmp/todo.md 't999: title' body enhancement ''; then
	fail "create helper succeeded after mapping validation failed"
fi
[[ "$(<"$WRITE_LOG")" == "VALIDATE" ]] || fail "assignment or lock ran before failed mapping validation"
pass "mapping failure prevents post-create assignment and lock writes"

: >"$WRITE_LOG"
require_task_issue_mapping() { printf 'VALIDATE\n' >>"$WRITE_LOG"; return 0; }
_push_create_issue t999 example/repo /tmp/todo.md 't999: title' body enhancement '' || \
	fail "create helper failed after successful mapping validation"
[[ "$(sed -n '1p' "$WRITE_LOG")" == "VALIDATE" ]] || fail "mapping validation was not the first post-create operation"
grep -q '^ASSIGN$' "$WRITE_LOG" || fail "assignment did not run after mapping validation"
grep -q '^LOCK$' "$WRITE_LOG" || fail "lock did not run after mapping validation"
pass "mapping validation precedes post-create assignment and lock writes"
