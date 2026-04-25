#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-canonical-recovery.sh — Regression tests for pulse-canonical-recovery.sh
# (t2865 / GH#20922).
#
# Covers the recovery decision tree and cross-cutting safety gates:
#
#   1. State detection — clean / uncommitted / unmerged / not-a-repo are
#      classified correctly by `_pcr_detect_state`.
#   2. Clean no-op    — `pulse_canonical_recover` on a clean repo returns 0
#                       without touching state.
#   3. Recovery path  — uncommitted local changes blocking pull are stashed,
#                       the pull replays, and the stash is popped clean.
#                       Repo ends up at origin HEAD with local changes restored.
#   4. Unmerged path  — `git merge --abort` clears UU state and the repo
#                       lands clean without needing a stash.
#   5. Failure path   — pull fails after stash (divergent history);
#                       advisory is filed via `gh issue create`. The call
#                       MUST go through the real `gh_create_issue` wrapper
#                       so the gh-wrapper-guard contract holds.
#   6. Hot-loop guard — exceeding MAX_ATTEMPTS in the window short-circuits
#                       to advisory without re-attempting recovery.
#   7. Dry-run        — DRY_RUN=1 leaves the repo state untouched.
#   8. Audit log      — every recovery attempt records ≥1 operation.verify
#                       entry via audit-log-helper.sh.
#
# `gh` and `audit-log-helper.sh` are stubbed via PATH so no real network
# calls or audit log entries are made.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME and stub directories.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Stub `gh` to capture invocations instead of hitting GitHub.
GH_STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$GH_STUB_DIR"
GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
cat >"${GH_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Record the invocation, return empty for issue list (no existing advisory),
# and succeed for issue create.
#
# NOTE: real `gh` with `--jq '.[0].number // empty'` against an empty list
# emits empty output. Our stub returns empty (NOT '[]') for `issue list` so
# the helper's idempotency check correctly proceeds to `gh issue create`
# when no prior advisory exists. Returning '[]' here would make the helper
# treat the literal '[]' as an existing issue number and short-circuit.
printf '%s\n' "$*" >>"${GH_CALL_LOG:-/dev/null}"
case "$1" in
	issue)
		case "${2:-}" in
			list) ;; # empty stdout — matches gh --jq filter on []
			create) ;; # silent success
			*) ;;
		esac
		;;
	label)
		case "${2:-}" in
			list) ;; # empty
			*) ;;  # create / set / etc — no-op
		esac
		;;
	api)
		# `_gh_wrapper_auto_sig` and others may call `gh api user --jq .login`.
		# Return a minimal JSON object so callers that consume stdout don't
		# break. Real gh with --jq applies the filter; here we just emit
		# `{}` and let the caller handle empty filter results.
		printf '{}\n'
		;;
esac
exit 0
STUB
chmod +x "${GH_STUB_DIR}/gh"

# Stub audit-log-helper.sh to capture invocations into a log.
AUDIT_CALL_LOG="${TEST_ROOT}/audit-calls.log"
mkdir -p "${TEST_SCRIPTS_DIR}-stubs"
AUDIT_STUB="${TEST_ROOT}/stubs/audit-log-helper.sh"
cat >"$AUDIT_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$AUDIT_CALL_LOG"
exit 0
STUB
chmod +x "$AUDIT_STUB"

# Activate stubs.
export GH_CALL_LOG AUDIT_CALL_LOG
export PATH="${GH_STUB_DIR}:${PATH}"

# Override the audit-helper resolution via the helper's `_PCR_AUDIT_HELPER`
# env hook. Leaving SCRIPT_DIR pointing at the real script directory means
# `shared-gh-wrappers.sh` sources cleanly and `gh_create_issue` is defined,
# which is what makes the advisory-creation path actually exercisable.
# Without this hook, the previous test setup overrode SCRIPT_DIR to the
# stubs/ dir, which broke the wrapper source and short-circuited the test
# through the "wrapper unavailable" no-op branch — the assertions claimed
# coverage that wasn't real.
export _PCR_AUDIT_HELPER="${TEST_ROOT}/stubs/audit-log-helper.sh"

# Source the recovery helper. shellcheck disable=SC1091
# shellcheck source=../pulse-canonical-recovery.sh
source "${TEST_SCRIPTS_DIR}/pulse-canonical-recovery.sh" || {
	echo "FAIL: sourcing pulse-canonical-recovery.sh failed" >&2
	exit 1
}

