#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#40246: guard the reported SC2337 sites even on older ShellCheck versions.
# pipe-early-exit-check:disable — this file contains anti-pattern samples as test fixtures
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A scoped source check, not a shell parser: cover immediate and newline-separated
# pipe/grep combinations, including grouped short flags such as -Fq or -qi.
python3 - "$SCRIPT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
paths = [
    root / "test-email-receipt-forward.sh",
    root / "test-hot-deploy-flow.sh",
    root.parent / "test-encryption-git-roundtrip-sops.sh",
    root / "test-maintainer-gate-approval-api-failure.sh",
]
pattern = re.compile(
    r"(?<!\|)\|(?!\|)\s*grep\s+(?:(?:-[A-Za-z]+)\s+)*"
    r"(?:-[A-Za-z]*[qmL][A-Za-z]*(?=\s)|--(?:quiet|silent|max-count|files-without-match)(?=[=\s]))"
)
assert pattern.search('echo "$output" | grep -Fq -- needle')
assert pattern.search("producer |\n\tgrep -F --quiet needle")
assert not pattern.search('grep -q needle <<<"$output"')
assert not pattern.search('producer | grep needle >/dev/null')
assert not pattern.search('grep -q first file || grep -q second file')
for path in paths:
    source = path.read_text().replace("\\\n", " ")
    if pattern.search(source):
        sys.exit(f"FAIL: early-exit grep pipeline remains in {path.name}")
print("PASS: reported suites contain no early-exit grep pipelines")
PY

# Use output much larger than a pipe buffer with a match at the beginning.
# Quiet grep is safe on captured output; live pipelines must consume all input
# and retain the producer's non-zero exit status (unlike process substitution).
produce_output() {
	printf 'MATCH\n%1048576s\n' ''
	return 0
}

output=$(produce_output)
grep -q MATCH <<<"$output"
if grep -q ABSENT <<<"$output"; then
	printf 'FAIL: here-string matched absent text\n' >&2
	exit 1
fi
produce_output | grep MATCH >/dev/null
if produce_output | grep ABSENT >/dev/null; then
	printf 'FAIL: streaming grep matched absent text\n' >&2
	exit 1
fi

produce_failure() {
	produce_output
	return 1
}

status=0
produce_failure | grep MATCH >/dev/null || status=$?
if [[ "$status" -ne 1 ]]; then
	printf 'FAIL: producer failure lost (status=%s)\n' "$status" >&2
	exit 1
fi
printf 'PASS: large-output matches and producer failures survive pipefail\n'
