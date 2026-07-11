#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/observability-helper.sh"
RUNTIME_MODULE="${REPO_ROOT}/.agents/scripts/runtime-events.mjs"

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

command -v node >/dev/null 2>&1 || {
	printf 'SKIP: node unavailable\n'
	exit 0
}
command -v sqlite3 >/dev/null 2>&1 || {
	printf 'SKIP: sqlite3 unavailable\n'
	exit 0
}

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-runtime-events-shell.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT
OBS_DIR="${TMP_HOME}/.aidevops/.agent-workspace/observability"
DB_PATH="${OBS_DIR}/llm-requests.db"
mkdir -p "$OBS_DIR"

RUNTIME_MODULE="$RUNTIME_MODULE" node --input-type=module -e '
const module = await import("file://" + process.env.RUNTIME_MODULE);
process.stdout.write(module.RUNTIME_EVENTS_SCHEMA_SQL);
' | sqlite3 "$DB_PATH"

sqlite3 "$DB_PATH" "
INSERT INTO runtime_events (
  envelope_version, occurred_at, event_id, event_type, correlation_id,
  subject_id, root_event_id, payload_json, payload_bytes, redaction_count
) VALUES (
  1, '2026-07-11T00:00:00.000Z', 'event-1', 'worker.started', 'corr-1',
  'worker-1', 'event-1', '{\"status\":\"running\"}', 20, 0
);"

output="$(HOME="$TMP_HOME" "$HELPER" runtime-events 1 2>/dev/null)"
[[ "$output" == *'"event_type":"worker.started"'* ]] || fail "runtime-events output contains event type"
[[ "$output" == *'"correlation_id":"corr-1"'* ]] || fail "runtime-events output contains correlation ID"
pass "runtime-events queries the existing observability database"

if HOME="$TMP_HOME" "$HELPER" runtime-events 0 >/dev/null 2>&1; then
	fail "runtime-events rejects an invalid limit"
fi
pass "runtime-events validates its bounded limit"
