#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for t2408 / GH#19997: approval-helper.sh must source
# shared-constants.sh so the gh_issue_comment / gh_pr_comment wrappers are
# defined at call time.
# =============================================================================
#
# Background: PR #19953 (t2393) swapped the raw `gh issue comment` /
# `gh pr comment` calls inside approval-helper.sh for the wrappers, but
# approval-helper.sh did not source shared-constants.sh. Under
# `sudo aidevops approve issue <N>` the wrappers were unbound, bash emitted
# `gh_issue_comment: command not found`, and the approval flow failed
# without posting the SSH-signed approval comment.
#
# This test sources approval-helper.sh in a subshell (bypassing the sudo
# requirement via the exported ALLOW_APPROVAL_SOURCE guard check — the
# helper only refuses sudo-sensitive *actions* at call time, not at
# source time) and asserts both wrappers are present as bash functions.
# If either is missing, the test fails with a diagnostic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

assert_defined() {
	local test_name="$1"
	local fn_name="$2"
	local source_output="$3"
	if printf '%s\n' "$source_output" | grep -qxF "FOUND $fn_name"; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $test_name"
	echo "    expected: $fn_name to be defined after sourcing approval-helper.sh"
	echo "    actual source output:"
	printf '%s\n' "$source_output" | sed 's/^/      /'
	FAIL=$((FAIL + 1))
	return 1
}

echo "Test: approval-helper.sh sources shared-constants.sh for wrappers"
echo "=================================================================="
echo ""

# Source approval-helper.sh in a subshell. The helper is normally invoked
# via `aidevops approve` dispatch, not sourced directly, so we override the
# dispatch tail by sourcing only — no _main is called. We probe the
# function table after source.
source_output=$(
	bash -c "
		set -uo pipefail
		# Prevent approval-helper's top-level argument handling from
		# executing: it only dispatches when invoked as a script, not when
		# sourced. Sourcing in this subshell is safe.
		# shellcheck disable=SC1091
		source '${PARENT_DIR}/approval-helper.sh' 2>&1 >/dev/null || true
		for fn in gh_issue_comment gh_pr_comment; do
			if declare -f \"\$fn\" >/dev/null 2>&1; then
				echo \"FOUND \$fn\"
			else
				echo \"MISSING \$fn\"
			fi
		done
	"
)

assert_defined "gh_issue_comment is defined after sourcing approval-helper.sh" \
	"gh_issue_comment" "$source_output"
assert_defined "gh_pr_comment is defined after sourcing approval-helper.sh" \
	"gh_pr_comment" "$source_output"

echo ""
echo "=================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
