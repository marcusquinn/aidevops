#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${TEST_DIR}/../local-branch-cleanup-helper.sh"
ROOT="${PWD}/.agents/tmp/test-local-branch-cleanup.$$"
REPO="$ROOT/repo"
BIN="$ROOT/bin"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; return 1; }
assert_has() {
	local value="$1" expected="$2"
	[[ "$value" == *"$expected"* ]] || fail "missing $expected in $value"
	return 0
}
cleanup() {
	git -C "$REPO" worktree remove --force "$ROOT/active" >/dev/null 2>&1 || true
	rm -rf "$ROOT"
	return 0
}
trap cleanup EXIT

test_commit() {
	local name="$1"
	printf '%s\n' "$name" >"$REPO/$name"
	git -C "$REPO" add "$name"
	git -C "$REPO" -c commit.gpgsign=false commit -qm "$name"
	return 0
}

mkdir -p "$BIN"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name 'Local Cleanup Test'
test_commit base
git -C "$REPO" branch -M main
git -C "$REPO" remote add origin https://github.com/example/aidevops.git
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$REPO" branch merged
git -C "$REPO" branch open-pr
git -C "$REPO" branch fork-pr
git -C "$REPO" branch active
git -C "$REPO" worktree add -q "$ROOT/active" active
git -C "$REPO" checkout -qb unmerged
test_commit unmerged
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb squash
test_commit squash
SQUASH_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main

cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
*'pulls?state=open&'*) printf '%s\n' '[{"state":"open","head":{"ref":"fork-pr","sha":"x"},"merged_at":null},{"state":"open","head":{"ref":"open-pr","sha":"x"},"merged_at":null}]' ;;
*'example:squash&'*) printf '[{"state":"closed","head":{"ref":"squash","sha":"%s"},"merged_at":"2026-09-29T00:00:00Z"}]\n' "$SQUASH_SHA" ;;
*) printf '%s\n' '[]' ;;
esac
STUB
chmod +x "$BIN/gh"
export SQUASH_SHA
export GH_LOG="$ROOT/gh.log"
export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/transport"
export AUDIT_LOG_DIR="$ROOT/audit"
dry=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO")
assert_has "$dry" 'would-delete merged'
assert_has "$dry" 'would-delete squash'
assert_has "$dry" 'keep main protected'
assert_has "$dry" 'keep active checked out'
assert_has "$dry" 'keep open-pr open PR'
assert_has "$dry" 'keep fork-pr open PR'
assert_has "$dry" 'keep unmerged unmerged local commits'
git -C "$REPO" show-ref --verify --quiet refs/heads/merged || fail 'dry-run deleted a ref'
assert_has "$dry" 'summary scanned='
[[ "$(grep -c 'pulls?state=open&' "$GH_LOG")" -eq 1 ]] || fail 'open PRs listed more than once per scan'
budget=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO" --max-lookups 0)
assert_has "$budget" 'would-delete merged'
assert_has "$budget" 'keep squash lookup budget exhausted'
assert_has "$budget" 'budget_exhausted=2'

result=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO" --branch merged --apply)
assert_has "$result" 'deleted merged'
git -C "$REPO" show-ref --verify --quiet refs/heads/merged && fail 'merged branch survived apply'
result=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO" --branch squash --apply)
assert_has "$result" "deleted squash $SQUASH_SHA"
git -C "$REPO" show-ref --verify --quiet refs/heads/squash && fail 'squash branch survived apply'
[[ "$(jq -s '[.[] | select(.type == "local-branch-delete")] | length' "$ROOT/audit/audit.jsonl")" -eq 2 ]] || fail 'deleted refs not audited'
bash "$TEST_DIR/../audit-log-helper.sh" verify --quiet || fail 'audit chain invalid'
result=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO" --branch squash --apply)
assert_has "$result" 'keep squash absent'
result=$(PATH="$BIN:$PATH" AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$REPO" --branch open-pr --apply)
assert_has "$result" 'keep open-pr github evidence unavailable'

# A lease failure preserves a branch moved after the scan, even when its old SHA was merged.
git -C "$REPO" branch race
cat >"$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *'update-ref -d refs/heads/race'* ]]; then
  /usr/bin/git -C "$TEST_REPO" update-ref refs/heads/race "$TEST_NEW_SHA"
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$BIN/git"
test_commit advance
TEST_NEW_SHA=$(git -C "$REPO" rev-parse HEAD)
export TEST_REPO="$REPO" TEST_NEW_SHA
if result=$(PATH="$BIN:$PATH" bash "$HELPER" --repo "$REPO" --branch race --apply); then
	fail 'moved ref deletion returned success'
fi
assert_has "$result" 'failed race ref changed after scan'
[[ "$(git -C "$REPO" rev-parse refs/heads/race)" == "$TEST_NEW_SHA" ]] || fail 'moved ref lost'
[[ "$(git -C "$REPO" worktree list --porcelain)" != *"$ROOT/transport"* ]] || fail 'transport left registered'
printf 'PASS: local cleanup dry-run, ancestry, merged PR, refusal, lease and transport\n'
