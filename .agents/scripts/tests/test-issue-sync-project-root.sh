#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27146 and GH#27977: pulse issue sync must bind
# mutations to the requested slug without changing human canonical checkouts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

# Fixture repositories are intentionally isolated under TMP. Use native Git so
# the production canonical-worktree shim does not classify them as service
# mirrors during local verification.
git() {
	/usr/bin/git "$@"
	return $?
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

make_repo() {
	local root="$1"
	local slug="$2"
	mkdir -p "$root"
	git -C "$root" init --quiet
	printf '\n[remote "origin"]\n\turl = https://github.com/%s.git\n' "$slug" >>"${root}/.git/config"
	printf '%s\n' '- [ ] t1 fixture' >"${root}/TODO.md"
	return 0
}

repo_a="${TMP}/repo-a"
repo_b="${TMP}/repo-b"
make_repo "$repo_a" owner/repo-a
make_repo "$repo_b" owner/repo-b

# The real helper must reject both an invalid root and a root/slug mismatch
# before invoking gh or changing either ledger.
before_a=$(shasum "$repo_a/TODO.md")
before_b=$(shasum "$repo_b/TODO.md")
if "$SCRIPTS_DIR/issue-sync-helper.sh" pull --repo owner/repo-a --project-root "$TMP/missing" >/dev/null 2>&1; then
	fail "missing project root was accepted"
fi
if "$SCRIPTS_DIR/issue-sync-helper.sh" pull --repo owner/repo-b --project-root "$repo_a" >/dev/null 2>&1; then
	fail "mismatched project root remote was accepted"
fi
[[ $(shasum "$repo_a/TODO.md") == "$before_a" ]] || fail "repo A changed after rejected roots"
[[ $(shasum "$repo_b/TODO.md") == "$before_b" ]] || fail "repo B changed after rejected roots"

# Exercise the real pulse function with a fixture helper. Rebuild the fixtures
# as clones of local remotes so Pulse can create fresh automation workspaces.
rm -rf "$repo_a" "$repo_b"
setup_sync_repo() {
	local root="$1"
	local remote="$2"
	git init --bare --quiet --initial-branch=main "$remote" 2>/dev/null || git init --bare --quiet "$remote"
	git clone --quiet "$remote" "$root"
	git -C "$root" config user.email test@example.com
	git -C "$root" config user.name Test
	git -C "$root" config commit.gpgsign false
	printf '%s\n' '- [ ] t1 fixture' >"${root}/TODO.md"
	git -C "$root" add TODO.md
	git -C "$root" commit --quiet -m seed
	git -C "$root" push --quiet origin main
	git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
	return 0
}

remote_a="${TMP}/remote-a.git"
remote_b="${TMP}/remote-b.git"
setup_sync_repo "$repo_a" "$remote_a"
setup_sync_repo "$repo_b" "$remote_b"

fixture_scripts="${TMP}/scripts"
mkdir -p "$fixture_scripts"
cp "$SCRIPTS_DIR/pulse-wrapper-cycle.sh" "$fixture_scripts/pulse-wrapper-cycle.sh"
cp "$SCRIPTS_DIR/planning-publisher.sh" "$fixture_scripts/planning-publisher.sh"
cp "$SCRIPTS_DIR/pulse-todo-publication.sh" "$fixture_scripts/pulse-todo-publication.sh"
cp "$SCRIPTS_DIR/pulse-todo-sync-workspace.sh" "$fixture_scripts/pulse-todo-sync-workspace.sh"
cat >"${fixture_scripts}/issue-sync-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
command_name="$1"
shift
repo=""
root=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo) repo="$2"; shift 2 ;;
	--project-root) root="$2"; shift 2 ;;
	*) exit 2 ;;
	esac
done
[[ -n "$repo" && -n "$root" ]] || exit 3
printf '%s|%s|%s\n' "$command_name" "$repo" "$root" >>"$CALL_LOG"
if [[ "$command_name" == "pull" ]]; then
	if [[ "$repo" == "owner/repo-handoff" ]]; then
		grep -Fq 'ref:GH#301' "${root}/TODO.md" || \
			printf '%s\n' '- [x] t301 completed ref:GH#301 pr:#77' >>"${root}/TODO.md"
	else
		printf '%s\n' "synced:${repo}" >>"${root}/TODO.md"
	fi
fi
if [[ "$command_name" == "pull" && -n "${ADVANCE_REMOTE_ON_PULL:-}" && ! -e "${ADVANCE_REMOTE_MARKER:-}" ]]; then
	writer="${ADVANCE_REMOTE_WRITER:-}"
	[[ -n "$writer" && -n "${ADVANCE_REMOTE_MARKER:-}" ]] || exit 4
	git clone --quiet "$ADVANCE_REMOTE_ON_PULL" "$writer"
	git -C "$writer" config user.email test@example.com
	git -C "$writer" config user.name Test
	git -C "$writer" config commit.gpgsign false
	printf '%s\n' 'advanced default snapshot' >>"${writer}/TODO.md"
	git -C "$writer" add TODO.md
	git -C "$writer" commit --quiet -m advance-snapshot
	git -C "$writer" push --quiet origin main
	touch "$ADVANCE_REMOTE_MARKER"
fi
FIXTURE
chmod +x "${fixture_scripts}/issue-sync-helper.sh"

