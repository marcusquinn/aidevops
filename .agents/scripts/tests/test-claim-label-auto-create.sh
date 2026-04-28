#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-label-auto-create.sh — GH#21474 regression guard.
#
# Validates the auto-create exception in _validate_labels_exist(): when a label
# matching ^blocked-by:(t[0-9]+|#[0-9]+)$ is missing from the repo, the helper
# auto-creates it via gh label create and continues instead of aborting.
#
# Cases covered:
#   1. blocked-by:t999 missing, gh label create succeeds   → label created in cache,
#                                                             _validate_labels_exist returns 0
#   2. blocked-by:t999 missing, gh label create fails       → warning only, returns 0
#                                                             (best-effort / fail-open)
#   3. tier:standrad (typo) missing                         → still aborts with return 1
#                                                             (t2800 typo-protection preserved)
#   4. blocked-by:#999 (issue-number variant) missing,
#      gh label create succeeds                             → label created, returns 0
#   5. blocked-by:t999 already exists in cache              → no create called, returns 0
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       detail: %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		pass "$name"
	else
		fail "$name" "want='${want}' got='${got}'"
	fi
	return 0
}

assert_return() {
	local name="$1" actual_rc="$2" want_rc="$3"
	if [[ "$actual_rc" == "$want_rc" ]]; then
		pass "$name"
	else
		fail "$name" "want exit=${want_rc} got exit=${actual_rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Shared setup: source claim-task-id.sh with minimal stubs.
# The BASH_SOURCE guard in the script prevents main() from running on source.
# ---------------------------------------------------------------------------

# Create a temp dir for stubs and state shared across all tests
BASE_STUB_DIR=""
BASE_STUB_DIR=$(mktemp -d)
trap 'rm -rf '"$BASE_STUB_DIR"'' EXIT

# Fake git: no-op (silences detect_platform remote calls)
cat >"${BASE_STUB_DIR}/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${BASE_STUB_DIR}/git"

# Fake jq: no-op
cat >"${BASE_STUB_DIR}/jq" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${BASE_STUB_DIR}/jq"

export HOME="${BASE_STUB_DIR}/home"
mkdir -p "${HOME}/.aidevops/logs"

# ---------------------------------------------------------------------------
# Helper: build a per-test gh stub in a new subdir and prepend it to PATH.
# The stub file is written by the caller to configure per-test behavior.
# ---------------------------------------------------------------------------
_make_stub_dir() {
	local stub_dir
	stub_dir=$(mktemp -d "${BASE_STUB_DIR}/test-XXXXXX")
	# Copy shared stubs
	cp "${BASE_STUB_DIR}/git" "${stub_dir}/git"
	cp "${BASE_STUB_DIR}/jq" "${stub_dir}/jq"
	printf '%s' "$stub_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Source the script once (functions are loaded into shell; main() is guarded)
# ---------------------------------------------------------------------------
# We need a gh stub available at source time for the auth check:
cat >"${BASE_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
exit 0
STUB
chmod +x "${BASE_STUB_DIR}/gh"
export PATH="${BASE_STUB_DIR}:${PATH}"

# shellcheck disable=SC1090
if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
	printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: blocked-by:t999 missing, gh create succeeds → returns 0, label in cache
# ---------------------------------------------------------------------------
_run_test1() {
	local stub_dir
	stub_dir=$(_make_stub_dir)

	# Track whether gh label create was invoked
	local create_called_file="${stub_dir}/create_called"

	cat >"${stub_dir}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then exit 0; fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "list" ]]; then
  # Return known labels (not including blocked-by:t999)
  printf 'tier:standard\nauto-dispatch\nbug\n'
  exit 0
fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "create" ]]; then
  printf '%s' "called" > "${create_called_file}"
  exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	# Temporarily prepend our per-test stub
	local saved_path="$PATH"
	PATH="${stub_dir}:${PATH}"

	# Reset session cache so the function fetches fresh
	local saved_cache="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	unset AIDEVOPS_LABEL_CACHE_FILE

	local rc=0
	_validate_labels_exist "owner/repo" "tier:standard,blocked-by:t999" 2>/dev/null || rc=$?

	PATH="$saved_path"
	[[ -n "$saved_cache" ]] && export AIDEVOPS_LABEL_CACHE_FILE="$saved_cache" || true

	assert_return "test1_blocked_by_create_succeeds_returns_0" "$rc" "0"

	local create_called=""
	[[ -f "$create_called_file" ]] && create_called="$(cat "$create_called_file")"
	assert_eq "test1_gh_label_create_was_called" "$create_called" "called"

	return 0
}

