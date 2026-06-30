#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25918: CodeFactor reported the Tambo payload
# validator range in packages/gui-shared/src/tambo.ts. Keep the exported
# validator as a compact orchestration entrypoint and push validation branches
# into focused helpers that the package tests cover directly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TAMBO_FILE="${REPO_ROOT}/packages/gui-shared/src/tambo.ts"

if [[ ! -f "$TAMBO_FILE" ]]; then
	printf 'FAIL: missing Tambo schema file: %s\n' "$TAMBO_FILE" >&2
	exit 1
fi

python3 - "$TAMBO_FILE" <<'PY'
import re
import sys

tambo_path = sys.argv[1]
source = open(tambo_path, encoding="utf-8").read().splitlines()

start = None
brace_depth = 0
body_lines = []
for line_number, line in enumerate(source, start=1):
    if start is None and line.startswith("export function validateTamboComponentPayload"):
        start = line_number
    if start is None:
        continue
    body_lines.append(line)
    brace_depth += line.count("{") - line.count("}")
    if brace_depth == 0 and line_number > start:
        break

if start is None:
    print("FAIL: validateTamboComponentPayload export not found", file=sys.stderr)
    sys.exit(1)

body = "\n".join(body_lines)
line_count = len(body_lines)
branch_count = len(re.findall(r"\b(if|for|while|switch)\b", body))

if line_count > 12:
    print(f"FAIL: validateTamboComponentPayload is {line_count} lines; keep <= 12", file=sys.stderr)
    sys.exit(1)
if branch_count > 1:
    print(f"FAIL: validateTamboComponentPayload has {branch_count} branches; keep <= 1", file=sys.stderr)
    sys.exit(1)

print("PASS: Tambo validator entrypoint remains CodeFactor-friendly")
PY
