#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Replay fixtures for superseded cancel-in-progress runs (GH#40329).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../gh-failure-miner-helper.sh"

# shellcheck disable=SC1090
source <(sed -n '/^filter_failed_check_runs()/,/^}/p' "$HELPER")

fail=0
check_count() {
	local label="$1" fixture="$2" expected="$3"
	local got
	got=$(filter_failed_check_runs "$fixture" | jq 'length')
	if [[ "$got" == "$expected" ]]; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s: expected %s got %s\n' "$label" "$expected" "$got"
		fail=1
	fi
	return 0
}

check_count "superseded cancelled then success -> 0" \
	'{"check_runs":[{"name":"x","conclusion":"cancelled","completed_at":"2026-01-01T01"},{"name":"x","conclusion":"cancelled","completed_at":"2026-01-01T02"},{"name":"x","conclusion":"success","completed_at":"2026-01-01T03"}]}' 0
check_count "cancelled-only, no newer run -> 1" \
	'{"check_runs":[{"name":"x","conclusion":"cancelled","completed_at":"2026-01-01T01"}]}' 1
check_count "cancelled mixed with failure -> 2" \
	'{"check_runs":[{"name":"x","conclusion":"cancelled","completed_at":"2026-01-01T01"},{"name":"x","conclusion":"failure","completed_at":"2026-01-01T02"},{"name":"x","conclusion":"success","completed_at":"2026-01-01T03"}]}' 2
check_count "success older than cancelled -> 1" \
	'{"check_runs":[{"name":"x","conclusion":"success","completed_at":"2026-01-01T01"},{"name":"x","conclusion":"cancelled","completed_at":"2026-01-01T02"}]}' 1

exit "$fail"
