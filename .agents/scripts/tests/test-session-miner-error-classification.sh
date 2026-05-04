#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-session-miner-error-classification.sh — Unit tests for session-miner error categories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_MINER_DIR="${SCRIPT_DIR}/../session-miner"

python3 - "$SESSION_MINER_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])

from extract_errors import classify_error


cases = {
    "NotFound: FileSystem.access ([local-worktree])": "workdir_not_found",
    "ENOENT: no such file or directory, open 'missing.txt'": "file_not_found",
    "Error: must Read before Edit": "not_read_first",
}

for raw_error, expected in cases.items():
    actual = classify_error(raw_error)
    if actual != expected:
        raise SystemExit(f"expected {expected!r} for {raw_error!r}, got {actual!r}")

print("session-miner error classification tests passed")
PY
