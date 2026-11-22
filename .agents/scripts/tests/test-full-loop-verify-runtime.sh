#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#39639: verify-runtime records runtime-verified
# evidence for a non-author verifier, every refusal precedes every write, and
# hold-for-review is lifted only for a trusted runtime-pending-only scope
# recorded for the current label application.

set -uo pipefail

TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
SCRIPT_DIR_TEST="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
unset HEADLESS FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS CLAUDE_HEADLESS \
	GITHUB_ACTIONS WORKER_ISSUE_NUMBER WORKER_REPO_SLUG

print_error() { printf 'ERROR %s\n' "$1" >&2; return 0; }
print_info() { printf 'INFO %s\n' "$1" >&2; return 0; }
print_warning() { printf 'WARN %s\n' "$1" >&2; return 0; }
print_success() { printf 'OK %s\n' "$1" >&2; return 0; }
detect_session_origin() { printf 'interactive\n'; return 0; }
git() { "$TEST_NATIVE_GIT" "$@"; return $?; }

check() {
	local name="$1"
	local condition_rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$condition_rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../full-loop-helper-risk.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-risk.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-commit.sh"
# shellcheck disable=SC2312
eval "$(sed -n '/^_merge_closing_refs_have_repository() {/,/^}/p;/^_merge_linked_issue_numbers() {/,/^}/p;/^_merge_linked_cross_repo_references() {/,/^}/p' \
	"${SCRIPT_DIR_TEST}/full-loop-helper-merge.sh")"
# shellcheck source=../full-loop-helper-verify-runtime.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-verify-runtime.sh"

REPO_DIR="${TEST_ROOT}/repo"
git init -q "$REPO_DIR" && cd "$REPO_DIR" || exit 1
git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init || exit 1
LOCAL_HEAD=$(git rev-parse HEAD)
OTHER_HEAD="0123456789abcdef0123456789abcdef01234567"
WRITES="${TEST_ROOT}/writes.log"
ASSOCIATIONS="${TEST_ROOT}/associations.log"
PR_READS="${TEST_ROOT}/pr-reads"
LABELED_AT="2026-11-21T00:00:00Z"
DEFAULT_CLOSING='[{"number":42,"repository":{"owner":{"login":"owner"},"name":"repo"}}]'

pending_reason="runner has no Stripe sandbox; unit tests pass"
PENDING_BODY=$(_build_pr_body "42" "Credential rotation" "$pending_reason" "src/auth.sh" \
	"<!-- aidevops:sig -->" "Resolves" "Critical" "runtime-pending")
SELF_BODY=$(_build_pr_body "42" "Docs" "read the diff" "README.md" \
	"<!-- aidevops:sig -->" "Resolves" "Low" "self-assessed")
# commit-and-pr refuses to generate a Critical self-assessed body, so this is
# the hand-edited form that merge refuses and verify-runtime must repair.
SELF_CRITICAL_BODY=$(printf '%s' "$PENDING_BODY" |
	sed 's/^- \*\*Verification:\*\* runtime-pending —/- **Verification:** self-assessed —/')
EVIDENCE="Ran the rotation CLI against the Stripe test account; old key revoked, new key served 3 requests"
FINAL_EVIDENCE="${EVIDENCE} (verified at head ${LOCAL_HEAD:0:12} by @verifier)"

# A hold-scope record in the producer's envelope. Args: login scopes
# [association] [created_at].
marker() {
	local login="$1"
	local scopes="$2"
	local association="${3:-NONE}"
	local created="${4:-2026-11-21T00:00:05Z}"
	jq -cn --arg l "$login" --arg a "$association" --arg c "$created" \
		--arg b "$(_hold_scope_marker_body 7 owner/repo "$scopes")" \
		'[{created_at:$c, author_association:$a, user:{login:$l}, body:$b}]'
	return 0
}

label_event() {
	local created="$1"
	jq -cn --arg c "$created" '[{event:"labeled", created_at:$c, label:{name:"hold-for-review"}}]'
	return 0
}

reset_fixture() {
	FAKE_STATE="OPEN"
	FAKE_CROSS="false"
	FAKE_HEAD="$LOCAL_HEAD"
	FAKE_BODY="$PENDING_BODY"
	FAKE_LABELS="hold-for-review"
	FAKE_COMMENTS=$(marker trusted runtime-pending)
	FAKE_EVENTS=$(label_event "$LABELED_AT")
	FAKE_CLOSING="$DEFAULT_CLOSING"
	WRITE_OK=1
	PR_ONLY_RC=1
	PR_ONLY_SLUG=""
	MOVE_HEAD_ON_EDIT=0
	MOVE_HEAD_ON_UNLABEL=0
	EDIT_AT_READ=""
	PENDING_AT_READ=""
	: >"$WRITES"
	: >"$ASSOCIATIONS"
	printf '0' >"$PR_READS"
	return 0
}

fake_pr_json() {
	jq -cn --arg state "$FAKE_STATE" --argjson cross "$FAKE_CROSS" --arg head "$FAKE_HEAD" \
		--arg body "$FAKE_BODY" --arg labels "$FAKE_LABELS" --argjson closing "$FAKE_CLOSING" '{
		state:$state, isCrossRepository:$cross, headRefOid:$head, headRefName:"feature/original", author:{login:"worker-bot"},
		body:$body, labels:($labels | split(",") | map(select(. != "")) | map({name:.})),
		closingIssuesReferences:$closing}'
	return 0
}

