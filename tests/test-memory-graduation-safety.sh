#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for safe memory graduation candidate selection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
GRADUATE_HELPER="$REPO_ROOT/.agents/scripts/memory-graduate-helper.sh"
TEST_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TEST_DIR"
	return 0
}
trap cleanup EXIT

store_memory_id() {
	local output=""
	local line=""
	local memory_id=""
	output=$(AIDEVOPS_MEMORY_DIR="$TEST_DIR" "$MEMORY_HELPER" store "$@")
	while IFS= read -r line; do
		if [[ "$line" == mem_* ]]; then
			memory_id="$line"
		fi
	done <<<"$output"
	printf '%s\n' "$memory_id"
	return 0
}

candidate_json() {
	local output=""
	local line=""
	local json=""
	local capturing=0
	output=$(AIDEVOPS_MEMORY_DIR="$TEST_DIR" "$GRADUATE_HELPER" candidates --json --limit 50)
	while IFS= read -r line; do
		if [[ "$line" == \[* ]]; then
			capturing=1
		fi
		if [[ "$capturing" -eq 1 ]]; then
			json+="$line"$'\n'
		fi
	done <<<"$output"
	printf '%s' "$json"
	return 0
}

graduation_preview() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" "$GRADUATE_HELPER" graduate --dry-run --limit 50 2>&1
	return $?
}

test_legacy_schema_migration() {
	local legacy_dir=""
	local output=""
	local truth_table_count=""
	legacy_dir=$(mktemp -d)

	AIDEVOPS_MEMORY_DIR="$legacy_dir" "$MEMORY_HELPER" store \
		--content "Legacy schema graduation remains safely migratable" \
		--type WORKING_SOLUTION --confidence high >/dev/null
	sqlite3 "$legacy_dir/memory.db" "DROP TABLE learning_truth_events; DROP TABLE learning_relations;"

	output=$(AIDEVOPS_MEMORY_DIR="$legacy_dir" "$GRADUATE_HELPER" candidates --json --limit 10)
	truth_table_count=$(sqlite3 "$legacy_dir/memory.db" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('learning_truth_events', 'learning_relations');")
	rm -rf "$legacy_dir"

	if [[ "$truth_table_count" != "2" || "$output" != *"Legacy schema graduation remains safely migratable"* ]]; then
		printf 'FAIL: graduation did not migrate a legacy truth-maintenance schema\n' >&2
		return 1
	fi
	return 0
}

main() {
	local preference_id=""
	local live_id=""
	local myth_id=""
	local replacement_id=""
	local old_id=""
	local new_id=""
	local results=""
	local preview=""
	local secret_value=""

	preference_id=$(store_memory_id --content "User prefers terse status summaries in personal sessions" --type USER_PREFERENCE --confidence high)
	live_id=$(store_memory_id --content "Portable privacy filters use POSIX extended regular expressions" --type WORKING_SOLUTION --confidence high)
	myth_id=$(store_memory_id --content "Obsolete privacy claim should never graduate into shared guidance" --type FAILURE_PATTERN --confidence high)
	replacement_id=$(store_memory_id --content "Verified privacy behavior replaces the obsolete shared claim" --type WORKING_SOLUTION --confidence high)
	store_memory_id --content "Evidence disproves the obsolete privacy graduation claim" --type ERROR_FIX --confidence high --debunks "$myth_id" --replacement "$replacement_id" --evidence "Regression test" >/dev/null
	old_id=$(store_memory_id --content "Old deployment guidance uses the retired memory path" --type TOOL_CONFIG --confidence high)
	new_id=$(store_memory_id --content "Current deployment guidance uses the supported memory path" --type TOOL_CONFIG --confidence high --supersedes "$old_id" --relation updates)
	store_memory_id --content "Contact private.person@example.test before publishing this workflow" --type CONTEXT --confidence high >/dev/null
	store_memory_id --content "Local evidence is stored at /Users/private-user/secret-project/report.md" --type TOOL_CONFIG --confidence high >/dev/null
	store_memory_id --content "Safe-looking content with private metadata must remain local" --type CONTEXT --confidence high --tags "owner.private@example.test,/Users/private-user/project" >/dev/null
	secret_value="sk-$(printf '%024d' 0)"
	sqlite3 "$TEST_DIR/memory.db" <<EOF
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('mem_secret_content_fixture', '', 'Legacy credential $secret_value must remain local', 'CONTEXT', 'legacy', 'high', datetime('now'), '', '', 'legacy');
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('mem_secret_tag_fixture', '', 'Safe content with credential metadata must remain local', 'CONTEXT', '$secret_value', 'high', datetime('now'), '', '', 'legacy');
EOF

	results=$(candidate_json)
	if [[ "$results" == *"private.person@example.test"* || "$results" == *"owner.private@example.test"* ||
		"$results" == *"/Users/private-user/"* || "$results" == *"$secret_value"* ]]; then
		printf 'FAIL: graduation candidate JSON exposed personal content\n' >&2
		return 1
	fi

	jq -e --arg id "$live_id" 'map(.id) | index($id) != null' <<<"$results" >/dev/null
	jq -e --arg id "$replacement_id" 'map(.id) | index($id) != null' <<<"$results" >/dev/null
	jq -e --arg id "$new_id" 'map(.id) | index($id) != null' <<<"$results" >/dev/null
	jq -e --arg id "$preference_id" 'map(.id) | index($id) | not' <<<"$results" >/dev/null
	jq -e --arg id "$myth_id" 'map(.id) | index($id) | not' <<<"$results" >/dev/null
	jq -e --arg id "$old_id" 'map(.id) | index($id) | not' <<<"$results" >/dev/null

	preview=$(graduation_preview)
	if [[ "$preview" == *"private.person@example.test"* || "$preview" == *"/Users/private-user/"* ||
		"$preview" == *"$secret_value"* ]]; then
		printf 'FAIL: graduation preview exposed personal content\n' >&2
		return 1
	fi
	test_legacy_schema_migration

	printf 'PASS: graduation includes live shareable memories and excludes personal, private, debunked, and superseded records\n'
	return 0
}

main "$@"
