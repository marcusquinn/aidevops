#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-routine-standalone.sh — t3036 / GH#21616 / GH#28207 guard.
#
# Asserts that pulse-merge-routine.sh (a standalone helper invoked by launchd
# every 120s) bootstraps successfully WITHOUT pulse-wrapper.sh's environment
# in scope. The routine sources pulse-merge.sh which references
# PULSE_START_EPOCH, unlock_issue_after_worker, fast_fail_reset, dependency
# reconciliation, and idempotent comments — all normally provided by
# pulse-wrapper.sh. Without explicit defaults / sourcing, `set -euo pipefail`
# in the routine causes hard failures or silently skips post-merge work.
#
# Root cause (t3036, GH#21616):
#   1. pulse-merge-routine.sh ran under `set -euo pipefail` (line 42) but did
#      NOT initialise PULSE_START_EPOCH. pulse-merge.sh:326 references it
#      inside _handle_post_merge_actions:
#        _merge_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
#      Hard fail under set -u. Every launchd invocation crashed before
#      writing the last-run marker.
#   2. unlock_issue_after_worker (defined in pulse-dispatch-core.sh) and
#      fast_fail_reset (defined in pulse-fast-fail.sh) were called from
#      pulse-merge.sh:338,383,385 but neither library was sourced by the
#      routine — every successful merge/close emitted 'command not found'
#      stderr noise.
#   3. reconcile_dependants_after_verified_closure was called after a linked
#      issue close but dependency-event-reconciler.sh was not sourced.
#   4. Standalone stuck-PR paths guarded and skipped escalation because
#      _gh_idempotent_comment from pulse-triage-cache.sh was not sourced.
#
# Fix (t3036, this PR):
#   - Initialise PULSE_START_EPOCH in the env-var defaults block.
#   - Source pulse-dispatch-core.sh and pulse-fast-fail.sh in the source chain.
#   - Source dependency-event-reconciler.sh and pulse-triage-cache.sh before
#     pulse-merge.sh and its conflict/stuck consumers (GH#28207).
#
# Test scenarios (all run with PULSE_START_EPOCH UNSET to catch regressions):
#   1. --help completes with exit 0 and no stderr noise
#   2. --help emits no 'command not found' errors
#   3. --help emits no 'unbound variable' errors
#   4. The routine file calls shared PULSE_START_EPOCH bootstrap (grep guard)
#   5. The routine file sources pulse-dispatch-core.sh (grep guard)
#   6. The routine file sources pulse-fast-fail.sh (grep guard)
#   7. runtime helpers define _should_setup_noninteractive_pulse_merge_routine
#   8. setup.sh call site uses the new helper (not the generic gate)
#   9. scheduler uses timeout-protected pulse-merge-routine
#   10. merge LaunchAgent uses normal spawn priority with explicit KeepAlive=false
#   11. standalone PATH repair keeps the framework gh shim first
#   12. leading --repo defaults to the run subcommand (GH#25698)
#   13. --pr configures an exact target
#   14. --pr rejects a missing --repo
#   15. dry-run stops before CI repair writes
#   16. exact spot-check bypasses the all-PR merge pass
#   17. GraphQL budget probing does not depend on the REST core budget
#   18. linked-issue closure invokes dependency reconciliation
#   19. stuck escalation invokes the idempotent comment provider
#   20. both paths run without missing-function diagnostics
#   21. missing gh authentication aborts before the first API request
#   22. standalone runs initialise a durable cross-process PR-view cache
#   23. inherited oversized PR batches are clamped for standalone runs
#   24-28. (GH#35349) due routines start once while another process holds the
#      Pulse instance lock, under the budget gate and routines.lockdir

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)" || exit 1

ROUTINE_FILE="${SCRIPTS_DIR}/pulse-merge-routine.sh"
SETUP_FILE="${REPO_ROOT}/setup.sh"
RUNTIME_HELPERS_FILE="${REPO_ROOT}/.agents/scripts/setup/_runtime_helpers.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_YELLOW=$'\033[1;33m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_YELLOW="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

skip() {
	local name="$1"
	local reason="${2:-}"
	printf '  %sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_NC" "$name" "$reason"
	return 0
}

if [[ ! -f "$ROUTINE_FILE" ]]; then
	printf '%sFATAL%s pulse-merge-routine.sh not found at %s\n' \
		"$TEST_RED" "$TEST_NC" "$ROUTINE_FILE"
	exit 1
fi

printf '%sRunning pulse-merge-routine standalone tests (t3036, GH#21616)%s\n' \
	"$TEST_GREEN" "$TEST_NC"

