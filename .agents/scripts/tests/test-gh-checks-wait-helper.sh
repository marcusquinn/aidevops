#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../gh-checks-wait-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		fail "$name" "unexpected ${needle}"
	else
		pass "$name"
	fi
	return 0
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected ${expected}, got ${actual}"
	fi
	return 0
}

write_fixture() {
	local directory="$1"
	local number="$2"
	local content="$3"
	mkdir -p "$directory"
	printf '%s\n' "$content" >"${directory}/poll-${number}.json"
	return 0
}

run_fixture_wait() {
	local fixture_dir="$1"
	local required_contexts="${AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS-}"
	shift
	AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$fixture_dir" \
		AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 \
		AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
		AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS="$required_contexts" \
		AIDEVOPS_GH_CHECKS_TEST_HEAD="${AIDEVOPS_GH_CHECKS_TEST_HEAD_OVERRIDE-fixture-head}" \
		AIDEVOPS_GH_CHECKS_TEST_DRAFT="${AIDEVOPS_GH_CHECKS_TEST_DRAFT_OVERRIDE-false}" \
		AIDEVOPS_GH_CHECKS_TEST_PR_STATE="${AIDEVOPS_GH_CHECKS_TEST_PR_STATE_OVERRIDE-OPEN}" \
		"$HELPER" wait 123 --repo example/repo --initial-interval 1 --max-interval 4 "$@"
	return $?
}

