#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify a protected-main rejection preserves immutable release provenance
# through an exact-head merge PR and idempotent tag reconciliation.

set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REAL_GIT=$(command -p -v git 2>/dev/null || command -v git)
REMOTE="${TEST_ROOT}/remote.git"
REPO="${TEST_ROOT}/release"
CONCURRENT="${TEST_ROOT}/concurrent"
MERGER="${TEST_ROOT}/merger"
BIN="${TEST_ROOT}/bin"
mkdir -p "$BIN"

"$REAL_GIT" init -q --bare "$REMOTE"
"$REAL_GIT" clone -q "$REMOTE" "$REPO"
"$REAL_GIT" -C "$REPO" switch -q -c main
"$REAL_GIT" -C "$REPO" config user.name Test
"$REAL_GIT" -C "$REPO" config user.email test@example.invalid
"$REAL_GIT" -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/fixture.txt"
"$REAL_GIT" -C "$REPO" add fixture.txt
"$REAL_GIT" -C "$REPO" commit -q -m seed
"$REAL_GIT" -C "$REPO" push -q -u origin main
"$REAL_GIT" --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

printf '1.2.3\n' >"${REPO}/VERSION"
"$REAL_GIT" -C "$REPO" add VERSION
"$REAL_GIT" -C "$REPO" commit -q -m 'chore(release): bump version to 1.2.3'
"$REAL_GIT" -C "$REPO" tag -a v1.2.3 -m 'Release v1.2.3 fixture'
RELEASE_COMMIT=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
TAG_OBJECT=$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.3)

"$REAL_GIT" clone -q "$REMOTE" "$CONCURRENT"
"$REAL_GIT" -C "$CONCURRENT" config user.name Test
"$REAL_GIT" -C "$CONCURRENT" config user.email test@example.invalid
printf 'concurrent\n' >"${CONCURRENT}/concurrent.txt"
"$REAL_GIT" -C "$CONCURRENT" add concurrent.txt
"$REAL_GIT" -C "$CONCURRENT" commit -q -m 'concurrent main update'
"$REAL_GIT" -C "$CONCURRENT" push -q origin main
CURRENT_MAIN=$("$REAL_GIT" -C "$CONCURRENT" rev-parse HEAD)

cat >"${BIN}/git" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GIT_LOG:?}"
args=" $* "
if [[ "$args" == *" merge-base --is-ancestor ${RELEASE_COMMIT:?} ${STALE_BRANCH_HEAD:-unset} "* && "${STALE_ANCESTRY_ERROR:-0}" == 1 ]]; then
	exit 128
fi
if [[ "$args" == *" push "* ]]; then
	printf 'repo_verify=%s %s\n' "${AIDEVOPS_PREPUSH_REPO_VERIFY:-unset}" "$*" >>"${FAKE_PUSH_ENV_LOG:?}"
fi
if [[ "$args" == *" --force-with-lease="* && "${STALE_BRANCH_RACE:-0}" == 1 ]]; then
	"${REAL_GIT:?}" --git-dir="${REMOTE:?}" update-ref \
		refs/heads/chore/release-v1.2.3-provenance "${CURRENT_MAIN:?}"
fi
if [[ "$args" == *" push --atomic origin HEAD:refs/heads/main --tags "* ]]; then
	count=0
	if [[ -f "${DIRECT_PUSH_COUNT:?}" ]]; then
		IFS= read -r count <"$DIRECT_PUSH_COUNT"
	fi
	printf '%s\n' "$((count + 1))" >"$DIRECT_PUSH_COUNT"
	printf '%s\n' \
		'remote: error: GH006: Protected branch update failed for refs/heads/main.' \
		'remote: error: Changes must be made through a pull request.' \
		'remote: error: 4 of 4 required status checks are expected.' >&2
	exit 1
fi
exec "${REAL_GIT:?}" "$@"
STUB
chmod +x "${BIN}/git"

cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
if [[ "${1:-}" == "api" && " $* " == *" repos/test/repo/pulls "* ]]; then
	if [[ -n "${STALE_BRANCH_PR_MODE:-}" ]]; then
		[[ "$STALE_BRANCH_PR_MODE" != api-failure ]] || exit 1
		# An older blocking PR on page one must not be hidden by a newer closed PR.
		jq -nc --arg mode "$STALE_BRANCH_PR_MODE" --arg head "${STALE_BRANCH_HEAD:?}" '[{
			number: 70, state: (if $mode == "open" then "open" else "closed" end),
			merged_at: (if $mode == "merged" then "2026-08-01T00:00:00Z" else null end),
			head: {sha: $head}, base: {ref: "other-base"}
		}]'
		printf '[{"number":71,"state":"closed","merged_at":null}]\n'
		exit 0
	fi
	if [[ -f "${STALE_PR_FILE:?}" && ! -f "${PR_RECREATED_FILE:?}" ]]; then
		jq -nc --arg stale_head "${STALE_PR_HEAD:?}" '[{
			number: 76,
			state: "closed",
			merged_at: "2026-08-02T00:00:00Z",
			draft: false,
			auto_merge: null,
			author_association: "OWNER",
			body: "<!-- stale protected release provenance -->",
			head: {ref: "chore/release-v1.2.3-provenance", sha: $stale_head, repo: {full_name: "test/repo"}},
			base: {ref: "main", repo: {full_name: "test/repo"}}
		}]'
		exit 0
	fi
	if [[ ! -f "${PR_CREATED_FILE:?}" ]]; then
		printf '[]\n'
		exit 0
	fi
	if [[ -f "${PR_MERGED_FILE:?}" ]]; then
		branch_sha="${RECOVERY_HEAD:?}"
	else
		branch_sha=$("${REAL_GIT:?}" ls-remote "${REMOTE:?}" \
			'refs/heads/chore/release-v1.2.3-provenance' | cut -f1)
	fi
	auto_merge=null
	pr_state=open
	merged_at=null
	if [[ -f "${PR_MERGED_FILE:?}" ]]; then
		pr_state=closed
		merged_at="${PR_MERGED_AT_JSON:-\"2026-08-03T00:00:00Z\"}"
	fi
	author_association="${PR_AUTHOR_ASSOCIATION:-OWNER}"
	[[ ! -f "${AUTO_MERGE_FILE:?}" ]] || auto_merge='{"merge_method":"merge"}'
	body="<!-- aidevops:release-provenance tag=v1.2.3 tag-object=${TAG_OBJECT:?} release-commit=${RELEASE_COMMIT:?} merge-method=merge -->"
	jq -nc --arg branch_sha "$branch_sha" --arg body "$body" \
		--arg pr_state "$pr_state" --arg author_association "$author_association" \
		--argjson merged_at "$merged_at" --argjson auto_merge "$auto_merge" '[{
			number: 77,
			state: $pr_state,
			merged_at: $merged_at,
			draft: false,
			auto_merge: $auto_merge,
			author_association: $author_association,
			user: {login: "test-owner"},
			body: $body,
			head: {ref: "chore/release-v1.2.3-provenance", sha: $branch_sha, repo: {full_name: "test/repo"}},
			base: {ref: "main", repo: {full_name: "test/repo"}}
		}]'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	if [[ -f "${STALE_PR_FILE:?}" ]]; then
		: >"${PR_RECREATED_FILE:?}"
	else
		: >"${PR_CREATED_FILE:?}"
	fi
	printf 'created\n'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
	: >"${AUTO_MERGE_FILE:?}"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "ready" ]]; then
	exit 0
fi
exit 1
STUB
chmod +x "${BIN}/gh"

export REAL_GIT REMOTE RELEASE_COMMIT TAG_OBJECT
export FAKE_GIT_LOG="${TEST_ROOT}/git.log"
export FAKE_GH_LOG="${TEST_ROOT}/gh.log"
export FAKE_PUSH_ENV_LOG="${TEST_ROOT}/push-env.log"
export DIRECT_PUSH_COUNT="${TEST_ROOT}/direct-push-count"
export PR_CREATED_FILE="${TEST_ROOT}/pr-created"
export AUTO_MERGE_FILE="${TEST_ROOT}/auto-merge"
export PR_MERGED_FILE="${TEST_ROOT}/pr-merged"
export STALE_PR_FILE="${TEST_ROOT}/stale-pr"
export PR_RECREATED_FILE="${TEST_ROOT}/pr-recreated"
export PATH="${BIN}:${PATH}"
export AIDEVOPS_VERSION_MANAGER_REPO_SLUG=test/repo

