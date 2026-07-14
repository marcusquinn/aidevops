#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../session-output-efficiency-helper.sh"
REVIEW_HELPER="${SCRIPT_DIR}/../session-review-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_omits() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected ${needle}"
	fi
	return 0
}

normalized_fixture="${TMPDIR_TEST}/normalized.jsonl"
claude_fixture="${TMPDIR_TEST}/claude.jsonl"
opencode_db="${TMPDIR_TEST}/opencode history?#.db"
active_home="${TMPDIR_TEST}/active-home"
active_export_fixture="${TMPDIR_TEST}/active-export.json"
mismatched_export_fixture="${TMPDIR_TEST}/mismatched-export.json"
fake_opencode_bin="${TMPDIR_TEST}/bin"

python3 - "$normalized_fixture" "$claude_fixture" "$opencode_db" "$active_home" "$active_export_fixture" "$mismatched_export_fixture" "$fake_opencode_bin" <<'PY'
import json
import os
import sqlite3
import sys

(
    normalized_path,
    claude_path,
    database_path,
    active_home,
    active_export_path,
    mismatched_export_path,
    fake_opencode_bin,
) = sys.argv[1:]
repeated = "unchanged status snapshot SECRET-MARKER " + ("x" * 100)
oversized = "large setup output " + ("y" * 9000)
duplicate = "duplicate tool result " + ("d" * 100)
repeated_line = "repeated line inside one model-visible result " + ("l" * 40)
block = "\n".join([
    "block line alpha " + ("a" * 40),
    "block line beta " + ("b" * 40),
    "block line gamma " + ("c" * 40),
])
fragment_output = "\n".join([repeated_line, repeated_line, repeated_line, block, block])
huge_fragment_output = "\n".join(["very large repeated fragment " + ("z" * 80)] * 1500)
receipt = "\n".join([
    "output_id: out_123_example",
    "outcome: succeeded",
    "exit_code: 0",
    "process_exit: 0",
    "evidence: bytes=23067 lines=134 sensitive_redacted=0 basis=exit-code",
])
json_receipt = json.dumps({
    "schema": "aidevops.operation-result/v1",
    "evidence": {"bytes": 4096},
})

with open(normalized_path, "w", encoding="utf-8") as handle:
    for _ in range(3):
        handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": repeated}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": "changed status"}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "setup"}, "output": oversized, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "fragments"}, "output": fragment_output, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "huge-fragments"}, "output": huge_fragment_output, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "read", "input": {"path": "one"}, "output": duplicate, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "read", "input": {"path": "two"}, "output": duplicate, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "receipt"}, "output": receipt, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "json-receipt"}, "output": json_receipt, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "fallback"}, "output": "output_sandbox: evidence store unavailable; running with native output\nnative output", "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "exact"}, "output": "output_sandbox: bypass exact/verbatim command\nexact output", "success": True}) + "\n")

with open(claude_path, "w", encoding="utf-8") as handle:
    for call_id in ("call-1", "call-2"):
        handle.write(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": call_id, "name": "Bash", "input": {"command": "poll"}}
        ]}}) + "\n")
        handle.write(json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": call_id, "content": repeated}
        ]}}) + "\n")

connection = sqlite3.connect(database_path)
connection.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
for index in range(2):
    part = {
        "type": "tool",
        "tool": "bash",
        "state": {"status": "completed", "input": {"command": "poll"}, "output": repeated},
    }
    connection.execute(
        "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
        (f"part-{index}", "session-test", index, json.dumps(part)),
    )
connection.commit()
connection.close()

active_database_path = os.path.join(active_home, ".local", "share", "opencode", "opencode.db")
os.makedirs(os.path.dirname(active_database_path), exist_ok=True)
active_connection = sqlite3.connect(active_database_path)
active_connection.execute("CREATE TABLE session (id TEXT PRIMARY KEY)")
active_connection.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
active_connection.execute("INSERT INTO session (id) VALUES (?)", ("session-active",))
unrelated_part = {
    "type": "tool",
    "tool": "read",
    "state": {"status": "completed", "input": {}, "output": "UNRELATED-RECENT-SESSION"},
}
active_connection.execute(
    "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
    ("unrelated-part", "unrelated-recent-session", 1, json.dumps(unrelated_part)),
)
active_connection.commit()
active_connection.close()