transition_dir="${TMPDIR_TEST}/transition"
write_fixture "$transition_dir" 1 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 2 '[{"name":"Complexity","workflow":"CI","state":"PENDING","bucket":"pending","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$transition_dir" 3 '[{"name":"Complexity","workflow":"CI","state":"SUCCESS","bucket":"pass","link":"https://example.invalid/1"},{"name":"maintainer-gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'

transition_output=$(run_fixture_wait "$transition_dir")
draft_output=$(AIDEVOPS_GH_CHECKS_TEST_DRAFT_OVERRIDE=true run_fixture_wait "$transition_dir")
assert_contains "draft PR warns about skipped review" "NOTE: PR is draft; review bots (e.g. CodeRabbit) may skip drafts and still report pass. Run gh pr ready, then wait again for review evidence." "$draft_output"
draft_note_count=$(printf '%s\n' "$draft_output" | grep -c '^NOTE: PR is draft;' || true)
assert_eq "draft warning prints once" "1" "$draft_note_count"
assert_contains "draft checks still pass" "PASS: required checks completed" "$draft_output"
[[ "$transition_output" != *'NOTE: PR is draft;'* ]] && pass "non-draft PR has no warning" || fail "non-draft PR has no warning"
assert_contains "wait prints initial state once" "CI wait started: pass=1 pending=1" "$transition_output"
assert_contains "wait prints state transition" "+ Complexity: pending -> pass" "$transition_output"
assert_contains "wait prints terminal success" "PASS: required checks completed" "$transition_output"
pending_count=$(printf '%s\n' "$transition_output" | grep -c '^  Complexity: pending$' || true)
[[ "$pending_count" -eq 1 ]] && pass "unchanged snapshot is not replayed" || fail "unchanged snapshot is not replayed" "count ${pending_count}"

empty_dir="${TMPDIR_TEST}/empty"
write_fixture "$empty_dir" 1 '[]'
empty_output=$(run_fixture_wait "$empty_dir")
assert_contains "no required checks is explicit terminal success" "PASS: verified no required checks; optional checks were not evaluated (use --all to wait for all checks)" "$empty_output"

set +e
configured_missing_output=$(AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nLint' run_fixture_wait "$empty_dir" --timeout 0 2>&1)
configured_missing_rc=$?
set -e
[[ "$configured_missing_rc" -eq 8 ]] && pass "configured but unreported required checks remain pending" || fail "configured but unreported required checks remain pending" "got ${configured_missing_rc}"
assert_contains "configured but unreported required checks time out as pending" "TIMEOUT: required checks remain non-terminal" "$configured_missing_output"
assert_contains "initial state names every unreported context" "CI wait started: none=0 missing=Format, Lint" "$configured_missing_output"
assert_contains "timeout names every unreported context" "(none=0 missing=Format, Lint)" "$configured_missing_output"

draft_skipped_dir="${TMPDIR_TEST}/draft-skipped"
write_fixture "$draft_skipped_dir" 1 '[{"name":"Format","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
set +e
draft_missing_output=$(AIDEVOPS_GH_CHECKS_TEST_DRAFT_OVERRIDE=true AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nLint' run_fixture_wait "$draft_skipped_dir" --timeout 5 --heartbeat 1 2>&1)
draft_missing_rc=$?
draft_skipped_output=$(AIDEVOPS_GH_CHECKS_TEST_DRAFT_OVERRIDE=true AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=Format run_fixture_wait "$draft_skipped_dir" --timeout 5 --heartbeat 1 2>&1)
draft_skipped_rc=$?
ready_missing_output=$(AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nLint' run_fixture_wait "$draft_skipped_dir" --timeout 1 --heartbeat 1 2>&1)
ready_missing_rc=$?
set -e
assert_eq "draft missing and skipped checks return 9" "9" "$draft_missing_rc"
assert_contains "draft result identifies action" "WAIT_CHECKS=draft-required-missing: run gh pr ready 123 --repo example/repo, then wait again" "$draft_missing_output"
assert_eq "draft skipped required checks return 9" "9" "$draft_skipped_rc"
assert_eq "ready missing checks remain pending" "8" "$ready_missing_rc"
assert_contains "ready missing checks report timeout" "TIMEOUT:" "$ready_missing_output"

set +e
conflict_output=$(AIDEVOPS_GH_CHECKS_TEST_MERGEABLE=CONFLICTING AIDEVOPS_GH_CHECKS_EMPTY_SETTLE_SECONDS=0 AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nLint' run_fixture_wait "$draft_skipped_dir" --timeout 5 --heartbeat 1 2>&1)
conflict_rc=$?
unknown_output=$(AIDEVOPS_GH_CHECKS_TEST_MERGEABLE=UNKNOWN AIDEVOPS_GH_CHECKS_EMPTY_SETTLE_SECONDS=0 AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nLint' run_fixture_wait "$draft_skipped_dir" --timeout 1 --heartbeat 1 2>&1)
unknown_rc=$?
set -e
assert_eq "conflicting PR with missing checks returns 10" "10" "$conflict_rc"
assert_contains "conflict result identifies rebase" "WAIT_CHECKS=conflict-required-missing: PR 123 conflicts with main; rebase onto origin/main, push, then wait again" "$conflict_output"
assert_eq "unknown mergeability stays pending" "8" "$unknown_rc"

partial_dir="${TMPDIR_TEST}/partial"
write_fixture "$partial_dir" 1 '[{"name":"Format","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
partial_output=$(AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nQlty Regression Gate\nLint' run_fixture_wait "$partial_dir" --timeout 3 --heartbeat 1 2>&1)
partial_rc=$?
set -e
assert_eq "passing reported checks cannot satisfy missing contexts" "8" "$partial_rc"
assert_contains "initial state names only missing contexts" "CI wait started: pass=1 missing=Qlty Regression Gate, Lint" "$partial_output"
heartbeat_line=$(printf '%s\n' "$partial_output" | grep '^heartbeat:' || true)
assert_contains "heartbeat names missing contexts" "(pass=1 missing=Qlty Regression Gate, Lint)" "$heartbeat_line"
timeout_line=$(printf '%s\n' "$partial_output" | grep '^TIMEOUT:' || true)
assert_contains "timeout names missing contexts with passing checks" "(pass=1 missing=Qlty Regression Gate, Lint)" "$timeout_line"
[[ "$partial_output" != *'missing=Format'* ]] && pass "reported context is excluded from missing names" || fail "reported context is excluded from missing names"

all_checks_dir="${TMPDIR_TEST}/all-checks"
write_fixture "$all_checks_dir" 1 '[{"name":"Preview","workflow":"Deploy","state":"PENDING","bucket":"pending","link":""}]'
write_fixture "$all_checks_dir" 2 '[{"name":"Preview","workflow":"Deploy","state":"SUCCESS","bucket":"pass","link":""}]'
all_checks_output=$(run_fixture_wait "$all_checks_dir" --all)
assert_contains "all-check mode observes pending optional checks" "Preview: pending" "$all_checks_output"
assert_contains "all-check mode waits for the transition" "+ Preview: pending -> pass" "$all_checks_output"
assert_contains "all-check mode reports scoped terminal success" "PASS: all checks completed" "$all_checks_output"

# GH#39075: a PR merged by native auto-merge stops the wait even while an
# optional context is still pending (no timeout wait).
merged_dir="${TMPDIR_TEST}/merged-pending"
write_fixture "$merged_dir" 1 '[{"name":"Complexity Analysis","workflow":"CI","state":"PENDING","bucket":"pending","link":""}]'
set +e
merged_output=$(AIDEVOPS_GH_CHECKS_TEST_PR_STATE_OVERRIDE=$'MERGED\t2026-11-18T21:03:39Z' run_fixture_wait "$merged_dir" --all --timeout 1800 2>&1)
merged_rc=$?
closed_output=$(AIDEVOPS_GH_CHECKS_TEST_PR_STATE_OVERRIDE=$'CLOSED\t' run_fixture_wait "$merged_dir" --all --timeout 1800 2>&1)
closed_rc=$?
set -e
assert_eq "merged PR with pending optional check exits 0" "0" "$merged_rc"
assert_contains "merged PR prints terminal line" "MERGED: PR #123 merged at 2026-11-18T21:03:39Z; check wait not required" "$merged_output"
assert_eq "closed unmerged PR exits non-zero" "1" "$closed_rc"
assert_contains "closed PR prints clear message" "CLOSED: PR #123 was closed without merging" "$closed_output"

all_empty_output=$(run_fixture_wait "$empty_dir" --all)
assert_contains "empty all-check selection is explicit terminal success" "PASS: verified no checks reported" "$all_empty_output"

# t18926: --all must not succeed while a configured required context is absent,
# and zero-job workflow runs are named as a distinct terminal failure.
zero_job_dir="${TMPDIR_TEST}/zero-job"
write_fixture "$zero_job_dir" 1 '[{"name":"Format","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
printf '%s\n' '{"workflow_runs":[{"id":111,"name":"Complexity","workflow_id":1,"run_number":2,"head_sha":"fixture-head","status":"completed","conclusion":"failure","total_jobs":0},{"id":112,"name":"Format","workflow_id":2,"run_number":1,"head_sha":"fixture-head","status":"completed","conclusion":"success","total_jobs":3}]}' >"${zero_job_dir}/runs.json"
set +e
all_pending_output=$(AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nComplexity' run_fixture_wait "$empty_dir" --all --timeout 0 2>&1)
all_pending_rc=$?
zero_job_output=$(AIDEVOPS_GH_CHECKS_EMPTY_SETTLE_SECONDS=0 AIDEVOPS_GH_CHECKS_TEST_REQUIRED_CONTEXTS=$'Format\nComplexity' run_fixture_wait "$zero_job_dir" --all --timeout 0 2>&1)
zero_job_rc=$?
set -e
assert_eq "--all with an absent required context does not exit 0" "8" "$all_pending_rc"
assert_eq "zero-job runs are a terminal failure" "1" "$zero_job_rc"
assert_contains "zero-job failure names workflow and run ID" "Complexity (run 111)" "$zero_job_output"
assert_contains "zero-job failure gives rerun hint" "gh run rerun <id> --repo example/repo" "$zero_job_output"
[[ "$zero_job_output" != *'(run 112)'* ]] && pass "healthy run is not reported as zero-job" || fail "healthy run is not reported as zero-job"

live_bin="${TMPDIR_TEST}/live-bin"
mkdir -p "$live_bin"
cat >"${live_bin}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	if [[ " $* " == *' --json isDraft '* ]]; then
		printf '%s\n' "${GH_TEST_DRAFT:-false}"
	else
		printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
	fi
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo" ]]; then
	[[ -z "${GH_TEST_METADATA_LOG:-}" ]] || printf 'read\n' >>"$GH_TEST_METADATA_LOG"
	case "${GH_TEST_REPO_KIND:-personal}" in
	private) printf '%s\n' '{"private":true,"owner":{"type":"User"}}' ;;
	organisation) printf '%s\n' '{"private":false,"owner":{"type":"Organization"}}' ;;
	unavailable) exit 1 ;;
	malformed) printf '%s\n' '{}' ;;
	*) printf '%s\n' '{"private":false,"owner":{"type":"User"}}' ;;
	esac
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/pulls/123" ]]; then
	if [[ "${3:-}" == "--jq" ]]; then
		printf '%s\n' main
		exit 0
	fi
	if [[ "${GH_TEST_MODE:-no-required}" == "local-deferral" || "${GH_TEST_MODE:-no-required}" == "local-deferral-once" ]]; then
		count=0
		[[ ! -s "${GH_TEST_CALL_COUNT:-}" ]] || count=$(<"$GH_TEST_CALL_COUNT")
		count=$((count + 1))
		printf '%s\n' "$count" >"$GH_TEST_CALL_COUNT"
		if [[ "${GH_TEST_MODE:-no-required}" == "local-deferral" || "$count" -eq 1 ]]; then
			printf '[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=%s reason="fixture"\n' "${GH_TEST_RETRY_AT:-1010}" >&2
			exit 75
		fi
	fi
	printf '%s\n' '{"number":123,"node_id":"PR_fixture","head":{"ref":"feature/test","sha":"0123456789abcdef0123456789abcdef01234567"}}'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/branches/main/protection/required_status_checks" ]]; then
	if [[ "${GH_TEST_MODE:-}" == "protection-not-enabled" ]]; then
		printf '%s\n' 'gh: Required status checks not enabled (HTTP 404)' >&2
		exit 1
	fi
	if [[ "${GH_TEST_MODE:-}" == "protection-error" ]]; then
		printf '%s\n' 'gh: Resource not accessible (HTTP 403)' >&2
		exit 1
	fi
	if [[ "${GH_TEST_MODE:-}" == protection-admin-only* ]]; then
		printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
		exit 1
	fi
	if [[ "${GH_TEST_MODE:-}" == "required-protection" ]]; then
		printf '%s\n' '{"contexts":["Format"]}'
	else
		printf '%s\n' '{"contexts":[],"checks":[]}'
	fi
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/branches/main" ]]; then
	case "${GH_TEST_MODE:-}" in
	protection-admin-only) printf '%s\n' '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["review-bot-gate","Complexity Analysis","maintainer-gate"]}}}' ;;
	protection-admin-only-unprotected) printf '%s\n' '{"protected":false}' ;;
	*) exit 1 ;;
	esac
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/rules/branches/main" ]]; then
	if [[ "${GH_TEST_MODE:-}" == "required-ruleset" ]]; then
		printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Lint"}]}}]'
	else
		printf '%s\n' '[]'
	fi
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ "${GH_TEST_MODE:-}" == "qlty-billing" ]]; then
		jq -nc --arg name "${GH_TEST_CHECK_NAME:-qlty check}" --arg description "${GH_TEST_DESCRIPTION:-Qlty did not run because you are out of minutes.}" '
			{data:{node:{__typename:"PullRequest",statusCheckRollup:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:[
				{__typename:"StatusContext",context:$name,state:"ERROR",targetUrl:"https://example.invalid/qlty",createdAt:"2026-08-01T00:00:00Z",description:$description,isRequired:true},
				{__typename:"StatusContext",context:"Lint",state:"SUCCESS",targetUrl:"",createdAt:"2026-08-01T00:00:00Z",description:"",isRequired:true}
			],pageInfo:{hasNextPage:false,endCursor:null}}}}}]}},rateLimit:{cost:1}}}'
		exit 0
	fi
	if [[ "${GH_TEST_MODE:-no-required}" == "api-error" ]]; then
		printf '%s\n' 'HTTP 503: service unavailable' >&2
		exit 1
	fi
	printf '%s\n' '{"data":{"node":{"__typename":"PullRequest","statusCheckRollup":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"optional","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]}},"rateLimit":{"cost":1}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${live_bin}/gh"