print_error() {
	printf 'ERROR %s\n' "$*"
	return 0
}
print_info() {
	printf 'INFO %s\n' "$*"
	return 0
}
print_warning() {
	printf 'WARNING %s\n' "$*"
	return 0
}
print_success() {
	printf 'SUCCESS %s\n' "$*"
	return 0
}

export REPO_ROOT="$REPO"
# shellcheck source=../version-manager-git.sh
source "${SCRIPT_DIR}/version-manager-git.sh"

AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN=stale-token
export AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN
_version_manager_verify_aggregate_lane_fence() { return 1; }
fenced_push_rc=0
push_changes 1.2.3 >/dev/null 2>&1 || fenced_push_rc=$?
[[ "$fenced_push_rc" -eq 1 && ! -e "$DIRECT_PUSH_COUNT" ]]
unset AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN
unset -f _version_manager_verify_aggregate_lane_fence
printf 'PASS stale aggregate lane is checked immediately before direct publication push\n'

for unqueued_mode in status reconcile; do
	_version_manager_reconcile_protected_release_tag test/repo v1.2.3 "$unqueued_mode" >/dev/null
	[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "$_VERSION_MANAGER_RELEASE_PR_MISSING" ]]
	[[ ! -e "$PR_CREATED_FILE" && ! -e "$DIRECT_PUSH_COUNT" ]]
done
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS missing protected PR is typed read-only state, not invalid local provenance\n'

_version_manager_verify_preserved_lane_fence() { return 1; }
if _version_manager_queue_protected_main_release 1.2.3 >/dev/null 2>&1; then
	printf 'FAIL stale preserved-tag lane queued publication\n'
	exit 1
fi
[[ ! -e "$PR_CREATED_FILE" && ! -e "$DIRECT_PUSH_COUNT" ]]
[[ -z "$("$REAL_GIT" ls-remote --heads "$REMOTE" refs/heads/chore/release-v1.2.3-provenance)" ]]
unset -f _version_manager_verify_preserved_lane_fence
printf 'PASS preserved-tag fence refuses branch and PR mutation\n'

# GH#34756: model the orphan from an earlier retry with a different commit SHA.
RECOVERY_BRANCH='chore/release-v1.2.3-provenance'
RELEASE_PARENT=$("$REAL_GIT" -C "$REPO" rev-parse "${RELEASE_COMMIT}^1")
STALE_BRANCH_HEAD=$("$REAL_GIT" -C "$REPO" commit-tree "${RELEASE_COMMIT}^{tree}" \
	-p "$RELEASE_PARENT" -m 'previous failed release attempt')
export STALE_BRANCH_HEAD CURRENT_MAIN
"$REAL_GIT" -C "$REPO" push -q origin "${STALE_BRANCH_HEAD}:refs/heads/${RECOVERY_BRANCH}"
for stale_pr_mode in open merged api-failure; do
	if (
		export STALE_BRANCH_PR_MODE="$stale_pr_mode"
		_version_manager_prepare_protected_release_head 1.2.3 "$RELEASE_COMMIT" \
			"$RELEASE_PARENT" "$RECOVERY_BRANCH" >/dev/null 2>&1
	); then
		printf 'FAIL stale branch was replaced despite PR mode %s\n' "$stale_pr_mode"
		exit 1
	fi
	[[ "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "refs/heads/${RECOVERY_BRANCH}")" == "$STALE_BRANCH_HEAD" ]]
done
printf 'PASS open and merged PR ownership and failed API lookup prevent stale replacement\n'

if (
	export STALE_ANCESTRY_ERROR=1
	_version_manager_prepare_protected_release_head 1.2.3 "$RELEASE_COMMIT" \
		"$RELEASE_PARENT" "$RECOVERY_BRANCH" >/dev/null 2>&1
); then
	printf 'FAIL ancestry query error authorized stale branch replacement\n'
	exit 1
fi
[[ "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "refs/heads/${RECOVERY_BRANCH}")" == "$STALE_BRANCH_HEAD" ]]
printf 'PASS ancestry query errors cannot authorize stale branch replacement\n'

if (
	_version_manager_require_aggregate_fence() { return 1; }
	_version_manager_prepare_protected_release_head 1.2.3 "$RELEASE_COMMIT" \
		"$RELEASE_PARENT" "$RECOVERY_BRANCH" >/dev/null 2>&1
); then
	printf 'FAIL stale branch replacement bypassed the aggregate fence\n'
	exit 1