# PR reads are counted in a file because callers read inside $(...).
# EDIT_AT_READ=N serves a maintainer-edited body from read N onward.
fake_pr_read() {
	local jq_filter="$1"
	local reads=0
	reads=$(($(<"$PR_READS") + 1))
	printf '%s' "$reads" >"$PR_READS"
	if [[ -n "$EDIT_AT_READ" && "$reads" -ge "$EDIT_AT_READ" ]]; then
		FAKE_BODY="${FAKE_BODY}"$'\n\nEdited by a maintainer after the read.'
	fi
	if [[ -n "$PENDING_AT_READ" && "$reads" -ge "$PENDING_AT_READ" ]]; then
		FAKE_BODY="$PENDING_BODY"
	fi
	if [[ -n "$jq_filter" ]]; then
		fake_pr_json | jq -r "$jq_filter"
	else
		fake_pr_json
	fi
	return 0
}

_flm_gh_read() {
	local jq_filter="" arg=""
	local -a args=("$@")
	local i=0
	while [[ "$i" -lt "${#args[@]}" ]]; do
		arg="${args[$i]}"
		[[ "$arg" == "--jq" ]] && jq_filter="${args[$((i + 1))]}"
		i=$((i + 1))
	done
	case "${args[1]}" in
	api)
		case "${args[2]}" in
		*/events) printf '%s' "$FAKE_EVENTS" ;;
		*/comments) printf '%s' "$FAKE_COMMENTS" ;;
		*) return 1 ;;
		esac
		;;
	pr) fake_pr_read "$jq_filter" ;;
	*) return 1 ;;
	esac
	return 0
}

gh_pr_edit_safe() {
	local arg="" next=""
	local -a args=("$@")
	local i=0
	while [[ "$i" -lt "${#args[@]}" ]]; do
		arg="${args[$i]}"
		next="${args[$((i + 1))]:-}"
		case "$arg" in
		--body-file)
			FAKE_BODY=$(<"$next")
			printf 'edit-body\n' >>"$WRITES"
			if [[ "$MOVE_HEAD_ON_EDIT" -eq 1 ]]; then
				FAKE_HEAD="$OTHER_HEAD"
				MOVE_HEAD_ON_EDIT=0
			fi
			;;
		--remove-label)
			FAKE_LABELS=$(printf '%s' "$FAKE_LABELS" | tr ',' '\n' | grep -vx "$next" | paste -sd, -)
			printf 'remove-label %s\n' "$next" >>"$WRITES"
			if [[ "$MOVE_HEAD_ON_UNLABEL" -eq 1 ]]; then
				FAKE_HEAD="$OTHER_HEAD"
				MOVE_HEAD_ON_UNLABEL=0
			fi
			;;
		--add-label)
			FAKE_LABELS="${FAKE_LABELS:+${FAKE_LABELS},}${next}"
			FAKE_EVENTS=$(jq -cn --argjson a "$FAKE_EVENTS" --argjson b "$(label_event 2026-11-21T00:01:00Z)" '$a + $b')
			printf 'add-label %s\n' "$next" >>"$WRITES"
			;;
		esac
		i=$((i + 1))
	done
	return 0
}