export CALL_LOG="${TMP}/calls.log"
export WRAPPER_LOGFILE="${TMP}/pulse.log"
export LOGFILE="$WRAPPER_LOGFILE"
export SCRIPT_DIR="$fixture_scripts"
export AIDEVOPS_TEMP_DIR="${TMP}/automation"
export AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true
export GIT_AUTHOR_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test
export GIT_COMMITTER_EMAIL=test@example.com
# shellcheck source=/dev/null
source "$fixture_scripts/pulse-wrapper-cycle.sh"
# Keep publication seams available in the parent test shell. Production loads
# the same module inside the isolated sync scope when it is not already loaded.
# shellcheck source=/dev/null
source "$fixture_scripts/planning-publisher.sh"
# Normal unprotected publication has no existing Pulse handoff. Keep this
# fixture entirely offline even though production checks for a pending PR.
gh() {
	if [[ "$1 $2" == "pr list" ]]; then
		printf '%s\n' '[]'
		return 0
	fi
	return 1
}

# Workspace creation must clone only the remote default branch tip.
_ptsw_create_workspace "file://${remote_a}" || fail "shallow workspace clone failed"
[[ $(git -C "$_PULSE_TODO_SYNC_WORKSPACE" rev-parse --is-shallow-repository) == "true" ]] ||
	fail "TODO-sync workspace clone was not shallow"
[[ $(git -C "$_PULSE_TODO_SYNC_WORKSPACE" branch -r | grep -Evc 'origin/HEAD') -eq 1 ]] ||
	fail "TODO-sync workspace clone fetched more than the default branch"
_ptsw_remove_owned_workspace "$_PULSE_TODO_SYNC_WORKSPACE_ROOT" \
	"$_PULSE_TODO_SYNC_OWNER_PID" "$_PULSE_TODO_SYNC_OWNER_START" ||
	fail "shallow workspace fixture cleanup failed"

wait_for_file() {
	local file_path="$1"
	local max_attempts="${2:-100}"
	local attempt=0
	while [[ ! -e "$file_path" && "$attempt" -lt "$max_attempts" ]]; do
		sleep 0.1
		attempt=$((attempt + 1))
	done
	[[ -e "$file_path" ]]
	return $?
}

only_todo_sync_workspace() {
	local workspace_root=""
	local match_count=0
	for workspace_root in "$AIDEVOPS_TEMP_DIR"/pulse-todo-sync.*; do
		[[ -d "$workspace_root" ]] || continue
		match_count=$((match_count + 1))
		printf '%s\n' "$workspace_root"
	done
	[[ "$match_count" -eq 1 ]]
	return $?
}

canonical_snapshot() {
	local root="$1"
	{
		git -C "$root" rev-parse HEAD
		cksum <"${root}/.git/index"
		cksum <"${root}/TODO.md"
		git -C "$root" status --porcelain=v1 --untracked-files=all
	}
	return 0
}

printf '%s\n' 'human canonical dirt A' >>"$repo_a/TODO.md"
printf '%s\n' 'human canonical dirt B' >>"$repo_b/TODO.md"
snapshot_a=$(canonical_snapshot "$repo_a")
snapshot_b=$(canonical_snapshot "$repo_b")
parent_exit_trap_before=$(trap -p EXIT)
parent_term_trap_before=$(trap -p TERM)
sync_todo_refs_for_repo owner/repo-a "$repo_a"
[[ $(canonical_snapshot "$repo_a") == "$snapshot_a" ]] || fail "repo A canonical checkout changed"
[[ $(canonical_snapshot "$repo_b") == "$snapshot_b" ]] || fail "repo A invocation changed repo B"
git --git-dir="$remote_a" show main:TODO.md | grep -q '^synced:owner/repo-a$' || fail "repo A remote was not synced"

sync_todo_refs_for_repo owner/repo-b "$repo_b"
[[ $(canonical_snapshot "$repo_a") == "$snapshot_a" ]] || fail "repo B invocation changed repo A"
[[ $(canonical_snapshot "$repo_b") == "$snapshot_b" ]] || fail "repo B canonical checkout changed"
git --git-dir="$remote_b" show main:TODO.md | grep -q '^synced:owner/repo-b$' || fail "repo B remote was not synced"

