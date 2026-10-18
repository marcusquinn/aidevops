#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#35024: fault-inject a SIGKILL between `git worktree add` and the ownership
# registry write in worktree-helper-add.sh, then assert the interrupted
# generation is never attributed, the fetch scratch worktree did not leak, the
# guarded clean sweep preserves it, and a rerun reuses it instead of replacing it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../worktree-helper.sh"
REAL_GIT=$(command -v git)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

REMOTE="${ROOT}/remote.git"
CANONICAL="${ROOT}/canonical"
WORKTREES="${ROOT}/worktrees"
BIN="${ROOT}/bin"
HOME="${ROOT}/home"
export HOME AIDEVOPS_WORKTREE_BASE_DIR="$WORKTREES"
export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${ROOT}/cleanup-receipts"
export AIDEVOPS_CLEANUP_LOG="${ROOT}/cleanup.log"
REGISTRY_DB="${HOME}/.aidevops/.agent-workspace/worktree-registry.db"
BRANCH="test/interrupted"
WT_PATH="${WORKTREES}/canonical-test-interrupted"
FAILURES=0

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	FAILURES=$((FAILURES + 1))
	return 0
}

registered_rows() {
	local branch="$1"
	[[ -f "$REGISTRY_DB" ]] || {
		printf '0\n'
		return 0
	}
	sqlite3 "$REGISTRY_DB" "SELECT count(*) FROM worktree_owners WHERE branch = '${branch}';" 2>/dev/null || printf '0\n'
	return 0
}

mkdir -p "$HOME" "$BIN"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$CANONICAL" 2>/dev/null
git -C "$CANONICAL" switch -q -c main
git -C "$CANONICAL" config user.name Test
git -C "$CANONICAL" config user.email test@example.invalid
git -C "$CANONICAL" commit -q --allow-empty -m seed
git -C "$CANONICAL" push -q -u origin main
git -C "$CANONICAL" remote set-head origin main

# Fault injector: after the named `git worktree add -b` succeeds, SIGKILL the
# helper before it can reach register_worktree. Fires once.
cat >"${BIN}/git" <<'GIT_WRAPPER'
#!/usr/bin/env bash
rc=0
"$AIDEVOPS_TEST_REAL_GIT" "$@" || rc=$?
if [[ "$rc" -eq 0 && " $* " == *" worktree add "* && " $* " == *" -b "* && -f "$AIDEVOPS_TEST_KILL_PIDFILE" ]]; then
	target_pid=$(cat "$AIDEVOPS_TEST_KILL_PIDFILE")
	rm -f "$AIDEVOPS_TEST_KILL_PIDFILE"
	printf 'killed %s\n' "$target_pid" >"$AIDEVOPS_TEST_KILL_MARKER"
	kill -9 "$target_pid"
fi
exit "$rc"
GIT_WRAPPER
chmod +x "${BIN}/git"
# Offline, deterministic gh: every PR/issue query is unavailable evidence.
printf '#!/usr/bin/env bash\nexit 1\n' >"${BIN}/gh"
chmod +x "${BIN}/gh"

export AIDEVOPS_TEST_REAL_GIT="$REAL_GIT"
export AIDEVOPS_TEST_KILL_PIDFILE="${ROOT}/kill.pid"
export AIDEVOPS_TEST_KILL_MARKER="${ROOT}/kill.marker"

ADD_RC=0
(
	cd "$CANONICAL" || exit 1
	PATH="${BIN}:${PATH}" AIDEVOPS_SKIP_AUTO_CLAIM=1 bash -c \
		'printf "%s" "$$" >"$1"; shift; exec "$@"' _ \
		"$AIDEVOPS_TEST_KILL_PIDFILE" "$HELPER" add "$BRANCH" >"${ROOT}/add.out" 2>&1
) || ADD_RC=$?

if [[ -f "$AIDEVOPS_TEST_KILL_MARKER" && "$ADD_RC" -ne 0 ]]; then
	pass "helper was killed between worktree creation and registration (rc=${ADD_RC})"
else
	fail "fault injection did not fire (rc=${ADD_RC}): $(tr '\n' ' ' <"${ROOT}/add.out")"
fi
[[ -d "$WT_PATH" ]] && git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/${BRANCH}" &&
	pass "interrupted generation exists on disk and as a branch" ||
	fail "interrupted generation missing"
[[ "$(registered_rows "$BRANCH")" == "0" ]] &&
	pass "interrupted generation has no ownership registration" ||
	fail "interrupted generation was registered"
if compgen -G "${WORKTREES}/.canonical-fetch-*" >/dev/null; then
	fail "fetch scratch worktree leaked before the named add"
else
	pass "fetch scratch worktree was removed before the named add"
fi

# Guarded sweep: age the directory past the grace window so preservation must
# come from the remaining guards (pre-work branch / unavailable PR evidence).
touch -t 202001010000 "$WT_PATH"
(
	cd "$CANONICAL" || exit 1
	PATH="${BIN}:${PATH}" "$HELPER" clean --auto >"${ROOT}/clean.out" 2>&1
) || true
[[ -d "$WT_PATH" ]] && pass "guarded clean sweep preserves the unregistered interrupted generation" ||
	fail "guarded clean sweep removed the interrupted generation: $(tr '\n' ' ' <"${ROOT}/clean.out")"

# Rerun: the existing generation is reported and reused, never replaced.
RERUN_RC=0
(
	cd "$CANONICAL" || exit 1
	PATH="${BIN}:${PATH}" AIDEVOPS_SKIP_AUTO_CLAIM=1 "$HELPER" add "$BRANCH" >"${ROOT}/rerun.out" 2>&1
) || RERUN_RC=$?
if [[ "$RERUN_RC" -eq 0 && -d "$WT_PATH" ]] && grep -qF "Worktree already exists for branch '${BRANCH}'" "${ROOT}/rerun.out"; then
	pass "rerun reuses the interrupted generation"
else
	fail "rerun did not reuse the interrupted generation (rc=${RERUN_RC}): $(tr '\n' ' ' <"${ROOT}/rerun.out")"
fi

if [[ "$FAILURES" -ne 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All create-register interruption checks passed\n'
exit 0
