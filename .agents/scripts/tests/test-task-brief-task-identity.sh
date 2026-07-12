#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${TEST_SCRIPTS_DIR}/task-brief-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
REPO_DIR="${TEST_ROOT}/repo"
TASK_ID="to01j2abc3def4gh5jkm6npq7rst-42.3"
PARENT_ID="to01j2abc3def4gh5jkm6npq7rst-42"

mkdir -p "$HOME" "$REPO_DIR"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.email 'test@example.com'
git -C "$REPO_DIR" config user.name 'Test Runner'
printf '%s\n' "- [ ] ${TASK_ID} Migrate task identity consumers #framework" >"${REPO_DIR}/TODO.md"
git -C "$REPO_DIR" add TODO.md
git -C "$REPO_DIR" commit -q -m "test: add ${TASK_ID}"

"$HELPER" "$TASK_ID" "$REPO_DIR" >/dev/null
BRIEF_FILE="${REPO_DIR}/todo/tasks/${TASK_ID}-brief.md"
[[ -f "$BRIEF_FILE" ]]
grep -qF "# ${TASK_ID}: Migrate task identity consumers" "$BRIEF_FILE"
grep -qF "**Parent task:** ${PARENT_ID}" "$BRIEF_FILE"
grep -qF "todo/tasks/${PARENT_ID}-brief.md" "$BRIEF_FILE"

if "$HELPER" 't42.0' "$REPO_DIR" >/dev/null 2>&1; then
	printf 'malformed task ID unexpectedly accepted\n' >&2
	exit 1
fi
[[ ! -e "${REPO_DIR}/todo/tasks/t42.0-brief.md" ]]

printf 'task brief identity tests passed\n'
exit 0
