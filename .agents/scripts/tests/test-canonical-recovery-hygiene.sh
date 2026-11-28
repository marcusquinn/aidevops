#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Fixture test for canonical-recovery-helper.sh repair-stale-locks and
# maintenance-gc (GH#39722): held, fresh and stale locks, stale and fresh
# interrupted-fetch pack temporaries, a live Git process gate, the audit trail,
# a gc --auto that failed with "failed to run reflog", a gc.log recording
# reflogs that reference pruned commits (GH#40596), and the canonical guard.

set -uo pipefail

TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
export TEST_NATIVE_GIT
GIT="$TEST_NATIVE_GIT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
GUARD="${SCRIPT_DIR}/canonical-git-command-guard.py"
ROOT=$(mktemp -d)
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
HOLDER_PID=""
GIT_PROC_PID=""
FAILURES=0

cleanup() {
	[[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null
	[[ -n "$GIT_PROC_PID" ]] && kill "$GIT_PROC_PID" 2>/dev/null
	rm -rf "$ROOT"
	return 0
}
trap cleanup EXIT

# Inherited Git location overrides (for example from a hook) would redirect
# fixture writes into the developer's repository; HOME does not isolate them.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES
export HOME="${ROOT}/home"
mkdir -p "$HOME"
AUDIT_FILE="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
OLD_STAMP=202001010000

pass() {
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	printf 'FAIL %s\n' "$1"
	FAILURES=$((FAILURES + 1))
	return 0
}

init_repo() {
	local repo="$1"
	mkdir -p "$repo"
	"$GIT" -C "$repo" init -q -b main
	"$GIT" -C "$repo" config user.name Test
	"$GIT" -C "$repo" config user.email test@example.invalid
	"$GIT" -C "$repo" config commit.gpgsign false
	"$GIT" -C "$repo" config gc.auto 0
	printf 'seed\n' >"${repo}/README.md"
	"$GIT" -C "$repo" add README.md
	"$GIT" -C "$repo" commit -q -m seed
	"$GIT" -C "$repo" branch feature/auto-a
	"$GIT" -C "$repo" branch feature/auto-b
	return 0
}

run_helper() {
	AIDEVOPS_REAL_GIT_BIN="$GIT" bash "$HELPER" "$@" 2>&1 || return 1
	return 0
}

REPO="${ROOT}/repo"
init_repo "$REPO"
COMMON="${REPO}/.git"
STALE_LOCK="${COMMON}/logs/refs/heads/feature/auto-a.lock"
FRESH_LOCK="${COMMON}/logs/refs/heads/feature/auto-b.lock"
HELD_LOCK="${COMMON}/refs/heads/feature/held.lock"
LINK_LOCK="${COMMON}/refs/heads/feature/link.lock"
PACKED_LOCK="${COMMON}/packed-refs.lock"
OLD_PACK="${COMMON}/objects/pack/tmp_pack_old"
FRESH_PACK="${COMMON}/objects/pack/tmp_idx_fresh"
: >"$STALE_LOCK"
: >"$FRESH_LOCK"
: >"$HELD_LOCK"
: >"$PACKED_LOCK"
printf 'partial pack\n' >"$OLD_PACK"
printf 'partial idx\n' >"$FRESH_PACK"
ln -s "$PACKED_LOCK" "$LINK_LOCK"
touch -t "$OLD_STAMP" "$STALE_LOCK" "$HELD_LOCK" "$PACKED_LOCK" "$OLD_PACK"
# A live process holds the old lock open, as a running Git would.
(
	exec 8<"$HELD_LOCK"
	exec sleep 120
) &
HOLDER_PID=$!
sleep 1

dry_output=$(run_helper repair-stale-locks --repo "$REPO") || fail "dry run exited non-zero: $dry_output"
candidates=$(grep '^CANDIDATE ' <<<"$dry_output" | sed -E 's/.* path=([^ ]+).*/\1/' | LC_ALL=C sort | tr '\n' ' ')
expected="logs/refs/heads/feature/auto-a.lock objects/pack/tmp_pack_old packed-refs.lock "
if [[ "$candidates" == "$expected" ]]; then
	pass "dry run lists only stale, unheld locks and stale pack temporaries"
else
	fail "dry run candidates were '$candidates' (expected '$expected'): $dry_output"
fi
if [[ "$dry_output" == *"SKIP reason=fresh kind=lock path=logs/refs/heads/feature/auto-b.lock"* &&
	"$dry_output" == *"SKIP reason=held kind=lock path=refs/heads/feature/held.lock"* &&
	"$dry_output" == *"SKIP reason=not-regular kind=lock path=refs/heads/feature/link.lock"* &&
	"$dry_output" == *"SKIP reason=fresh kind=tmp-pack path=objects/pack/tmp_idx_fresh"* &&
	"$dry_output" == *"MODE=dry-run"* ]]; then
	pass "dry run reports fresh, held, symlinked and fresh-pack files as skipped"
else
	fail "dry run skip reasons incomplete: $dry_output"
fi
# GH#40476: pack temporaries are sized even while the age gate keeps them.
if [[ "$dry_output" == *"SKIP reason=fresh kind=tmp-pack path=objects/pack/tmp_idx_fresh size=12"* &&
	"$dry_output" == *$'\nTMP_PACK_BYTES=25\n'* && "$dry_output" == *$'\nTMP_PACK_YOUNG_BYTES=12\n'* ]]; then
	pass "dry run sizes stale and young pack temporaries"
else
	fail "dry run pack temporary sizes missing: $dry_output"
fi
if [[ -f "$STALE_LOCK" && -f "$PACKED_LOCK" && -f "$OLD_PACK" && ! -e "$AUDIT_FILE" ]]; then
	pass "dry run removes nothing and writes no audit entry"
else
	fail "dry run mutated the repository or audit log"
fi

# A live Git process that started before a lock was written may own it.
mkfifo "${ROOT}/git-stdin"
"$GIT" -C "$REPO" cat-file --batch <"${ROOT}/git-stdin" >/dev/null &
GIT_PROC_PID=$!
exec 7>"${ROOT}/git-stdin"
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[[ "$(ps -o comm= -p "$GIT_PROC_PID" 2>/dev/null)" == *git ]] && break
	sleep 0.2
done
sleep 1
PROC_LOCK="${COMMON}/refs/heads/feature/proc.lock"
: >"$PROC_LOCK"
proc_output=$(run_helper repair-stale-locks --repo "$REPO" --min-age-minutes 0)
if [[ "$proc_output" == *"SKIP reason=live-git-process kind=lock path=refs/heads/feature/proc.lock"* ]]; then
	pass "lock written while a live Git process for the repository runs is kept"
else
	fail "live Git process gate did not hold: $proc_output"
fi
exec 7>&-
wait "$GIT_PROC_PID" 2>/dev/null
GIT_PROC_PID=""
rm -f "$PROC_LOCK"

apply_output=$(run_helper repair-stale-locks --repo "$REPO" --apply) || fail "apply exited non-zero: $apply_output"
removed=$(grep '^REMOVED kind=' <<<"$apply_output" | sed -E 's/.* path=([^ ]+).*/\1/' | LC_ALL=C sort | tr '\n' ' ')
if [[ "$removed" == "$expected" && ! -e "$STALE_LOCK" && ! -e "$PACKED_LOCK" && ! -e "$OLD_PACK" &&
	-f "$FRESH_LOCK" && -f "$HELD_LOCK" && -L "$LINK_LOCK" && -f "$FRESH_PACK" ]]; then
	pass "apply removes exactly the listed files and keeps fresh, held and symlinked files"
else
	fail "apply removed '$removed' (expected '$expected'): $apply_output"
fi
audit_count=$(grep -c '"Canonical stale Git debris removed"' "$AUDIT_FILE" 2>/dev/null) || audit_count=0
if [[ "$audit_count" -eq 3 ]] && ! grep -F "$ROOT" "$AUDIT_FILE" >/dev/null &&
	! grep -F '"repo"' "$AUDIT_FILE" >/dev/null &&
	grep -F 'logs/refs/heads/feature/auto-a.lock' "$AUDIT_FILE" >/dev/null &&
	AUDIT_LOG_FILE="$AUDIT_FILE" bash "${SCRIPT_DIR}/audit-log-helper.sh" verify --quiet 2>/dev/null; then
	pass "apply writes one verified audit entry per file with relative paths and no repository path"
else
	fail "audit trail incorrect (entries=$audit_count)"
fi
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
HOLDER_PID=""

# Non-canonical targets are refused.
"$GIT" -C "$REPO" worktree add -q "${ROOT}/linked" -b feature/linked
if run_helper repair-stale-locks --repo "${ROOT}/linked" >/dev/null; then
	fail "repair accepted a linked worktree target"
else
	pass "repair refuses a linked worktree target"
fi

# gc --auto fails on a stale reflog lock, then succeeds after maintenance-gc.
GC_REPO="${ROOT}/gc-repo"
init_repo "$GC_REPO"
"$GIT" -C "$GC_REPO" repack -q -d
printf 'more\n' >>"${GC_REPO}/README.md"
"$GIT" -C "$GC_REPO" commit -q -am more
"$GIT" -C "$GC_REPO" repack -q -d
"$GIT" -C "$GC_REPO" config gc.auto 6700
"$GIT" -C "$GC_REPO" config gc.autoPackLimit 1
GC_LOCK="${GC_REPO}/.git/logs/refs/heads/feature/auto-a.lock"
: >"$GC_LOCK"
touch -t "$OLD_STAMP" "$GC_LOCK"
baseline=$("$GIT" -C "$GC_REPO" -c gc.autoDetach=false gc --auto 2>&1) || true
if [[ "$baseline" == *"failed to run reflog"* ]]; then
	pass "fixture reproduces gc --auto 'failed to run reflog' on a stale reflog lock"
else
	printf 'INFO baseline gc --auto did not reproduce the reflog failure on this Git: %s\n' "$baseline"
fi
gc_dry=$(run_helper maintenance-gc --repo "$GC_REPO")
if [[ "$gc_dry" == *"GC_PLAN="* && -f "$GC_LOCK" ]]; then
	pass "maintenance-gc dry run plans gc without mutation"
else
	fail "maintenance-gc dry run incorrect: $gc_dry"
fi
gc_output=$(run_helper maintenance-gc --repo "$GC_REPO" --apply) || fail "maintenance-gc apply failed: $gc_output"
pack_count=$(find "${GC_REPO}/.git/objects/pack" -name '*.pack' | wc -l | tr -d ' ')
if [[ "$gc_output" == *"GC_RESULT=ok"* && "$gc_output" != *"failed to run reflog"* &&
	! -e "$GC_LOCK" && "$pack_count" -eq 1 ]]; then
	pass "maintenance-gc removes the stale lock and gc --auto completes"
else
	fail "maintenance-gc result incorrect (packs=$pack_count): $gc_output"
fi
after=$("$GIT" -C "$GC_REPO" -c gc.autoDetach=false gc --auto 2>&1) || after="exit $?: $after"
if [[ "$after" != *"failed to run reflog"* && "$after" != exit* ]]; then
	pass "git gc --auto runs without 'failed to run reflog' after repair"
else
	fail "git gc --auto still fails after repair: $after"
fi

# GH#40618: a live repack launched from a linked worktree blocks debris removal
# and gc even when gc.pid names a different, dead process.
LR_REPO="${ROOT}/lr-repo"
init_repo "$LR_REPO"
"$GIT" -C "$LR_REPO" worktree add -q "${ROOT}/lr-linked" -b feature/lr-linked
LR_COMMON="${LR_REPO}/.git"
LR_GCLOG="${LR_COMMON}/gc.log"
LR_PACK="${LR_COMMON}/objects/pack/tmp_pack_live"
printf 'warning: previous gc\n' >"$LR_GCLOG"
printf 'partial pack\n' >"$LR_PACK"
printf '999999 %s' "$(hostname)" >"${LR_COMMON}/gc.pid"
touch -t "$OLD_STAMP" "$LR_PACK" "${LR_COMMON}/gc.pid"
# Process name and argv[0] must both be git-repack. A bash symlink provides
# that; copying coreutils sleep fails on multicall builds (unknown program).
mkdir -p "${ROOT}/fakebin"
ln -s "$(command -v bash)" "${ROOT}/fakebin/git-repack"
(
	cd "${ROOT}/lr-linked" || exit 1
	exec "${ROOT}/fakebin/git-repack" -c 'for ((i = 0; i < 120; i++)); do sleep 1; done'
) &
REPACK_PID=$!
sleep 1
lr_output=$(run_helper maintenance-gc --repo "$LR_REPO" --apply --min-age-minutes 0 --tmp-min-age-days 0)
kill "$REPACK_PID" 2>/dev/null
wait "$REPACK_PID" 2>/dev/null
if [[ "$lr_output" == *"SKIP reason=live-repack-process kind=tmp-pack path=objects/pack/tmp_pack_live"* &&
	"$lr_output" == *"GC_RESULT=skipped reason=live-repack-process"* &&
	-f "$LR_PACK" && -f "$LR_GCLOG" && -f "${LR_COMMON}/gc.pid" ]]; then
	pass "live repack in a linked worktree keeps temp packs, gc.log and gc.pid and skips gc"
else
	fail "live repack gate did not hold: $lr_output"
fi

# GH#40596: a gc.log that only records reflogs referencing pruned commits is
# repaired (stale entries dropped, then gc.log removed); other content stays.
STALE_REPO="${ROOT}/stale-repo"
init_repo "$STALE_REPO"
"$GIT" -C "$STALE_REPO" switch -q -c topic
printf 'lost\n' >>"${STALE_REPO}/README.md"
"$GIT" -C "$STALE_REPO" commit -q -am lost
LOST=$("$GIT" -C "$STALE_REPO" rev-parse HEAD)
"$GIT" -C "$STALE_REPO" reset -q --hard HEAD~1
"$GIT" -C "$STALE_REPO" switch -q main
rm -f "${STALE_REPO}/.git/objects/${LOST:0:2}/${LOST:2}"
GC_LOG="${STALE_REPO}/.git/gc.log"
STALE_LINES="warning: reflog of 'HEAD' references pruned commits
warning: reflog of 'refs/heads/topic' references pruned commits"
printf '%s\n' "$STALE_LINES" >"$GC_LOG"
main_entries=$("$GIT" -C "$STALE_REPO" reflog show --format=%H refs/heads/main | wc -l | tr -d ' ')
probe_before=$("$GIT" -C "$STALE_REPO" rev-list --no-walk --reflog 2>&1 >/dev/null)
if [[ "$probe_before" == *"reflog of 'refs/heads/topic' references pruned commits"* ]]; then
	pass "fixture reproduces a reflog that references a pruned commit"
else
	fail "fixture did not reproduce the stale reflog: $probe_before"
fi
stale_dry=$(run_helper maintenance-gc --repo "$STALE_REPO") || fail "stale-reflog dry run failed: $stale_dry"
if [[ "$stale_dry" == *"GC_LOG=present lines=2 unknown_lines=0"* &&
	"$stale_dry" == *"STALE_REFLOG ref=refs/heads/topic"* && "$stale_dry" == *"STALE_REFLOG ref=HEAD"* &&
	"$stale_dry" == *"GC_LOG_PLAN=repair stale_reflogs=2"* && "$stale_dry" == *"PACK_COUNT="* &&
	-f "$GC_LOG" ]]; then
	pass "maintenance-gc dry run reports stale reflogs and plans the gc.log repair without mutation"
else
	fail "stale-reflog dry run incorrect: $stale_dry"
fi
stale_apply=$(run_helper maintenance-gc --repo "$STALE_REPO" --apply) || fail "stale-reflog apply failed: $stale_apply"
probe_after=$("$GIT" -C "$STALE_REPO" rev-list --no-walk --reflog 2>&1 >/dev/null)
main_after=$("$GIT" -C "$STALE_REPO" reflog show --format=%H refs/heads/main | wc -l | tr -d ' ')
if [[ "$stale_apply" == *"STALE_REFLOG_REPAIR=ok"* && "$stale_apply" == *"REMOVED kind=gc-log path=gc.log"* &&
	"$stale_apply" == *"GC_RESULT=ok"* && ! -e "$GC_LOG" && -z "$probe_after" &&
	"$main_after" == "$main_entries" ]]; then
	pass "maintenance-gc drops only stale reflog entries, removes gc.log and runs gc"
else
	fail "stale-reflog apply incorrect (main $main_entries->$main_after, probe='$probe_after'): $stale_apply"
fi
if grep -F '"Canonical stale reflog repair finished"' "$AUDIT_FILE" | grep -F '"result":"ok"' >/dev/null &&
	grep -F '"path":"gc.log"' "$AUDIT_FILE" >/dev/null && ! grep -F "$ROOT" "$AUDIT_FILE" >/dev/null &&
	AUDIT_LOG_FILE="$AUDIT_FILE" bash "${SCRIPT_DIR}/audit-log-helper.sh" verify --quiet 2>/dev/null; then
	pass "reflog repair and gc.log removal are audited without a repository path"
else
	fail "reflog repair audit trail incorrect"
fi
printf '%s\nerror: unexpected gc failure\n' "$STALE_LINES" >"$GC_LOG"
unknown_apply=$(run_helper maintenance-gc --repo "$STALE_REPO" --apply)
if [[ "$unknown_apply" == *"GC_LOG_PLAN=keep reason=unknown-content"* && -f "$GC_LOG" ]]; then
	pass "gc.log with unknown content is reported and kept"
else
	fail "unknown gc.log content handling incorrect: $unknown_apply"
fi
printf '%s\n' "$STALE_LINES" >"$GC_LOG"
sleep 120 &
GC_SLEEP_PID=$!
printf '%s %s' "$GC_SLEEP_PID" "$(hostname)" >"${STALE_REPO}/.git/gc.pid"
running_apply=$(run_helper maintenance-gc --repo "$STALE_REPO" --apply)
kill "$GC_SLEEP_PID" 2>/dev/null
wait "$GC_SLEEP_PID" 2>/dev/null
rm -f "${STALE_REPO}/.git/gc.pid"
if [[ "$running_apply" == *"GC_LOG_PLAN=keep reason=gc-running"* && -f "$GC_LOG" ]]; then
	pass "gc.log is kept while gc.pid names a live gc"
else
	fail "live gc gate for gc.log incorrect: $running_apply"
fi
# A gc.log left by a transient state whose reflogs are already clean is removed.
clean_apply=$(run_helper maintenance-gc --repo "$STALE_REPO" --apply) || fail "clean-probe apply failed: $clean_apply"
if [[ "$clean_apply" == *"REMOVED kind=gc-log path=gc.log"* && "$clean_apply" != *"STALE_REFLOG "* &&
	"$clean_apply" != *"STALE_REFLOG_REPAIR="* && ! -e "$GC_LOG" ]]; then
	pass "stale gc.log is removed when the reflog probe is already clean"
else
	fail "clean-probe gc.log removal incorrect: $clean_apply"
fi

# The helper is the sanctioned path; direct canonical gc stays blocked.
printf '{"initialized_repos":[{"path":"%s"}]}\n' "$REPO" >"${ROOT}/repos.json"
export AIDEVOPS_REPOS_FILE="${ROOT}/repos.json"
guard_out=$(python3 "$GUARD" --cwd "$REPO" --command "git gc --auto" 2>&1)
guard_rc=$?
if [[ "$guard_rc" -eq 42 && "$guard_out" == *"maintenance-gc"* ]]; then
	pass "direct canonical git gc is blocked and points to maintenance-gc"
else
	fail "direct canonical git gc guard result rc=$guard_rc: $guard_out"
fi
if python3 "$GUARD" --cwd "$REPO" --command "'${HELPER}' maintenance-gc --repo '${REPO}' --apply" >/dev/null 2>&1; then
	pass "canonical guard accepts the maintenance-gc helper path"
else
	fail "canonical guard rejected the maintenance-gc helper path"
fi

if [[ "$FAILURES" -gt 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All canonical recovery hygiene checks passed\n'
exit 0
