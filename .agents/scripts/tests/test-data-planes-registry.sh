#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
REGISTRY="$REPO_ROOT/.agents/configs/data-planes.json"

# shellcheck source=../shared-constants.sh
source "$SCRIPT_DIR/../shared-constants.sh"

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

validate_registry() {
	local registry_path="$1"

	python3 - "$registry_path" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text())
required_planes = {"_knowledge", "_cases", "_inbox", "_campaigns", "_projects", "_performance", "_feedback"}
required_fields = {
    "purpose",
    "helper",
    "versioning_policy",
    "sensitivity_default",
    "ingress",
    "egress",
    "index_retrieval_surface",
}
required_versioning_fields = {"versioned_paths", "gitignored_paths"}
allowed_sensitivity = {"public", "internal", "pii", "sensitive", "privileged", "unverified"}
errors = []

planes = registry.get("planes", {})
missing_planes = required_planes - set(planes)
if missing_planes:
    errors.append("missing planes: " + ", ".join(sorted(missing_planes)))

for plane_name, plane in sorted(planes.items()):
    if not plane_name.startswith("_"):
        errors.append(f"plane name must start with underscore: {plane_name}")
    for field in required_fields:
        if field not in plane or plane[field] in ("", [], {}):
            errors.append(f"{plane_name} missing {field}")
    sensitivity = plane.get("sensitivity_default")
    if sensitivity and sensitivity not in allowed_sensitivity:
        errors.append(f"{plane_name} invalid sensitivity_default: {sensitivity}")
    versioning = plane.get("versioning_policy", {})
    for field in required_versioning_fields:
        if field not in versioning or not isinstance(versioning[field], list):
            errors.append(f"{plane_name} versioning_policy missing list {field}")
    for list_field in ("ingress", "egress", "index_retrieval_surface"):
        if list_field in plane and not isinstance(plane[list_field], list):
            errors.append(f"{plane_name} {list_field} must be a list")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
	return $?
}

test_registry_json_valid() {
	if jq . "$REGISTRY" >/dev/null; then
		print_result "data planes registry is valid JSON" 0
	else
		print_result "data planes registry is valid JSON" 1 "jq failed for $REGISTRY"
	fi
	return 0
}

test_registry_contract_valid() {
	if validate_registry "$REGISTRY"; then
		print_result "data planes registry declares required fields" 0
	else
		print_result "data planes registry declares required fields" 1 "Registry contract validation failed"
	fi
	return 0
}

test_missing_required_field_fails() {
	local tmp_registry
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	tmp_registry="$(mktemp)"
	push_cleanup "rm -f '${tmp_registry}'"
	python3 - "$REGISTRY" "$tmp_registry" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text())
del registry["planes"]["_knowledge"]["helper"]
Path(sys.argv[2]).write_text(json.dumps(registry))
PY

	if validate_registry "$tmp_registry" >/dev/null 2>&1; then
		print_result "missing required registry field fails validation" 1 "Validator accepted missing helper field"
	else
		print_result "missing required registry field fails validation" 0
	fi
	rm -f "$tmp_registry"
	tmp_registry=""
	return 0
}

main() {
	printf 'Running data planes registry tests\n'
	test_registry_json_valid
	test_registry_contract_valid
	test_missing_required_field_fails
	printf 'Results: %s/%s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