for repo_kind in private organisation personal unavailable malformed; do
	set +e
	billing_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=qlty-billing GH_TEST_REPO_KIND="$repo_kind" \
		AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" wait 123 --repo example/repo --all --timeout 0 2>&1)
	billing_rc=$?
	set -e
	case "$repo_kind" in
	private | organisation)
		assert_eq "$repo_kind billing exits successfully" 0 "$billing_rc"
		assert_contains "$repo_kind reports skipped status and link" 'SKIPPED (qlty out of credits): qlty check https://example.invalid/qlty' "$billing_output"
		assert_contains "$repo_kind uses normalized counts" 'pass=1 skipping=1' "$billing_output"
		;;
	*)
		assert_eq "$repo_kind billing remains a terminal failure" 1 "$billing_rc"
		[[ "$billing_output" != *'SKIPPED ('* ]] && pass "$repo_kind does not skip" || fail "$repo_kind does not skip"
		;;
	esac
	if [[ "$repo_kind" == personal ]]; then
		assert_contains "public personal billing is unexpected" 'NOTE: unexpected qlty out-of-credits failure on a public personal-account repository' "$billing_output"
	fi
done

for check_name in 'QLTY CHECK' 'Qlty Regression Gate'; do
	set +e
	name_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=qlty-billing GH_TEST_REPO_KIND=organisation GH_TEST_CHECK_NAME="$check_name" \
		GH_TEST_DESCRIPTION='OUT OF CREDITS' AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" wait 123 --repo example/repo --all --timeout 0 2>&1)
	name_rc=$?
	set -e
	if [[ "$check_name" == 'QLTY CHECK' ]]; then
		assert_eq "case-insensitive qlty credit status skips" 0 "$name_rc"
	else
		assert_eq "Actions regression gate is never skipped" 1 "$name_rc"
	fi
