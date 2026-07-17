#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
GIT_SHIM="${SCRIPT_DIR}/git"
TEST_ROOT=$(mktemp -d)
REPO="${TEST_ROOT}/repo"
LINKED="${TEST_ROOT}/linked"
FAILED_LINKED="${TEST_ROOT}/failed-linked"
SHIM_BIN="${TEST_ROOT}/bin"
TEST_PATH="${SHIM_BIN}:/usr/bin:/bin:/usr/sbin:/sbin"
FAILING_GIT="${TEST_ROOT}/failing-git"
QUERY_FAILING_GIT="${TEST_ROOT}/query-failing-git"
POST_PRUNE_QUERY_FAILING_GIT="${TEST_ROOT}/post-prune-query-failing-git"
POST_PRUNE_QUERY_STATE="${TEST_ROOT}/post-prune-query-state"

teardown() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap teardown EXIT

mkdir -p "$REPO" "$SHIM_BIN"
/usr/bin/git -C "$REPO" init -q -b main
/usr/bin/git -C "$REPO" config user.name Test
/usr/bin/git -C "$REPO" config user.email test@example.invalid
/usr/bin/git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
/usr/bin/git -C "$REPO" add README.md
/usr/bin/git -C "$REPO" commit -q -m seed
/usr/bin/git -C "$REPO" worktree add -q -b feature/prune-test "$LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/prune-failure "$FAILED_LINKED"
ln -s "$GIT_SHIM" "${SHIM_BIN}/git"

if PATH="$TEST_PATH" git -C "$REPO" worktree prune >/dev/null 2>&1; then
	printf 'FAIL canonical Git shim unexpectedly allowed direct metadata prune\n'
	exit 1
fi

mkdir -p "${TEST_ROOT}/home"
if ! output=$(
	cd "$REPO" || exit 1
	HOME="${TEST_ROOT}/home" PATH="$TEST_PATH" \
		bash "${SCRIPT_DIR}/worktree-helper.sh" remove "$LINKED" 2>&1
); then
	printf 'FAIL worktree-helper removal failed with canonical Git shim active: %s\n' "$output"
	exit 1
fi

if /usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $LINKED"; then
	printf 'FAIL linked worktree metadata remains after helper removal\n'
	exit 1
fi

printf 'PASS worktree-helper prunes metadata with canonical Git shim active\n'

cat >"$FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree prune"* ]]; then
	exit 1
fi
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	/usr/bin/git "$@" || exit 1
	printf 'worktree %s\n\n' "${FAILED_LINKED_FOR_TEST:?}"
	exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$FAILING_GIT"

if output=$(
	cd "$REPO" || exit 1
	HOME="${TEST_ROOT}/home" PATH="$TEST_PATH" AIDEVOPS_REAL_GIT_BIN="$FAILING_GIT" \
		FAILED_LINKED_FOR_TEST="$FAILED_LINKED" \
		bash "${SCRIPT_DIR}/worktree-helper.sh" remove "$FAILED_LINKED" 2>&1
); then
	printf 'FAIL worktree-helper reported success when metadata prune failed\n'
	exit 1
fi
if [[ "$output" != *"Partial cleanup:"* || "$output" != *"Recovery:"* ]]; then
	printf 'FAIL prune failure omitted partial-cleanup recovery guidance: %s\n' "$output"
	exit 1
fi
printf 'PASS worktree-helper returns partial-cleanup guidance when metadata prune fails\n'

cat >"$QUERY_FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	exit 1
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$QUERY_FAILING_GIT"
# shellcheck source=../audit-worktree-removal-helper.sh
source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
if AIDEVOPS_REAL_GIT_BIN="$QUERY_FAILING_GIT" \
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-query-target"; then
	printf 'FAIL metadata query failure was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS metadata query failure cannot report cleanup success\n'

if (
	_worktree_cleanup_real_git() {
		return 0
	}
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-empty-git-target"
); then
	printf 'FAIL empty native Git path was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS empty native Git path cannot report cleanup success\n'

cat >"$POST_PRUNE_QUERY_FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	query_count=0
	if [[ -f "${POST_PRUNE_QUERY_STATE_FOR_TEST:?}" ]]; then
		read -r query_count <"$POST_PRUNE_QUERY_STATE_FOR_TEST"
	fi
	query_count=$((query_count + 1))
	printf '%s\n' "$query_count" >"$POST_PRUNE_QUERY_STATE_FOR_TEST"
	if [[ "$query_count" -eq 1 ]]; then
		printf 'worktree %s\n\n' "${POST_PRUNE_TARGET_FOR_TEST:?}"
		exit 0
	fi
	exit 1
fi
if [[ "$*" == *"worktree prune"* ]]; then
	exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$POST_PRUNE_QUERY_FAILING_GIT"
if AIDEVOPS_REAL_GIT_BIN="$POST_PRUNE_QUERY_FAILING_GIT" \
	POST_PRUNE_QUERY_STATE_FOR_TEST="$POST_PRUNE_QUERY_STATE" \
	POST_PRUNE_TARGET_FOR_TEST="${TEST_ROOT}/missing-post-prune-query-target" \
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-post-prune-query-target"; then
	printf 'FAIL post-prune metadata query failure was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS post-prune metadata query failure cannot report cleanup success\n'
