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
assert_eq 'worker excludes ten days and pre-boundary messages' 530 "$(_detect_session_tokens)"
assert_eq 'older issue window cannot expand attempt' 530 "$(_detect_session_tokens_with_since "$((START - 600))")"
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
if [[ "$SIGNATURE" != *'780 tokens'* || "$SIGNATURE" != *'<!-- aidevops:usage:full-v1 -->'* || "$SIGNATURE" == *'10d'* ]]; then
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
assert_eq 'interactive retains cumulative tokens' 933651 "$(_detect_session_tokens)"
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
	assert_eq 'invalid or unavailable marker preserves fallback' 933651 "$(_detect_session_tokens)"
done

# GH#39951: old normalized buckets and inclusive provider totals describe the
# same work. Cached-only/output-only rows must survive a zero input count.
sqlite3 "$DB" "
INSERT INTO message VALUES
 ('anthropic', ${START}123, '{\"tokens\":{\"input\":10,\"output\":80,\"reasoning\":20,\"cache\":{\"read\":100000,\"write\":20000}}}'),
 ('openai', ${START}123, '{\"tokens\":{\"total\":120110,\"input\":120010,\"output\":100,\"reasoning\":20,\"cache\":{\"read\":100000}}}'),
 ('zero-input', ${START}123, '{\"tokens\":{\"input\":0,\"output\":80,\"reasoning\":20,\"cache\":{\"read\":100000,\"write\":20000}}}'),
 ('missing-input', ${START}123, '{\"tokens\":{\"output\":80}}');
"
assert_eq 'Anthropic cache writes, reads and reasoning included' 120110 "$(_sum_session_tokens_for_session "$DB" anthropic)"
assert_eq 'OpenAI inclusive total does not double count subsets' 120110 "$(_sum_session_tokens_for_session "$DB" openai)"
assert_eq 'zero-input cached request included' 120100 "$(_sum_session_tokens_for_session "$DB" zero-input)"
assert_eq 'missing input does not drop output' 80 "$(_sum_session_tokens_for_session "$DB" missing-input)"

# Exercise the production pre-cleanup capture, not a parallel telemetry formula.
# shellcheck source=../headless-runtime-invoke.sh
source "$SCRIPTS_DIR/headless-runtime-invoke.sh"
runtime_role=worker
export AIDEVOPS_ATTEMPT_STARTED_AT="${START}123456789"
_capture_worker_usage_tokens "$TEST_TMP"
assert_eq 'telemetry captures all attempt sessions before DB cleanup' 361130 "$_WORKER_USAGE_TOKENS_TOTAL"
# Exercise the real terminal writer against a sandbox ledger, not a stub.
(
	export AIDEVOPS_DISPATCH_LEDGER_DIR="$TEST_TMP/ledger"
	export AIDEVOPS_ATTEMPT_ID=usage-regression
	export WORKER_ISSUE_NUMBER=1 WORKER_REPO_SLUG=owner/repo DISPATCH_REPO_SLUG=owner/repo
	# shellcheck source=../headless-runtime-worker-finish.sh
	source "$SCRIPTS_DIR/headless-runtime-worker-finish.sh"
	_hrw_record_terminal_outcome usage-session success verified
	assert_eq 'terminal telemetry persists captured tokens' 361130 "$(jq -r '.tokens' "$TEST_TMP/ledger/tier-telemetry.jsonl")"
)
runtime_role=model-replay
_capture_worker_usage_tokens "$TEST_TMP"
assert_eq 'non-worker invocation clears stale worker telemetry' 0 "$_WORKER_USAGE_TOKENS_TOTAL"
printf 'All attempt-metrics regression checks passed\n'
