#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$REPO_ROOT/.agents/scripts/aidevops-cli-converge-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-cli-converge.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	return 0
}

make_fixture() {
	local fixture="$1"
	mkdir -p "$fixture/home/.aidevops/agents" "$fixture/global" "$fixture/home/.local/bin" "$fixture/bin"
	printf '9.8.7\n' >"$fixture/home/.aidevops/agents/VERSION"
	cat >"$fixture/orchestrator-source" <<'EOF'
#!/usr/bin/env bash
printf 'aidevops %s\n' "$(tr -d '\n' <"$HOME/.aidevops/agents/VERSION")"
EOF
	cp "$REPO_ROOT/bin/aidevops" "$fixture/launcher"
	chmod +x "$fixture/launcher" "$fixture/orchestrator-source"
	return 0
}

run_converge() {
	local fixture="$1"
	shift
	HOME="$fixture/home" \
		PATH="${AIDEVOPS_TEST_CLI_PATH:-$fixture/global:$fixture/home/.local/bin}:$fixture/bin:/usr/bin:/bin" \
		AIDEVOPS_CLI_GLOBAL_TARGET="$fixture/global/aidevops" \
		AIDEVOPS_CLI_USER_TARGET="$fixture/home/.local/bin/aidevops" \
		AIDEVOPS_CLI_LOCK_DIR="$fixture/home/.aidevops/locks/cli.lock" \
		AIDEVOPS_CLI_WARNING_FILE="$fixture/home/.aidevops/logs/cli-warning.txt" \
		AIDEVOPS_CLI_NON_INTERACTIVE=true \
		"$@" "$HELPER" converge "$fixture/launcher" "$fixture/orchestrator-source" \
		"$fixture/home/.aidevops/agents/aidevops.sh" "$fixture/home/.aidevops/agents/VERSION"
	return $?
}

test_lock_covers_orchestrator_copy() {
	local fixture="$TEST_ROOT/orchestrator-lock"
	make_fixture "$fixture"
	printf 'stale-orchestrator\n' >"$fixture/home/.aidevops/agents/aidevops.sh"
	mkdir -p "$fixture/home/.aidevops/locks/cli.lock"
	sleep 10 &
	local owner_pid=$!
	local owner_lstart
	owner_lstart=$(LC_ALL=C TZ=UTC ps -ww -p "$owner_pid" -o lstart=)
	owner_lstart="${owner_lstart#"${owner_lstart%%[![:space:]]*}"}"
	printf '%s\n' "$owner_pid" >"$fixture/home/.aidevops/locks/cli.lock/pid"
	printf '%s\n' "$owner_lstart" >"$fixture/home/.aidevops/locks/cli.lock/lstart"
	printf 'sleep\n' >"$fixture/home/.aidevops/locks/cli.lock/command-token"
	: >"$fixture/home/.aidevops/locks/cli.lock/initialized"
	if AIDEVOPS_CLI_LOCK_WAIT_SECONDS=1 run_converge "$fixture" env >/dev/null 2>&1; then
		fail "orchestrator copy waits for active convergence lock" "unexpected success"
	elif [[ "$(tr -d '\n' <"$fixture/home/.aidevops/agents/aidevops.sh")" == "stale-orchestrator" ]]; then
		pass "orchestrator copy waits for active convergence lock"
	else
		fail "orchestrator copy waits for active convergence lock" "orchestrator changed outside lock"
	fi
	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$fixture/home/.aidevops/locks/cli.lock"
	return 0
}

test_incomplete_lock_grace_and_reclaim() {
	local fixture="$TEST_ROOT/incomplete-lock"
	make_fixture "$fixture"
	mkdir -p "$fixture/home/.aidevops/locks/cli.lock"
	if AIDEVOPS_CLI_INCOMPLETE_GRACE_SECONDS=1 run_converge "$fixture" env >/dev/null 2>&1; then
		pass "incomplete lock is reclaimed after bounded grace"
	else
		fail "incomplete lock is reclaimed after bounded grace" "convergence failed"
	fi
	return 0
}

