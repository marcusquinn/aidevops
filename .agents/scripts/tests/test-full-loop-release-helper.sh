#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/repo/linked-branch" "$ROOT/worktrees"

cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_CALL_LOG:?}"
case "$*" in
*rev-parse\ --show-toplevel*) printf '%s\n' "${FAKE_REPO_ROOT:?}" ;;
*worktree\ add*)
	for arg in "$@"; do
		case "$arg" in */aidevops-release-*) mkdir -p "$arg" ;; esac
	done
	;;
*worktree\ remove*)
	for arg in "$@"; do
		case "$arg" in */aidevops-release-*) rm -rf "$arg" ;; esac
	done
	;;
esac
exit 0
STUB
chmod +x "$ROOT/bin/git"

cat >"$ROOT/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >"${VM_CALL_LOG:?}"
printf 'cwd=%s\n' "$PWD" >>"$VM_CALL_LOG"
printf 'intent=%s\n' "${AIDEVOPS_RELEASE_INTENT_TRUSTED:-}" >>"$VM_CALL_LOG"
printf 'priority=%s\n' "${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" >>"$VM_CALL_LOG"
printf 'deploy=%s\n' "${AIDEVOPS_RELEASE_DEPLOY_SCOPE:-}" >>"$VM_CALL_LOG"
exit "${VM_EXIT:-0}"
STUB
chmod +x "$ROOT/version-manager.sh"

(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		AIDEVOPS_TRUSTED_ISSUE_PRIORITY=critical \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" minor 42 full
)

grep -q 'worktree add --detach' "$ROOT/git.log"
grep -q 'worktree remove' "$ROOT/git.log"
grep -qx 'args=release minor --source-pr 42' "$ROOT/vm.log"
grep -Eq "^cwd=${ROOT}/worktrees/aidevops-release-42-[0-9]+$" "$ROOT/vm.log"
grep -qx 'intent=1' "$ROOT/vm.log"
grep -qx 'priority=critical' "$ROOT/vm.log"
grep -qx 'deploy=full' "$ROOT/vm.log"
grep -qx 'published' "$ROOT/receipts/marcusquinn_aidevops-42.status"
if compgen -G "$ROOT/worktrees/aidevops-release-42-*" >/dev/null; then
	printf 'FAIL detached release worktree was not removed\n'
	exit 1
fi
printf 'PASS detached release runner persists publication receipt after successful gates\n'

cp "$ROOT/vm.log" "$ROOT/vm-after-publication.log"
worktree_adds_before=$(grep -c 'worktree add --detach' "$ROOT/git.log")
(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" minor 42 full
)
cmp -s "$ROOT/vm.log" "$ROOT/vm-after-publication.log"
worktree_adds_after=$(grep -c 'worktree add --detach' "$ROOT/git.log")
[[ "$worktree_adds_after" -eq "$worktree_adds_before" ]]
printf 'PASS repeated detached release reconciliation skips duplicate publication\n'

if (
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		VM_EXIT=1 \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 43 incremental
); then
	printf 'FAIL partial release returned success\n'
	exit 1
fi
if [[ -e "$ROOT/receipts/marcusquinn_aidevops-43.status" ]]; then
	printf 'FAIL partial release persisted a success receipt\n'
	exit 1
fi
printf 'PASS failed release never persists publication receipt\n'

printf '%s\n' not-requested >"$ROOT/receipts/marcusquinn_aidevops-44.status"
cp "$ROOT/vm.log" "$ROOT/vm-before-skipped-release.log"
if (
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 44 incremental
); then
	printf 'FAIL skipped release evidence was replaced\n'
	exit 1
fi
grep -qx 'not-requested' "$ROOT/receipts/marcusquinn_aidevops-44.status"
cmp -s "$ROOT/vm.log" "$ROOT/vm-before-skipped-release.log"
printf 'PASS skipped release evidence cannot trigger publication\n'

exit 0
