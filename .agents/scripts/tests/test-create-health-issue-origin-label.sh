#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-create-health-issue-origin-label.sh — t2691 / GH#20311 regression guard.
#
# Root cause (discovered 2026-04-21):
#   Health dashboard issues created by secondary pulse runners (collaborators
#   like alex-solovyev) had origin:worker STRIPPED by maintainer-gate.yml Job 5.
#   Timeline for issue #20298:
#     13:17:55Z  alex-solovyev: labeled supervisor, alex-solovyev, persistent,
#                               source:health-dashboard  (issue creation)
#     13:17:56Z  alex-solovyev: labeled origin:worker    (correct — separate call)
#     13:18:03Z  github-actions[bot]: unlabeled origin:worker  (STRIPPED by Job 5)
#     17:38:36Z  marcusquinn: labeled origin:worker       (backfilled by t2687)
#
#   Job 5 allowlist only covered github-actions[bot] and the repo owner.
#   Collaborator runners were in the DENIED path.
#
# Fix (t2691):
#   1. maintainer-gate.yml Job 5: extended allowlist to check the actor's
#      repository permission level via
#      /repos/{owner}/{repo}/collaborators/{username}/permission.
#      Actors with write/admin/maintain permission are allowed.
#   2. stats-health-dashboard.sh _create_health_issue: explicitly exports
#      AIDEVOPS_SESSION_ORIGIN=worker before calling gh_create_issue
#      (defense-in-depth; restores the saved value after the call).
#
# H1 verdict (from issue body):
#   H1 (REST fallback omits origin label) was investigated and FALSIFIED.
#   _gh_issue_create_rest correctly includes all labels inline in the POST.
#   The root cause was server-side label removal, not client-side omission.
#
# Tests:
#   1. _create_health_issue calls gh_create_issue with origin:worker (via
#      AIDEVOPS_SESSION_ORIGIN=worker override)
#   2. _create_health_issue restores AIDEVOPS_SESSION_ORIGIN after the call
#   3. _create_health_issue restores unset AIDEVOPS_SESSION_ORIGIN correctly
#   4. When AIDEVOPS_HEADLESS is set, origin:worker is also auto-applied
#   5. When neither AIDEVOPS_HEADLESS nor AIDEVOPS_SESSION_ORIGIN is set,
#      the explicit AIDEVOPS_SESSION_ORIGIN=worker guard still applies
#      origin:worker (not origin:interactive — the pre-fix bug pattern)
#   6. The REST fallback path (_gh_issue_create_rest) includes origin:worker
#      in the REST POST payload

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2691.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_SIGNATURE_CALLED="${TMP}/sig_called.log"

# Override print_* before sourcing to avoid color codes in test output
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
# shellcheck disable=SC2317
print_warning() { return 0; }
# shellcheck disable=SC2317
print_error() { return 0; }
# shellcheck disable=SC2317
print_success() { return 0; }
# shellcheck disable=SC2317
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

# Start without any session origin env vars
unset AIDEVOPS_SESSION_ORIGIN 2>/dev/null || true
unset AIDEVOPS_HEADLESS 2>/dev/null || true
unset FULL_LOOP_HEADLESS 2>/dev/null || true
unset OPENCODE_HEADLESS 2>/dev/null || true
unset GITHUB_ACTIONS 2>/dev/null || true

# Configurable stub behaviour per test via env vars:
#   STUB_PRIMARY_FAIL       — 1 to make gh issue create fail
#   STUB_RATE_LIMIT_REMAINING — what gh api rate_limit returns (default 5000)
# =============================================================================

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_* AFTER sourcing
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
export -f print_info