active_output = "active exact output ACTIVE-SECRET-MARKER " + ("q" * 100)
active_document = {
    "info": {"id": "session-active"},
    "messages": [{
        "info": {"role": "assistant"},
        "parts": [
            {
                "type": "tool",
                "tool": "bash",
                "state": {"status": "completed", "input": {"command": "poll"}, "output": active_output},
            },
            {
                "type": "tool",
                "tool": "bash",
                "state": {"status": "completed", "input": {"command": "poll"}, "output": active_output},
            },
        ],
    }],
}
with open(active_export_path, "w", encoding="utf-8") as handle:
    json.dump(active_document, handle)
active_document["info"]["id"] = "different-session"
with open(mismatched_export_path, "w", encoding="utf-8") as handle:
    json.dump(active_document, handle)

os.makedirs(fake_opencode_bin, exist_ok=True)
fake_opencode = os.path.join(fake_opencode_bin, "opencode")
with open(fake_opencode, "w", encoding="utf-8") as handle:
    handle.write("""#!/usr/bin/env python3
import os
import sys

if os.environ.get("AIDEVOPS_TEST_EXPORT_FAIL"):
    raise SystemExit(1)
if len(sys.argv) != 4 or sys.argv[1] != "export" or sys.argv[3] != "--pure":
    raise SystemExit(2)
with open(os.environ["AIDEVOPS_TEST_EXPORT_FIXTURE"], "rb") as source:
    sys.stdout.buffer.write(source.read())
""")
os.chmod(fake_opencode, 0o755)
PY

text_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture")
assert_contains "text reports one repeated group" "Repeated unchanged snapshots: 1 groups, 2 redundant results" "$text_output"
assert_contains "text reports oversized output" "Oversized tool results: 2" "$text_output"
assert_contains "text identifies unchanged snapshots" "unchanged-snapshot" "$text_output"
assert_contains "text identifies duplicate tool output" "Duplicate tool-output groups: 1" "$text_output"
assert_contains "text identifies repeated blocks" "Repeated line/block groups:" "$text_output"
assert_contains "text distinguishes receipt background evidence" "27163 declared bytes across 2 receipts" "$text_output"
assert_contains "text reports raw fallback and exact bypass" "Raw fallback / exact-output bypass results: 1 / 1" "$text_output"
assert_omits "text omits raw output" "SECRET-MARKER" "$text_output"

json_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture" --json)
if python3 -c 'import json,sys; report=json.load(sys.stdin); stats=report["stats"]; visibility=report["visibility"]; assert report["schema"] == "aidevops.session-output-efficiency/v1"; assert stats["redundant_tool_results"] == 2; assert stats["duplicate_output_groups"] == 1; assert stats["repeated_line_groups"] == 2; assert stats["repeated_block_groups"] >= 1; assert stats["oversized_tool_results"] == 2; assert stats["successful_oversized_results"] == 2; assert stats["raw_fallback_results"] == 1; assert stats["exact_output_bypass_results"] == 1; assert visibility["receipt_results"] == 2; assert visibility["declared_background_evidence_bytes"] == 27163; assert visibility["background_content_scanned"] is False' <<<"$json_output"; then
	pass "JSON contract exposes aggregate metrics"
else
	fail "JSON contract exposes aggregate metrics"
fi

claude_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime claude-code --input "$claude_fixture")
assert_contains "Claude JSONL tool results are correlated" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$claude_output"

database_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session session-test)
assert_contains "OpenCode database tool parts are analysed" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$database_output"

