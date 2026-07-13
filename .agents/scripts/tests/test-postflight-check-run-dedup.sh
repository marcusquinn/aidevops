#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FILTER="${REPO_ROOT}/.github/scripts/effective-check-runs.jq"
PAGINATION_FILTER="${REPO_ROOT}/.github/scripts/flatten-check-run-pages.jq"
RECONCILE_FILTER="${REPO_ROOT}/.github/scripts/reconcile-superseded-cancellations.jq"
FIXTURE="${SCRIPT_DIR}/fixtures/postflight-check-runs.json"

RESULT=$(jq --arg self_name "Verify Release Health" -f "$FILTER" "$FIXTURE")

jq -e '
  length == 4 and
  any(.[]; .name == "Framework Validation" and .conclusion == "success") and
  any(.[]; .name == "Security Validation" and .conclusion == "failure") and
  ([.[] | select(.name == "Shared Name")] | length == 2) and
  all(.[]; .name != "Verify Release Health")
' <<<"$RESULT" >/dev/null

printf 'PASS: postflight selects the latest completed check run per name and app\n'

CURRENT_RUNS='[
  {"id":10,"name":"Shell portability scan","status":"completed","conclusion":"cancelled","app":{"slug":"github-actions"}},
  {"id":11,"name":"Framework Validation","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}},
  {"id":12,"name":"Security Validation","status":"completed","conclusion":"cancelled","app":{"slug":"github-actions"}}
]'
DESCENDANT_RUNS='[
  {"id":20,"name":"Shell portability scan","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
  {"id":21,"name":"Framework Validation","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
  {"id":22,"name":"Security Validation","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}
]'
RECONCILED=$(jq -cn \
	--slurpfile current_run_documents <(printf '%s\n' "$CURRENT_RUNS") \
	--slurpfile descendant_run_documents <(printf '%s\n' "$DESCENDANT_RUNS") \
	-f "$RECONCILE_FILTER")

jq -e '
  any(.[]; .name == "Shell portability scan" and .conclusion == "success" and .superseded_by_check_run_id == 20) and
  any(.[]; .name == "Framework Validation" and .conclusion == "failure") and
  any(.[]; .name == "Security Validation" and .conclusion == "cancelled")
' <<<"$RECONCILED" >/dev/null

printf 'PASS: postflight accepts only cancelled checks superseded by descendant success\n'

LARGE_TEXT=$(printf '%*s' 300000 '' | tr ' ' x)
LARGE_CURRENT_RUNS=$(jq --rawfile output <(printf '%s' "$LARGE_TEXT") \
	'.[0].output = {text: $output}' <<<"$CURRENT_RUNS")
LARGE_RECONCILED=$(jq -cn \
	--slurpfile current_run_documents <(printf '%s\n' "$LARGE_CURRENT_RUNS") \
	--slurpfile descendant_run_documents <(printf '%s\n' "$DESCENDANT_RUNS") \
	-f "$RECONCILE_FILTER")

jq -e 'length == 3 and (.[0].output.text | length) == 300000' \
	<<<"$LARGE_RECONCILED" >/dev/null

if grep -Fq -- '--argjson current_runs' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight passes check-run payloads through argv\n' >&2
	exit 1
fi

if ! grep -Fq -- '--slurpfile current_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight does not use --slurpfile for current_run_documents\n' >&2
	exit 1
fi

printf 'PASS: postflight reconciliation avoids argv size limits\n'

PAGINATED_RESPONSE=$(jq -cn '
  [
    {check_runs: [range(1; 101) | {id: ., name: "Historical", status: "completed", conclusion: "success"}]},
    {check_runs: [{id: 101, name: "Framework Validation", status: "completed", conclusion: "success"}]}
  ]
')
FLATTENED=$(jq -c -f "$PAGINATION_FILTER" <<<"$PAGINATED_RESPONSE")

jq -e '
  (.check_runs | length) == 101 and
  any(.check_runs[]; .id == 101 and .name == "Framework Validation")
' <<<"$FLATTENED" >/dev/null

grep -Fq 'gh api --paginate --slurp' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'flatten-check-run-pages.jq' "${REPO_ROOT}/.github/workflows/postflight.yml"

printf 'PASS: postflight retains check-run evidence beyond the first API page\n'