# =============================================================================
# Test 1: --help completes with exit 0 (catches Bug 2 PULSE_START_EPOCH crash)
# =============================================================================
# Even with PULSE_START_EPOCH unset, the routine should bootstrap successfully
# enough to print help. Pre-fix, this would crash under `set -u` if any
# pulse-merge.sh code path that touches PULSE_START_EPOCH ran during sourcing.
printf '\n=== Bootstrap tests (PULSE_START_EPOCH unset) ===\n'

unset PULSE_START_EPOCH PULSE_MERGE_BATCH_LIMIT

help_stderr=$(LC_ALL=C timeout 30 "$ROUTINE_FILE" --help 2>&1 >/dev/null) || true
help_exit=$(
	LC_ALL=C timeout 30 "$ROUTINE_FILE" --help >/dev/null 2>&1
	printf '%s' "$?"
)

if [[ "$help_exit" == "0" ]]; then
	pass "1: --help exits 0 with PULSE_START_EPOCH unset"
else
	fail "1: --help exits 0 with PULSE_START_EPOCH unset" \
		"exit=$help_exit, stderr=$help_stderr"
fi

# =============================================================================
# Test 2: No 'command not found' errors during bootstrap
# =============================================================================
# Pre-fix, sourcing pulse-merge.sh emitted 'unlock_issue_after_worker: command
# not found' and 'fast_fail_reset: command not found' on every PR processed.
# Here-strings, not `printf | grep -q`: under pipefail the early-exit reader
# races the writer into SIGPIPE false results on Linux (GH#35943).
if grep -q -- 'command not found' <<<"$help_stderr"; then
	fail "2: no 'command not found' errors" \
		"stderr: $help_stderr"
else
	pass "2: no 'command not found' errors"
fi

# =============================================================================
# Test 3: No 'unbound variable' errors during bootstrap
# =============================================================================
# Pre-fix, line 326 of pulse-merge.sh (_merge_elapsed=$(($(date +%s) -
# PULSE_START_EPOCH))) failed under `set -u` when PULSE_START_EPOCH was unset.
if grep -q -- 'unbound variable' <<<"$help_stderr"; then
	fail "3: no 'unbound variable' errors" \
		"stderr: $help_stderr"
else
	pass "3: no 'unbound variable' errors"
fi

# =============================================================================
# Test 4: PULSE_START_EPOCH is initialised via shared bootstrap
# =============================================================================
printf '\n=== Source-content guards ===\n'

if grep -qE '^aidevops_ensure_pulse_start_epoch$' "$ROUTINE_FILE"; then
	pass "4: PULSE_START_EPOCH initialised via shared bootstrap"
else
	fail "4: PULSE_START_EPOCH initialised via shared bootstrap" \
		"missing aidevops_ensure_pulse_start_epoch call"
fi

# =============================================================================
# Test 5: pulse-dispatch-core.sh is sourced (provides unlock_issue_after_worker)
# =============================================================================
if grep -qE 'source "\$\{SCRIPT_DIR\}/pulse-dispatch-core\.sh"' "$ROUTINE_FILE"; then
	pass "5: pulse-dispatch-core.sh sourced (unlock_issue_after_worker)"
else
	fail "5: pulse-dispatch-core.sh sourced (unlock_issue_after_worker)" \
		"missing 'source ... pulse-dispatch-core.sh' line"
fi

# =============================================================================
# Test 6: pulse-fast-fail.sh is sourced (provides fast_fail_reset)
# =============================================================================
if grep -qE 'source "\$\{SCRIPT_DIR\}/pulse-fast-fail\.sh"' "$ROUTINE_FILE"; then
	pass "6: pulse-fast-fail.sh sourced (fast_fail_reset)"
else
	fail "6: pulse-fast-fail.sh sourced (fast_fail_reset)" \
		"missing 'source ... pulse-fast-fail.sh' line"
fi

if grep -qF "export PATH=\"\${SCRIPT_DIR}:\${PATH}\"" "$ROUTINE_FILE"; then
	pass "6b: routine re-prioritises framework scripts in PATH"
else
	fail "6b: routine re-prioritises framework scripts in PATH" \
		"missing SCRIPT_DIR PATH prepend after script-dir resolution"
fi

# =============================================================================
# Test 6c: merge runs fail closed when gh has no authentication context
# =============================================================================
auth_test_home=$(mktemp -d)
auth_output=""
auth_exit=0
auth_output=$(HOME="$auth_test_home" GH_TOKEN="" GITHUB_TOKEN="" \
	LC_ALL=C timeout 30 "$ROUTINE_FILE" --repo example/repo 2>&1) || auth_exit=$?
rm -rf "$auth_test_home"

if [[ "$auth_exit" -ne 0 ]] && grep -qF -- 'refusing unauthenticated API access' <<<"$auth_output"; then
	pass "6c: missing gh authentication aborts before API access"
