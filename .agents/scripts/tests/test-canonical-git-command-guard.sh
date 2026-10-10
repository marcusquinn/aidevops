#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
GUARD="${SCRIPT_DIR}/canonical-git-command-guard.py"
SHIM="${SCRIPT_DIR}/git"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT" "$NON_TEMP_ROOT"' EXIT
REPO="${TEST_ROOT}/repo"
LINKED="${TEST_ROOT}/linked"
PASSWORD_REPO="${TEST_ROOT}/password-store"
MARKED_REPO="${TEST_ROOT}/marked-repo"
NON_TEMP_ROOT=$(mktemp -d "${HOME}/canonical-git-guard.XXXXXX")
NON_TEMP_MARKED_REPO="${NON_TEMP_ROOT}/marked-repo"
SEPARATE_REPO="${TEST_ROOT}/separate-repo"
SEPARATE_GIT_DIR="${TEST_ROOT}/separate-repo-git"
SNAPSHOT_REPO="${TEST_ROOT}/snapshot.git"
TESTS=0
FAILURES=0

# Native Git and a minimal system PATH from the caller's PATH, so the fixture
# also runs where git/bash/python3 are not in /usr/bin (no FHS layout).
# The resolver skips aidevops Git shims that may lead the caller's PATH.
# shellcheck disable=SC2016 # Expanded by the child shell.
NATIVE_GIT=$(bash -c 'source "$1/runtime-env.sh" && aidevops_resolve_native_git' _ "$SCRIPT_DIR") || exit 1
TEST_SYS_PATH=""
for _tool in env bash git python3; do
	_tool_path=$(type -P "$_tool") || exit 1
	[[ "$_tool" == git ]] && _tool_path="$NATIVE_GIT"
	_tool_dir="${_tool_path%/*}"
	case ":${TEST_SYS_PATH}:" in
	*":${_tool_dir}:"*) ;;
	*) TEST_SYS_PATH="${TEST_SYS_PATH:+${TEST_SYS_PATH}:}${_tool_dir}" ;;
	esac
done
TEST_SYS_PATH="${TEST_SYS_PATH}:/usr/bin:/bin"
unset _tool _tool_path _tool_dir

# Fixture setup must bypass the guard under test; policy assertions invoke the
# shim explicitly below.
git() {
	"$NATIVE_GIT" "$@"
	return $?
}

pass() {
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s\n' "$1"
	return 0
}

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m seed
INITIAL_HEAD=$(git -C "$REPO" rev-parse HEAD)
REPOS_FILE="${TEST_ROOT}/repos.json"
printf '{"initialized_repos":[{"path":"%s"},{"path":"%s"},{"path":"%s"}]}\n' \
	"$REPO" "$SEPARATE_REPO" "$MARKED_REPO" >"$REPOS_FILE"
export AIDEVOPS_REPOS_FILE="$REPOS_FILE"

mkdir -p "$PASSWORD_REPO"
git -C "$PASSWORD_REPO" init -q -b main
printf 'encrypted fixture\n' >"${PASSWORD_REPO}/test-secret.gpg"

mkdir -p "$MARKED_REPO"
git -C "$MARKED_REPO" init -q -b main
printf '{}\n' >"${MARKED_REPO}/.aidevops.json"
printf 'managed fixture\n' >"${MARKED_REPO}/managed.txt"
mkdir -p "$NON_TEMP_MARKED_REPO"
git -C "$NON_TEMP_MARKED_REPO" init -q -b main
printf '{}\n' >"${NON_TEMP_MARKED_REPO}/.aidevops.json"
printf 'managed fixture\n' >"${NON_TEMP_MARKED_REPO}/managed.txt"
UNREGISTERED_REPO="${TEST_ROOT}/unregistered-repo"
mkdir -p "$UNREGISTERED_REPO"
git -C "$UNREGISTERED_REPO" init -q -b main
printf '{}\n' >"${UNREGISTERED_REPO}/.aidevops.json"
printf 'disposable fixture\n' >"${UNREGISTERED_REPO}/disposable.txt"

mkdir -p "$SEPARATE_REPO"
git init -q -b main --separate-git-dir "$SEPARATE_GIT_DIR" "$SEPARATE_REPO"
printf '{}\n' >"${SEPARATE_REPO}/.aidevops.json"

