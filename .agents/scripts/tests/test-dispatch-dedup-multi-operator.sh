#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-dedup-multi-operator.sh — Regression tests for multi-operator dispatch dedup
#
# t1996: Verify that every dispatch decision site applies the combined
# "(active status label) AND (non-self assignee)" gate. Simulates two
# pulses (runner-a, runner-b) racing for the same issue and asserts:
#
#   1. Race winner (assigned first) gets dispatch; race loser is blocked
#   2. Degraded state (status:queued + no assignee) → is_assigned() returns
#      SAFE, allowing any runner to reclaim (stale recovery model)
#   3. Non-owner assignee without a status label → is_assigned() still
#      blocks (the "worker user" rule: any non-self, non-owner assignee
#      always blocks regardless of labels)
#   4. Owner/maintainer + active status label → blocks dispatch (GH#18352)
#      Combined signal: label alone or assignee alone is not enough for owner
#
# Also verifies normalize_active_issue_assignments() behavior when another
# runner has already claimed an orphaned issue in the reconcile window.
#
# Requires only: bash, dispatch-dedup-helper.sh, a stub gh binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)

	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/config/aidevops"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	# repos.json with owner and maintainer for test slugs
	cat >"${TEST_ROOT}/config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/home/user/Git/testrepo",
      "slug": "testorg/testrepo",
      "pulse": true,
      "maintainer": "testmaintainer"
    }
  ]
}
EOF

	export REPOS_JSON="${TEST_ROOT}/config/aidevops/repos.json"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a gh stub for a specific issue state.
#
# Args:
#   $1 = comma-separated assignee logins (or "" for none)
#   $2 = comma-separated label names (or "" for none)
#   $3 = issue state (default OPEN)
#
# The stub returns a recent "Dispatching worker" comment to prevent the
# stale-assignment recovery path from firing during tests.
create_gh_stub() {
	local assignees_csv="$1"
	local labels_csv="${2:-}"
	local state="${3:-OPEN}"
	local assignees_json labels_json recent_ts

	assignees_json=$(
		ASSIGNEES_CSV="$assignees_csv" python3 - <<'PY'
import json, os
items=[i for i in os.environ.get('ASSIGNEES_CSV','').split(',') if i]
print(json.dumps([{"login": i} for i in items]))
PY
	)
	labels_json=$(
		LABELS_CSV="$labels_csv" python3 - <<'PY'
import json, os
items=[i for i in os.environ.get('LABELS_CSV','').split(',') if i]
print(json.dumps([{"name": i} for i in items]))
PY
	)
	recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"${state}","assignees":${assignees_json},"labels":${labels_json}}'
	exit 0
fi

# Stale-assignment check: return a recent dispatch comment
if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -q '/comments'; then
	printf '%s\n' '[{"created_at":"${recent_ts}","author":"runner-a","body_start":"Dispatching worker (PID 12345)"}]'
	exit 0
fi

# gh issue edit / comment — succeed silently
if [[ "\${1:-}" == "issue" && ("\${2:-}" == "edit" || "\${2:-}" == "comment") ]]; then
	exit 0
fi

printf 'unsupported gh invocation in stub: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# ─── Test 1: Race winner gets dispatch, race loser is blocked ────────────────
#
# Scenario: runner-a is assigned to issue 100 with status:queued.
# runner-b calls is_assigned() — must be BLOCKED because runner-a is
# a non-self assignee AND an active status label is present.
# This is the fundamental multi-operator race outcome: the first to
# assign wins; all subsequent callers must see the BLOCKED result.
test_race_winner_blocks_loser() {
	# Simulate: runner-a won the race (assigned + status:queued)
	create_gh_stub "runner-a" "status:queued,auto-dispatch"

	local output=""
	# runner-b checks → must be BLOCKED (runner-a != runner-b, active label present)
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b 2>/dev/null); then
		# exit 0 = blocked — correct
		case "$output" in
		*'ASSIGNED:'*'runner-a'*)
			print_result "race winner (runner-a) blocks loser (runner-b)" 0
			return 0
			;;
		esac
		print_result "race winner (runner-a) blocks loser (runner-b)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	# exit 1 = safe to dispatch — wrong: runner-a claimed it
	print_result "race winner (runner-a) blocks loser (runner-b)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# ─── Test 2: Degraded state (label + no assignee) → safe to reclaim ─────────
#
# If a worker died after setting status:queued but before assigning itself,
# the issue is in a "label only, no assignee" degraded state.
# is_assigned() must return SAFE so stale recovery (or normalize_active_issue_assignments)
# can reclaim it. A label without an assignee is NOT an active claim.
# This directly tests the "neither alone is sufficient" half of the combined rule.
test_degraded_label_no_assignee_is_safe() {
	# status:queued set, but no assignee (worker died mid-claim)
	create_gh_stub "" "status:queued,auto-dispatch"

	# Any runner should see this as SAFE (no assignee to block on)
	if "$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-a >/dev/null 2>&1; then
		# exit 0 = blocked — wrong: no assignee means safe
		print_result "degraded state (label+no assignee) allows dispatch (combined rule)" 1 \
			"Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	# exit 1 = safe — correct
	print_result "degraded state (label+no assignee) allows dispatch (combined rule)" 0
	return 0
}

