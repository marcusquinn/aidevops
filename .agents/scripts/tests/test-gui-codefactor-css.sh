#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25321: CodeFactor/stylelint no-duplicate-selectors
# findings in the GUI stylesheet.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
CSS_FILE="${REPO_ROOT}/packages/gui-web/src/styles.css"

if [[ ! -f "$CSS_FILE" ]]; then
	printf 'FAIL: missing GUI stylesheet: %s\n' "$CSS_FILE" >&2
	exit 1
fi

python3 - "$CSS_FILE" <<'PY'
import re
import sys
from collections import defaultdict

css_path = sys.argv[1]
selector_lines: dict[str, list[int]] = defaultdict(list)
brace_depth = 0
pending_selector: list[str] = []
pending_line = 0

with open(css_path, encoding="utf-8") as handle:
    for line_number, raw_line in enumerate(handle, start=1):
        line = raw_line.strip()
        if not line or line.startswith("/*"):
            continue

        if brace_depth == 0 and line.startswith("@"):
            brace_depth += line.count("{") - line.count("}")
            continue

        if brace_depth == 0:
            if "{" in line:
                selector = " ".join(pending_selector + [line.split("{", 1)[0].strip()])
                selector = re.sub(r"\s+", " ", selector).strip()
                if selector:
                    selector_lines[selector].append(pending_line or line_number)
                pending_selector = []
                pending_line = 0
            else:
                pending_selector.append(line)
                pending_line = pending_line or line_number

        brace_depth += line.count("{") - line.count("}")
        if brace_depth < 0:
            brace_depth = 0

duplicates = {selector: lines for selector, lines in selector_lines.items() if len(lines) > 1}
if duplicates:
    print("FAIL: duplicate top-level CSS selectors found", file=sys.stderr)
    for selector, lines in sorted(duplicates.items()):
        joined = ", ".join(str(line) for line in lines)
        print(f"  {selector}: lines {joined}", file=sys.stderr)
    sys.exit(1)

print("PASS: no duplicate top-level GUI CSS selectors")
PY
