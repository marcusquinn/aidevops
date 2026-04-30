#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-marketplace-race.sh — t3202 / GH#21905 regression guard.
#
# Asserts that `_update_json_version_field` (in version-manager-files.sh):
#
#   1. Reads with the SAME jq query that the final validator
#      (validate-version-consistency.sh::_check_marketplace_json) uses,
#      so updater and validator can never disagree on the read path.
#   2. Reports SUCCESS only when the validator query also sees the new
#      version — eliminating the v3.13.13 failure mode where the updater's
#      grep-based check passed but the validator's jq-based check did not.
#   3. Handles BOTH JSON shapes: top-level `.version` (package.json,
#      .claude-plugin/plugin.json) and nested `.metadata.version`
#      (.claude-plugin/marketplace.json).
#   4. Fails with diagnostic output when the file is genuinely unwritable
#      via the sed pattern (negative case).
#
# The race observed in v3.13.13 (2026-04-30): 4 chained sed_inplace + read
# pairs across VERSION, package.json, marketplace.json, and sonar config in
# the same release-execute call. The marketplace.json read sometimes saw
# old content. We could not deterministically reproduce the race in
# isolation, so this test runs many rapid iterations as the closest
# in-process proxy AND validates the read-path symmetry that closes the
# original divergence regardless of whether the race itself fires.
#
# Reference: marcusquinn/aidevops#21905, .agents/scripts/version-manager-files.sh:147

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

# Sandbox HOME so init_log_file (sourced via shared-constants) doesn't
# touch the real ~/.aidevops/logs.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Provide the variables that version-manager.sh's orchestrator normally
# sets before sourcing version-manager-files.sh.
SCRIPT_DIR="${TEST_SCRIPTS_DIR}"
REPO_ROOT="${TEST_ROOT}/repo"
mkdir -p "$REPO_ROOT"
export SCRIPT_DIR REPO_ROOT

# Source dependencies in the same order version-manager.sh does.
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=../version-manager-files.sh
source "${SCRIPT_DIR}/version-manager-files.sh"

# The validator's exact query — pin it so the test fails loudly if
# validate-version-consistency.sh's read path drifts away from the
# updater's read path. Update both helpers together, never one alone.
VALIDATOR_JQ_QUERY='.version // .metadata.version // "not found"'

# ---------------------------------------------------------------------
# Test 1: marketplace.json shape (.metadata.version, no top-level)
# ---------------------------------------------------------------------
test_marketplace_shape() {
	local fixture="${TEST_ROOT}/marketplace.json"
	cat >"$fixture" <<'EOF'
{
  "$schema": "https://example.com/marketplace.schema.json",
  "name": "aidevops",
  "metadata": {
    "version": "9.9.0",
    "description": "test fixture"
  },
  "plugins": []
}
EOF

	# Run 50 update+verify iterations. Each uses a different version
	# string to force a real sed substitution every time.
	local i new_version actual rc=0
	for i in $(seq 1 50); do
		new_version="9.9.${i}"
		_update_json_version_field "$fixture" "$new_version" "marketplace.json (test)" >/dev/null 2>&1 || {
			rc=1
			echo "  iteration $i: _update_json_version_field returned non-zero" >&2
			break
		}
		# Validator read path
		actual=$(jq -r "$VALIDATOR_JQ_QUERY" "$fixture" 2>/dev/null)
		if [[ "$actual" != "$new_version" ]]; then
			rc=1
			echo "  iteration $i: validator read '$actual', expected '$new_version'" >&2
			break
		fi
	done
	return $rc
}

# ---------------------------------------------------------------------
# Test 2: package.json shape (top-level .version)
# ---------------------------------------------------------------------
test_package_shape() {
	local fixture="${TEST_ROOT}/package.json"
	cat >"$fixture" <<'EOF'
{
  "name": "test-pkg",
  "version": "9.9.0",
  "description": "test fixture",
  "scripts": {
    "test": "echo ok"
  }
}
EOF

	local i new_version actual rc=0
	for i in $(seq 1 50); do
		new_version="9.9.${i}"
		_update_json_version_field "$fixture" "$new_version" "package.json (test)" >/dev/null 2>&1 || {
			rc=1
			echo "  iteration $i: _update_json_version_field returned non-zero" >&2
			break
		}
		actual=$(jq -r "$VALIDATOR_JQ_QUERY" "$fixture" 2>/dev/null)
		if [[ "$actual" != "$new_version" ]]; then
			rc=1
			echo "  iteration $i: validator read '$actual', expected '$new_version'" >&2
			break
		fi
	done
	return $rc
}

