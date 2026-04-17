#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-script-drift-detection.sh — t2156 regression guard.
#
# Tests the _check_script_drift function in aidevops-update-check.sh:
#
#   1. No-op when stamp file is absent (first-time install, no stamp yet).
#   2. No-op when deployed SHA matches canonical repo HEAD (in-sync).
#   3. No-op when drift is docs-only (reference/*.md).
#   4. Triggers redeploy message when framework code files drift
#      (.agents/scripts/, .agents/agents/, .agents/workflows/,
#       .agents/prompts/, .agents/hooks/).
#   5. setup.sh is actually invoked by the background redeploy.
#   6. No-op when framework repo directory does not exist.
#   7. Emits manual-run hint when setup.sh is not executable.
#
# Production failure (GH#19432–19443 blast radius):
#   3bbe31f36 merged at 00:09Z fixing stale-recovery (t2153). The production
#   pulse kept using the old in-memory code for 90+ minutes because aidevops
#   update only redeploys on VERSION change, not on local commits between
#   releases. Manual workaround: cp + pulse restart at 01:32 BST.
#
# Fix (t2156): setup.sh now writes ~/.aidevops/.deployed-sha after every
# successful deploy. aidevops-update-check.sh (running every ~10 min) detects
# SHA drift and triggers a background silent redeploy if framework code changed.
#
# Implementation: .agents/scripts/aidevops-update-check.sh (_check_script_drift)
#                 setup-modules/agent-deploy.sh (deploy_aidevops_agents stamp write)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_CHECK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/aidevops-update-check.sh"

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

# ---------------------------------------------------------------------------
# Sandbox: isolated HOME + fake git repo
# ---------------------------------------------------------------------------
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

SANDBOX_HOME="${TEST_ROOT}/home"
SANDBOX_REPO="${TEST_ROOT}/aidevops"
SANDBOX_AIDEVOPS="${SANDBOX_HOME}/.aidevops"
SETUP_CALLS_LOG="${TEST_ROOT}/setup_calls.log"

mkdir -p "$SANDBOX_HOME" "$SANDBOX_AIDEVOPS"

# Build a minimal fake framework git repo with three commits.
git init -q "$SANDBOX_REPO" 2>/dev/null
git -C "$SANDBOX_REPO" config user.email "test@test.local"
git -C "$SANDBOX_REPO" config user.name "Test"
# Disable commit signing — global gpg.format=ssh would require passphrase
git -C "$SANDBOX_REPO" config commit.gpgsign false

# Commit 1 — baseline (will serve as "deployed" SHA in drift tests)
mkdir -p "$SANDBOX_REPO/.agents/scripts"
printf '#!/usr/bin/env bash\necho v1\n' >"$SANDBOX_REPO/.agents/scripts/foo.sh"
git -C "$SANDBOX_REPO" add -A
git -C "$SANDBOX_REPO" commit -qm "initial" 2>/dev/null
DEPLOYED_SHA=$(git -C "$SANDBOX_REPO" rev-parse HEAD)

# Commit 2 — adds a script change (code drift)
printf '#!/usr/bin/env bash\necho v2\n' >"$SANDBOX_REPO/.agents/scripts/foo.sh"
git -C "$SANDBOX_REPO" add -A
git -C "$SANDBOX_REPO" commit -qm "update script" 2>/dev/null
SCRIPT_DRIFT_SHA=$(git -C "$SANDBOX_REPO" rev-parse HEAD)

# Commit 3 — docs-only change on top of commit 2
mkdir -p "$SANDBOX_REPO/.agents/reference"
printf '# doc\n' >"$SANDBOX_REPO/.agents/reference/readme.md"
git -C "$SANDBOX_REPO" add -A
git -C "$SANDBOX_REPO" commit -qm "update docs" 2>/dev/null
HEAD_SHA=$(git -C "$SANDBOX_REPO" rev-parse HEAD)

# Fail fast if git setup failed
if [[ -z "$DEPLOYED_SHA" ]] || [[ -z "$SCRIPT_DRIFT_SHA" ]] || [[ -z "$HEAD_SHA" ]]; then
	printf '%sSETUP FAILED%s Could not create sandbox git repo (empty SHAs: deployed=%s script=%s head=%s)\n' \
		"$TEST_RED" "$TEST_RESET" "$DEPLOYED_SHA" "$SCRIPT_DRIFT_SHA" "$HEAD_SHA"
	exit 1
fi

# Create a fake setup.sh that records calls
FAKE_SETUP="${SANDBOX_REPO}/setup.sh"
printf '#!/usr/bin/env bash\nprintf "called\n" >> "%s"\n' "$SETUP_CALLS_LOG" >"$FAKE_SETUP"
chmod +x "$FAKE_SETUP"

