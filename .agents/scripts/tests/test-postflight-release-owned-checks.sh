#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FILTER="${REPO_ROOT}/.github/scripts/release-owned-check-runs.jq"
WORKFLOW_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-workflow-runs.json"
CHECK_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-owned-check-runs.json"

scope_checks() {
	jq -c \
		--arg release_sha "release-sha" \
		--arg self_name "Verify Release Health" \
		--slurpfile release_run_documents "$WORKFLOW_FIXTURE" \
		-f "$FILTER"
	return 0
}

SCOPED=$(scope_checks <"$CHECK_FIXTURE")

jq -e '
  (.check_runs | length) == 2 and
  all(.check_runs[]; .check_suite.id == 501 or .check_suite.id == 502) and
  all(.check_runs[]; .status == "completed" and .conclusion == "success") and
  (.advisory_check_runs | length) == 1 and
  .advisory_check_runs[0].name == "Socket Security: Project Report" and
  .advisory_check_runs[0].status == "in_progress" and
  (all((.check_runs + .advisory_check_runs)[]; .name != "Verify Release Health"))
' <<<"$SCOPED" >/dev/null

printf 'PASS: superseded, self, and unrelated checks do not delay successful release checks\n'
printf 'PASS: pending external checks are classified as non-required advisories\n'

PAGINATED_SCOPED=$(jq -c \
	--arg release_sha "release-sha" \
	--arg self_name "Verify Release Health" \
	--slurpfile release_run_documents <(jq -s '.' "$WORKFLOW_FIXTURE") \
	-f "$FILTER" \
	"$CHECK_FIXTURE")
jq -e '(.check_runs | length) == 2' <<<"$PAGINATED_SCOPED" >/dev/null

printf 'PASS: paginated workflow-run response retains release-owned suites\n'

PENDING_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.status = "in_progress" | .conclusion = null)' "$CHECK_FIXTURE")
PENDING=$(scope_checks <<<"$PENDING_INPUT")
jq -e '[.check_runs[] | select(.status != "completed")] | length == 1' <<<"$PENDING" >/dev/null

printf 'PASS: pending release-quality checks remain pending\n'

FAILED_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.conclusion = "failure")' "$CHECK_FIXTURE")
FAILED=$(scope_checks <<<"$FAILED_INPUT")
jq -e '[.check_runs[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required"))] | length == 1' <<<"$FAILED" >/dev/null

printf 'PASS: terminal release-quality failures remain blocking\n'

grep -Fq "actions/runs?head_sha=\${COMMIT_SHA}&per_page=100" "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'release-owned-check-runs.jq' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile release_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'non-required advisory check(s) remain non-terminal' "${REPO_ROOT}/.github/workflows/postflight.yml"

printf 'PASS: postflight keeps paginated exact-SHA classification and advisory warnings\n'

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${POSTFLIGHT_RUNS_JSON:?}"
	exit 0
fi
exit 1
EOF
chmod +x "${STUB_DIR}/gh"

SUCCESS_RUNS='[{"databaseId":3001,"name":"Issue Sync","workflowName":"Issue Sync","event":"issues","headSha":"release-sha","status":"completed","conclusion":"failure","updatedAt":"2026-07-15T00:10:00Z"},{"databaseId":3002,"name":"Framework Validation","workflowName":"Framework Validation","event":"push","headSha":"release-sha","status":"completed","conclusion":"success","updatedAt":"2026-07-15T00:09:00Z"}]'
SUCCESS_OUTPUT=$(PATH="${STUB_DIR}:$PATH" POSTFLIGHT_RUNS_JSON="$SUCCESS_RUNS" bash "${REPO_ROOT}/.agents/scripts/postflight-check.sh" --ci-only --sha release-sha 2>&1)
grep -Fq 'Unrelated: Issue Sync (event: issues, conclusion: failure)' <<<"$SUCCESS_OUTPUT"
grep -Fq 'POSTFLIGHT VERIFICATION PASSED WITH WARNINGS' <<<"$SUCCESS_OUTPUT"
printf 'PASS: newer unrelated issues event is reported without replacing release evidence\n'

FAILED_RUNS='[{"databaseId":3003,"name":"Qlty Code Quality","workflowName":"Qlty Code Quality","event":"push","headSha":"release-sha","status":"completed","conclusion":"failure","updatedAt":"2026-07-15T00:11:00Z"}]'
FAILED_STATUS=0
FAILED_OUTPUT=$(PATH="${STUB_DIR}:$PATH" POSTFLIGHT_RUNS_JSON="$FAILED_RUNS" bash "${REPO_ROOT}/.agents/scripts/postflight-check.sh" --ci-only --sha release-sha 2>&1) || FAILED_STATUS=$?
[[ "$FAILED_STATUS" -eq 1 ]]
grep -Fq 'Required release check failed: Qlty Code Quality: failure' <<<"$FAILED_OUTPUT"
printf 'PASS: genuine failed Qlty release check remains explicitly blocking\n'
