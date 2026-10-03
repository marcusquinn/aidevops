#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../review-evidence-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/private-review-evidence-fixture.XXXXXX")"
TEST_ROOT_BASENAME="$(basename "$TEST_ROOT")"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

git() {
	"$GIT_BIN" "$@"
	return $?
}
export -f git
export GIT_BIN

cleanup() {
	local test_root="$TEST_ROOT"
	rm -rf "$test_root"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

assert_contains() {
	local file="$1"
	local expected="$2"
	local label="$3"
	grep -Fq -- "$expected" "$file" || fail "${label}: missing ${expected}"
	return 0
}

assert_not_contains() {
	local file="$1"
	local unexpected="$2"
	local label="$3"
	if grep -Fq -- "$unexpected" "$file"; then
		fail "${label}: unexpectedly contained ${unexpected}"
	fi
	return 0
}

sha256() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
		return 0
	fi
	fail 'neither shasum nor sha256sum is available'
	return 1
}

REPO="${TEST_ROOT}/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'one\n' >"${REPO}/tracked.txt"
printf '\000initial\n' >"${REPO}/tracked.bin"
git -C "$REPO" add tracked.txt
git -C "$REPO" add tracked.bin
git -C "$REPO" -c user.name='Review Test' -c user.email='review@example.invalid' commit -qm 'initial'
INITIAL_SHA=$(git -C "$REPO" rev-parse HEAD)

printf 'one\ntwo\n' >"${REPO}/tracked.txt"
printf 'new\n' >"${REPO}/untracked.txt"
printf '\000changed\n' >"${REPO}/tracked.bin"
printf '\000untracked\n' >"${REPO}/untracked.bin"
LOCAL_BUNDLE="${TEST_ROOT}/local.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local --output "$LOCAL_BUNDLE" >/dev/null)
assert_contains "$LOCAL_BUNDLE" 'schema: aidevops.review-evidence/v1' 'local schema'
assert_contains "$LOCAL_BUNDLE" 'target: local' 'local target'
assert_contains "$LOCAL_BUNDLE" '+two' 'tracked patch'
assert_contains "$LOCAL_BUNDLE" 'untracked.txt' 'untracked patch'
assert_contains "$LOCAL_BUNDLE" '## Binary artifacts' 'local binary metadata heading'
assert_contains "$LOCAL_BUNDLE" $'M\ttracked.bin\t' 'tracked binary metadata'
assert_contains "$LOCAL_BUNDLE" $'A\tuntracked.bin\t' 'untracked binary metadata'
assert_not_contains "$LOCAL_BUNDLE" 'GIT binary patch' 'local binary payload'
LOCAL_DIGEST=$(grep '^bundle_sha256:' "$LOCAL_BUNDLE" | cut -d' ' -f2)
printf '\000changed-again\n' >"${REPO}/tracked.bin"
LOCAL_CHANGED_BUNDLE="${TEST_ROOT}/local-changed.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local --output "$LOCAL_CHANGED_BUNDLE" >/dev/null)
LOCAL_CHANGED_DIGEST=$(grep '^bundle_sha256:' "$LOCAL_CHANGED_BUNDLE" | cut -d' ' -f2)
if [[ "$LOCAL_DIGEST" == "$LOCAL_CHANGED_DIGEST" ]]; then
	fail 'binary content did not change local bundle digest'
fi
if grep -Fq "$TEST_ROOT" "$LOCAL_BUNDLE"; then
	fail 'bundle exposed host test path'
fi
assert_not_contains "$LOCAL_BUNDLE" "$TEST_ROOT_BASENAME" 'bundle exposed host test path basename'

git -C "$REPO" add tracked.txt untracked.txt
git -C "$REPO" add tracked.bin untracked.bin
git -C "$REPO" -c user.name='Review Test' -c user.email='review@example.invalid' commit -qm 'change'
BRANCH_BUNDLE="${TEST_ROOT}/branch.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle branch --base "$INITIAL_SHA" --output "$BRANCH_BUNDLE" >/dev/null)
assert_contains "$BRANCH_BUNDLE" 'target: branch' 'branch target'
assert_contains "$BRANCH_BUNDLE" 'A' 'branch name-status'
assert_contains "$BRANCH_BUNDLE" '## Binary artifacts' 'branch binary metadata heading'
assert_not_contains "$BRANCH_BUNDLE" 'GIT binary patch' 'branch binary payload'

