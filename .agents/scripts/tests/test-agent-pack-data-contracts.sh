#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
MANIFEST="$REPO_ROOT/.agents/templates/agent-source-repo/agent-pack.json"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		if [[ -n "$message" ]]; then
			printf '  %s\n' "$message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

validate_manifest() {
	local manifest_path="$1"

	python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
allowed = {"public-safe", "private-local", "secret-adjacent", "never-export"}
errors = []

for field in ("inputs", "outputs", "artifact_paths", "default_sensitivity", "sensitivity_tiers"):
    if field not in manifest:
        errors.append(f"missing top-level field: {field}")

for index, output in enumerate(manifest.get("outputs", []), start=1):
    for field in ("name", "description", "artifact_path", "sensitivity", "allowed_destinations"):
        if not output.get(field):
            errors.append(f"output {index} missing {field}")
    sensitivity = output.get("sensitivity")
    if sensitivity and sensitivity not in allowed:
        errors.append(f"output {index} invalid sensitivity: {sensitivity}")

for index, input_item in enumerate(manifest.get("inputs", []), start=1):
    sensitivity = input_item.get("sensitivity")
    if sensitivity and sensitivity not in allowed:
        errors.append(f"input {index} invalid sensitivity: {sensitivity}")

tiers = set(manifest.get("sensitivity_tiers", []))
missing_tiers = allowed - tiers
if missing_tiers:
    errors.append("missing sensitivity tiers: " + ", ".join(sorted(missing_tiers)))

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
	return $?
}

test_template_manifest_is_valid() {
	if validate_manifest "$MANIFEST"; then
		print_result "template manifest declares valid data-flow contract" 0
	else
		print_result "template manifest declares valid data-flow contract" 1 "Template manifest failed validation"
	fi
	return 0
}

test_missing_output_sensitivity_fails() {
	local tmp_manifest
	tmp_manifest="$(mktemp)"
	python3 - "$MANIFEST" "$tmp_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
del manifest["outputs"][0]["sensitivity"]
Path(sys.argv[2]).write_text(json.dumps(manifest))
PY

	if validate_manifest "$tmp_manifest" >/dev/null 2>&1; then
		print_result "missing output sensitivity fails validation" 1 "Validator accepted missing output sensitivity"
	else
		print_result "missing output sensitivity fails validation" 0
	fi
	rm -f "$tmp_manifest"
	return 0
}

test_invalid_output_sensitivity_fails() {
	local tmp_manifest
	tmp_manifest="$(mktemp)"
	python3 - "$MANIFEST" "$tmp_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
manifest["outputs"][0]["sensitivity"] = "public-ish"
Path(sys.argv[2]).write_text(json.dumps(manifest))
PY

	if validate_manifest "$tmp_manifest" >/dev/null 2>&1; then
		print_result "invalid output sensitivity fails validation" 1 "Validator accepted invalid output sensitivity"
	else
		print_result "invalid output sensitivity fails validation" 0
	fi
	rm -f "$tmp_manifest"
	return 0
}

main() {
	printf 'Running agent pack data contract tests\n'
	test_template_manifest_is_valid
	test_missing_output_sensitivity_fails
	test_invalid_output_sensitivity_fails
	printf 'Results: %s/%s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