gh_pr_comment() { printf 'comment\n' >>"$WRITES"; return 0; }
_merge_resolve_repo() { printf '%s\n' "${1:-owner/repo}"; return 0; }
_issue_pr_only_contract_state() {
	local issue="$1"
	local slug="$2"
	if [[ -n "$PR_ONLY_SLUG" ]]; then
		[[ "${slug}#${issue}" == "$PR_ONLY_SLUG" ]] && return 0
		return 1
	fi
	return "$PR_ONLY_RC"
}
_gh_current_user_allows_repo_write() {
	if [[ "$WRITE_OK" -eq 1 ]]; then
		AIDEVOPS_GH_WRITE_PERMISSION_USER="verifier"
		return 0
	fi
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="insufficient-permission:read"
	return 1
}
_gh_actor_has_repo_write_authority() {
	printf '%s\n' "${3:-}" >>"$ASSOCIATIONS"
	case "$2" in
	trusted | verifier) return 0 ;;
	*) return 1 ;;
	esac
}

OUT="${TEST_ROOT}/out.log"
run_verify() {
	VR_RC=0
	cmd_verify_runtime "$@" >"$OUT" 2>&1 || VR_RC=$?
	[[ -z "${VR_TEST_DEBUG:-}" ]] || { printf -- '--- rc=%s\n' "$VR_RC"; cat "$OUT"; }
	return 0
}
no_writes() { [[ ! -s "$WRITES" ]]; }
body_level() { printf '%s' "$FAKE_BODY" | _runtime_testing_metadata_from_body | jq -r .level; }
body_evidence() { printf '%s' "$FAKE_BODY" | _runtime_testing_metadata_from_body | jq -r .evidence; }

# --- Success: non-author verifier, runtime-only scope ---
reset_fixture
run_verify 7 owner/repo --testing "$EVIDENCE"
check "verifier route succeeds" "$VR_RC"
grep -q 'VERIFY_RUNTIME_HOLD=lifted' "$OUT"
check "runtime-only hold is lifted" $?
cond_rc=1
[[ ",${FAKE_LABELS}," != *",hold-for-review,"* ]] && cond_rc=0
check "hold-for-review label removed" "$cond_rc"
cond_rc=1
[[ "$(body_level)" == "runtime-verified" ]] && cond_rc=0
check "body level is runtime-verified" "$cond_rc"
cond_rc=1
[[ "$(body_evidence)" == "$FINAL_EVIDENCE" ]] && cond_rc=0
check "evidence binds head and verifier" "$cond_rc"
metadata=$(printf '%s' "$FAKE_BODY" | _runtime_testing_metadata_from_body)
_runtime_testing_merge_refusal "$metadata" >/dev/null
check "merge recheck accepts the rewritten body" $?
cond_rc=1
[[ "$(jq -r .risk <<<"$metadata")" == "Critical" && "$FAKE_BODY" == *"Resolves #42"* ]] && cond_rc=0
check "risk and closing keyword preserved" "$cond_rc"
grep -q '^comment$' "$WRITES"
check "audit comment posted" $?
! _runtime_testing_merge_refusal "$(printf '%s' "$PENDING_BODY" | _runtime_testing_metadata_from_body)" >/dev/null
check "merge still refuses the original runtime-pending body" $?

# --- Refusals before any write ---
refuses_without_write() {
	local name="$1"
	shift
	run_verify "$@"
	[[ "$VR_RC" -ne 0 ]] && no_writes
	check "$name" $?
	return 0
}
reset_fixture; WRITE_OK=0
refuses_without_write "caller without write permission refuses" 7 --testing "$EVIDENCE"
reset_fixture; FAKE_HEAD="$OTHER_HEAD"
refuses_without_write "head mismatch refuses" 7 --testing "$EVIDENCE"
reset_fixture; FAKE_CROSS="true"
refuses_without_write "fork head refuses" 7 --testing "$EVIDENCE"
reset_fixture; FAKE_STATE="CLOSED"
refuses_without_write "closed PR refuses" 7 --testing "$EVIDENCE"
reset_fixture
refuses_without_write "bare marker evidence refuses" 7 --testing "runtime-verified"
reset_fixture
refuses_without_write "empty evidence refuses" 7 --testing ""
reset_fixture
refuses_without_write "placeholder evidence refuses" 7 --testing "none"
reset_fixture
refuses_without_write "closing keyword in evidence refuses" 7 --testing "Exercised the CLI; fixes #99"
reset_fixture
refuses_without_write "Runtime Testing heading in evidence refuses" 7 --testing $'ok\n## Runtime Testing\nx'
reset_fixture
refuses_without_write "an option in the evidence slot refuses" 7 --testing --dry-run
reset_fixture; FAKE_BODY="$SELF_BODY"
refuses_without_write "body merge already accepts refuses" 7 --testing "$EVIDENCE"
reset_fixture; FAKE_BODY=$'## Runtime Testing\n\n- **Risk level:** Low\n- **Verification:** self-assessed — x\n\n'"$PENDING_BODY"
refuses_without_write "ambiguous multi-section body refuses" 7 --testing "$EVIDENCE"
reset_fixture
WORKER_ISSUE_NUMBER=42 refuses_without_write "worker session refuses" 7 --testing "$EVIDENCE"
reset_fixture
printf 'tracked\n' >"${REPO_DIR}/f.txt" && git add f.txt
refuses_without_write "uncommitted tracked change refuses" 7 --testing "$EVIDENCE"
git rm -q --cached f.txt && rm -f "${REPO_DIR}/f.txt"
reset_fixture; EDIT_AT_READ=2
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -ne 0 ]] && ! grep -q '^edit-body' "$WRITES" && ! grep -q '^remove-label' "$WRITES"
check "body edited after the read is not overwritten" $?