else
	fail "6c: missing gh authentication aborts before API access" \
		"exit=$auth_exit, output=$auth_output"
fi

# =============================================================================
# Test 6d: standalone bootstrap creates the persistent PR-view cache
# =============================================================================
cache_test_home=$(mktemp -d)
cache_output=""
cache_exit=0
cache_output=$(HOME="$cache_test_home" "$ROUTINE_FILE" help 2>&1) || cache_exit=$?
if [[ "$cache_exit" -eq 0 && -d "$cache_test_home/.aidevops/cache/pulse-pr-view-cache" ]]; then
	pass "6d: standalone bootstrap initialises persistent PR-view cache"
else
	fail "6d: standalone bootstrap initialises persistent PR-view cache" \
		"exit=$cache_exit, output=$cache_output"
fi
rm -rf "$cache_test_home"

# =============================================================================
# Test 6e: standalone bootstrap clamps inherited oversized PR batches
# =============================================================================
bounded_output=""
bounded_exit=0
bounded_output=$(PULSE_MERGE_BATCH_LIMIT=310 PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX=50 \
	"$ROUTINE_FILE" help 2>&1) || bounded_exit=$?
if [[ "$bounded_exit" -eq 0 ]] && grep -qF -- 'PULSE_MERGE_BATCH_LIMIT=50' <<<"$bounded_output"; then
	pass "6e: standalone bootstrap clamps oversized PR batches"
else
	fail "6e: standalone bootstrap clamps oversized PR batches" \
		"exit=$bounded_exit, output=$bounded_output"
fi

# =============================================================================
# Test 7: runtime helpers define the escape-hatch helper (Bug 1 fix)
# =============================================================================
printf '\n=== setup.sh escape-hatch guard (Bug 1) ===\n'

if [[ ! -f "$SETUP_FILE" ]]; then
	skip "7: runtime helpers define _should_setup_noninteractive_pulse_merge_routine" \
		"setup.sh not found at $SETUP_FILE"
	skip "8: setup.sh call site uses new helper" \
		"setup.sh not found at $SETUP_FILE"
else
	if [[ -f "$RUNTIME_HELPERS_FILE" ]] && grep -qE '^_should_setup_noninteractive_pulse_merge_routine\(\)' "$RUNTIME_HELPERS_FILE"; then
		pass "7: runtime helpers define _should_setup_noninteractive_pulse_merge_routine"
	else
		fail "7: runtime helpers define _should_setup_noninteractive_pulse_merge_routine" \
			"missing function definition in $RUNTIME_HELPERS_FILE"
	fi

	# =========================================================================
	# Test 8: setup.sh call site uses the new helper (not the generic gate)
	# =========================================================================
	# The non-interactive scheduler block must call the new helper for the
	# pulse-merge-routine entry, not _should_setup_noninteractive_scheduler.
	# Pattern: an `if _should_setup_noninteractive_pulse_merge_routine; then`
	# line must be immediately followed (within 3 lines, allowing comments) by
	# either `setup_pulse_merge_routine` directly or the timed wrapper form
	# `_time_step "setup_pulse_merge_routine" setup_pulse_merge_routine`.
	# Use portable awk regex (no \b word boundary — BSD awk on macOS doesn't
	# support it).
	if awk '
		BEGIN { in_block=0; lines_since_gate=0; found_call=0 }
		/^[[:space:]]*if _should_setup_noninteractive_pulse_merge_routine[;[:space:]]/ {
			in_block=1
			lines_since_gate=0
			next
		}
		in_block {
			lines_since_gate++
			if ($0 ~ /^[[:space:]]+setup_pulse_merge_routine([[:space:]]|$)/ ||
				($0 ~ /_time_step[[:space:]]+"setup_pulse_merge_routine"/ &&
					$0 ~ /setup_pulse_merge_routine([[:space:]]|$)/)) {
				found_call=1
				exit
			}
			if (lines_since_gate > 3 || /^[[:space:]]*fi[[:space:]]*$/) {
				in_block=0
			}
		}
		END { exit (found_call) ? 0 : 1 }
	' "$SETUP_FILE"; then
		pass "8: setup.sh call site uses new helper"
	else
		fail "8: setup.sh call site uses new helper" \
			"'if _should_setup_noninteractive_pulse_merge_routine; then' not followed by 'setup_pulse_merge_routine' call"
	fi
fi