fi
[[ "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "refs/heads/${RECOVERY_BRANCH}")" == "$STALE_BRANCH_HEAD" ]]
printf 'PASS stale branch replacement requires the aggregate fence\n'

if (
	export STALE_BRANCH_RACE=1
	_version_manager_prepare_protected_release_head 1.2.3 "$RELEASE_COMMIT" \
		"$RELEASE_PARENT" "$RECOVERY_BRANCH" >/dev/null 2>&1
); then
	printf 'FAIL stale branch lease overwrote a concurrent remote update\n'
	exit 1
fi
[[ "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "refs/heads/${RECOVERY_BRANCH}")" == "$CURRENT_MAIN" ]]
"$REAL_GIT" --git-dir="$REMOTE" update-ref "refs/heads/${RECOVERY_BRANCH}" "$STALE_BRANCH_HEAD"
"$REAL_GIT" -C "$REPO" update-ref "refs/remotes/origin/${RECOVERY_BRANCH}" "$STALE_BRANCH_HEAD"
printf 'PASS stale branch lease preserves a concurrent remote update\n'

push_rc=0
push_output=$(push_changes 1.2.3 2>&1) || push_rc=$?
if [[ "$push_rc" -ne 8 ]]; then
	printf 'FAIL protected-main fallback returned rc=%s: %s\n' "$push_rc" "$push_output"
	exit 1
fi
[[ "$(<"$DIRECT_PUSH_COUNT")" == "1" ]]
[[ "$push_output" == *'GH006 Changes must be made through a pull request'* ]]
printf 'PASS permanent PR-required rejection stops after one direct push\n'

