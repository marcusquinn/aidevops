#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../session-distill-helper.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
workspace="$tmp_dir/workspace"
repository="$tmp_dir/repository"
worktree="$tmp_dir/session-worktree"

/usr/bin/git init -q -b main "$repository"
printf 'base\n' >"$repository/file.txt"
/usr/bin/git -C "$repository" add file.txt
GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
	/usr/bin/git -C "$repository" -c commit.gpgsign=false commit -q -m 'chore: base'
/usr/bin/git -C "$repository" worktree add -q -b bugfix/session-owned "$worktree"
printf 'session\n' >>"$worktree/file.txt"
GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
	/usr/bin/git -C "$worktree" -c commit.gpgsign=false commit -q -am 'fix: session-owned provenance'
session_commit=$(/usr/bin/git -C "$worktree" rev-parse HEAD)

AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' \
	"$HELPER" provenance --commit "$session_commit" --branch bugfix/session-owned \
	--worktree "$worktree" --repo example/repository --pr 101 >/dev/null
AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' \
	"$HELPER" provenance --commit "$session_commit" --branch bugfix/session-owned \
	--worktree "$worktree" --repo example/repository --pr 101 >/dev/null

GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
	/usr/bin/git -C "$repository" -c commit.gpgsign=false merge -q --no-ff bugfix/session-owned -m 'merge session work'
/usr/bin/git -C "$repository" worktree remove "$worktree"
/usr/bin/git -C "$repository" branch -D bugfix/session-owned >/dev/null
printf 'unrelated\n' >>"$repository/file.txt"
GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
	/usr/bin/git -C "$repository" -c commit.gpgsign=false commit -q -am 'fix: unrelated current main'

(
	cd "$repository"
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' "$HELPER" analyze >/dev/null
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' "$HELPER" extract >/dev/null
)
analysis="$workspace/sessions/provenance-session/session-analysis.json"
learnings="$workspace/sessions/provenance-session/extracted-learnings.json"
ledger="$workspace/sessions/provenance-session/git-provenance.json"
jq -e '.commit_attribution == "authoritative"' "$analysis" >/dev/null || fail 'captured attribution was not authoritative'
jq -e '.recent_commits == ["fix: session-owned provenance"]' "$analysis" >/dev/null || fail 'analysis used commits outside captured provenance'
jq -e 'all(.[]; .content != "fix: unrelated current main")' "$learnings" >/dev/null || fail 'unrelated current-main commit was distilled'
[[ "$(jq '.items | length' "$ledger")" == 1 ]] || fail 'provenance capture was not idempotent'
jq -e '.items[0].worktree == "[local-path]"' "$ledger" >/dev/null || fail 'worktree path was not privacy-redacted'

(
	cd "$repository"
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='missing-provenance' "$HELPER" analyze >/dev/null
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='missing-provenance' "$HELPER" extract >/dev/null
)
missing_analysis="$workspace/sessions/missing-provenance/session-analysis.json"
missing_learnings="$workspace/sessions/missing-provenance/extracted-learnings.json"
jq -e '.commit_attribution == "unavailable" and .recent_commits == []' "$missing_analysis" >/dev/null || fail 'missing provenance did not fail closed'
jq -e 'length == 0' "$missing_learnings" >/dev/null || fail 'missing provenance guessed current-branch learnings'

printf 'PASS: session distillation uses durable provenance and fails closed after cleanup\n'