SCHEDULERS_PLATFORM_FILE="${REPO_ROOT}/.agents/scripts/setup/modules/schedulers-platform.sh"
if [[ -f "$SCHEDULERS_PLATFORM_FILE" ]]; then
	if awk '
		BEGIN { in_func=0; has_routine_script=0; has_merge_only_arg=0 }
		/^_install_pulse_merge_routine_launchd\(\)/ { in_func=1; next }
		in_func && /^\}/ { in_func=0 }
		in_func && /^[[:space:]]*<string>\$\{_xml_pmr_script\}<\/string>[[:space:]]*$/ { has_routine_script=1 }
		in_func && /^[[:space:]]*<string>--merge-only<\/string>[[:space:]]*$/ { has_merge_only_arg=1 }
		END { exit (has_routine_script && !has_merge_only_arg) ? 0 : 1 }
	' "$SCHEDULERS_PLATFORM_FILE"; then
		pass "9: scheduler uses timeout-protected pulse-merge-routine"
	else
		fail "9: scheduler uses timeout-protected pulse-merge-routine" \
			"merge LaunchAgent must run pulse-merge-routine.sh directly and must not pass --merge-only"
	fi
else
	skip "9: scheduler uses timeout-protected pulse-merge-routine" \
		".agents/scripts/setup/modules/schedulers-platform.sh not found"
fi

if [[ -f "$SCHEDULERS_PLATFORM_FILE" ]]; then
	if awk '
		BEGIN { in_func=0; has_background=0; has_low_io=0; has_nice=0; has_keepalive_false=0; saw_keepalive=0 }
		/^_install_pulse_merge_routine_launchd\(\)/ { in_func=1; next }
		in_func && /^\}/ { in_func=0 }
		in_func && index($0, "<key>ProcessType</key>") { has_background=1 }
		in_func && index($0, "<key>LowPriorityBackgroundIO</key>") { has_low_io=1 }
		in_func && index($0, "<key>Nice</key>") { has_nice=1 }
		in_func && index($0, "<key>KeepAlive</key>") { saw_keepalive=1; next }
		in_func && saw_keepalive { if (index($0, "<false/>")) has_keepalive_false=1; saw_keepalive=0 }
		END { exit (!has_background && !has_low_io && !has_nice && has_keepalive_false) ? 0 : 1 }
	' "$SCHEDULERS_PLATFORM_FILE"; then
		pass "10: merge LaunchAgent uses normal spawn priority with explicit KeepAlive=false"
	else
		fail "10: merge LaunchAgent uses normal spawn priority with explicit KeepAlive=false" \
			"pulse merge LaunchAgent must not set ProcessType/LowPriorityBackgroundIO/Nice and must set KeepAlive=false"
	fi
else
	skip "10: merge LaunchAgent uses normal spawn priority with explicit KeepAlive=false" \
		".agents/scripts/setup/modules/schedulers-platform.sh not found"
fi

printf '\n=== Argument parser regression guards ===\n'

PARSER_HARNESS=$(mktemp "${TMPDIR:-/tmp}/pmr-parser-harness-XXXXXX")
trap 'rm -f "$PARSER_HARNESS"' EXIT

cat >"$PARSER_HARNESS" <<'PARSER_HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail

RUNNER_LOG_FILE=/dev/null
PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=30

_pmr_log() { return 0; }
cmd_help() { return 0; }
cmd_dry_run() { return 0; }
cmd_run() {
	if [[ -z "${REPOS_JSON:-}" ]]; then
		return 1
	fi
	if ! grep -q '"slug":"example/repo"' "$REPOS_JSON"; then
		return 1
	fi
	if [[ -n "${EXPECT_PR:-}" ]]; then
		[[ "${PULSE_MERGE_ROUTINE_TARGET_REPO:-}" == "example/repo" ]] || return 1
		[[ "${PULSE_MERGE_ROUTINE_TARGET_PR:-}" == "$EXPECT_PR" ]] || return 1
	else
		[[ -z "${PULSE_MERGE_ROUTINE_TARGET_PR:-}" ]] || return 1
	fi
	return 0
}

# Extract only _pmr_main so this test does not run the real merge routine.
# shellcheck disable=SC1090
source <(awk '
	/^_pmr_main\(\)/ { capture=1 }
	capture { print }
	capture && /^}/ { capture=0 }
' "$ROUTINE_FILE")

_pmr_main "$@"
PARSER_HARNESS_EOF

chmod +x "$PARSER_HARNESS"
parser_output=$(ROUTINE_FILE="$ROUTINE_FILE" bash "$PARSER_HARNESS" --repo example/repo 2>&1)
parser_rc=$?

if [[ "$parser_rc" -eq 0 ]]; then
	pass "12: leading --repo defaults to run subcommand"
else
	fail "12: leading --repo defaults to run subcommand" \
		"harness rc=${parser_rc}, output=${parser_output}"
fi

parser_output=$(EXPECT_PR=42 ROUTINE_FILE="$ROUTINE_FILE" bash "$PARSER_HARNESS" --repo example/repo --pr 42 2>&1)
parser_rc=$?

if [[ "$parser_rc" -eq 0 ]]; then
	pass "13: --pr configures an exact target"