assert_blocked() {
	local name="$1"
	local command="$2"
	local output=""
	output=$(python3 "$GUARD" --cwd "$REPO" --command "$command" 2>&1)
	local rc=$?
	if [[ "$rc" -eq 42 && "$output" == *"BLOCKED by canonical Git guard"* ]]; then
		pass "$name"
	else
		fail "$name (rc=$rc output=$output)"
	fi
	return 0
}

assert_allowed() {
	local name="$1"
	local cwd="$2"
	local command="$3"
	if python3 "$GUARD" --cwd "$cwd" --command "$command" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

assert_allowed_with_temp_root() {
	local name="$1"
	local cwd="$2"
	local command="$3"
	if TMPDIR="$TEST_ROOT" python3 "$GUARD" --cwd "$cwd" --command "$command" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

# GH#34179: version flags have no subcommand, but are exact read-only queries.
assert_allowed "allows canonical version flag" "$REPO" "git --version"
assert_allowed "allows canonical short version flag" "$REPO" "git -v"
assert_allowed "allows version flag with canonical -C target" "$REPO" "git -C '$REPO' --version"
assert_blocked "blocks unknown flag-only invocation" "git --unknown"
assert_blocked "blocks unknown flag before version" "git --unknown --version"
assert_blocked "blocks unknown flag after version" "git --version --unknown"
assert_blocked "blocks malformed -C version invocation" "git -C --version"
assert_blocked "blocks version followed by canonical mutation" "git --version branch -M renamed"
assert_blocked "blocks version after canonical mutation" "git branch -M renamed --version"
assert_blocked "blocks option terminator before version" "git -- --version"
# shellcheck disable=SC2016
assert_blocked "blocks unresolved version -C target" 'git -C "$REPO" --version'
assert_blocked "blocks chained mutation after version" "git --version && git branch -M renamed"
assert_blocked "blocks canonical detached switch" "git switch --detach main"
GUIDANCE_OUTPUT=$(python3 "$GUARD" --cwd "$REPO" --command "git pull --ff-only origin main" 2>&1)
RECOVERY_HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
QUOTED_RECOVERY_HELPER=$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$RECOVERY_HELPER")
if [[ "$GUIDANCE_OUTPUT" == *"${QUOTED_RECOVERY_HELPER} fast-forward-current"* && -x "$RECOVERY_HELPER" ]]; then
	pass "blocked canonical pull points to an executable audited fast-forward workflow"
else
	fail "blocked canonical pull omits executable audited fast-forward guidance"
fi
assert_blocked "blocks canonical branch rename" "git branch -m main safety/example"
assert_blocked "blocks canonical branch creation with reflog flag" "git branch -l feature/new"
assert_blocked "blocks canonical non-default switch" "git switch safety/example"
assert_blocked "blocks git -C canonical reset" "git -C '$REPO' reset --hard HEAD"
assert_blocked "blocks relative git -C canonical reset" "cd '$TEST_ROOT' && git -C repo reset --hard HEAD"
# shellcheck disable=SC2016
assert_blocked "blocks variable-derived git -C target" '/usr/bin/git -C "$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks command-substitution git -C target" '/usr/bin/git -C "$(pwd)" branch -M renamed'
# shellcheck disable=SC2016
assert_blocked "blocks attached variable git-dir target" '/usr/bin/git --git-dir="$REPO/.git" --work-tree="$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks environment variable Git target" 'env GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks literal environment Git target" "env GIT_DIR='$REPO/.git' GIT_WORK_TREE='$REPO' /usr/bin/git switch --detach main"
# shellcheck disable=SC2016
assert_blocked "blocks quoted environment assignment name" 'env '\''GIT_DIR='\''"$REPO/.git" '\''GIT_WORK_TREE='\''"$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks tilde git -C target" '/usr/bin/git -C ~/repo switch --detach main'
assert_blocked "blocks wrapped canonical switch" "env TEST=1 command git switch feature/example"
assert_blocked "blocks nested absolute Git bypass" "bash -c '/usr/bin/git switch --detach main'"
assert_blocked "blocks chained canonical mutation" "git status && git branch -M renamed"
assert_blocked "blocks canonical update-ref plumbing" "/usr/bin/git update-ref refs/heads/main HEAD"
assert_blocked "blocks canonical bundle creation" "git bundle create '$TEST_ROOT/commits.bundle' HEAD"
assert_blocked "blocks canonical bundle unbundle" "git bundle unbundle '$TEST_ROOT/commits.bundle'"
assert_blocked "blocks canonical hash-object writes" "git hash-object -w --stdin"
assert_blocked "blocks combined canonical hash-object write flags" "git hash-object -wt blob --stdin"
assert_blocked "blocks merge-tree writes in a canonical checkout" \
	"git merge-tree --write-tree '$INITIAL_HEAD' '$INITIAL_HEAD'"
assert_blocked "blocks destructive clean with exclude containing n" "git clean --force --exclude=nope"
assert_blocked "blocks interactive clean" "git clean --interactive"
assert_blocked "blocks canonical symbolic-ref update" "git symbolic-ref HEAD refs/heads/safety/example"
assert_blocked "blocks canonical symbolic-ref update with reflog reason" "git symbolic-ref -m reason HEAD refs/heads/safety/example"
assert_blocked "blocks canonical symbolic-ref deletion" "git symbolic-ref --delete refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref short deletion" "git symbolic-ref -d refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref combined deletion flags" "git symbolic-ref -qd refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref unknown options" "git symbolic-ref --bogus refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref without a ref" "git symbolic-ref --short"
assert_blocked "blocks canonical symbolic-ref option terminator" "git symbolic-ref -- refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref second ref after option terminator" "git symbolic-ref -- HEAD refs/heads/safety/example"
assert_allowed "allows gh auth global credential helper config from canonical cwd" "$REPO" \
	"git config --global credential.https://github.com.helper '!gh auth git-credential'"
assert_allowed "allows gh auth global replace-all credential helper config" "$REPO" \
	"git config --global --replace-all credential.helper '!gh auth git-credential'"
assert_blocked "blocks canonical local credential helper config" \
	"git config credential.helper '!gh auth git-credential'"
assert_blocked "blocks canonical global non-credential config write" \
	"git config --global include.path '$TEST_ROOT/unsafe.gitconfig'"
# GH#33066: single-key reads without --get are reads, not canonical mutations.
assert_allowed "allows bare global config key read" "$REPO" "git config --global gpg.format"
assert_allowed "allows bare system config key read" "$REPO" "git config --system core.editor"
assert_allowed "allows bare local config key read" "$REPO" "git config user.signingkey"
assert_allowed "allows file-scoped config key read" "$REPO" "git config --file '$TEST_ROOT/x.gitconfig' user.name"
assert_allowed "allows typed config key read" "$REPO" "git config --type bool commit.gpgsign"
assert_allowed "allows get subcommand read" "$REPO" "git config get user.name"
assert_allowed "allows get subcommand with get options" "$REPO" "git config get --all --show-names user.name"
assert_allowed "allows list subcommand" "$REPO" "git config list --global"
assert_blocked "blocks bare global config write" "git config --global gpg.format ssh"
assert_blocked "blocks typed config write" "git config --type bool commit.gpgsign true"
assert_blocked "blocks file-scoped config write" "git config -f '$TEST_ROOT/x.gitconfig' user.name value"
assert_blocked "blocks config unset" "git config --unset user.name"
assert_blocked "blocks config edit" "git config -e"
assert_blocked "blocks config long edit" "git config --global --edit"
assert_blocked "blocks set subcommand" "git config set user.name value"
assert_blocked "blocks unset subcommand" "git config unset user.name"
assert_blocked "blocks sectionless single positional" "git config edit"
assert_blocked "blocks value option missing its value" "git config user.name --type"
assert_blocked "blocks unknown config option" "git config --bogus user.name"
assert_blocked "blocks get-only option on legacy read" "git config --all user.name"
assert_blocked "blocks list with extra positional" "git config list user.name"
assert_blocked "blocks mutation in a repository with an aidevops project marker" \
	"git -C '$MARKED_REPO' add managed.txt"
assert_allowed "allows git add in an unregistered temp repo with a project marker" "$REPO" \
	"git -C '$UNREGISTERED_REPO' add disposable.txt"
if (cd "$UNREGISTERED_REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" add disposable.txt) &&
	! git -C "$UNREGISTERED_REPO" diff --cached --quiet -- disposable.txt; then
	pass "PATH shim stages files in an unregistered temp marker repo"
else
	fail "PATH shim stages files in an unregistered temp marker repo"
fi
assert_blocked "blocks marker repository outside temp roots" \
	"git -C '$NON_TEMP_MARKED_REPO' add managed.txt"
assert_blocked "blocks git-dir-only mutation targeting a managed canonical repository" \
	"git -C '$PASSWORD_REPO' --git-dir='$REPO/.git' update-ref refs/heads/blocked '$INITIAL_HEAD'"
assert_blocked "blocks git-dir-only mutation targeting a registered separate Git directory" \
	"git -C '$PASSWORD_REPO' --git-dir='$SEPARATE_GIT_DIR' update-ref refs/heads/blocked '$INITIAL_HEAD'"
assert_blocked "blocks an unrelated Git directory from mutating a managed worktree" \
	"git --git-dir='$PASSWORD_REPO/.git' --work-tree='$MARKED_REPO' reset --hard"
assert_blocked "blocks an unrelated Git directory from mutating a marker-managed separate-git-dir worktree" \
	"git --git-dir='$PASSWORD_REPO/.git' --work-tree='$SEPARATE_REPO' reset --hard"
assert_allowed "allows gopass-style Git mutation in an unrelated password store" "$REPO" \
	"git -C '$PASSWORD_REPO' add test-secret.gpg"
if (cd "$REPO" && env PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" -C "$PASSWORD_REPO" add test-secret.gpg); then
	if git -C "$PASSWORD_REPO" diff --cached --quiet -- test-secret.gpg; then
		fail "PATH shim permits unrelated password-store mutation"
	else
		pass "PATH shim permits unrelated password-store mutation"
	fi
else
	fail "PATH shim permits unrelated password-store mutation"
fi
printf '{"initialized_repos":null}\n' >"$REPOS_FILE"
assert_allowed "malformed managed-repository registry does not intercept unrelated Git" "$REPO" \
	"git -C '$PASSWORD_REPO' add test-secret.gpg"
printf '{"initialized_repos":[{"path":"~aidevops-user-that-does-not-exist/repo"}]}\n' >"$REPOS_FILE"
assert_allowed "invalid managed-repository path does not intercept unrelated Git" "$REPO" \
	"git -C '$PASSWORD_REPO' add test-secret.gpg"
printf '{"initialized_repos":[{"path":"%s"},{"path":"%s"},{"path":"%s"}]}\n' \
	"$REPO" "$SEPARATE_REPO" "$MARKED_REPO" >"$REPOS_FILE"

if [[ "$(git -C "$REPO" symbolic-ref --short HEAD)" == "main" ]] &&
	[[ "$(git -C "$REPO" rev-parse HEAD)" == "$INITIAL_HEAD" ]] &&
	! git -C "$REPO" show-ref --verify --quiet refs/heads/safety/example; then
	pass "blocked sequence leaves canonical refs unchanged"
else
	fail "blocked sequence leaves canonical refs unchanged"
fi

assert_allowed "allows canonical status" "$REPO" "git status --short"
assert_allowed "allows canonical diff-files query" "$REPO" "git diff-files --name-only"
assert_allowed "allows canonical diff-tree query" "$REPO" \
	"git diff-tree --root --no-commit-id --name-only -r '$INITIAL_HEAD'"
assert_allowed "allows canonical branch listing" "$REPO" "git branch -vv --no-abbrev"
assert_allowed "allows canonical branch pattern listing" "$REPO" "git branch --list 'feature/*'"
assert_allowed "allows canonical branch containment query" "$REPO" "git branch --contains main"
assert_allowed "allows canonical ref format validation" "$REPO" "git check-ref-format --branch feature/valid-ref"
assert_allowed "allows canonical no-index ignore query" "$REPO" "git check-ignore --no-index -v -- node_modules/x"
assert_allowed "allows canonical quiet ignore query" "$REPO" "git check-ignore --quiet -- README.md"
assert_allowed "allows canonical attribute query" "$REPO" "git check-attr -a -- README.md"
assert_allowed "allows canonical mailmap query" "$REPO" "git check-mailmap 'Test <test@example.invalid>'"
assert_allowed "allows canonical ls-remote query" "$REPO" "git ls-remote origin refs/heads/main"
assert_allowed "allows canonical rev-list tag query" "$REPO" "git rev-list -n 1 HEAD"
assert_allowed "allows canonical rev-list count query" "$REPO" "git rev-list --count HEAD"
assert_allowed "allows canonical rev-list root query" "$REPO" "git rev-list --max-parents=0 HEAD"
assert_allowed "allows canonical symbolic-ref query" "$REPO" "git symbolic-ref refs/remotes/origin/HEAD"
assert_allowed "allows canonical short symbolic-ref query" "$REPO" "git symbolic-ref --short refs/remotes/origin/HEAD"
assert_allowed "allows reordered canonical symbolic-ref query flags" "$REPO" "git symbolic-ref refs/remotes/origin/HEAD --quiet --short"
assert_allowed "allows canonical non-recursive symbolic-ref query" "$REPO" "git symbolic-ref --no-recurse refs/remotes/origin/HEAD"
assert_allowed "allows canonical bundle verification" "$REPO" "git bundle verify '$TEST_ROOT/commits.bundle'"
assert_allowed "allows quiet canonical bundle verification" "$REPO" "git bundle verify --quiet '$TEST_ROOT/commits.bundle'"
assert_allowed "allows canonical stdin hashing" "$REPO" "git hash-object --stdin"
assert_allowed "allows canonical stdin path hashing" "$REPO" "git hash-object --stdin-paths"
assert_allowed "allows canonical path hashing" "$REPO" "git hash-object README.md"
assert_allowed "allows canonical option-like path hashing after terminator" "$REPO" "git hash-object -- -w"
assert_allowed "allows canonical worktree creation" "$REPO" "git worktree add '$LINKED' -b feature/example"

PROSPECTIVE_CONTEXT=$(mktemp -d "${TEST_ROOT}/aidevops-prospective-todo.XXXXXX")
PROSPECTIVE_REPO="${PROSPECTIVE_CONTEXT}/repository.git"
git -C "$PROSPECTIVE_CONTEXT" init --bare -q repository.git
assert_allowed_with_temp_root "allows the pinned merge-tree probe in its isolated bare temp repo" \
	"$PROSPECTIVE_REPO" "git merge-tree --write-tree '$INITIAL_HEAD' '$INITIAL_HEAD'"
assert_allowed "allows unrelated writes in an unmanaged isolated bare temp repo" \
	"$REPO" "git -C '$PROSPECTIVE_REPO' update-ref refs/heads/main '$INITIAL_HEAD'"

git -C "$REPO" worktree add -q -b feature/example "$LINKED"
assert_allowed "allows linked-worktree version flag" "$LINKED" "git --version"
assert_allowed "allows version flag with linked -C target" "$REPO" "git -C '$LINKED' --version"
assert_allowed "allows version flag with repeated -C targets" "$REPO" "git -C '$TEST_ROOT' -C linked --version"
NATIVE_VERSION=$(git --version)
for VERSION_CWD in "$REPO" "$LINKED"; do
	VERSION_RC=0
	VERSION_OUTPUT=$(cd "$VERSION_CWD" && env PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" --version 2>&1) || VERSION_RC=$?
	TARGET_VERSION_RC=0
	TARGET_VERSION_OUTPUT=$(cd "$VERSION_CWD" && env PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" -C "$LINKED" --version 2>&1) || TARGET_VERSION_RC=$?
	if [[ "$VERSION_RC" -eq 0 && "$TARGET_VERSION_RC" -eq 0 && "$VERSION_OUTPUT" == "$NATIVE_VERSION" && "$TARGET_VERSION_OUTPUT" == "$NATIVE_VERSION" ]]; then
		pass "PATH shim preserves native version output and status from ${VERSION_CWD##*/}"
	else
		fail "PATH shim preserves native version output and status from ${VERSION_CWD##*/} (rc=$VERSION_RC target_rc=$TARGET_VERSION_RC)"
	fi
done
NATIVE_MISSING_RC=0
git -C "$TEST_ROOT/missing" --version >/dev/null 2>&1 || NATIVE_MISSING_RC=$?
SHIM_MISSING_RC=0
env PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" -C "$TEST_ROOT/missing" --version >/dev/null 2>&1 || SHIM_MISSING_RC=$?
if [[ "$NATIVE_MISSING_RC" -ne 0 && "$SHIM_MISSING_RC" -eq "$NATIVE_MISSING_RC" ]]; then
	pass "PATH shim preserves native invalid version target exit status"
else
	fail "PATH shim preserves native invalid version target exit status (native_rc=$NATIVE_MISSING_RC shim_rc=$SHIM_MISSING_RC)"
fi
git init --bare -q "$SNAPSHOT_REPO"
assert_allowed "allows an isolated snapshot repository to index a linked worktree" "$REPO" \
	"git --git-dir='$SNAPSHOT_REPO' --work-tree='$LINKED' add --all --sparse"
assert_allowed "allows canonical linked worktree removal" "$REPO" "git worktree remove --force '$LINKED'"
assert_allowed "allows canonical linked worktree removal with option terminator" "$REPO" "git worktree remove -f -- '$LINKED'"
assert_blocked "blocks canonical worktree removal of canonical root" "git worktree remove --force '$REPO'"
assert_blocked "blocks canonical worktree removal with unsupported options" "git worktree remove --force --expire now '$LINKED'"
assert_allowed "allows normal Git mutation in linked worktree" "$LINKED" "git switch -c feature/linked-child"
assert_allowed "allows rev-list query in linked worktree" "$LINKED" "git rev-list --count HEAD"
LINKED_GIT_DIR=$(git -C "$LINKED" rev-parse --path-format=absolute --git-dir)
assert_blocked "blocks linked-worktree metadata from mutating the canonical worktree" \
	"git --git-dir='$LINKED_GIT_DIR' --work-tree='$REPO' reset --hard"

git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
DEFAULT_BRANCH=$(
	unset -f git
	export PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-canonical-maintenance.sh"
	_get_default_branch_for_repo "$REPO"
)
if [[ "$DEFAULT_BRANCH" == "develop" ]]; then
	pass "deployed shim lets pulse resolve a non-main default branch"
else
	fail "deployed shim lets pulse resolve a non-main default branch (output=$DEFAULT_BRANCH)"
fi

if (cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/unsafe >/dev/null 2>&1) ||
	(cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1); then
	fail "PATH shim blocks symbolic-ref mutation before execution"
elif [[ "$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD)" == "origin/develop" ]]; then
	pass "PATH shim blocks symbolic-ref mutation before execution"
else
	fail "PATH shim left canonical symbolic ref changed"
fi

VALID_REF_RC=0
INVALID_REF_RC=0
NATIVE_INVALID_REF_RC=0
git check-ref-format --branch "invalid ref" >/dev/null 2>&1 || NATIVE_INVALID_REF_RC=$?
(cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" check-ref-format --branch feature/valid-ref >/dev/null) || VALID_REF_RC=$?
(cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" check-ref-format --branch "invalid ref" >/dev/null 2>&1) || INVALID_REF_RC=$?
if [[ "$VALID_REF_RC" -eq 0 && "$NATIVE_INVALID_REF_RC" -ne 0 && "$INVALID_REF_RC" -eq "$NATIVE_INVALID_REF_RC" ]]; then
	pass "PATH shim preserves native ref format validation"
else
	fail "PATH shim preserves native ref format validation (valid_rc=${VALID_REF_RC}, invalid_rc=${INVALID_REF_RC}, native_invalid_rc=${NATIVE_INVALID_REF_RC})"
fi

# GH#33858: child build tools probe ignore rules from canonical checkouts and
# must see native check-ignore results, not the guard's block code.
printf 'node_modules/\n' >>"${REPO}/.git/info/exclude"
IGNORED_RC=0
TRACKED_RC=0
IGNORED_OUTPUT=$(cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" check-ignore --no-index -v -- node_modules/x 2>&1) || IGNORED_RC=$?
(cd "$REPO" && PATH="${SCRIPT_DIR}:${TEST_SYS_PATH}" "$SHIM" check-ignore --quiet -- README.md >/dev/null 2>&1) || TRACKED_RC=$?
if [[ "$IGNORED_RC" -eq 0 && "$IGNORED_OUTPUT" == *"node_modules/"* && "$TRACKED_RC" -eq 1 ]]; then
	pass "PATH shim preserves native check-ignore results"
else
	fail "PATH shim preserves native check-ignore results (ignored_rc=${IGNORED_RC}, tracked_rc=${TRACKED_RC}, output=${IGNORED_OUTPUT})"
fi

if (cd "$REPO" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch --detach main >/dev/null 2>&1); then
	fail "PATH shim blocks canonical detached switch"
else
	[[ "$(git -C "$REPO" branch --show-current)" == "main" ]] && pass "PATH shim blocks canonical detached switch before execution" || fail "PATH shim changed canonical HEAD"
fi
if (cd "$LINKED" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch -q -c feature/linked-child); then
	pass "PATH shim allows linked-worktree branch mutation"
else
	fail "PATH shim allows linked-worktree branch mutation"
fi

SHIM_BIN="${TEST_ROOT}/bin"
mkdir -p "$SHIM_BIN"
ln -s "$SHIM" "${SHIM_BIN}/git"
if (cd "$REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git status --short >/dev/null); then
	pass "deployed symlink shim resolves policy engine"
else
	fail "deployed symlink shim resolves policy engine"
fi
HASH_INPUT="canonical hash-object read-only fixture $RANDOM"
printf '%s\n' "$HASH_INPUT" >"${REPO}/hash-input.txt"
EXPECTED_STDIN_HASH=$(printf '%s' "$HASH_INPUT" | "$NATIVE_GIT" hash-object --stdin)
EXPECTED_PATH_HASH=$("$NATIVE_GIT" -C "$REPO" hash-object hash-input.txt)
COUNT_OUTPUT=$("$NATIVE_GIT" -C "$REPO" count-objects)
OBJECT_COUNT_BEFORE=${COUNT_OUTPUT%% *}
SHIM_STDIN_HASH=$(printf '%s' "$HASH_INPUT" | (cd "$REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git hash-object --stdin))
SHIM_PATH_HASH=$(cd "$REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git hash-object hash-input.txt)
if [[ "$SHIM_STDIN_HASH" == "$EXPECTED_STDIN_HASH" && "$SHIM_PATH_HASH" == "$EXPECTED_PATH_HASH" ]]; then
	pass "deployed symlink shim allows read-only content and path hashing"
else
	fail "deployed symlink shim preserves native read-only hash-object output"
fi
WRITE_OUTPUT=$(printf '%s' "blocked hash-object write $RANDOM" | (cd "$REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git hash-object -w --stdin) 2>&1)
WRITE_RC=$?
COUNT_OUTPUT=$("$NATIVE_GIT" -C "$REPO" count-objects)
OBJECT_COUNT_AFTER=${COUNT_OUTPUT%% *}
if [[ "$WRITE_RC" -eq 42 && "$WRITE_OUTPUT" == *"BLOCKED by canonical Git guard"* && "$OBJECT_COUNT_AFTER" == "$OBJECT_COUNT_BEFORE" && "$(git -C "$REPO" rev-parse HEAD)" == "$INITIAL_HEAD" ]]; then
	pass "deployed symlink shim blocks hash-object writes without changing objects or refs"
else
	fail "deployed symlink shim blocks hash-object writes without changing objects or refs (rc=$WRITE_RC objects=${OBJECT_COUNT_BEFORE}->${OBJECT_COUNT_AFTER})"
fi
if (cd "$REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git switch --detach main >/dev/null 2>&1); then
	fail "deployed symlink shim blocks canonical mutation"
else
	[[ "$("$NATIVE_GIT" -C "$REPO" branch --show-current)" == "main" ]] && pass "deployed symlink shim blocks canonical mutation" || fail "symlink shim changed canonical HEAD"
fi

OLD_BUNDLE="${TEST_ROOT}/.aidevops/runtime-bundles/old/agents/scripts"
NEW_BUNDLE="${TEST_ROOT}/.aidevops/runtime-bundles/new/agents/scripts"
mkdir -p "$OLD_BUNDLE" "$NEW_BUNDLE"
cp "$SHIM" "${OLD_BUNDLE}/git"
cp "$SHIM" "${NEW_BUNDLE}/git"
ln -s "$GUARD" "${OLD_BUNDLE}/canonical-git-command-guard.py"
ln -s "$GUARD" "${NEW_BUNDLE}/canonical-git-command-guard.py"
ln -s "${SCRIPT_DIR}/canonical_git_policy.py" "${OLD_BUNDLE}/canonical_git_policy.py"
ln -s "${SCRIPT_DIR}/canonical_git_policy.py" "${NEW_BUNDLE}/canonical_git_policy.py"
ln -s "${SCRIPT_DIR}/canonical_git_invocation.py" "${OLD_BUNDLE}/canonical_git_invocation.py"
ln -s "${SCRIPT_DIR}/canonical_git_invocation.py" "${NEW_BUNDLE}/canonical_git_invocation.py"
ln -s "${SCRIPT_DIR}/canonical_git_readonly.py" "${OLD_BUNDLE}/canonical_git_readonly.py"
ln -s "${SCRIPT_DIR}/canonical_git_readonly.py" "${NEW_BUNDLE}/canonical_git_readonly.py"
ln -s "${SCRIPT_DIR}/canonical_git_ref_queries.py" "${OLD_BUNDLE}/canonical_git_ref_queries.py"
ln -s "${SCRIPT_DIR}/canonical_git_ref_queries.py" "${NEW_BUNDLE}/canonical_git_ref_queries.py"
ln -s "${SCRIPT_DIR}/canonical_git_config.py" "${OLD_BUNDLE}/canonical_git_config.py"
ln -s "${SCRIPT_DIR}/canonical_git_config.py" "${NEW_BUNDLE}/canonical_git_config.py"
ln -s "${SCRIPT_DIR}/canonical_git_management.py" "${OLD_BUNDLE}/canonical_git_management.py"
ln -s "${SCRIPT_DIR}/canonical_git_management.py" "${NEW_BUNDLE}/canonical_git_management.py"
ln -s "${SCRIPT_DIR}/canonical_git_repository.py" "${OLD_BUNDLE}/canonical_git_repository.py"
ln -s "${SCRIPT_DIR}/canonical_git_repository.py" "${NEW_BUNDLE}/canonical_git_repository.py"
ln -s "${SCRIPT_DIR}/canonical_shell_parser.py" "${OLD_BUNDLE}/canonical_shell_parser.py"
ln -s "${SCRIPT_DIR}/canonical_shell_parser.py" "${NEW_BUNDLE}/canonical_shell_parser.py"
if (cd "$REPO" && env PATH="${OLD_BUNDLE}:${NEW_BUNDLE}:${TEST_SYS_PATH}" "${OLD_BUNDLE}/git" status --short >/dev/null); then
	pass "runtime-bundle shim skips every aidevops shim generation"
else
	fail "runtime-bundle shim skips every aidevops shim generation"
fi

REENTRY_OUTPUT=$(env AIDEVOPS_CANONICAL_GIT_GUARD_ACTIVE=1 "$SHIM" status 2>&1)
REENTRY_RC=$?
if [[ "$REENTRY_RC" -eq 126 && "$REENTRY_OUTPUT" == *"recursive aidevops Git shim invocation"* ]]; then
	pass "recursive shim re-entry fails immediately with bounded diagnostic"
else
	fail "recursive shim re-entry is blocked (rc=$REENTRY_RC output=$REENTRY_OUTPUT)"
fi

SLOW_GIT="${TEST_ROOT}/slow-git"
printf '#!/usr/bin/env bash\nsleep 6\n' >"$SLOW_GIT"
chmod +x "$SLOW_GIT"
TIMEOUT_OUTPUT=$(python3 "$GUARD" --cwd "$REPO" --argv-json '["status"]' --real-git "$SLOW_GIT" 2>&1)
TIMEOUT_RC=$?
if [[ "$TIMEOUT_RC" -eq 42 && "$TIMEOUT_OUTPUT" == *"native Git repository probe timed out"* && "$TIMEOUT_OUTPUT" != *"Traceback"* ]]; then
	pass "native Git probe timeout fails closed without traceback"
else
	fail "native Git probe timeout is bounded (rc=$TIMEOUT_RC output=$TIMEOUT_OUTPUT)"
fi

LITERAL_REPO="${TEST_ROOT}/repo[1]"
mkdir -p "$LITERAL_REPO"
"$NATIVE_GIT" -C "$LITERAL_REPO" init -q -b main
if (cd "$LITERAL_REPO" && env PATH="${SHIM_BIN}:${TEST_SYS_PATH}" git status --short >/dev/null); then
	pass "shim accepts already-expanded literal metacharacter path"
else
	fail "shim accepts already-expanded literal metacharacter path"
fi

printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
