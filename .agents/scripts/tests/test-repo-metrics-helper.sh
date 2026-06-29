#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-repo-metrics-helper.sh — local LOC/language/dependency metrics regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$REPO_ROOT/.agents/scripts/repo-metrics-helper.sh"
LOC_HELPER="$REPO_ROOT/.agents/scripts/loc-badge-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local _name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$_name"
	return 0
}

_fail() {
	local _name="$1"
	local _message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n       %s\n' "$_name" "$_message"
	return 0
}

_assert_file_exists() {
	local _name="$1"
	local _path="$2"
	if [[ -f "$_path" ]]; then
		_pass "$_name"
		return 0
	fi
	_fail "$_name" "missing file: $_path"
	return 0
}

_write_fixture_repo() {
	local _repo="$1"
	mkdir -p "$_repo/src"
	git -C "$_repo" init -q
	cat >"$_repo/src/app.py" <<'PY'
# fixture comment
def hello():
    return "hello"
PY
	cat >"$_repo/package.json" <<'JSON'
{"dependencies":{"react":"latest"},"devDependencies":{"typescript":"latest"}}
JSON
	cat >"$_repo/requirements.txt" <<'REQ'
requests==2.32.0
pytest==8.0.0
REQ
	printf '# Fixture\n' >"$_repo/README.md"
	return 0
}

_assert_metrics_json() {
	local _name="$1"
	local _json="$2"
	if python3 - "$_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
languages = {item["name"] for item in data["languages"]}
if data["summary"]["code"] <= 0:
    raise SystemExit("code count not positive")
if "Python" not in languages or "JSON" not in languages:
    raise SystemExit(f"expected Python and JSON languages, got {sorted(languages)}")
if data["dependencies"]["direct"] < 4:
    raise SystemExit(f"expected >=4 direct deps, got {data['dependencies']['direct']}")
if not data["dependencies"]["manifests"]:
    raise SystemExit("expected dependency manifests")
PY
	then
		_pass "$_name"
		return 0
	fi
	_fail "$_name" "metrics JSON assertions failed"
	return 0
}

_test_generate_outputs() {
	local _tmp
	_tmp=$(mktemp -d)
	local _repo="$_tmp/repo"
	mkdir -p "$_repo"
	_write_fixture_repo "$_repo"

	bash "$HELPER" generate \
		--output-dir "$_tmp/out" \
		--badge-dir "$_tmp/out/badges" \
		--legacy-badge-dir "$_tmp/legacy" \
		"$_repo" >/dev/null

	_assert_file_exists "writes metrics JSON" "$_tmp/out/repo-metrics.json"
	_assert_file_exists "writes metrics Markdown" "$_tmp/out/repo-metrics.md"
	_assert_file_exists "writes LOC badge" "$_tmp/out/badges/loc.svg"
	_assert_file_exists "writes language badge" "$_tmp/out/badges/languages.svg"
	_assert_file_exists "writes dependency badge" "$_tmp/out/badges/dependencies.svg"
	_assert_file_exists "writes legacy LOC badge" "$_tmp/legacy/loc-total.svg"
	_assert_file_exists "writes legacy language badge" "$_tmp/legacy/loc-languages.svg"
	_assert_metrics_json "metrics JSON contains LOC/language/dependency data" "$_tmp/out/repo-metrics.json"

	rm -rf "$_tmp"
	return 0
}

_test_legacy_loc_json() {
	local _tmp
	_tmp=$(mktemp -d)
	local _repo="$_tmp/repo"
	mkdir -p "$_repo"
	_write_fixture_repo "$_repo"

	local _json
	_json=$(bash "$LOC_HELPER" --json-only "$_repo")
	if LEGACY_JSON="$_json" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["LEGACY_JSON"])
if data["total"]["code"] <= 0:
    raise SystemExit("legacy total.code not positive")
if not data["top"]:
    raise SystemExit("legacy top languages missing")
PY
	then
		_pass "legacy loc-badge JSON remains compatible"
	else
		_fail "legacy loc-badge JSON remains compatible" "invalid JSON summary"
	fi
	rm -rf "$_tmp"
	return 0
}

main() {
	if [[ ! -f "$HELPER" || ! -f "$LOC_HELPER" ]]; then
		_fail "required helpers exist" "missing repo metrics or LOC helper"
		printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
		return 1
	fi

	_test_generate_outputs
	_test_legacy_loc_json

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
