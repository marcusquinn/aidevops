#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for gh-signature-helper.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../gh-signature-helper.sh"

PASS=0
FAIL=0

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== gh-signature-helper.sh tests ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: generate with explicit CLI, model, tokens
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: generate with all explicit fields"
result=$("$HELPER" generate --cli "OpenCode" --cli-version "1.3.3" --model "anthropic/claude-opus-4-6" --tokens 1234)
assert_contains "starts with aidevops" "[aidevops.sh](https://aidevops.sh)" "$result"
assert_contains "contains CLI with plugin for" "plugin for [OpenCode](https://opencode.ai) v1.3.3" "$result"
assert_contains "model strips provider prefix" "with claude-opus-4-6" "$result"
assert_not_contains "no provider prefix" "anthropic/" "$result"
assert_contains "contains formatted tokens" "1,234 tokens on this" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: generate with explicit --tokens 0 (should omit tokens)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: explicit --tokens 0 omits tokens"
result=$("$HELPER" generate --cli "Claude Code" --cli-version "2.0.1" --model "anthropic/claude-sonnet-4-6" --tokens 0)
assert_contains "contains Claude Code" "plugin for [Claude Code](https://claude.ai/code) v2.0.1" "$result"
assert_not_contains "no tokens field" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: generate with zero tokens (should omit)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: zero tokens omitted"
result=$("$HELPER" generate --cli "OpenCode" --model "anthropic/claude-opus-4-6" --tokens 0)
assert_not_contains "zero tokens omitted" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: generate with no --model flag (auto-detects from session DB if available)
# GH#12965: model is now auto-detected from the OpenCode session DB, so the
# output may contain a model even without --model. We only verify the CLI
# override works and aidevops branding is present.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: no explicit model (auto-detect from DB)"
result=$("$HELPER" generate --cli "Cursor" --tokens 0)
assert_contains "contains Cursor link" "plugin for [Cursor](https://cursor.com)" "$result"
assert_contains "contains aidevops" "aidevops.sh" "$result"
# Model may or may not be present depending on whether a session DB is available

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: footer command includes --- separator
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: footer includes --- separator"
result=$("$HELPER" footer --cli "OpenCode" --cli-version "1.0.0" --model "anthropic/claude-sonnet-4-6" --tokens 5000)
assert_contains "contains ---" "---" "$result"
assert_contains "contains signature" "plugin for [OpenCode](https://opencode.ai) v1.0.0" "$result"
assert_contains "contains tokens" "5,000 tokens on this" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: comma formatting for various numbers
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: comma formatting"
result=$("$HELPER" generate --cli "Test" --model "m" --tokens 999)
assert_contains "3-digit no comma" "999 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1000)
assert_contains "4-digit with comma" "1,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 45000)
assert_contains "5-digit with comma" "45,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1234567)
assert_contains "7-digit with commas" "1,234,567 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: CLI URL mapping for known runtimes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: CLI URL mapping"
result=$("$HELPER" generate --cli "OpenCode" --model "m")
assert_contains "OpenCode URL" "https://opencode.ai" "$result"

result=$("$HELPER" generate --cli "Claude Code" --model "m")
assert_contains "Claude Code URL" "https://claude.ai/code" "$result"

result=$("$HELPER" generate --cli "Cursor" --model "m")
assert_contains "Cursor URL" "https://cursor.com" "$result"

result=$("$HELPER" generate --cli "Aider" --model "m")
assert_contains "Aider URL" "https://aider.chat" "$result"

result=$("$HELPER" generate --cli "Windsurf" --model "m")
assert_contains "Windsurf URL" "https://windsurf.com" "$result"

result=$("$HELPER" generate --cli "Continue" --model "m")
assert_contains "Continue URL" "https://continue.dev" "$result"

result=$("$HELPER" generate --cli "GitHub Copilot" --model "m")
assert_contains "Copilot URL" "https://github.com/features/copilot" "$result"

result=$("$HELPER" generate --cli "Cody" --model "m")
assert_contains "Cody URL" "https://sourcegraph.com/cody" "$result"

result=$("$HELPER" generate --cli "Kilo Code" --model "m")
assert_contains "Kilo Code URL" "https://kilocode.ai" "$result"

result=$("$HELPER" generate --cli "Augment" --model "m")
assert_contains "Augment URL" "https://augmentcode.com" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: unknown CLI gets no link
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: unknown CLI has no link"
result=$("$HELPER" generate --cli "SomeNewTool" --model "m")
assert_contains "CLI name present" "SomeNewTool" "$result"
assert_not_contains "no CLI markdown link" "[SomeNewTool](" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: env var overrides
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: environment variable overrides"
result=$(AIDEVOPS_SIG_CLI="EnvCLI" AIDEVOPS_SIG_CLI_VERSION="9.9.9" AIDEVOPS_SIG_MODEL="test/model" AIDEVOPS_SIG_TOKENS="42000" "$HELPER" generate)
assert_contains "env CLI name" "plugin for EnvCLI" "$result"
assert_contains "env CLI version" "v9.9.9" "$result"
assert_contains "env model strips prefix" "with model" "$result"
assert_contains "env tokens" "42,000 tokens on this" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: auto-detect tokens from OpenCode session DB (if running in OpenCode)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10: auto-detect tokens from session DB"
if [[ "${OPENCODE:-}" == "1" ]] && [[ -r "${HOME}/.local/share/opencode/opencode.db" ]]; then
	result=$("$HELPER" generate --cli "OpenCode" --model "anthropic/claude-opus-4-6")
	assert_contains "auto-detected tokens present" "tokens" "$result"
