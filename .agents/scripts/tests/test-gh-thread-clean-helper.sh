#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../gh-thread-clean-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fixture="$TMP_DIR/thread.json"
output="$TMP_DIR/out.md"

python3 - "$fixture" <<'PY'
import json, sys
body = "Main task\n\n<!-- provenance:start -->noise<!-- provenance:end -->\n\nsrc/app.sh:12 is relevant\n\n---\n[aidevops.sh](https://aidevops.sh) footer"
comments = [
    {"user": {"login": "bot"}, "body": "<!-- ops:start -->worker pid<!-- ops:end -->"},
    {"user": {"login": "coderabbitai"}, "body": "Review skipped due quota"},
    {"user": {"login": "reviewer"}, "body": "Please check .agents/scripts/foo.sh:10"},
]
json.dump({"body": body, "comments": comments}, open(sys.argv[1], "w"))
PY

"$HELPER" clean-file "$fixture" >"$output"

grep -q 'src/app.sh:12' "$output"
grep -q '.agents/scripts/foo.sh:10' "$output"
if grep -Eq 'aidevops\.sh|provenance:start|ops:start|Review skipped' "$output"; then
	printf 'FAIL: noisy content survived\n' >&2
	exit 1
fi

printf 'PASS gh-thread-clean-helper\n'