# ---------------------------------------------------------------------------
# call_drift_check: invoke _check_script_drift in isolation.
#   $1 — stamp SHA to write (or "" to omit/remove stamp file)
#   $2 — AIDEVOPS_FRAMEWORK_REPO override (default: $SANDBOX_REPO)
# Prints the function's stdout.
# ---------------------------------------------------------------------------
call_drift_check() {
	local stamp="${1:-}"
	local repo="${2:-$SANDBOX_REPO}"

	# Write or remove the stamp file
	if [[ -n "$stamp" ]]; then
		printf '%s\n' "$stamp" >"${SANDBOX_AIDEVOPS}/.deployed-sha"
	else
		rm -f "${SANDBOX_AIDEVOPS}/.deployed-sha"
	fi

	# Source just _check_script_drift from the update-check script, then call it.
	# set +e inside the subshell to avoid the outer set -e from propagating.
	HOME="$SANDBOX_HOME" AIDEVOPS_FRAMEWORK_REPO="$repo" bash -c "
		set +e
		# Extract and define only _check_script_drift to avoid side effects
		# from the full script (set -euo pipefail, main, etc.)
		$(sed -n '/_check_script_drift()/,/^}/p' "$UPDATE_CHECK_SCRIPT")
		_check_script_drift
	" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: no-op when stamp file is absent
# ---------------------------------------------------------------------------
result=$(call_drift_check "")
if [[ -z "$result" ]]; then
	print_result "no-op when stamp file absent" 0
else
	print_result "no-op when stamp file absent" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Test 2: no-op when deployed SHA == HEAD (in-sync)
# ---------------------------------------------------------------------------
result=$(call_drift_check "$HEAD_SHA")
if [[ -z "$result" ]]; then
	print_result "no-op when in-sync (deployed SHA == HEAD)" 0
else
	print_result "no-op when in-sync (deployed SHA == HEAD)" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Test 3: no-op when drift is docs-only
# Stamp = commit 2 (SCRIPT_DRIFT_SHA), HEAD = commit 3 (docs-only diff)
# ---------------------------------------------------------------------------
result=$(call_drift_check "$SCRIPT_DRIFT_SHA")
if [[ -z "$result" ]]; then
	print_result "no-op on docs-only drift (.agents/reference/*.md)" 0
else
	print_result "no-op on docs-only drift (.agents/reference/*.md)" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Test 4: redeploy triggered when framework code files drift
# Stamp = commit 1 (DEPLOYED_SHA), HEAD = commit 3 — diff includes .agents/scripts/
# ---------------------------------------------------------------------------
result=$(call_drift_check "$DEPLOYED_SHA")
if printf '%s' "$result" | grep -q "Script drift detected"; then
	print_result "redeploy triggered on code drift (.agents/scripts/)" 0
else
	print_result "redeploy triggered on code drift (.agents/scripts/)" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Test 5: setup.sh actually invoked by the background job
# Allow up to 3 seconds for the background job to complete.
# ---------------------------------------------------------------------------
check_setup_called=0
for _i in 1 2 3; do
	sleep 1
	if [[ -f "$SETUP_CALLS_LOG" ]] && [[ -s "$SETUP_CALLS_LOG" ]]; then
		check_setup_called=1
		break
	fi
done
if [[ "$check_setup_called" -eq 1 ]]; then
	print_result "setup.sh invoked by background redeploy" 0
else
	print_result "setup.sh invoked by background redeploy" 1 "(setup_calls.log empty or missing after 3s)"
fi

# ---------------------------------------------------------------------------
# Test 6: no-op when framework repo directory does not exist
# ---------------------------------------------------------------------------
result=$(call_drift_check "$DEPLOYED_SHA" "/nonexistent/path/aidevops")
if [[ -z "$result" ]]; then
	print_result "no-op when framework repo does not exist" 0
else
	print_result "no-op when framework repo does not exist" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Test 7: manual hint when setup.sh is not executable
# ---------------------------------------------------------------------------
NOXEC_REPO="${TEST_ROOT}/aidevops-noxec"
git init -q "$NOXEC_REPO" 2>/dev/null
git -C "$NOXEC_REPO" config user.email "test@test.local"
git -C "$NOXEC_REPO" config user.name "Test"
git -C "$NOXEC_REPO" config commit.gpgsign false
mkdir -p "$NOXEC_REPO/.agents/scripts"
printf '#!/usr/bin/env bash\necho v1\n' >"$NOXEC_REPO/.agents/scripts/bar.sh"
git -C "$NOXEC_REPO" add -A
git -C "$NOXEC_REPO" commit -qm "v1" 2>/dev/null
NOXEC_OLD_SHA=$(git -C "$NOXEC_REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\necho v2\n' >"$NOXEC_REPO/.agents/scripts/bar.sh"
git -C "$NOXEC_REPO" add -A
git -C "$NOXEC_REPO" commit -qm "v2" 2>/dev/null
# Create a non-executable setup.sh
printf '#!/usr/bin/env bash\necho setup\n' >"$NOXEC_REPO/setup.sh"
# intentionally NOT chmod +x

result=$(call_drift_check "$NOXEC_OLD_SHA" "$NOXEC_REPO")
if printf '%s' "$result" | grep -q "not executable"; then
	print_result "manual hint when setup.sh not executable" 0
else
	print_result "manual hint when setup.sh not executable" 1 "(got: '$result')"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d of %d tests FAILED.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