else
	fail "13: --pr configures an exact target" \
		"harness rc=${parser_rc}, output=${parser_output}"
fi

parser_output=$(ROUTINE_FILE="$ROUTINE_FILE" bash "$PARSER_HARNESS" --pr 42 2>&1)
parser_rc=$?

if [[ "$parser_rc" -eq 2 && "$parser_output" == *"Option --pr requires --repo."* ]]; then
	pass "14: --pr rejects a missing --repo"
else
	fail "14: --pr rejects a missing --repo" \
		"harness rc=${parser_rc}, output=${parser_output}"
fi

if awk '
	/if \[\[ "\$\{DRY_RUN:-0\}" == "1" \]\]/ { dry_guard=NR }
	/_attempt_pr_ci_rebase_retry/ && dry_guard > 0 && dry_guard < NR { rebase_guarded=1 }
	/_route_pr_to_fix_worker .*"ci"/ && dry_guard > 0 && dry_guard < NR { route_guarded=1 }
	END { exit (rebase_guarded && route_guarded) ? 0 : 1 }
' "${REPO_ROOT}/.agents/scripts/pulse-merge.sh"; then
	pass "15: dry-run stops before CI repair writes"
else
	fail "15: dry-run stops before CI repair writes" \
		"DRY_RUN must return before CI update-branch and repair dispatch calls"
fi

SCOPE_HARNESS=$(mktemp "${TMPDIR:-/tmp}/pmr-scope-harness-XXXXXX")
trap 'rm -f "$PARSER_HARNESS" "$SCOPE_HARNESS"' EXIT

cat >"$SCOPE_HARNESS" <<'SCOPE_HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail

PULSE_MERGE_ROUTINE_TARGET_REPO="example/repo"
PULSE_MERGE_ROUTINE_TARGET_PR="42"
_pmr_log() { return 0; }
merge_ready_prs_all_repos() {
	printf 'all-prs\n'
	return 0
}
process_pr() {
	local repo_slug="$1"
	local pr_number="$2"
	printf 'target:%s:%s\n' "$repo_slug" "$pr_number"
	return 1
}

# shellcheck disable=SC1090
source <(awk '
	/^_pmr_run_merge_scope\(\)/ { capture=1 }
	capture { print }
	capture && /^}/ { capture=0 }
' "$ROUTINE_FILE")

_pmr_run_merge_scope
SCOPE_HARNESS_EOF

scope_output=$(ROUTINE_FILE="$ROUTINE_FILE" bash "$SCOPE_HARNESS" 2>&1)
scope_rc=$?

if [[ "$scope_rc" -eq 0 && "$scope_output" == "target:example/repo:42" ]]; then
	pass "16: exact spot-check bypasses the all-PR merge pass"
else
	fail "16: exact spot-check bypasses the all-PR merge pass" \
		"harness rc=${scope_rc}, output=${scope_output}"
fi

printf '\n=== API budget isolation regression guard ===\n'

BUDGET_HARNESS=$(mktemp "${TMPDIR:-/tmp}/pmr-budget-harness-XXXXXX")
trap 'rm -f "$PARSER_HARNESS" "$SCOPE_HARNESS" "$BUDGET_HARNESS"' EXIT

cat >"$BUDGET_HARNESS" <<'BUDGET_HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail

gh() {
	if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
		printf '700\n'
		return 0
	fi
	return 22
}

# Extract the production read wrapper and budget probe without executing the
# routine entry point. The mock accepts only the zero-cost REST budget probe.
# shellcheck disable=SC1090
source <(awk '
	/^_pmr_gh_read\(\)/ { capture=1 }
	capture { print }
	capture && /^}/ { closures++; if (closures == 2) exit }
' "$ROUTINE_FILE")

unset AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING
[[ "$(_pmr_graphql_remaining)" == "700" ]]
BUDGET_HARNESS_EOF

chmod +x "$BUDGET_HARNESS"
budget_output=$(ROUTINE_FILE="$ROUTINE_FILE" bash "$BUDGET_HARNESS" 2>&1)
budget_rc=$?

if [[ "$budget_rc" -eq 0 ]]; then
	pass "17: GraphQL budget probe uses the zero-cost REST rate resource"
else
	fail "17: GraphQL budget probe uses the zero-cost REST rate resource" \
		"harness rc=${budget_rc}, output=${budget_output}"
fi

if grep -q 'pulse_rest_core_priority_allows_next progress "merge_routine_start"' "$ROUTINE_FILE"; then
	pass "17b: merge routine uses REST progress priority instead of the optional-work reserve"
else
	fail "17b: merge routine uses REST progress priority instead of the optional-work reserve"
fi

