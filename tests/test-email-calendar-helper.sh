#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/email-calendar-helper.sh"

TEST_WORKSPACE="$(mktemp -d)"
TEST_BIN="${TEST_WORKSPACE}/bin"
TEST_LOG="${TEST_WORKSPACE}/invocations.log"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_WORKSPACE"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected: $expected"
		echo "    Actual:   $actual"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -q -- "$needle"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Missing: $needle"
	fi
	return 0
}

setup_stubs() {
	mkdir -p "$TEST_BIN"

	cat >"${TEST_WORKSPACE}/ai-helper-true.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"agreed":true,"reason":"confirmed in thread","event":{"title":"Project Sync","start":"2026-04-02T14:00","end":"2026-04-02T14:30","timezone":"Europe/London","location":"Zoom","attendees":["owner@example.com"],"context_summary":"Team confirmed project sync meeting."}}'
EOF
	chmod +x "${TEST_WORKSPACE}/ai-helper-true.sh"

	cat >"${TEST_WORKSPACE}/ai-helper-false.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"agreed":false,"reason":"No explicit acceptance found","event":{}}'
EOF
	chmod +x "${TEST_WORKSPACE}/ai-helper-false.sh"

	cat >"${TEST_BIN}/osascript" <<EOF
#!/usr/bin/env bash
set -euo pipefail
input="\
\$(cat)"
printf 'OSASCRIPT:%s\n' "\$input" >>"$TEST_LOG"
EOF
	chmod +x "${TEST_BIN}/osascript"

	cat >"${TEST_BIN}/gws" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'GWS:%s\n' "\$*" >>"$TEST_LOG"
EOF
	chmod +x "${TEST_BIN}/gws"

	return 0
}

test_extract_merges_participants() {
	echo "Test: extract merges participants and normalizes schema"

	local thread_file="${TEST_WORKSPACE}/thread.txt"
	cat >"$thread_file" <<'EOF'
From: Alice <alice@example.com>
To: Bob <bob@example.com>
Subject: Re: Project sync

Let's do Thursday at 2pm, confirmed.
EOF

	local output
	output=$(PATH="$TEST_BIN:$PATH" "$HELPER" extract \
		--thread-file "$thread_file" \
		--ai-helper "${TEST_WORKSPACE}/ai-helper-true.sh")

	local agreed attendee_count
	agreed=$(printf '%s\n' "$output" | jq -r '.agreed')
	attendee_count=$(printf '%s\n' "$output" | jq '.event.attendees | length')

	assert_eq "agreed=true" "true" "$agreed"
	assert_eq "attendees merged" "3" "$attendee_count"
	return 0
}

test_create_apple_invokes_osascript() {
	echo "Test: create apple sends AppleScript"

	: >"$TEST_LOG"

	local event_file="${TEST_WORKSPACE}/event.json"
	cat >"$event_file" <<'EOF'
{"agreed":true,"reason":"ok","event":{"title":"Project Sync","start":"2026-04-02T14:00","end":"2026-04-02T14:30","timezone":"Europe/London","location":"Zoom","attendees":["alice@example.com","bob@example.com"],"context_summary":"Confirmed in email"}}
EOF

	PATH="$TEST_BIN:$PATH" "$HELPER" create --provider apple --event-file "$event_file" --source-ref "thread-123"

	local log_contents
	log_contents=$(cat "$TEST_LOG")
	assert_contains "AppleScript call recorded" "OSASCRIPT:" "$log_contents"
	assert_contains "Event title included" "Project Sync" "$log_contents"
	assert_contains "Participants in notes" "alice@example.com" "$log_contents"
	return 0
}

test_create_gws_invokes_cli_with_attendees() {
	echo "Test: create gws calls +insert with attendees"

	: >"$TEST_LOG"

	local event_file="${TEST_WORKSPACE}/event-gws.json"
	cat >"$event_file" <<'EOF'
{"agreed":true,"reason":"ok","event":{"title":"Client Call","start":"2026-04-03T09:00","end":"2026-04-03T10:00","timezone":"UTC","location":"","attendees":["one@example.com","two@example.com"],"context_summary":"Client agreed to call"}}
EOF

	PATH="$TEST_BIN:$PATH" "$HELPER" create --provider gws --event-file "$event_file" --calendar "Primary"

	local log_contents
	log_contents=$(cat "$TEST_LOG")
	assert_contains "gws invoked" "GWS:calendar +insert" "$log_contents"
	assert_contains "attendee one included" "--attendee one@example.com" "$log_contents"
	assert_contains "attendee two included" "--attendee two@example.com" "$log_contents"
	return 0
}

test_from_thread_no_agreement_exits_clean() {
	echo "Test: from-thread returns JSON when no agreement"

	local thread_file="${TEST_WORKSPACE}/thread-no-agreement.txt"
	cat >"$thread_file" <<'EOF'
From: A <a@example.com>
To: B <b@example.com>

Maybe we can meet sometime next week.
EOF

	local output
	output=$(PATH="$TEST_BIN:$PATH" "$HELPER" from-thread \
		--provider gws \
		--thread-file "$thread_file" \
		--ai-helper "${TEST_WORKSPACE}/ai-helper-false.sh")

	local agreed
	agreed=$(printf '%s\n' "$output" | jq -r '.agreed')
	assert_eq "agreed=false" "false" "$agreed"
	return 0
}

run_tests() {
	echo "Running email-calendar-helper tests"
	echo "===================================="

	setup_stubs
	test_extract_merges_participants
	test_create_apple_invokes_osascript
	test_create_gws_invokes_cli_with_attendees
	test_from_thread_no_agreement_exits_clean

	echo ""
	echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

run_tests
