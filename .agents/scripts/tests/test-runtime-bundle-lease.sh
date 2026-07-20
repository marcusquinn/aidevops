#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
LEASE_HELPER="${REPO_ROOT}/.agents/scripts/runtime-bundle-lease.sh"
HEADLESS_HELPER="${REPO_ROOT}/.agents/scripts/headless-runtime-helper.sh"
PULSE_WRAPPER="${REPO_ROOT}/.agents/scripts/pulse-wrapper.sh"
TEST_ROOT="$(mktemp -d -t runtime-bundle-lease.XXXXXX)"
ORIGINAL_HOME="${HOME}"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	HOME="$ORIGINAL_HOME"
	export HOME
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

if [[ ! -r "$LEASE_HELPER" ]]; then
	fail "runtime bundle lease helper exists" "missing=$LEASE_HELPER"
	printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi

# shellcheck source=../runtime-bundle-lease.sh
source "$LEASE_HELPER"
HOME="${TEST_ROOT}/home"
export HOME
agents_root="${HOME}/.aidevops/runtime-bundles/bundle-one/agents"
mkdir -p "${agents_root}/scripts"
agents_root=$(cd "$agents_root" && pwd -P)
lease_file="${agents_root%/bundle-one/agents}/.leases/bundle-one/$$"

if aidevops_runtime_bundle_lease_acquire "$agents_root" && \
	[[ -f "$lease_file" ]] && [[ "$(<"$lease_file")" == "$agents_root" ]]; then
	pass "physical runtime bundle acquisition writes a PID lease"
else
	fail "physical runtime bundle acquisition writes a PID lease" "lease=$lease_file"
fi

aidevops_runtime_bundle_lease_release
if [[ ! -e "$lease_file" ]]; then
	pass "runtime bundle lease release removes the PID lease"
else
	fail "runtime bundle lease release removes the PID lease" "lease still exists"
fi

repo_agents="${TEST_ROOT}/repo/.agents"
mkdir -p "${repo_agents}/scripts"
if aidevops_runtime_bundle_lease_acquire "$repo_agents" && \
	[[ -z "${_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE:-}" ]]; then
	pass "non-deployed repository scripts do not create runtime leases"
else
	fail "non-deployed repository scripts do not create runtime leases"
fi

if grep -q 'runtime-bundle-lease.sh' "$HEADLESS_HELPER" && \
	grep -q 'aidevops_runtime_bundle_lease_acquire' "$HEADLESS_HELPER" && \
	grep -q 'aidevops_runtime_bundle_lease_release' "$HEADLESS_HELPER"; then
	pass "headless runtime owns a bundle lease for its process lifetime"
else
	fail "headless runtime owns a bundle lease for its process lifetime"
fi

if grep -q 'runtime-bundle-lease.sh' "$PULSE_WRAPPER" && \
	grep -q 'aidevops_runtime_bundle_lease_acquire' "$PULSE_WRAPPER" && \
	grep -q 'aidevops_runtime_bundle_lease_release' "$PULSE_WRAPPER"; then
	pass "Pulse owns a bundle lease for its process lifetime"
else
	fail "Pulse owns a bundle lease for its process lifetime"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
