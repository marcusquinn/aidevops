#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FILTER="${REPO_ROOT}/.github/scripts/effective-check-runs.jq"
PAGINATION_FILTER="${REPO_ROOT}/.agents/scripts/jq/flatten-check-run-pages.jq"
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

for INVALID_RESPONSE in 'null' '{"message":"API unavailable"}'; do
	if ! jq -e -f "$PAGINATION_FILTER" <<<"$INVALID_RESPONSE" |
		jq -e '.check_runs == []' >/dev/null; then
		printf 'FAIL: pagination filter did not return empty check_runs for: %s\n' "$INVALID_RESPONSE" >&2
		exit 1
	fi
done

if ! grep -Fq 'gh api --paginate --slurp' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight does not request all check-run pages\n' >&2
	exit 1
fi

if ! grep -Fq 'flatten-check-run-pages.jq' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight does not flatten paginated check-run responses\n' >&2
	exit 1
fi

printf 'PASS: postflight retains check-run evidence beyond the first API page\n'

DEPLOYED_ROOT=$(mktemp -d)
trap 'rm -rf "$DEPLOYED_ROOT"' EXIT
DEPLOYED_SCRIPTS="${DEPLOYED_ROOT}/.aidevops/agents/scripts"
MOCK_BIN="${DEPLOYED_ROOT}/bin"
mkdir -p "$DEPLOYED_SCRIPTS" "$MOCK_BIN"
cp -R "${REPO_ROOT}/.agents/scripts/." "$DEPLOYED_SCRIPTS/"

cat >"${MOCK_BIN}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi

for arg in "$@"; do
	case "$arg" in
	*/check-runs\?per_page=100)
		printf '%s\n' '[{"check_runs":[{"id":1,"name":"Framework Validation","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"check_suite":{"id":501}}]}]'
		exit 0
		;;
	*/actions/runs\?head_sha=release-sha\&per_page=100)
		printf '%s\n' '[{"workflow_runs":[{"id":10,"name":"Release","head_sha":"release-sha","event":"push","status":"completed","conclusion":"success","check_suite_id":501}]}]'
		exit 0
		;;
	esac
done

exit 1
MOCK_GH
chmod +x "${MOCK_BIN}/gh"

if [[ -e "${DEPLOYED_ROOT}/.github" ]]; then
	printf 'FAIL: deployed-layout fixture unexpectedly contains repository .github files\n' >&2
	exit 1
fi

DEPLOYED_OUTPUT=$(PATH="${MOCK_BIN}:$PATH" \
	"${DEPLOYED_SCRIPTS}/postflight-check.sh" --ci-only --sha release-sha 2>&1)
grep -Fq '1 required release-owned check(s) passed' <<<"$DEPLOYED_OUTPUT"

printf 'PASS: deployed postflight loads colocated check-run filters without repository .github\n'
