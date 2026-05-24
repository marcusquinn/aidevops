#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-tabby-helper-appearance.sh — Tabby UI default migration regressions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/tabby-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_contains() {
	local path="$1"
	local needle="$2"
	python3 - "$path" "$needle" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
sys.exit(0 if sys.argv[2] in text else 1)
PY
	return $?
}

_run_fix_appearance() {
	local config_path="$1"
	TABBY_CONFIG="$config_path" bash "$HELPER" fix-appearance >/dev/null
	return 0
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

config_missing_css="${tmp_dir}/missing-css.yaml"
cat >"$config_missing_css" <<'YAML'
version: 8
appearance:
  tabsInFullscreen: true
  colorSchemeMode: auto
  spaciness: 0.9
  tabsLocation: left
  flexTabs: true
hacks: {}
YAML

_run_fix_appearance "$config_missing_css"
if _contains "$config_missing_css" "--side-tab-width: calc(300px * var(--spaciness))"; then
	_pass "missing appearance.css receives left-tab width default"
else
	_fail "missing appearance.css was not patched"
fi

_run_fix_appearance "$config_missing_css"
if [[ "$(python3 - "$config_missing_css" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).read_text().count("--side-tab-width"))
PY
)" == "1" ]]; then
	_pass "left-tab width migration is idempotent"
else
	_fail "left-tab width migration duplicated CSS"
fi

config_placeholder="${tmp_dir}/placeholder-css.yaml"
cat >"$config_placeholder" <<'YAML'
version: 8
appearance:
  css: '/* * { color: blue !important; } */'
  tabsLocation: left
YAML

_run_fix_appearance "$config_placeholder"
if _contains "$config_placeholder" "--side-tab-width: calc(300px * var(--spaciness))"; then
	_pass "Tabby placeholder CSS is replaced"
else
	_fail "Tabby placeholder CSS was not replaced"
fi

config_custom="${tmp_dir}/custom-css.yaml"
cat >"$config_custom" <<'YAML'
version: 8
appearance:
  css: |
    .terminal { font-size: 18px; }
  tabsLocation: left
YAML

before_custom="$(python3 - "$config_custom" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).read_text())
PY
)"
_run_fix_appearance "$config_custom"
after_custom="$(python3 - "$config_custom" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).read_text())
PY
)"
if [[ "$before_custom" == "$after_custom" ]]; then
	_pass "custom Tabby CSS is preserved"
else
	_fail "custom Tabby CSS was modified"
fi

if ((fail_count > 0)); then
	printf '%bFAIL:%b %d test(s) failed\n' "${TEST_RED}" "${TEST_NC}" "$fail_count" >&2
	exit 1
fi

printf '%bOK:%b %d test(s) passed\n' "${TEST_GREEN}" "${TEST_NC}" "$pass_count"
