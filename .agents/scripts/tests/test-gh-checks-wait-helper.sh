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

all_empty_output=$(run_fixture_wait "$empty_dir" --all)
assert_contains "empty all-check selection is explicit terminal success" "PASS: verified no checks reported" "$all_empty_output"

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
	if [[ "${GH_TEST_MODE:-}" == "required-protection" ]]; then
		printf '%s\n' '{"contexts":["Format"]}'
	else
		printf '%s\n' '{"contexts":[],"checks":[]}'
	fi
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

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
