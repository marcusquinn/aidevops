#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25918/GH#25982: CodeFactor reported the Tambo payload
# validator range in packages/gui-shared/src/tambo.ts. Keep each validator
# function in that reported span compact and push validation branches into
# focused helpers that the package tests cover directly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TAMBO_FILE="${REPO_ROOT}/packages/gui-shared/src/tambo.ts"

if [[ ! -f "$TAMBO_FILE" ]]; then
	printf 'FAIL: missing Tambo schema file: %s\n' "$TAMBO_FILE" >&2
	exit 1
fi

python3 - "$TAMBO_FILE" <<'PY'
import sys

tambo_path = sys.argv[1]
source = open(tambo_path, encoding="utf-8").read().splitlines()

limits = {
    "validateTamboComponentPayload": {"lines": 12, "branches": 1},
    "validateTamboPayloadEnvelope": {"lines": 22, "branches": 3},
    "resolveTamboComponentLookup": {"lines": 12, "branches": 2},
}

functions = {}
current_name = None
brace_depth = 0
body_lines = []
for line in source:
    if current_name is None:
        for name in limits:
            if line.startswith(f"function {name}") or line.startswith(f"export function {name}"):
                current_name = name
                body_lines = []
                brace_depth = 0
                break
    if current_name is None:
        continue
    body_lines.append(line)
    brace_depth += line.count("{") - line.count("}")
    if brace_depth == 0 and len(body_lines) > 1:
        functions[current_name] = body_lines
        current_name = None

missing = sorted(set(limits) - set(functions))
if missing:
    print(f"FAIL: Tambo validator function(s) not found: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

for name, body_lines in functions.items():
    body = "\n".join(body_lines)
    line_count = len(body_lines)
    branch_count = sum(body.count(token) for token in ("if (", "for (", "while (", "switch ("))
    if line_count > limits[name]["lines"]:
        print(f"FAIL: {name} is {line_count} lines; keep <= {limits[name]['lines']}", file=sys.stderr)
        sys.exit(1)
    if branch_count > limits[name]["branches"]:
        print(f"FAIL: {name} has {branch_count} branches; keep <= {limits[name]['branches']}", file=sys.stderr)
        sys.exit(1)

print("PASS: Tambo validator span remains CodeFactor-friendly")
PY
