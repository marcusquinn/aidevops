#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Integration coverage for owner-safe, serialized local development launches.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/localdev-helper.sh"
SERVE_LIB="$REPO_ROOT/.agents/scripts/localdev-helper-serve.sh"
TEST_TMP_BASE="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_TMP_BASE"
TEST_ROOT="$(mktemp -d "$TEST_TMP_BASE/localdev-helper-serve.XXXXXX")"
ORIGINAL_HOME="$HOME"
export HOME="$TEST_ROOT/home"
PROJECT_A="$TEST_ROOT/project-a"
PROJECT_B="$TEST_ROOT/project-b"
PASS=0
FAIL=0
ACTIVE_PIDS=()

record_pass() {
	local description="$1"
	printf 'PASS: %s\n' "$description"
	PASS=$((PASS + 1))
	return 0
}

record_fail() {
	local description="$1"
	printf 'FAIL: %s\n' "$description" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_true() {
	local description="$1"
	shift
	if "$@"; then
		record_pass "$description"
	else
		record_fail "$description"
	fi
	return 0
}

assert_status() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" -eq "$actual" ]]; then
		record_pass "$description"
	else
		record_fail "$description (expected $expected, got $actual)"
	fi
	return 0
}

line_count_is() {
	local file="$1"
	local expected="$2"
	local actual=0
	[[ -f "$file" ]] && actual="$(wc -l <"$file" | tr -d ' ')"
	[[ "$actual" -eq "$expected" ]]
	return $?
}

file_contains() {
	local file="$1"
	local text="$2"
	local line=""
	grep -Fq -- "$text" "$file" && return 0
	printf '  expected output containing: %s\n' "$text" >&2
	while IFS= read -r line; do
		printf '  actual output: %s\n' "$line" >&2
	done <"$file"
	return 1
}

pick_port() {
	python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
	return 0
}

wait_for_health() {
	local port="$1"
	local attempts="${2:-50}"
	local attempt=0
	while [[ "$attempt" -lt "$attempts" ]]; do
		if curl --fail --silent --output /dev/null --noproxy '*' "http://127.0.0.1:${port}/"; then
			return 0
		fi
		sleep 0.2
		attempt=$((attempt + 1))
	done
	return 1
}

wait_for_port_free() {
	local port="$1"
	local attempt=0
	while [[ "$attempt" -lt 50 ]]; do
		if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
		attempt=$((attempt + 1))
	done
	return 1
}