test_parallel_stale_reclaimers_serialize() {
	local fixture="$TEST_ROOT/parallel-reclaim"
	make_fixture "$fixture"
	mkdir -p "$fixture/home/.aidevops/locks/cli.lock"
	printf '999999\n' >"$fixture/home/.aidevops/locks/cli.lock/pid"
	printf 'stale-process-start\n' >"$fixture/home/.aidevops/locks/cli.lock/lstart"
	printf 'stale-token\n' >"$fixture/home/.aidevops/locks/cli.lock/command-token"
	: >"$fixture/home/.aidevops/locks/cli.lock/initialized"
	run_converge "$fixture" env >/dev/null 2>&1 &
	local first_pid=$!
	run_converge "$fixture" env >/dev/null 2>&1 &
	local second_pid=$!
	local first_rc=0
	local second_rc=0
	wait "$first_pid" || first_rc=$?
	wait "$second_pid" || second_rc=$?
	if [[ "$first_rc" -eq 0 && "$second_rc" -eq 0 && ! -d "$fixture/home/.aidevops/locks/cli.lock.reclaim" ]]; then
		pass "parallel stale reclaimers serialize and revalidate"
	else
		fail "parallel stale reclaimers serialize and revalidate" "first=$first_rc second=$second_rc"
	fi
	return 0
}

test_crashed_reclaim_mutex_recovers() {
	local fixture="$TEST_ROOT/crashed-reclaimer"
	make_fixture "$fixture"
	mkdir -p "$fixture/home/.aidevops/locks/cli.lock" "$fixture/home/.aidevops/locks/cli.lock.reclaim"
	printf '999998\n' >"$fixture/home/.aidevops/locks/cli.lock/pid"
	printf 'stale-primary-start\n' >"$fixture/home/.aidevops/locks/cli.lock/lstart"
	printf 'stale-primary-token\n' >"$fixture/home/.aidevops/locks/cli.lock/command-token"
	: >"$fixture/home/.aidevops/locks/cli.lock/initialized"
	printf '999997\n' >"$fixture/home/.aidevops/locks/cli.lock.reclaim/pid"
	printf 'stale-reclaimer-start\n' >"$fixture/home/.aidevops/locks/cli.lock.reclaim/lstart"
	printf 'stale-reclaimer-token\n' >"$fixture/home/.aidevops/locks/cli.lock.reclaim/command-token"
	: >"$fixture/home/.aidevops/locks/cli.lock.reclaim/initialized"
	if AIDEVOPS_CLI_RECLAIM_GRACE_SECONDS=1 run_converge "$fixture" env >/dev/null 2>&1 &&
		[[ ! -d "$fixture/home/.aidevops/locks/cli.lock.reclaim" ]]; then
		pass "crashed stale reclaim mutex is recovered"
	else
		fail "crashed stale reclaim mutex is recovered" "convergence remained blocked"
	fi
	return 0
}

test_release_requires_same_unique_token() {
	local fixture="$TEST_ROOT/release-owner-token"
	make_fixture "$fixture"
	cat >"$fixture/bin/install" <<'EOF'
#!/usr/bin/env bash
sleep 2
exec /usr/bin/install "$@"
EOF
	chmod +x "$fixture/bin/install"
	run_converge "$fixture" env >/dev/null 2>&1 &
	local converge_pid=$!
	local waited=0
	while [[ ! -r "$fixture/home/.aidevops/locks/cli.lock/initialized" && "$waited" -lt 20 ]]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	printf 'different-owner-token\n' >"$fixture/home/.aidevops/locks/cli.lock/command-token"
	local converge_rc=0
	wait "$converge_pid" || converge_rc=$?
	if [[ "$converge_rc" -eq 0 && -d "$fixture/home/.aidevops/locks/cli.lock" ]]; then
		pass "lock release refuses a different owner token"
	else
		fail "lock release refuses a different owner token" "rc=$converge_rc lock missing"
	fi
	rm -rf "$fixture/home/.aidevops/locks/cli.lock"
	return 0
}