done

set +e
code_failure_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=qlty-billing GH_TEST_REPO_KIND=private \
	GH_TEST_DESCRIPTION='Lint violations found' AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" wait 123 --repo example/repo --all --timeout 0 2>&1)
code_failure_rc=$?
set -e
assert_eq "non-billing qlty failure stays terminal" 1 "$code_failure_rc"
assert_contains "non-billing qlty is listed in failure details" 'qlty check: fail' "$code_failure_output"

billing_transition_dir="${TMPDIR_TEST}/billing-transition"
write_fixture "$billing_transition_dir" 1 '[{"name":"qlty check","state":"ERROR","bucket":"fail","description":"out of minutes","link":"https://example.invalid/qlty"},{"name":"Lint","state":"PENDING","bucket":"pending"}]'
write_fixture "$billing_transition_dir" 2 '[{"name":"qlty check","state":"ERROR","bucket":"fail","description":"out of minutes","link":"https://example.invalid/qlty"},{"name":"Lint","state":"SUCCESS","bucket":"pass"}]'
billing_metadata_log="${TMPDIR_TEST}/billing-metadata"
billing_transition_output=$(PATH="${live_bin}:$PATH" GH_TEST_REPO_KIND=organisation GH_TEST_METADATA_LOG="$billing_metadata_log" \
	run_fixture_wait "$billing_transition_dir" --all)
assert_eq "billing metadata is cached across polls" read "$(<"$billing_metadata_log")"
billing_note_count=$(printf '%s\n' "$billing_transition_output" | grep -c '^SKIPPED (' || true)
assert_eq "billing skip is printed once across polls" 1 "$billing_note_count"
assert_contains "other pending checks must finish" '+ Lint: pending -> pass' "$billing_transition_output"

# GH#34790: qlty-skips names only policy-classified skips, for the merge note.
for repo_kind in organisation personal; do
	set +e
	skips_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=qlty-billing GH_TEST_REPO_KIND="$repo_kind" \
		AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" qlty-skips 123 --repo example/repo 2>/dev/null)
	skips_rc=$?
	set -e
	assert_eq "$repo_kind qlty-skips exits successfully" 0 "$skips_rc"
	if [[ "$repo_kind" == organisation ]]; then
		assert_eq "organisation qlty-skips names check and link" $'qlty check\thttps://example.invalid/qlty' "$skips_output"
	else
		assert_eq "personal qlty-skips reports no skip" "" "$skips_output"
	fi
done
set +e
skips_findings_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=qlty-billing GH_TEST_REPO_KIND=organisation \
	GH_TEST_DESCRIPTION='Lint violations found' AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" qlty-skips 123 --repo example/repo 2>/dev/null)
set -e
assert_eq "qlty findings are never reported as skips" "" "$skips_findings_output"
set +e
PATH="${live_bin}:$PATH" GH_TEST_MODE=api-error AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" qlty-skips 123 --repo example/repo >/dev/null 2>&1
skips_error_rc=$?
set -e
assert_eq "unobservable checks make qlty-skips indeterminate" 2 "$skips_error_rc"