# Stub gh — captures calls, simulates success/failure
# shellcheck disable=SC2317
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	# gh api rate_limit
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		printf '%s\n' "${STUB_RATE_LIMIT_REMAINING:-5000}"
		return 0
	fi
	# gh api user
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf '"testuser"\n'
		return 0
	fi
	# gh api /repos/.../issues/N (state fetch for label delta)
	if [[ "$1" == "api" && "$2" =~ ^/repos/.+/issues/[0-9]+$ ]]; then
		printf '%s\n' "${STUB_CURRENT_LABELS:-bug}"
		return 0
	fi
	# gh api -X POST|PATCH — REST calls
	if [[ "$1" == "api" && ("$2" == "-X" || "$2" =~ ^-X) ]]; then
		if [[ "${STUB_REST_FAIL:-0}" == "1" ]]; then
			printf 'REST stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi
	# gh issue create
	if [[ "$1" == "issue" && "$2" == "create" ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9000\n'
		return 0
	fi
	# gh label create / gh pr ready / other
	return 0
}
export -f gh

# Stub gh-signature-helper.sh footer — no-op so we don't need real binary
# shellcheck disable=SC2317
_gh_sig_stub() {
	printf '' >"${GH_SIGNATURE_CALLED}"
	return 0
}

# Source the REST fallback module (required by shared-gh-wrappers.sh)
source "${SCRIPTS_DIR}/shared-gh-wrappers-rest-fallback.sh" >/dev/null 2>&1 || true
# Source the main wrappers
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh" >/dev/null 2>&1 || true

# Stub gh-signature-helper.sh so _create_health_issue doesn't fail
# The function uses "${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh"
# We create a stub at the expected path override.
export HOME="${TMP}/fakehome"
mkdir -p "${HOME}/.aidevops/agents/scripts"
cat >"${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" <<'SIGSTUB'
#!/usr/bin/env bash
# Stub gh-signature-helper.sh for test isolation
printf ''
SIGSTUB
chmod +x "${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh"

# Stub LOGFILE
export LOGFILE="${TMP}/test.log"
touch "$LOGFILE"

# Source stats-health-dashboard.sh (it sources stats-shared.sh for
# _get_runner_role — stub that too)
# shellcheck disable=SC2317
_get_runner_role() {
	echo "supervisor"
	return 0
}
# shellcheck disable=SC2317
_validate_repo_slug() {
	return 0
}
export -f _get_runner_role _validate_repo_slug

# Source the module under test
source "${SCRIPTS_DIR}/stats-health-dashboard.sh" >/dev/null 2>&1 || true

printf '%sRunning health-issue origin label tests (t2691 / GH#20311)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: _create_health_issue passes origin:worker via AIDEVOPS_SESSION_ORIGIN
#         override even when neither AIDEVOPS_HEADLESS nor SESSION_ORIGIN is set.
#         Pre-fix, this would default to origin:interactive (the bug).
# =============================================================================
: >"$GH_CALLS"
unset AIDEVOPS_SESSION_ORIGIN 2>/dev/null || true
unset AIDEVOPS_HEADLESS 2>/dev/null || true

_create_health_issue \
	"owner/repo" "testrunner" "supervisor" "[Supervisor:testrunner]" \
	"supervisor" "0E8A16" "Supervisor runner" "Supervisor" >/dev/null 2>&1 || true

if grep -qE '\-\-label origin:worker' "$GH_CALLS" 2>/dev/null; then
	pass "_create_health_issue passes origin:worker even without AIDEVOPS_HEADLESS"
else
	fail "_create_health_issue passes origin:worker even without AIDEVOPS_HEADLESS" \
		"Expected --label origin:worker in calls: $(grep 'label' "$GH_CALLS" | head -5)"
fi

# Verify origin:interactive was NOT passed to issue create (label create
# calls for ensure_origin_labels_exist are expected and benign — they
# just create the label on the repo, they don't apply it to the issue)
if grep -E '^issue create' "$GH_CALLS" 2>/dev/null | grep -q "origin:interactive"; then
	fail "_create_health_issue must NOT pass origin:interactive to issue create" \
		"Found origin:interactive in issue create: $(grep '^issue create' "$GH_CALLS" | head -3)"
else
	pass "_create_health_issue does NOT pass origin:interactive to issue create"
fi

# =============================================================================
# Test 2: _create_health_issue restores AIDEVOPS_SESSION_ORIGIN after the call
#         (should leave it unset when it was unset before the call)
# =============================================================================
unset AIDEVOPS_SESSION_ORIGIN 2>/dev/null || true
: >"$GH_CALLS"

_create_health_issue \
	"owner/repo" "testrunner" "supervisor" "[Supervisor:testrunner]" \
	"supervisor" "0E8A16" "Supervisor runner" "Supervisor" >/dev/null 2>&1 || true

if [[ -z "${AIDEVOPS_SESSION_ORIGIN:-}" ]]; then
	pass "_create_health_issue restores unset AIDEVOPS_SESSION_ORIGIN after call"
else
	fail "_create_health_issue restores unset AIDEVOPS_SESSION_ORIGIN after call" \
		"AIDEVOPS_SESSION_ORIGIN is now '${AIDEVOPS_SESSION_ORIGIN:-}' (should be unset)"
fi

# =============================================================================
# Test 3: _create_health_issue restores a pre-existing AIDEVOPS_SESSION_ORIGIN
# =============================================================================
export AIDEVOPS_SESSION_ORIGIN="interactive"
: >"$GH_CALLS"

_create_health_issue \
	"owner/repo" "testrunner" "supervisor" "[Supervisor:testrunner]" \
	"supervisor" "0E8A16" "Supervisor runner" "Supervisor" >/dev/null 2>&1 || true

if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "interactive" ]]; then
	pass "_create_health_issue restores pre-existing AIDEVOPS_SESSION_ORIGIN=interactive"
