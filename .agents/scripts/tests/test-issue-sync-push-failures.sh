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
