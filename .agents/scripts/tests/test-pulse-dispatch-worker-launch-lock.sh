#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression test for t3458: stale non-empty node_modules restore lock dirs
# must not spin forever in _dlw_node_modules_restore_acquire_lock.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3458-worker-launch-lock-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

lock_dir="${TEST_TMP}/worktree-node-modules-restore.lock.d"
mkdir -p "$lock_dir" || fail "failed to create lock dir"
printf '999999\n' >"${lock_dir}/pid" || fail "failed to create pid marker"

# Make the directory stale. macOS and GNU touch both support -t.
touch -t 200001010000 "$lock_dir" || fail "failed to age lock dir"

WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_node_modules_restore_acquire_lock "$lock_dir" || fail "lock acquire returned failure"

if [[ ! -f "${lock_dir}/pid" ]]; then
	fail "lock acquire did not recreate pid marker"
fi

_dlw_node_modules_restore_release_lock "$lock_dir"

if [[ -d "$lock_dir" ]]; then
	fail "lock release left lock dir behind"
fi

repo_dir="${TEST_TMP}/repo"
wt_dir="${TEST_TMP}/worktree"
mkdir -p "${repo_dir}/node_modules/example" "${repo_dir}/node_modules/.bin" "${repo_dir}/node_modules/prettier/bin" "$wt_dir" || fail "failed to create restore fixture dirs"
printf '{}\n' >"${repo_dir}/package.json" || fail "failed to create repo package.json"
printf '{}\n' >"${wt_dir}/package.json" || fail "failed to create worktree package.json"
printf 'fixture\n' >"${repo_dir}/node_modules/example/file.txt" || fail "failed to create node_modules fixture"
printf '#!/usr/bin/env node\n' >"${repo_dir}/node_modules/prettier/bin/prettier.cjs" || fail "failed to create prettier fixture"
ln -s ../prettier/bin/prettier.cjs "${repo_dir}/node_modules/.bin/prettier" || fail "failed to create prettier bin symlink"

LOGFILE="${TEST_TMP}/pulse.log" \
	AIDEVOPS_WORKSPACE_DIR="$TEST_TMP" \
	WORKTREE_NODE_MODULES_RESTORE_ENABLED=1 \
	WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=0 \
	WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_restore_worktree_deps "$wt_dir" "$repo_dir"

if [[ -d "${wt_dir}/node_modules/example" ]]; then
	fail "root node_modules payload was copied"
fi

if [[ ! -L "${wt_dir}/node_modules/.bin" ]]; then
	fail "root node_modules .bin tooling link was not created"
fi

_dlw_zero_output_comment_count() {
	fail "precomputed zero-output evidence count should skip comment API lookup"
	return 1
}

_dlw_zero_output_failure_count() {
	fail "precomputed zero-output evidence count should skip state lookup"
	return 1
}

if [[ "$(_dlw_zero_output_evidence_count 123 owner/repo "" 7)" != "7" ]]; then
	fail "precomputed zero-output evidence count was not returned directly"
fi

if ! grep -Fq "WORKER_GITHUB_LOGIN=\"\$self_login\"" "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"; then
	fail "pulse worker launch does not forward dispatching GitHub login"
fi

mkdir -p "${TEST_TMP}/bin" || fail "failed to create systemctl stub dir"
cat >"${TEST_TMP}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "show" ]]; then
	printf 'ActiveState=active\nSubState=running\nMainPID=4242'
	exit 0
fi
exit 1
EOF
chmod +x "${TEST_TMP}/bin/systemctl" || fail "failed to make systemctl stub executable"

resolved_pid=$(PATH="${TEST_TMP}/bin:${PATH}" LOGFILE="${TEST_TMP}/pulse.log" _dlw_systemd_resolve_main_pid "aidevops-test" "123") || fail "systemd PID resolver returned failure"
if [[ "$resolved_pid" != "4242" ]]; then
	fail "systemd PID resolver skipped final unterminated property"
fi

is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"
	[[ "$issue_body" == "blocked-body" && "$repo_slug" == "owner/repo" && "$issue_number" == "123" ]] || return 1
	return 0
}

if ! LOGFILE="${TEST_TMP}/pulse.log" _dlw_blocked_by_hard_stop "123" "owner/repo" '{"body":"blocked-body"}'; then
	fail "worker launch hard-stop did not block unresolved blocked-by dependency"
fi

printf 'PASS: stale non-empty node_modules restore lock is reclaimed\n'
printf 'PASS: root node_modules payload is skipped by default\n'
printf 'PASS: root node_modules .bin tooling is linked by default\n'
printf 'PASS: precomputed zero-output evidence count skips redundant lookups\n'
printf 'PASS: pulse worker launch forwards dispatching GitHub login\n'
printf 'PASS: systemd PID resolver handles final unterminated property\n'
printf 'PASS: worker launch hard-stops unresolved blocked-by dependencies\n'
exit 0
