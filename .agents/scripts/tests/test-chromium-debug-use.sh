#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../../.." && pwd)"
SCRIPT_PATH="${REPO_DIR}/.agents/scripts/chromium-debug-use.mjs"

readonly TEST_GREEN="[0;32m"
readonly TEST_RED="[0;31m"
readonly TEST_RESET="[0m"
readonly SCRIPT_PATH

EXPECTED_FILES=(
  ".agents/scripts/chromium-debug-use.mjs"
  ".agents/scripts/chromium-debug-use-lib/accessibility.mjs"
  ".agents/scripts/chromium-debug-use-lib/cdp-client.mjs"
  ".agents/scripts/chromium-debug-use-lib/commands.mjs"
  ".agents/scripts/chromium-debug-use-lib/connection.mjs"
  ".agents/scripts/chromium-debug-use-lib/constants.mjs"
  ".agents/scripts/chromium-debug-use-lib/daemon.mjs"
)

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
  local test_name="$1"
  local result="$2"
  local message="${3:-}"

  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$result" -eq 0 ]]; then
    echo -e "${TEST_GREEN}PASS${TEST_RESET} ${test_name}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  fi

  echo -e "${TEST_RED}FAIL${TEST_RESET} ${test_name}"
  if [[ -n "$message" ]]; then
    echo "       ${message}"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
  return 0
}

test_module_layout() {
  local missing=0
  local file=""

  for file in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "${REPO_DIR}/${file}" ]]; then
      print_result "module exists: ${file}" 1 "missing file"
      missing=1
    else
      print_result "module exists: ${file}" 0
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi
  return 0
}

test_module_syntax() {
  local file=""
  local abs_path=""

  for file in "${EXPECTED_FILES[@]}"; do
    abs_path="${REPO_DIR}/${file}"
    if node --check "$abs_path" >/dev/null 2>&1; then
      print_result "syntax: ${file}" 0
    else
      print_result "syntax: ${file}" 1 "node --check failed"
    fi
  done
  return 0
}

test_help_output() {
  local output=""
  local exit_code=0

  output=$(node "$SCRIPT_PATH" --help 2>&1) || exit_code=$?
  if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"Usage: chromium-debug-use <command>"* ]]; then
    print_result "help output" 0
  else
    print_result "help output" 1 "unexpected exit=${exit_code} output=${output}"
  fi
  return 0
}

main() {
  test_module_layout
  test_module_syntax
  test_help_output

  echo
  echo "Tests run: ${TESTS_RUN}"
  echo "Passed: ${TESTS_PASSED}"
  echo "Failed: ${TESTS_FAILED}"

  if [[ "$TESTS_FAILED" -ne 0 ]]; then
    return 1
  fi
  return 0
}

main "$@"
