#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../pulse-current-state-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$TMP_DIR" <<'PY'
import json, os, sys, time
root = sys.argv[1]
now = time.time()
open(os.path.join(root, 'dispatch-stages.tsv'), 'w').write(f'{now}\tworker_spawn\tissue=1\n')
open(os.path.join(root, 'headless-runtime-metrics.jsonl'), 'w').write(json.dumps({'ts': now, 'result': 'success'}) + '\n')
json.dump({'counters': {'dispatch_backoff_skipped': [now]}}, open(os.path.join(root, 'pulse-stats.json'), 'w'))
open(os.path.join(root, 'pulse-wrapper.log'), 'w').write('[pulse] useful activity\nInstance lock acquired\n')
PY

output="$TMP_DIR/out.txt"
"$HELPER" --log-dir "$TMP_DIR" --repo-path "$PWD" --window 15m >"$output"

grep -q 'Dispatch alive: true' "$output"
grep -q 'Worker terminal events: 1' "$output"
grep -q 'dispatch_backoff_skipped' "$output"

printf 'PASS pulse-current-state-helper\n'
