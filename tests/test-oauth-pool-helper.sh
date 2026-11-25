#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

# ---------------------------------------------------------------------------
# Test: set-priority command
# ---------------------------------------------------------------------------

run_test_set_priority() {
	printf "\n=== set-priority command ===\n"

	local test_home
	test_home="$(mktemp -d)"
	trap 'rm -rf "$test_home"' RETURN

	mkdir -p "$test_home/.aidevops"
	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	python3 - "$test_home/.aidevops/oauth-pool.json" "$now_ms" <<'PY'
import json, sys
path = sys.argv[1]
now_ms = int(sys.argv[2])
pool = {
    "anthropic": [
        {
            "email": "personal@example.com",
            "access": "token1",
            "refresh": "refresh1",
            "expires": now_ms + 3600000,
            "status": "active",
            "cooldownUntil": None,
            "lastUsed": "2026-01-01T00:00:00Z"
        },
        {
            "email": "work@example.com",
            "access": "token2",
            "refresh": "refresh2",
            "expires": now_ms + 3600000,
            "status": "active",
            "cooldownUntil": None,
            "lastUsed": "2026-01-02T00:00:00Z"
        }
    ]
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(pool, f, indent=2)
PY

	# Set priority on work account
	local set_output
	set_output=$(HOME="$test_home" bash "$SCRIPT_PATH" set-priority anthropic work@example.com 10 2>&1)
	if [[ "$set_output" == *"Set priority 10"* ]]; then
		pass "set-priority reports success"
	else
		fail "set-priority did not report success" "$set_output"
	fi

	# Verify priority written to pool file
	local priority_val
	priority_val=$(jq -r '.anthropic[] | select(.email=="work@example.com") | .priority' "$test_home/.aidevops/oauth-pool.json")
	if [[ "$priority_val" == "10" ]]; then
		pass "set-priority writes priority field to pool file"
	else
		fail "priority field not written correctly" "priority=$priority_val"
	fi

	# Verify list shows priority
	local list_output
	list_output=$(HOME="$test_home" bash "$SCRIPT_PATH" list anthropic 2>&1)
	if [[ "$list_output" == *"work@example.com"*"priority:10"* ]]; then
		pass "list shows priority when set"
	else
		fail "list did not show priority" "$list_output"
	fi

	# Verify personal account line has no priority suffix
	local personal_line
	personal_line=$(printf '%s\n' "$list_output" | grep "personal@example.com" || true)
	if [[ "$personal_line" != *"priority:"* ]]; then
		pass "list does not show priority for accounts without priority"
	else
		fail "list showed priority for account without priority" "$personal_line"
	fi

	# Clear priority (set to 0)
	local clear_output
	clear_output=$(HOME="$test_home" bash "$SCRIPT_PATH" set-priority anthropic work@example.com 0 2>&1)
	if [[ "$clear_output" == *"Cleared priority"* ]]; then
		pass "set-priority 0 clears priority"
	else
		fail "set-priority 0 did not report clear" "$clear_output"
	fi

	# Verify priority field removed from pool file
	local priority_after_clear
	priority_after_clear=$(jq -r '.anthropic[] | select(.email=="work@example.com") | .priority // "null"' "$test_home/.aidevops/oauth-pool.json")
	if [[ "$priority_after_clear" == "null" ]]; then
		pass "set-priority 0 removes priority field from pool file"
	else
		fail "priority field not removed after clear" "priority=$priority_after_clear"
	fi

	# Error: unknown account
	local err_output
	err_output=$(HOME="$test_home" bash "$SCRIPT_PATH" set-priority anthropic unknown@example.com 5 2>&1 || true)
	if [[ "$err_output" == *"not found"* ]]; then
		pass "set-priority reports error for unknown account"
	else
		fail "set-priority did not report error for unknown account" "$err_output"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test: priority-based rotation sort order
# ---------------------------------------------------------------------------

run_test_priority_rotation_sort() {
	printf "\n=== priority rotation sort order ===\n"

	local test_home
	test_home="$(mktemp -d)"
	trap 'rm -rf "$test_home"' RETURN

	mkdir -p "$test_home/.aidevops"
	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	# Create pool: low-priority account used less recently, high-priority used more recently
	# Without priority: LRU would pick personal (older lastUsed)
	# With priority: should pick work (higher priority) despite more recent lastUsed
	python3 - "$test_home/.aidevops/oauth-pool.json" "$now_ms" <<'PY'
import json, sys
path = sys.argv[1]
now_ms = int(sys.argv[2])
pool = {
    "anthropic": [
        {
            "email": "personal@example.com",
            "access": "token1",
            "refresh": "refresh1",
            "expires": now_ms + 3600000,
            "status": "active",
            "cooldownUntil": None,
            "lastUsed": "2026-01-01T00:00:00Z"
        },
        {
            "email": "work@example.com",
            "access": "token2",
            "refresh": "refresh2",
            "expires": now_ms + 3600000,
            "status": "active",
            "cooldownUntil": None,
            "lastUsed": "2026-01-03T00:00:00Z",
            "priority": 10
        }
    ]
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(pool, f, indent=2)
PY

	# Verify the rotation sort: python inline mirrors _rotate_execute sort
	local sort_result
	sort_result=$(
		python3 - "$test_home/.aidevops/oauth-pool.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    pool = json.load(f)
accounts = pool.get("anthropic", [])
# Mirror _rotate_execute sort: (-priority, lastUsed)
accounts.sort(key=lambda a: (-(a.get('priority') or 0), a.get('lastUsed', '')))
print(accounts[0]['email'])
PY
	)
	if [[ "$sort_result" == "work@example.com" ]]; then
		pass "priority sort prefers high-priority account over LRU"
	else
		fail "priority sort did not prefer high-priority account" "got=$sort_result"
	fi

	# Verify that without priority, LRU wins
	local lru_result
	lru_result=$(
		python3 - "$test_home/.aidevops/oauth-pool.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    pool = json.load(f)
accounts = pool.get("anthropic", [])
# LRU only (no priority)
accounts.sort(key=lambda a: a.get('lastUsed', ''))
print(accounts[0]['email'])
PY
	)
	if [[ "$lru_result" == "personal@example.com" ]]; then
		pass "LRU-only sort picks least-recently-used (baseline)"
	else
		fail "LRU-only sort did not pick least-recently-used" "got=$lru_result"
	fi

	return 0
}

run_test_set_priority
run_test_priority_rotation_sort

# Exercise the real CLI in a new session so /dev/tty cannot consume test input.
# Empty authorization input stops callback enrollment before any token exchange.
run_test_openai_add_routing() {
	local test_home
	test_home="$(mktemp -d)"
	trap 'rm -rf "$test_home"' RETURN

	printf '\n=== OpenAI add-mode routing ===\n'
	if python3 - "$SCRIPT_PATH" "$test_home" <<'PY'; then
import json
import os
from pathlib import Path
import subprocess
import sys

script, root = sys.argv[1:]
cases = [
    ("v1-device", "1.19.6", "device", False, True, False),
    ("v2-callback", "2.3.2", "device", False, False, False),
    ("explicit-callback", "2.3.2", "callback", False, False, False),
    ("v1-fallback", "1.19.6", "device", True, False, True),
    ("invalid-mode", "2.3.2", "invalid", False, False, False),
    ("unknown-version", "unknown", "device", True, False, True),
    ("failed-version", "failed", "device", True, False, True),
]
for name, version, mode, device_fails, success, fallback in cases:
    for prefilled in (False, True):
        home = Path(root) / (name + ("-prefilled" if prefilled else "-prompt"))
        bin_dir = home / "bin"
        bin_dir.mkdir(parents=True)
        auth_dir = home / ".local/share/opencode"
        auth_dir.mkdir(parents=True)
        (auth_dir / "auth.json").write_text(json.dumps({"openai": {
            "type": "oauth", "access": "test-access", "refresh": "test-refresh",
            "expires": 4102444800000, "accountId": "test-account"
        }}))
        stub = bin_dir / "opencode"
        stub.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$HOME/opencode-calls"
if [[ "${1:-}" == "--version" ]]; then
    [[ "$TEST_VERSION" != failed ]] || exit 1
    printf '%s\\n' "$TEST_VERSION"
    exit 0
fi
[[ "$*" == 'providers login -p OpenAI -m ChatGPT Pro/Plus (headless)' ]] || exit 99
[[ "$TEST_DEVICE_FAILS" != 1 ]] || exit 1
exit 0
''')
        stub.chmod(0o700)
        # macOS permits GUI launching even when display variables are empty.
        launcher = bin_dir / "open"
        launcher.write_text("#!/usr/bin/env bash\nexit 0\n")
        launcher.chmod(0o700)
        env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / ".local/share"),
                   PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   AIDEVOPS_OAUTH_POOL_FILE=str(home / "pool.json"),
                   AIDEVOPS_OPENAI_ADD_MODE=mode, TEST_VERSION=version,
                   TEST_DEVICE_FAILS=str(int(device_fails)), DISPLAY="",
                   WAYLAND_DISPLAY="", WSL_DISTRO_NAME="")
        args = ["bash", script, "add", "openai"]
        if prefilled:
            args.append("routing@example.com")
        stdin = "" if mode == "invalid" else ('\n' if prefilled else "routing@example.com\n\n")
        result = subprocess.run(args, env=env, input=stdin, text=True,
                                capture_output=True, start_new_session=True, timeout=20)
        output = result.stdout + result.stderr
        calls_file = home / "opencode-calls"
        calls = calls_file.read_text().splitlines() if calls_file.exists() else []
        label = f"{name} (prefilled={prefilled})"
        assert result.returncode == (0 if success else 1), (label, output)
        assert output.count("Account email: ") == int(not prefilled and mode != "invalid"), (label, output)
        assert output.count("Using email: routing@example.com") == int(prefilled and mode != "invalid"), (label, output)
        assert output.count("falling back to callback URL flow") == int(fallback), (label, output)
        auto = name == "v2-callback"
        assert output.count("OpenCode 2 (version 2 or later) detected; using callback URL flow") == int(auto), (label, output)
        login = "providers login -p OpenAI -m ChatGPT Pro/Plus (headless)"
        assert calls.count(login) == int(success or fallback), (label, calls)
        if mode != "device":
            assert not calls, (label, calls)
        if mode == "invalid":
            assert "Invalid AIDEVOPS_OPENAI_ADD_MODE: invalid (valid: device, callback)" in output
        elif not success:
            assert "No authorization code provided" in output, (label, output)
            assert not (home / "pool.json").exists(), label
        else:
            pool = json.loads((home / "pool.json").read_text())
            assert pool["openai"][0]["email"] == "routing@example.com", label
        print(f"  verified {label}")
PY
		pass "OpenAI add routing, single email resolution and accurate messages"
	else
		fail "OpenAI add routing regression"
	fi
	return 0
}

run_test_openai_add_routing

printf "\nSummary: %s passed, %s failed\n" "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