# ---------------------------------------------------------------------
# Test 3: idempotent path — file already has target version.
# The sed runs anyway (no-op substitution), and the post-validation
# must still confirm the value via the validator's query.
# ---------------------------------------------------------------------
test_idempotent_already_target() {
	local fixture="${TEST_ROOT}/idempotent.json"
	cat >"$fixture" <<'EOF'
{
  "metadata": {
    "version": "9.9.42"
  }
}
EOF

	_update_json_version_field "$fixture" "9.9.42" "idempotent.json (test)" >/dev/null 2>&1 || return 1
	local actual
	actual=$(jq -r "$VALIDATOR_JQ_QUERY" "$fixture" 2>/dev/null)
	[[ "$actual" == "9.9.42" ]]
}

# ---------------------------------------------------------------------
# Test 4: negative path — file has no "version" key the sed can match.
# The helper must return 1 AND emit a diagnostic line that mentions the
# observed jq read. We capture stderr and grep for the marker.
# ---------------------------------------------------------------------
test_negative_diagnostic() {
	local fixture="${TEST_ROOT}/no-version.json"
	cat >"$fixture" <<'EOF'
{
  "name": "no-version-key",
  "metadata": {
    "description": "no version field at all"
  }
}
EOF

	local stderr_capture rc
	stderr_capture=$(_update_json_version_field "$fixture" "9.9.99" "no-version.json (test)" 2>&1 >/dev/null)
	rc=$?
	if [[ $rc -eq 0 ]]; then
		echo "  expected non-zero exit, got 0" >&2
		return 1
	fi
	# The diagnostic block must include the actual jq read result and
	# the file path. Both are mentioned in the new helper's error path.
	if ! grep -q 'Failed to update' <<<"$stderr_capture"; then
		echo "  diagnostic missing 'Failed to update' marker:" >&2
		echo "$stderr_capture" >&2
		return 1
	fi
	if ! grep -q "diagnostic: file=" <<<"$stderr_capture"; then
		echo "  diagnostic missing 'diagnostic: file=' marker:" >&2
		echo "$stderr_capture" >&2
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------
# Test 5: read-path symmetry pin — assert the helper uses the SAME jq
# query string the final validator uses. Locks the contract: if either
# helper drifts, both this test and validate-version-consistency must
# move together.
# ---------------------------------------------------------------------
test_read_path_symmetry() {
	local helper_query
	helper_query=$(grep -E "^[[:space:]]+actual_version=\\\$\\(jq -r " \
		"${SCRIPT_DIR}/version-manager-files.sh" | head -n 1)
	if ! grep -q "$VALIDATOR_JQ_QUERY" <<<"$helper_query"; then
		echo "  helper jq query does not match validator query" >&2
		echo "  helper: $helper_query" >&2
		echo "  validator (pinned): $VALIDATOR_JQ_QUERY" >&2
		return 1
	fi
	# Also confirm the validator file still uses this query, so that
	# fixing only one side fails this test.
	local validator="${SCRIPT_DIR}/validate-version-consistency.sh"
	if [[ -f "$validator" ]]; then
		if ! grep -qF "$VALIDATOR_JQ_QUERY" "$validator"; then
			echo "  validator query drifted away from pinned form" >&2
			return 1
		fi
	fi
	return 0
}

# --- Run ---
test_marketplace_shape
print_result "marketplace.json (.metadata.version) — 50 rapid update+validator cycles" $?

test_package_shape
print_result "package.json (top-level .version) — 50 rapid update+validator cycles" $?

test_idempotent_already_target
print_result "idempotent path — file already at target version" $?

test_negative_diagnostic
print_result "negative path — emits diagnostic on persistent failure" $?

test_read_path_symmetry
print_result "read-path symmetry — helper jq matches validator jq" $?

echo "---"
echo "Tests run: $TESTS_RUN"
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
else
	printf '%s%d test(s) failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
