#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22613: the issue-sync-reusable.yml `sync-on-pr-merge`
# job uses two checkouts — an early framework checkout into `__aidevops/`
# (for the gh PATH shim) and a later "Checkout repo for TODO.md update" that
# pulls the caller repo into the workspace root.
#
# The second checkout uses `actions/checkout@v4` without `clean: false`, which
# default-deletes the workspace contents — including the `__aidevops/`
# subdirectory created by the early checkout. Without a re-checkout step
# AFTER the second checkout, the subsequent "Update TODO.md proof-log" step
# fails with `bash: __aidevops/.agents/scripts/issue-sync-git-push-helper.sh:
# No such file or directory` on every merged PR.
#
# This test asserts that the `sync-on-pr-merge` job has either:
#   (a) a `Re-checkout aidevops framework scripts` step AFTER the
#       `Checkout repo for TODO.md update` step, OR
#   (b) `clean: false` on the `Checkout repo for TODO.md update` step.
#
# Either invariant prevents the regression. The current canonical fix is (a).

set -euo pipefail

PASS=0
FAIL=0
RESULT_PREFIX_OK="PASS"
RESULT_PREFIX_BAD="FAIL"

# --- Resolve workflow path relative to this test ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"

if [[ ! -f "${WORKFLOW_FILE}" ]]; then
	echo "${RESULT_PREFIX_BAD}: workflow file not found: ${WORKFLOW_FILE}"
	exit 1
fi

# --- Helper: extract a job's body (line range) by job key ---
# Usage: extract_job_lines <job_key>
# Prints the start and end line numbers (inclusive) of the job's YAML body.
# Job body runs from `<job_key>:` line until the next sibling job key or EOF.
extract_job_lines() {
	local job_key="$1"
	local file="${WORKFLOW_FILE}"
	local start
	start=$(awk -v k="${job_key}:" '
		/^  [a-z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
			if ($1 == k) { print NR; exit }
		}
	' "${file}")

	if [[ -z "${start}" ]]; then
		printf '0 0\n'
		return 0
	fi

	# Find the next sibling job key (2-space indent, ends in colon) after start.
	local end
	end=$(awk -v start="${start}" '
		NR > start && /^  [a-z][a-zA-Z0-9_-]*:[[:space:]]*$/ { print NR-1; exit }
		END { if (!found) print NR }
	' "${file}")

	printf '%s %s\n' "${start}" "${end}"
	return 0
}

# --- Single assertion function ---
check() {
	local ok="$1" tc="$2" detail="$3"
	if [[ "${ok}" == "1" ]]; then
		PASS=$((PASS + 1))
		echo "${RESULT_PREFIX_OK}: ${tc}"
	else
		FAIL=$((FAIL + 1))
		echo "${RESULT_PREFIX_BAD}: ${tc} — ${detail}"
	fi
	return 0
}

# ============================================================
# Test 1: sync-on-pr-merge job exists
# ============================================================
read -r JOB_START JOB_END <<<"$(extract_job_lines 'sync-on-pr-merge')"
if [[ "${JOB_START}" == "0" ]]; then
	check 0 "sync-on-pr-merge job present" "job not found in ${WORKFLOW_FILE}"
	echo ""
	echo "Summary: ${PASS} passed, ${FAIL} failed"
	exit 1
fi
check 1 "sync-on-pr-merge job present" ""

# ============================================================
# Test 2: job has merged == true guard (defends against #22607
#         which falsely claimed the guard was missing)
# ============================================================
JOB_BODY=$(sed -n "${JOB_START},${JOB_END}p" "${WORKFLOW_FILE}")
if printf '%s\n' "${JOB_BODY}" | grep -qE 'github\.event\.pull_request\.merged[[:space:]]*==[[:space:]]*true'; then
	check 1 "sync-on-pr-merge has merged == true guard" ""
else
	check 0 "sync-on-pr-merge has merged == true guard" "job-level if guard missing — premature completion-marking risk on non-merge events"
fi

# ============================================================
# Test 3: job preserves __aidevops/ across the second checkout.
#         Either via Option A (clean: false on caller checkout)
#         or Option B (re-checkout framework after caller checkout).
#         At least ONE must hold.
# ============================================================
# Find the line of "Checkout repo for TODO.md update" within the job body.
CALLER_CHECKOUT_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Checkout repo for TODO\.md update' | head -1 | cut -d: -f1 || true)

if [[ -z "${CALLER_CHECKOUT_REL_LINE}" ]]; then
	check 0 "Checkout repo for TODO.md update step present" "step missing — proof-log cannot run"
else
	check 1 "Checkout repo for TODO.md update step present" ""

	# Option A: 'clean: false' present in the caller checkout step.
	# Look in a 30-line window after the step name.
	OPTION_A_OK=0
	if printf '%s\n' "${JOB_BODY}" | sed -n "${CALLER_CHECKOUT_REL_LINE},+30p" | grep -qE '^\s*clean:[[:space:]]*false'; then
		OPTION_A_OK=1
	fi

	# Option B: a 'Re-checkout aidevops framework scripts' step AFTER the
	# caller checkout. Match common naming variants.
	OPTION_B_OK=0
	# All step names following the caller checkout (i.e. lines after the caller checkout).
	STEPS_AFTER=$(printf '%s\n' "${JOB_BODY}" | tail -n "+${CALLER_CHECKOUT_REL_LINE}")
	if printf '%s\n' "${STEPS_AFTER}" | grep -qE 'name:[[:space:]]+(Re-checkout|Restore|Re-pull) (aidevops )?framework scripts'; then
		OPTION_B_OK=1
	fi

	if [[ "${OPTION_A_OK}" == "1" || "${OPTION_B_OK}" == "1" ]]; then
		check 1 "__aidevops/ preserved after caller checkout (Option A clean:false OR Option B re-checkout)" ""
	else
		check 0 "__aidevops/ preserved after caller checkout (Option A clean:false OR Option B re-checkout)" \
			"neither 'clean: false' nor a 'Re-checkout aidevops framework scripts' step found after 'Checkout repo for TODO.md update' — workspace wipe will delete __aidevops/ and the push-todo step will fail"
	fi
fi

# ============================================================
# Test 4: Update TODO.md proof-log step still references __aidevops/
#         (sanity check — if this changes, the test premise needs updating)
# ============================================================
if printf '%s\n' "${JOB_BODY}" | grep -qE 'bash[[:space:]]+__aidevops/\.agents/scripts/issue-sync-git-push-helper\.sh'; then
	check 1 "Update TODO.md proof-log invokes __aidevops/.agents/scripts/issue-sync-git-push-helper.sh" ""
else
	check 0 "Update TODO.md proof-log invokes __aidevops/.agents/scripts/issue-sync-git-push-helper.sh" \
		"reference path changed — update this test to track the new invocation pattern"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "Summary: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
	exit 1
fi
exit 0