RECOVERY_BRANCH='chore/release-v1.2.3-provenance'
RECOVERY_HEAD=$("$REAL_GIT" ls-remote "$REMOTE" "refs/heads/${RECOVERY_BRANCH}" | cut -f1)
export RECOVERY_HEAD
[[ "$RECOVERY_HEAD" =~ ^[0-9a-f]{40}$ ]]
[[ "$("$REAL_GIT" -C "$REPO" rev-parse "${RECOVERY_HEAD}^1")" == "$CURRENT_MAIN" ]]
[[ "$("$REAL_GIT" -C "$REPO" rev-parse "${RECOVERY_HEAD}^2")" == "$RELEASE_COMMIT" ]]
"$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$RELEASE_COMMIT" "$RECOVERY_HEAD"
[[ "$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.3)" == "$TAG_OBJECT" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
if grep -Eq ' rebase | commit --amend| tag -(d|s) ' "$FAKE_GIT_LOG"; then
	printf 'FAIL recovery rewrote the release commit or tag\n'
	exit 1
fi
printf 'PASS recovery branch preserves the original release commit and tag object\n'
grep -q -- "--force-with-lease=refs/heads/${RECOVERY_BRANCH}:${STALE_BRANCH_HEAD}" "$FAKE_GIT_LOG"
[[ "$RECOVERY_HEAD" != "$STALE_BRANCH_HEAD" ]]
printf 'PASS stale PR-less branch is replaced using the observed-head lease\n'

# GH#34753: GitHub refuses tag objects outside refs/tags, so the staging ref is
# a commit envelope whose `tag` blob hashes back to the exact signed object.
STAGED_ENVELOPE=$("$REAL_GIT" ls-remote "$REMOTE" refs/aidevops/release-tags/v1.2.3 | cut -f1)
[[ "$("$REAL_GIT" --git-dir="$REMOTE" cat-file -t "$STAGED_ENVELOPE")" == "commit" ]]
[[ "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "${STAGED_ENVELOPE}^1")" == "$RELEASE_COMMIT" ]]
[[ "$("$REAL_GIT" --git-dir="$REMOTE" cat-file blob "${STAGED_ENVELOPE}:tag" |
	"$REAL_GIT" --git-dir="$REMOTE" hash-object -t tag --stdin)" == "$TAG_OBJECT" ]]
printf 'PASS protected PR queue first preserves the exact tag on a fetchable staging ref\n'

# GH#34434: release-tool pushes run in dependency-free worktrees, so each one
# skips only the repo-verify guard for that command.
grep -q 'push --atomic origin HEAD:refs/heads/main --tags' "$FAKE_PUSH_ENV_LOG"
grep -q "push origin --force-with-lease=refs/heads/${RECOVERY_BRANCH}:${STALE_BRANCH_HEAD} ${RECOVERY_HEAD}:refs/heads/${RECOVERY_BRANCH}" "$FAKE_PUSH_ENV_LOG"
if grep -qv '^repo_verify=0 ' "$FAKE_PUSH_ENV_LOG"; then
	printf 'FAIL a release push ran the dependency-bound repo-verify guard\n'
	exit 1
fi
printf 'PASS release pushes skip only the repo-verify guard\n'

grep -q '^pr create .*--head chore/release-v1.2.3-provenance .*--base main ' "$FAKE_GH_LOG"
grep -q "^pr merge 77 --repo test/repo --auto --merge --match-head-commit ${RECOVERY_HEAD}$" "$FAKE_GH_LOG"
printf 'PASS recovery queues merge topology against the exact PR head\n'

create_calls_before=$(grep -c '^pr create ' "$FAKE_GH_LOG")
_version_manager_queue_protected_main_release 1.2.3 >/dev/null
create_calls_after=$(grep -c '^pr create ' "$FAKE_GH_LOG")
[[ "$create_calls_after" -eq "$create_calls_before" ]]
[[ "$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.3)" == "$TAG_OBJECT" ]]
printf 'PASS resumed queue reuses the exact protected PR and immutable tag\n'

merge_calls_before=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN=stale-token
export AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN
_version_manager_verify_aggregate_lane_fence() { return 1; }
if _version_manager_queue_exact_merge test/repo "$RECOVERY_BRANCH" "$RECOVERY_HEAD" \
	77 1.2.3 "$TAG_OBJECT" "$RELEASE_COMMIT" >/dev/null 2>&1; then
	printf 'FAIL stale aggregate lane queued a protected-main merge\n'
	exit 1
fi
merge_calls_after=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
[[ "$merge_calls_after" -eq "$merge_calls_before" ]]
unset AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN
unset -f _version_manager_verify_aggregate_lane_fence
printf 'PASS stale aggregate lane is checked immediately before protected-main merge queueing\n'

STALE_PR_HEAD="$CURRENT_MAIN"
export STALE_PR_HEAD
: >"$STALE_PR_FILE"
create_calls_before=$(grep -c '^pr create ' "$FAKE_GH_LOG")
_version_manager_create_or_reuse_protected_pr test/repo 1.2.3 "$RECOVERY_BRANCH" \
	"$RECOVERY_HEAD" "$TAG_OBJECT" "$RELEASE_COMMIT" >/dev/null
create_calls_after=$(grep -c '^pr create ' "$FAKE_GH_LOG")
[[ "$create_calls_after" -eq "$((create_calls_before + 1))" ]]
[[ -f "$PR_RECREATED_FILE" ]]
rm -f "$STALE_PR_FILE"
printf 'PASS stale closed PR is replaced by a new exact-head recovery PR\n'

printf 'unreviewed descendant\n' >"${REPO}/unsafe.txt"
"$REAL_GIT" -C "$REPO" add unsafe.txt
"$REAL_GIT" -C "$REPO" commit -q -m 'unreviewed recovery descendant'
UNSAFE_HEAD=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REPO" push -q origin "${UNSAFE_HEAD}:refs/heads/fixture-unsafe"
"$REAL_GIT" --git-dir="$REMOTE" update-ref "refs/heads/${RECOVERY_BRANCH}" "$UNSAFE_HEAD"
"$REAL_GIT" --git-dir="$REMOTE" update-ref -d refs/heads/fixture-unsafe
merge_calls_before=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
reconcile_unsafe_rc=0
reconcile_unsafe_output=$(_version_manager_reconcile_protected_release_tag \
	test/repo v1.2.3 reconcile 2>&1) || reconcile_unsafe_rc=$?
unsafe_rc=0
unsafe_output=$(_version_manager_queue_protected_main_release 1.2.3 2>&1) || unsafe_rc=$?
merge_calls_after=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
[[ "$reconcile_unsafe_rc" -ne 0 ]]
[[ "$reconcile_unsafe_output" == *'outside the required merge topology'* ]]
[[ "$unsafe_rc" -ne 0 ]]
[[ "$unsafe_output" == *'outside the required merge topology'* ]]
[[ "$merge_calls_after" -eq "$merge_calls_before" ]]
"$REAL_GIT" --git-dir="$REMOTE" update-ref "refs/heads/${RECOVERY_BRANCH}" "$RECOVERY_HEAD"
"$REAL_GIT" -C "$REPO" update-ref "refs/remotes/origin/${RECOVERY_BRANCH}" "$RECOVERY_HEAD"
"$REAL_GIT" -C "$REPO" checkout -q --detach "$RECOVERY_HEAD"
printf 'PASS incompatible recovery descendants fail closed before merge queueing\n'

export PR_AUTHOR_ASSOCIATION=NONE
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1; then
	printf 'FAIL untrusted protected release PR authorized tag reconciliation\n'
	exit 1
fi
unset PR_AUTHOR_ASSOCIATION
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS protected release reconciliation requires a trusted PR author\n'

"$REAL_GIT" -C "$REPO" tag -f -a v1.2.3 -m 'replacement tag object' "$RELEASE_COMMIT"
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1; then
	printf 'FAIL replacement local tag object matched protected release evidence\n'
	exit 1
fi
"$REAL_GIT" -C "$REPO" update-ref refs/tags/v1.2.3 "$TAG_OBJECT"
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS protected release reconciliation binds the exact preserved tag object\n'

_version_manager_reconcile_protected_release_tag test/repo v1.2.3 status >/dev/null
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "pr-pending" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS final tag publication remains blocked while the recovery PR is open\n'

"$REAL_GIT" clone -q "$REMOTE" "$MERGER"
"$REAL_GIT" -C "$MERGER" config user.name Test
"$REAL_GIT" -C "$MERGER" config user.email test@example.invalid
"$REAL_GIT" -C "$MERGER" merge -q --no-ff --no-edit "origin/${RECOVERY_BRANCH}"
"$REAL_GIT" -C "$MERGER" push -q origin main
MERGED_MAIN=$("$REAL_GIT" -C "$MERGER" rev-parse HEAD)
: >"$PR_MERGED_FILE"
"$REAL_GIT" --git-dir="$REMOTE" update-ref -d "refs/heads/${RECOVERY_BRANCH}"

tag_pushes_before=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
_version_manager_reconcile_protected_release_tag test/repo v1.2.3 status >/dev/null
tag_pushes_after=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "tag-ready" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS merged protected release status remains read-only after branch deletion\n'

export PR_MERGED_AT_JSON='"not-a-timestamp"'
tag_pushes_before=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1 || _version_manager_reconcile_protected_release_tag \
	test/repo v1.2.3 reconcile >/dev/null 2>&1; then
	printf 'FAIL malformed protected PR merge evidence authorized reconciliation\n'
	exit 1
fi
tag_pushes_after=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
unset PR_MERGED_AT_JSON
printf 'PASS malformed protected PR merge evidence cannot publish a tag\n'

"$REAL_GIT" --git-dir="$REMOTE" update-ref refs/heads/main "$CURRENT_MAIN"
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile \
	>/dev/null 2>&1; then
	printf 'FAIL merged PR metadata bypassed release ancestry verification\n'
	exit 1
fi
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
"$REAL_GIT" --git-dir="$REMOTE" update-ref refs/heads/main "$MERGED_MAIN"
printf 'PASS merged protected release still requires exact main ancestry\n'

reconcile_rc=0
_version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile \
	>/dev/null 2>&1 || reconcile_rc=$?
[[ "$reconcile_rc" -ne 0 ]]
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "aggregation-required" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS changed protected-main tree requires reviewed aggregation before tag publication\n'

tag_pushes_before=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
reconcile_rc=0
_version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile \
	>/dev/null 2>&1 || reconcile_rc=$?
tag_pushes_after=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
[[ "$reconcile_rc" -ne 0 ]]
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "aggregation-required" ]]
printf 'PASS repeated aggregation-required reconciliation is idempotent\n'

# A real SSH signature with no local trusted principal is a signer failure,
# not a reason to replace a correctly snapshot-bound immutable release tag.
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/snapshot-key"
"$REAL_GIT" -C "$REPO" config gpg.format ssh
"$REAL_GIT" -C "$REPO" config user.signingkey "$TEST_ROOT/snapshot-key"
: >"$TEST_ROOT/allowed_signers"
"$REAL_GIT" -C "$REPO" config gpg.ssh.allowedSignersFile "$TEST_ROOT/allowed_signers"
snapshot_source=$("$REAL_GIT" -C "$REPO" rev-parse "${RELEASE_COMMIT}^1")
"$REAL_GIT" -C "$REPO" tag -s v1.2.4 "$RELEASE_COMMIT" -m "Release snapshot

Aidevops-Snapshot-Base: $snapshot_source
Aidevops-Source-Merge: $snapshot_source"
snapshot_object=$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.4)
if _version_manager_publish_reachable_tag v1.2.4 >"$TEST_ROOT/untrusted.log" 2>&1; then
	printf 'FAIL untrusted snapshot signature permitted publication\n'
	exit 1
