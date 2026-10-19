#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#35100: resumed worker signatures must not charge historical session work.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v sqlite3 >/dev/null || {
	printf 'sqlite3 is required\n' >&2
	exit 1
}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export XDG_DATA_HOME="$TEST_TMP"
export AIDEVOPS_SESSION_ORIGIN=worker
export AIDEVOPS_SIG_SESSION_ID=parent
mkdir -p "$TEST_TMP/opencode"
DB="$TEST_TMP/opencode/opencode.db"
NOW=$(date +%s)
START=$((NOW - 300))
export AIDEVOPS_ATTEMPT_STARTED_AT="${START}123456789"

_is_opencode_runtime() { return 0; }
# shellcheck source=../gh-signature-helper-session.sh
source "$SCRIPTS_DIR/gh-signature-helper-session.sh"
# Keep the real ledger parser but isolate its storage from the runner's HOME.
_child_token_ledger_path() {
	local parent_id="$1"
	printf '%s/%s.children.tsv' "$TEST_TMP" "$parent_id"
	return 0
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

sqlite3 "$DB" "
CREATE TABLE session (id TEXT PRIMARY KEY, time_created INTEGER);
CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT);
INSERT INTO session VALUES ('parent', ($NOW - 864000) * 1000), ('child', ($NOW - 864000) * 1000);
INSERT INTO message VALUES
 ('parent', ($NOW - 864000) * 1000, '{\"tokens\":{\"input\":900000,\"output\":33071}}'),
 ('parent', ${START}122, '{\"tokens\":{\"input\":50,\"output\":0}}'),
 ('parent', ${START}123, '{\"tokens\":{\"input\":250,\"output\":80,\"cache\":{\"read\":100,\"write\":0}}}'),
 ('parent', ($START + 200) * 1000, '{\"tokens\":{\"input\":100,\"output\":0}}'),
 ('child', ($NOW - 864000) * 1000, '{\"tokens\":{\"input\":10000,\"output\":0}}'),
 ('child', ($START + 1) * 1000, '{\"tokens\":{\"input\":200,\"output\":0}}');
"
printf 'child\t10200\t%s\nold-external\t5000\t%s\nnew-external\t50\t%s\nmalformed\t700\tunknown\n' \
	"$((START - 100))" "$((START - 100))" "$((START + 1))" >"$TEST_TMP/parent.children.tsv"

assert_eq 'nanosecond marker becomes milliseconds' "${START}123" "$(_worker_attempt_start_ms)"
assert_eq 'worker excludes ten days and pre-boundary messages' 330 "$(_detect_session_tokens)"
assert_eq 'older issue window cannot expand attempt' 330 "$(_detect_session_tokens_with_since "$((START - 600))")"
assert_eq 'newer issue window remains narrower' 100 "$(_detect_session_tokens_with_since "$((START + 100))")"
assert_eq 'children use attempt DB window or current ledger epoch' 250 "$(_sum_child_tokens parent)"
SECONDS_USED=$(_detect_session_time)
if [[ "$SECONDS_USED" -lt 299 || "$SECONDS_USED" -gt 310 ]]; then
	printf 'FAIL attempt duration: %s\n' "$SECONDS_USED" >&2
	exit 1
fi
printf 'PASS attempt duration is five minutes, not ten days\n'

# Exercise the public producer as well as the individual metric functions.
mkdir -p "$TEST_TMP/.aidevops/.agent-workspace/tmp"
cp "$TEST_TMP/parent.children.tsv" "$TEST_TMP/.aidevops/.agent-workspace/tmp/parent.children.tsv"
SIGNATURE=$(HOME="$TEST_TMP" OPENCODE=true bash "$SCRIPTS_DIR/gh-signature-helper.sh" generate --cli OpenCode --model regression)
if [[ "$SIGNATURE" != *'580 tokens'* || "$SIGNATURE" == *'933,451 tokens'* || "$SIGNATURE" == *'10d'* ]]; then
	printf 'FAIL generated signature does not reflect attempt metrics\n' >&2
	exit 1
fi
printf 'PASS generated signature combines attempt-scoped parent and child work\n'

for marker in "$START" "${START}000" "${START}000000" "${START}000000000"; do
	export AIDEVOPS_ATTEMPT_STARTED_AT="$marker"
	assert_eq 'supported timestamp precision' "${START}000" "$(_worker_attempt_start_ms)"
done

export AIDEVOPS_ATTEMPT_STARTED_AT="${START}123456789"
export AIDEVOPS_SESSION_ORIGIN=interactive
assert_eq 'interactive retains cumulative tokens' 933451 "$(_detect_session_tokens)"
assert_eq 'interactive retains cumulative children' 15950 "$(_sum_child_tokens parent)"
assert_eq 'interactive ignores worker marker' '' "$(_worker_attempt_start_ms)"
SECONDS_USED=$(_detect_session_time)
[[ "$SECONDS_USED" -ge 864000 ]] || {
	printf 'FAIL interactive duration\n' >&2
	exit 1
}

export AIDEVOPS_SESSION_ORIGIN=worker
for marker in '' invalid 0 123 99999999999999999999 "$((NOW + 3600))000000000"; do
	export AIDEVOPS_ATTEMPT_STARTED_AT="$marker"
	assert_eq 'invalid or unavailable marker preserves fallback' 933451 "$(_detect_session_tokens)"
done
printf 'All attempt-metrics regression checks passed\n'
