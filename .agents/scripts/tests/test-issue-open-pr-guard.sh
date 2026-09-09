#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p "$STUB_BIN"

cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "pr list --repo" ]]; then
	case "${STUB_CASE:-none}" in
	missing) exit 1 ;;
	none | historical) printf '[]\n' ;;
	multiple)
		printf '[{"number":77,"headRefName":"feature/existing","headRefOid":"%s","headRepository":{"nameWithOwner":"%s"},"author":{"login":"alice"},"closingIssuesReferences":[{"number":42,"repository":{"owner":{"login":"owner"},"name":"repo"}}],"isDraft":false},{"number":78,"headRefName":"feature/other","headRefOid":"2222222222222222222222222222222222222222","headRepository":{"nameWithOwner":"owner/repo"},"author":{"login":"bob"},"closingIssuesReferences":[{"number":42,"repository":{"owner":{"login":"owner"},"name":"repo"}}],"isDraft":true}]\n' "${STUB_HEAD_SHA:-1111111111111111111111111111111111111111}" "${STUB_HEAD_REPO:-owner/repo}"
		;;
	*)
		printf '[{"number":77,"headRefName":"feature/existing","headRefOid":"%s","headRepository":{"nameWithOwner":"%s"},"author":{"login":"alice"},"closingIssuesReferences":[{"number":42,"repository":{"owner":{"login":"owner"},"name":"repo"}}],"isDraft":false}]\n' "${STUB_HEAD_SHA:-1111111111111111111111111111111111111111}" "${STUB_HEAD_REPO:-owner/repo}"
		;;
	esac
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_BIN}/gh"

# shellcheck source=../issue-open-pr-guard.sh
source "${SCRIPT_DIR_TEST}/issue-open-pr-guard.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-commit.sh"