test_already_current() {
	local fixture="$TEST_ROOT/current"
	make_fixture "$fixture"
	cp "$fixture/launcher" "$fixture/global/aidevops"
	chmod +x "$fixture/global/aidevops"
	local before
	before=$(stat -f '%m' "$fixture/global/aidevops" 2>/dev/null || stat -c '%Y' "$fixture/global/aidevops")
	sleep 1
	if run_converge "$fixture" env >/dev/null 2>&1; then
		local after
		after=$(stat -f '%m' "$fixture/global/aidevops" 2>/dev/null || stat -c '%Y' "$fixture/global/aidevops")
		[[ "$before" == "$after" ]] && pass "already-current launcher is a no-op" || fail "already-current launcher is a no-op" "mtime changed"
	else
		fail "already-current launcher is a no-op" "convergence failed"
	fi
	return 0
}

test_writable_global() {
	local fixture="$TEST_ROOT/writable"
	make_fixture "$fixture"
	printf 'stale\n' >"$fixture/global/aidevops"
	chmod +x "$fixture/global/aidevops"
	if run_converge "$fixture" env >/dev/null 2>&1 && cmp -s "$fixture/launcher" "$fixture/global/aidevops"; then
		pass "writable global launcher is replaced atomically"
	else
		fail "writable global launcher is replaced atomically" "launcher did not converge"
	fi
	return 0
}

test_stale_global_without_sudo() {
	local fixture="$TEST_ROOT/no-sudo"
	make_fixture "$fixture"
	printf '#!/usr/bin/env bash\nprintf "aidevops 1.0.0\\n"\n' >"$fixture/global/aidevops"
	chmod +x "$fixture/global/aidevops"
	cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$fixture/bin/sudo"
	if AIDEVOPS_CLI_FORCE_GLOBAL_UNWRITABLE=1 run_converge "$fixture" env >/dev/null 2>&1; then
		fail "stale privileged launcher fails without sudo" "unexpected success"
	elif [[ -s "$fixture/home/.aidevops/logs/cli-warning.txt" ]] && cmp -s "$fixture/launcher" "$fixture/home/.local/bin/aidevops"; then
		pass "stale privileged launcher fails with durable warning and user fallback"
	else
		fail "stale privileged launcher fails without sudo" "missing warning or fallback"
	fi
	return 0
}

test_sudo_failure_user_launcher_wins() {
	local fixture="$TEST_ROOT/user-wins"
	make_fixture "$fixture"
	printf '#!/usr/bin/env bash\nprintf "aidevops 1.0.0\\n"\n' >"$fixture/global/aidevops"
	chmod +x "$fixture/global/aidevops"
	cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$fixture/bin/sudo"
	if AIDEVOPS_TEST_CLI_PATH="$fixture/home/.local/bin:$fixture/global" \
		AIDEVOPS_CLI_FORCE_GLOBAL_UNWRITABLE=1 run_converge "$fixture" env >/dev/null 2>&1; then
		pass "user launcher succeeds after sudo-n failure when it wins PATH"
	else
		fail "user launcher succeeds after sudo-n failure when it wins PATH" "convergence failed"
	fi
	return 0
}

test_non_executable_targets_repaired() {
	local fixture="$TEST_ROOT/non-executable"
	make_fixture "$fixture"
	cp "$fixture/launcher" "$fixture/global/aidevops"
	cp "$fixture/orchestrator-source" "$fixture/home/.aidevops/agents/aidevops.sh"
	chmod 0644 "$fixture/global/aidevops" "$fixture/home/.aidevops/agents/aidevops.sh"
	if run_converge "$fixture" env >/dev/null 2>&1 && [[ -x "$fixture/global/aidevops" && -x "$fixture/home/.aidevops/agents/aidevops.sh" ]]; then
		pass "byte-identical non-executable targets are repaired"
	else
		fail "byte-identical non-executable targets are repaired" "executable mode was not restored"
	fi
	return 0
}

