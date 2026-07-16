#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../worker-failure-feedback-helper.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

METRICS_FILE="${TEST_ROOT}/metrics.jsonl"
EVIDENCE_FILE="${TEST_ROOT}/objective-evidence.jsonl"
NOW="$(date +%s)"

cat >"$METRICS_FILE" <<JSONL
{"ts":${NOW},"role":"worker","session_key":"issue-601","issue_number":601,"repo_slug":"owner/repo","attempt_id":"attempt-success","run_id":"run-a","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":${NOW},"role":"worker","session_key":"issue-602","issue_number":602,"repo_slug":"owner/repo","attempt_id":"attempt-failed","run_id":"run-b","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":${NOW},"role":"worker","session_key":"issue-603","issue_number":603,"repo_slug":"owner/repo","attempt_id":"attempt-unknown","run_id":"run-c","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":${NOW},"role":"worker","session_key":"issue-604","issue_number":604,"repo_slug":"owner/repo","attempt_id":"attempt-latest-failed","run_id":"run-d","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":${NOW},"role":"worker","session_key":"issue-605","issue_number":605,"repo_slug":"owner/repo","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
JSONL

cat >"$EVIDENCE_FILE" <<JSONL
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":601,"attempt_id":"attempt-success","run_id":"run-a","effective_outcome":"success","evidence_timestamp":${NOW}}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":602,"attempt_id":"attempt-failed","run_id":"run-b","effective_outcome":"failed","evidence_timestamp":${NOW}}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":603,"attempt_id":"attempt-unknown","run_id":"run-c","effective_outcome":"unknown","evidence_timestamp":${NOW}}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":604,"attempt_id":"attempt-latest-failed","run_id":"run-d","effective_outcome":"success","evidence_timestamp":$((NOW - 10))}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":604,"attempt_id":"attempt-latest-failed","run_id":"run-d","effective_outcome":"failed","evidence_timestamp":${NOW}}
JSONL

REPORT=$("$HELPER" report --since-hours 1 --threshold 1 \
	--metrics-file "$METRICS_FILE" --evidence-file "$EVIDENCE_FILE")
if [[ "$(printf '%s' "$REPORT" | jq -r 'length')" != "4" ]]; then
	printf 'FAIL: expected four effective failure groups: %s\n' "$REPORT" >&2
	exit 1
fi
if ! printf '%s' "$REPORT" | jq -e '.[] | select(.issue_number == 602 and .examples[0].attempt_id == "attempt-failed")' >/dev/null; then
	printf 'FAIL: miner did not retain the reconciled failure: %s\n' "$REPORT" >&2
	exit 1
fi
if ! printf '%s' "$REPORT" | jq -e '[.[].issue_number] | sort == [602,603,604,605]' >/dev/null; then
	printf 'FAIL: unknown, latest-failed, or legacy evidence did not fall back to raw failure: %s\n' "$REPORT" >&2
	exit 1
fi

printf 'PASS worker failure mining excludes only validated reconciled non-failures\n'
