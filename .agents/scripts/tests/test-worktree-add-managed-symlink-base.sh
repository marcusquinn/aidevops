#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-add-managed-symlink-base.sh — GH#35781 regression guard.
#
# Pulse creates worktrees with `worktree-helper.sh add` and, on the systemd
# backend, enrolls them with `worktree-managed-lifetime.py enroll`. The
# lifetime CLI requires a canonical path. When the repo root and worktree base
# were reached through a symlinked parent (for example ~/Git -> /data/Git), the
# generated path was not canonical: enrollment failed, the helper left an
# unenrolled worktree, and `match` on the porcelain path returned 3 (legacy).
#
# Assertions (real helper, real git, disposable registry):
#   1. Fresh managed add through a symlinked repo root and base succeeds.
#   2. Git porcelain records the canonical path, and `match` on it returns 0.
#   3. An injected enrollment failure exits non-zero, reports the
#      MANAGED_ENROLL_FAILED disposition, and leaves no worktree behind.
#   4. Pulse's helper-reason extractor surfaces the enrollment error.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$name"
	[[ -z "$detail" ]] || printf '       %s\n' "$detail"
	return 0
}

ROOT=$(mktemp -d -t gh35781.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
ROOT=$(cd "$ROOT" && pwd -P)
cd "$ROOT" || exit 1

mkdir -p "$ROOT/real/Git" "$ROOT/link" "$ROOT/home" "$ROOT/tmp"
ln -s "$ROOT/real/Git" "$ROOT/link/Git"
export HOME="$ROOT/home" WORKTREE_REGISTRY_DIR="$ROOT" WORKTREE_REGISTRY_DB="$ROOT/registry.db"
export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/link/Git/_worktrees" AIDEVOPS_TEMP_DIR="$ROOT/tmp"
export AIDEVOPS_CLEANUP_LOG="$ROOT/cleanup.log" AIDEVOPS_WORKTREE_TRASH_ROOT="$ROOT/recovery"
export AIDEVOPS_SESSION_ORIGIN=worker AIDEVOPS_SKIP_AUTO_CLAIM=1 WORKTREE_NODE_MODULES_RESTORE_ENABLED=0
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

REPO="$ROOT/link/Git/repo"
git init -q "$ROOT/real/Git/repo"
git -C "$REPO" commit -q --allow-empty -m fixture
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
bash -c 'source "$1/shared-worktree-registry.sh" && _init_registry_db' _ "$TEST_SCRIPTS_DIR" || exit 1

# Args: $1=scripts dir, $2=branch. Prints combined helper output; returns its rc.
managed_add() {
	local scripts="$1"
	local branch="$2"
	local rc=0
	(cd "$REPO" && AIDEVOPS_WORKTREE_MANAGER=pulse-cgroup-v1 AIDEVOPS_LAUNCH_TASK=15 \
		AIDEVOPS_LAUNCH_REPO=owner/repo AIDEVOPS_WORKTREE_BASE="$BASE_SHA" \
		"$scripts/worktree-helper.sh" add "$branch" --issue 15 2>&1) || rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}

porcelain_path() {
	local branch="$1"
	git -C "$REPO" worktree list --porcelain |
		awk -v b="branch refs/heads/$branch" '/^worktree /{p=substr($0,10)} $0==b{print p}'
	return 0
}

printf '\n=== GH#35781: managed worktree add through a symlinked base ===\n'

# --- 1-2: fresh create, then match, then managed ---------------------------
branch="feature/auto-20261027-000001-gh15"
rc=0
output=$(managed_add "$TEST_SCRIPTS_DIR" "$branch") || rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "fresh managed add through symlinked repo root and base succeeds"
else
	fail "fresh managed add through symlinked repo root and base succeeds" "rc=$rc: $(printf '%s' "$output" | tail -n 3 | tr '\n' ' ')"
fi
wt=$(porcelain_path "$branch")
match_rc=0
python3 "$TEST_SCRIPTS_DIR/worktree-managed-lifetime.py" match "$wt" 15 owner/repo >/dev/null 2>&1 || match_rc=$?
if [[ "$wt" == "$ROOT/real/Git/_worktrees/"* && "$match_rc" -eq 0 ]]; then
	pass "porcelain path is canonical and match classifies it managed (rc=0)"
else
	fail "porcelain path is canonical and match classifies it managed (rc=0)" "path='$wt' match_rc=$match_rc"
fi

# --- 3: enrollment failure rolls back the created generation ---------------
# Disposable copy of the scripts tree with an enroll-only failure injected.
stub_scripts="$ROOT/scripts"
cp -R "$TEST_SCRIPTS_DIR" "$stub_scripts"
mv "$stub_scripts/worktree-managed-lifetime.py" "$stub_scripts/worktree-managed-lifetime-real.py"
printf '%s\n' 'import os, sys' \
	'if sys.argv[1] == "enroll":' \
	'    print("managed-worktree: ValueError: injected enroll failure", file=sys.stderr)' \
	'    sys.exit(1)' \
	'real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "worktree-managed-lifetime-real.py")' \
	'os.execv(sys.executable, [sys.executable, real, *sys.argv[1:]])' \
	>"$stub_scripts/worktree-managed-lifetime.py"
branch="feature/auto-20261027-000002-gh15"
rc=0
output=$(managed_add "$stub_scripts" "$branch") || rc=$?
wt=$(porcelain_path "$branch")
if [[ "$rc" -ne 0 && -z "$wt" && ! -d "$ROOT/real/Git/_worktrees/repo-feature-auto-20261027-000002-gh15" ]] &&
	[[ "$output" == *"AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=MANAGED_ENROLL_FAILED"* ]]; then
	pass "enrollment failure exits non-zero and leaves no worktree behind"
else
	fail "enrollment failure exits non-zero and leaves no worktree behind" "rc=$rc path='$wt'"
fi

# --- 4: Pulse names the enrollment cause in its precreation log ------------
reason=$(bash -c 'source "$1/pulse-dispatch-worker-launch.sh" >/dev/null 2>&1; _dlw_precreate_helper_reason "$2"' \
	_ "$TEST_SCRIPTS_DIR" "$output")
if [[ "$reason" == "managed-worktree: ValueError: injected enroll failure" ]]; then
	pass "pulse helper reason surfaces the enrollment error"
else
	fail "pulse helper reason surfaces the enrollment error" "reason='$reason'"
fi

printf '\n--- Results: %s tests, %s failed ---\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
