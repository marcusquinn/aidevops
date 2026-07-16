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
	printf '%s\n' "synced:${repo}" >>"${root}/TODO.md"
fi
FIXTURE
chmod +x "${fixture_scripts}/issue-sync-helper.sh"

export CALL_LOG="${TMP}/calls.log"
export WRAPPER_LOGFILE="${TMP}/pulse.log"
export SCRIPT_DIR="$fixture_scripts"
export AIDEVOPS_TEMP_DIR="${TMP}/automation"
export AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true
export GIT_AUTHOR_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test
export GIT_COMMITTER_EMAIL=test@example.com
# shellcheck source=/dev/null
source "$fixture_scripts/pulse-wrapper-cycle.sh"

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
sync_todo_refs_for_repo owner/repo-a "$repo_a"
[[ $(canonical_snapshot "$repo_a") == "$snapshot_a" ]] || fail "repo A canonical checkout changed"
[[ $(canonical_snapshot "$repo_b") == "$snapshot_b" ]] || fail "repo A invocation changed repo B"
git --git-dir="$remote_a" show main:TODO.md | grep -q '^synced:owner/repo-a$' || fail "repo A remote was not synced"

sync_todo_refs_for_repo owner/repo-b "$repo_b"
[[ $(canonical_snapshot "$repo_a") == "$snapshot_a" ]] || fail "repo B invocation changed repo A"
[[ $(canonical_snapshot "$repo_b") == "$snapshot_b" ]] || fail "repo B canonical checkout changed"
git --git-dir="$remote_b" show main:TODO.md | grep -q '^synced:owner/repo-b$' || fail "repo B remote was not synced"

[[ $(wc -l <"$CALL_LOG" | tr -d ' ') -eq 8 ]] || fail "pulse did not make four bound calls per repository"
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

printf 'PASS: issue sync automation-workspace contract\n'
