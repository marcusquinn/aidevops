#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mirror-sync-helper.sh"
TEST_TEMP="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TEMP"
ROOT=$(mktemp -d "${TEST_TEMP}/mirror-test.XXXXXXXX")
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home" AIDEVOPS_TEMP_DIR="$ROOT/tmp"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR" "$ROOT/work"
ORIGIN="$ROOT/origin.git"
UPSTREAM="$ROOT/upstream.git"
CANONICAL="$ROOT/canonical"
git init -q --bare "$ORIGIN"
git init -q --bare "$UPSTREAM"
git -C "$ROOT/work" init -q -b main
git -C "$ROOT/work" config user.name Test
git -C "$ROOT/work" config user.email test@localhost
printf 'base\n' >"$ROOT/work/common"
git -C "$ROOT/work" add common
git -C "$ROOT/work" commit -qm base
git -C "$ROOT/work" remote add origin "$ORIGIN"
git -C "$ROOT/work" remote add upstream "$UPSTREAM"
git -C "$ROOT/work" push -q origin main
git -C "$ROOT/work" push -q upstream main
git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$CANONICAL"
CANONICAL_BEFORE=$(git -C "$CANONICAL" status --porcelain=v1)
CANONICAL_HEAD=$(git -C "$CANONICAL" rev-parse HEAD)
CONFIG="$ROOT/repos.json"
STATE="$ROOT/state.json"
export AIDEVOPS_REPOS_FILE="$CONFIG" AIDEVOPS_MIRROR_STATE_FILE="$STATE"
# Git's documented per-process URL rewrite keeps the production origin URL
# derived strictly from the registered slug; no test-only write override exists.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.${ORIGIN}.insteadOf"
export GIT_CONFIG_VALUE_0='https://github.com/private/mirror.git'
jq -n --arg url "$UPSTREAM" '{initialized_repos:[{slug:"private/mirror",mirror_upstream:"vendor/source",mirror_upstream_url:$url},{slug:"private/marker",mirror_upstream:true}]}' >"$CONFIG"

assert_state() {
	local expected="$1" actual
	actual=$(jq -r '.["private/mirror"].state' "$STATE")
	[[ "$actual" == "$expected" ]] || { printf 'expected %s, got %s\n' "$expected" "$actual" >&2; exit 1; }
	return 0
}
assert_untouched() {
	[[ "$(git -C "$CANONICAL" rev-parse HEAD)" == "$CANONICAL_HEAD" ]]
	[[ "$(git -C "$CANONICAL" status --porcelain=v1)" == "$CANONICAL_BEFORE" ]]
	return 0
}

bash "$SCRIPT" check >"$ROOT/check"
grep -q 'OK private/mirror up-to-date' "$ROOT/check"
grep -q 'INFO privacy-only mirror marker skipped' "$ROOT/check"
# A string upstream with an explicit opt-out must never be fetched or pushed.
jq '.initialized_repos += [{slug:"private/disabled",mirror_upstream:"vendor/source",mirror_sync:false}]' "$CONFIG" >"$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
bash "$SCRIPT" check >"$ROOT/check"
if grep -q 'private/disabled' "$ROOT/check"; then printf 'opted-out mirror was selected\n' >&2; exit 1; fi
bash "$SCRIPT" sync >"$ROOT/result"
assert_state OK

printf 'upstream\n' >"$ROOT/work/upstream.txt"
git -C "$ROOT/work" add upstream.txt
git -C "$ROOT/work" commit -qm upstream
git -C "$ROOT/work" push -q upstream main
bash "$SCRIPT" check >"$ROOT/check"
grep -q 'BEHIND private/mirror 1' "$ROOT/check"
bash "$SCRIPT" sync >"$ROOT/result"
assert_state OK
[[ "$(git --git-dir="$ORIGIN" rev-parse main)" == "$(git --git-dir="$UPSTREAM" rev-parse main)" ]]

