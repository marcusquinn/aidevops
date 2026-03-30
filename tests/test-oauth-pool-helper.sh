#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/.agents/scripts/oauth-pool-helper.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	printf "  PASS %s\n" "$1"
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf "  FAIL %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

run_test_expired_cooldown_auto_clear() {
	printf "\n=== expired cooldown auto-clear ===\n"

	local test_home
	test_home="$(mktemp -d)"
	trap 'rm -rf "$test_home"' RETURN

	mkdir -p "$test_home/.aidevops"
	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")
	local expired_ms
	expired_ms=$((now_ms - 60000))

	python3 - "$test_home/.aidevops/oauth-pool.json" "$expired_ms" <<'PY'
import json
import sys

path = sys.argv[1]
expired_ms = int(sys.argv[2])
pool = {
    "openai": [
        {
            "email": "expired@example.com",
            "access": "token",
            "refresh": "refresh",
            "expires": expired_ms + 3600000,
            "status": "rate-limited",
            "cooldownUntil": expired_ms,
            "lastUsed": "2026-01-01T00:00:00Z"
        }
    ]
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(pool, f, indent=2)
PY

	HOME="$test_home" bash "$SCRIPT_PATH" check openai >/tmp/oauth-check.out 2>/tmp/oauth-check.err

	local status_after
	status_after=$(jq -r '.openai[0].status' "$test_home/.aidevops/oauth-pool.json")
	local cooldown_after
	cooldown_after=$(jq -r '.openai[0].cooldownUntil' "$test_home/.aidevops/oauth-pool.json")

	if [[ "$status_after" == "idle" ]]; then
		pass "check auto-clears expired cooldown status"
	else
		fail "check did not auto-clear status" "status=$status_after"
	fi

	if [[ "$cooldown_after" == "0" ]]; then
		pass "check clears cooldownUntil to 0"
	else
		fail "check did not clear cooldownUntil to 0" "cooldownUntil=$cooldown_after"
	fi

	local status_output
	status_output=$(HOME="$test_home" bash "$SCRIPT_PATH" status openai 2>&1)
	if [[ "$status_output" == *"Available now  : 1"* && "$status_output" == *"Rate limited   : 0"* ]]; then
		pass "status reflects account as available after auto-clear"
	else
		fail "status output did not reflect cleared cooldown" "$status_output"
	fi

	local list_output
	list_output=$(HOME="$test_home" bash "$SCRIPT_PATH" list openai 2>&1)
	if [[ "$list_output" == *"expired@example.com [idle]"* ]]; then
		pass "list shows idle status after auto-clear"
	else
		fail "list output did not show idle status" "$list_output"
	fi

	return 0
}

run_test_expired_cooldown_auto_clear

printf "\nSummary: %s passed, %s failed\n" "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