live_no_required_output=$(PATH="${live_bin}:$PATH" AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
assert_contains "canonical no-required message is explicit terminal success" "PASS: verified no required checks; optional checks were not evaluated" "$live_no_required_output"
live_draft_output=$(PATH="${live_bin}:$PATH" GH_TEST_DRAFT=true AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
assert_contains "live draft metadata warns" "NOTE: PR is draft;" "$live_draft_output"
assert_contains "live draft checks preserve success" "PASS: verified no required checks" "$live_draft_output"
[[ "$live_no_required_output" != *'NOTE: PR is draft;'* ]] && pass "live non-draft metadata has no warning" || fail "live non-draft metadata has no warning"

for policy_mode in required-protection required-ruleset; do
	set +e
	policy_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE="$policy_mode" AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
		"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
	policy_rc=$?
	set -e
	[[ "$policy_rc" -eq 8 ]] && pass "$policy_mode: unreported context remains pending" || fail "$policy_mode: unreported context remains pending" "got ${policy_rc}"
done

not_enabled_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=protection-not-enabled AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
assert_contains "protection 404 'not enabled' is verified no-required" "PASS: verified no required checks" "$not_enabled_output"

set +e
protection_error_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=protection-error AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
protection_error_rc=$?
set -e
[[ "$protection_error_rc" -ne 0 ]] && pass "unreadable protection stays non-clear" || fail "unreadable protection stays non-clear" "$protection_error_output"

# GH#40626: fixture polls with the live policy read, as a write-access session
# sees it (the admin-only protection endpoint 404s).
live_policy_env=(PATH="${live_bin}:$PATH" AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1
	AIDEVOPS_GH_CHECKS_TEST_HEAD=fixture-head AIDEVOPS_GH_CHECKS_TEST_DRAFT=false AIDEVOPS_GH_CHECKS_TEST_PR_STATE=OPEN)
live_policy_wait=("$HELPER" wait 123 --repo example/repo --initial-interval 1 --max-interval 4)
late_dir="${TMPDIR_TEST}/late-registration"
write_fixture "$late_dir" 1 '[]'
write_fixture "$late_dir" 2 '[{"name":"maintainer-gate","workflow":"Maintainer Gate","state":"SUCCESS","bucket":"pass","link":""}]'
write_fixture "$late_dir" 3 '[{"name":"maintainer-gate","workflow":"Maintainer Gate","state":"SUCCESS","bucket":"pass","link":""},{"name":"Complexity Analysis","workflow":"Code Quality","state":"PENDING","bucket":"pending","link":"https://example.invalid/ca"},{"name":"review-bot-gate","workflow":"","state":"PENDING","bucket":"pending","link":""}]'
write_fixture "$late_dir" 4 '[{"name":"maintainer-gate","workflow":"Maintainer Gate","state":"SUCCESS","bucket":"pass","link":""},{"name":"Complexity Analysis","workflow":"Code Quality","state":"SUCCESS","bucket":"pass","link":"https://example.invalid/ca"},{"name":"review-bot-gate","workflow":"","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
late_output=$(env "${live_policy_env[@]}" GH_TEST_MODE=protection-admin-only AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$late_dir" \
	"${live_policy_wait[@]}" 2>&1)
late_rc=$?
set -e
assert_eq "late-registering required contexts end in success" "0" "$late_rc"
assert_contains "branch endpoint supplies required contexts without admin" "CI wait started: none=0 missing=Complexity Analysis, maintainer-gate, review-bot-gate" "$late_output"
late_partial="${late_output%%+ Complexity Analysis: added as pending*}"
[[ "$late_partial" != "$late_output" ]] && pass "late contexts register after the partial set" || fail "late contexts register after the partial set" "$late_output"
assert_not_contains "partial maintainer-gate-only set is not success" "PASS:" "$late_partial"
assert_contains "success follows the full required set" "PASS: required checks completed" "${late_output#"$late_partial"}"

partial_only_dir="${TMPDIR_TEST}/partial-only"
write_fixture "$partial_only_dir" 1 '[{"name":"maintainer-gate","workflow":"Maintainer Gate","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
unknown_policy_output=$(env "${live_policy_env[@]}" GH_TEST_MODE=protection-error AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$partial_only_dir" \
	"${live_policy_wait[@]}" --timeout 0 2>&1)
unknown_policy_rc=$?
settled_policy_output=$(env "${live_policy_env[@]}" GH_TEST_MODE=protection-error AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$partial_only_dir" \
	AIDEVOPS_GH_CHECKS_EMPTY_SETTLE_SECONDS=0 "${live_policy_wait[@]}" --timeout 0 2>&1)
settled_policy_rc=$?
unprotected_output=$(env "${live_policy_env[@]}" GH_TEST_MODE=protection-admin-only-unprotected AIDEVOPS_GH_CHECKS_FIXTURE_DIR="$partial_only_dir" \
	"${live_policy_wait[@]}" --timeout 0 2>&1)
unprotected_rc=$?
set -e
assert_eq "unknown policy holds a passing partial set inside the settle window" "8" "$unknown_policy_rc"
assert_not_contains "unknown policy partial set prints no success" "PASS:" "$unknown_policy_output"
assert_eq "unknown policy passing set succeeds after the settle window" "0" "$settled_policy_rc"
assert_contains "settled unknown policy reports success" "PASS: required checks completed" "$settled_policy_output"
assert_eq "branch endpoint verified-unprotected passing set succeeds at once" "0" "$unprotected_rc"

set +e
live_api_error_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=api-error AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 0 2>&1)
live_api_error_rc=$?
set -e
[[ "$live_api_error_rc" -eq 2 ]] && pass "exact-read API error remains indeterminate" || fail "exact-read API error remains indeterminate" "got ${live_api_error_rc}"
assert_contains "exact-read API error is diagnosed" "attempted GitHub/API read failed" "$live_api_error_output"

deferral_count_file="${TMPDIR_TEST}/deferral-count"
deferral_sleep_log="${TMPDIR_TEST}/deferral-sleeps"
: >"$deferral_count_file"
: >"$deferral_sleep_log"
deferral_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=local-deferral-once GH_TEST_CALL_COUNT="$deferral_count_file" \
	AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_CHECKS_TEST_NOW_EPOCH=1000 \
	AIDEVOPS_GH_CHECKS_TEST_SLEEP_LOG="$deferral_sleep_log" AIDEVOPS_GH_CHECKS_DEFERRAL_JITTER_SECONDS=0 \
	AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 "$HELPER" wait 123 --repo example/repo --timeout 30 2>&1)
assert_contains "local admission emits one actionable transition" "deferred by local-admission until epoch 1010" "$deferral_output"
assert_contains "local admission recovery is explicit" "GitHub check observation recovered" "$deferral_output"
assert_eq "local admission sleeps to the known deadline" "10" "$(<"$deferral_sleep_log")"
deferral_message_count=$(printf '%s\n' "$deferral_output" | grep -c 'deferred by local-admission' || true)
[[ "$deferral_message_count" -eq 1 ]] && pass "local admission warning is not repeated" || fail "local admission warning is not repeated" "count ${deferral_message_count}"

: >"$deferral_count_file"
set +e
beyond_timeout_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=local-deferral GH_TEST_CALL_COUNT="$deferral_count_file" \
	AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_CHECKS_TEST_NOW_EPOCH=1000 \
	AIDEVOPS_GH_CHECKS_DEFERRAL_JITTER_SECONDS=0 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 5 2>&1)
beyond_timeout_rc=$?
set -e
[[ "$beyond_timeout_rc" -eq 2 ]] && pass "deadline beyond timeout is indeterminate" || fail "deadline beyond timeout is indeterminate" "got ${beyond_timeout_rc}"
assert_contains "deadline beyond timeout is explicit" "beyond the remaining 5s timeout" "$beyond_timeout_output"

: >"$deferral_count_file"
set +e
equal_timeout_output=$(PATH="${live_bin}:$PATH" GH_TEST_MODE=local-deferral-once GH_TEST_CALL_COUNT="$deferral_count_file" \
	GH_TEST_RETRY_AT=1005 AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP=1 AIDEVOPS_GH_CHECKS_TEST_NOW_EPOCH=1000 \
	AIDEVOPS_GH_CHECKS_DEFERRAL_JITTER_SECONDS=0 AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1 \
	"$HELPER" wait 123 --repo example/repo --timeout 5 2>&1)
equal_timeout_rc=$?
set -e
[[ "$equal_timeout_rc" -eq 2 ]] && pass "deadline at timeout is indeterminate" || fail "deadline at timeout is indeterminate" "got ${equal_timeout_rc}"
assert_eq "deadline at timeout performs no follow-up identity read" "1" "$(<"$deferral_count_file")"
assert_contains "deadline at timeout is explicit" "beyond the remaining 5s timeout" "$equal_timeout_output"

mixed_skipping_dir="${TMPDIR_TEST}/mixed-skipping"
write_fixture "$mixed_skipping_dir" 1 '[{"name":"Required","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""},{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
mixed_skipping_output=$(run_fixture_wait "$mixed_skipping_dir")
assert_contains "pass plus skipping is terminal success" "PASS: required checks completed" "$mixed_skipping_output"

skipping_only_dir="${TMPDIR_TEST}/skipping-only"
write_fixture "$skipping_only_dir" 1 '[{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
skipping_only_output=$(run_fixture_wait "$skipping_only_dir")
assert_contains "skipping-only checks are terminal success" "PASS: required checks completed" "$skipping_only_output"

set +e
head_unavailable_output=$(AIDEVOPS_GH_CHECKS_TEST_HEAD_OVERRIDE='' run_fixture_wait "$empty_dir" 2>&1)
head_unavailable_rc=$?
set -e
[[ "$head_unavailable_rc" -eq 2 ]] && pass "unverified PR head is indeterminate" || fail "unverified PR head is indeterminate" "got ${head_unavailable_rc}"
assert_contains "unverified PR head is diagnosed" "PR head could not be verified" "$head_unavailable_output"

failure_dir="${TMPDIR_TEST}/failure"
write_fixture "$failure_dir" 1 '[{"name":"ShellCheck","workflow":"CI","state":"FAILURE","bucket":"fail","link":"https://example.invalid/failure"}]'
set +e
failure_output=$(run_fixture_wait "$failure_dir" 2>&1)
failure_rc=$?
set -e
[[ "$failure_rc" -eq 1 ]] && pass "terminal failure returns one" || fail "terminal failure returns one" "got ${failure_rc}"
assert_contains "terminal failure names failed check" "ShellCheck: fail" "$failure_output"
failure_link_count=$(printf '%s\n' "$failure_output" | grep -c 'https://example.invalid/failure' || true)
[[ "$failure_link_count" -eq 1 ]] && pass "failure link is emitted once" || fail "failure link is emitted once" "count ${failure_link_count}"

other_failure_dir="${TMPDIR_TEST}/other-failures"
write_fixture "$other_failure_dir" 1 '[{"name":"Cancelled","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":""},{"name":"Unexpected","workflow":"CI","state":"UNKNOWN","bucket":"mystery","link":""},{"name":"Optional","workflow":"CI","state":"SKIPPED","bucket":"skipping","link":""}]'
set +e
other_failure_output=$(run_fixture_wait "$other_failure_dir" 2>&1)
other_failure_rc=$?
set -e
[[ "$other_failure_rc" -eq 1 ]] && pass "cancel and unknown buckets return one" || fail "cancel and unknown buckets return one" "got ${other_failure_rc}"
assert_contains "cancelled check is reported" "Cancelled: cancel" "$other_failure_output"
assert_contains "unknown bucket is reported" "Unexpected: mystery" "$other_failure_output"
skipping_detail_count=$(printf '%s\n' "$other_failure_output" | grep -c '^  Optional: skipping$' || true)
[[ "$skipping_detail_count" -eq 1 ]] && pass "skipped check is omitted from failure details" || fail "skipped check is omitted from failure details" "count ${skipping_detail_count}"

# GH#35830: a concurrency-cancelled check is pending until superseded or grace ends.
cancel_super_dir="${TMPDIR_TEST}/cancel-superseded"
write_fixture "$cancel_super_dir" 1 '[{"name":"Build","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":""}]'
write_fixture "$cancel_super_dir" 2 '[{"name":"Build","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
cancel_super_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=180 run_fixture_wait "$cancel_super_dir" 2>&1)
cancel_super_rc=$?
set -e
[[ "$cancel_super_rc" -eq 0 ]] && pass "superseded cancel is not terminal" || fail "superseded cancel is not terminal" "got ${cancel_super_rc}"
assert_contains "superseded cancel ends with pass" "PASS: required checks completed" "$cancel_super_output"

# Exercise the real fetch -> canonicalize -> grace path with timestamp-only
# attempt changes. One second per epoch read makes the first window expire
# exactly when the second cancellation arrives, without wall-clock sleeps.
cancel_attempt_dir="${TMPDIR_TEST}/cancel-attempts"
write_fixture "$cancel_attempt_dir" 1 '[{"name":"Build","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":"","startedAt":"2026-10-28T12:00:00Z","completedAt":"2026-10-28T12:01:00Z"}]'
write_fixture "$cancel_attempt_dir" 2 '[{"name":"Build","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":"","startedAt":"2026-10-28T12:02:00Z","completedAt":"2026-10-28T12:03:00Z"}]'
write_fixture "$cancel_attempt_dir" 3 '[{"name":"Build","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
cancel_attempt_output=$(
	export CANCEL_CLOCK_FILE="${TMPDIR_TEST}/cancel-clock"
	date() {
		local format="${1:-}" epoch=100
		if [[ "$format" == '+%s' ]]; then
			[[ ! -s "$CANCEL_CLOCK_FILE" ]] || epoch=$(<"$CANCEL_CLOCK_FILE")
			printf '%s\n' "$((epoch + 1))" >"$CANCEL_CLOCK_FILE"
			printf '%s\n' "$epoch"
		else
			command date "$@"
		fi
		return 0
	}
	export -f date
	AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=1 run_fixture_wait "$cancel_attempt_dir" --timeout 10 --heartbeat 1
)
cancel_attempt_rc=$?
set -e
assert_eq "timestamp-only cancelled attempt receives a fresh grace window" "0" "$cancel_attempt_rc"
assert_contains "timestamp-only attempt can reach its passing replacement" "PASS: required checks completed" "$cancel_attempt_output"
assert_contains "attempt metadata does not postpone unchanged-state heartbeat" "heartbeat: required checks unchanged" "$cancel_attempt_output"
cancel_attempt_transitions=$(printf '%s\n' "$cancel_attempt_output" | grep '^+' || true)
assert_eq "attempt timestamps do not emit spurious state transitions" "+ Build: cancel -> pass" "$cancel_attempt_transitions"

cancel_final_dir="${TMPDIR_TEST}/cancel-final"
write_fixture "$cancel_final_dir" 1 '[{"name":"Build","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":""}]'
set +e
cancel_final_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=0 run_fixture_wait "$cancel_final_dir" 2>&1)
cancel_final_rc=$?
set -e
[[ "$cancel_final_rc" -eq 1 ]] && pass "unsuperseded cancel is terminal after grace" || fail "unsuperseded cancel is terminal after grace" "got ${cancel_final_rc}"