active_output=$(
	HOME="$active_home" \
		AIDEVOPS_TEMP_DIR="$TMPDIR_TEST" \
		PATH="${fake_opencode_bin}:$PATH" \
		OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_TEST_EXPORT_FIXTURE="$active_export_fixture" \
		"$HELPER" --runtime opencode --session session-active --json
)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["session"] == "session-active"; assert report["source"] == "opencode-export"; assert report["stats"]["completed_tool_results"] == 2; assert report["stats"]["redundant_tool_results"] == 1' <<<"$active_output"; then
	pass "active exact OpenCode session is analysed before close"
else
	fail "active exact OpenCode session is analysed before close"
fi
assert_omits "active aggregate report omits raw output" "ACTIVE-SECRET-MARKER" "$active_output"
assert_omits "active analysis does not substitute an unrelated recent session" "UNRELATED-RECENT-SESSION" "$active_output"

mapped_output=$(
	HOME="$active_home" \
		AIDEVOPS_TEMP_DIR="$TMPDIR_TEST" \
		PATH="${fake_opencode_bin}:$PATH" \
		AIDEVOPS_SESSION_ID="framework-session" \
		OPENCODE_SESSION_ID="stale-opencode-session" \
		AIDEVOPS_OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_TEST_EXPORT_FIXTURE="$active_export_fixture" \
		"$HELPER" --runtime opencode --session framework-session --json
)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["session"] == "session-active"; assert report["stats"]["completed_tool_results"] == 2' <<<"$mapped_output"; then
	pass "explicit framework-to-OpenCode identity mapping is honoured"
else
	fail "explicit framework-to-OpenCode identity mapping is honoured"
fi

set +e
missing_active_output=$(
	HOME="$active_home" \
		AIDEVOPS_TEMP_DIR="$TMPDIR_TEST" \
		PATH="${fake_opencode_bin}:$PATH" \
		OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_TEST_EXPORT_FIXTURE="$active_export_fixture" \
		AIDEVOPS_TEST_EXPORT_FAIL=1 \
		"$HELPER" --runtime opencode --session session-active --json 2>&1
)
missing_active_rc=$?
mismatched_active_output=$(
	HOME="$active_home" \
		AIDEVOPS_TEMP_DIR="$TMPDIR_TEST" \
		PATH="${fake_opencode_bin}:$PATH" \
		OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_OPENCODE_SESSION_ID="session-active" \
		AIDEVOPS_TEST_EXPORT_FIXTURE="$mismatched_export_fixture" \
		"$HELPER" --runtime opencode --session session-active --json 2>&1
)
mismatched_active_rc=$?
set -e
[[ "$missing_active_rc" -eq 2 ]] && pass "missing active export remains unavailable" || fail "missing active export remains unavailable" "got ${missing_active_rc}"
[[ "$mismatched_active_rc" -eq 2 ]] && pass "mismatched active export is rejected" || fail "mismatched active export is rejected" "got ${mismatched_active_rc}"
assert_omits "active export errors do not expose unrelated transcript data" "UNRELATED-RECENT-SESSION" "${missing_active_output}${mismatched_active_output}"

set +e
missing_session_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session absent-session 2>&1)
missing_session_rc=$?
invalid_session_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session '../*' 2>&1)
invalid_session_rc=$?
set -e
[[ "$missing_session_rc" -eq 2 ]] && pass "missing database session is unavailable" || fail "missing database session is unavailable" "got ${missing_session_rc}"
[[ "$invalid_session_rc" -eq 2 ]] && pass "unsafe session filter is rejected" || fail "unsafe session filter is rejected" "got ${invalid_session_rc}"
assert_omits "session errors do not expose database path" "$opencode_db" "${missing_session_output}${invalid_session_output}"

review_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$REVIEW_HELPER" output-efficiency --input "$normalized_fixture" --json)
assert_contains "session review delegates output analysis" '"schema":"aidevops.session-output-efficiency/v1"' "$review_output"

set +e
invalid_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "${TMPDIR_TEST}/missing.jsonl" 2>&1)
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 2 ]] && pass "missing transcript returns usage error" || fail "missing transcript returns usage error" "got ${invalid_rc}"
assert_omits "missing transcript does not expose requested path" "$TMPDIR_TEST" "$invalid_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