# --- Hold kept: evidence recorded, label untouched ---
hold_kept() {
	local name="$1"
	run_verify 7 --testing "$EVIDENCE"
	[[ "$VR_RC" -eq 0 && ",${FAKE_LABELS}," == *",hold-for-review,"* ]] &&
		grep -q 'VERIFY_RUNTIME_HOLD=keep' "$OUT" && ! grep -q '^remove-label' "$WRITES"
	check "$name" $?
	return 0
}
reset_fixture; FAKE_COMMENTS=$(marker trusted "pr-only,runtime-pending")
hold_kept "PR-only recorded scope keeps the hold"
cond_rc=1
[[ "$(body_level)" == "runtime-verified" ]] && cond_rc=0
check "kept hold still records the runtime evidence" "$cond_rc"
reset_fixture; FAKE_COMMENTS="[]"
hold_kept "unrecorded scope keeps the hold"
reset_fixture; FAKE_COMMENTS=$(marker stranger runtime-pending)
hold_kept "untrusted marker author keeps the hold"
reset_fixture; PR_ONLY_RC=0
hold_kept "live PR-only contract keeps the hold"
reset_fixture; PR_ONLY_RC=2
hold_kept "unverifiable PR-only contract keeps the hold"
reset_fixture
FAKE_CLOSING='[{"number":42,"repository":{"owner":{"login":"owner"},"name":"repo"}},{"number":5,"repository":{"owner":{"login":"other"},"name":"tasks"}}]'
PR_ONLY_SLUG="other/tasks#5"
hold_kept "PR-only contract in another repository keeps the hold"
reset_fixture
quoted=$(jq -cn '[{created_at:"2026-11-21T00:00:09Z", author_association:"OWNER", user:{login:"trusted"},
	body:"<!-- MERGE_SUMMARY -->\nSummary quotes <!-- aidevops:hold-scope scopes=runtime-pending --> inline"}]')
FAKE_COMMENTS=$(jq -cn --argjson a "$(marker trusted "pr-only,runtime-pending")" --argjson b "$quoted" '$a + $b')
hold_kept "a marker quoted in a newer comment is not a scope record"
reset_fixture
FAKE_EVENTS=$(jq -cn --argjson a "$(label_event "$LABELED_AT")" --argjson b "$(label_event 2026-11-21T00:00:30Z)" '$a + $b')
hold_kept "a record from an earlier hold does not lift a later manual hold"
reset_fixture; FAKE_COMMENTS=$(marker trusted runtime-pending MEMBER)
run_verify 7 --testing "$EVIDENCE"
grep -qx 'CONTRIBUTOR' "$ASSOCIATIONS" && ! grep -qx 'MEMBER' "$ASSOCIATIONS" && grep -q 'VERIFY_RUNTIME_HOLD=lifted' "$OUT"
check "a MEMBER record author is confirmed by repository permission" $?