# A protected default refuses direct publication once. A deterministic branch
# and reviewable PR survive workspace cleanup; later cycles wait for merge.
repo_handoff="${TMP}/repo-handoff"
remote_handoff="${TMP}/remote-handoff.git"
setup_sync_repo "$repo_handoff" "$remote_handoff"
original_gh_definition=$(declare -f gh)
original_push_definition=$(declare -f _planning_publish_push)
export TEST_PROTECTED_PR_BODY="${TMP}/protected-pr-body"
export TEST_PROTECTED_PUSHES="${TMP}/protected-pushes"
export TEST_PROTECTED_PR_BRANCH="${TMP}/protected-pr-branch"
gh() {
	if [[ "$1 $2" == "pr list" ]]; then
		if [[ -f "$TEST_PROTECTED_PR_BODY" ]]; then
			jq -n --rawfile body "$TEST_PROTECTED_PR_BODY" --rawfile head "$TEST_PROTECTED_PR_BRANCH" \
			'[ {url:"https://github.com/owner/repo-handoff/pull/1",state:"OPEN",body:$body,headRefName:($head | rtrimstr("\n"))} ]'
		else
			printf '%s\n' '[]'
		fi
		return 0
	fi
	if [[ "$1 $2" == "repo view" ]]; then
		printf '%s\n' 'WRITE'
		return 0
	fi
	return 1
}
gh_create_pr() {
	local body_file="" previous="" head_branch="" title=""
	while [[ $# -gt 0 ]]; do
		case "$previous" in
		--body-file) body_file="$1" ;;
		--head) head_branch="$1" ;;
		--title) title="$1" ;;
		esac
		previous="$1"; shift
	done
	[[ -n "$body_file" && -f "$body_file" && -n "$head_branch" && "$title" != *'[skip ci]'* ]] || return 1
	cp "$body_file" "$TEST_PROTECTED_PR_BODY"
	printf '%s\n' "$head_branch" >"$TEST_PROTECTED_PR_BRANCH"
	printf '%s\n' 'https://github.com/owner/repo-handoff/pull/1'
}
_planning_publish_push() {
	local workspace="$1" remote="$2" branch="$3" expected="$4" candidate="$5"
	if [[ "$branch" == "main" ]]; then
		printf '%s\n' rejected >>"$TEST_PROTECTED_PUSHES"
		PLANNING_PUBLISH_RESULT="protected_branch_publication_deferred"
		return 4
	fi
	git -C "$workspace" push -q --force-with-lease="refs/heads/${branch}:${expected}" \
		"$remote" "${candidate}:refs/heads/${branch}"
}
protected_rc=0
sync_todo_refs_for_repo owner/repo-handoff "$repo_handoff" || protected_rc=$?
[[ "$protected_rc" -eq 4 && -f "$TEST_PROTECTED_PR_BODY" ]] || fail "protected publication did not create a pending PR"
[[ $(wc -l <"$TEST_PROTECTED_PUSHES") -eq 1 ]] || fail "protected default push was retried"
if git --git-dir="$remote_handoff" show main:TODO.md | grep -q 'ref:GH#301'; then
	fail "unmerged TODO projection reached default"
fi
protected_rc=0
sync_todo_refs_for_repo owner/repo-handoff "$repo_handoff" >/dev/null || protected_rc=$?
[[ "$protected_rc" -eq 4 && $(wc -l <"$TEST_PROTECTED_PUSHES") -eq 1 ]] ||
	fail "pending PR allowed another protected-default push"
grep -q 'status=protected_branch_pr_pending repo=owner/repo-handoff pr=' "$WRAPPER_LOGFILE" ||
	fail "pending protected PR URL was not logged"
protected_branch=$(git --git-dir="$remote_handoff" for-each-ref --format='%(refname:short)' 'refs/heads/aidevops/pulse-todo-*')
[[ -n "$protected_branch" ]] || fail "protected handoff branch did not survive workspace cleanup"
protected_merge="${TMP}/protected-merge"
/usr/bin/git clone --quiet "$remote_handoff" "$protected_merge"
/usr/bin/git -C "$protected_merge" config user.email test@example.com
/usr/bin/git -C "$protected_merge" config user.name Test
printf '%s\n' 'unrelated upstream advance' >"${protected_merge}/README.md"
/usr/bin/git -C "$protected_merge" add README.md
/usr/bin/git -C "$protected_merge" commit --quiet -m advance-unrelated
/usr/bin/git -C "$protected_merge" push --quiet origin main
protected_rc=0
sync_todo_refs_for_repo owner/repo-handoff "$repo_handoff" >/dev/null || protected_rc=$?
[[ "$protected_rc" -eq 4 && $(wc -l <"$TEST_PROTECTED_PUSHES") -eq 1 ]] ||
	fail "default-branch advance created a duplicate handoff"
/usr/bin/git -C "$protected_merge" fetch --quiet origin "$protected_branch"
/usr/bin/git -C "$protected_merge" merge --quiet --no-edit "origin/${protected_branch}" || fail "protected PR fixture could not merge"
/usr/bin/git -C "$protected_merge" push --quiet origin main
sync_todo_refs_for_repo owner/repo-handoff "$repo_handoff" >/dev/null || fail "post-merge TODO sync did not converge"
git --git-dir="$remote_handoff" show main:TODO.md | grep -q 'ref:GH#301' || fail "merged PR did not publish TODO state"
[[ $(wc -l <"$TEST_PROTECTED_PUSHES") -eq 1 ]] || fail "post-merge cycle retried protected push"
eval "$original_gh_definition"
eval "$original_push_definition"
unset -f gh_create_pr
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "successful reconciliation left an automation workspace behind"
fi

# Clone failures emit bounded diagnostics without exposing URL authorities or
# credential-shaped values, clean their workspace, and remain retryable.
original_git_definition=$(declare -f git)
export TEST_CLONE_TOKEN="ghp_""1234567890abcdef"
git() {
	if [[ "${1:-}" == "clone" ]]; then
		printf 'fatal: unable to access https://user:%s@example.invalid/private.git\n' "$TEST_CLONE_TOKEN" >&2
		printf 'credential %s rejected; detail=%0600d\n' "$TEST_CLONE_TOKEN" 0 >&2
		return 128
	fi
	/usr/bin/git "$@"
	return $?
}
clone_failure_rc=0
clone_failure_output=$(sync_todo_refs_for_repo owner/repo-clone-failure "$repo_a" 2>&1) || clone_failure_rc=$?
eval "$original_git_definition"
unset TEST_CLONE_TOKEN
[[ "$clone_failure_rc" -eq 1 ]] || fail "clone failure was not retryable"
[[ "$clone_failure_output" != *"1234567890abcdef"* && "$clone_failure_output" != *"user:"* ]] ||
	fail "clone failure diagnostic exposed credentials"