test_lock_contention_and_idempotency() {
	local fixture="$TEST_ROOT/lock"
	make_fixture "$fixture"
	mkdir -p "$fixture/home/.aidevops/locks/cli.lock"
	printf '%s\n' "$$" >"$fixture/home/.aidevops/locks/cli.lock/pid"
	printf 'reused-process-start\n' >"$fixture/home/.aidevops/locks/cli.lock/lstart"
	printf 'aidevops-cli-converge-helper.sh\n' >"$fixture/home/.aidevops/locks/cli.lock/command-token"
	: >"$fixture/home/.aidevops/locks/cli.lock/initialized"
	if run_converge "$fixture" env >/dev/null 2>&1; then
		pass "PID-reuse fingerprint mismatch is reclaimed"
	else
		fail "PID-reuse fingerprint mismatch is reclaimed" "stale fingerprint blocked convergence"
	fi
	if run_converge "$fixture" env >/dev/null 2>&1 && run_converge "$fixture" env >/dev/null 2>&1; then
		pass "repeated convergence after lock release is idempotent"
	else
		fail "repeated convergence after lock release is idempotent" "convergence failed"
	fi
	return 0
}

test_user_fallback_shadowed() {
	local fixture="$TEST_ROOT/shadowed"
	make_fixture "$fixture"
	printf '#!/usr/bin/env bash\nprintf "aidevops 1.0.0\\n"\n' >"$fixture/global/aidevops"
	chmod +x "$fixture/global/aidevops"
	cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$fixture/bin/sudo"
	if AIDEVOPS_CLI_FORCE_GLOBAL_UNWRITABLE=1 run_converge "$fixture" env >/dev/null 2>&1; then
		fail "shadowed user fallback cannot pass convergence" "unexpected success"
	elif grep -q 'shadows the current user launcher\|resolves to stale launcher' "$fixture/home/.aidevops/logs/cli-warning.txt"; then
		pass "shadowed user fallback is detected"
	else
		fail "shadowed user fallback is detected" "missing actionable warning"
	fi
	return 0
}

test_unset_home_does_not_resolve_root_paths() {
	local fixture="$TEST_ROOT/unset-home"
	local output=""
	make_fixture "$fixture"
	if output=$(env -u HOME -u AIDEVOPS_DIR -u AIDEVOPS_CLI_WARNING_FILE \
		-u AIDEVOPS_CLI_LOCK_DIR -u AIDEVOPS_CLI_USER_TARGET \
		"$HELPER" converge "$fixture/launcher" "$fixture/orchestrator-source" \
		"$fixture/orchestrator-target" "$fixture/home/.aidevops/agents/VERSION" 2>&1); then
		fail "unset HOME does not resolve root paths" "unexpected convergence success"
	elif [[ "$output" == *"unbound variable"* || "$output" == /* ]]; then
		fail "unset HOME does not resolve root paths" "$output"
	else
		pass "unset HOME does not resolve root paths"
	fi
	return 0
}

main() {
	test_already_current
	test_lock_covers_orchestrator_copy
	test_incomplete_lock_grace_and_reclaim
	test_parallel_stale_reclaimers_serialize
	test_crashed_reclaim_mutex_recovers
	test_release_requires_same_unique_token
	test_writable_global
	test_stale_global_without_sudo
	test_sudo_failure_user_launcher_wins
	test_non_executable_targets_repaired
	test_lock_contention_and_idempotency
	test_user_fallback_shadowed
	test_unset_home_does_not_resolve_root_paths
	printf 'Results: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
	[[ "$FAIL_COUNT" -eq 0 ]]
	return $?
}

main "$@"