# A same-workflow, same-name pass on the head supersedes a later cancel in one read.
cancel_sibling_dir="${TMPDIR_TEST}/cancel-sibling-pass"
write_fixture "$cancel_sibling_dir" 1 '[{"name":"Gate","workflow":"Review Bot Gate","state":"SUCCESS","bucket":"pass","link":"run-a","startedAt":"2026-11-25T14:33:09Z"},{"name":"Gate","workflow":"Review Bot Gate","state":"CANCELLED","bucket":"cancel","link":"run-b","startedAt":"2026-11-25T14:39:53Z"}]'
set +e
cancel_sibling_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=0 run_fixture_wait "$cancel_sibling_dir" 2>&1)
cancel_sibling_rc=$?
set -e
assert_eq "cancel beside same-name pass is superseded" "0" "$cancel_sibling_rc"
assert_contains "superseded sibling cancel ends with pass" "PASS: required checks completed" "$cancel_sibling_output"

cancel_sibling_fail_dir="${TMPDIR_TEST}/cancel-sibling-pass-fail"
write_fixture "$cancel_sibling_fail_dir" 1 '[{"name":"Gate","workflow":"Review Bot Gate","state":"SUCCESS","bucket":"pass","link":"run-a","startedAt":"2026-11-25T14:33:09Z"},{"name":"Gate","workflow":"Review Bot Gate","state":"CANCELLED","bucket":"cancel","link":"run-b","startedAt":"2026-11-25T14:39:53Z"},{"name":"Test","workflow":"CI","state":"FAILURE","bucket":"fail","link":""}]'
set +e
cancel_sibling_fail_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=0 run_fixture_wait "$cancel_sibling_fail_dir" 2>&1)
cancel_sibling_fail_rc=$?
set -e
assert_eq "real failure beside superseded cancel stays terminal" "1" "$cancel_sibling_fail_rc"
assert_contains "real failure beside superseded cancel is reported" "Test: fail" "$cancel_sibling_fail_output"

