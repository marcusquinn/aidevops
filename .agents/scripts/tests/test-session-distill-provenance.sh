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
/usr/bin/git -C "$repository" remote add origin https://github.com/example/repository.git
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
unrelated_commit=$(/usr/bin/git -C "$repository" rev-parse HEAD)
ledger="$workspace/sessions/provenance-session/git-provenance.json"
jq --arg commit "$unrelated_commit" '.items += [{idempotency_key:"cross-repo",repository:"other/repository",pr_number:"202",commit:$commit,head_commit:$commit,merge_commit:"",branch:"main",worktree:"[local-path]",captured_at:"2026-01-01T00:00:00Z"}]' "$ledger" >"${ledger}.tmp"
mv "${ledger}.tmp" "$ledger"

(
	cd "$repository"
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' "$HELPER" analyze >/dev/null
	AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID='provenance-session' "$HELPER" extract >/dev/null
)
analysis="$workspace/sessions/provenance-session/session-analysis.json"
learnings="$workspace/sessions/provenance-session/extracted-learnings.json"
jq -e '.commit_attribution == "authoritative"' "$analysis" >/dev/null || fail 'captured attribution was not authoritative'
jq -e '.recent_commits == ["fix: session-owned provenance"]' "$analysis" >/dev/null || fail 'analysis used commits outside captured provenance'
jq -e 'all(.[]; .content != "fix: unrelated current main")' "$learnings" >/dev/null || fail 'unrelated current-main commit was distilled'
[[ "$(jq '[.items[] | select(.idempotency_key != "cross-repo")] | length' "$ledger")" == 1 ]] || fail 'provenance capture was not idempotent'
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

(
	merge_scripts="$tmp_dir/merge-scripts"
	mkdir -p "$merge_scripts"
	cat >"$merge_scripts/session-distill-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${AIDEVOPS_SESSION_ID:-}" "$*" >>"${CAPTURE_CALLS:?}"
EOF
	chmod +x "$merge_scripts/session-distill-helper.sh"
	SCRIPT_DIR="$(cd "$(dirname "$HELPER")" && pwd)"
	# shellcheck source=../full-loop-helper-merge.sh
	source "$SCRIPT_DIR/full-loop-helper-merge.sh"
	SCRIPT_DIR="$merge_scripts"
	export CAPTURE_CALLS="$tmp_dir/capture-calls"
	unset AIDEVOPS_SESSION_ID OPENCODE_SESSION_ID CLAUDE_SESSION_ID
	_merge_capture_session_distill_provenance 303 example/repository "$worktree"$'\t'bugfix/session-owned$'\t'"$repository"
	[[ ! -f "$CAPTURE_CALLS" ]] || fail 'merge capture invented a shared fallback session ID'
	AIDEVOPS_SESSION_ID='merge-session' _merge_capture_session_distill_provenance 303 example/repository "$worktree"$'\t'bugfix/session-owned$'\t'"$repository"
	grep -q '^merge-session|provenance --pr 303 --repo example/repository ' "$CAPTURE_CALLS" || fail 'merge capture did not preserve the authoritative session boundary'
)

printf 'PASS: session distillation uses durable provenance and fails closed after cleanup\n'