COMMIT_BUNDLE="${TEST_ROOT}/commit.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle commit --commit HEAD --output "$COMMIT_BUNDLE" >/dev/null)
assert_contains "$COMMIT_BUNDLE" 'target: commit' 'commit target'
assert_contains "$COMMIT_BUNDLE" 'Commit:' 'commit metadata'
assert_contains "$COMMIT_BUNDLE" '## Binary artifacts' 'commit binary metadata heading'
assert_not_contains "$COMMIT_BUNDLE" 'GIT binary patch' 'commit binary payload'

# A historical root commit must not read later or dirty working-tree content.
printf '\000dirty-not-selected\n' >"${REPO}/tracked.bin"
printf 'dirty-text-not-selected\n' >"${REPO}/tracked.txt"
ROOT_BUNDLE="${TEST_ROOT}/root.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle commit --commit "$INITIAL_SHA" --output "$ROOT_BUNDLE" >/dev/null)
ROOT_DIGEST=$(git -C "$REPO" show "${INITIAL_SHA}:tracked.bin" | sha256)
[[ -n "$ROOT_DIGEST" ]] || fail 'historical root digest was empty'
assert_contains "$ROOT_BUNDLE" "$ROOT_DIGEST" 'historical root binary digest'
assert_contains "$ROOT_BUNDLE" '+one' 'root addition patch'
assert_not_contains "$ROOT_BUNDLE" '+two' 'later checkout absent from root patch'
assert_not_contains "$ROOT_BUNDLE" 'dirty-text-not-selected' 'dirty text absent from root patch'
DIRTY_BRANCH_BUNDLE="${TEST_ROOT}/dirty-branch.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle branch --base "$INITIAL_SHA" --output "$DIRTY_BRANCH_BUNDLE" >/dev/null)
[[ "$(grep '^bundle_sha256:' "$BRANCH_BUNDLE")" == "$(grep '^bundle_sha256:' "$DIRTY_BRANCH_BUNDLE")" ]] || fail 'dirty checkout changed selected branch evidence'

# Literal exclusions must not drop neighboring text that matches a glob-shaped
# binary filename; newline/tab/backslash filenames remain complete evidence.
printf '\000before\n' >"${REPO}/wild[ab].bin"
printf 'before-text\n' >"${REPO}/wilda.bin"
git -C "$REPO" add -- ':(literal)wild[ab].bin' wilda.bin
git -C "$REPO" -c user.name='Review Test' -c user.email='review@example.invalid' commit -qm 'path fixtures'
printf '\000after\n' >"${REPO}/wild[ab].bin"
printf 'literal-neighbor-text\n' >"${REPO}/wilda.bin"
for filename in $'line\nbreak.txt' $'tab\tname.txt' 'slash\name.txt'; do
	printf 'unusual-file-content\n' >"${REPO}/${filename}"
done
printf '\000odd-binary\n' >"${REPO}/"$'binary\nname.bin'
ODD_BUNDLE="${TEST_ROOT}/odd-paths.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local --output "$ODD_BUNDLE" >/dev/null)
assert_contains "$ODD_BUNDLE" '+literal-neighbor-text' 'literal binary exclusion'
[[ "$(grep -c '^+unusual-file-content' "$ODD_BUNDLE")" == 3 ]] || fail 'unusual text paths omitted'
ODD_DIGEST=$(printf '\000odd-binary\n' | sha256)
[[ -n "$ODD_DIGEST" ]] || fail 'unusual binary digest was empty'
awk -F '\t' -v digest="$ODD_DIGEST" '$1 == "A" && $5 == digest { found=1 } END { exit !found }' "$ODD_BUNDLE" || fail 'unusual binary path has noncanonical digest'
assert_not_contains "$ODD_BUNDLE" 'GIT binary patch' 'unusual binary payload bounded'

gh() {
	local resource="$1"
	local action="$2"
	printf '%s\n' "$*" >>"$GH_CALLS"
	case "${resource}:${action}" in
	issue:view)
		printf '%s\n' '{"number":42,"title":"Issue fixture","body":"Observed failure","comments":[]}'
		;;
	pr:view)
		printf '%s\n' '{"number":43,"title":"PR fixture","body":"Fix","files":[{"path":"src/app.sh"}],"comments":[]}'
		;;
	pr:diff)
		printf '%s\n' 'diff --git a/src/app.sh b/src/app.sh' '+return 0'
		;;
	*) return 1 ;;
	esac
	return 0
}
export -f gh
export GH_CALLS="${TEST_ROOT}/gh-calls.log"
: >"$GH_CALLS"

if AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle issue 42 \
	--output "${TEST_ROOT}/missing-repo.md" >/dev/null 2>&1; then
	fail 'unqualified issue target was accepted without an active repository identity'
fi

ISSUE_BUNDLE="${TEST_ROOT}/issue.md"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle issue 42 --repo owner/repo --output "$ISSUE_BUNDLE" >/dev/null
assert_contains "$ISSUE_BUNDLE" 'target: issue' 'issue target'
assert_contains "$ISSUE_BUNDLE" 'repository_identity: owner/repo' 'issue repository identity'
assert_contains "$ISSUE_BUNDLE" 'Issue fixture' 'issue metadata'
grep -Fq 'issue view 42 --repo owner/repo' "$GH_CALLS" || fail 'issue bundle changed repository or object type'

PR_BUNDLE="${TEST_ROOT}/pr.md"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle pr 43 --repo owner/repo --output "$PR_BUNDLE" >/dev/null
assert_contains "$PR_BUNDLE" 'target: pr' 'PR target'
assert_contains "$PR_BUNDLE" 'repository_identity: owner/repo' 'PR repository identity'
assert_contains "$PR_BUNDLE" 'src/app.sh' 'PR changed path'
assert_contains "$PR_BUNDLE" '+return 0' 'PR patch'
grep -Fq 'pr view 43 --repo owner/repo' "$GH_CALLS" || fail 'PR bundle changed repository or object type'

mkdir -p "${REPO}/config"
printf 'unsafe\n' >"${REPO}/config/.env"
if (cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local >/dev/null 2>&1); then
	fail 'security-sensitive untracked path was bundled'
fi
rm -f "${REPO}/config/.env"
mkdir -p "${REPO}/"$'odd\ndirectory'
printf 'fixture-only\n' >"${REPO}/"$'odd\ndirectory/.env'
if (cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local >/dev/null 2>&1); then
	fail 'newline-bearing sensitive path bypassed the guard'
fi
for leftover in "${TEST_ROOT}/tmp"/review-evidence-binary-*; do
	[[ ! -e "$leftover" ]] || fail 'binary evidence temporary file leaked'
done