# GH#38537: with other checks still pending, the replacement run may be queued;
# even a zero grace must not turn the cancellation terminal before they settle.
cancel_queued_dir="${TMPDIR_TEST}/cancel-queued"
write_fixture "$cancel_queued_dir" 1 '[{"name":"Gate","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":"run-old"},{"name":"Lint","workflow":"CI","state":"IN_PROGRESS","bucket":"pending","link":""}]'
write_fixture "$cancel_queued_dir" 2 '[{"name":"Gate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":"run-new"},{"name":"Lint","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
set +e
cancel_queued_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=0 run_fixture_wait "$cancel_queued_dir" 2>&1)
cancel_queued_rc=$?
set -e
assert_eq "cancel beside pending checks waits for its queued replacement" "0" "$cancel_queued_rc"
assert_contains "queued replacement reaches pass" "PASS: required checks completed" "$cancel_queued_output"

cancel_mixed_dir="${TMPDIR_TEST}/cancel-mixed-pending"
write_fixture "$cancel_mixed_dir" 1 '[{"name":"Gate","workflow":"CI","state":"CANCELLED","bucket":"cancel","link":""},{"name":"Test","workflow":"CI","state":"FAILURE","bucket":"fail","link":""},{"name":"Lint","workflow":"CI","state":"IN_PROGRESS","bucket":"pending","link":""}]'
set +e
cancel_mixed_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=180 run_fixture_wait "$cancel_mixed_dir" 2>&1)
cancel_mixed_rc=$?
set -e
assert_eq "real failure beside cancel and pending stays terminal" "1" "$cancel_mixed_rc"
assert_contains "real failure is reported" "Test: fail" "$cancel_mixed_output"