if grep -qF 'Known REST-core progress launch floor reached' "$ROUTINE_FILE" &&
	grep -qF 'REST-core quota evidence unavailable' "$ROUTINE_FILE"; then
	pass "17c: merge routine distinguishes known REST floor from unavailable evidence"
else
	fail "17c: merge routine distinguishes known REST floor from unavailable evidence"
fi

printf '\n=== Standalone post-merge provider regression guards ===\n'

SOURCE_CHAIN_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/pmr-source-chain-home-XXXXXX")
SOURCE_CHAIN_HARNESS=$(mktemp "${TMPDIR:-/tmp}/pmr-source-chain-harness-XXXXXX")
trap 'rm -f "$PARSER_HARNESS" "$SCOPE_HARNESS" "$BUDGET_HARNESS" "$SOURCE_CHAIN_HARNESS"; rm -rf "$SOURCE_CHAIN_TEST_HOME"' EXIT

cat >"$SOURCE_CHAIN_HARNESS" <<'SOURCE_CHAIN_HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail

HOME="${SOURCE_CHAIN_TEST_HOME:?}"
LOGFILE=/dev/null
AIDEVOPS_MERGE_STUCK_AGE_MINUTES=1
export HOME LOGFILE AIDEVOPS_MERGE_STUCK_AGE_MINUTES