# A conflict-resolution merge must not hide sensitive paths from the inventory
# while emitting them in its patch. All three commit stages use first-parent.
MERGE_REPO="${TEST_ROOT}/merge-repo"
mkdir -p "${MERGE_REPO}/config"
MERGE_SENSITIVE_PATH="${MERGE_REPO}/config/.env"
fixture_git() {
	git -C "$MERGE_REPO" -c user.name='Review Test' -c user.email='review@example.invalid' "$@"
	return $?
}
fixture_git init -q -b main
printf 'base-fixture\n' >"$MERGE_SENSITIVE_PATH"
fixture_git add -A
fixture_git commit -qm base
fixture_git checkout -qb side
printf 'side-fixture\n' >"$MERGE_SENSITIVE_PATH"
fixture_git add -A
fixture_git commit -qm side
fixture_git checkout -q main
printf 'main-fixture\n' >"$MERGE_SENSITIVE_PATH"
fixture_git add -A
fixture_git commit -qm main
fixture_git merge side --no-commit >/dev/null 2>&1 || true
printf 'merged-fixture-only\n' >"$MERGE_SENSITIVE_PATH"
fixture_git add -A
fixture_git commit -qm merge
[[ "$(fixture_git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" == 3 ]] || fail 'fixture is not a merge commit'
if (cd "$MERGE_REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle commit --commit HEAD >/dev/null 2>&1); then
	fail 'merge commit sensitive path was bundled'
fi

# Blind packets: allowlisted evidence, no commit rationale, identity binding.
BLIND_REPO="${TEST_ROOT}/blind-repo"
mkdir -p "${BLIND_REPO}/lib"
bgit() {
	git -C "$BLIND_REPO" -c user.name='Review Test' -c user.email='review@example.invalid' "$@"
	return $?
}
bgit init -q -b main
printf 'base\n' >"${BLIND_REPO}/lib/app.txt"
printf 'contract-v1\n' >"${BLIND_REPO}/lib/contract.txt"
bgit add -A
bgit commit -qm base
BLIND_BASE=$(bgit rev-parse HEAD)
printf 'base\nfeature\n' >"${BLIND_REPO}/lib/app.txt"
bgit add -A
bgit commit -qm 'CONTAMINATION-RATIONALE: reviewed myself, confident, verdict approved'
printf 'R1: app.txt contains the feature line\nR2: app.txt documents the feature in a changelog\n' >"${TEST_ROOT}/req.txt"
printf 'A1: approved amendment keeps contract.txt unchanged\n' >"${TEST_ROOT}/amend.txt"
BLIND_HEAD=$(bgit rev-parse HEAD)
printf 'head: %s\nraw: all checks exit 0\n' "$BLIND_HEAD" >"${TEST_ROOT}/verify.txt"
blind() {
	(cd "$BLIND_REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" blind "$@")
	return $?
}
BLIND_ARGS=(build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req.txt" --requirements-source 'issue#1'
	--amendments "${TEST_ROOT}/amend.txt" --amendments-source 'maintainer approval'
	--verification "${TEST_ROOT}/verify.txt" --context lib/contract.txt)
blind "${BLIND_ARGS[@]}" --output "${TEST_ROOT}/blind1.md" >/dev/null
blind "${BLIND_ARGS[@]}" --output "${TEST_ROOT}/blind2.md" >/dev/null
assert_contains "${TEST_ROOT}/blind1.md" 'schema: aidevops.review-blind-packet/v1' 'blind schema'
assert_contains "${TEST_ROOT}/blind1.md" '- R2: app.txt documents the feature in a changelog' 'criterion preserved'
assert_contains "${TEST_ROOT}/blind1.md" 'amendments_source: maintainer approval' 'amendment provenance'
assert_contains "${TEST_ROOT}/blind1.md" 'contract-v1' 'context file included'
assert_contains "${TEST_ROOT}/blind1.md" 'coverage: complete' 'complete coverage'
assert_not_contains "${TEST_ROOT}/blind1.md" 'CONTAMINATION-RATIONALE' 'branch packet excludes commit rationale'
blind build commit --commit HEAD --output "${TEST_ROOT}/blind-commit.md" >/dev/null
assert_not_contains "${TEST_ROOT}/blind-commit.md" 'CONTAMINATION-RATIONALE' 'commit packet excludes commit message'
assert_not_contains "${TEST_ROOT}/blind-commit.md" 'review@example.invalid' 'commit packet excludes author metadata'
assert_contains "${TEST_ROOT}/blind-commit.md" 'coverage: partial' 'missing requirements is partial coverage'
assert_contains "${TEST_ROOT}/blind-commit.md" 'acceptance is unverified' 'missing requirements unavailable'
(cd "$BLIND_REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle commit --commit HEAD) | grep -Fq 'CONTAMINATION-RATIONALE' || fail 'legacy commit bundle changed'
blind validate "${TEST_ROOT}/blind1.md" >/dev/null || fail 'valid packet rejected'
[[ "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind1.md")" == "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind2.md")" ]] || fail 'unchanged evidence changed identity'
if blind build pr 1 >/dev/null 2>&1; then fail 'blind packet accepted PR discussion target'; fi

# Requirement, verification and artifact changes each change identity.
BLIND_ID=$(grep '^acceptance_identity:' "${TEST_ROOT}/blind1.md")
printf 'R1: changed\n' >"${TEST_ROOT}/req2.txt"
blind build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req2.txt" --requirements-source 'issue#1' \
	--amendments "${TEST_ROOT}/amend.txt" --amendments-source 'maintainer approval' \
	--verification "${TEST_ROOT}/verify.txt" --context lib/contract.txt --output "${TEST_ROOT}/blind3.md" >/dev/null
[[ "$BLIND_ID" != "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind3.md")" ]] || fail 'requirement change kept identity'
printf 'head: %s\nraw: different output\n' "$BLIND_HEAD" >"${TEST_ROOT}/verify2.txt"
blind build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req.txt" --requirements-source 'issue#1' \
	--amendments "${TEST_ROOT}/amend.txt" --amendments-source 'maintainer approval' \
	--verification "${TEST_ROOT}/verify2.txt" --context lib/contract.txt --output "${TEST_ROOT}/blind4.md" >/dev/null
[[ "$BLIND_ID" != "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind4.md")" ]] || fail 'verification change kept identity'
printf 'stale\n' >"${TEST_ROOT}/verify-stale.txt"
blind build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req.txt" --requirements-source 'issue#1' \
	--verification "${TEST_ROOT}/verify-stale.txt" --output "${TEST_ROOT}/blind5.md" >/dev/null
assert_contains "${TEST_ROOT}/blind5.md" 'excluded: evidence is not bound' 'unbound verification excluded'
assert_contains "${TEST_ROOT}/blind5.md" 'coverage: partial' 'unbound verification is partial coverage'
printf 'changed\n' >"${BLIND_REPO}/lib/contract.txt"
blind build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req.txt" --requirements-source 'issue#1' \
	--amendments "${TEST_ROOT}/amend.txt" --amendments-source 'maintainer approval' \
	--verification "${TEST_ROOT}/verify.txt" --context lib/contract.txt --output "${TEST_ROOT}/blind6.md" >/dev/null
[[ "$BLIND_ID" == "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind6.md")" ]] || fail 'unselected worktree edit changed branch identity'
printf 'base\nfeature\nmore\n' >"${BLIND_REPO}/lib/app.txt"
bgit add -A
bgit commit -qm next
printf 'head: %s\n' "$(bgit rev-parse HEAD)" >"${TEST_ROOT}/verify3.txt"
blind build branch --base "$BLIND_BASE" --requirements "${TEST_ROOT}/req.txt" --requirements-source 'issue#1' \
	--amendments "${TEST_ROOT}/amend.txt" --amendments-source 'maintainer approval' \
	--verification "${TEST_ROOT}/verify3.txt" --context lib/contract.txt --output "${TEST_ROOT}/blind7.md" >/dev/null
[[ "$BLIND_ID" != "$(grep '^acceptance_identity:' "${TEST_ROOT}/blind7.md")" ]] || fail 'artifact change kept identity'

# Tampering and malformed schemas are not accepted as fresh-review proof.
sed 's/feature line/other line/' "${TEST_ROOT}/blind1.md" >"${TEST_ROOT}/blind-tampered.md"
if blind validate "${TEST_ROOT}/blind-tampered.md" >/dev/null 2>&1; then fail 'tampered packet validated'; fi
sed 's#review-blind-packet/v1#review-blind-packet/v9#' "${TEST_ROOT}/blind1.md" >"${TEST_ROOT}/blind-schema.md"
if blind validate "${TEST_ROOT}/blind-schema.md" >/dev/null 2>&1; then fail 'unsupported schema validated'; fi
if blind build local --context ../escape >/dev/null 2>&1; then fail 'context path escape accepted'; fi
if blind build local --context config/.env >/dev/null 2>&1; then fail 'sensitive context accepted'; fi

# Acceptance results: one row per criterion; only all-satisfied on complete coverage passes.
printf '| ID | status | evidence | gap |\n|---|---|---|---|\n| R1 | satisfied | lib/app.txt | |\n| R2 | unmet | no changelog in artifact | add changelog |\n| A1 | satisfied | contract unchanged | |\n' >"${TEST_ROOT}/result-unmet.md"
RC=0
blind check-result "${TEST_ROOT}/blind1.md" "${TEST_ROOT}/result-unmet.md" >"${TEST_ROOT}/rc.out" || RC=$?
[[ "$RC" == 3 ]] || fail 'unmet criterion did not block delivery'
printf '| R1 | satisfied | lib/app.txt | |\n| A1 | satisfied | contract | |\n' >"${TEST_ROOT}/result-missing.md"
if blind check-result "${TEST_ROOT}/blind1.md" "${TEST_ROOT}/result-missing.md" >/dev/null 2>&1; then fail 'missing criterion row accepted'; fi
printf '| R1 | satisfied | | |\n| R2 | satisfied | x | |\n| A1 | satisfied | x | |\n' >"${TEST_ROOT}/result-noevidence.md"
if blind check-result "${TEST_ROOT}/blind1.md" "${TEST_ROOT}/result-noevidence.md" >/dev/null 2>&1; then fail 'evidence-free satisfied accepted'; fi
printf '| R1 | satisfied | a | |\n| R2 | satisfied | b | |\n| A1 | satisfied | c | |\n' >"${TEST_ROOT}/result-ok.md"
blind check-result "${TEST_ROOT}/blind1.md" "${TEST_ROOT}/result-ok.md" >"${TEST_ROOT}/rc.out" || fail 'complete satisfied result rejected'
assert_contains "${TEST_ROOT}/rc.out" 'acceptance: satisfied (3 of 3 criteria)' 'satisfied verdict'
RC=0
blind check-result "${TEST_ROOT}/blind5.md" "${TEST_ROOT}/result-ok.md" >/dev/null 2>&1 || RC=$?
[[ "$RC" != 0 ]] || fail 'partial-coverage packet allowed delivered claim'

printf 'PASS review evidence helper builds bounded target bundles\n'