git -C "$ROOT/work" fetch -q origin
printf 'local\n' >"$ROOT/work/local.txt"
git -C "$ROOT/work" add local.txt
git -C "$ROOT/work" commit -qm local
git -C "$ROOT/work" push -q origin main
git -C "$ROOT/work" reset -q --hard upstream/main
printf 'more upstream\n' >"$ROOT/work/more.txt"
git -C "$ROOT/work" add more.txt
git -C "$ROOT/work" commit -qm more
git -C "$ROOT/work" push -q upstream main
bash "$SCRIPT" check >"$ROOT/check"
grep -q 'DIVERGED private/mirror' "$ROOT/check"
bash "$SCRIPT" sync >"$ROOT/result"
assert_state OK
git --git-dir="$ORIGIN" show-ref --verify "refs/heads/sync/upstream-$(date +%Y%m%d)" >/dev/null
git --git-dir="$ORIGIN" merge-base --is-ancestor "$(git --git-dir="$UPSTREAM" rev-parse main)" "$(git --git-dir="$ORIGIN" rev-parse main)"

# A second divergence conflicts, and must not change either origin ref.
git -C "$ROOT/work" fetch -q origin
git -C "$ROOT/work" reset -q --hard origin/main
printf 'mirror\n' >"$ROOT/work/common"
git -C "$ROOT/work" add common
git -C "$ROOT/work" commit -qm mirror-conflict
git -C "$ROOT/work" push -q origin main
git -C "$ROOT/work" reset -q --hard upstream/main
printf 'vendor\n' >"$ROOT/work/common"
git -C "$ROOT/work" add common
git -C "$ROOT/work" commit -qm upstream-conflict
git -C "$ROOT/work" push -q upstream main
BEFORE=$(git --git-dir="$ORIGIN" rev-parse main)
if bash "$SCRIPT" sync >"$ROOT/result"; then printf 'expected conflict\n' >&2; exit 1; fi
assert_state CONFLICT
[[ "$(git --git-dir="$ORIGIN" rev-parse main)" == "$BEFORE" ]]

# Bad upstream URL cannot trigger a terminal prompt or alter origin.
jq '.initialized_repos[0].mirror_upstream_url = "/nonexistent/mirror-upstream.git"' "$CONFIG" >"$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
if bash "$SCRIPT" sync >"$ROOT/result"; then printf 'expected auth/fetch failure\n' >&2; exit 1; fi
assert_state FAIL
[[ "$(git --git-dir="$ORIGIN" rev-parse main)" == "$BEFORE" ]]
assert_untouched

# Exercise setup's selection and legacy-label collision decisions without
# installing a real user scheduler or modifying the operator's HOME.
mkdir -p "$HOME/.config/aidevops" "$HOME/.aidevops/agents/scripts" "$HOME/Library/LaunchAgents"
cp "$SCRIPT" "$HOME/.aidevops/agents/scripts/mirror-sync-helper.sh"
# shellcheck source=../setup/modules/schedulers-platform.sh
source "$(dirname "$SCRIPT")/setup/modules/schedulers-platform.sh"
INSTALLS=0
_install_scheduler_linux() { INSTALLS=$((INSTALLS + 1)); return 0; }
_launchd_install_if_changed() { INSTALLS=$((INSTALLS + 1)); return 0; }
_resolve_modern_bash() { command -v bash; return 0; }
_xml_escape() { printf '%s' "$1"; return 0; }
print_warning() { printf 'warning: %s\n' "$1" >&2; return 0; }
uname() { printf 'Linux\n'; return 0; }
jq '.initialized_repos = [{slug:"private/marker",mirror_upstream:true}]' "$CONFIG" >"$HOME/.config/aidevops/repos.json"
setup_mirror_sync
[[ "$INSTALLS" -eq 0 ]]
jq '.initialized_repos = [{slug:"private/mirror",mirror_upstream:"vendor/source"}]' "$CONFIG" >"$HOME/.config/aidevops/repos.json"
setup_mirror_sync
[[ "$INSTALLS" -eq 1 ]]
uname() { printf 'Darwin\n'; return 0; }
plutil() {
	local field="$2"
	case "$field" in
	ProgramArguments.0) printf '/bin/bash\n' ;;
	ProgramArguments.1) printf '%s\n' "$ROOT/legacy-missing.sh" ;;
	esac
	return 0
}
printf 'legacy\n' >"$HOME/Library/LaunchAgents/sh.aidevops.mirror-sync.plist"
setup_mirror_sync
[[ "$INSTALLS" -eq 2 ]]
touch "$ROOT/legacy-missing.sh"
setup_mirror_sync
[[ "$INSTALLS" -eq 2 ]]
printf 'mirror sync tests passed\n'