wait_for_path_absent() {
	local path="$1"
	local attempt=0
	while [[ "$attempt" -lt 50 ]]; do
		[[ ! -e "$path" ]] && return 0
		sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

register_pid() {
	local pid="$1"
	ACTIVE_PIDS+=("$pid")
	return 0
}

terminate_pid() {
	local pid="$1"
	local attempt=0
	if kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null || true
		while kill -0 "$pid" 2>/dev/null && [[ "$attempt" -lt 20 ]]; do
			sleep 0.1
			attempt=$((attempt + 1))
		done
		kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true
	return 0
}

cleanup() {
	local pid=""
	for pid in "${ACTIVE_PIDS[@]}"; do
		terminate_pid "$pid"
	done
	export HOME="$ORIGINAL_HOME"
	rm -rf "$TEST_ROOT"
	return 0
}

start_helper() {
	local project="$1"
	local port="$2"
	local launch_log="$3"
	local output_file="$4"
	local startup_delay="${5:-0}"
	local stale_lock="${6:-.next/dev/lock}"
	(
		cd "$project" || exit 1
		exec /bin/bash "$HELPER" serve --name integration-test --port "$port" --root "$project" \
			--lock "$stale_lock" --health-url "http://127.0.0.1:${port}/" \
			--startup-timeout 15 -- env LAUNCH_LOG="$launch_log" STARTUP_DELAY="$startup_delay" \
			python3 server.py
	) >"$output_file" 2>&1 &
	STARTED_PID=$!
	register_pid "$STARTED_PID"
	return 0
}

run_helper_once() {
	local project="$1"
	local port="$2"
	local launch_log="$3"
	local output_file="$4"
	local stale_lock="${5:-.next/dev/lock}"
	local status=0
	(
		cd "$project" || exit 1
		/bin/bash "$HELPER" serve --name integration-test --port "$port" --root "$project" \
			--lock "$stale_lock" --health-url "http://127.0.0.1:${port}/" \
			--startup-timeout 5 -- env LAUNCH_LOG="$launch_log" python3 server.py
	) >"$output_file" 2>&1 || status=$?
	return "$status"
}

for required_command in python3 curl lsof; do
	if ! command -v "$required_command" >/dev/null 2>&1; then
		printf 'FAIL: required test command unavailable: %s\n' "$required_command" >&2
		exit 1
	fi
done

trap cleanup EXIT
mkdir -p "$HOME/.local-dev-proxy/run-locks" "$PROJECT_A/.next/dev" "$PROJECT_B/.next/dev" "$TEST_ROOT/empty-bin"

missing_lsof_output="$TEST_ROOT/missing-lsof.out"
missing_lsof_status=0
(
	print_error() {
		printf '%s\n' "$*"
		return 0
	}
	print_info() {
		printf '%s\n' "$*"
		return 0
	}
	# shellcheck source=/dev/null
	source "$SERVE_LIB"
	PATH="$TEST_ROOT/empty-bin" _serve_validate_args 32000 5 1 ""
) >"$missing_lsof_output" 2>&1 || missing_lsof_status=$?
assert_status "missing lsof fails closed" 1 "$missing_lsof_status"
assert_true "missing lsof diagnostic is explicit" file_contains "$missing_lsof_output" "lsof is required"

missing_curl_output="$TEST_ROOT/missing-curl.out"
missing_curl_status=0
(
	print_error() {
		printf '%s\n' "$*"
		return 0
	}
	print_info() {
		printf '%s\n' "$*"
		return 0
	}
	lsof() { return 0; }
	# shellcheck source=/dev/null
	source "$SERVE_LIB"
	PATH="$TEST_ROOT/empty-bin" _serve_validate_args 32000 5 1 "http://127.0.0.1:32000/"
) >"$missing_curl_output" 2>&1 || missing_curl_status=$?
assert_status "missing curl fails closed when health is required" 1 "$missing_curl_status"
assert_true "missing curl diagnostic is explicit" file_contains "$missing_curl_output" "curl is required"

unknown_owner_output="$TEST_ROOT/unknown-owner.out"
unknown_owner_status=0
(
	print_error() {
		printf '%s\n' "$*"
		return 0
	}
	print_info() {
		printf '%s\n' "$*"
		return 0
	}
	# shellcheck source=/dev/null
	source "$SERVE_LIB"
	_serve_process_cwd() { return 0; }
	_serve_validate_owners 12345 "$PROJECT_A"
) >"$unknown_owner_output" 2>&1 || unknown_owner_status=$?
assert_status "uninspectable listener owner fails closed" 1 "$unknown_owner_status"
assert_true "uninspectable owner diagnostic is explicit" file_contains "$unknown_owner_output" "unknown"

for project in "$PROJECT_A" "$PROJECT_B"; do
	cat >"$project/server.py" <<'PY'
import http.server
import os
import time

port = int(os.environ["PORT"])
with open(os.environ["LAUNCH_LOG"], "a", encoding="utf-8") as log:
    log.write(f"pid={os.getpid()} port={port} host={os.environ.get('HOST', '')}\n")
    log.flush()
time.sleep(float(os.environ.get("STARTUP_DELAY", "0")))
status = int(os.environ.get("HEALTH_STATUS", "200"))

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        return

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
done

port="$(pick_port)"
launch_log="$TEST_ROOT/launch.log"
leader_output="$TEST_ROOT/leader.out"
reuse_output="$TEST_ROOT/reuse.out"
foreign_output="$TEST_ROOT/foreign.out"
touch "$PROJECT_A/.next/dev/lock" "$PROJECT_B/.next/dev/lock" "$launch_log"

# A dead, old launch lock must not permanently block the next owner.
mkdir "$HOME/.local-dev-proxy/run-locks/port-${port}.lock"
printf '%s\n' '999999' >"$HOME/.local-dev-proxy/run-locks/port-${port}.lock/pid"
touch -t 202001010000 "$HOME/.local-dev-proxy/run-locks/port-${port}.lock"

start_helper "$PROJECT_A" "$port" "$launch_log" "$leader_output"
leader_pid="$STARTED_PID"
assert_true "first launch becomes healthy" wait_for_health "$port"
assert_true "project-contained stale lock is removed" test ! -e "$PROJECT_A/.next/dev/lock"
assert_true "server launches once" line_count_is "$launch_log" 1
assert_true "PORT and HOST reach the command" file_contains "$launch_log" "port=$port host=0.0.0.0"
assert_true "stale per-port launch lock is reclaimed" wait_for_path_absent "$HOME/.local-dev-proxy/run-locks/port-${port}.lock"

run_helper_once "$PROJECT_A" "$port" "$launch_log" "$reuse_output"
reuse_status=$?
assert_status "healthy same-project listener is reused" 0 "$reuse_status"
assert_true "reuse does not launch a duplicate" line_count_is "$launch_log" 1
assert_true "reuse is reported" file_contains "$reuse_output" "Reusing integration-test on port $port"

run_helper_once "$PROJECT_B" "$port" "$launch_log" "$foreign_output"
foreign_status=$?
assert_status "foreign project listener fails closed" 1 "$foreign_status"
assert_true "foreign collision leaves its stale lock untouched" test -e "$PROJECT_B/.next/dev/lock"
assert_true "foreign collision does not stop the owner" kill -0 "$leader_pid"
assert_true "foreign collision is explained" file_contains "$foreign_output" "outside project root"

terminate_pid "$leader_pid"
assert_true "leader termination releases the port" wait_for_port_free "$port"

# An owned but unhealthy listener must remain running and block replacement.
unhealthy_log="$TEST_ROOT/unhealthy.log"
(
	cd "$PROJECT_A" || exit 1
	exec env PORT="$port" LAUNCH_LOG="$unhealthy_log" HEALTH_STATUS=503 python3 server.py
) >"$TEST_ROOT/unhealthy-server.out" 2>&1 &
unhealthy_pid=$!
register_pid "$unhealthy_pid"
sleep 0.5
unhealthy_output="$TEST_ROOT/unhealthy-helper.out"
run_helper_once "$PROJECT_A" "$port" "$launch_log" "$unhealthy_output"
unhealthy_status=$?
assert_status "owned unhealthy listener is not replaced" 1 "$unhealthy_status"
assert_true "owned unhealthy listener is not killed" kill -0 "$unhealthy_pid"
assert_true "unhealthy collision is explained" file_contains "$unhealthy_output" "is unhealthy"
terminate_pid "$unhealthy_pid"
assert_true "unhealthy listener cleanup releases the port" wait_for_port_free "$port"

# A requested stale-lock path outside the project must fail without launching.
outside_lock="$TEST_ROOT/outside.lock"
outside_output="$TEST_ROOT/outside.out"
touch "$outside_lock"
run_helper_once "$PROJECT_A" "$port" "$launch_log" "$outside_output" "$outside_lock"
outside_status=$?
assert_status "outside stale-lock path is rejected" 1 "$outside_status"
assert_true "outside stale-lock file is preserved" test -e "$outside_lock"
assert_true "outside stale-lock rejection does not launch" line_count_is "$launch_log" 1

missing_outside_lock="$TEST_ROOT/not-created/outside.lock"
run_helper_once "$PROJECT_A" "$port" "$launch_log" "$outside_output" "$missing_outside_lock"
missing_outside_status=$?
assert_status "absent outside stale-lock path is rejected" 1 "$missing_outside_status"

run_helper_once "$PROJECT_A" "$port" "$launch_log" "$outside_output" "../outside-absent.lock"
traversal_status=$?
assert_status "relative stale-lock traversal is rejected" 1 "$traversal_status"

mkdir "$TEST_ROOT/outside-dir"
ln -s "$TEST_ROOT/outside-dir" "$PROJECT_A/escape"
run_helper_once "$PROJECT_A" "$port" "$launch_log" "$outside_output" "escape/absent.lock"
symlink_escape_status=$?
assert_status "stale-lock parent symlink escape is rejected" 1 "$symlink_escape_status"
assert_true "all invalid stale-lock paths avoid launching" line_count_is "$launch_log" 1

launch_lock_target="$TEST_ROOT/launch-lock-target"
launch_lock_path="$HOME/.local-dev-proxy/run-locks/port-${port}.lock"
mkdir "$launch_lock_target"
printf '%s\n' 'preserve-me' >"$launch_lock_target/pid"
ln -s "$launch_lock_target" "$launch_lock_path"
run_helper_once "$PROJECT_A" "$port" "$launch_log" "$outside_output"
launch_lock_symlink_status=$?
assert_status "symlinked per-port launch lock is rejected" 1 "$launch_lock_symlink_status"
assert_true "symlinked launch-lock target is preserved" file_contains "$launch_lock_target/pid" "preserve-me"
assert_true "invalid launch lock does not launch" line_count_is "$launch_log" 1
rm -f "$launch_lock_path"

# Parallel cold starts must serialize and produce exactly one server process.
parallel_port="$(pick_port)"
parallel_log="$TEST_ROOT/parallel.log"
parallel_one="$TEST_ROOT/parallel-one.out"
parallel_two="$TEST_ROOT/parallel-two.out"
touch "$parallel_log" "$PROJECT_A/.next/dev/lock"
start_helper "$PROJECT_A" "$parallel_port" "$parallel_log" "$parallel_one" 2
parallel_pid_one="$STARTED_PID"
start_helper "$PROJECT_A" "$parallel_port" "$parallel_log" "$parallel_two" 2
parallel_pid_two="$STARTED_PID"
assert_true "parallel launch becomes healthy" wait_for_health "$parallel_port" 75
sleep 1
assert_true "parallel launch starts one command" line_count_is "$parallel_log" 1

alive_one=0
alive_two=0
kill -0 "$parallel_pid_one" 2>/dev/null && alive_one=1
kill -0 "$parallel_pid_two" 2>/dev/null && alive_two=1
if [[ $((alive_one + alive_two)) -eq 1 ]]; then
	record_pass "parallel follower exits after reusing the leader"
else
	record_fail "parallel follower exits after reusing the leader (alive: $alive_one/$alive_two)"
fi

if [[ "$alive_one" -eq 1 ]]; then
	parallel_leader="$parallel_pid_one"
	parallel_follower="$parallel_pid_two"
else
	parallel_leader="$parallel_pid_two"
	parallel_follower="$parallel_pid_one"
fi
follower_status=0
wait "$parallel_follower" || follower_status=$?
assert_status "parallel follower returns success" 0 "$follower_status"
terminate_pid "$parallel_leader"
assert_true "parallel leader termination releases the port" wait_for_port_free "$parallel_port"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