# --- Repairable verified and self-assessed bodies ---
reset_fixture
FAKE_BODY=$(printf '%s' "$PENDING_BODY" | VR_EVIDENCE="Ran it (verified at head ${OTHER_HEAD:0:12} by @someone)" \
	VR_FROM_LEVEL=runtime-pending _verify_runtime_rewrite_body)
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -eq 0 && "$(body_evidence)" == "$FINAL_EVIDENCE" ]] && grep -q '^edit-body' "$WRITES"
check "evidence for another head is re-recorded, not reused" $?
reset_fixture; FAKE_BODY="$SELF_CRITICAL_BODY"; FAKE_LABELS=""
! _runtime_testing_merge_refusal "$(printf '%s' "$FAKE_BODY" | _runtime_testing_metadata_from_body)" >/dev/null
check "merge refuses a hand-edited Critical self-assessed body" $?
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -eq 0 && "$(body_level)" == "runtime-verified" ]] && grep -q 'VERIFY_RUNTIME_HOLD=absent' "$OUT"
check "a Critical self-assessed body refused at merge is verified" $?
reset_fixture; FAKE_LABELS=""
FAKE_BODY=$(printf '%s' "$PENDING_BODY" |
	awk '/^- \*\*Verification:\*\* runtime-pending —/ {print "- **Verification:**"; print "  - nested evidence bullet"; next} {print}')
! _runtime_testing_merge_refusal "$(printf '%s' "$FAKE_BODY" | _runtime_testing_metadata_from_body)" >/dev/null
check "merge refuses a Verification line with no level (GH#39918)" $?
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -eq 0 && "$(body_level)" == "runtime-verified" && "$(body_evidence)" == "$FINAL_EVIDENCE" ]] && grep -q '^edit-body' "$WRITES"
check "a Verification line with no level and nested bullets is rewritten (GH#39918)" $?

# --- Dry run, idempotent rerun, head races ---
reset_fixture
run_verify 7 --testing "$EVIDENCE" --dry-run
[[ "$VR_RC" -eq 0 ]] && no_writes && grep -q '+ - \*\*Verification:\*\* runtime-verified' "$OUT"
check "dry run previews without writing" $?

reset_fixture
run_verify 7 --testing "$EVIDENCE"
: >"$WRITES"
FAKE_LABELS="hold-for-review"
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -eq 0 ]] && ! grep -q '^edit-body' "$WRITES" && grep -q '^remove-label' "$WRITES"
check "rerun on a verified body retries only the label" $?

reset_fixture; MOVE_HEAD_ON_EDIT=1
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -ne 0 && "$FAKE_BODY" == "$PENDING_BODY" ]] && ! grep -q '^remove-label' "$WRITES"
check "head moved during edit restores the pending body" $?

reset_fixture; MOVE_HEAD_ON_UNLABEL=1
run_verify 7 --testing "$EVIDENCE"
[[ "$VR_RC" -ne 0 && ",${FAKE_LABELS}," == *",hold-for-review,"* ]] &&
	grep -q '^add-label hold-for-review' "$WRITES" && [[ "$(tail -n 1 "$WRITES")" == "comment" ]]
check "head moved at label removal reapplies and re-records the hold" $?

# --- Hold-scope marker recording ---
reset_fixture; FAKE_COMMENTS=$(marker trusted runtime-pending)
_record_hold_scope_marker 7 owner/repo runtime-pending && no_writes
check "matching trusted marker is not reposted" $?
reset_fixture
FAKE_EVENTS=$(jq -cn --argjson a "$(label_event "$LABELED_AT")" --argjson b "$(label_event 2026-11-21T00:00:30Z)" '$a + $b')
_record_hold_scope_marker 7 owner/repo runtime-pending && grep -q '^comment$' "$WRITES"
check "a re-applied hold gets a fresh scope record" $?
reset_fixture; FAKE_COMMENTS="[]"
_record_hold_scope_marker 7 owner/repo "pr-only,runtime-pending" && grep -q '^comment$' "$WRITES"
check "new scope posts a marker" $?
! _record_hold_scope_marker 7 owner/repo 'bad scope'
check "malformed scope tokens are rejected" $?