else
	echo "  SKIP: not running in OpenCode (auto-detect test requires OpenCode session DB)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: session and response time auto-detection (OpenCode only)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 11: session time auto-detection (no response time)"
if [[ "${OPENCODE:-}" == "1" ]] && [[ -r "${HOME}/.local/share/opencode/opencode.db" ]]; then
	result=$("$HELPER" generate --cli "OpenCode" --model "m" --tokens 1)
	assert_contains "session time present" "spent " "$result"
	assert_not_contains "no response time" "to respond" "$result"
else
	echo "  SKIP: not running in OpenCode"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: total time with --issue-created
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 12: total time with --issue-created"
two_hours_ago=$(date -u -v-2H "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [[ -n "$two_hours_ago" ]]; then
	result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1 --issue-created "$two_hours_ago")
	assert_contains "total time present" "since this issue was created" "$result"
	assert_contains "total time has hours" "h" "$result"
else
	echo "  SKIP: date command does not support relative time"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: --solved flag changes total time phrasing
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 13: --solved flag"
if [[ -n "$two_hours_ago" ]]; then
	result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1 --issue-created "$two_hours_ago" --solved)
	assert_contains "solved phrasing" "Solved in " "$result"
	assert_not_contains "no since phrasing" "since this issue" "$result"
else
	echo "  SKIP: date command does not support relative time"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: issue-created scopes token detection to issue window
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 14: issue-created token scoping"
tmp_home=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper)
mkdir -p "${tmp_home}/.local/share/opencode"
db_path="${tmp_home}/.local/share/opencode/opencode.db"

now_epoch=$(date +%s)
session_created_ms=$(((now_epoch - 3600) * 1000))
pre_msg_ms=$(((now_epoch - 1200) * 1000))
issue_created_epoch=$((now_epoch - 600))
post_msg_ms=$(((now_epoch - 300) * 1000))

issue_created_iso=$(date -u -r "$issue_created_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
	date -u -d "@${issue_created_epoch}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

cwd_sql=$(pwd)
cwd_sql=${cwd_sql//\'/\'\'}

if command -v sqlite3 &>/dev/null; then
	sqlite3 "$db_path" "
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  title TEXT,
  directory TEXT NOT NULL,
  time_created INTEGER NOT NULL
);
CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
INSERT INTO session (id,title,directory,time_created)
VALUES ('ses_test_scope','sig-test','${cwd_sql}',${session_created_ms});
INSERT INTO message (id,session_id,time_created,time_updated,data)
VALUES
  ('msg_pre','ses_test_scope',${pre_msg_ms},${pre_msg_ms},'{\"tokens\":{\"input\":100,\"output\":10,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}'),
  ('msg_post','ses_test_scope',${post_msg_ms},${post_msg_ms},'{\"tokens\":{\"input\":200,\"output\":20,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');
"

	if [[ -n "$issue_created_iso" ]]; then
		result=$(HOME="$tmp_home" "$HELPER" generate --cli "OpenCode" --model "m" --issue-created "$issue_created_iso")
		assert_contains "issue window uses scoped tokens" "220 tokens on this" "$result"
		assert_not_contains "issue window excludes pre-issue tokens" "330 tokens on this" "$result"

		issue_after_epoch=$((now_epoch - 60))
		issue_after_iso=$(date -u -r "$issue_after_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
			date -u -d "@${issue_after_epoch}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
		if [[ -n "$issue_after_iso" ]]; then
			result=$(HOME="$tmp_home" "$HELPER" generate --cli "OpenCode" --model "m" --issue-created "$issue_after_iso")
			assert_not_contains "post-window excludes pre-issue fallback" "330 tokens on this" "$result"
			assert_not_contains "post-window omits scoped zero token phrase" "0 tokens on this" "$result"
		else
			echo "  SKIP: could not construct post-window issue-created timestamp"
		fi
	else
		echo "  SKIP: could not construct issue-created timestamp"
	fi
else
	echo "  SKIP: sqlite3 not available"
fi

rm -rf "$tmp_home"

# ─────────────────────────────────────────────────────────────────────────────
# Test 15: help command exits cleanly
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 15: help command"
result=$("$HELPER" help 2>&1)
assert_contains "help shows usage" "Usage:" "$result"
assert_contains "help shows examples" "Examples:" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