failures=0
assert_rc() {
	local name="$1" expected="$2"
	shift 2
	local actual=0
	PATH="${STUB_BIN}:$PATH" "$@" || actual=$?
	if [[ "$actual" -eq "$expected" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s expected=%s actual=%s\n' "$name" "$expected" "$actual"
		failures=$((failures + 1))
	fi
}

check_in_repo() {
	local repo_path="$1"
	shift
	(
		cd "$repo_path" || exit 2
		issue_open_pr_guard_check "$@"
	)
}

STUB_CASE=none assert_rc 'PR-less issue is allowed' 0 issue_open_pr_guard_check 42 owner/repo feature/new '' '' 0 owner/repo
STUB_CASE=none assert_rc 'replacement cannot name a nonexistent open PR' 2 issue_open_pr_guard_check 42 owner/repo feature/new 77 'The old approach cannot satisfy the verified API contract.' 0 owner/repo
STUB_CASE=open assert_rc 'foreign open PR blocks fresh branch' 1 issue_open_pr_guard_check 42 owner/repo feature/new '' '' 0 owner/repo
STUB_CASE=open assert_rc 'same PR branch continues idempotently' 3 issue_open_pr_guard_check 42 owner/repo feature/existing '' '' 0 owner/repo alice
STUB_CASE=open assert_rc 'same repo and branch cannot impersonate another PR author' 1 issue_open_pr_guard_check 42 owner/repo feature/existing '' '' 0 owner/repo bob
STUB_CASE=open STUB_HEAD_REPO=fork/repo assert_rc 'fork PR with same ref does not impersonate local continuation' 1 issue_open_pr_guard_check 42 owner/repo feature/existing '' '' 0 owner/repo alice
STUB_CASE=open STUB_HEAD_REPO=fork/repo assert_rc 'matching fork remote continues its own PR' 3 issue_open_pr_guard_check 42 owner/repo feature/existing '' '' 0 fork/repo alice
STUB_CASE=open assert_rc 'short replacement rationale is rejected' 1 issue_open_pr_guard_check 42 owner/repo feature/new 77 short
STUB_CASE=open assert_rc 'explicit audited replacement is allowed before ancestry gate' 0 issue_open_pr_guard_check 42 owner/repo feature/new 77 'The old approach cannot satisfy the verified API contract.'
STUB_CASE=historical assert_rc 'closed historical PR does not block' 0 issue_open_pr_guard_check 42 owner/repo feature/new '' '' 0 owner/repo
STUB_CASE=missing assert_rc 'missing linkage evidence fails closed' 2 issue_open_pr_guard_check 42 owner/repo feature/new '' '' 0 owner/repo
STUB_CASE=multiple assert_rc 'multiple linked open PRs fail closed as ambiguous' 2 issue_open_pr_guard_check 42 owner/repo feature/new '' '' 0 owner/repo

GIT_FIXTURE="${TEST_ROOT}/repo"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init -q
git -C "$GIT_FIXTURE" config user.email test@example.invalid
git -C "$GIT_FIXTURE" config user.name Test
printf 'original\n' >"${GIT_FIXTURE}/original.txt"
git -C "$GIT_FIXTURE" add original.txt
git -C "$GIT_FIXTURE" commit -qm original
export STUB_HEAD_SHA
STUB_HEAD_SHA=$(git -C "$GIT_FIXTURE" rev-parse HEAD)
printf 'replacement\n' >"${GIT_FIXTURE}/replacement.txt"
git -C "$GIT_FIXTURE" add replacement.txt
git -C "$GIT_FIXTURE" commit -qm replacement
STUB_CASE=open assert_rc 'replacement preserves original head ancestry' 0 check_in_repo "$GIT_FIXTURE" 42 owner/repo feature/new 77 'The old approach cannot satisfy the verified API contract.' 1
git -C "$GIT_FIXTURE" checkout --orphan unrelated -q
git -C "$GIT_FIXTURE" rm -rf . -q
printf 'unrelated\n' >"${GIT_FIXTURE}/unrelated.txt"
git -C "$GIT_FIXTURE" add unrelated.txt
git -C "$GIT_FIXTURE" commit -qm unrelated
STUB_CASE=open assert_rc 'replacement rejects discarded original commits' 1 check_in_repo "$GIT_FIXTURE" 42 owner/repo feature/new 77 'The old approach cannot satisfy the verified API contract.' 1

guard_lines=$(grep -n '^[[:space:]]*issue_open_pr_guard_check ' "${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
initial_guard_line="${guard_lines%%$'\n'*}"
final_guard_line="${guard_lines##*$'\n'}"
stage_line=$(grep -n '^[[:space:]]*_stage_and_commit ' "${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
push_line=$(grep -n '^[[:space:]]*_push_branch ' "${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
create_line=$(grep -n '^[[:space:]]*pr_number=.*_create_or_continue_pr ' "${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
if [[ "$initial_guard_line" -lt "$stage_line" && "$push_line" -lt "$final_guard_line" && "$final_guard_line" -lt "$create_line" ]]; then
	printf 'PASS full-loop revalidates linked PRs at the final creation boundary\n'
else
	printf 'FAIL full-loop guard ordering initial=%s stage=%s push=%s final=%s create=%s\n' \
		"$initial_guard_line" "$stage_line" "$push_line" "$final_guard_line" "$create_line"
	failures=$((failures + 1))
fi

CONTINUATION_LOG="${TEST_ROOT}/continuation.log"
print_info() { return 0; }
_reconcile_pr_origin_label() { printf 'origin %s %s %s\n' "$1" "$2" "$3" >>"$CONTINUATION_LOG"; }
_reconcile_recovered_pr_metadata() { printf 'metadata %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$CONTINUATION_LOG"; }
_create_pr() { printf 'create\n' >>"$CONTINUATION_LOG"; printf '99\n'; }
: >"$CONTINUATION_LOG"
continued_pr=$(_create_or_continue_pr 77 owner/repo title body origin:interactive)
if [[ "$continued_pr" == "77" ]] &&
	grep -q '^origin 77 owner/repo interactive$' "$CONTINUATION_LOG" &&
	grep -q '^metadata 77 owner/repo title body$' "$CONTINUATION_LOG" &&
	! grep -q '^create$' "$CONTINUATION_LOG"; then
	printf 'PASS final-boundary continuation reconciles without creating a PR\n'
else
	printf 'FAIL final-boundary continuation result=%s log=%s\n' "$continued_pr" "$(tr '\n' '|' <"$CONTINUATION_LOG")"
	failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
	exit 1
fi
printf 'PASS issue open PR guard regression suite\n'