# Sanity-check: gh_create_issue must be defined now that we're sourcing the
# real shared-gh-wrappers.sh from the real SCRIPT_DIR. If this fails the
# test is silently exercising the wrapper-unavailable branch and assertions
# below cannot prove advisory coverage.
if ! declare -F gh_create_issue >/dev/null 2>&1; then
	echo "FAIL: gh_create_issue undefined after sourcing helper — test setup broken" >&2
	exit 1
fi

# Override state file to point at the sandbox.
PULSE_CANONICAL_RECOVERY_STATE="${HOME}/.aidevops/.agent-workspace/supervisor/canonical-recovery-state.json"
export PULSE_CANONICAL_RECOVERY_STATE
PULSE_CANONICAL_RECOVERY_HOT_WINDOW=3600
PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS=3

# -----------------------------------------------------------------------------
# Helpers: synthetic git fixtures
# -----------------------------------------------------------------------------

# Create an "origin" bare-style clone and a working canonical clone.
# Outputs:
#   ORIGIN_DIR — path to non-bare repo serving as origin
#   CANON_DIR  — path to the canonical clone
make_repo_pair() {
	local label="$1"
	ORIGIN_DIR="${TEST_ROOT}/origin-${label}"
	CANON_DIR="${TEST_ROOT}/canon-${label}"
	rm -rf "$ORIGIN_DIR" "$CANON_DIR"
	mkdir -p "$ORIGIN_DIR"
	(
		cd "$ORIGIN_DIR" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
		printf 'v1\n' >foo.txt
		git add foo.txt
		git commit -qm "init"
	)
	git clone -q "$ORIGIN_DIR" "$CANON_DIR"
	(
		cd "$CANON_DIR" || exit 1
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
	)
	return 0
}

# Advance origin by one commit so the canonical clone is one commit behind.
advance_origin() {
	local origin="$1"
	(
		cd "$origin" || exit 1
		printf 'v2\n' >foo.txt
		git add foo.txt
		git commit -qm "advance"
	)
	return 0
}

reset_call_logs() {
	: >"$GH_CALL_LOG"
	: >"$AUDIT_CALL_LOG"
	rm -f "$PULSE_CANONICAL_RECOVERY_STATE" 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 1: state detection
# =============================================================================

make_repo_pair "state"

state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "clean" ]] \
	&& print_result "state detection: clean repo" 0 \
	|| print_result "state detection: clean repo" 1 "got: $state"

# Uncommitted change.
echo "local-edit" >>"${CANON_DIR}/foo.txt"
state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "uncommitted" ]] \
	&& print_result "state detection: uncommitted" 0 \
	|| print_result "state detection: uncommitted" 1 "got: $state"

# Reset.
git -C "$CANON_DIR" checkout -- foo.txt 2>/dev/null

# Not-a-repo.
state=$(_pcr_detect_state "${TEST_ROOT}/nonexistent")
[[ "$state" == "not-a-repo" ]] \
	&& print_result "state detection: not-a-repo" 0 \
	|| print_result "state detection: not-a-repo" 1 "got: $state"

# Unmerged: simulate by manually staging conflict markers.
make_repo_pair "unmerged"
(
	cd "$CANON_DIR" || exit 1
	# Create two divergent branches and force a merge conflict.
	git checkout -qb feature
	printf 'feature-edit\n' >foo.txt
	git commit -qam "feature"
	git checkout -q main
	printf 'main-edit\n' >foo.txt
	git commit -qam "main-divergent"
	git merge feature --no-edit 2>/dev/null || true
)
state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "unmerged" ]] \
	&& print_result "state detection: unmerged (UU)" 0 \
	|| print_result "state detection: unmerged (UU)" 1 "got: $state"

# =============================================================================
# Test 2: clean no-op
# =============================================================================

make_repo_pair "clean-noop"
reset_call_logs

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "clean repo: pulse_canonical_recover returns 0" 0
else
	print_result "clean repo: pulse_canonical_recover returns 0" 1 "exit nonzero"
fi
[[ ! -s "$AUDIT_CALL_LOG" ]] \
	&& print_result "clean repo: no audit calls" 0 \
	|| print_result "clean repo: no audit calls" 1 "log: $(cat "$AUDIT_CALL_LOG")"

# =============================================================================
# Test 3: recovery path — uncommitted local change on a non-overlapping file
# stashes, replays the upstream advance, and pops the stash cleanly.
# =============================================================================

make_repo_pair "recover"
# Origin advances foo.txt; we leave local-only.txt untracked locally.
advance_origin "$ORIGIN_DIR"
echo "local-only-line" >"${CANON_DIR}/local-only.txt"
reset_call_logs