# Extract the production standalone source block while pinning SCRIPT_DIR to
# the repository scripts directory. This exercises the exact ordered chain
# without invoking the routine entry point or contacting GitHub.
# shellcheck disable=SC1090
source <(awk '
	BEGIN { print "SCRIPT_DIR=\"${ROUTINE_TEST_SCRIPTS_DIR}\"" }
	/^# Source pulse libraries$/ { capture=1; next }
	capture && /^# Env-var defaults/ { exit }
	capture { print }
' "$ROUTINE_FILE")

declare -F reconcile_dependants_after_verified_closure >/dev/null 2>&1 || exit 21
declare -F _gh_idempotent_comment >/dev/null 2>&1 || exit 22

_pm_build_closing_comment() {
	printf 'mock closeout'
	return 0
}
_pm_upsert_pr_closing_comment() {
	return 0
}
unlock_issue_after_worker() {
	return 0
}
_pm_issue_api() {
	local repo_slug="${1:-}"
	local issue_number="${2:-}"
	printf 'repos/%s/issues/%s' "$repo_slug" "$issue_number"
	return 0
}
gh() {
	local command="${1:-}"
	if [[ "$command" == "api" ]]; then
		printf '[]\n'
		return 0
	fi
	return 1
}
gh_issue_comment() {
	return 0
}
set_solved_label() {
	return 0
}
clear_terminal_issue_dispatch_labels() {
	return 0
}
_gh_with_timeout() {
	return 0
}
reconcile_dependants_after_verified_closure() {
	local repo_slug="${1:-}"
	local issue_number="${2:-}"
	printf 'reconciled:%s:%s\n' "$repo_slug" "$issue_number"
	return 0
}
fast_fail_reset() {
	return 0
}
_pm_resolve_superseded_original_issue() {
	return 1
}
_pm_handle_partial_parent_closeout() {
	return 0
}
_release_interactive_claim_on_merge() {
	return 0
}
auto_file_next_phase() {
	return 0
}
_unblock_circuit_breaker_meta_pr() {
	return 0
}
invalidate_footprint_cache_for_issue() {
	return 0
}

_handle_post_merge_actions 42 owner/repo 77 summary origin:worker main

gh_pr_view() {
	printf 'mock-head-sha\n'
	return 0
}
_pms_check_runs_for_head() {
	printf '{"check_runs":[]}\n'
	return 0
}
_pms_failing_check_bullets() {
	printf '%s\n' '- mocked failing check'
	return 0
}
_gh_idempotent_comment() {
	local entity_number="${1:-}"
	local repo_slug="${2:-}"
	local marker="${3:-}"
	local comment_body="${4:-}"
	local entity_type="${5:-issue}"
	: "$marker" "$comment_body"
	printf 'idempotent:%s:%s:%s\n' "$entity_number" "$repo_slug" "$entity_type"
	return 0
}
pulse_stats_increment() {
	return 0
}

_escalate_individual_stuck_pr 43 owner/repo STUCK_CHECKS_FAILING 77
SOURCE_CHAIN_HARNESS_EOF

chmod +x "$SOURCE_CHAIN_HARNESS"
source_chain_output=$(ROUTINE_FILE="$ROUTINE_FILE" \
	ROUTINE_TEST_SCRIPTS_DIR="$SCRIPTS_DIR" \
	SOURCE_CHAIN_TEST_HOME="$SOURCE_CHAIN_TEST_HOME" \
	bash "$SOURCE_CHAIN_HARNESS" 2>&1)
source_chain_rc=$?

if [[ "$source_chain_rc" -eq 0 && "$source_chain_output" == *"reconciled:owner/repo:77"* ]]; then
	pass "18: linked-issue close invokes standalone dependency reconciliation"
else
	fail "18: linked-issue close invokes standalone dependency reconciliation" \
		"harness rc=${source_chain_rc}, output=${source_chain_output}"
fi

if [[ "$source_chain_rc" -eq 0 && "$source_chain_output" == *"idempotent:77:owner/repo:issue"* ]]; then
	pass "19: stuck escalation invokes standalone idempotent comment provider"
else
	fail "19: stuck escalation invokes standalone idempotent comment provider" \
		"harness rc=${source_chain_rc}, output=${source_chain_output}"
fi

if [[ "$source_chain_rc" -eq 0 && "$source_chain_output" != *"command not found"* && "$source_chain_output" != *"not defined"* ]]; then
	pass "20: post-merge providers run without missing-function diagnostics"
else
	fail "20: post-merge providers run without missing-function diagnostics" \
		"harness rc=${source_chain_rc}, output=${source_chain_output}"
fi

# =============================================================================
# Tests 24-28: routines run while another process holds the instance lock
# =============================================================================
# GH#35349: a long refill-only drain or full cycle held the Pulse instance lock
# and every scheduler tick skipped, so routines (evaluated only at full-cycle
# start) missed calendar slots. Busy ticks now run a routines-only pass under
# routines.lockdir. This harness holds the instance lock with a live process,
# runs the production refill busy hook and wrapper busy pass, and checks that a
# due script routine starts exactly once.
printf '\n=== Routines while the instance lock is held (GH#35349) ===\n'

WRAPPER_FILE="${SCRIPTS_DIR}/pulse-wrapper.sh"
BUSY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pmr-busy-routines-XXXXXX")
BUSY_HARNESS="${BUSY_ROOT}/harness.sh"
trap 'rm -f "$PARSER_HARNESS" "$SCOPE_HARNESS" "$BUDGET_HARNESS" "$SOURCE_CHAIN_HARNESS"; rm -rf "$SOURCE_CHAIN_TEST_HOME" "$BUSY_ROOT"' EXIT

cat >"$BUSY_HARNESS" <<'BUSY_HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail

root="${BUSY_ROOT:?}"
export HOME="${root}/home"
fake_scripts="${HOME}/.aidevops/agents/scripts"
repo_dir="${root}/routines-repo"
mkdir -p "$fake_scripts" "$repo_dir" "${HOME}/.aidevops/logs"
cat >"${fake_scripts}/queue-refill.sh" <<'ROUTINE_SCRIPT'
#!/usr/bin/env bash
printf 'run\n' >>"${BUSY_RUN_LOG:?}"
sleep 1
exit 0
ROUTINE_SCRIPT
cat >"${root}/always-due.sh" <<'SCHEDULE_SCRIPT'
#!/usr/bin/env bash
[[ "${1:-}" == "is-due" ]] || exit 2
exit 0
SCHEDULE_SCRIPT
chmod +x "${fake_scripts}/queue-refill.sh" "${root}/always-due.sh"
printf '# Tasks\n\n## Routines\n\n%s\n\n## Ready\n' \
	'- [x] r-queue-refill Queue refill repeat:cron(15,45 * * * *) ~1m run:scripts/queue-refill.sh' \
	>"${repo_dir}/TODO.md"
printf '{"initialized_repos":[{"slug":"example/routines","path":"%s","pulse":true,"local_only":true}]}\n' \
	"$repo_dir" >"${root}/repos.json"

export BUSY_RUN_LOG="${root}/runs.log"
SCRIPT_DIR="${ROUTINE_TEST_SCRIPTS_DIR:?}"
ROUTINE_SCHEDULE_HELPER="${root}/always-due.sh"
ROUTINE_STATE_FILE="${root}/routine-state.json"
ROUTINE_LOG_HELPER="${root}/missing-routine-log-helper.sh"
HEADLESS_RUNTIME_HELPER="${root}/missing-headless-helper.sh"
REPOS_JSON="${root}/repos.json"
LOGFILE="${root}/pulse.log"
WRAPPER_LOGFILE="${root}/pulse-wrapper.log"
STOP_FLAG="${root}/stop"
PRE_RUN_STAGE_TIMEOUT=60
PULSE_DIR="$root"
LOCKDIR="${root}/pulse-wrapper.lockdir"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/pulse-routines.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/pulse-event-refill.sh"
# Extract the production busy pass without bootstrapping the whole wrapper.
# shellcheck disable=SC1090
source <(awk '
	/^_pulse_run_routines_while_busy\(\)/ { capture=1 }
	capture { print }
	capture && /^}/ { exit }
' "${WRAPPER_FILE:?}")
check_session_gate() { return 0; }
# Supply quota evidence for this scheduler harness: production fails closed
# when neither REST quota checker is available. Budget decisions are covered
# by the selector and pulse-budget-priority suites, not by live API calls here.
pulse_rest_core_priority_allows_next() { return 0; }
# The stage gate itself is covered by pulse-budget-priority tests; record the
# stage name so the harness proves the busy pass goes through it.
_pulse_run_budget_priority_stage_with_timeout() {
	local stage_name="$1"
	printf 'stage:%s\n' "$stage_name" >>"${root}/stages.log"
	shift 2
	"$@"
	return $?
}

wait_for_success() {
	local attempt=0
	while [[ "$attempt" -lt 100 ]]; do
		if jq -e '."r-queue-refill".last_status == "success"' "$ROUTINE_STATE_FILE" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

# A live long-running process holds the Pulse instance lock.
sleep 300 &
holder_pid=$!
mkdir -p "$LOCKDIR"
printf '%s\n' "$holder_pid" >"${LOCKDIR}/pid"

# A worker-exit refill wake evaluates routines before waiting for the lock;
# a second busy scheduler tick in the same slot must not start it again.
_pulse_event_refill_run_routines_if_busy worker-exit
_pulse_run_routines_while_busy lock-busy
wait_for_success || printf 'routine did not finish\n'
grep -q 'routine r-queue-refill is due' "$LOGFILE" && printf 'due-logged\n'
grep -q 'routine r-queue-refill: dispatching script' "$LOGFILE" && printf 'dispatch-logged\n'
grep -q 'Routines-only pass: instance lock busy (refill-only:worker-exit)' "$WRAPPER_LOGFILE" && printf 'refill-pass-logged\n'
grep -q '^stage:evaluate_routines$' "${root}/stages.log" && printf 'budget-gated\n'
printf 'runs=%s\n' "$(grep -c '^run$' "$BUSY_RUN_LOG" 2>/dev/null || printf 0)"

# A live evaluator holding routines.lockdir makes a concurrent pass skip.
mkdir -p "${root}/routines.lockdir"
: >"${root}/routines.lockdir/pid-${holder_pid}"
before=$(grep -c 'is due' "$LOGFILE")
_pulse_run_routines_while_busy rate-limited
after=$(grep -c 'is due' "$LOGFILE")
[[ "$before" == "$after" ]] && grep -q 'another evaluator holds routines.lockdir' "$LOGFILE" &&
	printf 'concurrent-skip\n'
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
exit 0
BUSY_HARNESS_EOF

busy_output=$(BUSY_ROOT="$BUSY_ROOT" ROUTINE_TEST_SCRIPTS_DIR="$SCRIPTS_DIR" \
	WRAPPER_FILE="$WRAPPER_FILE" timeout 120 bash "$BUSY_HARNESS" 2>&1)
busy_rc=$?

if [[ "$busy_rc" -eq 0 && "$busy_output" == *"due-logged"* && "$busy_output" == *"dispatch-logged"* && "$busy_output" == *"refill-pass-logged"* ]]; then
	pass "24: due script routine starts while another process holds the instance lock"
else
	fail "24: due script routine starts while another process holds the instance lock" \
		"harness rc=${busy_rc}, output=${busy_output}"
fi

if [[ "$busy_output" == *"runs=1"* ]]; then
	pass "25: overlapping busy passes start the routine once per slot"
else
	fail "25: overlapping busy passes start the routine once per slot" "output=${busy_output}"
fi

if [[ "$busy_output" == *"budget-gated"* ]]; then
	pass "26: busy routines pass keeps the REST budget stage gate"
else
	fail "26: busy routines pass keeps the REST budget stage gate" "output=${busy_output}"
fi

if [[ "$busy_output" == *"concurrent-skip"* ]]; then
	pass "27: a live routines.lockdir holder makes a concurrent evaluator skip"
else
	fail "27: a live routines.lockdir holder makes a concurrent evaluator skip" "output=${busy_output}"
fi

# Every path that skips a full cycle for a live lock holder runs the pass.
busy_hooks=0
for busy_context in bootstrap is-running rate-limited lock-busy; do
	grep -qF "_pulse_run_routines_while_busy \"${busy_context}\"" "$WRAPPER_FILE" && busy_hooks=$((busy_hooks + 1))
done
if [[ "$busy_hooks" -eq 4 ]] && grep -qF 'evaluate_routines_locked || true' "$WRAPPER_FILE"; then
	pass "28: wrapper busy-skip paths run routines and the in-cycle backstop shares the lock"
else
	fail "28: wrapper busy-skip paths run routines and the in-cycle backstop shares the lock" \
		"busy hooks found=${busy_hooks}/4"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
