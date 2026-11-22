#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${TEST_DIR}/../local-branch-cleanup-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
[[ -d "$TEMP_PARENT" ]] || exit 1
ROOT=$(mktemp -d "${TEMP_PARENT}/test-local-branch-fork.XXXXXX")
REPO="$ROOT/repo"
BIN="$ROOT/bin"
cleanup() {
	rm -rf -- "$ROOT"
	return 0
}
trap cleanup EXIT
fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}
assert_has() {
	local value="$1" expected="$2"
	[[ "$value" == *"$expected"* ]] || fail "missing $expected in $value"
	return 0
}
run_scan() {
	bash "$HELPER" --repo "$REPO" "$@" || return 1
	return 0
}

mkdir "$BIN"
git init -q "$REPO"
git -C "$REPO" config user.name 'Fork Cleanup Test'
git -C "$REPO" config user.email test@example.invalid
TREE=$(git -C "$REPO" mktree </dev/null)
BASE=$(git -C "$REPO" commit-tree "$TREE" -m base)
TIP=$(git -C "$REPO" commit-tree "$TREE" -p "$BASE" -m tip)
MERGED_HEAD=$(git -C "$REPO" commit-tree "$TREE" -p "$TIP" -m merged-head)
OTHER=$(git -C "$REPO" commit-tree "$TREE" -p "$BASE" -m other)
git -C "$REPO" update-ref refs/heads/main "$BASE"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" remote add origin https://github.com/base/project.git
git -C "$REPO" remote add fork git@github.com:contributor/project.git
for remote in origin fork; do
	git -C "$REPO" update-ref "refs/remotes/$remote/main" "$BASE"
	git -C "$REPO" symbolic-ref "refs/remotes/$remote/HEAD" "refs/remotes/$remote/main"
done
for branch in exact ancestor absent unrelated unmerged lookup-error renamed open-local fallback; do
	git -C "$REPO" update-ref "refs/heads/$branch" "$TIP"
	git -C "$REPO" config "branch.$branch.remote" fork
	git -C "$REPO" config "branch.$branch.merge" "refs/heads/$branch"
done
git -C "$REPO" config branch.renamed.merge refs/heads/topic/original
git -C "$REPO" config branch.open-local.merge refs/heads/open-topic
git -C "$REPO" config --remove-section branch.fallback
export TIP MERGED_HEAD OTHER
export GH_LOG="$ROOT/gh.log"
export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/transport"
export WORKTREE_REGISTRY_DIR="$ROOT/registry"
export WORKTREE_REGISTRY_DB="$ROOT/registry/owners.db"
export AUDIT_LOG_DIR="$ROOT/audit"

cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
'api repos/base/project')
	[[ "${FAIL_METADATA:-0}" != 1 ]] || exit 1
	printf '%s\n' '{"fork":false,"full_name":"base/project"}' ;;
'api repos/contributor/project') printf '%s\n' '{"fork":true,"parent":{"full_name":"base/project"}}' ;;
*'repos/base/project/pulls?state=open&'*) printf '%s\n' '[{"head":{"ref":"open-topic"}}]' ;;
*'repos/base/project/pulls?state=closed&head='*)
	args="$*"
	ref="${args#*head=}"
	ref="${ref%%&*}"
	merged='"2026-11-03T00:00:00Z"'
	case "$ref" in
	contributor%3Aexact) ref=exact; sha="$TIP" ;;
	contributor%3Aancestor) ref=ancestor; sha="$MERGED_HEAD" ;;
	contributor%3Aabsent) ref=absent; sha=1111111111111111111111111111111111111111 ;;
	contributor%3Aunrelated) ref=unrelated; sha="$OTHER" ;;
	contributor%3Aunmerged) ref=unmerged; sha="$TIP"; merged=null ;;
	contributor%3Afork-only) printf '%s\n' '[]'; exit 0 ;;
	contributor%3Alookup-error) exit 1 ;;
	contributor%3Atopic%2Foriginal) ref=topic/original; sha="$TIP" ;;
	base%3Afallback) ref=fallback; sha="$TIP" ;;
	*) exit 1 ;;
	esac
	if [[ "${PAGE_FAILURE:-0}" == 1 ]]; then
		[[ "$args" == *'page=1' ]] || exit 1
		jq -n --arg ref "$ref" --arg sha "$sha" '[range(0;100) | {head:{ref:$ref,sha:$sha},merged_at:"2026-11-03T00:00:00Z"}]'
		exit 0
	fi
	if [[ "${FAIL_RECHECK:-0}" == 1 ]]; then
		count=$(grep -c 'state=closed' "$GH_LOG")
		[[ "$count" -lt 2 ]] || { printf '%s\n' '[]'; exit 0; }
	fi
	printf '[{"head":{"ref":"%s","sha":"%s"},"merged_at":%s}]\n' "$ref" "$sha" "$merged" ;;
*) exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

dry=$(run_scan)
assert_has "$dry" 'would-delete exact merged PR head SHA'
assert_has "$dry" 'would-delete ancestor merged PR head ancestor'
assert_has "$dry" 'would-delete renamed merged PR head SHA'
assert_has "$dry" 'would-delete fallback merged PR head SHA'
assert_has "$dry" 'keep absent unmerged local commits'
assert_has "$dry" 'keep unrelated unmerged local commits'
assert_has "$dry" 'keep unmerged unmerged local commits'
assert_has "$dry" 'keep lookup-error github evidence unavailable'
assert_has "$dry" 'keep open-local open PR exists'
[[ $(grep -c '^api repos/base/project$' "$GH_LOG") -eq 1 ]] || fail 'metadata not cached per scan'
[[ $(grep -c 'state=open' "$GH_LOG") -eq 1 ]] || fail 'open listing not cached'

dry=$(run_scan --remote fork)
assert_has "$dry" 'would-delete exact merged PR head SHA'
assert_has "$dry" 'would-delete ancestor merged PR head ancestor'
assert_has "$dry" 'would-delete renamed merged PR head SHA'
[[ $(grep -c '^api repos/contributor/project$' "$GH_LOG") -eq 1 ]] || fail 'fork metadata not cached'

budget=$(run_scan --branch ancestor --max-lookups 0)
assert_has "$budget" 'keep ancestor lookup budget exhausted'
failed=$(FAIL_METADATA=1 run_scan --branch exact)
assert_has "$failed" 'keep exact github evidence unavailable'

# A positive first page cannot authorize deletion if remaining pages fail or
# exceed the request cap, and mutation rechecks share the same cap.
: >"$GH_LOG"
budget=$(PAGE_FAILURE=1 run_scan --branch exact --max-lookups 1)
assert_has "$budget" 'keep exact lookup budget exhausted'
[[ $(grep -c 'state=closed' "$GH_LOG") -eq 1 ]] || fail 'pagination exceeded budget'
failed=$(PAGE_FAILURE=1 run_scan --branch exact --max-lookups 2)
assert_has "$failed" 'keep exact github evidence unavailable'
: >"$GH_LOG"
budget=$(run_scan --branch exact --apply --max-lookups 1)
assert_has "$budget" 'keep exact open PR or github evidence unavailable'
[[ $(grep -c 'state=closed' "$GH_LOG") -eq 1 ]] || fail 'mutation recheck exceeded budget'
git -C "$REPO" show-ref --verify --quiet refs/heads/exact || fail 'budget exhaustion deleted a ref'

# The production apply path must recheck positive PR evidence before deletion.
: >"$GH_LOG"
refused=$(FAIL_RECHECK=1 run_scan --branch exact --apply)
assert_has "$refused" 'keep exact open PR or github evidence unavailable'
git -C "$REPO" show-ref --verify --quiet refs/heads/exact || fail 'lost evidence still deleted a ref'
applied=$(run_scan --branch ancestor --remote fork --apply)
assert_has "$applied" "deleted ancestor $TIP"
if git -C "$REPO" show-ref --verify --quiet refs/heads/ancestor; then
	fail 'ancestor branch survived apply'
fi
[[ "$(git -C "$REPO" worktree list --porcelain)" != *"$ROOT/transport"* ]] || fail 'deletion transport leaked'

# A commit reachable from the fork's main but not the parent's main is not
# upstream merge evidence, even if the parent has no open PR for it.
git -C "$REPO" update-ref refs/heads/fork-only "$TIP"
git -C "$REPO" update-ref refs/remotes/fork/main "$TIP"
git -C "$REPO" config branch.fork-only.remote fork
git -C "$REPO" config branch.fork-only.merge refs/heads/fork-only
refused=$(run_scan --remote fork --branch fork-only --apply)
assert_has "$refused" 'keep fork-only unmerged local commits'
git -C "$REPO" show-ref --verify --quiet refs/heads/fork-only || fail 'fork-only ancestry deleted a ref'
printf 'PASS: fork PR exact, ancestor, absent object, renamed upstream, errors, budget and apply guards\n'