else
	fail "_create_health_issue restores pre-existing AIDEVOPS_SESSION_ORIGIN=interactive" \
		"AIDEVOPS_SESSION_ORIGIN is now '${AIDEVOPS_SESSION_ORIGIN:-}' (expected 'interactive')"
fi
unset AIDEVOPS_SESSION_ORIGIN

# =============================================================================
# Test 4: origin:worker is still passed when AIDEVOPS_HEADLESS=true
#         (the production path — stats-wrapper.sh sets this)
# =============================================================================
export AIDEVOPS_HEADLESS=true
: >"$GH_CALLS"

_create_health_issue \
	"owner/repo" "testrunner" "supervisor" "[Supervisor:testrunner]" \
	"supervisor" "0E8A16" "Supervisor runner" "Supervisor" >/dev/null 2>&1 || true

if grep -qE '\-\-label origin:worker' "$GH_CALLS" 2>/dev/null; then
	pass "_create_health_issue passes origin:worker with AIDEVOPS_HEADLESS=true"
else
	fail "_create_health_issue passes origin:worker with AIDEVOPS_HEADLESS=true" \
		"Expected --label origin:worker; calls: $(grep 'label' "$GH_CALLS" | head -5)"
fi
unset AIDEVOPS_HEADLESS

# =============================================================================
# Test 5: REST fallback path also includes origin:worker inline in POST
#         (confirms H1 from issue body is FALSIFIED — REST does include the label)
# =============================================================================
: >"$GH_CALLS"
_gh_issue_create_rest \
	--repo "owner/repo" \
	--title "test health issue" \
	--body "body text" \
	--label "supervisor" \
	--label "testrunner" \
	--label "source:health-dashboard" \
	--label "persistent" \
	--label "origin:worker" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=origin:worker' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=source:health-dashboard' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_create_rest includes origin:worker inline in POST (H1 falsified)"
else
	fail "_gh_issue_create_rest includes origin:worker inline in POST (H1 falsified)" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 6: REST fallback path does NOT use a separate label POST for issues
#         (unlike _gh_pr_create_rest which DOES use a separate step)
# =============================================================================
: >"$GH_CALLS"
_gh_issue_create_rest \
	--repo "owner/repo" \
	--title "test health issue" \
	--body "body" \
	--label "origin:worker" >/dev/null 2>&1 || true

# For issues, there should be exactly ONE POST call (the issue creation).
# A separate /labels POST would indicate the two-step pattern (PR pattern).
# Use grep exit code (0=match found, 1=not found) to avoid grep -c doubling.
if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/[0-9]+/labels' "$GH_CALLS" 2>/dev/null; then
	fail "_gh_issue_create_rest uses inline labels (no separate /labels POST)" \
		"Found separate /issues/{N}/labels POST call (expected none)"
else
	pass "_gh_issue_create_rest uses inline labels (no separate /labels POST)"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