# ─── Test 3: Non-owner assignee without status label → blocks dispatch ───────
#
# The "non-owner worker user" rule: any non-self, non-owner/maintainer assignee
# ALWAYS blocks dispatch, regardless of label state. This ensures that when a
# contributor is assigned to work on an issue, the pulse never races them even
# if the contributor didn't set a status label.
# This tests the "assignee alone is sufficient for non-owner users" side.
test_nonowner_assignee_no_label_blocks() {
	# contributor-user assigned, no status label (they're a non-owner worker)
	create_gh_stub "contributor-user" "bug,help-wanted"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-a 2>/dev/null); then
		# exit 0 = blocked — correct for non-owner assignee
		case "$output" in
		*'ASSIGNED:'*'contributor-user'*)
			print_result "non-owner assignee without label blocks dispatch" 0
			return 0
			;;
		esac
		print_result "non-owner assignee without label blocks dispatch" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	# exit 1 = safe — wrong: contributor-user is a non-owner assignee
	print_result "non-owner assignee without label blocks dispatch" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe). Non-owner assignee must always block."
	return 0
}

# ─── Test 4: Owner + active status label → blocks dispatch (GH#18352) ────────
#
# The combined signal: owner/maintainer + active status label = active claim.
# The owner alone (passive) would NOT block. But when paired with an active
# lifecycle label, it means a real worker was dispatched by the owner's pulse.
# Combined test: label alone ≠ block (tested above), assignee (owner) alone ≠ block,
# but label AND owner-assignee together → block.
test_owner_plus_active_label_blocks() {
	# testorg/testrepo owner is testorg (from slug prefix)
	create_gh_stub "testorg" "status:in-progress,auto-dispatch"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'testorg'*)
			print_result "owner + active status label blocks dispatch (combined rule, GH#18352)" 0
			return 0
			;;
		esac
		print_result "owner + active status label blocks dispatch (combined rule, GH#18352)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	print_result "owner + active status label blocks dispatch (combined rule, GH#18352)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# ─── Test 5: Owner without active label → SAFE (passive exemption) ───────────
#
# Complement to Test 4. Owner assigned with no active status label = passive
# backlog bookkeeping (GH#10521 fix). The pulse must be able to dispatch.
# Ensures the "combined rule" doesn't regress to "owner alone always blocks".
test_owner_no_label_is_passive() {
	create_gh_stub "testorg" "bug,tier:standard"

	if "$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b >/dev/null 2>&1; then
		print_result "owner without active label is passive (GH#10521 regression guard)" 1 \
			"Expected exit 1 (safe) but got exit 0 (blocked)"
		return 0
	fi

	print_result "owner without active label is passive (GH#10521 regression guard)" 0
	return 0
}

# ─── Test 6: Maintainer + active label → blocks dispatch ─────────────────────
#
# Same as Test 4 but for the configured maintainer (testmaintainer from repos.json).
# Ensures the combined rule applies to maintainers, not just slug owners.
test_maintainer_plus_active_label_blocks() {
	create_gh_stub "testmaintainer" "status:claimed,origin:interactive"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'testmaintainer'*)
			print_result "maintainer + active label blocks dispatch (combined rule)" 0
			return 0
			;;
		esac
		print_result "maintainer + active label blocks dispatch (combined rule)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	print_result "maintainer + active label blocks dispatch (combined rule)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# ─── Test 7: Self-assignment in reconcile race → second runner blocked ────────
#
# Simulates normalize_active_issue_assignments() behavior after a race:
# runner-a won the reconcile race and assigned itself to an orphaned issue.
# When runner-b calls is_assigned(), it must be blocked (runner-a != runner-b).
# This is the specific two-assignee stuck state prevented by t1996's fix to
# normalize_active_issue_assignments() — now it calls is_assigned() before
# self-assigning, so only the first reconciler assigns itself.
test_reconcile_race_second_runner_blocked() {
	# runner-a reconciled first (assigned itself, status:queued still set)
	create_gh_stub "runner-a" "status:queued"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'runner-a'*)
			print_result "reconcile race: second runner blocked after first runner reconciled (t1996)" 0
			return 0
			;;
		esac
		print_result "reconcile race: second runner blocked after first runner reconciled (t1996)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	print_result "reconcile race: second runner blocked after first runner reconciled (t1996)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe)"
	return 0
}