# --- Legacy Low/Medium completion: no interactive runtime attestation ---
reset_fixture; FAKE_BODY="$SELF_BODY"
notice=$(cmd_runtime_pending_notice 7 owner/repo)
printf '%s' "$notice" | jq -e '.risk == "Low" and .level == "self-assessed"' >/dev/null
check "notice exposes parsed Low completed metadata" $?
no_writes
check "default notice remains read-only" $?
cmd_runtime_pending_notice 7 owner/repo --lift-completed >"$OUT" 2>&1
check "Low completed hold lifts" $?
[[ "$FAKE_LABELS" == "" && "$(body_level)" == self-assessed ]] && grep -q '^comment' "$WRITES"
check "legacy lift audits without claiming runtime verification" $?
for legacy_case in pending high pr-only unrecorded permission race fork no-takeover closed; do
	reset_fixture; FAKE_BODY="$SELF_BODY"
	case "$legacy_case" in
	pending) FAKE_BODY="$PENDING_BODY" ;;
	high) FAKE_BODY="$SELF_CRITICAL_BODY" ;;
	pr-only) PR_ONLY_RC=0 ;;
	unrecorded) FAKE_COMMENTS='[]' ;;
	permission) WRITE_OK=0 ;;
	race) PENDING_AT_READ=2 ;;
	fork) FAKE_CROSS=true ;;
	no-takeover) FAKE_LABELS='hold-for-review,no-takeover' ;;
	closed) FAKE_STATE=CLOSED ;;
	esac
	! cmd_runtime_pending_notice 7 owner/repo --lift-completed >"$OUT" 2>&1 &&
		! grep -q '^remove-label' "$WRITES"
	check "legacy lift refuses ${legacy_case}" $?
done
reset_fixture; FAKE_BODY="$SELF_BODY"; MOVE_HEAD_ON_UNLABEL=1
! cmd_runtime_pending_notice 7 owner/repo --lift-completed >"$OUT" 2>&1 &&
	[[ ",${FAKE_LABELS}," == *",hold-for-review,"* ]]
check "legacy head race reapplies hold" $?

# The leased local repair branch must regenerate the original PR, never a new
# repair-branch PR or a force push. GitHub and transport remain controlled stubs.
reset_fixture; FAKE_BODY="$SELF_BODY"; FAKE_LABELS='origin:worker,hold-for-review'
AIDEVOPS_PR_REPAIR_NUMBER=7
AIDEVOPS_PR_REPAIR_HEAD_REF=feature/original
AIDEVOPS_PR_REPAIR_HEAD_SHA="$LOCAL_HEAD"
skip_rebase=1
target=$(_runtime_completion_target_branch owner/repo repair/test)
[[ "$target" == feature/original ]]
check "completion maps repair checkout to original PR branch" $?
FAKE_HEAD="$OTHER_HEAD"
! _runtime_completion_target_branch owner/repo repair/test >/dev/null
check "completion target rejects a moved head" $?
FAKE_HEAD="$LOCAL_HEAD"; skip_rebase=0
! _runtime_completion_target_branch owner/repo repair/test >/dev/null
check "completion target requires no-rebase" $?
skip_rebase=1; FAKE_LABELS='origin:worker,hold-for-review,no-takeover'
! _runtime_completion_target_branch owner/repo repair/test >/dev/null
check "completion target preserves no-takeover" $?

reset_fixture; FAKE_BODY="$SELF_BODY"; FAKE_LABELS='origin:worker,hold-for-review'
AIDEVOPS_RUNTIME_PENDING_COMPLETION=1
REMOTE_CLASS=fast-forward
_classify_remote_branch() { printf '%s %s\n' "$REMOTE_CLASS" "$LOCAL_HEAD"; return 0; }
timeout() { shift; "$@"; return $?; }
git() {
	local action="${1:-}"
	if [[ "$action" == push ]]; then
		printf '%s\n' "$*" >>"$WRITES"
		return 0
	fi
	if [[ "$action" == branch && "${2:-}" == --show-current ]]; then
		printf 'repair/test\n'
		return 0
	fi
	"$TEST_NATIVE_GIT" "$@"
	return $?
}
: >"$WRITES"
_push_branch feature/original 0 owner/repo
grep -qx "push -u origin ${LOCAL_HEAD}:refs/heads/feature/original --force-with-lease=feature/original:${LOCAL_HEAD}" "$WRITES"
check "completion binds ancestry-proven head to the observed remote lease" $?
FAKE_LABELS='origin:worker,hold-for-review,no-takeover'
: >"$WRITES"
! _push_branch feature/original 0 owner/repo && no_writes
check "prepush refresh preserves newly protected ownership" $?
! _create_or_continue_pr '' owner/repo title body origin:worker >/dev/null
check "completion publication cannot create a replacement PR" $?
! _create_or_continue_pr 8 owner/repo title body origin:worker >/dev/null
check "completion publication binds the dispatched PR number" $?
for REMOTE_CLASS in foreign own-rewrite absent unknown; do
	: >"$WRITES"
	! _push_branch feature/original 0 owner/repo && no_writes
	check "completion refuses ${REMOTE_CLASS} without a replacement branch" $?
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
