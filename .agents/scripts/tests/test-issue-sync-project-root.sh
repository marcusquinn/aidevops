#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27146: pulse issue sync must bind every mutation
# and commit check to the repository root paired with the requested slug.

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

# Exercise the real pulse function with a fixture helper. The helper records
# the contract and mutates only the explicitly supplied root on pull.
fixture_scripts="${TMP}/scripts"
mkdir -p "$fixture_scripts"
cp "$SCRIPTS_DIR/pulse-wrapper-cycle.sh" "$fixture_scripts/pulse-wrapper-cycle.sh"
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

function_src=$(awk '/^sync_todo_refs_for_repo\(\) \{/,/^}$/ { print }' "$fixture_scripts/pulse-wrapper-cycle.sh")
[[ -n "$function_src" ]] || fail "could not extract pulse sync function"
eval "$function_src"
export CALL_LOG="${TMP}/calls.log"
export WRAPPER_LOGFILE="${TMP}/pulse.log"
export SCRIPT_DIR="$fixture_scripts"

# Commit mechanics are not under test here. Stub git after the real helper's
# remote validation so pulse cannot attempt to push fixture repositories.
git() {
	return 0
}

snapshot_b=$(shasum "$repo_b/TODO.md")
sync_todo_refs_for_repo owner/repo-a "$repo_a"
[[ $(shasum "$repo_b/TODO.md") == "$snapshot_b" ]] || fail "repo A invocation changed repo B"
grep -q '^synced:owner/repo-a$' "$repo_a/TODO.md" || fail "repo A was not synced"

snapshot_a=$(shasum "$repo_a/TODO.md")
sync_todo_refs_for_repo owner/repo-b "$repo_b"
[[ $(shasum "$repo_a/TODO.md") == "$snapshot_a" ]] || fail "repo B invocation changed repo A"
grep -q '^synced:owner/repo-b$' "$repo_b/TODO.md" || fail "repo B was not synced"

[[ $(wc -l <"$CALL_LOG" | tr -d ' ') -eq 6 ]] || fail "pulse did not make three bound calls per repository"
grep -q "pull|owner/repo-a|${repo_a}" "$CALL_LOG" || fail "repo A root was not passed explicitly"
grep -q "pull|owner/repo-b|${repo_b}" "$CALL_LOG" || fail "repo B root was not passed explicitly"
grep -q 'repo=owner/repo-a root=validated' "$WRAPPER_LOGFILE" || fail "resolved slug/root status was not logged"
if grep -q "$TMP" "$WRAPPER_LOGFILE"; then
	fail "pulse log disclosed a private project path"
fi

printf 'PASS: issue sync project-root contract\n'