# ─── Test 8: Interactive session on existing origin:worker issue ─────────────
#
# t2057 — When an interactive session engages with an existing origin:worker
# issue, it calls interactive-session-helper.sh claim which applies
# status:in-review and self-assigns. The resulting state is:
#
#   assignee: testorg (owner, self-assigned by interactive session)
#   labels:   origin:worker, status:in-review
#
# When a pulse worker (runner-b) checks is_assigned(), it must be BLOCKED
# via the combined signal: owner + active status label (in-review). The
# origin:worker label is a creation-time marker that does NOT prevent
# interactive takeover; the status:in-review label is what signals active
# human ownership. This closes the gap where an interactive session picking
# up a worker-origin issue previously left no dispatch-blocking signal.
#
# Equivalent to Test 4 but with origin:worker present to confirm the label
# does not confuse the combined rule.
test_interactive_on_worker_origin_blocks() {
	# interactive session on existing origin:worker issue: owner self-assigned,
	# status:in-review applied by interactive-session-helper.sh claim
	create_gh_stub "testorg" "origin:worker,status:in-review,tier:standard"

	local output=""
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo runner-b 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'*'testorg'*)
			print_result "interactive session on origin:worker issue blocks dispatch (t2057)" 0
			return 0
			;;
		esac
		print_result "interactive session on origin:worker issue blocks dispatch (t2057)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	print_result "interactive session on origin:worker issue blocks dispatch (t2057)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe). Interactive claim via status:in-review must block parallel worker dispatch."
	return 0
}

# ─── Test 9: Single-user — self-assigned + origin:interactive blocks dispatch ──
#
# GH#18956 / t2091 — The classic single-user failure mode.
#
# Scenario: an interactive session filed issue #100 with origin:interactive
# and self-assigned it (user=testorg=repo owner). The pulse runner is ALSO
# authenticated as testorg (single-user setup). The old code's self-login
# exemption fired first → blocking_assignees was empty → pulse dispatched a
# duplicate worker.
#
# Fix (t2091): the self-login exemption is skipped when active_claim=="true".
# origin:interactive is an active claim signal, so the issue must block
# dispatch even when assignee==self_login.
test_single_user_interactive_self_assigned_blocks() {
	# Interactive session: owner self-assigned, origin:interactive present.
	# Pulse runner login == owner (single-user setup).
	create_gh_stub "testorg" "origin:interactive,auto-dispatch,tier:standard"

	local output=""
	# Pulse calls is_assigned() with self_login=testorg (same as assignee)
	if output=$("$HELPER_SCRIPT" is-assigned 100 testorg/testrepo testorg 2>/dev/null); then
		case "$output" in
		*'ASSIGNED:'* | *'INTERACTIVE_SESSION_BLOCKED:'*)
			print_result "single-user: self-assigned + origin:interactive blocks dispatch (t2091)" 0
			return 0
			;;
		esac
		print_result "single-user: self-assigned + origin:interactive blocks dispatch (t2091)" 1 \
			"exit 0 but unexpected output: ${output}"
		return 0
	fi

	print_result "single-user: self-assigned + origin:interactive blocks dispatch (t2091)" 1 \
		"Expected exit 0 (blocked) but got exit 1 (safe). GH#18956: self-login exemption must not override origin:interactive."
	return 0
}

# ─── Test 10: Self-assigned WITHOUT active claim is still passive (regression) ─
#
# Verify that the t2091 fix does NOT break the GH#10521 passive-bookkeeping
# rule. An owner self-assigned to an issue with NO active claim label (no
# status:*, no origin:interactive) must still be treated as passive —
# dispatch should proceed.
test_single_user_self_assigned_no_label_is_passive() {
	# Owner self-assigned, no active-claim labels (pure passive bookkeeping).
	create_gh_stub "testorg" "enhancement,tier:standard"

	local output=""
	# Pulse (self_login=testorg) checks → must be SAFE (passive bookkeeping)
	if "$HELPER_SCRIPT" is-assigned 100 testorg/testrepo testorg 2>/dev/null; then
		print_result "single-user: self-assigned + no active label remains passive (GH#10521 regression)" 1 \
			"Expected exit 1 (safe) but got exit 0 (blocked). Passive self-assignment must not block dispatch."
		return 0
	fi
	print_result "single-user: self-assigned + no active label remains passive (GH#10521 regression)" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	echo "=== Multi-operator dispatch dedup regression tests (t1996) ==="
	echo ""

	test_race_winner_blocks_loser
	test_degraded_label_no_assignee_is_safe
	test_nonowner_assignee_no_label_blocks
	test_owner_plus_active_label_blocks
	test_owner_no_label_is_passive
	test_maintainer_plus_active_label_blocks
	test_reconcile_race_second_runner_blocked
	test_interactive_on_worker_origin_blocks
	test_single_user_interactive_self_assigned_blocks
	test_single_user_self_assigned_no_label_is_passive

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
