#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

# Keep disposable fixture repositories isolated from the developer's guarded
# Git shim, global hooks, and signing policy.
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REMOTE="${ROOT}/remote.git"
REPO="${ROOT}/repo"
LINKED="${ROOT}/release"
BIN="${ROOT}/bin"
mkdir -p "$BIN"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" switch -q -c main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main
MERGE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" worktree add -q --detach "$LINKED" origin/main

cat >"${BIN}/gh" <<STUB
#!/usr/bin/env bash
case "\${PROVENANCE_MODE:-merged}" in
	open) printf '%s\n' '{"state":"OPEN","mergedAt":null,"baseRefName":"main","headRefOid":"head123","mergeCommit":null}' ;;
	stale) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","baseRefName":"main","headRefOid":"head123","mergeCommit":{"oid":"0000000000000000000000000000000000000000"}}' ;;
	*) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","baseRefName":"main","headRefOid":"head123","mergeCommit":{"oid":"${MERGE_SHA}"}}' ;;
esac
exit 0
STUB
chmod +x "${BIN}/gh"

print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
export SCRIPT_DIR REPO_ROOT="$LINKED"
source "${SCRIPT_DIR}/version-manager-git.sh"

PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops || {
	printf 'FAIL merged source PR provenance was rejected\n'
	exit 1
}
printf 'PASS merged source PR provenance is accepted\n'

if PROVENANCE_MODE=open PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'FAIL open source PR was accepted\n'
	exit 1
fi
printf 'PASS open source PR is rejected\n'

if PROVENANCE_MODE=stale PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'FAIL unreachable merge SHA was accepted\n'
	exit 1
fi
printf 'PASS unreachable merge SHA is rejected\n'

git -C "$REPO" switch -q -c safety/release-test
printf 'canonical human work\n' >>"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m 'local canonical divergence'
printf 'uncommitted human work\n' >>"${REPO}/README.md"
if verify_remote_sync main >/dev/null 2>&1 &&
	PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'PASS dirty diverged canonical checkout is irrelevant to detached release provenance\n'
else
	printf 'FAIL canonical checkout state blocked detached release provenance\n'
	exit 1
fi

if grep -qF 'verify_canonical_default_synced' "${SCRIPT_DIR}/version-manager.sh"; then
	printf 'FAIL release path still depends on canonical synchronization\n'
	exit 1
fi
printf 'PASS release path has no canonical synchronization dependency\n'

exit 0