fi
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == signer-untrusted ]]
grep -q 'SHA256:' "$TEST_ROOT/untrusted.log"
if grep -q 'Create a newly reviewed exact-tip aggregation release' "$TEST_ROOT/untrusted.log"; then
	printf 'FAIL signer trust failure recommended aggregation\n'
	exit 1
fi
[[ "$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.4)" == "$snapshot_object" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.4)" ]]
printf 'PASS untrusted SSH snapshot preserves its tag and reports signer-untrusted with fingerprint\n'

printf 'test@example.invalid %s\n' "$(<"$TEST_ROOT/snapshot-key.pub")" >"$TEST_ROOT/allowed_signers"
_version_manager_is_signed_snapshot v1.2.4
[[ "$_VERSION_MANAGER_SNAPSHOT_SIGNATURE_UNTRUSTED" -eq 0 ]]
_version_manager_publish_reachable_tag v1.2.4
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == tag-pushed ]]
[[ "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.4)" == "$snapshot_object"$'\trefs/tags/v1.2.4' ]]
printf 'PASS restoring signer trust publishes the exact preserved snapshot despite main drift\n'

# GH#34710: a recovery-pinned aggregate may trail main only when its signed pin
# is the direct release parent and that parent names the same aggregator PR.
pinned_aggregate=$("$REAL_GIT" -C "$REPO" commit-tree "${RELEASE_COMMIT}^{tree}" -p "$RELEASE_COMMIT" \
	-m "reviewed aggregate" -m "Aidevops-Release-Aggregator-PR: 77
Aidevops-Release-Aggregates: 76@${RELEASE_COMMIT}")
pinned_release=$("$REAL_GIT" -C "$REPO" commit-tree "${pinned_aggregate}^{tree}" -p "$pinned_aggregate" \
	-m "chore(release): bump version to 1.2.5")
_pinned_tag() {
	local tag="$1" source_pr="$2" pin="$3"
	"$REAL_GIT" -C "$REPO" tag -s "$tag" "$pinned_release" -m "Release $tag

Aidevops-Source-PR: $source_pr
Aidevops-Source-Merge: $pinned_aggregate
Aidevops-Aggregate-Pin: $pin
Aidevops-Aggregated-Source: 76@${RELEASE_COMMIT}"
	return 0
}
_pinned_tag v1.2.5 77 "$pinned_aggregate"
_version_manager_is_signed_snapshot v1.2.5
_pinned_tag v1.2.6 78 "$pinned_aggregate"
if _version_manager_is_signed_snapshot v1.2.6 >/dev/null 2>&1; then
	printf 'FAIL pinned tag accepted a source PR that is not the aggregator identity\n'
	exit 1
fi
_pinned_tag v1.2.7 77 "$RELEASE_COMMIT"
if _version_manager_is_signed_snapshot v1.2.7 >/dev/null 2>&1; then
	printf 'FAIL pinned tag accepted a pin that is not its direct release parent\n'
	exit 1
fi
"$REAL_GIT" -C "$REPO" tag -s v1.2.8 "$pinned_release" -m "Release v1.2.8

Aidevops-Source-PR: 77
Aidevops-Source-Merge: $pinned_aggregate"
if _version_manager_is_signed_snapshot v1.2.8 >/dev/null 2>&1; then
	printf 'FAIL unpinned aggregate tag was allowed to trail main\n'
	exit 1
fi
printf 'PASS signed aggregate pin permits main drift only for its exact reviewed aggregate parent\n'

exit 0