# ---------------------------------------------------------------------------
# Test 2: blocked-by:t999 missing, gh create fails → still returns 0 (best-effort)
# ---------------------------------------------------------------------------
_run_test2() {
	local stub_dir
	stub_dir=$(_make_stub_dir)

	cat >"${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
  printf 'tier:standard\nauto-dispatch\nbug\n'
  exit 0
fi
if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
  # Simulate permission/rate-limit failure
  exit 1
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	local saved_path="$PATH"
	PATH="${stub_dir}:${PATH}"

	local saved_cache="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	unset AIDEVOPS_LABEL_CACHE_FILE

	local rc=0
	_validate_labels_exist "owner/repo" "tier:standard,blocked-by:t999" 2>/dev/null || rc=$?

	PATH="$saved_path"
	[[ -n "$saved_cache" ]] && export AIDEVOPS_LABEL_CACHE_FILE="$saved_cache" || true

	assert_return "test2_blocked_by_create_fails_still_returns_0" "$rc" "0"

	return 0
}

# ---------------------------------------------------------------------------
# Test 3: tier:standrad (typo) still aborts — typo-protection preserved (t2800)
# ---------------------------------------------------------------------------
_run_test3() {
	local stub_dir
	stub_dir=$(_make_stub_dir)

	cat >"${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
  printf 'tier:standard\nauto-dispatch\nbug\n'
  exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	local saved_path="$PATH"
	PATH="${stub_dir}:${PATH}"

	local saved_cache="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	unset AIDEVOPS_LABEL_CACHE_FILE

	local rc=0
	_validate_labels_exist "owner/repo" "tier:standrad,bug" 2>/dev/null || rc=$?

	PATH="$saved_path"
	[[ -n "$saved_cache" ]] && export AIDEVOPS_LABEL_CACHE_FILE="$saved_cache" || true

	assert_return "test3_typo_label_still_aborts" "$rc" "1"

	return 0
}

# ---------------------------------------------------------------------------
# Test 4: blocked-by:#999 (issue-number variant), gh create succeeds → returns 0
# ---------------------------------------------------------------------------
_run_test4() {
	local stub_dir
	stub_dir=$(_make_stub_dir)
	local create_called_file="${stub_dir}/create_called"

	cat >"${stub_dir}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then exit 0; fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "list" ]]; then
  printf 'tier:standard\nauto-dispatch\nbug\n'
  exit 0
fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "create" ]]; then
  printf '%s' "called" > "${create_called_file}"
  exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	local saved_path="$PATH"
	PATH="${stub_dir}:${PATH}"

	local saved_cache="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	unset AIDEVOPS_LABEL_CACHE_FILE

	local rc=0
	_validate_labels_exist "owner/repo" "bug,blocked-by:#999" 2>/dev/null || rc=$?

	PATH="$saved_path"
	[[ -n "$saved_cache" ]] && export AIDEVOPS_LABEL_CACHE_FILE="$saved_cache" || true

	assert_return "test4_blocked_by_hash_variant_returns_0" "$rc" "0"

	local create_called=""
	[[ -f "$create_called_file" ]] && create_called="$(cat "$create_called_file")"
	assert_eq "test4_gh_label_create_was_called_for_hash_variant" "$create_called" "called"

	return 0
}

# ---------------------------------------------------------------------------
# Test 5: blocked-by:t999 already in cache → gh label create NOT called, returns 0
# ---------------------------------------------------------------------------
_run_test5() {
	local stub_dir
	stub_dir=$(_make_stub_dir)
	local create_called_file="${stub_dir}/create_called"

	cat >"${stub_dir}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then exit 0; fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "list" ]]; then
  # Include blocked-by:t999 so it's already in the cache
  printf 'tier:standard\nauto-dispatch\nbug\nblocked-by:t999\n'
  exit 0
fi
if [[ "\${1:-}" == "label" && "\${2:-}" == "create" ]]; then
  printf '%s' "called" > "${create_called_file}"
  exit 0
fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	local saved_path="$PATH"
	PATH="${stub_dir}:${PATH}"

	local saved_cache="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	unset AIDEVOPS_LABEL_CACHE_FILE

	local rc=0
	_validate_labels_exist "owner/repo" "bug,blocked-by:t999" 2>/dev/null || rc=$?

	PATH="$saved_path"
	[[ -n "$saved_cache" ]] && export AIDEVOPS_LABEL_CACHE_FILE="$saved_cache" || true

	assert_return "test5_blocked_by_already_in_cache_returns_0" "$rc" "0"

	local create_called=""
	[[ -f "$create_called_file" ]] && create_called="$(cat "$create_called_file")"
	assert_eq "test5_no_create_call_when_label_exists" "$create_called" ""

	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
printf '\n=== test-claim-label-auto-create.sh (GH#21474) ===\n\n'

_run_test1
_run_test2
_run_test3
_run_test4
_run_test5

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
