#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SANDBOX_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
NETWORK_HELPER="${SCRIPT_DIR}/network-tier-helper.sh"
HEADLESS_HELPER="${SCRIPT_DIR}/headless-runtime-helper.sh"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="${TEST_ROOT}/home"
BACKEND="${TEST_ROOT}/egress-backend"
TARGET="${TEST_ROOT}/adversary"
MARKER="${TEST_ROOT}/target-ran"
CHILD_MARKER="${TEST_ROOT}/child-ran"
BACKEND_LOG="${TEST_ROOT}/backend-argv"
CUSTOM_POLICY="${TEST_ROOT}/network-tiers-custom.conf"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_HOME"

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

write_fixtures() {
	cat >"$TARGET" <<EOF
#!/usr/bin/env bash
printf 'target' >"$MARKER"
(printf 'child' >"$CHILD_MARKER") &
wait
exit 0
EOF
	chmod +x "$TARGET"

	cat >"$BACKEND" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

case "${1:-}" in
probe)
	if [[ "${FAKE_BACKEND_MODE:-ready}" == "invalid" ]]; then
		printf '{"ready":true}'
		exit 0
	fi
	policy_file="${3:?}"
	policy_sha256="$(python3 - "$policy_file" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
)"
	printf '{"schema":"aidevops.worker-egress-backend.v1","ready":true,"scope":"process-tree","enforcement":"kernel","policy_sha256":"%s","backend_id":"fixture-backend"}' "$policy_sha256"
	exit 0
	;;
run)
	shift
	while [[ $# -gt 0 && "$1" != "--" ]]; do
		shift
	done
	[[ "${1:-}" == "--" ]] && shift
	printf '%s\n' "$@" >"${FAKE_BACKEND_LOG:?}"
	if [[ "${FAKE_BACKEND_MODE:-ready}" == "deny" ]]; then
		exit 77
	fi
	exec "$@"
	;;
*)
	exit 64
	;;
esac
EOF
	chmod +x "$BACKEND"
	return 0
}

test_policy_export_is_normalized() {
	local output=""
	output="$(HOME="$TEST_HOME" "$NETWORK_HELPER" export-policy)" || {
		fail "exports normalized backend policy" "export failed"
		return 0
	}
	if printf '%s' "$output" | jq -e \
		'.schema == "aidevops.worker-egress-policy.v1" and .raw_ip_action == "deny" and .private_network_action == "deny" and ([.rules[] | select(.tier == 5)] | length > 0) and ([.rules[] | select(.match == "exact" and .pattern == "github.com" and .action == "allow")] | length == 1) and ([.rules[] | select(.pattern == "api.openai.com" and (.action | startswith("allow")))] | length == 1)' \
		>/dev/null 2>&1; then
		pass "exports normalized backend policy"
	else
		fail "exports normalized backend policy" "invalid contract"
	fi
	return 0
}

test_policy_export_applies_user_override() {
	cat >"$CUSTOM_POLICY" <<'EOF'
[tier5]
github.com
EOF
	local output=""
	output="$(HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_USER_POLICY="$CUSTOM_POLICY" "$NETWORK_HELPER" export-policy)" || {
		fail "normalized policy applies user overrides" "export failed"
		return 0
	}
	if printf '%s' "$output" | jq -e \
		'[.rules[] | select(.match == "exact" and .pattern == "github.com" and .tier == 5 and .action == "deny")] | length == 1' \
		>/dev/null 2>&1; then
		pass "normalized policy applies user overrides"
	else
		fail "normalized policy applies user overrides" "override missing"
	fi
	return 0
}

test_required_mode_fails_closed_without_backend() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="" \
		"$SANDBOX_HELPER" run --egress-mode required -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" && ! -e "$CHILD_MARKER" ]]; then
		pass "required mode fails closed without backend"
	else
		fail "required mode fails closed without backend" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi
	return 0
}

test_required_mode_rejects_invalid_probe() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=invalid FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "required mode rejects invalid backend readiness"
	else
		fail "required mode rejects invalid backend readiness" "status=${status}"
	fi
	return 0
}

test_backend_wraps_process_tree() {
	rm -f "$MARKER" "$CHILD_MARKER" "$BACKEND_LOG"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=ready FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required --worker-id fixture-worker -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && -e "$CHILD_MARKER" && -s "$BACKEND_LOG" ]] && \
		grep -F "$TARGET" "$BACKEND_LOG" >/dev/null 2>&1; then
		pass "verified backend wraps command and descendants"
	else
		fail "verified backend wraps command and descendants" "status=${status}"
	fi
	return 0
}

test_backend_denial_blocks_arbitrary_binary() {
	rm -f "$MARKER" "$CHILD_MARKER" "$BACKEND_LOG"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=deny FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required --worker-id fixture-worker -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 77 && ! -e "$MARKER" && ! -e "$CHILD_MARKER" ]]; then
		pass "backend denial blocks arbitrary binary and descendants"
	else
		fail "backend denial blocks arbitrary binary and descendants" "status=${status}"
	fi
	return 0
}

test_auto_mode_reports_non_containment() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local output=""
	local status=0
	output="$(HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="" \
		"$SANDBOX_HELPER" run --egress-mode auto -- "$TARGET" 2>&1)" || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && "$output" == *"state=command-policy-only"* && "$output" == *"egress=command-policy-only"* ]]; then
		pass "auto mode reports command-policy-only state"
	else
		fail "auto mode reports command-policy-only state" "status=${status} output=${output}"
	fi
	return 0
}

test_headless_runtime_binds_egress_contract() {
	local egress_count=0
	local worker_count=0
	egress_count="$(grep -cF -- '--egress-mode' "$HEADLESS_HELPER")"
	worker_count="$(grep -cF -- '--worker-id' "$HEADLESS_HELPER")"
	if [[ "$egress_count" -eq 2 && "$worker_count" -eq 2 ]]; then
		pass "headless runtime binds egress mode and worker identity"
	else
		fail "headless runtime binds egress mode and worker identity" "egress=${egress_count} worker=${worker_count}"
	fi
	return 0
}

main() {
	write_fixtures
	test_policy_export_is_normalized
	test_policy_export_applies_user_override
	test_required_mode_fails_closed_without_backend
	test_required_mode_rejects_invalid_probe
	test_backend_wraps_process_tree
	test_backend_denial_blocks_arbitrary_binary
	test_auto_mode_reports_non_containment
	test_headless_runtime_binds_egress_contract
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
