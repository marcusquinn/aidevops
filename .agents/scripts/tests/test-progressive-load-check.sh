#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$SCRIPT_DIR/../progressive-load-check.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/progressive-load-check.XXXXXX")
FIXTURE_DIR="$TEST_ROOT/agents"

cleanup() {
	local test_root="${TEST_ROOT:-}"

	if [[ -n "$test_root" ]]; then
		rm -rf "$test_root"
	fi
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

mkdir -p "$FIXTURE_DIR"
cp "$AGENTS_DIR/AGENTS.md" "$FIXTURE_DIR/AGENTS.md"
ln -s "$AGENTS_DIR/configs" "$FIXTURE_DIR/configs"
ln -s "$AGENTS_DIR/prompts" "$FIXTURE_DIR/prompts"
ln -s "$AGENTS_DIR/reference" "$FIXTURE_DIR/reference"
ln -s "$AGENTS_DIR/workflows" "$FIXTURE_DIR/workflows"

PROGRESSIVE_LOAD_AGENTS_DIR="$FIXTURE_DIR" "$CHECKER" --quiet >/dev/null ||
	fail "valid AGENTS.md fixture should pass"

sed 's#reference/review-bot-gate\.md#reference/missing-review-bot-gate.md#' \
	"$FIXTURE_DIR/AGENTS.md" >"$FIXTURE_DIR/AGENTS.md.tmp"
mv "$FIXTURE_DIR/AGENTS.md.tmp" "$FIXTURE_DIR/AGENTS.md"

if output=$(PROGRESSIVE_LOAD_AGENTS_DIR="$FIXTURE_DIR" "$CHECKER" --quiet 2>&1); then
	fail "fixture missing a required pointer should fail"
fi

case "$output" in
*"review-bot-gate"*) ;;
*) fail "failure should identify the missing review-bot pointer" ;;
esac

printf 'PASS: progressive-load pointer fixtures\n'