# Exercise timer transitions deterministically without adding a test clock.
cancel_timer_output=$(
	# shellcheck source=../gh-checks-wait-helper.sh
	source "$HELPER" help >/dev/null
	_GCW_CANCEL_GRACE_SECONDS=180
	cancel_a='[{"name":"A","workflow":"CI","bucket":"cancel","link":"run-a"}]'
	cancel_b='[{"name":"B","workflow":"CI","bucket":"cancel","link":"run-b"}]'
	apply_cancel_grace failure "$cancel_a" 100
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_a" 280
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_b" 281
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_b" 400
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_b" 461
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace pending '[]' 462
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	# Same check, null link, different attempt (distinct timestamps): new window.
	cancel_c1='[{"name":"C","workflow":"CI","bucket":"cancel","link":"","startedAt":"t1","completedAt":"t2"}]'
	cancel_c2='[{"name":"C","workflow":"CI","bucket":"cancel","link":"","startedAt":"t3","completedAt":"t4"}]'
	apply_cancel_grace failure "$cancel_c1" 500
	apply_cancel_grace failure "$cancel_c2" 700
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	# GH#38537: an elapsed window is cleared while another check is pending;
	# the next window starts when nothing else is pending.
	cancel_d_pending='[{"name":"D","workflow":"CI","bucket":"cancel","link":"run-d"},{"name":"E","workflow":"CI","bucket":"pending","link":""}]'
	cancel_d_settled='[{"name":"D","workflow":"CI","bucket":"cancel","link":"run-d"},{"name":"E","workflow":"CI","bucket":"pass","link":""}]'
	apply_cancel_grace failure "$cancel_d_pending" 1000
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_d_settled" 1500
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
	apply_cancel_grace failure "$cancel_d_settled" 1680
	printf '%s:%s\n' "$_GCW_GRACED_CLASSIFICATION" "$_GCW_CANCEL_FIRST_EPOCH"
)
assert_eq "grace follows the cancelled set without extending unchanged cancellations" \
	$'pending:100\nfailure:100\npending:281\npending:281\nfailure:281\npending:\npending:700\npending:\npending:1500\nfailure:1500' "$cancel_timer_output"

for invalid_grace in '' 08 180s -1 86401 999999999999999999999999; do
	set +e
	invalid_grace_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS="$invalid_grace" run_fixture_wait "$cancel_final_dir" --timeout 0 2>&1)
	invalid_grace_rc=$?
	set -e
	assert_eq "invalid cancellation grace ${invalid_grace} is rejected" "1" "$invalid_grace_rc"
	assert_contains "invalid cancellation grace ${invalid_grace} has configuration diagnostic" \
		"AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS must be a decimal integer" "$invalid_grace_output"
done

set +e
cancel_pending_output=$(AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=86400 run_fixture_wait "$cancel_final_dir" --timeout 0 2>&1)
cancel_pending_rc=$?
set -e
assert_eq "valid grace keeps cancellation pending" "8" "$cancel_pending_rc"
assert_contains "valid grace times out rather than failing" "TIMEOUT:" "$cancel_pending_output"

recovery_dir="${TMPDIR_TEST}/recovery"
write_fixture "$recovery_dir" 1 'not-json'
write_fixture "$recovery_dir" 2 '[{"name":"Recovered","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
recovery_output=$(run_fixture_wait "$recovery_dir" 2>&1)
assert_contains "malformed evidence is visible" "required-check evidence was malformed" "$recovery_output"
assert_contains "API recovery is visible" "API state recovered" "$recovery_output"
assert_contains "API recovery can reach success" "PASS: required checks completed" "$recovery_output"

timeout_dir="${TMPDIR_TEST}/timeout"
write_fixture "$timeout_dir" 1 '[{"name":"Slow","workflow":"CI","state":"PENDING","bucket":"pending","link":""}]'
set +e
timeout_output=$(run_fixture_wait "$timeout_dir" --timeout 0 2>&1)
timeout_rc=$?
set -e
[[ "$timeout_rc" -eq 8 ]] && pass "pending timeout preserves gh pending exit" || fail "pending timeout preserves gh pending exit" "got ${timeout_rc}"
assert_contains "pending timeout remains diagnostic" "TIMEOUT: required checks remain non-terminal" "$timeout_output"

heartbeat_dir="${TMPDIR_TEST}/heartbeat"
heartbeat_file="${TMPDIR_TEST}/heartbeat/state"
mkdir -p "$(dirname "$heartbeat_file")"
write_fixture "$heartbeat_dir" 1 '[{"name":"Immediate","workflow":"CI","state":"SUCCESS","bucket":"pass","link":""}]'
AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE="$heartbeat_file" run_fixture_wait "$heartbeat_dir" >/dev/null
[[ -s "$heartbeat_file" ]] && pass "wait updates out-of-context runtime heartbeat" || fail "wait updates out-of-context runtime heartbeat"

# t19045: a headless worker that omits --timeout gets the bounded worker chunk.
headless_note="NOTE: headless worker default --timeout"
set +e
headless_default_output=$(unset AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS
	FULL_LOOP_HEADLESS=true AIDEVOPS_GH_CHECKS_HEADLESS_TIMEOUT_SECONDS=0 \
		run_fixture_wait "$timeout_dir" 2>&1)
headless_default_rc=$?
headless_explicit_output=$(unset AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS
	AIDEVOPS_HEADLESS=1 AIDEVOPS_GH_CHECKS_HEADLESS_TIMEOUT_SECONDS=0 \
		run_fixture_wait "$timeout_dir" --timeout 0 2>&1)
headless_explicit_rc=$?
set -e
assert_eq "headless default timeout bounds a pending wait" "8" "$headless_default_rc"
assert_contains "headless default timeout is announced" "${headless_note} 0s" "$headless_default_output"
assert_eq "explicit timeout still applies under headless" "8" "$headless_explicit_rc"
assert_not_contains "explicit timeout is not replaced under headless" "$headless_note" "$headless_explicit_output"
interactive_default_output=$(unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS \
	AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS
	run_fixture_wait "$heartbeat_dir" 2>&1)
assert_not_contains "interactive wait keeps the long default" "$headless_note" "$interactive_default_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
