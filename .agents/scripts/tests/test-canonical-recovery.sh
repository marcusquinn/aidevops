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

# Override the advisory directory to point at the sandbox BEFORE sourcing
# the helper, so the helper picks up the sandboxed default. (The helper
# uses parameter expansion `:-` so the env var wins over the in-script
# default at source time.)
PULSE_CANONICAL_RECOVERY_ADVISORY_DIR="${TEST_ROOT}/advisories"
export PULSE_CANONICAL_RECOVERY_ADVISORY_DIR
mkdir -p "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR"

# Source the recovery helper. shellcheck disable=SC1091
# shellcheck source=../pulse-canonical-recovery.sh
source "${TEST_SCRIPTS_DIR}/pulse-canonical-recovery.sh" || {
	echo "FAIL: sourcing pulse-canonical-recovery.sh failed" >&2
	exit 1
}

# Override state file to point at the sandbox.
PULSE_CANONICAL_RECOVERY_STATE="${HOME}/.aidevops/.agent-workspace/supervisor/canonical-recovery-state.json"
export PULSE_CANONICAL_RECOVERY_STATE
PULSE_CANONICAL_RECOVERY_HOT_WINDOW=3600
PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS=3

# Helper for advisory-file assertions. After t2871, advisories are written
# to a local file rather than filed as GitHub issues. Mirror the production
# safe-basename derivation in `_pcr_file_advisory` exactly — `printf '%s'`
# avoids the trailing newline that `basename` would otherwise produce
# (which `tr -c` would convert to `_`, breaking the filename match).
advisory_file_for() {
	local repo_path="$1"
	local raw safe
	raw=$(basename "$repo_path")
	safe=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/canonical-recovery-%s.advisory' "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR" "$safe"
	return 0
}

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
	# Clear any advisory files from prior tests so per-test assertions are
	# independent. Bash 3.2-safe glob expansion.
	if [[ -d "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR" ]]; then
		rm -f "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR"/*.advisory 2>/dev/null || true
	fi
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
# Test 5: failure path — pull fails after stash → local advisory file + return 1
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

# Local advisory file MUST be created and MUST NOT trigger any gh call.
adv_file=$(advisory_file_for "$CANON_DIR")
[[ -f "$adv_file" ]] \
	&& print_result "fail-pull: local advisory file created" 0 \
	|| print_result "fail-pull: local advisory file created" 1 "expected: $adv_file"

[[ ! -s "$GH_CALL_LOG" ]] \
	&& print_result "fail-pull: NO gh call (privacy: t2871)" 0 \
	|| print_result "fail-pull: NO gh call (privacy: t2871)" 1 "log: $(cat "$GH_CALL_LOG")"

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

# Local advisory file is the new escalation channel (t2871).
adv_file=$(advisory_file_for "$CANON_DIR")
[[ -f "$adv_file" ]] \
	&& print_result "hot-loop: local advisory file created on escalation" 0 \
	|| print_result "hot-loop: local advisory file created on escalation" 1 "expected: $adv_file"

[[ ! -s "$GH_CALL_LOG" ]] \
	&& print_result "hot-loop: NO gh call (privacy: t2871)" 0 \
	|| print_result "hot-loop: NO gh call (privacy: t2871)" 1 "log: $(cat "$GH_CALL_LOG")"

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

# No local advisory file written either.
adv_file=$(advisory_file_for "$CANON_DIR")
[[ ! -e "$adv_file" ]] \
	&& print_result "dry-run: no local advisory file written" 0 \
	|| print_result "dry-run: no local advisory file written" 1 "found: $adv_file"

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

# Local advisory still files even with jq missing — escalation path is
# unchanged by t2871; only the channel changed.
adv_file=$(advisory_file_for "$CANON_DIR")
[[ -f "$adv_file" ]] \
	&& print_result "no-jq: local advisory file created" 0 \
	|| print_result "no-jq: local advisory file created" 1 "expected: $adv_file"

[[ ! -s "$GH_CALL_LOG" ]] \
	&& print_result "no-jq: NO gh call (privacy: t2871)" 0 \
	|| print_result "no-jq: NO gh call (privacy: t2871)" 1 "log: $(cat "$GH_CALL_LOG")"

# Repo state must be preserved — fail-closed does not stash, pull, or pop.
state=$(_pcr_detect_state "$CANON_DIR")
[[ "$state" == "uncommitted" ]] \
	&& print_result "no-jq: repo state preserved (no stash attempted)" 0 \
	|| print_result "no-jq: repo state preserved (no stash attempted)" 1 "state: $state"

# =============================================================================
# Test 10: privacy regression (t2871) — advisory body contains no raw
# absolute paths that would leak username, drive topology, or repo prefix.
# =============================================================================
#
# This test replaces the no-op repo path with a representative leaky path
# and asserts the composed advisory body never contains:
#   - the raw username segment (e.g. /home/dave/, /Users/dave/)
#   - the drive/mount segment in the form that exposes user identity
#   - the legacy "Auto-filed by `pulse-canonical-recovery.sh` after exhausting
#     auto-recovery attempts for canonical repo `<absolute path>`" preamble
#
# `_pcr_advisory_body` is sourced from the helper and we call it directly —
# no need to fully simulate a failure. This is a pure body-composition test.

# Restore the real jq gate (if still overridden from Test 9 — it's a function
# definition leak, not actually used in this synthetic path, but be tidy).
unset -f _pcr_jq_required 2>/dev/null || true

# Synthetic "user paths" — these never touch a real filesystem.
declare -a leak_test_paths=(
	"/home/dave/Git/request-handler"
	"/Users/marcusquinn/Git/awardsapp"
	"/mnt/data/dave/Git/php-src"
)

for raw_path in "${leak_test_paths[@]}"; do
	body=$(_pcr_advisory_body "$raw_path" "stash-push-failed")

	# Username segment must not appear verbatim. We test the leaf segment
	# right after the home/users/mount root.
	case "$raw_path" in
		/home/*) leaked_user="/home/dave/" ;;
		/Users/*) leaked_user="/Users/marcusquinn/" ;;
		/mnt/*) leaked_user="/mnt/data/dave/" ;;
		*) leaked_user="" ;;
	esac

	if [[ -n "$leaked_user" ]]; then
		if printf '%s' "$body" | grep -qF "$leaked_user"; then
			print_result "privacy: '${raw_path}' — username segment NOT in advisory body" 1 "leaked: $leaked_user"
		else
			print_result "privacy: '${raw_path}' — username segment NOT in advisory body" 0
		fi
	fi

	# Sanity: the basename SHOULD appear (it identifies the affected repo
	# for the user — that's the whole point of the advisory) AND a
	# sanitised <user> placeholder SHOULD appear.
	basename=$(basename "$raw_path")
	printf '%s' "$body" | grep -qF "$basename" \
		&& print_result "privacy: '${raw_path}' — basename '$basename' present (identifies affected repo)" 0 \
		|| print_result "privacy: '${raw_path}' — basename '$basename' present (identifies affected repo)" 1
done

# Direct unit test of _pcr_sanitise_path — exercise each substitution rule.
# /Users/<name>/<rest>
got=$(_pcr_sanitise_path "/Users/dave/Git/php-src")
[[ "$got" == "/Users/<user>/Git/php-src" ]] \
	&& print_result "sanitise: /Users/<name>/ → /Users/<user>/" 0 \
	|| print_result "sanitise: /Users/<name>/ → /Users/<user>/" 1 "got: $got"

# /home/<name>/<rest>
got=$(_pcr_sanitise_path "/home/dave/Git/request-handler")
[[ "$got" == "/home/<user>/Git/request-handler" ]] \
	&& print_result "sanitise: /home/<name>/ → /home/<user>/" 0 \
	|| print_result "sanitise: /home/<name>/ → /home/<user>/" 1 "got: $got"

# /mnt/<volume>/<name>/<rest> — keep volume label, strip user
got=$(_pcr_sanitise_path "/mnt/data/dave/Git/php-src")
[[ "$got" == "/mnt/data/<user>/Git/php-src" ]] \
	&& print_result "sanitise: /mnt/<volume>/<name>/ → /mnt/<volume>/<user>/" 0 \
	|| print_result "sanitise: /mnt/<volume>/<name>/ → /mnt/<volume>/<user>/" 1 "got: $got"

# $HOME-prefixed → ~ (uses sandbox HOME from this test setup). The helper
# deliberately emits a literal `~` byte rather than a shell-expandable
# tilde, so SC2088 is the right warning to silence here — there is no
# expansion semantics involved, the test asserts the exact byte sequence
# the helper writes into the advisory file.
# shellcheck disable=SC2088
expected_home_subst='~/Git/awardsapp'
got=$(_pcr_sanitise_path "${HOME}/Git/awardsapp")
[[ "$got" == "$expected_home_subst" ]] \
	&& print_result "sanitise: \$HOME/ → ~/" 0 \
	|| print_result "sanitise: \$HOME/ → ~/" 1 "got: $got"

# Unknown root → fallback to <repo>/<basename>
got=$(_pcr_sanitise_path "/some/weird/place/myrepo")
[[ "$got" == "<repo>/myrepo" ]] \
	&& print_result "sanitise: unknown root → <repo>/basename" 0 \
	|| print_result "sanitise: unknown root → <repo>/basename" 1 "got: $got"

# =============================================================================
# Test 11: stale-UU recovery — UU state without MERGE_HEAD is cleared via
# reset --merge HEAD without stashing (GH#20935)
# =============================================================================
#
# Scenario: git crashes mid-merge-resolve, leaving UU index entries (stages
# 1, 2, 3) but no .git/MERGE_HEAD sentinel.  The prior code called `merge
# --abort` (which exits 1 with "no merge to abort" — swallowed by `|| true`)
# leaving state still "unmerged", then attempted `stash push` which also
# fails on unresolved conflicts, and escalated to an advisory unnecessarily.
#
# The new path detects the stale-UU case (unmerged + no merge head files),
# runs `merge --abort || reset --merge HEAD`, re-checks state, and returns 0
# if clean — with a distinct `stale-uu-recover` audit event.
#
# Test 10 used `unset -f _pcr_jq_required` to clean up after Test 9's
# override.  We redefine it here so the hot-loop guard's jq-availability
# check works correctly in Test 11 instead of fail-closing on every call.
# shellcheck disable=SC2317
_pcr_jq_required() {
	command -v jq >/dev/null 2>&1
	return $?
}

# We simulate the crash by starting a real merge (which produces the correct
# index conflict state: stages 1/2/3, no stage 0, working tree with markers)
# and then removing .git/MERGE_HEAD to mimic git crashing mid-resolve.  This
# is more reliable than direct index manipulation with --index-info because
# it produces exactly the index layout git itself creates.
make_repo_pair "stale-uu"
reset_call_logs
(
	cd "$CANON_DIR" || exit 1
	git checkout -qb feature-stale
	printf 'feature-edit\n' >foo.txt
	git commit -qam "feature"
	git checkout -q main
	printf 'main-edit\n' >foo.txt
	git commit -qam "main-divergent"
	# Trigger a real merge conflict so git creates MERGE_HEAD + index stages.
	git merge feature-stale --no-edit 2>/dev/null || true
	# Simulate git crashing mid-resolution by removing MERGE_HEAD.
	rm -f .git/MERGE_HEAD
)

# Pre-condition: state is "unmerged" and no MERGE_HEAD file exists.
stale_pre_state=$(_pcr_detect_state "$CANON_DIR")
[[ "$stale_pre_state" == "unmerged" ]] \
	&& print_result "stale-UU: pre-condition: state is 'unmerged'" 0 \
	|| print_result "stale-UU: pre-condition: state is 'unmerged'" 1 "got: $stale_pre_state"

[[ ! -e "${CANON_DIR}/.git/MERGE_HEAD" ]] \
	&& print_result "stale-UU: pre-condition: no MERGE_HEAD present" 0 \
	|| print_result "stale-UU: pre-condition: no MERGE_HEAD present" 1 "MERGE_HEAD found"

# Run recovery — should succeed via stale-UU path (merge --abort fails for
# no active merge, reset --merge HEAD clears the stale index entries).
if pulse_canonical_recover "$CANON_DIR" >/dev/null 2>&1; then
	print_result "stale-UU: recovery returns 0" 0
else
	print_result "stale-UU: recovery returns 0" 1 "got nonzero"
fi

# State must be clean after recovery.
stale_post_state=$(_pcr_detect_state "$CANON_DIR")
[[ "$stale_post_state" == "clean" ]] \
	&& print_result "stale-UU: working tree clean after recovery" 0 \
	|| print_result "stale-UU: working tree clean after recovery" 1 "state: $stale_post_state"

# No stash should have been created — the index-reset path bypasses stash.
stale_stash_count=$(git -C "$CANON_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
[[ "$stale_stash_count" == "0" ]] \
	&& print_result "stale-UU: no stash created (index reset path)" 0 \
	|| print_result "stale-UU: no stash created (index reset path)" 1 "stash count: $stale_stash_count"

# No advisory file — recovery succeeded, nothing to surface.
stale_adv_file=$(advisory_file_for "$CANON_DIR")
[[ ! -e "$stale_adv_file" ]] \
	&& print_result "stale-UU: no advisory file on success" 0 \
	|| print_result "stale-UU: no advisory file on success" 1 "found: $stale_adv_file"

# Audit log MUST record a stale-uu-recover entry — distinct from merge-abort.
# The outcome is "ok:index-reset" (not "success") to keep the repeated
# string literal count below the linter threshold.
grep -q "canonical-recovery.stale-uu-recover" "$AUDIT_CALL_LOG" \
	&& print_result "stale-UU: audit log records stale-uu-recover event" 0 \
	|| print_result "stale-UU: audit log records stale-uu-recover event" 1 "log: $(cat "$AUDIT_CALL_LOG")"

# No gh call — stale-UU success uses the local advisory channel (same as
# all other paths in t2871).
[[ ! -s "$GH_CALL_LOG" ]] \
	&& print_result "stale-UU: no gh call (local advisory channel)" 0 \
	|| print_result "stale-UU: no gh call (local advisory channel)" 1 "log: $(cat "$GH_CALL_LOG")"

# =============================================================================
# Summary
# =============================================================================

printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
