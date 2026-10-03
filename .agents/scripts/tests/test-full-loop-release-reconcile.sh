#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release reconciliation regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../.."
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED="published-reconcile"
_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED="authorized-published-reconcile"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/receipts"

# shellcheck source=../full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"
# shellcheck source=../release-authorization-manifest-helper.sh
source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"

# Exercise the real inspect/dispatch boundary before the command fixtures replace it.
(
	sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	_FULL_LOOP_RELEASE_RUN_JSON=""
	_full_loop_release_resolve_tag_commit() { printf '%s\n' "$sha"; return 0; }
	_full_loop_release_verify_channels() { return 1; }
	_full_loop_release_find_workflow_run() {
		local repo="$1" tag="$2" commit="$3"
		[[ "$repo" == test/repo && "$tag" == v1.2.3 && "$commit" == "$sha" ]] || return 1
		_FULL_LOOP_RELEASE_RUN_JSON="$fixture_run"
		return 0
	}
	gh() {
		[[ "$1 $2 $3" == 'workflow run publish-packages.yml' ]] || return 1
		printf 'dispatch\n' >>"${TEST_ROOT}/grace-dispatch.log"
		return 0
	}
	SCRIPT_DIR="${TEST_ROOT}/bin"
	fixture_run=$(jq -cn --arg sha "$sha" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{event:"push",head_sha:$sha,status:"completed",conclusion:"success",updated_at:$updated}')
	rc=0
	_full_loop_release_inspect_remote test/repo v1.2.3 >"${TEST_ROOT}/grace-output" || rc=$?
	[[ "$rc" -eq 8 && ! -e "${TEST_ROOT}/grace-dispatch.log" ]] || exit 1
	grep -qx 'WORKFLOW_STATUS=completed' "${TEST_ROOT}/grace-output" || exit 1
	printf 'PASS recent successful publish waits for channels without dispatch\n'
	fixture_run=$(jq -cn --arg sha "$sha" --arg updated "$(jq -nr --argjson epoch "$(date -u +%s)" '$epoch - 1200 | todateiso8601')" \
		'{event:"push",head_sha:$sha,status:"completed",conclusion:"success",updated_at:$updated}')
	rc=0
	_full_loop_release_inspect_remote test/repo v1.2.3 >/dev/null || rc=$?
	[[ "$rc" -eq 5 ]] || exit 1
	rc=0
	_full_loop_release_dispatch_recovery test/repo v1.2.3 >/dev/null || rc=$?
	[[ "$rc" -eq 8 && "$(wc -l <"${TEST_ROOT}/grace-dispatch.log")" -eq 1 ]] || exit 1
	printf 'PASS expired grace dispatches once\n'
	fixture_run=$(jq -cn --arg sha "$sha" '{event:"workflow_dispatch",head_sha:$sha,status:"queued",conclusion:null}')
	rc=0
	_full_loop_release_inspect_remote test/repo v1.2.3 >/dev/null || rc=$?
	[[ "$rc" -eq 8 && "$(wc -l <"${TEST_ROOT}/grace-dispatch.log")" -eq 1 ]] || exit 1
	printf 'PASS queued recovery does not redispatch\n'
	_full_loop_release_find_workflow_run() { _FULL_LOOP_RELEASE_RUN_JSON=""; return 3; }
	_full_loop_release_verify_channels() { return 0; }
	rc=0
	_full_loop_release_inspect_remote test/repo v1.2.3 >"${TEST_ROOT}/lookup-output" || rc=$?
	[[ "$rc" -eq 8 && "$(wc -l <"${TEST_ROOT}/grace-dispatch.log")" -eq 1 ]] || exit 1
	grep -qx 'WORKFLOW_LOOKUP=uncorroborated' "${TEST_ROOT}/lookup-output" || exit 1
	printf 'PASS absent run with published channels is pending without dispatch\n'
	_full_loop_release_verify_channels() { return 1; }
	rc=0
	_full_loop_release_inspect_remote test/repo v1.2.3 >/dev/null || rc=$?
	[[ "$rc" -eq 3 ]] || exit 1
	printf 'PASS absent run with unpublished channels still reports absent\n'
)

# shellcheck source=test-full-loop-release-reconcile-proof.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-proof.sh"
# shellcheck source=test-full-loop-release-reconcile-discovery.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-discovery.sh"
# shellcheck source=test-full-loop-release-reconcile-runtime.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-runtime.sh"
# shellcheck source=test-full-loop-release-reconcile-channels.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-channels.sh"
# shellcheck source=test-full-loop-release-reconcile-supersession.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-supersession.sh"
# shellcheck source=test-full-loop-release-reconcile-command.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-command.sh"

exit 0
