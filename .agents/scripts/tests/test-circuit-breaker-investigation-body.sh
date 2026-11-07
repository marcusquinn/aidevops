#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-circuit-breaker-investigation-body.sh — GH#37053 regression guard.
#
# Asserts _cb_file_investigation_task:
#   (1) passes the full composed body (## What, Ref #<trip>) to gh_create_issue
#   (2) fails closed (no gh_create_issue call) when body composition is empty
#   (3) withdraws auto-dispatch when the created issue came back without a body

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${TEST_SCRIPTS_DIR}/circuit-breaker-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
check() {
	local name="$1" rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"
export SUPERVISOR_DIR="${TEST_ROOT}/supervisor"
mkdir -p "$SUPERVISOR_DIR"

# Source the helper without running main (help is harmless).
# shellcheck source=../circuit-breaker-helper.sh
source "$HELPER" help >/dev/null 2>&1 || true
set +e # the helper enables errexit; assertions below handle exit codes

BODY_FILE="${TEST_ROOT}/body"
CALLS_FILE="${TEST_ROOT}/calls"
: >"$CALLS_FILE"
GH_API_BODY=""
EDIT_LOG=""

gh() {
	case "$1 $2" in
	"label create") return 0 ;;
	"issue edit")
		EDIT_LOG+="$*;"
		return 0
		;;
	esac
	if [[ "$1" == "api" ]]; then
		printf '%s' "$GH_API_BODY"
		return 0
	fi
	return 0
}

gh_create_issue() {
	local prev=""
	local arg
	# Runs inside $(...) in the helper, so persist via files.
	printf x >>"$CALLS_FILE"
	for arg in "$@"; do
		[[ "$prev" == "--body" ]] && printf '%s' "$arg" >"$BODY_FILE"
		prev="$arg"
	done
	echo "https://github.com/o/r/issues/501"
	return 0
}

# Scenario 1: body reaches gh_create_issue intact.
GH_API_BODY="## What
Ref #1"
_cb_file_investigation_task o/r 1 3 "o/r#2" worker_spawn_failed >/dev/null 2>&1
rc=$?
captured=$(<"$BODY_FILE")
if [[ $rc -eq 0 && "$captured" == *"## What"* && "$captured" == *"Ref #1"* ]]; then
	check "body with ## What and Ref #<trip> reaches gh_create_issue" 0
else
	check "body with ## What and Ref #<trip> reaches gh_create_issue" 1
fi
if [[ -z "$EDIT_LOG" ]]; then
	check "intact body leaves auto-dispatch untouched" 0
else
	check "intact body leaves auto-dispatch untouched" 1
fi

# Scenario 2: empty composition fails closed.
: >"$CALLS_FILE"
ORIG_BUILDER=$(declare -f _cb_build_investigation_body)
_cb_build_investigation_body() {
	return 0
}
_cb_file_investigation_task o/r 1 3 "o/r#2" worker_spawn_failed >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 && ! -s "$CALLS_FILE" ]]; then
	check "empty body composition does not create an issue" 0
else
	check "empty body composition does not create an issue" 1
fi

# Scenario 3: created issue lost its body downstream.
eval "$ORIG_BUILDER"
EDIT_LOG=""
GH_API_BODY="<!-- aidevops:sig -->"
_cb_file_investigation_task o/r 1 3 "o/r#2" worker_spawn_failed >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 && "$EDIT_LOG" == *"--remove-label auto-dispatch"* ]]; then
	check "bodyless created issue has auto-dispatch withdrawn" 0
else
	check "bodyless created issue has auto-dispatch withdrawn" 1
fi

# Scenario 4: successful API call returning an empty body counts as lost.
EDIT_LOG=""
GH_API_BODY=""
_cb_file_investigation_task o/r 1 3 "o/r#2" worker_spawn_failed >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 && "$EDIT_LOG" == *"--remove-label auto-dispatch"* ]]; then
	check "empty API body has auto-dispatch withdrawn" 0
else
	check "empty API body has auto-dispatch withdrawn" 1
fi

echo "Total:  $TESTS_RUN"
echo "Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