# Pre-condition: with `-u` the stash captures the untracked file. Without
# stashing, `git pull --ff-only` succeeds in this scenario (no overlap), but
# `_pcr_detect_state` still returns "uncommitted" so recovery exercises the
# full stash → pull → pop path. This validates the conflict-free success
# branch of the decision tree.
if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "recover: pulse_canonical_recover returns 0 on success" 0
else
	print_result "recover: pulse_canonical_recover returns 0 on success" 1
fi

# Verify repo is now up-to-date with origin AND local file is restored.
canon_head=$(git -C "$CANON_DIR" rev-parse HEAD)
origin_head=$(git -C "$ORIGIN_DIR" rev-parse HEAD)
[[ "$canon_head" == "$origin_head" ]] \
	&& print_result "recover: HEAD matches origin after recovery" 0 \
	|| print_result "recover: HEAD matches origin after recovery" 1 "canon=$canon_head origin=$origin_head"

[[ -f "${CANON_DIR}/local-only.txt" ]] && grep -q "local-only-line" "${CANON_DIR}/local-only.txt" \
	&& print_result "recover: local change restored after stash pop" 0 \
	|| print_result "recover: local change restored after stash pop" 1

# Stash list should be empty after a clean pop.
stash_count=$(git -C "$CANON_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
[[ "$stash_count" == "0" ]] \
	&& print_result "recover: stash consumed (no leftover entries)" 0 \
	|| print_result "recover: stash consumed (no leftover entries)" 1 "count: $stash_count"

# Audit log should contain at least one operation.verify entry.
grep -q "operation.verify" "$AUDIT_CALL_LOG" \
	&& print_result "recover: audit log records ≥1 operation.verify entry" 0 \
	|| print_result "recover: audit log records ≥1 operation.verify entry" 1 "log: $(cat "$AUDIT_CALL_LOG")"

# Verify a "success" outcome was recorded.
grep -q "canonical-recovery.success" "$AUDIT_CALL_LOG" \
	&& print_result "recover: audit log records canonical-recovery.success" 0 \
	|| print_result "recover: audit log records canonical-recovery.success" 1

# =============================================================================
# Test 4: unmerged path — merge --abort suffices
# =============================================================================

make_repo_pair "unmerged-recover"
(
	cd "$CANON_DIR" || exit 1
	git checkout -qb feature
	printf 'feature-edit\n' >foo.txt
	git commit -qam "feature"
	git checkout -q main
	printf 'main-edit\n' >foo.txt
	git commit -qam "main-divergent"
	git merge feature --no-edit 2>/dev/null || true
)
reset_call_logs

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "unmerged: recovery returns 0 after merge --abort" 0
else
	print_result "unmerged: recovery returns 0 after merge --abort" 1
fi

state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "clean" ]] \
	&& print_result "unmerged: working tree clean after merge --abort" 0 \
	|| print_result "unmerged: working tree clean after merge --abort" 1 "state: $state"

# =============================================================================
# Test 5: failure path — pull fails after stash → advisory + return 1
# =============================================================================

make_repo_pair "fail-pull"
# Diverge canonical history vs origin so pull --ff-only must fail even after
# stashing (the issue isn't local changes — it's a non-fast-forward).
(
	cd "$CANON_DIR" || exit 1
	# Create a divergent commit on canonical's main.
	printf 'canonical-side\n' >foo.txt
	git commit -qam "canonical-divergent"
)
advance_origin "$ORIGIN_DIR"
# Add an uncommitted change so recovery enters the stash path.
echo "extra-line" >>"${CANON_DIR}/foo.txt"
reset_call_logs

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "fail-pull: persistent failure returns 1" 1 "expected nonzero"
else
	print_result "fail-pull: persistent failure returns 1" 0
fi

grep -q "issue create" "$GH_CALL_LOG" \
	&& print_result "fail-pull: gh issue create invoked for advisory" 0 \
	|| print_result "fail-pull: gh issue create invoked for advisory" 1 "log: $(cat "$GH_CALL_LOG")"

grep -q "operation.verify" "$AUDIT_CALL_LOG" \
	&& print_result "fail-pull: audit log records failure entry" 0 \
	|| print_result "fail-pull: audit log records failure entry" 1

# =============================================================================
# Test 6: hot-loop guard
# =============================================================================

make_repo_pair "hot-loop"
echo "uncommitted" >>"${CANON_DIR}/foo.txt"
reset_call_logs

# Pre-populate state file with MAX_ATTEMPTS recent entries.
now=$(date +%s)
mkdir -p "$(dirname "$PULSE_CANONICAL_RECOVERY_STATE")"
printf '{"%s":[%d,%d,%d]}' "$CANON_DIR" "$now" "$now" "$now" \
	>"$PULSE_CANONICAL_RECOVERY_STATE"

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "hot-loop: returns 1 after MAX_ATTEMPTS exhausted" 1 "expected nonzero"
else
	print_result "hot-loop: returns 1 after MAX_ATTEMPTS exhausted" 0