[[ "$clone_failure_output" == *"[redacted-credential]"* ]] ||
	fail "clone failure diagnostic omitted redaction evidence"
[[ ${#clone_failure_output} -le 600 ]] || fail "clone failure diagnostic exceeded its output bound"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "clone failure left an automation workspace behind"
fi
[[ $(trap -p EXIT) == "$parent_exit_trap_before" ]] || fail "sync scope replaced the caller EXIT trap"
[[ $(trap -p TERM) == "$parent_term_trap_before" ]] || fail "sync scope replaced the caller TERM trap"

[[ $(wc -l <"$CALL_LOG" | tr -d ' ') -eq 24 ]] || fail "pulse did not make four bound calls per invocation"
if grep -Fq "|${repo_a}" "$CALL_LOG" || grep -Fq "|${repo_b}" "$CALL_LOG"; then
	fail "registered canonical root was passed to a mutating issue-sync command"
fi
grep -q 'repo=owner/repo-a root=automation' "$WRAPPER_LOGFILE" || fail "automation-root status was not logged"
if grep -q "$TMP" "$WRAPPER_LOGFILE"; then
	fail "pulse log disclosed a private project path"
fi

# Publication failure must be observable, retryable, and leave both remote and
# canonical state unchanged.
repo_c="${TMP}/repo-c"
remote_c="${TMP}/remote-c.git"
setup_sync_repo "$repo_c" "$remote_c"
printf '%s\n' 'human canonical dirt C' >>"$repo_c/TODO.md"
snapshot_c=$(canonical_snapshot "$repo_c")
remote_c_before=$(git --git-dir="$remote_c" rev-parse main)
publication_rc=0
AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK=/usr/bin/false \
	sync_todo_refs_for_repo owner/repo-c "$repo_c" || publication_rc=$?
[[ "$publication_rc" -eq 1 ]] || fail "publication failure was swallowed"
[[ $(canonical_snapshot "$repo_c") == "$snapshot_c" ]] || fail "failed publication changed canonical checkout"
[[ $(git --git-dir="$remote_c" rev-parse main) == "$remote_c_before" ]] || fail "failed publication changed remote"
grep -q 'status=retryable_failure stage=publication repo=owner/repo-c rc=1' "$WRAPPER_LOGFILE" || \
	fail "publication failure evidence was not logged"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "retryable publication failure left an automation workspace behind"
fi

# A protected default branch is a deterministic publication mode mismatch, not
# a snapshot conflict. Its GH006 rejection must be classified after one push
# and must not consume the bounded retry slot.
repo_protected="${TMP}/repo-protected"
remote_protected="${TMP}/remote-protected.git"
setup_sync_repo "$repo_protected" "$remote_protected"
protected_git="${TMP}/protected-push-git.sh"
cat >"$protected_git" <<'FIXTURE'
#!/usr/bin/env bash
if [[ "${3:-}" == "push" ]]; then
	printf '%s\n' 'remote: error: GH006: Protected branch update failed for refs/heads/main.' >&2
	printf '%s\n' 'remote: - Changes must be made through a pull request.' >&2
	exit 1
fi
exec /usr/bin/git "$@"
FIXTURE
chmod +x "$protected_git"
protected_refresh_repo_definition=$(declare -f _pulse_refresh_repo)
_pulse_refresh_repo() {
	local repo_path="$1"
	: "$repo_path"
	return 0
}
protected_rc=0
AIDEVOPS_PLANNING_GIT_BIN="$protected_git" \
	_pulse_sync_todo_repo_bounded owner/repo-protected "$repo_protected" 30 1 || protected_rc=$?
eval "$protected_refresh_repo_definition"
[[ "$protected_rc" -eq 4 ]] || fail "protected-branch publication was not classified as a bounded deferral"
grep -q 'status=protected_branch_publication_deferred repo=owner/repo-protected' "$WRAPPER_LOGFILE" || \
	fail "protected-branch deferral was not logged"
[[ $(grep -c 'status=protected_branch_publication_deferred repo=owner/repo-protected' "$WRAPPER_LOGFILE") -eq 1 ]] || \
	fail "protected-branch publication was deferred more than once"
if grep -q 'status=retrying repo=owner/repo-protected' "$WRAPPER_LOGFILE"; then
	fail "protected-branch publication consumed the snapshot retry slot"
fi
git --git-dir="$remote_protected" show main:TODO.md | grep -q '^synced:owner/repo-protected$' && \
	fail "protected-branch fixture unexpectedly published directly"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "protected-branch deferral left an automation workspace behind"
fi

# A remote default-branch advance after the isolated clone is created must be
# retried from a newly cloned exact snapshot instead of failing the batch.
repo_snapshot_retry="${TMP}/repo-snapshot-retry"
remote_snapshot_retry="${TMP}/remote-snapshot-retry.git"
setup_sync_repo "$repo_snapshot_retry" "$remote_snapshot_retry"
export ADVANCE_REMOTE_ON_PULL="$remote_snapshot_retry"
export ADVANCE_REMOTE_MARKER="${TMP}/remote-snapshot-advanced"
export ADVANCE_REMOTE_WRITER="${TMP}/remote-snapshot-writer"
retry_repos_json="${TMP}/snapshot-retry-repos.json"
jq -n --arg slug owner/repo-snapshot-retry --arg path "$repo_snapshot_retry" \
	'{initialized_repos:[{slug:$slug,path:$path,pulse:true,local_only:false}]}' >"$retry_repos_json"
previous_repos_json="${REPOS_JSON:-}"
export REPOS_JSON="$retry_repos_json"
refresh_repo_definition=$(declare -f _pulse_refresh_repo)
_pulse_refresh_repo() {
	local repo_path="$1"
	: "$repo_path"
	return 0
}
snapshot_retry_rc=0
sync_todo_refs_all_repos || snapshot_retry_rc=$?
eval "$refresh_repo_definition"
if [[ -n "$previous_repos_json" ]]; then
	export REPOS_JSON="$previous_repos_json"
else
	unset REPOS_JSON
fi
[[ "$snapshot_retry_rc" -eq 0 ]] || fail "stale snapshot retry did not recover"
[[ -e "$ADVANCE_REMOTE_MARKER" ]] || fail "stale snapshot fixture did not advance the remote"
git --git-dir="$remote_snapshot_retry" show main:TODO.md | grep -q '^synced:owner/repo-snapshot-retry$' || \
	fail "refreshed snapshot was not synced"
grep -q 'status=snapshot_mismatch stage=snapshot repo=owner/repo-snapshot-retry.*class=remote_advanced.*wake=fresh_workspace_at_remote_tip.*retry=recreate' "$WRAPPER_LOGFILE" || \
	fail "stale snapshot refresh evidence was not logged"
grep -q 'status=retrying repo=owner/repo-snapshot-retry attempt=2 reason=remote_advanced' "$WRAPPER_LOGFILE" || \
	fail "stale snapshot retry evidence was not logged"
grep -q 'TODO ref sync batch completed scheduled=1 failures=0' "$WRAPPER_LOGFILE" || \
	fail "recovered snapshot retry failed the sync batch"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "stale snapshot retry left an automation workspace behind"
fi
unset ADVANCE_REMOTE_ON_PULL ADVANCE_REMOTE_MARKER ADVANCE_REMOTE_WRITER

# A clone whose fetched tracking ref cannot match the authoritative remote HEAD
# would reproduce the same mismatch after recreation. Preserve the typed wake
# condition and do not spend the remote-advance retry on unchanged work.
repo_snapshot_unchanged="${TMP}/repo-snapshot-unchanged"
remote_snapshot_unchanged="${TMP}/remote-snapshot-unchanged.git"
setup_sync_repo "$repo_snapshot_unchanged" "$remote_snapshot_unchanged"
original_git_definition=$(declare -f git)
refresh_repo_definition=$(declare -f _pulse_refresh_repo)
git() {
	local arg=""
	for arg in "$@"; do
		if [[ "$arg" == "ls-remote" ]]; then
			printf 'ref:\trefs/heads/main\tHEAD\n'
			printf '1111111111111111111111111111111111111111\tHEAD\n'
			return 0
		fi
	done
	/usr/bin/git "$@"
	return $?
}
_pulse_refresh_repo() {
	local repo_path="$1"
	: "$repo_path"
	return 0
}
snapshot_unchanged_rc=0
_pulse_sync_todo_repo_bounded owner/repo-snapshot-unchanged \
	"$repo_snapshot_unchanged" 30 1 || snapshot_unchanged_rc=$?
eval "$original_git_definition"
eval "$refresh_repo_definition"
[[ "$snapshot_unchanged_rc" -eq 24 ]] || \
	fail "unchanged post-clone mismatch lost its stale-tracking classification"
grep -q 'status=snapshot_mismatch stage=snapshot repo=owner/repo-snapshot-unchanged.*class=stale_tracking_ref.*wake=tracking_ref_matches_authoritative_tip.*retry=none' \
	"$WRAPPER_LOGFILE" || fail "unchanged post-clone mismatch omitted its wake condition"
if grep -q 'status=retrying repo=owner/repo-snapshot-unchanged' "$WRAPPER_LOGFILE"; then
	fail "unchanged post-clone mismatch consumed a useless recreation retry"
fi
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "unchanged post-clone mismatch left an automation workspace behind"
fi

# Cleanup failure is observable without replacing the reconciliation result.
# Use a retryable-conflict result (2) so a cleanup helper failure cannot be
# mistaken for the original status.
repo_cleanup_failure="${TMP}/repo-cleanup-failure"
remote_cleanup_failure="${TMP}/remote-cleanup-failure.git"
setup_sync_repo "$repo_cleanup_failure" "$remote_cleanup_failure"
remove_owned_workspace_definition=$(declare -f _ptsw_remove_owned_workspace)
planning_publish_definition=$(declare -f planning_publish)
_ptsw_remove_owned_workspace() {
	local workspace_root="$1"
	local expected_pid="$2"
	local expected_start="$3"
	: "$workspace_root" "$expected_pid" "$expected_start"
	return 73
}
planning_publish() {
	local worktree="$1"
	local commit_message="$2"
	local remote_name="$3"
	local branch_name="$4"
	local changed_paths="$5"
	: "$worktree" "$commit_message" "$remote_name" "$branch_name" "$changed_paths"
	PLANNING_PUBLISH_RESULT="retryable_conflict"
	return 2
}
cleanup_failure_rc=0
sync_todo_refs_for_repo owner/repo-cleanup-failure "$repo_cleanup_failure" || cleanup_failure_rc=$?
[[ "$cleanup_failure_rc" -eq 2 ]] || fail "cleanup failure replaced retryable reconciliation status"
grep -q 'workspace cleanup outcome=failure stage=publication repo=owner/repo-cleanup-failure workspace=pulse-todo-sync\.' \
	"$WRAPPER_LOGFILE" || fail "cleanup failure was not recorded with stage and workspace identity"
eval "$remove_owned_workspace_definition"
eval "$planning_publish_definition"
for leaked_workspace in "$AIDEVOPS_TEMP_DIR"/pulse-todo-sync.*; do
	[[ -d "$leaked_workspace" ]] || continue
	rm -rf "$leaked_workspace"
done

# A watchdog timeout sends TERM through the process tree. The function-local
# subshell owns its traps, removes the allocated workspace, and leaves caller
# trap state unchanged while the watchdog preserves its timeout result.
repo_timeout="${TMP}/repo-timeout"
remote_timeout="${TMP}/remote-timeout.git"
setup_sync_repo "$repo_timeout" "$remote_timeout"
run_issue_sync_stage_definition=$(declare -f _pulse_run_issue_sync_stage)
export SYNC_BLOCK_MARKER="${TMP}/sync-blocked"
export SYNC_BLOCK_RELEASE="${TMP}/sync-release"
rm -f "$SYNC_BLOCK_MARKER" "$SYNC_BLOCK_RELEASE"
_pulse_run_issue_sync_stage() {
	local script_dir="$1"
	local stage="$2"
	local repo_slug="$3"
	local workspace="$4"
	: "$script_dir" "$repo_slug" "$workspace"
	printf '%s\n' "$stage" >"$SYNC_BLOCK_MARKER"
	while [[ ! -e "$SYNC_BLOCK_RELEASE" ]]; do
		sleep 0.1
	done
	return 0
}
_kill_tree() {
	local process_pid="$1"
	local child_pid=""
	while IFS= read -r child_pid; do
		[[ -n "$child_pid" ]] && _kill_tree "$child_pid"
	done < <(pgrep -P "$process_pid" 2>/dev/null || true)
	kill "$process_pid" 2>/dev/null || true
	return 0
}
_force_kill_tree() {
	local process_pid="$1"
	local child_pid=""
	while IFS= read -r child_pid; do
		[[ -n "$child_pid" ]] && _force_kill_tree "$child_pid"
	done < <(pgrep -P "$process_pid" 2>/dev/null || true)
	kill -9 "$process_pid" 2>/dev/null || true
	return 0
}
unset _PULSE_WATCHDOG_LOADED 2>/dev/null || true
# shellcheck source=../pulse-watchdog.sh
source "$SCRIPTS_DIR/pulse-watchdog.sh"
export PRE_RUN_STAGE_TIMEOUT=1
timeout_rc=0
run_stage_with_timeout "sync_todo_refs_all_repos" 1 \
	sync_todo_refs_for_repo owner/repo-timeout "$repo_timeout" || timeout_rc=$?
[[ "$timeout_rc" -eq 124 ]] || fail "watchdog timeout status was not preserved"
[[ -e "$SYNC_BLOCK_MARKER" ]] || fail "watchdog fixture did not reach the allocated workspace stage"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "TERM timeout left a TODO-sync workspace behind"
fi
grep -q 'workspace cleanup outcome=removed stage=pull repo=owner/repo-timeout workspace=pulse-todo-sync\.' \
	"$WRAPPER_LOGFILE" || fail "TERM cleanup outcome was not recorded"
[[ $(trap -p EXIT) == "$parent_exit_trap_before" ]] || fail "timeout scope replaced the caller EXIT trap"
[[ $(trap -p TERM) == "$parent_term_trap_before" ]] || fail "timeout scope replaced the caller TERM trap"

# SIGKILL cannot run EXIT cleanup. Preserve that orphan, age its immutable
# owner marker, then prove the next bounded sweep moves it recoverably.
repo_kill="${TMP}/repo-kill"
remote_kill="${TMP}/remote-kill.git"
setup_sync_repo "$repo_kill" "$remote_kill"
export SYNC_BLOCK_MARKER="${TMP}/sync-kill-blocked"
rm -f "$SYNC_BLOCK_MARKER" "$SYNC_BLOCK_RELEASE"
sync_todo_refs_for_repo owner/repo-kill "$repo_kill" >/dev/null 2>&1 &
kill_sync_pid=$!
wait_for_file "$SYNC_BLOCK_MARKER" || fail "KILL fixture did not allocate a workspace"
kill_workspace=$(only_todo_sync_workspace) || fail "KILL fixture did not expose exactly one workspace"
_ptsw_read_owner_marker "$kill_workspace" || fail "KILL fixture owner marker was invalid"
kill_owner_pid="$_PTSW_OWNER_PID"
kill -0 "$kill_owner_pid" 2>/dev/null || fail "workspace marker did not identify a live sync owner"
if ! pgrep -P "$kill_sync_pid" 2>/dev/null | grep -qx "$kill_owner_pid"; then
	_force_kill_tree "$kill_sync_pid"
	wait "$kill_sync_pid" 2>/dev/null || true
	fail "workspace marker did not identify the sync process child"
fi
kill -9 "$kill_owner_pid" 2>/dev/null || fail "could not KILL sync owner"
kill_wait_rc=0
wait "$kill_sync_pid" 2>/dev/null || kill_wait_rc=$?
[[ "$kill_wait_rc" -eq 137 ]] || fail "KILL fixture returned unexpected status"
[[ -d "$kill_workspace" ]] || fail "KILL fixture did not preserve the orphan for recovery"
_ptsw_read_owner_marker "$kill_workspace" || fail "orphan owner marker became invalid"
old_owner_created=$(($(date +%s) - 10))
printf '%s\t%s\t%s\t%s\n' "$_PTSW_MARKER_VERSION" "$_PTSW_OWNER_PID" \
	"$old_owner_created" "$_PTSW_OWNER_START" >"${kill_workspace}/${_PTSW_OWNER_MARKER}"
export PULSE_TODO_SYNC_WORKSPACE_GRACE_SECS=2
export PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN=1
export AIDEVOPS_TODO_SYNC_TRASH_ROOT="${TMP}/todo-sync-trash"
kill_recovered=$(_ptsw_sweep_stale_workspaces)
[[ "$kill_recovered" == "1" ]] || fail "later sweep did not recover the KILL orphan"
[[ ! -e "$kill_workspace" ]] || fail "KILL orphan remained in the active temp root"
grep -q 'stale cleanup outcome=removed reason=dead-owner workspace=pulse-todo-sync\.' \
	"$WRAPPER_LOGFILE" || fail "KILL orphan recovery was not audited"
eval "$run_issue_sync_stage_definition"
unset PULSE_TODO_SYNC_WORKSPACE_GRACE_SECS PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN \
	AIDEVOPS_TODO_SYNC_TRASH_ROOT SYNC_BLOCK_MARKER SYNC_BLOCK_RELEASE

# GH#34511: unattended GitHub HTTPS Git authentication uses only the gh
# credential principal; inherited helpers never receive get/store/erase.
# Hermetic by construction (reference/testing.md "Credential-helper
# isolation"): every config source is a fixture and credential requests run
# outside any repository, so a regression reaches only the fake helper, never
# a real OS credential store or GUI prompt.
auth_root="${TMP}/github-auth"
auth_no_repo="${auth_root}/no-repo"
mkdir -p "${auth_root}/bin" "$auth_no_repo"
export TEST_INHERITED_LOG="${auth_root}/inherited.log"
export TEST_GH_LOG="${auth_root}/gh.log"
cat >"${auth_root}/inherited-helper" <<'HELPER'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"$TEST_INHERITED_LOG"
cat >/dev/null
printf 'username=inherited\npassword=inherited-synthetic\n'
HELPER
cat >"${auth_root}/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "auth git-credential" ]] || exit 1
printf '%s\n' "${3:-}" >>"$TEST_GH_LOG"
cat >/dev/null
[[ "${3:-}" == "get" && -z "${TEST_GH_NO_TOKEN:-}" ]] || exit 0
printf 'username=x-access-token\npassword=managed-synthetic\n'
GH
chmod +x "${auth_root}/inherited-helper" "${auth_root}/bin/gh"
repo_auth="${TMP}/repo-auth"
remote_auth="${TMP}/remote-auth.git"
setup_sync_repo "$repo_auth" "$remote_auth"
/usr/bin/git -C "$repo_auth" remote set-url origin git@github.com:owner/repo-auth.git
auth_global="${auth_root}/global.gitconfig"
/usr/bin/git config --file "$auth_global" credential.helper "${auth_root}/inherited-helper"
/usr/bin/git config --file "$auth_global" credential.https://github.com.helper "${auth_root}/inherited-helper"
/usr/bin/git config --file "$auth_global" "url.file://${remote_auth}.insteadOf" \
	https://github.com/owner/repo-auth.git
auth_previous_path="$PATH"
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ASKPASS SSH_ASKPASS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL="$auth_global"
export PATH="${auth_root}/bin:${PATH}"

# Hermeticity preflight: abort before any credential request if a helper
# outside the fixture is visible (for example a developer checkout's local
# credential.helper=osxkeychain).
auth_visible_helpers=$(cd "$auth_no_repo" && GIT_CEILING_DIRECTORIES="$auth_root" \
	/usr/bin/git config --get-regexp '^credential\..*helper$' || true)
while read -r auth_helper_key auth_helper_value; do
	[[ -n "$auth_helper_key" ]] || continue
	[[ "$auth_helper_value" == "${auth_root}/"* ]] ||
		fail "non-fixture credential helper visible to auth test: ${auth_helper_key}"
done <<<"$auth_visible_helpers"
# The fixture remote must resolve locally so no request leaves the host.
[[ $(/usr/bin/git config --get "url.file://${remote_auth}.insteadOf") == \
	https://github.com/owner/repo-auth.git ]] || fail "auth fixture global config is not in effect"

_test_github_credential_roundtrip() {
	local remote_url="$1"
	local credential=""
	# A prompt-capable context is a regression; record it and refuse.
	if [[ "${GIT_TERMINAL_PROMPT:-}" != "0" || -n "${GIT_ASKPASS:-}" || -n "${SSH_ASKPASS:-}" ]]; then
		printf '%s\n' prompt-capable >>"$TEST_INHERITED_LOG"
		return 1
	fi
	credential=$(cd "$auth_no_repo" && GIT_CEILING_DIRECTORIES="$auth_root" GIT_TERMINAL_PROMPT=0 \
		/usr/bin/git credential fill <<<"$(printf 'protocol=https\nhost=github.com\npath=%s\n' \
			"${remote_url#https://github.com/}")") || return 1
	(cd "$auth_no_repo" && GIT_CEILING_DIRECTORIES="$auth_root" GIT_TERMINAL_PROMPT=0 \
		/usr/bin/git credential approve <<<"${credential}") || return 1
	return 0
}
auth_original_git_definition=$(declare -f git)
# Fixture remotes are local, so emulate the credential exchange real HTTPS
# would perform for each GitHub network command, then run it via insteadOf.
git() {
	local arg="" prev="" subcommand="" repo_dir="" target=""
	for arg in "$@"; do
		if [[ "$prev" == "-C" ]]; then
			repo_dir="$arg"
		elif [[ -z "$subcommand" && "$arg" != -* ]]; then
			subcommand="$arg"
		fi
		[[ "$arg" == https://github.com/* ]] && target="$arg"
		prev="$arg"
	done
	case "$subcommand" in
	clone | fetch | ls-remote | push)
		if [[ -z "$target" && -n "$repo_dir" ]]; then
			target=$(/usr/bin/git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
		fi
		if [[ "$target" == https://github.com/* ]]; then
			_test_github_credential_roundtrip "$target" || return 128
		fi
		;;
	esac
	/usr/bin/git "$@"
	return $?
}

: >"$TEST_INHERITED_LOG"
: >"$TEST_GH_LOG"
auth_rc=0
GIT_ASKPASS=/bin/echo SSH_ASKPASS=/bin/echo \
	sync_todo_refs_for_repo owner/repo-auth "$repo_auth" || auth_rc=$?
[[ "$auth_rc" -eq 0 ]] || fail "SSH-registered GitHub repo did not sync through the gh helper (rc=${auth_rc})"
[[ ! -s "$TEST_INHERITED_LOG" ]] ||
	fail "inherited credential helper or prompt path was used: $(tr '\n' ' ' <"$TEST_INHERITED_LOG")"
if ! grep -qx get "$TEST_GH_LOG" || ! grep -qx store "$TEST_GH_LOG"; then
	fail "gh credential helper did not serve get/store for TODO sync"
fi
git --git-dir="$remote_auth" show main:TODO.md | grep -q '^synced:owner/repo-auth$' ||
	fail "gh-authenticated TODO sync did not publish"
[[ -z "${GIT_CONFIG_COUNT:-}" && -z "${GIT_TERMINAL_PROMPT:-}" ]] ||
	fail "TODO-sync auth context leaked into the caller"

# Canonical refresh reads use the same isolation.
: >"$TEST_INHERITED_LOG"
: >"$TEST_GH_LOG"
auth_ls_remote=$(_pulse_unattended_git ls-remote https://github.com/owner/repo-auth.git refs/heads/main) ||
	fail "isolated canonical ls-remote failed"
[[ "$auth_ls_remote" == *refs/heads/main* ]] || fail "isolated canonical ls-remote returned no default ref"
if [[ -s "$TEST_INHERITED_LOG" ]] || ! grep -qx get "$TEST_GH_LOG"; then
	fail "canonical refresh ls-remote did not use only the gh helper"
fi

# Missing managed credentials fail once with redacted, actionable guidance.
: >"$TEST_INHERITED_LOG"
auth_missing_rc=0
auth_missing_output=$(TEST_GH_NO_TOKEN=1 \
	sync_todo_refs_for_repo owner/repo-auth "$repo_auth" 2>&1) || auth_missing_rc=$?
[[ "$auth_missing_rc" -eq 1 ]] || fail "missing gh credential was not a retryable failure"
[[ ! -s "$TEST_INHERITED_LOG" ]] || fail "missing gh credential fell back to an inherited helper"
[[ "$auth_missing_output" == *"reason=github_auth_unavailable action=run_gh_auth_status"* ]] ||
	fail "missing gh credential omitted actionable guidance: ${auth_missing_output}"
[[ "$auth_missing_output" != *synthetic* ]] || fail "auth failure diagnostic exposed a credential"
if only_todo_sync_workspace >/dev/null 2>&1; then
	fail "auth failure left an automation workspace behind"
fi

# Isolation is host-scoped: other hosts keep their configured helpers.
: >"$TEST_INHERITED_LOG"
: >"$TEST_GH_LOG"
(
	_ptsw_isolate_github_git_auth || exit 1
	cd "$auth_no_repo" || exit 1
	GIT_CEILING_DIRECTORIES="$auth_root" /usr/bin/git credential fill \
		<<<"$(printf 'protocol=https\nhost=example.invalid\npath=o/r.git\n')" >/dev/null
) || fail "non-GitHub credential lookup failed under isolation"
if ! grep -qx get "$TEST_INHERITED_LOG" || [[ -s "$TEST_GH_LOG" ]]; then
	fail "GitHub isolation changed a non-GitHub host's helper"
fi

eval "$auth_original_git_definition"
unset -f _test_github_credential_roundtrip
unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL TEST_INHERITED_LOG TEST_GH_LOG
export PATH="$auth_previous_path"

printf 'PASS: issue sync automation-workspace contract\n'
