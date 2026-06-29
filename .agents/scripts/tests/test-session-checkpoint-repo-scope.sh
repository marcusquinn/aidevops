#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/session-checkpoint-helper.sh"

fail() {
	local message="$1"
	printf '%s\n' "$message" >&2
	exit 1
}

assert_contains() {
	local label="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		fail "${label}: expected to find ${needle}"
	fi
	return 0
}

assert_not_contains() {
	local label="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		fail "${label}: unexpected ${needle}"
	fi
	return 0
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

export HOME="${tmp_root}/home"
mkdir -p "$HOME"

tmp_bin="${tmp_root}/bin"
mkdir -p "$tmp_bin"
cat >"${tmp_bin}/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "${tmp_bin}/gh"
export PATH="${tmp_bin}:${PATH}"

repo_one="${tmp_root}/repo-one"
repo_two="${tmp_root}/repo-two"
repo_three="${tmp_root}/repo-three"
mkdir -p "$repo_one" "$repo_two" "$repo_three"
git -C "$repo_one" init -q
git -C "$repo_two" init -q
git -C "$repo_three" init -q

save_one_output="$(cd "$repo_one" && "$HELPER" save --task t1 --note "TARGET_REPO_SCOPED_NOTE" 2>&1)"
assert_contains "repo one save path" "$save_one_output" "session-checkpoints/repo-"

load_one_output="$(cd "$repo_one" && "$HELPER" load 2>&1)"
assert_contains "repo one load" "$load_one_output" "TARGET_REPO_SCOPED_NOTE"

set +e
load_two_output="$(cd "$repo_two" && "$HELPER" load 2>&1)"
load_two_rc=$?
set -e
if [[ "$load_two_rc" -eq 0 ]]; then
	fail "repo two unexpectedly loaded repo one checkpoint"
fi
assert_not_contains "repo two load" "$load_two_output" "TARGET_REPO_SCOPED_NOTE"

(cd "$repo_two" && "$HELPER" save --task t2 --note "SIBLING_REPO_SCOPED_NOTE" >/dev/null)
load_one_again="$(cd "$repo_one" && "$HELPER" load 2>&1)"
assert_contains "repo one reload" "$load_one_again" "TARGET_REPO_SCOPED_NOTE"
assert_not_contains "repo one reload" "$load_one_again" "SIBLING_REPO_SCOPED_NOTE"

continuation_one="$(cd "$repo_one" && "$HELPER" continuation 2>&1)"
assert_contains "repo one continuation" "$continuation_one" "TARGET_REPO_SCOPED_NOTE"
assert_contains "repo one continuation memory label" "$continuation_one" "Repo-scoped memories"
assert_not_contains "repo one continuation" "$continuation_one" "SIBLING_REPO_SCOPED_NOTE"

mkdir -p "$HOME/.aidevops/.agent-workspace/tmp"
printf '%s\n' "LEGACY_UNRELATED_CHECKPOINT_STATE" >"$HOME/.aidevops/.agent-workspace/tmp/session-checkpoint.md"

set +e
load_three_output="$(cd "$repo_three" && "$HELPER" load 2>&1)"
load_three_rc=$?
set -e
if [[ "$load_three_rc" -eq 0 ]]; then
	fail "repo three unexpectedly loaded legacy global checkpoint"
fi
assert_contains "repo three legacy warning" "$load_three_output" "Legacy global checkpoint ignored"
assert_not_contains "repo three load" "$load_three_output" "LEGACY_UNRELATED_CHECKPOINT_STATE"

continuation_three="$(cd "$repo_three" && "$HELPER" continuation 2>&1)"
assert_not_contains "repo three continuation" "$continuation_three" "LEGACY_UNRELATED_CHECKPOINT_STATE"
assert_not_contains "repo three continuation" "$continuation_three" "TARGET_REPO_SCOPED_NOTE"
assert_not_contains "repo three continuation" "$continuation_three" "SIBLING_REPO_SCOPED_NOTE"

printf 'session-checkpoint repo scope test passed\n'