fi

grep -q "issue create" "$GH_CALL_LOG" \
	&& print_result "hot-loop: advisory issue create invoked on escalation" 0 \
	|| print_result "hot-loop: advisory issue create invoked on escalation" 1 "log: $(cat "$GH_CALL_LOG")"

# Verify recovery did NOT actually try to stash (escalation short-circuit).
state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "uncommitted" ]] \
	&& print_result "hot-loop: state preserved (no stash attempted)" 0 \
	|| print_result "hot-loop: state preserved (no stash attempted)" 1 "state: $state"

# =============================================================================
# Test 7: dry-run is read-only
# =============================================================================

make_repo_pair "dry-run"
echo "dry-run-edit" >>"${CANON_DIR}/foo.txt"
reset_call_logs
_PULSE_CANONICAL_RECOVERY_DRY_RUN=1

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "dry-run: returns 0 without acting" 0
else
	print_result "dry-run: returns 0 without acting" 1
fi

state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "uncommitted" ]] \
	&& print_result "dry-run: repo state untouched" 0 \
	|| print_result "dry-run: repo state untouched" 1 "state: $state"

# Stash list must be empty.
stash_count=$(git -C "$CANON_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
[[ "$stash_count" == "0" ]] \
	&& print_result "dry-run: no stash created" 0 \
	|| print_result "dry-run: no stash created" 1 "count: $stash_count"

# gh must NOT have been invoked.
[[ ! -s "$GH_CALL_LOG" ]] \
	&& print_result "dry-run: no gh advisory call" 0 \
	|| print_result "dry-run: no gh advisory call" 1 "log: $(cat "$GH_CALL_LOG")"

_PULSE_CANONICAL_RECOVERY_DRY_RUN=0

# =============================================================================
# Test 8: standalone invocation honours --dry-run + --help
# =============================================================================

make_repo_pair "standalone"
echo "standalone-edit" >>"${CANON_DIR}/foo.txt"

# --help exits 0 with usage text.
help_out=$("${TEST_SCRIPTS_DIR}/pulse-canonical-recovery.sh" --help 2>&1)
echo "$help_out" | grep -q "Usage:" \
	&& print_result "standalone: --help renders usage" 0 \
	|| print_result "standalone: --help renders usage" 1

# --dry-run on dirty repo → exit 0, no state change.
"${TEST_SCRIPTS_DIR}/pulse-canonical-recovery.sh" --dry-run "$CANON_DIR" \
	>/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] \
	&& print_result "standalone: --dry-run on dirty repo exits 0" 0 \
	|| print_result "standalone: --dry-run on dirty repo exits 0" 1 "rc: $rc"

# Missing argument → exit 2.
"${TEST_SCRIPTS_DIR}/pulse-canonical-recovery.sh" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] \
	&& print_result "standalone: missing repo-path exits 2" 0 \
	|| print_result "standalone: missing repo-path exits 2" 1 "rc: $rc"

# =============================================================================
# Test 9: jq-missing fail-closed escalation
# =============================================================================
#
# When jq is missing, the helper cannot maintain the persistent attempt
# counter that backs the hot-loop guard. Pre-fix behaviour: silent no-op
# (could loop forever if a transient pull failure recurred). Post-fix
# behaviour: fail-closed — every call escalates straight to advisory so
# the user is alerted instead of silently degrading. We simulate jq-missing
# by shadowing `_pcr_jq_required` in this scope.
#
# This test is at the end of the suite because the override leaks into
# the surrounding scope; subsequent in-process tests would see the stub.

make_repo_pair "no-jq"
echo "uncommitted-no-jq" >>"${CANON_DIR}/foo.txt"
reset_call_logs

# Override the jq-availability gate in this scope.
_pcr_jq_required() { return 1; }

if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "no-jq: fail-closed returns 1 on first call" 1 "expected nonzero"
else
	print_result "no-jq: fail-closed returns 1 on first call" 0
fi

grep -q "issue create" "$GH_CALL_LOG" \
	&& print_result "no-jq: advisory filed via gh issue create" 0 \
	|| print_result "no-jq: advisory filed via gh issue create" 1 "log: $(cat "$GH_CALL_LOG")"

# Repo state must be preserved — fail-closed does not stash, pull, or pop.
state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "uncommitted" ]] \
	&& print_result "no-jq: repo state preserved (no stash attempted)" 0 \
	|| print_result "no-jq: repo state preserved (no stash attempted)" 1 "state: $state"

# =============================================================================
# Summary
# =============================================================================

printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
