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

# GH#33532: dev-only dependencies are counted apart from runtime ones, a name
# in both sections stays runtime, Composer platform requirements are ignored,
# and no legacy .github/badges output is written unless asked for.
_test_runtime_dev_split() {
	local _tmp
	_tmp=$(mktemp -d)
	local _repo="$_tmp/repo"
	mkdir -p "$_repo"
	_write_fixture_repo "$_repo"
	cat >"$_repo/composer.json" <<'JSON'
{"require":{"php":">=7.4","ext-json":"*","guzzlehttp/guzzle":"^7"},
 "require-dev":{"phpunit/phpunit":"^10","guzzlehttp/guzzle":"^7"}}
JSON

	bash "$HELPER" generate \
		--output-dir "$_repo/docs/metrics" \
		--badge-dir "$_repo/docs/metrics/badges" \
		"$_repo" >/dev/null

	if python3 - "$_repo/docs/metrics/repo-metrics.json" <<'PY'
import json
import sys
from pathlib import Path

deps = json.loads(Path(sys.argv[1]).read_text())["dependencies"]
# react, requests, pytest, guzzlehttp/guzzle runtime; typescript, phpunit/phpunit dev
expected = {"direct": 6, "runtime": 4, "dev": 2}
actual = {key: deps[key] for key in expected}
if actual != expected:
    raise SystemExit(f"expected {expected}, got {actual}")
composer = next(m for m in deps["manifests"] if m["path"] == "composer.json")
if composer["dependencies"] != ["guzzlehttp/guzzle", "phpunit/phpunit"]:
    raise SystemExit(f"platform packages not excluded: {composer['dependencies']}")
PY
	then
		_pass "metrics JSON splits runtime and dev-only dependencies"
	else
		_fail "metrics JSON splits runtime and dev-only dependencies" "unexpected dependency counts"
	fi
	if grep -Fq '4 runtime, 2 dev' "$_repo/docs/metrics/badges/dependencies.svg"; then
		_pass "dependency badge labels runtime and dev counts"
	else
		_fail "dependency badge labels runtime and dev counts" "badge text missing '4 runtime, 2 dev'"
	fi
	if [[ ! -e "$_repo/.github/badges" ]]; then
		_pass "no legacy badge directory without --legacy-badge-dir"
	else
		_fail "no legacy badge directory without --legacy-badge-dir" "unexpected $_repo/.github/badges"
	fi
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
	_test_runtime_dev_split
	_test_legacy_loc_json

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
