#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
GRADUATE_HELPER="$REPO_ROOT/.agents/scripts/memory-graduate-helper.sh"
TEST_DIR="$(mktemp -d)"
DESTINATION="$TEST_DIR/graduated.md"
trap 'rm -rf "$TEST_DIR"' EXIT

memory() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" AIDEVOPS_VAULT_DIR="$TEST_DIR/no-vault" "$MEMORY_HELPER" "$@"
	return $?
}

graduate() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" AIDEVOPS_VAULT_DIR="$TEST_DIR/no-vault" AIDEVOPS_GRADUATED_FILE="$DESTINATION" "$GRADUATE_HELPER" "$@"
	return $?
}

store_id() {
	local content="$1"
	memory store --content "$content" --type WORKING_SOLUTION --confidence high | sed -n '$p'
	return "${PIPESTATUS[0]}"
}

add_verification_source() {
	local memory_id="$1"
	local source_id="verify_$memory_id"
	sqlite3 "$TEST_DIR/memory.db" "INSERT INTO observation_sources VALUES ('$source_id','obs_learning_$memory_id','test_result','result_$memory_id','ci-verifier','independent targeted test passed','ci:test-suite',strftime('%Y-%m-%dT%H:%M:%fZ','now'));"
	printf '%s\n' "$source_id"
	return 0
}

first_id=$(store_id "First verified promotion is removable without touching manual guidance")
second_id=$(store_id "Second verified promotion remains when the first promotion is revoked")
correction_id=$(store_id "Corrected guidance replaces the first verified promotion")
first_source=$(add_verification_source "$first_id")
second_source=$(add_verification_source "$second_id")

if graduate outcome "$first_id" test_passed --details self-claim >/dev/null 2>&1; then
	printf 'FAIL: qualifying outcome accepted missing attribution\n' >&2
	exit 1
fi
if graduate outcome "$first_id" test_passed --verifier self --source-id "src_learning_$first_id" --provenance manual >/dev/null 2>&1; then
	printf 'FAIL: qualifying outcome accepted self-asserted evidence\n' >&2
	exit 1
fi
graduate outcome "$first_id" test_passed --verifier ci-verifier --source-id "$first_source" --provenance ci:test-suite >/dev/null
graduate outcome "$second_id" operational_verified --verifier ci-verifier --source-id "$second_source" --provenance ci:test-suite >/dev/null
graduate graduate --limit 10 >/dev/null
printf '\nManual guidance must survive generated block removal.\n' >>"$DESTINATION"

db="$TEST_DIR/memory.db"
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM outcome_verifications WHERE verifier_id='ci-verifier';")" == "2" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM observation_promotions WHERE status='active';")" == "2" ]]
grep -F "First verified promotion" "$DESTINATION" >/dev/null
grep -F "Second verified promotion" "$DESTINATION" >/dev/null

graduate revoke "$first_id" --reason "later regression disproved guidance" >/dev/null
if grep -F "First verified promotion" "$DESTINATION" >/dev/null; then
	printf 'FAIL: revoked generated guidance remains in destination\n' >&2
	exit 1
fi
grep -F "Second verified promotion" "$DESTINATION" >/dev/null
grep -F "Manual guidance must survive" "$DESTINATION" >/dev/null
content_after_first_revoke=$(cksum "$DESTINATION")
graduate revoke "$first_id" --reason "later regression disproved guidance" >/dev/null
[[ "$(cksum "$DESTINATION")" == "$content_after_first_revoke" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM observation_outcomes WHERE observation_id='obs_learning_$first_id' AND outcome_kind='reverted';")" == "1" ]]

# Re-activate a fixture promotion to exercise correction separately.
sqlite3 "$db" "UPDATE observation_promotions SET status='active' WHERE observation_id='obs_learning_$first_id'; UPDATE observations SET status='active' WHERE observation_id='obs_learning_$first_id';"
graduate revoke "$first_id" --corrected-by "$correction_id" --reason "replacement guidance verified" >/dev/null
[[ "$(sqlite3 "$db" "SELECT status FROM observation_promotions WHERE observation_id='obs_learning_$first_id';")" == "corrected" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM observation_relations WHERE observation_id='obs_learning_$correction_id' AND target_observation_id='obs_learning_$first_id' AND relation_type='corrects';")" == "1" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM observation_outcomes WHERE observation_id='obs_learning_$first_id' AND outcome_kind='correction';")" == "1" ]]

printf 'PASS: independently verified promotion, exact idempotent revocation, and correction audit behavior\n'
